# tests\send_attempt_receipt.tests.ps1
# 真实收据、持久发送尝试、部分提交恢复与待确认发送（spec 验收矩阵 A15-A19 / A24 部分，复核 R1/R2/R3）。
# isolated 层：临时运行根 + 桩适配器；不访问浏览器、不发通知、不发送。
#
# [复核 R1] 收据部分**执行生产 DOM JavaScript**：Get-OutboundSnapshot 注入页面的那段脚本由
#   Node + 虚构 DOM（tests\outbound_receipt_dom.fixture.js）真实运行，不再把构造好的 JSON
#   塞给 Invoke-SendEval 冒充适配器验证；并额外跑通**完整发送消费者** Send-OneTalkMessageEx。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
if (-not (Test-AarIsolatedRuntime)) { throw 'Run this state-writing test through tests/run_tests.ps1 (isolated runtime required).' }
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\msg_extract_js.ps1')
. (Join-Path $scripts 'lib\outbound_receipts.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\investigations.ps1')
. (Join-Path $scripts 'lib\send_attempts.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output ("FAIL: " + $name) }
}
$lf = [string][char]10
function New-OutboundEvent([string]$text, [string]$time, [string]$id = '', [bool]$mine = $true, [string]$iq = 'composite') {
    $key = ''
    if ($id) { $key = 'id:' + $id } elseif ($time) { $key = 'cmp|out|' + $time + '|' + (Get-MessageBodyFingerprint $text) }
    return [pscustomobject]@{ MessageId = $id; MessageTime = $time; TimePrecision = $(if ($time) { 'second' } else { '' }); Text = $text; IsMine = $mine; Identity = $key; IdentityQuality = $iq; Direction = $(if ($mine) { 'out' } else { 'in' }); BodyHash = (Get-MessageBodyFingerprint $text) }
}

# ------------------------------------------------------------------ 生产收据 DOM 适配器矩阵（真实 JS）
# 只抽取生产函数本体；它调用的 Invoke-SendEval 被替换成"把真实脚本交给 Node 在虚构 DOM 上跑"。
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'lib\outbound_receipts.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'outbound_receipts.ps1 failed to parse' }
foreach ($fn in @('Get-OutboundSnapshot')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    Invoke-Expression $f.Extent.Text
}
$script:domJsFile = ''
$script:domJsText = ''
$script:domScenario = 'before'
$script:domScenarios = $null
$script:domCall = 0
$script:domUnreadable = $false
function Get-DomScenario {
    if ($script:domScenarios) {
        $i = [Math]::Min($script:domCall, @($script:domScenarios).Count - 1)
        return [string]@($script:domScenarios)[$i]
    }
    return [string]$script:domScenario
}
function Invoke-SendEval([string]$js) {
    if ($script:domUnreadable) { return 'not-json-at-all' }
    # 发送前后必须是**同一份**生产脚本（同口径）；不同脚本直接失败，不给"两次不同实现"的机会。
    if (-not $script:domJsText) {
        $script:domJsText = $js
        $script:domJsFile = Join-Path $env:TEMP ('aar_receipt_js_' + [guid]::NewGuid().ToString('N') + '.js')
        [IO.File]::WriteAllText($script:domJsFile, $js, (New-Object Text.UTF8Encoding($false)))
    } elseif ($script:domJsText -ne $js) {
        throw 'outbound snapshot scripts differ between calls'
    }
    $scenario = Get-DomScenario
    $script:domCall++
    $out = & node (Join-Path $PSScriptRoot 'outbound_receipt_dom.fixture.js') $script:domJsFile $scenario
    if ($LASTEXITCODE -ne 0) { throw ('dom fixture failed: ' + ($out -join ' ')) }
    return (($out -join $lf).Trim())
}
function Snap([string]$scenario) { $script:domScenario = $scenario; return @(Get-OutboundSnapshot -Buyer 'Buyer A') }

$before = Snap 'before'
Check 'dom-adapter-reads-before-snapshot' ($before.Count -eq 3 -and @($before | Where-Object { $_.IsMine -and -not $_.IsNoise }).Count -eq 1)
Check 'dom-adapter-keeps-flow-row-as-noise' (@($before | Where-Object { $_.IsNoise -and $_.StructureType -eq 'flow' }).Count -eq 1)
Check 'dom-adapter-direction-from-verified-layout' ($before[0].IsBuyer -and -not $before[0].IsMine -and -not $before[1].IsBuyer -and $before[1].IsMine)
Check 'dom-adapter-shared-identity-quality' (@($before | Where-Object { -not $_.IsNoise -and $_.IdentityQuality -eq 'composite' }).Count -eq 2)
$script:domUnreadable = $true
$threw = $false
try { $null = Get-OutboundSnapshot } catch { $threw = $true }
Check 'dom-adapter-rejects-unreadable-snapshot' $threw
$script:domUnreadable = $false

$REPLY = 'Your cartons are booked for Friday pickup.'
$afterOk = Snap 'after-composite'
$r1 = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterOk
Check 'A15-unique-new-event-yields-receipt' ($r1.Valid -and $r1.ConfirmationType -eq 'unique-exact-new-event')
Check 'A15-real-dom-receipt-validates-against-sent-text' (Test-ConfirmedOutboundReceipt $r1 'Buyer A' $REPLY)
$afterId = Snap 'after-platform-id'
$r2 = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterId
Check 'A15-platform-id-receipt-confirmation-type' ($r2.Valid -and $r2.ConfirmationType -eq 'new-platform-message-id' -and $r2.MessageId -eq 'PLAT-4242')
$afterNoTime = Snap 'after-no-time'
$rNT = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterNoTime
Check 'R1-unidentified-new-bubble-kept-and-refused' (-not $rNT.Valid -and $rNT.Error -eq 'new-unidentified-event' -and @($rNT.UnidentifiedNew).Count -eq 1)
Check 'R1-unidentified-bubble-is-not-filtered-away' (@($afterNoTime | Where-Object { -not (Test-MessageEventIdentityUsable $_) -and $_.IsMine -and -not $_.IsNoise }).Count -eq 1)
$afterFlowOnly = Snap 'after-flow-only'
$rFlow = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterFlowOnly
Check 'R1-flow-card-is-not-the-sent-message' (-not $rFlow.Valid -and $rFlow.Error -eq 'no-unique-new-event')
$afterFlowReal = Snap 'after-flow-and-real'
$rFlowReal = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterFlowReal
Check 'R1-flow-card-does-not-hide-the-real-bubble' ($rFlowReal.Valid -and $rFlowReal.ConfirmationType -eq 'unique-exact-new-event')
$afterAttach = Snap 'after-attachment'
$rAtt = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterAttach
Check 'R1-attachment-bubble-does-not-break-the-receipt' ($rAtt.Valid -and (Test-ConfirmedOutboundReceipt $rAtt 'Buyer A' $REPLY))

