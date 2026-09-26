# lib/doc.ps1 - 买家文档获取与解析: CDP 页面上下文 fetch(带登录态) 优先 → PS HttpWebRequest 兜底
#              → 临时文件(%TEMP%\alibaba_docs, 用后即删) → tools\doc-reader 解析。
# 依赖: config.ps1, lib\cdp.ps1(Invoke-CdpEval, 由调用方 dot-source), lib\log.ps1(可选)。

# [FIX-ENVBLOCK 2026-09-25] Start-ProcessClean 定义在 lib\cdp.ps1。调用方(monitor.ps1)会先 dot-source cdp.ps1,
# 这里做一次带守卫的兜底加载,避免单独引用 doc.ps1 时因函数缺失而整条文档解析路径静默失败。
if (-not (Get-Command Start-ProcessClean -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "cdp.ps1") }

function Get-DocTempDir {
    $d = Join-Path $env:TEMP "alibaba_docs"
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

# 文件名净化: 保留扩展名, 去除路径/非法字符, 长度限 80
function Get-SafeDocName([string]$name) {
    if (-not $name) { return "file.bin" }
    $base = Split-Path $name -Leaf
    $base = $base -replace '[\\/:*?"<>|]', '_'
    $base = ($base -replace '\s+', ' ').Trim()
    if ($base.Length -gt 80) {
        $ext = [System.IO.Path]::GetExtension($base)
        $base = $base.Substring(0, [Math]::Max(1, 80 - $ext.Length)) + $ext
    }
    if (-not $base) { return "file.bin" }
    return $base
}

function Save-DocTempFile([string]$name, [byte[]]$bytes) {
    $dir = Get-DocTempDir
    $safe = Get-SafeDocName $name
    $path = Join-Path $dir ((Get-Date -Format 'HHmmss') + "_" + $safe)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Remove-DocTemp([string]$path) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

# CDP 页面上下文 fetch → base64(≤MaxBytes); 失败/超限返回 $null。需调用方已 dot-source lib\cdp.ps1。
function Get-DocumentBase64ViaCdp([string]$url, [int]$MaxBytes = 10485760) {
    if (-not $url) { return $null }
    $esc = $url.Replace('\','\\').Replace("'","\'")
    $js = @"
(async function(){
  try {
    var r = await fetch('$esc', {credentials:'include'});
    if (!r.ok) return 'FETCH_FAIL:' + r.status;
    var buf = await r.arrayBuffer();
    if (buf.byteLength > $MaxBytes) return 'TOO_BIG:' + buf.byteLength;
    var bytes = new Uint8Array(buf);
    var bin = '';
    for (var i = 0; i < bytes.length; i += 8192) { bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192)); }
    return 'OK:' + btoa(bin);
  } catch(e) { return 'ERR:' + (e && e.message ? e.message : 'fetch failed'); }
})()
"@
    try {
        $out = Invoke-CdpEval $js
        if (-not $out) { return $null }
        $out = $out.Trim()
        if ($out -match '^OK:(.+)$') { return $Matches[1] }
        return $null
    } catch { return $null }
}

# PS 兜底下载 → base64(≤MaxBytes, 10s); 失败/超限返回 $null
function Get-DocumentBase64ViaHttp([string]$url, [int]$MaxBytes = 10485760, [int]$TimeoutSec = 10) {
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
            return [Convert]::ToBase64String($ms.ToArray())
        } finally { $resp.Dispose() }
    } catch { return $null }
}

# 调用 doc-reader 组件解析本地文件; 返回组件 JSON 对象或 $null(超时/失败/JSON 错)
function Invoke-DocReader([string]$filePath, [int]$MaxChars = 6000, [int]$RenderMaxPages = 2) {
    if (-not $filePath -or -not (Test-Path -LiteralPath $filePath)) { return $null }
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $reader = Join-Path $root "tools\doc-reader\read.js"
    if (-not (Test-Path $reader)) { return $null }
    $outFile = Join-Path $env:TEMP ("docread_" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        # [FIX-ENVBLOCK 2026-09-25] 改用 Start-ProcessClean(.NET 直启 + 去重环境块):
        #   原 Start-Process 带 -RedirectStandard* 在本机必抛 NO_PROXY 异常,整条文档解析路径失效。
        #   子进程 stdout 由父进程异步排空后按 UTF-8 落盘到同一 $outFile(与旧 cmd 级重定向字节等价,
        #   node 输出即 UTF-8),下游 Test-Path/Get-Content 逻辑不变。
        $docArgs = @('"' + $reader + '"', '"' + $filePath + '"', '--max-chars', [string]$MaxChars, '--render-max-pages', [string]$RenderMaxPages)
        $p = Start-ProcessClean -FilePath 'node.exe' -ArgumentList $docArgs -RedirectStandardOutput $outFile -RedirectStandardError (Join-Path $env:TEMP "docread_err.tmp") -WaitSeconds 30
        if (-not $p.HasExited) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            return $null
        }
        if (-not (Test-Path $outFile)) { return $null }
        $json = Get-Content $outFile -Raw -Encoding UTF8
        if (-not $json) { return $null }
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $env:TEMP "docread_err.tmp") -Force -ErrorAction SilentlyContinue
    }
}
