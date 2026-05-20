#include "openai.h"
#include "util.h"
#include "cJSON.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <time.h>

/* ---- ContentPart ---- */

void content_part_free(ContentPart *p) {
    if (!p) return;
    free(p->type); free(p->text); free(p->thinking);
    free(p->id); free(p->name); free(p->arguments);
}

static void content_part_init(ContentPart *p, const char *type) {
    memset(p, 0, sizeof(*p));
    p->type = xstrdup(type);
}

/* ---- AssistantMessage ---- */

void assistant_message_free(AssistantMessage *m) {
    if (!m) return;
    free(m->role); free(m->model_id); free(m->provider);
    for (int i = 0; i < m->content_len; i++) content_part_free(&m->content[i]);
    free(m->content);
    free(m->stop_reason); free(m->error_message);
    free(m);
}

static AssistantMessage *assistant_message_new(const Model *model) {
    AssistantMessage *m = xcalloc(1, sizeof(AssistantMessage));
    m->role      = xstrdup("assistant");
    m->model_id  = xstrdup(model->id ? model->id : "");
    m->provider  = xstrdup(model->provider ? model->provider : "");
    m->stop_reason = xstrdup("stop");
    return m;
}

static void msg_push_part(AssistantMessage *m, ContentPart p) {
    if (m->content_len >= m->content_cap) {
        m->content_cap = m->content_cap ? m->content_cap * 2 : 4;
        m->content = xrealloc(m->content, (size_t)m->content_cap * sizeof(ContentPart));
    }
    m->content[m->content_len++] = p;
}

static void msg_set_stop(AssistantMessage *m, const char *reason) {
    free(m->stop_reason);
    m->stop_reason = xstrdup(reason);
}

/* ---- ContextMessage ---- */

void context_message_free(ContextMessage *m) {
    if (!m) return;
    free(m->role); free(m->content);
    for (int i = 0; i < m->parts_len; i++) content_part_free(&m->parts[i]);
    free(m->parts);
    free(m->tool_call_id);
}

static void cm_push_part(ContextMessage *m, ContentPart p) {
    if (m->parts_len >= m->parts_cap) {
        m->parts_cap = m->parts_cap ? m->parts_cap * 2 : 4;
        m->parts = xrealloc(m->parts, (size_t)m->parts_cap * sizeof(ContentPart));
    }
    m->parts[m->parts_len++] = p;
}

/* ---- Tool ---- */

void tool_free(Tool *t) {
    if (!t) return;
    free(t->name); free(t->description); free(t->parameters_json);
}

/* ---- Context ---- */

Context *context_new(void) {
    return xcalloc(1, sizeof(Context));
}

void context_free(Context *ctx) {
    if (!ctx) return;
    free(ctx->system_prompt);
    for (int i = 0; i < ctx->messages_len; i++) context_message_free(&ctx->messages[i]);
    free(ctx->messages);
    for (int i = 0; i < ctx->tools_len; i++) tool_free(&ctx->tools[i]);
    free(ctx->tools);
    free(ctx);
}

static ContextMessage *ctx_new_msg(Context *ctx) {
    if (ctx->messages_len >= ctx->messages_cap) {
        ctx->messages_cap = ctx->messages_cap ? ctx->messages_cap * 2 : 8;
        ctx->messages = xrealloc(ctx->messages,
            (size_t)ctx->messages_cap * sizeof(ContextMessage));
    }
    ContextMessage *m = &ctx->messages[ctx->messages_len++];
    memset(m, 0, sizeof(*m));
    return m;
}

void context_add_user_msg(Context *ctx, const char *text) {
    ContextMessage *m = ctx_new_msg(ctx);
    m->role    = xstrdup("user");
    m->content = xstrdup(text ? text : "");
}

void context_add_assistant_msg(Context *ctx, const AssistantMessage *msg) {
    ContextMessage *m = ctx_new_msg(ctx);
    m->role = xstrdup("assistant");
    for (int i = 0; i < msg->content_len; i++) {
        ContentPart src = msg->content[i];
        ContentPart dst;
        memset(&dst, 0, sizeof(dst));
        dst.type      = src.type      ? xstrdup(src.type)      : NULL;
        dst.text      = src.text      ? xstrdup(src.text)      : NULL;
        dst.thinking  = src.thinking  ? xstrdup(src.thinking)  : NULL;
        dst.id        = src.id        ? xstrdup(src.id)        : NULL;
        dst.name      = src.name      ? xstrdup(src.name)      : NULL;
        dst.arguments = src.arguments ? xstrdup(src.arguments) : NULL;
        cm_push_part(m, dst);
    }
}

