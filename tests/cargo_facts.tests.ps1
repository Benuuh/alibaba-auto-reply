# tests\cargo_facts.tests.ps1 - 单一货物事实模型 + 报价准备度（2026-10-05 spec §3.1-§3.4 / §7 验收样例）
#
# 纯逻辑测试：只 dot-source scripts\config.ps1、scripts\lib\paths.ps1、scripts\lib\msg_norm.ps1
#   （msg_norm 会带上 reply_engine 与 destination）和 scripts\lib\facts_engine.ps1。
# 不访问浏览器、不调用模型、不联网、不读写任何运行数据文件。
#
# 消息用 '[BUYER] ... @@TS:x @@MT:x @@OT:<base64>' 形式构造（写法参考 tests\reception_facts.tests.ps1）。
# @@OT 是买家原文，@@MT 是逐条时间（消息方向与身份的证据）。
#
# 覆盖的验收样例（spec §7 与事实相关的行）：
#   C04 买家表示没有尺寸 ⇒ 不标记尺寸已提供；C05 稍后发 ⇒ promised（本轮不重复追问）
#   C06 10 箱 × 每箱 20 kg × 每箱 50×40×30 cm ⇒ 推导 200 kg / 0.6 m³ 且带公式
#   C07 单箱重量与总重量分别保存；C08 已给总重不再乘一次件数
#   C09 100 个商品 ⇒ 商品数量按 goods 范围保存，包装件数仍缺
#   C10 只给数量不说单位 ⇒ needs_confirmation
#   C11 件数/重量/尺寸/收货地址齐全、其余缺失 ⇒ Ready=true 且 CollectionComplete=false
#   C12 标准清单齐全但没有件数 ⇒ Ready=false 且 MissingFields 含 carton_count
#   C13 只给供应商地址 ⇒ 不算收货地址（Ready 仍缺 delivery_address）
#   C14 收货人姓名/联系方式未提供 ⇒ 不阻挡 Ready；C15 明确亚马逊仓代码 ⇒ 不重复索要街道地址
#   C16 "sorry ... 25 kg per carton, not 20" ⇒ 新值生效 + Corrections 记录
#   C17 两个无法解释为更正的不同值 ⇒ conflict，不擅自取值
#   C18 目的仓更正 ⇒ 新目的地生效 + Corrections 记录
#   C19-C22 联系方式按业务角色分字段（买家本人 ≠ 收货人）；C23-C24 机器人复述不增加事实可信度
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\paths.ps1")
. (Join-Path $scripts "lib\msg_norm.ps1")
. (Join-Path $scripts "lib\facts_engine.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}
function Assert-Contains([string]$name, [object]$actual, [string]$needle) {
    $t = (@($actual) | ForEach-Object { [string]$_ }) -join ' '
    if ($t.IndexOf($needle) -ge 0) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$t] | want contains: $needle" }
}
function Assert-Match([string]$name, [object]$actual, [string]$pattern) {
    $t = (@($actual) | ForEach-Object { [string]$_ }) -join ' '
    if ($t -match $pattern) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$t] | want match: $pattern" }
}

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts, [string]$markers = '') {
    return ('[BUYER] ' + $t + ' ' + $markers + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t))
}
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
function HumanLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@MT:' + $ts) }
function Conv([string[]]$lines) { return (ConvertTo-MessageList ($lines -join $LF) 'Test Buyer') }
function Facts([string[]]$lines, $sent = $null) { return (Get-CargoFacts -Conversation (Conv $lines) -SentMatches $sent) }
function Field($facts, [string]$key) { return $facts.ByKey[$key] }
function DerivedVal($facts, [string]$key) {
    $hit = @(@($facts.Derived) | Where-Object { [string]$_.Key -eq $key })
    if ($hit.Count -eq 0) { return $null }
    return $hit[0]
}

$ts = [long]1759400000000
function NextTs { $script:ts = $script:ts + 1000; return $script:ts }

Write-Output "== cargo_facts tests =="

