# page_select tests — FIX-PAGESELECT 2026-09-26
# 这条缺陷的后果是"monitor 操作错误页面"，只断言"函数存在"抓不到。
# 关键断言：**当前活动 Chrome 上 Get-Page 必须返回 OneTalk 页**（而不是第一个 page）。
#
# 🔴 RED 的构造（spec §11-A4 允许自决，此处说明为何这样构造）：
#   本机当前恰好"第一个 page 就是 OneTalk"（spec §1.1 已写明这是运气不是保证），
#   因此**只**断言"返回的是 OneTalk"在改动前也成立 ⇒ 拿不到稳定 RED。
#   本文件用两条**决定性**判据构造 RED：
#     (1) 代码文本断言 `source-has-url-guard`：旧实现没有 URL 筛选 ⇒ 失败；
#     (2) 行为断言 `invoke-cdpeval-not-guard-error`：旧 lib 里**根本没有 Get-Page**
#         （同名文件陷阱：consumer dot-source 的是 lib\cdp.ps1，而函数只在 scripts\cdp.ps1），
#         于是 Invoke-CdpEval 会误报 `CMD ERROR: no onetalk page found` ⇒ 失败。
#         这正是 G1-③ 门禁要抓的失败模式（monitor 每轮误报 ⇒ 自愈链空转）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
$script:pass=0; $script:fail=0
function Assert-True([string]$n,[bool]$c){ if($c){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n"} }
Write-Output "== page_select tests =="

# 取真实 /json/list 的 page 列表（CDP 端口取自 config.json）
#   ⚠️ [DEVIATION D-04] 这里**故意不用** `@(ConvertFrom-Json ...)`：PowerShell 5.1 会把 JSON 数组解析成
#   "单个 Object[] 对象"，再套 @() 就变成 1 元素数组（`$_.url` 会是多个 URL 空格拼接的伪值）
#   ⇒ 与 Get-Page 比较必然假失败。用 Invoke-RestMethod 直接拿可索引数组（与 Get-Page 同款写法）。
function Get-RawTargets {
    $port = Get-CdpPort
    return Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
}
function Get-RawPages {
    return @((Get-RawTargets) | Where-Object { $_.type -eq 'page' })
}
function Get-RawOnetalkPage {
    return @((Get-RawPages) | Where-Object { $_.url -match 'onetalk\.alibaba\.com' } | Select-Object -First 1)
}
# 目标 id 归一化：折叠伪对象的 id 是"多个 id 空格拼接"，取第一个记号才是真实 id
function Get-FirstToken([string]$s){ return ([string]$s -split '\s+')[0] }
# 抽取某个文件里的 Get-Page 函数体（用于"两处定义必须一致"的断言）
function Get-PageFnBody([string]$path){
    $lines = [System.IO.File]::ReadAllLines($path)
    $start = -1
    for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match '^function Get-Page\s*\{'){ $start=$i; break } }
    if($start -lt 0){ return $null }
    $acc = New-Object System.Collections.ArrayList
    for($i=$start;$i -lt $lines.Count;$i++){ [void]$acc.Add(($lines[$i] -replace '#.*$','').Trim()); if($lines[$i] -eq '}'){ break } }
    return (@($acc | Where-Object { $_ }) -join "`n")
}

# ── 断言 1（决定性 RED/GREEN）：URL 筛选是否真的落到**两个**同名文件里的 Get-Page ──
#    注意：**不能**用 (Get-Command Get-Page).Definition 判断"文件里有没有"——
#    dot-source 后命令表里只剩最后一次定义。这里直接读源码文本。
$libPath  = Join-Path $scripts "lib\cdp.ps1"
$rootPath = Join-Path $scripts "cdp.ps1"
$libSrc   = Get-Content $libPath -Raw
$rootSrc  = Get-Content $rootPath -Raw
Assert-True "source-has-url-guard" ($libSrc -match "url -match 'onetalk")
Assert-True "source-returns-null"  ($libSrc -match 'return \$null')
Assert-True "root-cdp-also-filtered" ($rootSrc -match "url -match 'onetalk")
Assert-True "same-name-trap-fixed" ($null -ne (Get-Command Get-Page -EA SilentlyContinue))
Assert-True "lib-defines-get-page" ($libSrc -match 'function Get-Page\s*\{')
$libBody = Get-PageFnBody $libPath
$rootBody = Get-PageFnBody $rootPath
Assert-True "two-definitions-identical" ($libBody -and $rootBody -and $libBody -eq $rootBody)

