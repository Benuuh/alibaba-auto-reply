# no_reply_write regression tests — 人工接管白名单的**写侧**（增/删/查 + 文件格式 + 容错）
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\no_reply_write.tests.ps1
# 覆盖目标：
#   ① 归一化与读侧同源（复用 ConvertTo-NoReplyKey，不另写一份）
#   ② 写出的文件与 tools\control-agent\agent_bridge.js 的 saveWhitelist **逐字节一致**
#      （JSON.stringify(list,null,2)+'\n' ⇒ LF + 2 空格缩进 + 结尾换行 + 无 BOM）
#   ③ 幂等（重复添加 = ALREADY；重复删除 = NOT_FOUND）
#   ④ 容错（文件缺失/损坏 → 按空名单，且"添加"能自愈重建）
#   ⑤ 反事实（空名/纯空白/只有下划线 → BAD_NAME 且不改文件；50 条不失真；中文名可往返）
# 全部使用自建临时 fixture，不触碰部署根的 data\manual_override.json
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

Write-Output "== no_reply_write tests =="

$tmp = Join-Path $env:TEMP ("no_reply_write_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$wl = Join-Path $tmp "manual_override.json"

try {
    # ---- 1. 添加 + 归一化（脏输入：大小写/下划线/多空格/首尾空白） ----
    Assert-Eq "a1-add-dirty"        (Add-NoReplyBuyer "  John_Smith  " $wl) "ADDED:john smith"
    Assert-True "a1-matches-reader" (Test-NoReplyBuyer "JOHN SMITH" $wl)
    Assert-Eq "a1-idempotent"       (Add-NoReplyBuyer "john smith" $wl) "ALREADY"
    Assert-Eq "a1-idempotent-dirty" (Add-NoReplyBuyer "JOHN   SMITH" $wl) "ALREADY"
    Assert-Eq "a1-count"            (@(Get-NoReplyList -Path $wl).Count) 1

    # ---- 2. 文件格式：与 Node 的 JSON.stringify(list,null,2)+'\n' 逐字节一致 ----
    [void](Add-NoReplyBuyer "Maria_Gomez" $wl)
    $raw = Get-Content $wl -Raw -Encoding UTF8
    $bytes = [System.IO.File]::ReadAllBytes($wl)
    Assert-True "f1-no-bom"      (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
    Assert-True "f2-lf-only"     (-not $raw.Contains("`r"))
    Assert-True "f3-ends-newline" ($raw.EndsWith("`n"))
    Assert-True "f4-two-space"   ($raw -match "(?m)^  `"")
    Assert-True "f5-array"       ((($raw | ConvertFrom-Json)) -is [System.Array])
    # 逐字节与 Node 输出比对（node 不可用时跳过，但必须显式记账而不是静默通过）
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $exp = Join-Path $tmp "expected.json"
        & node -e "require('fs').writeFileSync(process.argv[1], JSON.stringify(['john smith','maria gomez'], null, 2) + '\n', 'utf8');" $exp | Out-Null
        $b1 = [System.IO.File]::ReadAllBytes($wl); $b2 = [System.IO.File]::ReadAllBytes($exp)
        Assert-True "f6-byte-identical-to-node" (($b1.Length -eq $b2.Length) -and (-not (Compare-Object $b1 $b2)))
    } else {
        Write-Output "  NOTE: node 不可用 ⇒ f6（逐字节比对）未取证"
    }

    # ---- 3. 列表汇总 ----
    Assert-Eq "l1-summary" (Get-NoReplySummary -Path $wl) "当前人工接管白名单(2): john smith、maria gomez"

    # ---- 4. 删除 ----
    Assert-Eq "d1-remove"       (Remove-NoReplyBuyer "JOHN SMITH" $wl) "REMOVED:john smith"
    Assert-True "d1-gone"       (-not (Test-NoReplyBuyer "John Smith" $wl))
    Assert-True "d1-other-kept" (Test-NoReplyBuyer "Maria Gomez" $wl)
    Assert-Eq "d2-remove-again" (Remove-NoReplyBuyer "john smith" $wl) "NOT_FOUND"
    [void](Remove-NoReplyBuyer "maria gomez" $wl)
    Assert-Eq "d3-empty-file"   ((Get-Content $wl -Raw -Encoding UTF8).Trim()) "[]"
    Assert-Eq "d3-empty-summary" (Get-NoReplySummary -Path $wl) "白名单为空，所有客户均自动回复"

    # ---- 5. 容错：缺失 / 损坏 / 非数组 ⇒ 读为空名单，且"添加"能自愈 ----
    Remove-Item $wl -Force -ErrorAction SilentlyContinue
    Assert-True "t1-missing-empty" (@(Get-NoReplyList -Path $wl).Count -eq 0)
    Assert-Eq "t1-add-on-missing" (Add-NoReplyBuyer "Jane Doe" $wl) "ADDED:jane doe"
    Set-Content -Path $wl -Value '{broken' -Encoding UTF8 -NoNewline
    Assert-True "t2-corrupt-empty" (@(Get-NoReplyList -Path $wl).Count -eq 0)
    Assert-Eq "t2-add-on-corrupt" (Add-NoReplyBuyer "Jane Doe" $wl) "ADDED:jane doe"
    Assert-True "t2-recovered" ((Get-Content $wl -Raw -Encoding UTF8 | ConvertFrom-Json) -contains 'jane doe')
    Set-Content -Path $wl -Value '"just a string"' -Encoding UTF8
    Assert-True "t3-not-array-empty" (@(Get-NoReplyList -Path $wl).Count -eq 0)

    # ---- 6. 反事实：非法名字不得改文件 ----
    Set-Content -Path $wl -Value '["keep me"]' -Encoding UTF8
    $before = Get-Content $wl -Raw -Encoding UTF8
    Assert-Eq "x1-empty"     (Add-NoReplyBuyer "" $wl) "BAD_NAME"
    Assert-Eq "x2-blank"     (Add-NoReplyBuyer "   " $wl) "BAD_NAME"
    Assert-Eq "x3-underscore-only" (Add-NoReplyBuyer "_" $wl) "BAD_NAME"
    Assert-Eq "x4-remove-empty"    (Remove-NoReplyBuyer "" $wl) "BAD_NAME"
    Assert-Eq "x5-file-unchanged"  (Get-Content $wl -Raw -Encoding UTF8) $before

    # ---- 7. 反事实：大名单不失真（50 条） ----
    $big = @(); 1..50 | ForEach-Object { $big += ("buyer " + $_) }
    [void](Save-NoReplyList -Path $wl -List $big)
    $back = @(Get-NoReplyList -Path $wl)
    Assert-Eq "b1-count-50" $back.Count 50
    Assert-True "b2-first" ($back[0] -eq 'buyer 1')
    Assert-True "b3-last"  ($back[49] -eq 'buyer 50')

    # ---- 8. 反事实：中文/特殊字符往返（非 ASCII 不得被编码破坏） ----
    Set-Content -Path $wl -Value '[]' -Encoding UTF8
    Assert-Eq "u1-chinese-add" (Add-NoReplyBuyer "张 三" $wl) "ADDED:张 三"
    Assert-True "u2-chinese-match" (Test-NoReplyBuyer "张 三" $wl)
    Assert-Eq "u3-chinese-summary" (Get-NoReplySummary -Path $wl) "当前人工接管白名单(1): 张 三"
    Assert-True "u4-chinese-file-readable" ((Get-Content $wl -Raw -Encoding UTF8).Contains("张 三"))

} finally {
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
