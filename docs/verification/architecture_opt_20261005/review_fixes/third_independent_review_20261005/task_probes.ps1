$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
$isoRoot = Join-Path $env:TEMP ('aar-third-task-review-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
if (-not (Test-AarIsolatedRuntime)) { throw 'isolation failed' }
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')
. (Join-Path $scripts 'lib\task_facts.ps1')
. (Join-Path $scripts 'lib\goods.ps1')
. (Join-Path $scripts 'lib\quote.ps1')
$buyer = 'Independent Fictional Task Buyer'
$LF = [string][char]10
function BLine([string]$text, [long]$ts) { return ('[BUYER] ' + $text + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))) }
function ClearTasks { foreach ($f in @((Get-HumanTaskFile), ((Get-HumanTaskFile) + '.bak'))) { if (Test-Path $f) { Remove-Item -LiteralPath $f -Force } } }
function Out([string]$label, $data) { Write-Output ($label + ' ' + ($data | ConvertTo-Json -Depth 7 -Compress)) }
function Blocked([string]$text, $ev) { $dec = [pscustomobject]@{ ActionEvidence = (New-ActionEvidence -Values $ev); AskFields = @(); RequestedFacts = @(); Facts = $null }; return [bool](Test-SupplierPlanWording -Text $text -Decision $dec) }
function NewTask([string]$trig = 'Please verify this packing data.', [string]$contact = 'factory-one@example.invalid') { return (New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact $contact -TriggerMessage $trig -MissingFields @('carton_count','unit_weight','unit_dimensions')) }
$goodFields = @(@{FieldKey='carton_count'; Value='10'; Unit='cartons'; Scope='cartons'}, @{FieldKey='unit_weight';Value='12';Unit='kg';Scope='unit'}, @{FieldKey='unit_dimensions';Value='50x40x30';Unit='cm';Scope='unit'}, @{FieldKey='delivery_address';Value='Amazon FTW1';Unit='';Scope='destination'})
$ts = [long]1791172800000
Out 'ROOT' @{Root=$isoRoot;Tasks=(Get-HumanTaskFile)}

# Single open task with a trigger absent in a new conversation and different supplier/batch.
ClearTasks
$t = NewTask 'I cannot provide the old batch carton dimensions.'
[void](Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source manual-entry -RecordedBy operator -SourceRef call-old -RawContent 'Old batch confirmed.' -BatchRef 'batch-old' -ConfirmedFields $goodFields)
$newText = (BLine 'This is a new shipment, from another supplier factory-two@example.invalid.' ($ts+1000))
$newConv = ConvertTo-MessageList $newText $buyer
$e = @(Get-TaskConfirmedEvidence -Buyer $buyer -Conversation $newConv)
$rw = Get-QuoteReadinessForConversationText -Text $newText -ConvoName $buyer -WithTaskEvidence
Out 'CROSS_FLOW_SUPPLIER' @{Imported=$e.Count;ImportedSupplier=@($e | ForEach-Object {$_.SupplierIdentity})[0];NewBuyerText=$newConv.LatestBuyer.Orig;Ready=$rw.Ready;Error=$rw.Error}
$snapDir=Get-SkillPath data
[void](New-Item -ItemType Directory -Path $snapDir -Force)
$snapshot=Join-Path $snapDir 'msgs_20261005_120000.txt'
[IO.File]::WriteAllText($snapshot, ('# BUYER: '+$buyer+$LF+$newText), [Text.Encoding]::UTF8)
$candidates=@(Get-QuoteReadyBuyers -snapDir $snapDir)
Out 'CROSS_FLOW_ACTUAL_QUOTE_CANDIDATES' @{Count=$candidates.Count;Buyer=@($candidates | ForEach-Object {$_.buyer});Missing=@($candidates | ForEach-Object {$_.MissingFields})}

# Invalid fields never validate units/scope/arity/ranges, yet are provided and ready.
ClearTasks
$t = NewTask
$bad = @(@{FieldKey='carton_count';Value='0';Unit='pieces';Scope='goods'}, @{FieldKey='unit_weight';Value='-5';Unit='bananas';Scope='goods'}, @{FieldKey='unit_dimensions';Value='50x40';Unit='cm';Scope='goods'}, @{FieldKey='delivery_address';Value='unknown';Unit='';Scope='destination'})
$add = Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source manual-entry -RawContent 'Awaiting details.' -ConfirmedFields $bad
$conv = ConvertTo-MessageList (BLine 'Please verify this packing data.' $ts) $buyer
$cf = Get-CargoFacts -Conversation $conv -TaskEvidence @(Get-TaskConfirmedEvidence -Buyer $buyer -Conversation $conv)
$r = Get-QuoteReadiness -Facts $cf
Out 'INVALID_CONFIRMATION_READY' @{Saved=$add.Ok;Ready=$r.Ready;Fields=@('carton_count','unit_weight','unit_dimensions','delivery_address') | ForEach-Object {$k=$_;@{Key=$k;Value=$cf.ByKey[$k].Value;Unit=$cf.ByKey[$k].Unit;Scope=$cf.ByKey[$k].Scope;Status=$cf.ByKey[$k].Status}}}
[IO.File]::WriteAllText($snapshot, ('# BUYER: '+$buyer+$LF+(BLine 'Please verify this packing data.' $ts)), [Text.Encoding]::UTF8)
$candidates=@(Get-QuoteReadyBuyers -snapDir $snapDir)
Out 'INVALID_ACTUAL_QUOTE_CANDIDATES' @{Count=$candidates.Count;Buyer=@($candidates|ForEach-Object {$_.buyer})}

