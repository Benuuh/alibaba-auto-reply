# lib\msg_norm.ps1 - Single authority for message normalization, ordering and identity.
#
# WHY THIS FILE EXISTS (spec 4.1 / 6, evidence 2026-10-03):
#   1) ORDER WAS UNDEFINED. The extractor returned raw DOM order and said so ("keep DOM order"),
#      but three consumers disagreed about which end is newest:
#        - lib\msg_source.ps1::Test-HumanInterjection scans from the TAIL and calls it "our tail"
#          => tail = newest. That gate was built against 1812 real messages, so it is the strongest
#          evidence available, and it is the SAFETY gate (anti-interjection).
#        - scripts\monitor.ps1 used $buyerMsgs[count-1] as "the last buyer message" for the
#          should-reply hash (tail = newest).
#        - scripts\monitor.ps1 used $rawBuyerLines[0] to attach images/files, and
#          reply_agent_prompt.md claimed "the first line is the newest" (head = newest).  <-- BUG
#      A chat panel renders oldest at the top, so tail = newest is correct and the two head-based
#      consumers were wrong. This file makes the direction EXPLICIT, VERIFIES it against the
#      per-message showTime that the page already exposes, normalizes everything to chronological
#      ASCENDING (oldest first, newest last), and raises an explicit uncertainty flag instead of
#      guessing when the evidence contradicts itself (spec 4.1: "rolling, window truncation,
#      reordering, uncertain identity => enter an explicit abnormal state, do not guess from
#      changing timestamps").
#   2) SHORT MESSAGES WERE DROPPED. The page JS skipped any message whose cleaned text was
#      <= 2 characters unless it carried an image, so "ok", "si", "no" never became message
#      events - even though spec 4.1 requires text, short acknowledgements, refusals, complaints,
#      images and documents to ALL be able to form a new-message event. The only length-ish filter
#      now lives here, and it keeps every non-empty message; anything skipped is recorded with a
#      reason so nothing disappears silently.
#
# CONTRACT: this is the only place that turns raw extracted lines into message objects, decides
# message order, and assigns message identity. Other files must not re-derive order or identity.
# The output schema version is reported by Get-MsgSchemaVersion; bump it on any shape change.
#
# Dependency: reply_engine.ps1 (Get-NormalizedMsgText, Get-StableHash, ConvertTo-EpochMs).
# Dot-sourced defensively so this file can also be loaded standalone by tests.

if (-not (Get-Command Get-NormalizedMsgText -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'reply_engine.ps1')
}

# Structured message schema version. Bump on any field change to the message object.
$script:MsgSchemaVersion = 2

function Get-MsgSchemaVersion { return $script:MsgSchemaVersion }

# Strip @@TS / @@OT transport markers plus attachment markers from a raw line, returning the
# human-readable text. Markers are transport metadata, never message content.
function Get-MsgPlainText([string]$line) {
    if ([string]::IsNullOrEmpty($line)) { return '' }
    $t = $line -replace '^\[(BUYER|ME)\]\s*', ''
    $t = $t -replace '@@IMG:[^\s]*', ''
    $t = $t -replace '@@FILE:[^\s]*', ''
    $t = $t -replace '@@TS:[^\s]*', ''
    $t = $t -replace '@@OT:[A-Za-z0-9\+/=]+', ''
    return $t.Trim()
}

# Decode the @@OT original-text marker (base64 UTF-8). Falls back to the plain text when the
# marker is absent or corrupt, so identity never depends on a marker being present.
function Get-MsgOriginalText([string]$line) {
    $plain = Get-MsgPlainText $line
    $m = [regex]::Match([string]$line, '@@OT:([A-Za-z0-9\+/=]+)')
    if (-not $m.Success) { return $plain }
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
        if (-not [string]::IsNullOrWhiteSpace($decoded)) { return $decoded.Trim() }
    } catch { }
    return $plain
}

