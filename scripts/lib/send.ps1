# lib/send.ps1 - OneTalk 消息发送统一实现:打开会话 + 身份校验 + 原生 setter 填值 + 发送按钮 + 输入框清空校验。
# 返回格式(monitor/nudge 兼容): "OPEN_FAIL (..)" / "ABORT_WRONG_CONVO (expected=.., current=..)" / "NO_TEXTAREA" / "FILLED | CLICKED | SENT_OK" / ".. | NOT_SENT"
# 依赖: config.ps1, lib\cdp.ps1(Invoke-CdpEval), reply_engine.ps1(Get-StateKey)
#
# [SPEC-公海独立Chrome 2026-09-27 §3.4] 可选 `-Page`(公海发送落点)
#   现状:`Send-OneTalkMessage` 内部全部走 `Invoke-CdpEval` ⇒ 用的是 `Get-Page` = 9222 上的 OneTalk 页。
#   后果:公海就算用独立 Chrome 读页了,**发送仍会落到 monitor 的浏览器里** —— 白做。
#   改法:①可选参数 `-Page`(默认 $null = **现状行为**);
#         ②内部 JS 执行改走 Invoke-SendEval(传了页就在该页上求值,否则原样走 Invoke-CdpEval);
#         ③传了 `-Page` 时加一道**端口闸**:该页的 CDP 端点端口不得是自动回复的端口(9222/共用端口)。
#   ⚠️ 硬约束(spec §3.4 / §4-P3~P9):**不传 `-Page` 时行为必须与改动前逐字一致** —— monitor 一行不改。
#      因此新增的端口闸**只**在 `-Page` 非空时生效。
#   ⚠️ [SPEC-公海页面隔离 2026-09-27] 那套"页必须带 dshgh=1 标记 + DOM 精确会话名"的 P10 双重校验
#      已按本 spec §2.2 **整体删除**:独立 Chrome 之后不需要标记,页级风险由**端口隔离**消除。

# ---- [SPEC-公海独立Chrome §3.4] 本次发送所用的页面覆写(仅公海侧会赋值) ----
$script:SendPageOverride = $null

function Get-SendPageWsPort {
    # 从页对象的 webSocketDebuggerUrl 里取出 CDP 端口(ws://127.0.0.1:<port>/devtools/page/<id>)。
    # 取不到返回 0(= 无法判定)。
    #   ⚠️ 瞬态 CDP 故障会把多个 ws:// 用空格拼接 ⇒ 只取第一个记号(与 Connect-Page 同款兜底)。
    param($Page)
    if (-not $Page) { return 0 }
    $ws = ([string]$Page.webSocketDebuggerUrl -split '\s+')[0]
    if (-not $ws) { return 0 }
    $m = [regex]::Match($ws, '^ws://[^/]*:(\d+)/')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}

function Assert-SendPageNotSharedPort {
    # [SPEC-公海独立Chrome §3.4 / §4-P2] 公海发送**绝不允许**落在自动回复那个浏览器上。
    #   判据:页的 ws 端点端口存在(>0)且等于 config 的 `cdp_port`(= 自动回复端口)⇒ 抛异常。
    #   ⚠️ "失败即拒绝"的方向:**端口取不到**(0)时**不**拦 —— 那种情况无法证明它落在 9222 上,
    #      而真正的兜底是 gonghai 侧每个 CDP 出口的 9222 否决闸(gonghai_cdp.ps1)。
    #      这里只拦"能证明是共用的那一半",避免把正常的公海页误杀。
    param($Page)
    $wsPort = Get-SendPageWsPort $Page
    if ($wsPort -le 0) { return }
    $shared = Get-CdpPort
    if ($wsPort -eq $shared) {
        $msg = "ABORT_WRONG_PAGE (页的 CDP 端口 $wsPort == 自动回复端口 $shared;公海发送必须落在自己的 Chrome 上)"
        throw $msg
    }
}

