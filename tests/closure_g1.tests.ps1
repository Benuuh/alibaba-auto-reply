$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/config.ps1')
. (Join-Path $repo 'scripts/lib/paths.ps1')
$root=Join-Path $env:TEMP ('aar-closure-g1-'+[guid]::NewGuid().ToString('N'));[void](Initialize-AarIsolation $root)
$script:pass=0;$script:fail=0
function Assert($ok,$msg='assertion failed'){if(-not $ok){throw $msg}}
function Case($id,[scriptblock]$body){try{& $body;$script:pass++;Write-Output "PASS $id"}catch{$script:fail++;Write-Output "FAIL $id $($_.Exception.Message)"}}
Case G01 { $proof=[pscustomobject]@{PID=999999;Nonce='fake';Test='fake';Contexts=@()};$r=Test-AarChildAttestation -Proof $proof -ExpectedPID $PID -Nonce actual -TestName fixture;Assert (-not $r.Ok);$proof.PID=$PID;$proof.Nonce='actual';$proof.Test='fixture';Assert (-not(Test-AarChildAttestation -Proof $proof -ExpectedPID $PID -Nonce actual -TestName fixture).Ok) 'parent marker without child context is not proof' }
Case G02 {
    . (Join-Path $repo 'scripts/lib/cdp.ps1');. (Join-Path $repo 'scripts/lib/llm.ps1');. (Join-Path $repo 'scripts/lib/wecom.ps1')
    # No actual network requests: count at the transport and deliberately throw if ever reached.
    $script:transport=0;function Invoke-RestMethod {$script:transport++;throw 'TRANSPORT-REACHED'};function Invoke-WebRequest {$script:transport++;throw 'TRANSPORT-REACHED'}
    Remove-Item -LiteralPath (Get-AarIsolationMarkerPath) -Force
    $saved=$env:AAR_TEST_LAYER;Remove-Item Env:AAR_TEST_LAYER -ErrorAction SilentlyContinue;Remove-Item Env:AAR_RUNTIME_ROOT -ErrorAction SilentlyContinue
    foreach($action in @({Invoke-CdpEval '1'},{Invoke-LLM @() 0 1 ''},{Send-WecomMessage fixture},{Assert-AarSendAllowed actual-send})){ $blocked=$false;try{& $action}catch{$blocked=$_.Exception.Message -match 'ISOLATION'};Assert $blocked 'missing marker / cleared env cannot enable live egress' }
    Assert ($script:transport -eq 0);$env:AAR_TEST_LAYER=$saved
    [void](Initialize-AarIsolation $root)
}
Case G03 { $change=[pscustomobject]@{Path='C:\fictional-prod\data\x.json';Kind='file';Change='modified';Before='before';After='after'};foreach($writer in @($true,$false)){$r=Get-AarProductionPathAudit -Changes @($change) -WriterInfo ([pscustomobject]@{Running=$writer}) -WriterOutputRoots @('C:\fictional-prod\data') -AttributionProven -AttributionEvidence '';Assert ($r.Result -eq 'UNRESOLVED') 'boolean or process absence cannot attribute test writing'} }
Case G01-root-tamper {
    $saveProof=$env:AAR_ATTESTATION_FILE;$saveNonce=$env:AAR_TEST_NONCE;$saveName=$env:AAR_TEST_NAME
    try {$env:AAR_ATTESTATION_FILE=Join-Path $root 'root-proof.json';$env:AAR_TEST_NONCE=[guid]::NewGuid().ToString('N');$env:AAR_TEST_NAME='root-change-fixture';[void](Initialize-AarIsolation $root);Write-AarChildAttestation
        $proof=Get-Content $env:AAR_ATTESTATION_FILE -Raw|ConvertFrom-Json;Assert (Test-AarChildAttestation $proof $PID $env:AAR_TEST_NONCE $env:AAR_TEST_NAME).Ok
        $proof.Contexts[0].RuntimeRoot=Join-Path $root 'unverified-root';Assert (-not(Test-AarChildAttestation $proof $PID $env:AAR_TEST_NONCE $env:AAR_TEST_NAME).Ok) 'root cannot change without corresponding marker'
    }finally{$env:AAR_ATTESTATION_FILE=$saveProof;$env:AAR_TEST_NONCE=$saveNonce;$env:AAR_TEST_NAME=$saveName;[void](Initialize-AarIsolation $root)}
}
Case G02-config-marker-root {
    . (Join-Path $repo 'scripts/lib/cdp.ps1');. (Join-Path $repo 'scripts/lib/llm.ps1');. (Join-Path $repo 'scripts/lib/wecom.ps1')
    $script:transport=0;function Invoke-RestMethod {$script:transport++;throw 'TRANSPORT-REACHED'};function Invoke-WebRequest {$script:transport++;throw 'TRANSPORT-REACHED'}
    $lookup=(Get-Command Test-SkillRuntimeIsolated).ScriptBlock
    try {function Test-SkillRuntimeIsolated {throw 'injected config failure'}
        foreach($mutation in @('bad-marker','root-switch','config-failure')){
            if($mutation -eq 'bad-marker'){[IO.File]::WriteAllText((Get-AarIsolationMarkerPath),'{broken')}
            if($mutation -eq 'root-switch'){$env:AAR_RUNTIME_ROOT=Join-Path $root 'without-marker'}
            foreach($action in @({Invoke-CdpEval '1'},{Invoke-LLM @() 0 1 ''},{Send-WecomMessage fixture},{Assert-AarSendAllowed actual-send})){$blocked=$false;try{& $action}catch{$blocked=$_.Exception.Message -match 'ISOLATION'};Assert $blocked ($mutation+':'+$action.ToString())}
        };Assert ($script:transport -eq 0)
    }finally{Set-Item Function:Test-SkillRuntimeIsolated $lookup;[void](Initialize-AarIsolation $root)}
}
Case G03-child-exit3 {
    $test=Join-Path $root 'exit3-fixture.ps1';[IO.File]::WriteAllText($test,"Write-Output 'LogicTests=PASS ProductionPathAudit=UNRESOLVED Overall=BLOCKED-UNRESOLVED'; exit 3",(New-Object Text.UTF8Encoding($true)))
    $nonce=[guid]::NewGuid().ToString('N');$proofPath=Join-Path $root 'exit3-proof.json';$childRoot=Join-Path $root 'exit3-child'
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName='powershell.exe';$psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'run_child.ps1')+'" -TestPath "'+$test+'" -Root "'+$childRoot+'" -Nonce '+$nonce+' -ProofPath "'+$proofPath+'"';$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$p.WaitForExit();Assert ($p.ExitCode -eq 3) $stderr.Result
    $proof=Get-Content $proofPath -Raw|ConvertFrom-Json;Assert (Test-AarChildAttestation $proof $p.Id $nonce 'exit3-fixture.ps1').Ok
    Write-Output ('EXIT-PROPAGATION pid='+$p.Id+' exit='+$p.ExitCode+' verified=True '+$stdout.Result.Trim());$p.Dispose()
    $change=[pscustomobject]@{Path='C:\fictional-prod\x';Before='a';After='b'};$ev=[pscustomobject]@{Path=$change.Path;Before='a';After='b';PID=98765;SourceRef='isolated provenance fixture';ObservedAtUtc='2026-10-05T04:00:00Z';Source='test-child'}
    Assert ((Get-AarProductionPathAudit -Changes @($change) -AttributionEvidence @($ev)).Result -eq 'FAIL') 'proven test writing is fatal'
    $ev.Source='production-writer';Assert ((Get-AarProductionPathAudit -Changes @($change) -AttributionEvidence @($ev)).Result -eq 'PASS') 'path-specific independent production proof positive'
}
Write-Output "RESULT closure_g1 pass=$script:pass fail=$script:fail root=$root"
if($script:fail){exit 1}
