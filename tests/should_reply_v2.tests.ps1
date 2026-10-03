# should_reply_v2 tests -- [SPEC-待回复列表 2026-09-27 §3.4] 新判据的**规格验收**文件
#
# 与 should_reply.tests.ps1 的分工:
#   · should_reply.tests.ps1 = 旧文件改写(§3.3): 旧 8 行 → 新 5 行的语义迁移 + A8 单出口静态检查
#   · **本文件**             = 新规格验收(§3.4): 5 行判定表逐行 / 瞬态误读 / 连续 2 轮确认 /
#                              冷却与最小间隔; 并把 monitor.ps1 里**真实的** Update-PendingSeen
#                              用 AST 取出来驱动, 证明"连续确认轮数"这条防线真的按 §2.1 工作。
#
# ⚠️ 本文件必须保持 UTF-8 **带 BOM**(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码 ⇒ 中文乱码)。
# 纯逻辑: 不 dot-source monitor.ps1(那会执行它的主分发)、不碰页面、不启动 monitor、不写任何文件。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "reply_engine.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }

Write-Output "== should_reply_v2 tests =="

# ---------------------------------------------------------------------------
# 0) §2 判定表 5 行: Reason 字符串**逐字**断言 + 优先级(先命中先返回)
# ---------------------------------------------------------------------------
# 每一行一个独立的"最小输入"(其余项都取 §2 行 5 的放行值), 便于一眼看出是哪一行命中。
$PASS_ALL = @{
    LedgerUsable            = $true
    PendingSeenRounds       = 2
    RequiredSeenRounds      = 2
    MinutesSinceLastSend    = -1
    MinGapMinutes           = 5
    InPostSendCooldown      = $false
    PostSendCooldownMinutes = 5
}
function J2([hashtable]$over = @{}) {
    $p = @{}
    foreach ($k in $PASS_ALL.Keys) { $p[$k] = $PASS_ALL[$k] }
    if ($over) { foreach ($k in $over.Keys) { $p[$k] = $over[$k] } }
    return Test-ShouldReply @p
}

$rows = @(
    @{ row = 1; desc = '账本(去重状态)不可用'; over = @{ LedgerUsable = $false }
       wantReply = $false; wantReason = 'LEDGER_UNUSABLE_FAILCLOSED' },
    @{ row = 2; desc = '该会话不在待回复列表'; over = @{ PendingSeenRounds = 0 }
       wantReply = $false; wantReason = 'NOT_IN_PENDING_LIST' },
    @{ row = 2; desc = '连续确认轮数 < 2'; over = @{ PendingSeenRounds = 1 }
       wantReply = $false; wantReason = 'NOT_IN_PENDING_LIST' },
    @{ row = 3; desc = '该会话在发送后冷却期内'; over = @{ InPostSendCooldown = $true }
       wantReply = $false; wantReason = 'POST_SEND_COOLDOWN' },
    @{ row = 4; desc = '该会话距上次成功发送 < 最小间隔'; over = @{ MinutesSinceLastSend = 4 }
       wantReply = $false; wantReason = 'RATE_MIN_GAP' },
    @{ row = 5; desc = '以上都不命中(在列表且不在冷却/间隔内)'; over = @{}
       wantReply = $true;  wantReason = 'IN_PENDING_LIST' }
)
foreach ($c in $rows) {
    $r = J2 $c.over
    Assert-Eq ("§2-row{0}[{1}]-Reply" -f $c.row, $c.desc) $r.Reply $c.wantReply
    Assert-Eq ("§2-row{0}[{1}]-Reason" -f $c.row, $c.desc) $r.Reason $c.wantReason
}
Write-Output "  §2 判定表: 5 行(行 2 两种形态)逐行断言, Reason 逐字"

