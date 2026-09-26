# lib\alert_dedup.ps1 — 告警去重判定（纯函数；无 I/O、无副作用、可单测）
# [FIX-ALERTDEDUP 2026-09-26] 从 health_check.ps1 的内联逻辑抽出。
#
#   背景（实测 2026-09-26）：AlibabaAutoReplyHealth 由计划任务每 15 分钟触发一次
#   （:03/:18/:33/:48）；health_check.ps1 的 $now 在所有探针跑完后才取，
#   与上次告警的差值恒为 30 分钟 ± 亚秒抖动。旧判据 `-ge 30` 恰好压在边界上，
#   抖动决定"这一轮到底发不发"：
#     12:33:08 发了、13:03:06 发了、**13:33:06 没发**（data\health_state.json 停在 13:03:06）。
#   净效果：同类告警的间隔在 30/45 分钟之间摆动，且不可预测。
#
#   修法：去重窗口留 ToleranceMin 容差（默认 1 分钟，远小于半个 tick 的 7.5 分钟），
#   保证"告警之后最近的那个合法 tick 一定发"。语义仍是"同类告警 30 分钟内只发一次"。
#
#   ⚠️ 本文件含中文 ⇒ 必须保持 UTF-8 带 BOM。
#      Windows PowerShell 5.1 会把无 BOM 的 .ps1 按 ANSI/GBK 解码 ⇒ 中文字面量静默失真
#      （KNOWN_EXCEPTIONS E-10）。

function Test-AlertDue {
    param(
        [Parameter(Mandatory=$true)][datetime]$Now,
        [string]$LastAlert = '',
        [int]$WindowMin = 30,
        [double]$ToleranceMin = 1
    )
    # 空值 / 解析失败 ⇒ 视为"到点"：宁可多发一条，绝不静默哑火
    # （与抽库前的语义一致：旧代码 catch 后 $lastAlert 保持 $null ⇒ 直接发）
    if ([string]::IsNullOrWhiteSpace($LastAlert)) { return $true }
    $la = $null
    try { $la = [datetime]::Parse([string]$LastAlert) } catch { return $true }
    if ($null -eq $la) { return $true }
    return (($Now - $la).TotalMinutes -ge ($WindowMin - $ToleranceMin))
}
