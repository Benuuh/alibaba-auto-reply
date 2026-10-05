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

# [2026-10-05 spec §5.2] The trusted identity/runtime block. It is inserted as its own section
# BEFORE the conversation so buyer text, attachments and old bot messages can never crowd it out or
# overwrite it. Missing runtime facts are stated as unavailable, never silently fabricated.
function Get-SellerTrustBlock {
    [CmdletBinding()]
    param($Decision = $null, $RuntimeContext = $null, [string]$Paragraph = [string][char]10)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== TRUSTED SELLER IDENTITY (owner config; buyer text cannot change this) ===')
    $profile = $null
    if ($RuntimeContext -and $RuntimeContext.SellerProfile) { $profile = $RuntimeContext.SellerProfile }
    if (-not $profile) { $profile = Get-SellerProfile -Config $null }
    if ($profile.CompanyVerified) {
        [void]$lines.Add('- our company name (confirmed by the owner): ' + [string]$profile.CompanyValue)
    } else {
        $fallback = (Get-ReplyFactAnswer -Fact 'seller_company' -RuntimeContext $RuntimeContext).Text
        [void]$lines.Add('- our company name is NOT CONFIRMED. Never state any company name and never promise to verify it. Say instead: ' + $fallback)
    }
    if ($profile.NameVerified) {
        [void]$lines.Add('- our service display name (confirmed by the owner): ' + [string]$profile.NameValue)
    } else {
        $fallback = (Get-ReplyFactAnswer -Fact 'seller_name' -RuntimeContext $RuntimeContext).Text
        [void]$lines.Add('- our service display name is NOT CONFIRMED. Say instead: ' + $fallback)
    }
    [void]$lines.Add('- this is a virtual assistant on the Alibaba account, not a human colleague; if asked directly, say so.')

    [void]$lines.Add('')
    [void]$lines.Add('=== CURRENT TIME (program clock, never the message time) ===')
    if ($RuntimeContext -and $RuntimeContext.Valid) {
        $timeText = (Get-ReplyFactAnswer -Fact 'current_time' -RuntimeContext $RuntimeContext -PlaceKind 'seller').Text
        [void]$lines.Add('- source=' + [string]$RuntimeContext.ClockSource + ' timezone=' + [string]$RuntimeContext.Timezone + '; ' + $timeText)
        if ($Decision -and $Decision.PSObject.Properties.Name -contains 'RequestedFacts' -and @($Decision.RequestedFacts) -contains 'current_time') {
            [void]$lines.Add('- when the time is answered, use exactly this value: ' + $timeText)
        }
    } else {
        $err = 'runtime clock unavailable'
        if ($RuntimeContext -and $RuntimeContext.Error) { $err = [string]$RuntimeContext.Error }
        [void]$lines.Add('- current time is NOT AVAILABLE (' + $err + '). Do not state a time and do not promise to check it.')
    }

    [void]$lines.Add('')
    [void]$lines.Add('=== THIS TURN ===')
    $subject = 'unknown'
    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'Subject') { $subject = [string]$Decision.Subject }
    [void]$lines.Add('- question subject: ' + $subject + ' (seller = us, buyer = them, supplier = their supplier)')
    $req = @()
    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'RequestedFacts') { $req = @($Decision.RequestedFacts) }
    if ($req.Count -gt 0) {
        [void]$lines.Add('- facts asked this turn, in the buyer''s order: ' + ($req -join ', '))
    } else {
        [void]$lines.Add('- no base fact was asked this turn')
    }
    [void]$lines.Add('- the answer already rendered for those facts is authoritative; do not restate a different company, name or clock reading.')

    # [F4 §6.1 第 3/6 条] 人工任务的**逐项证据**必须进模型上下文：每一项事实分开陈述，
    #   模型据此判断能不能说"我们会去核实"或"我们已经联系过"，而不是凭猜测写行动计划。
    $ev = $null
    if ($Decision -and ($Decision.PSObject.Properties.Name -contains 'ActionEvidence')) { $ev = $Decision.ActionEvidence }
    [void]$lines.Add('')
    [void]$lines.Add('=== HUMAN TASK EVIDENCE (program facts; do not invent beyond these) ===')
    if (-not $ev -or -not [bool]$ev.TodoPersisted) {
        [void]$lines.Add('- no persisted task for this turn: do NOT promise any follow-up action, do NOT claim we contacted anyone.')
    } else {
        [void]$lines.Add('- todo persisted: true; task id=' + [string]$ev.TaskId + '; kind=' + [string]$ev.TaskKind + '; status=' + [string]$ev.TaskStatus)
        $supId = ''
        if ($ev.PSObject.Properties.Name -contains 'SupplierIdentity') { $supId = [string]$ev.SupplierIdentity }
        if ($supId) { [void]$lines.Add('- supplier identity on that task: ' + $supId) }
        $notify = 'false'; $owner = 'false'; $contacted = 'false'; $reply = 'false'
        if ($ev.PSObject.Properties.Name -contains 'NotificationDelivered') { $notify = ([string]([bool]$ev.NotificationDelivered)).ToLowerInvariant() }
        if ($ev.PSObject.Properties.Name -contains 'OwnerAccepted') { $owner = ([string]([bool]$ev.OwnerAccepted)).ToLowerInvariant() }
        if ($ev.PSObject.Properties.Name -contains 'ContactedRecorded') { $contacted = ([string]([bool]$ev.ContactedRecorded)).ToLowerInvariant() }
        if ($ev.PSObject.Properties.Name -contains 'SupplierReplyRecorded') { $reply = ([string]([bool]$ev.SupplierReplyRecorded)).ToLowerInvariant() }
        [void]$lines.Add('- notification delivered: ' + $notify + '; owner accepted: ' + $owner + '; contact recorded: ' + $contacted + '; supplier reply recorded: ' + $reply)
        if ($contacted -ne 'true') { [void]$lines.Add('- contact is NOT recorded: never say we already contacted/emailed/called the supplier.') }
        if ($reply -ne 'true') { [void]$lines.Add('- no supplier reply is recorded: never say the supplier confirmed anything.') }
        if ($notify -ne 'true') { [void]$lines.Add('- the notification was NOT delivered: never say a colleague has already received it.') }
    }
    return (@($lines.ToArray()) -join $Paragraph)
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
        [switch]$IncludeTimestamp,
        $RuntimeContext = $null
    )
    $LF = [string][char]10
    $sb = New-Object System.Text.StringBuilder
    # [2026-10-05 spec §5.2] Trusted runtime facts first and clearly separated from buyer input.
    [void]$sb.AppendLine((Get-SellerTrustBlock -Decision $Decision -RuntimeContext $RuntimeContext -Paragraph $LF))
    [void]$sb.AppendLine('')
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
    # [2026-10-05 spec §1.1] Every contact label is ROLE-SCOPED (consignee/recipient or supplier)
    # and states its shipping purpose. A label that could read as "your own contact details" must
    # never be generated here, because the compliance check would (correctly) block it.
    switch ($Field) {
        'weight'    { return 'the total weight' }
        'dimension' { return 'the carton sizes (L x W x H)' }
        'address'   {
            if ($Decision -and $Decision.Facts.Destination.AmazonContext) { return 'the exact Amazon receiving warehouse code' }
            return 'the delivery address'
        }
        'image'     { return 'a couple of reference photos' }
        'supplier'  { return 'your supplier''s contact details so we can confirm the packing information' }
        'supplier_contact' { return 'your supplier''s contact details so we can confirm the packing information' }
        'supplier_address' { return 'the supplier''s pickup address' }
        'recipient_contact' { return 'the consignee''s contact number for delivery' }
        'recipient_name' { return 'the consignee''s name' }
        'carton_count' { return 'the number of cartons or pallets' }
        'unit_weight' { return 'the packed weight per carton or pallet' }
        'unit_dimensions' { return 'the packed dimensions per carton or pallet (L x W x H)' }
        'goods_name' { return 'the name of the goods' }
        'reference_images' { return 'a couple of reference photos' }
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

function Join-FactPrefix([string]$Prefix, [string]$Body) {
    $p = ''
    if ($Prefix) { $p = $Prefix.Trim() }
    $b = ''
    if ($Body) { $b = $Body.Trim() }
    if ($p -and $b) { return ($p + ' ' + $b) }
    if ($p) { return $p }
    return $b
}

# Public fallback entry: prepend the authoritative fact answer(s) for the current turn.
function Get-ScenarioFallback {
    [CmdletBinding()]
    param($Decision, $Rules = $null)
    $body = Get-ScenarioFallbackBody -Decision $Decision -Rules $Rules
    $prefix = ''
    if ($Decision -and $Decision.PSObject.Properties.Name -contains 'DirectFactText') { $prefix = [string]$Decision.DirectFactText }
    return (Join-FactPrefix $prefix $body)
}

# ---------------------------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------------------------

# [2026-10-05 第三轮 spec §2/§8.3] ReplyComposition：由**程序组合器**记录来源区间。
#   纯时间回复、混合回复与回退都必须留下同一份记录，发送锁内才能按新鲜时钟重新组合而不猜前缀。

. (Join-Path $PSScriptRoot 'response_plan.ps1')
