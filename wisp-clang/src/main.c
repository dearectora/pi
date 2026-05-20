#include "args.h"
#include "config.h"
#include "openai.h"
#include "agent.h"
#include "tools.h"
#include "rpc.h"
#include "output.h"
#include "logger.h"
#include "systemprompt.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define VERSION "0.1.0"

static int is_tty(void) {
    struct stat st;
    if (fstat(STDIN_FILENO, &st) < 0) return 1;
    return (st.st_mode & S_IFMT) == S_IFCHR;
}

static char *read_stdin(void) {
    char *data = read_all(stdin, NULL);
    if (!data) return xstrdup("");
    /* Trim trailing newlines */
    size_t len = strlen(data);
    while (len > 0 && (data[len-1] == '\n' || data[len-1] == '\r')) data[--len] = '\0';
    return data;
}

/* Resolve model from args + config */
static const Model *resolve_model(const Args *args, const Config *config) {
    if (config->models.len == 0) return NULL;

    const char *provider = args->provider ? args->provider : config->default_provider;
    const char *model_id = args->model    ? args->model    : config->default_model;

    if (provider && model_id) {
        const Model *m = registry_find(config, provider, model_id);
        if (m) return m;
    }
    if (model_id) {
        const Model *m = registry_find_by_id(config, model_id);
        if (m) return m;
    }
    if (provider) {
        const Model *m = registry_for_provider_first(config, provider);
        if (m) return m;
    }
    return &config->models.data[0];
}

static const char *MODELS_JSON_EXAMPLE =
    "{\n"
    "  \"defaultProvider\": \"openai\",\n"
    "  \"defaultModel\": \"gpt-4o-mini\",\n"
    "  \"providers\": {\n"
    "    \"openai\": {\n"
    "      \"apiKey\": \"sk-...\",\n"
    "      \"models\": [\n"
    "        {\n"
    "          \"id\": \"gpt-4o-mini\",\n"
    "          \"name\": \"GPT-4o Mini\",\n"
    "          \"contextWindow\": 128000,\n"
    "          \"maxTokens\": 16384,\n"
    "          \"cost\": { \"input\": 0.15, \"output\": 0.60 }\n"
    "        }\n"
    "      ]\n"
    "    }\n"
    "  }\n"
    "}\n";

/* Agent callback state for non-RPC modes */
typedef struct {
    EventCallback inner_cb;
    void         *inner_data;
    AssistantMessage *final_msg;
    int           exit_code;
} MainCbState;

static void main_cb(const WispEvent *e, void *userdata) {
    MainCbState *s = (MainCbState *)userdata;
    if (s->inner_cb) s->inner_cb(e, s->inner_data);
    if (e->type == EV_DONE) {
        s->final_msg = e->message;
        s->exit_code = 0;
    } else if (e->type == EV_ERROR) {
        s->final_msg = e->message;
        s->exit_code = 1;
    }
}

