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
# Current pending contract: one decision consumes actual duplicate evidence.
Assert-Eq 'monitor-event-guard-called-once' (@($code|Where-Object {$_.code -match 'Test-PendingBuyerAlreadyAnswered\s+-'}).Count) 1
Assert-True 'monitor-guard-feeds-already-answered' ($monRaw -match '-AlreadyAnswered \$alreadyAnswered')
Assert-True 'monitor-pending-is-authoritative' ($monRaw -match '-PendingListAuthoritative')
Assert-True 'monitor-no-source-wait-consumer' ($monRaw -notmatch '\$freshSync\s*=|\$interventionSync\s*=')
Assert-True 'monitor-stale-pending-human-task' ($monRaw -match 'stale-pending-flag')
Assert-True 'monitor-final-pending-reread' ($monRaw -match '\$pendingRaw = Get-Snapshot')
# 不变量(与 should_reply.tests.ps1 的 A8 同源, 这里防"改到一半"): 判据调用点唯一 / 发送调用点唯一
Assert-Eq "single-judge-call-site" (@($code | Where-Object { $_.code -match 'Test-ShouldReply\s+-' }).Count) 1
# [2026-10-05 spec §5-3] The single production send site is now the STRUCTURED entry point
# (Send-OneTalkMessageEx), because the page action alone is not a send result any more.
Assert-Eq "single-send-site" (@($code | Where-Object { $_.code -match '\bSend-OneTalkMessageEx\s+-' }).Count) 1
Assert-Eq "legacy-send-entry-not-called" (@($code | Where-Object { $_.code -match '\bSend-OneTalkMessage\s+-' }).Count) 0
Assert-True 'pending-no-round-wait' ($monRaw -notmatch 'PENDING-CONFIRM-WAIT')

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
