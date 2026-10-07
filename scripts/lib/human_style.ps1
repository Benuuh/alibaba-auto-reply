# lib/human_style.ps1 - 采集"老板亲自说的话"(只读统计, 无副作用)
#
# 背景(spec 更像真人销售_20260926 §1.2): 实测全库 1812 条 [ME] 行**全部**带 @@TS,
#   说明它们全是机器人发出的; 人工在 OneTalk 里手打的消息**不带任何标记**(@@OT 只出现在 [BUYER] 行)。
#   ⇒ "人工消息" 可以被可靠识别 = [ME] 且不含 @@TS。
#   ⇒ 当前样本里这类消息为 0 条 —— 这是**正确结果**, 不是故障: 老板从未在监控范围内手回过。
#   本文件的用途: 先把采集通道建好, 等老板真的手回之后, 样本自然积累, 才能做"风格提取"正式版。
#
# 依赖: lib\msg_source.ps1 —— 来源判定**只允许**来自该文件(不得在本文件重写正则)。
#
# ⚠️ PII 纪律(spec §4-7): 本文件的返回值是"给本机分析用的对象", 其中 Text 含消息原文。
#   调用方**不得**把 Text 写进仓库、REPORT 或对老板的汇报; Get-HumanStyleStats 的输出
#   只含**聚合统计**(计数/词频/布尔分布)与**通用词块**, 不含买家名、不含整句原文。

# 去掉逐条标记(@@TS/@@MT/@@MID/@@OT/@@IMG/@@FILE/@@META/@@CARD), 得到可读文本
# [2026-10-07 spec §3.1 / 复核 R7] 旧实现漏了 @@MT 与 @@META，于是"采集到的人工原文"里
#   带着一整段 base64 元数据（统计出来的根本不是老板打的那句话）。
function Get-HumanMessageText([string]$line) {
    if (-not $line) { return '' }
    $t = $line
    $t = $t -replace '^\s*\[(ME|BUYER)\]\s*', ''
    $t = $t -replace '@@[A-Za-z]+:[^\s]*', ''
    return $t.Trim()
}

