$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
. (Join-Path $repo 'scripts/reply_engine.ps1')
. (Join-Path $repo 'scripts/lib/msg_norm.ps1')
. (Join-Path $repo 'scripts/lib/reply_policy.ps1')
. (Join-Path $repo 'scripts/lib/reply_gen.ps1')
function BLineLocal([string]$t,[long]$ts){'[BUYER] '+$t+' @@TS:'+$ts+' @@MT:'+$ts+' @@OT:'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)))}
function MakeConv($texts){$n=1791172800000L;$raw=@();foreach($t in $texts){$raw+=(BLineLocal $t $n);$n+=1000};ConvertTo-MessageList ($raw -join [string][char]10) 'Virtual Buyer'}
function MakeDec($ask,$facts){[pscustomobject]@{CanReply=$true;AskFields=@($ask);Facts=$facts;RequestedFacts=@();ActionEvidence=$null;ClarifyFields=@();FactOnly=$false;DirectFactText='';LatestBuyerText=''} }
function Show($id,$text,$dec){$r=Test-ReplyCompliance -Text $text -Decision $dec;Write-Output ('CHECK|'+$id+'|Ok='+$r.Ok+'|Codes='+(@($r.Violations|ForEach-Object{$_.Code})-join ',')+'|Text='+$text)}
function Invoke-LLM{param($Messages,$Temperature,$MaxTokens,$LogFile);return $script:modelReply}
$script:modelReply='Happy to help with this.'
function Gen($id,$texts,$askOverride=$null){
$c=MakeConv $texts;$f=Get-ConversationFacts $c;$d=Get-ReplyDecision -Conversation $c -Facts $f
if($null -ne $askOverride){$d.AskFields=@($askOverride)}
$p=New-ResponsePlan $d;$r=Render-ResponsePlan $p;$g=Invoke-ReplyGeneration -Conversation $c -Decision $d -PromptPath (Join-Path $repo 'scripts/reply_agent_prompt.md')
Write-Output ('GEN|'+$id+'|Scenario='+$d.Scenario+'|Ask='+(@($d.AskFields)-join ',')+'|Clarify='+(@($p.ClarificationRequests|ForEach-Object{$_.FieldKey})-join ',')+'|Source='+$g.Source+'|Codes='+(@($g.Violations|ForEach-Object{$_.Code})-join ',')+'|Text='+$g.Text+'|Rendered='+$r)
return
}
$none=Get-ConversationFacts (MakeConv @('I need freight service.'))
foreach($sep in @('and',',','plus','as well as','together with')){Show ('redline-'+$sep) ("Please share the supplier's contact details for packing "+$sep+' contact details so we can reach you.') (MakeDec @('supplier') $none)}
Show 'name-phone-reverse' "Could you share the recipient's phone number and name for delivery?" (MakeDec @('recipient_contact') $none)
Show 'weight-extra-dimensions' 'Please share the total weight and packed dimensions.' (MakeDec @('weight') $none)
Gen 'total-conflict-no-collect' @('Total weight: 20 kg.','Total weight: 24 kg.') @('dimension')
Gen 'dimensions-conflict-no-collect' @('Dimensions per carton: 50x40x30 cm.','Dimensions per carton: 60x50x40 cm.') @('weight')
Gen 'unit-conflict-plus-provided-total' @('Weight per carton: 10 kg.','Weight per carton: 12 kg.','Total weight: 200 kg.')
Gen 'dimensions-conflict-plus-complete-minimum' @('Dimensions per carton: 50x40x30 cm.','Dimensions per carton: 60x50x40 cm.','10 cartons, total weight 200 kg, delivery to Amazon FTW1.')
Gen 'name-conflict' @('Consignee name: Alex.','Consignee name: Bob.') @('weight')
Gen 'contact-conflict' @('Recipient contact: +1 555 0100.','Recipient contact: +1 555 0200.') @('weight')
Gen 'supplier-contact-conflict' @('Supplier contact: factory1@example.invalid.','Supplier contact: factory2@example.invalid.') @('weight')
Gen 'refusal-with-prior-conflict' @('Total weight: 20 kg.','Total weight: 24 kg.','No thanks, stop asking.')
Gen 'process-explain' @('How does the shipping process work?')
Gen 'billing-explain' @('How is chargeable weight calculated?')
Gen 'unassigned-contact' @('Contact: alex@example.invalid.')
$fc=Get-ConversationFacts (MakeConv @('20 cartons.','24 cartons.'))
foreach($txt in @('Which carton count should we use - 20 or 24?','Which carton count can you provide for the quote?','Please share the carton count, which we need for the quote.')){Show 'count-check' $txt (MakeDec @('weight') $fc)}
$cf=Get-ConversationFacts (MakeConv @('Weight per carton: 10 kg.','Weight per carton: 12 kg.','Total weight: 200 kg.'))
$dd=MakeDec @('dimension','address') $cf
$open='Could you confirm which weight and its packaging scope we should use?'
Write-Output ('REQUEST_ITEMS|open-weight|'+((@(Get-ReplyRequestItems -Text $open -Decision $dd)|Select-Object Text,Kind,FieldKey,ClarifyRef,VerbSource|ConvertTo-Json -Depth 6 -Compress)))
$cf=Get-ConversationFacts (MakeConv @('Supplier contact: factory1@example.invalid.','Supplier contact: factory2@example.invalid.'));$dd=MakeDec @('weight') $cf
$open="Could you confirm which supplier's business contact we should use?"
Write-Output ('REQUEST_ITEMS|open-supplier-contact|'+((@(Get-ReplyRequestItems -Text $open -Decision $dd)|Select-Object Text,Kind,FieldKey,Role,ClarifyRef,Raw|ConvertTo-Json -Depth 6 -Compress)))
$profile=Get-SellerProfile -Config ('{"seller_profile":{"company_name_en":"Example Freight","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'|ConvertFrom-Json)
$runtime=New-ReplyRuntimeContext -SellerProfile $profile -NowUtc ([datetime]'2026-10-05T04:00:00Z')
$c=MakeConv @('Consignee name: Alex.','Consignee name: Bob.','What time is it in China?');$f=Get-ConversationFacts $c;$d=Get-ReplyDecision -Conversation $c -Facts $f -RuntimeContext $runtime;$g=Invoke-ReplyGeneration -Conversation $c -Decision $d -RuntimeContext $runtime -PromptPath (Join-Path $repo 'scripts/reply_agent_prompt.md');Write-Output ('GEN|fact-only-prior-conflict|FactOnly='+$d.FactOnly+'|Ask='+(@($d.AskFields)-join ',')+'|Source='+$g.Source+'|Text='+$g.Text)
Gen 'address-conflict-positive' @('Amazon delivery to FTW1.','Amazon delivery to ONT8.')
foreach($t in @("Thanks, I have your supplier's contact on file.",'The supplier already gave us their contact person.','Thanks for the contact list.')){Show 'old-C05-no-evidence' $t (MakeDec @('supplier') $none)}