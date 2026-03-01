#!/bin/sh

# ================= 配置区域 =================
# nftables 表名和 set 名 (须与 wg_route 脚本一致)
NFT_TABLE="fw4"
NFT_SET_V4="gfw_list_v4"
NFT_SET_V6="gfw_list_v6"
# ============================================

# Telegram 官方 IPv4 地址段 (AS62041 / AS62014)
TELEGRAM_IPV4="
    91.108.4.0/22,
    91.108.8.0/22,
    91.108.12.0/22,
    91.108.16.0/22,
    91.108.20.0/22,
    91.108.56.0/22,
    149.154.160.0/20
"

# Telegram 官方 IPv6 地址段
TELEGRAM_IPV6="
    2001:b28:f23d::/48,
    2001:b28:f23f::/48,
    2001:67c:4e8::/48
"

echo "[*] 正在将 Telegram IP 段添加到 nftables set..."

# 检查 nft 表是否存在
if ! nft list table inet "$NFT_TABLE" > /dev/null 2>&1; then
    echo "[!] 错误: nftables 表 inet $NFT_TABLE 不存在。"
    echo "    请先确保 wg_route 服务已启动。"
    exit 1
fi

# 添加 IPv4 地址段
echo "[*] 添加 IPv4 地址段到 $NFT_SET_V4 ..."
nft add element inet "$NFT_TABLE" "$NFT_SET_V4" { $TELEGRAM_IPV4 }
if [ $? -eq 0 ]; then
    echo "  ✅ IPv4 地址段添加成功"
else
    echo "  ❌ IPv4 地址段添加失败"
    exit 1
fi

# 添加 IPv6 地址段
echo "[*] 添加 IPv6 地址段到 $NFT_SET_V6 ..."
nft add element inet "$NFT_TABLE" "$NFT_SET_V6" { $TELEGRAM_IPV6 }
if [ $? -eq 0 ]; then
    echo "  ✅ IPv6 地址段添加成功"
else
    echo "  ❌ IPv6 地址段添加失败"
    exit 1
fi

echo ""
echo "[√] Telegram IP 段已全部添加到 nftables！"
echo ""
echo "已添加的 IPv4 段:"
echo "  91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22"
echo "  91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22"
echo "  149.154.160.0/20"
echo ""
echo "已添加的 IPv6 段:"
echo "  2001:b28:f23d::/48, 2001:b28:f23f::/48, 2001:67c:4e8::/48"
echo ""
echo "验证命令: nft list set inet $NFT_TABLE $NFT_SET_V4"
