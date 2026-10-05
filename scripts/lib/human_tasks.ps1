# lib\human_tasks.ps1 - 人工任务闭环（2026-10-05 spec §4：人工任务必须有真实状态与执行证据）
#
# 为什么需要：决策层此前只返回布尔 NeedHumanTodo（"需要一个待办"），没有任何落库、通知与完成状态，
#   于是"我已转交/我会去核实"这类话术没有任何执行证据支撑。本模块把任务真正落盘，并对外提供
#   ActionEvidence 的四类事实：TodoPersisted / NotificationDelivered / OwnerAccepted / Deadline。
#
# 任务状态（spec §4.1 供应商核实闭环）：
#   awaiting_contact       —— 已记录缺口，正在向客户索取供应商联系方式
#   pending_human          —— 资料齐备，等人工上线认领
#   contacted              —— 人工已联系供应商（必须由人工记录，机器人不得自行置位）
#   awaiting_supplier_reply—— 已联系、等供应商回复（仍属未完成，不能表述为"资料已确认"）
#   resolved               —— 已取得资料并写回事实
#   closed                 —— 关闭（取消/无需处理）
#
# 去重：同一会话 + 同一任务类型 + 同一供应商键 的**未完成**任务持续更新，不重复建单。
#
# 依赖：config.ps1（Get-SkillPath "tasks"）、lib\state_store.ps1
if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Write-JsonDocumentAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'state_store.ps1')
}

$script:HumanTaskOpenStatuses = @('awaiting_contact', 'pending_human', 'contacted', 'awaiting_supplier_reply')
$script:HumanTaskMaxPerBuyer = 30

function Get-HumanTaskFile { return (Get-SkillPath 'tasks') }

