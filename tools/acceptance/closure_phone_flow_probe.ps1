$ErrorActionPreference='Stop';$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'scripts/lib/msg_norm.ps1');. (Join-Path $repo 'scripts/lib/quote.ps1');$root=Join-Path $env:TEMP ('aar-phone-flow-'+[guid]::NewGuid().ToString('N'));[void](Initialize-AarIsolation $root)
$t=New-OrUpdate-SupplierVerificationTask -Buyer 'Phone Flow Buyer' -SupplierContact '+15551234001' -TriggerMessage 'Supplier phone +15551234001. Please verify packing.' -TriggerAt '2026-10-05T04:00:00Z' -MissingFields @('carton_count','unit_weight','unit_dimensions','delivery_address')
$good=@(@{FieldKey='carton_count';Value='10';Unit='cartons';Scope='cartons'},@{FieldKey='unit_weight';Value='12';Unit='kg';Scope='unit'},@{FieldKey='unit_dimensions';Value='50x40x30';Unit='cm';Scope='unit'},@{FieldKey='delivery_address';Value='Amazon FTW1';Scope='destination'})
[void](Add-HumanTaskActionRecord -Id $t.Task.id -ActionKind supplier_reply -Source operator-entry -RecordedBy 'fixture operator' -SourceRef 'fixture:phone-call' -AtUtc '2026-10-05T04:01:00Z' -RawContent 'Supplier gave these packing values' -ConfirmedFields $good)
$r=Get-QuoteReadinessForConversationText -Text '[BUYER] The supplier phone is now +15551234002. Can you quote? @@MT:1791172920000' -ConvoName 'Phone Flow Buyer' -WithTaskEvidence
Write-Output ('PHONE-IDENTITY-CHANGE old='+$t.Task.FlowId+' current='+(Get-CurrentCargoFlow 'Phone Flow Buyer').Id+' ready='+$r.Ready+' root='+$root)
if($r.Ready){Write-Output 'FAIL D02-phone-flow';exit 1};Write-Output 'PASS D02-phone-flow';exit 0
