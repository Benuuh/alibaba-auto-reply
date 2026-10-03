# gonghai/gonghai_recon.ps1 - 阿里后台「公海」操作记录器(只读,零写入)。
#
#   目的(§6-S1):在不猜网页结构的前提下,把公海链路上**真实发生**的请求与 DOM 事实抓下来。
#   原理:向已登录页面注入 fetch/XHR 劫持钩子,
#         之后在页面上正常操作,钩子把每次调用的 path/方法/请求体/状态记进 window.__ghRecon.log,
#         再用 -Action dump 取回。**这不是逆向:是记录你自己会话里的真实请求。**
#
#   安全(§4-11/§4-12):
#     - 仅记录 **path(不含域)** 与请求体;**Authorization / Cookie 一律不记录**。
#     - 响应只记录 path + code/msg 三元组(白名单提取),**不记录响应体原文**(避免 PII 落盘)。
#       OneTalk 搜索接口可能在 **XHR 响应体**里返回客户名,故响应体只做白名单提取,绝不整存。
#     - 全程只读页面:不点击、不提交、不写平台数据。
#
#   用法:
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_recon.ps1 -Action install
#     ... 在浏览器里正常操作公海页面 ...
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_recon.ps1 -Action dump
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_recon.ps1 -Action status
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_recon.ps1 -Action report -Filter 'claim|customer'
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_recon.ps1 -Action clear
#   编码:UTF8-BOM(§4-6)。
param(
    [Parameter(Mandatory=$true)][ValidateSet("install","dump","report","clear","status")][string]$Action,
    [string]$OutFile = "",
    [string]$Filter = "",       # 仅 report:按 path 正则过滤(便于只看某一类动作)
    [switch]$ForceReinstall     # install:先删除旧钩子再装(改了钩子实现后必须用,否则旧闭包仍在)
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) "config.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\log.ps1")
. (Join-Path $here "gonghai_cdp.ps1")

if (-not $OutFile) { $OutFile = Join-Path $env:TEMP "gonghai_20260926\recon_dump.json" }

