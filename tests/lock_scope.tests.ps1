# tests\lock_scope.tests.ps1 - 页面锁范围与过期草稿（2026-10-05 spec §6.2 / §7）
#
# 覆盖（用真实入口函数 + 桩边界，不碰浏览器、不发送）：
#   L1  读消息阶段持锁，进入附件/生成前**释放**（LOCK-RELEASED-FOR-GENERATION）
#   L2  生成期间锁是空闲的：外部写者可以在此窗口取到锁
#   L3  发送前重新取锁并复核（PAGE-LOCK-REACQUIRED），发送在锁内完成
#   L4  生成期间买家改了诉求 ⇒ 旧草稿丢弃（STALE-DRAFT-DISCARD buyer-input-changed），不发送
#   L5  生成期间人工插话 ⇒ 旧草稿丢弃（human-or-unknown:human-last），不发送
#   L6  生成期间人工临时暂停生效 ⇒ 旧草稿丢弃（human-pause-active），不发送
#   L7  发送前拿不到锁 ⇒ 本轮不发送（SEND-LOCK-BUSY）
#   L8  复核失败时去重账本不被写（没有"发了却没发"的假成功）
#
# 隔离：临时运行根 + 隔离标记；monitor 的页面锁落在该根内。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0; $script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== lock_scope tests =='

$isoRoot = Join-Path $env:TEMP ('aar-lockscope-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot

. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib/sent_records.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\lock.ps1')

# ---- 真实入口函数（AST 抽取，与其它入口测试同款做法） ----
$tk = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tk, [ref]$errs)
if ($errs.Count) { throw 'monitor.ps1 failed to parse' }
foreach ($fn in @('Invoke-ConvoItem', 'Update-PendingSeen', 'Generate-Reply-LLM', 'Set-StateHash', 'Test-RepliedStateUsable', 'Get-RepliedStateFileSize', 'Get-LedgerHealth', 'Reset-LedgerHealthCache', 'Get-CachedDocumentRead', 'Test-LedgerShape', 'Get-ReplyEntryCount', 'Get-TaskContextForConvo')) {
    $n = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true)
    if (-not $n) { throw ('monitor.ps1 does not define ' + $fn) }
    Invoke-Expression $n.Extent.Text
}

$LF = [string][char]10
$script:now = [datetime]'2026-10-05T12:00:00'
function Get-Date { param([string]$Format) if ($Format) { return $script:now.ToString($Format) }; return $script:now }
$script:dataDir = Join-Path $isoRoot 'data'
New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null
$logFile = $null
$script:replyMinGapMin = 5; $script:replyPostSendCooldownMin = 5
$script:replyNewMsgFloorSec = 20; $script:requiredSeenRounds = 2; $script:replyRoundBudgetSec = 180
$script:accioFlags = @{ shadow = $false; read = $false }
$script:notifyChannelVerified = $false
$script:roundHalt = $false
$script:actionEvidence = New-ActionEvidence -Values $null
$script:banSafeFallback = "Thanks - I can't confirm this from here."
$script:lockHoldStart = $script:now

