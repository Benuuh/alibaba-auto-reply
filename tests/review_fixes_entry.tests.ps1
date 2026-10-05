# tests\review_fixes_entry.tests.ps1 - 真实 monitor 入口的隔离回归（A2 / A3 / A4 / A5 / T1 / T2）
#
# 分层：isolated。scripts\monitor.ps1 **从不被 dot-source**（那会执行它的主分发）；其函数由 AST 抽取
#   后在隔离运行根（临时目录 + .aar-isolation.json 标记）里重新定义，所有外部 IO 都是桩：
#   页面读取、模型、发送适配器、通知、时钟、锁。被修的判据本身（来源识别、暂停更新、任务持久化、
#   合规检查、报价判据、账本门禁）全部是**生产实现**，不是桩。
#
# 覆盖：
#   E-A2a 可信人工回复 -> 买家补充消息：暂停生效，本轮不发送（旧编排 PauseUpdates=0 / Sends=1）
#   E-A2b 12:00 人工 / 12:01 买家 / 12:04:59 不发送；12:05:00 之后门禁通过才可发送
#   E-A2c 12:03 新人工回复把截止推到 12:08；同一条重扫不延长
#   E-A2d 程序重新加载（重新读盘）不提前解除暂停
#   E-A2e 生成期间出现新的人工回复 => 旧草稿丢弃
#   E-A2f 未知来源新我方消息 => source_unknown_hold；买家补充消息不能解除
#   E-A2g 已确认机器人消息（发送记录）不触发人工暂停
#   E-A2h 暂停状态读取失败 => fail-closed，不发送
#   E-A3a 供应商联系场景：**生成前**任务已存在且为 pending_human，含真实联系方式与来源
#   E-A3b 无联系方式时落盘 awaiting_contact；补充联系人后更新同一条任务
#   E-A3c 任务写入失败 => 不承诺联系（措辞被拦）
#   E-A3d 通知失败 => 任务保留、NotificationDelivered=false、不谎称已通知
#   E-A3e 发送失败 / UNKNOWN 不删除已经成立的供应商核实任务
#   E-A3f 重复扫描不增生任务；换供应商不误合并
#   E-A4a 缺件数的买家不触发报价提醒（真实 monitor 发送后的提醒桩）
#   E-A4b 补充件数后触发一次；人工接管名单仍被排除
#   E-A5a 15 字节损坏账本 => Sends=0，账本与备份字节不变
#   E-A5b 合法空账本 => 可发送；空白/零字节 => 不发送
#   E-A5c 生成期间账本损坏 => 不发送
#   E-A5d 缺失主文件 + 有效备份 => 恢复并继续
#   E-T1/T2 时间问答经真实入口：T1 不以卖家时间到达发送桩；T2 中国时间正常发送且账本只在 SENT_OK 后推进
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

Write-Output '== review_fixes entry tests (real monitor entry, isolated) =='

$isoRoot = Join-Path $env:TEMP ('aar-reviewfix-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
Check 'E0-runtime-is-isolated' (Test-AarIsolatedRuntime) 'isolation marker missing'

. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\human_pause.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')
. (Join-Path $scripts 'lib\goods.ps1')
. (Join-Path $scripts 'lib\quote.ps1')

# ---- 真实入口函数（AST 抽取；monitor.ps1 不被执行） ----
$tk = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tk, [ref]$errs)
if ($errs.Count) { throw 'monitor.ps1 failed to parse' }
$entryFns = @(
    'Invoke-ConvoItem', 'Invoke-ScanRound', 'Update-PendingSeen', 'Generate-Reply-LLM', 'Set-StateHash',
    'Test-RepliedStateUsable', 'Get-RepliedStateFileSize', 'Get-RepliedState', 'Repair-RepliedState',
    'Get-LedgerHealth', 'Reset-LedgerHealthCache', 'Get-CachedDocumentRead', 'Test-LedgerShape',
    'Get-ReplyEntryCount', 'Test-LedgerFirstInitAllowed', 'Get-TaskContextForConvo', 'Add-LedgerReadLog'
)
foreach ($fnName in $entryFns) {
    $fnAst = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    if (-not $fnAst) { throw ('monitor.ps1 does not define ' + $fnName) }
    Invoke-Expression $fnAst.Extent.Text
}
$bogus = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'InvokeConvoItemThatDoesNotExist' }, $true)
Check 'E0-ast-reverse-check' ($null -eq $bogus) ''
Check 'E0-real-entry-extracted' ([bool](Get-Command Invoke-ConvoItem -ErrorAction SilentlyContinue)) ''

# ---- 注入时钟（12:00 本地 = 04:00 UTC；卖家 Asia/Shanghai => 12:00 北京时间） ----
# ---- 夹具时钟（2026-10-05 八项补修：时间口径修正） ----------------------------------------
#   $script:now    = 卖家所在时区的墙上时钟（Get-Date 桩、日志与冷却用）
#   $script:nowUtc = 同一时刻的 UTC 绝对时刻（暂停/等待/时间问答的**唯一**计时口径）
#   两者必须一起推进：只改 $script:now 会让暂停链按旧的 UTC 时刻判断，验收结论失真。
function Get-HumanPauseNowUtc { return $script:nowUtc }
function Set-FixNow([string]$LocalIso) {
    $script:now = [datetime]$LocalIso
    $script:nowUtc = [datetime]::SpecifyKind(([datetime]$LocalIso).AddHours(-8), [DateTimeKind]::Utc)
}
Set-FixNow '2026-10-05T12:00:00'
function Get-Date { param([string]$Format) if ($Format) { return $script:now.ToString($Format) }; return $script:now }
function Get-ReplyClockUtc { return $script:nowUtc }
# 暂停链的单一时钟入口（human_pause.ps1::Get-HumanPauseNow）：注入时钟必须同时覆盖它，
#   否则 [datetime]::Now 这种 .NET 静态调用会绕过注入时钟，验收结论会按真实墙钟得出。
function Get-HumanPauseNow { return $script:now }

$script:dataDir = Join-Path $isoRoot 'data'
New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null
$logFile = $null
$script:replyMinGapMin = 5; $script:replyPostSendCooldownMin = 5
$script:replyNewMsgFloorSec = 20; $script:requiredSeenRounds = 2; $script:replyRoundBudgetSec = 180
$script:accioFlags = @{ shadow = $false; read = $false }
$script:notifyChannelVerified = $false
$script:roundHalt = $false
$P_FULL = '{"seller_profile":{"company_name_en":"Example Freight","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$full = Get-SellerProfile -Config ($P_FULL | ConvertFrom-Json)
$script:sellerProfile = $full
$script:actionEvidence = New-ActionEvidence -Values $null
$script:banSafeFallback = "Thanks - I can't confirm this from here."
$script:lockHoldStart = $script:now
# 扫描轮（Invoke-ScanRound）会用到的运行态字段：显式初始化，避免读到上一个用例的残留。
$script:lastReload = $script:now
$script:emptyStreak = 0
$script:pageDownStreak = 0
$script:pageHealFails = 0
$script:pageName = 'Virtual Buyer'
$script:sendResult = 'SENT_OK'
$script:modelReply = 'Happy to help with the rate - could you share the carton sizes and the delivery weight?'
$script:logs = @()
$script:sends = 0
$script:sentText = ''
$script:notifications = 0
$script:notifyResult = 'SENT_OK'
$script:reads = 0
$script:ledgerWrites = 0
$script:taskStoreFail = $false
$script:notificationDelivered = $false
$script:humanTaskCalls = 0
$script:injectLedgerCorruptDuringGeneration = $false
$script:ledgerCorrupt = $false
$script:ledgerMissing = $false
$script:quoteReminderCalls = 0
$script:quoteReminderNotices = @()

