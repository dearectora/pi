#pragma once
#include "openai.h"

/* Run text-mode output: print text deltas to stdout, thinking to stderr.
   Returns exit code (0 = success, 1 = error). */
int run_text_mode(EventCallback *dummy, AssistantMessage **final_msg_out, void *unused);

/* These are the actual callback-based runners used internally */

/* text mode state */
typedef struct {
    int had_text;
    AssistantMessage *final_msg;
    int exit_code;
} TextModeState;

void text_mode_cb(const WispEvent *e, void *userdata);

/* json mode state */
typedef struct {
    AssistantMessage *final_msg;
    int exit_code;
} JsonModeState;

void json_mode_cb(const WispEvent *e, void *userdata);

/* Encode a single event to a JSON line (heap-allocated, caller frees).
   Returns NULL for events that produce no output. */
char *encode_event_json(const WispEvent *e);
