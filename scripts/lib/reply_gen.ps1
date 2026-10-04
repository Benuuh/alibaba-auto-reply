# lib\reply_gen.ps1 - Reply generation: compact context, ONE model call, ONE bounded rewrite.
#
# RESPONSIBILITY (spec 5, item 3): assemble a slim context, call the model once, allow at most one
# budgeted rewrite, or use the scenario fallback. No path may re-implement a different business
# policy: everything here consumes the decision object produced by lib\reply_policy.ps1, and every
# candidate reply is checked by Test-ReplyCompliance before it may leave this file.
#
# EFFICIENCY CONTRACT (spec 6):
#   - Exactly ONE model call for the normal path.
#   - At most ONE rewrite, and it SHARES the remaining round budget instead of starting a fresh
#     timer. The old code could start a separate rewrite for banned words and another for
#     liability wording; both are now one pass driven by the full violation list.
#   - The context is chronological (oldest first) and trimming removes the MIDDLE, so the newest
#     messages, the confirmed facts and the open items can never be pushed out by truncation.
#   - No attachment work happens here. Callers only pass image/document material when the decision
#     actually involves an attachment.

if (-not (Get-Command Test-ReplyCompliance -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'reply_policy.ps1')
}

# ---------------------------------------------------------------------------------------------
# Context assembly
# ---------------------------------------------------------------------------------------------

# Evidence-class labels required by spec 4.2: buyer statement, human confirmation, what we already
# told the buyer, and unknown. The model must be able to tell these apart, otherwise it cannot know
# which "facts" it is allowed to rely on.
function Get-FactEvidenceTable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Conversation)

    $fields = @(
        @{ Key = 'weight';    Label = 'total weight (kg)'; Pattern = '\d+\s*(kg|kgs|kilo|kilos)\b|\d+\s*(公斤|千克)|weight\s*[:=]?\s*\d|peso\s*[:=]?\s*\d' },
        @{ Key = 'dimension'; Label = 'packaging dimensions (L*W*H)'; Pattern = '\d+\s*[x\u00d7*]\s*\d+|\d+(\.\d+)?\s*(cm|mm)\s*[x\u00d7*]|dimension|尺寸|medidas' },
        @{ Key = 'quantity';  Label = 'cartons / pieces'; Pattern = '\d+\s*(pcs|pieces|cartons|ctns|boxes|units)\b|\d+\s*(件|箱)' },
        @{ Key = 'supplier';  Label = 'supplier contact'; Pattern = 'supplier|vendor|factory|proveedor|fornecedor|供应商' },
        @{ Key = 'mode';      Label = 'shipping mode'; Pattern = 'by sea|by air|ocean|air freight|\bfcl\b|\blcl\b|shipping method|transport' }
    )

    $rows = New-Object System.Collections.ArrayList
    foreach ($f in $fields) {
        $state = 'unknown'
        $evidence = ''
        $buyerHit = $false; $humanHit = $false; $botHit = $false
        foreach ($m in @($Conversation.Messages)) {
            if (-not $m -or $m.IsSystemCard) { continue }
            if ($m.Orig -notmatch ('(?i)' + $f.Pattern)) { continue }
            if ($m.Role -eq 'buyer') { $buyerHit = $true }
            elseif ($m.Source -eq 'human') { $humanHit = $true }
            elseif ($m.Source -eq 'bot') { $botHit = $true }
        }
        if ($buyerHit) { $state = 'provided'; $evidence = 'buyer statement in this conversation' }
        elseif ($humanHit) { $state = 'provided'; $evidence = 'owner replied directly in this chat' }
        elseif ($botHit) { $state = 'unconfirmed'; $evidence = 'we mentioned it; not confirmed by the buyer' }
        [void]$rows.Add(@{ Field = $f.Key; Label = $f.Label; State = $state; Evidence = $evidence })
    }
    $dest = Get-QuoteDestination $Conversation
    $destState = if ($dest.QuoteUsable) { $dest.DisplayName + ' (' + $dest.Source + ' provided)' } else { $dest.Kind }
    [void]$rows.Add(@{ Field = 'address'; Label = 'quote destination'; State = $destState; Evidence = $dest.Reason + '; ' + ((@($dest.Evidence | ForEach-Object { $_.Text })) -join ' | ') })
    $postalState = 'unknown'
    if ($dest.HasPostalAddress) { $postalState = 'provided' }
    elseif ($dest.QuoteUsable -and $dest.Kind -eq 'amazon_warehouse') { $postalState = 'unknown; not required for warehouse quote preparation' }
    [void]$rows.Add(@{ Field = 'postal_address'; Label = 'street address'; State = $postalState; Evidence = $dest.Source })
    return @($rows.ToArray())
}

