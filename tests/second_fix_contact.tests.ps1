# tests\second_fix_contact.tests.ps1 - F1：联系方式识别不再依赖冠词，角色必须属于联系请求（spec §2.1）
#
# 基线缺陷（docs\verification\architecture_opt_20261005\review_fixes\second_fix\independent_probes_before.txt）：
#   scripts\lib\contact_rules.ps1 的 $script:ContactGenericAskPatterns 把 a|an|the|your|any 写成**必需**
#   限定词，于是
#     'Please share contact details for delivery updates.'       -> Ok=true, Codes=[]
#     'Please provide contact information so we can reach you.'  -> Ok=true, Codes=[]
#   完全跳过联系方式红线；同类问题还有"角色只看同句是否出现 supplier/consignee"，导致
#     'Could you share your phone number so we can confirm the packing with your supplier?'
#   这种索取**买家本人**电话的句子被红线放行（只靠旧的第 4 项 BUYER_CONTACT_REQUEST 才拦住）。
#
# 本文件的断言全部落在 Test-ReplyCompliance 的**第 0 项**（联系方式红线）上：既断言 Ok，也断言
#   具体 Code（不断言"不含某短语"）。分层：纯逻辑 + 隔离运行根；不联网、不开页、不发送、
#   不读生产配置、不使用真实身份（.invalid 地址 / 虚构买家）。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }
function HasCode($r, [string]$code) { return (@($r.Violations | Where-Object { $_.Code -eq $code }).Count -gt 0) }

Write-Output '== second_fix contact tests (F1) =='

$isoRoot = Join-Path $env:TEMP ('aar-secondfix-contact-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
Check 'F1-isolated-runtime' (Test-AarIsolatedRuntime) 'isolation marker missing'

. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
# 最小决策桩（与 spec §2.1 / review_fixes.tests.ps1 的 AskDec 同形）
function Dec([string[]]$Ask, $Facts) { return [pscustomobject]@{ AskFields = @($Ask); Facts = $Facts; RequestedFacts = @(); ActionEvidence = $null } }
# 事实桩：只带本项关心的字段；CargoFacts.ByKey 支持 hashtable 与 PSCustomObject 两种形态。
function FactsHasSupplierContact { return [pscustomobject]@{ HasSupplierContact = $true; CargoFacts = $null; Destination = $null } }
function FactsByKey($Map, [bool]$HasSupplierContact = $false) {
    return [pscustomobject]@{ HasSupplierContact = $HasSupplierContact; CargoFacts = [pscustomobject]@{ ByKey = $Map }; Destination = $null }
}
$decNone = Dec @() $null

# ============================================================================================
# 1) 冠词是可选的：无冠词的 "contact details / contact information / phone numbers" 必须进入检查
# ============================================================================================
foreach ($t in @(
    'Please share contact details for delivery updates.',
    'Please provide contact information so we can reach you.',
    'Please share contact details for the shipment.',
    'Please send us contact information for the delivery.',
    'Please share phone numbers for the delivery updates.'
)) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $decNone
    Check ('F1-generic-no-article-blocked [' + $t + ']') (-not $r.Ok) (Codes $r)
    Check ('F1-generic-no-article-code [' + $t + ']') (HasCode $r 'CONTACT_ASK_NO_ROLE') (Codes $r)
}

# ============================================================================================
# 2) 基线里已经阻断的两个样例必须继续阻断（不能为了修 A 而放过 B）
# ============================================================================================
$r = Test-ReplyCompliance -Text 'Please leave a phone number for delivery updates.' -Rules $null -Decision $decNone
Check 'F1-keep-blocked-article-generic' (-not $r.Ok) (Codes $r)
Check 'F1-keep-blocked-article-generic-code' (HasCode $r 'CONTACT_ASK_NO_ROLE') (Codes $r)
$r = Test-ReplyCompliance -Text 'You can email me if that is easier.' -Rules $null -Decision $decNone
Check 'F1-keep-blocked-our-invitation' (-not $r.Ok) (Codes $r)
Check 'F1-keep-blocked-our-invitation-code' (HasCode $r 'OUR_CONTACT_OFFER') (Codes $r)

