# tests\third_fix_contact_fields.tests.ps1 - R1/R4：统一请求项解析 + 逐项角色/字段核对
#
# 依据：docs\specs\独立复核七项与验收守卫修复_spec_20261005.md §2 / §3 / §10.1。
# 失败基线：docs\verification\architecture_opt_20261005\review_fixes\second_independent_review_20261005\edge_probes.txt
#   （R1 并列句省略请求动词绕过红线、R4 收货姓名被当成联系方式已提供）。
#
# 分层：pure。只加载纯库，不联网、不开页、不发送、不读生产存储。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }
function Dec([string[]]$Ask, $Facts) { return [pscustomobject]@{ AskFields = @($Ask); Facts = $Facts; RequestedFacts = @(); ActionEvidence = $null } }
function FactsByKey($Map, [bool]$HasSupplierContact = $false) {
    return [pscustomobject]@{ HasSupplierContact = $HasSupplierContact; CargoFacts = [pscustomobject]@{ ByKey = $Map }; Destination = $null }
}
function Field([string]$Status, [string]$Value = '') { return [pscustomobject]@{ Status = $Status; Value = $Value } }

Write-Output '== third_fix contact/field tests (R1 / R4) =='

$decSupplier = Dec @('supplier') $null
$realNameFacts = FactsByKey @{ recipient_name = (Field 'provided' 'Alex'); recipient_contact = (Field 'missing' '') }
$decContactOnly = Dec @('recipient_contact') $realNameFacts

# ---- C01 原复核样例：并列句后半段省略请求动词，仍必须在完整检查里被阻断 ----
$c01 = 'Please share the supplier''s contact details for packing and contact details so we can reach you.'
$r = Test-ReplyCompliance -Text $c01 -Rules $null -Decision $decSupplier
Check 'C01-conjoined-generic-ask-blocked' (-not $r.Ok) (Codes $r)
Check 'C01-code-is-no-role' ([bool]((Codes $r) -match 'CONTACT_ASK_NO_ROLE')) (Codes $r)
$fb = $null
$convC01 = ConvertTo-MessageList (('[BUYER] I don''t know the packed dimensions. @@TS:1791172800000 @@MT:1791172800000')) 'Buyer X'
$decC01 = Get-ReplyDecision -Conversation $convC01 -Facts (Get-ConversationFacts $convC01) -Rules $null
$genC01 = Invoke-ReplyGeneration -Conversation $convC01 -Decision $decC01 -Rules $null -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -MaxRewrites 1
Check 'C01-generation-never-returns-the-blocked-text' (-not ([string]$genC01.Text -match "(?i)contact details so we can reach you")) ([string]$genC01.Text)

