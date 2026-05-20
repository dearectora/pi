#include "agent.h"
#include "openai.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    void         *cb_data)
{
    if (max_steps <= 0) max_steps = 10;

    /* Resolve stream options */
    StreamOptions resolved = config_resolve(config, opts, model);

    for (int step = 0; step < max_steps; step++) {
        if (abort_flag && *abort_flag) break;

        AssistantMessage *msg = stream_openai(model, ctx, &resolved, abort_flag, cb, cb_data);
        if (!msg) break;

        /* Check if we need tool calls */
        int need_tools = (msg->stop_reason && strcmp(msg->stop_reason, "toolUse") == 0);

        /* Add assistant message to context */
        context_add_assistant_msg(ctx, msg);

        if (!need_tools) {
            assistant_message_free(msg);
            break;
        }

        /* Execute tool calls */
        for (int i = 0; i < msg->content_len; i++) {
            ContentPart *p = &msg->content[i];
            if (!p->type || strcmp(p->type, "toolCall") != 0) continue;

            const char *tool_id   = p->id        ? p->id        : "";
            const char *tool_name = p->name       ? p->name      : "";
            const char *tool_args = p->arguments  ? p->arguments : "{}";

            char *result = NULL;
            if (handler) {
                result = handler(tool_name, tool_args, handler_data);
            }
            if (!result) {
                result = xstrdup("error: tool handler returned NULL");
            }

            context_add_tool_result(ctx, tool_id, result);
            free(result);
        }

        assistant_message_free(msg);
    }

    stream_options_free(&resolved);
}
