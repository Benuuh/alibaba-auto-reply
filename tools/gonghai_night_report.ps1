# gonghai_night_report.ps1 —— **只读**的收工总账(不碰页面、不写任何生产文件)
# 用途:跑到收工时间(-StopAt)后一键出总账:发出数 / 待办构成 / 问题分类 / 回音统计。
# 纪律:本脚本**只读**(rate/pending/日志/台账);不做任何发送、不改任何状态。
param([string]$Day = (Get-Date -Format 'yyyy-MM-dd'))
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$S = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'   # 本文件在 <部署根>\tools\
. (Join-Path $S 'config.ps1')
. (Join-Path $S 'lib\log.ps1')
. (Join-Path $S 'gonghai\gonghai_lib.ps1')

$dataDir = Get-SkillPath 'data'
$logDir = Get-SkillPath 'logs'
$runtime = Split-Path $dataDir -Parent

function Read-Shared([string]$p) {
    if (-not (Test-Path $p)) { return @() }
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        return @($sr.ReadToEnd() -split "`r?`n")
    } catch { return @() } finally { if ($sr) { $sr.Dispose() }; if ($fs) { $fs.Dispose() } }
}

Write-Output ("=== 公海收工总账 " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===")

# 1) 发出数(账本为准 + 日志口径对照)
$rate = $null
try { $rate = Get-Content (Join-Path $dataDir 'gonghai\gonghai_rate.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($rate) { Write-Output ("【今日发出】账本 " + $rate.day + " = " + $rate.day_count + " 条 ; 最后一条 " + $rate.last_sent_at) }
# [GH-59 2026-09-29 09:0x] **必须把轮转归档一起读**。
#   事故：monitor.log 到 5MB 会被轮转成 monitor_<时间戳>.log，只读当前文件会**漏掉当天更早的全部行**
#   （实测 09:01 报"今日回复 5 条"，而含归档的真实值是 **59 条** —— 差 12 倍）。
#   判据：凡 `monitor*.log`（排除 *_out/_err）都算同一逻辑日志，合并后按时间过滤。
$mon = @()
foreach ($lf in @(Get-ChildItem $logDir -Filter 'monitor*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_(out|err)\.log$' } | Sort-Object LastWriteTime)) {
    $mon += @(Read-Shared $lf.FullName)
}
if (@($mon).Count -lt 100) { Start-Sleep -Seconds 1; $mon = @(Read-Shared (Join-Path $logDir 'monitor.log')) }
foreach ($d in (@('2026-09-27', '2026-09-28', $Day) | Sort-Object -Unique)) {
    $n = @($mon | Where-Object { $_ -match ('^' + $d + ' .*GONGHAI-SENT') }).Count
    if ($n -gt 0) { Write-Output ("        日志口径 " + $d + " = " + $n + " 条") }
}

# 2) 待办队列构成
$pl = @(Get-GonghaiPendingList)
Write-Output ("【待办队列】共 " + $pl.Count + " 条（认领了但没发成功的客户，均有名字可补发）")
@($pl | Group-Object reason | Sort-Object Count -Descending) | ForEach-Object { Write-Output ("        " + $_.Name + " = " + $_.Count) }
if ($pl.Count -gt 0) {
    $oldest = @($pl | Sort-Object added_at | Select-Object -First 1)[0]
    Write-Output ("        最早入队 = " + $oldest.added_at + "（补发命令: gonghai_probe.ps1 -RetryPending [-Count N]）")
}

# 3) 问题分类(台账)
$ledger = Join-Path $runtime 'specs\公海运行问题台账.md'
if (Test-Path $ledger) {
    $lines = Read-Shared $ledger
    $rows = @($lines | Where-Object { $_ -match '^\|\s*\*\*GH-' })
    $fixed = @($rows | Where-Object { $_ -match '已修|已恢复|已核验|已验证|非问题|已排除' }).Count
    $ext = @($rows | Where-Object { $_ -match '外部|待老板决定|待人工确认|待观察|待查' }).Count
    Write-Output ("【问题台账】共 " + $rows.Count + " 行（已修/已验证 " + $fixed + " ; 外部或待决定 " + $ext + "）")
}

# 4) 关键事件计数
foreach ($k in @('RISK-ABORT', 'GONGHAI-SEARCH-DOWN', 'GONGHAI-ONETALK-REBUILD', 'GONGHAI-LIST-READFAIL', 'GONGHAI-LIST-REPAIR', 'GONGHAI-LIST-DEAD', 'GONGHAI-ENSURE: start')) {
    Write-Output ("【事件】" + $k + " = " + @($mon | Where-Object { $_ -match [regex]::Escape($k) }).Count)
}

# 5) 自动回复侧(今日)
$replied = @($mon | Where-Object { $_ -match ('^' + $Day + ' .*REPLIED to ') }).Count
$proc = @($mon | Where-Object { $_ -match ('^' + $Day + ' .*PROCESS convo') }).Count
$alerts = @($mon | Where-Object { $_ -match ('^' + $Day + ' .*INQUIRY-ALERT') }).Count
Write-Output ("【自动回复】" + $Day + " 回复成功 " + $replied + " 条 ; 处理会话 " + $proc + " 次 ; 新买家提醒 " + $alerts + " 条")
Write-Output "=== 结束（本脚本只读，未改动任何状态）==="
