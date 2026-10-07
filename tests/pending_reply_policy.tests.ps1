# Real monitor entry; all external page/model/send boundaries injected, stores isolated.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$h=Get-Content (Join-Path $PSScriptRoot 'review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000');if($cut -lt 0){throw 'HARNESS-BOUNDARY'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent',('$repo = '''+$repo+'''')))
. (Join-Path $repo 'scripts/lib/human_tasks.ps1')
$script:pass=0;$script:fail=0;$ts=1791172800000L
function Case($id,[scriptblock]$body){try{& $body;$script:pass++;Write-Output "PASS $id"}catch{$script:fail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
function Assert($ok,$why){if(-not $ok){throw $why}}
$script:pendingJson='[{"name":"Virtual Buyer"}]'
function Get-Snapshot { return $script:pendingJson }
function Switch-ToPendingTab { $script:reopens++ }
function Invoke-LLM {param($Messages,$Temperature,$MaxTokens,$LogFile)
    $script:modelCalls++
    if($script:leavePending){$script:pendingJson='[]'}
    if($script:changeBuyer){$script:raw=BLine 'A different shipment now.' ($ts+1000)}
    return $script:modelReply
}
Case natural-model-body-survives {
    Clear-TaskState;Clear-PauseState;$ctx=Reset (BLine 'I need to ship furniture.' $ts)
    $script:modelReply='Furniture packaging affects space usage during transport. Package measurements help estimate shipment volume.'
    Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 1 -and $script:sentText.Contains($script:modelReply)) ('natural unregistered body must reach send: '+$script:sentText+' logs: '+($script:logs -join ' | '))
    Assert ($script:modelCalls -eq 1) 'ordinary body does not need rewrite'
}
Case protected-body-one-rewrite {
    foreach($bad in @('Our rate is 100 USD.','We have contacted your supplier.','Could you send the private email?','The supplier confirmed 99 kg.','At this moment the clock is half past midnight in China.')){
        Clear-TaskState;$ctx=Reset (BLine 'I need to ship furniture.' $ts);$script:modelReply=$bad
        Invoke-ConvoItem $ctx $item|Out-Null
        Assert ($script:sends -eq 1 -and -not $script:sentText.Contains($bad)) ('protected content survived: '+$bad)
        Assert ($script:modelCalls -eq 2) 'one rewrite then controlled fallback'
    }
}
Case final-pending-gate {
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts);$script:leavePending=$true;$script:modelReply='Protective packing helps during transport.'
    try{Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 0 -and $script:ledgerWrites -eq 0) 'no longer pending must not send'}finally{$script:leavePending=$false;$script:pendingJson='[{"name":"Virtual Buyer"}]'}
}
Case changed-input-discards-draft {
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts);$script:changeBuyer=$true
    try{Invoke-ConvoItem $ctx $item|Out-Null;Assert ($script:sends -eq 0 -and $script:ledgerWrites -eq 0) 'new buyer input must discard draft'}finally{$script:changeBuyer=$false}
}
$originalOpen=(Get-Command Open-ConvoAndGetMessages).ScriptBlock
Case read-failure-rereads-once-then-human {
    Clear-TaskState;$ctx=Reset;$script:reopens=0
    function Open-ConvoAndGetMessages($name){$script:reads++;return 'READ_NOT_READY'}
    try{
        Invoke-ConvoItem $ctx $item|Out-Null
        Assert ($script:reads -eq 2 -and $script:reopens -eq 1 -and $script:sends -eq 0) 'one reread, no send'
        $tasks=@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly | Where-Object kind -eq pending_reply)
        Assert ($tasks.Count -eq 1 -and $tasks[0].lastTriggerMessage -eq 'READ_NOT_READY') 'real human task stores reason'
        Invoke-ConvoItem $ctx $item|Out-Null
        Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly | Where-Object kind -eq pending_reply).Count -eq 1) 'reread failure does not duplicate task'
    }finally{Set-Item Function:Open-ConvoAndGetMessages $originalOpen}
}
Case stale-pending-task-is-idempotent {
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts);$script:modelReply='Protective packing helps during transport.'
    Invoke-ConvoItem $ctx $item|Out-Null;Invoke-ConvoItem $ctx $item|Out-Null;Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 1) 'answered event cannot resend'
    Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly | Where-Object kind -eq pending_reply).Count -eq 1) 'stale pending gets one human task'
}
Case one-read-failure-does-not-stop-other-buyers {
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts);$script:reopens=0;$script:scanCycleNo=0
    $script:pendingJson='[{"name":"Virtual Buyer"},{"name":"Other Buyer"}]'
    function Open-ConvoAndGetMessages($name){$script:reads++;if($name -eq 'Virtual Buyer'){return 'READ_NOT_READY'};return [pscustomobject]@{name=$name;msgs=$script:raw;profile=''}}
    try{
        Invoke-ScanRound $ctx|Out-Null
        Assert ($script:sends -eq 1) ('other buyer must send: '+($script:logs -join ' | '))
        Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly | Where-Object kind -eq pending_reply).Count -eq 1) 'failed buyer task kept'
    }finally{Set-Item Function:Open-ConvoAndGetMessages $originalOpen;$script:pendingJson='[{"name":"Virtual Buyer"}]'}
}
Case task-store-failure-does-not-throw {
    $storeBody=(Get-Command New-OrUpdate-HumanTask).ScriptBlock
    function New-OrUpdate-HumanTask {throw 'fixture-store-unreadable'}
    try{$r=New-PendingReplyHumanTask -Buyer 'Virtual Buyer' -Reason 'read failed';Assert (-not $r.StoreOk) 'failure must be returned and logged'}finally{Set-Item Function:New-OrUpdate-HumanTask $storeBody}
}
Case retry-uses-pending-not-me-tail {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/monitor.ps1'),[ref]$null,[ref]$null)
    $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Send-PendingRetry'},$true)
    Invoke-Expression $fn.Extent.Text
    Clear-TaskState;$ctx=Reset ((BLine 'I need shipping.' $ts)+"`n"+(MeLine 'platform reception' ($ts+1000)));$script:modelReply='Shipment volume affects transport planning.'
    function Test-PendingReplyObsolete {throw 'me-tail must not decide pending retry'}
    Assert ((Send-PendingRetry $ctx 'Virtual Buyer') -eq 'PROCESSED' -and $script:sends -eq 1) 'in pending platform reception still sends'
    $script:pendingJson='[]'
    try{Assert ((Send-PendingRetry $ctx 'Virtual Buyer') -eq 'NOT_IN_LIST' -and $script:sends -eq 1) 'not pending never sends'}finally{$script:pendingJson='[{"name":"Virtual Buyer"}]'}
}
Case buyer-word-is-not-ui-noise {
    Clear-TaskState;$ctx=Reset (BLine 'Why does 自动接待 appear in my chat?' $ts);$script:modelReply='The chat shows the reception label.'
    Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 1) 'a real buyer body mentioning UI labels must not be discarded'
}
Case unknown-direction-is-read-failure-not-source-wait {
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts)
    $meta=ConvertTo-MessageMetaMarker ([pscustomobject]@{v='msgevent-2026-10-07.1';t=(B64 'Ambiguous bubble');dir='unknown';dirsrc='conflict';ts=($ts+1000);tprec='second';st='message';src=@();mid='';at='2026-10-05T04:00:00Z';idq='unusable'})
    $script:raw += "`n"+'[ME] Ambiguous bubble @@MT:'+($ts+1000)+' '+$meta
    Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 0 -and $script:modelCalls -eq 0) 'direction conflict must block before model or send'
    Assert (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly | Where-Object {$_.kind -eq 'pending_reply' -and $_.lastTriggerMessage -match 'direction-unverified'}).Count -eq 1) 'read failure requires a persisted human task'
    Clear-TaskState;$ctx=Reset (BLine 'I need shipping.' $ts)
    $meta=ConvertTo-MessageMetaMarker ([pscustomobject]@{v='msgevent-2026-10-07.1';t=(B64 'Reception bubble');dir='out';dirsrc='layout';ts=($ts+1000);tprec='second';st='message';src=@();mid='';at='2026-10-05T04:00:00Z';idq='composite'})
    $script:raw += "`n"+'[ME] Reception bubble @@MT:'+($ts+1000)+' '+$meta
    Invoke-ConvoItem $ctx $item|Out-Null
    Assert ($script:sends -eq 1) 'unknown sender with proven out direction must not delay pending'
}
Case trigger-identity-is-persisted {
    . (Join-Path $repo 'scripts/lib/send_attempts.ps1')
    $event=(ConvertTo-MessageList (BLine 'Same words.' $ts) 'Virtual Buyer').LatestBuyer
    $attempt=New-PersistedSendAttempt -Buyer 'Identity Fixture' -Text 'Prepared only.' -TriggerIdentity $event.StableId
    Assert ($attempt.Ok -and (Get-SendAttempt $attempt.AttemptId).triggerIdentity -ceq $event.StableId) 'exact trigger identity must survive actual isolated storage'
}
Write-Output "RESULT pass=$script:pass fail=$script:fail"
if($script:fail){exit 1}
