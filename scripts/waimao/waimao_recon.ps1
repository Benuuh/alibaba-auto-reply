# waimao/waimao_recon.ps1 - 网易外贸通接口侦察器(只读,零写入)。
#   目的:在不猜接口的前提下,把「客户发现/联系人挖掘」真实调用的 URL+请求体 原样抓出来。
#   原理:向已登录页面注入 fetch/XHR 劫持钩子(__wmRecon),之后你在页面上正常点一次
#         「搜索客户 / 挖邮箱 / 看联系人」,钩子把每次调用记进 window.__wmRecon.log。
#         再用 -Action dump 取回。这不是逆向:是记录你自己会话里的真实请求。
#
#   安全:仅记录 path(不含域)与请求体;Authorization/Cookie 一律不记录(C7)。
#         全程只读页面,不点击、不提交任何表单、不写平台数据。
#
#   用法:
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\waimao\waimao_recon.ps1 -Action install
#     ... 在浏览器里手工操作「客户发现」页面若干次 ...
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\waimao\waimao_recon.ps1 -Action dump
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\waimao\waimao_recon.ps1 -Action report
#     powershell -ExecutionPolicy Bypass -NoProfile -File scripts\waimao\waimao_recon.ps1 -Action clear
#   编码:UTF8-BOM(C1)。
param(
    [Parameter(Mandatory=$true)][ValidateSet("install","dump","report","clear","status")][string]$Action,
    [int]$Port = 0,
    [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) "config.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\log.ps1")
# 注意:不要 dot-source waimao_cdp.ps1 —— 它带 Mandatory 参数且 body 即主逻辑,
#       source 会立刻执行并因缺参报错。此处只把它当子进程调用(见 Invoke-WmCdpEval)。

if (-not $OutFile) { $OutFile = Join-Path (Split-Path (Split-Path $here -Parent) -Parent) "logs\waimao_recon.json" }

# 端口:与 waimao_cdp.ps1 同口径
if ($Port -le 0) {
    $cfg = Get-SkillConfig
    if ($cfg.waimao_cdp_port) { $Port = [int]$cfg.waimao_cdp_port } else { $Port = 9224 }
}

function Invoke-WmCdpEval([string]$js) {
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($js))
    $out = powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $here "waimao_cdp.ps1") -Action eval -Port $Port -ScriptB64 $b64 2>&1
    return ($out -join "`n")
}

# ---- 注入钩子:劫持 fetch + XMLHttpRequest,只记 path/方法/请求体/状态 ----
$jsInstall = @'
(function(){
  if (window.__wmRecon && window.__wmRecon.installed) { return "ALREADY-INSTALLED n=" + window.__wmRecon.log.length; }
  var R = { installed: true, t0: Date.now(), log: [] };
  var MAX = 4000;
  function push(rec){ if (R.log.length < MAX) R.log.push(rec); }
  function pathOf(u){
    try { var x = new URL(u, location.href); return x.pathname + (x.search || ""); }
    catch(e){ return String(u).substring(0,300); }
  }
  function bodyOf(b){
    if (b == null) return "";
    try {
      if (typeof b === "string") return b.substring(0, 4000);
      if (b instanceof URLSearchParams) return b.toString().substring(0, 4000);
      if (b instanceof FormData) { var o = []; b.forEach(function(v,k){ o.push(k + "=" + String(v).substring(0,300)); }); return o.join("&").substring(0,4000); }
      if (typeof b === "object") return JSON.stringify(b).substring(0, 4000);
      return String(b).substring(0, 1000);
    } catch(e){ return "(unserializable)"; }
  }
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
        if (res.status === 429) { rec.warn = "RATE-LIMITED-429"; }
        push(rec);
        return res;
      }, function(err){ rec.s = -1; rec.err = String(err).substring(0,200); push(rec); throw err; });
    };
  }
  // ---- XMLHttpRequest ----
  // 注意:loadend 在部分失败路径(同步抛错/abort/被 CSP 拦)不触发,记录会丢。
  //       故改为"去重 push + 超时兜底":事件到了就记真实状态,事件没到也必落一条。
  var OX = window.XMLHttpRequest;
  if (OX) {
    var oOpen = OX.prototype.open, oSend = OX.prototype.send;
    OX.prototype.open = function(m, u){ this.__wm = { m: String(m||"GET").toUpperCase(), u: u }; return oOpen.apply(this, arguments); };
    OX.prototype.send = function(b){
      var self = this, info = this.__wm || {};
      var rec = { k: "xhr", at: Date.now() - R.t0, m: info.m || "GET", p: pathOf(info.u || ""), b: bodyOf(b), s: 0 };
      var pushed = false;
      function settle(){
        if (pushed) { return; }
        pushed = true;
        try { rec.s = self.status; } catch(e) { rec.s = 0; }
        if (rec.s === 429) { rec.warn = "RATE-LIMITED-429"; }
        push(rec);
      }
      try {
        this.addEventListener("loadend", settle);
        this.addEventListener("error", settle);
        this.addEventListener("abort", settle);
        this.addEventListener("timeout", settle);
      } catch(e) {}
      // 兜底:5 秒内事件都没来也落一条,避免请求凭空消失
      try { setTimeout(settle, 5000); } catch(e) {}
      return oSend.apply(this, arguments);
    };
  }
  window.__wmRecon = R;
  return "INSTALLED at " + location.host + location.pathname;
})()
'@

