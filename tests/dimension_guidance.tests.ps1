# dimension_guidance tests - the "buyer cannot give sizes" guidance (spec 更像真人销售_20260926 S4 / 12.2-A9)
# Rewritten 2026-10-03 for the reply-chain refactor. Pure logic + document consistency: no page,
# no Chrome, no model, no network.
#
# WHAT CHANGED AND WHY: the old version asserted that the approved sentences appeared VERBATIM inside
# reply_agent_prompt.md and reply_playbook.md. That is no longer the architecture. The prompt now
# carries language rules only, and the scenario material lives in reply_scenarios.md, which is
# injected ONE SECTION AT A TIME by lib\reply_gen.ps1::Get-ScenarioGuidance. So this test now asserts
# the stronger property: the approved sentences are defined once in code AND are actually reachable
# through the injection path the model uses. Asserting "the string is somewhere in a file nobody
# loads" was exactly the fake-load bug this refactor removed.
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo "scripts"
. (Join-Path $scripts "reply_engine.ps1")
. (Join-Path $scripts "lib\msg_norm.ps1")
. (Join-Path $scripts "lib\reply_policy.ps1")
. (Join-Path $scripts "lib\reply_gen.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }
Write-Output "== dimension_guidance tests =="

# --- 1) the wording has exactly one definition, in code --------------------------------------
Assert-True "Get-DimensionGuidance-exists" ($null -ne (Get-Command Get-DimensionGuidance -EA SilentlyContinue))
Assert-True "Test-NoDimensionQuoteHint-exists" ($null -ne (Get-Command Test-NoDimensionQuoteHint -EA SilentlyContinue))
$g = Get-DimensionGuidance

# --- 2) the preferred sentence offers to do the work, and never quotes a number --------------
Assert-True "primary-mentions-supplier-contact" ($g.primary -match "supplier's contact")
Assert-True "primary-promises-direct-confirm" ($g.primary -match 'confirm the cargo details with them directly')
Assert-True "primary-no-price-number" (-not ($g.primary -match '\$\s?\d|USD\s?\d|\d+\s*(usd|dollars)'))
Assert-Eq   "fallback-count" (@($g.fallbacks).Count) 3
Assert-True "fallback-packing-list" (@(@($g.fallbacks) | Where-Object { $_.text -match 'packing list' }).Count -ge 1)
Assert-True "fallback-rough-size-estimate" (@(@($g.fallbacks) | Where-Object { $_.text -match 'rough size is fine' }).Count -ge 1)
Assert-True "fallback-lwh-cm" (@(@($g.fallbacks) | Where-Object { $_.text -match 'L x W x H in cm' }).Count -ge 1)

# --- 3) the scenario manual really is the injection source, and it is reachable --------------
$scenPath = Join-Path $scripts "reply_scenarios.md"
Assert-True "scenario-manual-exists" (Test-Path $scenPath)
$scenTxt = [System.IO.File]::ReadAllText($scenPath)
Assert-True "primary-in-scenario-manual" ($scenTxt.Contains([string]$g.primary))
foreach ($f in @($g.fallbacks)) { Assert-True ("fallback-in-scenario-manual: " + $f.case) ($scenTxt.Contains([string]$f.text)) }
$section = Get-ScenarioGuidance -Path $scenPath -Key 'dimension_missing'
Assert-True "dimension-section-is-injectable" (-not [string]::IsNullOrWhiteSpace($section))
Assert-True "injected-section-carries-primary" ($section.Contains([string]$g.primary))
foreach ($f in @($g.fallbacks)) { Assert-True ("injected-section-carries-fallback: " + $f.case) ($section.Contains([string]$f.text)) }

# --- 4) the fallback path actually returns the approved sentence ----------------------------
$LF = [string][char]10
$line = '[BUYER] I cannot get the dimensions from the factory, they do not reply @@TS:1759400000000 @@MT:1759400000000'
$conv = ConvertTo-MessageList $line 'Buyer A'
$facts = Get-ConversationFacts $conv
$dec = Get-ReplyDecision -Conversation $conv -Facts $facts
Assert-Eq "decision-is-dimension-missing" $dec.Scenario 'dimension_missing'
Assert-True "decision-asks-for-supplier-contact" ($dec.AskFields -contains 'supplier')
$fb = Get-ScenarioFallback -Decision $dec -Rules $null
Assert-Eq "fallback-equals-approved-primary" $fb ([string]$g.primary)

# --- 5) once the field limit is used up, the third ask must be replaced by a step-back -------
$askTwice = @(
    '[ME] Could you share your supplier''s contact? @@TS:1759400100000 @@MT:1759400100000',
    '[ME] Any luck with the supplier contact? @@TS:1759400200000 @@MT:1759400200000',
    '[BUYER] still no sizes from me @@TS:1759400300000 @@MT:1759400300000'
) -join $LF
$conv2 = ConvertTo-MessageList $askTwice 'Buyer A'
$dec2 = Get-ReplyDecision -Conversation $conv2 -Facts (Get-ConversationFacts $conv2)
Assert-True "ask-limit-blocks-supplier-ask" (-not ($dec2.AskFields -contains 'supplier'))
$fb2 = Get-ScenarioFallback -Decision $dec2 -Rules $null
Assert-True "third-ask-replaced-by-stepback" (-not ($fb2 -match "supplier's contact"))
Assert-Eq "stepback-is-the-approved-second-fallback" $fb2 ([string](@($g.fallbacks)[1].text))

# --- 6) the enforced ask limit, not prose about the ask limit -------------------------------
Assert-Eq "policy-ask-limit-is-two" $script:PolicyMaxAskPerField 2
Assert-True "AskCounts-exists" ($null -ne (Get-Command Get-AskCounts -EA SilentlyContinue))
$counts = Get-AskCounts @(
    [pscustomobject]@{ Role = 'me'; Text = 'Could you share the carton sizes?' },
    [pscustomobject]@{ Role = 'me'; Text = 'Any luck with the sizes?' },
    [pscustomobject]@{ Role = 'me'; Text = 'What is the total weight?' }
)
Assert-Eq "ask-counts-dimension" $counts.dimension 2
Assert-Eq "ask-counts-weight" $counts.weight 1

# --- 7) the forbidden phrasings are present in the material that IS sent --------------------
Assert-True "manual-forbids-no-dim-quote" ($scenTxt -match 'We can quote you without the dimensions')
Assert-True "manual-forbids-claiming-contacted-supplier" ($scenTxt -match 'I will have the supplier contact you')
Assert-True "manual-forbids-already-contacted" ($scenTxt -match 'I have already contacted your supplier')
Assert-True "manual-no-price-number" (-not ($scenTxt -match '\$\s?\d|USD \d|discount \d'))

# --- 8) "no dimensions needed" hints are really detectable ----------------------------------
$bad1 = "We can quote you without the dimensions."
$bad2 = "No need for the dimensions - just tell us the weight."
$bad3 = "Dimensions are not required for a quote."
$bad4 = "There is no need to measure anything, we can proceed."
$good1 = [string]$g.primary
$good2 = "If it's a carton, just the L x W x H in cm is enough."
$good3 = "I just need the carton sizes to price this accurately."
Assert-Eq "hint-bad1" (Test-NoDimensionQuoteHint $bad1) $true
Assert-Eq "hint-bad2" (Test-NoDimensionQuoteHint $bad2) $true
Assert-Eq "hint-bad3" (Test-NoDimensionQuoteHint $bad3) $true
Assert-Eq "hint-bad4" (Test-NoDimensionQuoteHint $bad4) $true
Assert-Eq "hint-good1" (Test-NoDimensionQuoteHint $good1) $false
Assert-Eq "hint-good2" (Test-NoDimensionQuoteHint $good2) $false
Assert-Eq "hint-good3" (Test-NoDimensionQuoteHint $good3) $false
Assert-Eq "hint-empty" (Test-NoDimensionQuoteHint '') $false
# and the send-time gate must actually consult it
$chk = Test-ReplyCompliance -Text $bad2 -Rules $null
Assert-True "compliance-uses-the-hint-check" (-not $chk.Ok)

# --- 9) the old fake load is gone, and the file was archived rather than silently dropped ----
Assert-True "playbook-no-longer-claimed-as-loaded" (-not ([System.IO.File]::ReadAllText((Join-Path $scripts 'reply_agent_prompt.md')) -match 'reply_playbook'))
Assert-True "playbook-archived-not-deleted" (Test-Path (Join-Path $repo 'docs\archive\reply_playbook_zh_20261003.md'))

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
