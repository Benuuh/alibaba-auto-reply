# lib\reply_policy.ps1 - The single authoritative business policy for the reply chain.
#
# RESPONSIBILITY (spec 5, item 2): given the same facts and conversation state, decide the response
# TYPE, the necessary questions and whether a human todo is required, and emit a SMALL decision
# object. This file never touches the browser, never calls a model and never sends anything.
# It is pure and side-effect free so the offline acceptance harness can drive it directly.
#
# WHY IT EXISTS (spec 5, "one authoritative implementation"):
#   Before this file the same policy was spread across four places that could drift apart:
#     - scripts\reply_agent_prompt.md   (prose: ask limits, red lines, scenario table, 55 auto-appended rules)
#     - scripts\reply_rules.json        (40 "never" rules with heavy semantic duplication)
#     - scripts\reply_engine.ps1        (rule-engine branches with their own question logic)
#     - scripts\monitor.ps1             (inline image fallback text, ask counting, rewrite hints)
#   The decision of "what kind of reply is this and what may it ask" now has exactly ONE
#   implementation: Get-ReplyDecision. Language expression lives in reply_agent_prompt.md,
#   hard bounds live in reply_rules.json plus the invariant patterns below, and reviewed
#   scenario examples live in reply_scenarios.md. Nothing else may restate policy.
#
# DEPENDENCY: reply_engine.ps1 supplies Test-BannedText / Test-FinancialCommitment (the existing
# single authorities for banned words and liability commitments). Those are CALLED, never copied,
# so a fix in one place cannot leave a stale twin behind.

if (-not (Get-Command Test-BannedText -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'reply_engine.ps1')
}

# ============================================================================================
# HARD BOUNDS
# These are structural limits, not style advice. No style suggestion may ever relax them
# (spec 5: "hard constraints must not be removable ... style suggestions must not silently relax
# business facts, fee commitments, identity checks and send protection").
# ============================================================================================

# Stating a price, a price range or a discount. A bare number is NOT a price (weights, carton
# counts and dimensions are legitimate), so a currency marker or a price word must sit next to
# the number. The buyer's own target figure is deliberately NOT echoed back to the buyer; it is
# recorded in the local todo instead, which is why there is no attribution exception here.
$script:PolicyPricePatterns = @(
    '\$\s*\d',
    '\b\d+(\.\d+)?\s*(usd|dollars?|bucks)\b',
    '\b(usd|eur|cny|rmb)\s*\d',
    '(?i)\b(price|rate|cost|quote|charge|fee|discount)\b[^.!?]{0,24}\b\d',
    '(?i)\b\d[^.!?]{0,24}\b(price|rate|per\s+(kg|cbm|container))\b'
)

# Exchanging contact details, or asking the buyer for their OWN contact details.
# The supplier's contact is a cargo-information source and is explicitly allowed; the buyer's own
# contact is a platform red line. Keeping both in one place is what makes that distinction checkable.
$script:PolicyContactPatterns = @(
    '(?i)[\w\.\-\+]+@[\w\-]+\.[A-Za-z]{2,}',
    '(?i)\b(whatsapp|we\s?chat|wechat|telegram|skype|viber|line\s?app|signal)\b',
    '(?i)\b(?:my|our)\s+(?:phone|number|mobile|cell)\b',
    '(?i)\bcall\s+me\b',
    '(?i)\boff[\s\-]?platform\b',
    '(?i)\bpay\s+(?:me\s+)?(?:directly|outside)\b'
)

# Promises the robot cannot keep. The dimension-guidance wording approved by the owner
# ("If you can share your supplier's contact, I can confirm the cargo details with them directly")
# is a CONDITIONAL offer and is deliberately NOT matched here. What is forbidden is claiming the
# contact already happened, or promising that the supplier will contact the buyer.
$script:PolicyUnsupportedPromisePatterns = @(
    '(?i)\bi(?:''|ha)?ve\s+(?:already\s+)?(?:contacted|reached\s+out\s+to|emailed|called)\b',
    '(?i)\bi\s+(?:have\s+)?contacted\s+(?:your\s+|the\s+)?(?:supplier|vendor|factory|warehouse)\b',
    '(?i)\bi(?:''|ll| will)\s+have\s+(?:the\s+|your\s+)?(?:supplier|vendor|factory)\s+contact\s+you\b',
    '(?i)\b(?:the|your)\s+(?:supplier|vendor|factory)\s+will\s+(?:contact|call|reach)\s+you\b',
    '(?i)\bi(?:''|ll| will)\s+(?:contact|call|reach\s+out\s+to)\s+(?:your\s+|the\s+)?(?:supplier|vendor|factory)\b',
    '(?i)\bi(?:''|ll| will)\s+arrange\s+(?:the\s+)?(?:pickup|pick\s?up|collection)\b',
    '(?i)\b(?:guaranteed|we\s+guarantee)\s+(?:delivery|arrival|clearance)\b'
)

