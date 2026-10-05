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
#      DOM order alone does not establish chronology. This file verifies direction against
#      per-message timestamps explicitly marked @@MT by the extractor, normalizes to chronological
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

# 模块互相按需加载的一次性标记（用 $global: 而不是 $script:：dot-source 时 $script: 解析到**调用方**
#   的脚本作用域，跨模块根本读不到）。facts_engine 见到 AarLibLoadingMsgNorm 就不再回调本文件，
#   否则 "facts_engine -> msg_norm -> facts_engine" 会递归到调用深度溢出（实测 CallDepthOverflow）。
$global:AarLibLoadingMsgNorm = $true

if (-not (Get-Command Get-NormalizedMsgText -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'reply_engine.ps1')
}
# 加载完成后立即清除重入标记（不能等到文件末尾：本文件会被多个模块 dot-source，
#   若在末尾才清除，任何"加载中途就被判定为已完成"的组合都会跳过事实模型）。
$global:AarLibLoadingMsgNorm = $false

# Structured message schema version. Bump on any field change to the message object.
$script:MsgSchemaVersion = 3

if (-not (Get-Command Get-QuoteDestination -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'destination.ps1')
}
# [2026-10-05 spec §4.2 第 1 条] 单一事实模型（Get-CargoFacts / Get-QuoteReadiness）在本文件里被
#   两个入口消费：Get-ConversationFacts 与 Get-QuoteReadinessForConversationText。依赖方向是
#   msg_norm -> facts_engine（facts_engine 会用本文件的 ConvertTo-MessageList 与目的地解析），
#   而本文件在 reply_engine/destination 之后加载，因此这里按需加载不会形成环。
#   只加载一次；缺失时静默跳过，由消费方按"判据不可用"显式降级（绝不退回第二套关键词判据）。
if (-not $global:AarFactsEngineLoaded) {
    $__factsFile = Join-Path $PSScriptRoot 'facts_engine.ps1'
    if ((Test-Path $__factsFile) -and -not $global:AarLibLoadingMsgNorm -and -not $global:AarLibLoadingFacts) { . $__factsFile }
}
$global:AarLibLoadingMsgNorm = $false

function Get-MsgSchemaVersion { return $script:MsgSchemaVersion }

# Definitions must live in the importing scope, not vanish after a function-local dot source.
if(-not(Get-Command Get-TaskConfirmedEvidence -ErrorAction SilentlyContinue)){. (Join-Path $PSScriptRoot 'task_facts.ps1')}

# Strip time, original-text, card and attachment transport markers from a raw line, returning the
# human-readable text. Markers are transport metadata, never message content.
function Get-MsgPlainText([string]$line) {
    if ([string]::IsNullOrEmpty($line)) { return '' }
    $t = $line -replace '^\[(BUYER|ME)\]\s*', ''
    $t = $t -replace '@@IMG:[^\s]*', ''
    $t = $t -replace '@@FILE:[^\s]*', ''
    $t = $t -replace '@@(?:TS|MT|MID|SRC|CARD):[^\s]*', ''
    $t = $t -replace '@@OT:[A-Za-z0-9\+/=]+', ''
    $t = $t -replace '系统自动发送|自动接待发送', ''
    return $t.Trim()
}

