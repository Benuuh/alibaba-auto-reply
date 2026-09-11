# vision/attachment tests: pure functions + sidecar + goods merge (no network, no real send)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\vision.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\vision.ps1")
. (Join-Path $scripts "lib\doc.ps1")
. (Join-Path $scripts "lib\goods.ps1")
. (Join-Path $scripts "reply_engine.ps1")

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

Write-Output "== vision tests =="

# ---- 1. ConvertTo-DataUrl ----
$durl = ConvertTo-DataUrl ([byte[]]@(0x89, 0x50, 0x4E, 0x47)) 'image/png'
Assert-True "dataurl-prefix" ($durl -eq 'data:image/png;base64,iVBORw==')
Assert-True "dataurl-empty-null" ($null -eq (ConvertTo-DataUrl ([byte[]]@()) 'image/png'))

# ---- 2. 标记剥离 + hash 稳定(VB7) ----
$plain = 'hi there, 47kg 60x40x30cm'
$withMarkers = 'hi there, 47kg 60x40x30cm @@IMG:https://img.alicdn.com/a.jpg|https://img.alicdn.com/b.jpg @@FILE:quote%20sheet.pdf|https://x/y.pdf'
Assert-Eq "markers-stripped" (Remove-AttachmentMarkers $withMarkers) $plain
Assert-Eq "hash-stable-img" (Get-StableHash (Remove-AttachmentMarkers $withMarkers)) (Get-StableHash $plain)
Assert-Eq "hash-stable-plain" (Get-StableHash (Remove-AttachmentMarkers $plain)) (Get-StableHash $plain)

# ---- 3. New-VisionContentParts: text 首位 + ≤3 图 ----
$p0 = New-VisionContentParts @() 'hello'
Assert-Eq "parts-text-only" (@($p0).Count) 1
Assert-Eq "parts-first-type" (@($p0)[0].type) 'text'
$urls = @('data:image/png;base64,AAA', 'data:image/png;base64,BBB', 'data:image/png;base64,CCC', 'data:image/png;base64,DDD', 'data:image/png;base64,EEE')
$p1 = @(New-VisionContentParts $urls 'look at these')
Assert-Eq "parts-total-capped" $p1.Count 4
Assert-Eq "parts-first-text" $p1[0].type 'text'
Assert-Eq "parts-img-type" $p1[1].type 'image_url'
Assert-Eq "parts-img-url" $p1[3].image_url.url 'data:image/png;base64,CCC'
$p2 = @(New-VisionContentParts @($null, 'data:image/png;base64,AAA', '') 'x')
Assert-Eq "parts-skip-empty" $p2.Count 2

# ---- 4. Get-VisionExtract: 合法/围栏/空值/非法/超长 ----
$e1 = Get-VisionExtract '{"weight_kg":"47","dims":"60x40x30cm","cartons":"","tracking":"TRK123456","note":"visible on label"}'
Assert-Eq "extract-weight" $e1['weight_kg'] '47'
Assert-Eq "extract-dims" $e1['dims'] '60x40x30cm'
Assert-Eq "extract-tracking" $e1['tracking'] 'TRK123456'
Assert-True "extract-empty-dropped" (-not $e1.ContainsKey('cartons'))
$e2 = Get-VisionExtract ('```json' + "`n" + '{"weight_kg":"10"}' + "`n" + '```')
Assert-Eq "extract-fenced" $e2['weight_kg'] '10'
Assert-True "extract-no-json-null" ($null -eq (Get-VisionExtract 'no json here'))
Assert-True "extract-empty-null" ($null -eq (Get-VisionExtract ''))
Assert-True "extract-all-empty-null" ($null -eq (Get-VisionExtract '{"weight_kg":"","dims":""}'))
$long = 'x' * 500
$e3 = Get-VisionExtract ('{"note":"' + $long + '"}')
Assert-Eq "extract-long-capped" $e3['note'].Length 120
Assert-True "extract-whitelist-only" ($null -eq (Get-VisionExtract '{"evil":"value"}'))

