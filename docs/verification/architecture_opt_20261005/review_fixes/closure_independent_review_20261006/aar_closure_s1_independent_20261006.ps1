$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
. (Join-Path $repo 'scripts/config.ps1')
. (Join-Path $repo 'scripts/lib/paths.ps1')
$root=Join-Path $env:TEMP ('aar-closure-s1-review-'+[guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $root)
if(-not(Test-AarIsolatedRuntime)){throw 'ISOLATION-MISSING'}
. (Join-Path $repo 'scripts/reply_engine.ps1')
. (Join-Path $repo 'scripts/lib/msg_norm.ps1')
. (Join-Path $repo 'scripts/lib/human_tasks.ps1')
. (Join-Path $repo 'scripts/lib/task_facts.ps1')
. (Join-Path $repo 'scripts/lib/goods.ps1')
. (Join-Path $repo 'scripts/lib/quote.ps1')
. (Join-Path $repo 'scripts/lib/seller_context.ps1')
. (Join-Path $repo 'scripts/lib/reply_gen.ps1')
$buyer='Independent Closure Buyer'
$LF=[string][char]10
$ts=1791172800000L
function BL($text,$stamp=$ts){return ('[BUYER] '+$text+' @@TS:'+$stamp+' @@MT:'+$stamp+' @@OT:'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))))}
function ClearTasks {foreach($path in @((Get-HumanTaskFile),((Get-HumanTaskFile)+'.bak'))){if(Test-Path $path){Remove-Item -LiteralPath $path -Force}}}
function NewTask($trigger='Please verify the packing.',[string[]]$missing=@('carton_count','unit_weight','unit_dimensions','delivery_address')){return (New-OrUpdate-SupplierVerificationTask -Buyer $buyer -SupplierContact 'factory@example.invalid' -TriggerMessage $trigger -TriggerAt '2026-10-05T04:00:00Z' -MissingFields $missing)}
function Record($id,$fields,$raw='Supplier supplied verified packing values.') {return (Add-HumanTaskActionRecord -Id $id -ActionKind supplier_reply -Source operator-entry -RecordedBy 'fictional operator' -SourceRef 'fictional:call-1' -AtUtc '2026-10-05T04:01:00Z' -RawContent $raw -ConfirmedFields $fields)}
function Emit($label,$value){Write-Output ($label+' '+($value|ConvertTo-Json -Depth 5 -Compress))}
$good=@(@{FieldKey='carton_count';Value='10';Unit='cartons';Scope='cartons'},@{FieldKey='unit_weight';Value='12';Unit='kg';Scope='unit'},@{FieldKey='unit_dimensions';Value='50x40x30';Unit='cm';Scope='unit'},@{FieldKey='delivery_address';Value='Amazon FTW1';Unit='';Scope='destination'})
$data=Get-SkillPath data;[void](New-Item -ItemType Directory -Path $data -Force)
$snapshot=Join-Path $data 'msgs_independent_20261006.txt'
Emit ROOT @{Root=$root;TaskFile=(Get-HumanTaskFile)}

# Same explicit new-shipment sentence occurs as a distinct later buyer event.
ClearTasks
$firstText=BL 'New shipment. Supplier is factory@example.invalid.' $ts
$conv=ConvertTo-MessageList $firstText $buyer
[void](Sync-CurrentCargoFlow -Buyer $buyer -Conversation $conv)
$t=NewTask 'New shipment. Supplier is factory@example.invalid.'
[void](Record $t.Task.id $good)
$before=Get-CurrentCargoFlow $buyer
$laterText=BL 'New shipment. Supplier is factory@example.invalid.' ($ts+86400000L)
$rw=Get-QuoteReadinessForConversationText -Text $laterText -ConvoName $buyer -WithTaskEvidence
$after=Get-CurrentCargoFlow $buyer
[IO.File]::WriteAllText($snapshot,('# BUYER: '+$buyer+$LF+$laterText),[Text.Encoding]::UTF8)
$quoted=@(Get-QuoteReadyBuyers $data)
Emit SAME_TEXT_NEW_BATCH @{OldFlow=$before.Id;NewFlow=$after.Id;OldMessage=$conv.Messages[0].StableId;NewMessage=$rw.Conversation.Messages[0].StableId;Ready=$rw.Ready;QuoteCandidates=$quoted.Count;Error=$rw.Error}

# Task-only completion ignores a real conflicting buyer fact in the current effective model.
ClearTasks
$t=NewTask
[void](Record $t.Task.id $good)
$conflictText=BL 'There are 11 cartons in this shipment.' ($ts+120000)
$facts=Get-ConversationFacts -Conversation (ConvertTo-MessageList $conflictText $buyer) -Buyer $buyer -WithTaskEvidence
$resolved=Set-HumanTaskStatus -Id $t.Task.id -Status resolved
$ev=Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id
Emit BUYER_CONFLICT_RESOLVED @{CargoCountStatus=$facts.CargoFacts.ByKey.carton_count.Status;Ready=$facts.QuoteReadiness.Ready;ResolvedSucceeded=$resolved;ResolvedRecorded=$ev.ResolvedRecorded;CompletionRefs=@($ev.ConfirmedFields|ForEach-Object {$_.Value})}

