# lib\msg_events.ps1 - 统一消息事件模型 + 我方来源四态判定（platform / project / human / unknown）
#
# 契约（spec §3.1 / §3.2）：
#   * 本文件是"消息事件身份"与"我方来源四态"的**唯一**判定处；旧入口一律委托到这里，
#     不再各自写正则判来源。纯函数、无副作用、不 dot-source monitor.ps1。
#   * 来源标签是**独立元数据**：不进入正文哈希、去重键或事件身份。
#   * 标签在取得来源真值对照（S0）并确认独占性之前**不参与判定**；
#     Get-MessageSourceRuleSet 的默认规则集没有任何已验证标签 ⇒ 标签单独出现时结果仍是 unknown。
#
# 行格式（向后兼容）：旧行仍可读，只是身份质量降级为 legacy。
#   [ME] <显示正文> @@MT:<epochms> @@TS:<epochms> @@META:<base64(json)>
#   @@META 固定在行尾，是唯一可信的逐条元数据载体；正文里出现的同类文本不会被当作元数据。
#   @@META 载荷字段：
#     v      抽取规则版本
#     t      base64(UTF-8 正文) —— 正文的唯一真值来源（有 @@META 时不再从显示文本反推正文）
#     dir    'in' | 'out' | 'unknown'（已核实方向：抽取器显式声明 unknown 时不得按角色标记改写）
#     dirsrc 方向依据：'layout' | 'name-field' | 'translation-marker' | 'conflict' | 'missing' | 'role-marker-only'
#     mid    平台 MessageId（页面确实给出时）
#     ts     逐条时间 epoch 毫秒
#     tprec  'millisecond' | 'second' | 'minute' | 'none'
#     st     'message' | 'flow' | 'summary'
#     src    @( 逐条绑定的原始来源字段/标签 )，例如 'tag:自动接待发送'、'field:sender=bot'
#     at     采样时刻 UTC ISO
#     idq    抽取侧自评的事件身份可信度
#
# 依赖：msg_source.ps1（行指纹）。本文件不写任何文件、不发通知、不读配置。

if (-not (Get-Command Get-MessageLineFingerprint -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'msg_source.ps1')
}

$script:MessageSourceRuleVersion = 'msgsrc-2026-10-07.1'
$script:MessageEventMetaVersion = 'msgevent-2026-10-07.1'

function Get-MessageSourceRuleVersion { return [string]$script:MessageSourceRuleVersion }
function Get-MessageEventMetaVersion { return [string]$script:MessageEventMetaVersion }

# =============================================================================================
# 来源证据规则集
#
# S0（对照证据）在本轮**没有**取得任何一类来源的真值样本（页面实时读取未授权、生产已停机）。
# 因此默认规则集是"空的"：没有任何标签被确认独占，也没有任何字段被确认可信。
#   * 这条默认值使 A02/A05/A06 的保守结果成为生产默认行为，而不是测试特例；
#   * 测试通过显式传入规则集来验证"若某类证据被确认，机制会得出对应四态"（机制 vs 规则分离）；
#   * 真实规则集只能由 S0 证据写入 config 的 source_rules 段（见 Get-MessageSourceRuleSetFromConfig）。
# =============================================================================================
function New-MessageSourceRuleSet {
    param(
        [string]$Version = '',
        $VerifiedTags = $null,
        $VerifiedFields = $null,
        [string]$Provenance = 'unverified-no-source-truth-sample'
    )
    $tags = @{}
    $fields = @{}
    if ($VerifiedTags) { foreach ($p in $VerifiedTags.PSObject.Properties) { $tags[[string]$p.Name] = [string]$p.Value } }
    if ($VerifiedFields) { foreach ($p in $VerifiedFields.PSObject.Properties) { $fields[[string]$p.Name] = [string]$p.Value } }
    return [pscustomobject]@{
        Version        = $(if ($Version) { $Version } else { [string]$script:MessageSourceRuleVersion })
        VerifiedTags   = $tags
        VerifiedFields = $fields
        Provenance     = $Provenance
        VerifiedCount  = ($tags.Count + $fields.Count)
    }
}

