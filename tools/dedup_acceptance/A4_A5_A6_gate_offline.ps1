# A4_A5_A6_gate_offline.ps1 -- [SPEC-单出口 2026-09-27] §5.1-A4 / A5 / A6 的离线门禁验收
#
# 为什么可以离线验收: 三条判据都是**控制流性质**("某条件下一个发送调用都不发生"), 必须证明的是
#   "门禁在发送之前 return"。本脚本按部署根代码的实际结构做桩驱动, 并对**真实部署文件**做 AST 断言,
#   保证"结构仍然如此", 桩不会被将来改坏的代码骗过。
#
# ⚠️ 只读: 不碰页面、不启动 monitor、不发送、不写任何部署根文件。
#   - 不 dot-source monitor.ps1(那会执行它的主分发);
#   - 用 AST 取真实函数定义, 在只读桩作用域里执行(**不修改部署文件**)。
param(
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path (Split-Path $here -Parent) -Parent
$scripts = Join-Path $root "scripts"
$monitorPath = Join-Path $scripts "monitor.ps1"
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "dedup_stop_20260927" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }

Write-Output "== A4/A5/A6 gate offline acceptance =="

# ---------------------------------------------------------------------------
# 0) 用 AST 解析 monitor.ps1, 取函数定义源码 + 全局语句清单
# ---------------------------------------------------------------------------
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($monitorPath, [ref]$tokens, [ref]$errors)
Assert-True "monitor-parses-clean" ($null -eq $errors -or $errors.Count -eq 0)

$funcAsts = @{}
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $funcAsts[$f.Name] = $f
}
foreach ($need in @('Test-OneTalkPagePresent', 'Invoke-ConvoItem', 'Invoke-ScanRound')) {
    Assert-True ("monitor-has-fn[{0}]" -f $need) ($funcAsts.ContainsKey($need))
}

# 脚本层语句(按行号排序) —— 用来证明"门禁 return 在会话循环之前"
# 注意: 门禁与循环都嵌在 Invoke-ScanRound 的 try 块里, 必须全树 FindAll, 不能只看 EndBlock.Statements
$gateStmt = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.StatementAst]) -and ($n.Extent.Text -match 'ABORT-PAGE-DOWN reason=')
        }, $true) | Sort-Object { $_.Extent.StartLineNumber })
$loopStmt = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -and ($n.Extent.Text -match 'foreach\s*\(\s*\$item\s+in\s+\$snap')
        }, $true) | Sort-Object { $_.Extent.StartLineNumber })
$sendStmt = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.StatementAst]) -and ($n.Extent.Text -match 'Send-OneTalkMessage')
        }, $true) | Sort-Object { $_.Extent.StartLineNumber })
Assert-True "A4-gate-statement-exists" ($gateStmt.Count -gt 0)
Assert-True "A4-convo-loop-exists" ($loopStmt.Count -gt 0)
Assert-True "A4-send-call-exists" ($sendStmt.Count -gt 0)
$gateLine = if ($gateStmt.Count -gt 0) { $gateStmt[0].Extent.StartLineNumber } else { -1 }
$loopLine = if ($loopStmt.Count -gt 0) { $loopStmt[0].Extent.StartLineNumber } else { -1 }
$sendLine = if ($sendStmt.Count -gt 0) { $sendStmt[0].Extent.StartLineNumber } else { -1 }
Write-Output ("    [structure] page-down gate at L{0}, convo loop at L{1}, first send call at L{2}" -f $gateLine, $loopLine, $sendLine)
Assert-True "A4-gate-before-loop" ($gateLine -gt 0 -and $loopLine -gt 0 -and $gateLine -lt $loopLine)
# 循环体内调用的会话处理函数, 必须是**含有唯一发送调用**的那个函数(Invoke-ConvoItem)
$loopText = if ($loopStmt.Count -gt 0) { $loopStmt[0].Extent.Text } else { '' }
Assert-True "A4-loop-calls-convo-handler" ($loopText -match 'Invoke-ConvoItem')
$convoSrcText = $funcAsts['Invoke-ConvoItem'].Extent.Text
Assert-True "A4-send-lives-in-convo-handler" ($convoSrcText -match 'Send-OneTalkMessage')
# 处理函数里的 Send-OneTalkMessage 出现 2 次: 1 次真实调用 + 1 次 §4.2-G2 注释(说明比对点在其内部)。
#   真实调用只允许 1 处 —— 按"非注释行"计数。
$realSend = 0
foreach ($ln in ($convoSrcText -split "`r?`n")) { if ($ln -notmatch '^\s*#' -and $ln -match 'Send-OneTalkMessage') { $realSend++ } }
Assert-Eq "A4-single-real-send-call-in-handler" $realSend 1
# 门禁所在的 if 分支必须以 return 结束(整轮跳过), 不是 continue/break
$gateIfText = if ($gateStmt.Count -gt 0) { $gateStmt[0].Extent.Text } else { '' }
Assert-True "A4-gate-returns-from-round" ($gateIfText -match 'return @\{ Action = .Normal. \}')
Assert-True "A4-gate-logs-skip-round" ($gateIfText -match 'action=skip-round')

