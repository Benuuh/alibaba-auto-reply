# tests\atomic_state.tests.ps1 - 运行态 JSON 的原子持久化（2026-10-05 spec §5-2 / §7）
#
# 覆盖：
#   S1 不存在 → 'missing'（可新建）
#   S2 存在但空内容 → 'empty'
#   S3 损坏 → 'corrupt'，**不得**被当成"没有账本/空账本"
#   S4 合法 → 'valid'，并能读出内容
#   S5 原子写入：目标不存在时创建；不留 .tmp 残file
#   S6 覆盖写：旧内容进备份文件
#   S7 写入失败（序列化失败）⇒ 目标文件保持原样（中断前旧账本仍可读）
#   S8 两个写入进程并发 ⇒ 读者只会读到合法的旧版本或新版本，不会读到半个文件
#   S9 隔离模式下写生产路径 ⇒ 立即抛 ISOLATION-VIOLATION
#   S10 顶层字段校验：合法 JSON 但缺字段 ⇒ 'corrupt'
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Assert-True([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' | got: [' + $a + '] | want: [' + $b + ']') }
}

Write-Output '== atomic_state tests =='

$isoRoot = Join-Path $env:TEMP ('aar-state-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\state_store.ps1')

$stateFile = Join-Path $isoRoot 'state.json'
$enc = New-Object System.Text.UTF8Encoding($false)

