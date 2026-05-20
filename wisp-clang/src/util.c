#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

void *xmalloc(size_t n) {
    void *p = malloc(n);
    if (!p && n > 0) { perror("malloc"); abort(); }
    return p;
}

void *xrealloc(void *p, size_t n) {
    void *r = realloc(p, n);
    if (!r && n > 0) { perror("realloc"); abort(); }
    return r;
}

void *xcalloc(size_t nmemb, size_t size) {
    void *p = calloc(nmemb, size);
    if (!p && nmemb > 0 && size > 0) { perror("calloc"); abort(); }
    return p;
}

char *xstrdup(const char *s) {
    if (!s) return NULL;
    char *r = strdup(s);
    if (!r) { perror("strdup"); abort(); }
    return r;
}

char *xstrndup(const char *s, size_t n) {
    if (!s) return NULL;
    char *r = strndup(s, n);
    if (!r) { perror("strndup"); abort(); }
    return r;
}

char *str_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0) return xstrdup("");
    char *buf = xmalloc(n + 1);
    va_start(ap, fmt);
    vsnprintf(buf, n + 1, fmt, ap);
    va_end(ap);
    return buf;
}

char *str_append(char *dst, const char *src) {
    if (!src) return dst;
    size_t dl = dst ? strlen(dst) : 0;
    size_t sl = strlen(src);
    char *r = xrealloc(dst, dl + sl + 1);
    memcpy(r + dl, src, sl + 1);
    return r;
}

/* Simple UUID v4 */
void gen_uuid(char out[37]) {
    unsigned char b[16];
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) {
        fread(b, 1, 16, f);
        fclose(f);
    } else {
        for (int i = 0; i < 16; i++) b[i] = (unsigned char)(rand() & 0xff);
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    snprintf(out, 37,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],b[1],b[2],b[3], b[4],b[5], b[6],b[7],
        b[8],b[9], b[10],b[11],b[12],b[13],b[14],b[15]);
}

/* Shell-escape for single-quoted strings: replace ' with '\'' */
char *shell_escape_sq(const char *s) {
    if (!s) return xstrdup("");
    size_t len = strlen(s);
    /* worst case: each ' becomes 4 chars */
    char *out = xmalloc(len * 4 + 1);
    char *p = out;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '\'') {
            *p++ = '\'';
            *p++ = '\\';
            *p++ = '\'';
            *p++ = '\'';
        } else {
            *p++ = s[i];
        }
    }
    *p = '\0';
    return out;
}

char *write_tempfile(const char *data, size_t len) {
    char tmpl[] = "/tmp/wisp_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return NULL;
    size_t written = 0;
    while (written < len) {
        ssize_t n = write(fd, data + written, len - written);
        if (n < 0) { close(fd); unlink(tmpl); return NULL; }
        written += (size_t)n;
    }
    close(fd);
    return xstrdup(tmpl);
}

char *read_all(FILE *f, size_t *out_len) {
    size_t cap = 4096, used = 0;
    char *buf = xmalloc(cap);
    while (!feof(f)) {
        if (used + 1 >= cap) {
            cap *= 2;
            buf = xrealloc(buf, cap);
        }
        size_t n = fread(buf + used, 1, cap - used - 1, f);
        used += n;
    }
    buf[used] = '\0';
    if (out_len) *out_len = used;
    return buf;
}

int mkdirp(const char *path, int mode) {
    char *p = xstrdup(path);
    int ret = 0;
    for (char *q = p + 1; *q; q++) {
        if (*q == '/') {
            *q = '\0';
            if (mkdir(p, (mode_t)mode) < 0 && errno != EEXIST) { ret = -1; break; }
            *q = '/';
        }
    }
    if (ret == 0) {
        if (mkdir(p, (mode_t)mode) < 0 && errno != EEXIST) ret = -1;
    }
    free(p);
    return ret;
}
