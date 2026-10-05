param([string]$Phase = 'before')
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'scripts/config.ps1')
. (Join-Path $repo 'scripts/lib/paths.ps1')
$root = Join-Path $env:TEMP ('aar-closure-probes-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $root)
$env:AAR_TEST_LAYER = 'Offline'
$src = Join-Path $repo 'docs/verification/architecture_opt_20261005/review_fixes/third_independent_review_20261005'
$dest = Join-Path $repo 'docs/verification/architecture_opt_20261005/review_fixes/closure_fix'
foreach ($name in @('original_probes','contact_entry_probe','request_probes','task_probes','pause_probes','time_probes')) {
    $savedPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
    $output = @(powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $src ($name + '.ps1')) 2>&1)
    $code = $LASTEXITCODE;$ErrorActionPreference=$savedPreference
    [IO.File]::WriteAllText((Join-Path $dest ($Phase + '_' + $name + '.txt')), (($output -join "`r`n") + "`r`nCHILD_EXIT=" + $code), (New-Object Text.UTF8Encoding($true)))
    Write-Output ($name + ' exit=' + $code)
}
