# Offline real-entry regression. Never load monitor top-level or production config.
# [2026-10-05 spec §6.2] A SUCCESSFUL send now costs TWO page reads: the snapshot read that feeds
# generation, and the send-time re-verification read taken after the page lock is re-acquired. Cases
# that expect a send therefore assert reads==2; cases that never reach the send still assert reads==1.
# Real: normalization, evidence, time gate, generation adapter/policy, state mutation.
# Fake: per-message page rows, model response, clock, persistence, attachment I/O, send.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
# [2026-10-07 spec §3.2 第 3 条] 无发送者证据的 [ME] 行现在是 unknown，不再外推为人工。
#   夹具用逐条已验证的发送者字段提供人工来源证据（字段在 @@META 载荷里，正文无法伪造）。
. (Join-Path $scripts 'lib\msg_events.ps1')
[void](Set-MessageSourceContext -Rules (New-MessageSourceRuleSet -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified-owner-field'))
function New-OwnerMeta([string]$text, [long]$ts) {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'; t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        dir = 'out'; dirsrc = 'layout'; mid = ''; ts = $ts; tprec = 'second'; st = 'message'
        src = @(); f = @('sender=owner'); at = '2026-10-05T00:00:00Z'; idq = 'composite'
    }))
}
function OwnerLine([string]$text, [long]$ts) { return ('[ME] ' + $text + ' @@MT:' + $ts + ' ' + (New-OwnerMeta $text $ts)) }
. (Join-Path $scripts 'lib/sent_records.ps1')
. (Join-Path $scripts 'lib/msg_norm.ps1')
. (Join-Path $scripts 'lib/msg_source.ps1')
. (Join-Path $scripts 'lib/reply_policy.ps1')
. (Join-Path $scripts 'lib/reply_gen.ps1')
. (Join-Path $scripts 'lib/vision.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Monitor parse failed' }
foreach ($name in @('Invoke-ConvoItem', 'Get-MonitorSourceGate', 'Get-MonitorSourceRules', 'Get-MonitorSourceConfirmed', 'New-MonitorInvestigation', 'New-SourceUnknownInvestigation', 'Invoke-MonitorInvestigationSweep', 'Invoke-MonitorInvestigationRetention','Invoke-ScanRound','Update-PendingSeen','Generate-Reply-LLM','Set-StateHash','Test-RepliedStateUsable','Get-TaskContextForConvo','Get-LedgerHealth','Reset-LedgerHealthCache','Get-CachedDocumentRead','Test-LedgerShape','Get-ReplyEntryCount','Test-PageConfirmedSendResult','Test-ReconciledDeliveryEvidence','Complete-ReconciledDelivery')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
$script:now = [datetime]'2026-10-05T12:00:00'
function Get-Date { param([string]$Format) if ($Format) { return $script:now.ToString($Format) }; return $script:now }
$script:dataDir = Join-Path $env:TEMP 'aar_cooldown_memory_only'
$logFile = $null
$script:replyMinGapMin = 5; $script:replyPostSendCooldownMin = 5
$script:replyNewMsgFloorSec = 20; $script:requiredSeenRounds = 2; $script:replyRoundBudgetSec = 180
$script:accioFlags = @{ shadow = $false; read = $false }
$script:pass = 0; $script:fail = 0
function Check($name, [bool]$ok) { if ($ok) { $script:pass++ } else { $script:fail++; Write-Output "FAIL $name"; $script:logs | Write-Output } }
function Write-Log($text) { $script:logs += $text }
function Add-Content { param($Path,$Value,$Encoding) if (-not $Path.StartsWith($script:dataDir)) { throw 'Unexpected write path' } }
# [2026-10-05 spec §5 A5] The ledger STATE comes from Get-LedgerHealth; only that boundary is
# stubbed, so the production usability judgement is what these cases exercise.
$script:stateFile = Join-Path $env:TEMP 'aar_cooldown_memory_only_state.json'
$script:ledgerBytes = 0
# A1/A9: "the ledger exists and is substantial but cannot be read" is a STATE, not a size guess.
$script:ledgerUnreadable = $false
function Get-LedgerHealth {
    $status = 'valid'
    if ($script:ledgerBytes -lt 0 -or $script:ledgerUnreadable) { $status = 'corrupt' }
    $data = $null
    if ($status -eq 'valid') { $data = [pscustomobject]@{ replied = [pscustomobject]@{ 'virtual buyer' = 'seed|1' } } }
    return [pscustomobject]@{ Status = $status; Data = $data; Bytes = [long][Math]::Abs($script:ledgerBytes); Error = ''; Path = $script:stateFile; Source = 'stub'; Count = 1; Recovered = $false; Reasons = @() }
}
function Get-RepliedStateFileSize { return [long][Math]::Abs($script:ledgerBytes) }
function Set-RepliedState($state) { $script:persisted = $state | ConvertTo-Json -Depth 10; $script:writes++ }
function Repair-RepliedState { throw 'Unexpected repair' }
function Get-RepliedState { return (Get-LedgerHealth).Data }
function Test-SourceUnknownHoldActive { param([string]$Buyer, [datetime]$Now) return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $null; Reason = 'stub' } }
function Set-SourceUnknownHold { param([string]$Buyer, [string]$MessageIdentity, [int]$Minutes = 0, [datetime]$Now) return [pscustomobject]@{ Changed = $true; Until = $null; Reason = 'stub'; Entry = $null } }
function Test-NoReplyBuyer { return $script:manual }
function Save-BuyerProfile { }
function Write-LocalAlert { }
function Clear-LocalAlert { }
function Send-WecomMessage { $script:notifications++; return 'OFFLINE' }
function Send-NewInquiryAlert { $script:notifications++ }
function Remove-PendingRetry { }
function Add-PendingRetry { }
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
function Invoke-LLM { param($Messages,$Temperature,$MaxTokens,$LogFile) $script:modelCalls++; $script:modelInput = $Messages | ConvertTo-Json -Depth 20; return 'Could you confirm the destination city?' }
function Open-ConvoAndGetMessages($name) { $script:reads++; return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' } }
function Send-OneTalkMessage($name,$text) { $script:sends++; $script:sentText = $text; return $script:sendResult }
# [2026-10-05 spec §5-3] The production entry consumes the STRUCTURED send result. The page
# confirmation is its own boundary, so this stub reports the page action's outcome as confirmed
# unless a test explicitly asks for the unclear-receipt path.
function Send-OneTalkMessageEx {
    param($buyer, $text, $Page = $null, [switch]$AlreadyOpen, [switch]$SkipConfirmation, [string]$AttemptId = '')
    $raw = Send-OneTalkMessage $buyer $text
    $st = 'FAILED'
    if ($raw -match 'ABORT_WRONG_CONVO') { $st = 'FAILED' }
    elseif ($raw -match 'SENT_OK') { if ($script:sendConfirm -eq 'absent') { $st = 'UNKNOWN' } else { $st = 'SENT_OK' } }
    $receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before @() -After @([pscustomobject]@{MessageId=('fixture-send-'+[guid]::NewGuid().ToString('N'));MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$text;IsMine=$true})
    return [pscustomobject]@{ Status = $st; Raw = [string]$raw; Buyer = $buyer; Text = $text; Confirmed = ($st -eq 'SENT_OK'); Receipt=$receipt; ConfirmEvidence = 'stub'; Detail = '' }
}
function Get-ImageDataUrl($url) { $script:imageUrl = $url; return $null }
function Get-DocumentBase64ViaCdp($url) { $script:fileUrl = $url; return $null }
function Get-DocumentBase64ViaHttp($url) { $script:fileUrl = $url; return $null }
function Get-AccioReplyLines { return $script:gatewayLines }
function Test-AccioLinesOverlap { return $true } # optimistic gateway boundary; identity still real
function Get-SkillConfig { throw 'Production config must never be read' }
function Get-SkillPath { throw 'Production paths must never be resolved' }
function Invoke-CdpEval { throw 'Browser access forbidden' }
function Start-Sleep { throw 'Blocking sleep forbidden in these entry cases' }
# [2026-10-05 spec §2.1/§2.2/§4/§6.2] Boundaries added by the architecture-optimisation round:
#   the page lock, the human-pause store, the sent-record store and the human-task store are all
#   BOUNDARIES. The entry test replaces them, so no runtime state leaves the process.
function Get-AppLock { param([string]$name, [int]$timeoutSec = 10) return $true }
function Release-AppLock { param([string]$name) return $true }
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{} }
function Update-HumanPauseFromLines {
    param([string]$Buyer, [string[]]$Lines, $SentMatches = $null, [datetime]$Now = ([datetime]::Now))
    return [pscustomobject]@{ Started = $false; Changed = $false; Until = $null; Reason = 'stub'; HumanIndex = -1; Identity = '' }
}
function Test-HumanPauseActive {
    param([string]$Buyer, [datetime]$Now = ([datetime]::Now))
    return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $null; Reason = 'stub' }
}
# [2026-10-05 八项补修 F2 §4.1 第 1/2 条] 读取与发送前共用的编排入口。本文件把暂停/等待的**存储**
#   当作边界（上面的 Test-HumanPauseActive / Test-SourceUnknownHoldActive 已经是桩），因此同步入口
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
function Get-ActionEvidenceForBuyer { param([string]$Buyer = '', [string]$Kind = '') return (New-ActionEvidence -Values $null) }
function Add-SentRecord { param([string]$Buyer, [string]$Text, [string]$SentAt = '', [string]$Source = '') return $true }
function New-OrUpdate-HumanTask {
    param([string]$Buyer, [string]$Kind, [string]$TriggerMessage = '', [string[]]$MissingFields = @(), $FactsSnapshot = $null, [string]$Status = 'awaiting_contact', [string]$SupplierKey = '', [string]$Note = '')
    return [pscustomobject]@{ Task = [pscustomobject]@{ id = 'stub-task'; status = $Status }; Created = $true; Updated = $false; StoreOk = $true }
}
function New-OrUpdate-SupplierVerificationTask {
    param([string]$Buyer, [string[]]$MissingFields = @(), [string]$SupplierContact = '', [string]$TriggerMessage = '', $FactsSnapshot = $null)
    return [pscustomobject]@{ Task = [pscustomobject]@{ id = 'stub-sup'; status = 'pending_human' }; Created = $true; Updated = $false; StoreOk = $true }
}
function Add-HumanTaskNotification { param([string]$Id, [bool]$Delivered = $false, [string]$Detail = '') return $true }
function Line($text, [long]$ts, $markers = '') { return '[BUYER] ' + $text + ' ' + $markers + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
$item = [pscustomobject]@{ name = 'Virtual Buyer'; preview = 'unchanged'; unread = $true }
function Reset {
    $script:logs = @(); $script:sends = 0; $script:modelCalls = 0; $script:reads = 0; $script:writes = 0
    $script:roundHalt = $false; $script:manual = $false; $script:ledgerBytes = 0
    $script:pageName = 'Virtual Buyer'; $script:sendResult = 'SENT_OK'; $script:imageUrl = ''; $script:fileUrl = ''
    $script:sendConfirm = 'confirmed'
    $script:raw = (Line 'old request' 1791170000000) + "`n" + (Line 'new request' 1791170001000)
    $ctx = @{ state = [pscustomobject]@{ replied = [pscustomobject]@{ 'virtual buyer' = (Get-DedupKey 'old request' 1) } }; lastSendAt = @{ 'virtual buyer' = $script:now.AddSeconds(-60) }; skipCooldown = @{}; openCooldown = @{}; noReplyPreview = @{}; humanPending = @{}; sendFailCount = @{}; failAlertAt = @{}; pendingSeen = @{}; dupGuardHolds = @{}; lastActivity = $script:now }
    Update-PendingSeen $ctx @($item); Update-PendingSeen $ctx @($item)
    return $ctx
}
function Cache($ctx, $reason = 'POST_SEND_COOLDOWN', $buyers = 1) { $ctx.skipCooldown[$item.name] = @{ time = $script:now.AddSeconds(-60); until = $ctx.lastSendAt['virtual buyer'].AddMinutes(5); pkey = 'unchanged'; preview = 'unchanged'; buyers = $buyers; count = 1; reason = $reason; nextVerifyAt = $script:now } }

# Current contract: one pending occurrence is sufficient, regardless of old timers.
function Get-Snapshot { return $script:pendingJson }
foreach($age in @(0,1,19,60,299)){
    $ctx=Reset; $script:pendingJson='[{"name":"Virtual Buyer"}]'
    $ctx.lastSendAt['virtual buyer']=$script:now.AddSeconds(-$age)
    $ctx.pendingSeen[$item.name]=1; Cache $ctx
    $ctx.openCooldown[$item.name]=$script:now
    Invoke-ConvoItem $ctx $item 1
    Check "pending at ${age}s sends without floor/coldstart/cache wait" ($script:sends -eq 1 -and $script:reads -eq 2)
    Invoke-ConvoItem $ctx $item
    Check "same answer at ${age}s never resends" ($script:sends -eq 1 -and $script:modelCalls -eq 2)
}
foreach($ledger in @('', 'ABC', '|1', 'ABC|oops', 'ABC|2147483648', 'ABC|0')){
    $ctx=Reset; $ctx.state.replied.'virtual buyer'=$ledger
    Invoke-ConvoItem $ctx $item
    Check "legacy unusable key [$ledger] cannot add a five minute delay" ($script:sends -eq 1)
}
$ctx=Reset; $script:raw=Line 'old request' 1791170000000; Cache $ctx
Invoke-ConvoItem $ctx $item
Check 'stale pending already answered does not generate or send' ($script:sends -eq 0 -and $script:modelCalls -eq 0 -and $script:reads -eq 1)
foreach($role in @('unknown','human')){
    $ctx=Reset
    $tail=if($role -eq 'human'){OwnerLine 'Welcome from owner' 1791170002000}else{'[ME] Welcome from reception @@MT:1791170002000'}
    $script:raw += "`n"+$tail
    Invoke-ConvoItem $ctx $item
    Check "pending me-tail $role is processed without inferred wait" ($script:sends -eq 1)
}
$ctx=Reset; $script:manual=$true; Invoke-ConvoItem $ctx $item
Check 'explicit manual whitelist still prevents automated send' ($script:sends -eq 0 -and $script:modelCalls -eq 0)
$ctx=Reset; $script:pageName='Virtual Buyer Extra'; Invoke-ConvoItem $ctx $item
Check 'partial name is refused' ($script:sends -eq 0 -and $script:roundHalt)
$ctx=Reset; $script:ledgerBytes=-1; Invoke-ConvoItem $ctx $item
Check 'unreadable ledger prevents send' ($script:sends -eq 0)
$ctx=Reset; $script:pendingJson='[]'; Invoke-ConvoItem $ctx $item
Check 'leaving pending during generation discards draft' ($script:sends -eq 0 -and $script:reads -eq 1 -and ($script:logs -match 'no longer in pending list'))
$ctx=Reset; $script:pendingJson='ERROR'; Invoke-ConvoItem $ctx $item
Check 'unreadable final pending list prevents send' ($script:sends -eq 0)
$script:pendingJson='[{"name":"Virtual Buyer"}]'
foreach($kind in @('image','file')){
    $ctx=Reset
    $marker=if($kind -eq 'image'){'@@IMG:https://example.invalid/new.png'}else{'@@FILE:new.pdf|https://example.invalid/new.pdf'}
    $script:raw=(Line 'old request' 1791170000000)+"`n"+(Line '[IMG]' 1791170001000 $marker)
    Invoke-ConvoItem $ctx $item
    Check "$kind pending newest attachment sends" ($script:sends -eq 1)
    $selected=if($kind -eq 'image'){$script:imageUrl}else{$script:fileUrl}
    Check "$kind selects newest attachment" ($selected -match '/new\.')
}
$latest=(ConvertTo-MessageList (Line 'same text' 1791170001000) 'Virtual Buyer').LatestBuyer
$old=(ConvertTo-MessageList (Line 'same text' 1791170000000) 'Virtual Buyer').LatestBuyer
$attempt=[pscustomobject]@{triggerIdentity=$old.StableId;receipt=[pscustomobject]@{Valid=$true}}
$ledger=Get-DedupKey 'same text' 1
Check 'confirmed old event does not block same text new event' (-not (Test-PendingBuyerAlreadyAnswered $latest $ledger 1 @($attempt)))
$attempt.triggerIdentity=$latest.StableId
Check 'confirmed receipt for exact event prevents repeat' (Test-PendingBuyerAlreadyAnswered $latest $ledger 1 @($attempt))
Check 'no pending means no reply' (-not (Test-ShouldReply -PendingListAuthoritative -PendingSeenRounds 0).Reply)
Write-Output "RESULT pass=$script:pass fail=$script:fail"
if($script:fail){exit 1}