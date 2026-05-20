#pragma once
#include "config.h"
#include <stddef.h>

/* --- ContentPart --- */
typedef struct {
    char *type;        /* "text", "thinking", "toolCall" */
    char *text;
    char *thinking;
    char *id;
    char *name;
    char *arguments;
} ContentPart;

/* --- AssistantMessage --- */
typedef struct {
    char        *role;          /* "assistant" */
    char        *model_id;
    char        *provider;
    ContentPart *content;
    int          content_len;
    int          content_cap;
    char        *stop_reason;   /* "stop","length","toolUse","error","aborted" */
    int          usage_input;
    int          usage_output;
    double       cost_input;
    double       cost_output;
    double       cost_total;
    char        *error_message;
} AssistantMessage;

void content_part_free(ContentPart *p);
void assistant_message_free(AssistantMessage *m);

/* --- ContextMessage --- */
typedef struct {
    char        *role;          /* "user","assistant","tool" */
    char        *content;       /* for user/tool */
    ContentPart *parts;         /* for assistant */
    int          parts_len;
    int          parts_cap;
    char        *tool_call_id;  /* for tool */
} ContextMessage;

void context_message_free(ContextMessage *m);

/* --- Tool --- */
typedef struct {
    char *name;
    char *description;
    char *parameters_json;
} Tool;

void tool_free(Tool *t);

/* --- Context --- */
typedef struct {
    char          *system_prompt;
    ContextMessage *messages;
    int             messages_len;
    int             messages_cap;
    Tool           *tools;
    int             tools_len;
    int             tools_cap;
} Context;

Context *context_new(void);
void context_free(Context *ctx);
void context_add_user_msg(Context *ctx, const char *text);
void context_add_assistant_msg(Context *ctx, const AssistantMessage *msg);
void context_add_tool_result(Context *ctx, const char *tool_call_id, const char *content);

/* --- Events --- */
typedef enum {
    EV_START,
    EV_TEXT_START,
    EV_TEXT_DELTA,
    EV_TEXT_END,
    EV_THINKING_START,
    EV_THINKING_DELTA,
    EV_THINKING_END,
    EV_TOOL_CALL_START,
    EV_TOOL_CALL_DELTA,
    EV_TOOL_CALL_END,
    EV_DONE,
    EV_ERROR
} EventType;

typedef struct {
    EventType        type;
    int              index;
    char            *delta;        /* valid only during callback (not owned) */
    char            *content;      /* valid only during callback (not owned) */
    /* for TOOL_CALL_END: */
    char            *part_id;
    char            *part_name;
    char            *part_arguments;
    /* for DONE/ERROR: owned by callback, caller should NOT free */
    AssistantMessage *message;
} WispEvent;

typedef void (*EventCallback)(const WispEvent *e, void *userdata);

/* --- stream_openai ---
   Calls cb for each event synchronously. The AssistantMessage in EV_DONE/EV_ERROR
   is heap-allocated and owned by the caller (free with assistant_message_free). */
AssistantMessage *stream_openai(
    const Model *model,
    const Context *ctx,
    const StreamOptions *opts,
    volatile int *abort_flag,  /* set to 1 to cancel */
    EventCallback cb,
    void *cb_data
);

/* Build a JSON request body (heap-allocated, caller frees) */
char *build_chat_request(const Model *model, const Context *ctx, const StreamOptions *opts);