function Get-MessageSourceRuleSet { return (New-MessageSourceRuleSet) }

# 从集中配置读取规则集。配置缺失/损坏时退回"空规则集"（保守方向：不猜来源）。
function Get-MessageSourceRuleSetFromConfig {
    param($Config = $null)
    try {
        if (-not $Config -and (Get-Command Get-SkillConfig -ErrorAction SilentlyContinue)) { $Config = Get-SkillConfig }
    } catch { $Config = $null }
    if (-not $Config) { return (New-MessageSourceRuleSet) }
    if (-not ($Config.PSObject.Properties.Name -contains 'source_rules')) { return (New-MessageSourceRuleSet) }
    $sr = $Config.source_rules
    if (-not $sr) { return (New-MessageSourceRuleSet) }
    $ver = ''
    if ($sr.PSObject.Properties.Name -contains 'version') { $ver = [string]$sr.version }
    $tags = $null; $fields = $null; $prov = 'config-source_rules'
    if ($sr.PSObject.Properties.Name -contains 'verified_tags') { $tags = $sr.verified_tags }
    if ($sr.PSObject.Properties.Name -contains 'verified_fields') { $fields = $sr.verified_fields }
    if ($sr.PSObject.Properties.Name -contains 'provenance') { $prov = [string]$sr.provenance }
    return (New-MessageSourceRuleSet -Version $ver -VerifiedTags $tags -VerifiedFields $fields -Provenance $prov)
}

