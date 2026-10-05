# tests\lock.tests.ps1 - 原子锁与归属校验回归（2026-10-05 spec §5-1 / §7）
#
# 保留历史用例（F1 僵锁自愈，2026-09-15 停摆根因 R2），并新增本轮要求：
#   L5 获取时写入本次持有 token；重复释放返回 false
#   L6 拒绝释放**别人的**锁（持有 PID 存活且非本进程）
#   L7 两个竞争进程同时抢同一把锁 ⇒ 最多一个成功（真实子进程并发，不用模拟时钟）
#   L8 旧格式 "pid|时间" 两段锁文件仍可被同一 PID 释放（格式兼容）
#   L9 隔离模式下锁文件必须落在隔离根内（不写生产 data 目录）
#
# 隔离：本测试自建临时运行根并写隔离标记，锁文件只落在该根内。
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
function Assert-False([string]$name, [bool]$cond, [string]$detail = '') { Assert-True $name (-not $cond) $detail }
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' | got: [' + $a + '] | want: [' + $b + ']') }
}

Write-Output '== lock tests =='

$isoRoot = Join-Path $env:TEMP ('aar-lock-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\lock.ps1')

$lockDir = Get-AppLockDir
$testLockName = 'pytest-lock'
$testLockFile = Get-AppLockFile $testLockName
if (Test-Path $testLockFile) { Remove-Item $testLockFile -Force -ErrorAction SilentlyContinue }

try {
    # ---- L0: 锁目录必须落在隔离根内（本轮新增） ----
    Assert-True 'L0-lock-dir-inside-isolated-root' (Test-AarPathUnder $lockDir $isoRoot) ('dir=' + $lockDir)

    # ---- L1: 无锁时取锁成功（timeoutSec=0 非阻塞路径） ----
    $ok1 = Get-AppLock $testLockName 0
    Assert-True 'L1-acquire-when-free' $ok1
    Assert-True 'L1-lock-file-created' (Test-Path $testLockFile)
    $holder1 = (Get-Content $testLockFile -Raw).Split('|')[0]
    Assert-Eq 'L1-holder-is-self' $holder1 $PID.ToString()
    $info1 = Get-AppLockInfo $testLockName
    Assert-True 'L1-token-recorded' ($info1.Token.Length -ge 16) ('token=' + $info1.Token)
    Assert-True 'L1-owned-by-self' $info1.Owned
    Assert-True 'L1-release-returns-true' (Release-AppLock $testLockName)
    Assert-False 'L1-release-removes-file' (Test-Path $testLockFile)
    Assert-False 'L1-second-release-is-false' (Release-AppLock $testLockName)

    # ---- L2: R2 回归 —— holder 已死的僵锁，timeoutSec=0 必须取锁成功（修复前返回 False） ----
    $deadPid = 999999
    if (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid = 987654 }
    [System.IO.File]::WriteAllText($testLockFile, ($deadPid.ToString() + '|2026-01-01 00:00:00'), (New-Object System.Text.ASCIIEncoding))
    Assert-False 'L2-dead-holder-not-alive' ([bool](Get-Process -Id $deadPid -ErrorAction SilentlyContinue))
    $ok2 = Get-AppLock $testLockName 0
    Assert-True 'L2-stale-lock-self-heal' $ok2
    $holder2 = (Get-Content $testLockFile -Raw).Split('|')[0]
    Assert-Eq 'L2-lock-taken-by-self' $holder2 $PID.ToString()
    [void](Release-AppLock $testLockName)

    # ---- L3: holder 存活时 timeoutSec=0 必须失败，且不得删除他人锁 ----
    $alivePid = (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID } | Select-Object -First 1).ProcessId
    if (-not $alivePid) { $alivePid = (Get-Process -Id $PID).Id }
    [System.IO.File]::WriteAllText($testLockFile, ($alivePid.ToString() + '|2026-01-01 00:00:00|foreignlock'), (New-Object System.Text.ASCIIEncoding))
    $ok3 = Get-AppLock $testLockName 0
    Assert-False 'L3-live-holder-blocks' $ok3
    Assert-True 'L3-other-lock-preserved' (Test-Path $testLockFile)
    $holder3 = (Get-Content $testLockFile -Raw).Split('|')[0]
    Assert-Eq 'L3-other-lock-untouched' $holder3 $alivePid.ToString()
    # L6: 归属校验 —— 本进程没有该锁的 token ⇒ 释放必须被拒绝
    Assert-False 'L6-foreign-release-refused' (Release-AppLock $testLockName)
    Assert-True 'L6-foreign-lock-still-there' (Test-Path $testLockFile)
    Remove-Item $testLockFile -Force

    # ---- L8: 旧格式（两段，无 token）同 PID 兼容释放 ----
    [System.IO.File]::WriteAllText($testLockFile, ($PID.ToString() + '|2026-01-01 00:00:00'), (New-Object System.Text.ASCIIEncoding))
    Assert-True 'L8-legacy-self-pid-release' (Release-AppLock $testLockName)
    Assert-False 'L8-legacy-file-gone' (Test-Path $testLockFile)

    # ---- L7: 两个竞争进程同时抢锁 ⇒ 最多一个成功 ----
    $raceDir = Join-Path $isoRoot 'race'
    New-Item -ItemType Directory -Path $raceDir -Force | Out-Null
    $barrier = Join-Path $raceDir 'go.flag'
    $childScript = Join-Path $raceDir 'racer.ps1'
    $childBody = @'