# ---- 注入钩子:劫持 fetch + XMLHttpRequest,只记 path/方法/请求体/状态(+白名单响应三元组) ----
#     使用公海专用变量名 __ghRecon,避免覆盖同页的其他记录器。
$jsInstall = @'
(function(){
  if (window.__ghRecon && window.__ghRecon.installed) { return "ALREADY-INSTALLED n=" + window.__ghRecon.log.length; }
  var R = { installed: true, t0: Date.now(), log: [] };
  var MAX = 1200;
  function push(rec){ if (R.log.length < MAX) { R.log.push(rec); } }
  function pathOf(u){
    try { var x = new URL(u, location.href); return x.pathname + (x.search || ""); }
    catch(e){ return String(u).substring(0,300); }
  }
  function bodyOf(b){
    if (b == null) return "";
    try {
      if (typeof b === "string") return scrub(b.substring(0, 2000));
      if (b instanceof URLSearchParams) return scrub(b.toString().substring(0, 2000));
      if (b instanceof FormData) { var o = []; b.forEach(function(v,k){ o.push(k + "=" + String(v).substring(0,200)); }); return scrub(o.join("&").substring(0,2000)); }
      if (typeof b === "object") return scrub(JSON.stringify(b).substring(0, 2000));
      return scrub(String(b).substring(0, 500));
    } catch(e){ return "(unserializable)"; }
  }
  // ⚠️ 凭据擦除(2026-09-27 01:0x 实测教训):
  //   本站请求体里**真的带凭据** —— 实测见到 `_csrf=<uuid>`、`_csrf_token_=<uuid>`、
  //   `chatToken=<长串>`(AliIM 打开会话用的凭据),以及 urlencode 后的同名参数。
  //   这些既不是 Authorization 也不是 Cookie 头,原实现会把它们原样落盘 ⇒ 违反 §4-11。
  //   ⇒ 所有请求体在记录前统一擦除;只保留"参数名 + 已擦除",便于核对参数形状。
  function scrub(s){
    if (typeof s !== "string" || !s) return s;
    var KEYS = ["chatToken","_csrf_token_","_csrf_token","_csrf","csrfToken","csrf","accessToken","authToken","jsessionid","sessionId","signedKey"];
    var out = s;
    for (var i = 0; i < KEYS.length; i++) {
      var k = KEYS[i];
      var reJson = new RegExp('("' + k + '"\\s*:\\s*")([^"]*)(")', 'gi');
      out = out.replace(reJson, '$1<REDACTED>$3');
      var reQs = new RegExp('(^|[?&]|%22|"|,)' + k + '(=|%3D|%22%3A%22)([^&"\\s]*)', 'gi');
      out = out.replace(reQs, '$1' + k + '$2<REDACTED>');
    }
    return out;
  }
  // 响应侧:只做白名单三元组提取,绝不整存响应体(可能含客户 PII)
  function metaOf(s){
    var m = { code: null, msg: "", keys: "" };
    try {
      if (typeof s !== "string" || !s) return m;
      var t = s.replace(/^\uFEFF/, "").trim();
      if (t.charAt(0) !== "{") return m;
      var o = JSON.parse(t);
      if (o && typeof o === "object") {
        ["code","resultCode","success","message","msg","errorMsg","errorCode","total","totalCount"].forEach(function(k){
          if (o[k] !== undefined && o[k] !== null && typeof o[k] !== "object") {
            m[k === "message" || k === "msg" || k === "errorMsg" ? "msg" : k] = String(o[k]).substring(0,120);
          }
        });
        var dk = Object.keys(o);
        m.keys = dk.slice(0, 14).join(",");
        // 只有当响应顶层**就是**列表时才记条数(count-only,不记内容)
        var arrKey = null;
        ["data","result","list","records"].forEach(function(k){
          if (!arrKey && Array.isArray(o[k])) { arrKey = k; }
        });
        if (arrKey) { m.n = o[arrKey].length; }
        else if (o.data && typeof o.data === "object") {
          ["list","records","dataSource","content"].forEach(function(k){
            if (!m.n && Array.isArray(o.data[k])) { m.n = o.data[k].length; }
          });
        }
      }
    } catch(e){}
    return m;
  }
  function say(v){ try { return String(v).substring(0,160); } catch(e){ return "?"; } }
  // ---- fetch ----
  var of = window.fetch;
  if (of) {
    window.fetch = function(input, init){
      var url = (typeof input === "string") ? input : (input && input.url) || "";
      var method = ((init && init.method) || (input && input.method) || "GET").toUpperCase();
      var body = bodyOf(init && init.body);
      var rec = { k: "fetch", at: Date.now() - R.t0, m: method, p: pathOf(url), b: body, s: 0 };
      return of.apply(this, arguments).then(function(res){
        rec.s = res.status;
        try {
          res.clone().text().then(function(t){
            var m = metaOf(t);
            if (m.code !== null) { rec.code = m.code; }
            if (m.msg) { rec.msg = m.msg; }
            if (m.keys) { rec.rk = m.keys; }
            if (m.n !== undefined) { rec.n = m.n; }
            if (m.total !== undefined) { rec.total = m.total; }
            if (m.totalCount !== undefined) { rec.totalCount = m.totalCount; }
            if (m.success !== undefined) { rec.ok = m.success; }
            rec.rlen = t ? t.length : 0;
          }).catch(function(){});
        } catch(e) {}
        if (res.status === 429) { rec.warn = "RATE-LIMITED-429"; }
        push(rec);
        return res;
      }, function(err){ rec.s = -1; rec.err = say(err); push(rec); throw err; });
    };
  }
  // ---- XMLHttpRequest ----
  // 注意:loadend 在部分失败路径(同步抛错/abort/被 CSP 拦)不触发 ⇒ 去重 push + 5s 超时兜底。
  var OX = window.XMLHttpRequest;
  if (OX) {
    var oOpen = OX.prototype.open, oSend = OX.prototype.send;
    OX.prototype.open = function(m, u){ this.__gh = { m: String(m||"GET").toUpperCase(), u: u }; return oOpen.apply(this, arguments); };
    OX.prototype.send = function(b){
      var self = this, info = this.__gh || {};
      var rec = { k: "xhr", at: Date.now() - R.t0, m: info.m || "GET", p: pathOf(info.u || ""), b: bodyOf(b), s: 0 };
      var pushed = false;
      function settle(){
        if (pushed) { return; }
        pushed = true;
        try { rec.s = self.status; } catch(e) { rec.s = 0; }
        try {
          if (rec.s !== 0) {
            var t = (self.responseType === "" || self.responseType === "text") ? self.responseText : "";
            var m = metaOf(t);
            if (m.code !== null) { rec.code = m.code; }
            if (m.msg) { rec.msg = m.msg; }
            if (m.keys) { rec.rk = m.keys; }
            if (m.n !== undefined) { rec.n = m.n; }
            if (m.total !== undefined) { rec.total = m.total; }
            if (m.totalCount !== undefined) { rec.totalCount = m.totalCount; }
            if (m.success !== undefined) { rec.ok = m.success; }
            rec.rlen = t ? t.length : 0;
          }
        } catch(e) {}
        if (rec.s === 429) { rec.warn = "RATE-LIMITED-429"; }
        push(rec);
      }
      try {
        this.addEventListener("loadend", settle);
        this.addEventListener("error", settle);
        this.addEventListener("abort", settle);
        this.addEventListener("timeout", settle);
      } catch(e) {}
      try { setTimeout(settle, 5000); } catch(e) {}
      return oSend.apply(this, arguments);
    };
  }
  window.__ghRecon = R;
  return "INSTALLED at " + location.host + location.pathname;
})()
'@