# Parse one raw extracted line into a structured message object.
# -DomIndex preserves the extractor's original position so ordering can be re-derived and audited.
# .RawLine keeps the line byte-for-byte so reordering can never lose @@OT/@@TS/@@IMG/@@FILE.
function ConvertFrom-MsgRawLine([string]$line, [int]$DomIndex) {
    $role = 'unknown'
    if ($line -match '^\[BUYER\]') { $role = 'buyer' }
    elseif ($line -match '^\[ME\]') { $role = 'me' }
    if ($role -eq 'unknown') { return $null }

    $plain = Get-MsgPlainText $line
    $orig = Get-MsgOriginalText $line

    # @@TS accompanies robot-sent messages (see lib\msg_source.ps1 header). An [ME] line without
    # it was typed by the owner. Same rule as the single authority in lib\msg_source.ps1.
    $source = $role
    if ($role -eq 'me') {
        if ($line -match '@@TS') { $source = 'bot' } else { $source = 'human' }
    }

    $imgUrls = @()
    $mi = [regex]::Match([string]$line, '@@IMG:([^\s]+)')
    if ($mi.Success) {
        $imgUrls = @(@($mi.Groups[1].Value -split '\|') | Where-Object { $_ } | Select-Object -First 3)
    }
    $fileName = ''
    $fileUrl = ''
    $mf = [regex]::Match([string]$line, '@@FILE:([^\s]+)')
    if ($mf.Success) {
        $fp = $mf.Groups[1].Value -split '\|', 2
        try { $fileName = [uri]::UnescapeDataString($fp[0]) } catch { $fileName = $fp[0] }
        if ($fp.Count -gt 1) { $fileUrl = $fp[1] }
    }

    $tsRaw = ''
    $mt = [regex]::Match([string]$line, '@@TS:([^\s]+)')
    if ($mt.Success) { $tsRaw = $mt.Groups[1].Value }
    $tsMs = $null
    if ($tsRaw) { $tsMs = ConvertTo-EpochMs $tsRaw }

    # Identity: prefer an evidence-backed key. A timestamp makes the key unique per real message
    # even when the buyer sends identical text twice - exactly the "same text, new message" case in
    # spec 7.1. Without a timestamp the key falls back to content plus DOM position and is only
    # PROBABLY unique; that is what IdConfident records, and consumers must not treat a
    # non-confident id as proof that two messages are the same message.
    $normHash = Get-StableHash (Get-NormalizedMsgText $orig)
    $idConfident = [bool]$tsRaw
    $stableId = $role + '|' + $normHash
    if ($tsRaw) { $stableId = $role + '|' + $normHash + '|' + $tsRaw }
    elseif ($DomIndex -ge 0) { $stableId = $role + '|' + $normHash + '|dom' + $DomIndex }

    return [pscustomobject]@{
        Schema        = $script:MsgSchemaVersion
        DomIndex      = $DomIndex
        Seq           = 0              # assigned after ordering (1 = oldest)
        Role          = $role          # 'buyer' | 'me'
        Source        = $source        # 'buyer' | 'bot' | 'human'
        Text          = $plain
        Orig          = $orig
        NormText      = (Get-NormalizedMsgText $orig)
        NormHash      = $normHash
        TsRaw         = $tsRaw
        TsMs          = $tsMs
        HasImage      = ($imgUrls.Count -gt 0)
        ImageUrls     = $imgUrls
        FileName      = $fileName
        FileUrl       = $fileUrl
        HasFile       = [bool]$fileName
        HasAttachment = (($imgUrls.Count -gt 0) -or [bool]$fileName)
        StableId      = $stableId
        IdConfident   = $idConfident
        IsEmpty       = [string]::IsNullOrWhiteSpace($plain)
        RawLine       = $line
    }
}

