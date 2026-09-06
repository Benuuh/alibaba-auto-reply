# =============================================================================
# [STOPPED-2026-09-07] 本脚本已停用（企微通道升级 spec v0.1 Phase 4）：
#   旧 6 固定命令体系被 tools\control-agent（自然语言远程控制）取代。
#   计划任务 AlibabaAutoReplyWeComCmd 已停用/删除（XML 备份见 backups\wecom_upgrade_20260907\）。
#   文件保留留档可回滚；不再被任何启动器/任务调用。行为未改动。
# =============================================================================
# wecom_command.ps1 - 企微远程指令系统:轮询 bot 收到的消息,匹配命令,执行动作,回发结果。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File wecom_command.ps1 [-DryRun]
# 计划任务(已停用,2026-09-07): 原 AlibabaAutoReplyWeComCmd 每分钟;状态 data\wecom_cmd_state.json(双写 .bak)
# 安全: 仅 owner(last_userid)可执行命令;同命令 60 秒节流;回发不含凭据;PII 只在本机 data\/logs\
param([switch]$DryRun)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"
function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }
$script:dataDir = Get-SkillPath "data"
$stateFile = Join-Path $script:dataDir "wecom_cmd_state.json"

# ===== 命令匹配纯函数(可单测;小写归一,冒号/空格等标点不影响关键词) =====
function Match-WecomCommand([string]$text) {
    if (-not $text) { return "" }
    $t = $text.Trim() -replace "[:：,，。.!！?？\s]+", ""
    $t = $t.ToLowerInvariant()
    if ($t -eq "help" -or $t -eq "帮助" -or $t.Contains("帮助") -or $t.Contains("help")) { return "help" }
    if ($t -eq "status" -or $t -eq "健康检查" -or $t.Contains("健康") -or $t.Contains("status")) { return "status" }
    if ($t -eq "dashboard" -or $t -eq "看板" -or $t.Contains("看板") -or $t.Contains("dashboard")) { return "dashboard" }
    if ($t -eq "buyers" -or $t -eq "最新买家" -or $t.Contains("最新买家") -or $t.Contains("buyers")) { return "buyers" }
    if ($t -eq "quote" -or $t -eq "报价提醒" -or $t.Contains("报价提醒") -or $t.Contains("quote")) { return "quote" }
    if ($t -eq "restart" -or $t -eq "重启监控" -or $t.Contains("重启监控") -or $t.Contains("restart")) { return "restart" }
    return ""
}

# 命令清单(帮助输出)
$script:helpText = "企微远程指令清单" + [char]10 +
    "帮助/help - 显示本清单" + [char]10 +
    "健康检查/status - 监控进程/CDP/日志/LLM 摘要" + [char]10 +
    "看板/dashboard - 数据看板路径与关键指标" + [char]10 +
    "最新买家/buyers - 近7天活跃买家与货物齐全度" + [char]10 +
    "报价提醒/quote - 数据齐全候选买家清单" + [char]10 +
    "重启监控/restart - 重启 monitor 进程(谨慎)"


# ===== 动作实现 =====

# 健康检查摘要:提取 status.ps1 输出关键行
function Invoke-CmdStatus {
    $out = powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot "status.ps1") 2>&1
    $lines = @($out | ForEach-Object { $_.ToString() })
    $sum = @()
    foreach ($l in $lines) {
        if ($l -match "monitor\.ps1|watchdog\.ps1|CDP 端口|LLM 失败|监控异常|日志.*新鲜|凭据泄露") { $sum += $l.Trim() }
    }
    if ($sum.Count -eq 0) { return "健康检查完成(无摘要行)" }
    $txt = ($sum | Select-Object -First 12) -join [char]10
    if ($txt.Length -gt 2000) { $txt = $txt.Substring(0, 2000) + "..." }
    return $txt
}

# 看板摘要
function Invoke-CmdDashboard {
    $out = powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot "dashboard.ps1") 2>&1
    $dashFile = Join-Path (Get-SkillPath "reports") "dashboard.html"
    $extra = ""
    $html = ""
    if (Test-Path $dashFile) { $html = Get-Content $dashFile -Raw -Encoding UTF8 }
    if ($html -match "发送成功</div><div class=.num.>(\d+)") { $extra += "发送成功=" + $Matches[1] }
    if ($html -match "活跃买家</div><div class=.num.>(\d+)") { $extra += " 活跃买家=" + $Matches[1] }
    if ($html -match "LLM 成功率</div><div class=.num.>(\S+?)%") { $extra += " LLM成功率=" + $Matches[1] + "%" }
    return ("看板: " + $dashFile + ($(if ($extra) { " | " + $extra } else { "" })))
}

