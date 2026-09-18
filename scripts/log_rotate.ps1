# log_rotate.ps1 - 日志轮转:超限日志移入 <LogDir>\archive\,保留最近 N 份归档。
# 用法(dot-source): . scripts\log_rotate.ps1; Invoke-LogRotation -LogDir <logs> -Name monitor -MaxMb 20 -KeepFiles 10 [-DryRun]
# 直接运行: powershell -ExecutionPolicy Bypass -NoProfile -File scripts\log_rotate.ps1 -DryRun
#           (读取 config.json 的 logs_dir/log_max_mb/log_keep_files,对 monitor/watchdog/health 三份日志执行)
$ErrorActionPreference = "Stop"

# 单份日志轮转:超限则重试 3 次(间隔 2s)移动到 archive\<Name>_<yyyyMMdd_HHmmss>.log;
# 归档保留最近 KeepFiles 份,其余删除;锁定失败只返回摘要不抛错;-DryRun 只报告不动文件。
function Invoke-LogRotation([string]$LogDir, [string]$Name, [int]$MaxMb, [int]$KeepFiles, [switch]$DryRun) {
    if ($MaxMb -le 0) { $MaxMb = 20 }
    if ($KeepFiles -le 0) { $KeepFiles = 10 }
    $file = Join-Path $LogDir ($Name + '.log')
    if (-not (Test-Path -LiteralPath $file)) {
        return ("LOG-ROTATE $Name action=none (file missing)")
    }
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 2)
    if ($sizeMb -le $MaxMb) {
        return ("LOG-ROTATE $Name size=${sizeMb}MB limit=${MaxMb}MB action=none")
    }
    if ($DryRun) {
        return ("LOG-ROTATE $Name size=${sizeMb}MB limit=${MaxMb}MB action=dryrun would-move-to=archive")
    }
    $archiveDir = Join-Path $LogDir 'archive'
    if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
    $dest = Join-Path $archiveDir ($Name + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    $moved = $false
    $lastErr = ''
    for ($i = 1; $i -le 3; $i++) {
        try {
            Move-Item -LiteralPath $file -Destination $dest -Force -ErrorAction Stop
            $moved = $true
            break
        } catch {
            $lastErr = [string]$_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    if (-not $moved) {
        return ("LOG-ROTATE $Name size=${sizeMb}MB limit=${MaxMb}MB action=fail reason=" + ($lastErr -replace '\s+',' '))
    }
    $deleted = 0
    try {
        $old = @(Get-ChildItem -LiteralPath $archiveDir -Filter ($Name + '_*.log') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepFiles)
        foreach ($f in $old) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            $deleted++
        }
    } catch {}
    return ("LOG-ROTATE $Name size=${sizeMb}MB limit=${MaxMb}MB action=moved file=" + [IO.Path]::GetFileName($dest) + " kept=${KeepFiles} deleted=${deleted}")
}

# 三份运行日志统一轮转(供手动/定时调用)
function Invoke-LogRotationAll([string]$LogDir, [int]$MaxMb, [int]$KeepFiles, [switch]$DryRun) {
    foreach ($n in @('monitor','watchdog','health')) {
        Invoke-LogRotation -LogDir $LogDir -Name $n -MaxMb $MaxMb -KeepFiles $KeepFiles -DryRun:$DryRun
    }
}

# 直接运行(非 dot-source)时:读取 config 执行三份日志轮转;dot-source 时仅加载函数,无副作用
$__logRotateDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $__logRotateDotSourced) {
    $__dry = @($args) -contains '-DryRun'
    . (Join-Path $PSScriptRoot 'config.ps1')
    $__cfg = Get-SkillConfig
    $__logDir = Get-SkillPath 'logs'
    $__maxMb = 20
    $__keep = 10
    if ($__cfg.PSObject.Properties.Name -contains 'log_max_mb' -and $__cfg.log_max_mb) { $__maxMb = [int]$__cfg.log_max_mb }
    if ($__cfg.PSObject.Properties.Name -contains 'log_keep_files' -and $__cfg.log_keep_files) { $__keep = [int]$__cfg.log_keep_files }
    Invoke-LogRotationAll -LogDir $__logDir -MaxMb $__maxMb -KeepFiles $__keep -DryRun:$__dry
}
