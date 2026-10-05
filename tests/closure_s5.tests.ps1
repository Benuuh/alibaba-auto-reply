$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$h=Get-Content (Join-Path $PSScriptRoot 'review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000');if($cut -lt 0){throw 'HARNESS-BOUNDARY'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent',('$repo = '''+$repo+'''')))
# Undo historical business stubs. Only page/model/notification/clock IO is injected.
. (Join-Path $repo 'scripts/lib/human_tasks.ps1')
. (Join-Path $repo 'scripts/lib/sent_records.ps1')
. (Join-Path $repo 'scripts/lib/goods.ps1')
. (Join-Path $repo 'scripts/lib/quote.ps1')
$script:pass=0;$script:fail=0;$ts=1791172800000L
function Assert($ok,$why='assertion failed'){if(-not $ok){throw $why}}
function Case($id,[scriptblock]$body){try{& $body;$script:pass++;Write-Output "PASS $id"}catch{$script:fail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
function Send-OneTalkMessageEx {param($buyer,$text,$Page,[switch]$AlreadyOpen,[switch]$SkipConfirmation)
    $script:sends++;$script:sentText=$text;$before=@();$after=@([pscustomobject]@{MessageId=('send-'+$script:sends);MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$text;IsMine=$true})
    $receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before $before -After $after; if($script:invalidReceipt){$receipt.Valid=$false}
    [pscustomobject]@{Status=$script:sendResult;Confirmed=($script:sendResult -eq 'SENT_OK');Receipt=$receipt;BeforeSnapshot=$before;Detail='fixture IO';Raw=$script:sendResult}
}
function FullTask {New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'factory@example.invalid' -TriggerMessage 'Please check the packing.' -TriggerAt '2026-10-05T04:00:00Z' -MissingFields @('carton_count','unit_weight','unit_dimensions','delivery_address')}
$fields=@(@{FieldKey='carton_count';Value='10';Unit='cartons';Scope='cartons'},@{FieldKey='unit_weight';Value='12';Unit='kg';Scope='unit'},@{FieldKey='unit_dimensions';Value='50x40x30';Unit='cm';Scope='unit'},@{FieldKey='delivery_address';Value='Amazon FTW1';Scope='destination';Unit=''})
function ActualRecord($id,$values,$correction=$null){$a=@{Id=$id;ActionKind='supplier_reply';Source='operator-entry';RecordedBy='fixture operator';SourceRef='call:closure-x';AtUtc='2026-10-05T04:01:00Z';RawContent='Supplier supplied packing values';ConfirmedFields=$values};if($correction){$a.CorrectionOfFactRef=$correction};Add-HumanTaskActionRecord @a}
Case P03-program-source-send {Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'Supplier contact is factory@example.invalid. Have you received the supplier contact details?' $ts);$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1 -and $script:sentText -match 'We have received') ($script:sentText+' | '+($script:logs -join ' | '));Assert ($script:lastReplyComposition.Plan.FactStatements.SourceRefs.Count -gt 0) 'program statement retains actual source';foreach($p in @((Get-SentRecordFile),((Get-SentRecordFile)+'.bak'))){if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}}
Case D04-awaiting-conditional-send {Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I cannot provide the packing dimensions.' $ts);$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1 -and $script:sentText -match 'Once you share');Assert ($script:sentText -notmatch 'Could you share (?:the total weight|the.*dimensions|the.*carton)');$task=@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)[0];$ev=Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId $task.id;$d=[pscustomobject]@{ActionEvidence=$ev;AskFields=@('supplier');RequestedFacts=@();Facts=$null};Assert (Test-SupplierPlanWording "Once you share the supplier's contact, our team will check the packing information with your supplier. Our team will contact your supplier." $d) 'extra unconditional action still blocked';foreach($p in @((Get-SentRecordFile),((Get-SentRecordFile)+'.bak'))){if(Test-Path $p){Remove-Item -LiteralPath $p -Force}}}
Case X01 {
    Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine "I cannot provide the dimensions. My supplier's contact is factory@example.invalid. Please check the packing." $ts);$script:sendResult='FAILED';$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;$created=@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly);Assert ($created.Count -eq 1) 'actual unable-to-provide entry creates persisted task';$t=[pscustomobject]@{Task=$created[0]};Assert (ActualRecord $t.Task.id $fields).Ok
    . (Join-Path $repo 'scripts/lib/human_tasks.ps1')
    $raw=BLine 'Has the supplier confirmed the packing for this shipment?' ($ts+120000)
    $data=Get-SkillPath data;$snap=Join-Path $data 'msgs_closure_x.txt';[IO.File]::WriteAllText($snap,("# BUYER: Virtual Buyer`n"+$raw),(New-Object Text.UTF8Encoding($true)))
    Assert (Get-GoodsDataStatus 'Virtual Buyer' $data).ready 'goods actual persisted facts';Assert (@(Get-QuoteReadyBuyers $data|Where-Object buyer -eq 'Virtual Buyer').Count -eq 1) 'quote actual persisted facts'
    $log=Join-Path $isoRoot 'logs/summary-input.log';[IO.File]::WriteAllText($log,"2026-10-05 12:00:00 | REPLIED to Virtual Buyer: SENT_OK`n2026-10-05 12:00:00 | Reply text: Thanks.")
    $out=Join-Path $isoRoot reports;$state=Join-Path $isoRoot summary-state.json
    $summary=@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts/summarize.ps1') -LogFile $log -OutDir $out -StateFile $state 2>&1);Assert ($LASTEXITCODE -eq 0) 'actual summary exit';$report=@(Get-ChildItem $out -Filter '*.md');Assert ($report.Count -eq 1);Assert ((Get-Content $report[0].FullName -Raw -Encoding UTF8) -match '可进入人工报价准备') 'summary actual readiness'
    Assert (Set-HumanTaskStatus $t.Task.id resolved);$ctx=Reset $raw;$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 1) 'history actual send';Assert ($script:sentText -match 'supplier confirmed');Assert ($script:sentText -notmatch 'will check|Could you share') 'no future plan or repeated facts';Assert ((Read-SentRecordStore).buyers.'virtual buyer'.Count -eq 1) 'actual receipt persisted'
}
$script:mutation=''
function Invoke-LLM {param($Messages,$Temperature,$MaxTokens,$LogFile)
    $script:modelCalls++
    if($script:modelCalls -eq 1 -and $script:mutation){$task=@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)[0];switch($script:mutation){
        correction {$ref=@(Get-HumanTaskConfirmedFields $task|Where-Object FieldKey -eq unit_weight)[0].FactRef;[void](ActualRecord $task.id @(@{FieldKey='unit_weight';Value='15';Unit='kg';Scope='unit'}) $ref)}
        closed {[void](Set-HumanTaskStatus $task.id closed -Resolution 'cancelled in fixture')}
        supplier {[void](New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'other@example.invalid' -TriggerMessage 'New supplier for current shipment' -TriggerAt '2026-10-05T04:02:00Z')}
        flow {[void](Sync-CurrentCargoFlow -Buyer 'Virtual Buyer' -Conversation (ConvertTo-MessageList (BLine 'New shipment.' ($ts+120000)) 'Virtual Buyer'))}
        human {$script:raw+=''+"`n"+'[ME] operator intervened @@MT:'+($ts+1000)+"`n"+(BLine 'extra buyer message' ($ts+2000))}
        unknown {$script:raw+=''+"`n"+'[ME] operator intervened @@TS:'+($ts+1000)+' @@MT:'+($ts+1000)+"`n"+(BLine 'extra buyer message' ($ts+2000))}
    }}
    return $script:modelReply
}
Case X02 {foreach($mutation in @('correction','closed','supplier','flow')){Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$t=FullTask;Assert (ActualRecord $t.Task.id $fields).Ok;$ctx=Reset (BLine 'Can you help with this shipment and has the supplier confirmed?' ($ts+120000));$script:mutation=$mutation;$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 0) ('dependency mutation '+$mutation+' must discard draft');Assert ($script:ledgerWrites -eq 0)
$script:mutation='';$nextText=switch($mutation){correction {'Has the supplier confirmed the packing? Can you help with this shipment?'} closed {'Can you help with this shipment?'} supplier {"My supplier is now other@example.invalid. Can you help with this shipment?"} flow {'New shipment. Can you help with this shipment?'}}
$next=Reset (BLine $nextText ($ts+180000));$script:modelReply='Happy to help with this.';Invoke-ConvoItem $next $item|Out-Null;Assert ($script:sends -eq 1) ('next round legal send after '+$mutation)
if($mutation -eq 'correction'){Assert ($script:sentText -match '15 kg' -and $script:sentText -notmatch '12 kg') 'only corrected weight rendered'}
if($mutation -in @('supplier','flow')){Assert ($script:sentText -notmatch 'supplier confirmed') 'old flow confirmations not reused'}
};$script:mutation=''}
Case X03 {foreach($mutation in @('human','unknown')){Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I need a shipping quote.' $ts);$script:mutation=$mutation;$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 0) ('intervention '+$mutation);Assert ($script:ledgerWrites -eq 0)};$script:mutation=''}
Case X04 {foreach($bad in @('Could you send the name and email?','Our rate is 100 USD.','The supplier confirmed 99 kg.','At this moment it is half past midnight in China.')){Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I need a shipping quote.' $ts);$script:modelReply=$bad;Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1) 'controlled positive must send';Assert ($script:modelCalls -le 2) 'whole turn one rewrite';Assert (-not $script:sentText.Contains($bad))}}
Case X05 {foreach($status in @('SENT_OK','FAILED','UNKNOWN')){Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I cannot get packing dimensions. Can your team check?' $ts);$script:sendResult=$status;$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1);Assert ($script:ledgerWrites -eq $(if($status -eq 'SENT_OK'){1}else{0})) ('ledger only confirmed '+$status);Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count -ge 1) 'failure preserves task'}}
Case X05-invalid-success-claim {Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I cannot provide the packing dimensions.' $ts);$script:modelReply='Happy to help with this.';$script:invalidReceipt=$true;try{Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1 -and $script:ledgerWrites -eq 0) 'status without valid event receipt cannot advance ledger';Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count -ge 1)}finally{$script:invalidReceipt=$false}}
# Reconciliation uses the real receipt producer and real monitor function, with only snapshot IO injected.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/monitor.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-UnknownSendResult'},$true);Invoke-Expression $fn.Extent.Text
$sendAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/lib/send.ps1'),[ref]$null,[ref]$null)
$fn=$sendAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-OneTalkOutboundMessage'},$true);Invoke-Expression $fn.Extent.Text
function Get-OutboundSnapshot {return @([pscustomobject]@{MessageId='reconciled-event';MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$script:sentText;IsMine=$true})}
try {Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I cannot get packing dimensions. Can your team check?' $ts);$script:sendResult='UNKNOWN';$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 1 -and $script:ledgerWrites -eq 1) 'successful real reconciliation publishes receipt and ledger';Write-Output 'PASS X05-reconciled-positive'}catch{$script:fail++;Write-Output "FAIL X05-reconciled-positive $($_.Exception.Message)"}
Write-Output "RESULT closure_s5 pass=$script:pass fail=$script:fail root=$isoRoot"
if($script:fail){exit 1}
