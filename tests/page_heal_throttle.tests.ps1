# page_heal_throttle tests — FIX-THROTTLE 2026-09-26
# 纯逻辑：覆盖静默期 / 退避阶梯 / 硬上限 / 边界。不触碰页面与 Chrome。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
$script:pass=0; $script:fail=0
function Assert-Eq([string]$n,[object]$a,[object]$b){ if($a -eq $b){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n | got:[$a] want:[$b]"} }
function Assert-True([string]$n,[bool]$c){ if($c){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n"} }
Write-Output "== page_heal_throttle tests =="

Assert-True "function-exists" ($null -ne (Get-Command Get-PageHealAction -EA SilentlyContinue))
$now = Get-Date '2026-09-26 00:30:00'

# 1) 静默期内一律 none（**这是本 spec 的核心**：绝不能每 90 秒重启）
$r = Get-PageHealAction -Streak 30 -Restarts 1 -QuietUntil $now.AddSeconds(120) -Now $now
Assert-Eq "quiet-blocks-restart" $r.Action 'none'
Assert-True "quiet-reason" ($r.Reason -like 'quiet-until*')

# 2) 静默期已过 + streak 够 → restart，并给出静默期长度
$r = Get-PageHealAction -Streak 30 -Restarts 1 -QuietUntil $now.AddSeconds(-1) -Now $now
Assert-Eq "after-quiet-restarts" $r.Action 'restart'
Assert-Eq "restart-sets-quiet-600" $r.NextQuietSec 600

# 3) 退避阶梯：第 3 次重启需要 streak>=6
Assert-Eq "backoff-3rd-needs-6"  (Get-PageHealAction -Streak 5  -Restarts 2 -Now $now).Action 'reload'
Assert-Eq "backoff-3rd-ok-at-6"  (Get-PageHealAction -Streak 6  -Restarts 2 -Now $now).Action 'restart'
# 第 4 次需要 streak>=12
Assert-Eq "backoff-4th-needs-12" (Get-PageHealAction -Streak 11 -Restarts 3 -Now $now).Action 'reload'
Assert-Eq "backoff-4th-ok-at-12" (Get-PageHealAction -Streak 12 -Restarts 3 -Now $now).Action 'restart'

# 4) 硬上限：达到 4 次后只告警，永不再重启（即使 streak 极大、静默期已过）
$r = Get-PageHealAction -Streak 999 -Restarts 4 -Now $now
Assert-Eq "max-restarts-alert-only" $r.Action 'alert-only'
Assert-True "max-restarts-reason" ($r.Reason -like 'max-restarts-reached*')
Assert-Eq "max-restarts-5-also-alert-only" (Get-PageHealAction -Streak 999 -Restarts 5 -Now $now).Action 'alert-only'

# 5) streak 过低不做任何事
Assert-Eq "streak-1-none" (Get-PageHealAction -Streak 1 -Restarts 0 -Now $now).Action 'none'
Assert-Eq "streak-2-reload" (Get-PageHealAction -Streak 2 -Restarts 0 -Now $now).Action 'reload'

# 6) 边界：'reload' 分支不得附带静默期（否则轻量 reload 会误抑制后续升级）
#    [偏差 D-01] spec §6-S2 模板自身只有 14 条断言，而 §7-A3 期望 "15 条"；本条按 §11 允许自决 A5
#    （"单测断言措辞与额外边界用例，不得删除已有 15 条"）补充，与节流目标直接相关。
Assert-Eq "reload-has-no-quiet" (Get-PageHealAction -Streak 5 -Restarts 2 -Now $now).NextQuietSec 0

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if($script:fail -gt 0){ Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
