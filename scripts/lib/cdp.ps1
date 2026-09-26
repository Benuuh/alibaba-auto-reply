# lib/cdp.ps1 - CDP 桥接统一封装:执行 JS / 健康探测。
# 依赖: config.ps1(Get-SkillPath "cdp")。WS 超时保护在 cdp.ps1 内(连接 15s/接收 20s)。
function Invoke-CdpEval([string]$js) {
    $cdp = Get-SkillPath "cdp"
    # 防碎参:JS 先 Base64 再传子进程(-ScriptB64),避免文本含双引号/特殊字符时
    # powershell -File -Script <内联参数> 在命令行层被拆碎导致 eval 失败(cdp.ps1 内解码)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($js))
    # [FIX-PAGESELECT 2026-09-26] 空守卫（S1-3）：cdp.ps1 的 Get-Page 现在是 URL 感知的，
    #   **没有 OneTalk 页时返回 $null**。调用方（monitor / send / doc / chrome_ensure / health_check）
    #   全部经本函数取页面上下文，故在这里统一兜底，返回一行含 `CMD ERROR` 的文本：
    #   - monitor.ps1 L1033 的既有分支 `$snapRaw -match '...|CMD ERROR'` 会命中 ⇒ CDP 自愈链自动接管；
    #   - send.ps1 因 `-notmatch 'CLICKED'` 返回 OPEN_FAIL、doc.ps1 返回 $null、health_check 当页异常处理；
    #   - **绝不**把 $null 交给上层去取 `.webSocketDebuggerUrl`（那会抛空引用，而不是走自愈）。
    $page = $null
    try { $page = Get-Page } catch { }
    if (-not $page) {
        return "CMD ERROR: no onetalk page found (url guard)"
    }
    $out = powershell -ExecutionPolicy Bypass -File $cdp -Action eval -ScriptB64 $b64 2>&1
    return ($out -join "`n")
}

