# lib\seller_context.ps1 - Trusted seller identity, runtime clock and controlled fact wording.
#
# RESPONSIBILITY (2026-10-05 spec §3): this is the ONLY place that answers three questions:
#   1. What do we (the seller side) truthfully know about our own company and service display name?
#   2. What is the actual current time, from a real clock, in a named time zone?
#   3. What may be said out loud about each, given per-field confirmation state?
#
# HARD RULES ENCODED HERE
#   - A field is usable as an outward FACT only when the owner-confirmed config supplies a
#     non-empty value AND its verified flag is true AND the value contains no unresolved template
#     marker. Empty / unverified / templated values degrade PER FIELD; one field's confirmed state
#     never lends credibility to another field.
#   - Identity is NEVER inferred from the buyer's name, the conversation, an attachment, the
#     project folder or a page store name. Only the owner-confirmed config counts.
#   - The current time is NEVER the message timestamp, a screenshot clock, a page "local time" or a
#     model guess. It is the system UTC clock converted through an explicit, named time zone. An
#     invalid time zone returns an explicit error and no-promise wording; it never silently falls
#     back to the host local zone and never emits a format placeholder.
#   - This file is pure: no browser, no model, no notification, no business-state writes. An
#     injected clock makes every function deterministic for the offline harness.
#
# The seller identity block is deliberately NOT part of the untrusted conversation: reply_gen
# inserts it as a separate section that buyer text cannot overwrite.

# ---------------------------------------------------------------------------------------------
# Template-marker vocabulary (one definition, shared with the policy gate).
# ---------------------------------------------------------------------------------------------
$script:SellerTemplatePatterns = @(
    '(?i)\[\s*(current\s*time|company\s*name|seller\s*company|seller\s*name|assistant\s*name|your\s*name|company|name|time)\s*\]',
    '\{\{[^{}\r\n]{0,80}\}\}',
    '\$\{[^{}\r\n]{0,80}\}',
    '(?i)<\s*(company[_ ]?name|seller[_ ]?name|assistant[_ ]?name|your[_ ]?name|current[_ ]?time|company|name|time)\s*>',
    '(?i)\bTODO\b',
    '(?i)\bTBD\b'
)

