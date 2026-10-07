# lib\send_attempts.ps1 - 持久化发送尝试、真实收据、部分提交恢复与待确认发送（spec §4）
#
# 送达状态（与来源分开建模，spec §3.3）：
#   not_attempted / pending_confirmation / receipt_verified / not_delivered_verified /
#   delivery_ambiguous / persistence_pending
#
# 铁律：
#   * 先持久化 AttemptId、买家触发引用、目标会话、完整正文/哈希、发送前快照证明与阶段，再执行输入/点击；
#     落盘失败时**不执行发送**（返回 Ok=$false 且 Reason='attempt-not-persisted'）。
#   * [复核 R2] 进入"即将产生外部发送副作用"之前必须再持久化一次阶段（dispatching）并回读核验：
#     没有可靠落盘的 dispatching 阶段就**不得**点击发送。因此重启后磁盘上的状态只有两种：
#       - stage=persisted / deliveryState=not_attempted ⇒ 可证明没有产生外部副作用；
#       - stage=dispatching 或更晚 ⇒ 可能已经发出，必须先对账，不得盲目重发。
#   * [复核 R2] 可恢复基线随尝试一起落盘（基线事件的键与签名），因此进程中断、重启之后
#     仍能在同口径下判断"我这条正文到底有没有作为新事件出现"。
#   * 收据要求"同口径前后快照里唯一新增事件 + 完整正文 + 会话身份"；无法证明时保持未确认，不伪造 ID。
#   * [复核 R3] 不重发保护是**会话级**的：同一会话里任何未确认/待持久化/歧义尝试都阻断新增发送，
#     去重键（触发）不同**不**构成放行理由；只有对账结论（已确认送达 / 可靠未送达）才解除。
#   * [复核 R8] "送达已证明"与"持久化全部完成"分开判断：receipt_verified 只说明收据有效；
#     只有 sent_records 与去重账本都写入并回读核验通过（persistence.sentRecord/ledger = ok）
#     才算闭环。任何有有效收据但账本未提交/未回读的尝试**保持会话保护**、留在活跃集合里、
#     不被保留上限淘汰，并由 Invoke-SendAttemptPersistenceRecovery（monitor 每轮扫描 / CLI recover）
#     幂等补齐；对账取得收据之后也立刻接通同样的真实提交，不再只写日志。
#   * sent_records 写入失败/返回 false：保留已送达证明 + persistence_pending，暂停该会话新增发送并生成调查，
#     绝不因落盘失败再次发送已送达正文。
#
# 依赖：config.ps1 / paths.ps1（运行态路径）、state_store.ps1（原子读写）；
#       msg_events.ps1（事件身份）、outbound_receipts.ps1 / sent_records.ps1（收据与账本）按需加载。

if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Write-JsonDocumentAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'state_store.ps1')
}
if (-not (Get-Command Get-MessageBodyFingerprint -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'msg_events.ps1')
}
# [复核 R4] 生产写入器（收据构造与 sent_records）必须真的可用：调用方（monitor / investigate.ps1）
#   只要加载了本文件，就应当拿到可用的 Add-SentRecord / Test-ConfirmedOutboundReceipt，
#   而不是在恢复路径里因为"函数不存在"退化成一个看不出原因的 false。
if (-not (Get-Command Test-ConfirmedOutboundReceipt -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'outbound_receipts.ps1')
}
if (-not (Get-Command Add-SentRecord -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'sent_records.ps1')
}

$script:SendAttemptStoreVersion = 1
$script:SendAttemptDeliveryStates = @('not_attempted', 'pending_confirmation', 'receipt_verified', 'not_delivered_verified', 'delivery_ambiguous', 'persistence_pending')
$script:SendAttemptMaxPerBuyer = 40
# 未确认状态：这些状态下的尝试阻断该会话的新增发送（与触发无关）。
$script:SendAttemptBlockingStates = @('pending_confirmation', 'persistence_pending', 'delivery_ambiguous')
# 可能已经产生外部发送副作用的阶段：重启后必须先对账。
$script:SendAttemptSideEffectStages = @('dispatching', 'dispatched', 'receipt-pending', 'sent-ok', 'unknown')

function Get-SendAttemptDeliveryStates { return @($script:SendAttemptDeliveryStates) }
function Get-SendAttemptStoreVersion { return [int]$script:SendAttemptStoreVersion }
function Get-SendAttemptBlockingStates { return @($script:SendAttemptBlockingStates) }

function Get-SendAttemptFile {
    $p = ''
    try { $p = Get-SkillPath 'send_attempts' } catch { $p = '' }
    if ($p -and (Test-Path (Split-Path $p -Parent))) { return $p }
    return (Join-Path (Get-SkillPath 'data') 'send_attempts.json')
}