# ---------------------------------------------------------------------------
# 1) 加载真实纯函数 + 从 AST 注入真实 Invoke-ConvoItem / Test-OneTalkPagePresent
# ---------------------------------------------------------------------------
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "reply_engine.ps1")
. (Join-Path $scripts "lib\msg_source.ps1")

# ⚠️⚠️ 数据面写保护（本次实测踩过，必须留在这里）:
#   Invoke-ConvoItem 里有一句 `Add-Content (Join-Path $script:dataDir ("msgs_"+时间戳+".txt"))` ——
#   它是**真实函数体**，第一次跑本 harness 时把 7 份桩快照写进了生产 data 目录
#   （msgs_20260927_121616..121700.txt，已删除并在 REPORT 留证）。本 harness 的契约是"只读"，
#   故这里把路径解析强制指向临时目录，任何"想写生产目录"的动作都落到临时区；
#   万一还有漏网的 Add-Content，下面把它改成记录而非落盘。
$script:dataDir = Join-Path $env:TEMP "dedup_acceptance_scratch"
New-Item -ItemType Directory -Force -Path $script:dataDir | Out-Null
$script:logFileDir = $script:dataDir
$script:stateFile = Join-Path $script:dataDir "state.json"
# [SPEC-待回复列表 2026-09-27 §0.1] Invoke-ConvoItem 现在读这两个**脚本级**变量(monitor.ps1 在启动时
#   从配置键装载)。本 harness 不执行 monitor.ps1 的脚本层, 故必须在这里补上, 否则它们是 $null
#   ⇒ 判据的行 3/行 4 用 0 当门槛, 冷却判定静默失效(一种最难发现的假绿)。
#   取值与 monitor 的语义一致: 配置键优先, 缺省 5; 且强制 cooldown ≥ min_gap。
#   静态防线(不属于本 harness): tests\should_reply.tests.ps1 断言 monitor.ps1 里确实是
#   `$script:replyMinGapMin = [int]$script:skillCfg.reply_min_gap_min` 这种**读配置键**的写法。
$script:replyMinGapMin = 5
$script:replyPostSendCooldownMin = 5
$script:requiredSeenRounds = 2
try {
    $__cfg = Get-SkillConfig
    if ($__cfg.PSObject.Properties.Name -contains 'reply_min_gap_min' -and $__cfg.reply_min_gap_min) { $script:replyMinGapMin = [int]$__cfg.reply_min_gap_min }
    if ($__cfg.PSObject.Properties.Name -contains 'reply_post_send_cooldown_min' -and $__cfg.reply_post_send_cooldown_min) { $script:replyPostSendCooldownMin = [int]$__cfg.reply_post_send_cooldown_min }
} catch { }
if ($script:replyPostSendCooldownMin -lt $script:replyMinGapMin) { $script:replyPostSendCooldownMin = $script:replyMinGapMin }
function Get-SkillPath([string]$name) {
    switch ($name) {
        'data' { return $script:dataDir }
        'logs' { return $script:logFileDir }
        'scripts' { return $script:dataDir }
        default { return $script:dataDir }
    }
}
function Add-Content {
    param([string]$Path, $Value, [string]$Encoding)
    [void]$logSink.Add("BLOCKED-ADD-CONTENT $Path")
}