# ============================================================================================
# C01-C03 契约形状与规则版本
# ============================================================================================
$c01 = Facts @((BuyerLine 'We have 10 cartons, each 20 kg, deliver to Amazon ONT8.' (NextTs)))
Assert-Eq 'C01-facts-shape' (@('Fields', 'ByKey', 'Derived', 'Clarifications', 'Conflicts', 'Corrections', 'RuleVersion') | Where-Object { $c01.PSObject.Properties.Name -notcontains $_ }).Count 0
Assert-True 'C01-fields-nonempty' (@($c01.Fields).Count -gt 0)
$c01missing = @(@('carton_count', 'unit_weight', 'unit_dimensions', 'delivery_address', 'recipient_contact', 'supplier_contact', 'buyer_conversation_identity') | Where-Object { -not $c01.ByKey.ContainsKey($_) })
Assert-Eq 'C01-bykey-has-contract-keys' (@($c01missing).Count) 0
$c01props = @('Key', 'Label', 'Value', 'Unit', 'Scope', 'Status', 'Source', 'SourceIndex', 'UpdatedAt', 'Evidence')
$badFieldCount = 0
foreach ($fl in @($c01.Fields)) {
    foreach ($pr in $c01props) { if ($fl.PSObject.Properties.Name -notcontains $pr) { $badFieldCount++ } }
}
Assert-Eq 'C02-field-objects-have-contract-props' $badFieldCount 0
$allStatuses = @($c01.Fields | ForEach-Object { [string]$_.Status } | Select-Object -Unique)
$allowed = @('unknown', 'promised', 'provided', 'needs_confirmation', 'conflict')
Assert-Eq 'C02-only-five-statuses' (@($allStatuses | Where-Object { $allowed -notcontains $_ }).Count) 0
Assert-Eq 'C03-rule-version-facts' $c01.RuleVersion '2026-10-05.1'
Assert-Eq 'C03-rule-version-readiness' (Get-QuoteReadiness -Facts $c01).RuleVersion '2026-10-05.1'

# ============================================================================================
# C04-C05 "没有尺寸" != "尺寸已提供"；"稍后发" = promised
# ============================================================================================
$c04 = Facts @((BuyerLine 'I do not have dimensions yet' (NextTs)))
Assert-True 'C04-dimension-not-provided' (@($c04.Fields | Where-Object { $_.Key -match 'dimension' -and $_.Status -eq 'provided' }).Count -eq 0)
Assert-True 'C04-unit-dimensions-unknown-or-promised' (@('unknown', 'promised') -contains [string](Field $c04 'unit_dimensions').Status)
Assert-True 'C04-no-fabricated-value' ([string](Field $c04 'unit_dimensions').Value -eq '')
$c04r = Get-QuoteReadiness -Facts $c04
Assert-Eq 'C04-not-ready' $c04r.Ready $false
Assert-Contains 'C04-missing-dimensions' $c04r.MissingFields 'unit_dimensions'

$c05 = Facts @((BuyerLine 'I will send the dimensions, weight and carton count tomorrow.' (NextTs)))
Assert-Eq 'C05-dimensions-promised' (Field $c05 'unit_dimensions').Status 'promised'
Assert-Eq 'C05-generic-dimensions-promised' (Field $c05 'dimensions').Status 'promised'
Assert-Eq 'C05-weight-promised' (Field $c05 'unit_weight').Status 'promised'
Assert-Eq 'C05-count-promised' (Field $c05 'carton_count').Status 'promised'
Assert-Eq 'C05-promise-source' (Field $c05 'unit_dimensions').Source 'buyer'
$c05r = Get-QuoteReadiness -Facts $c05
Assert-Contains 'C05-reason-promised' $c05r.Reasons 'promised by the buyer'
Assert-Eq 'C05-not-ready' $c05r.Ready $false

