param(
    [string]$LogDir = "",
    [string]$CredFile = ""
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
if (-not $CredFile) { $CredFile = Get-SkillPath "creds" }
if (-not $CredFile) { $CredFile = Join-Path (Split-Path $LogDir -Parent) "credentials.md" }

$cdp = Join-Path $LogDir "cdp.ps1"
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"
$profileDir = Get-SkillPath "profile"
if (-not $profileDir) { $profileDir = Join-Path (Split-Path $LogDir -Parent) "chrome-profile" }
$chromePath = Get-SkillPath "chrome"
if (-not $chromePath) { $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe" }

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

function Get-LoginState {
    $js = @"
(function(){
  return JSON.stringify({url: location.href.substring(0,80), hasTa: !!document.querySelector('textarea.send-textarea'), onLogin: !!document.querySelector('input[name=account]')});
})()
"@
    return Invoke-CdpEval $js
}

# 1. 若 CDP 未就绪：杀掉残留的调试 Chrome 进程并重启带调试端口的 Chrome
if (-not (Test-CdpReady)) {
    Write-Log "CHROME-ENSURE: CDP not ready, restarting Chrome..."
    # 只终止调试实例(带 remote-debugging 标志或使用本技能 profile 的进程),
    # 不误杀用户个人 Chrome(默认 profile 的浏览器会话)
    Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'remote-debugging-port' -or $_.CommandLine -match [regex]::Escape($profileDir) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    Start-Process -FilePath $chromePath -ArgumentList `
        "--remote-debugging-port=9222", "--user-data-dir=$profileDir", `
        "--no-first-run", "--no-default-browser-check", `
        "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding", `
        "about:blank"
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Test-CdpReady) { break }
        Start-Sleep -Seconds 1
    }
    if (-not (Test-CdpReady)) {
        Write-Log "CHROME-ENSURE: FAILED to start Chrome"
        exit 1
    }
    Write-Log "CHROME-ENSURE: Chrome restarted, CDP ready"
    Start-Sleep -Seconds 3
}

# 2. 导航到 OneTalk
powershell -ExecutionPolicy Bypass -File $cdp -Action navigate -Url "https://onetalk.alibaba.com/message/weblitePWA.htm" | Out-Null
Start-Sleep -Seconds 8

# 3. 检查登录状态
$state = Get-LoginState
Write-Log "CHROME-ENSURE: login state = $state"

if ($state -match 'hasTa":true') {
    Write-Log "CHROME-ENSURE: already logged in"
    exit 0
}

# 4. 未登录 → 从 credentials.md 读取凭据自动登录（统一走 lib\creds.ps1）
if ($state -match 'onLogin":true' -or $state -match 'login\.alibaba') {
    if (-not (Test-Path $CredFile)) { Write-Log "CHROME-ENSURE: credentials file not found: $CredFile"; exit 1 }
    $acct = Get-CredentialValue 'account'
    $pwd = Get-CredentialValue 'password'
    if (-not $acct -or -not $pwd) { Write-Log "CHROME-ENSURE: cannot parse credentials"; exit 1 }
    $escA = $acct.Replace("'","\'").Replace("\","\\")
    $escP = $pwd.Replace("'","\'").Replace("\","\\")
    $loginJs = @"
(function(){
  var setVal = function(el, val){
    var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
      : (el instanceof HTMLInputElement ? HTMLInputElement.prototype : HTMLElement.prototype);
    var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    setter.call(el, val);
    el.dispatchEvent(new Event('input', {bubbles:true}));
    el.dispatchEvent(new Event('change', {bubbles:true}));
  };
  var a = document.querySelector('input[name=account]');
  var p = document.querySelector('input[name=password]');
  if (!a || !p) return 'INPUTS_NOT_FOUND';
  setVal(a, '$escA');
  setVal(p, '$escP');
  var b = document.querySelector('button.sif_form-submit');
  if (b) b.click();
  return 'LOGGING_IN';
})()
"@
    $r = Invoke-CdpEval $loginJs
    Write-Log "CHROME-ENSURE: login attempt = $r"
    Start-Sleep -Seconds 10
    $state2 = Get-LoginState
    Write-Log "CHROME-ENSURE: after login = $state2"
    if ($state2 -match 'hasTa":true') { Write-Log "CHROME-ENSURE: login SUCCESS"; exit 0 }
    else {
        Write-Log "CHROME-ENSURE: login may have failed, manual check needed"
        exit 2
    }
} else {
    Write-Log "CHROME-ENSURE: unknown page state, manual check needed"
    exit 3
}