# Decide the chronological direction of the extracted sequence from the showTime evidence that
# the page already exposes. Returns @{ Ascending; Confident; Reason; TimestampedCount }.
#   Ascending = $true  => index 0 is the OLDEST message (already chronological)
#   Ascending = $false => index 0 is the NEWEST message (must be reversed)
#   Confident = $false => the evidence did not settle it; DOM order is kept and the condition is
#                         reported so callers log/flag it instead of guessing silently.
function Resolve-MessageDirection([object[]]$Messages) {
    $arr = @($Messages)
    $stamped = @($arr | Where-Object { $_ -and $null -ne $_.TsMs })
    $res = @{ Ascending = $true; Confident = $false; Reason = 'no-timestamps-default-dom-order'; TimestampedCount = $stamped.Count }
    if ($stamped.Count -lt 2) { return $res }

    # Compare along the DOM sequence, not the filtered list, so a partially timestamped
    # conversation cannot silently invert the answer.
    $first = $null
    $last = $null
    foreach ($m in $arr) {
        if ($null -ne $m.TsMs) {
            if ($null -eq $first) { $first = $m.TsMs }
            $last = $m.TsMs
        }
    }
    if ($null -eq $first -or $null -eq $last) { return $res }
    if ($first -lt $last) {
        $res.Ascending = $true; $res.Confident = $true; $res.Reason = 'timestamps-increase-with-dom-order'
        return $res
    }
    if ($first -gt $last) {
        $res.Ascending = $false; $res.Confident = $true; $res.Reason = 'timestamps-decrease-with-dom-order'
        return $res
    }

    # Equal endpoints: walk consecutive stamped pairs to see whether the whole stamped run moves one
    # way. A contradiction (mixed directions) means the window was reordered or truncated, and we
    # must not claim confidence (spec 4.1).
    $increases = 0
    $decreases = 0
    $prev = $null
    foreach ($m in $arr) {
        if ($null -eq $m.TsMs) { continue }
        if ($null -ne $prev) {
            if ($m.TsMs -gt $prev) { $increases++ }
            elseif ($m.TsMs -lt $prev) { $decreases++ }
        }
        $prev = $m.TsMs
    }
    if ($increases -gt 0 -and $decreases -eq 0) {
        $res.Ascending = $true; $res.Confident = $true; $res.Reason = 'timestamps-monotonic-ascending'
    } elseif ($decreases -gt 0 -and $increases -eq 0) {
        $res.Ascending = $false; $res.Confident = $true; $res.Reason = 'timestamps-monotonic-descending'
    } else {
        $res.Reason = 'timestamps-non-monotonic-order-unverified'
    }
    return $res
}

# Turn the raw extracted blob into a normalized, chronologically ASCENDING message list.
# Returns:
#   @{ Schema; Messages; Lines; Order; BuyerMessages; LatestBuyer; LastBuyer; BuyerCount;
#      Skipped; Anomaly }
#   .Lines  = the ORIGINAL raw lines in ascending order, markers preserved, so existing consumers
#             (anti-interjection gate, ledger selector, promised-field scan) keep working against
#             one single direction and no data can be lost by reconstruction.
#   .LatestBuyer / .LastBuyer = the newest buyer message object. Both names are kept so callers
#             cannot reintroduce the head/tail ambiguity.
#   .Anomaly = $true when the order could not be verified - log it, do not hide it.
function ConvertTo-MessageList([string]$Raw, [string]$ConvoName = '') {
    $emptyOrder = @{ Ascending = $true; Confident = $true; Reason = 'empty'; TimestampedCount = 0 }
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [pscustomobject]@{
            Schema = $script:MsgSchemaVersion; ConvoName = $ConvoName; Messages = @(); Lines = @()
            Order = $emptyOrder; BuyerMessages = @(); LatestBuyer = $null; LastBuyer = $null
            BuyerCount = 0; Skipped = @(); Anomaly = $false
        }
    }

    $rawLines = @([regex]::Split($Raw, "\r?\n"))
    $parsed = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $ln = $rawLines[$i]
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $msg = ConvertFrom-MsgRawLine $ln $i
        if ($null -eq $msg) {
            # Not a role-tagged line: UI noise. Record it so nothing disappears without a reason.
            $t = $ln.Trim()
            [void]$skipped.Add(@{ Index = $i; Reason = 'no-role-marker'; Text = $t.Substring(0, [Math]::Min(60, $t.Length)) })
            continue
        }
        if ($msg.IsEmpty -and -not $msg.HasAttachment) {
            [void]$skipped.Add(@{ Index = $i; Reason = 'empty-and-no-attachment'; Text = '' })
            continue
        }
        # NOTE: there is deliberately NO text-length filter here. Short acknowledgements such as
        # "ok", "si" and "no" are real message events (spec 4.1) and must reach the decision layer.
        [void]$parsed.Add($msg)
    }

    $order = Resolve-MessageDirection $parsed.ToArray()
    $list = @($parsed.ToArray())
    if (-not $order.Ascending) { [array]::Reverse($list) }

    for ($k = 0; $k -lt $list.Count; $k++) { $list[$k].Seq = $k + 1 }

    $buyers = @($list | Where-Object { $_.Role -eq 'buyer' })
    $latest = $null
    if ($buyers.Count -gt 0) { $latest = $buyers[$buyers.Count - 1] }

    return [pscustomobject]@{
        Schema        = $script:MsgSchemaVersion
        ConvoName     = $ConvoName
        Messages      = $list
        Lines         = @($list | ForEach-Object { $_.RawLine })
        Order         = $order
        BuyerMessages = $buyers
        LatestBuyer   = $latest
        LastBuyer     = $latest
        BuyerCount    = $buyers.Count
        Skipped       = @($skipped.ToArray())
        # Unverified order is a reportable condition, not something to paper over (spec 4.1).
        Anomaly       = (-not $order.Confident)
    }
}

