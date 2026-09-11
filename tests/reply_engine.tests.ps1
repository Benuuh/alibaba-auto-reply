# reply_engine regression tests (zero-dependency assertions, ASCII only)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_engine.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$engine = Join-Path (Split-Path $here -Parent) "scripts\reply_engine.ps1"
. $engine

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-Contains([string]$name, [string]$actual, [string]$needle) {
    if ($actual -and $actual.IndexOf($needle) -ge 0) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: $actual | want contains: $needle" }
}
function Assert-NotContains([string]$name, [string]$actual, [string]$needle) {
    if ($actual -and $actual.IndexOf($needle) -lt 0) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: $actual | want NOT contains: $needle" }
}
function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: $a | want: $b" }
}

$testRules = [pscustomobject]@{
    brand = [pscustomobject]@{ sales_contact = "Test Sales"; company_name = "Test Co" }
    pricing = $null
    data_to_collect = @(
        "Goods total weight (kg)",
        "Packaging dimensions L*W*H",
        "Reference images of the goods",
        "Recipient's detailed address"
    )
    reply_rules = $null
    templates = [pscustomobject]@{
        first_inquiry    = "Hi {name}, please provide weight, dimensions, images and address."
        follow_up_details = "Please have the supplier contact us."
        billing_rule     = "Billing is based on max of gross and volumetric weight."
        process_overview = "Process: supplier -> our warehouse -> invoice -> ship."
        ask_address      = "Could you provide the recipient's detailed address?"
        our_contact      = "Contact us: test@example.com"
    }
}

Write-Output "== reply_engine tests =="