# Decode the @@OT original-text marker (base64 UTF-8). Falls back to the plain text when the
# marker is absent or corrupt, so identity never depends on a marker being present.
function Get-MsgOriginalText([string]$line, [switch]$KeepUiNoise) {
    $plain = Get-MsgPlainText $line
    $m = [regex]::Match([string]$line, '@@OT:([A-Za-z0-9\+/=]+)')
    if (-not $m.Success) { return $plain }
    try {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
        if (-not [string]::IsNullOrWhiteSpace($decoded)) {
            if ($KeepUiNoise) { return $decoded.Trim() }
            return ($decoded -replace '系统自动发送|自动接待发送', '').Trim()
        }
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
    $rawOrig = Get-MsgOriginalText $line -KeepUiNoise
    $orig = ($rawOrig -replace '系统自动发送|自动接待发送', '').Trim()

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

    # @@TS in legacy snapshots may be conversation-level showTime. Only @@MT is evidence
    # of the per-message clock; a naked @@TS must never establish direction or identity.
    $tsRaw = ''
    $mt = [regex]::Match([string]$line, '@@TS:([^\s]+)')
    if ($mt.Success) { $tsRaw = $mt.Groups[1].Value }
    $messageTsRaw = ''
    $messageTs = [regex]::Match([string]$line, '@@MT:([^\s]+)')
    if ($messageTs.Success) { $messageTsRaw = $messageTs.Groups[1].Value }
    $tsMs = $null
    if ($messageTsRaw) { $tsMs = ConvertTo-EpochMs $messageTsRaw }
    $isSystemCard = ($role -eq 'buyer' -and (
        $line -match '@@CARD:system\b|系统自动发送' -or $rawOrig -match '系统自动发送' -or
        ($orig -match '(?i)最小订购量|minimum\s+order|min\.?\s+order' -and $orig -match '\$\s*\d')
    ))

    # Identity: prefer an evidence-backed key. A timestamp makes the key unique per real message
    # even when the buyer sends identical text twice - exactly the "same text, new message" case in
    # spec 7.1. Without a timestamp the key falls back to content plus DOM position and is only
    # PROBABLY unique; that is what IdConfident records, and consumers must not treat a
    # non-confident id as proof that two messages are the same message.
    $normText = Get-NormalizedMsgText $orig
    $normHash = Get-StableHash $normText
    $idConfident = ($null -ne $tsMs)
    $stableId = $role + '|' + $normHash
    if ($idConfident) { $stableId = $role + '|' + $normHash + '|' + $messageTsRaw }
    elseif ($DomIndex -ge 0) { $stableId = $role + '|' + $normHash + '|dom' + $DomIndex }

    $platformId=[regex]::Match($line,'@@MID:([^\s]+)')
    if($platformId.Success){$stableId=$role+'|id:'+$platformId.Groups[1].Value;$idConfident=$true}
    return [pscustomobject]@{
        PlatformMessageId=$platformId.Groups[1].Value
        Schema        = $script:MsgSchemaVersion
        DomIndex      = $DomIndex
        Seq           = 0              # assigned after ordering (1 = oldest)
        Role          = $role          # 'buyer' | 'me'
        Source        = $source        # 'buyer' | 'bot' | 'human'
        Text          = $plain
        Orig          = $orig
        NormText      = $normText
        NormHash      = $normHash
        TsRaw         = $tsRaw
        MessageTsRaw  = $messageTsRaw
        TsMs          = $tsMs
        IsSystemCard  = [bool]$isSystemCard
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

# Decide direction using ONLY explicit per-message timestamps. Legacy showTime is not evidence.
# Every message must be stamped and all consecutive pairs must agree. Equal clocks alone,
# missing clocks and any inversion leave direction unverified.
#   Ascending = $true  => index 0 is the OLDEST message (already chronological)
#   Ascending = $false => index 0 is the NEWEST message (must be reversed)
#   Confident = $false => the evidence did not settle it; DOM order is kept and the condition is
#                         reported so callers log/flag it instead of guessing silently.
function Resolve-MessageDirection([object[]]$Messages) {
    $arr = @($Messages)
    $stamped = @($arr | Where-Object { $_ -and $null -ne $_.TsMs })
    $res = @{ Ascending = $true; Confident = $false; Reason = 'no-trusted-message-timestamps'; TimestampedCount = $stamped.Count }
    if ($arr.Count -le 1) {
        $res.Confident = $true; $res.Reason = 'single-message'
        if ($arr.Count -eq 0) { $res.Reason = 'empty' }
        return $res
    }
    if ($stamped.Count -eq 0) { return $res }
    if ($stamped.Count -ne $arr.Count) { $res.Reason = 'missing-message-timestamps'; return $res }
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
#   .LatestBuyer / .LastBuyer = the newest buyer only when direction is verified and it is not
#             a system card; otherwise null, with ReplyBlockReason. BuyerCount retains cards
#             for compatibility with the existing HASH|count ledger.
#   .Anomaly = $true when order is unverified; production must block, never guess a latest message.
function ConvertTo-MessageList([string]$Raw, [string]$ConvoName = '') {
    $rawLines = @()
    if (-not [string]::IsNullOrWhiteSpace($Raw)) { $rawLines = @([regex]::Split($Raw, "\r?\n")) }
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
    $blockReason = ''
    if (-not $order.Confident) { $blockReason = 'message-order-unverified' }
    elseif ($buyers.Count -eq 0) { $blockReason = 'no-buyer-message' }
    elseif ($buyers[$buyers.Count - 1].IsSystemCard) { $blockReason = 'latest-buyer-system-card' }
    else { $latest = $buyers[$buyers.Count - 1] }
    # Identical content with the same displayed second is not a confidently unique identity.
    foreach ($group in @($list | Group-Object StableId | Where-Object { $_.Count -gt 1 })) {
        foreach ($message in $group.Group) { $message.IdConfident = $false }
    }

    $platformId=[regex]::Match($line,'@@MID:([^\s]+)')
    if($platformId.Success){$stableId=$role+'|id:'+$platformId.Groups[1].Value;$idConfident=$true}
    return [pscustomobject]@{
        PlatformMessageId=$platformId.Groups[1].Value
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
        ReplyBlockReason = $blockReason
        # Unverified order is a reportable condition, not something to paper over (spec 4.1).
        Anomaly       = (-not $order.Confident)
    }
}

# ============================================================================================
# [2026-10-05 spec §4.2 第 1 条] 单一报价判据的字符串入口。
#   quote.ps1 的报价提醒走的是**快照文本**（data\msgs_*.txt），而就绪判据在
#   facts_engine.ps1::Get-QuoteReadiness（消费 Get-CargoFacts）。这里是两者之间唯一的适配层：
#   任何消费者都必须通过它拿到与回复决策完全相同的事实与 Ready/MissingFields，
#   不得再自行用"重量 + 尺寸 + 地址"三个布尔值决定能不能报价。
# ============================================================================================
# 把附件识别结果（vision/doc sidecar）转成一条合成买家证据行，使其与买家原话走**同一份**
#   事实模型与准备度判据。没有值时不生成任何行。
function ConvertTo-SidecarBuyerLine($Sidecar) {
    if (-not $Sidecar) { return '' }
    $parts = New-Object System.Collections.ArrayList
    $w = ''
    if ($Sidecar.PSObject.Properties.Name -contains 'weight_kg') { $w = [string]$Sidecar.weight_kg }
    $d = ''
    if ($Sidecar.PSObject.Properties.Name -contains 'dims') { $d = [string]$Sidecar.dims }
    $c = ''
    if ($Sidecar.PSObject.Properties.Name -contains 'cartons') { $c = [string]$Sidecar.cartons }
    if ($w) { [void]$parts.Add('packed weight per carton ' + $w) }
    if ($d) { [void]$parts.Add('packed dimensions ' + $d) }
    if ($c) { [void]$parts.Add('cartons ' + $c) }
    if ($parts.Count -eq 0) { return '' }
    return ('[BUYER] (from attachment: ' + (@($parts.ToArray()) -join ', ') + ')')
}

# 附件识别单独给出的重量常常没有单位（sidecar 的 weight_kg 字段本身就是"公斤"含义，
#   历史数据里存在 '47'、'9kg' 两种写法）。单位缺失时按 kg 补上，并明确标成"整批/单件范围未明"
#   的事实模型值；这一步只服务于附件的字段语义，不改变任何买家原话的解析口径。
function Get-SidecarWeightText([string]$Raw) {
    $t = ([string]$Raw).Trim()
    if (-not $t) { return '' }
    if ($t -match '(?i)(kg|kgs|kilo|kilos|kilograms?|ton|tons|tonnes?|lb|lbs|公斤|千克|吨)\s*$') { return $t }
    if ($t -match '^\d+(\.\d+)?$') { return ($t + ' kg') }
    return $t
}

function Get-QuoteReadinessForSidecarText {
    [CmdletBinding()]
    param([string]$Text, $Sidecar = $null, [string]$ConvoName = '', [switch]$WithTaskEvidence)
    $combined = [string]$Text
    if ($Sidecar -and ($Sidecar.PSObject.Properties.Name -contains 'weight_kg')) {
        $Sidecar = [pscustomobject]@{
            weight_kg = (Get-SidecarWeightText ([string]$Sidecar.weight_kg))
            dims      = $(if ($Sidecar.PSObject.Properties.Name -contains 'dims') { [string]$Sidecar.dims } else { '' })
            cartons   = $(if ($Sidecar.PSObject.Properties.Name -contains 'cartons') { [string]$Sidecar.cartons } else { '' })
        }
    }
    $line = ConvertTo-SidecarBuyerLine $Sidecar
    if ($line) {
        if ($combined) { $combined = $combined + [string][char]10 + $line } else { $combined = ('# BUYER: ' + $ConvoName + [string][char]10 + $line) }
    }
    return (Get-QuoteReadinessForConversationText -Text $combined -ConvoName $ConvoName -WithTaskEvidence:$WithTaskEvidence)
}

# [spec §5.4 第 3 条] 同一证据适配契约：显式要求时才从任务存储读取已验证的确认资料。
#   纯文本/纯逻辑调用不传开关 ⇒ 完全不访问任务存储。
function Resolve-TaskEvidenceForFacts([string]$Buyer, $Conversation, $ExplicitEvidence, [bool]$WithTaskEvidence) {
    if ($ExplicitEvidence -and @($ExplicitEvidence).Count -gt 0) { return @($ExplicitEvidence) }
    if (-not $WithTaskEvidence) { return @() }
    if (-not $Buyer) { return @() }
    if (-not (Get-Command Get-TaskConfirmedEvidence -ErrorAction SilentlyContinue)) {
        $tf = Join-Path $PSScriptRoot 'task_facts.ps1'
        if (Test-Path $tf) { . $tf }
    }
    if (-not (Get-Command Get-TaskConfirmedEvidence -ErrorAction SilentlyContinue)) { return @() }
    $flow=Sync-CurrentCargoFlow -Buyer $Buyer -Conversation $Conversation
    if($flow){$Conversation | Add-Member -NotePropertyName CargoFlowRef -NotePropertyValue $flow -Force}
    return @(Get-TaskConfirmedEvidence -Buyer $Buyer -Conversation $Conversation)
}

function Get-QuoteReadinessForConversationText {
    [CmdletBinding()]
    param([string]$Text, [string]$ConvoName = '', $TaskEvidence = @(), [switch]$WithTaskEvidence)
    $out = [pscustomobject]@{
        Available = $false; Conversation = $null; Facts = $null; CargoFacts = $null
        Readiness = $null; Ready = $false; MissingFields = @(); OptionalMissingFields = @()
        CollectionComplete = $false; Clarifications = @(); RuleVersion = ''; Error = ''
    }
    if (-not (Get-Command Get-CargoFacts -ErrorAction SilentlyContinue)) { $out.Error = 'facts-engine-unavailable'; return $out }
    try {
        $conv = ConvertTo-MessageList ([string]$Text) $ConvoName
        $out.Conversation = $conv
        # [2026-10-05 第三轮 spec §5.4] 已验证的任务确认资料与买家原话走**同一份**事实模型与准备度判据。
        $te = @(Resolve-TaskEvidenceForFacts -Buyer $ConvoName -Conversation $conv -ExplicitEvidence $TaskEvidence -WithTaskEvidence ([bool]$WithTaskEvidence))
        $cf = Get-CargoFacts -Conversation $conv -TaskEvidence $te
        $out.CargoFacts = $cf
        $r = Get-QuoteReadiness -Facts $cf
        $out.Readiness = $r
        $out.Ready = [bool]$r.Ready
        $out.MissingFields = @($r.MissingFields)
        $out.OptionalMissingFields = @($r.OptionalMissingFields)
        $out.CollectionComplete = [bool]$r.CollectionComplete
        $out.Clarifications = @($r.Clarifications)
        $out.RuleVersion = [string]$r.RuleVersion
        $out.Available = $true
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

# Facts derived from the conversation, used by the policy layer. Deliberately distinguishes the
# evidence classes required by spec 4.2: buyer statement, human confirmation, model inference,
# unknown. This function only ever reports the first two, and labels which is which.
function Get-ConversationFacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Conversation,
        # [2026-10-05 第三轮 spec §5.4] 由最小共享适配层（lib\task_facts.ps1）导出的任务确认证据。
        #   不传时行为与旧调用完全一致（不读任务存储、不改变任何既有判据）。
        $TaskEvidence = @(),
        # [spec §5.4] 显式要求时才从任务存储读取已验证的确认资料（默认不访问真实存储）。
        [switch]$WithTaskEvidence,
        [string]$Buyer = ''
    )

    $msgs = @($Conversation.Messages | Where-Object { -not $_.IsSystemCard })
    $buyerText = (@($msgs | Where-Object { $_.Role -eq 'buyer' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $meText = (@($msgs | Where-Object { $_.Source -eq 'bot' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $humanText = (@($msgs | Where-Object { $_.Source -eq 'human' } | ForEach-Object { $_.Orig }) -join [string][char]10)
    $allText = (@($buyerText, $meText, $humanText) | Where-Object { $_ }) -join [string][char]10
    $bl = $buyerText.ToLowerInvariant()
    $al = $allText.ToLowerInvariant()
    $destination = Get-QuoteDestination $Conversation
    # [2026-10-05 spec §3.1] ONE fact model: when lib\facts_engine.ps1 is available its result is
    # attached here, so every consumer (reply strategy, quote reminder, reports) reads the same
    # values, scopes, statuses and evidence instead of re-deriving them from keywords.
    $cargoFacts = $null
    $quoteReadiness = $null
    if (Get-Command Get-CargoFacts -ErrorAction SilentlyContinue) {
        try {
            $teFacts = @(Resolve-TaskEvidenceForFacts -Buyer $Buyer -Conversation $Conversation -ExplicitEvidence $TaskEvidence -WithTaskEvidence ([bool]$WithTaskEvidence))
            $cargoFacts = Get-CargoFacts -Conversation $Conversation -TaskEvidence $teFacts
            if (Get-Command Get-QuoteReadiness -ErrorAction SilentlyContinue) { $quoteReadiness = Get-QuoteReadiness -Facts $cargoFacts }
        } catch { $taskEvidenceError=$_.Exception.Message;$cargoFacts=Get-CargoFacts -Conversation $Conversation;$quoteReadiness=Get-QuoteReadiness $cargoFacts }
    }

    return [pscustomobject]@{
        FlowRef=$Conversation.CargoFlowRef
        TaskEvidenceError=$taskEvidenceError
        CargoFacts      = $cargoFacts
        QuoteReadiness  = $quoteReadiness
        HasWeight       = [bool]($bl -match '\d+\s*(kg|kgs|kilo|kilos|ton|tons)\b|\d+\s*(公斤|千克|吨)|weight\s*[:=]?\s*\d|peso\s*[:=]?\s*\d')
        HasDimensions   = [bool]($bl -match '\d+\s*[x\u00d7*]\s*\d+|\d+(\.\d+)?\s*(cm|mm)\s*[x\u00d7*]|dimension|尺寸|medidas')
        HasAddress      = $destination.HasPostalAddress
        HasQuoteDestination = $destination.QuoteUsable
        Destination     = $destination
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
