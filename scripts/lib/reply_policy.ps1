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
# [2026-10-05 spec §3] Trusted seller identity, the runtime clock and controlled fact wording.
# Pure library: no browser, no model, no notification, no state writes.
if (-not (Get-Command Get-SellerProfile -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'seller_context.ps1')
}
# [2026-10-05 spec §1.1/§6.1] The HIGHEST-PRIORITY contact red line lives in its own pure library so
# the rule, its vocabulary and its acceptance samples have exactly one home.
if (-not (Get-Command Test-ContactRedline -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'contact_rules.ps1')
}
# [2026-10-05 spec §3.1] THE single cargo-fact model. The reply strategy, the quote reminder and the
# reports consume this one result instead of each re-deriving "is the data complete" from keywords.
if (-not (Get-Command Get-CargoFacts -ErrorAction SilentlyContinue)) {
    $factsFile = Join-Path $PSScriptRoot 'facts_engine.ps1'
    if (Test-Path $factsFile) { . $factsFile }
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

# [2026-10-05 spec §6.3] Follow-up promises with no execution evidence. The older list above only
# covered supplier/liability actions; a plain "Let me check and get back to you" is just as
# unbacked. This round wires no human-todo/notification loop, so ActionEvidence is all-false by
# default and every one of these is BLOCKED. The patterns target OUR declared action, never the
# buyer's own request and never a plain statement that a fact is currently unconfirmed
# ("I can't confirm the shipment status here." stays allowed).
$script:PolicyFollowUpPromisePatterns = @(
    '(?i)\blet\s+me\s+(check|verify|confirm|look\s+into|find\s+out|see)\b',
    '(?i)\bi(?:''m| am)\s+checking\b',
    '(?i)\bchecking\s+(with|on)\s+(the|our|my|your)?\s*(team|warehouse|manager|supplier|vendor|factory|carrier|office|colleagues?)\b',
    '(?i)\bi(?:''ve| have)\s+(?:already\s+)?passed\s+(?:this|it)\s+(on|along|over)\b',
    '(?i)\bi(?:''m| am)\s+(passing|forwarding|sending)\s+(this|it)\b',
    '(?i)\b(?:i|we)\b[^.!?\r\n]{0,40}\b(?:''ll| will)\s+(get|come)\s+back\s+to\s+you\b',
    '(?i)\bi(?:''m| am)\s+looking\s+into\b',
    '(?i)\bi(?:''ll| will)\s+(follow\s+up|check|verify|confirm|look\s+into)\b',
    '(?i)\b(?:i|we)(?:''ll| will)\s+follow\s+up\b',
    '(?i)\bkeep\s+an\s+eye\s+on\s+(this|it)\b',
    '(?i)\bi(?:''ll| will)\s+let\s+you\s+know\b',
    '(?i)\bi(?:''m| am)\s+having\s+(this|it|that)\s+(checked|looked\s+at|reviewed)\b',
    '(?i)\b(?:i|we)(?:''ll| will)\s+(update|notify)\s+you\b',
    '(?i)\b(?:the\s+)?(team|owner|manager|colleague)\s+will\s+(take|pick)\s+(it|this)\s+(over|up)\b'
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
# ============================================================================================
# [2026-10-05 第三轮 spec §2 / §8] TimeExpectations + OutputTimeClaims
#   从**完整 TimeTargets 与同一份 RuntimeContext** 导出每个目标的期望（原始/规范地点、有效时区、
#   实际 UTC offset、当地日期与钟点），再把待发文本里的每条当前时间声明解析出来逐条绑定。
#   * 不再保留 expectedValues/statedValues 的分钟值集合授权：声明必须绑定到**目标身份**；
#   * 同钟点、同 offset 或同 Zone 的**不同点名地点**不能靠相等关系合并覆盖；
#   * 未解析目标必须由**明确的时间地点/时区澄清**逐项点到，泛化一句 which city 不能覆盖全部；
#   * 判定对象是最终完整文本：正确程序前缀不能豁免错误正文。
# ============================================================================================
function Get-TimeExpectationId($Target, [int]$Index) {
    $p = [string]$Target.PlaceRaw
    if (-not $p) { $p = [string]$Target.Place }
    if (-not $p) { $p = 'seller' }
    return ('target-' + [string]$Index + ':' + (($p -replace '\s+', '-').ToLowerInvariant()))
}

function Get-TimeExpectations {
    [CmdletBinding()]
    param($TimeTargets = @(), $RuntimeContext = $null)
    $out = New-Object System.Collections.ArrayList
    if (-not $TimeTargets -or -not $RuntimeContext) { return @() }
    $nowUtc = [datetime]$RuntimeContext.NowUtc
    $i = 0
    foreach ($tg in @($TimeTargets)) {
        $i++
        $state = [string]$tg.State
        if (-not $state) { $state = $(if ([string]$tg.Kind -eq 'explicit') { 'explicit_resolved' } else { 'unspecified' }) }
        $zone = $null
        if ($state -eq 'unspecified' -or [string]$tg.Kind -eq 'seller') { $zone = Resolve-SellerTimeZone ([string]$RuntimeContext.Timezone) }
        else { $zone = Resolve-PlaceTimeZone ([string]$tg.Place) }
        $resolved = ($state -ne 'explicit_unresolved') -and ($zone -and $zone.Ok)
        $aliases = New-Object System.Collections.ArrayList
        foreach ($a in @([string]$tg.PlaceRaw, [string]$tg.Place)) { if ($a -and -not $aliases.Contains($a)) { [void]$aliases.Add($a) } }
        if ($zone -and $zone.Ok) {
            foreach ($a in @([string]$zone.Place, [string]$zone.Iana)) { if ($a -and -not $aliases.Contains($a)) { [void]$aliases.Add($a) } }
        }
        $e = [pscustomobject]@{
            TargetId = (Get-TimeExpectationId $tg $i)
            RequestId = [string]$tg.RequestId
            PlaceRaw = [string]$tg.PlaceRaw
            Place = [string]$tg.Place
            State = $state
            Kind = [string]$tg.Kind
            Reason = [string]$tg.Reason
            Resolved = [bool]$resolved
            Zone = $(if ($zone -and $zone.Ok) { [string]$zone.Iana } else { '' })
            DisplayPlace = $(if ($zone -and $zone.Ok) { [string]$zone.Place } else { '' })
            Aliases = @($aliases.ToArray())
            OffsetMinutes = 0
            OffsetText = ''
            ClockMinutes = -1
            ClockText = ''
            LocalDate = ''
            CrossDay = $false
            NowUtc = $nowUtc
        }
        if ($resolved) {
            try {
                $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($nowUtc, $zone.Info)
                $offset = $zone.Info.GetUtcOffset($nowUtc)
                $e.OffsetMinutes = [int]$offset.TotalMinutes
                $e.OffsetText = Format-UtcOffset $offset
                $e.ClockMinutes = ([int]$local.Hour * 60) + [int]$local.Minute
                $e.ClockText = $local.ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
                $e.LocalDate = $local.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                $e.CrossDay = ($local.Date -ne $nowUtc.Date)
            } catch { $e.Resolved = $false }
        }
        [void]$out.Add($e)
    }
    return @($out.ToArray())
}

# 业务时间标记（预约/排期/截止/时长）：它们不是"现在几点"的声明。
$script:PolicyTimeBusinessMarker = '(?i)\b(?:book(?:ing|ed)?|appointment|schedul\w*|pickup|pick\s?up|deadline|due\s+date|cut[\s\-]?off|closing|business\s+hours|opening\s+hours|transit\s+time|lead\s+time|delivery\s+window|eta)\b'
$script:PolicyTimeCurrentMarker = '(?i)\b(?:current(?:ly)?|right\s+now|at\s+the\s+moment|now|what\s+time|the\s+time\s+(?:is|now|in)|local\s+time)\b'
$script:PolicyTimeOffsetPattern = '(?i)\b(?:utc|gmt)\s*([+-]\s*\d{1,2}(?::\d{2})?)\b'
$script:PolicyTimeClarifyPattern = '(?i)\b(?:which|what)\s+(?:city|country|time\s*zone|region|state|area|location)\b|\bdo\s+you\s+mean\b|\bwhich\s+time\s*zone\b'

# 全文的当前时间声明：输出区间、句子范围、时刻、12/24 小时形态、声明的地点/时区与 offset。
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

    # 0) [2026-10-05 spec §1.1 / §6.1 check 0] THE CONTACT RED LINE - highest priority, runs first on
    #    every exit (model draft, single rewrite, fixed fallback and the pre-send gate).
    #    It blocks: offering/inviting OUR contact channels and asking for the buyer's OWN contact.
    #    It allows: an explicitly role-scoped (consignee/recipient or supplier) contact request that
    #    states a shipping/verification purpose or is authorized by this turn's AskFields.
    #    A supplier/consignee mention never exempts a personal-channel ask in the same sentence,
    #    because the judgement is per clause.
    $redlineCodes = @()
    if (Get-Command Test-ContactRedline -ErrorAction SilentlyContinue) {
        $redline = Test-ContactRedline -Text $Text -Decision $Decision -Facts $Decision.Facts
        foreach ($v in @($redline.Violations)) {
            $redlineCodes += [string]$v.Code
            [void]$violations.Add(@{ Code = [string]$v.Code; Severity = 'block'; Detail = [string]$v.Detail })
        }
    }

    # [独立复核 R09] "已有/已给/已存档"是事实声明：说明标题或措辞变化不改变它需要对应来源。
    $receivedClaimPattern = '(?i)\b(?:have|has|already)\s+(?:received|stored|saved|noted)|\bI have all|\b(?:i|we)\s+(?:already\s+)?(?:have|got)\b[^.\r\n]{0,40}?\b(?:contacts?|contact\s+person|details|information|documents?|资料)\b|\b(?:already|just)\s+(?:gave|given|sent|provided|shared|supplied)\s+us\b|\b(?:contacts?|details|information|address|name|number|email|documents?)[^.\r\n]{0,20}\bon\s+file\b|\bon\s+file\b[^.\r\n]{0,20}\b(?:contacts?|details|information|address|name|number)\b'
    foreach($receivedMatch in [regex]::Matches($Text,$receivedClaimPattern)) {
        $receivedBounds=Get-SentenceBounds $Text $receivedMatch.Index
        $receivedClaim=$Text.Substring($receivedBounds.Start,$receivedBounds.End-$receivedBounds.Start)
        # 条件/时间从句里的 "once we have the details" 不是已收到声明。
        if($receivedClaim -match '(?i)\b(?:once|when|if|after|before|until|as\s+soon\s+as)\s+(?:we|i|you)\s+(?:already\s+)?(?:have|got)\b'){continue}
        $hasSource=$false
        if($Decision.Facts.CargoFacts){
            $required=@();foreach($group in $script:PolicyAskFieldGroups){if($receivedClaim -match $group.Pattern){$required+=,@($group.Fields)}}
            if($receivedClaim -match '(?i)supplier.*contact'){$required+=,@('supplier_contact')};if($receivedClaim -match '(?i)recipient.*contact'){$required+=,@('recipient_contact')}
            $hasSource=($required.Count -gt 0)
            foreach($alternatives in $required){$found=@($Decision.Facts.CargoFacts.Fields|Where-Object {$alternatives -contains $_.Key -and $_.Status -eq 'provided' -and @($_.Evidence).Count});if(-not $found.Count){$hasSource=$false}}
            if($receivedClaim -match '(?i)\bI have all\b|received.*packing (?:details|information)'){$hasSource=[bool]$Decision.Facts.QuoteReadiness.Ready}
        }
        if(-not $hasSource){[void]$violations.Add(@{Code='UNSUPPORTED_RECEIVED_FACT';Severity='block';Detail='no corresponding received fact evidence'})}
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

    # 4) Contact exchange - second, deliberately redundant net kept from the previous build. Check 0
    #    already covers it with the role-aware rule; this only adds a violation when check 0 found
    #    nothing at all for the personal-contact case, so one text never reports the same problem twice.
    if ($redlineCodes.Count -eq 0 -and (Test-BuyerContactExchange $Text)) {
        [void]$violations.Add(@{ Code = 'BUYER_CONTACT_REQUEST'; Severity = 'block'; Detail = 'asks for or offers the buyer''s own contact details' })
    }

    # 5) Promises the robot cannot keep.
    foreach ($p in $script:PolicyUnsupportedPromisePatterns) {
        if ($Text -match $p) {
            [void]$violations.Add(@{ Code = 'UNSUPPORTED_PROMISE'; Severity = 'block'; Detail = $p })
            break
        }
    }
    # 5a) [2026-10-05 spec §6.3] Any declared follow-up action with no execution evidence. The
    # default is "no evidence": a missing Decision, a Decision whose ActionEvidence is all-false
    # and a payload with no persisted todo all block the same way. Only a Decision that carries a
    # real TodoPersisted fact may keep such wording.
    $todoPersisted = $false
    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'ActionEvidence' -and $Decision.ActionEvidence) {
        $todoPersisted = [bool]$Decision.ActionEvidence.TodoPersisted
    }
    if (-not $todoPersisted) {
        foreach ($p in $script:PolicyFollowUpPromisePatterns) {
            if ($Text -match $p) {
                [void]$violations.Add(@{ Code = 'UNSUPPORTED_PROMISE'; Severity = 'block'; Detail = $p })
                break
            }
        }
    }

    # 5b) [2026-10-05 spec §6.1] Unresolved template markers must never reach the buyer. This is
    # case/space-insensitive and covers the bracket/mustache/dollar-brace/angle/TO-DO families,
    # but it deliberately does NOT ban brackets in general: a size, a model code, a unit and a
    # known encoding all keep working (spec C16).
    foreach ($p in (Get-SellerTemplatePatterns)) {
        if ($Text -match $p) {
            [void]$violations.Add(@{ Code = 'UNRESOLVED_TEMPLATE'; Severity = 'block'; Detail = $p })
            break
        }
    }

    # 5c) [2026-10-05 spec §6.2] Identity / current-turn object constraints. These only run when a
    # Decision is supplied, which is every production exit (generation, rewrite, direct fact,
    # fallback and the monitor send gate).
    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'RequestedFacts') {
        $requested = @($Decision.RequestedFacts)
        $factOnly = [bool](Get-SellerObjectValue $Decision 'FactOnly')
        $askFields = @($Decision.AskFields)

        # (i) A pure own-name question must answer OUR service identity: never tell the buyer that
        #     their name is unconfirmed and never ask the buyer for a name back.
        if ($requested -contains 'seller_name') {
            if ($Text -match "(?i)(didn'?t|did\s+not|have\s+not|haven'?t|not)\s+(?:confirm|got|get|have|receive[d]?)\s+(?:your|ur)\s+name\b" -or
                $Text -match "(?i)\bwhat'?s\s+(?:your|ur)\s+name\b" -or
                $Text -match "(?i)\b(could|can|would)\s+you\s+(?:tell|share|confirm|provide)\s+(?:me\s+)?(?:your|ur)\s+name\b") {
                [void]$violations.Add(@{ Code = 'IDENTITY_WRONG_OBJECT'; Severity = 'block'; Detail = 'answers a question about OUR name by talking about the buyer''s name' })
            }
        }

        # (ii) A pure identity/time answer must not turn into cargo collection.
        if ($factOnly -and $askFields.Count -eq 0) {
            if ($Text -match '(?i)\b(weight|weights|kg|kgs|kilo|kilos|dimension|dimensions|size|sizes|carton|cartons|packing|address|delivery\s+address|zip|postal|warehouse|supplier|vendor|factory|photo|photos|image|images|reference\s+photos)\b') {
                [void]$violations.Add(@{ Code = 'FACT_TOPIC_DRIFT'; Severity = 'block'; Detail = 'a pure fact answer asked for cargo information' })
            }
        }

        # (iii) A company statement must match the owner-confirmed company exactly.
        if ($requested -contains 'seller_company') {
            $companyNorm = ''
            if ($Decision.PSObject.Properties.Name -contains 'FactCompanyValue') { $companyNorm = Normalize-CompanyName ([string]$Decision.FactCompanyValue) }
            # The capture window is deliberately wide (160 chars, one line). Cutting it at the first
            # period truncated "Harbor Freight Management Co., Ltd." to "Harbor Freight Management Co"
            # and blocked a CORRECT reply, because a legal-form abbreviation contains a period that is
            # not a sentence end. The window is trimmed by Get-CompanyStatementCandidate instead.
            # Match only the statement HEAD and slice the window from there, so a second statement
            # later in the same line is examined on its own. Capturing a fixed window instead made
            # the first match swallow "… Co., Ltd. We're Global Sourcing Ltd." whole, and the second,
            # invented identity was never checked.
            foreach ($m in [regex]::Matches($Text, "(?i)\b(?:we\s+are|we'?re|our\s+company\s+is|the\s+company\s+is|i'?m\s+from)\s+")) {
                $rest = $Text.Substring($m.Index + $m.Length)
                if ($rest.Length -gt 160) { $rest = $rest.Substring(0, 160) }
                $cand = Get-CompanyStatementCandidate $rest
                if (-not $cand) { continue }
                # A lowercase continuation is not a company statement ("we're happy to help").
                # -cnotmatch is deliberate: PowerShell's -match is case-INSENSITIVE by default, so a
                # plain -notmatch would never fire and every "We're happy to ..." would be misread as
                # a company claim.
                if ($cand -cnotmatch '^[A-Z]') { continue }
                if ($script:CompanyStatementNonNames -contains (($cand -split '[\s,]+')[0])) { continue }
                $candNorm = Normalize-CompanyName $cand
                # EXACT match only. A prefix rule (StartsWith) would let a correct name followed by a
                # second, invented identity through - exactly the case this check exists to stop.
                if ($companyNorm -and $candNorm -eq $companyNorm) { continue }
                [void]$violations.Add(@{ Code = 'FACT_COMPANY_MISMATCH'; Severity = 'block'; Detail = ('stated company does not match the owner-confirmed value: ' + $cand) })
                break
            }
        }

        # (iv) A stated own name must not be an invented name or the buyer's name.
        if ($requested -contains 'seller_name' -or $requested -contains 'assistant_identity') {
            $ownName = ''
            $ownVerified = $false
            if ($Decision.PSObject.Properties.Name -contains 'FactNameValue') { $ownName = [string]$Decision.FactNameValue }
            if ($Decision.PSObject.Properties.Name -contains 'FactNameVerified') { $ownVerified = [bool]$Decision.FactNameVerified }
            # The WHOLE candidate name is compared, not just its first word. Comparing only the
            # first word blocked the owner-confirmed "Taylor Reed" reply (the check saw "Taylor"
            # against a configured "Taylor Reed"): a correct multi-word display name could never be
            # sent. A same-first-word different tail ("Taylor Fake") must still be blocked, so the
            # comparison is exact after normalization - never a prefix test.
            foreach ($m in [regex]::Matches($Text, "\bI'?m\s+((?:[A-Z][A-Za-z'\-]{0,30})(?:\s+[A-Z][A-Za-z'\-]{0,30}){0,3})")) {
                $cand = ($m.Groups[1].Value -replace '\s+', ' ').Trim()
                if (-not $cand) { continue }
                if ($script:SelfIntroductionNonNames -contains (($cand -split ' ')[0])) { continue }
                if ($ownVerified -and (Normalize-PersonName $cand) -eq (Normalize-PersonName $ownName)) { continue }
                [void]$violations.Add(@{ Code = 'FACT_NAME_MISMATCH'; Severity = 'block'; Detail = ('stated own name does not match the confirmed display name: ' + $cand) })
                break
            }
        }

        # (v) [2026-10-05 第三轮 spec §2/§8] 每个目标生成 TimeExpectations，正文的每条当前时间声明
        #     生成 OutputTimeClaims 并**逐一绑定**：地点/时区/offset/时刻/日期都要对得上。
        #     正确程序前缀不能豁免错误正文；多目标裸时刻不猜；未解析目标必须被逐项澄清。
        if ($requested -contains 'current_time' -and $Decision.RuntimeContext -and $Decision.RuntimeContext.Valid) {
            $targets = @()
            if ($Decision.PSObject.Properties.Name -contains 'TimeTargets') { $targets = @($Decision.TimeTargets) }
            if ($targets.Count -eq 0) {
                # 兼容：没有目标列表时按旧的单地点字段重建一个目标。
                $targets = @([pscustomobject]@{
                    Place = [string]$Decision.RequestedPlace; PlaceRaw = [string]$Decision.RequestedPlace
                    Kind = [string]$Decision.RequestedPlaceKind; State = $(if ([string]$Decision.RequestedPlaceKind -eq 'explicit') { 'explicit_resolved' } else { 'unspecified' })
                    Resolved = [bool]$Decision.RequestedPlaceResolved; Reason = [string]$Decision.RequestedPlaceReason; TimeZone = ''
                })
            }
            $expectations = @(Get-TimeExpectations -TimeTargets $targets -RuntimeContext $Decision.RuntimeContext)
            foreach ($tv in @(Test-OutputTimeClaims -Text $Text -Expectations $expectations -InputText ([string]$Decision.LatestBuyerText))) {
                [void]$violations.Add(@{ Code = [string]$tv.Code; Severity = 'block'; Detail = [string]$tv.Detail })
            }
        }
    }

    if($Decision.RequestedFacts -notcontains 'current_time' -and @(Get-OutputTimeClaims $Text).Count){
        foreach($v in @(Test-OutputTimeClaims $Text @() ([string]$Decision.LatestBuyerText))){[void]$violations.Add($v)}
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

    # 8) [2026-10-05 spec §6.1 checks 1-3] Unified output check against THIS turn's Decision:
    #    a question about a field the decision did not authorize (or one the buyer already gave) is a
    #    violation, and a supplier-contact plan may only be stated when a real task backs it.
    if ($Decision -and ($Decision.PSObject.Properties.Name -contains 'AskFields')) {
        foreach ($v in @(Test-AskFieldConformance -Text $Text -Decision $Decision)) {
            [void]$violations.Add(@{ Code = [string]$v.Code; Severity = [string]$v.Severity; Detail = [string]$v.Detail })
        }
        if (Test-SupplierPlanWording -Text $Text -Decision $Decision) {
            [void]$violations.Add(@{ Code = 'UNSUPPORTED_PROMISE'; Severity = 'block'; Detail = 'supplier contact plan without a persisted human task / owner evidence' })
        }
    }

    $list = @($violations.ToArray())
    $blocked = @($list | Where-Object { $_.Severity -eq 'block' }).Count -gt 0
    return [pscustomobject]@{ Ok = (-not $blocked); Violations = $list }
}

# ============================================================================================
# [2026-10-05 spec §6.1 check 1] Ask-scope conformance
# Fields are compared by GROUP, so a decision that authorizes "weight" also authorizes the reply to
# say "the packed weight per carton" (the wording the reviewed examples use). A request outside the
# authorized groups, or a request for something the buyer already supplied, is blocked.
# ============================================================================================
# 判据分组。联系方式/姓名字段（recipient_contact / recipient_name / supplier_contact）由
#   contact_rules::Test-ContactRedline 用**同一份**请求项列表逐项判定（authorized / already-provided），
#   这里只负责其余字段组与地址类字段，避免同一份文本出现两套互相矛盾的授权口径。
$script:PolicyAskFieldGroups = @(
    @{ Name = 'weight';    Fields = @('weight', 'unit_weight', 'total_weight'); Pattern = '(?i)\b(weights?|kgs?|kilos?|gross\s+weight|net\s+weight|packed\s+weight|weigh)\b' },
    @{ Name = 'dimension'; Fields = @('dimension', 'unit_dimensions', 'lot_dimensions'); Pattern = '(?i)\b(dimensions?|sizes?|measurements?|l\s*[x*\u00d7]\s*w\s*[x*\u00d7]\s*h|cm|mm)\b' },
    @{ Name = 'count';     Fields = @('carton_count', 'quantity'); Pattern = '(?i)\b(cartons?|ctns?|boxes|pallets?|packages?|pieces|pcs|units)\b' },
    @{ Name = 'address';   Fields = @('address', 'delivery_address'); Pattern = '(?i)\b(address(?:es)?|destination|zip|postal|warehouse\s+code)\b' },
    @{ Name = 'supplier_address'; Fields = @('supplier_address'); Pattern = '(?i)\b(?:supplier|vendor|factory)(?:''s|s)?\s+(?:pickup\s+|factory\s+|warehouse\s+)?address(?:es)?\b|\baddress(?:es)?\s+(?:of|for)\s+(?:the\s+|our\s+)?(?:supplier|vendor|factory)\b' },
    @{ Name = 'image';     Fields = @('image', 'reference_images'); Pattern = '(?i)\b(photos?|images?|pictures?|pics?)\b' }
)

# 供应商限定地址：命中时不再按普通 delivery_address 判定（两个字段互不授权）。
$script:PolicySupplierAddressAskPattern = '(?i)\b(?:supplier|vendor|factory)(?:''s|s)?\s+(?:pickup\s+|factory\s+|warehouse\s+)?address(?:es)?\b|\baddress(?:es)?\s+(?:of|for)\s+(?:the\s+|our\s+)?(?:supplier|vendor|factory)\b'

# --------------------------------------------------------------------------------------------
# [2026-10-05 spec §6.2] "per carton / each pallet" is a UNIT MODIFIER, not a count request.
#   "Could you share the packed weight per carton?" asks for the WEIGHT and merely says which
#   unit that weight is measured per. The count group used to match any bare "carton" word, so a
#   question the weight authorization fully covers was reported as an unlicensed carton-count ask
#   and then blocked by its own fix. These two predicates separate the two readings:
#     Test-AskUnitModifier      - the packaging noun is only qualifying another field
#     Test-AskCountRequest      - the clause really asks HOW MANY cartons/pallets there are
# --------------------------------------------------------------------------------------------
$script:PolicyAskUnitModifier = '(?i)\b(?:per|each|every|a|an|one)\s+(?:single\s+)?(?:cartons?|boxes|pallets?|packages?|ctns?|pieces|pcs|units)\b'
$script:PolicyAskCountQuantifier = '(?i)\b(?:how\s+many|number\s+of|count\s+of|total\s+number|how\s+much\s+(?:cartons?|boxes|pallets?)|quantity\s+of)\b'

$script:PolicyAskPackageNoun = '(?i)(cartons?|ctns?|boxes|pallets?|packages?|pieces|pcs|units)'
# [2026-10-05 spec §6.2 第 1/3 条] "carton sizes" / "box dimensions" 里的包装名词是**尺寸的限定语**
#   （问的是尺寸，用箱为单位），不是件数询问。整段（名词 + 尺寸名词）都算被消费掉，
#   与 "per carton"、"each pallet" 走同一条单位修饰语判据。
$script:PolicyAskDimNounForPackage = '(?i:' + $script:PolicyAskPackageNoun + ')[\s\-]*(?:sizes?|dimensions?|measurements?|specs?)'

# Character spans of the clause consumed by a unit modifier. The span starts at the quantifier and
# then absorbs an enumeration of packaging nouns ("per carton or pallet", "each box / pallet"), so
# "the packed dimensions per carton or pallet (L x W x H)" is ONE modifier and not a count ask.
# A parenthetical dimension hint "(L x W x H)" is removed first: it is a measurement, not a count.
function Get-AskUnitModifierSpans([string]$Clause) {
    $spans = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Clause)) { return @() }
    $t = [regex]::Replace($Clause, '\([^)]*\)', ' ')
    # "carton sizes" / "box dimensions"：整段（名词 + 尺寸名词）都是**尺寸的限定语**，
    #   它自己就构成一个"已消费"的区间（长度与原文一致，因此下标可以直接用于原文）。
    foreach ($m in [regex]::Matches($t, $script:PolicyAskDimNounForPackage)) {
        [void]$spans.Add(@{ Start = $m.Index; End = ($m.Index + $m.Length) })
    }
    $t2 = [regex]::Replace($t, $script:PolicyAskDimNounForPackage, ' ')
    $pattern = '(?i)\b(?:per|each|every|a|an|one)\s+(?:single\s+)?' + $script:PolicyAskPackageNoun + '(?:\s*(?:,|/|\bor\b|\band\b)\s*(?:the\s+)?' + $script:PolicyAskPackageNoun + ')*'
    foreach ($m in [regex]::Matches($t2, $pattern)) {
        [void]$spans.Add(@{ Start = $m.Index; End = ($m.Index + $m.Length) })
    }
    return @($spans.ToArray())
}