# ---------------------------------------------------------------- 【复核 R9】没有 rich 文本节点的真实附件气泡
# 反例（修复前）：__aarExtractRow 在附件检测之前 if (!rich) return null，于是"图片/文件真实气泡"
#   只要没有 .session-rich-content / .content-with-translation.text-content 就整条消失 ——
#   收据会在"少了一条气泡"的假快照上成立，而真实页面上这条气泡是存在的。
$afterAttachNR = Snap 'after-attachment-norich'
Check 'R9-image-bubble-without-rich-is-retained' (@($afterAttachNR | Where-Object { -not $_.IsNoise -and $_.RawLine -match '@@IMG:.*invented-norich' }).Count -eq 1)
Check 'R9-image-bubble-without-rich-keeps-a-real-body' (@($afterAttachNR | Where-Object { $_.Text -eq '[IMG]' }).Count -eq 1)
$rAttNR = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterAttachNR
Check 'R9-image-bubble-without-rich-does-not-break-the-receipt' ($rAttNR.Valid)
$afterOwnNR = Snap 'after-own-attachment-norich'
Check 'R9-our-attachment-bubble-without-rich-is-kept-not-deleted' (@($afterOwnNR | Where-Object { $_.IsMine -and -not $_.IsNoise -and $_.Text -eq '[IMG]' }).Count -eq 1)
$rOwnNR = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterOwnNR
Check 'R9-our-attachment-bubble-cannot-be-traded-for-a-receipt' (-not $rOwnNR.Valid -and $rOwnNR.Error -eq 'no-unique-new-event')

# ---------------------------------------------------------------- 【复核 R10】明确右侧结构优先于显示名/翻译标记
$emptyRules = Get-MessageSourceRuleSet
$afterRightName = Snap 'after-right-with-name'
$evRightName = @($afterRightName | Where-Object { $_.Text -eq $REPLY })
Check 'R10-explicit-right-beats-the-name-field' ($evRightName.Count -eq 1 -and -not $evRightName[0].IsBuyer -and $evRightName[0].Direction -eq 'out' -and $evRightName[0].DirectionSource -eq 'layout')
Check 'R10-explicit-right-with-a-name-is-not-a-buyer-message' ((Resolve-MessageSourceClass -Event $evRightName[0] -Rules $emptyRules).Class -ne 'buyer')
$rRightName = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterRightName
Check 'R10-explicit-right-with-a-name-still-yields-a-receipt' ($rRightName.Valid)
$afterRightTr = Snap 'after-right-with-translation'
$evRightTr = @($afterRightTr | Where-Object { $_.Text -eq $REPLY })
Check 'R10-explicit-right-beats-the-translation-marker' ($evRightTr.Count -eq 1 -and -not $evRightTr[0].IsBuyer -and $evRightTr[0].Direction -eq 'out' -and $evRightTr[0].DirectionSource -eq 'layout')
Check 'R10-explicit-right-with-a-translation-is-not-a-buyer-message' ((Resolve-MessageSourceClass -Event $evRightTr[0] -Rules $emptyRules).Class -ne 'buyer')
$rRightTr = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterRightTr
Check 'R10-explicit-right-with-a-translation-still-yields-a-receipt' ($rRightTr.Valid)
$afterConflict = Snap 'after-direction-conflict'
$evConflict = @($afterConflict | Where-Object { $_.Text -eq $REPLY })
Check 'R10-direction-conflict-is-recorded-not-guessed' ($evConflict.Count -eq 1 -and $evConflict[0].Direction -eq 'unknown' -and $evConflict[0].DirectionSource -eq 'conflict' -and -not $evConflict[0].IsBuyer)
Check 'R10-direction-conflict-has-no-usable-identity' (-not (Test-MessageEventIdentityUsable $evConflict[0]))
Check 'R10-direction-conflict-is-neither-a-buyer-nor-a-project' ((Resolve-MessageSourceClass -Event $evConflict[0] -Rules $emptyRules).Class -eq 'unknown')
$rConflict = New-ConfirmedOutboundReceipt -Buyer 'Buyer A' -Text $REPLY -Before $before -After $afterConflict
Check 'R10-direction-conflict-cannot-prove-an-outbound-receipt' ((-not $rConflict.Valid) -and ($rConflict.Error -in @('new-unidentified-event', 'new-event-identity-not-usable')))

