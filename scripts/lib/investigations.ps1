# lib\investigations.ps1 - 来源与送达调查（事件级幂等契约 + 独立提醒）
#
# 为什么独立于 task_contracts.ps1：供应商核实任务按买家/业务流合并、以 resolved 收尾，
#   不能承载"同一买家的不同事件必须分开调查"的语义（spec §6 第 1 条）。
#
# 契约要点：
#   * 幂等键 = 会话 + 调查类型 + 确切事件/尝试；不同事件不因同买家或同正文合并。
#   * 身份无法唯一建立时创建**显式歧义调查**，不伪造唯一关联。
#   * 先持久化调查，再独立于"买家回复成功"分支触发提醒；页面阻断时也能提醒。
#   * 一次成功提醒不再因重复扫描重发；投递失败/响应不明分开记录并支持人工显式重试。
#   * 通道失败不删除调查、不释放发送闸门、不写成已通知。
#   * 关闭调查必须按类型核验证据；仅改状态不得解除保护。
#
# 依赖：config.ps1 / paths.ps1（运行态路径）、state_store.ps1（原子读写）。

if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Write-JsonDocumentAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'state_store.ps1')
}

$script:InvestigationKinds = @('source_unverified', 'source_conflict', 'identity_ambiguous', 'receipt_pending', 'receipt_persistence_failed', 'delivery_ambiguous')
$script:InvestigationStoreVersion = 1
$script:InvestigationDefaultDeadlineMinutes = 5
$script:InvestigationClosedRetentionDays = 30

function Get-InvestigationKinds { return @($script:InvestigationKinds) }
function Get-InvestigationStoreVersion { return [int]$script:InvestigationStoreVersion }

# 恢复来源调查所需的类型（这些类型不允许"只有状态"就关闭）
function Test-InvestigationKindRequiresSourceEvidence([string]$Kind) {
    return ([string]$Kind -in @('source_unverified', 'source_conflict', 'identity_ambiguous'))
}
function Test-InvestigationKindRequiresDeliveryEvidence([string]$Kind) {
    return ([string]$Kind -in @('receipt_pending', 'receipt_persistence_failed', 'delivery_ambiguous'))
}

function Get-InvestigationFile {
    $p = ''
    try { $p = Get-SkillPath 'investigations' } catch { $p = '' }
    if ($p -and (Test-Path (Split-Path $p -Parent))) { return $p }
    return (Join-Path (Get-SkillPath 'data') 'investigations.json')
}

