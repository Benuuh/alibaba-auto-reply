# okki/okki_lib.ps1 - OKKI 链路公共库(spec §5.7)。
#   职责:配置读取与校验 / 页内 fetch 封装(Invoke-OkkiApi) / 分页拉取 /
#         字段映射(ISO→中文国别) / 状态读写(幂等第②层) / 日志。
#   依赖:scripts\config.ps1(Get-SkillConfig/Get-SkillPath)、scripts\lib\log.ps1(Write-SkillLog)、
#         本目录 okki_cdp.ps1(专用 CDP 桥;禁止调用 scripts 根下的共享桥 —— C4/A4)。
#   编码:UTF8-BOM(C1);写 JSON 一律无 BOM(C2)。
#   隐私:禁止记录 cookie/token/账号密码,禁止整包转存 API 响应(C7)。

# ---------------------------------------------------------------- 配置层

# C5:flow_id/stage_id/来源/跟进人一律读 config,禁止脚本内写死与示例 id 兜底
function Get-OkkiConfig {
    $cfg = Get-SkillConfig
    return [pscustomobject]@{
        CdpPort      = if ($cfg.okki_cdp_port) { [int]$cfg.okki_cdp_port } else { 0 }
        Profile      = [string]$cfg.okki_profile
        BaseUrl      = [string]$cfg.okki_base_url
        FlowId       = [string]$cfg.okki_flow_id
        StageId      = [string]$cfg.okki_stage_id
        DefaultOrigin= [string]$cfg.okki_default_origin
        IntervalMs   = if ($null -ne $cfg.okki_write_interval_ms) { [int]$cfg.okki_write_interval_ms } else { 0 }
        PageSize     = if ($cfg.okki_page_size) { [int]$cfg.okki_page_size } else { 0 }
    }
}

function Assert-OkkiConfig([switch]$ForWrite) {
    $c = Get-OkkiConfig
    $need = @("okki_cdp_port","okki_profile","okki_base_url","okki_flow_id","okki_stage_id","okki_default_origin","okki_page_size")
    if ($ForWrite) { $need += "okki_write_interval_ms" }
    foreach ($k in $need) {
        $v = (Get-SkillConfig).$k
        if ($null -eq $v -or ([string]$v).Trim() -eq "") {
            throw "OKKI-CONFIG-MISSING: $k"
        }
    }
    if ($c.CdpPort -lt 1 -or $c.CdpPort -gt 65535) { throw "OKKI-CONFIG-INVALID: okki_cdp_port=$($c.CdpPort)" }
    if ($c.PageSize -lt 1) { throw "OKKI-CONFIG-INVALID: okki_page_size=$($c.PageSize)" }
    if ($c.Profile -notmatch 'okki') { throw "OKKI-CONFIG-INVALID: okki_profile 未指向独立 profile: $($c.Profile)" }
    if ($c.CdpPort -eq 9222) { throw "OKKI-CONFIG-INVALID: okki_cdp_port 不得为现役 9222(C5/N2)" }
    return $c
}

# ---------------------------------------------------------------- 路径 / 日志

function Get-OkkiDir([string]$which) {
    switch ($which) {
        "logs" { return (Get-SkillPath "logs") }
        "data" { return (Get-SkillPath "data") }
        "reports" { return (Get-SkillPath "reports") }
        default { return (Get-SkillPath "scripts") }
    }
}

function Get-OkkiLogFile { return (Join-Path (Get-OkkiDir "logs") "okki_sync.log") }
function Get-OkkiStateFile { return (Join-Path (Get-OkkiDir "data") "okki_opp_state.json") }
function Get-OkkiCountryFile { return (Join-Path $PSScriptRoot "country_names.json") }

# 全部日志写入 logs\okki_sync.log(§5.8)
function Write-OkkiLog([string]$msg) {
    $lf = Get-OkkiLogFile
    if (-not (Test-Path (Split-Path $lf -Parent))) { New-Item -ItemType Directory -Path (Split-Path $lf -Parent) -Force | Out-Null }
    Write-SkillLog $msg $lf
    Write-Host $msg
}

