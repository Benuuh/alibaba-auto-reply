# lib/ps-common.ps1 - 组件侧 PS 公共函数:config.json 解析单一事实源(client 与 bin 共用)
# 依赖: 无(独立 dot-source);config.json 位于组件根目录(本文件上一级),env WECOM_CONFIG 可覆盖路径

# 默认端口唯一来源(JS 侧 lib\config.js DEFAULTS.port 与之对应;env WECOM_PORT / config.json port 可覆盖)
function Conn-DefaultPort {
    return 19886
}

function Get-ConnConfig {
    $cfgFile = $env:WECOM_CONFIG
    if (-not $cfgFile) { $cfgFile = Join-Path (Split-Path $PSScriptRoot -Parent) "config.json" }
    if (-not (Test-Path $cfgFile)) { return $null }
    try {
        $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $cfg) { return $null }
        return $cfg
    } catch { return $null }
}
