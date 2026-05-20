#include "rpc.h"
#include "openai.h"
#include "agent.h"
#include "output.h"
#include "util.h"
#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <pthread.h>
#include <unistd.h>

/* ---- RPC session state ---- */

typedef struct {
    pthread_mutex_t  mu;

    char            *session_id;

    /* current model + options */
    Model            model;        /* deep copy */
    StreamOptions    opts;         /* deep copy */

    /* conversation history */
    ContextMessage  *messages;
    int              messages_len;
    int              messages_cap;

    /* system prompt */
    char            *system_prompt;

    /* streaming state */
    volatile int     is_streaming;
    volatile int     abort_flag;

    /* config reference (not owned) */
    const Config    *config;

    /* tools */
    ToolHandler      handler;
    void            *handler_data;

    /* output mutex */
    pthread_mutex_t  out_mu;
} RpcSession;

/* ---- Output helpers ---- */

static void rpc_write_json(RpcSession *s, cJSON *obj) {
    char *line = cJSON_PrintUnformatted(obj);
    pthread_mutex_lock(&s->out_mu);
    puts(line);
    fflush(stdout);
    pthread_mutex_unlock(&s->out_mu);
    free(line);
}

static void rpc_respond(RpcSession *s, const char *id, const char *command,
                        cJSON *data, const char *error_msg) {
    cJSON *r = cJSON_CreateObject();
    if (id && id[0]) cJSON_AddStringToObject(r, "id", id);
    cJSON_AddStringToObject(r, "type",    "response");
    cJSON_AddStringToObject(r, "command", command);
    cJSON_AddBoolToObject  (r, "success", error_msg == NULL ? cJSON_True : cJSON_False);
    if (error_msg) {
        cJSON_AddStringToObject(r, "error", error_msg);
        if (data) cJSON_Delete(data);
    } else if (data) {
        cJSON_AddItemToObject(r, "data", data);
    }
    rpc_write_json(s, r);
    cJSON_Delete(r);
}

/* ---- Event callback for streaming (writes RPC events) ---- */

typedef struct {
    RpcSession *session;
} RpcCbData;

static void rpc_event_cb(const WispEvent *e, void *userdata) {
    RpcCbData *d = (RpcCbData *)userdata;
    RpcSession *s = d->session;

    cJSON *obj = cJSON_CreateObject();

    switch (e->type) {
    case EV_START:
        cJSON_AddStringToObject(obj, "type", "start");
        if (e->message) {
            cJSON_AddStringToObject(obj, "model",    e->message->model_id  ? e->message->model_id  : "");
            cJSON_AddStringToObject(obj, "provider", e->message->provider  ? e->message->provider  : "");
        }
        break;
    case EV_TEXT_START:
        cJSON_AddStringToObject(obj, "type", "textStart");
        cJSON_AddNumberToObject(obj, "index", e->index);
        break;
    case EV_TEXT_DELTA:
        cJSON_AddStringToObject(obj, "type", "textDelta");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "delta", e->delta ? e->delta : "");
        break;
    case EV_TEXT_END:
        cJSON_AddStringToObject(obj, "type", "textEnd");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "content", e->content ? e->content : "");
        break;
    case EV_THINKING_START:
        cJSON_AddStringToObject(obj, "type", "thinkingStart");
        cJSON_AddNumberToObject(obj, "index", e->index);
        break;
    case EV_THINKING_DELTA:
        cJSON_AddStringToObject(obj, "type", "thinkingDelta");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "delta", e->delta ? e->delta : "");
        break;
    case EV_THINKING_END:
        cJSON_AddStringToObject(obj, "type", "thinkingEnd");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "content", e->content ? e->content : "");
        break;
    case EV_TOOL_CALL_START:
        cJSON_AddStringToObject(obj, "type", "toolCallStart");
        cJSON_AddNumberToObject(obj, "index", e->index);
        break;
    case EV_TOOL_CALL_DELTA:
        cJSON_AddStringToObject(obj, "type", "toolCallDelta");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "delta", e->delta ? e->delta : "");
        break;
    case EV_TOOL_CALL_END:
        cJSON_AddStringToObject(obj, "type", "toolCallEnd");
        cJSON_AddNumberToObject(obj, "index", e->index);
        cJSON_AddStringToObject(obj, "id",        e->part_id        ? e->part_id        : "");
        cJSON_AddStringToObject(obj, "name",      e->part_name      ? e->part_name      : "");
        cJSON_AddStringToObject(obj, "arguments", e->part_arguments ? e->part_arguments : "");
        break;
    case EV_DONE:
    case EV_ERROR:
        {
            cJSON_AddStringToObject(obj, "type", e->type == EV_DONE ? "done" : "error");
            if (e->message) {
                cJSON_AddStringToObject(obj, "model",      e->message->model_id   ? e->message->model_id   : "");
                cJSON_AddStringToObject(obj, "provider",   e->message->provider   ? e->message->provider   : "");
                cJSON_AddStringToObject(obj, "stopReason", e->message->stop_reason ? e->message->stop_reason : "");
                cJSON *usage = cJSON_CreateObject();
                cJSON_AddNumberToObject(usage, "input",  e->message->usage_input);
                cJSON_AddNumberToObject(usage, "output", e->message->usage_output);
                cJSON_AddNumberToObject(usage, "cost",   e->message->cost_total);
                cJSON_AddItemToObject(obj, "usage", usage);
                if (e->message->error_message && e->message->error_message[0])
                    cJSON_AddStringToObject(obj, "errorMessage", e->message->error_message);
            }
        }
        break;
    default:
        cJSON_Delete(obj);
        return;
    }

    rpc_write_json(s, obj);
    cJSON_Delete(obj);
}