function Get-HumanTaskBuyerKey([string]$Buyer) {
    if ([string]::IsNullOrWhiteSpace($Buyer)) { return '' }
    return (($Buyer -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Test-HumanTaskStatus([string]$Status) {
    return (@('awaiting_contact', 'pending_human', 'contacted', 'awaiting_supplier_reply', 'resolved', 'closed') -contains $Status)
}

# =============================================================================================
# [2026-10-05 八项补修 F4 §6.1 第 1 条] 任务类型的唯一映射。
#   决策层用 supplier_handoff 表示"要人工去核实供应商"，持久化层用 supplier_verification。
#   创建、查询、通知与规则登记都消费这一个映射，任何地方都不得再散落字符串替换。
# =============================================================================================
$script:HumanTaskKindAliases = @{
    'supplier_handoff'          = 'supplier_verification'
    'supplier_unreachable'      = 'supplier_verification'
    'supplier_verification'     = 'supplier_verification'
    'supplier_contact'          = 'supplier_verification'
    'suppliercontact'           = 'supplier_verification'
    'supplier-check'            = 'supplier_verification'
    'material_promised'         = 'material_promised'
    'complaint_review'          = 'complaint_review'
    'human_requested'           = 'human_requested'
    'delivery_status'           = 'delivery_status'
    'refusal'                   = 'refusal'
    'quote_preparation'         = 'quote_preparation'
}

function Resolve-HumanTaskKind([string]$Kind) {
    if ([string]::IsNullOrWhiteSpace($Kind)) { return '' }
    $k = ([string]$Kind).Trim().ToLowerInvariant()
    if ($script:HumanTaskKindAliases.ContainsKey($k)) { return [string]$script:HumanTaskKindAliases[$k] }
    return $k
}

# 任务类型是否是供应商核实类（别名也成立）。
function Test-SupplierVerificationKind([string]$Kind) {
    return ((Resolve-HumanTaskKind $Kind) -eq 'supplier_verification')
}

# 已建立"实际联系/供应商已回复"证据的任务状态（认领本身不算联系）。
function Test-HumanTaskContactedStatus([string]$Status) {
    return (@('contacted', 'awaiting_supplier_reply') -contains [string]$Status)
}

function Set-HumanTaskField($Task, [string]$Name, $Value) {
    if (-not $Task -or -not $Name) { return }
    if ($Task.PSObject.Properties.Name -contains $Name) { $Task.$Name = $Value; return }
    $Task | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Get-HumanTaskList {
    param([string]$Buyer = '', [string]$Status = '', [string]$Kind = '', [string]$TaskId = '', [switch]$OpenOnly)
    $store = Get-HealthyHumanTaskData
    $list = @()
    if ($store.tasks) { $list = @($store.tasks) }
    if ($Buyer) {
        $k = Get-HumanTaskBuyerKey $Buyer
        $list = @($list | Where-Object { [string]$_.buyerKey -eq $k })
    }
    if ($TaskId) { $list = @($list | Where-Object { [string]$_.id -eq $TaskId }) }
    # 类型过滤走唯一的别名映射：supplier_handoff 与 supplier_verification 是同一个任务类型。
    if ($Kind) {
        $ck = Resolve-HumanTaskKind $Kind
        $list = @($list | Where-Object { (Resolve-HumanTaskKind ([string]$_.kind)) -eq $ck })
    }
    if ($Status) { $list = @($list | Where-Object { [string]$_.status -eq $Status }) }
    if ($OpenOnly) { $list = @($list | Where-Object { $script:HumanTaskOpenStatuses -contains [string]$_.status }) }
    return @($list)
}

# 找到一个可复用的未完成任务（同买家 + 同类型 + 同供应商键）。
function Find-OpenHumanTask {
    param([Parameter(Mandatory = $true)][string]$Buyer, [Parameter(Mandatory = $true)][string]$Kind, [string]$SupplierKey = '')
    $wantKind = Resolve-HumanTaskKind $Kind
    foreach ($t in @(Get-HumanTaskList -Buyer $Buyer -OpenOnly)) {
        if ((Resolve-HumanTaskKind ([string]$t.kind)) -ne $wantKind) { continue }
        $tSup = ''
        if ($t.PSObject.Properties.Name -contains 'supplierKey') { $tSup = [string]$t.supplierKey }
        if ($SupplierKey -and $tSup -and $tSup -ne $SupplierKey) { continue }
        return $t
    }
    return $null
}

# 新建或更新同一未完成任务。返回 @{ Task; Created; Updated; StoreOk }
function Add-HumanTaskNotificationCore {
    param([Parameter(Mandatory = $true)][string]$Id, [bool]$Delivered = $false, [string]$Detail = '')
    $all = @(Get-HumanTaskList)
    $hit = $false
    foreach ($t in $all) {
        if ([string]$t.id -ne $Id) { continue }
        $attempts = 0
        if ($t.notification -and ($t.notification.PSObject.Properties.Name -contains 'attempts')) { $attempts = [int]$t.notification.attempts }
        Set-HumanTaskField $t 'notification' ([pscustomobject]@{
            attempts  = ($attempts + 1)
            delivered = [bool]$Delivered
            lastAt    = (Get-Date).ToString('o')
            detail    = $Detail
        })
        Set-HumanTaskField $t 'updatedAt' (Get-Date).ToString('o')
        $hit = $true
        break
    }
    if (-not $hit) { return $false }
    return [bool](Save-HumanTaskStore $all)
}

# 人工认领/确认（只有人工动作可以置位）。Deadline 只有真实确认过才写入。
function Set-HumanTaskOwnerAcceptedCore {
    param([Parameter(Mandatory = $true)][string]$Id, [string]$Deadline = '')
    $all = @(Get-HumanTaskList)
    $hit = $false
    foreach ($t in $all) {
        if ([string]$t.id -ne $Id) { continue }
        Set-HumanTaskField $t 'ownerAccepted' $true
        Set-HumanTaskField $t 'ownerAcceptedAt' (Get-Date).ToString('o')
        Set-HumanTaskField $t 'updatedAt' $t.ownerAcceptedAt
        if ($Deadline) { Set-HumanTaskField $t 'deadline' $Deadline }
        $hit = $true
        break
    }
    if (-not $hit) { return $false }
    return [bool](Save-HumanTaskStore $all)
}

# =============================================================================================
# [2026-10-05 第三轮 spec §5.2] 结构化行动/回复记录（同一个原子任务存储内的可选字段）
#
#   为什么需要：仅拆 ContactedRecorded / SupplierReplyRecorded 两个布尔不够——旧实现把**任意非空
#   resolution** 都当成"供应商已回复"，于是"人工处理完毕/等待回复/客户取消"这类模糊文本也授权了
#   "供应商已确认尺寸"。本轮把行动与回复记录结构化：
#     * ActionKind     contacted（我方真的联系过）| supplier_reply（供应商真的回复过）
#                      | resolved（具体事项真的完成）| notified | owner_claimed
#     * 每条记录保存 RecordId / TaskId / 供应商身份 / 绝对 UTC 的实际动作时刻与记录时刻 /
#       记录来源与人工记录者/来源引用 / 原始内容；
#     * supplier_reply 额外保存 ConfirmedFields（字段、值、单位、外包装/总重范围、出处）；
#     * 没有来源或内容不足的记录不授权任何具体确认；
#     * 自动 monitor/LLM 不能自设已联系/已回复/已确认（来源白名单拒绝）。
#
#   兼容：旧任务的 note/resolution/status 保留原样，不清空、不批量重写。旧 resolution 未经结构化
#   来源证明时记为 legacy-unverified，只可在内部展示，**不**升格为供应商回复/确认。
# =============================================================================================
$script:HumanTaskActionKinds = @('notified', 'owner_claimed', 'contacted', 'supplier_reply', 'resolved')
# 只有显式人工记录 / 已有可信业务入口可以写记录；monitor/LLM 的自动路径不在白名单内。
$script:HumanTaskTrustedSources = @('manual-entry', 'owner-ui', 'operator-entry', 'legacy-import')
$script:HumanTaskReplyActionKinds = @('supplier_reply')

function Get-HumanTaskStoreVersion { return 2 }

# 绝对 UTC 时钟（可被夹具注入）：优先用回复链的唯一时钟入口，其次暂停链的 UTC 入口。
function Get-HumanTaskClockUtc {
    if (Get-Command Get-ReplyClockUtc -ErrorAction SilentlyContinue) {
        try { return [datetime](Get-ReplyClockUtc) } catch { }
    }
    if (Get-Command Get-HumanPauseNowUtc -ErrorAction SilentlyContinue) {
        try { return [datetime](Get-HumanPauseNowUtc) } catch { }
    }
    return [datetime]::UtcNow
}

function ConvertTo-HumanTaskUtc($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).UtcDateTime }
    if ($Value -is [System.DateTime]) {
        $d = [System.DateTime]$Value
        if ($d.Kind -eq [System.DateTimeKind]::Utc) { return $d }
        if ($d.Kind -eq [System.DateTimeKind]::Local) { return ([System.DateTimeOffset]$d).UtcDateTime }
        return [System.DateTime]::SpecifyKind($d, [System.DateTimeKind]::Utc)
    }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    $dto = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([System.DateTimeOffset]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dto)) { return $dto.UtcDateTime }
    return $null
}

function Get-HumanTaskEvidenceText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return (([string]$Text) -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function Get-HumanTaskStableHash([string]$Text) {
    if ($null -eq $Text) { return "" }
    try {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } catch { return ([string]$Text.Length).ToString() }
}

function Get-HumanTaskProperty($Object, [string]$Name, $Default = $null) {
    if (-not $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

# 一条结构化记录（不落盘，由 Add-HumanTaskActionRecord 组装）。
function New-HumanTaskActionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$ActionKind,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$RawContent = "",
        [string]$RecordedBy = "",
        [string]$SourceRef = "",
        $AtUtc = $null,
        $RecordedAtUtc = $null,
        $ConfirmedFields = @(),
        [string]$TaskId = "",
        [string]$RecordId = "",
        [string]$SupplierIdentity = "",
        [string]$BuyerKey = "",
        [string]$BatchRef = ""
    )
    $nowUtc = ConvertTo-HumanTaskUtc $RecordedAtUtc
    if (-not $nowUtc) { $nowUtc = Get-HumanTaskClockUtc }
    $actUtc = ConvertTo-HumanTaskUtc $AtUtc
    if (-not $actUtc) { throw 'ACTUAL-ACTION-TIME-REQUIRED' }
    $rid = $RecordId
    if (-not $rid) { $rid = ([guid]::NewGuid().ToString('N').Substring(0, 12)) }
    $fields = New-Object System.Collections.ArrayList
    foreach ($f in @($ConfirmedFields)) {
        if (-not $f) { continue }
        $fk = [string](Get-HumanTaskProperty $f 'FieldKey' '')
        if (-not $fk) { $fk = [string](Get-HumanTaskProperty $f 'Key' '') }
        $fv = Get-HumanTaskProperty $f 'Value' $null
        if (-not $fk -or $null -eq $fv -or [string]::IsNullOrWhiteSpace([string]$fv)) { continue }
        [void]$fields.Add([pscustomobject]@{
            fieldKey  = $fk
            value     = [string]$fv
            unit      = [string](Get-HumanTaskProperty $f 'Unit' '')
            scope     = [string](Get-HumanTaskProperty $f 'Scope' '')
            source    = 'supplier-reply'
            sourceRef = [string](Get-HumanTaskProperty $f 'SourceRef' $SourceRef)
            batchRef  = [string](Get-HumanTaskProperty $f 'BatchRef' $BatchRef)
        })
    }
    return [pscustomobject]@{
        recordId      = $rid
        version       = 1
        taskId        = $TaskId
        buyerKey      = $BuyerKey
        supplierKey   = $SupplierIdentity
        actionKind    = ([string]$ActionKind).Trim().ToLowerInvariant()
        atUtc         = $actUtc.ToString('o')
        recordedAtUtc = $nowUtc.ToString('o')
        source        = ([string]$Source).Trim().ToLowerInvariant()
        recordedBy    = [string]$RecordedBy
        sourceRef     = [string]$SourceRef
        rawContent    = [string]$RawContent
        batchRef      = [string]$BatchRef
        confirmedFields = @($fields.ToArray())
        status        = 'active'
        supersededBy  = ''
        supersededAtUtc = ''
    }
}

function Get-HumanTaskActionRecords($Task) {
    if (-not $Task) { return @() }
    $raw = Get-HumanTaskProperty $Task 'actionRecords' $null
    if (-not $raw) { return @() }
    return @($raw)
}

# 显式记录一条行动/回复。返回 @{ Ok; RecordId; Error }。
#   拒绝：未知 ActionKind、非白名单来源、既无内容也无确认字段（内容不足不授权具体确认）。
function Get-HumanTaskKeyEvidenceFingerprint($Task, $ActiveRecords = $null) {
    if (-not $Task) { return '' }
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add('id=' + [string]$Task.id)
    [void]$parts.Add('buyer=' + [string](Get-HumanTaskProperty $Task 'buyerKey' ''))
    [void]$parts.Add('kind=' + [string](Resolve-HumanTaskKind ([string](Get-HumanTaskProperty $Task 'kind' ''))))
    [void]$parts.Add('status=' + [string](Get-HumanTaskProperty $Task 'status' ''))
    [void]$parts.Add('supplier=' + [string](Get-HumanTaskProperty $Task 'supplierKey' ''))
    [void]$parts.Add('flow=' + [string](Get-HumanTaskProperty $Task 'FlowId' ''))
    [void]$parts.Add('contact=' + (Get-HumanTaskEvidenceText ([string](Get-HumanTaskProperty $Task 'supplierContact' ''))))
    $mf = @(Get-HumanTaskProperty $Task 'missingFields' @()) | ForEach-Object { [string]$_ } | Sort-Object
    [void]$parts.Add('missing=' + ($mf -join '|'))
    [void]$parts.Add('deadline=' + [string](Get-HumanTaskProperty $Task 'deadline' ''))
    $records = $ActiveRecords
    if ($null -eq $records) { $records = @(Get-HumanTaskActionRecords $Task) }
    foreach ($r in @($records | Sort-Object { [string](Get-HumanTaskProperty $_ 'recordId' '') })) {
        if (-not $r) { continue }
        if ([string](Get-HumanTaskProperty $r 'status' 'active') -eq 'superseded') { continue }
        [void]$parts.Add('rec=' + [string](Get-HumanTaskProperty $r 'recordId' '') + ':' + [string](Get-HumanTaskProperty $r 'actionKind' '') + ':' + (Get-HumanTaskEvidenceText ([string](Get-HumanTaskProperty $r 'rawContent' ''))))
        [void]$parts.Add('provenance=' + $r.FlowId + '|' + $r.source + '|' + $r.sourceRef + '|' + $r.recordedBy + '|' + $r.atUtc)
        foreach ($f in @(Get-HumanTaskProperty $r 'confirmedFields' @() | Sort-Object { [string](Get-HumanTaskProperty $_ 'fieldKey' '') })) {
            if (-not $f) { continue }
            [void]$parts.Add('cf=' + [string](Get-HumanTaskProperty $f 'fieldKey' '') + '=' + [string](Get-HumanTaskProperty $f 'value' '') + [string](Get-HumanTaskProperty $f 'unit' '') + '/' + [string](Get-HumanTaskProperty $f 'scope' ''))
            [void]$parts.Add('version=' + $f.FieldVersion + '|' + $f.status)
        }
    }
    return (Get-HumanTaskStableHash (($parts.ToArray()) -join [string][char]10))
}

# 空证据：任何一项都没有成立时用它，绝不把"计划"当证据。
function New-HumanTaskEvidence {
    return [pscustomobject]@{
        TodoPersisted = $false; NotificationDelivered = $false; OwnerAccepted = $false; Deadline = ''
        TaskId = ''; TaskStatus = ''; TaskKind = ''; SupplierIdentity = ''; OpenTaskCount = 0
        UpdatedAt = ''; RequiredContact = ''; TaskSupplierContact = ''
        ContactedRecorded = $false; SupplierReplyRecorded = $false; ResolvedRecorded = $false
        NotificationAttempts = 0; IdentityMatch = $false
        # [2026-10-05 第三轮 spec §4.2/§5.2] 确切回读契约与逐项取证字段。
        EvidenceOrigin = ''; ExactTaskMatch = $false; TaskExists = $false; IsOpen = $false
        HasUsableSupplierContact = $false; KeyEvidenceFingerprint = ''
        ContactedSource = ''; SupplierReplySource = ''; SupplierReplyLegacyUnverified = $false
        ResolutionLegacy = ''; ActionRecords = @(); ConfirmedFields = @(); SupplierVerificationKind = $false
    }
}

# 把一条落盘任务映射成证据对象。**每一种事实分别取证**（spec §4.2/§5.2）：
#   TodoPersisted        任务真的落盘了；
#   NotificationDelivered 通知真的投递成功（认领不能代替它，它也不能代替"已确认"）；
#   OwnerAccepted        人工认领了任务（**不等于**已经联系供应商）；
#   ContactedRecorded    有结构化 contacted 记录，或旧状态本身记录了 contacted/awaiting_supplier_reply
#                        （旧状态仅内部展示，不授权已联系；可信动作实现由 task_contracts 提供）；
#   SupplierReplyRecorded **只**由结构化 supplier_reply 记录授权；旧的非空 resolution 记为
#                        legacy-unverified，只可在内部展示，绝不授权"供应商已回复/已确认"；
#   ConfirmedFields      仍然有效的结构化确认字段（值/单位/范围/出处齐全）；
#   Deadline             只有真实确认过才写入。
function ConvertTo-HumanTaskEvidence($Task) {
    $ev = New-HumanTaskEvidence
    if (-not $Task) { return $ev }
    $ev.TaskId = [string]$Task.id
    $ev.TaskStatus = [string]$Task.status
    $ev.TaskKind = [string](Resolve-HumanTaskKind ([string]$Task.kind))
    $ev.TodoPersisted = $true
    $ev.TaskExists = $true
    $ev.EvidenceOrigin = 'task-readback'
    if ($Task.PSObject.Properties.Name -contains 'updatedAt') { $ev.UpdatedAt = [string]$Task.updatedAt }
    if ($Task.PSObject.Properties.Name -contains 'supplierKey') { $ev.SupplierIdentity = [string]$Task.supplierKey }
    if ($Task.PSObject.Properties.Name -contains 'supplierContact') { $ev.TaskSupplierContact = [string]$Task.supplierContact }
    $ev.HasUsableSupplierContact = (Get-SupplierIdentity $ev.TaskSupplierContact).Confidence -in @('full-contact','full-contact-extracted')
    $ev.SupplierVerificationKind = [bool](Test-SupplierVerificationKind ([string]$Task.kind))
    if ($Task.notification) {
        if ($Task.notification.PSObject.Properties.Name -contains 'delivered') { $ev.NotificationDelivered = [bool]$Task.notification.delivered }
        if ($Task.notification.PSObject.Properties.Name -contains 'attempts') { $ev.NotificationAttempts = [int]$Task.notification.attempts }
    }
    $ev.OwnerAccepted = [bool]$Task.ownerAccepted
    $records = @(Get-HumanTaskActionRecords $Task)
    $active = @($records | Where-Object { (Test-TrustedTaskAction $_ $Task) -and ([string](Get-HumanTaskProperty $_ 'status' 'active') -ne 'superseded') })
    $ev.ActionRecords = @($active)
    $contactedRecords = @($active | Where-Object { [string](Get-HumanTaskProperty $_ 'actionKind' '') -eq 'contacted' })
    $replyRecords = @($active | Where-Object { [string](Get-HumanTaskProperty $_ 'actionKind' '') -eq 'supplier_reply' })
    if ($contactedRecords.Count -gt 0) {
        $ev.ContactedRecorded = $true
        $ev.ContactedSource = 'action-record'
    }

    if ($replyRecords.Count -gt 0) {
        $ev.SupplierReplyRecorded = $true
        $ev.SupplierReplySource = 'action-record'
    }
    $res = ''
    if ($Task.PSObject.Properties.Name -contains 'resolution') { $res = [string]$Task.resolution }
    if (-not $ev.SupplierReplyRecorded -and $res -and $res.Trim()) {
        $ev.SupplierReplyLegacyUnverified = $true
        $ev.SupplierReplySource = 'legacy-unverified'
        $ev.ResolutionLegacy = $res
    }
    $ev.ConfirmedFields = @(Get-HumanTaskConfirmedFields $Task)
    $resolvedRecord = @($active | Where-Object { [string](Get-HumanTaskProperty $_ 'actionKind' '') -eq 'resolved' })
    $ev.ResolvedRecorded = ([string]$Task.status -eq 'resolved' -and @(Get-HumanTaskProperty $Task CompletionFactRefs @()).Count -gt 0 -and (Test-HumanTaskCompletion $Task).Ok)
    if (($Task.PSObject.Properties.Name -contains 'deadline') -and $Task.deadline) { $ev.Deadline = [string]$Task.deadline }
    $ev.KeyEvidenceFingerprint = [string](Get-HumanTaskKeyEvidenceFingerprint $Task $active)
    return $ev
}

# 对外表述与期限承诺所需的执行证据。只有**本买家**的未完成任务才算数。
# 返回对象可直接喂给 New-ActionEvidence -Values。
#   注意（F4 §6.1 第 2 条）：会话级列表/摘要可以继续用它，但**生产回复的措辞授权**
#   必须走 Get-ActionEvidenceForTask（按确切 TaskId 回读），不得在缺确切任务时退回"最近一条"。
function Get-ActionEvidenceForBuyer {
    param([string]$Buyer = '', [string]$Kind = '')
    $ev = New-HumanTaskEvidence
    $open = @(Get-HumanTaskList -Buyer $Buyer -OpenOnly)
    if ($Kind) { $open = @(Get-HumanTaskList -Buyer $Buyer -Kind $Kind -OpenOnly) }
    $ev.OpenTaskCount = $open.Count
    if ($open.Count -eq 0) { return $ev }
    # 取最近更新的一条作为本轮证据主体
    $task = @($open | Sort-Object -Property @{ Expression = { [string]$_.updatedAt } } | Select-Object -Last 1)[0]
    $ev = ConvertTo-HumanTaskEvidence $task
    $ev.OpenTaskCount = $open.Count
    return $ev
}

# [2026-10-05 第三轮 spec §4.1 第 3/4/5 条] 任务的触发消息是否仍在本轮会话里（"当前确属该流程"的证据）。
function Test-HumanTaskTriggerPresent($Task, $Conversation) {
    if (-not $Task -or -not $Conversation) { return $false }
    $msgs = @($Conversation.Messages)
    $tid = ''
    if ($Task.PSObject.Properties.Name -contains 'triggerMessageId') { $tid = [string]$Task.triggerMessageId }
    if ($tid) { foreach ($m in $msgs) { if ($m -and ([string]$m.StableId -eq $tid)) { return $true } } }
    $trig = ''
    if ($Task.PSObject.Properties.Name -contains 'lastTriggerMessage') { $trig = [string]$Task.lastTriggerMessage }
    if (-not $trig -and ($Task.PSObject.Properties.Name -contains 'firstTriggerMessage')) { $trig = [string]$Task.firstTriggerMessage }
    if (-not $trig) { return $false }
    $n = Get-HumanTaskEvidenceText $trig
    if ($n.Length -lt 12) { return $false }
    foreach ($m in $msgs) {
        if (-not $m) { continue }
        if ($m.Role -ne 'buyer' -and $m.Source -ne 'human') { continue }
        $mt = Get-HumanTaskEvidenceText ([string]$m.Orig)
        if ($mt -and ($mt.Contains($n) -or $n.Contains($mt))) { return $true }
    }
    return $false
}

# [2026-10-05 第三轮 spec §4.1 第 3/4/5 条] 相关既有任务的**明确选择**（由编排层调用，纯判据不自行读存储）。
#   选择优先级：本轮确切创建/更新结果（调用方直接用 TaskId） → 当前相关核实流程绑定的确切任务
#   （供应商身份匹配，或触发消息仍在本轮会话里） → 唯一一条 awaiting_contact 的"待供应商联系人"流程引用
#   （仅授权条件式下一步，unknown identity 不作通配符） → 多候选无明确关联 ⇒ ambiguous，
#   不取最近、不取列表第一条、不借另一供应商；无相关任务返回空。
function Get-ActionEvidenceForTask {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [string]$Kind = '',
        [string]$SupplierIdentity = ''
    )
    $ev = New-HumanTaskEvidence
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return $ev }
    $all = @(Get-HumanTaskList -Buyer $Buyer)
    $wantKind = ''
    if ($Kind) { $wantKind = Resolve-HumanTaskKind $Kind }
    foreach ($t in $all) {
        if ([string]$t.id -ne $TaskId) { continue }
        # 任务确实存在（即使类型/归属不匹配）也要如实报告存在性；不匹配 ⇒ 不给授权。
        $ev.TaskExists = $true
        $tk = ''
        if ($t.PSObject.Properties.Name -contains 'supplierKey') { $tk = [string](Get-TaskSupplierIdentity $t) }
        if ($wantKind -and (Resolve-HumanTaskKind ([string]$t.kind)) -ne $wantKind) { $ev.ExactTaskMatch = $false; return $ev }
        if ($SupplierIdentity -and $tk -ne [string]$SupplierIdentity) { $ev.ExactTaskMatch = $false; return $ev }
        if ((Test-SupplierVerificationKind $t.kind) -and -not (Test-TaskFlowAssociation $t $null)) { $ev.ExactTaskMatch=$false; return $ev }
        $ev = ConvertTo-HumanTaskEvidence $t
        $ev.RequiredContact = [string]$SupplierIdentity
        $ev.IdentityMatch = [bool]((-not $SupplierIdentity) -or ($tk -eq [string]$SupplierIdentity))
        $ev.EvidenceOrigin = 'exact-task-readback'
        # [spec §4.2] 确切回读契约：匹配结论、存在性、开放性与关键指纹都完整透传。
        $ev.ExactTaskMatch = (($ev.TaskKind -eq (Resolve-HumanTaskKind $Kind)) -or (-not $Kind)) -and [bool]$ev.IdentityMatch
        # 任务已关闭/结束 ⇒ 不再作为本轮授权依据（但"曾经存在的确切记录"仍然如实报告）。
        if ($script:HumanTaskOpenStatuses -notcontains [string]$t.status) {
            $ev.TodoPersisted = $false
            $ev.IsOpen = $false
            $ev.OpenTaskCount = 0
        } else {
            $ev.IsOpen = $true
            $ev.OpenTaskCount = 1
        }
        return $ev
    }
    return $ev
}

