# tests\source_recovery_schedule.tests.ps1
# 人工暂停基准、来源不明等待到期、平台接管、恢复调度与事件级调查（验收矩阵 A04/A08-A14/A19-A21/A23）。
# isolated 层：真实暂停/等待/调查存储，跑在测试运行根里；不发通知、不发送、不访问浏览器。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\human_pause.ps1')
. (Join-Path $scripts 'lib\investigations.ps1')
. (Join-Path $scripts 'lib\send_attempts.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output ("FAIL: " + $name) }
}
$lf = [string][char]10
function MkLine {
    param([string]$Role, [string]$Text, [string]$Dir, [long]$Ts, [string]$Struct = 'message', [string[]]$Tags = @())
    $meta = [ordered]@{
        v = 'msgevent-2026-10-07.1'
        t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        dir = $Dir; dirsrc = 'layout'; mid = ''; ts = $Ts; tprec = 'second'
        st = $Struct; src = $Tags; at = '2026-10-07T00:00:00Z'
        idq = $(if ($Ts -gt 0) { 'composite' } else { 'unusable' })
    }
    return ('[' + $Role + '] ' + $Text + ' @@MT:' + $Ts + ' ' + (ConvertTo-MessageMetaMarker ([pscustomobject]$meta)))
}
$base = [datetime]::Parse('2026-10-07T10:00:00Z').ToUniversalTime()
function At([int]$min) { return $base.AddMinutes($min) }
# 逐条时间必须与注入时钟同一时间轴：绝对 epoch 必须由 $base 派生，否则夹具时间落在过去，
# 事件锚点会立刻过期，"等待窗口"根本不会处于 active 状态。
$E0 = ([System.DateTimeOffset]$base).ToUnixTimeMilliseconds()
function Tm([int]$min) { return ($E0 + (60000L * $min)) }

# ============================================================ A08 人工五分钟与到期回读
$h1 = MkLine 'ME' 'owner manual note' 'out' (Tm 0)
$ev1 = @(Get-ConversationEventIndex @($h1))
$corr = Add-InvestigationSourceCorrection -Buyer 'Buyer A08' -EventRef ([string]$ev1[0].Identity) -Class 'human' -Evidence 'field:sender=owner read on the page for this exact message' -By 'ops'
Check 'A08-human-correction-recorded' ($corr.Ok)
$lines08 = @($h1) + @(MkLine 'BUYER' 'and one more thing' 'in' (Tm 1))
$s1 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $lines08 -NowUtc (At 1)
Check 'A08-pause-established-from-confirmed-human' ($s1.SyncOk -and $s1.HumanPauseActive)
Check 'A08-pause-deadline-is-utc' ([bool]$s1.HumanPauseUntilUtc -and ([datetime]$s1.HumanPauseUntilUtc).ToUniversalTime() -gt (At 1))
$gate08 = Get-MessageSourceGate -Lines $lines08 -Rules (Get-MessageSourceRuleSet) -Confirmed (Get-InvestigationSourceCorrections -Buyer 'Buyer A08')
Check 'A08-buyer-tail-is-not-the-blocker' ($gate08.Reason -eq 'buyer-last')
$s2 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $lines08 -NowUtc (At 6)
Check 'A08-pause-expires-after-five-minutes' ($s2.SyncOk -and -not $s2.HumanPauseActive)

# ============================================================ A09 重扫/重启/窗口变化不延长
$s3 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $lines08 -NowUtc (At 2)
$untilA = ([datetime]$s3.HumanPauseUntilUtc).ToUniversalTime()
$shifted = @($h1) + @(MkLine 'ME' 'another owner line' 'out' (Tm -1)) + @(MkLine 'BUYER' 'more' 'in' (Tm 1))
$s4 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $shifted -NowUtc (At 2)
Check 'A09-rescan-does-not-extend-deadline' ($s4.SyncOk -and ([datetime]$s4.HumanPauseUntilUtc).ToUniversalTime() -eq $untilA)
$s5 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $lines08 -NowUtc (At 3)
Check 'A09-restart-does-not-reopen-window' (([datetime]$s5.HumanPauseUntilUtc).ToUniversalTime() -eq $untilA)
Check 'A09-event-identity-is-not-a-row-index' ((Get-InterventionEventIdentity $h1) -eq (Get-InterventionEventIdentity $h1))

