# tests\review_fixes.tests.ps1 - 架构审查六项(A1/A4/A6 + 账本状态 + 时间地点绑定)纯函数层验收
#
# 依据：docs\specs\架构审查六项与时间地点绑定修复_spec_20261005.md §1 / §4 / §5 / §6 / §7。
# 分层：pure（无浏览器、无模型、无发送、无通知、不解析生产路径以外的运行态文件）。
# 入口层（真实 monitor 函数 + 发送桩）在 tests\review_fixes_entry.tests.ps1（isolated 层）。
#
# 覆盖：
#   A1  联系邀约/渠道披露与无角色联系索取必须阻断；角色 + 用途的收货/供应商询问放行
#   A4  报价候选必须消费唯一判据 Get-QuoteReadiness（缺件数不进名单）
#   A6  'per carton / each pallet' 是单位修饰语，不是件数询问；真正的件数询问仍需授权
#   T1/T2 时间问句的地点三态与问题归属
#   账本 missing/empty/valid/corrupt 四态（A5 的纯函数部分）
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\contact_rules.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }
function BlockingCodes($r) { return (@($r.Violations | Where-Object { $_.Severity -eq 'block' } | ForEach-Object { $_.Code }) -join ',') }

Write-Output '== review_fixes tests (pure layer) =='

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function Conv([string[]]$l) { return (ConvertTo-MessageList ($l -join $LF) 'Buyer Fix') }
$P_FULL = '{"seller_profile":{"company_name_en":"Example Freight","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$prof = Get-SellerProfile -Config ($P_FULL | ConvertFrom-Json)
$utc = [datetime]::SpecifyKind([datetime]::Parse('2026-10-05T06:05:00', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
function Ctx($p, [datetime]$t) { return (New-ReplyRuntimeContext -SellerProfile $p -NowUtc $t) }
function Decide([string[]]$l, $rt) { $c = Conv $l; return (Get-ReplyDecision -Conversation $c -Facts (Get-ConversationFacts $c) -Rules $null -RuntimeContext $rt) }
function AskDec([string[]]$ask) { return [pscustomobject]@{ AskFields = @($ask); Facts = $null; RequestedFacts = @(); ActionEvidence = $null } }
$rt = Ctx $prof $utc

# ============================================================================================
# A1 - 联系方式最高优先级红线
# ============================================================================================
$a1Ask = AskDec @()
# 1) 单纯联系邀约：既没有 at/on/via 后缀，也不带号码，旧实现整句跳过。
foreach ($t in @('You can email me if that is easier.', 'You can email us if that is easier.', 'Call me if that is faster.', 'You can text me anytime.')) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $a1Ask
    Check ('A1-invitation-blocked [' + $t + ']') (-not $r.Ok) (Codes $r)
    Check ('A1-invitation-code [' + $t + ']') ((Codes $r) -match 'OUR_CONTACT_OFFER') (Codes $r)
}
# 2) 笼统索取联系方式：物流用途不能代替联系人的业务角色。
foreach ($t in @('Please leave a phone number for delivery updates.', 'Please leave a contact number for delivery updates.', 'Please provide a contact number so the carrier can call.', 'Could you leave a contact number for the shipment?')) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $a1Ask
    Check ('A1-generic-ask-blocked [' + $t + ']') (-not $r.Ok) (Codes $r)
    Check ('A1-generic-ask-code [' + $t + ']') ((Codes $r) -match 'CONTACT_ASK_NO_ROLE|BUYER_PERSONAL_CONTACT_ASK') (Codes $r)
}
# 3) 不含 your 的同义变体同样阻断。
foreach ($t in @('Drop me an email if that works better.', 'Feel free to reach me on WhatsApp.', 'Just email me the details.')) {
    $r = Test-ContactRedline -Text $t -Decision ([pscustomobject]@{AskFields=@('recipient_name','recipient_contact','delivery_address','supplier_contact')})
    Check ('A1-no-your-variant-blocked [' + $t + ']') (-not $r.Ok) (Codes $r)
}
# 4) 允许：角色 + 用途（收货人 / 供应商）。
foreach ($t in @(
    "Could you share the consignee's contact number for delivery?",
    "Could you share your supplier's contact details so we can confirm the packing information?",
    "Please share the recipient's phone number for delivery.",
    "Could you send the consignee's contact so the carrier can reach them?")) {
    $r = Test-ContactRedline -Text $t -Decision ([pscustomobject]@{AskFields=@('recipient_name','recipient_contact','delivery_address','supplier_contact')})
    Check ('A1-role-purpose-allowed [' + $t + ']') ([bool]$r.Ok) (Codes $r)
}
# 5) 一个小句提到供应商不得豁免别的小句的我方邀约。
$mixed = "We'll contact your supplier directly and you can email me if easier."
$rm = Test-ReplyCompliance -Text $mixed -Rules $null -Decision $a1Ask
Check 'A1-mixed-supplier-plus-invitation-blocked' (-not $rm.Ok) (Codes $rm)
Check 'A1-mixed-invitation-code' ((Codes $rm) -match 'OUR_CONTACT_OFFER') (Codes $rm)
# 6) [独立复核 R09] '供应商已给出联系人'是**事实声明**：无来源不得放行；但它仍不是索取（红线码不适用）。
$narr = Test-ReplyCompliance -Text 'The supplier already gave us their contact person.' -Rules $null -Decision $a1Ask
Check 'A1-supplier-narrative-needs-evidence' (-not [bool]$narr.Ok) (Codes $narr)
Check 'A1-supplier-narrative-evidence-code' ((Codes $narr) -match 'UNSUPPORTED_RECEIVED_FACT') (Codes $narr)
Check 'A1-supplier-narrative-not-an-offer' (-not ((Codes $narr) -match 'OUR_CONTACT_OFFER')) (Codes $narr)
# 7) 已提供的角色联系方式不再被当成'未授权字段'（旧实现报 ASK_OUT_OF_SCOPE，自相矛盾）。
$dSup = Decide @((BuyerLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." 1791170000000)) $rt
Check 'A1-supplied-supplier-contact-recognised' ([bool]$dSup.Facts.HasSupplierContact) ''
$rSup = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision $dSup
Check 'A1-supplied-field-not-out-of-scope' (-not ((BlockingCodes $rSup) -match 'ASK_OUT_OF_SCOPE')) (Codes $rSup)
Check 'A1-supplied-field-reported-as-reask' ((BlockingCodes $rSup) -match 'ASK_ALREADY_PROVIDED') (Codes $rSup)
# 8) 真正的允许路径（供应商尚未提供联系方式 + 本轮授权）在整个检查里也放行。
$dGap = Decide @((BuyerLine 'We need a freight quote for 10 cartons to Hamburg.' 1791170000000)) $rt
$allowDec = [pscustomobject]@{ AskFields = @('supplier'); Facts = $dGap.Facts; RequestedFacts = @(); ActionEvidence = $null }
$rAllow = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision $allowDec
Check 'A1-authorized-supplier-ask-passes-full-check' ([bool]$rAllow.Ok) (Codes $rAllow)
# 9) 固定回退同样过检查（不留无校验出口）。
$convFix = Conv @((BuyerLine 'Can you quote 10 cartons to Hamburg?' 1791170000000))
$factsFix = Get-ConversationFacts $convFix
foreach ($scenario in @('new_inquiry', 'details_given', 'dimension_missing', 'human_requested', 'complaint', 'delivery_status', 'supplier_unreachable', 'short_ack', 'material_promised', 'address_clarify', 'refusal')) {
    $fd = Get-ReplyDecision -Conversation $convFix -Facts $factsFix -ForceScenario $scenario
    $fb = Get-ScenarioFallback -Decision $fd
    if (-not $fb) { continue }
    $chk = Test-ReplyCompliance -Text $fb -Rules $null -Decision $fd
    Check ('A1-fallback-compliant [' + $scenario + ']') ([bool]$chk.Ok) ((Codes $chk) + ' :: ' + $fb)
}
Write-Output '  A1 done'

# ============================================================================================
# A4 - 报价候选消费唯一判据
# ============================================================================================
$snippetNoCount = (BuyerLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' 1791170000000)
$snippetCount = (BuyerLine '10 cartons, total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' 1791170000001)
$rwNo = Get-QuoteReadinessForConversationText -Text $snippetNoCount -ConvoName 'Virtual NoCount Buyer'
Check 'A4-no-count-not-ready' (-not [bool]$rwNo.Ready) ('missing=' + (@($rwNo.MissingFields) -join ','))
Check 'A4-no-count-missing-is-carton-count' ((@($rwNo.MissingFields)) -contains 'carton_count') ('missing=' + (@($rwNo.MissingFields) -join ','))
$rwYes = Get-QuoteReadinessForConversationText -Text $snippetCount -ConvoName 'Virtual Count Buyer'
Check 'A4-with-count-ready' ([bool]$rwYes.Ready) ('missing=' + (@($rwYes.MissingFields) -join ','))
# 四项齐全但没有图片/联系人仍可报价（可报价与清单齐全分开）。
Check 'A4-ready-with-incomplete-collection' (-not [bool]$rwYes.CollectionComplete) ''
# 'I do not have dimensions yet' 不满足尺寸项。
$rwDim = Get-QuoteReadinessForConversationText -Text (BuyerLine '10 cartons, 200 kg total, DDP to Amazon FTW1, I do not have dimensions yet' 1791170000002) -ConvoName 'B'
Check 'A4-promised-dimensions-not-ready' (-not [bool]$rwDim.Ready) ('missing=' + (@($rwDim.MissingFields) -join ','))
# 商品件数不能代替外包装件数。
$rwGoods = Get-QuoteReadinessForConversationText -Text (BuyerLine '500 pcs, 200 kg total, 50x40x30 cm per carton, DDP to Amazon FTW1' 1791170000003) -ConvoName 'C'
Check 'A4-goods-count-does-not-satisfy-carton-count' ((@($rwGoods.MissingFields)) -contains 'carton_count') ('missing=' + (@($rwGoods.MissingFields) -join ','))
# 供应商地址不能冒充收货地址。
$rwSupAddr = Get-QuoteReadinessForConversationText -Text (BuyerLine '10 cartons, 200 kg total, 50x40x30 cm, supplier address is 1 Example Road' 1791170000004) -ConvoName 'D'
Check 'A4-supplier-address-not-destination' (-not [bool]$rwSupAddr.Ready) ('missing=' + (@($rwSupAddr.MissingFields) -join ','))
# 明确总重不再乘件数（派生值只在缺少总重时计算）。
$rwDerived = Get-QuoteReadinessForConversationText -Text (BuyerLine '10 cartons, 20 kg per carton, 50x40x30 cm, DDP to Amazon FTW1' 1791170000005) -ConvoName 'E'
$derivedKeys = @()
if ($rwDerived.CargoFacts) { $derivedKeys = @(@($rwDerived.CargoFacts.Derived) | ForEach-Object { [string]$_.Key + '=' + [string]$_.Value }) }
Check 'A4-derived-total-weight-from-unit' ([bool](($derivedKeys -join ',') -match 'total_weight_kg=200')) ($derivedKeys -join ',')
Write-Output '  A4 done'

# ============================================================================================
# A6 - 单位修饰语不是件数询问
# ============================================================================================
$dw = AskDec @('weight')
$dd = AskDec @('dimension', 'unit_dimensions')
$dc = AskDec @('carton_count')
$a6 = @(
    @{ t = 'Could you share the packed weight per carton?'; d = $dw; want = $true },
    @{ t = 'Could you share the weight of each pallet?'; d = $dw; want = $true },
    @{ t = 'Could you share the total weight?'; d = $dw; want = $true },
    @{ t = 'Could you share the dimensions of each carton?'; d = $dd; want = $true },
    @{ t = 'Could you share the packed dimensions per carton or pallet (L x W x H)?'; d = $dd; want = $true },
    @{ t = 'How many cartons are there?'; d = $dw; want = $false },
    @{ t = 'Could you share the weight per carton and how many cartons?'; d = $dw; want = $false },
    @{ t = 'Could you share the number of cartons or pallets?'; d = $dc; want = $true },
    @{ t = 'Could you share the number of cartons or pallets?'; d = $dw; want = $false },
    @{ t = 'Could you share the carton count?'; d = $dw; want = $false },
    @{ t = 'Could you share the carton sizes (L x W x H)?'; d = $dd; want = $true },
    @{ t = 'Could you share the delivery address?'; d = $dw; want = $false }
)
foreach ($c in $a6) {
    $r = Test-ReplyCompliance -Text $c.t -Rules $null -Decision $c.d
    Check ('A6 [' + $c.t + ']') (([bool]$r.Ok) -eq [bool]$c.want) ('want=' + $c.want + ' got=' + $r.Ok + ' ' + (Codes $r))
}
# 已提供重量时再次索取仍阻断（真实事实模型）。
$convWeight = Conv @((BuyerLine '10 cartons, 200 kg total, 50x40x30 cm, DDP to Amazon FTW1' 1791170000000))
$factsWeight = Get-ConversationFacts $convWeight
$dWeight = Get-ReplyDecision -Conversation $convWeight -Facts $factsWeight -Rules $null -RuntimeContext $rt
$rAgain = Test-ReplyCompliance -Text 'Could you share the total weight?' -Rules $null -Decision $dWeight
Check 'A6-already-provided-weight-blocked' (-not [bool]$rAgain.Ok) (Codes $rAgain)
Check 'A6-already-provided-code' ((BlockingCodes $rAgain) -match 'ASK_ALREADY_PROVIDED') (Codes $rAgain)
# 单位修饰语判据本身（供后续维护者核对语义）。
Check 'A6-unit-modifier-per-carton' ([bool](Test-AskUnitModifier 'the packed weight per carton')) ''
Check 'A6-unit-modifier-not-a-count-request' (-not [bool](Test-AskCountRequest 'the packed weight per carton')) ''
Check 'A6-quantifier-is-a-count-request' ([bool](Test-AskCountRequest 'how many cartons')) ''
Write-Output '  A6 done'

# ============================================================================================
# T1 / T2 - 时间问答地点绑定
# ============================================================================================
function TimeCase([string]$id, [string]$q, [string]$wantPlace, [string]$wantKind) {
    $d = Decide @((BuyerLine $q 1791170000000)) $rt
    Eq ($id + '-place') ([string]$d.RequestedPlace) $wantPlace
    Eq ($id + '-kind') ([string]$d.RequestedPlaceKind) $wantKind
    return $d
}
# 大小写不决定'是否指定了地点'：两者目标状态一致。
$t1a = TimeCase 'T1-lower' 'What time is it in hamburg?' 'hamburg' 'explicit'
$t1b = TimeCase 'T1-upper' 'What time is it in Hamburg?' 'Hamburg' 'explicit'
Check 'T1-no-seller-clock' (-not ([string]$t1a.DirectFactText -match '2:05 PM')) ([string]$t1a.DirectFactText)
Check 'T1-upper-no-seller-clock' (-not ([string]$t1b.DirectFactText -match '2:05 PM')) ([string]$t1b.DirectFactText)
# 明确地点解析不了 => 保持 explicit 且 Resolved=false，只澄清。
Eq 'T1-lower-resolved' ([bool]$t1a.RequestedPlaceResolved) $true
Eq 'T1-unknown-place-resolved' ([bool](Decide @((BuyerLine 'What time is it in Atlantis?' 1791170000000)) $rt).RequestedPlaceResolved) $false
$t1u = Decide @((BuyerLine 'What time is it in Atlantis?' 1791170000000)) $rt
Check 'T1-unknown-place-clarifies-only' ([bool]($t1u.DirectFactText -match 'Which country or time zone')) ([string]$t1u.DirectFactText)
Check 'T1-unknown-place-no-clock' (-not ([string]$t1u.DirectFactText -match '\d{1,2}:\d{2}')) ([string]$t1u.DirectFactText)
# T2: 后句的公司所在地不得覆盖时间目标。
$t2a = TimeCase 'T2a' 'What time is it in China? My company is in Tokyo.' 'China' 'explicit'
Check 'T2a-answers-china' ([bool]($t2a.DirectFactText -match '2:05 PM in China')) ([string]$t2a.DirectFactText)
$t2b = TimeCase 'T2b' 'What time is it now? My company is in Tokyo.' '' 'seller'
Check 'T2b-answers-seller-zone' ([bool]($t2b.DirectFactText -match '2:05 PM in China')) ([string]$t2b.DirectFactText)
# 同一句里业务从句不得覆盖时间目标。
$t2c = Decide @((BuyerLine 'What time is it, my company is in Tokyo?' 1791170000000)) $rt
Check 'T2c-same-sentence-business-clause-ignored' ([bool]($t2c.DirectFactText -match '2:05 PM in China')) ([string]$t2c.RequestedPlace + ' :: ' + [string]$t2c.DirectFactText)
# 时间问题后接供应商/仓库/运输目的地句。
foreach ($pair in @(
    @{ q = 'What time is it in China? Our supplier is in Tokyo.'; want = 'China' },
    @{ q = 'What time is it in China? The warehouse is in Hamburg.'; want = 'China' },
    @{ q = 'What time is it in China? We are shipping to Tokyo.'; want = 'China' })) {
    $dx = Decide @((BuyerLine $pair.q 1791170000000)) $rt
    Eq ('T2d-business-place-ignored [' + $pair.q + ']') ([string]$dx.RequestedPlace) $pair.want
}
# 多条未答消息：保留消息边界。
$t2e = Decide @((BuyerLine 'What time is it in China?' 1791170000000), (BuyerLine 'By the way my company is in Tokyo.' 1791170001000)) $rt
Check 'T2e-multi-message-boundary-kept' ([bool]($t2e.DirectFactText -match '2:05 PM in China')) ([string]$t2e.RequestedPlace + ' :: ' + [string]$t2e.DirectFactText)
# 三种口语变体都指向东京。
foreach ($q in @('What time is it now in Tokyo?', 'What time is it in Tokyo now?', "What's the current time in Tokyo?")) {
    $dv = Decide @((BuyerLine $q 1791170000000)) $rt
    Eq ('T1-variant-place [' + $q + ']') ([string]$dv.RequestedPlace) 'Tokyo'
    Check ('T1-variant-answers-tokyo [' + $q + ']') ([bool]($dv.DirectFactText -match '3:05 PM in Tokyo')) ([string]$dv.DirectFactText)
}
# here / my local time：缺买家时区 => 澄清一次，不猜地点。
foreach ($q in @('what time is it here?', 'what is my local time')) {
    $dh = Decide @((BuyerLine $q 1791170000000)) $rt
    Eq ('T-here-kind [' + $q + ']') ([string]$dh.RequestedPlaceKind) 'unknown'
    Check ('T-here-clarify [' + $q + ']') ([bool]($dh.DirectFactText -match 'Which country or time zone')) ([string]$dh.DirectFactText)
}
# 多时区国家缺城市 => 澄清；明确城市 => 可靠转换。
$dUs = Decide @((BuyerLine 'What time is it in the USA?' 1791170000000)) $rt
Check 'T-multizone-country-clarifies' ([bool]($dUs.DirectFactText -match 'Which city or time zone in the United States')) ([string]$dUs.DirectFactText)
Check 'T-multizone-country-no-clock' (-not ([string]$dUs.DirectFactText -match '\d{1,2}:\d{2}')) ([string]$dUs.DirectFactText)
$dNy = Decide @((BuyerLine 'What time is it in New York?' 1791170000000)) $rt
Check 'T-explicit-city-converts' ([bool]($dNy.DirectFactText -match '2:05 AM in New York')) ([string]$dNy.DirectFactText)
# 混合请求：公司名与时间都答，顺序不变。
$dMix = Decide @((BuyerLine "What's the name of your company? And what time is it in Tokyo?" 1791170000000)) $rt
Check 'T-mixed-company-answered' ([bool]($dMix.DirectFactText -match 'Example Freight')) ([string]$dMix.DirectFactText)
Check 'T-mixed-time-answered' ([bool]($dMix.DirectFactText -match '3:05 PM in Tokyo')) ([string]$dMix.DirectFactText)
Check 'T-mixed-no-seller-clock' (-not ([string]$dMix.DirectFactText -match '2:05 PM')) ([string]$dMix.DirectFactText)
# 正确时间前缀 + 模型正文错误时刻/时区/身份 => 完整最终检查阻断。
$mixTimeConv = Conv @((BuyerLine 'What time is it now? And can you quote 10 cartons to Hamburg?' 1791170000000))
$mixTimeDec = Get-ReplyDecision -Conversation $mixTimeConv -Facts (Get-ConversationFacts $mixTimeConv) -Rules $null -RuntimeContext $rt
$chkWrong = Test-ReplyCompliance -Text "It's 9:40 AM in China (UTC+8). Happy to quote." -Rules $null -Decision $mixTimeDec
Check 'T-wrong-clock-after-correct-prefix-blocked' (-not [bool]$chkWrong.Ok) (Codes $chkWrong)
$chkRight = Test-ReplyCompliance -Text "It's 2:05 PM in China (UTC+8). Happy to quote." -Rules $null -Decision $mixTimeDec
Check 'T-correct-clock-allowed' ([bool]$chkRight.Ok) (Codes $chkRight)
Write-Output '  T1/T2 done'

# ============================================================================================
# 账本四态（A5 纯函数部分）
# ============================================================================================
$ledgerDir = Join-Path $env:TEMP ('aar-ledger-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
$encBom = New-Object System.Text.UTF8Encoding($true)
$ledger = Join-Path $ledgerDir 'state.json'
Eq 'L-missing' (Read-JsonDocument $ledger).Status 'missing'
[System.IO.File]::WriteAllText($ledger, '   ', $enc)
Eq 'L-empty' (Read-JsonDocument $ledger).Status 'empty'
$raw15 = New-Object System.Collections.Generic.List[byte]
foreach ($b in @(0xEF, 0xBB, 0xBF)) { [void]$raw15.Add([byte]$b) }
foreach ($b in [Text.Encoding]::UTF8.GetBytes('{"replied":{')) { [void]$raw15.Add([byte]$b) }
[System.IO.File]::WriteAllBytes($ledger, $raw15.ToArray())
Eq 'L-15byte-bytes' (Get-Item $ledger).Length 15
Eq 'L-15byte-corrupt' (Read-JsonDocument $ledger).Status 'corrupt'
Eq 'L-15byte-not-valid' (Read-JsonDocument $ledger).Status 'corrupt'
foreach ($size in @(1, 20, 99, 100, 101, 4096)) {
    $pad = '{"replied":{"x":"' + ('y' * ([Math]::Max(0, $size - 20)))
    [System.IO.File]::WriteAllText($ledger, $pad, $enc)
    Eq ('L-corrupt-size-' + $size) (Read-JsonDocument $ledger).Status 'corrupt'
}
# 合法空账本 = 有效（不是损坏，也不是'没有账本'）。
[System.IO.File]::WriteAllText($ledger, '{"replied":{}}', $enc)
Eq 'L-valid-empty' (Read-JsonDocument $ledger).Status 'valid'
# 合法 JSON 但结构不合法（缺 replied）=> 由消费方按结构判定，Read 本身是 valid。
[System.IO.File]::WriteAllText($ledger, '{"other":1}', $enc)
Eq 'L-valid-but-wrong-shape' (Read-JsonDocumentField -Path $ledger -Field 'replied').Status 'corrupt'
# 原子写入失败时旧文件保持可读。
[System.IO.File]::WriteAllText($ledger, '{"replied":{"a":"h|1"}}', $enc)
$beforeText = [System.IO.File]::ReadAllText($ledger)
$lockStream = [System.IO.File]::Open($ledger, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
try { $w = Write-JsonDocumentAtomic -Path $ledger -Data ([pscustomobject]@{ replied = [pscustomobject]@{ a = 'h|9' } }) } finally { $lockStream.Close(); $lockStream.Dispose() }
Check 'L-atomic-failure-reported' (-not $w.Ok) ('err=' + $w.Error)
Eq 'L-atomic-failure-keeps-old-file' ([System.IO.File]::ReadAllText($ledger)) $beforeText
Eq 'L-atomic-failure-still-valid' (Read-JsonDocument $ledger).Status 'valid'
Remove-Item -LiteralPath $ledgerDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output '  ledger states done'

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
