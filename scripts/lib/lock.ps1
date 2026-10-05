# lib\lock.ps1 - 应用级写锁：**原子获取 + 归属校验 + 僵锁回收**（2026-10-05 spec §5-1）。
#
# 为什么重写（对照 spec §5-1「页面锁采用原子获取，释放前验证归属；测试两个竞争进程最多只有一个获得锁」）：
#   旧实现用 Set-Content 先测存在再写 ⇒ "测到不存在"与"写入"之间不是原子操作：两个进程可以同时
#   通过存在性检查、互相覆盖，出现**双持有**。释放也不校验归属 ⇒ 任何路径都能删掉别人的锁
#   （gonghai_probe.ps1 里那句"无条件 Release 会误删别人的锁"正是这个洞的现场记录）。
#
# 新契约：
#   1) 获取 = FileMode.CreateNew（操作系统级原子创建），失败即"别人持有"；
#   2) 锁文件格式 "<pid>|<yyyy-MM-dd HH:mm:ss>|<token>"（前两段与旧格式兼容，watchdog 仍按 |
#      切第一段取 PID）；token 为本次获取独有的 GUID；
#   3) 释放前校验归属：token 必须是本进程本次获取的，或锁文件里的 PID 就是本进程 ⇒ 否则**拒绝删除**；
#   4) 僵锁（持有 PID 已死 / 内容不可解析）先删除再**当场重试创建**（保留 F1 教训：timeoutSec=0
#      时也必须至少尝试一次，否则会退回"LOCK-BUSY → watchdog 杀进程 → 又留僵锁"的自锁闭环）。
#
# 依赖：scripts\config.ps1（Get-SkillPath "locks"）；lib\paths.ps1 存在时附加隔离守卫。
if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Assert-AarNoProductionPath -ErrorAction SilentlyContinue)) {
    $__pathsFile = Join-Path $PSScriptRoot 'paths.ps1'
    if (Test-Path $__pathsFile) { . $__pathsFile }
}
if (-not $script:AppLockTokens) { $script:AppLockTokens = @{} }

function Get-AppLockDir {
    $d = Get-SkillPath 'locks'
    if (-not $d) { $d = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'data' }
    return $d
}

function Get-AppLockFile([string]$name) { return (Join-Path (Get-AppLockDir) ($name + '.lock')) }

# 锁文件状态。Stale = 持有 PID 已死或内容不可解析（可回收）；Owned = 本进程本次持有的 token 匹配。
function Get-AppLockInfo([string]$name) {
    $lockFile = Get-AppLockFile $name
    $r = [pscustomobject]@{
        Name = $name; Path = $lockFile; Exists = $false; Content = ''
        Pid = 0; PidAlive = $false; Token = ''; Stale = $false; Unparsable = $false; Owned = $false
    }
    if (-not (Test-Path $lockFile)) { return $r }
    $r.Exists = $true
    try { $r.Content = [string](Get-Content $lockFile -Raw -ErrorAction Stop) } catch { $r.Content = '' }
    $parts = @(([string]$r.Content).Trim() -split '\|')
    if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') {
        $r.Pid = [int]$parts[0]
        $r.PidAlive = [bool](Get-Process -Id $r.Pid -ErrorAction SilentlyContinue)
    } else {
        $r.Unparsable = $true
    }
    if ($parts.Count -ge 3) { $r.Token = [string]$parts[2] }
    $r.Stale = ($r.Unparsable -or -not $r.PidAlive)
    $mine = ''
    if ($script:AppLockTokens.ContainsKey($name)) { $mine = [string]$script:AppLockTokens[$name] }
    $r.Owned = (($mine -and $r.Token -and $mine -eq $r.Token) -or ($r.Pid -eq $PID -and -not $r.Unparsable))
    return $r
}

# 原子创建：只有"文件此前不存在"时才可能成功。返回 $true = 本次获取成功。
function Try-NewAppLockFile([string]$lockFile, [string]$content) {
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($content)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        return $true
    } catch {
        return $false
    } finally {
        if ($fs) { try { $fs.Close(); $fs.Dispose() } catch { } }
    }
}

# 获取写锁。返回 $true/$false（调用方既有用法 if (-not (Get-AppLock 'x' 0)) {...} 不变）。
function Get-AppLock([string]$name, [int]$timeoutSec = 10) {
    $lockFile = Get-AppLockFile $name
    $dir = Split-Path $lockFile -Parent
    Assert-AarNoProductionPath -Path $lockFile -Operation 'create lock file' -WithinRuntimeRoot
    # 同进程重入：锁已由本进程持有 ⇒ 直接成功。页面锁的语义是"本进程内串行地操作页面"，
    # 不是进程内互斥量；没有这一条，同一轮里的下一个会话会在自己持有的锁上等到超时。
    if ($script:AppLockTokens.ContainsKey($name)) {
        $ownInfo = Get-AppLockInfo $name
        if ($ownInfo.Owned) { return $true }
    }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $token = [guid]::NewGuid().ToString('N')
    $content = ([string]$PID + '|' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '|' + $token)
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    $reclaims = 0
    # 迭代上限：调用方可能注入/冻结时钟（测试），单纯依赖墙钟会让等待循环永不退出。
    $attempts = 0
    $maxAttempts = [Math]::Max(1, $timeoutSec + 1)
    do {
        $attempts++
        if (Try-NewAppLockFile $lockFile $content) {
            $script:AppLockTokens[$name] = $token
            return $true
        }
        $info = Get-AppLockInfo $name
        if ($info.Stale -and $reclaims -lt 3) {
            # F1: 僵锁已清必须**当场重试创建**（在 continue 之前），否则 timeoutSec=0 时
            # do-while 的 continue 会直接跳到条件判断并退出 ⇒ 返回 false ⇒ 自锁闭环。
            $reclaims++
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            if (Try-NewAppLockFile $lockFile $content) {
                $script:AppLockTokens[$name] = $token
                return $true
            }
            continue
        }
        Start-Sleep -Seconds 1
    } while (((Get-Date) -lt $deadline) -and ($attempts -lt $maxAttempts))
    return $false
}

# 释放写锁：**只释放自己持有的锁**。返回 $true = 本次确实删除了锁文件；
# $false = 没锁 / 锁属于别人（拒绝误删）。调用方既有用法（当语句调用）不受影响。
function Release-AppLock([string]$name) {
    $lockFile = Get-AppLockFile $name
    if (-not (Test-Path $lockFile)) {
        if ($script:AppLockTokens.ContainsKey($name)) { $script:AppLockTokens.Remove($name) }
        return $false
    }
    $info = Get-AppLockInfo $name
    if (-not $info.Owned) { return $false }
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    if ($script:AppLockTokens.ContainsKey($name)) { $script:AppLockTokens.Remove($name) }
    return $true
}

function Test-AppLockOwned([string]$name) { return [bool]((Get-AppLockInfo $name).Owned) }

function Clear-AppLockToken([string]$name) {
    if ($script:AppLockTokens.ContainsKey($name)) { $script:AppLockTokens.Remove($name) }
}
