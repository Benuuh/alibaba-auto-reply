# 基线快照:把代码+配置打包到 backups\,保留最近 20 份。
# 敏感铁律(D2):credentials.md 不打包(凭据不入备份包,防备份文件成为泄露点)。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File backup.ps1 -Snapshot
param([switch]$Snapshot)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$root = Get-SkillPath ""
$bakDir = Join-Path $root "backups"
if (-not (Test-Path $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }

# 排除运行时产物(日志/快照/状态/pid/备份/临时)
$exclRegex = '\.(log|bak|pre|pid|tmp)$|^msgs_|^state\.json|^nudge_state|^summary_last\.json|^remind_state|^last_sync|^verify_.*\.ps1$|^apply_.*\.ps1$'

function Add-Tree($zip, [string]$base, [string]$relDir) {
    $src = Join-Path $base $relDir
    if (-not (Test-Path $src)) { return }
    Get-ChildItem $src -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -notmatch $exclRegex -and $_.FullName -notmatch 'chrome-profile'
    } | ForEach-Object {
        $entry = $_.FullName.Substring($base.Length).TrimStart('\')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
}

if ($Snapshot) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $zipPath = Join-Path $bakDir ("alibaba-auto-reply_" + $stamp + ".zip")
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Add-Tree $zip $root "scripts"
        foreach ($f in @("SKILL.md", "README_部署说明.md", "llm_config.json")) {
            $p = Join-Path $root $f
            if (Test-Path $p) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $p, $f, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        }
    } finally { $zip.Dispose() }
    Get-ChildItem $bakDir -Filter "*.zip" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Output "snapshot: $zipPath"
} else {
    Write-Output "Usage: backup.ps1 -Snapshot"
}
