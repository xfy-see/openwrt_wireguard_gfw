/*
 * util.h — 共享工具函数 (header-only)
 *
 * 彩色终端输出、文件读取辅助。
 */

#ifndef UTIL_H
#define UTIL_H

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/*  彩色终端输出                                                       */
/* ------------------------------------------------------------------ */

static inline void color_printf(const char *color, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static inline void color_printf(const char *color, const char *fmt, ...)
{
    va_list ap;
    int is_tty = isatty(fileno(stdout));
    if (is_tty) fputs(color, stdout);
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    if (is_tty) fputs("\033[0m", stdout);
}

#define green(fmt, ...)  color_printf("\033[1;32m", fmt, ##__VA_ARGS__)
#define red(fmt, ...)    color_printf("\033[1;31m", fmt, ##__VA_ARGS__)
#define yellow(fmt, ...) color_printf("\033[1;33m", fmt, ##__VA_ARGS__)

/* ------------------------------------------------------------------ */
/*  文件读取辅助                                                       */
/* ------------------------------------------------------------------ */

/*
 * 将整个文件读取到 malloc 分配的缓冲区中。
 * 成功返回 0，*out_data 和 *out_len 被设置。
 * 失败返回 -1。调用者负责 free(*out_data)。
 */
static inline int read_file(const char *path, uint8_t **out_data, size_t *out_len)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return -1;

    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    if (sz < 0) { fclose(fp); return -1; }
    fseek(fp, 0, SEEK_SET);

    uint8_t *buf = (uint8_t *)malloc((size_t)sz);
    if (!buf) { fclose(fp); return -1; }

    if (fread(buf, 1, (size_t)sz, fp) != (size_t)sz) {
        free(buf);
        fclose(fp);
        return -1;
    }
    fclose(fp);

    *out_data = buf;
    *out_len  = (size_t)sz;
    return 0;
}

/* ------------------------------------------------------------------ */
/*  动态字符串数组                                                     */
/* ------------------------------------------------------------------ */

typedef struct {
    char  **items;
    size_t  count;
    size_t  cap;
} str_array_t;

static inline void str_array_init(str_array_t *a)
{
    a->items = NULL;
    a->count = 0;
    a->cap   = 0;
}

static inline void str_array_push(str_array_t *a, const char *s)
{
    if (a->count >= a->cap) {
        a->cap = a->cap ? a->cap * 2 : 256;
        a->items = (char **)realloc(a->items, a->cap * sizeof(char *));
    }
    a->items[a->count++] = strdup(s);
}

static inline void str_array_free(str_array_t *a)
{
    for (size_t i = 0; i < a->count; i++)
        free(a->items[i]);
    free(a->items);
    a->items = NULL;
    a->count = 0;
    a->cap   = 0;
}

static inline int str_cmp(const void *a, const void *b)
{
    return strcmp(*(const char **)a, *(const char **)b);
}

static inline void str_array_sort(str_array_t *a)
{
    if (a->count > 1)
        qsort(a->items, a->count, sizeof(char *), str_cmp);
}

/*
 * 排序并去重，返回去重后的数量。
 */
static inline size_t str_array_sort_unique(str_array_t *a)
{
    if (a->count <= 1) return a->count;

    str_array_sort(a);

    size_t w = 1;
    for (size_t r = 1; r < a->count; r++) {
        if (strcmp(a->items[r], a->items[w - 1]) != 0) {
            if (w != r) {
                a->items[w] = a->items[r];
            }
            w++;
        } else {
            free(a->items[r]);
        }
    }
    a->count = w;
    return w;
}

#endif /* UTIL_H */
