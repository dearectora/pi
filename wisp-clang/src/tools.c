#include "tools.h"
#include "util.h"
#include "cJSON.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <regex.h>
#include <fnmatch.h>
#include <ftw.h>

/* ---- truncation ---- */

#define OUT_MAX_LINES 300
#define OUT_MAX_BYTES (512 * 1024)

/* Truncate to last max_lines lines OR last max_bytes bytes (tail-based) */
static char *truncate_tail_str(const char *s) {
    if (!s) return xstrdup("");
    size_t len = strlen(s);

    if (len > OUT_MAX_BYTES) {
        const char *pfx = "[output truncated]\n";
        const char *tail = s + len - OUT_MAX_BYTES;
        char *r = xmalloc(strlen(pfx) + OUT_MAX_BYTES + 1);
        strcpy(r, pfx);
        memcpy(r + strlen(pfx), tail, OUT_MAX_BYTES);
        r[strlen(pfx) + OUT_MAX_BYTES] = '\0';
        return r;
    }

    /* count lines */
    int nlines = 0;
    for (size_t i = 0; i < len; i++) if (s[i] == '\n') nlines++;

    if (nlines <= OUT_MAX_LINES) return xstrdup(s);

    /* find start of (nlines - OUT_MAX_LINES + 1)-th newline from end */
    int skip = nlines - OUT_MAX_LINES;
    int found = 0;
    size_t pos = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '\n') {
            found++;
            if (found == skip) { pos = i + 1; break; }
        }
    }
    const char *pfx = "[output truncated]\n";
    char *r = xmalloc(strlen(pfx) + (len - pos) + 1);
    strcpy(r, pfx);
    memcpy(r + strlen(pfx), s + pos, len - pos + 1);
    return r;
}

/* Truncate to first max_lines lines or max_bytes (head-based) */
static char *truncate_head_str(const char *s, int max_lines) {
    if (!s) return xstrdup("");
    size_t len = strlen(s);

    if (len > OUT_MAX_BYTES) {
        char *r = xmalloc(OUT_MAX_BYTES + 40);
        memcpy(r, s, OUT_MAX_BYTES);
        strcpy(r + OUT_MAX_BYTES, "\n[output truncated at 512KB]");
        return r;
    }

    int nlines = 0;
    for (size_t i = 0; i < len; i++) if (s[i] == '\n') nlines++;
    if (nlines <= max_lines) return xstrdup(s);

    int found = 0;
    size_t pos = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '\n') {
            found++;
            if (found == max_lines) { pos = i; break; }
        }
    }
    char *r = xmalloc(pos + 20);
    memcpy(r, s, pos);
    strcpy(r + pos, "\n[output truncated]");
    return r;
}

/* ---- Tool schemas ---- */

static const char *BASH_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"command\":{\"type\":\"string\",\"description\":\"Bash command to execute\"},"
    "\"timeout\":{\"type\":\"number\",\"description\":\"Timeout in seconds\"}"
    "},"
    "\"required\":[\"command\"]}";

static const char *READ_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to read (relative or absolute)\"},"
    "\"offset\":{\"type\":\"number\",\"description\":\"Line number to start reading from (1-indexed)\"},"
    "\"limit\":{\"type\":\"number\",\"description\":\"Maximum number of lines to read\"}"
    "},"
    "\"required\":[\"path\"]}";

static const char *WRITE_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to write\"},"
    "\"content\":{\"type\":\"string\",\"description\":\"Content to write\"}"
    "},"
    "\"required\":[\"path\",\"content\"]}";

static const char *EDIT_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"path\":{\"type\":\"string\",\"description\":\"Path to the file to edit\"},"
    "\"edits\":{\"type\":\"array\",\"items\":{"
    "\"type\":\"object\","
    "\"properties\":{"
    "\"oldText\":{\"type\":\"string\",\"description\":\"Exact text to replace (must be unique in file)\"},"
    "\"newText\":{\"type\":\"string\",\"description\":\"Replacement text\"}"
    "},\"required\":[\"oldText\",\"newText\"]}}"
    "},"
    "\"required\":[\"path\",\"edits\"]}";

