#!/bin/bash
# deploy.sh — 将 wg_route_cn 及相关文件部署到 OpenWrt 路由器
#
# 用法:
#   ./deploy.sh [用户@路由器IP]
#
# 示例:
#   ./deploy.sh root@192.168.100.130
#   ./deploy.sh                         # 使用默认地址
#
# 依赖（本机）: python3, ssh
# 路由器无需 sftp/scp，文件通过 ssh stdin 传输

set -e

# ================= 配置区 =================
ROUTER="${1:-root@192.168.100.1}"

# 路由器目标目录
ROUTER_GFWLIST="/etc/gfwlist"
ROUTER_INITD="/etc/init.d"
ROUTER_NFT="/etc/nftables.d"

# 本地脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 部署到 /etc/gfwlist/ 的文件列表（Python 脚本 + Shell 脚本）
GFWLIST_FILES="
    geoip2nftset.py
    geosite2nftset.py
    update-proxy-domains.sh
    update-cn-domains.sh
"
# ==========================================

# 颜色输出
_green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
_red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
_step()   { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }

# 通过 ssh stdin 传输文件（不依赖 sftp/scp）
# 用法: _ssh_put <local> <remote>          — 二进制原样传输
#       _ssh_put_lf <local> <remote>       — 同时去掉 \r（Windows CRLF → LF）
_ssh_put() {
    ssh "$ROUTER" "cat > '$2'" < "$1"
}
_ssh_put_lf() {
    ssh "$ROUTER" "tr -d '\r' > '$2'" < "$1"
}

# ---------- 开始 ----------
echo ""
echo "======================================"
echo "  wg_route_cn 部署脚本"
echo "  目标路由器: $ROUTER"
echo "======================================"

# ---------- Step 1: 检查本地依赖 ----------
_step "1/5" "检查本地环境"

if ! command -v python3 >/dev/null 2>&1; then
    _red "错误: 本机未找到 python3，无法预生成 cn_direct.nft"
    exit 1
fi
_green "  python3: $(python3 --version 2>&1)"

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ROUTER" true 2>/dev/null; then
    _red "错误: 无法连接到 $ROUTER（请检查 SSH 密钥或路由器地址）"
    exit 1
fi
_green "  SSH 连接: OK"

# ---------- Step 2: 本地预生成 cn_direct.nft ----------
_step "2/5" "准备 CN IP nftables sets"

CN_NFT="$SCRIPT_DIR/cn_direct.nft"
if [ -s "$CN_NFT" ]; then
    _green "  使用已有 cn_direct.nft（$(wc -l < "$CN_NFT" | tr -d ' ') 行）"
    _yellow "  如需更新，请先删除后重新运行: rm $CN_NFT"
else
    _yellow "  cn_direct.nft 不存在，正在下载 geoip.dat 并生成（约需 30s）..."
    python3 "$SCRIPT_DIR/geoip2nftset.py" -c CN -o "$CN_NFT"
    _green "  cn_direct.nft 已生成：$(wc -l < "$CN_NFT" | tr -d ' ') 行"
fi

# ---------- Step 3: 创建路由器目录 ----------
_step "3/5" "创建路由器目标目录"

ssh "$ROUTER" "mkdir -p '$ROUTER_GFWLIST' '$ROUTER_NFT'"
_green "  $ROUTER_GFWLIST  OK"
_green "  $ROUTER_NFT  OK"

# ---------- Step 4: 部署 /etc/gfwlist/ ----------
_step "4/5" "部署脚本到 $ROUTER_GFWLIST"

for f in $GFWLIST_FILES; do
    [ -z "$f" ] && continue
    local_path="$SCRIPT_DIR/$f"
    remote_path="$ROUTER_GFWLIST/$f"

    if [ ! -f "$local_path" ]; then
        _yellow "  (跳过) $f — 本地文件不存在"
        continue
    fi

    # 所有文本文件都去掉 \r，.sh 额外 chmod +x
    _ssh_put_lf "$local_path" "$remote_path"
    case "$f" in
        *.sh) ssh "$ROUTER" "chmod +x '$remote_path'" ;;
    esac
    _green "  $f"
done

# cn_direct.nft 传到 /etc/nftables.d/（nft 文件用 LF，已在生成时保证）
_ssh_put "$CN_NFT" "$ROUTER_NFT/cn_direct.nft"
_green "  cn_direct.nft → $ROUTER_NFT/cn_direct.nft"

# ---------- Step 5: 部署 wg_route_cn ----------
_step "5/5" "部署 wg_route_cn → $ROUTER_INITD/wg_route_cn"

_ssh_put_lf "$SCRIPT_DIR/wg_route_cn" "$ROUTER_INITD/wg_route_cn"
ssh "$ROUTER" "chmod +x '$ROUTER_INITD/wg_route_cn'"
_green "  wg_route_cn"

ssh "$ROUTER" "/etc/init.d/wg_route_cn enable"
_green "  enable 完成（S99/K10 符号链接已创建）"

# ---------- 完成 ----------
echo ""
_green "======================================"
_green "  部署完成！"
_green "======================================"
echo ""
echo "后续操作："
echo "  立即启动:  ssh $ROUTER '/etc/init.d/wg_route_cn start'"
echo "  查看规则:  ssh $ROUTER 'nft list chain inet fw4 prerouting_wg'"
echo "  停止服务:  ssh $ROUTER '/etc/init.d/wg_route_cn stop'"
echo ""
