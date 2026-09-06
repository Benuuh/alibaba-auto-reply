# 计划任务健康检查:核对 4 个 AlibabaAutoReply 任务的最近运行时间是否超龄。
# 超龄(Summary>4.5h / Quality|Optimize>26h / Weekly>8 天)写告警日志(供 notify 消费)。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File task_health.ps1
# 建议:每日 07:00 计划任务或由 watchdog 顺带调用
param([string]$LogDir = "")

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# 任务 -> 最大允许超龄(小时)
$taskLimits = @{
    "AlibabaAutoReplySummary"  = 4.5
    "AlibabaAutoReplyQuality"  = 26
    "AlibabaAutoReplyOptimize" = 26
    "AlibabaAutoReplyWeekly"   = 192   # 8 天
}

$issues = 0
foreach ($tn in $taskLimits.Keys) {
    $q = (schtasks /Query /TN $tn /FO LIST /V 2>$null) -join "`n"
    $mLast = [regex]::Match($q, 'Last Run Time:\s*([^\r\n]+)')
    $mRes = [regex]::Match($q, 'Last Result:\s*([^\r\n]+)')
    $mNext = [regex]::Match($q, 'Next Run Time:\s*([^\r\n]+)')
    $lastStr = if ($mLast.Success) { $mLast.Groups[1].Value.Trim() } else { "" }
    $resStr = if ($mRes.Success) { $mRes.Groups[1].Value.Trim() } else { "" }
    $nextStr = if ($mNext.Success) { $mNext.Groups[1].Value.Trim() } else { "" }
    # 解析上次运行时间(如 "2026/8/24 8:00:00";"从未运行" 时跳过)
    $lastDt = $null
    if ($lastStr -match '^\d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}(:\d{2})?$') {
        try {
            # PS 5.1 注意:ParseExact 的格式数组必须显式 [string[]](object[] 参数绑定会失败)
            $formats = [string[]]@("yyyy/M/d H:mm:ss","yyyy/M/d H:mm","yyyy/MM/dd H:mm:ss","yyyy/MM/dd H:mm")
            $lastDt = [datetime]::ParseExact($lastStr, $formats, $null)
        } catch {
            try { $lastDt = [datetime]::Parse($lastStr) } catch {}
        }
    }
    $ok = $true
    $detail = "next=$nextStr"
    if ($lastDt) {
        $ageH = ((Get-Date) - $lastDt).TotalHours
        $detail = "last=$lastStr (${ageH}h ago), result=$resStr"
        if ($ageH -gt $taskLimits[$tn]) { $ok = $false }
    } elseif ($lastStr -match '从未|Never') {
        $detail = "never run, next=$nextStr"
    }
    if ($ok) {
        Write-Output "[OK]   $tn : $detail"
    } else {
        $issues++
        Write-Output "[!!]   $tn : $detail"
        Write-Log "TASK-HEALTH: $tn stale ($detail)"
    }
}
Write-Output "TASK-HEALTH: $issues issue(s)"
exit $issues
