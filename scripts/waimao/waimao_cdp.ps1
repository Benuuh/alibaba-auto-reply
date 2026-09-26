# waimao/waimao_cdp.ps1 - 网易外贸通专用 CDP 桥(端口参数化)。
#   镜像 okki/okki_cdp.ps1 的实现,但 host 匹配 waimao.office.163.com。
#   为什么独立成文件:共享 CDP 桥(scripts 根与 lib 下各一份)端口硬走 config.json 的
#   cdp_port(=9222,阿里 OneTalk 在用),本模块在 9224,不能复用也不能改共享文件。
#   编码:UTF8-BOM。
param(
    [Parameter(Mandatory=$true)][ValidateSet("eval","navigate","ports","tabs")][string]$Action,
    [int]$Port = 0,
    [string]$Url = "",
    [string]$Script = "",
    [string]$ScriptB64 = "",
    [string]$HostMatch = "waimao.office.163.com"
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")

# 端口:显式 -Port 优先,否则取 config 的 waimao_cdp_port(禁止回退 9222/9223)
function Get-WaimaoCdpPort {
    param([int]$Explicit = 0)
    if ($Explicit -gt 0) { return $Explicit }
    $cfg = Get-SkillConfig
    if ($cfg.waimao_cdp_port) { return [int]$cfg.waimao_cdp_port }
    throw "WAIMAO-CONFIG-MISSING: waimao_cdp_port"
}

function Send-Json([System.Net.WebSockets.ClientWebSocket]$ws, [string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

# [FIX-PROXY] 本机配了系统代理(见 lib\cdp.ps1 的 FIX-ENVBLOCK 记录:环境块里
#   http_proxy/HTTP_PROXY、no_proxy/NO_PROXY 成对重复)。若走系统代理,对本机
#   127.0.0.1 的 /json 请求会被转发到代理上而失败。所有回环 HTTP 一律显式绕开代理。
function Invoke-Loopback([string]$Uri, [int]$TimeoutSec = 15) {
    return Invoke-WebRequest -Uri $Uri -TimeoutSec $TimeoutSec -UseBasicParsing -Proxy $null
}

function Get-CdpTabs([int]$p) {
    return (Invoke-Loopback "http://127.0.0.1:$p/json").Content | ConvertFrom-Json
}

function Get-CdpVersion([int]$p) {
    return (Invoke-Loopback "http://127.0.0.1:$p/json/version").Content | ConvertFrom-Json
}

function Recv-Json([System.Net.WebSockets.ClientWebSocket]$ws) {
    $buffer = New-Object byte[] 67108864
    $recvSeg = [ArraySegment[byte]]::new($buffer)
    $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)
    if (-not $recvTask.Wait(30000)) { throw "WS RECV TIMEOUT (no data for 30s)" }
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

# 页面选择:优先 host 匹配目标 tab;不存在则退第一个 page
function Get-WaimaoPage([int]$p, [string]$Match) {
    $tabs = Get-CdpTabs $p
    $pages = @($tabs | Where-Object { $_.type -eq "page" })
    if (-not $pages -or $pages.Count -eq 0) { throw "NO PAGE TAB on port $p" }
    $hit = $pages | Where-Object { $_.url -and $_.url -match [regex]::Escape($Match) } | Select-Object -First 1
    if ($hit) { return $hit }
    return ($pages | Select-Object -First 1)
}

function Connect-Page([string]$wsUrl) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $connTask = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None)
    if (-not $connTask.Wait(15000)) { $ws.Dispose(); throw "WS CONNECT TIMEOUT ($wsUrl)" }
    return $ws
}

# 只输出 host+pathname:query 可能含 ticket/token(C7 禁止落日志)
function Get-SafePageLocation([string]$Url) {
    if (-not $Url) { return "(no-url)" }
    try { $u = [Uri]$Url; return ($u.Host + $u.AbsolutePath) } catch { return "(unparsable)" }
}

try {
    $wmPort = Get-WaimaoCdpPort -Explicit $Port
    switch ($Action) {
        "ports" {
            $v = Get-CdpVersion $wmPort
            $page = Get-WaimaoPage $wmPort $HostMatch
            Write-Output ("WAIMAO-CDP-READY port={0} browser={1} page={2}" -f $wmPort, $v.Browser, (Get-SafePageLocation $page.url))
        }
        "tabs" {
            # 列出全部 page tab(供 ensure/recon 定位目标页面;只输出 host+path)
            $tabs = Get-CdpTabs $wmPort
            foreach ($t in @($tabs | Where-Object { $_.type -eq "page" })) {
                Write-Output ((Get-SafePageLocation $t.url) + " | " + $t.title)
            }
        }
        "navigate" {
            $page = Get-WaimaoPage $wmPort $HostMatch
            $ws = Connect-Page $page.webSocketDebuggerUrl
            $escUrl = $Url.Replace('\','\\').Replace('"','\"')
            $resp = Cmd $ws 1 "Page.navigate" ('{"url":"' + $escUrl + '"}')
            if ($resp.error) { Write-Output "NAV ERROR: $($resp.error.message)" }
            Start-Sleep -Seconds 8
            $title = Cmd $ws 2 "Runtime.evaluate" '{"expression":"document.title","returnByValue":true}'
            Write-Output "TITLE: $($title.result.result.value)"
            $url = Cmd $ws 3 "Runtime.evaluate" '{"expression":"location.href","returnByValue":true}'
            Write-Output "URL: $($url.result.result.value)"
            $ws.Dispose()
        }
        "eval" {
            # -ScriptB64 优先:内容经 Base64 传输,命令行层不再受引号/特殊字符影响
            if ($ScriptB64) { $Script = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ScriptB64)) }
            $page = Get-WaimaoPage $wmPort $HostMatch
            $ws = Connect-Page $page.webSocketDebuggerUrl
            $esc = $Script.Replace('\','\\').Replace('"','\"').Replace("`n","\n").Replace("`r","\r")
            $expr = '{"expression":"' + $esc + '","returnByValue":true,"awaitPromise":true}'
            $resp = Cmd $ws 1 "Runtime.evaluate" $expr
            if ($resp.error) {
                Write-Output "WAIMAO-CDP-ERROR: $($resp.error.message)"
                exit 1
            } elseif ($resp.result.exceptionDetails) {
                Write-Output "WAIMAO-CDP-ERROR: JS EXCEPTION $($resp.result.exceptionDetails.text) $($resp.result.exceptionDetails.exception.value)"
                exit 1
            } elseif ($null -ne $resp.result.result.value) {
                Write-Output $resp.result.result.value
            } else {
                Write-Output "WAIMAO-CDP-ERROR: RESULT TYPE $($resp.result.result.type)"
                exit 1
            }
            $ws.Dispose()
        }
    }
} catch {
    Write-Output "WAIMAO-CDP-ERROR: $($_.Exception.Message)"
    exit 1
}