# True when EVERY packaging-noun mention in the clause sits inside a unit modifier.
function Test-AskUnitModifier([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    $spans = @(Get-AskUnitModifierSpans $Clause)
    if ($spans.Count -eq 0) { return $false }
    # 覆盖扫描必须与 span 计算用**同一份**归一化文本（括号提示与"名词+尺寸名词"都被替换成空格，
    #   长度不变但索引必须一致，否则会拿 A 文本的下标去比 B 文本的 span）。
    $scan = [regex]::Replace($Clause, '\([^)]*\)', ' ')
    $scan = [regex]::Replace($scan, $script:PolicyAskDimNounForPackage, ' ')
    foreach ($m in [regex]::Matches($scan, $script:PolicyAskPackageNoun)) {
        $covered = $false
        foreach ($s in $spans) {
            if ($m.Index -ge $s.Start -and $m.Index -lt $s.End) { $covered = $true; break }
        }
        if (-not $covered) { return $false }
    }
    return $true
}

# True when the clause really requests a count (quantifier, or a bare count noun that is not
# consumed by a unit modifier). "weight per carton and how many cartons" is true here.
function Test-AskCountRequest([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    if ($Clause -match $script:PolicyAskCountQuantifier) { return $true }
    if ($Clause -notmatch $script:PolicyAskPackageNoun) { return $false }
    return (-not (Test-AskUnitModifier $Clause))
}

# 只有真正的"请求"句才做范围核对：疑问句，或带第二人称的请求式，或明确的请求动词。
# 裸 "can" 会误伤 "I can't check with your supplier from here"（陈述能力不足，不是索取字段）。
$script:PolicyAskRequestVerbs = '(?i)\?|\b(?:could|can|would|will)\s+you\b|\bplease\b|\b(?:share|send|provide|give|tell\s+me|confirm|need|require|let\s+us\s+know)\b|\b(?:what|which|how\s+many)\b'
# 否定句不是索取（"we do not strictly need the supplier's contact"）。
$script:PolicyAskNegationGuard = '(?i)\b(?:do\s+not|don''?t|does\s+not|doesn''?t|no\s+longer|not)\b[^.!?]{0,25}\b(?:need|require|want|ask)\b'
# [F8 §9.1 第 1 条] which/whose/is this/do you mean 只是**可能澄清的语气线索**，
#   绝不代表整句被授权：它们不再构成免检路径，只参与"这一句是不是在澄清"的判断。
$script:PolicyAskClarifyGuard = '(?i)\b(?:which|whose|is\s+this|do\s+you\s+mean|did\s+you\s+mean|are\s+you\s+saying)\b'

# 真正的澄清问句：必须是**针对某个真实歧义的结构化澄清**，而不是"以澄清词开头"。
#   which/whose/is this/do you mean 只是语气线索（spec §7.2 第 1 条）；"Could you share the carton
#   count, which we need for the quote?" 的主干仍在索取 ⇒ 不是澄清。
function Test-AskClarifyWording([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    $c = ([string]$Clause).Trim()
    if ($c -match '(?i)\b(?:confirm|verify|clarify|check)\s+(?:whether|if)\b') { return $true }
    if ($c -match '(?i)\b(?:which|whose|what)\b[^?]{0,90}\b(?:is\s+correct|are\s+correct|is\s+right|are\s+right|should\s+(?:we|i)\s+use|(?:we|i)\s+should\s+use|can\s+(?:we|i)\s+use|to\s+use|do\s+you\s+mean|did\s+you\s+mean|is\s+it)\b') { return $true }
    if ($c -match '(?i)\b(?:do\s+you\s+mean|did\s+you\s+mean|are\s+you\s+saying|is\s+this|is\s+that)\b') { return $true }
    if ($c -match '(?i)\bwhich\s+(?:one|of\s+(?:these|them|the\s+two))\b') { return $true }
    if ($c -match '(?i)\b(?:two|both|different|conflicting|several)\b[^.]{0,50}\b(?:values?|numbers?|counts?|figures?|sizes?|weights?|quantit(?:y|ies)|answers?)\b') { return $true }
    if ($c -match '(?i)\b(?:you\s+(?:gave|sent|mentioned|provided)|we\s+(?:have|got))\b[^.]{0,40}\b(?:two|both|different|conflicting)\b') { return $true }
    return $false
}

# ============================================================================================
# [2026-10-05 第三轮 spec §2 / §7.1] ClarificationRequests：从**唯一事实模型**导出的结构化澄清证据
#   Id / FieldKey / ReasonKind(conflict|unit|scope|role|destination) / Candidates[{Value,Unit,Scope,
#   SourceRefs}] / SourceRefs / AllowedOpenClarification / AllowedQuestionForms
#   候选在**提取阶段**就保留单位、范围与消息/记录来源，绝不对自由文本 Clarifications 反向猜测，
#   也不另建第二套事实模型。ClarifyFields 只是字段索引，单独存在不授权任意数值（spec §7.2 第 5 条）。
# ============================================================================================
$script:ClarifyUnitFamilies = @{
    'kg' = 'mass'; 'kgs' = 'mass'; 'kilo' = 'mass'; 'kilos' = 'mass'; 'kilogram' = 'mass'; 'kilograms' = 'mass'
    'g' = 'mass'; 'gr' = 'mass'; 'gram' = 'mass'; 'grams' = 'mass'
    'ton' = 'mass'; 'tons' = 'mass'; 'tonne' = 'mass'; 'tonnes' = 'mass'; 'mt' = 'mass'
    'lb' = 'mass'; 'lbs' = 'mass'; 'pound' = 'mass'; 'pounds' = 'mass'
    'cm' = 'length'; 'centimeter' = 'length'; 'centimeters' = 'length'
    'mm' = 'length'; 'm' = 'length'; 'meter' = 'length'; 'meters' = 'length'; 'inch' = 'length'; 'inches' = 'length'
    'carton' = 'cartons'; 'cartons' = 'cartons'; 'ctn' = 'cartons'; 'ctns' = 'cartons'; 'box' = 'cartons'; 'boxes' = 'cartons'
    'case' = 'cartons'; 'cases' = 'cartons'; 'crate' = 'cartons'; 'crates' = 'cartons'
    'package' = 'cartons'; 'packages' = 'cartons'; 'pack' = 'cartons'; 'packs' = 'cartons'
    'pallet' = 'pallets'; 'pallets' = 'pallets'; 'skid' = 'pallets'; 'skids' = 'pallets'
    'pc' = 'pcs'; 'pcs' = 'pcs'; 'piece' = 'pcs'; 'pieces' = 'pcs'; 'unit' = 'pcs'; 'units' = 'pcs'
    'set' = 'pcs'; 'sets' = 'pcs'; 'item' = 'pcs'; 'items' = 'pcs'
}
$script:ClarifyMassToKg = @{ 'kg' = 1.0; 'kgs' = 1.0; 'kilo' = 1.0; 'kilos' = 1.0; 'kilogram' = 1.0; 'kilograms' = 1.0
    'g' = 0.001; 'gr' = 0.001; 'gram' = 0.001; 'grams' = 0.001
    'ton' = 1000.0; 'tons' = 1000.0; 'tonne' = 1000.0; 'tonnes' = 1000.0; 'mt' = 1000.0
    'lb' = 0.45359237; 'lbs' = 0.45359237; 'pound' = 0.45359237; 'pounds' = 0.45359237 }
$script:ClarifyLengthToCm = @{ 'cm' = 1.0; 'centimeter' = 1.0; 'centimeters' = 1.0; 'mm' = 0.1
    'm' = 100.0; 'meter' = 100.0; 'meters' = 100.0; 'inch' = 2.54; 'inches' = 2.54 }
$script:ClarifyUnitStopWords = @('or', 'and', 'is', 'are', 'the', 'a', 'an', 'to', 'for', 'of', 'in', 'on', 'per',
    'each', 'we', 'you', 'i', 'it', 'this', 'that', 'please', 'confirm', 'correct', 'right', 'total', 'us', 'me')

function Get-ClarifyNumberTokens([string]$Clause) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Clause)) { return @() }
    # 三维尺寸是一个**整体**令牌（50x40x30）：先取出来，再跳过它覆盖的单个数字，
    #   否则 "50x40x30" 会被拆成 50/40/30 三个无单位数字而无法与真实候选比对。
    $compositeSpans = New-Object System.Collections.ArrayList
    foreach ($cm in [regex]::Matches($Clause, '(?<![\d.])(\d+(?:\.\d+)?)\s*[x\u00d7*]\s*(\d+(?:\.\d+)?)\s*[x\u00d7*]\s*(\d+(?:\.\d+)?)(?![\d.])')) {
        $afterC = $Clause.Substring($cm.Index + $cm.Length)
        if ($afterC.Length -gt 24) { $afterC = $afterC.Substring(0, 24) }
        $unitC = ''
        $umC = [regex]::Match($afterC, '^\s*(?<u>[A-Za-z]{1,14})')
        if ($umC.Success) {
            $cuC = ([string]$umC.Groups['u'].Value).ToLowerInvariant()
            if ($script:ClarifyUnitStopWords -notcontains $cuC) { $unitC = $cuC }
        }
        $famC = ''
        if ($unitC -and $script:ClarifyUnitFamilies.ContainsKey($unitC)) { $famC = [string]$script:ClarifyUnitFamilies[$unitC] }
        $composite = (([string]$cm.Groups[1].Value) + 'x' + ([string]$cm.Groups[2].Value) + 'x' + ([string]$cm.Groups[3].Value))
        [void]$out.Add([pscustomobject]@{ Text = $cm.Value; Value = $composite; Composite = $composite; UnitRaw = $unitC; UnitNorm = $unitC; UnitFamily = $famC; Index = $cm.Index })
        [void]$compositeSpans.Add(@{ Start = $cm.Index; End = ($cm.Index + $cm.Length) })
    }
    foreach ($m in [regex]::Matches($Clause, '(?<![\d.])(\d+(?:\.\d+)?)(?![\d.])')) {
        $covered = $false
        foreach ($sp in $compositeSpans) { if ($m.Index -ge [int]$sp.Start -and $m.Index -lt [int]$sp.End) { $covered = $true; break } }
        if ($covered) { continue }
        $val = 0.0
        if (-not [double]::TryParse($m.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { continue }
        $after = $Clause.Substring($m.Index + $m.Length)
        if ($after.Length -gt 24) { $after = $after.Substring(0, 24) }
        $unitRaw = ''
        $um = [regex]::Match($after, '^\s*(?:per\s+|each\s+)?(?<u>[A-Za-z]{1,14})')
        if ($um.Success) {
            $cand = ([string]$um.Groups['u'].Value).ToLowerInvariant()
            if ($script:ClarifyUnitStopWords -notcontains $cand) { $unitRaw = $cand }
        }
        $fam = ''
        if ($unitRaw -and $script:ClarifyUnitFamilies.ContainsKey($unitRaw)) { $fam = [string]$script:ClarifyUnitFamilies[$unitRaw] }
        [void]$out.Add([pscustomobject]@{ Text = $m.Groups[1].Value; Value = $val; Composite = ''; UnitRaw = $unitRaw; UnitNorm = $unitRaw; UnitFamily = $fam; Index = $m.Index })
    }
    return @($out.ToArray())
}

# 注意：PowerShell 变量名大小写不敏感，局部变量绝不能叫 $a/$b（那会覆盖同名的 $A/$B 参数）。
function Test-ClarifyNumberEquals($A, $B) {
    $numLeft = 0.0; $numRight = 0.0
    $okLeft = [double]::TryParse([string]$A, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numLeft)
    $okRight = [double]::TryParse([string]$B, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$numRight)
    if ($okLeft -and $okRight) { return ([Math]::Abs($numLeft - $numRight) -lt 0.000001) }
    return ((([string]$A).Trim().ToLowerInvariant()) -eq (([string]$B).Trim().ToLowerInvariant()))
}

# 一个输出数值是否匹配某个**真实候选**：单位/范围必须一致，明确的单位换算才允许归一化；
#   不能凭数字相等推定同单位、同范围（总重与单箱重、产品件与外包装箱不相互冒充）。
function Test-ClarifyCandidateMatch($Token, $Candidate) {
    if (-not $Token -or -not $Candidate) { return $false }
    # 三维尺寸：整串按归一化的 "AxBxC" 逐字比对（不做任何数值推断）。
    $composite = ''
    if ($Token.PSObject.Properties.Name -contains 'Composite') { $composite = [string]$Token.Composite }
    if ($composite) {
        $left = (($composite -replace '\s+', '') -replace '[x\u00d7*]', 'x').ToLowerInvariant()
        $right = ((([string]$Candidate.Value) -replace '\s+', '') -replace '[x\u00d7*]', 'x').ToLowerInvariant()
        $tokenUnit=[string]$Token.UnitNorm;$candidateUnit=([string]$Candidate.Unit).ToLowerInvariant()
        if(-not $tokenUnit){$tokenUnit=$candidateUnit}
        if(-not $script:ClarifyLengthToCm.ContainsKey($tokenUnit) -or -not $script:ClarifyLengthToCm.ContainsKey($candidateUnit)){return $false}
        $lhs=@($left -split 'x');$rhs=@($right -split 'x')
        if($lhs.Count -ne 3 -or $rhs.Count -ne 3){return $false}
        for($axis=0;$axis -lt 3;$axis++){if([math]::Abs(([double]$lhs[$axis]*$script:ClarifyLengthToCm[$tokenUnit])-([double]$rhs[$axis]*$script:ClarifyLengthToCm[$candidateUnit])) -gt 0.000001){return $false}}
        return $true
    }
    $cu = ([string]$Candidate.Unit).Trim().ToLowerInvariant()
    $cfam = ''
    if ($cu -and $script:ClarifyUnitFamilies.ContainsKey($cu)) { $cfam = [string]$script:ClarifyUnitFamilies[$cu] }
    $tFam = [string]$Token.UnitFamily
    if($Token.UnitRaw -and -not $tFam){return $false}
    if ($tFam -and $cfam -and ($tFam -ne $cfam)) { return $false }
    if ($tFam -eq 'mass' -and $cfam -eq 'mass') {
        $leftKg = [double]$Token.Value * [double]$script:ClarifyMassToKg[[string]$Token.UnitNorm]
        $rightKg = 0.0
        if (-not [double]::TryParse([string]$Candidate.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rightKg)) { return $false }
        $rightKg = $rightKg * [double]$script:ClarifyMassToKg[$cu]
        return ([Math]::Abs($leftKg - $rightKg) -lt 0.000001)
    }
    if ($tFam -eq 'length' -and $cfam -eq 'length') {
        $leftCm = [double]$Token.Value * [double]$script:ClarifyLengthToCm[[string]$Token.UnitNorm]
        $rightCm = 0.0
        if (-not [double]::TryParse([string]$Candidate.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rightCm)) { return $false }
        $rightCm = $rightCm * [double]$script:ClarifyLengthToCm[$cu]
        return ([Math]::Abs($leftCm - $rightCm) -lt 0.000001)
    }
    return (Test-ClarifyNumberEquals ([string]$Token.Value) ([string]$Candidate.Value))
}

function Get-ClarifyReasonKind($Field, [string]$Status) {
    if ($Status -eq 'conflict') { return 'conflict' }
    $k = [string]$Field.Key
    if ($k -in @('weight', 'dimensions', 'count', 'unassigned_contact')) { return 'scope' }
    if ($k -in @('unit_dimensions', 'lot_dimensions', 'goods_dimensions')) { return 'unit' }
    if ($k -eq 'delivery_address') { return 'destination' }
    return 'scope'
}

function New-ClarifyCandidate($Value, $Unit, $Scope, $Refs) {
    return [pscustomobject]@{ Value = [string]$Value; Unit = [string]$Unit; Scope = [string]$Scope; SourceRefs = @($Refs) }
}

function Get-ReplyClarificationRequests {
    [CmdletBinding()]
    param($Facts = $null, $Decision = $null)
    $out = New-Object System.Collections.ArrayList
    $byKey = $null
    $conflicts = @()
    $dest = $null
    if ($Facts) {
        if (($Facts.PSObject.Properties.Name -contains 'CargoFacts') -and $Facts.CargoFacts) {
            if ($Facts.CargoFacts.PSObject.Properties.Name -contains 'ByKey') { $byKey = $Facts.CargoFacts.ByKey }
            if ($Facts.CargoFacts.PSObject.Properties.Name -contains 'Conflicts') { $conflicts = @($Facts.CargoFacts.Conflicts) }
        }
        if ($Facts.PSObject.Properties.Name -contains 'Destination') { $dest = $Facts.Destination }
    }
    $scenario = ''
    if ($Decision -and ($Decision.PSObject.Properties.Name -contains 'Scenario')) { $scenario = [string]$Decision.Scenario }

    $keys = @()
    if ($byKey) {
        if ($byKey -is [System.Collections.IDictionary]) { $keys = @($byKey.Keys) } else { $keys = @($byKey.PSObject.Properties.Name) }
    }
    foreach ($k in @($keys | Sort-Object)) {
        $f = Get-ContactFactValue $byKey ([string]$k)
        if (-not $f) { continue }
        $st = [string](Get-ContactFactValue $f 'Status')
        if ($st -ne 'conflict' -and $st -ne 'needs_confirmation') { continue }
        $cands = New-Object System.Collections.ArrayList
        foreach ($c in @($conflicts)) {
            $ck = ''
            if ($c -is [System.Collections.IDictionary]) { if ($c.Contains('Key')) { $ck = [string]$c['Key'] } }
            elseif ($c.PSObject.Properties.Name -contains 'Key') { $ck = [string]$c.Key }
            if ($ck -ne [string]$k) { continue }
            $cc = $null
            if ($c -is [System.Collections.IDictionary]) { if ($c.Contains('Candidates')) { $cc = @($c['Candidates']) } }
            elseif ($c.PSObject.Properties.Name -contains 'Candidates') { $cc = @($c.Candidates) }
            foreach ($one in @($cc)) {
                if (-not $one) { continue }
                $refs = @()
                if ($one -is [System.Collections.IDictionary]) { if ($one.Contains('SourceRefs')) { $refs = @($one['SourceRefs']) } }
                elseif ($one.PSObject.Properties.Name -contains 'SourceRefs') { $refs = @($one.SourceRefs) }
                [void]$cands.Add((New-ClarifyCandidate (Get-ContactFactValue $one 'Value') (Get-ContactFactValue $one 'Unit') (Get-ContactFactValue $one 'Scope') $refs))
            }
            if ($cands.Count -eq 0) {
                $vals = @()
                if ($c -is [System.Collections.IDictionary]) { if ($c.Contains('Values')) { $vals = @($c['Values']) } }
                elseif ($c.PSObject.Properties.Name -contains 'Values') { $vals = @($c.Values) }
                foreach ($v in @($vals)) {
                    [void]$cands.Add((New-ClarifyCandidate $v (Get-ContactFactValue $f 'Unit') (Get-ContactFactValue $f 'Scope') @()))
                }
            }
        }
        # 兼容：结构化候选也可以直接挂在字段本身（CargoFacts.ByKey.<key>.Candidates）。
        if ($cands.Count -eq 0) {
            foreach ($one in @(Get-ContactFactValue $f 'Candidates' @())) {
                if (-not $one) { continue }
                $refs = @()
                $r0 = Get-ContactFactValue $one 'SourceRefs'
                if ($r0) { $refs = @($r0) }
                [void]$cands.Add((New-ClarifyCandidate (Get-ContactFactValue $one 'Value') (Get-ContactFactValue $one 'Unit') (Get-ContactFactValue $one 'Scope') $refs))
            }
        }
        if ($cands.Count -eq 0 -and $st -eq 'needs_confirmation') {
            $fv = [string](Get-ContactFactValue $f 'Value')
            if ($fv) { [void]$cands.Add((New-ClarifyCandidate $fv (Get-ContactFactValue $f 'Unit') (Get-ContactFactValue $f 'Scope') @())) }
        }
        $refs = New-Object System.Collections.ArrayList
        foreach ($ev in @(Get-ContactFactValue $f 'Evidence' @())) {
            if (-not $ev) { continue }
            $mid = [string](Get-ContactFactValue $ev 'MessageId')
            $src = [string](Get-ContactFactValue $ev 'Source')
            $tid = [string](Get-ContactFactValue $ev 'TaskId')
            $rid = [string](Get-ContactFactValue $ev 'RecordId')
            if ($mid -and -not $refs.Contains('message:' + $mid)) { [void]$refs.Add('message:' + $mid) }
            if ($src -and -not $refs.Contains('source:' + $src)) { [void]$refs.Add('source:' + $src) }
            if ($tid -and -not $refs.Contains('task:' + $tid)) { [void]$refs.Add('task:' + $tid) }
            if ($rid -and -not $refs.Contains('record:' + $rid)) { [void]$refs.Add('record:' + $rid) }
        }
        foreach ($c in @($cands)) { foreach ($r in @($c.SourceRefs)) { if (-not $refs.Contains([string]$r)) { [void]$refs.Add([string]$r) } } }
        $label = [string](Get-ContactFactValue $f 'Label')
        if (-not $label) { $label = [string]$k }
        $forms = New-Object System.Collections.ArrayList
        $cv = @($cands | ForEach-Object { [string]$_.Value })
        if ($cv.Count -ge 2) {
            [void]$forms.Add('Which ' + $label + ' is correct - ' + $cv[0] + ' or ' + $cv[1] + '?')
            [void]$forms.Add('Could you confirm whether the ' + $label + ' is ' + $cv[0] + ' or ' + $cv[1] + '?')
        } elseif ($cv.Count -eq 1) {
            [void]$forms.Add('Could you confirm the ' + $label + ' (' + $cv[0] + ')?')
        }
        [void]$forms.Add('Could you confirm which ' + $label + ' we should use?')
        [void]$out.Add([pscustomobject]@{
            Id = ('clarify-' + [string]$k)
            FieldKey = [string]$k
            ReasonKind = (Get-ClarifyReasonKind $f $st)
            Candidates = @($cands.ToArray())
            SourceRefs = @($refs.ToArray())
            AllowedOpenClarification = $true
            AllowedQuestionForms = @($forms.ToArray())
        })
    }

    # 目的地歧义：候选来自真实目的地候选（不是场景名本身）。
    $destCands = @()
    $destOpen = $false
    $destReason = 'destination'
    if ($dest -and ([string]$dest.Kind -eq 'ambiguous')) {
        foreach ($c in @($dest.Candidates)) { if ($c) { $destCands += [string]$c } }
        if ($destCands.Count -eq 0) { $destOpen = $true }
    } elseif ($scenario -eq 'address_clarify') {
        $destReason = 'role'
        $destOpen = $true
    } elseif ($dest -and [bool]$dest.AmazonContext -and -not [bool]$dest.QuoteUsable) {
        $destOpen = $true
    }
    if ($destOpen -or $destCands.Count -gt 0) {
        $cands = New-Object System.Collections.ArrayList
        foreach ($v in @($destCands)) { [void]$cands.Add((New-ClarifyCandidate $v '' 'destination' @())) }
        $forms = New-Object System.Collections.ArrayList
        if ($destCands.Count -ge 2) {
            [void]$forms.Add('Which destination should I quote for - ' + $destCands[0] + ' or ' + $destCands[1] + '?')
        }
        [void]$forms.Add('Which delivery destination should I quote for?')
        [void]$out.Add([pscustomobject]@{
            Id = 'clarify-delivery_address'
            FieldKey = 'delivery_address'
            ReasonKind = $destReason
            Candidates = @($cands.ToArray())
            SourceRefs = @()
            AllowedOpenClarification = $true
            AllowedQuestionForms = @($forms.ToArray())
        })
    }
    return @($out.ToArray())
}

function Get-ClarificationRequestForGroup($Requests, $Group) {
    foreach ($r in @($Requests)) {
        if (-not $r) { continue }
        if (@($Group.Fields) -contains ([string]$r.FieldKey)) { return $r }
    }
    return $null
}

# 澄清候选绑定：句中的每个数值都必须对应一个**真实候选**（单位/范围一致，允许有依据的换算）。
#   没有可枚举候选时只能使用不编造选项的受控开放澄清。
function Test-ClarifyClauseBound([string]$Clause, $Request) {
    if (-not $Request) { return $false }
    $tokens = @(Get-ClarifyNumberTokens $Clause)
    $cands = @($Request.Candidates)
    $scopes=@($cands|ForEach-Object {$_.Scope}|Select-Object -Unique)
    if($Request.FieldKey -match 'weight|dimensions' -and $Clause -match '(?i)\bper\s+(?:carton|pallet|box)|\beach\b' -and $scopes -notcontains 'unit' -and -not($Request.ReasonKind -match 'scope' -and $scopes -contains 'unknown')){return $false}
    if($Clause -match '(?i)\b(?:total|full shipment|whole shipment|whole lot)\b' -and $Request.FieldKey -match 'weight|dimensions' -and $scopes -notcontains 'total' -and $scopes -notcontains 'packed_lot'){return $false}
    if($Request.FieldKey -eq 'carton_count' -and $Clause -match '(?i)\b(?:pieces|pcs|product|goods)\b'){return $false}
    if($Request.FieldKey -in @('recipient_name','delivery_address','supplier_contact','recipient_contact')){
        if($Clause -notmatch '(?i)\bor\b|\bis\s+|\bare\s+') {return [bool]$Request.AllowedOpenClarification}
        $options=[regex]::Match($Clause,"(?i)(?:\bis\s+|\bare\s+|\s-\s)(?<options>[^?]+)\??$")
        if(-not $options.Success){return $false}
        foreach($option in @($options.Groups['options'].Value -split '(?i)\s+or\s+|\s*,\s*')){
            $normalized=($option.Trim() -replace '^Amazon\s+','').ToLowerInvariant()
            if(@($cands|Where-Object {(($_.Value -replace '^Amazon\s+','').Trim().ToLowerInvariant()) -eq $normalized}).Count -eq 0){return $false}
        };return $true
    }
    if($tokens.Count -eq 0 -and $Clause -match '(?i)\bor\b' -and $Clause -notmatch '(?i)\bwhich\b[^?]*we should use'){return $false}

    if ($cands.Count -eq 0) {
        if ($tokens.Count -eq 0) { return [bool]$Request.AllowedOpenClarification }
        return $false
    }
    if ($tokens.Count -eq 0) { return [bool]$Request.AllowedOpenClarification }
    foreach ($t in $tokens) {
        $hit = $false
        foreach ($c in $cands) { if (Test-ClarifyCandidateMatch $t $c) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    return $true
}

function Test-AskFieldConformance {
    [CmdletBinding()]
    param([string]$Text, $Decision = $null)
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text) -or -not $Decision) { return @() }
    $ask = @()
    if ($Decision.PSObject.Properties.Name -contains 'AskFields') { $ask = @($Decision.AskFields | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
    $facts = $null
    if ($Decision.PSObject.Properties.Name -contains 'Facts') { $facts = $Decision.Facts }
    $provided = @{}
    if ($facts) {
        if ($facts.PSObject.Properties.Name -contains 'HasWeight') { $provided['weight'] = [bool]$facts.HasWeight }
        if ($facts.PSObject.Properties.Name -contains 'HasDimensions') { $provided['dimension'] = [bool]$facts.HasDimensions }
        if ($facts.PSObject.Properties.Name -contains 'HasQuoteDestination') { $provided['address'] = [bool]$facts.HasQuoteDestination }
        if ($facts.PSObject.Properties.Name -contains 'HasImages') { $provided['image'] = [bool]$facts.HasImages }
        if ($facts.PSObject.Properties.Name -contains 'HasQuantity') { $provided['count'] = [bool]$facts.HasQuantity }
    }
    # [2026-10-05 spec §3.2/§4.2] The ONE fact model is authoritative for "did the buyer already
    # supply this". Without it, a buyer who gave the supplier contact but still lacks dimensions was
    # reported as asking for a field the decision never authorised.
    $byKey = $null
    if ($facts -and ($facts.PSObject.Properties.Name -contains 'CargoFacts') -and $facts.CargoFacts) {
        if ($facts.CargoFacts.PSObject.Properties.Name -contains 'ByKey') { $byKey = $facts.CargoFacts.ByKey }
    }
    if ($byKey) {
        $fmap = @{
            'weight'    = @('unit_weight', 'total_weight', 'weight')
            'dimension' = @('unit_dimensions', 'lot_dimensions', 'dimensions')
            'count'     = @('carton_count', 'count')
            'address'   = @('delivery_address')
            'image'     = @('reference_images')
            'supplier_address' = @('supplier_address')
        }
        foreach ($gname in @($fmap.Keys)) {
            $hit = $false
            $unresolved = $false
            foreach ($fk in @($fmap[$gname])) {
                $fld = Get-ContactFactValue $byKey $fk
                if (-not $fld) { continue }
                $st = [string](Get-ContactFactValue $fld 'Status')
                if ($st -eq 'provided') { $hit = $true; break }
                # [spec §3.2] conflict / needs_confirmation **不当作已提供**，也不自动授权重新索取；
                #   唯一事实模型比"买家文本里出现过数字"的旧布尔更权威。
                if ($st -eq 'conflict' -or $st -eq 'needs_confirmation') { $unresolved = $true }
            }
            if ($hit) { $provided[$gname] = $true }
            elseif ($unresolved) { $provided[$gname] = $false }
        }
    }
    # [spec §7.1] 结构化澄清证据：只由唯一事实模型 / 真实目的地歧义导出（不再靠"字段有 conflict 布尔"）。
    $clarifyRequests = @(Get-ReplyClarificationRequests -Facts $facts -Decision $Decision)

    foreach ($item in @(Get-ReplyRequestItems -Text $Text -Decision $Decision)) {
        if ($item.Contact -or $item.Action -ne 'ask') { continue }
        $g=@($script:PolicyAskFieldGroups|Where-Object {$_.Fields -contains $item.FieldKey}|Select-Object -First 1)
        if(-not $g.Count){continue};$g=$g[0]
        if($item.Kind -eq 'clarify') {
            $req=@($clarifyRequests|Where-Object {$_.Id -eq $item.ClarifyRef})
            if($req.Count -and (Test-ClarifyClauseBound $item.Text $req[0])){continue}
            [void]$out.Add(@{Code='CLARIFY_CANDIDATE_UNSUPPORTED';Severity='block';Detail=$item.Text});continue
        }
        if($provided.ContainsKey($g.Name) -and $provided[$g.Name]){[void]$out.Add(@{Code='ASK_ALREADY_PROVIDED';Severity='block';Detail=$item.Text});continue}
        $authorized=@($g.Fields|Where-Object {$ask -contains $_}).Count -gt 0
        if(-not $authorized){[void]$out.Add(@{Code='ASK_OUT_OF_SCOPE';Severity='block';Detail=$item.Text})}
    }
    return @($out.ToArray())
}

# ============================================================================================
function Get-ConditionalSupplierPlanText { return "Once you share the supplier's contact, our team will check the packing information with your supplier." }

# [2026-10-05 spec §4.2] Supplier-contact plan wording by TASK STATE
# 条件式计划（"拿到联系人之后我们再去核实"）：awaiting_contact 的确切任务即可授权，保留条件。
$script:PolicySupplierConditionalPlanPatterns = @(
    '(?i)\b(?:once|when|after)\s+you\s+(?:send|share|provide|give)\b[^.!?]{0,50}\b(?:we|our\s+team|i)\b[^.!?]{0,40}\b(?:check|confirm|verify|contact|reach)\b[^.!?]{0,30}\b(?:supplier|vendor|factory)\b'
)
# 无条件的"我们会直接联系供应商核实"：还需要该确切任务上有**可用联系人**（spec §5.1 第 2 行）。
$script:PolicySupplierDeclaredPlanPatterns = @(
    '(?i)\b(?:we|our\s+team|i)(?:''ll|\s+will|\s+can)\s+(?:check|confirm|verify|contact|reach\s+out\s+to)\b[^.!?]{0,40}\b(?:your\s+|the\s+)?(?:supplier|vendor|factory)\b',
    '(?i)\b(?:we|our\s+team|i)\s+(?:can|will)\s+check\s+(?:the\s+)?(?:packed\s+weight|carton\s+count|dimensions?|packing)\b[^.!?]{0,40}\b(?:supplier|vendor|factory)\b'
)
$script:PolicySupplierFuturePlanPatterns = $script:PolicySupplierConditionalPlanPatterns + $script:PolicySupplierDeclaredPlanPatterns
# [spec §5.1] 过去行动与供应商回复**分别取证**：认领/投递不是联系，"已联系"也不是"已回复/已确认"。
$script:PolicySupplierContactClaimPatterns = @(
    '(?i)\b(?:i|we|our\s+team)(?:''ve|\s+have|\s+had)?\s+(?:already\s+)?(?:contacted|reached\s+out\s+to|emailed|called|phoned)\b',
    '(?i)\b(?:i|we|our\s+team)\s+(?:already\s+)?(?:contacted|emailed|called|reached)\s+(?:your\s+|the\s+)?(?:supplier|vendor|factory|warehouse)\b',
    '(?i)\bwe(?:''re|\s+are)\s+(?:waiting|still\s+waiting)\b[^.!?]{0,40}\b(?:supplier|vendor|factory)\b'
)
$script:PolicySupplierReplyClaimPatterns = @(
    '(?i)\b(?:the|your)\s+(?:supplier|vendor|factory)\s+(?:has\s+|have\s+|already\s+)?(?:confirmed|said|replied|told\s+us|reverted|responded)\b',
    '(?i)\b(?:confirmed|verified|checked)\s+by\s+(?:the\s+|your\s+)?(?:supplier|vendor|factory)\b',
    '(?i)\b(?:the|your)\s+(?:supplier|vendor|factory)(?:''s)?\s+(?:confirmation|reply|response)\b'
)
$script:PolicySupplierClaimedPatterns = $script:PolicySupplierContactClaimPatterns + $script:PolicySupplierReplyClaimPatterns
$script:PolicyResolvedClaimPatterns = @(
    '(?i)\b(?:this|that|it|the\s+(?:issue|matter|question|case))\s+(?:is|has\s+been)\s+(?:resolved|settled|sorted|closed|completed|done)\b',
    '(?i)\bwe(?:''ve|\s+have)\s+(?:resolved|settled|completed|finished)\b'
)

# 声明里点到的字段组（用于核对"供应商确认了 X"是否有对应确认记录支持）。
function Get-ClaimedFactGroups([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $map = @(
        @{ Name = 'dimension'; Fields = @('unit_dimensions', 'lot_dimensions', 'goods_dimensions', 'dimensions'); Pattern = '(?i)\b(dimensions?|sizes?|measurements?|cbm)\b' },
        @{ Name = 'weight';    Fields = @('unit_weight', 'total_weight', 'goods_weight', 'weight'); Pattern = '(?i)\b(weights?|kgs?|kilos?|gross|net)\b' },
        @{ Name = 'count';     Fields = @('carton_count', 'count', 'goods_count'); Pattern = '(?i)\b(cartons?|ctns?|boxes|pallets?|packages?|pieces|pcs|units|quantity)\b' },
        @{ Name = 'address';   Fields = @('delivery_address', 'supplier_address'); Pattern = '(?i)\b(address(?:es)?|destination|zip|postal|warehouse\s+code)\b' }
    )
    foreach ($g in $map) { if ($Text -match $g.Pattern) { [void]$out.Add($g) } }
    return @($out.ToArray())
}

# [spec §5.1] "供应商确认了 X/Y/Z" 必须由**该确切任务**的确认记录支持：
#   字段组要在 ConfirmedFields 里有对应字段；带数值时值/单位/范围也要一致。
function Test-SupplierConfirmedContentSupported([string]$Text, $ConfirmedFields) {
    $fields = @($ConfirmedFields)
    foreach ($g in @(Get-ClaimedFactGroups $Text)) {
        $hit = $false
        foreach ($f in $fields) { if (-not $f) { continue }; if (@($g.Fields) -contains ([string]$f.FieldKey)) { $hit = $true; break } }
        if (-not $hit) { return $false }
    }
    foreach ($t in @(Get-ClarifyNumberTokens $Text)) {
        $hit = $false
        foreach ($f in $fields) {
            if (-not $f) { continue }
            $cand = [pscustomobject]@{ Value = $f.Value; Unit = $f.Unit; Scope = $f.Scope }
            if (Test-ClarifyCandidateMatch $t $cand) { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }
    return $true
}

function Get-SupplierTaskState($Decision) {
    # [spec §4.2/§5.1] 逐项取证：任务落盘 / 通知投递 / 人工认领 / **实际联系** / 供应商回复 / 具体确认。
    #   认领（OwnerAccepted）不再授权"我们已经联系了供应商"；已联系也不再授权"供应商已确认"。
    $st = @{ TodoPersisted = $false; TaskStatus = ''; OwnerAccepted = $false
             NotificationDelivered = $false; ContactedRecorded = $false; SupplierReplyRecorded = $false
             TaskId = ''; TaskKind = ''; EvidenceOrigin = ''; ExactTaskMatch = $false; TaskExists = $false
             IsOpen = $false; HasUsableSupplierContact = $false; ResolvedRecorded = $false
             Deadline = ''; KeyEvidenceFingerprint = ''; ConfirmedFields = @() }
    if (-not $Decision) { return $st }
    if ($Decision.PSObject.Properties.Name -contains 'ActionEvidence' -and $Decision.ActionEvidence) {
        $ev = $Decision.ActionEvidence
        foreach ($pair in @(
            @{ K = 'TodoPersisted'; N = 'TodoPersisted' },
            @{ K = 'OwnerAccepted'; N = 'OwnerAccepted' },
            @{ K = 'NotificationDelivered'; N = 'NotificationDelivered' },
            @{ K = 'ContactedRecorded'; N = 'ContactedRecorded' },
            @{ K = 'SupplierReplyRecorded'; N = 'SupplierReplyRecorded' },
            @{ K = 'ResolvedRecorded'; N = 'ResolvedRecorded' },
            @{ K = 'ExactTaskMatch'; N = 'ExactTaskMatch' },
            @{ K = 'TaskExists'; N = 'TaskExists' },
            @{ K = 'IsOpen'; N = 'IsOpen' },
            @{ K = 'HasUsableSupplierContact'; N = 'HasUsableSupplierContact' }
        )) {
            if ($ev.PSObject.Properties.Name -contains $pair.N) { $st[$pair.K] = [bool]$ev.($pair.N) }
        }
        foreach ($pair in @(
            @{ K = 'TaskStatus'; N = 'TaskStatus' }, @{ K = 'TaskId'; N = 'TaskId' },
            @{ K = 'TaskKind'; N = 'TaskKind' }, @{ K = 'EvidenceOrigin'; N = 'EvidenceOrigin' },
            @{ K = 'Deadline'; N = 'Deadline' }, @{ K = 'KeyEvidenceFingerprint'; N = 'KeyEvidenceFingerprint' }
        )) {
            if ($ev.PSObject.Properties.Name -contains $pair.N) { $st[$pair.K] = [string]$ev.($pair.N) }
        }
        if ($ev.PSObject.Properties.Name -contains 'ConfirmedFields') { $st.ConfirmedFields = @($ev.ConfirmedFields) }
    }
    # 任务类型归一（human_tasks 未加载时退化为原样比较，绝不因此抛错）。
    if ($st.TaskKind -and (Get-Command Resolve-HumanTaskKind -ErrorAction SilentlyContinue)) {
        $st.TaskKind = [string](Resolve-HumanTaskKind ([string]$st.TaskKind))
    }
    return $st
}

function Test-SupplierPlanWording {
    [CmdletBinding()]
    param([string]$Text, $Decision = $null)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $st = Get-SupplierTaskState $Decision
    # ① 供应商未来计划至少需要：canonical supplier_verification + **确切任务回读匹配** + 任务仍开放。
    #    泛化的 TodoPersisted（例如一条 fulfillment_status 待办）不授权任何供应商动作。
    $supplierTaskOk = ([string]$st.TaskKind -eq 'supplier_verification' -and [bool]$st.ExactTaskMatch)
    if (-not $supplierTaskOk) {
        foreach ($p in $script:PolicySupplierFuturePlanPatterns) { if ($Text -match $p) { return $true } }
        foreach ($p in $script:PolicySupplierContactClaimPatterns) { if ($Text -match $p) { return $true } }
        foreach ($p in $script:PolicySupplierReplyClaimPatterns) { if ($Text -match $p) { return $true } }
        return $false
    }
    if (-not $st.IsOpen) { foreach($p in $script:PolicySupplierFuturePlanPatterns){if($Text -match $p){return $true}} }
    # ①b 无条件"直接联系"还需要该确切任务上有可用联系人（awaiting_contact 缺联系人时只能条件式表达）。
    if (-not [bool]$st.HasUsableSupplierContact) {
        # Only the exact program-owned conditional sentence is exempt. Any extra unconditional action still blocks.
        $declaredText=$Text.Replace((Get-ConditionalSupplierPlanText),'')
        foreach ($p in $script:PolicySupplierDeclaredPlanPatterns) { if ($declaredText -match $p) { return $true } }
    }
    # ② "我们已经联系过供应商" 需要联系记录（认领/投递都不算）。
    if (-not [bool]$st.ContactedRecorded) {
        foreach ($p in $script:PolicySupplierContactClaimPatterns) { if ($Text -match $p) { return $true } }
    }
    # ③ "供应商已回复/已确认" 需要对应的回复记录与来源；具体内容还要由确认字段支持。
    if (-not [bool]$st.SupplierReplyRecorded) {
        foreach ($p in $script:PolicySupplierReplyClaimPatterns) { if ($Text -match $p) { return $true } }
    } elseif (-not (Test-SupplierConfirmedContentSupported $Text $st.ConfirmedFields)) {
        return $true
    }
    # ④ 事项已完成/已解决需要该事项的实际完成记录（任务关闭本身不算供应商已确认）。
    if (-not [bool]$st.ResolvedRecorded) {
        foreach ($p in $script:PolicyResolvedClaimPatterns) { if ($Text -match $p) { return $true } }
    }
    # ⑤ 计划状态约束：已解决/关闭的任务不再有未来行动授权。
    $planAllowedStates = @('awaiting_contact', 'pending_human', 'contacted', 'awaiting_supplier_reply', '')
    if ($planAllowedStates -notcontains [string]$st.TaskStatus) {
        foreach ($p in $script:PolicySupplierFuturePlanPatterns) { if ($Text -match $p) { return $true } }
    }
    # ⑥ 时限承诺不得超过记录授权：涉及任务/供应商行动的期限必须来自已确认的 Deadline。
    if (-not $st.Deadline) {
        $hasSupplierAction = $false
        foreach ($p in $script:PolicySupplierFuturePlanPatterns) { if ($Text -match $p) { $hasSupplierAction = $true; break } }
        foreach ($p in $script:PolicySupplierContactClaimPatterns) { if ($Text -match $p) { $hasSupplierAction = $true; break } }
        if ($hasSupplierAction) {
            foreach ($p in $script:PolicyTimeCommitmentPatterns) { if ($Text -match $p) { return $true } }
        }
    }
    return $false
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
    # [2026-10-05 spec §3.2] Packaging-scoped field names from the one fact model are askable too;
    # each maps onto the same provided-ness evidence as its legacy equivalent.
    $alias = @{ 'carton_count' = 'count'; 'unit_weight' = 'weight'; 'total_weight' = 'weight'
                'unit_dimensions' = 'dimension'; 'lot_dimensions' = 'dimension'
                'delivery_address' = 'address'; 'reference_images' = 'image'
                'supplier_contact' = 'supplier' }
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'CargoFacts') -and $Facts.CargoFacts) {
        foreach ($k in @('carton_count', 'unit_weight', 'unit_dimensions', 'delivery_address', 'recipient_contact', 'recipient_name', 'supplier_contact', 'reference_images', 'goods_name')) {
            if ($consider -notcontains $k -and $AllowedFields.Count -eq 0) { $consider += $k }
        }
    }
    foreach ($f in $consider) {
        $provided = $false
        $base = $f
        if ($alias.ContainsKey($f)) { $base = [string]$alias[$f] }
        switch ($base) {
            'weight'    { $provided = [bool]$Facts.HasWeight }
            'dimension' { $provided = [bool]$Facts.HasDimensions }
            'address'   { $provided = [bool]$Facts.HasQuoteDestination }
            'image'     { $provided = [bool]$Facts.HasImages }
            # Only an actual contact value counts as provided (see Get-ConversationFacts).
            'supplier'  { $provided = [bool]$Facts.HasSupplierContact }
            'count'     { $provided = [bool]$Facts.HasQuantity }
        }
        # The fact model is authoritative for its own fields when it is available.
        if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'CargoFacts') -and $Facts.CargoFacts) {
            $cf = $Facts.CargoFacts
            $field = $null
            # ByKey is a HASHTABLE (the fact engine's contract allows $ByKey['key']). In PS 5.1 a
            # hashtable's PSObject.Properties only exposes IsReadOnly/Keys/Values/Count, so the old
            # "-contains" guard was always false and this whole branch was dead code.
            if ($cf.ByKey -is [System.Collections.IDictionary]) {
                if ($cf.ByKey.Contains($f)) { $field = $cf.ByKey[$f] }
            } elseif ($cf.ByKey -and ($cf.ByKey.PSObject.Properties.Name -contains $f)) {
                $field = $cf.ByKey.$f
            }
            if ($field) {
                $st = [string]$field.Status
                if ($st -eq 'provided') { $provided = $true }
                elseif ($st -eq 'conflict' -or $st -eq 'needs_confirmation') { $provided = $false }
            }
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

# ============================================================================================
# CURRENT-TURN BASE FACTS (2026-10-05 spec §4)
# The buyer's actual question for THIS turn, in the order it was asked. Deliberately narrow:
# delivery time / transit time / arrival time / company address / how much must NOT be captured
# here, and a statement that merely mentions a keyword must not become a question.
# ============================================================================================

# Compare company statements against the confirmed value without being fooled by punctuation.
function Normalize-CompanyName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.ToLowerInvariant()
    $n = $n -replace '[^a-z0-9]+', ' '
    $n = $n -replace '\s+', ' '
    return $n.Trim()
}

# Same normalization for a person's display name. Hyphens, apostrophes and periods are separators,
# so "Taylor-Reed", "Taylor Reed" and "Taylor Reed." all normalize identically.
function Normalize-PersonName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.ToLowerInvariant()
    $n = $n -replace '[^a-z0-9]+', ' '
    $n = $n -replace '\s+', ' '
    return $n.Trim()
}

# First words that are ordinary sentence starts after "I'm", never a self-introduced name.
$script:SelfIntroductionNonNames = @(
    'The', 'A', 'An', 'Happy', 'Glad', 'Sorry', 'Here', 'Not', 'Unable', 'Still', 'Also', 'Just',
    'Going', 'Looking', 'Checking', 'Working', 'Afraid', 'Sure', 'Based', 'Trying', 'On', 'In',
    'From', 'Currently', 'Always', 'Ready', 'Available', 'Located', 'Open', 'Able', 'Really',
    'Very', 'New', 'Interested', 'Waiting', 'Gladly', 'Pleased', 'Confident'
)

# First words that start an ordinary sentence after "we're" / "we are", never a company name.
$script:CompanyStatementNonNames = @(
    'The', 'A', 'An', 'Happy', 'Glad', 'Sorry', 'Here', 'Not', 'Unable', 'Still', 'Also', 'Just',
    'Going', 'Looking', 'Checking', 'Working', 'Afraid', 'Sure', 'Based', 'Trying', 'On', 'In',
    'From', 'Currently', 'Always', 'Ready', 'Available', 'Located', 'Open', 'Able', 'Really',
    'Very', 'New', 'Interested', 'Waiting', 'Pleased', 'Confident', 'Your', 'Our', 'We'
)

# Trim a captured "we're <...>" run down to the company statement itself. A legal-form abbreviation
# ("Co., Ltd.", "Inc.", "GmbH.") contains a period that is NOT a sentence end; treating it as one is
# what truncated the owner-confirmed name. Returns the statement, or '' when nothing remains.
function Get-CompanyStatementCandidate([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $t = $Raw.Trim()
    # 1) A coordinating boundary ends the name ONLY when a lowercase clause follows it:
    #    "… Co., Ltd. and we ship to Europe" ends the name, while "… Co., Ltd. and Global Sourcing
    #    Ltd." does not - that is a second, capitalized identity and must stay inside the candidate
    #    so it is compared and blocked.
    #    (?i:...) scopes case-insensitivity to the conjunction itself: a bare leading (?i) would
    #    also make the [a-z] lookahead case-insensitive and the distinction would be lost.
    $m = [regex]::Match($t, '(?i:\s+(?:and|but|so|which|that|where|while|because|however|although)\s+)(?=[a-z])')
    if ($m.Success) { $t = $t.Substring(0, $m.Index) }
    # 2) A comma that does NOT introduce a legal-form token ends the name. "Co., Ltd." survives.
    $m = [regex]::Match($t, '(?i),\s+(?!(?:ltd|limited|inc|incorporated|llc|corp|corporation|co|company|plc|gmbh|pty|pte|sdn|bhd|s\.?a|b\.?v|n\.?v)\b)')
    if ($m.Success) { $t = $t.Substring(0, $m.Index) }
    # 3) The first period that really ends a sentence: followed by whitespace + a new sentence, or
    #    by the end of the string. "Co.," is followed by a comma, so it is not a sentence end.
    for ($i = 0; $i -lt $t.Length; $i++) {
        $ch = $t[$i]
        if ($ch -ne '.' -and $ch -ne '!' -and $ch -ne '?') { continue }
        $rest = ''
        if ($i + 1 -lt $t.Length) { $rest = $t.Substring($i + 1) }
        # -cnotmatch, not -notmatch: PowerShell's -match is case-INSENSITIVE, so a plain -notmatch
        # would treat " and Global ..." as a new sentence and cut the name short again.
        if ($rest -ne '' -and $rest -cnotmatch '^\s+[A-Z0-9]') { continue }
        return $t.Substring(0, $i + 1).Trim()
    }
    return $t.Trim()
}

# ============================================================================================
# [2026-10-05 spec §7 T1/T2] 时间问题的地点绑定
#
# 三态（spec §7.2 第 1 条），绝不把"解析失败"压成"未指定"：
#   seller  —— 本轮没有指定任何时间地点 ⇒ 回答卖家所在地时间
#   explicit + Resolved=$true  —— 明确地点且可可靠解析 ⇒ 转换到该时区
#   explicit + Resolved=$false —— 明确地点但解析不了 / 多时区国家缺城市 ⇒ 只澄清地点，不答卖家时间
# 范围（spec §7.2 第 2/3 条）：地点只从**时间问句本身**所在的小句/句子/消息里取，不遍历整段输入
#   的所有 in/at 再取最后一个。后半句的公司/供应商/仓库/运输目的地因此无法覆盖时间目标。
# ============================================================================================

# 时间问句的模式表提升到脚本作用域：Get-TimePlaceInfo 需要知道"哪里是时间问题"。
$script:PolicyTimeQuestionPatterns = @(
    '(?i)\bwhat\s+time\s+is\s+it\b',
    '(?i)\bwhat(?:''s|s| is)\s+the\s+(?:current\s+|local\s+|exact\s+)?time\b',
    '(?i)\bthe\s+current\s+time\b',
    '(?i)\bcurrent\s+time\s+(?:now|please|here|there)\b',
    '(?i)\bwhat(?:''s| is)\s+my\s+local\s+time\b',
    '(?i)\bmy\s+local\s+time\b',
    '(?i)\b(?:got|have)\s+the\s+time\b',
    '(现在(是)?几点|几点(了|钟)?|当前时间|现在时间|时间是多少|现在的时间)'
)

# 时间问句的位置（**全部**出现处，升序）。返回 @() 表示这一段里没有时间问题。
function Get-TimeQuestionIndexes([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($p in $script:PolicyTimeQuestionPatterns) {
        foreach ($m in [regex]::Matches($Text, $p)) {
            if (-not $out.Contains([int]$m.Index)) { [void]$out.Add([int]$m.Index) }
        }
    }
    if ($out.Count -eq 0) { return @() }
    return @($out.ToArray() | Sort-Object)
}

# 兼容入口：最早一处的下标；-1 表示没有时间问题。
function Get-TimeQuestionIndex([string]$Text) {
    $all = @(Get-TimeQuestionIndexes $Text)
    if ($all.Count -eq 0) { return -1 }
    return [int]$all[0]
}

# 句子边界：句末标点 + 空白 + 大写字母开头（或到文本结尾）。
#   刻意与公司名判据用同一套"真正的句末"定义，避免把 "Co., Ltd." 这类缩写当成句末。
function Get-SentenceBounds([string]$Text, [int]$Index) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Start = 0; End = 0 } }
    $t = [string]$Text
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $t.Length) { $Index = $t.Length - 1 }
    $start = 0
    for ($i = $Index - 1; $i -ge 0; $i--) {
        $ch = $t[$i]
        if ($ch -ne '.' -and $ch -ne '!' -and $ch -ne '?' -and $ch -ne ';' -and [int][char]$ch -ne 0x3002 -and [int][char]$ch -ne 0xFF1F) { continue }
        $rest = ''
        if ($i + 1 -lt $t.Length) { $rest = $t.Substring($i + 1) }
        if ($rest -ne '' -and $rest -cnotmatch '^\s+[A-Z0-9]') { continue }
        $start = $i + 1
        break
    }
    $end = $t.Length
    for ($i = [Math]::Max($Index, $start); $i -lt $t.Length; $i++) {
        $ch = $t[$i]
        if ($ch -ne '.' -and $ch -ne '!' -and $ch -ne '?' -and $ch -ne ';' -and [int][char]$ch -ne 0x3002 -and [int][char]$ch -ne 0xFF1F) { continue }
        $rest = ''
        if ($i + 1 -lt $t.Length) { $rest = $t.Substring($i + 1) }
        if ($rest -ne '' -and $rest -cnotmatch '^\s+[A-Z0-9]') { continue }
        $end = $i + 1
        break
    }
    return @{ Start = $start; End = $end }
}

# 业务地点引导语：公司 / 办公地 / 仓库 / 供应商 / 收货地址 / 运输目的地。它们**不是**时间目标。
$script:PolicyTimeBusinessPlaceLead = '(?i)\b(?:my|our|the)\s+(?:company|office|warehouse|factory|supplier|vendor|buyer|address|destination|port)\b|\b(?:we|i)\s+(?:are|am)\s+(?:based|located)\b|\bshipping\s+(?:to|from)\b|\bdeliver(?:y|ing)?\s+to\b'

# 单个时间问题的范围（spec F6 §7.1 第 1/2 条）：
#   * 先按**消息边界**（调用方逐行传入）与**句界**取出包含该问句的句子；
#   * 业务地点位于问句**前方** ⇒ 范围从问句起点开始（绝不截成空后再退回整段文本搜索）；
#   * 业务地点位于问句**后方** ⇒ 在业务从句之前截断。
#   句界不以"下一句首字母大写"为条件：这里同时接受逗号、分号、口语并列与大小写变体。
function Get-TimeQuestionSpan([string]$Text, [int]$Index) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Start = 0; End = 0; Text = '' } }
    $t = [string]$Text
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $t.Length) { $Index = $t.Length - 1 }
    $b = Get-SentenceBounds $t $Index
    $rel = $Index - $b.Start
    $seg = $t.Substring($b.Start, [Math]::Max(0, $b.End - $b.Start))
    $cut = [regex]::Match($seg, $script:PolicyTimeBusinessPlaceLead)
    if ($cut.Success) {
        if ($cut.Index -le $rel) {
            $seg = $seg.Substring($rel)
            $rel = 0
        } else {
            $seg = $seg.Substring(0, $cut.Index)
        }
    }
    return @{ Start = ($b.Start + $rel); End = ($b.Start + $rel + $seg.Length); Text = $seg.Trim() }
}

