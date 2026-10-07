# tests\send_attempt_restart.tests.ps1
# [复核 R2/R4/R8] **真实子进程中断与重启**的隔离消费者回归：
#   ① 子进程在与生产同源的代码路径上持久化发送尝试，并落盘"即将产生外部副作用"的阶段，
#      随后被父进程强制终止（没有清理、没有优雅退出 —— 就是"点击之后崩了"）；
#   ② 父进程（另一个进程）从磁盘上看到：这次尝试可能已经发出 ⇒ 会话级闸门必须挡住重发；
#   ③ 再启动一个**新进程**做重启对账（同口径重读 + 真实收据），父进程核验最终磁盘状态：
#      收据绑定确切新增事件，sent_records 与账本真的写进去了；
#   ④ [复核 R8] 另外两条真实中断：**收据已保存但两段账本都没提交**（各账本提交阶段之前），
#      以及 **sent_records 已提交、账本写入阶段被杀**（两段提交之间）——
#      两种情况下会话都必须继续被挡住，且由生产恢复入口（monitor 每轮扫描 / CLI recover 共用）
#      幂等补齐后才解除。
# isolated 层：运行根必须在系统临时目录下（由 tests\run_tests.ps1 提供），不碰生产运行态。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output ("FAIL: " + $name) }
}
$lf = [string][char]10

# --- 运行根守卫：本测试会启动子进程写运行态，必须落在临时隔离根内 ---
$runRoot = Get-SkillRuntimeRoot
$tempRoot = [IO.Path]::GetFullPath($env:TEMP)
if ($null -eq (Get-AarIsolationInfo)) {
    if (-not (Test-AarPathUnder $runRoot $tempRoot)) {
        throw 'send_attempt_restart.tests.ps1 requires an isolated runtime root under the system temp directory - run it through tests\run_tests.ps1'
    }
    [void](New-AarIsolationRoot -Root $runRoot)
}
Check 'restart-runtime-root-is-isolated-temp' ((Test-AarPathUnder $runRoot $tempRoot) -and (Test-SkillRuntimeIsolated) -and ($null -ne (Get-AarIsolationInfo)))

. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\outbound_receipts.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\investigations.ps1')
. (Join-Path $scripts 'lib\send_attempts.ps1')

# --- 共享夹具：所有子进程必须看到**同一段**会话与同一条尝试 ---
$workDir = Join-Path $runRoot 'restart-fixture'
if (-not (Test-Path $workDir)) { New-Item -ItemType Directory -Path $workDir -Force | Out-Null }
$fixturePath = Join-Path $workDir 'fixture.ps1'
$fixture = @'
# 重启夹具（虚构数据）：基线会话 + 点击之后可能出现的新增出站事件。
$script:RestartBaselineText = 'Is the rate still valid for 40ft to Jeddah?'
$script:RestartReplyText = 'Your cartons are booked for Friday pickup.'
$script:RestartReplyAt = 1791005000000
function RestartMeta([string]$text, [string]$dir, [long]$ts) {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'
        t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        dir = $dir; dirsrc = 'layout'; mid = ''; ts = $ts; tprec = 'second'; st = 'message'
        src = @(); f = @(); at = '2026-10-07T00:00:00Z'; idq = 'composite'
    }))
}
function RestartLine([string]$role, [string]$text, [long]$ts) {
    return ('[' + $role + '] ' + $text + ' @@MT:' + $ts + ' ' + (RestartMeta $text $(if ($role -eq 'BUYER') { 'in' } else { 'out' }) $ts))
}
function Get-RestartBaselineLines {
    return @(
        (RestartLine 'BUYER' $script:RestartBaselineText 1791004000000),
        (RestartLine 'ME' 'Our earlier reply about the rate.' 1791004100000)
    )
}
function Get-RestartAfterLines {
    return @(Get-RestartBaselineLines) + @((RestartLine 'ME' $script:RestartReplyText $script:RestartReplyAt))
}
function Get-RestartLedgerValue([string]$Path, [string]$Key) {
    $doc = Read-JsonDocument $Path
    $v = ''
    if ($doc.Data -and ($doc.Data.PSObject.Properties.Name -contains 'replied')) {
        foreach ($p in $doc.Data.replied.PSObject.Properties) { if ([string]$p.Name -eq $Key) { $v = [string]$p.Value } }
    }
    return $v
}
'@
[IO.File]::WriteAllText($fixturePath, $fixture, (New-Object Text.UTF8Encoding($true)))