# 优先级: 先命中先返回(§2「按顺序判定」)。构造"多行同时成立"的输入, 断言**最靠前**的那一行胜出。
Assert-Eq "order-1-beats-all" (J2 @{ LedgerUsable = $false; PendingSeenRounds = 0; InPostSendCooldown = $true; MinutesSinceLastSend = 0 }).Reason 'LEDGER_UNUSABLE_FAILCLOSED'
Assert-Eq "order-2-beats-3-4" (J2 @{ PendingSeenRounds = 1; InPostSendCooldown = $true; MinutesSinceLastSend = 0 }).Reason 'NOT_IN_PENDING_LIST'
Assert-Eq "order-3-beats-4" (J2 @{ InPostSendCooldown = $true; MinutesSinceLastSend = 0 }).Reason 'POST_SEND_COOLDOWN'
Assert-Eq "order-4-alone" (J2 @{ MinutesSinceLastSend = 0 }).Reason 'RATE_MIN_GAP'

# Reason 全集必须是**恰好这 5 个**(多一个都意味着有人偷偷加了第二个判据出口)
$reasons = @($rows | ForEach-Object { $_.wantReason } | Sort-Object -Unique)
Assert-Eq "reason-set-is-exactly-5" $reasons.Count 5
Assert-Eq "reason-set-content" ($reasons -join ',') 'IN_PENDING_LIST,LEDGER_UNUSABLE_FAILCLOSED,NOT_IN_PENDING_LIST,POST_SEND_COOLDOWN,RATE_MIN_GAP'

# ---------------------------------------------------------------------------
# 1) §2.1 瞬态误读: 第 1 轮命中、第 2 轮消失 ⇒ **永久** Reply=false
#    两种瞬态的实机形态(写进断言名, 便于与 REPORT 对照):
#      ① 标签切换瞬间读到上一个视图的残留节点(13:04:23 读到 23 个且 visibility:hidden)
#      ② 切标签后列表短暂塌成 height:0(.all-list-container 实测 hidden/h0)
# ---------------------------------------------------------------------------
$t1 = J2 @{ PendingSeenRounds = 1 }   # 第 1 轮: 残留节点让列表"命中"
$t2 = J2 @{ PendingSeenRounds = 0 }   # 第 2 轮: 残留消失(计数被删键)
Assert-Eq "transient-round1-Reply" $t1.Reply $false
Assert-Eq "transient-round1-Reason" $t1.Reason 'NOT_IN_PENDING_LIST'
Assert-Eq "transient-round2-Reply" $t2.Reply $false
Assert-Eq "transient-round2-Reason" $t2.Reason 'NOT_IN_PENDING_LIST'
# "永久": 之后任意多轮都不再可能因为那次残留而放行(轮数必须从 0 重新攒)
foreach ($later in 1..6) {
    Assert-Eq ("transient-later-round{0}-Reply" -f $later) (J2 @{ PendingSeenRounds = 0 }).Reply $false
}

# 连续 2 轮命中 ⇒ 第 2 轮 Reply=true(§0 硬判据 1)
$c1 = J2 @{ PendingSeenRounds = 1 }
$c2 = J2 @{ PendingSeenRounds = 2 }
Assert-Eq "consecutive-round1-Reply" $c1.Reply $false
Assert-Eq "consecutive-round1-Reason" $c1.Reason 'NOT_IN_PENDING_LIST'
Assert-Eq "consecutive-round2-Reply" $c2.Reply $true
Assert-Eq "consecutive-round2-Reason" $c2.Reason 'IN_PENDING_LIST'

# ---------------------------------------------------------------------------
# 2) §2.1 把 monitor.ps1 里**真实的** Update-PendingSeen 取出来驱动(不是测试桩)
#    为什么必须取真实函数: 桩能"补上"生产缺的东西 —— 这正是最危险的一类假绿
#    (见 tools\dedup_acceptance\static_call_closure.ps1 的立项目由)。
# ---------------------------------------------------------------------------
$monPath = Join-Path $scripts 'monitor.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($monPath, [ref]$tokens, [ref]$errors)
Assert-True "monitor-parses-clean" ($null -eq $errors -or $errors.Count -eq 0)

$fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-PendingSeen' }, $true))
Assert-Eq "update-pending-seen-defined-in-production" $fnAsts.Count 1
# 反向自检: AST 取法本身必须能区分"有"和"没有"(否则这一段只是安慰剂)
$bogus = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'UpdatePendingSeenThatDoesNotExist' }, $true))
Assert-Eq "ast-extraction-reverse-check" $bogus.Count 0

