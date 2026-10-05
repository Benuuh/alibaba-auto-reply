$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$files=@(Get-ChildItem -Path (Join-Path $repo 'scripts'),(Join-Path $repo 'tests'),(Join-Path $repo 'tools') -Recurse -Filter *.ps1 -File | Sort-Object FullName)
$parseErrors=0;$bomMissing=@()
foreach($f in $files){
    $errs=$null;$tokens=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$tokens,[ref]$errs)
    if($errs -and @($errs).Count -gt 0){$parseErrors++;Write-Output ('PARSE-ERROR ' + $f.FullName + ' :: ' + (@($errs|ForEach-Object {$_.Message}) -join ' | '))}
    $bytes=[IO.File]::ReadAllBytes($f.FullName)
    if(-not($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)){$bomMissing+=$f.FullName.Replace($repo+'\','')}
}
Write-Output ('ENGINE=' + $PSVersionTable.PSVersion.ToString() + ' PS51_PARSE files=' + $files.Count + ' errors=' + $parseErrors + ' BOM_SCAN missing=' + $bomMissing.Count)
foreach($m in $bomMissing){Write-Output ('BOM-MISSING ' + $m)}