# 最新买家 + 货物齐全度(近 7 天活跃)
function Invoke-CmdBuyers {
    $stateFile2 = Join-Path (Get-SkillPath "scripts") "state.json"
    $names = @()
    if (Test-Path $stateFile2) {
        try {
            $st = Get-Content $stateFile2 -Raw -Encoding UTF8 | ConvertFrom-Json
            $bad = @("IsFixedSize","IsSynchronized","Count","IsReadOnly","Values","Keys","SyncRoot")
            $names = @($st.replied.PSObject.Properties.Name | Where-Object { $_ -notin $bad })
        } catch {}
    }
    $cutoff = (Get-Date).AddDays(-7)
    $rows = @()
    foreach ($n in $names) {
        $snap = Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue |
            Where-Object { try { (Get-Content $_.FullName -Encoding UTF8 -TotalCount 1) -eq ("# BUYER: " + $n) } catch { $false } } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $snap -or $snap.LastWriteTime -lt $cutoff) { continue }
        $g = $null
        try { . (Join-Path $PSScriptRoot "lib\goods.ps1"); $g = Get-GoodsDataStatus $n $script:dataDir } catch {}
        if (-not $g) { $rows += ($n + " | 未知"); continue }
        $mark = ""
        if ($g.weight) { $mark += "重量OK" } else { $mark += "重量缺" }
        if ($g.dims) { $mark += " 尺寸OK" } else { $mark += " 尺寸缺" }
        if ($g.addr) { $mark += " 地址OK" } else { $mark += " 地址缺" }
        $rows += ($n + " | " + $mark)
    }
    if ($rows.Count -eq 0) { return "近7天无活跃买家" }
    $txt = ($rows | Select-Object -First 15) -join [char]10
    if ($txt.Length -gt 2000) { $txt = $txt.Substring(0, 2000) + "..." }
    return ("近7天活跃买家(" + $rows.Count + "):" + [char]10 + $txt)
}

# 报价提醒候选
function Invoke-CmdQuote {
    $out = powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $PSScriptRoot "quote_remind.ps1") -DryRun 2>&1
    $txt = (@($out | ForEach-Object { $_.ToString() }) -join [char]10)
    if ($txt.Length -gt 2000) { $txt = $txt.Substring(0, 2000) + "..." }
    return $txt
}

# 重启监控(杀掉 monitor 进程 → 重启 → 等 20s → 检查心跳)
function Invoke-CmdRestart {
    $scriptPath = Join-Path $PSScriptRoot "monitor.ps1"
    $filter = "Name=" + [char]39 + "powershell.exe" + [char]39
    $old = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "monitor\.ps1" -and $_.CommandLine -match "\-Action start" })
    foreach ($proc in $old) { try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Seconds 3
    $logDir = Get-SkillPath "logs"
    Start-Process -FilePath "powershell.exe" -ArgumentList ("-ExecutionPolicy Bypass -NoProfile -File " + $scriptPath + " -Action start") -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir "monitor_out.log") -RedirectStandardError (Join-Path $logDir "monitor_err.log")
    Start-Sleep -Seconds 20
    $new = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "monitor\.ps1" -and $_.CommandLine -match "\-Action start" })
    $pidTxt = if ($new.Count -gt 0) { $new[0].ProcessId } else { "未找到" }
    $hb = ""
    $mlog = Join-Path $logDir "monitor.log"
    if (Test-Path $mlog) {
        $last = Get-Content $mlog -Tail 3 -Encoding UTF8
        if (($last -join " ") -match "Scan cycle done|Monitor started") { $hb = "心跳正常" } else { $hb = "无心跳" }
    }
    return ("monitor 已重启: PID=" + $pidTxt + " | " + $hb)
}

