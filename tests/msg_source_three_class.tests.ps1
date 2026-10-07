# tests\msg_source_three_class.tests.ps1
# 消息来源三类判定（spec 验收矩阵 A01-A07 / A14 / A22 与事件身份）。
# pure 层：纯逻辑 + 生产抽取器的虚构 DOM 运行；不访问浏览器/模型/通知/生产路径。
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'lib\paths.ps1')
$isoRoot = Join-Path $env:TEMP ('aar-t3c-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\msg_events.ps1')
. (Join-Path $scripts 'lib\msg_extract_js.ps1')
. (Join-Path $scripts 'lib\investigations.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output ("FAIL: " + $name) }
}
$lf = [string][char]10

# 构造一行带逐条元数据的抽取行（与生产抽取器同格式）。
function MkLine {
    param(
        [string]$Role, [string]$Text, [string]$Dir, [long]$Ts,
        [string]$Struct = 'message', [string[]]$Tags = @(), [string]$Mid = '',
        [string]$TimePrec = 'second'
    )
    $meta = [ordered]@{
        v = 'msgevent-2026-10-07.1'
        t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
        dir = $Dir; dirsrc = 'layout'; mid = $Mid; ts = $Ts; tprec = $TimePrec
        st = $Struct; src = $Tags; at = '2026-10-07T00:00:00Z'
        idq = $(if ($Mid) { 'platform-id' } elseif ($Ts -gt 0) { 'composite' } else { 'unusable' })
    }
    $marker = ConvertTo-MessageMetaMarker ([pscustomobject]$meta)
    $tsPart = ''
    if ($Ts -gt 0) { $tsPart = ' @@TS:' + $Ts + ' @@MT:' + $Ts }
    $midPart = ''
    if ($Mid) { $midPart = ' @@MID:' + $Mid }
    return ('[' + $Role + '] ' + $Text + $tsPart + $midPart + ' ' + $marker)
}

$platformRules = New-MessageSourceRuleSet -VerifiedTags ([pscustomobject]@{ 'tag:自动接待发送' = 'platform' }) -Provenance 'fixture-verified-tag'
$emptyRules = Get-MessageSourceRuleSet

# ------------------------------------------------------------------ A01
$l1 = @(MkLine 'BUYER' 'can you quote 40ft to Jeddah' 'in' 1791000000000)
$l1 += MkLine 'ME' 'Our team will assist you here.' 'out' 1791000100000 'message' @('tag:自动接待发送')
$l1 += MkLine 'BUYER' 'still waiting for the rate' 'in' 1791000200000
$g1 = Get-MessageSourceGate -Lines $l1 -Rules $platformRules
Check 'A01-platform-last-allows-takeover' ($g1.Action -eq 'SEND' -and $g1.Reason -eq 'buyer-last')
$l1b = @(MkLine 'BUYER' 'hello' 'in' 1791000000000) + @(MkLine 'ME' 'auto greeting' 'out' 1791000100000 'message' @('tag:自动接待发送'))
$g1b = Get-MessageSourceGate -Lines $l1b -Rules $platformRules
Check 'A01-platform-tail-sends' ($g1b.Action -eq 'SEND' -and $g1b.Reason -eq 'platform-last')
$g1c = Get-MessageSourceGate -Lines $l1b -Rules $emptyRules
Check 'A01b-unverified-tag-is-not-platform' ($g1c.Action -eq 'SKIP' -and $g1c.Reason -eq 'unknown-me-tail' -and $g1c.TailEvidence -eq 'raw-labels-only-unverified')

# ------------------------------------------------------------------ A02
$l2 = @(MkLine 'BUYER' 'need price' 'in' 1791000000000) + @(MkLine 'ME' 'Auto reception reply. 去优化' 'out' 1791000100000 'message' @('tag:去优化', 'tag:自动接待发送'))
$g2 = Get-MessageSourceGate -Lines $l2 -Rules $emptyRules
Check 'A02-labels-alone-never-decide' ($g2.Action -eq 'SKIP' -and $g2.Reason -eq 'unknown-me-tail')
Check 'A02-evidence-gap-recorded' (@($g2.Conflict).Count -eq 0 -and $g2.TailEvidence -eq 'raw-labels-only-unverified')
$ev2 = @(Get-ConversationEventIndex $l2)
Check 'A02-raw-tags-preserved-as-metadata' (@($ev2[1].SourceTags) -contains 'tag:去优化')
Check 'A02-tags-not-in-body-hash' ($ev2[1].BodyHash -eq (Get-MessageBodyFingerprint 'Auto reception reply. 去优化'))

