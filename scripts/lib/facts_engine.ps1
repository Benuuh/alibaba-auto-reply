# lib\facts_engine.ps1 - 单一货物事实模型 + 报价准备度（2026-10-05 spec §3.1-§3.4 / §7 验收样例）
#
# 职责
#   把"已规范化的消息列表"（lib\msg_norm.ps1::ConvertTo-MessageList 的返回值）变成**一份**带状态、
#   计量范围、来源与证据的货物事实，并单独判断"基本报价是否已具备条件"。
#   回复策略、报价提醒、摘要和报告消费同一份结果，停止各自用关键词独立判断资料是否齐全（spec §3.1）。
#
# 边界（纯函数库，符合 spec §6 分层）
#   - 不访问浏览器、不调用模型、不写文件、不发通知、不读系统时钟；时间只来自消息自带的 @@MT。
#   - 目的地解析复用既有权威实现 lib\destination.ps1::Get-QuoteDestination（msg_norm 已 dot-source），
#     本文件不写第二套仓储代码/地址解析。
#   - 唯一副作用是 dot-source 依赖文件本身。
#
# 依赖：lib\msg_norm.ps1（ConvertTo-MessageList / Get-MsgPlainText / 消息对象）；缺失时防御式 dot-source。
#
# 契约（属性名逐字一致，调用方按此使用）
#   Get-CargoFacts -Conversation $Conversation [-SentMatches $map]
#     Fields         @( 字段 )：@{ Key; Label; Value; Unit; Scope; Status; Source; SourceIndex; UpdatedAt; Evidence }
#     ByKey          @{ '<Key>' = 字段 }（含全部已登记字段；没有证据的字段 Status='unknown'、Value=''）
#     Derived        @( @{ Key; Value; Unit; Formula; SourceKeys } )：计算结果，带公式与来源字段
#     Clarifications @( 需要澄清的问题 )：字符串数组（范围不明 / 冲突 / 角色不明的联系方式）
#     Conflicts      @( @{ Key; Values } )
#     Corrections    @( @{ Key; From; To; SourceIndex } )
#     RuleVersion    '2026-10-05.1'
#   Get-QuoteReadiness -Facts $facts
#     Ready / MissingFields / OptionalMissingFields / CollectionComplete / Clarifications / Reasons / RuleVersion
#     判据（spec §3.2/§3.4 用户已确认）：
#       - 基本报价必需 = 件数 + 重量（单件或总重）+ 尺寸（单件或整批）+ 可用报价目的地；
#         Ready = 四项齐全，且没有未解决的冲突 / 让必需项落空的 needs_confirmation；
#       - MissingFields 用**字段键**（carton_count / unit_weight / unit_dimensions / delivery_address），
#         与 reply_policy 的 askKeyMap 对齐；冲突未解决时列出冲突字段本身（如 unit_weight）；
#       - OptionalMissingFields = 标准清单里尚未提供、但不阻挡报价准备的资料（缺货名/图片不改判 Ready）；
#       - CollectionComplete = 标准收集清单（10 项）全部提供，与 Ready 分开返回。
#
# 字段状态只有五种（spec §3.1）
#   unknown            没有可核对的值
#   promised           买家说稍后提供：保留缺口，本轮不重复追问同一字段
#   provided           明确给出了值与含义
#   needs_confirmation 有候选值，但单位/范围/含义不明（例如只给了 "20 kg" 没说总重还是每箱）
#   conflict           多个有效值无法解释为替换：请求确认，不擅自取第一个或最后一个
#
# 计量范围（spec §3.1-§3.2；用户已确认"单件以运输外包装（箱/托盘）为单位"）
#   weight:    unit（每箱/每托盘，运输外包装）| total（整批总重）| goods（商品净重）
#   dimension: unit（每箱/每托盘）| goods（商品本身）| lot（整批）
#   count:     cartons（箱/托盘等外包装件数）| goods（商品个数）
#   范围无法判定时，候选值挂在"范围未明"的占位字段（weight / dimensions / count），状态为 needs_confirmation。
#
# 证据分级（spec §2.2 / §3.1"机器人复述不能增加事实可信度"）
#   buyer  买家消息：事实的第一来源；
#   human  人工消息（现场手打，无 @@TS，且不在已确认发送记录里）：人工确认来源；
#   bot    机器人消息（@@TS 标记，或命中 lib\sent_records.ps1 的已确认发送记录）：不产生事实。
#
# SourceIndex 是消息在 $Conversation.Messages（= $Conversation.Lines）里的 0 基下标；
#   $SentMatches 是同一坐标系的索引表（lib\sent_records.ps1::Get-SentRecordMatchIndexes），
#   同时兼容按 DomIndex（原始抽取行号）给出的键，两者都只是"这条我方消息有发送记录"的证据。

$global:AarLibLoadingFacts = $true
if (-not (Get-Command Get-MsgPlainText -ErrorAction SilentlyContinue)) {
    # 重入守卫（双向）：msg_norm.ps1 按需加载本文件，本文件也按需加载 msg_norm.ps1。
    #   任何一侧"正在加载中"时都不得回调另一侧，否则两个文件互相 dot-source 会递归到
    #   调用深度溢出（实测 CallDepthOverflow：msg_norm:58 <-> facts_engine:60 死循环）。
    if (-not $global:AarLibLoadingMsgNorm -and -not $global:AarLibLoadingFacts) { . (Join-Path $PSScriptRoot 'msg_norm.ps1') }
}
$global:AarLibLoadingFacts = $false

$script:CargoFactsRuleVersion = '2026-10-05.1'

function Get-CargoRuleVersion { return $script:CargoFactsRuleVersion }

# Pure validation shared by message candidates and task confirmations.
function Test-CargoFieldValue {
    param([string]$FieldKey,$Value,[string]$Unit='', [string]$Scope='')
    $v=[string]$Value;$u=$Unit.Trim().ToLowerInvariant();$scopeKey=$Scope.ToLowerInvariant()
    $r=[pscustomobject]@{FieldKey=$FieldKey;Valid=$false;Value=$v;Unit=$u;Scope=$scopeKey;Reason='invalid-value-unit-or-scope'}
    if(-not $v -or $v.Length -gt 240 -or $v -match '[\r\n<>]|(?i)^(unknown|tbd|n/?a|none|null|pending)$'){return $r}
    switch -Regex ($FieldKey) {
        '^(carton_count|goods_count|count)$' {
            $n=ConvertTo-CargoNumber $v
            $r.Valid=($null -ne $n -and $n -gt 0 -and $n -eq [math]::Floor($n))
            if($FieldKey -eq 'carton_count'){$r.Valid=$r.Valid -and $scopeKey -in @('cartons','packaging') -and $u -match '^(cartons?|boxes|pallets?|packages?|ctns?|crates?)$'}
            elseif($FieldKey -eq 'goods_count'){$r.Valid=$r.Valid -and $scopeKey -eq 'goods'}else{$r.Valid=$false}
            if($r.Valid){$r.Value=Format-CargoNumber $n}
        }
        '^(unit_weight|total_weight|goods_weight|weight)$' {
            $n=ConvertTo-CargoNumber $v;$factors=@{kg=1;kgs=1;g=0.001;lb=0.45359237;lbs=0.45359237;ton=1000;tons=1000;t=1000}
            $wanted=@{unit_weight='unit';total_weight='total';goods_weight='goods';weight='unknown'}
            $r.Valid=($null -ne $n -and $n -gt 0 -and -not [double]::IsInfinity([double]$n) -and -not [double]::IsNaN([double]$n) -and $factors.ContainsKey($u) -and $scopeKey -eq $wanted[$FieldKey] -and $FieldKey -ne 'weight')
            if($r.Valid){$r.Value=Format-CargoNumber ([math]::Round(([double]$n*$factors[$u]),6));$r.Unit='kg'}
        }
        '^(unit_dimensions|lot_dimensions|goods_dimensions|dimensions)$' {
            $parts=@($v -split '[x×*]');$wanted=@{unit_dimensions='unit';lot_dimensions='packed_lot';goods_dimensions='goods';dimensions='unknown'}
            $r.Valid=($parts.Count -eq 3 -and $u -in @('cm','mm','m','in','inch','inches') -and $scopeKey -eq $wanted[$FieldKey] -and $FieldKey -ne 'dimensions')
            foreach($part in $parts){$n=ConvertTo-CargoNumber $part;if($null -eq $n -or $n -le 0 -or [double]::IsInfinity([double]$n) -or [double]::IsNaN([double]$n)){$r.Valid=$false}}
            if($u -in @('in','inch')){$r.Unit='inches'}
        }
        '^delivery_address$' {$d=Get-QuoteDestination (ConvertTo-MessageList ('[BUYER] Ship to '+$v));$r.Valid=($scopeKey -eq 'destination' -and [bool]$d.QuoteUsable)}
        '^(supplier_contact|recipient_contact)$' {$r.Valid=($v -match '^[\w.\-+]+@[\w.\-]+\.[a-zA-Z]{2,}$' -or (Test-CargoPhoneLike $v) -or (Test-CargoMessengerLike $v)) -and $scopeKey -eq $(if($FieldKey -eq 'supplier_contact'){'supplier'}else{'recipient'})}
        '^supplier_address$' {$r.Valid=(Test-CargoAddressLike $v) -and $scopeKey -eq 'supplier'}
        '^recipient_name$' {$r.Valid=($v -match "^[\p{L}][\p{L} .'-]{0,79}$" -and $scopeKey -eq 'recipient')}
        '^(goods_name|reference_images|buyer_conversation_identity)$' {$r.Valid=$true}
        default {$r.Valid=$false}
    }
    if($r.Valid){$r.Reason=''};return $r
}

# ============================================================================================
# 字段登记表 / 收集清单 / 报价必需项
# ============================================================================================

