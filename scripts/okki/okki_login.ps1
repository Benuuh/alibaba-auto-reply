# okki/okki_login.ps1 - OKKI(小满 CRM) 登录态失效时的自动登录(spec OKKI自动登录_20260925 §6 S3)。
#   职责:限流检查 → 读凭据 → 填表(#email/#password) → 勾同意/记住 → 复查按钮可用后点击
#         → 轮询 DOM 事实判定登录态 → 落限流状态。**只做登录,不做任何业务写入**。
#   凭据来源:credentials.md 的 okki_account / okki_password(经 lib\creds.ps1 读取)。
#            本文件不得出现任何凭据值、不得把填入值写进日志。
#   退出码:0 OK / 2 NO_FORM / 3 CDP-DOWN / 4 NO_CREDS / 9 CONFIG-MISSING
#          10 NEED_2FA(验证码/短信,交人工) / 11 COOLDOWN(限流) / 12 SUBMIT_FAILED / 1 ERROR
#   硬约束:只操作 okki_cdp_port(9223),禁止触碰 9222;遇到验证码/短信立即停机且**不重试**。
#   编码:UTF8-BOM(C1)。
param(
    [switch]$Quiet          # $true 时不写 Write-Host,只写日志
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\log.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\creds.ps1")
. (Join-Path $PSScriptRoot "okki_lib.ps1")

# 限流硬约束(spec §4-5):两次尝试间隔 >= 10 分钟,每小时 <= 3 次。不得放宽。
$MinIntervalSec = 600
$MaxPerHour     = 3
$PollMaxSec     = 45
$PollStepSec    = 1

function Say([string]$m) { if (-not $Quiet) { Write-Host $m } }

function Exit-With([int]$code, [string]$msg) {
    Write-OkkiLog "OKKI-LOGIN: $msg"
    Say "OKKI-LOGIN: $msg"
    exit $code
}

# 限流状态文件:data\okki_login_state.json(无 BOM,经 Write-OkkiJsonNoBom)
function Get-OkkiLoginStateFile { return (Join-Path (Get-OkkiDir "data") "okki_login_state.json") }

function Read-OkkiLoginState {
    $st = [pscustomobject]@{ lastAttempt = ""; lastSuccess = ""; attempts = @() }
    $f = Get-OkkiLoginStateFile
    if (Test-Path $f) {
        try {
            $o = (Get-Content $f -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($o) {
                if ($o.lastAttempt) { $st.lastAttempt = [string]$o.lastAttempt }
                if ($o.lastSuccess) { $st.lastSuccess = [string]$o.lastSuccess }
                if ($o.attempts) { $st.attempts = @($o.attempts | ForEach-Object { [string]$_ }) }
            }
        } catch { /* 损坏按空状态,交由限流重新计数 */ }
    }
    return $st
}

function Write-OkkiLoginState($st) {
    $obj = New-OkkiOrderedDict
    $obj["lastAttempt"] = [string]$st.lastAttempt
    $obj["lastSuccess"] = [string]$st.lastSuccess
    $obj["attempts"]    = @($st.attempts)
    Write-OkkiJsonNoBom (Get-OkkiLoginStateFile) $obj
}

# 只保留最近 1 小时内的尝试(内联实现:避免函数返回空数组被 PS 解包成 $null 导致计数失真)
function Get-RecentAttempts($attempts, $now) {
    $recent = @()
    foreach ($a in @($attempts)) {
        $s = [string]$a
        if (-not $s -or $s.Trim() -eq '') { continue }
        $t = $null
        try { $t = [datetime]::ParseExact($s, "yyyy-MM-dd HH:mm:ss", $null) } catch { $t = $null }
        if ($t -and ($now - $t).TotalSeconds -lt 3600 -and ($now - $t).TotalSeconds -ge -60) { $recent += $s }
    }
    return ,$recent
}

# ---- 页内 JS:填表(值经 Get-JsB64Literal 注入,不做字符串拼接) ----
$JsFillTpl = @'
(function(acc, pwd){
  var out = { filled:false, reason:'', agree:null, remember:null, btnFound:false, btnDisabled:null };
  function q(s){ try { return document.querySelector(s); } catch(e){ return null; } }
  var elA = q('#email'), elP = q('#password');
  if (!elA || !elP) { out.reason = 'NO_FORM_FIELDS'; return JSON.stringify(out); }
  if ((elA.tagName||'').toLowerCase() !== 'input' || (elP.tagName||'').toLowerCase() !== 'input') {
    out.reason = 'NOT_INPUT'; return JSON.stringify(out);
  }
  var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
  set.call(elA, acc); elA.dispatchEvent(new Event('input', {bubbles:true})); elA.dispatchEvent(new Event('change', {bubbles:true}));
  set.call(elP, pwd); elP.dispatchEvent(new Event('input', {bubbles:true})); elP.dispatchEvent(new Event('change', {bubbles:true}));
  out.filled = true;
  var agree = q('input.agree-checkbox');
  if (agree) { if (agree.checked !== true) { agree.click(); } out.agree = (agree.checked === true); }
  var rem = q('#remember');
  if (rem) { if (rem.checked !== true) { rem.click(); } out.remember = (rem.checked === true); }
  var btn = q('button.next-btn');
  if (!btn) { out.reason = 'NO_BUTTON'; return JSON.stringify(out); }
  out.btnFound = true;
  out.btnDisabled = !!btn.disabled;
  return JSON.stringify(out);
})(__ACC__, __PWD__)
'@

# 复查按钮可用性;可用才点击(点前必须复查 !disabled)
$JsClick = @'
(function(){
  var out = { btnFound:false, disabled:null, clicked:false };
  var btn = null;
  try { btn = document.querySelector('button.next-btn'); } catch(e) { btn = null; }
  if (!btn) { out.btnFound = false; return JSON.stringify(out); }
  out.btnFound = true;
  out.disabled = !!btn.disabled;
  if (!out.disabled) { btn.click(); out.clicked = true; }
  return JSON.stringify(out);
})()
'@

# 轮询期间的人机校验探测(只报事实,不回显任何输入值)
$JsGuardTpl = @'
(function(initialPwd){
  var host = location.host || '', path = location.pathname || '';
  var body = document.body ? (document.body.innerText || '') : '';
  var txt = body.substring(0, 4000);
  var smsLike = /验证码|动态码|短信验证|手机验证|二次验证|安全验证|verification code|verify code/i.test(txt);
  var pwd = document.querySelectorAll('input[type=password]').length;
  var codeInputs = 0;
  try {
    codeInputs = document.querySelectorAll('input[placeholder*="验证码"],input[placeholder*="动态码"],input[placeholder*="短信"],input[name*="captcha"],input[id*="captcha"]').length;
  } catch(e) { codeInputs = 0; }
  return JSON.stringify({ host:host, path:path.substring(0,80), pwdInputs:pwd,
                          newPwdInputs:(pwd > initialPwd), smsHint:smsLike, codeInputs:codeInputs });
})(__INITPWD__)
'@

try {
    # ---- 0. 配置 ----
    $cfg = $null
    try { $cfg = Assert-OkkiConfig } catch { Exit-With 9 "CONFIG-MISSING: $($_.Exception.Message)" }
    $port = [int]$cfg.CdpPort
    if ($port -eq 9222) { Exit-With 9 "REFUSE: okki_cdp_port=9222 是现役阿里链路端口,拒绝操作" }

    Say "OKKI-LOGIN: start port=$port"

    # ---- 1. 凭据(只判有无与长度,绝不回显) ----
    $acct = Get-CredentialValue 'okki_account'
    $pwd  = Get-CredentialValue 'okki_password'
    if (-not $acct -or -not $pwd) { Exit-With 4 "NO_CREDS credentials.md 缺少 okki_account/okki_password" }

    # ---- 2. 限流(spec §4-5 硬约束:>=10min 间隔,<=3 次/小时) ----
    $st = Read-OkkiLoginState
    $now = Get-Date
    $recent = Get-RecentAttempts $st.attempts $now
    if ($st.lastAttempt) {
        $la = $null
        try { $la = [datetime]::ParseExact($st.lastAttempt, "yyyy-MM-dd HH:mm:ss", $null) } catch { $la = $null }
        if ($la) {
            $gap = ($now - $la).TotalSeconds
            if ($gap -lt $MinIntervalSec) {
                $wait = [int][Math]::Ceiling($MinIntervalSec - $gap)
                Exit-With 11 "COOLDOWN 距上次尝试仅 $([int]$gap)s(需 $MinIntervalSec s),还需等待 $wait s"
            }
        }
    }
    if (@($recent).Count -ge $MaxPerHour) {
        Exit-With 11 "COOLDOWN 最近 1 小时内已尝试 $(@($recent).Count) 次(上限 $MaxPerHour)"
    }

    # ---- 3. CDP 就绪 ----
    if (-not (Test-OkkiCdpReady -Port $port)) { Exit-With 3 "CDP-DOWN port=$port 不可达" }

    # 记录本次尝试(先记录后执行:失败的尝试同样计入限流,避免异常路径绕过限流)
    $st.lastAttempt = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $st.attempts = @($recent) + @($st.lastAttempt)
    Write-OkkiLoginState $st

    # ---- 4. 页面必须在登录页(不在则导航) ----
    $jsUrl = "(function(){return location.host + location.pathname})()"
    $cur = ""
    try { $cur = (Invoke-OkkiCdpEval $jsUrl).Trim() } catch { $cur = "" }
    if ($cur -notmatch 'login\.' -and $cur -notmatch 'crm\.') {
        Write-OkkiLog "OKKI-LOGIN: 当前页($cur)非登录页,导航到登录页"
        [void](Invoke-OkkiCdpRaw -Action "navigate" -Url "https://login.xiaoman.cn/login")
        Start-Sleep -Seconds 6
    } else {
        Write-OkkiLog "OKKI-LOGIN: 当前页 = $cur"
    }

    # ---- 5. 填表 ----
    $jsFill = $JsFillTpl.Replace('__ACC__', (Get-JsB64Literal $acct)).Replace('__PWD__', (Get-JsB64Literal $pwd))
    $fillRaw = Invoke-OkkiCdpEval $jsFill
    $fill = $fillRaw | ConvertFrom-Json
    if (-not $fill.filled) {
        Exit-With 2 "NO_FORM url=$cur reason=$($fill.reason)"
    }
    Write-OkkiLog ("OKKI-LOGIN: 已填表 agree=" + $fill.agree + " remember=" + $fill.remember + " btnFound=" + $fill.btnFound)

    # ---- 6. 复查按钮可用性后点击 ----
    Start-Sleep -Milliseconds 700
    $clickRaw = Invoke-OkkiCdpEval $JsClick
    $click = $clickRaw | ConvertFrom-Json
    if (-not $click.btnFound) { Exit-With 2 "NO_FORM 找不到登录按钮 button.next-btn" }
    if ($click.disabled) { Exit-With 12 "SUBMIT_FAILED 登录按钮仍 disabled(同意框未生效?)" }
    if (-not $click.clicked) { Exit-With 12 "SUBMIT_FAILED 登录按钮未点击" }
    Write-OkkiLog "OKKI-LOGIN: 已点击登录按钮"

    # ---- 7. 轮询判定(DOM 事实),期间探测人机校验 ----
    $initialPwd = 1
    $deadline = (Get-Date).AddSeconds($PollMaxSec)
    $lastState = $null
    $guardHit = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollStepSec
        try {
            $s = (Invoke-OkkiCdpEval (Get-OkkiLoginStateJs)) | ConvertFrom-Json
            $lastState = $s
            if ($s.loggedIn) { break }
        } catch { $s = $null }

        if ($s -and -not $s.loggedIn) {
            try {
                $g = (Invoke-OkkiCdpEval ($JsGuardTpl.Replace('__INITPWD__', [string]$initialPwd))) | ConvertFrom-Json
                if ($g.smsHint -or $g.codeInputs -gt 0 -or $g.newPwdInputs) { $guardHit = $g; break }
            } catch { }
        }
    }

    # ---- 8. 人机校验 → 立即停机,不重试(spec §4-6) ----
    if ($guardHit) {
        Write-OkkiLog ("OKKI-LOGIN: 检出人机校验 smsHint=" + $guardHit.smsHint + " codeInputs=" + $guardHit.codeInputs + " newPwdInputs=" + $guardHit.newPwdInputs + " url=" + $guardHit.host + $guardHit.path)
        Exit-With 10 "NEED_2FA 页面要求验证码/短信/二次验证,已停机等待人工处理(不自动重试)"
    }

    # ---- 9. 已登录?若已到业务站但判定未过,导航根域再判一次 ----
    if (-not ($lastState -and $lastState.loggedIn)) {
        $hostNow = ""
        try { $hostNow = ((Invoke-OkkiCdpEval "(function(){return location.host})()").Trim()) } catch { $hostNow = "" }
        if ($hostNow -match 'crm\.xiaoman\.cn') {
            Write-OkkiLog "OKKI-LOGIN: 已在业务域但判定未过,导航根域复判"
            [void](Invoke-OkkiCdpRaw -Action "navigate" -Url $cfg.BaseUrl)
            Start-Sleep -Seconds 6
            try { $lastState = (Invoke-OkkiCdpEval (Get-OkkiLoginStateJs)) | ConvertFrom-Json } catch { }
        }
    }

    if ($lastState -and $lastState.loggedIn) {
        $st.lastSuccess = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Write-OkkiLoginState $st
        Write-OkkiLog "OKKI-LOGIN: OK url=$($lastState.host)$($lastState.path)"
        Say "OKKI-LOGIN: OK url=$($lastState.host)$($lastState.path)"
        exit 0
    }

    $where = if ($lastState) { "$($lastState.host)$($lastState.path)" } else { "<unknown>" }
    Exit-With 12 "SUBMIT_FAILED 提交后 ${PollMaxSec}s 内未达成登录态(DOM 判定) url=$where"
} catch {
    Write-OkkiLog "OKKI-LOGIN: ERROR $($_.Exception.Message)"
    Say "OKKI-LOGIN: ERROR $($_.Exception.Message)"
    exit 1
}
