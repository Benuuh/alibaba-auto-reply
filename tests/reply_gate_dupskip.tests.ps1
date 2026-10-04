# reply_gate_dupskip tests -- [FIX-DUP-GUARD / FIX-WAIT-STACK 2026-09-27]「重复回」与「等太久」的回归文件
#
# 覆盖 2026-09-27 傍晚的两处实测事故(规格修订见 docs\specs\判据改为待回复列表_20260927.md §12):
#   · 重复打扰: 买家 买家B 的同一条消息被连回 3 次
#               (16:31:47 / 16:41:09 / 16:50:35, 间隔 9 分半; 期间 buyerMsgs 与 lastBuyerHash 恒定)
#   · 等待叠加: 买家 买家N 的新消息被"发送后冷却 + 最小间隔"叠加挡到 8 分 43 秒
#               (17:28:42 判据判"该回"却被 RATE-SKIP 挡下, 旧代码又装一整段 5 分钟冷却)
#
# 本文件只做两件事:
#   1) 纯函数 Test-BuyerMsgAlreadyAnswered 的真值表 —— 它决定"要不要拦", 而**拦错方向代价最大**
#      (拦错 = 买家永远等不到回复, 即 Ganesan 事故形态), 故每个 fail-open 出口都逐条钉死;
#   2) monitor.ps1 的**生产接线**静态断言 —— 锚定冷却 / 下探信号三态 / 连挂告警确实在位,
#      且"唯一出口 / 唯一发送点 / 轮数不足不写冷却"这几条不变量没被这次修订破坏。
# 当前行为级证明在 tests/new_message_cooldown.tests.ps1 的 A1-A14（真实入口/证据）。
# 旧 tools/dedup_acceptance 脚本包含实机数据读取，不作为本次默认验收入口。
#
# ⚠️ 本文件必须保持 UTF-8 带 BOM(Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码 ⇒ 中文乱码, E-10)。
# 纯逻辑: 不 dot-source monitor.ps1(那会执行它的主分发)、不碰页面、不启动 monitor、不写任何文件。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "reply_engine.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }

Write-Output "== reply_gate_dupskip tests =="

# ---------------------------------------------------------------------------
# 1) 纯函数真值表: §12.1 的判据 = 条数与原文 hash **同时**逐字相等; 证据不足一律不拦(fail-open)
# ---------------------------------------------------------------------------
Assert-True "fn-exists" ($null -ne (Get-Command Test-BuyerMsgAlreadyAnswered -EA SilentlyContinue))
$H = 'A1B2C3D4E5F60718293A4B5C6D7E8F90'
Assert-Eq "exact-match-is-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|3" -BuyerCount 3 -NormLastBuyerHash $H) $true
# 买家又说了一句 ⇒ 条数变 ⇒ 必须放行(这正是 Ganesan 事故的反面: 绝不无限跳过)
Assert-Eq "count-increased-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|3" -BuyerCount 4 -NormLastBuyerHash $H) $false
# 最后一条原文变了(条数恰好相同: 抽取抖动/买家编辑) ⇒ 必须放行
Assert-Eq "hash-changed-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|3" -BuyerCount 3 -NormLastBuyerHash 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF') $false
# 证据不足的每一种形态 —— 全部必须"不拦"
Assert-Eq "legacy-key-without-count-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey $H -BuyerCount 3 -NormLastBuyerHash $H) $false
Assert-Eq "empty-ledger-key-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey '' -BuyerCount 3 -NormLastBuyerHash $H) $false
Assert-Eq "whitespace-ledger-key-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey '   ' -BuyerCount 3 -NormLastBuyerHash $H) $false
Assert-Eq "empty-hash-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|3" -BuyerCount 3 -NormLastBuyerHash '') $false
Assert-Eq "zero-count-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|0" -BuyerCount 0 -NormLastBuyerHash $H) $false
Assert-Eq "unknown-count-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|3" -BuyerCount -1 -NormLastBuyerHash $H) $false
Assert-Eq "non-numeric-count-not-answered" (Test-BuyerMsgAlreadyAnswered -LedgerKey "$H|x" -BuyerCount 3 -NormLastBuyerHash $H) $false
# 纯函数(§12.4 不变量): 函数体内不得出现文件/页面/进程/配置访问
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'reply_engine.ps1'), [ref]$tokens, [ref]$errors)
Assert-True "engine-parses-clean" ($null -eq $errors -or $errors.Count -eq 0)
$fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-BuyerMsgAlreadyAnswered' }, $true))
Assert-Eq "fn-defined-once" $fnAsts.Count 1
$fnSrc = if ($fnAsts.Count -eq 1) { [string]$fnAsts[0].Extent.Text } else { '' }
foreach ($forbidden in @('Get-Content', 'Set-Content', 'Add-Content', 'Invoke-CdpEval', 'Start-Process', 'Get-SkillConfig', 'Invoke-Expression')) {
    Assert-True ("fn-is-pure-no[{0}]" -f $forbidden) ($fnSrc -notmatch [regex]::Escape($forbidden))
}