# 兼容入口：第一个时间问题的范围文本。
function Get-TimeQuestionScope([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    foreach ($line in @([string]$Text -split "\r?\n")) {
        if (-not $line) { continue }
        $idxs = @(Get-TimeQuestionIndexes $line)
        if ($idxs.Count -eq 0) { continue }
        return [string](Get-TimeQuestionSpan $line ([int]$idxs[0])).Text
    }
    return ''
}

$script:PolicyTimePlaceFiller = '(?i)\s*\b(now|right\s+now|currently|today|tonight|please|exactly|at\s+the\s+moment|here|there|thanks|thank\s+you)\b\s*$'

# 一段范围文本里的**全部**地点候选（按出现顺序、去重）。并列句（and/or/逗号）逐项切开，
# 因此 "in China and in Tokyo" 得到两个目标，而不是一个 "China and in Tokyo" 长串。
function Get-TimePlaceCandidates([string]$ScopeText) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($ScopeText)) { return @() }
    foreach ($m in [regex]::Matches([string]$ScopeText, "(?i)\b(?:in|at)\s+([A-Za-z][A-Za-z\s/_.'\-]{0,40})")) {
        $raw = [string]$m.Groups[1].Value
        $pieces = @([regex]::Split($raw, '(?i)\s+(?:and|or)\s+|,'))
        for ($pi = 0; $pi -lt $pieces.Count; $pi++) {
            $cand = [string]$pieces[$pi]
            if ($pi -gt 0) { $cand = ($cand -replace '^(?i)(?:in|at)\s+', '') }
            $cand = ($cand -split '[?!,;:]')[0]
            $prev = ''
            while ($prev -ne $cand) {
                $prev = $cand
                $cand = $cand -replace $script:PolicyTimePlaceFiller, ''
                $cand = $cand.Trim().TrimEnd('.', ' ', ',')
            }
            if (-not $cand) { continue }
            if (($cand -split '\s+').Count -gt 4) { continue }
            $lc = ($cand -replace '^(?i)(?:in|at|the)\s+', '').ToLowerInvariant().Trim()
            if (-not $lc) { continue }
            if ($lc -in @('the', 'a', 'an')) { continue }
            if ($out -notcontains $cand) { [void]$out.Add($cand) }
        }
    }
    return @($out.ToArray())
}

