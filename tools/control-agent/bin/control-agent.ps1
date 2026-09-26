# bin/control-agent.ps1 - 桥启动/停止/状态(幂等;PID 文件防双实例)
# 用法: powershell -ExecutionPolicy Bypass -File bin\control-agent.ps1 -Action start|stop|status
# 启动: 检查 PID 文件与进程 → 拉起 node agent_bridge.js(重定向日志) → 等 agent.log 心跳
param([string]$Action = "start")

$ErrorActionPreference = "Stop"
$script:root = Split-Path $PSScriptRoot -Parent
$script:entryJs = Join-Path $script:root "agent_bridge.js"
$script:logDir = Join-Path $script:root "logs"
$script:pidFile = Join-Path $script:root "data\control-agent.pid"
$script:agentLog = Join-Path $script:logDir "agent.log"
$script:disableFlag = Join-Path $script:root "data\control-agent.disabled"

function Get-BridgeProcesses {
    # PS 5.1 返回数组的坑:return ,@(...) 空数组时 Count 误判为 1;Write-Output -NoEnumerate @() 也会输出一个 $null。
    # 可靠写法:空 → 无输出;非空 → 逗号包裹保持数组
    $list = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape($script:entryJs) })
    if ($list.Count -eq 0) { return }
    return ,$list
}

function Get-PidFileProcess {
    if (-not (Test-Path $script:pidFile)) { return $null }
    try {
        $pidv = [int](Get-Content $script:pidFile -Raw -ErrorAction SilentlyContinue)
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pidv" -ErrorAction SilentlyContinue
        if ($p -and $p.Name -match 'node' -and $p.CommandLine -match 'agent_bridge') { return $p }
    } catch {}
    return $null
}

function Start-Bridge {
    $byPid = Get-PidFileProcess
    $byCmd = @(Get-BridgeProcesses)
    if ($byPid -or $byCmd.Count -gt 0) {
        $pidTxt = $null
        if ($byPid) { $pidTxt = $byPid.ProcessId } elseif ($byCmd.Count -gt 0) { $pidTxt = $byCmd[0].ProcessId }
        # 手动 start = 恢复保活意图:清停用标记
        Remove-Item $script:disableFlag -Force -ErrorAction SilentlyContinue
        Write-Output ("CONTROL-ALREADY-RUNNING (PID " + $pidTxt + ")")
        exit 0
    }
    if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null }
    if (-not (Test-Path (Split-Path $script:pidFile -Parent))) { New-Item -ItemType Directory -Path (Split-Path $script:pidFile -Parent) -Force | Out-Null }
    # [FIX-DAEMONLAUNCH 2026-09-25] 原为 Start-Process 带标准流重定向参数（本机必抛 NO_PROXY）。
    #   改为已验证的"真实文件句柄重定向 + 脱离存活"启动器（见 scripts\lib\cdp.ps1::Start-DaemonClean）。
    $cdpLib = $null
    $probe = $PSScriptRoot
    while ($probe -and -not $cdpLib) {
        $cand = Join-Path $probe 'scripts\lib\cdp.ps1'
        if (Test-Path $cand) { $cdpLib = $cand; break }
        $up = Split-Path $probe -Parent
        if ($up -eq $probe) { break }
        $probe = $up
    }
    if (-not $cdpLib) { Write-Output "CONTROL-START-FAIL (cdp.ps1 not found from $PSScriptRoot)"; exit 1 }
    . $cdpLib
    $p = Start-DaemonClean -FilePath "node.exe" `
        -ArgumentList @($script:entryJs) `
        -LogPath (Join-Path $script:logDir "out.log") `
        -ErrPath (Join-Path $script:logDir "err.log") `
        -PumpSeconds 5
    # Start-DaemonClean 返回 .bat 包装层，其 Id ≠ node pid；pid 文件必须存**真实 node pid**，
    #   否则 Get-PidFileProcess（按 node+agent_bridge 校验）会判定无效 → 破坏单实例语义。
    $realPid = Get-DaemonProcessId -FilePath "node.exe" -Needle $script:entryJs
    if ($realPid -le 0) { $realPid = $p.Id }
    Start-Sleep -Seconds 2
    try { Set-Content -Path $script:pidFile -Value $realPid -Encoding ASCII } catch {}
    # 等心跳(最多 15 秒)
    $deadline = (Get-Date).AddSeconds(15)
    $hb = $false
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $script:agentLog) -and ((Get-Date) - (Get-Item $script:agentLog).LastWriteTime).TotalSeconds -lt 20) { $hb = $true; break }
        Start-Sleep -Seconds 1
    }
    if ($hb) {
        # 成功启动 = 恢复保活意图:清停用标记
        Remove-Item $script:disableFlag -Force -ErrorAction SilentlyContinue
        Write-Output ("CONTROL-STARTED (PID " + $realPid + ")")
        exit 0
    }
    Write-Output "CONTROL-START-FAIL (agent.log 无心跳)"
    exit 1
}

function Stop-Bridge {
    $byPid = Get-PidFileProcess
    if ($byPid) { try { Stop-Process -Id $byPid.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    $byCmd = @(Get-BridgeProcesses)
    foreach ($proc in $byCmd) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    try { Remove-Item $script:pidFile -Force -ErrorAction SilentlyContinue } catch {}
    # 停止 = 停用保活意图:建停用标记(纯 ASCII 时间戳),watchdog 见标记跳过拉起
    try {
        if (-not (Test-Path (Split-Path $script:disableFlag -Parent))) { New-Item -ItemType Directory -Path (Split-Path $script:disableFlag -Parent) -Force | Out-Null }
        Set-Content -Path $script:disableFlag -Value ("disabled at " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding ASCII
    } catch {}
    Write-Output "CONTROL-STOPPED"
}

function Show-Status {
    $byPid = Get-PidFileProcess
    $byCmd = @(Get-BridgeProcesses)
    $running = [bool]($byPid -or $byCmd.Count -gt 0)
    if (-not $running -and (Test-Path $script:disableFlag)) {
        Write-Output "control-agent: DISABLED (停用标记存在,删除 data\control-agent.disabled 并 start 可恢复)"
        exit 0
    }
    if (-not $running) {
        Write-Output "control-agent: DOWN"
        exit 1
    }
    $pidTxt = $null
    if ($byPid) { $pidTxt = $byPid.ProcessId } elseif ($byCmd.Count -gt 0) { $pidTxt = $byCmd[0].ProcessId }
    Write-Output ("control-agent: RUNNING (PID " + $pidTxt + ")")
    if (Test-Path $script:agentLog) {
        $last = Get-Content $script:agentLog -Tail 3 -Encoding UTF8
        $last | ForEach-Object { Write-Output ("  " + $_) }
    }
}

switch ($Action) {
    "start" { Start-Bridge }
    "stop" { Stop-Bridge }
    "status" { Show-Status }
    default { Write-Output "Usage: control-agent.ps1 -Action start|stop|status" }
}