void context_add_tool_result(Context *ctx, const char *tool_call_id, const char *content) {
    ContextMessage *m = ctx_new_msg(ctx);
    m->role         = xstrdup("tool");
    m->content      = xstrdup(content ? content : "");
    m->tool_call_id = xstrdup(tool_call_id ? tool_call_id : "");
}

/* ---- build_chat_request ---- */

char *build_chat_request(const Model *model, const Context *ctx, const StreamOptions *opts) {
    cJSON *root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "model", model->id ? model->id : "");
    cJSON_AddBoolToObject(root, "stream", cJSON_True);

    /* stream_options */
    cJSON *so = cJSON_CreateObject();
    cJSON_AddBoolToObject(so, "include_usage", cJSON_True);
    cJSON_AddItemToObject(root, "stream_options", so);

    if (opts && opts->temperature) {
        cJSON_AddNumberToObject(root, "temperature", *opts->temperature);
    }
    if (opts && opts->max_tokens) {
        cJSON_AddNumberToObject(root, "max_tokens", *opts->max_tokens);
    }

    /* messages array */
    cJSON *messages = cJSON_CreateArray();

    if (ctx->system_prompt && ctx->system_prompt[0]) {
        cJSON *sm = cJSON_CreateObject();
        cJSON_AddStringToObject(sm, "role", "system");
        cJSON_AddStringToObject(sm, "content", ctx->system_prompt);
        cJSON_AddItemToArray(messages, sm);
    }

    for (int i = 0; i < ctx->messages_len; i++) {
        const ContextMessage *cm = &ctx->messages[i];
        cJSON *jm = cJSON_CreateObject();

        if (strcmp(cm->role, "user") == 0) {
            cJSON_AddStringToObject(jm, "role", "user");
            cJSON_AddStringToObject(jm, "content", cm->content ? cm->content : "");
        } else if (strcmp(cm->role, "assistant") == 0) {
            cJSON_AddStringToObject(jm, "role", "assistant");
            /* collect text parts and tool_calls */
            char *text_buf = NULL;
            cJSON *tool_calls = cJSON_CreateArray();
            for (int k = 0; k < cm->parts_len; k++) {
                const ContentPart *p = &cm->parts[k];
                if (p->type && strcmp(p->type, "text") == 0) {
                    text_buf = str_append(text_buf, p->text ? p->text : "");
                } else if (p->type && strcmp(p->type, "toolCall") == 0) {
                    cJSON *tc = cJSON_CreateObject();
                    cJSON_AddStringToObject(tc, "id", p->id ? p->id : "");
                    cJSON_AddStringToObject(tc, "type", "function");
                    cJSON *fn = cJSON_CreateObject();
                    cJSON_AddStringToObject(fn, "name", p->name ? p->name : "");
                    cJSON_AddStringToObject(fn, "arguments", p->arguments ? p->arguments : "");
                    cJSON_AddItemToObject(tc, "function", fn);
                    cJSON_AddItemToArray(tool_calls, tc);
                }
            }
            if (text_buf && text_buf[0]) {
                cJSON_AddStringToObject(jm, "content", text_buf);
            }
            free(text_buf);
            if (cJSON_GetArraySize(tool_calls) > 0) {
                cJSON_AddItemToObject(jm, "tool_calls", tool_calls);
            } else {
                cJSON_Delete(tool_calls);
            }
        } else if (strcmp(cm->role, "tool") == 0) {
            cJSON_AddStringToObject(jm, "role", "tool");
            cJSON_AddStringToObject(jm, "content", cm->content ? cm->content : "");
            cJSON_AddStringToObject(jm, "tool_call_id", cm->tool_call_id ? cm->tool_call_id : "");
        }

        cJSON_AddItemToArray(messages, jm);
    }

    cJSON_AddItemToObject(root, "messages", messages);

    /* tools */
    if (ctx->tools_len > 0) {
        cJSON *tools_arr = cJSON_CreateArray();
        for (int i = 0; i < ctx->tools_len; i++) {
            const Tool *t = &ctx->tools[i];
            cJSON *tw = cJSON_CreateObject();
            cJSON_AddStringToObject(tw, "type", "function");
            cJSON *fn = cJSON_CreateObject();
            cJSON_AddStringToObject(fn, "name", t->name ? t->name : "");
            if (t->description && t->description[0])
                cJSON_AddStringToObject(fn, "description", t->description);
            /* parameters: parse existing JSON or use empty object */
            const char *params_str = t->parameters_json && t->parameters_json[0]
                ? t->parameters_json
                : "{\"type\":\"object\",\"properties\":{}}";
            cJSON *params = cJSON_Parse(params_str);
            if (!params) params = cJSON_CreateObject();
            cJSON_AddItemToObject(fn, "parameters", params);
            cJSON_AddItemToObject(tw, "function", fn);
            cJSON_AddItemToArray(tools_arr, tw);
        }
        cJSON_AddItemToObject(root, "tools", tools_arr);
    }

    char *result = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    return result; /* caller frees */
}

