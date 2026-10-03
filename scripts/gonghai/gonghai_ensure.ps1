# gonghai/gonghai_ensure.ps1 — [SPEC-公海独立Chrome 2026-09-27 §3.2] 公海自己的 Chrome 实例
#
# 做四件事(照抄 scripts\okki\okki_ensure.ps1 的成熟做法,并复用本模块已有的 CDP 能力):
#   ① 探测公海端口(gonghai_cdp_port,现役 9225)是否就绪
#   ② 未就绪 ⇒ 只启动"本任务 profile(gonghai_profile)+ 本任务端口"的 Chrome(**绝不误杀自动回复那个**)
#   ③ 导航到 OneTalk 并确保登录(+ 确保公海列表页也在**自己的**实例里)
#   ④ 输出 GONGHAI-ENSURE: OK / NEED_LOGIN,并把 activeAccountId 自述出来(§5-E4 的证据来源)
#
# 硬约束:
#   · 只操作 `gonghai_profile` 与 `gonghai_cdp_port`;**禁止**触碰 9222 实例(spec §4-P2 / §2.1);
#     端口 == config.cdp_port 时**直接拒绝启动**(fail-closed,见 Get-GonghaiCdpPort 的否决闸)。
#   · **禁止按进程名裸杀 chrome**(spec §3.2:"不许自己拼 taskkill");
#     只按"命令行含本 profile 目录 **且** 含本端口"的**精确匹配**定位(与 chrome_ensure/okki_ensure 同款思路,
#     但把判据收紧成"本 profile 目录"这**一个**必要条件 —— see Get-GonghaiChromeProcesses)。
#   · 本文件**不得**让 scripts\chrome_ensure.ps1 反过来依赖公海模块(那条线保持零依赖)。
# 编码:UTF-8 带 BOM(spec §6.1)。

param(
    [switch]$NoStart,           # 只探测,不起 Chrome
    [switch]$NoLogin,           # 只导航+判定,不尝试自动登录
    [int]$TimeoutSec = 40,      # 起 Chrome 后轮询 CDP 的最长等待(与 chrome_ensure.ps1 同口径)
    [int]$LoginWaitSec = 60     # 提交登录后等待跳转+渲染的上限(实测要几十秒,原来只等 10s ⇒ 假失败)
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) "config.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\log.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\cdp.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\creds.ps1")
. (Join-Path $here "gonghai_cdp.ps1")
# Get-GonghaiConfig(端口/profile 的权威读取口)在 gonghai_lib.ps1 里
. (Join-Path $here "gonghai_lib.ps1")

# 公海列表页(§5-E4:能读到会话/搜索到人 ⇒ 这个页必须也在公海自己的实例里)
#   ⚠️ 路径以 gonghai_probe.ps1 / gonghai_lib.ps1 里现役的匹配串为**权威**
#      (`i.alibaba.com/hub/alicrm/public_customer`);备用路径一并列在匹配串里容错。
$script:GonghaiPublicCustomerUrl = 'https://i.alibaba.com/hub/alicrm/public_customer'
$script:GonghaiPublicCustomerMatch = 'i\.alibaba\.com/hub/alicrm/public_customer|i\.alibaba\.com/hub/crm/public_customer'

function Say([string]$m) { Write-Output $m }
function Log([string]$m) {
    try { Write-SkillLog ("GONGHAI-ENSURE: " + $m) (Join-Path (Get-SkillPath "logs") "monitor.log") } catch { }
}
function Exit-With([int]$code, [string]$msg) {
    Say ("GONGHAI-ENSURE: " + $msg)
    Log $msg
    exit $code
}

# ---- 精确匹配"公海自己的 Chrome"(spec §3.2:**不许**按进程名裸杀) ----
# 判据(必须**同时**满足):命令行含本 profile 目录 **且** 含"调试端口"标志。
#   · 用 [regex]::Escape($profileDir) —— `D:\...\chrome-profile-gonghai` 是唯一前缀,
#     **不会**误命中 chrome-profile(自动回复)、chrome-profile-okki、chrome-profile-waimao。
#   · 再要求含 `--remote-debugging-port=` ⇒ 用户本人的普通 Chrome 窗口(没有该标志)永不入选。
#   · ⚠️ 命令行自匹配陷阱(spec §6.5):调用方的进程名是 powershell,不在 chrome.exe 集合里,天然免疫。
function Get-GonghaiChromeProcesses([string]$ProfileDir) {
    $all = @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue)
    return @($all | Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -match [regex]::Escape($ProfileDir)) -and
            ($_.CommandLine -match '--remote-debugging-port=')
        })
}

