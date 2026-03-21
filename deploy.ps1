#Requires -Version 5.1
# deploy.ps1 - 将 wg_route_cn 及相关文件部署到 OpenWrt 路由器
#
# 用法:
#   .\deploy.ps1 [用户@路由器IP]
#
# 示例:
#   .\deploy.ps1 root@192.168.1.1
#   .\deploy.ps1                      # 使用默认地址
#
# 依赖(本机): python3, ssh (Windows OpenSSH)

param(
    [string]$Router = "root@192.168.100.1"
)

$ErrorActionPreference = "Stop"

# ================= 配置区 =================
$ROUTER_GFWLIST = "/etc/gfwlist"
$ROUTER_INITD   = "/etc/init.d"
$ROUTER_NFT     = "/etc/nftables.d"

$SCRIPT_DIR = $PSScriptRoot

$GFWLIST_FILES = @(
    "geoip2nftset.py",
    "geosite2nftset.py",
    "update-proxy-domains.sh",
    "update-cn-domains.sh"
)
# ==========================================

function Write-Green([string]$msg)  { Write-Host $msg -ForegroundColor Green }
function Write-Yellow([string]$msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Red([string]$msg)    { Write-Host $msg -ForegroundColor Red }
function Write-Step([string]$n, [string]$msg) {
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

# 通过 SSH stdin 传输文件 (不依赖 sftp/scp)
# Send-SshFile   : 二进制原样传输
# Send-SshFileLF : 同时去掉 \r (Windows CRLF -> LF)
function Send-SshFile {
    param([string]$LocalPath, [string]$RemotePath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "ssh"
    $psi.Arguments              = "$Router `"cat > '$RemotePath'`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "SSH 传输失败: $LocalPath"
    }
}

function Send-SshFileLF {
    param([string]$LocalPath, [string]$RemotePath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = "ssh"
    $psi.Arguments              = "$Router `"tr -d '\r' > '$RemotePath'`""
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "SSH 传输失败: $LocalPath"
    }
}

# ---------- 开始 ----------
Write-Host ""
Write-Host "======================================"
Write-Host "  wg_route_cn 部署脚本"
Write-Host "  目标路由器: $Router"
Write-Host "======================================"

# ---------- Step 1: 检查本地依赖 ----------
Write-Step "1/5" "检查本地环境"

$PYTHON = $null
foreach ($cmd in @("python3", "python")) {
    $ver = & $cmd --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $PYTHON = $cmd
        Write-Green "  $cmd`: $ver"
        break
    }
}
if (-not $PYTHON) {
    Write-Red "错误: 本机未找到 python3，无法预生成 cn_direct.nft"
    exit 1
}

& ssh -o BatchMode=yes -o ConnectTimeout=5 $Router true 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Red "错误: 无法连接到 $Router (请检查 SSH 密钥或路由器地址)"
    exit 1
}
Write-Green "  SSH 连接: OK"

# ---------- Step 2: 本地预生成 cn_direct.nft ----------
Write-Step "2/5" "准备 CN IP nftables sets"

$CN_NFT = Join-Path $SCRIPT_DIR "cn_direct.nft"

if (Test-Path $CN_NFT) {
    $lineCount = (Get-Content $CN_NFT -Encoding UTF8).Count
    Write-Green "  使用已有 cn_direct.nft ($lineCount 行)"
    Write-Yellow "  如需更新，请先删除后重新运行: Remove-Item '$CN_NFT'"
} else {
    Write-Yellow "  cn_direct.nft 不存在，正在下载 geoip.dat 并生成 (约需 30s)..."
    & $PYTHON "$SCRIPT_DIR\geoip2nftset.py" -c CN -o $CN_NFT
    if ($LASTEXITCODE -ne 0) {
        Write-Red "错误: 生成 cn_direct.nft 失败"
        exit 1
    }
    $lineCount = (Get-Content $CN_NFT -Encoding UTF8).Count
    Write-Green "  cn_direct.nft 已生成: $lineCount 行"
}

# ---------- Step 3: 创建路由器目录 ----------
Write-Step "3/5" "创建路由器目标目录"

& ssh $Router "mkdir -p '$ROUTER_GFWLIST' '$ROUTER_NFT'"
Write-Green "  $ROUTER_GFWLIST  OK"
Write-Green "  $ROUTER_NFT  OK"

# ---------- Step 4: 部署 /etc/gfwlist/ ----------
Write-Step "4/5" "部署脚本到 $ROUTER_GFWLIST"

foreach ($f in $GFWLIST_FILES) {
    $localPath  = Join-Path $SCRIPT_DIR $f
    $remotePath = "$ROUTER_GFWLIST/$f"

    if (-not (Test-Path $localPath)) {
        Write-Yellow "  (跳过) $f - 本地文件不存在"
        continue
    }

    Send-SshFileLF -LocalPath $localPath -RemotePath $remotePath

    if ($f.EndsWith(".sh")) {
        & ssh $Router "chmod +x '$remotePath'"
    }
    Write-Green "  $f"
}

# cn_direct.nft 传到 /etc/nftables.d/
Send-SshFile -LocalPath $CN_NFT -RemotePath "$ROUTER_NFT/cn_direct.nft"
Write-Green "  cn_direct.nft -> $ROUTER_NFT/cn_direct.nft"

# ---------- Step 5: 部署 wg_route_cn ----------
Write-Step "5/5" "部署 wg_route_cn -> $ROUTER_INITD/wg_route_cn"

$WG_ROUTE = Join-Path $SCRIPT_DIR "wg_route_cn"
if (-not (Test-Path $WG_ROUTE)) {
    Write-Red "错误: 本地文件不存在: $WG_ROUTE"
    exit 1
}

Send-SshFileLF -LocalPath $WG_ROUTE -RemotePath "$ROUTER_INITD/wg_route_cn"
& ssh $Router "chmod +x '$ROUTER_INITD/wg_route_cn'"
Write-Green "  wg_route_cn"

& ssh $Router "/etc/init.d/wg_route_cn enable"
Write-Green "  enable 完成 (S99/K10 符号链接已创建)"

# ---------- 完成 ----------
Write-Host ""
Write-Green "======================================"
Write-Green "  部署完成！"
Write-Green "======================================"
Write-Host ""
Write-Host "后续操作："
Write-Host "  立即启动:  ssh $Router '/etc/init.d/wg_route_cn start'"
Write-Host "  查看规则:  ssh $Router 'nft list chain inet fw4 prerouting_wg'"
Write-Host "  停止服务:  ssh $Router '/etc/init.d/wg_route_cn stop'"
Write-Host ""
