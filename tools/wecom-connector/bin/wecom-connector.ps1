# bin/wecom-connector.ps1 - 组件启动/停止/状态(幂等;输出码与旧 wecom_start.ps1 兼容)
# 用法: powershell -ExecutionPolicy Bypass -File bin\wecom-connector.ps1 -Action start|stop|status
# 启动: 检查 HTTP 健康(已运行则跳过) → 从 config.json 读凭据经环境变量注入 → 拉起 node server.js
# 凭据优先级: 调用方环境变量 WX_BOT_ID/WX_BOT_SECRET(已设置则不覆盖) > config.json bot_id/bot_secret
# 无凭据也可启动(不连接企微,HTTP 桥可用,health.connected=false)
param([string]$Action = "start")

$ErrorActionPreference = "Stop"
$script:root = Split-Path $PSScriptRoot -Parent
. (Join-Path $script:root "lib\ps-common.ps1")
$script:configFile = Join-Path $script:root "config.json"
$script:serverJs = Join-Path $script:root "server.js"
$script:logDir = Join-Path $script:root "logs"
$script:port = Conn-DefaultPort
if ($env:WECOM_PORT) { $script:port = [int]$env:WECOM_PORT }
else {
    $script:cfg = Get-ConnConfig
    if ($script:cfg) {
        if ($script:cfg.port) { $script:port = [int]$script:cfg.port }
        if ($script:cfg.log_dir) { $script:logDir = Join-Path $script:root $script:cfg.log_dir }
    }
}
$script:baseUrl = "http://127.0.0.1:" + $script:port

function Test-BridgeReady {
    try {
        $r = Invoke-WebRequest -Uri ($script:baseUrl + "/health") -TimeoutSec 2 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Get-ComponentProcesses {
    # PS 5.1 坑:函数返回单元素数组会被展开为单个对象(调用方 .Count 变 $null),逗号强制按数组返回
    return ,@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($script:serverJs) })
}

# 凭据是否可用:调用方环境变量优先,其次 config.json(bot_id/bot_secret;占位值跳过)
function Test-CredsAvailable {
    if ($env:WX_BOT_ID -and $env:WX_BOT_SECRET) { return $true }
    $cfg = Get-ConnConfig
    if ($cfg -and $cfg.bot_id -and $cfg.bot_secret -and $cfg.bot_id -notmatch "占位" -and $cfg.bot_secret -notmatch "占位") { return $true }
    return $false
}

# 应用凭据:把可用凭据写入进程环境(供 Start-Process 子进程继承)
function Apply-Creds {
    if (-not $env:WX_BOT_ID -or -not $env:WX_BOT_SECRET) {
        $cfg = Get-ConnConfig
        if ($cfg) {
            if ($cfg.bot_id -and $cfg.bot_id -notmatch "占位") { if (-not $env:WX_BOT_ID) { $env:WX_BOT_ID = [string]$cfg.bot_id } }
            if ($cfg.bot_secret -and $cfg.bot_secret -notmatch "占位") { if (-not $env:WX_BOT_SECRET) { $env:WX_BOT_SECRET = [string]$cfg.bot_secret } }
        }
    }
}

function Start-Bridge {
    # 幂等门控:健康 OK 且进程确为本组件 → 已运行;健康 OK 但进程非本组件 → 端口被占用,诚实失败
    if (Test-BridgeReady) {
        $p = @(Get-ComponentProcesses)
        if ($p.Count -gt 0) {
            # 自愈:凭据可用但当前进程未连接企微(如无凭据模式启动的残留实例)→ 重启应用凭据
            if (-not (Test-CredsAvailable)) { Write-Output ("WECOM-ALREADY-RUNNING (PID " + $p[0].ProcessId + ")"); exit 0 }
            $h = Invoke-RestMethod -Uri ($script:baseUrl + "/health") -TimeoutSec 3 -UseBasicParsing
            if ($h.connected -eq $true) { Write-Output ("WECOM-ALREADY-RUNNING (PID " + $p[0].ProcessId + ")"); exit 0 }
            Write-Output ("WECOM-RESTARTING (no-bot instance PID " + $p[0].ProcessId + ", creds available)")
            foreach ($proc in $p) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
            Start-Sleep -Seconds 2
        } else {
            Write-Output "WECOM-START-FAIL (port in use by another service)"
            exit 1
        }
    } else {
        # 进程在但桥未就绪:等 5 秒再看(启动中)
        Start-Sleep -Seconds 5
        if (Test-BridgeReady) {
            $p = @(Get-ComponentProcesses)
            if ($p.Count -gt 0) { Write-Output ("WECOM-ALREADY-RUNNING (PID " + $p[0].ProcessId + ")"); exit 0 }
            Write-Output "WECOM-START-FAIL (port in use by another service)"
            exit 1
        }
    }
    Apply-Creds
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }
    Start-Process -FilePath "node.exe" -ArgumentList ("`"" + $script:serverJs + "`"") -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $script:logDir "wecom_bot.log") `
        -RedirectStandardError (Join-Path $script:logDir "wecom_bot.err.log") | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-BridgeReady) { break }
        Start-Sleep -Seconds 1
    }
    if (Test-BridgeReady) {
        $p = @(Get-ComponentProcesses)
        if ($p.Count -gt 0) { Write-Output ("WECOM-STARTED (PID " + $p[0].ProcessId + ")"); exit 0 }
        Write-Output "WECOM-STARTED (health ok)"
        exit 0
    }
    Write-Output "WECOM-START-FAIL"
    exit 1
}

function Stop-Bridge {
    Get-ComponentProcesses | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Write-Output "WECOM-STOPPED"
}

function Show-Status {
    try {
        $h = Invoke-RestMethod -Uri ($script:baseUrl + "/health") -TimeoutSec 3 -UseBasicParsing
        Write-Output ("health: connected=" + $h.connected)
        $s = Invoke-RestMethod -Uri ($script:baseUrl + "/status") -TimeoutSec 3 -UseBasicParsing
        Write-Output ("status: uptime_sec=" + $s.uptime_sec + " msg_count=" + $s.msg_count)
        if ($s.consumers) {
            foreach ($prop in ($s.consumers.PSObject.Properties)) { Write-Output ("  consumer " + $prop.Name + " seq=" + $prop.Value) }
        }
    } catch { Write-Output "status: SERVICE_DOWN" }
}

switch ($Action) {
    "start" { Start-Bridge }
    "stop" { Stop-Bridge }
    "status" { Show-Status }
    default { Write-Output "Usage: wecom-connector.ps1 -Action start|stop|status" }
}
