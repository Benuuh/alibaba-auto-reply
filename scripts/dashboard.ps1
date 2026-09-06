# 数据看板:解析 logs\monitor.log 生成聚合统计 HTML(reports\dashboard.html)。
# 只输出聚合统计,不输出买家名/对话内容/地址等 PII。
# 用法: dashboard.ps1 [-Days 14]
# 建议: 每日 06:00 计划任务
param(
    [int]$Days = 14,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$monitorLog = Join-Path $script:logFileDir "monitor.log"
$outDir = Get-SkillPath "reports"
if (-not $outDir) { $outDir = Join-Path (Split-Path $LogDir -Parent) "reports" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$cutoff = (Get-Date).AddDays(-$Days)
$byDay = @{}          # date -> count
$srcCount = @{ LLM = 0; RULE = 0; QUICK = 0; IMG = 0 }
$llmOk = 0; $llmErr = 0; $sentOk = 0; $sentFail = 0; $cycles = 0; $buyers = @{}
$reloads = 0; $errs = 0

Get-Content $monitorLog -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^(\d{4}-\d{2}-\d{2}) \d{2}:\d{2}:\d{2} \| (.+)$') {
        $d = $Matches[1]
        $ts = $null
        try { $ts = [datetime]::ParseExact($Matches[1], "yyyy-MM-dd", $null) } catch { return }
        if ($ts -lt $cutoff) { return }
        $line = $Matches[2]
        $byDay[$d] = ([int]$byDay[$d]) + 1
        if ($line -match 'Scan cycle done') { $cycles++ }
        if ($line -match 'Reply source: LLM') { $srcCount.LLM++ }
        elseif ($line -match 'Reply source: RULE_ENGINE') { $srcCount.RULE++ }
        elseif ($line -match 'Reply source: QUICK') { $srcCount.QUICK++ }
        elseif ($line -match 'Reply source: IMG_TEMPLATE') { $srcCount.IMG++ }
        if ($line -match 'LLM ok') { $llmOk++ }
        if ($line -match 'LLM error') { $llmErr++ }
        if ($line -match 'SENT_OK') { $sentOk++ }
        if ($line -match 'NOT_SENT|ABORT') { $sentFail++ }
        if ($line -match 'REPLIED to (.+?): ') { $buyers[$Matches[1].Trim()] = $true }
        if ($line -match 'RELOADED') { $reloads++ }
        if ($line -match 'Monitor error') { $errs++ }
    }
}

$daysSorted = @($byDay.Keys | Sort-Object)
$maxDay = 1
foreach ($d in $daysSorted) { if ($byDay[$d] -gt $maxDay) { $maxDay = $byDay[$d] } }
$barHtml = ""
foreach ($d in $daysSorted) {
    $h = [Math]::Max(2, [int](40 * $byDay[$d] / $maxDay))
    $barHtml += "<div class='bar-row'><span class='bar-label'>$d</span><div class='bar' style='width:${h}px' title='$($byDay[$d])'></div><span class='bar-val'>$($byDay[$d])</span></div>`n"
}
$llmTotal = $llmOk + $llmErr
$llmRate = if ($llmTotal -gt 0) { [Math]::Round(100 * $llmOk / $llmTotal, 1) } else { 0 }
$avgCycle = if ($cycles -gt 0) { [Math]::Round(($daysSorted.Count * 1440.0 * 60) / $cycles, 0) } else { 0 }

$html = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="600">
<title>alibaba-auto-reply Dashboard</title>
<style>
body { font-family: 'Segoe UI', sans-serif; margin: 24px; background: #f5f6f8; color: #222; }
h1 { font-size: 20px; }
.cards { display: flex; flex-wrap: wrap; gap: 12px; margin: 16px 0; }
.card { background: #fff; border-radius: 8px; padding: 14px 18px; box-shadow: 0 1px 3px rgba(0,0,0,.1); min-width: 140px; }
.card .num { font-size: 26px; font-weight: 600; }
.card .lbl { font-size: 12px; color: #777; }
.bar-row { display: flex; align-items: center; margin: 3px 0; }
.bar-label { width: 110px; font-size: 12px; }
.bar { background: #4a90d9; height: 14px; border-radius: 3px; }
.bar-val { margin-left: 8px; font-size: 12px; }
.foot { color: #999; font-size: 11px; margin-top: 20px; }
</style>
</head>
<body>
<h1>阿里国际站自动回复 - 数据看板</h1>
<div class="foot">生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | 统计窗口: 最近 $Days 天 | 聚合统计,不含买家个人信息</div>
<div class="cards">
  <div class="card"><div class="num">$sentOk</div><div class="lbl">发送成功</div></div>
  <div class="card"><div class="num">$($buyers.Count)</div><div class="lbl">活跃买家(去重)</div></div>
  <div class="card"><div class="num">$llmOk</div><div class="lbl">LLM 成功</div></div>
  <div class="card"><div class="num">$llmErr</div><div class="lbl">LLM 失败</div></div>
  <div class="card"><div class="num">${llmRate}%</div><div class="lbl">LLM 成功率</div></div>
  <div class="card"><div class="num">$sentFail</div><div class="lbl">发送失败/中止</div></div>
  <div class="card"><div class="num">$reloads</div><div class="lbl">页面刷新</div></div>
  <div class="card"><div class="num">$errs</div><div class="lbl">监控异常</div></div>
</div>
<h2>每日日志活动量</h2>
$barHtml
<h2>回复来源分布</h2>
<div class="cards">
  <div class="card"><div class="num">$($srcCount.LLM)</div><div class="lbl">LLM 生成</div></div>
  <div class="card"><div class="num">$($srcCount.RULE)</div><div class="lbl">规则引擎(LLM回退)</div></div>
  <div class="card"><div class="num">$($srcCount.QUICK)</div><div class="lbl">简短快回</div></div>
  <div class="card"><div class="num">$($srcCount.IMG)</div><div class="lbl">图片引导模板</div></div>
</div>
<div class="foot">由 alibaba-auto-reply dashboard.ps1 自动生成</div>
</body>
</html>
"@

$outFile = Join-Path $outDir "dashboard.html"
$html | Set-Content -Path $outFile -Encoding UTF8
Write-Output "dashboard: $outFile"