function Get-InvestigationBuyerKey([string]$Buyer) {
    if ([string]::IsNullOrWhiteSpace($Buyer)) { return '' }
    return ((([string]$Buyer) -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Get-InvestigationRefFingerprint([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return 'none' }
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# 幂等键：会话 + 类型 + 确切事件/尝试。身份无法唯一建立时使用显式歧义槽位。
function Get-InvestigationId {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$EventRef = '',
        [string]$AttemptId = '',
        [string]$AmbiguitySlot = ''
    )
    $key = Get-InvestigationBuyerKey $Buyer
    $ref = [string]$EventRef
    if (-not $ref) { $ref = [string]$AttemptId }
    $identity = 'event'
    $ambiguity = $false
    if (-not $ref) {
        $identity = 'explicit-ambiguity'
        $ambiguity = $true
        if (-not $AmbiguitySlot) { $AmbiguitySlot = 'unresolved' }
        $ref = 'ambiguous:' + [string]$AmbiguitySlot
    }
    $canon = ($key + [char]31 + [string]$Kind + [char]31 + $ref)
    $fp = (Get-InvestigationRefFingerprint $canon).Substring(0, 20)
    return ('inv-' + [string]$Kind + '-' + $fp)
}

function Read-InvestigationStore {
    $doc = Read-JsonDocument (Get-InvestigationFile)
    if ($doc.Status -eq 'valid' -and $doc.Data -and ($doc.Data.PSObject.Properties.Name -contains 'items')) {
        return $doc.Data
    }
    # 损坏的运行态不静默重建：返回空表 + 状态标记，调用方据此停止该会话而不是"删库恢复"。
    return [pscustomobject]@{ version = [int]$script:InvestigationStoreVersion; updatedAt = ''; items = [pscustomobject]@{}; __status = $doc.Status }
}

function Save-InvestigationStore($Store) {
    $w = Write-JsonDocumentAtomic -Path (Get-InvestigationFile) -Data $Store -Depth 12
    return [bool]$w.Ok
}

function ConvertTo-InvestigationTable($Object) {
    $t = @{}
    if (-not $Object) { return $t }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { $t[[string]$k] = $Object[$k] }
        return $t
    }
    foreach ($p in $Object.PSObject.Properties) { $t[[string]$p.Name] = $p.Value }
    return $t
}

# 统一构造存储载荷：来源更正表与调查项**互不覆盖**（普通调查写入不得丢掉更正表）。
function New-InvestigationStoreDoc($Items, [string]$NowText, $Corrections = $null) {
    if ($null -eq $Corrections) { $Corrections = [pscustomobject]@{} }
    return [pscustomobject]@{
        version    = [int]$script:InvestigationStoreVersion
        updatedAt  = [string]$NowText
        items      = $Items
        corrections = $Corrections
    }
}

function Get-InvestigationCorrectionsField($Store) {
    $c = Get-InvestigationStoreField $Store 'corrections'
    if ($null -eq $c) { return [pscustomobject]@{} }
    return $c
}

# 记录一次"确切事件"的来源更正。人工确认只授权该事件的来源更正，不制造机器人发送收据。
function Add-InvestigationSourceCorrection {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$EventRef,
        [Parameter(Mandatory = $true)][ValidateSet('platform', 'project', 'human')][string]$Class,
        [Parameter(Mandatory = $true)][string]$Evidence,
        [string]$By = '',
        [string]$InvestigationId = '',
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Error = ''; Correction = $null; AlreadyPresent = $false }
    $key = Get-InvestigationBuyerKey $Buyer
    if (-not $key) { $res.Error = 'no-buyer'; return $res }
    if (-not $EventRef) { $res.Error = 'exact-event-ref-required'; return $res }
    if ([string]::IsNullOrWhiteSpace($Evidence)) { $res.Error = 'evidence-provenance-required'; return $res }
    # 出处必须结构化（复核 R5）："handled"/"已处理"这类没有出处的备注不得写入更正表。
    $prov = Test-InvestigationStructuredEvidence -Evidence $Evidence
    if (-not $prov.Ok) { $res.Error = $prov.Reason; return $res }
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $corrections = ConvertTo-InvestigationTable (Get-InvestigationCorrectionsField $store)
    $list = New-Object System.Collections.ArrayList
    if ($corrections.ContainsKey($key)) { foreach ($c in @($corrections[$key])) { [void]$list.Add($c) } }
    # 幂等：同一确切事件 + 同一来源类别重复提交时不重复追加（复核 R5 的可恢复提交）。
    foreach ($c in @($list.ToArray())) {
        if ([string]$c.EventRef -eq [string]$EventRef -and [string]$c.Class -eq [string]$Class) {
            $res.Ok = $true
            $res.Correction = $c
            $res.AlreadyPresent = $true
            return $res
        }
    }
    $entry = [pscustomobject]@{
        EventRef        = [string]$EventRef
        Class           = [string]$Class
        Evidence        = [string]$Evidence
        By              = [string]$By
        AtUtc           = $NowUtc.ToUniversalTime().ToString('o')
        InvestigationId = [string]$InvestigationId
    }
    [void]$list.Add($entry)
    $corrections[$key] = @($list.ToArray())
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    $doc = New-InvestigationStoreDoc -Items $items -NowText ($NowUtc.ToUniversalTime().ToString('o')) -Corrections $corrections
    if (-not (Save-InvestigationStore $doc)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Correction = $entry
    return $res
}

# 该买家的确切事件更正表（键 = 事件身份，供门禁重算来源）。
function Get-InvestigationSourceCorrections([string]$Buyer) {
    $out = @{}
    $key = Get-InvestigationBuyerKey $Buyer
    if (-not $key) { return $out }
    $store = Read-InvestigationStore
    $corrections = ConvertTo-InvestigationTable (Get-InvestigationCorrectionsField $store)
    if (-not $corrections.ContainsKey($key)) { return $out }
    foreach ($c in @($corrections[$key])) {
        if (-not $c -or -not $c.EventRef) { continue }
        $out[[string]$c.EventRef] = [pscustomobject]@{ Class = [string]$c.Class; Evidence = [string]$c.Evidence }
    }
    return $out
}

function Add-InvestigationAuditRecord($Record, [string]$Action, [string]$Detail = '', [string]$Actor = 'system') {
    if (-not $Record) { return }
    $entry = [pscustomobject]@{
        atUtc = ([datetime]::UtcNow.ToString('o'))
        action = [string]$Action
        actor = [string]$Actor
        detail = [string]$Detail
    }
    $existing = @()
    if ($Record.PSObject.Properties.Name -contains 'audit') { $existing = @($Record.audit) }
    $Record.audit = @($existing + $entry)
}

# =============================================================================================
# 创建 / 更新
# =============================================================================================
# 返回 @{ Ok; Created; Updated; Record; Error }
function New-OrUpdate-Investigation {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$Kind,
        [string]$EventRef = '',
        [string]$EventRefQuality = '',
        [string]$AttemptId = '',
        [object[]]$EvidenceRefs = @(),
        [string]$AmbiguitySlot = '',
        [string]$Detail = '',
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$DeadlineMinutes = 0
    )
    $res = [pscustomobject]@{ Ok = $false; Created = $false; Updated = $false; Record = $null; Error = '' }
    $key = Get-InvestigationBuyerKey $Buyer
    if (-not $key) { $res.Error = 'no-buyer'; return $res }
    if ([string]$Kind -notin $script:InvestigationKinds) { $res.Error = 'unknown-kind'; return $res }
    if ($DeadlineMinutes -le 0) { $DeadlineMinutes = [int]$script:InvestigationDefaultDeadlineMinutes }
    $id = Get-InvestigationId -Buyer $Buyer -Kind $Kind -EventRef $EventRef -AttemptId $AttemptId -AmbiguitySlot $AmbiguitySlot
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    $nowText = $NowUtc.ToUniversalTime().ToString('o')
    $ref = [string]$EventRef
    if (-not $ref) { $ref = [string]$AttemptId }
    $identityQuality = [string]$EventRefQuality
    if (-not $ref) { $ref = 'ambiguous:' + $(if ($AmbiguitySlot) { [string]$AmbiguitySlot } else { 'unresolved' }); $identityQuality = 'ambiguous' }
    if ($items.ContainsKey($id)) {
        $rec = $items[$id]
        # 重复扫描：只更新证据引用与最后观察时间，**不重开**固定截止、不重发提醒。
        $rec.lastSeenUtc = $nowText
        if ($Detail) { $rec.detail = [string]$Detail }
        if (@($EvidenceRefs).Count -gt 0) {
            $merged = New-Object System.Collections.ArrayList
            foreach ($e in @($rec.evidenceRefs)) { [void]$merged.Add([string]$e) }
            foreach ($e in @($EvidenceRefs)) { if ($merged -notcontains [string]$e) { [void]$merged.Add([string]$e) } }
            $rec.evidenceRefs = @($merged.ToArray())
        }
        Add-InvestigationAuditRecord $rec 'rescan' 'same event re-observed; deadline unchanged' 'system'
        $items[$id] = $rec
        $res.Record = $rec
    } else {
        $rec = [pscustomobject]@{
            id                = $id
            kind              = [string]$Kind
            buyer             = [string]$Buyer
            buyerKey          = $key
            eventRef          = $ref
            eventRefQuality   = $(if ($identityQuality) { $identityQuality } else { 'unknown' })
            attemptId         = [string]$AttemptId
            detail            = [string]$Detail
            evidenceRefs      = @($EvidenceRefs | ForEach-Object { [string]$_ })
            firstSeenUtc      = $nowText
            lastSeenUtc       = $nowText
            deadlineUtc       = $NowUtc.ToUniversalTime().AddMinutes($DeadlineMinutes).ToString('o')
            deadlineIsFixed   = $true
            status            = 'open'
            nextCheckUtc      = ''
            notifications     = @()
            notifiedOnce      = $false
            notifiedAtUtc     = ''
            notifyResult      = ''
            # [复核 R6] 投递状态机：none（从未尝试）/ sent（真实 SENT_OK）/ unknown（响应不明）/ failed（明确失败）
            notifyState       = 'none'
            notifyAttempts    = 0
            operator          = ''
            claimedAtUtc      = ''
            resolution        = $null
            audit             = @()
            tombstone         = $false
        }
        Add-InvestigationAuditRecord $rec 'created' ('kind=' + [string]$Kind + ' ref=' + $ref) 'system'
        $items[$id] = $rec
        $res.Created = $true
        $res.Record = $rec
    }
    $out = New-InvestigationStoreDoc -Items $items -NowText $nowText -Corrections (Get-InvestigationCorrectionsField $store)
    if (-not (Save-InvestigationStore $out)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Updated = -not $res.Created
    return $res
}

function Get-InvestigationStoreField($Store, [string]$Name) {
    if (-not $Store) { return $null }
    if ($Store -is [System.Collections.IDictionary]) { if ($Store.Contains($Name)) { return $Store[$Name] }; return $null }
    if ($Store.PSObject.Properties.Name -contains $Name) { return $Store.$Name }
    return $null
}

function Get-Investigations {
    param(
        [string]$Buyer = '',
        [string]$Kind = '',
        [string]$Status = '',
        [switch]$ActiveOnly
    )
    $store = Read-InvestigationStore
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    $key = ''
    if ($Buyer) { $key = Get-InvestigationBuyerKey $Buyer }
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @($items.Keys)) {
        $rec = $items[$k]
        if (-not $rec) { continue }
        if ($key -and [string]$rec.buyerKey -ne $key) { continue }
        if ($Kind -and [string]$rec.kind -ne $Kind) { continue }
        if ($Status -and [string]$rec.status -ne $Status) { continue }
        if ($ActiveOnly -and ([string]$rec.status -in @('resolved', 'closed'))) { continue }
        [void]$out.Add($rec)
    }
    return @($out.ToArray() | Sort-Object -Property firstSeenUtc)
}

function Get-Investigation([string]$Id) {
    if (-not $Id) { return $null }
    foreach ($r in @(Get-Investigations)) { if ([string]$r.id -eq [string]$Id) { return $r } }
    return $null
}

# 该类型是否允许修正/确认：只有活跃记录可操作。
function Test-InvestigationActionable($Record) {
    if (-not $Record) { return $false }
    return (-not ([string]$Record.status -in @('resolved', 'closed')))
}

# =============================================================================================
# 通知：先持久化调查，再独立触发；失败不写已通知、不释放闸门
# =============================================================================================
# [复核 R6] 只有"从未尝试过投递"的调查才由周期扫描自动提醒。
#   一次投递尝试（无论结果如何）之后一律不再自动重发：
#     * 响应不明（UNKNOWN）**不能**当作未送达，通道可能已经送达；
#     * 明确失败也保留首次尝试与真实结果，由人工显式 retry-notify（单独审计）。
function Get-InvestigationNotifyState($Record) {
    if (-not $Record) { return 'none' }
    $field = Get-InvestigationStoreField $Record 'notifyState'
    if ($null -ne $field -and [string]$field) { return [string]$field }
    if ([bool]$Record.notifiedOnce) { return 'sent' }
    if ([int](Get-InvestigationStoreField $Record 'notifyAttempts') -gt 0) { return 'failed' }
    return 'none'
}

function Test-InvestigationNotificationDue($Record) {
    if (-not $Record) { return $false }
    if (-not (Test-InvestigationActionable $Record)) { return $false }
    if ([bool]$Record.notifiedOnce) { return $false }
    return ((Get-InvestigationNotifyState $Record) -eq 'none')
}

function Add-InvestigationNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Result,
        [string]$Detail = '',
        [string]$Channel = 'dsh-im',
        [switch]$OperatorRetry,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Record = $null; Error = '' }
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    if (-not $items.ContainsKey($Id)) { $res.Error = 'not-found'; return $res }
    $rec = $items[$Id]
    $nowText = $NowUtc.ToUniversalTime().ToString('o')
    $entry = [pscustomobject]@{
        atUtc = $nowText
        channel = [string]$Channel
        result = [string]$Result
        detail = [string]$Detail
        operatorRetry = [bool]$OperatorRetry
    }
    $rec.notifications = @($rec.notifications) + $entry
    $rec.notifyResult = [string]$Result
    if (-not ($rec.PSObject.Properties.Name -contains 'notifyState')) { $rec | Add-Member -NotePropertyName notifyState -NotePropertyValue 'none' -Force }
    if (-not ($rec.PSObject.Properties.Name -contains 'notifyAttempts')) { $rec | Add-Member -NotePropertyName notifyAttempts -NotePropertyValue 0 -Force }
    $rec.notifyAttempts = [int]$rec.notifyAttempts + 1
    # 只有真实 SENT_OK 才算已通知；探活/配置存在/操作者认领都不是投递证明。
    # [复核 R6] 其余结果分开记成 unknown / failed，并**不排下一次自动投递**：
    #   通道响应丢失不等于未送达，周期扫描重发会造成重复通知。
    if ([string]$Result -eq 'SENT_OK') {
        $rec.notifiedOnce = $true
        $rec.notifyState = 'sent'
        if ($rec.PSObject.Properties.Name -contains 'notifiedAtUtc') { $rec.notifiedAtUtc = $nowText }
        else { $rec | Add-Member -NotePropertyName notifiedAtUtc -NotePropertyValue $nowText -Force }
        $rec.nextCheckUtc = ''
    } else {
        $rec.notifiedOnce = $false
        if ([string]$Result -in @('UNKNOWN', 'NO_ADAPTER')) { $rec.notifyState = 'unknown' } else { $rec.notifyState = 'failed' }
        $rec.nextCheckUtc = ''
    }
    Add-InvestigationAuditRecord $rec 'notify' ([string]$Result + ' ' + [string]$Detail) $(if ($OperatorRetry) { 'operator' } else { 'system' })
    $items[$Id] = $rec
    $out = New-InvestigationStoreDoc -Items $items -NowText $nowText -Corrections (Get-InvestigationCorrectionsField $store)
    if (-not (Save-InvestigationStore $out)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Record = $rec
    return $res
}

