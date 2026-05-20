#include "config.h"
#include "util.h"
#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <errno.h>

/* ---- agent dir / models path ---- */

char *config_agent_dir(void) {
    const char *env = getenv("PI_CODING_AGENT_DIR");
    if (env && env[0]) return xstrdup(env);
    const char *home = getenv("HOME");
    if (!home || !home[0]) home = "/root";
    return str_printf("%s/.pi/agent", home);
}

char *config_models_path(void) {
    char *dir = config_agent_dir();
    char *p = str_printf("%s/models.json", dir);
    free(dir);
    return p;
}

/* ---- helpers ---- */

static void model_array_push(ModelArray *a, Model m) {
    if (a->len >= a->cap) {
        a->cap = a->cap ? a->cap * 2 : 8;
        a->data = xrealloc(a->data, (size_t)a->cap * sizeof(Model));
    }
    a->data[a->len++] = m;
}

static void model_free(Model *m) {
    free(m->id); free(m->name); free(m->provider);
    free(m->base_url);
}

/* ---- load ---- */

Config *config_load(void) {
    Config *cfg = xcalloc(1, sizeof(Config));

    char *path = config_models_path();
    FILE *f = fopen(path, "r");
    free(path);

    if (!f) {
        if (errno != ENOENT)
            cfg->load_error = str_printf("cannot open models.json: %s", strerror(errno));
        return cfg;
    }

    char *data = read_all(f, NULL);
    fclose(f);

    cJSON *root = cJSON_Parse(data);
    free(data);
    if (!root) {
        cfg->load_error = xstrdup("models.json: JSON parse error");
        return cfg;
    }

    /* top-level fields */
    cJSON *j;
    if ((j = cJSON_GetObjectItemCaseSensitive(root, "defaultProvider")) && cJSON_IsString(j))
        cfg->default_provider = xstrdup(j->valuestring);
    if ((j = cJSON_GetObjectItemCaseSensitive(root, "defaultModel")) && cJSON_IsString(j))
        cfg->default_model = xstrdup(j->valuestring);

    cJSON *stream = cJSON_GetObjectItemCaseSensitive(root, "stream");
    if (stream) {
        cJSON *t = cJSON_GetObjectItemCaseSensitive(stream, "temperature");
        if (t && cJSON_IsNumber(t)) {
            cfg->stream.temperature = xmalloc(sizeof(double));
            *cfg->stream.temperature = t->valuedouble;
        }
        cJSON *mt = cJSON_GetObjectItemCaseSensitive(stream, "maxTokens");
        if (mt && cJSON_IsNumber(mt)) {
            cfg->stream.max_tokens = xmalloc(sizeof(int));
            *cfg->stream.max_tokens = (int)mt->valuedouble;
        }
    }

    /* providers */
    cJSON *providers = cJSON_GetObjectItemCaseSensitive(root, "providers");
    if (providers) {
        cJSON *prov = NULL;
        cJSON_ArrayForEach(prov, providers) {
            const char *prov_id_raw = prov->string;
            if (!prov_id_raw) continue;

            /* lower-case provider id */
            char *pid = xstrdup(prov_id_raw);
            for (char *c = pid; *c; c++) if (*c >= 'A' && *c <= 'Z') *c += 32;

            /* api key */
            cJSON *apikey = cJSON_GetObjectItemCaseSensitive(prov, "apiKey");
            if (apikey && cJSON_IsString(apikey) && apikey->valuestring[0]) {
                cfg->key_providers = xrealloc(cfg->key_providers,
                    (size_t)(cfg->key_count + 1) * sizeof(char*));
                cfg->key_values = xrealloc(cfg->key_values,
                    (size_t)(cfg->key_count + 1) * sizeof(char*));
                cfg->key_providers[cfg->key_count] = xstrdup(pid);
                cfg->key_values[cfg->key_count] = xstrdup(apikey->valuestring);
                cfg->key_count++;
            }

            char *prov_base_url = NULL;
            cJSON *pb = cJSON_GetObjectItemCaseSensitive(prov, "baseUrl");
            if (pb && cJSON_IsString(pb)) prov_base_url = pb->valuestring;

            /* models array */
            cJSON *models_arr = cJSON_GetObjectItemCaseSensitive(prov, "models");
            if (models_arr) {
                cJSON *mdef = NULL;
                cJSON_ArrayForEach(mdef, models_arr) {
                    cJSON *mid = cJSON_GetObjectItemCaseSensitive(mdef, "id");
                    if (!mid || !cJSON_IsString(mid) || !mid->valuestring[0]) continue;

                    Model m = {0};
                    m.id = xstrdup(mid->valuestring);
                    m.provider = xstrdup(pid);

                    cJSON *mn = cJSON_GetObjectItemCaseSensitive(mdef, "name");
                    m.name = (mn && cJSON_IsString(mn)) ? xstrdup(mn->valuestring) : xstrdup(m.id);

                    /* baseUrl: model-level overrides provider-level */
                    cJSON *mb = cJSON_GetObjectItemCaseSensitive(mdef, "baseUrl");
                    if (mb && cJSON_IsString(mb))
                        m.base_url = xstrdup(mb->valuestring);
                    else if (prov_base_url)
                        m.base_url = xstrdup(prov_base_url);
                    else
                        m.base_url = xstrdup("");

                    cJSON *cw = cJSON_GetObjectItemCaseSensitive(mdef, "contextWindow");
                    if (cw && cJSON_IsNumber(cw)) m.context_window = (int)cw->valuedouble;
                    cJSON *mxt = cJSON_GetObjectItemCaseSensitive(mdef, "maxTokens");
                    if (mxt && cJSON_IsNumber(mxt)) m.max_tokens = (int)mxt->valuedouble;
                    cJSON *st = cJSON_GetObjectItemCaseSensitive(mdef, "supportsThinking");
                    if (st && cJSON_IsBool(st)) m.supports_thinking = cJSON_IsTrue(st);

                    cJSON *cost = cJSON_GetObjectItemCaseSensitive(mdef, "cost");
                    if (cost) {
                        cJSON *ci = cJSON_GetObjectItemCaseSensitive(cost, "input");
                        cJSON *co = cJSON_GetObjectItemCaseSensitive(cost, "output");
                        if (ci && cJSON_IsNumber(ci)) m.cost.input = ci->valuedouble;
                        if (co && cJSON_IsNumber(co)) m.cost.output = co->valuedouble;
                    }

                    model_array_push(&cfg->models, m);
                }
            }
            free(pid);
        }
    }

    cJSON_Delete(root);
    return cfg;
}