# ------------------------------------------------------------------ 完整发送消费者（真实 DOM JS）
# Send-OneTalkMessageEx 是生产唯一的发送出口；这里让它跑真实收据脚本 + 真实收据判定。
$sendAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'lib\send.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'send.ps1 failed to parse' }
foreach ($fn in @('Get-SendPageWsPort', 'Assert-SendPageNotSharedPort', 'Test-TextMatchesSent', 'Get-OutboundConfirmScript', 'Confirm-OneTalkOutboundMessage', 'Send-OneTalkMessageEx')) {
    $f = $sendAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)
    Invoke-Expression $f.Extent.Text
}
function Prepare-OneTalkConversation { param([string]$Buyer, [switch]$AlreadyOpen) return [pscustomobject]@{name=$Buyer} }
function Send-OneTalkMessage {
    param($buyer, $text, $Page = $null, [switch]$AlreadyOpen)
    $script:consumerSends++
    $script:consumerText = [string]$text
    if ($script:consumerAttemptId) { $script:recordAtClick = Get-SendAttempt $script:consumerAttemptId }
    return $script:consumerRaw
}
$script:consumerRaw = 'FILLED | CLICKED | SENT_OK'
$script:consumerSends = 0
$script:domCall = 0; $script:domScenarios = @('before', 'after-composite')
$consumerOk = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY
Check 'R1-send-consumer-runs-the-real-dom-adapter' ($script:consumerSends -eq 1 -and @($consumerOk.BeforeSnapshot).Count -eq 3 -and @($consumerOk.AfterSnapshot).Count -eq 4)
Check 'R1-send-consumer-reports-SENT_OK-with-valid-receipt' ($consumerOk.Status -eq 'SENT_OK' -and $consumerOk.Confirmed -and (Test-ConfirmedOutboundReceipt $consumerOk.Receipt 'Buyer A' $REPLY))
$script:domCall = 0; $script:domScenarios = @('before', 'after-no-time')
$consumerUnknown = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY
Check 'R1-send-consumer-refuses-unidentified-bubble' ($consumerUnknown.Status -eq 'UNKNOWN' -and -not $consumerUnknown.Confirmed -and -not (Test-ConfirmedOutboundReceipt $consumerUnknown.Receipt 'Buyer A' $REPLY))
$script:domCall = 0; $script:domScenarios = @('before', 'after-flow-only')
$consumerFlow = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY
Check 'R1-send-consumer-refuses-flow-card-as-send-proof' ($consumerFlow.Status -eq 'UNKNOWN' -and -not $consumerFlow.Confirmed)

# The persisted recovery baseline must match the actual bound snapshot before raw sending.
$boundAttempt = New-PersistedSendAttempt -Buyer 'Buyer A' -Text $REPLY -BeforeEvents @()
$script:consumerAttemptId = $boundAttempt.AttemptId
$script:domCall = 0; $script:domScenarios = @('before', 'after-composite')
$boundResult = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY -AttemptId $boundAttempt.AttemptId -AlreadyOpen
$expectedProof = Get-SendAttemptSnapshotProof -Events @($boundResult.BeforeSnapshot)
Check 'scope-baseline-is-bound-before-send-click' ($script:recordAtClick.stage -eq 'dispatching' -and $script:recordAtClick.beforeProof.EventCount -eq 3 -and $script:recordAtClick.beforeProof.SnapshotHash -eq $expectedProof.SnapshotHash)
Check 'scope-bound-baseline-send-still-confirms' ($boundResult.Status -eq 'SENT_OK')
$sendsBeforeGuard = $script:consumerSends
$script:domCall = 0; $script:domScenarios = @('before', 'after-composite')
$refused = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY -AttemptId $boundAttempt.AttemptId
Check 'scope-dispatched-attempt-cannot-replace-its-baseline' ($refused.NotAttempted -and $script:consumerSends -eq $sendsBeforeGuard)
$wrongAttempt = New-PersistedSendAttempt -Buyer 'Buyer Other' -Text $REPLY -BeforeEvents @()
$script:domCall = 0
$refused = Send-OneTalkMessageEx -buyer 'Buyer A' -text $REPLY -AttemptId $wrongAttempt.AttemptId
Check 'scope-wrong-attempt-buyer-cannot-send' ($refused.NotAttempted -and $script:consumerSends -eq $sendsBeforeGuard -and (Get-SendAttempt $wrongAttempt.AttemptId).stage -eq 'persisted')
$script:domUnreadable = $true
$readRefused = Send-OneTalkMessageEx -buyer 'Buyer Other' -text $REPLY -AttemptId $wrongAttempt.AttemptId
Check 'scope-unreadable-before-does-not-mark-dispatching' ($readRefused.NotAttempted -and (Get-SendAttempt $wrongAttempt.AttemptId).stage -eq 'persisted' -and $script:consumerSends -eq $sendsBeforeGuard)
$script:domUnreadable = $false
$script:consumerAttemptId = ''
$script:domScenarios = $null; $script:domScenario = 'before'

# ------------------------------------------------------------------ 收据代数（手工事件，不依赖 DOM）
$flatBefore = @(
    [pscustomobject]@{ MessageId = ''; MessageTime = '1791000000000'; TimePrecision = 'second'; Text = 'old question'; IsMine = $false; Identity = 'cmp|in|1791000000000|' + (Get-MessageBodyFingerprint 'old question'); IdentityQuality = 'composite'; Direction = 'in'; BodyHash = (Get-MessageBodyFingerprint 'old question') },
    [pscustomobject]@{ MessageId = ''; MessageTime = '1791000100000'; TimePrecision = 'second'; Text = 'our earlier reply'; IsMine = $true; Identity = 'cmp|out|1791000100000|' + (Get-MessageBodyFingerprint 'our earlier reply'); IdentityQuality = 'composite'; Direction = 'out'; BodyHash = (Get-MessageBodyFingerprint 'our earlier reply') }
)
$dup = @($flatBefore) + @(New-OutboundEvent 'the reply body' '1791000200000') + @(New-OutboundEvent 'the reply body' '1791000200000')
$r3 = New-ConfirmedOutboundReceipt -Buyer 'Buyer X' -Text 'the reply body' -Before $flatBefore -After $dup
Check 'A16-duplicate-events-no-text-guess' (-not $r3.Valid -and $r3.Error -eq 'no-unique-new-event')
$unidentifiedBefore = @([pscustomobject]@{ MessageId = ''; MessageTime = ''; TimePrecision = ''; Text = 'no identity at all'; IsMine = $true; Identity = ''; IdentityQuality = 'unusable'; Direction = 'out'; BodyHash = (Get-MessageBodyFingerprint 'no identity at all') })
$r4 = New-ConfirmedOutboundReceipt -Buyer 'Buyer X' -Text 'the reply body' -Before $unidentifiedBefore -After @(New-OutboundEvent 'the reply body' '1791000200000')
Check 'A16-incomplete-before-identity-refused' (-not $r4.Valid -and $r4.Error -in @('incomplete-before-identities', 'new-unidentified-event'))