function Get-SendAttemptBuyerKey([string]$Buyer) {
    if ([string]::IsNullOrWhiteSpace($Buyer)) { return '' }
    return ((([string]$Buyer) -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function New-SendAttemptId {
    return ('att-' + [guid]::NewGuid().ToString('N').Substring(0, 20))
}

function Read-SendAttemptStore {
    $doc = Read-JsonDocument (Get-SendAttemptFile)
    if ($doc.Status -eq 'valid' -and $doc.Data -and ($doc.Data.PSObject.Properties.Name -contains 'items')) { return $doc.Data }
    return [pscustomobject]@{ version = [int]$script:SendAttemptStoreVersion; updatedAt = ''; items = [pscustomobject]@{}; __status = $doc.Status }
}

function Save-SendAttemptStore($Store) {
    $w = Write-JsonDocumentAtomic -Path (Get-SendAttemptFile) -Data $Store -Depth 12
    return [bool]$w.Ok
}

function ConvertTo-SendAttemptTable($Object) {
    $t = @{}
    if (-not $Object) { return $t }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) { $t[[string]$k] = $Object[$k] }
        return $t
    }
    foreach ($prop in $Object.PSObject.Properties) { $t[[string]$prop.Name] = $prop.Value }
    return $t
}

function Add-SendAttemptAudit($Record, [string]$Action, [string]$Detail = '') {
    if (-not $Record) { return }
    $existing = @()
    if ($Record.PSObject.Properties.Name -contains 'audit') { $existing = @($Record.audit) }
    $Record.audit = @($existing + [pscustomobject]@{
        atUtc = ([datetime]::UtcNow.ToString('o'))
        action = [string]$Action
        detail = [string]$Detail
    })
}

function Get-SendAttemptRecordField($Record, [string]$Name) {
    if (-not $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) { if ($Record.Contains($Name)) { return $Record[$Name] }; return $null }
    if ($Record.PSObject.Properties.Name -contains $Name) { return $Record.$Name }
    return $null
}

# =============================================================================================
# [复核 R8] "送达已证明"与"持久化全部完成"是**两件事**，必须分开判断
#
#   为什么必须分开：Set-SendAttemptReceipt 把尝试写成 receipt_verified 时，persistence.sentRecord
#   与 persistence.ledger 仍是 pending —— 送达证明只在内存/尝试文件里，sent_records 与去重账本
#   （replied）里什么都没有。旧口径把 receipt_verified 直接当作 settled：
#     * Get-SendAttempts -ActiveOnly 排除它 ⇒ 恢复扫描永远看不到这条尝试；
#     * Remove-ExcessSendAttempts 把它当 settled ⇒ 保留上限可以把它淘汰掉；
#     * Test-SendAttemptBlocksResend 只认三个 blocking 状态 ⇒ 会话被提前解除保护。
#   于是"收据保存后、账本提交前中断"会留下一条既不会恢复、也不再保护会话的孤儿收据。
#   下面四个判据把两条结论彻底分开，并成为所有消费者的唯一口径。
# =============================================================================================

# 送达是否已被**有效收据**证明（与账本是否提交无关）。
function Test-SendAttemptHasValidReceipt($Record) {
    if (-not $Record) { return $false }
    $receipt = Get-SendAttemptRecordField $Record 'receipt'
    if (-not $receipt) { return $false }
    return [bool](Get-SendAttemptRecordField $receipt 'Valid')
}

# 两段持久化是否都**写入并回读核验**通过（sent_records + 去重账本）。
function Test-SendAttemptPersistenceComplete($Record) {
    if (-not $Record) { return $false }
    $p = Get-SendAttemptRecordField $Record 'persistence'
    if (-not $p) { return $false }
    return (([string](Get-SendAttemptRecordField $p 'sentRecord') -eq 'ok') -and ([string](Get-SendAttemptRecordField $p 'ledger') -eq 'ok'))
}

# 有收据、但两段持久化还没全部完成 ⇒ 必须继续恢复，不能算 settled、不能被淘汰。
function Test-SendAttemptPersistencePending($Record) {
    if (-not $Record) { return $false }
    if (-not (Test-SendAttemptHasValidReceipt $Record)) { return $false }
    return (-not (Test-SendAttemptPersistenceComplete $Record))
}

# 已闭环：不再是"活跃尝试"，可以不再阻断会话，也允许被保留上限淘汰。
#   * not_delivered_verified：可靠未送达证明，没有收据也没有账本；
#   * receipt_verified：**必须**同时具备有效收据与两段已核验的持久化结论。
function Test-SendAttemptSettled($Record) {
    if (-not $Record) { return $false }
    $st = [string](Get-SendAttemptRecordField $Record 'deliveryState')
    if ($st -eq 'not_delivered_verified') { return $true }
    if ($st -eq 'receipt_verified') { return ((Test-SendAttemptHasValidReceipt $Record) -and (Test-SendAttemptPersistenceComplete $Record)) }
    return $false
}

# 该尝试是否仍必须阻断同一会话的新增发送（会话级，与会话内的触发无关）。
function Test-SendAttemptBlocksConversation($Record) {
    if (-not $Record) { return $false }
    $st = [string](Get-SendAttemptRecordField $Record 'deliveryState')
    if ($st -in $script:SendAttemptBlockingStates) { return $true }
    if ($st -eq 'receipt_verified') { return (-not (Test-SendAttemptSettled $Record)) }
    return $false
}

# 阻断原因的**可读**形式：状态 + （收据已保存但账本未提交）这一特殊情况。
function Get-SendAttemptBlockReason($Record) {
    if (-not $Record) { return '' }
    $reason = [string](Get-SendAttemptRecordField $Record 'deliveryState')
    if (Test-SendAttemptPersistencePending $Record) { $reason = $reason + '/persistence-pending' }
    return $reason
}

# =============================================================================================
# 发送前快照证明 + 可恢复基线
#
# 基线是"发送前页面上的事件集合"的持久化形式：键（身份）与签名（无法建立身份的气泡）。
#   进程中断/重启后，用同一份共享抽取再读会话，即可判断基线之外是否新增了我们的正文。
# =============================================================================================
function New-SendAttemptBaselineEntry($Event) {
    if (-not $Event) { return $null }
    $key = ''
    if (Get-Command Get-OutboundEventKey -ErrorAction SilentlyContinue) { $key = [string](Get-OutboundEventKey $Event) }
    $sig = ''
    if (Get-Command Get-OutboundUnidentifiedSignature -ErrorAction SilentlyContinue) { $sig = [string](Get-OutboundUnidentifiedSignature $Event) }
    $body = ''
    if ($Event.PSObject.Properties.Name -contains 'BodyHash' -and $Event.BodyHash) { $body = [string]$Event.BodyHash }
    else { $body = [string](Get-MessageBodyFingerprint ([string]$Event.Text)) }
    $dir = ''
    if ($Event.PSObject.Properties.Name -contains 'Direction') { $dir = [string]$Event.Direction }
    elseif ($Event.PSObject.Properties.Name -contains 'IsMine') { $dir = $(if ([bool]$Event.IsMine) { 'out' } else { 'in' }) }
    $id = ''
    if ($Event.PSObject.Properties.Name -contains 'Identity') { $id = [string]$Event.Identity }
    $q = ''
    if ($Event.PSObject.Properties.Name -contains 'IdentityQuality') { $q = [string]$Event.IdentityQuality }
    return [pscustomobject]@{
        Key        = $key
        Sig        = $sig
        Identity   = $id
        Quality    = $q
        BodyHash   = $body
        Direction  = $dir
        MessageId  = [string]$Event.MessageId
        MessageTime = [string]$Event.MessageTime
    }
}

# 发送前快照证明：记录事件数、身份可用数与整表哈希，供发送后同口径比对与重启对账。
function Get-SendAttemptSnapshotProof {
    param([object[]]$Events = @(), [string]$CapturedAtUtc = '')
    $list = @($Events)
    $usable = 0
    $parts = New-Object System.Collections.ArrayList
    $baseline = New-Object System.Collections.ArrayList
    foreach ($e in $list) {
        $q = [string]$e.IdentityQuality
        if ($q -eq 'platform-id' -or $q -eq 'composite') { $usable++ }
        [void]$parts.Add([string]$e.Identity + '/' + [string]$e.BodyHash + '/' + [string]$e.MessageTime)
        $b = New-SendAttemptBaselineEntry $e
        if ($b) { [void]$baseline.Add($b) }
    }
    $joined = ($parts.ToArray() -join [string][char]30)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $quality = 'none'
    if ($list.Count -gt 0 -and $usable -eq $list.Count) { $quality = 'all-usable' }
    elseif ($usable -gt 0) { $quality = 'partial' }
    return [pscustomobject]@{
        CapturedAtUtc  = $(if ($CapturedAtUtc) { [string]$CapturedAtUtc } else { ([datetime]::UtcNow.ToString('o')) })
        EventCount     = $list.Count
        UsableCount    = $usable
        IdentityQuality = $quality
        SnapshotHash   = $hash
        RuleVersion    = $(if (Get-Command Get-MessageEventMetaVersion -ErrorAction SilentlyContinue) { [string](Get-MessageEventMetaVersion) } else { '' })
        Baseline       = @($baseline.ToArray())
    }
}

# =============================================================================================
# 发送前持久化（落盘失败 ⇒ 不执行发送）
# =============================================================================================
# 返回 @{ Ok; AttemptId; Record; Error }
function New-PersistedSendAttempt {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Buyer,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$DedupKey = '',
        [string]$TriggerRef = '',
        [string]$TriggerIdentity = '',
        [string]$ConvoKey = '',
        [object[]]$BeforeEvents = @(),
        [string]$SnapshotProofRef = '',
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; AttemptId = ''; Record = $null; Error = '' }
    $key = Get-SendAttemptBuyerKey $Buyer
    if (-not $key) { $res.Error = 'no-buyer'; return $res }
    if ([string]::IsNullOrWhiteSpace($Text)) { $res.Error = 'empty-text'; return $res }
    $store = Read-SendAttemptStore
    $status = [string]$(if ($store.PSObject.Properties.Name -contains '__status') { $store.__status } else { 'valid' })
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { $res.Error = 'send-attempt-store-' + $status; return $res }
    $proof = Get-SendAttemptSnapshotProof -Events $BeforeEvents
    $attemptId = New-SendAttemptId
    $nowText = $NowUtc.ToUniversalTime().ToString('o')
    $rec = [pscustomobject]@{
        attemptId     = $attemptId
        buyer         = [string]$Buyer
        buyerKey      = $key
        convoKey      = $(if ($ConvoKey) { [string]$ConvoKey } else { $key })
        triggerRef    = [string]$TriggerRef
        triggerIdentity = [string]$TriggerIdentity
        dedupKey      = [string]$DedupKey
        # [spec §4-3 / 复核 R2] 规格要求保存"待发送完整正文/哈希"：只存哈希与长度无法在重启后
        #   重新核对正文，也无法在恢复路径里幂等登记 sent_records（那里的收据校验要正文）。
        text          = [string]$Text
        textHash      = (Get-MessageBodyFingerprint $Text)
        textLength    = ([string]$Text).Length
        stage         = 'persisted'
        deliveryState = 'not_attempted'
        sideEffectAtUtc = ''
        beforeProof   = $proof
        snapshotProofRef = [string]$SnapshotProofRef
        receipt       = $null
        persistence   = [pscustomobject]@{ sentRecord = 'pending'; ledger = 'pending'; attempts = 0; lastError = '' }
        reconciliation = [pscustomobject]@{ attempts = 0; lastAtUtc = ''; outcome = ''; detail = '' }
        createdAtUtc  = $nowText
        updatedAtUtc  = $nowText
        audit         = @()
    }
    Add-SendAttemptAudit $rec 'persisted' ('dedupKey=' + [string]$DedupKey + ' trigger=' + [string]$TriggerRef + ' beforeQuality=' + [string]$proof.IdentityQuality + ' baseline=' + @($proof.Baseline).Count)
    $items = ConvertTo-SendAttemptTable $store.items
    $items[$attemptId] = $rec
    # 每买家保留上限：绝不淘汰仍处于未确认/持久化未完成状态的尝试。
    $items = Remove-ExcessSendAttempts $items $key
    $out = [pscustomobject]@{ version = [int]$script:SendAttemptStoreVersion; updatedAt = $nowText; items = $items }
    if (-not (Save-SendAttemptStore $out)) { $res.Error = 'attempt-not-persisted'; return $res }
    # 回读核验：落盘成功必须是"读回来确实存在且内容一致"，不是写入 API 返回 Ok 就算数。
    $back = Get-SendAttempt $attemptId
    if (-not $back -or [string]$back.textHash -ne [string]$rec.textHash -or [string]$back.stage -ne 'persisted') {
        $res.Error = 'attempt-persist-readback-mismatch'; return $res
    }
    $res.Ok = $true
    $res.AttemptId = $attemptId
    $res.Record = $back
    return $res
}

