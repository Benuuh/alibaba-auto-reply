# 集中配置加载器：所有脚本 dot-source 本文件后调用 Get-SkillConfig / Get-SkillPath。
# 配置来源：与 config.ps1 同目录的 config.json（换机/换目录只改这一个文件）；
# config.json 缺失或损坏时回退到脚本所在目录的父目录（部署根）。
$script:__skillConfig = $null

function Get-SkillConfig {
    if ($script:__skillConfig) { return $script:__skillConfig }
    $cfgFile = Join-Path $PSScriptRoot "config.json"
    if (Test-Path $cfgFile) {
        try {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg) { $script:__skillConfig = $cfg; return $cfg }
        } catch {}
    }
    $script:__skillConfig = [pscustomobject]@{
        deploy_root = (Split-Path $PSScriptRoot -Parent)
        chrome_path = "C:\Program Files\Google\Chrome\Application\chrome.exe"
    }
    return $script:__skillConfig
}

# 取 CDP 调试端口:config.json 有值用配置值,否则默认 9222
function Get-CdpPort {
    $cfg = Get-SkillConfig
    if ($cfg.cdp_port) { return [int]$cfg.cdp_port }
    return 9222
}

# 取某个具名路径：config.json 有值用配置值，否则按 deploy_root 推导默认值
function Get-SkillPath([string]$name) {
    $cfg = Get-SkillConfig
    $root = Split-Path $PSScriptRoot -Parent
    if ($cfg.deploy_root) { $root = [string]$cfg.deploy_root }
    $scripts = Join-Path $root "scripts"
    $reports = Join-Path $root "reports"
    switch ($name) {
        "scripts" { if ($cfg.scripts_dir) { return [string]$cfg.scripts_dir } else { return $scripts } }
        "reports" { if ($cfg.reports_dir) { return [string]$cfg.reports_dir } else { return $reports } }
        "logs"    { if ($cfg.logs_dir) { return [string]$cfg.logs_dir } else { return (Join-Path $root "logs") } }
        "data"    { if ($cfg.data_dir) { return [string]$cfg.data_dir } else { return (Join-Path $root "data") } }
        "profile" { if ($cfg.chrome_profile) { return [string]$cfg.chrome_profile } else { return (Join-Path $root "chrome-profile") } }
        "creds"   { if ($cfg.credentials_file) { return [string]$cfg.credentials_file } else { return (Join-Path $root "credentials.md") } }
        "llmcfg"  { if ($cfg.llm_config_file) { return [string]$cfg.llm_config_file } else { return (Join-Path $root "llm_config.json") } }
        "cdp"     { if ($cfg.cdp_script) { return [string]$cfg.cdp_script } else { return (Join-Path $scripts "cdp.ps1") } }
        "monitor" { if ($cfg.monitor_script) { return [string]$cfg.monitor_script } else { return (Join-Path $scripts "monitor.ps1") } }
        "ensure"  { if ($cfg.chrome_ensure_script) { return [string]$cfg.chrome_ensure_script } else { return (Join-Path $scripts "chrome_ensure.ps1") } }
        "chrome"  { if ($cfg.chrome_path) { return [string]$cfg.chrome_path } else { return "C:\Program Files\Google\Chrome\Application\chrome.exe" } }
        default   { return $root }
    }
}
