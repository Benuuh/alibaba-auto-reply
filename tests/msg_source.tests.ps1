# msg_source tests - 消息来源判定 (S1/S2, spec 更像真人销售_20260926 §6；2026-10-07 spec §3.2 / 复核 R7)
#
# 本文件分两段，覆盖"旧入口也必须委托共享判定"这件事：
#   §A 共享判定库**未加载**（只加载 lib\msg_source.ps1）：走保守阶梯 —— 不猜发送者，
#      带时间戳的 [ME] 行不再是 bot，无标记的 [ME] 行也不再是 human；
#   §B 装上共享判定库（生产加载链的顺序）后：project/platform/human/unknown 四态与旧词表映射、
#      已确认收据、时间戳、平台标签、人工证据逐项回归。
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
Assert-True "shared-classifier-not-loaded-yet" ($null -eq (Get-Command Get-MessageSourceClassForLine -EA SilentlyContinue))

# --- §A 保守阶梯（旧入口在没有共享判定库时也不得外推）---
Assert-Eq "buyer-with-both-marks" (Get-MessageSource '[BUYER] hello @@TS:1 @@OT:eHl6') 'buyer'
Assert-Eq "buyer-plain" (Get-MessageSource '[BUYER] hello') 'buyer'
# [复核 R7] 时间戳只证明"页面给了时间"，不再证明发送者 => 旧词表也不得判 bot
Assert-Eq "me-with-ts-is-not-bot" (Get-MessageSource '[ME] Got it @@TS:2') 'unknown'
# [复核 R7] 无标记同样不足以认定 human
Assert-Eq "me-without-ts-is-not-human" (Get-MessageSource "[ME] I'll check with the factory") 'unknown'
Assert-Eq "empty-string" (Get-MessageSource '') 'unknown'
Assert-Eq "null" (Get-MessageSource $null) 'unknown'
Assert-Eq "comment-line" (Get-MessageSource '# BUYER: someone') 'unknown'
Assert-Eq "noise-line" (Get-MessageSource '在Alibaba.com上聊天') 'unknown'

# --- §A Test-HumanInterjection：无人工证据不得被当成人工 ---
$r = Test-HumanInterjection @('[BUYER] a', '[ME] bot @@TS:1', '[ME] human')
Assert-Eq "fallback-me-lines-not-human-flag" $r.HasHumanLast $false
Assert-Eq "fallback-me-lines-not-human-source" $r.LastMeSource ''
$r = Test-HumanInterjection @('[BUYER] a')
Assert-Eq "only-buyer-flag" $r.HasHumanLast $false
Assert-Eq "only-buyer-source" $r.LastMeSource ''
$r = Test-HumanInterjection @()
Assert-Eq "empty-input-flag" $r.HasHumanLast $false
$r = Test-HumanInterjection $null
Assert-Eq "null-input-flag" $r.HasHumanLast $false
$r = Test-HumanInterjection @('[BUYER] a', '在Alibaba.com上聊天')
Assert-Eq "noise-only-tail-flag" $r.HasHumanLast $false
Assert-Eq "noise-only-tail-source" $r.LastMeSource ''
# 旧闸门在"没有任何发送者证据"时不再声称尾部是机器人
$g = Get-HumanInterjectionGate @('[BUYER] can you quote', '[ME] Got it @@TS:1')
Assert-Eq "fallback-gate-no-bot-claim" $g.Reason 'no-me-tail'
Assert-Eq "fallback-gate-no-human" $g.HasHumanLast $false

# =============================================================================================
# §B 装上共享判定库（与生产加载链一致：msg_source -> msg_events）
# =============================================================================================
. (Join-Path $scripts "lib\msg_events.ps1")
Assert-True "shared-classifier-loaded" ($null -ne (Get-Command Get-MessageSourceClassForLine -EA SilentlyContinue))

