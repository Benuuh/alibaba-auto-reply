# lib\suggestions.ps1 - Suggestion store for the review-then-apply improvement flow.
#
# WHY THIS REPLACES THE OLD auto_optimize BEHAVIOR (spec 5, "automatic optimization becomes
# suggestion-only", confirmed by the user):
#   The old scripts\auto_optimize.ps1 ran daily at 05:30 and wrote DIRECTLY into the live corpus:
#   it appended up to 5 "never" rules into reply_rules.never and appended Chinese "red line" lines
#   into reply_agent_prompt.md, then triggered a merge pass. The damage is still visible in git
#   history: 40 never-rules with heavy semantic overlap, and a 55-line auto-appended block inside
#   the prompt that mixed three generations of duplicated advice. Nobody reviewed any of it.
#
# THIS MODULE ONLY EVER WRITES INSIDE THE SUGGESTION DIRECTORY. It never touches reply_rules.json,
# reply_agent_prompt.md or reply_scenarios.md. Applying a suggestion is a separate, explicit act
# performed by scripts\apply_suggestion.ps1 after a human accepts it.
#
# Suggestion record (JSON):
#   id               stable id derived from target + proposed content, so the same idea always maps
#                    to the same record instead of piling up as a new row every day
#   status           pending | accepted | rejected | applied | apply-failed
#   seenCount        how many times generation has re-proposed this exact idea
#   baseHash         sha256 of the target file AT GENERATION TIME; applying refuses to proceed if
#                    the file changed since, so a later manual edit is never silently overwritten
#   decisions        append-only audit trail of accept/reject/apply attempts
#
# Dependency: none (pure file IO plus hashing).

$script:SuggestionSchemaVersion = 1

function Get-SuggestionDir([string]$DataDir) {
    if ([string]::IsNullOrWhiteSpace($DataDir)) { throw 'Get-SuggestionDir requires -DataDir' }
    return (Join-Path $DataDir 'suggestions')
}

function Get-SuggestionStorePath([string]$DataDir) {
    return (Join-Path (Get-SuggestionDir $DataDir) 'suggestions.json')
}

function Get-FileSha256([string]$Path) {
    if (-not $Path -or -not (Test-Path $Path)) { return '' }
    try {
        $h = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ([System.BitConverter]::ToString($h.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } catch { return '' }
}

# Stable id: same target + same proposed change => same id, forever. This is what makes "do not
# resubmit a rejected suggestion every day" mechanically enforceable instead of aspirational.
function New-SuggestionId([string]$TargetFile, [string]$TargetPointer, [string]$Proposed) {
    $seed = ((($TargetFile + '|' + $TargetPointer + '|' + $Proposed) -replace '\s+', ' ').Trim()).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hex = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seed)))).Replace('-', '').ToLowerInvariant()
    return 'sug-' + $hex.Substring(0, 16)
}

function New-EmptySuggestionStore {
    return [pscustomobject]@{
        schemaVersion = $script:SuggestionSchemaVersion
        updated       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        suggestions   = @()
    }
}

function Read-SuggestionStore([string]$DataDir) {
    $p = Get-SuggestionStorePath $DataDir
    if (-not (Test-Path $p)) { return (New-EmptySuggestionStore) }
    try {
        $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j) { return (New-EmptySuggestionStore) }
        if (-not ($j.PSObject.Properties.Name -contains 'suggestions')) { $j | Add-Member -NotePropertyName suggestions -NotePropertyValue @() }
        if (-not $j.suggestions) { $j.suggestions = @() }
        return $j
    } catch {
        # A corrupt store must not be silently replaced with an empty one: that would lose every
        # recorded decision and let already-rejected ideas come back. Fail loudly instead.
        throw ('suggestion store is unreadable: ' + $p + ' - ' + $_.Exception.Message)
    }
}

function Save-SuggestionStore([string]$DataDir, $Store) {
    $dir = Get-SuggestionDir $DataDir
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Store.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $json = $Store | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText((Get-SuggestionStorePath $DataDir), $json, (New-Object System.Text.UTF8Encoding($false)))
    return (Get-SuggestionStorePath $DataDir)
}

