#pragma once
#include <stddef.h>
#include <stdio.h>

/* Memory helpers - abort on OOM */
void *xmalloc(size_t n);
void *xrealloc(void *p, size_t n);
void *xcalloc(size_t nmemb, size_t size);
char *xstrdup(const char *s);
char *xstrndup(const char *s, size_t n);

/* String helpers */
char *str_append(char *dst, const char *src);
char *str_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* UUID generation */
void gen_uuid(char out[37]);

/* Shell-escape a string for use inside single quotes */
char *shell_escape_sq(const char *s);

/* Create a temp file, write data to it, return path (caller frees) */
char *write_tempfile(const char *data, size_t len);

/* Read all from a FILE* into heap-allocated string (caller frees) */
char *read_all(FILE *f, size_t *out_len);

/* Recursively create directories (like mkdir -p) */
int mkdirp(const char *path, int mode);
