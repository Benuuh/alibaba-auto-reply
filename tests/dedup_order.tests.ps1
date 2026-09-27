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
# RED/GREEN contract for this file (spec 6-R3 / 6-V1):
#   - Against the CURRENT implementation ($buyerMsgs[0] == "latest") case B fails.
#     That failure IS the reproduction evidence.
#   - Against the FIXED implementation (Test-NewBuyerMessage, order independent)
#     both cases pass.
#   ⚠️ [SPEC-单出口 2026-09-27] Test-NewBuyerMessage 已按 spec §4.1 **整体删除**(它的回退分支
#     "文本 hash 不同即算新消息"是第 6 次修复失效的直接原因)。本文件已改为对**唯一出口**
#     reply_engine.ps1::Test-ShouldReply 断言, 并新增"旧格式账本键必须 fail-closed"一节。
#     本文件的历史价值(顺序无关性的复现证据)保持不变; 断言只加强, 不放松。
# Do NOT loosen an assertion here to make it green. If case B cannot be made to
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
# Reproduces monitor.ps1 L942-944 under test: buyerMsgs[0] is treated as "latest".
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

# The judge under test: the SINGLE exit (spec §4.1).
#   与 monitor.ps1 的真实数据面逐字同构: 先用 Select-LatestBuyerLine(按账本 hash 内容匹配)
#   挑出"我们上一次回复针对的那条" —— 顺序漂移时它不会误取位置 0/末位 —— 再喂给 Test-ShouldReply。
function Test-Judge([string[]]$Lines, [string]$LedgerKey) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $picked = Select-LatestBuyerLine -BuyerLines $bm -SavedKey $LedgerKey
    $hLast = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $picked))
    return [bool](Test-ShouldReply -ConvoLines $Lines -LedgerKey $LedgerKey -NormLastBuyerHash $hLast).Reply
}
# 最坏形态的判据入口: hash 取**数组里最后一条** [BUYER](不做内容匹配选择),
#   用来直接压测 fail-closed 取向 —— 抽取漂移时也不得判"应回"。
function Test-JudgeLastLine([string[]]$Lines, [string]$LedgerKey) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $hLast = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $bm[-1]))
    return [bool](Test-ShouldReply -ConvoLines $Lines -LedgerKey $LedgerKey -NormLastBuyerHash $hLast).Reply
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

# ---------------------------------------------------------------------------
# Case A -- order = newest first. Buyer said nothing new since our reply.
# A correct judge says "no new message" (do NOT send).
# ---------------------------------------------------------------------------
Assert-True "A-no-new-message" (-not (Test-Judge $linesA $ledger))
# Control: in order A the current (position-based) code happens to agree, because
# here the first line IS the newest one. So case B alone isolates the order defect.
Assert-Eq "A-current-code-ledger-key" (Get-LedgerKeyLikeCurrentCode $linesA) $ledger

# ---------------------------------------------------------------------------
# Case B -- SAME conversation, SAME ledger, only the extracted order flipped.
# Still "no new message" (do NOT send). This is the reproduction: the current
# implementation reads the OLDEST line as "latest", computes a different hash,
# and concludes "new message" -> duplicate send.
# ---------------------------------------------------------------------------
Assert-True "B-no-new-message" (-not (Test-Judge $linesB $ledger))

# Order independence must hold in both directions for the same content set.
Assert-Eq "A-B-same-verdict" (Test-Judge $linesA $ledger) (Test-Judge $linesB $ledger)