# ============================================================================================
# 3) 未提供 + 本轮 AskFields 授权（或用途明确）的角色联系请求 => 通过
# ============================================================================================
$dSup = Dec @('supplier') $null
$r = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision $dSup
Check 'F1-authorized-supplier-ask-passes' ([bool]$r.Ok) (Codes $r)
$dRec = Dec @('recipient_contact') $null
# 这句话同时索取"收货人姓名 + 联系方式 + 收货地址"：地址部分属于 spec §6.2 的 AskFields 范围检查
#   （另一个独立判据，本项不得放宽），所以整句过 Test-ReplyCompliance 时决策桩必须把这三项都授权。
$dRecFull = Dec @('recipient_contact', 'recipient_name', 'delivery_address') $null
$r = Test-ReplyCompliance -Text "Could you share the consignee's name, contact number and delivery address?" -Rules $null -Decision $dRecFull
Check 'F1-authorized-recipient-ask-passes' ([bool]$r.Ok) (Codes $r)
# 只授权 recipient_contact 时，联系方式红线本身也必须放行（ASK_OUT_OF_SCOPE 来自地址部分，不是联系人判据）
$r = Test-ContactRedline -Text "Could you share the consignee's name, contact number and delivery address?" -Decision $dRec -Facts $null
Check 'F1-contact-only-cannot-authorize-name' (-not [bool]$r.Ok) (Codes $r)
$r = Test-ReplyCompliance -Text "Could you provide the consignee's contact?" -Rules $null -Decision $dRec
Check 'F1-authorized-recipient-contact-only-passes' ([bool]$r.Ok) (Codes $r)
# 事实为 unknown（还没提供）时，同样的授权请求仍然通过：阻断必须由"已提供"驱动，而不是一刀切
$factsUnknown = FactsByKey @{ 'supplier_contact' = [pscustomobject]@{ Status = 'unknown'; Value = '' } }
$r = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision (Dec @('supplier') $factsUnknown)
Check 'F1-unknown-facts-still-allowed' ([bool]$r.Ok) (Codes $r)

# ============================================================================================
# 4) 索取对象是买家本人 => 阻断；同句提到 supplier/consignee 不构成豁免（即便已授权 supplier）
# ============================================================================================
$r = Test-ReplyCompliance -Text 'Could you share your phone number so we can confirm the packing with your supplier?' -Rules $null -Decision $dSup
Check 'F1-personal-phone-with-supplier-mention-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-personal-phone-with-supplier-mention-code' (HasCode $r 'BUYER_PERSONAL_CONTACT_ASK') (Codes $r)
$r = Test-ReplyCompliance -Text 'Please send me your contact details so we can confirm the packing with your supplier.' -Rules $null -Decision $dSup
Check 'F1-personal-details-with-supplier-mention-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-personal-details-with-supplier-mention-code' (HasCode $r 'BUYER_PERSONAL_CONTACT_ASK') (Codes $r)
# 授权的是 supplier 不等于授权 consignee（角色必须与索取对象一致）
$r = Test-ReplyCompliance -Text "Could you provide the consignee's contact?" -Rules $null -Decision $dSup
Check 'F1-supplier-authorization-does-not-cover-recipient' (-not $r.Ok) (Codes $r)
Check 'F1-supplier-authorization-recipient-code' (HasCode $r 'CONTACT_ROLE_UNCLEAR') (Codes $r)

# ============================================================================================
# 5) 已提供的角色联系人再次索取 => CONTACT_ASK_ALREADY_PROVIDED（两种 Facts 形态都要能读）
# ============================================================================================
$r = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision (Dec @('supplier') (FactsHasSupplierContact))
Check 'F1-supplier-already-provided-flag-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-supplier-already-provided-flag-code' (HasCode $r 'CONTACT_ASK_ALREADY_PROVIDED') (Codes $r)

$factsSupKey = FactsByKey @{ 'supplier_contact' = [pscustomobject]@{ Status = 'provided'; Value = 'factory@example.invalid' } }
$r = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision (Dec @('supplier') $factsSupKey)
Check 'F1-supplier-already-provided-bykey-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-supplier-already-provided-bykey-code' (HasCode $r 'CONTACT_ASK_ALREADY_PROVIDED') (Codes $r)

$factsRecKey = FactsByKey @{ 'recipient_contact' = [pscustomobject]@{ Status = 'provided'; Value = '+1 555 0100' } }
$r = Test-ReplyCompliance -Text "Could you share the consignee's contact number for delivery?" -Rules $null -Decision (Dec @('recipient_contact') $factsRecKey)
Check 'F1-recipient-already-provided-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-recipient-already-provided-code' (HasCode $r 'CONTACT_ASK_ALREADY_PROVIDED') (Codes $r)