# 1. buyer accuses not reading
$r = Generate-Reply $testRules "buyer1" "you don't read my messages" @()
Assert-Contains "A0-cantread" $r "Sorry"
# 2. negative / refuse
$r = Generate-Reply $testRules "buyer1" "no thanks" @()
Assert-Contains "A1-refuse" $r "No problem"
# 3. thanks (no inquiry words)
$r = Generate-Reply $testRules "buyer1" "thanks" @()
Assert-Contains "A-thanks" $r "You're welcome"
# 4. thanks WITH inquiry words -> must not be generic thanks
$r = Generate-Reply $testRules "buyer1" "thanks, how much is shipping to USA?" @()
Assert-NotContains "A-thanks-inquiry" $r "You're welcome"
# 5. short confirm
$r = Generate-Reply $testRules "buyer1" "ok" @()
Assert-Contains "A-confirm-ok" $r "finalize"
# 6. confirm carrying cargo info -> NOT plain confirm
$r = Generate-Reply $testRules "buyer1" "yes it is 20 kg" @()
Assert-NotContains "A-confirm-cargo" $r "That works"
# 7. asks if AI
$r = Generate-Reply $testRules "buyer1" "are you a robot?" @()
Assert-Contains "A-ai" $r "assistant"
# 8. pure greeting
$r = Generate-Reply $testRules "buyer1" "hi" @()
Assert-Contains "A-greeting" $r "ship"
# 9. will get back later
$r = Generate-Reply $testRules "buyer1" "i'll get back to you tomorrow" @()
Assert-Contains "A-later" $r "Take your time"
# 10. contact info request
$r = Generate-Reply $testRules "buyer1" "whatsapp number?" @()
Assert-Contains "A-contact" $r "test@example.com"
# 11. process question
$r = Generate-Reply $testRules "buyer1" "how does your process work" @()
Assert-Contains "A-process" $r "Process"
# 12. billing question
$r = Generate-Reply $testRules "buyer1" "how do you calculate the charge?" @()
Assert-Contains "A-billing" $r "Billing"
# 13. transit time
$r = Generate-Reply $testRules "buyer1" "how long to deliver?" @()
Assert-Contains "A-transit" $r "5-10 days"
# 14. battery -> SDS/UN38.3
$r = Generate-Reply $testRules "buyer1" "i want to ship lithium batteries" @()
Assert-Contains "A-battery" $r "SDS"
# 15. battery with SDS already provided -> no repeated SDS ask
$r = Generate-Reply $testRules "buyer1" "i want to ship lithium batteries" @("[ME] Please share the SDS and UN38.3 report.","[BUYER] here is my SDS document and UN38.3 test report")
Assert-NotContains "A-battery-sds-given" $r "SDS and UN38.3"
# 16. price haggling
$r = Generate-Reply $testRules "buyer1" "too expensive, better price?" @()
Assert-Contains "A-haggle" $r "volumetric"
# 17. comparison (avoid haggle words like cheaper/price)
$r = Generate-Reply $testRules "buyer1" "another agent offers better service" @()
Assert-Contains "A-compare" $r "door-to-door"
# 18. no supplier
$r = Generate-Reply $testRules "buyer1" "i don't have a supplier yet" @()
Assert-Contains "A-nosupplier" $r "No problem"
# 19. goods info provided, missing address only
$r = Generate-Reply $testRules "buyer1" "the weight is 20kg and dims 10x10x10 cm" @()
Assert-Contains "A-missing-addr" $r "address"
# 20. all info provided (incl. photo) -> confirm quote
$r = Generate-Reply $testRules "buyer1" "20 kg, 10x10x10 cm, calle 123 madrid, photo attached" @("[BUYER] 20 kg, 10x10x10 cm, calle 123 madrid, photo attached")
Assert-Contains "A-allinfo" $r "finalize"
# 21. ask limit reached -> wait tone
$r = Generate-Reply $testRules "buyer1" "can you give me a quote?" @("[ME] Could you share the weight (kg)?","[ME] Could you share the packaging dimensions?","[BUYER] can you give me a quote?")
Assert-Contains "A-asklimit" $r "No rush"
# 22. address provided (with context) -> confirm receipt and ask remaining missing items
$r = Generate-Reply $testRules "buyer1" "the address is calle 456" @("[BUYER] the address is calle 456")
Assert-Contains "A-address" $r "Almost there"
Assert-Contains "A-address-weight" $r "weight"
# 23. shipment tracking
$r = Generate-Reply $testRules "buyer1" "where is my cargo?" @()
Assert-Contains "A-tracking" $r "warehouse"
# 24. default (no greeting prefix) -> ask missing info
$r = Generate-Reply $testRules "buyer1" "tell me about your service" @()
Assert-Contains "A-default" $r "weight"
# 25. Get-MissingInfo: weight present -> not missing
$missing = Get-MissingInfo "the weight is 20 kg" $testRules.data_to_collect
Assert-True "MI-weight-present" ($missing -notcontains "weight (kg)")
# 26. Get-MissingInfo: address absent -> missing
$missing = Get-MissingInfo "20 kg 10x10x10 cm" $testRules.data_to_collect
Assert-True "MI-addr-missing" ($missing -contains "recipient's address")
# 27. Get-MissingInfo: es address words
$missing = Get-MissingInfo "peso 20kg, medidas 10x10x10, calle 1" $testRules.data_to_collect
Assert-True "MI-es-addr" ($missing -notcontains "recipient's address")
# 28. stable hash normalization (translation markers / whitespace / punctuation / case)
$h1 = Get-StableHash "20kg 由阿里翻译提供, 箱子: 3!"
$h2 = Get-StableHash "20KG 箱子 3"
Assert-Eq "hash-normalize" $h1 $h2
# 29. Detect-Lang
Assert-Eq "lang-pt" (Detect-Lang "quanto custa o frete?") "pt"
Assert-Eq "lang-es" (Detect-Lang "cuanto cuesta el envio?") "es"
Assert-Eq "lang-fr" (Detect-Lang "merci beaucoup") "fr"
Assert-Eq "lang-en" (Detect-Lang "hello there") "en"
# 30. Get-StateKey
Assert-Eq "statekey" (Get-StateKey "  John Smith  ") "john smith"
# 31. Get-PromisedFields: buyer promises dimensions -> dimension promised
$p = Get-PromisedFields @("[BUYER] i will send you the dimensions tomorrow")
Assert-True "promise-dimension" ($p -contains 'dimension')
# 32. promised field is not asked again (missing list filtered)
$r = Generate-Reply $testRules "buyer1" "please give me a quote" @("[BUYER] i will send you the dimensions tomorrow","[BUYER] please give me a quote")
Assert-NotContains "A-promise-noask-dim" $r "dimension"
Assert-Contains "A-promise-asks-others" $r "weight"