# ---------------------------------------------------------------- CDP 封装

function Invoke-OkkiCdpRaw {
    param([string]$Action, [string]$Url, [string]$Js)
    $cdp = Join-Path $PSScriptRoot "okki_cdp.ps1"
    if (-not (Test-Path $cdp)) { throw "OKKI-CDP-ERROR: 缺少 $cdp" }
    $args2 = @("-ExecutionPolicy","Bypass","-NoProfile","-File",$cdp,"-Action",$Action)
    if ($Action -eq "navigate") { $args2 += @("-Url",$Url) }
    if ($Action -eq "eval") {
        # Base64 传输:避免 JS/JSON 正文在命令行层被拆碎
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Js))
        $args2 += @("-ScriptB64",$b64)
    }
    $out = & powershell @args2 2>&1
    return ($out -join "`n")
}

function Invoke-OkkiCdpEval {
    param([string]$Js)
    $out = Invoke-OkkiCdpRaw -Action "eval" -Js $Js
    if ($LASTEXITCODE -ne 0 -or $out -match 'OKKI-CDP-ERROR:') {
        throw ("OKKI-CDP-ERROR: " + $out)
    }
    return $out
}

function Test-OkkiCdpReady {
    param([int]$Port = 0)
    $c = Get-OkkiConfig
    $p = if ($Port -gt 0) { $Port } else { $c.CdpPort }
    if ($p -lt 1) { return $false }
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/json/version" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

# ---- 页内 fetch 封装(C3):必须在已登录页面上下文发起 POST/GET,带 x-requested-with ----

function Get-OkkiApiUrl([string]$path) {
    $c = Get-OkkiConfig
    if ($path -match '^https?://') { return $path }
    $b = $c.BaseUrl.TrimEnd('/')
    if ($path.StartsWith('/')) { return ($b + $path) }
    return ($b + '/' + $path)
}

# JS 字面量:Base64 → 页内自解(UTF-8 安全,且不依赖页面已有任何全局函数)。
# 正文不做 shell 转义,避免长中文/JSON 在命令行层被拆碎。
function Get-JsB64Literal([string]$s) {
    if ($null -eq $s) { $s = "" }
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
    return ("(function(b){var s=atob(b);var u=new Uint8Array(s.length);for(var i=0;i<s.length;i++){u[i]=s.charCodeAt(i);}return new TextDecoder('utf-8').decode(u);})('" + $b64 + "')")
}

# 页内 fetch;返回解析后的 data 对象(PSObject)或 $null;失败抛 OKKI-API-ERROR
# 支持两种调用:
#   Invoke-OkkiApi -Path <path> -Method GET  -Query <pscustomobject>
#   Invoke-OkkiApi -Path <path> -Method POST -Form  <pscustomobject>   # form-urlencoded
#   Invoke-OkkiApi -Path <path> -Method POST -JsonBody <pscustomobject> # application/json
function Invoke-OkkiApi {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Method = "POST",
        [object]$Query = $null,
        [object]$Form = $null,
        [object]$JsonBody = $null,
        [int]$TimeoutSec = 30
    )
    $url = Get-OkkiApiUrl $Path
    $q = ""
    if ($Query) {
        $pairs = @()
        foreach ($pr in $Query.PSObject.Properties) {
            $pairs += ((Escape-UriComponent $pr.Name) + "=" + (Escape-UriComponent ([string]$pr.Value)))
        }
        if ($pairs.Count -gt 0) { $q = "?" + ($pairs -join "&") }
    }
    $bodyKind = "none"
    $bodyJs = "null"
    if ($Form) {
        $bodyKind = "form"
        $pairs = @()
        foreach ($pr in $Form.PSObject.Properties) {
            $pairs += ((Escape-UriComponent $pr.Name) + "=" + (Escape-UriComponent ([string]$pr.Value)))
        }
        $bodyJs = Get-JsB64Literal ($pairs -join "&")
    } elseif ($JsonBody) {
        $bodyKind = "json"
        $bodyJs = Get-JsB64Literal (ConvertTo-OkkiJson $JsonBody)
    }
    $uJs = Get-JsB64Literal ($url + $q)
    $mEsc = $Method.ToUpper()
    $js = @"
(async function(){
  try {
    var opt = { method: '$mEsc', credentials: 'include', headers: { 'x-requested-with': 'XMLHttpRequest' } };
    var bk = '$bodyKind';
    if (bk === 'form') { opt.headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'; opt.body = $bodyJs; }
    else if (bk === 'json') { opt.headers['Content-Type'] = 'application/json; charset=UTF-8'; opt.body = $bodyJs; }
    var ctl = new AbortController();
    var tid = setTimeout(function(){ ctl.abort(); }, $($TimeoutSec * 1000));
    var r;
    try { r = await fetch($uJs, Object.assign(opt, { signal: ctl.signal })); }
    finally { clearTimeout(tid); }
    var text = await r.text();
    if (!r.ok) { return JSON.stringify({ __ok:false, __status:r.status, __body:text.substring(0,400) }); }
    var j = null;
    try { j = JSON.parse(text); } catch(e) { return JSON.stringify({ __ok:false, __status:r.status, __body:'NOT_JSON:' + text.substring(0,400) }); }
    return JSON.stringify({ __ok:true, __status:r.status, d:j });
  } catch(e) {
    return JSON.stringify({ __ok:false, __status:-1, __body:'FETCH_ERR:' + (e && e.message ? e.message : 'unknown') });
  }
})()
"@
    $out = Invoke-OkkiCdpEval $js
    $env = $null
    try { $env = $out | ConvertFrom-Json } catch { throw "OKKI-API-ERROR: 页内返回非 JSON($Path)" }
    if (-not $env.__ok) {
        $snippet = [string]$env.__body
        # 只留短片段用于诊断,禁止整包转存(C7);同时剔除可能出现的凭据字样
        $snippet = ($snippet -replace '(?i)(cookie|token|password|passwd|api_key|sk-)[^,;"''\s]*', '$1=<redacted>')
        if ($snippet.Length -gt 240) { $snippet = $snippet.Substring(0,240) }
        throw "OKKI-API-ERROR: $Path HTTP $($env.__status) $snippet"
    }
    return $env.d
}

# ---------------------------------------------------------------- 分页拉取

# 响应包裹层探测:实测到真实路径后由 okki_probe.ps1 落定,这里按顺序尝试已知键。
# 返回 $null 表示"这层没有列表"(无法判定),由调用方继续尝试其它路径。
function Get-OkkiListByPath($Obj, [string]$Path) {
    $node = $Obj
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        $node = Get-OkkiRecValue $node $seg
    }
    if ($null -eq $node) { return $null }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) { return $node }
    return $null
}