# =============================================================================================
# 行解析：把一行原始抽取行拆成 (正文, 逐条时间, 元数据)
# =============================================================================================
function Get-MessageBodyNorm([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = ([string]$Text) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
    return (($t -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Get-MessageBodyFingerprint([string]$Text) {
    $norm = Get-MessageBodyNorm $Text
    if (-not $norm) { return '' }
    return [string](Get-MessageLineFingerprint $norm)
}

# 去掉行内的全部已知标记，得到"显示正文"（旧行没有 @@META 时，这就是正文的唯一来源）。
function Get-MessageDisplayBody([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return '' }
    $t = [string]$Line
    $t = $t -replace '^\s*\[(BUYER|ME)\]\s*', ''
    $t = $t -replace '@@[A-Za-z]+:[^\s]*', ' '
    return ($t -replace '\s+', ' ').Trim()
}

function Get-MessageMetaMarker([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    # 只认行尾的最后一个 @@META：正文里伪造的同类文本不会被采纳。
    $m = [regex]::Match([string]$Line, '@@META:([A-Za-z0-9+/=_-]+)\s*$')
    if (-not $m.Success) { return $null }
    $raw = [string]$m.Groups[1].Value
    try { $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)) } catch { return $null }
    try {
        $obj = $json | ConvertFrom-Json
        if (-not $obj) { return $null }
        if (-not ($obj.PSObject.Properties.Name -contains 'v')) { return $null }
        return $obj
    } catch { return $null }
}

function ConvertTo-MessageMetaMarker($Meta) {
    if (-not $Meta) { return '' }
    $json = ($Meta | ConvertTo-Json -Depth 6 -Compress)
    return '@@META:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function ConvertTo-MessageDirection([string]$Dir) {
    switch ([string]$Dir) {
        'in'    { return 'in' }
        'out'   { return 'out' }
        default { return 'unknown' }
    }
}

# =============================================================================================
# 事件构造
# =============================================================================================
function New-MessageEvent {
    param(
        [string]$Role = '',
        [string]$Text = '',
        [string]$Direction = 'unknown',
        [string]$DirectionSource = 'missing',
        [string]$MessageId = '',
        [long]$MessageTime = 0,
        [string]$TimePrecision = 'none',
        [string]$StructureType = 'message',
        [object[]]$SourceTags = @(),
        [object[]]$SourceFields = @(),
        [object[]]$Attachments = @(),
        [string]$SampledAtUtc = '',
        [string]$ExtractionVersion = '',
        [string]$IdentityQuality = '',
        [int]$LineIndex = -1,
        [string]$RawLine = '',
        [string]$MetaStatus = 'absent'
    )
    return [pscustomobject]@{
        LineIndex         = $LineIndex
        Role              = [string]$Role
        Text              = [string]$Text
        BodyHash          = (Get-MessageBodyFingerprint $Text)
        Direction         = (ConvertTo-MessageDirection $Direction)
        DirectionSource   = [string]$DirectionSource
        MessageId         = [string]$MessageId
        MessageTime       = [long]$MessageTime
        TimePrecision     = [string]$TimePrecision
        StructureType     = [string]$StructureType
        SourceTags        = @($SourceTags)
        SourceFields      = @($SourceFields)
        Attachments       = @($Attachments)
        SampledAtUtc      = [string]$SampledAtUtc
        ExtractionVersion = $(if ($ExtractionVersion) { [string]$ExtractionVersion } else { [string]$script:MessageEventMetaVersion })
        IdentityQuality   = [string]$IdentityQuality
        MetaStatus        = [string]$MetaStatus
        RawLine           = [string]$RawLine
        IsBuyer           = ([string]$Role -eq 'buyer')
        IsMine            = ([string]$Role -eq 'me')
        IsNoise           = ([string]$StructureType -in @('flow', 'summary', 'noise'))
    }
}

# 一行 -> 事件。旧行没有 @@META 时按旧口径解析（正文 = 去掉标记的显示文本），身份质量降级为 legacy。
function ConvertFrom-MessageRawLine([string]$Line, [int]$LineIndex = -1) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $l = [string]$Line
    $role = ''
    if ($l -match '^\s*\[BUYER\]') { $role = 'buyer' }
    elseif ($l -match '^\s*\[ME\]') { $role = 'me' }
    if (-not $role) { return $null }

    $meta = Get-MessageMetaMarker $l
    $text = ''
    $dir = 'unknown'; $dirSrc = 'missing'; $mid = ''; $ts = [long]0; $tprec = 'none'
    $st = 'message'; $tags = @(); $fields = @(); $at = ''; $ver = ''; $idq = ''; $metaStatus = 'absent'
    # [复核 R10] 逐条元数据是否**显式**给出了方向。显式声明（即使值是 unknown/conflict）优先于
    #   "按行首角色标记猜方向"的旧口径 —— 否则方向冲突的真实气泡会被悄悄改写成 in/out。
    $dirDeclared = $false
    if ($meta) {
        $metaStatus = 'ok'
        if (($meta.PSObject.Properties.Name -contains 't') -and $meta.t) {
            try { $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$meta.t)) }
            catch { $text = ''; $metaStatus = 'corrupt' }
        }
        if ($meta.PSObject.Properties.Name -contains 'dir')    { $dir = [string]$meta.dir; $dirDeclared = $true }
        if ($meta.PSObject.Properties.Name -contains 'dirsrc') { $dirSrc = [string]$meta.dirsrc }
        if ($meta.PSObject.Properties.Name -contains 'mid')    { $mid = [string]$meta.mid }
        if ($meta.PSObject.Properties.Name -contains 'ts')     { try { $ts = [long]$meta.ts } catch { $ts = [long]0 } }
        if ($meta.PSObject.Properties.Name -contains 'tprec')  { $tprec = [string]$meta.tprec }
        if ($meta.PSObject.Properties.Name -contains 'st')     { $st = [string]$meta.st }
        if ($meta.PSObject.Properties.Name -contains 'src')    { $tags = @($meta.src) }
        if ($meta.PSObject.Properties.Name -contains 'f')      { $fields = @($meta.f) }
        if ($meta.PSObject.Properties.Name -contains 'at')     { $at = [string]$meta.at }
        if ($meta.PSObject.Properties.Name -contains 'v')      { $ver = [string]$meta.v }
        if ($meta.PSObject.Properties.Name -contains 'idq')    { $idq = [string]$meta.idq }
    }
    if (-not $text) { $text = Get-MessageDisplayBody $l }
    if ($dir -ne 'in' -and $dir -ne 'out') {
        if ($dirDeclared) {
            # [复核 R10] 抽取器显式声明方向（含 'unknown' 与左右结构冲突）：保持它，并把依据原样留下。
            #   这条事件因此没有可用身份（组合身份要求 in/out），既不能当买家诉求，也不能当出站证明。
            $dir = 'unknown'
            if (-not $dirSrc) { $dirSrc = 'missing' }
        } else {
            # 旧行 / 没有逐条元数据：沿用旧口径（按行首角色标记），并如实标注依据只是角色标记。
            if ($role -eq 'buyer') { $dir = 'in' } else { $dir = 'out' }
            $dirSrc = 'role-marker-only'
        }
    }
    if ($ts -le 0) {
        $mt = [regex]::Match($l, '@@MT:(\d{1,17})')
        if ($mt.Success) { try { $ts = [long]$mt.Groups[1].Value; if ($tprec -eq 'none') { $tprec = 'second' } } catch { $ts = [long]0 } }
    }
    if ($st -eq 'message' -and $l -match '@@CARD:system') { $st = 'system-card' }
    $evArgs = @{
        Role = $role; Text = $text; Direction = $dir; DirectionSource = $dirSrc; MessageId = $mid
        MessageTime = $ts; TimePrecision = $tprec; StructureType = $st; SourceTags = $tags; SourceFields = $fields
        SampledAtUtc = $at; ExtractionVersion = $ver; IdentityQuality = $idq; LineIndex = $LineIndex
        RawLine = $l; MetaStatus = $metaStatus
    }
    return (New-MessageEvent @evArgs)
}