function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function MkMeta([string]$text, [string]$dir, [long]$ts, [string[]]$tags = @(), [string[]]$fields = @(), [string]$mid = '', [string]$st = 'message') {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'; t = (B64 $text); dir = $dir; dirsrc = 'layout'; mid = $mid; ts = $ts
        tprec = $(if ($ts -gt 0) { 'second' } else { 'none' }); st = $st; src = $tags; f = $fields
        at = '2026-10-07T00:00:00Z'; idq = $(if ($mid) { 'platform-id' } elseif ($ts -gt 0) { 'composite' } else { 'unusable' })
    }))
}
function MeLine([string]$text, [long]$ts, [string[]]$tags = @(), [string[]]$fields = @(), [string]$mid = '') {
    $tsPart = ''
    if ($ts -gt 0) { $tsPart = ' @@MT:' + $ts }
    $midPart = ''
    if ($mid) { $midPart = ' @@MID:' + $mid }
    return ('[ME] ' + $text + $tsPart + $midPart + ' ' + (MkMeta $text 'out' $ts $tags $fields $mid))
}
function BuyerLine([string]$text, [long]$ts) { return ('[BUYER] ' + $text + ' @@MT:' + $ts + ' ' + (MkMeta $text 'in' $ts)) }

# 夹具规则集：只有"已验证"的标签/字段才参与判定（与生产默认空规则集形成对照）
$rules = New-MessageSourceRuleSet -VerifiedTags ([pscustomobject]@{ 'tag:自动接待发送' = 'platform' }) -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified'
[void](Set-MessageSourceContext -Rules $rules)

# --- 时间戳：老 [ME] 行（只有 @@TS/@@MT）仍然是 unknown，不是 bot 也不是 human ---
$tsLine = '[ME] Got it @@TS:1791000000000 @@MT:1791000000000'
Assert-Eq "R7-timestamp-only-line-is-unknown" (Get-MessageSource $tsLine) 'unknown'
Assert-Eq "R7-timestamp-only-class-is-unknown" (Get-MessageSourceClass -line $tsLine).Class 'unknown'
Assert-Eq "R7-timestamp-only-evidence-is-timer-marker" (Get-MessageSourceClass -line $tsLine).Evidence 'timer-marker-only'

# --- 无任何标记的 [ME] 行：仍然 unknown（不再外推为人工）---
$plain = '[ME] I will check with the factory'
Assert-Eq "R7-no-marker-line-is-unknown" (Get-MessageSource $plain) 'unknown'
Assert-Eq "R7-no-marker-evidence-is-no-sender-evidence" (Get-MessageSourceClass -line $plain).Evidence 'no-sender-evidence'

# --- 平台标签（已验证独占）=> platform（旧词表 'platform'，不得冒充我方 'bot'）---
$plat = MeLine 'Our team will assist you here.' 1791000100000 @('tag:自动接待发送')
Assert-Eq "R7-verified-platform-tag-class" (Get-MessageSourceClass -line $plat).Class 'platform'
Assert-Eq "R7-verified-platform-tag-legacy-word" (Get-MessageSource $plat) 'platform'

# --- 未验证的通用标签 => unknown，不猜 project/human ---
$unverified = MeLine 'Auto reception reply' 1791000100000 @('tag:去优化')
Assert-Eq "R7-unverified-tag-stays-unknown" (Get-MessageSourceClass -line $unverified).Class 'unknown'
Assert-Eq "R7-unverified-tag-evidence-gap" (Get-MessageSourceClass -line $unverified).Evidence 'raw-labels-only-unverified'

# --- 人工证据（逐条已验证发送者字段）=> human，旧词表 'human' ---
$human = MeLine 'owner typed this' 1791000200000 @() @('sender=owner')
Assert-Eq "R7-verified-human-field-class" (Get-MessageSourceClass -line $human).Class 'human'
Assert-Eq "R7-verified-human-field-legacy-word" (Get-MessageSource $human) 'human'

# --- 已确认收据 => project（旧词表 'bot'：这是"我方自动发送"的既有含义）---
$ours = MeLine 'Shipment booked for you.' 1791000300000
Assert-Eq "R7-receipt-match-is-project" (Get-MessageSourceClass -line $ours -SentRecordMatch $true).Class 'project'
Assert-Eq "R7-project-maps-to-legacy-bot-word" (ConvertTo-LegacyMessageSource 'project') 'bot'
Assert-Eq "R7-plain-our-line-without-receipt-is-unknown" (Get-MessageSource $ours) 'unknown'
Assert-True "R7-is-project-helper-requires-proof" (-not (Test-MessageSourceIsProject $ours))
Assert-True "R7-platform-is-not-project" (-not (Test-MessageSourceIsProject $plat))

