# okki/okki_ensure.ps1 - OKKI 环境确保(spec §5.7 / S2)。
#   做四件事:① 探测 9223 CDP ② 未就绪则只启动"本任务 profile + 9223"的 Chrome
#            ③ 导航到 okki_base_url ④ 判定登录态,输出 OKKI-ENSURE: OK / NEED_LOGIN。
#   硬约束:只操作 chrome-profile-okki 与 9223;禁止触碰 9222 实例(C6/N2);
#           禁止按进程名裸杀 chrome(C6/N9) —— 只按"命令行含本 profile 目录或 9223"精确定位。
#   编码:UTF8-BOM(C1)。
param(
    [switch]$NoStart,      # 只探测,不起 Chrome
    [int]$TimeoutSec = 40  # 起 Chrome 后轮询 CDP 的最长等待(与 chrome_ensure.ps1 同口径)
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\log.ps1")
. (Join-Path $PSScriptRoot "okki_lib.ps1")

function Exit-With([int]$code, [string]$msg) {
    Write-OkkiLog "OKKI-ENSURE: $msg"
    exit $code
}

try {
    $cfg = Get-OkkiConfig
    if (-not $cfg.CdpPort) { Write-Host "OKKI-CONFIG-MISSING: okki_cdp_port"; exit 9 }
    if (-not $cfg.Profile) { Write-Host "OKKI-CONFIG-MISSING: okki_profile"; exit 9 }
    if (-not $cfg.BaseUrl) { Write-Host "OKKI-CONFIG-MISSING: okki_base_url"; exit 9 }
    $port = $cfg.CdpPort
    $profileDir = $cfg.Profile
    $chromePath = Get-SkillPath "chrome"
    if (-not $chromePath) { $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe" }

    Write-OkkiLog "OKKI-ENSURE: start port=$port profile=$profileDir"

    # 0. 安全闸:绝不允许把 9222 当成本任务端口(N2)
    if ($port -eq 9222) { Exit-With 9 "REFUSE: okki_cdp_port=9222 是现役阿里链路端口,拒绝操作" }

    # 1. 探测 9223
    if (-not (Test-OkkiCdpReady -Port $port)) {
        if ($NoStart) { Exit-With 3 "OKKI-CDP-DOWN (NoStart)" }
        Write-OkkiLog "OKKI-ENSURE: CDP $port 未就绪,启动本任务 profile 的 Chrome"
        # C6:只杀命令行含本 profile 目录或 9223 的 chrome,不按进程名裸杀
        Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and (
                    $_.CommandLine -match [regex]::Escape($profileDir) -or
                    $_.CommandLine -match ('--remote-debugging-port=' + $port + '(\s|$)')
                )
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
        if (-not (Test-Path $chromePath)) { Exit-With 4 "OKKI-CHROME-MISSING: $chromePath" }
        Start-Process -FilePath $chromePath -ArgumentList `
            "--remote-debugging-port=$port", "--user-data-dir=$profileDir", `
            "--no-first-run", "--no-default-browser-check", `
            "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", `
            $cfg.BaseUrl
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if (Test-OkkiCdpReady -Port $port) { break }
            Start-Sleep -Seconds 1
        }
        if (-not (Test-OkkiCdpReady -Port $port)) { Exit-With 3 "OKKI-CDP-DOWN (启动后 $TimeoutSec s 内不可达)" }
        Write-OkkiLog "OKKI-ENSURE: CDP $port 就绪"
        Start-Sleep -Seconds 4
    } else {
        Write-OkkiLog "OKKI-ENSURE: CDP $port 已就绪"
    }

    # 2. 导航到站点根(已在目标站则跳过,避免打断用户正在看的页面)
    # 只用 host+pathname 判定与记录:query 可能含 ticket/token,不落日志(C7)
    $jsUrl = "(function(){return location.host + location.pathname})()"
    $cur = ""
    try { $cur = (Invoke-OkkiCdpEval $jsUrl).Trim() } catch { $cur = "" }
    $hostPart = ($cfg.BaseUrl -replace '^https?://','').TrimEnd('/')
    if ($cur -notmatch [regex]::Escape($hostPart)) {
        Write-OkkiLog "OKKI-ENSURE: 当前页不在目标站($cur),导航到 $($cfg.BaseUrl)"
        [void](Invoke-OkkiCdpRaw -Action "navigate" -Url $cfg.BaseUrl)
        Start-Sleep -Seconds 6
    } else {
        Write-OkkiLog "OKKI-ENSURE: 当前页已在目标站"
    }

    # 3. 登录态判定
    $state = Invoke-OkkiCdpEval (Get-OkkiLoginStateJs)
    Write-OkkiLog "OKKI-ENSURE: 登录态探针 = $state"
    $obj = $state | ConvertFrom-Json
    if ($obj.loggedIn) {
        Exit-With 0 "OK url=$($obj.host)$($obj.path)"
    }
    if ($obj.loginForm) {
        Exit-With 2 "NEED_LOGIN url=$($obj.host)$($obj.path) reason=$($obj.reason)"
    }
    Exit-With 5 "UNKNOWN url=$($obj.host)$($obj.path) reason=$($obj.reason)"
} catch {
    Write-OkkiLog "OKKI-ENSURE: ERROR $($_.Exception.Message)"
    Write-Host "OKKI-ENSURE: ERROR $($_.Exception.Message)"
    exit 1
}