# Build the compact, chronological context block handed to the model.
#
# Trimming rule (spec 6): the newest messages, the current buyer message, the confirmed facts and
# the open items are mandatory. Older history is added newest-first until the character budget runs
# out, then an elision marker is placed BETWEEN the head and the tail. Nothing mandatory is ever
# dropped, and an empty result is impossible as long as there is a current buyer message.
function New-ReplyContextBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        [Parameter(Mandatory = $true)]$Decision,
        [int]$MaxChars = 6000,
        [int]$KeepTail = 8,
        [switch]$IncludeTimestamp
    )
    $LF = [string][char]10
    $sb = New-Object System.Text.StringBuilder
    if ($Decision.OrderConfident) {
        [void]$sb.AppendLine('=== CONVERSATION (oldest first, newest last) ===')
    } else {
        [void]$sb.AppendLine('=== CONVERSATION (order unverified; do not reply) ===')
    }

    $msgs = @($Conversation.Messages | Where-Object { -not $_.IsSystemCard })
    $tailCount = [Math]::Min($KeepTail, $msgs.Count)
    $tail = @()
    if ($tailCount -gt 0) { $tail = @($msgs[($msgs.Count - $tailCount)..($msgs.Count - 1)]) }
    $headBudget = $MaxChars - (($tail | ForEach-Object { $_.Text.Length }) | Measure-Object -Sum).Sum
    if ($headBudget -lt 0) { $headBudget = 0 }

    $head = New-Object System.Collections.ArrayList
    $used = 0
    for ($i = 0; $i -lt ($msgs.Count - $tailCount); $i++) {
        $m = $msgs[$i]
        $cost = $m.Text.Length + 12
        if (($used + $cost) -gt $headBudget) { break }
        [void]$head.Add($m)
        $used += $cost
    }

    foreach ($m in $head.ToArray()) {
        $tag = '[ME] '
        if ($m.Role -eq 'buyer') { $tag = '[BUYER] ' }
        elseif ($m.Source -eq 'human') { $tag = '[ME-OWNER] ' }
        $ts = ''
        if ($IncludeTimestamp -and $m.MessageTsRaw) { $ts = ' (' + $m.MessageTsRaw + ')' }
        [void]$sb.AppendLine($tag + $m.Text + $ts)
    }
    $elided = $msgs.Count - $tailCount - $head.Count
    if ($elided -gt 0) { [void]$sb.AppendLine('... [' + $elided + ' older message(s) omitted] ...') }
    foreach ($m in $tail) {
        $tag = '[ME] '
        if ($m.Role -eq 'buyer') { $tag = '[BUYER] ' }
        elseif ($m.Source -eq 'human') { $tag = '[ME-OWNER] ' }
        $ts = ''
        if ($IncludeTimestamp -and $m.MessageTsRaw) { $ts = ' (' + $m.MessageTsRaw + ')' }
        [void]$sb.AppendLine($tag + $m.Text + $ts)
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== CURRENT BUYER MESSAGE ===')
    $latestText = '(no buyer message found)'
    if ($Decision.LatestBuyerText) { $latestText = $Decision.LatestBuyerText }
    [void]$sb.AppendLine($latestText)

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== FACTS AND THEIR EVIDENCE ===')
    foreach ($row in (Get-FactEvidenceTable $Conversation)) {
        [void]$sb.AppendLine('- ' + $row.Label + ': ' + $row.State + ' [' + $row.Evidence + ']')
    }

    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== OPEN ITEMS ===')
    [void]$sb.AppendLine('- scenario: ' + $Decision.Scenario)
    if ($Decision.Facts.Destination.QuoteUsable -and $Decision.Facts.Destination.Kind -eq 'amazon_warehouse') {
        [void]$sb.AppendLine('- Use the confirmed Amazon warehouse for quote preparation. Do not ask again for address, city, state, zip/postal details, destination or warehouse code. Do not invent its full address or a price.')
    } elseif ($Decision.Facts.Destination.AmazonContext) {
        [void]$sb.AppendLine('- address means the exact Amazon receiving warehouse code; ask for that code or a single warehouse choice, not a street address.')
    }
    if ($Decision.AskFields.Count -gt 0) {
        [void]$sb.AppendLine('- you may ask about: ' + ($Decision.AskFields -join ', '))
    } else {
        [void]$sb.AppendLine('- do NOT ask for any cargo information in this reply')
    }
    if ($Decision.PromisedFields.Count -gt 0) {
        [void]$sb.AppendLine('- the buyer already promised: ' + ($Decision.PromisedFields -join ', ') + ' -> confirm only, never re-ask')
    }
    $askedParts = @()
    foreach ($k in @('weight', 'dimension', 'address', 'image', 'supplier')) {
        if ($Decision.AskCounts.ContainsKey($k) -and [int]$Decision.AskCounts[$k] -gt 0) { $askedParts += ($k + ' x' + $Decision.AskCounts[$k]) }
    }
    if ($askedParts.Count -gt 0) {
        [void]$sb.AppendLine('- questions we already asked: ' + ($askedParts -join ', ') + ' (limit 2 per field)')
    }
    if ($Decision.NeedHumanTodo) {
        [void]$sb.AppendLine('- this request needs a real human fact; you must not invent one')
    }
    if ($Decision.AllowTimeCommitment) {
        [void]$sb.AppendLine('- a specific deadline is allowed: this request is being logged and the owner is being notified')
    } else {
        [void]$sb.AppendLine('- do NOT promise a specific deadline for this reply')
    }
    if (-not $Decision.OrderConfident) {
        [void]$sb.AppendLine('- WARNING: message order could not be verified (' + $Decision.OrderReason + '); do not generate or send a reply')
    }

    return $sb.ToString()
}