# 字段登记表（顺序即 Fields 的顺序，便于消费方稳定展示）。
#   Scope 是该字段的计量范围；Key 是逐字契约名。
function Get-CargoFieldSpecs {
    return @(
        [pscustomobject]@{ Key = 'goods_name';                 Label = '货物名称';              Unit = '';        Scope = 'goods' }
        [pscustomobject]@{ Key = 'reference_images';           Label = '参考图片';              Unit = '';        Scope = 'goods' }
        [pscustomobject]@{ Key = 'carton_count';               Label = '件数（箱/托盘）';       Unit = 'cartons'; Scope = 'cartons' }
        [pscustomobject]@{ Key = 'goods_count';                Label = '商品数量';              Unit = 'pcs';     Scope = 'goods' }
        [pscustomobject]@{ Key = 'count';                      Label = '数量（范围未明）';      Unit = '';        Scope = 'unknown' }
        [pscustomobject]@{ Key = 'unit_weight';                Label = '单件重量';              Unit = 'kg';      Scope = 'unit' }
        [pscustomobject]@{ Key = 'total_weight';               Label = '总重量';                Unit = 'kg';      Scope = 'total' }
        [pscustomobject]@{ Key = 'goods_weight';               Label = '商品净重';              Unit = 'kg';      Scope = 'goods' }
        [pscustomobject]@{ Key = 'weight';                     Label = '重量（范围未明）';      Unit = 'kg';      Scope = 'unknown' }
        [pscustomobject]@{ Key = 'unit_dimensions';            Label = '单件尺寸';              Unit = 'cm';      Scope = 'unit' }
        [pscustomobject]@{ Key = 'lot_dimensions';             Label = '整批尺寸';              Unit = 'cm';      Scope = 'lot' }
        [pscustomobject]@{ Key = 'goods_dimensions';           Label = '商品尺寸';              Unit = 'cm';      Scope = 'goods' }
        [pscustomobject]@{ Key = 'dimensions';                 Label = '尺寸（范围未明）';      Unit = 'cm';      Scope = 'unknown' }
        [pscustomobject]@{ Key = 'supplier_address';           Label = '供应商地址';            Unit = '';        Scope = 'supplier' }
        [pscustomobject]@{ Key = 'supplier_contact';           Label = '供应商联系方式';        Unit = '';        Scope = 'supplier' }
        [pscustomobject]@{ Key = 'recipient_name';             Label = '收货人名称';            Unit = '';        Scope = 'recipient' }
        [pscustomobject]@{ Key = 'recipient_contact';          Label = '收货人联系方式';        Unit = '';        Scope = 'recipient' }
        [pscustomobject]@{ Key = 'buyer_conversation_identity'; Label = '买家会话身份';         Unit = '';        Scope = 'buyer_conversation' }
        [pscustomobject]@{ Key = 'unassigned_contact';         Label = '联系方式（角色未明）';  Unit = '';        Scope = 'unknown' }
        [pscustomobject]@{ Key = 'delivery_address';           Label = '收货地址/可用报价目的地'; Unit = '';      Scope = 'destination' }
    )
}

# 标准收集清单（spec §3.2 表；CollectionComplete 判据，与 Ready 分开）。
function Get-CargoChecklistKeys {
    return @(
        'goods_name', 'reference_images', 'carton_count', 'unit_weight', 'unit_dimensions',
        'supplier_address', 'supplier_contact', 'recipient_name', 'recipient_contact', 'delivery_address'
    )
}

# 替代资料组合（spec §3.3）：清单项可由同义字段满足。
#   已明确给出总重时不再机械索要单件重量；整批尺寸可替代单件尺寸。
function Get-CargoChecklistProviders {
    return @{
        'goods_name'        = @('goods_name')
        'reference_images'  = @('reference_images')
        'carton_count'      = @('carton_count')
        'unit_weight'       = @('unit_weight', 'total_weight')
        'unit_dimensions'   = @('unit_dimensions', 'lot_dimensions')
        'supplier_address'  = @('supplier_address')
        'supplier_contact'  = @('supplier_contact')
        'recipient_name'    = @('recipient_name')
        'recipient_contact' = @('recipient_contact')
        'delivery_address'  = @('delivery_address')
    }
}

# 基本报价必需项（spec §3.2/§3.4 用户已确认：件数、重量、尺寸、收货地址）。
#   Providers = 能满足该项的字段（替代资料组合）；Fields = 参与冲突判断的字段；
#   Report = 该项未满足时写进 MissingFields 的字段键（消费方按字段键取用，例如
#            reply_policy 的 askKeyMap 把 unit_weight->weight、unit_dimensions->dimension）。
#   缺货物名称或图片不在此列：它们不阻挡 Basic quote readiness。
function Get-CargoRequiredCategories {
    return @(
        [pscustomobject]@{ Name = 'carton_count';     Report = 'carton_count';     Providers = @('carton_count');                   Fields = @('carton_count', 'count') }
        [pscustomobject]@{ Name = 'weight';           Report = 'unit_weight';      Providers = @('unit_weight', 'total_weight');    Fields = @('unit_weight', 'total_weight', 'weight') }
        [pscustomobject]@{ Name = 'dimensions';       Report = 'unit_dimensions';  Providers = @('unit_dimensions', 'lot_dimensions'); Fields = @('unit_dimensions', 'lot_dimensions', 'dimensions') }
        [pscustomobject]@{ Name = 'delivery_address'; Report = 'delivery_address'; Providers = @('delivery_address');                Fields = @('delivery_address') }
    )
}

# ============================================================================================
# 基础工具（纯函数）
# ============================================================================================

function Get-CargoMessageText($Message) {
    if (-not $Message) { return '' }
    $t = [string]$Message.Orig
    if ([string]::IsNullOrWhiteSpace($t)) { $t = [string]$Message.Text }
    return $t
}

# 已确认发送记录索引表：@(行) -> @{ <index> = $true }。键既按 Messages 下标匹配，也兼容 DomIndex。
function Test-CargoSentMatch($SentMatches, [int]$Index) {
    if (-not $SentMatches -or $Index -lt 0) { return $false }
    if ($SentMatches -is [System.Collections.IDictionary]) { return [bool]$SentMatches.Contains($Index) }
    $names = @($SentMatches.PSObject.Properties | ForEach-Object { $_.Name })
    return ($names -contains ([string]$Index))
}

# 证据分级：buyer / human / bot / unknown（见文件头）。
function Get-CargoEvidenceClass($Message, [int]$Index, $SentMatches) {
    if (-not $Message) { return 'unknown' }
    if ($Message.Role -eq 'buyer') { return 'buyer' }
    if ($Message.Role -ne 'me') { return 'unknown' }
    if (Test-CargoSentMatch $SentMatches $Index) { return 'bot' }
    if ($null -ne $Message.DomIndex -and (Test-CargoSentMatch $SentMatches ([int]$Message.DomIndex))) { return 'bot' }
    if ($Message.Source -eq 'bot') { return 'bot' }
    if ($Message.Source -eq 'human') { return 'human' }
    return 'unknown'
}

function Get-CargoWindow([string]$Text, [int]$Index, [int]$Length, [int]$Before = 60, [int]$After = 40) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $s = [Math]::Max(0, $Index - $Before)
    $e = [Math]::Min($Text.Length, $Index + $Length + $After)
    if ($e -le $s) { return '' }
    return $Text.Substring($s, $e - $s)
}

