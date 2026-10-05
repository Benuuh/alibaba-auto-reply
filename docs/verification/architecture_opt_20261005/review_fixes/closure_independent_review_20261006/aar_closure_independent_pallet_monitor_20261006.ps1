$ErrorActionPreference='Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$h=Get-Content -LiteralPath (Join-Path $repo 'tests/review_fixes_entry.tests.ps1') -Raw -Encoding UTF8
$cut=$h.IndexOf('$ts0 = [long]1791172800000');if($cut -lt 0){throw 'HARNESS-BOUNDARY'}
Invoke-Expression ($h.Substring(0,$cut).Replace('$repo = Split-Path $here -Parent', ('$repo = ''' + $repo.Replace("'", "''") + '''')))
. (Join-Path $repo 'scripts/lib/human_tasks.ps1')
. (Join-Path $repo 'scripts/lib/sent_records.ps1')
$script:reviewPass=0;$script:reviewFail=0
function Check($id,$ok){if($ok){$script:reviewPass++;Write-Output ('PASS '+$id)}else{$script:reviewFail++;Write-Output ('FAIL '+$id)}}
foreach($packageUnit in @('cartons','pallets')){
 Clear-PauseState;Clear-TaskState;Set-FixNow '2026-10-05T12:02:00'
 $task=New-OrUpdate-SupplierVerificationTask -Buyer 'Virtual Buyer' -SupplierContact 'factory@example.invalid' -TriggerMessage 'Please verify the packing.' -TriggerAt '2026-10-05T04:00:00Z' -MissingFields @('carton_count','unit_weight','unit_dimensions','delivery_address')
 $fields=@(@{FieldKey='carton_count';Value='2';Unit=$packageUnit;Scope='cartons'},@{FieldKey='unit_weight';Value='12';Unit='kg';Scope='unit'},@{FieldKey='unit_dimensions';Value='50x40x30';Unit='cm';Scope='unit'},@{FieldKey='delivery_address';Value='Amazon FTW1';Unit='';Scope='destination'})
 $r=Add-HumanTaskActionRecord -Id $task.Task.id -ActionKind supplier_reply -Source operator-entry -RecordedBy 'fictional operator' -SourceRef 'fictional:packing' -AtUtc '2026-10-05T04:01:00Z' -RawContent ('Supplier confirmed 2 '+$packageUnit+' and the packed values.') -ConfirmedFields $fields
 if(-not $r.Ok -or -not (Set-HumanTaskStatus -Id $task.Task.id -Status resolved)){throw 'VALID-TASK-FIXTURE-FAILED'}
 $ctx=Reset (BLine 'Has the supplier confirmed the packing?' 1791172920000L);$script:modelReply='Happy to help with this.'
 Invoke-ConvoItem $ctx $item|Out-Null
 [pscustomobject]@{Unit=$packageUnit;Sends=$script:sends;Text=$script:sentText;Logs=@($script:logs|Where-Object {$_ -match 'BLOCK|DIRTY|REPLY-GEN'})}|ConvertTo-Json -Compress|Write-Output
 Check ('legal-'+$packageUnit+'-confirmation-preserved') ($script:sends -eq 1 -and $script:sentText -match ('supplier confirmed 2 '+$packageUnit))
}
Write-Output ('RESULT independent_pallet_monitor pass='+$script:reviewPass+' fail='+$script:reviewFail+' root='+$isoRoot)
if($script:reviewFail){exit 1}