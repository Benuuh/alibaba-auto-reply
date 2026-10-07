param(
    [string]$Action = "start",
    [string]$LogDir = "",
    # [Phase3 2026-09-26] 仅用于自测: 验证 pending_retry.json 读写闭环, 不启动主循环(见文件末 SelfTestRetry 分支)
    [switch]$SelfTestRetry
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json(config.ps1 提供加载器与默认回退);
# 回复引擎(规则/语言检测/信息核对)来自 reply_engine.ps1,与回归测试共用同一份代码。
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "reply_engine.ps1")
# [SPEC 5 2026-10-03] The reply chain now lives in three focused libraries instead of inside this
# file. Load order matters: msg_norm needs reply_engine's normalization primitives, reply_policy
# needs reply_engine's banned-word / liability authorities, and reply_gen needs reply_policy.
. (Join-Path $PSScriptRoot "lib\msg_norm.ps1")
. (Join-Path $PSScriptRoot "lib\reply_policy.ps1")
# [2026-10-05 spec §3] 可信卖家身份、运行时时钟与受控事实渲染（纯函数库：无 CDP、无 LLM、无通知、
# 不写业务状态）。显式加载，最终 gate 与直接事实回答共用同一契约。
. (Join-Path $PSScriptRoot "lib\seller_context.ps1")
. (Join-Path $PSScriptRoot "lib\reply_gen.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
. (Join-Path $PSScriptRoot "lib\send.ps1")
. (Join-Path $PSScriptRoot "lib\llm.ps1")
. (Join-Path $PSScriptRoot "lib\lock.ps1")
# [FIX-PAGEHEALTH 2026-09-25] 数据面断连告警只走既有本地告警通道（文件+弹窗+企微），禁止自建通知路径
. (Join-Path $PSScriptRoot "lib\alert_local.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\quote.ps1")
. (Join-Path $PSScriptRoot "lib\no_reply.ps1")
. (Join-Path $PSScriptRoot "lib\vision.ps1")
# [2026-09-26 更像真人销售 S1] 消息来源判定(唯一判定处): @@TS = 机器人, 无标记的 [ME] = 人工
. (Join-Path $PSScriptRoot "lib\msg_source.ps1")
# [2026-10-07 spec §3.1 / 复核 R1] 浏览器侧逐条抽取与行序列化**唯一**实现：
#   会话读取与发送前后的收据快照共用同一份 JS，真实消息边界/方向/平台 ID/噪声规则不再各写一套。
. (Join-Path $PSScriptRoot "lib\msg_extract_js.ps1")
# [2026-10-05 spec §6.3/§5-2/§5-1] 运行数据根与隔离守卫、运行态 JSON 原子读写。
#   paths.ps1 让 state/pause/tasks/locks/pid/remind 统一经路径接口定位（显式 RuntimeRoot 下全部落在该根内）；
#   state_store.ps1 提供"临时写入 → 回读校验 → 备份 → 原子替换"，并区分 missing/empty/corrupt。
. (Join-Path $PSScriptRoot "lib\paths.ps1")
. (Join-Path $PSScriptRoot "lib\state_store.ps1")
# [2026-10-05 spec §2.1/§2.2/§4] 人工临时暂停、已确认发送记录、人工任务闭环。
. (Join-Path $PSScriptRoot "lib\sent_records.ps1")
. (Join-Path $PSScriptRoot "lib\human_pause.ps1")
. (Join-Path $PSScriptRoot "lib\human_tasks.ps1")
# [2026-10-07 spec §3/§4/§6] 统一消息事件与四态来源、事件级调查、持久化发送尝试。
#   加载顺序：msg_events 依赖 msg_source(37 行)；send_attempts 依赖 msg_events + state_store + sent_records(44 行)。
. (Join-Path $PSScriptRoot "lib\msg_events.ps1")
. (Join-Path $PSScriptRoot "lib\investigations.ps1")
. (Join-Path $PSScriptRoot "lib\send_attempts.ps1")
. (Join-Path $PSScriptRoot "lib\doc.ps1")
. (Join-Path $PSScriptRoot "lib\accio.ps1")
. (Join-Path $PSScriptRoot "log_rotate.ps1")
. (Join-Path $PSScriptRoot "retention.ps1")
$script:skillCfg = Get-SkillConfig
# [2026-10-05 spec §3.1] Seller identity and the runtime clock come from the ONE central config.
# ActionEvidence defaults to all-false: this round wires no human-todo / notification loop, so no
# exit may claim a check, a handoff, a follow-up or a deadline unless real evidence is supplied.
$script:sellerProfile = Get-SellerProfile -Config $script:skillCfg
$script:actionEvidence = New-ActionEvidence -Values $null
$script:logDirExplicit = [bool]$LogDir
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:cdpScript = Get-SkillPath "cdp"
$script:ensureScript = Get-SkillPath "ensure"
$script:llmCfgFile = Get-SkillPath "llmcfg"

$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
# [2026-10-05 spec §6.3] 账本路径统一走路径接口：未显式指定 -LogDir 时由 Get-SkillPath "state" 解析
#   （生产 = scripts\state.json，与改动前一致；隔离运行根下 = <root>\state.json）。
if ($script:logDirExplicit) { $stateFile = Join-Path $LogDir "state.json" } else { $stateFile = Get-SkillPath "state" }
# Accio 网关灰度开关(默认全关;影子/读取失败一律回退 CDP)
$script:accioFlags = Get-AccioFlags $script:skillCfg
Set-AccioLogFile $logFile
# F7:恢复 Accio 鉴权负缓存(跨重启生效),避免上一进程记录的 AUTH-REQUIRED 冷却窗口丢失
Restore-AccioAuthState

# F4(2026-09-15 停摆根因修复):回复轮次总预算(秒,缺省 180)。超预算则本轮不发送、保留待处理,下一轮重试
$script:replyRoundBudgetSec = 180
if ($script:skillCfg.PSObject.Properties.Name -contains 'reply_round_budget_sec' -and $script:skillCfg.reply_round_budget_sec) {
    $script:replyRoundBudgetSec = [int]$script:skillCfg.reply_round_budget_sec
}
if ($script:replyRoundBudgetSec -lt 30) { $script:replyRoundBudgetSec = 30 }

# Legacy configuration retained for compatibility; current pending policy never consumes these timers.
$script:replyMinGapMin = 5
if ($script:skillCfg.PSObject.Properties.Name -contains 'reply_min_gap_min' -and $script:skillCfg.reply_min_gap_min) {
    $script:replyMinGapMin = [int]$script:skillCfg.reply_min_gap_min
}
if ($script:replyMinGapMin -lt 1) { $script:replyMinGapMin = 1 }
$script:replyPostSendCooldownMin = 5
if ($script:skillCfg.PSObject.Properties.Name -contains 'reply_post_send_cooldown_min' -and $script:skillCfg.reply_post_send_cooldown_min) {
    $script:replyPostSendCooldownMin = [int]$script:skillCfg.reply_post_send_cooldown_min
}
if ($script:replyPostSendCooldownMin -lt 1) { $script:replyPostSendCooldownMin = 1 }
# §0.1 硬要求: 发送后冷却**不得小于**最小间隔。配错了(冷却 < 间隔)就抬到与间隔一致, 并留痕
#   (告警落到 monitor.log —— 见 Initialize-MonitorRuntime 的 COOLDOWN-RAISED 行; 此处只记标记)。
$script:cooldownRaisedToGap = $false
if ($script:replyPostSendCooldownMin -lt $script:replyMinGapMin) {
    $script:cooldownRaisedToGap = $true
    $script:replyPostSendCooldownMin = $script:replyMinGapMin
}
# Legacy two-round value; current pending entry passes one occurrence explicitly.
$script:requiredSeenRounds = 2
# Legacy seconds floor, not an active pending-reply gate.
$script:replyNewMsgFloorSec = 20
if ($script:skillCfg.PSObject.Properties.Name -contains 'reply_new_msg_floor_sec' -and $script:skillCfg.reply_new_msg_floor_sec) {
    $script:replyNewMsgFloorSec = [int]$script:skillCfg.reply_new_msg_floor_sec
}
if ($script:replyNewMsgFloorSec -lt 0) { $script:replyNewMsgFloorSec = 0 }

# 发送前拦截安全兜底句（spec 禁词拦截 Phase 4 + 2026-09-10 责任承诺拦截 + 2026-10-05 §6.3）：
# 命中禁词/责任承诺/无执行证据承诺且重写仍越线时整体替换。原文案自身就含 "I'm checking with the
# team ... I'll get back to you"，在本轮新门禁下已属无证据承诺，故改为只说明当前无法确认、不假称动作。
$script:banSafeFallback = "Thanks for your patience. I can't confirm this from here - a person from the team needs to check it."

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# 切换到"待回复"标签并返回是否成功
function Switch-ToPendingTab() {
    $js = @"
(function(){
  var tab = Array.from(document.querySelectorAll('.list-tab-item')).find(function(t){ return (t.innerText||'').trim() === '待回复'; });
  if (!tab) return 'NO_TAB';
  var active = (tab.className||'').toString().indexOf('active') >= 0;
  if (!active) tab.click();
  return active ? 'ALREADY_ACTIVE' : 'SWITCHED';
})()
"@
    return Invoke-CdpEval $js
}

# [SPEC §4.2-G1 2026-09-27] OneTalk 页是否存在(只读探测, 不写页面)。
#   取 $null 而非抛异常: 门禁本身不允许因为探测失败而放行。任何异常/无页一律返回 $false(=页面不可用)。
#   ⚠️ 与 Test-PageHealth 的分工: 本函数答"有没有 OneTalk 页", Test-PageHealth 答"页在但数据面是否断"。
#   两者任一不通过 ⇒ 整轮跳过(§4.2-G1)。
function Test-OneTalkPagePresent {
    try {
        $p = Get-Page
        return [bool]($p -and $p.url -match 'onetalk\.alibaba\.com')
    } catch { return $false }
}

# [SPEC §4.2-G1b 2026-09-27] G1 连续 2 轮 ⇒ 升级既有 PAGE-HEAL 路径(chrome_ensure -ForceRestart)。
#   返回: 'OK'(已尝试自愈) / 'FATAL'(自愈失败达上限 ⇒ 必须停止本轮之后的会话处理并告警)。
#   与主循环里既有的分级自愈(Get-PageHealAction 的静默期/退避/上限)共用同一套计数器, 不新造节流。
function Invoke-PageHealFromGate([string]$Reason) {
    if ($script:pageHealFails -ge 2) {
        Write-Log "ABORT-PAGE-DOWN-FATAL reason=$Reason healFails=$($script:pageHealFails) action=stop-round"
        try {
            Send-WecomMessage ("[ALERT] OneTalk 页面连续不可用, chrome_ensure 自愈已失败 $($script:pageHealFails) 次 (reason=$Reason); 已停止本轮及之后的会话处理, 等待人工介入") | Out-Null
        } catch { Write-Log "ABORT-PAGE-DOWN-FATAL: wecom alert failed - $($_.Exception.Message)" }
        return 'FATAL'
    }
    $act = Get-PageHealAction -Streak $script:pageDownStreak -Restarts $script:pageHealRestarts -QuietUntil $script:pageHealQuietUntil
    if ($act.Action -ne 'restart') {
        # 静默期/达上限等既有节流命中 ⇒ 不重复重启, 但仍按 G1 整轮跳过(上面已 return)
        Write-Log "PAGE-HEAL-ESCALATE-SKIPPED reason=$($Reason) heal=$($act.Action) [$($act.Reason)]"
        return 'OK'
    }
    Write-Log ("PAGE-HEAL-ESCALATE reason=$Reason streak=$($script:pageDownStreak) [$($act.Reason)] quiet=$($act.NextQuietSec)s")
    $ensure = powershell -ExecutionPolicy Bypass -NoProfile -File $script:ensureScript -ForceRestart 2>&1
    Write-Log "PAGE-HEAL-ESCALATE chrome_ensure exit=$LASTEXITCODE result: $(($ensure -join ' | '))"
    $script:pageHealRestarts++
    if ($act.NextQuietSec -gt 0) { $script:pageHealQuietUntil = (Get-Date).AddSeconds($act.NextQuietSec) }
    # 自愈是否成功以"页面上又能看到 OneTalk"为准, 不以退出码为准(退出码为 0 也可能是空动作)
    if (Test-OneTalkPagePresent) {
        Write-Log "PAGE-HEAL-ESCALATE result=ok (onetalk page present again)"
        $script:pageHealFails = 0
    } else {
        $script:pageHealFails++
        Write-Log "PAGE-HEAL-ESCALATE result=failed (healFails=$($script:pageHealFails))"
    }
    return 'OK'
}

function Get-Snapshot() {
    # 先切到待回复标签并等待列表刷新，再抓取会话列表
    $tabRes = Switch-ToPendingTab
    Start-Sleep -Seconds 2
    # 页面刚 reload 时"待回复"标签可能尚未渲染（NO_TAB），
    # 此时抓取会误拿到"全部/已读"标签的历史列表，导致 Open-Convo 全部 NOT_FOUND。
    # 等待 3 秒后重试切换，确保列表来源正确
    if ($tabRes -eq 'NO_TAB') {
        Start-Sleep -Seconds 3
        $tabRes = Switch-ToPendingTab
        Start-Sleep -Seconds 2
    }
    if ($tabRes -notin @('SWITCHED','ALREADY_ACTIVE')) { return 'PENDING_TAB_UNVERIFIED' }
    $js = $script:ConversationScopeJs + @"
(function(){
  var tabs = Array.from(document.querySelectorAll('.list-tab-item')).filter(function(t){
    return __aarVisible(t) && (t.innerText||'').trim() === '待回复';
  });
  if (tabs.length !== 1 || !/(^|\s)active(\s|$)/.test(String(tabs[0].className||''))) return 'PENDING_TAB_UNVERIFIED';
  // 抓取会话列表（优先 innerText，回退 textContent 兼容虚拟滚动）
  var items = Array.from(document.querySelectorAll('.contact-item-container')).filter(__aarVisible);
  var arr = [];
  items.forEach(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var name = (nameEl && nameEl.innerText && nameEl.innerText.trim()) || '';
    var txt = (e.innerText || '').replace(/\n+/g,' ').replace(/\s+/g,' ').trim();
    if (!name) { arr.push({error:'PENDING_NAME_UNVERIFIED'}); return; }
    var stable = txt.replace(/\d{1,2}:\d{2}/g,' ').replace(/\d{4}-\d{1,2}-\d{1,2}/g,' ').replace(/\s+/g,' ').trim();
    if (name) arr.push({unread: txt.indexOf('[未读]') >= 0, name: name.trim(), preview: stable.substring(0,80), full: txt.substring(0,200)});
  });
  // 按 name 去重：同一会话只保留一条，避免一次循环处理两次导致重复发送
  if (arr.some(function(it){return !!it.error;})) return 'PENDING_NAME_UNVERIFIED';
  var seen = Object.create(null);
  arr = arr.filter(function(it){ var key=__aarName(it.name); if (seen[key]) return false; seen[key] = true; return true; });
  if (arr.length > 0) return JSON.stringify(arr);
  // 列表为空：不在此处 reload（该提示文案常驻易误判），返回空由主循环连续空计数统一处理
  return '[]';
})()
"@
    $res = Invoke-CdpEval $js
    return $res
}



# P2.1a 合并:打开会话 + 会话名轮询校验 + 抓取消息 一次 eval 完成(JS Promise 轮询,cdp.ps1 awaitPromise:true)。
# 返回: 'NOT_FOUND' / 'SWITCH_TIMEOUT' / 解析失败标记 / 对象{name, msgs}(msgs 为 [BUYER]/[ME] 行文本)。
# 将原 5 次子进程调用(Open 1 + 校验 3 + 抓取 1)合并为 1 次,显著缩短扫描周期。
function Open-ConvoAndGetMessages([string]$keyword) {
    # Exact target + single visible header/container + scoped rows, shared with receipts.
    $js = Get-ConversationReadJs -Buyer $keyword
    $res = (Invoke-CdpEval $js).Trim()
    try {
        $obj = $res | ConvertFrom-Json
        if ($obj.error) { return ('READ_GUARD:' + [string]$obj.error) }
        if ($obj -and $obj.name -and $obj.scope) { return $obj }
    } catch {}
    return 'PARSE_FAIL'
}

function Get-Rules() {
    $rulesFile = Join-Path $LogDir "reply_rules.json"
    if (Test-Path $rulesFile) {
        try {
            return Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Log "Rules file parse error: $($_.Exception.Message)"
            return $null
        }
    }
    Write-Log "Rules file not found: $rulesFile"
    return $null
}


# LLM 配置：读取 llm_config.json（非敏感项）+ credentials.md（api_key，敏感信息铁律），未配置时返回 $null
$script:llmConfig = $null
function Get-LLMConfig {
    if ($script:llmConfig) { return $script:llmConfig }
    $cfgFile = $script:llmCfgFile
    if (Test-Path $cfgFile) {
        try {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # api_key 只从 credentials.md 读取（llm_config.json 不存任何敏感值）；
            # key 缺失时返回 $null 让调用方回退规则引擎（实际 key 注入在 libllm.ps1 的 Invoke-LLM 内部）
            $key = Get-CredentialValue 'api_key'
            if (-not $key) {
                Write-Log "LLM config: api_key missing in credentials.md"
                return $null
            }
            $script:llmConfig = $cfg
            return $cfg
        } catch {}
    }
    return $null
}

# 回复代理系统提示词（从 reply_agent_prompt.md 读取，带修改时间失效缓存）
$script:replyPromptCache = $null
$script:replyPromptCacheTime = $null
# =============================================================================================
# Reply generation - single entry point for the reply chain.
#
# [SPEC 5 2026-10-03] This used to be where monitor.ps1 assembled the model request itself: it
# concatenated the whole reply_rules.json corpus onto the prompt on every call, rebuilt the
# ask-count metadata inline, described the context as "reverse order, first line is newest"
# (which was backwards - see lib\msg_norm.ps1), and offered two separate rewrite switches
# (-BanRetry / -CommitRetry) so a draft could cost up to three model calls.
#
# All of that now lives in lib\reply_policy.ps1 (what to say) and lib\reply_gen.ps1 (how to say
# it): one slim prompt, one compact chronological context, ONE model call, at most ONE bounded
# rewrite driven by the full violation list, and the same scenario fallback the rule path uses.
# This function is kept as a thin adapter so the attachment pipeline below does not have to change.
#
# Returns the reply text, or $null only when even the fallback could not produce one.
# Side effect: $script:lastReplySource / $script:lastReplyDecision describe what happened, so
# callers log the truth instead of assuming every non-empty reply came from the model.
# =============================================================================================
$script:lastReplySource = 'NONE'
$script:lastReplyDecision = $null

function Get-ReplyPromptPath { return (Join-Path $LogDir "reply_agent_prompt.md") }
function Get-ReplyScenarioPath { return (Join-Path $LogDir "reply_scenarios.md") }

