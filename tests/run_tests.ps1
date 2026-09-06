# Test runner: executes all tests under tests\ and reports summary (non-zero exit on failure)
# Usage: powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$totalPass = 0
$totalFail = 0
$failFiles = New-Object System.Collections.ArrayList

foreach ($t in @(Get-ChildItem -Path $here -Filter "*.tests.ps1" | Sort-Object Name)) {
    Write-Output "=== $($t.Name) ==="
    $out = powershell -ExecutionPolicy Bypass -NoProfile -File $t.FullName 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Write-Output "  $_" }
    if ($exit -ne 0) { [void]$failFiles.Add($t.Name) }
}

Write-Output ""
Write-Output ("TEST-SUMMARY: files={0} failedFiles={1}" -f @(Get-ChildItem -Path $here -Filter "*.tests.ps1").Count, $failFiles.Count)
if ($failFiles.Count -gt 0) {
    Write-Output ("FAILED: " + ($failFiles -join ", "))
    exit 1
}
Write-Output "ALL TEST FILES PASS"
