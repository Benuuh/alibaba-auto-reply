# health_report.ps1 - daily health report pushed to WeCom (08:30 scheduled)
# Aggregates monitor status into a short text message; no credentials, no PII.
param([string]$LogDir = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
if (-not $script:logFileDir) { $script:logFileDir = Join-Path (Split-Path $LogDir -Parent) "logs" }
$monitorLog = Join-Path $script:logFileDir "monitor.log"
$logFile = Join-Path $script:logFileDir "monitor.log"
function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# --- gather facts ---
$mon = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'monitor\\.ps1' })
$wd = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'watchdog\\.ps1' })
$wc = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'wecom_bot' })
$cdpOk = $false
try { $cdp = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -TimeoutSec 3; if ($cdp) { $cdpOk = $true } } catch { $cdpOk = $false }

$repliedToday = 0; $llmErr = 0; $monErr = 0; $retry = 0; $logFresh = "n/a"
if (Test-Path $monitorLog) {
    $log = Get-Content $monitorLog -Encoding UTF8
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $repliedToday = @($log | Where-Object { $_ -match ("^" + $today) -and $_ -match "REPLIED to" }).Count
    $llmErr = @($log | Where-Object { $_ -match ("^" + $today) -and $_ -match "LLM error" }).Count
    $monErr = @($log | Where-Object { $_ -match ("^" + $today) -and $_ -match "Monitor error" }).Count
    $retry = @($log | Where-Object { $_ -match ("^" + $today) -and $_ -match "RETRY-QUEUE" }).Count
    $last = (Get-Item $monitorLog).LastWriteTime
    $logFresh = [string][int]((Get-Date) - $last).TotalMinutes + "m"
}

$stateFile = Join-Path $LogDir "state.json"
$buyerCount = 0
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $bad = @("IsFixedSize","IsSynchronized","Count","IsReadOnly","Values","Keys","SyncRoot")
        $buyerCount = @($st.replied.PSObject.Properties.Name | Where-Object { $_ -notin $bad }).Count
    } catch {}
}

$okMon = if ($mon.Count -gt 0) { "RUNNING" } else { "DOWN" }
$okWd = if ($wd.Count -gt 0) { "RUNNING" } else { "DOWN" }
$okWc = if ($wc.Count -gt 0) { "RUNNING" } else { "DOWN" }
$okCdp = if ($cdpOk) { "OK" } else { "DOWN" }
$status = "OK"
if ($okMon -eq "DOWN" -or $okCdp -eq "DOWN" -or $llmErr -gt 0 -or $monErr -gt 0) { $status = "ATTENTION" }

$msg = "[Health] alibaba-auto-reply " + (Get-Date -Format "yyyy-MM-dd HH:mm") + [char]10 +
"Status: " + $status + [char]10 +
"Monitor: " + $okMon + "  Watchdog: " + $okWd + "  WeCom: " + $okWc + "  CDP: " + $okCdp + [char]10 +
"Today replied: " + $repliedToday + "  LLM err: " + $llmErr + "  Monitor err: " + $monErr + [char]10 +
"Retry queue: " + $retry + "  Active buyers: " + $buyerCount + "  Log fresh: " + $logFresh

$res = Send-WecomMessage $msg
Write-Output ("HEALTH-REPORT: " + $res)
Write-Log ("HEALTH-REPORT: " + $res)
