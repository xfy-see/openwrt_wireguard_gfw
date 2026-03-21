/*
 * geosite2nftset.c — 从 geosite.dat 生成 dnsmasq nftset 配置
 *
 * 从 V2Ray/Xray 的 geosite.dat (protobuf 格式) 中读取指定分类的域名列表，
 * 生成 dnsmasq 的 server + nftset 配置文件。
 *
 * 用法:
 *   geosite2nftset -g /path/to/geosite.dat -c google -n "4#inet#fw4#google" -o google.conf
 *   geosite2nftset -g /path/to/geosite.dat -c cn -l -o cn_domains.txt
 *   geosite2nftset -g /path/to/geosite.dat --list-categories
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <getopt.h>
#include <time.h>

#include "protobuf.h"
#include "util.h"

/* ================================================================== */
/*  geosite.dat protobuf schema:                                       */
/*                                                                      */
/*  message Domain {                                                    */
/*    enum Type { Plain=0; Regex=1; RootDomain=2; Full=3; }             */
/*    Type   type  = 1;  // varint                                      */
/*    string value = 2;  // length-delimited                            */
/*    repeated Attribute attribute = 3;  // ignored                     */
/*  }                                                                   */
/*  message GeoSite {                                                   */
/*    string         country_code = 1;                                  */
/*    repeated Domain domain      = 2;                                  */
/*  }                                                                   */
/*  message GeoSiteList {                                               */
/*    repeated GeoSite entry = 1;                                       */
/*  }                                                                   */
/* ================================================================== */

/* Domain types */
enum {
    DOMAIN_TYPE_PLAIN       = 0,
    DOMAIN_TYPE_REGEX       = 1,
    DOMAIN_TYPE_ROOT_DOMAIN = 2,
    DOMAIN_TYPE_FULL        = 3,
};

static const char *domain_type_name(int t)
{
    switch (t) {
    case DOMAIN_TYPE_PLAIN:       return "plain";
    case DOMAIN_TYPE_REGEX:       return "regex";
    case DOMAIN_TYPE_ROOT_DOMAIN: return "domain";
    case DOMAIN_TYPE_FULL:        return "full";
    default:                      return "unknown";
    }
}

/* ------------------------------------------------------------------ */
/*  Domain 解析                                                        */
/* ------------------------------------------------------------------ */

typedef struct {
    int  type;
    char value[512];
} domain_t;

static int parse_domain(const uint8_t *data, size_t len, domain_t *out)
{
    buf_t b;
    buf_init(&b, data, len);
    out->type = DOMAIN_TYPE_PLAIN;
    out->value[0] = '\0';

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_VARINT) {
            uint64_t v;
            if (pb_read_varint(&b, &v) < 0) return -1;
            out->type = (int)v;
        } else if (tag.field == 2 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t s;
            if (pb_read_bytes(&b, &s) < 0) return -1;
            size_t copy = (s.len < sizeof(out->value) - 1)
                              ? s.len : sizeof(out->value) - 1;
            memcpy(out->value, s.data, copy);
            out->value[copy] = '\0';
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  GeoSite 解析                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
    char      country_code[64];
    domain_t *domains;
    size_t    domain_count;
    size_t    domain_cap;
} geosite_t;

static void geosite_init(geosite_t *g)
{
    g->country_code[0] = '\0';
    g->domains = NULL;
    g->domain_count = 0;
    g->domain_cap = 0;
}

static void geosite_free(geosite_t *g)
{
    free(g->domains);
    g->domains = NULL;
    g->domain_count = 0;
    g->domain_cap = 0;
}

static void geosite_push_domain(geosite_t *g, const domain_t *d)
{
    if (g->domain_count >= g->domain_cap) {
        g->domain_cap = g->domain_cap ? g->domain_cap * 2 : 512;
        g->domains = (domain_t *)realloc(g->domains,
                                         g->domain_cap * sizeof(domain_t));
    }
    g->domains[g->domain_count++] = *d;
}

/*
 * 快速提取 country_code。
 */
