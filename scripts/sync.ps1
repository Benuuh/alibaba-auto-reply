# 工作副本 ↔ 技能镜像同步。默认方向:工作副本 → 镜像(-Push);-Pull 反向;-Status 仅对比。
# 敏感铁律(D2):credentials.md 不推送不拉取(仅校验存在性),镜像侧凭据由人工维护。
# 运行时产物(日志/快照/状态/pid/备份/临时)与 chrome-profile/logs/data/reports/backups 一律排除。
# 用法: sync.ps1 -Push | -Pull | -Status
param(
    [switch]$Push,
    [switch]$Pull,
    [switch]$Status,
    [string]$MirrorRoot = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
$workRoot = Get-SkillPath ""
if (-not $MirrorRoot) { $MirrorRoot = Join-Path $env:USERPROFILE ".config\opencode\skills\alibaba-auto-reply" }
if (-not (Test-Path $MirrorRoot)) { Write-Output "SYNC-FAIL: mirror root not found: $MirrorRoot"; exit 1 }

$exclRegex = '\.(log|bak|pre|pid|tmp)$|^msgs_|^state\.json|^nudge_state|^summary_last\.json|^remind_state|^last_sync|^verify_.*\.ps1$|^apply_.*\.ps1$'
$rootFiles = @("SKILL.md", "README_部署说明.md", "llm_config.json")

function Get-SyncFiles([string]$base) {
    $list = @()
    $scripts = Join-Path $base "scripts"
    if (Test-Path $scripts) {
        $list += Get-ChildItem $scripts -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notmatch $exclRegex -and $_.FullName -notmatch 'chrome-profile'
        }
    }
    foreach ($d in @("tests", "docs")) {
        $dp = Join-Path $base $d
        if (Test-Path $dp) {
            $list += Get-ChildItem $dp -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -notmatch $exclRegex
            }
        }
    }
    foreach ($f in $rootFiles) {
        $p = Join-Path $base $f
        if (Test-Path $p) { $list += Get-Item $p }
    }
    return @($list)
}

function Get-RelPath([string]$base, [string]$full) { return $full.Substring($base.Length).TrimStart('\') }

function Write-DiffTable {
    $workFiles = Get-SyncFiles $workRoot
    $mirFiles = Get-SyncFiles $MirrorRoot
    $workMap = @{}; foreach ($f in $workFiles) { $workMap[(Get-RelPath $workRoot $f.FullName)] = (Get-FileHash $f.FullName).Hash }
    $mirMap = @{}; foreach ($f in $mirFiles) { $mirMap[(Get-RelPath $MirrorRoot $f.FullName)] = (Get-FileHash $f.FullName).Hash }
    foreach ($rel in ($workMap.Keys | Sort-Object)) {
        if (-not $mirMap.ContainsKey($rel)) { Write-Output "  ONLY-WORK:   $rel" }
        elseif ($mirMap[$rel] -ne $workMap[$rel]) { Write-Output "  DIFFERS:     $rel" }
    }
    foreach ($rel in ($mirMap.Keys | Sort-Object)) {
        if (-not $workMap.ContainsKey($rel)) { Write-Output "  ONLY-MIRROR: $rel" }
    }
    $wc = Join-Path $workRoot "credentials.md"; $mc = Join-Path $MirrorRoot "credentials.md"
    Write-Output ("  CREDS: work={0} mirror={1} (not synced by design)" -f (Test-Path $wc), (Test-Path $mc))
    $total = $workMap.Count
    $diff = @($workMap.Keys | Where-Object { -not $mirMap.ContainsKey($_) -or $mirMap[$_] -ne $workMap[$_] }).Count
    Write-Output "  summary: $total work files, $diff differ"
}

if ($Status) { Write-DiffTable; exit 0 }

$src = $null; $dst = $null; $label = ""
if ($Push) { $src = $workRoot; $dst = $MirrorRoot; $label = "work->mirror" }
elseif ($Pull) { $src = $MirrorRoot; $dst = $workRoot; $label = "mirror->work" }
else { Write-Output "Usage: sync.ps1 -Push | -Pull | -Status"; exit 1 }

$srcFiles = Get-SyncFiles $src
$copied = 0
foreach ($f in $srcFiles) {
    $rel = Get-RelPath $src $f.FullName
    $dstPath = Join-Path $dst $rel
    $dstDir = Split-Path $dstPath -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    if (Test-Path $dstPath) { Copy-Item $dstPath "$dstPath.prev" -Force -ErrorAction SilentlyContinue }
    Copy-Item $f.FullName $dstPath -Force
    $copied++
}
Write-Output "SYNC-DONE: $label, $copied files copied"
if ($Push) {
    # A5: record last push time for sync-staleness reminder
    @{ last_push = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); files = $copied } | ConvertTo-Json | Set-Content -Path (Join-Path $PSScriptRoot "last_sync.json") -Encoding UTF8
}
