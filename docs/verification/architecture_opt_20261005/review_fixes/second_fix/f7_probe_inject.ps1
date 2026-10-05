
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$root = Join-Path $env:TEMP ('aar-f7-inject-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
[void](Initialize-AarIsolation -Root $root)
$env:AAR_RUNTIME_ROOT = $root
$dataDir = Join-Path $root 'data'
$outDir = Join-Path $root 'reports'
$stateFile = Join-Path $root 'summary_last.json'
$logFile = Join-Path $root 'monitor_virtual.log'
$LF = [string][char]10
$enc = New-Object System.Text.UTF8Encoding($true)
$buyer = 'Virtual Buyer INJ'
$ts = 1791000000000L
$raw = '# BUYER: ' + $buyer + $LF + '[BUYER] 18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1 @@MT:' + $ts
[System.IO.File]::WriteAllText((Join-Path $dataDir 'msgs_inj_0001.txt'), $raw, $enc)
[System.IO.File]::WriteAllText($logFile, ('2026-10-05 12:00:00 | REPLIED to ' + $buyer + ': SENT_OK' + $LF + '2026-10-05 12:00:00 | Reply text: Thanks for the details.'), $enc)
$inner = @'
. '__REPO__\scripts\config.ps1'
. '__REPO__\scripts\lib\paths.ps1'
. '__REPO__\scripts\lib\msg_norm.ps1'
function Get-QuoteReadinessForSidecarText { throw 'injected facts-model failure' }
& '__REPO__\scripts\summarize.ps1' -LogFile '__LOG__' -OutDir '__OUT__' -StateFile '__STATE__'
'@
$cmd = $inner.Replace('__REPO__', $repo).Replace('__LOG__', $logFile).Replace('__OUT__', $outDir).Replace('__STATE__', $stateFile)
$res = & powershell -ExecutionPolicy Bypass -NoProfile -Command $cmd 2>&1
Write-Output ('inject exit=' + $LASTEXITCODE)
Write-Output ('inject stdout: ' + ($res -join ' | '))
$md = @(Get-ChildItem -LiteralPath $outDir -Filter '*.md')
Write-Output ('report count=' + $md.Count)
if ($md.Count -ge 1) {
    Get-Content -LiteralPath $md[0].FullName -Encoding UTF8 | Where-Object { $_ -match '货物数据齐全度|规则版本|Virtual Buyer INJ|必要缺口|辅助缺口|状态' } | ForEach-Object { Write-Output ('ROW: ' + $_) }
}
Write-Output ('ROOT=' + $root)