function Test-CdpReady {
    try {
        $port = Get-CdpPort
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/json/version" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# [FIX-PAGESELECT 2026-09-26] 🔴 URL 感知的页面选择器（共享定义的**唯一权威**，S1-2）。
#   为什么必须在这里也定义一份（本机"同名文件陷阱"，实测）：
#     `Get-Page` 原本**只**存在于子进程桥 `scripts\cdp.ps1`；而 `scripts\lib\cdp.ps1` 与它**同名**，
#     消费者 dot-source 的是 `lib\cdp.ps1` ⇒ 本作用域里**根本没有** `Get-Page`。
#     于是 `Invoke-CdpEval` 若直接调 `Get-Page` 会抛 CommandNotFound（被 catch 吞掉后误报
#     `CMD ERROR: no onetalk page found`）⇒ 健康页也会被误判，触发无谓的 CDP 自愈。
#   所以：本函数与 `scripts\cdp.ps1::Get-Page` **必须逐字一致**（tests\page_select.tests.ps1 同时断言两处）。
#   改动实质：原实现 `Select-Object -First 1` 不校验 URL —— 任何新开的 type=page 标签页
#   （例如 BrowserSkill 的 Agent Window）都可能排在 OneTalk 之前，让 monitor 操作错误页面。
function Get-Page {
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
    # ⚠️ 本函数与 `scripts\cdp.ps1::Get-Page` **必须逐字一致**（tests\page_select.tests.ps1 断言两处一致）。
    $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 5
    $pages = $tabs | Where-Object { $_.type -eq "page" }
    $onetalk = $pages | Where-Object { $_.url -match 'onetalk\.alibaba\.com' }
    if (@($onetalk).Count -gt 0) { return @($onetalk)[0] }
    return $null
}

# [FIX-ENVBLOCK 2026-09-25] 本机进程环境块存在 3 组仅大小写不同的重复键
#   (NO_PROXY/no_proxy, https_proxy/HTTPS_PROXY, http_proxy/HTTP_PROXY)，
#   导致任何"忽略大小写的环境字典"构建失败：Start-Process 带 -RedirectStandard* 必抛
#   ArgumentException 'Item has already been added. Key in dictionary: NO_PROXY / no_proxy'，
#   Get-ChildItem env: 亦抛同类异常。实测：不带重定向则成功，带重定向必失败。
#   本函数从父进程环境块抽出条目（按忽略大小写去重），返回不含重复键的快照。
#   实测：父进程 66 条 -> 去重后 **63** 条，重复组 **0** 组。
#   注意：OrderedDictionary 用忽略大小写比较器，先 Add 者胜（后续同义键被 Contains 拦下）。
function Get-CleanEnvSnapshot {
    $snap = New-Object System.Collections.Specialized.OrderedDictionary ([System.StringComparer]::OrdinalIgnoreCase)
    $vars = [System.Environment]::GetEnvironmentVariables('Process')
    foreach ($k in @($vars.Keys)) {
        $name = [string]$k
        if (-not $snap.Contains($name)) {
            $snap[$name] = [string][System.Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
    return $snap
}

# [FIX-ENVBLOCK 2026-09-25] 用**已去重**的环境块启动子进程（已验证可用的最小机制）。
#   实测：本机 $psi.EnvironmentVariables 初始为 **0** 条 -> Clear() 安全 -> 灌入 63 条 -> 子进程启动 **exit=0**。
#   ⚠️ 重定向实现方式（执行者 2026-09-25 实测补正，spec §S2-2 标 [需实测]）：
#     本函数**支持** -RedirectStandardOutput/-RedirectStandardError，但**不用** Start-Process 实现
#     （那条路径正是抛 NO_PROXY 异常的地方），改用 .NET ProcessStartInfo.RedirectStandardOutput=$true
#     + 异步排空(ReadToEndAsync)。实测：带重定向可正常启动、exitCode 正确、stdout 可取回，
#     且因为一开始就异步排空，不会出现"子进程写满管道缓冲区后死锁"。
#     输出在子进程退出后（或等待超时后已排空完成时）以 UTF-8(无 BOM) 落盘，
#     使 agent_start / wecom_start / lib\doc 等"读子进程输出文件"的调用点行为不变。
#   ⚠️ 本函数**不做**单实例/幂等判断——调用点必须自行保留原有的 pid/幂等语义。
#   返回 System.Diagnostics.Process；调用方负责 WaitForExit / Dispose。
#   绝不打印环境变量的值（其中含代理地址等本机信息）。
function Start-ProcessClean {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$RedirectStandardOutput = '',
        [string]$RedirectStandardError = '',
        [int]$WaitSeconds = 0
    )
    $snap = Get-CleanEnvSnapshot
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = ($ArgumentList -join ' ') }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    # ⚠️ 实测坑(PowerShell 5.1 + .NET Framework,本机 2026-09-25):$psi.EnvironmentVariables 的
    #   **首次属性访问返回 $null**,第二次访问才拿到 StringDictionaryWithComparer(实测 count=58)。
    #   因此链式写法 $psi.EnvironmentVariables.Clear() 作为首次访问必抛
    #   'You cannot call a method on a null-valued expression'(见 REPORT 偏差记录)。
    #   必须"绑定变量 + 仍为空则再访问一次",否则子进程环境块会被清空成 0 条(PATH/TEMP 全丢)。
    $psiEnv = $psi.EnvironmentVariables
    if ($null -eq $psiEnv) { $psiEnv = $psi.EnvironmentVariables }
    $psiEnv.Clear()
    foreach ($k in @($snap.Keys)) { $psiEnv[[string]$k] = [string]$snap[$k] }
    $doOut = -not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)
    $doErr = -not [string]::IsNullOrWhiteSpace($RedirectStandardError)
    if ($doOut) {
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    }
    if ($doErr) {
        $psi.RedirectStandardError = $true
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $tOut = $null
    $tErr = $null
    if ($doOut) { $tOut = $p.StandardOutput.ReadToEndAsync() }
    if ($doErr) { $tErr = $p.StandardError.ReadToEndAsync() }
    if ($WaitSeconds -gt 0) { [void]$p.WaitForExit($WaitSeconds * 1000) }
    $enc = New-Object System.Text.UTF8Encoding($false)
    if ($doOut) {
        try { [void]$tOut.Wait(2000) } catch { }
        if ($tOut.IsCompleted) {
            try { [System.IO.File]::WriteAllText($RedirectStandardOutput, [string]$tOut.Result, $enc) } catch { }
        }
    }
    if ($doErr) {
        try { [void]$tErr.Wait(2000) } catch { }
        if ($tErr.IsCompleted) {
            try { [System.IO.File]::WriteAllText($RedirectStandardError, [string]$tErr.Result, $enc) } catch { }
        }
    }
    return $p
}

# [FIX-PAGEHEALTH 2026-09-25] 数据面连通性判据。
#   背景：页面横幅"网络连接已经断开"时，textarea.send-textarea **仍存在**（实测 hasTa=true），
#         因此既有的 hasTa 判据会把断连判为"已登录"；monitor 的 CDP ERROR 分支也不会命中（snapRaw 返回 '[]'），
#         导致 2026-09-25 22:24-22:56 期间业务空转 32 分钟且 health 全绿。
#
#   ⚠️ 三条硬性设计约束（全部来自本 spec 的实测，不许简化掉）：
#   (1) 传参必须走 -ScriptB64：实测 `-Js` 参数不存在；内联 JS 会被命令行层撕碎；
#       且 cdp.ps1 的 Get-Page 原为 `Select-Object -First 1`（**不校验 URL**）——[FIX-PAGESELECT 2026-09-26]
#       起已改为 URL 感知（无 OneTalk 页返回 $null），但本函数仍**自己校验 location.href**：
#       纵深防御，防止 Get-Page 的匹配被放宽或被同名文件覆盖时探到错误标签页。
#   (2) 中文文案**必须**在 JS 内 btoa(unescape(encodeURIComponent(...))) 后传输：
#       实测 CDP 往返会破坏非 ASCII（'已连接' -> '宸茶繛鎺'）。B64 通道实测可完美还原 '网络连接已经断开'。
#   (3) 判"断连"必须**同时**要求元素存在 **且** 文案匹配：
#       实测在一个干净页面注入空 <span class="status-tip">已连接</span>，仅判元素存在会返回非空 tip -> 假阳性。
#
#   返回 PSCustomObject：
#     @{ PageDown=[bool]; Reason=[string]; Items=[int]; Spinner=[int]; Tab=[string]; Tip=[string] }
#   ⚠️ 用 [pscustomobject] 而非 hashtable：hashtable 经 PowerShell 管道返回时若函数体内有
#      任何残留输出（如 Invoke-CdpEval 的回显），调用方收到的会变成**数组**，
#      此时 $r.PageDown 静默返回 $null —— 会把"判据失效"伪装成"未断连"。见附录 B/C12。
# [FIX-PAGEHEALTH2 2026-09-26] 判据抽成纯函数：把 DOM 信号 → 判定，便于表驱动单测。
#   背景（实测）：.status-tip 里"网络连接已经断开"在**重连成功后仍留在 DOM**，
#   但此时 .connection-status-container 被父级压成 offsetHeight=0（容器自带 overflow:hidden）
#   ⇒ 文案被裁掉、视觉上不存在。旧判据只看文案 ⇒ 恒误报 PageDown=True：
#   2026-09-26 11:05 monitor 因此白白 -ForceRestart 了一次 Chrome（且重启后仍判 DOWN）。
#   实测对照：陈旧残留 containerH=0（rect 0x0），同一容器在文案**可见**时为 h=15。
#   保守性：若某天容器不再被折叠（containerH>5），本函数**退回旧行为**（只看文案）——
#   最坏情况与修复前一致，不会制造新的静默失守。
function Get-PageHealthVerdict {
    param(
        [string]$Tab = '',
        [string]$Tip = '',
        [int]$Items = 0,
        [int]$Spinner = 0,
        [int]$ContainerHeight = -1      # -1 = 探针未提供该字段 ⇒ 视为"未提供"，退回旧行为
    )
    if ($Tab -notmatch 'onetalk\.alibaba\.com') { return [pscustomobject]@{ PageDown=$true; Reason="wrong-tab:$Tab" } }
    $tipDown = ($Tip -match '网络连接已经断开|连接已断开|网络异常|重新连接')
    if ($tipDown -and $ContainerHeight -le 5 -and $ContainerHeight -ge 0) {
        # tip 文案在，但容器被折叠 ⇒ 陈旧残留，不判断连。Reason 保留可追溯性。
        return [pscustomobject]@{ PageDown=$false; Reason="tip-hidden-stale" }
    }
    if ($tipDown) { return [pscustomobject]@{ PageDown=$true; Reason="tip:$Tip" } }
    if ($Spinner -gt 0 -and $Items -eq 0) { return [pscustomobject]@{ PageDown=$true; Reason="list-stalled" } }
    return [pscustomobject]@{ PageDown=$false; Reason="ok" }
}

function Test-PageHealth {
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
    containerRectH: c ? Math.round(c.getBoundingClientRect().height) : -1,
    items: document.querySelectorAll('.contact-item-container').length,
    spin:  document.querySelectorAll('.im-conversation-list-container .im-next-icon-loading').length,
    hasTa: !!document.querySelector('textarea.send-textarea')
  });
})()
'@
    $b64js = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($js))
    $cdp = Get-SkillPath "cdp"
    $res = [string]((powershell -ExecutionPolicy Bypass -NoProfile -File $cdp -Action eval -ScriptB64 $b64js 2>&1) -join "`n")

    $tab = ''; $tip = ''; $items = 0; $spin = 0; $hasTa = $false
    # [FIX-PAGEHEALTH2 2026-09-26] 可见性维度：-1 表示"探针没给这个字段"（旧探针/解析失败），
    #   此时 Get-PageHealthVerdict 退回旧行为（只看文案）。**不可**把缺失默认成 0：
    #   0 的语义是"容器被折叠"，会把"未知"误判成"陈旧残留"（静默失守方向）。
    $containerH = -1
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

    # (a)(b)(c) 判定统一由纯函数 Get-PageHealthVerdict 给出（[FIX-PAGEHEALTH2 2026-09-26]）。
    #   原来这 4 个 return 分支内联在此，无法表驱动单测；抽成纯函数后
    #   tests\page_health_verdict.tests.ps1 可覆盖 10 个用例（含"陈旧残留 tip"与"真断连 tip"的区分）。
    #   分支语义与旧实现逐条对应；唯一**行为差异**是新增可见性维度：
    #   tip 文案在、但容器被折叠(containerH<=5) ⇒ 判为陈旧残留（Reason=tip-hidden-stale），不判 down。
    #   ⚠️ 中文匹配串与旧实现**逐字一致**，不得缩短（spec §7 A23 明令）。
    $v = Get-PageHealthVerdict -Tab $tab -Tip $tip -Items $items -Spinner $spin -ContainerHeight $containerH
    # 6 键返回形状保持不变（既有 tests\page_health.tests.ps1 断言这 6 键）
    return [pscustomobject]@{ PageDown=[bool]$v.PageDown; Reason=[string]$v.Reason; Items=$items; Spinner=$spin; Tab=$tab; Tip=$tip }
}