$logSink = New-Object System.Collections.ArrayList
function Write-Log([string]$msg) { [void]$logSink.Add($msg) }
function Send-WecomMessage([string]$m) { return 'STUB-WECOM' }
# ⚠️ 这里**故意不桩** Get-HumanInterjectionGate / Get-HumanInterjectionProbeLines:
#   它们由真实生产文件(msg_source.ps1 定义 / monitor.ps1 调用)提供。曾经的桩
#   `function Get-HumanInterjectionProbeLines([string]$p) { return @() }` 掩盖了阶段 D 才炸出来的
#   真实缺陷(monitor.ps1 调了一个生产代码里根本不存在的函数) —— 桩能"补上"生产缺的东西,
#   这正是最危险的一类假绿。生产缺什么, 这里就必须跟着报错。
function Test-NoReplyBuyer([string]$k) { return $false }
function Get-Snapshot() { return '[]' }
function Switch-ToPendingTab() { return 'ALREADY_ACTIVE' }
# 真实 Open-ConvoAndGetMessages 成功时返回对象 { name, msgs, profile }; msgs 为多行文本
function Open-ConvoAndGetMessages([string]$k) {
    return [pscustomobject]@{
        name    = $k
        msgs    = "[ME] earlier reply @@TS:1790000000000`n[BUYER] stub new buyer message @@TS:1790000000001 @@OT:c3R1Yg=="
        profile = ''
    }
}
function Remove-AttachmentMarkers([string]$t) { return $t }
function Save-BuyerProfile([string]$s, [string]$p) { }
function Invoke-CdpEval([string]$js) { return '' }
function Send-OneTalkMessage([string]$b, [string]$t) { $script:sendCalls++; return 'FILLED | CLICKED | SENT_OK' }
function Get-Rules() { return $null }
function Get-Page() { return $script:stubPage }
function Test-RepliedStateUsable($state) { return @{ Ok = $true; Count = 0; Bytes = 0; Reason = 'stub' } }
function Send-NewInquiryAlert([string]$b, [string]$p) { }
# 走到"生成回复"所需的最小桩(证明 G4 放行时会真的尝试发送 ⇒ 负对照成立)
function Start-LlmRound($k, $b) { return [pscustomobject]@{ sw = [System.Diagnostics.Stopwatch]::StartNew() } }
function Stop-LlmRound { }
function Get-LlmRoundElapsedSec { return 0 }
function Generate-Reply-LLM { return 'stub reply text' }
function Generate-Reply { return 'stub reply text' }
function Test-BannedText([string]$t, $l) { return $null }
function Test-FinancialCommitment([string]$t) { return $null }
function Test-LlmRoundBudgetExceeded { return $false }
# 发送成功后的记账桩: **不写任何账本**(本 harness 只读)
function Set-StateHash($ctx, [string]$skey, [string]$hash) { [void]$logSink.Add("STUB-SET-STATE-HASH $skey $hash") }
function Remove-PendingRetry([string]$k) { }
function Get-GoodsDataStatus($k, $d) { return $null }

$script:sendCalls = 0
$script:stubPage = $null

# 真实函数体(部署根逐字, 未修改文件)
Invoke-Expression ($funcAsts['Test-OneTalkPagePresent'].Extent.Text)
Invoke-Expression ($funcAsts['Invoke-ConvoItem'].Extent.Text)

