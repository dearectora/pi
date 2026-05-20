#include "logger.h"
#include "util.h"
#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>

static char *iso8601_now(void) {
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S.000Z", tm);
    return xstrdup(buf);
}

static int logger_append(SessionLogger *lg, cJSON *obj) {
    char *s = cJSON_PrintUnformatted(obj);
    if (!s) return -1;
    fprintf(lg->file, "%s\n", s);
    fflush(lg->file);
    free(s);
    return 0;
}

SessionLogger *logger_new(const Model *model) {
    /* sessions dir */
    char *agent_dir = config_agent_dir();
    char *sessions_dir = str_printf("%s/sessions", agent_dir);
    free(agent_dir);

    if (mkdirp(sessions_dir, 0755) < 0) {
        free(sessions_dir);
        return NULL;
    }

    /* session id */
    char uuid[37];
    gen_uuid(uuid);

    /* timestamp for filename */
    time_t t = time(NULL);
    struct tm *tm = gmtime(&t);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H-%M-%S-000Z", tm);

    char *path = str_printf("%s/%s_%s.jsonl", sessions_dir, ts, uuid);
    free(sessions_dir);

    FILE *f = fopen(path, "a");
    free(path);
    if (!f) return NULL;

    SessionLogger *lg = xcalloc(1, sizeof(SessionLogger));
    lg->file = f;

    /* header entry */
    char *now = iso8601_now();
    char cwd[4096] = ".";
    (void)!getcwd(cwd, sizeof(cwd));  /* ignore return */

    cJSON *hdr = cJSON_CreateObject();
    cJSON_AddStringToObject(hdr, "type",      "session");
    cJSON_AddNumberToObject(hdr, "version",   1);
    cJSON_AddStringToObject(hdr, "id",        uuid);
    cJSON_AddStringToObject(hdr, "timestamp", now);
    cJSON_AddStringToObject(hdr, "cwd",       cwd);
    cJSON_AddStringToObject(hdr, "tool",      "wisp");
    cJSON_AddStringToObject(hdr, "model",     model->id       ? model->id       : "");
    cJSON_AddStringToObject(hdr, "provider",  model->provider ? model->provider : "");
    free(now);

    logger_append(lg, hdr);
    cJSON_Delete(hdr);

    return lg;
}

int logger_log_user(SessionLogger *lg, const char *text) {
    if (!lg) return -1;
    char uuid[37]; gen_uuid(uuid);
    char *now = iso8601_now();

    cJSON *msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "role",    "user");
    cJSON_AddStringToObject(msg, "content", text ? text : "");

    cJSON *entry = cJSON_CreateObject();
    cJSON_AddStringToObject(entry, "type",      "message");
    cJSON_AddStringToObject(entry, "id",        uuid);
    cJSON_AddNullToObject(entry, "parentId");
    cJSON_AddStringToObject(entry, "timestamp", now);
    cJSON_AddItemToObject(entry, "message", msg);
    free(now);

    int r = logger_append(lg, entry);
    cJSON_Delete(entry);

    if (r == 0) {
        free(lg->last_message_id);
        lg->last_message_id = xstrdup(uuid);
    }
    return r;
}

int logger_log_assistant(SessionLogger *lg, const AssistantMessage *amsg) {
    if (!lg) return -1;

    char uuid[37]; gen_uuid(uuid);
    char *now = iso8601_now();

    cJSON *content = cJSON_CreateArray();
    for (int i = 0; i < amsg->content_len; i++) {
        const ContentPart *p = &amsg->content[i];
        cJSON *cp = cJSON_CreateObject();
        if (p->type && strcmp(p->type, "text") == 0) {
            cJSON_AddStringToObject(cp, "type", "text");
            cJSON_AddStringToObject(cp, "text", p->text ? p->text : "");
        } else if (p->type && strcmp(p->type, "thinking") == 0) {
            cJSON_AddStringToObject(cp, "type", "thinking");
            cJSON_AddStringToObject(cp, "thinking", p->thinking ? p->thinking : "");
        } else if (p->type && strcmp(p->type, "toolCall") == 0) {
            cJSON_AddStringToObject(cp, "type",      "tool_call");
            cJSON_AddStringToObject(cp, "id",        p->id        ? p->id        : "");
            cJSON_AddStringToObject(cp, "name",      p->name      ? p->name      : "");
            cJSON_AddStringToObject(cp, "arguments", p->arguments ? p->arguments : "");
        }
        cJSON_AddItemToArray(content, cp);
    }

    cJSON *usage = cJSON_CreateObject();
    cJSON_AddNumberToObject(usage, "input",  amsg->usage_input);
    cJSON_AddNumberToObject(usage, "output", amsg->usage_output);
    cJSON_AddNumberToObject(usage, "cost",   amsg->cost_total);

    cJSON *msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "role",       "assistant");
    cJSON_AddStringToObject(msg, "model",      amsg->model_id   ? amsg->model_id   : "");
    cJSON_AddStringToObject(msg, "provider",   amsg->provider   ? amsg->provider   : "");
    cJSON_AddStringToObject(msg, "stopReason", amsg->stop_reason ? amsg->stop_reason : "");
    cJSON_AddItemToObject(msg, "usage",   usage);
    cJSON_AddItemToObject(msg, "content", content);
    if (amsg->error_message && amsg->error_message[0])
        cJSON_AddStringToObject(msg, "errorMessage", amsg->error_message);

    cJSON *entry = cJSON_CreateObject();
    cJSON_AddStringToObject(entry, "type",      "message");
    cJSON_AddStringToObject(entry, "id",        uuid);
    if (lg->last_message_id && lg->last_message_id[0])
        cJSON_AddStringToObject(entry, "parentId", lg->last_message_id);
    else
        cJSON_AddNullToObject(entry, "parentId");
    cJSON_AddStringToObject(entry, "timestamp", now);
    cJSON_AddItemToObject(entry, "message", msg);
    free(now);

    int r = logger_append(lg, entry);
    cJSON_Delete(entry);

    if (r == 0) {
        free(lg->last_message_id);
        lg->last_message_id = xstrdup(uuid);
    }
    return r;
}

void logger_free(SessionLogger *lg) {
    if (!lg) return;
    if (lg->file) fclose(lg->file);
    free(lg->last_message_id);
    free(lg);
}
