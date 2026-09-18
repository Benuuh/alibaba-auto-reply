# lib/accio.ps1 - Accio 网关适配层(PS 封装)。
# 原则:失败一律返回 $null/空并写日志,由调用方回退 CDP;不打印任何鉴权值。
# 依赖: config.ps1(Get-SkillPath/Get-SkillConfig) + lib\log.ps1(Write-SkillLog) + tools\accio-client\cli.js。
if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "..\config.ps1") }
if (-not (Get-Command Write-SkillLog -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "log.ps1") }

$script:AccioCliPath = Join-Path (Get-SkillPath "") "tools\accio-client\cli.js"
$script:AccioLogFile = $null
$script:AccioNodeExe = $null
$script:AccioGatewayCache = $null      # @{ ok=[bool]; at=[datetime] }
$script:AccioConvCache = $null         # @{ at=[datetime]; list=@() }
$script:AccioInfoCache = $null         # @{ at=[datetime]; mtime=[datetime]; info=@{url;pid;relayPort} }
# F7(2026-09-15 停摆根因修复):AUTH-REQUIRED 负缓存。Accio 桌面应用更新/重启期间网关会返回
# AUTH-REQUIRED,旧实现每轮都重新探测并失败(浪费轮次时间 + 把日志刷成噪声)。命中后 5 分钟内不再探测,
# 直接返回 $null 走 CDP 回退(设计内行为,回复不受影响)。
$script:AccioAuthBlocked = $null       # @{ at=[datetime]; until=[datetime]; code=[string] }
$script:AccioAuthBlockSec = 300
$script:AccioAuthSkipLoggedAt = $null  # ACCIO-AUTH-SKIP 日志节流(≥60s 一行)
# 供 status.ps1 巡检:最近一次 AUTH-REQUIRED 的时间
function Get-AccioAuthState {
    if ($script:AccioAuthBlocked) { return $script:AccioAuthBlocked }
    return $null
}
# F7:把鉴权状态落盘(logs\accio_auth_state.json),使 status.ps1 等独立进程可观测,
# 并让负缓存跨 monitor 重启依然生效。
function Save-AccioAuthState([object]$state) {
    try {
        $dir = Get-SkillPath "logs"
        if (-not $dir) { return }
        $f = Join-Path $dir "accio_auth_state.json"
        if (-not $state) { Remove-Item $f -Force -ErrorAction SilentlyContinue; return }
        @{ at = $state.at.ToString('yyyy-MM-dd HH:mm:ss'); until = $state.until.ToString('yyyy-MM-dd HH:mm:ss'); code = $state.code } |
            ConvertTo-Json | Set-Content -Path $f -Encoding UTF8
    } catch {}
}
# 启动时恢复上次的负缓存(仅在仍未过期时)
function Restore-AccioAuthState {
    try {
        $dir = Get-SkillPath "logs"
        if (-not $dir) { return }
        $f = Join-Path $dir "accio_auth_state.json"
        if (-not (Test-Path $f)) { return }
        $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j.until) { return }
        $until = [datetime]::Parse([string]$j.until)
        if ($until -gt (Get-Date)) {
            $script:AccioAuthBlocked = @{ at = [datetime]::Parse([string]$j.at); until = $until; code = [string]$j.code }
        } else {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Set-AccioLogFile([string]$Path) { $script:AccioLogFile = $Path }
function Write-AccioLog([string]$msg) { if ($script:AccioLogFile) { Write-SkillLog $msg $script:AccioLogFile } }

function Get-AccioNodeExe {
    if ($script:AccioNodeExe) { return $script:AccioNodeExe }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:AccioNodeExe = $cmd.Source } else { $script:AccioNodeExe = "node.exe" }
    return $script:AccioNodeExe
}

# 读取开关(config.json;默认全 false)
function Get-AccioFlags([object]$Cfg = $null) {
    if (-not $Cfg) { $Cfg = Get-SkillConfig }
    $shadow = $false; $read = $false; $send = $false
    if ($Cfg) {
        if ($Cfg.PSObject.Properties.Name -contains 'accio_shadow' -and $Cfg.accio_shadow) { $shadow = $true }
        if ($Cfg.PSObject.Properties.Name -contains 'accio_read_enabled' -and $Cfg.accio_read_enabled) { $read = $true }
        if ($Cfg.PSObject.Properties.Name -contains 'accio_send_enabled' -and $Cfg.accio_send_enabled) { $send = $true }
    }
    return @{ shadow = $shadow; read = $read; send = $send }
}

# 读取 gateway-cli.json 的 非敏感 信息(url/pid/relayPort),按文件 mtime 缓存;凭据值不读取回显。
function Get-AccioGatewayInfo([switch]$Force) {
    $now = Get-Date
    $files = @(Get-ChildItem (Join-Path $env:USERPROFILE ".accio\accounts\*\.accio\runtime\gateway-cli.json") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { $script:AccioInfoCache = $null; return $null }
    $f = $files[0]
    if (-not $Force -and $script:AccioInfoCache -and $script:AccioInfoCache.mtime -eq $f.LastWriteTime) { return $script:AccioInfoCache.info }
    try {
        $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $info = @{ url = [string]$j.url; pid = $j.pid; relayPort = $j.relayPort; file = $f.FullName }
        $script:AccioInfoCache = @{ at = $now; mtime = $f.LastWriteTime; info = $info }
        return $info
    } catch {
        Write-AccioLog "ACCIO-CONFIG-ERR: $($_.Exception.Message)"
        return $null
    }
}

# 网关可用性探测: Accio 进程存在 + 网关端口 TCP 可达。结果缓存 60s。
function Test-AccioGateway([switch]$Force) {
    $now = Get-Date
    if (-not $Force -and $script:AccioGatewayCache -and (($now - $script:AccioGatewayCache.at).TotalSeconds -lt 60)) {
        return $script:AccioGatewayCache.ok
    }
    $ok = $false
    try {
        $proc = @(Get-Process -Name Accio -ErrorAction SilentlyContinue)
        if ($proc.Count -gt 0) {
            $info = Get-AccioGatewayInfo
            if ($info -and $info.url) {
                $u = [uri]$info.url
                $port = if ($u.Port -gt 0) { $u.Port } else { 80 }
                $client = New-Object System.Net.Sockets.TcpClient
                $iar = $client.BeginConnect($u.Host, $port, $null, $null)
                if ($iar.AsyncWaitHandle.WaitOne(1500, $false) -and $client.Connected) { $ok = $true }
                $client.Close()
            }
        }
    } catch { $ok = $false }
    $script:AccioGatewayCache = @{ ok = $ok; at = $now }
    return $ok
}

# Windows argv 引号转义(CommandLineToArgvW 规则)
function ConvertTo-AccioCliArg([string]$a) {
    if ($a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# 调用 Node CLI;返回解析后的 JSON 对象(ok=false 或异常 → $null + 日志)
function Invoke-AccioCli([string[]]$CliArgs, [int]$TimeoutMs = 120000) {
    if (-not (Test-Path $script:AccioCliPath)) { Write-AccioLog "ACCIO-CLI-MISSING: $($script:AccioCliPath)"; return $null }
    $node = Get-AccioNodeExe
    $argLine = (@($script:AccioCliPath) + $CliArgs) | ForEach-Object { ConvertTo-AccioCliArg $_ }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node
    $psi.Arguments = ($argLine -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            Write-AccioLog "ACCIO-TIMEOUT: cli $($CliArgs -join ' ') exceeded ${TimeoutMs}ms"
            return $null
        }
        $out = $outTask.Result
        $err = $errTask.Result
        $obj = $null
        $jsonErr = $null
        try { $obj = $out | ConvertFrom-Json } catch { $jsonErr = $_ }
        if ($null -eq $obj) {
            # 单行化:JSON 换行压成空格,附 ConvertFrom-Json 异常原因,整体截断 200 字符(日志行 ≤250)
            $detail = (($err + ' ' + $out) -replace '\s+',' ').Trim()
            if ($jsonErr) {
                $jm = ''
                try { $jm = [string]$jsonErr.Exception.Message } catch { $jm = [string]$jsonErr }
                $detail = ($detail + ' jsonErr=' + ($jm -replace '\s+',' ')).Trim()
            }
            if ($detail.Length -gt 200) { $detail = $detail.Substring(0,200) }
            Write-AccioLog ("ACCIO-PARSE-ERR: " + $detail)
            return $null
        }
        if ($obj.PSObject.Properties.Name -contains 'ok' -and -not $obj.ok) {
            $code = 'UNKNOWN'
            if ($obj.error -and $obj.error.code) { $code = [string]$obj.error.code }
            if ($code -eq 'AUTH-REQUIRED') {
                # F7:命中鉴权失败 → 记负缓存并只写一行(去重,避免每轮刷屏)
                $wasBlocked = $false
                if ($script:AccioAuthBlocked -and $script:AccioAuthBlocked.until -gt (Get-Date)) { $wasBlocked = $true }
                $script:AccioAuthBlocked = @{ at = (Get-Date); until = (Get-Date).AddSeconds($script:AccioAuthBlockSec); code = $code }
                Save-AccioAuthState $script:AccioAuthBlocked
                if (-not $wasBlocked) {
                    Write-AccioLog "ACCIO-ERR: $($CliArgs[0]) code=$code -> negative-cache ${script:AccioAuthBlockSec}s (fallback CDP; 需在 Accio 桌面应用重新登录才能恢复直读)"
                }
            } else {
                Write-AccioLog "ACCIO-ERR: $($CliArgs[0]) code=$code"
            }
            return $null
        }
        return $obj
    } catch {
        Write-AccioLog "ACCIO-CLI-ERR: $($_.Exception.Message)"
        return $null
    } finally {
        if ($p) { $p.Dispose() }
    }
}

# 会话列表(默认缓存 300s;force 忽略缓存)
function Get-AccioConversations([int]$Pages = 5, [int]$Count = 50, [switch]$Force) {
    $now = Get-Date
    if (-not $Force -and $script:AccioConvCache -and (($now - $script:AccioConvCache.at).TotalSeconds -lt 300)) {
        return $script:AccioConvCache.list
    }
    # F7:鉴权负缓存生效期内不再探测,直接回退 CDP(每轮只留一行去重日志)
    if (-not $Force -and $script:AccioAuthBlocked -and $script:AccioAuthBlocked.until -gt $now) {
        $leftSec = [int](($script:AccioAuthBlocked.until - $now).TotalSeconds)
        if (-not $script:AccioAuthSkipLoggedAt -or ((Get-Date) - $script:AccioAuthSkipLoggedAt).TotalSeconds -ge 60) {
            Write-AccioLog "ACCIO-AUTH-SKIP: AUTH-REQUIRED negative-cache active (${leftSec}s left, last=$($script:AccioAuthBlocked.at.ToString('yyyy-MM-dd HH:mm:ss'))) - skip conversations probe, fallback CDP"
            $script:AccioAuthSkipLoggedAt = Get-Date
        }
        return $null
    }
    if (-not (Test-AccioGateway)) { return $null }
    $obj = Invoke-AccioCli @('conversations', '--pages', "$Pages", '--count', "$Count")
    if (-not $obj) { return $null }
    $list = @($obj.conversations)
    $script:AccioConvCache = @{ at = $now; list = $list }
    return $list
}

# 买家名归一化键(大小写/多空格不敏感;CDP 与网关显示名可能略有差异)
function Get-AccioNameKey([string]$name) {
    if (-not $name) { return '' }
    return (($name -replace '\s+', ' ').Trim().ToLower())
}

# 会话映射表: 买家显示名(归一化键) → @{conversationId; contactAliId; selfAliId; unread}(同名取最新)
function Get-AccioConversationMap([switch]$Force) {
    $convs = Get-AccioConversations -Force:$Force
    if (-not $convs) { return $null }
    $map = @{}
    foreach ($c in $convs) {
        $name = Get-AccioNameKey ([string]$c.contactName)
        if (-not $name) { continue }
        $self = $null
        try {
            $cid = [string]$c.conversationId
            $contact = [string]$c.contactAliId
            $base = ($cid -split '#')[0]
            $parts = $base -split '-'
            if ($parts.Count -eq 2 -and $contact) {
                if ($parts[0] -eq $contact) { $self = [long]$parts[1] } elseif ($parts[1] -eq $contact) { $self = [long]$parts[0] }
            }
        } catch {}
        $entry = @{ conversationId = [string]$c.conversationId; contactAliId = $c.contactAliId; selfAliId = $self; unread = $c.unreadMessageCount; latestSendTime = $c.latestSendTime }
        if ($map.ContainsKey($name)) {
            $old = $map[$name]
            if (($entry.latestSendTime -as [long]) -gt ($old.latestSendTime -as [long])) { $map[$name] = $entry }
        } else {
            $map[$name] = $entry
        }
    }
    return $map
}

# 历史消息(全量;可选 limit 取最新 N 条)
function Get-AccioMessages([string]$ConversationId, [long]$SelfAliId = 0, [int]$Limit = 0, [int]$TimeoutMs = 90000) {
    if (-not (Test-AccioGateway)) { return $null }
    $cliArgs = @('messages', '--conversation', $ConversationId, '--timeout-ms', "$TimeoutMs")
    if ($SelfAliId -gt 0) { $cliArgs += @('--self', "$SelfAliId") }
    if ($Limit -gt 0) { $cliArgs += @('--limit', "$Limit") }
    $obj = Invoke-AccioCli $cliArgs -TimeoutMs ($TimeoutMs + 30000)
    if (-not $obj) { return $null }
    return @($obj.messages)
}

# 归一化文本(比对用):去标签/去时间戳/压缩空白
function Get-AccioNormText([string]$line) {
    if ($null -eq $line) { return '' }
    $t = $line -replace '^\[(BUYER|ME)\]\s*', ''
    $t = $t -replace '@@TS:[^\s]*\s*$', ''
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# 解析时间戳(epoch ms 或 日期字符串) → epoch ms / $null
function ConvertFrom-AccioTs([string]$ts) {
    if (-not $ts) { return $null }
    $t = $ts.Trim()
    if ($t -match '^\d{10,13}$') {
        $n = [long]$t
        if ($n -lt 10000000000) { $n = $n * 1000 }
        return $n
    }
    try {
        $dt = [datetime]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture)
        return [long](([DateTimeOffset]$dt).ToUnixTimeMilliseconds())
    } catch { return $null }
}

# 网关消息 → 现有 [BUYER]/[ME] 行格式(最新在前,与 CDP 提取顺序一致)
function ConvertTo-ReplyLines([object[]]$Messages, [long]$SelfAliId = 0) {
    if (-not $Messages) { return @() }
    $sorted = @($Messages | Sort-Object -Property @{ Expression = { if ($_.timestamp) { [long]$_.timestamp } else { 0 } } } -Descending)
    $lines = New-Object System.Collections.ArrayList
    foreach ($m in $sorted) {
        $text = [string]$m.content
        if (-not $text) { continue }
        $text = ($text -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
        if (-not $text) { continue }
        $isUs = $false
        if ($SelfAliId -gt 0 -and $m.senderAliId) { $isUs = ([long]$m.senderAliId -eq $SelfAliId) }
        $who = if ($isUs) { '[ME]' } else { '[BUYER]' }
        $ts = ''
        if ($m.timestamp) { $ts = ' @@TS:' + [long]$m.timestamp }
        [void]$lines.Add("$who $text$ts")
    }
    return $lines.ToArray()
}

# 取某买家的网关回复上下文行(失败返回 $null)
function Get-AccioReplyLines([string]$Buyer, [int]$Limit = 200) {
    $map = Get-AccioConversationMap
    $nameKey = Get-AccioNameKey $Buyer
    if (-not $map -or -not $map.ContainsKey($nameKey)) { Write-AccioLog "ACCIO-READ-FAIL: $Buyer not in gateway map"; return $null }
    $entry = $map[$nameKey]
    $msgs = Get-AccioMessages -ConversationId $entry.conversationId -SelfAliId ([long]$entry.selfAliId) -Limit $Limit
    if ($null -eq $msgs) { return $null }
    return ,(ConvertTo-ReplyLines $msgs ([long]$entry.selfAliId))
}

# 模糊行匹配(CDP DOM 含 UI 杂质/翻译差异;仅用于影子统计,不参与行为)
function Test-AccioLineMatch([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    $x = $a.ToLower(); $y = $b.ToLower()
    if ($x -eq $y) { return $true }
    if ($x.Length -ge 6 -and $y.Contains($x)) { return $true }
    if ($y.Length -ge 6 -and $x.Contains($y)) { return $true }
    $tx = @($x -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 2 })
    $ty = @($y -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 2 })
    if ($tx.Count -eq 0 -or $ty.Count -eq 0) { return $false }
    $inter = 0; foreach ($t in $tx) { if ($ty -contains $t) { $inter++ } }
    return (($inter / [Math]::Max($tx.Count, $ty.Count)) -ge 0.6)
}

# 内容重叠校验: CDP 最新买家行能否在网关行中找到(防同名多线程会话取错上下文)
function Test-AccioLinesOverlap([string[]]$CdpLines, [string[]]$GwLines) {
    if (-not $CdpLines -or -not $GwLines) { return $false }
    $cdpLatest = ''
    foreach ($c in $CdpLines) { if ($c -match '^\[BUYER\]') { $cdpLatest = Get-AccioNormText $c; break } }
    if (-not $cdpLatest) { return $true }  # 无买家行可校验,放行
    foreach ($g in $GwLines) { if (Test-AccioLineMatch $cdpLatest (Get-AccioNormText $g)) { return $true } }
    return $false
}

# 影子对比: 条数/最新买家消息/时间戳一致性 + CDP 覆盖率(模糊),仅写日志不改行为
function Invoke-AccioShadowCompare([string]$Buyer, [string[]]$CdpLines, [string[]]$GwLines) {
    $cdpN = @($CdpLines).Count
    $gwN = @($GwLines).Count
    $latest = 'na'; $tsCmp = 'na'; $cov = 'na'
    if ($cdpN -gt 0 -and $gwN -gt 0) {
        # 最新"买家"行(CDP 第 0 条即最新;取最近一条买家消息)
        $cdpLatest = ''
        foreach ($c in $CdpLines) { if ($c -match '^\[BUYER\]') { $cdpLatest = Get-AccioNormText $c; break } }
        $gwTexts = @($GwLines | ForEach-Object { Get-AccioNormText $_ })
        $hitIdx = -1
        if ($cdpLatest) {
            for ($i = 0; $i -lt $gwTexts.Count; $i++) { if (Test-AccioLineMatch $cdpLatest $gwTexts[$i]) { $hitIdx = $i; break } }
        }
        $latest = if ($hitIdx -ge 0 -or -not $cdpLatest) { 'match' } else { 'mismatch' }
        # 时间戳: CDP 最新买家行 ts vs 网关匹配行 ts(容差 120s;CDP ts 为渲染时间时可能偏大,只作参考)
        if ($hitIdx -ge 0) {
            $cTs = $null; $gTs = $null
            foreach ($c in $CdpLines) { if ($c -match '^\[BUYER\].*@@TS:([^\s]+)') { $cTs = ConvertFrom-AccioTs $Matches[1]; break } }
            if ($GwLines[$hitIdx] -match '@@TS:([^\s]+)') { $gTs = ConvertFrom-AccioTs $Matches[1] }
            if ($cTs -and $gTs) { $tsCmp = if ([Math]::Abs($cTs - $gTs) -le 120000) { 'match' } else { 'mismatch' } }
        }
        $hit = 0
        foreach ($c in $CdpLines) {
            $n = Get-AccioNormText $c
            if (-not $n) { continue }
            $found = $false
            foreach ($g in $gwTexts) { if (Test-AccioLineMatch $n $g) { $found = $true; break } }
            if ($found) { $hit++ }
        }
        $cov = if ($cdpN -gt 0) { "$([int](100 * $hit / $cdpN))%" } else { 'na' }
    }
    Write-AccioLog "ACCIO-SHADOW ${Buyer}: cdp=$cdpN gw=$gwN latest=$latest ts=$tsCmp cov=$cov"
}

# 发送(仅 Phase 4 用户指定测试会话;调用方负责回读验证)
function Send-AccioMessage([string]$ConversationId, [long]$BuyerAliId, [long]$SelfAliId, [string]$Text, [int]$TimeoutMs = 30000) {
    if (-not (Test-AccioGateway)) { Write-AccioLog "ACCIO-SEND-FAIL: gateway unavailable"; return $null }
    $cliArgs = @('send', '--conversation', $ConversationId, '--to', "$BuyerAliId", '--self', "$SelfAliId", '--text', $Text, '--yes', '--timeout-ms', "$TimeoutMs")
    $obj = Invoke-AccioCli $cliArgs -TimeoutMs ($TimeoutMs + 30000)
    return $obj
}