function Get-MessageEvents {
    param([string[]]$Lines)
    $out = New-Object System.Collections.ArrayList
    if (-not $Lines) { return @() }
    $all = @($Lines)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $ev = ConvertFrom-MessageRawLine ([string]$all[$i]) $i
        if ($ev) { [void]$out.Add($ev) }
    }
    return @($out.ToArray())
}

# =============================================================================================
# 事件身份
# =============================================================================================
function Get-MessageEventCompositeKey($Event) {
    if (-not $Event) { return '' }
    if ($Event.IsNoise) { return '' }
    if (-not $Event.BodyHash) { return '' }
    if ($Event.Direction -ne 'in' -and $Event.Direction -ne 'out') { return '' }
    $t = [long]$Event.MessageTime
    if ($t -le 0) { return '' }
    if ($Event.TimePrecision -ne 'millisecond' -and $Event.TimePrecision -ne 'second') { return '' }
    return ('cmp|' + [string]$Event.Direction + '|' + $t.ToString() + '|' + [string]$Event.BodyHash)
}

# 事件身份：优先平台 MessageId；缺 ID 时只在"方向 + 逐条时间 + 完整正文"能唯一识别时使用组合身份。
# 只有正文、DOM 下标或窗口位置不构成可信事件身份（spec §3.1）。
function Get-MessageEventIdentity($Event, $Siblings = $null) {
    $r = [pscustomobject]@{ Identity = ''; Quality = 'unusable'; Reason = 'no-identity-evidence' }
    if (-not $Event) { return $r }
    if ($Event.IsNoise) { $r.Reason = 'structural-noise-not-an-event'; return $r }
    if ($Event.MetaStatus -eq 'corrupt') { $r.Reason = 'metadata-corrupt'; return $r }
    if ($Event.MessageId) {
        $r.Identity = 'id:' + [string]$Event.MessageId
        $r.Quality = 'platform-id'
        $r.Reason = 'platform-message-id'
        return $r
    }
    $key = Get-MessageEventCompositeKey $Event
    if (-not $key) { $r.Reason = 'body-or-time-or-direction-missing'; return $r }
    if ($Siblings) {
        $n = 0
        foreach ($s in @($Siblings)) { if ((Get-MessageEventCompositeKey $s) -eq $key) { $n++ } }
        if ($n -gt 1) { $r.Reason = 'composite-key-not-unique'; $r.Quality = 'ambiguous'; return $r }
        if ($Event.MetaStatus -ne 'ok') { $r.Reason = 'legacy-line-without-metadata'; $r.Quality = 'legacy'; $r.Identity = $key; return $r }
    }
    $r.Identity = $key
    $r.Quality = $(if ($Event.MetaStatus -eq 'ok') { 'composite' } else { 'legacy' })
    $r.Reason = 'unique-composite'
    return $r
}

