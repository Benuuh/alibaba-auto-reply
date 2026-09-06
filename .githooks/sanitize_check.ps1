# sanitize_check.ps1 - 提交/推送前敏感信息扫描器(默认防线)
# 用法: powershell -File sanitize_check.ps1 -Mode staged | -Mode push -From <sha> -To <sha>
# 退出码: 0=通过, 1=发现阻断项(提交/推送被拒绝)
param(
    [ValidateSet("staged","push")]
    [string]$Mode = "staged",
    [string]$From = "",
    [string]$To = ""
)

$ErrorActionPreference = "Stop"
# 2026-09-07: git 输出按 UTF-8 解码(core.quotepath=false 时中文文件名原样输出;钩子管道非 tty 下防 OEM 乱码)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$git = "C:\Program Files\Git\cmd\git.exe"

# ---- 文件名黑名单(运行时产物/凭据/PII 文件,任何情况下不得入库) ----
$fileBlacklist = @(
    "credentials.md",
    "state.json", "state.json.bak",
    "remind_state.json", "inquiry_state.json",
    "nudge_state.json", "nudge_state.json.bak",
    "summary_last.json", "last_sync.json",
    "monitor.pid", "watchdog.pid",
    "wecom_receiver.json",
    "*.log", "*.pid", "*.local"
)
# 目录级黑名单(前缀匹配)
$dirBlacklist = @(
    "chrome-profile/",
    "logs/", "data/", "reports/", "backups/",
    "node_modules/"
)

# ---- 内容敏感模式(阻断级) ----
$contentBlock = @(
    "sk-[A-Za-z0-9]{16,}",
    "aibUffO9",
    "oVSkdg",
    "C:\\Users\\wnt",
    "Desktop\\Alibaba-skills",
    "Zhejiang Gocean",
    "Benjamin Hu",
    "password\s*[:=]\s*\S{6,}",
    "api_key\s*[:=]\s*\S{6,}",
    "(?m)\*\*密码 \(password\)\*\*：(?!xxx(?:\s|$)|你的|占位|<)\S+",
    "(?m)\*\*API Key \(api_key\)\*\*：(?!xxx(?:\s|$)|你的|占位|<)\S+",
    "(?m)\*\*账号 \(account\)\*\*：(?!xxx(?:\s|$)|你的|占位|<)\S+",
    # 2026-09-07 发布补充:通用形态(企微/飞书/Slack webhook URL、本机真实路径、bot 凭据赋值;值需 12+ 字母数字以避代码引用误伤)
    'qyapi\.weixin[^\s"'']*|hooks\.slack[^\s"'']*|open\.feishu[^\s"'']*',
    'D:\\Agent_work', 'C:\\Users\\22129',
    '(wx_bot_id|wx_bot_secret|bot_secret|control_api_key)["'']?\s*[:=：]\s*["'']?[A-Za-z0-9_\-]{12,}'
)

# ---- 内容敏感模式(警告级:疑似 PII,不阻断但提示) ----
$contentWarn = @(
    "sebastian breaux", "muhammad faiz", "eraldo modesto", "lubna el attar",
    "javed vahora", "esmin mateo", "hurry patho", "carlos resendiz",
    "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
)

$blocked = @()
$warned = @()
$files = @()

# ---- 收集待检查文件 ----
if ($Mode -eq "staged") {
    $names = @(& $git diff --cached --name-only --diff-filter=ACMRT 2>$null)
    foreach ($n in $names) {
        if (-not $n) { continue }
        $files += [pscustomobject]@{ Name = $n; Path = (Join-Path (Get-Location) $n) }
    }
} else {
    $range = "$From..$To"
    if (-not $From -or -not $To) { $range = "HEAD" }
    $names = @(& $git diff --name-only --diff-filter=ACMRT $range 2>$null)
    # 2026-09-07: 单提交/新分支(force 覆盖)时 range 退化为无效或空——回退 diff-tree 全量列该提交文件
    if ($names.Count -eq 0) {
        $target = if ($To) { $To } else { "HEAD" }
        $names = @(& $git diff-tree --no-commit-id --name-only -r --diff-filter=ACMRT $target 2>$null)
    }
    foreach ($n in $names) {
        if (-not $n) { continue }
        $files += [pscustomobject]@{ Name = $n; Path = "" }
    }
}

# ---- 逐文件检查 ----
foreach ($f in $files) {
    $name = $f.Name
    # 扫描器自身豁免:黑名单模式的定义行是"守卫描述"而非泄露
    if ($name -like "*.ps1" -and $name -like "*sanitize*") { continue }
    # config.json.example 豁免:仓库契约性占位模板(值均为 占位/example/path 形态;发布前另有门②人工复核)
    if ($name -eq "config.json.example" -or $name -like "*/config.json.example") { continue }
    $isBlockedFile = $false
    foreach ($pat in $fileBlacklist) {
        if ($name -like $pat) { $isBlockedFile = $true; break }
    }
    if (-not $isBlockedFile) {
        foreach ($d in $dirBlacklist) {
            if ($name.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)) { $isBlockedFile = $true; break }
        }
    }
    if ($isBlockedFile) {
        $blocked += "文件名黑名单: $name"
        continue
    }
    $content = ""
    if ($Mode -eq "staged") {
        if (Test-Path $f.Path) { try { $content = [System.IO.File]::ReadAllText($f.Path, [System.Text.Encoding]::UTF8) } catch { $content = "" } }
    } else {
        try { $content = & $git show "$To`:$name" 2>$null | Out-String } catch { $content = "" }
    }
    if (-not $content) { continue }
    foreach ($re in $contentBlock) {
        if ($content -match $re) { $blocked += "$name 含敏感内容: $re"; break }
    }
    foreach ($re in $contentWarn) {
        if ($content -match $re) { $warned += "$name 疑似PII: $re" }
    }
}

# ---- 输出 ----
if ($blocked.Count -gt 0) {
    Write-Output "SANITIZE-BLOCKED: 检测到敏感内容,已阻止:"
    $blocked | ForEach-Object { Write-Output ("  [BLOCK] " + $_) }
    exit 1
}
if ($warned.Count -gt 0) {
    Write-Output "SANITIZE-WARN: 疑似 PII(未阻断,请人工确认):"
    $warned | Sort-Object -Unique | ForEach-Object { Write-Output ("  [WARN] " + $_) }
}
Write-Output "SANITIZE-OK: $($files.Count) 个文件扫描通过"
exit 0
