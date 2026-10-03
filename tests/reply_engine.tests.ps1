# reply_engine regression tests - PRIMITIVES ONLY (rewritten 2026-10-03).
#
# The old version of this file was mostly a fixture for the intent engine (Generate-Reply plus
# Resolve-IntentEarly/-Info/-Data). That engine was REMOVED: it was a second implementation of
# business policy that disagreed with the prompt, and its assertions pinned behaviour the spec
# deliberately changed (for example "thanks" had to produce "You're welcome", which the reviewed
# scenario guidance now forbids as empty filler). Tests must not lock in behaviour we removed on
# purpose, so this file now covers exactly what reply_engine.ps1 still owns: pure primitives.
#
# Behavioural coverage for the reply chain lives in tests\reply_chain.tests.ps1.
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_engine.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$engine = Join-Path (Split-Path $here -Parent) "scripts\reply_engine.ps1"
. $engine

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n" } }
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }

Write-Output "== reply_engine tests =="

# --- 0) the retired engine must stay retired ------------------------------------------------
foreach ($gone in @('Generate-Reply','Resolve-IntentEarly','Resolve-IntentInfo','Resolve-IntentData','New-ReplyContext','Detect-Lang','Build-MissingQuestion','Resolve-Template')) {
    Assert-True ("retired-absent: " + $gone) ($null -eq (Get-Command $gone -ErrorAction SilentlyContinue))
}

# --- 1) language is always American English -------------------------------------------------
Assert-Eq "lang-always-en" (Get-ReplyLang) "en"

# --- 2) banned words ------------------------------------------------------------------------
Assert-Eq "ban-manager" (Test-BannedText "I will ask my manager" @('manager')) 'manager'
Assert-Eq "ban-manager-plural" (Test-BannedText "checked with managers" @('manager')) 'manager'
Assert-Eq "ban-supervisor" (Test-BannedText "our supervisor says" @('manager','supervisor')) 'supervisor'
Assert-Eq "ban-clean" (Test-BannedText "the container is booked" @('manager','supervisor')) $null
Assert-Eq "ban-word-boundary" (Test-BannedText "management software" @('manager')) $null

# --- 3) liability / fee commitment ----------------------------------------------------------
Assert-True "fin-on-us" ([bool](Test-FinancialCommitment "This is on us, not you."))
Assert-True "fin-reimburse" ([bool](Test-FinancialCommitment "We will reimburse you for the crane rental."))
Assert-True "fin-responsibility" ([bool](Test-FinancialCommitment "We take responsibility for this cost."))
Assert-True "fin-out-of-pocket" ([bool](Test-FinancialCommitment "you shouldn't be out of pocket for that"))
Assert-Eq   "fin-legit-process-not-hit" (Test-FinancialCommitment "we will be responsible for delivering the package to your designated address as agreed upon") $null
Assert-Eq   "fin-clean" (Test-FinancialCommitment "I am checking the status and will come back to you today.") $null

# --- 4) stable hash and normalization -------------------------------------------------------
Assert-Eq "hash-stable" (Get-StableHash "Hello  World!") (Get-StableHash "hello world")
Assert-Eq "hash-punct-insensitive" (Get-StableHash "47 kg.") (Get-StableHash "47 kg")
# Get-NormalizedMsgText deliberately preserves case, but Get-StableHash lowercases, so the dedup
# hash itself is case-insensitive. Assert the real contract rather than an assumed one.
Assert-Eq "hash-case-insensitive" (Get-StableHash (Get-NormalizedMsgText "OK")) (Get-StableHash (Get-NormalizedMsgText "ok"))
Assert-Eq "norm-preserves-case" (Get-NormalizedMsgText "OK") "OK"
Assert-Eq "norm-strips-translation" (Get-NormalizedMsgText "hello there 由阿里提供") "hello there"
Assert-Eq "norm-empty" (Get-NormalizedMsgText "   ") ''
Assert-Eq "dedupkey-format" ((Get-DedupKey "abc" 7) -split '\|')[1] '7'

