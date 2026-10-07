# lib\contact_rules.ps1 - 联系方式最高优先级红线检查器（2026-10-05 spec §1.1 / §6.1 第 0 条）
#
# 用户确认的红线（最高优先级，覆盖初稿、重写、固定回退与实际发送前检查）：
#   1) 不主动提供、推荐或邀请客户使用我方电话/邮箱/微信/WhatsApp 等联系方式，也不用它把客户引到站外；
#   2) 不主动笼统询问客户**本人**的电话/邮箱/微信/WhatsApp；禁止用 "your contact / your phone /
#      your WhatsApp" 代替收货资料的明确询问；
#   3) 允许按运输业务索取**收货人**（consignee / recipient）的姓名、收货联系方式与地址；
#   4) 允许按已确认的供应商核实流程索取**供应商**联系方式（supplier / vendor / factory）；
#   5) 即使买家本人就是收货人，询问也必须明确是收货用途，不得扩展为索取其私人聊天账号或转移对话；
#   6) 同一句里提到供应商/收货人**不能豁免**其他联系请求：混合包含我方联系邀约或对买家个人
#      联系方式的索取时仍然阻断（按请求项分别判定）。
#
# [2026-10-05 第三轮 spec §2 / §3] 本轮把"小句级模式匹配"升级为**请求项**模型：
#   Get-ReplyRequestItems 先把待发文本解析成结构化的请求项（源区间、动作、动词来源/是否继承、
#   实际角色、具体 FieldKey、用途、collect/clarify、澄清引用），联系方式红线与
#   reply_policy::Test-AskFieldConformance 消费**同一份**请求项列表，避免一个判据认定"已提供"、
#   另一个认定"未授权"。
#   关键行为：
#     * 并列请求允许省略/继承**动作**（share A and B），但**动词继承不等于角色继承**；
#       角色只有直接所有格、of/for 绑定或紧密的同一名词清单可继承。独立用途从句、新的请求动词、
#       新的所有者、人称代词（your phone）与句界都会结束或重建角色作用范围。
#     * 字段按**具体 FieldKey** 判定：recipient_name / recipient_contact / delivery_address /
#       supplier_contact / supplier_address 各自核对"已提供"与"本轮授权"，不再按角色整组判定。
#     * collect 顺序：规范键 → 该项已有有效 provided 事实则拒绝重复索取 → 该项 AskFields 授权 →
#       联系角色/业务用途成立。授权不能覆盖"已经提供"。
#
# 边界：本模块是**确定性模式匹配 + 有限句法**，不宣称覆盖所有自然语言（spec §3.1 第 8 条）。
#   判不准的情形按"宁可少发"处理：阻断并留 Detail，交给人工或受约束话术，而不是放行。
#
# 依赖：无（纯函数，可被 reply_policy 与测试各自加载）。

# 我方联系方式与"邀请联系"的措辞。
$script:ContactOurChannelWords = '(?:phone|mobile|cell|number|whatsapp|we\s?chat|wechat|telegram|skype|viber|line|signal|email|e-mail|mail|contact(?:\s+details)?)'

$script:ContactOurOfferPatterns = @(
    ('(?i)\b(?:my|our)\s+' + $script:ContactOurChannelWords + '\b'),
    '(?i)\bhere(?:''s| is)\s+(?:my|our)\b',
    # "contact me on WhatsApp" / "reach us at <number>"：必须带渠道或 at/on/via 才判为邀约，
    # 以免把平台内的正常表述（"you can contact us here"）误判成站外引流。
    '(?i)\b(?:contact|reach|call|message|text|email)\s+(?:me|us)\b[^.!?]{0,20}\b(?:at|on|via|through|by)\b',
    '(?i)\bcall\s+me\b',
    '(?i)\badd\s+me\s+on\b',
    '(?i)\b(?:dm|pm)\s+me\b',
    '(?i)\b(?:let''?s|let\s+us|we\s+can|you\s+can)\s+(?:talk|chat|continue|discuss|move|speak)\b[^.!?]{0,30}\b(?:whatsapp|we\s?chat|wechat|telegram|skype|viber|line|signal|off[\s\-]?platform|outside)\b',
    ('(?i)\b(?:talk|chat|speak|continue|discuss|message|reach|contact|call)\b[^.!?]{0,25}\b(?:on|over|via|through)\b[^.!?]{0,15}\b' + $script:ContactOurChannelWords + '\b'),
    '(?i)\b(?:switch|move|take)\s+(?:this\s+|the\s+)?(?:chat|conversation|talk)\s+(?:to|onto|over\s+to)\b',
    '(?i)\boff[\s\-]?platform\b',
    '(?i)\b(?:pay|payment|transfer)\s+(?:me\s+)?(?:directly|outside|off[\s\-]?platform)\b',
    '(?i)\b(?:my|our)\s+(?:whatsapp|wechat|we\s?chat|telegram|skype|viber)\s+(?:id|number|account)\b',
    # 单纯的联系邀约（"You can email me if that is easier." / "Call me anytime."）。
    '(?i)\b(?:e-?mail|call|phone|text|message|whatsapp|we\s?chat|wechat|telegram|skype|viber|signal|dm|pm)\s+(?:me|us)\b',
    # "Drop me an email" / "Send me a message"：动词在前、渠道在后的同义写法。
    '(?i)\b(?:drop|send|shoot|give|ping)\s+(?:me|us)\s+(?:an?\s+|the\s+)?(?:e-?mail|mail|message|text|dm|pm|whatsapp|we\s?chat|wechat|call)\b',
    ('(?i)\b(?:contact|reach|call|message|text|e-?mail|write\s+to|talk\s+to|speak\s+to)\s+(?:me|us)\b[^.!?]{0,20}\b' + $script:ContactOurChannelWords + '\b')
)

