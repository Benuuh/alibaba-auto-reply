# gonghai/gonghai_cdp.ps1 - 公海模块专用 CDP 桥(库形式,dot-source 使用,无 Mandatory 参数、无主逻辑)。
#
# 为什么另写一份而**不复用** scripts\lib\cdp.ps1(本 spec §6.5.1/§6.5.2 明令,不得修改它们):
#   1) `Get-Page` 是 **URL 感知**的,只返回 `onetalk.alibaba.com` 的页面,找不到返回 $null;
#      而公海 CRM 页(`i.alibaba.com` / `alicrm.alibaba.com`)**不是** onetalk 域
#      ⇒ 用它会恒返回 $null,公海取页永远失败(§6-S2 方案 A 的已知风险 R3)。
#   2) `lib\cdp.ps1` 与 `scripts\cdp.ps1` 里的 `Get-Page` **必须逐字一致**
#      (tests\page_select.tests.ps1 断言),monitor 依赖其判据语义 ⇒ 不能为了公海去改它。
#   ⇒ 本文件提供"按域匹配"的公海取页/求值能力,与 monitor 的取页逻辑**完全解耦**。
#
# 与 scripts\cdp.ps1 的关系:WS 收发/Cmd 的实现**照搬其成熟做法**(含 D-04 的 JSON 数组陷阱规避、
#   WS 连接 15s / 接收 20s 超时保护),但页面选择器换成公海版,并**加固了凭据防泄漏**(见下)。
# 编码:UTF-8 带 BOM(spec §4-6)。本文件**不执行任何写操作**,只做 CDP 求值。

# ---- 公海相关 URL 域(实测,§6.5.14/§6.5.9) ----
#   公海列表/我的客户:`i.alibaba.com/hub/alicrm/...`
#   客户详情:`alicrm.alibaba.com/crmpage/...`
#   OneTalk(`onetalk.alibaba.com`)由既有 lib\cdp.ps1 负责,此处只用于"顺带挂钩子"时匹配。
$script:GonghaiUrlPattern = 'i\.alibaba\.com/hub/alicrm|alicrm\.alibaba\.com'
$script:OnetalkUrlPattern  = 'onetalk\.alibaba\.com'

# ---- [SPEC-公海独立Chrome 2026-09-27 §2.2/§3.3] URL 标记方案已**整体撤销** ----
# 上一版 spec(docs\specs\公海页面隔离_20260927.md)那套"URL 标记(dshgh=1) + 按标记取页"的改动,
#   按本 spec §2.2 **全部删除**:公海现在跑在自己的 Chrome 上(9225 + chrome-profile-gonghai),
#   该端口上只会有公海自己的页 ⇒ 不需要、也不该有任何标记。SPEC-公海页面隔离 那份 spec **作废**。
#   (历史事故:公海开第二个 OneTalk 页会被 Chrome 排到前面,把自动回复顶掉 —— 见本 spec §1.2。
#    独立 Chrome 之后这个风险从根上消失,所以标记方案没有任何残留价值。)
# ⚠️ 被撤销、不得再出现的符号:`$script:GonghaiTabMarker`、`$script:GonghaiOnetalkPattern`、
#    `Get-SendPageMarkerPattern`、`Test-SendPageOnGonghaiTab`、`Test-SendPageMarkerPatternNonEmpty`。
# ⚠️ monitor 侧的 `Get-Page`(取第一个 OneTalk 页)**从头到尾一个字都没改**(本 spec §0 判据 3)。
$script:OnetalkBaseUrl = 'https://onetalk.alibaba.com/message/weblitePWA.htm'

function Get-GonghaiCdpPort {
    # [SPEC-公海独立Chrome 2026-09-27 §3.3] 只读 `gonghai_cdp_port`(现役 = 9225)。
    #   ⚠️ **不许回退到 `Get-CdpPort`(=9222)**:9222 是自动回复的链路端口,
    #      一旦公海落到 9222,就等于又回到"两个子系统共用/抢页面"的老毛病(spec §1.3)。
    #      缺失即抛异常(fail-closed),绝不静默退化。
    $cfg = Get-SkillConfig
    $has = ($cfg -and ($cfg.PSObject.Properties.Name -contains 'gonghai_cdp_port') -and $cfg.gonghai_cdp_port)
    if (-not $has) { throw "GONGHAI-CONFIG-MISSING: gonghai_cdp_port" }
    $port = [int]$cfg.gonghai_cdp_port
    Assert-GonghaiNotSharedPort -Port $port
    return $port
}

