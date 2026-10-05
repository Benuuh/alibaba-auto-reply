# lib\state_store.ps1 - 运行态 JSON 的统一读写与**原子替换**（2026-10-05 spec §5-2）。
#
# 契约：
#   Read-JsonDocument           区分四种状态：missing（不存在）/ empty（存在但空内容）/ valid / corrupt（解析失败）。
#                               调用方必须能区分"没有账本"与"账本损坏"：前者可新建，后者必须按故障处理，
#                               绝不能当成"空账本"静默重建（2026-09-27 重复打扰事故的形态）。
#   Write-JsonDocumentAtomic    临时文件写入 → 回读校验（解析通过）→ 备份现有文件 → 原子替换。
#                               替换用 File.Replace/Move（同卷原子），进程在替换前中断时旧文件保持可读。
#   Get-JsonDocumentBackupPath  统一备份路径（<Path>.bak）。
#
# 依赖：lib\paths.ps1（存在时附加隔离守卫；缺省不影响功能）。
if (-not (Get-Command Assert-AarNoProductionPath -ErrorAction SilentlyContinue)) {
    $__pathsFile = Join-Path $PSScriptRoot 'paths.ps1'
    if (Test-Path $__pathsFile) { . $__pathsFile }
}

function Get-JsonDocumentBackupPath([string]$Path) { return ($Path + '.bak') }

# 读：返回 @{ Path; Status; Data; Bytes; Error }
function Read-JsonDocument([string]$Path) {
    $r = [pscustomobject]@{ Path = $Path; Status = 'missing'; Data = $null; Bytes = [long]0; Error = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { $r.Status = 'missing'; $r.Error = 'empty path'; return $r }
    if (-not (Test-Path $Path)) { return $r }
    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        $r.Bytes = [long]$fi.Length
    } catch { }
    $raw = ''
    try { $raw = [string](Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop) } catch {
        $r.Status = 'corrupt'; $r.Error = $_.Exception.Message; return $r
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { $r.Status = 'empty'; return $r }
    try {
        $data = $raw | ConvertFrom-Json
        $r.Status = 'valid'; $r.Data = $data; return $r
    } catch {
        $r.Status = 'corrupt'; $r.Error = $_.Exception.Message; return $r
    }
}

# 写：原子替换 + 备份。返回 @{ Ok; Bytes; BackupPath; Error; Path }
function Write-JsonDocumentAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Data,
        [int]$Depth = 12,
        [switch]$NoBackup
    )
    $res = [pscustomobject]@{ Ok = $false; Bytes = [long]0; BackupPath = ''; Error = ''; Path = $Path }
    Assert-AarNoProductionPath -Path $Path -Operation 'write state file'
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $payload = ''
    try { $payload = ($Data | ConvertTo-Json -Depth $Depth) } catch {
        $res.Error = 'serialize-failed: ' + $_.Exception.Message; return $res
    }
    if ($null -eq $payload) { $payload = 'null' }
    $enc = New-Object System.Text.UTF8Encoding($true)
    $tmp = $Path + '.tmp-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [System.IO.File]::WriteAllText($tmp, $payload, $enc)
        # 回读校验：必须能解析回来，且内容非空。校验失败 ⇒ 不动目标文件。
        $back = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($back)) { throw 'tmp file is empty' }
        $null = $back | ConvertFrom-Json
        $tmpLen = [long](Get-Item -LiteralPath $tmp).Length
        if ($tmpLen -le 0) { throw 'tmp file is empty' }
        if ((Test-Path $Path) -and -not $NoBackup) {
            $backup = Get-JsonDocumentBackupPath $Path
            Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction SilentlyContinue
            $res.BackupPath = $backup
        }
        if (Test-Path $Path) {
            # File.Replace 是同卷原子替换。并发读者可能短暂持有目标文件 ⇒ 先重试几次；
            # 仍失败才退回 Move-Item -Force（该回退在目标被独占时可能先删后改名，故只作最后手段）。
            $replaced = $false
            for ($attempt = 0; $attempt -lt 3 -and -not $replaced; $attempt++) {
                try {
                    [System.IO.File]::Replace($tmp, $Path, $null)
                    $replaced = $true
                } catch {
                    if ($attempt -lt 2) { Start-Sleep -Milliseconds 25 }
                }
            }
            if (-not $replaced) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
        $res.Ok = $true
        $res.Bytes = [long](Get-Item -LiteralPath $Path).Length
        return $res
    } catch {
        $res.Error = $_.Exception.Message
        return $res
    } finally {
        if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# 便捷读：只取数据，并可选校验顶层字段是否存在（缺字段视为 corrupt，避免把结构变更当成空账本）。
function Read-JsonDocumentField {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Field = '')
    $doc = Read-JsonDocument $Path
    if ($doc.Status -eq 'valid' -and $Field) {
        if (-not ($doc.Data.PSObject.Properties.Name -contains $Field)) {
            $doc.Status = 'corrupt'
            $doc.Error = ('missing field: ' + $Field)
        }
    }
    return $doc
}
