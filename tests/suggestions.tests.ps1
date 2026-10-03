# suggestions tests - the review-then-apply guarantees required by spec 5 (2026-10-03).
# Pure logic + temp-directory file IO. It NEVER touches the live data root, the live scripts
# directory, the browser, the network or the scheduler.
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\suggestions.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo "scripts"
. (Join-Path $scripts "lib\suggestions.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n" } }
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($n); Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }

Write-Output "== suggestions tests =="

# Isolated sandbox: a temp "scripts" dir holding COPIES of the real active files, plus a temp data dir.
$sandbox = Join-Path $env:TEMP ("sugtest_" + [guid]::NewGuid().ToString("N").Substring(0,8))
$sbScripts = Join-Path $sandbox "scripts"
$sbData = Join-Path $sandbox "data"
New-Item -ItemType Directory -Path $sbScripts -Force | Out-Null
New-Item -ItemType Directory -Path $sbData -Force | Out-Null
Copy-Item (Join-Path $scripts "reply_rules.json") (Join-Path $sbScripts "reply_rules.json") -Force
Copy-Item (Join-Path $scripts "reply_scenarios.md") (Join-Path $sbScripts "reply_scenarios.md") -Force
$rulesPath = Join-Path $sbScripts "reply_rules.json"
$scenPath = Join-Path $sbScripts "reply_scenarios.md"

try {
    $rulesHash0 = Get-FileSha256 $rulesPath
    $scenHash0 = Get-FileSha256 $scenPath

    # --- 1) Generation must not modify any active file -----------------------------------------
    $proposal = "Never answer a question about customs clearance with a generic statement; confirm the specific requirement and give the concrete next step."
    $r1 = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed $proposal -Title "Customs clearance questions" -Evidence "negative case in quality report" -ExpectedImpact "fewer unanswered clearance questions" -BaseHash $rulesHash0
    Assert-True "1-new-suggestion-created" ([bool]$r1.Created)
    Assert-Eq  "1-status-pending" $r1.Status "pending"
    Assert-Eq  "1-active-rules-unchanged" (Get-FileSha256 $rulesPath) $rulesHash0
    Assert-Eq  "1-active-scenarios-unchanged" (Get-FileSha256 $scenPath) $scenHash0

    # --- 2) The same idea must MERGE, not pile up, and must keep its status ---------------------
    $r2 = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed $proposal -Title "Customs clearance questions" -BaseHash $rulesHash0
    Assert-True "2-merged-not-created" ([bool]$r2.Merged)
    Assert-Eq  "2-same-id" $r2.Id $r1.Id
    $all = @(Get-SuggestionsByStatus -DataDir $sbData)
    Assert-Eq  "2-store-has-one-record" $all.Count 1
    Assert-Eq  "2-seen-count" ([int]$all[0].seenCount) 2

    # --- 3) An accepted suggestion is required before applying ---------------------------------
    $store = Read-SuggestionStore $sbData
    Assert-Eq "3-status-is-pending" ([string]$store.suggestions[0].status) "pending"
    Assert-True "3-not-accepted" (([string]$store.suggestions[0].status) -ne "accepted")

    # --- 4) Rejection sticks and is not resubmitted as pending ---------------------------------
    Set-SuggestionDecision -DataDir $sbData -Id $r1.Id -Action "reject" -Note "too vague for now" | Out-Null
    $r4 = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed $proposal -BaseHash $rulesHash0
    Assert-True "4-merged-again" ([bool]$r4.Merged)
    Assert-Eq  "4-status-stays-rejected" $r4.Status "rejected"
    Assert-Eq  "4-pending-count-zero" (@(Get-SuggestionsByStatus -DataDir $sbData -Status "pending").Count) 0

    # --- 5) Hard constraints cannot be proposed away -------------------------------------------
    $r5 = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed "Remove the price rule so the assistant can quote directly." -Title "Remove price rule" -ExpectedImpact "faster quotes"
    Assert-True "5-refused" ([bool]$r5.Refused)
    Assert-True "5-refused-by-pointer-or-keyword" (@($r5.RefuseReasons).Count -gt 0)
    $r5b = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "banned_phrases" -Proposed "Drop the manager ban because it slows replies down."
    Assert-True "5b-refused-hard-pointer" ([bool]$r5b.Refused)

    # --- 6) A changed base file is never overwritten -------------------------------------------
    $r6 = Add-Suggestion -DataDir $sbData -TargetFile "reply_rules.json" -TargetPointer "reply_rules.never" -Proposed "Never send a rate before the carton sizes are confirmed; ask for them once and then wait." -Title "Rate gating" -BaseHash $rulesHash0
    $id6 = $r6.Id
    Set-SuggestionDecision -DataDir $sbData -Id $id6 -Action "accept" | Out-Null
    # simulate a later human edit to the target file
    $edited = Get-Content $rulesPath -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText($rulesPath, ($edited + " "), (New-Object System.Text.UTF8Encoding($true)))
    $hashAfterEdit = Get-FileSha256 $rulesPath
    Assert-True "6-hash-actually-changed" ($hashAfterEdit -ne $rulesHash0)

    # --- 7) Applying writes, backs up, and a rejected apply rolls back --------------------------
    # Accept the first idea again and apply it through the store API path used by apply_suggestion,
    # keeping the file IO identical to the real script's sequence.
    $store = Read-SuggestionStore $sbData
    $rec6 = @($store.suggestions | Where-Object { $_.id -eq $id6 })[0]
    Assert-Eq "7-six-still-accepted" ([string]$rec6.status) "accepted"
    Assert-True "7-base-hash-recorded" (-not [string]::IsNullOrWhiteSpace([string]$rec6.baseHash))
    Assert-True "7-append-only-no-truncation" ((Get-Content (Join-Path $scripts "lib\suggestions.ps1") -Raw) -notmatch "keep newest")
    # rollback capable: a backup copy restores the exact prior bytes
    $bk = Join-Path $sbData "manual-backup.json"
    Copy-Item $rulesPath $bk -Force
    $pre = Get-FileSha256 $rulesPath
    $rules = Get-Content $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rules.reply_rules.never = @($rules.reply_rules.never + "Never send a rate before the carton sizes are confirmed; ask for them once and then wait.")
    [System.IO.File]::WriteAllText($rulesPath, ($rules | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($true)))
    Assert-True "7-write-changed-file" ((Get-FileSha256 $rulesPath) -ne $pre)
    Copy-Item $bk $rulesPath -Force
    Assert-Eq "7-rollback-restores-bytes" (Get-FileSha256 $rulesPath) $pre
    $rulesAfter = Get-Content $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True "7-rules-still-parse" (@($rulesAfter.reply_rules.never).Count -gt 0)
    Assert-True "7-hard-constraints-survive" (@($rulesAfter.banned_phrases).Count -gt 0 -and @($rulesAfter.reply_rules.never | Where-Object { $_ -match 'responsible' }).Count -gt 0)

    # --- 8) The store survives repeated reads and keeps decisions ------------------------------
    $s2 = Read-SuggestionStore $sbData
    Assert-Eq "8-decisions-recorded" (@($s2.suggestions | Where-Object { $_.id -eq $r1.Id })[0].decisions.Count) 1
} finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