# --- 买方行与噪声 ---
Assert-Eq "R7-buyer-line-still-buyer" (Get-MessageSource (BuyerLine 'need price' 1791000400000)) 'buyer'
$flowLine = MeLine '进展 买家确认采购产品规格' 1791000500000
Assert-Eq "R7-flow-card-is-not-an-our-message" (Get-MessageSource $flowLine) 'unknown'

# --- 旧闸门（Test-HumanInterjection / Get-HumanInterjectionGate）在委托之后的行为 ---
$r = Test-HumanInterjection @((BuyerLine 'a' 1791000000000), $human)
Assert-Eq "B-tail-human-flag" $r.HasHumanLast $true
Assert-Eq "B-tail-human-source" $r.LastMeSource 'human'
# 平台行不是人工；旧扫描对它"透明"（继续向上找我方消息）——保守方向：绝不把平台当成人工。
$r = Test-HumanInterjection @((BuyerLine 'a' 1791000000000), $plat)
Assert-Eq "B-platform-tail-is-not-human" $r.HasHumanLast $false
Assert-Eq "B-platform-tail-source" $r.LastMeSource ''
# 平台行之后还有更早的人工消息时，旧扫描仍然让路（保守）；这不是"平台=人工"的结论。
$r = Test-HumanInterjection @((BuyerLine 'a' 1791000000000), $human, $plat)
Assert-Eq "B-legacy-scan-yields-to-older-human" $r.HasHumanLast $true
Assert-Eq "B-legacy-scan-reports-human-not-platform" $r.LastMeSource 'human'
$r = Test-HumanInterjection @((BuyerLine 'a' 1791000000000), $tsLine)
Assert-Eq "B-timestamp-tail-is-not-human" $r.HasHumanLast $false
$r = Test-HumanInterjection @($human, (BuyerLine 'new question' 1791000000000), $plat)
Assert-Eq "B-human-before-buyer-not-blocking" $r.HasHumanLast $false
$r = Test-HumanInterjection @((BuyerLine 'a' 1791000000000), $plat, (BuyerLine 'b' 1791000001000), $human)
Assert-Eq "B-human-after-multi-buyer" $r.HasHumanLast $true
Assert-Eq "B-human-after-multi-buyer-index" $r.HumanIndex 3

$g = Get-HumanInterjectionGate @((BuyerLine 'can you quote' 1791000000000), $human)
Assert-Eq "B-integ-tail-human-skip" $g.Action 'SKIP'
Assert-Eq "B-integ-tail-human-reason" $g.Reason 'human-last'
$g = Get-HumanInterjectionGate @((BuyerLine 'can you quote' 1791000000000))
Assert-Eq "B-integ-new-inquiry-send" $g.Action 'SEND'
Assert-Eq "B-integ-new-inquiry-reason" $g.Reason 'no-me-tail'
# 已确认收据 => project => 旧闸门按"我方自动发送"处理（可发送）
$g = Get-HumanInterjectionGate @((BuyerLine 'can you quote' 1791000000000), $ours)
Assert-Eq "B-integ-plain-tail-keeps-gate-open" $g.Action 'SEND'

$gx = Get-HumanInterjectionGateEx -lines @((BuyerLine 'hi' 1791000000000), $human) -SentMatches @{}
Assert-Eq "B-ex-human-last" $gx.Reason 'human-last'
$gx = Get-HumanInterjectionGateEx -lines @((BuyerLine 'hi' 1791000000000), $tsLine) -SentMatches @{}
Assert-Eq "B-ex-unknown-me-tail" $gx.Reason 'unknown-me-tail'
$gx = Get-HumanInterjectionGateEx -lines @((BuyerLine 'hi' 1791000000000), $plat) -SentMatches @{}
Assert-Eq "B-ex-platform-allows-takeover" $gx.Action 'SEND'

[void](Clear-MessageSourceContext)
Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
