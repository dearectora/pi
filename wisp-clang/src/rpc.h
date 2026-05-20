#pragma once
#include "config.h"
#include "openai.h"
#include "agent.h"

/* Run the RPC server: read JSON commands from stdin, write events/responses to stdout.
   Runs until stdin is closed. */
void run_rpc(
    const Config       *config,
    const Model        *initial_model,
    const StreamOptions *initial_opts,
    const char         *initial_system_prompt,
    ToolHandler         handler,
    void               *handler_data
);