# A time commitment is only allowed when the system can back it with a real local todo AND a
# successful notification (spec 4.3: "Do not invent a specific response deadline ... when the
# robot promises a verifiable in-system action, it must correspond to a real todo or a
# successful notification"). Generation asks this to pick a wording that it can actually honor.
$script:PolicyTimeCommitmentPatterns = @(
    '(?i)\bby\s+(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
    '(?i)\bwithin\s+\d+\s*(hour|hours|hrs|day|days|business\s+day|business\s+days)\b',
    '(?i)\bby\s+end\s+of\s+(day|business|week)\b',
    '(?i)\b(?:today|tomorrow)\s+(?:morning|afternoon|evening)\b',
    '(?i)\bby\s+\d{1,2}(:\d{2})?\s*(am|pm)\b'
)

# The reply language is American English regardless of the buyer's language (spec 4.3). A reply
# containing CJK characters, or the most common non-English function words, is a language
# regression and gets one bounded rewrite before falling back.
$script:PolicyNonEnglishPatterns = @(
    '[\u4e00-\u9fff]',
    '[\u3040-\u30ff]',
    '[\uac00-\ud7af]',
    '[¡¿]',
    '(?i)\b(gracias|precio|cotizaci[oó]n|env[ií]o|direcci[oó]n|obrigado|obrigada|pre[cç]o|cota[cç][aã]o|mercadoria|merci|devis|bonjour|livraison|exp[eé]dition)\b'
)

# Common British spellings. Low-severity: it triggers a rewrite hint, never a hard block.
$script:PolicyBritishSpellings = @{
    'colour' = 'color'; 'colours' = 'colors'; 'favour' = 'favor'; 'favours' = 'favors'
    'behaviour' = 'behavior'; 'centre' = 'center'; 'metre' = 'meter'; 'metres' = 'meters'
    'organise' = 'organize'; 'organised' = 'organized'; 'organisation' = 'organization'
    'realise' = 'realize'; 'realised' = 'realized'; 'licence' = 'license'
    'catalogue' = 'catalog'; 'cheque' = 'check'; 'tyre' = 'tire'; 'aluminium' = 'aluminum'
    'travelled' = 'traveled'; 'cancelled' = 'canceled'; 'apologise' = 'apologize'
    'analyse' = 'analyze'; 'defence' = 'defense'; 'offence' = 'offense'; 'grey' = 'gray'
    'fulfil' = 'fulfill'; 'enquiry' = 'inquiry'; 'enquiries' = 'inquiries'
}

function Get-PolicyHardBounds {
    return [pscustomobject]@{
        PricePatterns       = $script:PolicyPricePatterns
        ContactPatterns     = $script:PolicyContactPatterns
        UnsupportedPromises = $script:PolicyUnsupportedPromisePatterns
        TimeCommitments     = $script:PolicyTimeCommitmentPatterns
        NonEnglish          = $script:PolicyNonEnglishPatterns
        BritishSpellings    = $script:PolicyBritishSpellings
    }
}

# ============================================================================================
# COMPLIANCE
# ============================================================================================