function Remove-ExcessSendAttempts($Items, [string]$BuyerKey) {
    # 用显式对象承载 (Key, Record)。旧写法是嵌套数组 + .Item1/.Item2 —— PowerShell 数组没有
    #   这两个成员，取值恒为空：$settled 永远是空集，保留上限**从来没有真正淘汰过任何尝试**。
    #   本轮一并修正，并保留原来的保守方向：只淘汰已闭环的尝试。
    $mine = New-Object System.Collections.ArrayList
    foreach ($k in @($Items.Keys)) {
        $r = $Items[$k]
        if (-not $r) { continue }
        if ([string]$r.buyerKey -eq $BuyerKey) { [void]$mine.Add([pscustomobject]@{ Key = [string]$k; Record = $r }) }
    }
    if ($mine.Count -le $script:SendAttemptMaxPerBuyer) { return $Items }
    # [复核 R8] 只允许淘汰**已闭环**的尝试：收据已保存但 sent_records/账本还没提交的尝试
    #   是唯一的送达证据，绝不能因为"每买家保留上限"被静默丢掉。
    $settled = @($mine | Where-Object { Test-SendAttemptSettled $_.Record } | Sort-Object { [string]$_.Record.createdAtUtc })
    $excess = $mine.Count - $script:SendAttemptMaxPerBuyer
    $i = 0
    while ($i -lt $excess -and $i -lt $settled.Count) {
        $Items.Remove([string]$settled[$i].Key) | Out-Null
        $i++
    }
    return $Items
}

function Get-SendAttempt([string]$AttemptId) {
    if (-not $AttemptId) { return $null }
    $store = Read-SendAttemptStore
    $items = ConvertTo-SendAttemptTable $store.items
    if ($items.ContainsKey($AttemptId)) { return $items[$AttemptId] }
    return $null
}

function Get-SendAttempts {
    param([string]$Buyer = '', [string]$DeliveryState = '', [switch]$ActiveOnly)
    $store = Read-SendAttemptStore
    $items = ConvertTo-SendAttemptTable $store.items
    $key = ''
    if ($Buyer) { $key = Get-SendAttemptBuyerKey $Buyer }
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @($items.Keys)) {
        $r = $items[$k]
        if (-not $r) { continue }
        if ($key -and [string]$r.buyerKey -ne $key) { continue }
        if ($DeliveryState -and [string]$r.deliveryState -ne $DeliveryState) { continue }
        # [复核 R8] 活跃 = **尚未闭环**：receipt_verified 只有在有效收据 + 两段持久化都回读通过之后
        #   才算 settled。收据已保存但账本未提交的尝试必须留在活跃集合里（否则恢复扫描看不到它）。
        if ($ActiveOnly -and (Test-SendAttemptSettled $r)) { continue }
        [void]$out.Add($r)
    }
    return @($out.ToArray() | Sort-Object -Property createdAtUtc)
}

function Save-SendAttemptRecord($Record) {
    if (-not $Record) { return $false }
    $store = Read-SendAttemptStore
    $status = [string]$(if ($store.PSObject.Properties.Name -contains '__status') { $store.__status } else { 'valid' })
    if ($status -in @('corrupt', 'empty', 'schema-invalid')) { return $false }
    $items = ConvertTo-SendAttemptTable $store.items
    $items[[string]$Record.attemptId] = $Record
    $out = [pscustomobject]@{ version = [int]$script:SendAttemptStoreVersion; updatedAt = ([datetime]::UtcNow.ToString('o')); items = $items }
    return (Save-SendAttemptStore $out)
}