# ===== 禁止经理类措辞 (spec 禁止经理措辞 v0.1 Phase 5.1) =====
# 33. short confirm ("ok") output: no manager/boss/supervisor, contains finalize
$r = Generate-Reply $testRules "buyer1" "ok" @()
foreach ($__bw in @("manager","boss","supervisor")) { Assert-NotContains ("A-confirm-ban-" + $__bw) $r $__bw }
Assert-Contains "A-confirm-finalize" $r "finalize"
# 34. all-details provided -> complete-quote output: no banned words, contains finalize
$r = Generate-Reply $testRules "buyer1" "20 kg, 10x10x10 cm, calle 123 madrid, photo attached" @("[BUYER] 20 kg, 10x10x10 cm, calle 123 madrid, photo attached")
foreach ($__bw in @("manager","boss","supervisor")) { Assert-NotContains ("A-allinfo-ban-" + $__bw) $r $__bw }
Assert-Contains "A-allinfo-finalize" $r "finalize"
# 35. quote request with complete context (branch 13, weight known) -> no banned words, contains finalize
$r = Generate-Reply $testRules "buyer1" "can you send me a quote please?" @("[BUYER] 20 kg, 10x10x10 cm, calle 123 madrid, photo attached","[BUYER] can you send me a quote please?")
foreach ($__bw in @("manager","boss","supervisor")) { Assert-NotContains ("A-quote-ban-" + $__bw) $r $__bw }
Assert-Contains "A-quote-finalize" $r "finalize"
# 36. Test-BannedText: hits (word boundary, case-insensitive, plural/possessive, Chinese)
Assert-Eq "ban-manager"        (Test-BannedText "I'll confirm with my manager and get back." $null) "manager"
Assert-Eq "ban-manager-cap"    (Test-BannedText "ask My Manager first" $null) "manager"
Assert-Eq "ban-managers-pl"    (Test-BannedText "our managers will review" $null) "manager"
Assert-Eq "ban-senior"         (Test-BannedText "my senior manager will check" $null) "senior manager"
Assert-Eq "ban-boss"           (Test-BannedText "Sure boss" $null) "boss"
Assert-Eq "ban-supervisor"     (Test-BannedText "ask my supervisor" $null) "supervisor"
Assert-Eq "ban-cn-shangji"     (Test-BannedText "请示上级后答复您" $null) "上级"
Assert-Eq "ban-cn-jingli"      (Test-BannedText "我和经理确认后回复" $null) "经理"
Assert-Eq "ban-cn-zhuguan"     (Test-BannedText "需要主管批准" $null) "主管"
# 37. Test-BannedText: no false positives (allowed wording, boundary safety, custom list)
Assert-True "ban-clean-warehouse" ($null -eq (Test-BannedText "let me check with the warehouse and our team" $null))
Assert-True "ban-clean-manage"     ($null -eq (Test-BannedText "how do you manage shipping" $null))
Assert-True "ban-clean-managerial" ($null -eq (Test-BannedText "managerial tasks" $null))
Assert-True "ban-customlist"       ($null -eq (Test-BannedText "with my manager" @("boss","supervisor")))
Assert-Eq   "ban-customlist-hit"   (Test-BannedText "ok boss" @("boss")) "boss"

# ===== 责任/费用红线（2026-09-10 事故整改）=====
# 38. 责任索赔消息（钱+责任双重信号）-> 核实话术分支；不得揽责/承诺金额
$r = Generate-Reply $testRules "buyer1" "someone needs to be responsible for this cost, I paid `$3500 for crane rental because of the customs delay" @()
Assert-Contains "A-claim-verified" $r "checking with the team"
Assert-NotContains "A-claim-no-resp" $r "responsible for this cost"
Assert-NotContains "A-claim-no-onus" $r "on us"
Assert-NotContains "A-claim-no-oop" $r "out of pocket"
Assert-NotContains "A-claim-nomanager" $r "manager"
# 39. 纯催单（含 delayed）不得进入索赔分支
$r = Generate-Reply $testRules "buyer1" "any update on my shipment, it's delayed" @()
Assert-Contains "A-status-delay" $r "warehouse"
Assert-NotContains "A-status-notclaim" $r "Regarding the costs"
# 40. 纯报价请求不得进入索赔分支
$r = Generate-Reply $testRules "buyer1" "how much for shipping to NY" @()
Assert-Contains "A-quote2" $r "weight"
Assert-NotContains "A-quote2-notclaim" $r "checking with the team"
# 41. 西语索赔变体
$r = Generate-Reply $testRules "buyer1" "quién es responsable de este costo" @()
Assert-Contains "A-claim-es" $r "sorry"
Assert-NotContains "A-claim-es-noresp" $r "responsible for this cost"
# 42. Test-FinancialCommitment: 责任/费用承诺句命中
Assert-True "fin-hit-take-resp"  ($null -ne (Test-FinancialCommitment "we'll take responsibility for this cost and make it right"))
Assert-True "fin-hit-onus"       ($null -ne (Test-FinancialCommitment "this is on us, not you"))
Assert-True "fin-hit-thats-onus" ($null -ne (Test-FinancialCommitment "that's on us"))
Assert-True "fin-hit-oop"        ($null -ne (Test-FinancialCommitment "you shouldn't be out of pocket for that `$3500"))
Assert-True "fin-hit-cover"      ($null -ne (Test-FinancialCommitment "we'll cover the `$3500 crane rental"))
Assert-True "fin-hit-incident"   ($null -ne (Test-FinancialCommitment "We take responsibility for this cost and will make it right"))
# 43. Test-FinancialCommitment: 正当业务表述不误伤（responsible/cover 单用、报价语境）
Assert-True "fin-clean-template" ($null -eq (Test-FinancialCommitment "we will be responsible for delivering the package to your designated address as agreed upon"))
Assert-True "fin-clean-deliver"  ($null -eq (Test-FinancialCommitment "we are responsible for delivering to your address as agreed"))
Assert-True "fin-clean-quote"    ($null -eq (Test-FinancialCommitment "I'll finalize your quote and get back to you shortly"))
Assert-True "fin-clean-service"  ($null -eq (Test-FinancialCommitment "we cover the full route with door-to-door service"))

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"

