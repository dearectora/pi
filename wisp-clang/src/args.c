#include "args.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static void add_warning(Args *a, const char *msg) {
    if (a->warnings_len >= a->warnings_cap) {
        a->warnings_cap = a->warnings_cap ? a->warnings_cap * 2 : 4;
        a->warnings = xrealloc(a->warnings, (size_t)a->warnings_cap * sizeof(char*));
    }
    a->warnings[a->warnings_len++] = xstrdup(msg);
}

static void consume_flag(Args *a, const char *flag, const char *value) {
    if (strcmp(flag, "-m") == 0 || strcmp(flag, "--model") == 0) {
        free(a->model);
        a->model = xstrdup(value);
    } else if (strcmp(flag, "-p") == 0 || strcmp(flag, "--provider") == 0) {
        free(a->provider);
        a->provider = xstrdup(value);
    } else if (strcmp(flag, "--temperature") == 0) {
        double v = atof(value);
        if (a->temperature) free(a->temperature);
        a->temperature = xmalloc(sizeof(double));
        *a->temperature = v;
    } else if (strcmp(flag, "--max-tokens") == 0) {
        int v = atoi(value);
        if (a->max_tokens) free(a->max_tokens);
        a->max_tokens = xmalloc(sizeof(int));
        *a->max_tokens = v;
    } else if (strcmp(flag, "--mode") == 0) {
        if (strcmp(value, "json") == 0) a->json_mode = 1;
        else if (strcmp(value, "text") == 0) { /* default */ }
        else if (strcmp(value, "rpc") == 0)  a->rpc_mode = 1;
        else {
            char *w = str_printf("unknown mode: %s (use text, json, or rpc)", value);
            add_warning(a, w);
            free(w);
        }
    }
}

Args args_parse(int argc, char **argv) {
    Args a = {0};

    /* collect prompt words */
    char **prompt_parts = NULL;
    int    prompt_count = 0, prompt_cap = 0;

    for (int i = 0; i < argc; i++) {
        const char *arg = argv[i];

        /* --flag=value form */
        if (strncmp(arg, "--", 2) == 0) {
            const char *eq = strchr(arg, '=');
            if (eq) {
                char *flag = xstrndup(arg, (size_t)(eq - arg));
                consume_flag(&a, flag, eq + 1);
                free(flag);
                continue;
            }
        }

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            a.help = 1;
        } else if (strcmp(arg, "-v") == 0 || strcmp(arg, "--version") == 0) {
            a.version = 1;
        } else if (strcmp(arg, "--json") == 0) {
            a.json_mode = 1;
        } else if (strcmp(arg, "--no-log") == 0) {
            a.no_log = 1;
        } else if (strcmp(arg, "-m") == 0 || strcmp(arg, "--model") == 0 ||
                   strcmp(arg, "-p") == 0 || strcmp(arg, "--provider") == 0 ||
                   strcmp(arg, "--temperature") == 0 || strcmp(arg, "--max-tokens") == 0 ||
                   strcmp(arg, "--mode") == 0) {
            if (i + 1 < argc) {
                consume_flag(&a, arg, argv[++i]);
            } else {
                char *w = str_printf("flag %s requires a value", arg);
                add_warning(&a, w);
                free(w);
            }
        } else if (arg[0] == '-') {
            char *w = str_printf("unknown flag: %s", arg);
            add_warning(&a, w);
            free(w);
        } else {
            /* positional = prompt word */
            if (prompt_count >= prompt_cap) {
                prompt_cap = prompt_cap ? prompt_cap * 2 : 8;
                prompt_parts = xrealloc(prompt_parts, (size_t)prompt_cap * sizeof(char*));
            }
            prompt_parts[prompt_count++] = xstrdup(arg);
        }
    }

    if (prompt_count > 0) {
        /* Join prompt parts with spaces */
        size_t total = 0;
        for (int i = 0; i < prompt_count; i++) total += strlen(prompt_parts[i]) + 1;
        a.prompt = xmalloc(total);
        a.prompt[0] = '\0';
        for (int i = 0; i < prompt_count; i++) {
            if (i > 0) strcat(a.prompt, " ");
            strcat(a.prompt, prompt_parts[i]);
            free(prompt_parts[i]);
        }
        free(prompt_parts);
    }

    return a;
}

void args_free(Args *a) {
    free(a->model);
    free(a->provider);
    free(a->temperature);
    free(a->max_tokens);
    free(a->prompt);
    for (int i = 0; i < a->warnings_len; i++) free(a->warnings[i]);
    free(a->warnings);
}

void args_print_help(void) {
    puts("Usage: wisp [options] [prompt]\n"
         "\n"
         "Options:\n"
         "  -m, --model <id>         Model id (e.g. gpt-4o-mini, deepseek-reasoner)\n"
         "  -p, --provider <name>    Provider (e.g. openai, deepseek, groq)\n"
         "      --temperature <n>    Sampling temperature 0.0-2.0\n"
         "      --max-tokens <n>     Maximum output tokens\n"
         "      --mode <mode>        Output mode: text (default), json, rpc\n"
         "      --json               Shorthand for --mode json\n"
         "      --no-log             Disable JSONL session logging\n"
         "  -h, --help               Show this help\n"
         "  -v, --version            Show version\n"
         "\n"
         "Input:\n"
         "  Pass the prompt as a positional argument, or pipe it via stdin.\n"
         "  In rpc mode, commands are read from stdin as JSON Lines.\n"
         "\n"
         "Settings:\n"
         "  ~/.pi/agent/models.json     Model definitions, provider API keys, defaults\n"
         "\n"
         "RPC mode commands (stdin JSON Lines):\n"
         "  { \"type\": \"prompt\", \"message\": \"...\" }\n"
         "  { \"type\": \"follow_up\", \"message\": \"...\" }\n"
         "  { \"type\": \"abort\" }\n"
         "  { \"type\": \"new_session\" }\n"
         "  { \"type\": \"get_state\" }\n"
         "  { \"type\": \"get_messages\" }\n"
         "  { \"type\": \"set_model\", \"provider\": \"openai\", \"modelId\": \"gpt-4o\" }\n"
         "  { \"type\": \"get_available_models\" }\n"
         "  { \"type\": \"set_system_prompt\", \"systemPrompt\": \"...\" }\n"
         "\n"
         "Examples:\n"
         "  wisp \"What is the capital of France?\"\n"
         "  wisp -m deepseek-reasoner \"Solve: x^2 + 5x + 6 = 0\"\n"
         "  wisp -p groq -m llama-3.3-70b-versatile \"Explain monads\"\n"
         "  echo \"Summarise this text\" | wisp\n"
         "  wisp --mode json \"Tell me a joke\"\n"
         "  wisp --mode rpc\n"
         "  wisp --temperature 0.2 --max-tokens 256 \"Write a haiku\"\n");
}