# Replace the provisional monitor read with the exact target-bound snapshot used by the
# send adapter. This must finish before dispatching, so restart reconciliation shares it.
function Set-SendAttemptBeforeSnapshot {
    param([string]$AttemptId, [string]$Buyer, [string]$Text, [object[]]$BeforeEvents)
    $res = [pscustomobject]@{ Ok = $false; Error = ''; Record = $null }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    if ([string]$rec.stage -ne 'persisted' -or [string]$rec.deliveryState -ne 'not_attempted' -or
        [string]$rec.sideEffectAtUtc) { $res.Error = 'attempt-already-dispatching'; return $res }
    if ([string]$rec.buyerKey -ne (Get-SendAttemptBuyerKey $Buyer) -or
        [string]$rec.textHash -ne (Get-MessageBodyFingerprint $Text)) {
        $res.Error = 'attempt-target-or-text-mismatch'; return $res
    }
    if (@($BeforeEvents).Count -eq 0) { $res.Error = 'empty-before-snapshot'; return $res }
    $proof = Get-SendAttemptSnapshotProof -Events $BeforeEvents
    $rec.beforeProof = $proof
    $rec.updatedAtUtc = [datetime]::UtcNow.ToString('o')
    Add-SendAttemptAudit $rec 'before-snapshot-bound' ('events=' + $proof.EventCount + ' hash=' + $proof.SnapshotHash)
    if (-not (Save-SendAttemptRecord $rec)) { $res.Error = 'before-snapshot-write-failed'; return $res }
    $back = Get-SendAttempt $AttemptId
    if (-not $back -or [string]$back.stage -ne 'persisted' -or [string]$back.sideEffectAtUtc -or
        [string]$back.beforeProof.SnapshotHash -ne [string]$proof.SnapshotHash -or
        [int]$back.beforeProof.EventCount -ne [int]$proof.EventCount -or
        (ConvertTo-Json -InputObject @($back.beforeProof.Baseline) -Depth 8 -Compress) -ne
        (ConvertTo-Json -InputObject @($proof.Baseline) -Depth 8 -Compress)) {
        $res.Error = 'before-snapshot-readback-mismatch'; return $res
    }
    $res.Ok = $true; $res.Record = $back
    return $res
}

function Set-SendAttemptStage {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Detail = '',
        [string]$DeliveryState = ''
    )
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $false }
    $rec.stage = [string]$Stage
    if ($DeliveryState) { $rec.deliveryState = [string]$DeliveryState }
    $rec.updatedAtUtc = ([datetime]::UtcNow.ToString('o'))
    Add-SendAttemptAudit $rec ('stage:' + [string]$Stage) $Detail
    return (Save-SendAttemptRecord $rec)
}

# =============================================================================================
# [复核 R2] 外部副作用阶段：在点击/输入之前持久化并**回读核验**
#
#   返回 @{ Ok; Error; Record }
#   失败 ⇒ 调用方**不得**执行发送（宁可这一轮不发，也不能发出后没有任何本地证据）。
# =============================================================================================
function Start-SendAttemptSideEffect {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [string]$Detail = '',
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $res = [pscustomobject]@{ Ok = $false; Error = ''; Record = $null }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    if ([string]$rec.deliveryState -in @('receipt_verified', 'not_delivered_verified')) { $res.Error = 'attempt-already-settled'; return $res }
    $rec.stage = 'dispatching'
    $rec.deliveryState = 'pending_confirmation'
    $rec.sideEffectAtUtc = $NowUtc.ToUniversalTime().ToString('o')
    $rec.updatedAtUtc = $rec.sideEffectAtUtc
    Add-SendAttemptAudit $rec 'stage:dispatching' ('external side effect is about to be attempted ' + [string]$Detail)
    if (-not (Save-SendAttemptRecord $rec)) { $res.Error = 'attempt-store-write-failed'; return $res }
    $back = Get-SendAttempt $AttemptId
    if (-not $back -or [string]$back.stage -ne 'dispatching' -or [string]$back.deliveryState -ne 'pending_confirmation') {
        $res.Error = 'attempt-stage-readback-mismatch'
        return $res
    }
    $res.Ok = $true
    $res.Record = $back
    return $res
}

# 该尝试是否**可能**已经产生外部发送副作用（重启后必须先对账的那些）。
function Test-SendAttemptSideEffectPossible($Record) {
    if (-not $Record) { return $false }
    $stage = [string]$Record.stage
    if ([string]$Record.sideEffectAtUtc) { return $true }
    if ($stage -in @($script:SendAttemptSideEffectStages)) { return $true }
    if ($stage -like 'page:*' -or $stage -like 'failed:*') { return $true }
    return $false
}

# =============================================================================================
# 发送后确认（同口径前后快照）
# =============================================================================================
# 返回 @{ Confirmed; DeliveryState; Receipt; Error; NewEventCount; Ambiguity }
#
# 契约：BeforeEvents / AfterEvents 必须是 **Get-ConversationEventIndex 产出的事件对象**
#   （带 Identity 与 IdentityQuality）。缺少身份质量字段时按"无法证明"处理，不伪造收据。
function Confirm-SendAttemptFromSnapshots {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$Text,
        [object[]]$BeforeEvents = @(),
        [object[]]$AfterEvents = @(),
        [string]$ConvoKey = ''
    )
    $res = [pscustomobject]@{ Confirmed = $false; DeliveryState = 'delivery_ambiguous'; Receipt = $null; Error = ''; NewEventCount = 0; Ambiguity = @() }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    if ($ConvoKey -and [string]$rec.convoKey -and ([string]$rec.convoKey -ne [string]$ConvoKey)) {
        $res.Error = 'conversation-identity-mismatch'
        $res.Ambiguity = @('conversation-identity-mismatch')
        return $res
    }
    $before = @($BeforeEvents)
    $after = @($AfterEvents)
    $afterIds = @($after | ForEach-Object { [string]$_.Identity } | Where-Object { $_ })
    $beforeIds = @($before | ForEach-Object { [string]$_.Identity } | Where-Object { $_ })
    $newIdentified = @($afterIds | Where-Object { $beforeIds -notcontains $_ })
    $res.NewEventCount = $newIdentified.Count
    # 多候选/身份缺口：保持未确认，不伪造 ID 或收据。
    $unusableAfter = @($after | Where-Object { -not ([string]$_.IdentityQuality -in @('platform-id', 'composite')) })
    if ($unusableAfter.Count -gt 0) { $res.Ambiguity += 'after-snapshot-has-unidentified-events' }
    if ($newIdentified.Count -gt 1) { $res.Ambiguity += 'multiple-new-events' }
    if (@($res.Ambiguity).Count -gt 0) {
        $res.DeliveryState = 'delivery_ambiguous'
        $res.Error = 'cannot-prove-single-new-event'
        return $res
    }
    if (Get-Command New-ConfirmedOutboundReceipt -ErrorAction SilentlyContinue) {
        $receipt = New-ConfirmedOutboundReceipt -Buyer $Buyer -Text $Text -Before $before -After $after
        if ($receipt -and $receipt.Valid) {
            $res.Confirmed = $true
            $res.Receipt = $receipt
            $res.DeliveryState = 'receipt_verified'
            return $res
        }
        $res.Error = [string]$receipt.Error
    } else {
        $res.Error = 'no-receipt-adapter'
    }
    $res.DeliveryState = 'pending_confirmation'
    return $res
}