# True when the text asks for, or offers, the BUYER's own contact details rather than the
# supplier's. Kept separate because the generic contact pattern list cannot express "whose".
function Test-BuyerContactExchange([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    # A supplier-qualified phrase is the allowed case; strip it before looking for the buyer's own.
    $scrubbed = [regex]::Replace($Text, "(?i)(your|the)\s+supplier'?s?\s+(contact|number|phone|email|whatsapp)", ' SUPPLIER_CONTACT ')
    if ($scrubbed -match "(?i)\byour\s+(own\s+)?(contact|number|phone|mobile|cell|email|whatsapp|we\s?chat|wechat)\b") { return $true }
    if ($scrubbed -match "(?i)\b(send|share|give|provide)\s+(me\s+)?(your|ur)\s+(contact|number|phone|email|whatsapp)\b") { return $true }
    return $false
}

# Full pre-send policy check. Returns @{ Ok; Violations = @( @{ Code; Severity; Detail } ) }.
# Severity 'block' => must be rewritten or replaced by the scenario fallback.
# Severity 'warn'  => rewrite hint only; a single bounded rewrite may fix it, otherwise it ships.
function Test-ReplyCompliance {
    [CmdletBinding()]
    param(
        [string]$Text,
        $Rules = $null,
        $Decision = $null
    )
    $violations = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) {
        [void]$violations.Add(@{ Code = 'EMPTY'; Severity = 'block'; Detail = 'reply text is empty' })
        return [pscustomobject]@{ Ok = $false; Violations = @($violations.ToArray()) }
    }

    # 1) Banned words - delegated to the existing single authority, never re-implemented.
    $dest = $null
    if ($Decision -and $Decision.Facts) { $dest = $Decision.Facts.Destination }
    if ($dest -and $dest.QuoteUsable -and $dest.Kind -eq 'amazon_warehouse') {
        # Deterministic request vocabulary; deliberately does not reject a simple acknowledgment.
        $request = '(?i)(?:send|share|provide|give|need|require|confirm|tell|what|which|could|can you|please)[^.!?]{0,100}(?:address|street|city|state|zip|postal|warehouse|destination|code)|(?:address|street|city|state|zip|postal|warehouse|destination|code)[^.!?]{0,45}(?:required|needed|missing|please|\?)'
        $code = [regex]::Escape([string]$dest.WarehouseCode)
        $codeRequest = '(?i)\b(?:confirm|verify|provide|send|share)\s+(?:the\s+)?(?:amazon\s+)?' + $code + '\b|\b(?:is|should|can|which|what)\b[^.!?]{0,60}\b' + $code + '\b[^.!?]*\?'
        if ($Text -match $request -or $Text -match $codeRequest) {
            [void]$violations.Add(@{ Code = 'DESTINATION_REASK'; Severity = 'block'; Detail = 'Buyer already provided a usable Amazon warehouse; do not re-request destination, address, postal details or warehouse code.' })
        }
    }
    $banned = $null
    if ($Rules -and $Rules.banned_phrases) { $banned = @($Rules.banned_phrases) }
    $banHit = Test-BannedText $Text $banned
    if ($banHit) {
        [void]$violations.Add(@{ Code = 'BANNED_PHRASE'; Severity = 'block'; Detail = [string]$banHit })
    }

    # 2) Liability / fee commitment - delegated to the existing single authority.
    $finHit = Test-FinancialCommitment $Text
    if ($finHit) {
        [void]$violations.Add(@{ Code = 'LIABILITY_COMMITMENT'; Severity = 'block'; Detail = [string]$finHit })
    }

    # 3) Price disclosure.
    foreach ($p in $script:PolicyPricePatterns) {
        if ($Text -match $p) {
            [void]$violations.Add(@{ Code = 'PRICE_DISCLOSURE'; Severity = 'block'; Detail = $p })
            break
        }
    }

    # 4) Contact exchange.
    if (Test-BuyerContactExchange $Text) {
        [void]$violations.Add(@{ Code = 'BUYER_CONTACT_REQUEST'; Severity = 'block'; Detail = 'asks for or offers the buyer''s own contact details' })
    }
    foreach ($p in $script:PolicyContactPatterns) {
        if ($Text -match $p) {
            # 'whatsapp'/'wechat' may legitimately appear inside the approved "keep it on the
            # platform" refusal, so only the concrete address forms and call-me/off-platform
            # phrasings are blocking.
            if ($p -match 'whatsapp|we\s?chat|wechat|telegram|skype|viber|line' ) {
                if ($Text -match "(?i)(?:let'?s|we can|you can|add me|message me|talk|contact me)[^.!?]{0,30}\b(?:whatsapp|we\s?chat|wechat|telegram|skype|viber)\b") {
                    [void]$violations.Add(@{ Code = 'CONTACT_EXCHANGE'; Severity = 'block'; Detail = $p })
                }
            } else {
                [void]$violations.Add(@{ Code = 'CONTACT_EXCHANGE'; Severity = 'block'; Detail = $p })
            }
        }
    }

    # 5) Promises the robot cannot keep.
    foreach ($p in $script:PolicyUnsupportedPromisePatterns) {
        if ($Text -match $p) {
            [void]$violations.Add(@{ Code = 'UNSUPPORTED_PROMISE'; Severity = 'block'; Detail = $p })
            break
        }
    }

    # 6) Language must be American English.
    foreach ($p in $script:PolicyNonEnglishPatterns) {
        if ($Text -match $p) {
            [void]$violations.Add(@{ Code = 'NOT_AMERICAN_ENGLISH'; Severity = 'block'; Detail = $p })
            break
        }
    }

    # 6b) "We can still quote you without the dimensions" style hints. Test-NoDimensionQuoteHint
    # already existed but had NO caller anywhere in production (found by the 2026-10-03 inventory),
    # so the pricing red line it protects was never actually enforced on generated text. It is
    # wired in here rather than re-implemented, keeping one definition of the forbidden hints.
    if (Get-Command Test-NoDimensionQuoteHint -ErrorAction SilentlyContinue) {
        if (Test-NoDimensionQuoteHint $Text) {
            [void]$violations.Add(@{ Code = 'NO_DIMENSION_QUOTE_HINT'; Severity = 'block'; Detail = 'implies a quote is possible without dimensions' })
        }
    }

    # 7) American spelling (warning only).
    foreach ($k in $script:PolicyBritishSpellings.Keys) {
        if ($Text -match ('(?i)\b' + [regex]::Escape($k) + '\b')) {
            [void]$violations.Add(@{ Code = 'BRITISH_SPELLING'; Severity = 'warn'; Detail = ($k + ' -> ' + $script:PolicyBritishSpellings[$k]) })
        }
    }

    $list = @($violations.ToArray())
    $blocked = @($list | Where-Object { $_.Severity -eq 'block' }).Count -gt 0
    return [pscustomobject]@{ Ok = (-not $blocked); Violations = $list }
}

