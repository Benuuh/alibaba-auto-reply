# Read-only check that the owner-confirmed LOCAL profile can pass the final content check.
#
# The real company and display name live only in the git-ignored scripts\config.json. This script
# READS that file and prints BOOLEANS ONLY: no value, no substring of a value, and no violation
# detail (which would quote the value back). Nothing is written anywhere.
#
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File docs\verification\reception_facts_20261005\local_profile_check.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BuyerLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
function Invoke-LLM { param($Messages, $Temperature, $MaxTokens, $LogFile) return 'Happy to help with the rate - could you share the carton sizes and the delivery address?' }

$cfgPath = Join-Path $scripts 'config.json'
if (-not (Test-Path $cfgPath)) { Write-Output 'RESULT: local_config_missing=True'; exit 1 }
$cfg = [IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
$profile = Get-SellerProfile -Config $cfg
$ctx = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc ([datetime]::SpecifyKind([datetime]'2026-10-05T06:05:00', [DateTimeKind]::Utc))

function Run([string]$text) {
    $c = ConvertTo-MessageList (BuyerLine $text 1791000000000) 'Buyer A'
    $f = Get-ConversationFacts $c
    $d = Get-ReplyDecision -Conversation $c -Facts $f -Rules $null -RuntimeContext $ctx -ActionEvidence $ctx.ActionEvidence
    $g = Invoke-ReplyGeneration -Conversation $c -Decision $d -Rules $null `
        -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -RuntimeContext $ctx
    return [pscustomobject]@{ Decision = $d; Gen = $g }
}

$nameWords = @() ; $companyWords = @()
if ($profile.NameValue) { $nameWords = @($profile.NameValue -split '\s+' | Where-Object { $_ }) }
if ($profile.CompanyValue) { $companyWords = @($profile.CompanyValue -split '\s+' | Where-Object { $_ }) }

Write-Output '== local seller_profile read-only check (booleans only) =='
Write-Output ('company_field_configured=' + [bool]([string]$cfg.seller_profile.company_name_en))
Write-Output ('company_field_verified=' + [bool]$profile.CompanyVerified)
Write-Output ('company_is_multi_word=' + [bool]($companyWords.Count -gt 1))
Write-Output ('company_has_internal_period=' + [bool]($profile.CompanyValue -match '\.\s*\S'))
Write-Output ('name_field_configured=' + [bool]([string]$cfg.seller_profile.assistant_display_name_en))
Write-Output ('name_field_verified=' + [bool]$profile.NameVerified)
Write-Output ('name_is_multi_word=' + [bool]($nameWords.Count -gt 1))
Write-Output ('timezone_valid=' + [bool]$profile.TimezoneValid)

$rName = Run "What's your name?"
$nameText = [string]$rName.Gen.Text
$nameChk = Test-ReplyCompliance -Text $nameText -Rules $null -Decision $rName.Decision
Write-Output ('name_reply_source=' + $rName.Gen.Source)
Write-Output ('name_reply_rendered=' + [bool](-not [string]::IsNullOrWhiteSpace($nameText)))
Write-Output ('name_reply_contains_full_display_name=' + [bool]($nameText -match [regex]::Escape([string]$profile.NameValue)))
Write-Output ('name_final_content_check_ok=' + [bool]$nameChk.Ok)

$rCompany = Run "What's your company name?"
$companyText = [string]$rCompany.Gen.Text
$companyChk = Test-ReplyCompliance -Text $companyText -Rules $null -Decision $rCompany.Decision
Write-Output ('company_reply_source=' + $rCompany.Gen.Source)
Write-Output ('company_reply_contains_full_company=' + [bool]($companyText -match [regex]::Escape([string]$profile.CompanyValue)))
Write-Output ('company_final_content_check_ok=' + [bool]$companyChk.Ok)

$rTime = Run 'What time is it now?'
$timeChk = Test-ReplyCompliance -Text ([string]$rTime.Gen.Text) -Rules $null -Decision $rTime.Decision
Write-Output ('time_reply_has_clock=' + [bool]([string]$rTime.Gen.Text -match '\d{1,2}:\d{2}\s*(AM|PM)'))
Write-Output ('time_final_content_check_ok=' + [bool]$timeChk.Ok)
Write-Output ('time_reply_has_no_placeholder=' + [bool]([string]$rTime.Gen.Text -notmatch '\[|\{\{'))

$ok = ([bool]$profile.CompanyVerified -and [bool]$profile.NameVerified -and [bool]$nameChk.Ok -and [bool]$companyChk.Ok -and [bool]$timeChk.Ok)
Write-Output ('RESULT: local_profile_usable=' + $ok)
