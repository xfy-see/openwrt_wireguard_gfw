#!/bin/sh

# ================= 配置区域 (请与 update-proxy-domains.sh 保持一致) =================
NFT_SET_V4="gfw_list_v4"
NFT_SET_V6="gfw_list_v6"
TEST_DOMAIN="google.com"
# ==============================================================================

echo "[*] 开始对 $TEST_DOMAIN 进行 dnsmasq -> nftset 联动验证..."

# 1. 检查 dnsmasq 功能是否支持 nftset
if ! dnsmasq --version | grep -q "nftset"; then
    echo "[!] 错误: 当前 dnsmasq 不支持 nftset 选项，请安装 dnsmasq-full。"
    exit 1
fi

# 2. 检查 nftables 集合是否存在
if ! nft list set inet fw4 "$NFT_SET_V4" >/dev/null 2>&1; then
    echo "[!] 错误: nftables 集合 $NFT_SET_V4 不存在。"
    exit 1
fi

# 3. 记录当前的集合大小/条数
count_before_v4=$(nft list set inet fw4 "$NFT_SET_V4" | grep -c "\.")
count_before_v6=$(nft list set inet fw4 "$NFT_SET_V6" | grep -c ":")

echo "[*] 当前 $NFT_SET_V4 中约有 $count_before_v4 条记录"
echo "[*] 当前 $NFT_SET_V6 中约有 $count_before_v6 条记录"

# 4. 执行 DNS 查询触发联动
echo "[*] 正在执行 nslookup -query=A $TEST_DOMAIN (触发 IPv4 联动)..."
nslookup -query=A "$TEST_DOMAIN" 127.0.0.1 > /dev/null 2>&1

echo "[*] 正在执行 nslookup -query=AAAA $TEST_DOMAIN (触发 IPv6 联动)..."
nslookup -query=AAAA "$TEST_DOMAIN" ::1 > /dev/null 2>&1

# 稍微等待 dnsmasq 异步写入 nftset
sleep 1

# 5. 再次检查记录条数并对比
count_after_v4=$(nft list set inet fw4 "$NFT_SET_V4" | grep -c "\.")
count_after_v6=$(nft list set inet fw4 "$NFT_SET_V6" | grep -c ":")

echo "[*] 验证结果:"

if [ "$count_after_v4" -gt "$count_before_v4" ]; then
    echo "[√] IPv4 验证成功: $NFT_SET_V4 记录条数增加 ($count_before_v4 -> $count_after_v4)"
else
    echo "[?] IPv4 提醒: $NFT_SET_V4 记录条数未增加（可能是 IP 已在集合中，或查询未返回新 V4 地址）"
fi

if [ "$count_after_v6" -gt "$count_before_v6" ]; then
    echo "[√] IPv6 验证成功: $NFT_SET_V6 记录条数增加 ($count_before_v6 -> $count_after_v6)"
else
    echo "[?] IPv6 提醒: $NFT_SET_V6 记录条数未增加（可能是查询未返回 V6 地址，或者 IPv6 不通）"
fi

# 6. 展示匹配到的最新 IP (可选)
echo "[*] 最近加入集合的 IP 示例:"
nft list set inet fw4 "$NFT_SET_V4" | tail -n 5
