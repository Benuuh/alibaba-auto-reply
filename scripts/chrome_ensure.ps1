param(
    [string]$LogDir = "",
    [string]$CredFile = "",
    [switch]$ForceRestart,          # [FIX-DATAPLANE 2026-09-25] 数据面断连时由 monitor 传入
    [int]$HealthProbeTimeoutSec = 25 # 重启后等待数据面恢复的上限
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
if (-not $CredFile) { $CredFile = Get-SkillPath "creds" }
if (-not $CredFile) { $CredFile = Join-Path (Split-Path $LogDir -Parent) "credentials.md" }

$cdp = Join-Path $LogDir "cdp.ps1"
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"
$profileDir = Get-SkillPath "profile"
if (-not $profileDir) { $profileDir = Join-Path (Split-Path $LogDir -Parent) "chrome-profile" }
$chromePath = Get-SkillPath "chrome"
if (-not $chromePath) { $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe" }
$cdpPort = Get-CdpPort

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

function Get-LoginState {
    $js = @"
(function(){
  return JSON.stringify({url: location.href.substring(0,80), hasTa: !!document.querySelector('textarea.send-textarea'), onLogin: !!document.querySelector('input[name=account]')});
})()
"@
    return Invoke-CdpEval $js
}

# [FIX-DATAPLANE 2026-09-25] 数据面判据：CDP 可用 ≠ 数据面可用。
#   背景（实测 2026-09-25 22:24-23:56）：页面横幅"网络连接已经断开"时，
#     - Test-CdpReady = true（端口活着）
#     - textarea.send-textarea 仍存在 ⇒ Get-LoginState 判"已登录" ⇒ 原逻辑 exit 0 空操作
#     - location.reload() 已试 53 次无效（IM 长连接不会自愈）
#   ⇒ 唯一可自动化的恢复手段是**按 profile 精确重启 Chrome**。
#   ⚠️ 只在 PageDown 为真时才重启；PageDown 为假时行为与本修复前完全一致。
#
#   ⚠️ 关键：重启后页面是 about:blank，Test-PageHealth 的 URL 守卫会返回
#     Reason='wrong-tab:*' —— 那是"还没导航"，**不是**数据面故障。必须用
#     Test-PageDataPlane -Forced 跳过 wrong-tab 判定，否则重启会被误判为无效。
function Test-PageDataPlane {
    param([switch]$Forced)
    try {
        $r = Test-PageHealth
        if ($null -eq $r) { return @{ Down=$false; Reason='probe-null' } }
        if ($r -is [array]) { $r = $r[0] }     # 防管道污染（附录 B/C12 同类教训）
        # [FIX-PAGESELECT 2026-09-26] S1-3 空守卫：Get-Page 无 OneTalk 页时返回 $null ⇒ 本函数仍返回
        #   对象（wrong-tab），但若拿到的是字符串（CDP 错误文本）则说明判据本身失效：按"未取到证据"处理，
        #   **不**据此触发重启（避免把探测故障当数据面故障 ⇒ 重启风暴）。
        if (-not ($r.PSObject.Properties.Name -contains 'PageDown')) { return @{ Down=$false; Reason='probe-invalid' } }
        $reason = [string]$r.Reason
        # 刚重启 Chrome 时页面还没导航到 OneTalk：wrong-tab 是预期中间态，不算断连
        if ($Forced -and $reason -like 'wrong-tab:*') { return @{ Down=$false; Reason='pre-navigate' } }
        return @{ Down=[bool]$r.PageDown; Reason=$reason }
    } catch {
        # 探测本身失败 → 保守地**不**触发重启（避免把探测故障当成数据面故障，造成重启风暴）
        return @{ Down=$false; Reason=("probe-error: " + $_.Exception.Message) }
    }
}

function Restart-DebugChrome {
    param([string]$Reason)
    # 先断言（§4-11）：把"要重启"的意图与依据写进日志
    Write-Log ("CHROME-ENSURE: FORCE-RESTART triggered by $Reason")
    $targets = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'remote-debugging-port' -or $_.CommandLine -match [regex]::Escape($profileDir) })
    Write-Log ("CHROME-ENSURE: FORCE-RESTART targets=" + $targets.Count + " pids=" + (($targets | ForEach-Object { $_.ProcessId }) -join ','))
    if ($targets.Count -eq 0) {
        Write-Log "CHROME-ENSURE: FORCE-RESTART no matching chrome.exe (profile-scoped) - skip kill, will launch"
    }
    foreach ($t in $targets) { try { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 3
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    Start-Process -FilePath $chromePath -ArgumentList `
        "--remote-debugging-port=$cdpPort", "--user-data-dir=$profileDir", `
        "--no-first-run", "--no-default-browser-check", `
        "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", `
        "about:blank"
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) { if (Test-CdpReady) { break }; Start-Sleep -Seconds 1 }
    if (-not (Test-CdpReady)) { Write-Log "CHROME-ENSURE: FORCE-RESTART FAILED to start Chrome"; return $false }
    Write-Log "CHROME-ENSURE: FORCE-RESTART chrome up, CDP ready"
    return $true
}

# == 数据面判据入口（在 CDP 就绪性判断之前执行）==
$pd = Test-PageDataPlane
Write-Log ("CHROME-ENSURE: pageDataPlane down=" + $pd.Down + " reason=" + $pd.Reason)
$forced = $false
if ($pd.Down) {
    if (Restart-DebugChrome -Reason ("pageDataPlane:" + $pd.Reason)) {
        $forced = $true
        # 重启后等数据面恢复（轮询，上限 $HealthProbeTimeoutSec）。
        # 注意用 -Forced：此时页面是 about:blank，wrong-tab 属预期中间态。
        $dl = (Get-Date).AddSeconds($HealthProbeTimeoutSec)
        while ((Get-Date) -lt $dl) {
            Start-Sleep -Seconds 5
            $pd2 = Test-PageDataPlane -Forced
            if (-not $pd2.Down) { Write-Log ("CHROME-ENSURE: after force-restart probe reason=" + $pd2.Reason); break }
        }
        $pdEnd = Test-PageDataPlane -Forced
        if ($pdEnd.Down) { Write-Log "CHROME-ENSURE: data plane STILL DOWN after force-restart (will continue to login path)" }
        else { Write-Log "CHROME-ENSURE: force-restart finished, proceed to navigate+login path" }
    } else {
        Write-Log "CHROME-ENSURE: force-restart could not bring Chrome up"
    }
}

# 1. 若 CDP 未就绪：杀掉残留的调试 Chrome 进程并重启带调试端口的 Chrome
if (-not (Test-CdpReady)) {
    Write-Log "CHROME-ENSURE: CDP not ready, restarting Chrome..."
    # 只终止调试实例(带 remote-debugging 标志或使用本技能 profile 的进程),
    # 不误杀用户个人 Chrome(默认 profile 的浏览器会话)
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'remote-debugging-port' -or $_.CommandLine -match [regex]::Escape($profileDir) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    Start-Process -FilePath $chromePath -ArgumentList `
        "--remote-debugging-port=$cdpPort", "--user-data-dir=$profileDir", `
        "--no-first-run", "--no-default-browser-check", `
        "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", `
        "about:blank"
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Test-CdpReady) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-CdpReady)) {
        Write-Log "CHROME-ENSURE: FAILED to start Chrome"
        exit 1
    }
    Write-Log "CHROME-ENSURE: Chrome restarted, CDP ready"
    Start-Sleep -Seconds 3
}

