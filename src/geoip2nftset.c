/*
 * geoip2nftset.c — 从 geoip.dat 提取国家 IP 段生成 nftables set 定义
 *
 * 从 V2Ray/Xray 的 geoip.dat (protobuf 格式) 中读取指定国家的 CIDR 列表，
 * 生成 nftables set 定义文件，可用 `nft -f` 直接加载。
 *
 * 用法:
 *   geoip2nftset -g /path/to/geoip.dat -c CN -o cn_direct.nft
 *   geoip2nftset -g /path/to/geoip.dat -c CN -l -o cn_cidrs.txt
 *   geoip2nftset -g /path/to/geoip.dat --list-countries
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <strings.h>
#include <getopt.h>
#include <time.h>
#include <arpa/inet.h>

#include "protobuf.h"
#include "util.h"

/* ================================================================== */
/*  geoip.dat protobuf schema:                                         */
/*                                                                      */
/*  message CIDR {                                                      */
/*    bytes  ip     = 1;  // 4 bytes IPv4 or 16 bytes IPv6              */
/*    uint32 prefix = 2;  // prefix length                              */
/*  }                                                                   */
/*  message GeoIP {                                                     */
/*    string        country_code = 1;                                   */
/*    repeated CIDR cidr         = 2;                                   */
/*    bool          reverse_match = 3;  // ignored                      */
/*  }                                                                   */
/*  message GeoIPList {                                                 */
/*    repeated GeoIP entry = 1;                                         */
/*  }                                                                   */
/* ================================================================== */

/* ------------------------------------------------------------------ */
/*  CIDR 解析                                                          */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t  ip[16];
    int      ip_len;  /* 4 = IPv4, 16 = IPv6 */
    uint32_t prefix;
} cidr_t;

