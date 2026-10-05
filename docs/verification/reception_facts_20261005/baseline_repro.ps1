# Failure baseline for the 2026-10-05 reception-facts spec.
#
# Runs against the CURRENT (pre-fix) reply chain and prints the three defect classes the spec
# must close:
#   B1  an unresolved template placeholder is allowed through the send-time policy check
#   B2  a buyer asking for OUR name (What's ur name) is not classified as an own-identity question
#   B3  an action promise with no execution evidence is allowed through the policy check
#
# Pure logic only: no browser, no network, no model, no production config, no file writes.
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File docs\verification\reception_facts_20261005\baseline_repro.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }

$script:failed = 0
function Expect-Broken([string]$id, [string]$detail, [bool]$defectPresent) {
    if ($defectPresent) {
        $script:failed++
        Write-Output ("BASELINE-DEFECT " + $id + ": " + $detail)
    } else {
        Write-Output ("BASELINE-ALREADY-OK " + $id + ": " + $detail)
    }
}

# B1 - unresolved template placeholders pass the gate today.
foreach ($tpl in @('[current time]', 'It is [current time] now.', '[company name]', '{{company_name}}')) {
    $chk = Test-ReplyCompliance -Text $tpl -Rules $null
    Expect-Broken ('B1-template-allowed') ("policy Ok for placeholder text '" + $tpl + "' = " + [bool]$chk.Ok) ([bool]$chk.Ok)
}

# B2 - "What's ur name" is not recognized as an own-identity question.
$conv = ConvertTo-MessageList (BuyerLine "What's ur name" 1791000000000) 'Buyer A'
$facts = Get-ConversationFacts $conv
$d = Get-ReplyDecision -Conversation $conv -Facts $facts
Expect-Broken 'B2-own-name-misclassified' ("scenario for 'What's ur name' is '" + $d.Scenario + "' (no own-identity scenario exists)") ($d.Scenario -ne 'seller_name' -and $d.Scenario -ne 'assistant_identity')

# B3 - promises with no execution evidence pass the gate today.
foreach ($promise in @(
    "Let me check and get back to you.",
    "I'm checking with the team.",
    "I've passed this on.",
    "I'll get back to you shortly.",
    "I will keep an eye on this and let you know if anything needs you."
)) {
    $chk = Test-ReplyCompliance -Text $promise -Rules $null
    Expect-Broken ('B3-unsupported-promise-allowed') ("policy Ok for promise '" + $promise + "' = " + [bool]$chk.Ok) ([bool]$chk.Ok)
}

Write-Output ("RESULT: reproduced_defects=" + $script:failed)
