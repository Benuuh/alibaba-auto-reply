# health_check.ps1 - F8 health heartbeat (2026-09-16). ASCII-only on purpose.
# Checks: monitor process + log freshness / watchdog process / cooldown / wecom / control-agent / CDP + page login.
# Alerts via WeCom with 30-min dedup per check; writes logs\health.log. Always exits 0 unless fatal.
param([string]$LogDir = "")

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\alert_local.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
. (Join-Path $PSScriptRoot "lib\deadman.ps1")
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
        # [FIX-PAGEHEALTH 2026-09-25] hasTa 在断连时依然为 true（实测断连页 sendTextarea=1），
        #   必须叠加数据面判据，否则"页面断连"会被判为 OK（health.log 22:48/23:03 即此误报）。
        $ph = Test-PageHealth
        # [FIX-PAGESELECT 2026-09-26] S1-3 空守卫：Get-Page 无 OneTalk 页时返回 $null，
        #   Test-PageHealth 正常仍返回对象（wrong-tab 判定），但异常路径可能返回字符串/数组；
        #   直接取 $ph.PageDown 会静默拿到 $null ⇒ 把"判据失效"伪装成"未断连"。这里显式归一化。
        if ($ph -is [array]) { $ph = $ph[0] }
        if ($null -eq $ph -or -not ($ph.PSObject.Properties.Name -contains 'PageDown')) {
            $ph = [pscustomobject]@{ PageDown=$true; Reason='probe-invalid'; Items=0; Spinner=0; Tab=''; Tip='' }
        }
        $pageOk = ($st -match 'hasTa":true') -and (-not $ph.PageDown)
        $phDetail = "pageDown=$($ph.PageDown) reason=$($ph.Reason) items=$($ph.Items) spin=$($ph.Spinner)"
        Add-Check "page_logged_in" $pageOk ("$st | $phDetail")
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
# Alert fan-out (2026-09-22 F3): WeCom is the primary channel but it dies together with the very thing it
# reports on, so every failed send also lands in the local channel (logs\alert_active.json + logs\ALERT.md
# + desktop popup) which status.ps1 reads. Never breaks the exit-0 contract.
foreach ($a in $alerts) {
    try {
        $r = Send-WecomMessage $a
        Write-Log ("HEALTH-ALERT: " + $a + " -> " + $r)
        if ($r -ne 'SENT_OK') {
            $cn = ([string]$a -replace '^\[HEALTH\]\s+', '') -replace '\s+FAIL:.*$', ''
            $dt = ([string]$a -replace '^.*?FAIL:\s*', '')
            $lr = Write-LocalAlert $cn $dt ([string]$r)
            Write-Log ("HEALTH-ALERT-LOCAL: " + $cn + " wecom=" + $r + " -> " + $lr)
        }
    } catch { Write-Log ("HEALTH-ALERT-FAIL: " + $_.Exception.Message) }
}
foreach ($r in $recovers) {
    try {
        $x = Send-WecomMessage $r
        Write-Log ("HEALTH-RECOVER: " + $r + " -> " + $x)
        $cn = ([string]$r -replace '^\[HEALTH\]\s+', '') -replace '\s+RECOVERED.*$', ''
        $lr = Clear-LocalAlert $cn
        Write-Log ("HEALTH-RECOVER-LOCAL: " + $cn + " -> " + $lr)
    } catch { }
}