# 明确更正的语气标记（"sorry ... not 20" / "I mean" / "change ... to"）：只有带这类标记的不同值才算替换。
function Test-CargoCorrectionCue([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [bool]($Text -match "(?i)\b(sorry|apolog\w*|correction|corrected|i\s+mean|i\s+meant|instead|not\s+\d|change[ds]?|chang\w*\s+to|updat(e|ed)|revis(e|ed)|mistake|wrong|typo|actually|re-?send)\b|更正|改(为|成)|更正为|应该是|修正|不是|弄错|写错")
}

function ConvertTo-CargoNumber($Raw) {
    $s = ([string]$Raw).Trim()
    if (-not $s) { return $null }
    if ($s -match '^\d{1,3}(,\d{3})+(\.\d+)?$') { $s = $s -replace ',', '' }
    elseif ($s -match '^\d+,\d+$') { $s = $s -replace ',', '.' }
    $v = 0.0
    if (-not [double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
    return $v
}

function Format-CargoNumber($Value) {
    $v = [double]$Value
    $r = [Math]::Round($v, 6)
    return $r.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
}

function Add-CargoCandidate($Store, $Candidate) {
    if ($Candidate.Status -eq 'provided') {
        $valid = Test-CargoFieldValue $Candidate.Key $Candidate.Value $Candidate.Unit $Candidate.Scope
        if (-not $valid.Valid) { $Candidate.Status = 'needs_confirmation' }
        else { $Candidate.Value = $valid.Value; $Candidate.Unit = $valid.Unit; $Candidate.Scope = $valid.Scope }
    }
    if (-not $Candidate -or -not $Candidate.Key) { return }
    if (-not $Store.ContainsKey($Candidate.Key)) { $Store[$Candidate.Key] = New-Object System.Collections.ArrayList }
    [void]$Store[$Candidate.Key].Add($Candidate)
}

function Test-CargoSpanOverlap([int]$Index, [int]$Length, $Spans) {
    if (-not $Spans) { return $false }
    $end = $Index + $Length
    foreach ($sp in @($Spans)) {
        if ($end -le $sp.Start -or $Index -ge $sp.End) { continue }
        return $true
    }
    return $false
}

# ============================================================================================
# 重量：区分单件（运输外包装）/ 整批总重 / 商品净重（spec §3.1-§3.2）
# ============================================================================================

$script:CargoWeightUnitFactor = @{
    'kg' = 1.0; 'kgs' = 1.0; 'kilo' = 1.0; 'kilos' = 1.0; 'kilogram' = 1.0; 'kilograms' = 1.0
    'g' = 0.001; 'gr' = 0.001; 'gram' = 0.001; 'grams' = 0.001
    'ton' = 1000.0; 'tons' = 1000.0; 'tonne' = 1000.0; 'tonnes' = 1000.0; 'mt' = 1000.0
    'lb' = 0.45359237; 'lbs' = 0.45359237; 'pound' = 0.45359237; 'pounds' = 0.45359237
    '公斤' = 1.0; '千克' = 1.0; '吨' = 1000.0; '斤' = 0.5
}

$script:CargoWeightPattern = '(?i)(?<![\d.+-])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s*(kilograms?|kilos?|kgs?|grams?|gr|g|tonnes?|tons?|mt|lbs?|pounds?|公斤|千克|吨|斤)(?![\w])'

function Get-CargoWeightScope([string]$Text, [int]$Index, [int]$Length) {
    $win = Get-CargoWindow $Text $Index $Length 60 40
    $pre = Get-CargoWindow $Text $Index 0 30 0
    if ($win -match '(?i)\bnet\s+weight\b|\bnetto\b|\b(goods|product|item|actual)\s+weight\b|净重|商品重量|产品重量') { return 'goods' }
    if ($win -match '(?i)\b(total|overall|gross)\s+weight\b|\bweight\s+in\s+total\b|\bin\s+total\b|\baltogether\b|总重|总重量|一共|总共|合计|整批') { return 'total' }
    if ($pre -match '(?i)(?<![a-z])(total|overall|gross)\s*(weight)?\s*[:：]\s*$') { return 'total' }
    # [2026-10-05 spec §4.2 第 3 条] "216 kg gross" / "216 kg total"：量词在后、限定词在后的写法
    #   同样明确表示整批总重（旧实现只认 "gross weight" 这种限定词在前的写法，于是把它判成范围不明，
    #   报价准备度因此把它算成"重量未提供"，与用户已确认的"已明确总重"口径不一致）。
    $post = Get-CargoWindow $Text ($Index + $Length) 24 0
    if ($post -match '(?i)^\s*(gross|total|overall|in\s+total|altogether)\b') { return 'total' }
    # [独立复核 R02] 外包装范围必须有运输外包装证据：箱/托盘/包等包装名词或明确的 each/per 包装修饰，
    #   不能只凭裸 each/per 就把商品件重当成包装重量（spec §3.3）。
    if ($win -match '(?i)\bper\s+(carton|box|pallet|case|crate|ctn|package|drum|bundle|container|set)\b|\b(unit|box|carton|pallet)\s+weight\b|\bweight\s+per\s+(carton|box|pallet|case|crate|package|container)\b|/\s*(carton|box|pallet|case|crate|ctn|package)\b|每箱|每托|箱重') { return 'unit' }
    if ($win -match '(?i)\beach\s+(carton|box|pallet|case|crate|ctn|package|drum|bundle|container|set)s?\b|\b(each|every)\s+of\s+the\s+(cartons|boxes|pallets|cases|crates|packages)\b|\b(box|carton|pallet|case|crate|package)s?\b[^.\r\n]{0,24}\bweigh') { return 'unit' }
    # 商品件重/净重（each item / per piece / 商品重量）是产品范围，不能满足包装重量，需要核实包装范围。
    if ($win -match '(?i)\b(each|per|every)\s+(item|product|article|piece|pc|pcs|pair|bottle|bag|unit)s?\b|\b(product|item|article|piece|unit)s?\s+weight\b|商品重量|产品重量|净重') { return 'goods' }
    return 'unknown'
}

function Get-CargoWeightCandidates([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    foreach ($m in [regex]::Matches($Text, $script:CargoWeightPattern)) {
        $num = ConvertTo-CargoNumber $m.Groups[1].Value
        if ($null -eq $num) { continue }
        $unitRaw = $m.Groups[2].Value.ToLowerInvariant()
        $factor = 1.0
        if ($script:CargoWeightUnitFactor.ContainsKey($unitRaw)) { $factor = [double]$script:CargoWeightUnitFactor[$unitRaw] }
        $kg = [Math]::Round($num * $factor, 6)
        $scope = Get-CargoWeightScope $Text $m.Index $m.Length
        $key = 'weight'
        if ($scope -eq 'unit') { $key = 'unit_weight' }
        elseif ($scope -eq 'total') { $key = 'total_weight' }
        elseif ($scope -eq 'goods') { $key = 'goods_weight' }
        $status = 'needs_confirmation'
        if ($scope -ne 'unknown') { $status = 'provided' }
        $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80)
        [void]$out.Add(@{
            Key = $key; Value = $kg; Unit = 'kg'; Scope = $scope; Status = $status
            Display = $m.Value.Trim(); MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $cue
        })
    }
    return @($out.ToArray())
}

# ============================================================================================
# 尺寸：区分单件（运输外包装）/ 商品本身 / 整批（spec §3.1-§3.2）
# ============================================================================================

$script:CargoDimUnitPattern = '(?:(毫米|mm|厘米|cm|米|m|inches|inch|in|")(?:s)?)?'

function Get-CargoDimensionScope([string]$Text, [int]$Index, [int]$Length) {
    $win = Get-CargoWindow $Text $Index $Length 70 50
    if ($win -match '(?i)\b(product|item|goods|article)\s*(size|dimensions?)\b|\b(goods|product|item)\s+itself\b|\bunpacked\b|商品尺寸|产品尺寸|单个产品|裸装') { return 'goods' }
    if ($win -match '(?i)\b(total|overall)\s+(dimensions?|size)\b|\bwhole\s+(lot|shipment|consignment|order)\b|\bin\s+total\b|整批|整柜尺寸') { return 'lot' }
    if ($win -match '(?i)\bper\s+(carton|box|pallet|piece|pc|unit|case|crate)\b|\beach\b|/\s*(carton|box|pallet|piece|pc|unit|ctn)\b|\b(box|carton|pallet|packed|packaging|outer|master)\s*(size|dimensions?)\b|\bdimensions?\s+(per|of\s+each)\b|每箱|每托|单件|外箱|箱规') { return 'unit' }
    # 同一条消息本身在说外包装（箱/托盘/已包装）：按用户已确认的口径，单件 = 运输外包装。
    if ($win -match '(?i)\b(box|boxes|carton|cartons|ctn|ctns|pallet|pallets|case|cases|crate|crates|packed|packing|packaging|package|packages|outer)\b|箱|托盘|外包装') { return 'unit' }
    return 'unknown'
}

function Get-CargoDimensionCandidates([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $spans = New-Object System.Collections.ArrayList
    # 三维：长 x 宽 x 高（单位可省略，省略时按 cm 处理并记录在 Unit 上）
    $re3 = '(?<![\d.+-])(\d+(?:\.\d+)?)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*' + $script:CargoDimUnitPattern + '(?![\w])'
    foreach ($m in [regex]::Matches($Text, $re3)) {
        $unit = ''
        if ($m.Groups[4].Success) { $unit = Get-CargoLengthUnit $m.Groups[4].Value }
        $axes = @([double]$m.Groups[1].Value, [double]$m.Groups[2].Value, [double]$m.Groups[3].Value)
        $scope = Get-CargoDimensionScope $Text $m.Index $m.Length
        $key = 'dimensions'
        if ($scope -eq 'unit') { $key = 'unit_dimensions' }
        elseif ($scope -eq 'lot') { $key = 'lot_dimensions';$scope='packed_lot' }
        elseif ($scope -eq 'goods') { $key = 'goods_dimensions' }
        [void]$spans.Add(@{ Start = $m.Index; End = $m.Index + $m.Length })
        $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80)
        [void]$out.Add(@{
            Key = $key; Value = ((Format-CargoNumber $axes[0]) + 'x' + (Format-CargoNumber $axes[1]) + 'x' + (Format-CargoNumber $axes[2]))
            Unit = $unit; Scope = $scope; Status = 'provided'; Axes = @($axes)
            Display = $m.Value.Trim(); MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $cue
        })
    }
    # 两维：必须紧跟长度单位，避免把 "10 x 20" 之类的数字串当尺寸；只有两个边长不足以算体积。
    $re2 = '(?<![\d.+-])(\d+(?:\.\d+)?)\s*[x×*]\s*(\d+(?:\.\d+)?)\s*(mm|cm|m|inches|inch|")(?:s)?(?![\w])'
    foreach ($m in [regex]::Matches($Text, $re2)) {
        if (Test-CargoSpanOverlap $m.Index $m.Length $spans) { continue }
        $unit = Get-CargoLengthUnit $m.Groups[3].Value
        $scope = Get-CargoDimensionScope $Text $m.Index $m.Length
        $key = 'dimensions'
        if ($scope -eq 'unit') { $key = 'unit_dimensions' }
        elseif ($scope -eq 'lot') { $key = 'lot_dimensions' }
        elseif ($scope -eq 'goods') { $key = 'goods_dimensions' }
        [void]$spans.Add(@{ Start = $m.Index; End = $m.Index + $m.Length })
        $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80)
        [void]$out.Add(@{
            Key = $key; Value = ((Format-CargoNumber ([double]$m.Groups[1].Value)) + 'x' + (Format-CargoNumber ([double]$m.Groups[2].Value)))
            Unit = $unit; Scope = $scope; Status = 'needs_confirmation'; Axes = @([double]$m.Groups[1].Value, [double]$m.Groups[2].Value)
            Display = $m.Value.Trim(); MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $cue
        })
    }
    return @($out.ToArray())
}

function Get-CargoLengthUnit([string]$Raw) {
    $u = ([string]$Raw).Trim().ToLowerInvariant()
    if ($u -eq 'mm' -or $u -eq '毫米') { return 'mm' }
    if ($u -eq 'm' -or $u -eq '米') { return 'm' }
    if ($u -eq 'inch' -or $u -eq 'inches' -or $u -eq '"') { return 'inch' }
    return 'cm'
}

# 体积换算除数（长宽高按该单位相乘后除以除数得到 m³）；inch 不在此表内（换算不是整除，避免伪造公式）。
function Get-CargoVolumeDivisor([string]$Unit) {
    switch ([string]$Unit) {
        'cm' { return 1000000.0 }
        'mm' { return 1000000000.0 }
        'm'  { return 1.0 }
    }
    return 0.0
}

# ============================================================================================
# 数量：包装件数（箱/托盘）与商品个数分开（spec §3.1-§3.2）
# ============================================================================================

$script:CargoPackWords = 'cartons?|ctns?|boxes?|pallets?|skids?|cases?|crates?|packages?|packs?|drums?|rolls?'
$script:CargoPieceWords = 'pcs?|pieces?|units?|sets?|pairs?|items?'

function Get-CargoCountCandidates([string]$Text, $DimensionSpans, $WeightSpans = $null) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $patterns = @(
        @{ Re = ('(?i)(?<![\d.,+-])(\d{1,3}(?:,\d{3})+|\d+)\s*(' + $script:CargoPackWords + ')(?![\w])'); NumGroup = 1; Scope = 'cartons' }
        @{ Re = ('(?i)\b(' + $script:CargoPackWords + ')\b\s*(?:[:：]|x|×|\*)?\s*(\d{1,3}(?:,\d{3})+|\d+)(?![\w])'); NumGroup = 2; Scope = 'cartons' }
        @{ Re = ('(?i)(?<![\d.,+-])(\d{1,3}(?:,\d{3})+|\d+)\s*(' + $script:CargoPieceWords + ')(?![\w])'); NumGroup = 1; Scope = 'goods' }
        @{ Re = '(?i)\b(quantity|qty|number\s+of|count|amount)\b\s*(?:is|are|:)?\s*(\d{1,3}(?:,\d{3})+|\d+)(?![\w])'; NumGroup = 2; Scope = 'unknown' }
        @{ Re = '(\d+)\s*(箱|托盘|卡板)'; NumGroup = 1; Scope = 'cartons' }
        @{ Re = '(箱数|件数)\s*[:：]?\s*(\d+)'; NumGroup = 2; Scope = 'cartons' }
        @{ Re = '(\d+)\s*(个|件|台|只|条)'; NumGroup = 1; Scope = 'goods' }
        @{ Re = '(数量|总数量)\s*[:：]?\s*(\d+)'; NumGroup = 2; Scope = 'unknown' }
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Text, [string]$p.Re)) {
            $g = $m.Groups[[int]$p.NumGroup]
            if (-not $g.Success) { continue }
            if (Test-CargoSpanOverlap $g.Index $g.Length $DimensionSpans) { continue }
            # [2026-10-05 spec §6.2 同源问题] "packed weight per carton 47 kg" 里的 47 是**重量**，
            #   不是件数。件数候选不得落在重量数字的范围内，否则同一句话既给出单件重量又"给出"
            #   47 箱，与后面的真实箱数冲突（实测：合成附件证据行因此把 carton_count 判成 conflict）。
            if ($WeightSpans -and (Test-CargoSpanOverlap $g.Index $g.Length $WeightSpans)) { continue }
            $num = ConvertTo-CargoNumber $g.Value
            if ($null -eq $num) { continue }
            $key = 'count'
            if ($p.Scope -eq 'cartons') { $key = 'carton_count' }
            elseif ($p.Scope -eq 'goods') { $key = 'goods_count' }
            $status = 'needs_confirmation'
            if ($p.Scope -ne 'unknown') { $status = 'provided' }
            [void]$out.Add(@{
                Key = $key; Value = $num; Unit = $(if ($key -eq 'carton_count') { 'cartons' } elseif ($key -eq 'goods_count') { 'pcs' } else { '' })
                Scope = $p.Scope; Status = $status; Display = $m.Value.Trim()
                MatchIndex = $m.Index; MatchLength = $m.Length
                Cue = (Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80))
            })
        }
    }
    return @($out.ToArray())
}