static const char *GREP_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Search pattern (regex)\"},"
    "\"path\":{\"type\":\"string\",\"description\":\"Directory or file to search\"},"
    "\"glob\":{\"type\":\"string\",\"description\":\"Filter files by glob\"},"
    "\"ignoreCase\":{\"type\":\"boolean\",\"description\":\"Case-insensitive search\"},"
    "\"literal\":{\"type\":\"boolean\",\"description\":\"Treat as literal string\"},"
    "\"limit\":{\"type\":\"number\",\"description\":\"Max matches (default 100)\"}"
    "},"
    "\"required\":[\"pattern\"]}";

static const char *FIND_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern, e.g. *.go, **/*.ts\"},"
    "\"path\":{\"type\":\"string\",\"description\":\"Directory to search\"},"
    "\"limit\":{\"type\":\"number\",\"description\":\"Max results (default 1000)\"}"
    "},"
    "\"required\":[\"pattern\"]}";

static const char *LS_SCHEMA =
    "{\"type\":\"object\","
    "\"properties\":{"
    "\"path\":{\"type\":\"string\",\"description\":\"Directory to list\"},"
    "\"limit\":{\"type\":\"number\",\"description\":\"Max entries (default 500)\"}"
    "}}";

/* ---- register defaults ---- */

void tools_register_defaults(Context *ctx) {
    struct { const char *name; const char *desc; const char *schema; } defs[] = {
        {"bash",  "Execute a bash command. Returns stdout+stderr combined, truncated to last 300 lines or 512KB.", BASH_SCHEMA},
        {"read",  "Read file contents. Truncated to 300 lines or 512KB. Use offset/limit for large files.", READ_SCHEMA},
        {"write", "Write content to a file, creating parent dirs if needed. Overwrites existing files.", WRITE_SCHEMA},
        {"edit",  "Edit a file using exact text replacement. Every oldText must be unique in the file. All edits are matched against the original file simultaneously.", EDIT_SCHEMA},
        {"grep",  "Search file contents for a pattern. Returns matching lines as path:line:content. Limit 100 matches.", GREP_SCHEMA},
        {"find",  "Search for files by glob pattern. Supports ** for recursive matching.", FIND_SCHEMA},
        {"ls",    "List directory contents, sorted alphabetically. Dirs suffixed with /.", LS_SCHEMA},
    };
    int n = (int)(sizeof(defs)/sizeof(defs[0]));
    if (ctx->tools_cap < ctx->tools_len + n) {
        ctx->tools_cap = ctx->tools_len + n + 4;
        ctx->tools = xrealloc(ctx->tools, (size_t)ctx->tools_cap * sizeof(Tool));
    }
    for (int i = 0; i < n; i++) {
        Tool *t = &ctx->tools[ctx->tools_len++];
        t->name            = xstrdup(defs[i].name);
        t->description     = xstrdup(defs[i].desc);
        t->parameters_json = xstrdup(defs[i].schema);
    }
}

/* ---- dispatcher ---- */

char *tools_dispatch(const char *name, const char *arguments, void *userdata) {
    (void)userdata;
    if (!name) return xstrdup("error: no tool name");
    if (strcmp(name, "bash")  == 0) return tool_bash(arguments);
    if (strcmp(name, "read")  == 0) return tool_read(arguments);
    if (strcmp(name, "write") == 0) return tool_write(arguments);
    if (strcmp(name, "edit")  == 0) return tool_edit(arguments);
    if (strcmp(name, "grep")  == 0) return tool_grep(arguments);
    if (strcmp(name, "find")  == 0) return tool_find(arguments);
    if (strcmp(name, "ls")    == 0) return tool_ls(arguments);
    return str_printf("error: unknown tool: %s", name);
}

/* ---- bash ---- */

