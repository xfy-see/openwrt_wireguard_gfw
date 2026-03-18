#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
geoip2nftset.py - 从 geoip.dat 提取国家 IP 段生成 nftables set 定义

从 V2Ray/Xray 的 geoip.dat (protobuf 格式) 中读取指定国家的 CIDR 列表，
生成 nftables set 定义文件，可用 `nft -f` 直接加载，用于配合策略路由实现 CN 直连。

无需外部依赖，纯 Python 3 标准库实现 protobuf 解码。

用法:
    python3 geoip2nftset.py -c CN -o cn_direct.nft
    python3 geoip2nftset.py -g /path/to/geoip.dat -c CN -l -o cn_cidrs.txt
    python3 geoip2nftset.py --list-countries
"""

import argparse
import io
import os
import socket
import struct
import sys
import tempfile
import urllib.request
from datetime import datetime

# ============================================================================
# Protobuf 手动解码器（无需外部依赖）
# ============================================================================
# geoip.dat 使用 proto3 格式，结构如下:
#
# message CIDR {
#   bytes  ip     = 1;   // length-delimited: 4 字节 IPv4 或 16 字节 IPv6
#   uint32 prefix = 2;   // varint: 前缀长度
# }
#
# message GeoIP {
#   string country_code  = 1;  // length-delimited
#   repeated CIDR cidr   = 2;  // length-delimited
#   bool reverse_match   = 3;  // varint (忽略)
# }
#
# message GeoIPList {
#   repeated GeoIP entry = 1;  // length-delimited
# }

# Protobuf wire types
WIRE_VARINT = 0
WIRE_64BIT = 1
WIRE_LENGTH_DELIMITED = 2
WIRE_32BIT = 5

GEOIP_URL = "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"


# ============================================================================
# Protobuf 基础解析函数（与 geosite2nftset.py 一致）
# ============================================================================

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


# ============================================================================
# 彩色输出辅助函数
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


# ============================================================================
# geoip.dat 解析函数
# ============================================================================

def ip_bytes_to_str(ip_bytes: bytes) -> str:
    """将原始 IP 字节转换为点分十进制或冒号分隔的字符串。"""
    if len(ip_bytes) == 4:
        return socket.inet_ntop(socket.AF_INET, ip_bytes)
    elif len(ip_bytes) == 16:
        return socket.inet_ntop(socket.AF_INET6, ip_bytes)
    else:
        raise ValueError(f"Invalid IP bytes length: {len(ip_bytes)}")


def parse_cidr(data: bytes) -> dict:
    """解析 CIDR 消息，返回 {'ip': bytes, 'prefix': int}。"""
    stream = io.BytesIO(data)
    cidr = {"ip": b"", "prefix": 0}

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            # ip 字段（4 字节 IPv4 或 16 字节 IPv6）
            length = read_varint(stream)
            cidr["ip"] = stream.read(length)
        elif field_number == 2 and wire_type == WIRE_VARINT:
            # prefix 字段
            cidr["prefix"] = read_varint(stream)
        else:
            skip_field(stream, wire_type)

    return cidr


def parse_geoip(data: bytes) -> dict:
    """解析 GeoIP 消息，返回 {'country_code': str, 'cidrs': [str]}。"""
    stream = io.BytesIO(data)
    geoip = {"country_code": "", "cidrs": []}

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            # country_code 字段
            length = read_varint(stream)
            geoip["country_code"] = stream.read(length).decode("utf-8")
        elif field_number == 2 and wire_type == WIRE_LENGTH_DELIMITED:
            # cidr 字段（repeated）
            length = read_varint(stream)
            cidr_data = stream.read(length)
            cidr = parse_cidr(cidr_data)
            if cidr["ip"]:
                try:
                    ip_str = ip_bytes_to_str(cidr["ip"])
                    geoip["cidrs"].append(f"{ip_str}/{cidr['prefix']}")
                except ValueError:
                    pass  # 跳过无效的 IP 字节
        else:
            skip_field(stream, wire_type)

    return geoip


def parse_geoip_list(data: bytes):
    """解析 GeoIPList，生成器逐个 yield GeoIP entry 的原始字节。"""
    stream = io.BytesIO(data)

    while True:
        tag = read_tag(stream)
        if tag is None:
            break
        field_number, wire_type = tag

        if field_number == 1 and wire_type == WIRE_LENGTH_DELIMITED:
            # entry 字段（repeated GeoIP）
            length = read_varint(stream)
            entry_data = stream.read(length)
            yield entry_data
        else:
            skip_field(stream, wire_type)


def extract_country_code_fast(data: bytes) -> str:
    """快速提取 GeoIP 的 country_code 而不完整解析所有 CIDR。"""
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
# 下载函数
# ============================================================================

def download_geoip(url: str, dest: str):
    """下载 geoip.dat 文件。"""
    print(f"正在从 {url} 下载 geoip.dat ...")
    try:
        urllib.request.urlretrieve(url, dest)
        green("下载完成。\n")
    except Exception as e:
        red(f"\n下载失败: {e}\n")
        red("请检查网络连接，或使用 -g 参数指定本地 geoip.dat 文件。\n")
        sys.exit(2)


# ============================================================================
# 输出函数
# ============================================================================

def generate_nft_set_file(
    cidrs_v4: list,
    cidrs_v6: list,
    set_v4: str,
    set_v6: str,
    output_file: str,
    nft_table: str = "inet fw4",
    ipv4_only: bool = False,
    ipv6_only: bool = False,
):
    """生成 nftables set 定义文件（可用 `nft -f` 直接加载）。"""
    # 解析 table family 和 name（格式: "inet fw4" 或 "ip filter"）
    table_parts = nft_table.split()
    if len(table_parts) == 2:
        table_family, table_name = table_parts
    else:
        table_family, table_name = "inet", nft_table

    lines = []
    lines.append(f"# Generated by geoip2nftset.py — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"# IPv4 CIDRs: {len(cidrs_v4)}  IPv6 CIDRs: {len(cidrs_v6)}")
    lines.append("")
    lines.append(f"table {table_family} {table_name} {{")

    if not ipv6_only and cidrs_v4:
        lines.append(f"    set {set_v4} {{")
        lines.append("        type ipv4_addr")
        lines.append("        flags interval")
        lines.append("        elements = {")
        sorted_v4 = sorted(cidrs_v4)
        for i, cidr in enumerate(sorted_v4):
            comma = "," if i < len(sorted_v4) - 1 else ""
            lines.append(f"            {cidr}{comma}")
        lines.append("        }")
        lines.append("    }")

    if not ipv4_only and not ipv6_only and cidrs_v4 and cidrs_v6:
        lines.append("")

    if not ipv4_only and cidrs_v6:
        lines.append(f"    set {set_v6} {{")
        lines.append("        type ipv6_addr")
        lines.append("        flags interval")
        lines.append("        elements = {")
        sorted_v6 = sorted(cidrs_v6)
        for i, cidr in enumerate(sorted_v6):
            comma = "," if i < len(sorted_v6) - 1 else ""
            lines.append(f"            {cidr}{comma}")
        lines.append("        }")
        lines.append("    }")

    lines.append("}")

    with open(output_file, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


def generate_cidr_list(
    cidrs_v4: list,
    cidrs_v6: list,
    output_file: str,
    ipv4_only: bool = False,
    ipv6_only: bool = False,
):
    """生成纯 CIDR 列表文件（每行一条）。"""
    cidrs = []
    if not ipv6_only:
        cidrs.extend(sorted(cidrs_v4))
    if not ipv4_only:
        cidrs.extend(sorted(cidrs_v6))

    with open(output_file, "w", encoding="utf-8", newline="\n") as f:
        for cidr in cidrs:
            f.write(cidr + "\n")

    return len(cidrs)


# ============================================================================
# 主逻辑
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="从 geoip.dat 提取国家 IP 段生成 nftables set 定义文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  # 生成 CN IP 的 nftables set 定义文件（自动下载 geoip.dat）
  %(prog)s -c CN -o cn_direct.nft

  # 使用本地 geoip.dat，仅输出 IPv4
  %(prog)s -g /path/to/geoip.dat -c CN -4 -o cn_v4.nft

  # 输出纯 CIDR 列表（方便查看或后处理）
  %(prog)s -c CN -l -o cn_cidrs.txt

  # 列出 geoip.dat 中所有可用国家代码
  %(prog)s -g /path/to/geoip.dat --list-countries

  # 在 OpenWrt 上加载生成的 nft 文件
  nft -f cn_direct.nft
        """,
    )
    parser.add_argument(
        "-g", "--geoip",
        help="geoip.dat 文件路径（默认自动下载最新版本）",
    )
    parser.add_argument(
        "-c", "--country",
        default="CN",
        help="国家代码（默认: CN）",
    )
    parser.add_argument(
        "-o", "--output",
        help="输出文件路径（必填，除非使用 --list-countries）",
    )
    parser.add_argument(
        "--nft-table",
        default="inet fw4",
        help="nftables 表，格式: 'family name'（默认: inet fw4）",
    )
    parser.add_argument(
        "--nft-set-v4",
        default="cn_list_v4",
        help="IPv4 nftables set 名称（默认: cn_list_v4）",
    )
    parser.add_argument(
        "--nft-set-v6",
        default="cn_list_v6",
        help="IPv6 nftables set 名称（默认: cn_list_v6）",
    )
    parser.add_argument(
        "-4", "--ipv4-only",
        action="store_true",
        help="只输出 IPv4 CIDR",
    )
    parser.add_argument(
        "-6", "--ipv6-only",
        action="store_true",
        help="只输出 IPv6 CIDR",
    )
    parser.add_argument(
        "-l", "--cidr-list",
        action="store_true",
        help="输出纯 CIDR 列表而非 nftables set 定义",
    )
    parser.add_argument(
        "--list-countries",
        action="store_true",
        help="列出 geoip.dat 中所有可用国家代码并退出",
    )

    args = parser.parse_args()

    # 参数验证
    if args.ipv4_only and args.ipv6_only:
        red("错误: -4 和 -6 不能同时使用。\n")
        sys.exit(1)

    if not args.list_countries and not args.output:
        red("错误: 请使用 -o/--output 指定输出文件路径。\n")
        parser.print_help()
        sys.exit(1)

    # 获取 geoip.dat
    geoip_path = args.geoip
    tmp_file = None

    if not geoip_path:
        tmp_file = tempfile.NamedTemporaryFile(
            suffix=".dat", prefix="geoip_", delete=False
        )
        tmp_file.close()
        geoip_path = tmp_file.name
        download_geoip(GEOIP_URL, geoip_path)
    elif not os.path.isfile(geoip_path):
        red(f"错误: 文件不存在: {geoip_path}\n")
        sys.exit(1)

    try:
        # 读取 geoip.dat
        print(f"正在读取 {geoip_path} ...", end=" ")
        with open(geoip_path, "rb") as f:
            raw_data = f.read()
        file_size_kb = len(raw_data) / 1024
        green(f"完成 ({file_size_kb:.0f} KB)\n")

        # 列出国家代码模式
        if args.list_countries:
            print("\n可用国家代码列表:")
            print("=" * 60)
            countries = []
            for entry_data in parse_geoip_list(raw_data):
                code = extract_country_code_fast(entry_data)
                if code:
                    countries.append(code)
            countries.sort()
            for i, code in enumerate(countries, 1):
                print(f"  {i:4d}. {code}")
            print("=" * 60)
            print(f"共 {len(countries)} 个国家/地区")
            return

        # 查找指定国家
        country = args.country.upper()
        print(f"正在查找国家代码 '{country}' ...", end=" ")

        target_geoip = None
        for entry_data in parse_geoip_list(raw_data):
            code = extract_country_code_fast(entry_data)
            if code.upper() == country:
                target_geoip = parse_geoip(entry_data)
                break

        if target_geoip is None:
            red(f"\n错误: 未找到国家代码 '{args.country}'\n")
            red("使用 --list-countries 查看所有可用国家代码。\n")
            sys.exit(1)

        all_cidrs = target_geoip["cidrs"]
        green(f"找到！共 {len(all_cidrs)} 条 CIDR\n")

        # 按版本分类
        cidrs_v4 = [c for c in all_cidrs if ":" not in c]
        cidrs_v6 = [c for c in all_cidrs if ":" in c]

        print(f"\nCIDR 统计:")
        print(f"  IPv4: {len(cidrs_v4)} 条")
        print(f"  IPv6: {len(cidrs_v6)} 条")

        if not cidrs_v4 and not cidrs_v6:
            red("\n错误: 没有提取到任何 CIDR。\n")
            sys.exit(1)

        if args.ipv4_only and not cidrs_v4:
            red("\n错误: 没有 IPv4 CIDR 可输出。\n")
            sys.exit(1)

        if args.ipv6_only and not cidrs_v6:
            red("\n错误: 没有 IPv6 CIDR 可输出。\n")
            sys.exit(1)

        # 生成输出
        print(f"\n正在生成输出文件 {args.output} ...", end=" ")

        if args.cidr_list:
            count = generate_cidr_list(
                cidrs_v4, cidrs_v6, args.output,
                ipv4_only=args.ipv4_only,
                ipv6_only=args.ipv6_only,
            )
            green("完成\n")
            print(f"已生成纯 CIDR 列表，共 {count} 条。\n")
        else:
            generate_nft_set_file(
                cidrs_v4, cidrs_v6,
                args.nft_set_v4, args.nft_set_v6,
                args.output,
                nft_table=args.nft_table,
                ipv4_only=args.ipv4_only,
                ipv6_only=args.ipv6_only,
            )
            green("完成\n")
            v4_count = 0 if args.ipv6_only else len(cidrs_v4)
            v6_count = 0 if args.ipv4_only else len(cidrs_v6)
            sets_desc = []
            if v4_count:
                sets_desc.append(f"{args.nft_set_v4} ({v4_count} 条 IPv4)")
            if v6_count:
                sets_desc.append(f"{args.nft_set_v6} ({v6_count} 条 IPv6)")
            print(f"已生成 nftables set 定义: {', '.join(sets_desc)}\n")
            print(f"加载方法: nft -f {args.output}\n")

        green("任务完成。\n")

    finally:
        # 清理临时文件
        if tmp_file and os.path.exists(tmp_file.name):
            os.unlink(tmp_file.name)


if __name__ == "__main__":
    main()
