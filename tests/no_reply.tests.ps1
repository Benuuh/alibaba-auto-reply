# no_reply regression tests (manual-override whitelist: normalization / matching / fault tolerance)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\no_reply.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\no_reply.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}

Write-Output "== no_reply tests =="

# ---- 自建临时 fixture(测试自建自删,不改 tests\fixtures) ----
$tmp = Join-Path $env:TEMP ("no_reply_tests_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$wl = Join-Path $tmp "manual_override.json"
function Write-List([string]$json) { Set-Content -Path $wl -Value $json -Encoding UTF8 }
try {

    # ---- 1. 归一匹配(与 agent_bridge.js normCustomer 语义一致) ----
    Write-List '["john smith"]'
    Assert-True "n1-case-insensitive" (Test-NoReplyBuyer "John Smith" $wl)
    Assert-True "n1-trim-outer" (Test-NoReplyBuyer "  John Smith  " $wl)
    Assert-Eq "n1-key-parity" (ConvertTo-NoReplyKey "  ABC_Trading  ") "abc trading"
    Write-List '["ABC_Trading"]'
    Assert-True "n1-underscore-name" (Test-NoReplyBuyer "ABC Trading" $wl)
    Assert-True "n1-underscore-entry-vs-name" (Test-NoReplyBuyer "ABC_Trading" $wl)
    Write-List '["maria  gomez"]'
    Assert-True "n1-multi-space-entry" (Test-NoReplyBuyer "Maria Gomez" $wl)
    Assert-True "n1-multi-space-name" (Test-NoReplyBuyer "Maria   Gomez" $wl)
    Write-List '["  John  Smith  "]'
    Assert-True "n1-dirty-entry-normalized" (Test-NoReplyBuyer "John Smith" $wl)
    Assert-Eq "n1-key-underscore" (ConvertTo-NoReplyKey "ABC_Trading") "abc trading"

    # ---- 2. 近似名不误伤(精确匹配,非前缀/子串) ----
    Write-List '["john smith"]'
    Assert-True "n2-exact" (Test-NoReplyBuyer "John Smith" $wl)
    Assert-True "n2-not-suffix" (-not (Test-NoReplyBuyer "John Smiths" $wl))
    Assert-True "n2-not-longer" (-not (Test-NoReplyBuyer "John Smithson" $wl))
    Assert-True "n2-not-prefix" (-not (Test-NoReplyBuyer "Smith" $wl))
    Assert-True "n2-not-reordered" (-not (Test-NoReplyBuyer "Smith John" $wl))
    Assert-True "n2-not-adjacent" (-not (Test-NoReplyBuyer "JohnSmith" $wl))
    Assert-True "n2-empty" (-not (Test-NoReplyBuyer "" $wl))
    Assert-True "n2-blank" (-not (Test-NoReplyBuyer "   " $wl))
    Assert-True "n2-null" (-not (Test-NoReplyBuyer $null $wl))
    Write-List '["abc"]'
    Assert-True "n2-not-prefix-abc" (-not (Test-NoReplyBuyer "abcd" $wl))

    # ---- 3. 容错:空数组/缺失/损坏 → 全 False 不抛 ----
    Write-List '[]'
    Assert-True "f1-empty-array" (-not (Test-NoReplyBuyer "John Smith" $wl))
    Remove-Item $wl -Force -ErrorAction SilentlyContinue
    Assert-True "f2-missing-file" (-not (Test-NoReplyBuyer "John Smith" $wl))
    Write-List '{broken json'
    Assert-True "f3-corrupt-json" (-not (Test-NoReplyBuyer "John Smith" $wl))
    Write-List '"just a string"'
    Assert-True "f4-not-array" (-not (Test-NoReplyBuyer "John Smith" $wl))

    # ---- 4. -Path 显式注入 + 缓存 mtime 刷新 ----
    Write-List '["jane doe"]'
    Assert-True "p1-inject-hit" (Test-NoReplyBuyer "Jane Doe" $wl)
    Assert-True "p1-inject-hit2" (Test-NoReplyBuyer "JANE DOE" $wl)
    Write-List '["bob lee"]'
    Assert-True "p2-cache-refresh-hit" (Test-NoReplyBuyer "Bob Lee" $wl)
    Assert-True "p2-cache-refresh-stale-gone" (-not (Test-NoReplyBuyer "Jane Doe" $wl))
    Write-List '["jane doe", "JANE DOE", "jane  doe"]'
    $cnt = @(Get-NoReplyList -Path $wl).Count
    Assert-Eq "p3-dup-entries-deduped" $cnt 1
    Assert-True "p3-dup-still-matches" (Test-NoReplyBuyer "Jane  Doe" $wl)

} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