$jsDump = @'
(function(){
  var R = window.__ghRecon;
  var safe = location.href;
  try { var x = new URL(location.href); safe = x.origin + x.pathname; } catch(e) {}
  if (!R) { return JSON.stringify({ installed: false, count: 0, url: safe, log: [] }); }
  return JSON.stringify({ installed: true, count: R.log.length, url: safe, log: R.log });
})()
'@

$jsClear = @'
(function(){ if (window.__ghRecon) { window.__ghRecon.log = []; window.__ghRecon.t0 = Date.now(); return "CLEARED"; } return "NOT-INSTALLED"; })()
'@

$jsStatus = @'
(function(){
  var R = window.__ghRecon;
  var safe = location.href;
  try { var x = new URL(location.href); safe = x.origin + x.pathname; } catch(e) {}
  return JSON.stringify({ installed: !!(R && R.installed), count: R ? R.log.length : 0, url: safe, title: (document.title||'').substring(0,120) });
})()
'@

# 目标页:公海 CRM 域(两个域,**该域下所有标签页**)+ OneTalk(发消息链路在它上面)。
#   ⚠️ 必须取"全部匹配页"而不是第一个:实测 9222 上同时开着
#      i.alibaba.com/hub/alicrm/**my_customer** 与 .../public_customer 两个标签页,
#      只取第一个会把钩子装在 my_customer 上,而公海列表在 public_customer 上 ⇒ 抓不到东西。
function Get-ReconTargets {
    $out = @()
    $seen = @{}
    foreach ($pat in @('i\.alibaba\.com/hub/alicrm', 'alicrm\.alibaba\.com', 'onetalk\.alibaba\.com')) {
        foreach ($p in @(Get-GonghaiCdpPages | Where-Object { $_.url -match $pat })) {
            if (-not $seen.ContainsKey($p.id)) { $seen[$p.id] = $true; $out += $p }
        }
    }
    return $out
}

