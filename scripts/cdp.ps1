param(
    [Parameter(Mandatory=$true)][string]$Action,
    [string]$Url = "",
    [string]$Script = "",
    [string]$ScriptB64 = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")

function Send-Json([System.Net.WebSockets.ClientWebSocket]$ws, [string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

function Recv-Json([System.Net.WebSockets.ClientWebSocket]$ws) {
    $buffer = New-Object byte[] 67108864
    $recvSeg = [ArraySegment[byte]]::new($buffer)
    # 超时保护:20 秒收不到任何数据即判定连接僵死(曾出现 navigate 挂起 8 分钟)
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

function Get-Page {
    $port = Get-CdpPort
    $tabs = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/json" -UseBasicParsing).Content | ConvertFrom-Json
    return ($tabs | Where-Object { $_.type -eq "page" } | Select-Object -First 1)
}

function Connect-Page([string]$wsUrl) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    # 超时保护:15 秒连不上即失败,由调用方重试/自愈
    $connTask = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None)
    if (-not $connTask.Wait(15000)) { $ws.Dispose(); throw "WS CONNECT TIMEOUT ($wsUrl)" }
    return $ws
}

try {
switch ($Action) {
    "navigate" {
        $page = Get-Page
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
        if ($ScriptB64) {
            $Script = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ScriptB64))
        }
        $page = Get-Page
        $ws = Connect-Page $page.webSocketDebuggerUrl
        $esc = $Script.Replace('\','\\').Replace('"','\"').Replace("`n","\n").Replace("`r","\r")
        $expr = '{"expression":"' + $esc + '","returnByValue":true,"awaitPromise":true}'
        $resp = Cmd $ws 1 "Runtime.evaluate" $expr
        if ($resp.error) {
            Write-Output "CMD ERROR: $($resp.error.message)"
        } elseif ($resp.result.exceptionDetails) {
            Write-Output "JS EXCEPTION: $($resp.result.exceptionDetails.text) $($resp.result.exceptionDetails.exception.value)"
        } elseif ($null -ne $resp.result.result.value) {
            Write-Output $resp.result.result.value
        } else {
            Write-Output "RESULT TYPE: $($resp.result.result.type)"
        }
        $ws.Dispose()
    }
}
} catch {
    # 统一捕获:超时/连接失败/解析错误 → 输出单行错误,由调用方(monitor 等)按 CDP 失败处理并自愈
    Write-Output "CDP ERROR: $($_.Exception.Message)"
    exit 1
}