function Invoke-SendEval([string]$Js) {
    if($script:AarSendEvalAdapter){return (& $script:AarSendEvalAdapter $Js $script:SendPageOverride)}
    if(-not(Get-Command Assert-AarSendAllowed -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'paths.ps1')}
    Assert-AarSendAllowed 'real page send/evaluation'
    # [SPEC §3.4-2] 内部 JS 执行出口:**不传 `-Page` 时与改动前逐字一致**(直接 Invoke-CdpEval)。
    if ($script:SendPageOverride) {
        return (Invoke-GonghaiEvalOnPage -Page $script:SendPageOverride -Script $Js)
    }
    return (Invoke-CdpEval $Js)
}
function Set-SendEvaluationAdapter([scriptblock]$Adapter){$script:AarSendEvalAdapter=$Adapter}

function Send-OneTalkMessage([string]$buyer, [string]$text, $Page = $null, [switch]$AlreadyOpen) {
    # [SPEC §3.4] `-Page` 非空 ⇒ 本次发送落在该页上(公海自己的 Chrome)。
    #   ⚠️ 只影响本次调用:进入时快照旧值,退出时还原(避免污染 monitor 的同进程调用)。
    # [FIX-ALREADYOPEN 2026-09-27 20:03 事故] `-AlreadyOpen` = "这条会话**已经打开并核对过身份了**"。
    #   公海路径在**同一个写锁窗口内**先用搜索面板点开结果、再用详情卡 customerId 与公海 data-row-key
    #   精确比对 ⇒ 第 1 步"在会话列表里按名字找元素再点一次"既冗余又脆弱:
    #   实测那条 `.contact-item-container` 列表会**冻结**(不再包含新认领的客户),
    #   于是 6/10 条发送在 `OPEN_FAIL (NOT_FOUND)` 处失败 —— 明明人已经开在对的面板里、cardId 也已核对通过。
    #   ⚠️ 硬约束:`-AlreadyOpen` **只**跳过第 1 步;**第 2 步的会话名核对照做**(第二道"发对人"闸不能省)。
    #   ⚠️ 不传这个开关时行为与改动前**逐字一致** ⇒ monitor 一行不改(与 `-Page` 同款纪律)。
    $prevPage = $script:SendPageOverride
    if ($Page) { $script:SendPageOverride = $Page } else { $script:SendPageOverride = $null }
    try {
        return (Send-OneTalkMessageCore -buyer $buyer -text $text -Page $Page -AlreadyOpen:$AlreadyOpen)
    } finally {
        $script:SendPageOverride = $prevPage
    }
}

