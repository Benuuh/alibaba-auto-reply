# human_style.ps1 - 人工消息采集/风格统计 CLI（只读，不改任何数据）
#
# 用途：给"人"和"执行 agent"提供一个确定性入口，查看"老板本人手打的消息"有多少条、长什么样。
#   背景（spec 更像真人销售_20260926 §1.2）：快照里机器人发出的消息一律带 @@TS 标记，
#   人工在 OneTalk 手打的**不带任何标记** ⇒ "人工消息 = [ME] 且不含 @@TS"，可可靠识别。
#   当前这类消息为 0 条，因为老板从未在监控范围内手回过 —— **0 条是正确结果，不是故障**。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\human_style.ps1
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\human_style.ps1 -SnapDir <快照目录>
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\human_style.ps1 -List
#
# -List 只输出"条数 + 买家 + 时间"的清单（不打印消息原文，便于贴进汇报）
# 退出码：0 = 成功（含 0 样本）；1 = 目录不存在
param(
    [string]$SnapDir = "",
    [switch]$List
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\msg_source.ps1")
. (Join-Path $PSScriptRoot "lib\human_style.ps1")

if (-not $SnapDir) { $SnapDir = Get-SkillPath "data" }

if (-not (Test-Path $SnapDir)) {
    Write-Output ("快照目录不存在: " + $SnapDir)
    exit 1
}

if ($List) {
    $msgs = @(Get-HumanMessages $SnapDir)
    Write-Output ("人工消息条数: {0}" -f $msgs.Count)
    foreach ($m in $msgs) {
        Write-Output ("  [{0}] {1} (line {2})" -f $m.Buyer, $m.File, $m.Line)
    }
    if ($msgs.Count -eq 0) { Write-Output "  （采集通道已就绪，尚无人工作品样本 —— 老板手回后自动出现）" }
    exit 0
}

Get-HumanStyleStats $SnapDir | ForEach-Object { Write-Output $_ }
exit 0