# Source whitelist + arbitrary content is treated as completed supplier reply, no provenance required.
ClearTasks
$t = NewTask
$add = Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -RawContent 'Waiting for supplier reply.'
$ev = Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id -Kind supplier_verification
Out 'SOURCE_LABEL_NOT_PROOF' @{Saved=$add.Ok;SupplierReply=$ev.SupplierReplyRecorded;GenericReplyBlocked=(Blocked 'Your supplier has replied with the packing details.' $ev);Action=$ev.ActionRecords[0]}

# Correction of one field supersedes entire multi-field record and loses unchanged fields.
ClearTasks
$t = NewTask
[void](Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source manual-entry -RawContent 'Original confirmed values.' -ConfirmedFields $goodFields)
$before=@(Get-HumanTaskConfirmedFields @(Get-HumanTaskList -TaskId $t.Task.id)[0])
[void](Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source manual-entry -RawContent 'Weight correction only.' -ConfirmedFields @(@{FieldKey='unit_weight';Value='15';Unit='kg';Scope='unit'}))
$after=@(Get-HumanTaskConfirmedFields @(Get-HumanTaskList -TaskId $t.Task.id)[0])
Out 'PARTIAL_CORRECTION_LOSES_VALID_FIELDS' @{Before=@($before|ForEach-Object {$_.FieldKey});After=@($after|ForEach-Object {$_.FieldKey});Weight=@($after|Where-Object {$_.FieldKey -eq 'unit_weight'})[0].Value}

# Legacy task with no supplier key wrongly matches requested other supplier.
ClearTasks
$t = NewTask
$all=@(Get-HumanTaskList)
Set-HumanTaskField $all[0] supplierKey ''
[void](Save-HumanTaskStore $all)
$ev = Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id -Kind supplier_verification -SupplierIdentity 'email:factory-two@example.invalid'
Out 'BLANK_KEY_WILDCARD' @{ExactTaskMatch=$ev.ExactTaskMatch;IdentityMatch=$ev.IdentityMatch;StoredContact=$ev.TaskSupplierContact;RequestedIdentity=$ev.RequiredContact;PlanBlocked=(Blocked "We'll contact your supplier directly." $ev)}

# Verified resolved record survives storage but past confirmation is blocked (open is checked first).
ClearTasks
$t = NewTask
[void](Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source manual-entry -RawContent 'Supplier confirmed values.' -ConfirmedFields $goodFields)
[void](Set-HumanTaskStatus -Id $t.Task.id -Status resolved -Resolution 'verified')
$ev = Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id -Kind supplier_verification
Out 'RESOLVED_HISTORY_UNUSABLE' @{TaskExists=$ev.TaskExists;ExactMatch=$ev.ExactTaskMatch;IsOpen=$ev.IsOpen;ConfirmedFields=$ev.ConfirmedFields.Count;PastSupportedBlocked=(Blocked 'Your supplier confirmed 12 kg per carton.' $ev);FutureBlocked=(Blocked "We'll check the packed weight with your supplier." $ev)}

# Unverified resolved state can be set while no facts have been published.
ClearTasks
$t = NewTask
$set=Set-HumanTaskStatus -Id $t.Task.id -Status resolved -Resolution 'waiting for data'
$ev=Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id -Kind supplier_verification
Out 'UNVERIFIED_TASK_RESOLUTION' @{SetResolved=$set;Status=$ev.TaskStatus;ConfirmedFieldCount=$ev.ConfirmedFields.Count;ResolvedRecorded=$ev.ResolvedRecorded}

# A corrupt task store is read as no tasks and overwritten by ordinary creation.
ClearTasks
$t = NewTask
$file=Get-HumanTaskFile
[IO.File]::WriteAllText($file,'{"tasks": broken',[Text.Encoding]::UTF8)
$statusBefore=(Read-HumanTaskStore).__status
$new=New-OrUpdate-SupplierVerificationTask -Buyer 'Other Fictional Buyer' -SupplierContact 'other@example.invalid' -TriggerMessage 'I cannot provide the package dimensions.'
$doc=Read-HumanTaskStore
Out 'CORRUPT_STORE_OVERWRITTEN' @{StatusBefore=$statusBefore;NewStoreOk=$new.StoreOk;StatusAfter=(Read-JsonDocument $file).Status;RemainingBuyers=@($doc.tasks|ForEach-Object {$_.buyer})}

# Existing original test positives remain verified separately by the repository test file.
Write-Output 'END'
