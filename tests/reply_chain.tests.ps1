# reply_chain tests - message normalization, scenario decision, compliance and fallbacks.
# Pure logic. No browser, no network, no model, no live data root.
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_chain.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo "scripts"
. (Join-Path $scripts "reply_engine.ps1")
. (Join-Path $scripts "lib\msg_norm.ps1")
. (Join-Path $scripts "lib\reply_policy.ps1")
. (Join-Path $scripts "lib\reply_gen.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n" } }
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }

Write-Output "== reply_chain tests =="
$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
# Build a fixture line exactly the way the page does: [ROLE] text @@TS:<ms> @@OT:<base64 original>
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
function Decide([string[]]$lines) {
    $c = ConvertTo-MessageList ($lines -join $LF) 'Buyer A'
    $f = Get-ConversationFacts $c
    return (Get-ReplyDecision -Conversation $c -Facts $f)
}

# --- 1) order: ascending DOM order is recognized --------------------------------------------
$asc = ConvertTo-MessageList (@((BuyerLine 'hello' 1759400000000), (MeLine 'hi' 1759400100000), (BuyerLine 'any update?' 1759400200000)) -join $LF) 'B'
Assert-Eq "order-ascending-detected" $asc.Order.Ascending $true
Assert-Eq "order-ascending-confident" $asc.Order.Confident $true
Assert-Eq "order-newest-is-last" $asc.LatestBuyer.Text 'any update?'
Assert-Eq "order-buyer-count" $asc.BuyerCount 2

# --- 2) order: a REVERSED window must be detected and corrected ------------------------------
$rev = ConvertTo-MessageList (@((BuyerLine 'any update?' 1759400200000), (MeLine 'hi' 1759400100000), (BuyerLine 'hello' 1759400000000)) -join $LF) 'B'
Assert-Eq "order-reversed-detected" $rev.Order.Ascending $false
Assert-Eq "order-reversed-corrected-newest" $rev.LatestBuyer.Text 'any update?'
Assert-Eq "order-reversed-first-is-oldest" (@($rev.Messages)[0].Text) 'hello'

# --- 3) unknown order must be flagged, not guessed ------------------------------------------
$nots = ConvertTo-MessageList (@('[BUYER] hello', '[ME] hi') -join $LF) 'B'
Assert-Eq "order-unverified-flagged" $nots.Anomaly $true
Assert-Eq "order-unverified-reason" $nots.Order.Reason 'no-trusted-message-timestamps'

# --- 4) SHORT messages must survive (the old extractor dropped len<=2) -----------------------
$short = ConvertTo-MessageList (@((BuyerLine 'ok' 1759400000000), (BuyerLine 'no' 1759400100000), (BuyerLine 'si' 1759400200000)) -join $LF) 'B'
Assert-Eq "short-messages-kept" $short.BuyerCount 3
Assert-Eq "short-message-first" (@($short.BuyerMessages)[0].Text) 'ok'
Assert-Eq "short-message-latest" $short.LatestBuyer.Text 'si'

# --- 5) identity: same text with a different timestamp is a DIFFERENT message ----------------
$t1 = ConvertFrom-MsgRawLine (BuyerLine 'send me the rate' 1759400000000) 0
$t2 = ConvertFrom-MsgRawLine (BuyerLine 'send me the rate' 1759400900000) 1
Assert-True "identity-differs-with-ts" ($t1.StableId -ne $t2.StableId)
Assert-True "identity-confident-with-ts" ([bool]$t1.IdConfident)
$n1 = ConvertFrom-MsgRawLine '[BUYER] no timestamp here' 0
Assert-True "identity-not-confident-without-ts" (-not [bool]$n1.IdConfident)

# --- 6) attachments come from the NEWEST buyer message --------------------------------------
$att = ConvertTo-MessageList (@((BuyerLine 'here is a photo @@IMG:https://x.alicdn.com/a.png' 1759400000000), (MeLine 'got it' 1759400100000), (BuyerLine 'and the size?' 1759400200000)) -join $LF) 'B'
Assert-Eq "attachment-on-older-message" (@($att.BuyerMessages)[0].HasImage) $true
Assert-Eq "newest-has-no-attachment" $att.LatestBuyer.HasImage $false

