param(
    [string]$LogDir = "",
    [string]$OutDir = "",
    [int]$LookbackHours = 48,
    [switch]$ApplyNever
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\msg_source.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
. (Join-Path $PSScriptRoot "lib\reply_metrics.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
if (-not $OutDir) { $OutDir = Get-SkillPath "reports" }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $LogDir -Parent) "reports" }

# 规则（勿含"你们"等翻译高频词，会误报）
$negPattern    = '不(懂|会|明白)|看不懂|听不懂|算了吧|算了|别再|别再说|stupid|annoying|angry|frustrat|terrible|horrible|worst|disappoint|you don''t (understand|read|listen)|are you (stupid|kidding|a robot)|give up|never mind|forget it|无语|服了|太离谱|受不了'
$infoPattern   = '\d+\s*(kg|kgs|kilo|kilos)|\d+\s*[x×*]\s*\d+|\d+\s*(cm|mm|m\b)|address|street|road|avenue|code postal|zip|c?ep\b|deliver|城市|地址|邮编|image|photo|pic|picture|foto|imagen|图片|图\b'
$ackPattern    = '^(ok|okay|okey|yes|yeah|yep|yup|sure|fine|perfect|great|nice|good|thanks|thank you|thx|gracias|obrigad|merci|👍|👌|🙏)\s*[.!]*$'
$questionWords = @('weight', 'dimension', 'address', 'image', 'photo', 'picture', 'supplier', 'contact', 'kg')

# 从 monitor.log 构建"秒级时间戳 -> 买家名"映射（PROCESS 行），供旧快照回退匹配
$map = @{}
Get-Content (Join-Path (Get-SkillPath "logs") "monitor.log") -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| PROCESS convo from pending-list: ([^|]+)') {
        $map[([datetime]::ParseExact($Matches[1], "yyyy-MM-dd HH:mm:ss", $null)).ToString("yyyyMMddHHmmss")] = $Matches[2].Trim()
    }
}

# 找时间差最小且 <25s 的 PROCESS 记录（快照写入在打开会话后 2~20 秒）
function Find-Buyer([string]$snapTime) {
    $snapDt = [datetime]::ParseExact($snapTime, "yyyyMMdd_HHmmss", $null)
    $best = $null; $bestDiff = 25
    foreach ($k in $map.Keys) {
        $kt = [datetime]::ParseExact($k, "yyyyMMddHHmmss", $null)
        $diff = [Math]::Abs(($snapDt - $kt).TotalSeconds)
        if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $map[$k] }
    }
    return $best
}

# 分析单个快照，返回 负面行/重复提问/新信息/评分
function Analyze-Snapshot([string]$content) {
    $lines = @($content -split "`n") | Where-Object { $_ -match '^\[(BUYER|ME)\]' -and $_ -notmatch '自动接待' }
    if ($lines.Count -lt 2) { return $null }
    $neg = ''; $newInfo = $false; $ackOnly = $true; $dup = $false
    $buyerCount = 0; $lastMe = ''; $asked = @{}
    # A3 证据化:记录重复提问的具体问句(字段 -> 问句列表)
    $askedEvidence = @{}
    foreach ($l in $lines) {
        if ($l -match '^\[BUYER\] (.*)$') {
            $txt = $Matches[1]; $buyerCount++
            if ($txt -match $negPattern) { $neg = $txt }
            if ($txt -match $infoPattern) { $newInfo = $true }
            if ($txt -notmatch $ackPattern -and $txt -notmatch '\[IMG\]' -and $txt.Trim().Length -gt 2) { $ackOnly = $false }
        } elseif ($l -match '^\[ME\] (.*)$') {
            $txt = $Matches[1]; $lastMe = $txt
            # 只统计"问句"（以 ?/?/？ 结尾）中的问题词，避免把"20kg 已确认"这类确认句误判为重复提问
            if ($txt -match '[\?？]') {
                foreach ($w in $questionWords) {
                    if ($txt.ToLower() -match $w) {
                        $asked[$w] = ([int]$asked[$w]) + 1
                        if (-not $askedEvidence.ContainsKey($w)) { $askedEvidence[$w] = New-Object System.Collections.ArrayList }
                        $short = $txt.Substring(0, [Math]::Min(60, $txt.Length))
                        [void]$askedEvidence[$w].Add($short)
                    }
                }
            }
        }
    }
    $dupEvidence = ''
    foreach ($v in $asked.Values) { if ($v -ge 2) { $dup = $true; break } }
    if ($dup) {
        $ev = @()
        foreach ($w in $askedEvidence.Keys) { if ($asked[$w] -ge 2) { $ev += ("$w x$($asked[$w]): " + ($askedEvidence[$w] -join ' / ')) } }
        $dupEvidence = ($ev -join '; ')
    }
    $score = 0
    if ($neg) { $score -= 3 }
    if ($dup) { $score -= 2 }
    if ($newInfo) { $score += 2 }
    if ($buyerCount -gt 2 -and -not $ackOnly) { $score += 1 }
    return [pscustomobject]@{ neg = $neg; newInfo = $newInfo; dup = $dup; dupEvidence = $dupEvidence; score = $score; lastMe = $lastMe }
}