function Assert-GonghaiNotSharedPort {
    # [SPEC-公海独立Chrome §2.1 / §4-P2] 安全闸:公海**绝不允许**操作 9222 那个实例。
    # 为什么单独抽成函数:它是"独立 Chrome"这条硬判据的**可执行**形式,必须能被单测直接断言;
    #   且要在**每个** CDP 出口(取页/求值/建页)上生效,不只是配置读取处。
    param([int]$Port)
    $shared = Get-CdpPort
    if ($Port -eq $shared) {
        $msg = "REFUSE: gonghai_cdp_port=$Port 与自动回复的 cdp_port=$shared 相同;公海必须用独立 Chrome(现役 9225 / chrome-profile-gonghai),否则会再次抢页面"
        throw $msg
    }
}

function Get-GonghaiCdpPages {
    # 返回全部 type=page 的标签页。⚠️ 不要给 Invoke-RestMethod 的结果套 @()(D-04 陷阱)。
    $port = Get-GonghaiCdpPort
    $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 5
    return ($tabs | Where-Object { $_.type -eq "page" })
}

function Get-GonghaiPage {
    # 按 URL 正则取第一个匹配的页面;找不到返回 $null(**不**随便给一个页面)。
    param(
        [string]$UrlMatch = $script:GonghaiUrlPattern,
        [switch]$Any
    )
    $pages = Get-GonghaiCdpPages
    if ($Any) {
        $p = $pages | Select-Object -First 1
        if ($p) { return $p }
        return $null
    }
    $hit = $pages | Where-Object { $_.url -match $UrlMatch }
    if (@($hit).Count -gt 0) { return @($hit)[0] }
    return $null
}

function Get-GonghaiOnetalkUrl {
    # [SPEC-公海独立Chrome §3.3] 公海 OneTalk 页的 URL = **朴素基址**(标记已撤销,不再拼接任何 query)。
    # 保留 `#/` 结尾:该站用 hash 路由,实测直接开基址即可正常进入(§2.1 的"不要动 hash"仍然成立)。
    return ($script:OnetalkBaseUrl + '#/')
}

function Get-GonghaiOnetalkPage {
    # [SPEC-公海独立Chrome §3.3] 取**这个端口上**的第一个 OneTalk 页;找不到返回 $null。
    # ⚠️ 语义已恢复成最朴素的一版:不再做任何标记判断。
    #   安全性由"端口隔离"保证 —— 公海端口(9225)上只会有公海自己的页,
    #   而 9222 上的 monitor 正页根本不在这个端口上,取不到也就抢不到(spec §2.1/§2.3)。
    $hit = Get-GonghaiCdpPages | Where-Object { $_.url -match $script:OnetalkUrlPattern }
    if (@($hit).Count -gt 0) { return @($hit)[0] }
    return $null
}

function New-GonghaiOnetalkTab {
    # 用 CDP `PUT /json/new?<url>` 在**公海端口**上新开一个 OneTalk 标签页。
    # ⚠️ **必须 PUT**:实测(2026-09-27)本机 Chrome 对 `GET /json/new` 返回 **405 不允许的方法**。
    # 返回新建的 target 对象;失败抛异常(由 Ensure-GonghaiOnetalkTab 决定语义)。
    $port = Get-GonghaiCdpPort
    $url = Get-GonghaiOnetalkUrl
    $resp = Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:$port/json/new?" + $url) -TimeoutSec 20
    return $resp
}

function Close-GonghaiPage {
    # [GH-31 2026-09-28] 关闭公海实例上的一个标签页(CDP `GET /json/close/<targetId>`)。
    # 为什么需要:实测该页会**渲染进程卡死** —— 这时 `Set-GonghaiPageUrl` 导航**不生效**,
    #   反复"刷新"永远救不回来(批次12/13/14 连续 3 轮 exit=1 就是这么停的)。
    #   唯一可靠的自愈是**把这个标签页关掉、在同一个端口上新开一个**。
    # ⚠️ 只按页的 id 操作,且**只在本模块自己的端口**上(端口的 9222 否决闸在 Get-GonghaiCdpPort 里)。
    param($Page)
    if (-not $Page) { return $false }
    $tid = ([string]$Page.id -split '\s+')[0]
    if (-not $tid) { return $false }
    $port = Get-GonghaiCdpPort
    try {
        [void](Invoke-RestMethod -Uri ("http://127.0.0.1:$port/json/close/" + $tid) -TimeoutSec 8)
        return $true
    } catch { return $false }
}

