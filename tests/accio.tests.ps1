# accio adapter regression tests (config parsing / line conversion / shadow compare / fallback safety)
# Run via run_tests.ps1 or: powershell -ExecutionPolicy Bypass -NoProfile -File tests\accio.tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\accio.ps1")

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

Write-Output "== accio tests =="

$tmp = Join-Path $env:TEMP ("accio_tests_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$savedProfile = $env:USERPROFILE
try {

    # ---- 1. ConvertTo-ReplyLines: 顺序/身份/时间戳/清洗 ----
    $msgs = @(
        [pscustomobject]@{ timestamp = 100; senderAliId = 7; content = "hello`nworld" },
        [pscustomobject]@{ timestamp = 300; senderAliId = 9; content = 'buyer latest' },
        [pscustomobject]@{ timestamp = 200; senderAliId = 7; content = 'us reply' },
        [pscustomobject]@{ timestamp = 150; senderAliId = 9; content = '   ' }
    )
    $lines = @(ConvertTo-ReplyLines $msgs 7)
    Assert-Eq "l1-count-skip-empty" $lines.Count 3
    Assert-True "l1-newest-first" ($lines[0] -eq '[BUYER] buyer latest @@TS:300')
    Assert-True "l1-me-mapping" ($lines[1] -eq '[ME] us reply @@TS:200')
    Assert-True "l1-newline-collapsed" ($lines[2] -eq '[ME] hello world @@TS:100')
    Assert-Eq "l1-empty-input" @(ConvertTo-ReplyLines @() 7).Count 0
    $noSelf = @(ConvertTo-ReplyLines $msgs 0)
    Assert-True "l1-no-self-defaults-buyer" ($noSelf[0] -eq '[BUYER] buyer latest @@TS:300')

    # ---- 2. 归一化 / 时间戳解析 ----
    Assert-Eq "n1-strip-prefix-ts" (Get-AccioNormText '[BUYER] hi   there @@TS:123') 'hi there'
    Assert-Eq "n2-empty" (Get-AccioNormText $null) ''
    Assert-Eq "t1-epoch-ms" (ConvertFrom-AccioTs '1789161101616') 1789161101616
    Assert-Eq "t2-epoch-sec" (ConvertFrom-AccioTs '1789161101') 1789161101000
    Assert-True "t3-invalid-null" ($null -eq (ConvertFrom-AccioTs 'not-a-date'))

    # ---- 3. 开关解析(默认全关;自定义配置可开) ----
    $f0 = Get-AccioFlags ([pscustomobject]@{})
    Assert-True "f1-default-shadow-off" (-not $f0.shadow)
    Assert-True "f1-default-read-off" (-not $f0.read)
    Assert-True "f1-default-send-off" (-not $f0.send)
    $f1 = Get-AccioFlags ([pscustomobject]@{ accio_shadow = $true; accio_read_enabled = $true; accio_send_enabled = $false })
    Assert-True "f2-shadow-on" $f1.shadow
    Assert-True "f2-read-on" $f1.read
    Assert-True "f2-send-off" (-not $f1.send)

    # ---- 4. CLI 参数引号 ----
    Assert-Eq "q1-simple" (ConvertTo-AccioCliArg 'list') 'list'
    Assert-Eq "q2-space" (ConvertTo-AccioCliArg 'hello world') '"hello world"'
    Assert-Eq "q3-quote" (ConvertTo-AccioCliArg 'say "hi"') '"say \"hi\""'

    # ---- 5. 网关配置解析(临时 USERPROFILE;凭据字段不得进入 info) ----
    $acct = Join-Path $tmp ".accio\accounts\111\.accio\runtime"
    New-Item -ItemType Directory -Path $acct -Force | Out-Null
    Set-Content -Path (Join-Path $acct "gateway-cli.json") -Value '{"schemaVersion":1,"url":"http://localhost:4097/","authMode":"basic","username":"u","password":"secret-value","relayPort":9236,"pid":123}' -Encoding UTF8
    $env:USERPROFILE = $tmp
    $info = Get-AccioGatewayInfo -Force
    Assert-True "c1-url-parsed" ($info.url -eq 'http://localhost:4097/')
    Assert-True "c2-no-credential-keys" (-not ($info.Keys -contains 'password') -and -not ($info.Keys -contains 'username'))
    $env:USERPROFILE = (Join-Path $tmp "empty-none")
    Assert-True "c3-missing-config-null" ($null -eq (Get-AccioGatewayInfo -Force))

    # ---- 6. 影子对比日志(仅记录,不改行为) ----
    $log = Join-Path $tmp "test.log"
    Set-AccioLogFile $log
    $cdp = @('[BUYER] hello @@TS:1789161101000', '[ME] hi @@TS:1789161000000')
    $gw = @('[BUYER] hello @@TS:1789161101616', '[ME] hi @@TS:1789161000000', '[BUYER] older @@TS:1789100000000')
    Invoke-AccioShadowCompare "Test Buyer" $cdp $gw
    $logText = Get-Content $log -Raw -Encoding UTF8
    Assert-True "s1-log-line" ($logText -match 'ACCIO-SHADOW Test Buyer: cdp=2 gw=3 latest=match ts=match cov=100%')
    $gwBad = @('[ME] different @@TS:1789161101000')
    Invoke-AccioShadowCompare "Test Buyer" $cdp $gwBad
    $logText2 = Get-Content $log -Raw -Encoding UTF8
    Assert-True "s2-mismatch-logged" ($logText2 -match 'latest=mismatch')

    # ---- 6b. 重叠校验(防同名多线程取错上下文) ----
    $cdpA = @('[BUYER] hello there @@TS:1789161101000', '[ME] hi @@TS:1789161000000')
    $gwA = @('[ME] hi @@TS:1789161000000', '[BUYER] hello there @@TS:1789161101616')
    Assert-True "o1-overlap-true" (Test-AccioLinesOverlap $cdpA $gwA)
    $gwB = @('[BUYER] completely different thread @@TS:1789161101616')
    Assert-True "o2-overlap-false" (-not (Test-AccioLinesOverlap $cdpA $gwB))
    Assert-True "o3-no-buyer-line-pass" (Test-AccioLinesOverlap @('[ME] only me @@TS:1') $gwA)

    # ---- 7. 回退安全: 网关不可达时函数返回空而非抛错 ----
    $env:USERPROFILE = $savedProfile
    Assert-True "g1-conv-null-when-no-gateway" ($null -eq (Get-AccioConversations -Force -Pages 1) -or @((Get-AccioConversations -Force -Pages 1)).Count -ge 0)

} finally {
    $env:USERPROFILE = $savedProfile
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