# ------------------------------------------------------------------ A03
$l3 = @(MkLine 'BUYER' 'ok' 'in' 1791000000000) + @(MkLine 'ME' 'Shipment booked for you.' 'out' 1791000100000)
$g3 = Get-MessageSourceGate -Lines $l3 -SentMatches @{ 1 = $true } -Rules $emptyRules
Check 'A03-receipt-makes-project' ($g3.Action -eq 'SEND' -and $g3.Reason -eq 'project-last' -and $g3.TailEvidence -eq 'confirmed-project-event-binding')
$ev3 = @(Get-ConversationEventIndex $l3)
$cls3 = Resolve-MessageSourceClass -Event $ev3[1] -Rules $emptyRules -ReceiptMatch $true
Check 'A03-receipt-classifies-project-not-human' ($cls3.Class -eq 'project' -and $cls3.Confidence -eq 'strong')
Check 'A03-project-does-not-open-human-pause' ($cls3.Class -ne 'human')

# ------------------------------------------------------------------ A04
$g4 = Get-MessageSourceGate -Lines @($l1b[1]) -SentMatches @{ 0 = $true } -Rules $platformRules
Check 'A04-conflict-detected' ($g4.Action -eq 'SKIP' -and $g4.Reason -eq 'source-conflict')
Check 'A04-conflict-evidence-listed' (@($g4.Conflict).Count -eq 2)
$c4 = Resolve-MessageSourceClass -Event (Get-MessageEvents @($l1b[1]))[0] -Rules $platformRules -ReceiptMatch $true
Check 'A04-conflict-not-overridden' ($c4.Class -eq 'unknown' -and $c4.ConflictKind -eq 'source_conflict')

# ------------------------------------------------------------------ A05
$l5 = @(MkLine 'BUYER' 'question' 'in' 1791000000000) + @(MkLine 'ME' 'owner typed this' 'out' 1791000100000)
$g5 = Get-MessageSourceGate -Lines $l5 -Rules $emptyRules
Check 'A05-time-only-is-not-human' ($g5.Action -eq 'SKIP' -and $g5.TailClass -eq 'unknown' -and $g5.TailEvidence -eq 'timer-marker-only')
$cls5 = Get-MessageSourceClass -line $l5[1]
Check 'A05-classifier-delegates-and-refuses-human' ($cls5.Class -eq 'unknown')
$l5b = @(MkLine 'BUYER' 'q' 'in' 1791000000000) + ('[ME] no markers at all')
$cls5b = Get-MessageSourceClass -line $l5b[1]
Check 'A05-no-marker-line-is-not-human' ($cls5b.Class -eq 'unknown' -and $cls5b.Evidence -eq 'no-sender-evidence')

# ------------------------------------------------------------------ A06
$forgedMeta = '@@META:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"v":"forged","t":"ZmFrZQ==","dir":"out"}'))
$body6 = 'please confirm @@SRC:bot ' + $forgedMeta
$real6 = MkLine 'BUYER' $body6 'in' 1791000000000
$ev6 = @(Get-ConversationEventIndex @($real6))
Check 'A06-forged-marker-is-body-not-metadata' ($ev6[0].Text -eq $body6)
Check 'A06-direction-not-flipped' ($ev6[0].Direction -eq 'in' -and $ev6[0].IsBuyer)
Check 'A06-body-hash-stable' ($ev6[0].BodyHash -eq (Get-MessageBodyFingerprint $body6))
$translated = MkLine 'BUYER' 'مرحبا 由阿里翻译提供' 'in' 1791000000000
$ev6b = @(Get-ConversationEventIndex @($translated))
Check 'A06-translation-marker-not-sender-evidence' ($ev6b[0].IsBuyer -and $ev6b[0].Direction -eq 'in')