# ============================================================================================
# C06 单件重量/尺寸 + 推导总重量与总体积（spec §7 "10 箱、每箱 20 kg、每箱 50×40×30 cm"）
# ============================================================================================
$c06lines = @((BuyerLine 'We have 10 cartons. Each carton is 20 kg and measures 50 x 40 x 30 cm. Please deliver to Amazon ONT8.' (NextTs)))
$c06 = Facts $c06lines
$cc = Field $c06 'carton_count'
$uw = Field $c06 'unit_weight'
$ud = Field $c06 'unit_dimensions'
Assert-Eq 'C06-carton-count-value' $cc.Value 10
Assert-Eq 'C06-carton-count-status' $cc.Status 'provided'
Assert-Eq 'C06-carton-count-scope' $cc.Scope 'cartons'
Assert-Eq 'C06-unit-weight-value' $uw.Value 20
Assert-Eq 'C06-unit-weight-scope' $uw.Scope 'unit'
Assert-Eq 'C06-unit-weight-unit' $uw.Unit 'kg'
Assert-Eq 'C06-unit-weight-source' $uw.Source 'buyer'
Assert-Eq 'C06-unit-dimensions-value' $ud.Value '50x40x30'
Assert-Eq 'C06-unit-dimensions-scope' $ud.Scope 'unit'
Assert-Eq 'C06-unit-dimensions-unit' $ud.Unit 'cm'
Assert-Eq 'C06-total-weight-not-stated' (Field $c06 'total_weight').Status 'unknown'
$dw = DerivedVal $c06 'total_weight_kg'
$dv = DerivedVal $c06 'total_volume_m3'
Assert-True 'C06-derived-total-weight-exists' ($null -ne $dw)
Assert-Eq 'C06-derived-total-weight-value' $dw.Value 200
Assert-Eq 'C06-derived-total-weight-unit' $dw.Unit 'kg'
Assert-Eq 'C06-derived-total-weight-formula' $dw.Formula '10 x 20 = 200'
Assert-Eq 'C06-derived-total-weight-sourcekeys' (($dw.SourceKeys) -join ',') 'carton_count,unit_weight'
Assert-True 'C06-derived-volume-exists' ($null -ne $dv)
Assert-Eq 'C06-derived-volume-value' $dv.Value 0.6
Assert-Eq 'C06-derived-volume-unit' $dv.Unit 'm3'
Assert-Eq 'C06-derived-volume-formula' $dv.Formula '10 x (50*40*30/1000000) = 0.6'
Assert-Eq 'C06-derived-volume-sourcekeys' (($dv.SourceKeys) -join ',') 'carton_count,unit_dimensions'
$c06r = Get-QuoteReadiness -Facts $c06
Assert-Eq 'C06-ready' $c06r.Ready $true
Assert-Eq 'C06-collection-incomplete' $c06r.CollectionComplete $false
Assert-Eq 'C06-no-missing-required' (@($c06r.MissingFields).Count) 0
Assert-Contains 'C06-delivery-satisfied-by-warehouse-code' $c06r.Reasons 'no street address is required'

# ============================================================================================
# C07 单箱重量与总重量分别保存（不同 Scope）；C08 已给总重不再乘一次件数
# ============================================================================================
$c07 = Facts @(
    (BuyerLine 'We have 10 cartons and each carton is 20 kg.' (NextTs)),
    (BuyerLine 'The total weight is 200 kg.' (NextTs))
)
Assert-Eq 'C07-unit-weight' (Field $c07 'unit_weight').Value 20
Assert-Eq 'C07-unit-weight-scope' (Field $c07 'unit_weight').Scope 'unit'
Assert-Eq 'C07-total-weight' (Field $c07 'total_weight').Value 200
Assert-Eq 'C07-total-weight-scope' (Field $c07 'total_weight').Scope 'total'
Assert-True 'C07-no-total-weight-derivation-when-total-given' ($null -eq (DerivedVal $c07 'total_weight_kg'))

$c08 = Facts @((BuyerLine 'We have 10 cartons. Total weight is 200 kg.' (NextTs)))
Assert-Eq 'C08-carton-count' (Field $c08 'carton_count').Value 10
Assert-Eq 'C08-total-weight' (Field $c08 'total_weight').Value 200
Assert-True 'C08-no-multiply-by-carton-count' ($null -eq (DerivedVal $c08 'total_weight_kg'))
Assert-Eq 'C08-no-unit-weight' (Field $c08 'unit_weight').Status 'unknown'
$c08r = Get-QuoteReadiness -Facts $c08
Assert-True 'C08-weight-category-satisfied-by-total' (-not (@($c08r.MissingFields) -contains 'unit_weight'))