# 一个地点候选的三态判定（spec §7.1 第 3 条：unspecified / explicit_resolved / explicit_unresolved，
#   已指定但未知**不能**降成未指定）。返回 @{ PlaceRaw; Place; State; Kind; Resolved; Reason; TimeZone }
function Get-TimePlaceTargetState([string]$Candidate) {
    $t = [pscustomobject]@{ PlaceRaw = [string]$Candidate; Place = [string]$Candidate; State = 'explicit_unresolved'
                            Kind = 'explicit'; Resolved = $false; Reason = 'place-not-resolvable'; TimeZone = '' }
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $t }
    $zone = $null
    if (Get-Command Resolve-PlaceTimeZone -ErrorAction SilentlyContinue) { $zone = Resolve-PlaceTimeZone $Candidate }
    if ($zone -and $zone.Ok) {
        $t.State = 'explicit_resolved'; $t.Resolved = $true; $t.Reason = 'resolved'
        # Place 保留**买家点名的原文**（'Tokyo' / 'hamburg'）：渲染与展示都用它，
        #   时区信息单独放在 TimeZone 里；只有多时区国家才规范化成国名（与既有澄清措辞一致）。
        if ($zone.Iana) { $t.TimeZone = [string]$zone.Iana }
        return $t
    }
    if ($zone -and $zone.Ambiguous) {
        $t.State = 'explicit_unresolved'; $t.Resolved = $false; $t.Reason = 'ambiguous-multiple-time-zones'
        if ($zone.Place) { $t.Place = [string]$zone.Place }
        return $t
    }
    $t.State = 'explicit_unresolved'; $t.Resolved = $false; $t.Reason = 'place-not-resolvable'
    return $t
}