# ============================================================================================
# 联系方式：按业务角色分字段（spec §1.1 / §3.4 红线）
#   recipient_contact 收货人｜supplier_contact 供应商｜buyer_conversation_identity 买家会话身份（只是记录）
# ============================================================================================

$script:CargoRecipientRoleRe = '(?i)\b(consignee|recipient|receiver|receiving\s+contact|delivery\s+contact|收货人|收件人|接收人)\b'
$script:CargoSupplierRoleRe  = '(?i)\b(supplier|vendor|factory|manufacturer|proveedor|fornecedor|供应商|工厂|厂家)\b'
$script:CargoEmailRe = '(?<![\w.+-])[\w.\-+]+@[\w.\-]+\.[A-Za-z]{2,}(?![\w])'
$script:CargoMessengerRe = '(?i)\b(whatsapp|wechat|weixin|skype|telegram|viber)\b\s*(?:id|number|no\.?|account)?\s*(?:is|are|:)?\s*([^\r\n,;]{4,40})'
$script:CargoPhoneRe = '(?<![\w])(?:\+\d{1,3}[\s\-]?)?(?:\(?\d{2,4}\)?[\s\-]?){2,4}\d{2,4}(?![\w])'

function Test-CargoPhoneLike([string]$Raw) {
    $s = ([string]$Raw).Trim()
    if (-not $s) { return $false }
    $digits = ($s -replace '\D', '')
    if ($digits.Length -lt 7 -or $digits.Length -gt 15) { return $false }
    if ($s -match '^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$') { return $false }
    if ($s.StartsWith('+')) { return $true }
    if ($digits.Length -ge 8 -and ($s -match '[\s\-\(\)]')) { return $true }
    return $false
}

function Test-CargoMessengerLike([string]$Raw) {
    $s = ([string]$Raw).Trim()
    if (-not $s) { return $false }
    $digits = ($s -replace '\D', '')
    if ($digits.Length -ge 5) { return $true }
    if ($s -match '^[\w\.\-@\+]{5,}$') { return $true }
    return $false
}

# 角色归属：优先取联系方式之前最近的业务角色词；其次看之后紧邻的角色词；再次看第一人称自述。
function Resolve-CargoContactRole([string]$Text, [int]$Index, $RoleHits) {
    $best = ''
    $bestDist = 1000
    foreach ($h in @($RoleHits)) {
        if ($h.Index -ge $Index) { continue }
        $dist = $Index - ($h.Index + $h.Length)
        if ($dist -lt 0 -or $dist -gt 80) { continue }
        if ($dist -lt $bestDist) { $bestDist = $dist; $best = [string]$h.Kind }
    }
    if ($best) { return $best }
    $bestDist = 1000
    foreach ($h in @($RoleHits)) {
        if ($h.Index -lt $Index) { continue }
        $dist = $h.Index - $Index
        if ($dist -gt 40) { continue }
        if ($dist -lt $bestDist) { $bestDist = $dist; $best = [string]$h.Kind }
    }
    if ($best) { return $best }
    $pre = Get-CargoWindow $Text $Index 0 45 0
    if ($pre -match "(?i)\bmy\b|\bmine\b|\bcall\s+me\b|\breach\s+me\b|\btext\s+me\b|\bcontact\s+me\b|我的|联系我|打我") { return 'buyer' }
    return ''
}

function Get-CargoContactCandidates([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $roles = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Text, $script:CargoRecipientRoleRe)) { [void]$roles.Add(@{ Kind = 'recipient'; Index = $m.Index; Length = $m.Length }) }
    foreach ($m in [regex]::Matches($Text, $script:CargoSupplierRoleRe)) { [void]$roles.Add(@{ Kind = 'supplier'; Index = $m.Index; Length = $m.Length }) }
    $spans = New-Object System.Collections.ArrayList
    $found = New-Object System.Collections.ArrayList

    foreach ($m in [regex]::Matches($Text, $script:CargoMessengerRe)) {
        $val = ([string]$m.Groups[2].Value).Trim()
        $val = $val.TrimEnd('.', ',', ';', '!', '?', ')', ']')
        if (-not (Test-CargoMessengerLike $val)) { continue }
        [void]$found.Add(@{ Index = $m.Index; Length = $m.Length; Value = $val })
        [void]$spans.Add(@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
    foreach ($m in [regex]::Matches($Text, $script:CargoEmailRe)) {
        if (Test-CargoSpanOverlap $m.Index $m.Length $spans) { continue }
        [void]$found.Add(@{ Index = $m.Index; Length = $m.Length; Value = $m.Value.Trim() })
        [void]$spans.Add(@{ Start = $m.Index; End = $m.Index + $m.Length })
    }
    foreach ($m in [regex]::Matches($Text, $script:CargoPhoneRe)) {
        if (Test-CargoSpanOverlap $m.Index $m.Length $spans) { continue }
        $val = $m.Value.Trim()
        if (-not (Test-CargoPhoneLike $val)) { continue }
        [void]$found.Add(@{ Index = $m.Index; Length = $m.Length; Value = $val })
        [void]$spans.Add(@{ Start = $m.Index; End = $m.Index + $m.Length })
    }

    foreach ($f in @($found.ToArray() | Sort-Object { $_.Index })) {
        $kind = Resolve-CargoContactRole $Text ([int]$f.Index) $roles
        $key = 'unassigned_contact'
        $status = 'needs_confirmation'
        $scope = 'unknown'
        if ($kind -eq 'recipient') { $key = 'recipient_contact'; $status = 'provided'; $scope = 'recipient' }
        elseif ($kind -eq 'supplier') { $key = 'supplier_contact'; $status = 'provided'; $scope = 'supplier' }
        elseif ($kind -eq 'buyer') { $key = 'buyer_conversation_identity'; $status = 'provided'; $scope = 'buyer_conversation' }
        $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $f.Index $f.Length 80 80)
        [void]$out.Add(@{
            Key = $key; Value = [string]$f.Value; Unit = ''; Scope = $scope; Status = $status
            Display = [string]$f.Value; MatchIndex = $f.Index; MatchLength = $f.Length; Cue = $cue
        })
    }
    return @($out.ToArray())
}

