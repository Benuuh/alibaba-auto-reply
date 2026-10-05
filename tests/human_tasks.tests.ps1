# tests\human_tasks.tests.ps1 - 人工任务闭环与执行证据（2026-10-05 spec §4 / §6.1 / §7）
#
# 覆盖：
#   T1  新建供应商核实任务（无联系方式）⇒ awaiting_contact；证据 TodoPersisted=true
#   T2  客户反复催问 ⇒ 更新同一个未完成任务，不重复建单（askCount 递增）
#   T3  已给供应商联系方式 ⇒ pending_human；不同供应商键 ⇒ 各自独立任务
#   T4  状态流转 awaiting_contact → pending_human → contacted → awaiting_supplier_reply → resolved
#   T5  通知失败 ⇒ NotificationDelivered=false（任务保留、可重试，不得声称人工已收到）
#   T6  通知成功 ⇒ NotificationDelivered=true
#   T7  人工认领 + 确认期限 ⇒ OwnerAccepted/Deadline 成立（期限只有人工确认才有）
#   T8  任务 resolved ⇒ 不再提供 TodoPersisted 证据
#   T9  持久化：重新读盘后任务与状态一致
#   T10 存储损坏 ⇒ 状态如实上报（corrupt），不崩、不静默当作"从未有过任务"
#   T11 证据对象可直接喂给 New-ActionEvidence（与 seller_context 的契约一致）
#   T12 不同任务类型互不覆盖；-Kind 过滤只取本轮相关任务
#
# 隔离：临时运行根 + 隔离标记。
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

Write-Output '== human_tasks tests =='

$isoRoot = Join-Path $env:TEMP ('aar-tasks-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')

$buyer = 'Buyer Task'

