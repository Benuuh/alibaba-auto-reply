# auto_optimize.ps1 - Suggestion-only improvement pass.
#
# [SPEC 5 2026-10-03, user-confirmed] AUTOMATIC OPTIMIZATION NO LONGER EDITS ANY ACTIVE FILE.
#
# What this script used to do (and why it stopped): it ran daily at 05:30, called the model, and
# wrote the result STRAIGHT into the live corpus - appending up to 5 "never" rules into
# reply_rules.json and appending Chinese red-line lines into reply_agent_prompt.md, then firing a
# merge pass, and capping the never array by DROPPING THE OLDEST rules. That last part could delete
# a hard constraint. The accumulated damage is in git history: 40 overlapping never-rules and a
# 55-line auto-appended block inside the prompt.
#
# This script now ONLY writes suggestion records into <data_dir>\suggestions\. Applying a suggestion
# is a separate, explicit act: scripts\apply_suggestion.ps1 -Id <id>, and it requires that a human
# first ran scripts\review_suggestions.ps1 -Accept <id>.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -NoProfile -File auto_optimize.ps1            # generate
#   powershell -ExecutionPolicy Bypass -NoProfile -File auto_optimize.ps1 -DryRun    # show only
#   powershell -ExecutionPolicy Bypass -NoProfile -File auto_optimize.ps1 -NoLlm      # offline, no model call
# Scheduled task: AlibabaAutoReplyOptimize (daily 05:30, after the 05:00 quality report).
param(
    [switch]$DryRun,
    [switch]$NoLlm,
    [int]$MaxSuggestions = 5,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\suggestions.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$logFile = Join-Path $script:logFileDir "monitor.log"
$dataDir = Get-SkillPath "data"

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# The active files this pass READS (for duplicate and conflict checking) but must never write.
$rulesFile    = Join-Path $LogDir "reply_rules.json"
$promptFile   = Join-Path $LogDir "reply_agent_prompt.md"
$scenarioFile = Join-Path $LogDir "reply_scenarios.md"

# Guard: refuse to run at all if a caller somehow points us at an active file for writing. There is
# no code path that writes them any more; this makes that a checked property rather than a promise.
$activeFiles = @($rulesFile, $promptFile, $scenarioFile)
Write-Log ("AUTOOPT-SUGGEST-ONLY: active files are read-only for this pass (" + (($activeFiles | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + ")")

function Get-ActivePolicyText {
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in @($rulesFile, $promptFile, $scenarioFile)) {
        if (Test-Path $f) { [void]$sb.AppendLine((Get-Content $f -Raw -Encoding UTF8)) }
    }
    return $sb.ToString()
}

# Offline validation of one proposal, run BEFORE a human is ever asked to look at it.
#   - duplicate: the same wording already lives in an active file
#   - hard constraint: the intake guard already refused these, checked again for the record
#   - shape: too short / too long / not a rule-shaped sentence
# Returns a one-line human-readable result string.
function Test-ProposalOffline {
    param([string]$Proposed, [string]$ActiveText)
    $notes = New-Object System.Collections.ArrayList
    $p = ([string]$Proposed).Trim()
    if ($p.Length -lt 20) { [void]$notes.Add('too short to be a useful rule') }
    if ($p.Length -gt 400) { [void]$notes.Add('too long for a rule; trim it') }
    if ($ActiveText -and $ActiveText.ToLowerInvariant().Contains($p.ToLowerInvariant())) { [void]$notes.Add('duplicate: identical wording already present in an active file') }
    if ($p -notmatch '(?i)\b(never|always|when|if|do not|must)\b') { [void]$notes.Add('not rule-shaped: should state a trigger and an action') }
    if ($notes.Count -eq 0) { return 'pass: not a duplicate, rule-shaped, within length bounds, no hard-constraint relaxation detected' }
    return ('review: ' + ($notes -join '; '))
}

# 1) Evidence: the newest quality report. No report => nothing to learn from => exit quietly.
$repDir = Get-SkillPath "reports"
$report = $null
if (Test-Path $repDir) {
    $report = @(Get-ChildItem $repDir -Filter "quality_*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}
if (-not $report -or $report.Count -eq 0) { Write-Output "AUTOOPT-NO-REPORT"; exit 0 }
$reportText = Get-Content $report[0].FullName -Raw -Encoding UTF8
if ($reportText.Length -lt 200) { Write-Output "AUTOOPT-EMPTY-REPORT"; exit 0 }

$activeText = Get-ActivePolicyText
$baseRulesHash = Get-FileSha256 $rulesFile
$baseScenarioHash = Get-FileSha256 $scenarioFile

$proposals = @()
if (-not $NoLlm) {
    . (Join-Path $PSScriptRoot "lib\creds.ps1")
    . (Join-Path $PSScriptRoot "lib\llm.ps1")
    $llmCfgFile = Get-SkillPath "llmcfg"
    if (-not $llmCfgFile) { $llmCfgFile = Join-Path (Split-Path $LogDir -Parent) "llm_config.json" }
    if (-not (Test-Path $llmCfgFile)) { Write-Log 'AUTOOPT-SUGGEST: no LLM config, suggestion pass skipped'; Write-Output 'AUTOOPT-NO-LLM-CONFIG'; exit 0 }

    $sysPrompt = 'You are a senior cross-border customer-service quality analyst. From the negative cases in the quality report, propose improvements for an automated reply system. Output ONLY JSON, no other text. Shape: {"suggestions":[{"title":"...","targetFile":"reply_rules.json","targetPointer":"reply_rules.never","proposedContent":"...","evidence":"...","expectedImpact":"..."}]}. Rules: 1) every suggestion must be directly derivable from a negative case, never invented; 2) do not duplicate wording that already exists in the policy files shown to you; 3) proposedContent must be a single rule-shaped American English sentence that ADDS a restriction - proposals that would relax a price, liability, contact, identity-check or send-protection constraint are forbidden and will be rejected; 4) targetFile must be reply_rules.json (append to reply_rules.never) or reply_scenarios.md (append a reviewed example); 5) at most ' + $MaxSuggestions + ' suggestions; 6) if there is nothing to learn, return {"suggestions":[]}.'
    $userMsg = '=== QUALITY REPORT ===' + [string][char]10 + $reportText + [string][char]10 + [string][char]10 + '=== EXISTING POLICY (do not duplicate) ===' + [string][char]10 + $activeText
    $messages = @(
        @{ role = 'system'; content = $sysPrompt },
        @{ role = 'user'; content = $userMsg }
    )
    $respText = Invoke-LLM $messages 0.3 900 $logFile
    if (-not $respText) { Write-Log 'AUTOOPT-SUGGEST: LLM call failed'; Write-Output 'AUTOOPT-LLM-FAIL'; exit 0 }
    $parsed = $null
    try { $parsed = $respText | ConvertFrom-Json } catch { Write-Log 'AUTOOPT-SUGGEST: suggestion JSON parse failed'; Write-Output 'AUTOOPT-PARSE-FAIL'; exit 0 }
    if ($parsed -and $parsed.suggestions) { $proposals = @($parsed.suggestions) }
} else {
    Write-Log 'AUTOOPT-SUGGEST: -NoLlm set, no model call made'
}

if ($proposals.Count -eq 0) { Write-Output 'AUTOOPT-NO-SUGGESTIONS'; exit 0 }
if ($proposals.Count -gt $MaxSuggestions) { $proposals = @($proposals[0..($MaxSuggestions - 1)]) }

$created = 0; $merged = 0; $refused = 0; $dup = 0
$rows = New-Object System.Collections.ArrayList
foreach ($p in $proposals) {
    $content = ''
    if ($p.proposedContent) { $content = ([string]$p.proposedContent).Trim() }
    if (-not $content) { continue }
    $tf = 'reply_rules.json'
    if ($p.targetFile) { $tf = [string]$p.targetFile }
    $tp = 'reply_rules.never'
    if ($p.targetPointer) { $tp = [string]$p.targetPointer }
    $validation = Test-ProposalOffline -Proposed $content -ActiveText $activeText
    $baseHash = $baseRulesHash
    if ($tf -like '*reply_scenarios.md') { $baseHash = $baseScenarioHash }

    $evidence = [string]$p.evidence
    if (-not $evidence) { $evidence = 'derived from the negative cases in ' + $report[0].Name }
    # Note: the report can quote OUR OWN earlier wording. That is evidence about a bad outcome, and
    # it must never be treated as a sample of the owner's personal style (spec 5).
    $evidenceNote = $evidence + ' [source: ' + $report[0].Name + '; wording quoted from our own sent messages is evidence of a bad outcome, not a style sample]'

    $res = Add-Suggestion -DataDir $dataDir -TargetFile $tf -TargetPointer $tp -Proposed $content -Title ([string]$p.title) -Evidence $evidenceNote -ExpectedImpact ([string]$p.expectedImpact) -ConflictNote $validation -OfflineValidation $validation -BaseHash $baseHash
    if ($res.Refused) { $refused++; [void]$rows.Add('REFUSED (hard constraint): ' + $content + ' :: ' + ($res.RefuseReasons -join '; ')); continue }
    if ($res.Created) { $created++; [void]$rows.Add('NEW ' + $res.Id + ': ' + $content) }
    elseif ($res.Merged) {
        $merged++
        [void]$rows.Add('MERGED ' + $res.Id + ' (status=' + $res.Status + '): ' + $content)
        if ($res.Status -eq 'rejected') { $dup++ }
    }
}

if ($DryRun) {
    Write-Output '=== AUTOOPT SUGGEST-ONLY DRY-RUN (nothing written) ==='
    foreach ($r in $rows) { Write-Output $r }
    Write-Output ('=== new=' + $created + ' merged=' + $merged + ' refused=' + $refused + ' ===')
    exit 0
}

Write-Log ('AUTOOPT-SUGGEST: new=' + $created + ' merged=' + $merged + ' refused=' + $refused + ' source=' + $report[0].Name)
foreach ($r in $rows) { Write-Log ('AUTOOPT-SUGGEST ' + $r) }
Write-Output ('AUTOOPT-SUGGESTIONS: new=' + $created + ' merged=' + $merged + ' refused=' + $refused)
if ($dup -gt 0) { Write-Output ('AUTOOPT-NOTE: ' + $dup + ' suggestion(s) were previously rejected and were NOT resubmitted as pending') }
Write-Output ('AUTOOPT-NEXT: review with review_suggestions.ps1, then apply an accepted one with apply_suggestion.ps1 -Id <id>')
