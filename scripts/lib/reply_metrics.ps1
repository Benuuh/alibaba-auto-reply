# lib/reply_metrics.ps1 - 质量报告新增指标(只读, 无副作用)
#
# 背景(spec 更像真人销售_20260926 S8): 旧评分只考"话说得漂不漂亮"
#   (负面 -3 / 重复提问 -2 / 新信息 +2 / 实质互动 +1), 不考"有没有推进"。
#   本文件**只新增**指标计算, 不改动任何既有分值项的语义(否则历史报告不可比)。
#
# 依赖: lib\goods.ps1(可报价买家数)、lib\msg_source.ps1(消息来源)。
# 契约: 本文件所有函数**只读**, 不写任何状态文件; 出错一律返回 0 / 空, 不得让调用方崩掉。

# 安抚式等待语(D6/S7 的频率限制对象): 对同一买家整个对话最多 1 次
function Get-SoothingPhrasePatterns {
    return @('take your time', 'no rush', 'whenever you are ready', "whenever you're ready",
             'just let me know', 'happy to wait', 'no worries at all')
}

# 从快照全文里统计"安抚语重复"(同一会话同一句出现 >= 2 次即计一次违规)
# 返回: @{ Repeats = <int>; MaxSameCount = <int> }
function Get-SoothingPhraseRepeatStats([string]$snapshotContent) {
    $res = @{ Repeats = 0; MaxSameCount = 0 }
    if (-not $snapshotContent) { return $res }
    $pats = Get-SoothingPhrasePatterns
    $counts = @{}
    foreach ($line in @($snapshotContent -split "`n")) {
        if ((Get-MessageSource $line) -eq 'buyer') { continue }
        $low = $line.ToLower()
        foreach ($p in $pats) {
            if ($low.Contains($p)) {
                if (-not $counts.ContainsKey($p)) { $counts[$p] = 0 }
                $counts[$p]++
            }
        }
    }
    foreach ($k in $counts.Keys) {
        if ($counts[$k] -gt $res.MaxSameCount) { $res.MaxSameCount = $counts[$k] }
        if ($counts[$k] -ge 2) { $res.Repeats++ }
    }
    return $res
}

# 尺寸引导命中: 我方消息里是否出现了"引导买家给尺寸/给供应商联系方式"的成品话术
function Test-DimensionGuidanceHit([string]$snapshotContent) {
    if (-not $snapshotContent) { return $false }
    $pats = @(
        "supplier's contact",
        "packing list",
        'confirm the cargo details with them directly',
        'rough size is fine',
        'carton sizes',
        '\bL\s*[*x×]\s*W\s*[*x×]\s*H\b'
    )
    foreach ($line in @($snapshotContent -split "`n")) {
        if ((Get-MessageSource $line) -ne 'bot') { continue }
        foreach ($p in $pats) { if ($line -match $p) { return $true } }
    }
    return $false
}

# human_interjection 次数(S2 产生的日志计数)
# ⚠️ 禁止整文件读 monitor.log(spec §4-2: Add-Content + ErrorActionPreference=Stop 并发整读会让 monitor 抛
#    IOException 直接退出)。一律用 -Tail, 并且只统计**本文件尾部** —— 返回值是"最近 N 行内的次数",
#    不是全历史次数(报告里必须写明这一点, 否则会被误读)。
function Get-HumanInterjectionCount([string]$logFile, [int]$TailLines = 20000) {
    $res = @{ Count = 0; TailLines = $TailLines; Scanned = 0 }
    if (-not $logFile -or -not (Test-Path $logFile)) { return $res }
    try {
        $tail = @(Get-Content $logFile -Tail $TailLines -ErrorAction Stop)
        $res.Scanned = $tail.Count
        $res.Count = @($tail | Where-Object { $_ -match 'HUMAN-REPLIED-SKIP' }).Count
    } catch {
        $res.Count = 0
    }
    return $res
}

# 可报价买家数(重量+尺寸+地址三项齐全) —— 复用 lib\goods.ps1, 注意其返回键名为**小写**
function Get-QuotableBuyerCount([string]$dataDir) {
    $n = 0
    try {
        $names = @{}
        Get-ChildItem (Join-Path $dataDir 'msgs_*.txt') -ErrorAction SilentlyContinue | ForEach-Object {
            $first = Get-Content $_.FullName -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -and $first.StartsWith('# BUYER: ')) { $names[$first.Substring(9).Trim()] = $true }
        }
        foreach ($k in $names.Keys) {
            $g = Get-GoodsDataStatus $k $dataDir
            if ($g -and $g.weight -and $g.dims -and $g.addr) { $n++ }
        }
    } catch {
        return 0
    }
    return $n
}
