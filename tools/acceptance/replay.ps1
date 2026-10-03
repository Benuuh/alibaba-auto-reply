# tools\acceptance\replay.ps1 - OFFLINE acceptance replay for the reply chain.
#
# WHAT THIS IS
#   A scenario-driven, network-free replay of the REAL reply chain:
#       ConvertTo-MessageList -> Get-ConversationFacts -> Get-ReplyDecision
#       -> Invoke-ReplyGeneration -> Test-ReplyCompliance
#   The production files are dot-sourced from the repo. monitor.ps1 is NEVER loaded, no browser is
#   touched, and there is no real model: Invoke-LLM is a deterministic stub defined in this session
#   BEFORE generation runs, so the model boundary is a scripted string.
#
# WHAT IS REAL vs FAKE
#   REAL     : every decision, every context block, every fallback wording, every compliance check,
#              message normalization and identity, the rules JSON, the prompt and the scenario file.
#   FAKE     : the model (scripted), and the clock used for the timing report (simulated).
#   MEASURED : model call counts, system/context character counts, order confidence, wall time.
#
# SAFETY
#   All output goes to -WorkDir (default: a fresh directory under the user temp dir). The script
#   REFUSES to run if -WorkDir resolves inside the repo or inside the live data root
#   (resolved from local config, with a sibling runtime-root fallback), because nothing here may touch production data.
#   Nothing in this file sends a message, starts a service or calls the network.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1 -WorkDir C:\temp\aar1
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1 -Filter '0[1-9]*'
#   Exit code 0 = every assertion passed; 1 = at least one failed; 2 = refused to run (unsafe WorkDir).

[CmdletBinding()]
param(
    [string]$WorkDir = '',
    [string]$ScenarioDir = '',
    [string]$RepoRoot = '',
    [string]$Filter = '*',
    [string]$FirstSeenAt = '',
    [string]$SentAt = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$LF = [string][char]10

# ---------------------------------------------------------------------------------------------
# Paths and safety
# ---------------------------------------------------------------------------------------------
if (-not $RepoRoot) { $RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$RepoRoot = (Resolve-Path $RepoRoot).Path
if (-not $ScenarioDir) { $ScenarioDir = Join-Path $RepoRoot 'tests\scenarios' }
if (-not (Test-Path $ScenarioDir)) { throw "scenario directory not found: $ScenarioDir" }

$liveRoot = [IO.Path]::GetFullPath($RepoRoot + '-runtime')
$protectedPaths = @($RepoRoot, $liveRoot)
$localConfig = Join-Path $RepoRoot 'scripts\config.json'
if (Test-Path -LiteralPath $localConfig) {
    $localCfg = Get-Content -LiteralPath $localConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pathKey in @('data_dir', 'logs_dir', 'reports_dir', 'backups_dir', 'chrome_profile')) {
        $value = [string]$localCfg.$pathKey
        if ($value) { $protectedPaths += [IO.Path]::GetFullPath($value) }
    }
}
if (-not $WorkDir) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $WorkDir = Join-Path $env:TEMP ('aar_acceptance_' + $stamp + '_' + $PID)
}
if (-not (Test-Path $WorkDir)) { [void](New-Item -ItemType Directory -Path $WorkDir -Force) }
$WorkDir = (Resolve-Path $WorkDir).Path

$unsafe = $false
if ($WorkDir.ToLowerInvariant().StartsWith($RepoRoot.ToLowerInvariant())) { $unsafe = $true }
foreach ($protectedPath in $protectedPaths) {
    if ($WorkDir.StartsWith($protectedPath, [StringComparison]::OrdinalIgnoreCase)) { $unsafe = $true }
}
if ($WorkDir.ToLowerInvariant() -match 'alibaba-auto-reply-runtime') { $unsafe = $true }
if ($unsafe) {
    Write-Output ("REFUSED: -WorkDir '" + $WorkDir + "' is inside the repo or the live data root. " +
        "This harness must never write there. Pass -WorkDir <temp path>.")
    exit 2
}

# ---------------------------------------------------------------------------------------------
# Load the REAL production modules. monitor.ps1 is deliberately NOT loaded, and lib\llm.ps1
# (the only file that could reach the network) is deliberately NOT loaded either.
# ---------------------------------------------------------------------------------------------
$enginePath   = Join-Path $RepoRoot 'scripts\reply_engine.ps1'
$msgNormPath  = Join-Path $RepoRoot 'scripts\lib\msg_norm.ps1'
$policyPath   = Join-Path $RepoRoot 'scripts\lib\reply_policy.ps1'
$genPath      = Join-Path $RepoRoot 'scripts\lib\reply_gen.ps1'
$rulesPath    = Join-Path $RepoRoot 'scripts\reply_rules.json'
$promptPath   = Join-Path $RepoRoot 'scripts\reply_agent_prompt.md'
$scenarioPath = Join-Path $RepoRoot 'scripts\reply_scenarios.md'
$llmPath      = Join-Path $RepoRoot 'scripts\lib\llm.ps1'
foreach ($p in @($enginePath, $msgNormPath, $policyPath, $genPath, $rulesPath, $promptPath, $scenarioPath)) {
    if (-not (Test-Path $p)) { throw "required production file missing: $p" }
}

