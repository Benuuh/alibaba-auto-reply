param([string]$TestPath,[string]$Root,[string]$Nonce,[string]$ProofPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$env:AAR_TEST_LAYER='Offline';$env:AAR_TEST_NONCE=$Nonce;$env:AAR_TEST_NAME=Split-Path $TestPath -Leaf;$env:AAR_ATTESTATION_FILE=$ProofPath
$global:AarOfflineRequired=$true
. (Join-Path $repo 'scripts/config.ps1')
. (Join-Path $repo 'scripts/lib/paths.ps1')
[void](Initialize-AarIsolation -Root $Root)
Write-AarChildAttestation
$global:LASTEXITCODE=0
try { & $TestPath; exit $LASTEXITCODE } catch { Write-Error $_; exit 1 }
