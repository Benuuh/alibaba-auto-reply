# Prompt 红线归档合并:把 auto_optimize 追加的多段"自动优化追加的质量红线"合并去重为一段归档节。
# 防 prompt 无限膨胀(8 段重叠内容会稀释 LLM 注意力、增加 token 成本)。
# 用法: consolidate_prompt.ps1 [-DryRun]
param(
    [switch]$DryRun,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$promptFile = Join-Path $LogDir "reply_agent_prompt.md"
if (-not (Test-Path $promptFile)) { Write-Output "CONSOLIDATE-NO-FILE"; exit 0 }

$raw = Get-Content $promptFile -Raw -Encoding UTF8
$lines = @($raw -split "`r?`n")

# 定位所有自动优化段落起始行
$autoIdx = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^# 自动优化追加的质量红线') { $autoIdx += $i }
}
if ($autoIdx.Count -eq 0) { Write-Output "CONSOLIDATE-NOTHING"; exit 0 }

# 提取各段中的红线条目
$redlines = New-Object System.Collections.ArrayList
foreach ($i in $autoIdx) {
    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^#') { break }
        if ($lines[$j] -match '^- (.+)') { [void]$redlines.Add($Matches[1].Trim()) }
    }
}

# 精确去重(小写归一)
$seen = @{}; $dedup = @()
foreach ($r in $redlines) {
    $k = $r.ToLowerInvariant()
    if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $dedup += $r }
}

# 组装:核心正文(首个自动优化段之前) + 归档节
$core = @($lines[0..($autoIdx[0] - 1)])
$archived = @(
    "",
    "# 历史红线归档($(Get-Date -Format 'yyyy-MM-dd'))",
    "# 以下红线由 auto_optimize 自动追加,consolidate_prompt 合并去重(原始 $($redlines.Count) 条 -> 去重 $($dedup.Count) 条):"
)
foreach ($r in $dedup) { $archived += "- $r" }
$newText = (($core + $archived) -join "`r`n") + "`r`n"

if ($DryRun) {
    Write-Output "CONSOLIDATE-DRYRUN: lines $($lines.Count) -> $($core.Count + $archived.Count), redlines $($redlines.Count) -> $($dedup.Count), size $($raw.Length) -> $($newText.Length) chars"
    Write-Output "--- 归档节预览(前 8 条) ---"
    $archived | Select-Object -First 8 | ForEach-Object { Write-Output $_ }
    exit 0
}

Copy-Item $promptFile "$promptFile.pre" -Force
$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($promptFile, $newText, $enc)
Write-Output "CONSOLIDATE-DONE: $($dedup.Count) redlines archived, size $($raw.Length) -> $($newText.Length) chars (backup: reply_agent_prompt.md.pre)"