# The set of obvious placeholder markers. True means "this value is not a real fact".
function Test-UnresolvedTemplateValue([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    foreach ($p in $script:SellerTemplatePatterns) { if ($Value -match $p) { return $true } }
    return $false
}

function Get-SellerTemplatePatterns { return @($script:SellerTemplatePatterns) }

# ---------------------------------------------------------------------------------------------
# Seller identity
# ---------------------------------------------------------------------------------------------

# Normalize one configured field into Value / Verified / Source. A field can only become usable
# when it is non-empty, free of template markers AND explicitly confirmed by the owner.
function Format-SellerField($RawValue, $RawVerified, [string]$Label) {
    $value = ''
    if ($null -ne $RawValue) { $value = ([string]$RawValue).Trim() }
    $verified = [bool]$RawVerified
    if (-not $value) {
        return [pscustomobject]@{ Value = ''; Verified = $false; Source = ($Label + ': not configured') }
    }
    if (Test-UnresolvedTemplateValue $value) {
        return [pscustomobject]@{ Value = ''; Verified = $false; Source = ($Label + ': unresolved template marker in config value') }
    }
    if (-not $verified) {
        return [pscustomobject]@{ Value = ''; Verified = $false; Source = ($Label + ': not confirmed by the owner') }
    }
    return [pscustomobject]@{ Value = $value; Verified = $true; Source = ($Label + ': owner-confirmed config') }
}

# Pure, side-effect-free reader for the `seller_profile` block of the central config.
# Missing config, missing block, wrong types and unparseable values all degrade honestly.
function Get-SellerProfile {
    [CmdletBinding()]
    param($Config = $null)

    $block = $null
    if ($Config) {
        $p = $Config.PSObject.Properties['seller_profile']
        if ($p) { $block = $p.Value }
    }

    $company = $null
    $companyVerified = $false
    $name = $null
    $nameVerified = $false
    $timezone = 'Asia/Shanghai'
    if ($block) {
        foreach ($pair in @(
            @{ Key = 'company_name_en'; Target = 'company' },
            @{ Key = 'assistant_display_name_en'; Target = 'name' },
            @{ Key = 'company_name_verified'; Target = 'companyVerified' },
            @{ Key = 'assistant_display_name_verified'; Target = 'nameVerified' },
            @{ Key = 'timezone'; Target = 'timezone' }
        )) {
            $prop = $block.PSObject.Properties[$pair.Key]
            if (-not $prop) { continue }
            switch ($pair.Target) {
                'company'         { $company = $prop.Value }
                'name'            { $name = $prop.Value }
                'companyVerified' { $companyVerified = [bool]$prop.Value }
                'nameVerified'    { $nameVerified = [bool]$prop.Value }
                'timezone'        { if (-not [string]::IsNullOrWhiteSpace([string]$prop.Value)) { $timezone = ([string]$prop.Value).Trim() } }
            }
        }
    }

    $companyField = Format-SellerField $company $companyVerified 'company_name_en'
    $nameField = Format-SellerField $name $nameVerified 'assistant_display_name_en'
    $zone = Resolve-SellerTimeZone $timezone

    return [pscustomobject]@{
        Configured              = [bool]$block
        Timezone                = $timezone
        TimezoneValid           = [bool]$zone.Ok
        TimezoneId              = [string]$zone.WindowsId
        TimezonePlace           = [string]$zone.Place
        CompanyName             = $companyField
        AssistantDisplayName    = $nameField
        CompanyValue            = [string]$companyField.Value
        CompanyVerified         = [bool]$companyField.Verified
        CompanySource           = [string]$companyField.Source
        NameValue               = [string]$nameField.Value
        NameVerified            = [bool]$nameField.Verified
        NameSource              = [string]$nameField.Source
    }
}

# ---------------------------------------------------------------------------------------------
# Time zones - explicit IANA <-> Windows mapping. Windows PowerShell 5.1 (.NET Framework) does
# not resolve IANA ids, so the mapping is data, not a guess.
# ---------------------------------------------------------------------------------------------
$script:SellerIanaToWindows = @{
    'Asia/Shanghai'        = 'China Standard Time'
    'Asia/Hong_Kong'       = 'China Standard Time'
    'Asia/Tokyo'           = 'Tokyo Standard Time'
    'Asia/Singapore'       = 'Singapore Standard Time'
    'Asia/Taipei'          = 'Taipei Standard Time'
    'Asia/Seoul'           = 'Korea Standard Time'
    'Asia/Kolkata'         = 'India Standard Time'
    'Asia/Dubai'           = 'Arabian Standard Time'
    'Europe/London'        = 'GMT Standard Time'
    'Europe/Berlin'        = 'W. Europe Standard Time'
    'Europe/Paris'         = 'Romance Standard Time'
    'America/New_York'     = 'Eastern Standard Time'
    'America/Chicago'      = 'Central Standard Time'
    'America/Los_Angeles'  = 'Pacific Standard Time'
    'America/Toronto'      = 'Eastern Standard Time'
    'America/Vancouver'    = 'Pacific Standard Time'
    'America/Sao_Paulo'    = 'E. South America Standard Time'
    'America/Mexico_City'  = 'Central Standard Time (Mexico)'
    'Europe/Moscow'        = 'Russian Standard Time'
    'Asia/Jakarta'         = 'SE Asia Standard Time'
    'Australia/Sydney'     = 'AUS Eastern Standard Time'
    'Australia/Melbourne'  = 'AUS Eastern Standard Time'
    'Australia/Brisbane'   = 'E. Australia Standard Time'
    'Australia/Perth'      = 'W. Australia Standard Time'
    'UTC'                  = 'UTC'
    'Etc/UTC'              = 'UTC'
}

$script:SellerIanaPlaces = @{
    'Asia/Shanghai'        = 'China'
    'Asia/Hong_Kong'       = 'Hong Kong'
    'Asia/Tokyo'           = 'Japan'
    'Asia/Singapore'       = 'Singapore'
    'Asia/Taipei'          = 'Taiwan'
    'Asia/Seoul'           = 'South Korea'
    'Asia/Kolkata'         = 'India'
    'Asia/Dubai'           = 'the UAE'
    'Europe/London'        = 'the UK'
    'Europe/Berlin'        = 'Germany'
    'Europe/Paris'         = 'France'
    'America/New_York'     = 'New York'
    'America/Chicago'      = 'Chicago'
    'America/Los_Angeles'  = 'Los Angeles'
    'America/Toronto'      = 'Toronto'
    'America/Vancouver'    = 'Vancouver'
    'America/Sao_Paulo'    = 'Sao Paulo'
    'America/Mexico_City'  = 'Mexico City'
    'Europe/Moscow'        = 'Moscow'
    'Asia/Jakarta'         = 'Jakarta'
    'Australia/Sydney'     = 'Sydney'
    'Australia/Melbourne'  = 'Melbourne'
    'Australia/Brisbane'   = 'Brisbane'
    'Australia/Perth'      = 'Perth'
    'UTC'                  = 'UTC'
    'Etc/UTC'              = 'UTC'
}

# Buyer-facing place names for explicit "what time is it in <place>" questions.
$script:SellerPlaceToIana = @{
    'china' = 'Asia/Shanghai'; 'beijing' = 'Asia/Shanghai'; 'shanghai' = 'Asia/Shanghai'
    'shenzhen' = 'Asia/Shanghai'; 'guangzhou' = 'Asia/Shanghai'; 'ningbo' = 'Asia/Shanghai'
    'yiwu' = 'Asia/Shanghai'; 'chinese' = 'Asia/Shanghai'
    'japan' = 'Asia/Tokyo'; 'tokyo' = 'Asia/Tokyo'
    'singapore' = 'Asia/Singapore'
    'hong kong' = 'Asia/Hong_Kong'; 'hongkong' = 'Asia/Hong_Kong'
    'taiwan' = 'Asia/Taipei'; 'taipei' = 'Asia/Taipei'
    'korea' = 'Asia/Seoul'; 'south korea' = 'Asia/Seoul'; 'seoul' = 'Asia/Seoul'
    'india' = 'Asia/Kolkata'; 'mumbai' = 'Asia/Kolkata'; 'delhi' = 'Asia/Kolkata'
    'uae' = 'Asia/Dubai'; 'dubai' = 'Asia/Dubai'
    'uk' = 'Europe/London'; 'england' = 'Europe/London'; 'london' = 'Europe/London'
    'britain' = 'Europe/London'; 'great britain' = 'Europe/London'
    'germany' = 'Europe/Berlin'; 'berlin' = 'Europe/Berlin'; 'hamburg' = 'Europe/Berlin'
    'munich' = 'Europe/Berlin'; 'frankfurt' = 'Europe/Berlin'; 'cologne' = 'Europe/Berlin'; 'stuttgart' = 'Europe/Berlin'
    'france' = 'Europe/Paris'; 'paris' = 'Europe/Paris'
    # Cities keep resolving to a single zone. The multi-zone COUNTRIES they belong to deliberately
    # do NOT appear here: see $script:SellerAmbiguousCountries below.
    'new york' = 'America/New_York'; 'chicago' = 'America/Chicago'
    'california' = 'America/Los_Angeles'; 'los angeles' = 'America/Los_Angeles'
    'toronto' = 'America/Toronto'; 'vancouver' = 'America/Vancouver'
    'sao paulo' = 'America/Sao_Paulo'; 'mexico city' = 'America/Mexico_City'
    'moscow' = 'Europe/Moscow'; 'jakarta' = 'Asia/Jakarta'
    'sydney' = 'Australia/Sydney'; 'melbourne' = 'Australia/Melbourne'
    'brisbane' = 'Australia/Brisbane'; 'perth' = 'Australia/Perth'
    'utc' = 'UTC'; 'gmt' = 'UTC'
}

# Countries that span several time zones. Answering one of these with a single city would invent a
# location the buyer never named, so they resolve to an explicit "which city?" clarification
# instead. A named city inside them (New York, Sydney, ...) still converts precisely.
$script:SellerAmbiguousCountries = @{
    'usa' = 'the United States'; 'us' = 'the United States'; 'u.s.' = 'the United States'
    'u.s.a.' = 'the United States'; 'united states' = 'the United States'
    'united states of america' = 'the United States'; 'america' = 'the United States'
    'canada' = 'Canada'
    'australia' = 'Australia'
    'brazil' = 'Brazil'
    'russia' = 'Russia'
    'mexico' = 'Mexico'
    'indonesia' = 'Indonesia'
}

# Resolve a configured time-zone string (IANA preferred, Windows ids also accepted).
function Resolve-SellerTimeZone([string]$Timezone) {
    $tz = ''
    if ($Timezone) { $tz = $Timezone.Trim() }
    if (-not $tz) { $tz = 'Asia/Shanghai' }

    $iana = $tz
    $windows = ''
    if ($script:SellerIanaToWindows.ContainsKey($tz)) {
        $windows = [string]$script:SellerIanaToWindows[$tz]
    } else {
        foreach ($key in $script:SellerIanaToWindows.Keys) {
            if ($key -ieq $tz) { $iana = $key; $windows = [string]$script:SellerIanaToWindows[$key]; break }
        }
    }
    if (-not $windows) {
        # Accept an explicit Windows id only when .NET really resolves it.
        try { $null = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz); $windows = $tz } catch { $windows = '' }
    }
    if (-not $windows) {
        return [pscustomobject]@{ Ok = $false; Ambiguous = $false; Iana = $tz; WindowsId = ''; Place = ''; Info = $null; Error = ("unknown time zone '" + $tz + "'") }
    }
    try { $info = [System.TimeZoneInfo]::FindSystemTimeZoneById($windows) } catch {
        return [pscustomobject]@{ Ok = $false; Ambiguous = $false; Iana = $tz; WindowsId = ''; Place = ''; Info = $null; Error = ("time zone '" + $tz + "' maps to an unavailable system zone") }
    }
    $place = $iana
    if ($script:SellerIanaPlaces.ContainsKey($iana)) { $place = [string]$script:SellerIanaPlaces[$iana] }
    elseif ($script:SellerIanaPlaces.ContainsKey($windows)) { $place = [string]$script:SellerIanaPlaces[$windows] }
    elseif ($windows -match '^[A-Za-z]+/[A-Za-z_]+$') { $place = ($windows -split '/')[-1] -replace '_', ' ' }
    elseif ($windows -eq 'UTC') { $place = 'UTC' }
    return [pscustomobject]@{ Ok = $true; Ambiguous = $false; Iana = $iana; WindowsId = $windows; Place = $place; Info = $info; Error = '' }
}