int main(int argc, char **argv) {
    Args args = args_parse(argc - 1, argv + 1);

    for (int i = 0; i < args.warnings_len; i++) {
        fprintf(stderr, "Warning: %s\n", args.warnings[i]);
    }

    if (args.help) {
        args_print_help();
        args_free(&args);
        return 0;
    }

    if (args.version) {
        printf("wisp %s\n", VERSION);
        args_free(&args);
        return 0;
    }

    /* Load config */
    Config *config = config_load();
    if (config->load_error) {
        fprintf(stderr, "Error loading models.json: %s\n", config->load_error);
        config_free(config);
        args_free(&args);
        return 1;
    }

    /* RPC mode: read from stdin */
    if (args.rpc_mode) {
        if (config->models.len == 0) {
            fprintf(stderr, "Error: no models loaded. Create %s\n",
                config->load_error ? config->load_error : "~/.pi/agent/models.json");
            char *path = config_models_path();
            fprintf(stderr, "Example:\n%s\n", MODELS_JSON_EXAMPLE);
            free(path);
            config_free(config);
            args_free(&args);
            return 1;
        }
        const Model *model = resolve_model(&args, config);
        if (!model) {
            fprintf(stderr, "Error: could not resolve model\n");
            config_free(config);
            args_free(&args);
            return 1;
        }

        StreamOptions caller_opts = {0};
        if (args.temperature) {
            caller_opts.temperature = xmalloc(sizeof(double));
            *caller_opts.temperature = *args.temperature;
        }
        if (args.max_tokens) {
            caller_opts.max_tokens = xmalloc(sizeof(int));
            *caller_opts.max_tokens = *args.max_tokens;
        }
        StreamOptions opts = config_resolve(config, &caller_opts, model);
        stream_options_free(&caller_opts);

        if (!opts.api_key || !opts.api_key[0]) {
            fprintf(stderr,
                "Error: no API key found for provider \"%s\".\n"
                "Add it to ~/.pi/agent/models.json under the provider's \"apiKey\" field.\n",
                model->provider ? model->provider : "");
            stream_options_free(&opts);
            config_free(config);
            args_free(&args);
            return 1;
        }

        char *system_prompt = build_system_prompt();

        /* Build a temporary context to register tools */
        Context *tool_ctx = context_new();
        tools_register_defaults(tool_ctx);
        /* We don't use the context itself — just steal the tools */
        /* The RPC module uses the tools_dispatch function directly */
        context_free(tool_ctx);

        run_rpc(config, model, &opts, system_prompt, tools_dispatch, NULL);

        free(system_prompt);
        stream_options_free(&opts);
        config_free(config);
        args_free(&args);
        return 0;
    }

    /* Normal / JSON mode: need a prompt */
    char *prompt = NULL;
    if (args.prompt && args.prompt[0]) {
        prompt = xstrdup(args.prompt);
    } else {
        if (is_tty()) {
            fprintf(stderr, "Error: no prompt provided. Run `wisp --help` for usage.\n");
            config_free(config);
            args_free(&args);
            return 1;
        }
        prompt = read_stdin();
        if (!prompt || !prompt[0]) {
            fprintf(stderr, "Error: no prompt provided. Run `wisp --help` for usage.\n");
            free(prompt);
            config_free(config);
            args_free(&args);
            return 1;
        }
    }

    /* Resolve model */
    if (config->models.len == 0) {
        char *path = config_models_path();
        fprintf(stderr,
            "Error: no models loaded.\n\n"
            "Create %s with your model configuration, for example:\n\n%s",
            path, MODELS_JSON_EXAMPLE);
        free(path);
        free(prompt);
        config_free(config);
        args_free(&args);
        return 1;
    }

    const Model *model = resolve_model(&args, config);
    if (!model) {
        fprintf(stderr, "Error: could not resolve model\n");
        free(prompt);
        config_free(config);
        args_free(&args);
        return 1;
    }

    /* Resolve stream options */
    StreamOptions caller_opts = {0};
    if (args.temperature) {
        caller_opts.temperature = xmalloc(sizeof(double));
        *caller_opts.temperature = *args.temperature;
    }
    if (args.max_tokens) {
        caller_opts.max_tokens = xmalloc(sizeof(int));
        *caller_opts.max_tokens = *args.max_tokens;
    }
    StreamOptions opts = config_resolve(config, &caller_opts, model);
    stream_options_free(&caller_opts);

    if (!opts.api_key || !opts.api_key[0]) {
        fprintf(stderr,
            "Error: no API key found for provider \"%s\".\n"
            "Add it to ~/.pi/agent/models.json under the provider's \"apiKey\" field.\n",
            model->provider ? model->provider : "");
        stream_options_free(&opts);
        free(prompt);
        config_free(config);
        args_free(&args);
        return 1;
    }

    /* Session logger */
    SessionLogger *logger = NULL;
    if (!args.no_log) {
        logger = logger_new(model);
        if (!logger) {
            fprintf(stderr, "Warning: could not open session log\n");
        } else {
            logger_log_user(logger, prompt);
        }
    }

    /* Build context */
    Context *ctx = context_new();
    context_add_user_msg(ctx, prompt);
    free(prompt);

    /* Register tools */
    tools_register_defaults(ctx);

    /* Set up callback */
    AssistantMessage *final_msg = NULL;
    int exit_code = 0;

    if (args.json_mode) {
        JsonModeState jstate = {0};
        MainCbState ms = {
            .inner_cb   = json_mode_cb,
            .inner_data = &jstate,
        };
        run_agent(config, model, ctx, &opts, tools_dispatch, NULL, 0, NULL, main_cb, &ms);
        final_msg = ms.final_msg;
        exit_code = ms.exit_code;
    } else {
        TextModeState tstate = {0};
        MainCbState ms = {
            .inner_cb   = text_mode_cb,
            .inner_data = &tstate,
        };
        run_agent(config, model, ctx, &opts, tools_dispatch, NULL, 0, NULL, main_cb, &ms);
        final_msg = ms.final_msg;
        exit_code = ms.exit_code;
    }

    if (logger && final_msg) {
        logger_log_assistant(logger, final_msg);
    }
    logger_free(logger);

    context_free(ctx);
    stream_options_free(&opts);
    config_free(config);
    args_free(&args);

    return exit_code;
}
