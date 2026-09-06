# 周报:汇总最近 7 天监控与回复业务数据,生成周报 md;并顺带执行沉睡买家唤醒(nudge.ps1)。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File weekly_report.ps1 [-SkipNudge]
# 计划任务: AlibabaAutoReplyWeekly 每周一 08:00
param(
    [string]$LogDir = "",
    [int]$Days = 7,
    [switch]$SkipNudge
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
$stateFile = Join-Path $LogDir "state.json"
$outDir = Get-SkillPath "reports"
if (-not $outDir) { $outDir = Join-Path (Split-Path $LogDir -Parent) "reports" }

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# ===== 1) 统计 =====
$winStart = (Get-Date).AddDays(-$Days)
$lines = @()
if (Test-Path $logFile) { $lines = @(Get-Content $logFile -Encoding UTF8) }

$replied = @($lines | Select-String 'REPLIED to')
$sentOk = @($replied | Where-Object { $_.Line -match 'SENT_OK' })
$sentFail = @($replied | Where-Object { $_.Line -match 'NOT_SENT|ABORT' })
$srcLlm = @($lines | Select-String 'Reply source: LLM')
$srcRule = @($lines | Select-String 'Reply source: RULE_ENGINE')
$srcQuick = @($lines | Select-String 'Reply source: QUICK')
$srcImg = @($lines | Select-String 'Reply source: IMG_TEMPLATE')
$llmErr = @($lines | Select-String 'LLM error')
$monErr = @($lines | Select-String 'Monitor error')
$restarts = @($lines | Select-String 'Monitor started')

# 按天分布
$byDay = @{}
foreach ($r in $replied) {
    if ($r.Line -match '^(\d{4}-\d{2}-\d{2}) ') {
        $d = $Matches[1]
        if (-not $byDay.ContainsKey($d)) { $byDay[$d] = 0 }
        $byDay[$d]++
    }
}
$dayKeys = @($byDay.Keys | Sort-Object)

# 买家列表(从 REPLIED to X: 提取)
$buyerSet = @{}
foreach ($r in $replied) {
    if ($r.Line -match 'REPLIED to (.+?): ') { $buyerSet[$Matches[1].Trim()] = $true }
}
$buyers = @($buyerSet.Keys | Sort-Object)

# 去重会话数
$dedupCount = 0
if (Test-Path $stateFile) {
    try { $dedupCount = @((Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).replied.PSObject.Properties).Count } catch {}
}

# 快照数(窗口内)
$snapCount = @(Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $winStart }).Count

# 本周质量报告
$qualityReps = @(Get-ChildItem $outDir -Filter "quality_*.md" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $winStart } | Sort-Object LastWriteTime)

# ===== 2) 生成周报 =====
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# 阿里国际站自动回复周报")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- **统计窗口**: $($winStart.ToString("yyyy-MM-dd")) ~ $(Get-Date -Format "yyyy-MM-dd HH:mm")")
[void]$sb.AppendLine("- **生成时间**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## 总体指标")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| 指标 | 数值 |")
[void]$sb.AppendLine("|------|------|")
[void]$sb.AppendLine("| 回复总数 | $($replied.Count) 条 |")
[void]$sb.AppendLine("| 发送成功 | $($sentOk.Count) 条 |")
[void]$sb.AppendLine("| 发送失败/中止 | $($sentFail.Count) 条 |")
[void]$sb.AppendLine("| 涉及买家 | $($buyers.Count) 位 |")
[void]$sb.AppendLine("| LLM 生成 | $($srcLlm.Count) 条 |")
[void]$sb.AppendLine("| 规则引擎(LLM失败回退) | $($srcRule.Count + $srcQuick.Count) 条 |")
[void]$sb.AppendLine("| 图片引导模板 | $($srcImg.Count) 条 |")
[void]$sb.AppendLine("| LLM 失败次数 | $($llmErr.Count) 次 |")
[void]$sb.AppendLine("| 监控异常 | $($monErr.Count) 次 |")
[void]$sb.AppendLine("| 监控重启 | $($restarts.Count) 次 |")
[void]$sb.AppendLine("| 消息快照 | $snapCount 份 |")
[void]$sb.AppendLine("| 去重会话(累计) | $dedupCount 个 |")
[void]$sb.AppendLine()
[void]$sb.AppendLine("## 每日回复量")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| 日期 | 回复数 |")
[void]$sb.AppendLine("|------|--------|")
foreach ($d in $dayKeys) { [void]$sb.AppendLine("| $d | $($byDay[$d]) |") }
[void]$sb.AppendLine()
[void]$sb.AppendLine("## 活跃买家")
[void]$sb.AppendLine()
foreach ($b in $buyers) { [void]$sb.AppendLine("- $b") }
[void]$sb.AppendLine()
# P3.4 买家国别分布(仅聚合统计,档案 PII 留在本机 data\buyers\)
$buyerDir = Join-Path (Get-SkillPath "data") "buyers"
$countryCount = @{}
if (Test-Path $buyerDir) {
    Get-ChildItem $buyerDir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $p = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($p.country) { $c = [string]$p.country; $countryCount[$c] = ([int]$countryCount[$c]) + 1 }
        } catch {}
    }
}
if ($countryCount.Count -gt 0) {
    [void]$sb.AppendLine("## 买家国别分布")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| 国家 | 买家数 |")
    [void]$sb.AppendLine("|------|--------|")
    foreach ($c in ($countryCount.Keys | Sort-Object)) { [void]$sb.AppendLine("| $c | $($countryCount[$c]) |") }
    [void]$sb.AppendLine()
}
if ($qualityReps.Count -gt 0) {
    [void]$sb.AppendLine("## 本周质量报告")
    [void]$sb.AppendLine()
    foreach ($q in $qualityReps) { [void]$sb.AppendLine("- [$($q.Name)](quality_$($q.Name -replace 'quality_',''))") }
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("由 alibaba-auto-reply 监控自动生成")

$outFile = Join-Path $outDir ("weekly_" + (Get-Date -Format "yyyyMMdd") + ".md")
$sb.ToString() | Set-Content -Path $outFile -Encoding UTF8
Write-Output "weekly report: $outFile"

# P2.5 补跑标注:若上次周报已超过 7 天(计划任务错过,如机器关机),当前生成视为补跑
$lastRep = @(Get-ChildItem $outDir -Filter "weekly_*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
if ($lastRep.Count -ge 2) {
    $prev = $lastRep[1].LastWriteTime
    if (((Get-Date) - $prev).TotalDays -gt 7) {
        Add-Content -Path $logFile -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " | WEEKLY-CATCHUP: previous report $($lastRep[1].Name) was $([math]::Round(((Get-Date)-$prev).TotalDays,1)) days ago - generated catch-up") -Encoding UTF8
        Write-Output "WEEKLY-CATCHUP: previous report was $([math]::Round(((Get-Date)-$prev).TotalDays,1)) days ago"
    }
}

# P2.4 报告保留:删除 90 天前的 quality_/reply_summary_/weekly_ 报告
$repCutoff = (Get-Date).AddDays(-90)
$removedReps = @(Get-ChildItem $outDir -Filter "*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(quality|reply_summary|weekly)_' -and $_.LastWriteTime -lt $repCutoff })
foreach ($rr in $removedReps) { Remove-Item $rr.FullName -Force -ErrorAction SilentlyContinue }
if ($removedReps.Count -gt 0) { Add-Content -Path $logFile -Value ((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " | REPORT-CLEANUP: removed $($removedReps.Count) reports older than 90 days") -Encoding UTF8; Write-Output "REPORT-CLEANUP: removed $($removedReps.Count)" }

# ===== 3) 沉睡买家唤醒(随周报一起) =====
if (-not $SkipNudge) {
    $nudgeScript = Join-Path $LogDir "nudge.ps1"
    if (Test-Path $nudgeScript) {
        Write-Output "--- 执行沉睡买家唤醒 ---"
        powershell -ExecutionPolicy Bypass -NoProfile -File $nudgeScript -LogDir $LogDir 2>&1
    }
}
