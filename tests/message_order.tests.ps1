# Regression: untrusted showTime, real per-row extraction, uncertain order and system cards.
# Pure modules + AST-extracted monitor functions; only temporary files and a Node DOM stub.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib/msg_norm.ps1')
. (Join-Path $scripts 'lib/reply_policy.ps1')
. (Join-Path $scripts 'lib/reply_gen.ps1')
$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$value) {
    if ($value) { $script:pass++ } else { $script:fail++; Write-Output "FAIL: $name" }
}
function Line([string]$text, [long]$ts) { return '[BUYER] ' + $text + ' @@MT:' + $ts }
$lf = [string][char]10
$question = 'Is the rate still high for a 40ft container of modular cabins?'
$card = 'Shipping service $0.30-0.80 最小订购量: 1 Kilometer 系统自动发送'
$legacy = '[BUYER] ' + $question + ' @@TS:1791095628552' + $lf + '[ME] follow-up @@TS:1791095628556' + $lf + '[BUYER] ' + $card + ' @@TS:1791095628560'
$untrusted = ConvertTo-MessageList $legacy
Check 'legacy-render-clock-not-direction-evidence' $untrusted.Anomaly
Check 'legacy-has-no-latest-buyer' ($null -eq $untrusted.LatestBuyer)
Check 'legacy-timestamp-not-confident-identity' (-not $untrusted.Messages[0].IdConfident)
$badDecision = Get-ReplyDecision $untrusted (Get-ConversationFacts $untrusted) -ForceScenario 'new_inquiry'
Check 'untrusted-even-forced-policy-blocked' (-not $badDecision.CanReply)
Check 'blocked-policy-fallback-is-empty' ([string]::IsNullOrEmpty((Get-ScenarioFallback $badDecision)))
$script:modelCalls = 0
$script:modelContext = ''
function Invoke-LLM {
    param($Messages, $Temperature, $MaxTokens, $LogFile)
    $script:modelCalls++
    $script:modelContext = [string](@($Messages | Where-Object { $_.role -eq 'user' })[0].content)
    return 'A current rate needs checking for that container size.'
}
$blocked = Invoke-ReplyGeneration $untrusted $badDecision
Check 'blocked-model-not-called' ($script:modelCalls -eq 0 -and $blocked.Source -eq 'BLOCKED' -and -not $blocked.Text)