function Format-InvestigationNotice($Record) {
    if (-not $Record) { return '' }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('[调查] ' + [string]$Record.kind + ' / ' + [string]$Record.buyer)
    [void]$lines.Add('调查号: ' + [string]$Record.id)
    [void]$lines.Add('事件引用: ' + [string]$Record.eventRef + '（身份质量 ' + [string]$Record.eventRefQuality + '）')
    if ($Record.attemptId) { [void]$lines.Add('发送尝试: ' + [string]$Record.attemptId) }
    [void]$lines.Add('首次观察: ' + [string]$Record.firstSeenUtc + ' / 固定截止: ' + [string]$Record.deadlineUtc)
    if ($Record.detail) { [void]$lines.Add('说明: ' + [string]$Record.detail) }
    if (@($Record.evidenceRefs).Count -gt 0) { [void]$lines.Add('证据: ' + (@($Record.evidenceRefs) -join ', ')) }
    [void]$lines.Add('处理入口: powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list')
    return ($lines -join [string][char]10)
}

# 投递一次（可注入适配器：测试用桩，生产用 Send-WecomMessage）。
#   $Sender: scriptblock { param($Text) return 'SENT_OK' | 'SEND_ERROR: ..' | ... }
function Invoke-InvestigationNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [scriptblock]$Sender = $null,
        [switch]$OperatorRetry,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [switch]$DryRun
    )
    $res = [pscustomobject]@{ Ok = $false; Sent = $false; Result = ''; Detail = ''; Record = $null; Error = '' }
    $rec = Get-Investigation $Id
    if (-not $rec) { $res.Error = 'not-found'; return $res }
    if (-not (Test-InvestigationActionable $rec)) { $res.Error = 'not-actionable'; $res.Record = $rec; return $res }
    if (-not $OperatorRetry) {
        if ([bool]$rec.notifiedOnce) {
            $res.Error = 'already-notified'
            $res.Result = [string]$rec.notifyResult
            $res.Record = $rec
            return $res
        }
        # [复核 R6] 已经投递过一次（失败/响应不明）就不再自动重发：必须人工显式 retry-notify。
        if ((Get-InvestigationNotifyState $rec) -ne 'none') {
            $res.Error = 'delivery-attempt-recorded-operator-retry-required'
            $res.Result = [string]$rec.notifyResult
            $res.Record = $rec
            return $res
        }
    }
    if ($DryRun) {
        $res.Ok = $true; $res.Record = $rec; $res.Result = 'DRY-RUN'; $res.Detail = 'no delivery attempted'
        return $res
    }
    if (-not $Sender) {
        if (Get-Command Send-WecomMessage -ErrorAction SilentlyContinue) { $Sender = { param($Text) Send-WecomMessage $Text } }
        else {
            $res.Error = 'no-notification-adapter'
            $res.Result = 'NO_ADAPTER'
            $null = Add-InvestigationNotification -Id $Id -Result 'NO_ADAPTER' -Detail 'no delivery adapter available' -OperatorRetry:$OperatorRetry -NowUtc $NowUtc
            return $res
        }
    }
    $text = Format-InvestigationNotice $rec
    $raw = ''
    try { $raw = [string](& $Sender $text) } catch { $raw = 'SEND_ERROR: ' + $_.Exception.Message }
    $res.Result = $raw
    # 通道返回不明（空串 / 未识别码）单独记为 UNKNOWN，绝不当作已通知。
    if ($raw -eq 'SENT_OK') { $res.Sent = $true }
    elseif (-not $raw) { $raw = 'UNKNOWN'; $res.Result = 'UNKNOWN' }
    $add = Add-InvestigationNotification -Id $Id -Result $raw -Detail 'adapter response' -OperatorRetry:$OperatorRetry -NowUtc $NowUtc
    if (-not $add.Ok) { $res.Error = $add.Error; return $res }
    $res.Ok = $true
    $res.Record = $add.Record
    return $res
}