char *tool_bash(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *command = "";
    double timeout_s = 0;
    if (j) {
        cJSON *jc = cJSON_GetObjectItemCaseSensitive(j, "command");
        if (jc && cJSON_IsString(jc)) command = jc->valuestring;
        cJSON *jt = cJSON_GetObjectItemCaseSensitive(j, "timeout");
        if (jt && cJSON_IsNumber(jt)) timeout_s = jt->valuedouble;
    }

    /* Write command to temp file and execute */
    char *tmpf = write_tempfile(command, strlen(command));
    if (!tmpf) {
        cJSON_Delete(j);
        return xstrdup("error: failed to create temp file for bash command");
    }

    char *cmd;
    if (timeout_s > 0) {
        cmd = str_printf("timeout %.0f bash '%s' 2>&1", timeout_s, tmpf);
    } else {
        cmd = str_printf("bash '%s' 2>&1", tmpf);
    }

    FILE *pipe = popen(cmd, "r");
    free(cmd);

    char *output;
    if (pipe) {
        output = read_all(pipe, NULL);
        pclose(pipe);
    } else {
        output = xstrdup("error: popen failed");
    }

    unlink(tmpf);
    free(tmpf);
    cJSON_Delete(j);

    char *result = truncate_tail_str(output);
    free(output);
    return result;
}

/* ---- read ---- */

char *tool_read(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *path = "";
    int offset = 0, limit = 0;
    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jp && cJSON_IsString(jp)) path = jp->valuestring;
        cJSON *jo = cJSON_GetObjectItemCaseSensitive(j, "offset");
        if (jo && cJSON_IsNumber(jo)) offset = (int)jo->valuedouble;
        cJSON *jl = cJSON_GetObjectItemCaseSensitive(j, "limit");
        if (jl && cJSON_IsNumber(jl)) limit = (int)jl->valuedouble;
    }

    FILE *f = fopen(path, "r");
    if (!f) {
        char *err = str_printf("error: cannot open %s: %s", path, strerror(errno));
        cJSON_Delete(j);
        return err;
    }

    char *data = read_all(f, NULL);
    fclose(f);
    cJSON_Delete(j);

    /* Split into lines, apply offset/limit */
    /* Find start line */
    int start = 0;
    if (offset > 1) start = offset - 1;

    /* Navigate to start line */
    char *ptr = data;
    for (int i = 0; i < start && *ptr; i++) {
        char *nl = strchr(ptr, '\n');
        if (!nl) { ptr = ptr + strlen(ptr); break; }
        ptr = nl + 1;
    }

    if (!*ptr) {
        free(data);
        return xstrdup("");
    }

    int max_lines = limit > 0 ? limit : OUT_MAX_LINES;
    char *result = truncate_head_str(ptr, max_lines);
    free(data);
    return result;
}

/* ---- write ---- */

char *tool_write(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *path = NULL, *content = NULL;
    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jp && cJSON_IsString(jp)) path = jp->valuestring;
        cJSON *jc = cJSON_GetObjectItemCaseSensitive(j, "content");
        if (jc && cJSON_IsString(jc)) content = jc->valuestring;
    }
    if (!path) { cJSON_Delete(j); return xstrdup("error: path is required"); }
    if (!content) content = "";

    /* Create parent dirs */
    char *dir = xstrdup(path);
    char *slash = strrchr(dir, '/');
    if (slash && slash != dir) {
        *slash = '\0';
        if (mkdirp(dir, 0755) < 0) {
            char *err = str_printf("error: cannot create directory %s: %s", dir, strerror(errno));
            free(dir);
            cJSON_Delete(j);
            return err;
        }
    }
    free(dir);

    /* Save path and content before deleting cJSON (they reference internal strings) */
    char *saved_path    = xstrdup(path);
    char *saved_content = xstrdup(content);
    cJSON_Delete(j);

    FILE *f = fopen(saved_path, "w");
    if (!f) {
        char *err = str_printf("error: cannot write %s: %s", saved_path, strerror(errno));
        free(saved_path); free(saved_content);
        return err;
    }
    size_t clen = strlen(saved_content);
    fwrite(saved_content, 1, clen, f);
    fclose(f);

    char *ret = str_printf("Written %zu bytes to %s", clen, saved_path);
    free(saved_path); free(saved_content);
    return ret;
}