function Get-OkkiTotalByPath($Obj, [string]$Path) {
    $node = $Obj
    foreach ($seg in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        $node = Get-OkkiRecValue $node $seg
    }
    return $node
}

$script:OkkiListPaths  = @("data.list","data.rows","data.data","list","rows","result.list","data.result.list","data.items","data.records")
$script:OkkiTotalPaths = @("data.total","data.total_count","data.count","total","data.totalCount","data.pagination.total")

# 拉取「商机阶段为空」的客户单页(附录 §四.1 的筛选原文)
function Get-OkkiCompanyPage {
    param(
        [int]$Page = 1,
        [int]$PageSize = 0,
        [string]$ExtraFilters = "",
        [switch]$NoFilter,
        [switch]$Raw
    )
    $c = Assert-OkkiConfig
    if ($PageSize -le 0) { $PageSize = $c.PageSize }
    $form = New-OkkiOrderedDict
    $form["filter_type"] = "3"
    $form["criteria_type"] = "1"
    $idx = 0
    if (-not $NoFilter) {
        # filters[0][field]=stage & operator=is_null & object_name=objOpportunity & refer_type=9 & field_type=3
        $form["filters[$idx][field]"] = "stage"
        $form["filters[$idx][operator]"] = "is_null"
        $form["filters[$idx][object_name]"] = "objOpportunity"
        $form["filters[$idx][refer_type]"] = "9"
        $form["filters[$idx][field_type]"] = "3"
        $idx++
    }
    $form["curPage"] = [string]$Page
    $form["pageSize"] = [string]$PageSize
    $form["show_field_key"] = "company.private.list.field"
    $form["swarm_id"] = "1"
    $form["need_count"] = "true"
    if ($ExtraFilters) {
        # 追加筛选:形如 "filters[1][field]=x&filters[1][operator]=y"
        foreach ($kv in $ExtraFilters.Split('&')) {
            if ($kv -match '^(.+?)=(.*)$') { $form[$Matches[1]] = $Matches[2] }
        }
    }
    $resp = Invoke-OkkiApi -Path "/api/customerV3Read/companyList" -Method POST -Form $form
    $list = $null; $usedList = ""
    foreach ($p in $script:OkkiListPaths) {
        $l = Get-OkkiListByPath $resp $p
        if ($null -ne $l) { $list = $l; $usedList = $p; break }
    }
    $total = $null; $usedTotal = ""
    foreach ($p in $script:OkkiTotalPaths) {
        $t = Get-OkkiTotalByPath $resp $p
        if ($null -ne $t) { $total = $t; $usedTotal = $p; break }
    }
    if ($null -eq $list) {
        # 把响应里出现过的顶层键名报出来(键名不是值,无 PII),便于实测定位
        $keys = @()
        if ($resp) { $keys = @($resp.PSObject.Properties.Name) }
        $inner = @()
        if ($resp -and $resp.data) { $inner = @($resp.data.PSObject.Properties.Name) }
        throw "OKKI-SHAPE-UNKNOWN: companyList 未匹配到列表路径; 顶层键=[$($keys -join ',')] data键=[$($inner -join ',')]"
    }
    return [pscustomobject]@{
        List      = @($list)
        Total     = $total
        Count     = @($list).Count
        Page      = $Page
        PageSize  = $PageSize
        ListPath  = $usedList
        TotalPath = $usedTotal
        FormKeys  = @($form.Keys)
        Raw       = $resp
    }
}