# 扫描一遍待提醒的活跃调查（独立于"买家回复成功"分支，页面阻断时也能提醒）。
function Invoke-InvestigationNotificationSweep {
    param(
        [scriptblock]$Sender = $null,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$Max = 5,
        [switch]$DryRun
    )
    $out = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($rec in @(Get-Investigations -ActiveOnly)) {
        if ($n -ge $Max) { break }
        if (-not (Test-InvestigationNotificationDue $rec)) { continue }
        if ($rec.nextCheckUtc) {
            $due = [datetime]::MinValue
            if ([datetime]::TryParse([string]$rec.nextCheckUtc, [ref]$due) -and $due.ToUniversalTime() -gt $NowUtc.ToUniversalTime()) { continue }
        }
        $r = Invoke-InvestigationNotification -Id ([string]$rec.id) -Sender $Sender -NowUtc $NowUtc -DryRun:$DryRun
        [void]$out.Add($r)
        $n++
    }
    return @($out.ToArray())
}

# =============================================================================================
# 认领与关闭：关闭必须按类型核验证据，仅改状态一律拒绝
# =============================================================================================
function Set-InvestigationClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Operator,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Record = $null; Error = '' }
    if ([string]::IsNullOrWhiteSpace($Operator)) { $res.Error = 'no-operator'; return $res }
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    if (-not $items.ContainsKey($Id)) { $res.Error = 'not-found'; return $res }
    $rec = $items[$Id]
    $nowText = $NowUtc.ToUniversalTime().ToString('o')
    $rec.operator = [string]$Operator
    $rec.claimedAtUtc = $nowText
    if ([string]$rec.status -eq 'open') { $rec.status = 'investigating' }
    # 认领不是投递证明，也不是来源/送达证明：通知状态与闸门都不因认领改变。
    Add-InvestigationAuditRecord $rec 'claim' ('operator=' + [string]$Operator) ([string]$Operator)
    $items[$Id] = $rec
    $out = New-InvestigationStoreDoc -Items $items -NowText $nowText -Corrections (Get-InvestigationCorrectionsField $store)
    if (-not (Save-InvestigationStore $out)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Record = $rec
    return $res
}

