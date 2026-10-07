# scripts\investigate.ps1 - 来源与送达调查的操作入口（spec §6 / §11.2）
#
# 用途：列出/查看调查、认领、提交来源确认或送达证明、重试通知、查看审计。
# 边界：
#   * 只操作运行数据根下的 investigations.json / send_attempts.json / sent_records.json；
#   * 不发送客户消息；retry-notify 只走既有 dsh-im 通知出口，且离线/隔离上下文直接拒绝；
#   * 仅改状态、填写"已处理"或给出来源猜测都不足以关闭调查（Resolve-Investigation 按类型核验证据）；
#   * 人工确认来源只授权**确切事件**的来源更正，不制造机器人发送收据，也不解除其他人工暂停。
#
# 用法（与实际参数一致）：
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list -ActiveOnly -Buyer "Buyer A"
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action detail -Id inv-source_unverified-0123456789abcdef0123
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action claim -Id <id> -Operator "ops@example"
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-source -Id <id> -Class platform -Evidence "page:sender field read on the page at 2026-10-07 10:00"
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <id> -DeliveryState receipt_verified -ReceiptId <receiptId> -Evidence "receipt:read back from the same conversation"
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <id> -DeliveryState not_delivered_verified -Evidence "page:NOT_SENT reported by the send adapter"
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retry-notify -Id <id> [-DryRun]
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action sweep [-Max 5] [-DryRun]
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action audit -Id <id>
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retention [-Days 30] [-DryRun]
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action attempts [-Buyer "Buyer A"]
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action recover [-Buyer "Buyer A"] [-Max 5]
#
# 证据格式（复核 R5 起强制）：<source>:<detail>
#   * 来源类（confirm-source）：source ∈ page / api / field / receipt / sent-record / operator-observation，
#     detail ≥ 8 字符；"handled"/"已处理"这类没有出处的备注会被拒；更正只作用于确切事件身份。
#   * 送达类（confirm-delivery）：receipt_verified 必须在尝试存储或 sent_records 里找到**真实收据对象**
#     （收据号一致且正文哈希匹配）；not_delivered_verified 的 source ∈ page / adapter / send-result / dispatch。
#   * confirm-delivery 是可恢复的完整操作：核验证据 → 更新发送尝试 → 用真实写入器补齐 sent_records 与
#     去重账本 → 回读实际状态 → 才关闭调查；任一步失败都保留可重试状态（幂等）。
#
# 退出码：0 成功；1 操作被拒/失败（含证据不足）；2 用法或运行根错误。

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('list', 'detail', 'claim', 'confirm-source', 'confirm-delivery', 'retry-notify', 'sweep', 'audit', 'retention', 'attempts', 'recover')]
    [string]$Action,
    [string]$Id = '',
    [string]$Buyer = '',
    [string]$Kind = '',
    [string]$Status = '',
    [switch]$ActiveOnly,
    [string]$Operator = '',
    [ValidateSet('platform', 'project', 'human')][string]$Class = 'human',
    [string]$Evidence = '',
    [string]$EventRef = '',
    [ValidateSet('receipt_verified', 'not_delivered_verified')][string]$DeliveryState = 'receipt_verified',
    [string]$ReceiptId = '',
    [string]$Note = '',
    [int]$Max = 5,
    [int]$Days = 30,
    [switch]$DryRun,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
. (Join-Path $repo 'scripts\lib\state_store.ps1')
# [复核 R4] 收据与发送记录：confirm-delivery 要能核验**真实收据对象**，recover 要能真的写 sent_records。
. (Join-Path $repo 'scripts\lib\outbound_receipts.ps1')
. (Join-Path $repo 'scripts\lib\sent_records.ps1')
. (Join-Path $repo 'scripts\lib\investigations.ps1')
. (Join-Path $repo 'scripts\lib\msg_events.ps1')
. (Join-Path $repo 'scripts\lib\send_attempts.ps1')

function Write-Out([string]$Text) { Write-Output $Text }

