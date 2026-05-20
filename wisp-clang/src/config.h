#pragma once
#include <stddef.h>

typedef struct {
    double input;
    double output;
} ModelCost;

typedef struct {
    char *id;
    char *name;
    char *provider;
    char *base_url;
    int context_window;
    int max_tokens;
    ModelCost cost;
    int supports_thinking; /* bool */
} Model;

typedef struct {
    double *temperature; /* NULL = not set */
    int    *max_tokens;  /* NULL = not set */
} StreamDefaults;

typedef struct {
    Model  *data;
    int     len;
    int     cap;
} ModelArray;

typedef struct {
    /* loaded models */
    ModelArray models;

    /* defaults */
    char          *default_provider;
    char          *default_model;
    StreamDefaults stream;

    /* per-provider keys: parallel arrays, lower-cased provider names */
    char **key_providers;
    char **key_values;
    int    key_count;

    char *load_error; /* NULL if ok */
} Config;

/* Load config from ~/.pi/agent/models.json (or PI_CODING_AGENT_DIR) */
Config *config_load(void);
void    config_free(Config *c);

/* Returns the models.json path (heap-allocated, caller frees) */
char *config_models_path(void);

/* Returns the agent directory (heap-allocated, caller frees) */
char *config_agent_dir(void);

/* Returns api key for provider (lower-cased lookup), or NULL */
const char *config_api_key(const Config *c, const char *provider);

/* Resolve stream options: fill in api_key, temperature, max_tokens from config defaults */
typedef struct {
    char   *api_key;       /* heap, may be NULL */
    double *temperature;   /* heap, may be NULL */
    int    *max_tokens;    /* heap, may be NULL */
} StreamOptions;

StreamOptions config_resolve(const Config *c, const StreamOptions *caller_opts, const Model *model);
void stream_options_free(StreamOptions *o);

/* Model lookup helpers */
const Model *registry_find(const Config *c, const char *provider, const char *id);
const Model *registry_find_by_id(const Config *c, const char *id);
const Model *registry_for_provider_first(const Config *c, const char *provider);
