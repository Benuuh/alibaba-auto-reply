# tests\third_fix_pause_source.tests.ps1 - R5：同一快照统一来源分类，索引只用于证据对齐（spec §6 / §10.3）
#
# 失败基线（edge_probes.txt）：'[ME] Confirmed automated answer @@MT:...' 且有已确认发送记录时，
#   人工分支下标恒为 -1 ⇒ 没有取到发送证据 ⇒ 误判成人工回复并暂停 5 分钟。
#
# 分层：isolated（临时运行根内的真实暂停存储；不联网、不开页、不发送）。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== third_fix pause source tests (R5) =='

$isoRoot = Join-Path $env:TEMP ('aar-third-pause-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\human_pause.ps1')
# [2026-10-07 spec §3.2 第 3 条] 无发送者证据的 [ME] 行现在是 unknown，不再外推为人工。
#   本套夹具用逐条已验证的发送者字段提供人工来源证据（字段在 @@META 载荷里，正文无法伪造）。
. (Join-Path $scripts 'lib\msg_events.ps1')
[void](Set-MessageSourceContext -Rules (New-MessageSourceRuleSet -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified-owner-field'))
function New-OwnerMeta([string]$text, [long]$ts) {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'; t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        dir = 'out'; dirsrc = 'layout'; mid = ''; ts = $ts; tprec = 'second'; st = 'message'
        src = @(); f = @('sender=owner'); at = '2026-10-05T00:00:00Z'; idq = 'composite'
    }))
}
function OwnerLine([string]$text, [long]$ts) { return ('[ME] ' + $text + ' @@MT:' + $ts + ' ' + (New-OwnerMeta $text $ts)) }