# 会话级：给每个事件补 Identity / IdentityQuality / IdentityReason。
function Get-ConversationEventIndex {
    param([string[]]$Lines)
    $events = @(Get-MessageEvents $Lines)
    $out = New-Object System.Collections.ArrayList
    foreach ($e in $events) {
        $id = Get-MessageEventIdentity $e $events
        $e.IdentityQuality = [string]$id.Quality
        $e | Add-Member -NotePropertyName Identity -NotePropertyValue ([string]$id.Identity) -Force
        $e | Add-Member -NotePropertyName IdentityReason -NotePropertyValue ([string]$id.Reason) -Force
        [void]$out.Add($e)
    }
    return @($out.ToArray())
}

function Test-MessageEventIdentityUsable($Event) {
    if (-not $Event) { return $false }
    $q = [string]$Event.IdentityQuality
    return (($q -eq 'platform-id') -or ($q -eq 'composite'))
}

# =============================================================================================
# 我方来源四态判定
# =============================================================================================
function Add-MessageSourceClaim([hashtable]$Claims, [string]$Class, [string]$Ref) {
    if (-not $Class) { return }
    if (-not $Claims.ContainsKey($Class)) { $Claims[$Class] = (New-Object System.Collections.ArrayList) }
    [void]$Claims[$Class].Add([string]$Ref)
}