/* ---- edit ---- */

typedef struct {
    size_t start;
    size_t end;
    char *new_text;
} EditRange;

static int cmp_edit_range(const void *a, const void *b) {
    const EditRange *ea = (const EditRange *)a;
    const EditRange *eb = (const EditRange *)b;
    if (ea->start < eb->start) return -1;
    if (ea->start > eb->start) return 1;
    return 0;
}

char *tool_edit(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *path_raw = NULL;
    cJSON *jedits = NULL;

    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jp && cJSON_IsString(jp)) path_raw = jp->valuestring;
        jedits = cJSON_GetObjectItemCaseSensitive(j, "edits");
    }

    if (!path_raw) { cJSON_Delete(j); return xstrdup("error: path is required"); }
    if (!jedits || !cJSON_IsArray(jedits)) { cJSON_Delete(j); return xstrdup("error: edits array is required"); }

    char *path = xstrdup(path_raw);  /* own the path so cJSON_Delete is safe */

    /* Read file */
    FILE *f = fopen(path, "r");
    if (!f) {
        char *err = str_printf("error: cannot open %s: %s", path, strerror(errno));
        free(path);
        cJSON_Delete(j);
        return err;
    }
    char *original = read_all(f, NULL);
    fclose(f);

    int nedits = cJSON_GetArraySize(jedits);
    EditRange *ranges = xcalloc((size_t)nedits, sizeof(EditRange));
    char *error_msg = NULL;

    for (int i = 0; i < nedits && !error_msg; i++) {
        cJSON *edit = cJSON_GetArrayItem(jedits, i);
        cJSON *jold = cJSON_GetObjectItemCaseSensitive(edit, "oldText");
        cJSON *jnew = cJSON_GetObjectItemCaseSensitive(edit, "newText");
        if (!jold || !cJSON_IsString(jold)) {
            error_msg = str_printf("error: edit %d: missing oldText", i+1);
            break;
        }
        const char *old_text = jold->valuestring;
        const char *new_text = (jnew && cJSON_IsString(jnew)) ? jnew->valuestring : "";

        /* Find oldText in original */
        char *found = strstr(original, old_text);
        if (!found) {
            error_msg = str_printf("error: edit %d: oldText not found in file", i+1);
            break;
        }
        /* Check uniqueness */
        size_t old_len = strlen(old_text);
        if (strstr(found + 1, old_text) != NULL) {
            error_msg = str_printf("error: edit %d: oldText matches multiple locations (must be unique)", i+1);
            break;
        }
        ranges[i].start    = (size_t)(found - original);
        ranges[i].end      = ranges[i].start + old_len;
        ranges[i].new_text = xstrdup(new_text);
    }

    cJSON_Delete(j);  /* done with cJSON; path is now our own copy */

    if (error_msg) {
        free(path); free(original);
        for (int i = 0; i < nedits; i++) free(ranges[i].new_text);
        free(ranges);
        return error_msg;
    }

    /* Sort by position */
    qsort(ranges, (size_t)nedits, sizeof(EditRange), cmp_edit_range);

    /* Check overlaps */
    for (int i = 1; i < nedits; i++) {
        if (ranges[i].start < ranges[i-1].end) {
            error_msg = str_printf("error: edits %d and %d overlap - merge them into one edit", i, i+1);
            free(path); free(original);
            for (int k = 0; k < nedits; k++) free(ranges[k].new_text);
            free(ranges);
            return error_msg;
        }
    }

    /* Apply end-to-start */
    char *result = xstrdup(original);
    for (int i = nedits - 1; i >= 0; i--) {
        size_t rlen = strlen(result);
        size_t new_len = strlen(ranges[i].new_text);
        size_t after_len = rlen - ranges[i].end;
        char *tmp = xmalloc(ranges[i].start + new_len + after_len + 1);
        memcpy(tmp, result, ranges[i].start);
        memcpy(tmp + ranges[i].start, ranges[i].new_text, new_len);
        memcpy(tmp + ranges[i].start + new_len, result + ranges[i].end, after_len);
        tmp[ranges[i].start + new_len + after_len] = '\0';
        free(result);
        result = tmp;
    }

    /* Write back */
    f = fopen(path, "w");
    if (!f) {
        char *err = str_printf("error: cannot write %s: %s", path, strerror(errno));
        free(path); free(result); free(original);
        for (int i = 0; i < nedits; i++) free(ranges[i].new_text);
        free(ranges);
        return err;
    }
    fwrite(result, 1, strlen(result), f);
    fclose(f);

    char *ret = str_printf("Applied %d edit(s) to %s", nedits, path);
    free(path); free(result); free(original);
    for (int i = 0; i < nedits; i++) free(ranges[i].new_text);
    free(ranges);
    return ret;
}