# ---------------------------------------------------------------------------------------------
# Reviewed scenario guidance (reply_scenarios.md) - loaded per matched scenario, never in full.
# This replaces the old fake load: reply_agent_prompt.md used to mention reply_playbook.md by
# filename, which gave the model nothing at all because the file body was never sent.
# ---------------------------------------------------------------------------------------------
$script:__scenarioCache = $null
$script:__scenarioCacheTime = $null

function Get-ScenarioGuidance {
    [CmdletBinding()]
    param([string]$Path, [string]$Key)
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    if ([string]::IsNullOrWhiteSpace($Key)) { return '' }
    try {
        $ft = (Get-Item $Path).LastWriteTimeUtc.Ticks
        if (-not $script:__scenarioCache -or $script:__scenarioCacheTime -ne $ft) {
            $script:__scenarioCache = Get-Content $Path -Raw -Encoding UTF8
            $script:__scenarioCacheTime = $ft
        }
        $raw = $script:__scenarioCache
    } catch { return '' }
    if (-not $raw) { return '' }

    # Sections are delimited by '## <key>' headings (optionally with a trailing title).
    $pattern = '(?ms)^##\s+' + [regex]::Escape($Key) + '\s*$(.*?)(?=^##\s+|\z)'
    $m = [regex]::Match($raw, $pattern)
    if (-not $m.Success) { return '' }
    return $m.Groups[1].Value.Trim()
}