# ---- C02 同义逗号 / plus / also / 显式第二请求动词：同一红线成立 ----
foreach ($t in @(
    'Please share the supplier''s contact details for packing, contact details so we can reach you.',
    'Please share the supplier''s contact details for packing plus contact details so we can reach you.',
    'Please share the supplier''s contact details for packing and also contact details so we can reach you.',
    'Please share the supplier''s contact details for packing and please share contact details so we can reach you.'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision $decSupplier
    Check ('C02-synonym-conjunction-blocked [' + $t + ']') (-not $rr.Ok) (Codes $rr)
}

# ---- C03 supplier 合法请求 + your phone/email/我方邀约：非法项逐一阻断 ----
foreach ($t in @(
    'Please share the supplier''s contact details for packing and your phone number.',
    'Please share the supplier''s contact details for packing plus your email address.',
    'Please share the supplier''s contact details for packing and you can reach me on WhatsApp.'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision $decSupplier
    Check ('C03-mixed-illegal-item-blocked [' + $t + ']') (-not $rr.Ok) (Codes $rr)
}
$okSupplier = Test-ReplyCompliance -Text 'Please share the supplier''s contact details for packing.' -Rules $null -Decision $decSupplier
Check 'C03-legal-supplier-ask-still-passes' ([bool]$okSupplier.Ok) (Codes $okSupplier)

# ---- C04 授权且均缺的 recipient name/phone/address：三项正确绑定并合法 ----
$decRecFull = Dec @('recipient_contact', 'recipient_name', 'delivery_address') $null
$c04 = 'Could you share the recipient''s name, phone number and delivery address for delivery?'
$items = @(Get-ReplyRequestItems -Text $c04 -Decision $decRecFull)
$keys = @($items | ForEach-Object { [string]$_.FieldKey } | Where-Object { $_ } | Select-Object -Unique)
Check 'C04-name-bound' ($keys -contains 'recipient_name') ($keys -join ',')
Check 'C04-phone-bound' ($keys -contains 'recipient_contact') ($keys -join ',')
Check 'C04-address-bound' ($keys -contains 'delivery_address') ($keys -join ',')
Check 'C04-action-inherited-not-explicit' ([bool](@($items | Where-Object { $_.Inherited }).Count -gt 0)) ''
$r04 = Test-ReplyCompliance -Text $c04 -Rules $null -Decision $decRecFull
Check 'C04-full-authorization-passes' ([bool]$r04.Ok) (Codes $r04)

# ---- C05 [独立复核 R09] 供应商联系叙述（无索取动作）不得误拦；但"已有/已给"是事实声明，需要来源 ----
foreach ($t in @(
    'Thanks, I have your supplier''s contact on file.',
    'The supplier already gave us their contact person.'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision $decSupplier
    Check ('C05-no-evidence-claim-blocked [' + $t + ']') (-not [bool]$rr.Ok) (Codes $rr)
    Check ('C05-no-evidence-claim-code [' + $t + ']') ((Codes $rr) -match 'UNSUPPORTED_RECEIVED_FACT') (Codes $rr)
}
# 有真实来源时可陈述；普通联系说明始终合法。
$factsSupplierProvided = [pscustomobject]@{ HasSupplierContact = $true; CargoFacts = [pscustomobject]@{ ByKey = @{ supplier_contact = (Field 'provided' 'supplier@example.invalid') }; Fields = @([pscustomobject]@{ Key = 'supplier_contact'; Status = 'provided'; Value = 'supplier@example.invalid'; Unit = ''; Scope = 'contact'; Evidence = @('operator-record') }) }; Destination = $null }
foreach ($t in @(
    'Thanks, I have your supplier''s contact on file.',
    'The supplier already gave us their contact person.',
    'Supplier contact details help us verify packing.',
    'Thanks for the contact list.'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision (Dec @('supplier') $factsSupplierProvided)
    Check ('C05-sourced-or-ordinary-allowed [' + $t + ']') ([bool]$rr.Ok) (Codes $rr)
}

# ---- C06/C07/C08 实际事实模型：姓名已有 ≠ 联系方式已提供 ----
Check 'C06-contact-status-is-not-provided' (-not [bool](Test-ContactItemProvided $realNameFacts 'recipient_contact')) ''
$r06 = Test-ReplyCompliance -Text 'Please share the recipient''s phone number for delivery.' -Rules $null -Decision $decContactOnly
Check 'C06-missing-phone-ask-allowed' ([bool]$r06.Ok) (Codes $r06)
# C07：contact 已有、name 缺失且仅姓名授权 ⇒ 姓名询问通过；不重复问联系渠道。
$contactOnlyProvided = FactsByKey @{ recipient_contact = (Field 'provided' '+1 555 0100'); recipient_name = (Field 'missing' '') }
$r07 = Test-ReplyCompliance -Text 'Could you share the recipient''s name for delivery?' -Rules $null -Decision (Dec @('recipient_name') $contactOnlyProvided)
Check 'C07-name-ask-allowed-when-contact-provided' ([bool]$r07.Ok) (Codes $r07)
$r07b = Test-ReplyCompliance -Text 'Could you share the recipient''s contact number for delivery?' -Rules $null -Decision (Dec @('recipient_name', 'recipient_contact') $contactOnlyProvided)
Check 'C07-contact-reask-blocked' (-not $r07b.Ok) (Codes $r07b)
# 姓名已提供时的重复索要同样阻断（同一个具体字段的 provided 语义）。
$r07c = Test-ReplyCompliance -Text 'Can you confirm the recipient''s name?' -Rules $null -Decision (Dec @('recipient_name') $realNameFacts)
Check 'C07-name-reask-blocked-through-compliance' (-not $r07c.Ok) (Codes $r07c)
$contactProvided = $contactOnlyProvided
$r08 = Test-ReplyCompliance -Text 'Please share the recipient''s phone number for delivery.' -Rules $null -Decision (Dec @('recipient_contact') $contactProvided)
Check 'C08-authorization-cannot-override-provided' (-not $r08.Ok) (Codes $r08)
Check 'C08-code-already-provided' ([bool]((Codes $r08) -match 'CONTACT_ASK_ALREADY_PROVIDED')) (Codes $r08)

# ---- C09 只授权具体字段：未授权的具体字段被阻断 ----
$decNameAddr = Dec @('recipient_name', 'delivery_address') $null
$r09a = Test-ReplyCompliance -Text 'Please share the recipient''s phone number for delivery.' -Rules $null -Decision $decNameAddr
Check 'C09-name-address-do-not-authorize-phone' (-not $r09a.Ok) (Codes $r09a)
$decSupAddr = Dec @('supplier_address') $null
$r09b = Test-ReplyCompliance -Text 'Could you share your supplier''s contact details for packing?' -Rules $null -Decision $decSupAddr
Check 'C09-supplier-address-does-not-authorize-contact' (-not $r09b.Ok) (Codes $r09b)
Check 'C09-code-is-unauthorized-field' ([bool]((Codes $r09b) -match 'CONTACT_ASK_UNAUTHORIZED_FIELD')) (Codes $r09b)

# ---- C10 姓名已有、仅 contact 授权，却混问姓名和电话：整句被拦，正确替代可发 ----
$r10 = Test-ReplyCompliance -Text 'Could you share the recipient''s name and phone number for delivery?' -Rules $null -Decision $decContactOnly
Check 'C10-mixed-with-provided-name-blocked' (-not $r10.Ok) (Codes $r10)
$r10b = Test-ReplyCompliance -Text 'Please share the recipient''s phone number for delivery.' -Rules $null -Decision $decContactOnly
Check 'C10-correct-replacement-can-send' ([bool]$r10b.Ok) (Codes $r10b)

# ---- C11 买家即收货人：受控交付角色表达可发；私人联系方式仍阻断 ----
$r11a = Test-ReplyCompliance -Text 'As the consignee, could you share the delivery phone number?' -Rules $null -Decision $decContactOnly
Check 'C11-controlled-consignee-expression-passes' ([bool]$r11a.Ok) (Codes $r11a)
$r11b = Test-ReplyCompliance -Text 'As the consignee, could you share your personal contact?' -Rules $null -Decision $decContactOnly
Check 'C11-personal-contact-still-blocked' (-not $r11b.Ok) (Codes $r11b)

# ---- C12 已有有效派送邮箱：再要派送电话按同项重复索取阻断 ----
$emailProvided = FactsByKey @{ recipient_contact = (Field 'provided' 'alex@example.invalid') }
$r12 = Test-ReplyCompliance -Text 'Please share the delivery phone number.' -Rules $null -Decision (Dec @('recipient_contact') $emailProvided)
Check 'C12-email-satisfies-recipient-contact' (-not $r12.Ok) (Codes $r12)
Check 'C12-code-already-provided' ([bool]((Codes $r12) -match 'CONTACT_ASK_ALREADY_PROVIDED')) (Codes $r12)

# ---- 交叉：姓名已有、电话缺失，合法电话请求 + 并列未指名 contact 请求 => 后项阻断 ----
foreach ($t in @(
    'Please share the recipient''s phone number for delivery and contact details so we can reach you.',
    'Please share the recipient''s phone number for delivery, plus your email address.'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision $decContactOnly
    Check ('X-contact-cross-blocked [' + $t + ']') (-not $rr.Ok) (Codes $rr)
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
