# tests\third_fix_tasks_evidence.tests.ps1 - R2/R3：确切任务引用 + 逐项行动取证 + 确认资料闭环
#
# 依据：docs\specs\独立复核七项与验收守卫修复_spec_20261005.md §4 / §5 / §10.2。
# 失败基线：仅有一条 fulfillment_status 待办时仍借它授权供应商承诺；contacted 被当成"供应商已确认"。
#
# 分层：isolated（临时运行根内的真实任务存储；不联网、不开页、不发送、不通知真实通道）。
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

Write-Output '== third_fix task/evidence tests (R2 / R3) =='

$isoRoot = Join-Path $env:TEMP ('aar-third-tasks-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
Check 'A00-isolated-runtime' (Test-AarIsolatedRuntime) 'isolation marker missing'

. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')
. (Join-Path $scripts 'lib\task_facts.ps1')

function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
$LF = [string][char]10
$ts = [long]1791172800000
$buyer = 'Virtual Buyer'
function ClearTaskState {
    $f = Get-HumanTaskFile
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if (Test-Path ($f + '.bak')) { Remove-Item -LiteralPath ($f + '.bak') -Force -ErrorAction SilentlyContinue }
}
function PlanBlocked([string]$text, $ev) {
    $dec = [pscustomobject]@{ ActionEvidence = (New-ActionEvidence -Values $ev); AskFields = @(); RequestedFacts = @(); Facts = $null }
    return (Test-SupplierPlanWording -Text $text -Decision $dec)
}

# ---- A01 仅 fulfillment_status 待办：不得授权任何供应商计划 ----
ClearTaskState
$other = New-OrUpdate-HumanTask -Buyer $buyer -Kind 'fulfillment_status' -TriggerMessage 'Where is my shipment?' -Status 'pending_human'
$sel = Select-RelatedHumanTask -Buyer $buyer -Kind 'supplier_verification'
Check 'A01-unrelated-todo-is-not-selected' (-not [bool]$sel.Selected) ([string]$sel.Reason)
$evBuyer = Get-ActionEvidenceForBuyer -Buyer $buyer
Check 'A01-summary-evidence-is-not-supplier-authorization' (Test-SupplierPlanWording -Text "We'll contact your supplier directly." -Decision ([pscustomobject]@{ ActionEvidence = (New-ActionEvidence -Values $evBuyer); AskFields = @(); RequestedFacts = @(); Facts = $null })) ''

# ---- A05 awaiting_contact（缺联系人）：条件计划可发，无条件"直接联系"不获授权 ----
ClearTaskState
$tk = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -MissingFields @('unit_dimensions') -TriggerMessage 'Please verify packing for this shipment.' -TriggerAt '2026-10-05T04:00:00Z'
Eq 'A05-task-awaiting-contact' ([string]$tk.Task.status) 'awaiting_contact'
$evA5 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk.Task.id) -Kind 'supplier_verification' -SupplierIdentity ([string]$tk.Task.supplierKey)
Check 'A05-exact-readback' ([bool]$evA5.TodoPersisted -and [bool]$evA5.ExactTaskMatch -and [bool]$evA5.IsOpen) ([string]$evA5.EvidenceOrigin)
Check 'A05-no-usable-contact' (-not [bool]$evA5.HasUsableSupplierContact) ''
Check 'A05-conditional-plan-allowed' (-not (PlanBlocked "Once you share the supplier's contact, we'll check the packing details with them." $evA5)) ''
Check 'A05-unconditional-direct-contact-blocked' (PlanBlocked "We'll contact your supplier directly." $evA5) ''

