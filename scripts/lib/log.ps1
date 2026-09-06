# lib/log.ps1 - 统一日志写入:UTF-8 追加 + 5MB 轮转(保留 20 份归档)。
# 用法: . lib\log.ps1; Write-SkillLog "msg" "C:\...\logs\monitor.log"
# 各脚本可定义单参数 wrapper: function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }
function Write-SkillLog([string]$msg, [string]$logFile) {
    if (-not $logFile) { return }
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 5MB)) {
            $logDir = Split-Path $logFile -Parent
            $base = [System.IO.Path]::GetFileNameWithoutExtension($logFile)
            $archived = Join-Path $logDir ($base + "_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
            Move-Item -Path $logFile -Destination $archived -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $logDir -Filter ($base + "_*.log") | Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " | " + $msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}