# A later query widens requirements but initial VerificationItems never adds the new item.
ClearTasks
$one=NewTask 'Please verify the weight.' @('unit_weight')
$two=NewTask 'Please also verify the dimensions.' @('unit_weight','unit_dimensions')
[void](Record $two.Task.id @($good[1]))
$resolved=Set-HumanTaskStatus -Id $two.Task.id -Status resolved
$actual=@(Get-HumanTaskList -TaskId $two.Task.id)[0]
Emit NEW_REQUIRED_ITEM_IGNORED @{SameTask=($one.Task.id -eq $two.Task.id);OriginalItems=@($actual.VerificationItems|ForEach-Object {$_.FieldKey});PendingFields=$actual.missingFields;ResolvedSucceeded=$resolved;ConfirmedFields=@(Get-HumanTaskConfirmedFields $actual|ForEach-Object {$_.FieldKey})}

# Product per-piece mass must not be read as the outer carton/pallet weight.
ClearTasks
$text=(BL 'There are 10 cartons.' $ts)+$LF+(BL 'Each item weighs 1 kg.' ($ts+1000))+$LF+(BL 'Carton dimensions are 50x40x30 cm.' ($ts+2000))+$LF+(BL 'Ship to Amazon FTW1.' ($ts+3000))
$rw=Get-QuoteReadinessForConversationText -Text $text -ConvoName $buyer -WithTaskEvidence
[IO.File]::WriteAllText($snapshot,('# BUYER: '+$buyer+$LF+$text),[Text.Encoding]::UTF8)
Emit PRODUCT_WEIGHT_AS_PACKED_WEIGHT @{Ready=$rw.Ready;WeightStatus=$rw.CargoFacts.ByKey.unit_weight.Status;WeightValue=$rw.CargoFacts.ByKey.unit_weight.Value;WeightScope=$rw.CargoFacts.ByKey.unit_weight.Scope;QuoteCandidates=@(Get-QuoteReadyBuyers $data).Count;Error=$rw.Error}

# Accurate pallet confirmation is rendered with the carton unit by the program.
ClearTasks
$t=NewTask
$palletFields=@($good|Where-Object {$_.FieldKey -ne 'carton_count'})+@(@{FieldKey='carton_count';Value='2';Unit='pallets';Scope='cartons'})
[void](Record $t.Task.id $palletFields)
[void](Set-HumanTaskStatus -Id $t.Task.id -Status resolved)
$text=BL 'Has the supplier confirmed the packing?' ($ts+120000)
$conv=ConvertTo-MessageList $text $buyer
$facts=Get-ConversationFacts -Conversation $conv -Buyer $buyer -WithTaskEvidence
$ev=Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id
$runtime=New-ReplyRuntimeContext -SellerProfile (Get-SellerProfile -Config $null) -NowUtc ([datetime]'2026-10-05T04:02:00Z')
$decision=Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $null -RuntimeContext $runtime -ActionEvidence $ev
$plan=New-ResponsePlan $decision
$render=Render-ResponsePlan $plan
$checked=Test-ReplyCompliance -Text $render -Rules $null -Decision $decision
Emit PALLET_CONFIRMATION_RENDER @{CountFieldUnit=$facts.CargoFacts.ByKey.carton_count.Unit;Rendered=$render;Allowed=$checked.Ok;Codes=@($checked.Violations|ForEach-Object {$_.Code})}
function Invoke-LLM {param($Messages,$Temperature,$MaxTokens,$LogFile);return 'Happy to help with this.'}
$gen=Invoke-ReplyGeneration -Conversation $conv -Decision $decision -Rules $null -RuntimeContext $runtime -MaxRewrites 1
Emit PALLET_ACTUAL_GENERATION @{Text=$gen.Text;Source=$gen.Source;FallbackReason=$gen.FallbackReason;Codes=@($gen.Violations|ForEach-Object {$_.Code});Calls=$gen.ModelCalls}

# Fully attributed waiting note still does not contain an actual supplier response.
ClearTasks
$t=NewTask
$record=Record $t.Task.id @() 'Operator note: Waiting for supplier reply.'
$ev=Get-ActionEvidenceForTask -Buyer $buyer -TaskId $t.Task.id
Emit ATTRIBUTED_WAITING_NOTE @{Saved=$record.Ok;ReplyRecorded=$ev.SupplierReplyRecorded;RecordContent=$ev.ActionRecords[0].rawContent}
$text=BL 'Has the supplier replied?' ($ts+120000)
$conv=ConvertTo-MessageList $text $buyer
$facts=Get-ConversationFacts -Conversation $conv -Buyer $buyer -WithTaskEvidence
$decision=Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $null -RuntimeContext $runtime -ActionEvidence $ev
$falseClaim='Your supplier has replied.'
$policy=Test-SupplierPlanWording -Text $falseClaim -Decision $decision
$compliance=Test-ReplyCompliance -Text $falseClaim -Rules $null -Decision $decision
$plan=New-ResponsePlan $decision
function Invoke-LLM {param($Messages,$Temperature,$MaxTokens,$LogFile);return 'Your supplier has replied.'}
$gen=Invoke-ReplyGeneration -Conversation $conv -Decision $decision -Rules $null -RuntimeContext $runtime -MaxRewrites 1
Emit ATTRIBUTED_WAITING_CONSUMERS @{WordingBlocked=$policy;FullComplianceAllowed=$compliance.Ok;FullComplianceCodes=@($compliance.Violations|ForEach-Object {$_.Code});PlanRender=(Render-ResponsePlan $plan);ActualGenerated=$gen.Text;GeneratedSource=$gen.Source;ModelClaimAdmission=(Get-BusinessBodyAdmission $falseClaim).Allowed}
Write-Output END
