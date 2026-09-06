# lib/creds.ps1 - 凭据统一读取（唯一允许出现敏感值的文件：credentials.md）
# 敏感信息铁律:账号/密码/API key 只允许出现在 credentials.md,任何其他文件禁止内联敏感值。
# 依赖: config.ps1 已 dot-source 提供 Get-SkillPath;若未加载则本文件自行加载。
# 用法: . lib\creds.ps1; $key = Get-CredentialValue 'api_key'
# 兼容现有 credentials.md 格式:
#   - **账号 (account)**：xxx
#   - **密码 (password)**：xxx
#   - **API Key (api_key)**：xxx
# 解析失败返回 $null(调用方需处理:记日志/回退,不得崩溃)。

if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
}

$script:__credCache = $null
$script:__credCacheTime = $null
function Get-CredentialValue([string]$name) {
    $credFile = Get-SkillPath "creds"
    if (-not $credFile -or -not (Test-Path $credFile)) { return $null }
    $ft = (Get-Item $credFile).LastWriteTimeUtc.Ticks
    if (-not $script:__credCache -or $script:__credCacheTime -ne $ft) {
        $script:__credCache = Get-Content $credFile -Raw -Encoding UTF8
        $script:__credCacheTime = $ft
    }
    $cred = $script:__credCache
    switch ($name) {
        "account"  { if ($cred -match '- \*\*账号 \(account\)\*\*：(\S+)') { return $Matches[1] } }
        "password" { if ($cred -match '- \*\*密码 \(password\)\*\*：(\S+)') { return $Matches[1] } }
        "api_key"  { if ($cred -match '- \*\*API Key \(api_key\)\*\*：(\S+)') { return $Matches[1] } }
        "wx_bot_id" { if ($cred -match '- \*\*企微机器人 Bot ID \(wx_bot_id\)\*\*：(\S+)') { return $Matches[1] } }
        "wx_bot_secret" { if ($cred -match '- \*\*企微机器人 Secret \(wx_bot_secret\)\*\*：(\S+)') { return $Matches[1] } }
    }
    return $null
}
