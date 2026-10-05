# tests\isolation.tests.ps1 - 隔离基础（2026-10-05 spec §6.3 / §7 / §8 第 7 项）
#
# 覆盖：
#   I01 显式 ConfigPath 生效（代码位置与运行数据根分别解析）
#   I02 显式 RuntimeRoot：运行态路径全部落在该根内，代码位置仍来自仓库
#   I03 隔离但缺标记 ⇒ 写操作立即失败（fail closed，不允许"说不清就照写"）
#   I04 隔离 + 标记 ⇒ 写生产路径被拒（ISOLATION-VIOLATION）
#   I05 隔离 + 标记 ⇒ 写隔离根内允许
#   I06 未隔离（RuntimeRoot == deploy_root）⇒ 守卫为 no-op，生产行为不变
#   I07 无标记不算隔离；标记非法/损坏也不算
#   I08 CDP 出口在隔离模式下抛错（真实浏览器不可达）
#   I09 真实发送适配器在隔离模式下抛错
#   I10 隔离根不能建在生产路径之内
#   I11 生产指纹：隔离运行不会创建/改写生产文件
#   I12 模块导入无运行副作用（只解析，不建目录、不写文件）
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Output ('  ok   ' + $name) }
    else { $script:fail++; Write-Output ('  FAIL ' + $name + ' :: ' + $detail) }
}
function Throws([scriptblock]$sb) {
    try { [void](& $sb); return '' } catch { return $_.Exception.Message }
}

. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

Write-Output '== isolation tests (spec §6.3) =='

