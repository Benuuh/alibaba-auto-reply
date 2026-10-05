# baseprobe.ps1 - shared baseline harness for the 2026-10-05 architecture-review spec.
# FICTIONAL DATA ONLY. Isolated runtime root + isolation marker. No browser, no model, no send,
# no notification, no production path is touched.
param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
while ($repo -and -not (Test-Path -LiteralPath (Join-Path $repo 'scripts/config.ps1'))) { $repo = Split-Path $repo -Parent }
if (-not $repo) { throw 'Repository root not found' }
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
$isoRoot = Join-Path $env:TEMP ('aar-baseprobe-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot

. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\msg_source.ps1')
. (Join-Path $scripts 'lib\contact_rules.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\sent_records.ps1')
. (Join-Path $scripts 'lib\human_pause.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')

$lines = New-Object System.Collections.ArrayList
function Emit([string]$s) { [void]$lines.Add($s); Write-Output $s }
$script:fails = New-Object System.Collections.ArrayList
function Case([string]$id, [string]$desc, [bool]$expected, [bool]$actual, [string]$detail = '') {
    $ok = ($expected -eq $actual)
    $verdict = 'PASS'
    if (-not $ok) { $verdict = 'FAIL'; [void]$script:fails.Add($id) }
    Emit ("  [{0}] {1} {2} expected={3} actual={4} {5}" -f $verdict, $id, $desc, $expected, $actual, $detail)
}

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function MeLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts) }
function HumanLine([string]$t, [long]$ts) { return ('[ME] ' + $t + ' @@MT:' + $ts) }
function Conv([string[]]$l) { return (ConvertTo-MessageList ($l -join $LF) 'Buyer A') }