# ------------------------------------------------------------------ 发送前持久化 + 副作用阶段（复核 R2）
$att16 = New-PersistedSendAttempt -Buyer 'Buyer X' -Text 'the reply body' -DedupKey 'k16' -TriggerRef 'k16' -BeforeEvents $flatBefore
$afterWithUnknown = @($flatBefore) + @(New-OutboundEvent 'the reply body' '1791000200000') + @(New-OutboundEvent '[IMG]' '' '' $true 'unusable')
$res16 = Confirm-SendAttemptFromSnapshots -AttemptId $att16.AttemptId -Buyer 'Buyer X' -Text 'the reply body' -BeforeEvents $flatBefore -AfterEvents $afterWithUnknown -ConvoKey 'buyer x'
Check 'A16-unidentified-extra-event-keeps-ambiguity' (-not $res16.Confirmed -and $res16.DeliveryState -eq 'delivery_ambiguous' -and @($res16.Ambiguity).Count -gt 0)
$afterClean = @($flatBefore) + @(New-OutboundEvent 'the reply body' '1791000200000')
$res16b = Confirm-SendAttemptFromSnapshots -AttemptId $att16.AttemptId -Buyer 'Buyer X' -Text 'the reply body' -BeforeEvents $flatBefore -AfterEvents $afterClean -ConvoKey 'buyer x'
Check 'A16-fully-identified-single-new-event-confirms' ($res16b.Confirmed -and $res16b.DeliveryState -eq 'receipt_verified')
$res16c = Confirm-SendAttemptFromSnapshots -AttemptId $att16.AttemptId -Buyer 'Buyer X' -Text 'the reply body' -BeforeEvents $flatBefore -AfterEvents $afterClean -ConvoKey 'a-different-conversation'
Check 'A16-conversation-identity-mismatch-refused' (-not $res16c.Confirmed -and $res16c.Error -eq 'conversation-identity-mismatch')
$r1flat = New-ConfirmedOutboundReceipt -Buyer 'Buyer X' -Text 'the reply body' -Before $flatBefore -After $afterClean
Check 'A16-receipt-validator-rejects-mismatched-text' (-not (Test-ConfirmedOutboundReceipt $r1flat 'Buyer X' 'a different text'))

$att = New-PersistedSendAttempt -Buyer 'Buyer X' -Text 'the reply body' -DedupKey 'key|3' -TriggerRef 'key|3' -BeforeEvents @($flatBefore)
Check 'A15-attempt-persisted-before-send' ($att.Ok -and $att.AttemptId)
Check 'A15-attempt-records-before-proof' ($att.Record.beforeProof.EventCount -eq 2 -and $att.Record.textHash -eq (Get-MessageBodyFingerprint 'the reply body'))
Check 'A15-attempt-starts-not-attempted' ($att.Record.deliveryState -eq 'not_attempted')
Check 'R2-attempt-stores-the-complete-outgoing-text' ([string]$att.Record.text -eq 'the reply body' -and [int]$att.Record.textLength -eq 'the reply body'.Length)
Check 'R2-attempt-stores-a-recoverable-baseline' (@($att.Record.beforeProof.Baseline).Count -eq 2 -and @($att.Record.beforeProof.Baseline | Where-Object { $_.Identity }).Count -eq 2)
Check 'R2-persisted-attempt-without-side-effect-does-not-block' (-not (Test-SendAttemptBlocksResend -Buyer 'Buyer X' -TriggerRef 'key|3').Blocked)
$sideFx = Start-SendAttemptSideEffect -AttemptId $att.AttemptId -Detail 'before input/click'
Check 'R2-side-effect-stage-persisted-before-the-click' ($sideFx.Ok -and $sideFx.Record.stage -eq 'dispatching' -and $sideFx.Record.deliveryState -eq 'pending_confirmation' -and [bool]$sideFx.Record.sideEffectAtUtc)
Check 'scope-baseline-cannot-change-after-dispatching' (-not (Set-SendAttemptBeforeSnapshot -AttemptId $att.AttemptId -Buyer 'Buyer X' -Text 'the reply body' -BeforeEvents $flatBefore).Ok)
$attEmpty = New-PersistedSendAttempt -Buyer 'Buyer X' -Text '' -DedupKey 'k'
Check 'A15-empty-text-refused' (-not $attEmpty.Ok)

# A17：点击后超时/未确认 ⇒ 保持待确认，不重发同一触发
$null = Set-SendAttemptReceipt -AttemptId $att.AttemptId -Receipt $null -DeliveryState 'pending_confirmation'
$blk = Test-SendAttemptBlocksResend -Buyer 'Buyer X' -TriggerRef 'key|3'
Check 'A17-pending-confirmation-blocks-resend' ($blk.Blocked -and @($blk.Reasons).Count -eq 1)
$retry = Test-SendAttemptRetryAllowed -Buyer 'Buyer X' -TriggerRef 'key|3'
Check 'A17-no-blind-retry-while-unconfirmed' (-not $retry.Allowed -and $retry.Reason -eq 'unconfirmed-attempt-pending_confirmation')

# R3：会话级保护 —— 去重键不同**不**构成放行理由
$blkOther = Test-SendAttemptBlocksResend -Buyer 'Buyer X' -TriggerRef 'a-brand-new-trigger'
Check 'R3-new-trigger-in-the-same-conversation-is-blocked' ($blkOther.Blocked -and $blkOther.SessionBlocked -and @($blkOther.SameTrigger).Count -eq 0)
$retryOther = Test-SendAttemptRetryAllowed -Buyer 'Buyer X' -TriggerRef 'a-brand-new-trigger'
Check 'R3-new-trigger-does-not-auto-allow-a-retry' (-not $retryOther.Allowed -and $retryOther.Reason -eq 'unconfirmed-attempt-pending_confirmation')

