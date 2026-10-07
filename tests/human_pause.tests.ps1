# tests\human_pause.tests.ps1 - 人工临时暂停、可信人工来源与已确认发送记录（2026-10-05 spec §2.1/§2.2/§7 + 八项补修 F3）
#
# 覆盖：
#   P1  第一次可信人工回复 ⇒ 截止 = **该回复的绝对时刻** + 5 分钟
#   P2  重复扫描同一条人工消息 ⇒ 截止不变（不因"又扫到一次"延长）
#   P3  更晚的新人工回复 ⇒ 只按这条新回复延长
#   P4  更早/同一条旧回复 ⇒ 不缩短、不改变
#   P5  暂停状态持久化：重新读盘后截止时间一致（重启不提前解除、不重新计时）
#   P6  到期 → 不再 active（到期本身不产生任何发送动作）
#   P7  只有 Class='human' 的可信人工回复才计时；只有时间戳的 [ME] 不开始、不延长（unknown 不算人工）
#   P8  本系统已确认发送记录 ⇒ 该 [ME] 判为 bot（不当作人工），并据此让闸门放行
#   P9  会话行里没有可信人工回复 ⇒ 不创建暂停
#   P10 显式人工接管名单优先由调用方处理：暂停到期也不解除名单（本模块不改名单）
#   F3-* 八项补修 F3 的验收：绝对时间口径、历史重扫不推进、换行号/窗口截断、事件身份、
#        首次观察锚点、异常未来时刻、读取失败 fail-closed
#
# 隔离：临时运行根 + 隔离标记；所有状态写入都落在该根内。
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

Write-Output '== human_pause tests =='

$isoRoot = Join-Path $env:TEMP ('aar-pause-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\human_pause.ps1')

# [2026-10-07 spec §3.2 第 3 条] 无发送者证据的 [ME] 行现在是 unknown，不再外推为人工。
#   本套夹具用"已验证的人工发送者字段"提供人工来源证据（字段来自逐条 @@META 载荷，正文无法伪造）。
$fixtureRules = New-MessageSourceRuleSet -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified-owner-field'
[void](Set-MessageSourceContext -Rules $fixtureRules)
function New-FixtureMeta([string]$text, [long]$ts, [string[]]$fields = @(), [string[]]$tags = @()) {
    $meta = [ordered]@{
        v = 'msgevent-2026-10-07.1'
        t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        dir = 'out'; dirsrc = 'layout'; mid = ''; ts = $ts; tprec = 'second'
        st = 'message'; src = $tags; f = $fields; at = '2026-10-05T00:00:00Z'
        idq = $(if ($ts -gt 0) { 'composite' } else { 'unusable' })
    }
    return (ConvertTo-MessageMetaMarker ([pscustomobject]$meta))
}

$buyer = 'Buyer Pause'
# 绝对时间口径：夹具的"现在"就是一个 UTC 时刻；消息的 @@MT 是同一口径的 epoch 毫秒。
$t0 = [datetime]::SpecifyKind([datetime]'2026-10-05T12:00:00', [DateTimeKind]::Utc)
function TsOf([datetime]$Utc) { return ([System.DateTimeOffset]$Utc).ToUnixTimeMilliseconds() }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@MT:' + $ts + ' ' + (New-FixtureMeta $t $ts @('sender=owner'))) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' ' + (New-FixtureMeta $t $ts)) }
$ts0 = TsOf $t0