$item = [pscustomobject]@{ name = 'acceptance stub buyer'; preview = 'stub preview'; unread = $true }
function New-Ctx {
    return @{
        state          = [pscustomobject]@{ replied = [pscustomobject]@{ 'other buyer' = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|1' } }
        openCooldown   = @{}
        skipCooldown   = @{}
        noReplyPreview = @{}
        sendFailCount  = @{}
        failAlertAt    = @{}
        humanPending   = @{}
        lastSendAt     = @{}
        # [SPEC-待回复列表 2026-09-27 §2.1] 连续确认轮数: 会话名 -> 轮数。
        #   本 harness 直接喂"已连读 2 轮", 因为要验收的是 G4/G3 门禁而不是确认机制本身
        #   (确认机制由 tests\should_reply_v2.tests.ps1 用生产函数 Update-PendingSeen 驱动验收)。
        pendingSeen    = @{ 'acceptance stub buyer' = 2 }
        lastActivity   = Get-Date
    }
}

# ---------------------------------------------------------------------------
# 2) A4: 页面不可用 ⇒ 一条都不发
#      (a) 真实 Test-OneTalkPagePresent 在"无 OneTalk 页"时必须判 $true(不可用)
#      (b) 用本次事故时段的真实快照证明: 在那批会话上, 判据本身会判"应回",
#          但门禁先 return ⇒ 会话处理数 0、发送数 0(这就是 11:50 那一轮本该发生的事)
# ---------------------------------------------------------------------------
$script:stubPage = $null
Assert-Eq "A4-no-page-detected" (Test-OneTalkPagePresent) $false
$script:stubPage = [pscustomobject]@{ url = 'https://onetalk.alibaba.com/message/weblitePWA.htm#' }
Assert-Eq "A4-page-present-detected" (Test-OneTalkPagePresent) $true
$script:stubPage = [pscustomobject]@{ url = 'https://i.alibaba.com/hub/alicrm/public_customer' }
Assert-Eq "A4-wrong-page-is-not-onetalk" (Test-OneTalkPagePresent) $false

# 事故现场快照: 用真实数据构造"若门禁不在, 就会走进会话处理"的前提
$dataDir = [string](Get-SkillConfig).data_dir
if (-not $dataDir) { $dataDir = Join-Path (Split-Path $root -Parent) "alibaba-auto-reply-runtime\data" }
$accSnap = Join-Path $dataDir 'msgs_20260927_114208.txt'
$wouldProcess = 0
if (Test-Path $accSnap) {
    $all = @(Get-Content $accSnap -Encoding UTF8)
    $body = $all[1..($all.Count - 1)]
    $wouldProcess = 1
}
$script:sendCalls = 0
$script:logSink | Out-Null
$logSink.Clear()
$ctx = New-Ctx
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)
# 门禁语义(与部署根代码同一条件表达式): 页面缺失 ⇒ 本函数**不被调用**
$pageMissing = -not (Test-OneTalkPagePresent)
$processed = 0
if (-not $pageMissing) { $processed++; Invoke-ConvoItem $ctx $item 2 }
Assert-True "A4-gate-triggered-by-missing-page" $pageMissing
Assert-Eq "A4-convos-processed-zero" $processed 0
Assert-Eq "A4-sends-zero" $script:sendCalls 0
Assert-True "A4-incident-snapshot-would-otherwise-be-processed" ($wouldProcess -eq 1)

# ---------------------------------------------------------------------------
# 3) A5: 同一买家在**最小间隔/发送后冷却**内不可能收到第 2 条
#      [SPEC-待回复列表 2026-09-27 §0.1] 值已由硬编码 15/3 改为配置键, 缺省 **5/5**。
#      ⚠️ 行为变更(必须如实登记, 见 REPORT「与旧 spec 的冲突点」):
#        §0.1 要求 cooldown ≥ min_gap, 缺省二者都是 5 ⇒ 判据第 3 行(POST_SEND_COOLDOWN)
#        **总是**先于第 4 行(RATE_MIN_GAP)命中; 故"刚发过"时日志出现的是 POST_SEND_COOLDOWN,
#        而不是旧标题里的 RATE-SKIP。RATE-SKIP 仍是 §3.2 明文要求保留的**纵深防御**代码路径
#        (若判据判错也发不出去), 但正常情况下不可达 —— 下面第 (c) 段单独断言它仍然在位。
# ---------------------------------------------------------------------------
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-2)   # 2 分钟前刚发过 < 5 分钟门槛
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A5-second-send-blocked" $script:sendCalls 0
Write-Output ("    [diagnostic] log lines = {0}" -f $logSink.Count)
foreach ($l in $logSink) { Write-Output ("      | {0}" -f $l) }
Assert-True "A5-second-send-reason-logged" ([bool](@($logSink | Where-Object { $_ -match 'Reason=POST_SEND_COOLDOWN|RATE-SKIP buyer=' }).Count -gt 0))
$rateLine = @($logSink | Where-Object { $_ -match 'Reason=POST_SEND_COOLDOWN|RATE-SKIP buyer=' })[0]
Write-Output ("    block log: {0}" -f $rateLine)