# 拉全部候选(逐页);$Limit<=0 表示不限制
function Get-OkkiCandidates {
    param([int]$Limit = 0, [int]$PageSize = 0)
    $c = Assert-OkkiConfig
    if ($PageSize -le 0) { $PageSize = $c.PageSize }
    $all = New-Object 'System.Collections.ArrayList'
    $page = 1
    $total = $null
    $listPath = ""
    $totalPath = ""
    $guard = 0
    while ($true) {
        $guard++
        if ($guard -gt 500) { throw "OKKI-PAGING-GUARD: 超过 500 页,疑似分页参数无效(死循环保护)" }
        $p = Get-OkkiCompanyPage -Page $page -PageSize $PageSize
        if ($page -eq 1) { $total = $p.Total; $listPath = $p.ListPath; $totalPath = $p.TotalPath }
        if ($p.Count -eq 0) { break }
        foreach ($r in $p.List) { [void]$all.Add($r) }
        if ($Limit -gt 0 -and $all.Count -ge $Limit) { break }
        if ($total -and ($page * $PageSize) -ge [int]$total) { break }
        if ($p.Count -lt $PageSize) { break }
        $page++
    }
    return [pscustomobject]@{
        Records   = $all
        Total     = $total
        ListPath  = $listPath
        TotalPath = $totalPath
        Pages     = $page
    }
}

# ---------------------------------------------------------------- JSON 工具(C2/中文安全)

