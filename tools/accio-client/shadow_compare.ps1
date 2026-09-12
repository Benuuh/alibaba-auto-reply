# shadow_compare.ps1 - 一次性影子对比: 用 data\msgs_*.txt(CDP 快照) vs 网关历史, 仅写 monitor.log 的 ACCIO-SHADOW 行。
# 只读: 不打开浏览器、不发送、不改任何状态。用法: powershell -File tools\accio-client\shadow_compare.ps1 [-MaxConversations 25]
param([int]$MaxConversations = 25)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root "scripts\config.ps1")
. (Join-Path $root "scripts\lib\log.ps1")
. (Join-Path $root "scripts\lib\accio.ps1")

$logFile = Join-Path (Get-SkillPath "logs") "monitor.log"
Set-AccioLogFile $logFile

if (-not (Test-AccioGateway -Force)) {
    Write-Output "ACCIO-SHADOW-BATCH: gateway unavailable, abort"
    exit 1
}

$dataDir = Get-SkillPath "data"
$snaps = @(Get-ChildItem (Join-Path $dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
$byBuyer = @{}
foreach ($s in $snaps) {
    $first = Get-Content $s.FullName -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($first -and $first.StartsWith("# BUYER: ")) {
        $b = $first.Substring(9).Trim()
        if ($b -and -not $byBuyer.ContainsKey($b)) { $byBuyer[$b] = $s.FullName }
    }
}
$buyers = @($byBuyer.Keys) | Select-Object -First $MaxConversations
Write-Output ("ACCIO-SHADOW-BATCH: candidates=" + $buyers.Count + " (from " + $snaps.Count + " snapshots)")

$ok = 0; $fail = 0; $match = 0; $mismatch = 0
foreach ($b in $buyers) {
    $cdpLines = @(Get-Content $byBuyer[$b] -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\[(BUYER|ME)\]' })
    $gwLines = Get-AccioReplyLines $b
    if ($gwLines) {
        Invoke-AccioShadowCompare $b $cdpLines $gwLines
        $ok++
        $log = Get-Content $logFile -Tail 1 -Encoding UTF8
        if ($log -match 'latest=match') { $match++ } else { $mismatch++ }
    } else {
        Write-SkillLog "ACCIO-SHADOW ${b}: gateway unavailable (cdp-only)" $logFile
        $fail++
    }
}
Write-Output ("ACCIO-SHADOW-BATCH: done ok=$ok fail=$fail latestMatch=$match latestMismatch=$mismatch")