function Write-Log($text) { $script:logs += $text }
function Write-LocalAlert { }
function Clear-LocalAlert { }
function Send-WecomMessage { return 'SENT_OK' }
function Send-NewInquiryAlert { }
function Add-Content { param($Path, $Value, $Encoding) }
# Test-RepliedStateUsable / Get-RepliedStateFileSize / Set-StateHash come from the REAL monitor
# (AST-extracted above); only the ledger READ/WRITE boundary is stubbed.
# [2026-10-05 spec §5 A5] The ledger STATE now comes from Get-LedgerHealth (the real
# Test-RepliedStateUsable consumes it), so that is the single boundary stubbed here - the
# usability judgement itself is the production one, never a stub.
$script:stateFile = Join-Path $isoRoot 'state.json'
$script:ledgerHealthy = $true
function Get-LedgerHealth {
    $status = 'valid'
    if (-not $script:ledgerHealthy) { $status = 'corrupt' }
    $data = $null
    if ($status -eq 'valid') { $data = [pscustomobject]@{ replied = [pscustomobject]@{} } }
    return [pscustomobject]@{ Status = $status; Data = $data; Bytes = [long]0; Error = ''; Path = $script:stateFile; Source = 'stub'; Count = 0; Recovered = $false; Reasons = @() }
}
function Set-RepliedState($state) { $script:writes++ }
function Repair-RepliedState { throw 'Unexpected repair' }
function Get-RepliedState { throw 'Unexpected live read' }
function Test-NoReplyBuyer { return $false }
function Save-BuyerProfile { }
function Remove-PendingRetry { }
function Add-PendingRetry { param($key, $reason) $script:retryReason = $reason }
function Read-RetryTable { return @{ items = @{} } }
function Get-GoodsDataStatus { return $null }
function Start-LlmRound { return @{ sw = [Diagnostics.Stopwatch]::StartNew() } }
function Stop-LlmRound { }
function Get-LlmRoundElapsedSec { return 0 }
function Get-LlmRoundRemainingSec { return 180 }
function Test-LlmRoundBudgetExceeded { return $false }
function Get-ReplyPromptPath { return (Join-Path $scripts 'reply_agent_prompt.md') }
function Get-ReplyScenarioPath { return (Join-Path $scripts 'reply_scenarios.md') }
function Get-Rules { return $null }
function Invoke-LLM { param($Messages, $Temperature, $MaxTokens, $LogFile) $script:modelCalls++; return 'Could you send the delivery address?' }
function Remove-AttachmentMarkers { param([string]$text) return $text }
function Get-ImageDataUrl { return $null }
function Get-DocumentBase64ViaCdp { return $null }
function Get-DocumentBase64ViaHttp { return $null }
function Get-AccioReplyLines { return @() }
function Test-AccioLinesOverlap { return $true }
# Resolving runtime paths through the REAL interface is safe here because this file runs isolated:
# the isolation marker is asserted below, so Get-SkillPath can only return temp-root paths.
Check 'L0-runtime-is-isolated' (Test-AarIsolatedRuntime) 'the isolation marker is missing'
function Invoke-CdpEval { throw 'Browser access forbidden' }
function Start-Sleep { param([int]$Seconds = 1, [int]$Milliseconds = 0) $script:sleeps++ }
# 边界：暂停/任务/发送记录/发送适配器全部桩化（页面锁是**真实**的，本测试就是要验它）
function Update-HumanPauseFromLines { param([string]$Buyer, [string[]]$Lines, $SentMatches = $null, [datetime]$Now) return [pscustomobject]@{ Started = $false; Changed = $false; Until = $null; Reason = 'stub'; HumanIndex = -1; Identity = '' } }
# [2026-10-05 spec §2.2 第 5 条] The pause is now checked TWICE: once before deciding whether to
# answer the newest buyer message (scan) and once just before sending. Only the SECOND check may
# report the pause, so the L6 case still proves the draft is discarded at send time.
$script:pauseCalls = 0
# [2026-10-05 八项补修 F2 §4.1 第 1/2 条] 读取与发送前共用的编排入口。本文件把暂停/等待的**存储**
#   当作边界（下面的 Test-HumanPauseActive / Test-SourceUnknownHoldActive 已经是桩），因此同步入口
#   委托给同一组桩，保持『这轮该不该因为介入而让路』的语义不变。
function Sync-ConversationInterventionState {
    param([string]$Buyer, $Conversation = $null, [string[]]$Lines = $null, $SentMatches = $null, $Now = $null, $NowUtc = $null, [int]$Minutes = 0)
    $p = Test-HumanPauseActive -Buyer $Buyer
    $h = Test-SourceUnknownHoldActive -Buyer $Buyer
    return [pscustomobject]@{ SyncOk = $true; Buyer = $Buyer; NowUtc = $NowUtc; HumanPauseActive = [bool]$p.Active; HumanPauseUntilUtc = $p.Until
        HumanPauseReason = [string]$p.Reason; UnknownHoldActive = [bool]$h.Active; UnknownHoldUntilUtc = $h.Until; UnknownHoldReason = [string]$h.Reason
        NewHumanEvents = @(); NewUnknownEvents = @(); Anomalies = @(); UnknownHistory = @(); LegacyAdopted = $false; Reason = 'stub'; Error = '' }
}
function Get-ActionEvidenceForTask { param([string]$Buyer, [string]$TaskId, [string]$Kind = '', [string]$SupplierIdentity = '') return (New-ActionEvidence -Values $null) }