function Generate-Reply-LLM([object]$rules, [string]$convoName, [string]$latest, [string[]]$context, [switch]$BanRetry, [switch]$CommitRetry, [string[]]$ImageDataUrls = $null, [string]$AttachmentText = $null, [object]$Conversation = $null) {
    $lf = [string][char]10
    # Reuse the verified conversation. Plain model text no longer contains ordering evidence.
    $conv = $Conversation
    if (-not $conv) { $conv = ConvertTo-MessageList (@($context) -join $lf) $convoName }
    # [spec §5.4 第 3 条] 已验证的任务确认资料与买家原话走同一份事实模型（同一证据适配契约）。
    $facts = Get-ConversationFacts -Conversation $conv -Buyer $convoName -WithTaskEvidence
    # -NotifyChannelAvailable gates whether a specific deadline may be promised at all. It defaults
    # to $false: the local todo/notification path is not wired into this build, and spec 4.3 forbids
    # inventing a response deadline. The decision object still reports NeedHumanTodo / TodoKind so
    # the wiring can be added later without touching policy.
    # [2026-10-05] The reachable channel no longer grants a deadline by itself: the decision needs a
    # real persisted todo, a real notification delivery and a real deadline (spec §6.3).
    $runtimeCtx = New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc (Get-ReplyClockUtc)
    # [2026-10-05 spec §4] Execution evidence comes from THIS buyer's persisted human tasks:
    # a boolean NeedHumanTodo and a reachable notification channel are not evidence.
    # [2026-10-05 spec §3.2 第 1 条] When the orchestrator already created/updated this turn's task
    # (before generation), its read-back evidence is the authoritative one - re-reading the store
    # here would still be correct but would hide an ordering regression.
    # [spec §4.1 第 1 条] 生成阶段的行动证据只来自本轮确切任务引用；
    #   没有引用就是空证据（不再退回"该买家最近一条待办"）。
    $evidence = $script:actionEvidence
    if ($script:turnActionEvidence) { $evidence = $script:turnActionEvidence }
    else { $evidence = New-ActionEvidence -Values $null }
    $decision = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $rules -NotifyChannelAvailable:([bool]$script:notifyChannelVerified) -RuntimeContext $runtimeCtx -ActionEvidence $evidence

    # Bounded rewrite: at most ONE extra call, and only while the round budget still allows it.
    $maxRewrites = [Math]::Max(0,1-[int]$script:turnRewrites)
    if ((Get-Command Get-LlmRoundRemainingSec -ErrorAction SilentlyContinue) -and (Get-LlmRoundRemainingSec) -lt 30) {
        # Not enough budget left to attempt a rewrite: ship the fallback rather than overrun the round.
        $maxRewrites = 0
    }

    $gen = Invoke-ReplyGeneration -Conversation $conv -Decision $decision -Rules $rules `
        -PromptPath (Get-ReplyPromptPath) -ScenarioPath (Get-ReplyScenarioPath) `
        -LogFile $logFile -ImageDataUrls $ImageDataUrls -AttachmentText $AttachmentText -MaxRewrites $maxRewrites `
        -RuntimeContext $runtimeCtx

    $codes = @($gen.Violations | ForEach-Object { $_.Code }) -join ','
    Write-Log "REPLY-GEN $($convoName) scenario=$($decision.Scenario) src=$($gen.Source) modelCalls=$($gen.ModelCalls) rewrites=$($gen.Rewrites) ctxChars=$($gen.ContextChars) violations=[$codes] fallback=$($gen.FallbackReason) ask=[$($decision.AskFields -join ',')] todo=$($decision.TodoKind) orderConfident=$($decision.OrderConfident) subject=$($decision.Subject) facts=[$($decision.RequestedFacts -join ',')] unresolved=[$($decision.UnresolvedFacts -join ',')] clock=$($runtimeCtx.ClockSource)"
    $script:lastReplySource = $gen.Source
    $script:lastReplyDecision = $decision
    # [spec §2/§8.3] 组合器维护的来源区间：发送锁内据此重新组合，不猜前缀。
    $script:lastReplyComposition = $gen.Composition
    $script:turnRewrites += [int]$gen.Rewrites
    if (-not $gen.Text) { return $null }
    return $gen.Text
}


# [2026-09-27 FIX-DEDUP2] 去重账本的"可读性"必须与"内容是空"区分开。
# 背景(实测事故): 2026-09-27 00:43 前后出现"买家没说新话却被重复回复"5 例, 且 INQUIRY-ALERT 对账本里
#   早有记录的老买家误发。用程序自己的 Test-DedupHit 复现这 5 例, 全部返回 True(本应 SKIP) ⇒ 现场那一刻
#   读不到账本记录。危险放大器是 Set-StateHash 原本的第一行:
#       if (-not $ctx.state -or -not $ctx.state.replied) { $ctx.state = [pscustomobject]@{ replied = @{} } }
#   它把"读取失败(返回 $null)"和"首次创建(确实没有账本)"当成同一件事 ⇒ 一次读取失败后,
#   下一次发送成功就会把**整本账本重置成 1 条**, 并由 Set-RepliedState 连**备份一起覆盖** ⇒
#   此后所有老会话都被判成"首次问询"而重发。这正是本轮要堵的洞。
# 处置方向与 spec §4-15 一致: 宁可少发, 不可重复打扰; 判据不确定时偏向不发, 且必须留日志(不得静默)。
function Get-RepliedStateFileSize {
    $health = Get-LedgerHealth
    return [long]$health.Bytes
}

# =============================================================================================
# [2026-10-05 spec §5 A5] 账本健康判定的统一入口 Get-LedgerHealth
#
# 为什么必须改：旧实现把"读取状态"压成 $null，再用**文件字节数**猜它是不是首次运行
#   （if ($bytes -gt 100) {不可用} else {no-ledger-yet}）。15 字节的损坏账本因此被判成
#   "还没有账本"，接着走首次创建分支把历史覆盖掉——正是 2026-09-27 重复打扰事故的形态。
# 现在的判据：状态来自 Read-JsonDocument（missing / empty / valid / corrupt），结构再按
#   账本契约校验（顶层 replied 集合必须存在），文件大小只出现在诊断字段里。
# 主文件缺失时才回退备份；备份也必须解析通过且结构合法，并且显式记录恢复结果。
# 读取结果按 (路径, 大小, 最后写入时间) 在本进程内缓存，避免一轮扫描里反复读盘。
# =============================================================================================
# 注意：PS 5.1 下**有序字典**（[ordered]@{}）的 PSObject.Properties 不暴露自定义键，
#   "$cache.Key" 会直接报 PropertyNotFound。这里必须用普通哈希表（键可枚举）或 pscustomobject。
$script:LedgerHealthCache = @{ Key = ''; Value = $null; Has = $false }
$script:LedgerReadLog = New-Object System.Collections.ArrayList

# 追加一条账本链路日志。返回列表在极端作用域（例如被抽取后重新定义）下可能不可用，
#   此时直接退回 Write-Log，绝不让"记日志"本身抛异常。
function Add-LedgerReadLog([string]$Text) {
    try {
        if ($null -ne $script:LedgerReadLog) { $script:LedgerReadLog.Add([string]$Text); return }
    } catch { }
    Write-Log ([string]$Text)
}

function Get-CachedDocumentRead([string]$Path) {
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $key = ($Path + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks)
    } catch {
        $key = ($Path + '|missing')
    }
    if ($script:LedgerHealthCache.Has -and $script:LedgerHealthCache.Key -eq $key) { return $script:LedgerHealthCache.Value }
    $doc = Read-JsonDocument $Path
    $script:LedgerHealthCache = @{ Key = $key; Value = $doc; Has = $true }
    return $doc
}

function Reset-LedgerHealthCache {
    $script:LedgerHealthCache = @{ Key = ''; Value = $null; Has = $false }
}

# 顶层 replied 集合是否存在且可枚举。合法 JSON 但没有 replied 键 ⇒ 结构不合法 ⇒ 不可用。
function Test-LedgerShape($Data) {
    if ($null -eq $Data) { return $false }
    if (-not ($Data.PSObject.Properties.Name -contains 'replied')) { return $false }
    $r = $Data.replied
    if ($null -eq $r) { return $false }
    if ($r -is [string]) { return $false }
    return $true
}

function Get-ReplyEntryCount($State) {
    if (-not $State) { return 0 }
    if (-not ($State.PSObject.Properties.Name -contains 'replied')) { return 0 }
    $r = $State.replied
    if (-not $r) { return 0 }
    if ($r -is [System.Collections.IDictionary]) { return $r.Count }
    return @($r.PSObject.Properties.Name).Count
}

# 返回 @{ Status; Data; Bytes; Error; Path; Source; Count; Recovered; Reasons }
#   Status: missing | empty | valid | corrupt
#   Source: primary | backup | none
function Get-LedgerHealth {
    $health = [pscustomobject]@{
        Status = 'missing'; Data = $null; Bytes = [long]0; Error = ''; Path = [string]$script:stateFile
        Source = 'none'; Count = 0; Recovered = $false; Reasons = @()
    }
    try { if (Test-Path $script:stateFile) { $health.Bytes = [long](Get-Item -LiteralPath $script:stateFile).Length } } catch { }
    $doc = Get-CachedDocumentRead $script:stateFile
    $health.Status = [string]$doc.Status
    $health.Error = [string]$doc.Error
    if ($doc.Status -eq 'valid') {
        if (Test-LedgerShape $doc.Data) {
            $health.Data = $doc.Data
            $health.Source = 'primary'
            $health.Count = Get-ReplyEntryCount $doc.Data
            return $health
        }
        $health.Status = 'corrupt'
        $health.Error = 'ledger schema invalid: missing replied collection'
        return $health
    }
    if ($doc.Status -eq 'empty') {
        $health.Error = 'ledger file is present but contains no JSON document'
        return $health
    }
    if ($doc.Status -eq 'missing') {
        # 只有主文件确实不存在时才看备份；主文件损坏绝不静默改用备份。
        $bak = Get-JsonDocumentBackupPath $script:stateFile
        $docBak = Get-CachedDocumentRead $bak
        if ($docBak.Status -eq 'valid' -and (Test-LedgerShape $docBak.Data)) {
            $health.Data = $docBak.Data
            $health.Source = 'backup'
            $health.Count = Get-ReplyEntryCount $docBak.Data
            $health.Reasons = @('primary-missing-restored-from-backup')
            if ($health.Count -lt 1) {
                $health.Status = 'corrupt'
                $health.Data = $null
                $health.Source = 'none'
                $health.Error = 'backup ledger has no replied entries'
                return $health
            }
            $w = Write-JsonDocumentAtomic -Path $script:stateFile -Data $docBak.Data -Depth 5 -NoBackup
            if ($w.Ok) {
                # 恢复后必须**重新读取并核验**主文件；不能假设刚写下的内容就是下一次读到的内容
                #   （实测：写回瞬间(mtime,length)可能与先前的缓存键重合，直接沿用缓存会把恢复后的
                #   账本仍判成不可用 ⇒ 本轮被 fail-closed 挡下，恢复等于没发生）。
                Reset-LedgerHealthCache
                # 回读必须**绕过缓存**：刚刚那次写入的 (长度, mtime) 可能与此前的缓存键重合，
                #   走缓存会把恢复后的账本仍判成不可用。
                $verify = Read-JsonDocument $script:stateFile
                try {
                    $fi = Get-Item -LiteralPath $script:stateFile -ErrorAction Stop
                    $script:LedgerHealthCache = @{ Key = ($script:stateFile + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks); Value = $verify; Has = $true }
                } catch { Reset-LedgerHealthCache }
                if ($verify.Status -ne 'valid' -or -not (Test-LedgerShape $verify.Data)) {
                    $health.Status = 'corrupt'
                    $health.Data = $null
                    $health.Source = 'none'
                    $health.Recovered = $false
                    $health.Error = 'restored ledger failed read-back verification'
                    Add-LedgerReadLog ('LEDGER-BACKUP-RESTORE-UNVERIFIED status=' + [string]$verify.Status)
                    return $health
                }
                $health.Data = $verify.Data
                $health.Count = Get-ReplyEntryCount $verify.Data
                $health.Source = 'primary'
                $health.Recovered = $true
                Add-LedgerReadLog ('LEDGER-RESTORED-FROM-BACKUP entries=' + $health.Count)
            } else {
                Add-LedgerReadLog ('LEDGER-BACKUP-RESTORE-FAIL ' + $w.Error)
            }
            return $health
        }
        return $health
    }
    return $health
}

# 账本是否可用于去重判定。返回 @{ Ok=<bool>; Count=<int>; Bytes=<long>; Reason=<string>; Status=<string> }
#   Ok=$false 的情形全部来自**状态**而不是文件大小：损坏 / 空白 / 结构不合法 / 读取失败。
function Test-RepliedStateUsable($state) {
    $health = Get-LedgerHealth
    $st = [string]$health.Status
    if ($st -ne 'valid' -or -not (Test-LedgerShape $health.Data)) {
        if ($st -eq 'missing') { return @{ Ok = $false; Count = 0; Bytes = $health.Bytes; Reason = 'ledger-missing'; Status = $st } }
        if ($st -eq 'empty') { return @{ Ok = $false; Count = 0; Bytes = $health.Bytes; Reason = 'ledger-empty-file'; Status = $st } }
        return @{ Ok = $false; Count = 0; Bytes = $health.Bytes; Reason = 'ledger-corrupt-or-unreadable'; Status = $st }
    }
    $count = Get-ReplyEntryCount $health.Data
    if ($count -eq 0) {
        # 合法 JSON 的空 replied 集合 = **有效空账本**（首次初始化后的正常状态）。
        return @{ Ok = $true; Count = 0; Bytes = $health.Bytes; Reason = 'ok-empty'; Status = $st }
    }
    return @{ Ok = $true; Count = $count; Bytes = $health.Bytes; Reason = 'ok'; Status = $st }
}

# 只有"主文件确实不存在"的首次初始化路径可以调用本函数，明确返回是否允许创建空账本。
function Test-LedgerFirstInitAllowed {
    $health = Get-LedgerHealth
    return [bool]($health.Status -eq 'missing')
}

function Get-RepliedState {
    # [2026-10-05 spec §5-2] 返回值仍然是"账本数据或 $null"（保持旧契约，避免调用方二次改造）；
    #   但 $null 现在**不再**被当成"没有账本"：健康状态由 Get-LedgerHealth 单独保留，
    #   所有门禁都读那一份状态，不再用文件大小猜。
    if ($script:LedgerReadLog -and $script:LedgerReadLog.Count -gt 0) {
        foreach ($m in @($script:LedgerReadLog)) { Write-Log ([string]$m) }
        $script:LedgerReadLog.Clear()
    }
    $health = Get-LedgerHealth
    if ($health.Status -eq 'valid' -and $health.Data) { return $health.Data }
    return $null
}

# [FIX-DEDUP2] 账本修复: 主文件不可解析时, 用**经解析与结构验证的**备份覆盖主文件。
# 绝不"重建为空账本" —— 那等于把买家回复历史丢掉, 必然导致重发。
function Repair-RepliedState {
    $bak = Get-JsonDocumentBackupPath $script:stateFile
    $doc = Read-JsonDocument $bak
    if ($doc.Status -ne 'valid') { return $false }
    try {
        $j = $doc.Data
        if (-not (Test-LedgerShape $j)) { return $false }
        $n = Get-ReplyEntryCount $j
        if ($n -lt 1) { return $false }
        # 原子替换：备份内容先落到临时文件再改名，中途中断不会留下半个账本。
        $w = Write-JsonDocumentAtomic -Path $script:stateFile -Data $j -NoBackup
        if (-not $w.Ok) { Write-Log ("STATE-REPAIR-FAIL: " + $w.Error); return $false }
        Reset-LedgerHealthCache
        Write-Log "STATE-REPAIRED: state.json restored from backup ($n entries)"
        return $true
    } catch {
        Write-Log "STATE-REPAIR-FAIL: $($_.Exception.Message)"
        return $false
    }
}


function Set-RepliedState([object]$state) {
    # 双写：主文件 + 备份，防止文件损坏/丢失导致 dedup 失效重复回复。
    # [2026-10-05 spec §5-2] 改为**原子替换**：临时文件写入 → 回读校验 → 备份 → 原子改名。
    #   任一步失败 ⇒ 目标账本保持原样并留日志，绝不写入半个/空账本。
    $w = Write-JsonDocumentAtomic -Path $stateFile -Data $state -Depth 5
    if (-not $w.Ok) {
        Write-Log ("STATE-WRITE-FAIL: " + $w.Error + " (ledger left unchanged)")
        return $false
    }
    Reset-LedgerHealthCache
    $bak = Get-JsonDocumentBackupPath $stateFile
    $wb = Write-JsonDocumentAtomic -Path $bak -Data $state -Depth 5 -NoBackup
    if (-not $wb.Ok) { Write-Log ("STATE-BACKUP-WRITE-FAIL: " + $wb.Error) }
    return $true
}

# 去重状态统一写入:按类型分流合并 replied 表并双写落盘(发送成功路径与旧记录升级共用)。
# 注意:首次创建时 replied 是 @{} (IDictionary),PSObject.Properties 会枚举 CLR 内部属性污染 state.json,
# 必须按类型分流:IDictionary 用 Keys,反序列化的 PSCustomObject 用 Properties。
function Set-StateHash($ctx, [string]$skey, [string]$hash) {
    # [FIX-DEDUP2] 关键保护: 账本"读取失败"**绝不允许**走"首次创建"分支。
    #   原实现 if (-not $ctx.state -or -not $ctx.state.replied) { $ctx.state = @{replied=@{}} }
    #   会把读取失败当成新账本 ⇒ 落盘时把 135 条历史覆盖成 1 条(连备份一起) ⇒ 之后所有老会话被判成
    #   "首次问询"而重发。实测事故见 D-21。这里改为: 先在内存里尝试修复, 仍不可用则**拒绝写入**并告警。
    #   [2026-10-05 spec §5-2] 判据取 Get-LedgerHealth 的**状态**，不再取文件字节数。
    $usable = Test-RepliedStateUsable $ctx.state
    if (-not $usable.Ok) {
        Write-Log "STATE-WRITE-SKIP $skey : refused (ledger unusable: $($usable.Reason), status=$($usable.Status), bytes=$($usable.Bytes)) - not overwriting the reply ledger"
        $rep = Repair-RepliedState
        $ctx.state = Get-RepliedState
        $usable2 = Test-RepliedStateUsable $ctx.state
        if (-not $usable2.Ok) {
            Write-LocalAlert 'dedup_ledger' ("reply ledger unusable ($($usable2.Reason), status=$($usable2.Status), bytes=$($usable2.Bytes)); refused to overwrite it for $skey") 'local-only' | Out-Null
            return
        }
        Write-Log "STATE-WRITE-RESUME $skey : ledger usable again after repair=$rep (entries=$($usable2.Count))"
    }
    if (-not $ctx.state -or -not $ctx.state.replied) { $ctx.state = [pscustomobject]@{ replied = @{} } }
    $rep = @{}
    $src = $ctx.state.replied
    if ($src -is [System.Collections.IDictionary]) {
        foreach ($k in $src.Keys) { $rep[$k] = $src[$k] }
    } else {
        foreach ($p in $src.PSObject.Properties) { $rep[$p.Name] = $p.Value }
    }
    $rep[$skey] = $hash
    $ctx.state = [pscustomobject]@{ replied = $rep }
    Set-RepliedState $ctx.state
}

# 启动时清理：msgs 快照只保留最近 200 份，防止无限增长
function Cleanup-LegacyQueues {
    Get-ChildItem -Path $script:dataDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 200 | Remove-Item -Force -ErrorAction SilentlyContinue
}

# P3.4 买家档案:解析卡片原始文本,提取国家/注册时间,存 data\buyers\<key>.json(PII 仅本机,不入备份/仓库)
function Save-BuyerProfile([string]$skey, [string]$profileRaw) {
    if (-not $profileRaw) { return }
    $buyerDir = Join-Path $script:dataDir "buyers"
    if (-not (Test-Path $buyerDir)) { New-Item -ItemType Directory -Path $buyerDir -Force | Out-Null }
    $country = ""
    foreach ($c in @(
        @("Brazil","brazil|brasil"), @("United States","united states|usa|eua"), @("Mexico","mexico|m[eé]xico"),
        @("India","india"), @("Spain","spain|espa[añ]a"), @("France","france"), @("Italy","italy|italia"),
        @("Germany","germany|deutschland"), @("Nigeria","nigeria"), @("Argentina","argentina"),
        @("Chile","chile"), @("Peru","per[uú]"), @("Colombia","colombia"), @("UK","united kingdom|uk\b"),
        @("Canada","canada"), @("Pakistan","pakistan"), @("Turkey","turkey|t[uü]rkiye"), @("Egypt","egypt"),
        @("Vietnam","vietnam"), @("Philippines","philippines"), @("Indonesia","indonesia"),
        @("Saudi Arabia","saudi"), @("Russia","russia|r[uú]ssia"), @("Poland","poland"), @("Portugal","portugal")
    )) {
        if ($profileRaw -match $c[1]) { $country = $c[0]; break }
    }
    $regTime = ""
    $m = [regex]::Match($profileRaw, '(\d{4}[-/]\d{1,2}[-/]\d{1,2})')
    if ($m.Success) { $regTime = $m.Groups[1].Value }
    $fname = ($skey -replace '[^\w\-]','_') + ".json"
    $file = Join-Path $buyerDir $fname
    $profile = [pscustomobject]@{
        buyer = $skey
        country = $country
        registered = $regTime
        raw = $profileRaw
        updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $profile | ConvertTo-Json -Depth 3 | Set-Content -Path $file -Encoding UTF8
}

# 读取买家档案(内存缓存,文件 mtime 失效)
$script:__buyerProfileCache = @{}
$script:__buyerProfileCacheTime = @{}
function Get-BuyerProfile([string]$skey) {
    # 注意:Join-Path 只接受 2 个位置参数,多级路径必须嵌套或合并 ChildPath
    $f = Join-Path $script:dataDir (Join-Path "buyers" (($skey -replace '[^\w\-]','_') + ".json"))
    if (-not (Test-Path $f)) { return $null }
    $ft = (Get-Item $f).LastWriteTimeUtc.Ticks
    if ($script:__buyerProfileCache.ContainsKey($skey) -and $script:__buyerProfileCacheTime[$skey] -eq $ft) { return $script:__buyerProfileCache[$skey] }
    try {
        $p = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:__buyerProfileCache[$skey] = $p
        $script:__buyerProfileCacheTime[$skey] = $ft
        return $p
    } catch { return $null }
}

# A1 new inquiry wecom alert (24h throttle, state in data\inquiry_state.json)
function Send-NewInquiryAlert([string]$buyer, [string]$preview) {
    try {
        $isf = Join-Path $script:dataDir "inquiry_state.json"
        if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null }
        $st = $null
        if (Test-Path $isf) { try { $st = (Get-Content $isf -Raw -Encoding UTF8 | ConvertFrom-Json).pushed } catch { $st = $null } }
        $sk = $buyer.Trim().ToLowerInvariant()
        $prev = $null
        if ($st -and $st.PSObject.Properties.Name -contains $sk) { $prev = $st.$sk }
        if ($prev) {
            $ageH = 999
            try { $ageH = ((Get-Date) - ([datetime]::ParseExact([string]$prev, "yyyy-MM-dd HH:mm", $null))).TotalHours } catch {}
            if ($ageH -lt 24) { return }
        }
        $previewTxt = if ($preview) { [string]$preview } else { "(no preview)" }
        if ($previewTxt.Length -gt 120) { $previewTxt = $previewTxt.Substring(0, 120) + "..." }
        $msg = "[NEW-INQUIRY] $buyer" + [char]10 + $previewTxt
        $res = Send-WecomMessage $msg
        if ($res -eq "SENT_OK") {
            $new = @{}
            if ($st) { foreach ($p in $st.PSObject.Properties) { $new[$p.Name] = $p.Value } }
            $new[$sk] = (Get-Date -Format "yyyy-MM-dd HH:mm")
            @{ pushed = $new } | ConvertTo-Json -Depth 5 | Set-Content -Path $isf -Encoding UTF8
            Write-Log "INQUIRY-ALERT: $buyer -> $res"
        } else {
            Write-Log "INQUIRY-ALERT-FAIL: $buyer -> $res (will retry next cycle)"
        }
    } catch {
        Write-Log "INQUIRY-ALERT-ERR: $($_.Exception.Message)"
    }
}
function Invoke-LayoutMigration {
    if (-not (Test-Path $script:logFileDir)) { New-Item -ItemType Directory -Path $script:logFileDir -Force | Out-Null }
    if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null }
    foreach ($name in @("monitor.log","monitor_out.log","monitor_err.log","watchdog.log")) {
        $src = Join-Path $LogDir $name
        $dst = Join-Path $script:logFileDir $name
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            Move-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -Path $LogDir -Filter "monitor_*.log" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path (Join-Path $script:logFileDir $_.Name))) {
            Move-Item -Path $_.FullName -Destination (Join-Path $script:logFileDir $_.Name) -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -Path $LogDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path (Join-Path $script:dataDir $_.Name))) {
            Move-Item -Path $_.FullName -Destination (Join-Path $script:dataDir $_.Name) -Force -ErrorAction SilentlyContinue
        }
    }
}
# CDP/Chrome 不可达自愈:连续 3 次错误则重启 Chrome 并重新登录(监控主循环 catch 与 CDP 掉线分支共用)
function Invoke-CdpSelfHeal {
    $script:cdpFailStreak++
    if ($script:cdpFailStreak -ge 3) {
        $script:cdpFailStreak = 0
        Write-Log "CDP fail x3 - running chrome_ensure.ps1..."
        $ensure = powershell -ExecutionPolicy Bypass -File $script:ensureScript 2>&1
        Write-Log "chrome_ensure result: $($ensure -join ' | ')"
        Start-Sleep -Seconds 10
        return $true
    }
    return $false
}

# P2.2 页面重载:释放写锁 → reload → 记时 → 清零失败计数(空闲/忙时两条触发路径共用)
function Invoke-PageReload([string]$reason) {
    Release-AppLock 'onetalk-write'
    $re = Invoke-CdpEval "location.reload(); 'RELOADED'"
    Write-Log ($reason + " - $re, waiting for reconnection")
    Start-Sleep -Seconds 12
    $script:lastReload = Get-Date
    $script:emptyStreak = 0
}

# P2.4 容量治理：state 记录超阈值(200)且买家 30 天无快照活动 → 清理陈旧记录（单次遍历 msgs 快照建索引）
function Cleanup-StaleState {
    try {
        $st = Get-RepliedState
        if (-not $st -or -not $st.replied) { return }
        $names = @($st.replied.PSObject.Properties.Name)
        if ($names.Count -lt 200) { return }
        $cutoff = (Get-Date).AddDays(-30)
        # 单次遍历:一次扫描全部快照首行,建立 买家名 -> 最新快照时间 索引(原实现按买家重复扫描目录)
        $latestMap = @{}
        Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | ForEach-Object {
            $first = Get-Content $_.FullName -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -and $first.StartsWith("# BUYER: ")) {
                $bn = $first.Substring(9)
                if (-not $latestMap.ContainsKey($bn) -or $latestMap[$bn] -lt $_.LastWriteTime) { $latestMap[$bn] = $_.LastWriteTime }
            }
        }
        $removed = @()
        foreach ($n in $names) {
            $latest = $null
            if ($latestMap.ContainsKey($n)) { $latest = $latestMap[$n] }
            if (-not $latest -or $latest -lt $cutoff) {
                $st.replied.PSObject.Properties.Remove($n)
                $removed += $n
            }
        }
        if ($removed.Count -gt 0) {
            Set-RepliedState $st
            Write-Log "STATE-CLEANUP: removed $($removed.Count) stale entries (total was $($names.Count))"
        }
    } catch {
        Write-Log "STATE-CLEANUP: error $($_.Exception.Message)"
    }
}

# ===== 待补发表 (2026-09-26 Phase 3) =====
# 背景: 发送失败(ABORT_WRONG_CONVO / CDP 瞬时错误)后,会话会离开"待回复"列表,
#       而 RETRY-QUEUE 只是日志字符串、没有补发循环 ==> 买家永远收不到回复。
# 设计: 失败即入表; 每轮扫描前先处理到期的补发项; 成功或超限即出表。
# 存储: data\pending_retry.json (运行数据根, 不入库)
# 取舍(对应 spec §8-2 R1/R7): 补发优先复用既有 Invoke-ConvoItem(完整流程:会话名校验/去重/
#       生成/禁词双检/SENT_OK 记账),因为"重新抓消息重新生成"正是该函数的语义,天然满足 D5;
#       代价是若原发送其实已成功(仅清空校验未通过),补发会重发一次 ==> 见 REPORT 残留风险。
#       补发与正常路径共用同一把去重键 Get-DedupKey, 不引入第二套键。
function Get-RetryFile { Join-Path (Get-SkillPath "data") "pending_retry.json" }

function Read-RetryTable {
    $f = Get-RetryFile
    # [2026-10-05 spec §5-2] 统一读取入口：区分缺失/空/合法/损坏；损坏按既有策略记日志后当空表处理
    #   （补发表是可重建的队列，不是去重账本；账本侧仍是"损坏 ⇒ 不发送"）。
    $doc = Read-JsonDocument $f
    if ($doc.Status -eq 'missing') { return @{ version = 1; items = @{} } }
    if ($doc.Status -eq 'empty' -or $doc.Status -eq 'corrupt') {
        Write-Log ("RETRY-TABLE-READ-" + $doc.Status.ToUpperInvariant() + ": " + $doc.Error + " (treated as empty)")
        return @{ version = 1; items = @{} }
    }
    try {
        $j = $doc.Data
        $t = @{ version = 1; items = @{} }
        if ($j -and $j.items) {
            foreach ($p in $j.items.PSObject.Properties) {
                $hasDedup = ($p.Value.PSObject.Properties.Name -contains 'dedupKey')
                $hasPageOk = ($p.Value.PSObject.Properties.Name -contains 'pageConfirmed')
                $t.items[$p.Name] = @{
                    key = [string]$p.Value.key; reason = [string]$p.Value.reason
                    firstAt = [string]$p.Value.firstAt; lastAt = [string]$p.Value.lastAt
                    tries = [int]$p.Value.tries; nextAt = [string]$p.Value.nextAt
                    # [2026-10-06] 对账证据：发送当时算出的去重键 + 页面侧发送动作是否已完成
                    dedupKey = $(if ($hasDedup) { [string]$p.Value.dedupKey } else { '' })
                    pageConfirmed = [bool]$(if ($hasPageOk) { $p.Value.pageConfirmed } else { $false })
                }
            }
        }
        return $t
    } catch {
        Write-Log ("RETRY-TABLE-READ-FAIL: " + $_.Exception.Message + " (treated as empty)")
        return @{ version = 1; items = @{} }
    }
}

function Save-RetryTable($t) {
    $f = Get-RetryFile
    try {
        $o = @{}
        foreach ($k in $t.items.Keys) {
            $v = $t.items[$k]
            $o[$k] = @{ key=$v.key; reason=$v.reason; firstAt=$v.firstAt; lastAt=$v.lastAt; tries=$v.tries; nextAt=$v.nextAt; dedupKey=[string]$v.dedupKey; pageConfirmed=[bool]$v.pageConfirmed }
        }
        # [2026-10-05 spec §5-2] 原子替换 + 备份（原来的 WriteAllText 直接覆盖，中断会留下半个 JSON）
        $w = Write-JsonDocumentAtomic -Path $f -Data @{ version = 1; items = $o } -Depth 6
        if (-not $w.Ok) { Write-Log ("RETRY-TABLE-WRITE-FAIL: " + $w.Error) }
    } catch { Write-Log ("RETRY-TABLE-WRITE-FAIL: " + $_.Exception.Message) }
}

# 退避: 1, 2, 5, 15, 30 分钟后第 6 次放弃(共 5 次补发机会)
function Get-RetryBackoffMin([int]$tries) {
    $seq = @(1, 2, 5, 15, 30)
    if ($tries -ge $seq.Count) { return -1 }   # -1 = 放弃
    return $seq[$tries]
}

function Add-PendingRetry([string]$key, [string]$reason, [string]$DedupKey = '', [bool]$PageConfirmed = $false) {
    $t = Read-RetryTable
    $sk = $key.ToLower()
    $now = Get-Date
    $r = $reason
    if ($r.Length -gt 200) { $r = $r.Substring(0, 200) }
    if ($t.items.ContainsKey($sk)) {
        $it = $t.items[$sk]
        $it.tries = [int]$it.tries + 1
        $it.lastAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $it.reason = $r
        # 已记录过的对账证据不被无参重排覆盖（去重键只在为空时接受新值；页面确认只增不减）
        if ($DedupKey -and -not [string]$it.dedupKey) { $it.dedupKey = $DedupKey }
        if ($PageConfirmed) { $it.pageConfirmed = $true }
    } else {
        $it = @{ key=$key; reason=$r; firstAt=$now.ToString('yyyy-MM-dd HH:mm:ss')
                 lastAt=$now.ToString('yyyy-MM-dd HH:mm:ss'); tries=0; nextAt=$now.ToString('yyyy-MM-dd HH:mm:ss')
                 dedupKey=[string]$DedupKey; pageConfirmed=[bool]$PageConfirmed }
    }
    $bk = Get-RetryBackoffMin ([int]$it.tries)
    if ($bk -lt 0) {
        $t.items.Remove($sk)
        Write-Log ("RETRY-GIVEUP $key after $($it.tries) tries: $r")
    } else {
        $it.nextAt = $now.AddMinutes($bk).ToString('yyyy-MM-dd HH:mm:ss')
        $t.items[$sk] = $it
        Write-Log ("RETRY-QUEUED $key tries=$($it.tries) next=$($it.nextAt) reason=$r")
    }
    Save-RetryTable $t
}

function Remove-PendingRetry([string]$key) {
    $t = Read-RetryTable
    $sk = $key.ToLower()
    if ($t.items.ContainsKey($sk)) {
        $t.items.Remove($sk)
        Save-RetryTable $t
        Write-Log "RETRY-CLEARED $key"
    }
}

# ===== [2026-10-06 生产观察] 补发对账闭环 =====
# 背景：收据要求"发送前后唯一新增事件"的绑定；当会话消息缺少稳定平台身份（DOM 侧只有打印时间、
#   且有图片/系统行没有时间）时，收据自证失败，发送被记为 UNKNOWN（账本不推进、补发项排队）。
#   实测：页面已 SENT_OK 且会话随即离开待回复列表，但补发项只能反复得到 NOT_IN_LIST 直到放弃。
# 判据（可自证的部分）：页面侧发送动作已完成（FILLED|CLICKED|SENT_OK 三段）+ 会话已不在待回复
#   列表。两者同时成立才当作"已送达"的对账证据；仅有 NOT_IN_LIST（可能被人工接走/买家撤回）不够。
# 边界：只推进**去重账本**（发送当时算出的同一把键），**不伪造**已确认收据——缺事件身份时收据保持
#   未发布（spec §5.1），对账结论只作为日志证据留痕。
function Test-PageConfirmedSendResult([string]$SendRaw) {
    if (-not $SendRaw) { return $false }
    return (($SendRaw -match '(?i)\bFILLED\b') -and ($SendRaw -match '(?i)\bCLICKED\b') -and ($SendRaw -match '(?i)\bSENT_OK\b'))
}
function Test-ReconciledDeliveryEvidence([string]$Reason, [bool]$PageConfirmed, [string]$DedupKey) {
    if (-not $DedupKey) { return $false }
    if (-not $PageConfirmed) { return $false }
    return (Test-PageConfirmedSendResult $Reason)
}
function Complete-ReconciledDelivery($ctx, [string]$skey, [string]$DedupKey, [string]$Evidence) {
    if (-not $DedupKey) { return $false }
    Set-StateHash $ctx $skey $DedupKey
    $written = ''
    if ($ctx.state -and $ctx.state.replied) {
        if ($ctx.state.replied -is [System.Collections.IDictionary]) { $written = [string]$ctx.state.replied[$skey] }
        elseif ($ctx.state.replied.PSObject.Properties.Name -contains $skey) { $written = [string]$ctx.state.replied.$skey }
    }
    if ($written -ne $DedupKey) {
        Write-Log ("RETRY-RECONCILE-LEDGER-WRITE-FAIL " + $skey + " key=" + $DedupKey + " (ledger not advanced)")
        return $false
    }
    Write-Log ("RETRY-RECONCILED-DELIVERED " + $skey + " key=" + $DedupKey + " evidence=" + $Evidence + " receipt=unpublished(no-event-identity)")
    return $true
}

# =============================================================================================
# [2026-10-07 spec §3.1/§3.2/§5/§6] 统一来源门禁、事件级调查与独立提醒
#
# 边界：
#   * 规则集默认是"空的"（没有任何标签被 S0 证实独占）⇒ 标签单独出现仍是 unknown；
#     真实规则只能由 config 的 source_rules 段写入。
#   * 门禁只阻断**当前相关我方尾部**那个确切事件，久远 unknown 不无限封锁（spec §5 未知来源第 4 条）。
#   * 调查提醒独立于"买家回复成功"分支，页面阻断时也提醒；一次成功提醒不因重复扫描重发。
#   * 未加载新库（旧测试按 AST 抽取单个函数）时，全部入口退回旧判据，行为逐字不变。
# =============================================================================================
$script:monitorSourceRules = $null

function Get-MonitorSourceRules {
    if ($script:monitorSourceRules) { return $script:monitorSourceRules }
    $rules = $null
    # 显式安装的共享判定上下文（配置驱动的生产路径不设置它；夹具/测试用它注入"已验证规则"）。
    if (Get-Command Get-MessageSourceActiveRules -ErrorAction SilentlyContinue) {
        try {
            $active = Get-MessageSourceActiveRules
            # 只有"确实带了已验证规则"的上下文才覆盖配置（空规则集不算显式安装）。
            if ($active -and [int]$active.VerifiedCount -gt 0) { $rules = $active }
        } catch { $rules = $null }
    }
    if (-not $rules -and (Get-Command Get-MessageSourceRuleSetFromConfig -ErrorAction SilentlyContinue)) {
        try { $rules = Get-MessageSourceRuleSetFromConfig -Config $script:skillCfg } catch { $rules = $null }
    }
    if (-not $rules -and (Get-Command Get-MessageSourceRuleSet -ErrorAction SilentlyContinue)) { $rules = Get-MessageSourceRuleSet }
    $script:monitorSourceRules = $rules
    return $script:monitorSourceRules
}

function Get-MonitorSourceConfirmed([string]$Buyer) {
    if (-not (Get-Command Get-InvestigationSourceCorrections -ErrorAction SilentlyContinue)) { return @{} }
    try { return (Get-InvestigationSourceCorrections -Buyer $Buyer) } catch { return @{} }
}

# 发送闸门（四态）。新库不可用时退回旧 Get-HumanInterjectionGateEx，调用点无需分别处理。
function Get-MonitorSourceGate([string[]]$Lines, $SentMatches = $null, [string]$Buyer = '') {
    if (Get-Command Get-MessageSourceGate -ErrorAction SilentlyContinue) {
        $confirmed = @{}
        if ($Buyer) { $confirmed = Get-MonitorSourceConfirmed $Buyer }
        try {
            return (Get-MessageSourceGate -Lines $Lines -SentMatches $SentMatches -Rules (Get-MonitorSourceRules) -Confirmed $confirmed)
        } catch {
            Write-Log "SOURCE-GATE-ERR: $($_.Exception.Message) - falling back to legacy gate"
        }
    }
    return (Get-HumanInterjectionGateEx -lines $Lines -SentMatches $SentMatches)
}

# 建立/更新事件级调查。身份无法唯一建立时走显式歧义槽位（不伪造唯一关联）。
function New-MonitorInvestigation {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$EventRef = '',
        [string]$EventRefQuality = '',
        [string]$AttemptId = '',
        [object[]]$EvidenceRefs = @(),
        [string]$Detail = '',
        [string]$AmbiguitySlot = ''
    )
    $res = [pscustomobject]@{ Ok = $false; Id = ''; Created = $false; Error = 'no-investigation-store' }
    if (-not (Get-Command New-OrUpdate-Investigation -ErrorAction SilentlyContinue)) { return $res }
    try {
        $r = New-OrUpdate-Investigation -Buyer $Buyer -Kind $Kind -EventRef $EventRef -EventRefQuality $EventRefQuality -AttemptId $AttemptId -EvidenceRefs $EvidenceRefs -Detail $Detail -AmbiguitySlot $AmbiguitySlot
        $res.Ok = [bool]$r.Ok
        $res.Created = [bool]$r.Created
        $res.Error = [string]$r.Error
        if ($r.Record) { $res.Id = [string]$r.Record.id }
    } catch {
        $res.Error = $_.Exception.Message
    }
    return $res
}

# 未知来源等待到期 ⇒ 固定调查（超时不是来源证明，不把 unknown 改成 project）。
function New-SourceUnknownInvestigation {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        $Gate = $null,
        [string]$Conflict = ''
    )
    $kind = 'source_unverified'
    $detail = 'five-minute window elapsed without exclusive source evidence'
    if ($Conflict -or ($Gate -and [string]$Gate.Reason -eq 'source-conflict')) {
        $kind = 'source_conflict'
        $detail = 'strong source evidence conflicts for this exact event'
    }
    $ref = ''
    $quality = ''
    if ($Gate) {
        $ref = [string]$Gate.HoldEventRef
        if (-not $ref) { $ref = [string]$Gate.TailIdentity }
        $quality = [string]$Gate.TailIdentityQuality
    }
    if (-not $ref) { $quality = 'ambiguous' }
    $evidence = @()
    if ($Gate -and $Gate.SourceEvidence) { $evidence += [string]$Gate.SourceEvidence }
    if ($Conflict) { $evidence += [string]$Conflict }
    return (New-MonitorInvestigation -Buyer $Buyer -Kind $kind -EventRef $ref -EventRefQuality $quality -EvidenceRefs $evidence -Detail $detail -AmbiguitySlot 'no-unique-event-ref')
}

# 独立提醒扫描：不依赖任何一次回复是否成功；通道失败不改写通知状态。
function Invoke-MonitorInvestigationSweep {
    param([int]$Max = 5, [switch]$DryRun)
    if (-not (Get-Command Invoke-InvestigationNotificationSweep -ErrorAction SilentlyContinue)) { return @() }
    try {
        return @(Invoke-InvestigationNotificationSweep -Sender { param($Text) Send-WecomMessage $Text } -Max $Max -DryRun:$DryRun)
    } catch {
        Write-Log "INVESTIGATION-SWEEP-ERR: $($_.Exception.Message)"
        return @()
    }
}

# [复核 R4/R8] 发送尝试的生产恢复入口：对"收据已证明送达但两段持久化未完成"的尝试重跑真实写入
#   （sent_records + 去重账本），并回读核验。失败不改写状态、不释放闸门，留待人工。
#   R8 起扫描范围不再只看 persistence_pending：收据保存后立刻中断留下的 receipt_verified
#   （persistence.sentRecord/ledger 仍为 pending）同样会被这里补齐，否则那条收据永远不会进账本。
function Invoke-MonitorSendAttemptRecovery {
    param([int]$Max = 5)
    $res = [pscustomobject]@{ Ok = $true; Results = @(); Error = '' }
    if (-not (Get-Command Invoke-SendAttemptPersistenceRecovery -ErrorAction SilentlyContinue)) { return $res }
    try {
        $r = Invoke-SendAttemptPersistenceRecovery -Max $Max
        if ($r) { $res.Results = @($r.Results); $res.Error = [string]$r.Error }
    } catch {
        $res.Ok = $false
        $res.Error = $_.Exception.Message
        Write-Log "SEND-ATTEMPT-RECOVERY-ERR: $($_.Exception.Message)"
    }
    return $res
}

# 保留策略：活跃调查与它们依赖的证明不被剪枝丢弃。
function Invoke-MonitorInvestigationRetention {
    if (-not (Get-Command Invoke-InvestigationRetention -ErrorAction SilentlyContinue)) { return $null }
    try { return (Invoke-InvestigationRetention) } catch { Write-Log "INVESTIGATION-RETENTION-ERR: $($_.Exception.Message)"; return $null }
}

# [2026-10-05 spec §5-4] 发送结果未知时的对账：先读会话，确认"新的我方消息"是否真的出现。
# 返回 @{ Status = 'confirmed' | 'absent' | 'unverified'; Detail }
#   confirmed ⇒ 消息确实已发出（可以记成功，不需要重试）
#   absent    ⇒ 会话里看不到这条消息（可以按失败处理）
#   unverified⇒ 读不到/顺序不可信/我方新消息内容不符 ⇒ 不据此补发，交给补发表的退避与人工
# =============================================================================================
# [2026-10-05 spec §3.2 第 1 条] 编排顺序：事实/业务决策 → **幂等创建或更新本轮任务** →
#   回读持久化结果与 ActionEvidence → 生成/重写/回退 → 最终复核 → 发送 → 只推进发送相关状态。
#
# 为什么必须在生成之前：任务存在**不依赖**回复发送成功，而"我们会直接向供应商核实"这类计划
#   措辞必须先有落盘任务才允许出现。旧编排把任务创建放在 SENT_OK 之后，于是生成时的
#   ActionEvidence 永远是空的 ⇒ 联系计划被自己的证据校验拦下 ⇒ 回退成让客户自己提供尺寸。
#
# 纯决策与生成器仍然不写业务状态：写状态的是本函数（编排层），生成器只消费返回的 ActionEvidence。
# =============================================================================================
function Get-TaskContextForConvo($Conversation, [string]$BuyerKey, [string]$ConvoKey, $Facts = $null) {
    $out = [pscustomobject]@{
        Needed = $false; TodoKind = ''; Created = $false; Updated = $false; StoreOk = $true
        TaskId = ''; TaskStatus = ''; SupplierKey = ''; SupplierContact = ''; SupplierContactSource = ''
        MissingFields = @(); Error = ''; Evidence = $null
        # [F4] 落盘身份的完整证据面：规范化任务类型、供应商身份、回读匹配结论与更新时间。
        TaskKind = ''; SupplierIdentity = ''; EvidenceMatch = $true; UpdatedAt = ''
        # [2026-10-05 第三轮 spec §4.1 第 4 条] 相关任务选择的结论：多候选无明确关联 ⇒ ambiguous。
        Ambiguous = $false; SelectionReason = ''
    }
    try {
        if (-not $Facts) { $Facts = Get-ConversationFacts $Conversation }
        # 探查用的决策：ActionEvidence 显式为空，只用来问"本轮需要哪类任务"。
        $probeRuntime = New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc (Get-ReplyClockUtc)
        $pre = Get-ReplyDecision -Conversation $Conversation -Facts $Facts -Rules $null -RuntimeContext $probeRuntime -ActionEvidence (New-ActionEvidence -Values $null)
        $kind = ''
        if ($pre) { $kind = [string]$pre.TodoKind }
        # [2026-10-05 spec §3.2 第 4 条] 供应商核实是**闭环**：一旦本会话已经存在未完成的
        #   供应商任务（awaiting_contact / pending_human），本轮出现供应商联系方式就必须更新它，
        #   哪怕本轮场景已经变成 details_given（决策不再返回 supplier_handoff）。
        #   没有这一条，"补充联系人后更新同一任务"永远不会发生，任务会永久停在 awaiting_contact。
        $supContact = Get-SupplierContactFromConversation -Conversation $Conversation -Facts $Facts
        $selectedOpen=Select-RelatedHumanTask -Buyer $ConvoKey -Kind supplier_verification -Conversation $Conversation
        $openSupplierTask=$null;if($selectedOpen.Selected -and $selectedOpen.TaskStatus -in $script:HumanTaskOpenStatuses){$openSupplierTask=@(Get-HumanTaskList -Buyer $ConvoKey -TaskId $selectedOpen.TaskId)[0]}
        if(-not $openSupplierTask -and $supContact.Contact){$openSupplierTask=Get-SupplierContactCompletionTask $ConvoKey $supContact.Contact}
        $hasNewSupplierContact = [bool]($supContact.Contact)
        $needsSupplierUpdate = ($hasNewSupplierContact -and $null -ne $openSupplierTask)
        if (-not $kind -and $needsSupplierUpdate) { $kind = 'supplier_handoff' }
        $out.TodoKind = $kind
        if (-not $kind) {
            # [2026-10-05 第三轮 spec §4.1 第 1/4/5 条] 没有本轮明确任务类型时**绝不**退回"该买家最近一条待办"：
            #   fulfillment_status / quote_status 之类的会话级待办不能授权任何供应商动作。
            #   只有当当前业务流程与该供应商身份明确相关、且候选唯一时才选择它（确切回读）。
            $sel = Select-RelatedHumanTask -Buyer $ConvoKey -Kind 'supplier_verification' -SupplierIdentity $(if($supContact.Contact){(Get-SupplierIdentity $supContact.Contact).Key}else{''}) -Conversation $Conversation
            $out.Ambiguous = [bool]$sel.Ambiguous
            $out.SelectionReason = [string]$sel.Reason
            if ($sel.Selected) {
                $out.TaskId = [string]$sel.TaskId
                $out.TodoKind = [string]$sel.Kind
                $out.TaskKind = [string]$sel.Kind
                $out.TaskStatus = [string]$sel.TaskStatus
                $out.SupplierKey = [string]$sel.SupplierKey
                $out.SupplierIdentity = [string]$sel.SupplierKey
                $out.Evidence = Get-ActionEvidenceForTask -Buyer $ConvoKey -TaskId $out.TaskId -Kind $out.TodoKind -SupplierIdentity $out.SupplierKey
                Write-Log ("HUMAN-TASK-RELATED-SELECT " + $ConvoKey + " id=" + $out.TaskId + " kind=" + $out.TodoKind + " reason=" + $sel.Reason)
            } else {
                $out.Evidence = New-ActionEvidence -Values $null
                Write-Log ("HUMAN-TASK-NO-EXACT-REF " + $ConvoKey + " reason=" + $sel.Reason + " candidates=" + [string]$sel.CandidateCount + " ambiguous=" + [string]$sel.Ambiguous + " : no related task, no supplier action is authorized")
            }
            return $out
        }
        $out.Needed = $true
        $missing = @()
        if ($pre -and ($pre.PSObject.Properties.Name -contains 'QuoteMissingFields')) { $missing = @($pre.QuoteMissingFields) }
        $trigger = ''
        if ($pre -and $pre.LatestBuyerText) { $trigger = [string]$pre.LatestBuyerText }
        $triggerId = ''
        $triggerAt = ''
        if ($Conversation -and $Conversation.LatestBuyer) {
            $triggerId = [string]$Conversation.LatestBuyer.StableId
            $triggerAt = [string]$Conversation.LatestBuyer.MessageTsRaw
        }
        $snapshot = $null
        if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'CargoFacts') -and $Facts.CargoFacts) {
            $snap = [ordered]@{ ruleVersion = [string]$Facts.CargoFacts.RuleVersion; fields = [ordered]@{} }
            foreach ($f in @($Facts.CargoFacts.Fields)) {
                if (-not $f) { continue }
                $snap.fields[[string]$f.Key] = [ordered]@{ value = [string]$f.Value; unit = [string]$f.Unit; scope = [string]$f.Scope; status = [string]$f.Status }
            }
            $snapshot = $snap
        }
        if ($kind -eq 'supplier_handoff' -or $kind -eq 'supplier_verification') {
            $sup = Get-SupplierContactFromConversation -Conversation $Conversation -Facts $Facts
            $out.SupplierContact = [string]$sup.Contact
            $out.SupplierContactSource = [string]$sup.Source
            $tk = New-OrUpdate-SupplierVerificationTask -Buyer $ConvoKey -MissingFields $missing -SupplierContact ([string]$sup.Contact) -TriggerMessage $trigger -FactsSnapshot $snapshot -TriggerMessageId $triggerId -TriggerAt $triggerAt -Source ([string]$sup.Source)
            $out.Created = [bool]$tk.Created
            $out.Updated = [bool]$tk.Updated
            $out.StoreOk = [bool]$tk.StoreOk
            if ($tk.Task) {
                $out.TaskId = [string]$tk.Task.id
                $out.TaskStatus = [string]$tk.Task.status
                $out.SupplierKey = [string]$tk.Task.supplierKey
                $out.SupplierIdentity = [string]$tk.Task.supplierKey
                $out.UpdatedAt = [string]$tk.Task.updatedAt
            }
        } else {
            $tk = New-OrUpdate-HumanTask -Buyer $ConvoKey -Kind $kind -TriggerMessage $trigger -MissingFields $missing -FactsSnapshot $snapshot -Status 'pending_human'
            $out.Created = [bool]$tk.Created
            $out.Updated = [bool]$tk.Updated
            $out.StoreOk = [bool]$tk.StoreOk
            if ($tk.Task) { $out.TaskId = [string]$tk.Task.id; $out.TaskStatus = [string]$tk.Task.status }
        }
        $out.MissingFields = @($missing)
        # 回读持久化结果：ActionEvidence 必须来自真的落盘任务，而不是本函数的内存对象。
        # [F4 §6.1 第 2/3 条] 按**确切 TaskId + 买家 + 规范化任务类型 + 供应商身份**回读；
        #   缺确切任务时不退回"该买家最近一条"，宁可不给联系计划授权。
        #   任务落盘失败（StoreOk=false）时**不**制造假证据：Evidence 留空，
        #   决策侧因此看不到 TodoPersisted ⇒ 措辞被拦下。
        if ($out.StoreOk -and $out.TaskId) {
            $exact = Get-ActionEvidenceForTask -Buyer $ConvoKey -TaskId $out.TaskId -Kind $kind -SupplierIdentity $out.SupplierKey
            if ($exact -and $exact.TaskExists -and $exact.ExactTaskMatch) { $out.Evidence = $exact }
            else {
                Write-Log ("HUMAN-TASK-EVIDENCE-MISS " + $ConvoKey + " kind=" + $kind + " id=" + $out.TaskId + " supplier=" + $out.SupplierKey + " : persisted task could not be read back with the same identity - no plan authorization")
                $out.Evidence = New-ActionEvidence -Values $null
                $out.EvidenceMatch = $false
            }
            if ($out.Evidence -and $out.Evidence.PSObject.Properties.Name -contains 'SupplierIdentity') { $out.SupplierIdentity = [string]$out.Evidence.SupplierIdentity }
        } else {
            $out.Evidence = New-ActionEvidence -Values $null
        }
        if (-not $out.StoreOk) {
            Write-Log "HUMAN-TASK-STORE-FAIL $ConvoKey kind=$kind : task store write failed - wording must stay neutral and no contact promise is allowed"
        }
    } catch {
        $out.Error = $_.Exception.Message
        $out.StoreOk = $false
        Write-Log "HUMAN-TASK-ERR $BuyerKey : $($_.Exception.Message)"
    }
    return $out
}

function Resolve-UnknownSendResult([string]$key,[string]$text,$Before=$null) {
    return (Confirm-OneTalkOutboundMessage -buyer $key -text $text -Before $Before)
}

# [2026-10-05 spec §5-4] 补发前的对账：会话里最后说话的是我方（机器人或人工）⇒ 买家诉求已被答复，
# 补发等于重复打扰。返回 'ANSWERED' | 'PENDING' | 'UNKNOWN'。
function Test-PendingReplyObsolete([string]$key) {
    try {
        $convo = Open-ConvoAndGetMessages $key
        if ($convo -is [string]) { return 'UNKNOWN' }
        $list = ConvertTo-MessageList $convo.msgs $key
        if ($list.Anomaly) { return 'UNKNOWN' }
        $msgs = @($list.Messages)
        if ($msgs.Count -eq 0) { return 'UNKNOWN' }
        if ($msgs[$msgs.Count - 1].Role -eq 'me') { return 'ANSWERED' }
        return 'PENDING'
    } catch { return 'UNKNOWN' }
}

# [Phase3] 补发单个会话: 重新抓待回复列表 ->
#   在列表内  => 走既有 Invoke-ConvoItem 完整流程(会话名校验/去重/生成/双检/SENT_OK)
#   不在列表内 => 'NOT_IN_LIST', 不发(避免对已人工处理的会话误发)
# 注意: 本函数自身不发送, 一律经由 Invoke-ConvoItem -> Send-OneTalkMessage(内含会话名校验, D4)。
function Send-PendingRetry($ctx, [string]$key) {
    # Pending membership decides eligibility; a platform reception is not a delivery receipt.
    $nkey = Get-PendingConversationName $key
    $snapRaw = Get-Snapshot
    if ($snapRaw -notmatch '^\[') { return "SNAP_FAIL ($snapRaw)" }
    $snap = $null
    try { $snap = $snapRaw | ConvertFrom-Json } catch { return "SNAP_PARSE_FAIL" }
    $target = $null
    foreach ($it in @($snap)) {
        if (-not $it.name) { continue }
        $cand = Get-PendingConversationName ([string]$it.name)
        if ($cand -eq $nkey) { $target = $it; break }
    }
    if (-not $target) { return 'NOT_IN_LIST' }
    Write-Log "RETRY-INLIST $key -> reusing full convo pipeline"
    Invoke-ConvoItem $ctx $target
    return 'PROCESSED'
}

# 会话处理：待回复 -> 精确读取 -> 防重复 -> 自然生成 -> 发送前复核 -> 送达证据。
# $ctx 为可写上下文引用: state/openCooldown/skipCooldown/noReplyPreview/sendFailCount/failAlertAt/lastActivity
function Invoke-ConvoItem($ctx, $item, [int]$CycleNo = 2) {
    $key = $item.name.Trim()
    $skey = Get-StateKey $key
    # [2026-10-05 spec §3.2 第 1 条] 本轮任务证据的重置点：每次进入会话都从零开始，
    #   避免上一个会话的 ActionEvidence 泄漏到这一轮（那会让措辞校验被错误的证据放行）。
    $script:turnActionEvidence = $null
    # [F4 §6.1 第 4 条] 本轮任务的**确切身份**（会话级绑定，绝不跨会话共享）。
    #   发送前用同一个 TaskId/类型/供应商身份回读，任务关闭或归属变化时弃稿。
    $script:turnTaskRef = $null
    # [2026-10-05 第三轮 spec §2/§8.3] 每轮重置组合器来源区间（不跨会话泄漏）。
    $script:lastReplyComposition = $null
    $script:turnRewrites=0
    Write-Log "PROCESS convo from pending-list: $($key) | $($item.preview)"

    # [2026-10-05 spec §6.2] 页面锁只覆盖"读消息"这一段。生成期间不持锁（见下方 LOCK-RELEASED-FOR-GENERATION），
    #   发送前重新取锁并复核。同进程重入由 lib\lock.ps1 处理，因此上一条会话若在早退路径上仍持锁，这里不会自锁。
    $script:lockHoldStart = Get-Date
    if (-not (Get-AppLock 'onetalk-write' 5)) {
        Write-Log "LOCK-BUSY $($key): onetalk-write held by another process, deferring this conversation"
        return
    }
    Write-Log "PAGE-LOCK-ACQUIRED phase=read convo=$($key)"
    # ===== [SPEC §4.2-G2 2026-09-27] 发对人校验 ⇒ 整轮中止 =====
    # 真正的比对点在 **发送前一步**: lib\send.ps1::Send-OneTalkMessage 的会话名/标题校验(L70-73),
    #   它每次发送都会执行, 返回 `ABORT_WRONG_CONVO (expected=.., current=..)`。
    # 本函数消费该结果(见下方发送回执分支): 一旦出现 ⇒ 置 $script:roundHalt, 本轮剩余会话一律不处理。
    # 依据 §2.1/§3-R6: 11:49:35 实测该闸门被触发时旧行为只报错、继续处理后续会话(前 7 条已经发出去)。
    if ($script:roundHalt) { return }
    # A1 新询盘通知已下移 —— 见下方"确认买家有新消息"处 [FIX-ALERTNOISE 2026-09-26]。
    #   旧位置的问题：只看"会话在不在待回复列表 + 该买家 24h 内是否通知过"，
    #   **完全不看买家有没有说新话** ⇒ 已读会话（预览往往还是我方最后发出那句）也照发通知。
    #   实测事故 2026-09-26 18:34：74 秒内连发 9 条，用户判定为"乱发"。
    #   故移到 Test-ShouldReply 判定之后：只有"账本证明不了已经回过这条"才通知。
    # A5 人工接管白名单(NO-REPLY):名单买家不自动回复(LLM/规则/图片模板/QUICK 全跳过,不发送);
    # 只读留痕(买家档案+msgs 快照)且不写 replied 去重状态 → 移出名单后自动恢复正常;
    # 新消息仍由上方 A1 提醒主人(24h 节流);预览不变时后续轮免打扰跳过
    if (Test-NoReplyBuyer $key) {
        if ($ctx.noReplyPreview.ContainsKey($key) -and $ctx.noReplyPreview[$key] -eq $item.preview) {
            Write-Log "TEMP-SKIP $($key): manual-override whitelist (preview unchanged, no auto reply)"
            return
        }
        $nrConvo = Open-ConvoAndGetMessages $key
        if ($nrConvo -is [string]) {
            Write-Log "NO-REPLY-SNAP-FAIL $($key): $nrConvo"
            return
        }
        if ($nrConvo.profile) { Save-BuyerProfile $skey $nrConvo.profile }
        $nrLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
        Add-Content -Path $nrLog -Value ("# BUYER: " + $key) -Encoding UTF8
        Add-Content -Path $nrLog -Value (Remove-AttachmentMarkers $nrConvo.msgs) -Encoding UTF8
        $ctx.noReplyPreview[$key] = $item.preview
        Write-Log "NO-REPLY-SNAPSHOT $($key): manual-override whitelist, snapshot kept, no auto reply"
        return
    }
    # Pending is authoritative; previous source/time caches cannot postpone its read.
    if ($ctx.skipCooldown.ContainsKey($key)) { $ctx.skipCooldown.Remove($key) }
    if ($ctx.openCooldown.ContainsKey($key)) { $ctx.openCooldown.Remove($key) }
    # P2.1a:打开+校验+抓消息合并为一次 eval(原 Open-Convo + 轮询 + Get-AllMessages 共 5 次调用)
    $convo = Open-ConvoAndGetMessages $item.name
    if ($convo -is [string]) {
        # 打开失败/超时:切回待回复标签重试一次
        Write-Log "RETRY-OPEN $($key): $convo - switching to pending tab and retry"
        Switch-ToPendingTab | Out-Null
        Start-Sleep -Seconds 3
        $convo = Open-ConvoAndGetMessages $item.name
    }
    if ($convo -is [string]) {
        Write-Log "SKIP $($key): cannot open convo ($convo)"
        $null=New-PendingReplyHumanTask -Buyer $key -Reason ([string]$convo)
        return
    }
    $ctx.openCooldown.Remove($key)
    # The merged opener can return a nonmatching header after its timeout. Refuse that page
    # before normalization/evidence; final send identity and round-halt safeguards remain.
    $openedName = ([string]$convo.name).Trim()
    if (-not $openedName -or (Get-PendingConversationName $openedName) -cne (Get-PendingConversationName $key)) {
        $script:roundHalt = $true
        Write-Log "ABORT_WRONG_CONVO $($key): opened=$openedName round-halt before message evidence"
        return
    }
    $msgsRaw = $convo.msgs
    # ===== [SPEC 4.1 / 5 2026-10-03] Normalize order + identity in ONE place, BEFORE any consumer
    # looks at the messages. The raw DOM order used to be handed to three consumers that disagreed
    # about which end was newest: lib\msg_source.ps1 treats the TAIL as newest, the should-reply
    # hash below used the LAST buyer line, but attachments were read from index 0 and the prompt
    # claimed index 0 was newest. lib\msg_norm.ps1 settles the direction from the per-message
    # item-base-info time marked @@MT, normalizes to chronological ASCENDING (oldest first), and
    # flags an explicit anomaly instead of guessing when the evidence contradicts itself.
    $msgList = ConvertTo-MessageList $msgsRaw $key
    $orderLine = "MSG-SCHEMA $($key) v=$($msgList.Schema) msgs=$(@($msgList.Messages).Count) buyers=$($msgList.BuyerCount) order=$($msgList.Order.Reason) confident=$($msgList.Order.Confident) skipped=$(@($msgList.Skipped).Count) anomaly=$($msgList.Anomaly)"
    Write-Log $orderLine
    if ($msgList.Anomaly) {
        $null=New-PendingReplyHumanTask -Buyer $key -Reason ('message-order-unverified:'+$msgList.Order.Reason)
        Write-Log "MSG-ORDER-UNVERIFIED $($key) reason=$($msgList.Order.Reason) stamped=$($msgList.Order.TimestampedCount) - this conversation is blocked before generation/send"
        return
    }
    if (-not $msgList.LatestBuyer) {
        $null=New-PendingReplyHumanTask -Buyer $key -Reason ('no-actionable-buyer:'+$msgList.ReplyBlockReason)
        Write-Log "MSG-INPUT-SKIP $($key) reason=$($msgList.ReplyBlockReason) - no actionable latest buyer message"
        return
    }
    $replyConversation = $msgList
    $orderedRaw = @($msgList.Lines) -join ([string][char]10)
    # B2: attachment markers come from the NEWEST buyer message (the tail), never from index 0.
    $attImages = @(); $attFile = $null
    $newestBuyer = $msgList.LatestBuyer
    if ($newestBuyer) {
        if ($newestBuyer.HasImage) { $attImages = @(@($newestBuyer.ImageUrls) | Select-Object -First 3) }
        if ($newestBuyer.HasFile) { $attFile = @{ name = $newestBuyer.FileName; url = $newestBuyer.FileUrl } }
        # Enhanced path: the newest message points at an attachment in words but carries no marker,
        # so walk BACKWARDS from the newest buyer message (never forwards from the oldest).
        if ($attImages.Count -eq 0 -and -not $attFile -and $newestBuyer.Orig -match '(?i)(photo|image|pic|picture|foto|imagen|图片|图|文件|附件|document|attachment|pdf|excel|csv|word)') {
            $bArr = @($msgList.BuyerMessages)
            for ($bi = $bArr.Count - 1; $bi -ge 0; $bi--) {
                $cand = $bArr[$bi]
                if ($cand.HasImage) { $attImages = @(@($cand.ImageUrls) | Select-Object -First 3); break }
                if ($cand.HasFile) { $attFile = @{ name = $cand.FileName; url = $cand.FileUrl }; break }
            }
        }
    }
    $msgs = Remove-AttachmentMarkers $orderedRaw
    # P3.4 保存买家档案(国家/注册时间等,PII 仅存本机 data\buyers\)
    if ($convo.profile) { Save-BuyerProfile $skey $convo.profile }
    $msgLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
    Add-Content -Path $msgLog -Value ("# BUYER: " + $key) -Encoding UTF8
    Add-Content -Path $msgLog -Value $msgs -Encoding UTF8
    # Structural noise has already been removed; never drop a real message by a body keyword.
    $cdpLines = @($msgList.Lines)
    $lines = $cdpLines
    # ===== [2026-10-07 spec §4-7，复核 R2/R4] 重启对账：这条会话里是否有"点击后中断"的尝试 =====
    #   用**同口径重读**（共享事件抽取，就是本轮读到的这几行）判断那条正文是否真的成了新事件：
    #     唯一新增出站事件且正文一致 ⇒ 有效收据（绑定确切事件，不伪造 ID）；
    #     没有新增出站事件 ⇒ 只是没有证明，保持 pending_confirmation；
    #     多条新增 / 新增了无法建立身份的气泡 ⇒ delivery_ambiguous + 调查。
    #   对账结果直接决定本轮会话级闸门能不能放行，因此必须放在门禁之前。
    if ((Get-Command Invoke-SendAttemptReconciliation -ErrorAction SilentlyContinue) -and (Get-Command Get-SendAttemptsNeedingReconciliation -ErrorAction SilentlyContinue)) {
        try {
            foreach ($pendingAttempt in @(Get-SendAttemptsNeedingReconciliation -Buyer $key)) {
                $reconEvents = @(Get-ConversationEventIndex @($cdpLines))
                $recon = Invoke-SendAttemptReconciliation -AttemptId ([string]$pendingAttempt.attemptId) -Events $reconEvents -ConvoKey $key
                Write-Log ("SEND-ATTEMPT-RECONCILE " + $key + " attempt=" + [string]$pendingAttempt.attemptId + " applied=" + [string]$recon.Applied + " state=" + [string]$recon.DeliveryState + " err=" + [string]$recon.Error + " investigation=" + [string]$recon.InvestigationId)
                # [复核 R8] 对账取得收据**不等于**闭环：把两段账本的实际提交结论也写进日志。
                #   提交失败 ⇒ 保持 persistence_pending + 会话保护（本轮门禁随后会挡住这个会话），
                #   并由每轮扫描的 Invoke-MonitorSendAttemptRecovery 继续幂等补齐。
                if ($recon.Applied) {
                    Write-Log ("SEND-ATTEMPT-RECONCILE-PERSIST " + $key + " attempt=" + [string]$pendingAttempt.attemptId + " ok=" + [string]$recon.PersistenceOk + " complete=" + [string]$recon.PersistenceComplete + " sentRecord=" + [string]$recon.SentRecord + " ledger=" + [string]$recon.Ledger + " blocked=" + [string]$recon.Blocked + " err=" + [string]$recon.PersistError)
                }
            }
        } catch { Write-Log "SEND-ATTEMPT-RECONCILE-ERR $($key): $($_.Exception.Message)" }
    }
    # Accio 影子/读取切换（开关默认关；任何失败自动回退 CDP）。
    # 去重/最新买家消息基准始终取 CDP，避免网关行文本差异导致 hash 突变→重复回复。
    if ($script:accioFlags.shadow -or $script:accioFlags.read) {
        $gwLines = Get-AccioReplyLines $key
        if ($script:accioFlags.shadow) {
            if ($gwLines) { Invoke-AccioShadowCompare $key $cdpLines $gwLines }
            else { Write-Log "ACCIO-SHADOW $($key): gateway unavailable (cdp-only)" }
        }
        if ($script:accioFlags.read) {
            $gwConv = $null
            if ($gwLines) { $gwConv = ConvertTo-MessageList (@($gwLines) -join ([string][char]10)) $key }
            if ($gwConv -and -not $gwConv.Anomaly -and $gwConv.LatestBuyer -and
                $gwConv.LatestBuyer.Orig -ceq $msgList.LatestBuyer.Orig -and
                $gwConv.LatestBuyer.StableId -ceq $msgList.LatestBuyer.StableId -and
                (Test-AccioLinesOverlap $cdpLines $gwLines)) {
                $replyConversation = $gwConv
                $lines = @($gwConv.Lines); Write-Log "ACCIO-READ src=gateway $($key) lines=$(@($gwConv.Lines).Count)"
            } else {
                Write-Log "ACCIO-READ src=cdp $($key) (gateway unavailable or content mismatch)"
            }
        }
    }
    # [SPEC-单出口 2026-09-27] 会话级"整轮中止"标记: 由 G2(发对人失败)置位, 置位后本轮剩余会话一律不处理。
    #   依据 spec §4.2-G2 + §4.4-4(禁止"只跳过该会话、继续处理下一个")。消费点在 Invoke-ScanRound。
    $script:roundHalt = $false
    $buyerMsgs = @($cdpLines | Where-Object { $_ -match '^\[BUYER\]' })
    if ($buyerMsgs.Count -gt 0) {
        # Latest text, attachments and ledger input share the verified CDP latest buyer.
        # A saved ledger hash identifies a previously answered message, never the current one.
        $latestRaw = $newestBuyer.RawLine
        $latest = ($latestRaw -replace '^\[BUYER\] ','')
        if ($latest.Trim().Length -eq 0) {
            Write-Log "SKIP $($key): empty latest message"
            $null=New-PendingReplyHumanTask -Buyer $key -Reason 'empty-buyer-input'
            return
        }
        # Normalizer owns original text and message identity. Do not reparse a filtered
        # legacy line here: it can drop MT-only rows or accidentally hash transport markers.
        $lastBuyerOrig = $newestBuyer.Orig
        $latestClean = $newestBuyer.Text
        # [FIX-DUP 2026-09-25] LLM/规则输入必须剥离 @@OT（否则提示词里会出现 B64 垃圾）
        # [2026-10-07 spec §3.1] @@META/@@MID 是逐条来源元数据，绝不进入模型上下文。
                    $lines = $lines | ForEach-Object { $_ -replace '@@(?:TS|MT|MID|CARD):[^\s]+','' -replace '@@OT:[A-Za-z0-9+/=]+','' -replace '@@META:[A-Za-z0-9+/=_-]+','' }
        Write-Log "Latest buyer msg: $latestClean"
        # Keep HASH|count persistence; evidence, attachments and the write use this CDP latest.
        # [SPEC-单出口 2026-09-27] 判据专用 hash: 必须是**该会话最后一条买家消息**的 hash(同口径: 原文优先)。
        $hLastBuyer = Get-StableHash (Get-NormalizedMsgText $lastBuyerOrig)
        $buyerCount = $msgList.LedgerBuyerCount
        # $newKey 仅用于日志留痕; 真正写账本的是发送成功后下方的 Set-StateHash(同一 hash 与条数)。
        #   条数口径 = 该会话买家消息条数(与 $lastBuyer 同一次抓取), 保证"账本条数 vs 当前条数"可比。
        $newKey = Get-DedupKey (Get-NormalizedMsgText $lastBuyerOrig) $buyerCount
        # ===== [SPEC-待回复列表 2026-09-27 §2] 「是否回复」的唯一出口: Test-ShouldReply =====
        # Pending-list membership triggers handling; identity only prevents duplicate sends.
        $ledgerKey = ''
        if ($ctx.state -and $ctx.state.replied) {
            if ($ctx.state.replied -is [Collections.IDictionary]) { $ledgerKey=[string]$ctx.state.replied[$skey] }
            elseif ($ctx.state.replied.PSObject.Properties.Name -contains $skey) { $ledgerKey=[string]$ctx.state.replied.$skey }
        }
        $ledgerUsableNow=(Test-RepliedStateUsable $ctx.state).Ok
        $attempts=@()
        try { if(Get-Command Get-SendAttempts -ErrorAction SilentlyContinue){$attempts=@(Get-SendAttempts -Buyer $key)} }
        catch { $null=New-PendingReplyHumanTask -Buyer $key -Reason ('send-history-unreadable:'+ $_.Exception.Message); return }
        $alreadyAnswered=Test-PendingBuyerAlreadyAnswered -LatestBuyer $newestBuyer -LedgerKey $ledgerKey -BuyerCount $buyerCount -Attempts $attempts
        $shouldReply=Test-ShouldReply -PendingListAuthoritative -LedgerUsable $ledgerUsableNow -PendingSeenRounds 1 -AlreadyAnswered $alreadyAnswered
        Write-Log "SHOULD-REPLY $($key): Reply=$($shouldReply.Reply) Reason=$($shouldReply.Reason) buyerMsgs=$buyerCount ledgerKey=$ledgerKey"
        if (-not $shouldReply.Reply) {
            if($alreadyAnswered){$null=New-PendingReplyHumanTask -Buyer $key -Reason 'stale-pending-flag: recorded answer already covers this buyer event'}
            Write-Log "PENDING-REPLY-HOLD $($key): $($shouldReply.Reason)"
            return
        } else {
            # A1 new inquiry alert (24h throttle)
            # [FIX-ALERTNOISE 2026-09-26] 移到这里：本分支 = Test-ShouldReply 判"应回" = **账本证明不了
            #   已经回过这条**（新询盘 / 买家真说了新话）。
            #   条件与旧位置逐字相同，只是挪到信息更全的位置 ⇒ 已读/无新消息的会话不再打扰主人。
            #   [FIX-DEDUP2] 补前置: 账本必须可读。本轮开头已保证(不可读则整轮跳过), 此处再挡一道,
            #   避免把"账本读不到"误报成"首次问询"(实测 2026-09-27 00:43 对老买家误发 3 次)。
            $ledgerReadable = (Test-RepliedStateUsable $ctx.state).Ok
            if ($ledgerReadable -and (-not $ctx.state -or -not $ctx.state.replied -or ($ctx.state.replied.PSObject.Properties.Name -notcontains $skey))) {
                Send-NewInquiryAlert $key $item.preview
            } elseif (-not $ledgerReadable) {
                Write-Log "INQUIRY-ALERT-SKIP $key : ledger unreadable, suppressed 'new inquiry' alert (avoid false first-contact alert)"
            }
            $rules = Get-Rules
            $reply = $null
            # Source label is set by the generation adapter; 'NONE' means nothing was produced yet.
            $src = 'NONE'
            $visionSource = ''
            $visionUrls = @()
            $docExtractText = ''
            $attFileName = ''
            # F2(a)/F4:回复轮次开始 —— 起心跳上下文与总预算,并打出第一行 ROUND-* 进度日志
            $roundBudget = $script:replyRoundBudgetSec
            $roundCtx = Start-LlmRound $key $roundBudget
            $attFlag = 'none'
            if ($attFile) { $attFlag = 'file' } elseif (@($attImages).Count -gt 0) { $attFlag = 'img' }
            Write-Log "ROUND-START $($key) attach=$attFlag imgs=$(@($attImages).Count) ctx=$(@($lines).Count) budget=${roundBudget}s"
            # [2026-10-05 spec §6.2] 附件处理与模型生成移出页面锁：锁只保护页面读取（上面）与发送（下面）。
            #   快照身份与"本轮买家输入"在这里固定下来，发送前复核要用同一份基准。
            $snapshotLatestIdentity = [string]$replyConversation.LatestBuyer.StableId
            $snapshotLatestText = [string]$replyConversation.LatestBuyer.Orig
            $snapshotBuyerCount = [int]$replyConversation.BuyerCount
            # ===== [2026-10-05 spec §3.2 第 1 条] 编排顺序：事实/业务决策 → **幂等创建或更新本轮任务**
            #   → 回读持久化结果与 ActionEvidence → 生成/重写/回退 → 最终复核 → 发送。
            #   任务在生成之前落盘，且**不依赖**回复是否发送成功；暂停期间同样可以整理资料。
            # [spec §5.4 第 3 条] 已验证的任务确认资料与买家原话走同一份事实模型。
            $taskFacts = Get-ConversationFacts -Conversation $replyConversation -Buyer $key -WithTaskEvidence
            $taskCtx = Get-TaskContextForConvo -Conversation $replyConversation -BuyerKey $skey -ConvoKey $key -Facts $taskFacts
            if ($taskCtx.Needed) {
                Write-Log "HUMAN-TASK-PRE $($key) kind=$($taskCtx.TodoKind) status=$($taskCtx.TaskStatus) id=$($taskCtx.TaskId) created=$($taskCtx.Created) storeOk=$($taskCtx.StoreOk) contactLen=$($taskCtx.SupplierContact.Length) supplierKey=$($taskCtx.SupplierKey) missing=$((@($taskCtx.MissingFields)) -join ',')"
            }
            $script:turnActionEvidence = $taskCtx.Evidence
            $script:turnTaskRef = [pscustomobject]@{
                TaskId = [string]$taskCtx.TaskId; TaskKind = [string]$taskCtx.TodoKind
                SupplierIdentity = [string]$taskCtx.SupplierIdentity; TaskStatus = [string]$taskCtx.TaskStatus
            }
            $readHoldMs = [int]((Get-Date) - $script:lockHoldStart).TotalMilliseconds
            [void](Release-AppLock 'onetalk-write')
            Write-Log "LOCK-RELEASED-FOR-GENERATION $($key) readHoldMs=$readHoldMs"
            # 0) B5 图片多模态: 下载 → 多模态回复(与提取解耦)
            if ($attImages.Count -gt 0) {
                Write-Log "ROUND-VISION-BEGIN $($key) kind=image n=$($attImages.Count)"
                $dataUrls = @()
                foreach ($u in $attImages) { $du = Get-ImageDataUrl $u; if ($du) { $dataUrls += $du } }
                if ($dataUrls.Count -gt 0) {
                    $visionSource = 'image'
                    $visionUrls = $dataUrls
                    Write-Log "VISION-IMG $($key): $($dataUrls.Count)/$($attImages.Count) image(s) downloaded"
                    $reply = Generate-Reply-LLM $rules $key $latestClean $lines -ImageDataUrls $dataUrls -Conversation $replyConversation
                    if ($reply) { $src = $script:lastReplySource; Write-Log "VISION-REPLY $($key) src=$($src)(multimodal)" }
                    else { Write-Log "VISION-REPLY-FAIL $($key): multimodal LLM returned null" }
                } else {
                    Write-Log "VISION-IMG-FAIL $($key): image download failed"
                }
                Write-Log "ROUND-VISION-END $($key) kind=image elapsed=$(Get-LlmRoundElapsedSec)s got=$([bool]$reply)"
            }
            # 0b) B5 文档: CDP 页面上下文 fetch 优先 → 兜底 PS 下载 → doc-reader → 文本/扫描图
            if (-not $reply -and $attFile) {
                Write-Log "ROUND-VISION-BEGIN $($key) kind=document name=$($attFile.name)"
                $b64 = $null
                if ($attFile.url) { $b64 = Get-DocumentBase64ViaCdp $attFile.url }
                if (-not $b64 -and $attFile.url) { $b64 = Get-DocumentBase64ViaHttp $attFile.url }
                if ($b64) {
                    $docTmp = $null
                    try {
                        $docTmp = Save-DocTempFile $attFile.name ([Convert]::FromBase64String($b64))
                        $docRes = Invoke-DocReader $docTmp 6000 2
                        if ($docRes -and $docRes.ok) {
                            Write-Log "DOC-READ $($key): $($attFile.name) kind=$($docRes.kind) chars=$($docRes.text.Length) images=$(@($docRes.images).Count)"
                            $visionSource = 'document'
                            $attFileName = $attFile.name
                            if ($docRes.kind -eq 'pdf-scan' -and @($docRes.images).Count -gt 0) {
                                $visionUrls = @($docRes.images)
                                $docPrompt = "买家发送了文件《$($attFile.name)》(扫描件, 已渲染为图片)。请结合文件内容回复; 明确可见的重量/尺寸/箱数/单号可确认, 不确定不臆造。"
                                $reply = Generate-Reply-LLM $rules $key $latestClean $lines -ImageDataUrls @($docRes.images) -AttachmentText $docPrompt -Conversation $replyConversation
                                if ($reply) { $src = $script:lastReplySource; Write-Log "VISION-REPLY $($key) src=$($src)(doc-scan)" }
                                else { Write-Log "VISION-REPLY-FAIL $($key): doc-scan LLM returned null" }
                            } else {
                                $docExtractText = $docRes.text
                                $docPrompt = "买家发送了文件《$($attFile.name)》（类型：$($docRes.kind)）：`n" + $docRes.text + "`n请结合文件内容回复；明确可见的重量/尺寸/箱数/单号可确认，不确定不臆造。"
                                $reply = Generate-Reply-LLM $rules $key $latestClean $lines -AttachmentText $docPrompt -Conversation $replyConversation
                                if ($reply) { $src = $script:lastReplySource; Write-Log "VISION-REPLY $($key) src=$($src)(doc)" }
                                else { Write-Log "VISION-REPLY-FAIL $($key): doc LLM returned null" }
                            }
                        } else {
                            Write-Log "DOC-READ-FAIL $($key): $($attFile.name) (fallback to text flow)"
                        }
                    } finally {
                        Remove-DocTemp $docTmp
                    }
                } else {
                    Write-Log "DOC-DOWNLOAD-FAIL $($key): $($attFile.name) (fallback to text flow)"
                }
                Write-Log "ROUND-VISION-END $($key) kind=document elapsed=$(Get-LlmRoundElapsedSec)s got=$([bool]$reply)"
            }
            # 1) Every non-image message goes through the single generation entry point first. That
            #    entry point already contains its own scenario fallback, so a $null return means even
            #    the fallback produced nothing - not merely "the model failed".
            if (-not $reply -and $latestClean -ne '[IMG]') {
                $reply = Generate-Reply-LLM $rules $key $latestClean $lines -Conversation $replyConversation
                if ($reply) { $src = $script:lastReplySource; Write-Log "Reply source: $($src)" }
            }
            # 2) Image-only message -> the scenario fallback for 'attachment_only'. This replaces an
            #    inline 4-language hashtable that duplicated policy wording inside monitor.ps1 and
            #    whose non-English branches were unreachable (Get-ReplyLang is always 'en').
            if (-not $reply -and $latestClean -eq '[IMG]') {
                $imgDecision = $script:lastReplyDecision
                if (-not $imgDecision) {
                    $imgConv = $replyConversation
                    $imgDecision = Get-ReplyDecision -Conversation $imgConv -Facts (Get-ConversationFacts $imgConv) -Rules $rules -ForceScenario 'attachment_only'
                }
                $reply = Get-ScenarioFallback -Decision $imgDecision -Rules $rules
                # Record it so the send-time gate below uses the attachment wording, not a generic one.
                if (-not $script:lastReplyDecision) { $script:lastReplyDecision = $imgDecision }
                $src = 'FALLBACK'
                Write-Log "Reply source: SCENARIO_FALLBACK(attachment_only)"
            }
            # 3) Still empty -> the decision-driven fallback for the CURRENT scenario. There is no
            #    separate "rule engine" any more: the fallback path and the model path share exactly
            #    one policy implementation (lib\reply_policy.ps1 decides, lib\reply_gen.ps1 words it).
            #    The old QUICK/RULE_ENGINE labels are gone with it.
            if (-not $reply) {
                $fbDecision = $script:lastReplyDecision
                if (-not $fbDecision) {
                    $fbConv = $replyConversation
                    $fbDecision = Get-ReplyDecision -Conversation $fbConv -Facts (Get-ConversationFacts $fbConv) -Rules $rules
                }
                $reply = Get-ScenarioFallback -Decision $fbDecision -Rules $rules
                $src = 'FALLBACK'
                Write-Log "Reply source: SCENARIO_FALLBACK($($fbDecision.Scenario))"
            }
            # 2b) B5 提取调用(与回复解耦): 附件存在时第二次 LLM 只输出 JSON → sidecar(source+文件名)
            if ($visionSource) {
                try {
                    $exPrompt = 'Read the attached content. Output ONLY JSON: {"weight_kg":"","dims":"","cartons":"","tracking":"","note":""}. Use only clearly visible values; leave fields empty if unsure.'
                    $exMsgs = $null
                    if ($visionUrls.Count -gt 0) {
                        $exMsgs = @(@{ role = 'user'; content = @(New-VisionContentParts $visionUrls $exPrompt) })
                    } elseif ($docExtractText) {
                        $exMsgs = @(@{ role = 'user'; content = ($exPrompt + "`n`n=== 文件内容 ===`n" + $docExtractText) })
                    }
                    if ($exMsgs) {
                        $exText = Invoke-LLM $exMsgs 0.2 300 $logFile
                        $ex = Get-VisionExtract $exText
                        if ($ex) {
                            $exFile = 'attachment'
                            if ($attFileName) { $exFile = $attFileName }
                            elseif ($attImages.Count -gt 0) { $exFile = (($attImages[0] -split '\?')[0].Split('/')[-1]) }
                            Save-VisionExtract $key $ex $visionSource $exFile $script:dataDir | Out-Null
                            Write-Log "VISION-EXTRACT $($key) src=$visionSource fields=$((@($ex.Keys)) -join ',')"
                        }
                    }
                } catch { Write-Log "VISION-EXTRACT-ERR $($key): $($_.Exception.Message)" }
            }
            if ($reply -and $reply.Trim().Length -gt 0) {
                # F4:预算耗尽 → 本轮不发送,保留待处理状态,下一轮重试(避免超预算轮次拖长静默)
                if (Test-LlmRoundBudgetExceeded) {
                    Set-LlmRoundBudgetExceeded "pre-send" $logFile
                    Write-Log "ROUND-DONE $($key) ms=$($roundCtx.sw.ElapsedMilliseconds) result=BUDGET-SKIP (kept pending for next round)"
                    Stop-LlmRound
                    return
                }
                # === Send-time policy gate (defence in depth) ===
                # The generation path already checks compliance and rewrites at most once. This is the
                # LAST gate before the text leaves the process, and it also covers replies that did
                # not come from the model.
                # [SPEC 6 2026-10-03] It used to run two INDEPENDENT rewrite rounds - one for banned
                # words, one for liability wording - so a single draft could cost up to two extra
                # model calls, and each round re-sent the whole prompt. Spec 6 requires at most ONE
                # rewrite sharing the remaining budget, so the rewrite now lives in lib\reply_gen.ps1
                # (driven by the full violation list) and this gate never calls the model at all.
                # The guarantee is unchanged: a reply that cannot be made compliant is never sent.
                # [2026-10-05 spec §6.2] 发送前重新取锁并复核：待回复成员、精确会话名、当前买家输入与任务证据。
                #   任何一项变化 ⇒ 丢弃旧草稿（绝不"只换个称呼"把过期内容发出去）。
                if (-not (Get-AppLock 'onetalk-write' 5)) {
                    Write-Log "SEND-LOCK-BUSY $($key): another writer holds onetalk-write; draft discarded, no send this round"
                    Stop-LlmRound
                    return
                }
                $stale = ''
                try {
                    $pendingRaw = Get-Snapshot
                    if ($pendingRaw -notmatch '^\[') { throw 'pending-list-unreadable' }
                    $pendingNow = $pendingRaw | ConvertFrom-Json
                    if (-not @($pendingNow | Where-Object { (Get-PendingConversationName ([string]$_.name)) -ceq (Get-PendingConversationName $key) }).Count) {
                        Write-Log "STALE-DRAFT-DISCARD $($key): no longer in pending list"
                        Stop-LlmRound
                        return
                    }
                    $freshConvo = Open-ConvoAndGetMessages $key
                    if ($freshConvo -is [string]) {
                        $stale = 'reread-failed:' + $freshConvo
                    } else {
                        $freshOpened = ([string]$freshConvo.name).Trim()
                        if (-not $freshOpened -or (Get-PendingConversationName $freshOpened) -cne (Get-PendingConversationName $key)) {
                            $stale = 'identity-changed'
                        } else {
                            $freshList = ConvertTo-MessageList $freshConvo.msgs $key
                            if ($freshList.Anomaly) { $stale = 'order-unverified' }
                            elseif (-not $freshList.LatestBuyer) { $stale = 'no-actionable-buyer:' + $freshList.ReplyBlockReason }
                            elseif ([string]$freshList.LatestBuyer.Orig -ne $snapshotLatestText) { $stale = 'buyer-input-changed' }
                            elseif ([string]$freshList.LatestBuyer.StableId -cne $snapshotLatestIdentity) { $stale = 'buyer-identity-changed' }
                            elseif ([int]$freshList.BuyerCount -ne $snapshotBuyerCount) { $stale = 'buyer-count-changed' }
                        }
                    }
                } catch { $stale = 'reread-error:' + $_.Exception.Message }

                if (-not $stale) {
                    # [2026-10-05 spec §5 第 3/5 条] 账本在生成期间损坏 ⇒ 本轮不发送。
                    $ledgerNow = Test-RepliedStateUsable $ctx.state
                    if (-not $ledgerNow.Ok) {
                        Write-Log "SEND-GATE-LEDGER-UNUSABLE $($key): ledger became unusable during generation ($($ledgerNow.Reason), status=$($ledgerNow.Status)) - no send"
                        Stop-LlmRound
                        return
                    }
                }
                if ($stale) {
                    if ($stale -match 'reread|order-unverified|no-actionable-buyer') { $null=New-PendingReplyHumanTask -Buyer $key -Reason $stale }
                    Write-Log "STALE-DRAFT-DISCARD $($key): $stale - the draft built from the older snapshot is discarded; the conversation is re-decided on the next read"
                    Stop-LlmRound
                    return
                }
                Write-Log "PAGE-LOCK-REACQUIRED phase=send convo=$($key) verified=pending+identity+input+ledger"
                $sendRuntime = New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc (Get-ReplyClockUtc)
                # 最终复核读的是**本轮已经落盘任务**的回读证据（不是生成前的旧状态）。
                # [F4 §6.1 第 4 条] 发送前用**同一个** TaskId + 规范化类型 + 供应商身份重新回读落盘任务：
                #   任务关闭、归属变化或关键事实变化 ⇒ 弃稿重决策，绝不继续使用 script 里的旧证据。
                $sendEvidence = $script:turnActionEvidence
                $taskRef = $script:turnTaskRef
                if ($taskRef -and $taskRef.TaskId) {
                    try {
                        $freshEvidence = Get-ActionEvidenceForTask -Buyer $key -TaskId $taskRef.TaskId -Kind $taskRef.TaskKind -SupplierIdentity $taskRef.SupplierIdentity
                        if ($freshEvidence -and $freshEvidence.TaskExists -and $freshEvidence.ExactTaskMatch) {
                            $sendEvidence = New-ActionEvidence -Values $freshEvidence
                            Write-Log "HUMAN-TASK-SEND-REREAD $($key) id=$($taskRef.TaskId) kind=$($freshEvidence.TaskKind) status=$($freshEvidence.TaskStatus) identity=$($freshEvidence.SupplierIdentity) matched=True"
                        } else {
                            Write-Log "HUMAN-TASK-SEND-REREAD $($key) id=$($taskRef.TaskId) kind=$($taskRef.TaskKind) : the persisted task is closed or no longer matches this identity - the draft is discarded and the conversation is re-decided"
                            $stale = 'task-closed-or-changed'
                        }
                    } catch {
                        Write-Log "HUMAN-TASK-SEND-REREAD-ERR $($key): $($_.Exception.Message)"
                        $stale = 'task-evidence-unreadable'
                    }
                }
                # [spec §4.1 第 1 条] 这里**不再**退回 Get-ActionEvidenceForBuyer：
                #   没有本轮确切任务引用就没有行动证据（空证据 ⇒ 措辞检查按无任务处理）。
                if ($stale) {
                    Write-Log "STALE-DRAFT-DISCARD $($key): $stale - the draft built from the older task evidence is discarded"
                    Stop-LlmRound
                    return
                }
                $sendFacts = Get-ConversationFacts -Conversation $freshList -Buyer $key -WithTaskEvidence
                $sendDecision = Get-ReplyDecision -Conversation $freshList -Facts $sendFacts -Rules $rules -RuntimeContext $sendRuntime -ActionEvidence $sendEvidence
                # [2026-10-05 spec §3.2] The runtime facts must be fresh at send time. A pure time
                # answer is re-rendered from the fresh clock (never a second model call); a mixed
                # answer whose clock/company/name already drifted is caught by the identity checks
                # in Test-ReplyCompliance and replaced by the controlled fallback below.
                # [2026-10-05 第三轮 spec §2/§8.3] 发送锁内用**一份新鲜的 RuntimeContext** 同时刷新程序
                #   时间片段与对应的全部 TimeExpectations，再与原独立业务正文重新组合：
                #   不叠加新旧答案、不对全文做字符串/正则替换去猜前缀、其他身份事实片段（公司/姓名）继续保留。
                $composition=$script:lastReplyComposition
                if($composition -and -not (Test-ResponsePlanDependencies -Buyer $key -Plan $composition.Plan)){
                    Write-Log "STALE-DRAFT-DISCARD $($key): response-plan dependencies changed"
                    Stop-LlmRound
                    return
                }
                $freshPlan=New-ResponsePlan $sendDecision
                $body=''
                if($composition){$body=[string]$composition.BusinessBody}
                $freshComposition=Compose-Reply $freshPlan $body
                $reply=$freshComposition.Text
                $src='COMPOSITION_REFRESH'
                $finalCheck = Test-ReplyCompliance -Text $reply -Rules $rules -Decision $sendDecision
                if (-not $finalCheck.Ok) {
                    $codes = @($finalCheck.Violations | ForEach-Object { $_.Code }) -join ','
                    $detail = (@($finalCheck.Violations | Where-Object { $_.Severity -eq 'block' } | ForEach-Object { $_.Code + ':' + $_.Detail }) -join ' | ')
                    $sum = $reply.Trim()
                    if ($sum.Length -gt 60) { $sum = $sum.Substring(0, 60) + '...' }
                    Write-Log "SEND-GATE-BLOCK $($key) src=$($src) codes=[$codes] detail=[$detail] action=SCENARIO_FALLBACK summary=$($sum)"
                    $reply = Get-ScenarioFallback -Decision $sendDecision -Rules $rules
                    $src = 'FALLBACK'
                    $postCheck = Test-ReplyCompliance -Text $reply -Rules $rules -Decision $sendDecision
                    if (-not $postCheck.Ok) {
                        # The last holding line is a send candidate too; validate it below.
                        $postCodes = @($postCheck.Violations | ForEach-Object { $_.Code }) -join ','
                        Write-Log "SEND-GATE-FALLBACK-DIRTY $($key) codes=[$postCodes] action=NEUTRAL_HOLD"
                        $reply = $script:banSafeFallback
                    }
                }

                if (-not (Test-ReplyCompliance -Text $reply -Rules $rules -Decision $sendDecision).Ok) {
                    Write-Log "SEND-GATE-FINAL-BLOCK $($key): no compliant fallback; no send or state advancement"
                    return
                }

                # ===== [2026-10-07 spec §4-7/§4-3，复核 R2/R3] 会话级不重发 + 发送前持久化尝试 =====
                #   只要该会话还有未确认（pending_confirmation）、持久化未完成（persistence_pending）
                #   或歧义（delivery_ambiguous）的尝试，本轮就不发送 —— **与去重键无关**：
                #   买家再发一条新消息（新触发）也不能自动放行一条未对账的旧发送。
                $sendAttemptId = ''
                $sendAttemptBefore = @()
                if (Get-Command Test-SendAttemptBlocksResend -ErrorAction SilentlyContinue) {
                    $resendBlock = $null
                    try { $resendBlock = Test-SendAttemptBlocksResend -Buyer $key -TriggerRef $newKey -ConvoKey $key }
                    catch { $null=New-PendingReplyHumanTask -Buyer $key -Reason ('send-history-unreadable:'+ $_.Exception.Message); return }
                    if ($resendBlock -and $resendBlock.Blocked) {
                        Write-Log "SEND-ATTEMPT-BLOCKS-RESEND $($key): unconfirmed attempt(s) [$(@($resendBlock.Reasons) -join ',')] - the conversation is not sent to again until they are reconciled (trigger=$newKey sameTrigger=$(@($resendBlock.SameTrigger).Count))"
                        $null=New-PendingReplyHumanTask -Buyer $key -Reason ('delivery-unresolved:'+(@($resendBlock.Reasons) -join ','))
                        return
                    }
                }
                # [spec §4-3] 先持久化唯一 AttemptId、目标会话、完整正文/哈希、发送前快照证明与阶段，
                #   再执行输入/点击。落盘失败 ⇒ **不执行发送**（不冒"发了但没有任何本地证据"的风险）。
                if (Get-Command New-PersistedSendAttempt -ErrorAction SilentlyContinue) {
                    $attRes = $null
                    try {
                        if (Get-Command Get-ConversationEventIndex -ErrorAction SilentlyContinue) {
                            $sendAttemptBefore = @(Get-ConversationEventIndex @($freshList.Lines))
                        }
                        $attRes = New-PersistedSendAttempt -Buyer $key -Text $reply -DedupKey $newKey -TriggerRef $newKey -TriggerIdentity $newestBuyer.StableId -ConvoKey $key -BeforeEvents $sendAttemptBefore
                    } catch {
                        Write-Log "SEND-ATTEMPT-PERSIST-ERR $($key): $($_.Exception.Message)"
                        $attRes = [pscustomobject]@{ Ok = $false; AttemptId = ''; Error = $_.Exception.Message }
                    }
                    if (-not $attRes -or -not $attRes.Ok) {
                        $why = 'unknown'
                        if ($attRes) { $why = [string]$attRes.Error }
                        Write-Log "SEND-ATTEMPT-NOT-PERSISTED $($key): $why - send is NOT executed (spec 4-3)"
                        $null=New-PendingReplyHumanTask -Buyer $key -Reason ('send-attempt-not-persisted:'+$why)
                        return
                    }
                    $sendAttemptId = [string]$attRes.AttemptId
                    Write-Log "SEND-ATTEMPT-PERSISTED $($key) attempt=$sendAttemptId dedupKey=$newKey beforeEvents=$(@($sendAttemptBefore).Count)"
                }
                # [2026-10-05 spec §5-3/§5-4] 结构化发送结果：SENT_OK = 页面动作 + 会话内新我方消息双证据；
                #   UNKNOWN = 页面动作完成但核对不到 ⇒ **先对账再决定是否重试**，绝不直接按失败补发。
                # The adapter binds and persists its actual baseline before marking dispatching.
                $sendRes = Send-OneTalkMessageEx -buyer $key -text $reply -AlreadyOpen -AttemptId $sendAttemptId
                $sendStatus = [string]$sendRes.Status
                $sendRaw = [string]$sendRes.Raw
                Write-Log "ROUND-SEND $($key) chars=$($reply.Length) elapsed=$(Get-LlmRoundElapsedSec)s status=$sendStatus evidence=[$($sendRes.ConfirmEvidence)]"
                Write-Log "REPLIED to $($key): $sendRaw [$sendStatus] $($sendRes.Detail)"
                Write-Log "Reply text: $($reply)"
                if ($sendStatus -eq 'UNKNOWN' -and $sendRaw -notmatch 'ABORT_WRONG_CONVO') {
                    $rec = Resolve-UnknownSendResult -key $key -text $reply -Before $sendRes.BeforeSnapshot
                    Write-Log "SEND-RECONCILE $($key): $($rec.Status) - $($rec.Detail)"
                    if ($rec.Status -eq 'confirmed') {
                        $sendStatus = 'SENT_OK'
                        $sendRes|Add-Member -NotePropertyName Receipt -NotePropertyValue $rec.Receipt -Force
                        $sendRaw = ($sendRaw + ' | RECONCILED_CONFIRMED')
                    } else {
                        $sendStatus = 'FAILED'
                        $sendRaw = ($sendRaw + ' | RECONCILE_' + $rec.Status.ToUpperInvariant())
                    }
                }
                if($sendStatus -eq 'SENT_OK' -and -not(Test-ConfirmedOutboundReceipt $sendRes.Receipt $key $reply)){
                    $sendStatus='UNKNOWN';$sendRaw+=' | INVALID_CONFIRMED_RECEIPT';Write-Log "SEND-RECEIPT-INVALID $($key): no ledger advancement"
                }
                # ===== [2026-10-07 spec §3.3/§4-4/§4-7，复核 R1] 尝试级确认 + 登记真实送达状态 =====
                #   **生产调用点**：用发送适配器返回的同口径前后快照（共享真实事件抽取 + 共享身份构造）
                #   做"唯一新增事件 + 完整正文 + 会话身份"的尝试级确认；收据有效 ⇒ receipt_verified；
                #   页面动作完成但核对不到 ⇒ pending_confirmation；其余 ⇒ delivery_ambiguous。
                $attemptConfirm = $null
                if ($sendAttemptId -and (Get-Command Confirm-SendAttemptFromSnapshots -ErrorAction SilentlyContinue)) {
                    $beforeSnap = @()
                    $afterSnap = @()
                    if ($sendRes.PSObject.Properties.Name -contains 'BeforeSnapshot' -and $sendRes.BeforeSnapshot) { $beforeSnap = @($sendRes.BeforeSnapshot) }
                    if ($sendRes.PSObject.Properties.Name -contains 'AfterSnapshot' -and $sendRes.AfterSnapshot) { $afterSnap = @($sendRes.AfterSnapshot) }
                    if (@($beforeSnap).Count -gt 0 -and @($afterSnap).Count -gt 0) {
                        try {
                            $attemptConfirm = Confirm-SendAttemptFromSnapshots -AttemptId $sendAttemptId -Buyer $key -Text $reply -BeforeEvents $beforeSnap -AfterEvents $afterSnap -ConvoKey $key
                        } catch { $attemptConfirm = $null; Write-Log "SEND-ATTEMPT-CONFIRM-ERR $($key): $($_.Exception.Message)" }
                        if ($attemptConfirm) {
                            Write-Log "SEND-ATTEMPT-CONFIRM $($key) attempt=$sendAttemptId confirmed=$($attemptConfirm.Confirmed) state=$($attemptConfirm.DeliveryState) newEvents=$($attemptConfirm.NewEventCount) ambiguity=[$(@($attemptConfirm.Ambiguity) -join ',')] err=$($attemptConfirm.Error)"
                        }
                    } else {
                        Write-Log "SEND-ATTEMPT-CONFIRM-SKIPPED $($key) attempt=${sendAttemptId} : the send adapter returned no same-caliber snapshots"
                    }
                }
                # 尝试级确认拿到了有效收据而页面核对只给出 UNKNOWN 时，以**收据**为准（送达已被证明）。
                if ($attemptConfirm -and $attemptConfirm.Confirmed -and $sendStatus -ne 'SENT_OK') {
                    $sendStatus = 'SENT_OK'
                    $sendRes | Add-Member -NotePropertyName Receipt -NotePropertyValue $attemptConfirm.Receipt -Force
                    $sendRaw = ($sendRaw + ' | ATTEMPT_RECEIPT_CONFIRMED')
                    Write-Log "SEND-RECEIPT-RECOVERED $($key) attempt=$sendAttemptId receipt=$($attemptConfirm.Receipt.ReceiptId) type=$($attemptConfirm.Receipt.ConfirmationType)"
                }
                $sendNotAttempted = ($sendRes.PSObject.Properties.Name -contains 'NotAttempted' -and [bool]$sendRes.NotAttempted)
                if ($sendNotAttempted) {
                    Write-Log "SEND-ABORTED-BEFORE-INPUT $($key) attempt=$sendAttemptId reason=$($sendRes.Detail)"
                }
                if ($sendAttemptId -and -not $sendNotAttempted -and (Get-Command Set-SendAttemptReceipt -ErrorAction SilentlyContinue)) {
                    try {
                        [void](Set-SendAttemptStage -AttemptId $sendAttemptId -Stage ('page:' + $sendStatus) -Detail ([string]$sendRes.ConfirmEvidence))
                        if ($sendStatus -eq 'SENT_OK') {
                            [void](Set-SendAttemptReceipt -AttemptId $sendAttemptId -Receipt $sendRes.Receipt -DeliveryState 'receipt_verified')
                        } elseif (Test-PageConfirmedSendResult ([string]$sendRaw)) {
                            [void](Set-SendAttemptReceipt -AttemptId $sendAttemptId -Receipt $null -DeliveryState 'pending_confirmation')
                            $ambDetail = 'page actions completed but no unique new event could be proven'
                            if ($attemptConfirm -and $attemptConfirm.Error) { $ambDetail = $ambDetail + ' (' + [string]$attemptConfirm.Error + ')' }
                            $invP = New-MonitorInvestigation -Buyer $key -Kind 'receipt_pending' -AttemptId $sendAttemptId -EventRefQuality 'attempt' -EvidenceRefs @('page-action-ok', ('raw:' + [string]$sendRaw)) -Detail $ambDetail
                            Write-Log "SEND-PENDING-CONFIRMATION $($key) attempt=$sendAttemptId - this conversation will not be re-sent until it is reconciled; investigation=$($invP.Id)"
                        } else {
                            [void](Set-SendAttemptStage -AttemptId $sendAttemptId -Stage ('failed:' + $sendStatus) -DeliveryState 'delivery_ambiguous' -Detail ([string]$sendRaw))
                        }
                    } catch { Write-Log "SEND-ATTEMPT-STAGE-ERR $($key): $($_.Exception.Message)" }
                }
                # 仅发送成功才记录去重；发送失败（ABORT/未发出/对账后仍未知）不记录，
                # 否则会话会永久卡在待回复板块且永不重试
                if ($sendStatus -eq 'SENT_OK') {
                    # Capture the successful-send clock before ledger/retry I/O can delay it.
                    $sentAt = Get-Date
                    $ctx.lastSendAt[$skey] = $sentAt
                    # [2026-10-05 spec §2.2] 记录已确认发送：之后判定"这条 [ME] 是不是我们发的"就有
                    #   本系统自己的证据，不再依赖 @@TS 这种时间字段。
                    # [2026-10-07 spec §4-5/§4-6] 跨文件不是一次原子提交：用持久提交阶段 + 可恢复对账处理
                    #   部分成功。sent_records 写入失败或返回 false ⇒ 保留已送达证明与待持久化状态、
                    #   暂停该会话新增发送并生成调查；**绝不**因落盘失败再次发送已送达正文。
                    $ledgerWriter = {
                        Set-StateHash $ctx $skey $newKey
                        $writtenNow = ''
                        if ($ctx.state -and $ctx.state.replied) {
                            if ($ctx.state.replied -is [System.Collections.IDictionary]) { $writtenNow = [string]$ctx.state.replied[$skey] }
                            elseif ($ctx.state.replied.PSObject.Properties.Name -contains $skey) { $writtenNow = [string]$ctx.state.replied.$skey }
                        }
                        return ($writtenNow -eq $newKey)
                    }.GetNewClosure()
                    $sentRecordWriter = {
                        return [bool](Add-SentRecord -Buyer $key -Text $reply -SentAt $sentAt.ToString('o') -Source 'monitor' -Receipt $sendRes.Receipt)
                    }.GetNewClosure()
                    $persisted = $null
                    if ($sendAttemptId -and (Get-Command Complete-SendAttemptPersistence -ErrorAction SilentlyContinue)) {
                        try { $persisted = Complete-SendAttemptPersistence -AttemptId $sendAttemptId -SentRecordWriter $sentRecordWriter -LedgerWriter $ledgerWriter -Detail 'SENT_OK' } catch { $persisted = $null; Write-Log "SEND-PERSIST-ERR $($key): $($_.Exception.Message)" }
                    }
                    if (-not $persisted) {
                        # 旧路径（没有持久化尝试）逐字保留原行为。
                        try { [void](Add-SentRecord -Buyer $key -Text $reply -SentAt $sentAt.ToString('o') -Source 'monitor' -Receipt $sendRes.Receipt) } catch { Write-Log "SENT-RECORD-WRITE-FAIL $($key): $($_.Exception.Message)" }
                        Set-StateHash $ctx $skey $newKey
                    } elseif (-not $persisted.Ok) {
                        Write-Log "SEND-PERSISTENCE-PENDING $($key) attempt=$sendAttemptId sentRecord=$($persisted.SentRecord) ledger=$($persisted.Ledger) err=$($persisted.Error) investigation=$($persisted.InvestigationId) - delivered proof kept; no resend of this reply"
                    } else {
                        Write-Log "SEND-PERSISTENCE-OK $($key) attempt=$sendAttemptId alreadyDone=$($persisted.AlreadyDone)"
                    }
                    # [2026-10-05 spec §3.2 第 1/2/7 条] 任务已经在**生成之前**由编排层幂等创建/更新
                    #   （Get-TaskContextForConvo），发送成功只负责如实记录通知结果：
                    #     通知失败 ⇒ 任务保留（pending_human/awaiting_contact），措辞不得声称人工已收到；
                    #     TodoPersisted / NotificationDelivered 是两类不同的证据，互不代替。
                    #   发送失败或 UNKNOWN **不删除**已经成立的供应商核实任务（本分支根本不碰任务表）。
                    try {
                        if ($taskCtx -and $taskCtx.Needed -and $taskCtx.TaskId) {
                            $todoKind = [string]$taskCtx.TodoKind
                            Write-Log "HUMAN-TASK $($key) kind=$($todoKind) status=$($taskCtx.TaskStatus) id=$($taskCtx.TaskId) created=$($taskCtx.Created) updated=$($taskCtx.Updated) after=SENT_OK"
                            $delivered = $false
                            try {
                                $note = Send-WecomMessage ("[TODO] " + $todoKind + " for " + $key + " (task " + $taskCtx.TaskId + ")")
                                if ([string]$note -eq 'SENT_OK') { $delivered = $true }
                                Write-Log "HUMAN-TASK-NOTIFY $($key) result=$note delivered=$delivered"
                            } catch { Write-Log "HUMAN-TASK-NOTIFY-ERR $($key): $($_.Exception.Message)" }
                            [void](Add-HumanTaskNotification -Id $taskCtx.TaskId -Delivered $delivered -Detail ([string]$todoKind))
                            $script:turnActionEvidence = Get-ActionEvidenceForBuyer -Buyer $key -Kind $todoKind
                        }
                    } catch { Write-Log "HUMAN-TASK-ERR $($key): $($_.Exception.Message)" }
                    Remove-PendingRetry $key          # [Phase3] 发送成功即出补发表
                    # [FIX-DUP-GUARD 2026-09-27] 真发出去了 ⇒ 重复回复的连挂计数归零(该计数语义是"连续")。
                    if ($ctx.ContainsKey('dupGuardHolds') -and $ctx.dupGuardHolds) { $ctx.dupGuardHolds.Remove($skey) }
                    # [SPEC §4.3-G4 2026-09-27 / SPEC-待回复列表 §2 行3-4] 记录成功发送时刻
                    #   —— 上方已赋值，秒级下限与分钟门禁共用这一个数据面。
                    # B2 报价提醒:[F7 §8.1 第 6 条] 前置门必须**直接消费统一结果**（Ready），
                    #   不得再用旧的三布尔（weight/dims/addr，且不看件数）拼第二套判据。
                    #   旧布尔值只允许用于逐项展示。哈希表/对象两种形态都用同一个取值接口读取。
                    try {
                        $gst = Get-GoodsDataStatus $key $script:dataDir
                        $gstReady = $false
                        if ($gst) {
                            if ($gst -is [System.Collections.IDictionary]) { if ($gst.Contains('ready')) { $gstReady = [bool]$gst['ready'] } }
                            elseif ($gst.PSObject.Properties.Name -contains 'ready') { $gstReady = [bool]$gst.ready }
                        }
                        if ($gstReady) {
                            $n = Send-QuoteReminders -OnlyBuyer $key -logFile $logFile
                            if ($n -gt 0) { Write-Log "QUOTE-REMIND: pushed for $key" }
                        } else {
                            Write-Log "QUOTE-REMIND-SKIP $($key): the unified quote readiness is not Ready (no second readiness judgement in the monitor)"
                        }
                    } catch {
                        Write-Log "QUOTE-REMIND-ERR: $($_.Exception.Message)"
                    }
                } else {
                    # ===== [SPEC §4.2-G2 2026-09-27] 发对人校验失败 ⇒ **整轮中止**(不只是跳过该会话) =====
                    # 依据 §7-R6: 本次事故里该闸门确实被触发(11:49:35 expected=买家L, current=买家G
                    #   Buyer-B), 但旧行为只报错、继续处理后续会话 ⇒ 页面已错位仍继续发。spec §4.4-4
                    #   明令禁止"只跳过该会话、继续处理下一个"。
                    if ($sendRaw -match 'ABORT_WRONG_CONVO') {
                        $script:roundHalt = $true
                        Write-Log "ABORT_WRONG_CONVO $($key): $sendRaw round-halt (no further sends this round)"
                        try { Send-WecomMessage ("[ALERT] ABORT_WRONG_CONVO for " + $key + " - " + $sendRaw + " ; round halted") | Out-Null } catch { }
                    }
                    # A4: count consecutive send failures, alert after 3 (30m throttle per buyer)
                    $failCount = 0
                    if ($ctx.sendFailCount.ContainsKey($key)) { $failCount = $ctx.sendFailCount[$key] }
                    $failCount++
                    $ctx.sendFailCount[$key] = $failCount
                    # 首次失败累计到 3 次立即告警;再次告警需距上次告警超过 30 分钟(节流)
                    $lastAlert = 0
                    if ($ctx.failAlertAt.ContainsKey($key)) { $lastAlert = [int]((Get-Date) - $ctx.failAlertAt[$key]).TotalMinutes }
                    if ($failCount -ge 3 -and (-not $ctx.failAlertAt.ContainsKey($key) -or $lastAlert -gt 30)) {
                        $ctx.failAlertAt[$key] = Get-Date
                        $ctx.sendFailCount[$key] = 0
                        $af = Send-WecomMessage ("[ALERT] send failed x" + $failCount + " for " + $key + ": " + $sendRaw)
                        Write-Log "FAIL-ALERT: $key -> $af (streak=$failCount)"
                    }
                    Write-Log "RETRY-QUEUE $($key): send failed ($sendRaw), will retry after cooldown"
                    $ctx.openCooldown[$key] = Get-Date
                    # [Phase3] 发送失败 ⇒ 入持久化补发表(会话可能就此离开待回复列表 ⇒ 否则永不重试)。
                    #   不去重 state(沿用既有正确设计, 见上方 L957-958 注释: 写了会永久卡死且永不重试)。
                    # [2026-10-06] 页面侧发送动作已完成但收据自证失败时，把当时的去重键一起入表：
                    #   会话随后离开待回复列表即可作为"已送达"的对账证据（见 NOT_IN_LIST 分支）。
                    Add-PendingRetry $key ([string]$sendRaw) $newKey (Test-PageConfirmedSendResult ([string]$sendRaw))
                }
            } else {
                Write-Log "SKIP $($key): empty reply generated"
            }
            Write-Log "ROUND-DONE $($key) ms=$($roundCtx.sw.ElapsedMilliseconds) budget=${roundBudget}s"
            Stop-LlmRound
        }
    } else {
        Write-Log "SKIP $($key): no buyer msgs found"
    }
}

