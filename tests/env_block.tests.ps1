# env_block regression tests — FIX-ENVBLOCK 2026-09-25
# 背景：本机进程环境块含 3 组仅大小写不同的重复键，导致带 -RedirectStandard* 的 Start-Process 必抛
#       ArgumentException 'Item has already been added. Key in dictionary: NO_PROXY / no_proxy'。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\cdp.ps1")

$script:pass = 0; $script:fail = 0
function Assert-True([string]$n,[bool]$c){ if($c){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n"} }
Write-Output "== env_block tests =="

# 1) 去重函数存在且返回忽略大小写的唯一快照
$snap = Get-CleanEnvSnapshot
Assert-True "snapshot-not-null" ($null -ne $snap)
$names = @($snap.Keys)
$groups = $names | Group-Object { $_.ToLower() }
Assert-True "no-case-insensitive-duplicates" (@($groups | Where-Object Count -gt 1).Count -eq 0)

# 2) 父进程环境的真实重复键已被折叠（本机为 NO_PROXY / https_proxy / http_proxy 三组）
$raw = [System.Environment]::GetEnvironmentVariables('Process').Keys
$rawDup = @($raw | Group-Object { $_.ToLower() } | Where-Object Count -gt 1)
Assert-True "parent-had-duplicates(raw count>0)" ($rawDup.Count -gt 0)
Assert-True "clean-count-lt-raw" ($names.Count -lt @($raw).Count)

# 3) 干净启动可成功（不带重定向——本函数故意不支持重定向，见 S2-2 注释）
$p = Start-ProcessClean -FilePath "powershell.exe" -ArgumentList @('-NoProfile','-Command','exit 0') -WaitSeconds 15
Assert-True "clean-start-no-redirect" ($null -ne $p)
Assert-True "clean-start-exit0" ($p.HasExited -and $p.ExitCode -eq 0)

# 4) 去重块可直接灌入忽略大小写字典而不抛异常（模拟 .NET 子进程环境构造）
$ok = $true
try {
    $ci = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($snap.Keys)) { $ci.Add([string]$k, [string]$snap[$k]) }
} catch { $ok = $false }
Assert-True "clean-snapshot-loads-into-ordinalignorecase-dict" $ok
Assert-True "dict-count-equals-snapshot" ($ci.Count -eq $names.Count)

# 5) [ADDED 2026-09-25 执行者] 重定向路径（.NET 实现）——spec §S2-2 标 [需实测]：实测可行。
#    该断言区分"跑通"与"跑对"：只证明函数能启动不算，必须证明**带重定向**也能启动并取回子进程输出。
$o = Join-Path $env:TEMP ("envblock_t_out_" + $PID + ".txt")
$e = Join-Path $env:TEMP ("envblock_t_err_" + $PID + ".txt")
$p2 = Start-ProcessClean -FilePath "powershell.exe" -ArgumentList @('-NoProfile','-Command','Write-Output REDIR-OK; exit 0') -RedirectStandardOutput $o -RedirectStandardError $e -WaitSeconds 20
Assert-True "redirect-start-exit0" ($p2.HasExited -and $p2.ExitCode -eq 0)
$txt = ''
if (Test-Path $o) { $txt = (Get-Content $o -Raw -Encoding UTF8) }
Assert-True "redirect-captured-stdout" ($txt -match 'REDIR-OK')
Remove-Item $o,$e -Force -ErrorAction SilentlyContinue

# 6) [ADDED 2026-09-25 执行者] 子进程**确实拿到**非空且已去重的环境块。
#    这条防的是静默故障：若 .NET 的 EnvironmentVariables 被清空却没灌回（本机首次访问返回 $null 的坑），
#    子进程会变成 0 条环境（PATH/TEMP 全丢）却仍能 exit 0 —— 只断言 exit0 抓不到它。
$o3 = Join-Path $env:TEMP ("envblock_t_cnt_" + $PID + ".txt")
$cntArgs = @('-NoProfile','-Command','[Console]::Out.Write([System.Environment]::GetEnvironmentVariables(''Process'').Keys.Count)')
$p3 = Start-ProcessClean -FilePath "powershell.exe" -ArgumentList $cntArgs -RedirectStandardOutput $o3 -WaitSeconds 20
$cnt = -1
if (Test-Path $o3) { try { $cnt = [int]((Get-Content $o3 -Raw -Encoding UTF8).Trim()) } catch { $cnt = -1 } }
Assert-True "child-env-nonempty" ($cnt -gt 0)
Assert-True "child-env-not-more-than-parent" ($cnt -le @($raw).Count)
Remove-Item $o3 -Force -ErrorAction SilentlyContinue

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
