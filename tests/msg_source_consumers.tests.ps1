# tests\msg_source_consumers.tests.ps1
# [复核 R7] 旧来源入口的**实际消费者**回归：human_style 的"老板手打"采集、reply_metrics 的
#   安抚语重复与尺寸引导指标，都必须经由共享四态判定，并正确处理
#   未知 / 只有时间戳 / 平台标签 / 已确认收据（project）四类输入。
# isolated 层：真实 sent_records / state 读取都落在测试运行根内；不访问浏览器/模型/通知。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\outbound_receipts.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\human_style.ps1')
. (Join-Path $scripts 'lib\reply_metrics.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output ("FAIL: " + $name) }
}
$lf = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function MkMeta([string]$text, [string]$dir, [long]$ts, [string[]]$tags = @(), [string[]]$fields = @(), [string]$st = 'message') {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'; t = (B64 $text); dir = $dir; dirsrc = 'layout'; mid = ''; ts = $ts
        tprec = $(if ($ts -gt 0) { 'second' } else { 'none' }); st = $st; src = $tags; f = $fields
        at = '2026-10-07T00:00:00Z'; idq = $(if ($ts -gt 0) { 'composite' } else { 'unusable' })
    }))
}
function MeLine([string]$text, [long]$ts, [string[]]$tags = @(), [string[]]$fields = @(), [string]$suffix = '') {
    $tsPart = ''
    if ($ts -gt 0) { $tsPart = ' @@MT:' + $ts }
    return ('[ME] ' + $text + $tsPart + ' ' + (MkMeta $text 'out' $ts $tags $fields) + $suffix)
}
function BuyerLine([string]$text, [long]$ts) { return ('[BUYER] ' + $text + ' @@MT:' + $ts + ' ' + (MkMeta $text 'in' $ts)) }

$rules = New-MessageSourceRuleSet -VerifiedTags ([pscustomobject]@{ 'tag:自动接待发送' = 'platform' }) -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified'
[void](Set-MessageSourceContext -Rules $rules)

# ------------------------------------------------------------------ 逐行来源（消费者共用的入口）
$known = MeLine 'proven platform greeting' 1791000000000 @('tag:自动接待发送')
$humanLine = MeLine 'owner hand typed words' 1791000001000 @() @('sender=owner')
$timerLine = MeLine 'we said this earlier' 1791000002000
$plainLine = '[ME] no markers at all'
$snapshot = @(
    (BuyerLine 'question' 1790999000000),
    $known,
    $humanLine,
    $timerLine,
    $plainLine
) -join $lf
$sources = @(Get-SnapshotLineSources -snapshotContent $snapshot)
Check 'R7-line-sources-cover-every-line' ($sources.Count -eq 5)
Check 'R7-buyer-line-classified-buyer' ($sources[0].Source -eq 'buyer')
Check 'R7-verified-platform-tag-classified-platform' ($sources[1].Source -eq 'platform')
Check 'R7-verified-human-field-classified-human' ($sources[2].Source -eq 'human' -and $sources[2].Evidence -eq 'verified-human-sender-evidence')
Check 'R7-timer-only-line-is-unknown' ($sources[3].Source -eq 'unknown' -and $sources[3].Evidence -eq 'timer-marker-only')
Check 'R7-no-marker-line-is-unknown' ($sources[4].Source -eq 'unknown' -and $sources[4].Evidence -eq 'no-sender-evidence')

# ------------------------------------------------------------------ 安抚语重复：不再把未知/平台算成我方
$unknownRepeat = @((BuyerLine 'hi' 1790999000000), (MeLine 'no rush, take your time' 1791000000000), (MeLine 'no rush again' 1791000001000)) -join $lf
$spUnknown = Get-SoothingPhraseRepeatStats -snapshotContent $unknownRepeat
Check 'R7-soothing-ignores-unknown-our-lines' ([int]$spUnknown.Repeats -eq 0 -and [int]$spUnknown.UnprovenOurLines -eq 2 -and [int]$spUnknown.ProvenOurLines -eq 0)
$platformRepeat = @((BuyerLine 'hi' 1790999000000), (MeLine 'no rush' 1791000000000 @('tag:自动接待发送')), (MeLine 'no rush' 1791000001000 @('tag:自动接待发送'))) -join $lf
$spPlatform = Get-SoothingPhraseRepeatStats -snapshotContent $platformRepeat
Check 'R7-soothing-ignores-platform-lines' ([int]$spPlatform.Repeats -eq 0 -and [int]$spPlatform.PlatformLines -eq 2)

