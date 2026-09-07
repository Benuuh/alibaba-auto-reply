# lib/no_reply.ps1 - 人工接管白名单(指定买家不自动回复)统一读取与匹配
# 名单文件: data\manual_override.json(JSON 字符串数组,条目为已归一买家名;本机 PII,gitignore 不入库)
# 归一化契约: 与 tools\control-agent\agent_bridge.js 的 normCustomer 逐字同构
#   (trim → ToLowerInvariant → '_'→' ' → 连续空白压单空格),改动需双侧同步,否则企微添加的客户在 PS 侧匹配失败
# 容错: 文件缺失/损坏/非数组 → 视为空名单,绝不抛错(每路径 WARN 一次)
# 用法: . lib\no_reply.ps1; Test-NoReplyBuyer 'John Smith'
# 依赖: 本库不强制 dot-source config.ps1;Get-SkillPath 可用时经其取 data 目录,
#       否则回退 <部署根>\data(由 PSScriptRoot=scripts\lib 推导)

# 归一化: trim → 小写 → '_'→' ' → 连续空白压单空格(顺序与 agent_bridge.js normCustomer 一致)
function ConvertTo-NoReplyKey([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $t = $s.Trim()
    $t = $t.ToLowerInvariant()
    $t = $t.Replace('_', ' ')
    $t = [regex]::Replace($t, '\s+', ' ')
    $t = $t.Trim()
    return $t
}

$script:__noReplyCache = @{}     # path -> @{ t=tick; ft=文件mtime; list=@() }
$script:__noReplyWarned = @{}    # path -> $true(损坏/缺失仅 WARN 一次)

# 读名单: 10s TTL 静态缓存(文件 mtime 变化立即失效,便于测试与即时编辑)
function Get-NoReplyList([string]$Path = "") {
    if (-not $Path) {
        if (Get-Command Get-SkillPath -ErrorAction SilentlyContinue) {
            $Path = Join-Path (Get-SkillPath "data") "manual_override.json"
        } else {
            $root = Join-Path (Split-Path $PSScriptRoot -Parent) "..\data"
            $Path = Join-Path $root "manual_override.json"
        }
    }
    $ft = -1
    if (Test-Path $Path) {
        try { $ft = (Get-Item $Path).LastWriteTimeUtc.Ticks } catch {}
    }
    $now = [Environment]::TickCount
    if ($script:__noReplyCache.ContainsKey($Path)) {
        $c = $script:__noReplyCache[$Path]
        if ($c.ft -eq $ft -and ($now - $c.t) -lt 10000) { return $c.list }
    }
    $list = @()
    if (Test-Path $Path) {
        try {
            $arr = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
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
    } elseif (-not $script:__noReplyWarned.ContainsKey($Path)) {
        $script:__noReplyWarned[$Path] = $true
        Write-Warning "no_reply: $Path 不存在,按空名单处理"
    }
    $script:__noReplyCache[$Path] = @{ t = $now; ft = $ft; list = $list }
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
