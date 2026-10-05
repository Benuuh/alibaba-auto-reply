# Explicit, process-sticky test context; clearing environment cannot enable real egress.
if($env:AAR_TEST_LAYER -and $env:AAR_TEST_LAYER -notin @('Live','All')){$global:AarOfflineRequired=$true}
function Test-AarOfflineRequired {
    if($global:AarOfflineRequired){return $true}
    if($env:AAR_TEST_LAYER -and $env:AAR_TEST_LAYER -notin @('Live','All')){$global:AarOfflineRequired=$true;return $true}
    try {if(Test-SkillRuntimeIsolated){$global:AarOfflineRequired=$true;return $true}}catch{return $true}
    return $false
}
function Assert-AarSendAllowed([string]$Operation='real egress') {
    if(Test-AarOfflineRequired){throw ('ISOLATION-VIOLATION: offline context refuses '+$Operation)}
}
function Get-AarAttestationDoc {
    $doc=[pscustomobject]@{PID=$PID;Nonce=$env:AAR_TEST_NONCE;Test=$env:AAR_TEST_NAME;Contexts=@();Switches=@()}
    if($env:AAR_ATTESTATION_FILE -and (Test-Path $env:AAR_ATTESTATION_FILE)){
        try{$old=Get-Content -LiteralPath $env:AAR_ATTESTATION_FILE -Raw|ConvertFrom-Json;if($old.PID -eq $PID -and $old.Nonce -eq $env:AAR_TEST_NONCE){$doc.Contexts=@($old.Contexts);if($old.PSObject.Properties.Name -contains 'Switches'){$doc.Switches=@($old.Switches)}}}catch{}
    }
    return $doc
}
function Save-AarAttestationDoc($Doc) {
    if(-not $env:AAR_ATTESTATION_FILE){return}
    [IO.File]::WriteAllText($env:AAR_ATTESTATION_FILE,($Doc|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))
}
# [独立复核 R10] 运行根切换进入可核验上下文：切换当下登记（未核验=待定），
#   由同一进程里为该根写出合法标记（New-AarIsolationRoot）来解除；未登记/未解除/无标记的切换在父进程核验时失败。
function Write-AarRuntimeRootSwitch([string]$From,[string]$To,[bool]$Declared,[string]$Reason) {
    if(-not $env:AAR_ATTESTATION_FILE){return}
    $fromText='';$toText=''
    try{$fromText=(Normalize-AarPath $From)}catch{$fromText=[string]$From}
    try{$toText=(Normalize-AarPath $To)}catch{$toText=[string]$To}
    if(-not $toText -or $fromText -eq $toText){return}
    $doc=Get-AarAttestationDoc
    $doc.Switches=@($doc.Switches)+[pscustomobject]@{From=$fromText;To=$toText;AtUtc=[datetime]::UtcNow.ToString('o');Declared=[bool]$Declared;Reason=[string]$Reason;Status='pending'}
    Save-AarAttestationDoc $doc
}
function Resolve-AarRuntimeRootSwitch([string]$Root) {
    if(-not $env:AAR_ATTESTATION_FILE){return}
    $text='';try{$text=(Normalize-AarPath $Root)}catch{$text=[string]$Root}
    if(-not $text){return}
    $doc=Get-AarAttestationDoc
    if(-not @($doc.Switches).Count){return}
    $changed=$false
    foreach($s in @($doc.Switches)){if(-not $s){continue};if([string]$s.To -eq $text -and [string]$s.Status -ne 'verified'){$s|Add-Member -NotePropertyName Status -NotePropertyValue 'verified' -Force;$s|Add-Member -NotePropertyName MarkerVerifiedAtUtc -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force;$changed=$true}}
    if($changed){Save-AarAttestationDoc $doc}
}
function Write-AarChildAttestation {
    if(-not $env:AAR_ATTESTATION_FILE){return}
    $context=[pscustomobject]@{PID=$PID;Nonce=$env:AAR_TEST_NONCE;Test=$env:AAR_TEST_NAME;RuntimeRoot=(Normalize-AarPath (Get-AarRuntimeRoot));Marker=(Get-AarIsolationMarkerPath);MarkerSHA256='';AtUtc=[datetime]::UtcNow.ToString('o')}
    if(Test-Path $context.Marker){$context.MarkerSHA256=(Get-FileHash -LiteralPath $context.Marker -Algorithm SHA256).Hash;$context|Add-Member MarkerBytes ([Convert]::ToBase64String([IO.File]::ReadAllBytes($context.Marker)))}
    $doc=Get-AarAttestationDoc
    $doc.Contexts=@($doc.Contexts)+$context
    Save-AarAttestationDoc $doc
}
function Test-AarChildAttestation {
    param($Proof,[int]$ExpectedPID,[string]$Nonce,[string]$TestName)
    $r=[pscustomobject]@{Ok=$false;Reason='identity-or-context-missing';VerifiedContexts=@()}
    if(-not $Proof -or $Proof.PID -ne $ExpectedPID -or $Proof.Nonce -ne $Nonce -or $Proof.Test -ne $TestName -or -not @($Proof.Contexts).Count){return $r}
    foreach($context in @($Proof.Contexts)){
        if($context.PID -ne $ExpectedPID -or $context.Nonce -ne $Nonce -or $context.Test -ne $TestName -or -not $context.RuntimeRoot -or -not $context.Marker -or -not $context.MarkerSHA256){return $r}
        $marker=$context.Marker
        if((Normalize-AarPath $marker) -ne (Normalize-AarPath (Join-Path $context.RuntimeRoot '.aar-isolation.json')) -or -not $context.MarkerBytes){return $r}
        $bytes=[Convert]::FromBase64String($context.MarkerBytes);$actual=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff)|ConvertFrom-Json
        if($actual.childPID -ne $ExpectedPID -or $actual.nonce -ne $Nonce -or $actual.test -ne $TestName -or -not $actual.isolated){return $r}
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','')}finally{$sha.Dispose()}
        if($hash -ne $context.MarkerSHA256){$r.Reason='marker-snapshot-changed';return $r}
        foreach($prod in @(Get-AarProductionPaths)){if(Test-AarPathUnder $context.RuntimeRoot $prod){$r.Reason='root-under-production';return $r}}
        $r.VerifiedContexts+= $context
    }
    # [独立复核 R10] 运行根切换必须已登记且由合法标记解除；显式声明的隔离探针记录原因后放行。
    if($Proof.PSObject.Properties.Name -contains 'Switches'){
        foreach($switch in @($Proof.Switches)){
            if(-not $switch){continue}
            if([string]$switch.To -eq [string]$switch.From){continue}
            if([bool]$switch.Declared){continue}
            if([string]$switch.Status -ne 'verified'){$r.Reason='unverified-runtime-root-switch: '+[string]$switch.To;return $r}
        }
    }
    $r.Ok=$true;$r.Reason='child-identity-marker-and-runtime-root-verified';return $r
}