# 收货人姓名：必须有收货角色措辞，不能把买家自称或泛化 contact 当收货人（spec §2.2/§3.4）。
$script:CargoNameStopWords = @(
    'contact', 'contacts', 'phone', 'number', 'numbers', 'address', 'details', 'detail', 'info',
    'information', 'name', 'whatsapp', 'email', 'mail', 'tel', 'mobile', 'cell', 'will', 'can',
    'the', 'my', 'our', 'your', 'his', 'her', 'their', 'is', 'are', 'and', 'at', 'to', 'for',
    'not', 'no', 'unknown', 'pending', 'later', 'same', 'below', 'above', 'company', 'limited', 'ltd',
    'consignee', 'recipient', 'receiver', 'supplier', 'vendor', 'factory', 'whatsapp', 'wechat'
)

function Get-CargoRecipientNameCandidates([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $patterns = @(
        '(?i)\b(consignee|recipient|receiver)(?:''s)?\s*(?:name)?\s*[:：]?\s*(?:is|are)?\s*([A-Za-z][A-Za-z\.\-'']{1,29}(?:\s+[A-Za-z][A-Za-z\.\-'']{1,29}){0,2})'
        '(收货人|收件人)\s*(?:姓名|名字)?\s*[:：]?\s*([\u4e00-\u9fa5]{2,6})'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Text, $p)) {
            $val = ([string]$m.Groups[2].Value).Trim()
            $val = $val.TrimEnd('.', ',', ';', ':', '!', '?')
            if (-not $val) { continue }
            # 只保留从第一个 token 开始、遇到停用词为止的名字（"John Smith and his contact" -> "John Smith"）。
            $tokens = @($val -split '\s+')
            $keep = New-Object System.Collections.ArrayList
            foreach ($tk in $tokens) {
                $rawTok = [string]$tk
                $cleanTok = $rawTok.Trim('.', ',', ';', ':', '!', '?')
                if (-not $cleanTok) { break }
                if ($script:CargoNameStopWords -contains $cleanTok.ToLowerInvariant()) { break }
                [void]$keep.Add($cleanTok)
                if ($rawTok -match '[.,;:!?]$') { break }
            }
            if ($keep.Count -eq 0) { continue }
            $val = (@($keep.ToArray()) -join ' ')
            if ($val -match '(?i)^(consignee|recipient|receiver|supplier|vendor|factory)$') { continue }
            $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80)
            [void]$out.Add(@{
                Key = 'recipient_name'; Value = $val; Unit = ''; Scope = 'recipient'; Status = 'provided'
                Display = $val; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $cue
            })
        }
    }
    return @($out.ToArray())
}

# 供应商地址：角色措辞 + 地址词紧邻。它进 supplier_address，绝不能当收货地址（spec §3.2/§3.4）。
function Test-CargoAddressLike([string]$Raw) {
    $s = ([string]$Raw).Trim()
    if ($s.Length -lt 6) { return $false }
    if ($s -match '(?i)^(unknown|not\s+sure|no\s+idea|n/?a|tbd|pending|same\s+as)') { return $false }
    if ($s -match '\d') { return $true }
    if ($s -match '(?i)\b(street|road|avenue|blvd|boulevard|lane|drive|rd|st|ave|ln|dr|way|hwy)\b') { return $true }
    return $false
}

function Get-CargoSupplierAddressCandidates([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $patterns = @(
        '(?i)\b(?:supplier|vendor|factory|manufacturer|供应商|工厂|厂家)\b\s*(?:''s)?\s*(?:(?:factory|warehouse|office|pickup)\s+)?(?:address|地址)\s*[:：]?\s*([^.!?\r\n]{4,120})'
        '(?i)\b(?:address|地址)\s*(?:of|for)\s*(?:the\s+)?(?:our\s+)?(?:supplier|vendor|factory|供应商|工厂)\s*[:：]?\s*([^.!?\r\n]{4,120})'
    )
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Text, $p)) {
            $val = ([string]$m.Groups[1].Value).Trim()
            $val = $val -replace '^(?i)(is|are|at|in|:|=|是|在)\s+', ''
            $val = ($val -split '(?i)\b(?:Shipping|Total Boxes|Total Weight|Box Dimensions|Box Weight|Cartons|Delivery Method)\s*[:：]')[0]
            $val = (($val -replace '\?{2,}|<br\s*/?>', ' ') -replace '\s+', ' ').Trim()
            if ($val.Length -gt 120) { $val = $val.Substring(0, 120).Trim() }
            if (-not (Test-CargoAddressLike $val)) { continue }
            $cue = Test-CargoCorrectionCue (Get-CargoWindow $Text $m.Index $m.Length 80 80)
            [void]$out.Add(@{
                Key = 'supplier_address'; Value = $val; Unit = ''; Scope = 'supplier'; Status = 'provided'
                Display = $val; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $cue
            })
        }
    }
    return @($out.ToArray())
}

# ============================================================================================
# 货物名称与参考图片（清单项；缺失不阻挡 Basic quote readiness）
# ============================================================================================

$script:CargoGoodsNameWords = 'card\s+holder|cardholder|treadmill|monitor|printer|furniture|appliance|charger|cable|phone|solar|battery|pump|valve|motor|engine|paint|chemical|cartridge|filter|lamp|camera|speaker|headphone|keyboard|laptop|tablet|router|modem|generator|compressor|scanner|sensor|controller|adapter|transformer|converter|inverter|drone|tractor|forklift|conveyor|drum|tank|rack|shelf|stand|power\s+bank|powerbank|machine|tool|kit|textile|fabric|garment|toy|bottle|cup|plate|chair|table|glass|steel|pipe|fitting|bearing|gear|belt|hose|wire|socket|switch|panel|module|board|chip|display|screen'

function Clean-CargoGoodsName([string]$Raw) {
    $s = ([string]$Raw).Trim()
    if (-not $s) { return '' }
    foreach ($sep in @('.', '。', '!', '!', '?', '？', ';', '；', ',', '，')) {
        $i = $s.IndexOf($sep)
        if ($i -gt 0) { $s = $s.Substring(0, $i) }
    }
    for ($k = 0; $k -lt 3; $k++) {
        $n = $s -replace "^(?i)(contains|containing|have|has|with|for|the|a|an|is|are|need|want|we|i|it|its|it's|it’s|this|these|please|and|of|to|on|in|our|my)\s+", ''
        if ($n -eq $s) { break }
        $s = $n
    }
    $s = ($s -replace '\s+', ' ').Trim()
    $s = $s.TrimEnd('.', ',', ';', ':', '!', '?', '-')
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60).Trim() }
    return $s
}

function Get-CargoGoodsNameCandidate([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, 'product-detail/([^\s/?]+)')
    if ($m.Success) {
        $title = [string]$m.Groups[1].Value
        $title = $title -replace '\.html$', ''
        $title = $title -replace '-\d+$', ''
        $title = $title -replace '-', ' '
        $title = Clean-CargoGoodsName $title
        if ($title) { return @{ Key = 'goods_name'; Value = $title; Unit = ''; Scope = 'goods'; Status = 'provided'; Display = $title; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $false } }
    }
    $m = [regex]::Match($Text, '(?i)\b(?:product|item|goods|cargo|commodity)\s*name\s*[:：]\s*([^\r\n]{2,60})')
    if ($m.Success) {
        $val = Clean-CargoGoodsName $m.Groups[1].Value
        if ($val) { return @{ Key = 'goods_name'; Value = $val; Unit = ''; Scope = 'goods'; Status = 'provided'; Display = $val; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $false } }
    }
    $m = [regex]::Match($Text, "(?i)\b(?:it'?s|it\s+is|this\s+is|these\s+are|that'?s|the\s+product\s+is|the\s+item\s+is|the\s+goods\s+are)\s+(?:a|an|the)?\s*((?:" + $script:CargoGoodsNameWords + ")[\w\s\-']{0,30})")
    if ($m.Success) {
        $val = Clean-CargoGoodsName $m.Groups[1].Value
        if ($val) { return @{ Key = 'goods_name'; Value = $val; Unit = ''; Scope = 'goods'; Status = 'provided'; Display = $val; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $false } }
    }
    $m = [regex]::Match($Text, '(?i)\b(' + $script:CargoGoodsNameWords + ')\b')
    if ($m.Success) {
        $val = Clean-CargoGoodsName $m.Groups[1].Value
        if ($val) { return @{ Key = 'goods_name'; Value = $val; Unit = ''; Scope = 'goods'; Status = 'provided'; Display = $val; MatchIndex = $m.Index; MatchLength = $m.Length; Cue = $false } }
    }
    return $null
}

# ============================================================================================
# 承诺（promised）：买家说稍后提供 ⇒ 保留缺口，本轮不重复追问同一字段
# ============================================================================================