function ConvertTo-OkkiJson {
    param([Parameter(Mandatory=$true)][object]$Obj)
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 33554432
    $json = $ser.Serialize($Obj)
    # PS 空数组会被序列化成 null;submitOpportunity 的 product_list 必须是 [](附录 §四.3)
    if ($json -eq "null") { $json = "{}" }
    return $json
}

function New-OkkiOrderedDict { return (New-Object 'System.Collections.Specialized.OrderedDictionary') }

# 无 BOM 写 JSON(C2)
function Write-OkkiJsonNoBom([string]$Path, [object]$Obj) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-OkkiJson $Obj
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Escape-UriComponent([string]$s) {
    if ($null -eq $s) { return "" }
    return [System.Uri]::EscapeDataString($s)
}

# ---------------------------------------------------------------- 登录态判定

# 返回一段 JS(字符串结果,调用方 ConvertFrom-Json)。
# 判据全部为 DOM 事实,禁止凭想象断言"已登录":
#   loginForm = 存在 password 输入框 / 登录页 URL 特征
#   loggedIn  = host 属本站 且 无登录表单 且 页面已非空白(有可见节点)
function Get-OkkiLoginStateJs {
    $js = @'
(function(){
  try {
    var host = location.host || '';
    var path = location.pathname || '/';
    var q = location.search || '';
    var pwd = document.querySelectorAll('input[type=password]').length;
    var loginHost = /^login\./i.test(host);
    var loginPath = /(^|\/)(login|signin|sign-in|passport|sso)(\/|$)/i.test(path);
    var body = document.body;
    var visible = body ? body.querySelectorAll('*').length : 0;
    var title = document.title || '';
    var loginForm = (pwd > 0) || loginHost || loginPath;
    /* 只认 crm. 主站为业务站;login.* 一律判未登录。query 不参与输出(可能含 ticket/token) */
    var isSite = /^crm\.xiaoman\.cn$/i.test(host);
    var loggedIn = isSite && !loginForm && visible > 50;
    var reason = 'pwdInputs=' + pwd + ';loginHost=' + loginHost + ';loginPath=' + loginPath + ';nodes=' + visible + ';title=' + title.substring(0,40);
    return JSON.stringify({ loggedIn: loggedIn, loginForm: loginForm, isSite: isSite, host: host, path: path.substring(0,80), nodes: visible, title: title.substring(0,60), reason: reason });
  } catch(e) {
    return JSON.stringify({ loggedIn:false, loginForm:false, isSite:false, host:'', path:'', nodes:0, title:'', reason:'JS_ERR:' + (e && e.message ? e.message : 'unknown') });
  }
})()
'@
    return $js
}

# ---------------------------------------------------------------- 国别字典(S4)