# ByKey 是 PSCustomObject（不是 hashtable）时也要能读到 —— 兼容取值函数不能只认一种形态。
#   这里直接走 Test-ContactRedline -Facts：reply_policy 的字段范围检查（另一个判据）假定 ByKey 是
#   hashtable（$bk.ContainsKey），生产事实模型也确实给 hashtable，因此该形态只在红线层验证。
$factsRecName = FactsByKey ([pscustomobject]@{ 'recipient_name' = [pscustomobject]@{ Status = 'provided'; Value = 'Jane Doe' } })
$r = Test-ContactRedline -Text "Could you share the consignee's name for delivery?" -Facts $factsRecName
Check 'F1-recipient-name-provided-object-shape-blocked' (-not $r.Ok) (Codes $r)
Check 'F1-recipient-name-provided-object-shape-code' (HasCode $r 'CONTACT_ASK_ALREADY_PROVIDED') (Codes $r)

# 'unknown'（未提供）不得被当成 provided
$factsRecUnknown = FactsByKey @{ 'recipient_contact' = [pscustomobject]@{ Status = 'unknown'; Value = '' } }
$r = Test-ReplyCompliance -Text "Could you share the consignee's contact number for delivery?" -Rules $null -Decision (Dec @('recipient_contact') $factsRecUnknown)
Check 'F1-recipient-unknown-not-blocked' ([bool]$r.Ok) (Codes $r)

# ============================================================================================
# 6) 非索取叙述 / 平台内正常沟通不得因为含 contact|details 被误拦
# ============================================================================================
foreach ($t in @(
    'We can keep everything here on the platform.',
    'Thanks for the contact list.',
    'The contact person at the warehouse will call you.'
)) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $decNone
    Check ('F1-narration-not-blocked [' + $t + ']') ([bool]$r.Ok) (Codes $r)
}
# [独立复核 R09] "已有/已给"是事实声明：没有对应来源时完整校验不得放行。
foreach ($t in @(
    "Thanks, I have your supplier's contact on file.",
    'The supplier already gave us their contact person.'
)) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $decNone
    Check ('F1-unsourced-claim-blocked [' + $t + ']') (-not [bool]$r.Ok) (Codes $r)
    Check ('F1-unsourced-claim-code [' + $t + ']') ((Codes $r) -match 'UNSUPPORTED_RECEIVED_FACT') (Codes $r)
}
$factsSupplierSourced = [pscustomobject]@{ HasSupplierContact = $true; CargoFacts = [pscustomobject]@{ ByKey = @{ supplier_contact = [pscustomobject]@{ Status = 'provided'; Value = 'supplier@example.invalid' } }; Fields = @([pscustomobject]@{ Key = 'supplier_contact'; Status = 'provided'; Value = 'supplier@example.invalid'; Unit = ''; Scope = 'contact'; Evidence = @('operator-record') }) }; Destination = $null }
foreach ($t in @(
    "Thanks, I have your supplier's contact on file.",
    'The supplier already gave us their contact person.'
)) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision (Dec @() $factsSupplierSourced)
    Check ('F1-sourced-claim-allowed [' + $t + ']') ([bool]$r.Ok) (Codes $r)
}
# 角色 + 用途明确的既有允许措辞同样继续通过（对象绑定不能过度收紧）
foreach ($t in @(
    "Could you share the consignee's name, contact number and delivery address?",
    "Could you share your supplier's contact details so we can confirm the packing information?",
    "Please share the recipient's phone number for delivery.",
    "Could you send the consignee's contact so the carrier can reach them?",
    "Could you share your supplier's contact so we can check the carton count and packed weight with them?"
)) {
    $r = Test-ContactRedline -Text $t -Decision ([pscustomobject]@{AskFields=@('recipient_name','recipient_contact','delivery_address','supplier_contact')})
    Check ('F1-role-purpose-still-allowed [' + $t + ']') ([bool]$r.Ok) (Codes $r)
}

# ============================================================================================
# 7) 联系方式检查仍是 Test-ReplyCompliance 的第一项（同一句里红线先报，其它检查在其后）
# ============================================================================================
$both = Test-ReplyCompliance -Text 'Please share contact details for delivery updates. The rate is $1,200 all in.' -Rules $null -Decision $decNone
Check 'F1-contact-check-reports-first' ((-not $both.Ok) -and (@($both.Violations)[0].Code -eq 'CONTACT_ASK_NO_ROLE')) (Codes $both)
Check 'F1-other-checks-still-run-after' (HasCode $both 'PRICE_DISCLOSURE') (Codes $both)

