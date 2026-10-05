# tests\run_tests.ps1 - 分层测试入口（2026-10-05 spec §6.3 / §7 / §8）。
#
# 分层（清单见 tests\layers.json，每个 *.tests.ps1 必须登记，未登记 ⇒ 直接失败）：
#   pure     纯逻辑：消息规范化、事实、决策、时间判据、输出检查。不访问浏览器/模型/通知通道。
#   isolated 隔离集成：真正的会话入口、临时存储、竞争进程、模拟适配器。只使用测试配置与临时目录。
#   live     真实验收：真实模型、指定浏览器会话、通知投递与发送确认。**默认不运行**。
#
# 默认入口（-Layer Offline = pure + isolated）遵守两条硬约束：
#   ① 每个子测试进程都被指到本次运行独有的临时运行根（含 .aar-isolation.json 标记），
#      因此 Get-SkillPath 的运行态路径全部落在临时目录里，且 CDP/真实发送出口在隔离模式下直接抛错；
#   ② 运行前后各取一次**生产路径指纹**（大小 + 最后写入时间 + 内容哈希；目录时间只算 metadata），
#      任何生产文件被创建/改写/删除都会逐条列出。
#
# [2026-10-05 第三轮 spec §9] 验收口径与退出码：
#   分开报告 LogicTests / IsolationChecks / ProductionPathAudit / Overall，且 Overall 只有在
#   逻辑、隔离与生产路径审计**全部**通过时才是 PASS。并发写者存在**不是**写入归因证据：
#   没有独立来源证明时，输出根内的并发变化记为 ProductionPathAudit=UNRESOLVED，
#   Overall=BLOCKED-UNRESOLVED，普通全量入口不会 exit 0、也不会打印整体成功。
#
#   exit 0  逻辑与隔离通过，且生产路径审计 PASS；
#   exit 1  逻辑测试失败 / 隔离检查失败 / 生产路径审计 FAIL（确证测试越界）；
#   exit 2  runner 配置错误（分层清单缺失、未登记或文件缺失）；
#   exit 3  环境未验收：生产路径出现并发变化但来源未证实（ProductionPathAudit=UNRESOLVED）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1                 # 默认 Offline
#   powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Pure
#   Live/All 在本轮 runner 中拒绝执行，真实验收未授权。
param(
    [ValidateSet('Offline', 'Pure', 'Isolated', 'Live', 'All')][string]$Layer = 'Offline',
    [string]$LogFile = '',
    [switch]$KeepTemp
)
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
. (Join-Path $repo 'scripts\config.ps1')
. (Join-Path $repo 'scripts\lib\paths.ps1')

$transcript = New-Object System.Collections.ArrayList
function Emit([string]$line) { [void]$transcript.Add($line); Write-Output $line }

$manifestPath = Join-Path $here 'layers.json'
if (-not (Test-Path $manifestPath)) { Emit 'RUNNER-ERROR: tests\layers.json is missing'; exit 2 }
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$allFiles = @(Get-ChildItem -Path $here -Filter '*.tests.ps1' | Sort-Object Name | ForEach-Object { $_.Name })
$pure = @($manifest.pure)
$isolated = @($manifest.isolated)
$live = @($manifest.live)
$classified = @($pure + $isolated + $live)
# 失配即失败：新增测试文件必须显式分层，否则"默认离线套件通过"会被未分类文件悄悄削弱。
$unclassified = @($allFiles | Where-Object { $classified -notcontains $_ })
$missingFiles = @($classified | Where-Object { $allFiles -notcontains $_ })
if ($unclassified.Count -gt 0) { Emit ('RUNNER-ERROR: unclassified test file(s): ' + ($unclassified -join ', ') + ' - add them to tests\layers.json'); exit 2 }
if ($missingFiles.Count -gt 0) { Emit ('RUNNER-ERROR: layers.json lists missing file(s): ' + ($missingFiles -join ', ')); exit 2 }