# ============================================================ A10 连续人工回复与白名单
$h2 = MkLine 'ME' 'owner second note' 'out' (Tm 3)
$ev2 = @(Get-ConversationEventIndex @($h2))
$null = Add-InvestigationSourceCorrection -Buyer 'Buyer A08' -EventRef ([string]$ev2[0].Identity) -Class 'human' -Evidence 'field:sender=owner read on the page for this exact message' -By 'ops'
$lines10 = @($h1) + @($h2)
$s6 = Sync-ConversationInterventionState -Buyer 'Buyer A08' -Lines $lines10 -NowUtc (At 3)
Check 'A10-consecutive-human-event-extends-pause' (([datetime]$s6.HumanPauseUntilUtc).ToUniversalTime() -ge (At 8))
$whitelist = Get-MessageSourceGate -Lines $lines10 -Rules (Get-MessageSourceRuleSet) -Confirmed (Get-InvestigationSourceCorrections -Buyer 'Buyer A08')
Check 'A10-whitelist-remains-outside-this-gate' ($whitelist.Action -eq 'SKIP' -and $whitelist.Reason -eq 'human-last')

# ============================================================ A11 无当前待回复诉求 ⇒ 不补发
$tokens = $null; $errors = $null
$mAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'monitor.ps1 failed to parse' }
$fnObsolete = $mAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-PendingReplyObsolete' }, $true)
Invoke-Expression $fnObsolete.Extent.Text
$script:pendingRaw = ''
function Open-ConvoAndGetMessages([string]$keyword) { return [pscustomobject]@{ name = $keyword; msgs = $script:pendingRaw; profile = '' } }
$script:pendingRaw = (@((MkLine 'BUYER' 'question' 'in' (Tm 0)), (MkLine 'ME' 'answer already sent' 'out' (Tm 1))) -join $lf)
Check 'A11-our-side-last-means-answered' ((Test-PendingReplyObsolete 'Buyer A11') -eq 'ANSWERED')
$script:pendingRaw = (@((MkLine 'ME' 'answer already sent' 'out' (Tm 1)), (MkLine 'BUYER' 'new question' 'in' (Tm 2))) -join $lf)
Check 'A11-buyer-last-means-pending' ((Test-PendingReplyObsolete 'Buyer A11') -eq 'PENDING')
$script:pendingRaw = 'garbage that cannot be parsed as lines'
Check 'A11-unreadable-is-unknown-not-answered' ((Test-PendingReplyObsolete 'Buyer A11') -eq 'UNKNOWN')

# ============================================================ A12 未知来源超时不放行
$u1 = MkLine 'ME' 'unidentified our side' 'out' (Tm 1)
$linesU = @(MkLine 'BUYER' 'question' 'in' (Tm 0)) + @($u1)
$gu = Get-MessageSourceGate -Lines $linesU -Rules (Get-MessageSourceRuleSet)
Check 'A12-unknown-tail-blocks' ($gu.Action -eq 'SKIP' -and $gu.Reason -eq 'unknown-me-tail')
$su = Sync-ConversationInterventionState -Buyer 'Buyer A12' -Lines $linesU -NowUtc (At 1)
Check 'A12-unknown-hold-established' ($su.SyncOk -and $su.UnknownHoldActive)
$holdActive = Test-SourceUnknownHoldActive -Buyer 'Buyer A12' -NowUtc (At 4)
Check 'A12-hold-still-active-before-deadline' ($holdActive.Active)
$holdExpired = Test-SourceUnknownHoldActive -Buyer 'Buyer A12' -NowUtc (At 7)
Check 'A12-hold-expires-at-fixed-deadline' (-not $holdExpired.Active -and $holdExpired.Reason -eq 'expired')
$invA12 = New-OrUpdate-Investigation -Buyer 'Buyer A12' -Kind 'source_unverified' -EventRef ([string]$gu.HoldEventRef) -EventRefQuality ([string]$gu.TailIdentityQuality)
Check 'A12-investigation-persisted-on-expiry' ($invA12.Ok -and $invA12.Created)
$gu2 = Get-MessageSourceGate -Lines $linesU -Rules (Get-MessageSourceRuleSet)
Check 'A12-timeout-does-not-promote-unknown' ($gu2.Action -eq 'SKIP' -and $gu2.TailClass -eq 'unknown')