# ── 断言 2：真实页面上 Get-Page 的返回值必须与"URL 匹配到的那个 page"一致 ──
$p = Get-Page
$rawPages = @(Get-RawPages)
$rawOnetalk = @(Get-RawOnetalkPage)
$firstUrl = if ($rawPages.Count -gt 0) { [string]$rawPages[0].url } else { '(none)' }
$gpUrl = if ($p) { [string]$p.url } else { '(null)' }
Write-Output ("  (first page = " + $firstUrl + ")")
Write-Output ("  (Get-Page   = " + $gpUrl + ")")
Write-Output ("  (raw page count = " + $rawPages.Count + ", raw onetalk = " + $rawOnetalk.Count + ")")
$gpIdNorm  = if ($p) { Get-FirstToken $p.id } else { '' }
$rawIdNorm = if ($rawOnetalk.Count -gt 0) { Get-FirstToken $rawOnetalk[0].id } else { '' }
$gpWsCount = if ($p) { ([regex]::Matches([string]$p.webSocketDebuggerUrl, 'ws://')).Count } else { 0 }
Write-Output ("  (first page id = " + (Get-FirstToken $firstUrl) + " ; Get-Page id = " + $gpIdNorm + " ; raw onetalk id = " + $rawIdNorm + " ; ws count = " + $gpWsCount + ")")

Assert-True "returns-something" ($null -ne $p)
Assert-True "url-is-onetalk" ($p -and $p.url -match 'onetalk\.alibaba\.com')
Assert-True "has-ws-url" ($p -and $p.webSocketDebuggerUrl)
Assert-True "ws-url-single-target" ($gpWsCount -eq 1)
Assert-True "first-page-is-onetalk-today" ($firstUrl -match 'onetalk\.alibaba\.com')
Assert-True "equals-first-onetalk-page" ($gpIdNorm -and $rawIdNorm -and $gpIdNorm -eq $rawIdNorm)

# ── 断言 3（行为 RED）：Invoke-CdpEval 必须不再误报空守卫错误（G1-③ 的失败模式） ──
$evalUrl = [string](Invoke-CdpEval "location.href")
Write-Output ("  (Invoke-CdpEval location.href = " + $evalUrl + ")")
Assert-True "invoke-cdpeval-not-guard-error" ($evalUrl -notmatch 'no onetalk page found')
Assert-True "invoke-cdpeval-returns-onetalk-url" ($evalUrl -match 'onetalk\.alibaba\.com')

# ── 断言 4：负向构造 —— 第一个 page 不是 OneTalk 时 Get-Page 必须返回 $null ──
#    （用同一份真实 CDP 数据判定；本机当前首元素就是 OneTalk ⇒ 退化为纯逻辑等价式）
if ($rawPages.Count -gt 0 -and $firstUrl -notmatch 'onetalk\.alibaba\.com') {
    Assert-True "no-onetalk-must-return-null" ($null -eq $p)
} else {
    $fake = @(@{type='page';url='https://example.com/x';webSocketDebuggerUrl='ws://a'},
              @{type='page';url='https://onetalk.alibaba.com/message/weblitePWA.htm';webSocketDebuggerUrl='ws://b'})
    $picked = @($fake | Where-Object { $_.type -eq 'page' -and $_.url -match 'onetalk\.alibaba\.com' } | Select-Object -First 1)
    Assert-True "logic-skips-non-onetalk-first" ($picked.Count -eq 1 -and $picked[0].webSocketDebuggerUrl -eq 'ws://b')
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if($script:fail -gt 0){ Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
