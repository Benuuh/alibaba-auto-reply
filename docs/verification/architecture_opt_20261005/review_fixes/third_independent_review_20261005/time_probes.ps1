$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$h=Get-Content -LiteralPath "$repo\tests\review_fixes_entry.tests.ps1" -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000')
if($cut -lt 0){throw 'Harness boundary missing'}
$p=$h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + ''''))
Invoke-Expression $p
$script:reviewPass=0
$script:reviewFail=0
function Expect-Review([string]$n,[bool]$ok){if($ok){$script:reviewPass++}else{$script:reviewFail++;Write-Output ('INDEPENDENT-FAIL: '+$n)}}
Set-FixNow '2026-10-05T12:00:00'
$ts=[long]1791172800000
function Out-Probe([string]$Name,$Data){[pscustomobject]@{Probe=$Name;Data=$Data}|ConvertTo-Json -Depth 12 -Compress|Write-Output}
function Decide([string]$q){$c=ConvertTo-MessageList (BLine $q $ts) 'Virtual Buyer';$rt=New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc $script:nowUtc;Get-ReplyDecision -Conversation $c -Facts (Get-ConversationFacts $c) -Rules $null -RuntimeContext $rt}
$d=Decide 'What time is it in China?'
foreach($txt in @("It's 12:00 PM in China (UTC+8). It's 9:40 PM in China (UTC+8), and we can discuss the booking.","It's 12:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+8).","It's 12:00 PM in China (UTC+8) on 2026-10-04.")){
$r=Test-ReplyCompliance -Text $txt -Decision $d
Expect-Review 'wrong-time-text-must-block' (-not [bool]$r.Ok)
Out-Probe 'time-entire-text-check' @{Text=$txt;Ok=$r.Ok;Codes=@($r.Violations|ForEach-Object{$_.Code});Claims=@(Get-OutputTimeClaims $txt)}
}
$d=Decide 'What time is it in Beijing? What time is it in Shanghai?'
$r=Test-ReplyCompliance -Text "It's 12:00 PM in China (UTC+8)." -Decision $d
Expect-Review 'two-cities-country-only-must-not-cover-both' (-not [bool]$r.Ok)
Out-Probe 'two-cities-country-alias' @{Ok=$r.Ok;Codes=@($r.Violations|ForEach-Object{$_.Code});Targets=$d.TimeTargets;Expected=@(Get-TimeExpectations -TimeTargets $d.TimeTargets -RuntimeContext $d.RuntimeContext)}
$d=Decide 'What time is it in Atlantis? What time is it in Elbonia?'
$txt='A shipment can go to Atlantis or Elbonia. Which city should receive the cargo?'
$r=Test-ReplyCompliance -Text $txt -Decision $d
Expect-Review 'unrelated-cargo-question-must-not-answer-time' (-not [bool]$r.Ok)
Out-Probe 'unknown-place-business-question' @{Text=$txt;Ok=$r.Ok;Codes=@($r.Violations|ForEach-Object{$_.Code})}
foreach($txt in @("It's 9:40 PM in China (UTC+8), and we can discuss the booking.","It's 12:00 PM in Japan (UTC+8).","It's 12:00 PM in China (UTC+8) on 2026-10-04.")){
Clear-PauseState
Clear-TaskState
Set-FixNow '2026-10-05T12:00:00'
$ctx=Reset (BLine 'What time is it in China? I need a shipping quote.' $ts)
$script:modelReply=$txt
Invoke-ConvoItem $ctx $item
Expect-Review 'wrong-time-body-must-not-reach-send' (-not [bool]($script:sends -gt 0 -and $script:sentText.Contains($txt)))
Out-Probe 'time-real-monitor-entry' @{ModelText=$txt;Sends=$script:sends;Text=$script:sentText;Calls=$script:modelCalls;Logs=@($script:logs|Where-Object{$_ -match 'REPLY-GEN|SEND-GATE|FACT-COMPOSITION'})}
}
Out-Probe 'isolated-root' $isoRoot
$goodDec=Decide 'What time is it in China?'
$good=Test-ReplyCompliance -Text "It's 12:00 PM in China (UTC+8)." -Decision $goodDec
Expect-Review 'correct-China-time-must-pass' ([bool]$good.Ok)
Out-Probe 'independent-time-assertions' @{Pass=$script:reviewPass;Fail=$script:reviewFail}
if($script:reviewFail -gt 0){exit 1}

