# independent_probes_after.ps1 - 与 independent_review_20261005\independent_probes.ps1 **同一组输入**的复跑版本。
# 只改三处夹具时间口径（spec §3.2 明确要求修正）：
#   ① harness 切割点改为修正后的 $ts0 字面量；
#   ② 暂停链用 -NowUtc（UTC 注入时钟）而不是墙上时钟；
#   ③ 推进时钟走 Set-FixNow（同时推进本地/UTC 两个注入时钟）。
# 失败基线见同目录 independent_probes_before.txt（由原始探针文件产出）。
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$harnessText = Get-Content -LiteralPath (Join-Path $repo 'tests\review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
# 夹具时间口径在 2026-10-05 八项补修里被修正：$ts0 现在等于注入时钟的绝对时刻。
$cut = $harnessText.IndexOf('$ts0 = [long]1791172800000')
if ($cut -lt 0) { throw 'Cannot locate isolated harness boundary' }
$prefix = $harnessText.Substring(0, $cut)
$prefix = $prefix.Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + ''''))
Invoke-Expression $prefix
function Result([string]$Probe, $Data) {
    [pscustomobject]@{ Probe = $Probe; Data = $Data } | ConvertTo-Json -Depth 8 -Compress | Write-Output
}
$LF = [string][char]10
$localNow = [datetime]'2026-10-05T12:00:00'
$utcNow = [datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$tsNow = ([DateTimeOffset]$utcNow).ToUnixTimeMilliseconds()
Set-FixNow '2026-10-05T12:00:00'

# Full compliance checker: omitted articles and role words that do not own the requested contact.
$contactDecision = [pscustomobject]@{ AskFields = @('supplier'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
foreach ($text in @(
    'You can email me if that is easier.',
    'Please leave a phone number for delivery updates.',
    'Please share contact details for delivery updates.',
    'Please provide contact information so we can reach you.',
    'Could you share your phone number so we can confirm the packing with your supplier?'
)) {
    $check = Test-ReplyCompliance -Text $text -Rules $null -Decision $contactDecision
    Result 'contact-full-check' @{ Text = $text; Ok = $check.Ok; Codes = @($check.Violations | ForEach-Object { $_.Code }) }
}

# Time questions with the business location before the question and multiple requested targets.
$runtime = New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc $utcNow
foreach ($text in @(
    'What time is it in hamburg?',
    'What time is it in China? My company is in Tokyo.',
    'My company is in Tokyo, what time is it in China?',
    'My company is in Tokyo. what time is it in China?',
    'What time is it in China and in Tokyo?',
    'What time is it in China? What time is it in Tokyo?'
)) {
    $conversation = ConvertTo-MessageList (BLine $text $tsNow) 'Virtual Buyer'
    $decision = Get-ReplyDecision -Conversation $conversation -Facts (Get-ConversationFacts $conversation) -Rules $null -RuntimeContext $runtime
    Result 'time-decision' @{ Text = $text; Place = $decision.RequestedPlace; Scope = $decision.RequestedTimeScope; Answer = $decision.DirectFactText }
}

# Absolute message time: first scan at 12:04 should expire at 12:05 for a 12:00 reply.
Clear-PauseState
Set-FixNow '2026-10-05T12:04:00'
$humanLine = (MeLine 'A human answered at noon' $tsNow) + ' @@SRC:human'
$pauseResult = Update-HumanPauseFromLines -Buyer 'Virtual Buyer' -Lines @($humanLine, (BLine 'Any update?' ($tsNow + 60000))) -SentMatches @{} -NowUtc $script:nowUtc
Result 'pause-delayed-first-scan' @{ MessageAt = $utcNow.ToString('HH:mm:ss'); ScanAt = $script:nowUtc.ToString('HH:mm:ss'); UntilUtc = ([datetime]$pauseResult.Until).ToString('HH:mm:ss'); ExpectedUntilUtc = $utcNow.AddMinutes(5).ToString('HH:mm:ss') }

# Two retained historical human replies must not re-extend the same expired pause every scan.
Clear-PauseState
$script:now = $localNow
$twoHumans = @(
    ((MeLine 'Earlier human answer' ($tsNow - 60000)) + ' @@SRC:human'),
    ((MeLine 'Latest human answer' $tsNow) + ' @@SRC:human')
)
$first = Update-HumanPauseFromLines -Buyer 'Virtual Buyer' -Lines $twoHumans -SentMatches @{} -NowUtc $script:nowUtc
Set-FixNow '2026-10-05T12:06:00'
$second = Update-HumanPauseFromLines -Buyer 'Virtual Buyer' -Lines $twoHumans -SentMatches @{} -NowUtc $script:nowUtc
Result 'pause-history-rescan' @{ FirstUntilUtc = ([datetime]$first.Until).ToString('HH:mm:ss'); ScanAtUtc = $script:nowUtc.ToString('HH:mm:ss'); SecondUntilUtc = ([datetime]$second.Until).ToString('HH:mm:ss'); Active = (Test-HumanPauseActive -Buyer 'Virtual Buyer' -NowUtc $script:nowUtc).Active; LastIdentity = (Get-HumanPause 'Virtual Buyer').lastHumanMessageId }

# New unknown our-side reply followed by buyer before the scan: use production page-format lines.
Clear-PauseState
Clear-TaskState
$script:now = $localNow
$script:nowUtc = $utcNow
$base = (BLine 'Can you help with shipping?' ($tsNow - 120000)) + $LF + (MeLine 'Earlier unidentified reply' ($tsNow - 60000))
$ctx = Reset $base
Invoke-ConvoItem $ctx $item
$water = $ctx.sourceUnknownMarks['Virtual Buyer']
$supplement = $base + $LF + (MeLine 'New human reply without source marker' $tsNow) + $LF + (BLine '10 cartons to Hamburg' ($tsNow + 1000))
$ctxNext = Reset $supplement
$ctxNext.sourceUnknownMarks = $ctx.sourceUnknownMarks
Invoke-ConvoItem $ctxNext $item
Result 'unknown-new-reply-then-buyer-entry' @{ PreviousWatermark = $water; HoldExists = ($null -ne (Get-SourceUnknownHold 'Virtual Buyer')); Sends = $script:sends; SentText = $script:sentText; Logs = @($script:logs | Where-Object { $_ -match 'SOURCE-UNKNOWN|REPLY-GEN|HUMAN-TASK' }) }

# Supplier task has to supply the current task evidence before the future plan is generated.
Clear-PauseState
Clear-TaskState
$script:now = $localNow
$supplierRaw = BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." $tsNow
$ctx = Reset $supplierRaw
$script:modelReply = "We'll contact your supplier directly."
Invoke-ConvoItem $ctx $item
$tasks = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Result 'supplier-plan-entry' @{ Sends = $script:sends; SentText = $script:sentText; Evidence = $script:turnActionEvidence; StoredKind = $tasks[0].kind; Logs = @($script:logs | Where-Object { $_ -match 'REPLY-GEN|HUMAN-TASK' }) }

# Different contacts at one email service must not merge suppliers or overwrite the first contact.
Clear-TaskState
$one = New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'factory-one@mail.example.invalid' -MissingFields @('unit_dimensions')
$two = New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'factory-two@mail.example.invalid' -MissingFields @('unit_weight')
$tasks = @(Get-HumanTaskList -Buyer 'Virtual Buyer' -OpenOnly)
Result 'supplier-key-collision' @{ FirstId = $one.Task.id; SecondId = $two.Task.id; Count = $tasks.Count; Keys = @($tasks | ForEach-Object { $_.supplierKey }); Contacts = @($tasks | ForEach-Object { $_.supplierContact }) }

# A business location preceding the time question must not override its explicit China target at send.
Clear-PauseState
Clear-TaskState
$ctx = Reset (BLine 'My company is in Tokyo, what time is it in China?' $tsNow)
Invoke-ConvoItem $ctx $item
Result 'time-business-before-question-entry' @{ Sends = $script:sends; SentText = $script:sentText; Logs = @($script:logs | Where-Object { $_ -match 'REPLY-GEN|FACT-TIME' }) }

# An ordinary relative clause containing "which" must not skip the authorized-field check.
$weightOnly = [pscustomobject]@{ AskFields = @('weight'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
foreach ($text in @('Could you share the packed weight per carton?', 'Could you share the carton count?', 'Could you share the carton count, which we need for the quote?')) {
    $check = Test-ReplyCompliance -Text $text -Rules $null -Decision $weightOnly
    Result 'ask-field-clarification-bypass' @{ Text = $text; Ok = $check.Ok; Codes = @($check.Violations | ForEach-Object { $_.Code }) }
}

# The actual summarize entry must render the same readiness as the unified fact model.
$summarySnapshot = Join-Path $script:dataDir 'msgs_summary_review_20261005.txt'
$summaryCargo = BLine 'Cargo name: cable. Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' $tsNow
[System.IO.File]::WriteAllText($summarySnapshot, ('# BUYER: Virtual Buyer' + $LF + $summaryCargo), (New-Object System.Text.UTF8Encoding($true)))
$summaryLog = Join-Path $isoRoot 'virtual_summary_monitor.log'
$summaryLogText = '2026-10-05 12:00:00 | REPLIED to Virtual Buyer: SENT_OK' + $LF + '2026-10-05 12:00:00 | Reply text: Thanks for the details.'
[System.IO.File]::WriteAllText($summaryLog, $summaryLogText, (New-Object System.Text.UTF8Encoding($true)))
$summaryOut = Join-Path $isoRoot 'review_reports'
$summaryState = Join-Path $isoRoot 'review_summary_state.json'
$summaryGoods = Get-GoodsDataStatus 'Virtual Buyer' $script:dataDir
$summaryResult = & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $repo 'scripts\summarize.ps1') -LogFile $summaryLog -OutDir $summaryOut -StateFile $summaryState
if ($LASTEXITCODE -ne 0) { throw 'Isolated summarize entry failed' }
$summaryFile = @(Get-ChildItem -LiteralPath $summaryOut -Filter '*.md') | Select-Object -First 1
$summaryRows = @(Get-Content -LiteralPath $summaryFile.FullName -Encoding UTF8 | Where-Object { $_ -match '^\| Virtual Buyer' })
Result 'actual-summary-readiness' @{ Ready = $summaryGoods.ready; Missing = $summaryGoods.missingFields; SummaryRow = ($summaryRows -join $LF); Output = ($summaryResult -join $LF); Path = $summaryFile.FullName }

Result 'isolated-root' $isoRoot
