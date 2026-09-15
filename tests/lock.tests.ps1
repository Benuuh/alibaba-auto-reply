# lock regression tests — F1 僵锁自愈(2026-09-15 停摆根因修复 R2)
# 事故背景: watch 被杀 → data\onetalk-write.lock 残留(holder PID 已死) → monitor 每轮 Get-AppLock 'onetalk-write' 0
#          只删锁不重试,因 timeoutSec=0 时 deadline 已过 → 返回 $false → 该轮 LOCK-BUSY 跳过(日志静默)
#          → watchdog 判 stale 杀进程 → 再留僵锁,形成自锁闭环,最终风暴保护永久放弃 → 停摆 3h04m。
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\lock.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\lock.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-False([string]$name, [bool]$cond) {
    if (-not $cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}

Write-Output "== lock tests =="

$lockDir = Get-SkillPath "data"
if (-not $lockDir) { $lockDir = Join-Path (Split-Path $here -Parent) "data" }
$testLockName = "pytest-lock"
$testLockFile = Join-Path $lockDir ("$testLockName.lock")
# 断言不能污染真实写锁 onetalk-write;统一用独立锁名 pytest-lock
if (Test-Path $testLockFile) { Remove-Item $testLockFile -Force -ErrorAction SilentlyContinue }

# ---- 用例 1:无锁时取锁成功(timeoutSec=0 非阻塞路径) ----
$ok1 = Get-AppLock $testLockName 0
Assert-True "L1-acquire-when-free" $ok1
Assert-True "L1-lock-file-created" (Test-Path $testLockFile)
$holder1 = (Get-Content $testLockFile -Raw).Split('|')[0]
Assert-Eq "L1-holder-is-self" $holder1 $PID.ToString()
Release-AppLock $testLockName
Assert-False "L1-release-removes-file" (Test-Path $testLockFile)

# ---- 用例 2:R2 回归 —— holder 已死的僵锁,timeoutSec=0 必须取锁成功(修复前返回 False) ----
# 用一个几乎不可能存在的 PID 作为 holder,模拟"monitor 被杀后残留的僵锁"
$deadPid = 999999
if (Get-Process -Id $deadPid -ErrorAction SilentlyContinue) { $deadPid = 987654 }
"$deadPid|2026-01-01 00:00:00" | Set-Content $testLockFile -Encoding ASCII
Assert-False "L2-dead-holder-not-alive" ([bool](Get-Process -Id $deadPid -ErrorAction SilentlyContinue))
$ok2 = Get-AppLock $testLockName 0
Assert-True "L2-stale-lock-self-heal" $ok2
$holder2 = (Get-Content $testLockFile -Raw).Split('|')[0]
Assert-Eq "L2-lock-taken-by-self" $holder2 $PID.ToString()
Release-AppLock $testLockName

# ---- 用例 3:holder 存活时 timeoutSec=0 必须失败,且不得删除他人锁 ----
$alivePid = $PID   # 本进程必然存活
"$alivePid|2026-01-01 00:00:00" | Set-Content $testLockFile -Encoding ASCII
$ok3 = Get-AppLock $testLockName 0
Assert-False "L3-live-holder-blocks" $ok3
Assert-True "L3-other-lock-preserved" (Test-Path $testLockFile)
$holder3 = (Get-Content $testLockFile -Raw).Split('|')[0]
Assert-Eq "L3-other-lock-untouched" $holder3 $alivePid.ToString()
Release-AppLock $testLockName

# ---- 用例 4:清理后不残留测试锁(避免污染运行环境) ----
Assert-False "L4-cleanup-no-residue" (Test-Path $testLockFile)

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
