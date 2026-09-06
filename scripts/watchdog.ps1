param(
    [string]$Action = "start",
    [string]$LogDir = "",
    [int]$CheckIntervalSec = 30,
    [int]$LogStaleSec = 90
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }

$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "watchdog.log"
$monitorScript = Join-Path $LogDir "monitor.ps1"
$ensureScript = Join-Path $LogDir "chrome_ensure.ps1"

# 防重启风暴:window 分钟内重启超过 count 次说明 monitor 启动即崩溃,停止重启并告警(阈值可从 config.json 调)
$script:stormCount = 4
$script:stormWindowMin = 10
$cfgStorm = Get-SkillConfig
if ($cfgStorm.restart_storm_count) { $script:stormCount = [int]$cfgStorm.restart_storm_count }
if ($cfgStorm.restart_storm_window_min) { $script:stormWindowMin = [int]$cfgStorm.restart_storm_window_min }
if ($script:stormCount -lt 1) { $script:stormCount = 1 }
if ($script:stormWindowMin -lt 1) { $script:stormWindowMin = 1 }
$script:restartTimes = New-Object System.Collections.ArrayList
function Test-RestartStorm {
    $now = Get-Date
    $keep = @($script:restartTimes | Where-Object { ($now - $_).TotalMinutes -lt $script:stormWindowMin })
    $script:restartTimes = New-Object System.Collections.ArrayList
    foreach ($t in $keep) { [void]$script:restartTimes.Add($t) }
    return ($script:restartTimes.Count -ge $script:stormCount)
}
# 按命令行精确匹配正在运行的 monitor 实例(与 Get-MonitorProcesses 兜底共用同一判定)
function Get-MonitorProcessesByCommandLine {
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '\-File .*monitor\.ps1' -and $_.CommandLine -match '\-Action start' })
}

function Invoke-WatchdogRestart([string]$reason) {
    # D1 竞态加固:重启前用命令行兜底再查一次——pid 文件过时但 monitor 实际存活时,只刷新 pid 文件,绝不重启(防双实例)
    $alive = Get-MonitorProcessesByCommandLine
    if ($alive.Count -gt 0) {
        $pidFile = Join-Path $LogDir "monitor.pid"
        try { Set-Content -Path $pidFile -Value $alive[0].ProcessId -Encoding ASCII } catch {}
        Write-Log "WATCHDOG: monitor actually alive (PID $($alive[0].ProcessId)) but pid file stale - refreshed pid file, skip restart ($reason)"
        return
    }
    if (Test-RestartStorm) {
        Write-Log "RESTART-STORM: $($script:stormWindowMin) 分钟内已重启 $($script:restartTimes.Count + 1) 次(原因: $reason),停止自动重启避免循环,请人工检查"
        exit 1
    }
    Start-MonitorProcess
    [void]$script:restartTimes.Add((Get-Date))
    Write-Log "Monitor restarted ($reason)."
}

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

function Get-MonitorProcesses {
    # 主判定：monitor.pid 记录的进程存在且为 monitor 实例（避免把其他含 "monitor.ps1"
    # 字样的命令行进程误判为监控，导致 watchdog 漏重启）
    $procs = @()
    $pidFile = Join-Path $LogDir "monitor.pid"
    if (Test-Path $pidFile) {
        try {
            $pidv = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pidv" -ErrorAction SilentlyContinue
            if ($p -and $p.Name -match 'powershell' -and $p.CommandLine -match 'monitor\.ps1') { $procs += $p }
        } catch {}
    }
    if ($procs.Count -eq 0) {
        # 兜底：PID 文件缺失/失效时按命令行精确匹配（-File 方式启动的实例）
        $procs = Get-MonitorProcessesByCommandLine
    }
    return $procs
}

function Get-LogAgeSec {
    $log = Join-Path $script:logFileDir "monitor.log"
    if (Test-Path $log) {
        return [int]((Get-Date) - (Get-Item $log).LastWriteTime).TotalSeconds
    }
    return 999999
}