# 每个时间问题的目标列表：未指定地点 ⇒ 一个 unspecified 目标（卖家时区）；
#   有地点 ⇒ 逐个候选一条目标（可靠/未解析分别标注，全部保留，绝不只留第一个）。
function Get-TimeTargetsForScope([string]$ScopeText, [string]$RequestId = '', [string]$MessageId = '', $QuestionSpan = $null) {
    $out = New-Object System.Collections.ArrayList
    $cands = @(Get-TimePlaceCandidates $ScopeText)
    if ($cands.Count -eq 0) {
        $localUnknown = [bool](($ScopeText -match '(?i)\b(here|where\s+i\s+am)\b') -or ($ScopeText -match '(?i)\bmy\s+local\s+time\b'))
        if ($localUnknown) {
            [void]$out.Add([pscustomobject]@{ RequestId = $RequestId; MessageId = $MessageId; QuestionSpan = $QuestionSpan; ScopeText = $ScopeText
                PlaceRaw = ''; Place = ''; State = 'explicit_unresolved'; Kind = 'unknown'; Resolved = $false
                Reason = 'buyer-local-time-zone-unknown'; TimeZone = '' })
        } else {
            [void]$out.Add([pscustomobject]@{ RequestId = $RequestId; MessageId = $MessageId; QuestionSpan = $QuestionSpan; ScopeText = $ScopeText
                PlaceRaw = ''; Place = ''; State = 'unspecified'; Kind = 'seller'; Resolved = $true
                Reason = 'no-place-named'; TimeZone = '' })
        }
        return @($out.ToArray())
    }
    foreach ($c in $cands) {
        $st = Get-TimePlaceTargetState $c
        [void]$out.Add([pscustomobject]@{ RequestId = $RequestId; MessageId = $MessageId; QuestionSpan = $QuestionSpan; ScopeText = $ScopeText
            PlaceRaw = [string]$st.PlaceRaw; Place = [string]$st.Place; State = [string]$st.State; Kind = [string]$st.Kind
            Resolved = [bool]$st.Resolved; Reason = [string]$st.Reason; TimeZone = [string]$st.TimeZone })
    }
    return @($out.ToArray())
}