# --- 5) timestamps -------------------------------------------------------------------------
Assert-Eq "epoch-ms-passthrough" (ConvertTo-EpochMs "1759400000000") ([long]1759400000000)
Assert-Eq "epoch-sec-to-ms" (ConvertTo-EpochMs "1759400000") ([long]1759400000000)
Assert-Eq "epoch-bad" (ConvertTo-EpochMs "not-a-time") $null
Assert-Eq "epoch-empty" (ConvertTo-EpochMs "") $null
Assert-True "epoch-datetime-parses" ($null -ne (ConvertTo-EpochMs "2026-10-03 12:00:00"))

# --- 6) legacy dedup helpers ----------------------------------------------------------------
Assert-Eq "alreadyreplied-same-ts" (Test-AlreadyReplied "H|1759400000000" "H" "1759400000000") $true
Assert-Eq "alreadyreplied-newer" (Test-AlreadyReplied "H|1759400000000" "H" "1759400001000") $false
Assert-Eq "alreadyreplied-difftext" (Test-AlreadyReplied "H|1759400000000" "OTHER" "1759400001000") $false
Assert-Eq "dedup-hit-same-count" (Test-DedupHit "H|3" "H" 3) $true
Assert-Eq "dedup-hit-more" (Test-DedupHit "H|3" "H" 4) $false

# --- 7) the single "should reply" exit ------------------------------------------------------
$r = Test-ShouldReply -LedgerUsable $false -PendingSeenRounds 9 -MinutesSinceLastSend -1
Assert-Eq "shouldreply-ledger-unusable" $r.Reason 'LEDGER_UNUSABLE_FAILCLOSED'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 1 -MinutesSinceLastSend -1
Assert-Eq "shouldreply-not-in-list" $r.Reason 'NOT_IN_PENDING_LIST'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 0 -RequiredSeenRounds 0 -MinutesSinceLastSend -1
Assert-Eq "shouldreply-required-rounds-floor-2" $r.Reason 'NOT_IN_PENDING_LIST'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 2 -InPostSendCooldown $true
Assert-Eq "shouldreply-cooldown" $r.Reason 'POST_SEND_COOLDOWN'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 2 -MinutesSinceLastSend 3 -MinGapMinutes 5
Assert-Eq "shouldreply-min-gap" $r.Reason 'RATE_MIN_GAP'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 2 -MinutesSinceLastSend 5 -MinGapMinutes 5
Assert-Eq "shouldreply-gap-equal-passes" $r.Reason 'IN_PENDING_LIST'
$r = Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 2 -MinutesSinceLastSend -1
Assert-Eq "shouldreply-first-time" $r.Reason 'IN_PENDING_LIST'

# --- 8) a CONFIRMED NEW message is not blocked by the old-message cooldown -------------------
$old = @{ LedgerUsable = $true; PendingSeenRounds = 2; MinutesSinceLastSend = 1; MinGapMinutes = 5; InPostSendCooldown = $true }
Assert-Eq "newmsg-old-message-still-blocked" (Test-ShouldReply @old).Reason 'POST_SEND_COOLDOWN'
Assert-Eq "newmsg-passes-with-evidence" (Test-ShouldReply @old -ConfirmedNewMessage $true -SecondsSinceLastSend 120).Reason 'IN_PENDING_LIST'
Assert-Eq "newmsg-floor-applies" (Test-ShouldReply @old -ConfirmedNewMessage $true -SecondsSinceLastSend 5 -NewMessageFloorSeconds 20).Reason 'NEW_MESSAGE_FLOOR'
Assert-Eq "newmsg-floor-not-before-first-send" (Test-ShouldReply @old -ConfirmedNewMessage $true -SecondsSinceLastSend -1).Reason 'IN_PENDING_LIST'
Assert-Eq "newmsg-still-needs-ledger" (Test-ShouldReply -LedgerUsable $false -PendingSeenRounds 5 -ConfirmedNewMessage $true -SecondsSinceLastSend 999).Reason 'LEDGER_UNUSABLE_FAILCLOSED'
Assert-Eq "newmsg-still-needs-two-rounds" (Test-ShouldReply -LedgerUsable $true -PendingSeenRounds 1 -ConfirmedNewMessage $true -SecondsSinceLastSend 999).Reason 'NOT_IN_PENDING_LIST'

