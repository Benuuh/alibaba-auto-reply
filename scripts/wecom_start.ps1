# wecom_start.ps1 v2 - wecom-connector keep-alive launcher (spec: 企微通道升级 Phase 2-3)
# Replaces v1 (old scripts\wecom\wecom_bot.js starter). Name/location unchanged for watchdog.
# Credentials are read from credentials.md and injected via process env only (never written to disk/config).
# Codes (watchdog compatible): WECOM-ALREADY-RUNNING / WECOM-NOT-CONNECTED / WECOM-NO-CREDS / WECOM-STARTED / WECOM-START-FAIL
param([string]$LogDir = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
if (-not $script:logFileDir) { $script:logFileDir = Join-Path (Split-Path $LogDir -Parent) "logs" }
$logFile = Join-Path $script:logFileDir "watchdog.log"
function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

$script:baseUrl = "http://127.0.0.1:19886"

# 1) Bridge healthy & connected -> already running (watchdog silent, no double start)
try {
    $h = Invoke-RestMethod -Uri ($script:baseUrl + "/health") -TimeoutSec 3
    if ($h.connected -eq $true) { Write-Output "WECOM-ALREADY-RUNNING"; exit 0 }
} catch { }

# 2) Connector process alive but not connected yet -> wait for SDK auto reconnect (no restart storm)
$procs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'wecom-connector' -and $_.CommandLine -match 'server\.js' })
if ($procs.Count -gt 0) { Write-Output "WECOM-NOT-CONNECTED"; exit 0 }

# 3) Not running -> inject creds via env (never to disk/config) and start via component bin
$botId = Get-CredentialValue 'wx_bot_id'
$botSecret = Get-CredentialValue 'wx_bot_secret'
if (-not $botId -or -not $botSecret) {
    Write-Log "WECOM-START: credentials missing in credentials.md (wx_bot_id/wx_bot_secret)"
    Write-Output "WECOM-NO-CREDS"
    exit 1
}
$env:WX_BOT_ID = $botId
$env:WX_BOT_SECRET = $botSecret
$env:WX_RECEIVER_FILE = Join-Path (Get-SkillPath "data") "wecom_receiver.json"

$bin = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\wecom-connector') 'bin\wecom-connector.ps1'
# 以文件重定向方式调用 bin(而非管道捕获):避免被启动的 node 进程继承管道句柄导致调用方(如 watchdog 轮询)悬挂
$tmpOut = Join-Path $env:TEMP ("wconn_out_" + $PID + ".txt")
$tmpErr = Join-Path $env:TEMP ("wconn_err_" + $PID + ".txt")
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-ExecutionPolicy Bypass -NoProfile -File "' + $bin + '" -Action start') -WindowStyle Hidden -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -PassThru
$child.WaitForExit(45000) | Out-Null
$out = @()
if (Test-Path $tmpOut) { $out = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
Remove-Item $tmpOut,$tmpErr -Force -ErrorAction SilentlyContinue
$joined = $out -join ' '
foreach ($line in $out) { Write-Log "WECOM-START: $line" }
if ($joined -match 'WECOM-STARTED') { Write-Output "WECOM-STARTED $joined"; exit 0 }
if ($joined -match 'WECOM-ALREADY-RUNNING') { Write-Output "WECOM-ALREADY-RUNNING"; exit 0 }
Write-Output "WECOM-START-FAIL"
exit 1