# ---- 5. sidecar 读写(临时目录) ----
$tmp = Join-Path $env:TEMP ("vision_tests_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    $saved = Save-VisionExtract 'Test Buyer' @{ weight_kg = '47'; dims = '60x40x30cm' } 'image' 'shot1.png' $tmp
    Assert-True "sidecar-saved" ([bool]$saved)
    Assert-True "sidecar-file-exists" (Test-Path $saved)
    $side = Get-VisionSidecar 'Test Buyer' $tmp
    Assert-Eq "sidecar-weight" $side.weight_kg '47'
    Assert-Eq "sidecar-source" $side.source 'image'
    Assert-Eq "sidecar-file" $side.file 'shot1.png'
    # 二次合并: 新字段追加, 旧字段保留, source 覆盖
    Save-VisionExtract 'test buyer' @{ tracking = 'TRK1' } 'document' 'doc.pdf' $tmp | Out-Null
    $side2 = Get-VisionSidecar 'Test Buyer' $tmp
    Assert-Eq "sidecar-merge-keep" $side2.weight_kg '47'
    Assert-Eq "sidecar-merge-add" $side2.tracking 'TRK1'
    Assert-Eq "sidecar-source-updated" $side2.source 'document'
    Assert-True "sidecar-missing-null" ($null -eq (Get-VisionSidecar 'Nobody Here' $tmp))
    Assert-True "sidecar-no-fields-null" ($null -eq (Save-VisionExtract 'Test Buyer' @{} 'image' 'x.png' $tmp))

    # ---- 6. goods 合并(B6) ----
    $snapDir = Join-Path $tmp "snaps"
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    # 无 sidecar 的买家: 快照只有文本, 无重量/尺寸
    @("# BUYER: Plain Buyer", "[BUYER] hello, any update? @@TS:1") -join "`n" | Set-Content -Path (Join-Path $snapDir "msgs_20260912_000001.txt") -Encoding UTF8
    $st0 = Get-GoodsDataStatus 'Plain Buyer' $snapDir
    Assert-True "goods-no-sidecar-weight" (-not $st0.weight)
    Assert-True "goods-no-sidecar-dims" (-not $st0.dims)
    # 有 sidecar 的买家: 快照无重量/尺寸, sidecar 提供
    @("# BUYER: Vision Buyer", "[BUYER] please check the photo @@TS:1") -join "`n" | Set-Content -Path (Join-Path $snapDir "msgs_20260912_000002.txt") -Encoding UTF8
    Save-VisionExtract 'Vision Buyer' @{ weight_kg = '47'; dims = '60x40x30cm'; cartons = '2' } 'image' 'shot.png' $snapDir | Out-Null
    $st1 = Get-GoodsDataStatus 'Vision Buyer' $snapDir
    Assert-True "goods-sidecar-weight" ([bool]$st1.weight)
    Assert-True "goods-sidecar-dims" ([bool]$st1.dims)
    $det1 = Get-GoodsDetails 'Vision Buyer' $snapDir
    Assert-Eq "goods-details-weight" $det1.weight '47'
    Assert-Eq "goods-details-dims" $det1.dims '60x40x30cm'
    Assert-Eq "goods-details-qty" $det1.qty '2'
    # 无快照但有 sidecar → 状态/详情仍可用
    Save-VisionExtract 'No Snap Buyer' @{ weight_kg = '9kg' } 'image' 'x.png' $snapDir | Out-Null
    $st2 = Get-GoodsDataStatus 'No Snap Buyer' $snapDir
    Assert-True "goods-nosnap-sidecar" ([bool]$st2.weight)
    $det2 = Get-GoodsDetails 'No Snap Buyer' $snapDir
    Assert-Eq "goods-nosnap-details" $det2.weight '9kg'

    # ---- 7. 文件名净化 ----
    Assert-Eq "safe-name" (Get-SafeDocName '..\evil/pa:th*file.pdf') 'pa_th_file.pdf'
    Assert-True "safe-name-long" ((Get-SafeDocName (('a' * 200) + '.pdf')).Length -le 80)
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output ("  RESULT: pass=$script:pass fail=$script:fail")
if ($script:fail -gt 0) { Write-Output ("  FAILED: " + ($script:fails -join ", ")); exit 1 }
Write-Output "  ALL PASS"
exit 0