# Resolve a buyer-named place ("China", "Tokyo", "the UK") to a real zone. IANA ids pass through.
# Three distinct outcomes, because "we do not know", "there is no single answer" and "here it is"
# must not be flattened into one:
#   Ok=$true                -> the place maps to exactly one zone
#   Ambiguous=$true         -> the place is real but spans several zones (a country such as
#                              Australia or the USA): the caller MUST ask which city, never pick one
#   Ok=$false, Ambiguous=$false -> unrecognized place
function Resolve-PlaceTimeZone([string]$Place) {
    if ([string]::IsNullOrWhiteSpace($Place)) {
        return [pscustomobject]@{ Ok = $false; Ambiguous = $false; Iana = $Place; WindowsId = ''; Place = ''; Info = $null; Error = 'no place supplied' }
    }
    $p = $Place.Trim().ToLowerInvariant()
    $p = $p -replace '^(in|at|the)\s+', ''
    $p = $p -replace '[.,;:!?]+$', ''
    $p = $p.Trim()
    if ($script:SellerAmbiguousCountries.ContainsKey($p)) {
        $country = [string]$script:SellerAmbiguousCountries[$p]
        return [pscustomobject]@{ Ok = $false; Ambiguous = $true; Iana = ''; WindowsId = ''; Place = $country; Info = $null; Error = ('several time zones in ' + $country) }
    }
    if ($script:SellerPlaceToIana.ContainsKey($p)) { return (Resolve-SellerTimeZone ([string]$script:SellerPlaceToIana[$p])) }
    # An explicit IANA-looking id is allowed through only if it really resolves.
    $zone = Resolve-SellerTimeZone $Place
    if ($zone.Ok -and $Place -match '/') { return $zone }
    return [pscustomobject]@{ Ok = $false; Ambiguous = $false; Iana = $Place; WindowsId = ''; Place = ''; Info = $null; Error = ("unknown place '" + $Place + "'") }
}

