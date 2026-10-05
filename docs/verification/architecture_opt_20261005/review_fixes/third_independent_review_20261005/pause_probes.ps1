$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
$iso = Join-Path $env:TEMP ('aar-review-third-pause-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $iso)
$env:AAR_RUNTIME_ROOT=$iso
. (Join-Path $repo 'scripts\lib\state_store.ps1')
. (Join-Path $repo 'scripts\lib\msg_source.ps1')
. (Join-Path $repo 'scripts\lib\sent_records.ps1')
. (Join-Path $repo 'scripts\lib\human_pause.ps1')
$script:utc=[datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
function Get-HumanPauseNowUtc { return $script:utc }
function Mt([datetime]$t){ return ([DateTimeOffset]$t).ToUnixTimeMilliseconds() }
function ReviewHumanLine([string]$text,[datetime]$t){ return '[ME] '+$text+' @@MT:'+(Mt $t) }
function U([string]$text,[datetime]$t){ return '[ME] '+$text+' @@TS:'+(Mt $t)+' @@MT:'+(Mt $t) }
function Sync([string]$buyer,[string[]]$lines,$matches){return Sync-ConversationInterventionState -Buyer $buyer -Lines $lines -SentMatches $matches -NowUtc $script:utc}
Write-Output ('IsolationRoot='+$iso)
# P1: actual sent record -> repeated identical human text at another message time is classified as bot
$buyer='Virtual Repeat Buyer'
[void](Add-SentRecord -Buyer $buyer -Text 'Thanks, we will check the cargo details.' -SentAt $script:utc.ToString('o'))
$script:utc=$script:utc.AddMinutes(1)
$lines=@((ReviewHumanLine 'Thanks, we will check the cargo details.' $script:utc.AddMinutes(-1)), (ReviewHumanLine 'Thanks, we will check the cargo details.' $script:utc), '[BUYER] any updates?')
$matches=Get-SentRecordMatchIndexes -Buyer $buyer -Lines $lines
$s=Sync $buyer $lines $matches
Write-Output ('P1-repeat-text matches='+($matches.Keys -join ',')+' HumanPauseActive='+$s.HumanPauseActive+' NewHuman='+@($s.NewHumanEvents).Count+' SourceSecond='+(Get-MessageSourceClass $lines[1] $matches[1]).Class)
# P2: future-stamped human stored with bounded firstSeen, bot correction recomputes with untrusted atUtc
$script:utc=[datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$future=ReviewHumanLine 'real human future stamp' $script:utc.AddHours(5)
$mis=ReviewHumanLine 'misclassified bot with mt only' $script:utc.AddMinutes(1)
$s=Sync 'Virtual Future Buyer' @($future,$mis) @{}
Write-Output ('P2-future before='+ (Get-HumanPause 'Virtual Future Buyer').untilUtc)
$script:utc=$script:utc.AddMinutes(2)
[void](Add-SentRecord -Buyer 'Virtual Future Buyer' -Text 'misclassified bot with mt only' -SentAt $script:utc.AddMinutes(-1).ToString('o'))
$s=Sync 'Virtual Future Buyer' @($future,$mis) (Get-SentRecordMatchIndexes -Buyer 'Virtual Future Buyer' -Lines @($future,$mis))
Write-Output ('P2-future after='+(Get-HumanPause 'Virtual Future Buyer').untilUtc+' active='+$s.HumanPauseActive+' corrects='+@($s.CorrectedBotEvents).Count+' expectedNotAfter=2026-10-05T04:06:00Z')
# P1/P2: latest unknown gets confirmed-bot; earlier unknown still active must retain its own hold
$script:utc=[datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$u1=U 'first unknown message' $script:utc
$u2=U 'later actually bot message' $script:utc.AddMinutes(1)
$s=Sync 'Virtual Unknown Buyer' @($u1,$u2,'[BUYER] followup') @{}
Write-Output ('P3-unknown before='+(Get-SourceUnknownHold 'Virtual Unknown Buyer').untilUtc)
$script:utc=$script:utc.AddMinutes(2)
[void](Add-SentRecord -Buyer 'Virtual Unknown Buyer' -Text 'later actually bot message' -SentAt $script:utc.AddMinutes(-1).ToString('o'))
$s=Sync 'Virtual Unknown Buyer' @($u1,$u2,'[BUYER] followup') (Get-SentRecordMatchIndexes -Buyer 'Virtual Unknown Buyer' -Lines @($u1,$u2,'[BUYER] followup'))
Write-Output ('P3-unknown afterActive='+$s.UnknownHoldActive+' remainingUnknownCount='+@(Get-InterventionEvents -Lines @($u1,$u2,'[BUYER] followup') -SentMatches @{1=$true} -NowUtc $script:utc -Unknown).Count+' expectedUntil=2026-10-05T04:05:00Z')
# G1 proof switch ignores proof data content
$g=Get-AarProductionPathAudit -Changes @([pscustomobject]@{Path='C:\fictional-prod\data\x.json'}) -WriterInfo ([pscustomobject]@{Running=$true}) -WriterOutputRoots @('C:\fictional-prod\data') -AttributionProven
Write-Output ('G1-emptyProof result='+$g.Result+' evidence=['+$g.AttributionEvidence+']')