# wecom_start.ps1 v3 - wecom-connector keep-alive launcher (spec: 企微通道自愈与单实例加固 2026-09-22)
# v2 -> v3: 第 2 步从"短路 exit 0"改为"未连接自愈"(连续 3 次未连接 -> 重启组件;冷却/配额防风暴)。
#   第 1 步(ALREADY-RUNNING)保持原语义,仅增加恢复清零与 WECOM-RECOVERED 留痕。
# Replaces v1 (old scripts\wecom\wecom_bot.js starter). Name/location unchanged for watchdog.
# Credentials are read from credentials.md and injected via process env only (never written to disk/config).
# Codes (watchdog compatible): WECOM-ALREADY-RUNNING / WECOM-NOT-CONNECTED / WECOM-NO-CREDS / WECOM-STARTED / WECOM-START-FAIL
# New codes: WECOM-SELFHEAL / WECOM-SELFHEAL-COOLDOWN / WECOM-SELFHEAL-QUOTA / WECOM-RECOVERED / WECOM-ALREADY-RUNNING (retest path)
param([string]$LogDir = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
if (-not $script:logFileDir) { $script:logFileDir = Join-Path (Split-Path $LogDir -Parent) "logs" }
$logFile = Join-Path $script:logFileDir "watchdog.log"
function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

$script:baseUrl = "http://127.0.0.1:19886"
$script:componentRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\wecom-connector'
$script:streakFile = Join-Path (Join-Path $script:componentRoot 'data') 'not_connected_streak.json'
$script:kickStateFile = Join-Path (Join-Path $script:componentRoot 'data') 'kick_state.json'
# 三个自愈阈值(见 spec §6 S2.1;理由:3 次相隔一轮 watchdog(30s)≈90s,长于一次正常认证耗时,
# 避免把"正在认证"误判为故障;冷却与每小时配额防止与未知第二实例互踢成风暴)。
$script:healFailThreshold = 3      # 连续未连接次数
$script:healCooldownMin = 10       # 自愈后冷却(分钟)
$script:healQuotaPerHour = 3       # 每小时自愈上限
$script:healStartupGraceSec = 60   # 进程启动 <60s 视为"正在启动",不自愈

function Get-NowMs { return [long]([datetime]::UtcNow - [datetime]'1970-01-01').TotalMilliseconds }
function Format-FromMs([long]$ms) { return ([datetime]'1970-01-01').AddMilliseconds($ms).ToLocalTime().ToString('HH:mm:ss') }

function Get-ConnectorProcesses {
    # PS 5.1 坑:函数返回单元素数组会被展开,逗号强制按数组返回
    return ,@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'wecom-connector' -and $_.CommandLine -match 'server\.js' })
}

# 状态读取:任何异常/损坏一律视为"无状态"(C9:不得让保活脚本抛异常退出)
function New-StreakState { return [pscustomobject]@{ count = 0; first_ts = $null; last_ts = $null; cooldown_until = $null; heals = @() } }
function Read-StreakState {
    try {
        if (-not (Test-Path $script:streakFile)) { return (New-StreakState) }
        $j = Get-Content $script:streakFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j) { return (New-StreakState) }
        $st = New-StreakState
        $n = 0
        if ($j.PSObject.Properties.Name -contains 'count') { [void][int]::TryParse([string]$j.count, [ref]$n) }
        $st.count = $n
        if ($j.PSObject.Properties.Name -contains 'first_ts') { $st.first_ts = $j.first_ts }
        if ($j.PSObject.Properties.Name -contains 'last_ts') { $st.last_ts = $j.last_ts }
        if ($j.PSObject.Properties.Name -contains 'cooldown_until') { $st.cooldown_until = $j.cooldown_until }
        if (($j.PSObject.Properties.Name -contains 'heals') -and $j.heals) {
            $st.heals = @($j.heals | Where-Object { $null -ne $_ -and "$_" -match '^\d+$' } | ForEach-Object { [long]$_ })
        }
        return $st
    } catch { return (New-StreakState) }
}
function Write-StreakState($st) {
    try {
        $dir = Split-Path $script:streakFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $st | ConvertTo-Json -Depth 5 | Set-Content -Path $script:streakFile -Encoding UTF8
    } catch { Write-Log ("WECOM-SELFHEAL: state write failed - " + $_.Exception.Message) }
}
# F1 的主动退避状态(与 server.js 共用同一文件);损坏视为无退避
function Read-KickBackoffMs {
    try {
        if (-not (Test-Path $script:kickStateFile)) { return [long]0 }
        $j = Get-Content $script:kickStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j -and ($j.PSObject.Properties.Name -contains 'backoffUntilMs')) {
            $v = 0L
            if ([long]::TryParse([string]$j.backoffUntilMs, [ref]$v)) { return $v }
        }
    } catch { }
    return [long]0
}

# 1) Bridge healthy & connected -> already running (watchdog silent, no double start)
try {
    $h = Invoke-RestMethod -Uri ($script:baseUrl + "/health") -TimeoutSec 3
    if ($h.connected -eq $true) {
        $st = Read-StreakState
        if ($st.count -ge 3 -or $st.cooldown_until) {
            $prev = $st.count
            Write-Log ("WECOM-RECOVERED (prev streak " + $prev + ")")
        }
        $st.count = 0
        $st.first_ts = $null
        $st.cooldown_until = $null
        Write-StreakState $st
        Write-Output "WECOM-ALREADY-RUNNING"
        exit 0
    }
} catch { }

