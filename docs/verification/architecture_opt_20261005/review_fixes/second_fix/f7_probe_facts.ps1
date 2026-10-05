
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$root = Join-Path $env:TEMP ('aar-f7-probe-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
[void](Initialize-AarIsolation -Root $root)
$env:AAR_RUNTIME_ROOT = $root
. (Join-Path $repo 'scripts\lib\goods.ps1')
$ts = 1791000000000L
function Probe([string]$name, [string[]]$msgs) {
    $lines = @()
    foreach ($m in $msgs) { $lines += ('[BUYER] ' + $m + ' @@MT:' + $ts); $ts += 1000 }
    $raw = ('# BUYER: Virtual Buyer' + [string][char]10 + ($lines -join [string][char]10))
    $rw = Get-QuoteReadinessForConversationText -Text $raw -ConvoName 'Virtual Buyer'
    [pscustomobject]@{
        Name = $name
        Ready = $rw.Ready
        Missing = @($rw.MissingFields) -join ','
        Optional = @($rw.OptionalMissingFields) -join ','
        CollectionComplete = $rw.CollectionComplete
        Clarifications = (@($rw.Clarifications) -join ' ;; ')
        RuleVersion = $rw.RuleVersion
        Error = $rw.Error
    } | ConvertTo-Json -Compress -Depth 6 | Write-Output
}
Probe 'f1-missing-cartons' @('Cargo name: cable. Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1')
Probe 'f2-four-complete' @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1')
Probe 'f3a-count-conflict' @('20 cartons total','24 cartons total')
Probe 'f3b-count-conflict-cue' @('20 cartons total','sorry, 24 cartons total')
Probe 'f3c-weight-scope-unknown' @('The weight is 20 kg, DDP to Amazon FTW1, dimensions 50x40x30 cm, 10 cartons')
Probe 'f3d-weight-conflict' @('The weight is 20 kg','The weight is 25 kg','10 cartons, 50x40x30 cm, DDP to Amazon FTW1')
Probe 'f3e-unit-vs-total-conflict' @('200 kg total','180 kg total','10 cartons, 50x40x30 cm, DDP to Amazon FTW1')
Probe 'f3f-dim-conflict' @('10 cartons, 50x40x30 cm, 216 kg gross, DDP to Amazon FTW1','Actually the carton size is 60x50x40 cm')
Probe 'f3g-dim-needs-confirm' @('10 cartons, 50x40 cm, 216 kg gross, DDP to Amazon FTW1')
Write-Output ('ROOT=' + $root)
