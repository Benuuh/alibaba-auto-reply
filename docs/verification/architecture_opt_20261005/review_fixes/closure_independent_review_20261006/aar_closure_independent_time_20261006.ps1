$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$h=Get-Content -LiteralPath (Join-Path $repo 'tests/review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000')
if($cut -lt 0){throw 'HARNESS-BOUNDARY-MISSING'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + '''')))
$script:independentPass=0;$script:independentFail=0
function Case($id,[scriptblock]$body){try{& $body;$script:independentPass++;Write-Output ('PASS '+$id)}catch{$script:independentFail++;Write-Output ('FAIL '+$id+' '+$_.Exception.Message)}}
function Assert($ok,$why){if(-not $ok){throw $why}}
function Run-Time([string]$q,[string]$local){
 Clear-PauseState;Clear-TaskState;Set-FixNow $local
 $stamp=([DateTimeOffset]$script:nowUtc).ToUnixTimeMilliseconds()
 $ctx=Reset (BLine $q $stamp);$script:modelReply='Happy to help with this.'
 Invoke-ConvoItem $ctx $item|Out-Null
 [pscustomobject]@{Question=$q;LocalClock=$local;Sends=$script:sends;Text=$script:sentText;Calls=$script:modelCalls;Logs=@($script:logs|Where-Object {$_ -match 'GEN|BLOCK|DISCARD'})}|ConvertTo-Json -Depth 7 -Compress|Write-Output
 Assert ($script:sends -eq 1) ('actual entry did not send for '+$q+'; '+($script:logs -join ' | '))
 return $script:sentText
}
Case 'R-T01-cross-day-China' {$v=@(Run-Time 'What time is it in China?' '2026-10-06T00:05:00');$v[0]|Write-Output;Assert ($script:sentText -match '12:05 AM on 2026-10-06 in China') $script:sentText}
Case 'R-T02-cross-day-London' {$v=@(Run-Time 'What time is it in London?' '2026-10-06T00:05:00');$v[0]|Write-Output;Assert ($script:sentText -match '5:05 PM in London') $script:sentText}
Case 'R-T03-same-zone-cities' {$v=@(Run-Time 'What time is it in Beijing and Shanghai?' '2026-10-05T12:00:00');$v[0]|Write-Output;Assert ($script:sentText -match 'in Beijing' -and $script:sentText -match 'in Shanghai') $script:sentText}
Case 'R-T04-multi-place-mixed' {$v=@(Run-Time 'What time is it in China and Japan? Can you help with shipping?' '2026-10-05T12:00:00');$v[0]|Write-Output;Assert ($script:sentText -match '12:00 PM in China' -and $script:sentText -match '1:00 PM in Japan') $script:sentText}
Case 'R-T05-unknown-places' {$v=@(Run-Time 'What time is it in Atlantis? What time is it in Elbonia?' '2026-10-05T12:00:00');$v[0]|Write-Output;Assert ($script:sentText -match 'time in Atlantis' -and $script:sentText -match 'time in Elbonia' -and $script:sentText -notmatch 'UTC\+8') $script:sentText}
Case 'R-T06-buyer-local' {$v=@(Run-Time 'What is my local time?' '2026-10-05T12:00:00');$v[0]|Write-Output;Assert ($script:sentText -match 'Which country or time zone' -and $script:sentText -notmatch 'UTC\+8') $script:sentText}
Write-Output ('RESULT independent_time pass='+$script:independentPass+' fail='+$script:independentFail+' root='+$isoRoot)
if($script:independentFail){exit 1}