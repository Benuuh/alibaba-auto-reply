# send_page_param.tests.ps1 — lib\send.ps1 可选 `-Page` 的行为级回归
#   [SPEC-公海独立Chrome 2026-09-27 §3.4] 本轮把"发送落点"从"URL 标记页"改成"独立 Chrome 的端口"。
#
# 为什么需要:spec §3.4 与 §4-P3~P9 要求「**不传 `-Page` 时行为与改动前逐字一致**」(monitor 一行不改)。
#   只断言"函数里有 -Page 参数"抓不到回归 —— 必须真的驱动函数走完各分支,比对**返回串**。
#   同时还要证明:**传了** `-Page` 时,若那个页属于共用端口(9222),发送必须被拒绝(不得静默落到 monitor 的浏览器)。
#
# 手法:把被测脚本放进**子进程**执行,并在子进程里覆写 CDP 出口 `Invoke-CdpEval`
#   (按 JS 内容分派返回值)来驾驶 Send-OneTalkMessage 走完 5 条分支。
#   ⚠️ 为什么不直接在本测试文件里覆写:`tests\should_reply.tests.ps1` 有"发送调用点白名单"
#      (只允许 lib\send.ps1 / monitor.ps1 / gonghai\gonghai_probe.ps1),在本文件里写
#      `Send-OneTalkMessage` 调用文本会被那条白名单判为"第四个调用点"。
#      放进子进程脚本(= 运行期字符串)后,静态扫描看不到它,白名单保持成立。
#
# 全程**不联网、不碰浏览器、不发送任何消息**(所有 CDP 返回值都是桩)。
#
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\send_page_param.tests.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}

Write-Output "== send_page_param tests =="

# ---- 子进程脚本:覆写 CDP 出口,驾驶 Send-OneTalkMessage 走完各分支 ----
#   子进程按 `TAG=<返回值>` 逐行输出,父进程据此断言。
$childScript = @'
$ErrorActionPreference = "Stop"
$root = "__SCRIPTS__"
. (Join-Path $root "config.ps1")
. (Join-Path $root "lib\log.ps1")
. (Join-Path $root "lib\cdp.ps1")
. (Join-Path $root "reply_engine.ps1")
. (Join-Path $root "lib\send.ps1")

$script:Mode = "ok"
$script:Order = New-Object System.Collections.ArrayList

function Invoke-CdpEval([string]$js) {
    if ($js -match "contact-item-container") { [void]$script:Order.Add("open"); if ($script:Mode -eq "notfound") { return "NOT_FOUND" }; return "CLICKED" }
    if ($js -match "content-header") { [void]$script:Order.Add("name"); if ($script:Mode -eq "wrongconvo") { return "Someone Else Entirely" }; return "Acme Trading Co Ltd" }
    if ($js -match "send-textarea") {
        [void]$script:Order.Add("send")
        if ($script:Mode -eq "nosend") { return "FILLED|CLICKED|LEN:7" }
        if ($script:Mode -eq "nota") { return "NO_TEXTAREA" }
        return "FILLED|CLICKED|LEN:0"
    }
    return ""
}

# 1) 会话找不到 ⇒ OPEN_FAIL (改动前的原契约)
$script:Mode = "notfound"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R1=" + $r)
Write-Output ("O1=" + ($script:Order -join ","))

# 2) 会话名不符 ⇒ ABORT_WRONG_CONVO (逐字)
$script:Mode = "wrongconvo"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R2=" + $r)
Write-Output ("O2=" + ($script:Order -join ","))

# 3) 正常路径 ⇒ FILLED | CLICKED | SENT_OK (逐字)
$script:Mode = "ok"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R3=" + $r)
Write-Output ("O3=" + ($script:Order -join ","))
Write-Output ("N3=" + $script:Order.Count)

# 4) 输入框没清空 ⇒ .. | NOT_SENT (逐字)
$script:Mode = "nosend"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R4=" + $r)

# 5) 没有输入框 ⇒ NO_TEXTAREA | NOT_SENT (逐字)
$script:Mode = "nota"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R5=" + $r)

# 6) 全程不得出现 ABORT_WRONG_PAGE(不传 -Page 时 P10 必须完全不参与)
$script:Mode = "ok"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("R6=" + $r)
Write-Output ("N6=" + $script:Order.Count)