# 2. 导航到 OneTalk
powershell -ExecutionPolicy Bypass -File $cdp -Action navigate -Url "https://onetalk.alibaba.com/message/weblitePWA.htm" | Out-Null
Start-Sleep -Seconds 8

# 3. 检查登录状态
$state = Get-LoginState
Write-Log "CHROME-ENSURE: login state = $state"

if ($state -match 'hasTa":true') {
    # [FIX-DATAPLANE 2026-09-25] hasTa 只代表"控件在"，不代表"数据面通"。
    #   若数据面仍断，不得再报"already logged in"后静默 exit 0。
    #   ⚠️ 刚重启 Chrome 时页面可能仍在加载（URL 还是 about:blank 或正在导航）
    #      ⇒ Test-PageHealth 会返回 wrong-tab ⇒ 直接用 -Forced 会漏判。
    #   因此这里先给一个就绪宽限窗口（最多 40 秒），再做一次**不加 -Forced** 的严格判定。
    $grace = (Get-Date).AddSeconds(40)
    $pdNow = $null
    while ((Get-Date) -lt $grace) {
        $pdNow = Test-PageDataPlane       # 严格：wrong-tab 也算 Down
        if (-not $pdNow.Down) { break }
        if ($pdNow.Reason -notlike 'wrong-tab:*') { break }   # 已导航到 OneTalk 但仍断 → 无需再等
        Start-Sleep -Seconds 5
    }
    if ($pdNow -and $pdNow.Down) {
        Write-Log ("CHROME-ENSURE: hasTa=true but pageDataPlane DOWN (" + $pdNow.Reason + ") - NOT exiting as healthy")
        exit 4
    }
    Write-Log "CHROME-ENSURE: already logged in"
    exit 0
}

# 4. 未登录 → 从 credentials.md 读取凭据自动登录（统一走 lib\creds.ps1）
if ($state -match 'onLogin":true' -or $state -match 'login\.alibaba') {
    if (-not (Test-Path $CredFile)) { Write-Log "CHROME-ENSURE: credentials file not found: $CredFile"; exit 1 }
    $acct = Get-CredentialValue 'account'
    $pwd = Get-CredentialValue 'password'
    if (-not $acct -or -not $pwd) { Write-Log "CHROME-ENSURE: cannot parse credentials"; exit 1 }
    $escA = $acct.Replace("'","\'").Replace("\","\\")
    $escP = $pwd.Replace("'","\'").Replace("\","\\")
    $loginJs = @"
(function(){
  var setVal = function(el, val){
    var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
      : (el instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLElement.prototype);
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, val);
    el.dispatchEvent(new Event('input', {bubbles:true}));
    el.dispatchEvent(new Event('change', {bubbles:true}));
  };
  var a = document.querySelector('input[name=account]');
  var p = document.querySelector('input[name=password]');
  if (!a || !p) return 'INPUTS_NOT_FOUND';
  setVal(a, '$escA');
  setVal(p, '$escP');
  var b = document.querySelector('button.sif_form-submit');
  if (b) b.click();
  return 'LOGGING_IN';
})()
"@
    $r = Invoke-CdpEval $loginJs
    Write-Log "CHROME-ENSURE: login attempt = $r"
    Start-Sleep -Seconds 10
    $state2 = Get-LoginState
    Write-Log "CHROME-ENSURE: after login = $state2"
    if ($state2 -match 'hasTa":true') { Write-Log "CHROME-ENSURE: login SUCCESS"; exit 0 }
    else {
        Write-Log "CHROME-ENSURE: login may have failed, manual check needed"
        exit 2
    }
} else {
    Write-Log "CHROME-ENSURE: unknown page state, manual check needed"
    exit 3
}
