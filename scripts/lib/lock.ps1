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
            if ($holder -and -not (Get-Process -Id $holder -ErrorAction SilentlyContinue)) {
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
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
