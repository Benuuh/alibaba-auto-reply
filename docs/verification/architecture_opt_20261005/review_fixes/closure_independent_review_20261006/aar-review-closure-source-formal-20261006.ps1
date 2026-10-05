$script:reviewPass=0;$script:reviewFail=0
function ReviewAssert([string]$Name,[bool]$Condition,[string]$Detail){if($Condition){$script:reviewPass++;Write-Output ('PASS '+$Name)}else{$script:reviewFail++;Write-Output ('FAIL '+$Name+' '+$Detail)}}$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' };$env:AAR_TEST_LAYER='Offline'
. (Join-Path $repo 'scripts/config.ps1');. (Join-Path $repo 'scripts/lib/paths.ps1')
$root=Join-Path $env:TEMP ('aar-review-closure-source-'+[guid]::NewGuid().ToString('N'));[void](Initialize-AarIsolation $root)
. (Join-Path $repo 'scripts/reply_engine.ps1');. (Join-Path $repo 'scripts/lib/msg_source.ps1');. (Join-Path $repo 'scripts/lib/sent_records.ps1');. (Join-Path $repo 'scripts/lib/human_pause.ps1');. (Join-Path $repo 'scripts/lib/send.ps1')
$script:now=[datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00',[DateTimeKind]::Utc)
function Get-HumanPauseNowUtc {return $script:now}
function RE($text,$at){[pscustomobject]@{MessageId='';MessageTime=$at;TimePrecision='minute';Text=$text;IsMine=$true}}
function RL($text,$at){'[ME] '+$text+' @@TS:'+$at+' @@MT:'+$at}
function ReviewSync($buyer,$lines){$matches=Get-SentRecordMatchIndexes $buyer $lines;Sync-ConversationInterventionState -Buyer $buyer -Lines $lines -SentMatches $matches -NowUtc $script:now}
Write-Output ('RuntimeRoot='+$root)
$buyer='Virtual Collision Buyer';$a=RE 'Bot and human same printed-minute text.' '1791172800000';$b=RE 'Later automated response.' '1791172860000'
$ra=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $a.Text -Before @() -After @($a);[void](Add-SentRecord -Buyer $buyer -Text $a.Text -Receipt $ra)
$s=ReviewSync $buyer @((RL $a.Text $a.MessageTime),'[BUYER] initial q')
$script:now=$script:now.AddMinutes(1);$lines=@((RL $a.Text $a.MessageTime),(RL $a.Text $a.MessageTime),(RL $b.Text $b.MessageTime),'[BUYER] next q')
$s=ReviewSync $buyer $lines;Write-Output ('Collision-before-correction hold='+$s.UnknownHoldActive+' until='+$s.UnknownHoldUntilUtc.ToString('o'))
$rb=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $b.Text -Before @($a,$a) -After @($a,$a,$b);[void](Add-SentRecord -Buyer $buyer -Text $b.Text -Receipt $rb)
$script:now=$script:now.AddMinutes(1);$s=ReviewSync $buyer $lines
$store=Read-HumanPauseStore;$records=ConvertTo-HumanPauseTable (ConvertTo-HumanPauseTable $store.interventionEvents)[$buyer.ToLowerInvariant()];$ak=Get-InterventionEventIdentity (RL $a.Text $a.MessageTime)
Write-Output ('Collision-after-correction hold='+$s.UnknownHoldActive+' AStoredKind='+$records[$ak].kind+' AReceiptAmbiguous='+(@(Get-SentRecords $buyer)[0]).ambiguous+' expected=True-until-04:05Z')
ReviewAssert 'C1-remaining-collision-must-still-hold' ([bool]($s.SyncOk -and $s.UnknownHoldActive -and $s.UnknownHoldUntilUtc -eq $script:now.AddMinutes(3))) ('observed HoldActive='+$s.UnknownHoldActive+' SyncOk='+$s.SyncOk+' expected until=2026-10-05T04:05:00Z')
[IO.File]::WriteAllText((Get-HumanPauseFile),'{"version":3,"pauses":{"invalid buyer":{"untilUtc":"not-a-time","lastHumanMessageId":"x"}},"sourceUnknownHolds":{},"interventionEvents":{}}')
$s=Sync-ConversationInterventionState -Buyer 'Invalid Buyer' -Lines @('[BUYER] next q') -NowUtc $script:now
Write-Output ('Nested-invalid-deadline SyncOk='+$s.SyncOk+' PauseActive='+$s.HumanPauseActive+' Error=['+$s.Error+'] expected=fail-closed-or-once-bounded-legacy')
ReviewAssert 'C2-invalid-stored-deadline-fails-closed' (-not [bool]$s.SyncOk) ('observed SyncOk='+$s.SyncOk+' PauseActive='+$s.HumanPauseActive+' Error=['+$s.Error+']')
[IO.File]::WriteAllText((Get-HumanPauseFile),'{"version":1,"pauses":{},"sourceUnknownHolds":{"legacy buyer":{"buyer":"Legacy Buyer","lastMessageId":"legacy-u","reason":"unknown"}},"interventionEvents":{}}')
$s=Sync-ConversationInterventionState -Buyer 'Legacy Buyer' -Lines @('[BUYER] next q') -NowUtc $script:now
Write-Output ('Legacy-unknown-no-anchor SyncOk='+$s.SyncOk+' HoldActive='+$s.UnknownHoldActive+' expected=True-once-bounded')
$childTest=Join-Path $root 'runtime-change.tests.ps1';$body=@('$changed=Join-Path $env:TEMP (''aar-unattested-runtime-''+[guid]::NewGuid().ToString(''N''))','[void](Set-SkillRuntimeRoot $changed)','Write-Output (''ActualChildRuntime=''+(Get-SkillRuntimeRoot)+'' MarkerExists=''+(Test-Path (Get-AarIsolationMarkerPath)))','$blocked=$false;try{Assert-AarSendAllowed ''real-egress''}catch{$blocked=$_.Exception.Message -match ''ISOLATION''}', 'Write-Output (''RealEgressStillBlocked=''+$blocked)', 'exit 0') -join [string][char]10
[IO.File]::WriteAllText($childTest,$body,(New-Object Text.UTF8Encoding($true)))
$nonce=[guid]::NewGuid().ToString('N');$proofPath=Join-Path $root 'runtime-proof.json';$childRoot=Join-Path $root 'child-initial'
$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName='powershell.exe';$psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $repo 'tests/run_child.ps1')+'" -TestPath "'+$childTest+'" -Root "'+$childRoot+'" -Nonce '+$nonce+' -ProofPath "'+$proofPath+'"';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$childExit=$p.ExitCode;$proof=Get-Content $proofPath -Raw|ConvertFrom-Json;$check=Test-AarChildAttestation -Proof $proof -ExpectedPID $p.Id -Nonce $nonce -TestName 'runtime-change.tests.ps1'
Write-Output ('Actual-child-root-change Exit='+$p.ExitCode+' Verified='+$check.Ok+' '+$stdout.Result.Trim()+' Error=['+$stderr.Result.Trim()+'] expected=unverified-runtime-change-not-PASS');$p.Dispose()
ReviewAssert 'C3-unattested-current-root-change-cannot-pass' (-not [bool]$check.Ok) ('observed Verified='+$check.Ok+' ChildExit='+$childExit+' '+$stdout.Result.Trim())
Write-Output ('RESULT independent_source_guard pass='+$script:reviewPass+' fail='+$script:reviewFail)
if($script:reviewFail -gt 0){exit 1}