# 时间请求列表（spec F6 §7.1 第 1/3/4 条）：每个时间问题一条，含消息边界与全部目标。
function Get-TimeRequestList([string]$Text) {
    $requests = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $lines = @([string]$Text -split "\r?\n")
    $offset = 0
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $line = [string]$lines[$li]
        if ($line) {
            $msgId = 'msg-' + ($li + 1) + ':' + (Get-TimeRequestMessageId $line)
            $idxs = @(Get-TimeQuestionIndexes $line)
            $lastEnd = -1
            $qNo = 0
            foreach ($i in $idxs) {
                if ([int]$i -lt $lastEnd) { continue }
                $span = Get-TimeQuestionSpan $line ([int]$i)
                $lastEnd = [int]$span.End
                $qNo++
                $rid = 'time-' + ($li + 1) + '-' + $qNo
                $qs = @{ Start = ($offset + [int]$span.Start); End = ($offset + [int]$span.End) }
                $targets = @(Get-TimeTargetsForScope ([string]$span.Text) $rid $msgId $qs)
                [void]$requests.Add([pscustomobject]@{
                    RequestId    = $rid
                    MessageId    = $msgId
                    QuestionSpan = $qs
                    QuestionText = [string]$span.Text
                    Targets      = @($targets)
                })
            }
        }
        $offset += $line.Length + 1
    }
    return @($requests.ToArray())
}

# 消息身份的稳定片段（内容 hash，不用位置下标）：同一段未答文本在多次扫描里得到同一个 MessageId。
function Get-TimeRequestMessageId([string]$Line) {
    $norm = ([string]$Line -replace '\s+', ' ').Trim().ToLowerInvariant()
    if (-not $norm) { return 'empty' }
    if (Get-Command Get-StableHash -ErrorAction SilentlyContinue) { return ([string](Get-StableHash $norm)).Substring(0, [Math]::Min(10, ([string](Get-StableHash $norm)).Length)) }
    return ([string][Math]::Abs($norm.GetHashCode()))
}

# 扁平化的时间目标列表（决策、渲染、模型上下文、重写、回退与发送前检查共用同一份）。
function Get-TimeTargetList([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-TimeRequestList $Text)) {
        foreach ($t in @($r.Targets)) { [void]$out.Add($t) }
    }
    return @($out.ToArray())
}