$script:nowUtc = [datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
function Get-HumanPauseNowUtc { return $script:nowUtc }
function Set-FixNow([string]$LocalIso) {
    $script:nowUtc = [datetime]::SpecifyKind(([datetime]$LocalIso).AddHours(-8), [DateTimeKind]::Utc)
}
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
function PlainMeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@MT:' + $ts) }
function HumanLine([string]$t, [long]$ts) { return (OwnerLine $t $ts) }
$LF = [string][char]10
$ts0 = [long]1791172800000
$buyer = 'Virtual Buyer'
function ClearPause {
    [void](Clear-HumanPause $buyer)
    [void](Clear-SourceUnknownHold $buyer)
    $f = Get-HumanPauseFile
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if (Test-Path ($f + '.bak')) { Remove-Item -LiteralPath ($f + '.bak') -Force -ErrorAction SilentlyContinue }
}
function Sync([string[]]$lines, $matches, $nowUtc) {
    return (Sync-ConversationInterventionState -Buyer $buyer -Lines $lines -SentMatches $matches -NowUtc $nowUtc)
}

# ---- S01 原 ME 只有 MT、SentMatches[0]=true、后接买家 => 不暂停/不 hold ----
ClearPause
Set-FixNow '2026-10-05T12:00:00'
$s01Lines = @((PlainMeLine 'Confirmed automated answer' $ts0), (BLine 'New question' ($ts0 + 1000)))
$s01 = Sync $s01Lines @{ 0 = $true } $script:nowUtc
Check 'S01-confirmed-bot-does-not-pause' (-not [bool]$s01.HumanPauseActive) ([string]$s01.Reason)
Check 'S01-confirmed-bot-does-not-hold' (-not [bool]$s01.UnknownHoldActive) ([string]$s01.Reason)
$ev01 = @(Get-InterventionEvents -Lines $s01Lines -SentMatches @{ 0 = $true } -NowUtc $script:nowUtc)
Eq 'S01-no-human-event-extracted' $ev01.Count 0
$bots01 = @(Get-InterventionEvents -Lines $s01Lines -SentMatches @{ 0 = $true } -NowUtc $script:nowUtc -Bot)
Eq 'S01-bot-event-extracted' $bots01.Count 1
Eq 'S01-bot-uses-real-index' ([int]$bots01[0].LineIndex) 0

# ---- S02 有/无 TS 的已确认机器人：可信发送记录按既有优先级生效 ----
ClearPause
$s02a = Sync @((MeLine 'bot with ts' $ts0), (BLine 'q' ($ts0 + 1000))) @{ 0 = $true } $script:nowUtc
Check 'S02-with-ts-confirmed-bot-no-pause' (-not [bool]$s02a.HumanPauseActive) ''
ClearPause
$s02b = Sync @((PlainMeLine 'bot without ts' $ts0), (BLine 'q' ($ts0 + 1000))) @{ 0 = $true } $script:nowUtc
Check 'S02-without-ts-confirmed-bot-no-pause' (-not [bool]$s02b.HumanPauseActive) ''
ClearPause
$s02c = Sync @('[ME] explicit sender marker @@SRC:bot @@MT:' + $ts0, (BLine 'q' ($ts0 + 1000))) @{} $script:nowUtc
Check 'S02-explicit-bot-marker-no-pause' (-not [bool]$s02c.HumanPauseActive) ''

# ---- S03 相同文本在不同位置，一条有发送证据、另一条没有 => 按真实下标分别分类 ----
ClearPause
$same = 'identical text from our side'
$s03Lines = @((PlainMeLine $same $ts0), (BLine 'mid' ($ts0 + 1000)), (HumanLine $same ($ts0 + 2000)))
$s03ev = @(Get-InterventionEvents -Lines $s03Lines -SentMatches @{ 0 = $true } -NowUtc $script:nowUtc)
Eq 'S03-only-the-unmatched-line-is-human' $s03ev.Count 1
Eq 'S03-human-event-uses-its-own-index' ([int]$s03ev[0].LineIndex) 2
$s03bots = @(Get-InterventionEvents -Lines $s03Lines -SentMatches @{ 0 = $true } -NowUtc $script:nowUtc -Bot)
Eq 'S03-matched-line-is-bot' $s03bots.Count 1
Eq 'S03-bot-index' ([int]$s03bots[0].LineIndex) 0

# ---- S04 截断/重排后重新建立 Matches，重新读盘：对齐正确、身份与截止不靠下标 ----
ClearPause
Set-FixNow '2026-10-05T12:00:00'
$full = @((BLine 'hello' $ts0), (HumanLine 'owner took over' ($ts0 + 60000)), (BLine 'buyer follows up' ($ts0 + 120000)))
$s04a = Sync $full @{} $script:nowUtc
Check 'S04-pause-from-human' ([bool]$s04a.HumanPauseActive) ([string]$s04a.Reason)
$untilA = ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc
Set-FixNow '2026-10-05T12:02:00'
$truncated = @((HumanLine 'owner took over' ($ts0 + 60000)), (BLine 'buyer follows up' ($ts0 + 120000)))
$s04b = Sync $truncated @{} $script:nowUtc
Eq 'S04-reordered-window-keeps-until' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $untilA

# ---- S05 显式 human / unknown + 买家补充 / 12:04 首扫 12:00 人工 => 真暂停与等待成立，绝对截止 12:05 ----
ClearPause
Set-FixNow '2026-10-05T12:04:00'
$humanAt1200 = [long](([System.DateTimeOffset]([datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc))).ToUnixTimeMilliseconds())
$s05 = Sync @((HumanLine 'owner answered' $humanAt1200), (BLine 'and now?' ($humanAt1200 + 1000))) @{} $script:nowUtc
Check 'S05-pause-active' ([bool]$s05.HumanPauseActive) ([string]$s05.Reason)
Eq 'S05-absolute-deadline-is-reply-plus-5' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) ([datetime]::SpecifyKind([datetime]'2026-10-05T04:05:00', [DateTimeKind]::Utc))
# 页面形态 = 带 @@TS/@@MT 时间戳，但**不在**本系统已确认发送记录里 => unknown（既不当作机器人，也不当作人工）。
$unknownLine = '[ME] we replied but the page gave no sender @@TS:' + ($humanAt1200 + 2000) + ' @@MT:' + ($humanAt1200 + 2000)
$s05b = Sync @($unknownLine, (BLine 'and now?' ($humanAt1200 + 3000))) @{} $script:nowUtc
Check 'S05-unknown-hold-active' ([bool]$s05b.UnknownHoldActive) ([string]$s05b.Reason)
Eq 'S05-human-pause-identity-is-the-human-line' ([string](Get-HumanPause $buyer).lastHumanMessageId) (Get-InterventionEventIdentity (HumanLine 'owner answered' $humanAt1200))

