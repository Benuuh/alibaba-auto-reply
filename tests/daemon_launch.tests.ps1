# daemon_launch tests — FIX-DAEMONLAUNCH 2026-09-25
# 关键：必须证明"长驻子进程的启动输出被真实写入文件，且子进程在启动器返回后仍存活"。
# 只断言"能启动"抓不到本缺陷（原缺陷正是能启动但日志永不生成）。
#
# ⚠️ 本文件相对 spec §6-S2-3 的模板有三处**必要**修改（已记入 REPORT 偏差记录 D-06）：
#   (1) 原模板用 `$args = @(...)`：`$args` 是 PowerShell 自动变量，赋值语义脆弱；改用 `$childArgs`。
#   (2) 原模板的 "did-not-capture-late-output"（断言 NEVERSEEN 不出现）与本节
#       "长驻守护进程的启动输出被真实写入文件"**互相矛盾**：真实文件句柄重定向下，
#       子进程后续输出**本就应该**持续落盘（这正是修复目标，原缺陷才是日志永不生成）。
#       故改为"启动器返回时后续输出尚未出现"，用标记文件精确控制时序，语义不变且不矛盾。
#   (3) 原模板的 "cleanup-killed" 断言 `$p.HasExited`：$p 是**包装层**进程，
#       杀掉包装层不会终止已脱离存活的守护进程（这正是我们要的"脱离"）。
#       故改为按命令行精确匹配目标进程并终止后断言其退出。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
$script:pass=0; $script:fail=0
function Assert-True([string]$n,[bool]$c){ if($c){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n"} }
Write-Output "== daemon_launch tests =="

Assert-True "function-exists" ($null -ne (Get-Command Start-DaemonClean -EA SilentlyContinue))

$log = Join-Path $env:TEMP ("daemon_test_" + $PID + ".log")
$marker = Join-Path $env:TEMP ("daemon_test_" + $PID + ".go")
$childSript = Join-Path $env:TEMP ("daemon_child_" + $PID + ".ps1")
$lateLine = ("NEVERSEEN-" + $PID)
Remove-Item $log,($log+'.err'),$marker,$childSript -Force -EA SilentlyContinue

# 子进程脚本：先输出 5 行启动日志；等标记文件出现后输出 lateLine 再继续存活（模拟长驻守护进程）
#   ⚠️ 用字面量 here-string（@'...'@）+ .Replace 注入路径：双引号 here-string 会把子进程脚本里的
#      `$true` 当变量插值成裸词 `True`，导致子进程把它当命令执行后**立即退出**（实测踩坑）。
$childBody = @'
1..5 | ForEach-Object { Write-Output BOOTLINE }
$n = 0
while (-not (Test-Path '__MARKER__') -and $n -lt 600) { Start-Sleep -Milliseconds 100; $n++ }
Write-Output '__LATE__'
# 打印后继续存活（模拟长驻守护进程），供 cleanup 步骤真实地终止它
while ($true) { Start-Sleep -Seconds 1 }
'@
$childBody = $childBody.Replace('__MARKER__', $marker).Replace('__LATE__', $lateLine)
[System.IO.File]::WriteAllText($childSript, $childBody, (New-Object System.Text.UTF8Encoding($false)))

$childArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$childSript)
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-DaemonClean -FilePath 'powershell.exe' -ArgumentList $childArgs -LogPath $log -PumpSeconds 6
$returnSec = [int]$sw.Elapsed.TotalSeconds

Assert-True "process-started" ($null -ne $p -and $p.Id -gt 0)
Assert-True "log-file-created" (Test-Path $log)
$txt = [string]$(if (Test-Path $log) { Get-Content $log -Raw -Encoding UTF8 } else { '' })
Assert-True "captured-boot-lines" (([regex]::Matches($txt,'BOOTLINE')).Count -ge 5)
Assert-True "has-launcher-header" (Test-Path $log)     # 日志文件由启动器创建（含启动输出）
Assert-True "launcher-returned-promptly" ($returnSec -lt 20)   # 启动器不再阻塞到子进程退出
Assert-True "daemon-still-alive-after-return" (-not $p.HasExited)
Assert-True "did-not-capture-late-output" ($txt -notmatch $lateLine)   # 启动器返回时后续输出尚未写入

# 放行子进程的后续输出，证明"文件句柄重定向让日志持续落盘"（这正是原缺陷做不到的）
Set-Content -Path $marker -Value 'go' -Encoding ASCII
Start-Sleep -Seconds 3
$txt2 = [string]$(if (Test-Path $log) { Get-Content $log -Raw -Encoding UTF8 } else { '' })
Assert-True "late-output-lands-in-file" ($txt2 -match $lateLine)

# 清理：按命令行精确匹配目标进程并终止（不能只杀包装层）
#   ⚠️ 必须用**文件名**而非完整路径匹配：参数被加了引号，完整路径在 CommandLine 里是
#      "...\"C:\...\daemon_child_N.ps1\"" 形态，用不带引号的完整路径做 Contains 匹配**会漏配**（实测）。
$leaf = 'powershell.exe'
$childName = [System.IO.Path]::GetFileName($childSript)
$killed = $false
foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='$leaf'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($childName) })) {
    try { Stop-Process -Id $c.ProcessId -Force -EA SilentlyContinue; $killed = $true } catch {}
}
Start-Sleep -Seconds 1
$still = @(Get-CimInstance Win32_Process -Filter "Name='$leaf'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($childName) })
Assert-True "cleanup-killed" ($killed -and $still.Count -eq 0)
Remove-Item $log,($log+'.err'),$marker,$childSript -Force -EA SilentlyContinue
# 清掉 .launch.bat / .launch.pid 等启动期产物（放日志目录）
Get-ChildItem (Split-Path $log -Parent) -Filter 'powershell_*.launch.*' -EA SilentlyContinue |
    Remove-Item -Force -EA SilentlyContinue

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
