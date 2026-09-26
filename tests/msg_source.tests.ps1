# msg_source tests - 消息来源判定 (S1/S2, spec 更像真人销售_20260926 §6)
# 纯逻辑: 只测 Get-MessageSource / Test-HumanInterjection, 不碰页面/Chrome/网络。
# 覆盖 spec §6-S1 用例表的 7 类 + 边界 + S2 的集成式判定(尾部人工 -> 应跳过 / 尾部机器人 -> 应发送)。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\msg_source.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }
Write-Output "== msg_source tests =="

# --- 存在性 (A1) ---
Assert-True "Get-MessageSource-exists" ($null -ne (Get-Command Get-MessageSource -EA SilentlyContinue))
Assert-True "Test-HumanInterjection-exists" ($null -ne (Get-Command Test-HumanInterjection -EA SilentlyContinue))

# --- spec §6-S1 用例表: 四类来源判定 ---
# 买家行(带 @@TS 与 @@OT 都要判为 buyer —— @@TS 不是我方专属,买家行也可能有)
Assert-Eq "buyer-with-both-marks" (Get-MessageSource '[BUYER] hello @@TS:1 @@OT:eHl6') 'buyer'
Assert-Eq "buyer-plain" (Get-MessageSource '[BUYER] hello') 'buyer'
# 机器人行(带 @@TS)
Assert-Eq "bot-with-ts" (Get-MessageSource '[ME] Got it @@TS:2') 'bot'
# 人工行([ME] 且无 @@TS)
Assert-Eq "human-no-ts" (Get-MessageSource "[ME] I'll check with the factory") 'human'
# 空
Assert-Eq "empty-string" (Get-MessageSource '') 'unknown'
Assert-Eq "null" (Get-MessageSource $null) 'unknown'
# 非消息行(UI 噪声/注释/买家名头)
Assert-Eq "comment-line" (Get-MessageSource '# BUYER: someone') 'unknown'
Assert-Eq "noise-line" (Get-MessageSource '在Alibaba.com上聊天') 'unknown'

# --- Test-HumanInterjection: 用例表 ---
# 尾部人工 -> HasHumanLast=$true
$r = Test-HumanInterjection @('[BUYER] a', '[ME] bot @@TS:1', '[ME] human')
Assert-Eq "tail-human-flag" $r.HasHumanLast $true
Assert-Eq "tail-human-index" $r.HumanIndex 2
Assert-Eq "tail-human-source" $r.LastMeSource 'human'

# 尾部机器人 -> HasHumanLast=$false, LastMeSource='bot'
$r = Test-HumanInterjection @('[BUYER] a', '[ME] human', '[ME] bot @@TS:2')
Assert-Eq "tail-bot-flag" $r.HasHumanLast $false
Assert-Eq "tail-bot-source" $r.LastMeSource 'bot'

# 只有买家(新询盘) -> HasHumanLast=$false, LastMeSource=''
$r = Test-HumanInterjection @('[BUYER] a')
Assert-Eq "only-buyer-flag" $r.HasHumanLast $false
Assert-Eq "only-buyer-source" $r.LastMeSource ''

# 空输入 / null 不报错
$r = Test-HumanInterjection @()
Assert-Eq "empty-input-flag" $r.HasHumanLast $false
$r = Test-HumanInterjection $null
Assert-Eq "null-input-flag" $r.HasHumanLast $false

# --- 边界: "我方尾部"的正确语义 ---
# 人工消息在买家之前 -> 属于历史, 与本轮是否抢话无关 => 应发送(尾部是我方机器人)
$r = Test-HumanInterjection @('[ME] human', '[BUYER] new question', '[ME] bot @@TS:9')
Assert-Eq "human-before-buyer-not-blocking" $r.HasHumanLast $false
Assert-Eq "human-before-buyer-source" $r.LastMeSource 'bot'

# 多买家发言 + 最后一条人工: 仍应识别为人工(往上第一句我方就是人工)
$r = Test-HumanInterjection @('[BUYER] a', '[ME] bot @@TS:1', '[BUYER] b', '[BUYER] c', '[ME] human')
Assert-Eq "human-after-multi-buyer" $r.HasHumanLast $true
Assert-Eq "human-after-multi-buyer-index" $r.HumanIndex 4

# 人工连发两条 -> 命中最近一条(索引应为最后一行)
$r = Test-HumanInterjection @('[BUYER] a', '[ME] human one', '[ME] human two')
Assert-Eq "two-human-lines-index" $r.HumanIndex 2
Assert-Eq "two-human-lines-flag" $r.HasHumanLast $true

# 尾部夹空行/噪声行: 仍要能看到人工消息(保守方向, 不因噪声漏判)
$r = Test-HumanInterjection @('[BUYER] a', '[ME] bot @@TS:1', '[ME] human', '')
Assert-Eq "noise-after-human-flag" $r.HasHumanLast $true
Assert-Eq "noise-after-human-index" $r.HumanIndex 2

# 我方尾部只有噪声行 -> 不误判为人工(LastMeSource 保持空 => 可发送)
$r = Test-HumanInterjection @('[BUYER] a', '在Alibaba.com上聊天')
Assert-Eq "noise-only-tail-flag" $r.HasHumanLast $false
Assert-Eq "noise-only-tail-source" $r.LastMeSource ''

# --- S2 集成式纯逻辑: 闸门函数如何映射到"发送/跳过" ---
# 契约(与 monitor.ps1 内的闸门一致): monitor **调用同一个函数** Get-HumanInterjectionGate,
# 故下列断言直接覆盖线上判定路径(不是复刻一份逻辑)。
Assert-True "Get-HumanInterjectionGate-exists" ($null -ne (Get-Command Get-HumanInterjectionGate -EA SilentlyContinue))
$g = Get-HumanInterjectionGate @('[BUYER] can you quote', '[ME] bot @@TS:1', '[ME] I''ll check with the factory')
Assert-Eq "integ-tail-human-skip" $g.Action 'SKIP'
Assert-Eq "integ-tail-human-reason" $g.Reason 'human-last'
Assert-Eq "integ-tail-human-flag" $g.HasHumanLast $true
$g = Get-HumanInterjectionGate @('[BUYER] can you quote', '[ME] I''ll check with the factory', '[ME] bot @@TS:2')
Assert-Eq "integ-tail-bot-send" $g.Action 'SEND'
Assert-Eq "integ-tail-bot-reason" $g.Reason 'bot-last'
$g = Get-HumanInterjectionGate @('[BUYER] can you quote')
Assert-Eq "integ-new-inquiry-send" $g.Action 'SEND'
Assert-Eq "integ-new-inquiry-reason" $g.Reason 'no-me-tail'
# 真实快照行形态(带 @@OT 的买家行 + 带 ts 的机器人行混排)
$g = Get-HumanInterjectionGate @(
    '[BUYER] Can you give me a quote @@TS:1758800000000 @@OT:Q2FuIHlvdSBnaXZlIG1lIGEgcXVvdGU=',
    '[ME] Got it - let me check @@TS:1758800060000',
    '[ME] No worries - take your time with Amazon')
Assert-Eq "integ-realistic-skip" $g.Action 'SKIP'
Assert-Eq "integ-realistic-index" $g.HumanIndex 2

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