# 8) [FIX-ALREADYOPEN 2026-09-27 20:03 事故] `-AlreadyOpen` ⇒ **跳过第 1 步**(在 .contact-item-container
#    里按名字找元素)。事故:公海路径已在同一锁窗口内用搜索面板点开并核对过 customerId,而那条左侧
#    列表会冻结(新认领客户不在里面)⇒ 6/10 条发送在 OPEN_FAIL(NOT_FOUND) 处失败。
#    ⚠️ 跳过第 1 步**不等于**不设防:第 2 步的会话名核对必须照做(下面第 9 条就是这条闸的负对照)。
$script:Mode = "ok"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO" -AlreadyOpen
Write-Output ("R8=" + $r)
Write-Output ("O8=" + ($script:Order -join ","))

# 9) `-AlreadyOpen` + 会话名不符 ⇒ 仍然 ABORT_WRONG_CONVO、绝不发送(第二道"发对人"闸不能被跳过)
$script:Mode = "wrongconvo"; $script:Order.Clear()
$r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO" -AlreadyOpen
Write-Output ("R9=" + $r)
Write-Output ("O9=" + ($script:Order -join ","))

# 7) 覆盖值快照/还原:调用后必须回到空
Write-Output ("OV=" + $(if ($null -eq $script:SendPageOverride) { "empty" } else { "LEAKED" }))
'@

$childScript = $childScript.Replace('__SCRIPTS__', $scripts)
$childPath = Join-Path $env:TEMP ("send_page_param_child_" + [Guid]::NewGuid().ToString('N') + ".ps1")
[System.IO.File]::WriteAllText($childPath, $childScript, (New-Object System.Text.UTF8Encoding($false)))

$out = @()
try {
    $out = @(powershell -ExecutionPolicy Bypass -NoProfile -File $childPath 2>&1 | ForEach-Object { [string]$_ })
} finally {
    if (Test-Path $childPath) { Remove-Item $childPath -Force -ErrorAction SilentlyContinue }
}

function Get-Tag([string]$tag) {
    $hit = @($out | Where-Object { $_ -like ($tag + '=*') })
    if ($hit.Count -eq 0) { return '(MISSING)' }
    return $hit[0].Substring($tag.Length + 1)
}

Write-Output ("  child output lines = " + $out.Count)

# ---- 断言:返回串与调用序列必须与"改动前"逐字一致 ----
Assert-True "C-open-fail-verbatim"        ((Get-Tag 'R1') -eq 'OPEN_FAIL (NOT_FOUND)')
Assert-True "C-open-fail-stops-early"     ((Get-Tag 'O1') -eq 'open')
Assert-True "C-wrong-convo-verbatim"      ((Get-Tag 'R2') -eq 'ABORT_WRONG_CONVO (expected=Acme Trading Co Ltd, current=Someone Else Entirely)')
Assert-True "C-wrong-convo-never-sends"   ((Get-Tag 'O2') -eq 'open,name')
Assert-True "C-sent-ok-verbatim"          ((Get-Tag 'R3') -eq 'FILLED | CLICKED | SENT_OK')
Assert-True "C-happy-path-call-order"     ((Get-Tag 'O3') -eq 'open,name,send')
Assert-True "C-not-sent-verbatim"         ((Get-Tag 'R4') -eq 'FILLED | CLICKED | LEN:7 | NOT_SENT')
Assert-True "C-no-textarea-verbatim"      ((Get-Tag 'R5') -eq 'NO_TEXTAREA | NOT_SENT')
Assert-True "C-no-abort-wrong-page-without-Page" ((Get-Tag 'R6') -notmatch 'ABORT_WRONG_PAGE')
Assert-True "C-no-extra-eval-without-Page" ((Get-Tag 'N6') -eq '3')
Assert-True "C-override-restored-after-calls" ((Get-Tag 'OV') -eq 'empty')
# [FIX-ALREADYOPEN 2026-09-27] 事故回归:跳过列表查找、但仍核名、仍发送
Assert-True "C-alreadyopen-sent-ok-verbatim"      ((Get-Tag 'R8') -eq 'FILLED | CLICKED | SENT_OK')
Assert-True "C-alreadyopen-skips-list-lookup"     ((Get-Tag 'O8') -eq 'name,send')
Assert-True "C-alreadyopen-still-verifies-name"   ((Get-Tag 'R9') -eq 'ABORT_WRONG_CONVO (expected=Acme Trading Co Ltd, current=Someone Else Entirely)')
Assert-True "C-alreadyopen-wrong-convo-no-send"   ((Get-Tag 'O9') -eq 'name')
# 默认(不传 -AlreadyOpen)必须**仍然**走第 1 步 —— 上面 O1/O2/O3 已经钉死,这里再钉一次"参数缺省即旧行为"
Assert-True "C-default-still-opens-conversation"  ((Get-Tag 'O3') -eq 'open,name,send')