function Set-SendAttemptReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        $Receipt,
        [string]$DeliveryState = 'receipt_verified'
    )
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $false }
    $rec.receipt = $Receipt
    $rec.deliveryState = [string]$DeliveryState
    $rec.updatedAtUtc = ([datetime]::UtcNow.ToString('o'))
    Add-SendAttemptAudit $rec ('delivery:' + [string]$DeliveryState) $(if ($Receipt -and $Receipt.ReceiptId) { 'receipt=' + [string]$Receipt.ReceiptId } else { 'no-receipt' })
    return (Save-SendAttemptRecord $rec)
}

# =============================================================================================
# [复核 R2/R4] 重启对账：用**持久化基线** + 一次同口径重读判断这条正文是否已成为新事件
#
# $Events 必须是共享抽取器（Get-ConversationEventIndex）的产出。判定方向一律保守：
#   * 位置之外的**新增出站事件唯一且正文一致** ⇒ 有效收据（绑定确切事件，不伪造 ID）；
#   * 没有任何新增出站事件 ⇒ 只是"没有证明"，保持 pending_confirmation（"看不到"不等于未送达）；
#   * 新增出站事件多于一条，或出现无法建立身份的新出站气泡 ⇒ delivery_ambiguous；
#   * 会话身份不符 / 没有可恢复基线 ⇒ 拒绝给结论（Error），状态不变。
# =============================================================================================
function Resolve-SendAttemptFromEvents {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [object[]]$Events = @(),
        [string]$ConvoKey = ''
    )
    $res = [pscustomobject]@{ Ok = $false; DeliveryState = ''; Receipt = $null; Error = ''; NewEventCount = 0; Ambiguity = @(); Candidates = @() }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    if ($ConvoKey -and [string]$rec.convoKey -and ([string]$rec.convoKey -ne [string]$ConvoKey)) {
        $res.Error = 'conversation-identity-mismatch'; $res.Ambiguity = @('conversation-identity-mismatch'); return $res
    }
    $baseline = @()
    if ((Get-SendAttemptRecordField $rec 'beforeProof') -and ((Get-SendAttemptRecordField $rec 'beforeProof').PSObject.Properties.Name -contains 'Baseline')) {
        $baseline = @((Get-SendAttemptRecordField $rec 'beforeProof').Baseline)
    }
    if ($baseline.Count -eq 0 -and [int]$rec.beforeProof.EventCount -gt 0) {
        # 旧记录没有基线（升级前落盘的尝试）：不能凭空重建，明确拒绝给结论。
        $res.Error = 'no-recoverable-baseline'; return $res
    }
    $baseIds = @($baseline | ForEach-Object { [string]$_.Identity } | Where-Object { $_ })
    $baseKeys = @($baseline | ForEach-Object { [string]$_.Key } | Where-Object { $_ })
    $baseSigs = @{}
    foreach ($b in $baseline) {
        $s = [string]$b.Sig
        if (-not $s) { continue }
        if (-not $baseSigs.ContainsKey($s)) { $baseSigs[$s] = 0 }
        $baseSigs[$s] = [int]$baseSigs[$s] + 1
    }
    $outbound = @($Events | Where-Object { $_ -and -not $_.IsNoise -and -not $_.IsBuyer -and [string]$_.Direction -ne 'in' })
    $newOut = New-Object System.Collections.ArrayList
    $newUnidentified = New-Object System.Collections.ArrayList
    foreach ($e in $outbound) {
        $sig = ''
        if (Get-Command Get-OutboundUnidentifiedSignature -ErrorAction SilentlyContinue) { $sig = [string](Get-OutboundUnidentifiedSignature $e) }
        if ($sig) {
            if ($baseSigs.ContainsKey($sig) -and [int]$baseSigs[$sig] -gt 0) { $baseSigs[$sig] = [int]$baseSigs[$sig] - 1; continue }
            [void]$newUnidentified.Add($sig); continue
        }
        $id = [string]$e.Identity
        if ($id -and ($baseIds -contains $id)) { continue }
        $key = ''
        if (Get-Command Get-OutboundEventKey -ErrorAction SilentlyContinue) { $key = [string](Get-OutboundEventKey $e) }
        if ($key -and ($baseKeys -contains $key)) { continue }
        if (-not $id -and -not $key) { [void]$newUnidentified.Add('no-identity'); continue }
        [void]$newOut.Add($e)
    }
    $res.NewEventCount = @($newOut).Count
    if (@($newUnidentified).Count -gt 0) {
        $res.DeliveryState = 'delivery_ambiguous'
        $res.Ambiguity = @($newUnidentified.ToArray())
        $res.Error = 'new-unidentified-outbound-event'
        return $res
    }
    if (@($newOut).Count -gt 1) {
        $res.DeliveryState = 'delivery_ambiguous'
        $res.Ambiguity = @('multiple-new-outbound-events')
        $res.Error = 'multiple-new-outbound-events'
        return $res
    }
    if (@($newOut).Count -eq 0) {
        $res.DeliveryState = 'pending_confirmation'
        $res.Error = 'no-new-outbound-event'
        return $res
    }
    $e = $newOut[0]
    $res.Candidates = @($e)
    if ([string]$e.BodyHash -ne [string]$rec.textHash) {
        $res.DeliveryState = 'pending_confirmation'
        $res.Error = 'new-event-body-does-not-match-this-attempt'
        return $res
    }
    $key2 = ''
    if (Get-Command Get-OutboundEventKey -ErrorAction SilentlyContinue) { $key2 = [string](Get-OutboundEventKey $e) }
    if (-not $key2 -or -not [string]$e.Identity) {
        $res.DeliveryState = 'delivery_ambiguous'
        $res.Ambiguity = @('new-event-identity-not-usable')
        $res.Error = 'new-event-identity-not-usable'
        return $res
    }
    # 有效收据：绑定**确切的新增事件**；BeforeKeys 取持久化基线，AfterKeys 在其上追加该事件键。
    $receipt = [pscustomobject]@{
        Valid = $true
        BuyerKey = (Get-SentRecordKey ([string]$rec.buyer))
        ReceiptId = [guid]::NewGuid().ToString('N')
        MessageId = [string]$e.MessageId
        MessageTime = [string]$e.MessageTime
        TimePrecision = [string]$e.TimePrecision
        TextHash = [string](Get-MessageLineFingerprint (Get-SentRecordNormText ([string]$rec.text)))
        BeforeKeys = @($baseKeys)
        AfterKeys = @($baseKeys + @($key2))
        ConfirmationType = 'recovered-from-persisted-baseline'
        Error = ''
        UnidentifiedNew = @()
    }
    $res.Ok = $true
    $res.Receipt = $receipt
    $res.DeliveryState = 'receipt_verified'
    return $res
}