/* ---- SSE streaming state ---- */

#define MAX_TOOL_BLOCKS 64

typedef struct {
    int  sse_index;
    int  content_index; /* index in msg->content */
    char *id;
    char *name;
    char *arg_buf;      /* accumulated arguments */
    size_t arg_len;
    size_t arg_cap;
} ToolBlock;

typedef struct {
    int started;
    int idx;
    char *buf;
    size_t len;
    size_t cap;
} TextBlock;

static void tb_append(TextBlock *tb, const char *s) {
    size_t sl = strlen(s);
    if (tb->len + sl + 1 > tb->cap) {
        tb->cap = tb->cap ? tb->cap * 2 : 256;
        while (tb->cap < tb->len + sl + 1) tb->cap *= 2;
        tb->buf = xrealloc(tb->buf, tb->cap);
    }
    memcpy(tb->buf + tb->len, s, sl + 1);
    tb->len += sl;
}

static void tb_free(TextBlock *tb) { free(tb->buf); }

static void tool_block_append(ToolBlock *tb, const char *s) {
    size_t sl = strlen(s);
    if (tb->arg_len + sl + 1 > tb->arg_cap) {
        tb->arg_cap = tb->arg_cap ? tb->arg_cap * 2 : 256;
        while (tb->arg_cap < tb->arg_len + sl + 1) tb->arg_cap *= 2;
        tb->arg_buf = xrealloc(tb->arg_buf, tb->arg_cap);
    }
    memcpy(tb->arg_buf + tb->arg_len, s, sl + 1);
    tb->arg_len += sl;
}

static void tool_block_free(ToolBlock *tb) {
    free(tb->id); free(tb->name); free(tb->arg_buf);
}

static ToolBlock *find_tool_block(ToolBlock *blocks, int *count, int sse_index) {
    for (int i = 0; i < *count; i++) {
        if (blocks[i].sse_index == sse_index) return &blocks[i];
    }
    if (*count >= MAX_TOOL_BLOCKS) return NULL;
    ToolBlock *b = &blocks[(*count)++];
    memset(b, 0, sizeof(*b));
    b->sse_index = sse_index;
    return b;
}

/* ---- stream_openai ---- */

