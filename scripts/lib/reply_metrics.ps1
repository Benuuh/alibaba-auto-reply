# lib/reply_metrics.ps1 - 质量报告新增指标(只读, 无副作用)
#
# 背景(spec 更像真人销售_20260926 S8): 旧评分只考"话说得漂不漂亮"
#   (负面 -3 / 重复提问 -2 / 新信息 +2 / 实质互动 +1), 不考"有没有推进"。
#   本文件**只新增**指标计算, 不改动任何既有分值项的语义(否则历史报告不可比)。
#
# 依赖: lib\goods.ps1(可报价买家数)、lib\msg_source.ps1 -> lib\msg_events.ps1(消息来源四态)、
#       lib\sent_records.ps1(已确认发送记录，用于把"我方真实发出"的行识别为 project)。
# 契约: 本文件所有函数**只读**, 不写任何状态文件; 出错一律返回 0 / 空, 不得让调用方崩掉。

# [2026-10-07 spec §3.2 / 复核 R7] 逐行来源：**统一委托共享判定**；给出 -Buyer 时再用
#   已确认发送记录把我们的真实发送识别为 project。
#   为什么需要 -Buyer：收据匹配是"同一条已确认发送 + 同一 buyer"的函数；没有 buyer 时只能依赖
#   已验证的来源字段/标签 —— 历史 [ME] 行会（正确地）保持 unknown，而不是被当成我方。
function Get-SnapshotLineSources {
    param([string]$snapshotContent, [string]$Buyer = '')
    $out = New-Object System.Collections.ArrayList
    if (-not $snapshotContent) { return @() }
    $lines = @($snapshotContent -split "`n")
    $sent = @{}
    if ($Buyer -and (Get-Command Get-SentRecordMatchIndexes -ErrorAction SilentlyContinue)) {
        try { $sent = Get-SentRecordMatchIndexes -Buyer $Buyer -Lines $lines } catch { $sent = @{} }
    }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        $class = 'unknown'
        $evidence = 'legacy-word-list'
        if (Get-Command Get-MessageSourceClass -ErrorAction SilentlyContinue) {
            $match = ($sent.ContainsKey($i) -and [bool]$sent[$i])
            $cls = Get-MessageSourceClass -line $line -SentRecordMatch $match
            $class = [string]$cls.Class
            $evidence = [string]$cls.Evidence
        } else {
            switch (Get-MessageSource $line) {
                'buyer'   { $class = 'buyer' }
                'human'   { $class = 'human' }
                'bot'     { $class = 'project' }
                default   { $class = 'unknown' }
            }
        }
        [void]$out.Add([pscustomobject]@{ Index = $i; Line = $line; Source = $class; Evidence = $evidence })
    }
    return @($out.ToArray())
}

# 安抚式等待语(D6/S7 的频率限制对象): 对同一买家整个对话最多 1 次
function Get-SoothingPhrasePatterns {
    return @('take your time', 'no rush', 'whenever you are ready', "whenever you're ready",
             'just let me know', 'happy to wait', 'no worries at all')
}

