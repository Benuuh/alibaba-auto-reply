# gonghai module regression tests — 公海客户开发模块
#
# 覆盖:破冰话术合规与定稿一致性、幂等键、限速下限与抖动区间、配置硬夹、状态原子写、幂等判定。
# 设计原则:**不联网、不碰浏览器、不发送任何消息**;只测纯逻辑与本地状态文件。
# 测试用的幂等键用明显不会与真实客户碰撞的假 key,并在 finally 里清理。
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\gonghai.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\log.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
. (Join-Path $scripts "gonghai\gonghai_cdp.ps1")
. (Join-Path $scripts "gonghai\gonghai_lib.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-False([string]$name, [bool]$cond) {
    if (-not $cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}
function Assert-Match([string]$name, [string]$s, [string]$pat) {
    if ($s -match $pat) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | [$s] !~ /$pat/" }
}
function Assert-NotMatch([string]$name, [string]$s, [string]$pat) {
    if ($s -notmatch $pat) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | [$s] =~ /$pat/" }
}

Write-Output "== gonghai tests =="

# ---- 用例 1:破冰话术必须与 §6.5.15 老板定稿**逐字一致** ----
# 定稿文本硬编码在此:任何人改动 icebreaker.md 都会立刻让本用例失败(防"话术被悄悄改")。
$expected = "Hello. I'm reaching out to see if you have any upcoming procurement needs. I'd be happy to provide a shipping cost quotation to assist with your project's feasibility assessment."
$actual = Get-GonghaiIcebreaker
Assert-Eq "G1-icebreaker-exact-match-spec" $actual $expected

# ---- 用例 2:破冰话术合规硬约束(§4-7 / §6.5.6) ----
Assert-NotMatch "G2-no-digit"        $actual '\d'
Assert-False    "G2-no-at-sign"      ($actual.Contains('@'))
Assert-NotMatch "G2-no-price-words"  $actual '(?i)usd|price|discount|quote amount'
Assert-NotMatch "G2-no-phone-or-url" $actual '(?i)https?://|www\.|\+\d'
Assert-NotMatch "G2-no-mass-mailing" $actual '(?i)dear sir|madam|to whom it may concern'
Assert-NotMatch "G2-no-inquiry-claim" $actual '(?i)thanks for your inquiry'   # §1 #11:对冷客户错误
$wordCount = (@($actual -split '\s+') | Where-Object { $_ }).Count
Assert-True "G2-word-count-le-40 (got $wordCount)" ($wordCount -le 40)
Assert-True "G2-word-count-ge-10 (got $wordCount)" ($wordCount -ge 10)

# ---- 用例 3:幂等键 ----
$ibId = Get-GonghaiIcebreakerId
Assert-Match "G3-icebreaker-id-8hex" $ibId '^[0-9a-f]{8}$'
Assert-Eq "G3-hash-stable" (Get-GonghaiHash8 "abc") (Get-GonghaiHash8 "abc")
Assert-True "G3-hash-changes-with-input" ((Get-GonghaiHash8 "abc") -ne (Get-GonghaiHash8 "abd"))
Assert-Match "G3-hash-shape" (Get-GonghaiHash8 "x") '^[0-9a-f]{8}$'
# key_hash 语义 = sha1(customer_key + '|' + icebreaker_id)[0:8]
$sampleKey = 'deadbeefdeadbeefdeadbeefdeadbeef'
$expectHash = Get-GonghaiHash8 ($sampleKey + "|" + $ibId)
Assert-Match "G3-keyhash-shape" $expectHash '^[0-9a-f]{8}$'

# ---- 用例 4:限速规格(§6.5.4) ----
# [DECISION 2026-09-27 深夜] 老板"取消这个限制" ⇒ 最小间隔下限 90000 → **0 = 不间隔**。
#   断言口径跟着改,但**必须证明"取消"是可逆的**:抖动公式仍在,把配置写回正数即恢复原节奏
#   (下面用"篡改 config 的子进程"验 90000 ⇒ 63000..117000 的区间)。
$cfg = Get-GonghaiConfig
Assert-Eq "G4-min-interval-floor-0" ([int]$script:GonghaiMinIntervalFloorMs) 0
Assert-Eq "G4-live-min-interval-is-0" ([int]$cfg.minIntervalMs) 0
# 间隔为 0 ⇒ 等待恒为 0(限速门恒放行);绝不能返回负数或噪声
$w0 = @(); for ($i = 0; $i -lt 50; $i++) { $w0 += (Get-GonghaiWaitMs) }
Assert-Eq "G4-zero-interval-waits-zero" (@($w0 | Where-Object { $_ -ne 0 }).Count) 0
# [SYNC 2026-09-27] 单次运行上限 3 → 10:老板 16:46 裁决(留痕见 gonghai_lib.ps1 §6.5.4 上方注释)。
#   断言口径**未变**(硬上限必须是那个常量;配置再大也被夹回它),只是跟着裁决更新值。
#   ⚠️ 本条与下面两条 G4-clamp / G4-config-restored 是同一处权威链(常量 ↔ config ↔ probe ValidateRange)。
Assert-Eq "G4-run-cap-hard-10" $script:GonghaiRunCapHard 10
Assert-True "G4-run-cap-not-above-10" ($cfg.runCap -le 10)
Assert-True "G4-jitter-not-above-30" ($cfg.jitterPct -le 30)

# 单次运行上限 + 抖动公式:篡改 config 后在**新进程**里复核(缓存必须清掉)
$oldCfgText = $null
$cfgFile = Join-Path $scripts "config.json"
if (Test-Path $cfgFile) { $oldCfgText = [System.IO.File]::ReadAllText($cfgFile) }
try {
    if ($oldCfgText) {
        $tampered = $oldCfgText -replace '"gonghai_min_interval_ms"\s*:\s*\d+', '"gonghai_min_interval_ms":90000'
        $tampered = $tampered -replace '"gonghai_run_cap"\s*:\s*\d+', '"gonghai_run_cap":99'
        $tampered = $tampered -replace '"gonghai_jitter_pct"\s*:\s*\d+', '"gonghai_jitter_pct":90'
        [System.IO.File]::WriteAllText($cfgFile, $tampered, (New-Object System.Text.UTF8Encoding($false)))
        # 清掉 config 缓存:Get-SkillConfig 有 $script:__skillConfig 记忆
        # 重新 dot-source 前先清缓存变量
        $ps = [powershell]::Create()
        $ps.AddScript(@"
. '$scripts\config.ps1'
. '$scripts\gonghai\gonghai_lib.ps1'
`$c = Get-GonghaiConfig
`$mn = [int]::MaxValue; `$mx = 0
for (`$i = 0; `$i -lt 300; `$i++) { `$w = Get-GonghaiWaitMs; if (`$w -lt `$mn) { `$mn = `$w }; if (`$w -gt `$mx) { `$mx = `$w } }
Write-Output (`$c.minIntervalMs.ToString() + '|' + `$c.runCap.ToString() + '|' + `$c.jitterPct.ToString() + '|' + `$mn.ToString() + '|' + `$mx.ToString())
"@) | Out-Null
        $out = ($ps.Invoke() | Out-String).Trim()
        $ps.Dispose()
        $parts = $out -split '\|'
        # 恢复间隔(90000)后:抖动区间必须回到 [0.7,1.3]×90000 = 63000..117000 ⇒ **取消是可逆的**
        Assert-Eq "G4-restore-interval-90000"      ([int]$parts[0]) 90000
        Assert-Eq "G4-clamp-run-cap-back-to-10"    ([int]$parts[1]) 10
        Assert-Eq "G4-clamp-jitter-back-to-30"     ([int]$parts[2]) 30
        Assert-True "G4-jitter-lower-bound>=63000 (min=$($parts[3]))" ([int]$parts[3] -ge 63000)
        Assert-True "G4-jitter-upper-bound<=117000 (max=$($parts[4]))" ([int]$parts[4] -le 117000)
        Assert-True "G4-jitter-actually-varies"    ([int]$parts[4] -gt [int]$parts[3])
    }
} finally {
    if ($oldCfgText) { [System.IO.File]::WriteAllText($cfgFile, $oldCfgText, (New-Object System.Text.UTF8Encoding($false))) }
}
# 恢复后复核配置未被测试弄坏
#   [SYNC 2026-09-27] 这两条的**目的**是"证明测试没把现役配置改坏"(见上句),不是钉死策略值 ——
#   故与"篡改前读到的原值"比对,而不是写死策略值:否则老板每次调上限都会得到一条假红。
$cfgAfter = (Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json)
$cfgBefore = $null
if ($oldCfgText) { try { $cfgBefore = $oldCfgText | ConvertFrom-Json } catch { $cfgBefore = $null } }
if ($cfgBefore) {
    Assert-Eq "G4-config-restored-interval" ([int]$cfgAfter.gonghai_min_interval_ms) ([int]$cfgBefore.gonghai_min_interval_ms)
    Assert-Eq "G4-config-restored-runcap"   ([int]$cfgAfter.gonghai_run_cap)   ([int]$cfgBefore.gonghai_run_cap)
} else {
    Assert-Eq "G4-config-restored-interval" ([int]$cfgAfter.gonghai_min_interval_ms) 0
    Assert-Eq "G4-config-restored-runcap"   ([int]$cfgAfter.gonghai_run_cap)   10
}

# ---- 用例 5:状态文件原子写 + 幂等判定 ----
$testKey = 'TESTKEY00000000000000000000000000'   # 明显假 key,不与真实 data-row-key(32hex) 冲突
$idxPath = Get-GonghaiPath "sent_index.json"
$backup = $null
if (Test-Path $idxPath) { $backup = [System.IO.File]::ReadAllText($idxPath) }
try {
    # 初始:未发送过
    $idx = Get-GonghaiSentIndex
    Assert-False "G5-fresh-key-not-sent" (Test-GonghaiAlreadySent -Index $idx -CustomerKey $testKey)

    # 先写后发:记 unverified 后,幂等判定必须立刻命中(崩溃重启防线)
    [void](Set-GonghaiSentRecord -Index $idx -CustomerKey $testKey -Status "unverified" -CodeName "gh-test0001")
    $idx2 = Get-GonghaiSentIndex
    Assert-True "G5-unverified-blocks-resend" (Test-GonghaiAlreadySent -Index $idx2 -CustomerKey $testKey)

    # 记录形状
    $rec = $null
    foreach ($p in $idx2.items.PSObject.Properties) { if ($p.Name -eq $testKey) { $rec = $p.Value } }
    Assert-True "G5-record-written" ($null -ne $rec)
    if ($rec) {
        Assert-Eq    "G5-record-status"  ([string]$rec.status) "unverified"
        Assert-Eq    "G5-record-ib-id"   ([string]$rec.icebreaker_id) $ibId
        Assert-Match "G5-record-keyhash" ([string]$rec.key_hash) '^[0-9a-f]{8}$'
        Assert-Eq    "G5-record-attempts" ([int]$rec.attempts) 1
        Assert-Eq    "G5-record-code"    ([string]$rec.code_name) "gh-test0001"
        # PII 纪律:账本里**不得**出现客户名/邮箱字段
        $names = @($rec.PSObject.Properties.Name)
        Assert-False "G5-no-name-field"  ($names -contains 'name')
        Assert-False "G5-no-email-field" ($names -contains 'email')
    }

    # 状态升级为 sent 后仍必须命中(防重发)
    $idx3 = Get-GonghaiSentIndex
    [void](Set-GonghaiSentRecord -Index $idx3 -CustomerKey $testKey -Status "sent" -CodeName "gh-test0001")
    $idx4 = Get-GonghaiSentIndex
    Assert-True "G5-sent-blocks-resend" (Test-GonghaiAlreadySent -Index $idx4 -CustomerKey $testKey)

    # attempts 应递增到 2
    $rec2 = $null
    foreach ($p in $idx4.items.PSObject.Properties) { if ($p.Name -eq $testKey) { $rec2 = $p.Value } }
    if ($rec2) { Assert-Eq "G5-attempts-increment" ([int]$rec2.attempts) 2 }

    # 原子写:JSON 必须可解析且 version=1
    $parsed = (Get-Content $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-Eq "G5-json-version" ([int]$parsed.version) 1
    Assert-True "G5-json-has-items" ($parsed.PSObject.Properties.Name -contains 'items')
} finally {
    # 还原:测试 key 不得留在真实账本里
    if ($backup) { [System.IO.File]::WriteAllText($idxPath, $backup, (New-Object System.Text.UTF8Encoding($false))) }
    else { if (Test-Path $idxPath) { Remove-Item $idxPath -Force -ErrorAction SilentlyContinue } }
}
$idxFinal = Get-GonghaiSentIndex
Assert-False "G5-test-key-cleaned" (Test-GonghaiAlreadySent -Index $idxFinal -CustomerKey $testKey)

# ---- 用例 6:限速门(Test-GonghaiRateGate) ----
# [DECISION 2026-09-27 深夜] 最小间隔被取消(0 = 不间隔) ⇒ "刚发过就必须等"这条**语义已不存在**。
#   断言跟着改,但"门本身还在"必须验到:间隔为 0 时它必须**恒放行**且 waitMs=0
#   (将来把 `gonghai_min_interval_ms` 写回正数,门会自动恢复拦截 —— 由 G4 的子进程用例证明可逆)。
$ratePath = Get-GonghaiPath "gonghai_rate.json"
$rateBackup = $null
if (Test-Path $ratePath) { $rateBackup = [System.IO.File]::ReadAllText($ratePath) }
try {
    $gate = Test-GonghaiRateGate
    # 没有 last_sent_at 时必须放行
    Assert-True "G6-first-send-allowed" ($gate.ok -or $gate.reason -ne 'FIRST')
    # 写一条"刚刚发过" ⇒ 间隔=0 时**不得**再拦
    Set-GonghaiRate -LastSentAt (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $gate2 = Test-GonghaiRateGate
    Assert-True "G6-zero-interval-allows-immediate-resend" ([bool]$gate2.ok)
    Assert-Eq   "G6-zero-interval-wait-is-0" ([int]$gate2.waitMs) 0
    # 当日计数应为 1
    Assert-True "G6-day-count-positive" ((Get-GonghaiDailyCount) -ge 1)
} finally {
    if ($rateBackup) { [System.IO.File]::WriteAllText($ratePath, $rateBackup, (New-Object System.Text.UTF8Encoding($false))) }
    else { if (Test-Path $ratePath) { Remove-Item $ratePath -Force -ErrorAction SilentlyContinue } }
}

# ---- 用例 7:模块文件齐备 + 脚本带 BOM(§4-6) ----
foreach ($f in @('gonghai_cdp.ps1','gonghai_lib.ps1','gonghai_probe.ps1','gonghai_recon.ps1','gonghai_batch.ps1','icebreaker.md')) {
    Assert-True "G7-file-exists $f" (Test-Path (Join-Path $scripts "gonghai\$f"))
}
foreach ($f in @('gonghai_cdp.ps1','gonghai_lib.ps1','gonghai_probe.ps1','gonghai_recon.ps1','gonghai_batch.ps1')) {
    $p = Join-Path $scripts "gonghai\$f"
    if (Test-Path $p) {
        $b = [System.IO.File]::ReadAllBytes($p)
        $isBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
        Assert-True "G7-bom-present $f" $isBom
    }
}

# ---- 用例 8:禁止项静态检查(防止把危险操作写回代码) ----
$probePath = Join-Path $scripts "gonghai\gonghai_probe.ps1"
$probeText = [System.IO.File]::ReadAllText($probePath)
$libPath = Join-Path $scripts "gonghai\gonghai_lib.ps1"
$libText = [System.IO.File]::ReadAllText($libPath)
# 必须在发送/认领路径上取写锁
Assert-Match "G8-probe-uses-get-applock"    $probeText 'Get-AppLock'
Assert-Match "G8-probe-uses-release-lock"   $probeText 'Release-AppLock'
# 必须复用既有发送实现(而不是自己造一个)
Assert-Match "G8-probe-reuses-send-one-talk" $probeText 'Send-OneTalkMessage'
# 必须做发对人校验(customerId 比对)
Assert-Match "G8-probe-verifies-customerid" $probeText 'cardId'
# 必须恢复 OneTalk 列表状态
Assert-Match "G8-lib-restores-list"  $libText 'Restore-OneTalkList'
Assert-Match "G8-lib-asserts-contacts" $libText 'contact-item-container'
# 禁止触碰表头全选 / 清空所有筛选项(§6.5.12)
foreach ($bad in @('thead input','ant-table-selection','清空所有筛选项')) {
    Assert-False ("G8-probe-must-not-touch: " + $bad) ($probeText.Contains($bad))
    Assert-False ("G8-lib-must-not-touch: " + $bad)   ($libText.Contains($bad))
}
# 禁止在公海模块里调用 monitor 的重载/自愈(§6.5.2)
foreach ($bad in @('Invoke-PageReload','chrome_ensure')) {
    Assert-False ("G8-lib-must-not-call: " + $bad) ($libText.Contains($bad))
}
# DryRun 不得触发认领(实测教训:一次 DRYRUN 误认领占名额)
Assert-Match "G8-dryrun-skips-claim" $probeText '\$DryRun\)\s*\{'

# ---- 用例 9:[SPEC-公海独立Chrome 2026-09-27 §3.3] 单独 dot-source 时的兜底匹配串必须仍然设防 ----
# 本测试文件**只** dot-source 了 gonghai_lib.ps1(没有 gonghai_cdp.ps1)⇒ `$script:OnetalkUrlPattern`
# 此刻是空的,Get-GonghaiOnetalkUrlMatch 走的正是**兜底字面量**那条分支。这里锁死:
#   ① 兜底值非空(绝不能变成 $null —— 那会让 `-match $null` 恒真 = 完全不设防);
#   ② 兜底值就是 onetalk 域名:**不再带任何标记**(标记方案已按 §2.2 整体撤销);
#   ③ 兜底字面量与 gonghai_cdp.ps1 的权威常量**逐字一致**(防两处漂移)。
$libOnlyMatch = Get-GonghaiOnetalkUrlMatch
Assert-True "G9-default-match-nonempty" ($libOnlyMatch -and $libOnlyMatch.Trim().Length -gt 0)
Assert-Eq   "G9-default-match-is-plain-domain" $libOnlyMatch 'onetalk\.alibaba\.com'
Assert-False "G9-default-match-has-no-marker" ($libOnlyMatch -match 'dshgh')
Assert-True  "G9-default-match-hits-onetalk-url" (('https://onetalk.alibaba.com/message/weblitePWA.htm?activeAccountId=285965039#/') -match $libOnlyMatch)
Assert-False "G9-default-match-rejects-crm-url" (('https://i.alibaba.com/hub/alicrm/public_customer') -match $libOnlyMatch)
# ③ 源码级逐字对照(不依赖 gonghai_cdp.ps1 是否被加载)
$cdpSrcText = Get-Content (Join-Path $scripts "gonghai\gonghai_cdp.ps1") -Raw
# ⚠️ 必须**行首锚定**:注释里也会出现 `$script:OnetalkUrlPattern` 这类字样(说明为什么用它)
$mPat = [regex]::Match($cdpSrcText, "(?m)^\s*\`$script:OnetalkUrlPattern\s*=\s*'([^']+)'")
Assert-True "G9-cdp-declares-onetalk-pattern" $mPat.Success
if ($mPat.Success) {
    Assert-Eq "G9-lib-fallback-literal-identical-to-cdp-constant" $libOnlyMatch $mPat.Groups[1].Value
}
# [SPEC-公海独立Chrome §2.2] 标记方案的常量必须**已从 gonghai_cdp.ps1 消失**(行首锚定,避开注释)
Assert-False "G9-cdp-no-marker-constant" ([regex]::IsMatch($cdpSrcText, "(?m)^\s*\`$script:GonghaiTabMarker\s*="))
Assert-False "G9-cdp-no-marker-pattern-constant" ([regex]::IsMatch($cdpSrcText, "(?m)^\s*\`$script:GonghaiOnetalkPattern\s*="))
# 公海端口必须是自己的(9225),不得回退到共用端口
Assert-Eq "G9-cdp-port-is-9225" (Get-GonghaiCdpPort) 9225

# ---- 用例 10:[2026-09-27 事故] 公海写锁范围只允许覆盖"页面写窗口" ----
# 事故(实测 monitor.log):当天 LOCK-BUSY 844 次、47 段合计 80.9 分钟没有任何扫描,
#   单段最长 15:59:41→16:11:20 = **11.6 分钟**完全静默(有买家消息也只能干等)。
#   根因:公海把"认领生效轮询(最长 20 秒)""6 轮搜索重试(每轮含 10/15 秒等待)""取页(最长 15 秒)"
#   "限速等待(最长 117 秒)"全放在 onetalk-write 锁里 ⇒ monitor 每轮 0 超时抢锁必然被拒。
# 本用例用 AST 精确定位"锁窗口"(= Finally 块里**真的调用** Release-AppLock 的那个 try),
#   钉死三件事,防止回退:
#     ① 窗口里不得有任何等待/搜索/取页/探针/限速门(它们不需要互斥);
#     ② 窗口里必须有"发对人校验(Open-GonghaiSearchResult + cardId)"**且位于发送调用之前**
#        —— 硬约束:校验与发送不许拆到两个窗口;
#     ③ 发送窗口的 finally 必须"先恢复页面(§6.5.14)、再释放锁",任何 return/异常都不漏释放。
function Get-LockWindows([string]$Path) {
    # 判据不用正则猜:必须是 TryStatementAst,且其 Finally 里存在**命令调用** Release-AppLock
    #   (注释里提到 Release-AppLock 不算 —— 例如"这里不许 Release-AppLock"那种说明)。
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    $out = New-Object System.Collections.ArrayList
    foreach ($t in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
        if (-not $t.Finally) { continue }
        $rel = @($t.Finally.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Release-AppLock' }, $true))
        if ($rel.Count -eq 0) { continue }
        # 去注释(整行 + 行尾):注释里写"Start-Sleep/搜索"是用来解释为什么挪出去的,不能算违规
        $body = (@($t.Body.Extent.Text -split "`n") | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
        $fin  = (@($t.Finally.Extent.Text -split "`n") | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
        [void]$out.Add([pscustomobject]@{ line = $t.Extent.StartLineNumber; body = $body; finally = $fin })
    }
    return @($out)
}
function Get-SendCallIndex([string]$Body) {
    # [2026-09-27 收敛] 发送调用只剩一种写法:`Send-OneTalkMessage`(在 lib 的唯一窗口里)。
    #   旧版还要找 probe 的包装函数 `Invoke-GonghaiSend` —— 那个包装已随窗口一起移入 lib。
    return $Body.IndexOf('Send-OneTalkMessage')
}

$batchPath = Join-Path $scripts "gonghai\gonghai_batch.ps1"
$libPath   = Join-Path $scripts "gonghai\gonghai_lib.ps1"
$batchText = [System.IO.File]::ReadAllText($batchPath)
$libText   = [System.IO.File]::ReadAllText($libPath)
$batchW = @(Get-LockWindows $batchPath)
$probeW = @(Get-LockWindows $probePath)
$libW   = @(Get-LockWindows $libPath)
$allW   = @($batchW) + @($probeW) + @($libW)

# [2026-09-27 收敛] 结构断言跟着架构改:**发送窗口只剩一处**(lib),两个入口都委派给它。
#   为什么这是进步而不是放松:事故根因正是"同一判据两份实现" ⇒ 现在结构上不可能再漂移。
Assert-Eq   "G10-lib-exactly-one-send-window (got $($libW.Count))" $libW.Count 1
Assert-Eq   "G10-batch-own-window-is-claim-only (got $($batchW.Count))" $batchW.Count 1
Assert-True "G10-probe-keeps-own-claim-window (got $($probeW.Count))" ($probeW.Count -ge 1)
# 发送调用**不得**再出现在 batch/probe 自己的窗口里(否则又变成两份实现)
Assert-Eq   "G10-no-send-call-in-entrypoint-windows" (@(@($batchW) + @($probeW)) | Where-Object { $_.body -match 'Send-OneTalkMessage' }).Count 0

# ① 锁窗口里不得有"等"或"搜索"或"取页/探针"
Assert-Eq "G10-no-sleep-inside-any-lock-window" (@($allW | Where-Object { $_.body -match 'Start-Sleep' }).Count) 0
Assert-Eq "G10-no-search-inside-any-lock-window" (@($allW | Where-Object { $_.body -match 'Invoke-OneTalkSearch|Open-OneTalkSearchPanel|Get-GonghaiSearchResultCount' }).Count) 0
Assert-Eq "G10-no-read-or-ready-wait-inside-any-lock-window" (@($allW | Where-Object { $_.body -match 'Test-GonghaiRateGate|Ensure-GonghaiOnetalkTab|Test-GonghaiPageHealth|Get-GonghaiRiskSignal' }).Count) 0
Assert-Eq "G10-lock-acquired-outside-window-body" (@($allW | Where-Object { $_.body -match 'Get-AppLock|Wait-Lock|Wait-ProbeLock|Wait-GonghaiLock' }).Count) 0
Assert-Eq "G10-no-claim-verify-poll-inside-any-lock-window" (@($allW | Where-Object { $_.body -match 'Test-GonghaiRowClaimed|Wait-GonghaiClaimEffect' }).Count) 0
# 缩锁不等于把点击也挪出去:认领点击必须仍在锁窗口里
Assert-True "G10-claim-click-still-inside-lock-window (got $(@($allW | Where-Object { $_.body -match 'Invoke-GonghaiClaimRow|Invoke-GonghaiClaim\b' }).Count))" (@($allW | Where-Object { $_.body -match 'Invoke-GonghaiClaimRow|Invoke-GonghaiClaim\b' }).Count -ge 2)

# ② 发对人校验 + 发送必须同一个窗口,且校验在前(现在只有那一个窗口,判据更硬)
$sendW = $libW
Assert-Eq "G10-send-window-count" $sendW.Count 1
Assert-Eq "G10-every-send-window-verifies-identity" (@($sendW | Where-Object { $_.body -notmatch 'Open-GonghaiSearchResult' }).Count) 0
Assert-Eq "G10-every-send-window-compares-cardid" (@($sendW | Where-Object { $_.body -notmatch 'cardId' }).Count) 0
Assert-Eq "G10-verify-before-send-in-same-window" (@($sendW | Where-Object { $_.body.IndexOf('Open-GonghaiSearchResult') -gt (Get-SendCallIndex $_.body) }).Count) 0
Assert-Eq "G10-unverified-written-inside-send-window" (@($sendW | Where-Object { $_.body -notmatch "Status 'unverified'" }).Count) 0
# fail-closed:读不到 customerId 必须是**独立的一支**(不许和"不等"混在一句里)
Assert-Match "G10-lib-failclosed-no-cardid-branch" $libText "verdict = 'NO_CARDID'"

# ③ 发送窗口 finally:先恢复页面(§6.5.14),再释放锁
Assert-Eq "G10-every-send-window-restores-page-in-finally" (@($sendW | Where-Object { $_.finally -notmatch 'Restore-OneTalkList' }).Count) 0
Assert-Eq "G10-restore-before-release-in-finally" (@($sendW | Where-Object { $_.finally.IndexOf('Restore-OneTalkList') -gt $_.finally.IndexOf('Release-AppLock') }).Count) 0

# ④ 缩锁不等于删功能:被挪出去的步骤必须都还在,且两个入口都**委派**唯一窗口
Assert-Match "G10-batch-still-searches"  $batchText 'Invoke-OneTalkSearch'
Assert-Match "G10-batch-still-rate-gates" $batchText 'Test-GonghaiRateGate'
Assert-Match "G10-batch-delegates-send-window" $batchText 'Invoke-GonghaiSendWindow'
Assert-Match "G10-probe-delegates-send-window" $probeText 'Invoke-GonghaiSendWindow'
Assert-Match "G10-batch-still-locks"     $batchText 'Get-AppLock|Wait-GonghaiLock'
Assert-Match "G10-probe-still-searches"  $probeText 'Invoke-OneTalkSearch'
Assert-Match "G10-probe-still-locks"     $probeText 'Get-AppLock'
Assert-Match "G10-probe-still-releases"  $probeText 'Release-AppLock'

# ---- 用例 11:发送窗口的**行为**验证(纯桩;不碰浏览器、不碰真实锁文件) ----
# 为什么还要这一层:用例 10 只能证明"源码结构对不对",证明不了"调用顺序真的落在锁里"。
#   [2026-09-27 收敛] 窗口实现已从 probe **移入 lib**(`Wait-GonghaiLock` / `Invoke-GonghaiSendWindow`),
#   所以这里用 AST 从 **lib** 抽出这两个函数原样执行,把 Get-AppLock / Release-AppLock /
#   Open-GonghaiSearchResult / Set-GonghaiSentRecord / Send-OneTalkMessage / Complete-GonghaiSend /
#   Restore-OneTalkList 全换成"记录调用顺序"的桩,然后断言:
#     ① 顺序 = 取锁 → 开结果(读 cardId) → 先写后发 → 发送 → 记账 → 恢复页面 → 释放锁
#        ⇒ 发送确实在锁内,且恢复页面(页面写)也在释放之前;
#     ② cardId ≠ 公海 key ⇒ 一条都不发(WRONG_CONVO);读不到 cardId ⇒ NO_CARDID(同样不发);
#     ③ 发送抛异常 ⇒ 锁照样释放、页面照样恢复(缩锁最容易搞坏的就是这条);
#     ④ 抢不到锁 ⇒ 一个页面动作都不做;没有页面 ⇒ 直接释放(绝不回落到 monitor 的浏览器);
#     ⑤ -DryRun ⇒ 不发送、不写账本。
function Get-FnText([string]$Path, [string]$Name) {
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    $f = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)) | Select-Object -First 1
    if (-not $f) { return '' }
    return $f.Extent.Text
}

$script:LockName = 'gonghai-window-unit-test'   # 桩锁名(桩 Get-AppLock 不会创建任何真实锁文件)
$script:Trace = New-Object System.Collections.ArrayList
function Get-AppLock([string]$name, [int]$timeoutSec = 10) { [void]$script:Trace.Add('LOCK'); return [bool]$script:StubLockOk }
function Release-AppLock([string]$name) { [void]$script:Trace.Add('UNLOCK') }
function Restore-OneTalkList { [void]$script:Trace.Add('RESTORE'); return @{ ok = $true; contacts = 5; raw = '' } }
function Open-GonghaiSearchResult { param([string]$ExpectedKey = "", [int]$MaxTry = 3) [void]$script:Trace.Add('OPEN'); return $script:StubOpen }
function Set-GonghaiSentRecord { param($Index, [string]$CustomerKey, [string]$Status, [string]$CodeName) [void]$script:Trace.Add("REC:$Status"); return $null }
function Send-OneTalkMessage {
    param([string]$buyer, [string]$text, $Page = $null, [switch]$AlreadyOpen)
    [void]$script:Trace.Add('SEND')
    if (-not $AlreadyOpen) { [void]$script:Trace.Add('SEND-WITHOUT-ALREADYOPEN') }   # 公海路径必须带这个开关
    if ($script:StubSendThrows) { throw 'STUB-SEND-BOOM' }
    return [string]$script:StubSendResult
}
# 记账函数也用桩(否则会去写真实账本/限速文件/日志);但用**真的** Get-GonghaiSendStatus 映射结果串
function Complete-GonghaiSend {
    param($Index, [string]$CustomerKey, [string]$Code, [string]$SendResult)
    [void]$script:Trace.Add('COMPLETE')
    return (Get-GonghaiSendStatus $SendResult)
}
function Write-GonghaiLog { param([string]$Msg) }   # 静音:窗口内部的锁忙日志

$fnLock = Get-FnText $libPath 'Wait-GonghaiLock'
$fnWin  = Get-FnText $libPath 'Invoke-GonghaiSendWindow'
Assert-True "G11-window-functions-extracted-from-lib (lock=$($fnLock.Length) win=$($fnWin.Length))" ($fnLock.Length -gt 100 -and $fnWin.Length -gt 100)
# 两个入口都**不许**再自带窗口实现(防回退成两份)
Assert-Eq "G11-probe-no-local-window (got $((Get-FnText $probePath 'Invoke-GonghaiSendWindow').Length))" (Get-FnText $probePath 'Invoke-GonghaiSendWindow').Length 0
Assert-Eq "G11-batch-no-local-window (got $((Get-FnText $batchPath 'Invoke-GonghaiSendWindow').Length))" (Get-FnText $batchPath 'Invoke-GonghaiSendWindow').Length 0
Assert-Eq "G11-probe-no-local-lockwait (got $((Get-FnText $probePath 'Wait-ProbeLock').Length))" (Get-FnText $probePath 'Wait-ProbeLock').Length 0

if ($fnLock.Length -gt 100 -and $fnWin.Length -gt 100) {
    . ([scriptblock]::Create($fnLock))
    . ([scriptblock]::Create($fnWin))
    $dummyPage = [pscustomobject]@{ id = 'STUB'; url = 'https://onetalk.alibaba.com/message/weblitePWA.htm#/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/STUB' }
    $keyA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $keyB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

    # ① 正常路径:顺序必须严格是 取锁→开结果→先写后发→发送→记账→恢复→释放
    $script:Trace.Clear(); $script:StubLockOk = $true; $script:StubSendThrows = $false
    $script:StubSendResult = 'FILLED | CLICKED | SENT_OK'
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = $keyA; cardIdAbbrev = 'aaaaaaaa…'; hdrLen = 5 }
    $W = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1
    Assert-Eq "G11-happy-verdict" ([string]$W.verdict) 'DONE'
    Assert-True "G11-happy-send-passthrough" ([string]$W.send -match 'SENT_OK')
    Assert-Eq "G11-happy-status-mapped" ([string]$W.status) 'sent'
    Assert-Eq "G11-happy-call-order" ($script:Trace -join '>') 'LOCK>OPEN>REC:unverified>SEND>COMPLETE>RESTORE>UNLOCK'

    # ①b 公海发送必须带 `-AlreadyOpen`(否则又会去查那条会冻结的 .contact-item-container 列表)
    Assert-Eq "G11-happy-uses-alreadyopen" (@($script:Trace | Where-Object { $_ -eq 'SEND-WITHOUT-ALREADYOPEN' }).Count) 0

    # ② cardId 不匹配 ⇒ 绝不发送(CustomerId 精确比对是最强判据)
    $script:Trace.Clear(); $script:StubLockOk = $true
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = $keyB; cardIdAbbrev = 'bbbbbbbb…'; hdrLen = 5 }
    $W2 = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1
    Assert-Eq   "G11-wrong-convo-verdict" ([string]$W2.verdict) 'WRONG_CONVO'
    Assert-Eq   "G11-wrong-convo-no-send" ($script:Trace -join '>') 'LOCK>OPEN>RESTORE>UNLOCK'

    # ②b cardId 读不到(详情卡没渲染) ⇒ **fail-closed**:绝不发送(独立判据 NO_CARDID)
    $script:Trace.Clear(); $script:StubLockOk = $true
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = ''; cardIdAbbrev = '(none)'; hdrLen = 5 }
    $W2b = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1
    Assert-Eq "G11-no-cardid-verdict" ([string]$W2b.verdict) 'NO_CARDID'
    Assert-Eq "G11-no-cardid-no-send" ($script:Trace -join '>') 'LOCK>OPEN>RESTORE>UNLOCK'

    # ②c 未提供 key(历史路径)且 cardId 读不到 ⇒ INCONCLUSIVE(交上层等 10 秒重搜;同样不发送)
    $script:Trace.Clear(); $script:StubLockOk = $true
    $W2c = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey '' -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1
    Assert-Eq "G11-inconclusive-verdict" ([string]$W2c.verdict) 'INCONCLUSIVE'
    Assert-Eq "G11-inconclusive-no-send" ($script:Trace -join '>') 'LOCK>OPEN>RESTORE>UNLOCK'

    # ②d 没有公海页 ⇒ NO_TAB,且**立刻释放锁**(绝不允许回落到 monitor 的浏览器)
    $script:Trace.Clear(); $script:StubLockOk = $true
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = $keyA; cardIdAbbrev = 'aaaaaaaa…'; hdrLen = 5 }
    $W2d = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $null -Index $null -MaxWaitSec 1
    Assert-Eq "G11-no-tab-verdict" ([string]$W2d.verdict) 'NO_TAB'
    Assert-Eq "G11-no-tab-releases-lock" ($script:Trace -join '>') 'LOCK>UNLOCK'

    # ③ 发送抛异常 ⇒ 锁必须被释放、页面必须被恢复(绝不能因为缩小范围而漏释放)
    $script:Trace.Clear(); $script:StubLockOk = $true; $script:StubSendThrows = $true
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = $keyA; cardIdAbbrev = 'aaaaaaaa…'; hdrLen = 5 }
    $threw = $false
    try { [void](Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1) }
    catch { $threw = $true }
    Assert-True "G11-exception-propagates" $threw
    Assert-Eq   "G11-exception-still-restores-and-releases" ($script:Trace -join '>') 'LOCK>OPEN>REC:unverified>SEND>RESTORE>UNLOCK'
    $script:StubSendThrows = $false

    # ④ 抢不到锁 ⇒ 一个页面动作都不做(页面/账本/发送都不许被碰)
    $script:Trace.Clear(); $script:StubLockOk = $false
    $W4 = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -MaxWaitSec 1
    Assert-Eq "G11-lock-busy-verdict" ([string]$W4.verdict) 'LOCK_BUSY'
    # 只允许"试锁"这一个动作(桩把每次尝试记成 LOCK):页面/账本/发送/恢复一个都不许有
    $touched = @($script:Trace | Where-Object { $_ -ne 'LOCK' })
    Assert-Eq "G11-lock-busy-touches-nothing" ($touched -join '>') ''

    # ⑤ -DryRun:走完核对就返回 ⇒ 不发送、不写账本(但仍恢复页面并释放锁)
    $script:Trace.Clear(); $script:StubLockOk = $true
    $script:StubSendResult = 'SHOULD-NOT-BE-CALLED'
    $script:StubOpen = @{ clicked = $true; hasTa = $true; cardId = $keyA; cardIdAbbrev = 'aaaaaaaa…'; hdrLen = 5 }
    $W5 = Invoke-GonghaiSendWindow -Code 'gh-testtest' -ExpectedName 'Stub Buyer' -ExpectedKey $keyA -Text 'hello' -Page $dummyPage -Index $null -DryRun -MaxWaitSec 1
    Assert-Eq "G11-dryrun-verdict" ([string]$W5.verdict) 'DONE'
    Assert-Eq "G11-dryrun-no-send-no-ledger" ($script:Trace -join '>') 'LOCK>OPEN>RESTORE>UNLOCK'

    # ⑥ 桩锁名绝不能落到真实运行数据根(证明上面所有场景都没碰真实锁)
    $stubLockFile = Join-Path (Get-SkillPath "data") "gonghai-window-unit-test.lock"
    Assert-False "G11-no-real-lock-file-touched" (Test-Path $stubLockFile)
}