# --- 7) scenario classification ------------------------------------------------------------
Assert-Eq "scen-human-requested" (Decide @((BuyerLine 'please give me a real person' 1759400000000))).Scenario 'human_requested'
Assert-Eq "scen-stop-bot" (Decide @((BuyerLine 'stop the bot and let a human answer' 1759400000000))).Scenario 'human_requested'
Assert-Eq "scen-complaint" (Decide @((BuyerLine 'this is ridiculous, still no answer' 1759400000000))).Scenario 'complaint'
Assert-Eq "scen-delivery-status" (Decide @((BuyerLine 'did you receive my cargo?' 1759400000000))).Scenario 'delivery_status'
Assert-Eq "scen-quote-ready" (Decide @((BuyerLine 'is my quote ready yet?' 1759400000000))).Scenario 'quote_ready_query'
Assert-Eq "scen-supplier-unreachable" (Decide @((BuyerLine 'I cannot reach my supplier, no reply for days' 1759400000000))).Scenario 'supplier_unreachable'
Assert-Eq "scen-dimension-missing" (Decide @((BuyerLine 'I do not have the sizes, I need to ask the factory' 1759400000000))).Scenario 'dimension_missing'
Assert-Eq "scen-address-clarify" (Decide @((BuyerLine 'which address do you need from me?' 1759400000000))).Scenario 'address_clarify'
Assert-Eq "scen-material-promised" (Decide @((BuyerLine 'I will send the dimensions tomorrow' 1759400000000))).Scenario 'material_promised'
Assert-Eq "scen-billing" (Decide @((BuyerLine 'how do you calculate the chargeable weight?' 1759400000000))).Scenario 'billing_explain'
Assert-Eq "scen-process" (Decide @((BuyerLine 'how does your process work?' 1759400000000))).Scenario 'process_explain'
Assert-Eq "scen-refusal" (Decide @((BuyerLine 'no thanks, not interested' 1759400000000))).Scenario 'refusal'
Assert-Eq "scen-short-ack" (Decide @((BuyerLine 'ok' 1759400000000))).Scenario 'short_ack'
Assert-Eq "scen-short-ack-thanks" (Decide @((BuyerLine 'thanks!' 1759400000000))).Scenario 'short_ack'
Assert-Eq "scen-new-inquiry" (Decide @((BuyerLine 'how much for 2 pallets to Los Angeles?' 1759400000000))).Scenario 'new_inquiry'
Assert-Eq "scen-details-given" (Decide @((BuyerLine '40x30x20cm, 12 kg each, 5 cartons' 1759400000000))).Scenario 'details_given'

# --- 8) ask policy -------------------------------------------------------------------------
$d = Decide @((BuyerLine 'ok' 1759400000000))
Assert-Eq "ask-short-ack-asks-nothing" (@($d.AskFields).Count) 0
$d = Decide @((BuyerLine 'I do not have the sizes, I need to ask the factory' 1759400000000))
Assert-True "ask-dimension-missing-asks-supplier-contact" ($d.AskFields -contains 'supplier')
$d = Decide @((BuyerLine 'I do not have a supplier, I cannot give you the sizes' 1759400000000))
Assert-Eq "ask-no-supplier-does-not-ask-contact" ($d.AskFields -contains 'supplier') $false
$d = Decide @((BuyerLine 'how much for 2 pallets?' 1759400000000))
Assert-Eq "ask-new-inquiry-one-question" (@($d.AskFields).Count) 1
$d = Decide @((BuyerLine 'the carton sizes are 40x30x20 cm' 1759400000000), (BuyerLine 'and 12 kg total' 1759400000000))
Assert-True "ask-does-not-reask-provided-dimensions" (-not ($d.AskFields -contains 'dimension'))
# the 2-per-field limit must be enforced from OUR side of the conversation
$d = Decide @((MeLine 'Could you share the carton sizes?' 1759400000000), (MeLine 'Any luck with the sizes?' 1759400100000), (BuyerLine 'still working on it' 1759400200000))
Assert-True "ask-limit-blocks-third-ask" (-not ($d.AskFields -contains 'dimension'))

# --- 9) todo flags ------------------------------------------------------------------------
foreach ($pair in @(
    @{ t = 'did you receive my cargo?'; k = 'fulfillment_status' },
    @{ t = 'is my quote ready yet?'; k = 'quote_status' },
    @{ t = 'please give me a real person'; k = 'human_requested' },
    @{ t = 'this is ridiculous, still no answer'; k = 'complaint_review' },
    @{ t = 'I cannot reach my supplier, no reply for days'; k = 'supplier_handoff' }
)) {
    $d = Decide @((BuyerLine $pair.t 1759400000000))
    Assert-Eq ("todo-kind: " + $pair.t) $d.TodoKind $pair.k
    Assert-True ("todo-required: " + $pair.t) ([bool]$d.NeedHumanTodo)
}
$d = Decide @((BuyerLine 'ok' 1759400000000))
Assert-True "todo-not-required-for-ack" (-not [bool]$d.NeedHumanTodo)

# --- 10) no deadline may be promised while the notify path is unverified --------------------
$d = Decide @((BuyerLine 'did you receive my cargo?' 1759400000000))
Assert-True "deadline-disallowed-by-default" (-not [bool]$d.AllowTimeCommitment)
$c2 = ConvertTo-MessageList (BuyerLine 'did you receive my cargo?' 1759400000000) 'B'
$d2 = Get-ReplyDecision -Conversation $c2 -Facts (Get-ConversationFacts $c2) -NotifyChannelAvailable $true
Assert-True "deadline-allowed-only-with-verified-channel" ([bool]$d2.AllowTimeCommitment)