switch ($Action) {
    "install" {
        $targets = Get-ReconTargets
        if (@($targets).Count -eq 0) {
            Write-Output "NO-TARGET-PAGE: 没有找到公海页(i.alibaba.com/hub/alicrm 或 alicrm.alibaba.com),也没有 OneTalk 页"
            Write-Output "先在浏览器里打开公海页,再重跑 install"
            exit 1
        }
        foreach ($t in $targets) {
            $hostPath = ""
            try { $u = [Uri]$t.url; $hostPath = $u.Host + $u.AbsolutePath } catch { $hostPath = "(url-unparsable)" }
            try {
                if ($ForceReinstall) {
                    # 必须**先删除**旧钩子:install 在已安装时直接返回 ALREADY-INSTALLED,
                    # 不会替换实现 ⇒ 改了钩子代码(例如新增凭据擦除)却还是旧逻辑。
                    [void](Invoke-GonghaiEvalOnPage -Page $t -Script 'try{ delete window.__ghRecon; }catch(e){}; "PURGED"')
                }
                $r = Invoke-GonghaiEvalOnPage -Page $t -Script $jsInstall
                Write-Output ("PAGE " + $hostPath + " -> " + $r)
            } catch {
                Write-Output ("PAGE " + $hostPath + " -> HOOK-FAILED: " + $_.Exception.Message)
            }
        }
        Write-Output "下一步:在浏览器里正常操作公海页面,然后跑 -Action dump"
    }
    "status" {
        $targets = Get-ReconTargets
        if (@($targets).Count -eq 0) { Write-Output "NO-TARGET-PAGE"; exit 1 }
        foreach ($t in $targets) {
            try { Write-Output ((Invoke-GonghaiEvalOnPage -Page $t -Script $jsStatus)) }
            catch { Write-Output ("STATUS-FAILED: " + $_.Exception.Message) }
        }
    }
    "clear" {
        $targets = Get-ReconTargets
        if (@($targets).Count -eq 0) { Write-Output "NO-TARGET-PAGE"; exit 1 }
        foreach ($t in $targets) {
            try { Write-Output (Invoke-GonghaiEvalOnPage -Page $t -Script $jsClear) }
            catch { Write-Output ("CLEAR-FAILED: " + $_.Exception.Message) }
        }
    }
    "dump" {
        $targets = Get-ReconTargets
        if (@($targets).Count -eq 0) { Write-Output "NO-TARGET-PAGE"; exit 1 }
        $all = New-Object System.Collections.ArrayList
        $pages = New-Object System.Collections.ArrayList
        foreach ($t in $targets) {
            $hostPath = ""
            try { $u = [Uri]$t.url; $hostPath = $u.Host + $u.AbsolutePath } catch { $hostPath = "(url-unparsable)" }
            $raw = $null
            try { $raw = Invoke-GonghaiEvalOnPage -Page $t -Script $jsDump } catch { $raw = $null }
            if (-not $raw -or ($raw -notmatch '(?s)\{.*\}')) {
                [void]$pages.Add([pscustomobject]@{ page = $hostPath; installed = $false; count = 0; note = "dump-failed" })
                continue
            }
            $o = $Matches[0] | ConvertFrom-Json
            [void]$pages.Add([pscustomobject]@{ page = $hostPath; installed = [bool]$o.installed; count = [int]$o.count; note = "" })
            foreach ($e in @($o.log)) {
                [void]$all.Add([pscustomobject]@{
                    page = $hostPath
                    k    = [string]$e.k
                    at   = $e.at
                    m    = [string]$e.m
                    p    = [string]$e.p
                    b    = [string]$e.b
                    s    = $e.s
                    code = $e.code
                    msg  = $e.msg
                    rk   = $e.rk
                    n    = $e.n
                    rlen = $e.rlen
                    warn = $e.warn
                })
            }
        }
        $doc = [pscustomobject]@{
            version   = 1
            captured  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            pageCount = @($pages).Count
            pages     = @($pages)
            count     = @($all).Count
            log       = @($all)
        }
        $dir = Split-Path $OutFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $json = $doc | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Output ("DUMP-OK file=" + $OutFile + " count=" + @($all).Count)
        foreach ($p in @($pages)) { Write-Output ("  page=" + $p.page + " installed=" + $p.installed + " count=" + $p.count + " " + $p.note) }
    }
    "report" {
        if (-not (Test-Path $OutFile)) { Write-Output "NO-DUMP: 先跑 -Action dump"; exit 2 }
        $o = (Get-Content $OutFile -Raw -Encoding UTF8) | ConvertFrom-Json
        Write-Output ("dump 文件: " + $OutFile)
        Write-Output ("抓取时刻: " + $o.captured + "  总条数: " + $o.count)
        Write-Output ""
        Write-Output "=== 按 页/方法/path(去 query) 归并 ==="
        $rows = @{}
        foreach ($e in @($o.log)) {
            if ($Filter -and ([string]$e.p) -notmatch $Filter) { continue }
            $base = ([string]$e.p -split '\?')[0]
            $key = ([string]$e.page) + " || " + ([string]$e.m) + " " + $base
            if (-not $rows.ContainsKey($key)) {
                $rows[$key] = [pscustomobject]@{ Page = $e.page; Method = $e.m; Path = $base; Hits = 0; Status = @(); Code = @(); N = @(); RLen = @(); Warn = ""; Sample = "" }
            }
            $rows[$key].Hits++
            $rows[$key].Status += [string]$e.s
            if ($null -ne $e.code) { $rows[$key].Code += [string]$e.code }
            if ($null -ne $e.n) { $rows[$key].N += [string]$e.n }
            if ($null -ne $e.rlen) { $rows[$key].RLen += [string]$e.rlen }
            if (-not $rows[$key].Sample -and $e.b) { $rows[$key].Sample = ([string]$e.b).Substring(0, [Math]::Min(240, ([string]$e.b).Length)) }
            if ($e.warn) { $rows[$key].Warn = [string]$e.warn }
        }
        if ($rows.Count -eq 0) { Write-Output "(无匹配记录)"; exit 0 }
        $rows.Values | Sort-Object -Property Hits -Descending |
            Format-Table -AutoSize -Property Hits, Method, Path, Warn, @{n='N';e={ ($_.N | Select-Object -Unique) -join '/' }}, @{n='Code';e={ ($_.Code | Select-Object -Unique) -join '/' }} |
            Out-String -Width 400
        Write-Output "=== 含请求体的接口样本 ==="
        foreach ($r in ($rows.Values | Where-Object { $_.Sample } | Sort-Object -Property Hits -Descending)) {
            Write-Output ("--- [{0}x] {1} {2}  (page={3})" -f $r.Hits, $r.Method, $r.Path, $r.Page)
            Write-Output ("    body: " + $r.Sample)
        }
        $rl = @($o.log | Where-Object { $_.warn })
        if ($rl.Count -gt 0) { Write-Output ("`n[!] 命中 429 风控 " + $rl.Count + " 次") }
    }
}