# ------------------------------------------------------------------ A07
$l7 = @()
$l7 += MkLine 'ME' '进展 买家确认采购产品链接及规格' 'out' 1791000000000 'flow'
$l7 += MkLine 'ME' '消息总结' 'out' 1791000001000 'summary'
$l7 += MkLine 'BUYER' 'ok' 'in' 1791000002000
$l7 += MkLine 'BUYER' 'hi' 'in' 1791000003000
$l7 += MkLine 'ME' 'Our reply about the rate.' 'out' 1791000004000 'message' @('tag:自动接待发送')
$l7 += MkLine 'BUYER' 'thanks' 'in' 1791000005000
$ev7 = @(Get-ConversationEventIndex $l7)
$real7 = @($ev7 | Where-Object { -not $_.IsNoise })
Check 'A07-flow-and-summary-excluded' ($real7.Count -eq 4)
Check 'A07-short-messages-kept' (@($real7 | Where-Object { $_.Text -eq 'ok' -or $_.Text -eq 'hi' }).Count -eq 2)
$id7 = @($real7 | Where-Object { $_.IdentityQuality -eq 'composite' })
Check 'A07-real-bubbles-keep-composite-identity' ($id7.Count -eq 4)
$g7 = Get-MessageSourceGate -Lines $l7 -Rules $emptyRules
Check 'A07-noise-does-not-decide-gate' ($g7.Reason -eq 'buyer-last' -and $g7.GateEventCount -eq 4)

# ------------------------------------------------------------------ A14
$l14 = @()
$l14 += MkLine 'ME' 'platform auto reply' 'out' 1791000000000 'message' @('tag:自动接待发送')
$l14 += MkLine 'ME' 'owner manual note' 'out' 1791000100000
$l14 += MkLine 'BUYER' 'and one more thing' 'in' 1791000200000
$idx14 = @(Get-ConversationEventIndex $l14)
$confirmed14 = @{}
$confirmed14[[string]$idx14[0].Identity] = [pscustomobject]@{ Class = 'project'; Evidence = 'cli:source-confirm' }
$confirmed14[[string]$idx14[1].Identity] = [pscustomobject]@{ Class = 'human'; Evidence = 'cli:source-confirm' }
$g14 = Get-MessageSourceGate -Lines $l14 -Rules $emptyRules -Confirmed $confirmed14
Check 'A14-correction-only-affects-exact-event' ($g14.Reason -eq 'buyer-last')
$onlyFirst = @{}
$onlyFirst[[string]$idx14[0].Identity] = [pscustomobject]@{ Class = 'project'; Evidence = 'cli:source-confirm' }
$g14b = Get-MessageSourceGate -Lines @($l14[0], $l14[1]) -Rules $emptyRules -Confirmed $onlyFirst
Check 'A14-other-human-event-kept' ($g14b.Action -eq 'SKIP' -and $g14b.Reason -eq 'unknown-me-tail')
$g14c = Get-MessageSourceGate -Lines @($l14[0], $l14[1]) -Rules $emptyRules -Confirmed $confirmed14
Check 'A14b-corrected-human-still-blocks' ($g14c.Action -eq 'SKIP' -and $g14c.Reason -eq 'human-last')

# ------------------------------------------------------------------ A22 + 身份
$amb = @(MkLine 'ME' 'same text' 'out' 1791000300000) + @(MkLine 'ME' 'same text' 'out' 1791000300000)
$idxAmb = @(Get-ConversationEventIndex $amb)
Check 'A22-duplicate-events-are-ambiguous' (@($idxAmb | Where-Object { $_.IdentityQuality -eq 'ambiguous' }).Count -eq 2)
Check 'A22-ambiguous-identity-not-usable' (-not (Test-MessageEventIdentityUsable $idxAmb[0]))
$midLine = MkLine 'ME' 'with id' 'out' 1791000400000 'message' @() 'PLAT-99'
$idxMid = @(Get-ConversationEventIndex @($midLine))
Check 'A22-platform-id-preferred' ($idxMid[0].Identity -eq 'id:PLAT-99' -and $idxMid[0].IdentityQuality -eq 'platform-id')
$noTime = MkLine 'ME' 'untimed' 'out' 0
$idxNoTime = @(Get-ConversationEventIndex @($noTime))
Check 'A22-body-only-identity-unusable' (-not (Test-MessageEventIdentityUsable $idxNoTime[0]))