# 文本里出现的**任何**邮箱/电话字面量：我方对外回复不应包含联系号码（收货人/供应商资料由系统内部
# 保存，不需要回写）。出现即阻断，避免"顺带发送"。
$script:ContactLiteralPatterns = @(
    '(?i)[\w\.\-\+]+@[\w\-]+\.[A-Za-z]{2,}',
    '(?<![\d.])(?:\+?\d[\d\s\-\(\)]{7,}\d)(?![\d.])'
)

$script:ContactPersonalAskPatterns = @(
    # "your phone" / "your personal phone number" / "your own WhatsApp id"：允许中间出现形容词，
    # 但**不**允许 "your supplier's ..."（角色名不在形容词集合里 ⇒ 交给角色判据处理）。
    ('(?i)\b(?:your|ur|u)\s+(?:(?:own|personal|private|direct|contact|phone|mobile|cell)\s+){0,3}' + $script:ContactOurChannelWords + '\b'),
    '(?i)\b(?:send|share|give|provide|tell|confirm)\s+(?:me\s+)?(?:your|ur|u)\b[^.!?]{0,20}\b(?:contact|number|phone|mobile|cell|email|whatsapp|we\s?chat|wechat)\b',
    '(?i)\bwhat(?:''s|s| is)\s+(?:your|ur)\s+(?:whatsapp|we\s?chat|wechat|number|phone|email)\b',
    '(?i)\bcan\s+i\s+(?:have|get)\s+(?:your|ur)\b',
    '(?i)\b(?:your|ur)\s+(?:whatsapp|we\s?chat|wechat)\s+(?:id|number|account)\b'
)

# 允许的业务角色（收货人 / 供应商）。
$script:ContactRecipientRoleWords = '(?:consignee|recipient|receiver|the\s+receiving\s+party|delivery\s+contact|收货人|收件人)'
$script:ContactSupplierRoleWords  = '(?:supplier|vendor|factory|供应商|工厂)'
$script:ContactRecipientRole = ('(?i)\b' + $script:ContactRecipientRoleWords + '\b')
$script:ContactSupplierRole  = ('(?i)\b' + $script:ContactSupplierRoleWords + '\b')

# 收货/核实用途措辞（即使买家本人就是收货人，也要说明业务用途）。
$script:ContactPurposeWords = '(?i)\b(?:deliver\w*|shipment|shipping|consignment|cargo|carrier|courier|dispatch|arrival|drop[\s\-]?off|warehouse|pack\w*|cartons?|pallets?|weights?|dimensions?|measurements?|packing\s+list|quot\w+|rates?|verify|confirm|包装|收货|派送|运输|核实)\b'

# 无角色的"泛化联系方式请求"（spec §3.2 第 1 条）：限定词是**可选**修饰语，进入检查的条件是
#   "索取动作 + 联系渠道/资料对象"，而不是有没有冠词。
$script:ContactItemNouns = '(?:contact\s+(?:numbers?|details?|info(?:rmation)?|address(?:es)?)|phone(?:\s+(?:numbers?|nos?\.?))?|mobile(?:\s+(?:numbers?|nos?\.?))?|cell(?:\s+(?:numbers?|nos?\.?))?|e-?mail(?:\s+address(?:es)?)?|whats\s?app|we\s?chat|wechat|telegram|skype|viber|signal|line\s+id)'

$script:ContactGenericAskPatterns = @(
    ('(?i)\b(?:leave|provide|share|send|give|need|require|confirm|add|tell\s+me|tell\s+us|pass\s+me)\s+(?:me\s+|us\s+)?(?:(?:a|an|the|your|any|some|my|our)\s+)?(?:\w+''s\s+)?' + $script:ContactItemNouns + '\b'),
    '(?i)\b(?:leave|provide|share|send|give|need|require|confirm)\s+(?:me\s+|us\s+)?(?:a|an|the|your|any)\s+(?:number(?!\s+of\b)|contact|details?)\b[^.!?]{0,30}\b(?:for|of|to|with|so\s+that)\b',
    '(?i)\bwhat(?:''s|s| is)?\s+(?:the|a|your)?\s*(?:best\s+)?(?:contact\s+numbers?|phone\s+numbers?|contact\s+details?|e-?mail\s+address(?:es)?)\b',
    '(?i)\b(?:a|the)\s+(?:contact\s+number|phone\s+number)\s+for\b'
)

# 联系渠道/资料名词（角色后面可以跟的那一类名词）。
$script:ContactChannelWords = '(?:contact(?:\s+(?:numbers?|details?|info(?:rmation)?))?|phone(?:\s+(?:numbers?|nos?\.?))?|mobile(?:\s+(?:numbers?|nos?\.?))?|cell(?:\s+(?:numbers?|nos?\.?))?|e-?mail(?:\s+address(?:es)?)?|whats\s?app|we\s?chat|wechat|telegram|skype|viber|signal|line\s+id|numbers?|details?)'

# 索取动作的**显式动词**（可被并列成分继承）。"please/could/can" 只是礼貌标记，不是动作本身。
$script:ContactAskVerbPattern = '(?i)\b(?:what|which|how\s+many|share|send|provide|give|leave|confirm|add|supply|furnish|advise|pass|tell\s+me|let\s+us\s+know|tell\s+us|need|require|want|ask(?:ing)?\s+for)\b'
# 礼貌/疑问标记只在**指向对话方**时才算请求信号（"The contact person ... will call you." 不是索取）。
$script:ContactAskPolitenessPattern = '(?i)\b(?:could|can|would|will|may)\s+(?:you|i|we)\b|\bplease\b|\bkindly\b|\?'
# 否定句不是索取（"we do not strictly need the supplier's contact"）。
$script:ContactNegationGuard = '(?i)\b(?:do\s+not|don''?t|does\s+not|doesn''?t|no\s+longer|not|never)\b[^.!?]{0,25}\b(?:need|require|want|ask)\b'