# ---- A07 仅通知投递 / 仅人工认领：只授权对应声明 ----
ClearTaskState
$tk7 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'supplier@example.invalid' -TriggerMessage 'Please verify packing for this shipment.' -TriggerAt '2026-10-05T04:00:00Z'
[void](Add-HumanTaskNotification -Id ([string]$tk7.Task.id) -Delivered $true -Detail 'stub')
$evNotify = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk7.Task.id) -Kind 'supplier_verification'
Check 'A07-notification-recorded' ([bool]$evNotify.NotificationDelivered) ''
Check 'A07-notification-does-not-authorize-contact-claim' (PlanBlocked 'We have already contacted your supplier about the packing.' $evNotify) ''
Check 'A07-notification-does-not-authorize-confirmation' (PlanBlocked 'Your supplier confirmed the packed weight is 20 kg.' $evNotify) ''
[void](Set-HumanTaskOwnerAccepted -Id ([string]$tk7.Task.id))
$evOwner = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk7.Task.id) -Kind 'supplier_verification'
Check 'A07-owner-accepted-recorded' ([bool]$evOwner.OwnerAccepted) ''
Check 'A07-owner-accept-is-not-contact' (-not [bool]$evOwner.ContactedRecorded) ''

# ---- A08 contacted=true / supplierReply=false：合法"已联系、等确认"；阻断"供应商已确认" ----
[void](Set-HumanTaskStatus -Id ([string]$tk7.Task.id) -Status 'contacted' -Note 'Called supplier; waiting for a reply')
$evA8 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk7.Task.id) -Kind 'supplier_verification'
Check 'A08-status-without-provenance-is-not-contacted' (-not [bool]$evA8.ContactedRecorded) ''
Eq 'A08-status-has-no-action-source' ([string]$evA8.ContactedSource) ''
Check 'A08-supplier-reply-not-recorded' (-not [bool]$evA8.SupplierReplyRecorded) ''
Check 'A08-unverified-contacted-waiting-blocked' (PlanBlocked "We've contacted your supplier and are waiting for their confirmation." $evA8) ''
Check 'A08-confirmation-claim-blocked' (PlanBlocked 'Your supplier confirmed the dimensions.' $evA8) ''

# ---- A09 模糊 note/resolution 不生成供应商回复/确认证据 ----
ClearTaskState
$tk9 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'supplier@example.invalid' -TriggerMessage 'Please verify packing for this shipment.' -TriggerAt '2026-10-05T04:00:00Z'
[void](Set-HumanTaskStatus -Id ([string]$tk9.Task.id) -Status 'awaiting_supplier_reply' -Note 'customer cancelled, handled manually' -Resolution 'handled / waiting for reply')
$evA9 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk9.Task.id) -Kind 'supplier_verification'
Check 'A09-legacy-resolution-is-not-a-reply' (-not [bool]$evA9.SupplierReplyRecorded) ''
Check 'A09-legacy-resolution-marked-unverified' ([bool]$evA9.SupplierReplyLegacyUnverified) ''
Eq 'A09-legacy-reply-source' ([string]$evA9.SupplierReplySource) 'legacy-unverified'
Check 'A09-no-confirmed-fields-from-vague-text' (@($evA9.ConfirmedFields).Count -eq 0) ''
Check 'A09-confirmation-still-blocked' (PlanBlocked 'Your supplier confirmed the packed weight is 20 kg per carton.' $evA9) ''

# ---- A10 真实结构化供应商回复及确认字段 ----
$add = Add-HumanTaskActionRecord -Id ([string]$tk9.Task.id) -ActionKind 'supplier_reply' -Source 'manual-entry' -RecordedBy 'operator-1' -SourceRef 'call-2026-10-05-1' -RawContent 'Supplier confirmed 10 cartons, 12 kg per carton, 50x40x30 cm per carton.' -AtUtc '2026-10-05T03:00:00Z' -ConfirmedFields @(
    @{ FieldKey = 'carton_count'; Value = '10'; Unit = 'cartons'; Scope = 'cartons' },
    @{ FieldKey = 'unit_weight'; Value = '12'; Unit = 'kg'; Scope = 'unit' },
    @{ FieldKey = 'unit_dimensions'; Value = '50x40x30'; Unit = 'cm'; Scope = 'unit' }
)
Check 'A10-structured-record-written' ([bool]$add.Ok) ([string]$add.Error)
$evA10 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk9.Task.id) -Kind 'supplier_verification'
Check 'A10-reply-recorded' ([bool]$evA10.SupplierReplyRecorded) ''
Eq 'A10-reply-source-is-record' ([string]$evA10.SupplierReplySource) 'action-record'
Check 'A10-confirmed-fields-kept-with-unit-and-scope' (@($evA10.ConfirmedFields).Count -eq 3 -and [string]@($evA10.ConfirmedFields)[0].Unit -eq 'cartons') (@($evA10.ConfirmedFields) | ConvertTo-Json -Depth 4 -Compress)
Check 'A10-generic-reply-allowed' (-not (PlanBlocked 'Your supplier has replied with the packing details.' $evA10)) ''
Check 'A10-supported-values-allowed' (-not (PlanBlocked 'Your supplier confirmed 12 kg per carton and the carton size 50x40x30 cm.' $evA10)) ''
Check 'A10-unsupported-value-blocked' (PlanBlocked 'Your supplier confirmed 99 kg per carton.' $evA10) ''
Check 'A10-unsupported-field-blocked' (PlanBlocked 'Your supplier confirmed the delivery address.' $evA10) ''