function Test-CargoPromiseFields([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $future = [bool]($Text -match "(?i)\b(will|gonna|going\s+to|i'll|i\s+will|we'll|let\s+me|as\s+soon\s+as|tomorrow|later|next\s+week|shortly|soon|afterwards)\b|稍后|晚点|明天|回头|待会|稍等")
    if (-not $future) { return @() }
    if ($Text -match '(?i)\b(weight|weights|kg|kgs|kilos?|kilograms?)\b|重量|公斤|千克') { [void]$out.Add('weight') }
    if ($Text -match '(?i)\b(dimensions?|sizes?|measurements?|specs?|cbm)\b|尺寸|体积') { [void]$out.Add('dimensions') }
    if ($Text -match "(?i)\b(cartons?|boxes?|pallets?|ctns?|quantities|quantity|qty|number\s+of\s+(cartons?|boxes?|pallets?))\b|件数|箱数|数量") { [void]$out.Add('count') }
    if ($Text -match '(?i)\b(images?|photos?|pictures?|pics?)\b|图片|照片') { [void]$out.Add('images') }
    if ($Text -match '(?i)\b(supplier|vendor|factory)\b[^.!?]{0,30}\b(contact|details|number|email|whatsapp)\b|供应商[^。！？]{0,10}(联系|电话|邮箱)') { [void]$out.Add('supplier_contact') }
    return @($out.ToArray())
}

# 承诺类别 -> 落点字段（清单字段 + 范围未明占位字段，两边都能被消费方读到）。
function Get-CargoPromiseTargets([string]$Category) {
    switch ([string]$Category) {
        'weight'     { return @('unit_weight', 'weight') }
        'dimensions' { return @('unit_dimensions', 'dimensions') }
        'count'      { return @('carton_count', 'count') }
        'images'     { return @('reference_images') }
        'supplier_contact' { return @('supplier_contact') }
    }
    return @()
}

# ============================================================================================
# 目的地（复用权威实现，不写第二套解析）
# ============================================================================================

function Find-CargoMessageIndexByStableId($Messages, [string]$StableId) {
    if (-not $StableId) { return -1 }
    for ($i = 0; $i -lt @($Messages).Count; $i++) {
        if ([string]$Messages[$i].StableId -eq $StableId) { return $i }
    }
    return -1
}

function Find-CargoDestinationSourceIndex($Conversation, $Destination) {
    if (-not $Conversation -or -not $Destination) { return -1 }
    $needle = ''
    if ($Destination.WarehouseCode) { $needle = [string]$Destination.WarehouseCode }
    elseif ($Destination.PostalAddress) { $needle = [string]$Destination.PostalAddress }
    if (-not $needle) { return -1 }
    $n = (($needle -replace '\s+', ' ').Trim()).ToLowerInvariant()
    if ($n.Length -gt 24) { $n = $n.Substring(0, 24) }
    $msgs = @($Conversation.Messages)
    for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
        $m = $msgs[$i]
        if (-not $m -or $m.IsSystemCard) { continue }
        if ($m.Role -ne 'buyer' -and $m.Source -ne 'human') { continue }
        $t = ((Get-CargoMessageText $m) -replace '\s+', ' ').ToLowerInvariant()
        if ($t.Contains($n)) { return $i }
    }
    return -1
}

# 目的仓更正（"change warehouse to ONT8"）：用权威实现对"这条消息之前"的会话取旧值，保留历史证据。
function Get-CargoDestinationCorrection($Conversation, $Destination, [int]$SourceIndex) {
    if (-not $Conversation -or -not $Destination -or -not $Destination.QuoteUsable -or $SourceIndex -le 0) { return $null }
    $msgs = @($Conversation.Messages)
    if ($SourceIndex -ge $msgs.Count) { return $null }
    $text = Get-CargoMessageText $msgs[$SourceIndex]
    if (-not (Test-CargoCorrectionCue $text)) { return $null }
    $priorLines = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $SourceIndex; $i++) { [void]$priorLines.Add([string]$msgs[$i].RawLine) }
    if ($priorLines.Count -eq 0) { return $null }
    $prior = Get-QuoteDestination (ConvertTo-MessageList (($priorLines.ToArray()) -join [string][char]10))
    if (-not $prior -or -not $prior.QuoteUsable) { return $null }
    if ([string]$prior.DisplayName -eq [string]$Destination.DisplayName) { return $null }
    return @{ Key = 'delivery_address'; From = [string]$prior.DisplayName; To = [string]$Destination.DisplayName; SourceIndex = $SourceIndex }
}

# ============================================================================================
# 主函数：Get-CargoFacts
# ============================================================================================

# 冲突候选的结构化形态：值、单位、范围与来源引用（消息身份/任务记录身份）。
function New-CargoConflictCandidate($Spec, $Candidate) {
    $refs = New-Object System.Collections.ArrayList
    if ($Candidate -and $Candidate.Evidence) {
        $ev = $Candidate.Evidence
        $mid = ''
        if ($ev -is [System.Collections.IDictionary]) { if ($ev.Contains('MessageId')) { $mid = [string]$ev['MessageId'] } }
        elseif ($ev.PSObject.Properties.Name -contains 'MessageId') { $mid = [string]$ev.MessageId }
        $src = ''
        if ($ev -is [System.Collections.IDictionary]) { if ($ev.Contains('Source')) { $src = [string]$ev['Source'] } }
        elseif ($ev.PSObject.Properties.Name -contains 'Source') { $src = [string]$ev.Source }
        if ($mid) { [void]$refs.Add(('message:' + $mid)) }
        if ($src) { [void]$refs.Add(('source:' + $src)) }
    }
    if ($Candidate -and $null -ne $Candidate.Index -and [int]$Candidate.Index -ge 0) { [void]$refs.Add(('index:' + [string][int]$Candidate.Index)) }
    return @{
        Value      = [string]$Candidate.Value
        Unit       = [string]$Candidate.Unit
        Scope      = [string]$Candidate.Scope
        FieldKey   = [string]$Spec.Key
        SourceRefs = @($refs.ToArray() | Select-Object -Unique)
    }
}