# ---- 用例 12:[DECISION 2026-09-27 晚] 当日配额闸:0 = 不限 ----
# 老板原话"取消每日的限制"⇒ `gonghai_daily_cap` = 0 必须被解释为**不限**。
#   为什么要有这一组:此前 daily_cap **只有 probe 检查**、batch 完全不检查(登记缺口),
#   而"取消限制"如果只改配置不改判据,任何一处内联比较都会把 0 读成"零配额"⇒ 直接死锁。
$capCfg = Get-GonghaiConfig
Assert-Eq    "G12-live-config-daily-cap-is-0" ([int]$capCfg.dailyCap) 0
$capNow = Test-GonghaiDailyCapReached
Assert-False "G12-unlimited-never-reached" ([bool]$capNow.reached)
Assert-True  "G12-unlimited-flag"          ([bool]$capNow.unlimited)
Assert-Eq    "G12-unlimited-reason"        ([string]$capNow.reason) 'UNLIMITED'
Assert-True  "G12-daily-count-reported (daily=$($capNow.daily))" ([int]$capNow.daily -ge 0)

# 静态接线:probe 与 batch **都**必须走同一个判据;不许任何一处内联重写比较逻辑
$probeSrcTxt = [System.IO.File]::ReadAllText($probePath)
$batchSrcTxt = [System.IO.File]::ReadAllText((Join-Path $scripts "gonghai\gonghai_batch.ps1"))
Assert-Match "G12-probe-uses-cap-gate"  $probeSrcTxt 'Test-GonghaiDailyCapReached'
Assert-Match "G12-batch-uses-cap-gate"  $batchSrcTxt 'Test-GonghaiDailyCapReached'
Assert-False "G12-probe-no-inline-daily-compare" ($probeSrcTxt -match '\$daily\s*-ge\s*\$cfg\.dailyCap')
Assert-False "G12-batch-no-inline-daily-compare" ($batchSrcTxt -match '\$daily\s*-ge\s*\$cfg\.dailyCap')

