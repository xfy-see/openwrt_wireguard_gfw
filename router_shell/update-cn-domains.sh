#!/bin/sh

# ================= 配置区域 =================
# 存放 dnsmasq 自定义配置的目录
CONF_DIR="/etc/dnsmasq.d"
# 生成的配置文件名
CN_CONF="$CONF_DIR/cn-direct.conf"

# CN 域名使用国内 DNS 解析（避免污染，直接用 CN DNS）
DNS_SERVER="114.114.114.114"
DNS_SERVER_V6=""

# nftables 配置信息（务必与 cn_direct.nft 中的 set 名称一致）
NFT_FAMILY_TABLE="inet#fw4"
NFT_SET_V4="cn_list_v4"
NFT_SET_V6="cn_list_v6"

# geosite2nftset.py 脚本路径
GEOSITE_SCRIPT="/etc/gfwlist/geosite2nftset.py"
# 临时文件：CN 域名列表
TMP_DOMAINS="/tmp/cn_domains.txt"

# geoip2nftset.py 脚本路径（用于生成 CN IP nft 文件）
GEOIP_SCRIPT="/etc/gfwlist/geoip2nftset.py"
# CN IP nft 文件输出路径（加载到 nftables 中）
CN_NFT_FILE="/etc/nftables.d/cn_direct.nft"
# ============================================

echo "[*] 开始生成 CN 直连规则..."

# ---- 第一步：生成 CN IP nftables set 定义文件 ----
echo "[*] 从 geoip.dat 提取 CN IP 段..."
if [ -x "$GEOIP_SCRIPT" ] || python3 "$GEOIP_SCRIPT" --help > /dev/null 2>&1; then
    python3 "$GEOIP_SCRIPT" -c CN -o "$CN_NFT_FILE"
    if [ $? -eq 0 ] && [ -s "$CN_NFT_FILE" ]; then
        echo "[√] CN IP nft 文件已生成: $CN_NFT_FILE ($(wc -l < "$CN_NFT_FILE") 行)"
        # 加载到 nftables（如果 nft 命令可用）
        if command -v nft > /dev/null 2>&1; then
            nft -f "$CN_NFT_FILE" && echo "[√] CN IP nftables set 已加载" || echo "[!] nftables 加载失败，请手动执行: nft -f $CN_NFT_FILE"
        else
            echo "[!] nft 命令不可用，请手动执行: nft -f $CN_NFT_FILE"
        fi
    else
        echo "[!] CN IP 文件生成失败，跳过 IP 阶段"
    fi
else
    echo "[!] geoip2nftset.py 不可用 ($GEOIP_SCRIPT)，跳过 CN IP 阶段"
fi

# ---- 第二步：生成 CN 域名 dnsmasq nftset 规则 ----
echo "[*] 从 geosite.dat 提取 CN 域名列表..."
if [ -x "$GEOSITE_SCRIPT" ] || python3 "$GEOSITE_SCRIPT" --help > /dev/null 2>&1; then
    python3 "$GEOSITE_SCRIPT" -c cn -l -o "$TMP_DOMAINS"
    if [ $? -ne 0 ] || [ ! -s "$TMP_DOMAINS" ]; then
        echo "[!] CN 域名提取失败，请检查 $GEOSITE_SCRIPT"
        exit 1
    fi
    echo "[√] 已提取 CN 域名 $(wc -l < "$TMP_DOMAINS") 条"
else
    echo "[!] geosite2nftset.py 不可用 ($GEOSITE_SCRIPT)"
    exit 1
fi

echo "[*] 正在生成 dnsmasq CN 直连规则 (这可能需要几秒钟)..."

# 确保配置目录存在
mkdir -p "$CONF_DIR" || { echo "[!] 无法创建配置目录 $CONF_DIR"; exit 1; }

# 使用 awk 生成 dnsmasq 规则（server= 使用 CN DNS，nftset= 指向 cn_list）
awk -v dns="$DNS_SERVER" -v dnsv6="$DNS_SERVER_V6" \
    -v tbl="$NFT_FAMILY_TABLE" \
    -v set4="$NFT_SET_V4" -v set6="$NFT_SET_V6" '
BEGIN {
    print "# 此文件由脚本自动生成，请勿手动修改！"
    print "# CN 域名直连规则：使用国内 DNS 解析，将解析结果写入 cn_list nftset"
}
{
    # 跳过空行和注释行
    if ($1 == "" || $1 ~ /^#/) next;

    # 清理可能存在的 Windows 换行符 (\r)
    gsub(/\r/, "", $1);

    domain = $1;

    # 1. 生成 DNS 转发规则（使用国内 DNS，直接解析不经过防污染代理）
    printf("server=/%s/%s\n", domain, dns);
    if (dnsv6 != "") {
        printf("server=/%s/%s\n", domain, dnsv6);
    }

    # 2. 生成 nftset 规则（将解析结果写入 cn_list，触发直连路由）
    printf("nftset=/%s/4#%s#%s,6#%s#%s\n", domain, tbl, set4, tbl, set6);
}' "$TMP_DOMAINS" > "$CN_CONF"

rm -f "$TMP_DOMAINS"

CN_DOMAIN_COUNT=$(grep -c "^server=" "$CN_CONF" 2>/dev/null || echo 0)
echo "[√] 规则生成完毕：$CN_CONF ($CN_DOMAIN_COUNT 条域名)"

echo "[*] 检查 dnsmasq 语法..."
dnsmasq --test > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "[*] 语法正确，正在重启 dnsmasq 服务..."
    /etc/init.d/dnsmasq restart
    echo "[√] CN 直连规则更新完成！"
    echo ""
    echo "当前生效规则："
    echo "  CN IP 直连: $CN_NFT_FILE (nftables set $NFT_SET_V4 / $NFT_SET_V6)"
    echo "  CN 域名直连: $CN_CONF (dnsmasq nftset → $NFT_SET_V4 / $NFT_SET_V6)"
else
    echo "[!] 生成的规则存在语法错误，请检查！已回滚。"
    rm -f "$CN_CONF"
    exit 1
fi
