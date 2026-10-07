# lib/msg_source.ps1 - 消息来源判定(纯函数, 无副作用, 便于单测)
# 背景: 快照里机器人发出的消息带 @@TS 标记, 人工在 OneTalk 手打的消息不带任何标记。
#   实测(2026-09-26): 全库 1812 条 [ME] 行全部带 @@TS; @@OT 只出现在 [BUYER] 行(804/1509)。
#   标记由 monitor.ps1::Open-ConvoAndGetMessages 的页面 JS 产出:
#     '[ME] ' + 文本 + (有 ts 时 ' @@TS:' + ts)   —— @@TS 是机器人消息的可靠伴随标记。
# 契约: 本文件是"消息来源"的唯一判定处; 其他文件不得再自行写正则判断来源。
# 依赖: 无(不 dot-source 任何文件), 可被测试与 monitor 各自独立加载。

# 旧词表映射（兼容既有消费者）：四态/买方/噪声 -> 'buyer' | 'bot' | 'human' | 'platform' | 'unknown'
#   * project（已确认收据 / 已确认本项目发送者证据）= 旧词表的 'bot'（我方自动发送）；
#   * platform 单独保留：它是**平台**发的，不是我方，不能冒充 'bot' 让我方消费者认领；
#   * noise（flow 卡 / 总结卡）与无角色行 => 'unknown'。
function ConvertTo-LegacyMessageSource([string]$Class) {
    switch ([string]$Class) {
        'buyer'    { return 'buyer' }
        'human'    { return 'human' }
        'project'  { return 'bot' }
        'bot'      { return 'bot' }
        'platform' { return 'platform' }
        default    { return 'unknown' }
    }
}

# 单行判定: 返回 'buyer' | 'bot' | 'human' | 'platform' | 'unknown'
#
# [2026-10-07 spec §3.2 第 3 条 / 复核 R7] 这是**旧入口**，现在同样委托共享判定：
#   * 共享判定库（lib\msg_events.ps1）在时一律委托，"有时间就是 bot、无标记就是人工"的旁路被移除；
#   * 共享判定库不可用时（只加载本文件的单元测试）走保守阶梯：买方角色标记 => buyer，
#     其余一律 unknown —— 仍然不猜发送者。
function Get-MessageSource([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return 'unknown' }
    if (Get-Command Get-MessageSourceClassForLine -ErrorAction SilentlyContinue) {
        $cls = Get-MessageSourceClassForLine -Line $line
        return (ConvertTo-LegacyMessageSource ([string]$cls.Class))
    }
    if ($line -match '^\[BUYER\]') { return 'buyer' }
    return 'unknown'
}

# 消费者专用：这条行是否**已被证明是我方**（project）——用于"只看我方成品话术"的统计口径。
#   platform（平台自动回复）/ human / unknown 都不是"我方"。
function Test-MessageSourceIsProject([string]$line) {
    return ((Get-MessageSource $line) -eq 'bot')
}

# 判断"最近一条我方消息是否人工发出"(用于防抢话)。
# [复核 R7] 注意：本函数依赖 Get-MessageSource，而后者现在委托共享判定 ⇒ 只有**有出处的人工证据**
#   （已验证发送者字段 / 绑定确切事件的人工确认）才会得到 'human'；
#   带时间戳的老 [ME] 行、以及无任何证据的 [ME] 行都是 'unknown'，不再各自外推。
# 语义: 只考察"我方尾部"—— 从最新一行往上扫, 一旦遇到买家发言即停(买家发言之后的我方消息才是"抢话"的证据)。
#   我方尾部第一条我方消息是 'human' ⇒ HasHumanLast=$true (应跳过自动发送)。
#   是 'bot' ⇒ HasHumanLast=$false, LastMeSource='bot' (可正常发送)。
#   完全没有我方消息(我方尾部为空) ⇒ HasHumanLast=$false, LastMeSource='' (新询盘, 可发送)。
# 返回: @{ HasHumanLast = <bool>; HumanIndex = <int>; LastMeSource = <string> }
#   方向: 宁可少发, 不可抢话 —— 判据不确定时偏向不发(见 spec §4-15)。
function Test-HumanInterjection([string[]]$lines) {
    $r = @{ HasHumanLast = $false; HumanIndex = -1; LastMeSource = '' }
    if (-not $lines -or $lines.Count -eq 0) { return $r }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $src = Get-MessageSource $lines[$i]
        if ($src -eq 'buyer') { break }          # 往上遇到买家发言即停(只看"我方尾部")
        if ($src -eq 'human') {
            # 我方尾部第一条我方消息 = 人工 ⇒ 机器人不得插话
            $r.HasHumanLast = $true
            $r.HumanIndex = $i
            $r.LastMeSource = 'human'
            return $r
        }
        if ($src -eq 'bot') {
            $r.LastMeSource = 'bot'
            return $r
        }
        # 'unknown'(空行/UI 噪声行): 继续往上扫, 不当作任何一方(保守: 不因噪声行漏判人工消息)
    }
    return $r
}