# ------------------------------------------------------------------ 重启对账（持久化基线 + 同口径重读）
$attR = New-PersistedSendAttempt -Buyer 'Buyer Restart' -Text 'restart reply body' -DedupKey 'r|1' -TriggerRef 'r|1' -ConvoKey 'buyer restart' -BeforeEvents $flatBefore
$null = Start-SendAttemptSideEffect -AttemptId $attR.AttemptId
Check 'R2-restart-attempt-blocks-before-reconciliation' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)
Check 'R2-restart-candidate-is-listed-for-reconciliation' (@(Get-SendAttemptsNeedingReconciliation -Buyer 'Buyer Restart').Count -eq 1)
$reconNone = Invoke-SendAttemptReconciliation -AttemptId $attR.AttemptId -Events $flatBefore -ConvoKey 'buyer restart'
Check 'R2-reconciliation-without-a-new-event-keeps-pending' ((-not $reconNone.Applied) -and $reconNone.Error -eq 'no-new-outbound-event' -and (Get-SendAttempt $attR.AttemptId).deliveryState -eq 'pending_confirmation')
$newOut = [pscustomobject]@{ MessageId = 'PLAT-9001'; MessageTime = '1791000900000'; TimePrecision = 'second'; Text = 'restart reply body'; IsMine = $true; Identity = 'id:PLAT-9001'; IdentityQuality = 'platform-id'; Direction = 'out'; IsBuyer = $false; IsNoise = $false; BodyHash = (Get-MessageBodyFingerprint 'restart reply body') }
$reconOk = Invoke-SendAttemptReconciliation -AttemptId $attR.AttemptId -Events (@($flatBefore) + @($newOut)) -ConvoKey 'buyer restart'
Check 'R2-reconciliation-proves-delivery-from-persisted-baseline' ($reconOk.Ok -and $reconOk.Applied -and $reconOk.DeliveryState -eq 'receipt_verified')
$recR = Get-SendAttempt $attR.AttemptId
Check 'R2-recovered-receipt-binds-the-exact-new-event' ([bool]$recR.receipt -and $recR.receipt.Valid -and $recR.receipt.MessageId -eq 'PLAT-9001' -and $recR.receipt.ConfirmationType -eq 'recovered-from-persisted-baseline')
Check 'R2-recovered-receipt-validates-against-the-stored-text' ((Test-ConfirmedOutboundReceipt $recR.receipt 'Buyer Restart' 'restart reply body'))
# [复核 R8] 反例（修复前）：Set-SendAttemptReceipt 把尝试写成 receipt_verified 时就**同时**解除了会话保护，
#   而 persistence.sentRecord / persistence.ledger 仍是 pending，且 -ActiveOnly 直接排除所有 receipt_verified，
#   于是这条尝试既不会恢复也不会再挡住这个会话。现在"送达已证明"与"持久化全部完成"分开判断：
#   账本还没提交 ⇒ 会话必须继续被挡住，直到恢复入口真的把两段写进去并回读核验。
Check 'R8-reconciliation-alone-does-not-release-the-conversation' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)
Check 'R8-reconciled-receipt-without-ledgers-stays-active' (@(Get-SendAttempts -Buyer 'Buyer Restart' -ActiveOnly).Count -eq 1)
Check 'R8-reconciliation-reports-persistence-separately' ((-not $reconOk.PersistenceComplete) -and (-not $reconOk.PersistenceOk) -and $reconOk.SentRecord -eq 'ok' -and $reconOk.Ledger -eq 'failed' -and $reconOk.Blocked)
Check 'R8-reconciled-receipt-without-ledgers-is-not-settled' (-not (Test-SendAttemptSettled (Get-SendAttempt $attR.AttemptId)))
Check 'R8-reconciled-receipt-without-ledgers-needs-persistence' ((Test-SendAttemptPersistencePending (Get-SendAttempt $attR.AttemptId)))
$attR2 = New-PersistedSendAttempt -Buyer 'Buyer Restart' -Text 'restart reply body two' -DedupKey 'r|2' -TriggerRef 'r|2' -ConvoKey 'buyer restart' -BeforeEvents $flatBefore
$null = Start-SendAttemptSideEffect -AttemptId $attR2.AttemptId
$ambEv = [pscustomobject]@{ MessageId = ''; MessageTime = ''; TimePrecision = ''; Text = 'restart reply body two'; IsMine = $true; Identity = ''; IdentityQuality = 'unusable'; Direction = 'out'; IsBuyer = $false; IsNoise = $false; BodyHash = (Get-MessageBodyFingerprint 'restart reply body two') }
$reconAmb = Invoke-SendAttemptReconciliation -AttemptId $attR2.AttemptId -Events (@($flatBefore) + @($ambEv)) -ConvoKey 'buyer restart'
Check 'R2-reconciliation-with-an-unidentified-new-bubble-is-ambiguous' ($reconAmb.DeliveryState -eq 'delivery_ambiguous' -and (Get-SendAttempt $attR2.AttemptId).deliveryState -eq 'delivery_ambiguous')
Check 'R2-ambiguous-reconciliation-opens-an-investigation' ([bool]$reconAmb.InvestigationId)
Check 'R2-ambiguous-attempt-still-blocks-the-conversation' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)

# A18：收据有效但 sent_records 写入 false / 异常，或账本部分成功
$att2 = New-PersistedSendAttempt -Buyer 'Buyer X' -Text 'second reply' -DedupKey 'key|4' -TriggerRef 'key|4' -BeforeEvents @($flatBefore)
$null = Set-SendAttemptReceipt -AttemptId $att2.AttemptId -Receipt $r1flat -DeliveryState 'receipt_verified'
$fail1 = Complete-SendAttemptPersistence -AttemptId $att2.AttemptId -SentRecordWriter { return $false } -LedgerWriter { return $true }
Check 'A18-sent-record-false-blocks' (-not $fail1.Ok -and $fail1.DeliveryState -eq 'persistence_pending' -and $fail1.Blocked)
Check 'A18-persistence-failure-investigation' ([bool]$fail1.InvestigationId)
Check 'A18-ledger-not-advanced-after-partial' ($fail1.SentRecord -eq 'failed' -and $fail1.Ledger -eq 'pending')
$invPersist = Get-Investigation $fail1.InvestigationId
Check 'A18-investigation-kind-is-persistence' ($invPersist -and $invPersist.kind -eq 'receipt_persistence_failed' -and $invPersist.attemptId -eq $att2.AttemptId)
$blk2 = Test-SendAttemptBlocksResend -Buyer 'Buyer X' -TriggerRef 'key|4'
Check 'A18-persistence-pending-blocks-resend' ($blk2.Blocked)
$fail2 = Complete-SendAttemptPersistence -AttemptId $att2.AttemptId -SentRecordWriter { throw 'disk full' } -LedgerWriter { return $true }
Check 'A18-writer-exception-recorded' (-not $fail2.Ok -and $fail2.Error -match 'sent-record-writer-exception|sent-record-write-returned-false|returned-false|disk full')
# 恢复：真的写入成功后补齐幂等登记
$ok = Complete-SendAttemptPersistence -AttemptId $att2.AttemptId -SentRecordWriter { return $true } -LedgerWriter { return $true }
Check 'A18-recovery-completes-persistence' ($ok.Ok -and $ok.SentRecord -eq 'ok' -and $ok.Ledger -eq 'ok')
$again = Complete-SendAttemptPersistence -AttemptId $att2.AttemptId -SentRecordWriter { return $true } -LedgerWriter { return $true }
Check 'A18-idempotent-second-completion' ($again.Ok -and $again.AlreadyDone)