# Hard constraints a suggestion may NEVER touch. Spec 5: "hard constraints must not be removable by
# a keep-the-newest-N truncation policy, and style suggestions must not relax business facts, fee
# commitments, identity checks or send protection." Enforced at INTAKE, so such an idea is refused
# before it is even stored, and again at APPLY time.
$script:HardConstraintPointers = @(
    'banned_phrases',
    'pricing',
    'reply_rules.always',
    'identity',
    'send_protection',
    'should_reply'
)
$script:HardConstraintKeywords = @(
    'price', 'pricing', 'quote', 'rate', 'discount',
    'reimburse', 'refund', 'compensate', 'liability', 'responsible',
    'manager', 'supervisor', 'boss',
    'contact', 'whatsapp', 'wechat',
    'identity', 'wrong convo', 'wrong buyer',
    'send protection', 'write lock', 'page health',
    'american english', 'banned'
)

function Test-HardConstraintSuggestion {
    [CmdletBinding()]
    param($Suggestion)
    $reasons = New-Object System.Collections.ArrayList
    $pointer = ''
    if ($Suggestion -and $Suggestion.target -and $Suggestion.target.pointer) { $pointer = [string]$Suggestion.target.pointer }
    foreach ($hp in $script:HardConstraintPointers) {
        if ($pointer -and ($pointer.ToLowerInvariant().Contains($hp.ToLowerInvariant()))) {
            [void]$reasons.Add('target pointer touches a hard-constraint section: ' + $hp)
        }
    }
    # A proposal that RELAXES something is identified by removal/negation wording. A proposal that
    # adds a restriction is allowed. This is deliberately conservative: refusing a good idea costs
    # one review cycle, relaxing a red line costs a real incident.
    $text = ''
    if ($Suggestion) { $text = ([string]$Suggestion.title + ' ' + [string]$Suggestion.expectedImpact) }
    if ($Suggestion -and $Suggestion.change) {
        $text += ' ' + [string]$Suggestion.change.after
        if ($Suggestion.change.before) { $text += ' ' + [string]$Suggestion.change.before }
    }
    $lt = $text.ToLowerInvariant()
    if ($lt -match '\b(remove|delete|drop|relax|loosen|no longer|stop (enforcing|checking)|disable|allow (a )?(price|discount|contact)|permit)\b') {
        foreach ($kw in $script:HardConstraintKeywords) {
            if ($lt.Contains($kw)) {
                [void]$reasons.Add('proposal appears to relax a hard constraint involving: ' + $kw)
                break
            }
        }
    }
    $list = @($reasons.ToArray())
    return [pscustomobject]@{ Allowed = ($list.Count -eq 0); Reasons = $list }
}