switch ($Layer) {
    'Pure'     { $selected = @($pure) }
    'Isolated' { $selected = @($isolated) }
    'Offline'  { $selected = @($pure + $isolated) }
    'Live'     { $selected = @($live) }
    'All'      { $selected = @($pure + $isolated + $live) }
}

$enforceProductionGuard = ($Layer -ne 'Live')
Emit ('TEST-LAYER=' + $Layer + ' files=' + $selected.Count + ' productionGuard=' + $enforceProductionGuard)
Emit ('PRODUCTION-PATHS: ' + ((Get-AarProductionPaths) -join ' ; '))

# =============================================================================================
# [2026-10-05 第三轮 spec §9] 验收口径：分开报告 LogicTests / IsolationChecks /
#   ProductionPathAudit / Overall，保留实际退出码。
#
#   归因口径（第 3/4 条）：本机可能同时有生产 monitor/watchdog/Chrome 在跑，它们会写自己的运行态。
#     * 「进程存在 + 路径在输出根」**不是**写入证据 —— 这只说明"有并发写者存在"；
#     * 只有调用方拿到**独立来源证明**（-AttributionProven / -AttributionEvidence）时才算已归因；
#     * 否则一律 ProductionPathAudit=UNRESOLVED：不得写成 benign/attributed，也不得记为 Overall PASS。
#
#   退出码（文档化）：
#     0  逻辑测试与隔离检查通过，且生产路径审计 PASS；
#     1  逻辑测试失败，或生产路径审计 FAIL（越界变化/无存活写者）；
#     2  runner 自身配置错误（分层清单缺失/未登记/文件缺失）；
#     3  环境未验收：生产路径出现并发变化但来源未证实（ProductionPathAudit=UNRESOLVED）。
#        普通全量入口**不会**在这种情形下 exit 0 或打印整体成功。
# =============================================================================================
$writer = Get-AarProductionWriterInfo
Emit ('PRODUCTION-WRITER: running=' + $writer.Running + ' lockHolder=' + $writer.LockHolder + ' processes=' + ($writer.Processes -join ','))
$writerOutputRoots = @((Get-SkillPath 'data'), (Get-SkillPath 'logs'), (Get-SkillPath 'reports'), (Get-SkillPath 'backups'))
# [spec §9 第 3/6 条] 某个**正在运行的生产进程自身拥有**的路径（Chrome 运行时写自己的 profile）。
#   落在其中的变化仍然不是通过（UNRESOLVED），只是不再被当作"测试越界"的证据；
#   没有该进程在跑时同一路径的变化仍然是 FAIL。
$writerOwnedPaths = @()
try {
    $cfg = Get-SkillConfig
    if ($cfg.chrome_profile) {
        $chromeRunning = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue).Count -gt 0
        if ($chromeRunning) { $writerOwnedPaths += [string]$cfg.chrome_profile }
    }
} catch { }
Emit ('PRODUCTION-WRITER-OWNED-PATHS: ' + $(if (@($writerOwnedPaths).Count -gt 0) { @($writerOwnedPaths) -join ' ; ' } else { '(none)' }))
$cluesBefore = $null
if ($enforceProductionGuard) { try { $cluesBefore = Get-AarWriteAttributionClues } catch { $cluesBefore = $null } }

$before = @{}
if ($enforceProductionGuard) { $before = Get-AarProductionFingerprint }
$attributedChanges = New-Object System.Collections.ArrayList
$fileFingerprints = @{}
$fileContexts=@{}

$totalPass = 0
$totalFail = 0
$failFiles = New-Object System.Collections.ArrayList
$tempRoots = New-Object System.Collections.ArrayList
$isolationOk = $true
$isolationIssues = New-Object System.Collections.ArrayList
$savedRuntimeRoot = $env:AAR_RUNTIME_ROOT
$savedLayer = $env:AAR_TEST_LAYER

