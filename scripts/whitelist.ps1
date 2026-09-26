# whitelist.ps1 - 人工接管白名单 CLI（名单买家不自动回复）
#
# 用途：给"人"和"执行 agent"提供**确定性**的名单增删查入口。
#   背景：名单读侧一直在 scripts\lib\no_reply.ps1（monitor / nudge / quote 三处判定），
#   但写侧原先只在 tools\control-agent\agent_bridge.js 里、靠轮询旧企微桥 19886 收指令；
#   该桥 2026-09-26 停用后写侧失效。本脚本把写侧搬到 PowerShell，读侧一行未动。
#
# 用法（三选一，等价）：
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command '白名单 列表'
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command '白名单 添加 John Smith'
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command 'whitelist remove John Smith'
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Action add -Name 'John Smith'
#
# 退出码：0 = 成功（含"已在名单中"这类幂等结果）；1 = 用法错误（命令解析失败/空客户名）
# 输出：单行人类可读结果（可直接作为企微回发文本）
param(
    [string]$Command = "",
    [ValidateSet('', 'list', 'add', 'remove')][string]$Action = "",
    [string]$Name = "",
    [string]$Path = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\no_reply.ps1")

# 名单文件：优先显式 -Path（供测试注入），否则走 config 的 data 目录（与读侧同一路径来源）
if (-not $Path) { $Path = Join-Path (Get-SkillPath "data") "manual_override.json" }

# 指令解析：与 agent_bridge.js L68 的正则同构
#   ^(?:白名单|whitelist)\s+(添加|删除|列表|add|remove|list)\s*(.*)$
$WL_RE = '^(?:白名单|whitelist)\s+(添加|删除|列表|add|remove|list)\s*(.*)$'

if ($Command) {
    $m = [regex]::Match($Command.Trim(), $WL_RE, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) {
        Write-Output "用法: 白名单 添加|删除|列表 <客户名>"
        exit 1
    }
    $verb = $m.Groups[1].Value.ToLowerInvariant()
    $Name = $m.Groups[2].Value
    switch ($verb) {
        { $_ -in @('列表', 'list') } { $Action = 'list' }
        { $_ -in @('添加', 'add') } { $Action = 'add' }
        { $_ -in @('删除', 'remove') } { $Action = 'remove' }
    }
}

if (-not $Action) {
    Write-Output "用法: 白名单 添加|删除|列表 <客户名>"
    exit 1
}

switch ($Action) {
    'list' {
        Write-Output (Get-NoReplySummary -Path $Path)
        exit 0
    }
    'add' {
        $r = Add-NoReplyBuyer -Name $Name -Path $Path
        switch -Regex ($r) {
            '^ADDED:(.*)$'   { Write-Output ("已加入人工接管白名单（不再自动回复）: " + $Matches[1]); exit 0 }
            '^ALREADY$'      { Write-Output ("已在白名单中（人工接管，不自动回复）: " + (ConvertTo-NoReplyKey $Name)); exit 0 }
            default          { Write-Output "用法: 白名单 添加|删除|列表 <客户名>"; exit 1 }
        }
    }
    'remove' {
        $r = Remove-NoReplyBuyer -Name $Name -Path $Path
        switch -Regex ($r) {
            '^REMOVED:(.*)$' { Write-Output ("已移出白名单（恢复自动回复）: " + $Matches[1]); exit 0 }
            '^NOT_FOUND$'    { Write-Output ("不在白名单中: " + (ConvertTo-NoReplyKey $Name)); exit 0 }
            default          { Write-Output "用法: 白名单 添加|删除|列表 <客户名>"; exit 1 }
        }
    }
}
