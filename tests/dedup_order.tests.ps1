# dedup_order tests -- REPRO for duplicated sends caused by position-dependent dedup
#
# Scenario: the buyer message list order in the DOM is NOT stable. In two real
# snapshots captured seconds apart the same extractor produced opposite orders
# (one newest-first, one oldest-first). A dedup judge that reads "$buyerMsgs[0]"
# ("the first buyer message") therefore flips its answer when the order flips,
# and the bot re-sends an identical reply to a buyer who said nothing new.
#
# The ledger key format is (unchanged): <md5-of-normalized-original-text>|<buyerCount>
#
# Pure logic only. No CDP, no Chrome, no page, no file writes.
#
# [SPEC-待回复列表 2026-09-27] 判据**再次换掉**: docs\specs\判据改为待回复列表_20260927.md
#   旧(SPEC-单出口)锚点 = 账本 HASH|count vs 最后一条买家消息; 新锚点 = **该会话此刻在不在页面的
#   待回复列表里**(连续 2 轮确认) + 发送后冷却/最小间隔。账本仍继续写(§2.2), 但不再参与判定。
#
#   本文件的历史价值 = **顺序无关性的复现证据**。换判据之后这条性质不但保留, 而且变成结构性的:
#   判据的入参里**根本没有任何"消息顺序/条数/hash"维度** ⇒ 顺序翻转不可能再改变结论。
#   故本文件的断言只加强、不放松, 并按 §3.3 把"旧证据锚点已失效"写成显式断言:
#     (a) 同一内容集合、两种相反顺序 ⇒ 结论必须相同(历史主题);
#     (b) 账本 key 取 $ledger / 旧格式 key / 空串 ⇒ 结论必须相同("锚点已退出判定");
#     (c) 买家真说新话仍必须能回(防"修成哑巴") —— 措辞改为: 会话在待回复列表里就必须回,
#         不再要求"账本条数必须增长"才回(那正是 §1.2 的病灶)。
# Do NOT loosen an assertion here to make it green. If a case cannot be made to
# pass by changing production code, the diagnosis is wrong -- stop and report.
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "reply_engine.ps1")
$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }
Write-Output "== dedup_order tests =="

# ---------------------------------------------------------------------------
# Snapshot-to-ledger pipeline (mirrors monitor.ps1's real code path)
# ---------------------------------------------------------------------------
# monitor.ps1 keeps the ORIGINAL text (the @@OT payload) and falls back to the
# displayed text when @@OT is absent; both cases below use plain text lines so
# displayed text == original text.
function Get-MsgPlain([string]$line) {
    return ($line -replace '^\[(BUYER|ME)\]\s*', '' -replace '@@TS:.*$', '').Trim()
}
# Reproduces monitor.ps1 under test: buyerMsgs[0] is treated as "latest".
function Get-LedgerKeyLikeCurrentCode([string[]]$Lines) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $first = Get-MsgPlain $bm[0]
    return (Get-DedupKey (Get-NormalizedMsgText $first) @($bm).Count)
}
# The semantically newest buyer message ("wonderful" = idx 2 below). Used to build
# the ledger, because that is what a dedup judge is SUPPOSED to remember.
function Get-LedgerKeyFromNewest([string[]]$Lines) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $newest = Get-NormalizedMsgText (Get-MsgPlain $bm[-1])
    return (Get-DedupKey $newest @($bm).Count)
}