# ============================================================================================
# 8) 完整生成链：违规初稿 -> 一次合规重写 => 发重写；初稿与重写都违规 => 只发经同一检查的回退
# ============================================================================================
$script:modelCalls = 0
$script:modelQueue = New-Object System.Collections.ArrayList
function Invoke-LLM {
    param($Messages, $Temperature, $MaxTokens, $LogFile)
    $script:modelCalls++
    if ($script:modelQueue.Count -gt 0) { $r = [string]$script:modelQueue[0]; $script:modelQueue.RemoveAt(0); return $r }
    return ''
}
function GenCase([string[]]$Drafts) {
    $script:modelCalls = 0
    $script:modelQueue.Clear()
    foreach ($d in $Drafts) { [void]$script:modelQueue.Add($d) }
    $conv = ConvertTo-MessageList (BuyerLine 'Can you quote 10 cartons to Hamburg?' 1791170000000) 'Buyer R'
    $facts = Get-ConversationFacts $conv
    $dec = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $null
    $gen = Invoke-ReplyGeneration -Conversation $conv -Decision $dec -Rules $null `
        -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') `
        -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -MaxRewrites 1
    return [pscustomobject]@{ Gen = $gen; Decision = $dec; ModelCalls = $script:modelCalls }
}
$compliantRewrite = 'Thanks for your message - I have everything noted here on the platform.'
$sanity = Test-ReplyCompliance -Text $compliantRewrite -Rules $null -Decision $decNone
Check 'F1-rewrite-stub-is-compliant' ([bool]$sanity.Ok) (Codes $sanity)

$g1 = GenCase @('Please share contact details for delivery updates.', $compliantRewrite)
Eq 'F1-gen-rewrite-source' $g1.Gen.Source 'FALLBACK'
Eq 'F1-gen-rewrite-model-calls' $g1.ModelCalls 2
Eq 'F1-gen-rewrite-count' $g1.Gen.Rewrites 1
$c1 = Test-ReplyCompliance -Text $g1.Gen.Text -Rules $null -Decision $g1.Decision
Check 'F1-gen-rewrite-is-compliant' ([bool]$c1.Ok) (Codes $c1)
Check 'F1-gen-rewrite-has-no-contact-ask' ([bool](Test-ContactRedline -Text $g1.Gen.Text -Decision $g1.Decision -Facts $g1.Decision.Facts).Ok) $g1.Gen.Text

$g2 = GenCase @('Please share contact details for delivery updates.', 'Please provide contact information so we can reach you.')
Check 'F1-gen-double-violation-no-dirty-text' ([bool]($g2.Gen.Source -eq 'BLOCKED' -or -not [string]::IsNullOrWhiteSpace($g2.Gen.Text))) $g2.Gen.Source
if ([string]::IsNullOrWhiteSpace($g2.Gen.Text)) {
    Eq 'F1-gen-double-violation-blocked' $g2.Gen.Source 'BLOCKED'
} else {
    Eq 'F1-gen-double-violation-falls-back' $g2.Gen.Source 'FALLBACK'
    $c2 = Test-ReplyCompliance -Text $g2.Gen.Text -Rules $null -Decision $g2.Decision
    Check 'F1-gen-double-violation-final-compliant' ([bool]$c2.Ok) ((Codes $c2) + ' :: ' + $g2.Gen.Text)
    Check 'F1-gen-double-violation-final-no-contact-ask' ([bool](Test-ContactRedline -Text $g2.Gen.Text -Decision $g2.Decision -Facts $g2.Decision.Facts).Ok) $g2.Gen.Text
}
Check 'F1-gen-double-violation-reason' ([bool]($g2.Gen.FallbackReason -match '^business-body-sensitive')) $g2.Gen.FallbackReason

# ============================================================================================
# 9) -Facts 确实由 reply_policy 接进红线：真实决策对象（买家已给供应商联系人）也要阻断重复询问
# ============================================================================================
$convSup = ConvertTo-MessageList (BuyerLine "My supplier's contact is factory@example.invalid, but I don't know the dimensions." 1791170000000) 'Buyer R'
$decSup = Get-ReplyDecision -Conversation $convSup -Facts (Get-ConversationFacts $convSup) -Rules $null
Check 'F1-real-decision-knows-supplier-contact' ([bool]$decSup.Facts.HasSupplierContact) ''
$rWired = Test-ReplyCompliance -Text "Could you share your supplier's contact details so we can confirm the packing information?" -Rules $null -Decision $decSup
Check 'F1-real-decision-repeat-ask-blocked' ((-not $rWired.Ok) -and (HasCode $rWired 'CONTACT_ASK_ALREADY_PROVIDED')) (Codes $rWired)

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