# [SPEC-待回复列表 2026-09-27 §2.1/§3.2] 用**本轮快照的会话名集合**更新 $ctx.pendingSeen(连续确认轮数)。
#   命中则 +1; 未命中则**删键**(§2.1 原文:「命中则 +1, 未命中则删除」)。
#   为什么必须每轮整表对齐、而不是"逐会话在循环里 +1":
#     ① 同一轮内多个会话会互相干扰 —— 循环里更新时, 先处理的会话可能把后处理会话的轮数写成脏值;
#     ② "不在列表"必须由**快照整体**判定。逐会话更新的话, 一个本轮没出现在列表里的会话
#        根本不会被访问 ⇒ 计数永远不删 ⇒ 上次的 2 轮会被跨中断复用, 瞬态防线形同虚设。
#   位置(§3.2 硬要求): 在 Invoke-ScanRound 主线、`foreach ($item in $snap)` **之前**调用。
function Update-PendingSeen($ctx, $snap) {
    if (-not $ctx) { return }
    if (-not $ctx.ContainsKey('pendingSeen') -or -not $ctx.pendingSeen) { $ctx.pendingSeen = @{} }
    $seen = @{}
    foreach ($it in @($snap)) {
        if (-not $it) { continue }
        $n = [string]$it.name
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $seen[$n.Trim()] = $true
    }
    # 先删"本轮不在列表里"的键(必须在累加之前: 否则同名会话会在同一轮里既删又加)
    foreach ($k in @($ctx.pendingSeen.Keys)) {
        if (-not $seen.ContainsKey($k)) { $ctx.pendingSeen.Remove($k) }
    }
    foreach ($k in @($seen.Keys)) {
        $cur = 0
        if ($ctx.pendingSeen.ContainsKey($k)) { $cur = [int]$ctx.pendingSeen[$k] }
        $ctx.pendingSeen[$k] = $cur + 1
    }
}