function New-GonghaiPage {
    # [SPEC-公海独立Chrome §3.2] 在公海端口上新开任意 URL 的标签页(公海 CRM 页用)。
    # 为什么需要:公海列表页(i.alibaba.com/hub/alicrm/public_customer)以前是**在 9222 上手动开**的;
    #   公海改用 9225 之后,那个页在新实例里并不存在 ⇒ 需要按需在工作实例里创建。
    # ⚠️ 同样必须 PUT(见 New-GonghaiOnetalkTab)。
    param([Parameter(Mandatory = $true)][string]$Url)
    $port = Get-GonghaiCdpPort
    $resp = Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:$port/json/new?" + $Url) -TimeoutSec 20
    return $resp
}

function Set-GonghaiPageUrl {
    # 在**指定的公海页**上执行 Page.navigate(公海端口,**绝不**落到 9222)。
    # 为什么不用 scripts\cdp.ps1 -Action navigate:那条路走 `Get-Page` = 9222 上的第一个 OneTalk 页。
    param(
        [Parameter(Mandatory = $true)]$Page,
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 25000
    )
    # [SPEC-公海独立Chrome §2.1] 纵深防御:页的 ws 端点必须属于公海端口
    $port = Get-GonghaiCdpPort
    $ws0 = ([string]$Page.webSocketDebuggerUrl -split '\s+')[0]
    $m = [regex]::Match($ws0, '^ws://[^/]*:(\d+)/')
    if ($m.Success -and [int]$m.Groups[1].Value -ne $port) {
        throw ("REFUSE: 页面 ws 端点端口 " + $m.Groups[1].Value + " != 公海端口 $port(拒绝在非公海实例上导航)")
    }
    $ws = Connect-GonghaiPage $Page.webSocketDebuggerUrl
    try {
        $esc = $Url.Replace('\', '\\').Replace('"', '\"')
        return (Invoke-GonghaiCmdOn -Ws $ws -Id 1 -Method "Page.navigate" -ParamsJson ('{"url":"' + $esc + '"}') -TimeoutMs $TimeoutMs)
    } finally {
        try { $ws.Dispose() } catch { }
    }
}

function Ensure-GonghaiOnetalkTab {
    # [SPEC-公海独立Chrome §3.2/§3.3] 保证**公海实例上存在** OneTalk 页,并返回它。
    #   ① 已有 ⇒ 直接复用;
    #   ② 没有 ⇒ 在公海端口上新开一个(不再有任何标记判断);
    #   ③ 轮询等待页面就绪(最多 N 次 × 间隔)。
    # ⚠️ 建页失败 ⇒ 返回 $null,由调用方按"无页"处理;**绝不**回退去用 9222 上的页。
    # 生命周期:页被关掉 / Chrome 重启 ⇒ 下次运行时自愈重开。
    param([int]$WaitTries = 15, [int]$WaitMs = 1000)
    $tab = Get-GonghaiOnetalkPage
    if ($tab) { return $tab }
    try { [void](New-GonghaiOnetalkTab) }
    catch { return $null }
    for ($i = 1; $i -le $WaitTries; $i++) {
        Start-Sleep -Milliseconds $WaitMs
        $tab = Get-GonghaiOnetalkPage
        if ($tab) { return $tab }
    }
    return $null
}

function Connect-GonghaiPage([string]$wsUrl) {
    # 照搬 scripts\cdp.ps1::Connect-Page 的兜底:瞬态 CDP 故障会把多个 ws:// 用空格拼接。
    $wsUrl = ([string]$wsUrl -split '\s+')[0]
    if (-not $wsUrl) { throw "EMPTY WS URL (merged target?)" }
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $connTask = $ws.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None)
    if (-not $connTask.Wait(15000)) { $ws.Dispose(); throw "WS CONNECT TIMEOUT ($wsUrl)" }
    return $ws
}

function Send-GonghaiJson([System.Net.WebSockets.ClientWebSocket]$ws, [string]$json) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}

function Receive-GonghaiJson([System.Net.WebSockets.ClientWebSocket]$ws) {
    $buffer = New-Object byte[] 67108864
    $recvSeg = [ArraySegment[byte]]::new($buffer)
    $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)
    if (-not $recvTask.Wait(20000)) { throw "WS RECV TIMEOUT (no data for 20s)" }
    $result = $recvTask.Result
    return [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
}

# ---- 只读网络侦察用:多帧 JSON 读取器 + 凭据事件**静默丢弃** ----
#
# 为什么需要(实测教训 2026-09-27 00:4x):
#   CDP 一帧**不一定**是一个完整 JSON。`Network.requestWillBeSentExtraInfo` 事件会把
#   **整个 CookieJar** 放进 params(实测含 `XSRF-TOKEN`、`__itrace_wid` 等真凭据),
#   帧还会被 TCP 拆开 ⇒ 天真的 `ConvertFrom-Json` 单帧解析既会抛异常,
#   又会把**凭据明文打进 stderr/控制台**(违反 §4-11 与 §6-S1 的"不记录 Cookie"约束)。
#   ⇒ 本函数:①按花括号深度拼帧;②对含凭据的事件类型**在解析前就丢弃,绝不回显**。
$script:GonghaiDropEvents = @(
    'Network.requestWillBeSentExtraInfo',
    'Network.responseReceivedExtraInfo',
    'Network.eventSourceMessageReceived',
    'Network.webSocketFrameReceived',
    'Network.webSocketFrameSent',
    'Network.webSocketWillSendHandshakeRequest',
    'Network.webSocketHandshakeResponseReceived'
)

function Read-GonghaiJson {
    # 读取下一个 CDP 消息。
    #   -Mode Resp  :**只**返回带 id 的"命令响应",把所有事件(event)直接跳过。
    #                这是 Invoke-GonghaiCmd 必须用的模式:OneTalk 页面会持续喷 Network 事件,
    #                若按"丢弃若干帧"的方式找响应,帧预算会被事件吃光 ⇒ 命令超时(实测 2026-09-27)。
    #   -Mode Drain :返回事件与响应,但**静默丢弃**含凭据的事件类型(见 $GonghaiDropEvents)。
    # 超时/丢弃/非 JSON 返回 $null。
    param(
        [Parameter(Mandatory=$true)][System.Net.WebSockets.ClientWebSocket]$Ws,
        [ValidateSet('Resp','Drain')][string]$Mode = 'Resp',
        [int]$TimeoutMs = 2000
    )
    $buf = New-Object System.Text.StringBuilder
    $depth = 0
    $inStr = $false
    $esc = $false
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $chunk = $null
        try { $chunk = Receive-GonghaiJson $Ws } catch { return $null }
        if (-not $chunk) { continue }
        foreach ($ch in $chunk.ToCharArray()) {
            if ($depth -eq 0) {
                if ($ch -eq '{') { [void]$buf.Clear(); $depth = 1; $inStr = $false; $esc = $false; [void]$buf.Append($ch) }
                continue
            }
            [void]$buf.Append($ch)
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq '"') { $inStr = $false }
            } else {
                if ($ch -eq '"') { $inStr = $true }
                elseif ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') {
                    $depth--
                    if ($depth -eq 0) {
                        $jsonText = $buf.ToString()
                        [void]$buf.Clear()
                        $obj = $null
                        try { $obj = $jsonText | ConvertFrom-Json } catch { $obj = $null }
                        if (-not $obj) { continue }
                        $hasId = ($obj.PSObject.Properties.Name -contains 'id')
                        if ($Mode -eq 'Resp') {
                            # 只认命令响应;所有事件(含带凭据的)一律不进任何日志路径
                            if ($hasId) { return $obj }
                            continue
                        }
                        # Drain 模式:按**解析后的 method** 精确匹配丢弃(不做子串匹配,
                        # 否则 'Network.requestWillBeSent' 会误伤 ...ExtraInfo 之外的兄弟事件)
                        if (-not $hasId) {
                            $m = ''
                            if ($obj.PSObject.Properties.Name -contains 'method') { $m = [string]$obj.method }
                            if ($m -and ($script:GonghaiDropEvents -contains $m)) { continue }
                        }
                        return $obj
                    }
                }
            }
        }
    }
    return $null
}

