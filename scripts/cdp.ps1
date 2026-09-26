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
    # [FIX-PAGESELECT 2026-09-26] 原实现 `Select-Object -First 1` 不校验 URL：
    #   任何新开的 type=page 标签页（例如 BrowserSkill 的 Agent Window）都可能排在 OneTalk 之前，
    #   导致 monitor 的 Switch-ToPendingTab / Get-Snapshot / 发送动作全部打在错误页面上，
    #   并让 Test-PageHealth 返回 wrong-tab ⇒ 分级自愈误判断连 ⇒ 反复 reload/重启 Chrome（自伤循环）。
    #   现改为：优先返回 URL 匹配 onetalk 的 page；找不到则**明确返回 $null**（而不是随便给一个页面）。
    $port = Get-CdpPort
    # [DEVIATION D-02 2026-09-26] 不用 spec 模板的 `Invoke-WebRequest ... -UseBasicParsing`：本机实测它在
    #   PowerShell 5.1 里**必抛** `Win32 internal error "Access is denied" 0x5 ... reading the console
    #   output buffer`（同进程对照：Invoke-RestMethod 正常）⇒ 照抄模板会让 Get-Page 恒返回 $null。
    # [DEVIATION D-04 2026-09-26] 也**不要**写 `@(ConvertFrom-Json -InputObject $s)`：PowerShell 5.1 把
    #   JSON 数组解析成"**单个** Object[] 对象"，再被 @() 包成 1 元素数组 ⇒ 下游读到的是整个数组，
    #   `$page.webSocketDebuggerUrl` 变成多个 ws:// 拼接串，`Connect-Page` 抛
    #   `Cannot convert the "System.Object[]" value of type "System.Object[]" to type "System.Uri"`
    #   ⇒ CDP 全线失效（实测 01:24–01:28 monitor 卡在 about:blank）。
    #   **正确写法**：`Invoke-RestMethod` 直接返回可索引数组（实测 count=5、[0].type=page），**不要**再套 @()。
    # ⚠️ 本函数与 `scripts\lib\cdp.ps1::Get-Page` **必须逐字一致**（tests\page_select.tests.ps1 断言两处一致）。
    $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 5
    $pages = $tabs | Where-Object { $_.type -eq "page" }
    $onetalk = $pages | Where-Object { $_.url -match 'onetalk\.alibaba\.com' }
    if (@($onetalk).Count -gt 0) { return @($onetalk)[0] }
    return $null
}

function Connect-Page([string]$wsUrl) {
    # [DEVIATION D-04 2026-09-26] 本机实测存在一个**瞬态** CDP 故障：Chrome 刚重启的窗口内，
    #   /json 的 JSON 数组会被**折叠**成一个对象（`type`="page browser_ui browser_ui"、
    #   `webSocketDebuggerUrl`=多个 ws:// 用空格拼接）。它若流到 [Uri] 转换处就抛
    #   `Cannot convert the "System.Object[]" value of type "System.Object[]" to type "System.Uri"`
    #   ⇒ 整条 CDP 路径死掉、monitor 卡在 about:blank 无法导航回 OneTalk（实测 01:26–01:28）。
    #   这里兜底：只取第一个 URL 记号。
    $wsUrl = ([string]$wsUrl -split '\s+')[0]
    if (-not $wsUrl) { throw "EMPTY WS URL (merged target?)" }
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    # 超时保护:15 秒连不上即失败,由调用方重试/自愈
    $connTask = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None)
    if (-not $connTask.Wait(15000)) { $ws.Dispose(); throw "WS CONNECT TIMEOUT ($wsUrl)" }
    return $ws
}

try {
switch ($Action) {
    "navigate" {
        # [DEVIATION D-03 2026-09-26] navigate 是"把页面开到 OneTalk"的**引导动作**：
        #   重启 Chrome 后页面是 about:blank ⇒ 此时**必然**没有 OneTalk 页。
        #   若这里也用 URL 守卫（返回 $null），导航就永远无法发生 ⇒ chrome_ensure 的
        #   "proceed to navigate+login path" 变成死路（实测 01:25:35：CHROME-ENSURE: unknown page state,
        #   manual check needed，monitor 卡死在 about:blank）。
        #   ⇒ navigate 用"可用的任意 page"作引导；URL 守卫只作用于 eval（那才是真正操作页面的动作）。
        $page = Get-Page
        if (-not $page) {
            # [DEVIATION D-03/D-04] 引导兜底：用"可用的任意 page"（同样不要给 JSON 解析套 @()）
            $port = Get-CdpPort
            try {
                $all = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 5
                $page = $all | Where-Object { $_.type -eq "page" } | Select-Object -First 1
            } catch { $page = $null }
        }
        # S1-3 空守卫：连一个 page 都没有（Chrome 没起来）才报错
        if (-not $page) { Write-Output "CMD ERROR: no onetalk page found (url guard)"; exit 1 }
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
        # [FIX-PAGESELECT 2026-09-26] S1-3 空守卫：Get-Page 现在可能返回 $null
        if (-not $page) { Write-Output "CMD ERROR: no onetalk page found (url guard)"; exit 1 }
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