# 负对照: 间隔超过最小间隔时必须**能**走到发送(证明限流没有把发送全封死, 且桩确实能观察到发送)
#   ⚠️ 匹配式必须精确到 `Reason=`/`RATE-SKIP buyer=` —— 不能只写 POST_SEND_COOLDOWN:
#     发送后的日志里有 `(config key reply_post_send_cooldown_min)`, 而 -match 默认**不区分大小写**,
#     `post_send_cooldown` 会命中 `POST_SEND_COOLDOWN` ⇒ 负对照恒为 FAIL(实测踩过)。
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)
Invoke-ConvoItem $ctx $item 2
Assert-True "A5-beyond-gap-not-rate-blocked" (-not [bool](@($logSink | Where-Object { $_ -match 'Reason=POST_SEND_COOLDOWN|Reason=RATE_MIN_GAP|RATE-SKIP buyer=' }).Count -gt 0))
Assert-Eq "A5-beyond-gap-reaches-send" $script:sendCalls 1
# 发送成功后必须写 POST-SEND-COOLDOWN 且值来自配置键(§0.1: 不得再硬编码 3min)
Assert-True "A5-post-send-cooldown-logged" ([bool](@($logSink | Where-Object { $_ -match 'POST-SEND-COOLDOWN' }).Count -gt 0))
$psLine = @($logSink | Where-Object { $_ -match 'POST-SEND-COOLDOWN' })[0]
Write-Output ("    post-send log: {0}" -f $psLine)
Assert-True "A5-post-send-cooldown-uses-config-value" ($psLine -match ("POST-SEND-COOLDOWN .* {0}min" -f $script:replyPostSendCooldownMin))
Assert-True "A5-post-send-cooldown-records-lastSendAt" ($ctx.lastSendAt.ContainsKey('acceptance stub buyer'))

# (c) 纵深防御仍在位: RATE-SKIP 分支必须还存在于**真实部署文件**里(静态, 与运行态解耦)
$monText = [System.IO.File]::ReadAllText($monitorPath, [System.Text.Encoding]::UTF8)
Assert-True "A5-rate-skip-depth-defense-present" ($monText -match 'RATE-SKIP buyer=')
Assert-True "A5-rate-skip-reads-config-key" ($monText -match 'if \(\$gapMin2 -lt \$script:replyMinGapMin\)')
Assert-True "A5-no-hardcoded-15m-gap" ($monText -notmatch 'if \(\$gapMin -lt 15\)')
Assert-True "A5-no-hardcoded-3x-cooldown" ($monText -notmatch '\[Math\]::Min\(3 \* \[Math\]::Pow')

# ---------------------------------------------------------------------------
# 4) A6: 冷启动只观察(cycle=1 ⇒ 发送数 0、输出 COLD-START)
# ---------------------------------------------------------------------------
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
Invoke-ConvoItem $ctx $item 1
Assert-Eq "A6-cold-start-sends-zero" $script:sendCalls 0
Assert-True "A6-cold-start-logged" ([bool](@($logSink | Where-Object { $_ -match 'COLD-START-SKIP' }).Count -gt 0))
# 负对照: cycle=2 起必须放行(不得把冷启动判成永久只观察)
$logSink.Clear()
Invoke-ConvoItem $ctx $item 2
Assert-True "A6-cycle2-not-cold-start" (-not [bool](@($logSink | Where-Object { $_ -match 'COLD-START-SKIP' }).Count -gt 0))

# 冷启动门禁必须在会话处理入口第一行(早于任何页面操作/提醒)
$convoSrc = $funcAsts['Invoke-ConvoItem'].Extent.Text
$coldIdx = $convoSrc.IndexOf('COLD-START-SKIP')
$firstCdpIdx = $convoSrc.IndexOf('Open-ConvoAndGetMessages')
Assert-True "A6-cold-start-before-page-work" ($coldIdx -gt 0 -and ($firstCdpIdx -lt 0 -or $coldIdx -lt $firstCdpIdx))