function Get-OkkiCountryMap {
    $f = Get-OkkiCountryFile
    if (-not (Test-Path $f)) { throw "OKKI-DICT-MISSING: $f" }
    $raw = Get-Content $f -Raw -Encoding UTF8
    $o = $raw | ConvertFrom-Json
    $map = @{}
    foreach ($p in $o.countries.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
    return $map
}

# ISO→中文;未知返回 $null(调用方按 SKIP-UNKNOWN-COUNTRY 跳过,禁止猜 —— §5.6)
function Get-OkkiCountryName([string]$iso) {
    if (-not $iso) { return $null }
    $key = $iso.Trim().ToUpperInvariant()
    if ($key.Length -ne 2) { return $null }
    $map = Get-OkkiCountryMap
    if ($map.ContainsKey($key)) { return $map[$key] }
    return $null
}

# ---- 客户记录字段抽取(R7:所有字段路径集中在此处) ----
# 字段名一律来自实测(okki_probe.ps1 打印真实键名),禁止凭附录想象(C10/N6)。
# 抽取顺序:优先"显式 ISO 字段名",再退化到候选键;任何候选值都必须通过
# "∈ 字典 或 ^[A-Za-z]{2}$"校验才被采纳。

function Get-OkkiRecValue($Rec, [string]$Key) {
    if ($null -eq $Rec) { return $null }
    $p = $Rec.PSObject.Properties[$Key]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $null
}

# 客户名:按实测键名顺序取第一个非空
function Get-OkkiCompanyName($Rec) {
    foreach ($k in @("name","company_name","customer_name","companyName","full_name")) {
        $v = Get-OkkiRecValue $Rec $k
        if ($v -and ([string]$v).Trim() -ne "") { return ([string]$v).Trim() }
    }
    return $null
}

# 国别:返回 ISO 或 $null(不猜)
function Get-OkkiCompanyIso($Rec, [hashtable]$Map, [hashtable]$ZhToIso) {
    $explicit = @("country","country_code","country_iso","country_code_iso","countryCode","countryIso","country_iso_code")
    foreach ($k in $explicit) {
        $v = Get-OkkiRecValue $Rec $k
        if ($null -eq $v) { continue }
        $r = Resolve-OkkiIso $v $ZhToIso
        if ($r -and $Map.ContainsKey($r)) { return $r }
    }
    $loose = @("country_id","country_name","country_text","nation","nationality","area_code")
    foreach ($k in $loose) {
        $v = Get-OkkiRecValue $Rec $k
        if ($null -eq $v) { continue }
        $r = Resolve-OkkiIso $v $ZhToIso
        if ($r -and $Map.ContainsKey($r)) { return $r }
    }
    return $null
}

# 主联系人 id:列表字段 main_customer(附录 §四.2);缺失由调用方兜底 detail 接口
function Get-OkkiMainCustomer($Rec) {
    foreach ($k in @("main_customer","mainCustomer","main_customer_id","main_contact","contact_id")) {
        $v = Get-OkkiRecValue $Rec $k
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v.Trim() -eq "") { continue }
        return $v
    }
    return $null
}

# 跟进人 user_id(Q5:缺省用当前用户)
function Get-OkkiFollowerId($Rec) {
    foreach ($k in @("user_id","main_user","follower_id","owner_id","charge_user_id","handler_id")) {
        $v = Get-OkkiRecValue $Rec $k
        if ($v -and ([string]$v).Trim() -ne "") { return $v }
    }
    return $null
}

# 客户来源(Q4):从客户记录抽取候选值
function Get-OkkiOriginCandidate($Rec) {
    foreach ($k in @("origin_list","origin","source","source_list","customer_source","origin_id")) {
        $v = Get-OkkiRecValue $Rec $k
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v.Trim() -eq "") { continue }
        return $v
    }
    return $null
}

# 从 detail 响应里取主联系人 id(兜底路径)
function Get-OkkiContactFromDetail($Detail) {
    $cands = @()
    foreach ($path in @("data.main_customer","data.contact_list","data.contacts","data.customer_list","main_customer","contact_list","contacts")) {
        $node = $Detail
        $ok = $true
        foreach ($seg in $path.Split('.')) {
            if ($null -eq $node) { $ok = $false; break }
            $node = Get-OkkiRecValue $node $seg
        }
        if ($ok -and $null -ne $node) { $cands += $node }
    }
    foreach ($c in $cands) {
        if ($c -is [System.Collections.IEnumerable] -and $c -isnot [string]) {
            foreach ($item in $c) {
                $id = Get-OkkiRecValue $item "customer_id"
                if (-not $id) { $id = Get-OkkiRecValue $item "id" }
                if ($id) { return $id }
            }
        } else {
            $id = Get-OkkiRecValue $c "customer_id"
            if (-not $id) { $id = Get-OkkiRecValue $c "id" }
            if ($id) { return $id }
            if ($c -is [string] -or $c -is [int] -or $c -is [long]) { return $c }
        }
    }
    return $null
}