function Write-Log($text) { $script:logs += [string]$text }
function Write-LocalAlert { }
function Clear-LocalAlert { }
function Send-WecomMessage($text) { $script:notifications++; $script:quoteReminderNotices += [string]$text; return $script:notifyResult }
function Send-NewInquiryAlert { $script:notifications++ }
function Add-Content { param($Path, $Value, $Encoding) }
function Get-AppLock { param([string]$name, [int]$timeoutSec = 10) return $true }
function Release-AppLock { param([string]$name) return $true }
function Test-NoReplyBuyer { return [bool]$script:manual }
function Save-BuyerProfile { }
function Remove-PendingRetry { }
function Add-PendingRetry { param($key, $reason) }
function Read-RetryTable { return @{ items = @{} } }
function Start-LlmRound { return @{ sw = [Diagnostics.Stopwatch]::StartNew() } }
function Stop-LlmRound { }
function Get-LlmRoundElapsedSec { return 0 }
function Get-LlmRoundRemainingSec { return 180 }
function Test-LlmRoundBudgetExceeded { return $false }
function Get-ReplyPromptPath { return (Join-Path $scripts 'reply_agent_prompt.md') }
function Get-ReplyScenarioPath { return (Join-Path $scripts 'reply_scenarios.md') }
function Get-Rules { return $null }
# [F4 §6.1 第 3 条] 记录模型**实际收到**的上下文（观察，不是桩）：验收要断言证据真的进了模型输入。
#   第一次模型调用时同时记录隔离运行根里**真实落盘**的未完成任务数，用来证明任务在生成之前就落盘了。
function Invoke-LLM {
    param($Messages, $Temperature, $MaxTokens, $LogFile)
    $script:modelCalls++
    try { $script:modelInput = [string]($Messages | ConvertTo-Json -Depth 20) } catch { $script:modelInput = '' }
    if ($script:modelCalls -eq 1) {
        try { $script:taskCountAtModelCall = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count } catch { $script:taskCountAtModelCall = -1 }
    }
    return $script:modelReply
}
function Remove-AttachmentMarkers { param([string]$text) return $text }
function Get-ImageDataUrl { return $null }
function Get-DocumentBase64ViaCdp { return $null }
function Get-DocumentBase64ViaHttp { return $null }
function Get-AccioReplyLines { return @() }
function Test-AccioLinesOverlap { return $true }
function Invoke-CdpEval { throw 'Browser access forbidden in these tests' }
function Start-Sleep { param([int]$Seconds = 1, [int]$Milliseconds = 0) }
# 运行态边界：路径解析走真实接口（隔离模式下只可能落在临时根内）。
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{} }
function Add-SentRecord { param([string]$Buyer, [string]$Text, [string]$SentAt = '', [string]$Source = '') return $true }
# 供应商计划措辞的证据必须来自**真实落盘任务**：Get-ActionEvidenceForBuyer 故意不桩化，
# 它读的是隔离运行根里的 human_tasks.json。
# 通知投递是外部出口（桩）；"任务里记了几次尝试、成功与否"由真实的 human_tasks 记录承担。
$script:notificationAttempts = 0
function Add-HumanTaskNotification { param([Parameter(Mandatory = $true)][string]$Id, [bool]$Delivered = $false, [string]$Detail = '')
    $script:notificationAttempts++
    $script:notificationDelivered = [bool]$Delivered
    return $true
}

# 发送适配器：最外层桩。它同时记录'买家会收到什么'与调用次数。
function Send-OneTalkMessageEx {
    param($buyer, $text, $Page = $null, [switch]$AlreadyOpen, [switch]$SkipConfirmation)
    $script:sends++
    $script:sentText = [string]$text
    $status = [string]$script:sendResult
    $confirmed = ($status -eq 'SENT_OK')
    $receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before @() -After @([pscustomobject]@{MessageId=('fixture-send-'+[guid]::NewGuid().ToString('N'));MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$text;IsMine=$true})
    return [pscustomobject]@{ Status = $status; Raw = $status; Buyer = $buyer; Text = $text; Confirmed = $confirmed; Receipt=$receipt; ConfirmEvidence = 'stub'; Detail = '' }
}
function Resolve-UnknownSendResult { param([string]$key, [string]$text) return [pscustomobject]@{ Status = 'unverified'; Detail = 'stub' } }
function Test-PendingReplyObsolete { param([string]$key) return $false }
function Get-AccioReplyLines2 { }

# 引号：报价提醒的触发只允许在 SENT_OK 之后。原函数保持真实实现（读隔离快照目录）。
function Get-QuoteReminderProbe { return $script:quoteReminderCalls }

$item = [pscustomobject]@{ name = 'Virtual Buyer'; preview = 'unchanged'; unread = $true }
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
$LF = [string][char]10
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
function HumanLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@MT:' + $ts) }

