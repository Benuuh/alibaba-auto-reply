# gonghai_chrome_isolation.tests.ps1 — [SPEC-公海独立Chrome 2026-09-27] 公海独立 Chrome(9225)隔离
#
# 本文件取代 tests\gonghai_page_isolation.tests.ps1(那份锁的是**已被 §2.2 撤销**的 URL 标记方案)。
# 覆盖 spec 的硬判据:
#   A(§2.1/§3.1) 配置:gonghai_cdp_port=9225(不是 9222)、gonghai_profile 独立、与 9222/9223/9224 都不撞;
#   B(§3.3)      公海取页 = "这个端口上的 OneTalk 页",**不含任何标记**;标记常量/函数必须已消失;
#   C(§3.4)      `Send-OneTalkMessage` 保留可选 `-Page`(公海发送落点)+ **端口闸**;不传时行为不变;
#   D(§3.2)      启动脚本:按 profile **精确匹配**(绝不裸杀 chrome / 绝不碰 9222);
#   E(§4-P1)     `Get-Page` 一个字都没改(函数体 SHA256 与基线一致 + 两处定义逐字一致);
#   F            `chrome_ensure.ps1` 对公海**零依赖**(标记方案那一块已撤销)。
#
# 设计原则:纯逻辑 + 读源码文本;**不联网、不开页、不发送**。
#
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\gonghai_chrome_isolation.tests.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"

. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\log.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
. (Join-Path $scripts "reply_engine.ps1")
. (Join-Path $scripts "lib\send.ps1")
. (Join-Path $scripts "gonghai\gonghai_cdp.ps1")
. (Join-Path $scripts "gonghai\gonghai_lib.ps1")

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-True([string]$name, [bool]$cond) {
    if ($cond) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name" }
}
function Assert-False([string]$name, [bool]$cond) { Assert-True $name (-not $cond) }
function Assert-Eq([string]$name, [object]$a, [object]$b) {
    if ($a -eq $b) { $script:pass++ }
    else { $script:fail++; [void]$script:fails.Add($name); Write-Output "  FAIL: $name | got: [$a] | want: [$b]" }
}
function Get-Sha256Hex([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))) -replace '-', '') }
    finally { $sha.Dispose() }
}
# 抽取 `function <Name> {` 起、到首个顶格 `}` 止的函数体(注释保留)
function Get-FnText([string]$path, [string]$name) {
    $lines = [System.IO.File]::ReadAllLines($path)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ('^function ' + [regex]::Escape($name) + '\s*[\(\{]')) { $start = $i; break } }
    if ($start -lt 0) { return $null }
    $acc = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $lines.Count; $i++) {
        [void]$acc.Add($lines[$i])
        if ($i -gt $start -and $lines[$i] -eq '}') { break }
    }
    return (@($acc) -join "`n")
}
# 去注释后的源码(代码级断言用,避免被注释里的示例误导)
function Get-CodeOnly([string]$path) {
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    return (@($lines | Where-Object { $_ -notmatch '^\s*#' } | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n")
}

Write-Output "== gonghai_chrome_isolation tests =="

$ghCdpPath   = Join-Path $scripts "gonghai\gonghai_cdp.ps1"
$ghLibPath   = Join-Path $scripts "gonghai\gonghai_lib.ps1"
$ghEnsPath   = Join-Path $scripts "gonghai\gonghai_ensure.ps1"
$probePath   = Join-Path $scripts "gonghai\gonghai_probe.ps1"
$sendPath    = Join-Path $scripts "lib\send.ps1"
$libCdpPath  = Join-Path $scripts "lib\cdp.ps1"
$rootCdpPath = Join-Path $scripts "cdp.ps1"
$chromPath   = Join-Path $scripts "chrome_ensure.ps1"

# ===========================================================================
# E/§4-P1 —— Get-Page 一个字都不许改(硬门禁)
#   基线 SHA256 由上一版 spec 的规划会话留证(2026-09-27),本 spec §4-P1 要求它**逐字不变**。
# ===========================================================================
$BASELINE_GETPAGE_BODY_SHA = 'DF15A58F83BEBC7EE71BFD783611013B8920F4B466F3AFB3E77D34B7F088C5F9'

function Get-PageFnCode([string]$path) {
    $lines = [System.IO.File]::ReadAllLines($path)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^function Get-Page\s*\{') { $start = $i; break } }
    if ($start -lt 0) { return $null }
    $acc = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $lines.Count; $i++) {
        [void]$acc.Add(($lines[$i] -replace '#.*$', '').Trim())
        if ($lines[$i] -eq '}') { break }
    }
    return (@($acc | Where-Object { $_ }) -join "`n")
}
$libGetPageBody = Get-PageFnCode $libCdpPath
$rootGetPageBody = Get-PageFnCode $rootCdpPath
Assert-True "P1-lib-defines-get-page" ($null -ne $libGetPageBody)
Assert-True "P1-root-defines-get-page" ($null -ne $rootGetPageBody)
Assert-Eq "P1-get-page-body-sha256-unchanged" (Get-Sha256Hex $libGetPageBody) $BASELINE_GETPAGE_BODY_SHA
Assert-Eq "P1-two-definitions-identical" $libGetPageBody $rootGetPageBody
Assert-True "P1-still-selects-first-onetalk" ($libGetPageBody -match "url -match 'onetalk\\\.alibaba\\\.com'")
Assert-True "P1-still-returns-null-when-none" ($libGetPageBody -match 'return \$null')

# §4-P2 —— Invoke-CdpEval 的空守卫契约逐字不变 + 仍然只走共用端口
$libCdpSrc = Get-Content $libCdpPath -Raw
Assert-True "P2-cdpeval-guard-contract-intact" ($libCdpSrc -match 'return "CMD ERROR: no onetalk page found \(url guard\)"')
$evalFn = Get-FnText $libCdpPath 'Invoke-CdpEval'
Assert-True "P2-eval-still-uses-get-page" ($evalFn -match '\$page = Get-Page')
# ⚠️ Test-CdpReady 加了可选 -Port,但**不传时**必须仍取 config 的 cdp_port(=9222)
$readyFn = Get-FnText $libCdpPath 'Test-CdpReady'
Assert-True "P2-cdpready-default-still-config-port" ($readyFn -match 'Get-CdpPort')
Assert-True "P2-cdpready-opt-in-port" ($readyFn -match '\$Port -gt 0')

# ===========================================================================
# A/§2.1 §3.1 —— 配置:9225 + 独立 profile
# ===========================================================================
$cfgEx = Get-Content (Join-Path $scripts 'config.json.example') -Raw -Encoding UTF8 | ConvertFrom-Json
$cfgLv = Get-Content (Join-Path $scripts 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

Assert-Eq "A-example-port-9225" ([int]$cfgEx.gonghai_cdp_port) 9225
Assert-Eq "A-live-port-9225"    ([int]$cfgLv.gonghai_cdp_port) 9225
# ⚠️ 这是本 spec 的**核心回归点**:上一版配置里 gonghai_cdp_port 就是 9222(和自动回复共用)
Assert-True "A-example-port-not-shared" ([int]$cfgEx.gonghai_cdp_port -ne [int]$cfgEx.cdp_port)
Assert-True "A-live-port-not-shared"    ([int]$cfgLv.gonghai_cdp_port -ne [int]$cfgLv.cdp_port)

$exNames = @($cfgEx.PSObject.Properties.Name)
$lvNames = @($cfgLv.PSObject.Properties.Name)
Assert-True "A-example-has-gonghai_profile" ($exNames -contains 'gonghai_profile')
Assert-True "A-live-has-gonghai_profile"    ($lvNames -contains 'gonghai_profile')
Assert-True "A-example-profile-nonempty"    (-not [string]::IsNullOrWhiteSpace([string]$cfgEx.gonghai_profile))
Assert-True "A-live-profile-nonempty"       (-not [string]::IsNullOrWhiteSpace([string]$cfgLv.gonghai_profile))
# 四个实例的 profile 必须两两不同(共用 profile ⇒ 同一个 Chrome 进程 ⇒ 白做)
$profiles = @([string]$cfgLv.chrome_profile, [string]$cfgLv.okki_profile, [string]$cfgLv.waimao_profile, [string]$cfgLv.gonghai_profile)
Assert-Eq "A-four-distinct-profiles" (@($profiles | Sort-Object -Unique).Count) 4
# 四个端口必须两两不同
$ports = @([int]$cfgLv.cdp_port, [int]$cfgLv.okki_cdp_port, [int]$cfgLv.waimao_cdp_port, [int]$cfgLv.gonghai_cdp_port)
Assert-Eq "A-four-distinct-ports" (@($ports | Sort-Object -Unique).Count) 4
Assert-True "A-gonghai-profile-name"     ([string]$cfgLv.gonghai_profile -match 'chrome-profile-gonghai$')
Assert-True "A-gonghai-profile-not-monitor" ([string]$cfgLv.gonghai_profile -ne [string]$cfgLv.chrome_profile)

# ---- 端口权威来源:Get-GonghaiCdpPort 必须读 gonghai_cdp_port ----
Assert-Eq "A-cdp-port-fn-returns-9225" (Get-GonghaiCdpPort) 9225
Assert-Eq "A-config-port-9225"         ([int](Get-GonghaiConfig).port) 9225
$portFnCode = Get-FnText $ghCdpPath 'Get-GonghaiCdpPort'
Assert-True "A-port-fn-reads-config-key" ($portFnCode -match 'gonghai_cdp_port')
Assert-False "A-port-fn-no-fallback-to-shared" ($portFnCode -match 'return Get-CdpPort')

# ---- 9222 否决闸:配成共用端口必须**抛异常拒绝**(fail-closed) ----
Assert-True "A-guard-fn-exists" ($null -ne (Get-Command Assert-GonghaiNotSharedPort -EA SilentlyContinue))
$threw = $false
try { Assert-GonghaiNotSharedPort -Port 9222 } catch { $threw = $true }
Assert-True "A-guard-refuses-shared-port" $threw
$threw2 = $false
try { Assert-GonghaiNotSharedPort -Port 9225 } catch { $threw2 = $true }
Assert-False "A-guard-allows-own-port" $threw2

# ===========================================================================
# B/§2.2 §3.3 —— 标记方案已撤销 + 公海取页 = "这个端口上的 OneTalk 页"
# ===========================================================================
# B1:撤销的常量/函数必须**真的不存在**了(dot-source 后也取不到)
Assert-True "B-marker-constant-gone" ($null -eq $script:GonghaiTabMarker)
Assert-True "B-marker-pattern-constant-gone" ($null -eq $script:GonghaiOnetalkPattern)
foreach ($dead in @('Get-SendPageMarkerPattern', 'Test-SendPageOnGonghaiTab', 'Test-SendPageMarkerPatternNonEmpty', 'Read-SendCurrentConvoName', 'Test-SendPageConvoName')) {
    Assert-True ("B-send-symbol-gone-" + $dead) ($null -eq (Get-Command $dead -EA SilentlyContinue))
}

# B2:源码里不得再有 dshgh 的**代码**(注释里记录"已撤销"是允许的;这里查代码行)
foreach ($pair in @(@{ p = $ghCdpPath; n = 'gonghai_cdp.ps1' }, @{ p = $ghLibPath; n = 'gonghai_lib.ps1' },
                     @{ p = $probePath; n = 'gonghai_probe.ps1' }, @{ p = $ghEnsPath; n = 'gonghai_ensure.ps1' },
                     @{ p = $sendPath; n = 'lib\send.ps1' })) {
    $code = Get-CodeOnly $pair.p
    Assert-False ("B-no-marker-code-in-" + $pair.n) ($code -match 'dshgh')
    Assert-False ("B-no-marker-symbol-in-" + $pair.n) ($code -match 'GonghaiTabMarker|GonghaiOnetalkPattern')
}

# B3:公海匹配串 = 朴素域名(与 gonghai_cdp.ps1 的权威常量一致)
Assert-Eq "B-lib-urlmatch-is-plain-domain" (Get-GonghaiOnetalkUrlMatch) 'onetalk\.alibaba\.com'
Assert-Eq "B-authoritative-onetalk-pattern" $script:OnetalkUrlPattern 'onetalk\.alibaba\.com'
Assert-True "B-eval-fn-uses-plain-pattern" ((Get-FnText $ghLibPath 'Get-GonghaiOnetalkUrlMatch') -notmatch 'dshgh')

# B4:Get-GonghaiOnetalkUrl = 朴素基址 + hash 路由(不再拼标记)
$ghUrl = Get-GonghaiOnetalkUrl
Assert-True "B-onetalk-url-no-marker" ($ghUrl -notmatch 'dshgh')
Assert-True "B-onetalk-url-keeps-hash-route" ($ghUrl -match '#/$')
Assert-True "B-onetalk-url-starts-with-base" ($ghUrl.StartsWith($script:OnetalkBaseUrl))

# B5:Get-GonghaiOnetalkPage 用桩替换页清单(不碰真浏览器):
#    **取第一个 OneTalk 页**,不看任何标记
$script:StubPages = @()
function Get-GonghaiCdpPages { return $script:StubPages }

$monLikeUrl = 'https://onetalk.alibaba.com/message/weblitePWA.htm?activeAccountId=285965039#/'
$script:StubPages = @(
    [pscustomobject]@{ id = 'CRM';      type = 'page'; url = 'https://i.alibaba.com/hub/alicrm/public_customer'; webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/CRM' },
    [pscustomobject]@{ id = 'ONETALK';  type = 'page'; url = $monLikeUrl;                                      webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/ONETALK' }
)
$hit = Get-GonghaiOnetalkPage
Assert-True "B-picks-onetalk-page" ($null -ne $hit -and ([string]$hit.id).Trim() -eq 'ONETALK')

# 页面顺序无关:OneTalk 排在后面也必须命中它(而非取第一个 page)
$script:StubPages = @(
    [pscustomobject]@{ id = 'FIRST';    type = 'page'; url = 'https://example.com/x';   webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/FIRST' },
    [pscustomobject]@{ id = 'ONETALK2'; type = 'page'; url = $monLikeUrl;               webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/ONETALK2' }
)
$hit2 = Get-GonghaiOnetalkPage
Assert-True "B-order-independent" ($null -ne $hit2 -and ([string]$hit2.id).Trim() -eq 'ONETALK2')

# 没有 OneTalk 页 ⇒ $null(**不**随便给一个页)
$script:StubPages = @([pscustomobject]@{ id = 'CRM2'; type = 'page'; url = 'https://i.alibaba.com/hub/alicrm/public_customer'; webSocketDebuggerUrl = 'ws://x' })
Assert-True "B-no-onetalk-returns-null" ($null -eq (Get-GonghaiOnetalkPage))

# B6:建页/取页的端口来源必须是公海端口
$newTabCode = Get-FnText $ghCdpPath 'New-GonghaiOnetalkTab'
Assert-True "B-newtab-uses-gonghai-port" ($newTabCode -match 'Get-GonghaiCdpPort')
Assert-False "B-newtab-no-marker" ($newTabCode -match 'dshgh')
$ensureTabCode = Get-FnText $ghCdpPath 'Ensure-GonghaiOnetalkTab'
Assert-True "B-ensuretab-uses-onetalk-page" ($ensureTabCode -match 'Get-GonghaiOnetalkPage')
Assert-True "B-ensuretab-reopens-when-missing" ($ensureTabCode -match 'New-GonghaiOnetalkTab')

# B7:公海健康探针必须在**公海端口**上(不能拿 9222 的页当自己的判据)
Assert-True "B-health-probe-exists" ($null -ne (Get-Command Test-GonghaiPageHealth -EA SilentlyContinue))
$ghHealthCode = Get-FnText $ghCdpPath 'Test-GonghaiPageHealth'
Assert-True "B-health-probe-uses-gonghai-eval" ($ghHealthCode -match 'Invoke-GonghaiEval')
Assert-True "B-health-probe-reuses-verdict" ($ghHealthCode -match 'Get-PageHealthVerdict')
$probeSrc = Get-Content $probePath -Raw
Assert-True "B-probe-uses-gonghai-health" ($probeSrc -match 'Test-GonghaiPageHealth')
Assert-False "B-probe-no-longer-probes-shared-port" ((Get-CodeOnly $probePath) -match '\$health = Test-PageHealth')

# ===========================================================================
# C/§3.4 —— lib\send.ps1 可选 `-Page` + 端口闸
# ===========================================================================
Assert-True "C-send-has-page-param" (@((Get-Command Send-OneTalkMessage).Parameters.Keys) -contains 'Page')
Assert-True "C-send-core-has-page-param" (@((Get-Command Send-OneTalkMessageCore).Parameters.Keys) -contains 'Page')
Assert-True "C-core-exists" ($null -ne (Get-FnText $sendPath 'Send-OneTalkMessageCore'))

$coreCode = Get-FnText $sendPath 'Send-OneTalkMessageCore'
Assert-False "C-core-has-no-bare-invoke-cdpeval" ($coreCode -match 'Invoke-CdpEval')
Assert-Eq "C-core-routes-through-Invoke-SendEval" ([regex]::Matches($coreCode, 'Invoke-SendEval')).Count 3
# 端口闸必须存在,且必须在**任何求值之前**(否则会先点开一个会话再发现页不对)
$gatePos = $coreCode.IndexOf('Assert-SendPageNotSharedPort')
$openPos = $coreCode.IndexOf('$r1 = Invoke-SendEval')
Assert-True "C-port-gate-present" ($gatePos -ge 0)
Assert-True "C-port-gate-before-first-eval" ($gatePos -ge 0 -and $openPos -ge 0 -and $gatePos -lt $openPos)
Assert-True "C-port-gate-gated-on-Page" ($coreCode -match 'if \(\$Page\) \{ Assert-SendPageNotSharedPort')

$sendEvalCode = Get-FnText $sendPath 'Invoke-SendEval'
Assert-True "C-sendeval-falls-back-to-cdpeval" ($sendEvalCode -match 'return \(Invoke-CdpEval \$Js\)')
Assert-True "C-sendeval-uses-override-when-set" ($sendEvalCode -match 'Invoke-GonghaiEvalOnPage')
Assert-True "C-page-override-default-empty" ((Get-Content $sendPath -Raw) -match '\$script:SendPageOverride\s*=\s*\$null')
Assert-True "C-send-snapshots-and-restores-override" (((Get-Content $sendPath -Raw) -match '\$prevPage = \$script:SendPageOverride') -and ((Get-Content $sendPath -Raw) -match 'finally\s*\{\s*\$script:SendPageOverride = \$prevPage'))
# 端口闸自身:判据必须是"页的 ws 端口 == config 的 cdp_port ⇒ 拒绝"
$gateCode = Get-FnText $sendPath 'Assert-SendPageNotSharedPort'
Assert-True "C-gate-exists" ($null -ne $gateCode)
Assert-True "C-gate-compares-with-shared-port" ($gateCode -match 'Get-CdpPort')
Assert-True "C-gate-throws-abort-wrong-page" ($gateCode -match 'ABORT_WRONG_PAGE')
$wsPortCode = Get-FnText $sendPath 'Get-SendPageWsPort'
Assert-True "C-wsport-parses-ws-url" ($wsPortCode.Contains("ws://[^/]*:(\d+)/"))
# 纯函数行为断言(不经浏览器)
Assert-Eq "C-wsport-from-9222" (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9222/devtools/page/A' })) 9222
Assert-Eq "C-wsport-from-9225" (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/A' })) 9225
Assert-Eq "C-wsport-null-page" (Get-SendPageWsPort $null) 0
Assert-Eq "C-wsport-empty-ws" (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = '' })) 0
Assert-Eq "C-wsport-merged-tokens" (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9225/devtools/page/A ws://127.0.0.1:9225/devtools/page/B' })) 9225
Assert-Eq "C-wsport-garbage" (Get-SendPageWsPort ([pscustomobject]@{ webSocketDebuggerUrl = 'not-a-ws-url' })) 0

# §3.4-3 公海调用点必须传 -Page
#   [SYNC 2026-09-27 收敛] 发送窗口整体移入 gonghai_lib.ps1(batch/probe 共用) ⇒ 这个调用点
#   现在在 lib 里;两个入口改为把 `-Page` 交给窗口。判据不变:**公海发送必须显式带 -Page**。
$probeSrc2 = Get-Content $probePath -Raw
$libSrc2   = Get-Content (Join-Path $scripts "gonghai\gonghai_lib.ps1") -Raw
Assert-True "C-lib-passes-page" ($libSrc2 -match 'Send-OneTalkMessage -buyer \$ExpectedName -text \$Text -Page \$Page -AlreadyOpen')
Assert-True "C-probe-delegates-window" ($probeSrc2 -match 'Invoke-GonghaiSendWindow[^\r\n]*-Page \$ghTab')
Assert-True "C-probe-obtains-tab" ($probeSrc2 -match 'Ensure-GonghaiOnetalkTab')
Assert-True "C-probe-aborts-when-no-tab" ($probeSrc2 -match 'NO_GONGHAI_TAB')
Assert-True "C-probe-catches-page-abort" ($probeSrc2 -match 'ABORT_WRONG_PAGE')

# 白名单:允许调用 Send-OneTalkMessage 的仍然只有那三个(不得新增第四个)
$sendSites = @()
foreach ($f in @(Get-ChildItem -Path $scripts -Recurse -Include *.ps1 -File -ErrorAction SilentlyContinue)) {
    $ln = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
        $ln++
        if ($line -match '^\s*#') { continue }
        if ($line -match '\bSend-OneTalkMessage\b') {
            $sendSites += [pscustomobject]@{ file = $f.FullName.Substring($root.Length + 1); line = $ln }
        }
    }
}
$unexpected = @($sendSites | Where-Object {
        $_.file -notmatch 'scripts\\lib\\send\.ps1$' -and
        $_.file -notmatch 'scripts\\monitor\.ps1$' -and
        $_.file -notmatch 'scripts\\gonghai\\gonghai_probe\.ps1$' -and
        # [SYNC 2026-09-27] 补 gonghai_batch.ps1 —— 同一公海子系统的批量入口(2026-09-27 新增),
        #   复用同一份 lib\send.ps1(发对人校验 ABORT_WRONG_CONVO 在它内部), 不是第二套发送实现。
        #   该文件新增时本白名单没跟上 ⇒ 这条断言一直是红的(既有红项, 与本轮缩锁改动无关)。
        $_.file -notmatch 'scripts\\gonghai\\gonghai_batch\.ps1$' -and
        # [SYNC 2026-09-27 收敛] 发送窗口移入 gonghai\gonghai_lib.ps1(batch/probe 共用同一份) ⇒
        #   唯一调用点从两个入口文件挪到了 lib。
        $_.file -notmatch 'scripts\\gonghai\\gonghai_lib\.ps1$'
    })
Assert-Eq "C-no-new-send-call-site" $unexpected.Count 0
if ($unexpected.Count -gt 0) { $unexpected | ForEach-Object { Write-Output ("      unexpected: {0}:{1}" -f $_.file, $_.line) } }

# ===========================================================================
# D/§3.2 —— 启动脚本(公海自己的 Chrome)
# ===========================================================================
Assert-True "D-ensure-script-exists" (Test-Path $ghEnsPath)
$ensSrc = Get-Content $ghEnsPath -Raw
$ensCode = Get-CodeOnly $ghEnsPath
# 端口/profile 只能来自配置
Assert-True "D-ensure-reads-gonghai-port" ($ensCode -match 'Get-GonghaiCdpPort')
Assert-True "D-ensure-uses-configured-profile" ($ensCode -match 'gonghai_profile') 
Assert-True "D-ensure-launches-with-profile" (($ensCode -match '--user-data-dir=') -and ($ensCode -match '\$profileDir'))   # [GH-38] WMI 启动写法里路径带转义引号,故不要求紧贴等号
Assert-True "D-ensure-launches-with-port" ($ensCode -match '--remote-debugging-port=\$ghPort')
Assert-True "D-ensure-navigates-to-onetalk" ($ensCode -match 'Get-GonghaiOnetalkUrl')
Assert-True "D-ensure-detects-login" ($ensCode -match 'textarea\.send-textarea')
Assert-True "D-ensure-reports-account-id" ($ensCode -match 'activeAccountId')
Assert-True "D-ensure-refuses-shared-port" ($ensCode -match 'GONGHAI-CDP-DOWN|REFUSE')
# **绝不**按进程名裸杀 chrome:杀进程必须带"本 profile 目录"这个必要条件
Assert-True "D-ensure-profile-exact-match" ($ensCode -match 'Get-GonghaiChromeProcesses')
$matcherFn = Get-FnText $ghEnsPath 'Get-GonghaiChromeProcesses'
Assert-True "D-matcher-fn-exists" ($null -ne $matcherFn)
Assert-True "D-matcher-requires-profile-dir" ($matcherFn -match 'regex\]::Escape\(\$ProfileDir\)')
Assert-True "D-matcher-requires-debug-flag" ($matcherFn -match '--remote-debugging-port=')
Assert-True "D-matcher-only-chrome-exe" ($matcherFn -match "Name='chrome\.exe'")
# 杀进程只出现在 profile 精确匹配的那一处
$killCount = ([regex]::Matches($ensCode, 'Stop-Process')).Count
Assert-Eq "D-ensure-single-kill-site" $killCount 1
# 绝不出现"按进程名裸杀"的写法(不带 profile 过滤的 Get-Process chrome | Stop-Process)
Assert-False "D-ensure-no-bare-process-kill" ($ensCode -match 'Get-Process\s+-Name\s+chrome|Get-Process\s+chrome')
# 不得依赖 chrome_ensure.ps1(避免反向耦合)
Assert-False "D-ensure-does-not-call-chrome-ensure" ($ensCode -match 'chrome_ensure\.ps1')

# ===========================================================================
# F —— chrome_ensure.ps1(自动回复那个实例)对公海**零依赖**,标记块已撤销,
#      且**杀进程必须按 profile 精确匹配**(不得连坐公海/okki/waimao)
# ===========================================================================
$chromSrc = Get-Content $chromPath -Raw
$chromCode = Get-CodeOnly $chromPath
Assert-True "F-chrome-ensure-keeps-monitor-navigate-url" ($chromCode -match 'weblitePWA\.htm')
Assert-False "F-chrome-ensure-no-marker-block" ($chromCode -match 'markedTabExists|GonghaiTabMarkerLiteral')
Assert-False "F-chrome-ensure-no-marker-literal" ($chromCode -match 'dshgh')
Assert-False "F-chrome-ensure-no-reverse-dependency" ($chromCode -match 'gonghai_cdp|gonghai_lib|GonghaiOnetalkPattern|Ensure-GonghaiOnetalkTab|gonghai_ensure')
# 导航必须回到"无条件导航"(标记块撤销前它被 if 包住)
Assert-True "F-chrome-ensure-unconditional-navigate" ($chromCode -match "powershell -ExecutionPolicy Bypass -File \`$cdp -Action navigate")

# 🔴 本 spec 实机验收真实踩到的缺陷(2026-09-27 15:14:36):
#   chrome_ensure 的杀进程判据含 `-match 'remote-debugging-port'` ⇒ 匹配**任何**调试实例,
#   一次 FORCE-RESTART 杀掉 20 个进程(含公海 9225 的全部)⇒ 把本 spec 刚建好的隔离实例一起干掉。
#   下面三条把这个回归钉死。
Assert-True "F-uses-profile-scoped-matcher" ($chromCode -match 'Get-MonitorChromeProcesses')
Assert-False "F-no-catch-all-debug-port-kill" ($chromCode -match "'remote-debugging-port'")
$monMatcher = Get-FnText $chromPath 'Get-MonitorChromeProcesses'
Assert-True "F-matcher-fn-exists" ($null -ne $monMatcher)
Assert-True "F-matcher-requires-profile-dir" ($monMatcher -match 'regex\]::Escape\(\$profileDir\)')
# profile 边界:`chrome-profile` 是 `chrome-profile-gonghai` 的**前缀** ⇒ 必须有边界断言,
# 否则自动回复的 ensure 会把公海实例当成自己人杀掉。
Assert-True "F-matcher-has-boundary-guard" ($monMatcher -match '\(\?!\[A-Za-z0-9\._-\]\)')
# 行为验证:纯字符串层面复刻该判据,证明"本实例命中、其他三个实例不命中"
$monProfile = [string](Get-Content (Join-Path $scripts 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).chrome_profile
$boundPat = [regex]::Escape($monProfile.TrimEnd('\')) + '(?![A-Za-z0-9._-])'
# 运行数据根由配置推导(不硬编码本机路径);下面三条只验证"兄弟 profile 不命中"这一边界语义
$rtRoot = Split-Path $monProfile.TrimEnd('\') -Parent
Assert-True "F-matcher-hits-own-profile" (('"C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --user-data-dir=' + $monProfile + ' --no-first-run') -match $boundPat)
Assert-False "F-matcher-ignores-gonghai-profile" (('"chrome.exe" --remote-debugging-port=9225 --user-data-dir=' + $rtRoot + '\chrome-profile-gonghai') -match $boundPat)
Assert-False "F-matcher-ignores-okki-profile" (('"chrome.exe" --remote-debugging-port=9223 --user-data-dir=' + $rtRoot + '\chrome-profile-okki') -match $boundPat)
Assert-False "F-matcher-ignores-waimao-profile" (('"chrome.exe" --remote-debugging-port=9224 --user-data-dir=' + $rtRoot + '\chrome-profile-waimao') -match $boundPat)
Assert-False "F-matcher-ignores-user-chrome" (('"chrome.exe" --user-data-dir=D:\Users\x\AppData\Local\Google\Chrome\User Data') -match $boundPat)

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
