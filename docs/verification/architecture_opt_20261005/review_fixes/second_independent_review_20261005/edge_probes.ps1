$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$harness = Get-Content -LiteralPath (Join-Path $repo 'tests\review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut = $harness.IndexOf('$ts0 = [long]1791172800000')
if ($cut -lt 0) { throw 'Missing harness boundary' }
$prefix = $harness.Substring(0, $cut).Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + ''''))
Invoke-Expression $prefix
$script:reviewPass = 0
$script:reviewFailures = New-Object System.Collections.ArrayList
function Expect-Review([string]$Name,[bool]$Ok) {
    if($Ok) { $script:reviewPass++ } else { [void]$script:reviewFailures.Add($Name) }
}
function Out-Probe([string]$Name, $Data) { [pscustomobject]@{Probe=$Name;Data=$Data} | ConvertTo-Json -Depth 8 -Compress | Write-Output }
function Check-Text([string]$Name,[string]$Text,$Decision) {
    $v = Test-ReplyCompliance -Text $Text -Rules $null -Decision $Decision
    $script:lastReviewCheck = $v
    Out-Probe $Name @{Text=$Text;Ok=$v.Ok;Codes=@($v.Violations | ForEach-Object {$_.Code})}
}
Set-FixNow '2026-10-05T12:00:00'
$ts = [long]1791172800000
$contactDecision = [pscustomobject]@{AskFields=@('supplier');Facts=$null;RequestedFacts=@();ActionEvidence=$null}
foreach($txt in @(
    "Please share the supplier's contact details for packing and your phone number.",
    "Please share the supplier's contact details for packing and contact details so we can reach you.",
    "Please share contact details for delivery updates and the supplier's phone number for packing.",
    "Please share the supplier's contact details for packing, plus your email address.",
    "Please share the recipient's phone number for delivery."
)) { Check-Text 'contact-conjunction-and-scope' $txt $contactDecision }
$nameFacts = [pscustomobject]@{CargoFacts=[pscustomobject]@{ByKey=@{recipient_name=[pscustomobject]@{Status='provided';Value='Alex'};recipient_contact=[pscustomobject]@{Status='missing';Value=''}}}}
$recipientDecision = [pscustomobject]@{AskFields=@('recipient_contact');Facts=$nameFacts;RequestedFacts=@();ActionEvidence=$null}
Check-Text 'recipient-name-is-not-phone' "Please share the recipient's phone number for delivery." $recipientDecision
Clear-PauseState
$botNoTs = HumanLine 'Confirmed automated answer' $ts
$sync = Sync-ConversationInterventionState -Buyer 'Virtual Buyer' -Lines @($botNoTs,(BLine 'New question' ($ts+1000))) -SentMatches @{0=$true} -NowUtc $script:nowUtc
Out-Probe 'confirmed-bot-without-ts' @{Source=(Get-MessageSourceClass $botNoTs $true);Pause=$sync.HumanPauseActive;Hold=$sync.UnknownHoldActive;NewHumans=$sync.NewHumanEvents;Reason=$sync.Reason}
Expect-Review 'R5-confirmed-bot-must-not-start-human-pause' (-not [bool]$sync.HumanPauseActive)
$runtime = New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc $script:nowUtc
foreach($pair in @(
    @('What time is it in China? What time is it in Tokyo?', "It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9)."),
    @('What time is it in China? What time is it in Singapore?', "It's 12:00 PM in China (UTC+8)."),
    @('What time is it in Atlantis? What time is it in Elbonia?', 'Which city or time zone do you mean for Atlantis?'),
    @('What time is it in Atlantis?', 'The shipment is going to Atlantis.'),
    @('What time is it in China?', "It's 12:00 AM in China (UTC+8).")
)) {
    $conv=ConvertTo-MessageList (BLine $pair[0] $ts) 'Virtual Buyer'
    $d=Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -Rules $null -RuntimeContext $runtime
    Check-Text 'time-target-binding' $pair[1] $d
}
foreach($txt in @(
    'What time is it in China? what time is it in Tokyo?',
    'What time is it in Hamburg? my company is in Tokyo.',
    'What time is it in China? What time is it in Tokyo? My company is in London.',
    'What time is it in Tokyo? what time is it in China?'
)) {
    $conv=ConvertTo-MessageList (BLine $txt $ts) 'Virtual Buyer'
    $d=Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -Rules $null -RuntimeContext $runtime
    Out-Probe 'time-scope' @{Question=$txt;Targets=@($d.TimeTargets | ForEach-Object { [pscustomobject]@{Place=$_.Place;State=$_.State;Scope=$_.ScopeText}});Answer=$d.DirectFactText}
}
$conflictFacts=[pscustomobject]@{CargoFacts=[pscustomobject]@{ByKey=@{carton_count=[pscustomobject]@{Status='conflict';Candidates=@([pscustomobject]@{Value='20'},[pscustomobject]@{Value='24'})}}}}
$conflictDecision=[pscustomobject]@{AskFields=@('weight');Facts=$conflictFacts;RequestedFacts=@();ActionEvidence=$null;ClarifyFields=@('carton_count')}
foreach($txt in @('Which carton count is correct - 999 or 1000?','Which carton count can you provide for the quote?','Could you confirm whether the carton count is 20 or 24?')) { Check-Text 'clarification-bound-to-candidates' $txt $conflictDecision }
$ev=[pscustomobject]@{TodoPersisted=$true;NotificationDelivered=$false;OwnerAccepted=$true;ContactedRecorded=$true;SupplierReplyRecorded=$false;TaskStatus='contacted';TaskId='t1';TaskKind='supplier_verification'}
$dClaim=[pscustomobject]@{AskFields=@();Facts=$null;RequestedFacts=@();ActionEvidence=$ev}
Check-Text 'contacted-is-not-supplier-reply' 'Your supplier confirmed the dimensions.' $dClaim
Clear-PauseState
Clear-TaskState
$other=New-OrUpdate-HumanTask -Buyer 'Virtual Buyer' -Kind 'fulfillment_status' -TriggerMessage 'Where is my shipment?' -Status 'pending_human'
$ctx=Reset (BLine 'Can you help with shipping?' $ts)
$script:modelReply="We'll contact your supplier directly."
Invoke-ConvoItem $ctx $item
Out-Probe 'unrelated-task-authorizes-supplier' @{Sends=$script:sends;Text=$script:sentText;Evidence=$script:turnActionEvidence;TaskRef=$script:turnTaskRef;Tasks=@(Get-HumanTaskList -Buyer 'Virtual Buyer' | ForEach-Object {[pscustomobject]@{Id=$_.id;Kind=$_.kind;Status=$_.status}});Logs=@($script:logs|Where-Object {$_ -match 'REPLY-GEN|HUMAN-TASK'})}
Expect-Review 'R2-unrelated-todo-must-not-authorize-supplier-plan' (-not ([string]$script:sentText -match "(?i)we'll contact your supplier directly"))
Clear-PauseState
Clear-TaskState
$ctx=Reset (BLine "I don't know the packed dimensions." $ts)
$script:modelReply="Please share the supplier's contact details for packing and contact details so we can reach you."
Invoke-ConvoItem $ctx $item
Out-Probe 'contact-conjunction-real-entry' @{Sends=$script:sends;Text=$script:sentText;Logs=@($script:logs|Where-Object {$_ -match 'REPLY-GEN|SEND-GATE'})}
Expect-Review 'R1-contact-redline-must-block-generic-conjoined-request' (-not ([string]$script:sentText -match '(?i)contact details so we can reach you'))
Clear-PauseState
Clear-TaskState
$ctx=Reset (BLine 'What time is it in China and in Tokyo? I need a shipping quote.' $ts)
$script:modelReply="It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9)."
Invoke-ConvoItem $ctx $item
Out-Probe 'swapped-time-real-entry' @{Sends=$script:sends;Text=$script:sentText;Logs=@($script:logs|Where-Object {$_ -match 'REPLY-GEN|SEND-GATE'})}
Expect-Review 'R6-entire-reply-must-bind-clock-to-place' (-not ([string]$script:sentText -match "(?i)1:00 PM in China"))
$convConflict=ConvertTo-MessageList ((BLine '20 cartons.' $ts)+$LF+(BLine '24 cartons.' ($ts+1000))) 'Virtual Buyer'
$realCf=Get-ConversationFacts $convConflict
Out-Probe 'real-count-conflict' @{CountStatus=$realCf.CargoFacts.ByKey.carton_count.Status;CountValue=$realCf.CargoFacts.ByKey.carton_count.Value;Candidates=$realCf.CargoFacts.ByKey.carton_count.Candidates}
$realCfDecision=[pscustomobject]@{AskFields=@('weight');Facts=$realCf;RequestedFacts=@();ActionEvidence=$null;ClarifyFields=@('carton_count')}
Check-Text 'real-conflict-wrong-candidates' 'Which carton count is correct - 999 or 1000?' $realCfDecision
Expect-Review 'R7-clarification-must-not-invent-candidates' (-not [bool]$script:lastReviewCheck.Ok)
$convName=ConvertTo-MessageList (BLine 'Consignee name: Alex.' $ts) 'Virtual Buyer'
$factsName=Get-ConversationFacts $convName
$realRecipientDecision=[pscustomobject]@{AskFields=@('recipient_contact');Facts=$factsName;RequestedFacts=@();ActionEvidence=$null}
Out-Probe 'real-recipient-fields' @{NameStatus=$factsName.CargoFacts.ByKey.recipient_name.Status;ContactStatus=$factsName.CargoFacts.ByKey.recipient_contact.Status}
Check-Text 'real-name-is-not-contact' "Please share the recipient's phone number for delivery." $realRecipientDecision
Expect-Review 'R4-name-present-phone-missing-must-allow-phone-request' ([bool]$script:lastReviewCheck.Ok)
Out-Probe 'real-conflict-values' @($realCf.CargoFacts.Conflicts|ForEach-Object {[pscustomobject]@{Key=$_.Key;Values=$_.Values}})
Clear-PauseState
Clear-TaskState
$supplierTask=New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'supplier@example.invalid' -MissingFields @('unit_dimensions')
[void](Set-HumanTaskStatus -Id $supplierTask.Task.id -Status 'contacted' -Note 'Called supplier; waiting for a reply')
$realContactEv=Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId $supplierTask.Task.id -Kind 'supplier_verification' -SupplierIdentity $supplierTask.Task.supplierKey
$dRealClaim=[pscustomobject]@{AskFields=@();Facts=$null;RequestedFacts=@();ActionEvidence=$realContactEv}
Out-Probe 'real-contacted-evidence' @{TaskStatus=$realContactEv.TaskStatus;Contacted=$realContactEv.ContactedRecorded;SupplierReply=$realContactEv.SupplierReplyRecorded;TaskKind=$realContactEv.TaskKind}
Check-Text 'real-contacted-not-confirmed' 'Your supplier confirmed the dimensions.' $dRealClaim
Expect-Review 'R3-contacted-without-reply-must-not-authorize-confirmation' (-not [bool]$script:lastReviewCheck.Ok)
$ctx=Reset (BLine 'Can you help with shipping?' $ts)
$script:modelReply='Your supplier confirmed the dimensions.'
Invoke-ConvoItem $ctx $item
Out-Probe 'supplier-confirmation-real-entry' @{Sends=$script:sends;Text=$script:sentText;Evidence=$script:turnActionEvidence;Logs=@($script:logs|Where-Object {$_ -match 'REPLY-GEN|SEND-GATE'})}
# Verify confirmed receipt precedence through the real monitor entry (receipt lookup is an external IO stub).
Clear-PauseState
Clear-TaskState
function Get-SentRecordMatchIndexes { param([string]$Buyer,[string[]]$Lines) return @{0=$true} }
$ctx=Reset ((HumanLine 'Confirmed automated answer' $ts)+$LF+(BLine 'Can you help with shipping?' ($ts+1000)))
$script:modelReply='Could you share the packed weight per carton?'
Invoke-ConvoItem $ctx $item
Out-Probe 'confirmed-bot-real-entry' @{Sends=$script:sends;Logs=@($script:logs|Where-Object {$_ -match 'INTERVENTION|PAUSE|REPLY-GEN'})}
Out-Probe 'isolated-root' $isoRoot
Out-Probe 'independent-review-assertions' @{Pass=$script:reviewPass;Fail=$script:reviewFailures.Count;Failures=@($script:reviewFailures.ToArray())}
if($script:reviewFailures.Count -gt 0) { exit 1 }
