# lib\paths.ps1 - 运行数据根与隔离守卫（2026-10-05 spec §6.3 / §7 / §8）。
#
# 职责（纯函数 + 目录创建，无浏览器/模型/通知副作用）：
#   1) 统一解析运行态文件路径（state / pause / tasks / locks / pid / remind / data / logs）；
#   2) 显式声明隔离运行根并写标记文件（记录生产路径清单）；
#   3) 在隔离模式下拒绝任何指向生产代码根或生产数据根的写操作；
#   4) 提供"隔离模式不得调用真实发送适配器"的可检查判据。
#
# 为什么必须显式标记：仅把 RuntimeRoot 指到临时目录并不能证明调用方**知道**自己在隔离运行；
#   标记文件把"生产路径清单"固定下来，使 Assert 能在写之前用可核对的事实拒绝，而不是靠约定。
#
# 依赖：scripts\config.ps1（Get-SkillConfig / Get-SkillPath / Set-SkillRuntimeRoot）。
if (-not (Get-Command Get-SkillRuntimeRoot -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}

$script:AarIsolationMarkerName = '.aar-isolation.json'

function Get-AarRuntimeRoot { return (Get-SkillRuntimeRoot) }
function Get-AarDeployRoot { return (Get-SkillDeployRoot) }

function Get-AarIsolationMarkerPath([string]$Root = '') {
    $r = $Root
    if (-not $r) { $r = Get-AarRuntimeRoot }
    return (Join-Path $r '.aar-isolation.json')
}

# 生产路径清单：直接从 config.json 的**运行态键**与部署根推导，不经过 RuntimeRoot，
# 因此在任何隔离设置之后调用仍然得到真实生产位置。
function Get-AarProductionPaths {
    $cfg = Get-SkillConfig
    $root = Get-SkillDeployRoot
    $scripts = Join-Path $root 'scripts'
    if ($cfg.scripts_dir) { $scripts = [string]$cfg.scripts_dir }
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @(
        $root,
        $scripts,
        (Join-Path $root 'data'),
        (Join-Path $root 'logs'),
        (Join-Path $root 'backups'),
        (Join-Path $scripts 'state.json'),
        (Join-Path $scripts 'monitor.pid'),
        (Join-Path $scripts 'remind_state.json'),
        (Join-Path $root 'credentials.md'),
        (Join-Path $root 'llm_config.json')
    )) { [void]$list.Add([string]$p) }
    if ($cfg.data_dir) { [void]$list.Add([string]$cfg.data_dir) }
    if ($cfg.logs_dir) { [void]$list.Add([string]$cfg.logs_dir) }
    if ($cfg.backups_dir) { [void]$list.Add([string]$cfg.backups_dir) }
    if ($cfg.chrome_profile) { [void]$list.Add([string]$cfg.chrome_profile) }
    if ($cfg.credentials_file) { [void]$list.Add([string]$cfg.credentials_file) }
    if ($cfg.llm_config_file) { [void]$list.Add([string]$cfg.llm_config_file) }
    if ($cfg.PSObject.Properties.Name -contains 'state_file' -and $cfg.state_file) { [void]$list.Add([string]$cfg.state_file) }
    if ($cfg.PSObject.Properties.Name -contains 'pause_file' -and $cfg.pause_file) { [void]$list.Add([string]$cfg.pause_file) }
    if ($cfg.PSObject.Properties.Name -contains 'human_tasks_file' -and $cfg.human_tasks_file) { [void]$list.Add([string]$cfg.human_tasks_file) }
    if ($cfg.PSObject.Properties.Name -contains 'lock_dir' -and $cfg.lock_dir) { [void]$list.Add([string]$cfg.lock_dir) }
    if ($cfg.PSObject.Properties.Name -contains 'pid_file' -and $cfg.pid_file) { [void]$list.Add([string]$cfg.pid_file) }
    if ($cfg.PSObject.Properties.Name -contains 'remind_state_file' -and $cfg.remind_state_file) { [void]$list.Add([string]$cfg.remind_state_file) }
    return @($list.ToArray() | Where-Object { $_ } | Select-Object -Unique)
}

function Get-AarIsolationInfo {
    $marker = Get-AarIsolationMarkerPath
    if (-not (Test-Path $marker)) { return $null }
    try {
        $j = Get-Content $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j -and $j.isolated) { return $j }
    } catch { }
    return $null
}

