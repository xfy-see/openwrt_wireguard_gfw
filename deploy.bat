@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

:: deploy.bat — 将 wg_route_cn 及相关文件部署到 OpenWrt 路由器
::
:: 用法:
::   deploy.bat [用户@路由器IP]
::
:: 示例:
::   deploy.bat root@192.168.100.130
::   deploy.bat                         （使用默认地址）
::
:: 依赖（本机）: python3, ssh (Windows OpenSSH)
:: 路由器无需 sftp/scp，文件通过 ssh stdin 传输

:: ================= 配置区 =================
if "%~1"=="" (
    set "ROUTER=root@192.168.1.1"
) else (
    set "ROUTER=%~1"
)

:: 路由器目标目录
set "ROUTER_GFWLIST=/etc/gfwlist"
set "ROUTER_INITD=/etc/init.d"
set "ROUTER_NFT=/etc/nftables.d"

:: 本地脚本目录（bat 文件所在目录）
set "SCRIPT_DIR=%~dp0"
:: 去掉末尾反斜杠
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: 部署到 /etc/gfwlist/ 的文件列表
set GFWLIST_FILES=geoip2nftset.py geosite2nftset.py update-proxy-domains.sh update-cn-domains.sh
:: ==========================================

echo.
echo ======================================
echo   wg_route_cn 部署脚本
echo   目标路由器: %ROUTER%
echo ======================================

:: ---------- Step 1: 检查本地依赖 ----------
echo.
echo [1/5] 检查本地环境

python3 --version >nul 2>&1
if errorlevel 1 (
    python --version >nul 2>&1
    if errorlevel 1 (
        echo [错误] 本机未找到 python3，无法预生成 cn_direct.nft
        exit /b 1
    ) else (
        set "PYTHON=python"
    )
) else (
    set "PYTHON=python3"
)

for /f "tokens=*" %%v in ('!PYTHON! --version 2^>^&1') do echo   python: %%v

ssh -o BatchMode=yes -o ConnectTimeout=5 "%ROUTER%" true >nul 2>&1
if errorlevel 1 (
    echo [错误] 无法连接到 %ROUTER%（请检查 SSH 密钥或路由器地址）
    exit /b 1
)
echo   SSH 连接: OK

:: ---------- Step 2: 本地预生成 cn_direct.nft ----------
echo.
echo [2/5] 准备 CN IP nftables sets

set "CN_NFT=%SCRIPT_DIR%\cn_direct.nft"

if exist "%CN_NFT%" (
    for /f %%c in ('find /c /v "" ^< "%CN_NFT%"') do set "NFT_LINES=%%c"
    echo   使用已有 cn_direct.nft（!NFT_LINES! 行）
    echo   如需更新，请先删除后重新运行: del "%CN_NFT%"
) else (
    echo   cn_direct.nft 不存在，正在下载 geoip.dat 并生成（约需 30s）...
    !PYTHON! "%SCRIPT_DIR%\geoip2nftset.py" -c CN -o "%CN_NFT%"
    if errorlevel 1 (
        echo [错误] 生成 cn_direct.nft 失败
        exit /b 1
    )
    for /f %%c in ('find /c /v "" ^< "%CN_NFT%"') do set "NFT_LINES=%%c"
    echo   cn_direct.nft 已生成：!NFT_LINES! 行
)

:: ---------- Step 3: 创建路由器目录 ----------
echo.
echo [3/5] 创建路由器目标目录

ssh "%ROUTER%" "mkdir -p '%ROUTER_GFWLIST%' '%ROUTER_NFT%'"
echo   %ROUTER_GFWLIST%  OK
echo   %ROUTER_NFT%  OK

:: ---------- Step 4: 部署 /etc/gfwlist/ ----------
echo.
echo [4/5] 部署脚本到 %ROUTER_GFWLIST%

for %%f in (%GFWLIST_FILES%) do (
    set "LOCAL_PATH=%SCRIPT_DIR%\%%f"
    set "REMOTE_PATH=%ROUTER_GFWLIST%/%%f"

    if not exist "!LOCAL_PATH!" (
        echo   ^(跳过^) %%f — 本地文件不存在
    ) else (
        :: 去掉 \r（CRLF → LF），通过 ssh stdin 传输
        ssh "%ROUTER%" "tr -d '\r' > '!REMOTE_PATH!'" < "!LOCAL_PATH!"

        :: .sh 文件额外 chmod +x
        echo %%f | findstr /i "\.sh$" >nul 2>&1
        if not errorlevel 1 (
            ssh "%ROUTER%" "chmod +x '!REMOTE_PATH!'"
        )
        echo   %%f
    )
)

:: cn_direct.nft 传到 /etc/nftables.d/
ssh "%ROUTER%" "cat > '%ROUTER_NFT%/cn_direct.nft'" < "%CN_NFT%"
echo   cn_direct.nft → %ROUTER_NFT%/cn_direct.nft

:: ---------- Step 5: 部署 wg_route_cn ----------
echo.
echo [5/5] 部署 wg_route_cn → %ROUTER_INITD%/wg_route_cn

set "WG_ROUTE=%SCRIPT_DIR%\wg_route_cn"
if not exist "%WG_ROUTE%" (
    echo [错误] 本地文件不存在: %WG_ROUTE%
    exit /b 1
)

ssh "%ROUTER%" "tr -d '\r' > '%ROUTER_INITD%/wg_route_cn'" < "%WG_ROUTE%"
ssh "%ROUTER%" "chmod +x '%ROUTER_INITD%/wg_route_cn'"
echo   wg_route_cn

ssh "%ROUTER%" "/etc/init.d/wg_route_cn enable"
echo   enable 完成（S99/K10 符号链接已创建）

:: ---------- 完成 ----------
echo.
echo ======================================
echo   部署完成！
echo ======================================
echo.
echo 后续操作：
echo   立即启动:  ssh %ROUTER% /etc/init.d/wg_route_cn start
echo   查看规则:  ssh %ROUTER% "nft list chain inet fw4 prerouting_wg"
echo   停止服务:  ssh %ROUTER% /etc/init.d/wg_route_cn stop
echo.

endlocal