/* ---- grep ---- */

typedef struct {
    regex_t re;
    const char *glob;
    int limit;
    int match_count;
    char *output;
    size_t out_len;
    size_t out_cap;
} GrepState;

static void grep_append(GrepState *gs, const char *s) {
    size_t sl = strlen(s);
    if (gs->out_len + sl + 1 > gs->out_cap) {
        gs->out_cap = gs->out_cap ? gs->out_cap * 2 : 4096;
        while (gs->out_cap < gs->out_len + sl + 1) gs->out_cap *= 2;
        gs->output = xrealloc(gs->output, gs->out_cap);
    }
    memcpy(gs->output + gs->out_len, s, sl + 1);
    gs->out_len += sl;
}

static GrepState *g_grep_state = NULL;

static int grep_visitor(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    GrepState *gs = g_grep_state;

    if (gs->match_count >= gs->limit || gs->out_len >= OUT_MAX_BYTES) return 0;

    /* Skip hidden files/dirs */
    const char *base = strrchr(fpath, '/');
    base = base ? base + 1 : fpath;
    if (base[0] == '.') {
        return 0;  /* skip hidden; nftw will skip hidden dirs' subtrees naturally */
    }

    if (typeflag == FTW_D || typeflag == FTW_DNR) return 0;
    if (typeflag != FTW_F) return 0;

    /* Apply glob filter */
    if (gs->glob && gs->glob[0]) {
        if (fnmatch(gs->glob, base, 0) != 0) return 0;
    }

    /* Read and search file */
    FILE *f = fopen(fpath, "r");
    if (!f) return 0;
    char *data = read_all(f, NULL);
    fclose(f);

    /* Search line by line */
    char *line = data;
    int lineno = 1;
    while (*line && gs->match_count < gs->limit && gs->out_len < OUT_MAX_BYTES) {
        char *nl = strchr(line, '\n');
        size_t llen = nl ? (size_t)(nl - line) : strlen(line);

        /* Null-terminate line temporarily */
        char saved = line[llen];
        line[llen] = '\0';

        if (regexec(&gs->re, line, 0, NULL, 0) == 0) {
            /* Truncate long lines */
            char *disp = line;
            char truncated[516];
            if (llen > 512) {
                memcpy(truncated, line, 512);
                memcpy(truncated + 512, "...", 4);  /* includes NUL */
                disp = truncated;
            }
            char *entry = str_printf("%s:%d:%s\n", fpath, lineno, disp);
            grep_append(gs, entry);
            free(entry);
            gs->match_count++;
        }

        line[llen] = saved;
        if (!nl) break;
        line = nl + 1;
        lineno++;
    }

    free(data);
    return 0;
}

