# lib/lock.ps1 - 应用级写锁:基于锁文件 + PID 存活校验,僵锁自动回收。
# 用途:monitor 每轮处理前拿锁,轮末释放;nudge 发送前拿锁(超时放弃),防止并发操作同一页面。
# 依赖: config.ps1(Get-SkillPath "data" 放锁文件)。
function Get-AppLock([string]$name, [int]$timeoutSec = 10) {
    $lockDir = Get-SkillPath "data"
    if (-not $lockDir) { $lockDir = Join-Path (Split-Path $PSScriptRoot -Parent) "data" }
    if (-not (Test-Path $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
    $lockFile = Join-Path $lockDir ("$name.lock")
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    # do-while 保证至少尝试一次(timeoutSec=0 时 while 条件立即不满足,非阻塞调用必须能尝试)
    do {
        if (-not (Test-Path $lockFile)) {
            try {
                Set-Content -Path $lockFile -Value ($PID.ToString() + "|" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding ASCII -ErrorAction Stop
                return $true
            } catch { Start-Sleep -Milliseconds 500 }
        } else {
            $holder = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue).Split('|')[0]
            # 只接受纯数字 PID:锁文件损坏/半写入(并发 Set-Content 被打断)时,
            # Get-Process -Id <非数字> 会抛参数绑定异常;调用方多为 $ErrorActionPreference='Stop',
            # 该异常会直接终止 monitor 本轮。非数字一律按僵锁回收。
            $holderAlive = $false
            if ($holder -and $holder -match '^\d+$') {
                $holderAlive = [bool](Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)
            }
            if ($holder -and -not $holderAlive) {
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
                # F1(2026-09-15 停摆根因 R2):僵锁已清必须"当场重试创建"。
                # timeoutSec=0 时 deadline 已是过去时刻,此处若 continue 会直接退出 do-while 并返回 false
                # → 该轮被判 LOCK-BUSY 跳过(日志静默)→ watchdog 判 stale 杀进程 → 又留僵锁,形成自锁闭环。
                try {
                    Set-Content -Path $lockFile -Value ($PID.ToString() + "|" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding ASCII -ErrorAction Stop
                    return $true
                } catch { Start-Sleep -Milliseconds 500 }
                continue
            }
            Start-Sleep -Seconds 1
        }
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Release-AppLock([string]$name) {
    $lockDir = Get-SkillPath "data"
    if (-not $lockDir) { $lockDir = Join-Path (Split-Path $PSScriptRoot -Parent) "data" }
    $lockFile = Join-Path $lockDir ("$name.lock")
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