# Merge-or-insert. Returns @{ Id; Created; Merged; Status; Refused; RefuseReasons }.
#   - Re-proposing an existing idea bumps seenCount and refreshes the evidence only. The STATUS is
#     never reset: a rejected idea stays rejected and is NOT resubmitted as pending (spec 5).
function Add-Suggestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$TargetFile,
        [Parameter(Mandatory = $true)][string]$TargetPointer,
        [Parameter(Mandatory = $true)][string]$Proposed,
        [string]$Title = '',
        [string]$Evidence = '',
        [string]$ExpectedImpact = '',
        [string]$ConflictNote = '',
        [string]$OfflineValidation = '',
        [string]$BaseHash = ''
    )
    $sug = [pscustomobject]@{
        target = [pscustomobject]@{ file = $TargetFile; pointer = $TargetPointer }
        change = [pscustomobject]@{ before = $null; after = $Proposed }
        title  = $Title
        expectedImpact = $ExpectedImpact
    }
    $guard = Test-HardConstraintSuggestion $sug
    if (-not $guard.Allowed) {
        return [pscustomobject]@{ Id = ''; Created = $false; Merged = $false; Status = 'refused'; Refused = $true; RefuseReasons = @($guard.Reasons) }
    }

    $id = New-SuggestionId $TargetFile $TargetPointer $Proposed
    $store = Read-SuggestionStore $DataDir
    $existing = @($store.suggestions | Where-Object { $_.id -eq $id })
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if ($existing.Count -gt 0) {
        $rec = $existing[0]
        $rec.seenCount = [int]$rec.seenCount + 1
        $rec.lastSeen = $now
        if ($Evidence) { $rec.evidence = $Evidence }
        if ($OfflineValidation) { $rec.offlineValidation = $OfflineValidation }
        if ($BaseHash) { $rec.baseHash = $BaseHash }
        Save-SuggestionStore $DataDir $store | Out-Null
        return [pscustomobject]@{ Id = $id; Created = $false; Merged = $true; Status = [string]$rec.status; Refused = $false; RefuseReasons = @() }
    }

    $rec = [pscustomobject]@{
        id                = $id
        schemaVersion     = $script:SuggestionSchemaVersion
        status            = 'pending'
        created           = $now
        lastSeen          = $now
        seenCount         = 1
        title             = $Title
        evidence          = $Evidence
        target            = [pscustomobject]@{ file = $TargetFile; pointer = $TargetPointer }
        change            = [pscustomobject]@{ before = $null; after = $Proposed }
        expectedImpact    = $ExpectedImpact
        conflictCheck     = $ConflictNote
        offlineValidation = $OfflineValidation
        baseHash          = $BaseHash
        decisions         = @()
        appliedAt         = ''
        applyFailure      = ''
    }
    $store.suggestions = @($store.suggestions) + $rec
    Save-SuggestionStore $DataDir $store | Out-Null
    return [pscustomobject]@{ Id = $id; Created = $true; Merged = $false; Status = 'pending'; Refused = $false; RefuseReasons = @() }
}

function Get-SuggestionById([string]$DataDir, [string]$Id) {
    if (-not $Id) { return $null }
    $store = Read-SuggestionStore $DataDir
    $hit = @($store.suggestions | Where-Object { $_.id -eq $Id })
    if ($hit.Count -eq 0) { return $null }
    return $hit[0]
}

# Record a human decision. Only 'accept' makes a suggestion applicable, and only this function can
# set it, so a scheduled run, a file existing, or the model's own opinion can never apply anything.
function Set-SuggestionDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('accept', 'reject')][string]$Action,
        [string]$Note = ''
    )
    $store = Read-SuggestionStore $DataDir
    $hit = @($store.suggestions | Where-Object { $_.id -eq $Id })
    if ($hit.Count -eq 0) { throw ('suggestion not found: ' + $Id) }
    $rec = $hit[0]
    if ($rec.status -eq 'applied') { throw ('suggestion already applied, refusing to re-decide: ' + $Id) }
    if ($Action -eq 'accept') { $rec.status = 'accepted' } else { $rec.status = 'rejected' }
    $rec.decisions = @($rec.decisions) + [pscustomobject]@{
        at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); action = $Action; by = 'user'; note = $Note
    }
    Save-SuggestionStore $DataDir $store | Out-Null
    return $rec
}

function Set-SuggestionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DataDir,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Note = ''
    )
    $store = Read-SuggestionStore $DataDir
    $hit = @($store.suggestions | Where-Object { $_.id -eq $Id })
    if ($hit.Count -eq 0) { throw ('suggestion not found: ' + $Id) }
    $rec = $hit[0]
    $rec.status = $Status
    if ($Status -eq 'applied') { $rec.appliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Status -eq 'apply-failed') { $rec.applyFailure = $Note }
    $rec.decisions = @($rec.decisions) + [pscustomobject]@{
        at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); action = $Status; by = 'apply'; note = $Note
    }
    Save-SuggestionStore $DataDir $store | Out-Null
    return $rec
}

function Get-SuggestionsByStatus([string]$DataDir, [string]$Status = '') {
    $store = Read-SuggestionStore $DataDir
    if (-not $Status) { return @($store.suggestions) }
    return @($store.suggestions | Where-Object { $_.status -eq $Status })
}
