# lib/wecom.ps1 - 告警推送出口（2026-09-26 改造：旧企微长连接 → dsh-im 主动投递）
#
# 【历史】原实现经本地长连接桥 127.0.0.1:19886/send 推送到企微机器人。
#   该桥已按用户授权停用（spec 通道交接与页面判据修正_20260926 的 Phase A），
#   原因是它与 @xmanrui/dsh-im 插件抢同一个企微机器人（exit_on_kicked_offline=true ⇒ 互相顶下线）。
#   停用后本函数恒返回 SERVICE_DOWN ⇒ 7 处调用点的告警全部哑火。本文件即为此而改。
#
# 【现在】走 dsh-im 主动投递 HTTP 接口。实测（2026-09-26 12:36-12:40）：
#   GET  同路径                                     -> 405 + allow: POST（接口活着、只收 POST）
#   POST {botId 错}                                 -> 404 unknown-bot
#   POST {botId 对, targetId 错}                    -> 404 unknown-target
#   POST {botId 对, targetId 对, text}              -> 200 {"sent":true}
#   POST 多一个键 / 少一个键                         -> 400 bad-request（接口用 exactKeys 严格校验）
#   官方文档明示：该 HTTP 接口**不包含鉴权**，只应在本机使用。
#
# 【契约不变】函数名与返回码保持原样，7 个调用点一行都不用改：
#   SENT_OK / SERVICE_DOWN / NO_RECEIVER / SEND_ERROR: <msg>
#   ⚠️ 函数名里的 "Wecom" 是历史命名，实际出口已是 dsh-im。
#
# 【编码铁律】PS 5.1 的字符串 body 会按 GBK 编码 ⇒ 中文乱码。
#   必须显式转 UTF-8 字节再发送（旧实现同款教训，新实现照做）。
#
# 依赖: config.ps1（读取 dshim_delivery_url / dshim_bot_id / dshim_target_id）
function Get-WecomReceiver {
    $f = Join-Path (Get-SkillPath "data") "wecom_receiver.json"
    if (Test-Path $f) {
        try { return Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}

function Get-DshImConfig {
    $url = ''; $bot = ''; $tgt = ''
    try {
        $cfg = Join-Path $PSScriptRoot '..\config.json'
        if (Test-Path $cfg) {
            $o = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($o.PSObject.Properties.Name -contains 'dshim_delivery_url') { $url = [string]$o.dshim_delivery_url }
            if ($o.PSObject.Properties.Name -contains 'dshim_bot_id')       { $bot = [string]$o.dshim_bot_id }
            if ($o.PSObject.Properties.Name -contains 'dshim_target_id')    { $tgt = [string]$o.dshim_target_id }
        }
    } catch { }
    return [pscustomobject]@{ Url = $url; BotId = $bot; TargetId = $tgt }
}

# 兼容旧调用点：旧函数名保留，语义改为"探活 dsh-im 配置是否就绪"
function Test-WecomService {
    $c = Get-DshImConfig
    if (-not $c.Url -or -not $c.BotId -or -not $c.TargetId) { return $false }
    try {
        $r = Invoke-WebRequest -Uri $c.Url -Method Get -UseBasicParsing -TimeoutSec 3
        return ($r.StatusCode -eq 405)     # 405 = 接口在且只收 POST（实测）
    } catch {
        # Invoke-WebRequest 对 405 会抛异常；从异常里取状态码
        try { return ([int]$_.Exception.Response.StatusCode -eq 405) } catch { return $false }
    }
}

# 返回: SENT_OK / SERVICE_DOWN / NO_RECEIVER / SEND_ERROR: ...
# $to 参数保留仅为兼容旧调用点签名；dsh-im 的目标由 targetId 决定，此处不再使用。
function Send-WecomMessage([string]$text, [string]$to = "") {
    $c = Get-DshImConfig
    if (-not $c.Url -or -not $c.BotId -or -not $c.TargetId) { return "SERVICE_DOWN" }
    # ⚠️ 必须挡**纯空白**：实测空白 text 会被接口拒为 400 bad-request（"Invalid delivery request."），
    #    不在这里拦就会变成 SEND_ERROR 而不是 NO_RECEIVER（语义退化、且刷错误日志）。
    if ([string]::IsNullOrWhiteSpace($text)) { return "NO_RECEIVER" }
    # 接口用 exactKeys 严格校验：**只能**有 botId/targetId/text 三个键（实测多一个键即 400）
    $body = [pscustomobject]@{ botId = $c.BotId; targetId = $c.TargetId; text = $text } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $r = Invoke-RestMethod -Uri $c.Url -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        if ($r.sent -eq $true) { return "SENT_OK" }
        return "SEND_FAIL"
    } catch { return "SEND_ERROR: $($_.Exception.Message)" }
}

# ===== 旧实现（2026-09-26 停用，保留备查；如需回滚见 spec §9 R-2）=====
# function Test-WecomService {
#     try {
#         $h = Invoke-RestMethod -Uri "http://127.0.0.1:19886/health" -TimeoutSec 3
#         return ($h.connected -eq $true)
#     } catch { return $false }
# }
# function Send-WecomMessage([string]$text, [string]$to = "") {
#     if (-not $to) {
#         $rcv = Get-WecomReceiver
#         if (-not $rcv -or -not $rcv.last_userid) { return "NO_RECEIVER" }
#         $to = $rcv.last_userid
#     }
#     if (-not (Test-WecomService)) { return "SERVICE_DOWN" }
#     $body = @{ to = $to; text = $text } | ConvertTo-Json
#     $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
#     try {
#         $r = Invoke-RestMethod -Uri "http://127.0.0.1:19886/send" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15
#         if ($r.ok) { return "SENT_OK" }
#         return "SEND_FAIL"
#     } catch { return "SEND_ERROR: $($_.Exception.Message)" }
# }
