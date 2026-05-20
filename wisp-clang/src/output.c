#include "output.h"
#include "util.h"
#include "cJSON.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- text mode ---- */

void text_mode_cb(const WispEvent *e, void *userdata) {
    TextModeState *s = (TextModeState *)userdata;

    switch (e->type) {
    case EV_TEXT_DELTA:
        if (e->delta) {
            fputs(e->delta, stdout);
            fflush(stdout);
            s->had_text = 1;
        }
        break;
    case EV_THINKING_DELTA:
        if (e->delta) {
            fputs(e->delta, stderr);
            fflush(stderr);
        }
        break;
    case EV_DONE:
        if (s->had_text) {
            fputc('\n', stdout);
            fflush(stdout);
        }
        s->final_msg  = e->message;
        s->exit_code  = 0;
        break;
    case EV_ERROR:
        {
            const char *desc = "unknown error";
            if (e->message && e->message->error_message && e->message->error_message[0])
                desc = e->message->error_message;
            fprintf(stderr, "\nError: %s\n", desc);
            s->final_msg  = e->message;
            s->exit_code  = 1;
        }
        break;
    default:
        break;
    }
}

/* ---- json mode ---- */

char *encode_event_json(const WispEvent *e) {
    cJSON *d = NULL;

    switch (e->type) {
    case EV_START:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "start");
        if (e->message) {
            cJSON_AddStringToObject(d, "model",    e->message->model_id  ? e->message->model_id  : "");
            cJSON_AddStringToObject(d, "provider", e->message->provider  ? e->message->provider  : "");
        }
        break;
    case EV_TEXT_START:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "textStart");
        cJSON_AddNumberToObject(d, "index", e->index);
        break;
    case EV_TEXT_DELTA:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "textDelta");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "delta", e->delta ? e->delta : "");
        break;
    case EV_TEXT_END:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "textEnd");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "content", e->content ? e->content : "");
        break;
    case EV_THINKING_START:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "thinkingStart");
        cJSON_AddNumberToObject(d, "index", e->index);
        break;
    case EV_THINKING_DELTA:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "thinkingDelta");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "delta", e->delta ? e->delta : "");
        break;
    case EV_THINKING_END:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "thinkingEnd");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "content", e->content ? e->content : "");
        break;
    case EV_TOOL_CALL_START:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "toolCallStart");
        cJSON_AddNumberToObject(d, "index", e->index);
        break;
    case EV_TOOL_CALL_DELTA:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "toolCallDelta");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "delta", e->delta ? e->delta : "");
        break;
    case EV_TOOL_CALL_END:
        d = cJSON_CreateObject();
        cJSON_AddStringToObject(d, "type", "toolCallEnd");
        cJSON_AddNumberToObject(d, "index", e->index);
        cJSON_AddStringToObject(d, "id",        e->part_id        ? e->part_id        : "");
        cJSON_AddStringToObject(d, "name",      e->part_name      ? e->part_name      : "");
        cJSON_AddStringToObject(d, "arguments", e->part_arguments ? e->part_arguments : "");
        break;
    case EV_DONE:
    case EV_ERROR:
        {
            d = cJSON_CreateObject();
            cJSON_AddStringToObject(d, "type", e->type == EV_DONE ? "done" : "error");
            if (e->message) {
                cJSON_AddStringToObject(d, "model",      e->message->model_id   ? e->message->model_id   : "");
                cJSON_AddStringToObject(d, "provider",   e->message->provider   ? e->message->provider   : "");
                cJSON_AddStringToObject(d, "stopReason", e->message->stop_reason ? e->message->stop_reason : "");
                cJSON *usage = cJSON_CreateObject();
                cJSON_AddNumberToObject(usage, "input",  e->message->usage_input);
                cJSON_AddNumberToObject(usage, "output", e->message->usage_output);
                cJSON_AddNumberToObject(usage, "cost",   e->message->cost_total);
                cJSON_AddItemToObject(d, "usage", usage);
                if (e->message->error_message && e->message->error_message[0])
                    cJSON_AddStringToObject(d, "errorMessage", e->message->error_message);
            }
        }
        break;
    default:
        return NULL;
    }

    if (!d) return NULL;
    char *s = cJSON_PrintUnformatted(d);
    cJSON_Delete(d);
    return s;
}

void json_mode_cb(const WispEvent *e, void *userdata) {
    JsonModeState *s = (JsonModeState *)userdata;

    char *line = encode_event_json(e);
    if (line) {
        puts(line);
        fflush(stdout);
        free(line);
    }

    if (e->type == EV_DONE) {
        s->final_msg = e->message;
        s->exit_code = 0;
    } else if (e->type == EV_ERROR) {
        s->final_msg = e->message;
        s->exit_code = 1;
    }
}