# ---- 公海页登录态探针(JS 内 btoa,避免非 ASCII 在 CDP 往返中被破坏) ----
function Get-GonghaiLoginStateJs {
    return @'
(function(){
  var ta = !!document.querySelector('textarea.send-textarea');
  var acc = !!document.querySelector('input[name=account]');
  var hasText = document.body ? ((document.body.innerText||'').trim().length > 30) : false;
  return JSON.stringify({
    hasTa: ta,
    onLogin: acc,
    hasText: hasText,
    url: location.href.substring(0,120)
  });
})()
'@
}

function Get-GonghaiAccountId {
    # 公海页当前**真正生效的**账号身份(§5-E4 要的证据)。
    # ⚠️ 实测(2026-09-27):URL 里的 `activeAccountId=` **只是 UI 参数,不代表会话身份** ——
    #    在 9225 上手工导航成 `?activeAccountId=285965039#/`,URL 变了,但
    #    `window.currentUserAccountId` 仍是 284768582。
    #    ⇒ 权威来源是页面全局量,不是 URL。
    # ⚠️ 只回传账号数字/登录名:URL 里还有 chatToken 等凭据,**不得**整串落日志。
    $js = @'
(function(){
  var g = function(k){ try { return (window[k] === undefined || window[k] === null) ? '' : String(window[k]); } catch(e){ return ''; } };
  var m = String(location.href).match(/activeAccountId=(\d+)/);
  return JSON.stringify({
    accountId: g('currentUserAccountId'),
    loginId: g('currentUserLoginId'),
    aliId: g('aliId'),
    urlAccountId: m ? m[1] : ''
  });
})()
'@
    $out = [pscustomobject]@{ accountId = ''; loginId = ''; aliId = ''; urlAccountId = '' }
    try {
        # ⚠️ 必须显式传 -UrlMatch:Invoke-GonghaiEval 的缺省值是**公海 CRM 域**
        #    (`$script:GonghaiUrlPattern`);不传就会打到 public_customer 页上 ⇒ 三个字段全空
        #    (本次执行会话实测踩到:看起来"读不到账号",其实是**读错了页**)。
        $raw = [string](Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch))
        if ($raw -match '(?s)\{.*\}') {
            $o = $Matches[0] | ConvertFrom-Json
            $out.accountId = [string]$o.accountId; $out.loginId = [string]$o.loginId
            $out.aliId = [string]$o.aliId; $out.urlAccountId = [string]$o.urlAccountId
        }
    } catch { }
    return $out
}

