# 定向补发工具（长期保留）：按"原因类别"挑出**值得补**的待办条目，逐条走完整发送窗口。
#
# 为什么需要这个工具：待办队列里混着两类完全不同的东西 ——
#   ① `LOST_AFTER_ABORT` / `WRONG_CONVO` / `NOTSENT` / `NO_CARDID`：**我们这边**没发成功，
#      客户在阿里侧是有索引的 ⇒ 补发成功率实测 **16/25 = 64%**（2026-09-28 实测）；
#   ② `INDEX_NOT_SYNCED`：**阿里侧从未建索引** ⇒ 实测 27 条 **0 成功**（GH-47）。
#   链路自带的轮转补发是"每 5 轮 2 条"，覆盖全队列要十几小时；本工具用来**立刻把①捞回来**。
#
# 用法：
#   tools\gonghai_recover.ps1                                  # 默认补 ① 那四类
#   tools\gonghai_recover.ps1 -Reasons LOST_AFTER_ABORT        # 只补某一类
#   tools\gonghai_recover.ps1 -DryRun                          # 只列名单，不发送
#
# ⚠️ 纪律：跑之前**必须先停链路**（同一个 9225 页面不能并发用）。
param(
    [string[]]$Reasons = @('LOST_AFTER_ABORT', 'WRONG_CONVO', 'NOTSENT', 'NO_CARDID'),
    [int]$MaxCount = 0,          # 0 = 不限制
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'
$S = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'   # 本文件在 <部署根>\tools\
. (Join-Path $S 'config.ps1')
. (Join-Path $S 'lib\log.ps1')
. (Join-Path $S 'lib\cdp.ps1')
. (Join-Path $S 'gonghai\gonghai_cdp.ps1')
. (Join-Path $S 'gonghai\gonghai_lib.ps1')
$probe = Join-Path $S 'gonghai\gonghai_probe.ps1'   # 补发子进程入口(同目录推导)

$targets = @(Get-GonghaiPendingList | Where-Object { $Reasons -contains $_.reason } | Sort-Object added_at)
if ($MaxCount -gt 0) { $targets = @($targets | Select-Object -First $MaxCount) }

Write-Output ("=== 定向补发 " + (Get-Date -Format 'MM-dd HH:mm:ss') + " ; 类别=" + ($Reasons -join '/') + " ; 目标 " + $targets.Count + " 条 ===")
if ($targets.Count -eq 0) { Write-Output "（没有符合条件的待办条目）"; exit 0 }
if ($DryRun) {
    $i = 0
    foreach ($t in $targets) { $i++; Write-Output ("  [" + $i + "] " + $(if ($t.code) { $t.code } else { 'gh-' + (Get-GonghaiHash8 $t.key) }) + "  " + $t.reason + "  " + $t.added_at) }
    exit 0
}

$logDir = Get-SkillPath 'logs'
$sent = 0; $notfound = 0; $already = 0; $other = 0
$i = 0
foreach ($t in $targets) {
    $i++
    $code = if ($t.code) { $t.code } else { 'gh-' + (Get-GonghaiHash8 $t.key) }
    $out = Join-Path $logDir ('gonghai_recover_' + $code + '_' + (Get-Date -Format 'HHmmss') + '.txt')
    & powershell -ExecutionPolicy Bypass -NoProfile -File $probe -RetryPending -CustomerId $t.key 2>&1 | Tee-Object -FilePath $out | Out-Null
    $txt = ''
    try { $txt = Get-Content $out -Raw } catch { }
    $verdict = '其它'
    if ($txt -match 'SENT_OK|✓ 已发') { $verdict = '✅ SENT_OK'; $sent++ }
    elseif ($txt -match 'END NOT_FOUND_IN_SEARCH') { $verdict = '❌ NOT_FOUND'; $notfound++ }
    elseif ($txt -match 'SKIP ALREADY_SENT') { $verdict = '⏭ ALREADY_SENT(出队)'; $already++ }
    else { $other++ }
    Write-Output ("[" + $i + "/" + $targets.Count + "] " + $code + " (" + $t.reason + ") => " + $verdict + "   " + (Get-Date -Format 'HH:mm:ss'))
}
Write-Output ("=== 结束 " + (Get-Date -Format 'MM-dd HH:mm:ss') + " ; 成功 " + $sent + " ; 搜不到 " + $notfound + " ; 已发过出队 " + $already + " ; 其它 " + $other + " ; 剩余待办 = " + @(Get-GonghaiPendingList).Count + " ===")
