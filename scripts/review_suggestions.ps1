# review_suggestions.ps1 - VIEW and DECIDE on suggestions. It never applies anything.
#
# [SPEC 5 2026-10-03] "Provide an explicit acceptance entry point, and do not merge 'view the
# suggestion' with 'apply the suggestion'." This script is the VIEW + DECIDE half. Applying is the
# other half and lives in scripts\apply_suggestion.ps1, which refuses to run unless the suggestion
# is already in the 'accepted' state. Nothing here edits an active policy file.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -NoProfile -File review_suggestions.ps1
#   powershell -ExecutionPolicy Bypass -NoProfile -File review_suggestions.ps1 -Status pending
#   powershell -ExecutionPolicy Bypass -NoProfile -File review_suggestions.ps1 -Show sug-1a2b3c4d5e6f7a8b
#   powershell -ExecutionPolicy Bypass -NoProfile -File review_suggestions.ps1 -Accept sug-1a2b... -Note "looks right"
#   powershell -ExecutionPolicy Bypass -NoProfile -File review_suggestions.ps1 -Reject sug-1a2b... -Note "too vague"
param(
    [string]$Status = "",
    [string]$Show = "",
    [string]$Accept = "",
    [string]$Reject = "",
    [string]$Note = "",
    [string]$DataDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\suggestions.ps1")
if (-not $DataDir) { $DataDir = Get-SkillPath "data" }

function Format-One($s) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('---------------------------------------------------------------')
    [void]$lines.Add('id:        ' + $s.id)
    [void]$lines.Add('status:    ' + $s.status + '   seen ' + $s.seenCount + 'x   created ' + $s.created + '   lastSeen ' + $s.lastSeen)
    [void]$lines.Add('title:     ' + $s.title)
    [void]$lines.Add('target:    ' + $s.target.file + '  ->  ' + $s.target.pointer)
    [void]$lines.Add('baseHash:  ' + $s.baseHash)
    [void]$lines.Add('proposed:  ' + $s.change.after)
    [void]$lines.Add('impact:    ' + $s.expectedImpact)
    [void]$lines.Add('evidence:  ' + $s.evidence)
    [void]$lines.Add('conflict:  ' + $s.conflictCheck)
    [void]$lines.Add('offline:   ' + $s.offlineValidation)
    if ($s.appliedAt) { [void]$lines.Add('appliedAt: ' + $s.appliedAt) }
    if ($s.applyFailure) { [void]$lines.Add('applyFailure: ' + $s.applyFailure) }
    if (@($s.decisions).Count -gt 0) {
        [void]$lines.Add('decisions:')
        foreach ($d in @($s.decisions)) { [void]$lines.Add('  - ' + $d.at + '  ' + $d.action + '  ' + $d.note) }
    }
    return ($lines -join [string][char]10)
}

if ($Accept -and $Reject) { Write-Output 'REVIEW-ERR: pass either -Accept or -Reject, not both'; exit 2 }

if ($Accept) {
    $r = Set-SuggestionDecision -DataDir $DataDir -Id $Accept -Action 'accept' -Note $Note
    Write-Output ('REVIEW-ACCEPTED ' + $r.id + ' (status=' + $r.status + ')')
    Write-Output ('NEXT: apply it explicitly with:  powershell -ExecutionPolicy Bypass -NoProfile -File apply_suggestion.ps1 -Id ' + $r.id)
    exit 0
}
if ($Reject) {
    $r = Set-SuggestionDecision -DataDir $DataDir -Id $Reject -Action 'reject' -Note $Note
    Write-Output ('REVIEW-REJECTED ' + $r.id + ' (status=' + $r.status + ')')
    Write-Output 'This exact proposal will not be resubmitted as pending; it is kept with its decision.'
    exit 0
}
if ($Show) {
    $s = Get-SuggestionById -DataDir $DataDir -Id $Show
    if (-not $s) { Write-Output ('REVIEW-NOT-FOUND ' + $Show); exit 1 }
    Write-Output (Format-One $s)
    exit 0
}

$all = @(Get-SuggestionsByStatus -DataDir $DataDir -Status $Status)
Write-Output ('SUGGESTIONS dir: ' + (Get-SuggestionDir $DataDir))
if ($Status) { Write-Output ('filter: status=' + $Status) }
if ($all.Count -eq 0) { Write-Output 'REVIEW-NONE'; exit 0 }
foreach ($s in ($all | Sort-Object @{ Expression = { $_.status } }, @{ Expression = { $_.created } })) { Write-Output (Format-One $s) }
Write-Output '---------------------------------------------------------------'
$byStatus = @{}
foreach ($s in $all) { if (-not $byStatus.ContainsKey($s.status)) { $byStatus[$s.status] = 0 }; $byStatus[$s.status]++ }
$summary = @($byStatus.Keys | Sort-Object | ForEach-Object { $_ + '=' + $byStatus[$_] }) -join ' '
Write-Output ('TOTAL ' + $all.Count + '  ' + $summary)
Write-Output 'Decide with -Accept <id> or -Reject <id>. Applying is a separate command and only works on an accepted suggestion.'