# Program-formatted UTC offset for buyer-facing text: "+8", "-4", "+5:45".
function Format-UtcOffset([TimeSpan]$Offset) {
    $minutes = [int]$Offset.TotalMinutes
    $sign = '+'
    if ($minutes -lt 0) { $sign = '-'; $minutes = -$minutes }
    $hours = [int][Math]::Floor($minutes / 60)
    $mins = $minutes % 60
    if ($mins -eq 0) { return ($sign + [string]$hours) }
    return ($sign + [string]$hours + ':' + $mins.ToString('00'))
}

# ---------------------------------------------------------------------------------------------
# Runtime clock
# ---------------------------------------------------------------------------------------------

# The single clock hook. Production reads the system UTC clock; the offline harness overrides this
# function so every render is deterministic. Nothing else in the reply chain reads a clock directly.
function Get-ReplyClockUtc { return [datetime]::UtcNow }

# Build the runtime facts object handed to policy/generation/gating. Callers pass an explicit
# -NowUtc in tests. The returned object carries an explicit error when the zone is invalid and
# NEVER substitutes the host local zone or a placeholder.
function New-ReplyRuntimeContext {
    [CmdletBinding()]
    param(
        $SellerProfile = $null,
        [datetime]$NowUtc,
        [string]$ClockSource = ''
    )
    if (-not $PSBoundParameters.ContainsKey('NowUtc')) {
        $NowUtc = Get-ReplyClockUtc
        if (-not $ClockSource) { $ClockSource = 'system-utc' }
    }
    if (-not $ClockSource) { $ClockSource = 'injected-utc' }

    $utc = $NowUtc
    if ($utc.Kind -eq [System.DateTimeKind]::Local) { $utc = $utc.ToUniversalTime() }
    elseif ($utc.Kind -eq [System.DateTimeKind]::Unspecified) { $utc = [datetime]::SpecifyKind($utc, [System.DateTimeKind]::Utc) }

    $profile = $SellerProfile
    if (-not $profile) { $profile = Get-SellerProfile -Config $null }

    $valid = $true
    $errorText = ''
    $local = $null
    $offset = ''
    $offsetMinutes = 0
    $windowsId = ''
    $place = ''
    $zone = Resolve-SellerTimeZone ([string]$profile.Timezone)
    if (-not $zone.Ok) {
        $valid = $false
        $errorText = 'invalid-timezone: ' + [string]$zone.Error
        $windowsId = ''
        $place = ''
    } else {
        $windowsId = [string]$zone.WindowsId
        $place = [string]$zone.Place
        try {
            $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $zone.Info)
            $ts = $zone.Info.GetUtcOffset($utc)
            $offset = Format-UtcOffset $ts
            $offsetMinutes = [int]$ts.TotalMinutes
        } catch {
            $valid = $false
            $errorText = 'timezone-conversion-failed: ' + $_.Exception.Message
            $local = $null
        }
    }

    return [pscustomobject]@{
        Valid           = $valid
        Error           = $errorText
        NowUtc          = $utc
        LocalNow        = $local
        Timezone        = [string]$profile.Timezone
        TimezoneId      = $windowsId
        Place           = $place
        Offset          = $offset
        OffsetMinutes   = $offsetMinutes
        ClockSource     = $ClockSource
        CapturedAtUtc   = $utc
        SellerProfile   = $profile
        ActionEvidence  = (New-ActionEvidence -Values $null)
    }
}

