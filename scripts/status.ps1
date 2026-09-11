# 一键健康检查:输出监控系统全貌(进程/CDP/日志/去重/快照/报告/计划任务/告警配置)。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File status.ps1
param([string]$LogDir = "")

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "config.ps1")
$cfg = Get-SkillConfig
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }

function Section([string]$title) {
    Write-Host ""
    Write-Host ("=" * 58) -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host ("-" * 58) -ForegroundColor DarkGray
}
function StatusLine([string]$label, [bool]$ok, [string]$detail) {
    $mark = if ($ok) { "[OK]  " } else { "[!!]  " }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("{0}{1,-22} {2}" -f $mark, $label, $detail) -ForegroundColor $color
}

Write-Host "阿里国际站自动回复 - 健康检查 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White

# --- 1. 进程 ---
Section "进程"
$monPid = $null; $monAlive = $false
if (Test-Path (Join-Path $LogDir "monitor.pid")) {
    $monPid = (Get-Content (Join-Path $LogDir "monitor.pid") -Raw -ErrorAction SilentlyContinue).Trim()
    $monAlive = [bool](Get-Process -Id $monPid -ErrorAction SilentlyContinue)
}
StatusLine "monitor.ps1" $monAlive $(if ($monPid) { "PID=$monPid" } else { "无 PID 文件" })
$wtdPid = $null; $wtdAlive = $false
if (Test-Path (Join-Path $LogDir "watchdog.pid")) {
    $wtdPid = (Get-Content (Join-Path $LogDir "watchdog.pid") -Raw -ErrorAction SilentlyContinue).Trim()
    $wtdAlive = [bool](Get-Process -Id $wtdPid -ErrorAction SilentlyContinue)
}
StatusLine "watchdog.ps1" $wtdAlive $(if ($wtdPid) { "PID=$wtdPid" } else { "无 PID 文件" })

# --- 2. CDP / Chrome ---
$cdpPort = Get-CdpPort
Section "Chrome / CDP ($cdpPort)"
$cdpOk = $false; $cdpVer = ""
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$cdpPort/json/version" -TimeoutSec 3 -UseBasicParsing
    if ($r.StatusCode -eq 200) { $cdpOk = $true; $cdpVer = (($r.Content | ConvertFrom-Json).Browser) }
} catch {}
StatusLine "CDP 端口 $cdpPort" $cdpOk $cdpVer

# --- 3. monitor.log ---
Section "monitor.log 摘要"
$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
if (Test-Path $logFile) {
    $log = Get-Content $logFile -Encoding UTF8
    $sizeKB = [Math]::Round((Get-Item $logFile).Length / 1KB, 1)
    $ageSec = [int]((Get-Date) - (Get-Item $logFile).LastWriteTime).TotalSeconds
    $ageTxt = if ($ageSec -lt 90) { "新鲜(${ageSec}s 前更新)" } else { "可能僵死(${ageSec}s 前更新)" }
    StatusLine "日志" $true "$($log.Count) 行, $sizeKB KB, $ageTxt"
    StatusLine "已回复 REPLIED" $true "$(($log | Select-String 'REPLIED to').Count) 次"
    StatusLine "LLM 成功" $true "$(($log | Select-String 'LLM ok').Count) 次"
    $llmErr = ($log | Select-String 'LLM error').Count
    StatusLine "LLM 失败" ($llmErr -eq 0) "$llmErr 次"
    $monErr = ($log | Select-String 'Monitor error').Count
    StatusLine "监控异常" ($monErr -eq 0) "$monErr 次"
    Write-Host "--- 最近 8 行 ---" -ForegroundColor DarkGray
    $log | Select-Object -Last 8 | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Gray }
} else {
    StatusLine "monitor.log" $false "不存在(监控尚未产生日志)"
}

# --- 4. state.json 去重 ---
Section "去重状态 state.json"
$stateFile = Join-Path $LogDir "state.json"
if (Test-Path $stateFile) {
    try {
        $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        # 过滤 Hashtable CLR 内部属性名(历史 bug 污染),只统计真实买家键
        $__bad = @('IsFixedSize','IsSynchronized','Count','IsReadOnly','Values','Keys','SyncRoot')
        $names = @($st.replied.PSObject.Properties.Name | Where-Object { $_ -notin $__bad })
        StatusLine "已回复会话" $true "$($names.Count) 个: $($names -join ', ')"
    } catch { StatusLine "state.json" $false "解析失败" }
} else { StatusLine "state.json" $false "不存在" }