/* ---- Streaming thread ---- */

typedef struct {
    RpcSession *session;
    Context    *ctx;       /* owned by thread, freed after done */
    Model       model;     /* deep copy */
    StreamOptions opts;    /* deep copy */
} StreamThreadArg;

static Model model_copy(const Model *m) {
    Model r = {0};
    r.id               = m->id       ? xstrdup(m->id)       : NULL;
    r.name             = m->name     ? xstrdup(m->name)     : NULL;
    r.provider         = m->provider ? xstrdup(m->provider) : NULL;
    r.base_url         = m->base_url ? xstrdup(m->base_url) : NULL;
    r.context_window   = m->context_window;
    r.max_tokens       = m->max_tokens;
    r.cost             = m->cost;
    r.supports_thinking = m->supports_thinking;
    return r;
}

static void model_free_fields(Model *m) {
    free(m->id); free(m->name); free(m->provider); free(m->base_url);
}

static void *stream_thread(void *arg) {
    StreamThreadArg *a = (StreamThreadArg *)arg;
    RpcSession *s = a->session;

    RpcCbData cb_data = { .session = s };

    run_agent(
        s->config,
        &a->model,
        a->ctx,
        &a->opts,
        s->handler,
        s->handler_data,
        10,
        &s->abort_flag,
        rpc_event_cb,
        &cb_data
    );

    /* Append new messages from ctx to session history */
    pthread_mutex_lock(&s->mu);
    for (int i = 0; i < a->ctx->messages_len; i++) {
        ContextMessage *cm = &a->ctx->messages[i];
        /* Add to session messages */
        if (s->messages_len >= s->messages_cap) {
            s->messages_cap = s->messages_cap ? s->messages_cap * 2 : 16;
            s->messages = xrealloc(s->messages, (size_t)s->messages_cap * sizeof(ContextMessage));
        }
        /* Deep copy */
        ContextMessage dst = {0};
        dst.role         = cm->role         ? xstrdup(cm->role)         : NULL;
        dst.content      = cm->content      ? xstrdup(cm->content)      : NULL;
        dst.tool_call_id = cm->tool_call_id ? xstrdup(cm->tool_call_id) : NULL;
        for (int k = 0; k < cm->parts_len; k++) {
            ContentPart src = cm->parts[k];
            ContentPart p = {0};
            p.type      = src.type      ? xstrdup(src.type)      : NULL;
            p.text      = src.text      ? xstrdup(src.text)      : NULL;
            p.thinking  = src.thinking  ? xstrdup(src.thinking)  : NULL;
            p.id        = src.id        ? xstrdup(src.id)        : NULL;
            p.name      = src.name      ? xstrdup(src.name)      : NULL;
            p.arguments = src.arguments ? xstrdup(src.arguments) : NULL;
            if (dst.parts_len >= dst.parts_cap) {
                dst.parts_cap = dst.parts_cap ? dst.parts_cap * 2 : 4;
                dst.parts = xrealloc(dst.parts, (size_t)dst.parts_cap * sizeof(ContentPart));
            }
            dst.parts[dst.parts_len++] = p;
        }
        s->messages[s->messages_len++] = dst;
    }
    s->is_streaming = 0;
    s->abort_flag   = 0;
    pthread_mutex_unlock(&s->mu);

    /* Cleanup */
    context_free(a->ctx);
    model_free_fields(&a->model);
    stream_options_free(&a->opts);
    free(a);

    return NULL;
}