# ---------------------------------------------------------------------------------------------
# The fake model. Defined BEFORE any generation call, so no other Invoke-LLM can exist.
# Modes (per scenario, from the fixture):
#   compliant                : call 1 -> compliantReply                       (1 call)
#   violation_then_compliant : call 1 -> violation, call 2 -> compliant       (2 calls, rewrite)
#   violation_then_null      : call 1 -> violation, call 2 -> $null           (2 calls, fallback)
#   always_violation         : every call -> violation                        (2 calls, fallback)
#   null                     : every call -> $null                            (1 call, fallback)
# ---------------------------------------------------------------------------------------------
$script:Fake = [pscustomobject]@{
    Mode           = 'compliant'
    CallIndex      = 0
    Calls          = (New-Object System.Collections.ArrayList)
    CompliantReply = ''
    ViolationReply = ''
}
$script:FakeStubMarker = 'aar-acceptance-fake-llm-v1'

function Invoke-LLM {
    param($Messages, $Temperature, $MaxTokens, $LogFile)
    $script:Fake.CallIndex++
    $sys = ''
    $usr = ''
    foreach ($m in @($Messages)) {
        if ($null -eq $m) { continue }
        $role = [string]$m.role
        if ($role -eq 'system') { $sys = [string]$m.content }
        elseif ($role -eq 'user') { $usr = [string]$m.content }
    }
    [void]$script:Fake.Calls.Add([pscustomobject]@{
        Index       = $script:Fake.CallIndex
        SystemChars = $sys.Length
        UserChars   = $usr.Length
        TotalChars  = ($sys.Length + $usr.Length)
        System      = $sys
        User        = $usr
    })
    $text = $null
    switch ($script:Fake.Mode) {
        'compliant'                { $text = $script:Fake.CompliantReply }
        'violation_then_compliant' { if ($script:Fake.CallIndex -eq 1) { $text = $script:Fake.ViolationReply } else { $text = $script:Fake.CompliantReply } }
        'violation_then_null'      { if ($script:Fake.CallIndex -eq 1) { $text = $script:Fake.ViolationReply } else { $text = $null } }
        'always_violation'         { $text = $script:Fake.ViolationReply }
        'null'                     { $text = $null }
        default                    { $text = $null }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

. $enginePath
. $msgNormPath
. $policyPath
. $genPath

# Guard rails: prove that the model is the stub and that the network-capable module was not loaded.
if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) { throw 'fake Invoke-LLM did not register' }
if (Get-Command Get-LLMConfig -ErrorAction SilentlyContinue) { throw 'lib\llm.ps1 appears to be loaded: refusing to run (a real model call would be possible)' }

$rules = Get-Content -Path $rulesPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------------------------------------------------------------------------------------------
# Assertion bookkeeping
# ---------------------------------------------------------------------------------------------
$script:Failures = New-Object System.Collections.ArrayList
$script:Checks   = 0
$script:Results  = New-Object System.Collections.ArrayList
$script:Notes    = New-Object System.Collections.ArrayList

function Add-Check {
    param([string]$Scenario, [string]$Id, [bool]$Ok, [string]$Detail = '')
    $script:Checks++
    if (-not $Ok) { [void]$script:Failures.Add([pscustomobject]@{ Scenario = $Scenario; Id = $Id; Detail = $Detail }) }
    return $Ok
}

function Get-JProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-SentenceCount([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    return @(($Text -split '[.!?]+') | Where-Object { $_.Trim().Length -gt 0 }).Count
}

# Approximate "is the reply asking for this field": an ask verb within 40 characters of a field
# keyword in the same sentence. Deliberately a proximity heuristic, NOT language understanding;
# see tools\acceptance\README.md, section "what this does not prove".
$script:FieldKeywords = @{
    weight    = 'weight|weights|kg|kgs|kilo|kilos|gross weight'
    dimension = 'dimension|dimensions|size|sizes|carton size|carton sizes|measurement|measurements|l\s?x\s?w\s?x\s?h|cm|mm'
    address   = 'address|addresses|delivery address|zip|postal code|destination'
    image     = 'image|images|photo|photos|picture|pictures'
    supplier  = 'supplier|suppliers|vendor|factory|factories'
}
$script:AskVerbs = "share|send|provide|confirm|need|tell me|let me know|what(?:'s| is| are)|could you|can you|do you have|give me|looking for"

function Test-ReasksField([string]$Text, [string]$Field) {
    $kw = $script:FieldKeywords[$Field]
    if (-not $kw) { return $false }
    $pat = '(?i)\b(' + $script:AskVerbs + ')\b[^.!?]{0,40}\b(' + $kw + ')\b'
    return [bool]($Text -match $pat)
}

function Test-Forbidden {
    param([string]$Text, $Entries)
    $hits = New-Object System.Collections.ArrayList
    foreach ($e in @($Entries)) {
        if ($null -eq $e) { continue }
        $pattern = [string](Get-JProp $e 'pattern')
        if (-not $pattern) { continue }
        $kind = [string](Get-JProp $e 'kind')
        if (-not $kind) { $kind = 'regex' }
        $hit = $false
        if ($kind -eq 'substring') {
            $hit = ($Text.ToLowerInvariant().IndexOf($pattern.ToLowerInvariant()) -ge 0)
        } else {
            $hit = [bool]($Text -match $pattern)
        }
        if ($hit) {
            [void]$hits.Add([pscustomobject]@{ Pattern = $pattern; Kind = $kind; Why = [string](Get-JProp $e 'why') })
        }
    }
    return @($hits.ToArray())
}

function Get-ContextSection {
    param([string]$Context, [string]$Header, [string]$NextHeader)
    $pat = '(?s)' + [regex]::Escape($Header) + '\r?\n(.*?)\r?\n\r?\n' + [regex]::Escape($NextHeader)
    $m = [regex]::Match($Context, $pat)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

# Chronological check: every conversation line the block actually contains must appear in ascending
# message order (messages omitted by middle-trimming are simply not found, which is fine).
function Test-ContextChronological {
    param([string]$Context, $Messages)
    $pos = -1
    $seen = 0
    foreach ($m in @($Messages)) {
        $tag = '[ME] '
        if ($m.Role -eq 'buyer') { $tag = '[BUYER] ' }
        elseif ($m.Source -eq 'human') { $tag = '[ME-OWNER] ' }
        $needle = $tag + $m.Text
        $i = $Context.IndexOf($needle, $pos + 1)
        if ($i -lt 0) { continue }
        if ($i -le $pos) { return @{ Ok = $false; Detail = ('out of order at Seq ' + $m.Seq) } }
        $pos = $i
        $seen++
    }
    return @{ Ok = $true; Detail = ('lines checked: ' + $seen) }
}

function ConvertFrom-IsoUtc([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try {
        return [datetime]::Parse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    } catch { return $null }
}

function Get-Timing {
    param($Scenario, [string]$FirstOverride, [string]$SentOverride)
    $clock = Get-JProp $Scenario 'clock'
    $firstTxt = [string](Get-JProp $clock 'firstSeenAt')
    $sentTxt = [string](Get-JProp $clock 'sentAt')
    if ($FirstOverride) { $firstTxt = $FirstOverride }
    if ($SentOverride) { $sentTxt = $SentOverride }
    $first = ConvertFrom-IsoUtc $firstTxt
    $sent = ConvertFrom-IsoUtc $sentTxt
    $lat = $null
    # NEVER report zero for an unknown origin: an unknown origin is reported as UNKNOWN, not 0.
    if ($null -ne $first -and $null -ne $sent) { $lat = [math]::Round(($sent - $first).TotalSeconds, 1) }
    $firstOut = 'UNKNOWN'
    if ($null -ne $first) { $firstOut = $first.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $sentOut = 'UNKNOWN'
    if ($null -ne $sent) { $sentOut = $sent.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $latOut = 'UNKNOWN'
    if ($null -ne $lat) { $latOut = [string]$lat }
    return [pscustomobject]@{ FirstSeen = $firstOut; Sent = $sentOut; LatencySeconds = $lat; LatencyText = $latOut }
}

# ---------------------------------------------------------------------------------------------
# Fixture integrity: the @@OT marker must be the real base64 of the visible text.
# ---------------------------------------------------------------------------------------------
function Test-FixtureIntegrity {
    param([string]$ScenarioId, [string[]]$Lines)
    $ok = $true
    foreach ($ln in $Lines) {
        $m = [regex]::Match($ln, '@@OT:([A-Za-z0-9\+/=]+)')
        if (-not $m.Success) { continue }
        $plain = $ln -replace '^\[(BUYER|ME)\]\s*', ''
        $plain = $plain -replace '@@IMG:[^\s]*', ''
        $plain = $plain -replace '@@FILE:[^\s]*', ''
        $plain = $plain -replace '@@TS:[^\s]*', ''
        $plain = $plain -replace '@@OT:[A-Za-z0-9\+/=]+', ''
        $plain = $plain.Trim()
        $decoded = ''
        try { $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value)) } catch { $decoded = '<not valid base64>' }
        if ($decoded -ne $plain) {
            $ok = Add-Check $ScenarioId 'fixture-ot-matches-visible-text' $false ("@@OT decoded to '" + $decoded + "' but the visible text is '" + $plain + "'")
        }
    }
    if ($ok) { [void](Add-Check $ScenarioId 'fixture-ot-matches-visible-text' $true '') }
    return $ok
}

# ---------------------------------------------------------------------------------------------
# Scenario loading
# ---------------------------------------------------------------------------------------------
$files = @(Get-ChildItem -Path $ScenarioDir -Filter '*.json' | Sort-Object Name | Where-Object { $_.Name -like $Filter })
if ($files.Count -eq 0) { throw "no scenario files matched '" + $Filter + "' in " + $ScenarioDir }

$requiredCoverage = @(
    'cargo-received query', 'ambiguous address meaning', 'supplier handoff failure',
    'buyer asks for a human', 'repeated chasing', 'angry buyer', 'unknown quote',
    'dimensions already given', 'buyer promises details later', 'simple acknowledgement',
    'image-only message', 'file parse failure', 'several short messages in a row',
    'same text as a new message', 'human already answered', 'notification failure'
)

if (-not $Quiet) {
    Write-Output '=============================================================='
    Write-Output ' OFFLINE ACCEPTANCE REPLAY - reply chain (no network, no browser)'
    Write-Output '=============================================================='
    Write-Output (' repo         : ' + $RepoRoot)
    Write-Output (' scenarios    : ' + $ScenarioDir + "  (filter '" + $Filter + "', " + $files.Count + ' file(s))')
    Write-Output (' work dir     : ' + $WorkDir)
    Write-Output (' msg schema   : ' + (Get-MsgSchemaVersion))
    Write-Output (' model        : FAKE stub Invoke-LLM (marker ' + $script:FakeStubMarker + '), lib\llm.ps1 NOT loaded')
    Write-Output ''
}

$coverageSeen = New-Object System.Collections.ArrayList

foreach ($f in $files) {
    $scenario = (Get-Content -Path $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
    $id = [string](Get-JProp $scenario 'id')
    if (-not $id) { $id = $f.BaseName }
    $title = [string](Get-JProp $scenario 'title')
    $category = [string](Get-JProp $scenario 'category')
    if ($category) { [void]$coverageSeen.Add($category) }
    $expectedAction = [string](Get-JProp $scenario 'expectedAction')
    $lines = @(Get-JProp $scenario 'conversationLines' | ForEach-Object { [string]$_ })
    $raw = $lines -join $LF

    [void](Test-FixtureIntegrity $id $lines)

    # ---- REAL normalization ----
    $conv = ConvertTo-MessageList $raw 'Buyer A'
    $facts = Get-ConversationFacts $conv

    # ---- REAL decision ----
    $notify = [bool](Get-JProp $scenario 'notifyChannelAvailable')
    $decision = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $rules -NotifyChannelAvailable:$notify

    # ---- REAL context block (the exact call reply_gen makes) ----
    $context = New-ReplyContextBlock -Conversation $conv -Decision $decision

    # ---- REAL generation against the FAKE model ----
    $fm = Get-JProp $scenario 'fakeModel'
    $mode = [string](Get-JProp $fm 'mode')
    if (-not $mode) { $mode = 'compliant' }
    $script:Fake.Mode = $mode
    $script:Fake.CallIndex = 0
    $script:Fake.Calls.Clear()
    $script:Fake.CompliantReply = [string](Get-JProp $fm 'compliantReply')
    $script:Fake.ViolationReply = [string](Get-JProp $fm 'violationReply')

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $gen = Invoke-ReplyGeneration -Conversation $conv -Decision $decision -Rules $rules -PromptPath $promptPath -ScenarioPath $scenarioPath -MaxRewrites 1
    $sw.Stop()

    $reply = [string]$gen.Text
    $calls = @($script:Fake.Calls.ToArray())

    # ---- expectations (chain-reported calls vs actual stub invocations are different numbers:
    #      the chain only counts a call that returned usable text) ----
    $defaultCalls = 1; $defaultStub = 1; $defaultSource = 'LLM'
    switch ($mode) {
        'compliant'                { $defaultCalls = 1; $defaultStub = 1; $defaultSource = 'LLM' }
        'violation_then_compliant' { $defaultCalls = 2; $defaultStub = 2; $defaultSource = 'LLM_REWRITE' }
        'violation_then_null'      { $defaultCalls = 1; $defaultStub = 2; $defaultSource = 'FALLBACK' }
        'always_violation'         { $defaultCalls = 2; $defaultStub = 2; $defaultSource = 'FALLBACK' }
        'null'                     { $defaultCalls = 0; $defaultStub = 1; $defaultSource = 'FALLBACK' }
    }
    $wantCalls = Get-JProp $scenario 'expectModelCalls'
    if ($null -eq $wantCalls) { $wantCalls = $defaultCalls }
    $wantStub = Get-JProp $scenario 'expectStubCalls'
    if ($null -eq $wantStub) { $wantStub = $defaultStub }
    $wantSource = [string](Get-JProp $scenario 'expectSource')
    if (-not $wantSource) { $wantSource = $defaultSource }

    # ===== assertions =====
    [void](Add-Check $id 'decision-scenario' ($decision.Scenario -eq $expectedAction) ("expected '" + $expectedAction + "' got '" + $decision.Scenario + "' reasons=[" + (@($decision.Reasons) -join '; ') + ']'))
    [void](Add-Check $id 'msg-schema' ($conv.Schema -eq (Get-MsgSchemaVersion)) ('schema ' + $conv.Schema))
    [void](Add-Check $id 'reply-not-empty' (-not [string]::IsNullOrWhiteSpace($reply)) 'reply is empty')

    $comp = Test-ReplyCompliance -Text $reply -Rules $rules
    [void](Add-Check $id 'reply-passes-policy' ([bool]$comp.Ok) ('violations=[' + (@($comp.Violations | ForEach-Object { $_.Code }) -join ',') + ']'))
    [void](Add-Check $id 'fallback-itself-compliant' ((Get-JProp $gen 'FallbackReason') -notmatch 'fallback-noncompliant') ([string]$gen.FallbackReason))

    $forbidden = @(Test-Forbidden $reply (Get-JProp $scenario 'forbiddenContent'))
    [void](Add-Check $id 'no-forbidden-content' ($forbidden.Count -eq 0) ('hit: ' + (@($forbidden | ForEach-Object { $_.Pattern }) -join ' | ')))

    # required qualities
    foreach ($q in @(Get-JProp $scenario 'requiredQualities')) {
        if ($null -eq $q) { continue }
        $qid = [string](Get-JProp $q 'id')
        $check = [string](Get-JProp $q 'check')
        $value = Get-JProp $q 'value'
        $ok = $true; $detail = ''
        switch ($check) {
            'maxSentences' { $n = Get-SentenceCount $reply; $ok = ($n -le [int]$value); $detail = ('' + $n + ' sentences, max ' + $value) }
            'maxChars'     { $n = $reply.Trim().Length; $ok = ($n -le [int]$value); $detail = ('' + $n + ' chars, max ' + $value) }
            'minChars'     { $n = $reply.Trim().Length; $ok = ($n -ge [int]$value); $detail = ('' + $n + ' chars, min ' + $value) }
            'maxQuestions' { $n = ([regex]::Matches($reply, '\?')).Count; $ok = ($n -le [int]$value); $detail = ('' + $n + ' question marks, max ' + $value) }
            'asksAQuestion' {
                $has = [bool]($reply -match '\?')
                $ok = ($has -eq [bool]$value); $detail = ('question mark present=' + $has + ' want=' + $value)
            }
            'mustMatch'    { $ok = [bool]($reply -match [string]$value); $detail = ("no match for '" + $value + "'") }
            'mustNotMatch' { $ok = -not [bool]($reply -match [string]$value); $detail = ("matched forbidden '" + $value + "'") }
            'noTimeCommitment' { $ok = -not (Test-TimeCommitment $reply); $detail = 'reply commits to a specific deadline' }
            'notSameAsPriorMe' {
                $norm = (Get-NormalizedMsgText $reply).ToLowerInvariant()
                foreach ($m in @($conv.Messages)) {
                    if ($m.Role -ne 'me') { continue }
                    if ((Get-NormalizedMsgText $m.Text).ToLowerInvariant() -eq $norm) { $ok = $false; $detail = ('identical to prior line Seq ' + $m.Seq) }
                }
                if ($ok) { $detail = 'differs from every prior [ME] line' }
            }
            'onlyAskableFields' {
                $allowed = @()
                if ($value -is [string] -and $value -eq '$decision') { $allowed = @($decision.AskFields) }
                else { $allowed = @($value | ForEach-Object { [string]$_ }) }
                $reasked = @()
                foreach ($k in @('weight', 'dimension', 'address', 'image', 'supplier')) {
                    if ($allowed -contains $k) { continue }
                    if (Test-ReasksField $reply $k) { $reasked += $k }
                }
                $ok = ($reasked.Count -eq 0)
                $detail = ('re-asks ' + ($reasked -join ',') + ' allowed=[' + ($allowed -join ',') + ']')
            }
            default { $ok = $false; $detail = "unknown check '" + $check + "'" }
        }
        [void](Add-Check $id ('quality:' + $qid) $ok $detail)
    }

    # decision-object expectations
    $ed = Get-JProp $scenario 'expectedDecision'
    if ($null -ne $ed) {
        foreach ($prop in @($ed.PSObject.Properties)) {
            $want = $prop.Value
            $got = Get-JProp $decision $prop.Name
            if ($prop.Name -eq 'askFields' -or $prop.Name -eq 'promisedFields') {
                $a = @(@($want | ForEach-Object { [string]$_ }) | Sort-Object)
                $b = @(@($got | ForEach-Object { [string]$_ }) | Sort-Object)
                [void](Add-Check $id ('decision:' + $prop.Name) ((($a -join ',') -eq ($b -join ','))) ('want [' + ($a -join ',') + '] got [' + ($b -join ',') + ']'))
            } else {
                [void](Add-Check $id ('decision:' + $prop.Name) ([string]$got -eq [string]$want) ("want '" + $want + "' got '" + $got + "'"))
            }
        }
    }

    # conversation expectations
    $wantBuyerCount = Get-JProp $scenario 'expectBuyerCount'
    if ($null -ne $wantBuyerCount) {
        [void](Add-Check $id 'buyer-count' (@($conv.BuyerMessages).Count -eq [int]$wantBuyerCount) ('got ' + @($conv.BuyerMessages).Count + ' want ' + $wantBuyerCount))
    }
    $wantLatest = [string](Get-JProp $scenario 'expectLatestBuyerText')
    if ($wantLatest) {
        $gotLatest = ''
        if ($conv.LatestBuyer) { $gotLatest = [string]$conv.LatestBuyer.Orig }
        [void](Add-Check $id 'latest-buyer-message' ($gotLatest -eq $wantLatest) ("got '" + $gotLatest + "' want '" + $wantLatest + "'"))
    }
    $wantSkipped = Get-JProp $scenario 'expectSkippedZero'
    if ($null -ne $wantSkipped -and [bool]$wantSkipped) {
        [void](Add-Check $id 'no-message-dropped' (@($conv.Skipped).Count -eq 0) ('skipped ' + @($conv.Skipped).Count + ' line(s)'))
    }
    $wantOrder = Get-JProp $scenario 'expectOrderConfident'
    if ($null -ne $wantOrder) {
        [void](Add-Check $id 'order-confident' ([bool]$decision.OrderConfident -eq [bool]$wantOrder) ('got ' + $decision.OrderConfident + ' (' + $decision.OrderReason + ') want ' + $wantOrder))
    }
    if ([bool](Get-JProp $scenario 'expectDistinctIdsForSameText')) {
        $buyers = @($conv.BuyerMessages)
        $found = $false; $confident = $true; $distinct = $true; $groups = 0
        for ($i = 0; $i -lt $buyers.Count; $i++) {
            for ($j = $i + 1; $j -lt $buyers.Count; $j++) {
                if ($buyers[$i].Orig -ne $buyers[$j].Orig) { continue }
                $groups++
                $found = $true
                if (-not $buyers[$i].IdConfident -or -not $buyers[$j].IdConfident) { $confident = $false }
                if ($buyers[$i].StableId -eq $buyers[$j].StableId) { $distinct = $false }
            }
        }
        [void](Add-Check $id 'same-text-different-message-identity' ($found -and $confident -and $distinct) ('pairs=' + $groups + ' distinctIds=' + $distinct + ' confident=' + $confident))
    }
    $wantHuman = Get-JProp $scenario 'expectHumanSourceCount'
    if ($null -ne $wantHuman) {
        $n = @($conv.Messages | Where-Object { $_.Source -eq 'human' }).Count
        [void](Add-Check $id 'human-source-recognized' ($n -eq [int]$wantHuman) ('got ' + $n + ' want ' + $wantHuman))
    }
    $wantEvidence = Get-JProp $scenario 'expectFactsEvidence'
    if ($null -ne $wantEvidence) {
        $rows = @(Get-FactEvidenceTable $conv)
        foreach ($w in @($wantEvidence)) {
            if ($null -eq $w) { continue }
            $wf = [string](Get-JProp $w 'field')
            $row = @($rows | Where-Object { [string]$_.Field -eq $wf })
            $gotState = ''
            $gotEv = ''
            if ($row.Count -gt 0) { $gotState = [string]$row[0].State; $gotEv = [string]$row[0].Evidence }
            $wantState = [string](Get-JProp $w 'state')
            $wantEv = [string](Get-JProp $w 'evidence')
            $okEv = $true
            if ($wantState) { $okEv = $okEv -and ($gotState -eq $wantState) }
            if ($wantEv) { $okEv = $okEv -and ($gotEv -eq $wantEv) }
            [void](Add-Check $id ('facts-evidence:' + $wf) $okEv ("got '" + $gotState + "' [" + $gotEv + "] want '" + $wantState + "' [" + $wantEv + ']'))
        }
    }
    if ([bool](Get-JProp $scenario 'expectOwnerEvidenceInContext')) {
        [void](Add-Check $id 'owner-evidence-in-context' ([bool]($context -match 'owner replied directly in this chat')) 'context does not credit the owner reply')
    }
    if ([bool](Get-JProp $scenario 'expectOrderWarningInContext')) {
        [void](Add-Check $id 'order-warning-in-context' ([bool]($context -match 'WARNING: message order could not be verified')) 'context does not surface the unverified order')
    }

    # stage metrics
    [void](Add-Check $id 'model-calls' ([int]$gen.ModelCalls -eq [int]$wantCalls) ('gen=' + $gen.ModelCalls + ' want=' + $wantCalls))
    [void](Add-Check $id 'stub-invocations' ($script:Fake.CallIndex -eq [int]$wantStub) ('stub=' + $script:Fake.CallIndex + ' want=' + $wantStub))
    [void](Add-Check $id 'reply-source' ([string]$gen.Source -eq $wantSource) ("got '" + $gen.Source + "' want '" + $wantSource + "'"))
    [void](Add-Check $id 'context-chars-recorded' ([int]$gen.ContextChars -gt 0 -and [int]$gen.ContextChars -eq $context.Length) ('gen=' + $gen.ContextChars + ' local=' + $context.Length))

    # the block the model actually received must be the block we measured
    if ($calls.Count -gt 0) {
        [void](Add-Check $id 'model-input-is-measured-context' ($calls[0].User -eq $context) 'the user content sent to the model differs from New-ReplyContextBlock')
        if ($calls.Count -gt 1) {
            [void](Add-Check $id 'rewrite-reuses-same-context' ($calls[1].User -eq $context) 'the rewrite call did not reuse the same context')
        }
    }

    # context structure
    $curSection = Get-ContextSection $context '=== CURRENT BUYER MESSAGE ===' '=== FACTS AND THEIR EVIDENCE ==='
    [void](Add-Check $id 'context-current-buyer-message' ($curSection -eq [string]$decision.LatestBuyerText) ("context shows '" + $curSection + "' decision says '" + $decision.LatestBuyerText + "'"))
    $chrono = Test-ContextChronological -Context $context -Messages $conv.Messages
    [void](Add-Check $id 'context-chronological' ([bool]$chrono.Ok) ([string]$chrono.Detail))

    # scenario guidance actually injected (measured at the model boundary)
    $guidanceChars = 0
    $guidanceKey = [string]$decision.GuidanceKey
    $guidanceText = [string](Get-ScenarioGuidance -Path $scenarioPath -Key $guidanceKey)
    $guidanceChars = $guidanceText.Length
    if ($calls.Count -gt 0) {
        $marker = '=== REVIEWED EXAMPLES FOR THIS SITUATION (' + $decision.Scenario + ') ==='
        $injected = [bool]($calls[0].System.Contains($marker))
        [void](Add-Check $id 'guidance-injected' ($injected -and $guidanceChars -gt 0) ('marker=' + $injected + ' guidanceChars=' + $guidanceChars + ' key=' + $guidanceKey))
    } else {
        [void](Add-Check $id 'guidance-available' ($guidanceChars -gt 0) ('key=' + $guidanceKey + ' guidanceChars=' + $guidanceChars))
    }

    # timing (simulated clock, same inputs as the comparison run)
    $timing = Get-Timing -Scenario $scenario -FirstOverride $FirstSeenAt -SentOverride $SentAt
    if ($null -eq $timing.LatencySeconds) {
        [void](Add-Check $id 'timing-unknown-not-zero' ($timing.LatencyText -eq 'UNKNOWN') ("latency reported as '" + $timing.LatencyText + "'"))
    } else {
        [void](Add-Check $id 'timing-positive' ([double]$timing.LatencySeconds -gt 0) ('latency ' + $timing.LatencyText + 's from the simulated first-seen/sent inputs'))
    }

    $systemChars = 0
    $userChars = 0
    if ($calls.Count -gt 0) { $systemChars = [int]$calls[0].SystemChars; $userChars = [int]$calls[0].UserChars }
    else { $systemChars = ([string](Get-ReplySystemPrompt $promptPath)).Length + $guidanceChars; $userChars = $context.Length }

    $scenarioFailures = @($script:Failures | Where-Object { $_.Scenario -eq $id })
    $result = [pscustomobject]@{
        Id             = $id
        Title          = $title
        Category       = $category
        ExpectedAction = $expectedAction
        Scenario       = [string]$decision.Scenario
        Reasons        = @($decision.Reasons)
        Source         = [string]$gen.Source
        ModelCalls     = [int]$gen.ModelCalls
        ExpectedCalls  = [int]$wantCalls
        StubCalls      = [int]$script:Fake.CallIndex
        ExpectedStub   = [int]$wantStub
        Rewrites       = [int]$gen.Rewrites
        ContextChars   = [int]$gen.ContextChars
        SystemChars    = [int]$systemChars
        UserChars      = [int]$userChars
        RequestChars   = [int]($systemChars + $userChars)
        GuidanceChars  = [int]$guidanceChars
        GuidanceKey    = $guidanceKey
        OrderConfident = [bool]$decision.OrderConfident
        OrderReason    = [string]$decision.OrderReason
        AskFields      = @($decision.AskFields)
        Reply          = $reply
        FallbackReason = [string]$gen.FallbackReason
        WallMs         = [int]$sw.ElapsedMilliseconds
        FirstSeenAt    = $timing.FirstSeen
        SentAt         = $timing.Sent
        LatencySeconds = $timing.LatencySeconds
        LatencyText    = $timing.LatencyText
        Failures       = @($scenarioFailures | ForEach-Object { $_.Id })
    }
    [void]$script:Results.Add($result)
    $status = 'PASS'
    if ($scenarioFailures.Count -gt 0) { $status = 'FAIL' }

    if (-not $Quiet) {
        $short = $reply -replace '\s+', ' '
        if ($short.Length -gt 40) { $short = $short.Substring(0, 40) + '...' }
        $line = ' ' + $status.PadRight(4) + ' ' + $id.PadRight(30) + ' ' + ([string]$decision.Scenario).PadRight(18) +
            ' calls=' + ([string]$gen.ModelCalls).PadRight(2) + ' ctx=' + ([string]$gen.ContextChars).PadRight(5) +
            ' order=' + ([string]$decision.OrderConfident).PadRight(5) + ' src=' + ([string]$gen.Source).PadRight(12) + ' ' + $short
        Write-Output $line
    }

    # ---- informational probes (documented in the report) ----
    foreach ($probe in @(Get-JProp $scenario 'extraProbes')) {
        if ($null -eq $probe) { continue }
        $pname = [string](Get-JProp $probe 'name')
        $pNotify = Get-JProp $probe 'notifyChannelAvailable'
        if ($null -eq $pNotify) { $pNotify = $notify }
        $force = [string](Get-JProp $probe 'forceScenario')
        if ($force) {
            $pDec = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $rules -NotifyChannelAvailable:([bool]$pNotify) -ForceScenario $force
        } else {
            $pDec = Get-ReplyDecision -Conversation $conv -Facts $facts -Rules $rules -NotifyChannelAvailable:([bool]$pNotify)
        }
        $pFb = [string](Get-ScenarioFallback -Decision $pDec -Rules $rules)
        $pFbCheck = Test-ReplyCompliance -Text $pFb -Rules $rules
        $pEd = Get-JProp $probe 'expectDecision'
        if ($null -ne $pEd) {
            foreach ($prop in @($pEd.PSObject.Properties)) {
                $got = Get-JProp $pDec $prop.Name
                [void](Add-Check $id ('probe:' + $pname + ':' + $prop.Name) ([string]$got -eq [string]$prop.Value) ("want '" + $prop.Value + "' got '" + $got + "'"))
            }
        }
        if ([bool](Get-JProp $probe 'expectFallbackCompliant')) {
            [void](Add-Check $id ('probe:' + $pname + ':fallback-compliant') ([bool]$pFbCheck.Ok) ('violations=[' + (@($pFbCheck.Violations | ForEach-Object { $_.Code }) -join ',') + ']'))
        }
        $pm = [string](Get-JProp $probe 'expectFallbackMatches')
        if ($pm) {
            [void](Add-Check $id ('probe:' + $pname + ':fallback-matches') ([bool]($pFb -match $pm)) ("fallback '" + $pFb + "' does not match '" + $pm + "'"))
        }
        [void]$script:Notes.Add([pscustomobject]@{ Scenario = $id; Probe = $pname; ScenarioKey = [string]$pDec.Scenario; Fallback = $pFb })
    }
}

# ---------------------------------------------------------------------------------------------
# Coverage of the required scenario list (spec 7.1)
# ---------------------------------------------------------------------------------------------
foreach ($need in $requiredCoverage) {
    [void](Add-Check 'coverage' ('required-scenario:' + $need) ($coverageSeen -contains $need) 'no fixture declares this category')
}

# ---------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------
$failed = $script:Failures.Count
$failedScenarios = @($script:Results | Where-Object { $_.Failures.Count -gt 0 }).Count
$passed = $script:Results.Count - $failedScenarios

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Offline acceptance replay - reply chain')
[void]$md.AppendLine('')
[void]$md.AppendLine('Generated: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ')
[void]$md.AppendLine('Repo: ' + $RepoRoot + '  ')
[void]$md.AppendLine('Scenario dir: ' + $ScenarioDir + '  ')
[void]$md.AppendLine('Model: FAKE stub Invoke-LLM (marker ' + $script:FakeStubMarker + '); scripts/lib/llm.ps1 NOT loaded; no network, no browser.  ')
[void]$md.AppendLine('Clock: SIMULATED (fixture clock object; overridable with -FirstSeenAt/-SentAt). A missing first-seen time is reported as UNKNOWN, never as 0.')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Summary')
[void]$md.AppendLine('')
[void]$md.AppendLine('- scenarios: ' + $script:Results.Count)
[void]$md.AppendLine('- scenario PASS: ' + $passed)
[void]$md.AppendLine('- scenario FAIL: ' + $failedScenarios)
[void]$md.AppendLine('- assertions: ' + $script:Checks + ' (' + $failed + ' failed)')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Per scenario')
[void]$md.AppendLine('')
[void]$md.AppendLine('| id | want action | got action | source | model calls | ctx chars | sys chars | guidance chars | order confident | reply | result |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in $script:Results) {
    $e = $r.Reply -replace '\|', '\\|'
    $res = 'PASS'
    if ($r.Failures.Count -gt 0) { $res = 'FAIL: ' + ($r.Failures -join ', ') }
    [void]$md.AppendLine('| ' + $r.Id + ' | ' + $r.ExpectedAction + ' | ' + $r.Scenario + ' | ' + $r.Source + ' | ' + $r.ModelCalls + ' | ' + $r.ContextChars + ' | ' + $r.SystemChars + ' | ' + $r.GuidanceChars + ' | ' + $r.OrderConfident + ' | ' + $e + ' | ' + $res + ' |')
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Stage metrics (MEASURED)')
[void]$md.AppendLine('')
[void]$md.AppendLine('system chars and ctx chars are measured AT THE MODEL BOUNDARY by the fake Invoke-LLM stub, not estimated.')
[void]$md.AppendLine('')
[void]$md.AppendLine('| id | scenario | model calls (want) | stub calls (want) | rewrites | ctx chars | sys chars | request chars | guidance chars | order confident | order reason | wall ms |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($r in $script:Results) {
    [void]$md.AppendLine('| ' + $r.Id + ' | ' + $r.Scenario + ' | ' + $r.ModelCalls + ' (' + $r.ExpectedCalls + ') | ' + $r.StubCalls + ' (' + $r.ExpectedStub + ') | ' + $r.Rewrites + ' | ' + $r.ContextChars + ' | ' + $r.SystemChars + ' | ' + $r.RequestChars + ' | ' + $r.GuidanceChars + ' | ' + $r.OrderConfident + ' | ' + $r.OrderReason + ' | ' + $r.WallMs + ' |')
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Timing (SIMULATED clock - this is NOT send latency)')
[void]$md.AppendLine('')
[void]$md.AppendLine('| id | first seen (simulated) | sent (simulated) | latency seconds |')
[void]$md.AppendLine('|---|---|---|---|')
foreach ($r in $script:Results) {
    [void]$md.AppendLine('| ' + $r.Id + ' | ' + $r.FirstSeenAt + ' | ' + $r.SentAt + ' | ' + $r.LatencyText + ' |')
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Failures')
[void]$md.AppendLine('')
if ($failed -eq 0) {
    [void]$md.AppendLine('None.')
} else {
    foreach ($fl in $script:Failures) {
        [void]$md.AppendLine('- **' + $fl.Scenario + '** (' + $fl.Id + '): ' + $fl.Detail)
    }
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Informational probes')
[void]$md.AppendLine('')
foreach ($n in $script:Notes) {
    [void]$md.AppendLine('- ' + $n.Scenario + ' / ' + $n.Probe + ': scenario=' + $n.ScenarioKey + ' -> ' + $n.Fallback)
}
[void]$md.AppendLine('')

$reportPath = Join-Path $WorkDir 'acceptance_report.md'
Set-Content -Path $reportPath -Value $md.ToString() -Encoding UTF8

$jsonPath = Join-Path $WorkDir 'acceptance_results.json'
$payload = [pscustomobject]@{
    GeneratedAt   = (Get-Date).ToString('o')
    RepoRoot      = $RepoRoot
    WorkDir       = $WorkDir
    StubMarker    = $script:FakeStubMarker
    Checks        = $script:Checks
    Failures      = $failed
    ScenarioPass  = $passed
    ScenarioTotal = $script:Results.Count
    Results       = @($script:Results)
    FailedChecks  = @($script:Failures)
}
Set-Content -Path $jsonPath -Value ($payload | ConvertTo-Json -Depth 6) -Encoding UTF8

if (-not $Quiet) {
    Write-Output ''
    Write-Output ('assertions : ' + $script:Checks + '  failed: ' + $failed)
    Write-Output ('scenarios  : ' + $script:Results.Count + '  pass: ' + $passed + '  fail: ' + $failedScenarios)
    Write-Output ('report     : ' + $reportPath)
    Write-Output ('results    : ' + $jsonPath)
    Write-Output ''
    Write-Output 'timing (SIMULATED):'
    foreach ($r in $script:Results) {
        Write-Output ('  ' + $r.Id.PadRight(30) + ' firstSeen=' + ([string]$r.FirstSeenAt).PadRight(21) + ' sent=' + ([string]$r.SentAt).PadRight(21) + ' latency=' + $r.LatencyText + 's')
    }
    Write-Output ''
    if ($failed -eq 0) { Write-Output 'RESULT: ALL PASS' } else { Write-Output 'RESULT: FAIL' }
}

if ($failed -gt 0) { exit 1 }
exit 0