$cutoff = (Get-Date).AddHours(-$LookbackHours)
$perBuyer = @{}; $negCases = @()
foreach ($f in (Get-ChildItem -Path (Get-SkillPath "data") -Filter "msgs_*.txt" | Where-Object { $_.LastWriteTime -gt $cutoff })) {
    $content = Get-Content $f.FullName -Raw -Encoding UTF8
    $buyer = ($content -split "`n" | Select-Object -First 1).Trim()
    if ($buyer -match '^# BUYER: (.+)$') {
        $buyer = $Matches[1].Trim()
    } else {
        $m = [regex]::Match($f.BaseName, '\d{8}_\d{6}')
        if (-not $m.Success) { continue }
        $buyer = Find-Buyer $m.Value
        if (-not $buyer) { continue }
    }
    $a = Analyze-Snapshot $content
    if (-not $a) { continue }
    # [S8 只加不改] 新增指标:与本轮快照同源计算, 不改动 Analyze-Snapshot 的任何既有分值语义
    $sp = Get-SoothingPhraseRepeatStats $content
    $m = @{ soothingRepeats = $sp.Repeats; soothingMax = $sp.MaxSameCount
            dimGuide = (Test-DimensionGuidanceHit $content) }
    if (-not $perBuyer.ContainsKey($buyer)) { $perBuyer[$buyer] = @() }
    $perBuyer[$buyer] += [pscustomobject]@{ time = $f.LastWriteTime; a = $a; file = $f.Name; m = $m }
    if ($a.neg) { $negCases += [pscustomobject]@{ buyer = $buyer; time = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"); line = $a.neg; me = $a.lastMe; file = $f.Name } }
}

if ($perBuyer.Count -eq 0) { Write-Output "no snapshots in last $LookbackHours hours"; exit 0 }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outFile = Join-Path $OutDir ("quality_" + (Get-Date -Format "yyyyMMdd_HHmm") + ".md")

$rows = $perBuyer.Keys | Sort-Object | ForEach-Object {
    $last = $perBuyer[$_][-1]
    $flag = if ($last.a.neg) { "⚠️ $($last.a.neg.Substring(0, [Math]::Min(30, $last.a.neg.Length)))" } else { "-" }
    # A3 证据化:重复提问附具体问句(截断 80 字符)
    $dup  = if ($last.a.dup) { "⚠️ 重复提问: $($last.a.dupEvidence.Substring(0, [Math]::Min(80, $last.a.dupEvidence.Length)))" } else { "-" }
    $info = if ($last.a.newInfo) { "✅" } else { "-" }
    "| $_ | $($perBuyer[$_].Count) | $($last.a.score) | $flag | $dup | $info |"
}
$worst = $perBuyer.GetEnumerator() | Sort-Object { $_.Value[-1].a.score } | Select-Object -First 1

# ===== [S8 新增] 推进类指标(独立成节, 不改动上方旧 4 项分值的任何语义) =====
# 为什么加: 旧评分只考"话说得漂不漂亮", 不考"有没有推进" —— 无法分辨"正常等待"与"卡死"。
$newRows = $perBuyer.Keys | Sort-Object | ForEach-Object {
    $last = $perBuyer[$_][-1]
    $mm = $last.m
    $snd = if ($mm -and $mm.soothingRepeats -gt 0) { "⚠️ $($mm.soothingRepeats) 处(同句最多 $($mm.soothingMax) 次)" } else { "-" }
    $dg = if ($mm -and $mm.dimGuide) { "✅" } else { "-" }
    "| $_ | $snd | $dg |"
}
$soothingViolators = @($perBuyer.Keys | Where-Object { $perBuyer[$_][-1].m -and $perBuyer[$_][-1].m.soothingRepeats -gt 0 }).Count
$dimGuideBuyers = @($perBuyer.Keys | Where-Object { $perBuyer[$_][-1].m -and $perBuyer[$_][-1].m.dimGuide }).Count
$monLog = Join-Path (Get-SkillPath "logs") "monitor.log"
$hjStat = Get-HumanInterjectionCount $monLog 20000
$quotable = 0
try { $quotable = Get-QuotableBuyerCount (Get-SkillPath "data") } catch { $quotable = 0 }

$negBlock = if ($negCases.Count) { $negCases | ForEach-Object {
    "- **$($_.buyer)** ($($_.time)): $($_.line)"
    "  - 我方上轮回复: $($_.me.Substring(0, [Math]::Min(80, $_.me.Length)))"
    "  - 快照: $($_.file)"
} } else { "无。" }

$lines = @(
    "# 自动回复质量报告", "",
    "- **统计时段**: 最近 $LookbackHours 小时",
    "- **生成时间**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")",
    "- **涉及买家**: $($perBuyer.Count) 位", "",
    "| 买家 | 快照数 | 评分 | 负面 | 重复提问 | 新信息推进 |",
    "|------|--------|------|------|----------|------------|",
    ($rows -join "`n"), "",
    "## 负面案例", "", ($negBlock -join "`n"), "",
    "## 风险会话 Top1", "",
    "- **$($worst.Key)** 评分 $($worst.Value[-1].a.score)，最近快照 $($worst.Value[-1].file)",
    "- 建议人工查看该会话，必要时在 reply_rules.json 增加规则", "",
    "---", "质量评分说明: 负面 -3 / 重复提问 -2 / 新信息 +2 / 实质互动 +1",
    "",
    "## 推进类指标（2026-09-26 新增，独立成列；上方 4 项分值语义未变，历史报告仍可比）", "",
    "- **human_interjection 次数（人工插话让路）**: $($hjStat.Count)（扫描 monitor.log 末 $($hjStat.TailLines) 行，实际读到 $($hjStat.Scanned) 行）",
    "  - 含义：老板亲自回过之后，机器人让路不再插话的次数（S2 防抢话）。",
    "  - 注意：此数只覆盖日志**尾部**，不是全历史累计。",
    "- **尺寸引导使用次数（有会话命中）**: $($dimGuideBuyers) / $($perBuyer.Count)",
    "  - 含义：我方消息里出现了「引导买家给尺寸/给供应商联系方式」成品话术的会话数。",
    "- **安抚语重复次数（>1 即计违规）**: $($soothingViolators) 个会话",
    "  - 含义：同一会话里同一句安抚式等待语（take your time / no rush 等）出现 ≥ 2 次；D6/S7 规定对同一买家最多 1 次。",
    "- **可报价买家数（重量+尺寸+地址三项齐全）**: $($quotable)",
    "  - 含义：达到「资料齐可报价」门槛的买家数（复用 lib\goods.ps1::Get-GoodsDataStatus，键名小写）。", "",
    "| 买家 | 安抚语重复 | 尺寸引导 |",
    "|------|-----------|---------|",
    ($newRows -join "`n")
)
$lines -join "`n" | Set-Content -Path $outFile -Encoding UTF8
Write-Output "quality report: $outFile"

# A 包: 报告生成后自动推企微摘要(失败只记日志, 不影响报告任务退出码)
try { . (Join-Path $PSScriptRoot "lib\report_push.ps1"); Send-ReportWecomSummary $outFile 'quality' | Out-Null } catch {}

# Negative-case rules become SUGGESTIONS (spec 5 2026-10-03), never a direct corpus edit.
# This was the SECOND auto-append path: with -ApplyNever it wrote straight into
# reply_rules.reply_rules.never, bypassing review exactly like the old auto_optimize did. Both paths
# now funnel into <data_dir>\suggestions\ and require a human accept plus an explicit apply.
if ($ApplyNever -and $negCases.Count -gt 0) {
    . (Join-Path $PSScriptRoot "lib\suggestions.ps1")
    $dataDir = Get-SkillPath "data"
    $rulesFile = Join-Path $LogDir "reply_rules.json"
    $baseHash = Get-FileSha256 $rulesFile
    $added = 0
    foreach ($c in $negCases) {
        $rule = $null
        if ($c.line.ToLower() -match 'read|看懂|听|understand') { $rule = "If the buyer is frustrated that we misread details, apologize briefly and re-confirm only the disputed point - never re-ask for information already provided" }
        elseif ($c.line.ToLower() -match 'repeat|重复|same question') { $rule = "Never ask the same question twice - if already answered, acknowledge and move forward" }
        elseif ($c.line.ToLower() -match 'price|quote|报价|贵') { $rule = "Never appear evasive about pricing - give the billing rule and request missing data in one short message" }
        if (-not $rule) { continue }
        $res = Add-Suggestion -DataDir $dataDir -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed $rule -Title "Quality-report negative case" -Evidence ("negative case detected by analyze_replies in " + (Split-Path $outFile -Leaf)) -ExpectedImpact "reduces the repeated negative pattern" -BaseHash $baseHash
        if ($res.Refused) { Write-Output ("SUGGESTION REFUSED (hard constraint): " + $rule); continue }
        if ($res.Created) { Write-Output ("SUGGESTION ADDED " + $res.Id + ": " + $rule); $added++ }
        elseif ($res.Merged) { Write-Output ("SUGGESTION MERGED " + $res.Id + " (status=" + $res.Status + ")") }
    }
    Write-Output ("suggestions written: " + $added + " (review with review_suggestions.ps1; nothing was applied)")
    Write-Output "reply_rules.json was NOT modified by this run"
}