# --- 子进程公共前导（新增的中断场景共用；夹具与运行根由参数传入） ---
$preludePath = Join-Path $workDir 'child_prelude.ps1'
$prelude = @'
$ErrorActionPreference = 'Stop'
$env:AAR_RUNTIME_ROOT = $Root
$global:AarOfflineRequired = $true
. (Join-Path $Repo 'scripts\config.ps1')
. (Join-Path $Repo 'scripts\lib\paths.ps1')
. (Join-Path $Repo 'scripts\lib\state_store.ps1')
. (Join-Path $Repo 'scripts\lib\msg_source.ps1')
. (Join-Path $Repo 'scripts\lib\msg_events.ps1')
. (Join-Path $Repo 'scripts\lib\outbound_receipts.ps1')
. (Join-Path $Repo 'scripts\lib\sent_records.ps1')
. (Join-Path $Repo 'scripts\lib\investigations.ps1')
. (Join-Path $Repo 'scripts\lib\send_attempts.ps1')
. (Join-Path $Root 'restart-fixture\fixture.ps1')
function Write-Marker([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, [string]$Text) }
# 与生产 monitor 发送路径同形：先持久化尝试，再落盘"即将产生外部副作用"的阶段。
function Start-RestartAttempt([string]$Buyer, [string]$ConvoKey, [string]$DedupKey) {
    $before = @(Get-ConversationEventIndex (Get-RestartBaselineLines))
    $att = New-PersistedSendAttempt -Buyer $Buyer -Text $script:RestartReplyText -DedupKey $DedupKey -TriggerRef $DedupKey -ConvoKey $ConvoKey -BeforeEvents $before
    if (-not $att.Ok) { throw ('PERSIST-FAILED: ' + [string]$att.Error) }
    $side = Start-SendAttemptSideEffect -AttemptId $att.AttemptId -Detail ('dedupKey=' + $DedupKey)
    if (-not $side.Ok) { throw ('STAGE-FAILED: ' + [string]$side.Error) }
    return [string]$att.AttemptId
}
# 同口径重读 + 真实收据判定（与 monitor 的重启对账用同一个函数）。
function Resolve-RestartReceipt([string]$AttemptId, [string]$ConvoKey) {
    $d = Resolve-SendAttemptFromEvents -AttemptId $AttemptId -Events @(Get-ConversationEventIndex (Get-RestartAfterLines)) -ConvoKey $ConvoKey
    if (-not $d.Ok) { throw ('RECEIPT-FAILED: ' + [string]$d.Error) }
    return $d.Receipt
}
'@
[IO.File]::WriteAllText($preludePath, $prelude, (New-Object Text.UTF8Encoding($true)))