# ============================================================================================
# C09-C10 数量范围：商品个数 vs 包装件数；无法判定 ⇒ needs_confirmation
# ============================================================================================
$c09 = Facts @((BuyerLine 'We have 100 pieces of the item and we have not packed them yet.' (NextTs)))
Assert-Eq 'C09-goods-count-value' (Field $c09 'goods_count').Value 100
Assert-Eq 'C09-goods-count-scope' (Field $c09 'goods_count').Scope 'goods'
Assert-Eq 'C09-carton-count-not-provided' (Field $c09 'carton_count').Status 'unknown'
$c09r = Get-QuoteReadiness -Facts $c09
Assert-Eq 'C09-not-ready' $c09r.Ready $false
Assert-Contains 'C09-missing-carton-count' $c09r.MissingFields 'carton_count'

$c10 = Facts @((BuyerLine 'Quantity: 20' (NextTs)))
Assert-Eq 'C10-ambiguous-count-status' (Field $c10 'count').Status 'needs_confirmation'
Assert-Eq 'C10-ambiguous-count-value' (Field $c10 'count').Value 20
Assert-Eq 'C10-carton-count-not-provided' (Field $c10 'carton_count').Status 'unknown'
Assert-True 'C10-clarification-raised' (@($c10.Clarifications).Count -ge 1)
$c10r = Get-QuoteReadiness -Facts $c10
Assert-Contains 'C10-missing-carton-count' $c10r.MissingFields 'carton_count'

# ============================================================================================
# C11 件数/重量/尺寸/收货地址齐全，其余缺失 ⇒ Ready=true 且 CollectionComplete=false
# ============================================================================================
$c11 = Facts @((BuyerLine 'We have 10 cartons. Each carton is 20 kg and measures 50 x 40 x 30 cm. Please deliver to Amazon ONT8.' (NextTs)))
$c11r = Get-QuoteReadiness -Facts $c11
Assert-Eq 'C11-ready' $c11r.Ready $true
Assert-Eq 'C11-collection-incomplete' $c11r.CollectionComplete $false
foreach ($k in @('goods_name', 'reference_images', 'supplier_address', 'supplier_contact', 'recipient_name', 'recipient_contact')) {
    Assert-Contains ('C11-optional-missing:' + $k) $c11r.OptionalMissingFields $k
}
Assert-Contains 'C11-reason-collection-incomplete' $c11r.Reasons 'collection incomplete'
Assert-Contains 'C11-reason-optional-not-blocking' $c11r.Reasons 'do not block basic quote preparation'

# ============================================================================================
# C12 标准清单齐全但没有件数 ⇒ Ready=false 且 MissingFields 含 carton_count
# ============================================================================================
$c12 = Facts @(
    (BuyerLine 'Product name: card holder' (NextTs) '@@IMG:http://example.invalid/1.jpg'),
    (BuyerLine 'The box weight is 20 kg per carton and each carton is 50 x 40 x 30 cm.' (NextTs)),
    (BuyerLine 'Our supplier address is 123 Main St, Los Angeles, CA 90001 and the supplier contact is +86 139 0000 2222.' (NextTs)),
    (BuyerLine 'The consignee name is John Smith and his contact number is +1 555 010 2233.' (NextTs)),
    (BuyerLine 'Please deliver to Amazon ONT8.' (NextTs))
)
Assert-Eq 'C12-goods-name' (Field $c12 'goods_name').Status 'provided'
Assert-Contains 'C12-goods-name-value' (Field $c12 'goods_name').Value 'card holder'
Assert-Eq 'C12-reference-images' (Field $c12 'reference_images').Status 'provided'
Assert-Eq 'C12-supplier-address' (Field $c12 'supplier_address').Status 'provided'
Assert-Contains 'C12-supplier-address-value' (Field $c12 'supplier_address').Value '123 Main St'
Assert-Eq 'C12-supplier-contact' (Field $c12 'supplier_contact').Status 'provided'
Assert-Eq 'C12-recipient-name' (Field $c12 'recipient_name').Value 'John Smith'
Assert-Eq 'C12-recipient-contact' (Field $c12 'recipient_contact').Status 'provided'
Assert-Eq 'C12-delivery-address' (Field $c12 'delivery_address').Status 'provided'
Assert-Eq 'C12-carton-count-missing' (Field $c12 'carton_count').Status 'unknown'
$c12r = Get-QuoteReadiness -Facts $c12
Assert-Eq 'C12-not-ready' $c12r.Ready $false
Assert-Contains 'C12-missing-carton-count' $c12r.MissingFields 'carton_count'
Assert-Eq 'C12-collection-incomplete' $c12r.CollectionComplete $false
Assert-Eq 'C12-optional-excludes-required' (@($c12r.OptionalMissingFields) -contains 'carton_count') $false