# True when the text commits to a specific deadline. Callers must only allow this when a real
# local todo plus a successful notification exist (see Get-ReplyDecision's AllowTimeCommitment).
function Test-TimeCommitment([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($p in $script:PolicyTimeCommitmentPatterns) { if ($Text -match $p) { return $true } }
    return $false
}

# ============================================================================================
# DECISION
# ============================================================================================

# Per-field question counts taken from OUR side of the conversation. Moved here from monitor.ps1
# so the "how many times did we already ask" rule has one implementation shared by the policy
# layer, the rule engine and the replay harness.
function Get-AskCounts([object[]]$Messages) {
    $counts = @{ weight = 0; dimension = 0; address = 0; image = 0; supplier = 0 }
    foreach ($m in @($Messages)) {
        if (-not $m -or $m.Role -ne 'me') { continue }
        if ($m.Text -notmatch '[\?？]') { continue }
        $lc = $m.Text.ToLowerInvariant()
        if ($lc -match 'weight|kg|peso|公斤|千克|gross') { $counts.weight++ }
        if ($lc -match 'dimension|size|尺寸|medida|\bcm\b|\bmm\b') { $counts.dimension++ }
        if ($lc -match 'address|addr|地址|calle|street|endere|rua|(?:which|what).{0,30}(?:amazon|fba).{0,15}warehouse|warehouse.{0,15}code') { $counts.address++ }
        if ($lc -match 'image|photo|picture|图片|图') { $counts.image++ }
        if ($lc -match 'supplier|供应商|fornecedor|proveedor') { $counts.supplier++ }
    }
    return $counts
}

# The maximum number of times we may ask for one field across the whole conversation.
$script:PolicyMaxAskPerField = 2

# Which fields are still legitimately askable. A field is NOT askable when the buyer already
# provided it, when the buyer promised it, or when we already asked the maximum number of times.
function Get-AskableFields {
    [CmdletBinding()]
    param($Facts, $AskCounts, [string[]]$PromisedFields = @(), [string[]]$AllowedFields = @())

    $promised = @($PromisedFields)
    $askable = New-Object System.Collections.ArrayList
    $consider = @('weight', 'dimension', 'address', 'image')
    if ($AllowedFields.Count -gt 0) { $consider = @($AllowedFields) }
    foreach ($f in $consider) {
        $provided = $false
        switch ($f) {
            'weight'    { $provided = [bool]$Facts.HasWeight }
            'dimension' { $provided = [bool]$Facts.HasDimensions }
            'address'   { $provided = [bool]$Facts.HasQuoteDestination }
            'image'     { $provided = [bool]$Facts.HasImages }
            # Only an actual contact value counts as provided (see Get-ConversationFacts).
            'supplier'  { $provided = [bool]$Facts.HasSupplierContact }
        }
        if ($provided) { continue }
        if ($promised -contains $f) { continue }
        $used = 0
        if ($AskCounts -and $AskCounts.ContainsKey($f)) { $used = [int]$AskCounts[$f] }
        if ($used -ge $script:PolicyMaxAskPerField) { continue }
        [void]$askable.Add($f)
    }
    return @($askable.ToArray())
}

# Scenario classification. Ordered by the priority required by spec 4.2:
#   safety constraints -> the current concrete request -> emotion and human requests ->
#   assistance we can actually perform -> only then the information the current stage needs.
# Returns @{ Scenario; Reasons } - the FIRST matching rule wins, so the order below IS the policy.
function Get-ReplyScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [string]$LatestText = '',
        $AskCounts = $null,
        $Conversation = $null
    )
    $lt = ''
    if ($LatestText) { $lt = $LatestText.ToLowerInvariant() }
    $reasons = New-Object System.Collections.ArrayList
    $buyerMsgCount = 0
    if ($Conversation) { $buyerMsgCount = [int]$Conversation.BuyerCount }

    # --- 1) Human request / stop the bot. Highest priority: continuing to market after this is a
    #        trust breach and is explicitly forbidden by spec 4.2.
    if ($lt -match '(?i)\b(real\s+(person|human|people|agent)|actual\s+(person|human)|speak\s+to\s+(a\s+)?(human|person|someone|agent|manager)|talk\s+to\s+(a\s+)?(human|person|real)|human\s+being|are\s+you\s+(a\s+)?(bot|robot|ai)|is\s+this\s+(a\s+)?(bot|robot|ai)|stop\s+(the\s+)?(bot|robot|automation|auto)|turn\s+off\s+(the\s+)?(bot|robot|automation)|don''?t\s+reply\s+automatically|real\s+human)\b' -or
        $lt -match '(真人|人工|不要机器人|关闭机器人|别用机器人|是不是机器人)') {
        [void]$reasons.Add('explicit human or stop-bot request')
        return @{ Scenario = 'human_requested'; Reasons = @($reasons.ToArray()) }
    }

    # --- 2) Complaint / anger. Apologize about the SPECIFIC thing, never re-promise the same day
    #        again, and never keep pitching.
    if ($lt -match '(?i)\b(angry|furious|ridiculous|unacceptable|terrible|awful|disappointed|frustrat\w*|complain\w*|useless|scam|liar|worst|fed\s+up|sick\s+of|no\s+one\s+(is\s+)?(help|answer|reply)|still\s+no\s+(answer|reply|update)|waste\s+of\s+time)\b' -or
        $lt -match '(投诉|生气|太差|骗人|催了这么多次|没人理)') {
        [void]$reasons.Add('complaint or frustration signal')
        return @{ Scenario = 'complaint'; Reasons = @($reasons.ToArray()) }
    }

    # --- 3) Fulfillment question: did it arrive / has it shipped / is the quote ready. Without a
    #        trusted real-time record the only honest answer is "not confirmed yet", plus a todo.
    if ($lt -match '(?i)\b(did\s+you\s+(receive|get)|have\s+you\s+(received|got|shipped|sent)|is\s+it\s+(shipped|sent|dispatched)|has\s+it\s+(shipped|been\s+shipped)|where\s+is\s+my|where''?s\s+my|my\s+(cargo|shipment|package|parcel|container|goods)|tracking|track\b|shipment\s+status|any\s+update|status\s+update|when\s+will\s+(it|my)|quote\s+ready|ready\s+yet|how\s+long\s+(more|until)|still\s+waiting)\b' -or
        $lt -match '(收到货|发货了吗|报价做好了吗|到哪了|什么时候到)') {
        # A price/quote request is a different scenario only when no fulfillment fact is involved.
        if ($lt -match '(?i)\b(quote|price|rate|cost)\b.*\b(ready|done|finished|prepared)\b' -or $lt -match '报价做好了吗') {
            [void]$reasons.Add('quote completion question without a trusted record')
            return @{ Scenario = 'quote_ready_query'; Reasons = @($reasons.ToArray()) }
        }
        [void]$reasons.Add('fulfillment or tracking question without a trusted record')
        return @{ Scenario = 'delivery_status'; Reasons = @($reasons.ToArray()) }
    }

    # --- 4) Supplier cannot be reached. Handle the handoff request itself; never claim we called.
    # The inability verbs must be about REACHING someone. An earlier, looser pattern matched
    # "I cannot get the dimensions from the factory", which is a dimensions problem, not a
    # supplier-contact problem, and it stole priority from the dimension_missing rule below.
    if ($lt -match "(?i)\b(supplier|vendor|factory|proveedor|fornecedor)\b[^.!?]{0,30}\b(not\s+answering|isn''?t\s+answering|not\s+responding|no\s+reply|no\s+answer|ignoring|unreachable|unresponsive|disappeared|went\s+silent)\b" -or
        $lt -match "(?i)\b(can''?t|cannot|could\s+not|unable\s+to|hard\s+to|difficult\s+to)\s+(reach|contact|get\s+(a\s+)?(hold|reply|answer)\s+(of|from)|talk\s+to|find)\b[^.!?]{0,30}\b(supplier|vendor|factory|proveedor|fornecedor)\b" -or
        $lt -match '(联系不上供应商|供应商不回|工厂不回|找不到供应商)') {
        [void]$reasons.Add('buyer cannot reach the supplier')
        return @{ Scenario = 'supplier_unreachable'; Reasons = @($reasons.ToArray()) }
    }

    # --- 4b) The buyer cannot supply dimensions ("no sizes", "cannot measure", "must ask the
    #         factory"). This is the single highest-volume blocker in the real data (86.4% of
    #         buyers never supplied dimensions, and dimensions are a hard requirement for an
    #         accurate rate). The owner-approved approach is to offer to confirm the cargo details
    #         with the supplier directly and to ask for the supplier's contact - which is a cargo
    #         information source, NOT the buyer's own contact. The three step-back phrasings live
    #         in reply_scenarios.md under 'dimension_missing' and are defined in code by
    #         reply_engine.ps1::Get-DimensionGuidance.
    if ($lt -match "(?i)(no|don''?t|do\s+not|does\s+not|doesn''?t|cannot|can''?t|unable|not\s+able|hard\s+to|difficult\s+to|without)\b[^.!?]{0,30}\b(dimension|dimensions|size|sizes|measurement|measurements)\b" -or
        $lt -match "(?i)\b(dimension|dimensions|size|sizes)\b[^.!?]{0,20}\b(unknown|not\s+available|not\s+sure|no\s+idea|unavailable)\b" -or
        $lt -match '(量不了|没有尺寸|不知道尺寸|要问工厂|问一下工厂|尺寸没有)') {
        [void]$reasons.Add('buyer cannot provide dimensions')
        return @{ Scenario = 'dimension_missing'; Reasons = @($reasons.ToArray()) }
    }

    # --- 5) Ambiguous "address" mention: the buyer's own address, the supplier's address, the
    #        warehouse address or the delivery address are all possible. Ask which one instead of
    #        assuming it is the recipient address (spec 4.2 forbids auto-reading it as such).
    if ($lt -match '(?i)\baddress\b' -and $lt -notmatch '(?i)\b(deliver|delivery|recipient|consignee|shipping|ship\s+to|destination)\b' -and
        $lt -match '(?i)(\bwhich\b|\bwhat\b|\?|send\s+it|give\s+you|provide|share|need|want)') {
        [void]$reasons.Add('address mentioned without specifying whose address')
        return @{ Scenario = 'address_clarify'; Reasons = @($reasons.ToArray()) }
    }

    # --- 6) The buyer promised to send something later. Acknowledge and stop asking that field.
    $promisedNow = @()
    if ($lt -match "(?i)\b(will|gonna|going\s+to|let\s+me|i''?ll|i\s+will|as\s+soon\s+as|tomorrow|later|next\s+week|shortly)\b") {
        # Plurals matter here: "I will send the dimensions tomorrow" is the single most common
        # buyer phrasing, and an earlier version used \bdimension\b which does NOT match
        # "dimensions" (no word boundary before the trailing s). That silently dropped the promise
        # and let the system ask for the sizes again on the next turn.
        if ($lt -match '(?i)\b(weight|weights|kg|kgs|kilos?)\b') { $promisedNow += 'weight' }
        if ($lt -match '(?i)\b(dimensions?|sizes?|measurements?|specs?)\b') { $promisedNow += 'dimension' }
        if ($lt -match '(?i)\b(address|addresses)\b') { $promisedNow += 'address' }
        if ($lt -match '(?i)\b(images?|photos?|pictures?|pics?)\b') { $promisedNow += 'image' }
        if ($lt -match '(?i)\b(suppliers?|vendors?|factories|factory)\b') { $promisedNow += 'supplier' }
    }
    if ($promisedNow.Count -gt 0) {
        [void]$reasons.Add('buyer promised to provide: ' + ($promisedNow -join ', '))
        return @{ Scenario = 'material_promised'; Reasons = @($reasons.ToArray()); PromisedFields = $promisedNow }
    }

    # --- 7) Billing rule explanation - static, confirmed business knowledge we may answer directly.
    if ($lt -match '(?i)\b(billing|volumetric|chargeable|how\s+(do\s+you|does\s+it)\s+(charge|calculate|weigh)|how\s+is\s+(the\s+)?(price|cost|weight)\s+calculated|gross\s+weight\s+or|by\s+weight\s+or\s+by\s+size)\b') {
        [void]$reasons.Add('billing or chargeable-weight question')
        return @{ Scenario = 'billing_explain'; Reasons = @($reasons.ToArray()) }
    }

    # --- 8) Process explanation - also static, confirmed knowledge.
    if ($lt -match '(?i)\b(process|procedure|how\s+does\s+(this|it)\s+work|what\s+are\s+the\s+steps|next\s+steps|how\s+do\s+we\s+start|what\s+happens\s+(next|after))\b') {
        [void]$reasons.Add('process question')
        return @{ Scenario = 'process_explain'; Reasons = @($reasons.ToArray()) }
    }

    # --- 9) Packing / preparation help - assistance we can actually perform.
    if ($lt -match '(?i)\b(pack(ing|ed)?|pallet|carton|label(l?ing)?|crate|prepar\w+\s+the\s+(goods|cargo|shipment))\b' -and
        $lt -match '(?i)\b(how|what|should|need|prepare|ready|help)\b') {
        [void]$reasons.Add('packing or preparation question')
        return @{ Scenario = 'packing_prep'; Reasons = @($reasons.ToArray()) }
    }

    # --- 10) A plain refusal / stop. Short, warm, no further pitching.
    if ($lt -match '(?i)^\s*(no\s+thanks?|no\s+thank\s+you|not\s+interested|never\s+mind|forget\s+it|drop\s+it|stop|unsubscribe|cancel)\b' -or
        ($lt -match '^(no|non|não|nao)\s*$')) {
        [void]$reasons.Add('buyer declined or asked to stop')
        return @{ Scenario = 'refusal'; Reasons = @($reasons.ToArray()) }
    }

    # --- 11) Short acknowledgement with no new information. Answer briefly and, when it is
    #         genuinely useful, add one concrete thing. Never a wall of text, never a hard sell.
    if ($lt -match '(?i)^\s*(ok|okay|okey|k|yes|yeah|yep|yup|sure|fine|perfect|great|nice|good|thanks|thank\s+you|thx|ty|got\s+it|understood|noted|alright|no\s+problem|👍)\b' -and $lt.Length -le 30) {
        [void]$reasons.Add('short acknowledgement without new information')
        return @{ Scenario = 'short_ack'; Reasons = @($reasons.ToArray()) }
    }

    # --- 12) Attachment-only message (the text is just the image marker).
    if ($Facts -and $Facts.HasImages -and $lt -match '^\s*\[img\]\s*$') {
        [void]$reasons.Add('image-only message')
        return @{ Scenario = 'attachment_only'; Reasons = @($reasons.ToArray()) }
    }

    # --- 13) Buyer supplied details. Confirm them and ask only for the fields still missing.
    if ($Facts -and ($Facts.HasWeight -or $Facts.HasDimensions -or $Facts.HasAddress -or $Facts.HasFile -or $Facts.HasQuantity)) {
        [void]$reasons.Add('buyer supplied cargo details in this conversation')
        return @{ Scenario = 'details_given'; Reasons = @($reasons.ToArray()) }
    }

    # --- 14) Price / quote request with nothing supplied yet.
    if ($lt -match '(?i)\b(quote|quotation|price|pricing|cost|rate|how\s+much|freight|shipping\s+cost|expensive|cheap|discount|budget)\b') {
        [void]$reasons.Add('price or quote request')
        return @{ Scenario = 'new_inquiry'; Reasons = @($reasons.ToArray()) }
    }

    # --- 15) Generic new inquiry: the buyer said something with no other signal.
    if ($buyerMsgCount -le 2 -or $lt -match '(?i)\b(hi|hello|hey|good\s+(morning|afternoon|evening))\b') {
        [void]$reasons.Add('early conversation with no specific signal')
        return @{ Scenario = 'new_inquiry'; Reasons = @($reasons.ToArray()) }
    }

    [void]$reasons.Add('no scenario signal matched')
    return @{ Scenario = 'general'; Reasons = @($reasons.ToArray()) }
}