$P_FULL = '{"seller_profile":{"company_name_en":"Example Freight","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$prof = Get-SellerProfile -Config ($P_FULL | ConvertFrom-Json)
$utc = [datetime]::SpecifyKind([datetime]::Parse('2026-10-05T06:05:00', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
function Ctx($p, [datetime]$t) { return (New-ReplyRuntimeContext -SellerProfile $p -NowUtc $t) }
function Decide([string[]]$l, $rt) { $c = Conv $l; return (Get-ReplyDecision -Conversation $c -Facts (Get-ConversationFacts $c) -Rules $null -RuntimeContext $rt) }
function Codes($r) { return (@($r.Violations | Where-Object { $_.Severity -eq 'block' } | ForEach-Object { $_.Code }) -join ',') }

Emit ('RUNTIME-MODE: ' + (Format-AarRuntimeBanner))
Emit ('ISOLATED: ' + (Test-AarIsolatedRuntime))
Emit ('ISOROOT: ' + $isoRoot)
Emit ''

# ============================================================================================
Emit '=== A1 最高优先级联系方式红线漏拦 ==='
$a1ask = [pscustomobject]@{ AskFields = @(); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
foreach ($t in @(
    'You can email me if that is easier.',
    'You can email us if that is easier.',
    'Please leave a phone number for delivery updates.',
    'Please leave a contact number for delivery updates.',
    'We''ll contact your supplier directly and you can email me if easier.')) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $a1ask
    Case ('A1-block[' + $t.Substring(0, [Math]::Min(40, $t.Length)) + ']') 'must be blocked' $false $r.Ok ('codes=' + (Codes $r))
}
foreach ($pair in @(
    @{ t = "Could you share the consignee's contact number for delivery?"; ask = @('recipient_contact') },
    @{ t = "Could you share your supplier's contact details so we can confirm the packing information?"; ask = @('supplier_contact') })) {
    $d = [pscustomobject]@{ AskFields = @($pair.ask); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
    $r = Test-ReplyCompliance -Text $pair.t -Rules $null -Decision $d
    Case ('A1-allow[' + $pair.t.Substring(0, 30) + ']') 'must be allowed' $true $r.Ok ('codes=' + (Codes $r))
}
# The red line itself must allow a role+purpose contact request; the separate AskFields scope check
# only fires when this turn's decision did not authorise the field (that is its own rule, §6.1 check 1).
$rNoAsk = Test-ContactRedline -Text 'Could you share your supplier''s contact details so we can confirm the packing information?'
Case 'A1-allow-role-purpose-no-askfields' 'role+purpose allowed by the red line' $true ([bool]$rNoAsk.Ok) ('codes=' + ((@($rNoAsk.Violations | ForEach-Object { $_.Code })) -join ','))
# The buyer gave the supplier contact but NOT the dimensions: the decision then asks a quote gap
# instead of the supplier contact, so the AskFields scope check must NOT report a request for a
# field the buyer has already supplied (spec §1.1 rule 7: "already supplied" is not re-asked).
$dSup = Decide @((BLine "My supplier's contact is supplier@example.invalid, but I don't know the dimensions." 1791170000000)) (Ctx $prof $utc)
$rScoped = Test-ReplyCompliance -Text 'Could you share your supplier''s contact details so we can confirm the packing information?' -Rules $null -Decision $dSup
Case 'A1-supplier-contact-already-provided-recognised' 'the one fact model reports the supplier contact as supplied' $true ([bool]$dSup.Facts.HasSupplierContact) ('askFields=' + (@($dSup.AskFields) -join ','))
# The old behaviour reported this as ASK_OUT_OF_SCOPE ("the decision never authorised the supplier
# field") even though the buyer HAD supplied it - a contradictory message. Now the single fact model
# is consulted and the honest code is ASK_ALREADY_PROVIDED (a re-ask of a supplied field, §6.1).
Case 'A1-no-false-out-of-scope-for-provided-supplier-contact' 'a supplied field is not reported as an unauthorised ask' $true ([bool](-not ((Codes $rScoped) -match 'ASK_OUT_OF_SCOPE'))) ('codes=' + (Codes $rScoped))
Case 'A1-provided-supplier-field-reported-as-reask' 're-asking a supplied field is ASK_ALREADY_PROVIDED' $true ([bool]((Codes $rScoped) -match 'ASK_ALREADY_PROVIDED')) ('codes=' + (Codes $rScoped))
# The plain role+purpose allowance (no prior supplier contact) keeps working through the full check.
$dGap = Decide @((BLine 'We need a freight quote for 10 cartons to Hamburg.' 1791170000000)) (Ctx $prof $utc)
$rFull = Test-ReplyCompliance -Text 'Could you share your supplier''s contact details so we can confirm the packing information?' -Rules $null -Decision ([pscustomobject]@{ AskFields = @('supplier'); Facts = $dGap.Facts; RequestedFacts = @(); ActionEvidence = $null })
Case 'A1-role-purpose-allowed-when-not-supplied-yet' 'role + purpose allowed by the full check' $true $rFull.Ok ('codes=' + (Codes $rFull))
$rDiscl = Test-ReplyCompliance -Text 'The supplier already gave us their contact person.' -Rules $null -Decision $a1ask
Case 'A1-narrative-not-offer' 'supplier narrative must not be misread' $true $rDiscl.Ok ('codes=' + (Codes $rDiscl))
Emit ''

# ============================================================================================
Emit '=== A4 报价提醒仍用旧的三字段规则 ==='
. (Join-Path $scripts 'lib\goods.ps1')
. (Join-Path $scripts 'lib\quote.ps1')
$snapDir = Join-Path $isoRoot 'data'
New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
function Save-Snap([string]$buyer, [string[]]$body, [string]$name) {
    $p = Join-Path $snapDir $name
    $all = @(('# BUYER: ' + $buyer)) + $body
    [System.IO.File]::WriteAllText($p, ($all -join $LF), (New-Object System.Text.UTF8Encoding($false)))
}
Save-Snap 'Virtual NoCount Buyer' @((BLine 'Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' 1791170000000)) 'msgs_20261005_000001.txt'
Save-Snap 'Virtual Count Buyer' @((BLine '10 cartons, total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1' 1791170000001)) 'msgs_20261005_000002.txt'
$ready = @(Get-QuoteReadyBuyers $snapDir)
Emit ('  ready buyers: ' + ((@($ready | ForEach-Object { $_.buyer })) -join ' ; '))
Case 'A4-nocount-excluded' 'buyer without carton count must not be a reminder candidate' $false ([bool](@($ready | Where-Object { $_.buyer -eq 'Virtual NoCount Buyer' }).Count -gt 0))
Case 'A4-count-included' 'buyer with carton count is a candidate' $true ([bool](@($ready | Where-Object { $_.buyer -eq 'Virtual Count Buyer' }).Count -gt 0))
Emit ''

# ============================================================================================
Emit '=== A5 不足 100 字节的损坏账本被当作不存在 ==='
. (Join-Path $scripts 'lib\state_store.ps1')
$tk = $null; $errs = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'), [ref]$tk, [ref]$errs)
if ($errs.Count) { throw 'monitor.ps1 failed to parse' }
foreach ($fn in @('Test-RepliedStateUsable', 'Get-RepliedState', 'Get-RepliedStateFileSize', 'Get-LedgerHealth', 'Reset-LedgerHealthCache', 'Get-CachedDocumentRead', 'Test-LedgerShape', 'Get-ReplyEntryCount', 'Test-LedgerFirstInitAllowed')) {
    $n = $ast.Find({ param($x) $x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true)
    if (-not $n) { throw ('monitor.ps1 does not define ' + $fn) }
    Invoke-Expression $n.Extent.Text
}
$script:stateFile = Join-Path $isoRoot 'state.json'
# Exact original 15-byte sample: UTF-8 BOM + {"replied":{
$rawBytes = New-Object System.Collections.Generic.List[byte]
foreach ($b in @(0xEF, 0xBB, 0xBF)) { [void]$rawBytes.Add([byte]$b) }
foreach ($b in [Text.Encoding]::UTF8.GetBytes('{"replied":{')) { [void]$rawBytes.Add([byte]$b) }
[System.IO.File]::WriteAllBytes($script:stateFile, $rawBytes.ToArray())
$b15 = (Get-Item $script:stateFile).Length
$doc = Read-JsonDocument $script:stateFile
Emit ('  15-byte sample: bytes=' + $b15 + ' readStatus=' + $doc.Status)
$u = Test-RepliedStateUsable (Get-RepliedState)
Emit ('  Test-RepliedStateUsable => Ok=' + $u.Ok + ' Reason=' + $u.Reason + ' Bytes=' + $u.Bytes)
Case 'A5-small-corrupt-detected' 'corrupt 15-byte ledger must not be treated as no-ledger' $false ([bool]$u.Ok)
Emit ''

# ============================================================================================
Emit '=== A6 每箱重量/尺寸被误判为额外询问箱数 ==='
function AskDecision([string[]]$ask) { return [pscustomobject]@{ AskFields = @($ask); Facts = $null; RequestedFacts = @(); ActionEvidence = $null } }
$dw = AskDecision @('weight')
foreach ($t in @('Could you share the packed weight per carton?', 'Could you share the weight of each pallet?')) {
    $r = Test-ReplyCompliance -Text $t -Rules $null -Decision $dw
    Case ('A6-allow-weight-per-unit[' + $t.Substring(0, 30) + ']') 'per-unit weight is inside a weight authorization' $true $r.Ok ('codes=' + (Codes $r))
}
$dd = AskDecision @('dimension')
$r = Test-ReplyCompliance -Text 'Could you share the dimensions of each carton?' -Rules $null -Decision $dd
Case 'A6-allow-dims-per-carton' 'per-carton dimensions are inside a dimension authorization' $true $r.Ok ('codes=' + (Codes $r))
$r = Test-ReplyCompliance -Text 'How many cartons are there?' -Rules $null -Decision $dw
Case 'A6-block-real-count-ask' 'a real carton-count question still needs count authorization' $false $r.Ok ('codes=' + (Codes $r))
$r = Test-ReplyCompliance -Text 'Could you share the weight per carton and how many cartons?' -Rules $null -Decision $dw
Case 'A6-block-mixed-count-ask' 'the count half of a mixed request is still unauthorised' $false $r.Ok ('codes=' + (Codes $r))
Emit ''

# ============================================================================================
Emit '=== T1/T2 时间问答地点绑定 ==='
$rt = Ctx $prof $utc
function Eq([string]$id, [string]$desc, [string]$want, [string]$got) {
    $ok = ($want -ceq $got)
    $verdict = 'PASS'
    if (-not $ok) { $verdict = 'FAIL'; [void]$script:fails.Add($id) }
    Emit ("  [{0}] {1} {2} want=[{3}] got=[{4}]" -f $verdict, $id, $desc, $want, $got)
}
function Case-Time([string]$id, [string[]]$l, [string]$wantPlace, [string]$wantKind) {
    $d = Decide $l $rt
    Eq ($id + '-place') 'requested place' $wantPlace ([string]$d.RequestedPlace)
    Eq ($id + '-kind') 'requested place kind' $wantKind ([string]$d.RequestedPlaceKind)
}
Case-Time 'T1-lowercase-hamburg' @((BLine 'What time is it in hamburg?' 1791170000000)) 'hamburg' 'explicit'
Case-Time 'T1-uppercase-hamburg' @((BLine 'What time is it in Hamburg?' 1791170000000)) 'Hamburg' 'explicit'
$d = Decide @((BLine 'What time is it in hamburg?' 1791170000000)) $rt
Emit ('  T1 lower-case direct=[' + $d.DirectFactText + ']')
Case 'T1-no-seller-clock-for-lowercase-hamburg' 'T1 must not answer the seller clock' $false ([bool]($d.DirectFactText -match '2:05 PM'))
$d2 = Decide @((BLine 'What time is it in Hamburg?' 1791170000000)) $rt
Emit ('  T1 upper-case direct=[' + $d2.DirectFactText + ']')
$d3 = Decide @((BLine 'What time is it in China? My company is in Tokyo.' 1791170000000)) $rt
Emit ('  T2a place=[' + $d3.RequestedPlace + '] direct=[' + $d3.DirectFactText + ']')
Case 'T2a-china-not-overridden' 'the later company sentence must not override the time target' $true ([bool]($d3.DirectFactText -match '2:05 PM in China'))
$d4 = Decide @((BLine 'What time is it now? My company is in Tokyo.' 1791170000000)) $rt
Emit ('  T2b place=[' + $d4.RequestedPlace + '] direct=[' + $d4.DirectFactText + ']')
Case 'T2b-no-place-defaults-seller' 'an unspecified time question defaults to the seller zone' $true ([bool]($d4.DirectFactText -match '2:05 PM in China'))
Emit ''

# A2/A3 纯函数层复现（人工暂停计时锚点、供应商任务键与证据）
$a2Buyer = 'Virtual Buyer'
$t12 = [datetime]'2026-10-05T12:00:00'
$humanLine = ('[ME] I will take this one myself @@MT:' + ([long]1893456000000))
$u1 = Update-HumanPauseFromLines -Buyer $a2Buyer -Lines @((BLine 'hello' 1893455000000), $humanLine) -Now $t12
Case 'A2-pause-anchored-on-scanned-human-reply' 'pause window opens on the trusted human reply' $true ([bool]$u1.Started) ('reason=' + $u1.Reason + ' until=' + $u1.Until)
$pa = Test-HumanPauseActive -Buyer $a2Buyer -Now $t12.AddMinutes(1)
Case 'A2-pause-active-one-minute-later' 'buyer supplement one minute later is inside the window' $true ([bool]$pa.Active) ('reason=' + $pa.Reason)
$ctxA2 = @{ sourceUnknownMarks = @{} }
Case 'A2-fresh-ctx-has-no-marks' 'a fresh scan context has no unknown marks yet' $false ([bool]$ctxA2.sourceUnknownMarks.ContainsKey($a2Buyer)) ''
$supTask = New-OrUpdate-SupplierVerificationTask -Buyer $a2Buyer -SupplierContact 'supplier@example.invalid' -TriggerMessage 'my supplier contact'
Case 'A3-real-contact-not-placeholder' 'the task stores the real contact, not a literal placeholder' $true ([bool]($supTask.Task.supplierContact -eq 'supplier@example.invalid')) ('contact=' + $supTask.Task.supplierContact)
Case 'A3-supplier-key-from-contact' 'the dedup key is derived from the real contact' $true ([bool]($supTask.Task.supplierKey -match 'example')) ('key=' + $supTask.Task.supplierKey)
$supTask2 = New-OrUpdate-SupplierVerificationTask -Buyer $a2Buyer -SupplierContact 'other@example.net'
Case 'A3-two-suppliers-separate-tasks' 'a different supplier gets its own task' $true ([bool]($supTask2.Task.id -ne $supTask.Task.id)) ('ids=' + $supTask.Task.id + '/' + $supTask2.Task.id)
Emit ('BASELINE-RESULT: fail=' + $script:fails.Count + ' cases=' + (@($script:fails | Select-Object -Unique).Count))
if ($script:fails.Count -gt 0) { Emit ('BASELINE-FAILED: ' + ((@($script:fails | Select-Object -Unique)) -join ', ')) } else { Emit 'BASELINE-ALL-PASS' }
if ($Out) {
    $enc2 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Out, (($lines -join $LF) + $LF), $enc2)
    Write-Output ('EVIDENCE-WRITTEN: ' + $Out)
}
try { Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }