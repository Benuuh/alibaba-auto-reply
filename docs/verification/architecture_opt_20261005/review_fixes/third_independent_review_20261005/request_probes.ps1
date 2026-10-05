$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
. (Join-Path $repo 'scripts\reply_engine.ps1')
. (Join-Path $repo 'scripts\lib\msg_norm.ps1')
. (Join-Path $repo 'scripts\lib\reply_policy.ps1')
. (Join-Path $repo 'scripts\lib\reply_gen.ps1')
function Dec($Ask,$Facts) { [pscustomobject]@{ AskFields=@($Ask);Facts=$Facts;RequestedFacts=@();ActionEvidence=$null;ClarifyFields=@() } }
function BL([string]$t,[long]$ts) { '[BUYER] '+$t+' @@TS:'+$ts+' @@MT:'+$ts+' @@OT:'+([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t))) }
function CF($Texts) { $a=@();$n=1791172800000L;foreach($t in $Texts){$a+=(BL $t $n);$n+=1000}; Get-ConversationFacts (ConvertTo-MessageList ($a -join [string][char]10) 'Virtual Buyer') }
function Probe($Id,$Text,$Decision) {
$r=Test-ReplyCompliance -Text $Text -Rules $null -Decision $Decision
Write-Output ('RESULT|'+$Id+'|Ok='+[string]$r.Ok+'|Codes='+(@($r.Violations | ForEach-Object{[string]$_.Code}) -join ',')+'|Text='+$Text)
Write-Output ('ITEMS|'+$Id+'|'+((@(Get-ReplyRequestItems -Text $Text -Decision $Decision)|ForEach-Object{[string]$_.Role+':'+[string]$_.FieldKey+':'+[string]$_.Verb+':'+[string]$_.Raw})-join '|'))
}
$none=CF @('I need freight service.')
$recipient=Dec @('recipient_contact') $none
Probe 'field-name-only-contact-authorized' "Could you share the recipient's name for delivery?" $recipient
Probe 'explicit-new-verb-inherited-role' "Please share the recipient's name and provide phone number so we can reach you." $recipient
Probe 'tight-role-list-name-last' "Could you share the recipient's phone number and name for delivery?" (Dec @('recipient_contact') (CF @('Consignee name: Alex.')))
Probe 'purpose-only-no-role' 'Could you share the delivery phone number?' $recipient
Probe 'separate-role-and-generic-same-clause' "Could you share the supplier's contact details as well as contact details so we can reach you?" (Dec @('supplier') $none)
Probe 'same-clause-role-before-generic' "Please provide the supplier's contact details together with contact details so we can reach you." (Dec @('supplier') $none)
Probe 'empty-ask-still-authorized-by-purpose' "Please share the recipient's phone number for delivery." (Dec @() $none)
$weight=CF @('Total weight: 20 kg.'); Probe 'provided-authorized-weight' 'Could you share the total weight?' (Dec @('weight') $weight)
$count=CF @('20 cartons.','24 cartons.'); $countDec=Dec @('weight') $count
Probe 'count-original-bad' 'Which carton count is correct - 999 or 1000?' $countDec
Probe 'count-original-good' 'Could you confirm whether the carton count is 20 or 24?' $countDec
Probe 'count-kg-split' 'Which carton count is correct - 20 or 24 kg?' $countDec
Probe 'count-written-invented' 'Which carton count is correct - nine hundred ninety-nine or one thousand?' $countDec
Probe 'count-collection-tail-inherited' 'Could you confirm whether the carton count is 20 or 24 and dimensions?' $countDec
$dim=CF @('Dimensions per carton: 50x40x30 cm.','Dimensions per carton: 60x50x40 cm.');$dimDec=Dec @('weight') $dim
Probe 'dim-unit-change' 'Could you confirm whether the dimensions per carton are 50x40x30 inches or 60x50x40 inches?' $dimDec
Probe 'dim-scope-change' 'Could you confirm whether the dimensions of the full shipment are 50x40x30 cm or 60x50x40 cm?' $dimDec
$wconf=CF @('Total weight: 20 kg.','Total weight: 24 kg.');$wdec=Dec @('dimension') $wconf
Probe 'weight-scope-change' 'Could you confirm whether the weight per carton is 20 kg or 24 kg?' $wdec
$dest=CF @('Ship to Hamburg.','Ship to Shanghai.');$ddec=Dec @('weight') $dest
Probe 'destination-invented' 'Could you confirm which delivery destination we should use - London or Paris?' $ddec
Write-Output ('CLARIFICATIONS|count|'+((@(Get-ReplyClarificationRequests -Facts $count -Decision $countDec)|ConvertTo-Json -Depth 8 -Compress)))
Write-Output ('CLARIFICATIONS|dim|'+((@(Get-ReplyClarificationRequests -Facts $dim -Decision $dimDec)|ConvertTo-Json -Depth 8 -Compress)))
Write-Output ('CLARIFICATIONS|weight|'+((@(Get-ReplyClarificationRequests -Facts $wconf -Decision $wdec)|ConvertTo-Json -Depth 8 -Compress)))
Write-Output ('CLARIFICATIONS|destination|'+((@(Get-ReplyClarificationRequests -Facts $dest -Decision $ddec)|ConvertTo-Json -Depth 8 -Compress)))
Probe 'no-inherited-dimension-check' 'Please share the total weight and packed dimensions.' (Dec @('weight') $none)
Probe 'count-unrecognized-unit' 'Which carton count is correct - 20 bags or 24 bags?' $countDec
$dest2=CF @('Amazon delivery to FTW1.','Amazon delivery to ONT8.'); $ddec2=Dec @('weight') $dest2
Probe 'real-destination-invented' 'Could you confirm which delivery destination we should use - London or Paris?' $ddec2
Write-Output ('CLARIFICATIONS|real-destination|'+((@(Get-ReplyClarificationRequests -Facts $dest2 -Decision $ddec2)|ConvertTo-Json -Depth 8 -Compress)))
$nconf=CF @('Consignee name: Alex.','Consignee name: Bob.'); $ndec=Dec @('weight') $nconf
Probe 'recipient-name-real-clarify' "Could you confirm whether the recipient's name is Alex or Bob?" $ndec
Probe 'recipient-name-invented-clarify' "Could you confirm whether the recipient's name is Nobody or Stranger?" (Dec @('recipient_name') $nconf)
function Invoke-LLM($Messages,$Temperature,$MaxTokens,$LogFile) { $script:ModelText }
function GenProbe([string]$Id,[string[]]$Messages,[string]$ModelText,$OverrideAsk=$null) {
$raw=@();$tsgen=1791172800000L;foreach($txtgen in $Messages){$raw+=(BL $txtgen $tsgen);$tsgen+=1000}
$convgen=ConvertTo-MessageList ($raw -join [string][char]10) 'Virtual Buyer'
$factgen=Get-ConversationFacts $convgen
$decgen=Get-ReplyDecision -Conversation $convgen -Facts $factgen
if($null -ne $OverrideAsk){$decgen.AskFields=@($OverrideAsk)}
$script:ModelText=$ModelText
$gen=Invoke-ReplyGeneration -Conversation $convgen -Decision $decgen -Rules $null -PromptPath (Join-Path $repo 'scripts\reply_agent_prompt.md') -ScenarioPath (Join-Path $repo 'scripts\reply_scenarios.md') -MaxRewrites 1
Write-Output ('GEN|'+$Id+'|Source='+[string]$gen.Source+'|Calls='+[string]$gen.ModelCalls+'|Rewrites='+[string]$gen.Rewrites+'|Ask='+(@($decgen.AskFields)-join ',')+'|Text='+[string]$gen.Text)
}
GenProbe 'generic-contact-reaches-generation' @('I do not know the dimensions, can you help?') "Please provide the supplier's contact details together with contact details so we can reach you."
GenProbe 'name-provided-reaches-generation' @('Consignee name: Alex.','Can you help with shipping?') "Could you share the recipient's phone number and name for delivery?" @('recipient_contact')
GenProbe 'dimensions-inches-reaches-generation' @('Dimensions per carton: 50x40x30 cm.','Dimensions per carton: 60x50x40 cm.') 'Could you confirm whether the dimensions per carton are 50x40x30 inches or 60x50x40 inches?'
GenProbe 'explicit-verb-redline-reaches-generation' @('Can you help with shipping?') "Please share the recipient's name and provide phone number so we can reach you." @('recipient_contact')
GenProbe 'contact-authorizes-name-reaches-generation' @('Can you help with shipping?') "Could you share the recipient's name for delivery?" @('recipient_contact')
GenProbe 'weight-scope-reaches-generation' @('Total weight: 20 kg.','Total weight: 24 kg.') 'Could you confirm whether the weight per carton is 20 kg or 24 kg?'
GenProbe 'inherited-dimensions-reaches-generation' @('Can you help with shipping?') 'Please share the total weight and packed dimensions.' @('weight')
GenProbe 'real-destination-invented-reaches-generation' @('Amazon delivery to FTW1.','Amazon delivery to ONT8.') 'Could you confirm which delivery destination we should use - London or Paris?'
GenProbe 'refusal-no-ask-ignored' @('I am not interested, thanks.') "Please share the recipient's phone number for delivery."
Probe 'original-contact-after-and-blocked' "Please share the supplier's contact details for packing and contact details so we can reach you." (Dec @('supplier') $none)
Probe 'R4-good-phone-name-provided' "Please share the recipient's phone number for delivery." (Dec @('recipient_contact') (CF @('Consignee name: Alex.')))
Probe 'R4-direct-already-provided-name-blocked' "Could you share the recipient's name for delivery?" (Dec @('recipient_contact') (CF @('Consignee name: Alex.')))