# ============================================================================================
# C13 只提供供应商地址 ⇒ 不算收货地址
# ============================================================================================
$c13 = Facts @(
    (BuyerLine 'We have 10 cartons. Each carton is 20 kg and measures 50 x 40 x 30 cm.' (NextTs)),
    (BuyerLine 'Our supplier address is 123 Main St, Los Angeles, CA 90001.' (NextTs))
)
Assert-True 'C13-delivery-address-not-provided' ((Field $c13 'delivery_address').Status -ne 'provided')
Assert-Eq 'C13-supplier-address-provided' (Field $c13 'supplier_address').Status 'provided'
$c13r = Get-QuoteReadiness -Facts $c13
Assert-Eq 'C13-not-ready' $c13r.Ready $false
Assert-Contains 'C13-missing-delivery-address' $c13r.MissingFields 'delivery_address'
Assert-Eq 'C13-no-other-missing-required' ((@($c13r.MissingFields) | Where-Object { $_ -ne 'delivery_address' }).Count) 0

# ============================================================================================
# C14 收货人资料缺失不阻挡 Ready；C15 明确亚马逊仓代码满足报价目的地
# ============================================================================================
$c14r = Get-QuoteReadiness -Facts $c11
Assert-Eq 'C14-ready-without-recipient' $c14r.Ready $true
Assert-Contains 'C14-recipient-name-optional' $c14r.OptionalMissingFields 'recipient_name'
Assert-Contains 'C14-recipient-contact-optional' $c14r.OptionalMissingFields 'recipient_contact'
Assert-Eq 'C15-delivery-address-provided' (Field $c11 'delivery_address').Status 'provided'
Assert-Contains 'C15-delivery-address-is-warehouse' (Field $c11 'delivery_address').Value 'ONT8'
Assert-Contains 'C15-no-street-address-asked' $c14r.Reasons 'no street address is required'
Assert-Eq 'C15-destination-evidence-kind' (([string](Field $c11 'delivery_address').Evidence[0].Kind)) 'amazon_warehouse'

# ============================================================================================
# C16 明确更正：新值生效 + Corrections 记录
# ============================================================================================
$c16 = Facts @(
    (BuyerLine 'We have 10 cartons. Each carton is 20 kg. Please deliver to Amazon ONT8.' (NextTs)),
    (BuyerLine 'Sorry, it is 25 kg per carton, not 20.' (NextTs))
)
Assert-Eq 'C16-new-value-wins' (Field $c16 'unit_weight').Value 25
Assert-Eq 'C16-not-conflict' (Field $c16 'unit_weight').Status 'provided'
Assert-Eq 'C16-correction-count' (@($c16.Corrections).Count) 1
Assert-Eq 'C16-correction-key' $c16.Corrections[0].Key 'unit_weight'
Assert-Eq 'C16-correction-from' $c16.Corrections[0].From 20
Assert-Eq 'C16-correction-to' $c16.Corrections[0].To 25
Assert-Eq 'C16-correction-source-index' $c16.Corrections[0].SourceIndex 1
Assert-Eq 'C16-derived-uses-new-value' (DerivedVal $c16 'total_weight_kg').Value 250
Assert-Eq 'C16-derived-formula-uses-new-value' (DerivedVal $c16 'total_weight_kg').Formula '10 x 25 = 250'
$c16r = Get-QuoteReadiness -Facts $c16
Assert-Contains 'C16-reason-corrections-applied' $c16r.Reasons 'corrections applied'

