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
# ============================================================================================
# [2026-10-05 spec §8.1 F7] 结论直接取自**统一事实模型**
#   （lib\facts_engine.ps1::Get-QuoteReadiness，经 lib\goods.ps1::Get-GoodsDataStatus 适配）。
#   本报表不再自行组合"重量 + 尺寸 + 地址 + 货名"判据：ready / missingFields /
#   optionalMissingFields / clarifications / collectionComplete / ruleVersion / error 一律按统一
#   结果原样呈现，旧 goods 布尔值（weight/dims/addr/img/supplier）只用于逐项 ✅/❌ 展示。
#   取值接口必须同时支持哈希表与对象：Get-GoodsDataStatus 返回**哈希表**，而 PS 5.1 下哈希表的
#   PSObject.Properties 只暴露 CLR 成员（Contains/Keys/Values/Count），用它判键会静默拿到 $null。
function Get-SummaryStatusValue($Status, [string]$Name) {
    if ($null -eq $Status) { return $null }
    if ($Status -is [System.Collections.IDictionary]) {
        if ($Status.Contains($Name)) { return $Status[$Name] }
        return $null
    }
    if ($Status.PSObject.Properties.Name -contains $Name) { return $Status.$Name }
    return $null
}
function Get-SummaryStatusList($Status, [string]$Name) {
    $v = Get-SummaryStatusValue $Status $Name
    if ($null -eq $v) { return @() }
    return @($v | Where-Object { $null -ne $_ -and [string]$_ -ne '' })
}
# 表格单元格转义：竖线与换行都不能破坏 Markdown 表格结构。
function Format-SummaryCell($Text) {
    $t = [string]$Text
    $t = $t -replace '\|', '\|'
    $t = $t -replace '\r?\n', ' '
    return $t.Trim()
}
# 统一模型的字段键 -> 人话（展示用；未登记的键回退到统一字段登记表 Get-CargoFieldSpecs 的 Label）。
function Get-SummaryFieldLabel([string]$Key) {
    $k = [string]$Key
    if (-not $k) { return '' }
    $labels = @{
        'carton_count'       = '外包装件数'
        'count'              = '数量（范围未明）'
        'unit_weight'        = '包装重量（单件或总重）'
        'total_weight'       = '总重量'
        'weight'             = '重量（范围未明）'
        'unit_dimensions'    = '包装尺寸（单件或整批）'
        'lot_dimensions'     = '整批尺寸'
        'dimensions'         = '尺寸（范围未明）'
        'delivery_address'   = '可用报价目的地'
        'goods_name'         = '货物名称'
        'reference_images'   = '参考图片'
        'supplier_address'   = '供应商地址'
        'supplier_contact'   = '供应商联系方式'
        'recipient_name'     = '收货人名称'
        'recipient_contact'  = '收货人联系方式'
        'unassigned_contact' = '联系方式（角色未明）'
    }
    if ($labels.ContainsKey($k)) { return [string]$labels[$k] }
    if (Get-Command Get-CargoFieldSpecs -ErrorAction SilentlyContinue) {
        foreach ($spec in @(Get-CargoFieldSpecs)) { if ([string]$spec.Key -eq $k) { return [string]$spec.Label } }
    }
    return $k
}
function Format-SummaryFieldList($Keys) {
    $names = New-Object System.Collections.ArrayList
    foreach ($k in @($Keys)) {
        $n = Get-SummaryFieldLabel ([string]$k)
        if ($n -and ($names -notcontains $n)) { [void]$names.Add($n) }
    }
    if ($names.Count -eq 0) { return '—' }
    return (@($names.ToArray()) -join '、')
}
# 判据不可用（error 非空）时任何逐项 ✅/❌ 都不可信，统一显示 ⚠️。
function Format-SummaryMark($Value, [bool]$Judged) {
    if (-not $Judged) { return '⚠️' }
    if ($Value) { return '✅' }
    return '❌'
}
$summaryRuleVersions = @()
[void]$sb.AppendLine("| 买家 | 货物名称 | 外包装件数 | 总重量 | 尺寸L\*W\*H | 报价目的地 | 图片(参考) | 供应商(参考) | 必要缺口 | 辅助缺口(不阻挡报价) | 状态 |")
[void]$sb.AppendLine("|------|---------|-----------|--------|-----------|---------|----------|----------|---------|------------------|------|")
foreach ($buyer in ($byBuyer.Keys | Sort-Object)) {
    $st = Get-GoodsDataStatus $buyer
    if (-not $st) { continue }
    $g = Get-GoodsName $buyer
    # ---- 统一结果（唯一判据） ----
    $ready = [bool](Get-SummaryStatusValue $st 'ready')
    $errorText = [string](Get-SummaryStatusValue $st 'error')
    $missingKeys = @(Get-SummaryStatusList $st 'missingFields')
    $optionalKeys = @(Get-SummaryStatusList $st 'optionalMissingFields')
    $clarifications = @(Get-SummaryStatusList $st 'clarifications')
    $collectionComplete = [bool](Get-SummaryStatusValue $st 'collectionComplete')
    $ruleVersion = [string](Get-SummaryStatusValue $st 'ruleVersion')
    if ($ruleVersion -and ($summaryRuleVersions -notcontains $ruleVersion)) { $summaryRuleVersions += $ruleVersion }
    $judged = (-not $errorText.Trim())
    # 外包装件数是基本报价条件，但没有对应的旧 goods 布尔值：直接取统一必要缺口清单。
    $cartonCountOk = (($missingKeys -notcontains 'carton_count') -and ($missingKeys -notcontains 'count'))
    # ---- 结论：只取统一 Ready / Error / MissingFields / Clarifications ----
    if (-not $judged) {
        # 判据不可用时**绝不**因为缺口数组为空就写"齐全"。
        $concl = '❌ 资料判定失败，需核对'
        $detail = Format-SummaryCell $errorText
        if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) }
        if ($detail) { $concl += '（' + $detail + '）' }
    } elseif ($ready) {
        $concl = '✅ 可进入人工报价准备'
        if (-not $collectionComplete) { $concl += '（辅助资料未齐，见「辅助缺口」列；不阻挡报价准备）' }
    } elseif ($missingKeys.Count -gt 0) {
        $concl = '❌ 不可进入报价准备（缺: ' + (Format-SummaryFieldList $missingKeys) + '）'
    } else {
        $concl = '❌ 不可进入报价准备（统一结果未列出具体缺口，需核对）'
    }
    if ($clarifications.Count -gt 0) {
        $clarCells = @()
        foreach ($cl in $clarifications) { $clarCells += (Format-SummaryCell $cl) }
        $concl += '；待澄清: ' + ($clarCells -join ' / ')
    }
    $escBuyer = Format-SummaryCell $buyer
    $escGoods = Format-SummaryCell $g.name
    $mCarton = Format-SummaryMark $cartonCountOk $judged
    $mWeight = Format-SummaryMark ([bool](Get-SummaryStatusValue $st 'weight')) $judged
    $mDims = Format-SummaryMark ([bool](Get-SummaryStatusValue $st 'dims')) $judged
    $mImg = Format-SummaryMark ([bool](Get-SummaryStatusValue $st 'img')) $judged
    $mSupplier = Format-SummaryMark ([bool](Get-SummaryStatusValue $st 'supplier')) $judged
    $destLabel = Format-SummaryCell (Get-GoodsDestinationLabel $st)
    [void]$sb.AppendLine("| $escBuyer | $escGoods | $mCarton | $mWeight | $mDims | $destLabel | $mImg | $mSupplier | $(Format-SummaryFieldList $missingKeys) | $(Format-SummaryFieldList $optionalKeys) | $concl |")
}
[void]$sb.AppendLine()
$summaryRuleVersionText = '(不可用)'
if ($summaryRuleVersions.Count -gt 0) { $summaryRuleVersionText = ($summaryRuleVersions -join ' / ') }
[void]$sb.AppendLine("> 规则版本（统一事实模型 RuleVersion）: $summaryRuleVersionText")
[void]$sb.AppendLine("> 注：本表**结论直接取自统一事实模型**（lib\facts_engine.ps1::Get-QuoteReadiness，经 lib\goods.ps1::Get-GoodsDataStatus 适配），不再由本报表自行组合重量/尺寸/地址/货名判据，也不因某一列缺失而另立结论。")
[void]$sb.AppendLine("> 基本报价条件 = 外包装件数（箱/托盘）+ 包装重量（单件或已明确总重）+ 包装尺寸（单件或整批）+ 可用报价目的地（买家原文中的收货地址，或明确给出的 Amazon/FBA 收货仓代码；仓库代码即可满足目的地，不代表街道地址已提供）。")
[void]$sb.AppendLine("> 货名、图片、供应商资料、收货人姓名/联系方式是辅助项：缺它们只列进「辅助缺口(不阻挡报价)」列，不改判「可进入人工报价准备」。")
[void]$sb.AppendLine("> 「必要缺口」列按统一模型的字段键给出人话（如 carton_count→外包装件数）；件数/单位/尺寸范围不明或存在冲突时，状态列给出统一模型实际产生的待澄清问题。")
[void]$sb.AppendLine("> 状态只表示「资料是否具备报价准备条件」，不代表已通知、已联系或已报价；本报表不输出任何价格。")
[void]$sb.AppendLine()
[void]$sb.AppendLine("---")
[void]$sb.AppendLine("由 alibaba-auto-reply 监控自动生成")

$sb.ToString() | Set-Content -Path $outFile -Encoding UTF8
@{ last_end = $end.ToString("yyyy-MM-dd HH:mm:ss") } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

"summary written: $outFile ($($parsed.Count) replies)"
