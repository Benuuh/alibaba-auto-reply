# dimension_guidance tests — 「买家说没有尺寸」时的引导话术 (spec 更像真人销售_20260926 S4 / §12.2-A9)
# 纯逻辑 + 文档一致性: 不碰页面 / Chrome / LLM。
# 判定强度说明(A9/S4 的退化方案): 测试无法在没有 LLM 的情况下断言"任意一次生成的回复"必然命中引导问法,
#   故断言的是**生产侧的引导话术定义**(Get-DimensionGuidance)与**提示词是否真的带上了这些成品话术**,
#   外加"没尺寸也能报价"的禁止暗示检测(Test-NoDimensionQuoteHint)本身可判真假。
#   这比纯关键词扫描强: 关键词必须与生产函数的返回值逐字一致, 改了一边不改另一边会立刻变红。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo "scripts"
. (Join-Path $scripts "reply_engine.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }
Write-Output "== dimension_guidance tests =="

# --- 1) 话术定义存在 ---
Assert-True "Get-DimensionGuidance-exists" ($null -ne (Get-Command Get-DimensionGuidance -EA SilentlyContinue))
Assert-True "Test-NoDimensionQuoteHint-exists" ($null -ne (Get-Command Test-NoDimensionQuoteHint -EA SilentlyContinue))
$g = Get-DimensionGuidance
$promptPath = Join-Path $scripts "reply_agent_prompt.md"
$prompt = [System.IO.File]::ReadAllText($promptPath)

# --- 2) 主推说法: "我直接联系供应商" (spec §12.2: 这是第一反应, 三种问法降为退一步) ---
Assert-True "primary-mentions-supplier-contact" ($g.primary -match "supplier's contact")
Assert-True "primary-promises-direct-confirm" ($g.primary -match 'confirm the cargo details with them directly')
Assert-True "primary-no-price-number" (-not ($g.primary -match '\$\s?\d|USD\s?\d|\d+\s*(usd|dollars)'))
Assert-True "primary-in-prompt" ($prompt.Contains([string]$g.primary))

# --- 3) 三种退一步问法都必须在, 且逐字出现在提示词里(与生产定义一致) ---
# 注: Where-Object 的输出被 @(...) 包裹时, 单元素会被解包成字符串, 其 .Count 对字符串同样返回 1 但
#     对"恰好 1 个匹配"的情形不可靠, 故此处的存在性判断统一走"外层再包一层 @() 后用 -ge 1"。
Assert-Eq "fallback-count" (@($g.fallbacks).Count) 3
Assert-True "fallback-packing-list" (@(@($g.fallbacks) | Where-Object { $_.text -match 'packing list' }).Count -ge 1)
Assert-True "fallback-rough-size-estimate" (@(@($g.fallbacks) | Where-Object { $_.text -match 'rough size is fine' }).Count -ge 1)
Assert-True "fallback-lwh-cm" (@(@($g.fallbacks) | Where-Object { $_.text -match 'L x W x H in cm' }).Count -ge 1)
foreach ($f in @($g.fallbacks)) {
    Assert-True ("fallback-in-prompt: " + $f.case) ($prompt.Contains([string]$f.text))
}

# --- 4) 提示词必须带"边界"说明: 不得暗示没尺寸也能报价 / 不得声称已联系供应商 ---
Assert-True "prompt-forbids-no-dim-quote" ($prompt -match 'We can quote you without the dimensions')
Assert-True "prompt-forbids-claiming-contacted-supplier" ($prompt -match 'I will have the supplier contact you')
Assert-True "prompt-keeps-2x-rule-reference" ($prompt -match '最多追问 2 次')

# --- 5) "没尺寸也能报价"的暗示检测: 真的能判真假(正例命中 / 反例不命中) ---
$bad1 = "We can quote you without the dimensions."
$bad2 = "No need for the dimensions - just tell us the weight."
$bad3 = "Dimensions are not required for a quote."
$bad4 = "There is no need to measure anything, we can proceed."
$good1 = [string]$g.primary
$good2 = "If it's a carton, just the L x W x H in cm is enough."
$good3 = "I just need the carton sizes to price this accurately."
Assert-Eq "hint-bad1" (Test-NoDimensionQuoteHint $bad1) $true
Assert-Eq "hint-bad2" (Test-NoDimensionQuoteHint $bad2) $true
Assert-Eq "hint-bad3" (Test-NoDimensionQuoteHint $bad3) $true
Assert-Eq "hint-bad4" (Test-NoDimensionQuoteHint $bad4) $true
Assert-Eq "hint-good1" (Test-NoDimensionQuoteHint $good1) $false
Assert-Eq "hint-good2" (Test-NoDimensionQuoteHint $good2) $false
Assert-Eq "hint-good3" (Test-NoDimensionQuoteHint $good3) $false
Assert-Eq "hint-empty" (Test-NoDimensionQuoteHint '') $false

# --- 6) 手册(指南 1)必须与提示词同源: 主推说法逐字一致, 且明确三种退一步 ---
$pb = Join-Path $scripts "reply_playbook.md"
Assert-True "playbook-exists" (Test-Path $pb)
if (Test-Path $pb) {
    $pbtxt = [System.IO.File]::ReadAllText($pb)
    # 手册里用的是长破折号 — 与乘号 × ; 生产字符串用 ASCII '-' 与 'x'。
    # 两侧必须做**同一套**排版归一化后再比对, 否则第 3 句会假红(此处踩过一次: 只归一化了手册一侧)。
    function ConvertTo-PrintNorm([string]$s) { return ([string]$s).Replace([char]0x2014, '-').Replace([char]0x00D7, 'x') }
    $normPb = ConvertTo-PrintNorm $pbtxt
    Assert-True "playbook-has-primary" ($normPb.Contains((ConvertTo-PrintNorm $g.primary)))
    Assert-True "playbook-has-fallback-1" ($normPb.Contains((ConvertTo-PrintNorm @($g.fallbacks)[0].text)))
    Assert-True "playbook-has-fallback-2" ($normPb.Contains((ConvertTo-PrintNorm @($g.fallbacks)[1].text)))
    Assert-True "playbook-has-fallback-3" ($normPb.Contains((ConvertTo-PrintNorm @($g.fallbacks)[2].text)))
    Assert-True "playbook-forbids-claiming-contacted" ($pbtxt -match '我已经联系上你供应商了')
    Assert-True "playbook-no-price-number" (-not ($pbtxt -match '\$\s?\d|USD \d|discount \d'))
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