foreach ($name in $selected) {
    $t = Join-Path $here $name
    if (-not (Test-Path $t)) { continue }
    Emit ('=== ' + $name + ' ===')
    $runRoot = Join-Path $env:TEMP ('aar-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    [void]$tempRoots.Add($runRoot)
    $marker = [ordered]@{
        isolated = $true
        created = (Get-Date).ToString('o')
        test = $name
        production_root = (Get-SkillDeployRoot)
        production_paths = @(Get-AarProductionPaths)
    } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $runRoot '.aar-isolation.json'), $marker, (New-Object System.Text.UTF8Encoding($true)))
    $env:AAR_RUNTIME_ROOT = $runRoot
    $env:AAR_TEST_LAYER = $Layer
    # 隔离检查（IsolationChecks）：子进程必须真的跑在带标记的隔离运行根里，且该根不在生产路径内。
    $markerPath = Join-Path $runRoot '.aar-isolation.json'
    if (-not (Test-Path $markerPath)) {
        $isolationOk = $false
        [void]$isolationIssues.Add($name + ': isolation marker missing in run root')
    } else {
        foreach ($prod in @(Get-AarProductionPaths)) {
            if ($prod -and (Test-AarPathUnder $runRoot $prod)) {
                $isolationOk = $false
                [void]$isolationIssues.Add($name + ': run root is inside production path ' + $prod)
            }
        }
    }
    $fileBefore = @{}
    if ($enforceProductionGuard) { $fileBefore = Get-AarProductionFingerprint }
    $out = @();$exit=1
    if($Layer -in @('Live','All')){throw 'closure runner supports isolated Offline only'}
    $nonce=[guid]::NewGuid().ToString('N');$proofPath=Join-Path $runRoot 'child-proof.json'
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName='powershell.exe'
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $here 'run_child.ps1')+'" -TestPath "'+$t+'" -Root "'+$runRoot+'" -Nonce "'+$nonce+'" -ProofPath "'+$proofPath+'"'
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $child=New-Object Diagnostics.Process;$child.StartInfo=$psi
    try{
        [void]$child.Start();$childPID=$child.Id
        $stdoutTask=$child.StandardOutput.ReadToEndAsync();$stderrTask=$child.StandardError.ReadToEndAsync()
        $child.WaitForExit();$exit=$child.ExitCode;$out=@($stdoutTask.Result -split "`r?`n")+@($stderrTask.Result -split "`r?`n")
        $proof=$null;if(Test-Path $proofPath){$proof=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json}
        $attestation=Test-AarChildAttestation -Proof $proof -ExpectedPID $childPID -Nonce $nonce -TestName $name
        if(-not $attestation.Ok){$isolationOk=$false;[void]$isolationIssues.Add($name+': '+$attestation.Reason)}
        $fileContexts[$name]=[pscustomobject]@{ChildPID=$childPID;Nonce=$nonce;Test=$name;Proof=$proof;Verified=$attestation.Ok;Reason=$attestation.Reason;ExitCode=$exit}
        Emit ('CHILD-CONTEXT test='+$name+' pid='+$childPID+' nonce='+$nonce+' verified='+$attestation.Ok+' contexts='+@($attestation.VerifiedContexts).Count+' exit='+$exit)
    }catch{$out+=('RUNNER-EXCEPTION: '+$_.Exception.Message);$isolationOk=$false;$exit=1}finally{$child.Dispose()}
    if ($enforceProductionGuard) {
        $fileAfter = Get-AarProductionFingerprint
        $fileDiffs = @(Get-AarProductionChangeDetails $fileBefore $fileAfter)
        # 只保留差异明细（完整前后指纹体积过大且无额外信息）。
        $fileFingerprints[$name] = @($fileDiffs)
        foreach ($d in $fileDiffs) { [void]$attributedChanges.Add(('[' + $name + '] ' + [string]$d.Change + ' ' + [string]$d.Path + ' (' + [string]$d.Kind + ')')) }
    }
    foreach ($line in $out) { Emit ('  ' + [string]$line) }
    $outText = ($out | ForEach-Object { [string]$_ }) -join [string][char]10
    foreach ($m in [regex]::Matches($outText, 'pass=(\d+)')) { $totalPass += [int]$m.Groups[1].Value }
    foreach ($m in [regex]::Matches($outText, 'fail=(\d+)')) { $totalFail += [int]$m.Groups[1].Value }
    if ($exit -ne 0) { [void]$failFiles.Add($name) }
}
if ($null -eq $savedRuntimeRoot) { Remove-Item Env:\AAR_RUNTIME_ROOT -ErrorAction SilentlyContinue } else { $env:AAR_RUNTIME_ROOT = $savedRuntimeRoot }
if ($null -eq $savedLayer) { Remove-Item Env:\AAR_TEST_LAYER -ErrorAction SilentlyContinue } else { $env:AAR_TEST_LAYER = $savedLayer }