AssistantMessage *stream_openai(
    const Model *model,
    const Context *ctx,
    const StreamOptions *opts,
    volatile int *abort_flag,
    EventCallback cb,
    void *cb_data)
{
    AssistantMessage *msg = assistant_message_new(model);

    /* Emit start event */
    if (cb) {
        WispEvent e = {0};
        e.type    = EV_START;
        e.message = msg;
        cb(&e, cb_data);
    }

    /* Build request body */
    char *body = build_chat_request(model, ctx, opts);
    if (!body) {
        msg_set_stop(msg, "error");
        free(msg->error_message);
        msg->error_message = xstrdup("failed to build request");
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        return msg;
    }

    /* Write body to temp file */
    char *tmpfile = write_tempfile(body, strlen(body));
    free(body);
    if (!tmpfile) {
        msg_set_stop(msg, "error");
        free(msg->error_message);
        msg->error_message = xstrdup("failed to write temp file");
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        return msg;
    }

    /* Build URL */
    const char *base = model->base_url ? model->base_url : "";
    /* trim trailing slash */
    size_t blen = strlen(base);
    while (blen > 0 && base[blen-1] == '/') blen--;
    char *url = str_printf("%.*s/chat/completions", (int)blen, base);

    /* Validate URL */
    if (strncmp(url, "http://", 7) != 0 && strncmp(url, "https://", 8) != 0) {
        msg_set_stop(msg, "error");
        free(msg->error_message);
        msg->error_message = str_printf("invalid base_url: %s", base);
        free(url); unlink(tmpfile); free(tmpfile);
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        return msg;
    }

    const char *api_key = (opts && opts->api_key) ? opts->api_key : "";
    char *esc_url = shell_escape_sq(url);
    char *esc_key = shell_escape_sq(api_key);
    free(url);

    char *cmd = str_printf(
        "curl -s -N --no-buffer "
        "-H 'Content-Type: application/json' "
        "-H 'Authorization: Bearer %s' "
        "-H 'Accept: text/event-stream' "
        "--data @'%s' "
        "'%s'",
        esc_key, tmpfile, esc_url);
    free(esc_key);
    free(esc_url);

    FILE *pipe = popen(cmd, "r");
    free(cmd);

    if (!pipe) {
        msg_set_stop(msg, "error");
        free(msg->error_message);
        msg->error_message = xstrdup("popen failed");
        unlink(tmpfile); free(tmpfile);
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        return msg;
    }

    /* SSE parsing state */
    TextBlock text     = {0};
    TextBlock thinking = {0};
    ToolBlock tool_blocks[MAX_TOOL_BLOCKS];
    int tool_count = 0;
    memset(tool_blocks, 0, sizeof(tool_blocks));

    /* Line buffer */
    char *line_buf = xmalloc(65536);
    int   line_cap = 65536;
    int   line_len = 0;

    int aborted = 0;
    int got_http_error = 0;

    /* Read char by char to handle arbitrary line lengths */
    int c;
    while ((c = fgetc(pipe)) != EOF) {
        if (abort_flag && *abort_flag) {
            aborted = 1;
            break;
        }

        if (c == '\n') {
            line_buf[line_len] = '\0';

            /* Process line */
            if (strncmp(line_buf, "data: ", 6) == 0) {
                const char *data = line_buf + 6;

                if (strcmp(data, "[DONE]") == 0) {
                    break;
                }

                cJSON *chunk = cJSON_Parse(data);
                if (!chunk) { line_len = 0; continue; }

                /* Check for HTTP error embedded in JSON (some providers do this) */
                cJSON *jerr = cJSON_GetObjectItemCaseSensitive(chunk, "error");
                if (jerr) {
                    cJSON *jmsg = cJSON_GetObjectItemCaseSensitive(jerr, "message");
                    const char *emsg = (jmsg && cJSON_IsString(jmsg)) ? jmsg->valuestring : "HTTP error";
                    msg_set_stop(msg, "error");
                    free(msg->error_message);
                    msg->error_message = xstrdup(emsg);
                    cJSON_Delete(chunk);
                    got_http_error = 1;
                    break;
                }

                /* model field */
                cJSON *jmodel = cJSON_GetObjectItemCaseSensitive(chunk, "model");
                if (jmodel && cJSON_IsString(jmodel) && jmodel->valuestring[0]) {
                    free(msg->model_id);
                    msg->model_id = xstrdup(jmodel->valuestring);
                }

                /* usage */
                cJSON *jusage = cJSON_GetObjectItemCaseSensitive(chunk, "usage");
                if (jusage) {
                    cJSON *jpt = cJSON_GetObjectItemCaseSensitive(jusage, "prompt_tokens");
                    cJSON *jct = cJSON_GetObjectItemCaseSensitive(jusage, "completion_tokens");
                    if (jpt && cJSON_IsNumber(jpt)) msg->usage_input  = (int)jpt->valuedouble;
                    if (jct && cJSON_IsNumber(jct)) msg->usage_output = (int)jct->valuedouble;
                    double in_cost  = (double)msg->usage_input  / 1000000.0 * model->cost.input;
                    double out_cost = (double)msg->usage_output / 1000000.0 * model->cost.output;
                    msg->cost_input  = in_cost;
                    msg->cost_output = out_cost;
                    msg->cost_total  = in_cost + out_cost;
                }

                /* choices */
                cJSON *choices = cJSON_GetObjectItemCaseSensitive(chunk, "choices");
                cJSON *choice = NULL;
                cJSON_ArrayForEach(choice, choices) {
                    cJSON *delta = cJSON_GetObjectItemCaseSensitive(choice, "delta");
                    if (!delta) continue;

                    /* reasoning_content (DeepSeek) */
                    cJSON *jreason = cJSON_GetObjectItemCaseSensitive(delta, "reasoning_content");
                    if (jreason && cJSON_IsString(jreason) && jreason->valuestring[0]) {
                        if (!thinking.started) {
                            thinking.started = 1;
                            thinking.idx = msg->content_len;
                            ContentPart p; content_part_init(&p, "thinking");
                            msg_push_part(msg, p);
                            if (cb) {
                                WispEvent e = {0};
                                e.type  = EV_THINKING_START;
                                e.index = thinking.idx;
                                cb(&e, cb_data);
                            }
                        }
                        tb_append(&thinking, jreason->valuestring);
                        free(msg->content[thinking.idx].thinking);
                        msg->content[thinking.idx].thinking = xstrdup(thinking.buf);
                        if (cb) {
                            WispEvent e = {0};
                            e.type  = EV_THINKING_DELTA;
                            e.index = thinking.idx;
                            e.delta = jreason->valuestring;
                            cb(&e, cb_data);
                        }
                    }

                    /* content */
                    cJSON *jcontent = cJSON_GetObjectItemCaseSensitive(delta, "content");
                    if (jcontent && cJSON_IsString(jcontent) && jcontent->valuestring[0]) {
                        if (!text.started) {
                            text.started = 1;
                            text.idx = msg->content_len;
                            ContentPart p; content_part_init(&p, "text");
                            msg_push_part(msg, p);
                            if (cb) {
                                WispEvent e = {0};
                                e.type  = EV_TEXT_START;
                                e.index = text.idx;
                                cb(&e, cb_data);
                            }
                        }
                        tb_append(&text, jcontent->valuestring);
                        free(msg->content[text.idx].text);
                        msg->content[text.idx].text = xstrdup(text.buf);
                        if (cb) {
                            WispEvent e = {0};
                            e.type  = EV_TEXT_DELTA;
                            e.index = text.idx;
                            e.delta = jcontent->valuestring;
                            cb(&e, cb_data);
                        }
                    }

                    /* tool_calls */
                    cJSON *jtcs = cJSON_GetObjectItemCaseSensitive(delta, "tool_calls");
                    cJSON *jtc = NULL;
                    cJSON_ArrayForEach(jtc, jtcs) {
                        cJSON *jidx = cJSON_GetObjectItemCaseSensitive(jtc, "index");
                        int sse_idx = jidx ? (int)jidx->valuedouble : 0;

                        ToolBlock *blk = find_tool_block(tool_blocks, &tool_count, sse_idx);
                        if (!blk) continue;

                        int is_new = (blk->content_index == 0 && blk->id == NULL && blk->name == NULL);
                        if (is_new && tool_count > 1) is_new = 0; /* only truly new if first encounter */
                        /* detect new: arg_buf == NULL and we haven't set content_index yet */
                        int truly_new = (blk->arg_buf == NULL && blk->id == NULL && blk->name == NULL);

                        cJSON *jtcid = cJSON_GetObjectItemCaseSensitive(jtc, "id");
                        cJSON *jfn   = cJSON_GetObjectItemCaseSensitive(jtc, "function");
                        cJSON *jname = jfn ? cJSON_GetObjectItemCaseSensitive(jfn, "name") : NULL;
                        cJSON *jargs = jfn ? cJSON_GetObjectItemCaseSensitive(jfn, "arguments") : NULL;

                        if (truly_new) {
                            blk->content_index = msg->content_len;
                            const char *tid  = (jtcid && cJSON_IsString(jtcid)) ? jtcid->valuestring : "";
                            const char *tnam = (jname && cJSON_IsString(jname)) ? jname->valuestring : "";
                            blk->id   = xstrdup(tid);
                            blk->name = xstrdup(tnam);
                            ContentPart p; content_part_init(&p, "toolCall");
                            p.id   = xstrdup(tid);
                            p.name = xstrdup(tnam);
                            msg_push_part(msg, p);
                            if (cb) {
                                WispEvent e = {0};
                                e.type  = EV_TOOL_CALL_START;
                                e.index = sse_idx;
                                cb(&e, cb_data);
                            }
                        }

                        /* update id/name if provided */
                        if (jtcid && cJSON_IsString(jtcid) && jtcid->valuestring[0]) {
                            free(blk->id);
                            blk->id = xstrdup(jtcid->valuestring);
                            free(msg->content[blk->content_index].id);
                            msg->content[blk->content_index].id = xstrdup(jtcid->valuestring);
                        }
                        if (jname && cJSON_IsString(jname) && jname->valuestring[0]) {
                            free(blk->name);
                            blk->name = xstrdup(jname->valuestring);
                            free(msg->content[blk->content_index].name);
                            msg->content[blk->content_index].name = xstrdup(jname->valuestring);
                        }

                        /* arguments delta */
                        if (jargs && cJSON_IsString(jargs) && jargs->valuestring[0]) {
                            tool_block_append(blk, jargs->valuestring);
                            free(msg->content[blk->content_index].arguments);
                            msg->content[blk->content_index].arguments = xstrdup(blk->arg_buf);
                            if (cb) {
                                WispEvent e = {0};
                                e.type  = EV_TOOL_CALL_DELTA;
                                e.index = sse_idx;
                                e.delta = jargs->valuestring;
                                cb(&e, cb_data);
                            }
                        }
                    }

                    /* finish_reason */
                    cJSON *jfr = cJSON_GetObjectItemCaseSensitive(choice, "finish_reason");
                    if (jfr && cJSON_IsString(jfr)) {
                        const char *fr = jfr->valuestring;
                        if (strcmp(fr, "stop") == 0)        msg_set_stop(msg, "stop");
                        else if (strcmp(fr, "length") == 0) msg_set_stop(msg, "length");
                        else if (strcmp(fr, "tool_calls") == 0) msg_set_stop(msg, "toolUse");
                    }
                }

                cJSON_Delete(chunk);
            }
            /* else: skip non-data lines */

            line_len = 0;
        } else {
            /* accumulate */
            if (line_len + 2 >= line_cap) {
                line_cap *= 2;
                line_buf = xrealloc(line_buf, (size_t)line_cap);
            }
            line_buf[line_len++] = (char)c;
        }
    }

    free(line_buf);
    pclose(pipe);
    unlink(tmpfile);
    free(tmpfile);

    if (aborted) {
        msg_set_stop(msg, "aborted");
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        tb_free(&text); tb_free(&thinking);
        for (int i = 0; i < tool_count; i++) tool_block_free(&tool_blocks[i]);
        return msg;
    }

    if (got_http_error) {
        if (cb) {
            WispEvent e = {0}; e.type = EV_ERROR; e.message = msg;
            cb(&e, cb_data);
        }
        tb_free(&text); tb_free(&thinking);
        for (int i = 0; i < tool_count; i++) tool_block_free(&tool_blocks[i]);
        return msg;
    }

    /* Emit *End events */
    if (text.started) {
        if (cb) {
            WispEvent e = {0};
            e.type    = EV_TEXT_END;
            e.index   = text.idx;
            e.content = text.buf ? text.buf : "";
            cb(&e, cb_data);
        }
    }
    if (thinking.started) {
        if (cb) {
            WispEvent e = {0};
            e.type    = EV_THINKING_END;
            e.index   = thinking.idx;
            e.content = thinking.buf ? thinking.buf : "";
            cb(&e, cb_data);
        }
    }
    for (int i = 0; i < tool_count; i++) {
        ToolBlock *blk = &tool_blocks[i];
        if (cb) {
            WispEvent e = {0};
            e.type           = EV_TOOL_CALL_END;
            e.index          = blk->sse_index;
            e.part_id        = blk->id ? blk->id : "";
            e.part_name      = blk->name ? blk->name : "";
            e.part_arguments = blk->arg_buf ? blk->arg_buf : "";
            cb(&e, cb_data);
        }
    }

    if (cb) {
        WispEvent e = {0}; e.type = EV_DONE; e.message = msg;
        cb(&e, cb_data);
    }

    tb_free(&text);
    tb_free(&thinking);
    for (int i = 0; i < tool_count; i++) tool_block_free(&tool_blocks[i]);

    return msg;
}
