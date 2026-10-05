$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
. (Join-Path $repo 'scripts/reply_engine.ps1')
. (Join-Path $repo 'scripts/lib/msg_norm.ps1')
. (Join-Path $repo 'scripts/lib/reply_policy.ps1')
$script:pass=0;$script:fail=0
function Check($name,$ok){if($ok){$script:pass++;Write-Output ('PASS '+$name)}else{$script:fail++;Write-Output ('FAIL '+$name)}}
$d=[pscustomobject]@{AskFields=@('supplier');Facts=$null;RequestedFacts=@();ActionEvidence=$null}
foreach($text in @('Thanks, I have your supplier''s contact on file.','The supplier already gave us their contact person.')){
 $r=Test-ReplyCompliance -Text $text -Decision $d
 [pscustomobject]@{Text=$text;Ok=$r.Ok;Codes=@($r.Violations|ForEach-Object {$_.Code});FactsPresent=($null -ne $d.Facts)}|ConvertTo-Json -Compress|Write-Output
 Check ('missing-evidence-must-block-'+$text) (-not $r.Ok)
}
Check 'ordinary-contact-explanation-positive' (Test-ReplyCompliance -Text 'Supplier contact details help us verify packing.' -Decision $d).Ok
Check 'generic-contact-redline-negative' (-not (Test-ReplyCompliance -Text 'Could you share your phone number?' -Decision $d).Ok)
Write-Output ('RESULT independent_c05 pass='+$script:pass+' fail='+$script:fail)
if($script:fail){exit 1}