$audit = [pscustomobject]@{ Result = 'PASS'; Reason = 'production guard disabled for this layer'; Fatal = @(); Unattributed = @(); Attributed = @(); WriterRunning = $false }
$changeDetails = @()
$cluesAfter = $null
if ($enforceProductionGuard) {
    $after = Get-AarProductionFingerprint
    $changeDetails = @(Get-AarProductionChangeDetails $before $after)
    try { $cluesAfter = Get-AarWriteAttributionClues } catch { $cluesAfter = $null }
    # 归因证明的口径：只有当调用方显式提供独立证据时才传 -AttributionProven。
    #   本 runner 目前**没有**这样的证据来源，因此一律按"来源未证实"处理。
    $audit = Get-AarProductionPathAudit -Changes $changeDetails -WriterInfo $writer -WriterOutputRoots $writerOutputRoots -WriterOwnedPaths $writerOwnedPaths
}

if (-not $KeepTemp) {
    foreach ($d in $tempRoots) { $full=Normalize-AarPath $d;if(-not(Test-AarPathUnder $full $env:TEMP) -or $full -eq (Normalize-AarPath $env:TEMP)){throw 'unsafe test cleanup path'};Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

Emit ''
Emit ('TEST-SUMMARY: layer=' + $Layer + ' files=' + $selected.Count + ' failedFiles=' + $failFiles.Count + ' pass=' + $totalPass + ' fail=' + $totalFail)
$logicResult = 'PASS'
if ($failFiles.Count -gt 0 -or $totalFail -gt 0) { $logicResult = 'FAIL' }
Emit ('LogicTests=' + $logicResult + ' files=' + $selected.Count + ' failedFiles=' + $failFiles.Count + ' pass=' + $totalPass + ' fail=' + $totalFail)
if ($failFiles.Count -gt 0) { Emit ('  failed files: ' + ($failFiles -join ', ')) }
$isolationResult = 'PASS'
if (-not $isolationOk) { $isolationResult = 'FAIL' }
Emit ('IsolationChecks=' + $isolationResult + ' checked=' + $selected.Count + ' issues=' + $isolationIssues.Count)
foreach ($i in @($isolationIssues)) { Emit ('  isolation issue: ' + [string]$i) }

if ($enforceProductionGuard) {
    Emit ('ProductionPathAudit=' + [string]$audit.Result + ' changes=' + @($changeDetails).Count + ' writerRunning=' + $writer.Running + ' reason=' + [string]$audit.Reason)
    if ($cluesBefore -or $cluesAfter) {
        Emit ('  attribution-clues(before): ' + (($cluesBefore | ConvertTo-Json -Depth 4 -Compress)))
        Emit ('  attribution-clues(after): ' + (($cluesAfter | ConvertTo-Json -Depth 4 -Compress)))
    }
    if (@($changeDetails).Count -gt 0) {
        Emit '  PRODUCTION-CHANGE-DETAILS (path | change | kind | before -> after):'
        foreach ($d in @($changeDetails)) {
            Emit ('    ' + [string]$d.Path + ' | ' + [string]$d.Change + ' | ' + [string]$d.Kind + ' | ' + [string]$d.Before + ' -> ' + [string]$d.After)
        }
        Emit '  NOTE: concurrent changes with no independent write-provenance evidence are UNRESOLVED; a running writer is a clue, not proof.'
        if ($audit.Result -eq 'FAIL') {
            foreach ($d in @($audit.Fatal)) { Emit ('    fatal: ' + (($d | ConvertTo-Json -Depth 4 -Compress))) }
        }
        foreach ($d in @($audit.Unattributed)) { Emit ('    unresolved(concurrent, source unproven): ' + (($d | ConvertTo-Json -Depth 4 -Compress))) }
    }
} else {
    Emit 'ProductionPathAudit=NOT-ENFORCED layer=Live'
}

$overall = 'PASS'
$exitCode = 0
if ($logicResult -eq 'FAIL' -or $isolationResult -eq 'FAIL') { $overall = 'FAIL'; $exitCode = 1 }
elseif ($enforceProductionGuard -and $audit.Result -eq 'FAIL') { $overall = 'FAIL'; $exitCode = 1 }
elseif ($enforceProductionGuard -and $audit.Result -eq 'UNRESOLVED') { $overall = 'BLOCKED-UNRESOLVED'; $exitCode = 3 }
Emit ('Overall=' + $overall + ' exitCode=' + $exitCode)

if ($LogFile) {
    try {
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($LogFile, (($transcript -join [string][char]10) + [string][char]10), $enc)
        Write-Output ('TEST-LOG-WRITTEN: ' + $LogFile)
        # 生产路径审计的证据文件（精确路径、前后指纹、内容哈希、采样区间、测试文件与进程线索）。
        $auditPath = $LogFile + '.production-audit.json'
        $auditDoc = [ordered]@{
            generatedAtUtc = ([datetime]::UtcNow.ToString('o'))
            layer = $Layer
            selectedFiles = @($selected)
            logicTests = $logicResult
            isolationChecks = $isolationResult
            productionPathAudit = [string]$audit.Result
            overall = $overall
            exitCode = $exitCode
            writerOutputRoots = @($writerOutputRoots)
            writer = $writer
            attributionCluesBefore = $cluesBefore
            attributionCluesAfter = $cluesAfter
            changes = @($changeDetails)
            perFileDiffs = $fileFingerprints
            childContexts=$fileContexts
            isolationEvidenceScope='Verified child PID, test, nonce, declared runtime roots and marker hashes; real model/CDP/send/notification adapters refuse offline context. This does not prove every direct file IO stayed inside these roots.'
            failedFiles = @($failFiles)
        }
        [System.IO.File]::WriteAllText($auditPath, (($auditDoc | ConvertTo-Json -Depth 8) + [string][char]10), (New-Object System.Text.UTF8Encoding($true)))
        Write-Output ('TEST-AUDIT-WRITTEN: ' + $auditPath)
    } catch { Write-Output ('TEST-LOG-FAILED: ' + $_.Exception.Message) }
}

if ($exitCode -eq 1) {
    if ($failFiles.Count -gt 0) { Emit ('FAILED: ' + ($failFiles -join ', ')) }
    if ($isolationResult -eq 'FAIL') { Emit 'FAILED: isolation checks failed' }
    if ($enforceProductionGuard -and $audit.Result -eq 'FAIL') { Emit 'FAILED: production paths changed during an offline run (fatal / unattributable)' }
} elseif ($exitCode -eq 3) {
    Emit 'NOT-ACCEPTED: business regression passed, but the production-path audit is UNRESOLVED (concurrent change with no proven source) - full acceptance stays pending'
}
if ($exitCode -eq 0) { Emit 'ALL SELECTED TEST FILES PASS' }
exit $exitCode