# ------------------------------------------------------------------ 已确认收据 => project => 计入我方
# 只含一个安抚语模式，便于断言"重复一次"（多模式文本会各自计一次重复）
$replyText = 'no rush, thank you'
$replyAt = 1791000900000
$receipt = New-ConfirmedOutboundReceipt -Buyer 'Buyer Metrics' -Text $replyText -Before @() -After @(
    [pscustomobject]@{ MessageId = ''; MessageTime = [string]$replyAt; TimePrecision = 'second'; Text = $replyText; IsMine = $true }
)
Check 'R7-fixture-receipt-valid' ([bool]$receipt.Valid)
Check 'R7-fixture-receipt-recorded' ([bool](Add-SentRecord -Buyer 'Buyer Metrics' -Text $replyText -Receipt $receipt))
# 第二次发送：同文**不同时刻**，各自一条收据（同文同刻会被正确地判成身份不唯一，不能拿来当证据）
$replyAt2 = $replyAt + 1000
$receipt2 = New-ConfirmedOutboundReceipt -Buyer 'Buyer Metrics' -Text $replyText -Before @() -After @(
    [pscustomobject]@{ MessageId = ''; MessageTime = [string]$replyAt2; TimePrecision = 'second'; Text = $replyText; IsMine = $true }
)
Check 'R7-fixture-second-receipt-valid' ([bool]$receipt2.Valid)
Check 'R7-fixture-second-receipt-recorded' ([bool](Add-SentRecord -Buyer 'Buyer Metrics' -Text $replyText -Receipt $receipt2))
$receiptSnapshot = @(
    (BuyerLine 'hi' 1790999000000),
    (MeLine $replyText $replyAt),
    (MeLine $replyText $replyAt2)
) -join $lf
$spNoBuyer = Get-SoothingPhraseRepeatStats -snapshotContent $receiptSnapshot
Check 'R7-soothing-without-buyer-does-not-claim-our-lines' ([int]$spNoBuyer.Repeats -eq 0 -and [int]$spNoBuyer.UnprovenOurLines -eq 2)
$spBuyer = Get-SoothingPhraseRepeatStats -snapshotContent $receiptSnapshot -Buyer 'Buyer Metrics'
Check 'R7-soothing-counts-receipt-proven-lines' ([int]$spBuyer.Repeats -eq 1 -and [int]$spBuyer.ProvenOurLines -eq 2 -and [int]$spBuyer.UnprovenOurLines -eq 0)

# ------------------------------------------------------------------ 尺寸引导：只有证明是我方的行才算
$guideUnknown = @((BuyerLine 'what sizes' 1790999000000), (MeLine 'please send carton sizes' 1791000000000)) -join $lf
Check 'R7-dimension-guidance-rejects-unknown' (-not (Test-DimensionGuidanceHit -snapshotContent $guideUnknown))
$guidePlatform = @((BuyerLine 'what sizes' 1790999000000), (MeLine 'please send carton sizes' 1791000000000 @('tag:自动接待发送'))) -join $lf
Check 'R7-dimension-guidance-rejects-platform' (-not (Test-DimensionGuidanceHit -snapshotContent $guidePlatform))
$guideReceiptText = 'rough size is fine, carton sizes help'
$guideAt = 1791000800000
$guideReceipt = New-ConfirmedOutboundReceipt -Buyer 'Buyer Guide' -Text $guideReceiptText -Before @() -After @(
    [pscustomobject]@{ MessageId = ''; MessageTime = [string]$guideAt; TimePrecision = 'second'; Text = $guideReceiptText; IsMine = $true }
)
Check 'R7-guide-fixture-receipt-valid' ([bool]$guideReceipt.Valid)
Check 'R7-guide-fixture-receipt-recorded' ([bool](Add-SentRecord -Buyer 'Buyer Guide' -Text $guideReceiptText -Receipt $guideReceipt))
$guideSnapshot = @((BuyerLine 'what sizes' 1790999000000), (MeLine $guideReceiptText $guideAt)) -join $lf
$guideEv = Get-DimensionGuidanceEvidence -snapshotContent $guideSnapshot -Buyer 'Buyer Guide'
Check 'R7-dimension-guidance-accepts-receipt-proven-line' ($guideEv.Hit -and $guideEv.Source -eq 'project' -and $guideEv.Evidence -eq 'confirmed-project-event-binding')

# ------------------------------------------------------------------ human_style：只采集有出处的人工消息
$snapDir = Join-Path (Get-SkillPath 'data') 'consumer_snapshots'
if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
$snapFile = Join-Path $snapDir 'msgs_20261007_120000.txt'
$humanBody = 'owner hand typed words'
$snapLines = @(
    '# BUYER: Buyer Human',
    (BuyerLine 'question' 1790999000000),
    (MeLine 'platform greeting' 1791000000000 @('tag:自动接待发送')),
    (MeLine $humanBody 1791000001000 @() @('sender=owner')),
    (MeLine 'timer only our line' 1791000002000),
    '[ME] no markers at all'
)
[IO.File]::WriteAllText($snapFile, ($snapLines -join $lf), (New-Object Text.UTF8Encoding($false)))
$human = @(Get-HumanMessages $snapDir)
Check 'R7-human-style-collects-only-evidenced-human' ($human.Count -eq 1 -and $human[0].Text -eq $humanBody)
Check 'R7-human-style-reports-source-and-evidence' ($human[0].Source -eq 'human' -and $human[0].Evidence -eq 'verified-human-sender-evidence')
$styleText = (Get-HumanStyleStats $snapDir) -join $lf
Check 'R7-human-style-stats-count-the-one-sample' ($styleText -match '人工消息条数: 1')
Remove-Item -LiteralPath $snapFile -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ 平台消息不得被当成人工
$platOnly = Join-Path (Get-SkillPath 'data') 'consumer_snapshots_platform'
if (-not (Test-Path $platOnly)) { New-Item -ItemType Directory -Path $platOnly -Force | Out-Null }
$platFile = Join-Path $platOnly 'msgs_20261007_120100.txt'
[IO.File]::WriteAllText($platFile, (@('# BUYER: Buyer Plat', (BuyerLine 'q' 1790999000000), (MeLine 'platform auto reply' 1791000000000 @('tag:自动接待发送'))) -join $lf), (New-Object Text.UTF8Encoding($false)))
Check 'R7-human-style-rejects-platform-lines' (@(Get-HumanMessages $platOnly).Count -eq 0)
Remove-Item -LiteralPath $platFile -Force -ErrorAction SilentlyContinue

[void](Clear-MessageSourceContext)
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
