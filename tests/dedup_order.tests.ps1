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

# The judge under test. Prefers the fixed pure function; until it exists it falls
# back to the current implementation so this file reproduces the defect.
function Test-Judge([string[]]$Lines, [string]$LedgerKey) {
    $bm = @($Lines | Where-Object { $_ -match '^\[BUYER\]' })
    $count = @($bm).Count
    if (Get-Command Test-NewBuyerMessage -ErrorAction SilentlyContinue) {
        return [bool](Test-NewBuyerMessage -BuyerLines $bm -SavedKey $LedgerKey)
    }
    $hText = Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $bm[0]))
    return (-not (Test-DedupHit $LedgerKey $hText $count))
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
# ledger built when count was 3 -> count grew -> must be judged as NEW
$ledgerOld = Get-DedupKey ((Get-NormalizedMsgText (Get-MsgPlain $newest))) 3
Assert-True "genuinely-new-msg-detected" (Test-Judge $linesNew $ledgerOld)

# ---------------------------------------------------------------------------
# Legacy ledger keys. 110 of the 135 live ledger entries carry the OLD key format
# <hash>|<epoch-ms> (13-digit 2nd segment) instead of <hash>|<count>. A naive
# [int] cast of that segment throws (Int32 overflow) and would abort the round.
# The judge must not throw, and must fall back to conservative "text same ->
# already replied" for this shape.
# ---------------------------------------------------------------------------
Assert-True "legacy-fn-exists" ($null -ne (Get-Command Test-NewBuyerMessage -EA SilentlyContinue))
$legacyKey = (Get-DedupKey ((Get-NormalizedMsgText (Get-MsgPlain $newest))) 0)
$legacyKey = ($legacyKey -split '\|')[0] + '|1789826752752'
$legacyVerdict = $null
$legacyThrew = $false
try { $legacyVerdict = Test-NewBuyerMessage -BuyerLines $linesA -SavedKey $legacyKey -CurrentHash (Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $newest))) }
catch { $legacyThrew = $true }
Assert-True "legacy-key-does-not-throw" (-not $legacyThrew)
# same text in the ledger -> conservatively "no new message" (do not send)
Assert-True "legacy-key-same-text-no-new" ($legacyVerdict -eq $false)
# different text in the ledger -> treated as new (pre-existing fallback behavior)
$legacyOther = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA|1789826752752'
Assert-True "legacy-key-other-text-is-new" ((Test-NewBuyerMessage -BuyerLines $linesA -SavedKey $legacyOther -CurrentHash (Get-StableHash (Get-NormalizedMsgText (Get-MsgPlain $newest)))))
# sentinel count -1 (unknown) must be conservative too
$sentinelKey = (($ledger -split '\|')[0] + '|-1')
Assert-True "sentinel-minus1-no-new" ((Test-NewBuyerMessage -BuyerLines $linesA -SavedKey $sentinelKey -CurrentHash '') -eq $false)
# missing key -> first contact -> new
Assert-True "empty-key-is-new" ((Test-NewBuyerMessage -BuyerLines $linesA -SavedKey '' -CurrentHash '') -eq $true)

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