static int geosite_extract_code(const uint8_t *data, size_t len,
                                char *code, size_t code_len)
{
    buf_t b;
    buf_init(&b, data, len);

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t s;
            if (pb_read_bytes(&b, &s) < 0) return -1;
            size_t copy = (s.len < code_len - 1) ? s.len : code_len - 1;
            memcpy(code, s.data, copy);
            code[copy] = '\0';
            return 0;
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    code[0] = '\0';
    return -1;
}

/*
 * 完整解析 GeoSite。
 */
static int parse_geosite(const uint8_t *data, size_t len, geosite_t *out)
{
    buf_t b;
    buf_init(&b, data, len);
    geosite_init(out);

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t s;
            if (pb_read_bytes(&b, &s) < 0) return -1;
            size_t copy = (s.len < sizeof(out->country_code) - 1)
                              ? s.len : sizeof(out->country_code) - 1;
            memcpy(out->country_code, s.data, copy);
            out->country_code[copy] = '\0';
        } else if (tag.field == 2 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t dom_data;
            if (pb_read_bytes(&b, &dom_data) < 0) return -1;
            domain_t d;
            if (parse_domain(dom_data.data, dom_data.len, &d) == 0)
                geosite_push_domain(out, &d);
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  GeoSiteList 遍历                                                   */
/* ------------------------------------------------------------------ */

typedef int (*geosite_entry_cb)(const uint8_t *data, size_t len, void *ctx);

static int iter_geosite_list(const uint8_t *data, size_t len,
                             geosite_entry_cb cb, void *ctx)
{
    buf_t b;
    buf_init(&b, data, len);

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t entry;
            if (pb_read_bytes(&b, &entry) < 0) return -1;
            int rc = cb(entry.data, entry.len, ctx);
            if (rc != 0) return rc;
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  list-categories 回调                                               */
/* ------------------------------------------------------------------ */

static int list_cat_cb(const uint8_t *data, size_t len, void *ctx)
{
    str_array_t *list = (str_array_t *)ctx;
    char code[64];
    if (geosite_extract_code(data, len, code, sizeof(code)) == 0 && code[0])
        str_array_push(list, code);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  查找指定分类回调                                                   */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *target;
    geosite_t  *result;
    int         found;
} find_site_ctx_t;

static int find_cat_cb(const uint8_t *data, size_t len, void *ctx)
{
    find_site_ctx_t *fc = (find_site_ctx_t *)ctx;
    char code[64];
    if (geosite_extract_code(data, len, code, sizeof(code)) < 0)
        return 0;

    if (strcasecmp(code, fc->target) == 0) {
        if (parse_geosite(data, len, fc->result) < 0) return -1;
        fc->found = 1;
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  DNS IP 验证                                                        */
/* ------------------------------------------------------------------ */

static int is_valid_ip(const char *s)
{
    /* 简单检查：包含 . 或 : 且仅由合法字符组成 */
    int has_dot = 0, has_colon = 0;
    for (const char *p = s; *p; p++) {
        if (*p == '.') has_dot = 1;
        else if (*p == ':') has_colon = 1;
        else if (!isxdigit((unsigned char)*p)) return 0;
    }
    return has_dot || has_colon;
}

/* ------------------------------------------------------------------ */
/*  输出: dnsmasq server + nftset 配置                                 */
/* ------------------------------------------------------------------ */

static int write_dnsmasq_conf(const char *output,
                              const str_array_t *domains,
                              const char *dns_ip, int dns_port,
                              const char *nftset_name)
{
    FILE *fp = fopen(output, "w");
    if (!fp) { perror(output); return -1; }

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

    fprintf(fp, "# dnsmasq nftset rules generated by geosite2nftset\n");
    fprintf(fp, "# Last Updated on %s\n", ts);
    fprintf(fp, "# Category domains: %zu\n", domains->count);
    fprintf(fp, "#\n");

    for (size_t i = 0; i < domains->count; i++) {
        fprintf(fp, "server=/%s/%s#%d\n", domains->items[i], dns_ip, dns_port);
        if (nftset_name && nftset_name[0])
            fprintf(fp, "nftset=/%s/%s\n", domains->items[i], nftset_name);
    }

    fclose(fp);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  输出: 纯域名列表                                                   */
/* ------------------------------------------------------------------ */

static int write_domain_list(const char *output, const str_array_t *domains)
{
    FILE *fp = fopen(output, "w");
    if (!fp) { perror(output); return -1; }

    for (size_t i = 0; i < domains->count; i++)
        fprintf(fp, "%s\n", domains->items[i]);

    fclose(fp);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */

static void print_usage(const char *prog)
{
    printf("用法: %s [选项]\n\n", prog);
    printf("从 geosite.dat 生成 dnsmasq nftset 配置文件\n\n");
    printf("选项:\n");
    printf("  -g, --geosite FILE      geosite.dat 文件路径（必填）\n");
    printf("  -c, --category NAME     geosite 分类名称（默认: google）\n");
    printf("  -d, --dns IP            DNS 服务器地址（默认: 127.0.0.1）\n");
    printf("  -p, --port PORT         DNS 端口（默认: 5353）\n");
    printf("  -n, --nftset NAME       nftset 名称: family#table_family#table#set\n");
    printf("  -o, --output FILE       输出文件路径\n");
    printf("  -l, --domain-list       仅输出域名列表\n");
    printf("      --list-categories   列出所有可用分类并退出\n");
    printf("      --include-regex     包含 regex 类型规则\n");
    printf("      --include-plain     包含 plain（关键字）类型规则\n");
    printf("  -h, --help              显示此帮助信息\n");
    printf("\n示例:\n");
    printf("  %s -g geosite.dat -c google -n \"4#inet#fw4#google\" -o google.conf\n", prog);
    printf("  %s -g geosite.dat -c cn -l -o cn_domains.txt\n", prog);
    printf("  %s -g geosite.dat --list-categories\n", prog);
}

int main(int argc, char *argv[])
{
    const char *geosite_path  = NULL;
    const char *category      = "google";
    const char *dns_ip        = "127.0.0.1";
    int         dns_port      = 5353;
    const char *nftset_name   = "";
    const char *output        = NULL;
    int         domain_list_mode = 0;
    int         list_categories  = 0;
    int         include_regex    = 0;
    int         include_plain    = 0;

    static struct option long_opts[] = {
        {"geosite",         required_argument, 0, 'g'},
        {"category",        required_argument, 0, 'c'},
        {"dns",             required_argument, 0, 'd'},
        {"port",            required_argument, 0, 'p'},
        {"nftset",          required_argument, 0, 'n'},
        {"output",          required_argument, 0, 'o'},
        {"domain-list",     no_argument,       0, 'l'},
        {"list-categories", no_argument,       0, 'C'},
        {"include-regex",   no_argument,       0, 'R'},
        {"include-plain",   no_argument,       0, 'P'},
        {"help",            no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "g:c:d:p:n:o:lh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'g': geosite_path    = optarg; break;
        case 'c': category        = optarg; break;
        case 'd': dns_ip          = optarg; break;
        case 'p': dns_port        = atoi(optarg); break;
        case 'n': nftset_name     = optarg; break;
        case 'o': output          = optarg; break;
        case 'l': domain_list_mode = 1; break;
        case 'C': list_categories  = 1; break;
        case 'R': include_regex    = 1; break;
        case 'P': include_plain    = 1; break;
        case 'h': print_usage(argv[0]); return 0;
        default:  print_usage(argv[0]); return 1;
        }
    }

    /* 参数验证 */
    if (!geosite_path) {
        red("错误: 请使用 -g/--geosite 指定 geosite.dat 文件路径。\n");
        return 1;
    }
    if (!list_categories && !output) {
        red("错误: 请使用 -o/--output 指定输出文件路径。\n");
        return 1;
    }

    if (!domain_list_mode && !list_categories) {
        if (!is_valid_ip(dns_ip)) {
            red("错误: 无效的 DNS 服务器地址: %s\n", dns_ip);
            return 1;
        }
        if (dns_port < 1 || dns_port > 65535) {
            red("错误: 无效的 DNS 端口: %d\n", dns_port);
            return 1;
        }
    }

    /* 读取 geosite.dat */
    printf("正在读取 %s ... ", geosite_path);
    fflush(stdout);

    uint8_t *raw_data;
    size_t raw_len;
    if (read_file(geosite_path, &raw_data, &raw_len) < 0) {
        red("\n错误: 无法读取文件: %s\n", geosite_path);
        return 1;
    }
    green("完成 (%.1f MB)\n", (double)raw_len / (1024.0 * 1024.0));

    /* list-categories 模式 */
    if (list_categories) {
        str_array_t cats;
        str_array_init(&cats);
        iter_geosite_list(raw_data, raw_len, list_cat_cb, &cats);
        str_array_sort(&cats);

        printf("\n可用分类列表:\n");
        printf("============================================================\n");
        for (size_t i = 0; i < cats.count; i++)
            printf("  %4zu. %s\n", i + 1, cats.items[i]);
        printf("============================================================\n");
        printf("共 %zu 个分类\n", cats.count);

        str_array_free(&cats);
        free(raw_data);
        return 0;
    }

    /* 查找指定分类 */
    printf("正在查找分类 '%s' ... ", category);
    fflush(stdout);

    geosite_t site;
    find_site_ctx_t fc = { .target = category, .result = &site, .found = 0 };
    iter_geosite_list(raw_data, raw_len, find_cat_cb, &fc);

    if (!fc.found) {
        red("\n错误: 未找到分类 '%s'\n", category);
        red("使用 --list-categories 查看所有可用分类。\n");
        free(raw_data);
        return 1;
    }

    green("找到！共 %zu 条规则\n", site.domain_count);

    /* 提取域名 */
    str_array_t domains;
    str_array_init(&domains);

    int stats[4]   = {0, 0, 0, 0};
    int skipped[4] = {0, 0, 0, 0};

    for (size_t i = 0; i < site.domain_count; i++) {
        domain_t *d = &site.domains[i];
        int t = d->type;
        if (t >= 0 && t <= 3) stats[t]++;

        if (t == DOMAIN_TYPE_ROOT_DOMAIN || t == DOMAIN_TYPE_FULL) {
            str_array_push(&domains, d->value);
        } else if (t == DOMAIN_TYPE_REGEX && include_regex) {
            str_array_push(&domains, d->value);
        } else if (t == DOMAIN_TYPE_PLAIN && include_plain) {
            str_array_push(&domains, d->value);
        } else {
            if (t >= 0 && t <= 3) skipped[t]++;
        }
    }

    /* 统计 */
    printf("\n域名规则统计:\n");
    for (int t = 0; t <= 3; t++) {
        if (stats[t] > 0) {
            int extracted = stats[t] - skipped[t];
            printf("  %-12s: %5d 条  (已提取 %d", domain_type_name(t),
                   stats[t], extracted);
            if (skipped[t] > 0)
                printf("，跳过 %d", skipped[t]);
            printf(")\n");
        }
    }

    if (domains.count == 0) {
        red("\n错误: 没有提取到任何域名。\n");
        geosite_free(&site);
        free(raw_data);
        return 1;
    }

    /* 去重并排序 */
    size_t unique_count = str_array_sort_unique(&domains);

    /* 生成输出 */
    printf("\n正在生成输出文件 %s ... ", output);
    fflush(stdout);

    int rc;
    if (domain_list_mode) {
        rc = write_domain_list(output, &domains);
        if (rc == 0) {
            green("完成\n");
            printf("已生成域名列表，共 %zu 个唯一域名。\n\n", unique_count);
        }
    } else {
        rc = write_dnsmasq_conf(output, &domains, dns_ip, dns_port, nftset_name);
        if (rc == 0) {
            green("完成\n");
            const char *mode = (nftset_name && nftset_name[0])
                                   ? "server + nftset" : "server";
            printf("已生成 dnsmasq %s 配置，共 %zu 个唯一域名。\n\n",
                   mode, unique_count);
        }
    }

    if (rc == 0) green("任务完成。\n");
    else         red("错误: 写入文件失败。\n");

    str_array_free(&domains);
    geosite_free(&site);
    free(raw_data);
    return rc;
}