# "独立用途从句"：出现即结束角色作用范围（后面的并列项不能继承角色）。
$script:ContactPurposeClausePattern = '(?i)\b(?:so\s+that|so\s+we\s+can|so\s+you\s+can|so\s+we\s+may|in\s+order\s+to|for\s+(?:the\s+)?(?:packing|packaging|delivery|shipment|shipping|verification|reference|records|our\s+records|the\s+quote|quoting))\b'

# [独立复核 R06] 程序自己的"范围澄清"受控句式（response_plan 渲染）：
#   "Could you confirm which <字段> and its <范围> we should use?" 是一个问题、一个字段，不能被 and 拆成第二个索取。
$script:ContactControlledScopeClarifyPattern = '(?i)\bcould\s+you\s+confirm\s+which\s+[^?]{0,40}?\s+and\s+(?:its|their)\s+[^?]{0,40}?\s+(?:we|i)\s+should\s+use\b'

# =============================================================================================
# 请求项解析（spec §2 / §3.1）
# =============================================================================================

# 段落切分：句末标点 / 逗号 / 并列连词。返回 @{ Start; End; Text; Boundary }
#   Boundary: 'start' | 'sentence' | 'comma' | 'conj'
$script:ContactSegmentSplitPattern = '(?<=[.!?;])\s+|\s*,\s*|\s*\b(?:as\s+well\s+as|together\s+with|and|but|also|plus|however|btw|by\s+the\s+way)\b\s*|\s*\bor\b\s*'

function Get-ReplyRequestSegments([string]$Text) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = [string]$Text
    $idx = 0
    $boundary = 'start'
    foreach ($m in [regex]::Matches($t, $script:ContactSegmentSplitPattern)) {
        $segText = $t.Substring($idx, $m.Index - $idx)
        if ($segText.Trim()) {
            [void]$out.Add([pscustomobject]@{ Start = $idx; End = $m.Index; Text = $segText.Trim(); Boundary = $boundary })
        }
        $b = 'conj'
        if ($m.Value -match '[.!?;]' -or ($m.Index -gt 0 -and $t[$m.Index - 1] -match '[.!?;]')) { $b = 'sentence' }
        elseif ($m.Value -match ',') { $b = 'comma' }
        $boundary = $b
        $idx = $m.Index + $m.Length
    }
    if ($idx -lt $t.Length) {
        $segText = $t.Substring($idx)
        if ($segText.Trim()) { [void]$out.Add([pscustomobject]@{ Start = $idx; End = $t.Length; Text = $segText.Trim(); Boundary = $boundary }) }
    }
    return @($out.ToArray())
}

# 具体字段键的唯一别名表。粗角色名只映射到**最保守的单项**，绝不展开成整组资料（spec §3.2）。
$script:ContactFieldAliases = @{
    'supplier'          = 'supplier_contact'
    'supplier_contact'  = 'supplier_contact'
    'suppliercontact'   = 'supplier_contact'
    'supplier_address'  = 'supplier_address'
    'recipient_contact' = 'recipient_contact'
    'consignee_contact' = 'recipient_contact'
    'delivery_contact'  = 'recipient_contact'
    'recipient_name'    = 'recipient_name'
    'consignee_name'    = 'recipient_name'
    'recipient'         = 'recipient_name'
    'consignee'         = 'recipient_name'
    'delivery_address'  = 'delivery_address'
    'recipient_address' = 'delivery_address'
    'address'           = 'delivery_address'
}