try {
    # ---- P1 ----
    $line1 = MeLine 'first human answer' $ts0
    $r1 = Update-HumanPauseFromLines -Buyer $buyer -Lines @($line1) -NowUtc $t0
    Eq 'P1-reason-started' $r1.Reason 'started'
    Check 'P1-until-is-reply-plus-5min' ((ConvertTo-HumanPauseUtc $r1.Until) -eq $t0.AddMinutes(5)) ('until=' + $r1.Until)
    $st = Test-HumanPauseActive -Buyer $buyer -NowUtc $t0.AddMinutes(4)
    Check 'P1-active-inside-window' $st.Active
    Eq 'P1-remaining-seconds' $st.RemainingSec 60

    # ---- P2 ----
    $r2 = Update-HumanPauseFromLines -Buyer $buyer -Lines @($line1) -NowUtc $t0.AddMinutes(3)
    Eq 'P2-same-identity-not-extended' $r2.Reason 'unchanged-same-message'
    Check 'P2-until-unchanged' ((ConvertTo-HumanPauseUtc $r2.Until) -eq $t0.AddMinutes(5)) ('until=' + $r2.Until)

    # ---- P3 ----
    $t3 = $t0.AddMinutes(3)
    $line3 = MeLine 'second human answer' (TsOf $t3)
    $r3 = Update-HumanPauseFromLines -Buyer $buyer -Lines @($line3) -NowUtc $t3
    Eq 'P3-extended-by-new-reply' $r3.Reason 'extended'
    Check 'P3-until-is-new-reply-plus-5min' ((ConvertTo-HumanPauseUtc $r3.Until) -eq $t3.AddMinutes(5)) ('until=' + $r3.Until)

    # ---- P4 ----
    $line0 = MeLine 'older human answer' (TsOf $t0.AddMinutes(-10))
    $r4 = Update-HumanPauseFromLines -Buyer $buyer -Lines @($line0) -NowUtc $t3
    Eq 'P4-older-reply-does-not-change' $r4.Reason 'unchanged-older-message'
    Check 'P4-until-still-t3-plus-5' ((ConvertTo-HumanPauseUtc (Test-HumanPauseActive -Buyer $buyer -NowUtc $t3).Until) -eq $t3.AddMinutes(5))

    # ---- P5（持久化：重新读盘） ----
    $file = Get-HumanPauseFile
    Check 'P5-store-file-exists' (Test-Path $file) $file
    $reloaded = Get-HumanPause $buyer
    Check 'P5-until-survives-reload' ((ConvertTo-HumanPauseUtc $reloaded.untilUtc) -eq $t3.AddMinutes(5)) ('untilUtc=' + $reloaded.untilUtc)
    Eq 'P5-identity-survives-reload' ([string]$reloaded.lastHumanMessageId) (Get-InterventionEventIdentity $line3)
    Check 'P5-store-inside-isolated-root' (Test-AarPathUnder $file $isoRoot) $file

    # ---- P6 ----
    $exp = Test-HumanPauseActive -Buyer $buyer -NowUtc $t3.AddMinutes(5)
    Check 'P6-expired-not-active' (-not $exp.Active)
    Eq 'P6-expired-reason' $exp.Reason 'expired'
    Check 'P6-unknown-buyer-has-no-pause' (-not (Test-HumanPauseActive -Buyer 'Nobody' -NowUtc $t0).Active)

    # ---- P7: 可信人工回复识别（证据化） ----
    $linesBuyerOnly = @('[BUYER] hi @@TS:100 @@MT:100')
    Eq 'P7-no-human-when-only-buyer' (@(Get-TrustedHumanReplies -lines $linesBuyerOnly).Count) 0
    $linesTimerOnly = @('[ME] sure, I will check @@TS:100 @@MT:100')
    Eq 'P7-timer-only-is-not-human' (@(Get-TrustedHumanReplies -lines $linesTimerOnly).Count) 0
    $clsTimer = Get-MessageSourceClass $linesTimerOnly[0] $false
    Eq 'P7-timer-only-class' $clsTimer.Class 'unknown'
    Eq 'P7-timer-only-evidence' $clsTimer.Evidence 'timer-marker-only'
    # [spec §3.2 第 3 条] 无标记、无发送者证据的 [ME] 行**不再**自动认定为人工。
    $linesHuman = @('[ME] I will handle this one myself')
    Eq 'P7-plain-me-is-not-human-any-more' (@(Get-TrustedHumanReplies -lines $linesHuman).Count) 0
    Eq 'P7-plain-me-evidence-gap' (Get-MessageSourceClass $linesHuman[0] $false).Evidence 'no-sender-evidence'
    # 行内 @@SRC 文本不是可信元数据（正文本身就能写出同样的字符串，A06）。
    $linesExplicit = @('[ME] hello @@SRC:human @@MT:100')
    Eq 'P7-inline-marker-not-metadata' (@(Get-TrustedHumanReplies -lines $linesExplicit).Count) 0
    # 只有逐条 @@META 里经过规则确认的发送者字段才算人工证据。
    $linesVerified = @(MeLine 'I will handle this one myself' 100)
    Eq 'P7-verified-owner-field-is-human' (@(Get-TrustedHumanReplies -lines $linesVerified).Count) 1

    # unknown 不开始暂停
    $buyerU = 'Buyer Unknown'
    $upd = Update-HumanPauseFromLines -Buyer $buyerU -Lines $linesTimerOnly -NowUtc $t0
    Eq 'P7-unknown-does-not-start-pause' $upd.Reason 'no-trusted-human-reply'
    Check 'P7-unknown-no-pause-entry' ($null -eq (Get-HumanPause $buyerU))

    # 闸门：unknown 尾巴 ⇒ 不发送（既不当作机器人，也不当作人工）
    $gate = Get-HumanInterjectionGateEx -lines $linesTimerOnly
    Eq 'P7-gate-skips-unknown-tail' $gate.Action 'SKIP'
    Eq 'P7-gate-reason' $gate.Reason 'unknown-me-tail'
    Check 'P7-gate-not-counted-as-human' (-not $gate.HasHumanLast)
    $gateHuman = Get-HumanInterjectionGateEx -lines @('[BUYER] hi', (MeLine 'answered by hand' 100))
    Eq 'P7-gate-skips-human-last' $gateHuman.Reason 'human-last'
    Eq 'P7-gate-unverified-me-tail-is-unknown' ((Get-HumanInterjectionGateEx -lines @('[BUYER] hi', '[ME] answered by hand')).Reason) 'unknown-me-tail'
    $gateBuyer = Get-HumanInterjectionGateEx -lines @('[ME] bot wrote @@TS:1', '[BUYER] new question')
    Eq 'P7-gate-sends-after-buyer' $gateBuyer.Action 'SEND'

    # ---- P8: 已确认发送记录 ----
    $buyerS = 'Buyer Sent'
    $null = Add-SentRecord -Buyer $buyerS -Text 'Could you share the consignee name and delivery address?' -Receipt (New-ConfirmedOutboundReceipt -Buyer $buyerS -Text 'Could you share the consignee name and delivery address?' -Before @() -After @([pscustomobject]@{MessageTime='1791172800000';TimePrecision='millisecond';Text='Could you share the consignee name and delivery address?';IsMine=$true}))
    Check 'P8-text-alone-cannot-match' (-not (Test-SentRecordMatch -Buyer $buyerS -Text 'Could you share the consignee name and delivery address?'))
    Check 'P8-normalised-text-alone-cannot-match' (-not (Test-SentRecordMatch -Buyer $buyerS -Text 'Could  you share the CONSIGNEE name and delivery address?'))
    Check 'P8-record-no-false-positive' (-not (Test-SentRecordMatch -Buyer $buyerS -Text 'What is your best price?'))
    Check 'P8-record-isolated-per-buyer' (-not (Test-SentRecordMatch -Buyer 'Someone Else' -Text 'Could you share the consignee name and delivery address?'))
    $linesSent = @('[ME] Could you share the consignee name and delivery address? @@TS:1791172800000 @@MT:1791172800000')
    $map = Get-SentRecordMatchIndexes -Buyer $buyerS -Lines $linesSent
    Check 'P8-index-map-marks-record-line' ($map.ContainsKey(0))
    $clsSent = Get-MessageSourceClass $linesSent[0] ([bool]$map.ContainsKey(0))
    # [spec §3.2] 我方来源四态：唯一命中同一事件的本项目收据 ⇒ project（旧词 'bot' 已被取代）。
    Eq 'P8-record-line-is-project' $clsSent.Class 'project'
    Eq 'P8-record-line-evidence' $clsSent.Evidence 'confirmed-project-event-binding'
    $gateSent = Get-HumanInterjectionGateEx -lines $linesSent -SentMatches $map
    Eq 'P8-gate-sends-when-our-message-proven' $gateSent.Action 'SEND'
    Eq 'P8-gate-reason-bot' $gateSent.Reason 'bot-last'
    # 同一条消息在**没有**发送记录时是 unknown ⇒ 闸门不放行（这正是本轮要求的差别）
    $gateNoRecord = Get-HumanInterjectionGateEx -lines $linesSent
    Eq 'P8-without-record-gate-blocks' $gateNoRecord.Reason 'unknown-me-tail'
    # 记录持久化
    # 注意：PS 5.1 里单个 PSCustomObject 没有 .Count（返回 $null）⇒ 断言必须显式 @() 包裹
    Check 'P8-store-persisted' (@(Get-SentRecords -Buyer $buyerS).Count -ge 1)
    # 已确认发送记录 ⇒ 不触发人工暂停
    $buyerBot = 'Buyer Bot Record'
    $botText = 'our own bot answer'
    $null = Add-SentRecord -Buyer $buyerBot -Text $botText -Receipt (New-ConfirmedOutboundReceipt -Buyer $buyerBot -Text $botText -Before @() -After @([pscustomobject]@{MessageTime=[string]$ts0;TimePrecision='millisecond';Text=$botText;IsMine=$true}))
    $botLine = '[ME] ' + $botText + ' @@TS:' + $ts0 + ' @@MT:' + $ts0
    $mapBot = Get-SentRecordMatchIndexes -Buyer $buyerBot -Lines @($botLine)
    Eq 'P8-bot-line-is-a-confirmed-send' ([string](Get-MessageSourceClass $botLine ([bool]$mapBot.ContainsKey(0))).Class) 'project'
    $null = Update-HumanPauseFromLines -Buyer $buyerBot -Lines @($botLine) -SentMatches $mapBot -NowUtc $t0
    Check 'P8-confirmed-bot-does-not-pause' ($null -eq (Get-HumanPause $buyerBot)) ''

    # ---- P9 ----
    $upd9 = Update-HumanPauseFromLines -Buyer 'Buyer Quiet' -Lines @('[BUYER] hello @@TS:1 @@MT:1') -NowUtc $t0
    Eq 'P9-no-human-no-pause' $upd9.Reason 'no-trusted-human-reply'

    # 从会话行开始暂停（带时间戳的人工行：无 @@TS ⇒ 可信人工）
    $line9 = MeLine 'let me answer' $ts0
    $upd10 = Update-HumanPauseFromLines -Buyer 'Buyer Lines' -Lines @((BLine 'hi' $ts0), $line9) -NowUtc $t0
    Check 'P9-human-line-starts-pause' ($upd10.Started -and $null -ne $upd10.Until)
    Check 'P9-pause-entry-exists' ($null -ne (Get-HumanPause 'Buyer Lines'))
    Check 'P9-until-is-absolute-reply-time-plus-5' ((ConvertTo-HumanPauseUtc (Get-HumanPause 'Buyer Lines').untilUtc) -eq $t0.AddMinutes(5)) ''

    # ---- P10 ----
    Check 'P10-takeover-list-untouched-by-pause-module' (-not (Test-Path (Join-Path (Get-SkillPath 'data') 'manual_override.json')))

    # =========================================================================================
    # F3 - 八项补修验收（绝对时间 / 事件身份 / 历史重扫 / 首次观察锚点 / 异常时间 / 存储失败）
    # =========================================================================================
    # F3-a 12:00 人工回复，12:04 首次扫描 ⇒ 截止仍是 12:05（不是 12:09）
    $bA = 'Buyer F3a'
    $rA = Update-HumanPauseFromLines -Buyer $bA -Lines @((MeLine 'answered at noon' $ts0)) -NowUtc $t0.AddMinutes(4)
    Check 'F3a-until-is-reply-time-plus-5-not-scan-time' ((ConvertTo-HumanPauseUtc $rA.Until) -eq $t0.AddMinutes(5)) ('until=' + $rA.Until)
    Check 'F3a-active-at-1204' ([bool](Test-HumanPauseActive -Buyer $bA -NowUtc $t0.AddMinutes(4)).Active) ''
    Check 'F3a-expired-at-1206' (-not [bool](Test-HumanPauseActive -Buyer $bA -NowUtc $t0.AddMinutes(6)).Active) ''

    # F3-b 历史人工 11:59、12:00，12:06 扫描 ⇒ 不活动，绝不能变成 12:11
    $bB = 'Buyer F3b'
    $hist = @((MeLine 'earlier human answer' (TsOf $t0.AddMinutes(-1))), (MeLine 'latest human answer' $ts0))
    $rB = Update-HumanPauseFromLines -Buyer $bB -Lines $hist -NowUtc $t0.AddMinutes(6)
    Check 'F3b-history-does-not-restart-pause' (-not [bool](Test-HumanPauseActive -Buyer $bB -NowUtc $t0.AddMinutes(6)).Active) ''
    Check 'F3b-until-is-still-1205' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bB).untilUtc) -eq $t0.AddMinutes(5)) ((Get-HumanPause $bB).untilUtc)
    $rB2 = Update-HumanPauseFromLines -Buyer $bB -Lines $hist -NowUtc $t0.AddMinutes(6).AddSeconds(30)
    Check 'F3b-rescan-keeps-until' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bB).untilUtc) -eq $t0.AddMinutes(5)) ''

    # F3-c 同两条历史消息换行号 / 截断窗口后重扫 ⇒ 截止保持，旧消息不重新暂停
    $bC = 'Buyer F3c'
    $null = Update-HumanPauseFromLines -Buyer $bC -Lines @((BLine 'prefix noise' (TsOf $t0.AddMinutes(-5))), $hist[0], $hist[1]) -NowUtc $t0
    $untilC = ConvertTo-HumanPauseUtc (Get-HumanPause $bC).untilUtc
    $null = Update-HumanPauseFromLines -Buyer $bC -Lines @($hist[0], $hist[1]) -NowUtc $t0.AddMinutes(2)
    Check 'F3c-line-number-change-does-not-extend' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bC).untilUtc) -eq $untilC) ('was=' + $untilC + ' now=' + (Get-HumanPause $bC).untilUtc)
    $null = Update-HumanPauseFromLines -Buyer $bC -Lines @($hist[1]) -NowUtc $t0.AddMinutes(3)
    Check 'F3c-truncated-window-does-not-extend' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bC).untilUtc) -eq $untilC) ''

    # F3-d 12:03 的新人工回复 ⇒ 截止推进到 12:08
    $bD = 'Buyer F3d'
    $null = Update-HumanPauseFromLines -Buyer $bD -Lines @((MeLine 'first human answer' $ts0)) -NowUtc $t0
    $null = Update-HumanPauseFromLines -Buyer $bD -Lines @((MeLine 'first human answer' $ts0), (MeLine 'second human answer' (TsOf $t0.AddMinutes(3)))) -NowUtc $t0.AddMinutes(3)
    Check 'F3d-new-human-reply-extends-to-1208' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bD).untilUtc) -eq $t0.AddMinutes(8)) ((Get-HumanPause $bD).untilUtc)

    # F3-e 原文相同但逐条时间不同的两次人工回复 ⇒ 第二条按新事件处理
    $bE = 'Buyer F3e'
    $sameText1 = MeLine 'ok' $ts0
    $sameText2 = MeLine 'ok' (TsOf $t0.AddMinutes(2))
    Check 'F3e-same-text-different-time-different-identity' ((Get-InterventionEventIdentity $sameText1) -ne (Get-InterventionEventIdentity $sameText2)) ''
    $null = Update-HumanPauseFromLines -Buyer $bE -Lines @($sameText1) -NowUtc $t0
    $rE = Update-HumanPauseFromLines -Buyer $bE -Lines @($sameText1, $sameText2) -NowUtc $t0.AddMinutes(2)
    Eq 'F3e-second-identical-text-is-a-new-event' $rE.Reason 'extended'
    Check 'F3e-until-is-second-reply-plus-5' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bE).untilUtc) -eq $t0.AddMinutes(7)) ''

    # F3-f 没有可靠时间的同一条人工消息：重扫/重启都用同一个首次观察时刻，不延长
    $bF = 'Buyer F3f'
    # [spec §3.2] 人工来源由逐条已验证字段提供；本条**没有**可靠逐条时间，走首次观察锚点。
    $noTime = '[ME] I will answer this one myself ' + (New-FixtureMeta 'I will answer this one myself' 0 @('sender=owner'))
    $rF1 = Update-HumanPauseFromLines -Buyer $bF -Lines @($noTime) -NowUtc $t0
    Eq 'F3f-no-time-uses-first-observation' $rF1.Reason 'started'
    Check 'F3f-first-observation-window' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bF).untilUtc) -eq $t0.AddMinutes(5)) ((Get-HumanPause $bF).untilUtc)
    $rF2 = Update-HumanPauseFromLines -Buyer $bF -Lines @($noTime) -NowUtc $t0.AddMinutes(3)
    Eq 'F3f-rescan-keeps-first-observation' $rF2.Reason 'unchanged-same-message'
    Check 'F3f-until-unchanged-after-rescan' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bF).untilUtc) -eq $t0.AddMinutes(5)) ''
    Eq 'F3f-time-source-is-observation' ([string](Get-HumanPause $bF).timeSource) 'none'

    # F3-g 异常未来时刻：记录异常、按有界保守策略处理，绝不无限延长
    $bG = 'Buyer F3g'
    $futureTs = TsOf $t0.AddHours(5)
    $rG = Update-HumanPauseFromLines -Buyer $bG -Lines @((MeLine 'timestamp from the future' $futureTs)) -NowUtc $t0
    Check 'F3g-future-time-anomaly-recorded' (@($rG.Anomalies).Count -ge 1) ('anomalies=' + @($rG.Anomalies).Count)
    Check 'F3g-future-time-is-bounded' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bG).untilUtc) -le $t0.AddMinutes(5)) ((Get-HumanPause $bG).untilUtc)
    Eq 'F3g-future-time-marked' ([string](Get-HumanPause $bG).timeTrust) 'anomalous-future'

    # F3-h 状态读取失败 ⇒ SyncOk=false（调用方本轮不发送）
    $bH = 'Buyer F3h'
    $pausePath = Get-HumanPauseFile
    $backupText = $null
    if (Test-Path -LiteralPath $pausePath) { $backupText = [System.IO.File]::ReadAllText($pausePath, [System.Text.Encoding]::UTF8) }
    Remove-Item -LiteralPath $pausePath -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $pausePath -Force | Out-Null
    $rH = Update-HumanPauseFromLines -Buyer $bH -Lines @((MeLine 'human while store is broken' $ts0)) -NowUtc $t0
    Check 'F3h-read-failure-is-not-silently-ok' (-not [bool]$rH.SyncOk) ('reason=' + $rH.Reason)
    $syncH = Sync-ConversationInterventionState -Buyer $bH -Lines @((MeLine 'human while store is broken' $ts0)) -NowUtc $t0
    Check 'F3h-sync-reports-failure' (-not [bool]$syncH.SyncOk) ('reason=' + $syncH.Reason)
    Check 'F3h-sync-failure-is-not-active-pause' (-not [bool]$syncH.HumanPauseActive) ''
    Remove-Item -LiteralPath $pausePath -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $backupText) { [System.IO.File]::WriteAllText($pausePath, $backupText, (New-Object System.Text.UTF8Encoding($true))) }

    # F3-i 不同宿主时区：同一条消息在"注入 UTC 时钟"下的截止与宿主时区无关
    $bI = 'Buyer F3i'
    $rI = Update-HumanPauseFromLines -Buyer $bI -Lines @((MeLine 'tz independent' $ts0)) -NowUtc $t0
    Check 'F3i-until-is-pure-utc' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bI).untilUtc).Kind -eq [System.DateTimeKind]::Utc) ''
    Check 'F3i-until-equals-reply-plus-5-utc' ((ConvertTo-HumanPauseUtc (Get-HumanPause $bI).untilUtc) -eq $t0.AddMinutes(5)) ''
    Check 'F3i-persisted-clock-basis' ([string](Get-HumanPause $bI).clockBasis -eq 'utc-absolute') ([string](Get-HumanPause $bI).clockBasis)
} finally {
    Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