function Invoke-GonghaiCmdOn {
    # 在**已有连接**上发命令(仅用于必须保持同一条连接的场景,例如 Network 事件 drain)。
    # ⚠️ 优先用 Invoke-GonghaiCmd(每次新建连接):OneTalk 会持续喷 Network 事件,
    #    长连接上帧流交错,实测会让后续命令的响应读不到 ⇒ CDP CMD TIMEOUT(2026-09-27)。
    param(
        [Parameter(Mandatory=$true)][System.Net.WebSockets.ClientWebSocket]$Ws,
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][string]$Method,
        [string]$ParamsJson = '{}',
        [int]$TimeoutMs = 25000
    )
    $json = '{"id":' + $Id + ',"method":"' + $Method + '","params":' + $ParamsJson + '}'
    Send-GonghaiJson $Ws $json
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $obj = Read-GonghaiJson -Ws $Ws -Mode Resp -TimeoutMs 2000
        if ($obj -and ($obj.PSObject.Properties.Name -contains 'id') -and $obj.id -eq $Id) { return $obj }
    }
    throw "CDP CMD TIMEOUT ($Method id=$Id)"
}

function Invoke-GonghaiCmd {
    # 发一条 CDP 命令并等它的响应:**每次新建连接**,响应拿到即断开。
    # 理由(实测 2026-09-27):OneTalk 的事件流会污染长连接,导致后续命令响应读不到;
    #   短连接是既有 scripts\cdp.ps1 的成熟做法。
    # 事件(含 CookieJar 的 ExtraInfo 事件)在 Resp 模式下解析后被跳过,绝不进入异常/日志路径。
    param(
        [Parameter(Mandatory=$true)][int]$Id,
        [Parameter(Mandatory=$true)][string]$Method,
        [string]$ParamsJson = '{}',
        [string]$UrlMatch = $script:GonghaiUrlPattern,
        [int]$TimeoutMs = 25000,
        [int]$Retry = 1
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $page = Get-GonghaiPage -UrlMatch $UrlMatch
        if (-not $page) { throw "NO_PAGE_MATCH (url pattern: $UrlMatch)" }
        $ws = Connect-GonghaiPage $page.webSocketDebuggerUrl
        try {
            return (Invoke-GonghaiCmdOn -Ws $ws -Id $Id -Method $Method -ParamsJson $ParamsJson -TimeoutMs $TimeoutMs)
        } catch {
            if ($attempt -gt $Retry -or ($_.Exception.Message -notmatch 'CDP CMD TIMEOUT')) { throw }
        } finally {
            try { $ws.Dispose() } catch { }
        }
    }
}

function Invoke-GonghaiEval {
    # 在指定页面(按 URL 匹配)执行 JS,返回字符串结果。失败抛异常,由调用方决定语义。
    # ⚠️ 与 cdp.ps1 一样:awaitPromise 需要页面上下文,JS 必须在 20s 内 resolve。
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [string]$UrlMatch = $script:GonghaiUrlPattern,
        [switch]$Any
    )
    $page = Get-GonghaiPage -UrlMatch $UrlMatch -Any:$Any
    if (-not $page) { throw "NO_PAGE_MATCH (url pattern: $UrlMatch)" }
    return (Invoke-GonghaiEvalOnPage -Page $page -Script $Script)
}