# ---- S06 同条重扫 / 历史重扫 / 无可靠时间 / 异常未来 / 存储故障 ----
$untilBefore = ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc
Set-FixNow '2026-10-05T12:06:00'
$s06 = Sync @((HumanLine 'owner answered' $humanAt1200), (BLine 'and now?' ($humanAt1200 + 1000))) @{} $script:nowUtc
Check 'S06-historical-rescan-does-not-pause-again' (-not [bool]$s06.HumanPauseActive) ([string]$s06.Reason)
Eq 'S06-until-unchanged' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $untilBefore
# 无可靠时间：用首次观察锚点建立有界窗口，同一条重扫不延长。
ClearPause
Set-FixNow '2026-10-05T12:00:00'
$noTs = OwnerLine 'owner typed this without any timestamp' 0
$s06b = Sync @($noTs, (BLine 'hi' ($ts0))) @{} $script:nowUtc
Check 'S06-no-reliable-time-creates-bounded-pause' ([bool]$s06b.HumanPauseActive) ''
$untilNoTs = ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc
Eq 'S06-no-reliable-time-anchored-on-first-seen' $untilNoTs $script:nowUtc.AddMinutes(5)
Set-FixNow '2026-10-05T12:02:00'
$s06c = Sync @($noTs, (BLine 'hi' ($ts0))) @{} $script:nowUtc
Eq 'S06-rescan-does-not-extend' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $untilNoTs
# 异常未来时间：不按未来时刻延长，按首次观察有界处理。
ClearPause
Set-FixNow '2026-10-05T12:00:00'
$futureTs = [long](([System.DateTimeOffset]$script:nowUtc.AddHours(5)).ToUnixTimeMilliseconds())
$s06d = Sync @((HumanLine 'future stamped' $futureTs), (BLine 'hi' $ts0)) @{} $script:nowUtc
Check 'S06-anomalous-future-is-bounded' ([bool]$s06d.HumanPauseActive) ''
Eq 'S06-future-does-not-extend-beyond-now-plus-5' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $script:nowUtc.AddMinutes(5)
Check 'S06-future-anomaly-reported' (@($s06d.Anomalies).Count -ge 1) ''
# 存储故障 => SyncOk=false（fail-closed），调用方据此不发送。
$pauseBody = (Get-Command Read-HumanPauseStore).ScriptBlock
function Read-HumanPauseStore { throw 'pause store unreadable' }
$s06e = Sync @((HumanLine 'owner answered' $humanAt1200)) @{} $script:nowUtc
Check 'S06-store-failure-is-fail-closed' (-not [bool]$s06e.SyncOk) ([string]$s06e.Error)
Set-Item Function:Read-HumanPauseStore $pauseBody

# ---- S07 旧误判事件有确切 bot 证据，另有真实人工事件 => 更正误判/有界，不删真实人工暂停、不延长 ----
ClearPause
Set-FixNow '2026-10-05T12:00:00'
$misLine = PlainMeLine 'this was actually our bot' $ts0
# 模拟旧的误判状态：把这条**证据不足**的消息直接登记为人工事件（新规则不会自行这样判定），
#   再验证确切 bot 证据能把这一条更正掉。
$misAnchorUtc = [datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$misEv = [pscustomobject]@{ Identity = (Get-InterventionEventIdentity $misLine); LineIndex = 0; AtUtc = $misAnchorUtc
    TimeTrust = 'reliable'; TimeSource = 'explicit'; Evidence = 'legacy-misclassification'; SourceClass = 'human'; Preview = ''; RawLine = $misLine }
$null = Invoke-InterventionEventSync -Buyer $buyer -HumanEvents @($misEv) -NowUtc $script:nowUtc
$s07a = Sync @($misLine) @{} $script:nowUtc
Check 'S07-misclassified-pause-exists' ([bool]$s07a.HumanPauseActive) ([string]$s07a.Reason)
# 同一快照现在给出**确切** bot 证据 => 更正分类并按其余真实人工事件重算截止（没有真实人工 => 只解除这一个暂停）。
$s07b = Sync @($misLine) @{ 0 = $true } $script:nowUtc
Check 'S07-misclassified-pause-corrected' (-not [bool]$s07b.HumanPauseActive) ([string]$s07b.Reason)
Check 'S07-correction-reported' (@($s07b.CorrectedBotEvents).Count -ge 1) ''
# 另有一条真实人工事件时：更正误判项，但真实人工暂停必须保留且不被延长。
ClearPause
$realHuman = HumanLine 'a real human reply' ($ts0 + 60000)
$s07c = Sync @($misLine) @{} $script:nowUtc
$untilMis = ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc
$s07d = Sync @($misLine, $realHuman) @{ 0 = $true } $script:nowUtc
Check 'S07-real-human-pause-survives' ([bool]$s07d.HumanPauseActive) ([string]$s07d.Reason)
Eq 'S07-real-human-identity-kept' ([string](Get-HumanPause $buyer).lastHumanMessageId) (Get-InterventionEventIdentity $realHuman)
# 更正后的截止只由**真实人工事件**决定（12:01 + 5 分钟 = 12:06），既不沿用误判项，也不额外延长。
$realHumanUtc = [datetime]::SpecifyKind([datetime]'2026-10-05T04:01:00', [DateTimeKind]::Utc)
Eq 'S07-recomputed-from-real-human-only' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $realHumanUtc.AddMinutes(5)
# 更正不引入额外延长：同一快照再同步一次，截止不变（也不因为"又扫到一次"而顺延）。
$untilCorrected = ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc
Set-FixNow '2026-10-05T12:02:00'
[void](Sync @($misLine, $realHuman) @{ 0 = $true } $script:nowUtc)
Eq 'S07-correction-is-idempotent' (ConvertTo-HumanPauseUtc (Get-HumanPause $buyer).untilUtc) $untilCorrected
Check 'S07-not-extended-beyond-real-human' ($untilCorrected -le $realHumanUtc.AddMinutes(5)) ''
Check 'S07-correction-does-not-touch-real-event' (-not ((Get-InterventionEventIdentity $realHuman) -in @($s07d.CorrectedBotEvents))) ''

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
