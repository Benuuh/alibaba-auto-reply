# lib/log.ps1 - 统一日志写入:UTF-8 追加 + 5MB 轮转(保留 20 份归档)。
# 用法: . lib\log.ps1; Write-SkillLog "msg" "C:\...\logs\monitor.log"
# 各脚本可定义单参数 wrapper: function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }
#
# [GH-32/GH-35 2026-09-28] **日志写入绝不允许拖垮生产**。实测两类真实故障:
#   · GH-32 `Add-Content : ... used by another process` —— 巡检用 Select-String/Get-Content **独占读**日志时,
#     会把生产的追加写挡在门外(当时真丢了一行 GONGHAI-SENT);
#   · GH-35 `Add-Content : Stream was not readable` —— 句柄/文件状态被外部动作(如轮转、改名)破坏。
# 对策(不改成功路径的行为,只让失败**不致命、不丢消息**):
#   ① 写入失败 ⇒ 等 250ms 重试一次(瞬时占用/抖动多半能过);
#   ② 仍失败 ⇒ 落到同级 `*.fallback.log`,消息不丢,并**不打任何异常**(调用方是生产链路);
#   ③ 全程 try/catch 兜底 —— Write-SkillLog 永远不抛。
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

    # ① 正常写入
    try {
        Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction Stop
        return
    } catch { }

    # ② 重试一次(瞬时占用/抖动)
    try {
        Start-Sleep -Milliseconds 250
        Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction Stop
        return
    } catch { }

    # ③ 兜底:落 fallback 文件,消息不丢(再失败也只能放弃,绝不抛)
    try {
        $fb = [System.IO.Path]::ChangeExtension($logFile, $null)
        if (-not $fb) { $fb = $logFile }
        $fb = $fb.TrimEnd('.') + '.fallback.log'
        Add-Content -Path $fb -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}