# 返回 @{ Class; Evidence; EvidenceRefs; Confidence; RuleVersion; Conflict; ConflictKind }
#   Class: platform | project | human | unknown | buyer | noise
function Resolve-MessageSourceClass {
    param(
        $Event,
        $Rules = $null,
        [bool]$ReceiptMatch = $false,
        [string]$ConfirmedClass = '',
        [string]$ConfirmedEvidence = ''
    )
    if (-not $Rules) { $Rules = Get-MessageSourceRuleSet }
    $r = [pscustomobject]@{
        Class = 'unknown'; Evidence = 'no-evidence'; EvidenceRefs = @(); Confidence = 'none'
        RuleVersion = [string]$Rules.Version; Conflict = @(); ConflictKind = ''
    }
    if (-not $Event) { $r.Evidence = 'empty-event'; return $r }
    if ($Event.IsNoise) { $r.Class = 'noise'; $r.Evidence = 'structural-noise'; $r.Confidence = 'strong'; return $r }
    if ($Event.IsBuyer -or $Event.Direction -eq 'in') { $r.Class = 'buyer'; $r.Evidence = 'verified-direction-in'; $r.Confidence = 'strong'; return $r }

    $claims = @{}
    # 1) 本项目已确认收据：唯一命中同一事件 ⇒ project（强证据，绑定确切事件）
    if ($ReceiptMatch) { Add-MessageSourceClaim $claims 'project' 'receipt:confirmed-outbound-event' }

    # 2) 逐条原始来源字段/标签：只有在规则集确认独占时才成为证据（默认规则集为空 ⇒ 不参与判定）
    foreach ($tag in @($Event.SourceTags)) {
        $t = [string]$tag
        if (-not $t) { continue }
        if ($Rules.VerifiedTags.ContainsKey($t)) { Add-MessageSourceClaim $claims ([string]$Rules.VerifiedTags[$t]) ('meta.tag:' + $t) }
    }
    # 已验证来源字段：只采信 @@META 载荷里逐条绑定的字段（正文里写出的同类文本不是元数据，见 A06）。
    if ($Event.MetaStatus -eq 'ok') {
        foreach ($f in @($Event.SourceFields)) {
            $fv = [string]$f
            if (-not $fv) { continue }
            if ($Rules.VerifiedFields.ContainsKey($fv)) {
                Add-MessageSourceClaim $claims ([string]$Rules.VerifiedFields[$fv]) ('meta.field:' + $fv)
            }
        }
    }

    # 3) 有出处、绑定确切事件的人工确认（由调查 CLI 提交，带 EventRef）
    if ($ConfirmedClass -and $Event.Identity -and $ConfirmedEvidence) {
        Add-MessageSourceClaim $claims ([string]$ConfirmedClass) ('confirmed:' + [string]$ConfirmedEvidence)
    }

    $classes = @($claims.Keys | Sort-Object)
    if ($classes.Count -eq 0) {
        if (@($Event.SourceTags).Count -gt 0) {
            $r.Evidence = 'raw-labels-only-unverified'
            $r.EvidenceRefs = @($Event.SourceTags | ForEach-Object { 'meta.tag:' + [string]$_ })
        } elseif ($Event.IsMine -or $Event.Direction -eq 'out') {
            # 我方消息但没有任何发送者证据：区分"只有逐条时间"与"连时间都没有"两种缺口。
            if ([long]$Event.MessageTime -gt 0) { $r.Evidence = 'timer-marker-only' }
            else { $r.Evidence = 'no-sender-evidence' }
        }
        return $r
    }
    if ($classes.Count -gt 1) {
        $refs = New-Object System.Collections.ArrayList
        foreach ($c in $classes) { foreach ($ref in @($claims[$c])) { [void]$refs.Add([string]$ref) } }
        $r.Class = 'unknown'
        $r.Evidence = 'source-conflict'
        $r.ConflictKind = 'source_conflict'
        $r.Confidence = 'conflicting'
        $r.Conflict = @($refs.ToArray())
        $r.EvidenceRefs = @($refs.ToArray())
        return $r
    }
    $cls = [string]$classes[0]
    $r.Class = $cls
    $r.EvidenceRefs = @($claims[$cls])
    $r.Confidence = 'strong'
    if ($cls -eq 'project') { $r.Evidence = 'confirmed-project-event-binding' }
    elseif ($cls -eq 'platform') { $r.Evidence = 'verified-platform-sender-field' }
    elseif ($cls -eq 'human') { $r.Evidence = 'verified-human-sender-evidence' }
    else { $r.Evidence = 'verified-evidence' }
    return $r
}

