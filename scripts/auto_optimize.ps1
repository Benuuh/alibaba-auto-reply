# 自动优化:基于质量报告/总结反馈,用 LLM 提炼规则改进,自动写入语料库与提示词。
# 护栏:只做新增式修改(never 规则 / 质量红线),不动模板/价格/品牌;写入前自动备份;单次数量上限;无负面案例不动作。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File auto_optimize.ps1 [-DryRun] [-MaxRules 5]
# 计划任务: AlibabaAutoReplyOptimize 每日 05:30(质量报告 05:00 之后)
param(
    [switch]$DryRun,
    [int]$MaxRules = 5,
    [int]$ConsolidateThresholdChars = 14000,
    [int]$ConsolidateBlockThreshold = 4,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# LLM 配置(同 monitor 的 llm_config.json;api_key 只从 credentials.md 读取)
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\llm.ps1")
$llmCfgFile = Get-SkillPath "llmcfg"
if (-not $llmCfgFile) { $llmCfgFile = Join-Path (Split-Path $LogDir -Parent) "llm_config.json" }
# 只做存在性门槛:配置实际读取在 lib\llm.ps1 的 Invoke-LLM 内部统一完成(带缓存),此处不再重复解析;
# 文件损坏/无法解析时 Invoke-LLM 返回 $null,由下方 AUTOOPT-LLM-FAIL 兜底
if (-not (Test-Path $llmCfgFile)) { Write-Output "AUTOOPT-NO-LLM-CONFIG"; exit 0 }

# 1) 找最新质量报告(无报告则跳过)
$repDir = Get-SkillPath "reports"
$report = $null
if (Test-Path $repDir) {
    $report = @(Get-ChildItem $repDir -Filter "quality_*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}
if (-not $report -or $report.Count -eq 0) { Write-Output "AUTOOPT-NO-REPORT"; exit 0 }
$reportText = Get-Content $report[0].FullName -Raw -Encoding UTF8
if ($reportText.Length -lt 200) { Write-Output "AUTOOPT-EMPTY-REPORT"; exit 0 }

# 2) 组装输入:质量报告 + 现有 never 规则 + 现有红线(供 LLM 去重参考)
$rulesFile = Join-Path $LogDir "reply_rules.json"
$promptFile = Join-Path $LogDir "reply_agent_prompt.md"
$rulesRaw = ""
if (Test-Path $rulesFile) { $rulesRaw = Get-Content $rulesFile -Raw -Encoding UTF8 }
$promptRaw = ""
if (Test-Path $promptFile) { $promptRaw = Get-Content $promptFile -Raw -Encoding UTF8 }

$sysPrompt = "你是一位资深跨境电商客服质量分析师。根据质量报告中的负面案例,提炼可直接用于自动回复系统的改进规则。只输出 JSON,不要任何其他文字。JSON 结构: {`"never`": [英文行为禁令,每条≤150字符], `"redlines`": [中文生成约束,每条≤150字符], `"rationale`": [中文依据,每条对应一条建议] }。要求: 1) 每条建议必须能从负面案例直接推导,禁止臆造; 2) 与已有规则不重复; 3) never=发给买家的回复中禁止出现的行为,redlines=生成回复时必须遵守的约束; 4) never 与 redlines 合计不超过 $MaxRules 条; 5) 没有可提炼的改进时输出 {`"never`":[],`"redlines`":[]}。"

$userMsg = "=== 质量报告 ===`n$reportText`n`n=== 现有 reply_rules.json(含 never 规则) ===`n$rulesRaw`n`n=== 现有 reply_agent_prompt.md(含质量红线第五步) ===`n$promptRaw"

# 3) LLM 调用(统一走 lib\llm.ps1:HttpWebRequest + 显式 UTF-8 解码,key 来自 credentials.md)
$messages = @(
    @{ role = "system"; content = $sysPrompt },
    @{ role = "user"; content = $userMsg }
)
$respText = Invoke-LLM $messages 0.3 800 $logFile
if (-not $respText) { Write-Output "AUTOOPT-LLM-FAIL"; exit 0 }

# 4) 解析与护栏校验(Invoke-LLM 已返回建议 JSON 文本,直接解析)
$parsed = $null
try { $parsed = $respText | ConvertFrom-Json } catch { Write-Log "AUTOOPT: LLM suggestion JSON parse failed"; Write-Output "AUTOOPT-PARSE-FAIL"; exit 0 }
$never = @()
if ($parsed.never) { $never = @($parsed.never | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 }) }
$redlines = @()
if ($parsed.redlines) { $redlines = @($parsed.redlines | Where-Object { $_ -is [string] -and $_.Trim().Length -gt 0 }) }
if ($never.Count -eq 0 -and $redlines.Count -eq 0) {
    Write-Log "AUTOOPT: no suggestions from $($report[0].Name)"
    Write-Output "AUTOOPT-NO-SUGGESTIONS"
    exit 0
}
# 数量上限 + 与现有内容去重(子串包含,大小写不敏感)
if ($never.Count -gt $MaxRules) { $never = $never[0..($MaxRules-1)] }
if ($redlines.Count -gt $MaxRules) { $redlines = $redlines[0..($MaxRules-1)] }
$existing = ($rulesRaw + $promptRaw).ToLower()
$never = @($never | Where-Object { -not $existing.Contains($_.Trim().ToLower()) })
$redlines = @($redlines | Where-Object { -not $existing.Contains($_.Trim().ToLower()) })
if ($never.Count -eq 0 -and $redlines.Count -eq 0) { Write-Output "AUTOOPT-ALL-DUP"; exit 0 }

if ($DryRun) {
    Write-Output "=== AUTOOPT DRY-RUN(来源: $($report[0].Name)) ==="
    foreach ($n in $never) { Write-Output "never:    $n" }
    foreach ($r in $redlines) { Write-Output "redline:  $r" }
    Write-Output "=== 共 $($never.Count + $redlines.Count) 条建议,未写入 ==="
    exit 0
}

# 5) 应用(备份 + 追加;写入前精确去重 + 总量上限,防规则重复累积)
if ($never.Count -gt 0) {
    if (Test-Path $rulesFile) { Copy-Item $rulesFile "$rulesFile.bak" -Force }
    $rules = Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $cur = @()
    if ($rules.reply_rules.never) { $cur = @($rules.reply_rules.never) }
    foreach ($n in $never) { $cur += $n }
    # 精确去重(Trim + 小写归一),保留首次出现顺序
    $seen = @{}
    $dedup = @()
    foreach ($c in $cur) {
        $k = $c.Trim().ToLowerInvariant()
        if ($k.Length -gt 0 -and -not $seen.ContainsKey($k)) { $seen[$k] = $true; $dedup += $c }
    }
    # 总量上限:超限丢弃最旧,保留最新 40 条(新建议优先;旧规则已被更新的规则覆盖)
    if ($dedup.Count -gt 40) {
        $dropped = $dedup.Count - 40
        Write-Log "AUTOOPT: never rules exceed cap 40 (actual $($dedup.Count)), dropping oldest $dropped (keep newest 40)"
        $dedup = $dedup[($dedup.Count - 40)..($dedup.Count - 1)]
    }
    $rules.reply_rules.never = $dedup
    $rules | ConvertTo-Json -Depth 6 | Set-Content -Path $rulesFile -Encoding UTF8
    Write-Log "AUTOOPT: +$($never.Count) never rules into reply_rules.json (dedup applied, total $($dedup.Count))"
}
if ($redlines.Count -gt 0) {
    if (Test-Path $promptFile) { Copy-Item $promptFile "$promptFile.bak" -Force }
    $addLines = @("", "# 自动优化追加的质量红线($(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
    foreach ($r in $redlines) { $addLines += "- $r" }
    Add-Content -Path $promptFile -Value ($addLines -join "`n") -Encoding UTF8
    Write-Log "AUTOOPT: +$($redlines.Count) redlines into reply_agent_prompt.md (backup saved)"

    # 阈值触发合并:字符数超限或自动块数超限 -> 同进程调用 consolidate_prompt.ps1(幂等)
    $promptNow = Get-Content $promptFile -Raw -Encoding UTF8
    $blockCount = @(Select-String -Path $promptFile -Pattern '^# 自动优化追加的质量红线').Count
    if ($promptNow.Length -gt $ConsolidateThresholdChars -or $blockCount -gt $ConsolidateBlockThreshold) {
        Write-Log "CONSOLIDATE: trigger (chars $($promptNow.Length)/$ConsolidateThresholdChars, blocks $blockCount/$ConsolidateBlockThreshold) - running consolidate_prompt.ps1"
        $consolidateScript = Join-Path $LogDir "consolidate_prompt.ps1"
        if (Test-Path $consolidateScript) {
            $consOut = @(& $consolidateScript 2>&1)
            Write-Log "CONSOLIDATE: $($consOut -join ' | ')"
        } else {
            Write-Log "CONSOLIDATE: consolidate_prompt.ps1 not found, skipped"
        }
    }
}
Write-Log "AUTOOPT: applied from $($report[0].Name) (never+$($never.Count), redlines+$($redlines.Count))"
Write-Output "AUTOOPT-APPLIED: never+$($never.Count) redlines+$($redlines.Count)"
