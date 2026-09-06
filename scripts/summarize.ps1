param(
    [string]$LogFile = "",
    [string]$OutDir = "",
    [string]$StateFile = ""
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
if (-not $LogFile) { $LogFile = Join-Path (Get-SkillPath "logs") "monitor.log" }
if (-not $OutDir) { $OutDir = Get-SkillPath "reports" }
if (-not $StateFile) { $StateFile = Join-Path (Get-SkillPath "scripts") "summary_last.json" }

# 上次总结的截止时间（ISO 字符串），文件不存在则从日志最早时间开始
$lastEnd = $null
if (Test-Path $StateFile) {
    try { $lastEnd = (Get-Content $StateFile -Raw | ConvertFrom-Json).last_end } catch {}
}

$lines = Get-Content $LogFile -Encoding UTF8
$replies = New-Object System.Collections.ArrayList
$current = $null

foreach ($line in $lines) {
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| (REPLIED to .+?: .+)$') {
        if ($current -and $current.reply_text) { [void]$replies.Add($current) }
        $current = [pscustomobject]@{
            time       = $Matches[1]
            summary    = $Matches[2]
            reply_text = $null
        }
    }
    elseif ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| Reply text: (.+)$' -and $current) {
        $current.reply_text = $Matches[2]
    }
}
if ($current -and $current.reply_text) { [void]$replies.Add($current) }

if ($replies.Count -eq 0) {
    "no replies in log"
    exit 0
}

# 解析时间
$parsed = @()
foreach ($r in $replies) {
    try { $t = [datetime]::ParseExact($r.time, "yyyy-MM-dd HH:mm:ss", $null) } catch { continue }
    if ($lastEnd) {
        try { $le = [datetime]::ParseExact($lastEnd, "yyyy-MM-dd HH:mm:ss", $null) } catch { $le = $null }
        if ($le -and $t -le $le) { continue }
    }
    $parsed += [pscustomobject]@{ t = $t; r = $r }
}

if ($parsed.Count -eq 0) {
    # 记录当前最后一条日志时间作为截止
    $last = $replies[-1].time
    @{ last_end = $last } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    "no new replies since last summary"
    exit 0
}

# 按会话名聚合（从 summary 中提取买家名）
$byBuyer = @{}
foreach ($p in $parsed) {
    $m = [regex]::Match($p.r.summary, '^REPLIED to (.+?): ')
    $buyer = if ($m.Success) { $m.Groups[1].Value } else { "未知" }
    if (-not $byBuyer.ContainsKey($buyer)) { $byBuyer[$buyer] = New-Object System.Collections.ArrayList }
    [void]$byBuyer[$buyer].Add($p)
}

$start = ($parsed | Measure-Object -Property t -Minimum).Minimum
$end = ($parsed | Measure-Object -Property t -Maximum).Maximum

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$fileName = "reply_summary_" + $start.ToString("yyyyMMdd_HHmm") + "-" + $end.ToString("HHmm") + ".md"
$outFile = Join-Path $OutDir $fileName

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# 阿里国际站自动回复总结")
[void]$sb.AppendLine()
[void]$sb.AppendLine("- **统计时段**: $($start.ToString("yyyy-MM-dd HH:mm:ss")) ~ $($end.ToString("yyyy-MM-dd HH:mm:ss"))")
[void]$sb.AppendLine("- **生成时间**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")")
[void]$sb.AppendLine("- **回复总数**: $($parsed.Count) 条")
[void]$sb.AppendLine("- **涉及买家**: $($byBuyer.Count) 位")
[void]$sb.AppendLine()

foreach ($buyer in ($byBuyer.Keys | Sort-Object)) {
    $items = $byBuyer[$buyer]
    [void]$sb.AppendLine("## $buyer")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| 时间 | 发送状态 | 回复内容 |")
    [void]$sb.AppendLine("|------|----------|----------|")
    foreach ($it in ($items | Sort-Object { $_.t })) {
        $status = if ($it.r.summary -match 'SENT_OK') { "✅ 成功" } elseif ($it.r.summary -match 'NOT_SENT') { "❌ 失败" } else { "⚠️ 待确认" }
        $text = ($it.r.reply_text -replace '\|', '\|').Substring(0, [Math]::Min(100, ($it.r.reply_text).Length))
        [void]$sb.AppendLine("| $($it.t.ToString("HH:mm:ss")) | $status | $text |")
    }
    [void]$sb.AppendLine()
}

[void]$sb.AppendLine("---")
[void]$sb.AppendLine("## 货物数据齐全度（供报价判断）")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| 买家 | 货物名称 | 总重量 | 尺寸L\*W\*H | 收货地址 | 图片(参考) | 供应商(参考) | 状态 |")
[void]$sb.AppendLine("|------|---------|--------|-----------|---------|----------|----------|------|")
foreach ($buyer in ($byBuyer.Keys | Sort-Object)) {
    $st = Get-GoodsDataStatus $buyer
    if (-not $st) { continue }
    $g = Get-GoodsName $buyer
    $marks = @(if ($st.weight) { "✅" } else { "❌" })
    $marks += @(if ($st.dims) { "✅" } else { "❌" })
    $marks += @(if ($st.img) { "✅" } else { "❌" })
    $marks += @(if ($st.addr) { "✅" } else { "❌" })
    $marks += @(if ($st.supplier) { "✅" } else { "❌" })
    $missing = @()
    if (-not $st.weight) { $missing += "总重量" }
    if (-not $st.dims) { $missing += "尺寸" }
    if (-not $st.addr) { $missing += "地址" }
    if (-not $g.known) { $missing += "货物名称" }
    $concl = if ($missing.Count -eq 0) { "✅ 齐全，可报价" } else { "缺: " + ($missing -join "、") }
    $escBuyer = $buyer -replace '\|', '\|'
    $escGoods = $g.name -replace '\|', '\|'
    [void]$sb.AppendLine("| $escBuyer | $escGoods | $($marks[0]) | $($marks[1]) | $($marks[3]) | $($marks[2]) | $($marks[4]) | $concl |")
}
[void]$sb.AppendLine()
[void]$sb.AppendLine("> 注：齐全度由规则从买家消息自动判断（重量=数字+kg/吨，尺寸=三维数字或 dimensions，地址=地址词或城市/国家，货物名称=产品链接或品名词）。图片与供应商联系列为参考，不计入齐全判定；结论仅供报价参考，请以实际聊天内容为准。")
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("由 alibaba-auto-reply 监控自动生成")

$sb.ToString() | Set-Content -Path $outFile -Encoding UTF8
@{ last_end = $end.ToString("yyyy-MM-dd HH:mm:ss") } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

"summary written: $outFile ($($parsed.Count) replies)"