# 发送闸门判定(纯函数, 无副作用): 把"消息行"直接映射为"本轮该不该自动发送"。
# 这是 monitor.ps1 防抢话闸门**实际调用**的同一函数(测试与线上共用一份逻辑, 避免判定漂移)。
# 返回: @{ Action = 'SKIP' | 'SEND'; Reason = <string>; HasHumanLast = <bool>; HumanIndex = <int>; LastMeSource = <string> }
#   'SKIP' + Reason='human-last'  ⇒ 人工已回应, 本轮不自动发送(spec §6-S2)
function Get-HumanInterjectionGate([string[]]$lines) {
    $r = Test-HumanInterjection $lines
    if ($r.HasHumanLast) {
        return @{ Action = 'SKIP'; Reason = 'human-last'; HasHumanLast = $true; HumanIndex = $r.HumanIndex; LastMeSource = $r.LastMeSource }
    }
    $reason = 'no-me-tail'
    if ($r.LastMeSource -eq 'bot') { $reason = 'bot-last' }
    return @{ Action = 'SEND'; Reason = $reason; HasHumanLast = $false; HumanIndex = $r.HumanIndex; LastMeSource = $r.LastMeSource }
}
# =============================================================================================
# [2026-10-05 spec §2.2] 证据化的消息来源判定
#
# 为什么要改：旧判据把"@@TS 存在"当作"这条是我们机器人发的"。时间字段只能证明页面给了这条消息
#   一个时间，不能独立证明发送者身份。新判据按证据分级：
#     1) 显式发送者标记（页面/API 给出的 @@SRC:bot|human）—— 最高等级证据；
#     2) 本系统**已确认发送记录**（发送成功后落盘的 send receipt）；
#     3) 既无发送记录、也没有任何逐条时间 ⇒ 人工手打（这是本机实测的既有形态，保留但不外推）；
#     4) 只有时间字段、没有前两类证据 ⇒ **unknown**：既不当作机器人，也不当作人工。
#
# 未知来源的处置（spec §2.2 要求独立设计）：
#   - 不把 unknown 当作"一条新的人工回复"（不因此开始/延长人工暂停）；
#   - 我方尾部最新一条是 unknown 时，发送闸门按"抢话风险不明"处理 ⇒ 不自动发送并留日志，
#     由人工核对（对话里最新一条既然是我方，买家当前诉求通常已被答复，代价可控）。
# =============================================================================================

# 稳定的行指纹（跨进程一致，用于人工消息身份去重）。本文件保持"无依赖"契约，自带 SHA1。
function Get-MessageLineFingerprint([string]$Line) {
    if ([string]::IsNullOrEmpty($Line)) { return '' }
    try {
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Line)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
    } catch { return ([string]$Line.Length).ToString() }
}

# 单行来源分级。返回 @{ Class = 'buyer'|'platform'|'project'|'human'|'unknown'|'noise'; Evidence; ... }
#
# [2026-10-07 spec §3.2 第 3 条] 这是**旧入口的委托点**：只要共享判定库（lib\msg_events.ps1）已加载，
#   一律委托 Get-MessageSourceClassForLine，本文件内不再保留自己的来源阶梯。
#   只有共享判定库不可用时（单文件测试）才走下面的保守阶梯，且该阶梯已按新规则收紧。
function Get-MessageSourceClass([string]$line, [bool]$SentRecordMatch = $false, $Rules = $null, $Confirmed = $null, [string]$Buyer = '') {
    if (-not $line) { return @{ Class = 'unknown'; Evidence = 'empty-line' } }
    if (Get-Command Get-MessageSourceClassForLine -ErrorAction SilentlyContinue) {
        return (Get-MessageSourceClassForLine -Line $line -SentRecordMatch $SentRecordMatch -Rules $Rules -Confirmed $Confirmed -Buyer $Buyer)
    }
    if ($line -match '^\[BUYER\]') { return @{ Class = 'buyer'; Evidence = 'explicit-role-marker' } }
    if ($line -notmatch '^\[ME\]') { return @{ Class = 'unknown'; Evidence = 'no-role-marker' } }
    # [spec §3.2 第 2 条 / A06] 行内 @@SRC 文本不是可信元数据（正文里也能写出同样的字符串）。
    #   只有共享判定库从 @@META 载荷取出的标签，且被规则集确认独占时才算证据。
    #   共享判定库不可用时，本条阶梯一律不采信行内 @@SRC。
    if ($SentRecordMatch) { return @{ Class = 'project'; Evidence = 'confirmed-send-record' } }
    # @@TS 是"我方消息带逐条时间"的既有伴随标记（页面抽取对我方消息同时写 @@TS/@@MT）。
    # 它只说明"这条有时间戳"，不足以证明发送者是机器人 ⇒ unknown（既不当作机器人，也不当作人工）。
    if ($line -match '@@(?:TS|MID):') { return @{ Class = 'unknown'; Evidence = 'timer-marker-only' } }
    # [spec §3.2 第 3 条] 无标签、无时间、无发送记录都不足以自动认定 human：不再外推。
    return @{ Class = 'unknown'; Evidence = 'no-sender-evidence' }
}