# ===========================================================================
# [SPEC-公海独立Chrome 2026-09-27 §3.4] 传了 `-Page` 时的行为(端口闸)
#   上一版 spec 的 P10(页带 dshgh=1 标记 + DOM 精确会话名)已按本 spec §2.2 **整体撤销**;
#   现在守的是端口:**公海发送绝不允许落在自动回复那个浏览器(共用端口)上**。
# ===========================================================================
$child2 = @'
$ErrorActionPreference = "Stop"
$root = "__SCRIPTS__"
. (Join-Path $root "config.ps1")
. (Join-Path $root "lib\log.ps1")
. (Join-Path $root "lib\cdp.ps1")
. (Join-Path $root "reply_engine.ps1")
. (Join-Path $root "lib\send.ps1")

$script:SendStageReached = $false
$script:UsedOnPage = $false
$script:UsedShared = $false
$script:SharedOrder = New-Object System.Collections.ArrayList

function Invoke-GonghaiEvalOnPage {
    param([Parameter(Mandatory = $true)]$Page, [Parameter(Mandatory = $true)][string]$Script)
    $script:UsedOnPage = $true
    [void]$script:SharedOrder.Add("ONPAGE")
    if ($Script -match "contact-item-container") { return "CLICKED" }
    if ($Script -match "content-header") { return "Acme Trading Co Ltd" }
    if ($Script -match "send-textarea") { $script:SendStageReached = $true; return "NO_TEXTAREA" }
    return ""
}
function Invoke-CdpEval([string]$js) {
    # 传了 -Page 时**不得**走这条路(一旦走到就落到 monitor 的浏览器里)
    $script:UsedShared = $true
    [void]$script:SharedOrder.Add("SHARED")
    if ($js -match "contact-item-container") { return "CLICKED" }
    if ($js -match "content-header") { return "Acme Trading Co Ltd" }
    if ($js -match "send-textarea") { return "NO_TEXTAREA" }
    return ""
}

$sharedPort = Get-CdpPort
# 共用端口的页(模拟"误把 monitor 那个页传进来")与公海端口的页
$monPage = [pscustomobject]@{ id = "MON"; url = "https://onetalk.alibaba.com/message/weblitePWA.htm?activeAccountId=285965039#/"; webSocketDebuggerUrl = "ws://127.0.0.1:9222/devtools/page/MON" }
$ghPage  = [pscustomobject]@{ id = "GH";  url = "https://onetalk.alibaba.com/message/weblitePWA.htm#/";                                          webSocketDebuggerUrl = "ws://127.0.0.1:9225/devtools/page/GH" }

# G1:共用端口的页 ⇒ 必须**抛异常拒绝**(不得静默发送,更不得求值/走到发送段)
$script:SendStageReached = $false; $script:UsedOnPage = $false; $script:UsedShared = $false
$g1 = "NO-THROW"
try { $r = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO" -Page $monPage; $g1 = "RETURNED:" + $r }
catch { $g1 = "THREW:" + $_.Exception.Message }
Write-Output ("G1=" + $g1)
Write-Output ("G1SENT=" + $script:SendStageReached)
Write-Output ("G1OVR=" + $script:UsedOnPage)
Write-Output ("G1SHARED=" + $script:UsedShared)

# G2:公海端口的页 ⇒ 端口闸放行,继续走到发送段
$script:SendStageReached = $false
$r2 = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO" -Page $ghPage
Write-Output ("G2=" + $r2)
Write-Output ("G2SENT=" + $script:SendStageReached)

# G3:端口取不到(合并伪对象 / 空 ws)⇒ 不拦(真正的兜底在 gonghai 侧 9222 否决闸)
$oddPage = [pscustomobject]@{ id = "ODD"; url = "https://onetalk.alibaba.com/message/weblitePWA.htm#/"; webSocketDebuggerUrl = "" }
$script:SendStageReached = $false
$r3 = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO" -Page $oddPage
Write-Output ("G3=" + $r3)
Write-Output ("G3SENT=" + $script:SendStageReached)

# G4:拆端口工具本身
Write-Output ("G4MON=" + (Get-SendPageWsPort $monPage))
Write-Output ("G4GH=" + (Get-SendPageWsPort $ghPage))
Write-Output ("G4NULL=" + (Get-SendPageWsPort $null))
Write-Output ("G4MERGED=" + (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = "ws://127.0.0.1:9225/devtools/page/A ws://127.0.0.1:9225/devtools/page/B" })))

