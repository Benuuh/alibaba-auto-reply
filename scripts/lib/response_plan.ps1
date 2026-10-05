# Program-owned sensitive content. BusinessBody is a separate input with finite admission.
function Get-BusinessBodyAdmission([string]$Text) {
    if(-not $Text){return [pscustomobject]@{Kind='ordinary';Allowed=$true}}
    $catalog=@('Thanks for your message.','Happy to help with this.','Got it, thanks.','Thanks for letting me know.','No problem at all.','I understand.','Supplier contact details help us verify packing.','The chargeable weight is the higher of the actual gross weight and the volumetric weight.','Accurate packing information helps us assess freight requirements.')
    $remaining=$Text.Trim()
    while($remaining){$hit=$false;foreach($sentence in $catalog){if($remaining.StartsWith($sentence,[StringComparison]::OrdinalIgnoreCase)){$remaining=$remaining.Substring($sentence.Length).Trim();$hit=$true;break}};if(-not $hit){$kind='unknown';if($remaining -match '(?i)\b(share|provide|send|confirm|name|contact|time|today|tomorrow|received|stored|replied|called|price|weight|dimensions)\b'){$kind='sensitive'};return [pscustomobject]@{Kind=$kind;Allowed=$false}}}
    return [pscustomobject]@{Kind='ordinary';Allowed=$true}
}
# [独立复核 R07] 运输包装名词来自确认记录本身的单位（pallets 不得被渲染成 cartons）。
function Get-ConfirmedPackageNoun($Fields) {
    foreach($f in @($Fields)){
        if(-not $f -or [string]$f.FieldKey -ne 'carton_count'){continue}
        $u=([string]$f.Unit).Trim().ToLowerInvariant()
        switch -Regex ($u) {
            '^pallet|^skid'   { return 'pallet' }
            '^carton|^ctn'    { return 'carton' }
            '^box'            { return 'box' }
            '^crate'          { return 'crate' }
            '^case'           { return 'case' }
            '^package|^pack'  { return 'package' }
            '^set'            { return 'set' }
            '^drum'           { return 'drum' }
            '^bundle'         { return 'bundle' }
            '^bag'            { return 'bag' }
        }
    }
    return 'carton'
}
function New-ResponsePlan {
    param($Decision)
    $collect=@();$clarify=@();$facts=@();$actions=@();$deps=@();$refs=@()
    if($Decision.DirectFactText){$facts+= [pscustomobject]@{Kind='seller-facts';Text=[string]$Decision.DirectFactText;SourceRefs=@($Decision.FactFragments)}}
    if($Decision.Facts.CargoFacts -and $Decision.LatestBuyerText -match '(?i)\b(received|receive|stored|have you got)\b'){
        $receiptFields=@{supplier_contact="supplier's business contact details";recipient_contact="recipient's delivery contact details";unit_dimensions='packed dimensions per carton';total_weight='total packed weight'}
        foreach($key in $receiptFields.Keys){
            $wanted=switch($key){supplier_contact {$Decision.LatestBuyerText -match '(?i)supplier.*contact'} recipient_contact {$Decision.LatestBuyerText -match '(?i)(recipient|consignee).*contact'} unit_dimensions {$Decision.LatestBuyerText -match '(?i)dimensions'} total_weight {$Decision.LatestBuyerText -match '(?i)total.*weight'}}
            $field=$Decision.Facts.CargoFacts.ByKey[$key]
            if($wanted -and $field -and $field.Status -eq 'provided' -and @($field.Evidence).Count){$facts+=[pscustomobject]@{Kind='received-cargo-fact';Text=('We have received the '+$receiptFields[$key]+'.');SourceRefs=@($field.Evidence)}}
        }
    }
    $ev=$Decision.ActionEvidence
    foreach($request in @(Get-ReplyClarificationRequests -Facts $Decision.Facts -Decision $Decision)){$clarify+=$request}
    foreach($field in @($Decision.AskFields)){
        if($ev -and $ev.ExactTaskMatch -and $ev.IsOpen -and $ev.TaskKind -eq 'supplier_verification' -and $field -in @('carton_count','weight','unit_weight','total_weight','dimension','unit_dimensions','lot_dimensions')){continue}
        $key=Get-ContactFieldKey $field;if(-not $key){$key=$field}
        if(Test-ContactItemProvided $Decision.Facts $key){continue}
        $group=@($script:PolicyAskFieldGroups|Where-Object {$_.Fields -contains $field}|Select-Object -First 1)
        if($group.Count){$provided=$false;if($Decision.Facts.CargoFacts){foreach($candidateKey in $group[0].Fields){if($Decision.Facts.CargoFacts.ByKey.ContainsKey($candidateKey) -and $Decision.Facts.CargoFacts.ByKey[$candidateKey].Status -eq 'provided'){$provided=$true}}};if($provided){continue};$conf=@($clarify|Where-Object {$group[0].Fields -contains $_.FieldKey});if($conf.Count){continue}}
        $collect+=[pscustomobject]@{FieldKey=$key;Label=(Get-AskFieldLabel $field $Decision);Role=$(if($key -like 'supplier*'){'supplier'}elseif($key -like 'recipient*' -or $key -eq 'delivery_address'){'recipient'}else{'cargo'});Purpose='shipping';SourceRef='decision:AskFields'}
    }
    if($ev -and $ev.ExactTaskMatch){
        $deps+=[pscustomobject]@{TaskId=$ev.TaskId;SupplierIdentity=$ev.SupplierIdentity;KeyEvidenceFingerprint=$ev.KeyEvidenceFingerprint}
        foreach($f in @($ev.ConfirmedFields)){if($f.FactRef){$refs+=$f.FactRef}}
        if($ev.IsOpen -and $ev.TodoPersisted -and $ev.TaskKind -eq 'supplier_verification'){
            if($ev.HasUsableSupplierContact){$actions+=[pscustomobject]@{Kind='future-verification';Text='Our team will check the packing information with your supplier.';SourceRef=$ev.TaskId}}
            else{$actions+=[pscustomobject]@{Kind='conditional-verification';Text=(Get-ConditionalSupplierPlanText);SourceRef=$ev.TaskId}}
        }
        if($ev.SupplierReplyRecorded -and $Decision.LatestBuyerText -match '(?i)\b(confirmed|confirmation|supplier.*repl|packing.*verified)\b'){
            # [独立复核 R07] 使用确认记录里的**真实运输包装单位**，不得把托盘改写成箱。
            $packageNoun=Get-ConfirmedPackageNoun @($ev.ConfirmedFields)
            foreach($f in @($ev.ConfirmedFields)){
                $text=''
                switch($f.FieldKey){
                    'carton_count'{$countUnit=([string]$f.Unit).Trim();if(-not $countUnit){$countUnit=$packageNoun+'s'};$text='Your supplier confirmed '+$f.Value+' '+$countUnit+'.'}
                    'unit_weight'{$text='Your supplier confirmed '+$f.Value+' kg per '+$packageNoun+'.'}
                    'total_weight'{$text='Your supplier confirmed a total weight of '+$f.Value+' kg.'}
                    'unit_dimensions'{$text='Your supplier confirmed dimensions per '+$packageNoun+' of '+$f.Value+' '+$f.Unit+'.'}
                }
                if($text){$facts+=[pscustomobject]@{Kind='supplier-confirmation';Text=$text;SourceRefs=@($f.FactRef)}}
            }
        }
    }
    if($Decision.Facts.CargoFacts){foreach($f in @($Decision.Facts.CargoFacts.Fields)){foreach($e in @($f.Evidence)){if($e.FactRef){$refs+=$e.FactRef}}}}
    return [pscustomobject]@{FlowRef=$Decision.Facts.FlowRef;CollectRequests=$collect;ClarificationRequests=$clarify;FactStatements=$facts;ActionStatements=$actions;Dependencies=$deps;FactRefs=@($refs|Sort-Object TaskId,RecordId,FieldKey,FieldVersion -Unique);Decision=$Decision}
}
function Render-ResponsePlan($Plan) {
    $parts=@()
    foreach($fact in $Plan.FactStatements){$parts+=$fact.Text}
    foreach($request in $Plan.CollectRequests){if($request.Label -match '[\r\n<>]' -or $request.Label.Length -gt 150){continue};$parts+='Could you share '+$request.Label+'?'}
    foreach($request in $Plan.ClarificationRequests){
        if($request.FieldKey -eq 'delivery_address' -and $Plan.Decision.Facts.Destination.AmazonContext -and -not $Plan.Decision.Facts.Destination.Candidates.Count){$parts+='Could you share the exact Amazon receiving warehouse code?';continue}
        $label=switch -Regex ($request.FieldKey){'weight'{'weight and its packaging scope'};'dimensions'{'packed dimensions and their scope'};'count'{'transport package count'};'recipient_name'{"recipient's name"};'recipient_contact'{"recipient's delivery contact"};'supplier_contact'{"supplier's business contact"};'delivery_address'{'delivery destination'};default{''}}
        if($label){$parts+='Could you confirm which '+$label+' we should use?'}
    }
    foreach($action in $Plan.ActionStatements){$parts+=$action.Text}
    return ($parts -join ' ')
}
function Test-ResponsePlanDependencies {
    param([string]$Buyer,$Plan)
    if(-not $Plan){return $false}
    try {
        if($Plan.FlowRef){$flow=Get-CurrentCargoFlow $Buyer;if(-not $flow -or $flow.Id -ne $Plan.FlowRef.Id -or $flow.SupplierIdentity -ne $Plan.FlowRef.SupplierIdentity){return $false}}
        foreach($dep in $Plan.Dependencies){$ev=Get-ActionEvidenceForTask -Buyer $Buyer -TaskId $dep.TaskId -SupplierIdentity $dep.SupplierIdentity;if(-not $ev.ExactTaskMatch -or $ev.KeyEvidenceFingerprint -ne $dep.KeyEvidenceFingerprint){return $false}}
        foreach($ref in $Plan.FactRefs){$task=@(Get-HumanTaskList -Buyer $Buyer -TaskId $ref.TaskId);if($task.Count -ne 1 -or -not(Test-TaskFlowAssociation $task[0] $null)){return $false};$fields=@(Get-HumanTaskConfirmedFields $task[0]);$match=@($fields|Where-Object {$_.FactRef.RecordId -eq $ref.RecordId -and $_.FactRef.FieldKey -eq $ref.FieldKey -and $_.FactRef.FieldVersion -eq $ref.FieldVersion -and $_.FactRef.ValueHash -eq $ref.ValueHash});if($match.Count -ne 1){return $false}}
        return $true
    } catch {return $false}
}
function Compose-Reply {
    param($Plan,[string]$BusinessBody='')
    $admission=Get-BusinessBodyAdmission $BusinessBody
    if(-not $admission.Allowed){$BusinessBody=''}
    $program=Render-ResponsePlan $Plan
    $text=(@($program,$BusinessBody)|Where-Object {$_}) -join ' '
    if(-not $text -and $Plan.Decision.CanReply){$BusinessBody='Thanks for your message.';$text=$BusinessBody}
    return [pscustomobject]@{Plan=$Plan;ProgramText=$program;FactText=$program;FactFragments=$Plan.FactStatements;BusinessBody=$BusinessBody;Text=$text;Admission=$admission.Kind;ProgramRange=@(0,$program.Length);BusinessRange=@(($program.Length+1),$BusinessBody.Length)}
}
function New-ReplyCompositionRecord {
    param($Decision,[string]$Text)
    # Compatibility only: no prefix removal or inferred model provenance.
    $plan=New-ResponsePlan $Decision
    return (Compose-Reply -Plan $plan)
}
function Get-ScenarioFallback {
    param($Decision,$Rules=$null)
    if($Decision.PSObject.Properties.Name -contains 'CanReply' -and -not $Decision.CanReply){return ''}
    (Compose-Reply (New-ResponsePlan $Decision) 'Thanks for your message.').Text
}
function Invoke-ReplyGeneration {
    param($Conversation,$Decision,$Rules=$null,[string]$PromptPath,[string]$ScenarioPath,[string]$LogFile,[string[]]$ImageDataUrls=$null,[string]$AttachmentText='',[int]$MaxRewrites=1,[double]$Temperature=0.7,[int]$MaxTokens=400,$RuntimeContext=$null)
    $r=[pscustomobject]@{Text='';Source='BLOCKED';ModelCalls=0;Rewrites=0;Violations=@();FallbackReason='';ContextChars=0;AttachmentNote='';Composition=$null}
    if($Conversation.Anomaly -or -not $Conversation.LatestBuyer -or -not $Decision.CanReply -or $Decision.LatestBuyerText -ne $Conversation.LatestBuyer.Orig){$r.FallbackReason='unverified-reply-input';return $r}
    $plan=New-ResponsePlan $Decision;$body='';$admission=Get-BusinessBodyAdmission ''
    if(-not $Decision.FactOnly -and (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)){
        $context=New-ReplyContextBlock -Conversation $Conversation -Decision $Decision -RuntimeContext $RuntimeContext;$r.ContextChars=$context.Length
        $prompt=(Get-ReplySystemPrompt $PromptPath)+"`nOnly choose ordinary business explanations or polite acknowledgements. Program code owns every request, fact, clarification and action."
        if($ScenarioPath){$prompt+="`n"+(Get-ScenarioGuidance -Path $ScenarioPath -Key $Decision.GuidanceKey)}
        $user=$context;if($AttachmentText){$user+="`n[UNTRUSTED ATTACHMENT]`n"+$AttachmentText}
        $content=$user;if($ImageDataUrls -and (Get-Command New-VisionContentParts -ErrorAction SilentlyContinue)){$content=@(New-VisionContentParts $ImageDataUrls $user)}
        $messages=@(@{role='system';content=$prompt},@{role='user';content=$content})
        $r.ModelCalls++;try{$body=[string](Invoke-LLM $messages $Temperature $MaxTokens $LogFile)}catch{$body='';$r.FallbackReason='llm-failed'}
        $admission=Get-BusinessBodyAdmission $body
        if(-not $admission.Allowed -and $MaxRewrites -gt 0){$r.Rewrites=1;$messages[0].content+="`nRewrite using only registered ordinary business wording, with no requests, facts, prices, actions or times.";$r.ModelCalls++;try{$body=[string](Invoke-LLM $messages $Temperature $MaxTokens $LogFile)}catch{$body='';$r.FallbackReason='llm-failed'};$admission=Get-BusinessBodyAdmission $body}
    }
    if(-not $body){$r.FallbackReason='llm-failed'}
    if(-not(Get-Command Invoke-LLM -ErrorAction SilentlyContinue)){$r.FallbackReason='llm-unavailable'}
    if(-not $admission.Allowed){$body='';$r.FallbackReason='business-body-'+$admission.Kind}
    $composition=Compose-Reply $plan $body
    $check=Test-ReplyCompliance -Text $composition.Text -Rules $Rules -Decision $Decision;$r.Violations=$check.Violations
    if($check.Ok){$r.Text=$composition.Text;$r.Composition=$composition;$r.Source=$(if($Decision.FactOnly){'DIRECT_FACT'}elseif($body){if($r.Rewrites){'LLM_REWRITE'}else{'LLM'}}else{'FALLBACK'})}
    else{$r.FallbackReason+='|controlled-plan-noncompliant'}
    return $r
}