# ============================================================ A13 久远 unknown 不再封锁
$old = MkLine 'ME' 'old unidentified' 'out' (Tm -1000)
$lines13 = @($old) + @(MkLine 'BUYER' 'brand new trusted request' 'in' (Tm 4))
$g13 = Get-MessageSourceGate -Lines $lines13 -Rules (Get-MessageSourceRuleSet)
Check 'A13-new-trusted-buyer-tail-is-processable' ($g13.Action -eq 'SEND' -and $g13.Reason -eq 'buyer-last')
$s13 = Sync-ConversationInterventionState -Buyer 'Buyer A13' -Lines $lines13 -NowUtc (At 20)
Check 'A13-old-hold-does-not-block-new-request' ($s13.SyncOk -and -not $s13.UnknownHoldActive)
Check 'A13-old-source-not-promoted' ((Resolve-MessageSourceClass -Event (Get-MessageEvents @($old))[0]).Class -eq 'unknown')

# ============================================================ A14 来源更正只作用于确切事件
$ownerA = MkLine 'ME' 'owner line kept' 'out' (Tm 5)
$ownerB = MkLine 'ME' 'owner line corrected' 'out' (Tm 6)
$idx14 = @(Get-ConversationEventIndex @($ownerA, $ownerB))
$null = Add-InvestigationSourceCorrection -Buyer 'Buyer A14' -EventRef ([string]$idx14[1].Identity) -Class 'project' -Evidence 'receipt:confirmed project receipt bound to this exact event' -By 'ops'
$s14 = Sync-ConversationInterventionState -Buyer 'Buyer A14' -Lines @($ownerA, $ownerB) -NowUtc (At 1)
Check 'A14-corrected-event-not-human' (-not $s14.HumanPauseActive)
Check 'A14-correction-scope-is-exact-event' (@(Get-InvestigationSourceCorrections -Buyer 'Buyer A14').Keys.Count -eq 1)

# ============================================================ A20/A21 调查幂等与通知真实性
$i20a = New-OrUpdate-Investigation -Buyer 'Buyer A20' -Kind 'source_conflict' -EventRef 'ref-a' -EventRefQuality 'composite'
$i20b = New-OrUpdate-Investigation -Buyer 'Buyer A20' -Kind 'source_conflict' -EventRef 'ref-b' -EventRefQuality 'composite'
Check 'A20-different-events-not-merged' ($i20a.Record.id -ne $i20b.Record.id)
$i20a2 = New-OrUpdate-Investigation -Buyer 'Buyer A20' -Kind 'source_conflict' -EventRef 'ref-a' -EventRefQuality 'composite'
Check 'A20-same-event-idempotent' (-not $i20a2.Created -and $i20a2.Record.id -eq $i20a.Record.id)
$i20c = New-OrUpdate-Investigation -Buyer 'Buyer A20' -Kind 'source_unverified' -EventRef ''
Check 'A20-unique-identity-impossible-creates-explicit-ambiguity' ($i20c.Record.eventRef -like 'ambiguous:*' -and $i20c.Record.eventRefQuality -eq 'ambiguous')

