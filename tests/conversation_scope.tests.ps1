# Actual production browser scripts in Node/vm; no browser, sends, model or production writes.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/lib/msg_extract_js.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/lib/outbound_receipts.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'outbound_receipts parse failed'}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OutboundSnapshot'},$true)
Invoke-Expression $fn.Extent.Text
function Invoke-SendEval([string]$Js) { $script:snapshotJs=$Js; return '{"name":"Buyer A","lines":[]}' }
try { $null=Get-OutboundSnapshot -Buyer 'Buyer A' } catch { if($_.Exception.Message -notmatch 'MESSAGES_NOT_READY'){throw} }
$scripts=[ordered]@{readA=(Get-ConversationReadJs -Buyer 'Buyer A');readB=(Get-ConversationReadJs -Buyer 'Buyer B');already=(Get-ConversationReadJs -Buyer 'Buyer A' -AlreadyOpen $true);snapshot=$script:snapshotJs}
$tmp=Join-Path $env:TEMP ('aar-conversation-js-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    [IO.File]::WriteAllText($tmp,($scripts|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
    & node (Join-Path $PSScriptRoot 'conversation_scope.fixture.js') $tmp
    if($LASTEXITCODE -ne 0){throw 'Conversation boundary regressions failed'}
} finally {Remove-Item -LiteralPath $tmp -Force}

# The PS snapshot adapter must propagate a DOM guard failure instead of returning empty proof.
function Invoke-SendEval { return '{"error":"TARGET_MISMATCH"}' }
$blocked=$false
try{$null=Get-OutboundSnapshot -Buyer 'Buyer A'}catch{$blocked=$_.Exception.Message -match 'TARGET_MISMATCH'}
if(-not $blocked){throw 'Snapshot guard error was swallowed'}
function Invoke-SendEval { return '{"name":"Buyer A","lines":[]}' }
$blocked=$false
try{$null=Get-OutboundSnapshot -Buyer 'Buyer A'}catch{$blocked=$_.Exception.Message -match 'MESSAGES_NOT_READY'}
if(-not $blocked){throw 'Empty snapshot was accepted by PS adapter'}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/monitor.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-Snapshot'},$true)
Invoke-Expression $fn.Extent.Text
function Switch-ToPendingTab { return 'ALREADY_ACTIVE' }
function Start-Sleep {param($Seconds)}
function Invoke-CdpEval($Js){$script:pendingListJs=$Js;return '[]'}
$null=Get-Snapshot
$tmp=Join-Path $env:TEMP ('aar-pending-list-'+[guid]::NewGuid().ToString('N')+'.js')
try{
    [IO.File]::WriteAllText($tmp,$script:pendingListJs,(New-Object Text.UTF8Encoding($false)))
    & node (Join-Path $PSScriptRoot 'pending_list.fixture.js') $tmp
    if($LASTEXITCODE -ne 0){throw 'Pending list DOM regressions failed'}
}finally{Remove-Item -LiteralPath $tmp -Force}
function Switch-ToPendingTab {return 'NO_TAB'}
function Invoke-CdpEval {throw 'unverified tab must not be read'}
if((Get-Snapshot) -ne 'PENDING_TAB_UNVERIFIED'){throw 'unverified tab returned a pending list'}
Write-Output 'RESULT conversation_scope: PASS (production DOM scripts + pending list + unreadable snapshot guard)'