void config_free(Config *c) {
    if (!c) return;
    for (int i = 0; i < c->models.len; i++) model_free(&c->models.data[i]);
    free(c->models.data);
    free(c->default_provider);
    free(c->default_model);
    free(c->stream.temperature);
    free(c->stream.max_tokens);
    for (int i = 0; i < c->key_count; i++) {
        free(c->key_providers[i]);
        free(c->key_values[i]);
    }
    free(c->key_providers);
    free(c->key_values);
    free(c->load_error);
    free(c);
}

const char *config_api_key(const Config *c, const char *provider) {
    if (!c || !provider) return NULL;
    for (int i = 0; i < c->key_count; i++) {
        if (strcasecmp(c->key_providers[i], provider) == 0)
            return c->key_values[i];
    }
    return NULL;
}

StreamOptions config_resolve(const Config *c, const StreamOptions *caller, const Model *model) {
    StreamOptions out = {0};
    if (caller) {
        if (caller->api_key) out.api_key = xstrdup(caller->api_key);
        if (caller->temperature) {
            out.temperature = xmalloc(sizeof(double));
            *out.temperature = *caller->temperature;
        }
        if (caller->max_tokens) {
            out.max_tokens = xmalloc(sizeof(int));
            *out.max_tokens = *caller->max_tokens;
        }
    }
    if (!out.api_key && c && model) {
        const char *k = config_api_key(c, model->provider);
        if (k) out.api_key = xstrdup(k);
    }
    if (!out.temperature && c && c->stream.temperature) {
        out.temperature = xmalloc(sizeof(double));
        *out.temperature = *c->stream.temperature;
    }
    if (!out.max_tokens && c && c->stream.max_tokens) {
        out.max_tokens = xmalloc(sizeof(int));
        *out.max_tokens = *c->stream.max_tokens;
    }
    return out;
}

void stream_options_free(StreamOptions *o) {
    if (!o) return;
    free(o->api_key);
    free(o->temperature);
    free(o->max_tokens);
}

const Model *registry_find(const Config *c, const char *provider, const char *id) {
    if (!c || !provider || !id) return NULL;
    for (int i = 0; i < c->models.len; i++) {
        Model *m = &c->models.data[i];
        if (strcasecmp(m->provider, provider) == 0 && strcasecmp(m->id, id) == 0)
            return m;
    }
    return NULL;
}

const Model *registry_find_by_id(const Config *c, const char *id) {
    if (!c || !id) return NULL;
    for (int i = 0; i < c->models.len; i++) {
        if (strcasecmp(c->models.data[i].id, id) == 0)
            return &c->models.data[i];
    }
    return NULL;
}

const Model *registry_for_provider_first(const Config *c, const char *provider) {
    if (!c || !provider) return NULL;
    for (int i = 0; i < c->models.len; i++) {
        if (strcasecmp(c->models.data[i].provider, provider) == 0)
            return &c->models.data[i];
    }
    return NULL;
}