# ============================================================================================
# C17 两个无法解释为更正的不同值 ⇒ conflict（不擅自取第一个/最后一个）
# ============================================================================================
$c17 = Facts @(
    (BuyerLine 'We have 10 cartons. Each carton is 20 kg. Please deliver to Amazon ONT8.' (NextTs)),
    (BuyerLine 'The carton weight is 25 kg.' (NextTs))
)
Assert-Eq 'C17-conflict-status' (Field $c17 'unit_weight').Status 'conflict'
Assert-Eq 'C17-conflict-value-empty' ([string](Field $c17 'unit_weight').Value) ''
Assert-Eq 'C17-conflict-recorded' (@($c17.Conflicts).Count) 1
Assert-Eq 'C17-conflict-key' $c17.Conflicts[0].Key 'unit_weight'
Assert-Eq 'C17-conflict-values' ((@($c17.Conflicts[0].Values) | ForEach-Object { [string]$_ }) -join ',') '20,25'
Assert-True 'C17-clarification-raised' (@($c17.Clarifications).Count -ge 1)
Assert-Eq 'C17-no-corrections' (@($c17.Corrections).Count) 0
Assert-True 'C17-no-derived-total-weight' ($null -eq (DerivedVal $c17 'total_weight_kg'))
$c17r = Get-QuoteReadiness -Facts $c17
Assert-Eq 'C17-not-ready' $c17r.Ready $false
Assert-Contains 'C17-missing-weight' $c17r.MissingFields 'unit_weight'
Assert-Contains 'C17-reason-conflict' $c17r.Reasons 'unresolved conflict: unit_weight'

# ============================================================================================
# C18 目的仓更正：新目的地生效 + Corrections 记录（历史证据保留）
# ============================================================================================
$c18 = Facts @(
    (BuyerLine 'Please deliver to Amazon LAX9.' (NextTs)),
    (BuyerLine 'Change warehouse to ONT8 please.' (NextTs))
)
Assert-Contains 'C18-new-destination-wins' (Field $c18 'delivery_address').Value 'ONT8'
Assert-Eq 'C18-destination-provided' (Field $c18 'delivery_address').Status 'provided'
$c18c = @($c18.Corrections | Where-Object { [string]$_.Key -eq 'delivery_address' })
Assert-Eq 'C18-destination-correction-recorded' $c18c.Count 1
Assert-Contains 'C18-correction-from' $c18c[0].From 'LAX9'
Assert-Contains 'C18-correction-to' $c18c[0].To 'ONT8'

# ============================================================================================
# C19-C22 联系方式按业务角色分字段（red line：买家本人联系方式 != 收货资料）
# ============================================================================================
$c19 = Facts @((BuyerLine 'My WhatsApp is +86 138 0000 1111, you can reach me there.' (NextTs)))
Assert-Eq 'C19-buyer-identity-recorded' (Field $c19 'buyer_conversation_identity').Status 'provided'
Assert-Contains 'C19-buyer-identity-value' (Field $c19 'buyer_conversation_identity').Value '138'
Assert-True 'C19-not-recipient-contact' ((Field $c19 'recipient_contact').Status -ne 'provided')
Assert-Eq 'C19-recipient-contact-unknown' (Field $c19 'recipient_contact').Status 'unknown'
$c19r = Get-QuoteReadiness -Facts $c19
Assert-Contains 'C19-recipient-contact-still-missing' $c19r.OptionalMissingFields 'recipient_contact'
Assert-Eq 'C19-not-ready' $c19r.Ready $false

$c20 = Facts @((BuyerLine 'Consignee: John Smith. Consignee contact number: +1 555 010 2233.' (NextTs)))
Assert-Eq 'C20-recipient-name' (Field $c20 'recipient_name').Value 'John Smith'
Assert-Eq 'C20-recipient-contact-status' (Field $c20 'recipient_contact').Status 'provided'
Assert-Eq 'C20-recipient-contact-scope' (Field $c20 'recipient_contact').Scope 'recipient'
Assert-Contains 'C20-recipient-contact-value' (Field $c20 'recipient_contact').Value '555'
Assert-True 'C20-not-supplier-contact' ((Field $c20 'supplier_contact').Status -ne 'provided')