# ===== 主流程 =====
# dot-source 守卫:测试 dot-source 本文件时只取 Match-WecomCommand 函数,不执行主流程
if ($MyInvocation.InvocationName -ne '.') {
$owner = $null
$rcv = Get-WecomReceiver
if ($rcv -and $rcv.last_userid) { $owner = [string]$rcv.last_userid }

# 读取状态
$lastSeq = 0
$lastCmdTime = ""
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($st.last_seq) { $lastSeq = [long]$st.last_seq }
        if ($st.last_cmd_time) { $lastCmdTime = [string]$st.last_cmd_time }
    } catch {}
}

$msgs = Get-WecomMessages -after $lastSeq
if ($null -eq $msgs) {
    Write-Output "WECOM-CMD: service unavailable"
    exit 0
}
# 更新 last_seq 到返回的最大 seq(即使无新消息也推进,防重复轮询)
$newSeq = $lastSeq
foreach ($m in $msgs) { if ([long]$m.seq -gt $newSeq) { $newSeq = [long]$m.seq } }

if ($DryRun) {
    Write-Output ("WECOM-CMD-DRYRUN: msgs=" + $msgs.Count + " lastSeq=" + $lastSeq + " newSeq=" + $newSeq)
    foreach ($m in $msgs) { Write-Output ("  seq=" + $m.seq + " userid=" + $m.userid + " content=[" + $m.content + "]") }
    exit 0
}

if ($msgs.Count -eq 0) {
    # 无新消息:推进 seq(若有)或首次运行时初始化状态文件(幂等验证/状态可观察)
    if ($newSeq -gt $lastSeq -or -not (Test-Path $stateFile)) {
        @{ last_seq = $newSeq; last_cmd_time = $lastCmdTime } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
        Set-Content -Path ($stateFile + ".bak") -Value (Get-Content $stateFile -Raw -Encoding UTF8) -Encoding UTF8
    }
    exit 0
}

# 逐条处理(仅 owner;按 seq 升序)
$maxHandled = $lastSeq
foreach ($m in ($msgs | Sort-Object { [long]$_.seq })) {
    if ([long]$m.seq -gt $maxHandled) { $maxHandled = [long]$m.seq }
    if (-not $owner -or ([string]$m.userid) -ne $owner) {
        Write-Log "WECOM-CMD-IGNORED: userid=$($m.userid) content=[$($m.content)]"
        continue
    }
    $cmd = Match-WecomCommand $m.content
    if (-not $cmd) {
        $r1 = Send-WecomMessage "未知指令,发送帮助查看命令清单"
        Write-Log ("WECOM-CMD: 未知指令 [" + $m.content + "] -> " + $r1)
        continue
    }
    # 60 秒节流:同一命令内容不重复执行
    $nowStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $throttle = $false
    if ($lastCmdTime) {
        try {
            $elapsed = ((Get-Date) - [datetime]::ParseExact($lastCmdTime, "yyyy-MM-dd HH:mm:ss", $null)).TotalSeconds
            if ($elapsed -lt 60) { $throttle = $true }
        } catch {}
    }
    if ($throttle) {
        Write-Log ("WECOM-CMD-THROTTLE: " + $cmd + " (60s)")
        continue
    }
    $lastCmdTime = $nowStr
    $result = ""
    switch ($cmd) {
        "help" { $result = $script:helpText }
        "status" { $result = Invoke-CmdStatus }
        "dashboard" { $result = Invoke-CmdDashboard }
        "buyers" { $result = Invoke-CmdBuyers }
        "quote" { $result = Invoke-CmdQuote }
        "restart" { $result = Invoke-CmdRestart }
    }
    if ($result.Length -gt 2000) { $result = $result.Substring(0, 2000) + "..." }
    $sendRes = Send-WecomMessage $result
    $sumTxt = $result.Substring(0, [Math]::Min(80, $result.Length)) -replace "`n", " "
    Write-Log ("WECOM-CMD: " + $cmd + " -> " + $sendRes + " | " + $sumTxt)
}

# 保存状态(双写)
@{ last_seq = $maxHandled; last_cmd_time = $lastCmdTime } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
Set-Content -Path ($stateFile + ".bak") -Value (Get-Content $stateFile -Raw -Encoding UTF8) -Encoding UTF8
Write-Output ("WECOM-CMD-DONE: seq=" + $maxHandled)
}
