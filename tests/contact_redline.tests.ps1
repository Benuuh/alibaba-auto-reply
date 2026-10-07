# tests\contact_redline.tests.ps1 - 联系方式最高优先级红线（2026-10-05 spec §1.1 / §6.1 第 0 条 / §7）
#
# 纯逻辑：不联网、不开页、不发送。加载 reply_policy（内部会加载 contact_rules）+ reply_gen。
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
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== contact_redline tests =='

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function Decide([string[]]$lines, [string[]]$askOverride = $null) {
    $conv = ConvertTo-MessageList (($lines -join $LF)) 'Buyer R'
    $facts = Get-ConversationFacts $conv
    $d = Get-ReplyDecision -Conversation $conv -Facts $facts
    if ($askOverride) { $d.AskFields = @($askOverride) }
    return $d
}
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }

# ---------------------------------------------------------------------------------------------
# 1) 允许：角色 + 用途明确的收货人 / 供应商询问
# ---------------------------------------------------------------------------------------------
$allowed = @(
    "Could you share the consignee's name, contact number and delivery address?",
    "Could you share your supplier's contact details so we can confirm the packing information?",
    "Please share the recipient's phone number for delivery.",
    "Could you send the consignee's contact so the carrier can reach them?",
    "Could you share your supplier's contact so we can check the carton count and packed weight with them?",
    "We can keep everything here on the platform."
)
foreach ($t in $allowed) {
    $r = Test-ContactRedline -Text $t -Decision ([pscustomobject]@{AskFields=@('recipient_name','recipient_contact','delivery_address','supplier_contact')})
    Check ('allow: ' + $t) $r.Ok (Codes $r)
}

# 本轮 AskFields 授权角色时，"角色指名索取"即使没有用途词也放行（spec §6.1 第 0 条的范围条件）
$dRecipient = [pscustomobject]@{ AskFields = @('recipient_contact') }
$dSupplier = [pscustomobject]@{ AskFields = @('supplier') }
Check 'allow-by-askfields-recipient' (Test-ContactRedline -Text "Could you provide the consignee's contact?" -Decision $dRecipient).Ok
Check 'allow-by-askfields-supplier' (Test-ContactRedline -Text "Could you share your supplier's contact?" -Decision $dSupplier).Ok

# ---------------------------------------------------------------------------------------------
# 2) 阻断：主动提供/邀请我方联系方式（即使来自固定回退也不豁免）
# ---------------------------------------------------------------------------------------------
$ourContact = @(
    "Here's my WhatsApp number. You can contact me there.",
    "My email is ops@example.com - feel free to write me.",
    "Add me on WeChat and we can discuss the shipment.",
    "You can reach us at +86 138 0000 0000.",
    "Let's continue on WhatsApp.",
    "Please contact me on Telegram.",
    "We can move this conversation off-platform.",
    "Here is our phone number: +1 555 0100."
)
foreach ($t in $ourContact) {
    $r = Test-ContactRedline -Text $t
    Check ('block-our-contact: ' + $t) (-not $r.Ok) 'expected a violation'
    $c = Test-ReplyCompliance -Text $t
    Check ('compliance-block-our-contact: ' + $t) (-not $c.Ok) (Codes $c)
}

# ---------------------------------------------------------------------------------------------
# 3) 阻断：索取买家本人联系方式（没有明确收货角色）
# ---------------------------------------------------------------------------------------------
$buyerPersonal = @(
    "What's your WhatsApp number?",
    "Send me your phone number or email.",
    "Can I have your email address?",
    "Please share your contact details.",
    "What is your phone number?",
    "Your email please."
)
foreach ($t in $buyerPersonal) {
    $r = Test-ContactRedline -Text $t
    Check ('block-buyer-contact: ' + $t) (-not $r.Ok) 'expected a violation'
    $c = Test-ReplyCompliance -Text $t
    Check ('compliance-block-buyer-contact: ' + $t) (-not $c.Ok) (Codes $c)
}