if ($fnAsts.Count -eq 1) {
    Invoke-Expression $fnAsts[0].Extent.Text
    Assert-True "update-pending-seen-callable" ($null -ne (Get-Command Update-PendingSeen -EA SilentlyContinue))

    function New-Snap([string[]]$names) {
        $a = @()
        foreach ($n in $names) { $a += [pscustomobject]@{ name = $n; preview = 'stub preview'; unread = $true } }
        return $a
    }
    # §2.1 原文: 「每轮 Get-Snapshot 后更新;命中则 +1,未命中则删除。只有 ≥2 才允许发。」
    $ctx = @{ pendingSeen = @{} }
    Update-PendingSeen $ctx (New-Snap @('Alice', 'Bob'))
    Assert-Eq "seen-round1-Alice-1" $ctx.pendingSeen['Alice'] 1
    Assert-Eq "seen-round1-Bob-1" $ctx.pendingSeen['Bob'] 1
    Assert-Eq "seen-round1-judge-Alice" (J2 @{ PendingSeenRounds = $ctx.pendingSeen['Alice'] }).Reply $false

    Update-PendingSeen $ctx (New-Snap @('Alice', 'Carol'))
    Assert-Eq "seen-round2-Alice-2" $ctx.pendingSeen['Alice'] 2
    Assert-Eq "seen-round2-judge-Alice" (J2 @{ PendingSeenRounds = $ctx.pendingSeen['Alice'] }).Reason 'IN_PENDING_LIST'
    # 未命中 ⇒ **删除键**(不是置 0 —— 置 0 会让"曾经连读两轮"的旧计数在中断后被复用)
    Assert-Eq "seen-round2-Bob-key-removed" ($ctx.pendingSeen.ContainsKey('Bob')) $false
    Assert-Eq "seen-round2-Carol-1" $ctx.pendingSeen['Carol'] 1

    # 瞬态残留的整条时间线: 只有第 1 轮出现 ⇒ 永远攒不到 2
    $ctxT = @{ pendingSeen = @{} }
    Update-PendingSeen $ctxT (New-Snap @('Ghost'))
    $rt1 = J2 @{ PendingSeenRounds = $(if ($ctxT.pendingSeen.ContainsKey('Ghost')) { [int]$ctxT.pendingSeen['Ghost'] } else { 0 }) }
    Update-PendingSeen $ctxT (New-Snap @('Real'))
    $rt2 = J2 @{ PendingSeenRounds = $(if ($ctxT.pendingSeen.ContainsKey('Ghost')) { [int]$ctxT.pendingSeen['Ghost'] } else { 0 }) }
    Assert-Eq "ghost-round1-Reply" $rt1.Reply $false
    Assert-Eq "ghost-round2-Reply" $rt2.Reply $false
    Assert-Eq "ghost-key-gone" ($ctxT.pendingSeen.ContainsKey('Ghost')) $false

    # 真正连续 2 轮 ⇒ 第 2 轮放行(端到端: 快照 → 计数 → 判据)
    $ctxR = @{ pendingSeen = @{} }
    Update-PendingSeen $ctxR (New-Snap @('RealBuyer'))
    $rr1 = J2 @{ PendingSeenRounds = $ctxR.pendingSeen['RealBuyer'] }
    Update-PendingSeen $ctxR (New-Snap @('RealBuyer'))
    $rr2 = J2 @{ PendingSeenRounds = $ctxR.pendingSeen['RealBuyer'] }
    Assert-Eq "real-round1-Reply" $rr1.Reply $false
    Assert-Eq "real-round1-Reason" $rr1.Reason 'NOT_IN_PENDING_LIST'
    Assert-Eq "real-round2-Reply" $rr2.Reply $true
    Assert-Eq "real-round2-Reason" $rr2.Reason 'IN_PENDING_LIST'

    # 空快照(列表空了) ⇒ 所有键清空; 恢复后从 1 重新攒(不得复用旧计数)
    Update-PendingSeen $ctxR (New-Snap @())
    Assert-Eq "empty-snapshot-clears-all" $ctxR.pendingSeen.Count 0
    Update-PendingSeen $ctxR (New-Snap @('RealBuyer'))
    Assert-Eq "after-empty-restart-from-1" $ctxR.pendingSeen['RealBuyer'] 1
    Assert-Eq "after-empty-not-immediately-sendable" (J2 @{ PendingSeenRounds = $ctxR.pendingSeen['RealBuyer'] }).Reply $false

    # 会话名前后空格必须归一(快照的 name 已 trim, 与 Invoke-ConvoItem 的 $key = $item.name.Trim() 对齐)
    $ctxS = @{ pendingSeen = @{} }
    Update-PendingSeen $ctxS (New-Snap @('  Spaced Buyer  '))
    Assert-Eq "seen-name-trimmed" $ctxS.pendingSeen['Spaced Buyer'] 1

    # 缺 pendingSeen 键的 ctx(纵深防御)不得抛异常, 且会被补上
    $ctxNoKey = @{}
    $threwSeen = $false
    try { Update-PendingSeen $ctxNoKey (New-Snap @('X')) } catch { $threwSeen = $true }
    Assert-True "seen-missing-key-no-throw" (-not $threwSeen)
    Assert-Eq "seen-missing-key-created" $ctxNoKey.pendingSeen['X'] 1

    # 快照里的空名/空项必须被跳过(否则会造出 "" 这个永远删不掉的幽灵键)
    $ctxE = @{ pendingSeen = @{} }
    Update-PendingSeen $ctxE (@([pscustomobject]@{ name = ''; preview = 'x' }, $null, [pscustomobject]@{ name = 'Real'; preview = 'y' }))
    Assert-Eq "seen-blank-names-skipped" $ctxE.pendingSeen.Count 1
    Assert-Eq "seen-real-kept" $ctxE.pendingSeen['Real'] 1
} else {
    Assert-True "update-pending-seen-section-skipped" $false
}

