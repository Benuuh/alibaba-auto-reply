# 集中配置加载器：所有脚本 dot-source 本文件后调用 Get-SkillConfig / Get-SkillPath。
# 配置来源（按优先级）：
#   1) 显式参数 -ConfigPath / -RuntimeRoot（测试与隔离模式使用）
#   2) 环境变量 AAR_CONFIG_PATH / AAR_RUNTIME_ROOT（子进程隔离使用）
#   3) 与 config.ps1 同目录的 config.json
#   4) config.json 缺失或损坏时回退到脚本所在目录的父目录（部署根）
#
# [2026-10-05 spec §6.3 架构优化] 代码位置与运行数据根分别解析：
#   - 代码位置（deploy_root / scripts_dir / creds / llmcfg ...）来自 config.json 或本文件所在目录；
#   - 运行数据根（RuntimeRoot）决定 state / pause / tasks / locks / pid / remind / data / logs 等
#     运行态文件的落点。未显式指定 RuntimeRoot 时等于 deploy_root：生产行为逐字不变。
#   一旦显式指定 RuntimeRoot（隔离模式），运行态路径**只**从该根派生，不再读取生产 config 的
#   data_dir/logs_dir/state_file 等运行态键 —— 这正是"隔离测试不得写到生产数据根"的实现。
#   本文件只做解析，不建目录、不写文件、不启动循环、不通知、不恢复进程。
$script:__skillConfig = $null
$script:__skillConfigPath = ''
$script:__runtimeRoot = ''

# 配置文件路径：显式参数 > 环境变量 > 与本文件同目录的 config.json。
function Get-SkillConfigPath {
    if ($script:__skillConfigPath) { return $script:__skillConfigPath }
    if ($env:AAR_CONFIG_PATH) { return [string]$env:AAR_CONFIG_PATH }
    return (Join-Path $PSScriptRoot "config.json")
}

# 运行数据根：显式设置 > 环境变量 > config.runtime_root > deploy_root。
function Get-SkillRuntimeRoot {
    if ($script:__runtimeRoot) { return [string]$script:__runtimeRoot }
    if ($env:AAR_RUNTIME_ROOT) { return [string]$env:AAR_RUNTIME_ROOT }
    $cfg = Get-SkillConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'runtime_root') -and $cfg.runtime_root) {
        return [string]$cfg.runtime_root
    }
    return (Get-SkillDeployRoot)
}

# 是否处于隔离运行数据根（解析到部署根以外的显式运行根）。
function Test-SkillRuntimeIsolated {
    return ((Get-SkillRuntimeRoot) -ne (Get-SkillDeployRoot))
}

# 显式设置运行数据根（测试/隔离模式调用；传空串恢复默认解析）。
#   [独立复核 R10] 在带证据文件的孩子进程里，任何运行根切换都要进入可核验上下文：
#   -DeclaredProbe + -Reason 只用于显式声明的隔离守卫探针；其余切换须由 New-AarIsolationRoot 写出合法标记解除，
#   否则父进程核验失败（未登记/无标记的切根不能被当成已核验上下文）。
function Set-SkillRuntimeRoot([string]$Path, [switch]$DeclaredProbe, [string]$Reason = '') {
    $previous = Get-SkillRuntimeRoot
    $script:__runtimeRoot = ''
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $script:__runtimeRoot = $Path.Trim() }
    $current = Get-SkillRuntimeRoot
    if (Get-Command Write-AarRuntimeRootSwitch -ErrorAction SilentlyContinue) {
        Write-AarRuntimeRootSwitch -From $previous -To $current -Declared:([bool]$DeclaredProbe) -Reason $Reason
    }
    return $current
}

# 显式设置配置文件路径并丢弃已缓存配置（传空串恢复默认解析）。
function Set-SkillConfigPath([string]$Path) {
    $script:__skillConfigPath = ''
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $script:__skillConfigPath = $Path.Trim() }
    $script:__skillConfig = $null
    return (Get-SkillConfigPath)
}

# 代码位置根（部署根）。与运行数据根分开解析。
function Get-SkillDeployRoot {
    $cfg = Get-SkillConfig
    if ($cfg -and $cfg.deploy_root) { return [string]$cfg.deploy_root }
    return (Split-Path $PSScriptRoot -Parent)
}

function Get-SkillConfig {
    param(
        [string]$ConfigPath = '',
        [string]$RuntimeRoot = ''
    )
    if ($RuntimeRoot) { [void](Set-SkillRuntimeRoot $RuntimeRoot) }
    if ($ConfigPath) {
        if ($script:__skillConfig -and $script:__skillConfigPath -eq $ConfigPath) { return $script:__skillConfig }
        $script:__skillConfigPath = $ConfigPath
        $script:__skillConfig = $null
    }
    if ($script:__skillConfig) { return $script:__skillConfig }
    $cfgFile = Get-SkillConfigPath
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

function Get-SkillConfigValue([string]$key, $default = $null) {
    $cfg = Get-SkillConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains $key) -and $null -ne $cfg.$key -and "$($cfg.$key)" -ne '') { return $cfg.$key }
    return $default
}