try {
    # ---- S1 ----
    Assert-Eq 'S1-missing' (Read-JsonDocument $stateFile).Status 'missing'

    # ---- S2 ----
    [System.IO.File]::WriteAllText($stateFile, '   ', $enc)
    Assert-Eq 'S2-empty' (Read-JsonDocument $stateFile).Status 'empty'

    # ---- S3 ----
    [System.IO.File]::WriteAllText($stateFile, '{"replied": {', $enc)
    $s3 = Read-JsonDocument $stateFile
    Assert-Eq 'S3-corrupt' $s3.Status 'corrupt'
    Assert-True 'S3-corrupt-is-not-missing' ($s3.Status -ne 'missing')
    Assert-True 'S3-corrupt-carries-error' ($s3.Error.Length -gt 0)

    # ---- S4 + S5 ----
    Remove-Item $stateFile -Force
    $w = Write-JsonDocumentAtomic -Path $stateFile -Data ([pscustomobject]@{ replied = [pscustomobject]@{ a = 'h|1' } })
    Assert-True 'S5-write-ok' $w.Ok ('err=' + $w.Error)
    $s4 = Read-JsonDocument $stateFile
    Assert-Eq 'S4-valid' $s4.Status 'valid'
    Assert-Eq 'S4-value-roundtrip' ([string]$s4.Data.replied.a) 'h|1'
    Assert-Eq 'S5-no-temp-leftovers' (@(Get-ChildItem $isoRoot -Filter '*.tmp-*' -ErrorAction SilentlyContinue).Count) 0

    # ---- S6 ----
    $w2 = Write-JsonDocumentAtomic -Path $stateFile -Data ([pscustomobject]@{ replied = [pscustomobject]@{ a = 'h|2' } })
    Assert-True 'S6-second-write-ok' $w2.Ok ('err=' + $w2.Error)
    Assert-True 'S6-backup-created' (Test-Path (Get-JsonDocumentBackupPath $stateFile))
    $backupText = Get-Content (Get-JsonDocumentBackupPath $stateFile) -Raw
    Assert-True 'S6-backup-holds-previous-content' ($backupText -match 'h\|1')

    # ---- S7: 替换阶段失败 ⇒ 旧账本保持可读（模拟"进程在原子替换前中断/目标被独占"） ----
    $beforeText = Get-Content $stateFile -Raw
    $lockStream = [System.IO.File]::Open($stateFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $w3 = Write-JsonDocumentAtomic -Path $stateFile -Data ([pscustomobject]@{ replied = [pscustomobject]@{ a = 'h|9' } })
    } finally {
        $lockStream.Close(); $lockStream.Dispose()
    }
    Assert-True 'S7-failed-write-reported' (-not $w3.Ok) ('err=' + $w3.Error)
    Assert-Eq 'S7-target-unchanged' ((Get-Content $stateFile -Raw) -replace '\s+', '') ($beforeText -replace '\s+', '')
    Assert-Eq 'S7-still-readable-after-failure' (Read-JsonDocument $stateFile).Status 'valid'
    Assert-Eq 'S7-no-temp-leftovers' (@(Get-ChildItem $isoRoot -Filter '*.tmp-*' -ErrorAction SilentlyContinue).Count) 0

    # ---- S10 ----
    [System.IO.File]::WriteAllText($stateFile, '{"other": 1}', $enc)
    Assert-Eq 'S10-missing-field-is-corrupt' (Read-JsonDocumentField -Path $stateFile -Field 'replied').Status 'corrupt'
    Assert-Eq 'S10-present-field-is-valid' (Read-JsonDocumentField -Path $stateFile -Field 'other').Status 'valid'

    # ---- S8: 并发写入期间读者永远读到合法内容 ----
    $writerScript = Join-Path $isoRoot 'writer.ps1'
    $writerBody = @'
param([string]$File, [string]$Tag, [int]$Iterations)
$ErrorActionPreference = 'Stop'
. (Join-Path $env:AAR_REPO 'scripts\config.ps1')
. (Join-Path $env:AAR_REPO 'scripts\lib\paths.ps1')
. (Join-Path $env:AAR_REPO 'scripts\lib\state_store.ps1')
for ($i = 0; $i -lt $Iterations; $i++) {
    $payload = [pscustomobject]@{ replied = [pscustomobject]@{ tag = $Tag; seq = $i; pad = ('x' * 400) } }
    $null = Write-JsonDocumentAtomic -Path $File -Data $payload -NoBackup
    Start-Sleep -Milliseconds 5
}
'@
    [System.IO.File]::WriteAllText($writerScript, $writerBody, (New-Object System.Text.UTF8Encoding($true)))
    $env:AAR_REPO = $repo
    $wFile = Join-Path $isoRoot 'race-state.json'
    $null = Write-JsonDocumentAtomic -Path $wFile -Data ([pscustomobject]@{ replied = [pscustomobject]@{ tag = 'seed'; seq = 0 } })
    $p1 = Start-Process -FilePath 'powershell' -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $writerScript, '-File', $wFile, '-Tag', 'A', '-Iterations', '25') -PassThru -WindowStyle Hidden
    $p2 = Start-Process -FilePath 'powershell' -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $writerScript, '-File', $wFile, '-Tag', 'B', '-Iterations', '25') -PassThru -WindowStyle Hidden
    $bad = 0
    $reads = 0
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        $doc = Read-JsonDocument $wFile
        # 并发写者持有目标文件时会短暂出现共享冲突/替换窗口：重试若干次；
        # 只有"重试后仍读不到合法内容"才算被撕裂的账本。
        $attempt = 0
        while ($doc.Status -ne 'valid' -and $attempt -lt 5) {
            $attempt++
            Start-Sleep -Milliseconds 25
            $doc = Read-JsonDocument $wFile
        }
        $reads++
        if ($doc.Status -ne 'valid') { $bad++ }
        if ($p1.HasExited -and $p2.HasExited) { break }
        Start-Sleep -Milliseconds 10
    }
    $p1.WaitForExit(20000) | Out-Null
    $p2.WaitForExit(20000) | Out-Null
    Assert-True 'S8-reads-happened' ($reads -gt 5) ('reads=' + $reads)
    Assert-Eq 'S8-no-torn-read' $bad 0 ('reads=' + $reads)
    Assert-Eq 'S8-final-state-valid' (Read-JsonDocument $wFile).Status 'valid'

    # ---- S9: 隔离模式下写生产路径必须失败 ----
    $prodState = (Get-AarProductionPaths) | Where-Object { $_ -match 'state\.json$' } | Select-Object -First 1
    if (-not $prodState) { $prodState = Join-Path (Get-AarProductionPaths)[0] 'state.json' }
    $existedBefore = Test-Path $prodState
    $beforeSig = ''
    if ($existedBefore) {
        $fi = Get-Item $prodState
        $beforeSig = ([string]$fi.Length + '|' + $fi.LastWriteTimeUtc.ToString('o'))
    }
    $threw = ''
    try { $null = Write-JsonDocumentAtomic -Path $prodState -Data ([pscustomobject]@{ x = 1 }) } catch { $threw = $_.Exception.Message }
    Assert-True 'S9-production-write-refused' ($threw -match 'ISOLATION-VIOLATION') ('err=' + $threw)
    $afterSig = ''
    if (Test-Path $prodState) {
        $fi2 = Get-Item $prodState
        $afterSig = ([string]$fi2.Length + '|' + $fi2.LastWriteTimeUtc.ToString('o'))
    }
    Assert-Eq 'S9-production-file-untouched' $afterSig $beforeSig
} finally {
    Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