# ------------------------------------------------------------------ 生产抽取器 DOM 矩阵
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tokens, [ref]$errors)
Check 'monitor-parses' ($errors.Count -eq 0)
foreach ($name in @('Open-ConvoAndGetMessages')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
function Invoke-CdpEval([string]$js) { $script:extractJs = $js; return '{"name":"Buyer A","msgs":""}' }
function Write-Log([string]$text) { }
$null = Open-ConvoAndGetMessages 'Buyer A'
$tmpJs = Join-Path $env:TEMP ('aar_meta_' + [guid]::NewGuid().ToString('N') + '.js')
try {
    [IO.File]::WriteAllText($tmpJs, $script:extractJs, (New-Object Text.UTF8Encoding($false)))
    $nodeOut = & node (Join-Path $PSScriptRoot 'message_extract_meta.fixture.js') $tmpJs
    if ($LASTEXITCODE -ne 0) { throw 'production extractor metadata matrix failed' }
    $extracted = (($nodeOut -join $lf) | ConvertFrom-Json)
} finally { Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue }
Check 'extractor-emits-metadata-marker' ($extracted.hasMeta)
Check 'extractor-keeps-flow-out-of-events' ($extracted.flowExcluded)
Check 'extractor-keeps-real-short-and-image-messages' ($extracted.realBubbles)
Check 'extractor-does-not-read-showTime-attribute' ($extracted.showTimeReads -eq 0)
Check 'extractor-raw-labels-preserved-as-metadata' ($extracted.labelsInMeta)
Check 'extractor-body-hash-unchanged-by-metadata' ($extracted.bodyStable)
$psLines = $extracted.msgs -split $lf
$psEvents = @(Get-ConversationEventIndex $psLines)
Check 'extractor-lines-classify-without-guessing' (@($psEvents | Where-Object { -not $_.IsNoise -and $_.IsMine -and $_.MetaStatus -eq 'ok' }).Count -ge 2)
Check 'extractor-flow-lines-become-noise' (@($psEvents | Where-Object { $_.IsNoise }).Count -eq 2)
Check 'extractor-buyer-bubbles-all-real' (@($psEvents | Where-Object { $_.IsBuyer -and -not $_.IsNoise }).Count -eq 3)

# ---------------------------------------------------------------- 【复核 R9】没有 rich 节点的真实附件气泡
Check 'extractor-keeps-an-image-bubble-without-a-rich-node' ($extracted.imageWithoutRichRetained)

# ---------------------------------------------------------------- 【复核 R10】明确结构优先于显示名/翻译标记
Check 'extractor-explicit-right-beats-the-name-field' ($extracted.explicitRightBeatsName)
Check 'extractor-explicit-right-beats-the-translation-marker' ($extracted.explicitRightBeatsTranslation)
Check 'extractor-translated-row-keeps-the-sent-body' ($extracted.translatedBodyStable)
Check 'extractor-records-a-direction-conflict-without-guessing' ($extracted.directionConflictRecorded)
# 共享抽取行 -> 共享事件 -> 共享四态判定 -> 发送闸门：方向冲突不得变成买家问题或出站证明
$strictLines = @($extracted.strictMsgs -split $lf)
$strictEvents = @(Get-ConversationEventIndex $strictLines)
$conflictEv = @($strictEvents | Where-Object { $_.DirectionSource -eq 'conflict' })
Check 'direction-conflict-survives-into-the-event-model' (@($conflictEv).Count -eq 1 -and $conflictEv[0].Direction -eq 'unknown' -and (-not $conflictEv[0].IsBuyer))
Check 'direction-conflict-has-no-usable-event-identity' (-not (Test-MessageEventIdentityUsable $conflictEv[0]))
Check 'direction-conflict-is-neither-buyer-nor-project' ((Resolve-MessageSourceClass -Event $conflictEv[0] -Rules $emptyRules).Class -eq 'unknown')
$rightNameEv = @($strictEvents | Where-Object { $_.Text -eq 'Your cartons are booked for Friday pickup.' -and $_.DirectionSource -eq 'layout' })
Check 'explicit-right-row-keeps-a-usable-outbound-identity' (@($rightNameEv | Where-Object { $_.Direction -eq 'out' -and (Test-MessageEventIdentityUsable $_) }).Count -eq 2)
$strictGate = Get-MessageSourceGate -Lines $strictLines -Rules $emptyRules
Check 'direction-conflict-holds-the-send-gate' ($strictGate.Action -eq 'SKIP' -and $strictGate.Reason -eq 'unknown-me-tail' -and $strictGate.LastMeSource -eq 'unknown')

Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