# ---- A11 混合声明：前项证据不能豁免后项 ----
Check 'A11-mixed-claim-blocked' (PlanBlocked "We contacted your supplier and your supplier confirmed the delivery address." $evA10) ''

# ---- A12 旧 key 缺失但本任务联系人完整 / 无法核对 ----
ClearTaskState
$legacy = [pscustomobject]@{
    id = 'legacy001'; buyer = $buyer; buyerKey = 'virtual buyer'; kind = 'supplier_verification'; status = 'pending_human'
    supplierKey = ''; supplierContact = 'factory@example.invalid'; supplierContactSource = 'message-email'
    firstTriggerMessage = "My supplier's contact is factory@example.invalid"; lastTriggerMessage = "My supplier's contact is factory@example.invalid"
    missingFields = @('unit_dimensions'); notification = [pscustomobject]@{ attempts = 0; delivered = $false; lastAt = ''; detail = '' }
    ownerAccepted = $false; deadline = ''; resolution = ''; createdAt = '2026-10-05T00:00:00Z'; updatedAt = '2026-10-05T00:00:00Z'
}
$storeFile = Get-HumanTaskFile
[System.IO.File]::WriteAllText($storeFile, ((@{ version = 1; updatedAt = '2026-10-05T00:00:00Z'; tasks = @($legacy) } | ConvertTo-Json -Depth 8) + $LF), (New-Object System.Text.UTF8Encoding($true)))
$flow=Sync-CurrentCargoFlow -Buyer $buyer -SupplierIdentity 'email:factory@example.invalid' -TriggerMessage $legacy.firstTriggerMessage
Set-HumanTaskField $legacy FlowId $flow.Id
[void](Save-HumanTaskStore @($legacy))
$selLegacy = Select-RelatedHumanTask -Buyer $buyer -Kind 'supplier_verification' -SupplierIdentity 'email:factory@example.invalid'
Check 'A12-legacy-task-matched-by-its-own-contact' ([bool]$selLegacy.Selected -and [string]$selLegacy.TaskId -eq 'legacy001') ([string]$selLegacy.Reason)
$selWrong = Select-RelatedHumanTask -Buyer $buyer -Kind 'supplier_verification' -SupplierIdentity 'email:other@example.net'
Check 'A12-unverifiable-identity-does-not-wildcard' (-not [bool]$selWrong.Selected) ([string]$selWrong.Reason)

# ---- A13 存储失败：保留任务、不假投递、不推进账本（任务表本身不被删除） ----
ClearTaskState
$tk13 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'supplier@example.invalid' -TriggerMessage 'Please verify packing for this shipment.' -TriggerAt '2026-10-05T04:00:00Z'
[void](Add-HumanTaskNotification -Id ([string]$tk13.Task.id) -Delivered $false -Detail 'FAILED')
$ev13 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk13.Task.id) -Kind 'supplier_verification'
Check 'A13-notification-failure-keeps-task' (@(Get-HumanTaskList -Buyer $buyer -OpenOnly).Count -eq 1) ''
Check 'A13-notification-not-delivered' (-not [bool]$ev13.NotificationDelivered) ''
Check 'A13-untrusted-source-rejected' (-not [bool](Add-HumanTaskActionRecord -Id ([string]$tk13.Task.id) -ActionKind 'supplier_reply' -Source 'monitor' -RawContent 'auto').Ok) ''
Check 'A13-insufficient-content-rejected' (-not [bool](Add-HumanTaskActionRecord -Id ([string]$tk13.Task.id) -ActionKind 'supplier_reply' -Source 'manual-entry' -RawContent '').Ok) ''