try {
    # ---- T1 ----
    $r1 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -MissingFields @('carton_count', 'unit_weight') -TriggerMessage 'no dimensions yet'
    Check 'T1-created' $r1.Created
    Eq 'T1-status-awaiting-contact' $r1.Task.status 'awaiting_contact'
    Eq 'T1-missing-fields' (@($r1.Task.missingFields) -join ',') 'carton_count,unit_weight'
    $ev1 = Get-ActionEvidenceForBuyer -Buyer $buyer
    Check 'T1-evidence-todo-persisted' $ev1.TodoPersisted
    Check 'T1-evidence-notification-false' (-not $ev1.NotificationDelivered)
    Eq 'T1-open-task-count' $ev1.OpenTaskCount 1

    # ---- T2 ----
    $id1 = [string]$r1.Task.id
    $r2 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -MissingFields @('carton_count')
    Check 'T2-not-created-again' (-not $r2.Created)
    Eq 'T2-same-task-id' ([string]$r2.Task.id) $id1
    Eq 'T2-single-open-task' (@(Get-HumanTaskList -Buyer $buyer -OpenOnly).Count) 1
    Check 'T2-ask-count-incremented' ([int]$r2.Task.askCount -ge 2) ('askCount=' + $r2.Task.askCount)

    # ---- T3 ----
    $r3 = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact '+86 138 0000 0000' -MissingFields @('carton_count')
    Eq 'T3-with-contact-pending-human' $r3.Task.status 'pending_human'
    Check 'T3-supplier-key-set' (([string]$r3.Task.supplierKey).Length -gt 5) ('key=' + $r3.Task.supplierKey)
    $r3b = New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'other-supplier@example.com' -TriggerMessage 'Please use this other supplier for the shipment.'
    Check 'T3-different-supplier-is-separate-task' ([string]$r3b.Task.id -ne [string]$r3.Task.id)
    Eq 'T3-two-open-tasks' (@(Get-HumanTaskList -Buyer $buyer -OpenOnly).Count) 2

    # ---- T4 ----
    $tid = [string]$r3.Task.id
    Check 'T4-set-contacted' (Set-HumanTaskStatus -Id $tid -Status 'contacted' -Note 'called supplier')
    $t = @(Get-HumanTaskList -Buyer $buyer | Where-Object { $_.id -eq $tid })[0]
    Eq 'T4-status-contacted' $t.status 'contacted'
    Check 'T4-status-does-not-imply-owner-accepted' (-not [bool]$t.ownerAccepted)
    Check 'T4-set-awaiting-supplier-reply' (Set-HumanTaskStatus -Id $tid -Status 'awaiting_supplier_reply')
    $ev4 = Get-ActionEvidenceForTask -Buyer $buyer -TaskId $tid -Kind 'supplier_verification'
    Eq 'T4-other-supplier-not-current-evidence' $ev4.TaskStatus ''
    Check 'T4-evidence-owner-not-fabricated' (-not $ev4.OwnerAccepted)
    Check 'T4-incomplete-cannot-resolve' (-not (Set-HumanTaskStatus -Id $tid -Status resolved))
    $null=Add-HumanTaskActionRecord -Id $tid -ActionKind supplier_reply -Source operator-entry -RecordedBy 'fixture operator' -SourceRef 'call:task-4' -AtUtc '2026-10-05T04:01:00Z' -RawContent 'Supplier supplied 10 cartons and 20 kg per carton.' -ConfirmedFields @(@{FieldKey='carton_count';Value='10';Unit='cartons';Scope='cartons'},@{FieldKey='unit_weight';Value='20';Unit='kg';Scope='unit'})
    Check 'T4-set-resolved' (Set-HumanTaskStatus -Id $tid -Status 'resolved' -Resolution 'supplier confirmed 10 cartons 20kg each')
    Eq 'T4-open-task-count-after-resolve' (@(Get-HumanTaskList -Buyer $buyer -OpenOnly).Count) 1

    # ---- T5 / T6 ----
    $openId = [string](@(Get-HumanTaskList -Buyer $buyer -OpenOnly))[0].id
    $null = Add-HumanTaskNotification -Id $openId -Delivered $false -Detail 'dsh-im timeout'
    $ev5 = Get-ActionEvidenceForBuyer -Buyer $buyer
    Check 'T5-failed-notification-is-false' (-not $ev5.NotificationDelivered)
    Eq 'T5-task-kept-open' $ev5.OpenTaskCount 1
    $null = Add-HumanTaskNotification -Id $openId -Delivered $false -Detail 'retry timeout'
    $attempts = 0
    foreach ($x in @(Get-HumanTaskList -Buyer $buyer)) { if ([string]$x.id -eq $openId) { $attempts = [int]$x.notification.attempts } }
    Eq 'T5-attempts-counted' $attempts 2
    $null = Add-HumanTaskNotification -Id $openId -Delivered $true -Detail 'delivered'
    $ev6 = Get-ActionEvidenceForBuyer -Buyer $buyer
    Check 'T6-delivered-notification-is-true' $ev6.NotificationDelivered

    # ---- T7 ----
    Check 'T7-owner-accepts-with-deadline' (Set-HumanTaskOwnerAccepted -Id $openId -Deadline '2026-10-06 18:00')
    $ev7 = Get-ActionEvidenceForBuyer -Buyer $buyer
    Check 'T7-evidence-owner-accepted' $ev7.OwnerAccepted
    Eq 'T7-evidence-deadline' $ev7.Deadline '2026-10-06 18:00'
    Check 'T7-deadline-only-after-human-confirmation' ($null -ne $ev7.Deadline)

    # ---- T11: 与 seller_context 的 ActionEvidence 契约一致 ----
    $ae = New-ActionEvidence -Values $ev7
    Check 'T11-action-evidence-todo' $ae.TodoPersisted
    Check 'T11-action-evidence-notify' $ae.NotificationDelivered
    Check 'T11-action-evidence-owner' $ae.OwnerAccepted
    Check 'T11-action-evidence-deadline' $ae.HasDeadline
    $noTask = New-ActionEvidence -Values (Get-ActionEvidenceForBuyer -Buyer 'Nobody Here')
    Check 'T11-no-task-no-evidence' ((-not $noTask.TodoPersisted) -and (-not $noTask.NotificationDelivered) -and (-not $noTask.HasDeadline))

    # ---- T8 ----
    foreach ($x in @(Get-HumanTaskList -Buyer $buyer -OpenOnly)) { $null = Set-HumanTaskStatus -Id ([string]$x.id) -Status 'closed' -Resolution 'cancelled in fixture' }
    $ev8 = Get-ActionEvidenceForBuyer -Buyer $buyer
    Check 'T8-resolved-no-todo-evidence' (-not $ev8.TodoPersisted)
    Eq 'T8-no-open-tasks' $ev8.OpenTaskCount 0

    # ---- T9: 持久化 ----
    $file = Get-HumanTaskFile
    Check 'T9-store-file-exists' (Test-Path $file) $file
    Check 'T9-store-inside-isolated-root' (Test-AarPathUnder $file $isoRoot) $file
    Check 'T9-tasks-survive-reload' (@(Get-HumanTaskList -Buyer $buyer).Count -ge 2)
    $sum = Get-HumanTaskSummary
    Check 'T9-summary-counts' ($sum.Total -ge 2) ('total=' + $sum.Total)

    # ---- T12 ----
    $rc = New-OrUpdate-HumanTask -Buyer $buyer -Kind 'complaint_review' -TriggerMessage 'buyer is angry'
    Check 'T12-other-kind-created' $rc.Created
    $evSup = Get-ActionEvidenceForBuyer -Buyer $buyer -Kind 'supplier_verification'
    $evCmp = Get-ActionEvidenceForBuyer -Buyer $buyer -Kind 'complaint_review'
    Eq 'T12-kind-filter-supplier' $evSup.TaskKind ''
    Eq 'T12-kind-filter-complaint' $evCmp.TaskKind 'complaint_review'

    # ---- T10: 损坏的存储 ----
    [System.IO.File]::WriteAllText($file, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
    $sumBad = Get-HumanTaskSummary
    Eq 'T10-corrupt-store-reported' $sumBad.Status 'corrupt'
    Eq 'T10-corrupt-store-no-tasks' $sumBad.Total 0
    $failedRead=$false;try{Get-ActionEvidenceForBuyer -Buyer $buyer}catch{$failedRead=$true};Check 'T10-corrupt-evidence-fails-closed' $failedRead
    $before=[IO.File]::ReadAllText($file);$failedWrite=$false;try{New-OrUpdate-HumanTask -Buyer $buyer -Kind supplier_verification}catch{$failedWrite=$true};Check 'T10-corrupt-store-not-rebuilt' ($failedWrite -and [IO.File]::ReadAllText($file) -eq $before)
} finally {
    Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