# 扫描快照目录, 返回所有"人工发出的"我方消息(依赖 msg_source.ps1 判定, 不自己写正则)
# 返回: 数组(可能为空), 元素 = @{ Buyer=<买家名>; Text=<原文>; File=<快照名>; Line=<行号>; Source=<词表值>; Evidence=<证据引用> }
# 注意: Buyer 字段属 PII, 仅供本机分析; 不要写入入库文件。
#
# [2026-10-07 spec §3.2 / 复核 R7] 判定来源只有一个：Get-MessageSource -> 共享四态判定。
#   这里**不再**把"没有 @@TS"当成人工；只有带出处的人工证据（已验证发送者字段或确切事件确认）
#   才会被采集。未知/平台/项目行一律不计入"老板手打"（宁可少采，不可把别人的话算成老板的）。
function Get-HumanMessages([string]$snapDir) {
    $out = @()
    if (-not $snapDir -or -not (Test-Path $snapDir)) { return @() }
    $files = @(Get-ChildItem (Join-Path $snapDir 'msgs_*.txt') -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $buyer = ''
        $ln = 0
        $lines = @(Get-Content $f.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
        foreach ($line in $lines) {
            $ln++
            if ($line -match '^#\s*BUYER:\s*(.+)$') { $buyer = $Matches[1].Trim(); continue }
            $cls = $null
            if (Get-Command Get-MessageSourceClass -ErrorAction SilentlyContinue) { $cls = Get-MessageSourceClass -line $line }
            $src = if ($cls) { [string]$cls.Class } else { '' }
            $legacy = Get-MessageSource $line
            $isHuman = ($src -eq 'human') -or ((-not $src) -and ($legacy -eq 'human'))
            if (-not $isHuman) { continue }
            $out += [pscustomobject]@{
                Buyer = $buyer
                Text  = (Get-HumanMessageText $line)
                File  = $f.Name
                Line  = $ln
                Source = $(if ($src) { $src } else { $legacy })
                Evidence = $(if ($cls) { [string]$cls.Evidence } else { 'legacy-human' })
            }
        }
    }
    return @($out)
}

# 词块归一化: 去标点/小写/压空白 —— 仅用于"开场/结尾 Top N"这类聚合统计
function Get-StyleToken([string]$text) {
    if (-not $text) { return '' }
    $t = $text.ToLower()
    $t = $t -replace '[^a-z0-9''\s]', ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# 风格统计(只读): 输出可读报告字符串数组; 0 样本时输出说明而**不是**抛异常
function Get-HumanStyleStats([string]$snapDir) {
    $msgs = @(Get-HumanMessages $snapDir)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('=== 人工消息风格统计(老板本人手打的消息) ===')
    [void]$lines.Add(("快照目录: {0}" -f $snapDir))
    [void]$lines.Add(("人工消息条数: {0}" -f $msgs.Count))

    if ($msgs.Count -eq 0) {
        [void]$lines.Add('')
        [void]$lines.Add('暂无人工作品样本(0 条)。')
        [void]$lines.Add('这**不是故障**: 实测机器人发出的消息一律带 @@TS 标记, 人工手打的不带任何标记;')
        [void]$lines.Add('当前 0 条说明老板还没有在监控范围内手回过买家。')
        [void]$lines.Add('采集通道已就绪 —— 老板在 OneTalk 里手回之后, 重跑本命令即可看到样本与风格。')
        return @($lines)
    }

    # 句数 / 词数
    $sentenceCounts = @()
    $wordCounts = @()
    $openers = @{}
    $closers = @{}
    $emojiMsgs = 0
    $contractionMsgs = 0
    $addrDear = 0; $addrHi = 0; $addrFriend = 0; $addrNone = 0
    $buyers = @{}
    foreach ($m in $msgs) {
        $buyers[$m.Buyer] = $true
        $txt = [string]$m.Text
        $sentences = @($txt -split '[.!?]+' | Where-Object { $_.Trim().Length -gt 0 })
        $sentenceCounts += $sentences.Count
        $words = @($txt -split '\s+' | Where-Object { $_ -match '[A-Za-z0-9]' })
        $wordCounts += $words.Count
        $tok = Get-StyleToken $txt
        if ($tok) {
            $tw = @($tok -split ' ')
            if ($tw.Count -gt 0) {
                $o = ($tw | Select-Object -First 2) -join ' '
                if (-not $openers.ContainsKey($o)) { $openers[$o] = 0 }
                $openers[$o]++
                $cl = ($tw | Select-Object -Last 2) -join ' '
                if (-not $closers.ContainsKey($cl)) { $closers[$cl] = 0 }
                $closers[$cl]++
            }
        }
        if ($txt -match '[\uD800-\uDBFF][\uDC00-\uDFFF]|[\u2190-\u2BFF\u2600-\u27BF]') { $emojiMsgs++ }
        if ($txt -match "(?i)\b(i'm|i'll|i've|we're|we'll|we've|don't|doesn't|can't|won't|it's|that's|you're)\b") { $contractionMsgs++ }
        if ($txt -match '(?i)^\s*dear\b') { $addrDear++ }
        elseif ($txt -match '(?i)^\s*(hi|hello|hey)\b') { $addrHi++ }
        elseif ($txt -match '(?i)my friend') { $addrFriend++ }
        else { $addrNone++ }
    }
    $avgSent = [Math]::Round((($sentenceCounts | Measure-Object -Average).Average), 2)
    $avgWord = [Math]::Round((($wordCounts | Measure-Object -Average).Average), 2)

    [void]$lines.Add(("涉及买家数: {0}" -f @($buyers.Keys).Count))
    [void]$lines.Add(("平均句数/条: {0}" -f $avgSent))
    [void]$lines.Add(("平均词数/条: {0}" -f $avgWord))
    [void]$lines.Add('')
    [void]$lines.Add(('开场说法 Top 5:'))
    foreach ($k in @($openers.Keys | Sort-Object { -$openers[$_] } | Select-Object -First 5)) {
        [void]$lines.Add(("  {0,4}x  {1}" -f $openers[$k], $k))
    }
    [void]$lines.Add(('结尾说法 Top 5:'))
    foreach ($k in @($closers.Keys | Sort-Object { -$closers[$_] } | Select-Object -First 5)) {
        [void]$lines.Add(("  {0,4}x  {1}" -f $closers[$k], $k))
    }
    [void]$lines.Add('')
    [void]$lines.Add(("用 emoji 的消息: {0}/{1}" -f $emojiMsgs, $msgs.Count))
    [void]$lines.Add(("用缩略语(I'll/we're 等)的消息: {0}/{1}" -f $contractionMsgs, $msgs.Count))
    [void]$lines.Add(('称呼方式分布:'))
    [void]$lines.Add(("  Dear X : {0}" -f $addrDear))
    [void]$lines.Add(("  Hi/Hello/Hey X : {0}" -f $addrHi))
    [void]$lines.Add(("  My friend : {0}" -f $addrFriend))
    [void]$lines.Add(("  无称呼 : {0}" -f $addrNone))
    return @($lines)
}