function Test-HumanPauseActive {
    param([string]$Buyer, [datetime]$Now)
    $script:pauseCalls++
    $active = ([bool]$script:pauseActive -and $script:pauseCalls -gt 1)
    return [pscustomobject]@{ Active = $active; Until = $script:now.AddMinutes(3); RemainingSec = 180; Entry = $null; Reason = 'stub' }
}
function Get-ActionEvidenceForBuyer { param([string]$Buyer = '', [string]$Kind = '') return (New-ActionEvidence -Values $null) }
# [2026-10-05 spec §2.2 第 4 条] The independent source-unknown hold is a boundary (persisted state),
# so the entry test replaces the STORE, not the judgement about whether a hold is active.
function Test-SourceUnknownHoldActive { param([string]$Buyer, [datetime]$Now) return [pscustomobject]@{ Active = [bool]$script:unknownHoldActive; Until = $null; RemainingSec = 0; Entry = $null; Reason = 'stub' } }
function Set-SourceUnknownHold { param([string]$Buyer, [string]$MessageIdentity, [int]$Minutes = 0, [datetime]$Now) return [pscustomobject]@{ Changed = $true; Until = $Now.AddMinutes(5); Reason = 'stub'; Entry = $null } }
function Add-SentRecord { param([string]$Buyer, [string]$Text, [string]$SentAt = '', [string]$Source = '') $script:sentRecords++; return $true }
function New-OrUpdate-HumanTask { param([string]$Buyer, [string]$Kind, [string]$TriggerMessage = '', [string[]]$MissingFields = @(), $FactsSnapshot = $null, [string]$Status = 'awaiting_contact', [string]$SupplierKey = '', [string]$Note = '') return [pscustomobject]@{ Task = [pscustomobject]@{ id = 't'; status = $Status }; Created = $true; Updated = $false; StoreOk = $true } }
function New-OrUpdate-SupplierVerificationTask { param([string]$Buyer, [string[]]$MissingFields = @(), [string]$SupplierContact = '', [string]$TriggerMessage = '', $FactsSnapshot = $null) return [pscustomobject]@{ Task = [pscustomobject]@{ id = 't'; status = 'pending_human' }; Created = $true; Updated = $false; StoreOk = $true } }
function Add-HumanTaskNotification { param([string]$Id, [bool]$Delivered = $false, [string]$Detail = '') return $true }
function Send-OneTalkMessageEx {
    param($buyer, $text, $Page = $null, [switch]$AlreadyOpen, [switch]$SkipConfirmation)
    $script:sends++
    $script:lockHeldAtSend = (Test-AppLockOwned 'onetalk-write')
    $receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before @() -After @([pscustomobject]@{MessageId=('fixture-send-'+[guid]::NewGuid().ToString('N'));MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$text;IsMine=$true})
    return [pscustomobject]@{ Status = 'SENT_OK'; Raw = 'FILLED | CLICKED | SENT_OK'; Buyer = $buyer; Text = $text; Confirmed = $true; Receipt=$receipt; ConfirmEvidence = 'stub'; Detail = '' }
}