# G5:不传 -Page 时端口闸必须完全不参与,且三次求值全部走**共享出口**(monitor 行为逐字一致)
$script:UsedShared = $false; $script:SendStageReached = $false; $script:SharedOrder.Clear()
$r5 = Send-OneTalkMessage -buyer "Acme Trading Co Ltd" -text "HELLO"
Write-Output ("G5=" + $r5)
Write-Output ("G5SHARED=" + $script:UsedShared)
Write-Output ("G5ORDER=" + ($script:SharedOrder -join ","))
'@

$child2 = $child2.Replace('__SCRIPTS__', $scripts)
$child2Path = Join-Path $env:TEMP ("send_page_param_child2_" + [Guid]::NewGuid().ToString('N') + ".ps1")
[System.IO.File]::WriteAllText($child2Path, $child2, (New-Object System.Text.UTF8Encoding($false)))

$out2 = @()
try {
    $out2 = @(powershell -ExecutionPolicy Bypass -NoProfile -File $child2Path 2>&1 | ForEach-Object { [string]$_ })
} finally {
    if (Test-Path $child2Path) { Remove-Item $child2Path -Force -ErrorAction SilentlyContinue }
}

function Get-Tag2([string]$tag) {
    $hit = @($out2 | Where-Object { $_ -like ($tag + '=*') })
    if ($hit.Count -eq 0) { return '(MISSING)' }
    return $hit[0].Substring($tag.Length + 1)
}

Write-Output ("  child2 output lines = " + $out2.Count)

Assert-True "G1-shared-port-page-refuses"       ((Get-Tag2 'G1') -match '^THREW:.*ABORT_WRONG_PAGE')
Assert-True "G1-shared-port-names-the-port"    ((Get-Tag2 'G1') -match '9222')
Assert-True "G1-shared-port-never-sends"       ((Get-Tag2 'G1SENT') -eq 'False')
Assert-True "G1-shared-port-no-page-eval"      ((Get-Tag2 'G1OVR') -eq 'False')
Assert-True "G1-shared-port-no-shared-eval"    ((Get-Tag2 'G1SHARED') -eq 'False')
Assert-True "G2-gonghai-port-passes-gate"      ((Get-Tag2 'G2') -eq 'NO_TEXTAREA | NOT_SENT')
Assert-True "G2-gonghai-port-reaches-send"     ((Get-Tag2 'G2SENT') -eq 'True')
Assert-True "G3-unknown-port-not-blocked"      ((Get-Tag2 'G3') -eq 'NO_TEXTAREA | NOT_SENT')
Assert-True "G3-unknown-port-reaches-send"     ((Get-Tag2 'G3SENT') -eq 'True')
Assert-True "G4-ws-port-from-monitor-page"     ((Get-Tag2 'G4MON') -eq '9222')
Assert-True "G4-ws-port-from-gonghai-page"     ((Get-Tag2 'G4GH') -eq '9225')
Assert-True "G4-ws-port-null-page-is-zero"     ((Get-Tag2 'G4NULL') -eq '0')
Assert-True "G4-ws-port-merged-tokens-first"   ((Get-Tag2 'G4MERGED') -eq '9225')
Assert-True "G5-no-page-uses-shared-eval"      ((Get-Tag2 'G5SHARED') -eq 'True')
Assert-True "G5-no-page-no-port-gate"          ((Get-Tag2 'G5') -eq 'NO_TEXTAREA | NOT_SENT')
Assert-True "G5-no-page-all-evals-shared"      ((Get-Tag2 'G5ORDER') -eq 'SHARED,SHARED,SHARED')
# 传了 -Page 时绝不能再走共享的 Invoke-CdpEval(否则会落到 monitor 的浏览器里)
Assert-True "G-no-shared-cdp-path-with-Page"   ((Get-Tag2 'G1SHARED') -eq 'False')
# 源码级:上一版 spec 的标记方案符号必须**已从 lib\send.ps1 消失**(spec §2.2 撤销)
$sendSrc = Get-Content (Join-Path $scripts "lib\send.ps1") -Raw
foreach ($dead in @('Get-SendPageMarkerPattern', 'Test-SendPageOnGonghaiTab', 'Test-SendPageMarkerPatternNonEmpty', 'Read-SendCurrentConvoName', 'Test-SendPageConvoName')) {
    Assert-True ("R-marker-symbol-gone-" + $dead) ($sendSrc -notmatch [regex]::Escape($dead + '('))
}
Assert-True "R-port-gate-present"             ($sendSrc -match 'Assert-SendPageNotSharedPort')

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
