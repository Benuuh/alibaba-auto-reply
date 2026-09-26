# lib/msg_source.ps1 - 消息来源判定(纯函数, 无副作用, 便于单测)
# 背景: 快照里机器人发出的消息带 @@TS 标记, 人工在 OneTalk 手打的消息不带任何标记。
#   实测(2026-09-26): 全库 1812 条 [ME] 行全部带 @@TS; @@OT 只出现在 [BUYER] 行(804/1509)。
#   标记由 monitor.ps1::Open-ConvoAndGetMessages 的页面 JS 产出:
#     '[ME] ' + 文本 + (有 ts 时 ' @@TS:' + ts)   —— @@TS 是机器人消息的可靠伴随标记。
# 契约: 本文件是"消息来源"的唯一判定处; 其他文件不得再自行写正则判断来源。
# 依赖: 无(不 dot-source 任何文件), 可被测试与 monitor 各自独立加载。

# 单行判定: 返回 'buyer' | 'bot' | 'human' | 'unknown'
function Get-MessageSource([string]$line) {
    if (-not $line) { return 'unknown' }
    if ($line -match '^\[BUYER\]') { return 'buyer' }
    if ($line -match '^\[ME\]') {
        if ($line -match '@@TS') { return 'bot' }
        return 'human'
    }
    return 'unknown'
}

# 判断"最近一条我方消息是否人工发出"(用于防抢话)
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