# ---------------------------------------------------------------------------------------------
# 4) 混合句：提到供应商/收货人**不豁免**同一句里的其他联系请求（spec §1.1 第 6 条）
# ---------------------------------------------------------------------------------------------
$mixed = @(
    "Could you share your supplier's contact details and your WhatsApp number?",
    "Thanks for the consignee's number. You can also email me at ops@example.com.",
    "Please send the consignee name and your personal phone number.",
    "Could you share the recipient's phone for delivery and add me on WeChat?"
)
foreach ($t in $mixed) {
    $r = Test-ContactRedline -Text $t
    Check ('block-mixed: ' + $t) (-not $r.Ok) 'expected a violation'
}

# 只索取供应商联系方式 => 允许；同一句里既索取供应商又索取买家本人 => 阻断
Check 'supplier-only-allowed' (Test-ContactRedline -Text "Could you share your supplier's contact?" -Decision $dSupplier).Ok
Check 'supplier-plus-buyer-blocked' (-not (Test-ContactRedline -Text "Could you share your supplier's contact and your WhatsApp?" -Decision $dSupplier).Ok)

# 收货人即买家本人：明确按收货用途询问 => 允许（spec §7 该行要求不被旧禁令误拦）
$buyerIsConsignee = "Are you also the consignee? If so, could you share the recipient's contact number and delivery address?"
Check 'buyer-is-consignee-allowed' (Test-ContactRedline -Text $buyerIsConsignee -Decision ([pscustomobject]@{AskFields=@('recipient_name','recipient_contact','delivery_address','supplier_contact')})).Ok

# ---------------------------------------------------------------------------------------------
# 5) 与其余检查的关系：红线先于其它检查生效；固定回退本身也必须合规
# ---------------------------------------------------------------------------------------------
$priceAndContact = "The rate is 1200 USD. You can reach me on WhatsApp."
$r = Test-ReplyCompliance -Text $priceAndContact
Check 'redline-runs-alongside-other-checks' (-not $r.Ok)
Check 'redline-code-present' ((Codes $r) -match 'OUR_CONTACT_OFFER') (Codes $r)

$conv = ConvertTo-MessageList (BuyerLine 'Can you quote 10 cartons to Hamburg?' 1791170000000) 'Buyer R'
$facts = Get-ConversationFacts $conv
$dec = Get-ReplyDecision -Conversation $conv -Facts $facts
foreach ($scenario in @('new_inquiry', 'details_given', 'dimension_missing', 'human_requested', 'complaint', 'delivery_status', 'supplier_unreachable', 'short_ack', 'material_promised', 'address_clarify', 'refusal')) {
    $fd = Get-ReplyDecision -Conversation $conv -Facts $facts -ForceScenario $scenario
    $fb = Get-ScenarioFallback -Decision $fd
    if (-not $fb) { continue }
    $chk = Test-ReplyCompliance -Text $fb -Rules $null -Decision $fd
    Check ('fallback-compliant[' + $scenario + ']') $chk.Ok ((Codes $chk) + ' :: ' + $fb)
}

# 决策层的 AskFields 若只授权供应商，则收货人联系方式询问需要自己的授权（不借供应商授权放行）
Check 'askfields-are-role-specific' (-not (Test-ContactRedline -Text "Could you provide the consignee's contact?" -Decision $dSupplier).Ok)

# A request verb ends at a sentence boundary; ordinary explanations are not requests.
$dNatural=[pscustomobject]@{AskFields=@('weight');Facts=$null}
$natural='Could you share the total weight? Package measurements help estimate shipment volume.'
Check 'sentence-boundary-does-not-inherit-request-verb' (@(Get-ReplyRequestItems -Text $natural -Decision $dNatural | Where-Object {$_.FieldKey -eq 'dimension'}).Count -eq 0)
Check 'ordinary-dimensions-explanation-is-allowed' ((Test-ReplyCompliance -Text $natural -Decision $dNatural).Ok)
Check 'new-sentence-explicit-request-still-blocked' (-not (Test-ReplyCompliance -Text 'Could you share the total weight? Please provide the dimensions.' -Decision $dNatural).Ok)

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
