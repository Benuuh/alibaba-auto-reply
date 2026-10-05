# A receipt binds an exact new outbound event. DOM position is never an identity.
function Get-OutboundEventKey($Event) {
    if($Event.MessageId){return 'id:'+[string]$Event.MessageId}
    if($Event.MessageTime -and $Event.TimePrecision -in @('millisecond','second','minute')){return 'at:'+[string]$Event.MessageTime+'|'+(Get-MessageLineFingerprint (Get-SentRecordNormText $Event.Text))}
    return ''
}
function Get-ReceiptTimestamp([string]$Time) {
    if($Time -match '^\d{13}$'){return $Time}
    $parsed=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse($Time,[ref]$parsed)){return [string]$parsed.ToUnixTimeMilliseconds()}
    return ''
}
function New-ConfirmedOutboundReceipt {
    param([string]$Buyer,[string]$Text,$Before=@(),$After=@())
    $r=[pscustomobject]@{Valid=$false;BuyerKey=(Get-SentRecordKey $Buyer);ReceiptId=[guid]::NewGuid().ToString('N');MessageId='';MessageTime='';TimePrecision='';TextHash=(Get-MessageLineFingerprint (Get-SentRecordNormText $Text));BeforeKeys=@();AfterKeys=@();ConfirmationType='';Error='no-unique-new-event'}
    $beforeKeys=@($Before|ForEach-Object {Get-OutboundEventKey $_});$afterKeys=@($After|ForEach-Object {Get-OutboundEventKey $_});$r.BeforeKeys=$beforeKeys;$r.AfterKeys=$afterKeys
    $matches=@($After|Where-Object {$_.IsMine -and (Get-SentRecordNormText $_.Text) -eq (Get-SentRecordNormText $Text)})
    $new=@($matches|Where-Object {$key=Get-OutboundEventKey $_;$key -and $beforeKeys -notcontains $key -and @($afterKeys|Where-Object {$_ -eq $key}).Count -eq 1})
    if($new.Count -ne 1){return $r};$m=$new[0]
    if(-not $m.MessageId -and @($beforeKeys|Where-Object {$_}).Count -ne @($Before).Count){$r.Error='incomplete-before-identities';return $r}
    $r.MessageId=[string]$m.MessageId;$r.MessageTime=[string]$m.MessageTime;$r.TimePrecision=[string]$m.TimePrecision;$r.ConfirmationType=$(if($m.MessageId){'new-platform-message-id'}else{'unique-exact-new-event'});$r.Valid=$true;$r.Error='';return $r
}
function Get-OutboundSnapshot {
    # Uses only selectors and per-message printed time already consumed by monitor extraction.
    $scriptText=@'
(function(){
  var rows=Array.from(document.querySelectorAll('[class*=message-item-wrapper]'));
  return JSON.stringify(rows.map(function(row){
    var rich=row.querySelector('.session-rich-content.text') || row.querySelector('.content-with-translation .session-rich-content') || row.querySelector('.content-with-translation.text-content');
    var name=row.querySelector('.item-base-info .name');
    var base=row.querySelector('.item-base-info');
    var match=((base && base.innerText)||'').match(/\b(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\b/);
    var time=''; var precision='';
    if(match){var y=+match[1],mo=+match[2]-1,d=+match[3],h=+match[4],mi=+match[5],s=+(match[6]||0);var dt=new Date(y,mo,d,h,mi,s);if(dt.getFullYear()===y && dt.getMonth()===mo && dt.getDate()===d && dt.getHours()===h && dt.getMinutes()===mi){time=String(dt.getTime());precision=match[6]?'second':'minute';}}
    return {MessageId:'',MessageTime:time,TimePrecision:precision,Text:rich?(rich.innerText||'').replace(/\n+/g,' ').trim():'',IsMine:!(name && name.innerText.trim()) && (row.className||'').indexOf('item-left')<0};
  }));
})()
'@
    $raw=Invoke-SendEval $scriptText
    $parsed=$raw|ConvertFrom-Json
    if($null -eq $parsed){throw 'OUTBOUND-SNAPSHOT-UNREADABLE'}
    return @($parsed)
}

function Test-ConfirmedOutboundReceipt($Receipt,[string]$Buyer,[string]$Text) {
    if(-not $Receipt -or -not $Receipt.Valid -or $Receipt.BuyerKey -ne (Get-SentRecordKey $Buyer) -or $Receipt.TextHash -ne (Get-MessageLineFingerprint (Get-SentRecordNormText $Text))){return $false}
    $event=[pscustomobject]@{MessageId=$Receipt.MessageId;MessageTime=$Receipt.MessageTime;TimePrecision=$Receipt.TimePrecision;Text=$Text};$key=Get-OutboundEventKey $event
    return ($key -and @($Receipt.AfterKeys|Where-Object {$_ -eq $key}).Count -eq 1 -and @($Receipt.BeforeKeys|Where-Object {$_ -eq $key}).Count -eq 0 -and ($Receipt.MessageId -or (Get-ReceiptTimestamp $Receipt.MessageTime)))
}