# 三态地点信息（兼容入口）：返回**第一个**目标，另附全部目标列表供新消费方使用。
#   @{ Place; Kind; Resolved; Reason; Scope; State; TimeZone; Targets; Requests }
function Get-TimePlaceInfo([string]$Text) {
    $info = [pscustomobject]@{ Place = ''; Kind = 'seller'; Resolved = $true; Reason = 'no-place-named'; Scope = ''
                               State = 'unspecified'; TimeZone = ''; Targets = @(); Requests = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $info }
    $requests = @(Get-TimeRequestList $Text)
    $targets = New-Object System.Collections.ArrayList
    foreach ($r in $requests) { foreach ($t in @($r.Targets)) { [void]$targets.Add($t) } }
    $info.Requests = @($requests)
    $info.Targets = @($targets.ToArray())
    if ($targets.Count -eq 0) { return $info }
    $first = $targets[0]
    $info.Place = [string]$first.Place
    $info.Kind = [string]$first.Kind
    $info.Resolved = [bool]$first.Resolved
    $info.Reason = [string]$first.Reason
    $info.State = [string]$first.State
    $info.TimeZone = [string]$first.TimeZone
    if ($requests.Count -gt 0) { $info.Scope = [string]$requests[0].QuestionText }
    return $info
}

# 兼容入口：只要第一个地点原文。
function Get-RequestedTimePlace([string]$Text) {
    return [string](Get-TimePlaceInfo $Text).Place
}

# 兼容入口：时间问题里被点名的全部地点原文（逐目标状态请用 Get-TimeTargetList）。
function Get-TimeQuestionPlaces([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    foreach ($t in @(Get-TimeTargetList $Text)) {
        if (-not $t.PlaceRaw) { continue }
        if ($out -notcontains [string]$t.PlaceRaw) { [void]$out.Add([string]$t.PlaceRaw) }
    }
    return @($out.ToArray())
}

# The currently unanswered request = the trailing run of buyer messages with no reply from our side
# after them. Previously answered questions that merely sit later in the window are therefore not
# answered again, and several short unanswered messages are answered together in one turn.
function Get-CurrentRequestText($Conversation) {
    if (-not $Conversation) { return '' }
    $msgs = @($Conversation.Messages | Where-Object { $_ -and -not $_.IsSystemCard })
    $parts = New-Object System.Collections.ArrayList
    for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
        $m = $msgs[$i]
        if ($m.Role -eq 'me') { break }
        if ($m.Role -eq 'buyer' -and $m.Orig) { [void]$parts.Insert(0, [string]$m.Orig) }
    }
    return ((@($parts.ToArray()) -join ' ').Trim())
}

# [F6 §7.1 第 1 条] 同一批未答买家消息的**逐条**文本（保留消息边界）。
#   CurrentRequestText 仍然是『合并成一句』的展示/场景输入（既有消费方依赖这个口径），
#   但时间问题必须按消息逐条识别起点/结束，因此事实与目标解析走这一份逐条文本。
function Get-CurrentRequestLines($Conversation) {
    if (-not $Conversation) { return @() }
    $msgs = @($Conversation.Messages | Where-Object { $_ -and -not $_.IsSystemCard })
    $parts = New-Object System.Collections.ArrayList
    for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
        $m = $msgs[$i]
        if ($m.Role -eq 'me') { break }
        if ($m.Role -eq 'buyer' -and $m.Orig) { [void]$parts.Insert(0, [string]$m.Orig) }
    }
    return @($parts.ToArray())
}

function Get-FactIntents([string]$Text) {
    $t = ''
    if ($Text) { $t = [string]$Text }
    # Buyers type typographic apostrophes ("what’s ur name"); normalize them to ASCII so the same
    # patterns match. This is the only text mutation this matcher performs.
    if ($t) {
        $t = $t.Replace([char]0x2018, "'").Replace([char]0x2019, "'").Replace([char]0x02BC, "'").Replace([char]0xFF07, "'")
    }
    if ([string]::IsNullOrWhiteSpace($t)) {
        return [pscustomobject]@{ Intents = @(); Primary = ''; HasBusiness = $false; Subject = 'unknown'; Place = ''; PlaceKind = 'seller'; PlaceResolved = $true; PlaceReason = 'empty'; TimeScope = ''; ForeignSubject = $false }
    }

    $hasQuestionMark = [bool](($t -match '\?') -or ($t -match '？'))
    $hasWh = [bool](($t -match '(?i)\b(what|which|who|when|where|how|tell|remind|may\s+i\s+know|do\s+you\s+know)\b') -or ($t -match '(什么|哪|谁|几|叫|多少)'))
    $foreignOwner = '(?i)(supplier|vendor|factory|my|buyer)\s*''?s?\s*$'
    $hits = @{}

    # --- current time: interrogative forms only ------------------------------------------------
    # 模式表在脚本作用域（Get-TimePlaceInfo 需要同一份定义，避免两处漂移）。
    foreach ($p in $script:PolicyTimeQuestionPatterns) {
        $m = [regex]::Match($t, $p)
        if ($m.Success) { if (-not $hits.ContainsKey('current_time') -or $m.Index -lt $hits['current_time']) { $hits['current_time'] = $m.Index } }
    }

    # --- our company: question forms only; supplier/vendor/factory "company name" is NOT ours ----
    $companyPatterns = @(
        '(?i)\b(what|which|who)(?:''s|s| is| are| am)?\b[^.!?\r\n]{0,24}\b(your|ur|u|the)\s+company\b(?!\s*(?:address|location|office|number|phone|email|registration|licen[cs]e|policy|website|rate|price|fee|charge|about|doing|sell|ship|offer|profile))',
        '(?i)\bname\s+of\s+(your|ur|u|the)\s+company\b',
        '(?i)\b(tell|remind)\s+me\s+(?:again\s+)?(?:what\s+)?(?:your|ur|u|the)\s+company\b',
        '(你|您)(们)?(的)?公司(叫(什么|啥)?|是(什么|哪家|哪个|谁)|名称|名字)',
        '公司叫什么'
    )
    $companyQuestionPatterns = @(
        '(?i)\b(your|ur|u|the)\s+company(?:''s)?\s+name\b',
        '(?i)\bcompany\s+name\b'
    )
    foreach ($p in $companyPatterns) {
        foreach ($m in [regex]::Matches($t, $p)) {
            $prefix = $t.Substring(0, $m.Index)
            if ($prefix -match $foreignOwner) { continue }
            if (-not $hits.ContainsKey('seller_company') -or $m.Index -lt $hits['seller_company']) { $hits['seller_company'] = $m.Index }
        }
    }
    if ($hasQuestionMark -or $hasWh) {
        foreach ($p in $companyQuestionPatterns) {
            foreach ($m in [regex]::Matches($t, $p)) {
                $prefix = $t.Substring(0, $m.Index)
                if ($prefix -match $foreignOwner) { continue }
                if (-not $hits.ContainsKey('seller_company') -or $m.Index -lt $hits['seller_company']) { $hits['seller_company'] = $m.Index }
            }
        }
    }

    # --- our service display name --------------------------------------------------------------
    $namePatterns = @(
        '(?i)\bwhat(?:''s|s| is| are)\s+(?:your|ur|u)\s+name\b',
        '(?i)\bwhat\s+do\s+(?:i|we)\s+call\s+you\b',
        '(?i)\b(who|which)\s+are\s+you\b',
        '(?i)\b(tell|remind)\s+me\s+(?:again\s+)?(?:what\s+)?(?:your|ur|u)\s+name\b',
        '(你叫什么|您叫什么|你(的)?名字|您(的)?名字|你是谁|您是谁|怎么称呼你|你的名字叫什么)'
    )
    $nameQuestionPatterns = @('(?i)\b(your|ur|u)\s+name\b')
    foreach ($p in $namePatterns) {
        $m = [regex]::Match($t, $p)
        if ($m.Success) {
            $prefix = $t.Substring(0, $m.Index)
            if ($prefix -match $foreignOwner) { continue }
            if (-not $hits.ContainsKey('seller_name') -or $m.Index -lt $hits['seller_name']) { $hits['seller_name'] = $m.Index }
        }
    }
    if ($hasQuestionMark -or $hasWh) {
        foreach ($p in $nameQuestionPatterns) {
            $m = [regex]::Match($t, $p)
            if ($m.Success) {
                $prefix = $t.Substring(0, $m.Index)
                if ($prefix -match $foreignOwner) { continue }
                if (-not $hits.ContainsKey('seller_name') -or $m.Index -lt $hits['seller_name']) { $hits['seller_name'] = $m.Index }
            }
        }
    }

    # --- "are you a bot" ------------------------------------------------------------------------
    $identityPatterns = @(
        '(?i)\b(are|is)\s+(you|this|it)\s+(an?\s+)?(bot|robot|ai|automated|auto-?reply|chatbot|machine)\b',
        '(是不是机器人|你是机器人|您是机器人|是机器人吗|你是ai|您是ai)'
    )
    foreach ($p in $identityPatterns) {
        $m = [regex]::Match($t, $p)
        if ($m.Success) { if (-not $hits.ContainsKey('assistant_identity') -or $m.Index -lt $hits['assistant_identity']) { $hits['assistant_identity'] = $m.Index } }
    }

    $intents = New-Object System.Collections.ArrayList
    foreach ($key in @($hits.Keys | Sort-Object { $hits[$_] })) { [void]$intents.Add([string]$key) }
    $intentList = @($intents.ToArray())

    # A shipping / quotation signal in the same turn means the facts are answered first and the
    # original inquiry policy still asks for the fields that are genuinely missing.
    $businessPattern = '(?i)\b(quote|quotation|pricing|price|cost|rate|how\s+much|freight|shipping|ship|deliver\w*|delivery|transit|warehouse|container|pallet|carton|cargo|consign\w*|tracking|shipment|order|book|pickup|pick\s?up|address|destination|kg|kgs|dimension|dimensions|size|sizes|weight|fcl|lcl|air|sea|ddp|fob|cif|invoice|dispatch\w*|customs|clearance)\b'
    $hasBusiness = [bool]($t -match $businessPattern)

    $foreignSupplier = [bool](($t -match "(?i)\b(supplier|vendor|factory)\s*'?s?\s+(company|name|contact|details|identity)\b"))
    $foreignBuyer = [bool]($t -match '(?i)\bmy\s+(name|company|company\s+name|contact|details)\b')
    $subject = 'unknown'
    if ($intentList.Count -gt 0) { $subject = 'seller' }
    elseif ($foreignSupplier) { $subject = 'supplier' }
    elseif ($foreignBuyer) { $subject = 'buyer' }

    $place = ''
    $placeKind = 'seller'
    $placeResolved = $true
    $placeReason = 'no-time-question'
    $timeScope = ''
    $timeRequests = @()
    $timeTargets = @()
    if ($hits.ContainsKey('current_time')) {
        # [2026-10-05 F6 §7.1] 三态地点 + **逐问题、逐目标**归属：地点只在时间问句自身的范围内解析，
        #   业务句（公司/供应商/仓库/目的地）无论位于问句前后都不参与。解析不了的地点保持 explicit
        #   （绝不降级为"未指定"再默认卖家时区）。多个时间问题/多个地点全部保留，不静默丢弃第二问。
        $timeRequests = @(Get-TimeRequestList $t)
        $timeTargets = @(Get-TimeTargetList $t)
        $placeInfo = Get-TimePlaceInfo $t
        $place = [string]$placeInfo.Place
        $placeKind = [string]$placeInfo.Kind
        $placeResolved = [bool]$placeInfo.Resolved
        $placeReason = [string]$placeInfo.Reason
        $timeScope = [string]$placeInfo.Scope
        if ($timeTargets.Count -eq 0) {
            $timeTargets = @([pscustomobject]@{ RequestId = 'time-1-1'; MessageId = 'msg-1'; QuestionSpan = $null; ScopeText = $t
                PlaceRaw = ''; Place = ''; State = 'unspecified'; Kind = 'seller'; Resolved = $true
                Reason = 'no-place-named'; TimeZone = '' })
        }
    }

    $primary = ''
    if ($intentList.Count -gt 0) { $primary = [string]$intentList[0] }
    return [pscustomobject]@{
        Intents        = $intentList
        Primary        = $primary
        HasBusiness    = $hasBusiness
        Subject        = $subject
        Place          = $place
        PlaceKind      = $placeKind
        # [2026-10-05 spec §7.2 第 1 条] 保留"明确指定但解析不了"的原因与问题范围原文，
        #   供决策、受控渲染、模型上下文、重写、固定回退与发送前检查消费同一份结果。
        PlaceResolved  = $placeResolved
        PlaceReason    = $placeReason
        TimeScope      = $timeScope
        # [F6] 时间请求与目标列表：决策、受控渲染、模型上下文、重写、回退与发送前检查消费同一份。
        TimeRequests   = @($timeRequests)
        TimeTargets    = @($timeTargets)
        ForeignSubject = [bool]($foreignSupplier -or $foreignBuyer)
    }
}