# 从任意形态的国别值里取 ISO:
#   "US" / "us" / "美国" / {value:'US'} / {code:'US'} / {country:'US'} / [..]
# 取不到返回 $null(不猜)
function Resolve-OkkiIso($countryVal, [hashtable]$ZhToIso) {
    if ($null -eq $countryVal) { return $null }
    if ($countryVal -is [System.Collections.IEnumerable] -and $countryVal -isnot [string]) {
        foreach ($item in $countryVal) {
            $r = Resolve-OkkiIso $item $ZhToIso
            if ($r) { return $r }
        }
        return $null
    }
    if ($countryVal -is [psobject] -and $countryVal -isnot [string]) {
        foreach ($k in @("value","code","country","iso","country_code","alpha2","id","key")) {
            $p = $countryVal.PSObject.Properties[$k]
            if ($p -and $null -ne $p.Value -and ([string]$p.Value).Trim() -ne "") {
                $r = Resolve-OkkiIso $p.Value $ZhToIso
                if ($r) { return $r }
            }
        }
        return $null
    }
    $s = ([string]$countryVal).Trim()
    if ($s -eq "") { return $null }
    if ($s -match '^[A-Za-z]{2}$') { return $s.ToUpperInvariant() }
    if ($ZhToIso -and $ZhToIso.ContainsKey($s)) { return $ZhToIso[$s] }
    return $null
}

function Get-OkkiZhToIso([hashtable]$Map) {
    $rev = @{}
    foreach ($k in $Map.Keys) { if (-not $rev.ContainsKey($Map[$k])) { $rev[$Map[$k]] = $k } }
    return $rev
}

# ---------------------------------------------------------------- 状态层(幂等第②层,§5.3)

function Read-OkkiState {
    $f = Get-OkkiStateFile
    if (-not (Test-Path $f)) {
        return [pscustomobject]@{ created = [pscustomobject]@{}; failed = [pscustomobject]@{}; runs = @() }
    }
    try {
        $raw = Get-Content $f -Raw -Encoding UTF8
        $o = $raw | ConvertFrom-Json
        foreach ($k in @("created","failed","runs")) {
            if (-not $o.PSObject.Properties[$k]) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $(if ($k -eq "runs") { @() } else { [pscustomobject]@{} }) -Force }
        }
        return $o
    } catch {
        throw "OKKI-STATE-CORRUPT: $f ($($_.Exception.Message))"
    }
}

# 无 BOM 落盘(C2);调用方保证 state 结构完整
function Write-OkkiState($State) {
    Write-OkkiJsonNoBom (Get-OkkiStateFile) $State
}

function New-OkkiState {
    $s = [pscustomobject]@{}
    $s | Add-Member -NotePropertyName created -NotePropertyValue (New-OkkiOrderedDict) -Force
    $s | Add-Member -NotePropertyName failed -NotePropertyValue (New-OkkiOrderedDict) -Force
    $s | Add-Member -NotePropertyName runs -NotePropertyValue (New-Object 'System.Collections.ArrayList') -Force
    return $s
}

function Add-OkkiStateCreated($State, [string]$CompanyId, [string]$OpportunityId, [string]$Name) {
    $State.created[$CompanyId] = [pscustomobject]@{
        opportunity_id = $OpportunityId
        name = $Name
        at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    Write-OkkiState $State   # C8:每条成功后立即落盘
}

function Add-OkkiStateFailed($State, [string]$CompanyId, [string]$Reason) {
    $State.failed[$CompanyId] = [pscustomobject]@{
        reason = $Reason
        at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    Write-OkkiState $State
}

function Add-OkkiStateRun($State, $RunRec) {
    [void]$State.runs.Add($RunRec)
    # 只保留最近 20 次
    while ($State.runs.Count -gt 20) { $State.runs.RemoveAt(0) }
    Write-OkkiState $State
}

function Test-OkkiAlreadyCreated($State, [string]$CompanyId) {
    if (-not $CompanyId) { return $false }
    return ($State.created.PSObject.Properties.Name -contains $CompanyId)
}