# Facts derived from the conversation, used by the policy layer. Deliberately distinguishes the
# evidence classes required by spec 4.2: buyer statement, human confirmation, model inference,
# unknown. This function only ever reports the first two, and labels which is which.
function Get-ConversationFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Conversation)

    $msgs = @($Conversation.Messages)
    $buyerText = (@($msgs | Where-Object { $_.Role -eq 'buyer' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $meText = (@($msgs | Where-Object { $_.Source -eq 'bot' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $humanText = (@($msgs | Where-Object { $_.Source -eq 'human' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $allText = (@($buyerText, $meText, $humanText) | Where-Object { $_ }) -join [string][char]10
    $bl = $buyerText.ToLowerInvariant()
    $al = $allText.ToLowerInvariant()

    return [pscustomobject]@{
        HasWeight       = [bool]($bl -match '\d+\s*(kg|kgs|kilo|kilos|ton|tons)\b|\d+\s*(公斤|千克|吨)|weight\s*[:=]?\s*\d|peso\s*[:=]?\s*\d')
        HasDimensions   = [bool]($bl -match '\d+\s*[x\u00d7*]\s*\d+|\d+(\.\d+)?\s*(cm|mm)\s*[x\u00d7*]|dimension|尺寸|medidas')
        HasAddress      = [bool]($bl -match 'address|addr|calle|rua|street|avenue|road|endere|direcci|收货地址|邮编|cep|postal|zip|city|ciudad|cidade|country|pa[ií]s|deliver to|consignee|destinatario')
        HasImages       = [bool](@($msgs | Where-Object { $_.Role -eq 'buyer' -and $_.HasImage }).Count -gt 0)
        HasFile         = [bool](@($msgs | Where-Object { $_.Role -eq 'buyer' -and $_.HasFile }).Count -gt 0)
        # "Mentioned a supplier" and "gave us the supplier's contact" are different facts and must
        # not be conflated: the approved dimension guidance asks for the supplier's contact, so if
        # merely mentioning the factory counted as "provided" the system would stop asking for the
        # very thing it needs - and the fallback would still ask, contradicting the decision object.
        HasSupplier     = [bool]($bl -match 'supplier|vendor|factory|proveedor|fornecedor|供应商')
        HasSupplierContact = [bool](
            ($bl -match '(supplier|vendor|factory|proveedor|fornecedor|供应商)[^.!?]{0,60}(\+?\d[\d\s\-\(\)]{6,}|[\w\.\-]+@[\w\-]+\.[A-Za-z]{2,})') -or
            ($bl -match '(contact|number|phone|whatsapp|email|wechat)[^.!?]{0,20}(of|for|is|:)[^.!?]{0,40}(supplier|vendor|factory|proveedor|fornecedor|供应商)')
        )
        # The buyer explicitly said they have no supplier or are the end user. Asking for a supplier
        # contact would then be nonsense.
        HasNoSupplier   = [bool]($bl -match "(?:\bno\b|\bdon''?t\s+have\b|\bdo\s+not\s+have\b|\bdoesn''?t\s+have\b|\bwithout\b|\bnot\s+using\b)[^.!?]{0,25}\b(?:supplier|vendor|factory|proveedor|fornecedor|供应商)" -or $bl -match '(没有供应商|终端客户)')
        HasQuantity     = [bool]($bl -match '\d+\s*(pcs|pieces|cartons|ctns|boxes|units)\b|\d+\s*(件|箱)')
        HasShippingMode = [bool]($bl -match 'by sea|by air|ocean|air freight|\bfcl\b|\blcl\b|shipping method|transport')
        BuyerStatements = $buyerText
        BotStatements   = $meText
        HumanStatements = $humanText
        AllText         = $allText
        BuyerLower      = $bl
        AllLower        = $al
    }
}
