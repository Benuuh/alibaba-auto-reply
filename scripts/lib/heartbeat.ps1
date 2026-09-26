# lib\heartbeat.ps1 — 每日"我还活着"心跳（纯函数判定 + 组装 + 发送）
#
#   为什么要它：2026-09-26 移除失效检查后，health.log 长期全绿，告警链路**再没有任何日常流量**
#   ⇒ 通道断掉时不会有人知道（通知你的那条路，本身就是断的那条）。
#   当日 15:2x 人工发过一条测试消息、用户确认收到 —— 但那是**一次性**的，证明不了明天还通。
#
#   设计取舍：
#   - **只在所有检查都 OK 时发** ⇒ 它是"全清"信号；有故障时由既有告警路径负责，不重复打扰。
#   - 每天最多一条（状态记在 <data>\heartbeat_state.json）。
#   - 到点后由 health_check 的 15 分钟 tick 触发 ⇒ 实际到达时间 = 当天首个 >= heartbeat_hour 的 tick。
#
#   依赖: config.ps1(Get-SkillPath "data")、lib\wecom.ps1(Send-WecomMessage)。调用方负责 dot-source。
#
#   ⚠️ 本文件含中文 ⇒ 必须 UTF-8 **带 BOM**（KNOWN_EXCEPTIONS E-10）。
#   ⚠️ 心跳正文含中文 ⇒ **不可**放进 health_check.ps1（该文件无 BOM，中文字面量会静默乱码）。
#      故由本文件组装正文，health_check.ps1 只传数字（纯 ASCII 调用点）。

function Test-HeartbeatDue {
    param(
        [Parameter(Mandatory=$true)][datetime]$Now,
        [string]$LastSent = '',          # 'yyyy-MM-dd' 形式；空 = 从未发过
        [int]$Hour = 9
    )
    if ($Now.Hour -lt $Hour) { return $false }
    if ([string]::IsNullOrWhiteSpace($LastSent)) { return $true }
    $d = $null
    try { $d = [datetime]::Parse([string]$LastSent) } catch { return $true }
    if ($null -eq $d) { return $true }
    return ($d.Date -ne $Now.Date)
}

function Get-HeartbeatStateFile { return (Join-Path (Get-SkillPath "data") "heartbeat_state.json") }

function Get-HeartbeatLastSent {
    $f = Get-HeartbeatStateFile
    if (Test-Path $f) {
        try { return [string]((Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json).lastSent) } catch { }
    }
    return ''
}

function Save-HeartbeatSent([datetime]$When) {
    try {
        $json = [pscustomobject]@{
            lastSent   = $When.ToString('yyyy-MM-dd')
            lastSentAt = $When.ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json
        Set-Content -Path (Get-HeartbeatStateFile) -Value $json -Encoding UTF8
    } catch { }
}

# 组装并发送。**调用方只传数字/时间**，中文正文在本文件内组装（保护 health_check.ps1 的 ASCII 约束）。
function Send-DailyHeartbeat {
    param(
        [Parameter(Mandatory=$true)][int]$CheckCount,
        [Parameter(Mandatory=$true)][datetime]$Now
    )
    $t = "【每日自检】" + $Now.ToString('yyyy-MM-dd HH:mm') + " 系统正常：" + $CheckCount +
         " 项检查全部通过（进程/日志/守护/冷却/CDP/页面）。" +
         "收到本条 = 告警通道畅通；若某天该来没来，说明通道或系统出问题了 —— 那正是本消息存在的意义。"
    return (Send-WecomMessage $t)
}