char *tool_grep(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *pattern = NULL, *path = ".", *glob = NULL;
    int ignore_case = 0, literal = 0, limit = 100;

    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "pattern");
        if (jp && cJSON_IsString(jp)) pattern = jp->valuestring;
        cJSON *jpa = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jpa && cJSON_IsString(jpa) && jpa->valuestring[0]) path = jpa->valuestring;
        cJSON *jg = cJSON_GetObjectItemCaseSensitive(j, "glob");
        if (jg && cJSON_IsString(jg)) glob = jg->valuestring;
        cJSON *jic = cJSON_GetObjectItemCaseSensitive(j, "ignoreCase");
        if (jic && cJSON_IsBool(jic)) ignore_case = cJSON_IsTrue(jic);
        cJSON *jlit = cJSON_GetObjectItemCaseSensitive(j, "literal");
        if (jlit && cJSON_IsBool(jlit)) literal = cJSON_IsTrue(jlit);
        cJSON *jlim = cJSON_GetObjectItemCaseSensitive(j, "limit");
        if (jlim && cJSON_IsNumber(jlim) && jlim->valuedouble > 0) limit = (int)jlim->valuedouble;
    }

    if (!pattern) { cJSON_Delete(j); return xstrdup("error: pattern is required"); }

    /* Build regex pattern */
    char *pat = xstrdup(pattern);
    if (literal) {
        /* Escape regex metacharacters */
        char *escaped = xmalloc(strlen(pat) * 2 + 1);
        char *p = escaped;
        for (const char *c = pat; *c; c++) {
            if (strchr("^$.*+?()[]{}|\\", *c)) *p++ = '\\';
            *p++ = *c;
        }
        *p = '\0';
        free(pat);
        pat = escaped;
    }

    int flags = REG_EXTENDED;
    if (ignore_case) flags |= REG_ICASE;

    GrepState gs = {0};
    gs.glob  = glob;
    gs.limit = limit;

    if (regcomp(&gs.re, pat, flags) != 0) {
        free(pat); cJSON_Delete(j);
        return str_printf("error: invalid regex pattern: %s", pattern);
    }
    free(pat);

    g_grep_state = &gs;
    nftw(path, grep_visitor, 20, FTW_PHYS);
    g_grep_state = NULL;

    regfree(&gs.re);
    cJSON_Delete(j);

    if (gs.match_count == 0) {
        free(gs.output);
        return xstrdup("No matches found");
    }

    return gs.output ? gs.output : xstrdup("");
}

/* ---- find ---- */

typedef struct {
    const char *pattern;
    const char *base_path;
    size_t      base_len;
    int         limit;
    char      **results;
    int         result_count;
    int         result_cap;
} FindState;

/* Glob match supporting ** */
static int glob_match(const char *pattern, const char *path) {
    /* No **: use fnmatch directly */
    if (!strstr(pattern, "**")) {
        return fnmatch(pattern, path, FNM_PATHNAME) == 0;
    }

    /* Find first ** */
    const char *dstar = strstr(pattern, "**");
    size_t prefix_len = (size_t)(dstar - pattern);

    /* Check prefix */
    if (prefix_len > 0) {
        if (strncmp(path, pattern, prefix_len) != 0) return 0;
        path = path + prefix_len;
    }

    /* rest is pattern after ** */
    const char *rest = dstar + 2;
    if (rest[0] == '/') rest++;

    if (rest[0] == '\0') return 1; /* ** matches everything */

    /* Try matching rest against every suffix of path */
    const char *p = path;
    for (;;) {
        if (fnmatch(rest, p, FNM_PATHNAME) == 0) return 1;
        char *slash = strchr(p, '/');
        if (!slash) return 0;
        p = slash + 1;
    }
}

static FindState *g_find_state = NULL;

static int find_visitor(const char *fpath, const struct stat *sb, int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)ftwbuf;
    FindState *fs = g_find_state;

    if (fs->result_count >= fs->limit) return 0;
    if (typeflag == FTW_D || typeflag == FTW_DNR) return 0;
    if (typeflag != FTW_F) return 0;

    /* Get relative path */
    const char *rel = fpath;
    if (fs->base_len > 0 && strncmp(fpath, fs->base_path, fs->base_len) == 0) {
        rel = fpath + fs->base_len;
        if (rel[0] == '/') rel++;
    }

    if (glob_match(fs->pattern, rel)) {
        if (fs->result_count >= fs->result_cap) {
            fs->result_cap = fs->result_cap ? fs->result_cap * 2 : 64;
            fs->results = xrealloc(fs->results, (size_t)fs->result_cap * sizeof(char*));
        }
        fs->results[fs->result_count++] = xstrdup(rel);
    }
    return 0;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