/* ---- Session helpers ---- */

static void session_push_user_msg(RpcSession *s, const char *text) {
    if (s->messages_len >= s->messages_cap) {
        s->messages_cap = s->messages_cap ? s->messages_cap * 2 : 16;
        s->messages = xrealloc(s->messages, (size_t)s->messages_cap * sizeof(ContextMessage));
    }
    ContextMessage m = {0};
    m.role    = xstrdup("user");
    m.content = xstrdup(text ? text : "");
    s->messages[s->messages_len++] = m;
}

/* ---- Model JSON for responses ---- */

static cJSON *model_to_json(const Model *m) {
    cJSON *j = cJSON_CreateObject();
    cJSON_AddStringToObject(j, "id",       m->id       ? m->id       : "");
    cJSON_AddStringToObject(j, "name",     m->name     ? m->name     : "");
    cJSON_AddStringToObject(j, "provider", m->provider ? m->provider : "");
    cJSON_AddStringToObject(j, "baseUrl",  m->base_url ? m->base_url : "");
    cJSON_AddNumberToObject(j, "contextWindow",   m->context_window);
    cJSON_AddNumberToObject(j, "maxTokens",       m->max_tokens);
    if (m->supports_thinking)
        cJSON_AddTrueToObject(j, "supportsThinking");
    else
        cJSON_AddFalseToObject(j, "supportsThinking");
    cJSON *cost = cJSON_CreateObject();
    cJSON_AddNumberToObject(cost, "input",  m->cost.input);
    cJSON_AddNumberToObject(cost, "output", m->cost.output);
    cJSON_AddItemToObject(j, "cost", cost);
    return j;
}

/* ---- ContextMessage to JSON ---- */

static cJSON *context_messages_to_json(const ContextMessage *msgs, int len) {
    cJSON *arr = cJSON_CreateArray();
    for (int i = 0; i < len; i++) {
        const ContextMessage *cm = &msgs[i];
        cJSON *m = cJSON_CreateObject();
        cJSON_AddStringToObject(m, "role", cm->role ? cm->role : "");
        if (cm->content)
            cJSON_AddStringToObject(m, "content", cm->content);
        if (cm->tool_call_id)
            cJSON_AddStringToObject(m, "toolCallId", cm->tool_call_id);
        if (cm->parts_len > 0) {
            cJSON *parts = cJSON_CreateArray();
            for (int k = 0; k < cm->parts_len; k++) {
                const ContentPart *p = &cm->parts[k];
                cJSON *pj = cJSON_CreateObject();
                cJSON_AddStringToObject(pj, "type", p->type ? p->type : "");
                if (p->text)      cJSON_AddStringToObject(pj, "text",      p->text);
                if (p->thinking)  cJSON_AddStringToObject(pj, "thinking",  p->thinking);
                if (p->id)        cJSON_AddStringToObject(pj, "id",        p->id);
                if (p->name)      cJSON_AddStringToObject(pj, "name",      p->name);
                if (p->arguments) cJSON_AddStringToObject(pj, "arguments", p->arguments);
                cJSON_AddItemToArray(parts, pj);
            }
            cJSON_AddItemToObject(m, "parts", parts);
        }
        cJSON_AddItemToArray(arr, m);
    }
    return arr;
}

/* ---- run_rpc ---- */

