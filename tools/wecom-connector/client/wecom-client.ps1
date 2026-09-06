# client/wecom-client.ps1 - wecom-connector 的 PowerShell 客户端库(独立组件,零外部依赖)
# 用法: . client\wecom-client.ps1; Conn-SendMessage -Text "..." -To "userid"
# 函数前缀 Conn-* 避免与宿主项目同名函数(如旧 lib\wecom.ps1)遮蔽冲突。
# 基地址解析优先级: 环境变量 WECOM_BASE_URL > 组件 config.json(host/port) > 默认(见 Conn-DefaultPort)
# 编码铁律: PS 5.1 的 Invoke-RestMethod 缺 charset 时按 Latin-1 解码会乱码,见下方 Conn-GetJson/Conn-PostJson 注释。
# 返回码(与 alibaba-auto-reply 原 lib\wecom.ps1 语义一致):
#   Conn-SendMessage → SENT_OK / NO_RECEIVER / SERVICE_DOWN / SEND_FAIL / SEND_ERROR: <msg>
#   Conn-GetMessages → items 数组(seq>after 升序);服务不可达返回 $null(不抛错)

function Conn-BaseUrl {
    $envUrl = $env:WECOM_BASE_URL
    if ($envUrl) { return $envUrl }
    $cfg = Get-ConnConfig
    if ($cfg -and $cfg.port) {
        $hostName = "127.0.0.1"
        if ($cfg.host) { $hostName = [string]$cfg.host }
        return ("http://" + $hostName + ":" + $cfg.port)
    }
    return "http://127.0.0.1:" + (Conn-DefaultPort)
}

# 公共配置解析(与 bin 共用单一事实源)
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\ps-common.ps1")

# POST UTF-8 字节 + Invoke-RestMethod 统一封装(编码铁律:PS 5.1 缺 charset 按 Latin-1 解码,
# 必须显式 UTF-8 字节发送并声明 charset);调用方自行 try/catch
function Conn-PostJson([string]$pathAndQuery, $obj, [int]$timeoutSec = 15) {
    $body = $obj | ConvertTo-Json
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    return Invoke-RestMethod -Uri ((Conn-BaseUrl) + $pathAndQuery) -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec $timeoutSec -UseBasicParsing
}

# GET + UTF8 解码统一封装(编码铁律:PS 5.1 Invoke-RestMethod 缺 charset 按 Latin-1 解码会乱码,
# 必须 HttpWebRequest + StreamReader(UTF8) 显式解码);失败返回 $null 不抛错
function Conn-GetJson([string]$pathAndQuery) {
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create(((Conn-BaseUrl) + $pathAndQuery))
        $req.Method = "GET"
        $req.Timeout = 5000
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $json = $reader.ReadToEnd()
        $reader.Dispose()
        $resp.Dispose()
        return ($json | ConvertFrom-Json)
    } catch { return $null }
}

# 服务健康:连接状态布尔(不抛错)
function Conn-TestService {
    $h = Conn-GetJson "/health"
    return ($null -ne $h -and $h.connected -eq $true)
}

# 接收方缓存对象(owner 判定与主动推送目标);服务不可达返回 $null
function Conn-GetReceiver {
    return Conn-GetJson "/receiver"
}

# 发送企微消息:to 缺省时用接收方缓存 last_userid
function Conn-SendMessage([string]$text, [string]$to = "") {
    if (-not $to) {
        $rcv = Conn-GetReceiver
        if (-not $rcv -or -not $rcv.last_userid) { return "NO_RECEIVER" }
        $to = [string]$rcv.last_userid
    }
    if (-not (Conn-TestService)) { return "SERVICE_DOWN" }
    try {
        $r = Conn-PostJson "/send" @{ to = $to; text = $text } 15
        if ($r.ok) { return "SENT_OK" }
        return "SEND_FAIL"
    } catch { return "SEND_ERROR: $($_.Exception.Message)" }
}

# 增量读取消息(consumer 命名游标;after 缺省取该消费者已存游标)。返回 items 数组或 $null。
function Conn-GetMessages([string]$consumer = "", [long]$after = -1) {
    $q = "consumer=" + [System.Uri]::EscapeDataString($consumer)
    if ($after -ge 0) { $q = $q + "&after=" + $after }
    $r = Conn-GetJson ("/messages?" + $q)
    if ($null -eq $r) { return $null }
    # PS 5.1 坑:空数组 return 会被展开为无输出(调用方得 $null),逗号前缀强制按数组返回
    return ,@($r.items)
}

# 读取某消费者已存游标(不存在返回 0)
function Conn-GetCursor([string]$consumer = "") {
    $q = "consumer=" + [System.Uri]::EscapeDataString($consumer)
    $r = Conn-GetJson ("/cursor?" + $q)
    if ($null -eq $r) { return 0 }
    return [long]$r.seq
}

# 推进消费者游标(处理完消息后提交,at-least-once 语义)。成功返回 $true,失败 $false。
function Conn-SetCursor([string]$consumer = "", [long]$seq = 0) {
    try {
        $r = Conn-PostJson "/cursor" @{ consumer = $consumer; seq = $seq } 5
        return ($null -ne $r.seq)
    } catch { return $false }
}

# 游标迁移:消费方在组件中尚无游标且旧状态文件有 last_seq 时,以其为初始游标(防止重启后重复处理历史消息)。
# 返回: "SEEDED" / "ALREADY" / "NO_LEGACY" / "FAILED"
function Conn-InitCursor([string]$consumer = "", [string]$legacyFile = "") {
    $cur = Conn-GetCursor -consumer $consumer
    if ($cur -gt 0) { return "ALREADY" }
    if ($legacyFile -and (Test-Path $legacyFile)) {
        try {
            $st = Get-Content $legacyFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st -and $st.last_seq -and ([long]$st.last_seq) -gt 0) {
                if (Conn-SetCursor -consumer $consumer -seq ([long]$st.last_seq)) { return "SEEDED" }
                return "FAILED"
            }
        } catch { return "NO_LEGACY" }
    }
    return "NO_LEGACY"
}
