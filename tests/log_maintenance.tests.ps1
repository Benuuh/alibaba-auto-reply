# log_maintenance regression tests: log rotation + snapshot retention (zero-dependency, ASCII-safe output).
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\log_maintenance.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
. (Join-Path $root "scripts\log_rotate.ps1")
. (Join-Path $root "scripts\retention.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}

function New-FileSize([string]$path, [long]$bytes) {
    $fs = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $fs.SetLength($bytes) } finally { $fs.Dispose() }
}

function New-TestDir {
    $d = Join-Path $env:TEMP ("log_maint_" + [guid]::NewGuid().ToString('N').Substring(0,12))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $d 'archive') -Force | Out-Null
    return $d
}

Write-Output "== log_maintenance tests =="

# ---------- log rotation ----------
$d = New-TestDir
New-FileSize (Join-Path $d 'monitor.log') 3145728   # 3 MB > 1 MB limit
New-FileSize (Join-Path $d 'watchdog.log') 102400   # 0.1 MB under limit
New-FileSize (Join-Path $d 'health.log') 102400     # 0.1 MB under limit
$a1 = Join-Path $d 'archive\monitor_20260101_000000.log'
$a2 = Join-Path $d 'archive\monitor_20260102_000000.log'
Set-Content -LiteralPath $a1 -Value 'old-1' -Encoding UTF8
Set-Content -LiteralPath $a2 -Value 'old-2' -Encoding UTF8
(Get-Item -LiteralPath $a1).LastWriteTime = [datetime]'2026-01-01 00:00:00'
(Get-Item -LiteralPath $a2).LastWriteTime = [datetime]'2026-01-02 00:00:00'

$r1 = Invoke-LogRotation -LogDir $d -Name monitor -MaxMb 1 -KeepFiles 2
Assert-True "rotate-over-limit-moved" ($r1 -match 'action=moved')
Assert-True "rotate-source-gone" (-not (Test-Path -LiteralPath (Join-Path $d 'monitor.log')))
$arch = @(Get-ChildItem -LiteralPath (Join-Path $d 'archive') -Filter 'monitor_*.log' -File)
Assert-True "rotate-archive-cap" ($arch.Count -eq 2)
Assert-True "rotate-deleted-oldest" (-not (Test-Path -LiteralPath $a1))
Assert-True "rotate-kept-newest" (Test-Path -LiteralPath $a2)
Assert-True "rotate-summary-deleted" ($r1 -match 'deleted=1')

$r2 = Invoke-LogRotation -LogDir $d -Name watchdog -MaxMb 1 -KeepFiles 2
Assert-True "rotate-under-limit-noop" ($r2 -match 'action=none')
Assert-True "rotate-under-limit-file-kept" (Test-Path -LiteralPath (Join-Path $d 'watchdog.log'))

$r3 = Invoke-LogRotation -LogDir $d -Name nosuch -MaxMb 1 -KeepFiles 2
Assert-True "rotate-missing-noop" ($r3 -match 'action=none')

# DryRun: over-limit file must NOT be moved, archive count unchanged
New-FileSize (Join-Path $d 'monitor.log') 3145728
$archBefore = @(Get-ChildItem -LiteralPath (Join-Path $d 'archive') -Filter 'monitor_*.log' -File).Count
$r4 = Invoke-LogRotation -LogDir $d -Name monitor -MaxMb 1 -KeepFiles 2 -DryRun
Assert-True "rotate-dryrun-flag" ($r4 -match 'action=dryrun')
Assert-True "rotate-dryrun-file-kept" (Test-Path -LiteralPath (Join-Path $d 'monitor.log'))
$archAfter = @(Get-ChildItem -LiteralPath (Join-Path $d 'archive') -Filter 'monitor_*.log' -File).Count
Assert-True "rotate-dryrun-archive-untouched" ($archAfter -eq $archBefore)

Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue

# ---------- snapshot retention ----------
$d2 = Join-Path $env:TEMP ("ret_maint_" + [guid]::NewGuid().ToString('N').Substring(0,12))
New-Item -ItemType Directory -Path $d2 -Force | Out-Null
$old1 = Join-Path $d2 'msgs_20260101_000000.txt'   # expired (mtime ~100d ago)
$old2 = Join-Path $d2 'msgs_20260215_000000.txt'   # expired (mtime ~50d ago)
$new1 = Join-Path $d2 'msgs_20990101_000000.txt'   # not expired
$m1 = (Get-Date).AddDays(-100).ToString('yyyyMM')
$m2 = (Get-Date).AddDays(-50).ToString('yyyyMM')
Set-Content -LiteralPath $old1 -Value 'snap-jan' -Encoding UTF8
Set-Content -LiteralPath $old2 -Value 'snap-feb' -Encoding UTF8
Set-Content -LiteralPath $new1 -Value 'snap-new' -Encoding UTF8
(Get-Item -LiteralPath $old1).LastWriteTime = (Get-Date).AddDays(-100)
(Get-Item -LiteralPath $old2).LastWriteTime = (Get-Date).AddDays(-50)
New-Item -ItemType Directory -Path (Join-Path $d2 'buyers') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $d2 'buyers\b1.json') -Value '{}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $d2 'manual_override.json') -Value '{}' -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $d2 'vision_extract') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $d2 'vision_extract\v1.txt') -Value 'keep' -Encoding UTF8

$r5 = @(Invoke-SnapshotRetention -DataDir $d2 -Days 30 -DryRun) -join ' | '
Assert-True "retention-dryrun-flag" ($r5 -match 'dryrun=true')
Assert-True "retention-dryrun-count" ($r5 -match 'archived=2')
Assert-True "retention-dryrun-keeps-files" ((Test-Path -LiteralPath $old1) -and (Test-Path -LiteralPath $old2))
Assert-True "retention-dryrun-no-archive-dir" (-not (Test-Path -LiteralPath (Join-Path $d2 'archive')))

$r6 = Invoke-SnapshotRetention -DataDir $d2 -Days 30
Assert-True "retention-archived-two" ($r6 -match 'archived=2')
Assert-True "retention-expired-gone" ((-not (Test-Path -LiteralPath $old1)) -and (-not (Test-Path -LiteralPath $old2)))
Assert-True "retention-not-expired-kept" (Test-Path -LiteralPath $new1)
Assert-True "retention-monthly-zips" ((Test-Path -LiteralPath (Join-Path $d2 ('archive\msgs_' + $m1 + '.zip'))) -and (Test-Path -LiteralPath (Join-Path $d2 ('archive\msgs_' + $m2 + '.zip'))))
Assert-True "retention-untouched-dirs" ((Test-Path -LiteralPath (Join-Path $d2 'buyers\b1.json')) -and (Test-Path -LiteralPath (Join-Path $d2 'manual_override.json')) -and (Test-Path -LiteralPath (Join-Path $d2 'vision_extract\v1.txt')))
$r7 = Invoke-SnapshotRetention -DataDir $d2 -Days 30
Assert-True "retention-second-run-noop" ($r7 -match 'archived=0')

Remove-Item -LiteralPath $d2 -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