$failSender = { param($Text) return 'SEND_ERROR: timeout after 15s' }
$n1 = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -Sender $failSender
Check 'A21-failed-delivery-not-recorded-as-notified' (-not $n1.Sent -and -not $n1.Record.notifiedOnce)
Check 'A21-todo-survives-failed-notification' ([bool](Get-Investigation ([string]$i20a.Record.id)))
Check 'A21-failure-detail-recorded' (@((Get-Investigation ([string]$i20a.Record.id)).notifications).Count -eq 1)
$dr = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -OperatorRetry -DryRun
Check 'A21-dry-run-does-not-mark-notified' ($dr.Ok -and -not (Get-Investigation ([string]$i20a.Record.id)).notifiedOnce)
$okSender = { param($Text) return 'SENT_OK' }
# [复核 R6] 已经投递过一次（失败/不明）之后，**正常路径**不得再自动重发；必须人工显式 retry。
$autoAfterFailure = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -Sender $okSender
Check 'A21-failed-attempt-blocks-the-automatic-path' ((-not $autoAfterFailure.Sent) -and $autoAfterFailure.Error -eq 'delivery-attempt-recorded-operator-retry-required')
Check 'A21-failed-attempt-not-restamped-as-notified' (-not (Get-Investigation ([string]$i20a.Record.id)).notifiedOnce)
Check 'A21-failure-state-recorded-separately' ((Get-InvestigationNotifyState (Get-Investigation ([string]$i20a.Record.id))) -eq 'failed')
$n2 = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -Sender $okSender -OperatorRetry
Check 'A21-successful-delivery-marks-notified-once' ($n2.Sent -and (Get-Investigation ([string]$i20a.Record.id)).notifiedOnce)
$beforeCount = @((Get-Investigation ([string]$i20a.Record.id)).notifications).Count
$null = Invoke-InvestigationNotificationSweep -Sender $okSender
Check 'A21-rescan-does-not-renotify' (@((Get-Investigation ([string]$i20a.Record.id)).notifications).Count -eq $beforeCount)
$n3 = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -Sender $okSender
Check 'A21-auto-path-refuses-second-notice' ($n3.Error -eq 'already-notified')
$n4 = Invoke-InvestigationNotification -Id ([string]$i20a.Record.id) -Sender $okSender -OperatorRetry
Check 'A21-operator-retry-is-explicit-and-audited' ($n4.Sent -and @((Get-Investigation ([string]$i20a.Record.id)).notifications).Count -gt $beforeCount)

# [复核 R6] 复核报告给出的复现：虚构通道**始终返回 UNKNOWN**，两次正常扫描不得产生第二次投递。
$script:unknownCalls = 0
$unknownSender = { param($Text) $script:unknownCalls++; return '' }
$i21u = New-OrUpdate-Investigation -Buyer 'Buyer A21U' -Kind 'source_unverified' -EventRef 'ref-21u' -EventRefQuality 'composite'
$u1 = Invoke-InvestigationNotification -Id ([string]$i21u.Record.id) -Sender $unknownSender
$u2 = Invoke-InvestigationNotification -Id ([string]$i21u.Record.id) -Sender $unknownSender
$null = Invoke-InvestigationNotificationSweep -Sender $unknownSender
Check 'A21-unknown-response-recorded-not-as-notified' ($u1.Ok -and $u1.Result -eq 'UNKNOWN' -and -not (Get-Investigation ([string]$i21u.Record.id)).notifiedOnce)
Check 'A21-unknown-state-is-recorded-separately' ((Get-InvestigationNotifyState (Get-Investigation ([string]$i21u.Record.id))) -eq 'unknown')
Check 'A21-unknown-is-never-resent-by-the-normal-path' ($script:unknownCalls -eq 1 -and $u2.Error -eq 'delivery-attempt-recorded-operator-retry-required')
$u3 = Invoke-InvestigationNotification -Id ([string]$i21u.Record.id) -Sender $unknownSender -OperatorRetry
Check 'A21-unknown-operator-retry-is-explicit' ($script:unknownCalls -eq 2 -and $u3.Result -eq 'UNKNOWN')