# 正数上限**仍然有效**(证明闸只是被"取消"而不是被"拆掉"):
#   把 cap 篡改成 1,当日计数必然 >= 1 ⇒ 必须 reached。
#   ⚠️ 同 G4:Get-SkillConfig 有进程内缓存 ⇒ 必须在**新的 powershell 实例**里重新 dot-source。
$cfgFileCap = Join-Path $scripts "config.json"
$oldCfgCap = $null
if (Test-Path $cfgFileCap) { $oldCfgCap = [System.IO.File]::ReadAllText($cfgFileCap) }
try {
    if ($oldCfgCap) {
        $tamperedCap = $oldCfgCap -replace '"gonghai_daily_cap"\s*:\s*-?\d+', '"gonghai_daily_cap":1'
        [System.IO.File]::WriteAllText($cfgFileCap, $tamperedCap, (New-Object System.Text.UTF8Encoding($false)))
        $psCap = [powershell]::Create()
        $psCap.AddScript(@"
. '$scripts\config.ps1'
. '$scripts\gonghai\gonghai_lib.ps1'
`$r = Test-GonghaiDailyCapReached
Write-Output ('CAP1|' + `$r.reached.ToString() + '|' + `$r.unlimited.ToString() + '|' + `$r.cap.ToString() + '|' + `$r.daily.ToString() + '|' + `$r.reason)
"@) | Out-Null
        $outCap = ($psCap.Invoke() | Out-String).Trim()
        $psCap.Dispose()
        $partsCap = $outCap -split '\|'
        # [跨零点修正 2026-09-29 00:0x] 原断言假设"当日计数必然 ≥ 1"，**零点后不成立**
        #   （实测 00:0x 当日计数归零 ⇒ cap=1 时 reached=False，两条断言假红）。
        #   新判据是**恒真等式**：`reached 必须等于 (当日计数 ≥ cap)`，且 cap 生效时 reason 不能是 UNLIMITED。
        #   这样既跨零点稳定，又仍然证明"闸是活的、只是被取消成 0 而不是被拆掉"。
        $capDaily = [int]$partsCap[4]
        Assert-Eq    "G12-cap1-line-shape"      ([string]$partsCap[0]) 'CAP1'
        Assert-True  "G12-cap1-blocks"          ([string]$partsCap[1] -eq ([string]($capDaily -ge 1)))
        Assert-False "G12-cap1-not-unlimited"   ([string]$partsCap[2] -eq 'True')
        Assert-Eq    "G12-cap1-value"           ([int]$partsCap[3]) 1
        Assert-True  "G12-cap1-reason"          $(if ($capDaily -ge 1) { [string]$partsCap[5] -eq 'DAILY_CAP' } else { [string]$partsCap[5] -ne 'UNLIMITED' })
    }
} finally {
    if ($oldCfgCap) { [System.IO.File]::WriteAllText($cfgFileCap, $oldCfgCap, (New-Object System.Text.UTF8Encoding($false))) }
}
# 恢复后复核:现役配置必须**逐字**回到 0 = 不限(测试不许把老板的决定改坏)
$cfgCapAfter = (Get-Content $cfgFileCap -Raw -Encoding UTF8 | ConvertFrom-Json)
Assert-Eq "G12-config-restored-daily-cap-0" ([int]$cfgCapAfter.gonghai_daily_cap) 0