# 扫描轮:抓列表 → 逐会话处理 → CDP 错误识别/自愈 → 按需 reload 决策。
# 返回 @{ Action = 'LockBusy' | 'Reloaded' | 'Normal' },调用方据此决定 sleep/continue
function Invoke-ScanRound($ctx) {
    # P2.3 写互斥:与其他写者(如 nudge)互斥,避免并发操作同一页面。拿不到锁则本轮跳过。
    $lockHeld = Get-AppLock 'onetalk-write' 0
    if (-not $lockHeld) {
        Write-Log "LOCK-BUSY: onetalk-write held by another process, skipping round"
        return @{ Action = 'LockBusy' }
    }
    $snapRaw = ''
    $snap = $null
        # ===== [Phase3] 先处理到期的补发项 =====
        # 这些会话可能已经不在待回复列表里(这正是 P-A 的成因),所以必须独立于列表推进。
        try {
            $rt = Read-RetryTable
            $nowR = Get-Date
            $due = @()
            foreach ($k in @($rt.items.Keys)) {
                $it = $rt.items[$k]
                $nx = $null
                try { $nx = [datetime]::Parse([string]$it.nextAt) } catch { $nx = $null }
                if (-not $nx -or $nx -le $nowR) { $due += $k }
            }
            foreach ($k in $due) {
                $itR = (Read-RetryTable).items[$k]
                if (-not $itR) { continue }
                $bkey = [string]$itR.key
                Write-Log "RETRY-ATTEMPT $bkey tries=$($itR.tries) reason=$($itR.reason)"
                try {
                    $rres = Send-PendingRetry $ctx $bkey
                    if ($rres -eq 'SENT_OK') { Remove-PendingRetry $bkey }
                    elseif ($rres -eq 'RECONCILED') {
                        # 对账结论：会话里最后说话的是我方 ⇒ 该诉求已被答复，补发项作废（不重发）
                        Remove-PendingRetry $bkey
                    }
                    elseif ($rres -eq 'NOT_IN_LIST') {
                        # [2026-10-06] 对账闭环：页面侧发送动作已完成（记在补发项里）+ 会话已离开待回复列表
                        #   ⇒ 当作已送达：推进账本并关闭补发项（不重发、不伪造收据）。
                        #   仅有 NOT_IN_LIST（被人工接走 / 买家撤回）不足以推进账本。
                        $rkey = [string]$itR.key
                        if (Test-ReconciledDeliveryEvidence ([string]$itR.reason) ([bool]$itR.pageConfirmed) ([string]$itR.dedupKey)) {
                            if (Complete-ReconciledDelivery $ctx (Get-StateKey $rkey) ([string]$itR.dedupKey) 'page-send-ok+pending-list-cleared') {
                                Remove-PendingRetry $rkey
                            } else {
                                Add-PendingRetry $rkey 'NOT_IN_LIST (ledger write failed; keep reconciling)'
                            }
                        } else {
                            # 会话已不在待回复列表 ⇒ 无法安全补发(可能已被人工处理或买家已撤回)
                            Add-PendingRetry $rkey 'NOT_IN_LIST (conversation no longer in pending list)'
                        }
                    } else {
                        # 'PROCESSED': Invoke-ConvoItem 未抛异常且未发送成功(命中 dedup/冷却/打开失败等);
                        # 仍按失败再排期, 由 tries 上限兜住(自然收敛, 见 spec §8-2 R3)
                        Add-PendingRetry $bkey ([string]$rres)
                    }
                } catch {
                    Add-PendingRetry $bkey ("RETRY-EXC: " + $_.Exception.Message)
                }
            }
        } catch { Write-Log ("RETRY-LOOP-ERR: " + $_.Exception.Message) }

        # ===== [2026-10-07 spec §6] 事件级调查的独立提醒与保留 =====
        #   提醒独立于"买家回复是否成功"分支：本次扫描轮即使全部会话被门禁阻断（页面阻断、
        #   来源不明、待确认发送），到期调查仍然会被提醒一次。通道失败不改写通知状态、不释放闸门。
        try {
            $invSweep = @(Invoke-MonitorInvestigationSweep -Max 3)
            foreach ($sr in $invSweep) {
                $sid = ''
                if ($sr.Record) { $sid = [string]$sr.Record.id }
                Write-Log ("INVESTIGATION-NOTIFY id=" + $sid + " result=" + [string]$sr.Result + " sent=" + [string]$sr.Sent + " err=" + [string]$sr.Error)
            }
            if ($invSweep.Count -gt 0) { [void](Invoke-MonitorInvestigationRetention) }
        } catch { Write-Log ("INVESTIGATION-SWEEP-LOOP-ERR: " + $_.Exception.Message) }

        # ===== [2026-10-07 spec §4-6，复核 R4] 待持久化发送的生产恢复（与提醒同级、独立于回复成功） =====
        #   收据已证明送达、只是 sent_records 或账本没写成功的尝试，在这里用**真实写入器**重试并回读；
        #   失败保持 persistence_pending（该会话继续被会话级闸门挡住），绝不因落盘失败再次发送。
        try {
            $recovered = Invoke-MonitorSendAttemptRecovery -Max 3
            foreach ($rr in @($recovered.Results)) {
                Write-Log ("SEND-ATTEMPT-RECOVERY attempt=" + [string]$rr.AttemptId + " ok=" + [string]$rr.Ok + " sentRecord=" + [string]$rr.SentRecord + " ledger=" + [string]$rr.Ledger + " err=" + [string]$rr.Error)
            }
        } catch { Write-Log ("SEND-ATTEMPT-RECOVERY-LOOP-ERR: " + $_.Exception.Message) }
    try {
        # 待回复板块 = 待办队列：板块里出现的每个会话都需要处理，回复后自动从板块消失。
        $snapRaw = Get-Snapshot
        if ($snapRaw -match '^\[') { $snap = $snapRaw | ConvertFrom-Json }
        if ($snap -and $snap.Count -gt 0) {
            $script:emptyStreak = 0
            $ctx.lastActivity = Get-Date
            # [2026-10-05 spec §5 A5] 每轮重新求一次账本健康状态（状态判定与缓存都由
            #   Get-LedgerHealth 负责）。损坏 / 空白 / 结构不合法都在这里被拦下，
            #   而不是被当成"还没有账本"。
            $ctx.state = Get-RepliedState
            # [FIX-DEDUP2] 账本不可用 ⇒ **本轮一律不处理会话**(宁可少发, 不可重复打扰)。
            #   理由: 没有账本就无法判定"是否已回复过"; 若照常发送, 每个会话都会被当成首次问询而重发
            #   (这正是 2026-09-27 00:43 事故的形态)。先尝试用备份修复, 再决定是否跳过本轮。
            $led = Test-RepliedStateUsable $ctx.state
            if (-not $led.Ok) {
                Write-Log "STATE-UNUSABLE: ledger unreadable ($($led.Reason), status=$($led.Status), bytes=$($led.Bytes)) - skipping this round (no sends) to avoid re-replying"
                $repaired = Repair-RepliedState
                $ctx.state = Get-RepliedState
                $led2 = Test-RepliedStateUsable $ctx.state
                if ($led2.Ok) {
                    Write-Log "STATE-UNUSABLE-RECOVERED: repair=$repaired entries=$($led2.Count) - resuming normal processing"
                    Clear-LocalAlert 'dedup_ledger'
                } else {
                    Write-LocalAlert 'dedup_ledger' ("reply ledger unusable ($($led2.Reason), status=$($led2.Status), bytes=$($led2.Bytes)); auto-reply paused this round to avoid duplicate replies") 'local-only' | Out-Null
                    Write-Log "Scan cycle done (ledger-unusable skip)"
                    return @{ Action = 'Normal' }
                }
            } else {
                # 配对清除: 上一轮若因账本不可用而告警, 本轮恢复即清(不复发"只写不清")
                Clear-LocalAlert 'dedup_ledger'
                if ($led.Count -gt 0 -and $led.Count -lt 3 -and $led.Bytes -gt 1000) {
                    # 文件很大却只剩极少数条目 ⇒ 疑似曾被覆盖, 显式留痕供人工确认
                    Write-Log "STATE-SUSPECT: ledger has only $($led.Count) entries but file is $($led.Bytes) bytes"
                }
            }
            # ===== [SPEC §4.2 G1/G1b/G3 2026-09-27] 整轮硬门禁(不满足 ⇒ 本轮一条都不发) =====
            # 依据: 本次事故 §2.1 —— 页面已 `no onetalk page found`, monitor 仍逐会话处理并刷屏 8 条/轮,
            #   8 分钟内 8 条消息无人拦(§3-R3「失败不闭合: 错了一条也停不下来」)。
            # 位置: 必须**在进入会话处理循环之前**; 命中即整轮 return, 绝不"只跳过该会话、继续处理下一个"
            #   (spec §4.4-4 明令禁止)。
            # (a) 页面存在性: 无 OneTalk 页 ⇒ 页面不可用(与 Test-PageHealth 互补: 后者覆盖"页在但数据面断")
            $pageMissing = -not (Test-OneTalkPagePresent)
            $pageHealth = Test-PageHealth
            # S1-3 空守卫(沿用既有教训): 异常路径可能返回字符串/数组, 直接取 .PageDown 会静默拿到 $null
            #   ⇒ 把"判据失效"伪装成"未断连"。显式归一化后再判定。
            if ($pageHealth -is [array]) { $pageHealth = $pageHealth[0] }
            if ($null -eq $pageHealth -or -not ($pageHealth.PSObject.Properties.Name -contains 'PageDown')) {
                $pageHealth = [pscustomobject]@{ PageDown = $true; Reason = 'probe-invalid'; Items = 0; Spinner = 0; Tab = ''; Tip = '' }
            }
            if ($pageMissing -or $pageHealth.PageDown) {
                $pdReason = if ($pageMissing) { 'no-onetalk-page' } else { [string]$pageHealth.Reason }
                Write-Log "ABORT-PAGE-DOWN reason=$($pdReason) items=$(@($snap).Count) action=skip-round"
                $script:pageDownStreak++
                # (b) G1b 自愈: 连续 2 轮 G1 ⇒ 升级到既有 chrome_ensure -ForceRestart 路径
                if ($script:pageDownStreak -ge 2) {
                    $heal = Invoke-PageHealFromGate $pdReason
                    if ($heal -eq 'FATAL') { return @{ Action = 'PageDownFatal' } }
                }
                Write-Log "Scan cycle done (page-down skip)"
                return @{ Action = 'Normal' }
            }
            if ($script:pageDownStreak -gt 0) {
                Write-Log "PAGE-RECOVERED after $($script:pageDownStreak) down round(s)"
                $script:pageDownStreak = 0
            }
            $script:pageHealFails = 0
            # ===== [SPEC-待回复列表 2026-09-27 §2.1/§3.2] 连续确认轮数: 每轮用本轮快照整表对齐 =====
            # 位置说明(与 §3.2 的"约 L1403–1405"的差异, 已在 REPORT 登记):
            #   §3.2 的硬约束是"必须在 foreach ($item in $snap) 之前、且在**主线**上"。放在
            #   Get-Snapshot 之后紧邻处也不违规, 但会带来一个真实风险: 页面已被 G1 判为不可用
            #   (无 OneTalk 页 / 数据面断)的那一轮, 快照本身就不值得信任; 若照样给它 +1,
            #   等页面恢复时这份**坏快照**已经攒够 2 轮 ⇒ 恰好绕开 §2.1 要挡的误发。
            #   故放在 G1 门禁**之后**、foreach 之前: 只有"这一轮的列表可信"才计入确认。
            Update-PendingSeen $ctx $snap
            # (c) G3 冷启动: monitor 启动后的第 1 个 scan cycle 只观察不发送(允许写快照/日志/推提醒)。
            $script:scanCycleNo++
            # [2026-10-05 spec §6.2] 页面锁只覆盖"页面读取"这一段：列表与页面健康都已取完，
            #   进入逐会话处理前先放锁。每个会话自己在读消息时再取锁，生成期间**不持锁**，
            #   发送前重新取锁并复核（见 Invoke-ConvoItem）。这样模型/附件耗时不再占用页面锁。
            [void](Release-AppLock 'onetalk-write')
            Write-Log ("PAGE-LOCK-RELEASED phase=list-done items=" + @($snap).Count)
            foreach ($item in $snap) {
                if (-not $item.name) { continue }
                if ($script:roundHalt) {
                    # G2 整轮中止: 已发生"发对人"校验失败 ⇒ 本轮剩余会话一律不处理(§4.2-G2 round-halt)
                    Write-Log "ROUND-HALT: ABORT_WRONG_CONVO seen in this round; skipping remaining item(s)"
                    break
                }
                $script:roundHalt = $false
                try {
                    Invoke-ConvoItem $ctx $item $script:scanCycleNo
                } catch {
                    Write-Log "CONVO-ERROR $($item.name): $($_.Exception.Message)"
                    $null=New-PendingReplyHumanTask -Buyer $item.name -Reason ('conversation-error:'+$_.Exception.Message)
                } finally {
                    Release-AppLock 'onetalk-write' | Out-Null
                }
            }
        }
        Write-Log "Scan cycle done"
    } catch {
        Write-Log "Monitor error: $($_.Exception.Message)"
        # CDP/Chrome 不可达自愈：连续 3 次错误则重启 Chrome 并重新登录
        Invoke-CdpSelfHeal | Out-Null
    }
    # 列表抓取失败（非合法 JSON / 页面未就绪）时连续 3 次强制刷新重连；
    # 列表为空数组 [] 是正常"无待办"状态，不刷新避免打断连接
    if ($null -eq $snap -and $snapRaw -notmatch '^\[') {
        # CDP 掉线识别(修复盲区):Cdp-Eval 把子进程错误当普通输出返回,
        # 此前 CDP 掉线只走下方"重载循环"而永不触发 chrome_ensure 自愈。
        # 现在检测到 CDP 错误标记 → 计入 cdpFailStreak,连续 3 次自动自愈;
        # CDP 已断时重载请求必然也失败,跳过重载直接等待下一轮
        if ($snapRaw -match 'CDP ERROR|WS CONNECT TIMEOUT|WS RECV TIMEOUT|无法连接到远程服务器|CMD ERROR') {
            $cdpStreak = $script:cdpFailStreak + 1
            Write-Log "CDP error detected ($cdpStreak/3): $($snapRaw.Substring(0, [Math]::Min(90, $snapRaw.Length)))"
            if (Invoke-CdpSelfHeal) { $script:emptyStreak = 0 }
        } else {
            $script:emptyStreak++
            if ($script:emptyStreak -ge 3) {
                $script:emptyStreak = 0
                $re = Invoke-CdpEval "location.reload(); 'RELOADED'"
                Write-Log "List fetch failed x3 - forced page reload ($re), waiting for reconnection"
                Start-Sleep -Seconds 12
            }
        }
    } else {
        # 本轮列表抓取正常 → 失败计数清零
        $script:emptyStreak = 0
        $script:cdpFailStreak = 0
    }
    # [FIX-PAGEHEALTH 2026-09-25] 数据面连通性判定（与 CDP 错误判定相互独立、互补）
    #   背景：页面断连时 $snapRaw 返回 '[]'（合法 JSON），既不会进 CDP-ERROR 分支、也不触发 emptyStreak
    #   之外的任何动作 → 22:24-22:56 业务空转 32 分钟而日志只有 "Scan cycle done"。
    $pageHealth = Test-PageHealth
    # [FIX-PAGESELECT 2026-09-26] S1-3 空守卫：Get-Page 无 OneTalk 页时返回 $null，本函数仍返回对象
    #   （wrong-tab ⇒ PageDown），但异常路径可能返回字符串/数组：直接取 $pageHealth.PageDown 会静默拿到
    #   $null ⇒ 把"判据失效"伪装成"未断连"（附录 B/C12 同类教训）。这里显式归一化后再判定。
    if ($pageHealth -is [array]) { $pageHealth = $pageHealth[0] }
    if ($null -eq $pageHealth -or -not ($pageHealth.PSObject.Properties.Name -contains 'PageDown')) {
        $pageHealth = [pscustomobject]@{ PageDown=$true; Reason='probe-invalid'; Items=0; Spinner=0; Tab=''; Tip='' }
    }
    if ($pageHealth.PageDown) {
        $script:pageDownStreak++
        Write-Log "PAGE-DOWN ($($script:pageDownStreak)x) reason=$($pageHealth.Reason) items=$($pageHealth.Items) spin=$($pageHealth.Spinner)"
    } else {
        if ($script:pageDownStreak -gt 0) {
            Write-Log "PAGE-RECOVERED after $($script:pageDownStreak) down round(s)"
            # [FIX-ALERTPAIR 2026-09-26] 数据面恢复即清掉 page_data_plane 告警：原实现只在
            #   'alert-only' 分支 Write-LocalAlert，恢复时无配对 Clear ⇒ 该告警永不消解。
            #   必须留在本 if 内部：只有"曾 down 过"才需要清（无条件调用等于每轮空转）。
            Clear-LocalAlert 'page_data_plane'
        }
        $script:pageDownStreak = 0
    }
    # [FIX-THROTTLE 2026-09-26] 分级自愈（带静默期/退避/上限，取代原来的 `% 3` 无退避写法）
    $healSkipped = $false
    if ($pageHealth.PageDown -and $script:pageDownStreak -ge 2) {
        Release-AppLock 'onetalk-write'
        if (-not (Get-AppLock 'onetalk-write' 0)) {
            $healSkipped = $true
            Write-Log "PAGE-HEAL-SKIP: onetalk-write held by another process (avoid disturbing an in-flight send)"
        } else {
            Release-AppLock 'onetalk-write'
            $act = Get-PageHealAction -Streak $script:pageDownStreak -Restarts $script:pageHealRestarts -QuietUntil $script:pageHealQuietUntil
            switch ($act.Action) {
                'restart' {
                    Write-Log ("PAGE-HEAL: escalating to chrome_ensure -ForceRestart [$($act.Reason)] quiet=$($act.NextQuietSec)s")
                    $ensure = powershell -ExecutionPolicy Bypass -NoProfile -File $script:ensureScript -ForceRestart 2>&1
                    Write-Log "PAGE-HEAL chrome_ensure exit=$LASTEXITCODE result: $(($ensure -join ' | '))"
                    $script:pageHealRestarts++
                    if ($act.NextQuietSec -gt 0) { $script:pageHealQuietUntil = (Get-Date).AddSeconds($act.NextQuietSec) }
                    Write-Log ("PAGE-HEAL: restarts=$($script:pageHealRestarts) quietUntil=" + $(if($script:pageHealQuietUntil){$script:pageHealQuietUntil.ToString('HH:mm:ss')}else{'-'}))
                }
                'reload' { Invoke-PageReload "Scheduled page reload (PAGE-DOWN x$($script:pageDownStreak))" }
                'alert-only' {
                    if (-not $script:pageHealAlerted) {
                        $script:pageHealAlerted = $true
                        Write-Log ("PAGE-HEAL-ALERT-ONLY: $($act.Reason) - 停止自动重启，等待人工介入")
                        Write-LocalAlert 'page_data_plane' ("OneTalk 数据面断连持续 $($script:pageDownStreak) 轮，已达重启上限 $($script:pageHealRestarts) 次（$($act.Reason)）") 'local-only'
                    }
                }
                default { }
            }
        }
    }
    # 恢复/稳定后清零计数（D4）
    if (-not $pageHealth.PageDown -and $script:pageDownStreak -eq 0 -and $script:pageHealRestarts -gt 0) {
        Write-Log ("PAGE-HEAL: page healthy - reset restart counter (was $($script:pageHealRestarts))")
        $script:pageHealRestarts = 0
        $script:pageHealQuietUntil = $null
        $script:pageHealAlerted = $false
    }
    # P2.2 按需 reload(替代原每 2 分钟无条件刷新):空闲且距上次活动超过阈值才刷新;忙时超过 30 分钟兜底
    $minsSinceReload = [int]((Get-Date) - $script:lastReload).TotalMinutes
    $minsSinceActivity = [int]((Get-Date) - $ctx.lastActivity).TotalMinutes
    if ($minsSinceReload -ge $script:reloadIdleMin -and $snap.Count -eq 0 -and $minsSinceActivity -ge $script:reloadIdleMin) {
        Invoke-PageReload "Scheduled page reload (${minsSinceReload}m since last, idle ${minsSinceActivity}m)"
        return @{ Action = 'Reloaded' }
    } elseif ($minsSinceReload -ge 30) {
        # 长时间无法空闲（一直在处理会话），强制刷新防止列表失活
        Invoke-PageReload "Forced page reload (${minsSinceReload}m, busy)"
        return @{ Action = 'Reloaded' }
    }
    return @{ Action = 'Normal' }
}