function Get-CargoFacts {
    [CmdletBinding()]
    param(
        $Conversation,
        $SentMatches = $null,
        # [2026-10-05 第三轮 spec §5.4] 已验证的**任务确认资料**（由最小共享适配层从人工任务存储导出）。
        #   事实引擎保持纯计算：它只消费调用方显式传入的证据，绝不自己去读任务文件。
        $TaskEvidence = @()
    )

    $specs = Get-CargoFieldSpecs
    $candidates = @{}
    foreach ($s in $specs) { $candidates[$s.Key] = New-Object System.Collections.ArrayList }

    $clarifications = New-Object System.Collections.ArrayList
    $conflicts = New-Object System.Collections.ArrayList
    $corrections = New-Object System.Collections.ArrayList
    $promised = @{}          # 落点字段 -> @{ Index; Ts; Text }
    $supplierAddrMsgs = @{}  # 供应商地址语句所在消息下标（不参与收货目的地解析）

    $messages = @()
    if ($Conversation -and ($Conversation.PSObject.Properties.Name -contains 'Messages')) { $messages = @($Conversation.Messages) }
    if ($Conversation -and $Conversation.PSObject.Properties.Name -contains 'CargoFlowRef' -and $Conversation.CargoFlowRef) {
        $flow=$Conversation.CargoFlowRef
        $messages=@($messages | Where-Object {
            $m=$_;$sha=[Security.Cryptography.SHA1]::Create()
            try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$m.Orig))) -replace '-','').ToLowerInvariant()}finally{$sha.Dispose()}
            @($flow.CurrentContextRefs|Where-Object {$_.MessageId -eq $m.StableId -or $_.Hash -eq $hash}).Count -gt 0
        })
        $Conversation=ConvertTo-MessageList ((@($messages|ForEach-Object {$_.RawLine})) -join [string][char]10)
    }

    for ($i = 0; $i -lt $messages.Count; $i++) {
        $m = $messages[$i]
        if (-not $m -or $m.IsSystemCard) { continue }
        $cls = Get-CargoEvidenceClass $m $i $SentMatches
        # 机器人复述 / 来源不明：不产生任何事实（spec §2.2 / §3.1）。
        if ($cls -ne 'buyer' -and $cls -ne 'human') { continue }

        $text = Get-CargoMessageText $m
        $ts = [string]$m.MessageTsRaw
        $ev = @{ Source = $cls; Text = [string]$m.Orig; MessageId = [string]$m.StableId }

        if ($m.HasImage -and $cls -eq 'buyer') {
            Add-CargoCandidate $candidates @{
                Key = 'reference_images'; Value = 'image'; Unit = ''; Scope = 'goods'; Status = 'provided'
                Display = '[IMG]'; MatchIndex = 0; MatchLength = 0; Cue = $false
                Index = $i; Ts = $ts; Evidence = $ev
            }
        }

        $nameCand = Get-CargoGoodsNameCandidate $text
        if ($nameCand) {
            $nameCand.Index = $i; $nameCand.Ts = $ts; $nameCand.Evidence = $ev
            Add-CargoCandidate $candidates $nameCand
        }

        $dimCands = @(Get-CargoDimensionCandidates $text)
        $dimSpans = @($dimCands | ForEach-Object { @{ Start = $_.MatchIndex; End = ($_.MatchIndex + $_.MatchLength) } })

        foreach ($c in $dimCands) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        $weightCands = @(Get-CargoWeightCandidates $text)
        $weightSpans = @($weightCands | ForEach-Object { @{ Start = $_.MatchIndex; End = ($_.MatchIndex + $_.MatchLength) } })
        foreach ($c in $weightCands) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        foreach ($c in @(Get-CargoCountCandidates $text $dimSpans $weightSpans)) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        foreach ($c in @(Get-CargoContactCandidates $text)) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        foreach ($c in @(Get-CargoRecipientNameCandidates $text)) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        $supAddr = @(Get-CargoSupplierAddressCandidates $text)
        foreach ($c in $supAddr) {
            $c.Index = $i; $c.Ts = $ts; $c.Evidence = $ev
            Add-CargoCandidate $candidates $c
        }
        # 供应商地址语句（且不含亚马逊目的仓线索）不进入收货目的地解析：只给供应商地址 != 收货地址。
        if ($supAddr.Count -gt 0 -and -not ($text -match '(?i)\b(amazon|fba)\b|亚马逊')) { $supplierAddrMsgs[$i] = $true }

        foreach ($pf in @(Test-CargoPromiseFields $text)) {
            foreach ($tk in @(Get-CargoPromiseTargets $pf)) {
                if (-not $promised.ContainsKey($tk)) { $promised[$tk] = @{ Index = $i; Ts = $ts; Text = $text } }
            }
        }
    }

    # ---- 目的地：权威实现 + 供应商地址剔除 ----
    $destConv = $Conversation
    if ($supplierAddrMsgs.Count -gt 0 -and $messages.Count -gt 0) {
        $keep = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $messages.Count; $i++) {
            if ($supplierAddrMsgs.ContainsKey($i)) { continue }
            [void]$keep.Add([string]$messages[$i].RawLine)
        }
        $destConv = ConvertTo-MessageList (($keep.ToArray()) -join [string][char]10)
    }
    $destination = $null
    if ($destConv) { $destination = Get-QuoteDestination $destConv }

    if ($destination -and $destination.QuoteUsable) {
        $destIdx = Find-CargoDestinationSourceIndex $destConv $destination
        $origIdx = -1
        if ($destIdx -ge 0) {
            $origIdx = Find-CargoMessageIndexByStableId $messages ([string]$destConv.Messages[$destIdx].StableId)
        }
        $ts = ''
        if ($origIdx -ge 0) { $ts = [string]$messages[$origIdx].MessageTsRaw }
        $src = [string]$destination.Source
        if ($src -ne 'buyer' -and $src -ne 'human') { $src = 'buyer' }
        Add-CargoCandidate $candidates @{
            Key = 'delivery_address'; Value = [string]$destination.DisplayName; Unit = ''; Scope = 'destination'
            Status = 'provided'; Display = [string]$destination.DisplayName; MatchIndex = 0; MatchLength = 0; Cue = $false
            Index = $origIdx; Ts = $ts
            Evidence = @{ Source = $src; Text = [string]$destination.DisplayName; MessageId = ''; Kind = [string]$destination.Kind; Display = [string]$destination.DisplayName }
        }
        $corr = Get-CargoDestinationCorrection $Conversation $destination $origIdx
        if ($corr) { [void]$corrections.Add($corr) }
    } elseif ($destination -and $destination.Kind -eq 'ambiguous') {
        $vals = @($destination.Candidates)
        if ($vals.Count -eq 0) { $vals = @('multiple unsupported destinations') }
        [void]$conflicts.Add(@{ Key = 'delivery_address'; Values = @($vals) })
        [void]$clarifications.Add('Conflicting delivery destinations (' + ($vals -join ', ') + ') - please confirm which one to use.')
    }

    # ---- [spec §5.4] 已验证的任务确认资料作为带来源的证据并入**同一份**事实模型 ----
    #   与买家/人工消息同值时按现有规则归并；不同值且无明确可信更正依据时保留双方来源并冲突。
    foreach ($te in @($TaskEvidence)) {
        if (-not $te) { continue }
        $tek = ''
        if ($te -is [System.Collections.IDictionary]) { if ($te.Contains('FieldKey')) { $tek = [string]$te['FieldKey'] } }
        elseif ($te.PSObject.Properties.Name -contains 'FieldKey') { $tek = [string]$te.FieldKey }
        if (-not $tek -or -not $candidates.ContainsKey($tek)) { continue }
        $st = 'provided'
        if ($te -is [System.Collections.IDictionary]) { if ($te.Contains('Status') -and $te['Status']) { $st = [string]$te['Status'] } }
        elseif (($te.PSObject.Properties.Name -contains 'Status') -and $te.Status) { $st = [string]$te.Status }
        if ($st -ne 'provided' -and $st -ne 'needs_confirmation') { continue }
        $val = $null; $unit = ''; $scope = ''; $tid = ''; $rid = ''; $at = ''; $srefs = @(); $batch = ''
        if ($te -is [System.Collections.IDictionary]) {
            $val = $te['Value']; $unit = [string]$te['Unit']; $scope = [string]$te['Scope']
            $tid = [string]$te['TaskId']; $rid = [string]$te['RecordId']; $at = [string]$te['ObservedAtUtc']
            if ($te.Contains('SourceRefs')) { $srefs = @($te['SourceRefs']) }
            if ($te.Contains('BatchRef')) { $batch = [string]$te['BatchRef'] }
        } else {
            $val = $te.Value; $unit = [string]$te.Unit; $scope = [string]$te.Scope
            $tid = [string]$te.TaskId; $rid = [string]$te.RecordId; $at = [string]$te.ObservedAtUtc
            if ($te.PSObject.Properties.Name -contains 'SourceRefs') { $srefs = @($te.SourceRefs) }
            if ($te.PSObject.Properties.Name -contains 'BatchRef') { $batch = [string]$te.BatchRef }
        }
        if ($null -eq $val -or [string]::IsNullOrWhiteSpace([string]$val)) { continue }
        $ev = @{ Source = 'task'; Text = [string]$val; MessageId = ''; TaskId = $tid; RecordId = $rid
                 SourceRefs = @($srefs); BatchRef = $batch; Kind = 'task-record'; FactRef = $te.FactRef }
        Add-CargoCandidate $candidates @{
            Key = $tek; Value = $val; Unit = $unit; Scope = $scope; Status = $st
            Display = [string]$val; MatchIndex = 0; MatchLength = 0; Cue = $false
            Index = -1; Ts = $at; Evidence = $ev
        }
    }

    # ---- 归并：更正 / 冲突 / 歧义 / 承诺 / 未知 ----
    $fields = New-Object System.Collections.ArrayList
    $byKey = @{}
    foreach ($s in $specs) {
        $list = @($candidates[$s.Key].ToArray())
        $providedCands = @($list | Where-Object { $_.Status -eq 'provided' })
        $pendingCands = @($list | Where-Object { $_.Status -eq 'needs_confirmation' })
        $status = 'unknown'; $value = ''; $unit = $s.Unit; $scope = $s.Scope
        $src = 'unknown'; $srcIdx = -1; $updated = ''; $evidence = @()

        if ($providedCands.Count -gt 0) {
            $current = $providedCands[0]
            $conflictValues = New-Object System.Collections.ArrayList
            # [2026-10-05 第三轮 spec §2 / §7.1] 冲突必须带**结构化候选**（值、单位、范围、来源），
            #   澄清判据据此核对"这句话里的数值是不是本字段真实存在的候选"，而不是只看
            #   "字段状态是 conflict" 就放行任意数值。Values 保留为兼容字段。
            $conflictCands = New-Object System.Collections.ArrayList
            for ($k = 1; $k -lt $providedCands.Count; $k++) {
                $nx = $providedCands[$k]
                $same = ([string]$nx.Value -eq [string]$current.Value -and [string]$nx.Unit -eq [string]$current.Unit)
                if ($same) { $current = $nx; continue }
                if ($nx.Cue) {
                    [void]$corrections.Add(@{ Key = $s.Key; From = $current.Value; To = $nx.Value; SourceIndex = [int]$nx.Index })
                    $current = $nx
                    continue
                }
                if ($conflictValues.Count -eq 0) {
                    [void]$conflictValues.Add($current.Value)
                    [void]$conflictCands.Add((New-CargoConflictCandidate $s $current))
                }
                if ($conflictValues -notcontains $nx.Value) {
                    [void]$conflictValues.Add($nx.Value)
                    [void]$conflictCands.Add((New-CargoConflictCandidate $s $nx))
                }
                $current = $nx
            }
            if ($conflictValues.Count -gt 0) {
                $status = 'conflict'; $value = ''
                [void]$conflicts.Add(@{ Key = $s.Key; Values = @($conflictValues.ToArray()); Candidates = @($conflictCands.ToArray()) })
                $first = $providedCands[0]
                $src = [string]$first.Evidence.Source; $srcIdx = [int]$first.Index; $updated = [string]$first.Ts
                $evidence = @($providedCands | ForEach-Object { $_.Evidence })
            } else {
                $status = 'provided'; $value = $current.Value; $unit = [string]$current.Unit; $scope = [string]$current.Scope
                $src = [string]$current.Evidence.Source; $srcIdx = [int]$current.Index; $updated = [string]$current.Ts
                $evidence = @($current.Evidence)
            }
        } elseif ($pendingCands.Count -gt 0) {
            $last = $pendingCands[$pendingCands.Count - 1]
            $status = 'needs_confirmation'; $value = $last.Value; $unit = [string]$last.Unit; $scope = [string]$last.Scope
            $src = [string]$last.Evidence.Source; $srcIdx = [int]$last.Index; $updated = [string]$last.Ts
            $evidence = @($pendingCands | ForEach-Object { $_.Evidence })
        } elseif ($promised.ContainsKey($s.Key)) {
            $p = $promised[$s.Key]
            $status = 'promised'; $src = 'buyer'; $srcIdx = [int]$p.Index; $updated = [string]$p.Ts
            $evidence = @(@{ Source = 'buyer'; Text = [string]$p.Text; MessageId = '' })
        }

        $f = [pscustomobject]@{
            Key = $s.Key; Label = $s.Label; Value = $value; Unit = $unit; Scope = $scope
            Status = $status; Source = $src; SourceIndex = $srcIdx; UpdatedAt = $updated; Evidence = @($evidence)
        }
        [void]$fields.Add($f)
        $byKey[$s.Key] = $f
    }

    # ---- 澄清问题：范围不明 / 冲突（冲突已在上面的分支里记过一条，这里补字段级问题） ----
    foreach ($s in $specs) {
        $f = $byKey[$s.Key]
        if ($f.Status -eq 'conflict') {
            $vals = @()
            foreach ($c in @($conflicts)) { if ([string]$c.Key -eq $s.Key) { $vals = @($c.Values) } }
            if ($s.Key -eq 'delivery_address') { continue }   # 上面已记录目的地冲突问题
            [void]$clarifications.Add('Conflicting ' + $s.Label + ' values (' + (($vals | ForEach-Object { [string]$_ }) -join ', ') + ') - please confirm which one is correct.')
        } elseif ($f.Status -eq 'needs_confirmation') {
            [void]$clarifications.Add((Get-CargoClarificationText $f))
        }
    }

    # ---- 推导值：带公式与来源字段，绝不伪装成买家原话（spec §3.1/§3.3） ----
    $derived = New-Object System.Collections.ArrayList
    $cc = $byKey['carton_count']
    $uw = $byKey['unit_weight']
    $tw = $byKey['total_weight']
    $ud = $byKey['unit_dimensions']
    if ($cc.Status -eq 'provided' -and $uw.Status -eq 'provided' -and $tw.Status -ne 'provided') {
        # 已明确给出总重时不再用件数乘一次（spec §7 "10 箱、总重量 200 kg"）。
        $total = [Math]::Round(([double]$cc.Value) * ([double]$uw.Value), 6)
        $formula = (Format-CargoNumber $cc.Value) + ' x ' + (Format-CargoNumber $uw.Value) + ' = ' + (Format-CargoNumber $total)
        [void]$derived.Add(@{ Key = 'total_weight_kg'; Value = $total; Unit = 'kg'; Formula = $formula; SourceKeys = @('carton_count', 'unit_weight') })
    }
    if ($cc.Status -eq 'provided' -and $ud.Status -eq 'provided') {
        $divisor = Get-CargoVolumeDivisor ([string]$ud.Unit)
        $parts = @(([string]$ud.Value) -split 'x')
        if ($divisor -gt 0 -and $parts.Count -eq 3) {
            $a = ConvertTo-CargoNumber $parts[0]; $b = ConvertTo-CargoNumber $parts[1]; $c = ConvertTo-CargoNumber $parts[2]
            if ($null -ne $a -and $null -ne $b -and $null -ne $c) {
                $unitVol = ($a * $b * $c) / $divisor
                $total = [Math]::Round(([double]$cc.Value) * $unitVol, 6)
                $formula = (Format-CargoNumber $cc.Value) + ' x (' + (Format-CargoNumber $a) + '*' + (Format-CargoNumber $b) + '*' + (Format-CargoNumber $c) + '/' + (Format-CargoNumber $divisor) + ') = ' + (Format-CargoNumber $total)
                [void]$derived.Add(@{ Key = 'total_volume_m3'; Value = $total; Unit = 'm3'; Formula = $formula; SourceKeys = @('carton_count', 'unit_dimensions') })
            }
        }
    }

    return [pscustomobject]@{
        Fields         = @($fields.ToArray())
        ByKey          = $byKey
        Derived        = @($derived.ToArray())
        Clarifications = @($clarifications.ToArray())
        Conflicts      = @($conflicts.ToArray())
        Corrections    = @($corrections.ToArray())
        RuleVersion    = $script:CargoFactsRuleVersion
    }
}