param([string]$LockName, [string]$OutFile, [string]$Barrier)
$ErrorActionPreference = 'Stop'
. (Join-Path $env:AAR_REPO 'scripts\config.ps1')
. (Join-Path $env:AAR_REPO 'scripts\lib\paths.ps1')
. (Join-Path $env:AAR_REPO 'scripts\lib\lock.ps1')
$deadline = (Get-Date).AddSeconds(20)
while (-not (Test-Path $Barrier) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 20 }
$got = Get-AppLock $LockName 0
if ($got) {
    [System.IO.File]::WriteAllText($OutFile, 'GOT', (New-Object System.Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds 900
    [void](Release-AppLock $LockName)
} else {
    [System.IO.File]::WriteAllText($OutFile, 'MISS', (New-Object System.Text.UTF8Encoding($false)))
}
'@
    [System.IO.File]::WriteAllText($childScript, $childBody, (New-Object System.Text.UTF8Encoding($true)))
    $env:AAR_REPO = $repo
    $outA = Join-Path $raceDir 'a.txt'
    $outB = Join-Path $raceDir 'b.txt'
    $pa = Start-Process -FilePath 'powershell' -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $childScript, '-LockName', 'race-lock', '-OutFile', $outA, '-Barrier', $barrier) -PassThru -WindowStyle Hidden
    $pb = Start-Process -FilePath 'powershell' -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', $childScript, '-LockName', 'race-lock', '-OutFile', $outB, '-Barrier', $barrier) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 200
    [System.IO.File]::WriteAllText($barrier, 'go', (New-Object System.Text.UTF8Encoding($false)))
    $pa.WaitForExit(30000) | Out-Null
    $pb.WaitForExit(30000) | Out-Null
    $ra = ''
    $rb = ''
    if (Test-Path $outA) { $ra = (Get-Content $outA -Raw).Trim() }
    if (Test-Path $outB) { $rb = (Get-Content $outB -Raw).Trim() }
    $gotCount = @(@($ra, $rb) | Where-Object { $_ -eq 'GOT' }).Count
    Assert-Eq 'L7-exactly-one-process-acquires' $gotCount 1 ('A=' + $ra + ' B=' + $rb)
    Assert-False 'L7-no-lock-residue' (Test-Path (Get-AppLockFile 'race-lock'))

    # ---- L4: 清理后不残留测试锁 ----
    Assert-False 'L4-cleanup-no-residue' (Test-Path $testLockFile)
} finally {
    if (Test-Path $testLockFile) { Remove-Item $testLockFile -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
