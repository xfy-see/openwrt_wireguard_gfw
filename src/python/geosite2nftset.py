#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
geosite2nftset.py - 从 geosite.dat 生成 dnsmasq nftset 配置

从 V2Ray/Xray 的 geosite.dat (protobuf 格式) 中读取指定分类的域名列表，
生成 dnsmasq 的 server + nftset 配置文件，用于配合 nftables 实现基于域名的流量分流。

无需外部依赖，纯 Python 3 标准库实现 protobuf 解码。

用法:
    python3 geosite2nftset.py -c google -n "4#inet#fw4#google" -o google_nftset.conf
    python3 geosite2nftset.py -g /path/to/geosite.dat -c google -l -o google_domains.txt
"""

import argparse
import io
import os
import re
import struct
import sys
import tempfile
import urllib.request
from datetime import datetime

# ============================================================================
# Protobuf 手动解码器（无需外部依赖）
# ============================================================================
# geosite.dat 使用 proto3 格式，结构如下:
#
# message Domain {
#   enum Type { Plain=0; Regex=1; RootDomain=2; Full=3; }
#   Type type = 1;      // varint
#   string value = 2;   // length-delimited
#   repeated Attribute attribute = 3;  // length-delimited (忽略)
# }
#
# message GeoSite {
#   string country_code = 1;    // length-delimited
#   repeated Domain domain = 2; // length-delimited
# }
#
# message GeoSiteList {
#   repeated GeoSite entry = 1; // length-delimited
# }

# Protobuf wire types
WIRE_VARINT = 0
WIRE_64BIT = 1
WIRE_LENGTH_DELIMITED = 2
WIRE_32BIT = 5

# Domain types
DOMAIN_TYPE_PLAIN = 0
DOMAIN_TYPE_REGEX = 1
DOMAIN_TYPE_ROOT_DOMAIN = 2
DOMAIN_TYPE_FULL = 3

DOMAIN_TYPE_NAMES = {
    DOMAIN_TYPE_PLAIN: "plain",
    DOMAIN_TYPE_REGEX: "regex",
    DOMAIN_TYPE_ROOT_DOMAIN: "domain",
    DOMAIN_TYPE_FULL: "full",
}

GEOSITE_URL = "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"


def read_varint(stream: io.BytesIO) -> int:
    """从字节流中读取 protobuf varint 编码的整数。"""
    result = 0
    shift = 0
    while True:
        byte = stream.read(1)
        if not byte:
            raise EOFError("Unexpected end of stream while reading varint")
        b = byte[0]
        result |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            break
        shift += 7
    return result


def read_tag(stream: io.BytesIO):
    """读取 protobuf 字段标签，返回 (field_number, wire_type) 或 None。"""
    try:
        varint = read_varint(stream)
    except EOFError:
        return None
    field_number = varint >> 3
    wire_type = varint & 0x07
    return field_number, wire_type


def skip_field(stream: io.BytesIO, wire_type: int):
    """跳过不需要解析的字段。"""
    if wire_type == WIRE_VARINT:
        read_varint(stream)
    elif wire_type == WIRE_64BIT:
        stream.read(8)
    elif wire_type == WIRE_LENGTH_DELIMITED:
        length = read_varint(stream)
        stream.read(length)
    elif wire_type == WIRE_32BIT:
        stream.read(4)
    else:
        raise ValueError(f"Unknown wire type: {wire_type}")


def parse_domain(data: bytes) -> dict:
    """解析 Domain 消息，返回 {'type': int, 'value': str}。"""
    stream = io.BytesIO(data)
    domain = {"type": DOMAIN_TYPE_PLAIN, "value": ""}

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_VARINT:
            # type 字段
            domain["type"] = read_varint(stream)
        elif field_number == 2 and wire_type == WIRE_LENGTH_DELIMITED:
            # value 字段
            length = read_varint(stream)
            domain["value"] = stream.read(length).decode("utf-8")
        else:
            # 跳过 attribute 等其他字段
            skip_field(stream, wire_type)

    return domain


def parse_geosite(data: bytes) -> dict:
    """解析 GeoSite 消息，返回 {'country_code': str, 'domains': [dict]}。"""
    stream = io.BytesIO(data)
    geosite = {"country_code": "", "domains": []}

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            # country_code 字段
            length = read_varint(stream)
            geosite["country_code"] = stream.read(length).decode("utf-8")
        elif field_number == 2 and wire_type == WIRE_LENGTH_DELIMITED:
            # domain 字段（repeated）
            length = read_varint(stream)
            domain_data = stream.read(length)
            geosite["domains"].append(parse_domain(domain_data))
        else:
            skip_field(stream, wire_type)

    return geosite


def parse_geosite_list(data: bytes):
    """解析 GeoSiteList，生成器逐个 yield GeoSite。

    为了节省内存，遇到匹配的 country_code 时才完整解析。
    """
    stream = io.BytesIO(data)

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            # entry 字段（repeated GeoSite）
            length = read_varint(stream)
            entry_data = stream.read(length)
            yield entry_data
        else:
            skip_field(stream, wire_type)


def extract_country_code_fast(data: bytes) -> str:
    """快速提取 GeoSite 的 country_code 而不完整解析所有域名。"""
    stream = io.BytesIO(data)

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            length = read_varint(stream)
            return stream.read(length).decode("utf-8")
        else:
            skip_field(stream, wire_type)

    return ""


# ============================================================================
# 输出和辅助函数
# ============================================================================

def color_print(text: str, color_code: str):
    """彩色终端输出。"""
    if sys.stdout.isatty():
        print(f"\033[1;{color_code}m{text}\033[0m", end="")
    else:
        print(text, end="")


def green(text: str):
    color_print(text, "32")


def red(text: str):
    color_print(text, "31")


def yellow(text: str):
    color_print(text, "33")


def download_geosite(url: str, dest: str):
    """下载 geosite.dat 文件。"""
    print(f"正在从 {url} 下载 geosite.dat ...")
    try:
        urllib.request.urlretrieve(url, dest)
        green("下载完成。\n")
    except Exception as e:
        red(f"\n下载失败: {e}\n")
        red("请检查网络连接，或使用 -g 参数指定本地 geosite.dat 文件。\n")
        sys.exit(2)


def list_categories(data: bytes):
    """列出 geosite.dat 中所有可用的分类名称。"""
    categories = []
    for entry_data in parse_geosite_list(data):
        code = extract_country_code_fast(entry_data)
        if code:
            categories.append(code)
    return sorted(categories)


def generate_dnsmasq_nftset_conf(
    domains: list,
    dns_ip: str,
    dns_port: int,
    nftset_name: str,
    output_file: str,
):
    """生成 dnsmasq server + nftset 配置文件。"""
    # 去重并排序
    unique_domains = sorted(set(domains))

    lines = []
    lines.append("# dnsmasq nftset rules generated by geosite2nftset")
    lines.append(f"# Last Updated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"# Category domains: {len(unique_domains)}")
    lines.append("#")

    for domain in unique_domains:
        lines.append(f"server=/{domain}/{dns_ip}#{dns_port}")
        if nftset_name:
            lines.append(f"nftset=/{domain}/{nftset_name}")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    return len(unique_domains)


def generate_domain_list(domains: list, output_file: str):
    """生成纯域名列表文件。"""
    unique_domains = sorted(set(domains))

    with open(output_file, "w", encoding="utf-8") as f:
        for domain in unique_domains:
            f.write(domain + "\n")

    return len(unique_domains)


# ============================================================================
# 主逻辑
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="从 geosite.dat 生成 dnsmasq nftset 配置文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 生成 google 分类的 dnsmasq nftset 配置（自动下载 geosite.dat）
  %(prog)s -c google -n "4#inet#fw4#google" -o google_nftset.conf

  # 使用本地 geosite.dat 文件
  %(prog)s -g /path/to/geosite.dat -c google -n "4#inet#fw4#google" -o google.conf

  # 仅输出域名列表
  %(prog)s -c google -l -o google_domains.txt

  # 列出 geosite.dat 中所有可用分类
  %(prog)s -g /path/to/geosite.dat --list-categories
        """,
    )
    parser.add_argument(
        "-g", "--geosite",
        help="geosite.dat 文件路径（默认自动下载最新版本）",
    )
    parser.add_argument(
        "-c", "--category",
        default="google",
        help="geosite 分类名称（默认: google）",
    )
    parser.add_argument(
        "-d", "--dns",
        default="127.0.0.1",
        help="DNS 服务器 IP 地址（默认: 127.0.0.1）",
    )
    parser.add_argument(
        "-p", "--port",
        type=int,
        default=5353,
        help="DNS 服务器端口（默认: 5353）",
    )
    parser.add_argument(
        "-n", "--nftset",
        default="",
        help="nftset 名称，格式: family#table_family#table#set（如 4#inet#fw4#google）",
    )
    parser.add_argument(
        "-o", "--output",
        help="输出文件路径（必填，除非使用 --list-categories）",
    )
    parser.add_argument(
        "-l", "--domain-list",
        action="store_true",
        help="仅输出域名列表而非 dnsmasq 规则",
    )
    parser.add_argument(
        "--list-categories",
        action="store_true",
        help="列出 geosite.dat 中所有可用分类并退出",
    )
    parser.add_argument(
        "--include-regex",
        action="store_true",
        help="是否包含 regex 类型的域名规则（默认忽略）",
    )
    parser.add_argument(
        "--include-plain",
        action="store_true",
        help="是否包含 plain（关键字）类型的域名规则（默认忽略）",
    )

    args = parser.parse_args()

    # 参数验证
    if not args.list_categories and not args.output:
        red("错误: 请使用 -o/--output 指定输出文件路径。\n")
        parser.print_help()
        sys.exit(1)

    if not args.domain_list and not args.list_categories:
        # 验证 DNS IP
        ipv4_pattern = r"^((25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(25[0-5]|2[0-4]\d|[01]?\d\d?)$"
        ipv6_pattern = r"^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$"
        if not re.match(ipv4_pattern, args.dns) and not re.match(ipv6_pattern, args.dns):
            red(f"错误: 无效的 DNS 服务器地址: {args.dns}\n")
            sys.exit(1)

        # 验证端口
        if args.port < 1 or args.port > 65535:
            red(f"错误: 无效的 DNS 端口: {args.port}\n")
            sys.exit(1)

        # 验证 nftset 名称格式: family#table_family#table_name#set_name
        if args.nftset and not re.match(r"^[a-zA-Z0-9_]+(#[a-zA-Z0-9_]+){2,3}$", args.nftset):
            red(f"错误: 无效的 nftset 名称格式: {args.nftset}\n")
            red("正确格式: family#table_family#table#set（如 4#inet#fw4#google）\n")
            sys.exit(1)

    # 获取 geosite.dat
    geosite_path = args.geosite
    tmp_file = None

    if not geosite_path:
        # 自动下载
        tmp_file = tempfile.NamedTemporaryFile(
            suffix=".dat", prefix="geosite_", delete=False
        )
        tmp_file.close()
        geosite_path = tmp_file.name
        download_geosite(GEOSITE_URL, geosite_path)
    elif not os.path.isfile(geosite_path):
        red(f"错误: 文件不存在: {geosite_path}\n")
        sys.exit(1)

    try:
        # 读取 geosite.dat
        print(f"正在读取 {geosite_path} ...", end=" ")
        with open(geosite_path, "rb") as f:
            raw_data = f.read()
        file_size_mb = len(raw_data) / (1024 * 1024)
        green(f"完成 ({file_size_mb:.1f} MB)\n")

        # 列出分类模式
        if args.list_categories:
            print("\n可用分类列表:")
            print("=" * 60)
            categories = list_categories(raw_data)
            for i, cat in enumerate(categories, 1):
                print(f"  {i:4d}. {cat}")
            print("=" * 60)
            print(f"共 {len(categories)} 个分类")
            return

        # 查找指定分类
        category = args.category.upper()
        print(f"正在查找分类 '{args.category}' ...", end=" ")

        target_geosite = None
        for entry_data in parse_geosite_list(raw_data):
            code = extract_country_code_fast(entry_data)
            if code.upper() == category:
                target_geosite = parse_geosite(entry_data)
                break

        if target_geosite is None:
            red(f"\n错误: 未找到分类 '{args.category}'\n")
            red("使用 --list-categories 查看所有可用分类。\n")
            sys.exit(1)

        green(f"找到！共 {len(target_geosite['domains'])} 条规则\n")

        # 提取域名
        domains = []
        stats = {t: 0 for t in DOMAIN_TYPE_NAMES}
        skipped = {t: 0 for t in DOMAIN_TYPE_NAMES}

        for d in target_geosite["domains"]:
            dtype = d["type"]
            value = d["value"]
            stats[dtype] = stats.get(dtype, 0) + 1

            if dtype == DOMAIN_TYPE_ROOT_DOMAIN:
                # root domain: 匹配该域名及其所有子域名
                domains.append(value)
            elif dtype == DOMAIN_TYPE_FULL:
                # full: 精确匹配该域名
                domains.append(value)
            elif dtype == DOMAIN_TYPE_REGEX and args.include_regex:
                # regex: 正则表达式（通常跳过，dnsmasq 不支持）
                domains.append(value)
            elif dtype == DOMAIN_TYPE_PLAIN and args.include_plain:
                # plain: 关键字匹配（通常跳过）
                domains.append(value)
            else:
                skipped[dtype] = skipped.get(dtype, 0) + 1

        # 打印统计信息
        print(f"\n域名规则统计:")
        for dtype, name in DOMAIN_TYPE_NAMES.items():
            total = stats.get(dtype, 0)
            skip = skipped.get(dtype, 0)
            if total > 0:
                status = f"已提取 {total - skip}" + (f"，跳过 {skip}" if skip > 0 else "")
                print(f"  {name:12s}: {total:5d} 条  ({status})")

        if not domains:
            red("\n错误: 没有提取到任何域名。\n")
            sys.exit(1)

        # 生成输出
        print(f"\n正在生成输出文件 {args.output} ...", end=" ")

        if args.domain_list:
            count = generate_domain_list(domains, args.output)
            green(f"完成\n")
            print(f"已生成域名列表，共 {count} 个唯一域名。\n")
        else:
            count = generate_dnsmasq_nftset_conf(
                domains,
                args.dns,
                args.port,
                args.nftset,
                args.output,
            )
            green(f"完成\n")
            mode = "server + nftset" if args.nftset else "server"
            print(f"已生成 dnsmasq {mode} 配置，共 {count} 个唯一域名。\n")

        green("任务完成。\n")

    finally:
        # 清理临时文件
        if tmp_file and os.path.exists(tmp_file.name):
            os.unlink(tmp_file.name)


if __name__ == "__main__":
    main()