# A time snapshot is fresh when it was captured no more than MaxAgeSec ago. Used before sending so
# a pure time answer is re-rendered instead of shipping a stale minute.
function Test-RuntimeContextFresh {
    [CmdletBinding()]
    param($RuntimeContext, [int]$MaxAgeSec = 60, [datetime]$NowUtc)
    if (-not $RuntimeContext -or -not $RuntimeContext.CapturedAtUtc) { return $false }
    if (-not $PSBoundParameters.ContainsKey('NowUtc')) { $NowUtc = Get-ReplyClockUtc }
    $age = ($NowUtc - [datetime]$RuntimeContext.CapturedAtUtc).TotalSeconds
    return ($age -ge 0 -and $age -le $MaxAgeSec)
}

# ---------------------------------------------------------------------------------------------
# Action evidence - what the process has REALLY done, as distinct from what it plans to do.
# ---------------------------------------------------------------------------------------------
function Get-SellerObjectValue($Object, [string]$Name) {
    if (-not $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# All four evidence classes default to "not established". A boolean NeedHumanTodo, a reachable
# notification channel or "we plan to" must never be turned into evidence by this function.
function New-ActionEvidence {
    [CmdletBinding()]
    param($Values = $null)
    $todo = [bool](Get-SellerObjectValue $Values 'TodoPersisted')
    $notify = [bool](Get-SellerObjectValue $Values 'NotificationDelivered')
    $owner = [bool](Get-SellerObjectValue $Values 'OwnerAccepted')
    $deadlineRaw = Get-SellerObjectValue $Values 'Deadline'
    $deadline = ''
    if ($null -ne $deadlineRaw) { $deadline = ([string]$deadlineRaw).Trim() }
    # [2026-10-05 八项补修 F4 §6.1 第 6 条] 每一类事实分别取证、分别透传：
    #   认领（OwnerAccepted）不能授权"已联系"；通知投递（NotificationDelivered）不能授权"已确认"。
    $contacted = [bool](Get-SellerObjectValue $Values 'ContactedRecorded')
    $reply = [bool](Get-SellerObjectValue $Values 'SupplierReplyRecorded')
    $resolved = [bool](Get-SellerObjectValue $Values 'ResolvedRecorded')
    $taskId = [string](Get-SellerObjectValue $Values 'TaskId')
    $taskKind = [string](Get-SellerObjectValue $Values 'TaskKind')
    $taskStatus = [string](Get-SellerObjectValue $Values 'TaskStatus')
    $supplierIdentity = [string](Get-SellerObjectValue $Values 'SupplierIdentity')
    $updatedAt = [string](Get-SellerObjectValue $Values 'UpdatedAt')
    # [2026-10-05 第三轮 spec §4.2] 确切回读契约：匹配结论、存在性、开放性与关键指纹必须完整透传，
    #   否则措辞检查只看到 TodoPersisted=true 就会把任何任务当成供应商计划授权。
    $origin = [string](Get-SellerObjectValue $Values 'EvidenceOrigin')
    $exact = [bool](Get-SellerObjectValue $Values 'ExactTaskMatch')
    $exists = [bool](Get-SellerObjectValue $Values 'TaskExists')
    $isOpen = [bool](Get-SellerObjectValue $Values 'IsOpen')
    $usableContact = [bool](Get-SellerObjectValue $Values 'HasUsableSupplierContact')
    $fingerprint = [string](Get-SellerObjectValue $Values 'KeyEvidenceFingerprint')
    $contactedSource = [string](Get-SellerObjectValue $Values 'ContactedSource')
    $replySource = [string](Get-SellerObjectValue $Values 'SupplierReplySource')
    $legacyUnverified = [bool](Get-SellerObjectValue $Values 'SupplierReplyLegacyUnverified')
    $resolvedLegacy = [string](Get-SellerObjectValue $Values 'ResolutionLegacy')
    $identityMatch = [bool](Get-SellerObjectValue $Values 'IdentityMatch')
    $records = Get-SellerObjectValue $Values 'ActionRecords'
    if ($null -eq $records) { $records = @() }
    $confirmed = Get-SellerObjectValue $Values 'ConfirmedFields'
    if ($null -eq $confirmed) { $confirmed = @() }
    return [pscustomobject]@{
        TodoPersisted         = $todo
        NotificationDelivered = $notify
        OwnerAccepted         = $owner
        Deadline              = $deadline
        HasDeadline           = [bool](-not [string]::IsNullOrWhiteSpace($deadline))
        ContactedRecorded     = $contacted
        SupplierReplyRecorded = $reply
        ResolvedRecorded      = $resolved
        TaskId                = $taskId
        TaskKind              = $taskKind
        TaskStatus            = $taskStatus
        SupplierIdentity      = $supplierIdentity
        UpdatedAt             = $updatedAt
        EvidenceOrigin        = $origin
        ExactTaskMatch        = $exact
        TaskExists            = $exists
        IsOpen                = $isOpen
        HasUsableSupplierContact = $usableContact
        KeyEvidenceFingerprint   = $fingerprint
        ContactedSource       = $contactedSource
        SupplierReplySource   = $replySource
        SupplierReplyLegacyUnverified = $legacyUnverified
        ResolutionLegacy      = $resolvedLegacy
        IdentityMatch         = $identityMatch
        ActionRecords         = @($records)
        ConfirmedFields       = @($confirmed)
    }
}

# ---------------------------------------------------------------------------------------------
# Controlled fact wording
# ---------------------------------------------------------------------------------------------

# Format the local clock for the target zone. The date is added only when the conversion crosses a
# calendar day, which is exactly when a bare clock is ambiguous.
function Format-ReplyTimeText($LocalNow, [string]$Place, [string]$Offset, $UtcNow) {
    if ($null -eq $LocalNow) { return '' }
    $time = $LocalNow.ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
    $placeText = 'China'
    if ($Place) { $placeText = $Place }
    $offsetText = ''
    if ($Offset) { $offsetText = ' (UTC' + $Offset + ')' }
    $crossDay = $false
    if ($UtcNow) { $crossDay = ($LocalNow.Date -ne ([datetime]$UtcNow).Date) }
    if ($crossDay) {
        $date = $LocalNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        return ("It's " + $time + " on " + $date + " in " + $placeText + $offsetText + ".")
    }
    return ("It's " + $time + " in " + $placeText + $offsetText + ".")
}

# Deterministic place clarifications. Both ask exactly ONE question and never fall back to the
# seller zone, which would answer a place the buyer never asked about.
$script:SellerTimePlaceClarify = "Happy to help with the time. Which country or time zone are you in?"
function Get-AmbiguousPlaceClarify([string]$Country) {
    $c = 'that country'
    if ($Country) { $c = $Country }
    return ("Happy to help with the time. Which city or time zone in " + $c + " do you mean?")
}

# Append a full stop only when the sentence does not already end with one, so a company name such
# as "Example Freight Co., Ltd." is never rendered as "Ltd..".
function Complete-Sentence([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = $Text.Trim()
    if ($t -match '[.!?]$') { return $t }
    return ($t + '.')
}

# One fact, one honest sentence. Resolved=$false means "we could not confirm the value", and the
# text then says exactly that without any internal term, excuse loop or follow-up promise.
function Get-ReplyFactAnswer {
    [CmdletBinding()]
    param(
        [string]$Fact,
        $RuntimeContext = $null,
        [string]$Place = '',
        [string]$PlaceKind = 'seller',
        # [2026-10-05 spec §7.2 第 1 条] "明确指定了地点"和"这个地点能可靠解析"是两件事。
        #   PlaceKind='explicit' + PlaceResolved=$false ⇒ 只澄清地点，绝不退回卖家时区。
        [bool]$PlaceResolved = $true,
        [string]$PlaceReason = '',
        # [2026-10-05 第三轮 spec §8.1] 多城市同国家/同钟点时，显示名由调用方点名到具体城市，
        #   避免两个不同点名目标渲染成同一个国家名而互相覆盖。
        [string]$DisplayPlace = ''
    )
    $profile = $null
    if ($RuntimeContext) { $profile = $RuntimeContext.SellerProfile }
    if (-not $profile) { $profile = Get-SellerProfile -Config $null }

    switch ($Fact) {
        'current_time' {
            if ($PlaceKind -eq 'unknown') {
                return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = $script:SellerTimePlaceClarify; Source = 'DIRECT_FACT_PLACE_CLARIFY' }
            }
            if ($PlaceKind -eq 'explicit' -and -not $PlaceResolved) {
                # 已经知道买家点名了哪个地点，却无法可靠转换 ⇒ 只问一个明确的地点/时区问题，
                #   不附带货物资料追问、不输出估算时刻、更不退回卖家时间。
                $asked = [string]$Place
                if ([string]::IsNullOrWhiteSpace($asked)) { return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = $script:SellerTimePlaceClarify; Source = 'DIRECT_FACT_PLACE_CLARIFY' } }
                if ($PlaceReason -eq 'ambiguous-multiple-time-zones') {
                    return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = (Get-AmbiguousPlaceClarify $asked); Source = 'DIRECT_FACT_PLACE_AMBIGUOUS' }
                }
                return [pscustomobject]@{
                    Fact = $Fact; Resolved = $false
                    Text = ("I can't confirm the time in " + $asked + " here. Which country or time zone do you mean?")
                    Source = 'DIRECT_FACT_PLACE_UNKNOWN'
                }
            }
            if (-not $RuntimeContext -or -not $RuntimeContext.Valid) {
                return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = "I can't confirm the current time here."; Source = 'DIRECT_FACT_UNRESOLVED' }
            }
            $zone = $null
            $placeText = [string]$RuntimeContext.Place
            if ($DisplayPlace) { $placeText = [string]$DisplayPlace }
            if ($PlaceKind -eq 'explicit' -and -not [string]::IsNullOrWhiteSpace($Place)) {
                $zone = Resolve-PlaceTimeZone $Place
                if ($zone.Ambiguous) {
                    # A real country with several zones. Picking one city would invent a location
                    # the buyer never named, so ask once instead.
                    return [pscustomobject]@{
                        Fact = $Fact; Resolved = $false
                        Text = (Get-AmbiguousPlaceClarify ([string]$zone.Place))
                        Source = 'DIRECT_FACT_PLACE_AMBIGUOUS'
                    }
                }
                if (-not $zone.Ok) {
                    return [pscustomobject]@{
                        Fact = $Fact; Resolved = $false
                        Text = ("I can't confirm the time in " + $Place + " here. Which country or time zone do you mean?")
                        Source = 'DIRECT_FACT_PLACE_UNKNOWN'
                    }
                }
                if (-not $DisplayPlace) { $placeText = [string]$zone.Place }
            } else {
                $zone = Resolve-SellerTimeZone ([string]$RuntimeContext.Timezone)
            }
            try {
                $local = [System.TimeZoneInfo]::ConvertTimeFromUtc([datetime]$RuntimeContext.NowUtc, $zone.Info)
                $offset = Format-UtcOffset ($zone.Info.GetUtcOffset([datetime]$RuntimeContext.NowUtc))
            } catch {
                return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = "I can't confirm the current time here."; Source = 'DIRECT_FACT_UNRESOLVED' }
            }
            return [pscustomobject]@{
                Fact = $Fact; Resolved = $true
                Text = (Format-ReplyTimeText $local $placeText $offset $RuntimeContext.NowUtc)
                Source = 'DIRECT_FACT'
            }
        }
        'seller_company' {
            if ($profile.CompanyVerified) {
                return [pscustomobject]@{ Fact = $Fact; Resolved = $true; Text = (Complete-Sentence ("We're " + [string]$profile.CompanyValue)); Source = 'DIRECT_FACT' }
            }
            return [pscustomobject]@{ Fact = $Fact; Resolved = $false; Text = "I can help with shipping questions here, but I can't confirm the company name."; Source = 'DIRECT_FACT_UNRESOLVED' }
        }
        'seller_name' {
            if ($profile.NameVerified) {
                if ($profile.CompanyVerified) {
                    return [pscustomobject]@{ Fact = $Fact; Resolved = $true; Text = ("I'm " + [string]$profile.NameValue + ", " + [string]$profile.CompanyValue + "'s virtual shipping assistant."); Source = 'DIRECT_FACT' }
                }
                return [pscustomobject]@{ Fact = $Fact; Resolved = $true; Text = ("I'm " + [string]$profile.NameValue + ", a virtual shipping assistant for this Alibaba account."); Source = 'DIRECT_FACT' }
            }
            return [pscustomobject]@{ Fact = $Fact; Resolved = $true; Text = "I'm the shipping assistant for this Alibaba account."; Source = 'DIRECT_FACT' }
        }
        'assistant_identity' {
            return [pscustomobject]@{ Fact = $Fact; Resolved = $true; Text = "Yes, I'm a virtual shipping assistant."; Source = 'DIRECT_FACT' }
        }
        default {
            return [pscustomobject]@{ Fact = [string]$Fact; Resolved = $false; Text = ''; Source = 'DIRECT_FACT_UNSUPPORTED' }
        }
    }
}