function Invoke-GonghaiEvalOnPage {
    # 与 Invoke-GonghaiEval 相同,但直接给页面对象(用于"遍历全部匹配页"的场景)。
    param(
        [Parameter(Mandatory=$true)]$Page,
        [Parameter(Mandatory=$true)][string]$Script
    )
    $ws = Connect-GonghaiPage $Page.webSocketDebuggerUrl
    try {
        $js = $Script
        if (-not $js) { throw "EMPTY SCRIPT" }
        $esc = $js.Replace('\','\\').Replace('"','\"').Replace("`n","\n").Replace("`r","\r")
        $expr = '{"expression":"' + $esc + '","returnByValue":true,"awaitPromise":true}'
        $resp = Invoke-GonghaiCmdOn -Ws $ws -Id 1 -Method "Runtime.evaluate" -ParamsJson $expr
        if ($resp.error) { throw "CDP ERROR: $($resp.error.message)" }
        if ($resp.result.exceptionDetails) {
            $t = $resp.result.exceptionDetails.text
            $v = $resp.result.exceptionDetails.exception.value
            throw "JS EXCEPTION: $t $v"
        }
        if ($null -ne $resp.result.result.value) { return [string]$resp.result.result.value }
        return "RESULT TYPE: $($resp.result.result.type)"
    } finally {
        try { $ws.Dispose() } catch { }
    }
}

function Test-GonghaiPageHealth {
    # [SPEC-公海独立Chrome 2026-09-27 §3.3] 公海自己的页面健康探针(**在公海端口上**)。
    # 为什么不能直接用 lib\cdp.ps1::Test-PageHealth:它固定走 config 的 cdp_port(9222),
    #   那是自动回复的浏览器 ⇒ 公海会拿"别人的页"当自己的健康判据(判据与对象错配)。
    # 判定复用既有纯函数 Get-PageHealthVerdict(**同一套判据**,不另写一套),
    #   只把"取页 + 求值"换成公海端口上的一次求值。
    # ⚠️ 必须传 `-Page`(见下):不传就走"按 URL 匹配取第一个 OneTalk 页",
    #    而页清单的**顺序会变** —— 实测(2026-09-27 15:07)公海实例上 public_customer 排到了 9225 的第一位,
    #    于是健康探针探到了 CRM 页(wrong-tab:...public_customer)并**误判 PageDown=True**。
    #    ⇒ 调用方手里已经有 OneTalk 页对象时,一律显式传进来。
    # ⚠️ 中文文案必须在 JS 内 btoa(encodeURIComponent) 后传输,否则 CDP 往返会破坏非 ASCII
    #    (既有实测:'已连接' -> '宸茶繛鎺')。
    # 返回与 Test-PageHealth 同形的 6 键对象(+ HasTa)。
    param($Page = $null)
    $js = @'
(function(){
  var c = document.querySelector('.connection-status-container');
  var e = document.querySelector('.connection-status-container .status-tip');
  var tip = e ? (e.innerText || '').replace(/\s+/g,' ').trim() : '';
  var tipB64 = tip ? btoa(unescape(encodeURIComponent(tip))) : '';
  return JSON.stringify({
    url: location.href.substring(0,120),
    tipB64: tipB64,
    containerH: c ? c.offsetHeight : -1,
    items: document.querySelectorAll('.contact-item-container').length,
    spin:  document.querySelectorAll('.im-conversation-list-container .im-next-icon-loading').length,
    hasTa: !!document.querySelector('textarea.send-textarea')
  });
})()
'@
    $res = ""
    try {
        if ($Page) { $res = [string](Invoke-GonghaiEvalOnPage -Page $Page -Script $js) }
        else { $res = [string](Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch)) }
    } catch { $res = "" }
    $tab = ''; $tip = ''; $items = 0; $spin = 0; $hasTa = $false; $containerH = -1
    if ($res -match '(?s)\{.*\}') {
        try {
            $o = $Matches[0] | ConvertFrom-Json
            $tab = [string]$o.url; $items = [int]$o.items; $spin = [int]$o.spin; $hasTa = [bool]$o.hasTa
            if ($o.tipB64) { $tip = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$o.tipB64)) }
            if (($o.PSObject.Properties.Name -contains 'containerH') -and $null -ne $o.containerH) { $containerH = [int]$o.containerH }
        } catch { $tab = 'PARSE-ERR' }
    } else {
        $tab = 'CDP-ERR'
    }
    # ⚠️ 判据来源必须与 monitor 同一份(lib\cdp.ps1::Get-PageHealthVerdict),否则两边会漂移。
    if (-not (Get-Command Get-PageHealthVerdict -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ PageDown=$true; Reason='verdict-fn-missing'; Items=$items; Spinner=$spin; Tab=$tab; Tip=$tip; HasTa=$hasTa }
    }
    $v = Get-PageHealthVerdict -Tab $tab -Tip $tip -Items $items -Spinner $spin -ContainerHeight $containerH
    return [pscustomobject]@{ PageDown=[bool]$v.PageDown; Reason=[string]$v.Reason; Items=$items; Spinner=$spin; Tab=$tab; Tip=$tip; HasTa=$hasTa }
}

function Get-GonghaiPageSummary {
    # 只读自述:URL(截断,防 chatToken 之类凭据外泄)+ 标题 + 关键元素计数。
    $js = @'
(function(){
  var u = location.href;
  // 只保留 origin+pathname,丢掉 query/hash(可能含 chatToken 等凭据)
  var safe = u;
  try { var x = new URL(u); safe = x.origin + x.pathname; } catch(e) {}
  return JSON.stringify({
    url: safe,
    host: location.host,
    title: (document.title || '').substring(0,120),
    rows: document.querySelectorAll('tbody tr.ant-table-row').length,
    contacts: document.querySelectorAll('.contact-item-container').length,
    tabs: document.querySelectorAll('.list-tab-item').length,
    hasTa: !!document.querySelector('textarea.send-textarea')
  });
})()
'@
    return (Invoke-GonghaiEval -Script $js -Any)
}
