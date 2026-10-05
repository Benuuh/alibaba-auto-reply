$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$h=Get-Content (Join-Path $repo 'tests/review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000');if($cut -lt 0){throw 'HARNESS-BOUNDARY'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent',('$repo = '''+$repo+'''')))
. (Join-Path $repo 'scripts/lib/human_tasks.ps1')
. (Join-Path $repo 'scripts/lib/sent_records.ps1')
. (Join-Path $repo 'scripts/lib/goods.ps1')
. (Join-Path $repo 'scripts/lib/quote.ps1')
$realWriter=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-RepliedState'},$true)
Invoke-Expression $realWriter.Extent.Text
function Send-OneTalkMessageEx {param($buyer,$text,$Page,[switch]$AlreadyOpen,[switch]$SkipConfirmation)
$script:sends++;$script:sentText=$text;$before=@();$after=@([pscustomobject]@{MessageId=('send-'+$script:sends);MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$text;IsMine=$true})
$receipt=New-ConfirmedOutboundReceipt -Buyer $buyer -Text $text -Before $before -After $after
[pscustomobject]@{Status=$script:sendResult;Confirmed=($script:sendResult -eq 'SENT_OK');Receipt=$receipt;BeforeSnapshot=$before;Detail='fixture IO';Raw=$script:sendResult}
}
function RunCase([string]$id,[string[]]$texts,[string]$model='Happy to help with this.'){
Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:00:00';$raw=@();$ts=1791172800000L;foreach($text in $texts){$raw+=(BLine $text $ts);$ts+=1000};$ctx=Reset ($raw -join [string][char]10);$script:modelReply=$model
Invoke-ConvoItem $ctx $item | Out-Null
$ledger=Read-JsonDocument $script:stateFile
Write-Output ('LEDGER|'+$id+'|Status='+$ledger.Status+'|Entries='+(@($ledger.Data.replied.PSObject.Properties).Count))
Write-Output ('MONITOR|'+$id+'|Sends='+$script:sends+'|Calls='+$script:modelCalls+'|Text='+$script:sentText)
Write-Output ('LOGS|'+$id+'|'+($script:logs -join ' ~ '))
}
$script:reviewPass=0;$script:reviewFail=0
function ReviewAssert([string]$id,[bool]$ok,[string]$why){if($ok){$script:reviewPass++;Write-Output ('PASS|'+$id)}else{$script:reviewFail++;Write-Output ('FAIL|'+$id+'|'+$why)}}
RunCase 'unit-conflict-with-total-positive-must-send' @('Weight per carton: 10 kg.','Weight per carton: 12 kg.','Total weight: 200 kg.')
ReviewAssert 'legal-weight-clarification-preserved' ($script:sends -eq 1 -and $script:sentText -match '(?i)confirm.*weight' -and $script:sentText -match '(?i)carton sizes|packed dimensions') ('Must send actual supported weight clarification and legal missing dimensions; sent=['+$script:sentText+']')
RunCase 'supplier-contact-conflict-positive-must-send' @('Supplier contact: factory1@example.invalid.','Supplier contact: factory2@example.invalid.')
ReviewAssert 'legal-supplier-clarification-preserved' ($script:sends -eq 1 -and $script:sentText -match '(?i)confirm.*supplier' -and $script:sentText -match '(?i)weight') ('Must send actual supplier-contact clarification and legal missing weight; sent=['+$script:sentText+']')
RunCase 'ordinary-body-positive' @('I need shipping services.') 'Happy to help with this.'
ReviewAssert 'ordinary-business-body-still-sends' ($script:sends -eq 1 -and $script:sentText -match 'Happy to help with this' -and $script:sentText -match '(?i)weight') ('Sends='+$script:sends+' text='+$script:sentText)
RunCase 'unknown-body-fallback-positive' @('I need shipping services.') 'Kindly furnish the private correspondence coordinates.'
ReviewAssert 'unknown-business-body-controlled-fallback' ($script:sends -eq 1 -and $script:modelCalls -eq 2 -and $script:sentText -match '(?i)weight' -and $script:sentText -notmatch '(?i)coordinates|correspondence|private') ('Sends='+$script:sends+' Calls='+$script:modelCalls+' text='+$script:sentText)
Write-Output ('ROOT|'+$isoRoot)
Write-Output ('RESULT|pass='+$script:reviewPass+'|fail='+$script:reviewFail)
if($script:reviewFail){exit 1}