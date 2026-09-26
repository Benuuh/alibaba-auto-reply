# ============================================================
#  C 盘清理 - 管理员脚本
#  用法：右键此文件 -> "使用 PowerShell 运行"；或管理员 PowerShell 中执行：
#        powershell -NoProfile -ExecutionPolicy Bypass -File "<本脚本的绝对路径>"
#        （不写死部署根：脚本自身路径即 $PSCommandPath，可直接复制其值）
#
#  安全说明：以下项目全部是可再生的缓存 / 日志 / 安装包残留。
#  不触碰：Windows\Installer(卸载修复必需)、WinSxS(仅由 DISM 处理)、
#          任何用户文档、聊天记录、已安装程序、账号配置。
# ============================================================

# --- 自检：必须以管理员身份运行 ---
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "请以管理员身份运行此脚本。" -ForegroundColor Red
    Read-Host "按回车退出"
    exit 1
}

$ErrorActionPreference = 'Continue'
function Get-Size($p) {
    if (-not (Test-Path -LiteralPath $p)) { return 0 }
    $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object -Property Length -Sum).Sum
    if ($null -eq $s) { return 0 }
    return [double]$s
}

$before = (Get-PSDrive C).Free
$report = @()

$targets = [ordered]@{
    # --- Windows 更新缓存（已下载完的更新包，需要时会重新下载）---
    'Windows 更新下载缓存'        = 'C:\Windows\SoftwareDistribution\Download'
    # --- 系统日志（CBS/DISM/WindowsUpdate 等，纯诊断信息）---
    'CBS 组件安装日志'            = 'C:\Windows\Logs\CBS'
    'DISM 日志'                   = 'C:\Windows\Logs\DISM'
    'Windows Update 日志'         = 'C:\Windows\Logs\WindowsUpdate'
    'PITR 日志'                   = 'C:\Windows\Logs\PITR'
    'WinRE 代理日志'              = 'C:\Windows\Logs\WinREAgent'
    'NetSetup 日志'               = 'C:\Windows\Logs\NetSetup'
    # --- VS / VC++ 安装器包缓存（仅影响"修复安装"，卸载不受影响）---
    'VS 安装器包缓存'             = 'C:\ProgramData\Package Cache'
    # --- 上一轮因权限未清理成功的项 ---
    'Windows Installer 缓存(用户)'= "$env:LOCALAPPDATA\Package Cache"
    '罗技 G HUB 旧版安装包'       = 'C:\ProgramData\LGHUB\depots\634218'
    # --- Adobe Camera Raw 相机/镜头配置文件（打开 RAW 时会按需重新下载）---
    'Camera Raw: ModelZoo'        = 'C:\ProgramData\Adobe\CameraRaw\ModelZoo'
    'Camera Raw: CameraProfiles'  = 'C:\ProgramData\Adobe\CameraRaw\CameraProfiles'
    'Camera Raw: LensProfiles'    = 'C:\ProgramData\Adobe\CameraRaw\LensProfiles'
}

Write-Host "`n=== 开始清理 ===" -ForegroundColor Cyan
foreach ($name in $targets.Keys) {
    $path = $targets[$name]
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $size = Get-Size $path
    if ($size -le 0) { continue }

    try {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    } catch {
        Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $left  = Get-Size $path
    $freed = [math]::Round(($size - $left) / 1MB, 1)
    $report += [PSCustomObject]@{ 项目 = $name; 释放MB = $freed; 剩余MB = [math]::Round($left / 1MB, 1) }
    if ($freed -gt 1) { Write-Host ("  [OK]   {0,-32} {1,8:N1} MB" -f $name, $freed) -ForegroundColor Green }
    else              { Write-Host ("  [跳过] {0,-32} 未释放" -f $name) -ForegroundColor DarkGray }
}

# --- DISM 组件存储清理：清理 WinSxS 中被取代的旧组件版本 ---
# WinSxS 目录显示约 19GB，但大部分是与 System32 共享的硬链接，实际可回收量由系统计算。
Write-Host "`n=== DISM 组件存储分析（可能需要 1-3 分钟）===" -ForegroundColor Cyan
dism /Online /Cleanup-Image /AnalyzeComponentStore

Write-Host "`n是否执行组件存储清理？(清理被取代的旧版本组件，不可回滚旧更新)" -ForegroundColor Yellow
$answer = Read-Host "输入 Y 执行，其他键跳过"
if ($answer -eq 'Y' -or $answer -eq 'y') {
    Write-Host "正在清理组件存储（可能需要 5-15 分钟，请勿关闭窗口）..." -ForegroundColor Cyan
    dism /Online /Cleanup-Image /StartComponentCleanup
}

$after = (Get-PSDrive C).Free
Write-Host "`n=== 汇总 ===" -ForegroundColor Cyan
$report | Where-Object { $_.释放MB -gt 0 } | Sort-Object 释放MB -Descending | Format-Table -AutoSize
Write-Host ("本次释放 : {0:N2} GB" -f (($after - $before) / 1GB)) -ForegroundColor Green
Write-Host ("C 盘可用 : {0:N2} GB  (清理前 {1:N2} GB)" -f ($after / 1GB), ($before / 1GB)) -ForegroundColor Green
Read-Host "`n完成，按回车退出"