# ---- 用例 13:[FIX-ALREADYOPEN / FIX-FAILCLOSED] 2026-09-27 20:03 事故回归 ----
# 事故:批次3 的 6/10 条发送返回 `OPEN_FAIL (NOT_FOUND)` —— 搜索正常、cardId 也精确匹配,
#   坏在 `send.ps1` 第 1 步"在 .contact-item-container 里按名字再找一次人";实测那条列表会**冻结**
#   (新认领的客户不在里面)。同时暴露 batch 的身份核对是 **fail-open**(cardId 读不到时也打印"核对通过")。
$batchSrcTxt2 = [System.IO.File]::ReadAllText((Join-Path $scripts "gonghai\gonghai_batch.ps1"))
$sendSrcTxt   = [System.IO.File]::ReadAllText((Join-Path $scripts "lib\send.ps1"))
$libSrcTxt    = [System.IO.File]::ReadAllText((Join-Path $scripts "gonghai\gonghai_lib.ps1"))
# ① 公海发送必须走**唯一窗口**且带 `-AlreadyOpen`(不许再依赖会冻结的列表查找)
Assert-Match "G13-lib-send-alreadyopen"  $libSrcTxt 'Send-OneTalkMessage[^\r\n]*-AlreadyOpen'
Assert-Match "G13-batch-delegates-window" $batchSrcTxt2 'Invoke-GonghaiSendWindow'
Assert-Match "G13-probe-delegates-window" $probeSrcTxt  'Invoke-GonghaiSendWindow'
# ② 身份核对必须 fail-closed:读不到 customerId 时**不得**走到发送(fail-open 的写法要被结构性排除)
Assert-Match "G13-lib-no-cardid-branch"   $libSrcTxt "verdict = 'NO_CARDID'"
Assert-Match "G13-batch-handles-no-cardid" $batchSrcTxt2 "'NO_CARDID'"
#   ⚠️ 只扫**代码行**:注释里会引用旧判据来讲事故成因,不能因此假红
$libCodeLines = @(($libSrcTxt -split "\r?\n") | Where-Object { $_ -notmatch '^\s*#' })
Assert-False "G13-lib-no-failopen-cardid" (($libCodeLines -join "`n") -match '\$open\.cardId\s+-and\s+\$open\.cardId\s+-ne')
# ③ send.ps1 的开关必须"缺省即旧行为"(monitor 一行不改),且只包住第 1 步
Assert-Match "G13-send-has-alreadyopen-switch" $sendSrcTxt '\[switch\]\$AlreadyOpen'
Assert-Match "G13-send-guards-open-step"       $sendSrcTxt 'if \(-not \$AlreadyOpen\)'
# ④ 第 2 步的会话名核对**必须留着**(跳过第 1 步不等于不设防)
Assert-Match "G13-send-keeps-name-check"       $sendSrcTxt 'ABORT_WRONG_CONVO \(expected='