# F8b watchdog auto-heal (2026-09-18): start watchdog detached when watchdog_process fails.
# Idempotent (pid file + command line double-check); heal attempts throttled to one per 30 min via state key
# 'watchdog_heal' (same 30-min period as alerts); HEAL/HEAL-FAIL traces in health.log; never breaks exit 0.
try {
    $wdCheck = $checks | Where-Object { $_.name -eq 'watchdog_process' } | Select-Object -First 1
    if ($wdCheck -and (-not $wdCheck.ok)) {
        $lastHeal = $null
        $healPrev = $null
        if ($state.ContainsKey('watchdog_heal')) { $healPrev = $state['watchdog_heal'] }
        if ($healPrev -and ($healPrev.PSObject.Properties.Name -contains 'lastHeal') -and $healPrev.lastHeal) {
            try { $lastHeal = [datetime]::Parse([string]$healPrev.lastHeal) } catch { }
        }
        if (-not $lastHeal -or ($now - $lastHeal).TotalMinutes -ge 30) {
            if (Test-PidAlive (Join-Path $LogDir "watchdog.pid") 'watchdog\.ps1') {
                # already running (started between check and heal) - no action, no throttle update
            } else {
                $wdScript = Join-Path $LogDir "watchdog.ps1"
                $wdOut = Join-Path $script:logsDir "watchdog_out.log"
                $wdErr = Join-Path $script:logsDir "watchdog_err.log"
                $healResult = 'fail'
                try {
                    # [FIX-ENVBLOCK 2026-09-25] 原 Start-Process 带 -RedirectStandard* 在本机必抛
                    #   ArgumentException 'NO_PROXY / no_proxy'(health.log 23:10:01 "HEALTH-HEAL-FAIL"
                    #   即此路径),导致 watchdog 自愈拉起永远失败。watchdog 是常驻无限循环,
                    #   不能对它做管道重定向(父进程不排空即死锁) → 改走 Start-ProcessClean 不带重定向;
                    #   代价:logs\watchdog_out.log / watchdog_err.log 不再更新(watchdog 自身写 watchdog.log)。
                    #   幂等语义不变:下方仍按 watchdog.pid + 命令行双重校验。
                    $wdArgList = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', ('"' + $wdScript + '"'), '-Action', 'start')
                    [void](Start-ProcessClean -FilePath 'powershell.exe' -ArgumentList $wdArgList)
                    Start-Sleep -Seconds 6
                    if (Test-PidAlive (Join-Path $LogDir "watchdog.pid") 'watchdog\.ps1') {
                        $wdPid = ''
                        try { $wdPid = (Get-Content (Join-Path $LogDir "watchdog.pid") -Raw -ErrorAction SilentlyContinue).Trim() } catch { }
                        Write-Log ("HEALTH-HEAL pid=" + $wdPid)
                        $healResult = 'ok'
                    } else {
                        Write-Log "HEALTH-HEAL-FAIL"
                    }
                } catch {
                    Write-Log ("HEALTH-HEAL-FAIL: " + $_.Exception.Message)
                }
                $state['watchdog_heal'] = @{ lastHeal = $now.ToString('yyyy-MM-dd HH:mm:ss'); result = $healResult }
            }
        }
    }
} catch { }
try { $state | ConvertTo-Json -Depth 5 | Set-Content -Path $script:stateFile -Encoding UTF8 } catch { }

# P0 deadman heartbeat (2026-09-18): ping external URL every health run (ping only, no PII);
# health.log throttled to max one line per 6h (state in data\deadman_state.json). fail never alerts (no alert loop).
try {
    $dmCfg = Get-SkillConfig
    $dmUrl = ''
    if ($dmCfg.PSObject.Properties.Name -contains 'deadman_ping_url') { $dmUrl = [string]$dmCfg.deadman_ping_url }
    if ($dmUrl) {
        $dmRes = Send-DeadmanPing $dmUrl
        $dmStateFile = Join-Path $script:dataDir 'deadman_state.json'
        $dmLast = $null
        if (Test-Path $dmStateFile) {
            try { $dmLast = [datetime]::Parse([string]((Get-Content $dmStateFile -Raw -Encoding UTF8 | ConvertFrom-Json).lastLog)) } catch { }
        }
        if (-not $dmLast -or ((Get-Date) - $dmLast).TotalHours -ge 6) {
            Write-Log ("DEADMAN-PING " + $dmRes)
            $dmState = [pscustomobject]@{ lastLog = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); result = $dmRes }
            try { $dmState | ConvertTo-Json | Set-Content -Path $dmStateFile -Encoding UTF8 } catch { }
        }
    }
} catch { Write-Log ("DEADMAN-ERR: " + $_.Exception.Message) }
exit 0