# The judge under test: the SINGLE exit (SPEC-待回复列表 §2 判定表 5 行).
#   ⚠️ 签名换了: 判定入参 = LedgerUsable / PendingSeenRounds / RequiredSeenRounds /
#      MinutesSinceLastSend / MinGapMinutes / InPostSendCooldown / PostSendCooldownMinutes。
#      $Lines / $LedgerKey / $NormLastBuyerHash 仍然逐字传进去 —— 但只为**证明它们不影响结论**
#      (§2.2「保留但不参与判定」/ anchor-dead 一节)。
function Invoke-Judge([string[]]$Lines, [string]$LedgerKey, [string]$Hash, [int]$SeenRounds) {
    return Test-ShouldReply -LedgerUsable $true -PendingSeenRounds $SeenRounds -RequiredSeenRounds 2 `
        -MinutesSinceLastSend -1 -MinGapMinutes 5 -InPostSendCooldown $false -PostSendCooldownMinutes 5 `
        -ConvoLines $Lines -LedgerKey $LedgerKey -NormLastBuyerHash $Hash
}
# 与 monitor.ps1 的真实数据面同构: 先用 Select-LatestBuyerLine(按账本 hash 内容匹配)挑出
#   "我们上一次回复针对的那条"(顺序漂移时它不会误取位置 0/末位), 再喂给唯一出口。
function Test-Judge([string[]]$Lines, [string]$LedgerKey, [int]$SeenRounds = 2) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $h = ''
    if ($bm.Count -gt 0) {
        $picked = Select-LatestBuyerLine -BuyerLines $bm -SavedKey $LedgerKey
        $h = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $picked))
    }
    return [bool](Invoke-Judge $Lines $LedgerKey $h $SeenRounds).Reply
}
function Test-JudgeReason([string[]]$Lines, [string]$LedgerKey, [int]$SeenRounds = 2) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $h = ''
    if ($bm.Count -gt 0) {
        $picked = Select-LatestBuyerLine -BuyerLines $bm -SavedKey $LedgerKey
        $h = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $picked))
    }
    return [string](Invoke-Judge $Lines $LedgerKey $h $SeenRounds).Reason
}
# 最坏形态的入口: hash 取**数组里最后一条** [BUYER](不做内容匹配选择) —— 旧判据下这是"抽取漂移"
#   的压测点。新判据不看 hash ⇒ 结论必须与 Test-Judge 完全相同(这一条就是"锚点已死"的断言)。
function Test-JudgeLastLine([string[]]$Lines, [string]$LedgerKey, [int]$SeenRounds = 2) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $h = ''
    if ($bm.Count -gt 0) { $h = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $bm[-1])) }
    return [bool](Invoke-Judge $Lines $LedgerKey $h $SeenRounds).Reply
}

# ---------------------------------------------------------------------------
# The conversation. "wonderful" is the NEWEST buyer message; the other two
# predate it. Both orders carry identical content and identical buyer count,
# so a correct judge MUST return the same answer for both.
# ---------------------------------------------------------------------------
$newest = '[BUYER] wonderful wonderful'
$olderA = '[BUYER] Could you please let me know the total'
$olderB = '[BUYER] and i will see how it goes'
$meA    = '[ME] We have branches in major Chinese logistics cities'
$meB    = '[ME] Sure'

# Case A: extractor returned newest-first (observed in snapshot msgs_20260927_021045.txt)
$linesA = @($newest, $meA, $olderA, $meB, $olderB)
# Case B: extractor returned oldest-first (observed in snapshot msgs_20260927_021141.txt)
$linesB = @($meA, $olderA, $meB, $olderB, $newest)

$countA = @($linesA | Where-Object { $_ -match '^\[BUYER\]' }).Count
$countB = @($linesB | Where-Object { $_ -match '^\[BUYER\]' }).Count
Assert-Eq "both-orders-same-buyer-count" $countA $countB
Assert-Eq "buyer-count-is-3" $countA 3

# The ledger records the reply the bot already sent to the NEWEST buyer message.
$ledger = Get-LedgerKeyFromNewest $linesB
Assert-True "ledger-has-key-format" ($ledger -match '^[0-9A-F]{32}\|\d+$')
Assert-Eq "ledger-count-segment-is-buyer-count" (($ledger -split '\|')[1]) '3'
$legacyKey = (($ledger -split '\|')[0]) + '|1789826752752'
# 与任何一条买家消息都对不上的假账本 hash(抽取漂移的极端形态), 后面多处复用
$legacyOther = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|1789826752752'

# ---------------------------------------------------------------------------
# Anchor independence — [SPEC-待回复列表 §2.2/§9] 旧证据锚点(顺序 / 账本 hash / 条数)
# 必须**完全退出**判定。判据的 7 个判定入参里没有任何一个是"消息顺序"或"账本内容"。
# ---------------------------------------------------------------------------
$judgeParams = @((Get-Command Test-ShouldReply).Parameters.Keys)
foreach ($need in @('LedgerUsable', 'PendingSeenRounds', 'RequiredSeenRounds', 'MinutesSinceLastSend', 'MinGapMinutes', 'InPostSendCooldown', 'PostSendCooldownMinutes')) {
    Assert-True ("judge-has-new-param[{0}]" -f $need) ($judgeParams -contains $need)
}
foreach ($gone in @('BuyerCount', 'ConvoLineCount', 'LedgerCount', 'MessageOrder', 'MinuteOfDay')) {
    Assert-True ("judge-has-no-positional-bias-param[{0}]" -f $gone) (-not ($judgeParams -contains $gone))
}