# 【复核 R4】恢复入口必须**自带真实写入器**，不再得到 no-sent-record-writer / no-ledger-writer
$att4 = New-PersistedSendAttempt -Buyer 'Buyer X' -Text 'resume reply body' -DedupKey 'key|5' -TriggerRef 'key|5' -BeforeEvents @($flatBefore)
$r4rec = New-ConfirmedOutboundReceipt -Buyer 'Buyer X' -Text 'resume reply body' -Before $flatBefore -After (@($flatBefore) + @(New-OutboundEvent 'resume reply body' '1791000300000'))
Check 'R4-recovery-fixture-receipt-is-valid' ($r4rec.Valid -and (Test-ConfirmedOutboundReceipt $r4rec 'Buyer X' 'resume reply body'))
$null = Set-SendAttemptReceipt -AttemptId $att4.AttemptId -Receipt $r4rec -DeliveryState 'receipt_verified'
$fail4 = Complete-SendAttemptPersistence -AttemptId $att4.AttemptId -SentRecordWriter { return $false } -LedgerWriter { return $true }
Check 'R4-persistence-failure-keeps-a-retryable-state' ((-not $fail4.Ok) -and $fail4.DeliveryState -eq 'persistence_pending' -and (Get-SendAttempt $att4.AttemptId).deliveryState -eq 'persistence_pending')
Check 'R4-resume-without-writers-refuses-instead-of-faking' ((Resume-SendAttemptPersistence -AttemptId $att4.AttemptId) -eq $false)
$att4Rec = Get-SendAttempt $att4.AttemptId
$w4 = Get-SendAttemptProductionWriters $att4.AttemptId
Check 'R4-production-writers-bind-the-stored-attempt-text' ($null -ne $w4 -and [string]$w4.Text -eq 'resume reply body' -and [string]$w4.Receipt.ReceiptId -eq [string]$att4Rec.receipt.ReceiptId -and $w4.SentRecordWriter -eq 'Invoke-SendAttemptSentRecordWrite')
# 隔离根里还没有 state.json ⇒ 账本写入必须**失败**，恢复不得伪造成功
$resumeNoLedger = Complete-SendAttemptPersistence -AttemptId $att4.AttemptId -UseProductionWriters -Detail 'offline-recovery'
Check 'R4-recovery-does-not-fake-success-without-a-ledger' ((-not $resumeNoLedger.Ok) -and $resumeNoLedger.SentRecord -eq 'ok' -and $resumeNoLedger.Ledger -eq 'failed' -and (Get-SendAttempt $att4.AttemptId).deliveryState -eq 'persistence_pending')
Check 'R4-sent-record-from-recovery-is-really-present' (@(Get-SentRecords -Buyer 'Buyer X' | Where-Object { [string]$_.receipt.ReceiptId -eq [string]$r4rec.ReceiptId }).Count -ge 1)
# 建好账本之后重试同一恢复：两段都成功，且账本键可回读
$ledgerPath = Get-SkillPath 'state'
[void](Write-JsonDocumentAtomic -Path $ledgerPath -Data ([pscustomobject]@{ replied = [pscustomobject]@{} }) -Depth 5)
$resumeOk = Complete-SendAttemptPersistence -AttemptId $att4.AttemptId -UseProductionWriters -Detail 'offline-recovery-retry'
Check 'R4-recovery-completes-when-both-writes-really-succeed' ($resumeOk.Ok -and $resumeOk.SentRecord -eq 'ok' -and $resumeOk.Ledger -eq 'ok')
$ledgerBack = Read-JsonDocument $ledgerPath
$ledgerValue = ''
foreach ($p in $ledgerBack.Data.replied.PSObject.Properties) { if ([string]$p.Name -eq 'buyer x') { $ledgerValue = [string]$p.Value } }
Check 'R4-ledger-entry-is-verified-by-read-back' ($ledgerBack.Status -eq 'valid' -and $ledgerValue -eq 'key|5')
Check 'R4-empty-dedup-key-is-refused-not-invented' (-not (Set-SendAttemptLedgerEntry -Buyer 'Buyer Nobody' -DedupKey ''))