# =============================================================================================
# 发送闸门（四态）
# =============================================================================================
# 只看"当前相关我方尾部"：从最新一条往上，跳过结构噪声（flow/总结卡），
#   第一条有真实方向的事件决定结果。久远 unknown 不再阻断（spec §5 未知来源第 4 条）。
function Get-MessageSourceGate {
    param(
        [string[]]$Lines,
        $SentMatches = $null,
        $Rules = $null,
        $Confirmed = $null
    )
    if (-not $Rules) { $Rules = Get-MessageSourceRuleSet }
    $r = [pscustomobject]@{
        Action = 'SEND'; Reason = ''; TailIndex = -1; TailClass = ''; TailEvidence = ''
        TailIdentity = ''; TailIdentityQuality = ''; Conflict = @(); RuleVersion = [string]$Rules.Version
        HoldEventRef = ''; GateEventCount = 0
        # 与旧 Get-HumanInterjectionGateEx 同形的兼容字段（调用点无需改写取值）。
        HasHumanLast = $false; HumanIndex = -1; LastMeSource = ''
        UnknownIndex = -1; SourceClass = ''; SourceEvidence = ''
    }
    if (-not $Lines -or @($Lines).Count -eq 0) { $r.Action = 'SKIP'; $r.Reason = 'no-actionable'; return $r }
    $events = @(Get-ConversationEventIndex $Lines)
    $real = @($events | Where-Object { -not $_.IsNoise })
    $r.GateEventCount = $real.Count
    if ($real.Count -eq 0) { $r.Action = 'SKIP'; $r.Reason = 'no-actionable'; return $r }
    $mine = @($real | Where-Object { -not $_.IsBuyer })
    if ($mine.Count -eq 0) { $r.Reason = 'no-me-tail'; return $r }
    $tail = $mine[$mine.Count - 1]
    $receipt = $false
    if ($SentMatches -and $SentMatches.ContainsKey([int]$tail.LineIndex)) { $receipt = [bool]$SentMatches[[int]$tail.LineIndex] }
    $confClass = ''; $confEvidence = ''
    if ($Confirmed -and $tail.Identity) {
        foreach ($k in @($Confirmed.Keys)) {
            if ([string]$k -eq [string]$tail.Identity) { $confClass = [string]$Confirmed[$k].Class; $confEvidence = [string]$Confirmed[$k].Evidence }
        }
    }
    $cls = Resolve-MessageSourceClass -Event $tail -Rules $Rules -ReceiptMatch $receipt -ConfirmedClass $confClass -ConfirmedEvidence $confEvidence
    $r.TailIndex = [int]$tail.LineIndex
    $r.TailClass = [string]$cls.Class
    $r.TailEvidence = [string]$cls.Evidence
    $r.TailIdentity = [string]$tail.Identity
    $r.TailIdentityQuality = [string]$tail.IdentityQuality
    $r.Conflict = @($cls.Conflict)
    $lastReal = $real[$real.Count - 1]
    if ($lastReal.IsBuyer) { $r.Reason = 'buyer-last'; return $r }
    if ($cls.Class -eq 'buyer') { $r.Reason = 'buyer-last'; return $r }
    if ($cls.Class -eq 'platform') {
        $r.Reason = 'platform-last'; $r.LastMeSource = 'platform'
        $r.SourceClass = 'platform'; $r.SourceEvidence = [string]$cls.Evidence
        return $r
    }
    if ($cls.Class -eq 'project') {
        $r.Reason = 'project-last'; $r.LastMeSource = 'project'
        $r.SourceClass = 'project'; $r.SourceEvidence = [string]$cls.Evidence
        return $r
    }
    if ($cls.Class -eq 'human') {
        $r.Action = 'SKIP'; $r.Reason = 'human-last'
        $r.HasHumanLast = $true; $r.HumanIndex = [int]$tail.LineIndex; $r.LastMeSource = 'human'
        $r.SourceClass = 'human'; $r.SourceEvidence = [string]$cls.Evidence
        return $r
    }
    $r.Action = 'SKIP'
    if ($cls.ConflictKind -eq 'source_conflict') { $r.Reason = 'source-conflict' } else { $r.Reason = 'unknown-me-tail' }
    $r.HoldEventRef = [string]$tail.Identity
    $r.UnknownIndex = [int]$tail.LineIndex
    $r.LastMeSource = 'unknown'
    $r.SourceClass = [string]$cls.Class
    $r.SourceEvidence = [string]$cls.Evidence
    return $r
}

# =============================================================================================
# 来源更正：只更新确切事件，并据此重算暂停（spec §3.2 第 5 条 / A14）
# =============================================================================================
function Get-MessageSourceCorrections {
    param($Store, [string]$Buyer)
    $out = @{}
    if (-not $Store) { return $out }
    if (-not ($Store.PSObject.Properties.Name -contains 'corrections')) { return $out }
    $key = [string]$Buyer
    if (Get-Command Get-HumanPauseKey -ErrorAction SilentlyContinue) { $key = [string](Get-HumanPauseKey $Buyer) }
    if (-not $key) { $key = ([string]$Buyer).Trim().ToLowerInvariant() }
    foreach ($prop in $Store.corrections.PSObject.Properties) {
        if ([string]$prop.Name -ne $key) { continue }
        foreach ($c in @($prop.Value)) {
            if (-not $c) { continue }
            if (-not ($c.PSObject.Properties.Name -contains 'EventRef')) { continue }
            if (-not $c.EventRef) { continue }
            $out[[string]$c.EventRef] = [pscustomobject]@{ Class = [string]$c.Class; Evidence = [string]$c.Evidence }
        }
    }
    return $out
}

