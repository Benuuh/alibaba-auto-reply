# tests\third_fix_g1_guard.tests.ps1 - G1：生产路径审计口径与越界证据（spec §9 / §10.6）
#
# 本文件**不触碰**真实 Chrome profile 或任何生产文件：全部用虚构指纹/虚构写者信息驱动
#   lib\paths.ps1::Get-AarProductionPathAudit 与 Get-AarProductionChangeDetails 的纯分类。
# 归因功能需要来源证明时，夹具**明确注入**"已证实/未证实"，不把模拟证明写成实际生产归因。
#
# 分层：pure。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== third_fix G1 production-path guard tests =='

# 虚构根（只用于路径归属判断；不创建、不读取、不写入任何真实文件）。
$fakeData = 'C:\fictional-prod\data'
$fakeLogs = 'C:\fictional-prod\logs'
$fakeConfig = 'C:\fictional-prod\config.json'
$fakeChrome = 'C:\fictional-prod\chrome-profile'
$roots = @($fakeData, $fakeLogs)
$writerUp = [pscustomobject]@{ Running = $true; LockHolder = '4242'; Processes = @('4242') }
$writerDown = [pscustomobject]@{ Running = $false; LockHolder = ''; Processes = @() }
function Chg([string]$path, [string]$kind = 'file-content', [string]$change = 'changed') {
    return [pscustomobject]@{ Path = $path; Change = $change; Kind = $kind; Before = 'FILE|10|t0|sha256:aaaa'; After = 'FILE|10|t1|sha256:bbbb' }
}

# ---- 无变化 => PASS ----
$g0 = Get-AarProductionPathAudit -Changes @() -WriterInfo $writerUp -WriterOutputRoots $roots
Eq 'G1-no-change-is-pass' ([string]$g0.Result) 'PASS'

# ---- 越界变化（写者输出根之外）=> FAIL，绝不因为"有写者在跑"变成 benign ----
$g1 = Get-AarProductionPathAudit -Changes @((Chg $fakeConfig)) -WriterInfo $writerUp -WriterOutputRoots $roots
Eq 'G1-outside-writer-roots-is-fatal' ([string]$g1.Result) 'UNRESOLVED'
Eq 'G1-outside-writer-roots-is-not-benign' (@($g1.Unattributed).Count) 1
# Chrome 在运行时拥有自己的 profile：落在其中的变化同样**不是通过**（UNRESOLVED），
#   但也不再被当作"测试越界"的证据 —— 目录归属是线索，不是写入来源证明。
$g2 = Get-AarProductionPathAudit -Changes @((Chg $fakeChrome)) -WriterInfo $writerUp -WriterOutputRoots $roots -WriterOwnedPaths @($fakeChrome)
Eq 'G1-chrome-profile-change-is-unresolved-not-benign' ([string]$g2.Result) 'UNRESOLVED'
Check 'G1-chrome-profile-not-swallowed-as-benign' ([bool]($g2.Result -ne 'PASS')) ''
Eq 'G1-chrome-profile-not-counted-as-attributed' (@($g2.Attributed).Count) 0
Check 'G1-chrome-profile-recorded-in-unresolved' ([bool]((@($g2.Unattributed) | ConvertTo-Json -Depth 4) -match 'chrome-profile')) ''
# 没有 Chrome 在跑（该路径不在写者自有清单里）时，同一路径的变化仍然是 FAIL（越界）。
$g2b = Get-AarProductionPathAudit -Changes @((Chg $fakeChrome)) -WriterInfo $writerUp -WriterOutputRoots $roots -WriterOwnedPaths @()
Eq 'G1-chrome-profile-without-running-chrome-is-fatal' ([string]$g2b.Result) 'UNRESOLVED'
# 写者自有路径 + 没有存活写者 => 仍然是 FAIL。
$g2c = Get-AarProductionPathAudit -Changes @((Chg $fakeChrome)) -WriterInfo $writerDown -WriterOutputRoots $roots -WriterOwnedPaths @($fakeChrome)
Eq 'G1-writer-owned-without-writer-is-fatal' ([string]$g2c.Result) 'UNRESOLVED'

# ---- 无存活写者 + 任何变化 => FAIL ----
$g3 = Get-AarProductionPathAudit -Changes @((Chg (Join-Path $fakeLogs 'run.log'))) -WriterInfo $writerDown -WriterOutputRoots $roots
Eq 'G1-no-writer-any-change-is-fatal' ([string]$g3.Result) 'UNRESOLVED'

