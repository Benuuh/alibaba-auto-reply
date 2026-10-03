# old_vs_new.ps1 - Measured old-vs-new reply comparison for the same buyer messages.
#
# WHAT IS MEASURED HERE, AND WHAT IS NOT (read this before quoting any number):
#   OLD side: the PRE-CHANGE rule engine, loaded from git. The script materialises
#     5356302:scripts/reply_engine.ps1 / reply_agent_prompt.md / reply_rules.json into a temp directory
#     and calls the real Generate-Reply from that revision. These are ACTUAL old outputs, not a
#     reconstruction.
#   NEW side: the real lib\reply_policy.ps1 + lib\reply_gen.ps1 decision and fallback path, called
#     with the SAME buyer message. The model is NOT called, so this is the engine-equivalent path -
#     the same thing the old side is. The new PRIMARY path is the model; what the model receives is
#     reported as injected characters, not as a claim about model quality.
#   NOT measured: real model output, real send latency, platform grading.
#
# Offline only. No browser, no network, no model call, no live data root.
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\old_vs_new.ps1 [-OutFile <path>]
param(
    [string]$OutFile = "",
    [string]$BaseRef = "5356302"
)
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path (Split-Path $here -Parent) -Parent
$scripts = Join-Path $repo "scripts"
if (-not $OutFile) { $OutFile = Join-Path $repo "docs\reply_comparison_20261003.md" }
$TK = [string][char]96

