# health_check.ps1 - F8 health heartbeat (2026-09-16). ASCII-only on purpose.
# Checks: monitor process + log freshness / watchdog process / cooldown / wecom / control-agent / CDP + page login.
# Alerts via WeCom with 30-min dedup per check; writes logs\health.log. Always exits 0 unless fatal.
param([string]$LogDir = "")

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logsDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$script:logFile = Join-Path $script:logsDir "health.log"
$script:stateFile = Join-Path $script:dataDir "health_state.json"

function Write-Log([string]$m) { Write-SkillLog $m $script:logFile }

function Get-CimByCmd([string]$pattern) {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and ($_.CommandLine -match $pattern) })
}
function Test-PidAlive([string]$pidFile, [string]$cmdPattern) {
    if (-not (Test-Path $pidFile)) { return $false }
    $v = 0
    try { $v = [int]((Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()) } catch { return $false }
    if ($v -le 0) { return $false }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$v" -ErrorAction SilentlyContinue
    if ($p -and $p.CommandLine -and ($p.CommandLine -match $cmdPattern)) { return $true }
    return $false
}
function Get-MonLogAgeSec {
    $f = Join-Path $script:logsDir "monitor.log"
    if (Test-Path $f) { return [int]((Get-Date) - (Get-Item $f).LastWriteTime).TotalSeconds }
    return 999999
}

$checks = New-Object System.Collections.ArrayList
function Add-Check([string]$name, [bool]$ok, [string]$detail) { [void]$checks.Add([pscustomobject]@{ name = $name; ok = $ok; detail = $detail }) }

try {
    $monOk = Test-PidAlive (Join-Path $LogDir "monitor.pid") 'monitor\.ps1'
    $monDetail = "alive"
    if (-not $monOk) { $monDetail = "pid file missing/stale or cmdline mismatch" }
    Add-Check "monitor_process" $monOk $monDetail

    $age = Get-MonLogAgeSec
    Add-Check "monitor_log_fresh" ($age -lt 600) ("log age " + $age + "s (limit 600s)")

    $wdOk = Test-PidAlive (Join-Path $LogDir "watchdog.pid") 'watchdog\.ps1'
    $wdDetail = "alive"
    if (-not $wdOk) { $wdDetail = "watchdog NOT running" }
    Add-Check "watchdog_process" $wdOk $wdDetail

    $cdActive = $false; $cdUntil = ""
    $cdFile = Join-Path $script:logsDir "watchdog_cooldown.json"
    if (Test-Path $cdFile) {
        try {
            $c = Get-Content $cdFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.until -and ([datetime]::Parse([string]$c.until) -gt (Get-Date))) { $cdActive = $true; $cdUntil = [string]$c.until }
        } catch { }
    }
    $cdDetail = "none"
    if ($cdActive) { $cdDetail = "COOLDOWN until " + $cdUntil }
    Add-Check "watchdog_cooldown" (-not $cdActive) $cdDetail

    $wcOk = $false
    try { $wcOk = ((Invoke-RestMethod 'http://127.0.0.1:19886/health' -TimeoutSec 5).connected -eq $true) } catch { }
    $wcDetail = "connected"
    if (-not $wcOk) { $wcDetail = "19886 not connected" }
    Add-Check "wecom_connected" $wcOk $wcDetail

    $caProcs = @(Get-CimByCmd 'agent_bridge\.js')
    $caDisabled = Test-Path (Join-Path (Split-Path $PSScriptRoot -Parent) "tools\control-agent\data\control-agent.disabled")
    $caOk = ($caProcs.Count -gt 0) -or $caDisabled
    $caDetail = "down and not disabled"
    if ($caProcs.Count -gt 0) { $caDetail = "running" } elseif ($caDisabled) { $caDetail = "disabled by flag" }
    Add-Check "control_agent" $caOk $caDetail

    $cdpOk = Test-CdpReady
    $cdpDetail = "reachable"
    if (-not $cdpOk) { $cdpDetail = "unreachable" }
    Add-Check "cdp_9222" $cdpOk $cdpDetail

    if ($cdpOk) {
        $js = "(function(){return JSON.stringify({url:(location.href||'').substring(0,60),hasTa:!!document.querySelector('textarea.send-textarea'),onLogin:!!document.querySelector('input[name=account]')})})()"
        $st = Invoke-CdpEval $js
        $pageOk = ($st -match 'hasTa":true')
        Add-Check "page_logged_in" $pageOk ([string]$st)
    }
} catch { Write-Log ("HEALTH-ERR: " + $_.Exception.Message) }

$state = @{}
if (Test-Path $script:stateFile) {
    try {
        $j = Get-Content $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $state[$p.Name] = $p.Value }
    } catch { }
}
$now = Get-Date
$alerts = New-Object System.Collections.ArrayList
$recovers = New-Object System.Collections.ArrayList
foreach ($c in $checks) {
    $prev = $null
    if ($state.ContainsKey($c.name)) { $prev = $state[$c.name] }
    $prevOk = $null
    if ($prev -and ($prev.PSObject.Properties.Name -contains 'ok')) { $prevOk = [bool]$prev.ok }
    if (-not $c.ok) {
        $lastAlert = $null
        if ($prev -and ($prev.PSObject.Properties.Name -contains 'lastAlert') -and $prev.lastAlert) {
            try { $lastAlert = [datetime]::Parse([string]$prev.lastAlert) } catch { }
        }
        if (-not $lastAlert -or ($now - $lastAlert).TotalMinutes -ge 30) {
            [void]$alerts.Add("[HEALTH] " + $c.name + " FAIL: " + $c.detail)
            $state[$c.name] = @{ ok = $false; lastAlert = $now.ToString('yyyy-MM-dd HH:mm:ss') }
        } else {
            $state[$c.name] = @{ ok = $false; lastAlert = [string]$prev.lastAlert }
        }
    } else {
        if ($prevOk -eq $false) { [void]$recovers.Add("[HEALTH] " + $c.name + " RECOVERED") }
        $state[$c.name] = @{ ok = $true; lastAlert = $null }
    }
}
$statusLine = "HEALTH: " + (($checks | ForEach-Object { $_.name + "=" + $(if ($_.ok) { "OK" } else { "FAIL" }) }) -join " ")
Write-Log $statusLine
foreach ($a in $alerts) {
    try { $r = Send-WecomMessage $a; Write-Log ("HEALTH-ALERT: " + $a + " -> " + $r) } catch { Write-Log ("HEALTH-ALERT-FAIL: " + $_.Exception.Message) }
}
foreach ($r in $recovers) {
    try { $x = Send-WecomMessage $r; Write-Log ("HEALTH-RECOVER: " + $r + " -> " + $x) } catch { }
}
try { $state | ConvertTo-Json -Depth 5 | Set-Content -Path $script:stateFile -Encoding UTF8 } catch { }
exit 0