# 从快照全文里统计"安抚语重复"(同一会话同一句出现 >= 2 次即计一次违规)
# 返回: @{ Repeats = <int>; MaxSameCount = <int> }
# [2026-10-07 spec §3.2 / 复核 R7] 口径变更（**收紧**）：只有**已被证明是我方**（project，旧词表 'bot'）
#   的行才计入"我方安抚语重复"。平台自动回复（platform）、人工（human）与无发送者证据（unknown）
#   一律不计入 —— 旧实现只跳过 buyer，等于把平台/人工/未知行都算成我方话术。
#   同时把分类计数一并返回（UnprovenLines 等），报告能看见"有多少行因为缺证据没有计入"，
#   而不是静默变成 0。调用方仍按 Repeats / MaxSameCount 取值。
function Get-SoothingPhraseRepeatStats([string]$snapshotContent, [string]$Buyer = '') {
    $res = @{ Repeats = 0; MaxSameCount = 0; ProvenOurLines = 0; UnprovenOurLines = 0; PlatformLines = 0; HumanLines = 0; BuyerLines = 0 }
    if (-not $snapshotContent) { return $res }
    $pats = Get-SoothingPhrasePatterns
    $counts = @{}
    foreach ($lineInfo in @(Get-SnapshotLineSources -snapshotContent $snapshotContent -Buyer $Buyer)) {
        $line = [string]$lineInfo.Line
        # 注意：PowerShell 的 switch 自带循环语义，其中的 continue 只会结束 switch 而不是外层 foreach，
        #   所以必须用 if/elseif 把"跳过非我方行"表达清楚（否则未知行会照旧被计入）。
        $source = [string]$lineInfo.Source
        if ($source -eq 'buyer') { $res.BuyerLines++; continue }
        if ($source -eq 'human') { $res.HumanLines++; continue }
        if ($source -eq 'platform') { $res.PlatformLines++; continue }
        if ($source -eq 'noise') { continue }
        if ($source -ne 'project') { if (-not [string]::IsNullOrWhiteSpace($line)) { $res.UnprovenOurLines++ }; continue }
        $res.ProvenOurLines++
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
#
# [2026-10-07 spec §3.2 / 复核 R7] 旧实现把"带 @@TS 的我方行"判为 bot，于是平台自动回复也会被算成
#   "我方说了这句话"。现在只认**已被证明是我方**（project / 旧词表 'bot'）的行；
#   platform（平台自动回复）与 unknown（无发送者证据，含历史无收据记录）都不算。
#   需要明细时用 Get-DimensionGuidanceEvidence（返回命中行与分类计数），本函数只给布尔结论。
function Get-DimensionGuidanceEvidence([string]$snapshotContent, [string]$Buyer = '') {
    $res = [pscustomobject]@{ Hit = $false; Line = ''; Source = ''; Evidence = ''; UnprovenOurLines = 0; PlatformLines = 0 }
    if (-not $snapshotContent) { return $res }
    foreach ($lineInfo in @(Get-SnapshotLineSources -snapshotContent $snapshotContent -Buyer $Buyer)) {
        $line = [string]$lineInfo.Line
        if ([string]$lineInfo.Source -eq 'platform') { $res.PlatformLines++; continue }
        if ([string]$lineInfo.Source -ne 'project') { if (-not [string]::IsNullOrWhiteSpace($line)) { $res.UnprovenOurLines++ }; continue }
        foreach ($p in @(Get-DimensionGuidancePatterns)) {
            if ($line -match $p) { $res.Hit = $true; $res.Line = $line; $res.Source = [string]$lineInfo.Source; $res.Evidence = [string]$lineInfo.Evidence; return $res }
        }
    }
    return $res
}

function Get-DimensionGuidancePatterns {
    return @(
        "supplier's contact",
        "packing list",
        'confirm the cargo details with them directly',
        'rough size is fine',
        'carton sizes',
        '\bL\s*[*x×]\s*W\s*[*x×]\s*H\b'
    )
}

function Test-DimensionGuidanceHit([string]$snapshotContent, [string]$Buyer = '') {
    return [bool](Get-DimensionGuidanceEvidence -snapshotContent $snapshotContent -Buyer $Buyer).Hit
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

# 安全取字段值：goods 状态是**哈希表**，PS 5.1 下哈希表的 PSObject.Properties 只暴露
#   IsReadOnly/Keys/Values/Count 等 CLR 成员，"-contains 'ready'" 与 "$g.ready" 都会静默拿到
#   $null（这正是"报告说 0 个可报价买家"的成因）。统一走 Contains/Properties 两条路。
function Get-MetricValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

# 可报价买家数 —— [2026-10-05 spec §4.2 第 1/2 条] 消费唯一判据 Get-QuoteReadiness
#   （经 goods.ps1 的适配器取回 ready），不再用"重量 + 尺寸 + 地址"三个布尔值自行判定。
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
            if ([bool](Get-MetricValue $g 'ready')) { $n++ }
        }
    } catch {
        return 0
    }
    return $n
}