# 会话里所有**可信人工回复**（spec §2.1 的计时依据）。返回按出现顺序的数组：
#   @{ Index; Identity; MessageTs; Evidence; Preview }
function Get-TrustedHumanReplies([string[]]$lines, $SentMatches = $null) {
    $out = New-Object System.Collections.ArrayList
    if (-not $lines) { return @() }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = [string]$lines[$i]
        if (-not $ln) { continue }
        $sentMatch = $false
        if ($SentMatches -and $SentMatches.ContainsKey($i)) { $sentMatch = [bool]$SentMatches[$i] }
        $cls = Get-MessageSourceClass $ln $sentMatch
        if ($cls.Class -ne 'human') { continue }
        $ts = ''
        $mts = [regex]::Match($ln, '@@MT:([^\s]+)')
        if ($mts.Success) { $ts = [string]$mts.Groups[1].Value }
        $preview = ($ln -replace '^\[ME\]\s*', '')
        $preview = ($preview -replace '@@[A-Z]+:[^\s]*', '').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) }
        [void]$out.Add([pscustomobject]@{
            Index = $i
            Identity = (Get-MessageLineFingerprint $ln)
            MessageTs = $ts
            Evidence = [string]$cls.Evidence
            Preview = $preview
        })
    }
    return @($out.ToArray())
}

# 发送闸门的证据化版本（spec §2.2）。返回与 Get-HumanInterjectionGate 同形，另加：
#   SourceClass / SourceEvidence / UnknownIndex
#   Action='SKIP' 的三种原因：
#     'human-last'       —— 我方尾部最新一条是**可信人工**消息（沿用旧语义：不抢话）
#     'unknown-me-tail'  —— 我方尾部最新一条来源无法证明（不当作机器人，也不当作人工）
#     'no-actionable'    —— 会话里没有任何带角色标记的消息
function Get-HumanInterjectionGateEx([string[]]$lines, $SentMatches = $null) {
    $r = @{ Action = 'SEND'; Reason = ''; HasHumanLast = $false; HumanIndex = -1; LastMeSource = '';
            SourceClass = ''; SourceEvidence = ''; UnknownIndex = -1 }
    if (-not $lines -or $lines.Count -eq 0) {
        $r.Action = 'SKIP'; $r.Reason = 'no-actionable'
        return $r
    }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $ln = [string]$lines[$i]
        if (-not $ln) { continue }
        $sentMatch = $false
        if ($SentMatches -and $SentMatches.ContainsKey($i)) { $sentMatch = [bool]$SentMatches[$i] }
        $cls = Get-MessageSourceClass $ln $sentMatch
        if ($cls.Class -eq 'unknown' -and $cls.Evidence -eq 'no-role-marker') { continue }   # UI 噪声行
        if ($cls.Class -eq 'buyer') {
            $r.Reason = 'buyer-last'
            return $r
        }
        $r.SourceClass = [string]$cls.Class
        $r.SourceEvidence = [string]$cls.Evidence
        if ($cls.Class -eq 'human') {
            $r.Action = 'SKIP'; $r.Reason = 'human-last'; $r.HasHumanLast = $true
            $r.HumanIndex = $i; $r.LastMeSource = 'human'
            return $r
        }
        # [2026-10-07 spec §3.2] 我方来源四态：project/platform（我方、非人工）都按"已证明是我方"处理。
        if ($cls.Class -eq 'project' -or $cls.Class -eq 'platform' -or $cls.Class -eq 'bot') {
            $r.Reason = 'bot-last'; $r.LastMeSource = 'bot'
            return $r
        }
        # unknown 的我方消息：不能证明是机器人 ⇒ 不自动发送（宁可少发，不可抢话）
        $r.Action = 'SKIP'; $r.Reason = 'unknown-me-tail'
        $r.UnknownIndex = $i; $r.LastMeSource = 'unknown'
        return $r
    }
    $r.Reason = 'no-me-tail'
    return $r
}