# ---- 用例 14:[FIX-MULTI-RESULT] 搜索结果多条时"按 customerId 挑对的人" ----
# 事故:客户名就叫 "User name"(公海显示名),OneTalk 搜索返回 **3 条**;旧实现只点第 1 条 ⇒
#   cardId 不等于公海 key ⇒ 6 轮重试全废,人已认领走却永远发不出去(gh-fbc008e4)。
$libSrcTxt = [System.IO.File]::ReadAllText((Join-Path $scripts "gonghai\gonghai_lib.ps1"))
Assert-Match "G14-lib-has-expectedkey-param" $libSrcTxt '\[string\]\$ExpectedKey\s*=\s*""'
Assert-Match "G14-lib-bounded-tries"         $libSrcTxt '\[int\]\$MaxTry\s*=\s*3'
# 挑人这一步在 lib 里:唯一窗口必须把 ExpectedKey 传给 Open-GonghaiSearchResult
Assert-Match "G14-lib-passes-expectedkey"    $libSrcTxt 'Open-GonghaiSearchResult\s+-ExpectedKey\s+\$ExpectedKey'
# 两个入口把 key 交给窗口(而不是各自去开结果)
Assert-Match "G14-batch-passes-key-to-window" $batchSrcTxt2 'Invoke-GonghaiSendWindow[^\r\n]*-ExpectedKey\s+\$c\.key'
Assert-Match "G14-probe-passes-key-to-window" $probeSrcTxt  'Invoke-GonghaiSendWindow[^\r\n]*-ExpectedKey\s+\$c\.key'
# 挑选判据必须是**严格相等**(不许"包含/前缀"这类宽容匹配 —— 那正是发错人的入口)
Assert-Match "G14-strict-equality"           $libSrcTxt 'toLowerCase\(\) === want'
# 旧语义必须保留:不传 -ExpectedKey ⇒ 只看第 1 条(不许静默改变没人复核过的行为)
Assert-Match "G14-default-keeps-first-only"  $libSrcTxt 'var max = want \? Math\.min\(items\.length, maxTry\) : 1;'