# ---------------------------------------------------------------------------
# 2) 生产接线静态断言(monitor.ps1)
# ---------------------------------------------------------------------------
$monPath = Join-Path $scripts 'monitor.ps1'
$monRaw = [System.IO.File]::ReadAllText($monPath, [System.Text.Encoding]::UTF8)
# 只剔除"整行注释"; 用**函数调用形态**匹配, 免得把定义行/注释里的名字算成调用(同 should_reply.tests.ps1 的口径)
function Get-CodeLines([string]$path) {
    $out = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $n++
        if ($line -match '^\s*#') { continue }
        [void]$out.Add([pscustomobject]@{ line = $n; code = $line })
    }
    return $out
}
$code = Get-CodeLines $monPath
# 账本事实只算一次, 且必须作为**入参**喂给唯一出口(不是新增第二个出口)
Assert-Eq "monitor-guard-called-once" (@($code | Where-Object { $_.code -match 'Test-BuyerMsgAlreadyAnswered\s+-' }).Count) 1
Assert-True "monitor-guard-feeds-seen-rounds" ($monRaw -match 'if \(\$alreadyAnswered\) \{ \$seenRounds = 0 \}')
Assert-True "monitor-guard-kept-single-exit-arg" ($monRaw -match '-PendingSeenRounds \$seenRounds')
# 锚定冷却: 每个 skipCooldown 写入点都必须带 until(漏一个就漏一处叠加等待)
$writers = @($code | Where-Object { $_.code -match 'skipCooldown\[\$key\] = @\{' })
Assert-True "cooldown-writers-present" ($writers.Count -ge 4)
Assert-Eq "every-cooldown-writer-has-until" (@($writers | Where-Object { $_.code -notmatch 'until' }).Count) 0
Assert-True "rate-min-gap-anchored-to-lastsend" ($monRaw -match '\$coolUntil = \$sentAt\.AddMinutes\(\$script:replyMinGapMin\)')
Assert-True "post-send-anchored-to-lastsend" ($monRaw -match '\$coolUntil = \$sentAt\.AddMinutes\(\$script:replyPostSendCooldownMin\)')
Assert-True "new-floor-anchored-to-lastsend" ($monRaw -match '\$coolUntil = \$sentAt\.AddSeconds\(\$script:replyNewMsgFloorSec\)')
Assert-True "minute-data-keeps-fraction" ($monRaw -notmatch '\$gapMin = \[int\]')
Assert-True "no-second-minute-override" ($monRaw -notmatch '\$gapMin2\s*=')
Assert-True "periodic-read-scheduler-present" ($monRaw -match 'nextVerifyAt' -and $monRaw -match "'periodic'")
# 冷却期内"预览变化"的三态 + 连挂告警(全部必须留痕, 否则线上无从判断)
foreach ($marker in @('COOLDOWN-RECHECK', 'COOLDOWN-HOLD', 'COOLDOWN-LIFT', 'DUP-GUARD-HOLD', 'DUP-GUARD-ALERT', 'dupGuardHolds')) {
    Assert-True ("monitor-has[{0}]" -f $marker) ($monRaw -match [regex]::Escape($marker))
}
# 不变量(与 should_reply.tests.ps1 的 A8 同源, 这里防"改到一半"): 判据调用点唯一 / 发送调用点唯一
Assert-Eq "single-judge-call-site" (@($code | Where-Object { $_.code -match 'Test-ShouldReply\s+-' }).Count) 1
Assert-Eq "single-send-site" (@($code | Where-Object { $_.code -match '\bSend-OneTalkMessage\b' }).Count) 1
# §2.1: 轮数不足那条路仍只等待、不写冷却(否则第 2 轮永远等不到)
Assert-True "pending-confirm-wait-intact" ($monRaw -match 'PENDING-CONFIRM-WAIT')
Assert-True "dup-guard-not-on-pending-confirm-path" ($monRaw -match 'DUP-GUARD-HOLD')

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
