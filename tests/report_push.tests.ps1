# report_push regression tests (纯函数解析器断言, 虚构数据; 不做真实推送)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\report_push.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\report_push.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}
function Assert-Contains([string]$name, [string]$hay, [string]$needle) {
    if ($hay -and $hay.Contains($needle)) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | missing: [$needle]" }
}

Write-Output "== report_push tests =="

$fixtures = Join-Path $here "fixtures"
$qFile = Join-Path $fixtures "report_quality_fixture.md"
$wFile = Join-Path $fixtures "report_weekly_fixture.md"

# ---- 1. 质量报告解析 ----
$q = Get-ReportSummaryText $qFile 'quality'
Assert-True "q-not-null" ($null -ne $q)
Assert-Contains "q-header-date" $q "[质量报告] 2026-09-12 05:00"
Assert-Contains "q-window" $q "- 统计时段: 最近 48 小时"
Assert-Contains "q-buyers" $q "- 涉及买家: 3 位"
Assert-Contains "q-neg-count" $q "- 负面案例: 2 条"
Assert-Contains "q-top1" $q "- 风险 Top1: Alice Test 评分 -2"
Assert-Contains "q-report-name" $q "- 报告: report_quality_fixture.md"
Assert-True "q-len-800" ($q.Length -le 800)

# ---- 2. 周报解析 ----
$w = Get-ReportSummaryText $wFile 'weekly'
Assert-True "w-not-null" ($null -ne $w)
Assert-Contains "w-header-window" $w "[周报] 2026-09-08 ~ 2026-09-14"
Assert-Contains "w-reply" $w "- 回复: 35 条（成功 34 / 失败 1）"
Assert-Contains "w-buyers" $w "- 涉及买家: 18 位"
Assert-Contains "w-llm" $w "- LLM: 30 / 回退: 4 / 图片: 1"
Assert-Contains "w-errors" $w "- 异常: LLM 失败 2 次 / 监控 1 次"
Assert-Contains "w-country-top3" $w "- 国别 Top3: Brazil 6、United States 4、Mexico 3"
Assert-Contains "w-report-name" $w "- 报告: report_weekly_fixture.md"
Assert-True "w-len-800" ($w.Length -le 800)

# ---- 3. 降级: 缺节/无负面/无国别 → 不报错, 省略缺失行 ----
$tmp = Join-Path $env:TEMP ("report_push_tests_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $qDeg = Join-Path $tmp "quality_20260901_0500.md"
    @(
        "# 自动回复质量报告", "",
        "- **涉及买家**: 1 位", "",
        "## 负面案例", "", "无。", "",
        "## 风险会话 Top1", "",
        "- **Solo Buyer** 评分 0，最近快照 msgs_x.txt"
    ) -join "`n" | Set-Content -Path $qDeg -Encoding UTF8
    $qd = Get-ReportSummaryText $qDeg 'quality'
    Assert-True "qd-not-null" ($null -ne $qd)
    Assert-Contains "qd-header-from-filename" $qd "[质量报告] 2026-09-01 05:00"
    Assert-Contains "qd-buyers" $qd "- 涉及买家: 1 位"
    Assert-Contains "qd-neg-zero" $qd "- 负面案例: 0 条"
    Assert-True "qd-omit-window" (-not $qd.Contains("统计时段"))
    Assert-Contains "qd-top1" $qd "- 风险 Top1: Solo Buyer 评分 0"

    $wDeg = Join-Path $tmp "weekly_20260901.md"
    @(
        "# 阿里国际站自动回复周报", "",
        "- **统计窗口**: 2026-08-25 ~ 2026-09-01", "",
        "## 总体指标", "",
        "| 指标 | 数值 |",
        "|------|------|",
        "| 回复总数 | 2 条 |"
    ) -join "`n" | Set-Content -Path $wDeg -Encoding UTF8
    $wd = Get-ReportSummaryText $wDeg 'weekly'
    Assert-True "wd-not-null" ($null -ne $wd)
    Assert-Contains "wd-header" $wd "[周报] 2026-08-25 ~ 2026-09-01"
    Assert-Contains "wd-reply-partial" $wd "- 回复: 2 条"
    Assert-True "wd-omit-country" (-not $wd.Contains("国别"))
    Assert-True "wd-omit-errors" (-not $wd.Contains("异常"))

    # ---- 4. 空文件/不存在/未知类型 → $null ----
    $empty = Join-Path $tmp "quality_20260901_0600.md"
    Set-Content -Path $empty -Value "   `n  " -Encoding UTF8
    Assert-True "empty-null" ($null -eq (Get-ReportSummaryText $empty 'quality'))
    Assert-True "missing-null" ($null -eq (Get-ReportSummaryText (Join-Path $tmp "nope.md") 'quality'))
    Assert-True "unknown-kind-null" ($null -eq (Get-ReportSummaryText $qFile 'other'))

    # ---- 5. 摘要行数/格式稳定(首行+末行) ----
    $qLines = @($q -split "`n")
    Assert-True "q-first-line" ($qLines[0] -match '^\[质量报告\] \d{4}-\d{2}-\d{2} \d{2}:\d{2}$')
    Assert-True "q-last-line" ($qLines[-1] -match '^- 报告: .+\.md$')
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output ("  RESULT: pass=$script:pass fail=$script:fail")
if ($script:fail -gt 0) { Write-Output ("  FAILED: " + ($script:fails -join ", ")); exit 1 }
Write-Output "  ALL PASS"
exit 0
