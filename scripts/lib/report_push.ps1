# lib/report_push.ps1 - 质量/周报生成后推企微摘要(统计+重点项+文件名)。
# 返回码: SENT_OK / SKIPPED-DUP / PUSH-DISABLED / NO_RECEIVER / SERVICE_DOWN / SEND_FAIL / PARSE-EMPTY
# 规则: 失败只记日志不重试; 同报告文件去重(data\report_push_state.json, 上限 100 条); 摘要 ≤800 字符。
# 依赖: config.ps1 / lib\wecom.ps1 / lib\log.ps1 (本文件自行 dot-source, 可独立单测)。
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
. (Join-Path $PSScriptRoot "wecom.ps1")
. (Join-Path $PSScriptRoot "log.ps1")

# 纯函数: 解析报告文件 → 摘要文本(失败/空文件返回 $null)。Kind: quality | weekly
function Get-ReportSummaryText([string]$ReportFile, [string]$Kind) {
    if (-not $ReportFile -or -not (Test-Path -LiteralPath $ReportFile)) { return $null }
    $raw = Get-Content -LiteralPath $ReportFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $lines = @($raw -split "`r?`n")
    $name = Split-Path $ReportFile -Leaf
    $out = New-Object System.Collections.ArrayList

    if ($Kind -eq 'quality') {
        $window = ''; $buyers = ''; $top1 = ''
        $negCount = 0; $sawNeg = $false; $inNeg = $false
        $genTime = ''
        foreach ($l in $lines) {
            if ($l -match '^- \*\*统计时段\*\*:\s*(.+)$') { $window = $Matches[1].Trim() }
            elseif ($l -match '^- \*\*生成时间\*\*:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') { $genTime = $Matches[1] }
            elseif ($l -match '^- \*\*涉及买家\*\*:\s*(\d+)\s*位') { $buyers = $Matches[1] }
            elseif ($l -match '^##\s*负面案例') { $inNeg = $true; $sawNeg = $true; continue }
            elseif ($l -match '^##\s') { $inNeg = $false }
            if ($inNeg -and $l -match '^- \*\*') { $negCount++ }
            if ($l -match '^- \*\*(.+?)\*\*\s*评分\s*(-?\d+)') { $top1 = "$($Matches[1]) 评分 $($Matches[2])" }
        }
        $headerDate = ''
        if ($name -match '^quality_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})') { $headerDate = "$($Matches[1])-$($Matches[2])-$($Matches[3]) $($Matches[4]):$($Matches[5])" }
        if (-not $headerDate) { $headerDate = $genTime }
        [void]$out.Add("[质量报告] $headerDate")
        if ($window) { [void]$out.Add("- 统计时段: $window") }
        if ($buyers) { [void]$out.Add("- 涉及买家: $buyers 位") }
        if ($sawNeg) { [void]$out.Add("- 负面案例: $negCount 条") }
        if ($top1) { [void]$out.Add("- 风险 Top1: $top1") }
        [void]$out.Add("- 报告: $name")
        return ($out -join "`n")
    }

    if ($Kind -eq 'weekly') {
        $winStart = ''; $winEnd = ''
        $total = ''; $ok = ''; $fail = ''
        $buyers = ''; $llm = ''; $fallback = ''; $img = ''
        $llmErr = ''; $monErr = ''
        $countries = New-Object System.Collections.ArrayList
        $inCountry = $false
        foreach ($l in $lines) {
            if ($l -match '^- \*\*统计窗口\*\*:\s*(\d{4}-\d{2}-\d{2})\s*~\s*(\d{4}-\d{2}-\d{2})') { $winStart = $Matches[1]; $winEnd = $Matches[2] }
            elseif ($l -match '^\|\s*回复总数\s*\|\s*(\d+)\s*条\s*\|') { $total = $Matches[1] }
            elseif ($l -match '^\|\s*发送成功\s*\|\s*(\d+)\s*条\s*\|') { $ok = $Matches[1] }
            elseif ($l -match '^\|\s*发送失败/中止\s*\|\s*(\d+)\s*条\s*\|') { $fail = $Matches[1] }
            elseif ($l -match '^\|\s*涉及买家\s*\|\s*(\d+)\s*位\s*\|') { $buyers = $Matches[1] }
            elseif ($l -match '^\|\s*LLM 生成\s*\|\s*(\d+)\s*条\s*\|') { $llm = $Matches[1] }
            elseif ($l -match '^\|\s*规则引擎\(LLM失败回退\)\s*\|\s*(\d+)\s*条\s*\|') { $fallback = $Matches[1] }
            elseif ($l -match '^\|\s*图片引导模板\s*\|\s*(\d+)\s*条\s*\|') { $img = $Matches[1] }
            elseif ($l -match '^\|\s*LLM 失败次数\s*\|\s*(\d+)\s*次\s*\|') { $llmErr = $Matches[1] }
            elseif ($l -match '^\|\s*监控异常\s*\|\s*(\d+)\s*次\s*\|') { $monErr = $Matches[1] }
            elseif ($l -match '^##\s*买家国别分布') { $inCountry = $true; continue }
            elseif ($l -match '^##\s') { $inCountry = $false }
            if ($inCountry -and $l -match '^\|\s*(?!国家)(.+?)\s*\|\s*(\d+)\s*\|$') { [void]$countries.Add(@($Matches[1].Trim(), [int]$Matches[2])) }
        }
        $header = "[周报]"
        if ($winStart -and $winEnd) { $header = "[周报] $winStart ~ $winEnd" }
        elseif ($name -match '^weekly_(\d{4})(\d{2})(\d{2})') { $header = "[周报] $($Matches[1])-$($Matches[2])-$($Matches[3])" }
        [void]$out.Add($header)
        if ($total -ne '' -or $ok -ne '' -or $fail -ne '') {
            $r = "- 回复: $total 条"
            if ($ok -ne '' -or $fail -ne '') { $r += "（成功 $ok / 失败 $fail）" }
            [void]$out.Add($r)
        }
        if ($buyers) { [void]$out.Add("- 涉及买家: $buyers 位") }
        if ($llm -ne '' -or $fallback -ne '' -or $img -ne '') { [void]$out.Add("- LLM: $llm / 回退: $fallback / 图片: $img") }
        if ($llmErr -ne '' -or $monErr -ne '') { [void]$out.Add("- 异常: LLM 失败 $llmErr 次 / 监控 $monErr 次") }
        if ($countries.Count -gt 0) {
            $top3 = @($countries | Sort-Object { -[int]$_[1] } | Select-Object -First 3 | ForEach-Object { "$($_[0]) $($_[1])" })
            [void]$out.Add("- 国别 Top3: " + ($top3 -join '、'))
        }
        [void]$out.Add("- 报告: $name")
        return ($out -join "`n")
    }

    return $null
}