function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Line([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
$item = [pscustomobject]@{ name = 'Virtual Buyer'; preview = 'unchanged'; unread = $true }

function Reset {
    $script:logs = @(); $script:sends = 0; $script:modelCalls = 0; $script:writes = 0
    $script:reads = 0; $script:sentRecords = 0; $script:retryReason = ''
    $script:roundHalt = $false; $script:ledgerBytes = 0; $script:pauseActive = $false
    $script:pauseCalls = 0; $script:ledgerHealthy = $true; $script:unknownHoldActive = $false
    $script:pageName = 'Virtual Buyer'
    $script:raw = Line 'Can you quote 10 cartons to Hamburg?' 1791170000000
    $script:raw2 = $script:raw
    $script:externalLockProbe = ''
    $ctx = @{
        state = [pscustomobject]@{ replied = [pscustomobject]@{} }
        lastSendAt = @{}; skipCooldown = @{}; openCooldown = @{}; noReplyPreview = @{}
        humanPending = @{}; sendFailCount = @{}; failAlertAt = @{}; pendingSeen = @{}
        dupGuardHolds = @{}; lastActivity = $script:now
    }
    Update-PendingSeen $ctx @($item); Update-PendingSeen $ctx @($item)
    [void](Release-AppLock 'onetalk-write')
    return $ctx
}
# 第一次读取返回 raw，发送前的复核读取返回 raw2（模拟"生成期间页面变了"）
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    $payload = $script:raw
    if ($script:reads -ge 2) { $payload = $script:raw2 }
    if ($script:reads -eq 1) {
        # 生成窗口里探测：页面锁必须已经释放
        $probe = Get-AppLock 'external-writer-probe' 0
        $script:externalLockProbe = [string]$probe
        if ($probe) { [void](Release-AppLock 'external-writer-probe') }
    }
    return [pscustomobject]@{ name = $script:pageName; msgs = $payload; profile = '' }
}

try {
    # ---------------- L1/L2/L3: lock scope + re-acquire + send under lock ----------------
    $ctx = Reset
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L1-read-phase-took-the-lock' ($log -match 'PAGE-LOCK-ACQUIRED phase=read')
    Check 'L1-lock-released-before-generation' ($log -match 'LOCK-RELEASED-FOR-GENERATION')
    Check 'L2-generation-window-is-unlocked' ($script:externalLockProbe -eq 'True') ('probe=' + $script:externalLockProbe)
    Check 'L3-lock-reacquired-before-send' ($log -match 'PAGE-LOCK-REACQUIRED phase=send')
    Eq 'L3-sent-once' $script:sends 1
    Check 'L3-send-happened-under-the-lock' ([bool]$script:lockHeldAtSend)
    Eq 'L3-ledger-written-once' $script:writes 1
    Eq 'L3-sent-record-written' $script:sentRecords 1
    Check 'L1-hold-time-logged' ($log -match 'readHoldMs=\d+')

    # ---------------- L4: buyer changed the request during generation ----------------
    $ctx = Reset
    $script:raw2 = (Line 'Can you quote 10 cartons to Hamburg?' 1791170000000) + $LF + (Line 'Actually make it 20 cartons to Berlin' 1791170009000)
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L4-stale-draft-discarded' ($log -match 'STALE-DRAFT-DISCARD')
    Check 'L4-reason-is-input-change' ($log -match 'buyer-input-changed')
    Eq 'L4-nothing-sent' $script:sends 0
    Eq 'L4-ledger-untouched' $script:writes 0
    Eq 'L4-no-sent-record' $script:sentRecords 0

    # ---------------- L5: a human replied during generation ----------------
    $ctx = Reset
    $script:raw2 = (Line 'Can you quote 10 cartons to Hamburg?' 1791170000000) + $LF + '[ME] I will take this one myself @@MT:1791170009000'
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L5-human-interjection-discards-draft' ($log -match 'STALE-DRAFT-DISCARD' -and $log -match 'human-or-unknown:human-last')
    Eq 'L5-nothing-sent' $script:sends 0

    # L5b: a hand-typed line with no per-message clock leaves the order unverifiable - also stale.
    $ctx = Reset
    $script:raw2 = (Line 'Can you quote 10 cartons to Hamburg?' 1791170000000) + $LF + '[ME] I will take this one myself'
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L5b-unverifiable-order-discards-draft' ($log -match 'STALE-DRAFT-DISCARD' -and $log -match 'order-unverified')
    Eq 'L5b-nothing-sent' $script:sends 0

    # ---------------- L6: a human pause started during generation ----------------
    $ctx = Reset
    $script:pauseActive = $true
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L6-human-pause-discards-draft' ($log -match 'STALE-DRAFT-DISCARD' -and $log -match 'human-pause-active')
    Eq 'L6-nothing-sent' $script:sends 0

    # ---------------- L7: another process holds the lock ----------------
    # 真实竞争：锁文件由**另一个存活进程**持有（这里用父 PowerShell 的 PID 模拟别的写者）。
    $ctx = Reset
    $foreignPid = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID } | Select-Object -First 1).ProcessId
    if (-not $foreignPid) { $foreignPid = 4 }
    $lockFile = Get-AppLockFile 'onetalk-write'
    [System.IO.File]::WriteAllText($lockFile, ($foreignPid.ToString() + '|2026-10-05 12:00:00|foreign'), (New-Object System.Text.ASCIIEncoding))
    $script:sleeps = 0
    Invoke-ConvoItem $ctx $item
    $log = ($script:logs -join $LF)
    Check 'L7-lock-contention-detected' ($log -match 'LOCK-BUSY')
    Eq 'L7-nothing-sent' $script:sends 0
    Check 'L7-waited-with-bounded-attempts' ($script:sleeps -ge 1) ('sleeps=' + $script:sleeps)
    Check 'L7-foreign-lock-not-deleted' (Test-Path $lockFile)
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
} finally {
    [void](Release-AppLock 'onetalk-write')
    [void](Release-AppLock 'external-writer-probe')
    Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