# --- 11) compliance ------------------------------------------------------------------------
foreach ($bad in @(
    'The rate is $2,450 all in.',
    'We will reimburse you for the crane rental, this is on us.',
    'Let us talk on WhatsApp.',
    'I have contacted your supplier already.',
    'I will have the supplier contact you.',
    'Please send me your email so I can follow up.',
    'No need for the dimensions - just tell us the weight.',
    'I will ask my manager for a better price.'
)) {
    $chk = Test-ReplyCompliance -Text $bad -Rules $null
    Assert-True ("compliance-blocks: " + $bad) (-not $chk.Ok)
}
foreach ($good in @(
    'Thanks for checking in. I do not want to give you a guess, so I am confirming the current status and will come back to you as soon as I have it.',
    'If you can share your supplier''s contact, I can confirm the cargo details with them directly - that way I get you an accurate quote faster.',
    'Got it, thanks. I will keep an eye on this and let you know if anything needs you.',
    'Happy to help keep everything on the platform - your quotes and documents stay in one place here.'
)) {
    $chk = Test-ReplyCompliance -Text $good -Rules $null
    Assert-True ("compliance-allows: " + $good.Substring(0, [Math]::Min(40, $good.Length))) ($chk.Ok)
}
$chk = Test-ReplyCompliance -Text 'Got it, we should organise the shipment and the colour is fine.' -Rules $null
Assert-True "compliance-warns-british-spelling" (@($chk.Violations | Where-Object { $_.Code -eq 'BRITISH_SPELLING' }).Count -gt 0)
Assert-True "compliance-british-spelling-is-warning-not-block" ($chk.Ok)
$chk = Test-ReplyCompliance -Text '好的，我明白了' -Rules $null
Assert-True "compliance-blocks-non-english" (-not $chk.Ok)

# --- 12) every scenario fallback is compliant and deadline-honest ---------------------------
$scenarios = @('human_requested','complaint','delivery_status','quote_ready_query','supplier_unreachable','dimension_missing','address_clarify','material_promised','billing_explain','process_explain','packing_prep','refusal','short_ack','attachment_only','attachment_parse_failed','details_given','new_inquiry','general')
foreach ($s in $scenarios) {
    $conv = ConvertTo-MessageList (BuyerLine 'placeholder message for the scenario harness' 1759400000000) 'Buyer A'
    $d = Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -ForceScenario $s
    $fb = Get-ScenarioFallback -Decision $d -Rules $null
    Assert-True ("fallback-nonempty: " + $s) (-not [string]::IsNullOrWhiteSpace($fb))
    $chk = Test-ReplyCompliance -Text $fb -Rules $null
    Assert-True ("fallback-compliant: " + $s) ($chk.Ok)
    if (-not $d.AllowTimeCommitment) {
        Assert-True ("fallback-no-invented-deadline: " + $s) (-not (Test-TimeCommitment $fb))
    }
}

# --- 13) context assembly: newest message and facts survive truncation ---------------------
$many = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 40; $i++) { [void]$many.Add((BuyerLine ("older filler message number " + $i) (1759400000000 + $i * 1000))) }
[void]$many.Add((BuyerLine 'FINAL QUESTION: the carton sizes are 40x30x20 cm' 1759499000000))
$bigConv = ConvertTo-MessageList ($many -join $LF) 'B'
$bigFacts = Get-ConversationFacts $bigConv
$bigDec = Get-ReplyDecision -Conversation $bigConv -Facts $bigFacts
$ctx = New-ReplyContextBlock -Conversation $bigConv -Decision $bigDec -MaxChars 1200
Assert-True "context-keeps-newest" ($ctx.Contains('FINAL QUESTION'))
Assert-True "context-has-facts-section" ($ctx.Contains('FACTS AND THEIR EVIDENCE'))
Assert-True "context-has-open-items" ($ctx.Contains('OPEN ITEMS'))
Assert-True "context-keeps-current-message-section" ($ctx.Contains('CURRENT BUYER MESSAGE'))
Assert-True "context-marks-oldest-first" ($ctx.Contains('oldest first'))
Assert-True "context-elides-middle-not-tail" ($ctx.Contains('omitted'))

# --- 14) the reviewed scenario manual is ACTUALLY injectable -------------------------------
$scenPath = Join-Path $scripts 'reply_scenarios.md'
Assert-True "scenario-file-exists" (Test-Path $scenPath)
if (Test-Path $scenPath) {
    $g = Get-ScenarioGuidance -Path $scenPath -Key 'dimension_missing'
    Assert-True "scenario-guidance-resolves" (-not [string]::IsNullOrWhiteSpace($g))
    $dg = Get-DimensionGuidance
    Assert-True "scenario-guidance-has-approved-primary" ($g.Contains([string]$dg.primary))
    foreach ($s in $scenarios) {
        $key = Get-ScenarioGuidanceKey $s
        $txt = Get-ScenarioGuidance -Path $scenPath -Key $key
        Assert-True ("scenario-section-injectable: " + $key) (-not [string]::IsNullOrWhiteSpace($txt))
    }
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