# 启动初始化:单实例保护 + PID 文件 + 退出清理 + 迁移/清理 + 脚本级运行态
function Initialize-MonitorRuntime {
    # 单实例保护：PID 文件记录当前实例，重复启动时直接退出
    $pidFile = Join-Path $LogDir "monitor.pid"
    if (Test-Path $pidFile) {
        try {
            $oldPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -match 'powershell') {
                Write-Log "Another monitor instance already running (PID $oldPid) - exiting"
                exit 0
            }
        } catch {}
    }
    try { Set-Content -Path $pidFile -Value $PID -Encoding ASCII } catch {}
    try {
        # 退出时清理 PID 文件（正常退出路径；被强杀时由新实例检测失效 PID 覆盖）
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            Remove-Item -Path (Join-Path $LogDir "monitor.pid") -Force -ErrorAction SilentlyContinue
        } | Out-Null
    } catch {}
    # P0 日志/快照治理(2026-09-18):启动时轮转 monitor.log 并执行快照保留(先 DryRun 记录再实际执行);失败不影响启动
    try {
        $__logMaxMb = 20
        $__logKeep = 10
        if ($script:skillCfg.PSObject.Properties.Name -contains 'log_max_mb' -and $script:skillCfg.log_max_mb) { $__logMaxMb = [int]$script:skillCfg.log_max_mb }
        if ($script:skillCfg.PSObject.Properties.Name -contains 'log_keep_files' -and $script:skillCfg.log_keep_files) { $__logKeep = [int]$script:skillCfg.log_keep_files }
        Write-Log (Invoke-LogRotation -LogDir $script:logFileDir -Name 'monitor' -MaxMb $__logMaxMb -KeepFiles $__logKeep)
    } catch { }
    try {
        $__snapDays = 90
        if ($script:skillCfg.PSObject.Properties.Name -contains 'snapshot_retention_days' -and $script:skillCfg.snapshot_retention_days) { $__snapDays = [int]$script:skillCfg.snapshot_retention_days }
        Write-Log (Invoke-SnapshotRetention -DataDir $script:dataDir -Days $__snapDays -DryRun)
        Write-Log (Invoke-SnapshotRetention -DataDir $script:dataDir -Days $__snapDays)
    } catch { }
    Invoke-LayoutMigration
    Write-Log "=== Monitor started (PID $PID, auto-reply engine built-in) ==="
    Write-Log 'REPLY-POLICY pending-list-authoritative; no source wait, minute cooldown, new-message floor or extra confirmation rounds; duplicate/delivery safeguards active'
    Cleanup-LegacyQueues
    Cleanup-StaleState
    $script:emptyStreak = 0
    # P2.2 reload 按需化:OneTalk 长连接会失效,但无需每 2 分钟无条件刷新。
    # 仅当 (a)列表抓取失败连续 2 次(emptyStreak, 上方处理), 或 (b)空闲超过 reload_idle_min(默认10分钟),
    # 或 (c)持续忙处理超过 30 分钟 时才 reload。列表有新会话/预览变化视为活跃,重置 idle 计时。
    $script:reloadIdleMin = 10
    if ($script:skillCfg -and $script:skillCfg.reload_idle_min) { $script:reloadIdleMin = [int]$script:skillCfg.reload_idle_min }
    if ($script:reloadIdleMin -lt 3) { $script:reloadIdleMin = 3 }
    $script:lastReload = Get-Date
    # CDP 连续失败计数：达到阈值触发 Chrome 自愈（重启+重登）
    $script:cdpFailStreak = 0
    # [FIX-PAGEHEALTH 2026-09-25] 数据面断连连续轮次（分级自愈用）
    $script:pageDownStreak = 0
    # [FIX-THROTTLE 2026-09-26] 自愈节流运行态
    $script:pageHealRestarts = 0      # 本轮累计 FORCE-RESTART 次数
    $script:pageHealQuietUntil = $null # 静默期截止时间
    $script:pageHealAlerted = $false   # 达上限后只告警一次
    # [SPEC §4.2 2026-09-27] 整轮硬门禁运行态
    $script:pageHealFails = 0          # G1b: 门禁触发的 chrome_ensure 自愈连续失败次数(>=2 ⇒ FATAL)
    $script:scanCycleNo = 0            # G3: scan cycle 序号(启动后第 1 轮 = 冷启动, 只观察不发送)
    $script:roundHalt = $false         # G2: 本轮是否已因"发对人失败"而整轮中止
}

