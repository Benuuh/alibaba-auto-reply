# okki/okki_cdp.ps1 - OKKI 专用 CDP 桥(端口参数化),镜像 scripts 根下共享 CDP 桥的实现。
# 为什么独立成文件(spec §5.1):共享桥(scripts 根与 lib 下各一份)的端口硬走
# Get-CdpPort(=config.json 的 cdp_port=9222),被 monitor/watchdog/nudge/health_check 共用,
# 本任务在 9223,不能复用也不能改共享文件(C4/N1)。
param(
    [Parameter(Mandatory=$true)][ValidateSet("eval","navigate","ports")][string]$Action,
    [int]$Port = 0,
    [string]$Url = "",
    [string]$Script = "",
    [string]$ScriptB64 = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")

# 端口:显式 -Port 优先,否则取 config 的 okki_cdp_port(禁止回退 9222 —— 见 C5/N3)
function Get-OkkiCdpPort {
    param([int]$Explicit = 0)
    if ($Explicit -gt 0) { return $Explicit }
    $cfg = Get-SkillConfig
    if ($cfg.okki_cdp_port) { return [int]$cfg.okki_cdp_port }
    throw "OKKI-CONFIG-MISSING: okki_cdp_port"
}

function Send-Json([System.Net.WebSockets.ClientWebSocket]$ws, [string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

function Recv-Json([System.Net.WebSockets.ClientWebSocket]$ws) {
    $buffer = New-Object byte[] 67108864
    $recvSeg = [ArraySegment[byte]]::new($buffer)
    # 超时保护:20 秒收不到数据即判僵死(与共享桥接收超时同口径)
    $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)
    if (-not $recvTask.Wait(20000)) { throw "WS RECV TIMEOUT (no data for 20s)" }
    $result = $recvTask.Result
    return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
}

function Cmd([System.Net.WebSockets.ClientWebSocket]$ws, [int]$id, [string]$method, [string]$paramsJson) {
    $json = '{"id":' + $id + ',"method":"' + $method + '","params":' + $paramsJson + '}'
    Send-Json $ws $json
    while ($true) {
        $resp = Recv-Json $ws
        $obj = $resp | ConvertFrom-Json
        if ($obj.id -eq $id) { return $obj }
    }
}

# 页面选择:优先 host 匹配 crm.xiaoman.cn 的 type=page tab;不存在则退第一个 page(spec §5.1)
function Get-OkkiPage([int]$p, [string]$HostMatch = "crm.xiaoman.cn") {
    $tabs = (Invoke-WebRequest -Uri "http://127.0.0.1:$p/json" -TimeoutSec 15 -UseBasicParsing).Content | ConvertFrom-Json
    $pages = @($tabs | Where-Object { $_.type -eq "page" })
    if (-not $pages -or $pages.Count -eq 0) { throw "NO PAGE TAB on port $p" }
    $hit = $pages | Where-Object { $_.url -and $_.url -match [regex]::Escape($HostMatch) } | Select-Object -First 1
    if ($hit) { return $hit }
    return ($pages | Select-Object -First 1)
}

function Connect-Page([string]$wsUrl) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    # 超时保护:15 秒连不上即失败(与共享桥连接超时同口径)
    $connTask = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None)
    if (-not $connTask.Wait(15000)) { $ws.Dispose(); throw "WS CONNECT TIMEOUT ($wsUrl)" }
    return $ws
}

function Get-ChromeVersion([int]$p) {
    $v = (Invoke-WebRequest -Uri "http://127.0.0.1:$p/json/version" -TimeoutSec 15 -UseBasicParsing).Content | ConvertFrom-Json
    return $v
}

# 只输出 host+pathname:query 可能含 ticket/token,C7 禁止落日志
function Get-SafePageLocation([string]$Url) {
    if (-not $Url) { return "(no-url)" }
    try {
        $u = [Uri]$Url
        return ($u.Host + $u.AbsolutePath)
    } catch { return "(unparsable)" }
}

try {
    $okkiPort = Get-OkkiCdpPort -Explicit $Port
    switch ($Action) {
        "ports" {
            # 就绪探测:输出 OKKI-CDP-READY + 该端口 Chrome 版本(供 ensure 判定)
            $v = Get-ChromeVersion $okkiPort
            $page = Get-OkkiPage $okkiPort
            Write-Output ("OKKI-CDP-READY port={0} browser={1} page={2}" -f $okkiPort, $v.Browser, (Get-SafePageLocation $page.url))
        }
        "navigate" {
            $page = Get-OkkiPage $okkiPort
            $ws = Connect-Page $page.webSocketDebuggerUrl
            $escUrl = $Url.Replace('\','\\').Replace('"','\"')
            $resp = Cmd $ws 1 "Page.navigate" ('{"url":"' + $escUrl + '"}')
            if ($resp.error) { Write-Output "NAV ERROR: $($resp.error.message)" }
            Start-Sleep -Seconds 6
            $title = Cmd $ws 2 "Runtime.evaluate" '{"expression":"document.title","returnByValue":true}'
            Write-Output "TITLE: $($title.result.result.value)"
            $url = Cmd $ws 3 "Runtime.evaluate" '{"expression":"location.href","returnByValue":true}'
            Write-Output "URL: $($url.result.result.value)"
            $ws.Dispose()
        }
        "eval" {
            # -ScriptB64 优先:内容经 Base64 传输,命令行层不再受引号/特殊字符影响
            if ($ScriptB64) {
                $Script = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ScriptB64))
            }
            $page = Get-OkkiPage $okkiPort
            $ws = Connect-Page $page.webSocketDebuggerUrl
            $esc = $Script.Replace('\','\\').Replace('"','\"').Replace("`n","\n").Replace("`r","\r")
            $expr = '{"expression":"' + $esc + '","returnByValue":true,"awaitPromise":true}'
            $resp = Cmd $ws 1 "Runtime.evaluate" $expr
            if ($resp.error) {
                Write-Output "OKKI-CDP-ERROR: $($resp.error.message)"
                exit 1
            } elseif ($resp.result.exceptionDetails) {
                Write-Output "OKKI-CDP-ERROR: JS EXCEPTION $($resp.result.exceptionDetails.text) $($resp.result.exceptionDetails.exception.value)"
                exit 1
            } elseif ($null -ne $resp.result.result.value) {
                Write-Output $resp.result.result.value
            } else {
                Write-Output "OKKI-CDP-ERROR: RESULT TYPE $($resp.result.result.type)"
                exit 1
            }
            $ws.Dispose()
        }
    }
} catch {
    # 统一捕获:超时/连接失败/解析错误 → 单行错误 + 非零退出(供 okki_ensure/主流程判定)
    Write-Output "OKKI-CDP-ERROR: $($_.Exception.Message)"
    exit 1
}