function Show-Investigation($Record) {
    if (-not $Record) { Write-Out '(not found)'; return }
    Write-Out ('调查号    : ' + [string]$Record.id)
    Write-Out ('类型      : ' + [string]$Record.kind)
    Write-Out ('买家      : ' + [string]$Record.buyer)
    Write-Out ('事件引用  : ' + [string]$Record.eventRef + ' (质量 ' + [string]$Record.eventRefQuality + ')')
    if ($Record.attemptId) { Write-Out ('发送尝试  : ' + [string]$Record.attemptId) }
    Write-Out ('状态      : ' + [string]$Record.status)
    Write-Out ('首次观察  : ' + [string]$Record.firstSeenUtc)
    Write-Out ('末次观察  : ' + [string]$Record.lastSeenUtc)
    Write-Out ('固定截止  : ' + [string]$Record.deadlineUtc + ' (固定=' + [string]$Record.deadlineIsFixed + ')')
    Write-Out ('已通知    : ' + [string]$Record.notifiedOnce + ' / 末次结果 ' + [string]$Record.notifyResult)
    if (@($Record.evidenceRefs).Count -gt 0) { Write-Out ('证据引用  : ' + (@($Record.evidenceRefs) -join ' | ')) }
    if ($Record.operator) { Write-Out ('操作者    : ' + [string]$Record.operator + ' @ ' + [string]$Record.claimedAtUtc) }
    if ($Record.detail) { Write-Out ('说明      : ' + [string]$Record.detail) }
    if ($Record.resolution) { Write-Out ('解决依据  : ' + ($Record.resolution | ConvertTo-Json -Compress -Depth 6)) }
    if (@($Record.notifications).Count -gt 0) {
        Write-Out '通知记录  :'
        foreach ($n in @($Record.notifications)) {
            Write-Out ('  - ' + [string]$n.atUtc + ' ' + [string]$n.channel + ' => ' + [string]$n.result + ' ' + [string]$n.detail)
        }
    }
}