# [FIX-DAEMONLAUNCH 2026-09-25] 取回由 Start-DaemonClean 拉起的**真实守护进程** pid。
#   为什么需要：Start-DaemonClean 返回的是 .bat 包装层（cmd.exe）的 Process 对象，
#   其 Id ≠ 守护进程（node）的 pid。原来用 Start-Process -PassThru 时 $p.Id 就是 node 的 pid，
#   直接换成包装层 pid 会破坏调用点的单实例判断（Get-PidFileProcess 按 node+命令行校验）。
#   用法：Get-DaemonProcessId -FilePath 'node.exe' -Needle $script:entryJs
function Get-DaemonProcessId {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string]$Needle
    )
    $leaf = [System.IO.Path]::GetFileName($FilePath)
    $hit = @(Get-CimInstance Win32_Process -Filter "Name='$leaf'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Needle) })
    if ($hit.Count -gt 0) { return [int]$hit[0].ProcessId }
    return 0
}

# [FIX-DAEMONLAUNCH 2026-09-25] 长驻守护进程的启动器（真实文件句柄重定向 + 脱离存活）。
#
#   ⚠️ 本函数**没有**采用 spec §6-S2-2 原设计的"同步泵送"。原因：经本轮 5 组对照实测，
#      原设计对"永不退出的 node 守护进程"**不可用，且会杀死守护进程**：
#     (1) $p.StandardOutput.EndOfStream 在"管道开着但暂时无数据"时**会阻塞**（实测：
#         子进程写 1 行后睡 8s → EndOfStream 实测阻塞 8s 才返回）。因此 ReadLine/EndOfStream
#         泵送循环会一直卡到子进程退出，拿不到"泵 N 秒即返回"；实测 Start-DaemonClean(原实现)
#         在 PumpSeconds=6 时实际耗时 = 子进程全程 25s。
#     (2) "父进程泵一段后退出"这一模式本身会杀死守护进程：实测 Process.Start +
#         RedirectStandardOutput=$true 启动的 node 守护进程，在启动器退出后 2 秒内死亡
#         （管道读端关闭 → 子进程写 stdout 触发 EPIPE/IOException）。
#     (3) spec D2 观察到的"泵 4s 后返回且子进程仍存活"实为误判：真实耗时≈子进程全程，
#         子进程"存活"只是因为它还没退出，而非已脱离。
#     ⇒ 若照原设计落地，wecom-connector 一旦重启就会起不来（**告警通道整条丢失**），
#       比 B-03 原缺陷更严重。故此处改用下面已验证的启动模式。
#
#   ✅ 本实现（实测：守护进程在启动器退出后 14s 仍存活，日志从启动首行起持续落盘）：
#     ① 把启动命令写进一个临时 .bat：`"<exe>" <args> > "<log>" 2> "<err>"`
#        —— 重定向由 cmd 以**真实文件句柄**完成，全程不使用管道 ⇒ 无 EPIPE、无阻塞、无 NO_PROXY；
#        —— 同时天然解决"参数含空格/引号"的转义问题（不依赖 $psi.Arguments 的裸 join）。
#     ② 用 Start-Process -WindowStyle Hidden（**不带** -RedirectStandard*）启动该 .bat，
#        子进程脱离启动器独立存活（实测 14s 后仍存活）。
#     ③ 短暂等待：确认日志文件已创建，并按命令行匹配精确取回真实 node pid 写入 .pid 标记，
#        然后**立即返回**，不等待守护进程退出。
#   返回 .bat 包装层的 Process 对象（已启动，未等待退出）。
#   ⚠️ 不做单实例/幂等判断——调用点必须自行保留原有的 pid/幂等语义。
function Start-DaemonClean {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory=$true)][string]$LogPath,
        [string]$ErrPath = '',
        [int]$PumpSeconds = 5
    )
    if (-not $ErrPath) { $ErrPath = $LogPath + '.err' }

    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    # 参数转义：每个参数一律加双引号并转义内部双引号
    #   ⚠️ 先剥掉调用方可能已加的外层双引号（spec 的两处调用点示范了 '"' + $path + '"' 写法，
    #      若不剥掉会生成 ""path"" 的双层引号；两种写法都必须可用）
    $inner = '"' + ([string]$FilePath).Trim('"') + '"'
    foreach ($a in @($ArgumentList)) {
        if ($null -eq $a -or [string]::IsNullOrWhiteSpace([string]$a)) { continue }
        $av = ([string]$a).Trim('"')
        $inner = $inner + ' "' + $av.Replace('"', '\"') + '"'
    }

    $stamp = [System.IO.Path]::GetFileNameWithoutExtension($FilePath) + '_' + ([guid]::NewGuid().ToString('N').Substring(0,8))
    $batPath = Join-Path $logDir ($stamp + '.launch.bat')
    $pidPath = Join-Path $logDir ($stamp + '.launch.pid')
    Remove-Item $pidPath -Force -EA SilentlyContinue

    $batLines = @(
        '@echo off',
        ($inner + ' > "' + $LogPath + '" 2> "' + $ErrPath + '"')
    )
    [System.IO.File]::WriteAllLines($batPath, $batLines, (New-Object System.Text.UTF8Encoding($false)))

    $p = Start-Process -FilePath $batPath -WindowStyle Hidden -PassThru

    # 按命令行精确取回真实目标进程 pid（用于 pid 文件/日志），并在等待窗口内确认日志已创建
    $leaf = [System.IO.Path]::GetFileName($FilePath)
    $needle = ''
    if (@($ArgumentList).Count -gt 0) { $needle = [string]@($ArgumentList)[0] }
    $targetProc = $null
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $PumpSeconds))
    while ((Get-Date) -lt $deadline) {
        if (-not $targetProc -and $needle) {
            $cand = @(Get-CimInstance Win32_Process -Filter "Name='$leaf'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) })
            if ($cand.Count -gt 0) { $targetProc = $cand[0] }
        }
        # 等到"目标进程已起 + 日志已开始落盘"再返回（日志为空时继续等，避免调用方读到空日志）
        $logHasContent = $false
        if (Test-Path $LogPath) {
            try { $logHasContent = ((Get-Item $LogPath -ErrorAction SilentlyContinue).Length -gt 0) } catch {}
        }
        if ($logHasContent -and $targetProc) { break }
        Start-Sleep -Milliseconds 250
    }
    if ($targetProc) { Set-Content -Path $pidPath -Value $targetProc.ProcessId -Encoding ASCII -EA SilentlyContinue }
    return $p
}

