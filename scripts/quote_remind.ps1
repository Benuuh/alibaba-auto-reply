# quote_remind.ps1 - 报价提醒 CLI:扫描数据齐全买家并推送企微提醒(手动/计划任务/调试)
# 用法: quote_remind.ps1 [-DryRun] [-LogDir ...]
param(
    [switch]$DryRun,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\quote.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
if (-not $script:logFileDir) { $script:logFileDir = Join-Path (Split-Path $LogDir -Parent) "logs" }
$logFile = Join-Path $script:logFileDir "monitor.log"
function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

$ready = Get-QuoteReadyBuyers
if ($ready.Count -eq 0) {
    Write-Output "QUOTE-REMIND: no ready buyers"
    exit 0
}
Write-Output "QUOTE-REMIND: $($ready.Count) ready buyer(s):"
foreach ($b in $ready) { Write-Output ("  - {0} | {1}" -f $b.buyer, $b.goods) }
if ($DryRun) {
    Write-Output "QUOTE-REMIND-DRYRUN: 未推送"
    exit 0
}
if (-not (Test-WecomService)) {
    Write-Output "QUOTE-REMIND: wecom service down (check node process)"
    Write-Log "QUOTE-REMIND: wecom service down"
    exit 1
}
$sent = Send-QuoteReminders -logFile $logFile
Write-Output "QUOTE-REMIND: sent=$sent"
Write-Log "QUOTE-REMIND: done sent=$sent"