function Reset([string]$raw = '') {
    $script:logs = @(); $script:sends = 0; $script:modelCalls = 0; $script:reads = 0
    $script:modelInput = ''; $script:taskCountAtModelCall = -1
    $script:ledgerWrites = 0; $script:notifications = 0; $script:humanTaskCalls = 0
    $script:roundHalt = $false; $script:manual = $false; $script:sendResult = 'SENT_OK'
    $script:sentText = ''; $script:raw = $raw; $script:pageName = 'Virtual Buyer'
    $script:ledgerCorrupt = $false; $script:ledgerMissing = $false; $script:notifyResult = 'SENT_OK'
    $script:quoteReminderCalls = 0; $script:quoteReminderNotices = @()
    # 账本是一个**真实文件**：每个用例都从一个合法的空账本开始（那才是"还没有回复历史"的
    # 合法状态）。A5 自己管理账本形态，因此那一组把 seedLedger 关掉。
    if ($script:seedLedger) { [System.IO.File]::WriteAllText($script:stateFile, '{"replied":{}}', (New-Object System.Text.UTF8Encoding($false))) }
    Reset-LedgerHealthCache
    $script:taskStoreFail = $false; $script:notificationDelivered = $false; $script:notificationAttempts = 0
    # 冷却/待回复状态是跨用例的持久面：每个用例都要从干净状态开始，否则上一个用例的
    #   发送后冷却会把下一个用例挡在 TEMP-SKIP（那是真实行为，但不是本用例要验的东西）。
    $script:now = $script:now
    $ctx = @{ state = $null; lastSendAt = @{}; skipCooldown = @{}; openCooldown = @{}; noReplyPreview = @{}
              humanPending = @{}; sendFailCount = @{}; failAlertAt = @{}; pendingSeen = @{}; dupGuardHolds = @{}
              sourceUnknownMarks = @{}; lastActivity = $script:now }
    Update-PendingSeen $ctx @($item); Update-PendingSeen $ctx @($item)
    return $ctx
}
function Open-ConvoAndGetMessages($name) { $script:reads++; return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' } }

# 账本链保持**真实实现**（Get-LedgerHealth / Test-RepliedStateUsable / Get-RepliedState 全部来自
#   AST 抽取的 monitor.ps1），只把"写盘"这一层换成计数器：用例直接写真实的账本文件来驱动状态。
#   这样 A5 验的是生产判据本身，而不是一个桩。
$script:stateFile = Join-Path $isoRoot 'state.json'
$script:seedLedger = $true
function Set-RepliedState($state) { $script:ledgerWrites++; return $true }
function Repair-RepliedState { return $false }

function Seen($ctx) { Update-PendingSeen $ctx @($item) }
# 真实入口要求「在待回复列表中连续出现 2 轮」才进入发送分支；夹具里显式补足这一条件，
#   否则用例停在 PENDING-CONFIRM-WAIT，测不到本项要验的暂停/任务/账本行为。
# ---- 扫描轮入口（Invoke-ScanRound）的外部边界：页面存在性/健康、锁、快照 ----
#   本项要验的是**账本门禁**在真实编排里的位置与结论，页面与恢复动作都是外部出口，用桩替换。
$script:pagePresent = $true
$script:pageDown = $false
function Test-OneTalkPagePresent { return [bool]$script:pagePresent }
function Test-PageHealth { return [pscustomobject]@{ PageDown = [bool]$script:pageDown; Reason = 'stub'; Items = 1; Spinner = 0; Tab = 'pending'; Tip = '' } }
function Invoke-PageHealFromGate { }
function Invoke-CdpSelfHeal { }
function Get-PageHealAction { return 'none' }
function Invoke-PageReload { }
function Get-Snapshot { return ('[{"name":"Virtual Buyer","preview":"unchanged"}]') }
function MarkSeen($ctx, [int]$Times = 2) { for ($i = 0; $i -lt $Times; $i++) { Seen $ctx } }
# 每个用例从干净的暂停/等待状态开始（这些状态是持久化的，会跨用例留存）。
function Clear-PauseState {
    [void](Clear-HumanPause 'Virtual Buyer')
    [void](Clear-SourceUnknownHold 'Virtual Buyer')
}
# 人工任务表同样是持久化状态：本文件的用例各自独立，进入新的一组前显式清空，
#   免得上一组留下的任务（例如"物流状态"）被本组的断言读到。
function Clear-TaskState {
    $f = Get-HumanTaskFile
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $bak = $f + '.bak'
    if (Test-Path $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
}
# ============================================================================================
# A2 - 人工五分钟让路（真实入口 + 发送桩）
# ============================================================================================
# 基线复现的形态：会话末尾是「可信人工回复 -> 新买家消息」。旧编排只在闸门 SKIP 时更新暂停，
#   于是 PauseUpdates=0 且 Sends=1；现在进入会话时先扫描整段快照并检查持久化暂停。
# @@MT 是 UTC 毫秒，必须是可解析的真实时刻（夹具用 2030-01-01 前后的值）。
$ts0 = [long]1791172800000
Set-FixNow '2026-10-05T12:00:00'
Clear-PauseState
$ctx = Reset (HumanLine 'I will take this one myself' $ts0)
$script:raw += [string][char]10 + (BLine 'Any update on my quote?' ($ts0 + 1000))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2a-no-send-when-human-then-buyer' $script:sends 0
Check 'E-A2a-pause-recorded' ($null -ne (Get-HumanPause 'Virtual Buyer')) ''
$pauseA = Test-HumanPauseActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc
Check 'E-A2a-pause-active' ([bool]$pauseA.Active) ('reason=' + $pauseA.Reason)
Eq 'E-A2a-pause-until-is-reply-plus-5' (ConvertTo-HumanPauseUtc $pauseA.Until) $script:nowUtc.AddMinutes(5)
Check 'E-A2a-skip-logged' ([bool](($script:logs -join [string][char]10) -match 'HUMAN-PAUSE-ACTIVE-SKIP')) ''

# 12:04:59 仍在窗口内 => 不发送；12:05:00 之后到期 => 正常门禁重新生效。
Set-FixNow '2026-10-05T12:04:59'
$ctx = Reset (HumanLine 'I will take this one myself' $ts0)
$script:raw += [string][char]10 + (BLine 'Any update on my quote?' ($ts0 + 1000))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2b-1249-no-send' $script:sends 0
Set-FixNow '2026-10-05T12:05:01'
$ctx = Reset (HumanLine 'I will take this one myself' $ts0)
$script:raw += [string][char]10 + (BLine 'Any update on my quote?' ($ts0 + 1000))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2b-after-expiry-gate-allows-send' $script:sends 1

# 12:03 的新人工回复把截止推到 12:08；同一条消息重扫不延长。
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset ((HumanLine 'first human answer' $ts0) + [string][char]10 + (BLine 'any update?' ($ts0 + 1000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$untilFirst = (Test-HumanPauseActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Until
Check 'E-A2c-first-window' (-not [bool]$script:sends -and $null -ne $untilFirst) ('until=' + $untilFirst)
Set-FixNow '2026-10-05T12:03:00'
$ctx = Reset ((HumanLine 'first human answer' $ts0) + [string][char]10 + (HumanLine 'second human answer' ($ts0 + 180000)) + [string][char]10 + (BLine 'any update?' ($ts0 + 181000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$untilSecond = (Test-HumanPauseActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Until
Eq 'E-A2c-new-human-reply-extends' (ConvertTo-HumanPauseUtc $untilSecond) $script:nowUtc.AddMinutes(5)
Set-FixNow '2026-10-05T12:04:00'
$ctx = Reset ((HumanLine 'first human answer' $ts0) + [string][char]10 + (HumanLine 'second human answer' ($ts0 + 180000)) + [string][char]10 + (BLine 'any update?' ($ts0 + 181000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$untilAgain = (Test-HumanPauseActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Until
Eq 'E-A2c-rescan-does-not-extend' (ConvertTo-HumanPauseUtc $untilAgain) (ConvertTo-HumanPauseUtc $untilSecond)

# 重新读盘（模拟程序重启）不提前解除、也不重新计时。
$reload = Get-HumanPause 'Virtual Buyer'
Eq 'E-A2d-pause-survives-reload' (ConvertTo-HumanPauseUtc $reload.untilUtc) (ConvertTo-HumanPauseUtc $untilSecond)
# 买家连续多条消息也不延长人工暂停（暂停只按人工回复计时）。
$ctx = Reset ((HumanLine 'second human answer' ($ts0 + 180000)) + [string][char]10 + (BLine 'and one more thing' ($ts0 + 200000)) + [string][char]10 + (BLine 'also this' ($ts0 + 220000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2d-buyer-messages-do-not-extend' (ConvertTo-HumanPauseUtc (Get-HumanPause 'Virtual Buyer').untilUtc) (ConvertTo-HumanPauseUtc $untilSecond)
Eq 'E-A2d-buyer-messages-do-not-send' $script:sends 0

# 生成期间出现新的人工回复 => 旧草稿丢弃。
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$script:raw2 = ''
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    if ($script:reads -ge 2 -and $script:raw2) { return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw2; profile = '' } }
    return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' }
}
$script:raw2 = (BLine 'Can you quote 10 cartons to Hamburg?' $ts0) + [string][char]10 + (HumanLine 'hold on, I will answer this one' ($ts0 + 30000))
Invoke-ConvoItem $ctx $item
Eq 'E-A2e-mid-generation-human-discards-draft' $script:sends 0
Check 'E-A2e-stale-logged' ([bool](($script:logs -join [string][char]10) -match 'STALE-DRAFT-DISCARD')) ($script:logs -join ' | ')
function Open-ConvoAndGetMessages($name) { $script:reads++; return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' } }

# 未知来源的我方**新**消息 => 独立、持久化、去重的等待窗口；买家补充消息不能立即解除。
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$baseLines = (BLine 'hello' $ts0) + [string][char]10 + (BLine 'are you there?' ($ts0 + 1000))
# 首次加载：整段历史里没有来源不明的我方消息 => 不产生任何等待状态。
$ctx = Reset $baseLines
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-A2f-first-load-creates-no-hold' ($null -eq (Get-SourceUnknownHold 'Virtual Buyer')) ''
# 之后扫描时**新出现**一条只有时间戳的我方消息（页面抽到但没有发送者证据）：
#   既不当作机器人（不发送），也不当作人工（不开始暂停），而是开启独立等待窗口。
# 显式构造"只有时间戳、没有逐条发送标记"的我方消息：剔除 @@TS（机器人标记）但保留 @@MT（时间）。
# 页面抽取给我方行加了时间戳却没有可验证的发送者来源：这一行是 unknown
#   （既不当作机器人，也不当作人工）。页面形态 = 带 @@TS/@@MT 时间戳，但**不在**本系统已确认发送记录里。
$unknownTail = '[ME] we replied but the page gave no sender @@TS:' + ($ts0 + 2000) + ' @@MT:' + ($ts0 + 2000)
# 第二次扫描：快照里**新出现**一条无法证明来源的我方消息。水位线表示"这一个下标之前的
#   未知我方消息都是已经登记过的历史"，因此下标 2 是这一轮新出现的介入。
$ctx = Reset ($baseLines + [string][char]10 + $unknownTail)
$ctx.sourceUnknownMarks['Virtual Buyer'] = 1
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$hold = Get-SourceUnknownHold 'Virtual Buyer'
Check 'E-A2f-new-unknown-creates-hold' ($null -ne $hold) ($script:logs -join ' | ')
Check 'E-A2f-unknown-does-not-start-human-pause' ($null -eq (Get-HumanPause 'Virtual Buyer')) ''
Eq 'E-A2f-hold-is-five-minutes' (ConvertTo-HumanPauseUtc $hold.untilUtc) $script:nowUtc.AddSeconds(2).AddMinutes(5)
# 买家随后补充消息**不能**立即解除等待。
Set-FixNow '2026-10-05T12:01:00'
$ctx = Reset ($baseLines + [string][char]10 + $unknownTail + [string][char]10 + (BLine 'and now?' ($ts0 + 3000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2f-buyer-supplement-does-not-send' $script:sends 0
Check 'E-A2f-hold-still-active' ([bool](Test-SourceUnknownHoldActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Active) ''
Eq 'E-A2f-hold-until-unchanged' (ConvertTo-HumanPauseUtc (Get-SourceUnknownHold 'Virtual Buyer').untilUtc) (ConvertTo-HumanPauseUtc $hold.untilUtc)
# 同一条未知消息重扫不延长。
$ctx = Reset ($baseLines + [string][char]10 + $unknownTail + [string][char]10 + (BLine 'and now?' ($ts0 + 3000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A2f-rescan-does-not-extend-hold' (ConvertTo-HumanPauseUtc (Get-SourceUnknownHold 'Virtual Buyer').untilUtc) (ConvertTo-HumanPauseUtc $hold.untilUtc)
# 到期后等待自动失效（只解除临时等待，不主动发问候）。
Set-FixNow '2026-10-05T12:06:00'
Check 'E-A2f-hold-expires' (-not [bool](Test-SourceUnknownHoldActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Active) ''

# 已确认机器人消息（发送记录命中）不触发人工暂停。
Clear-PauseState
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) $m = @{}; for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match '^\[ME\]') { $m[$i] = $true } }; return $m }
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset ((BLine 'hello' $ts0) + [string][char]10 + (MeLine 'our own bot answer' ($ts0 + 1000)) + [string][char]10 + (BLine 'still there?' ($ts0 + 2000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-A2g-confirmed-bot-does-not-pause' ($null -eq (Get-HumanPause 'Virtual Buyer')) ''
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{} }

# 暂停状态读取失败 => fail-closed（不发送）。
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset ((HumanLine 'human answered first' $ts0) + [string][char]10 + (BLine 'any update?' ($ts0 + 1000)))
MarkSeen $ctx
$pauseBody = (Get-Command Test-HumanPauseActive).ScriptBlock
function Test-HumanPauseActive { param([string]$Buyer, $Now = $null, $NowUtc = $null) throw 'pause store unreadable' }
Invoke-ConvoItem $ctx $item
Eq 'E-A2h-pause-read-failure-blocks-send' $script:sends 0
Set-Item Function:Test-HumanPauseActive $pauseBody
Check 'E-A2h-failure-logged' ([bool](($script:logs -join [string][char]10) -match 'HUMAN-PAUSE-ERR')) ''
# A3 - 供应商任务在**生成之前**落盘，含真实联系方式与来源
# ============================================================================================
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$a3Convo = (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
$ctx = Reset $a3Convo
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$tasksA3 = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-A3a-task-exists' $tasksA3.Count 1
Eq 'E-A3a-task-kind' ([string]$tasksA3[0].kind) 'supplier_verification'
Eq 'E-A3a-task-status-pending-human' ([string]$tasksA3[0].status) 'pending_human'
Eq 'E-A3a-real-contact-not-placeholder' ([string]$tasksA3[0].supplierContact) 'supplier@example.invalid'
Check 'E-A3a-contact-source-recorded' ([string]$tasksA3[0].supplierContactSource -match 'supplier_contact') ([string]$tasksA3[0].supplierContactSource)
Check 'E-A3a-supplier-key-from-contact' ([string]$tasksA3[0].supplierKey -match 'example\.invalid') ([string]$tasksA3[0].supplierKey)
Check 'E-A3a-trigger-message-kept' ([string]$tasksA3[0].lastTriggerMessage -match "supplier's contact") ([string]$tasksA3[0].lastTriggerMessage)
Check 'E-A3a-missing-fields-kept' ((@($tasksA3[0].missingFields)).Count -gt 0) ('missing=' + (@($tasksA3[0].missingFields) -join ','))
Check 'E-A3a-facts-snapshot-kept' ($null -ne $tasksA3[0].factsSnapshot) ''
Eq 'E-A3a-send-happened' $script:sends 1
Check 'E-A3a-plan-not-degraded' (-not ([string]$script:sentText -match '(?i)share the (carton sizes|dimensions)')) ([string]$script:sentText)
Check 'E-A3a-no-placeholder-in-text' (-not ([string]$script:sentText -match 'supplier-contact-provided')) ([string]$script:sentText)

# 无联系方式 => awaiting_contact；补充联系人后更新同一条任务，不增生。
Set-FixNow '2026-10-05T12:00:00'
Clear-TaskState
$ctx = Reset (BLine "I don't know the dimensions and I cannot measure the cartons." $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$tAsk = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-A3b-awaiting-contact-created' ([string]$tAsk[0].status) 'awaiting_contact'
Eq 'E-A3b-no-contact-stored' ([string]$tAsk[0].supplierContact) ''
$idAsk = [string]$tAsk[0].id
$ctx = Reset ((BLine "I don't know the dimensions and I cannot measure the cartons." $ts0) + [string][char]10 + (BLine 'My supplier is Delta Components, contact supplier@example.invalid' ($ts0 + 60000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$tAsk2 = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-A3b-single-task-after-contact' $tAsk2.Count 1
Eq 'E-A3b-same-task-updated' ([string]$tAsk2[0].id) $idAsk
Eq 'E-A3b-status-advanced' ([string]$tAsk2[0].status) 'pending_human'
Eq 'E-A3b-contact-stored' ([string]$tAsk2[0].supplierContact) 'supplier@example.invalid'

# 任务写入失败 => 不得承诺联系。
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
$origTaskFn = (Get-Command New-OrUpdate-SupplierVerificationTask).ScriptBlock
function New-OrUpdate-SupplierVerificationTask {
    param([Parameter(Mandatory = $true)][string]$Buyer, [string[]]$MissingFields = @(), [string]$SupplierContact = '', [string]$TriggerMessage = '', $FactsSnapshot = $null, [string]$SupplierName = '', [string]$TriggerMessageId = '', [string]$TriggerAt = '', [string]$Source = '', [string]$Note = '')
    return [pscustomobject]@{ Task = [pscustomobject]@{ id = 'failed-task'; status = 'pending_human'; supplierKey = 'k' }; Created = $false; Updated = $true; StoreOk = $false }
}
Invoke-ConvoItem $ctx $item
Check 'E-A3c-store-failure-logged' ([bool](($script:logs -join [string][char]10) -match 'HUMAN-TASK-STORE-FAIL')) ''
Check 'E-A3c-no-contact-promise-without-task' (-not ([string]$script:sentText -match '(?i)we(.|\n){0,20}(contact|check with|verify with)\b.{0,20}supplier')) ([string]$script:sentText)
Set-Item Function:New-OrUpdate-SupplierVerificationTask $origTaskFn

# 通知失败 => 任务保留、NotificationDelivered=false，不谎称人工已收到。
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
$script:notifyResult = 'FAILED'
Invoke-ConvoItem $ctx $item
$tNotify = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-A3d-task-kept-after-notify-failure' $tNotify.Count 1
Check 'E-A3d-notification-not-delivered' (-not [bool]$tNotify[0].notification.delivered) ''
Eq 'E-A3d-notification-attempted' $script:notificationAttempts 1
$script:notifyResult = 'SENT_OK'

# 发送失败/UNKNOWN 不删除已经成立的供应商核实任务。
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
$script:sendResult = 'FAILED'
Invoke-ConvoItem $ctx $item
Eq 'E-A3e-failed-send-keeps-task' (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) 1
$ctx = Reset ((BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0) + [string][char]10 + (BLine "didn't get a reply yet" ($ts0 + 60000)))
MarkSeen $ctx
$script:sendResult = 'UNKNOWN'
Invoke-ConvoItem $ctx $item
Check 'E-A3e-unknown-send-keeps-task' ((@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) -ge 1) ''
$script:sendResult = 'SENT_OK'

# 重复扫描不增生任务；不同供应商各自独立。
Set-FixNow '2026-10-05T12:00:00'
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Invoke-ConvoItem $ctx $item
Invoke-ConvoItem $ctx $item
Eq 'E-A3f-repeat-scan-no-duplicate-task' (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) 1
$tkOther = New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'other@example.net' -TriggerMessage 'Please use this other supplier for this shipment.'
Eq 'E-A3f-other-supplier-is-separate' (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) 2
Check 'E-A3f-other-supplier-different-key' ([string]$tkOther.Task.supplierKey -ne [string](@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)[0]).supplierKey) ''
# ============================================================================================
# A4 - 报价提醒经真实 monitor 的提醒桩
# ============================================================================================
function Save-SnapshotFor([string]$buyer, [string[]]$lines, [string]$name) {
    $p = Join-Path $script:dataDir $name
    [System.IO.File]::WriteAllText($p, (@(('# BUYER: ' + $buyer)) + $lines) -join [string][char]10, (New-Object System.Text.UTF8Encoding($false)))
}
function Clear-QuoteReminderState {
    $f = Join-Path $isoRoot 'remind_state.json'
    if (Test-Path $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}
Clear-PauseState
Clear-TaskState
Clear-QuoteReminderState
Set-FixNow '2026-10-05T12:00:00'
# 页面上只有『总毛重 200 kg / 每箱 50x40x30 cm / DDP 到 Amazon FTW1』，没有箱数：
#   统一判据（Get-QuoteReadiness）判 MissingFields=carton_count ⇒ 不进候选名单，因此**不发**报价提醒。
Save-SnapshotFor 'Virtual Buyer' @((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0)) 'msgs_a4_0001.txt'
$ctx = Reset (BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A4a-send-happened' $script:sends 1
Eq 'E-A4a-no-quote-reminder-without-carton-count' (@($script:quoteReminderNotices | Where-Object { $_ -match '报价提醒' }).Count) 0
Check 'E-A4a-no-ready-claim-logged' (-not (($script:logs -join [string][char]10) -match 'QUOTE-REMIND: pushed')) ''

# 补充件数后：候选名单包含他，真实发送后的提醒桩收到**一条**提醒；同一内容 24h 内不再推。
Set-FixNow '2026-10-05T12:10:00'
Save-SnapshotFor 'Virtual Buyer' @((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0), (BLine 'Actually there are 10 cartons' ($ts0 + 60000))) 'msgs_a4_0002.txt'
Clear-QuoteReminderState
$script:quoteReminderNotices = @()
$ctx = Reset ((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0) + [string][char]10 + (BLine 'Actually there are 10 cartons' ($ts0 + 60000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A4b-send-happened' $script:sends 1

Eq 'E-A4b-one-quote-reminder' (@($script:quoteReminderNotices | Where-Object { $_ -match '报价提醒' }).Count) 1
Check 'E-A4b-reminder-names-destination' ([bool]((@($script:quoteReminderNotices | Where-Object { $_ -match '报价提醒' }) -join ' ') -match 'Amazon FTW1')) ''
Check 'E-A4b-reminder-triggered-after-sent-ok' ([bool](($script:logs -join [string][char]10) -match 'ROUND-SEND .* status=SENT_OK')) ''

# 同一内容再次触发：24h 去重，零新增提醒。
Set-FixNow '2026-10-05T12:20:00'
$script:quoteReminderNotices = @()
$ctx = Reset ((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0) + [string][char]10 + (BLine 'Actually there are 10 cartons' ($ts0 + 60000)) + [string][char]10 + (BLine 'any update?' ($ts0 + 120000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A4b-send-happened-3' $script:sends 1
Eq 'E-A4b-reminder-deduped-no-new' (@($script:quoteReminderNotices | Where-Object { $_ -match '报价提醒' }).Count) 0

# 人工接管名单仍然排除报价候选（且不发提醒）。
$script:manual = $true
Set-FixNow '2026-10-05T13:00:00'
$script:quoteReminderNotices = @()
$ctx = Reset ((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $ts0) + [string][char]10 + (BLine 'Actually there are 10 cartons' ($ts0 + 60000)) + [string][char]10 + (BLine 'any update?' ($ts0 + 120000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A4b-manual-override-excluded' (@($script:quoteReminderNotices | Where-Object { $_ -match '报价提醒' }).Count) 0
$script:manual = $false
# ============================================================================================
# A5 - 账本状态经真实 monitor 门禁
# ============================================================================================
Clear-PauseState
Clear-TaskState
$script:seedLedger = $false
Set-FixNow '2026-10-05T12:00:00'
# 15 字节损坏账本：不发送，且普通流程不改写账本与备份。
$ledgerPath = Join-Path $isoRoot 'ledger_state.json'
$script:stateFile = $ledgerPath
$bakPath = $ledgerPath + '.bak'
$raw15b = New-Object System.Collections.Generic.List[byte]
foreach ($b in @(0xEF, 0xBB, 0xBF)) { [void]$raw15b.Add([byte]$b) }
foreach ($b in [Text.Encoding]::UTF8.GetBytes('{"replied":{')) { [void]$raw15b.Add([byte]$b) }
[System.IO.File]::WriteAllBytes($ledgerPath, $raw15b.ToArray())
[System.IO.File]::WriteAllText($bakPath, '{"replied":{"seed":"h|1"}}', (New-Object System.Text.UTF8Encoding($false)))
$ledgerBefore = [System.IO.File]::ReadAllBytes($ledgerPath)
$bakBefore = [System.IO.File]::ReadAllBytes($bakPath)
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A5a-corrupt-ledger-no-send' $script:sends 0
Check 'E-A5a-ledger-bytes-unchanged' ([bool](([System.IO.File]::ReadAllBytes($ledgerPath)) -join ',' -eq ($ledgerBefore -join ','))) ''
Check 'E-A5a-backup-bytes-unchanged' ([bool](([System.IO.File]::ReadAllBytes($bakPath)) -join ',' -eq ($bakBefore -join ','))) ''

# ---- 扫描轮门禁（Invoke-ScanRound）：账本不可用时整轮一条都不发 ----
$ctxScan = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
Set-FixNow '2026-10-05T12:00:00'
$bytesBefore = (Get-Item $ledgerPath).Length
$result = Invoke-ScanRound $ctxScan
Eq 'E-A5a-scan-blocks-round' $script:sends 0
Check 'E-A5a-state-unusable-logged' ([bool](($script:logs -join [string][char]10) -match 'STATE-UNUSABLE')) ($script:logs -join ' | ')
Eq 'E-A5a-ledger-bytes-still-15' (Get-Item $ledgerPath).Length $bytesBefore

# 有效空账本时扫描轮正常处理会话（可发送）。
$script:seedLedger = $true
[System.IO.File]::WriteAllText($ledgerPath, '{"replied":{}}', (New-Object System.Text.UTF8Encoding($false)))
Reset-LedgerHealthCache
Set-FixNow '2026-10-05T12:10:00'
$ctxScan = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
# 扫描轮自己会调用 Update-PendingSeen（整表对齐），因此这里只预置一次，扫描轮那一轮补足第二次。
Seen $ctxScan
# 扫描轮的第一个 cycle 只观察（既有冷启动保护），因此跑两轮。
[void](Invoke-ScanRound $ctxScan)
Set-FixNow '2026-10-05T12:11:00'
[void](Invoke-ScanRound $ctxScan)
Eq 'E-A5b-scan-processes-with-valid-empty-ledger' $script:sends 1

# 合法空账本 => 有效，可发送。
[System.IO.File]::WriteAllText($ledgerPath, '{"replied":{}}', (New-Object System.Text.UTF8Encoding($false)))
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A5b-valid-empty-ledger-allows-send' $script:sends 1
Check 'E-A5b-ledger-written' ([bool]($script:ledgerWrites -ge 1)) ('writes=' + $script:ledgerWrites)

# 空白文件 / 零字节 => 不发送（不是'没有账本'）。
$script:seedLedger = $false
Set-FixNow '2026-10-05T12:30:00'
[System.IO.File]::WriteAllText($ledgerPath, '   ', (New-Object System.Text.UTF8Encoding($false)))
Reset-LedgerHealthCache
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A5b-blank-file-no-send' $script:sends 0
Set-FixNow '2026-10-05T12:40:00'
[System.IO.File]::WriteAllBytes($ledgerPath, (New-Object byte[] 0))
Reset-LedgerHealthCache
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A5b-zero-byte-no-send' $script:sends 0

# 生成期间账本损坏 => 不发送（最终检查更新并核验新状态）。
[System.IO.File]::WriteAllText($ledgerPath, '{"replied":{}}', (New-Object System.Text.UTF8Encoding($false)))
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
$script:corruptOnSecondRead = $true
$openBody = (Get-Command Open-ConvoAndGetMessages).ScriptBlock
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    if ($script:reads -ge 2 -and $script:corruptOnSecondRead) {
        [System.IO.File]::WriteAllText($script:stateFile, '{"replied":{', (New-Object System.Text.UTF8Encoding($false)))
    }
    return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' }
}
Invoke-ConvoItem $ctx $item
Eq 'E-A5c-ledger-corrupted-during-generation-no-send' $script:sends 0
Check 'E-A5c-ledger-unusable-at-send-logged' ([bool](($script:logs -join [string][char]10) -match 'SEND-GATE-LEDGER-UNUSABLE')) ''
Set-Item Function:Open-ConvoAndGetMessages $openBody
$script:corruptOnSecondRead = $false

# 主文件缺失 + 有效备份 => 显式恢复并继续。
Set-FixNow '2026-10-05T13:00:00'
Remove-Item -LiteralPath $ledgerPath -Force -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllText($bakPath, '{"replied":{"seed":"h|1"}}', (New-Object System.Text.UTF8Encoding($false)))
Reset-LedgerHealthCache
$script:seedLedger = $false
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
# 恢复动作发生在**读取账本的那一刻**（真实入口的第一次读取）。这里断言的是恢复本身的结果：
#   显式恢复、留痕、主文件重建，并且恢复后账本被判定为可用。
Invoke-ConvoItem $ctx $item
$restored = Get-LedgerHealth
Check 'E-A5d-restore-logged' ([bool](($script:logs -join [string][char]10) -match 'LEDGER-RESTORED-FROM-BACKUP')) (($script:logs | Where-Object { $_ -match 'LEDGER' }) -join ' | ')
Check 'E-A5d-ledger-file-recreated' (Test-Path $ledgerPath) ''
Eq 'E-A5d-restored-source-is-primary' ([string]$restored.Source) 'primary'
Eq 'E-A5d-restored-entry-count' ([int]$restored.Count) 1
Check 'E-A5d-restored-ledger-usable' ([bool](Test-RepliedStateUsable $null).Ok) ('status=' + $restored.Status)
# 恢复后的一轮正常路径：账本可用 ⇒ 会话照常处理并可发送。
Set-FixNow '2026-10-05T13:10:00'
$ctx = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-A5d-restored-ledger-allows-send' $script:sends 1
Check 'E-A5d-restored-state-hash-written' ([bool]($script:ledgerWrites -ge 1)) ('writes=' + $script:ledgerWrites)

# ============================================================================================
# T1 / T2 - 时间问答经真实入口
# ============================================================================================
Clear-PauseState
Clear-TaskState
# T1: 明确地点不能退回卖家时间；解析不了时只澄清地点。
Set-FixNow '2026-10-05T12:00:00'
$script:nowUtc = [datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$ctx = Reset (BLine 'What time is it in hamburg?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-T1-send-happened' $script:sends 1
# 规范 §7.2 第 7 条：允许为 T1 增加可靠的城市映射（本轮加了 Hamburg -> Europe/Berlin）。
# 关键是**绝不能**退回卖家时间；解析不了时才只澄清地点。
Check 'E-T1-no-seller-clock-at-send-stub' (-not ([string]$script:sentText -match 'China|UTC\+8')) ([string]$script:sentText)
Check 'E-T1-answers-the-named-place' ([bool]([string]$script:sentText -match "It's 6:00 AM in hamburg \(UTC\+2\)")) ([string]$script:sentText)
# 另一个未知地名：明确指定但解析不了 => 只澄清地点，不输出任何时刻。
$ctx = Reset (BLine 'What time is it in Atlantis?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-T1-unknown-place-send-happened' $script:sends 1
Check 'E-T1-unknown-place-clarifies-only' ([bool]([string]$script:sentText -match 'Which country or time zone')) ([string]$script:sentText)
Check 'E-T1-unknown-place-no-clock' (-not ([string]$script:sentText -match '\d{1,2}:\d{2}')) ([string]$script:sentText)
Check 'E-T1-ledger-advanced-only-after-send' ([bool]($script:ledgerWrites -ge 1)) ('writes=' + $script:ledgerWrites)

# T2: 后句公司在东京不覆盖时间目标 => 中国时间正常发送。
$ctx = Reset (BLine 'What time is it in China? My company is in Tokyo.' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-T2a-send-happened' $script:sends 1
Check 'E-T2a-china-clock-at-send-stub' ([bool]([string]$script:sentText -match "It's 12:00 PM in China")) ([string]$script:sentText)
Check 'E-T2a-not-japan-clock' (-not ([string]$script:sentText -match 'Japan')) ([string]$script:sentText)

# 未指定地点 => 卖家所在地（不是买家公司的所在地）。
$ctx = Reset (BLine 'What time is it now? My company is in Tokyo.' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-T2b-seller-zone-at-send-stub' ([bool]([string]$script:sentText -match "It's 12:00 PM in China")) ([string]$script:sentText)

# 发送前复核：正确时间前缀 + 模型附加错误时刻 => 发送前检查阻断（回退由同一判据决定）。
$ctx = Reset ((BLine 'What time is it now? I also need a quote for 10 cartons.' $ts0))
MarkSeen $ctx
$script:modelReply = "It's 9:40 AM in China (UTC+8). Happy to help with the rate."
Invoke-ConvoItem $ctx $item
Check 'E-T-final-gate-blocks-wrong-clock-body' (-not ([string]$script:sentText -match '9:40')) ([string]$script:sentText)
$script:modelReply = 'Happy to help with the rate - could you share the carton sizes and the delivery weight?'

Write-Output ''
# 多条未答短消息：不得因为后一条业务位置句而改变时间目标，也不得把两句拼成地名。
$ctx = Reset ((BLine 'What time is it in China?' $ts0) + [string][char]10 + (BLine 'my company is in Tokyo' ($ts0 + 1000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-T2c-multi-message-send-happened' $script:sends 1
Check 'E-T2c-multi-message-keeps-china' ([bool]([string]$script:sentText -match "It's 12:00 PM in China")) ([string]$script:sentText)
Check 'E-T2c-multi-message-not-tokyo' (-not ([string]$script:sentText -match 'Japan')) ([string]$script:sentText)

# ============================================================================================
# 八项补修 F2 / F4 / F6：独立复核探针输入转正式回归（真实 monitor 入口 + 发送桩）
# ============================================================================================
# 说明：这里用的是**实际页面格式** [ME] ... @@TS:... @@MT:...（MeLine），不是测试专有的 human 标记，
#   因此证明的是生产来源路径，而不是夹具自己造的标记。
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'

# ---- F2-a 历史 unknown 建基线；新 unknown + 同一扫描内的买家补充 => 不发送且等待落盘 ----
$f2base = (BLine 'Can you help with shipping?' ($ts0 - 120000)) + $LF + (MeLine 'Earlier unidentified reply' ($ts0 - 60000))
$ctx = Reset $f2base
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-F2a-baseline-unknown-creates-hold' ($null -ne (Get-SourceUnknownHold 'Virtual Buyer')) ($script:logs -join ' | ')
Eq 'E-F2a-baseline-no-send' $script:sends 0

$f2new = $f2base + $LF + (MeLine 'New unidentified reply from the page' $ts0) + $LF + (BLine '10 cartons to Hamburg' ($ts0 + 1000))
$ctx = Reset $f2new
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-F2a-new-unknown-plus-buyer-does-not-send' $script:sends 0
$holdF2 = Get-SourceUnknownHold 'Virtual Buyer'
Check 'E-F2a-hold-persisted' ($null -ne $holdF2) ($script:logs -join ' | ')
Check 'E-F2a-hold-anchored-on-message-time' ((ConvertTo-HumanPauseUtc $holdF2.anchorUtc) -eq $script:nowUtc) ([string]$holdF2.anchorUtc)
Eq 'E-F2a-hold-anchor-source' ([string]$holdF2.anchorSource) 'message-time'
Check 'E-F2a-skip-logged' ([bool](($script:logs -join $LF) -match 'SOURCE-UNKNOWN-HOLD-ACTIVE-SKIP')) ($script:logs -join ' | ')

# ---- F2-b 同一条 unknown 重扫：等待窗口不延长 ----
$ctx = Reset $f2new
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-F2b-rescan-does-not-extend' ((ConvertTo-HumanPauseUtc (Get-SourceUnknownHold 'Virtual Buyer').untilUtc)) ((ConvertTo-HumanPauseUtc $holdF2.untilUtc))

# ---- F2-c 相同文字但新的逐条时间 => 新事件，等待窗口按新事件推进 ----
Set-FixNow '2026-10-05T12:04:00'
$f2newer = $f2base + $LF + (MeLine 'New unidentified reply from the page' ($ts0 + 240000)) + $LF + (BLine '10 cartons to Hamburg' ($ts0 + 241000))
$ctx = Reset $f2newer
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$holdF2c = Get-SourceUnknownHold 'Virtual Buyer'
Check 'E-F2c-identical-text-new-time-is-a-new-event' ((ConvertTo-HumanPauseUtc $holdF2c.untilUtc) -gt (ConvertTo-HumanPauseUtc $holdF2.untilUtc)) ([string]$holdF2c.untilUtc)
Eq 'E-F2c-no-send' $script:sends 0

# ---- F2-d 窗口截断 / 行号变化：同一事件不重新等待、不延长 ----
$f2trunc = $f2base + $LF + (MeLine 'New unidentified reply from the page' ($ts0 + 240000))
$ctx = Reset $f2trunc
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-F2d-truncated-window-keeps-until' ((ConvertTo-HumanPauseUtc (Get-SourceUnknownHold 'Virtual Buyer').untilUtc)) ((ConvertTo-HumanPauseUtc $holdF2c.untilUtc))

# ---- F2-e 重启：状态从盘上重建，等待窗口保持不变（不重新等五分钟）----
$restartHold = Get-SourceUnknownHold 'Virtual Buyer'
Eq 'E-F2e-restart-keeps-until' ((ConvertTo-HumanPauseUtc $restartHold.untilUtc)) ((ConvertTo-HumanPauseUtc $holdF2c.untilUtc))

# ---- F2-f 生成期间出现新的 unknown，尾部仍是同一条买家消息 => 旧草稿丢弃 ----
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$f2g1 = (BLine 'Can you quote 10 cartons to Hamburg?' ($ts0 - 3600000)) + $LF + (MeLine 'historical unidentified reply' ($ts0 - 3540000)) + $LF + (BLine 'Can you quote 10 cartons to Hamburg?' ($ts0 + 1000))
$script:raw2 = (BLine 'Can you quote 10 cartons to Hamburg?' ($ts0 - 3600000)) + $LF + (MeLine 'historical unidentified reply' ($ts0 - 3540000)) + $LF + (MeLine 'unidentified reply appeared during generation' $ts0) + $LF + (BLine 'Can you quote 10 cartons to Hamburg?' ($ts0 + 1000))
$ctx = Reset $f2g1
MarkSeen $ctx
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    if ($script:reads -ge 2 -and $script:raw2) { return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw2; profile = '' } }
    return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' }
}
Invoke-ConvoItem $ctx $item
Check 'E-F2f-mid-generation-unknown-discards-draft' ([bool](($script:logs -join $LF) -match 'STALE-DRAFT-DISCARD' -and ($script:logs -join $LF) -match 'source-unknown-hold')) ($script:logs -join ' | ')
Eq 'E-F2f-no-send' $script:sends 0
function Open-ConvoAndGetMessages($name) { $script:reads++; return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' } }

# ---- F2-g 首次加载的可靠历史 unknown（已过窗口）不重新等待 ----
Clear-PauseState
Set-FixNow '2026-10-05T12:00:00'
$oldUnknown = (BLine 'hello' $ts0) + $LF + (MeLine 'long finished unidentified reply' ($ts0 - 3600000))
$ctx = Reset $oldUnknown
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-F2g-old-unknown-is-history' ($null -eq (Get-SourceUnknownHold 'Virtual Buyer')) ($script:logs -join ' | ')

# ---- F4-a 供应商核实计划：任务在第一次模型调用前落盘，模型收到确切证据，计划真的发出 ----
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$f4raw = BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0
$script:modelReply = "We'll contact your supplier directly."
$ctx = Reset $f4raw
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$f4tasks = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-F4a-task-exists-before-generation' $script:taskCountAtModelCall 1
Eq 'E-F4a-single-task' $f4tasks.Count 1
Eq 'E-F4a-task-kind-is-canonical' ([string]$f4tasks[0].kind) 'supplier_verification'
Eq 'E-F4a-task-status-pending-human' ([string]$f4tasks[0].status) 'pending_human'
Eq 'E-F4a-real-contact-stored' ([string]$f4tasks[0].supplierContact) 'supplier@example.invalid'
Eq 'E-F4a-supplier-identity-is-the-contact' ([string]$f4tasks[0].supplierKey) 'email:supplier@example.invalid'
Check 'E-F4a-model-received-todo-persisted' ([bool]($script:modelInput -match 'todo persisted: true')) ''
Check 'E-F4a-model-received-task-id' ([bool]($script:modelInput -match [regex]::Escape([string]$f4tasks[0].id))) ''
Check 'E-F4a-model-received-kind' ([bool]($script:modelInput -match 'kind=supplier_verification')) ''
Check 'E-F4a-model-received-supplier-identity' ([bool]($script:modelInput -match [regex]::Escape('email:supplier@example.invalid'))) ''
Eq 'E-F4a-send-happened' $script:sends 1
Check 'E-F4a-direct-verification-plan-sent' ([bool]([string]$script:sentText -match '(?i)supplier')) ([string]$script:sentText)
Check 'E-F4a-not-degraded-to-rough-size' (-not ([string]$script:sentText -match '(?i)rough size')) ([string]$script:sentText)
Check 'E-F4a-plan-not-asking-buyer-to-measure' (-not ([string]$script:sentText -match '(?i)share the (carton sizes|dimensions)')) ([string]$script:sentText)
$f4ev = Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId ([string]$f4tasks[0].id) -Kind 'supplier_handoff' -SupplierIdentity ([string]$f4tasks[0].supplierKey)
Check 'E-F4a-exact-evidence-readback' ([bool]$f4ev.TodoPersisted) ''
Eq 'E-F4a-evidence-task-id' ([string]$f4ev.TaskId) ([string]$f4tasks[0].id)
Eq 'E-F4a-evidence-kind-canonical' ([string]$f4ev.TaskKind) 'supplier_verification'
Eq 'E-F4a-evidence-supplier-identity' ([string]$f4ev.SupplierIdentity) ([string]$f4tasks[0].supplierKey)
Check 'E-F4a-unknown-task-id-yields-no-evidence' (-not [bool](Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId 'no-such-task' -Kind 'supplier_handoff').TodoPersisted) ''
Check 'E-F4a-other-buyer-yields-no-evidence' (-not [bool](Get-ActionEvidenceForTask -Buyer 'Someone Else' -TaskId ([string]$f4tasks[0].id) -Kind 'supplier_handoff').TodoPersisted) ''
Check 'E-F4a-other-supplier-yields-no-evidence' (-not [bool](Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId ([string]$f4tasks[0].id) -Kind 'supplier_handoff' -SupplierIdentity 'email:other@example.net').TodoPersisted) ''

# ---- F4-b 人工认领但未联系 => "我们已经联系过供应商" 仍被拦 ----
$f4own = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Check 'E-F4b-owner-accept' (Set-HumanTaskOwnerAccepted -Id ([string]$f4own[0].id) -Deadline '')
$f4evOwn = Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId ([string]$f4own[0].id) -Kind 'supplier_verification'
Check 'E-F4b-owner-accepted-recorded' ([bool]$f4evOwn.OwnerAccepted) ''
Check 'E-F4b-contact-not-recorded-by-acceptance' (-not [bool]$f4evOwn.ContactedRecorded) ''
$claimDecision = [pscustomobject]@{ ActionEvidence = $f4evOwn; AskFields = @(); RequestedFacts = @(); Facts = $null }
Check 'E-F4b-claimed-contact-blocked' (Test-SupplierPlanWording -Text "We have already contacted your supplier about the packing." -Decision $claimDecision) ''
Check 'E-F4b-future-plan-still-allowed' (-not (Test-SupplierPlanWording -Text "We'll confirm the packed weight with your supplier." -Decision $claimDecision)) ''
Check 'E-F4b-set-contacted' (Set-HumanTaskStatus -Id ([string]$f4own[0].id) -Status 'contacted' -Note 'called the supplier') ''
$f4evContacted = Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId ([string]$f4own[0].id) -Kind 'supplier_verification'
Check 'E-F4b-status-alone-no-contact-evidence' (-not [bool]$f4evContacted.ContactedRecorded) ''
$actualContact=Add-HumanTaskActionRecord -Id ([string]$f4own[0].id) -ActionKind contacted -Source operator-entry -RecordedBy 'fixture operator' -SourceRef 'fixture:actual-call-1' -AtUtc '2026-10-05T04:00:00Z' -RawContent 'Operator called the supplier about packing'
Check 'E-F4b-explicit-contact-record-saved' $actualContact.Ok ''
$f4evContacted = Get-ActionEvidenceForTask -Buyer 'Virtual Buyer' -TaskId ([string]$f4own[0].id) -Kind 'supplier_verification'
Check 'E-F4b-contact-recorded-after-action' ([bool]$f4evContacted.ContactedRecorded) ''
$claimDecision2 = [pscustomobject]@{ ActionEvidence = $f4evContacted; AskFields = @(); RequestedFacts = @(); Facts = $null }
Check 'E-F4b-claimed-contact-allowed-after-record' (-not (Test-SupplierPlanWording -Text "We have already contacted your supplier about the packing." -Decision $claimDecision2)) ''
$notifyOnly = [pscustomobject]@{ TodoPersisted = $true; NotificationDelivered = $true; OwnerAccepted = $false; ContactedRecorded = $false; SupplierReplyRecorded = $false; TaskStatus = 'pending_human'; TaskId = 't1'; TaskKind = 'supplier_verification' }
$notifyEvidence = New-ActionEvidence -Values $notifyOnly
$notifyDecision = [pscustomobject]@{ ActionEvidence = $notifyEvidence; AskFields = @(); RequestedFacts = @(); Facts = $null }
Check 'E-F4b-notification-does-not-authorise-confirmation' (Test-SupplierPlanWording -Text "Your supplier confirmed the packed weight is 20 kg per carton." -Decision $notifyDecision) ''

# ---- F4-c awaiting_contact：允许条件式计划，但模型上下文里明确"联系尚未记录" ----
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = "Once we have the details we'll check with your supplier."
$ctx = Reset (BLine "I don't know the dimensions and I cannot measure the cartons." $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$f4cTasks = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Eq 'E-F4c-awaiting-contact-task' ([string]$f4cTasks[0].status) 'awaiting_contact'
Check 'E-F4c-model-received-awaiting-task' ([bool]($script:modelInput -match 'todo persisted: true')) ''
Check 'E-F4c-no-contact-claim-in-model-context' ([bool]($script:modelInput -match 'contact is NOT recorded')) ''

# ---- F4-d 任务落盘失败 => 不得给联系计划授权 ----
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = "We'll contact your supplier directly."
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
$origSup = (Get-Command New-OrUpdate-SupplierVerificationTask).ScriptBlock
function New-OrUpdate-SupplierVerificationTask {
    param([Parameter(Mandatory = $true)][string]$Buyer, [string[]]$MissingFields = @(), [string]$SupplierContact = '', [string]$TriggerMessage = '', $FactsSnapshot = $null, [string]$SupplierName = '', [string]$SupplierId = '', [string]$TriggerMessageId = '', [string]$TriggerAt = '', [string]$Source = '', [string]$Note = '')
    return [pscustomobject]@{ Task = [pscustomobject]@{ id = 'failed-task'; status = 'pending_human'; supplierKey = 'k' }; Created = $false; Updated = $true; StoreOk = $false }
}
Invoke-ConvoItem $ctx $item
Check 'E-F4d-store-failure-logged' ([bool](($script:logs -join $LF) -match 'HUMAN-TASK-STORE-FAIL')) ''
Check 'E-F4d-no-plan-without-persisted-task' (-not ([string]$script:sentText -match '(?i)we(.|\n){0,20}(contact|check with|verify with)\b.{0,20}supplier')) ([string]$script:sentText)
Set-Item Function:New-OrUpdate-SupplierVerificationTask $origSup

# ---- F4-e 生成后任务被关闭 => 旧草稿丢弃，不继续使用 script 里的旧证据 ----
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = "We'll contact your supplier directly."
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
$script:closeTaskOnSecondRead = $true
$openBodyF4 = (Get-Command Open-ConvoAndGetMessages).ScriptBlock
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    if ($script:reads -ge 2 -and $script:closeTaskOnSecondRead) {
        foreach ($x in @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)) { [void](Set-HumanTaskStatus -Id ([string]$x.id) -Status 'closed' -Note 'closed during generation') }
    }
    return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' }
}
Invoke-ConvoItem $ctx $item
Check 'E-F4e-closed-task-discards-draft' ([bool](($script:logs -join $LF) -match 'STALE-DRAFT-DISCARD' -and ($script:logs -join $LF) -match 'task-closed-or-changed|response-plan dependencies changed')) ($script:logs -join ' | ')
Eq 'E-F4e-no-send' $script:sends 0
Set-Item Function:Open-ConvoAndGetMessages $openBodyF4
$script:closeTaskOnSecondRead = $false

# ---- F4-f 两个会话轮流处理：turnActionEvidence / turnTaskRef 不跨会话泄漏 ----
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = "We'll contact your supplier directly."
$ctx = Reset (BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
$leakTaskRef = $script:turnTaskRef
Check 'E-F4f-first-conversation-has-task-ref' ([bool]($null -ne $leakTaskRef -and $leakTaskRef.TaskId)) ''
$firstBuyerItem=$item
$item=[pscustomobject]@{name='Other Virtual Buyer';preview='unchanged';unread=$true}
$ctx2 = Reset (BLine 'Can you quote 10 cartons to Hamburg?' $ts0)
$script:pageName='Other Virtual Buyer'
MarkSeen $ctx2
Invoke-ConvoItem $ctx2 $item
Check 'E-F4f-second-conversation-clears-task-ref' ([string]::IsNullOrEmpty([string]$script:turnTaskRef.TaskId)) ('ref=' + [string]$script:turnTaskRef.TaskId)
$item=$firstBuyerItem

# ---- F6-a 业务位置位于时间问题之前：时间目标仍是中国（真实入口 + 发送桩）----
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T14:05:00'
$tsF6 = ([System.DateTimeOffset]$script:nowUtc).ToUnixTimeMilliseconds()
$ctx = Reset (BLine 'My company is in Tokyo, what time is it in China?' $tsF6)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E-F6a-send-happened' $script:sends 1
Check 'E-F6a-answers-china' ([bool]([string]$script:sentText -match "It's 2:05 PM in China")) ([string]$script:sentText)
Check 'E-F6a-not-japan' (-not ([string]$script:sentText -match 'Japan')) ([string]$script:sentText)

# ---- F6-b 两个时间问题：两个目标都要被回答，不静默漏答第二个 ----
$ctx = Reset (BLine 'What time is it in China? What time is it in Tokyo?' $tsF6)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-F6b-answers-china' ([bool]([string]$script:sentText -match "It's 2:05 PM in China")) ([string]$script:sentText)
Check 'E-F6b-answers-tokyo' ([bool]([string]$script:sentText -match "It's 3:05 PM in Tokyo")) ([string]$script:sentText)

# ---- F6-c 已解析目标 + 多时区国家：可靠目标正确，未解析目标明确澄清 ----
$ctx = Reset (BLine 'What time is it in China and in Australia?' $tsF6)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E-F6c-answers-china' ([bool]([string]$script:sentText -match "It's 2:05 PM in China")) ([string]$script:sentText)
Check 'E-F6c-clarifies-australia' ([bool]([string]$script:sentText -match 'Which city or time zone in Australia')) ([string]$script:sentText)
Set-FixNow '2026-10-05T12:00:00'


# ============================================================================================
# [2026-10-05 第三轮 spec §10] 独立复核七项与交叉用例的**真实 monitor 入口**回归
#   输入逐条对应 docs\verification\architecture_opt_20261005\review_fixes\second_independent_review_20261005\edge_probes.ps1
#   的 7 条失败断言（复跑基线 Pass=0 Fail=7）；这里把它们与正/反交叉用例转成正式分层回归。
#   合法性以"文字是否到达发送桩（Sends=1）"为准：非法文字一律不得到达发送桩，合法正例必须真的发出。
# ============================================================================================
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'

# ---- R5：同一快照里带真实发送证据的我方消息（无 @@TS）不得创建人工暂停 ----
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{ 0 = $true } }
$ctx = Reset ((HumanLine 'Confirmed automated answer' $ts0) + $LF + (BLine 'New question' ($ts0 + 1000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E3-R5-confirmed-bot-no-pause' ($null -eq (Get-HumanPause 'Virtual Buyer')) ($script:logs -join ' | ')
Eq 'E3-R5-confirmed-bot-still-sends' $script:sends 1
Check 'E3-R5-no-pause-skip-log' (-not (($script:logs -join $LF) -match 'HUMAN-PAUSE-ACTIVE-SKIP')) ($script:logs -join ' | ')
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{} }

# ---- R2：只有一条其他类型的待办时，供应商承诺不得借它授权 ----
Clear-PauseState
Clear-TaskState
$other = New-OrUpdate-HumanTask -Buyer 'Virtual Buyer' -Kind 'fulfillment_status' -TriggerMessage 'Where is my shipment?' -Status 'pending_human'
Eq 'E3-R2-only-unrelated-task-exists' (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) 1
$script:modelReply = "We'll contact your supplier directly."
$ctx = Reset (BLine 'Can you help with shipping?' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E3-R2-unrelated-todo-does-not-authorize-supplier-plan' (-not ([string]$script:sentText -match "(?i)we'll contact your supplier directly")) ([string]$script:sentText)
Eq 'E3-R2-legal-fallback-still-sends' $script:sends 1
Check 'E3-R2-no-exact-ref-logged' ([bool](($script:logs -join $LF) -match 'HUMAN-TASK-NO-EXACT-REF')) ($script:logs -join ' | ')

# ---- R1：并列句后半段省略请求动词的泛化联系请求不得到达发送桩 ----
Clear-PauseState
Clear-TaskState
$script:modelReply = "Please share the supplier's contact details for packing and contact details so we can reach you."
$ctx = Reset (BLine "I don't know the packed dimensions." $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E3-R1-conjoined-generic-ask-blocked' (-not ([string]$script:sentText -match '(?i)contact details so we can reach you')) ([string]$script:sentText)
Eq 'E3-R1-legal-fallback-reaches-the-stub' $script:sends 1
Check 'E3-R1-block-logged' ([bool](($script:logs -join $LF) -match 'SEND-GATE-BLOCK|business-body-sensitive|REPLY-GEN .*violations=\[CONTACT_ASK_NO_ROLE\]')) ($script:logs -join ' | ')
Check 'E3-R1-fallback-not-asking-buyer-to-measure' (-not ([string]$script:sentText -match '(?i)rough size|share the carton sizes')) ([string]$script:sentText)

# ---- R6：正确程序前缀不能掩盖错误正文；最终文字必须逐目标绑定地点/时区/时刻 ----
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = "It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9)."
$ctx = Reset (BLine 'What time is it in China and in Tokyo? I need a shipping quote.' $ts0)
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E3-R6-send-happened' $script:sends 1
Check 'E3-R6-no-swapped-clock-in-final-text' (-not ([string]$script:sentText -match '1:00 PM in China')) ([string]$script:sentText)
Check 'E3-R6-no-wrong-japan-clock' (-not ([string]$script:sentText -match '12:00 PM in Japan')) ([string]$script:sentText)
Check 'E3-R6-final-text-answers-both-targets' (([bool]([string]$script:sentText -match "It's 12:00 PM in China \(UTC\+8\)")) -and ([bool]([string]$script:sentText -match "It's 1:00 PM in Tokyo \(UTC\+9\)"))) ([string]$script:sentText)
Check 'E3-R6-mismatch-logged' ([bool](($script:logs -join $LF) -match 'FACT_TIME_MISMATCH|business-body-(?:unknown|sensitive)')) ($script:logs -join ' | ')

# ---- R3：contacted 但无供应商回复 => "供应商已确认尺寸" 不得到达发送桩 ----
Clear-PauseState
Clear-TaskState
$supTask = New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'supplier@example.invalid' -TriggerMessage 'Please check supplier packing for this shipment.' -MissingFields @('unit_dimensions')
[void](Set-HumanTaskStatus -Id ([string]$supTask.Task.id) -Status 'contacted' -Note 'Called supplier; waiting for a reply')
$script:modelReply = 'Your supplier confirmed the dimensions.'
$ctx = Reset ((BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E3-R3-contacted-is-not-a-supplier-reply' (-not ([string]$script:sentText -match '(?i)supplier confirmed')) ([string]$script:sentText)
Eq 'E3-R3-legal-fallback-sends' $script:sends 1
Check 'E3-R3-confirmed-fields-empty-at-send' ([bool](-not (@($script:turnActionEvidence.ConfirmedFields).Count -gt 0))) ''

# ---- 交叉 1：正确供应商任务 -> 先说合法将来计划、再说无依据已确认：第二动作阻断 ----
Clear-PauseState
Clear-TaskState
$script:modelReply = "We'll confirm the packed weight with your supplier, and your supplier has already confirmed the dimensions."
$ctx = Reset ((BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $ts0))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Check 'E3-X1-second-unsupported-action-blocked' (-not ([string]$script:sentText -match '(?i)already confirmed')) ([string]$script:sentText)
Eq 'E3-X1-legal-part-still-sends' $script:sends 1

# ---- 交叉 2：混合多地点时间 + 供应商核实，生成后任务证据与时钟变化 => 用新时钟 + 同一合法任务证据 ----
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$script:modelReply = 'Happy to help with the rate.'
$script:raw2 = ''
$openBodyX2 = (Get-Command Open-ConvoAndGetMessages).ScriptBlock
$ctx = Reset ((BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions. Also, what time is it in China and in Tokyo?" $ts0))
MarkSeen $ctx
function Open-ConvoAndGetMessages($name) {
    $script:reads++
    if ($script:reads -ge 2) { $script:nowUtc = $script:nowUtc.AddMinutes(37); $script:now = $script:now.AddMinutes(37) }
    return [pscustomobject]@{ name = $script:pageName; msgs = $script:raw; profile = '' }
}
Invoke-ConvoItem $ctx $item
Set-Item Function:Open-ConvoAndGetMessages $openBodyX2
Check 'E3-X2-final-text-uses-fresh-clock' (([bool]([string]$script:sentText -match "It's 12:37 PM in China")) -and (-not ([string]$script:sentText -match "It's 12:00 PM in China"))) ([string]$script:sentText)
Check 'E3-X2-mixed-time-answers-tokyo' ([bool]([string]$script:sentText -match "It's 1:37 PM in Tokyo")) ([string]$script:sentText)
Eq 'E3-X2-same-legal-task-evidence' (@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly).Count) 1
Check 'E3-X2-task-identity-stable' ([string]$script:turnTaskRef.TaskId -eq [string](@(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)[0]).id) ([string]$script:turnTaskRef.TaskId)
Set-FixNow '2026-10-05T12:00:00'

# ---- 交叉 3：快照里已有确认机器人 + 之后有真实人工 + 买家：机器人不暂停，真实人工仍暂停；到期后可发 ----
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{ 0 = $true } }
$ctx = Reset ((MeLine 'our own bot answer' $ts0) + $LF + (HumanLine 'owner takes over' ($ts0 + 1000)) + $LF + (BLine 'any update?' ($ts0 + 2000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E3-X3-paused-by-real-human-only' $script:sends 0
$pauseX3 = Get-HumanPause 'Virtual Buyer'
Check 'E3-X3-pause-identity-is-the-human-line' ([string]$pauseX3.lastHumanMessageId -eq (Get-InterventionEventIdentity (HumanLine 'owner takes over' ($ts0 + 1000)))) ([string]$pauseX3.lastHumanMessageId)
Eq 'E3-X3-absolute-deadline-is-human-plus-5' (ConvertTo-HumanPauseUtc $pauseX3.untilUtc) $script:nowUtc.AddSeconds(1).AddMinutes(5)
Set-FixNow '2026-10-05T12:05:30'
$ctx = Reset ((MeLine 'our own bot answer' $ts0) + $LF + (HumanLine 'owner takes over' ($ts0 + 1000)) + $LF + (BLine 'any update?' ($ts0 + 2000)))
MarkSeen $ctx
Invoke-ConvoItem $ctx $item
Eq 'E3-X3-legal-reply-after-expiry-sends' $script:sends 1
function Get-SentRecordMatchIndexes { param([string]$Buyer, [string[]]$Lines) return @{} }
Set-FixNow '2026-10-05T12:00:00'


Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