# 取某个具名路径：代码位置按 config.json/deploy_root 解析；运行态位置按 RuntimeRoot 解析。
# [2026-10-05 spec §6.3] state / pause / tasks / locks / pid / remind 统一从这里定位，
#   各脚本不得再自行 Join-Path 拼运行态路径。
function Get-SkillPath([string]$name) {
    $cfg = Get-SkillConfig
    $root = Get-SkillDeployRoot
    $runtime = Get-SkillRuntimeRoot
    $isolated = ($runtime -ne $root)

    # ---- 代码位置（隔离不影响：代码永远来自仓库） ----
    $scripts = Join-Path $root "scripts"
    $reports = Join-Path $root "reports"
    if ($cfg.scripts_dir) { $scripts = [string]$cfg.scripts_dir }
    if ($cfg.reports_dir) { $reports = [string]$cfg.reports_dir }

    # ---- 运行态位置 ----
    if ($isolated) {
        $data    = Join-Path $runtime "data"
        $logs    = Join-Path $runtime "logs"
        $profile = Join-Path $runtime "chrome-profile"
        $backups = Join-Path $runtime "backups"
        $creds   = Join-Path $runtime "credentials.md"
        $llmcfg  = Join-Path $runtime "llm_config.json"
        $state   = Join-Path $runtime "state.json"
        $pidf    = Join-Path $runtime "monitor.pid"
        $remind  = Join-Path $runtime "remind_state.json"
        $pause   = Join-Path $runtime "human_pause.json"
        $tasks   = Join-Path $runtime "human_tasks.json"
        $locks   = Join-Path $runtime "locks"
    } else {
        $data    = Join-Path $root "data"
        if ($cfg.data_dir) { $data = [string]$cfg.data_dir }
        $logs    = Join-Path $root "logs"
        if ($cfg.logs_dir) { $logs = [string]$cfg.logs_dir }
        $profile = Join-Path $root "chrome-profile"
        if ($cfg.chrome_profile) { $profile = [string]$cfg.chrome_profile }
        $backups = Join-Path $root "backups"
        if ($cfg.backups_dir) { $backups = [string]$cfg.backups_dir }
        $creds   = Join-Path $root "credentials.md"
        if ($cfg.credentials_file) { $creds = [string]$cfg.credentials_file }
        $llmcfg  = Join-Path $root "llm_config.json"
        if ($cfg.llm_config_file) { $llmcfg = [string]$cfg.llm_config_file }
        $state   = Join-Path $scripts "state.json"
        if ($cfg.PSObject.Properties.Name -contains 'state_file' -and $cfg.state_file) { $state = [string]$cfg.state_file }
        $pidf    = Join-Path $scripts "monitor.pid"
        if ($cfg.PSObject.Properties.Name -contains 'pid_file' -and $cfg.pid_file) { $pidf = [string]$cfg.pid_file }
        $remind  = Join-Path $scripts "remind_state.json"
        if ($cfg.PSObject.Properties.Name -contains 'remind_state_file' -and $cfg.remind_state_file) { $remind = [string]$cfg.remind_state_file }
        $pause   = Join-Path $data "human_pause.json"
        if ($cfg.PSObject.Properties.Name -contains 'pause_file' -and $cfg.pause_file) { $pause = [string]$cfg.pause_file }
        $tasks   = Join-Path $data "human_tasks.json"
        if ($cfg.PSObject.Properties.Name -contains 'human_tasks_file' -and $cfg.human_tasks_file) { $tasks = [string]$cfg.human_tasks_file }
        $locks   = $data
        if ($cfg.PSObject.Properties.Name -contains 'lock_dir' -and $cfg.lock_dir) { $locks = [string]$cfg.lock_dir }
    }

    switch ($name) {
        "scripts" { return $scripts }
        "reports" { return $reports }
        "logs"    { return $logs }
        "data"    { return $data }
        "profile" { return $profile }
        "backups" { return $backups }
        "creds"   { return $creds }
        "llmcfg"  { return $llmcfg }
        "cdp"     { if ($cfg.cdp_script) { return [string]$cfg.cdp_script } else { return (Join-Path $scripts "cdp.ps1") } }
        "monitor" { if ($cfg.monitor_script) { return [string]$cfg.monitor_script } else { return (Join-Path $scripts "monitor.ps1") } }
        "ensure"  { if ($cfg.chrome_ensure_script) { return [string]$cfg.chrome_ensure_script } else { return (Join-Path $scripts "chrome_ensure.ps1") } }
        "chrome"  { if ($cfg.chrome_path) { return [string]$cfg.chrome_path } else { return "C:\Program Files\Google\Chrome\Application\chrome.exe" } }
        "runtime" { return $runtime }
        "state"   { return $state }
        "pause"   { return $pause }
        "tasks"   { return $tasks }
        "locks"   { return $locks }
        "pid"     { return $pidf }
        "remind"  { return $remind }
        # 已确认发送记录（spec §2.2 的来源证据）：与其它运行态文件同根，便于隔离测试。
        "sent_records" { return (Join-Path $data "sent_records.json") }
        "rules"   { if ($cfg.reply_rules_file) { return [string]$cfg.reply_rules_file } else { return (Join-Path $scripts "reply_rules.json") } }
        "registry" { if ($cfg.rule_registry_file) { return [string]$cfg.rule_registry_file } else { return (Join-Path $scripts "reply_rules.registry.json") } }
        default   { return $root }
    }
}