function Start-Monitor {
    Initialize-MonitorRuntime
    # 运行态上下文(显式传递,避免隐式作用域):state 去重 + 各类冷却/节流表 + 最近活动时间
    $ctx = @{
        state = $null
        openCooldown = @{}
        skipCooldown = @{}
        noReplyPreview = @{}
        sendFailCount = @{}
        failAlertAt = @{}
        humanPending = @{}   # [2026-09-26 S2] 买家 -> $true: 该会话"我方尾部是人工消息", 自动回复正让路中
        lastSendAt = @{}     # [SPEC §4.3-G4 2026-09-27] statekey -> 最近一次**成功发送**时刻(最小间隔兜底, 值见配置键)
        # [SPEC-待回复列表 2026-09-27 §2.1] 会话名 -> **连续**在待回复列表里出现的轮数(瞬态误读防线)。
        #   命中 +1, 未命中**删键**(不是置 0 —— 置 0 会让"曾经连读两轮"的旧计数在中断后仍被当成已确认)。
        #   内存态: monitor 重启即归零, 每个会话重新攒满 2 轮(§10-R3, 代价约 9 秒, 可接受)。
        pendingSeen = @{}
        # [FIX-DUP-GUARD 2026-09-27] statekey -> "在待回复列表里、但账本证明最后一条买家消息已回过"的**连续**轮数。
        #   连挂 3 次即告警(见 NOT_IN_PENDING_LIST 分支); 真发出去或买家说了新话即归零(不归零就失去"连续"语义)。
        dupGuardHolds = @{}
        # [2026-10-05 spec §2.2 第 4 条] 会话名 -> 已登记的"来源不明我方消息"标记。
        #   首次登记只记历史（不开始等待），此后同一会话新出现的未知我方消息才开启
        #   source_unknown_hold。标记只在内存里，重启后第一条未知我方消息重新按历史处理；
        #   真正需要拦的是"尾部仍是我方未知消息"（闸门本来就 SKIP）与已持久化的等待窗口。
        sourceUnknownMarks = @{}
        lastActivity = Get-Date
    }
    while ($true) {
        $r = Invoke-ScanRound $ctx
        if ($r.Action -eq 'LockBusy') {
            Start-Sleep -Seconds 5
            continue
        }
        if ($r.Action -eq 'Reloaded') {
            continue
        }
        if ($r.Action -eq 'PageDownFatal') {
            # [SPEC §4.2-G1b] 页面不可用且自愈失败达上限 ⇒ 停止处理, 等人工介入。
            #   不再 5 秒一轮刷屏(本次事故 §2.1: 页面已不可用仍逐会话刷屏 8 条/轮)。
            Write-Log "MONITOR-HALT: page unavailable and self-heal failed; waiting for manual intervention (60s recheck, no sends)"
            Release-AppLock 'onetalk-write'
            Start-Sleep -Seconds 60
            continue
        }
        Release-AppLock 'onetalk-write'
        Start-Sleep -Seconds 5
    }
}

