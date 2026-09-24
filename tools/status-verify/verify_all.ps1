# verify_all.ps1 - workspace-wide liveness verification (read-only, re-runnable)
# 2026-09-21 | spec: specs\工作区全组件运行状态核实_20260921.md
# 只读：不启停任何进程、不写除 reports\status_verify_*.json 以外的任何文件
# 部署根从脚本自身位置推导(tools\status-verify\ -> 上两级),避免把本机绝对路径写进仓库
param(
  [string]$Root   = '',
  [string]$OutDir = '',
  [string]$Tag    = 'run',
  # 可选外部组件路径:默认从用户主目录推导,不暴露本机用户名
  [string]$AccioCliJson = '',
  [string]$AccioExe     = ''
)

$ErrorActionPreference = 'SilentlyContinue'
# 部署根默认 = 本脚本上两级(tools\status-verify\ -> 仓库根),不写死本机路径
if (-not $Root) { $Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
if (-not $AccioCliJson) {
  # 账号 ID 因机器而异:自动探测 .accio\accounts\<id>\ 下的 gateway-cli.json,不写死内部 ID
  $gwHit = @(Get-ChildItem (Join-Path $HOME '.accio\accounts') -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { Join-Path $_.FullName '.accio\runtime\gateway-cli.json' } |
             Where-Object { Test-Path $_ })
  if ($gwHit.Count -gt 0) { $AccioCliJson = $gwHit[0] }
}
if (-not $AccioExe) { $AccioExe = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Accio work\Accio.exe' }
$root = $Root
if (-not $OutDir) { $OutDir = Join-Path $root 'reports' }
$now  = Get-Date
$res  = [ordered]@{ ts = $now.ToString('yyyy-MM-dd HH:mm:ss'); tag = $Tag; components = [ordered]@{}; summary = [ordered]@{} }

function Add-Comp($name, $ok, $detail, $data) {
  $script:res.components[$name] = [ordered]@{ ok = $ok; detail = $detail; data = $data }
  $m = 'OK'; if (-not $ok) { $m = 'FAIL' }
  Write-Output ("[{0}] {1,-16} {2}" -f $m, $name, $detail)
}
function Get-PidFromFile($f) {
  if (-not (Test-Path $f)) { return 0 }
  $v = (Get-Content $f -Raw -Encoding UTF8) -replace '\D',''
  if ($v -eq '') { return 0 }
  return [int]$v
}
function Test-CmdLine($pat) {
  $n = 0
  foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    if ($p.CommandLine -ne $null -and $p.CommandLine -match $pat) { $n++ }
  }
  return $n
}
function Get-NewestFileAgeSec($dir, $filter) {
  $f = Get-ChildItem $dir -Filter $filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f -eq $null) { return -1 }
  return [int]((Get-Date) - $f.LastWriteTime).TotalSeconds
}
function Test-Port($port) {
  $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c -eq $null) { return @{ open = $false; pid = 0 } }
  return @{ open = $true; pid = [int]$c.OwningProcess }
}

# ---------- 1. monitor ----------
$mp = Get-PidFromFile "$root\scripts\monitor.pid"
$mAlive = [bool](Get-Process -Id $mp -ErrorAction SilentlyContinue)
$mAge = Get-NewestFileAgeSec "$root\logs" 'monitor.log'
$mOk = $mAlive -and ($mAge -ge 0) -and ($mAge -lt 600)
Add-Comp 'monitor' $mOk ("pid={0} alive={1} log_age={2}s (limit 600s)" -f $mp, $mAlive, $mAge) @{ pid = $mp; alive = $mAlive; log_age_sec = $mAge }

# ---------- 2. watchdog ----------
$wp = Get-PidFromFile "$root\scripts\watchdog.pid"
$wAlive = [bool](Get-Process -Id $wp -ErrorAction SilentlyContinue)
$wAge = Get-NewestFileAgeSec "$root\logs" 'watchdog.log'
$wOk = $wAlive -and ($wAge -ge 0) -and ($wAge -lt 3600)
Add-Comp 'watchdog' $wOk ("pid={0} alive={1} log_age={2}s (limit 3600s)" -f $wp, $wAlive, $wAge) @{ pid = $wp; alive = $wAlive; log_age_sec = $wAge }

