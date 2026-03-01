#!/bin/sh

# ================= 配置区域 =================
# 存放 dnsmasq 自定义配置的目录
#CONF_DIR="/etc/dnsmasq.d"
CONF_DIR="./"
# 生成的配置文件名
PROXY_CONF="$CONF_DIR/gfw-proxy.conf"

# 处理 DNS 污染的监听地址和端口
DNS_SERVER="8.8.8.8"

# nftables 配置信息 (务必与你的 nftables 脚本中的表名和集合名一致)
NFT_FAMILY_TABLE="inet#fw4"
NFT_SET_V4="gfw_list_v4"
NFT_SET_V6="gfw_list_v6"

# 规则源 URL (这里使用 Loyalsoldier 整理的纯域名 gfwlist 列表)
# 主URL和备用CDN地址
RULE_URLS=(
    "https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
    "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/gfw.txt"
)
TMP_FILE="/tmp/gfw_raw.txt"

# 下载绑定的网络接口 (可通过环境变量 BIND_IFACE 传入，如 wg_aws)
# 设置后 wget 会通过该接口的 IP 下载，用于翻墙下载 gfwlist
BIND_IFACE="${BIND_IFACE:-}"
# ============================================

echo "[*] 开始下载最新的代理域名列表..."

# 如果指定了绑定接口，获取其 IP 地址用于 wget --bind-address
WGET_BIND=""
if [ -n "$BIND_IFACE" ]; then
    # 优先取 IPv4，没有则取 IPv6 全局地址 (排除 fe80 link-local)
    BIND_IP=$(ip -4 addr show dev "$BIND_IFACE" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    if [ -z "$BIND_IP" ]; then
        BIND_IP=$(ip -6 addr show dev "$BIND_IFACE" scope global 2>/dev/null | grep -oE 'inet6 [0-9a-f:]+' | awk '{print $2}')
    fi
    if [ -n "$BIND_IP" ]; then
        WGET_BIND="--bind-address=$BIND_IP"
        echo "[*] 使用接口 $BIND_IFACE ($BIND_IP) 下载"
    else
        echo "[!] 接口 $BIND_IFACE 无可用 IP 地址，使用默认路由下载"
    fi
fi

# 尝试从多个URL下载，直到成功
for url in "${RULE_URLS[@]}"; do
    echo "[*] 尝试从 $url 下载..."
    wget $WGET_BIND -q -O "$TMP_FILE" "$url"
    
    if [ -s "$TMP_FILE" ]; then
        echo "[√] 从 $url 下载成功！"
        break
    fi
    echo "[!] 从 $url 下载失败，尝试下一个地址..."
done

if [ ! -s "$TMP_FILE" ]; then
    echo "[!] 所有地址都下载失败，请检查网络连通性 (可能需要临时开启全局代理)。"
    exit 1
fi

# 追加 gfw.txt 中缺失的域名 (例如 .google 结尾的域名)
EXTRA_DOMAINS="google antigravity.google"
for d in $EXTRA_DOMAINS; do
    if ! grep -qx "$d" "$TMP_FILE"; then
        echo "$d" >> "$TMP_FILE"
    fi
done

echo "[*] 下载成功，正在处理并生成 dnsmasq 规则 (这可能需要几秒钟)..."

# 使用 awk 进行高性能文本处理
awk -v dns="$DNS_SERVER" -v tbl="$NFT_FAMILY_TABLE" -v set4="$NFT_SET_V4" -v set6="$NFT_SET_V6" '
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
    
    # 2. 生成 IPv4 的 nftset 规则
    printf("nftset=/%s/4#%s#%s\n", domain, tbl, set4);
    
    # 3. 生成 IPv6 的 nftset 规则
    printf("nftset=/%s/6#%s#%s\n", domain, tbl, set6);
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