# 发送摘要: 开关 → 去重 → 解析 → 推送 → 记录状态(仅 SENT_OK 记录, 失败下次可重试)
function Send-ReportWecomSummary([string]$ReportFile, [string]$Kind, [switch]$Force) {
    $logFile = Join-Path (Get-SkillPath "logs") "monitor.log"
    $cfg = Get-SkillConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'report_push_enabled') -and $cfg.report_push_enabled -eq $false) {
        return "PUSH-DISABLED"
    }
    if (-not $ReportFile -or -not (Test-Path -LiteralPath $ReportFile)) { return "PARSE-EMPTY" }
    $name = Split-Path $ReportFile -Leaf
    $stateFile = Join-Path (Get-SkillPath "data") "report_push_state.json"
    $state = $null
    if (Test-Path $stateFile) {
        try { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
    }
    if ($state -and $state.pushed -and -not $Force) {
        $pushedNames = @($state.pushed.PSObject.Properties.Name)
        if ($pushedNames -contains $name) { return "SKIPPED-DUP" }
    }
    $text = Get-ReportSummaryText $ReportFile $Kind
    if (-not $text) {
        try { Write-SkillLog "REPORT-PUSH: kind=$Kind file=$name result=PARSE-EMPTY" $logFile } catch {}
        return "PARSE-EMPTY"
    }
    if ($text.Length -gt 800) { $text = $text.Substring(0, 800) }
    $res = Send-WecomMessage $text
    if ($res -eq 'SENT_OK') {
        $pushed = @{}
        if ($state -and $state.pushed) { foreach ($p in $state.pushed.PSObject.Properties) { $pushed[$p.Name] = $p.Value } }
        $pushed[$name] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        if ($pushed.Count -gt 100) {
            $keep = @($pushed.GetEnumerator() | Sort-Object { [datetime]$_.Value } | Select-Object -Last 100)
            $pushed = @{}
            foreach ($e in $keep) { $pushed[$e.Key] = $e.Value }
        }
        try { @{ pushed = $pushed } | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8 } catch {}
        try { Write-SkillLog "REPORT-PUSH: kind=$Kind file=$name result=SENT_OK" $logFile } catch {}
        return "SENT_OK"
    }
    $mapped = "SEND_FAIL"
    if ($res -eq 'NO_RECEIVER') { $mapped = 'NO_RECEIVER' }
    elseif ($res -eq 'SERVICE_DOWN') { $mapped = 'SERVICE_DOWN' }
    try { Write-SkillLog "REPORT-PUSH: kind=$Kind file=$name result=$mapped ($res)" $logFile } catch {}
    return $mapped
}
