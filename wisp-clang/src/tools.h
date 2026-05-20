#pragma once
#include "openai.h"

/* Register all default tools into ctx->tools.
   Returns a dispatcher ToolHandler that routes calls to the right executor.
   userdata for the returned handler is NULL (unused). */
void tools_register_defaults(Context *ctx);

/* The dispatcher. Pass as handler to run_agent / rpc. */
char *tools_dispatch(const char *name, const char *arguments, void *userdata);

/* Individual tool executors (heap result, caller frees) */
char *tool_bash(const char *arguments);
char *tool_read(const char *arguments);
char *tool_write(const char *arguments);
char *tool_edit(const char *arguments);
char *tool_grep(const char *arguments);
char *tool_find(const char *arguments);
char *tool_ls(const char *arguments);