# Render the whole current request (already ordered by the intent matcher) as one combined answer.
# UnresolvedFacts lists the facts whose VALUE could not be confirmed, so the caller can log the
# production configuration gap without telling the buyer any internal term.
function Get-DirectFactReply {
    [CmdletBinding()]
    param(
        [string[]]$RequestedFacts,
        $RuntimeContext = $null,
        [string]$Place = '',
        [string]$PlaceKind = 'seller',
        [bool]$PlaceResolved = $true,
        [string]$PlaceReason = '',
        # [2026-10-05 F6 §7.1 第 4/5 条] 时间问题的**全部目标**。可靠目标逐项渲染，
        #   未解析/多时区目标逐项澄清；多个地点共用同一份 RuntimeContext（同一个 NowUtc）。
        [object[]]$TimeTargets = @()
    )
    $answers = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList
    $parts = New-Object System.Collections.ArrayList
    $fragments = New-Object System.Collections.ArrayList
    $targets = @($TimeTargets)
    # [spec §8.1] 同国家/同显示名的多个**不同点名地点**：改用买家点名的城市渲染，避免只显示国家名时
    #   两个目标互相覆盖（多城市同国家/同钟点必须点名对应城市或明确列出这些目标）。
    $displayOverride = @{}
    if ($targets.Count -gt 1) {
        $byDisplay = @{}
        foreach ($tg in $targets) {
            $z = $null
            if (Get-Command Resolve-PlaceTimeZone -ErrorAction SilentlyContinue) { $z = Resolve-PlaceTimeZone ([string]$tg.Place) }
            $dn = ''
            if ($z -and $z.Ok) { $dn = [string]$z.Place }
            if (-not $dn) { continue }
            $raw = [string]$tg.PlaceRaw
            if (-not $raw) { $raw = [string]$tg.Place }
            if (-not $byDisplay.ContainsKey($dn)) { $byDisplay[$dn] = @{} }
            $byDisplay[$dn][$raw] = $true
        }
        foreach ($dn in @($byDisplay.Keys)) {
            if (@($byDisplay[$dn].Keys).Count -le 1) { continue }
            foreach ($tg in $targets) {
                $z = $null
                if (Get-Command Resolve-PlaceTimeZone -ErrorAction SilentlyContinue) { $z = Resolve-PlaceTimeZone ([string]$tg.Place) }
                if (-not ($z -and $z.Ok)) { continue }
                if ([string]$z.Place -ne $dn) { continue }
                $raw = [string]$tg.PlaceRaw
                if ($raw) { $displayOverride[(Get-TimeExpectationId $tg 0)] = $raw }
            }
        }
    }
    foreach ($f in @($RequestedFacts)) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        if ($f -eq 'current_time' -and $targets.Count -gt 0) {
            # 逐目标渲染：每个目标一条答案；去重相同目标与相同措辞，绝不静默漏答第二个问题。
            $seenTarget = @{}
            $seenText = @{}
            $fragParts = New-Object System.Collections.ArrayList
            $fragTargets = New-Object System.Collections.ArrayList
            $ti = 0
            foreach ($tg in $targets) {
                $ti++
                $tk = ([string]$tg.State + '|' + [string]$tg.Place + '|' + [string]$tg.Reason)
                $tid = ('target-' + [string]$ti + ':' + ((([string]$tg.PlaceRaw) -replace '\s+', '-').ToLowerInvariant()))
                if (-not $seenTarget.ContainsKey($tk)) {
                    $seenTarget[$tk] = $true
                    $dp = ''
                    if($tg.PlaceRaw){$dp=[string]$tg.PlaceRaw}
                    if ($displayOverride.ContainsKey((Get-TimeExpectationId $tg 0))) { $dp = [string]$displayOverride[(Get-TimeExpectationId $tg 0)] }
                    $a = Get-ReplyFactAnswer -Fact 'current_time' -RuntimeContext $RuntimeContext -Place ([string]$tg.Place) -PlaceKind ([string]$tg.Kind) -PlaceResolved ([bool]$tg.Resolved) -PlaceReason ([string]$tg.Reason) -DisplayPlace $dp
                    [void]$answers.Add($a)
                    if (-not $a.Resolved) { if ($unresolved -notcontains [string]$a.Fact) { [void]$unresolved.Add([string]$a.Fact) } }
                    if ($a.Text -and -not $seenText.ContainsKey([string]$a.Text)) {
                        $seenText[[string]$a.Text] = $true
                        [void]$fragParts.Add([string]$a.Text)
                    }
                }
                if (-not $fragTargets.Contains($tid)) { [void]$fragTargets.Add($tid) }
            }
            $ft = (@($fragParts.ToArray()) -join ' ')
            if ($ft) {
                [void]$parts.Add($ft)
                [void]$fragments.Add([pscustomobject]@{ Fact = 'current_time'; TargetIds = @($fragTargets.ToArray()); Text = $ft })
            }
            continue
        }
        $a = Get-ReplyFactAnswer -Fact $f -RuntimeContext $RuntimeContext -Place $Place -PlaceKind $PlaceKind -PlaceResolved $PlaceResolved -PlaceReason $PlaceReason
        [void]$answers.Add($a)
        if (-not $a.Resolved) { [void]$unresolved.Add([string]$a.Fact) }
        if ($a.Text) {
            [void]$parts.Add([string]$a.Text)
            [void]$fragments.Add([pscustomobject]@{ Fact = [string]$f; TargetIds = @(); Text = [string]$a.Text })
        }
    }
    return [pscustomobject]@{
        Text           = (@($parts.ToArray()) -join ' ')
        Answers        = @($answers.ToArray())
        Unresolved     = @($unresolved.ToArray())
        RequestedCount = @($RequestedFacts).Count
        # [spec §2/§8.3] ReplyComposition 的程序事实片段：来源只由程序建立，模型不能自报。
        Fragments      = @($fragments.ToArray())
    }
}