# A21/A22：只改状态、给出来源猜测都不能关闭调查
# [复核 R5] 更正与关闭必须绑定**真实事件身份**（不再是任意字符串）。
$l22 = MkLine 'ME' 'unverified our side line' 'out' (Tm 8)
$ev22 = @(Get-ConversationEventIndex @($l22))
$ref22 = [string]$ev22[0].Identity
$l22b = MkLine 'ME' 'a different our side line' 'out' (Tm 9)
$otherRef22 = [string](@(Get-ConversationEventIndex @($l22b))[0].Identity)
Check 'A22-fixture-identity-is-an-event-identity' ($ref22 -like 'cmp|*' -and $otherRef22 -ne $ref22)
$i22 = New-OrUpdate-Investigation -Buyer 'Buyer A22' -Kind 'source_unverified' -EventRef $ref22 -EventRefQuality 'composite'
$c22 = Set-InvestigationClaim -Id ([string]$i22.Record.id) -Operator 'ops'
Check 'A22-claim-does-not-resolve' ($c22.Ok -and (Get-Investigation ([string]$i22.Record.id)).status -eq 'investigating')
$r22a = Resolve-Investigation -Id ([string]$i22.Record.id) -By 'ops' -SourceClass 'platform' -Evidence '' -EventRef $ref22
Check 'A22-source-closure-needs-provenance' (-not $r22a.Ok -and $r22a.Error -eq 'evidence-provenance-required')
# [复核 R5] 没有出处的备注（handled / 已处理）不构成证明
$r22note = Resolve-Investigation -Id ([string]$i22.Record.id) -By 'ops' -SourceClass 'platform' -Evidence 'handled' -EventRef $ref22
Check 'A22-source-closure-rejects-a-bare-note' (-not $r22note.Ok -and $r22note.Error -eq 'evidence-provenance-required')
$r22src = Resolve-Investigation -Id ([string]$i22.Record.id) -By 'ops' -SourceClass 'platform' -Evidence 'note:handled by the operator' -EventRef $ref22
Check 'A22-source-closure-rejects-an-unattributable-source' (-not $r22src.Ok -and $r22src.Error -eq 'evidence-source-not-attributable')
$r22b = Resolve-Investigation -Id ([string]$i22.Record.id) -By 'ops' -SourceClass 'platform' -Evidence 'page:sender field read on the page' -EventRef $otherRef22
Check 'A22-source-closure-needs-exact-event' (-not $r22b.Ok -and $r22b.Error -eq 'event-ref-does-not-match-investigation')
Check 'A22-rejected-closure-keeps-the-investigation-open' ((Get-Investigation ([string]$i22.Record.id)).status -ne 'resolved')
$r22c = Resolve-Investigation -Id ([string]$i22.Record.id) -By 'ops' -SourceClass 'platform' -Evidence 'page:sender field verified 2026-10-07 for this exact message' -EventRef $ref22
Check 'A22-source-closure-with-provenance-succeeds' ($r22c.Ok -and $r22c.Record.status -eq 'resolved')
Check 'A22-correction-is-persisted-before-the-closure' ($r22c.CorrectionPersisted -and (Get-InvestigationSourceCorrections -Buyer 'Buyer A22').ContainsKey($ref22))
Check 'A22-resolved-investigation-stops-blocking' (-not (Get-InvestigationSendBlock -Buyer 'Buyer A22' -EventRef $ref22).Blocked)

# ============================================================ A23 发送前复核接线
$sendBlock22 = New-OrUpdate-Investigation -Buyer 'Buyer A23' -Kind 'source_unverified' -EventRef 'ref-23' -EventRefQuality 'composite'
Check 'A23-active-investigation-blocks-exact-event' ((Get-InvestigationSendBlock -Buyer 'Buyer A23' -EventRef 'ref-23').Blocked)
Check 'A23-unrelated-event-not-blocked' (-not (Get-InvestigationSendBlock -Buyer 'Buyer A23' -EventRef 'other-event').Blocked)
$conflictLines = @(MkLine 'ME' 'conflicting evidence' 'out' (Tm 7))
$rulesPlatform = New-MessageSourceRuleSet -VerifiedTags ([pscustomobject]@{ 'tag:自动接待发送' = 'platform' })
$conflictLine = MkLine 'ME' 'conflicting evidence' 'out' (Tm 7) 'message' @('tag:自动接待发送')
$gc = Get-MessageSourceGate -Lines @($conflictLine) -SentMatches @{ 0 = $true } -Rules $rulesPlatform
Check 'A23-send-time-gate-detects-conflict' ($gc.Action -eq 'SKIP' -and $gc.Reason -eq 'source-conflict')
$monitorText = [IO.File]::ReadAllText((Join-Path $scripts 'monitor.ps1'))
Check 'A23-monitor-exposes-shared-gate' ($monitorText -match 'function Get-MonitorSourceGate')
Check 'A23-current-pending-does-not-consume-source-waits' (([regex]::Matches($monitorText, 'Get-MonitorSourceGate\s+-Lines')).Count -eq 0)
Check 'A23-current-pending-keeps-identity-input-discard' ($monitorText -match "buyer-identity-changed" -and $monitorText -match 'STALE-DRAFT-DISCARD')
Check 'A23-single-send-site-preserved' (([regex]::Matches($monitorText, '\bSend-OneTalkMessageEx\s+-')).Count -eq 1)

Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