$c21 = Facts @((BuyerLine 'Our supplier contact is +86 139 0000 2222.' (NextTs)))
Assert-Eq 'C21-supplier-contact-status' (Field $c21 'supplier_contact').Status 'provided'
Assert-Eq 'C21-supplier-contact-scope' (Field $c21 'supplier_contact').Scope 'supplier'
Assert-True 'C21-not-recipient-contact' ((Field $c21 'recipient_contact').Status -ne 'provided')

$c22 = Facts @((BuyerLine 'Phone: +1 555 010 2233' (NextTs)))
Assert-Eq 'C22-role-unknown-contact' (Field $c22 'unassigned_contact').Status 'needs_confirmation'
Assert-True 'C22-not-recipient-contact' ((Field $c22 'recipient_contact').Status -ne 'provided')
Assert-True 'C22-clarification-raised' (@($c22.Clarifications).Count -ge 1)

# ============================================================================================
# C23-C24 机器人复述不增加事实可信度；人工消息可作为人工确认来源
# ============================================================================================
$c23 = Facts @(
    (MeLine 'The total weight is 200 kg and the carton count is 10.' (NextTs)),
    (BuyerLine 'Yes please deliver to Amazon ONT8.' (NextTs)),
    (HumanLine 'Confirmed with the supplier: 12 cartons.' (NextTs))
)
Assert-True 'C23-robot-restatement-not-a-fact' ((Field $c23 'total_weight').Status -ne 'provided')
Assert-Eq 'C23-robot-restatement-unknown' (Field $c23 'total_weight').Status 'unknown'
Assert-Eq 'C23-human-confirmation-count' (Field $c23 'carton_count').Value 12
Assert-Eq 'C23-human-confirmation-source' (Field $c23 'carton_count').Source 'human'

$c24lines = @(
    (BuyerLine 'Hello, we want to ship some goods.' (NextTs)),
    ('[ME] The total weight is 200 kg. @@MT:' + (NextTs))
)
$c24a = Facts $c24lines @{ 1 = $true }
Assert-True 'C24-confirmed-send-record-is-our-message' ((Field $c24a 'total_weight').Status -ne 'provided')
$c24b = Facts $c24lines
Assert-Eq 'C24-hand-typed-me-line-is-human-evidence' (Field $c24b 'total_weight').Value 200

# ============================================================================================
# C25-C27 边界：空会话、空事实、机器人消息不产生图片事实
# ============================================================================================
$c25 = Get-CargoFacts -Conversation (Conv @())
Assert-True 'C25-empty-conversation-facts' ($null -ne $c25)
Assert-Eq 'C25-empty-no-conflicts' (@($c25.Conflicts).Count) 0
Assert-Eq 'C25-empty-carton-count-unknown' (Field $c25 'carton_count').Status 'unknown'
$c25r = Get-QuoteReadiness -Facts $c25
Assert-Eq 'C25-empty-not-ready' $c25r.Ready $false
Assert-Eq 'C25-empty-missing-four' (@($c25r.MissingFields).Count) 4
Assert-Eq 'C25-missing-field-vocabulary' ((@($c25r.MissingFields) -join ',')) 'carton_count,unit_weight,unit_dimensions,delivery_address'
$c26r = Get-QuoteReadiness -Facts $null
Assert-Eq 'C26-null-facts-not-ready' $c26r.Ready $false
Assert-Eq 'C26-null-facts-rule-version' $c26r.RuleVersion '2026-10-05.1'

$c27 = Facts @((MeLine 'Photo of the cartons' (NextTs) ))
$c27b = Facts @((BuyerLine 'Here are the photos' (NextTs) '@@IMG:http://example.invalid/2.jpg'))
Assert-Eq 'C27-buyer-image-is-a-fact' (Field $c27b 'reference_images').Status 'provided'
Assert-True 'C27-our-image-is-not-a-buyer-fact' ((Field $c27 'reference_images').Status -ne 'provided')

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