$sandbox = Join-Path $env:TEMP ('aar-iso-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$savedEnvRoot = $env:AAR_RUNTIME_ROOT
$savedEnvCfg = $env:AAR_CONFIG_PATH

try {
    # ------------------------------------------------------------------ I01
    $cfgDir = Join-Path $sandbox 'cfg'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $cfgPath = Join-Path $cfgDir 'config.json'
    $cfgObj = [ordered]@{
        deploy_root = $cfgDir
        scripts_dir = (Join-Path $cfgDir 'scripts')
        data_dir = (Join-Path $sandbox 'prod-data')
        chrome_path = 'C:\chrome.exe'
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
    Remove-Item Env:\AAR_RUNTIME_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\AAR_CONFIG_PATH -ErrorAction SilentlyContinue
    [void](Set-SkillConfigPath '')
    [void](Set-SkillRuntimeRoot '' -DeclaredProbe -Reason 'I01: 生产模式解析探针（不是隔离根，显式声明）')
    $loaded = Get-SkillConfig -ConfigPath $cfgPath
    Check 'I01a explicit ConfigPath is honoured' ($loaded.deploy_root -eq $cfgDir) ('deploy_root=' + $loaded.deploy_root)
    Check 'I01b code root follows the explicit config' ((Get-SkillDeployRoot) -eq $cfgDir) ('root=' + (Get-SkillDeployRoot))
    Check 'I01c runtime root defaults to the code root' ((Get-SkillRuntimeRoot) -eq $cfgDir) ('runtime=' + (Get-SkillRuntimeRoot))
    Check 'I01d not isolated without an explicit runtime root' (-not (Test-SkillRuntimeIsolated)) 'Test-SkillRuntimeIsolated=true'

    # ------------------------------------------------------------------ I02
    $isoRoot = Join-Path $sandbox 'run'
    New-Item -ItemType Directory -Path $isoRoot -Force | Out-Null
    [void](Set-SkillRuntimeRoot $isoRoot)
    $names = @('state', 'pause', 'tasks', 'locks', 'pid', 'remind', 'data', 'logs')
    $outside = @()
    foreach ($n in $names) {
        $p = Get-SkillPath $n
        if (-not (Test-AarPathUnder $p $isoRoot)) { $outside += ($n + '=' + $p) }
    }
    Check 'I02a runtime paths resolve inside the explicit RuntimeRoot' ($outside.Count -eq 0) ($outside -join ' ; ')
    Check 'I02b code paths still come from the config' ((Get-SkillPath 'scripts') -eq (Join-Path $cfgDir 'scripts')) ('scripts=' + (Get-SkillPath 'scripts'))
    Check 'I02c isolated flag is on' (Test-SkillRuntimeIsolated) 'Test-SkillRuntimeIsolated=false'

    # ------------------------------------------------------------------ I03
    $err = Throws { Assert-AarNoProductionPath -Path (Join-Path $isoRoot 'x.json') -Operation 'write' }
    Check 'I03 unmarked isolated runtime fails closed' ($err -match 'ISOLATION-VIOLATION') ('err=' + $err)

    # ------------------------------------------------------------------ I04/I05
    $info = New-AarIsolationRoot $isoRoot
    Check 'I04a marker exists after New-AarIsolationRoot' (Test-Path (Get-AarIsolationMarkerPath $isoRoot)) 'marker missing'
    Check 'I04b Test-AarIsolatedRuntime is true with marker' (Test-AarIsolatedRuntime) 'Test-AarIsolatedRuntime=false'
    $prod = @($info.production_paths)
    Check 'I04c production path list is non-empty' ($prod.Count -gt 0) 'empty production path list'
    $errProd = Throws { Assert-AarNoProductionPath -Path (Join-Path $cfgDir 'state.json') -Operation 'write' }
    Check 'I04d writing a production path is refused' ($errProd -match 'ISOLATION-VIOLATION') ('err=' + $errProd)
    $errOut = Throws { Assert-AarNoProductionPath -Path (Join-Path $isoRoot 'state.json') -Operation 'write' -WithinRuntimeRoot }
    Check 'I05a writing inside the isolated root is allowed' ($errOut -eq '') ('err=' + $errOut)
    $errOutside = Throws { Assert-AarNoProductionPath -Path (Join-Path $env:TEMP 'aar-outside.json') -Operation 'write' -WithinRuntimeRoot }
    Check 'I05b -WithinRuntimeRoot refuses an outside path' ($errOutside -match 'ISOLATION-VIOLATION') ('err=' + $errOutside)

    # ------------------------------------------------------------------ I10
    $errInsideProd = Throws { New-AarIsolationRoot (Join-Path $cfgDir 'nested-run') }
    Check 'I10 isolation root inside a production path is refused' ($errInsideProd -match 'ISOLATION-VIOLATION') ('err=' + $errInsideProd)

    # ------------------------------------------------------------------ I08/I09
    . (Join-Path $scripts 'lib\cdp.ps1')
    . (Join-Path $scripts 'lib\send.ps1')
    $errCdp = Throws { Invoke-CdpEval "1+1" }
    Check 'I08 Invoke-CdpEval is refused while isolated' ($errCdp -match 'ISOLATION-VIOLATION') ('err=' + $errCdp)
    $errSend = Throws { Send-OneTalkMessage 'Buyer X' 'hello' }
    Check 'I09 Send-OneTalkMessage is refused while isolated' ($errSend -match 'ISOLATION-VIOLATION') ('err=' + $errSend)

    # ------------------------------------------------------------------ I11
    $before = Get-AarProductionFingerprint
    $probe = Join-Path (Get-SkillPath 'state') 'x'
    [System.IO.File]::WriteAllText((Get-SkillPath 'state'), '{"replied":{}}', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Get-SkillPath 'pause'), '{"pauses":{}}', (New-Object System.Text.UTF8Encoding($false)))
    $after = Get-AarProductionFingerprint
    $diff = @(Compare-AarProductionFingerprint $before $after)
    Check 'I11a isolated writes create no production file' ($diff.Count -eq 0) ($diff -join ' ; ')
    Check 'I11b the isolated files really were written' ((Test-Path (Get-SkillPath 'state')) -and (Test-Path (Get-SkillPath 'pause'))) 'isolated files missing'

    # ------------------------------------------------------------------ I12
    $probeDir = Join-Path $sandbox 'importprobe'
    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    $probeScript = Join-Path $probeDir 'probe.ps1'
    $probeBody = '. "' + (Join-Path $scripts 'config.ps1') + '"' + [string][char]10 +
                 '. "' + (Join-Path $scripts 'lib\paths.ps1') + '"' + [string][char]10 +
                 '$null = Get-SkillPath "state"' + [string][char]10 +
                 'Write-Output "PROBE-OK"'
    [System.IO.File]::WriteAllText($probeScript, $probeBody, (New-Object System.Text.UTF8Encoding($true)))
    $probeOut = @(powershell -ExecutionPolicy Bypass -NoProfile -File $probeScript 2>&1)
    Check 'I12a importing the modules has no runtime error' ((($probeOut -join ' ') -match 'PROBE-OK')) ($probeOut -join ' | ')
    Check 'I12b import does not create the runtime root' (-not (Test-Path (Join-Path $repo 'run'))) 'unexpected directory created'

    # ------------------------------------------------------------------ I07
    Remove-Item (Get-AarIsolationMarkerPath $isoRoot) -Force
    Check 'I07 unmarked runtime root is not "isolated"' (-not (Test-AarIsolatedRuntime)) 'Test-AarIsolatedRuntime=true without marker'
    [System.IO.File]::WriteAllText((Get-AarIsolationMarkerPath $isoRoot), '{"isolated":false}', (New-Object System.Text.UTF8Encoding($false)))
    Check 'I07b a marker with isolated=false does not count' (-not (Test-AarIsolatedRuntime)) 'isolated=false marker was accepted'

    # ------------------------------------------------------------------ I06
    [void](Set-SkillConfigPath '')
    [void](Set-SkillRuntimeRoot '' -DeclaredProbe -Reason 'I06: 回到生产模式确认守卫为 no-op（显式声明）')
    Remove-Item Env:\AAR_RUNTIME_ROOT -ErrorAction SilentlyContinue
    Check 'I06a default resolution is production (not isolated)' (-not (Test-SkillRuntimeIsolated)) ('runtime=' + (Get-SkillRuntimeRoot))
    $errNoop = Throws { Assert-AarNoProductionPath -Path (Join-Path (Get-SkillPath 'data') 'whatever.json') -Operation 'write' }
    Check 'I06b the guard is a no-op in production mode' ($errNoop -eq '') ('err=' + $errNoop)
} finally {
    if ($null -eq $savedEnvRoot) { Remove-Item Env:\AAR_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:AAR_RUNTIME_ROOT = $savedEnvRoot }
    if ($null -eq $savedEnvCfg) { Remove-Item Env:\AAR_CONFIG_PATH -ErrorAction SilentlyContinue } else { $env:AAR_CONFIG_PATH = $savedEnvCfg }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output 'FAILED'; exit 1 }
Write-Output 'ALL PASS'
