$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$h=Get-Content -LiteralPath "$repo\tests\review_fixes_entry.tests.ps1" -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000')
if($cut -lt 0){throw 'Harness boundary missing'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + '''')))
Set-FixNow '2026-10-05T12:00:00'
Clear-PauseState
Clear-TaskState
$ts=[long]1791172800000
$ctx=Reset (BLine "I don't know the packed dimensions." $ts)
$script:modelReply="Please provide the supplier's contact details together with contact details so we can reach you."
Invoke-ConvoItem $ctx $item
[pscustomobject]@{Probe='contact-redline-real-entry';Sends=$script:sends;ModelCalls=$script:modelCalls;Text=$script:sentText;TaskRef=$script:turnTaskRef;Logs=@($script:logs|Where-Object{$_ -match 'REPLY-GEN|SEND-GATE'});IsolationRoot=$isoRoot}|ConvertTo-Json -Depth 12 -Compress|Write-Output
if($script:sends -gt 0 -and $script:sentText -match 'contact details so we can reach you'){Write-Output 'INDEPENDENT-FAIL: generic buyer contact request reached send';exit 1}
