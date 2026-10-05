$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/reply_engine.ps1')
. (Join-Path $repo 'scripts/lib/msg_norm.ps1')
. (Join-Path $repo 'scripts/lib/reply_policy.ps1')
. (Join-Path $repo 'scripts/lib/reply_gen.ps1')
$script:pass=0;$script:fail=0
function Assert($ok,$msg='assertion failed'){if(-not $ok){throw $msg}}
function Case($id,[scriptblock]$body){try{& $body;$script:pass++;Write-Output "PASS $id"}catch{$script:fail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
function CF($texts){$n=1791172800000L;$raw=@();foreach($t in $texts){$raw+='[BUYER] '+$t+' @@TS:'+$n+' @@MT:'+$n+' @@OT:'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)));$n+=1000};Get-ConversationFacts (ConvertTo-MessageList ($raw -join "`n") 'Closure Buyer')}
function Dec($ask,$facts){[pscustomobject]@{AskFields=@($ask);Facts=$facts;RequestedFacts=@();ActionEvidence=$null;ClarifyFields=@()}}
function Allowed($text,$dec){(Test-ReplyCompliance -Text $text -Decision $dec).Ok}
$none=CF @('I need freight service.')
Case P01 {foreach($sep in @('and',',','plus','as well as','together with')){Assert (-not (Allowed ("Please share the supplier's contact details for packing "+$sep+' contact details so we can reach you.') (Dec @('supplier') $none))) $sep}}
Case P02 {foreach($text in @("Please share the recipient's name and provide phone number so we can reach you.","Please share the recipient's name and your email.","Please share the supplier's contact for packing and contact details so we can reach you.")){Assert (-not (Allowed $text (Dec @('recipient_name','supplier_contact') $none)))}}
Case P03 {Assert (Allowed "Please share the supplier's contact details for packing." (Dec @('supplier') $none));Assert (Allowed 'Supplier contact details help us verify packing.' (Dec @() $none));Assert (-not (Allowed 'I have received and stored the supplier contact details.' (Dec @() $none)))}
Case P04 {foreach($text in @('My email is agent@example.invalid.','You can email me.','Please give your private phone number.')){Assert (-not (Allowed $text (Dec @('supplier') $none)))}}
Case P05 {foreach($text in @("Could you share the recipient's name and phone number for delivery?","Could you share the recipient's phone number and name for delivery?")){Assert (-not (Allowed $text (Dec @('recipient_contact') $none)))};Assert (Allowed "Please share the recipient's phone number for delivery." (Dec @('recipient_contact') (CF @('Consignee name: Alex.'))))}
Case P06 {Assert (-not (Allowed 'Please share the total weight and packed dimensions.' (Dec @('weight') $none)));Assert (Allowed 'Please share the total weight.' (Dec @('weight') $none))}
Case P07 {Assert (-not (Allowed 'Please share the total weight.' (Dec @('weight') (CF @('Total weight: 20 kg.')))));Assert (-not (Allowed "Please share the recipient's phone number for delivery." (Dec @() $none)))}
Case P08 {$f=CF @('20 cartons.','24 cartons.');$d=Dec @('weight') $f;Assert (Allowed 'Could you confirm whether the carton count is 20 or 24?' $d);foreach($text in @('Which carton count is correct - 999 or 1000?','Which carton count is correct - nine hundred ninety-nine or one thousand?','Which carton count is correct - 20 bags or 24 bags?')){Assert (-not (Allowed $text $d)) $text}}
Case P09 { $f=CF @('Dimensions per carton: 50x40x30 cm.','Dimensions per carton: 60x50x40 cm.');$d=Dec @('weight') $f;Assert (-not(Allowed 'Could you confirm whether the dimensions per carton are 50x40x30 inches or 60x50x40 inches?' $d));$f=CF @('Total weight: 20 kg.','Total weight: 24 kg.');Assert (-not(Allowed 'Could you confirm whether the weight per carton is 20 kg or 24 kg?' (Dec @('dimension') $f))) }
Case P10 { $f=CF @('Consignee name: Alex.','Consignee name: Bob.');$d=Dec @('weight') $f;Assert (Allowed "Could you confirm whether the recipient's name is Alex or Bob?" $d);Assert (-not(Allowed "Could you confirm whether the recipient's name is Nobody or Stranger?" $d));$f=CF @('Amazon delivery to FTW1.','Amazon delivery to ONT8.');Assert (-not(Allowed 'Could you confirm which delivery destination we should use - London or Paris?' (Dec @('weight') $f))) }
function Invoke-LLM {param($Messages,$Temperature,$MaxTokens,$LogFile);$script:calls++;return 'Kindly furnish the unregistered private correspondence coordinates; our supplier has confirmed 999 kg.'}
Case P11 { $c=ConvertTo-MessageList '[BUYER] Can you help with shipping?' 'Closure Buyer';$f=Get-ConversationFacts $c;$d=Get-ReplyDecision -Conversation $c -Facts $f;$script:calls=0;$g=Invoke-ReplyGeneration -Conversation $c -Decision $d -PromptPath (Join-Path $repo 'scripts/reply_agent_prompt.md');Assert ($g.Text -and $g.Text -notmatch 'coordinates|999|confirmed') 'unknown model text discarded; controlled positive survives';Assert ($g.Rewrites -le 1 -and $script:calls -le 2);Assert (Test-ReplyCompliance -Text $g.Text -Decision $d).Ok }
Write-Output "RESULT closure_s2 pass=$script:pass fail=$script:fail"
if($script:fail){exit 1}
