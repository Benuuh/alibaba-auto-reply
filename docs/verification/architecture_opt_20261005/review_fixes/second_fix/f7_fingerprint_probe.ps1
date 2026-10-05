
$ErrorActionPreference = 'Continue'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
Set-Location -LiteralPath $repo
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
$before = Get-AarProductionFingerprint
$w = Get-AarProductionWriterInfo
Write-Output ('writer running=' + $w.Running + ' lockHolder=[' + $w.LockHolder + '] procs=[' + ($w.Processes -join ',') + ']')
Start-Sleep -Seconds 40
$after = Get-AarProductionFingerprint
$diff = @(Compare-AarProductionFingerprint $before $after)
Write-Output ('diff count=' + $diff.Count)
$roots = @((Get-SkillPath 'data'), (Get-SkillPath 'logs'), (Get-SkillPath 'reports'), (Get-SkillPath 'backups'))
foreach ($d in $diff) {
  $path = $d
  foreach ($prefix in @('changed: ', 'created: ', 'removed: ')) { if ($path.StartsWith($prefix)) { $path = $path.Substring($prefix.Length); break } }
  $benign = $false
  foreach ($r in $roots) { if ($r -and (Test-AarPathUnder $path $r)) { $benign = $true; break } }
  Write-Output ('  benign=' + $benign + '  ' + $d)
}