# 两种顺序 + 三种账本 key(现行 $ledger / 旧格式 13 位 / 空串) = 6 种组合 ⇒ 结论必须完全一致
$grid = @()
foreach ($L in @($linesA, $linesB)) {
    foreach ($k in @($ledger, $legacyKey, '')) {
        $grid += ("{0}|{1}" -f (Test-Judge $L $k), (Test-JudgeReason $L $k))
    }
}
Assert-Eq "anchor-grid-single-verdict" (@($grid | Sort-Object -Unique).Count) 1
Assert-Eq "anchor-grid-verdict" $grid[0] 'True|IN_PENDING_LIST'
Write-Output ("  锚点已退出判定: 2 种顺序 × 3 种账本 key = 6 种组合, 结论全部 = {0}" -f $grid[0])

# 抽取漂移的最坏形态(hash 取数组末位、不做内容匹配, 且账本 hash 与任何一条都对不上)
#   必须与常规入口给出**同一个**结论 —— 若哪天有人把 hash 重新接回判定, 这里立刻变红。
Assert-Eq "drift-worst-case-same-verdict-A" (Test-JudgeLastLine $linesA $legacyOther) (Test-Judge $linesA $ledger)
Assert-Eq "drift-worst-case-same-verdict-B" (Test-JudgeLastLine $linesB $legacyOther) (Test-Judge $linesB $ledger)

# ---------------------------------------------------------------------------
# Case A / Case B — 历史上的重复发送复现用例。
# 旧判据: 顺序翻转 ⇒ hash 变 ⇒ 判"有新消息" ⇒ 重复发送(本文件就是为复现它而建的)。
# 新判据: 顺序完全不参与判定 ⇒ 两种顺序结论必须相同, 且**不得**因为顺序翻转而多发。
# ---------------------------------------------------------------------------
Assert-True "A-and-B-same-verdict" ((Test-Judge $linesA $ledger) -eq (Test-Judge $linesB $ledger))
Assert-Eq "A-verdict" (Test-Judge $linesA $ledger) $true
Assert-Eq "B-verdict" (Test-Judge $linesB $ledger) $true
Assert-Eq "A-B-same-reason" (Test-JudgeReason $linesA $ledger) (Test-JudgeReason $linesB $ledger)

# 旧实现的对照: "位置 0 当最新"确实会算出**不同**的账本 key(这就是历史缺陷的形态)。
#   保留它作为"为什么顺序无关性重要"的证据, 但断言方向已改为: 两个 key 不同, 结论却必须相同。
Assert-Eq "A-current-code-ledger-key" (Get-LedgerKeyLikeCurrentCode $linesA) $ledger
Assert-True "B-position-zero-key-differs" ((Get-LedgerKeyLikeCurrentCode $linesB) -ne $ledger)
Assert-True "A-B-verdict-identical-despite-different-derived-keys" ((Test-Judge $linesA (Get-LedgerKeyLikeCurrentCode $linesB)) -eq (Test-Judge $linesB $ledger))

# ---------------------------------------------------------------------------
# Not-in-list must not send, even when the buyer count grew.
# [SPEC-待回复列表 §2 行 2] 判据看的是"在不在待回复列表", 不再看条数是否增长。
# ---------------------------------------------------------------------------
$linesNew = @($linesB + '[BUYER] one more thing, what is the ETA')
Assert-Eq "new-msg-count-is-4" (@($linesNew | Where-Object { $_ -match '^\[BUYER\]' }).Count) 4
$ledgerOld = Get-DedupKey ((Get-NormalizedMsgText (Get-MsgPlain $newest))) 3
# 不在列表(轮数 0) ⇒ 一律不发, 即使买家确实说了新话、账本条数也确实"增加了"
Assert-Eq "not-in-list-no-reply-despite-new-msg" (Test-JudgeReason $linesNew $ledgerOld 0) 'NOT_IN_PENDING_LIST'
Assert-Eq "not-in-list-rounds-1-no-reply" (Test-Judge $linesNew $ledgerOld 1) $false
# 在列表里连读 2 轮 ⇒ 必须回 —— **不再要求**账本条数增长(§1.2: 旧要求正是"无限跳过"的病灶)
Assert-Eq "in-list-2-rounds-replies" (Test-Judge $linesNew $ledgerOld 2) $true
Assert-Eq "in-list-2-rounds-reason" (Test-JudgeReason $linesNew $ledgerOld 2) 'IN_PENDING_LIST'
# 反过来: 条数没变也要回(旧判据在这里判 LEDGER_COUNT_MATCH ⇒ false ⇒ 永不回)
Assert-Eq "unchanged-count-still-replies-when-in-list" (Test-Judge $linesB $ledger 2) $true
Write-Output "  防哑巴: 会话在待回复列表里(连续 2 轮) ⇒ 必回, 与账本条数是否增长无关"

