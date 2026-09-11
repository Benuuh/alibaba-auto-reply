# lib/vision.ps1 - 买家图片/文档附件识别: 下载→data URL→多模态构造→提取解析→sidecar。
# 纯函数区(可单测): ConvertTo-DataUrl / Remove-AttachmentMarkers / New-VisionContentParts /
#                   Get-VisionExtract / Get-VisionExtractFile / Save-VisionExtract / Get-VisionSidecar。
# 下载区: Get-ImageDataUrl(图片, ≤2MB/10s) / Get-DocumentBase64(文档, CDP 优先, 见 lib\doc.ps1)。
# 依赖: config.ps1(Get-SkillPath "data")。
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")

function ConvertTo-DataUrl([byte[]]$bytes, [string]$mime) {
    if (-not $bytes -or $bytes.Length -eq 0) { return $null }
    if (-not $mime) { $mime = 'image/png' }
    return ("data:" + $mime + ";base64," + [Convert]::ToBase64String($bytes))
}

# 剥离 @@IMG/@@FILE 附件标记(快照/hash 前调用; 标记不参与 hash, 快照格式不变)
function Remove-AttachmentMarkers([string]$text) {
    if (-not $text) { return $text }
    return ($text -replace '\s*@@IMG:[^\s]*','' -replace '\s*@@FILE:[^\s]*','')
}

# 多模态消息内容: text 首位 + 最多 3 张图(超出忽略)
function New-VisionContentParts([string[]]$dataUrls, [string]$text) {
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add(@{ type = 'text'; text = [string]$text })
    $n = 0
    foreach ($u in @($dataUrls)) {
        if (-not $u) { continue }
        if ($n -ge 3) { break }
        [void]$parts.Add(@{ type = 'image_url'; image_url = @{ url = [string]$u } })
        $n++
    }
    return @($parts)
}

# 解析提取 JSON: 白名单 weight_kg/dims/cartons/tracking/note; 仅保留非空; 单值 ≤120 字符; 失败 $null
function Get-VisionExtract([string]$llmText) {
    if (-not $llmText) { return $null }
    $t = $llmText.Trim()
    $t = $t -replace '^```(json)?\s*','' -replace '\s*```$',''
    $m = [regex]::Match($t, '\{[\s\S]*\}')
    if (-not $m.Success) { return $null }
    try { $o = $m.Value | ConvertFrom-Json } catch { return $null }
    if (-not $o) { return $null }
    $fields = @{}
    foreach ($k in @('weight_kg', 'dims', 'cartons', 'tracking', 'note')) {
        if ($o.PSObject.Properties.Name -contains $k) {
            $v = [string]$o.$k
            $v = $v.Trim()
            if ($v.Length -gt 0) {
                if ($v.Length -gt 120) { $v = $v.Substring(0, 120) }
                $fields[$k] = $v
            }
        }
    }
    if ($fields.Count -eq 0) { return $null }
    return $fields
}

function Get-VisionExtractFile([string]$buyer, [string]$dataDir = "") {
    if (-not $dataDir) { $dataDir = Get-SkillPath "data" }
    if (-not $buyer) { return $null }
    $key = ($buyer.Trim().ToLowerInvariant() -replace '[\\/:*?"<>|]', '_')
    if (-not $key) { return $null }
    return (Join-Path (Join-Path $dataDir "vision_extract") ($key + ".json"))
}

# 合并写入 sidecar(已有字段保留, 新字段覆盖; 追加 source/file/updated)
function Save-VisionExtract([string]$buyer, $fields, [string]$source, [string]$fileName, [string]$dataDir = "") {
    if (-not $fields -or $fields.Count -eq 0) { return $null }
    $file = Get-VisionExtractFile $buyer $dataDir
    if (-not $file) { return $null }
    $dir = Split-Path $file -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cur = @{}
    if (Test-Path $file) {
        try {
            $o = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $cur[$p.Name] = $p.Value }
        } catch {}
    }
    foreach ($k in $fields.Keys) { $cur[$k] = $fields[$k] }
    if ($source) { $cur['source'] = $source }
    if ($fileName) { $cur['file'] = $fileName }
    $cur['updated'] = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    try { $cur | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8 } catch { return $null }
    return $file
}

# 读取 sidecar(损坏/缺失返回 $null)
function Get-VisionSidecar([string]$buyer, [string]$dataDir = "") {
    $file = Get-VisionExtractFile $buyer $dataDir
    if (-not $file -or -not (Test-Path $file)) { return $null }
    try { return (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# 图片下载 → data URL(≤MaxBytes, 超时/失败返回 $null)
function Get-ImageDataUrl([string]$url, [int]$MaxBytes = 2097152, [int]$TimeoutSec = 10) {
    if (-not $url) { return $null }
    try {
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($url)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        try { $req.Headers.Add('Referer', 'https://onetalk.alibaba.com/') } catch {}
        $resp = $req.GetResponse()
        try {
            if ($resp.ContentLength -gt $MaxBytes) { return $null }
            $ms = New-Object System.IO.MemoryStream
            $stream = $resp.GetResponseStream()
            $buf = New-Object byte[] 65536
            $total = 0
            while (($read = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                $total += $read
                if ($total -gt $MaxBytes) { return $null }
                $ms.Write($buf, 0, $read)
            }
            if ($ms.Length -eq 0) { return $null }
            $mime = 'image/png'
            if ($url -match '(?i)\.jpe?g(\?|$)') { $mime = 'image/jpeg' }
            elseif ($url -match '(?i)\.gif(\?|$)') { $mime = 'image/gif' }
            elseif ($url -match '(?i)\.webp(\?|$)') { $mime = 'image/webp' }
            return (ConvertTo-DataUrl $ms.ToArray() $mime)
        } finally { $resp.Dispose() }
    } catch { return $null }
}