# ---------- 3. chrome-cdp ----------
$cdpVer = $null; $cdpPages = -1
try { $cdpVer = (Invoke-WebRequest 'http://127.0.0.1:9222/json/version' -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json } catch { }
try { $cdpPages = @((Invoke-WebRequest 'http://127.0.0.1:9222/json/list' -TimeoutSec 5 -UseBasicParsing).Content | ConvertFrom-Json).Count } catch { }
$cdpPort = Test-Port 9222
$cdpOk = ($cdpVer -ne $null) -and $cdpPort.open
$bVer = ''; if ($cdpVer -ne $null) { $bVer = [string]$cdpVer.Browser }
Add-Comp 'chrome-cdp' $cdpOk ("port=9222 open={0} browser={1} pages={2}" -f $cdpPort.open, $bVer, $cdpPages) @{ port_open = $cdpPort.open; browser = $bVer; pages = $cdpPages; owning_pid = $cdpPort.pid }

# ---------- 4. wecom-connector (TCP-only; GET / returns 404 by design) ----------
$wPort = Test-Port 19886
$wPidFile = Get-PidFromFile "$root\tools\control-agent\data\control-agent.pid"
$wcAge = Get-NewestFileAgeSec "$root\tools\wecom-connector\logs" 'wecom_bot*.log'
$tcpOk = $false
try { $cli = New-Object System.Net.Sockets.TcpClient; $cli.Connect('127.0.0.1', 19886); $tcpOk = $cli.Connected; $cli.Close() } catch { }
$wOk = $wPort.open -and $tcpOk
Add-Comp 'wecom-connector' $wOk ("port=19886 tcp_accept={0} owning_pid={1} log_age={2}s" -f $tcpOk, $wPort.pid, $wcAge) @{ port_open = $wPort.open; tcp_accept = $tcpOk; owning_pid = $wPort.pid; log_age_sec = $wcAge }

# ---------- 5. control-agent ----------
$cp = Get-PidFromFile "$root\tools\control-agent\data\control-agent.pid"
$cAlive = [bool](Get-Process -Id $cp -ErrorAction SilentlyContinue)
$bAlive = Test-CmdLine 'agent_bridge\.js'
$cAge = Get-NewestFileAgeSec "$root\tools\control-agent\logs" 'agent.log'
$cOk = $cAlive -and ($bAlive -gt 0)
Add-Comp 'control-agent' $cOk ("pid={0} alive={1} bridge_procs={2} log_age={3}s (idle!=broken)" -f $cp, $cAlive, $bAlive, $cAge) @{ pid = $cp; alive = $cAlive; bridge_procs = $bAlive; log_age_sec = $cAge }

# ---------- 6. scheduled tasks ----------
$taskNames = @('AlibabaAutoReplyHealth','AlibabaAutoReplySummary','AlibabaAutoReplyQuality','AlibabaAutoReplyOptimize','AlibabaAutoReplyWeekly','AlibabaAutoReplyWatchdog')
$budget = @{ 'AlibabaAutoReplyHealth' = 1800; 'AlibabaAutoReplySummary' = 14400; 'AlibabaAutoReplyQuality' = 86400; 'AlibabaAutoReplyOptimize' = 86400; 'AlibabaAutoReplyWeekly' = 604800; 'AlibabaAutoReplyWatchdog' = 604800 }
$tBad = 0; $tLines = @()
foreach ($tn in $taskNames) {
  $i = Get-ScheduledTaskInfo -TaskName $tn -ErrorAction SilentlyContinue
  if ($i -eq $null) { $tBad++; $tLines += "$tn MISSING"; continue }
  $late = ($i.NextRunTime -ne $null) -and ($i.NextRunTime -lt $now)
  $badRes = ($i.LastTaskResult -ne 0) -and ($tn -ne 'AlibabaAutoReplyWatchdog')
  $skip = ($tn -eq 'AlibabaAutoReplyWatchdog')
  $thisBad = $late -or $badRes
  if ($thisBad) { $tBad++ }
  $tLines += ("{0}: result={1} next={2} late={3}" -f $tn, $i.LastTaskResult, $i.NextRunTime, $late)
}
$tOk = ($tBad -eq 0)
Add-Comp 'scheduled-tasks' $tOk ("{0}/{1} healthy; bad={2}" -f ($taskNames.Count - $tBad), $taskNames.Count, $tBad) @{ detail_lines = $tLines; bad_count = $tBad }
foreach ($l in $tLines) { Write-Output ("      " + $l) }

# ---------- 7. data-freshness ----------
$msgNew = Get-ChildItem "$root\data" -Filter 'msgs_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$msgAge = -1; if ($msgNew -ne $null) { $msgAge = [int]($now - $msgNew.LastWriteTime).TotalSeconds }
$buyerN = @(Get-ChildItem "$root\data\buyers" -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
$msgN = @(Get-ChildItem "$root\data" -Filter 'msgs_*.txt' -File -ErrorAction SilentlyContinue).Count
$repN = @(Get-ChildItem "$root\reports" -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
$hs = $null; try { $hs = Get-Content "$root\data\health_state.json" -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$hsBad = 0
if ($hs -ne $null) { foreach ($p in $hs.PSObject.Properties) { if ($p.Value.ok -ne $true) { $hsBad++ } } }
$dfOk = ($msgAge -ge 0) -and ($msgAge -lt 7200) -and ($hsBad -eq 0)
Add-Comp 'data-freshness' $dfOk ("newest_msg_age={0}s (limit 7200s) buyers={1} msgs={2} reports={3} health_bad={4}" -f $msgAge, $buyerN, $msgN, $repN, $hsBad) @{ newest_msg_age_sec = $msgAge; buyers = $buyerN; msgs = $msgN; reports = $repN; health_bad = $hsBad }

# ---------- 8. accio-gateway ----------
$gwFile = $AccioCliJson
$gwExists = Test-Path $gwFile
$gwPort = Test-Port 4097
$gwExe = $AccioExe
$gwExeExists = Test-Path $gwExe
$gwProc = Test-CmdLine 'Accio\.exe'
$gwOk = $gwPort.open
Add-Comp 'accio-gateway' $gwOk ("port4097_open={0} exe_exists={1} accio_procs={2} cli_json_exists={3}" -f $gwPort.open, $gwExeExists, $gwProc, $gwExists) @{ port_open = $gwPort.open; exe_exists = $gwExeExists; accio_procs = $gwProc; cli_json_exists = $gwExists }

# ---------- 9. frozen-files (git state) ----------
$porcelain = @(git -C $root status --porcelain)
$dirty = @($porcelain | Where-Object { $_ -match 'reply_rules\.json|reply_agent_prompt\.md' })
$head = (git -C $root rev-parse --short HEAD)
Add-Comp 'frozen-files' ($dirty.Count -eq 0) ("HEAD={0} dirty_frozen={1}" -f $head, $dirty.Count) @{ head = $head; dirty = $dirty; porcelain_all = $porcelain }

# ---------- summary ----------
$okN = 0; $failN = 0; $fails = @()
foreach ($k in $res.components.Keys) {
  if ($res.components[$k].ok) { $okN++ } else { $failN++; $fails += $k }
}
$res.summary = [ordered]@{ ok = $okN; fail = $failN; failing = $fails }
Write-Output ("SUMMARY ok={0} fail={1} failing=[{2}]" -f $okN, $failN, ($fails -join ','))

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outFile = Join-Path $OutDir ("status_verify_{0}_{1}.json" -f $now.ToString('yyyyMMdd_HHmmss'), $Tag)
[IO.File]::WriteAllText($outFile, ($res | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Output ("REPORT_JSON=" + $outFile)
exit 0