# 隔离模式 = 显式运行根 + 该根内存在有效标记。两者缺一都不算隔离。
function Test-AarIsolatedRuntime {
    if (-not (Test-SkillRuntimeIsolated)) { return $false }
    return ($null -ne (Get-AarIsolationInfo))
}

function Normalize-AarPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return $Path.Trim().TrimEnd('\') }
}

# 路径是否落在某个根之内（含根本身）。比较不区分大小写，按目录边界判断，避免 C:\a 匹配 C:\ab。
function Test-AarPathUnder([string]$Path, [string]$Root) {
    $p = Normalize-AarPath $Path
    $r = Normalize-AarPath $Root
    if (-not $p -or -not $r) { return $false }
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 新建隔离运行根：建目录 + 写标记（含生产路径清单）。返回标记对象。
# 行为约定：不删除、不修改任何生产文件；根已存在时只补写标记。
function New-AarIsolationRoot([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { throw 'New-AarIsolationRoot: Root is required' }
    $full = Normalize-AarPath $Root
    $prod = Get-AarProductionPaths
    foreach ($p in $prod) {
        if (Test-AarPathUnder $full $p) {
            throw ("ISOLATION-VIOLATION: isolation root '$full' is inside production path '$p'")
        }
    }
    foreach ($d in @($full, (Join-Path $full 'data'), (Join-Path $full 'logs'), (Join-Path $full 'locks'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $info = [ordered]@{
        isolated        = $true
        childPID = $PID
        nonce = $env:AAR_TEST_NONCE
        test = $env:AAR_TEST_NAME
        created         = (Get-Date).ToString('o')
        production_root = (Get-SkillDeployRoot)
        production_paths = @($prod)
    }
    $json = ($info | ConvertTo-Json -Depth 6)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Get-AarIsolationMarkerPath $full), $json, $enc)
    # [独立复核 R10] 该根已写出合法标记 ⇒ 解除本次切根登记（切换进入可核验上下文）。
    if (Get-Command Resolve-AarRuntimeRootSwitch -ErrorAction SilentlyContinue) { Resolve-AarRuntimeRootSwitch -Root $full }
    return (Get-AarIsolationInfo)
}

# 一次性进入隔离模式：设置运行根（可选设置配置文件）并写标记。
function Initialize-AarIsolation {
    param([Parameter(Mandatory = $true)][string]$Root, [string]$ConfigPath = '')
    $global:AarOfflineRequired=$true
    if ($ConfigPath) { [void](Set-SkillConfigPath $ConfigPath) }
    [void](Set-SkillRuntimeRoot $Root)
    $info = New-AarIsolationRoot $Root
    Write-AarChildAttestation
    return [pscustomobject]@{
        Root = (Normalize-AarPath $Root)
        Marker = (Get-AarIsolationMarkerPath)
        ProductionRoot = [string]$info.production_root
        ProductionPaths = @($info.production_paths)
    }
}

# 写操作前的隔离守卫：
#   - 非隔离模式：不做限制（生产行为不变）；
#   - 隔离模式：目标路径落在生产路径清单内 ⇒ 立即抛错（测试必须失败，而不是静默改生产文件）。
function Assert-AarNoProductionPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Operation = 'write',
        # -WithinRuntimeRoot: additionally require the target to be inside the isolated root. Used by
        # the runtime stores (state/pause/tasks/locks) whose paths are derived from the runtime root.
        # Plain temp-file tests may legitimately write elsewhere under %TEMP%, so the default only
        # forbids the production paths.
        [switch]$WithinRuntimeRoot
    )
    if (-not (Test-SkillRuntimeIsolated)) { return }
    if ($null -eq (Get-AarIsolationInfo)) {
        throw ("ISOLATION-VIOLATION: runtime root '" + (Get-AarRuntimeRoot) + "' is outside the deploy root but has no " + $script:AarIsolationMarkerName + " marker; refusing to $Operation '" + $Path + "' (call Initialize-AarIsolation / New-AarIsolationRoot first)")
    }
    $spec = Get-AarIsolationInfo
    foreach ($p in @($spec.production_paths)) {
        if (Test-AarPathUnder $Path $p) {
            throw ("ISOLATION-VIOLATION: refusing to $Operation production path '" + (Normalize-AarPath $Path) + "' while running isolated under '" + (Normalize-AarPath (Get-AarRuntimeRoot)) + "'")
        }
    }
    if ($WithinRuntimeRoot -and -not (Test-AarPathUnder $Path (Get-AarRuntimeRoot))) {
        throw ("ISOLATION-VIOLATION: refusing to $Operation '" + (Normalize-AarPath $Path) + "' outside the isolated runtime root '" + (Normalize-AarPath (Get-AarRuntimeRoot)) + "'")
    }
}

# [2026-10-05 第三轮 spec §9 第 1 条] 生产路径指纹：文件 -> "FILE|size|lastWriteUtc|sha256:..."，
#   目录 -> "DIR|<lastWriteUtc>|metadata-only"（**目录时间变化只是 metadata**，不能混写成"已证明内容改写"）。
#   只做非递归列目录；大文件（> HashMaxBytes）只记大小/时间并显式标注 no-hash，避免跑测试时做全盘哈希。
$script:AarFingerprintHashMaxBytes = 1048576

function Get-AarFileContentHash([string]$Path, [long]$Length = -1) {
    try {
        if ($Length -lt 0) { $Length = [long](Get-Item -LiteralPath $Path -ErrorAction Stop).Length }
        if ($Length -gt $script:AarFingerprintHashMaxBytes) { return 'no-hash' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { return (([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()) }
            finally { $fs.Dispose() }
        } finally { $sha.Dispose() }
    } catch { return 'hash-failed' }
}

function Get-AarProductionFingerprint {
    $snap = @{}
    $paths = Get-AarProductionPaths
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { $snap[(Normalize-AarPath $p)] = 'MISSING'; continue }
        $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        if ($item.PSIsContainer) {
            $snap[(Normalize-AarPath $p)] = ('DIR|' + $item.LastWriteTimeUtc.ToString('o') + '|metadata-only')
            foreach ($f in @(Get-ChildItem -LiteralPath $p -File -ErrorAction SilentlyContinue)) {
                $snap[(Normalize-AarPath $f.FullName)] = ('FILE|' + [string]$f.Length + '|' + $f.LastWriteTimeUtc.ToString('o') + '|sha256:' + (Get-AarFileContentHash $f.FullName ([long]$f.Length)))
            }
        } else {
            $snap[(Normalize-AarPath $p)] = ('FILE|' + [string]$item.Length + '|' + $item.LastWriteTimeUtc.ToString('o') + '|sha256:' + (Get-AarFileContentHash $p ([long]$item.Length)))
        }
    }
    return $snap
}

# 差异明细：每条带路径、变化类型、前后取值与"内容是否可证明变化"的判定。
#   Kind = 'file-content'（文件哈希不同 ⇒ 内容确实变了）| 'file-time'（只有时间/大小，无哈希差异）
#        | 'dir-metadata'（目录时间变化，仅 metadata）| 'created' | 'removed'
function Get-AarProductionChangeDetails($Before, $After) {
    $out = New-Object System.Collections.ArrayList
    foreach ($k in @($Before.Keys)) {
        if (-not $After.ContainsKey($k)) {
            [void]$out.Add([pscustomobject]@{ Path = $k; Change = 'removed'; Kind = 'removed'; Before = [string]$Before[$k]; After = '' })
            continue
        }
        $b = [string]$Before[$k]; $a = [string]$After[$k]
        if ($b -eq $a) { continue }
        $kind = 'changed'
        if ($b.StartsWith('DIR|') -or $a.StartsWith('DIR|')) { $kind = 'dir-metadata' }
        else {
            $hb = ''
            $mb = [regex]::Match($b, 'sha256:([0-9a-f]+|no-hash|hash-failed)')
            if ($mb.Success) { $hb = [string]$mb.Groups[1].Value }
            $ha = ''
            $ma = [regex]::Match($a, 'sha256:([0-9a-f]+|no-hash|hash-failed)')
            if ($ma.Success) { $ha = [string]$ma.Groups[1].Value }
            if ($hb -and $ha -and $hb -ne $ha -and $hb -match '^[0-9a-f]{16,}$' -and $ha -match '^[0-9a-f]{16,}$') { $kind = 'file-content' }
            else { $kind = 'file-time' }
        }
        [void]$out.Add([pscustomobject]@{ Path = $k; Change = 'changed'; Kind = $kind; Before = $b; After = $a })
    }
    foreach ($k in @($After.Keys)) {
        if ($Before.ContainsKey($k)) { continue }
        [void]$out.Add([pscustomobject]@{ Path = $k; Change = 'created'; Kind = 'created'; Before = ''; After = [string]$After[$k] })
    }
    return @($out.ToArray())
}

# 比较两份指纹，返回差异描述数组（空数组 = 生产文件逐项未变）。
function Compare-AarProductionFingerprint($Before, $After) {
    $diff = New-Object System.Collections.ArrayList
    foreach ($k in @($Before.Keys)) {
        if (-not $After.ContainsKey($k)) { [void]$diff.Add("removed: $k"); continue }
        if ([string]$Before[$k] -ne [string]$After[$k]) { [void]$diff.Add("changed: $k") }
    }
    foreach ($k in @($After.Keys)) {
        if (-not $Before.ContainsKey($k)) { [void]$diff.Add("created: $k") }
    }
    return @($diff.ToArray())
}

# 真实发送适配器守卫：隔离模式下一律拒绝（测试必须改为注入适配器）。
function Assert-AarSendAllowed {
    if (Test-AarIsolatedRuntime) {
        throw ("ISOLATION-VIOLATION: the real OneTalk send adapter was called while running isolated under '" + (Normalize-AarRuntimeRootSafe) + "'")
    }
}
function Normalize-AarRuntimeRootSafe { try { return (Normalize-AarPath (Get-AarRuntimeRoot)) } catch { return '?' } }

# 统一运行态文件入口（找不到具名路径时按运行根推导）。
function Get-AarRuntimeFile([string]$Name) {
    $p = Get-SkillPath $Name
    if (-not $p) { $p = Join-Path (Get-AarRuntimeRoot) ($Name + '.json') }
    return $p
}

# 生产写者是否正在运行：读取生产数据根的写锁文件并校验持有进程是否存活。
# 用途：离线测试的生产指纹守卫必须能区分"测试写了生产文件"与"正在运行的生产进程写了生产文件"。
#   - 有存活写者 ⇒ 变化按并发写者归因（WARN），仍逐条列出供人工核对；
#   - 无写者 ⇒ 任何变化都是本次运行的写入 ⇒ 直接失败。
function Test-AarProductionWriterRunning {
    $lockFile = Join-Path (Get-SkillPath 'data') 'onetalk-write.lock'
    if (-not (Test-Path $lockFile)) { return $false }
    try {
        $txt = (Get-Content $lockFile -Raw -ErrorAction SilentlyContinue)
        if (-not $txt) { return $false }
        $holder = ([string]$txt).Split('|')[0].Trim()
        if ($holder -notmatch '^\d+$') { return $false }
        return [bool](Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue)
    } catch { return $false }
}

function Get-AarProductionWriterInfo {
    $lockFile = Join-Path (Get-SkillPath 'data') 'onetalk-write.lock'
    $holder = ''
    if (Test-Path $lockFile) {
        try { $holder = ([string](Get-Content $lockFile -Raw)).Split('|')[0].Trim() } catch { }
    }
    $monitors = @()
    try {
        $monitors = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match 'monitor\.ps1|watchdog\.ps1') } |
            ForEach-Object { [string]$_.ProcessId })
    } catch { }
    return [pscustomobject]@{
        Running = ((Test-AarProductionWriterRunning) -or ($monitors.Count -gt 0))
        LockHolder = $holder
        Processes = @($monitors)
    }
}