# Endpoints differ, but the middle reverses direction: the old endpoint shortcut missed this.
$mixed = ConvertTo-MessageList (@((Line 'first' 1791000000000), (Line 'middle' 1791000200000), (Line 'last' 1791000100000)) -join $lf)
Check 'unequal-endpoint-inversion-unverified' $mixed.Anomaly
$equal = ConvertTo-MessageList (@((Line 'first' 1791000000000), (Line 'last' 1791000000000)) -join $lf)
Check 'all-equal-clocks-unverified' $equal.Anomaly
$partial = ConvertTo-MessageList (@((Line 'first' 1791000000000), '[ME] clock missing', (Line 'last' 1791000100000)) -join $lf)
Check 'missing-interior-clock-unverified' ($partial.Anomaly -and $partial.Order.Reason -eq 'missing-message-timestamps')
$invalid = ConvertTo-MessageList (@('[BUYER] first @@MT:not-a-time', (Line 'last' 1791000100000)) -join $lf)
Check 'invalid-message-clock-unverified' $invalid.Anomaly
$duplicate = ConvertTo-MessageList (@((Line 'same' 1791000000000), (Line 'same' 1791000000000)) -join $lf)
Check 'same-content-same-second-identity-unverified' (-not $duplicate.Messages[0].IdConfident -and -not $duplicate.Messages[1].IdConfident)
$onlyCard = ConvertTo-MessageList ('[BUYER] ' + $card)
Check 'single-card-cannot-drive-policy' ($onlyCard.ReplyBlockReason -eq 'latest-buyer-system-card' -and -not $onlyCard.LatestBuyer)
$encodedCard = '[BUYER] Shipping service @@OT:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($card))
Check 'card-label-hidden-in-original-marker-is-still-guarded' ((ConvertTo-MessageList $encodedCard).ReplyBlockReason -eq 'latest-buyer-system-card')
$newCard = ConvertTo-MessageList (@((Line 'real old question' 1791000000000), (Line $card 1791000100000)) -join $lf)
Check 'latest-card-does-not-fall-back-to-old-question' (-not $newCard.LatestBuyer)
Check 'ui-label-cleaned-from-text-normalization' ((Get-NormalizedMsgText 'hello 系统自动发送') -eq 'hello')

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tokens, [ref]$errors)
Check 'monitor-parses' ($errors.Count -eq 0)
foreach ($name in @('Open-ConvoAndGetMessages', 'Generate-Reply-LLM', 'Invoke-ConvoItem', 'Get-ReplyPromptPath', 'Get-ReplyScenarioPath')) {
    $fn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
function Invoke-CdpEval([string]$js) { $script:extractJs = $js; return '{"name":"Buyer A","msgs":""}' }
function Write-Log([string]$text) { $script:logs += $text }
$script:logs = @()
$null = Open-ConvoAndGetMessages 'Buyer A'
$tempFile = Join-Path $env:TEMP ('aar_extract_' + [guid]::NewGuid().ToString('N') + '.js')
try {
    [IO.File]::WriteAllText($tempFile, $script:extractJs, (New-Object Text.UTF8Encoding($false)))
    $nodeOut = & node (Join-Path $PSScriptRoot 'message_extract.fixture.js') $tempFile
    if ($LASTEXITCODE -ne 0) { throw 'Production extractor DOM regression failed' }
    $extracted = ($nodeOut -join $lf) | ConvertFrom-Json
} finally { Remove-Item -LiteralPath $tempFile -Force }
$fixed = ConvertTo-MessageList $extracted.reverse.msgs
Check 'real-extractor-reverse-order-proven' ($fixed.Order.Confident -and -not $fixed.Order.Ascending)
Check 'real-extractor-latest-is-question' ($fixed.LatestBuyer.Orig -eq $question)
Check 'old-card-kept-for-ledger-count' ($fixed.BuyerCount -eq 2 -and @($fixed.Messages | Where-Object IsSystemCard).Count -eq 1)
Check 'newest-not-given-old-card-image' (-not $fixed.LatestBuyer.HasImage)
$facts = Get-ConversationFacts $fixed
Check 'product-card-is-not-supplier-fact' (-not $facts.HasSupplier)
$decision = Get-ReplyDecision $fixed $facts
Check 'real-extractor-policy-target-is-question' ($decision.CanReply -and $decision.LatestBuyerText -eq $question)
$context = New-ReplyContextBlock $fixed $decision
Check 'card-and-label-excluded-from-model-context' ($context -notmatch 'Shipping service|最小订购量|系统自动发送|Kilometer|@@(?:MT|TS|CARD|OT):')
Check 'question-is-model-current-message' ($context.Contains('=== CURRENT BUYER MESSAGE ===' + [Environment]::NewLine + $question))
Check 'missing-clock-despite-render-clock-remains-unverified' ((ConvertTo-MessageList $extracted.missing.msgs).Anomaly)
Check 'image-only-timestamp-survives-extraction' ((ConvertTo-MessageList $extracted.image.msgs).LatestBuyer.HasImage)

# Load only the pure Accio converter and matcher; its full test includes a live gateway probe.
$accioAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'lib/accio.ps1'), [ref]$tokens, [ref]$errors)
foreach ($name in @('ConvertTo-ReplyLines', 'Get-AccioNormText', 'Test-AccioLineMatch', 'Test-AccioLinesOverlap')) {
    $fn = $accioAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
$gateway = @(ConvertTo-ReplyLines @(
    [pscustomobject]@{ content = 'old question'; timestamp = 1791000000000; senderAliId = 2 },
    [pscustomobject]@{ content = $question; timestamp = 1791000100000; senderAliId = 2 }
) 1)
$gatewayConv = ConvertTo-MessageList ($gateway -join $lf)
Check 'gateway-message-timestamp-normalized-before-use' ($gatewayConv.Order.Confident -and $gatewayConv.LatestBuyer.Orig -eq $question)
Check 'gateway-overlap-uses-cdp-latest-not-first' (-not (Test-AccioLinesOverlap @('[BUYER] old question', ('[BUYER] ' + $question)) @('[BUYER] old question')))

# Execute the actual monitor generation adapter, without the monitor's main program.
$LogDir = $scripts
$logFile = $null
$script:notifyChannelVerified = $false
$script:lastReplyDecision = $null
$cleanLines = @('[BUYER] stale plain-text input')
$reply = Generate-Reply-LLM $null 'Buyer A' 'stale old card' $cleanLines -Conversation $fixed
Check 'monitor-adapter-reuses-verified-current-message' ($script:lastReplyDecision.LatestBuyerText -eq $question)
Check 'monitor-adapter-keeps-order-confidence' $script:lastReplyDecision.OrderConfident
Check 'monitor-adapter-model-sees-question' ($script:modelCalls -eq 1 -and $script:modelContext.Contains($question))
$noProofReply = Generate-Reply-LLM $null 'Buyer A' $question @('[BUYER] question', '[ME] no metadata')
Check 'adapter-cannot-recreate-confident-order-from-stripped-lines' (-not $noProofReply -and $script:modelCalls -eq 1)
$staleDecision = Get-ReplyDecision $fixed (Get-ConversationFacts $fixed)
$staleDecision.LatestBuyerText = 'old opening question'
$staleGeneration = Invoke-ReplyGeneration $fixed $staleDecision
Check 'generator-rejects-decision-about-an-older-message' ($staleGeneration.Source -eq 'BLOCKED' -and $script:modelCalls -eq 1)

# Both unsafe inputs stop the real monitor handler before any downstream side effect.
function Test-NoReplyBuyer { return $false }
function Open-ConvoAndGetMessages { return [pscustomobject]@{ name = 'Buyer A'; msgs = $script:unsafeRaw; profile = '' } }
function Send-OneTalkMessage { throw 'Send must never be reached' }
function Save-BuyerProfile { throw 'Profile write must never be reached' }
function Set-RepliedState { throw 'Ledger write must never be reached' }
$script:roundHalt = $false
$ctx = @{ skipCooldown = @{}; openCooldown = @{}; noReplyPreview = @{}; state = @{ replied = @{} } }
foreach ($raw in @($legacy, ('[BUYER] ' + $card))) {
    $script:unsafeRaw = $raw
    Invoke-ConvoItem $ctx ([pscustomobject]@{ name = 'Buyer A'; preview = 'invented preview' })
}
Check 'monitor-logs-unverified-and-card-skip' (($script:logs -join $lf) -match 'MSG-ORDER-UNVERIFIED' -and ($script:logs -join $lf) -match 'latest-buyer-system-card')
Check 'unsafe-handler-did-not-model-or-mutate-ledger' ($script:modelCalls -eq 1 -and $ctx.state.replied.Count -eq 0)
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
Write-Output 'ALL PASS'