function Get-TabWsPort {
    # 从页对象的 webSocketDebuggerUrl 取 CDP 端口(本地小工具;刻意**不**依赖 lib\send.ps1,
    #   避免"启动脚本"与"发送模块"之间多一条不必要的耦合)。取不到返回 0。
    param($Page)
    if (-not $Page) { return 0 }
    $ws = ([string]$Page.webSocketDebuggerUrl -split '\s+')[0]
    if (-not $ws) { return 0 }
    $m = [regex]::Match($ws, '^ws://[^/]*:(\d+)/')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

# ================= 主流程 =================
Say ("=== GONGHAI-ENSURE " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " ===")

# 0. 配置 + 安全闸
$cfg = Get-GonghaiConfig
$ghPort = 0
try { $ghPort = Get-GonghaiCdpPort } catch { Exit-With 9 $_.Exception.Message }
$profileDir = $cfg.profile
if (-not $profileDir) { Exit-With 9 "GONGHAI-CONFIG-MISSING: gonghai_profile" }
$chromePath = Get-SkillPath "chrome"
if (-not $chromePath) { $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe" }
$sharedPort = Get-CdpPort
if ($ghPort -eq $sharedPort) { Exit-With 9 "REFUSE: gonghai_cdp_port=$ghPort == cdp_port=$sharedPort(自动回复的实例),拒绝操作" }
Say ("port=$ghPort profile=$profileDir (shared/monitor port=$sharedPort 一律不碰)")
Log ("start port=$ghPort profile=$profileDir")

# 1. 探测公海端口
if (-not (Test-CdpReady -Port $ghPort)) {
    if ($NoStart) { Exit-With 3 "GONGHAI-CDP-DOWN (NoStart)" }
    Say "CDP $ghPort 未就绪,启动公海自己的 Chrome"
    $targets = @(Get-GonghaiChromeProcesses -ProfileDir $profileDir)
    Say ("profile-matched chrome processes = " + $targets.Count + " pids=" + (($targets | ForEach-Object { $_.ProcessId }) -join ','))
    if ($targets.Count -eq 0) { Say "无本 profile 的残留 chrome(按 profile + 调试标志精确匹配),直接启动" }
    foreach ($t in $targets) { try { Stop-Process -Id $t.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    if ($targets.Count -gt 0) { Start-Sleep -Seconds 3 }
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    if (-not (Test-Path $chromePath)) { Exit-With 4 "GONGHAI-CHROME-MISSING: $chromePath" }
    # ⚠️ 独立 `--user-data-dir` ⇒ Chrome 会开一个**新进程**(spec §3.2-1)。
    #
    # 🔴 [GH-38 2026-09-28] **必须"脱离父进程"启动**。原实现用 `Start-Process`:
    #    Chrome 成为调用方(工具命令 / 后台作业)的**子进程**,而 Windows 作业对象会在父进程结束时
    #    **连同子进程一起回收** ⇒ 实测当晚:每次 ensure 拉起后**只能活几分钟**就在下一次工具调用/作业结束时消失,
    #    于是出现"批次认领 9 个 → 搜索时浏览器已死 → 9 个全被记成索引未同步"的连环假故障(GH-36 也是它)。
    #    改用 **WMI Win32_Process.Create**:新进程的父进程是 WmiPrvSE(系统服务),
    #    不在调用方的作业对象里 ⇒ **母进程退出后 Chrome 继续活着**。
    #    ⚠️ 参数要拼成**一条命令行字符串**,路径含空格必须加引号(WMI 不做参数数组)。
    $argList = @(
        "--remote-debugging-port=$ghPort",
        "--user-data-dir=`"$profileDir`"",
        "--no-first-run", "--no-default-browser-check",
        "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
        "about:blank"
    )
    $cmdLine = "`"$chromePath`" " + ($argList -join ' ')
    $created = $null
    try {
        $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine } -ErrorAction Stop
    } catch {
        Write-Output ("  WARN: WMI Create 失败(" + $_.Exception.Message + ") ⇒ 退回 Start-Process(可能随父进程被回收)")
    }
    if ($created -and $created.ReturnValue -eq 0) {
        Say ("已用 WMI(脱离父进程)启动 Chrome pid=" + $created.ProcessId)
    } elseif (-not $created) {
        Start-Process -FilePath $chromePath -ArgumentList $argList
        Say "已用 Start-Process 启动 Chrome(兜底路径)"
    } else {
        Exit-With 4 ("GONGHAI-CHROME-LAUNCH-FAILED rc=" + $created.ReturnValue)
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-CdpReady -Port $ghPort) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-CdpReady -Port $ghPort)) { Exit-With 3 "GONGHAI-CDP-DOWN (启动后 $TimeoutSec s 内端口 $ghPort 不可达)" }
    Say "CDP $ghPort 就绪"
    Log "CDP $ghPort ready"
    Start-Sleep -Seconds 4
} else {
    Say "CDP $ghPort 已就绪"
}

# 2. 确保公海实例上有 OneTalk 页(没有就新开一个;**只**在公海端口上)
$tab = Ensure-GonghaiOnetalkTab
if (-not $tab) { Exit-With 5 "GONGHAI-NO-ONETALK-PAGE (端口 $ghPort 上无法获得 OneTalk 页)" }
Say ("onetalk tab id=" + (([string]$tab.id -split '\s+')[0]) + " wsPort=" + (Get-TabWsPort $tab))

# 2b. 确保公海列表页也在公海实例里(否则 gonghai_probe 读列表会 NO_PAGE_MATCH)
$listPage = Get-GonghaiPage -UrlMatch $script:GonghaiPublicCustomerMatch
if (-not $listPage) {
    Say "公海列表页不在本实例,新开一个"
    try { [void](New-GonghaiPage -Url $script:GonghaiPublicCustomerUrl) } catch { Say ("公海列表页新开失败: " + $_.Exception.Message) }
    Start-Sleep -Seconds 5
    $listPage = Get-GonghaiPage -UrlMatch $script:GonghaiPublicCustomerMatch
} 
Say ("public_customer page = " + $(if ($listPage) { ([string]$listPage.id -split '\s+')[0] } else { '(none)' }))

# 3. 导航到 OneTalk(只有在"当前不是 OneTalk 页"时才导航,避免打断正在用的页)
$cur = ""
try {
    $cur = ([string](Invoke-GonghaiEvalOnPage -Page $tab -Script "(function(){return location.host + location.pathname})()")).Trim()
} catch { $cur = "" }
if ($cur -notmatch 'onetalk\.alibaba\.com') {
    Say ("当前页不在 OneTalk($cur),导航到 " + (Get-GonghaiOnetalkUrl))
    try { [void](Set-GonghaiPageUrl -Page $tab -Url (Get-GonghaiOnetalkUrl)) } catch { Exit-With 6 ("导航失败: " + $_.Exception.Message) }
    Start-Sleep -Seconds 8
} else {
    Say "当前页已在 OneTalk"
}

# 4. 登录态判定
#   ⚠️ 实测教训(2026-09-27):自动登录提交后,页面**要几十秒**才完成跳转并渲染出 textarea。
#      原来只等 10 秒就判 NEED_LOGIN ⇒ 假失败(本次执行会话就踩了这个坑,一度误以为登不上)。
#      ⇒ 改成在**登录中**状态下轮询等待(最多 $LoginWaitSec),期间不算失败、也**不重复提交**。
function Read-GonghaiLoginState {
    $s = ""
    try { $s = [string](Invoke-GonghaiEvalOnPage -Page $tab -Script (Get-GonghaiLoginStateJs)) } catch { $s = "" }
    $o = $null
    if ($s -match '(?s)\{.*\}') { try { $o = $Matches[0] | ConvertFrom-Json } catch { $o = $null } }
    return [pscustomobject]@{ raw = $s; obj = $o }
}

$st = Read-GonghaiLoginState
Say ("登录态探针 = " + ($st.raw -replace '\s+', ' '))

if ($st.obj -and $st.obj.hasTa) {
    $acc = Get-GonghaiAccountId
    $accId = $(if ($acc.accountId) { $acc.accountId } else { '(none)' })
    $accLogin = $(if ($acc.loginId) { $acc.loginId } else { '(none)' })
    $accUrl = $(if ($acc.urlAccountId) { $acc.urlAccountId } else { '(none)' })
    Say ("GONGHAI-ENSURE: OK accountId=" + $accId + " loginId=" + $accLogin + " urlAccountId=" + $accUrl + " port=$ghPort")
    Log ("OK port=$ghPort accountId=" + $accId + " loginId=" + $accLogin)
    exit 0
}

if ($st.obj -and $st.obj.onLogin) {
    if ($NoLogin) { Exit-With 2 "NEED_LOGIN(NoLogin) port=$ghPort" }
    $credFile = Get-SkillPath "creds"
    if (-not (Test-Path $credFile)) { Exit-With 2 "NEED_LOGIN(凭据文件不存在: $credFile)" }
    $acct = Get-CredentialValue 'account'
    $pwd = Get-CredentialValue 'password'
    if (-not $acct -or -not $pwd) { Exit-With 2 "NEED_LOGIN(无法解析凭据)" }
    $escA = $acct.Replace("'", "\'").Replace("\", "\\")
    $escP = $pwd.Replace("'", "\'").Replace("\", "\\")
    # ⚠️ 凭据只进 JS 表达式,**绝不**落日志/不落命令行(§4-11)。
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
  setVal(a, '__ACCT__');
  setVal(p, '__PWD__');
  var b = document.querySelector('button.sif_form-submit');
  if (b) b.click();
  return 'LOGGING_IN';
})()
"@
    $loginJs = $loginJs.Replace('__ACCT__', $escA).Replace('__PWD__', $escP)
    $r = ""
    try { $r = [string](Invoke-GonghaiEvalOnPage -Page $tab -Script $loginJs) } catch { $r = ("EVAL-ERR: " + $_.Exception.Message) }
    Say ("登录尝试 = " + $r)

    # ⚠️ 提交后**轮询等待**(跳转 + 渲染要几十秒)。等待期间**不重复提交**(避免风控)。
    $deadline = (Get-Date).AddSeconds($LoginWaitSec)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $st2 = Read-GonghaiLoginState
        Say ("  等待中: " + ($st2.raw -replace '\s+', ' '))
        if ($st2.obj -and $st2.obj.hasTa) { $ok = $true; break }
        if ($st2.obj -and -not $st2.obj.onLogin -and -not $st2.obj.hasTa) {
            # 既不在登录页、也没有输入框 ⇒ 可能在"选账号/验证"中间页,继续等(不重试提交)
            continue
        }
    }
    if ($ok) {
        $acc2 = Get-GonghaiAccountId
        $a2id = $(if ($acc2.accountId) { $acc2.accountId } else { '(none)' })
        $a2login = $(if ($acc2.loginId) { $acc2.loginId } else { '(none)' })
        $a2url = $(if ($acc2.urlAccountId) { $acc2.urlAccountId } else { '(none)' })
        Say ("GONGHAI-ENSURE: OK(autologin) accountId=" + $a2id + " loginId=" + $a2login + " urlAccountId=" + $a2url + " port=$ghPort")
        Log ("OK(autologin) port=$ghPort accountId=" + $a2id + " loginId=" + $a2login)
        exit 0
    }
    Exit-With 2 "NEED_LOGIN(自动登录后等待 $LoginWaitSec s 仍无 textarea.send-textarea;需人工确认验证码/短信/选账号页) port=$ghPort"
}

Exit-With 5 ("UNKNOWN(端口 $ghPort 页面状态无法判定) raw=" + ($st.raw -replace '\s+', ' '))