# Scenario classification. Ordered by the priority required by spec 4.2:
#   safety constraints -> the current concrete request -> emotion and human requests ->
#   assistance we can actually perform -> only then the information the current stage needs.
# Returns @{ Scenario; Reasons } - the FIRST matching rule wins, so the order below IS the policy.
function Get-ReplyScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Facts,
        # The newest buyer message. Every pre-existing rule below is written against THIS, because
        # "ok", "thanks" and "any update?" are properties of the newest line.
        [string]$LatestText = '',
        # [2026-10-05 spec §4] The whole currently-unanswered run of buyer messages. Only the base
        # fact block uses it: a question that is still unanswered must be answered even when a
        # shorter line followed it. Passing it must NOT change any other rule, otherwise a merged
        # "wait it is coming ok" would stop being a short acknowledgement.
        [string]$CurrentRequest = '',
        $AskCounts = $null,
        $Conversation = $null
    )
    $lt = ''
    if ($LatestText) { $lt = $LatestText.ToLowerInvariant() }
    $factText = $LatestText
    if ($CurrentRequest) { $factText = $CurrentRequest }
    $reasons = New-Object System.Collections.ArrayList
    $buyerMsgCount = 0
    if ($Conversation) { $buyerMsgCount = [int]$Conversation.BuyerCount }

    # --- 1) Explicit human request / stop the bot. Highest priority: continuing to market after
    #        this is a trust breach and is explicitly forbidden by spec 4.2. The bare "are you a
    #        bot" question is handled separately below so it can be answered honestly instead of
    #        being swallowed by the handoff guard.
    if ($lt -match '(?i)\b(real\s+(person|human|people|agent)|actual\s+(person|human)|speak\s+to\s+(a\s+)?(human|person|someone|agent|manager)|talk\s+to\s+(a\s+)?(human|person|real)|human\s+being|stop\s+(the\s+)?(bot|robot|automation|auto)|turn\s+off\s+(the\s+)?(bot|robot|automation)|don''?t\s+reply\s+automatically|real\s+human)\b' -or
        $lt -match '(真人|人工|不要机器人|关闭机器人|别用机器人)') {
        [void]$reasons.Add('explicit human or stop-bot request')
        return @{ Scenario = 'human_requested'; Reasons = @($reasons.ToArray()) }
    }

    # --- 1b) [2026-10-05 spec §4] The current turn's base facts. Computed once here and used both
    #         to answer pure fact questions deterministically and to keep them ahead of the
    #         "history already supplied cargo data" / "early conversation" catch-alls.
    $factInfo = Get-FactIntents $factText
    if (@($factInfo.Intents) -contains 'assistant_identity') {
        [void]$reasons.Add('buyer asked whether this is a bot')
        return @{ Scenario = 'assistant_identity'; Reasons = @($reasons.ToArray()) }
    }
    if (@($factInfo.Intents).Count -gt 0 -and -not $factInfo.HasBusiness) {
        [void]$reasons.Add('base fact question for this turn: ' + (@($factInfo.Intents) -join ', '))
        return @{ Scenario = [string]$factInfo.Primary; Reasons = @($reasons.ToArray()) }
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
        'attachment_only', 'details_given', 'new_inquiry',
        'current_time', 'seller_company', 'seller_name', 'assistant_identity'
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
        [string]$ForceScenario = '',
        # [2026-10-05 spec §3/§7] Runtime facts are passed EXPLICITLY. A compatibility caller that
        # omits them degrades honestly (no identity, no clock) instead of reading global leftovers.
        $RuntimeContext = $null,
        $ActionEvidence = $null
    )

    $evidence = $ActionEvidence
    if (-not $evidence) {
        if ($RuntimeContext -and $RuntimeContext.ActionEvidence) { $evidence = $RuntimeContext.ActionEvidence }
        else { $evidence = New-ActionEvidence -Values $null }
    }

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
            Subject = 'unknown'; RequestedFacts = @(); UnresolvedFacts = @(); FactAnswers = @()
            DirectFactText = ''; FactOnly = $false; FactSource = ''; CurrentRequestText = ''
            RequestedPlace = ''; RequestedPlaceKind = ''; RequestedPlaceResolved = $true; RequestedPlaceReason = ''
            TimeQuestionScope = ''; TimeRequests = @(); TimeTargets = @(); ClarifyFields = @()
            ClarificationRequests = @()
            FactFragments = @()
            FactCompanyValue = ''; FactCompanyVerified = $false
            FactNameValue = ''; FactNameVerified = $false
            RuntimeContext = $RuntimeContext; ActionEvidence = $evidence
            OrderConfident = [bool]$Conversation.Order.Confident; OrderReason = [string]$Conversation.Order.Reason
        }
    }
    $latestText = $latest.Orig
    $currentRequest = Get-CurrentRequestText $Conversation
    if ([string]::IsNullOrWhiteSpace($currentRequest)) { $currentRequest = $latestText }
    # [F6 §7.1 第 1 条] 事实/时间目标解析用**逐条**未答消息（保留消息边界）；
    #   CurrentRequestText 仍是合并口径，展示与场景判据不变。
    $factInput = $currentRequest
    $currentRequestLines = @(Get-CurrentRequestLines $Conversation)
    if ($currentRequestLines.Count -gt 0) { $factInput = ($currentRequestLines -join [string][char]10) }
    $factInfo = Get-FactIntents $factInput
    $askCounts = Get-AskCounts $Conversation.Messages
    $promised = @(Get-PromisedFields @($Conversation.Lines))

    $scenarioInfo = $null
    if ($ForceScenario) {
        $scenarioInfo = @{ Scenario = $ForceScenario; Reasons = @('forced by caller') }
    } else {
        # Scenario classification keeps its original "newest line" input; the merged unanswered
        # request is passed separately and is used ONLY by the base-fact rule (spec §4).
        $scenarioInfo = Get-ReplyScenario -Facts $Facts -LatestText $latestText -CurrentRequest $currentRequest -AskCounts $askCounts -Conversation $Conversation
    }
    $scenario = [string]$scenarioInfo.Scenario

    # Controlled fact rendering. Answers are produced by program code from the owner config and the
    # injected clock; the model only ever words the surrounding business reply.
    $requestedFacts = @($factInfo.Intents)
    $factAnswers = @()
    $directText = ''
    $unresolvedFacts = @()
    # [spec §2/§8.3] ReplyComposition 的程序事实片段（Fact/TargetIds/Text）：发送刷新时按同一份目标
    #   列表 + 新鲜 RuntimeContext 重新渲染，再与**独立业务正文**重新组合。
    $factFragments = @()
    if ($requestedFacts.Count -gt 0) {
        $direct = Get-DirectFactReply -RequestedFacts $requestedFacts -RuntimeContext $RuntimeContext -Place $factInfo.Place -PlaceKind $factInfo.PlaceKind -PlaceResolved ([bool]$factInfo.PlaceResolved) -PlaceReason ([string]$factInfo.PlaceReason) -TimeTargets @($factInfo.TimeTargets)
        $factAnswers = @($direct.Answers)
        $directText = [string]$direct.Text
        $unresolvedFacts = @($direct.Unresolved)
        if ($direct.PSObject.Properties.Name -contains 'Fragments') { $factFragments = @($direct.Fragments) }
    }
    $sellerProfile = $null
    if ($RuntimeContext -and $RuntimeContext.SellerProfile) { $sellerProfile = $RuntimeContext.SellerProfile }
    if (-not $sellerProfile) { $sellerProfile = Get-SellerProfile -Config $null }

    $factScenarios = @('current_time', 'seller_company', 'seller_name', 'assistant_identity')
    $latestHasAttachment = [bool]($latest.HasImage -or $latest.HasFile)
    $factOnly = ($requestedFacts.Count -gt 0 -and -not $factInfo.HasBusiness -and -not $latestHasAttachment -and
                 $scenario -in $factScenarios -and -not $Conversation.Anomaly)

    # How detailed may this reply be? Simple acknowledgements get one line; a complex explanation
    # may take a few. Deliberately NOT a hard character cap (spec 4.3: do not mechanically
    # truncate to a fixed number of sentences).
    $maxSentences = 2
    if ($scenario -in @('short_ack', 'refusal', 'material_promised')) {
        $maxSentences = 1
    } elseif ($scenario -in @('current_time', 'seller_company', 'seller_name', 'assistant_identity')) {
        $maxSentences = 1
    } elseif ($scenario -in @('complaint', 'billing_explain', 'process_explain', 'packing_prep')) {
        $maxSentences = 3
    }

    # Which fields may this reply ask for? Only fields genuinely missing, not already provided and
    # not already asked to the limit. This is the ONE place the "do not re-ask" rule is applied.
    $askable = Get-AskableFields -Facts $Facts -AskCounts $askCounts -PromisedFields $promised
    # [2026-10-05 spec §3.2] The quote-necessary gaps come from the ONE fact model. They are used to
    # make sure this turn asks for something that actually gates a quote (carton count / weight /
    # dimensions / a usable destination) instead of a decorative extra.
    $readiness = $null
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'QuoteReadiness')) { $readiness = $Facts.QuoteReadiness }
    $askKeyMap = @{
        'carton_count' = 'carton_count'; 'unit_weight' = 'weight'; 'total_weight' = 'weight'
        'unit_dimensions' = 'dimension'; 'lot_dimensions' = 'dimension'
        'delivery_address' = 'address'; 'supplier_contact' = 'supplier'
        'recipient_contact' = 'recipient_contact'; 'recipient_name' = 'recipient_name'
        'reference_images' = 'image'; 'goods_name' = 'goods_name'
    }
    $quoteGapAsks = @()
    if ($readiness -and -not [bool]$readiness.Ready) {
        foreach ($mf in @($readiness.MissingFields)) {
            $k = [string]$mf
            if ($askKeyMap.ContainsKey($k)) { $k = [string]$askKeyMap[$k] }
            if ($askable -contains $k -and $quoteGapAsks -notcontains $k) { $quoteGapAsks += $k }
            if ($quoteGapAsks.Count -ge 2) { break }
        }
    }

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
            } elseif (-not $Facts.HasWeight -and $askable -contains 'weight') {
                # [2026-10-05 spec §3.2 rule 7] No supplier to verify with: keep the gap for a human but
                # allow one legitimate step-back datum. The decision must authorize exactly what the
                # approved fallback wording asks for, otherwise wording and output check drift apart.
                $askFields = @('weight')
            }
        }
        { $_ -in @('attachment_only', 'quote_ready_query') } { $askFields = @($askable | Select-Object -First 2) }
        # These scenarios do not collect cargo fields. Address clarification asks whose address;
        # acknowledgements and promises close the exchange without creating another task.
        { $_ -in @('address_clarify', 'human_requested', 'complaint', 'refusal', 'short_ack',
                   'material_promised', 'billing_explain', 'process_explain', 'delivery_status',
                   'current_time', 'seller_company', 'seller_name', 'assistant_identity') } { }
        default         { if ($askable.Count -gt 0) { $askFields = @($askable[0]) } }
    }
    # [2026-10-05 spec §3.2] If this turn asks nothing that gates a quote, ask the top quote-necessary
    # gap instead (still inside the AskFields/promised limits). Scenario wording is unchanged.
    if ($quoteGapAsks.Count -gt 0) {
        $gatesQuote = $false
        foreach ($f in @($askFields)) { if ($quoteGapAsks -contains $f) { $gatesQuote = $true; break } }
        if (-not $gatesQuote -and $scenario -notin @('human_requested', 'complaint', 'refusal', 'short_ack', 'material_promised', 'address_clarify', 'dimension_missing')) {
            $askFields = @(@($askFields) + $quoteGapAsks[0] | Select-Object -Unique)
        }
    }
    # Never ask a field the buyer already promised (belt and braces on top of Get-AskableFields).
    $askFields = @($askFields | Where-Object { $promised -notcontains $_ })
    # A pure fact/identity turn collects nothing: no cargo questionnaire, no new quotation task.
    if ($factOnly) { $askFields = @() }
    if ($Facts.Destination -and ($Facts.Destination.Kind -eq 'ambiguous' -or $Facts.Destination.AmazonContext) -and
        -not $Facts.HasQuoteDestination -and $askable -contains 'address' -and
        $scenario -in @('new_inquiry','details_given','attachment_only','attachment_parse_failed','quote_ready_query','general')) { $askFields = @('address') }

    # Does this request need a real human fact? Anything about fulfillment, money, supplier
    # handoff, an explicit human request, a complaint or an unreadable attachment does.
    $todoKind = switch ($scenario) {
        'delivery_status'      { 'fulfillment_status' }
        'quote_ready_query'    { 'quote_status' }
        'supplier_unreachable' { 'supplier_handoff' }
        # [2026-10-05 spec §3.2 第 4 条] 供应商核实是一个**闭环**：没有联系方式时任务以
        #   awaiting_contact 落盘（向客户索取联系方式），拿到联系方式后更新为 pending_human。
        #   两种情况都是同一类任务，不能因为"还没拿到联系方式"就不建单——那正是旧实现让
        #   联系计划没有任何执行证据、最终退化成让客户自己去量的根因。
        #   买家明确说没有供应商时（HasNoSupplier）才不建供应商任务。
        'dimension_missing'    { if ($Facts.HasNoSupplier) { '' } else { 'supplier_handoff' } }
        'human_requested'      { 'human_requested' }
        'complaint'            { 'complaint_review' }
        'address_clarify'      { 'address_clarify' }
        'attachment_parse_failed' { 'attachment_unreadable' }
        default                { '' }
    }
    $needTodo = [bool]$todoKind

    # A specific deadline may only be offered when THIS round really persisted a local todo,
    # really delivered a notification, and really committed a deadline. A reachable channel and the
    # boolean NeedHumanTodo are NOT execution evidence (2026-10-05 spec §6.3 / C14 / C15): this
    # build has no human-todo loop wired, so the default is false.
    $allowTimeCommitment = ([bool]$evidence.TodoPersisted -and [bool]$evidence.NotificationDelivered -and [bool]$evidence.HasDeadline)

    # After a human request, a complaint, a refusal, a bot-identity question or a pure fact turn the
    # reply must assist only - no pitching and no new cargo task.
    $allowAdvance = -not ($scenario -in @('human_requested', 'complaint', 'refusal', 'assistant_identity', 'current_time', 'seller_company', 'seller_name'))

    # [F8 §9.1 第 3/4 条] 本轮**确实被授权澄清的字段**：只有这些字段允许出现"确认单位/归属/冲突"的
    #   具体澄清句；which/whose/is this 之类的语气线索本身不构成授权。来源是结构化的：
    #     ① 决策场景本身就是在澄清某个字段（例如 address_clarify ⇒ delivery_address）；
    #     ② 唯一事实模型里处于 conflict / needs_confirmation 的字段；
    #     ③ 目的地被判定为 ambiguous（缺城市/邮编）时的 delivery_address。
    $clarifyFields = New-Object System.Collections.ArrayList
    if ($scenario -eq 'address_clarify') { [void]$clarifyFields.Add('delivery_address') }
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'CargoFacts') -and $Facts.CargoFacts -and $Facts.CargoFacts.ByKey) {
        $cfk = $Facts.CargoFacts.ByKey
        foreach ($k in @($cfk.Keys)) {
            $st = [string]$cfk[$k].Status
            if ($st -eq 'conflict' -or $st -eq 'needs_confirmation') { if (-not $clarifyFields.Contains([string]$k)) { [void]$clarifyFields.Add([string]$k) } }
        }
    }
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'Destination') -and $Facts.Destination -and [string]$Facts.Destination.Kind -eq 'ambiguous') {
        if (-not $clarifyFields.Contains('delivery_address')) { [void]$clarifyFields.Add('delivery_address') }
    }

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
        # [F8] 本轮允许澄清的字段（结构化证据；空数组 ⇒ 任何字段澄清句都按未授权处理）。
        ClarifyFields       = @($clarifyFields.ToArray())
        # [2026-10-05 第三轮 spec §7.1] 结构化澄清请求：候选/单位/范围/来源与允许问法。
        ClarificationRequests = @(Get-ReplyClarificationRequests -Facts $Facts -Decision ([pscustomobject]@{ Scenario = $scenario; ClarifyFields = @($clarifyFields.ToArray()) }))
        # [spec §2/§8.3] 程序事实片段（由程序组合器建立来源，模型不能自报）。
        FactFragments       = @($factFragments)
        LatestBuyerText     = $latestText
        Facts               = $Facts
        # ---- 2026-10-05 spec §4/§6: current-turn object and trusted-runtime facts ----
        Subject             = [string]$factInfo.Subject
        RequestedFacts      = @($requestedFacts)
        UnresolvedFacts     = @($unresolvedFacts)
        FactAnswers         = @($factAnswers)
        DirectFactText      = $directText
        FactOnly            = [bool]$factOnly
        FactSource          = $(if ($directText) { 'DIRECT_FACT' } else { '' })
        CurrentRequestText   = $currentRequest
        RequestedPlace      = [string]$factInfo.Place
        RequestedPlaceKind  = [string]$factInfo.PlaceKind
        RequestedPlaceResolved = [bool]$factInfo.PlaceResolved
        RequestedPlaceReason   = [string]$factInfo.PlaceReason
        TimeQuestionScope   = [string]$factInfo.TimeScope
        # [F6 §7.1 第 4 条] 时间请求/目标列表：生产检查消费**所有**目标，不再只校验第一处。
        TimeRequests        = @($factInfo.TimeRequests)
        TimeTargets         = @($factInfo.TimeTargets)
        FactCompanyValue    = [string]$sellerProfile.CompanyValue
        FactCompanyVerified = [bool]$sellerProfile.CompanyVerified
        FactNameValue       = [string]$sellerProfile.NameValue
        FactNameVerified    = [bool]$sellerProfile.NameVerified
        # ---- 2026-10-05 spec §3: the single cargo-fact model and quote readiness ----
        CargoFacts          = $(if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'CargoFacts')) { $Facts.CargoFacts } else { $null })
        QuoteReady          = $(if ($readiness) { [bool]$readiness.Ready } else { $false })
        QuoteMissingFields  = $(if ($readiness) { @($readiness.MissingFields) } else { @() })
        OptionalMissingFields = $(if ($readiness) { @($readiness.OptionalMissingFields) } else { @() })
        CollectionComplete  = $(if ($readiness) { [bool]$readiness.CollectionComplete } else { $false })
        Clarifications      = $(if ($readiness) { @($readiness.Clarifications) } else { @() })
        FactsRuleVersion    = $(if ($readiness) { [string]$readiness.RuleVersion } else { '' })
        RuntimeContext      = $RuntimeContext
        ActionEvidence      = $evidence
        OrderConfident      = [bool](-not $Conversation.Anomaly)
        OrderReason         = [string]$Conversation.Order.Reason
    }
}

. (Join-Path $PSScriptRoot 'time_claims.ps1')