function Get-CargoClarificationText($Field) {
    $v = [string]$Field.Value
    $u = [string]$Field.Unit
    switch ([string]$Field.Key) {
        'weight'     { return ('Weight scope is unclear: is ' + $v + ' ' + $u + ' the weight per carton/pallet or the total weight?') }
        'dimensions' { return ('Dimension scope is unclear: are ' + $v + ' ' + $u + ' the size per carton/pallet, the goods themselves, or the whole lot?') }
        'count'      { return ('Count scope is unclear: is ' + $v + ' the number of cartons/pallets or the number of individual pieces?') }
        'unit_dimensions' { return ('Dimensions need length, width and height - ' + $v + ' ' + $u + ' only has two sides.') }
        'lot_dimensions'  { return ('Lot dimensions need length, width and height - ' + $v + ' ' + $u + ' only has two sides.') }
        'goods_dimensions' { return ('Goods dimensions need length, width and height - ' + $v + ' ' + $u + ' only has two sides.') }
        'unassigned_contact' { return ('A contact detail was given without a role: is it the consignee''s or the supplier''s?') }
        default      { return ('Please confirm the ' + [string]$Field.Label + ' value (' + $v + ').') }
    }
}

# ============================================================================================
# 报价准备度：Get-QuoteReadiness
# ============================================================================================

function Get-CargoFieldStatus($ByKey, [string]$Key) {
    if (-not $ByKey) { return 'unknown' }
    if (-not $ByKey.ContainsKey($Key)) { return 'unknown' }
    $f = $ByKey[$Key]
    if (-not $f) { return 'unknown' }
    return [string]$f.Status
}

function Get-QuoteReadiness {
    [CmdletBinding()]
    param($Facts)

    $byKey = @{}
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'ByKey') -and $Facts.ByKey) { $byKey = $Facts.ByKey }

    $missing = New-Object System.Collections.ArrayList
    $optional = New-Object System.Collections.ArrayList
    $reasons = New-Object System.Collections.ArrayList
    $clarifications = @()
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'Clarifications')) { $clarifications = @($Facts.Clarifications) }

    # ---- 基本报价必需项（件数 / 重量 / 尺寸 / 收货地址） ----
    # 冲突优先：有冲突就请求确认，不擅自取用；否则缺什么报什么（字段键，便于消费方直接转成追问项）。
    foreach ($cat in (Get-CargoRequiredCategories)) {
        $conflictKeys = @()
        foreach ($fk in @($cat.Fields)) { if ((Get-CargoFieldStatus $byKey $fk) -eq 'conflict') { $conflictKeys += [string]$fk } }
        if ($conflictKeys.Count -gt 0) {
            foreach ($ck in $conflictKeys) { if ($missing -notcontains $ck) { [void]$missing.Add($ck) } }
            continue
        }
        $satisfied = $false
        foreach ($pk in @($cat.Providers)) { if ((Get-CargoFieldStatus $byKey $pk) -eq 'provided') { $satisfied = $true } }
        if (-not $satisfied -and ($missing -notcontains [string]$cat.Report)) { [void]$missing.Add([string]$cat.Report) }
    }

    # ---- 标准清单完整度（与 Ready 分开） ----
    $providers = Get-CargoChecklistProviders
    foreach ($ck in @(Get-CargoChecklistKeys)) {
        $ok = $false
        if ($providers.ContainsKey($ck)) {
            foreach ($pk in @($providers[$ck])) { if ((Get-CargoFieldStatus $byKey $pk) -eq 'provided') { $ok = $true } }
        }
        if (-not $ok -and ($missing -notcontains $ck)) { [void]$optional.Add([string]$ck) }
    }
    $collectionComplete = $true
    foreach ($ck in @(Get-CargoChecklistKeys)) {
        $ok = $false
        if ($providers.ContainsKey($ck)) {
            foreach ($pk in @($providers[$ck])) { if ((Get-CargoFieldStatus $byKey $pk) -eq 'provided') { $ok = $true } }
        }
        if (-not $ok) { $collectionComplete = $false }
    }

    $ready = (@($missing.ToArray()).Count -eq 0)

    # ---- Reasons：判据依据，供回复与内部提醒共用 ----
    if ($ready) {
        [void]$reasons.Add('ready for basic quote preparation: carton count, weight, dimensions and a usable quote destination are all provided')
    } else {
        [void]$reasons.Add('not ready for basic quote preparation - missing required: ' + ((@($missing.ToArray())) -join ', '))
    }
    foreach ($cat in (Get-CargoRequiredCategories)) {
        foreach ($fk in @($cat.Fields)) {
            $st = Get-CargoFieldStatus $byKey $fk
            if ($st -eq 'needs_confirmation') { [void]$reasons.Add('needs confirmation: ' + $fk + ' (' + [string]$byKey[$fk].Label + ')') }
            elseif ($st -eq 'conflict') { [void]$reasons.Add('unresolved conflict: ' + $fk + ' (' + [string]$byKey[$fk].Label + ')') }
        }
    }
    $promisedKeys = New-Object System.Collections.ArrayList
    foreach ($spec in (Get-CargoFieldSpecs)) {
        if ((Get-CargoFieldStatus $byKey ([string]$spec.Key)) -eq 'promised') { [void]$promisedKeys.Add([string]$spec.Key) }
    }
    if ($promisedKeys.Count -gt 0) {
        [void]$reasons.Add('promised by the buyer, not re-asked this round: ' + ((@($promisedKeys.ToArray())) -join ', '))
    }
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'Derived') -and @($Facts.Derived).Count -gt 0) {
        $dk = @(@($Facts.Derived) | ForEach-Object { [string]$_.Key })
        [void]$reasons.Add('derived (calculated, not buyer-stated): ' + ($dk -join ', '))
    }
    if ($Facts -and ($Facts.PSObject.Properties.Name -contains 'Corrections') -and @($Facts.Corrections).Count -gt 0) {
        $cs = @()
        foreach ($c in @($Facts.Corrections)) { $cs += ([string]$c.Key + ' ' + [string]$c.From + ' -> ' + [string]$c.To) }
        [void]$reasons.Add('corrections applied: ' + ($cs -join '; '))
    }
    $da = $null
    if ($byKey.ContainsKey('delivery_address')) { $da = $byKey['delivery_address'] }
    if ($da -and $da.Status -eq 'provided' -and @($da.Evidence).Count -gt 0 -and ([string]$da.Evidence[0].Kind) -eq 'amazon_warehouse') {
        [void]$reasons.Add('quote destination is the Amazon warehouse code ' + [string]$da.Value + ' - no street address is required')
    }
    if ($collectionComplete) {
        [void]$reasons.Add('standard collection list complete')
    } else {
        $optList = @($optional.ToArray())
        if ($optList.Count -gt 0) {
            [void]$reasons.Add('collection incomplete - optional items not provided (they do not block basic quote preparation): ' + ($optList -join ', '))
        } else {
            [void]$reasons.Add('collection incomplete')
        }
    }

    return [pscustomobject]@{
        Ready                = $ready
        MissingFields        = @($missing.ToArray())
        OptionalMissingFields = @($optional.ToArray())
        CollectionComplete   = $collectionComplete
        Clarifications       = @($clarifications)
        Reasons              = @($reasons.ToArray())
        RuleVersion          = $script:CargoFactsRuleVersion
    }
}

# 本文件**全部定义完成后**才置位：msg_norm.ps1 用它判断"单一事实模型是否已经可用"，
#   而不是用 Get-Command —— 在互相加载的过程中 Get-Command 会看到"加载到一半"的状态。
$global:AarFactsEngineLoaded = $true