# 对账一次并把结论落盘（收据、状态、审计），随后**接通实际提交**。
#
#   [复核 R8] 送达被证明 ≠ 持久化完成：旧实现在保存 receipt_verified 之后立即返回，两份账本
#   一份都没提交，而恢复扫描又只处理 persistence_pending ⇒ 这条尝试永远不会补齐，
#   来源也就无法用发送记录纠正。现在对账成功之后立刻用**生产写入器**提交 sent_records 与
#   去重账本并回读核验；任一段失败即保持 persistence_pending + 会话保护 + 显式调查。
#
#   返回 @{ Ok; Applied; DeliveryState; Receipt; Error; InvestigationId; Decision;
#            PersistenceOk; PersistenceComplete; SentRecord; Ledger; PersistError; Blocked }
function Invoke-SendAttemptReconciliation {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [object[]]$Events = @(),
        [string]$ConvoKey = ''
    )
    $res = [pscustomobject]@{
        Ok = $false; Applied = $false; DeliveryState = ''; Receipt = $null; Error = ''; InvestigationId = ''; Decision = $null
        PersistenceOk = $false; PersistenceComplete = $false; SentRecord = ''; Ledger = ''; PersistError = ''; Blocked = $false
    }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    $d = Resolve-SendAttemptFromEvents -AttemptId $AttemptId -Events $Events -ConvoKey $ConvoKey
    $res.Decision = $d
    $res.DeliveryState = [string]$d.DeliveryState
    $res.Receipt = $d.Receipt
    if ($d.Ok -and $d.DeliveryState -eq 'receipt_verified') {
        if (-not (Set-SendAttemptReceipt -AttemptId $AttemptId -Receipt $d.Receipt -DeliveryState 'receipt_verified')) { $res.Error = 'attempt-store-write-failed'; return $res }
        $res.Ok = $true; $res.Applied = $true
        # ---- [复核 R8] 接通实际提交：取得收据之后必须真的把两段账本写进去并回读 ----
        $p = $null
        try {
            $p = Complete-SendAttemptPersistence -AttemptId $AttemptId -UseProductionWriters -Detail 'reconcile'
        } catch {
            $p = $null
            $res.PersistError = 'persistence-writer-exception: ' + $_.Exception.Message
        }
        if ($p) {
            $res.PersistenceOk = [bool]$p.Ok
            $res.SentRecord = [string]$p.SentRecord
            $res.Ledger = [string]$p.Ledger
            if (-not $res.PersistError) { $res.PersistError = [string]$p.Error }
            if ($p.InvestigationId) { $res.InvestigationId = [string]$p.InvestigationId }
        } elseif (-not $res.PersistError) {
            $res.PersistError = 'persistence-not-attempted'
        }
        # 以**磁盘上的实际状态**（而不是内存结论）汇报持久化与闸门结论。
        $back = Get-SendAttempt $AttemptId
        $res.PersistenceComplete = (Test-SendAttemptPersistenceComplete $back)
        $res.Blocked = (Test-SendAttemptBlocksConversation $back)
        if (-not $back) { $res.Error = 'attempt-vanished-after-reconciliation' }
        return $res
    }
    if ($d.DeliveryState -eq 'delivery_ambiguous') {
        if (-not (Set-SendAttemptStage -AttemptId $AttemptId -Stage 'reconcile:ambiguous' -DeliveryState 'delivery_ambiguous' -Detail ([string]$d.Error))) { $res.Error = 'attempt-store-write-failed'; return $res }
        if (Get-Command New-OrUpdate-Investigation -ErrorAction SilentlyContinue) {
            $inv = New-OrUpdate-Investigation -Buyer ([string]$rec.buyer) -Kind 'delivery_ambiguous' -AttemptId $AttemptId -EventRefQuality 'attempt' -EvidenceRefs @('reconcile:' + [string]$d.Error) -Detail 'restart reconciliation could not prove a single new outbound event'
            if ($inv.Ok) { $res.InvestigationId = [string]$inv.Record.id }
        }
        $res.Ok = $true; $res.Applied = $true
        return $res
    }
    # 没有结论：只记录一次对账审计，状态保持 pending_confirmation。
    $res.Error = [string]$d.Error
    $rec = Get-SendAttempt $AttemptId
    if ($rec) {
        $recon = Get-SendAttemptRecordField $rec 'reconciliation'
        if (-not $recon) { $rec | Add-Member -NotePropertyName reconciliation -NotePropertyValue ([pscustomobject]@{ attempts = 0; lastAtUtc = ''; outcome = ''; detail = '' }) -Force; $recon = $rec.reconciliation }
        $recon.attempts = [int]$recon.attempts + 1
        $recon.lastAtUtc = ([datetime]::UtcNow.ToString('o'))
        $recon.outcome = 'unverified'
        $recon.detail = [string]$d.Error
        Add-SendAttemptAudit $rec 'reconcile:unverified' ([string]$d.Error)
        [void](Save-SendAttemptRecord $rec)
    }
    return $res
}

# =============================================================================================
# 账本写入（恢复路径的真实写入器；只有**回读核验通过**才返回 $true）
# =============================================================================================
function Get-SendAttemptLedgerFile {
    try { return (Get-SkillPath 'state') } catch { return '' }
}

function Set-SendAttemptLedgerEntry {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Buyer,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DedupKey
    )
    $key = Get-SendAttemptBuyerKey $Buyer
    if (-not $key -or -not $DedupKey) { return $false }
    $path = Get-SendAttemptLedgerFile
    if (-not $path) { return $false }
    $doc = Read-JsonDocument $path
    # 与 monitor 的 Set-StateHash 同一保守方向：账本缺失/损坏/结构不合法一律**拒绝写入**，
    #   绝不用"新建空账本"的方式覆盖历史（那会直接导致重发）。
    if ($doc.Status -ne 'valid' -or -not $doc.Data) { return $false }
    if (-not ($doc.Data.PSObject.Properties.Name -contains 'replied')) { return $false }
    $rep = @{}
    $src = $doc.Data.replied
    if ($src -is [System.Collections.IDictionary]) { foreach ($k in $src.Keys) { $rep[[string]$k] = $src[$k] } }
    else { foreach ($p in $src.PSObject.Properties) { $rep[$p.Name] = $p.Value } }
    $rep[$key] = [string]$DedupKey
    $out = [pscustomobject]@{ replied = $rep }
    $w = Write-JsonDocumentAtomic -Path $path -Data $out -Depth 5
    if (-not $w.Ok) { return $false }
    $back = Read-JsonDocument $path
    if ($back.Status -ne 'valid' -or -not $back.Data) { return $false }
    # 逐属性比较：账本键可能含空格/特殊字符，动态成员访问会静默取不到值（既有教训）。
    $got = ''
    if ($back.Data.PSObject.Properties.Name -contains 'replied') {
        $r2 = $back.Data.replied
        if ($r2 -is [System.Collections.IDictionary]) { if ($r2.Contains($key)) { $got = [string]$r2[$key] } }
        elseif ($r2) { foreach ($p in $r2.PSObject.Properties) { if ([string]$p.Name -eq $key) { $got = [string]$p.Value } } }
    }
    return ($got -eq [string]$DedupKey)
}