# ---------------------------------------------------------------------------
# 5) [FIX-DUP-GUARD 2026-09-27] A7: 同一条买家消息**不得重复回复**
#    事故现场(2026-09-27 16:31-16:50): 买家B 收到 3 条回复(16:31:47 / 16:41:09 /
#    16:50:35, 间隔 9 分半), 期间 buyerMsgs=9 与 lastBuyerHash 恒定、列表预览逐字相同 —— 也就是
#    "最后一条买家消息早就回过了", 可新判据按 §2.2 不再读账本 ⇒ 冷却一到期就再发一条。
#    验收方式: 真实 Invoke-ConvoItem + **真实算法算出的账本键**(同一次抓取里最后一条买家原文的
#    hash + 条数), 证明该轮发不出去; 并证明判据出口没变(仍是 Test-ShouldReply 的既有 5 个 Reason)。
# ---------------------------------------------------------------------------
$hStubLast = Get-StableHash (Get-NormalizedMsgText 'stub')   # 桩消息的 @@OT:c3R1Yg== 解出来就是 stub
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.state = [pscustomobject]@{ replied = [pscustomobject]@{ 'acceptance stub buyer' = "$hStubLast|1" } }
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)   # 让限流不可能是拦截原因
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A7-same-msg-not-resent" $script:sendCalls 0
Assert-True "A7-dup-guard-logged" ([bool](@($logSink | Where-Object { $_ -match 'DUP-GUARD-HOLD' }).Count -gt 0))
$srLine = @($logSink | Where-Object { $_ -match '^SHOULD-REPLY ' }) | Select-Object -First 1
Assert-True "A7-judge-still-single-exit" ([bool]($srLine -match 'Reason=NOT_IN_PENDING_LIST'))
Assert-True "A7-dup-guard-evidence-logged" ([bool]($srLine -match 'alreadyAnswered=True'))
foreach ($l in $logSink) { Write-Output ("      | {0}" -f $l) }

# 负对照(证明这条闸门**真的会放行**, 不是把发送全封死): 买家再说一句 ⇒ 条数 1→2 ⇒ 账本对不上 ⇒ 发
function Open-ConvoAndGetMessages([string]$k) {
    return [pscustomobject]@{
        name    = $k
        msgs    = "[ME] earlier reply @@TS:1790000000000`n[BUYER] stub old buyer message @@TS:1790000000001 @@OT:c3R1Yg==`n[BUYER] stub new buyer message @@TS:1790000000002 @@OT:c3R1Yg=="
        profile = ''
    }
}
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.state = [pscustomobject]@{ replied = [pscustomobject]@{ 'acceptance stub buyer' = "$hStubLast|1" } }
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A7-new-msg-still-sent" $script:sendCalls 1
Assert-True "A7-no-dup-guard-when-new-msg" (-not [bool](@($logSink | Where-Object { $_ -match 'DUP-GUARD-HOLD' }).Count -gt 0))

# ---------------------------------------------------------------------------
# 6) [FIX-WAIT-STACK 2026-09-27] A8: 被 RATE_MIN_GAP 挡下后, 冷却必须**锚在阻塞条件到期的那一刻**
#    事故现场: 17:24:04 发送 → 17:24:47 买家发来新数据 → 17:28:42 判据判"该回"但被 RATE-SKIP 挡下
#    (真实 gap=4.63m < 最小间隔 5m) → 旧代码从"此刻"再装一整段 5 分钟冷却 ⇒ 买家等到 17:33:30
#    (共 8 分 43 秒, 而配置写的只有 5 分钟)。
#    验收: 用真实 Invoke-ConvoItem + 真实 ctx.skipCooldown 记录, 断言 until ≈ 上次发送 + 最小间隔,
#    而不是"此刻 + 一整段冷却"; 并断言时间一到就能正常发出(锚定不是把发送封死)。
# ---------------------------------------------------------------------------
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$sentAt = (Get-Date).AddMinutes(-4.6)   # 4.6 分钟: 判据的 [int] 取整判"不在冷却内", 真实值仍 < 5 ⇒ 走 RATE-SKIP
$ctx.lastSendAt['acceptance stub buyer'] = $sentAt
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A8-rate-skip-no-send" $script:sendCalls 0
Assert-True "A8-rate-skip-logged" ([bool](@($logSink | Where-Object { $_ -match 'RATE-SKIP buyer=' }).Count -gt 0))
$cd = $ctx.skipCooldown['acceptance stub buyer']
Assert-True "A8-cooldown-record-with-until" ([bool]($cd -and $cd.ContainsKey('until')))
if ($cd -and $cd.ContainsKey('until')) {
    $until = [datetime]$cd['until']
    $deltaSec = [Math]::Round([Math]::Abs(($until - $sentAt.AddMinutes($script:replyMinGapMin)).TotalSeconds), 1)
    $waitSec = [Math]::Round((($until - (Get-Date)).TotalSeconds), 1)
    Write-Output ("    [diagnostic] until={0:HH:mm:ss} 锚点误差={1}s 距现在={2}s" -f $until, $deltaSec, $waitSec)
    Assert-True "A8-until-anchored-at-min-gap" ($deltaSec -le 5)
    Assert-True "A8-until-not-now-plus-full-cooldown" ($waitSec -lt 60)
}
# 时间一到必须能发出(把记录里的 until 拨到过去 = 模拟时间流逝), 否则"锚定"就成了"封死"
$ctx.skipCooldown['acceptance stub buyer']['until'] = (Get-Date).AddSeconds(-1)
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-5.1)
$script:sendCalls = 0
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A8-after-boundary-sends" $script:sendCalls 1

