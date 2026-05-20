#pragma once
#include "config.h"
#include "openai.h"

/* ToolHandler: called by the agent to execute a tool call.
   Returns heap-allocated result string. Caller frees.
   A result starting with "error: " signals a tool error. */
typedef char *(*ToolHandler)(const char *tool_name, const char *arguments, void *userdata);

/* run_agent: run the agent loop.
   - ctx: context with messages; new messages are appended during the loop.
   - max_steps: 0 = default 10
   - cb / cb_data: called for every event from every step
   All streamed events are forwarded to cb. */
void run_agent(
    const Config *config,
    const Model  *model,
    Context      *ctx,
    const StreamOptions *opts,
    ToolHandler   handler,
    void         *handler_data,
    int           max_steps,
    volatile int *abort_flag,
    EventCallback cb,
    void         *cb_data
);