# --- 9) positive evidence for a genuinely new buyer message ---------------------------------
Assert-Eq "evidence-count-increased" (Test-ConfirmedNewBuyerMessage -LedgerKey 'ABC|3' -BuyerCount 4 -NormLastBuyerHash 'ZZZ') $true
Assert-Eq "evidence-hash-changed" (Test-ConfirmedNewBuyerMessage -LedgerKey 'ABC|3' -BuyerCount 3 -NormLastBuyerHash 'ZZZ') $true
Assert-Eq "evidence-same-message" (Test-ConfirmedNewBuyerMessage -LedgerKey 'ABC|3' -BuyerCount 3 -NormLastBuyerHash 'ABC') $false
Assert-Eq "evidence-legacy-key" (Test-ConfirmedNewBuyerMessage -LedgerKey 'ABC' -BuyerCount 9 -NormLastBuyerHash 'ZZZ') $false
Assert-Eq "evidence-overflow-key" (Test-ConfirmedNewBuyerMessage -LedgerKey 'ABC|1788799769241' -BuyerCount 9 -NormLastBuyerHash 'ZZZ') $false
Assert-Eq "evidence-empty" (Test-ConfirmedNewBuyerMessage -LedgerKey '' -BuyerCount 3 -NormLastBuyerHash 'X') $false

# --- 10) already-answered guard -------------------------------------------------------------
Assert-Eq "answered-exact" (Test-BuyerMsgAlreadyAnswered -LedgerKey 'H|3' -BuyerCount 3 -NormLastBuyerHash 'H') $true
Assert-Eq "answered-more-messages" (Test-BuyerMsgAlreadyAnswered -LedgerKey 'H|3' -BuyerCount 4 -NormLastBuyerHash 'H') $false
Assert-Eq "answered-hash-differs" (Test-BuyerMsgAlreadyAnswered -LedgerKey 'H|3' -BuyerCount 3 -NormLastBuyerHash 'X') $false
Assert-Eq "answered-overflow-failsafe" (Test-BuyerMsgAlreadyAnswered -LedgerKey 'H|1788799769241' -BuyerCount 9 -NormLastBuyerHash 'H') $false

# --- 11) ledger selector --------------------------------------------------------------------
$lines = @('[BUYER] first @@TS:1759400000000', '[ME] ok @@TS:1759400100000', '[BUYER] second @@TS:1759400200000')
Assert-Eq "select-latest-default" (Select-LatestBuyerLine -BuyerLines @($lines[0],$lines[2]) -SavedKey '') $lines[2]
$h0 = Get-StableHash (Get-NormalizedMsgText 'first')
Assert-Eq "select-by-ledger" (Select-LatestBuyerLine -BuyerLines @($lines[0],$lines[2]) -SavedKey ($h0 + '|1')) $lines[0]

# --- 12) dimension guidance + the orphaned hint check --------------------------------------
$g = Get-DimensionGuidance
Assert-True "dim-primary-mentions-supplier-contact" ($g.primary -match "supplier's contact")
Assert-Eq   "dim-fallback-count" (@($g.fallbacks).Count) 3
Assert-True "dim-primary-no-price" (-not ($g.primary -match '\$\s?\d'))
Assert-Eq "dim-hint-blocks-implied-quote" (Test-NoDimensionQuoteHint "We can quote you without the dimensions.") $true
Assert-Eq "dim-hint-blocks-no-need" (Test-NoDimensionQuoteHint "There is no need to measure anything, we can proceed.") $true
Assert-Eq "dim-hint-allows-primary" (Test-NoDimensionQuoteHint ([string]$g.primary)) $false
Assert-Eq "dim-hint-empty" (Test-NoDimensionQuoteHint '') $false

# --- 13) promised fields and missing info ---------------------------------------------------
$p = @(Get-PromisedFields @('[BUYER] i will send you the dimensions tomorrow'))
Assert-True "promised-dimension" ($p -contains 'dimension')
$p2 = @(Get-PromisedFields @('[BUYER] here are the dimensions: 10x10x10'))
Assert-Eq "promised-already-sent-not-promised" ($p2 -contains 'dimension') $false
$m = @(Get-MissingInfo "the weight is 20 kg" @("Goods total weight (kg)","Packaging dimensions L*W*H"))
Assert-True "missing-weight-provided" (-not ($m -match 'weight'))
Assert-True "missing-dims-absent" ([bool]($m -match 'dimension'))

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