# =============================================================================================
# 【复核 R8】"送达已证明"与"持久化全部完成"分开判断
#
#   反例（修复前，本会话在同一临时隔离根复现）：
#     Set-SendAttemptReceipt 写成 receipt_verified ⇒ persistence.sentRecord / persistence.ledger 仍为 pending；
#     Get-SendAttempts -ActiveOnly 直接排除所有 receipt_verified ⇒ 该尝试不进恢复队列；
#     Test-SendAttemptBlocksResend 只认 pending_confirmation/persistence_pending/delivery_ambiguous
#       ⇒ 会话已经被"解除保护"，而去重账本与 sent_records 里什么都没有。
#   下面覆盖生产消费者：收据保存 → 会话仍被挡 → 生产恢复入口幂等补齐 → 才解除。
# =============================================================================================
$att8 = New-PersistedSendAttempt -Buyer 'Buyer Persist' -Text 'persist reply body' -DedupKey 'p|1' -TriggerRef 'p|1' -ConvoKey 'buyer persist' -BeforeEvents $flatBefore
$null = Start-SendAttemptSideEffect -AttemptId $att8.AttemptId
$r8rec = New-ConfirmedOutboundReceipt -Buyer 'Buyer Persist' -Text 'persist reply body' -Before $flatBefore -After (@($flatBefore) + @(New-OutboundEvent 'persist reply body' '1791000700000'))
Check 'R8-fixture-receipt-is-valid' ($r8rec.Valid -and (Test-ConfirmedOutboundReceipt $r8rec 'Buyer Persist' 'persist reply body'))
$null = Set-SendAttemptReceipt -AttemptId $att8.AttemptId -Receipt $r8rec -DeliveryState 'receipt_verified'
$rec8 = Get-SendAttempt $att8.AttemptId
Check 'R8-receipt-saved-while-both-ledgers-are-still-pending' ($rec8.deliveryState -eq 'receipt_verified' -and [string]$rec8.persistence.sentRecord -eq 'pending' -and [string]$rec8.persistence.ledger -eq 'pending')
Check 'R8-receipt-without-ledgers-still-blocks-the-conversation' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Persist').Blocked)
Check 'R8-receipt-without-ledgers-is-not-settled' (-not (Test-SendAttemptSettled $rec8))
Check 'R8-receipt-without-ledgers-stays-active' (@(Get-SendAttempts -Buyer 'Buyer Persist' -ActiveOnly).Count -eq 1)
Check 'R8-receipt-without-ledgers-needs-persistence-not-reconciliation' (@(Get-SendAttemptsNeedingReconciliation -Buyer 'Buyer Persist').Count -eq 0 -and (Test-SendAttemptPersistencePending $rec8))
$retry8 = Test-SendAttemptRetryAllowed -Buyer 'Buyer Persist' -TriggerRef 'a-brand-new-trigger'
Check 'R8-a-new-trigger-does-not-release-an-unpersisted-receipt' ((-not $retry8.Allowed) -and $retry8.AttemptId -eq $att8.AttemptId)
# 续做入口的判据也换成"还有效收据而持久化没完成"，但**没有写入器时必须拒绝**而不是伪造成功
Check 'R8-resume-accepts-the-state-but-refuses-without-writers' ((Resume-SendAttemptPersistence -AttemptId $att8.AttemptId) -eq $false -and (Test-SendAttemptPersistencePending (Get-SendAttempt $att8.AttemptId)))
# 生产恢复入口（monitor 每轮扫描 / CLI recover 共用）必须挑到这条 receipt_verified 的尝试
$recov8 = Invoke-SendAttemptPersistenceRecovery -Buyer 'Buyer Persist'
Check 'R8-recovery-picks-up-a-receipt_verified-attempt' (@($recov8.Results).Count -eq 1 -and [string]$recov8.Results[0].AttemptId -eq $att8.AttemptId)
Check 'R8-recovery-commits-both-writes' ([bool]$recov8.Results[0].Ok -and $recov8.Results[0].SentRecord -eq 'ok' -and $recov8.Results[0].Ledger -eq 'ok')
Check 'R8-recovery-releases-the-conversation' (-not (Test-SendAttemptBlocksResend -Buyer 'Buyer Persist').Blocked)
Check 'R8-sent-record-from-recovery-is-on-disk' (@(Get-SentRecords -Buyer 'Buyer Persist' | Where-Object { [string]$_.receipt.ReceiptId -eq [string]$r8rec.ReceiptId }).Count -eq 1)
$ledger8 = Read-JsonDocument $ledgerPath
$ledgerVal8 = ''
if ($ledger8.Data -and ($ledger8.Data.PSObject.Properties.Name -contains 'replied')) {
    foreach ($p in $ledger8.Data.replied.PSObject.Properties) { if ([string]$p.Name -eq 'buyer persist') { $ledgerVal8 = [string]$p.Value } }
}
Check 'R8-ledger-entry-from-recovery-is-on-disk' ($ledgerVal8 -eq 'p|1')
$again8 = Invoke-SendAttemptPersistenceRecovery -Buyer 'Buyer Persist'
Check 'R8-recovery-is-idempotent-once-both-writes-are-ok' (@($again8.Results).Count -eq 0 -and (Test-SendAttemptSettled (Get-SendAttempt $att8.AttemptId)))

# 保留上限：收据已保存但账本未提交的尝试**不得**被当成 settled 淘汰（否则证据会被静默丢掉）
$capItems = @{}
$capReceipt = [pscustomobject]@{ Valid = $true; ReceiptId = 'cap-receipt' }
for ($ci = 0; $ci -lt 40; $ci++) {
    $capItems['att-cap-' + $ci] = [pscustomobject]@{
        attemptId = 'att-cap-' + $ci; buyerKey = 'buyer cap'; convoKey = 'buyer cap'
        deliveryState = 'receipt_verified'; createdAtUtc = ('2026-10-07T00:00:{0:D2}.0000000Z' -f $ci)
        receipt = $capReceipt
        persistence = [pscustomobject]@{ sentRecord = 'ok'; ledger = 'ok' }
    }
}
for ($cj = 0; $cj -lt 4; $cj++) {
    $capItems['att-cap-new-' + $cj] = [pscustomobject]@{
        attemptId = 'att-cap-new-' + $cj; buyerKey = 'buyer cap'; convoKey = 'buyer cap'
        deliveryState = 'receipt_verified'; createdAtUtc = ('2026-10-07T01:00:{0:D2}.0000000Z' -f $cj)
        receipt = $capReceipt
        persistence = [pscustomobject]@{ sentRecord = 'ok'; ledger = 'ok' }
    }
}
$capItems['att-cap-open'] = [pscustomobject]@{
    attemptId = 'att-cap-open'; buyerKey = 'buyer cap'; convoKey = 'buyer cap'
    deliveryState = 'receipt_verified'; createdAtUtc = '1999-01-01T00:00:00.0000000Z'
    receipt = $capReceipt
    persistence = [pscustomobject]@{ sentRecord = 'pending'; ledger = 'pending' }
}
Check 'R8-cap-fixture-separates-settled-from-unpersisted' ((Test-SendAttemptSettled $capItems['att-cap-0']) -and (-not (Test-SendAttemptSettled $capItems['att-cap-open'])))
$trimmed = Remove-ExcessSendAttempts $capItems 'buyer cap'
Check 'R8-cap-never-evicts-a-receipt-without-a-ledger' ([bool]$trimmed.ContainsKey('att-cap-open'))
Check 'R8-cap-evicts-only-fully-persisted-attempts' (@($trimmed.Keys).Count -eq 40)