# =============================================================================================
# [复核 R5] 有出处的结构化证据
#
#   为什么必须结构化：旧校验只要求"Evidence 非空"，于是 'handled' / '已处理' 这种**没有任何出处**
#   的备注也能关闭一条来源调查。现在要求 <source>:<detail>：
#     * source 必须来自许可集合（页面字段 / API / 收据 / 已确认发送记录 / 操作者现场观察…）；
#     * detail 至少 8 个字符，且不得只是一个状态词（handled/done/resolved/已处理…）。
#   这仍然不是"来源真值"本身：它只保证**提交者声明了出处**，真实独占性仍由 S0 证据决定。
# =============================================================================================
$script:InvestigationSourceEvidenceSources = @('page', 'api', 'field', 'receipt', 'sent-record', 'operator-observation')
$script:InvestigationNotDeliveredEvidenceSources = @('page', 'adapter', 'send-result', 'dispatch')
$script:InvestigationReceiptEvidenceSources = @('receipt', 'sent-record', 'page', 'operator-observation')
$script:InvestigationNonProvingNotes = @('handled', 'done', 'resolved', 'ok', 'yes', 'n/a', 'na', 'none', 'fixed', 'checked', 'processed', '已处理', '已解决', '已确认', '已关闭', '处理完毕')

function Test-InvestigationStructuredEvidence {
    param([string]$Evidence, [string[]]$AllowedSources = $null)
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; Source = ''; Detail = '' }
    if (-not $AllowedSources) { $AllowedSources = $script:InvestigationSourceEvidenceSources }
    $t = ([string]$Evidence).Trim()
    if (-not $t) { $r.Reason = 'evidence-provenance-required'; return $r }
    $idx = $t.IndexOf(':')
    if ($idx -le 0) { $r.Reason = 'evidence-provenance-required'; return $r }
    $src = $t.Substring(0, $idx).Trim().ToLowerInvariant()
    $detail = $t.Substring($idx + 1).Trim()
    $r.Source = $src; $r.Detail = $detail
    if ($AllowedSources -notcontains $src) { $r.Reason = 'evidence-source-not-attributable'; return $r }
    if ($detail.Length -lt 8) { $r.Reason = 'evidence-detail-too-short'; return $r }
    if ($script:InvestigationNonProvingNotes -contains $detail.ToLowerInvariant()) { $r.Reason = 'evidence-note-is-not-proof'; return $r }
    $r.Ok = $true
    return $r
}