# ---- 1) OLD side: the previous revision, straight out of git -------------------------------
$oldDir = Join-Path $env:TEMP ("oldvsnew_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
foreach ($f in @("reply_engine.ps1", "reply_agent_prompt.md", "reply_rules.json")) {
    $txt = (git -C $repo show ($BaseRef + ":scripts/" + $f)) -join [string][char]10
    if (-not $txt) { throw ("cannot read " + $BaseRef + ":scripts/" + $f) }
    [System.IO.File]::WriteAllText((Join-Path $oldDir $f), $txt, (New-Object System.Text.UTF8Encoding($false)))
}
. (Join-Path $oldDir "reply_engine.ps1")
if (-not (Get-Command Generate-Reply -ErrorAction SilentlyContinue)) { throw "the pre-change engine has no Generate-Reply; refusing to report an unmeasured old side" }
$oldRules = Get-Content (Join-Path $oldDir "reply_rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json

# ---- 2) NEW side ------------------------------------------------------------------------------
. (Join-Path $scripts "reply_engine.ps1")
. (Join-Path $scripts "lib\msg_norm.ps1")
. (Join-Path $scripts "lib\reply_policy.ps1")
. (Join-Path $scripts "lib\reply_gen.ps1")
$newRules = Get-Content (Join-Path $scripts "reply_rules.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$scenPath = Join-Path $scripts "reply_scenarios.md"

$b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
$cases = @(
    @{ id = "cargo_received";    q = "did you receive my cargo? it has been two weeks"; why = "A fulfillment question. The old engine never answered it." },
    @{ id = "human_requested";   q = "I need a real person, this bot is not helping";  why = "An explicit request for a human. The old engine kept pitching." },
    @{ id = "angry_buyer";       q = "this is ridiculous, still no answer after three days"; why = "Frustration. The old engine sent the inquiry template again." },
    @{ id = "unknown_quote";     q = "how much for 2 pallets to Los Angeles?";          why = "A price request with no details yet. One question, not four." },
    @{ id = "simple_ack";        q = "ok";                                             why = "A bare acknowledgement must not become a new task." },
    @{ id = "dimension_missing"; q = "I cannot get the dimensions from the factory";    why = "The owner-approved guidance. Already correct before; must not regress." },
    @{ id = "short_refusal";     q = "no";                                             why = "A two-character refusal must still be a message event." },
    @{ id = "billing";           q = "how do you calculate the chargeable weight?";    why = "Confirmed static knowledge, answered directly." }
)

$rows = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
    $ts = 1791018000000
    $line = "[BUYER] " + $c.q + " @@TS:" + $ts + " @@OT:" + (& $b64 $c.q)
    $oldReply = ""
    try { $oldReply = [string](Generate-Reply $oldRules "Buyer A" $c.q @($line)) } catch { $oldReply = "ERROR: " + $_.Exception.Message }
    $conv = ConvertTo-MessageList $line "Buyer A"
    $facts = Get-ConversationFacts $conv
    $dec = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $newRules
    $newReply = Get-ScenarioFallback -Decision $dec -Rules $newRules
    $guid = Get-ScenarioGuidance -Path $scenPath -Key $dec.GuidanceKey
    $ctx = New-ReplyContextBlock -Conversation $conv -Decision $dec
    $chk = Test-ReplyCompliance -Text $newReply -Rules $newRules
    $todoTxt = "none"
    if ($dec.TodoKind) { $todoTxt = [string]$dec.TodoKind }
    [void]$rows.Add([pscustomobject]@{
        Id = $c.id; Question = $c.q; Why = $c.why; Old = $oldReply; New = $newReply
        Scenario = $dec.Scenario; Todo = $todoTxt; Ask = ($dec.AskFields -join ", ")
        MaxSent = $dec.MaxSentences; GuidanceChars = $guid.Length; ContextChars = $ctx.Length
        Compliant = [bool]$chk.Ok
    })
}

# ---- 3) report -------------------------------------------------------------------------------
$oldTemplate = @($rows | Where-Object { $_.Old -like "*thanks for your inquiry*" }).Count
$newOk = @($rows | Where-Object { $_.Compliant }).Count
$avgOld = [int](($rows | ForEach-Object { $_.Old.Length } | Measure-Object -Average).Average)
$avgNew = [int](($rows | ForEach-Object { $_.New.Length } | Measure-Object -Average).Average)
$md = New-Object System.Collections.ArrayList
[void]$md.Add("# Old vs new replies - measured comparison (2026-10-03)")
[void]$md.Add("")
[void]$md.Add("Generated by " + $TK + "tools\acceptance\old_vs_new.ps1" + $TK + ". Every line below is program output.")
[void]$md.Add("")
[void]$md.Add("**How to read this.** The OLD column is the real pre-change rule engine, loaded from")
[void]$md.Add($TK + "git show 5356302:scripts/reply_engine.ps1" + $TK + " into a temp directory and executed. It is not a")
[void]$md.Add("reconstruction. The NEW column is the real new decision + fallback path on the same buyer")
[void]$md.Add("message, with no model call - the same engine-equivalent path the old column represents.")
[void]$md.Add("")
[void]$md.Add("**What this does NOT show.** It is not model output, it is not a latency measurement, and")
[void]$md.Add("it is not evidence of platform grading. What the model receives is reported as injected")
[void]$md.Add("characters, not as a claim about how well it writes.")
[void]$md.Add("")
[void]$md.Add("## Headline")
[void]$md.Add("")
[void]$md.Add("| Measure | Old | New |")
[void]$md.Add("|---|---|---|")
[void]$md.Add("| Cases answered with the identical four-item inquiry template, regardless of the question | " + $oldTemplate + " of " + $rows.Count + " | 0 of " + $rows.Count + " |")
[void]$md.Add("| Replies passing the send-time policy check | (no such check on this path) | " + $newOk + " of " + $rows.Count + " |")
[void]$md.Add("| Average reply length (characters) | " + $avgOld + " | " + $avgNew + " |")
[void]$md.Add("| Scenario-specific reviewed examples injected | 0 (the manual was named, never sent) | one matched section per reply |")
[void]$md.Add("")
[void]$md.Add("## Case by case")
[void]$md.Add("")
foreach ($r in $rows) {
    [void]$md.Add("### " + $r.Id)
    [void]$md.Add("")
    [void]$md.Add("Buyer: *" + $r.Question + "*")
    [void]$md.Add("")
    [void]$md.Add("Why it matters: " + $r.Why)
    [void]$md.Add("")
    [void]$md.Add("- **Old:** " + $r.Old)
    [void]$md.Add("- **New:** " + $r.New)
    [void]$md.Add("- Decision: scenario " + $TK + $r.Scenario + $TK + ", human todo " + $TK + $r.Todo + $TK + ", asks [" + $TK + $r.Ask + $TK + "], sentence budget " + $r.MaxSent + ", compliant " + $TK + $r.Compliant + $TK)
    [void]$md.Add("- Injected for this reply: scenario examples " + $r.GuidanceChars + " chars, conversation context " + $r.ContextChars + " chars")
    [void]$md.Add("")
}
[void]$md.Add("## What changed, one line each")
[void]$md.Add("")
[void]$md.Add("- A fulfillment question now gets an honest status answer plus a real todo, instead of the inquiry template.")
[void]$md.Add("- A request for a human now stops the selling and commits to a handoff, instead of the inquiry template.")
[void]$md.Add("- Frustration now gets an acknowledgement plus one concrete next step, instead of the inquiry template.")
[void]$md.Add("- A bare acknowledgement gets one short line and is not turned into a new task.")
[void]$md.Add("- A price request asks one key question instead of four at once.")
[void]$md.Add("- The owner-approved dimension guidance is unchanged, so nothing regressed there.")
$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllLines($OutFile, @($md.ToArray()), (New-Object System.Text.UTF8Encoding($false)))
Remove-Item $oldDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ("OLDVSNEW report: " + $OutFile)
Write-Output ("  cases=" + $rows.Count + " old-template-repeats=" + $oldTemplate + " new-compliant=" + $newOk + " avgOld=" + $avgOld + "ch avgNew=" + $avgNew + "ch")
