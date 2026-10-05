# Shared task storage, flow, provenance and field-version contracts. Loaded by human_tasks.
function ConvertTo-HumanTaskEpoch([string]$Value) {
    $n=0L;if([long]::TryParse($Value,[ref]$n)){return $n}
    $dt=[datetimeoffset]::MinValue;if([datetimeoffset]::TryParse($Value,[ref]$dt)){return $dt.ToUnixTimeMilliseconds()};return 0L
}
function Read-HumanTaskStore {
    $doc = Read-JsonDocument (Get-HumanTaskFile)
    $status = $doc.Status; $data = $doc.Data
    if ($status -eq 'missing' -and (Test-Path ((Get-HumanTaskFile)+'.bak'))) { $status='backup-without-main' }
    if ($status -eq 'valid') {
        if (-not $data -or $data.PSObject.Properties.Name -notcontains 'tasks' -or $null -eq $data.tasks -or $data.tasks -is [string] -or $data.tasks -isnot [System.Array]) { $status='schema-invalid' }
    }
    if ($status -eq 'missing') { $data=[pscustomobject]@{version=3;tasks=@();currentFlows=[pscustomobject]@{};flows=@()} }
    if ($status -ne 'valid' -and $status -ne 'missing') { $data=$null }
    $result=[pscustomobject]@{Status=$status;Data=$data;Error=$doc.Error;Version=0;tasks=@();__status=$status}
    if ($data) { $result.tasks=@($data.tasks); $result.Version=[int]$data.version }
    return $result
}
function Get-HealthyHumanTaskData {
    $read=Read-HumanTaskStore
    if ($read.Status -notin @('valid','missing')) { throw ('TASK-STORE-UNHEALTHY:'+ $read.Status) }
    $data=$read.Data
    if ($data.PSObject.Properties.Name -notcontains 'currentFlows') { Set-HumanTaskField $data currentFlows ([pscustomobject]@{}) }
    if ($data.PSObject.Properties.Name -notcontains 'flows') { Set-HumanTaskField $data flows @() }
    return $data
}
function Invoke-HumanTaskTransaction([scriptblock]$Body) {
    $hash=Get-HumanTaskStableHash ([IO.Path]::GetFullPath((Get-HumanTaskFile)).ToLowerInvariant())
    $mutex=New-Object Threading.Mutex($false,('Local\AarTask-'+$hash))
    $held=$false
    try { try{$held=$mutex.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$held=$true};if(-not $held){throw 'TASK-STORE-LOCK-TIMEOUT'}; [void](Get-HealthyHumanTaskData); & $Body }
    finally { if($held){$mutex.ReleaseMutex()};$mutex.Dispose() }
}
function Save-HumanTaskStore($Tasks) {
    Invoke-HumanTaskTransaction {
        $data=Get-HealthyHumanTaskData
        if ($Tasks.PSObject.Properties.Name -contains 'tasks') { $data=$Tasks } else {Set-HumanTaskField $data tasks @($Tasks)}
        Set-HumanTaskField $data version 3
        $w=Write-JsonDocumentAtomic -Path (Get-HumanTaskFile) -Data $data -Depth 30
        if(-not $w.Ok){return $false}
        $back=Read-HumanTaskStore
        return ($back.Status -eq 'valid' -and (Get-HumanTaskStableHash ($data|ConvertTo-Json -Depth 30 -Compress)) -eq (Get-HumanTaskStableHash ($back.Data|ConvertTo-Json -Depth 30 -Compress)))
    }
}
function Get-CurrentCargoFlow([string]$Buyer) {
    $data=Get-HealthyHumanTaskData; $key=Get-HumanTaskBuyerKey $Buyer
    $id=[string](Get-HumanTaskProperty $data.currentFlows $key '')
    foreach($f in @($data.flows)){if($f.Id -eq $id -and $f.BuyerKey -eq $key){return $f}}
    return $null
}
# [独立复核 R01] 货物流锚点身份 = 可靠消息身份（StableId）或（原文哈希 + 逐条实际时刻）。
#   仅原文哈希相同不足以证明是同一个消息事件：买家在不同时刻再次发同文新货单必须建立新流。
# [独立复核 R05] 流上下文保存该事件的原文行（带上限），使完成检查能在同一提交前重新消费当前买家事实。
function Get-CargoFlowRefLine($Message, [string]$FallbackText = '', [string]$FallbackAt = '') {
    $line = ''
    if ($Message) {
        $body = ([string]$Message.Orig) -replace '\s+', ' '
        $at = [string]$Message.MessageTsRaw
        if (-not $at) { $at = [string]$Message.TsRaw }
        $line = '[BUYER] ' + $body.Trim()
        if ($at) { $line = $line + ' @@MT:' + $at }
    } elseif ($FallbackText) {
        $body = ([string]$FallbackText) -replace '\s+', ' '
        $line = '[BUYER] ' + $body.Trim()
        if ($FallbackAt) { $line = $line + ' @@MT:' + $FallbackAt }
    }
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) }
    return $line
}
function Test-CargoFlowEventMatch($Ref, $Message) {
    if (-not $Ref -or -not $Message) { return $false }
    $rid = [string](Get-HumanTaskProperty $Ref MessageId '')
    $mid = [string](Get-HumanTaskProperty $Message StableId '')
    if ($rid -and $mid -and $rid -eq $mid) { return $true }
    $rh = [string](Get-HumanTaskProperty $Ref Hash '')
    if (-not $rh -or $rh -ne (Get-HumanTaskStableHash ([string]$Message.Orig))) { return $false }
    $ra = ConvertTo-HumanTaskEpoch ([string](Get-HumanTaskProperty $Ref At ''))
    $ma = ConvertTo-HumanTaskEpoch ([string]$Message.MessageTsRaw)
    if ($ra -and $ma) { return ($ra -eq $ma) }
    return ((-not $ra) -and (-not $ma))
}
function Sync-CurrentCargoFlow {
    param([string]$Buyer,$Conversation=$null,[string]$SupplierIdentity='', [string]$TriggerMessage='', [string]$TriggerMessageId='', [string]$TriggerAt='')
    Invoke-HumanTaskTransaction {
        $data=Get-HealthyHumanTaskData;$key=Get-HumanTaskBuyerKey $Buyer;$current=$null
        if($SupplierIdentity -eq 'supplier-identity-unknown'){$SupplierIdentity=''}
        $currentId=[string](Get-HumanTaskProperty $data.currentFlows $key '')
        foreach($stored in @($data.flows)){if($stored.Id -eq $currentId -and $stored.BuyerKey -eq $key){$current=$stored;break}}
        $messages=@();if($Conversation){$messages=@($Conversation.Messages|Where-Object {$_.Role -eq 'buyer' -or $_.Source -eq 'human'})}
        $contactSource=$null
        if(-not $SupplierIdentity -and $Conversation -and $Conversation.Order.Confident){
            $contactSource=$null;$cutAt=0L;if($current){$cutAt=ConvertTo-HumanTaskEpoch $current.InitialTriggerRef.At}
            foreach($m in $messages){
                $at=ConvertTo-HumanTaskEpoch $m.MessageTsRaw;if($cutAt -and $at -and $at -lt $cutAt){continue}
                # Same role/contact candidates used by CargoFacts; email and phone cannot diverge.
                $ids=@();if(Get-Command Get-CargoContactCandidates -ErrorAction SilentlyContinue){foreach($candidate in @(Get-CargoContactCandidates $m.Orig|Where-Object {$_.Key -eq 'supplier_contact' -and $_.Status -eq 'provided'})){$id=Get-SupplierIdentity $candidate.Value;if($id.Confidence -in @('full-contact','full-contact-extracted')){$ids+=$id.Key}}}
                $ids=@($ids|Select-Object -Unique);if($ids.Count -eq 1){$contactSource=$m;$SupplierIdentity=$ids[0]}
            }
        }
        $start=$null
        foreach($m in $messages){if($m.Orig -match '(?i)\bnew\s+(?:shipment|cargo|goods|order|batch|consignment)\b|新(?:货物|订单|批次)'){ $start=$m }}
        $new=$false
        if($start){
            # [独立复核 R01] 新货单判定按事件身份，不按正文哈希：同文不同事件（新时刻/新消息身份）＝新批次。
            $knownEvent=$false
            if($current){foreach($knownRef in @(@($current.InitialTriggerRef)+@($current.CurrentContextRefs))){if($knownRef -and (Test-CargoFlowEventMatch $knownRef $start)){$knownEvent=$true;break}}}
            if(-not $knownEvent){$new=$true}
        }
        if($current -and $SupplierIdentity -and $current.SupplierIdentity -ne 'supplier-identity-unknown' -and $current.SupplierIdentity -ne $SupplierIdentity){$new=$true;if(-not $start){if($contactSource){$start=$contactSource}elseif($messages.Count){$start=$messages[-1]}}}
        if(-not $current -or $new){
            if(-not $start -and $messages.Count){$start=$messages[0]}
            $text=$TriggerMessage;$mid=$TriggerMessageId;$at=$TriggerAt
            if($start){$text=[string]$start.Orig;$mid=[string]$start.StableId;$at=[string]$start.MessageTsRaw}
            if(-not $text -and -not $mid){return $null}
            $initial=[pscustomobject]@{MessageId=$mid;Hash=(Get-HumanTaskStableHash $text);At=$at;Line=(Get-CargoFlowRefLine $start $text $at)}
            $current=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');BuyerKey=$key;SupplierIdentity=$(if($SupplierIdentity){$SupplierIdentity}else{'supplier-identity-unknown'});InitialTriggerRef=$initial;CurrentContextRefs=@($initial)}
            Set-HumanTaskField $data flows @($data.flows+$current);Set-HumanTaskField $data.currentFlows $key $current.Id
        } elseif($SupplierIdentity -and $current.SupplierIdentity -eq 'supplier-identity-unknown'){Set-HumanTaskField $current SupplierIdentity $SupplierIdentity}
        $refs=@($current.CurrentContextRefs);$cut=ConvertTo-HumanTaskEpoch $current.InitialTriggerRef.At
        $pastStart=($null -eq $start)
        foreach($m in $messages){if($m -eq $start){$pastStart=$true};if(-not $pastStart){continue};$stamp=ConvertTo-HumanTaskEpoch $m.MessageTsRaw;$hash=Get-HumanTaskStableHash ([string]$m.Orig);if($cut -and $stamp -and $stamp -lt $cut){continue};if(@($refs|Where-Object {($_.MessageId -and $_.MessageId -eq $m.StableId) -or $_.Hash -eq $hash}).Count -eq 0){$refs+= [pscustomobject]@{MessageId=[string]$m.StableId;Hash=$hash;At=[string]$m.MessageTsRaw;Line=(Get-CargoFlowRefLine $m)}}}
        Set-HumanTaskField $current CurrentContextRefs $refs
        if(-not (Save-HumanTaskStore $data)){throw 'FLOW-WRITE-FAILED'}
        return $current
    }
}
function Get-TaskSupplierIdentity($Task) {
    $key=[string](Get-HumanTaskProperty $Task supplierKey '')
    if($key -and $key -notmatch '^email-domain:'){return $key}
    $contact=[string](Get-HumanTaskProperty $Task supplierContact '')
    if($contact){$id=Get-SupplierIdentity $contact;if($id.Confidence -in @('full-contact','full-contact-extracted')){return $id.Key}}
    return 'supplier-identity-unknown'
}
function Test-TaskFlowAssociation($Task,$Conversation,[switch]$ExactSelection) {
    if(-not $Task){return $false};$flow=Get-CurrentCargoFlow ([string]$Task.buyer)
    if(-not $flow -or -not $Task.FlowId -or $Task.FlowId -ne $flow.Id){return $false}
    $identity=Get-TaskSupplierIdentity $Task
    return ($identity -eq $flow.SupplierIdentity)
}
function Select-RelatedHumanTask {
    param([string]$Buyer,[string]$Kind='supplier_verification',[string]$SupplierIdentity='',$Conversation=$null)
    $r=[pscustomobject]@{Selected=$false;Ambiguous=$false;Reason='no-related-task';TaskId='';Kind='';TaskStatus='';SupplierKey='';SupplierContact='';CandidateCount=0}
    $all=@(Get-HumanTaskList -Buyer $Buyer -Kind $Kind);$r.CandidateCount=$all.Count
    $matching=@($all|Where-Object {(Test-TaskFlowAssociation $_ $Conversation) -and (-not $SupplierIdentity -or (Get-TaskSupplierIdentity $_) -eq $SupplierIdentity)})
    if($matching.Count -ne 1){$r.Ambiguous=($all.Count -gt 0);$r.Reason='ambiguous-flow';return $r}
    $t=$matching[0];$r.Selected=$true;$r.Reason='persisted-current-flow';$r.TaskId=$t.id;$r.Kind=Resolve-HumanTaskKind $t.kind;$r.TaskStatus=$t.status;$r.SupplierKey=Get-TaskSupplierIdentity $t;$r.SupplierContact=$t.supplierContact;return $r
}
function Get-SupplierContactCompletionTask([string]$Buyer,[string]$SupplierContact){
    $identity=Get-SupplierIdentity $SupplierContact
    if($identity.Confidence -notin @('full-contact','full-contact-extracted')){return $null}
    $flow=Get-CurrentCargoFlow $Buyer;if(-not $flow -or $flow.SupplierIdentity -ne $identity.Key){return $null}
    $pending=@(Get-HumanTaskList -Buyer $Buyer -Kind supplier_verification -OpenOnly|Where-Object {$_.FlowId -eq $flow.Id -and $_.status -eq 'awaiting_contact' -and (Get-TaskSupplierIdentity $_) -eq 'supplier-identity-unknown'})
    if($pending.Count -eq 1){return $pending[0]};return $null
}
function New-OrUpdate-HumanTask {
    param([string]$Buyer,[string]$Kind,[string]$TriggerMessage='',[string[]]$MissingFields=@(),$FactsSnapshot=$null,[string]$Status='awaiting_contact',[string]$SupplierKey='',[string]$Note='',$Extra=$null)
    Invoke-HumanTaskTransaction {
        $all=@(Get-HumanTaskList);$key=Get-HumanTaskBuyerKey $Buyer;$kindKey=Resolve-HumanTaskKind $Kind;$flowId=[string](Get-HumanTaskProperty $Extra FlowId '')
        $task=@($all|Where-Object {$_.buyerKey -eq $key -and (Resolve-HumanTaskKind $_.kind) -eq $kindKey -and $_.status -in $script:HumanTaskOpenStatuses -and ([string]$_.FlowId -eq $flowId) -and ([string]$_.supplierKey -eq $SupplierKey)}|Select-Object -First 1)
        $created=($task.Count -eq 0);$now=[datetime]::UtcNow.ToString('o')
        if($created){$task=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');buyer=$Buyer;buyerKey=$key;kind=$kindKey;status=$Status;supplierKey=$SupplierKey;FlowId=$flowId;firstTriggerMessage=$TriggerMessage;lastTriggerMessage=$TriggerMessage;missingFields=@($MissingFields);VerificationItems=@($MissingFields|ForEach-Object {[pscustomobject]@{FieldKey=$_;Providers=@($_);SourceRef=(Get-HumanTaskStableHash $TriggerMessage)}});factsSnapshot=$FactsSnapshot;note=$Note;askCount=0;createdAt=$now;updatedAt=$now;notification=[pscustomobject]@{attempts=0;delivered=$false;lastAt='';detail=''};ownerAccepted=$false;ownerAcceptedAt='';deadline='';resolution='';supplierContact='';supplierContactSource='';supplierName='';triggerMessageId='';triggerAt='';actionRecords=@()};$all+= $task}else{$task=$task[0]}
        if($Status -eq 'resolved'){throw 'USE-VERIFIED-COMPLETION'}
        if($task.status -eq 'awaiting_contact' -and $Status -eq 'pending_human'){Set-HumanTaskField $task status $Status}
        $priorMissing=@(Get-HumanTaskProperty $task missingFields @())
        # [独立复核 R05] 明确来源的新增核实事项追加到持久集合：原事项保留，动态缺口变化本身不新增事项。
        $items=@(Get-HumanTaskProperty $task VerificationItems @())
        foreach($mf in @($MissingFields)){
            $mfKey=[string]$mf;if(-not $mfKey){continue}
            if(@($items|Where-Object {[string]$_.FieldKey -eq $mfKey}).Count -gt 0){continue}
            if($priorMissing -contains $mfKey){continue}
            if(-not (Test-HumanTaskVerificationItemRequested $mfKey $TriggerMessage)){continue}
            $items+=[pscustomobject]@{FieldKey=$mfKey;Providers=@($mfKey);SourceRef=(Get-HumanTaskStableHash $TriggerMessage);Source='explicit-trigger';EstablishedAtUtc=$now}
        }
        Set-HumanTaskField $task VerificationItems $items
        Set-HumanTaskField $task lastTriggerMessage $TriggerMessage;Set-HumanTaskField $task missingFields @($MissingFields);Set-HumanTaskField $task updatedAt $now;Set-HumanTaskField $task askCount ([int]$task.askCount+1)
        if($FactsSnapshot){Set-HumanTaskField $task factsSnapshot $FactsSnapshot}
        if($Extra){foreach($p in $Extra.PSObject.Properties){if($p.Name -in @('FlowId','supplierContact','supplierContactSource','supplierName','triggerMessageId','triggerAt')){Set-HumanTaskField $task $p.Name $p.Value}}}
        $ok=Save-HumanTaskStore $all
        return [pscustomobject]@{Task=$task;Created=($created -and $ok);Updated=(-not $created -and $ok);StoreOk=[bool]$ok}
    }
}
function New-OrUpdate-SupplierVerificationTask {
    param([string]$Buyer,[string[]]$MissingFields=@(),[string]$SupplierContact='',[string]$TriggerMessage='',$FactsSnapshot=$null,[string]$SupplierName='',[string]$SupplierId='',[string]$TriggerMessageId='',[string]$TriggerAt='',[string]$Source='',[string]$Note='')
    Invoke-HumanTaskTransaction {
        $identity=Get-SupplierIdentity $SupplierContact $SupplierName $SupplierId
        $flow=Sync-CurrentCargoFlow -Buyer $Buyer -SupplierIdentity $identity.Key -TriggerMessage $TriggerMessage -TriggerMessageId $TriggerMessageId -TriggerAt $TriggerAt
        if(-not $flow){throw 'NO-TRUSTED-FLOW-TRIGGER'}
        if(-not $SupplierContact -and $flow.SupplierIdentity -ne 'supplier-identity-unknown'){
            $associated=@(Get-HumanTaskList -Buyer $Buyer -Kind supplier_verification -OpenOnly|Where-Object {$_.FlowId -eq $flow.Id -and (Get-TaskSupplierIdentity $_) -eq $flow.SupplierIdentity})
            if($associated.Count -eq 1){$SupplierContact=[string]$associated[0].supplierContact;$SupplierName=[string]$associated[0].supplierName;$Source=[string]$associated[0].supplierContactSource;$identity=Get-SupplierIdentity $SupplierContact $SupplierName}
        }
        $old=@(Get-HumanTaskList -Buyer $Buyer -Kind supplier_verification -OpenOnly|Where-Object {$_.FlowId -eq $flow.Id -and $_.supplierKey -eq 'supplier-identity-unknown'})
        if($SupplierContact -and $old.Count -eq 1){$all=@(Get-HumanTaskList);foreach($t in $all){if($t.id -eq $old[0].id){Set-HumanTaskField $t supplierKey $identity.Key}};if(-not(Save-HumanTaskStore $all)){throw 'CONTACT-UPDATE-FAILED'}}
        $extra=[pscustomobject]@{FlowId=$flow.Id;supplierContact=$SupplierContact;supplierContactSource=$Source;supplierName=$SupplierName;triggerMessageId=$TriggerMessageId;triggerAt=$TriggerAt}
        New-OrUpdate-HumanTask -Buyer $Buyer -Kind supplier_verification -TriggerMessage $TriggerMessage -MissingFields $MissingFields -FactsSnapshot $FactsSnapshot -Status $(if($SupplierContact){'pending_human'}else{'awaiting_contact'}) -SupplierKey $identity.Key -Note $Note -Extra $extra
    }
}
# [独立复核 R08] "仍在等待"的说明不等于已回复：先剥离说明标题（Operator note: / 备注：…），再看首句语义。
#   真实收到并给资料的回复（如 "Your supplier has replied."、"Supplier replied: 12 cartons."）不受影响。
function Test-HumanTaskWaitingStatement([string]$RawContent) {
    if([string]::IsNullOrWhiteSpace($RawContent)){return $false}
    $text=[string]$RawContent
    for($i=0;$i -lt 3;$i++){
        $stripped=$text -replace '^\s*(?:[A-Za-z][A-Za-z0-9 _\-\.]{0,24}|[\u4e00-\u9fa5]{1,10})\s*[:：]\s*',''
        if($stripped -eq $text){break}
        $text=$stripped
    }
    if($text -match '(?i)^\s*(still\s+|currently\s+)?(waiting|awaiting|pending|no\s+reply|not\s+yet)\b'){return $true}
    if($text -match '(?i)^\s*(still\s+|currently\s+)?(waiting|awaiting|pending)\b[^.\r\n]{0,40}\b(supplier|vendor|factory|reply|response|confirmation)\b'){return $true}
    return $false
}
function Test-TrustedTaskAction($Record,$Task) {
    if(-not $Record -or -not $Task){return $false}
    return ($Record.taskId -eq $Task.id -and $Record.FlowId -and $Record.FlowId -eq $Task.FlowId -and $Record.supplierKey -eq (Get-TaskSupplierIdentity $Task) -and $Record.source -in @('operator-entry','owner-ui','manual-entry') -and $Record.recordedBy -and $Record.sourceRef -and (ConvertTo-HumanTaskUtc $Record.atUtc) -and $Record.rawContent -and -not (Test-HumanTaskWaitingStatement ([string]$Record.rawContent)))
}
function Add-HumanTaskActionRecord {
    param([string]$Id,[string]$ActionKind,[string]$Source='manual-entry',[string]$RawContent='',[string]$RecordedBy='',[string]$SourceRef='',$AtUtc=$null,$RecordedAtUtc=$null,$ConfirmedFields=@(),[string]$BatchRef='',$CorrectionOfFactRef=$null,[switch]$OccurredNow)
    $out=[pscustomobject]@{Ok=$false;RecordId='';Error='';AllFieldsValid=$false;ValidationResults=@()}
    if(-not $RecordedBy -or -not $SourceRef -or (-not (ConvertTo-HumanTaskUtc $AtUtc) -and -not $OccurredNow) -or $Source -notin @('operator-entry','manual-entry','owner-ui') -or $ActionKind -notin $script:HumanTaskActionKinds -or -not $RawContent -or (Test-HumanTaskWaitingStatement $RawContent)){$out.Error='explicit-action-context-required';return $out}
    Invoke-HumanTaskTransaction {
        $all=@(Get-HumanTaskList);$t=@($all|Where-Object id -eq $Id)[0];if(-not $t){$out.Error='task-not-found';return $out}
        if(-not $t.FlowId){$out.Error='unverified-flow';return $out}
        if($OccurredNow -and -not $AtUtc){$AtUtc=Get-HumanTaskClockUtc}
        $rec=New-HumanTaskActionRecord -ActionKind $ActionKind -Source $Source -RawContent $RawContent -RecordedBy $RecordedBy -SourceRef $SourceRef -AtUtc $AtUtc -RecordedAtUtc $RecordedAtUtc -TaskId $Id -BuyerKey $t.buyerKey -SupplierIdentity (Get-TaskSupplierIdentity $t) -BatchRef $BatchRef
        Set-HumanTaskField $rec FlowId $t.FlowId
        $fields=@();$validations=@()
        foreach($f in @($ConfirmedFields)){ $v=Test-CargoFieldValue ([string]$f.FieldKey) $f.Value ([string]$f.Unit) ([string]$f.Scope);$validations+=$v
            $version=[guid]::NewGuid().ToString('N');$field=[pscustomobject]@{fieldKey=[string]$f.FieldKey;value=$v.Value;unit=$v.Unit;scope=$v.Scope;source='supplier-reply';sourceRef=$SourceRef;Valid=$v.Valid;Reason=$v.Reason;FieldVersion=$version;status='active';CorrectionOfFactRef=$CorrectionOfFactRef}
            $fields+=$field
        }
        if($CorrectionOfFactRef){$target=$null;foreach($r in @(Get-HumanTaskActionRecords $t)){foreach($f in @($r.confirmedFields)){if($r.recordId -eq $CorrectionOfFactRef.RecordId -and $f.fieldKey -eq $CorrectionOfFactRef.FieldKey -and $f.FieldVersion -eq $CorrectionOfFactRef.FieldVersion -and $r.FlowId -eq $CorrectionOfFactRef.FlowId -and $r.supplierKey -eq $CorrectionOfFactRef.SupplierIdentity){$target=$f}}};if(-not $target){$out.Error='correction-target-mismatch';return $out};Set-HumanTaskField $target status 'superseded';Set-HumanTaskField $target supersededBy $rec.recordId}
        Set-HumanTaskField $rec confirmedFields $fields
        Set-HumanTaskField $t actionRecords @(@(Get-HumanTaskActionRecords $t)+$rec)
        if($ActionKind -eq 'resolved'){$check=Test-HumanTaskCompletion $t;if(-not $check.Ok){$out.Error='verification-incomplete';return $out};Set-HumanTaskField $rec CompletionFactRefs $check.FactRefs}
        if(-not (Save-HumanTaskStore $all)){$out.Error='store-write-failed';return $out}
        $out.Ok=$true;$out.RecordId=$rec.recordId;$out.ValidationResults=$validations;$out.AllFieldsValid=(@($validations|Where-Object {-not $_.Valid}).Count -eq 0);return $out
    }
}
function Get-HumanTaskConfirmedFields($Task) {
    $out=@()
    foreach($r in @(Get-HumanTaskActionRecords $Task)){
        if(-not (Test-TrustedTaskAction $r $Task) -or $r.actionKind -ne 'supplier_reply'){continue}
        foreach($f in @($r.confirmedFields)){
            if($f.status -eq 'superseded'){continue};$v=Test-CargoFieldValue $f.fieldKey $f.value $f.unit $f.scope;if(-not $v.Valid){continue}
            $ref=[pscustomobject]@{FlowId=$Task.FlowId;TaskId=$Task.id;RecordId=$r.recordId;FieldKey=$f.fieldKey;FieldVersion=$f.FieldVersion;SupplierIdentity=$r.supplierKey;ValueHash=(Get-HumanTaskStableHash ($v.Value+'|'+$v.Unit+'|'+$v.Scope))}
            $out+=[pscustomobject]@{FieldKey=$f.fieldKey;Value=$v.Value;Unit=$v.Unit;Scope=$v.Scope;Source='supplier-reply';SourceRef=$f.sourceRef;BatchRef=$r.batchRef;TaskId=$Task.id;RecordId=$r.recordId;RecordedAtUtc=$r.recordedAtUtc;SupplierIdentity=$r.supplierKey;FlowId=$Task.FlowId;FactRef=$ref}
        }
    };return $out
}
# [独立复核 R05] 明确来源的新增核实事项：只有确实被本轮触发原文点名的字段才算新增事项。
$script:HumanTaskVerificationItemCues = @{
    carton_count=@('carton','box','pallet','package','件数','箱数','托盘','外包装')
    unit_weight=@('weight','kg','kilo','公斤','千克','重量')
    total_weight=@('weight','总重','总重量')
    unit_dimensions=@('dimension','size','cm','尺寸')
    lot_dimensions=@('dimension','size','cm','尺寸')
    delivery_address=@('address','destination','warehouse','地址','目的地')
    supplier_contact=@('supplier','vendor','factory','供应商','联系')
    recipient_name=@('recipient','consignee','收货','收件')
    recipient_contact=@('recipient','consignee','phone','contact','收货','电话')
}
function Test-HumanTaskVerificationItemRequested([string]$FieldKey,[string]$Trigger) {
    if([string]::IsNullOrWhiteSpace($Trigger)){return $false}
    if(-not $script:HumanTaskVerificationItemCues.ContainsKey($FieldKey)){return $false}
    foreach($cue in @($script:HumanTaskVerificationItemCues[$FieldKey])){if($Trigger -match ('(?i)'+[regex]::Escape($cue))){return $true}}
    return $false
}
# [独立复核 R05] 完成检查必须在同一提交前消费**同流当前有效买家事实**：
#   当前买家给出的有效值与任务确认值不一致时，该核实事项不算满足（未解冲突不得完成）。
function Get-CurrentBuyerConflictItems($Task) {
    $out=@()
    if(-not $Task){return $out}
    if(-not (Get-Command Get-CargoFacts -ErrorAction SilentlyContinue)){return $out}
    if(-not (Get-Command ConvertTo-MessageList -ErrorAction SilentlyContinue)){return $out}
    $flow=$null;try{$flow=Get-CurrentCargoFlow ([string]$Task.buyer)}catch{return $out}
    if(-not $flow -or [string]$flow.Id -ne [string]$Task.FlowId){return $out}
    $lines=@();foreach($ref in @($flow.CurrentContextRefs)){$line=[string](Get-HumanTaskProperty $ref Line '');if($line){$lines+=$line}}
    if(-not $lines.Count){return $out}
    $byKey=$null
    try{$conv=ConvertTo-MessageList (($lines|Select-Object -Unique) -join [string][char]10) ([string]$Task.buyer);$bf=Get-CargoFacts -Conversation $conv -TaskEvidence @();if($bf){$byKey=$bf.ByKey}}catch{return $out}
    if(-not $byKey){return $out}
    $fields=@(Get-HumanTaskConfirmedFields $Task)
    foreach($item in @(Get-HumanTaskProperty $Task VerificationItems @())){
        $key=[string]$item.FieldKey;if(-not $key){continue}
        $providers=@($key);if($key -eq 'weight'){$providers=@('unit_weight','total_weight')};if($key -eq 'dimension'){$providers=@('unit_dimensions','lot_dimensions')}
        foreach($pk in $providers){
            if(-not $byKey.ContainsKey($pk)){continue}
            $bfield=$byKey[$pk]
            if([string](Get-HumanTaskProperty $bfield Status '') -ne 'provided'){continue}
            $bv=[string](Get-HumanTaskProperty $bfield Value '');$bu=[string](Get-HumanTaskProperty $bfield Unit '')
            $matched=@($fields|Where-Object {[string]$_.FieldKey -eq $pk -and [string]$_.Value -eq $bv -and [string]$_.Unit -eq $bu})
            if($matched.Count -eq 0){if($out -notcontains $key){$out+=$key};break}
        }
    }
    return @($out)
}
function Test-HumanTaskCompletion($Task) {
    $fields=@(Get-HumanTaskConfirmedFields $Task);$refs=@();$missing=@()
    $items=@(Get-HumanTaskProperty $Task VerificationItems @())
    if(-not $items.Count){return [pscustomobject]@{Ok=$false;FactRefs=@();Missing=@('unverified-original-items')}}
    $buyerConflicts=@(Get-CurrentBuyerConflictItems $Task)
    foreach($item in $items){$key=[string]$item.FieldKey;$providers=@($item.Providers);if($key -eq 'weight'){$providers=@('unit_weight','total_weight')};if($key -eq 'dimension'){$providers=@('unit_dimensions','lot_dimensions')}
        $found=@($fields|Where-Object {$providers -contains $_.FieldKey});$unique=@($found|ForEach-Object {$_.Value+'|'+$_.Unit+'|'+$_.Scope}|Select-Object -Unique)
        $conflicting=$false;foreach($fk in @($found.FieldKey|Select-Object -Unique)){if(@($found|Where-Object FieldKey -eq $fk|ForEach-Object {$_.Value+'|'+$_.Unit+'|'+$_.Scope}|Select-Object -Unique).Count -gt 1){$conflicting=$true}}
        if($found.Count -eq 0 -or $conflicting -or ($buyerConflicts -contains $key)){$missing+=$key}else{$refs+=@($found|ForEach-Object {$_.FactRef})}
    };return [pscustomobject]@{Ok=($missing.Count -eq 0);FactRefs=$refs;Missing=$missing}
}
function Set-HumanTaskStatus {
    param([string]$Id,[string]$Status,[string]$Note='',[string]$Resolution='')
    Invoke-HumanTaskTransaction {
        if(-not(Test-HumanTaskStatus $Status)){return $false};$all=@(Get-HumanTaskList);$t=@($all|Where-Object id -eq $Id)[0];if(-not $t){return $false}
        if($Status -eq 'resolved'){$c=Test-HumanTaskCompletion $t;if(-not $c.Ok){return $false};Set-HumanTaskField $t CompletionFactRefs $c.FactRefs}
        if($Status -eq 'closed' -and -not $Resolution -and -not $Note){return $false}
        Set-HumanTaskField $t status $Status;Set-HumanTaskField $t resolution $Resolution;Set-HumanTaskField $t note $Note;return [bool](Save-HumanTaskStore $all)
    }
}