# 供 monitor 等入口在启动时显式声明运行根（环境变量/参数已由 config.ps1 处理）。
function Format-AarRuntimeBanner {
    $mode = 'production'
    if (Test-SkillRuntimeIsolated) { $mode = 'isolated' }
    return ('runtime-mode=' + $mode + ' root=' + (Normalize-AarPath (Get-AarRuntimeRoot)))
}

# =============================================================================================
# [2026-10-05 第三轮 spec §9] 生产路径验收审计（纯分类，可被 G1 夹具直接驱动）
#
#   PASS        没有生产路径变化，或有**独立证据**证明变化来自已归因的写者；
#   FAIL        变化落在写者自己的输出根之外（越界/测试写到生产），或根本没有存活写者；
#   UNRESOLVED  变化只落在存活写者的输出根内，但**来源未证实** —— 不伪称已归因，也不记为通过。
#
#   「写的可能性」不是证据：进程存在 + 路径在输出根 **不构成**写入归因证据（spec §9 第 3 条）。
#   只有调用方显式给出独立来源证明（-AttributionProven + -AttributionEvidence）才算 PASS。
# =============================================================================================
function Get-AarProductionPathAudit {
    param(
        $Changes = @(),
        $WriterInfo = $null,
        # 生产写者自己的输出根（数据/日志/报表/备份）：落在其中的变化 = 并发写者的可能来源。
        [string[]]$WriterOutputRoots = @(),
        # 某个**正在运行的生产进程自身拥有**的路径（例如 Chrome 在运行时写自己的 profile）。
        #   这不是"排除目录"：落在其中的变化仍然**不是通过**（UNRESOLVED），只是不再当作
        #   "测试越界"的证据 —— 目录归属是线索，不是写入来源证明（spec §9 第 3/6 条）。
        [string[]]$WriterOwnedPaths = @(),
        [switch]$AttributionProven,
        $AttributionEvidence = @()
    )
    $fatal = New-Object System.Collections.ArrayList
    $unattributed = New-Object System.Collections.ArrayList
    $attributed = New-Object System.Collections.ArrayList
    $writerRunning = [bool]($WriterInfo -and $WriterInfo.Running)
    foreach ($c in @($Changes)) {
        $path = ''
        if ($c -is [System.Collections.IDictionary]) { $path = [string]$c['Path'] }
        elseif ($c -and ($c.PSObject.Properties.Name -contains 'Path')) { $path = [string]$c.Path }
        $isWriterOutput = $false
        foreach ($r in @($WriterOutputRoots)) { if ($r -and (Test-AarPathUnder $path $r)) { $isWriterOutput = $true; break } }
        $isWriterOwned = $false
        foreach ($r in @($WriterOwnedPaths)) { if ($r -and (Test-AarPathUnder $path $r)) { $isWriterOwned = $true; break } }
        # A process or boolean cannot establish write provenance. Unknown stays UNRESOLVED.
        # Structured independent evidence must bind this exact path and both fingerprints.
        $proof=@($AttributionEvidence|Where-Object {$_ -isnot [string] -and $_.Path -eq $path -and $_.Before -eq $c.Before -and $_.After -eq $c.After -and $_.PID -gt 0 -and $_.SourceRef -and $_.ObservedAtUtc})
        if($proof.Count -eq 1 -and $proof[0].Source -eq 'test-child'){[void]$fatal.Add($c)}
        elseif($proof.Count -eq 1 -and $proof[0].Source -eq 'production-writer'){[void]$attributed.Add($c)}
        else{[void]$unattributed.Add($c)}

    }
    $result = 'PASS'
    $reason = 'no production path changed during this run'
    if ($fatal.Count -gt 0) {
        $result = 'FAIL'
        $reason = 'independent path-specific evidence proves a test child wrote production'
    } elseif ($unattributed.Count -gt 0) {
        $result = 'UNRESOLVED'
        $reason = 'production changes have unknown provenance; source is NOT proven (process existence or absence is not write attribution)'
    } elseif ($attributed.Count -gt 0) {
        $reason = 'changes independently attributed: ' + [string]$AttributionEvidence
    }
    return [pscustomobject]@{
        Result = $result
        Reason = $reason
        Fatal = @($fatal.ToArray())
        Unattributed = @($unattributed.ToArray())
        Attributed = @($attributed.ToArray())
        AttributionEvidence = [string]$AttributionEvidence
        WriterRunning = $writerRunning
        # 本次判定用到的写者自有路径（Chrome profile 等），逐条记录以便复核。
        WriterOwnedPaths = @($WriterOwnedPaths)
    }
}

# 可读取的写入溯源线索（只读）：锁持有进程、生产 monitor/watchdog、Chrome 进程。
#   这些只是**线索**；没有独立写入证明时不得据此宣称已归因。
function Get-AarWriteAttributionClues {
    param([string]$ChromeProfilePath = '')
    $clues = [ordered]@{
        capturedAtUtc   = ([datetime]::UtcNow.ToString('o'))
        lockHolderPid   = ''
        monitorWatchdog = @()
        chromeProcesses = @()
        chromeProfilePath = [string]$ChromeProfilePath
    }
    $info = Get-AarProductionWriterInfo
    $clues.lockHolderPid = [string]$info.LockHolder
    $clues.monitorWatchdog = @($info.Processes)
    try {
        $chrome = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Id })
        $clues.chromeProcesses = @($chrome)
    } catch { }
    return [pscustomobject]$clues
}

. (Join-Path $PSScriptRoot 'test_context.ps1')