# =============================================================================================
# 共享判定上下文：所有旧入口（msg_source.ps1 / human_pause.ps1 / monitor.ps1）都委托到这里。
#   * 默认上下文 = 空规则集 + 无更正 ⇒ 除 buyer/结构噪声/已确认收据外一律 unknown。
#   * 生产由 monitor 用 config 的 source_rules 设置规则集；人工确认由调查 CLI 写入更正表。
#   * 测试可显式设置上下文，验证"若某类证据被确认，机制会得出对应四态"。
# =============================================================================================
$script:MessageSourceActiveRules = $null
$script:MessageSourceConfirmedMap = $null

function Set-MessageSourceContext {
    param($Rules = $null, $Confirmed = $null)
    $script:MessageSourceActiveRules = $Rules
    $script:MessageSourceConfirmedMap = $Confirmed
    return (Get-MessageSourceActiveRules)
}

function Clear-MessageSourceContext {
    $script:MessageSourceActiveRules = $null
    $script:MessageSourceConfirmedMap = $null
}

function Test-MessageSourceContextSet { return ($null -ne $script:MessageSourceActiveRules) }

function Get-MessageSourceActiveRules {
    if ($script:MessageSourceActiveRules) { return $script:MessageSourceActiveRules }
    return (Get-MessageSourceRuleSet)
}

function Get-MessageSourceActiveConfirmed { return $script:MessageSourceConfirmedMap }

# 单行 -> 四态（供所有旧入口委托）。返回与旧 Get-MessageSourceClass 同形并附证据引用。
function Get-MessageSourceClassForLine {
    param(
        [string]$Line,
        [bool]$SentRecordMatch = $false,
        $Rules = $null,
        $Confirmed = $null,
        [string]$Buyer = ''
    )
    if (-not $Rules) { $Rules = Get-MessageSourceActiveRules }
    if (-not $Confirmed) {
        if ($Buyer -and (Get-Command Get-InvestigationSourceCorrections -ErrorAction SilentlyContinue)) {
            try { $Confirmed = Get-InvestigationSourceCorrections -Buyer $Buyer } catch { $Confirmed = $null }
        }
        if (-not $Confirmed) { $Confirmed = Get-MessageSourceActiveConfirmed }
    }
    $ev = ConvertFrom-MessageRawLine ([string]$Line) 0
    if (-not $ev) { return @{ Class = 'unknown'; Evidence = 'no-role-marker'; EvidenceRefs = @(); Confidence = 'none'; RuleVersion = [string]$Rules.Version; ConflictKind = ''; Identity = '' } }
    $id = Get-MessageEventIdentity $ev
    $ev | Add-Member -NotePropertyName Identity -NotePropertyValue ([string]$id.Identity) -Force
    $ev.IdentityQuality = [string]$id.Quality
    $confClass = ''; $confEvidence = ''
    if ($Confirmed -and $ev.Identity) {
        foreach ($k in @($Confirmed.Keys)) {
            if ([string]$k -eq [string]$ev.Identity) { $confClass = [string]$Confirmed[$k].Class; $confEvidence = [string]$Confirmed[$k].Evidence }
        }
    }
    $r = Resolve-MessageSourceClass -Event $ev -Rules $Rules -ReceiptMatch $SentRecordMatch -ConfirmedClass $confClass -ConfirmedEvidence $confEvidence
    return @{
        Class        = [string]$r.Class
        Evidence     = [string]$r.Evidence
        EvidenceRefs = @($r.EvidenceRefs)
        Confidence   = [string]$r.Confidence
        RuleVersion  = [string]$r.RuleVersion
        ConflictKind = [string]$r.ConflictKind
        Identity     = [string]$ev.Identity
    }
}

# 事件在会话里是否是"当前相关尾部"：用于调查与门禁说明（阻断的是哪一个当前事件）。
function Get-MessageSourceRelevantTail {
    param([string[]]$Lines)
    $events = @(Get-ConversationEventIndex $Lines)
    $real = @($events | Where-Object { -not $_.IsNoise })
    if ($real.Count -eq 0) { return $null }
    return $real[$real.Count - 1]
}
