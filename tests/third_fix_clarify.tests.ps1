# tests\third_fix_clarify.tests.ps1 - R7：澄清绑定具体歧义与来源（spec §7 / §10.5）
#
# 失败基线（edge_probes.txt）：真实冲突 20/24 时，'Which carton count is correct - 999 or 1000?' 被放行，
#   而合法的 'Could you confirm whether the carton count is 20 or 24?' 反而被判 ASK_OUT_OF_SCOPE。
# 本文件用**实际事实模型**从 '20 cartons.' / '24 cartons.' 得到冲突与来源，不再只手工设置一个 conflict 布尔。
#
# 分层：pure。
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
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
$LF = [string][char]10
$ts = [long]1791172800000

Write-Output '== third_fix clarification tests (R7) =='

# 真实事实模型：两条互相冲突的箱数消息 => conflict + 结构化候选（值/单位/范围/来源）。
$convConflict = ConvertTo-MessageList ((BLine '20 cartons.' $ts) + $LF + (BLine '24 cartons.' ($ts + 1000))) 'Virtual Buyer'
$cf = Get-ConversationFacts $convConflict
Check 'Q00-real-conflict-status' ([string]$cf.CargoFacts.ByKey['carton_count'].Status -eq 'conflict') ([string]$cf.CargoFacts.ByKey['carton_count'].Status)
$reqs = @(Get-ReplyClarificationRequests -Facts $cf -Decision ([pscustomobject]@{ Scenario = 'new_inquiry'; ClarifyFields = @('carton_count') }))
Check 'Q00-has-structured-clarification-request' ($reqs.Count -ge 1) ([string]$reqs.Count)
$req = @($reqs | Where-Object { $_.FieldKey -eq 'carton_count' })[0]
Check 'Q00-reason-kind-is-conflict' ([string]$req.ReasonKind -eq 'conflict') ([string]$req.ReasonKind)
Check 'Q00-candidates-carry-value-unit-scope' (@($req.Candidates).Count -eq 2 -and [string]@($req.Candidates)[0].Unit -eq 'cartons' -and [string]@($req.Candidates)[0].Scope -eq 'cartons') (@($req.Candidates) | ConvertTo-Json -Depth 4 -Compress)
Check 'Q00-candidates-carry-source-refs' ([bool](@(@($req.Candidates)[0].SourceRefs).Count -gt 0)) (@($req.Candidates)[0].SourceRefs -join ',')

$decConflict = [pscustomobject]@{ AskFields = @('weight'); Facts = $cf; RequestedFacts = @(); ActionEvidence = $null; ClarifyFields = @('carton_count') }

# ---- Q01 无来源候选被阻断 ----
$q01 = Test-ReplyCompliance -Text 'Which carton count is correct - 999 or 1000?' -Rules $null -Decision $decConflict
Check 'Q01-invented-candidates-blocked' (-not $q01.Ok) (Codes $q01)
Check 'Q01-code' ([bool]((Codes $q01) -match 'CLARIFY_CANDIDATE_UNSUPPORTED')) (Codes $q01)

# ---- Q02 两种合法澄清形式都能通过 ----
$q02a = Test-ReplyCompliance -Text 'Which carton count is correct - 20 or 24?' -Rules $null -Decision $decConflict
Check 'Q02-which-form-passes' ([bool]$q02a.Ok) (Codes $q02a)
$q02b = Test-ReplyCompliance -Text 'Could you confirm whether the carton count is 20 or 24?' -Rules $null -Decision $decConflict
Check 'Q02-confirm-whether-form-passes' ([bool]$q02b.Ok) (Codes $q02b)

# ---- Q03 'which count can you provide' 属于新索取，按 collect 判定 ----
$q03 = Test-ReplyCompliance -Text 'Which carton count can you provide for the quote?' -Rules $null -Decision $decConflict
Check 'Q03-reask-is-not-a-clarification' (-not $q03.Ok) (Codes $q03)
Check 'Q03-code-is-out-of-scope' ([bool]((Codes $q03) -match 'ASK_OUT_OF_SCOPE')) (Codes $q03)