# 正常重启对账（真实消费者路径）：对账拿到的收据随后由生产恢复入口补齐两段账本
$recovRestart = Invoke-SendAttemptPersistenceRecovery -Buyer 'Buyer Restart'
Check 'R8-restart-reconciled-attempt-is-completed-by-the-recovery-scan' (@($recovRestart.Results).Count -eq 1 -and [string]$recovRestart.Results[0].AttemptId -eq $attR.AttemptId -and [bool]$recovRestart.Results[0].Ok)
Check 'R8-restart-reconciled-attempt-is-settled-after-the-recovery' ((Test-SendAttemptSettled (Get-SendAttempt $attR.AttemptId)))
Check 'R8-restart-conversation-still-blocked-by-the-ambiguous-attempt' ((Test-SendAttemptBlocksResend -Buyer 'Buyer Restart').Blocked)

# 真实 Add-SentRecord 幂等登记（收据校验是前置条件）
$okRec = Add-SentRecord -Buyer 'Buyer X' -Text 'the reply body' -Receipt $r1flat
Check 'A15-sent-record-written-with-valid-receipt' ([bool]$okRec)
$badRec = Add-SentRecord -Buyer 'Buyer X' -Text 'the reply body' -Receipt $r3
Check 'A16-sent-record-refuses-invalid-receipt' (-not [bool]$badRec)
Check 'R4-production-writers-are-real-and-verifiable' ($null -ne (Get-SendAttemptProductionWriters $att2.AttemptId))

# A19：可靠未送达证明，但原诉求已被人工处理/过期 ⇒ 不重试旧回复
$att3 = New-PersistedSendAttempt -Buyer 'Buyer Y' -Text 'stale reply' -DedupKey 'ykey|1' -TriggerRef 'ykey|1' -BeforeEvents @()
$null = Start-SendAttemptSideEffect -AttemptId $att3.AttemptId
$null = Set-SendAttemptStage -AttemptId $att3.AttemptId -Stage 'failed' -DeliveryState 'not_delivered_verified' -Detail 'page reported NOT_SENT'
$allow = Test-SendAttemptRetryAllowed -Buyer 'Buyer Y' -TriggerRef 'ykey|1'
Check 'A19-not-delivered-is-not-a-retry-authorisation' ($allow.Allowed)
$invNotDelivered = New-OrUpdate-Investigation -Buyer 'Buyer Y' -Kind 'receipt_pending' -AttemptId $att3.AttemptId -EventRefQuality 'attempt' -EvidenceRefs @('not-delivered:page-NOT_SENT')
$resAttempt = Resolve-Investigation -Id ([string]$invNotDelivered.Record.id) -By 'ops' -DeliveryState 'not_delivered_verified' -Evidence 'page:NOT_SENT reported by the send adapter after the click'
Check 'A19-delivery-investigation-closes-with-evidence' ($resAttempt.Ok)
$noEvidence = Resolve-Investigation -Id ([string]$invNotDelivered.Record.id) -By 'ops' -DeliveryState 'receipt_verified' -Evidence '' -ReceiptId ''
Check 'A19-delivery-closure-needs-evidence' (-not $noEvidence.Ok)

# A24（部分）：损坏存储阻断；活跃证明不被剪枝
$invFile = Get-SkillPath 'investigations'
$keep = [IO.File]::ReadAllText($invFile)
[IO.File]::WriteAllText($invFile, '{ this is not json', (New-Object Text.UTF8Encoding($false)))
$blocked = New-OrUpdate-Investigation -Buyer 'Buyer Z' -Kind 'source_unverified' -EventRef 'ref-1'
Check 'A24-corrupt-store-blocks-new-investigation' (-not $blocked.Ok -and $blocked.Error -match 'investigation-store-')
$blocked2 = Complete-SendAttemptPersistence -AttemptId $att2.AttemptId -SentRecordWriter { return $true } -LedgerWriter { return $true }
Check 'A24-corrupt-store-does-not-fake-success' ([bool]$blocked2.Ok)
[IO.File]::WriteAllText($invFile, $keep, (New-Object Text.UTF8Encoding($true)))
$active = @(Get-Investigations -ActiveOnly)
$ret = Invoke-InvestigationRetention -ClosedRetentionDays 0
Check 'A24-active-investigations-not-pruned' ($ret.Ok -and $ret.Removed -eq 0 -and @(Get-Investigations -ActiveOnly).Count -eq $active.Count)
Check 'A24-retention-no-write-when-nothing-removed' ($ret.Kept -eq @(Get-Investigations).Count)

# 发送尝试存储的保留策略：未确认的尝试不被淘汰
$storeFile = Get-SkillPath 'send_attempts'
Check 'A24-attempt-store-is-inside-runtime-root' ([bool](Test-AarPathUnder $storeFile (Get-SkillRuntimeRoot)))

$failedBaseline = New-PersistedSendAttempt -Buyer 'Buyer Baseline Failure' -Text $REPLY -BeforeEvents $before
$attemptAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'lib/send_attempts.ps1'),[ref]$null,[ref]$null)
$saveFn=$attemptAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-SendAttemptRecord'},$true)
function Save-SendAttemptRecord { param($Record) return $false }
try {
    $failedBinding=Set-SendAttemptBeforeSnapshot -AttemptId $failedBaseline.AttemptId -Buyer 'Buyer Baseline Failure' -Text $REPLY -BeforeEvents $afterOk
    Check 'scope-baseline-write-failure-is-not-dispatchable' (-not $failedBinding.Ok -and $failedBinding.Error -eq 'before-snapshot-write-failed' -and (Get-SendAttempt $failedBaseline.AttemptId).stage -eq 'persisted')
} finally {Invoke-Expression $saveFn.Extent.Text}
Check 'scope-empty-before-baseline-is-refused' (-not (Set-SendAttemptBeforeSnapshot -AttemptId $failedBaseline.AttemptId -Buyer 'Buyer Baseline Failure' -Text $REPLY -BeforeEvents @()).Ok)

if ($script:domJsFile -and (Test-Path $script:domJsFile)) { Remove-Item -LiteralPath $script:domJsFile -Force -ErrorAction SilentlyContinue }

Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
