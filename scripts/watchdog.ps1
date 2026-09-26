# watchdog.ps1 - 常驻守护(五重): monitor 进程 / 日志新鲜度 / CDP 兜底 / 企微保活 / control-agent 保活。
param(
    [string]$Action = "start",
    [string]$LogDir = "",
    [int]$CheckIntervalSec = 30,
    # F2(c) 2026-09-15 停摆根因修复:静默阈值 90 → 240。
    # 2026-09-15 事故中一轮真实回复耗时 >90s(多模态识别 + LLM 重试叠加)导致 watchdog 误杀正在工作的
    # monitor。F2(a) 的 ROUND-* 心跳(轮次内 <30s 一行)才是主防线,放宽阈值只是兜底。
    # 故此处不可设为无限大;可由 config.json 的 watchdog_log_stale_sec 覆盖。
    [int]$LogStaleSec = 240
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

# 防重启风暴:window 分钟内重启超过 count 次说明 monitor 启动即崩溃,进入冷却并告警(阈值可从 config.json 调)
$script:stormCount = 4
$script:stormWindowMin = 10
# F3(2026-09-15 停摆根因修复):命中风暴后不再"永久放弃",改为进入冷却期,冷却期内不重启 monitor,
# 冷却到期自动恢复守护能力,并推送企微告警。
$script:stormCooldownMin = 30
$cfgStorm = Get-SkillConfig
if ($cfgStorm.restart_storm_count) { $script:stormCount = [int]$cfgStorm.restart_storm_count }
if ($cfgStorm.restart_storm_window_min) { $script:stormWindowMin = [int]$cfgStorm.restart_storm_window_min }
if ($cfgStorm.restart_storm_cooldown_min) { $script:stormCooldownMin = [int]$cfgStorm.restart_storm_cooldown_min }
# F2(c):静默阈值可由 config 覆盖(缺省 240)
if ($cfgStorm.watchdog_log_stale_sec) { $LogStaleSec = [int]$cfgStorm.watchdog_log_stale_sec }
if ($script:stormCount -lt 1) { $script:stormCount = 1 }
if ($script:stormWindowMin -lt 1) { $script:stormWindowMin = 1 }
if ($script:stormCooldownMin -lt 1) { $script:stormCooldownMin = 1 }
if ($LogStaleSec -lt 30) { $LogStaleSec = 30 }
$script:restartTimes = New-Object System.Collections.ArrayList
$script:cooldownFile = Join-Path $script:logFileDir "watchdog_cooldown.json"

# F3:冷却状态读写。返回 @{ until; reason; count } 或 $null(无冷却/已到期)
function Get-WatchdogCooldown {
    if (-not (Test-Path $script:cooldownFile)) { return $null }
    try {
        $c = Get-Content $script:cooldownFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $c.until) { return $null }
        $until = [datetime]::Parse([string]$c.until)
        if ($until -gt (Get-Date)) { return @{ until = $until; reason = [string]$c.reason; count = [int]$c.count } }
        return $null
    } catch { return $null }
}
function Clear-WatchdogCooldown {
    if (Test-Path $script:cooldownFile) { Remove-Item $script:cooldownFile -Force -ErrorAction SilentlyContinue }
}
# F3:进入冷却 + 企微告警(推送失败只记日志,绝不抛错阻塞守护循环)
function Enter-WatchdogCooldown([string]$reason, [int]$count) {
    $until = (Get-Date).AddMinutes($script:stormCooldownMin)
    $obj = @{ until = $until.ToString('yyyy-MM-dd HH:mm:ss'); reason = $reason; count = $count; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    try { $obj | ConvertTo-Json | Set-Content -Path $script:cooldownFile -Encoding UTF8 } catch {}
    Write-Log "RESTART-STORM: $($script:stormWindowMin) 分钟内已重启 ${count} 次(原因: $reason),进入冷却 $($script:stormCooldownMin) 分钟(至 $($obj.until)),冷却期内不重启 monitor,请人工检查"
    try {
        $wecomScript = Join-Path $LogDir "lib\wecom.ps1"
        if (Test-Path $wecomScript) {
            . $wecomScript
            $alert = "[ALERT] watchdog 重启风暴($reason)，进入冷却 $($script:stormCooldownMin) 分钟；请人工检查 monitor.log"
            $r = Send-WecomMessage $alert
            Write-Log "RESTART-STORM-ALERT: $r"
        } else {
            Write-Log "RESTART-STORM-ALERT: skipped (lib\wecom.ps1 not found)"
        }
    } catch { Write-Log "RESTART-STORM-ALERT-FAIL: $($_.Exception.Message)" }
}
function Test-RestartStorm {
    $now = Get-Date
    $keep = @($script:restartTimes | Where-Object { ($now - $_).TotalMinutes -lt $script:stormWindowMin })
    $script:restartTimes = New-Object System.Collections.ArrayList
    foreach ($t in $keep) { [void]$script:restartTimes.Add($t) }
    return ($script:restartTimes.Count -ge $script:stormCount)
}
# F2(b):活锁豁免判定 —— data\onetalk-write.lock 的持有 PID 仍存活视为"monitor 正在处理轮次"
# (含长耗时 LLM/多模态识别),不得以"日志静默"为由杀它。抽成独立函数便于单元测试。
function Test-LiveWriteLock {
    $lockPath = Join-Path (Get-SkillPath "data") "onetalk-write.lock"
    if (-not (Test-Path $lockPath)) { return $null }
    $lh = (Get-Content $lockPath -Raw -ErrorAction SilentlyContinue).Split('|')[0]
    # 只接受纯数字 PID:锁文件损坏/半写入时 Get-Process -Id <非数字> 会抛参数绑定异常,
    # 而调用方(monitor/watchdog)可能是 $ErrorActionPreference='Stop',必须在此挡住。
    if ($lh -and $lh -match '^\d+$' -and (Get-Process -Id ([int]$lh) -ErrorAction SilentlyContinue)) { return $lh }
    return $null
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
        # F3(2026-09-15):原实现此处 exit 1 —— 永久停止一切重启,把"可自愈故障"变成"静默停摆"(事故 3h04m 无人知)。
        # 现改为进入冷却期:冷却内不重启 monitor(避免循环),到期自动恢复守护能力,并推送企微告警。
        Enter-WatchdogCooldown $reason ($script:restartTimes.Count + 1)
        return
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
    # [FIX-ENVBLOCK 2026-09-25] 原实现用 Start-Process 带 -RedirectStandardOutput/-RedirectStandardError，
    #   在本机（进程环境块含 3 组仅大小写不同的重复键）必抛
    #   ArgumentException 'Item has already been added. Key in dictionary: NO_PROXY / no_proxy'，
    #   → watchdog.log 22:27:18 起连续 4 条 "Monitor process NOT FOUND ... Restarting..." 后紧跟 "Watchdog error"，
    #   monitor 根本起不来（这是本次缺陷二的**真实抛点**，spec §1.5 推测的 L262 不是）。
    #   改走 Start-ProcessClean（.NET 直启 + 已去重环境块）。monitor.ps1 是无限循环，
    #   不能对它做管道重定向（父进程必须持续排空，否则子进程写满管道缓冲区即死锁），故此处不带重定向；
    #   代价：logs\monitor_out.log / monitor_err.log 不再更新，monitor 自身仍写 logs\monitor.log。
    #   单实例/幂等语义不变：monitor.ps1 内部 Initialize-MonitorRuntime 仍按 monitor.pid 判重。
    $argList = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', ('"' + $monitorScript + '"'), '-Action', 'start')
    [void](Start-ProcessClean -FilePath "powershell.exe" -ArgumentList $argList)
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
    Write-Log "=== Watchdog started (PID $PID, 五重守护: 进程/日志/CDP/企微/control-agent, check every ${CheckIntervalSec}s, stale threshold ${LogStaleSec}s, storm ${script:stormCount}/${script:stormWindowMin}m) ==="
    # P2.5 CDP 兜底:monitor 自愈失败时(CDP 连续不可达)由 watchdog 直接跑 chrome_ensure
    $cdpFailStreak = 0
    # control-agent 启动失败冷却截止时间(成功/失败状态变化才写日志,避免 30s 刷屏)
    $script:agentRetryAfter = [datetime]::MinValue
    # Accio 网关降级状态(仅进程轻量探测;连续不可达 N 轮记一次日志,避免刷屏)
    $script:accioDownStreak = 0
    # F3:冷却期循环计数(用于"每分钟留一行"节流)
    $script:cooldownTick = 0
    # 启动时若存在未到期冷却(上次进程被杀但冷却文件残留),继续遵守并留痕
    if (Get-WatchdogCooldown) {
        $cd0 = Get-WatchdogCooldown
        Write-Log "COOLDOWN: inherited active cooldown until $($cd0.until.ToString('yyyy-MM-dd HH:mm:ss')) (reason=$($cd0.reason))"
        $script:cooldownTick = 1
    }
    while ($true) {
        try {
            $procs = Get-MonitorProcesses
            $logAge = Get-LogAgeSec

            # F3:冷却期检查(冷却内不重启 monitor;每分钟评估一次是否可退出冷却)
            $cd = Get-WatchdogCooldown
            if ($cd) {
                $minsLeft = [int]((($cd.until) - (Get-Date)).TotalMinutes) + 1
                $script:cooldownTick++
                # 每分钟留一行(冷却状态必须可观测),避免刷屏
                if (($script:cooldownTick % [int](60 / [Math]::Max(1, $CheckIntervalSec))) -eq 1) {
                    Write-Log "COOLDOWN: active (reason=$($cd.reason), count=$($cd.count), until=$($cd.until.ToString('yyyy-MM-dd HH:mm:ss')), ~${minsLeft}m left) - monitor restart suppressed, keepalives continue"
                }
                if ($procs.Count -eq 0) {
                    Write-Log "COOLDOWN: monitor process NOT FOUND but cooldown active (until $($cd.until.ToString('yyyy-MM-dd HH:mm:ss'))) - not restarting yet"
                }
            } else {
                if ($script:cooldownTick -gt 0) {
                    Write-Log "COOLDOWN: expired - watchdog resumed full守护 (monitor restart re-enabled)"
                    $script:cooldownTick = 0
                    Clear-WatchdogCooldown
                }
                if ($procs.Count -eq 0) {
                    # 进程不存在 → 重启(带风暴防护)
                    Write-Log "Monitor process NOT FOUND (log age ${logAge}s). Restarting..."
                    Invoke-WatchdogRestart "process not found"
                } elseif ($logAge -gt $LogStaleSec) {
                    # F2(b) 活锁豁免:锁被存活进程持有 = monitor 正在处理轮次(含长耗时 LLM/多模态),不得误杀。
                    # 2026-09-15 停摆事故即由此处误判 stale 杀活跃进程引起。
                    $lockHolder = Test-LiveWriteLock
                    if ($lockHolder) {
                        Write-Log "WATCHDOG: log quiet ${logAge}s > ${LogStaleSec}s but onetalk-write held by LIVE PID $lockHolder - treated as busy, skip"
                    } else {
                        # 进程在但日志长时间未更新 → 判定僵死，杀掉重启(带风暴防护)
                        Write-Log "Monitor process alive but log stale ${logAge}s > ${LogStaleSec}s, no live write lock. Killing and restarting..."
                        foreach ($p in $procs) {
                            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                        }
                        Start-Sleep -Seconds 2
                        Invoke-WatchdogRestart "stale log"
                    }
                }
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
            # [HANDOVER 2026-09-26] 交接前置门：与 scripts\wecom_start.ps1 的 Get-WecomHandoverSkip 同语义。
            #   为什么要在这里再判一次：wecom_start.ps1 里的门禁虽然能挡住"启动旧通道"，但每 30s 仍会
            #   spawn 一个 PowerShell 进程只为打印一行 skip（11:28-11:31 实测：日志每 30s 一行 + 进程开销）。
            #   在这里短路后，watchdog 连 spawn 都不做。逃生门与判定条件完全一致：marker 不在 或
            #   新通道宿主不在 ⇒ 退回原逻辑（继续保活，绝不静默失守）。
            #   [PORTABLE 2026-09-26] marker 路径不再硬编码绝对路径：与 L87 同款走 Get-SkillPath "data"
            #   （硬编码会让脚本不可移植，且被 .githooks\sanitize_check.ps1 的 'D:\\Agent_work' 规则判为敏感内容）。
            $wecomHandoverMarker = Join-Path (Get-SkillPath "data") 'alert-channel.handover.json'
            $wecomHandover = $false
            if ($env:WECOM_FORCE_RUN -ne '1' -and (Test-Path $wecomHandoverMarker)) {
                try { $wecomHandover = @(Get-Process -Name 'DSH Desktop' -ErrorAction SilentlyContinue).Count -gt 0 } catch { $wecomHandover = $false }
            }
            $wecomStart = Join-Path $LogDir "wecom_start.ps1"
            if ($wecomHandover) {
                # 已交接：不 spawn、不记日志（watchdog.log 已有 wecom_start 侧的首条 HANDOVER-SKIP 留痕）
            } elseif (Test-Path $wecomStart) {
                $ws = powershell -ExecutionPolicy Bypass -NoProfile -File $wecomStart 2>&1
                if ($ws -match 'WECOM-STARTED') {
                    Write-Log "WATCHDOG-WECOM: $($ws -join ' ')"
                } elseif ($ws -match 'WECOM-NO-CREDS|WECOM-START-FAIL') {
                    Write-Log "WATCHDOG-WECOM: issue - $($ws -join ' ')"
                }
            }
            # control-agent 保活（冷却 5 分钟；仅状态变化/失败记日志；DISABLED/ALREADY-RUNNING 静默）
            $agentStart = Join-Path $LogDir "agent_start.ps1"
            if ((Test-Path $agentStart) -and ((Get-Date) -ge $script:agentRetryAfter)) {
                # 文件重定向 + 等待结果(不用管道捕获):node 会继承调用方管道句柄,
                # 管道捕获会导致 watchdog 循环悬挂直到 node 退出(PS 5.1 句柄继承坑,wecom_start 同款教训)
                # [FIX-ENVBLOCK 2026-09-25] Start-Process 带 -RedirectStandard* 在本机必抛 NO_PROXY 异常,
                #   改走 Start-ProcessClean(.NET 直启 + 去重环境块,stdout/stderr 由父进程异步排空后落盘)。
                #   语义等价:仍在 75s 上限内等结果,仍按 CONTROL-* 分支记日志。
                $asOut = Join-Path $env:TEMP ("wagent_out_" + $PID + ".txt")
                $asErr = Join-Path $env:TEMP ("wagent_err_" + $PID + ".txt")
                $asArgList = @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', ('"' + $agentStart + '"'))
                [void](Start-ProcessClean -FilePath 'powershell.exe' -ArgumentList $asArgList -RedirectStandardOutput $asOut -RedirectStandardError $asErr -WaitSeconds 75)
                $asText = ""
                if (Test-Path $asOut) {
                    $asText = (@(Get-Content $asOut -Encoding UTF8 -ErrorAction SilentlyContinue) -join ' ')
                }
                Remove-Item $asOut,$asErr -Force -ErrorAction SilentlyContinue
                if ($asText -match 'CONTROL-') {
                    if ($asText -match 'CONTROL-STARTED') { Write-Log "WATCHDOG-AGENT: $asText" }
                    elseif ($asText -match 'CONTROL-START-FAIL') {
                        Write-Log "WATCHDOG-AGENT: issue - $asText (5 分钟内不重试)"
                        $script:agentRetryAfter = (Get-Date).AddMinutes(5)
                    }
                    # CONTROL-ALREADY-RUNNING / CONTROL-DISABLED → 静默
                } else {
                    # 超时无结果:留痕并立即重试(不设冷却)——此前静默会导致首轮失败不可见
                    Write-Log "WATCHDOG-AGENT: timeout waiting result (will retry next cycle)"
                }
            }
            # Accio 桌面应用健康探测(轻量:仅进程;网关不可达时监控侧自动回退 CDP,不重启桌面应用)
            $accioUp = @(Get-Process -Name Accio -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $accioUp) {
                $script:accioDownStreak++
                if ($script:accioDownStreak -eq 3) {
                    Write-Log "WATCHDOG-ACCIO: gateway down, CDP fallback active (x3)"
                } elseif ($script:accioDownStreak -gt 3 -and ($script:accioDownStreak % 20) -eq 0) {
                    Write-Log "WATCHDOG-ACCIO: gateway still down (x$($script:accioDownStreak)), CDP fallback active"
                }
            } else {
                if ($script:accioDownStreak -ge 3) { Write-Log "WATCHDOG-ACCIO: gateway up (Accio running)" }
                $script:accioDownStreak = 0
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
