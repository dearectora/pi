#pragma once

typedef struct {
    int     help;
    int     version;
    char   *model;      /* NULL if not set */
    char   *provider;   /* NULL if not set */
    double *temperature; /* NULL if not set */
    int    *max_tokens;  /* NULL if not set */
    int     json_mode;
    int     rpc_mode;
    int     no_log;
    char   *prompt;     /* NULL means read from stdin */
    char  **warnings;
    int     warnings_len;
    int     warnings_cap;
} Args;

/* Parse argv (not including argv[0]). */
Args args_parse(int argc, char **argv);
void args_free(Args *a);
void args_print_help(void);
