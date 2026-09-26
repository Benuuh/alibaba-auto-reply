# lib/no_reply.ps1 - 人工接管白名单(指定买家不自动回复)统一读取与匹配
# 名单文件: data\manual_override.json(JSON 字符串数组,条目为已归一买家名;本机 PII,gitignore 不入库)
# 归一化契约: trim → ToLowerInvariant → '_'→' ' → 连续空白压单空格(顺序冻结,勿改)。
#   原先与 tools\control-agent\agent_bridge.js 的 normCustomer 逐字同构;该组件已于 2026-09-26
#   退休并**物理移除**(见 docs\KNOWN_EXCEPTIONS.md E-20/E-24)⇒ 本文件即名单读写侧的**唯一实现**,
#   不再有"双侧同步"的对象。改动归一化顺序会使既有名单(已归一买家名)全部失配。
# 容错: 文件缺失/损坏/非数组 → 视为空名单,绝不抛错(每路径 WARN 一次)
# 用法: . lib\no_reply.ps1; Test-NoReplyBuyer 'John Smith'
# 依赖: 本库不强制 dot-source config.ps1;Get-SkillPath 可用时经其取 data 目录,
#       否则回退 <部署根>\data(由 PSScriptRoot=scripts\lib 推导)

# 归一化: trim → 小写 → '_'→' ' → 连续空白压单空格(原与已移除的 agent_bridge.js normCustomer 一致，顺序冻结)
function ConvertTo-NoReplyKey([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $t = $s.Trim()
    $t = $t.ToLowerInvariant()
    $t = $t.Replace('_', ' ')
    $t = [regex]::Replace($t, '\s+', ' ')
    $t = $t.Trim()
    return $t
}

$script:__noReplyCache = @{}     # path -> @{ raw=文件原始内容; list=@() }(内容级缓存:同 tick 内两次写入 mtime 相同也不会读到旧名单)
$script:__noReplyWarned = @{}    # path -> $true(损坏/缺失仅 WARN 一次)

# 读名单: 内容级缓存(文件内容变化立即失效,便于测试与即时编辑;文件极小,每调用重读开销可忽略)
function Get-NoReplyList([string]$Path = "") {
    if (-not $Path) {
        if (Get-Command Get-SkillPath -ErrorAction SilentlyContinue) {
            $Path = Join-Path (Get-SkillPath "data") "manual_override.json"
        } else {
            $root = Join-Path (Split-Path $PSScriptRoot -Parent) "..\data"
            $Path = Join-Path $root "manual_override.json"
        }
    }
    $exists = Test-Path $Path
    $raw = ""
    if ($exists) {
        try { $raw = Get-Content $Path -Raw -Encoding UTF8 } catch { $raw = "" }
        if ($null -eq $raw) { $raw = "" }
    }
    if ($script:__noReplyCache.ContainsKey($Path)) {
        $c = $script:__noReplyCache[$Path]
        if ($c.raw -eq $raw) { return $c.list }
    }
    $list = @()
    if (-not $exists) {
        if (-not $script:__noReplyWarned.ContainsKey($Path)) {
            $script:__noReplyWarned[$Path] = $true
            Write-Warning "no_reply: $Path 不存在,按空名单处理"
        }
    } elseif (-not $raw) {
        if (-not $script:__noReplyWarned.ContainsKey($Path)) {
            $script:__noReplyWarned[$Path] = $true
            Write-Warning "no_reply: $Path 读取失败,按空名单处理"
        }
    } else {
        try {
            $arr = $raw | ConvertFrom-Json
            if ($arr -is [System.Array]) {
                foreach ($e in $arr) {
                    $nk = ConvertTo-NoReplyKey ([string]$e)
                    if (-not $nk) { continue }
                    $dup = $false
                    foreach ($x in $list) { if ([string]::Equals($x, $nk, [System.StringComparison]::Ordinal)) { $dup = $true; break } }
                    if (-not $dup) { $list += $nk }
                }
            } elseif (-not $script:__noReplyWarned.ContainsKey($Path)) {
                $script:__noReplyWarned[$Path] = $true
                Write-Warning "no_reply: $Path 非 JSON 数组,按空名单处理"
            }
        } catch {
            if (-not $script:__noReplyWarned.ContainsKey($Path)) {
                $script:__noReplyWarned[$Path] = $true
                Write-Warning "no_reply: $Path 读取失败,按空名单处理"
            }
        }
    }
    $script:__noReplyCache[$Path] = @{ raw = $raw; list = $list }
    return $list
}

# 匹配: 对传入会话名执行同一归一后与条目精确相等(Ordinal);空白名恒 False;Path 可显式指定名单文件(测试/注入)
function Test-NoReplyBuyer([string]$Name, [string]$Path = "") {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $k = ConvertTo-NoReplyKey $Name
    if (-not $k) { return $false }
    foreach ($e in (Get-NoReplyList -Path $Path)) {
        if ([string]::Equals($e, $k, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

# ============================================================================
# 写侧（2026-09-26 新增）——人工接管名单的"增/删/查"
#
# 背景：名单**写侧**原先只存在于 tools\control-agent\agent_bridge.js 的 handleWhitelistCmd
#   （L66 注释原文："白名单管理指令(硬编码直处理,不经外部 agent/确认闸门)"），
#   它靠轮询旧企微桥 127.0.0.1:19886 收指令。该桥已于 2026-09-26 停用（与 dsh-im 抢同一
#   企微机器人会互踢）⇒ **写侧随之失效，但读侧匹配一直在 monitor/nudge/quote 里正常工作**。
#   本段把写侧搬到 PowerShell 侧，读侧一行未动，因此**不影响任何自动回复判定**。
#   [2026-09-26 收口] agent_bridge.js 及其所在目录已随两套退休告警桥一并**物理移除**
#   （见 docs\KNOWN_EXCEPTIONS.md E-20/E-24）⇒ 本段是名单读写侧的**唯一实现**。
#
# 历史契约（agent_bridge.js 已移除 ⇒ 不再有"双侧同步"对象，下列映射仅作溯源，格式与顺序冻结勿改）：
#   normCustomer  → ConvertTo-NoReplyKey        （trim → lower → '_'→' ' → 压空白）
#   写文件        → Save-NoReplyList            （JSON 数组；**LF + 2 空格缩进 + 结尾 \\n + 无 BOM**）
#   指令正则      → 见 scripts\whitelist.ps1    （^(白名单|whitelist) (添加|删除|列表|add|remove|list) …）
#
# ⚠️ 格式必须逐字节对齐 Node：PS 的 ConvertTo-Json 默认产出 CRLF + 4 空格缩进，
#    与 JSON.stringify(list,null,2)+'\\n' 不同（实测 43B vs 36B）⇒ 必须做换行与缩进归一。
# ============================================================================

# 写名单（内部）:与已移除的 agent_bridge.js saveWhitelist 逐字节同格式（格式冻结，勿改）
function Save-NoReplyList([string]$Path, [string[]]$List) {
    if (-not $Path) { throw "Save-NoReplyList: Path required" }
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $arr = @($List)
    if ($arr.Count -eq 0) {
        $text = "[]`n"
    } else {
        $json = ConvertTo-Json -InputObject $arr -Depth 3
        $json = $json -replace "`r`n", "`n"
        $json = [regex]::Replace($json, '(?m)^( +)', { param($m) ' ' * ($m.Groups[1].Length / 2) })
        $text = $json + "`n"
    }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $text
}

# 名单的展示文本（企微回发用）:空名单给明确提示，非空给出计数与全部条目
function Get-NoReplySummary([string]$Path = "") {
    $list = @(Get-NoReplyList -Path $Path)
    if ($list.Count -eq 0) { return "白名单为空，所有客户均自动回复" }
    return ("当前人工接管白名单(" + $list.Count + "): " + ($list -join '、'))
}

# 加入名单。返回: ADDED:<key> | ALREADY | BAD_NAME
#   - 先归一（与读侧同一函数），已是名单成员则不重复写入（幂等）
#   - 名单文件缺失/损坏时按空名单处理并**重建**（不会把坏内容当名单继续写坏）
function Add-NoReplyBuyer([string]$Name, [string]$Path = "") {
    $k = ConvertTo-NoReplyKey $Name
    if (-not $k) { return "BAD_NAME" }
    $list = @(Get-NoReplyList -Path $Path)
    if ($list -contains $k) { return "ALREADY" }
    [void](Save-NoReplyList -Path $Path -List (@($list) + $k))
    return ("ADDED:" + $k)
}

# 移出名单。返回: REMOVED:<key> | NOT_FOUND | BAD_NAME
function Remove-NoReplyBuyer([string]$Name, [string]$Path = "") {
    $k = ConvertTo-NoReplyKey $Name
    if (-not $k) { return "BAD_NAME" }
    $list = @(Get-NoReplyList -Path $Path)
    if ($list -notcontains $k) { return "NOT_FOUND" }
    [void](Save-NoReplyList -Path $Path -List @($list | Where-Object { $_ -ne $k }))
    return ("REMOVED:" + $k)
}
