
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$root = Join-Path $env:TEMP ('aar-f7-repro-' + [guid]::NewGuid().ToString('N'))
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')
[void](Initialize-AarIsolation -Root $root)
$env:AAR_RUNTIME_ROOT = $root
. (Join-Path $repo 'scripts\lib\goods.ps1')
$dataDir = Join-Path $root 'data'
$outDir = Join-Path $root 'reports'
$stateFile = Join-Path $root 'summary_last.json'
$logFile = Join-Path $root 'monitor_virtual.log'
$LF = [string][char]10
$enc = New-Object System.Text.UTF8Encoding($true)

# 夹具（全部虚构；快照写入隔离运行根的 data 目录）
$cases = @(
    @{ Buyer = 'Virtual Buyer F1'; File = 'msgs_f1_0001.txt'; Msgs = @('Cargo name: cable. Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1') },
    @{ Buyer = 'Virtual Buyer F2'; File = 'msgs_f2_0001.txt'; Msgs = @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1') },
    @{ Buyer = 'Virtual Buyer F3'; File = 'msgs_f3_0001.txt'; Msgs = @('20 cartons total','24 cartons total') },
    @{ Buyer = 'Virtual Buyer F4'; File = 'msgs_f4_0001.txt'; Msgs = @('The weight is 20 kg, DDP to Amazon FTW1, dimensions 50x40x30 cm, 10 cartons') },
    @{ Buyer = 'Virtual Buyer F5'; File = 'msgs_f5_0001.txt'; Msgs = @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1','Change to Amazon TEST2') }
)
$ts = 1791000000000L
$logLines = @()
foreach ($c in $cases) {
    $lines = @()
    foreach ($m in $c.Msgs) { $lines += ('[BUYER] ' + $m + ' @@MT:' + $ts); $ts += 1000 }
    $raw = ('# BUYER: ' + $c.Buyer + $LF + ($lines -join $LF))
    [System.IO.File]::WriteAllText((Join-Path $dataDir $c.File), $raw, $enc)
    $logLines += ('2026-10-05 12:00:00 | REPLIED to ' + $c.Buyer + ': SENT_OK')
    $logLines += '2026-10-05 12:00:00 | Reply text: Thanks for the details.'
}
[System.IO.File]::WriteAllText($logFile, ($logLines -join $LF), $enc)

# 同一份统一结果（本进程）
Write-Output '== unified result (Get-GoodsDataStatus, same fixtures) =='
foreach ($c in $cases) {
    $st = Get-GoodsDataStatus $c.Buyer $dataDir
    Write-Output (@{ buyer = $c.Buyer; ready = [bool]$st.ready; missing = (@($st.missingFields) -join ','); optional = (@($st.optionalMissingFields) -join ','); collection = [bool]$st.collectionComplete; rule = [string]$st.ruleVersion; error = [string]$st.error; clar = (@($st.clarifications) -join ' ;; ') } | ConvertTo-Json -Compress)
}

# 实际 summarize.ps1 子进程（显式 LogFile/OutDir/StateFile；运行根由环境变量继承）
Write-Output '== actual summarize.ps1 run =='
$sumOut = & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $repo 'scripts\summarize.ps1') -LogFile $logFile -OutDir $outDir -StateFile $stateFile 2>&1
Write-Output ('summarize exit=' + $LASTEXITCODE)
Write-Output ('summarize stdout: ' + ($sumOut -join ' | '))
$md = @(Get-ChildItem -LiteralPath $outDir -Filter '*.md' | Sort-Object Name)
if ($md.Count -ne 1) { throw ('expected exactly one report, got ' + $md.Count) }
Write-Output ('report path: ' + $md[0].FullName)
Write-Output '== report content =='
Get-Content -LiteralPath $md[0].FullName -Encoding UTF8 | ForEach-Object { Write-Output $_ }
Write-Output ('ROOT=' + $root)
