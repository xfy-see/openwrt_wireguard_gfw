#!/bin/sh

# ================= 配置区域 =================
# 存放 dnsmasq 自定义配置的目录
CONF_DIR="/etc/dnsmasq.d"
#CONF_DIR="./"
# 生成的配置文件名
PROXY_CONF="$CONF_DIR/gfw-proxy.conf"

# 处理 DNS 污染的监听地址和端口
DNS_SERVER="8.8.8.8"
DNS_SERVER_V6="2001:4860:4860::8888"

# nftables 配置信息 (务必与你的 nftables 脚本中的表名和集合名一致)
NFT_FAMILY_TABLE="inet#fw4"
NFT_SET_V4="gfw_list_v4"
NFT_SET_V6="gfw_list_v6"

# 规则源 URL (这里使用 Loyalsoldier 整理的纯域名 gfwlist 列表)
# 主URL和备用CDN地址
RULE_URLS="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt"
TMP_FILE="/tmp/gfw_raw.txt"

# 下载绑定的网络接口 (可通过环境变量 BIND_IFACE 传入，如 wg0)
# 设置后通过临时 ip rule 让下载流量走该接口，用于翻墙下载 gfwlist
BIND_IFACE="${BIND_IFACE:-}"
# ============================================

echo "[*] 开始下载最新的代理域名列表..."

# 如果指定了绑定接口，临时添加高优先级默认路由走该接口
_BIND_RULE_ADDED=""
if [ -n "$BIND_IFACE" ]; then
    ip route add default dev "$BIND_IFACE" table 99 2>/dev/null
    ip rule add lookup 99 prio 1 2>/dev/null
    _BIND_RULE_ADDED=1
    echo "[*] 使用接口 $BIND_IFACE 下载 (临时默认路由)"
fi

# 尝试从多个URL下载，直到成功
for url in $RULE_URLS; do
    echo "[*] 尝试从 $url 下载..."
    uclient-fetch --no-check-certificate -q -O "$TMP_FILE" "$url"

    if [ -s "$TMP_FILE" ]; then
        echo "[√] 从 $url 下载成功！"
        break
    fi
    echo "[!] 从 $url 下载失败，尝试下一个地址..."
done

# 清理临时路由
if [ -n "$_BIND_RULE_ADDED" ]; then
    ip rule del lookup 99 prio 1 2>/dev/null
    ip route del default dev "$BIND_IFACE" table 99 2>/dev/null
fi

if [ ! -s "$TMP_FILE" ]; then
    echo "[!] 所有地址都下载失败，请检查网络连通性 (可能需要临时开启全局代理)。"
    exit 1
fi

# 从 domain-list-community 下载 AI 相关分类域名，追加到 gfw 列表
# 分类列表：openai, anthropic, google-deepmind (含 gemini), perplexity, xai, cursor, huggingface, github-copilot
AI_CATEGORIES="openai anthropic google-deepmind perplexity xai cursor huggingface github-copilot"
AI_BASE_URL="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
AI_TMP="/tmp/ai_domains_raw.txt"

echo "[*] 下载 AI 相关域名分类..."
ai_count=0
: > "$AI_TMP"
for cat in $AI_CATEGORIES; do
    if uclient-fetch --no-check-certificate -q -O - "$AI_BASE_URL/$cat" >> "$AI_TMP" 2>/dev/null; then
        echo "[√] 分类 $cat 下载成功"
    else
        echo "[!] 分类 $cat 下载失败，跳过"
    fi
done

# 从下载内容中提取纯域名（跳过注释、空行、full:前缀、regexp:、include:、@属性标记）
awk '{
    gsub(/\r/, "")
    # 跳过空行、注释、regexp、include 指令
    if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^#/ || $0 ~ /^regexp:/ || $0 ~ /^include:/) next
    # 去掉 full: 前缀
    sub(/^full:/, "")
    # 取第一个字段（去掉 @ads 等属性标记）
    domain = $1
    # 跳过含通配符或非域名的行
    if (domain ~ /[*{}|]/ || domain !~ /\./) next
    print domain
}' "$AI_TMP" | sort -u | while read -r d; do
    if ! grep -qx "$d" "$TMP_FILE"; then
        echo "$d" >> "$TMP_FILE"
        ai_count=$((ai_count + 1))
    fi
done
rm -f "$AI_TMP"

# 补充 gfw.txt 中缺失的顶级 google 域名（不在任何分类中）
for d in google antigravity.google; do
    if ! grep -qx "$d" "$TMP_FILE"; then
        echo "$d" >> "$TMP_FILE"
    fi
done

echo "[*] AI 域名追加完成"

echo "[*] 下载成功，正在处理并生成 dnsmasq 规则 (这可能需要几秒钟)..."

# 确保配置目录存在
mkdir -p "$CONF_DIR" || { echo "[!] 无法创建配置目录 $CONF_DIR"; exit 1; }

# 使用 awk 进行高性能文本处理
awk -v dns="$DNS_SERVER" -v dnsv6="$DNS_SERVER_V6" -v tbl="$NFT_FAMILY_TABLE" -v set4="$NFT_SET_V4" -v set6="$NFT_SET_V6" '
BEGIN {
    print "# 此文件由脚本自动生成，请勿手动修改！"
}
{
    # 跳过空行和注释行
    if ($1 == "" || $1 ~ /^#/) next;

    # 清理可能存在的 Windows 换行符 (\r)
    gsub(/\r/, "", $1);

    domain = $1;

    # 1. 生成 DNS 转发规则 (防污染)
    printf("server=/%s/%s\n", domain, dns);
    if (dnsv6 != "") {
        printf("server=/%s/%s\n", domain, dnsv6);
    }

    # 2 & 3. 生成 IPv4 和 IPv6 的 nftset 规则（合并为一行）
    printf("nftset=/%s/4#%s#%s,6#%s#%s\n", domain, tbl, set4, tbl, set6);
}' "$TMP_FILE" > "$PROXY_CONF"

rm -f "$TMP_FILE"

echo "[*] 规则生成完毕，检查 dnsmasq 语法..."
dnsmasq --test > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "[*] 语法正确，正在重启 dnsmasq 服务..."
    /etc/init.d/dnsmasq restart
    echo "[√] 更新完成！"
else
    echo "[!] 生成的规则存在语法错误，请检查！已回滚操作。"
    rm -f "$PROXY_CONF"
    exit 1
fi