# ---- Q04 数字相同但单位/范围换成 pallets / 产品件 / 重量 => 按具体字段/单位阻断 ----
foreach ($t in @(
    'Which carton count is correct - 20 pallets or 24 pallets?',
    'Which carton count is correct - 20 pcs or 24 pcs?',
    'Which carton count is correct - 20 kg or 24 kg?'
)) {
    $rr = Test-ReplyCompliance -Text $t -Rules $null -Decision $decConflict
    Check ('Q04-unit-or-scope-mismatch-blocked [' + $t + ']') (-not $rr.Ok) (Codes $rr)
}

# ---- Q05 真实冲突下不编造选项的开放澄清可以通过；孤立 ClarifyFields 无真实歧义不允许编造候选 ----
$q05 = Test-ReplyCompliance -Text 'Could you confirm which carton count we should use?' -Rules $null -Decision $decConflict
Check 'Q05-open-clarification-passes' ([bool]$q05.Ok) (Codes $q05)
$bareClarify = [pscustomobject]@{ AskFields = @('weight'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null; ClarifyFields = @('carton_count') }
$q05b = Test-ReplyCompliance -Text 'Which carton count is correct - 20 or 24?' -Rules $null -Decision $bareClarify
Check 'Q05-bare-clarify-index-does-not-authorize-values' (-not $q05b.Ok) (Codes $q05b)

# ---- Q06 合法 count 澄清 + 未授权 contact/尺寸请求：逐项阻断 ----
$q06 = Test-ReplyCompliance -Text 'Which carton count is correct - 20 or 24, and could you also share the recipient''s phone number?' -Rules $null -Decision $decConflict
Check 'Q06-other-unauthorized-ask-blocked' (-not $q06.Ok) (Codes $q06)
$q06b = Test-ReplyCompliance -Text 'Which carton count is correct - 20 or 24, and could you also share the packed dimensions per carton?' -Rules $null -Decision $decConflict
Check 'Q06-dimension-ask-blocked' (-not $q06b.Ok) (Codes $q06b)

# ---- Q07 AskFields 也授权该字段，仍不能伪造已有候选 ----
$decConflictWeightCount = [pscustomobject]@{ AskFields = @('weight', 'carton_count'); Facts = $cf; RequestedFacts = @(); ActionEvidence = $null; ClarifyFields = @('carton_count') }
$q07 = Test-ReplyCompliance -Text 'Which carton count is correct - 999 or 1000?' -Rules $null -Decision $decConflictWeightCount
Check 'Q07-authorization-does-not-license-fake-candidates' (-not $q07.Ok) (Codes $q07)

# ---- Q08 原范围/修饰语规则与真实目的地澄清保持 ----
$weightDim = [pscustomobject]@{ AskFields = @('weight', 'dimension'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
Check 'Q08-unit-modifier-not-a-count-ask' ([bool](Test-ReplyCompliance -Text 'Could you share the packed dimensions per carton or pallet (L x W x H)?' -Rules $null -Decision $weightDim).Ok) ''
Check 'Q08-relative-clause-not-exempt' (-not (Test-ReplyCompliance -Text 'Could you share the carton count, which we need for the quote?' -Rules $null -Decision $decConflict).Ok) ''
$addrConv = ConvertTo-MessageList (BLine 'Can you quote 10 cartons to Hamburg?' $ts) 'Virtual Buyer'
$addrFacts = Get-ConversationFacts $addrConv
$addrDec = Get-ReplyDecision -Conversation $addrConv -Facts $addrFacts -ForceScenario 'address_clarify'
Check 'Q08-address-clarify-has-structured-request' ([bool](@($addrDec.ClarificationRequests | Where-Object { $_.FieldKey -eq 'delivery_address' }).Count -ge 1)) ''
$addrFb = Get-ScenarioFallback -Decision $addrDec
Check 'Q08-address-clarify-fallback-compliant' ([bool](Test-ReplyCompliance -Text $addrFb -Rules $null -Decision $addrDec).Ok) (Codes (Test-ReplyCompliance -Text $addrFb -Rules $null -Decision $addrDec))

# ---- 交叉：先澄清真实 20/24，再追加未授权供应商/客户联系请求：逐项检查 ----
$cross = Test-ReplyCompliance -Text 'Could you confirm whether the carton count is 20 or 24, and please share your supplier''s contact details?' -Rules $null -Decision $decConflict
Check 'X-clarify-plus-unauthorized-contact-blocked' (-not $cross.Ok) (Codes $cross)

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
