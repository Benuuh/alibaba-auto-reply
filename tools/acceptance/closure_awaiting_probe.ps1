$ErrorActionPreference='Stop';$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$h=Get-Content (Join-Path $repo 'tests/review_fixes_entry.tests.ps1') -Raw -Encoding UTF8;$cut=$h.IndexOf('$ts0 = [long]1791172800000');Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent',('$repo = '''+$repo+'''')))
Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'I cannot provide the packing dimensions.' 1791172800000);$script:modelReply='Happy to help with this.';Invoke-ConvoItem $ctx $item|Out-Null
$ok=($script:sends -eq 1 -and $script:sentText -match 'Once you share' -and $script:sentText -notmatch 'Could you share (?:the total weight|the.*dimensions|the.*carton)')
Write-Output ('ACTUAL-SEND count='+$script:sends+' text='+$script:sentText);if($ok){Write-Output 'PASS D04-awaiting-conditional';exit 0}else{Write-Output 'FAIL D04-awaiting-conditional';$script:logs|Where-Object {$_ -match 'REPLY-GEN|SEND-GATE'};exit 1}