function Stop-Monitor {
    $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'monitor\.ps1' }
    foreach ($proc in $p) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Log "=== Monitor stopped ==="
}

# [Phase3 2026-09-26] 自测开关(spec §6 S8 / §7 A1): 只验证 pending_retry.json 读写闭环,
#   不进入主循环、不碰浏览器、不发送。下一轮可清理。
if ($SelfTestRetry) {
    $zeroKeys = @()
    $__t0 = Read-RetryTable
    if ($__t0.items) { $zeroKeys = @($__t0.items.Keys) }
    Write-Output ("SELFTEST-BEFORE keys=[" + (($zeroKeys | Sort-Object) -join ',') + "]")
    Write-Output ("SELFTEST-FILE " + (Get-RetryFile))
    Add-PendingRetry 'ZZ_Phase3_Selftest' 'selftest write->read->delete roundtrip'
    Write-Output ("SELFTEST-RAW " + (Get-Content (Get-RetryFile) -Raw -Encoding UTF8))
    $__t1 = Read-RetryTable
    $__hit = $__t1.items.ContainsKey('zz_phase3_selftest')
    Write-Output ("SELFTEST-READBACK hasSelfTestKey=" + $__hit + " tries=" + $(if($__hit){$__t1.items['zz_phase3_selftest'].tries}else{'-'}) + " nextAt=" + $(if($__hit){$__t1.items['zz_phase3_selftest'].nextAt}else{'-'}))
    Remove-PendingRetry 'ZZ_Phase3_Selftest'
    $__t2 = Read-RetryTable
    $__still = $false
    if ($__t2.items) { $__still = $__t2.items.ContainsKey('zz_phase3_selftest') }
    Write-Output ("SELFTEST-AFTER-DELETE stillPresent=" + $__still)
    $__b = foreach ($i in 0..6) { Get-RetryBackoffMin $i }
    Write-Output ("SELFTEST-BACKOFF " + ($__b -join ','))
    Write-Output "SELFTEST-OK (main loop NOT started)"
    exit 0
}

switch ($Action) {
    "start" { Start-Monitor }
    "stop" { Stop-Monitor }
    default { Write-Output "Usage: monitor.ps1 -Action start|stop" }
}
