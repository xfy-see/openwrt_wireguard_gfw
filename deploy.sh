#!/bin/bash
# deploy.sh — 将 wg_route 及 update-proxy-domains.sh 部署到 OpenWrt 路由器
#
# 用法:
#   ./deploy.sh [用户@路由器IP]
#
# 示例:
#   ./deploy.sh root@192.168.100.1
#   ./deploy.sh root@192.168.100.130
#   ./deploy.sh                         # 默认部署到 192.168.1.1
#
# 功能:
#   1. 部署 wg_route (init.d 服务) 和 update-proxy-domains.sh
#   2. 根据路由器 IP 自动选择正确的 WireGuard 接口名
#   3. 设置 cron 每日凌晨 3 点更新域名列表
#   4. enable 并启动服务
#
# 路由器无需 sftp/scp，文件通过 ssh stdin 传输

set -e

# ================= 配置区 =================
ROUTER="${1:-root@192.168.1.1}"

# 路由器 IP → WireGuard 接口名映射
# 192.168.1.1 使用 wg0，其余使用 wg_aws
_wg_iface_for() {
    case "$1" in
        *192.168.1.1) echo "wg0" ;;
        *)            echo "wg_aws" ;;
    esac
}

WG_IFACE=$(_wg_iface_for "$ROUTER")

# 本地脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ==========================================

# 颜色输出
_green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
_red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
_step()   { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }

# 通过 ssh stdin 传输文件并转换 CRLF → LF
_ssh_put_lf() {
    ssh "$ROUTER" "tr -d '\r' > '$2'" < "$1"
}

# ---------- 开始 ----------
echo ""
echo "======================================"
echo "  wg_route 部署脚本"
echo "  目标路由器: $ROUTER"
echo "  WG 接口名: $WG_IFACE"
echo "======================================"

# ---------- Step 1: 检查连接 ----------
_step "1/4" "检查 SSH 连接"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER" true 2>/dev/null; then
    _red "错误: 无法连接到 $ROUTER（请检查 SSH 密钥或路由器地址）"
    exit 1
fi
_green "  SSH 连接: OK"

# ---------- Step 2: 创建目录 ----------
_step "2/4" "创建路由器目标目录"

ssh "$ROUTER" "mkdir -p /etc/gfwlist /etc/nftables.d /etc/dnsmasq.d"
_green "  /etc/gfwlist  OK"

# ---------- Step 3: 部署文件 ----------
_step "3/4" "部署脚本"

# 部署 update-proxy-domains.sh
_ssh_put_lf "$SCRIPT_DIR/update-proxy-domains.sh" "/etc/gfwlist/update-proxy-domains.sh"
ssh "$ROUTER" "chmod +x /etc/gfwlist/update-proxy-domains.sh"
_green "  update-proxy-domains.sh → /etc/gfwlist/"

# 部署 wg_route（替换接口名）
tr -d '\r' < "$SCRIPT_DIR/wg_route" \
    | sed "s/WG_IFACE=\"[^\"]*\"/WG_IFACE=\"$WG_IFACE\"/" \
    | ssh "$ROUTER" "cat > /etc/init.d/wg_route && chmod +x /etc/init.d/wg_route"
_green "  wg_route → /etc/init.d/wg_route (WG_IFACE=$WG_IFACE)"

# enable 服务
ssh "$ROUTER" "/etc/init.d/wg_route enable 2>/dev/null"
_green "  enable 完成"

# ---------- Step 4: 设置 cron ----------
_step "4/4" "设置定时更新 (每日 03:00)"

ssh "$ROUTER" "
    crontab -l 2>/dev/null | grep -v update-proxy-domains | {
        cat
        echo \"0 3 * * * BIND_IFACE=$WG_IFACE /etc/gfwlist/update-proxy-domains.sh >> /tmp/gfw-update.log 2>&1\"
    } | crontab -
"
_green "  cron 已配置"

# ---------- 完成 ----------
echo ""
_green "======================================"
_green "  部署完成！"
_green "======================================"
echo ""
echo "后续操作："
echo "  立即启动:  ssh $ROUTER '/etc/init.d/wg_route start'"
echo "  查看规则:  ssh $ROUTER 'nft list chain inet fw4 prerouting_wg'"
echo "  停止服务:  ssh $ROUTER '/etc/init.d/wg_route stop'"
echo "  查看日志:  ssh $ROUTER 'cat /tmp/gfw-update.log'"
echo ""
