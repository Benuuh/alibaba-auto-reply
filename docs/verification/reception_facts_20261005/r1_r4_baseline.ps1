# R1-R4 failure baseline for the 2026-10-05 independent acceptance supplement.
#
# Reproduces the four defects against the CURRENT reply chain through the REAL call sequence
#   ConvertTo-MessageList -> Get-ReplyDecision -> Invoke-ReplyGeneration
# with a FICTIONAL confirmed identity (Harbor Freight Management Co., Ltd. / Taylor Reed) and an
# injected UTC clock. Pure logic only: no browser, no network, no live config, no file writes.
#
#   R1  a correct multi-word display name is blocked by FACT_NAME_MISMATCH (only the first word
#       of the configured name is accepted)
#   R2  a correct company name containing an internal abbreviation period ("Co., Ltd.") is
#       blocked by FACT_COMPANY_MISMATCH (the statement is cut at the internal period)
#   R3  an explicitly named place ("in Tokyo") is ignored and the seller zone answers instead
#   R4  a multi-zone country ("Australia", "USA") silently picks one city instead of clarifying
#
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File docs\verification\reception_facts_20261005\r1_r4_baseline.ps1
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

# Fictional identity only. The owner-confirmed values are never written here.
$FICTION = '{"seller_profile":{"company_name_en":"Harbor Freight Management Co., Ltd.","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$profile = Get-SellerProfile -Config ($FICTION | ConvertFrom-Json)
$ctx = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc ([datetime]::SpecifyKind([datetime]'2026-10-05T06:05:00', [DateTimeKind]::Utc))

function Invoke-LLM { param($Messages, $Temperature, $MaxTokens, $LogFile) return 'Happy to help with the rate - could you share the carton sizes and the delivery address?' }

$script:defects = 0
function Expect-Defect([string]$id, [string]$detail, [bool]$broken) {
    if ($broken) { $script:defects++; Write-Output ('BASELINE-DEFECT ' + $id + ': ' + $detail) }
    else { Write-Output ('BASELINE-OK ' + $id + ': ' + $detail) }
}

function Run([string]$text) {
    $c = ConvertTo-MessageList (BuyerLine $text 1791000000000) 'Buyer A'
    $f = Get-ConversationFacts $c
    $d = Get-ReplyDecision -Conversation $c -Facts $f -Rules $null -RuntimeContext $ctx -ActionEvidence $ctx.ActionEvidence
    $g = Invoke-ReplyGeneration -Conversation $c -Decision $d -Rules $null `
        -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -RuntimeContext $ctx
    return [pscustomobject]@{ Decision = $d; Gen = $g }
}
function Codes($r) { return (@($r.Gen.Violations | ForEach-Object { $_.Code }) -join ',') }

Write-Output '== R1-R4 failure baseline (independent acceptance supplement) =='
Write-Output ('fictional identity: ' + $profile.CompanyValue + ' / ' + $profile.NameValue)

# ---- R1: the correct multi-word display name must survive the identity check ------------------
$r1 = Run "What's your name?"
Write-Output ('R1 direct-fact-text : ' + $r1.Decision.DirectFactText)
Write-Output ('R1 source           : ' + $r1.Gen.Source + '  violations=[' + (Codes $r1) + ']')
Expect-Defect 'R1-correct-display-name-blocked' ('source=' + $r1.Gen.Source + ' codes=[' + (Codes $r1) + ']') ($r1.Gen.Source -eq 'BLOCKED' -or $r1.Gen.Text -ne $r1.Decision.DirectFactText)
# A name that only shares the first word must STILL be blocked (this must not regress).
$r1b = Run "What's your name?"
$probe = Test-ReplyCompliance -Text "I'm Taylor Fake, the virtual shipping assistant." -Rules $null -Decision $r1b.Decision
Expect-Defect 'R1-guard-still-blocks-wrong-tail' ('policy Ok for a same-first-word name = ' + [bool]$probe.Ok) ([bool]$probe.Ok)

# ---- R2: a company name with internal abbreviation periods must survive -----------------------
$r2 = Run "What's your company name?"
Write-Output ('R2 direct-fact-text : ' + $r2.Decision.DirectFactText)
Write-Output ('R2 source           : ' + $r2.Gen.Source + '  violations=[' + (Codes $r2) + ']')
Expect-Defect 'R2-correct-company-blocked' ('source=' + $r2.Gen.Source + ' codes=[' + (Codes $r2) + ']') ($r2.Gen.Source -eq 'BLOCKED' -or $r2.Gen.Text -ne $r2.Decision.DirectFactText)
# A wrong company appended after the correct one must STILL be blocked (this must not regress).
$probe = Test-ReplyCompliance -Text ("We're Harbor Freight Management Co., Ltd. We're Global Sourcing Ltd.") -Rules $null -Decision $r2.Decision
Expect-Defect 'R2-guard-still-blocks-appended-company' ('policy Ok for a correct name + fake identity = ' + [bool]$probe.Ok) ([bool]$probe.Ok)

# ---- R3: an explicitly named place must win over the seller zone ------------------------------
foreach ($q in @('What time is it now in Tokyo?', 'What time is it in Tokyo now?', "What's the current time in Tokyo?")) {
    $r3 = Run $q
    $ok = ($r3.Decision.DirectFactText -eq "It's 3:05 PM in Japan (UTC+9).")
    Expect-Defect ('R3-explicit-place [' + $q + ']') ('answered [' + $r3.Decision.DirectFactText + ']') (-not $ok)
}
# The seller-zone answer must still be the default when no place is named.
$r3d = Run 'What time is it now?'
Expect-Defect 'R3-no-place-still-seller-zone' ('answered [' + $r3d.Decision.DirectFactText + ']') ($r3d.Decision.DirectFactText -ne "It's 2:05 PM in China (UTC+8).")

# ---- R4: a multi-zone country must clarify instead of picking one city ------------------------
foreach ($pair in @(@{ q = 'What time is it in Australia?'; bad = '5:05 PM' }, @{ q = 'What time is it in the USA?'; bad = '2:05 AM' })) {
    $r4 = Run $pair.q
    $clarify = ($r4.Decision.DirectFactText -match '(?i)which (city|country) or time zone') -and ($r4.Decision.DirectFactText -notmatch '\d')
    Expect-Defect ('R4-multi-zone-country [' + $pair.q + ']') ('answered [' + $r4.Decision.DirectFactText + ']') (-not $clarify)
}
# An explicit city inside a multi-zone country must still convert precisely.
$r4c = Run 'What time is it in New York?'
Expect-Defect 'R4-explicit-city-new-york' ('answered [' + $r4c.Decision.DirectFactText + ']') ($r4c.Decision.DirectFactText -ne "It's 2:05 AM in New York (UTC-4).")

Write-Output ('RESULT: reproduced_defects=' + $script:defects)
