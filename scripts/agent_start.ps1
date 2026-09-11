# agent_start.ps1 - control-agent 保活启动器(幂等)。
# 输出码(供 watchdog 判定): CONTROL-ALREADY-RUNNING / CONTROL-DISABLED / CONTROL-STARTED / CONTROL-START-FAIL
# 停用标记: tools\control-agent\data\control-agent.disabled(bin -Action stop 建, -Action start 删);
#           仅在"未运行+需拉起"时生效;进程在跑照常 ALREADY-RUNNING。
param([string]$LogDir = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:root = Split-Path $LogDir -Parent
$script:bin = Join-Path $script:root "tools\control-agent\bin\control-agent.ps1"
$script:entry = Join-Path $script:root "tools\control-agent\agent_bridge.js"
$script:disableFlag = Join-Path $script:root "tools\control-agent\data\control-agent.disabled"

# 1) 进程检测(CIM 命令行匹配 agent_bridge.js,与 bin\control-agent.ps1 同判定)
$procs = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match [regex]::Escape($script:entry) })

# 2) 停用标记仅在"未运行+需拉起"时生效 → DISABLED(静默)
if ($procs.Count -eq 0 -and (Test-Path $script:disableFlag)) { Write-Output "CONTROL-DISABLED"; exit 0 }

# 3) 进程存在 → ALREADY-RUNNING(不写日志,调用方静默)
if ($procs.Count -gt 0) { Write-Output ("CONTROL-ALREADY-RUNNING (PID " + $procs[0].ProcessId + ")"); exit 0 }

if (-not (Test-Path $script:bin)) { Write-Output "CONTROL-START-FAIL (bin not found: $script:bin)"; exit 1 }

# 4) 未运行 → 文件重定向调用 bin -Action start(避免子进程继承管道句柄导致调用方悬挂;60s 上限)
$tmpOut = Join-Path $env:TEMP ("agent_start_out_" + $PID + ".txt")
$tmpErr = Join-Path $env:TEMP ("agent_start_err_" + $PID + ".txt")
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-ExecutionPolicy Bypass -NoProfile -File "' + $script:bin + '" -Action start') -WindowStyle Hidden -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -PassThru
$child.WaitForExit(60000) | Out-Null
$out = @()
if (Test-Path $tmpOut) { $out = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
Remove-Item $tmpOut,$tmpErr -Force -ErrorAction SilentlyContinue
$joined = $out -join ' '
if ($joined -match 'CONTROL-STARTED') { Write-Output ("CONTROL-STARTED " + $joined); exit 0 }
if ($joined -match 'CONTROL-ALREADY-RUNNING') { Write-Output ("CONTROL-ALREADY-RUNNING " + $joined); exit 0 }
Write-Output ("CONTROL-START-FAIL " + $joined)
exit 1
