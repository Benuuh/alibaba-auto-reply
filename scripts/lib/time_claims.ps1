# All clocks and current-date statements are checked, including text after a valid program answer.
function Get-OutputTimeClaims {
    param([string]$Text)
    $claims=@();$regex='(?<![\d.+-])(\d{1,2}):(\d{2})\s*([AaPp][Mm])?(?![\w])|(?<![\d.])(\d{1,2})\s*([AaPp][Mm])(?![\w])|\b(\d{4}-\d{2}-\d{2})\b'
    foreach($m in [regex]::Matches($Text,$regex)){
        $b=Get-SentenceBounds $Text $m.Index;$sentence=$Text.Substring($b.Start,$b.End-$b.Start)
        $dateOnly=$m.Groups[6].Success
        if($dateOnly -and $m.Index -gt 0 -and $Text.Substring(0,$m.Index) -match "(?i)it'?s\s+\d{1,2}:\d{2}.*\bon\s*$"){
            $prior=[regex]::Matches($Text.Substring(0,$m.Index),'(?i)it''?s\s+\d{1,2}:\d{2}')
            if($prior.Count){$begin=$prior[$prior.Count-1].Index;$b=Get-SentenceBounds $Text $begin;$sentence=$Text.Substring($b.Start,$b.End-$b.Start)}
        }
        # Explicit appointment-only statements may be validated from input by the caller. A booking word elsewhere never exempts "it's".
        $appointment=(-not $dateOnly -and $sentence -match '(?i)\b(?:appointment|booking|pickup)\s+(?:is|at|for)\b' -and $sentence -notmatch "(?i)it'?s|current|right now|\b(?:the|local)\s+time")
        $hour=0;$minute=0;$mer='';$clock=-1;$valid=$true
        if(-not $dateOnly){if($m.Groups[1].Success){$hour=[int]$m.Groups[1].Value;$minute=[int]$m.Groups[2].Value;$mer=$m.Groups[3].Value}else{$hour=[int]$m.Groups[4].Value;$mer=$m.Groups[5].Value};$valid=($minute -le 59 -and $hour -le 23);if($mer){$valid=$valid -and $hour -ge 1 -and $hour -le 12;$hour=$hour%12;if($mer -ieq 'PM'){$hour+=12}};$clock=60*$hour+$minute}
        $offset=[regex]::Match($sentence,$script:PolicyTimeOffsetPattern)
        $date=[regex]::Match($sentence,'\b\d{4}-\d{2}-\d{2}\b')
        $claims+=[pscustomobject]@{Index=$m.Index;Length=$m.Length;Text=$m.Value;Sentence=$sentence;SentenceStart=$b.Start;SentenceEnd=$b.End;ClockMinutes=$clock;Ambiguous=(-not $mer -and -not $dateOnly -and $hour -le 12);OffsetText=$offset.Groups[1].Value;Date=$date.Value;DateOnly=$dateOnly;Valid=$valid;Appointment=$appointment}
    };return $claims
}
function Test-OutputTimeClaims {
    param([string]$Text,$Expectations=@(),[string]$InputText='')
    $out=@();$resolved=@($Expectations|Where-Object Resolved);$unresolved=@($Expectations|Where-Object {-not $_.Resolved});$seen=@{};$unique=@()
    foreach($e in $resolved){$key=$e.PlaceRaw.ToLowerInvariant();if(-not $key){$key='seller'};if(-not $seen.ContainsKey($key)){$seen[$key]=$true;$unique+=$e}}
    $answered=@{}
    foreach($claim in @(Get-OutputTimeClaims $Text)){
        if($claim.Appointment){
            $inputAppointments=@(Get-OutputTimeClaims $InputText|Where-Object {$_.Appointment -and $_.Valid -and $_.ClockMinutes -eq $claim.ClockMinutes -and $_.Ambiguous -eq $claim.Ambiguous -and $_.Date -eq $claim.Date -and $_.OffsetText -eq $claim.OffsetText})
            if($inputAppointments.Count){continue};$out+=@{Code='FACT_TIME_MISMATCH';Severity='block';Detail='appointment time has no corresponding buyer source'};continue
        }
        $bound=@();$explicit=[regex]::Match($claim.Sentence,'(?i)\b(?:in|at)\s+(?<place>[A-Za-z][A-Za-z /_-]*?)(?=\s*\(|\s+on\b|\s+is\b|[.!?,;]|$)')
        if($explicit.Success){$place=$explicit.Groups['place'].Value.Trim().ToLowerInvariant();foreach($e in $unique){$aliases=@($e.PlaceRaw,$e.Place,$e.Zone);if($e.State -eq 'unspecified'){$aliases+=$e.DisplayPlace};$aliases=@($aliases|Where-Object {$_});if(@($aliases|Where-Object {$_.ToLowerInvariant() -eq $place}).Count){$bound+=$e}}
            if(-not $bound.Count){$out+=@{Code='FACT_TIME_MISMATCH';Severity='block';Detail='explicit unrequested place: '+$place};continue}
        }else{
            foreach($e in $unique){foreach($alias in @($e.PlaceRaw,$e.Place,$e.Zone)|Where-Object {$_}){if($claim.Sentence -match ('(?i)(?<![\w])'+[regex]::Escape($alias)+'(?![\w])')){$bound+=$e;break}}}
            if(-not $bound.Count -and $unique.Count -eq 1){$bound=@($unique[0])}
        }
        if($bound.Count -ne 1){$out+=@{Code='FACT_TIME_MISMATCH';Severity='block';Detail='time claim has no unique place binding'};continue};$e=$bound[0]
        $ok=$claim.Valid
        if(-not $claim.DateOnly){$ok=$ok -and $(if($claim.Ambiguous){($claim.ClockMinutes%720) -eq ($e.ClockMinutes%720)}else{$claim.ClockMinutes -eq $e.ClockMinutes})}
        if($claim.Date){$ok=$ok -and $claim.Date -eq $e.LocalDate}
        if($claim.OffsetText){$offsetMinutes=0;$m=[regex]::Match($claim.OffsetText,'^([+-])(\d{1,2})(?::(\d{2}))?$');if(-not $m.Success){$ok=$false}else{$offsetMinutes=60*[int]$m.Groups[2].Value+[int]$m.Groups[3].Value;if($m.Groups[1].Value -eq '-'){$offsetMinutes=-$offsetMinutes};$ok=$ok -and $offsetMinutes -eq $e.OffsetMinutes}}
        if(-not $ok){$out+=@{Code='FACT_TIME_MISMATCH';Severity='block';Detail=$claim.Sentence}}elseif(-not $claim.DateOnly){$answered[$e.TargetId]=$true}
    }
    foreach($e in $unique){if(-not $answered.ContainsKey($e.TargetId)){$out+=@{Code='FACT_TIME_TARGET_UNANSWERED';Severity='block';Detail=$e.PlaceRaw}}}
    foreach($e in $unresolved){$place=$e.PlaceRaw;if(-not $place){$place=$e.Place};$ok=($null -eq $place -or $place -eq '') -and $Text -match '(?i)\bwhich\s+(?:country|city|time\s*zone)\b[^?]*time\s*zone'
        foreach($m in [regex]::Matches($Text,'(?i)\b(?:which|what)\s+(?:city|country|time\s*zone)\b')){$b=Get-SentenceBounds $Text $m.Index;$start=$b.Start;if($start -gt 1){$prior=Get-SentenceBounds $Text ($start-1);$start=$prior.Start};$scope=$Text.Substring($start,$b.End-$start);$places=@($place,$e.DisplayPlace,$e.Place)|Where-Object {$_};foreach($p in $places){if($scope -match '(?i)current time|local time|time in|time zone' -and $scope -match [regex]::Escape($p)){$ok=$true}}}
        if(-not $ok){$out+=@{Code='FACT_TIME_TARGET_UNCLARIFIED';Severity='block';Detail=$place}}
    };return $out
}