# ---- 用例 15:输出拼接必须加括号(PowerShell 参数模式坑) ----
# 事故:`Say "       send: " + ($W.send -replace ...)` 在**参数模式**下被解析成三个参数
#   ⇒ Say 只收到第一段字符串,发送返回串**静默消失**(实测 2026-09-27 批次6 打出空的 `send:`)。
#   状态/账本都是对的 ⇒ 这种缺陷不会被任何行为断言抓到,只能静态扫。
$argModeHits = @()
foreach ($f in @($batchPath, $probePath, $libPath)) {
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        $ln++
        if ($line -match '^\s*#') { continue }
        if ($line -match '\b(Say|Write-Output)\s+"[^"]*"\s*\+') {
            $argModeHits += ([System.IO.Path]::GetFileName($f) + ":" + $ln)
        }
    }
}
Assert-Eq "G15-no-argument-mode-plus-in-output (got $($argModeHits -join ','))" $argModeHits.Count 0

# ---- 用例 16:[2026-09-27 收敛] 模块闸真的会拦 ----
# 此前 spec 判定链第 1 步(`disabled` 标记 / `gonghai_enabled`)**没有任何脚本读它** ⇒
# 这里用真标记文件把"能拦住"钉死(测完删除,绝不留标记)。
$runNow = Test-GonghaiRunnable
Assert-True "G16-live-module-runnable" ([bool]$runNow.ok)
Assert-Eq   "G16-live-module-reason" ([string]$runNow.reason) 'OK'
$markerPath = Get-GonghaiPath "disabled"
$hadMarker = Test-Path $markerPath
try {
    if (-not $hadMarker) { Set-Content -Path $markerPath -Value 'unit-test' -Encoding ASCII }
    $rBlocked = Test-GonghaiRunnable
    Assert-False "G16-disabled-marker-blocks" ([bool]$rBlocked.ok)
    Assert-Eq    "G16-disabled-marker-reason" ([string]$rBlocked.reason) 'DISABLED_MARKER'
} finally {
    if (-not $hadMarker -and (Test-Path $markerPath)) { Remove-Item $markerPath -Force }
}
# 两个入口都必须调它(否则闸形同虚设)
Assert-Match "G16-batch-calls-module-gate" $batchSrcTxt2 'Test-GonghaiRunnable'
Assert-Match "G16-probe-calls-module-gate" $probeSrcTxt  'Test-GonghaiRunnable'

# ---- 用例 17:[2026-09-27 收敛] 待办队列(入队/幂等/出队) ----
# 为什么必须测:这是"认领了却没发成功"的人**唯一的归宿**(认领不可逆、公海列表里已消失)。
$pendPath = Get-GonghaiPath "pending.json"
$pendBackup = $null
if (Test-Path $pendPath) { $pendBackup = [System.IO.File]::ReadAllText($pendPath) }
try {
    $k1 = 'PENDKEY000000000000000000000001'
    $k2 = 'PENDKEY000000000000000000000002'
    $n0 = @(Get-GonghaiPendingList).Count
    Add-GonghaiPending -CustomerKey $k1 -Name 'Stub Buyer One' -Code 'gh-pend0001' -Reason 'INDEX_NOT_SYNCED'
    $l1 = @(Get-GonghaiPendingList)
    Assert-Eq "G17-enqueue-adds-one" $l1.Count ($n0 + 1)
    $e1 = @($l1 | Where-Object { $_.key -eq $k1 })[0]
    Assert-Eq "G17-enqueue-keeps-name"   ([string]$e1.name) 'Stub Buyer One'
    Assert-Eq "G17-enqueue-keeps-reason" ([string]$e1.reason) 'INDEX_NOT_SYNCED'
    Assert-Eq "G17-enqueue-tries-1"      ([int]$e1.tries) 1
    # 幂等 upsert:同一 key 再入队不产生第二行,只把 tries +1 并更新原因
    Add-GonghaiPending -CustomerKey $k1 -Name 'Stub Buyer One' -Code 'gh-pend0001' -Reason 'NO_CARDID'
    $l2 = @(Get-GonghaiPendingList)
    Assert-Eq "G17-upsert-no-duplicate" $l2.Count $l1.Count
    $e2 = @($l2 | Where-Object { $_.key -eq $k1 })[0]
    Assert-Eq "G17-upsert-bumps-tries"   ([int]$e2.tries) 2
    Assert-Eq "G17-upsert-updates-reason" ([string]$e2.reason) 'NO_CARDID'
    # 出队
    Remove-GonghaiPending -CustomerKey $k1
    $l3 = @(Get-GonghaiPendingList)
    Assert-Eq "G17-dequeue-removes" (@($l3 | Where-Object { $_.key -eq $k1 }).Count) 0
    Assert-Eq "G17-dequeue-back-to-baseline" $l3.Count $n0
    # 不存在的 key 出队不得报错、也不得改动队列
    Remove-GonghaiPending -CustomerKey 'PENDKEY999999999999999999999999'
    Assert-Eq "G17-dequeue-missing-is-noop" (@(Get-GonghaiPendingList).Count) $n0
    # 两条独立 key 必须各自成行
    Add-GonghaiPending -CustomerKey $k1 -Name 'A' -Code 'gh-pend0001' -Reason 'NOTSENT'
    Add-GonghaiPending -CustomerKey $k2 -Name 'B' -Code 'gh-pend0002' -Reason 'NOTSENT'
    Assert-Eq "G17-two-entries" (@(Get-GonghaiPendingList).Count) ($n0 + 2)
} finally {
    if ($null -ne $pendBackup) { [System.IO.File]::WriteAllText($pendPath, $pendBackup, (New-Object System.Text.UTF8Encoding($false))) }
    elseif (Test-Path $pendPath) { Remove-Item $pendPath -Force -ErrorAction SilentlyContinue }
}
# 还原后:真实队列必须原样(测试 key 不得留在里面)
Assert-Eq "G17-test-keys-cleaned" (@(Get-GonghaiPendingList) | Where-Object { $_.key -like 'PENDKEY*' }).Count 0