function Get-ContactFieldKey([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $k = ([string]$Raw).Trim().ToLowerInvariant()
    if ($script:ContactFieldAliases.ContainsKey($k)) { return [string]$script:ContactFieldAliases[$k] }
    return ''
}

# 本轮 AskFields 授权展开：recipient_contact 同时覆盖"收货人姓名"（姓名属于同一联系资料块），
#   反向不成立（recipient_name 不授权联系方式）；delivery_address / supplier_address 各自独立。
function Expand-ContactAuthorizedFields($Fields) {
    $out = New-Object System.Collections.ArrayList
    foreach ($f in @($Fields)) {
        $k = Get-ContactFieldKey ([string]$f)
        if ($k -and -not $out.Contains($k)) { [void]$out.Add($k) }
    }
    return @($out.ToArray())
}

function Get-ContactAuthorizedFields($Decision) {
    if (-not $Decision) { return @() }
    if (-not ($Decision.PSObject.Properties.Name -contains 'AskFields')) { return @() }
    return @(Expand-ContactAuthorizedFields @($Decision.AskFields))
}

# 兼容取值：$Decision.Facts 是 PSCustomObject，CargoFacts.ByKey 是 hashtable；
#   两种形态都要能读，且**不能**用 PSObject.Properties 判断 hashtable 的键。
function Get-ContactFactValue($Bag, [string]$Key) {
    if (-not $Bag -or [string]::IsNullOrWhiteSpace($Key)) { return $null }
    if ($Bag -is [System.Collections.IDictionary]) {
        if ($Bag.Contains($Key)) { return $Bag[$Key] }
        return $null
    }
    foreach ($p in @($Bag.PSObject.Properties)) { if ($p.Name -eq $Key) { return $p.Value } }
    return $null
}

# [spec §3.2] 该**具体资料项**本轮是否已经有有效 provided 事实。
#   recipient_name / delivery_address 不授权 recipient_contact；supplier_address 与 supplier_contact 互不授权。
function Test-ContactItemProvided($Facts, [string]$FieldKey) {
    if (-not $Facts -or [string]::IsNullOrWhiteSpace($FieldKey)) { return $false }
    if ($FieldKey -eq 'supplier_contact' -and [bool](Get-ContactFactValue $Facts 'HasSupplierContact')) { return $true }
    $cargo = Get-ContactFactValue $Facts 'CargoFacts'
    if (-not $cargo) { return $false }
    $byKey = Get-ContactFactValue $cargo 'ByKey'
    if (-not $byKey) { return $false }
    $keys = @()
    switch ($FieldKey) {
        'supplier_contact'  { $keys = @('supplier_contact') }
        'supplier_address'  { $keys = @('supplier_address') }
        'recipient_contact' { $keys = @('recipient_contact') }
        'recipient_name'    { $keys = @('recipient_name') }
        'delivery_address'  { $keys = @('delivery_address', 'recipient_address', 'address') }
    }
    foreach ($k in $keys) {
        $fld = Get-ContactFactValue $byKey $k
        if (-not $fld) { continue }
        $st = [string](Get-ContactFactValue $fld 'Status')
        if ($st -eq 'provided') { return $true }
        # 供应商侧旧键：只有真的带了值才算已提供（避免空值把合法询问挡掉）。
        $val = [string](Get-ContactFactValue $fld 'Value')
        if ($st -eq 'unknown' -and $val -and $k -eq 'supplier_contact') { return $true }
    }
    return $false
}

# 兼容入口（只按角色粗判，保留给列表/摘要类消费者；授权与已提供判定一律用具体 FieldKey）。
function Test-ContactRoleProvided($Facts, [string]$Role) {
    if ($Role -eq 'supplier') { return (Test-ContactItemProvided $Facts 'supplier_contact') }
    if ($Role -eq 'recipient') { return ((Test-ContactItemProvided $Facts 'recipient_contact') -or (Test-ContactItemProvided $Facts 'recipient_name')) }
    return $false
}

# 把小句切开（兼容入口，保留给既有消费者）。
function Get-ContactClauses([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = [string]$Text
    $parts = [regex]::Split($t, '(?<=[.!?;])\s+|\s+(?:and|but|also|plus|btw|by\s+the\s+way|however)\s+')
    return @($parts | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

# 该小句是否在披露/邀请我方联系方式。
function Test-OurContactDisclosure([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    foreach ($p in $script:ContactOurOfferPatterns) { if ($Clause -match $p) { return $true } }
    $Clause=$Clause -replace '\b\d{4}-\d{2}-\d{2}\b',' CALENDAR_DATE '
    foreach ($p in $script:ContactLiteralPatterns) { if ($Clause -match $p) { return $true } }
    return $false
}

# 该小句是否在索取买家**本人**的联系方式。
function Test-PersonalContactAsk([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    foreach ($p in $script:ContactPersonalAskPatterns) { if ($Clause -match $p) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------------------------
# [spec §3.1] 请求项：源文本区间、动作、动词来源/是否继承、实际角色、具体 FieldKey、用途、
#   collect/clarify、澄清引用。角色**不**由全文出现 supplier/recipient 推导。
# ---------------------------------------------------------------------------------------------
$script:ContactRoleItemPattern = (
    # [独立复核 R06] 角色与资料名词之间允许**受控**的业务修饰语（supplier's business contact /
    #   recipient's delivery contact）；除此之外仍必须紧邻，空角色不通配。
    '(?i)\b(?<owner>your|ur|the|our|their|his|her|my)?\s*(?<role>' + $script:ContactRecipientRoleWords + '|' + $script:ContactSupplierRoleWords + ')(?:''s|s)?\s+(?:(?:business|office|company|corporate|primary|main|direct|general|sales|delivery|shipping|receiving|warehouse|pickup|logistics|contact\s+person)\s+)?(?<item>' + $script:ContactChannelWords + '|name|address(?:es)?)\b'
)
$script:ContactItemOfRolePattern = (
    '(?i)\b(?<item>' + $script:ContactChannelWords + '|name|address(?:es)?)\s+(?:of|for)\s+(?<owner>the\s+|your\s+|our\s+|their\s+)?(?<role>' + $script:ContactRecipientRoleWords + '|' + $script:ContactSupplierRoleWords + ')\b'
)
# 无角色的"投递用途"联系方式（"the delivery phone number" / "delivery address"）：
#   收货人角色 + 派送用途的受控表达，不是笼统的个人联系方式请求。
$script:ContactDeliveryItemPattern = '(?i)\bdeliver\w*\s+(?<item>' + $script:ContactChannelWords + '|address(?:es)?)\b'

function Get-ContactItemFieldKey([string]$Role, [string]$Item) {
    $r = ([string]$Role).ToLowerInvariant()
    $i = ([string]$Item).Trim().ToLowerInvariant()
    $isRecipient = [bool]($r -match 'consignee|recipient|receiver|receiving|delivery\s+contact|收货人|收件人')
    $isSupplier = [bool]($r -match 'supplier|vendor|factory|供应商|工厂')
    $isAddress = [bool]($i -match '^address')
    $isName = [bool]($i -match '^name')
    if ($isAddress) {
        if ($isRecipient) { return 'delivery_address' }
        if ($isSupplier) { return 'supplier_address' }
        return ''
    }
    if ($isName) {
        if ($isRecipient) { return 'recipient_name' }
        return ''
    }
    if ($isRecipient) { return 'recipient_contact' }
    if ($isSupplier) { return 'supplier_contact' }
    return ''
}

function New-ContactRequestItem {
    param(
        [int]$Index, [int]$Length, [string]$Text, [string]$Action = 'ask',
        [string]$Verb = '', [string]$VerbSource = 'explicit', [bool]$Inherited = $false,
        [string]$Role = '', [string]$FieldKey = '', [bool]$Purpose = $false,
        [string]$Kind = 'collect', [string]$ClarifyRef = '', [bool]$Contact = $true, [string]$Raw = ''
    )
    return [pscustomobject]@{
        Index      = $Index
        Length     = $Length
        Text       = $Text
        Action     = $Action
        Verb       = $Verb
        VerbSource = $VerbSource
        Inherited  = $Inherited
        Role       = $Role
        FieldKey   = $FieldKey
        Purpose    = $Purpose
        Kind       = $Kind
        ClarifyRef = $ClarifyRef
        Contact    = $Contact
        Raw        = $Raw
    }
}

function Get-ReplyRequestItems {
    [CmdletBinding()]
    param([string]$Text, $Decision = $null)
    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $t = [string]$Text
    $textPurpose = [bool]($t -match $script:ContactPurposeWords)
    $segments = @(Get-ReplyRequestSegments $t)
    $inheritedVerb = ''
    $roleScope = ''
    $scopeValid = $false
    for ($si = 0; $si -lt $segments.Count; $si++) {
        $seg = $segments[$si]
        $body = [string]$seg.Text
        $boundary = [string]$seg.Boundary
        # 句界：动作与角色作用范围都结束。
        if ($boundary -eq 'sentence') { $inheritedVerb = ''; $roleScope = ''; $scopeValid = $false }
        if (-not $body) { continue }

        $ownVerb = ''
        # An omitted modifier after "per carton or pallet" is scope, not a package-count request.
        if($boundary -eq 'conj' -and $body -match '(?i)^(?:pallet|carton|box)(?:\s*\([^)]*\))?\s*[?!.]?$' -and $si -gt 0 -and $segments[$si-1].Text -match '(?i)\bper\s+(carton|pallet|box)\b'){continue}
        $m = [regex]::Match($body, $script:ContactAskVerbPattern)
        if ($m.Success) { $ownVerb = $m.Value.ToLowerInvariant() }
        if ($ownVerb -and $boundary -in @('comma','conj')) { $roleScope='';$scopeValid=$false }
        if ($body -match '(?i)\b(?:your|my|our|their|his|her)\s+(?:phone|email|contact|number|name)\b') { $roleScope='';$scopeValid=$false }
        $hasPoliteness = [bool]($body -match $script:ContactAskPolitenessPattern)
        $negated = [bool]($body -match $script:ContactNegationGuard)

        $verb = $ownVerb
        $verbSource = 'explicit'
        if (-not $verb) {
            if ($inheritedVerb -and ($boundary -eq 'comma' -or $boundary -eq 'conj')) {
                $verb = $inheritedVerb; $verbSource = 'inherited'
            }
        }
        # 本段之后，动作是否可被下一并列项继承。
        $nextInheritedVerb = $inheritedVerb
        if ($ownVerb) { $nextInheritedVerb = $ownVerb }

        $isAsk = [bool](($verb -or $hasPoliteness) -and -not $negated)
        $segPurpose = [bool]($body -match $script:ContactPurposeWords)
        $purpose = [bool]($segPurpose -or $textPurpose)
        $purposeClause = [bool]($body -match $script:ContactPurposeClausePattern)

        # ---- 我方渠道披露/邀约（独立检查，不受角色/用途授权豁免） ----
        if (Test-OurContactDisclosure $body) {
            [void]$items.Add((New-ContactRequestItem -Index $seg.Start -Length ($seg.End - $seg.Start) -Text $body -Action 'offer' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role '' -FieldKey '' -Purpose $purpose -Kind 'offer' -Contact $true -Raw $body))
            if ($purposeClause) { $roleScope = ''; $scopeValid = $false }
            $inheritedVerb = $nextInheritedVerb
            continue
        }

        $segItems = New-Object System.Collections.ArrayList
        $consumed = New-Object System.Collections.ArrayList
        if ($isAsk) {
            # (1) 角色所有格 + 资料名词："your supplier's contact details" / "the consignee's name"
            foreach ($rm in [regex]::Matches($body, $script:ContactRoleItemPattern)) {
                $fk = Get-ContactItemFieldKey ([string]$rm.Groups['role'].Value) ([string]$rm.Groups['item'].Value)
                if (-not $fk) { continue }
                $role = 'recipient'
                if ([string]$rm.Groups['role'].Value -match $script:ContactSupplierRole) { $role = 'supplier' }
                $isContact = ($fk -ne 'delivery_address' -and $fk -ne 'supplier_address')
                [void]$segItems.Add((New-ContactRequestItem -Index ($seg.Start + $rm.Index) -Length $rm.Length -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role $role -FieldKey $fk -Purpose $purpose -Kind 'collect' -Contact $isContact -Raw $rm.Value))
                [void]$consumed.Add(@{ Start = $rm.Index; End = ($rm.Index + $rm.Length) })
            }
            # (2) 资料名词 + of/for + 角色："contact details of the supplier"
            foreach ($rm in [regex]::Matches($body, $script:ContactItemOfRolePattern)) {
                if (Test-ContactSpanCovered $rm.Index $consumed) { continue }
                $fk = Get-ContactItemFieldKey ([string]$rm.Groups['role'].Value) ([string]$rm.Groups['item'].Value)
                if (-not $fk) { continue }
                $role = 'recipient'
                if ([string]$rm.Groups['role'].Value -match $script:ContactSupplierRole) { $role = 'supplier' }
                $isContact = ($fk -ne 'delivery_address' -and $fk -ne 'supplier_address')
                [void]$segItems.Add((New-ContactRequestItem -Index ($seg.Start + $rm.Index) -Length $rm.Length -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role $role -FieldKey $fk -Purpose $purpose -Kind 'collect' -Contact $isContact -Raw $rm.Value))
                [void]$consumed.Add(@{ Start = $rm.Index; End = ($rm.Index + $rm.Length) })
            }
            # (3) 投递用途的联系资料（"the delivery phone number"）=> 收货人联系资料
            foreach ($rm in [regex]::Matches($body, $script:ContactDeliveryItemPattern)) {
                if (Test-ContactSpanCovered $rm.Index $consumed) { continue }
                $fk = Get-ContactItemFieldKey 'recipient' ([string]$rm.Groups['item'].Value)
                if (-not $fk) { continue }
                $isContact = ($fk -ne 'delivery_address')
                [void]$segItems.Add((New-ContactRequestItem -Index ($seg.Start + $rm.Index) -Length $rm.Length -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role 'recipient' -FieldKey $fk -Purpose $true -Kind 'collect' -Contact $isContact -Raw $rm.Value))
                [void]$consumed.Add(@{ Start = $rm.Index; End = ($rm.Index + $rm.Length) })
            }
            # (4) 买家本人联系方式（"your phone"）——同句出现角色不豁免。
            #   先挖掉"角色所有格 + 资料名词"整段："could you share your supplier's contact" 不是
            #   "send me your contact"；只有挖掉后仍命中买家本人模式的才算个人索取。
            $scrubbedBody = [regex]::Replace($body, $script:ContactRolePhraseScrub, ' ROLE_ITEM ')
            if (Test-PersonalContactAsk $scrubbedBody) {
                [void]$segItems.Add((New-ContactRequestItem -Index $seg.Start -Length ($seg.End - $seg.Start) -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role 'buyer' -FieldKey 'buyer_contact' -Purpose $purpose -Kind 'collect' -Contact $true -Raw $body))
            } else {
                # (5) 无显式角色的裸资料名词：先试"继承的角色"（紧密名词清单），否则按无角色处理。
                $bare = Get-ContactBareItemSpans $body $consumed
                $bareChannels = New-Object System.Collections.ArrayList
                foreach ($b in $bare) {
                    if (-not (Test-ContactChannelNoun ([string]$b.Item) $body ([int]$b.Index)) -and -not ($scopeValid -and [string]$b.Item -match '^(?:name|address)')) { continue }
                    [void]$bareChannels.Add($b)
                    $fk = ''
                    if ($scopeValid -and $roleScope) { $fk = Get-ContactItemFieldKey $roleScope ([string]$b.Item) }
                    if ($fk) {
                        $isContact = ($fk -ne 'delivery_address' -and $fk -ne 'supplier_address')
                        [void]$segItems.Add((New-ContactRequestItem -Index ($seg.Start + $b.Index) -Length $b.Length -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role $roleScope -FieldKey $fk -Purpose $purpose -Kind 'collect' -Contact $isContact -Raw ([string]$b.Raw)))
                    }
                }
                # [spec §3.1 第 1 条] 并列请求允许省略/继承**动作**：本段有索取动作（显式或继承）、
                #   出现联系渠道名词、却没有任何角色锚点 ⇒ 无角色联系方式请求（动词继承 ≠ 角色继承）。
                if ($bareChannels.Count -gt 0 -and -not ($scopeValid -and $roleScope)) {
                    if ((Test-GenericContactAsk $body) -or $verb) {
                        [void]$segItems.Add((New-ContactRequestItem -Index $seg.Start -Length ($seg.End - $seg.Start) -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role 'none' -FieldKey '' -Purpose $purpose -Kind 'collect' -Contact $true -Raw $body))
                    }
                }
            }
            # 显式泛化联系方式请求（无需裸名词判据）也必须进入检查。
            if ($segItems.Count -eq 0 -and (Test-GenericContactAsk $body) -and $isAsk) {
                [void]$segItems.Add((New-ContactRequestItem -Index $seg.Start -Length ($seg.End - $seg.Start) -Text $body -Action 'ask' -Verb $verb -VerbSource $verbSource -Inherited ($verbSource -eq 'inherited') -Role 'none' -FieldKey '' -Purpose $purpose -Kind 'collect' -Contact $true -Raw $body))
            }
        }

        # Every non-contact request is produced by this same parser, including inherited verbs.
        if ($isAsk -and (Get-Variable PolicyAskFieldGroups -Scope Script -ErrorAction SilentlyContinue)) {
            foreach($group in $script:PolicyAskFieldGroups) {
                if($body -notmatch $group.Pattern){continue}
                if($group.Name -eq 'count' -and -not (Test-AskCountRequest $body)){continue}
                if($group.Name -eq 'address' -and $body -match $script:PolicySupplierAddressAskPattern){continue}
                $field=[string]$group.Fields[0]
                if(@($segItems|Where-Object {$_.FieldKey -eq $field}).Count){continue}
                $kind='collect';$cref='';$itemText=$body
                $bounds=Get-SentenceBounds $t $seg.Start
                $full=$t.Substring($bounds.Start,$bounds.End-$bounds.Start)
                if((Test-AskClarifyWording $body) -or ($full -match $script:ContactControlledScopeClarifyPattern)){$req=Get-ClarificationRequestForGroup @(Get-ReplyClarificationRequests -Facts $Decision.Facts -Decision $Decision) $group;if($req){$kind='clarify';$cref=$req.Id;$itemText=$full}}
                [void]$segItems.Add((New-ContactRequestItem -Index $seg.Start -Length ($seg.End-$seg.Start) -Text $itemText -Verb $verb -VerbSource $verbSource -FieldKey $field -Contact $false -Kind $kind -ClarifyRef $cref -Raw $body))
            }
        }

        foreach ($it in $segItems) { [void]$items.Add($it) }

        # ---- 角色作用范围推进 ----
        if ($purposeClause) {
            $roleScope = ''; $scopeValid = $false
        } elseif ($segItems.Count -gt 0) {
            $anchor = $null
            foreach ($it in $segItems) { if ($it.Role -eq 'recipient' -or $it.Role -eq 'supplier') { $anchor = $it; break } }
            if ($anchor) {
                $roleScope = [string]$anchor.Role
                # 只有"紧密的同一名词清单"才允许继承：本段没有独立用途从句、没有新的显式所有者动词。
                $newOwner = [bool]($body -match '(?i)\b(?:your|ur|my|our|their|his|her)\b')
                $scopeValid = (-not $purposeClause)
                if ($newOwner -and -not ($boundary -eq 'comma' -or $boundary -eq 'conj')) { $scopeValid = $false }
            } else {
                $scopeValid = $false
                $roleScope = ''
            }
        } elseif ($boundary -eq 'sentence') {
            $scopeValid = $false; $roleScope = ''
        } else {
            # 本段没有请求项（例如纯用途从句）：角色作用范围不再向前继承。
            $scopeValid = $false
        }
        $inheritedVerb = $nextInheritedVerb
    }
    return @($items.ToArray())
}

function Test-ContactSpanCovered([int]$Index, $Spans) {
    foreach ($s in @($Spans)) { if ($Index -ge [int]$s.Start -and $Index -lt [int]$s.End) { return $true } }
    return $false
}

# 未被显式角色消费的裸资料名词（"phone number" / "delivery address" 里的名词部分）。
$script:ContactBareItemPattern = '(?i)\b(?<item>' + $script:ContactChannelWords + '|address(?:es)?|name)\b'

# 裸名词是不是"联系方式渠道"（address/name/泛化 details/number 不算渠道；"a number of ..." 也不算）。
$script:ContactPlainGenericNouns = @('detail', 'details', 'information', 'info', 'number', 'numbers', 'address', 'addresses', 'name', 'names')

function Test-ContactChannelNoun([string]$Item, [string]$Body = '', [int]$Index = 0) {
    $i = ([string]$Item).Trim().ToLowerInvariant()
    if (-not $i) { return $false }
    if ($i -match '^(?:contact|phone|mobile|cell|e-?mail|whats\s?app|we\s?chat|wechat|telegram|skype|viber|signal|line\s+id)\b') { return $true }
    if ($script:ContactPlainGenericNouns -contains $i) {
        if ($i -match '^numbers?$' -and $Body) {
            $rest = $Body.Substring([Math]::Min($Index + $Item.Length, $Body.Length))
            if ($rest -match '^\s+of\b') { return $false }
        }
        return $false
    }
    return $false
}

function Get-ContactBareItemSpans([string]$Body, $Consumed) {
    $out = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }
    foreach ($m in [regex]::Matches($Body, $script:ContactBareItemPattern)) {
        if (Test-ContactSpanCovered $m.Index $Consumed) { continue }
        # 与已消费区间重叠的也跳过。
        $overlap = $false
        foreach ($s in @($Consumed)) { if ($m.Index -lt [int]$s.End -and ($m.Index + $m.Length) -gt [int]$s.Start) { $overlap = $true; break } }
        if ($overlap) { continue }
        [void]$out.Add(@{ Index = $m.Index; Length = $m.Length; Item = [string]$m.Groups['item'].Value; Raw = $m.Value })
    }
    return @($out.ToArray())
}

# 该小句是否是一个"联系方式请求"（兼容入口：角色指名 / 买家本人 / 无角色泛化，先过请求门）。
function Test-ContactRequest([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    if ($Clause -match $script:ContactNegationGuard) { return $false }
    if ($Clause -match $script:ContactAskVerbPattern) { return $true }
    if ($Clause -match $script:ContactAskPolitenessPattern) { return $true }
    return $false
}

function Test-RoleContactAsk([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    return [bool](($Clause -match $script:ContactRoleItemPattern) -or ($Clause -match $script:ContactItemOfRolePattern))
}

function Test-GenericContactAsk([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return $false }
    foreach ($p in $script:ContactGenericAskPatterns) { if ($Clause -match $p) { return $true } }
    return $false
}

function Test-ContactAsk([string]$Clause) {
    if (-not (Test-ContactRequest $Clause)) { return $false }
    return ((Test-PersonalContactAsk $Clause) -or (Test-RoleContactAsk $Clause) -or (Test-GenericContactAsk $Clause))
}

# 小句里是否**明确指向业务角色**（收货人或供应商）并说明用途。
function Get-ContactClauseRole([string]$Clause) {
    $role = ''
    if ($Clause -match $script:ContactRecipientRole) { $role = 'recipient' }
    elseif ($Clause -match $script:ContactSupplierRole) { $role = 'supplier' }
    $purpose = [bool]($Clause -match $script:ContactPurposeWords)
    return @{ Role = $role; Purpose = $purpose }
}

# 兼容入口（旧调用方）：返回 '' | 'buyer' | 'recipient' | 'supplier'。
$script:ContactRolePhraseScrub = ('(?i)\b(?:your|ur|the)\s+(?:' + $script:ContactRecipientRoleWords + '|' + $script:ContactSupplierRoleWords + ')(?:''s|s)?\s+(?:name|address(?:es)?|' + $script:ContactChannelWords + ')(?:(?:\s*,\s*|\s+)(?:name|address(?:es)?|' + $script:ContactChannelWords + '))*')

function Get-ContactAskObject([string]$Clause) {
    if ([string]::IsNullOrWhiteSpace($Clause)) { return '' }
    $scrubbed = [regex]::Replace($Clause, $script:ContactRolePhraseScrub, ' ROLE_ITEM ')
    if (Test-PersonalContactAsk $scrubbed) { return 'buyer' }
    if ($Clause -match $script:ContactRecipientRole) { return 'recipient' }
    if ($Clause -match $script:ContactSupplierRole) { return 'supplier' }
    return ''
}

# 角色是否在**本轮**被 AskFields 以任何字段形式授权（用于区分 CONTACT_ROLE_UNCLEAR 与
#   CONTACT_ASK_UNAUTHORIZED_FIELD）。
function Test-ContactRoleAuthorized($AuthorizedFields, [string]$Role) {
    foreach ($f in @($AuthorizedFields)) {
        if ($Role -eq 'recipient' -and $f -in @('recipient_contact', 'recipient_name', 'delivery_address')) { return $true }
        if ($Role -eq 'supplier' -and $f -in @('supplier_contact', 'supplier_address')) { return $true }
    }
    return $false
}

# =============================================================================================
# 主检查（消费同一份请求项列表；spec §3.3：初稿、一次重写、固定回退、直接事实与最终发送共用）
# =============================================================================================
# 返回 @{ Ok; Violations = @(@{Code;Severity;Detail}); Clauses; Items; AllowedFields }
#   Code: OUR_CONTACT_OFFER | BUYER_PERSONAL_CONTACT_ASK | CONTACT_ROLE_UNCLEAR |
#         CONTACT_ASK_NO_ROLE | CONTACT_ASK_ALREADY_PROVIDED | CONTACT_ASK_UNAUTHORIZED_FIELD
function Test-ContactRedline {
    [CmdletBinding()]
    param([string]$Text, $Decision = $null, $Facts = $null)
    $violations = New-Object System.Collections.ArrayList
    $allowed = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Ok = $true; Violations = @(); Clauses = @(); Items = @(); AllowedFields = @() }
    }
    $items = @(Get-ReplyRequestItems -Text $Text -Decision $Decision)
    $authorized = @(Get-ContactAuthorizedFields $Decision)
    $hasAskSet = [bool]($Decision -and ($Decision.PSObject.Properties.Name -contains 'AskFields') -and @($Decision.AskFields).Count -gt 0)
    foreach ($it in $items) {
        if ([string]$it.Action -eq 'offer') {
            [void]$violations.Add(@{ Code = 'OUR_CONTACT_OFFER'; Severity = 'block'; Detail = ('offers or invites our own contact channel: ' + [string]$it.Raw) })
            continue
        }
        if (-not [bool]$it.Contact) { continue }
        if ([string]$it.Role -eq 'buyer') {
            [void]$violations.Add(@{ Code = 'BUYER_PERSONAL_CONTACT_ASK'; Severity = 'block'; Detail = ('asks for the buyer''s own contact details: ' + [string]$it.Raw) })
            continue
        }
        if ([string]$it.Role -eq 'recipient' -or [string]$it.Role -eq 'supplier') {
            if ((Get-Command Test-AskClarifyWording -ErrorAction SilentlyContinue) -and (Test-AskClarifyWording $Text)) {
                $req=@(Get-ReplyClarificationRequests -Facts $Facts -Decision $Decision | Where-Object {$_.FieldKey -eq $it.FieldKey})
                if($req.Count -and (Test-ClarifyClauseBound $Text $req[0])){[void]$allowed.Add($it.FieldKey);continue}
            }
            # collect 顺序：① 该项已有有效 provided 事实 ⇒ 拒绝重复索取（授权不能覆盖它）；
            #              ② 该项本轮 AskFields 授权；③ 联系角色/业务用途成立。
            if (Test-ContactItemProvided $Facts ([string]$it.FieldKey)) {
                [void]$violations.Add(@{ Code = 'CONTACT_ASK_ALREADY_PROVIDED'; Severity = 'block'; Detail = ('asks again for the ' + [string]$it.FieldKey + ' this turn already has: ' + [string]$it.Raw) })
                continue
            }
            if ($authorized -contains [string]$it.FieldKey) {
                [void]$allowed.Add([string]$it.FieldKey)
                continue
            }
            if ($hasAskSet) {
                if (Test-ContactRoleAuthorized $authorized ([string]$it.Role)) {
                    [void]$violations.Add(@{ Code = 'CONTACT_ASK_UNAUTHORIZED_FIELD'; Severity = 'block'; Detail = ('asks for ' + [string]$it.FieldKey + ', which this turn''s AskFields [' + (@($Decision.AskFields) -join ',') + '] does not authorize: ' + [string]$it.Raw) })
                } else {
                    [void]$violations.Add(@{ Code = 'CONTACT_ROLE_UNCLEAR'; Severity = 'block'; Detail = ('asks for the ' + [string]$it.Role + ' contact details without this turn''s AskFields authorization: ' + [string]$it.Raw) })
                }
                continue
            }
            [void]$violations.Add(@{ Code = 'CONTACT_ROLE_UNCLEAR'; Severity = 'block'; Detail = ('asks for role contact details without stating a shipping purpose and without this turn''s AskFields authorization: ' + [string]$it.Raw) })
            continue
        }
        # 没有业务角色的联系方式请求：用途不能代替联系人的业务角色。
        [void]$violations.Add(@{ Code = 'CONTACT_ASK_NO_ROLE'; Severity = 'block'; Detail = ('asks for contact details without naming a business role (supplier / consignee): ' + [string]$it.Raw) })
    }
    $list = @($violations.ToArray())
    return [pscustomobject]@{
        Ok = ($list.Count -eq 0)
        Violations = $list
        Clauses = @($items | ForEach-Object { [string]$_.Text } | Select-Object -Unique)
        Items = $items
        AllowedFields = @($allowed.ToArray() | Select-Object -Unique)
    }
}

# 供生成器/提示词使用的允许措辞模板（角色 + 用途），避免模型自由发挥踩线。
function Get-ContactAllowedAskTemplates {
    return @(
        "Could you share the consignee's name, contact number and delivery address?",
        "Could you share your supplier's contact details so we can confirm the packing information?"
    )
}
