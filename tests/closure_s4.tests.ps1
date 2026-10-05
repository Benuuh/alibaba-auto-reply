$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
# Same AST extraction as existing entry test: only IO adapters are replaced, never monitor dispatch.
$h=Get-Content (Join-Path $PSScriptRoot 'review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000')
if($cut -lt 0){throw 'ENTRY-HARNESS-BOUNDARY-MISSING'}
$prefix=$h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent',('$repo = '''+$repo+''''))
Invoke-Expression $prefix
$script:closurePass=0;$script:closureFail=0
function Assert($ok,$msg='assertion failed'){if(-not $ok){throw $msg}}
function Case($id,[scriptblock]$body){try{& $body;$script:closurePass++;Write-Output "PASS $id"}catch{$script:closureFail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
$ts=1791172800000L
function Decide($q){$c=ConvertTo-MessageList (BLine $q $ts) 'Virtual Buyer';$rt=New-ReplyRuntimeContext -SellerProfile $script:sellerProfile -NowUtc $script:nowUtc;Get-ReplyDecision -Conversation $c -Facts (Get-ConversationFacts $c) -RuntimeContext $rt}
function Allowed($text,$dec){(Test-ReplyCompliance -Text $text -Decision $dec).Ok}
function Open-ConvoAndGetMessages($name){$script:reads++;if($script:advanceTimeOnSecondRead -and $script:reads -ge 2){Set-FixNow '2026-10-05T12:37:00'};return [pscustomobject]@{name=$script:pageName;msgs=$script:raw;profile=''}}
Case T01 {Set-FixNow '2026-10-05T12:00:00';$d=Decide 'What time is it in China? What time is it in Japan?';Assert (Allowed "It's 12:00 PM in China (UTC+8). It's 1:00 PM in Japan (UTC+9)." $d);Assert (-not(Allowed "It's 1:00 PM in China (UTC+9). It's 12:00 PM in Japan (UTC+8)." $d))}
Case T02 {$d=Decide 'What time is it in China?';Assert (-not(Allowed "It's 12:00 PM in China (UTC+8). It's 9:40 PM in China (UTC+8), and we can discuss the booking." $d));Assert (Allowed "It's 12:00 PM in China (UTC+8)." $d)}
Case T02-appointment-source {$d=Decide 'The pickup is at 9:40 PM. What time is it in China?';Assert (Allowed "It's 12:00 PM in China (UTC+8). The pickup is at 9:40 PM." $d);$d=Decide 'What time is it in China?';Assert (-not(Allowed "It's 12:00 PM in China (UTC+8). The pickup is at 9:40 PM." $d))}
Case T03 {$d=Decide 'What time is it in China?';Assert (-not(Allowed "It's 12:00 PM in Japan (UTC+8)." $d));Assert (Allowed "It's 12:00 PM (UTC+8)." $d)}
Case T04 {$d=Decide 'What time is it in China?';Assert (Allowed "It's 12:00 PM in China (UTC+8) on 2026-10-05." $d);Assert (-not(Allowed "It's 12:00 PM in China (UTC+8) on 2026-10-04." $d));Assert (-not(Allowed 'Today in China is 2026-10-04.' $d));Assert (-not(Allowed "It's 12:00 AM in China (UTC+8)." $d));Assert (-not(Allowed "It's 12:00 PM in China (UTC+9)." $d))}
Case T05 {foreach($q in @('What time is it in China? What time is it in Singapore?','What time is it in Beijing? What time is it in Shanghai?')){$d=Decide $q;Assert (-not(Allowed "It's 12:00 PM in China (UTC+8)." $d));Assert (Allowed $d.DirectFactText $d)};$d=Decide 'What time is it in China? What time is it in China?';Assert (Allowed $d.DirectFactText $d)}
Case T06 {$d=Decide 'What time is it in Atlantis? What time is it in Elbonia?';Assert (Allowed $d.DirectFactText $d);Assert (-not(Allowed 'A shipment can go to Atlantis or Elbonia. Which city should receive the cargo?' $d))}
Case T07 {Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'What time is it in China, what is your company, and can you help with shipping?' $ts);$script:modelReply='Happy to help with this.';$script:advanceTimeOnSecondRead=$true;Invoke-ConvoItem $ctx $item;Assert ($script:sends -eq 1) 'actual monitor send positive';Assert ($script:sentText -match 'Example Freight');Assert ($script:sentText -match '12:37 PM') 'actual clock advance retained';Assert (([regex]::Matches($script:sentText,'UTC\+8')).Count -eq 1) 'no duplicated time prefix';$script:advanceTimeOnSecondRead=$false}
Case T08 {foreach($body in @("It's 9:40 PM in China (UTC+8), and we can discuss the booking.",'At this moment the clock is half past midnight in China.','Today in China is 2026-10-04.')){Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$ctx=Reset (BLine 'What time is it in China? I need a shipping quote.' $ts);$script:modelReply=$body;Invoke-ConvoItem $ctx $item;Assert ($script:sends -eq 1) 'controlled valid reply must reach actual send stub';Assert (-not $script:sentText.Contains($body)) 'bad business body cannot reach send';Assert ($script:modelCalls -le 2)} }
Write-Output "RESULT closure_s4 pass=$script:closurePass fail=$script:closureFail root=$isoRoot"
if($script:closureFail){exit 1}
