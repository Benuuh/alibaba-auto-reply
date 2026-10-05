$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/config.ps1')
. (Join-Path $repo 'scripts/lib/paths.ps1')
$root=Join-Path $env:TEMP ('aar-closure-s3-'+[guid]::NewGuid().ToString('N'));[void](Initialize-AarIsolation $root)
. (Join-Path $repo 'scripts/reply_engine.ps1')
. (Join-Path $repo 'scripts/lib/msg_source.ps1')
. (Join-Path $repo 'scripts/lib/sent_records.ps1')
. (Join-Path $repo 'scripts/lib/human_pause.ps1')
. (Join-Path $repo 'scripts/lib/send.ps1')
$script:pass=0;$script:fail=0
function Assert($ok,$msg='assertion failed'){if(-not $ok){throw $msg}}
function Case($id,[scriptblock]$body){try{& $body;$script:pass++;Write-Output "PASS $id"}catch{$script:fail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
function ClearFixture {foreach($f in @((Get-SentRecordFile),((Get-SentRecordFile)+'.bak'),(Get-HumanPauseFile),((Get-HumanPauseFile)+'.bak'))){if(Test-Path $f){Remove-Item -LiteralPath $f -Force}}}
$now=[datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00',[DateTimeKind]::Utc);$text='Thanks for your message.'
function Snapshot($id,$stamp,$body=$text){[pscustomobject]@{MessageId=$id;MessageTime=$stamp;TimePrecision='millisecond';Text=$body;IsMine=$true}}
function Receipt($id,$stamp){New-ConfirmedOutboundReceipt -Buyer 'Closure Buyer' -Text $text -Before @() -After @((Snapshot $id $stamp))}
Case H01 {ClearFixture;$receipt=Receipt bot1 '2026-10-05T04:00:00Z';Assert (Add-SentRecord -Buyer 'Closure Buyer' -Text $text -Receipt $receipt);$lines=@("[ME] $text @@MID:bot1 @@MT:1791172800000", "[ME] $text @@MID:human1 @@MT:1791172860000", "[ME] $text Also check packing. @@MID:human2 @@MT:1791172860001");$map=Get-SentRecordMatchIndexes 'Closure Buyer' $lines;Assert ($map.Count -eq 1 -and $map.ContainsKey(0));$sync=Sync-ConversationInterventionState -Buyer 'Closure Buyer' -Lines $lines -SentMatches $map -NowUtc $now.AddMinutes(1);Assert $sync.SyncOk;Assert ($sync.UnknownHoldActive -or $sync.HumanPauseActive) }
Case H02 {ClearFixture;foreach($pair in @(@('b1','2026-10-05T04:00:00Z'),@('b2','2026-10-05T04:01:00Z'))){Assert (Add-SentRecord -Buyer 'Closure Buyer' -Text $text -Receipt (Receipt $pair[0] $pair[1]))};Assert (@(Get-SentRecords 'Closure Buyer').Count -eq 2);$map=Get-SentRecordMatchIndexes 'Closure Buyer' @("[ME] $text @@MID:b1", "[ME] $text @@MID:b2");Assert ($map.Count -eq 2) }
Case H03 {ClearFixture;Assert (Add-SentRecord -Buyer 'Closure Buyer' -Text $text -Receipt (Receipt b1 '2026-10-05T04:00:00Z'));$map=Get-SentRecordMatchIndexes 'Closure Buyer' @("[ME] $text @@MID:b1");Assert ($map.Count -eq 1);Assert ((Get-MessageSourceClass "[ME] $text").Class -ne 'bot');$r=New-ConfirmedOutboundReceipt -Buyer 'Closure Buyer' -Text $text -Before @() -After @((Snapshot '' '2026-10-05T04:00:00Z'),(Snapshot '' '2026-10-05T04:00:00Z'));Assert (-not $r.Valid) }
Case H04 {ClearFixture;$r=Receipt '' '2026-10-05T04:00:00Z';Assert (Add-SentRecord -Buyer 'Closure Buyer' -Text $text -Receipt $r);$line="[ME] $text @@MT:1791172800000";$map=Get-SentRecordMatchIndexes 'Closure Buyer' @($line,$line);Assert ($map.Count -eq 0);$map=Get-SentRecordMatchIndexes 'Closure Buyer' @($line);Assert ($map.Count -eq 0) 'observed ambiguity stays denied after truncation' }
function Event($id,$at,$trust='reliable'){[pscustomobject]@{Identity=$id;AtUtc=[datetime]$at;TimeTrust=$trust;TimeSource='fixture';Preview=$id}}
Case H05 {ClearFixture;Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -UnknownEvents @((Event A $now),(Event B $now.AddMinutes(1))) -NowUtc $now.AddMinutes(1)).SyncOk;Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -BotEvents @((Event B $now.AddMinutes(1))) -NowUtc $now.AddMinutes(2)).SyncOk;Assert (Test-SourceUnknownHoldActive 'Closure Buyer' -NowUtc $now.AddMinutes(4)).Active;Assert (-not (Test-SourceUnknownHoldActive 'Closure Buyer' -NowUtc $now.AddMinutes(5)).Active) }
Case H06 {ClearFixture;Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -HumanEvents @((Event A $now.AddHours(5) anomalous-future),(Event B $now.AddMinutes(1))) -NowUtc $now.AddMinutes(1)).SyncOk;Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -BotEvents @((Event B $now.AddMinutes(1))) -NowUtc $now.AddMinutes(2)).SyncOk;$until=Get-HumanPauseUntilUtc (Get-HumanPause 'Closure Buyer');Assert ($until -le $now.AddMinutes(6)) 'do not recalculate from anomalous raw atUtc' }
Case H07 {ClearFixture;Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -HumanEvents @((Event A $now)) -NowUtc $now).SyncOk;Assert ((Get-HumanPauseUntilUtc (Get-HumanPause 'Closure Buyer')) -eq $now.AddMinutes(5));Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -HumanEvents @((Event A $now),(Event B $now.AddMinutes(3))) -NowUtc $now.AddMinutes(3)).SyncOk;. (Join-Path $repo 'scripts/lib/human_pause.ps1');Assert (Invoke-InterventionEventSync -Buyer 'Closure Buyer' -HumanEvents @((Event B $now.AddMinutes(3))) -NowUtc $now.AddMinutes(4)).SyncOk;Assert ((Get-HumanPauseUntilUtc (Get-HumanPause 'Closure Buyer')) -eq $now.AddMinutes(8)) }
Case H08 {foreach($raw in @('',' ','{"pauses":"wrong"}')){ClearFixture;$path=Get-HumanPauseFile;[IO.File]::WriteAllText($path,$raw);$r=Sync-ConversationInterventionState -Buyer 'Closure Buyer' -Lines @('[BUYER] hello') -NowUtc $now;Assert (-not $r.SyncOk)} }
Write-Output "RESULT closure_s3 pass=$script:pass fail=$script:fail root=$root"
if($script:fail){exit 1}