# --- 5. 消息快照 ---
Section "消息快照 msgs_*.txt"
$msgs = @(Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($msgs.Count -gt 0) {
    StatusLine "快照数量" $true "$($msgs.Count) 份"
    Write-Host ("  最新: " + $msgs[0].Name + " (" + $msgs[0].LastWriteTime.ToString("HH:mm:ss") + ")") -ForegroundColor Gray
} else { StatusLine "快照" $false "无(尚无买家会话)" }
# P3.4 买家档案
$buyerDir = Join-Path $script:dataDir "buyers"
$profCount = @(Get-ChildItem $buyerDir -Filter "*.json" -ErrorAction SilentlyContinue).Count
StatusLine "买家档案" $true "$profCount 份 (data\buyers\)"

# --- 6. 报告 ---
Section "报告 reports\"
$repDir = Get-SkillPath "reports"
if (Test-Path $repDir) {
    $reps = @(Get-ChildItem $repDir -Filter "*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($reps.Count -gt 0) { StatusLine "报告" $true "$($reps.Count) 份, 最新: $($reps[0].Name)" }
    else { StatusLine "报告" $false "暂无(首份总结由计划任务自动生成)" }
} else { StatusLine "报告目录" $false "$repDir 不存在" }

# --- 7. 计划任务 ---
Section "计划任务"
foreach ($tn in @("AlibabaAutoReplySummary", "AlibabaAutoReplyQuality", "AlibabaAutoReplyOptimize", "AlibabaAutoReplyWeekly")) {
    $task = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($task) {
        $st = $task.State.ToString()
        $next = "未排程"
        try {
            $info = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
            if ($info -and $info.NextRunTime -and $info.NextRunTime -ne [datetime]::MaxValue) { $next = $info.NextRunTime.ToString("yyyy-MM-dd HH:mm") }
        } catch { }
        $ok = ($st -eq 'Ready')
        StatusLine $tn $ok "状态=$st, 下次=$next"
    } else {
        StatusLine $tn $false "状态=任务不存在"
    }
}

# --- 8. 镜像同步 ---
Section "镜像同步"
$lsf = Join-Path $LogDir "last_sync.json"
if (Test-Path $lsf) {
    try {
        $ls = Get-Content $lsf -Raw -Encoding UTF8 | ConvertFrom-Json
        $ageD = [int]((Get-Date) - ([datetime]::ParseExact($ls.last_push, "yyyy-MM-dd HH:mm:ss", $null))).TotalDays
        StatusLine "上次 -Push" ($ageD -lt 7) "$($ls.last_push) ($ageD 天前, $($ls.files) files)"
    } catch { StatusLine "上次 -Push" $true "解析失败" }
} else { StatusLine "上次 -Push" $true "尚无记录(先跑 sync.ps1 -Push)"
}

Section "敏感信息审计"
$secretHits = New-Object System.Collections.ArrayList
$scanDirs = @((Get-SkillPath "scripts"), (Get-SkillPath "logs"), (Get-SkillPath "reports"))
$skPat = 'sk-[A-Za-z0-9]{10,}'
$pwdPat = '(password|pwd)\s*[:=]\s*[''"]+[^''"]{4,}[''"]+'
foreach ($d in $scanDirs) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem $d -Recurse -File -Include *.ps1,*.json,*.md,*.log -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -ne 'credentials.md' -and $_.FullName -notmatch 'lib[\\/]creds\.ps1' -and $_.FullName -notmatch 'node_modules'
    } | ForEach-Object {
        try { $txt = Get-Content $_.FullName -Raw -Encoding UTF8 } catch { return }
        if ($txt -match $skPat) { [void]$secretHits.Add("$($_.Name): sk-key 明文") }
        if ($txt -match $pwdPat) { [void]$secretHits.Add("$($_.Name): password 字面量") }
    }
}
if ($secretHits.Count -eq 0) { StatusLine "凭据泄露" $true "未发现 sk-key/password 明文" }
else { foreach ($h in $secretHits) { StatusLine "凭据泄露" $false $h } }

Write-Host ""
Write-Host ("=" * 58) -ForegroundColor DarkGray
Write-Host "检查完成:以上 [!!] 项需要关注" -ForegroundColor Yellow