void run_rpc(
    const Config       *config,
    const Model        *initial_model,
    const StreamOptions *initial_opts,
    const char         *initial_system_prompt,
    ToolHandler         handler,
    void               *handler_data)
{
    RpcSession s = {0};
    pthread_mutex_init(&s.mu, NULL);
    pthread_mutex_init(&s.out_mu, NULL);

    char uuid[37]; gen_uuid(uuid);
    s.session_id = xstrdup(uuid);

    s.config       = config;
    s.model        = model_copy(initial_model);
    s.opts         = config_resolve(config, initial_opts, initial_model);
    s.system_prompt = xstrdup(initial_system_prompt ? initial_system_prompt : "");
    s.handler      = handler;
    s.handler_data = handler_data;

    /* Read line by line from stdin */
    char *line_buf = xmalloc(4 * 1024 * 1024);
    int   line_cap = 4 * 1024 * 1024;

    while (fgets(line_buf, line_cap, stdin)) {
        /* Strip newline */
        size_t ll = strlen(line_buf);
        while (ll > 0 && (line_buf[ll-1] == '\n' || line_buf[ll-1] == '\r')) line_buf[--ll] = '\0';
        if (ll == 0) continue;

        cJSON *cmd = cJSON_Parse(line_buf);
        if (!cmd) continue;

        cJSON *jtype = cJSON_GetObjectItemCaseSensitive(cmd, "type");
        cJSON *jid   = cJSON_GetObjectItemCaseSensitive(cmd, "id");
        const char *type = (jtype && cJSON_IsString(jtype)) ? jtype->valuestring : "";
        const char *id   = (jid   && cJSON_IsString(jid))   ? jid->valuestring   : "";

        if (strcmp(type, "prompt") == 0 || strcmp(type, "follow_up") == 0) {
            cJSON *jmsg = cJSON_GetObjectItemCaseSensitive(cmd, "message");
            const char *message = (jmsg && cJSON_IsString(jmsg)) ? jmsg->valuestring : "";

            pthread_mutex_lock(&s.mu);
            if (s.is_streaming) {
                pthread_mutex_unlock(&s.mu);
                rpc_respond(&s, id, type, NULL, "already streaming; send abort first");
                cJSON_Delete(cmd);
                continue;
            }

            /* Add user message to history */
            session_push_user_msg(&s, message);

            /* Build context snapshot */
            Context *ctx = context_new();
            ctx->system_prompt = xstrdup(s.system_prompt ? s.system_prompt : "");
            /* Copy all messages */
            for (int i = 0; i < s.messages_len; i++) {
                ContextMessage *cm = &s.messages[i];
                if (ctx->messages_len >= ctx->messages_cap) {
                    ctx->messages_cap = ctx->messages_cap ? ctx->messages_cap * 2 : 16;
                    ctx->messages = xrealloc(ctx->messages,
                        (size_t)ctx->messages_cap * sizeof(ContextMessage));
                }
                ContextMessage dst = {0};
                dst.role         = cm->role         ? xstrdup(cm->role)         : NULL;
                dst.content      = cm->content      ? xstrdup(cm->content)      : NULL;
                dst.tool_call_id = cm->tool_call_id ? xstrdup(cm->tool_call_id) : NULL;
                for (int k = 0; k < cm->parts_len; k++) {
                    ContentPart src = cm->parts[k];
                    ContentPart p = {0};
                    p.type      = src.type      ? xstrdup(src.type)      : NULL;
                    p.text      = src.text      ? xstrdup(src.text)      : NULL;
                    p.thinking  = src.thinking  ? xstrdup(src.thinking)  : NULL;
                    p.id        = src.id        ? xstrdup(src.id)        : NULL;
                    p.name      = src.name      ? xstrdup(src.name)      : NULL;
                    p.arguments = src.arguments ? xstrdup(src.arguments) : NULL;
                    if (dst.parts_len >= dst.parts_cap) {
                        dst.parts_cap = dst.parts_cap ? dst.parts_cap * 2 : 4;
                        dst.parts = xrealloc(dst.parts,
                            (size_t)dst.parts_cap * sizeof(ContentPart));
                    }
                    dst.parts[dst.parts_len++] = p;
                }
                ctx->messages[ctx->messages_len++] = dst;
            }

            s.is_streaming = 1;
            s.abort_flag   = 0;

            Model       thread_model = model_copy(&s.model);
            StreamOptions thread_opts = config_resolve(s.config, &s.opts, &s.model);
            pthread_mutex_unlock(&s.mu);

            /* Respond success before streaming starts */
            rpc_respond(&s, id, type, NULL, NULL);

            /* Launch streaming thread */
            StreamThreadArg *arg = xcalloc(1, sizeof(StreamThreadArg));
            arg->session = &s;
            arg->ctx     = ctx;
            arg->model   = thread_model;
            arg->opts    = thread_opts;

            pthread_t tid;
            pthread_create(&tid, NULL, stream_thread, arg);
            pthread_detach(tid);

        } else if (strcmp(type, "abort") == 0) {
            pthread_mutex_lock(&s.mu);
            s.abort_flag = 1;
            pthread_mutex_unlock(&s.mu);
            rpc_respond(&s, id, "abort", NULL, NULL);

        } else if (strcmp(type, "new_session") == 0) {
            pthread_mutex_lock(&s.mu);
            s.abort_flag = 1;
            /* Clear history */
            for (int i = 0; i < s.messages_len; i++)
                context_message_free(&s.messages[i]);
            s.messages_len = 0;
            free(s.system_prompt);
            s.system_prompt = xstrdup("");
            free(s.session_id);
            char newuuid[37]; gen_uuid(newuuid);
            s.session_id = xstrdup(newuuid);
            pthread_mutex_unlock(&s.mu);
            rpc_respond(&s, id, "new_session", NULL, NULL);

        } else if (strcmp(type, "get_state") == 0) {
            pthread_mutex_lock(&s.mu);
            cJSON *state = cJSON_CreateObject();
            cJSON *mj = model_to_json(&s.model);
            cJSON_AddItemToObject(state, "model", mj);
            if (s.is_streaming)
                cJSON_AddTrueToObject(state, "isStreaming");
            else
                cJSON_AddFalseToObject(state, "isStreaming");
            cJSON_AddStringToObject(state, "sessionId", s.session_id ? s.session_id : "");
            cJSON_AddNumberToObject(state, "messageCount", s.messages_len);
            pthread_mutex_unlock(&s.mu);
            rpc_respond(&s, id, "get_state", state, NULL);

        } else if (strcmp(type, "get_messages") == 0) {
            pthread_mutex_lock(&s.mu);
            cJSON *msgs_json = context_messages_to_json(s.messages, s.messages_len);
            pthread_mutex_unlock(&s.mu);
            cJSON *data = cJSON_CreateObject();
            cJSON_AddItemToObject(data, "messages", msgs_json);
            rpc_respond(&s, id, "get_messages", data, NULL);

        } else if (strcmp(type, "set_model") == 0) {
            cJSON *jprov = cJSON_GetObjectItemCaseSensitive(cmd, "provider");
            cJSON *jmid  = cJSON_GetObjectItemCaseSensitive(cmd, "modelId");
            const char *provider = (jprov && cJSON_IsString(jprov)) ? jprov->valuestring : "";
            const char *model_id = (jmid  && cJSON_IsString(jmid))  ? jmid->valuestring  : "";

            const Model *m = NULL;
            if (provider[0] && model_id[0])
                m = registry_find(config, provider, model_id);
            if (!m && model_id[0])
                m = registry_find_by_id(config, model_id);

            if (!m) {
                rpc_respond(&s, id, "set_model", NULL,
                    str_printf("model %s not found", model_id));
            } else {
                pthread_mutex_lock(&s.mu);
                model_free_fields(&s.model);
                s.model = model_copy(m);
                stream_options_free(&s.opts);
                s.opts = config_resolve(config, NULL, m);
                pthread_mutex_unlock(&s.mu);
                rpc_respond(&s, id, "set_model", model_to_json(m), NULL);
            }

        } else if (strcmp(type, "get_available_models") == 0) {
            cJSON *models_arr = cJSON_CreateArray();
            for (int i = 0; i < config->models.len; i++) {
                cJSON_AddItemToArray(models_arr, model_to_json(&config->models.data[i]));
            }
            cJSON *data = cJSON_CreateObject();
            cJSON_AddItemToObject(data, "models", models_arr);
            rpc_respond(&s, id, "get_available_models", data, NULL);

        } else if (strcmp(type, "set_system_prompt") == 0) {
            cJSON *jsp = cJSON_GetObjectItemCaseSensitive(cmd, "systemPrompt");
            const char *sp = (jsp && cJSON_IsString(jsp)) ? jsp->valuestring : "";
            pthread_mutex_lock(&s.mu);
            free(s.system_prompt);
            s.system_prompt = xstrdup(sp);
            pthread_mutex_unlock(&s.mu);
            rpc_respond(&s, id, "set_system_prompt", NULL, NULL);

        } else {
            char *errmsg = str_printf("unknown command: %s", type);
            rpc_respond(&s, id, type, NULL, errmsg);
            free(errmsg);
        }

        cJSON_Delete(cmd);
    }

    free(line_buf);
    /* Cleanup session */
    model_free_fields(&s.model);
    stream_options_free(&s.opts);
    free(s.system_prompt);
    free(s.session_id);
    for (int i = 0; i < s.messages_len; i++) context_message_free(&s.messages[i]);
    free(s.messages);
    pthread_mutex_destroy(&s.mu);
    pthread_mutex_destroy(&s.out_mu);
}