# 生产写入器（真实落盘 + 回读核验）。
#   刻意写成**函数**而不是 GetNewClosure 闭包：闭包会新建动态模块，在里面看不到调用方
#   dot-source 进来的命令，于是"写入器存在"会退化成 'sent-record-writer-exception'。
function Invoke-SendAttemptSentRecordWrite {
    param([Parameter(Mandatory = $true)][string]$AttemptId)
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $false }
    $text = [string](Get-SendAttemptRecordField $rec 'text')
    $receipt = $rec.receipt
    if (-not $text -or -not $receipt -or -not $receipt.Valid) { return $false }
    if (-not (Get-Command Add-SentRecord -ErrorAction SilentlyContinue)) { return $false }
    $ok = [bool](Add-SentRecord -Buyer ([string]$rec.buyer) -Text $text -SentAt (([datetime]::UtcNow).ToString('o')) -Source 'recovery' -Receipt $receipt)
    if (-not $ok) { return $false }
    # 回读核验：这条收据必须真的能在 sent_records 里按收据号找到。
    foreach ($r in @(Get-SentRecords -Buyer ([string]$rec.buyer))) {
        if ($r.receipt -and [string]$r.receipt.ReceiptId -eq [string]$receipt.ReceiptId) { return $true }
    }
    return $false
}

function Invoke-SendAttemptLedgerWrite {
    param([Parameter(Mandatory = $true)][string]$AttemptId)
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $false }
    return [bool](Set-SendAttemptLedgerEntry -Buyer ([string]$rec.buyer) -DedupKey ([string]$rec.dedupKey))
}

# 生产写入器的**描述**（供调用方核对绑定的是哪条尝试、哪段正文、哪个收据）。
#   真实写入由 Invoke-SendAttemptSentRecordWrite / Invoke-SendAttemptLedgerWrite 完成。
function Get-SendAttemptProductionWriters([string]$AttemptId) {
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $null }
    return [pscustomobject]@{
        AttemptId = [string]$rec.attemptId
        Buyer = [string]$rec.buyer
        Text = [string](Get-SendAttemptRecordField $rec 'text')
        Receipt = $rec.receipt
        DedupKey = [string]$rec.dedupKey
        SentRecordWriter = 'Invoke-SendAttemptSentRecordWrite'
        LedgerWriter = 'Invoke-SendAttemptLedgerWrite'
    }
}

# =============================================================================================
# 部分提交恢复：收据有效但账本/发送记录写入失败
# =============================================================================================
# 返回 @{ Ok; SentRecord; Ledger; DeliveryState; Blocked; Error; InvestigationId }
#   * $SentRecordWriter / $LedgerWriter 是注入的写入器（生产传 Add-SentRecord / 账本写入包装），
#     返回 $true 表示确实落盘成功；返回 $false 或抛异常都算失败。
#   * 任一失败：保留已送达证明、置 persistence_pending、暂停该会话新增发送并生成调查；
#     绝不因落盘失败再次发送已送达正文。
function Complete-SendAttemptPersistence {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [scriptblock]$SentRecordWriter = $null,
        [scriptblock]$LedgerWriter = $null,
        # 生产恢复入口用它：真实写入器在本库内执行（见 Invoke-SendAttemptSentRecordWrite 的说明）。
        [switch]$UseProductionWriters,
        [string]$Detail = ''
    )
    $res = [pscustomobject]@{ Ok = $false; SentRecord = ''; Ledger = ''; DeliveryState = ''; Blocked = $false; Error = ''; InvestigationId = ''; AlreadyDone = $false }
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { $res.Error = 'attempt-not-found'; return $res }
    $receipt = $rec.receipt
    if (-not $receipt -or -not $receipt.Valid) { $res.Error = 'no-valid-receipt'; $res.DeliveryState = [string]$rec.deliveryState; return $res }
    if ([string]$rec.persistence.sentRecord -eq 'ok' -and [string]$rec.persistence.ledger -eq 'ok') {
        $res.Ok = $true
        $res.AlreadyDone = $true
        $res.SentRecord = 'ok'
        $res.Ledger = 'ok'
        $res.DeliveryState = [string]$rec.deliveryState
        return $res
    }
    $failure = ''
    if ([string]$rec.persistence.sentRecord -ne 'ok') {
        $ok = $false
        if ($SentRecordWriter) { try { $ok = [bool](& $SentRecordWriter) } catch { $ok = $false; $failure = 'sent-record-writer-exception: ' + $_.Exception.Message } }
        elseif ($UseProductionWriters) { try { $ok = [bool](Invoke-SendAttemptSentRecordWrite -AttemptId $AttemptId) } catch { $ok = $false; $failure = 'sent-record-writer-exception: ' + $_.Exception.Message } }
        else { $failure = 'no-sent-record-writer' }
        if ($ok) { $rec.persistence.sentRecord = 'ok' } else { $rec.persistence.sentRecord = 'failed'; if (-not $failure) { $failure = 'sent-record-write-returned-false' } }
        $rec.persistence.attempts = [int]$rec.persistence.attempts + 1
    }
    if (-not $failure -and [string]$rec.persistence.ledger -ne 'ok') {
        $ok = $false
        if ($LedgerWriter) { try { $ok = [bool](& $LedgerWriter) } catch { $ok = $false; $failure = 'ledger-writer-exception: ' + $_.Exception.Message } }
        elseif ($UseProductionWriters) { try { $ok = [bool](Invoke-SendAttemptLedgerWrite -AttemptId $AttemptId) } catch { $ok = $false; $failure = 'ledger-writer-exception: ' + $_.Exception.Message } }
        else { $failure = 'no-ledger-writer' }
        if ($ok) { $rec.persistence.ledger = 'ok' } else { $rec.persistence.ledger = 'failed'; if (-not $failure) { $failure = 'ledger-write-returned-false' } }
        $rec.persistence.attempts = [int]$rec.persistence.attempts + 1
    }
    $res.SentRecord = [string]$rec.persistence.sentRecord
    $res.Ledger = [string]$rec.persistence.ledger
    if ($failure) {
        $rec.persistence.lastError = $failure
        $rec.deliveryState = 'persistence_pending'
        $rec.updatedAtUtc = ([datetime]::UtcNow.ToString('o'))
        Add-SendAttemptAudit $rec 'persistence-pending' ($failure + ' ' + [string]$Detail)
        if (-not (Save-SendAttemptRecord $rec)) { $res.Error = 'attempt-store-write-failed'; $res.Blocked = $true; $res.DeliveryState = 'persistence_pending'; return $res }
        # 显式调查：保留待持久化状态，暂停该会话新增发送。
        if (Get-Command New-OrUpdate-Investigation -ErrorAction SilentlyContinue) {
            $inv = New-OrUpdate-Investigation -Buyer ([string]$rec.buyer) -Kind 'receipt_persistence_failed' -AttemptId ([string]$rec.attemptId) -EventRefQuality 'attempt' -EvidenceRefs @('receipt:' + [string]$receipt.ReceiptId, 'persistence:' + $failure) -Detail ('delivery proven by receipt but persistence failed: ' + $failure)
            if ($inv.Ok) { $res.InvestigationId = [string]$inv.Record.id }
        }
        $res.Error = $failure
        $res.Blocked = $true
        $res.DeliveryState = 'persistence_pending'
        return $res
    }
    $rec.deliveryState = 'receipt_verified'
    $rec.updatedAtUtc = ([datetime]::UtcNow.ToString('o'))
    Add-SendAttemptAudit $rec 'persisted-receipt' ('receipt=' + [string]$receipt.ReceiptId + ' ' + [string]$Detail)
    if (-not (Save-SendAttemptRecord $rec)) { $res.Error = 'attempt-store-write-failed'; $res.Blocked = $true; return $res }
    $res.Ok = $true
    $res.DeliveryState = 'receipt_verified'
    return $res
}