# ---- A14 通知尝试数变化但关键证据未变 => 指纹稳定 ----
$fp1 = [string]$ev13.KeyEvidenceFingerprint
[void](Add-HumanTaskNotification -Id ([string]$tk13.Task.id) -Delivered $false -Detail 'retry')
$ev14 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk13.Task.id) -Kind 'supplier_verification'
Check 'A14-fingerprint-ignores-notification-attempts' ([string]$ev14.KeyEvidenceFingerprint -eq $fp1) ($fp1 + ' vs ' + [string]$ev14.KeyEvidenceFingerprint)

# ---- A18 更正：新确认取代旧值，旧记录不再被引用 ----
$rec1 = Add-HumanTaskActionRecord -Id ([string]$tk13.Task.id) -ActionKind 'supplier_reply' -Source 'owner-ui' -RawContent 'first confirmation' -AtUtc '2026-10-05T04:01:00Z' -SourceRef 'call:fixture-rec1' -RecordedBy 'fixture operator' -ConfirmedFields @(@{ FieldKey = 'unit_weight'; Value = '12'; Unit = 'kg'; Scope = 'unit' })
Check 'A18-first-confirmation-written' ([bool]$rec1.Ok) ''
$correction18=@(Get-HumanTaskConfirmedFields (Get-HumanTaskList -TaskId $tk13.Task.id)[0])[0].FactRef
$rec2 = Add-HumanTaskActionRecord -CorrectionOfFactRef $correction18 -Id ([string]$tk13.Task.id) -ActionKind 'supplier_reply' -Source 'owner-ui' -RawContent 'corrected confirmation' -AtUtc '2026-10-05T04:01:00Z' -SourceRef 'call:fixture-rec2' -RecordedBy 'fixture operator' -ConfirmedFields @(@{ FieldKey = 'unit_weight'; Value = '15'; Unit = 'kg'; Scope = 'unit' })
Check 'A18-correction-written' ([bool]$rec2.Ok) ''
$fields18 = @(Get-HumanTaskConfirmedFields (Get-HumanTaskList -Buyer $buyer -TaskId ([string]$tk13.Task.id))[0])
Eq 'A18-only-the-corrected-value-remains' (@($fields18 | Where-Object { $_.FieldKey -eq 'unit_weight' }).Count) 1
Eq 'A18-corrected-value' ([string]@($fields18 | Where-Object { $_.FieldKey -eq 'unit_weight' })[0].Value) '15'

