# lib/alert_local.ps1 - local alert fallback channel (the only observable path when WeCom is down). ASCII-only.
# Why: health_check alerts used to be delivered only through the WeCom long connection, so a dead channel
# silenced its own alarm (see spec 2026-09-22 R4). This module writes the alarm to local files + a popup.
# Files: <logs>\alert_active.json (open alerts), <logs>\ALERT.md (append-only history).
# Dependency: config.ps1 (Get-SkillPath "logs"); log.ps1 is optional (used for POPUP-SPAWNED lines).
# Contract: every function swallows its own errors and never throws - health_check must always exit 0.

function Get-LocalAlertDir {
    $d = $null
    try { $d = Get-SkillPath "logs" } catch { $d = $null }
    if (-not $d) { $d = Join-Path (Split-Path $PSScriptRoot -Parent) "logs" }
    return $d
}

function Get-LocalAlertFile { return (Join-Path (Get-LocalAlertDir) "alert_active.json") }
function Get-LocalAlertMd { return (Join-Path (Get-LocalAlertDir) "ALERT.md") }

function Get-LocalAlertLogFile {
    try { return (Join-Path (Get-SkillPath "logs") "health.log") } catch { return "" }
}

# Append one line to ALERT.md (append-only history; failure is silent by design)
function Add-LocalAlertMd([string]$line) {
    try {
        $md = Get-LocalAlertMd
        $dir = Split-Path $md -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $md -Value $line -Encoding UTF8
    } catch { }
}

# Read alert_active.json; returns an array (never $null). Corrupt file == no state.
function Get-LocalAlert {
    $items = @()
    try {
        $f = Get-LocalAlertFile
        if (-not (Test-Path $f)) { return @() }
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j) { return @() }
        if ($j -is [System.Array]) { return @($j) }
        if ($j.PSObject.Properties.Name -contains 'items') { return @($j.items) }
    } catch { }
    return $items
}

function Save-LocalAlert($items) {
    try {
        $f = Get-LocalAlertFile
        $dir = Split-Path $f -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # keep the same shape across runs: {"items":[...]}
        $obj = [pscustomobject]@{ items = @($items) }
        $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $f -Encoding UTF8
    } catch { }
}

# Desktop popup in a detached child process so health_check never blocks (R6: silent no-op if unsupported)
function Show-LocalAlertPopup([string]$text) {
    try {
        $safe = ([string]$text) -replace '[\r\n]', ' '
        $safe = $safe -replace '\\', '/'          # avoid escape sequences inside the single-quoted PS payload
        if ($safe.Length -gt 200) { $safe = $safe.Substring(0, 200) }
        $cmd = '(New-Object -ComObject WScript.Shell).Popup("' + $safe + '",20,"WECOM ALERT",48) | Out-Null'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', $cmd) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        return "POPUP-SPAWNED"
    } catch { return ("POPUP-SKIPPED: " + $_.Exception.Message) }
}

# Write (or refresh) the local alert for one check.
# Returns LOCAL_ALERT_WRITTEN / LOCAL_ALERT_ERROR: <msg>; never throws.
function Write-LocalAlert([string]$check, [string]$detail, [string]$wecomResult) {
    try {
        $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $items = @(Get-LocalAlert | Where-Object { $_ -and ($_.check -ne $check) })
        $items += [pscustomobject]@{ check = $check; detail = $detail; wecom = $wecomResult; first_ts = $now; last_ts = $now }
        Save-LocalAlert $items
        Add-LocalAlertMd ("[" + $now + "] ALERT " + $check + " | " + $detail + " | wecom=" + $wecomResult)
        $pop = Show-LocalAlertPopup ("[HEALTH] " + $check + " FAIL: " + $detail)
        $logFile = Get-LocalAlertLogFile
        if ($logFile) { try { Write-SkillLog $pop $logFile } catch { } }
        return "LOCAL_ALERT_WRITTEN"
    } catch {
        return ("LOCAL_ALERT_ERROR: " + $_.Exception.Message)
    }
}

# Clear the local alert for one check (file removed when it becomes empty). Never throws.
function Clear-LocalAlert([string]$check) {
    try {
        $items = @(Get-LocalAlert | Where-Object { $_ -and ($_.check -ne $check) })
        $f = Get-LocalAlertFile
        if ($items.Count -eq 0) {
            if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        } else {
            Save-LocalAlert $items
        }
        Add-LocalAlertMd ("[" + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "] ALERT-CLEARED " + $check)
        return "LOCAL_ALERT_CLEARED"
    } catch { return ("LOCAL_ALERT_ERROR: " + $_.Exception.Message) }
}
