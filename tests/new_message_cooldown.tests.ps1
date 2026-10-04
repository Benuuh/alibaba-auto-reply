# Offline real-entry regression. Never load monitor top-level or production config.
# Real: normalization, evidence, time gate, generation adapter/policy, state mutation.
# Fake: per-message page rows, model response, clock, persistence, attachment I/O, send.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $root 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib/msg_norm.ps1')
. (Join-Path $scripts 'lib/msg_source.ps1')
. (Join-Path $scripts 'lib/reply_policy.ps1')
. (Join-Path $scripts 'lib/reply_gen.ps1')
. (Join-Path $scripts 'lib/vision.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Monitor parse failed' }
foreach ($name in @('Invoke-ConvoItem','Invoke-ScanRound','Update-PendingSeen','Generate-Reply-LLM','Set-StateHash','Test-RepliedStateUsable')) {
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
function Get-RepliedStateFileSize { return $script:ledgerBytes }
function Set-RepliedState($state) { $script:persisted = $state | ConvertTo-Json -Depth 10; $script:writes++ }
function Repair-RepliedState { throw 'Unexpected repair' }
function Get-RepliedState { throw 'Unexpected live read' }
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
function Get-ImageDataUrl($url) { $script:imageUrl = $url; return $null }
function Get-DocumentBase64ViaCdp($url) { $script:fileUrl = $url; return $null }
function Get-DocumentBase64ViaHttp($url) { $script:fileUrl = $url; return $null }
function Get-AccioReplyLines { return $script:gatewayLines }
function Test-AccioLinesOverlap { return $true } # optimistic gateway boundary; identity still real
function Get-SkillConfig { throw 'Production config must never be read' }
function Get-SkillPath { throw 'Production paths must never be resolved' }
function Invoke-CdpEval { throw 'Browser access forbidden' }
function Start-Sleep { throw 'Blocking sleep forbidden in these entry cases' }
function Line($text, [long]$ts, $markers = '') { return '[BUYER] ' + $text + ' ' + $markers + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
$item = [pscustomobject]@{ name = 'Virtual Buyer'; preview = 'unchanged'; unread = $true }
function Reset {
    $script:logs = @(); $script:sends = 0; $script:modelCalls = 0; $script:reads = 0; $script:writes = 0
    $script:roundHalt = $false; $script:manual = $false; $script:ledgerBytes = 0
    $script:pageName = 'Virtual Buyer'; $script:sendResult = 'SENT_OK'; $script:imageUrl = ''; $script:fileUrl = ''
    $script:raw = (Line 'old request' 1791170000000) + "`n" + (Line 'new request' 1791170001000)
    $ctx = @{ state = [pscustomobject]@{ replied = [pscustomobject]@{ 'virtual buyer' = (Get-DedupKey 'old request' 1) } }; lastSendAt = @{ 'virtual buyer' = $script:now.AddSeconds(-60) }; skipCooldown = @{}; openCooldown = @{}; noReplyPreview = @{}; humanPending = @{}; sendFailCount = @{}; failAlertAt = @{}; pendingSeen = @{}; dupGuardHolds = @{}; lastActivity = $script:now }
    Update-PendingSeen $ctx @($item); Update-PendingSeen $ctx @($item)
    return $ctx
}
function Cache($ctx, $reason = 'POST_SEND_COOLDOWN', $buyers = 1) { $ctx.skipCooldown[$item.name] = @{ time = $script:now.AddSeconds(-60); until = $ctx.lastSendAt['virtual buyer'].AddMinutes(5); pkey = 'unchanged'; preview = 'unchanged'; buyers = $buyers; count = 1; reason = $reason; nextVerifyAt = $script:now } }

$ctx = Reset; Invoke-ConvoItem $ctx $item
Check 'A1 new text at 60s reaches generation/send with five minute configs' ($script:sends -eq 1 -and $script:modelCalls -gt 0)
$ctx = Reset; $script:raw = Line 'edited latest request' 1791170001000; Invoke-ConvoItem $ctx $item
Check 'A1 equal count changed original hash is positive evidence' ($script:sends -eq 1 -and ($script:logs -match 'confirmedNew=True'))
$ctx = Reset; $ctx.lastSendAt['virtual buyer'] = $script:now.AddSeconds(-19.999); Invoke-ConvoItem $ctx $item
Check 'A2 19.999s blocks before generation' ($script:sends -eq 0 -and $script:modelCalls -eq 0 -and ($script:logs -match 'NEW_MESSAGE_FLOOR'))
Check 'A2 floor deadline anchored to successful send' ($ctx.skipCooldown[$item.name].until -eq $ctx.lastSendAt['virtual buyer'].AddSeconds(20))
$deadline = $ctx.skipCooldown[$item.name].until
Invoke-ConvoItem $ctx $item
Check 'A2 repeated scans do not move deadline' ($ctx.skipCooldown[$item.name].until -eq $deadline)
$script:now = $script:now.AddMilliseconds(1); Invoke-ConvoItem $ctx $item
Check 'A2 exactly 20.000s sends without five minute wait' ($script:sends -eq 1)
$ctx = Reset; $script:raw = (Line 'old request' 1791170000000) + "`n" + (Line 'old request' 1791170001000); Cache $ctx
Invoke-ConvoItem $ctx $item
Check 'A3 same text count increased unchanged preview periodically read and sent' ($script:reads -eq 1 -and $script:sends -eq 1)
$script:now = $script:now.AddSeconds(20); Invoke-ConvoItem $ctx $item
Check 'A3 success scans do not resend same text message' ($script:sends -eq 1)

foreach ($kind in @('image','file')) {
    $ctx = Reset; Cache $ctx
    $markers = if ($kind -eq 'image') { '@@IMG:https://example.invalid/new.png' } else { '@@FILE:new.pdf|https://example.invalid/new.pdf' }
    $script:raw = (Line 'old request' 1791170000000 '@@IMG:https://example.invalid/old.png') + "`n" + (Line '[IMG]' 1791170001000 $markers)
    Invoke-ConvoItem $ctx $item
    Check "A4 $kind unchanged preview read and sent" ($script:reads -eq 1 -and $script:sends -eq 1)
    $selected = if ($kind -eq 'image') { $script:imageUrl } else { $script:fileUrl }
    Check "A4 $kind latest attachment selected" ($selected -match '/new\.')
    Check "A4 $kind ledger matches normalized current row" ($ctx.state.replied['virtual buyer'] -eq (Get-DedupKey '[IMG]' 2))
}
foreach ($preview in @('translation changed','unread 99','our reply preview')) {
    $ctx = Reset; $script:raw = '[BUYER] translated UI text @@TS:1791170000000 @@MT:1791170000000 @@OT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('old request')); Cache $ctx
    $noiseItem = [pscustomobject]@{ name = $item.name; preview = $preview; unread = $true }
    Invoke-ConvoItem $ctx $noiseItem
    Check "A5 $preview reads but does not generate/send" ($script:reads -eq 1 -and $script:modelCalls -eq 0 -and $script:sends -eq 0)
}
$ctx = Reset; $script:raw = Line 'old request' 1791170000000; Cache $ctx
Invoke-ConvoItem $ctx $item; $script:now = $script:now.AddMinutes(6); Invoke-ConvoItem $ctx $item
Check 'A6 answered old message blocked inside and beyond cooldown' ($script:sends -eq 0 -and $script:modelCalls -eq 0 -and $script:reads -eq 2)
$script:now = $script:now.AddSeconds(20); Invoke-ConvoItem $ctx $item
Check 'A6 verified repeated old-message holds retain third-hold alert' ($script:sends -eq 0 -and $ctx.dupGuardHolds['virtual buyer'] -eq 3 -and ($script:logs -match 'DUP-GUARD-ALERT'))

foreach ($key in @('', 'ABC', '|1', 'ABC|oops', 'ABC|2147483648', 'ABC|1|extra', 'ABC|0', 'ABC|-1')) {
    $ctx = Reset; $ctx.state.replied.'virtual buyer' = $key; Invoke-ConvoItem $ctx $item
    Check "A7 bad key [$key] no exemption or exception" ($script:sends -eq 0 -and ($script:logs -match 'confirmedNew=False') -and ($script:logs -match 'Reason=POST_SEND_COOLDOWN'))
    Check "A7 bad key [$key] not false confirmation log" (-not ($script:logs -match 'COOLDOWN-LIFT'))
}
$ctx = Reset; $ctx.state.replied.'virtual buyer' = Get-DedupKey 'old request' 3; Invoke-ConvoItem $ctx $item
Check 'A7 count decrease changed hash no exemption' ($script:sends -eq 0 -and ($script:logs -match 'confirmedNew=False'))
$ctx = Reset; $script:raw = (Line 'old request' 1791170000000) + "`n" + (Line 'new request' 1791170001000) + "`n" + (Line 'new request' 1791170001000); Invoke-ConvoItem $ctx $item
Check 'A7 collision marks latest identity untrusted' ($script:sends -eq 0 -and ($script:logs -match 'trusted=False'))
$ctx = Reset; $script:raw = '[BUYER] request without message time'; Invoke-ConvoItem $ctx $item
Check 'A7 missing latest time identity keeps ordinary minute gate' ($script:sends -eq 0 -and ($script:logs -match 'trusted=False') -and ($script:logs -match 'POST_SEND_COOLDOWN'))
$ctx = Reset; Cache $ctx; $ctx.state.replied.'virtual buyer' = 'legacy'; Invoke-ConvoItem $ctx $item
Check 'A7 unreadable key recheck is not logged as confirmed lift' ($script:reads -eq 1 -and $script:sends -eq 0 -and -not ($script:logs -match 'COOLDOWN-LIFT'))

foreach ($reason in @('POST_SEND_COOLDOWN','RATE_MIN_GAP')) {
    $ctx = Reset; $ctx.state.replied.'virtual buyer' = 'legacy'; $ctx.lastSendAt['virtual buyer'] = $script:now.AddSeconds(-299.999)
    if ($reason -eq 'RATE_MIN_GAP') { $script:replyPostSendCooldownMin = 0 }
    Invoke-ConvoItem $ctx $item
    Check "A8 $reason 299.999s blocked" ($script:sends -eq 0 -and ($script:logs -match "Reason=$reason"))
    Check "A8 $reason deadline anchored" ($ctx.skipCooldown[$item.name].until -eq $ctx.lastSendAt['virtual buyer'].AddMinutes(5))
    $until = $ctx.skipCooldown[$item.name].until; Invoke-ConvoItem $ctx $item
    Check "A8 $reason repeated scan preserves deadline" ($ctx.skipCooldown[$item.name].until -eq $until)
    $script:now = $script:now.AddMilliseconds(1); Invoke-ConvoItem $ctx $item
    Check "A8 $reason exactly 300.000s can send" ($script:sends -eq 1)
    $script:replyPostSendCooldownMin = 5
}

$ctx = Reset; $script:manual = $true; $ctx.noReplyPreview[$item.name] = $item.preview; Invoke-ConvoItem $ctx $item
Check 'A9 whitelist remains first and blocks even page read' ($script:sends -eq 0 -and $script:reads -eq 0)
$ctx = Reset; $script:raw = (Line 'request' 1791170000000) + "`n[ME] Human intervened @@MT:1791170001000"; Invoke-ConvoItem $ctx $item
Check 'A9 real human interjection gate blocks' ($script:sends -eq 0 -and $ctx.skipCooldown[$item.name].reason -eq 'HUMAN_INTERJECTION')
$script:now = $script:now.AddSeconds(20); $script:raw = (Line 'later request' 1791170002000); Invoke-ConvoItem $ctx $item
Check 'A9 explicit human hold not cancelled by periodic scheduler' ($script:reads -eq 1 -and $script:sends -eq 0)
$ctx = Reset; $script:raw = (Line 'one' 1791170000000) + "`n" + (Line 'two' 1791170002000) + "`n" + (Line 'three' 1791170001000); Invoke-ConvoItem $ctx $item
Check 'A9 untrusted order blocks before generation' ($script:sends -eq 0 -and $script:modelCalls -eq 0)
$ctx = Reset; $script:raw = Line 'system listing' 1791170000000 '@@CARD:system'; Invoke-ConvoItem $ctx $item
Check 'A9 latest system card blocked' ($script:sends -eq 0 -and ($script:logs -match 'latest-buyer-system-card'))
$ctx = Reset; $ctx.state = $null; $script:ledgerBytes = 1024; Invoke-ConvoItem $ctx $item
Check 'A9 real ledger usability blocks new message' ($script:sends -eq 0 -and ($script:logs -match 'LEDGER_UNUSABLE_FAILCLOSED'))
$ctx = Reset; $script:pageName = 'Other Person'; Invoke-ConvoItem $ctx $item
Check 'A9 opened wrong identity halts before evidence/send' ($script:roundHalt -and $script:sends -eq 0 -and $script:modelCalls -eq 0 -and ($script:logs -match 'ABORT_WRONG_CONVO'))
$ctx = Reset; $script:sendResult = 'ABORT_WRONG_CONVO'; Invoke-ConvoItem $ctx $item; $before = $script:sends; Invoke-ConvoItem $ctx $item
Check 'A9 final send identity abort halts remaining entries without state write' ($script:roundHalt -and $script:sends -eq $before -and $script:writes -eq 0)
$ctx = Reset; Invoke-ConvoItem $ctx $item 1
Check 'A9 startup observation blocks all reads/model/send' ($script:sends -eq 0 -and $script:reads -eq 0 -and $script:modelCalls -eq 0)
$ctx = Reset; $ctx.pendingSeen[$item.name] = 1; Invoke-ConvoItem $ctx $item
Check 'A9 insufficient consecutive rounds do not install cooldown' ($script:sends -eq 0 -and -not $ctx.skipCooldown.ContainsKey($item.name))

$ctx = Reset; $ctx.lastSendAt['virtual buyer'] = $script:now.AddSeconds(-19); Invoke-ConvoItem $ctx $item
$script:raw += "`n" + (Line 'newest input 77 kg' 1791170002000); $script:now = $script:now.AddSeconds(1); Invoke-ConvoItem $ctx $item
Check 'A10 wait uses fresh latest input at expiry' ($script:sends -eq 1 -and $script:modelInput -match '77 kg' -and $ctx.state.replied['virtual buyer'] -eq (Get-DedupKey (Get-NormalizedMsgText 'newest input 77 kg') 3))

foreach ($seconds in @(19,60)) {
    $ctx = Reset; $ctx.lastSendAt['virtual buyer'] = $script:now.AddSeconds(-$seconds)
    if ($seconds -eq 60) { $ctx.state.replied.'virtual buyer' = 'legacy' }
    Invoke-ConvoItem $ctx $item; $firstAt = $ctx.lastSendAt['virtual buyer']; $firstWait = $ctx.skipCooldown[$item.name].until
    $other = [pscustomobject]@{ name = 'Second Buyer'; preview = 'unchanged' }; $ctx.pendingSeen[$other.name] = 2; $script:pageName = $other.name
    Invoke-ConvoItem $ctx $other
    Check "A11 $seconds second buyer independent no global wait" ($script:sends -eq 1 -and $ctx.lastSendAt['virtual buyer'] -eq $firstAt -and $ctx.skipCooldown[$item.name].until -eq $firstWait)
}

$ctx = Reset; $script:sendResult = 'SEND_FAILED'; $saved = $ctx.state.replied.'virtual buyer'; $sentAt = $ctx.lastSendAt['virtual buyer']; Invoke-ConvoItem $ctx $item
Check 'A12 failed send consumes neither ledger nor successful-send clock' ($script:writes -eq 0 -and $ctx.state.replied.'virtual buyer' -eq $saved -and $ctx.lastSendAt['virtual buyer'] -eq $sentAt)
$script:now = $script:now.AddMinutes(3); $script:sendResult = 'SENT_OK'; Invoke-ConvoItem $ctx $item
Check 'A12 failed message retried after original open backoff' ($script:sends -eq 2 -and $script:writes -eq 1)
$script:now = $script:now.AddSeconds(20); Invoke-ConvoItem $ctx $item
Check 'A12 successful in-memory dictionary ledger dedups' ($script:sends -eq 2 -and $script:writes -eq 1)
$diskState = $script:persisted | ConvertFrom-Json; $ctx = Reset; $ctx.state = $diskState; $ctx.lastSendAt = @{}; Invoke-ConvoItem $ctx $item 1; Invoke-ConvoItem $ctx $item 2
Check 'A12 context rebuild retains persisted HASH/count dedup without clearing ledger' ($script:sends -eq 0 -and $script:writes -eq 0)

# Old caches missing scheduling/source fields must never get their deadline reset on reads.
foreach ($buyers in @(1,-1)) {
    $ctx = Reset; Cache $ctx 'POST_SEND_COOLDOWN' $buyers; $ctx.skipCooldown[$item.name].Remove('reason'); $ctx.skipCooldown[$item.name].Remove('nextVerifyAt'); $ctx.skipCooldown[$item.name].Remove('until')
    Invoke-ConvoItem $ctx $item
    Check "legacy cache buyers=$buyers finite fallback permits guarded read" ($script:reads -eq 1 -and $script:sends -eq 1)
}
$ctx = Reset; Cache $ctx; $ctx.skipCooldown[$item.name].nextVerifyAt = $script:now.AddSeconds(20); Invoke-ConvoItem $ctx $item
Check 'read cache before interval avoids unnecessary generation and read' ($script:reads -eq 0 -and $script:modelCalls -eq 0)
$script:now = $script:now.AddSeconds(20); Invoke-ConvoItem $ctx $item
Check 'read cache exact 20s interval discovers new input' ($script:reads -eq 1 -and $script:sends -eq 1)
$ctx = Reset; Check 'A13 five minute configs retained in entry test' ($script:replyMinGapMin -eq 5 -and $script:replyPostSendCooldownMin -eq 5); Invoke-ConvoItem $ctx $item
Check 'A13 new input actually sends with five minute configuration' ($script:sends -eq 1)
$ctx = Reset; $script:accioFlags.read = $true; $script:gatewayLines = @((Line 'gateway-only earlier data' 1791169999000),(Line 'new request' 1791170003000)); Invoke-ConvoItem $ctx $item
Check 'A13 Accio latest text alone cannot replace CDP latest identity' ($script:sends -eq 1 -and ($script:logs -match 'ACCIO-READ src=cdp') -and $script:modelInput -notmatch 'gateway-only earlier data')
$script:accioFlags.read = $false
$ctx = Reset; $ctx.state = [pscustomobject]@{ replied = [pscustomobject]@{} }; $ctx.lastSendAt = @{}; $script:raw = Line 'first request' 1791170000000; Invoke-ConvoItem $ctx $item
Check 'A14 first buyer without key or successful-send time can reply' ($script:sends -eq 1 -and $script:writes -eq 1)

# Warehouse destination regression through the real production entry, including send-time defence.
$ctx = Reset; $script:raw = Line '18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1' 1791170001000
Invoke-ConvoItem $ctx $item
Check 'B2 real entry rejects model destination-city question and sends fallback' ($script:sends -eq 1 -and $script:modelCalls -eq 2 -and $script:sentText -notmatch 'address|city|postal|zip|warehouse code')
$adapterBody = (Get-Command Generate-Reply-LLM).ScriptBlock
function Generate-Reply-LLM { return 'Please send the delivery address.' }
$ctx = Reset; $script:raw = Line '18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1' 1791170001000
Invoke-ConvoItem $ctx $item
Check 'B2 actual send-time gate rejects a bypassed dirty adapter result' ($script:sends -eq 1 -and ($script:logs -match 'DESTINATION_REASK') -and $script:sentText -notmatch 'address|city|postal|zip|warehouse code')
Set-Item Function:Generate-Reply-LLM $adapterBody
$ctx = Reset; $script:manual = $true; $script:raw = Line 'Amazon FTW1' 1791170001000; Invoke-ConvoItem $ctx $item
Check 'B14 warehouse destination never overrides manual takeover' ($script:sends -eq 0 -and $script:modelCalls -eq 0)
$ctx = Reset; $script:raw = (Line 'Amazon FTW1' 1791170000000) + "`n[ME] Owner answered @@MT:1791170001000"; Invoke-ConvoItem $ctx $item
Check 'B14 warehouse destination never overrides real human interjection' ($script:sends -eq 0 -and $script:modelCalls -eq 0)

# Real scan entry, external lock/page-health boundaries mocked. Page-down returns before
# handlers; lock-busy returns before even a snapshot. Unexpected healing throws.
function Get-AppLock { return $script:lockAvailable }
function Release-AppLock { $script:releases++ }
function Get-Snapshot { return '[{"name":"Virtual Buyer","preview":"unchanged"}]' }
function Get-RepliedState { return $script:scanState }
function Test-OneTalkPagePresent { return $script:pagePresent }
function Test-PageHealth { return [pscustomobject]@{ PageDown = $script:pageDown; Reason = 'offline'; Items = 1 } }
function Invoke-PageHealFromGate { throw 'Unexpected process recovery' }
function Invoke-CdpSelfHeal { throw 'Unexpected browser recovery' }
function Get-PageHealAction { throw 'Unexpected heal scheduling' }
function Invoke-PageReload { throw 'Unexpected browser reload' }
$ctx = Reset; $script:lockAvailable = $false; $script:scanState = $ctx.state; $script:releases = 0
$result = Invoke-ScanRound $ctx
Check 'A9 real scan write lock busy skips all processing' ($result.Action -eq 'LockBusy' -and $script:reads -eq 0 -and $script:sends -eq 0)
foreach ($missing in @($true,$false)) {
    $ctx = Reset; $script:scanState = $ctx.state; $script:lockAvailable = $true; $script:pagePresent = -not $missing; $script:pageDown = -not $missing; $script:pageDownStreak = 0
    Invoke-ScanRound $ctx | Out-Null
    Check "A9 real scan page missing=$missing blocks pending handlers" ($script:reads -eq 0 -and $script:sends -eq 0 -and ($script:logs -match 'ABORT-PAGE-DOWN'))
}
# Release review: every send candidate, including the last holding line, must pass policy.
$ctx = Reset; $script:raw = Line '18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1' 1791170001000
$fallbackBody = (Get-Command Get-ScenarioFallback).ScriptBlock
$holdingLine = $script:banSafeFallback
$adapterBody = (Get-Command Generate-Reply-LLM).ScriptBlock
try {
    function Generate-Reply-LLM { return 'Please send the delivery address.' }
    function Get-ScenarioFallback { return 'Please send the delivery address.' }
    $script:banSafeFallback = 'Please send the delivery address.'
    Invoke-ConvoItem $ctx $item
    Check 'release final holding line cannot bypass destination policy or advance state' ($script:sends -eq 0 -and $script:writes -eq 0)
} finally {
    Set-Item Function:Generate-Reply-LLM $adapterBody
    Set-Item Function:Get-ScenarioFallback $fallbackBody
    $script:banSafeFallback = $holdingLine
}
Write-Output "RESULT pass=$script:pass fail=$script:fail"
if ($script:fail) { exit 1 }