# ---------------------------------------------------------------------------
# Guard: a genuinely NEW buyer message (count grows) must still be detected.
# A fix that always says "already replied" would silence real replies -- that is
# worse than the duplicate send, so this must stay false.
# ---------------------------------------------------------------------------
$linesNew = @($linesB + '[BUYER] one more thing, what is the ETA')
$ledgerNew = Get-LedgerKeyFromNewest $linesNew
Assert-Eq "new-msg-count-is-4" (@($linesNew | Where-Object { $_ -match '^\[BUYER\]' }).Count) 4
# ledger built when count was 3 -> buyer count is now 4 -> must be judged as NEW.
#   [SPEC-单出口] 走的是 Test-JudgeLastLine(hash 取"数组最后一条", 模拟抽取漂移的最坏形态):
#   条数不等 ⇒ 账本记录的不是这一批 ⇒ 说明买家又说话了 ⇒ 应回(且 Reason 必须是 BUYER_AFTER_ME)。
$ledgerOld = Get-DedupKey ((Get-NormalizedMsgText (Get-MsgPlain $newest))) 3
Assert-True "genuinely-new-msg-detected" (Test-JudgeLastLine $linesNew $ledgerOld)
$rNew = Test-ShouldReply -ConvoLines $linesNew -LedgerKey $ledgerOld `
    -NormLastBuyerHash (Get-StableHash (Get-NormalizedMsgText 'one more thing, what is the ETA'))
Assert-Eq "genuinely-new-msg-reason" $rNew.Reason 'BUYER_COUNT_INCREASED'

# 而"账本 hash 正是数组最后一条买家消息"时(已回过这条) ⇒ 必须不发
Assert-Eq "ledger-hash-of-last-line-not-reply" (Test-JudgeLastLine $linesNew $ledgerNew) $false

# ---------------------------------------------------------------------------
# Legacy ledger keys. 110 of the 135 live ledger entries carry the OLD key format
# <hash>|<epoch-ms> (13-digit 2nd segment) instead of <hash>|<count>.
# [SPEC-单出口 2026-09-27] 行为**已变更**(spec §4.1 必须删掉的旧出口):
#   旧实现 Test-NewBuyerMessage 的第二段不可解析时会退回"文本 hash 不同即算新消息" ⇒ 误发;
#   新实现的唯一出口 Test-ShouldReply 对旧格式键一律 **fail-closed**(证明不了就不发)。
#   本节断言据此改写: 旧格式键在两种形态下都不得判"应回"。
# ---------------------------------------------------------------------------
$legacyKey = (($ledger -split '\|')[0]) + '|1789826752752'

# (a) 旧格式键的 hash 能对上"我方回复针对的那条"(选择器按内容匹配) ⇒ 命中行2, 不发
Assert-Eq "legacy-key-selector-hash-match" (Test-Judge $linesA $legacyKey) $false
$rLegacy = Test-ShouldReply -ConvoLines $linesA -LedgerKey $legacyKey `
    -NormLastBuyerHash (Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $newest)))
Assert-Eq "legacy-key-selector-reason" $rLegacy.Reason 'LEDGER_HASH_MATCH'

# (b) 账本 hash 与快照里任何一条买家消息都对不上(抽取漂移) + 第二段不可解析:
#     判据此时**不能**证明"是新消息"(hash 对不上、条数不可解析) ⇒ 只要不是"买家又开口",
#     一律 fail-closed(不发)。这是旧代码 Test-NewBuyerMessage 的回退分支
#     ("文本 hash 不同即算新消息")会**误发**的那条路径。
$legacyOther = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|1789826752752'
Assert-Eq "legacy-key-other-hash-me-tail-failclosed" (Test-JudgeLastLine @($olderB, $meA) $legacyOther) $false
#     反过来: 我方回复之后买家又开口(最后一行是 [BUYER]) ⇒ 必须仍能回(行6 BUYER_AFTER_ME),
#     否则就是"修成哑巴"。两者一起才说明 fail-closed 没有过度收紧。
Assert-Eq "legacy-key-other-hash-buyer-tail-still-replies" (Test-JudgeLastLine $linesA $legacyOther) $true

# (b2) 同一旧格式键 + "我方消息排在最后"(订单已收尾) ⇒ 同样不得判"应回"
Assert-Eq "legacy-key-me-tail-failclosed" (Test-JudgeLastLine @($olderB, $meA) $legacyOther) $false

# (c) 旧格式键绝不抛异常(第 6 次修复曾因 [int] 溢出崩在真实账本上)
$legacyThrew = $false
try { Test-Judge $linesA $legacyKey | Out-Null } catch { $legacyThrew = $true }
Assert-True "legacy-key-does-not-throw" (-not $legacyThrew)

# (d) 旧出口函数必须已经不存在(spec §4.1: 整体删除, 不是改)
Assert-True "legacy-fn-removed" ($null -eq (Get-Command Test-NewBuyerMessage -EA SilentlyContinue))

# (e) 哨兵 -1(未知) 与缺失第 2 段一律 fail-closed
$sentinelKey = (($ledger -split '\|')[0] + '|-1')
Assert-Eq "sentinel-minus1-not-reply" (Test-JudgeLastLine @($olderB, $meA) $sentinelKey) $false
# 缺失 key(从未回复过) ⇒ 首次问询, 必须仍能回(防"修成哑巴")
Assert-True "empty-key-is-new" (Test-JudgeLastLine $linesA '')

# ---------------------------------------------------------------------------
# Select-LatestBuyerLine -- picks the message the ledger says we replied to,
# instead of whatever happens to sit at index 0. Used for the log line and the
# LLM input, so the operator sees the message we actually answered.
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
