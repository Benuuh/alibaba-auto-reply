# lib/wecom.ps1 - 企微智能机器人推送封装(长连接通道,经本地 HTTP 127.0.0.1:19886)
# 注意:PS 5.1 字符串 body 会按 GBK 编码导致中文乱码,必须显式 UTF-8 字节发送。
# 依赖: config.ps1(Get-SkillPath "data" 读接收人缓存)
function Get-WecomReceiver {
    $f = Join-Path (Get-SkillPath "data") "wecom_receiver.json"
    if (Test-Path $f) {
        try { return Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}

function Test-WecomService {
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:19886/health" -TimeoutSec 3
        return ($h.connected -eq $true)
    } catch { return $false }
}

# 返回: SENT_OK / NO_RECEIVER / SERVICE_DOWN / SEND_ERROR: ...
function Send-WecomMessage([string]$text, [string]$to = "") {
    if (-not $to) {
        $rcv = Get-WecomReceiver
        if (-not $rcv -or -not $rcv.last_userid) { return "NO_RECEIVER" }
        $to = $rcv.last_userid
    }
    if (-not (Test-WecomService)) { return "SERVICE_DOWN" }
    $body = @{ to = $to; text = $text } | ConvertTo-Json
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:19886/send" -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        if ($r.ok) { return "SENT_OK" }
        return "SEND_FAIL"
    } catch { return "SEND_ERROR: $($_.Exception.Message)" }
}