# ---------------------------------------------------------------------------
# 3) §2 行 3/4: 冷却内 / 间隔内的 Reason 与边界; §0.1 两个值的配置面
# ---------------------------------------------------------------------------
Assert-Eq "cooldown-wins-over-gap" (J2 @{ InPostSendCooldown = $true; MinutesSinceLastSend = 1; MinGapMinutes = 5 }).Reason 'POST_SEND_COOLDOWN'
Assert-Eq "min-gap-inside" (J2 @{ MinutesSinceLastSend = 4; MinGapMinutes = 5 }).Reason 'RATE_MIN_GAP'
Assert-Eq "min-gap-boundary-equal-passes" (J2 @{ MinutesSinceLastSend = 5; MinGapMinutes = 5 }).Reason 'IN_PENDING_LIST'
Assert-Eq "min-gap-beyond-passes" (J2 @{ MinutesSinceLastSend = 12; MinGapMinutes = 5 }).Reason 'IN_PENDING_LIST'
Assert-Eq "min-gap-never-sent-passes" (J2 @{ MinutesSinceLastSend = -1 }).Reason 'IN_PENDING_LIST'
# 冷却的配置值本身不改变布尔判定的语义(调用方按同一 lastSendAt 判定), 但必须能自由改而不改代码
Assert-Eq "cooldown-config-value-independent" (J2 @{ InPostSendCooldown = $true; PostSendCooldownMinutes = 30 }).Reason 'POST_SEND_COOLDOWN'
# 同一买家在最小间隔内不可能收到第 2 条(§0 硬判据 2): 构造"发送成功 1 分钟后再判"
Assert-Eq "second-message-blocked-within-gap" (J2 @{ MinutesSinceLastSend = 1; MinGapMinutes = 5 }).Reply $false
Assert-Eq "second-message-allowed-after-gap" (J2 @{ MinutesSinceLastSend = 5; MinGapMinutes = 5 }).Reply $true