function Start-MonitorProcess {
    # 重定向输出避免窗口阻塞；monitor.ps1 为无限循环，必须在独立进程运行
    Start-Process -FilePath "powershell.exe" -ArgumentList (
        "-ExecutionPolicy Bypass -NoProfile -File `"$monitorScript`" -Action start"
    ) -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $script:logFileDir "monitor_out.log") `
        -RedirectStandardError (Join-Path $script:logFileDir "monitor_err.log") | Out-Null
}

function Start-Watchdog {
    # 单实例保护：watchdog.pid 记录当前实例，重复启动直接退出
    $pidFile = Join-Path $LogDir "watchdog.pid"
    if (Test-Path $pidFile) {
        try {
            $oldPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -match 'powershell') {
                Write-Log "Another watchdog instance already running (PID $oldPid) - exiting"
                exit 0
            }
        } catch {}
    }
    try { Set-Content -Path $pidFile -Value $PID -Encoding ASCII } catch {}
    Write-Log "=== Watchdog started (PID $PID, check every ${CheckIntervalSec}s, stale threshold ${LogStaleSec}s, storm ${script:stormCount}/${script:stormWindowMin}m) ==="
    # P2.5 CDP 兜底:monitor 自愈失败时(CDP 连续不可达)由 watchdog 直接跑 chrome_ensure
    $cdpFailStreak = 0
    while ($true) {
        try {
            $procs = Get-MonitorProcesses
            $logAge = Get-LogAgeSec

            if ($procs.Count -eq 0) {
                # 进程不存在 → 重启(带风暴防护)
                Write-Log "Monitor process NOT FOUND (log age ${logAge}s). Restarting..."
                Invoke-WatchdogRestart "process not found"
            } elseif ($logAge -gt $LogStaleSec) {
                # 进程在但日志长时间未更新 → 判定僵死，杀掉重启(带风暴防护)
                Write-Log "Monitor process alive but log stale ${logAge}s > ${LogStaleSec}s. Killing and restarting..."
                foreach ($p in $procs) {
                    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                }
                Start-Sleep -Seconds 2
                Invoke-WatchdogRestart "stale log"
            }
            # P2.5 CDP 兜底:CDP 连续不可达 10 次(约 5 分钟)直接跑 chrome_ensure.ps1
            if (Test-CdpReady) {
                $cdpFailStreak = 0
            } else {
                $cdpFailStreak++
                if ($cdpFailStreak -ge 10 -and (Test-Path $ensureScript)) {
                    Write-Log "WATCHDOG-CDP: CDP unreachable x$cdpFailStreak - running chrome_ensure.ps1"
                    $ens = powershell -ExecutionPolicy Bypass -File $ensureScript 2>&1
                    Write-Log "WATCHDOG-CDP: chrome_ensure result: $($ens -join ' | ')"
                    $cdpFailStreak = 0
                    Start-Sleep -Seconds 30
                }
            }
            # B 系列:企微机器人长连接服务监管(幂等启动,node 进程死亡自动拉起)
            $wecomStart = Join-Path $LogDir "wecom_start.ps1"
            if (Test-Path $wecomStart) {
                $ws = powershell -ExecutionPolicy Bypass -NoProfile -File $wecomStart 2>&1
                if ($ws -match 'WECOM-STARTED') {
                    Write-Log "WATCHDOG-WECOM: $($ws -join ' ')"
                } elseif ($ws -match 'WECOM-NO-CREDS|WECOM-START-FAIL') {
                    Write-Log "WATCHDOG-WECOM: issue - $($ws -join ' ')"
                }
            }
        } catch {
            Write-Log "Watchdog error: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $CheckIntervalSec
    }
}

function Stop-Watchdog {
    # 杀掉自身（当前进程）之外的所有 watchdog 进程
    $self = $PID
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'watchdog\.ps1' -and $_.ProcessId -ne $self } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Log "=== Watchdog stopped ==="
}

switch ($Action) {
    "start" { Start-Watchdog }
    "stop" { Stop-Watchdog }
    default { Write-Output "Usage: watchdog.ps1 -Action start|stop" }
}