switch ($Action) {
    'list' {
        $items = @(Get-Investigations -Buyer $Buyer -Kind $Kind -Status $Status -ActiveOnly:$ActiveOnly)
        if ($AsJson) { Write-Out (($items | ConvertTo-Json -Depth 8)) ; break }
        if ($items.Count -eq 0) { Write-Out '(no investigations)'; break }
        Write-Out 'ID | KIND | STATUS | BUYER | EVENTREF | DEADLINE | NOTIFIED'
        foreach ($r in $items) {
            Write-Out (([string]$r.id) + ' | ' + [string]$r.kind + ' | ' + [string]$r.status + ' | ' + [string]$r.buyer + ' | ' + [string]$r.eventRef + ' | ' + [string]$r.deadlineUtc + ' | ' + [string]$r.notifiedOnce)
        }
        $stat = Get-InvestigationStatistics
        Write-Out ('TOTAL=' + $stat.Total + ' ACTIVE=' + $stat.Active)
    }
    'detail' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for detail'; exit 2 }
        Show-Investigation (Get-Investigation $Id)
    }
    'audit' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for audit'; exit 2 }
        $rec = Get-Investigation $Id
        if (-not $rec) { Write-Out 'ERROR: not found'; exit 1 }
        foreach ($a in @($rec.audit)) { Write-Out ([string]$a.atUtc + ' | ' + [string]$a.actor + ' | ' + [string]$a.action + ' | ' + [string]$a.detail) }
    }
    'claim' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for claim'; exit 2 }
        if (-not $Operator) { Write-Out 'ERROR: -Operator is required for claim'; exit 2 }
        $r = Set-InvestigationClaim -Id $Id -Operator $Operator
        if (-not $r.Ok) { Write-Out ('REJECTED: ' + $r.Error); exit 1 }
        Write-Out ('CLAIMED ' + $Id + ' by ' + $Operator + ' (claim is not delivery or source proof)')
    }
    'confirm-source' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for confirm-source'; exit 2 }
        $rec = Get-Investigation $Id
        if (-not $rec) { Write-Out 'ERROR: not found'; exit 1 }
        if (-not $EventRef) { $EventRef = [string]$rec.eventRef }
        # [复核 R5] 更正**先落盘**（在 Resolve-Investigation 内部完成），再关闭调查：
        #   更正写失败时调查保持可继续处理，不会出现"已关闭但更正未生效"。
        $r = Resolve-Investigation -Id $Id -By $(if ($Operator) { $Operator } else { $env:USERNAME }) -SourceClass $Class -Evidence $Evidence -EventRef $EventRef -Note $Note
        if (-not $r.Ok) { Write-Out ('REJECTED: ' + $r.Error); exit 1 }
        if (-not $r.CorrectionPersisted) { Write-Out ('CORRECTION-NOT-PERSISTED: ' + $Id); exit 1 }
        # 回读核验：更正表里必须真的能按确切事件读到这条更正。
        $back = Get-InvestigationSourceCorrections -Buyer ([string]$rec.buyer)
        if (-not $back.ContainsKey([string]$EventRef) -or [string]$back[[string]$EventRef].Class -ne [string]$Class) {
            Write-Out ('CORRECTION-READBACK-MISMATCH: ' + $Id + ' eventRef=' + $EventRef)
            exit 1
        }
        Write-Out ('RESOLVED ' + $Id + ' source=' + $Class + ' eventRef=' + $EventRef + ' correction=' + $(if ($r.AlreadyPresent) { 'already-present' } else { 'persisted' }))
    }
    'confirm-delivery' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for confirm-delivery'; exit 2 }
        # [复核 R4] confirm-delivery 是一条**可恢复的完整操作**：核验真实收据/未送达证据 →
        #   更新关联发送尝试 → 用真实写入器补齐 sent_records 与账本并回读 → 最后关闭调查。
        $r = Resolve-Investigation -Id $Id -By $(if ($Operator) { $Operator } else { $env:USERNAME }) -DeliveryState $DeliveryState -Evidence $Evidence -ReceiptId $ReceiptId -Note $Note
        if (-not $r.Ok) { Write-Out ('REJECTED: ' + $r.Error); exit 1 }
        $closure = $r.DeliveryClosure
        Write-Out ('RESOLVED ' + $Id + ' delivery=' + $DeliveryState + ' attempt=' + $(if ($closure) { [string]$closure.AttemptState } else { '' }))
    }
    'attempts' {
        # 发送尝试的只读视图：操作者据此判断"哪些尝试可能已经发出、必须先对账"。
        $items = @(Get-SendAttempts -Buyer $Buyer)
        if ($items.Count -eq 0) { Write-Out '(no send attempts)'; break }
        Write-Out 'ATTEMPTID | BUYER | STAGE | DELIVERY | SIDE-EFFECT | TRIGGER | RECEIPT'
        foreach ($a in $items) {
            Write-Out (([string]$a.attemptId) + ' | ' + [string]$a.buyer + ' | ' + [string]$a.stage + ' | ' + [string]$a.deliveryState + ' | ' +
                [string](Test-SendAttemptSideEffectPossible $a) + ' | ' + [string]$a.triggerRef + ' | ' + $(if ($a.receipt -and $a.receipt.Valid) { [string]$a.receipt.ReceiptId } else { '-' }))
        }
        Write-Out ('TOTAL=' + $items.Count + ' NEEDING-RECONCILIATION=' + @(Get-SendAttemptsNeedingReconciliation -Buyer $Buyer).Count)
    }
    'recover' {
        # [复核 R4] 生产恢复入口的 CLI 版本：对"已证明送达但持久化未完成"的尝试重跑真实写入并回读。
        $r = Invoke-SendAttemptPersistenceRecovery -Buyer $Buyer -Max $Max
        if (-not $r.Ok) { Write-Out ('RECOVERY-FAILED: ' + $r.Error); exit 1 }
        if (@($r.Results).Count -eq 0) { Write-Out '(nothing to recover)'; break }
        foreach ($x in @($r.Results)) {
            Write-Out (([string]$x.AttemptId) + ' buyer=' + [string]$x.Buyer + ' ok=' + [string]$x.Ok + ' sentRecord=' + [string]$x.SentRecord + ' ledger=' + [string]$x.Ledger + ' ' + [string]$x.Error)
        }
    }
    'retry-notify' {
        if (-not $Id) { Write-Out 'ERROR: -Id is required for retry-notify'; exit 2 }
        $r = Invoke-InvestigationNotification -Id $Id -OperatorRetry -DryRun:$DryRun
        if (-not $r.Ok) { Write-Out ('NOTIFY-FAILED: ' + $r.Error + ' result=' + $r.Result); exit 1 }
        Write-Out ('NOTIFY ' + $Id + ' result=' + $r.Result + ' sent=' + $r.Sent)
        if (-not $r.Sent -and -not $DryRun) { exit 1 }
    }
    'sweep' {
        $rs = @(Invoke-InvestigationNotificationSweep -Max $Max -DryRun:$DryRun)
        foreach ($r in $rs) { Write-Out ((($r.Record).id) + ' => ' + [string]$r.Result + ' sent=' + [string]$r.Sent + ' ' + [string]$r.Error) }
        if ($rs.Count -eq 0) { Write-Out '(nothing due)' }
    }
    'retention' {
        if ($DryRun) {
            $active = @(Get-Investigations -ActiveOnly).Count
            $all = @(Get-Investigations).Count
            Write-Out ('DRY-RUN retention: total=' + $all + ' active-kept=' + $active + ' closed-older-than-days=' + $Days + ' would-be-removed=' + ($all - $active))
        } else {
            $r = Invoke-InvestigationRetention -ClosedRetentionDays $Days
            if (-not $r.Ok) { Write-Out ('RETENTION-FAILED: ' + $r.Error); exit 1 }
            Write-Out ('RETENTION removed=' + $r.Removed + ' kept=' + $r.Kept + ' (active investigations and their evidence are never pruned)')
        }
    }
}
exit 0