# ---- 用例 18:[GH-27] 公海列表页冻结 ⇒ 读列表必须能自愈 ----
# 事故:2026-09-27 23:30 第4批在读公海列表时 `CDP CMD TIMEOUT (Runtime.evaluate)` ⇒ 整批 exit 1、串联停机;
#   只读探针随后也读不出来(标签页还在,页面整个冻住)。旧实现 phase 0 读列表**没有任何重试**。
Assert-Match "G18-lib-has-resilient-read"  $libSrcTxt 'function Read-GonghaiPublicRows'
Assert-Match "G18-lib-has-page-repair"     $libSrcTxt 'function Repair-GonghaiPublicListPage'
Assert-Match "G18-lib-repair-reloads-page" $libSrcTxt 'GONGHAI-LIST-REPAIR reload public_customer'
Assert-Match "G18-lib-logs-readfail"       $libSrcTxt 'GONGHAI-LIST-READFAIL'
# batch 必须用带自愈的读法,且**不得**再有本地 Read-Rows 定义(单实现)
Assert-Match "G18-batch-uses-resilient-read" $batchSrcTxt2 'Read-GonghaiPublicRows -MaxTries'
Assert-False "G18-batch-no-local-read-rows"  ($batchSrcTxt2 -match '(?m)^function Read-Rows')
Assert-Match "G18-batch-handles-null-list"   $batchSrcTxt2 'ABORT 公海列表读不到'
# 认领点击的 CDP 超时不得打死整批:必须有 catch 兜住
Assert-Match "G18-batch-claim-has-catch"     $batchSrcTxt2 '认领异常\(页面可能冻结\)'

# ---- 用例 19:[GH-24/GH-28/GH-29] 连续跑入口 gonghai_loop.ps1 的三条纪律 ----
# 这三条都是 2026-09-27 深夜连跑时**真踩到**的:
#   GH-24 自匹配(判据把自己的命令行也算成批次) / GH-28 退出码不分级(可恢复故障也停) /
#   GH-29 数组解包(函数返回单元素数组 ⇒ `.Count` 是 $null ⇒ 并发闸静默失效)
$loopPath = Join-Path $scripts "gonghai\gonghai_loop.ps1"
Assert-True "G19-loop-exists" (Test-Path $loopPath)
if (Test-Path $loopPath) {
    $lb = [System.IO.File]::ReadAllBytes($loopPath)
    Assert-True "G19-loop-has-bom" ($lb.Length -ge 3 -and $lb[0] -eq 0xEF -and $lb[1] -eq 0xBB -and $lb[2] -eq 0xBF)
    $loopSrc = [System.IO.File]::ReadAllText($loopPath)
    # ① 并发闸:判据必须排除调用方自身(-Command),且调用处必须 @() 包裹防解包
    #    ⚠️ 用**字面量 Contains** 而不是正则:反斜杠/引号嵌套太深,正则容易写成假绿或假红。
    Assert-True "G19-guard-matches-file-flag" ($loopSrc.Contains("-File\s+\S*batch\.ps1"))
    Assert-True "G19-guard-excludes-command"  ($loopSrc.Contains("-notmatch '\-Command'"))
    Assert-True "G19-guard-wrapped-in-array"  ($loopSrc.Contains('@(Get-RealBatchProcesses).Count'))
    # ② 退出码分级:exit 1 可恢复重试;9/3/4/10 立即停
    Assert-Match "G19-retry-on-exit1"         $loopSrc 'if \(\$code -eq 1\)'
    Assert-Match "G19-stop-on-risk-exit9"     $loopSrc '9=风控'
    Assert-Match "G19-max-recoverable-retry"  $loopSrc '\$MaxRecoverableRetry'
    # ③ 目标读"当天"计数(跨零点自动按新一天算)
    Assert-Match "G19-reads-day-count"        $loopSrc 'day_count'
    # ④ 单例锁 + 静默窗口(两条链路交接时防并发:进程判据只看一眼会撞进对方 ~3 秒的批间空档)
    Assert-True "G19-has-singleton-lock"       ($loopSrc.Contains("Get-AppLock `$LockName 0"))
    Assert-True "G19-releases-lock-in-finally" ($loopSrc.Contains("Release-AppLock `$LockName"))
    Assert-True "G19-has-quiet-window"         ($loopSrc.Contains('$QuietSec'))
    Assert-True "G19-quiet-window-resets"      ($loopSrc.Contains('$quiet = 0'))
    # ⑤ 待办队列定期补发("认领了却发不出去"的人要有人管;按**入队年龄**筛,避免刚失败就狂重试)
    Assert-True "G19-drains-pending"           ($loopSrc.Contains('-RetryPending -CustomerId'))
    Assert-True "G19-drain-has-age-filter"     ($loopSrc.Contains('$DrainMinAgeHours'))
}