# ---------------------------------------------------------------------------------------------
# System prompt (slim, mtime-invalidated cache)
# ---------------------------------------------------------------------------------------------
$script:__sysPromptCache = $null
$script:__sysPromptCacheTime = $null

function Get-ReplySystemPrompt {
    [CmdletBinding()]
    param([string]$Path)
    if ($Path -and (Test-Path $Path)) {
        try {
            $ft = (Get-Item $Path).LastWriteTimeUtc.Ticks
            if ($script:__sysPromptCache -and $script:__sysPromptCacheTime -eq $ft) { return $script:__sysPromptCache }
            $script:__sysPromptCache = Get-Content $Path -Raw -Encoding UTF8
            $script:__sysPromptCacheTime = $ft
            return $script:__sysPromptCache
        } catch { }
    }
    if ($script:__sysPromptCache) { return $script:__sysPromptCache }
    return 'You are a concise, warm logistics assistant replying to Alibaba.com buyers. Always answer in American English. Keep it short and human.'
}

# ---------------------------------------------------------------------------------------------
# Scenario fallbacks - the single source of the words used when the model is unavailable or its
# output cannot be made compliant. American English only, no prices, no contact exchange, no
# liability, no invented facts and no unsupported promises, so they pass Test-ReplyCompliance.
# ---------------------------------------------------------------------------------------------
# Human-readable label for an askable field key. Single definition so every fallback that lists
# fields reads like a person wrote it instead of leaking internal keys.
function Get-AskFieldLabel([string]$Field, $Decision = $null) {
    switch ($Field) {
        'weight'    { return 'the total weight' }
        'dimension' { return 'the carton sizes (L x W x H)' }
        'address'   {
            if ($Decision -and $Decision.Facts.Destination.AmazonContext) { return 'the exact Amazon receiving warehouse code' }
            return 'the delivery address'
        }
        'image'     { return 'a couple of reference photos' }
        'supplier'  { return 'your supplier''s contact' }
        default     { return [string]$Field }
    }
}

# Join field keys into a natural English list: "a, b and c".
function Join-AskFieldLabels([string[]]$Fields, $Decision = $null) {
    $labels = @(@($Fields) | ForEach-Object { Get-AskFieldLabel $_ $Decision })
    if ($labels.Count -eq 0) { return '' }
    if ($labels.Count -eq 1) { return $labels[0] }
    if ($labels.Count -eq 2) { return ($labels[0] + ' and ' + $labels[1]) }
    return ((@($labels[0..($labels.Count - 2)]) -join ', ') + ' and ' + $labels[$labels.Count - 1])
}