# 子进程启动/等待辅助（父进程侧）
function Start-Child([string]$Path, [string[]]$Extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path, '-Repo', $repo, '-Root', $runRoot)
    if ($Extra) { $argList += $Extra }
    return (Start-Process -FilePath 'powershell' -ArgumentList $argList -PassThru -WindowStyle Hidden)
}
function Wait-ForFile([string]$Path, $Proc, [int]$Seconds = 90) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $Path)) {
        if ($Proc.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    return (Test-Path $Path)
}
function Stop-Child($Proc) {
    $exited = $Proc.HasExited
    if (-not $exited) { Stop-Process -Id $Proc.Id -Force; Start-Sleep -Milliseconds 400 }
    return $exited
}

$child1Path = Join-Path $workDir 'child_crash.ps1'
$child1 = @'
param([string]$Repo, [string]$Root, [string]$Marker)
$ErrorActionPreference = 'Stop'
$env:AAR_RUNTIME_ROOT = $Root
$global:AarOfflineRequired = $true
. (Join-Path $Repo 'scripts\config.ps1')
. (Join-Path $Repo 'scripts\lib\paths.ps1')
. (Join-Path $Repo 'scripts\lib\state_store.ps1')
. (Join-Path $Repo 'scripts\lib\msg_source.ps1')
. (Join-Path $Repo 'scripts\lib\msg_events.ps1')
. (Join-Path $Repo 'scripts\lib\outbound_receipts.ps1')
. (Join-Path $Repo 'scripts\lib\sent_records.ps1')
. (Join-Path $Repo 'scripts\lib\investigations.ps1')
. (Join-Path $Repo 'scripts\lib\send_attempts.ps1')
. (Join-Path $Root 'restart-fixture\fixture.ps1')
$before = @(Get-ConversationEventIndex (Get-RestartBaselineLines))
$att = New-PersistedSendAttempt -Buyer 'Buyer Restart' -Text $script:RestartReplyText -DedupKey 'restart|1' -TriggerRef 'restart|1' -ConvoKey 'buyer restart' -BeforeEvents $before
if (-not $att.Ok) { [IO.File]::WriteAllText($Marker, 'PERSIST-FAILED:' + $att.Error); exit 9 }
# 外部副作用前的第二阶段持久化：这一步之后进程"崩溃"，磁盘上留下可能已发出的状态。
$side = Start-SendAttemptSideEffect -AttemptId $att.AttemptId -Detail 'child about to click send'
if (-not $side.Ok) { [IO.File]::WriteAllText($Marker, 'STAGE-FAILED:' + $side.Error); exit 9 }
[IO.File]::WriteAllText($Marker, $att.AttemptId)
# 模拟"点击之后卡住"：不再主动退出，等待父进程强制终止。
Start-Sleep -Seconds 600
'@
[IO.File]::WriteAllText($child1Path, $child1, (New-Object Text.UTF8Encoding($true)))
Check 'restart-child-scripts-written' ((Test-Path $fixturePath) -and (Test-Path $child1Path) -and (Test-Path $preludePath))
# 父进程也用同一份夹具：对账与核验必须与子进程看到的是**同一段会话与同一条尝试**。
. $fixturePath

# ------------------------------------------------------------------ ① 真实子进程：持久化 → 崩溃
$markerPath = Join-Path $workDir 'child1.marker'
if (Test-Path $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
$proc = Start-Child $child1Path @('-Marker', $markerPath)
$attemptId = ''
if (Wait-ForFile $markerPath $proc) { $attemptId = ([IO.File]::ReadAllText($markerPath)).Trim() }
$childExited = Stop-Child $proc
Check 'restart-child-persisted-an-attempt' ($attemptId -match '^att-')
Check 'restart-child-was-killed-without-cleanup' (-not $childExited)

# ------------------------------------------------------------------ ② 另一个进程看到的磁盘状态
$stored = Get-SendAttempt $attemptId
Check 'restart-attempt-visible-to-a-new-process' ([bool]$stored -and [string]$stored.deliveryState -eq 'pending_confirmation')
Check 'restart-attempt-records-the-dispatch-stage' ([string]$stored.stage -eq 'dispatching' -and [bool]$stored.sideEffectAtUtc)
Check 'restart-attempt-keeps-the-complete-text' ([string]$stored.text -eq 'Your cartons are booked for Friday pickup.')
Check 'restart-attempt-keeps-a-recoverable-baseline' (@($stored.beforeProof.Baseline).Count -eq 2)
Check 'restart-side-effect-is-possible-after-the-crash' ((Test-SendAttemptSideEffectPossible $stored))
Check 'restart-conversation-is-blocked-from-resending' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart' -TriggerRef 'restart|1').Blocked)
Check 'restart-attempt-is-listed-for-reconciliation' (@(Get-SendAttemptsNeedingReconciliation -Buyer 'Buyer Restart').Count -eq 1)
# 没有新事件时**不能**推出"未送达"，更不能盲目重发
$noProof = Invoke-SendAttemptReconciliation -AttemptId $attemptId -Events @(Get-ConversationEventIndex (Get-RestartBaselineLines)) -ConvoKey 'buyer restart'
Check 'restart-reconciliation-without-evidence-keeps-pending' ((-not $noProof.Applied) -and $noProof.Error -eq 'no-new-outbound-event')
Check 'restart-reconciliation-without-evidence-keeps-blocking' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)

# ------------------------------------------------------------------ ③ 新进程：重启对账（必须同时接通真实提交）
$ledgerPath = Get-SkillPath 'state'
[void](Write-JsonDocumentAtomic -Path $ledgerPath -Data ([pscustomobject]@{ replied = [pscustomobject]@{} }) -Depth 5)
$child2Path = Join-Path $workDir 'child_recover.ps1'
$child2 = @'
param([string]$Repo, [string]$Root, [string]$AttemptId, [string]$Out)
$ErrorActionPreference = 'Stop'
$env:AAR_RUNTIME_ROOT = $Root
$global:AarOfflineRequired = $true
. (Join-Path $Repo 'scripts\config.ps1')
. (Join-Path $Repo 'scripts\lib\paths.ps1')
. (Join-Path $Repo 'scripts\lib\state_store.ps1')
. (Join-Path $Repo 'scripts\lib\msg_source.ps1')
. (Join-Path $Repo 'scripts\lib\msg_events.ps1')
. (Join-Path $Repo 'scripts\lib\outbound_receipts.ps1')
. (Join-Path $Repo 'scripts\lib\sent_records.ps1')
. (Join-Path $Repo 'scripts\lib\investigations.ps1')
. (Join-Path $Repo 'scripts\lib\send_attempts.ps1')
. (Join-Path $Root 'restart-fixture\fixture.ps1')
$events = @(Get-ConversationEventIndex (Get-RestartAfterLines))
# [复核 R8] 只调用**生产的重启对账入口**：取得收据之后必须由它接通真实提交，
#   不再额外手工调用 Complete-SendAttemptPersistence（否则就绕开了被测的接线）。
$recon = Invoke-SendAttemptReconciliation -AttemptId $AttemptId -Events $events -ConvoKey 'buyer restart'
$result = [pscustomobject]@{
    Applied = [bool]$recon.Applied
    DeliveryState = [string]$recon.DeliveryState
    ReconError = [string]$recon.Error
    ReceiptId = $(if ($recon.Receipt) { [string]$recon.Receipt.ReceiptId } else { '' })
    PersistenceOk = [bool]$recon.PersistenceOk
    PersistenceComplete = [bool]$recon.PersistenceComplete
    SentRecord = [string]$recon.SentRecord
    Ledger = [string]$recon.Ledger
    PersistError = [string]$recon.PersistError
    BlockedAfter = [bool](Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked
}
[IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Compress -Depth 5))
exit 0
'@
[IO.File]::WriteAllText($child2Path, $child2, (New-Object Text.UTF8Encoding($true)))
$resultPath = Join-Path $workDir 'child2.result.json'
if (Test-Path $resultPath) { Remove-Item -LiteralPath $resultPath -Force }
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell -NoProfile -ExecutionPolicy Bypass -File $child2Path -Repo $repo -Root $runRoot -AttemptId $attemptId -Out $resultPath | Out-Null
$child2Exit = $LASTEXITCODE
$ErrorActionPreference = $savedEap
Check 'restart-recovery-process-exited-zero' ($child2Exit -eq 0 -and (Test-Path $resultPath))
$result = $null
if (Test-Path $resultPath) { $result = ([IO.File]::ReadAllText($resultPath) | ConvertFrom-Json) }
Check 'restart-recovery-proved-delivery' ($result -and $result.Applied -and $result.DeliveryState -eq 'receipt_verified' -and [bool]$result.ReceiptId)
Check 'restart-reconciliation-alone-committed-both-writes' ($result -and $result.PersistenceOk -and $result.PersistenceComplete -and $result.SentRecord -eq 'ok' -and $result.Ledger -eq 'ok')
Check 'restart-recovery-lifted-the-block' ($result -and -not $result.BlockedAfter)

# ------------------------------------------------------------------ ④ 父进程核验最终磁盘状态
$final = Get-SendAttempt $attemptId
Check 'restart-final-state-is-receipt-verified' ([string]$final.deliveryState -eq 'receipt_verified')
Check 'restart-final-receipt-binds-the-exact-new-event' ([bool]$final.receipt.Valid -and [string]$final.receipt.MessageId -eq '' -and [string]$final.receipt.MessageTime -eq '1791005000000' -and [string]$final.receipt.ConfirmationType -eq 'recovered-from-persisted-baseline')
Check 'restart-final-receipt-validates-against-the-stored-text' ((Test-ConfirmedOutboundReceipt $final.receipt 'Buyer Restart' 'Your cartons are booked for Friday pickup.'))
Check 'restart-final-attempt-is-settled' ((Test-SendAttemptSettled $final) -and (Test-SendAttemptPersistenceComplete $final))
$sentRecs = @(Get-SentRecords -Buyer 'Buyer Restart' | Where-Object { [string]$_.receipt.ReceiptId -eq [string]$final.receipt.ReceiptId })
Check 'restart-sent-record-really-exists-on-disk' ($sentRecs.Count -eq 1)
Check 'restart-ledger-entry-really-exists-on-disk' ((Get-RestartLedgerValue $ledgerPath 'buyer restart') -eq 'restart|1')
Check 'restart-conversation-is-released-after-recovery' (-not (Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)

# =============================================================================================
# ⑤⑥【复核 R8】真实中断的两个新阶段：收据保存之后、两段账本提交的前 / 中
#
#   反例（修复前）：Set-SendAttemptReceipt 写成 receipt_verified 就同时解除了会话保护，
#     而 -ActiveOnly 又把 receipt_verified 整个排除在恢复扫描之外 ⇒ 这条尝试永远不会补齐账本，
#     来源也无法用发送记录纠正。下面两条真实子进程分别停在"账本提交之前"和"账本提交之中"。
# =============================================================================================
$child3Path = Join-Path $workDir 'child_receipt_stage.ps1'
$child3 = @'
param([string]$Repo, [string]$Root, [string]$Marker)
. (Join-Path $Root 'restart-fixture\child_prelude.ps1')
try { $attempt = Start-RestartAttempt 'Buyer Receipt Window' 'buyer receipt window' 'rw|1' } catch { Write-Marker $Marker ('SETUP-FAILED: ' + $_.Exception.Message); exit 9 }
# 与生产 monitor 同形：送达被收据证明 ⇒ 先落盘 receipt_verified（这一行就是生产调用点）。
try { $receipt = Resolve-RestartReceipt $attempt 'buyer receipt window' } catch { Write-Marker $Marker ('SETUP-FAILED: ' + $_.Exception.Message); exit 9 }
if (-not (Set-SendAttemptReceipt -AttemptId $attempt -Receipt $receipt -DeliveryState 'receipt_verified')) { Write-Marker $Marker 'RECEIPT-WRITE-FAILED'; exit 9 }
Write-Marker $Marker $attempt
# 进程在提交任何一段账本之前被强杀。
Start-Sleep -Seconds 600
'@
[IO.File]::WriteAllText($child3Path, $child3, (New-Object Text.UTF8Encoding($true)))

$child4Path = Join-Path $workDir 'child_ledger_stage.ps1'
$child4 = @'
param([string]$Repo, [string]$Root, [string]$Marker, [string]$StageMarker)
. (Join-Path $Root 'restart-fixture\child_prelude.ps1')
try { $attempt = Start-RestartAttempt 'Buyer Ledger Window' 'buyer ledger window' 'lw|1' } catch { Write-Marker $Marker ('SETUP-FAILED: ' + $_.Exception.Message); exit 9 }
try { $receipt = Resolve-RestartReceipt $attempt 'buyer ledger window' } catch { Write-Marker $Marker ('SETUP-FAILED: ' + $_.Exception.Message); exit 9 }
if (-not (Set-SendAttemptReceipt -AttemptId $attempt -Receipt $receipt -DeliveryState 'receipt_verified')) { Write-Marker $Marker 'RECEIPT-WRITE-FAILED'; exit 9 }
Write-Marker $Marker $attempt
# 走生产恢复路径：sent_records 用真实写入器先提交成功，随后在**账本写入阶段**被强杀
#   ⇒ 磁盘上是"发送记录已落盘、两段结论仍是 pending"的部分提交状态。
$ledgerStage = {
    Write-Marker $StageMarker 'ledger-stage-entered'
    Start-Sleep -Seconds 600
}
$null = Complete-SendAttemptPersistence -AttemptId $attempt -UseProductionWriters -LedgerWriter $ledgerStage
Start-Sleep -Seconds 600
'@
[IO.File]::WriteAllText($child4Path, $child4, (New-Object Text.UTF8Encoding($true)))

# ---- ⑤ 收据已保存、两段账本都还没提交时中断 ----
$receiptMarker = Join-Path $workDir 'child_receipt.marker'
if (Test-Path $receiptMarker) { Remove-Item -LiteralPath $receiptMarker -Force }
$procR = Start-Child $child3Path @('-Marker', $receiptMarker)
$attemptReceipt = ''
if (Wait-ForFile $receiptMarker $procR) { $attemptReceipt = ([IO.File]::ReadAllText($receiptMarker)).Trim() }
$childRExited = Stop-Child $procR
Check 'R8-receipt-stage-child-saved-the-receipt' ($attemptReceipt -match '^att-')
Check 'R8-receipt-stage-child-was-killed-without-cleanup' (-not $childRExited)
$storedR = Get-SendAttempt $attemptReceipt
Check 'R8-receipt-stage-state-is-receipt-verified' ($storedR -and [string]$storedR.deliveryState -eq 'receipt_verified')
Check 'R8-receipt-stage-both-ledgers-are-still-pending' ([string]$storedR.persistence.sentRecord -eq 'pending' -and [string]$storedR.persistence.ledger -eq 'pending')
Check 'R8-receipt-stage-attempt-is-not-settled' (-not (Test-SendAttemptSettled $storedR))
Check 'R8-receipt-stage-attempt-stays-active-for-recovery' (@(Get-SendAttempts -Buyer 'Buyer Receipt Window' -ActiveOnly).Count -eq 1)
Check 'R8-receipt-stage-conversation-is-blocked' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Receipt Window').Blocked)
Check 'R8-receipt-stage-sent-records-are-not-written-yet' (@(Get-SentRecords -Buyer 'Buyer Receipt Window').Count -eq 0)
Check 'R8-receipt-stage-needs-persistence-not-reconciliation' (@(Get-SendAttemptsNeedingReconciliation -Buyer 'Buyer Receipt Window').Count -eq 0)

# ---- ⑥ sent_records 已提交、账本写入阶段被中断 ----
$ledgerMarker = Join-Path $workDir 'child_ledger.marker'
$stageMarker = Join-Path $workDir 'child_ledger.stage'
foreach ($p in @($ledgerMarker, $stageMarker)) { if (Test-Path $p) { Remove-Item -LiteralPath $p -Force } }
$procL = Start-Child $child4Path @('-Marker', $ledgerMarker, '-StageMarker', $stageMarker)
$attemptLedger = ''
if (Wait-ForFile $ledgerMarker $procL) { $attemptLedger = ([IO.File]::ReadAllText($ledgerMarker)).Trim() }
$reachedLedgerStage = Wait-ForFile $stageMarker $procL 60
$childLExited = Stop-Child $procL
Check 'R8-ledger-stage-child-had-saved-the-receipt' ($attemptLedger -match '^att-')
Check 'R8-ledger-stage-child-reached-the-ledger-write' $reachedLedgerStage
Check 'R8-ledger-stage-child-was-killed-without-cleanup' (-not $childLExited)
$storedL = Get-SendAttempt $attemptLedger
Check 'R8-ledger-stage-state-still-carries-pending-ledgers' ($storedL -and [string]$storedL.deliveryState -eq 'receipt_verified' -and [string]$storedL.persistence.sentRecord -eq 'pending' -and [string]$storedL.persistence.ledger -eq 'pending')
Check 'R8-ledger-stage-sent-record-really-reached-the-disk' (@(Get-SentRecords -Buyer 'Buyer Ledger Window').Count -eq 1)
Check 'R8-ledger-stage-ledger-entry-is-still-missing' ((Get-RestartLedgerValue $ledgerPath 'buyer ledger window') -eq '')
Check 'R8-ledger-stage-conversation-is-blocked' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Ledger Window').Blocked)

# ---- ⑦ 新进程：生产恢复入口（monitor 每轮扫描 / CLI recover 共用）补齐并回读 ----
$child5Path = Join-Path $workDir 'child_persist_recover.ps1'
$child5 = @'
param([string]$Repo, [string]$Root, [string]$Buyer, [string]$Out)
$ErrorActionPreference = 'Stop'
$env:AAR_RUNTIME_ROOT = $Root
$global:AarOfflineRequired = $true
. (Join-Path $Repo 'scripts\config.ps1')
. (Join-Path $Repo 'scripts\lib\paths.ps1')
. (Join-Path $Repo 'scripts\lib\state_store.ps1')
. (Join-Path $Repo 'scripts\lib\msg_source.ps1')
. (Join-Path $Repo 'scripts\lib\msg_events.ps1')
. (Join-Path $Repo 'scripts\lib\outbound_receipts.ps1')
. (Join-Path $Repo 'scripts\lib\sent_records.ps1')
. (Join-Path $Repo 'scripts\lib\investigations.ps1')
. (Join-Path $Repo 'scripts\lib\send_attempts.ps1')
$rec = Invoke-SendAttemptPersistenceRecovery -Buyer $Buyer -Max 5
$attempts = @(Get-SendAttempts -Buyer $Buyer)
$result = [pscustomobject]@{
    Ok = [bool]$rec.Ok
    Count = @($rec.Results).Count
    Results = @($rec.Results)
    AttemptCount = $attempts.Count
    PersistenceComplete = $(if ($attempts.Count -gt 0) { [bool](Test-SendAttemptPersistenceComplete $attempts[0]) } else { $false })
    Settled = $(if ($attempts.Count -gt 0) { [bool](Test-SendAttemptSettled $attempts[0]) } else { $false })
    ReceiptId = $(if ($attempts.Count -gt 0 -and $attempts[0].receipt) { [string]$attempts[0].receipt.ReceiptId } else { '' })
    SentRecordCount = @(Get-SentRecords -Buyer $Buyer).Count
    BlockedAfter = [bool](Test-SendAttemptBlocksResend -Buyer $Buyer).Blocked
}
[IO.File]::WriteAllText($Out, ($result | ConvertTo-Json -Compress -Depth 6))
exit 0
'@
[IO.File]::WriteAllText($child5Path, $child5, (New-Object Text.UTF8Encoding($true)))

function Invoke-PersistRecoveryChild([string]$Buyer, [string]$OutName) {
    $out = Join-Path $workDir $OutName
    if (Test-Path $out) { Remove-Item -LiteralPath $out -Force }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $child5Path -Repo $repo -Root $runRoot -Buyer $Buyer -Out $out | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    $obj = $null
    if ((Test-Path $out) -and $code -eq 0) { $obj = ([IO.File]::ReadAllText($out) | ConvertFrom-Json) }
    return [pscustomobject]@{ ExitCode = $code; Result = $obj }
}

$runR = Invoke-PersistRecoveryChild 'Buyer Receipt Window' 'child_receipt.recovered.json'
Check 'R8-receipt-stage-recovery-process-exited-zero' ($runR.ExitCode -eq 0 -and $runR.Result)
Check 'R8-receipt-stage-recovery-completed-both-writes' ($runR.Result.Count -eq 1 -and [bool]$runR.Result.Results[0].Ok -and $runR.Result.Results[0].SentRecord -eq 'ok' -and $runR.Result.Results[0].Ledger -eq 'ok')
Check 'R8-receipt-stage-recovery-settles-the-attempt' ($runR.Result.PersistenceComplete -and $runR.Result.Settled)
Check 'R8-receipt-stage-recovery-releases-the-conversation' (-not $runR.Result.BlockedAfter)
Check 'R8-receipt-stage-recovery-wrote-exactly-one-sent-record' ($runR.Result.SentRecordCount -eq 1)
Check 'R8-receipt-stage-ledger-entry-is-on-disk' ((Get-RestartLedgerValue $ledgerPath 'buyer receipt window') -eq 'rw|1')
$storedRAfter = Get-SendAttempt $attemptReceipt
Check 'R8-receipt-stage-recovery-kept-the-original-receipt' ([string]$storedRAfter.receipt.ReceiptId -eq [string]$runR.Result.ReceiptId)

$runL = Invoke-PersistRecoveryChild 'Buyer Ledger Window' 'child_ledger.recovered.json'
Check 'R8-ledger-stage-recovery-process-exited-zero' ($runL.ExitCode -eq 0 -and $runL.Result)
Check 'R8-ledger-stage-recovery-completed-both-writes' ($runL.Result.Count -eq 1 -and [bool]$runL.Result.Results[0].Ok -and $runL.Result.Results[0].SentRecord -eq 'ok' -and $runL.Result.Results[0].Ledger -eq 'ok')
Check 'R8-ledger-stage-recovery-did-not-duplicate-the-sent-record' ($runL.Result.SentRecordCount -eq 1)
Check 'R8-ledger-stage-recovery-settles-and-releases' ($runL.Result.PersistenceComplete -and $runL.Result.Settled -and (-not $runL.Result.BlockedAfter))
Check 'R8-ledger-stage-ledger-entry-is-on-disk' ((Get-RestartLedgerValue $ledgerPath 'buyer ledger window') -eq 'lw|1')
$storedLAfter = Get-SendAttempt $attemptLedger
Check 'R8-ledger-stage-recovery-kept-the-original-receipt' ([string]$storedLAfter.receipt.ReceiptId -eq [string]$runL.Result.ReceiptId)

Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