# ---------------------------------------------------------------------------
# 7) [FIX-COOLDOWN-LIFT 2026-09-27] A9: 冷却记录**仍在有效期内**时, "预览变化"该往哪边走
#    这一段的两个用例合起来就是本修订第 ② 条的全部语义:
#      (a) 账本证明**买家说了新话** ⇒ 解除页面跳过 ⇒ 发出(时间闸门若放行) —— 买家不该被冷却按住
#      (b) 账本证明**还是那条已回过的消息** ⇒ 让路(COOLDOWN-HOLD) + 重新校准预览基准 ⇒ 不重复打扰
#    (a) 是本次要修的病(实测 买家N 8 分 43 秒); (b) 是防止"解除冷却"退化成"再来一次重复发送"。
# ---------------------------------------------------------------------------
# (a) 买家说了新话: 桩给 2 条买家行(条数 2), 账本记的是旧键 |1 ⇒ 账本对不上 ⇒ 必须放行并发出
function Open-ConvoAndGetMessages([string]$k) {
    return [pscustomobject]@{
        name    = $k
        msgs    = "[ME] earlier reply @@TS:1790000000000`n[BUYER] stub old buyer message @@TS:1790000000001 @@OT:c3R1Yg==`n[BUYER] stub new buyer message @@TS:1790000000002 @@OT:c3R1Yg=="
        profile = ''
    }
}
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.state = [pscustomobject]@{ replied = [pscustomobject]@{ 'acceptance stub buyer' = "$hStubLast|1" } }
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)   # 时间闸门全放行
$ctx.skipCooldown['acceptance stub buyer'] = @{ time = Get-Date; until = (Get-Date).AddMinutes(5); preview = 'stale preview'; pkey = 'stale preview'; buyers = 1; count = 1 }
Invoke-ConvoItem $ctx $item 2
Assert-True "A9-lift-recheck-logged" ([bool](@($logSink | Where-Object { $_ -match 'COOLDOWN-RECHECK' }).Count -gt 0))
Assert-True "A9-lift-logged" ([bool](@($logSink | Where-Object { $_ -match 'COOLDOWN-LIFT' }).Count -gt 0))
Assert-Eq "A9-lift-sends" $script:sendCalls 1
Assert-True "A9-lift-not-held-instead" (-not [bool](@($logSink | Where-Object { $_ -match 'COOLDOWN-HOLD' }).Count -gt 0))

# (b) 还是那条已回过的消息: 1 条买家行 + 账本 |1 ⇒ 必须让路, 且把预览基准重校准(免得每轮都下探开页面)
function Open-ConvoAndGetMessages([string]$k) {
    return [pscustomobject]@{
        name    = $k
        msgs    = "[ME] earlier reply @@TS:1790000000000`n[BUYER] stub new buyer message @@TS:1790000000001 @@OT:c3R1Yg=="
        profile = ''
    }
}
$script:sendCalls = 0
$logSink.Clear()
$ctx = New-Ctx
$ctx.state = [pscustomobject]@{ replied = [pscustomobject]@{ 'acceptance stub buyer' = "$hStubLast|1" } }
$ctx.lastSendAt['acceptance stub buyer'] = (Get-Date).AddMinutes(-20)
$ctx.skipCooldown['acceptance stub buyer'] = @{ time = Get-Date; until = (Get-Date).AddMinutes(5); preview = 'stale preview'; pkey = 'stale preview'; buyers = 1; count = 1 }
Invoke-ConvoItem $ctx $item 2
Assert-Eq "A9-hold-no-send" $script:sendCalls 0
Assert-True "A9-hold-logged" ([bool](@($logSink | Where-Object { $_ -match 'COOLDOWN-HOLD' }).Count -gt 0))
$rebase = $ctx.skipCooldown['acceptance stub buyer']
Assert-True "A9-hold-rebaselined-preview" ([bool]($rebase -and $rebase.pkey -ne 'stale preview'))

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