# ---------------------------------------------------------------------------
# Legacy ledger keys. 110 of the 137 live ledger entries carry the OLD key format
# <hash>|<epoch-ms> (13-digit 2nd segment) instead of <hash>|<count>.
# [SPEC-待回复列表 2026-09-27] 新判据**不解析账本键** ⇒ 旧格式与任何异常段都不再是判定输入;
#   唯一剩下的要求是"不得因为传入这种键而抛异常"(第 6 次修复曾因 [int] 溢出崩在真实账本上)。
# ---------------------------------------------------------------------------
$legacyThrew = $false
try { Test-Judge $linesA $legacyKey | Out-Null } catch { $legacyThrew = $true }
Assert-True "legacy-key-does-not-throw" (-not $legacyThrew)
# 旧格式键与原格式键必须给出**同一个**结论(判据已不看键内容)
Assert-Eq "legacy-key-same-verdict-as-current" (Test-Judge $linesA $legacyKey) (Test-Judge $linesA $ledger)
Assert-Eq "legacy-key-same-reason-as-current" (Test-JudgeReason $linesA $legacyKey) (Test-JudgeReason $linesA $ledger)
# 与任何买家消息都对不上的 hash(抽取漂移的极端形态)同样不影响结论
Assert-Eq "unknown-hash-same-verdict" (Test-Judge $linesA $legacyOther) (Test-Judge $linesA $ledger)
# 哨兵 -1(未知) 与缺失第 2 段
$sentinelKey = (($ledger -split '\|')[0] + '|-1')
Assert-Eq "sentinel-minus1-same-verdict" (Test-Judge $linesA $sentinelKey) (Test-Judge $linesA $ledger)
# 缺失 key(从未回复过) ⇒ 在列表里就必须回(防"修成哑巴")
Assert-True "empty-key-in-list-still-replies" (Test-Judge $linesA '' 2)
# 空 key + 不在列表 ⇒ 不发(列表是唯一判据)
Assert-Eq "empty-key-not-in-list-no-reply" (Test-Judge $linesA '' 0) $false
# 账本不可用 ⇒ fail-closed(§2 行 1 / §4.1 裁决 = 方案甲: 账本读不到, 一条都不发)
$rLed = Test-ShouldReply -LedgerUsable $false -PendingSeenRounds 9 -LedgerKey $ledger -ConvoLines $linesA
Assert-Eq "ledger-unusable-failclosed-Reason" $rLed.Reason 'LEDGER_UNUSABLE_FAILCLOSED'
Assert-Eq "ledger-unusable-failclosed-Reply" $rLed.Reply $false

# (d) 旧出口函数必须已经不存在(spec 单出口 §4.1: 整体删除, 不是改)
Assert-True "legacy-fn-removed" ($null -eq (Get-Command Test-NewBuyerMessage -EA SilentlyContinue))

# ---------------------------------------------------------------------------
# Select-LatestBuyerLine -- picks the message the ledger says we replied to,
# instead of whatever happens to sit at index 0. Used for the log line and the
# LLM input, so the operator sees the message we actually answered.
#   [SPEC-待回复列表 2026-09-27 §2.2] 该选择器**继续有效且继续被调用**, 但只服务日志/LLM 输入,
#   不再参与"是否回复"的判定 —— 故本节的断言逐字保留(它的价值与判据无关)。
# ---------------------------------------------------------------------------
Assert-True "selector-fn-exists" ($null -ne (Get-Command Select-LatestBuyerLine -EA SilentlyContinue))
# ledger was written for $newest -> selector must find it in EITHER order
Assert-Eq "selector-finds-newest-in-order-A" (Select-LatestBuyerLine -BuyerLines $linesA -SavedKey $ledger) $newest
Assert-Eq "selector-finds-newest-in-order-B" (Select-LatestBuyerLine -BuyerLines $linesB -SavedKey $ledger) $newest
# it must NOT be position 0 in order B (that is the whole point)
Assert-True "selector-not-position-zero-in-B" ($linesB[0] -ne $newest)
# no ledger / no match -> fall back to the last line (existing assumption)
Assert-Eq "selector-fallback-last" (Select-LatestBuyerLine -BuyerLines $linesB -SavedKey '') $linesB[$linesB.Count - 1]
Assert-Eq "selector-fallback-no-match" (Select-LatestBuyerLine -BuyerLines $linesB -SavedKey 'DEADBEEFDEADBEEFDEADBEEFDEADBEEF|9') $linesB[$linesB.Count - 1]
# empty input must not throw
Assert-Eq "selector-empty-input" (Select-LatestBuyerLine -BuyerLines @() -SavedKey $ledger) ''

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