char *tool_find(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *pattern = NULL, *path = ".";
    int limit = 1000;

    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "pattern");
        if (jp && cJSON_IsString(jp)) pattern = jp->valuestring;
        cJSON *jpa = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jpa && cJSON_IsString(jpa) && jpa->valuestring[0]) path = jpa->valuestring;
        cJSON *jl = cJSON_GetObjectItemCaseSensitive(j, "limit");
        if (jl && cJSON_IsNumber(jl) && jl->valuedouble > 0) limit = (int)jl->valuedouble;
    }

    if (!pattern) { cJSON_Delete(j); return xstrdup("error: pattern is required"); }

    FindState fs = {0};
    fs.pattern   = pattern;
    fs.base_path = path;
    fs.base_len  = strlen(path);
    fs.limit     = limit;

    g_find_state = &fs;
    nftw(path, find_visitor, 20, FTW_PHYS);
    g_find_state = NULL;

    cJSON_Delete(j);

    if (fs.result_count == 0) {
        free(fs.results);
        return xstrdup("No files found");
    }

    /* Sort */
    qsort(fs.results, (size_t)fs.result_count, sizeof(char*), cmp_str);

    /* Join */
    size_t total = 0;
    for (int i = 0; i < fs.result_count; i++) total += strlen(fs.results[i]) + 1;
    char *out = xmalloc(total + 1);
    char *p = out;
    for (int i = 0; i < fs.result_count; i++) {
        size_t sl = strlen(fs.results[i]);
        memcpy(p, fs.results[i], sl);
        p += sl;
        if (i + 1 < fs.result_count) *p++ = '\n';
        free(fs.results[i]);
    }
    *p = '\0';
    free(fs.results);
    return out;
}

/* ---- ls ---- */

static int cmp_dirent(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

char *tool_ls(const char *arguments) {
    cJSON *j = cJSON_Parse(arguments ? arguments : "{}");
    const char *path = ".";
    int limit = 500;

    if (j) {
        cJSON *jp = cJSON_GetObjectItemCaseSensitive(j, "path");
        if (jp && cJSON_IsString(jp) && jp->valuestring[0]) path = jp->valuestring;
        cJSON *jl = cJSON_GetObjectItemCaseSensitive(j, "limit");
        if (jl && cJSON_IsNumber(jl) && jl->valuedouble > 0) limit = (int)jl->valuedouble;
    }

    DIR *d = opendir(path);
    if (!d) {
        char *err = str_printf("error: cannot open directory %s: %s", path, strerror(errno));
        cJSON_Delete(j);
        return err;
    }

    char **names = NULL;
    int count = 0, cap = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL && count < limit) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        /* stat to determine if directory */
        char *full = str_printf("%s/%s", path, ent->d_name);
        struct stat st;
        int is_dir = (stat(full, &st) == 0 && S_ISDIR(st.st_mode));
        free(full);
        char *name = is_dir ? str_printf("%s/", ent->d_name) : xstrdup(ent->d_name);
        if (count >= cap) {
            cap = cap ? cap * 2 : 32;
            names = xrealloc(names, (size_t)cap * sizeof(char*));
        }
        names[count++] = name;
    }
    closedir(d);
    cJSON_Delete(j);

    if (count == 0) {
        free(names);
        return xstrdup("");
    }

    qsort(names, (size_t)count, sizeof(char*), cmp_dirent);

    size_t total = 0;
    for (int i = 0; i < count; i++) total += strlen(names[i]) + 1;
    char *out = xmalloc(total + 1);
    char *p = out;
    for (int i = 0; i < count; i++) {
        size_t sl = strlen(names[i]);
        memcpy(p, names[i], sl);
        p += sl;
        if (i + 1 < count) *p++ = '\n';
        free(names[i]);
    }
    *p = '\0';
    free(names);
    return out;
}