# ---- 用例 20:[GH-34] 公海首页"可用行缩水"必须能自愈 ----
# 事故:同一张列表页连续认领多轮后,可用行 10 → 9 → 8 → **6**（页面不自己刷新,被认领的行变空行）
#   ⇒ 每轮产能被动下降。修法:阶段0 发现"可用 < 请求批大小 且 < 10"就先刷新页再读一次。
Assert-True "G20-batch-refreshes-on-shrink"  ($batchSrcTxt2.Contains('本页可用仅'))
Assert-True "G20-batch-repairs-then-rereads" ($batchSrcTxt2.Contains('Repair-GonghaiPublicListPage -WaitSec 12'))
Assert-True "G20-batch-only-adopts-if-better" ($batchSrcTxt2.Contains('刷新后可用 = '))
Assert-True "G20-batch-keeps-original-on-no-gain" ($batchSrcTxt2.Contains('保持原样继续'))
Write-Output ""
# ---- 用例 21:[GH-34c] 池子首页人不够时必须能**翻页**取新鲜行 ----
# 事故:第 1 页 10 行里 4 行空行(不是我们认领的),刷新/关页重开都救不回人数 ⇒ 每轮只拿 6 个。
# 正解:翻下一页。实测第 8 轮 `翻页后可用 = 10 行(已采用)` ⇒ 产能 6 → 10。
$libSrcLoop = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G21-lib-has-pager"        ($libSrcLoop.Contains('function Move-GonghaiPublicListPage'))
Assert-True "G21-pager-uses-ant-next"  ($libSrcLoop.Contains(".ant-pagination-next"))
Assert-True "G21-pager-detects-disabled" ($libSrcLoop.Contains("ant-pagination-disabled"))
Assert-True "G21-batch-tries-pager-first" ($batchSrcTxt2.Contains('Move-GonghaiPublicListPage -Direction next'))
Assert-True "G21-batch-pager-before-repair" ($batchSrcTxt2.IndexOf('Move-GonghaiPublicListPage -Direction next') -lt $batchSrcTxt2.IndexOf('Repair-GonghaiPublicListPage -WaitSec 12'))
Assert-True "G21-batch-adopts-only-if-better" ($batchSrcTxt2.Contains('已采用（可用 = ') -and $batchSrcTxt2.Contains('$poolP.Count -gt $pool.Count'))   # [GH-52] 文案改为"翻到下一页面/已采用",但"只有确实更多才采用"的判据不变
# ---- 用例 22:[GH-32/GH-35] 日志写入必须"永不拖垮生产" ----
# 两次真实故障:① 独占读把生产写挡住(丢过 1 行) ② Stream was not readable。
# 纪律:Write-SkillLog 必须有重试 + fallback + 永不抛。
$logSrc = [System.IO.File]::ReadAllText((Join-Path $scripts 'lib\log.ps1'))
Assert-True "G22-log-has-retry"        ($logSrc.Contains('重试一次'))
Assert-True "G22-log-has-fallback"     ($logSrc.Contains('.fallback.log'))
Assert-True "G22-log-never-throws"     ($logSrc.Contains('-ErrorAction Stop'))
Assert-True "G22-log-closes-with-catch" ($logSrc.Contains('Add-Content -Path $fb'))
# ---- 用例 23:[GH-39] 搜索不可用时**不许认领**(救命闸) ----
# 事故:OneTalk 数据面断开 ⇒ 搜索对所有人返回 0 ⇒ 批次照样认领 9-10 人、一个也发不出去 ⇒ 待办冲到 60+。
$libSrc2 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G23-lib-has-search-gate"    ($libSrc2.Contains('function Test-GonghaiSearchUsable'))
Assert-True "G23-gate-banner-informational-only" ($libSrc2.Contains('横幅只作参考、不作判据'))
Assert-True "G23-gate-smoke-search"      ($libSrc2.Contains('smoke-zero'))
Assert-True "G23-batch-calls-gate"       ($batchSrcTxt2.Contains('Test-GonghaiSearchUsable'))
Assert-True "G23-batch-aborts-search-down" ($batchSrcTxt2.Contains('GONGHAI-SEARCH-DOWN'))
Assert-True "G23-gate-before-claim"      ($batchSrcTxt2.IndexOf('Test-GonghaiSearchUsable') -lt $batchSrcTxt2.IndexOf('阶段1：认领'))
# ---- 用例 24:[GH-41] "搜索全 0"必须能自愈:重建 OneTalk 客户端页 ----
# 事故:OneTalk web 客户端页卡成空壳(监控实例 bodyLen 仅 128) ⇒ 搜索对所有人返回 0,持续 45 分钟。
# 实测唯一有效修法 = 关页重开(重登/重启 Chrome/刷新都无效)。
$libSrc3 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G24-lib-has-onetalk-rebuild" ($libSrc3.Contains('function Repair-GonghaiOnetalkTab'))
Assert-True "G24-rebuild-closes-page"     ($libSrc3.Contains('Close-GonghaiPage -Page $page'))
Assert-True "G24-rebuild-opens-new"       ($libSrc3.Contains('New-GonghaiOnetalkTab'))
Assert-True "G24-batch-self-heals"        ($batchSrcTxt2.Contains('Repair-GonghaiOnetalkTab'))
Assert-True "G24-batch-rechecks-gate"     ($batchSrcTxt2.Contains('重建后搜索已恢复'))
# ---- 用例 25:[GH-42] 搜索前必须先清空输入框(否则关键词被拼坏 ⇒ 假"索引未同步") ----
$libSrc4 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G25-search-clears-first"   ($libSrc4.Contains("setter.call(inp, '')"))
Assert-True "G25-search-reports-mismatch" ($libSrc4.Contains('mismatch:'))
Assert-True "G25-search-reports-value"  ($libSrc4.Contains('value: v'))
# ---- 用例 26:[GH-44] 中断时必须把"已认领未发送"的人全部入队 ----
# 事故:三轮 ABORT_WRONG_CONVO 停机,只入队了"索引未同步"那 1 个,其余 9-10 个直接丢失(只能事后人工反查)。
Assert-True "G26-batch-has-abort-backfill" ($batchSrcTxt2.Contains('GH-44'))
Assert-True "G26-backfill-reason"          ($batchSrcTxt2.Contains('LOST_AFTER_ABORT'))
Assert-True "G26-tracks-sent-keys"         ($batchSrcTxt2.Contains('$sentKeys'))
Assert-True "G26-backfill-adds-pending"    ($batchSrcTxt2.Contains('Add-GonghaiPending -CustomerKey $c.key -Name $c.name'))
Assert-False "G26-no-undefined-script-abort" ($batchSrcTxt2 -match '-and\s+\$script:Abort')   # 只匹配**代码形态**;注释里提到该变量名不算(上一版就因此假报警)
# ---- 用例 27:[GH-45] 待办补发必须**轮转**(按最久没试过优先),不能反复挑同几个 ----
$libSrc5 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
$loopSrc2 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_loop.ps1'))
Assert-True "G27-lib-projects-updated-at" ($libSrc5.Contains('updated_at = $(if ($v.updated_at)'))
Assert-True "G27-drain-sorts-by-updated"  ($loopSrc2.Contains('Sort-Object updated_at, added_at'))
# ---- 用例 28:[GH-48/GH-49] WRONG_CONVO 不再掐整轮 + 搜索闸必须有负对照 ----
$batchSrcTxt3 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_batch.ps1'))
$libSrc6 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G28-wrong-convo-not-round-fatal" (-not ($batchSrcTxt3 -match "(?s)'WRONG_CONVO'.{0,900}?\`$abort = \`$true"))
Assert-True "G28-wrong-convo-enqueues"        ($batchSrcTxt3.Contains('Reason ''WRONG_CONVO'''))
Assert-True "G28-still-aborts-on-lock-busy"   ($batchSrcTxt3.Contains("'LOCK_BUSY'"))
Assert-True "G28-gate-has-negative-control"   ($libSrc6.Contains("Invoke-OneTalkSearch -Keyword 'zzqx'"))
Assert-True "G28-gate-detects-stale-panel"    ($libSrc6.Contains('search-stale-panel'))
# ---- 用例 29:[GH-50] 会话名校验必须归一化(不可见字符不能把真客户挡死) ----
$sendSrc = [System.IO.File]::ReadAllText((Join-Path $scripts 'lib\send.ps1'))
Assert-True "G29-send-normalizes-name"   ($sendSrc.Contains('U+200B') -or $sendSrc.Contains('\u200B'))
Assert-True "G29-send-uses-norm-vars"    ($sendSrc.Contains('$nB') -and $sendSrc.Contains('$nC'))
Assert-True "G29-send-keeps-strong-key"  ($sendSrc.Contains('$curKey -eq $key'))
Assert-True "G29-send-keeps-verbatim-message" ($sendSrc.Contains('ABORT_WRONG_CONVO (expected=$buyer, current=$current)'))   # 逐字契约(测试 send_page_param 钉的)不能被诊断信息破坏
# ---- 用例 30:[GH-52] 池子首页 0 行时必须先翻页,不能直接判死 ----
$batchSrcTxt4 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_batch.ps1'))
Assert-True "G30-zero-check-after-heal"  ($batchSrcTxt4.IndexOf('三级自愈(由轻到重)') -lt $batchSrcTxt4.IndexOf('GH-52] 三级自愈跑完仍是 0 行'))
Assert-True "G30-multi-page-loop"        ($batchSrcTxt4.Contains('$maxPages = 3'))
Assert-True "G30-logs-pool-empty"        ($batchSrcTxt4.Contains('GONGHAI-POOL-EMPTY'))
# ---- 用例 31:[GH-53] 风控命中必须**以 exit 9 结束批次**(否则 loop 不会停) ----
# 事故:发送阶段风控命中只写了 `$abort = $true; break` ⇒ 批次 exit 0 ⇒ loop 以为成功、继续开新批次,
#   在风控持续命中时每 3 分钟认领一批(队列 122→149)。老板的硬要求是"风控命中即停机"。
$batchSrcTxt5 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_batch.ps1'))
Assert-True "G31-send-risk-sets-flag"   ($batchSrcTxt5.Contains('$abort = $true; $riskAbort = $true; break'))
Assert-True "G31-flag-initialized"      ($batchSrcTxt5.Contains('$riskAbort = $false'))
Assert-True "G31-exits-9-at-end"        ($batchSrcTxt5.Contains('if ($riskAbort) {'))
Assert-True "G31-two-exit9-paths"       (([regex]::Matches($batchSrcTxt5,'exit 9')).Count -ge 2)
Assert-True "G31-logs-stop"             ($batchSrcTxt5.Contains('GONGHAI-RISK-STOP-EXIT9'))
# ---- 用例 32:[GH-54] 风控探针不得扫描客户消息区(英文 "risk" 曾把整条链停掉) ----
$libSrc7 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
# ⚠️ 只查**代码**、不查注释:实现里保留了旧词表的注释(说明为什么删),那是文档不是行为。
Assert-True "G32-risk-no-body-scan"      (-not ($libSrc7 -match 'if \(t\.indexOf\(k\) >= 0\)'))   # 不再对 body 全文匹配
Assert-True "G32-risk-no-bare-english"   (-not ($libSrc7 -match "var t = \(document\.body"))
Assert-True "G32-risk-scoped-to-dialog"  ($libSrc7.Contains('scope.indexOf(k)'))
Assert-True "G32-risk-node-selector"     ($libSrc7.Contains('[class*=baxia]'))
Assert-True "G32-risk-keeps-cn-phrases"  ($libSrc7.Contains('操作过于频繁'))
# ---- 用例 33:[GH-55] 定期补发只挑"值得补"的原因类别(无索引类实测 0% 收益,不许再盲轮转) ----
$loopSrc3 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_loop.ps1'))
Assert-True "G33-drain-reason-filter"    ($loopSrc3.Contains('$drainReasons -contains $_.reason'))
Assert-True "G33-drain-excludes-nosync"  (-not ($loopSrc3 -match '\$drainReasons\s*=\s*@\([^)]*INDEX_NOT_SYNCED'))
Assert-True "G33-drain-has-four-reasons" ($loopSrc3.Contains("'LOST_AFTER_ABORT', 'WRONG_CONVO', 'NOTSENT', 'NO_CARDID'"))
Assert-True "G33-drain-derives-code"     ($loopSrc3.Contains("Get-GonghaiHash8 `$pd.key"))
# ---- 用例 34:[GH-58] 补发失败计数必须**跨轮累计**(写进轮内会被每轮清零,等于没加) ----
$loopSrc4 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_loop.ps1'))
Assert-True "G34-failcount-init-once"   (([regex]::Matches($loopSrc4, '(?m)^\s*\$drainFailCount = @\{\}')).Count -eq 1)
Assert-True "G34-failcount-cross-round" ($loopSrc4.Contains('$drainFailCount[$pd.key] = ([int]$drainFailCount[$pd.key] + 1)'))
Assert-True "G34-failcount-clears"      ($loopSrc4.Contains('$drainFailCount.Remove($pd.key)'))
Assert-True "G34-filter-uses-failcount" ($loopSrc4.Contains('([int]$drainFailCount[$_.key] -lt $drainMaxTries)'))
Assert-True "G34-recoverfails-intact"   ($loopSrc4 -match '(?m)^\$recoverFails = 0')
Assert-True "G34-no-tries-cap"          (-not $loopSrc4.Contains('$_.tries -lt $drainMaxTries'))
# ---- 用例 35:[GH-62] 风控探针的"通用弹窗"分支必须排除加载遮罩(mask/loading) ----
$libSrc8 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_lib.ps1'))
Assert-True "G35-risk-excludes-mask"    ($libSrc8.Contains('/loading|mask/i.test(cls)'))
Assert-True "G35-risk-generic-needs-text" ($libSrc8.Contains("var t = (e.innerText || '').trim();"))
Assert-True "G35-risk-true-selector-sep" ($libSrc8.Contains("var trueSel = '#baxia-dialog-content"))
Assert-True "G35-risk-true-nodes-counted" ($libSrc8.Contains('document.querySelectorAll(trueSel).length'))
# ---- 用例 36:[GH-63] 翻页自愈后必须"以当前显示页为准",否则认领会全线 ROW_GONE ----
$batchSrcTxt6 = [System.IO.File]::ReadAllText((Join-Path $scripts 'gonghai\gonghai_batch.ps1'))
Assert-True "G36-realign-to-current-view" ($batchSrcTxt6.Contains('[GH-63] 以**当前显示页**为准'))
Assert-True "G36-realign-rereads-rows"     ($batchSrcTxt6.Contains('$rowsNow = Read-GonghaiPublicRows'))
Assert-True "G36-realign-adopts-nonempty"  ($batchSrcTxt6.Contains('if ($poolNow.Count -ge 1)'))
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