# Map a scenario to the reviewed guidance file key (reply_scenarios.md). Returning the same string
# for two scenarios is deliberate: guidance is shared rather than duplicated per scenario.
function Get-ScenarioGuidanceKey([string]$Scenario) {
    foreach ($key in @(
        'human_requested', 'complaint', 'delivery_status', 'quote_ready_query',
        'supplier_unreachable', 'dimension_missing', 'address_clarify', 'material_promised',
        'billing_explain', 'process_explain', 'packing_prep', 'refusal', 'short_ack',
        'attachment_only', 'details_given', 'new_inquiry'
    )) {
        if ($Scenario -eq $key) { return $key }
    }
    return 'general'
}

# Build the small decision object. Everything downstream (generation, fallbacks, the replay
# harness) consumes THIS and must not re-derive policy from raw text.
function Get-ReplyDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        [Parameter(Mandatory = $true)]$Facts,
        $Rules = $null,
        [switch]$NotifyChannelAvailable,
        [string]$ForceScenario = ''
    )

    $latest = $Conversation.LatestBuyer
    if ($Conversation.Anomaly -or -not $latest -or $latest.IsSystemCard) {
        $reason = 'no-actionable-buyer-message'
        if ($Conversation.ReplyBlockReason) { $reason = $Conversation.ReplyBlockReason }
        return [pscustomobject]@{
            CanReply = $false; BlockReason = $reason; Scenario = 'unverified_input'
            Reasons = @($reason); GuidanceKey = ''; AskFields = @(); AskableFields = @()
            AskCounts = @{}; PromisedFields = @(); MaxSentences = 0
            NeedHumanTodo = $false; TodoKind = ''; AllowTimeCommitment = $false
            AllowAdvance = $false; LatestBuyerText = ''; Facts = $Facts
            OrderConfident = [bool]$Conversation.Order.Confident; OrderReason = [string]$Conversation.Order.Reason
        }
    }
    $latestText = $latest.Orig
    $askCounts = Get-AskCounts $Conversation.Messages
    $promised = @(Get-PromisedFields @($Conversation.Lines))

    $scenarioInfo = $null
    if ($ForceScenario) {
        $scenarioInfo = @{ Scenario = $ForceScenario; Reasons = @('forced by caller') }
    } else {
        $scenarioInfo = Get-ReplyScenario -Facts $Facts -LatestText $latestText -AskCounts $askCounts -Conversation $Conversation
    }
    $scenario = [string]$scenarioInfo.Scenario

    # How detailed may this reply be? Simple acknowledgements get one line; a complex explanation
    # may take a few. Deliberately NOT a hard character cap (spec 4.3: do not mechanically
    # truncate to a fixed number of sentences).
    $maxSentences = 2
    if ($scenario -in @('short_ack', 'refusal', 'material_promised')) {
        $maxSentences = 1
    } elseif ($scenario -in @('complaint', 'billing_explain', 'process_explain', 'packing_prep')) {
        $maxSentences = 3
    }

    # Which fields may this reply ask for? Only fields genuinely missing, not already provided and
    # not already asked to the limit. This is the ONE place the "do not re-ask" rule is applied.
    $askable = Get-AskableFields -Facts $Facts -AskCounts $askCounts -PromisedFields $promised

    # Scenario-specific ask policy. Fewer questions is better: spec 4.3 asks for one key question
    # for a new inquiry, and a short list only when several fields are genuinely indispensable.
    $askFields = @()
    switch ($scenario) {
        'new_inquiry'   { if ($askable.Count -gt 0) { $askFields = @($askable[0]) } }
        # Reference images help but are not required to price accurately, so a short list here is
        # limited to the fields that genuinely gate an accurate rate (spec 4.3).
        'details_given' { $askFields = @($askable | Where-Object { $_ -ne 'image' } | Select-Object -First 2) }
        # The approved approach is to offer to confirm the cargo details with the supplier directly.
        # Asking for the supplier's contact is therefore the legitimate ask here - but only when the
        # buyer actually has a supplier, and only while the field limit allows it.
        'dimension_missing' {
            # Ask for the supplier's contact only when we do not already have it and the buyer has not
            # told us they have no supplier at all.
            if (-not $Facts.HasNoSupplier) {
                $sup = @(Get-AskableFields -Facts $Facts -AskCounts $askCounts -PromisedFields $promised -AllowedFields @('supplier'))
                if ($sup.Count -gt 0) { $askFields = @('supplier') }
            }
        }
        { $_ -in @('attachment_only', 'quote_ready_query') } { $askFields = @($askable | Select-Object -First 2) }
        # These scenarios do not collect cargo fields. Address clarification asks whose address;
        # acknowledgements and promises close the exchange without creating another task.
        { $_ -in @('address_clarify', 'human_requested', 'complaint', 'refusal', 'short_ack',
                   'material_promised', 'billing_explain', 'process_explain', 'delivery_status') } { }
        default         { if ($askable.Count -gt 0) { $askFields = @($askable[0]) } }
    }
    # Never ask a field the buyer already promised (belt and braces on top of Get-AskableFields).
    $askFields = @($askFields | Where-Object { $promised -notcontains $_ })
    if ($Facts.Destination -and ($Facts.Destination.Kind -eq 'ambiguous' -or $Facts.Destination.AmazonContext) -and
        -not $Facts.HasQuoteDestination -and $askable -contains 'address' -and
        $scenario -in @('new_inquiry','details_given','attachment_only','attachment_parse_failed','quote_ready_query','general')) { $askFields = @('address') }

    # Does this request need a real human fact? Anything about fulfillment, money, supplier
    # handoff, an explicit human request, a complaint or an unreadable attachment does.
    $todoKind = switch ($scenario) {
        'delivery_status'      { 'fulfillment_status' }
        'quote_ready_query'    { 'quote_status' }
        'supplier_unreachable' { 'supplier_handoff' }
        # Once the supplier contact is known, confirming the cargo details with them is a real
        # owner action, so it needs a real todo. Before that we are only asking for the contact.
        'dimension_missing'    { if ($Facts.HasSupplierContact -or $Facts.HasSupplier) { 'supplier_handoff' } else { '' } }
        'human_requested'      { 'human_requested' }
        'complaint'            { 'complaint_review' }
        'address_clarify'      { 'address_clarify' }
        'attachment_parse_failed' { 'attachment_unreadable' }
        default                { '' }
    }
    $needTodo = [bool]$todoKind

    # A specific deadline may only be offered when a real local todo exists AND the notification
    # channel can actually deliver it. Otherwise generation uses wording without a deadline.
    $allowTimeCommitment = ($needTodo -and [bool]$NotifyChannelAvailable)

    # After a human request, a complaint or a refusal the reply must assist only - no pitching.
    $allowAdvance = -not ($scenario -in @('human_requested', 'complaint', 'refusal'))

    return [pscustomobject]@{
        CanReply            = $true
        BlockReason         = ''
        Scenario            = $scenario
        Reasons             = @($scenarioInfo.Reasons)
        GuidanceKey         = (Get-ScenarioGuidanceKey $scenario)
        AskFields           = @($askFields)
        AskableFields       = @($askable)
        AskCounts           = $askCounts
        PromisedFields      = @($promised)
        MaxSentences        = $maxSentences
        NeedHumanTodo       = $needTodo
        TodoKind            = $todoKind
        AllowTimeCommitment = $allowTimeCommitment
        AllowAdvance        = $allowAdvance
        LatestBuyerText     = $latestText
        Facts               = $Facts
        OrderConfident      = [bool](-not $Conversation.Anomaly)
        OrderReason         = [string]$Conversation.Order.Reason
    }
}
