# retention.ps1 - 快照保留:data\msgs_*.txt 中超过 N 天的文件按月份打包进 data\archive\msgs_<yyyyMM>.zip,
# 打包成功后删除源文件。只处理 msgs_*.txt;不碰 data\buyers\、vision_extract\、manual_override.json、state、报告。
# 用法(dot-source): . scripts\retention.ps1; Invoke-SnapshotRetention -DataDir <data> -Days 90 [-DryRun]
# 直接运行: powershell -ExecutionPolicy Bypass -NoProfile -File scripts\retention.ps1 [-DryRun] [-Days N]
$ErrorActionPreference = "Stop"

# 把一批文件追加进目标 zip:目标不存在→新建;已存在→-Update 追加,失败(重名冲突等)→合并到带时间戳的新 zip。
function Add-FilesToZip([string]$ZipPath, [string[]]$Files) {
    if (Test-Path -LiteralPath $ZipPath) {
        try {
            Compress-Archive -LiteralPath $Files -DestinationPath $ZipPath -Update -ErrorAction Stop
            return $true
        } catch {
            $alt = Join-Path ([IO.Path]::GetDirectoryName($ZipPath)) ([IO.Path]::GetFileNameWithoutExtension($ZipPath) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
            try { Compress-Archive -LiteralPath $Files -DestinationPath $alt -CompressionLevel Optimal -ErrorAction Stop; return $true } catch { return $false }
        }
    }
    try { Compress-Archive -LiteralPath $Files -DestinationPath $ZipPath -CompressionLevel Optimal -ErrorAction Stop; return $true } catch { return $false }
}

# 快照保留:超期 msgs_*.txt 按 LastWriteTime 月份分组归档;DryRun 只输出清单与总量,不动文件。
# 返回摘要字符串: RETENTION archived=N freed=X MB dryrun=... 
function Invoke-SnapshotRetention([string]$DataDir, [int]$Days, [switch]$DryRun) {
    if ($Days -le 0) { $Days = 90 }
    $cutoff = (Get-Date).AddDays(-1 * $Days)
    $all = @(Get-ChildItem -LiteralPath $DataDir -Filter 'msgs_*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
    $totalBytes = 0
    foreach ($f in $all) { $totalBytes += $f.Length }
    $totalMb = [Math]::Round($totalBytes / 1MB, 2)
    if ($all.Count -eq 0) {
        return ("RETENTION archived=0 freed=0 MB (no files older than ${Days}d)")
    }
    if ($DryRun) {
        foreach ($f in $all) { Write-Output ("RETENTION-DRYRUN " + $f.Name + " " + $f.LastWriteTime.ToString('yyyy-MM-dd') + " " + [Math]::Round($f.Length / 1KB, 1) + "KB") }
        return ("RETENTION archived=" + $all.Count + " freed=${totalMb} MB dryrun=true")
    }
    $archiveDir = Join-Path $DataDir 'archive'
    if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $archived = 0
    $freedBytes = 0
    foreach ($grp in ($all | Group-Object { $_.LastWriteTime.ToString('yyyyMM') })) {
        $zipPath = Join-Path $archiveDir ('msgs_' + $grp.Name + '.zip')
        $files = @($grp.Group | ForEach-Object { $_.FullName })
        if (Add-FilesToZip $zipPath $files) {
            foreach ($f in $grp.Group) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $archived++
                    $freedBytes += $f.Length
                } catch { }
            }
        }
    }
    $freedMb = [Math]::Round($freedBytes / 1MB, 2)
    return ("RETENTION archived=$archived freed=${freedMb} MB (older than ${Days}d)")
}

# 直接运行(非 dot-source)时:读取 config 执行一次保留策略;dot-source 时仅加载函数,无副作用
$__retentionDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $__retentionDotSourced) {
    $__dry = @($args) -contains '-DryRun'
    $__days = 0
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '-Days' -and ($i + 1) -lt $args.Count) { $__days = [int]$args[$i + 1] }
    }
    . (Join-Path $PSScriptRoot 'config.ps1')
    $__cfg = Get-SkillConfig
    $__dataDir = Get-SkillPath 'data'
    if ($__days -le 0) {
        $__days = 90
        if ($__cfg.PSObject.Properties.Name -contains 'snapshot_retention_days' -and $__cfg.snapshot_retention_days) { $__days = [int]$__cfg.snapshot_retention_days }
    }
    Invoke-SnapshotRetention -DataDir $__dataDir -Days $__days -DryRun:$__dry
}