function Send-OneTalkMessageCore([string]$buyer, [string]$text, $Page = $null, [switch]$AlreadyOpen) {
    # [2026-10-05 spec §6.3] Isolation enforcement lives at the REAL page egress (lib\cdp.ps1):
    # under an isolated runtime root every page evaluation throws ISOLATION-VIOLATION, so a real send
    # can never complete. A white-box test that replaces that egress with a simulated adapter is
    # exactly the "模拟适配器" the spec allows, and is therefore not blocked here.
    # Accio 网关发送（灰度开关 accio_send_enabled 默认关；失败自动回退 CDP；仅 Phase 4 验证后开启）
    try {
        if ((Get-Command Send-AccioMessage -ErrorAction SilentlyContinue) -and (Get-Command Get-SkillConfig -ErrorAction SilentlyContinue)) {
            $__cfg = Get-SkillConfig
            if ($__cfg -and ($__cfg.PSObject.Properties.Name -contains 'accio_send_enabled') -and $__cfg.accio_send_enabled) {
                $__map = Get-AccioConversationMap
                $__nk = Get-AccioNameKey $buyer
                if ($__map -and $__nk -and $__map.ContainsKey($__nk)) {
                    $__e = $__map[$__nk]
                    if ($__e.selfAliId) {
                        $__res = Send-AccioMessage -ConversationId $__e.conversationId -BuyerAliId ([long]$__e.contactAliId) -SelfAliId ([long]$__e.selfAliId) -Text $text
                        if ($__res) {
                            Write-AccioLog "ACCIO-SEND src=gateway buyer=$buyer"
                            return "ACCIO-SENT | SENT_OK"
                        }
                        Write-AccioLog "ACCIO-SEND src=cdp buyer=$buyer (gateway failed)"
                    }
                } else {
                    Write-AccioLog "ACCIO-SEND src=cdp buyer=$buyer (not in gateway map)"
                }
            }
        }
    } catch {
        if (Get-Command Write-AccioLog -ErrorAction SilentlyContinue) { Write-AccioLog "ACCIO-SEND-ERR: $($_.Exception.Message)" }
    }
    # ================= [SPEC §3.4-3] 发送落点端口闸(**仅**在传了 -Page 时启用) =================
    # 本次真正要防的是"这条消息会不会发到自动回复那个浏览器里"(spec §3.4:不改这里就是白做)。
    # 判据:发送所用页的 CDP 端点端口必须是公海自己的端口,**不得**等于 config 的 cdp_port(=9222)。
    # 不满足 ⇒ **立刻**抛异常(由调用方按 ABORT_WRONG_PAGE 处理:不发送、记日志、清锁)。
    # ⚠️ 位置必须在**任何**页面求值之前:否则会先点开一个会话、再发现页不对 ——
    #    "在别人的浏览器上点会话"本身就是不该发生的副作用(spec §1.3 的事故形态)。
    # ⚠️ 不传 `-Page` 时**整块跳过** ⇒ monitor 的行为与改动前逐字一致(spec §3.4 / §4-P3~P9)。
    if ($Page) { Assert-SendPageNotSharedPort $Page }

    # 1) 打开会话(按买家名匹配列表项)
    #    [FIX-ALREADYOPEN 2026-09-27] `-AlreadyOpen` ⇒ 整块跳过(人已经开在面板里,且 cardId 已核对)。
    #      为什么不能"找不到就继续":**找不到就继续**会把"当前开着的会话是谁"变成未验证状态 ——
    #      所以这里不改成回退,而是由调用方**显式声明**"已开且已核对",两种语义分得清清楚楚。
    if (-not $AlreadyOpen) {
    $esc = $buyer.Replace("\","\\").Replace("'","\'").Replace('"','\"')
    $js1 = @"
(function(){
  var el = Array.from(document.querySelectorAll('.contact-item-container')).find(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var nameTxt = (nameEl && nameEl.innerText) || '';
    var full = (e.innerText || '') + '|' + nameTxt;
    return full.indexOf('$esc') >= 0;
  });
  if (!el) return 'NOT_FOUND';
  el.click();
  return 'CLICKED';
})()
"@
    $r1 = Invoke-SendEval $js1
    if ($r1 -notmatch 'CLICKED') { return "OPEN_FAIL ($r1)" }
    Start-Sleep -Seconds 3
    }   # ← /if (-not $AlreadyOpen)

    # 2) 身份校验:当前会话名必须与目标一致(防串台/防错发;排除客户详情卡片)
    $jsName = @"
(function(){
  var cands = [];
  var hdr = document.querySelector('.content-header');
  if (hdr) {
    var t = (hdr.innerText || '').trim().split('\n')[0].trim();
    if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
  }
  Array.from(document.querySelectorAll('[class*=header] [class*=name], [class*=Title], h1,h2,h3,[class*=contact-name]')).forEach(function(e){
    if (e.closest && e.closest('.alicrm-customer-detail-card')) return;
    var t = (e.innerText || '').trim();
    if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
  });
  if (!cands.length) return '';
  var best = cands[0];
  cands.forEach(function(c){ if (c.length > best.length) best = c; });
  return best.split('\n')[0].trim();
})()
"@
    $current = (Invoke-SendEval $jsName).Trim()
    $key = Get-StateKey $buyer
    $curKey = Get-StateKey $current
    # [GH-50 2026-09-28] **比较前必须归一化**：实测 `expected=Brian Casco, current=Brian Casco`
    #   字面一模一样却判 `ABORT_WRONG_CONVO` —— 根因是网页里带**不可见字符**
    #   （零宽空格 U+200B / 方向控制 U+202A-202E / BOM U+FEFF 等，日志里看不出来），
    #   或空白/大小写差异 ⇒ 朴素的 `IndexOf` 直接判不等，把**自己人**挡在门外
    #   （该客户 customerId 强判据已经通过，说明就是他）。
    #   归一化规则:去掉零宽/方向控制/BOM → 折叠空白 → 首尾去空 → 转小写。
    #   ⚠️ 强判据(customerId 相等,由公海发送窗口负责)不变;这里只是把"同名判定"做得不被不可见字符欺骗。
    $nB = (([string]$buyer) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', '' -replace '\s+', ' ').Trim().ToLowerInvariant()
    $nC = (([string]$current) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', '' -replace '\s+', ' ').Trim().ToLowerInvariant()
    $match = ($curKey -and $curKey -eq $key) -or
             ($nB -and $nC -and ($nC -eq $nB -or $nC.Contains($nB) -or $nB.Contains($nC)))
    #   ⚠️ 返回串必须**逐字保持** `ABORT_WRONG_CONVO (expected=.., current=..)` ——
    #     测试 `send_page_param.tests.ps1` 的 C-wrong-convo-verbatim / C-alreadyopen-still-verifies-name
    #     把这条格式钉成契约（monitor/nudge 兼容）。归一化诊断**不进返回串**。
    if (-not $match) { return "ABORT_WRONG_CONVO (expected=$buyer, current=$current)" }

    # 3) 填值(React 受控组件必须原生 setter + input 事件)
    $esc2 = $text.Replace("\","\\").Replace("'","\'").Replace("`n","\n").Replace("`r","\r")
    # 3+4+5) 合并:填值 + 点击发送 + 输入框清空校验 一次 eval(JS 内等待,P2.1a)
    $js2 = @"
(async function(){
  var ta = document.querySelector('textarea.send-textarea');
  if (!ta) return 'NO_TEXTAREA';
  var setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
  setter.call(ta, '$esc2');
  ta.dispatchEvent(new Event('input', {bubbles:true}));
  await new Promise(function(r){ setTimeout(r, 1000); });
  var btns = Array.from(document.querySelectorAll('button')).filter(function(b){ return (b.innerText||'').trim() === '发送'; });
  if (!btns.length) return 'FILLED|NO_BTN';
  btns[0].click();
  await new Promise(function(r){ setTimeout(r, 2000); });
  var ta2 = document.querySelector('textarea.send-textarea');
  return ta2 ? ('FILLED|CLICKED|LEN:' + ta2.value.length) : 'FILLED|CLICKED|NO_TA';
})()
"@
    $r2 = Invoke-SendEval $js2
    if ($r2 -match 'LEN:0') { return "FILLED | CLICKED | SENT_OK" }
    return ($r2 -replace '\|',' | ') + " | NOT_SENT"
}

# =============================================================================================
# [2026-10-05 spec §5-3/§5-4] 发送结果的结构化返回与发送后核对
#
# 为什么需要：输入框清空只证明"页面动作的一个阶段"完成（spec §5-3）。真正的发送结果必须再核对
#   会话里出现了新的我方消息；核对不到时结果是**未知**，先对账再决定是否重试，绝不直接当失败补发。
# 兼容：Send-OneTalkMessage 的返回串一个字都不改（monitor/nudge/公海与既有测试依赖它）；
#   需要结构化结果的新调用方使用 Send-OneTalkMessageEx。
# =============================================================================================

# 纯函数：把"刚发送的文本"与"页面读到的最新消息文本"做归一化比较。
# 归一化只处理不可见字符/空白/大小写；页面可能把长文本截断或拼接译文，因此再允许前缀比较。
function Test-TextMatchesSent([string]$Expected, [string]$Actual) {
    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) { return $false }
    $e = ([string]$Expected) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
    $a = ([string]$Actual) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
    $e = ($e -replace '\s+', ' ').Trim().ToLowerInvariant()
    $a = ($a -replace '\s+', ' ').Trim().ToLowerInvariant()
    if (-not $e -or -not $a) { return $false }
    if ($a -eq $e) { return $true }
    return $false
}

function Get-OutboundConfirmScript {
    return @"
(function(){
  var rows = Array.from(document.querySelectorAll('[class*=message-item-wrapper]'));
  if (!rows.length) return JSON.stringify({rows:0, lastIsMine:false, lastText:''});
  var last = rows[rows.length-1];
  var rich = last.querySelector('.session-rich-content.text')
          || last.querySelector('.content-with-translation .session-rich-content')
          || last.querySelector('.content-with-translation.text-content');
  var t = rich ? (rich.innerText||'').replace(/\n+/g,' ').trim() : '';
  var nameEl = last.querySelector('.item-base-info .name');
  var cls = (last.className||'').toString();
  var isBuyer = !!(nameEl && nameEl.innerText.trim()) || cls.indexOf('item-left') >= 0;
  return JSON.stringify({rows: rows.length, lastIsMine: !isBuyer, lastText: t.substring(0,400)});
})()
"@
}

# 页面核对：最新一条消息必须是我方且内容与刚发送的文本一致。
# 返回 @{ Status = 'confirmed' | 'absent' | 'unverified'; Evidence; Detail }
function Confirm-OneTalkOutboundMessage([string]$buyer,[string]$text,$Before=$null) {
    $r=[pscustomobject]@{Status='unverified';Evidence='';Detail='before-snapshot-required';Receipt=$null}
    if($null -eq $Before){return $r}
    try{$after=@(Get-OutboundSnapshot);$receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before $Before -After $after;$r.Receipt=$receipt
        if($receipt.Valid){$r.Status='confirmed';$r.Evidence=$receipt.ConfirmationType;$r.Detail='unique-exact-new-outbound-event'}else{$r.Detail=$receipt.Error}
    }catch{$r.Detail=$_.Exception.Message};return $r
}

# 结构化发送：Status = SENT_OK（已核对）| UNKNOWN（页面动作完成但核对不到，需对账）| FAILED。
function Send-OneTalkMessageEx {
    param(
        [Parameter(Mandatory = $true)][string]$buyer,
        [Parameter(Mandatory = $true)][string]$text,
        $Page = $null,
        [switch]$AlreadyOpen,
        # 页面核对需要真实页面读取；模拟适配器可显式跳过，此时状态降级为 UNKNOWN（不得当作已确认）。
        [switch]$SkipConfirmation
    )
    $oldPage=$script:SendPageOverride
    if($Page){Assert-SendPageNotSharedPort $Page;$script:SendPageOverride=$Page}
    try {
    $before=$null
    try{$before=@(Get-OutboundSnapshot)}catch{}
    $raw = Send-OneTalkMessage -buyer $buyer -text $text -Page $Page -AlreadyOpen:$AlreadyOpen
    $res = [pscustomobject]@{
        Status = 'FAILED'; Raw = [string]$raw; Buyer = $buyer; Text = $text
        Confirmed = $false; ConfirmEvidence = ''; Detail = ''; Receipt=$null; BeforeSnapshot=$before
    }
    if ($raw -match 'ABORT_WRONG_CONVO') { $res.Detail = 'wrong-conversation'; return $res }
    if ($raw -match 'SENT_OK') {
        if ($SkipConfirmation) {
            $res.Status = 'UNKNOWN'; $res.ConfirmEvidence = 'confirmation-skipped'
            $res.Detail = 'page-action-only'
            return $res
        }
        $c = Confirm-OneTalkOutboundMessage -buyer $buyer -text $text -Before $before
        $res.ConfirmEvidence = $c.Evidence
        $res.Receipt=$c.Receipt
        if ($c.Status -eq 'confirmed') {
            $res.Status = 'SENT_OK'; $res.Confirmed = $true; $res.Detail = $c.Detail
        } else {
            $res.Status = 'UNKNOWN'; $res.Detail = ('receipt-unclear: ' + $c.Status + ' (' + $c.Detail + ')')
        }
        return $res
    }
    $res.Detail = 'send-not-confirmed'
    return $res
    } finally {$script:SendPageOverride=$oldPage}
}

if(-not(Get-Command New-ConfirmedOutboundReceipt -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'sent_records.ps1')}