# 2) Connector process alive but not connected -> self-heal after N consecutive misses.
#    原 v2 此处直接 exit 0(把"进程在但未连接"当正常),正是 2026-09-21 静默失效 14 小时的根因(R2)。
$procs = Get-ConnectorProcesses
if ($procs.Count -gt 0) {
    $st = Read-StreakState
    $nowMs = Get-NowMs
    $ageSec = 999999
    try {
        $cd = $procs[0].CreationDate
        if ($cd) { $ageSec = [int]((Get-Date) - $cd).TotalSeconds }
    } catch { }
    # R4 防护:刚启动、可能仍在认证中的实例,直接让路(不自愈、不累计 streak)
    if ($ageSec -lt $script:healStartupGraceSec) {
        Write-Output ("WECOM-NOT-CONNECTED (starting up, " + $ageSec + "s)")
        exit 0
    }
    # R9:F1 主动退避期内不自愈、不累计 streak(否则 F2 会把 F1 的退避当成故障反复重启)
    $kbUntil = Read-KickBackoffMs
    if ($kbUntil -gt $nowMs) {
        $st.count = 0
        Write-StreakState $st
        Write-Output ("WECOM-NOT-CONNECTED (kick-backoff until " + (Format-FromMs $kbUntil) + ")")
        exit 0
    }
    $nowTxt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $st.count = $st.count + 1
    if (-not $st.first_ts) { $st.first_ts = $nowTxt }
    $st.last_ts = $nowTxt
    Write-StreakState $st
    if ($st.count -eq 1) { Write-Log ("WECOM-NOT-CONNECTED streak started (1/" + $script:healFailThreshold + ")") }
    if ($st.count -lt $script:healFailThreshold) {
        Write-Output ("WECOM-NOT-CONNECTED (streak " + $st.count + "/" + $script:healFailThreshold + ")")
        exit 0
    }
    Write-Log ("WECOM-NOT-CONNECTED streak reached " + $st.count + "/" + $script:healFailThreshold + " - evaluating self-heal")
    if ($st.cooldown_until -and (Get-Date) -lt [datetime]$st.cooldown_until) {
        Write-Output ("WECOM-SELFHEAL-COOLDOWN until " + $st.cooldown_until)
        exit 0
    }
    $heals = @($st.heals | Where-Object { ($nowMs - $_) -lt 3600000 })
    $st.heals = $heals
    if ($heals.Count -ge $script:healQuotaPerHour) {
        Write-Output ("WECOM-SELFHEAL-QUOTA (" + $heals.Count + " heals in last hour)")
        exit 0
    }
    # 自愈前复测(TOCTOU 容忍:最坏多一次重启)
    try {
        if ((Invoke-RestMethod -Uri ($script:baseUrl + '/health') -TimeoutSec 3).connected -eq $true) {
            Write-Output "WECOM-ALREADY-RUNNING"
            exit 0
        }
    } catch { }
    Write-Log ("WECOM-SELFHEAL: not connected x" + $st.count + " (~" + ($st.count * 30) + "s), restarting")
    $binStop = Join-Path $script:componentRoot 'bin\wecom-connector.ps1'
    & powershell -ExecutionPolicy Bypass -NoProfile -File $binStop -Action stop | Out-Null   # 复用组件自带 stop(命令行精确匹配)
    Start-Sleep -Seconds 2
    $st.count = 0
    $st.first_ts = $null
    $st.cooldown_until = (Get-Date).AddMinutes($script:healCooldownMin).ToString('yyyy-MM-dd HH:mm:ss')
    $st.heals = @($st.heals) + @($nowMs)
    Write-StreakState $st
    # 落入既有第 3 步:凭据注入 + 启动(输出码含 'WECOM-STARTED' 以便 watchdog 记日志,无需改 watchdog.ps1)
}

# 3) Not running -> inject creds via env (never to disk/config) and start via component bin
$botId = Get-CredentialValue 'wx_bot_id'
$botSecret = Get-CredentialValue 'wx_bot_secret'
if (-not $botId -or -not $botSecret) {
    Write-Log "WECOM-START: credentials missing in credentials.md (wx_bot_id/wx_bot_secret)"
    Write-Output "WECOM-NO-CREDS"
    exit 1
}
$env:WX_BOT_ID = $botId
$env:WX_BOT_SECRET = $botSecret
$env:WX_RECEIVER_FILE = Join-Path (Get-SkillPath "data") "wecom_receiver.json"

$bin = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\wecom-connector') 'bin\wecom-connector.ps1'
# 以文件重定向方式调用 bin(而非管道捕获):避免被启动的 node 进程继承管道句柄导致调用方(如 watchdog 轮询)悬挂
$tmpOut = Join-Path $env:TEMP ("wconn_out_" + $PID + ".txt")
$tmpErr = Join-Path $env:TEMP ("wconn_err_" + $PID + ".txt")
$child = Start-Process -FilePath 'powershell.exe' -ArgumentList ('-ExecutionPolicy Bypass -NoProfile -File "' + $bin + '" -Action start') -WindowStyle Hidden -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -PassThru
$child.WaitForExit(45000) | Out-Null
$out = @()
if (Test-Path $tmpOut) { $out = @(Get-Content $tmpOut -Encoding UTF8 -ErrorAction SilentlyContinue) }
Remove-Item $tmpOut,$tmpErr -Force -ErrorAction SilentlyContinue
$joined = $out -join ' '
foreach ($line in $out) { Write-Log "WECOM-START: $line" }
if ($joined -match 'WECOM-STARTED') { Write-Output "WECOM-STARTED $joined"; exit 0 }
if ($joined -match 'WECOM-ALREADY-RUNNING') { Write-Output "WECOM-ALREADY-RUNNING"; exit 0 }
Write-Output "WECOM-START-FAIL"
exit 1