# =============================================================================================
# [2026-10-05 spec §3.2 第 3/4 条] 供应商核实任务的真实资料
#   任务必须保存**真实联系方式**及其来源、业务角色、缺失字段、资料快照、触发消息与身份、
#   创建/更新时间与状态。字面量占位符（旧实现的 'supplier-contact-provided'）不是联系人，
#   也不能当去重键：不同供应商必须得到不同的键，同一供应商必须稳定复用同一个键。
# =============================================================================================

# 从对话里取供应商联系方式：优先用统一事实模型（供应商角色字段），退回 HasSupplierContact 的文本。
# [F5 §5.1 第 5 条] 事实状态为 conflict（两个互相独立的值）时**不**从会话里挑第一个邮箱覆盖现有任务：
#   返回空联系人与显式冲突来源，由上层保持 awaiting_contact / 请求归属确认。
function Get-SupplierContactFromConversation($Conversation, $Facts = $null) {
    $contact = ''
    $source = ''
    $conflict = $false
    if ($Facts) {
        if ($Facts.PSObject.Properties.Name -contains 'CargoFacts' -and $Facts.CargoFacts -and $Facts.CargoFacts.ByKey) {
            $bk = $Facts.CargoFacts.ByKey
            if ($bk.ContainsKey('supplier_contact')) {
                $f = $bk['supplier_contact']
                if ($f -and [string]$f.Status -eq 'conflict') {
                    $conflict = $true
                    $source = 'cargo-facts:supplier_contact:conflict'
                } elseif ($f -and [string]$f.Status -eq 'provided' -and $f.Value) {
                    $contact = [string]$f.Value
                    $source = 'cargo-facts:supplier_contact'
                }
            }
        }
    }
    if ($conflict) { return [pscustomobject]@{ Contact = ''; Source = $source; Conflict = $true } }
    if($Facts -and $Facts.CargoFacts){return [pscustomobject]@{Contact=$contact;Source=$source;Conflict=$false}}
    if (-not $contact -and $Conversation) {
        foreach ($m in @($Conversation.Messages)) {
            if (-not $m) { continue }
            if ($m.Role -ne 'buyer' -and $m.Source -ne 'human') { continue }
            $t = [string]$m.Orig
            if (-not $t) { continue }
            if ($t -notmatch '(?i)\b(supplier|vendor|factory|proveedor|fornecedor|供应商|工厂)\b') { continue }
            $mm = [regex]::Match($t, '(?i)([\w\.\-\+]+@[\w\-]+\.[A-Za-z]{2,})')
            if ($mm.Success) { $contact = $mm.Groups[1].Value; $source = 'message-email'; break }
            $mp = [regex]::Match($t, '(?<![\d.])(\+?\d[\d\s\-\(\)]{6,}\d)(?![\d.])')
            if ($mp.Success) { $contact = ($mp.Groups[1].Value.Trim()); $source = 'message-phone'; break }
        }
    }
    return [pscustomobject]@{ Contact = $contact; Source = $source; Conflict = $false }
}