function Test-InvestigationSourceEvidence {
    param([string]$Class, [string]$Evidence, [string]$EventRef, $Record)
    if ([string]$Class -notin @('platform', 'project', 'human')) { return [pscustomobject]@{ Ok = $false; Reason = 'source-class-must-be-platform-project-or-human' } }
    if ([string]::IsNullOrWhiteSpace($Evidence)) { return [pscustomobject]@{ Ok = $false; Reason = 'evidence-provenance-required' } }
    if (-not $EventRef) { return [pscustomobject]@{ Ok = $false; Reason = 'exact-event-ref-required' } }
    if ($Record -and ([string]$Record.eventRef -ne [string]$EventRef)) { return [pscustomobject]@{ Ok = $false; Reason = 'event-ref-does-not-match-investigation' } }
    # 出处必须结构化且可归因；"已处理"这类备注不构成证明。
    $provenance = Test-InvestigationStructuredEvidence -Evidence $Evidence
    if (-not $provenance.Ok) { return [pscustomobject]@{ Ok = $false; Reason = $provenance.Reason } }
    # 确切事件绑定：更正键必须是**构建出来的事件身份**，不是任意字符串。
    if ([string]$EventRef -notmatch '^(id:|cmp\||ambiguous:)') {
        return [pscustomobject]@{ Ok = $false; Reason = 'event-ref-is-not-an-event-identity' }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# [复核 R5] 送达证据必须绑定**真实收据对象**与**确切发送尝试**：
#   * ReceiptId 不是"填一个字符串"就算数：它必须能在尝试存储或 sent_records 里找到一条
#     通过 Test-ConfirmedOutboundReceipt 的真实收据，且该收据绑定的正是这条尝试的正文；
#   * 旧实现把 ReceiptId 与 AttemptId 做子串比较，于是"把 AttemptId 当收据号填"反而能通过。
function Test-InvestigationDeliveryEvidence {
    param([string]$DeliveryState, [string]$Evidence, [string]$ReceiptId, $Record)
    $r = [pscustomobject]@{ Ok = $false; Reason = ''; Receipt = $null; Attempt = $null }
    if ([string]$DeliveryState -notin @('receipt_verified', 'not_delivered_verified')) {
        $r.Reason = 'delivery-state-must-be-verified'; return $r
    }
    if ([string]::IsNullOrWhiteSpace($Evidence)) { $r.Reason = 'delivery-evidence-required'; return $r }
    if (-not $Record -or -not [string]$Record.attemptId) { $r.Reason = 'attempt-binding-required'; return $r }
    if (-not (Get-Command Get-SendAttempt -ErrorAction SilentlyContinue)) { $r.Reason = 'attempt-store-unavailable'; return $r }
    $attempt = Get-SendAttempt ([string]$Record.attemptId)
    if (-not $attempt) { $r.Reason = 'attempt-not-found'; return $r }
    $r.Attempt = $attempt
    $attemptText = [string](Get-SendAttemptRecordField $attempt 'text')
    if ([string]$DeliveryState -eq 'receipt_verified') {
        if ([string]::IsNullOrWhiteSpace($ReceiptId)) { $r.Reason = 'receipt-id-required-for-verified-delivery'; return $r }
        $prov = Test-InvestigationStructuredEvidence -Evidence $Evidence -AllowedSources $script:InvestigationReceiptEvidenceSources
        if (-not $prov.Ok) { $r.Reason = $prov.Reason; return $r }
        $receipt = $null
        if ($attempt.receipt -and $attempt.receipt.Valid -and ([string]$attempt.receipt.ReceiptId -eq [string]$ReceiptId)) { $receipt = $attempt.receipt }
        if (-not $receipt -and (Get-Command Get-SentRecords -ErrorAction SilentlyContinue)) {
            foreach ($s in @(Get-SentRecords -Buyer ([string]$attempt.buyer))) {
                if (-not $s.receipt -or -not $s.receipt.Valid) { continue }
                if ([string]$s.receipt.ReceiptId -ne [string]$ReceiptId) { continue }
                if (Get-Command Test-ConfirmedOutboundReceipt -ErrorAction SilentlyContinue) {
                    if (-not (Test-ConfirmedOutboundReceipt $s.receipt ([string]$attempt.buyer) $attemptText)) { continue }
                }
                $receipt = $s.receipt; break
            }
        }
        if (-not $receipt) { $r.Reason = 'receipt-object-not-found-for-this-attempt'; return $r }
        if ($attemptText -and [string]$receipt.TextHash -ne [string](Get-MessageBodyFingerprint $attemptText)) {
            $r.Reason = 'receipt-does-not-bind-this-attempt-text'; return $r
        }
        $r.Receipt = $receipt
        $r.Ok = $true
        return $r
    }
    # not_delivered_verified：只有**直接观察发送动作**的出处可用（页面/适配器/发送结果/派发阶段）。
    #   "消息不在当前窗口""会话不在待回复列表"单独不构成未送达证明（spec §4 末尾）。
    $prov = Test-InvestigationStructuredEvidence -Evidence $Evidence -AllowedSources $script:InvestigationNotDeliveredEvidenceSources
    if (-not $prov.Ok) { $r.Reason = $prov.Reason; return $r }
    if (Get-Command Test-SendAttemptSideEffectPossible -ErrorAction SilentlyContinue) {
        if (-not (Test-SendAttemptSideEffectPossible $attempt)) { $r.Reason = 'no-send-attempt-side-effect'; return $r }
    }
    $r.Ok = $true
    return $r
}

# [复核 R4] 送达确认的**可恢复提交**：先核验证据，再更新发送尝试与两段持久化并回读，
#   最后才关闭调查。任一步失败都保留可继续处理的状态（调查不关闭，重试幂等）。
#   返回 @{ Ok; Record; Error; AttemptState; Receipt }
function Complete-InvestigationDeliveryClosure {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$By,
        [string]$DeliveryState = '',
        [string]$Evidence = '',
        [string]$ReceiptId = '',
        [string]$Note = '',
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Record = $null; Error = ''; AttemptState = ''; Receipt = $null }
    $inv = Get-Investigation $Id
    if (-not $inv) { $res.Error = 'not-found'; return $res }
    if (-not (Test-InvestigationActionable $inv)) { $res.Error = 'already-closed'; return $res }
    $v = Test-InvestigationDeliveryEvidence -DeliveryState $DeliveryState -Evidence $Evidence -ReceiptId $ReceiptId -Record $inv
    if (-not $v.Ok) { $res.Error = $v.Reason; return $res }
    $attempt = $v.Attempt
    $attemptId = [string]$inv.attemptId
    if ([string]$DeliveryState -eq 'receipt_verified') {
        if (-not (Set-SendAttemptReceipt -AttemptId $attemptId -Receipt $v.Receipt -DeliveryState 'receipt_verified')) { $res.Error = 'attempt-store-write-failed'; return $res }
        $p = Complete-SendAttemptPersistence -AttemptId $attemptId -UseProductionWriters -Detail 'investigation-confirm-delivery'
        if (-not $p.Ok) { $res.Error = 'persistence-not-completed: ' + [string]$p.Error; return $res }
        $res.Receipt = $v.Receipt
    } else {
        if (-not (Set-SendAttemptStage -AttemptId $attemptId -Stage 'not-delivered-verified' -DeliveryState 'not_delivered_verified' -Detail ('evidence=' + [string]$Evidence))) {
            $res.Error = 'attempt-store-write-failed'; return $res
        }
    }
    # 回读实际状态：只有磁盘上的状态确实变成目标状态才算完成（不看内存对象）。
    $back = Get-SendAttempt $attemptId
    if (-not $back) { $res.Error = 'attempt-not-found-after-update'; return $res }
    if ([string]$back.deliveryState -ne [string]$DeliveryState) { $res.Error = 'attempt-state-readback-mismatch'; $res.AttemptState = [string]$back.deliveryState; return $res }
    if ([string]$DeliveryState -eq 'receipt_verified') {
        if ([string]$back.persistence.sentRecord -ne 'ok' -or [string]$back.persistence.ledger -ne 'ok') {
            $res.Error = 'persistence-readback-not-ok'; $res.AttemptState = [string]$back.deliveryState; return $res
        }
    }
    $res.AttemptState = [string]$back.deliveryState
    $res.Ok = $true
    return $res
}

# 关闭调查。source 类必须提交真实出处 + 确切事件映射；收据类必须提交有效送达/未送达证明。
function Resolve-Investigation {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$By,
        [string]$SourceClass = '',
        [string]$Evidence = '',
        [string]$EventRef = '',
        [string]$DeliveryState = '',
        [string]$ReceiptId = '',
        [string]$Note = '',
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Record = $null; Error = ''; Correction = $null; CorrectionPersisted = $false; DeliveryClosure = $null; AlreadyPresent = $false }
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    if (-not $items.ContainsKey($Id)) { $res.Error = 'not-found'; return $res }
    $rec = $items[$Id]
    if (-not (Test-InvestigationActionable $rec)) { $res.Error = 'already-closed'; return $res }
    if ([string]::IsNullOrWhiteSpace($By)) { $res.Error = 'operator-required'; return $res }
    $kind = [string]$rec.kind
    if (Test-InvestigationKindRequiresSourceEvidence $kind) {
        $v = Test-InvestigationSourceEvidence -Class $SourceClass -Evidence $Evidence -EventRef $EventRef -Record $rec
        if (-not $v.Ok) { $res.Error = $v.Reason; return $res }
        # [复核 R5] 更正**先落盘**再关闭：更正写失败时调查保持可继续处理（不得留下"已关闭但更正未生效"）。
        $corr = Add-InvestigationSourceCorrection -Buyer ([string]$rec.buyer) -EventRef $EventRef -Class $SourceClass -Evidence $Evidence -By $By -InvestigationId $Id -NowUtc $NowUtc
        if (-not $corr.Ok) { $res.Error = 'correction-not-persisted: ' + [string]$corr.Error; return $res }
        $res.Correction = $corr.Correction
        $res.CorrectionPersisted = $true
        $res.AlreadyPresent = [bool]$corr.AlreadyPresent
    } elseif (Test-InvestigationKindRequiresDeliveryEvidence $kind) {
        # [复核 R4] 证据核验 + 尝试状态更新 + 部分提交恢复 + 回读，全部在关闭之前完成。
        $closure = Complete-InvestigationDeliveryClosure -Id $Id -By $By -DeliveryState $DeliveryState -Evidence $Evidence -ReceiptId $ReceiptId -Note $Note -NowUtc $NowUtc
        $res.DeliveryClosure = $closure
        if (-not $closure.Ok) { $res.Error = $closure.Error; return $res }
    } else {
        $res.Error = 'unsupported-kind'
        return $res
    }
    # 重新读取存储：上面的更正落盘 / 尝试状态更新可能已经改写了文件，
    #   用旧的内存快照写回会把刚提交的更正抹掉（这正是"已关闭但更正未生效"的形态）。
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    if (-not $items.ContainsKey($Id)) { $res.Error = 'not-found-after-evidence'; return $res }
    $rec = $items[$Id]
    $nowText = $NowUtc.ToUniversalTime().ToString('o')
    $rec.status = 'resolved'
    $rec.operator = [string]$By
    $rec.resolution = [pscustomobject]@{
        atUtc = $nowText
        by = [string]$By
        sourceClass = [string]$SourceClass
        deliveryState = [string]$DeliveryState
        receiptId = [string]$ReceiptId
        evidence = [string]$Evidence
        eventRef = [string]$EventRef
        note = [string]$Note
    }
    Add-InvestigationAuditRecord $rec 'resolved' ('evidence=' + [string]$Evidence + ' note=' + [string]$Note) ([string]$By)
    $items[$Id] = $rec
    $out = New-InvestigationStoreDoc -Items $items -NowText $nowText -Corrections (Get-InvestigationCorrectionsField $store)
    if (-not (Save-InvestigationStore $out)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Record = $rec
    return $res
}

# =============================================================================================
# 发送闸门联动与保留策略
# =============================================================================================
# 与该买家**当前事件/尝试**相关的活跃调查：只有这些才阻断发送（久远记录不无限封锁）。
function Get-InvestigationSendBlock {
    param(
        [string]$Buyer,
        [string]$EventRef = '',
        [string]$AttemptId = ''
    )
    $blocking = New-Object System.Collections.ArrayList
    foreach ($rec in @(Get-Investigations -Buyer $Buyer -ActiveOnly)) {
        $kind = [string]$rec.kind
        if ($kind -in @('source_unverified', 'source_conflict', 'identity_ambiguous')) {
            if (-not $EventRef) { continue }
            if ([string]$rec.eventRef -ne [string]$EventRef) { continue }
        } elseif ($kind -in @('receipt_pending', 'receipt_persistence_failed', 'delivery_ambiguous')) {
            if (-not $AttemptId) { continue }
            if ([string]$rec.attemptId -ne [string]$AttemptId) { continue }
        } else { continue }
        [void]$blocking.Add($rec)
    }
    return [pscustomobject]@{
        Blocked = (@($blocking).Count -gt 0)
        Reasons = @($blocking | ForEach-Object { [string]$_.kind + ':' + [string]$_.id })
        Records = @($blocking.ToArray())
    }
}

# 保留策略：活跃调查与其证据不被"最近 N 条"剪枝丢掉；只有已关闭且超过保留期的记录才被清理。
function Invoke-InvestigationRetention {
    param(
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$ClosedRetentionDays = 0
    )
    if ($ClosedRetentionDays -le 0) { $ClosedRetentionDays = [int]$script:InvestigationClosedRetentionDays }
    $res = [pscustomobject]@{ Ok = $false; Removed = 0; Kept = 0; Error = '' }
    $store = Read-InvestigationStore
    $status = [string](Get-InvestigationStoreField $store '__status')
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'investigation-store-' + $status; return $res }
    $items = ConvertTo-InvestigationTable (Get-InvestigationStoreField $store 'items')
    $cut = $NowUtc.ToUniversalTime().AddDays(-1 * $ClosedRetentionDays)
    $kept = @{}
    $removed = 0
    foreach ($k in @($items.Keys)) {
        $rec = $items[$k]
        if (-not $rec) { $removed++; continue }
        if (Test-InvestigationActionable $rec) { $kept[$k] = $rec; continue }
        $closedAt = [datetime]::MinValue
        if ($rec.resolution -and $rec.resolution.atUtc) { [void][datetime]::TryParse([string]$rec.resolution.atUtc, [ref]$closedAt) }
        elseif ($rec.lastSeenUtc) { [void][datetime]::TryParse([string]$rec.lastSeenUtc, [ref]$closedAt) }
        if ($closedAt -eq [datetime]::MinValue -or $closedAt.ToUniversalTime() -lt $cut) { $removed++ } else { $kept[$k] = $rec }
    }
    if ($removed -eq 0) {
        # 没有可清理项时不写文件（避免每轮扫描都重写存储）。
        $res.Ok = $true
        $res.Removed = 0
        $res.Kept = $kept.Count
        return $res
    }
    $out = New-InvestigationStoreDoc -Items $kept -NowText ($NowUtc.ToUniversalTime().ToString('o')) -Corrections (Get-InvestigationCorrectionsField $store)
    if (-not (Save-InvestigationStore $out)) { $res.Error = 'investigation-store-write-failed'; return $res }
    $res.Ok = $true
    $res.Removed = $removed
    $res.Kept = $kept.Count
    return $res
}

function Get-InvestigationStatistics {
    $items = @(Get-Investigations)
    $byKind = @{}
    $active = 0
    foreach ($r in $items) {
        if (Test-InvestigationActionable $r) { $active++ }
        $k = [string]$r.kind
        if (-not $byKind.ContainsKey($k)) { $byKind[$k] = 0 }
        $byKind[$k] = [int]$byKind[$k] + 1
    }
    return [pscustomobject]@{ Total = $items.Count; Active = $active; ByKind = $byKind }
}