$cfg = Get-SkillConfig
Assert-Eq "cfg-reply_min_gap_min" ([int]$cfg.reply_min_gap_min) 5
Assert-Eq "cfg-reply_post_send_cooldown_min" ([int]$cfg.reply_post_send_cooldown_min) 5
Assert-True "cfg-cooldown-ge-min-gap" ([int]$cfg.reply_post_send_cooldown_min -ge [int]$cfg.reply_min_gap_min)
# 判据的**参数缺省值**也必须是 §0.1 的新值(防止有人只改 monitor 调用点、把函数缺省留成 15/3)
$monRaw = [System.IO.File]::ReadAllText($monPath, [System.Text.Encoding]::UTF8)
$engRaw = [System.IO.File]::ReadAllText((Join-Path $scripts 'reply_engine.ps1'), [System.Text.Encoding]::UTF8)
Assert-True "judge-param-default-min-gap-5" ($engRaw -match '\[int\]\$MinGapMinutes\s*=\s*5,')
Assert-True "judge-param-default-cooldown-5" ($engRaw -match '\[int\]\$PostSendCooldownMinutes\s*=\s*5,')
Assert-True "judge-param-default-required-seen-2" ($engRaw -match '\[int\]\$RequiredSeenRounds\s*=\s*2,')
Assert-True "monitor-does-not-hardcode-15" ($monRaw -notmatch 'if \(\$gapMin -lt 15\)')
Assert-True "monitor-does-not-hardcode-3x" ($monRaw -notmatch '\[Math\]::Min\(3 \* \[Math\]::Pow')

# ---------------------------------------------------------------------------
# 4) §4.1 待裁决项: 执行会话必须二选一并留证 —— 本实现取**方案甲**(保守)
#    方案甲: 账本读不到 ⇒ 本轮一条都不发(P6 保持)。技术证据 = 判据行 1 与整轮门禁同时在位。
# ---------------------------------------------------------------------------
Assert-Eq "§4.1-decision-A-judge-blocks" (J2 @{ LedgerUsable = $false }).Reply $false
Assert-Eq "§4.1-decision-A-reason" (J2 @{ LedgerUsable = $false }).Reason 'LEDGER_UNUSABLE_FAILCLOSED'
Assert-True "§4.1-decision-A-round-gate-kept" ($monRaw -match 'STATE-UNUSABLE: ledger unreadable')
Assert-True "§4.1-decision-A-judge-guard-kept" ($monRaw -match '-LedgerUsable \$ledgerUsableNow')
Write-Output "  §4.1 裁决: 方案甲(保守) —— 账本不可读 ⇒ 判据行 1 fail-closed, 且整轮门禁 P6 保持"

# ---------------------------------------------------------------------------
# 5) §9 单出口: Test-ShouldReply 仍是**唯一**出口(本次换判据, 不是加第二个出口)
# ---------------------------------------------------------------------------
$tokens2 = $null; $errors2 = $null
$astEng = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'reply_engine.ps1'), [ref]$tokens2, [ref]$errors2)
Assert-True "engine-parses-clean" ($null -eq $errors2 -or $errors2.Count -eq 0)
$engFns = @($astEng.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
Assert-True "single-exit-fn-still-exists" ($engFns -contains 'Test-ShouldReply')
Assert-True "legacy-judge-fn-still-gone" (-not ($engFns -contains 'Test-NewBuyerMessage'))
# 判据函数必须是纯函数: 函数体内不得出现文件/页面/进程访问
$judgeAsts = @($astEng.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ShouldReply' }, $true))
Assert-Eq "judge-fn-found-once" $judgeAsts.Count 1
$fnSrc = if ($judgeAsts.Count -eq 1) { [string]$judgeAsts[0].Extent.Text } else { '' }
foreach ($forbidden in @('Get-Content', 'Set-Content', 'Add-Content', 'Invoke-CdpEval', 'Invoke-Expression', 'Start-Process', 'Out-File', 'Get-SkillConfig')) {
    Assert-True ("judge-is-pure-no[{0}]" -f $forbidden) ($fnSrc -notmatch [regex]::Escape($forbidden))
}

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