# =============================================================================================
# [2026-10-05 八项补修 F5 §5.1] 供应商身份按**实际联系人**保存。
#   旧实现把邮箱压成 email-domain:<域名>，于是 factory-one@mail.example.invalid 与
#   factory-two@mail.example.invalid 得到同一个键、互相覆盖（两个供应商被合并）。
#   现在：
#     * 已有明确供应商 ID 时优先用该 ID；
#     * 否则用**完整规范化邮箱**（lowercase、去首尾空白；绝不删账号部分、绝不按域名归并）；
#     * 否则用规范化电话号码（只保留数字；不猜补国家码、不按后缀合并）；
#     * 都没有才退回供应商名称键，最后才是"供应商身份未定"。
#   规范化只做无歧义处理；身份可信度随身份一起保存，供人工核对。
# =============================================================================================
function Get-SupplierIdentity {
    param([string]$SupplierContact = '', [string]$SupplierName = '', [string]$SupplierId = '')
    if (-not [string]::IsNullOrWhiteSpace($SupplierId)) {
        $sid = (([string]$SupplierId).Trim().ToLowerInvariant() -replace '\s+', ' ')
        if ($sid) { return [pscustomobject]@{ Key = ('supplier-id:' + $sid); Kind = 'supplier-id'; Value = $sid; Canonical = $sid; Confidence = 'explicit-id'; Raw = $SupplierContact } }
    }
    $raw = ''
    if ($SupplierContact) { $raw = ([string]$SupplierContact).Trim() }
    $c = $raw.ToLowerInvariant()
    if ($c) {
        $m = [regex]::Match($c, '^[a-z0-9\.\-\+_]+@[a-z0-9\-\.]+\.[a-z]{2,}$')
        if ($m.Success) { return [pscustomobject]@{ Key = ('email:' + $c); Kind = 'email'; Value = $c; Canonical = $c; Confidence = 'full-contact'; Raw = $raw } }
        if ($c -match '@') {
            # 形如 "Name <a@b.com>" / "a@b.com (purchasing)"：抽出唯一可判定的地址；抽不出就不当邮箱用。
            $m2 = [regex]::Match($c, '([a-z0-9\.\-\+_]+@[a-z0-9\-\.]+\.[a-z]{2,})')
            if ($m2.Success -and [regex]::Matches($c, '([a-z0-9\.\-\+_]+@[a-z0-9\-\.]+\.[a-z]{2,})').Count -eq 1) {
                $addr = [string]$m2.Groups[1].Value
                return [pscustomobject]@{ Key = ('email:' + $addr); Kind = 'email'; Value = $addr; Canonical = $addr; Confidence = 'full-contact-extracted'; Raw = $raw }
            }
            return [pscustomobject]@{ Key = ('contact:' + ($c -replace '\s+', '')); Kind = 'contact'; Value = $c; Canonical = ($c -replace '\s+', ''); Confidence = 'unparsed'; Raw = $raw }
        }
        $digits = ($c -replace '[^\d]', '')
        if ($digits.Length -ge 7) { return [pscustomobject]@{ Key = ('phone:' + $digits); Kind = 'phone'; Value = $digits; Canonical = $digits; Confidence = 'full-contact'; Raw = $raw } }
        return [pscustomobject]@{ Key = ('contact:' + ($c -replace '\s+', '')); Kind = 'contact'; Value = $c; Canonical = ($c -replace '\s+', ''); Confidence = 'unparsed'; Raw = $raw }
    }
    $n = ''
    if ($SupplierName) { $n = (([string]$SupplierName).ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() }
    if ($n) { return [pscustomobject]@{ Key = ('name:' + $n); Kind = 'name'; Value = $n; Canonical = $n; Confidence = 'name-only'; Raw = $raw } }
    return [pscustomobject]@{ Key = 'supplier-identity-unknown'; Kind = 'unknown'; Value = ''; Canonical = ''; Confidence = 'unknown'; Raw = $raw }
}

function Get-SupplierTaskKey([string]$SupplierContact, [string]$SupplierName = '', [string]$SupplierId = '') {
    return [string](Get-SupplierIdentity -SupplierContact $SupplierContact -SupplierName $SupplierName -SupplierId $SupplierId).Key
}

# 供应商核实任务的专用入口（spec §4.1 / §3.2）：
#   已有真实联系方式 ⇒ pending_human 且 supplierKey 来自该联系方式；
#   没有联系方式   ⇒ awaiting_contact，键为 'supplier-identity-unknown'；
#   同一会话/同一供应商/同类请求后续收到联系方式时更新**同一条**任务为 pending_human
#   （awaiting_contact 阶段所有供应商共用一个未知键，因此补充联系人不会留下悬挂重复任务）。
function Get-HumanTaskSummary {
    $store = Read-HumanTaskStore
    $all = @()
    if ($store.tasks) { $all = @($store.tasks) }
    $open = @($all | Where-Object { $script:HumanTaskOpenStatuses -contains [string]$_.status })
    return [pscustomobject]@{ Total = $all.Count; Open = $open.Count; Status = [string]$store.Status }
}

. (Join-Path $PSScriptRoot 'task_contracts.ps1')

function Add-HumanTaskNotification {
    param([string]$Id,[bool]$Delivered=$false,[string]$Detail='')
    $argsCopy=$PSBoundParameters
    Invoke-HumanTaskTransaction { Add-HumanTaskNotificationCore @argsCopy }
}
function Set-HumanTaskOwnerAccepted {
    param([string]$Id,[string]$Deadline='')
    $argsCopy=$PSBoundParameters
    Invoke-HumanTaskTransaction { Set-HumanTaskOwnerAcceptedCore @argsCopy }
}
