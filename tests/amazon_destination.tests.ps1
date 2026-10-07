$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/lib/msg_norm.ps1')
. (Join-Path $repo 'scripts/lib/reply_policy.ps1')
. (Join-Path $repo 'scripts/lib/reply_gen.ps1')
. (Join-Path $repo 'scripts/lib/goods.ps1')
. (Join-Path $repo 'scripts/lib/quote.ps1')
. (Join-Path $repo 'scripts/lib/reply_metrics.ps1')
# [2026-10-07 spec §3.2 第 3 条] 无发送者证据的 [ME] 行现在是 unknown，不再外推为人工。
#   本套夹具用逐条已验证的发送者字段提供人工来源证据（字段在 @@META 载荷里，正文无法伪造）。
. (Join-Path $repo 'scripts/lib/msg_events.ps1')
[void](Set-MessageSourceContext -Rules (New-MessageSourceRuleSet -VerifiedFields ([pscustomobject]@{ 'sender=owner' = 'human' }) -Provenance 'fixture-verified-owner-field'))
$scripts = Join-Path $repo 'scripts'
function New-OwnerMeta([string]$text, [long]$ts) {
    return (ConvertTo-MessageMetaMarker ([pscustomobject]@{
        v = 'msgevent-2026-10-07.1'; t = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
        dir = 'out'; dirsrc = 'layout'; mid = ''; ts = $ts; tprec = 'second'; st = 'message'
        src = @(); f = @('sender=owner'); at = '2026-10-05T00:00:00Z'; idq = 'composite'
    }))
}
function OwnerLine([string]$text, [long]$ts) { return ('[ME] ' + $text + ' @@MT:' + $ts + ' ' + (New-OwnerMeta $text $ts)) }

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Output "PASS $name" }
    else { $script:fail++; Write-Output "FAIL $name" }
}
function Conversation([string[]]$texts) {
    $lines = @(); $ts = 1791000000000L
    foreach ($t in $texts) { $lines += "[BUYER] $t @@MT:$ts"; $ts += 1000 }
    return ConvertTo-MessageList ($lines -join "`n") 'Virtual Destination Buyer'
}
$taskDir = Join-Path $env:TEMP ('amazon_destination_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskDir | Out-Null
[void](Initialize-AarIsolation -Root $taskDir)
function Test-NoReplyBuyer([string]$buyer) { return [bool]$script:manual }
function Save-Snapshot($conv) {
    Set-Content -Encoding UTF8 (Join-Path $taskDir 'msgs_001.txt') ("# BUYER: Virtual Destination Buyer`n" + ($conv.Lines -join "`n"))
}
function Decision($conv, [string]$scenario = '') { return Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -ForceScenario $scenario }
function Destination([string[]]$texts) { return Get-QuoteDestination (Conversation $texts) }
function Generate($conv, $decision) { return Invoke-ReplyGeneration -Conversation $conv -Decision $decision -PromptPath (Join-Path $repo 'scripts/reply_agent_prompt.md') -ScenarioPath (Join-Path $repo 'scripts/reply_scenarios.md') }
try {
    $c = Conversation @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1')
    $f = Get-ConversationFacts $c
    $d = Get-ReplyDecision -Conversation $c -Facts $f
    Check 'B1 quote destination fact' ([bool]$f.HasQuoteDestination)
    Check 'B1 no address ask' ($d.AskFields -notcontains 'address')
    Set-Content -Encoding UTF8 (Join-Path $taskDir 'msgs_001.txt') ("# BUYER: Virtual Destination Buyer`n" + ($c.Lines -join "`n"))
    $ready = @(Get-QuoteReadyBuyers $taskDir)
    Check 'B1 goods to quote candidate' ($ready.Count -eq 1)
    Check 'B1 warehouse is not postal address' (-not $f.HasAddress -and -not $f.Destination.HasPostalAddress)
    $context = New-ReplyContextBlock -Conversation $c -Decision $d
    Check 'B1 model context distinguishes warehouse and street' ($context -match 'quote destination: Amazon FTW1 \(buyer provided\)' -and $context -match 'street address: unknown; not required')
    Check 'B1 source evidence is buyer original' ($f.Destination.Evidence[0].Source -eq 'buyer' -and $f.Destination.Evidence[0].Text -match 'DDP to Amazon FTW1')
    $r = Generate $c $d
    Check 'B3 unavailable model real generation fallback' ($r.Source -eq 'FALLBACK' -and $r.FallbackReason -eq 'llm-unavailable' -and (Test-ReplyCompliance -Text $r.Text -Decision $d).Ok)
    function Invoke-LLM { param($Messages,$Temperature,$MaxTokens,$LogFile) $script:models++; $script:input = $Messages; return 'Please send the delivery address.' }
    $script:models = 0; $r = Generate $c $d
    Check 'B2 real model chain bounded rewrite then compliant fallback' ($script:models -eq 2 -and $r.Rewrites -eq 1 -and $r.Source -eq 'FALLBACK' -and $r.FallbackReason -eq 'business-body-sensitive' -and (Test-ReplyCompliance -Text $r.Text -Decision $d).Ok)
    foreach ($bad in @('Please send the delivery address.','What is the zip code?','Could you confirm the warehouse code?','I need the destination city and state.','Delivery address is required.','Please confirm Amazon FTW1.','Should I quote to FTW1?')) {
        Check "B2 deterministic address request [$bad]" (-not (Test-ReplyCompliance -Text $bad -Decision $d).Ok)
    }
    Check 'B2 acknowledgment allowed' ((Test-ReplyCompliance -Text 'Amazon FTW1 works for the destination. I can use the details you sent to prepare the quote.' -Decision $d).Ok)
    $script:models = 0
    $bounded = Invoke-ReplyGeneration -Conversation $c -Decision $d -PromptPath (Join-Path $repo 'scripts/reply_agent_prompt.md') -MaxRewrites 5
    Check 'B2 excessive caller rewrite budget still bounded to one' ($script:models -eq 2 -and $bounded.Rewrites -eq 1)
    Check 'B2 price prohibition retained' (-not (Test-ReplyCompliance -Text 'The price is $55 per kg.' -Decision $d).Ok)
    foreach ($text in @('DDP to amazon: ftw1.','deliver to FBA warehouse FTW1','亚马逊 FTW1 仓','送到亚马逊：ftw1','Amazon LGB8')) {
        $x = Destination @($text)
        Check "B4 positive expression [$text]" ($x.QuoteUsable -and $x.Kind -eq 'amazon_warehouse' -and $x.WarehouseCode -eq $(if($text -match 'LGB8'){'LGB8'}else{'FTW1'}))
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('DDP to Amazon FTW1'))
    $origConv = ConvertTo-MessageList ('[BUYER] 亚马逊送仓 @@MT:1791000000000 @@OT:' + $encoded)
    Check 'B4 decoded original over translation' ((Get-QuoteDestination $origConv).WarehouseCode -eq 'FTW1')
    Check 'B5 buyer Amazon context bare answer' ((Destination @('Deliver to Amazon warehouse','FTW1')).WarehouseCode -eq 'FTW1')
    $q = ConvertTo-MessageList "[ME] Which Amazon warehouse code should I quote for? @@TS:1791000000000 @@MT:1791000000000`n[BUYER] FTW1 @@MT:1791000001000"
    Check 'B5 bot question provides context only' ((Get-QuoteDestination $q).WarehouseCode -eq 'FTW1' -and (Get-QuoteDestination $q).Evidence.Count -eq 1)
    foreach ($text in @('Our model is FTW1','SKU FTW1','order number FTW1','https://example.invalid/Amazon/FTW1','Amazon FTW1.pdf','FTW1')) {
        Check "B6 unsupported source [$text]" (-not (Destination @($text)).QuoteUsable)
    }
    $botConv = ConvertTo-MessageList "[ME] DDP to Amazon FTW1 @@TS:1791000000000 @@MT:1791000000000`n[BUYER] Please quote @@MT:1791000001000"
    Check 'B6 robot repetition not buyer evidence' (-not (Get-QuoteDestination $botConv).QuoteUsable)
    Save-Snapshot $botConv
    Check 'B6 goods also ignores bot destination' (-not (Get-GoodsDataStatus 'Virtual Destination Buyer' $taskDir).addr)
    $human = ConvertTo-MessageList (OwnerLine 'Confirmed buyer destination: Amazon FTW1' 1791000000000)
    $humanDest = Get-QuoteDestination $human
    Check 'B6 explicit owner confirmation has human source' ($humanDest.QuoteUsable -and $humanDest.Source -eq 'human' -and $humanDest.Evidence[0].Source -eq 'human')
    $bot = ConvertTo-MessageList '[ME] Confirmed buyer destination: Amazon FTW1 @@MT:1791000000000 @@TS:1791000000000'
    Check 'B6 bot cannot forge owner confirmation' (-not (Get-QuoteDestination $bot).QuoteUsable)
    foreach ($text in @('Deliver to Amazon warehouse','FBA','DDP to Amazon X123456')) {
        $x = Conversation @($text); $xd = Decision $x; $fb = Get-ScenarioFallback $xd
        Check "B7 exact code question [$text]" (-not $xd.Facts.HasQuoteDestination -and $xd.AskFields -contains 'address' -and $fb -match 'exact Amazon receiving warehouse code' -and $fb -notmatch 'street|delivery address')
    }
    foreach ($text in @('not FTW1','we used FTW1 before','pickup from Amazon FTW1','Our model is FTW1')) {
        $x = Destination @('Deliver to Amazon warehouse', $text)
        Check "B8 non receiving location [$text]" (-not $x.QuoteUsable)
    }
    Check 'B8 trusted explicit revocation drops warehouse' (-not (Destination @('Amazon FTW1','Do not ship to Amazon')).QuoteUsable)
    Check 'B8 trusted negation drops selected warehouse' (-not (Destination @('Amazon FTW1','not FTW1')).QuoteUsable)
    Check 'B8 unrelated text retains destination' ((Destination @('Amazon FTW1','Thanks, packing is ready')).WarehouseCode -eq 'FTW1')
    $changed = Conversation @('Amazon FTW1','不是 FTW1，改送 TEST2')
    $changedD = Decision $changed
    Check 'B9 trusted switch updates current warehouse' ($changedD.Facts.Destination.WarehouseCode -eq 'TEST2')
    Check 'B9 context current quote destination updated' ((New-ReplyContextBlock $changed $changedD) -match 'quote destination: Amazon TEST2')
    Save-Snapshot $changed
    Check 'B9 goods current destination updated' ((Get-GoodsDetails 'Virtual Destination Buyer' $taskDir).addr -eq 'Amazon TEST2')
    foreach ($texts in @(@('Amazon FTW1 or TEST2'), @('Amazon FTW1','Amazon TEST2'), @('Amazon FTW1','Delivery address: 246 Fiction Road, Sample City 99999'), @('Amazon FTW1 or delivery address: 246 Fiction Road, Sample City 99999'))) {
        $x = Conversation $texts; $xd = Decision $x
        Check ('B10 ambiguous ' + ($texts -join '/')) ($xd.Facts.Destination.Kind -eq 'ambiguous' -and -not $xd.Facts.HasQuoteDestination -and $xd.AskFields.Count -eq 1 -and (Get-ScenarioFallback $xd) -match '(?i)which.*destination')
        Save-Snapshot $x
        Check 'B10 ambiguous goods not complete' (-not (Get-GoodsDataStatus 'Virtual Destination Buyer' $taskDir).addr)
    }
    $x = Destination @('Amazon FTW1, delivery address: 246 Fiction Road, Sample City 99999')
    Check 'B10 associated same message address retained' ($x.QuoteUsable -and $x.HasPostalAddress -and $x.WarehouseCode -eq 'FTW1')
    $x = Destination @('Amazon FTW1 or X123456')
    Check 'B10 known plus unsupported alternative remains ambiguous' ($x.Kind -eq 'ambiguous' -and -not $x.QuoteUsable)
    foreach ($text in @('53 x 41 x 32 cm, Amazon FTW1','216 kg, Amazon FTW1')) {
        $x = Conversation @($text); $xd = Decision $x; Save-Snapshot $x
        $st = Get-GoodsDataStatus 'Virtual Destination Buyer' $taskDir
        Check "B11 required cargo missing [$text]" ($xd.AskFields -notcontains 'address' -and ($xd.AskFields -contains 'weight' -or $xd.AskFields -contains 'dimension') -and ($st.weight -eq $false -or $st.dims -eq $false) -and @(Get-QuoteReadyBuyers $taskDir).Count -eq 0)
    }
    $x = Conversation @('216 kg, 53 x 41 x 32 cm, Delivery address: 246 Fiction Road, Sample City 99999')
    $xd = Decision $x
    Check 'B12 ordinary postal address usable' ($xd.Facts.HasAddress -and $xd.Facts.HasQuoteDestination -and $xd.Facts.Destination.Kind -eq 'postal_address' -and $xd.AskFields -notcontains 'address')
    $xd = Decision (Conversation @('216 kg, 53 x 41 x 32 cm, shipping to a private home'))
    Check 'B12 ordinary missing destination still asks address' ($xd.AskFields -contains 'address' -and (Get-ScenarioFallback $xd) -match 'delivery address')
    $xd = Decision (Conversation @('which address do you need from me?'))
    Check 'B12 address ownership clarification retained' ($xd.Scenario -eq 'address_clarify')
    $private = Destination @('Amazon FTW1','Instead deliver to my private address: 246 Fiction Road, Sample City 99999')
    Check 'B12 explicit switch to private address' ($private.Kind -eq 'postal_address' -and $private.WarehouseCode -eq '')
    Save-Snapshot $c
    $stateFile = Join-Path $taskDir 'reminders.json'; $script:notices = @(); $script:notifyResult = 'SENT_OK'
    function Send-WecomMessage($text) { $script:notices += $text; return $script:notifyResult }
    Check 'B13 actual goods quote reminder success' ((Send-QuoteReminders -stateFile $stateFile -snapDir $taskDir) -eq 1 -and $script:notices[0] -match '报价目的地: Amazon FTW1')
    $beforeState = [IO.File]::ReadAllText($stateFile)
    Check 'B13 same content suppressed' ((Send-QuoteReminders -stateFile $stateFile -snapDir $taskDir) -eq 0 -and $script:notices.Count -eq 1)
    $changed = Conversation @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1','Change to Amazon TEST2'); Save-Snapshot $changed
    $script:notifyResult = 'FAILED'
    Check 'B13 failed changed notification not success' ((Send-QuoteReminders -stateFile $stateFile -snapDir $taskDir) -eq 0 -and [IO.File]::ReadAllText($stateFile) -eq $beforeState)
    $script:notifyResult = 'SENT_OK'
    Check 'B13 changed destination hash permits reminder' ((Send-QuoteReminders -stateFile $stateFile -snapDir $taskDir) -eq 1 -and $script:notices[-1] -match 'Amazon TEST2' -and [IO.File]::ReadAllText($stateFile) -ne $beforeState)
    $script:manual = $true
    Check 'B14 manual takeover excluded without notification' (@(Get-QuoteReadyBuyers $taskDir).Count -eq 0 -and (Send-QuoteReminders -stateFile $stateFile -snapDir $taskDir) -eq 0)
    $script:manual = $false
    $card = ConvertTo-MessageList '[BUYER] Amazon FTW1 @@CARD:system @@MT:1791000000000'
    Check 'B14 system card cannot provide destination or generate' (-not (Get-QuoteDestination $card).QuoteUsable -and (Generate $card (Decision $card)).Source -eq 'BLOCKED')
    $old = ConvertTo-MessageList "[BUYER] Amazon FTW1`n[BUYER] Change to Amazon TEST2"
    Check 'B14 legacy conflict cannot use DOM to switch' ((Get-QuoteDestination $old).Kind -eq 'ambiguous' -and (Generate $old (Decision $old)).Source -eq 'BLOCKED')
    $singleOld = ConvertTo-MessageList '[BUYER] Amazon FTW1'
    Check 'B14 legacy single declaration conservatively useful for goods' ((Get-QuoteDestination $singleOld).QuoteUsable)
    $split = Conversation @('18 cartons, 53 x 41 x 32 cm, 216 kg gross','DDP to Amazon FTW1','Any update on my quote?')
    $splitD = Decision $split
    Check 'B15 split messages keep complete facts' ($splitD.Facts.HasWeight -and $splitD.Facts.HasDimensions -and $splitD.Facts.HasQuoteDestination -and $splitD.AskFields -notcontains 'address')
    Check 'B15 chasing quote requires human fact and no invented rate' ($splitD.NeedHumanTodo -and (Test-ReplyCompliance -Text (Get-ScenarioFallback $splitD) -Decision $splitD).Ok)
    Save-Snapshot $c; $st = Get-GoodsDataStatus 'Virtual Destination Buyer' $taskDir
    Check 'B16 report label uses warehouse without false postal claim' ((Get-GoodsDestinationLabel $st) -eq 'Amazon FTW1' -and -not $st.HasPostalAddress -and $st.addr)
    Check 'B16 real quotable metric uses same destination status' ((Get-QuotableBuyerCount $taskDir) -eq 1)
    # Execute only the real report table statements; no report I/O, config, logs or notification.
    $statusBody = (Get-Command Get-GoodsDataStatus).ScriptBlock
    $nameBody = (Get-Command Get-GoodsName).ScriptBlock
    function Get-GoodsDataStatus($buyer) { return & $statusBody $buyer $taskDir }
    function Get-GoodsName($buyer) { return & $nameBody $buyer $taskDir }
    $byBuyer = @{ 'Virtual Destination Buyer' = @() }; $sb = New-Object Text.StringBuilder
    $reportSource = Get-Content (Join-Path $repo 'scripts/summarize.ps1') -Raw -Encoding UTF8
    $reportStart = $reportSource.IndexOf('[void]$sb.AppendLine("## 货物数据齐全度')
    $reportEnd = $reportSource.IndexOf('[void]$sb.AppendLine("由 alibaba-auto-reply', $reportStart)
    Invoke-Expression $reportSource.Substring($reportStart, $reportEnd - $reportStart)
    Check 'B16 real report table displays current quote destination' ($sb.ToString() -match '\| Amazon FTW1 \|' -and $sb.ToString() -match '报价目的地' -and $sb.ToString() -notmatch '缺: 地址')
    Set-Item Function:Get-GoodsDataStatus $statusBody
    Set-Item Function:Get-GoodsName $nameBody
    foreach ($scenario in @('attachment_parse_failed','dimension_missing')) {
        $x = Conversation @('Amazon FTW1','I have no supplier and cannot give dimensions'); $xd = Decision $x $scenario
        $fb = Get-ScenarioFallback $xd
        Check "B17 fallback [$scenario] no repeated destination" ((Test-ReplyCompliance -Text $fb -Decision $xd).Ok -and $fb -notmatch 'address|zip|postal|warehouse code')
    }
} finally {
    Remove-Item -LiteralPath $taskDir -Recurse -Force
}
Write-Output "RESULT pass=$script:pass fail=$script:fail"
if ($script:fail) { exit 1 }
