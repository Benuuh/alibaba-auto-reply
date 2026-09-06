# wecom_command tests: Match-WecomCommand keyword matching (pure function)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\wecom_command.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "wecom_command.ps1") -DryRun

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output ("  FAIL: " + $name + " | got: [" + $a + "] want: [" + $b + "]") }
}

Write-Output "== wecom_command tests =="

# ---- 6 个命令各自关键词命中 ----
Assert-Eq "C1-help-cn" (Match-WecomCommand "帮助") "help"
Assert-Eq "C1-help-en" (Match-WecomCommand "help") "help"
Assert-Eq "C2-status-cn" (Match-WecomCommand "健康检查") "status"
Assert-Eq "C2-status-en" (Match-WecomCommand "status") "status"
Assert-Eq "C3-dashboard-cn" (Match-WecomCommand "看板") "dashboard"
Assert-Eq "C3-dashboard-en" (Match-WecomCommand "dashboard") "dashboard"
Assert-Eq "C4-buyers-cn" (Match-WecomCommand "最新买家") "buyers"
Assert-Eq "C4-buyers-en" (Match-WecomCommand "buyers") "buyers"
Assert-Eq "C5-quote-cn" (Match-WecomCommand "报价提醒") "quote"
Assert-Eq "C5-quote-en" (Match-WecomCommand "quote") "quote"
Assert-Eq "C6-restart-cn" (Match-WecomCommand "重启监控") "restart"
Assert-Eq "C6-restart-en" (Match-WecomCommand "restart") "restart"

# ---- 未知消息返回空 ----
Assert-Eq "C7-unknown" (Match-WecomCommand "你好呀随便聊聊") ""
Assert-Eq "C8-empty" (Match-WecomCommand "") ""
Assert-Eq "C9-null" (Match-WecomCommand $null) ""

# ---- 大小写/多余空格/中文标点不影响 ----
Assert-Eq "C10-upper" (Match-WecomCommand "HELP") "help"
Assert-Eq "C11-mixed-case" (Match-WecomCommand "HeLp Me") "help"
Assert-Eq "C12-spaces" (Match-WecomCommand "  健康检查  ") "status"
Assert-Eq "C13-colon-cn" (Match-WecomCommand "帮助：") "help"
Assert-Eq "C14-colon-en" (Match-WecomCommand "help:") "help"
Assert-Eq "C15-punct" (Match-WecomCommand "看板！") "dashboard"
Assert-Eq "C16-question" (Match-WecomCommand "健康检查?") "status"

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
