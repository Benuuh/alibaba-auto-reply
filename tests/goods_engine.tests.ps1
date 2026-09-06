# goods_engine regression tests (fixture snapshots; covers 4 extraction defects fixed 2026-08-25)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\goods_engine.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\goods.ps1")
$fixtures = Join-Path $here "fixtures"

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
function Assert-Contains([string]$name, [string]$actual, [string]$needle) {
    if ($actual -and $actual.IndexOf($needle) -ge 0) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$actual] | want contains: $needle" }
}
function Assert-NotContains([string]$name, [string]$actual, [string]$needle) {
    if ($actual -and $actual.IndexOf($needle) -lt 0) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$actual] | want NOT contains: $needle" }
}

Write-Output "== goods_engine tests =="

# ---- 缺陷 1:尺寸串 "40 × 50 × 50 CM" 不得被当作件数;真实件数来自 "20 boxes" ----
$d1 = Get-GoodsDetails "fixture_qty_dims" $fixtures
Assert-Eq "D1-qty-from-boxes" $d1.qty "20"
Assert-Eq "D1-dims-kept" $d1.dims "40 × 50 × 50 CM"

# ---- 缺陷 3:Box Weight: 11 KG 提取为单件重量(去前缀标签) ----
Assert-Eq "D3-box-weight" $d1.unit_weight "11 KG"

# ---- 缺陷 4:地址在 Shipping: 处截断,以 77477 结尾,不含后续字段 ----
Assert-Contains "D4-addr-zip" $d1.addr "77477"
Assert-NotContains "D4-addr-no-shipping" $d1.addr "Shipping"
Assert-NotContains "D4-addr-no-total-boxes" $d1.addr "Total Boxes"
Assert-NotContains "D4-addr-no-dims" $d1.addr "Box Dimensions"

# ---- 缺陷 2:货名不得是整句废话/含时间戳/含 IMG;只取关键词附近短片段 ----
$n1 = Get-GoodsName "fixture_name" $fixtures
Assert-True "D2-known" $n1.known
Assert-Contains "D2-card" $n1.name "card"
Assert-NotContains "D2-no-ts" $n1.name "@@TS"
Assert-NotContains "D2-no-img" $n1.name "[IMG]"
Assert-NotContains "D2-no-box-weight-line" $n1.name "Box Weight"
Assert-True "D2-short" ($n1.name.Length -le 60)
Assert-NotContains "D2-no-full-repeat" $n1.name "It’s a card holder item It’s a card holder item"

# ---- 缺陷 3 变体:Weight per Box: 5kg / 每箱重(第二行不覆盖,首行优先) ----
$d3 = Get-GoodsDetails "fixture_unitweight" $fixtures
Assert-Eq "D3-weight-per-box" $d3.unit_weight "5kg"

# ---- 缺陷 1 模式 b:box x 50(× 前单词)正常提取 ----
Assert-Eq "D1-box-x-50" $d3.qty "50"

# ---- 运输方案:by sea ----
Assert-Contains "D3-transport" $d3.transport "by sea"

# ---- 缺陷 A1:Total Boxes: 20 ?? 提取件数(箱字段优先;数字后 ?? 不影响);dims 不得回归 ----
$dA1 = Get-GoodsDetails "fixture_muhammad_faiz" $fixtures
Assert-Eq "A1-qty-total-boxes" $dA1.qty "20"
Assert-Eq "A1-dims-not-regressed" $dA1.dims "40 × 50 × 50 CM"
Assert-Eq "A1-unit-weight-kept" $dA1.unit_weight "11 KG"
# 注:夹具4 为 "Shipping: Sea ?? to USA"(无 by sea 词),transport 维持现状即可;真实 by sea 场景由 D3-transport 覆盖

# ---- 缺陷 A2:箱/托盘词优先于数量词(Total quantity 200 units vs Number of cartons: 2 → 2) ----
$dA2 = Get-GoodsDetails "fixture_priority" $fixtures
Assert-Eq "A2-cartons-beats-quantity" $dA2.qty "2"

# ---- 缺陷 B:地址以门牌号+街道结构为起点(12999 Murphy Rd),以 ZIP 结尾,不含后续字段 ----
$dB = Get-GoodsDetails "fixture_muhammad_faiz" $fixtures
Assert-Contains "B-addr-houseno-street" $dB.addr "12999 Murphy Rd"
Assert-Contains "B-addr-city-state" $dB.addr "Stafford"
Assert-True "B-addr-ends-zip" ($dB.addr -match '77477s*$')
Assert-NotContains "B-addr-no-shipping" $dB.addr "Shipping:"
Assert-NotContains "B-addr-no-dims" $dB.addr "Box Dimensions:"
Assert-NotContains "B-addr-no-total-boxes" $dB.addr "Total Boxes:"

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