# [复核 R4] 恢复路径把"尝试状态更新 + 两段持久化"接成可恢复操作；
#   默认使用**生产写入器**（sent_records + 去重账本），因此不再出现 no-sent-record-writer / no-ledger-writer。
function Resume-SendAttemptPersistence {
    param(
        [Parameter(Mandatory = $true)][string]$AttemptId,
        [scriptblock]$SentRecordWriter = $null,
        [scriptblock]$LedgerWriter = $null,
        [switch]$UseProductionWriters
    )
    $rec = Get-SendAttempt $AttemptId
    if (-not $rec) { return $false }
    # [复核 R8] 只要还有效收据而两段持久化没完成就允许续做 —— 包括已经被写成 receipt_verified
    #   但账本仍为 pending 的尝试（那正是"收据保存后中断"留下的状态）。
    if (-not (Test-SendAttemptPersistencePending $rec)) { return $false }
    if (-not $SentRecordWriter -and -not $LedgerWriter -and -not $UseProductionWriters) {
        # 既没有注入写入器、也没有要求用生产写入器 ⇒ 明确拒绝，而不是悄悄退化成 "no-writer" 结论。
        return $false
    }
    $r = Complete-SendAttemptPersistence -AttemptId $AttemptId -SentRecordWriter $SentRecordWriter -LedgerWriter $LedgerWriter -UseProductionWriters:$UseProductionWriters -Detail 'resume'
    return [bool]$r.Ok
}

# 生产恢复入口（monitor 的每轮扫描与调查 CLI 共用）：对可能有副作用的尝试重试持久化。
#   返回 @{ Ok; Error; Results = @() }
function Invoke-SendAttemptPersistenceRecovery {
    param([string]$Buyer = '', [int]$Max = 5)
    $out = New-Object System.Collections.ArrayList
    $n = 0
    # [复核 R8] 恢复扫描必须覆盖**所有**"有有效收据但账本未提交/未回读"的尝试：
    #   既包括 persistence_pending，也包括收据保存后立刻中断留下的 receipt_verified。
    foreach ($rec in @(Get-SendAttempts -Buyer $Buyer -ActiveOnly)) {
        if ($n -ge $Max) { break }
        if (-not (Test-SendAttemptPersistencePending $rec)) { continue }
        $r = Complete-SendAttemptPersistence -AttemptId ([string]$rec.attemptId) -UseProductionWriters -Detail 'monitor-recovery'
        [void]$out.Add([pscustomobject]@{ AttemptId = [string]$rec.attemptId; Buyer = [string]$rec.buyer; Ok = [bool]$r.Ok; Error = [string]$r.Error; SentRecord = [string]$r.SentRecord; Ledger = [string]$r.Ledger })
        $n++
    }
    return [pscustomobject]@{ Ok = $true; Error = ''; Results = @($out.ToArray()) }
}

# 需要重启对账的尝试（可能已产生外部副作用且尚未定论）。
function Get-SendAttemptsNeedingReconciliation {
    param([string]$Buyer = '')
    $out = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-SendAttempts -Buyer $Buyer -ActiveOnly)) {
        $st = [string]$r.deliveryState
        if ($st -notin @('pending_confirmation', 'delivery_ambiguous')) { continue }
        if (-not (Test-SendAttemptSideEffectPossible $r)) { continue }
        [void]$out.Add($r)
    }
    return @($out.ToArray())
}

# =============================================================================================
# 不重发保护
# =============================================================================================
# [复核 R3] 会话级保护：同一会话里仍有未确认/待持久化/歧义的尝试 ⇒ 不重发。
#   触发（去重键）不同**不**构成放行理由：未确认发送必须先对账并与当前诉求建立明确关系。
#   返回 @{ Blocked; Reasons; Records; SessionBlocked; TriggerRef }
function Test-SendAttemptBlocksResend {
    param([string]$Buyer, [string]$TriggerRef = '', [string]$ConvoKey = '')
    $blocking = New-Object System.Collections.ArrayList
    $sameTrigger = New-Object System.Collections.ArrayList
    foreach ($r in @(Get-SendAttempts -Buyer $Buyer -ActiveOnly)) {
        # [复核 R8] 阻断判据 = "尚未闭环"，而不是只有三个状态标签：
        #   收据已保存但 sent_records/账本未提交的尝试同样必须挡住这个会话。
        if (-not (Test-SendAttemptBlocksConversation $r)) { continue }
        if ($ConvoKey -and [string]$r.convoKey -and ([string]$r.convoKey -ne [string]$ConvoKey)) { continue }
        [void]$blocking.Add($r)
        if ($TriggerRef -and [string]$r.triggerRef -and ([string]$r.triggerRef -eq [string]$TriggerRef)) { [void]$sameTrigger.Add($r) }
    }
    return [pscustomobject]@{
        Blocked = (@($blocking).Count -gt 0)
        Reasons = @($blocking | ForEach-Object { [string]$_.attemptId + ':' + (Get-SendAttemptBlockReason $_) })
        Records = @($blocking.ToArray())
        SessionBlocked = (@($blocking).Count -gt 0)
        SameTrigger = @($sameTrigger.ToArray())
    }
}

# 只有可靠未送达证据才允许重新进入发送流程；仍须由调用方重新核对全部发送门禁。
function Test-SendAttemptRetryAllowed {
    param([string]$Buyer, [string]$TriggerRef = '', [string]$ConvoKey = '')
    $blk = Test-SendAttemptBlocksResend -Buyer $Buyer -TriggerRef $TriggerRef -ConvoKey $ConvoKey
    if ($blk.Blocked) {
        $first = @($blk.Records)[0]
        # 收据已保存但账本未提交的尝试：明确报告"不是未确认，而是持久化没完成"，不给重试授权。
        $reason = 'unconfirmed-attempt-' + [string]$first.deliveryState
        if (Test-SendAttemptPersistencePending $first) { $reason = $reason + '-persistence-pending' }
        return [pscustomobject]@{ Allowed = $false; Reason = $reason; AttemptId = [string]$first.attemptId }
    }
    return [pscustomobject]@{ Allowed = $true; Reason = ''; AttemptId = '' }
}