# ---- 写者输出根内的并发变化 + 来源未证实 => UNRESOLVED（不是 PASS，也不写成 benign/attributed）----
$g4 = Get-AarProductionPathAudit -Changes @((Chg (Join-Path $fakeData 'state.json'))) -WriterInfo $writerUp -WriterOutputRoots $roots
Eq 'G1-concurrent-in-writer-roots-is-unresolved' ([string]$g4.Result) 'UNRESOLVED'
Check 'G1-unresolved-is-not-pass' ([bool]($g4.Result -ne 'PASS')) ''
Check 'G1-unresolved-reason-says-source-not-proven' ([bool]([string]$g4.Reason -match 'NOT proven')) ([string]$g4.Reason)
Eq 'G1-unresolved-not-counted-as-attributed' (@($g4.Attributed).Count) 0

# ---- 夹具明确注入"已证实" => PASS，并把证明写进结果（模拟证明不等于实际生产归因）----
$g5 = Get-AarProductionPathAudit -Changes @((Chg (Join-Path $fakeData 'state.json'))) -WriterInfo $writerUp -WriterOutputRoots $roots -AttributionProven -AttributionEvidence 'fixture-injected-proof: writer pid 4242 wrote it'
Eq 'G1-injected-proof-is-pass' ([string]$g5.Result) 'UNRESOLVED'
Eq 'G1-injected-proof-recorded' ([string]$g5.AttributionEvidence) 'fixture-injected-proof: writer pid 4242 wrote it'

# ---- 差异明细：目录时间只算 metadata；内容哈希差异才算内容改写 ----
$before = @{}
$after = @{}
$before['C:\fictional-prod\logs'] = 'DIR|2026-10-05T00:00:00.0000000Z|metadata-only'
$after['C:\fictional-prod\logs'] = 'DIR|2026-10-05T00:00:05.0000000Z|metadata-only'
$before['C:\fictional-prod\logs\a.log'] = 'FILE|10|2026-10-05T00:00:00.0000000Z|sha256:aaaaaaaaaaaaaaaa'
$after['C:\fictional-prod\logs\a.log'] = 'FILE|10|2026-10-05T00:00:05.0000000Z|sha256:bbbbbbbbbbbbbbbb'
$before['C:\fictional-prod\logs\b.log'] = 'FILE|10|2026-10-05T00:00:00.0000000Z|sha256:cccccccccccccccc'
$after['C:\fictional-prod\logs\b.log'] = 'FILE|12|2026-10-05T00:00:05.0000000Z|sha256:cccccccccccccccc'
$d = @(Get-AarProductionChangeDetails $before $after)
$dirEntry = @($d | Where-Object { $_.Path -eq 'C:\fictional-prod\logs' })[0]
$contentEntry = @($d | Where-Object { $_.Path -eq 'C:\fictional-prod\logs\a.log' })[0]
$timeEntry = @($d | Where-Object { $_.Path -eq 'C:\fictional-prod\logs\b.log' })[0]
Eq 'G1-directory-change-is-metadata-only' ([string]$dirEntry.Kind) 'dir-metadata'
Eq 'G1-same-size-different-content-detected' ([string]$contentEntry.Kind) 'file-content'
Eq 'G1-size-only-change-is-not-content-rewrite' ([string]$timeEntry.Kind) 'file-time'

# ---- created / removed ----
$b2 = @{}; $a2 = @{}
$b2['C:\fictional-prod\data\gone.json'] = 'FILE|1|t|sha256:aaaaaaaaaaaaaaaa'
$a2['C:\fictional-prod\data\new.json'] = 'FILE|1|t|sha256:bbbbbbbbbbbbbbbb'
$d2 = @(Get-AarProductionChangeDetails $b2 $a2)
Check 'G1-removed-detected' ([bool](@($d2 | Where-Object { $_.Change -eq 'removed' }).Count -eq 1)) ''
Check 'G1-created-detected' ([bool](@($d2 | Where-Object { $_.Change -eq 'created' }).Count -eq 1)) ''

# ---- 真实入口（runner）必须分开报告四个结论，且未证实来源不得记为整体成功 ----
$runnerSrc = Get-Content (Join-Path $here 'run_tests.ps1') -Raw -Encoding UTF8
foreach ($needle in @('LogicTests=', 'IsolationChecks=', 'ProductionPathAudit=', 'Overall=', 'exit $exitCode',
                      'BLOCKED-UNRESOLVED', 'NOT-ACCEPTED', 'source unproven', 'production-audit.json',
                      'a running writer is a clue, not proof')) {
    Check ('G1-runner-reports [' + $needle + ']') ([bool]($runnerSrc -match [regex]::Escape($needle))) ''
}
Check 'G1-runner-no-longer-claims-attribution' (-not ($runnerSrc -match 'attributed to the live writer, not to this run')) ''
Check 'G1-runner-does-not-exclude-chrome-profile' (-not ($runnerSrc -match 'chrome-profile.*benign|benign.*chrome-profile')) ''
Check 'G1-runner-keeps-fatal-exit-1' ([bool]($runnerSrc -match 'FAILED: production paths changed')) ''

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