static int parse_cidr(const uint8_t *data, size_t len, cidr_t *out)
{
    buf_t b;
    buf_init(&b, data, len);
    memset(out, 0, sizeof(*out));

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t ip;
            if (pb_read_bytes(&b, &ip) < 0) return -1;
            if (ip.len != 4 && ip.len != 16) return -1;
            memcpy(out->ip, ip.data, ip.len);
            out->ip_len = (int)ip.len;
        } else if (tag.field == 2 && tag.wire == WIRE_VARINT) {
            uint64_t v;
            if (pb_read_varint(&b, &v) < 0) return -1;
            out->prefix = (uint32_t)v;
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  将 CIDR 转为字符串 "1.2.3.4/24"                                   */
/* ------------------------------------------------------------------ */

static int cidr_to_str(const cidr_t *c, char *buf, size_t buflen)
{
    char ip_str[INET6_ADDRSTRLEN];
    int af = (c->ip_len == 4) ? AF_INET : AF_INET6;

    if (!inet_ntop(af, c->ip, ip_str, sizeof(ip_str)))
        return -1;

    int n = snprintf(buf, buflen, "%s/%u", ip_str, c->prefix);
    return (n > 0 && (size_t)n < buflen) ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/*  GeoIP 解析：提取 country_code 并收集 CIDR                          */
/* ------------------------------------------------------------------ */

typedef struct {
    char         country_code[16];
    str_array_t  cidrs_v4;
    str_array_t  cidrs_v6;
} geoip_t;

static void geoip_init(geoip_t *g)
{
    g->country_code[0] = '\0';
    str_array_init(&g->cidrs_v4);
    str_array_init(&g->cidrs_v6);
}

static void geoip_free(geoip_t *g)
{
    str_array_free(&g->cidrs_v4);
    str_array_free(&g->cidrs_v6);
}

/*
 * 快速提取 country_code 而不解析所有 CIDR。
 */
static int extract_country_code(const uint8_t *data, size_t len,
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
 * 完整解析 GeoIP：提取 country_code + 所有 CIDR。
 */
static int parse_geoip(const uint8_t *data, size_t len, geoip_t *out)
{
    buf_t b;
    buf_init(&b, data, len);
    geoip_init(out);

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
            pb_bytes_t cidr_data;
            if (pb_read_bytes(&b, &cidr_data) < 0) return -1;

            cidr_t c;
            if (parse_cidr(cidr_data.data, cidr_data.len, &c) == 0 && c.ip_len > 0) {
                char buf[64];
                if (cidr_to_str(&c, buf, sizeof(buf)) == 0) {
                    if (c.ip_len == 4)
                        str_array_push(&out->cidrs_v4, buf);
                    else
                        str_array_push(&out->cidrs_v6, buf);
                }
            }
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  GeoIPList 遍历                                                     */
/* ------------------------------------------------------------------ */

typedef int (*geoip_entry_cb)(const uint8_t *data, size_t len, void *ctx);

static int iter_geoip_list(const uint8_t *data, size_t len, geoip_entry_cb cb, void *ctx)
{
    buf_t b;
    buf_init(&b, data, len);

    pb_tag_t tag;
    while (pb_read_tag(&b, &tag) == 0) {
        if (tag.field == 1 && tag.wire == WIRE_LENGTH_DELIMITED) {
            pb_bytes_t entry;
            if (pb_read_bytes(&b, &entry) < 0) return -1;
            int rc = cb(entry.data, entry.len, ctx);
            if (rc != 0) return rc; /* 1 = found & stop, -1 = error */
        } else {
            if (pb_skip_field(&b, tag.wire) < 0) return -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  list-countries 回调                                                */
/* ------------------------------------------------------------------ */

static int list_country_cb(const uint8_t *data, size_t len, void *ctx)
{
    str_array_t *list = (str_array_t *)ctx;
    char code[16];
    if (extract_country_code(data, len, code, sizeof(code)) == 0 && code[0])
        str_array_push(list, code);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  查找指定国家回调                                                   */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *target;
    geoip_t    *result;
    int         found;
} find_ctx_t;

static int find_country_cb(const uint8_t *data, size_t len, void *ctx)
{
    find_ctx_t *fc = (find_ctx_t *)ctx;
    char code[16];
    if (extract_country_code(data, len, code, sizeof(code)) < 0)
        return 0;

    if (strcasecmp(code, fc->target) == 0) {
        if (parse_geoip(data, len, fc->result) < 0) return -1;
        fc->found = 1;
        return 1; /* stop iteration */
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  输出: nftables set 定义文件                                        */
/* ------------------------------------------------------------------ */

static int write_nft_set_file(const char *output,
                              const str_array_t *v4, const str_array_t *v6,
                              const char *set_v4, const char *set_v6,
                              const char *table_family, const char *table_name,
                              int ipv4_only, int ipv6_only)
{
    FILE *fp = fopen(output, "w");
    if (!fp) { perror(output); return -1; }

    time_t now = time(NULL);
    struct tm *tm = localtime(&now);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", tm);

    fprintf(fp, "# Generated by geoip2nftset — %s\n", ts);
    fprintf(fp, "# IPv4 CIDRs: %zu  IPv6 CIDRs: %zu\n", v4->count, v6->count);
    fprintf(fp, "\n");
    fprintf(fp, "table %s %s {\n", table_family, table_name);

    if (!ipv6_only && v4->count > 0) {
        fprintf(fp, "    set %s {\n", set_v4);
        fprintf(fp, "        type ipv4_addr\n");
        fprintf(fp, "        flags interval\n");
        fprintf(fp, "        elements = {\n");
        for (size_t i = 0; i < v4->count; i++) {
            fprintf(fp, "            %s%s\n",
                    v4->items[i], (i < v4->count - 1) ? "," : "");
        }
        fprintf(fp, "        }\n");
        fprintf(fp, "    }\n");
    }

    if (!ipv4_only && !ipv6_only && v4->count > 0 && v6->count > 0)
        fprintf(fp, "\n");

    if (!ipv4_only && v6->count > 0) {
        fprintf(fp, "    set %s {\n", set_v6);
        fprintf(fp, "        type ipv6_addr\n");
        fprintf(fp, "        flags interval\n");
        fprintf(fp, "        elements = {\n");
        for (size_t i = 0; i < v6->count; i++) {
            fprintf(fp, "            %s%s\n",
                    v6->items[i], (i < v6->count - 1) ? "," : "");
        }
        fprintf(fp, "        }\n");
        fprintf(fp, "    }\n");
    }

    fprintf(fp, "}\n");
    fclose(fp);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  输出: 纯 CIDR 列表                                                */
/* ------------------------------------------------------------------ */

static int write_cidr_list(const char *output,
                           const str_array_t *v4, const str_array_t *v6,
                           int ipv4_only, int ipv6_only)
{
    FILE *fp = fopen(output, "w");
    if (!fp) { perror(output); return -1; }

    if (!ipv6_only) {
        for (size_t i = 0; i < v4->count; i++)
            fprintf(fp, "%s\n", v4->items[i]);
    }
    if (!ipv4_only) {
        for (size_t i = 0; i < v6->count; i++)
            fprintf(fp, "%s\n", v6->items[i]);
    }
    fclose(fp);
    return 0;
}

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */

static void print_usage(const char *prog)
{
    printf("用法: %s [选项]\n\n", prog);
    printf("从 geoip.dat 提取国家 IP 段生成 nftables set 定义文件\n\n");
    printf("选项:\n");
    printf("  -g, --geoip FILE       geoip.dat 文件路径（必填）\n");
    printf("  -c, --country CODE     国家代码（默认: CN）\n");
    printf("  -o, --output FILE      输出文件路径\n");
    printf("      --nft-table TABLE  nftables 表，格式: 'family name'（默认: inet fw4）\n");
    printf("      --nft-set-v4 NAME  IPv4 set 名称（默认: cn_list_v4）\n");
    printf("      --nft-set-v6 NAME  IPv6 set 名称（默认: cn_list_v6）\n");
    printf("  -4, --ipv4-only        只输出 IPv4 CIDR\n");
    printf("  -6, --ipv6-only        只输出 IPv6 CIDR\n");
    printf("  -l, --cidr-list        输出纯 CIDR 列表而非 nftables set 定义\n");
    printf("      --list-countries   列出所有可用国家代码并退出\n");
    printf("  -h, --help             显示此帮助信息\n");
    printf("\n示例:\n");
    printf("  %s -g geoip.dat -c CN -o cn_direct.nft\n", prog);
    printf("  %s -g geoip.dat -c CN -l -o cn_cidrs.txt\n", prog);
    printf("  %s -g geoip.dat --list-countries\n", prog);
}

int main(int argc, char *argv[])
{
    const char *geoip_path = NULL;
    const char *country    = "CN";
    const char *output     = NULL;
    const char *nft_table  = "inet fw4";
    const char *set_v4     = "cn_list_v4";
    const char *set_v6     = "cn_list_v6";
    int ipv4_only      = 0;
    int ipv6_only      = 0;
    int cidr_list_mode = 0;
    int list_countries = 0;

    static struct option long_opts[] = {
        {"geoip",          required_argument, 0, 'g'},
        {"country",        required_argument, 0, 'c'},
        {"output",         required_argument, 0, 'o'},
        {"nft-table",      required_argument, 0, 'T'},
        {"nft-set-v4",     required_argument, 0, 'V'},
        {"nft-set-v6",     required_argument, 0, 'W'},
        {"ipv4-only",      no_argument,       0, '4'},
        {"ipv6-only",      no_argument,       0, '6'},
        {"cidr-list",      no_argument,       0, 'l'},
        {"list-countries", no_argument,       0, 'L'},
        {"help",           no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "g:c:o:46lh", long_opts, NULL)) != -1) {
        switch (opt) {
        case 'g': geoip_path = optarg; break;
        case 'c': country    = optarg; break;
        case 'o': output     = optarg; break;
        case 'T': nft_table  = optarg; break;
        case 'V': set_v4     = optarg; break;
        case 'W': set_v6     = optarg; break;
        case '4': ipv4_only  = 1; break;
        case '6': ipv6_only  = 1; break;
        case 'l': cidr_list_mode = 1; break;
        case 'L': list_countries = 1; break;
        case 'h': print_usage(argv[0]); return 0;
        default:  print_usage(argv[0]); return 1;
        }
    }

    /* 参数验证 */
    if (!geoip_path) {
        red("错误: 请使用 -g/--geoip 指定 geoip.dat 文件路径。\n");
        return 1;
    }
    if (ipv4_only && ipv6_only) {
        red("错误: -4 和 -6 不能同时使用。\n");
        return 1;
    }
    if (!list_countries && !output) {
        red("错误: 请使用 -o/--output 指定输出文件路径。\n");
        return 1;
    }

    /* 解析 nft_table: "inet fw4" → family="inet", name="fw4" */
    char table_family[32] = "inet", table_name[64] = "";
    {
        const char *sp = strchr(nft_table, ' ');
        if (sp) {
            size_t flen = (size_t)(sp - nft_table);
            if (flen >= sizeof(table_family)) flen = sizeof(table_family) - 1;
            memcpy(table_family, nft_table, flen);
            table_family[flen] = '\0';
            strncpy(table_name, sp + 1, sizeof(table_name) - 1);
        } else {
            strncpy(table_name, nft_table, sizeof(table_name) - 1);
        }
    }

    /* 读取 geoip.dat */
    printf("正在读取 %s ... ", geoip_path);
    fflush(stdout);

    uint8_t *raw_data;
    size_t raw_len;
    if (read_file(geoip_path, &raw_data, &raw_len) < 0) {
        red("\n错误: 无法读取文件: %s\n", geoip_path);
        return 1;
    }
    green("完成 (%zu KB)\n", raw_len / 1024);

    /* list-countries 模式 */
    if (list_countries) {
        str_array_t countries;
        str_array_init(&countries);
        iter_geoip_list(raw_data, raw_len, list_country_cb, &countries);
        str_array_sort(&countries);

        printf("\n可用国家代码列表:\n");
        printf("============================================================\n");
        for (size_t i = 0; i < countries.count; i++)
            printf("  %4zu. %s\n", i + 1, countries.items[i]);
        printf("============================================================\n");
        printf("共 %zu 个国家/地区\n", countries.count);

        str_array_free(&countries);
        free(raw_data);
        return 0;
    }

    /* 查找指定国家 */
    printf("正在查找国家代码 '%s' ... ", country);
    fflush(stdout);

    geoip_t geoip;
    find_ctx_t fc = { .target = country, .result = &geoip, .found = 0 };
    iter_geoip_list(raw_data, raw_len, find_country_cb, &fc);

    if (!fc.found) {
        red("\n错误: 未找到国家代码 '%s'\n", country);
        red("使用 --list-countries 查看所有可用国家代码。\n");
        free(raw_data);
        return 1;
    }

    size_t total = geoip.cidrs_v4.count + geoip.cidrs_v6.count;
    green("找到！共 %zu 条 CIDR\n", total);

    printf("\nCIDR 统计:\n");
    printf("  IPv4: %zu 条\n", geoip.cidrs_v4.count);
    printf("  IPv6: %zu 条\n", geoip.cidrs_v6.count);

    if (total == 0) {
        red("\n错误: 没有提取到任何 CIDR。\n");
        geoip_free(&geoip);
        free(raw_data);
        return 1;
    }

    /* 排序 */
    str_array_sort(&geoip.cidrs_v4);
    str_array_sort(&geoip.cidrs_v6);

    /* 生成输出 */
    printf("\n正在生成输出文件 %s ... ", output);
    fflush(stdout);

    int rc;
    if (cidr_list_mode) {
        rc = write_cidr_list(output, &geoip.cidrs_v4, &geoip.cidrs_v6,
                             ipv4_only, ipv6_only);
        if (rc == 0) {
            green("完成\n");
            size_t count = 0;
            if (!ipv6_only) count += geoip.cidrs_v4.count;
            if (!ipv4_only) count += geoip.cidrs_v6.count;
            printf("已生成纯 CIDR 列表，共 %zu 条。\n\n", count);
        }
    } else {
        rc = write_nft_set_file(output,
                                &geoip.cidrs_v4, &geoip.cidrs_v6,
                                set_v4, set_v6,
                                table_family, table_name,
                                ipv4_only, ipv6_only);
        if (rc == 0) {
            green("完成\n");
            size_t v4c = ipv6_only ? 0 : geoip.cidrs_v4.count;
            size_t v6c = ipv4_only ? 0 : geoip.cidrs_v6.count;
            if (v4c) printf("  %s (%zu 条 IPv4)\n", set_v4, v4c);
            if (v6c) printf("  %s (%zu 条 IPv6)\n", set_v6, v6c);
            printf("\n加载方法: nft -f %s\n\n", output);
        }
    }

    if (rc == 0) green("任务完成。\n");
    else         red("错误: 写入文件失败。\n");

    geoip_free(&geoip);
    free(raw_data);
    return rc;
}