function Get-ScenarioFallback {
    [CmdletBinding()]
    param($Decision, $Rules = $null)

    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'CanReply' -and -not $Decision.CanReply) { return '' }

    $scenario = 'general'
    if ($Decision -and $Decision.Scenario) { $scenario = [string]$Decision.Scenario }
    $withDeadline = [bool]($Decision -and $Decision.AllowTimeCommitment)
    $dest = $null
    if ($Decision -and $Decision.Facts) { $dest = $Decision.Facts.Destination }
    if ($dest -and $dest.Kind -eq 'ambiguous' -and $Decision.AskFields -contains 'address') {
        if ($dest.AmazonContext -and -not $dest.HasPostalAddress) { return 'Which Amazon warehouse should I quote for?' }
        return 'Which delivery destination should I quote for?'
    }

    switch ($scenario) {
        'human_requested' {
            # Deliberately does NOT claim the handoff already happened. Spec 4.4 makes "local todo
            # created", "notification succeeded" and "business request completed" three different
            # states, and only a successful notification may be described as "passed on". This text
            # is generated BEFORE the notification attempt, so it commits to an action the system
            # really does take (create the local todo and notify) instead of reporting a result it
            # cannot yet know.
            return "Understood - I will get a person on this. I am passing it to the team now so they can take it from here."
        }
        'complaint' {
            if ($withDeadline) { return "I am sorry about this, and I understand why you are frustrated. I am checking the actual status right now and will come back to you with a clear answer by tomorrow morning." }
            return "I am sorry about this, and I understand why you are frustrated. I am checking the actual status right now, and I will come back to you as soon as I have something concrete."
        }
        'delivery_status' {
            if ($withDeadline) { return "Thanks for checking in. I do not want to give you a guess, so I am confirming the current status with the warehouse and will come back to you by tomorrow morning." }
            return "Thanks for checking in. I do not want to give you a guess, so I am confirming the current status and will come back to you as soon as I have it."
        }
        'quote_ready_query' {
            if ($withDeadline) { return "I am still working on your rate and I do not want to send you a rough number. I will have it for you by tomorrow morning." }
            return "I am still working on your rate and I do not want to send you a rough number. I will come back to you as soon as it is ready."
        }
        'supplier_unreachable' {
            return "That is frustrating, and I do not want to leave you stuck. I am having this checked from our side so it does not sit with you."
        }
        'dimension_missing' {
            # The wording is NOT restated here: it is read from the single owner-approved definition
            # in reply_engine.ps1::Get-DimensionGuidance so the two can never drift apart.
            $g = Get-DimensionGuidance
            $noSupplier = $false
            if ($Decision -and $Decision.Facts) { $noSupplier = [bool]$Decision.Facts.HasNoSupplier }
            if (-not $noSupplier) {
                $mayAskSupplier = ($Decision -and ($Decision.AskFields -contains 'supplier'))
                if ($mayAskSupplier) { return [string]$g.primary }
                # We already asked for the supplier's contact the maximum number of times. Asking a
                # third time is nagging (spec 4.3), so step back to the approved fallback wording
                # instead of repeating the ask. Still read from Get-DimensionGuidance, so there is
                # one definition of these sentences.
                return [string](@($g.fallbacks)[1].text)
            }
            # Buyer has no supplier at all: keep the approved "we do not strictly need the supplier
            # contact" sentence, minus the dimensions clause the buyer has just said they cannot give.
            $destinationAsk = ''
            if ($Decision.AskableFields -contains 'address') { $destinationAsk = ', and ' + (Get-AskFieldLabel 'address' $Decision) }
            return "No problem at all - we do not strictly need the supplier's contact. Just tell me what you are shipping, roughly how much it weighs$destinationAsk, and I will take it from there."
        }
        'address_clarify' {
            return "Happy to help with the address. Just so I get this right - is this the pickup address for the cargo, or the address it should be delivered to?"
        }
        'material_promised' {
            return "Sounds good, no rush at all. Send them over whenever they are ready and I will take it from there."
        }
        'billing_explain' {
            if ($Rules -and $Rules.pricing -and $Rules.pricing.billing_rule) { return [string]$Rules.pricing.billing_rule }
            return "The chargeable weight is the higher of the actual gross weight and the volumetric weight, so accurate weight and dimensions are what keep the rate competitive."
        }
        'process_explain' {
            if ($Rules -and $Rules.templates -and $Rules.templates.process_overview) { return [string]$Rules.templates.process_overview }
            return "It is straightforward: your supplier delivers the cargo to our warehouse in China, we confirm the details and issue the invoice, you pay, and then we book the space and ship it door to door."
        }
        'packing_prep' {
            return "For packing, the main things are a clean carton size, a packing list that matches what actually ships, and labels that match the invoice. If you send me the carton sizes I can check them against what we need."
        }
        'refusal' {
            return "No problem at all - thanks for letting me know. If anything changes, I am here."
        }
        'short_ack' {
            return "Got it, thanks. I will keep an eye on this and let you know if anything needs you."
        }
        'attachment_only' {
            return "Thanks for the images. I am looking at them now - if the carton sizes or the total weight are handy, send them over and I can price this accurately."
        }
        'attachment_parse_failed' {
            if ($Decision -and $Decision.Facts.Destination) {
                if ($Decision.AskFields.Count -gt 0) { return 'I could not open the attachment. Could you share ' + (Join-AskFieldLabels $Decision.AskFields $Decision) + '?' }
                return 'I could not open the attachment. Please paste any missing cargo details in the message.'
            }
            return "Thanks for sending that. I could not open it properly on my side, so could you tell me the key details in the message instead - weight, carton sizes and the delivery address?"
        }
        'details_given' {
            if ($Decision -and $Decision.AskFields.Count -gt 0) {
                return "Thanks, I have noted those details. To finish the rate I just need " + (Join-AskFieldLabels $Decision.AskFields $Decision) + "."
            }
            return "Thanks, I have all of that noted. I am working on the rate now and will come back to you with the exact figure."
        }
        'new_inquiry' {
            if ($Decision -and $Decision.AskFields.Count -gt 0) {
                return "Happy to help with this. To price it accurately, could you share " + (Join-AskFieldLabels $Decision.AskFields $Decision) + "?"
            }
            return "Happy to help with this. Could you tell me a bit more about the cargo and where it needs to go?"
        }
        default {
            if ($withDeadline) { return "Thanks for your message. I am looking into this and will come back to you by tomorrow morning." }
            return "Thanks for your message. I am looking into this and will get back to you as soon as I can."
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------------------------

# Generate one compliant reply.
# Returns @{ Text; Source; ModelCalls; Rewrites; Violations; FallbackReason }.
#   Source = 'LLM' | 'LLM_REWRITE' | 'FALLBACK'
# Contract: at most ONE rewrite. The rewrite is driven by the whole violation list, so banned-word
# and liability problems are fixed in a single extra call rather than one call each.
function Invoke-ReplyGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        [Parameter(Mandatory = $true)]$Decision,
        $Rules = $null,
        [string]$PromptPath,
        [string]$ScenarioPath,
        [string]$LogFile,
        [string[]]$ImageDataUrls = $null,
        [string]$AttachmentText = '',
        [int]$MaxRewrites = 1,
        [double]$Temperature = 0.7,
        [int]$MaxTokens = 400
    )
    $result = [ordered]@{
        Text = ''; Source = 'NONE'; ModelCalls = 0; Rewrites = 0
        Violations = @(); FallbackReason = ''; ContextChars = 0; AttachmentNote = ''
    }
    $MaxRewrites = [Math]::Min(1, [Math]::Max(0, $MaxRewrites))

    if ($Conversation.Anomaly -or -not $Conversation.LatestBuyer -or $Conversation.LatestBuyer.IsSystemCard -or
        -not $Decision.CanReply -or $Decision.LatestBuyerText -ne $Conversation.LatestBuyer.Orig) {
        $result.Source = 'BLOCKED'
        $result.FallbackReason = 'unverified-reply-input'
        return [pscustomobject]$result
    }

    $systemPrompt = Get-ReplySystemPrompt $PromptPath
    $guidance = ''
    if ($ScenarioPath) { $guidance = Get-ScenarioGuidance -Path $ScenarioPath -Key $Decision.GuidanceKey }

    # Only the matched scenario's examples are injected, and only for this request. This is the
    # difference between "the prompt names a manual" and "the manual is actually sent".
    $system = $systemPrompt
    if ($guidance) {
        $system += ([string][char]10) + ([string][char]10) + '=== REVIEWED EXAMPLES FOR THIS SITUATION (' + $Decision.Scenario + ') ===' + ([string][char]10) + $guidance
    }

    $context = New-ReplyContextBlock -Conversation $Conversation -Decision $Decision
    $result.ContextChars = $context.Length
    $user = $context
    if ($AttachmentText) { $user += ([string][char]10) + ([string][char]10) + '[ATTACHMENT CONTENT]' + ([string][char]10) + $AttachmentText }

    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
        $result.Text = Get-ScenarioFallback -Decision $Decision -Rules $Rules
        $result.Source = 'FALLBACK'
        $result.FallbackReason = 'llm-unavailable'
        if (-not (Test-ReplyCompliance -Text $result.Text -Rules $Rules -Decision $Decision).Ok) { $result.Text = ''; $result.Source = 'BLOCKED' }
        return [pscustomobject]$result
    }

    # Multimodal: when the caller actually downloaded images, the user turn must be built from
    # content parts. New-VisionContentParts lives in lib\vision.ps1 (loaded by monitor). If it is not
    # available - a standalone test load - the reply still goes out as text, but the degradation is
    # recorded instead of the buyer's images being dropped without a trace.
    $userContent = $user
    if ($ImageDataUrls -and @($ImageDataUrls).Count -gt 0) {
        if (Get-Command New-VisionContentParts -ErrorAction SilentlyContinue) {
            $userContent = @(New-VisionContentParts $ImageDataUrls $user)
        } else {
            $result.AttachmentNote = 'vision-helper-missing: images not attached'
        }
    }
    $messages = @(
        @{ role = 'system'; content = $system },
        @{ role = 'user'; content = $userContent }
    )
    $text = Invoke-LLM $messages $Temperature $MaxTokens $LogFile
    if ($text) { $result.ModelCalls++ }

    $rewrites = 0
    $violations = @()
    if ($text) {
        $check = Test-ReplyCompliance -Text $text -Rules $Rules -Decision $Decision
        $violations = @($check.Violations)
        while ((-not $check.Ok) -and $rewrites -lt $MaxRewrites) {
            $rewrites++
            $blocked = @($check.Violations | Where-Object { $_.Severity -eq 'block' })
            $hints = @($blocked | ForEach-Object { '- ' + $_.Code + ': ' + $_.Detail }) -join ([string][char]10)
            $retrySystem = $system + ([string][char]10) + ([string][char]10) +
                '=== REWRITE REQUIRED ===' + ([string][char]10) +
                'Your previous draft was rejected by the send-time policy check. Rewrite the reply so that ALL of the following are fixed. Keep the same intent, keep it short, and reply in American English only.' + ([string][char]10) + $hints
            $retryMessages = @(
                @{ role = 'system'; content = $retrySystem },
                @{ role = 'user'; content = $user }
            )
            $retry = Invoke-LLM $retryMessages $Temperature $MaxTokens $LogFile
            if ($retry) { $result.ModelCalls++ } else { break }
            $text = $retry
            $check = Test-ReplyCompliance -Text $text -Rules $Rules -Decision $Decision
            $violations = @($check.Violations)
        }
        if ($check.Ok) {
            $result.Text = $text
            if ($rewrites -gt 0) { $result.Source = 'LLM_REWRITE' } else { $result.Source = 'LLM' }
        }
    }

    if (-not $result.Text) {
        $result.Text = Get-ScenarioFallback -Decision $Decision -Rules $Rules
        $result.Source = 'FALLBACK'
        if ($violations.Count -gt 0) {
            $result.FallbackReason = 'policy-violation'
        } elseif ($text) {
            $result.FallbackReason = 'rewrite-exhausted'
        } else {
            $result.FallbackReason = 'llm-failed'
        }
        # The fallback itself must satisfy the same policy, otherwise we would ship a violation.
        $fbCheck = Test-ReplyCompliance -Text $result.Text -Rules $Rules -Decision $Decision
        if (-not $fbCheck.Ok) {
            $codes = @($fbCheck.Violations | ForEach-Object { $_.Code }) -join ','
            $result.FallbackReason += '|fallback-noncompliant:' + $codes
            $result.Text = ''
            $result.Source = 'BLOCKED'
        }
    }

    $result.Rewrites = $rewrites
    $result.Violations = $violations
    return [pscustomobject]$result
}
