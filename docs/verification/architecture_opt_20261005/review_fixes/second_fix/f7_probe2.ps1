
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$root = Join-Path $env:TEMP ('aar-f7-probe2-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
[void](Initialize-AarIsolation -Root $root)
$env:AAR_RUNTIME_ROOT = $root
. (Join-Path $repo 'scripts\lib\goods.ps1')
. (Join-Path $repo 'scripts\lib\quote.ps1')
$dataDir = Join-Path $root 'data'
$LF = [string][char]10
$enc = New-Object System.Text.UTF8Encoding($true)
$ts = 1791000000000L
function Save([string]$buyer, [string]$file, [string[]]$msgs) {
    $lines = @(); $t = 1791000000000L
    foreach ($m in $msgs) { $lines += ('[BUYER] ' + $m + ' @@MT:' + $t); $t += 1000 }
    [System.IO.File]::WriteAllText((Join-Path $dataDir $file), ('# BUYER: ' + $buyer + $LF + ($lines -join $LF)), $enc)
}
Save 'Virtual Buyer F5' 'msgs_f5_0001.txt' @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1','Change to Amazon TEST2')
Save 'Virtual Buyer F6' 'msgs_f6_0001.txt' @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1','Sorry, correction: 24 cartons')
Save 'Virtual Buyer F2' 'msgs_f2_0001.txt' @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1')
foreach ($b in @('Virtual Buyer F2','Virtual Buyer F5','Virtual Buyer F6')) {
    $st = Get-GoodsDataStatus $b $dataDir
    Write-Output (@{ buyer = $b; ready = [bool]$st.ready; missing = (@($st.missingFields) -join ','); optional = (@($st.optionalMissingFields) -join ','); collection = [bool]$st.collectionComplete; dest = (Get-GoodsDestinationLabel $st); clar = (@($st.clarifications) -join ' ;; ') } | ConvertTo-Json -Compress)
}
Write-Output ('quote-ready-buyers: ' + (@(Get-QuoteReadyBuyers $dataDir | ForEach-Object { $_.buyer }) -join ' | '))
Write-Output ('quotable-count: ' + (Get-QuotableBuyerCount $dataDir))
Write-Output ('ROOT=' + $root)