# ---- A16 确认资料保存并重载 => 统一事实 provided、Ready=true、不再补问 ----
ClearTaskState
$conv16 = ConvertTo-MessageList ((BLine 'Please quote for this shipment.' $ts) + $LF + (BLine "My supplier's contact is supplier@example.invalid" ($ts + 1000))) $buyer
$tk16 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'supplier@example.invalid' -MissingFields @('carton_count','unit_weight','unit_dimensions','delivery_address') -TriggerMessage "My supplier's contact is supplier@example.invalid" -TriggerMessageId ([string]@($conv16.Messages)[1].StableId)
$rec16 = Add-HumanTaskActionRecord -Id ([string]$tk16.Task.id) -ActionKind 'supplier_reply' -Source 'manual-entry' -RecordedBy 'operator-2' -RawContent 'Supplier confirmed the packing data.' -AtUtc '2026-10-05T04:01:00Z' -SourceRef 'call:fixture-rec16' -ConfirmedFields @(
    @{ FieldKey = 'carton_count'; Value = '10'; Unit = 'cartons'; Scope = 'cartons' },
    @{ FieldKey = 'unit_weight'; Value = '12'; Unit = 'kg'; Scope = 'unit' },
    @{ FieldKey = 'unit_dimensions'; Value = '50x40x30'; Unit = 'cm'; Scope = 'unit' },
    @{ FieldKey = 'delivery_address'; Value = 'Amazon FTW1'; Unit = ''; Scope = 'destination' }
)
Check 'A16-record-written' ([bool]$rec16.Ok) ([string]$rec16.Error)
# 重新读盘（模拟进程重启）后仍能读到嵌套记录与单位/范围/来源。
$reloaded = @(Get-HumanTaskList -Buyer $buyer -TaskId ([string]$tk16.Task.id))[0]
$fieldsReloaded = @(Get-HumanTaskConfirmedFields $reloaded)
Eq 'A16-reloaded-confirmed-field-count' $fieldsReloaded.Count 4
Eq 'A16-reloaded-unit-preserved' ([string]@($fieldsReloaded | Where-Object { $_.FieldKey -eq 'unit_dimensions' })[0].Unit) 'cm'
Eq 'A16-reloaded-scope-preserved' ([string]@($fieldsReloaded | Where-Object { $_.FieldKey -eq 'unit_dimensions' })[0].Scope) 'unit'
Check 'A16-reloaded-record-id-preserved' ([bool]([string]@($fieldsReloaded | Where-Object { $_.FieldKey -eq 'unit_dimensions' })[0].RecordId)) ''
$evidence16 = @(Get-TaskConfirmedEvidence -Buyer $buyer -Conversation $conv16)
Check 'A16-adapter-exports-evidence' ($evidence16.Count -eq 4) ([string]$evidence16.Count)
$cf16 = Get-CargoFacts -Conversation $conv16 -TaskEvidence $evidence16
$rd16 = Get-QuoteReadiness -Facts $cf16
Check 'A16-four-minimum-fields-provided' ([bool]$rd16.Ready) ('missing=' + (@($rd16.MissingFields) -join ','))
Eq 'A16-carton-count-becomes-provided' ([string]$cf16.ByKey['carton_count'].Status) 'provided'
Eq 'A16-unit-weight-becomes-provided' ([string]$cf16.ByKey['unit_weight'].Status) 'provided'
# 同一事实模型 => 决策不再补问已确认项（AskableFields 不含它们）。
$facts16 = Get-ConversationFacts -Conversation $conv16 -Buyer $buyer -WithTaskEvidence
$dec16 = Get-ReplyDecision -Conversation $conv16 -Facts $facts16 -Rules $null
Check 'A16-no-reask-of-confirmed-count' (-not (@($dec16.AskFields) -contains 'carton_count')) (@($dec16.AskFields) -join ',')
Check 'A16-no-reask-of-confirmed-weight' (-not (@($dec16.AskFields) -contains 'unit_weight')) (@($dec16.AskFields) -join ',')
# 统一 quote/readiness 与摘要入口消费同一结果。
$rw16 = Get-QuoteReadinessForConversationText -Text (($conv16.Lines) -join $LF) -ConvoName $buyer -WithTaskEvidence
Check 'A16-quote-entry-agrees' ([bool]$rw16.Ready) ([string]$rw16.Error)
# 任务来源的证据仍带 TaskId/RecordId（不是"伪装成买家原话"）。
Eq 'A16-task-evidence-source' ([string]$cf16.ByKey['carton_count'].Evidence[0].Source) 'task'
Check 'A16-task-evidence-carries-record-id' ([bool]([string]$cf16.ByKey['carton_count'].Evidence[0].RecordId)) ''

# ---- A17 resolved 后可信事实仍可读取；不再对已 resolved 任务许诺待执行计划 ----
[void](Set-HumanTaskStatus -Id ([string]$tk16.Task.id) -Status 'resolved' -Resolution 'data collected')
$ev17 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId ([string]$tk16.Task.id) -Kind 'supplier_verification'
Check 'A17-closed-task-still-reported-as-existing' ([bool]$ev17.TaskExists) ''
Check 'A17-closed-task-not-open' (-not [bool]$ev17.IsOpen) ''
Check 'A17-confirmed-facts-survive-closure' (@($ev17.ConfirmedFields).Count -eq 4) ([string]@($ev17.ConfirmedFields).Count)
Check 'A17-no-future-plan-for-resolved-task' (PlanBlocked "We'll check the packed weight with your supplier." $ev17) ''

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