# [FIX-THROTTLE 2026-09-26] 自愈升级节流判定（纯函数，便于单测）。
#   背景（实测 2026-09-26 00:06-00:16）：升级周期 90 秒 < 页面建连所需时间（>30 秒），
#   导致每 90 秒杀掉 Chrome 一次、页面只有约 18 秒建连 ⇒ 自伤循环；且无退避、无上限（11 分钟 8 次）。
#   本函数只做判定，不做任何副作用（不重启、不写文件）——便于纯逻辑测试。
#
#   参数：
#     $Streak          当前 PAGE-DOWN 连续轮次
#     $Restarts        本轮已累计的 FORCE-RESTART 次数
#     $QuietUntil      静默期截止时间（DateTime 或 $null）
#     $Now             当前时间（便于测试注入）
#     $MaxRestarts     硬上限（默认 4）
#   返回：@{ Action='none'|'reload'|'restart'|'alert-only'; Reason=<string>; NextQuietSec=<int> }
function Get-PageHealAction {
    param(
        [int]$Streak,
        [int]$Restarts,
        [object]$QuietUntil = $null,
        [datetime]$Now = (Get-Date),
        [int]$MaxRestarts = 4
    )
    # 1) 静默期：期内一律不升级（只让调用方继续探测）
    if ($QuietUntil -and $Now -lt [datetime]$QuietUntil) {
        return @{ Action='none'; Reason=('quiet-until ' + ([datetime]$QuietUntil).ToString('HH:mm:ss')); NextQuietSec=0 }
    }
    # 2) 硬上限：超过则只告警，永不重启
    if ($Restarts -ge $MaxRestarts) {
        return @{ Action='alert-only'; Reason=("max-restarts-reached $Restarts/$MaxRestarts"); NextQuietSec=0 }
    }
    # 3) 退避阶梯：第 1、2 次重启门槛为 3 轮；第 3 次 6 轮；第 4 次 12 轮
    $need = 3
    if ($Restarts -eq 2) { $need = 6 }
    elseif ($Restarts -ge 3) { $need = 12 }
    if ($Streak -lt $need) {
        # 未到重启门槛：给一次轻量 reload（仅当 streak>=2）
        if ($Streak -ge 2) { return @{ Action='reload'; Reason=("streak $Streak < need $need"); NextQuietSec=0 } }
        return @{ Action='none'; Reason=("streak $Streak too low"); NextQuietSec=0 }
    }
    return @{ Action='restart'; Reason=("streak $Streak >= need $need (restart #" + ($Restarts+1) + ")"); NextQuietSec=600 }
}
