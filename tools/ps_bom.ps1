# tools\ps_bom.ps1 - .ps1 文件 UTF-8 BOM 守卫（2026-10-05 工作流工具）
#
# 背景：本机 PowerShell 5.1 对**无 BOM** 的 .ps1 按 ANSI 解码，中文注释/字符串会静默失真；
#   本仓库的 .ps1 一律要求 UTF-8 带 BOM（SKILL.md / KNOWN_EXCEPTIONS E-10）。
#   编辑工具在改写文件时可能丢掉 BOM，本脚本用来核对"相对 git HEAD 的 BOM 状态是否被改变"，
#   并在 -Fix 时补回 BOM（只补 BOM，不改内容）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\ps_bom.ps1            # 检查（默认）
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\ps_bom.ps1 -Fix       # 补 BOM
param(
    [switch]$Fix,
    [string[]]$Paths = @()
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent

function Test-FileHasBom([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

function Add-FileBom([string]$path) {
    # 只用"显式字符比较"剥 BOM：ReadAllText 是否已剥掉 BOM 依实现而定，
    # 无条件 TrimStart([char]0xFEFF) 会在 BOM 已被剥掉时吃掉正文第一个字符（曾把 '#' 吃掉）。
    $t = [System.IO.File]::ReadAllText($path)
    if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
    [System.IO.File]::WriteAllText($path, $t, (New-Object System.Text.UTF8Encoding($true)))
}

$targets = New-Object System.Collections.ArrayList
if ($Paths.Count -gt 0) {
    foreach ($p in $Paths) { [void]$targets.Add($p) }
} else {
    Push-Location $root
    try {
        foreach ($line in @(git status --porcelain)) {
            if (-not $line -or $line.Length -lt 4) { continue }
            $rel = $line.Substring(3).Trim().Trim('"')
            if ($rel -notmatch '\.ps1$') { continue }
            [void]$targets.Add((Join-Path $root $rel))
        }
    } finally { Pop-Location }
}

$mismatch = New-Object System.Collections.ArrayList
foreach ($t in $targets) {
    if (-not (Test-Path $t)) { continue }
    $rel = $t.Replace($root + '\', '').Replace('\', '/')
    $headHasBom = $null
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $root
    try {
        $inHead = $false
        & git cat-file -e ("HEAD:" + $rel) 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $inHead = $true }
        if ($inHead) {
            $head = @(& git show ("HEAD:" + $rel) 2>$null)
            if ($head.Count -gt 0) { $headHasBom = ([string]$head[0]).StartsWith([char]0xFEFF) }
        }
    } catch { } finally { Pop-Location; $ErrorActionPreference = $savedEap }
    $cur = Test-FileHasBom $t
    $desired = $true
    if ($null -ne $headHasBom) { $desired = $headHasBom }
    if ($cur -ne $desired) {
        if ($Fix -and $desired) {
            Add-FileBom $t
            Write-Output ('BOM-FIXED ' + $rel)
        } else {
            [void]$mismatch.Add([pscustomobject]@{ File = $rel; HasBom = $cur; Desired = $desired })
        }
    }
}
foreach ($m in $mismatch) { Write-Output ('BOM-MISMATCH ' + $m.File + ' (has=' + $m.HasBom + ' desired=' + $m.Desired + ')') }
Write-Output ('BOM-CHECK files=' + $targets.Count + ' mismatches=' + $mismatch.Count)
if ($mismatch.Count -gt 0) { exit 1 }
exit 0