$jsDump = @'
(function(){
  var R = window.__wmRecon;
  if (!R) { return JSON.stringify({ installed: false, log: [] }); }
  return JSON.stringify({ installed: true, count: R.log.length, url: location.href.substring(0,200), log: R.log });
})()
'@

$jsClear = @'
(function(){ if (window.__wmRecon) { window.__wmRecon.log = []; window.__wmRecon.t0 = Date.now(); return "CLEARED"; } return "NOT-INSTALLED"; })()
'@

$jsStatus = @'
(function(){
  var R = window.__wmRecon;
  return JSON.stringify({ installed: !!(R && R.installed), count: R ? R.log.length : 0, url: location.href.substring(0,200), title: document.title });
})()
'@

switch ($Action) {
    "install" {
        $r = Invoke-WmCdpEval $jsInstall
        Write-Output ("INSTALL -> " + $r)
        if ($r -match 'INSTALLED|ALREADY-INSTALLED') { Write-Output "下一步:到浏览器里正常操作「客户发现」页面(搜索客户、点挖邮箱、看联系人),然后跑 -Action dump" }
    }
    "status" {
        Write-Output (Invoke-WmCdpEval $jsStatus)
    }
    "clear" {
        Write-Output (Invoke-WmCdpEval $jsClear)
    }
    "dump" {
        $raw = Invoke-WmCdpEval $jsDump
        if ($raw -notmatch '(?s)\{.*\}') { Write-Output "DUMP-FAILED: $raw"; exit 1 }
        $json = $Matches[0]
        $dir = Split-Path $OutFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        $o = $json | ConvertFrom-Json
        Write-Output ("DUMP-OK file=" + $OutFile + " count=" + $o.count)
    }
    "report" {
        if (-not (Test-Path $OutFile)) { Write-Output "NO-DUMP: 先跑 -Action dump"; exit 2 }
        $o = (Get-Content $OutFile -Raw) | ConvertFrom-Json
        Write-Output ("页面: " + $o.url)
        Write-Output ("抓取条数: " + $o.count)
        Write-Output ""
        # 按 path 归并(去掉 query,便于看接口全集)
        $rows = @{}
        foreach ($e in @($o.log)) {
            $p = [string]$e.p
            $base = ($p -split '\?')[0]
            $key = ([string]$e.m) + " " + $base
            if (-not $rows.ContainsKey($key)) {
                $rows[$key] = [pscustomobject]@{ Method = $e.m; Path = $base; Hits = 0; Status = @(); Sample = ""; Warn = "" }
            }
            $rows[$key].Hits++
            $rows[$key].Status += [string]$e.s
            if (-not $rows[$key].Sample -and $e.b) { $rows[$key].Sample = ([string]$e.b).Substring(0, [Math]::Min(300, ([string]$e.b).Length)) }
            if ($e.warn) { $rows[$key].Warn = [string]$e.warn }
        }
        $rows.Values | Sort-Object -Property Hits -Descending | Format-Table -AutoSize -Property Hits, Method, Path, Warn
        Write-Output "`n=== 含请求体的接口样本(前 12 条) ==="
        $i = 0
        foreach ($r in ($rows.Values | Where-Object { $_.Sample } | Sort-Object -Property Hits -Descending)) {
            $i++; if ($i -gt 12) { break }
            Write-Output ("--- [{0}] {1} {2}" -f $r.Hits, $r.Method, $r.Path)
            Write-Output ("    body: " + $r.Sample)
        }
        Write-Output "`n=== 命中路径关键词的接口(客户发现/联系人/邮箱) ==="
        $rows.Values | Where-Object { $_.Path -match 'search|contact|email|mail|company|customs|clue|lead|grub|deep|dcm|trade|buyer' } | Sort-Object -Property Hits -Descending | Format-Table -AutoSize -Property Hits, Method, Path
        $rl = @($o.log | Where-Object { $_.warn })
        if ($rl.Count -gt 0) { Write-Output ("`n[!] 命中 429 风控 " + $rl.Count + " 次 —— 自动化频率必须保守(见方案'风控与合规'一节)") }
    }
}
