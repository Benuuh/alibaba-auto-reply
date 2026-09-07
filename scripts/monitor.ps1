param(
    [string]$Action = "start",
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"

# 集中配置:路径统一来自 config.json(config.ps1 提供加载器与默认回退);
# 回复引擎(规则/语言检测/信息核对)来自 reply_engine.ps1,与回归测试共用同一份代码。
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "reply_engine.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
. (Join-Path $PSScriptRoot "lib\send.ps1")
. (Join-Path $PSScriptRoot "lib\llm.ps1")
. (Join-Path $PSScriptRoot "lib\lock.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\quote.ps1")
. (Join-Path $PSScriptRoot "lib\no_reply.ps1")
$script:skillCfg = Get-SkillConfig
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:cdpScript = Get-SkillPath "cdp"
$script:ensureScript = Get-SkillPath "ensure"
$script:llmCfgFile = Get-SkillPath "llmcfg"

$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
$stateFile = Join-Path $LogDir "state.json"

# 发送前拦截安全兜底句（spec 禁词拦截 Phase 4）：命中禁词且重写仍越线/引擎路径命中时整体替换；纯 ASCII，非空保证
$script:banSafeFallback = "Thanks for your patience! I'll finalize your quote and get back to you shortly."

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# 切换到"待回复"标签并返回是否成功
function Switch-ToPendingTab() {
    $js = @"
(function(){
  var tab = Array.from(document.querySelectorAll('.list-tab-item')).find(function(t){ return (t.innerText||'').trim() === '待回复'; });
  if (!tab) return 'NO_TAB';
  var active = (tab.className||'').toString().indexOf('active') >= 0;
  if (!active) tab.click();
  return active ? 'ALREADY_ACTIVE' : 'SWITCHED';
})()
"@
    return Invoke-CdpEval $js
}

function Get-Snapshot() {
    # 先切到待回复标签并等待列表刷新，再抓取会话列表
    $tabRes = Switch-ToPendingTab
    Start-Sleep -Seconds 2
    # 页面刚 reload 时"待回复"标签可能尚未渲染（NO_TAB），
    # 此时抓取会误拿到"全部/已读"标签的历史列表，导致 Open-Convo 全部 NOT_FOUND。
    # 等待 3 秒后重试切换，确保列表来源正确
    if ($tabRes -eq 'NO_TAB') {
        Start-Sleep -Seconds 3
        Switch-ToPendingTab | Out-Null
        Start-Sleep -Seconds 2
    }
    $js = @"
(function(){
  // 抓取会话列表（优先 innerText，回退 textContent 兼容虚拟滚动）
  var items = Array.from(document.querySelectorAll('.contact-item-container'));
  var arr = [];
  items.forEach(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var name = (nameEl && nameEl.innerText && nameEl.innerText.trim()) || '';
    var txt = (e.innerText || '').replace(/\n+/g,' ').replace(/\s+/g,' ').trim();
    if (!name && txt.length < 2) return;
    if (!name) {
      var lines = txt.split(' ');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].length >= 3 || /[A-Za-z]{2,}/.test(lines[i])) { name = lines[i].substring(0,30); break; }
      }
    }
    var stable = txt.replace(/\d{1,2}:\d{2}/g,' ').replace(/\d{4}-\d{1,2}-\d{1,2}/g,' ').replace(/\s+/g,' ').trim();
    if (name) arr.push({unread: txt.indexOf('[未读]') >= 0, name: name.trim(), preview: stable.substring(0,80), full: txt.substring(0,200)});
  });
  // 按 name 去重：同一会话只保留一条，避免一次循环处理两次导致重复发送
  var seen = {};
  arr = arr.filter(function(it){ if (seen[it.name]) return false; seen[it.name] = true; return true; });
  if (arr.length > 0) return JSON.stringify(arr);
  // 列表为空：不在此处 reload（该提示文案常驻易误判），返回空由主循环连续空计数统一处理
  return '[]';
})()
"@
    $res = Invoke-CdpEval $js
    return $res
}



# P2.1a 合并:打开会话 + 会话名轮询校验 + 抓取消息 一次 eval 完成(JS Promise 轮询,cdp.ps1 awaitPromise:true)。
# 返回: 'NOT_FOUND' / 'SWITCH_TIMEOUT' / 解析失败标记 / 对象{name, msgs}(msgs 为 [BUYER]/[ME] 行文本)。
# 将原 5 次子进程调用(Open 1 + 校验 3 + 抓取 1)合并为 1 次,显著缩短扫描周期。
function Open-ConvoAndGetMessages([string]$keyword) {
    $esc = $keyword.Replace("\","\\").Replace("'","\'").Replace('"','\"')
    $js = @"
(async function(){
  var el = Array.from(document.querySelectorAll('.contact-item-container')).find(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var nameTxt = (nameEl && nameEl.innerText) || '';
    var full = (e.innerText || '') + '|' + nameTxt;
    return full.indexOf('$esc') >= 0;
  });
  if (!el) return 'NOT_FOUND';
  el.click();
  // 轮询校验会话名(最多 6 秒),防串台
  var current = '';
  for (var i = 0; i < 12; i++) {
    await new Promise(function(r){ setTimeout(r, 500); });
    var cands = [];
    var hdr = document.querySelector('.content-header');
    if (hdr) {
      var t = (hdr.innerText || '').trim().split('\n')[0].trim();
      if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
    }
    Array.from(document.querySelectorAll('[class*=header] [class*=name], [class*=Title], h1,h2,h3,[class*=contact-name]')).forEach(function(e){
      if (e.closest && e.closest('.alicrm-customer-detail-card')) return;
      var t = (e.innerText || '').trim();
      if (t && t.length < 60 && /[A-Za-z]/.test(t)) cands.push(t);
    });
    if (cands.length) {
      var best = cands[0];
      cands.forEach(function(c){ if (c.length > best.length) best = c; });
      current = best.split('\n')[0].trim();
    }
    if (current && (current.indexOf('$esc') >= 0 || '$esc'.indexOf(current) >= 0)) break;
  }
  if (!current) return 'SWITCH_TIMEOUT';
  // 抓取消息(保持 DOM 原始顺序)
  var out = [];
  document.querySelectorAll('[class*=message-item-wrapper]').forEach(function(w){
    var cls = (w.className||'').toString();
    var rich = w.querySelector('.content-with-translation.text-content, .session-rich-content');
    if (!rich) return;
    var txt = rich.innerText.replace(/\n+/g,' ').trim();
    var clean = txt.replace(/翻译中…|反馈|已读|回复|翻译|Revert|由阿里提供|自动接待发送/g,'').trim();
    var hasImg = !!w.querySelector('img[src*="alicdn"], [class*=image] img, [class*=Image] img, [class*=picture]');
    if (clean.length <= 2) {
      if (hasImg && (cls.indexOf('item-left') >= 0)) out.push({b:true, t:'[IMG]', ts:''});
      return;
    }
    var nameEl = w.querySelector('.item-base-info .name');
    var buyerName = (nameEl && nameEl.innerText.trim()) || '';
    var isBuyer = buyerName.length > 0 || /由阿里翻译提供|翻译中/.test(txt);
    if (!isBuyer) isBuyer = cls.indexOf('item-left') >= 0;
    var ts = '';
    var el2 = w;
    while (el2 && !el2.getAttribute('data-expinfo')) { el2 = el2.parentElement; }
    var exp = (el2 && el2.getAttribute('data-expinfo')) || '';
    var m = exp.match(/"showTime":(\d+)/);
    if (m) ts = m[1];
    if (!ts) {
      var baseEl = w.querySelector('.item-base-info');
      var baseTxt = (baseEl && baseEl.innerText) || '';
      var m2 = baseTxt.match(/(\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2})/);
      if (m2) ts = m2[1];
    }
    out.push({b: isBuyer, t: clean.substring(0,1000), ts: ts});
  });
  var lines = [];
  out.forEach(function(o){ lines.push((o.b ? '[BUYER] ' : '[ME] ') + o.t + (o.ts ? ' @@TS:' + o.ts : '')); });
  // P3.4 买家档案:抓取客户详情卡片原始文本(国家/注册时间/标签等),PS 侧解析
  var profile = '';
  var card = document.querySelector('.alicrm-customer-detail-card');
  if (card) { profile = (card.innerText || '').replace(/\n+/g,' ').replace(/\s+/g,' ').trim().substring(0, 300); }
  return JSON.stringify({name: current, msgs: lines.join('\n'), profile: profile});
})()
"@
    $res = Invoke-CdpEval $js
    $res = ($res -replace '^\s+|\s+$','')
    if ($res -eq 'NOT_FOUND' -or $res -eq 'SWITCH_TIMEOUT') { return $res }
    try {
        $obj = $res | ConvertFrom-Json
        if ($obj -and $obj.name) { return $obj }
    } catch {}
    return "PARSE_FAIL"
}

function Get-Rules() {
    $rulesFile = Join-Path $LogDir "reply_rules.json"
    if (Test-Path $rulesFile) {
        try {
            return Get-Content $rulesFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Log "Rules file parse error: $($_.Exception.Message)"
            return $null
        }
    }
    Write-Log "Rules file not found: $rulesFile"
    return $null
}


# LLM 配置：读取 llm_config.json（非敏感项）+ credentials.md（api_key，敏感信息铁律），未配置时返回 $null
$script:llmConfig = $null
function Get-LLMConfig {
    if ($script:llmConfig) { return $script:llmConfig }
    $cfgFile = $script:llmCfgFile
    if (Test-Path $cfgFile) {
        try {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # api_key 只从 credentials.md 读取（llm_config.json 不存任何敏感值）；
            # key 缺失时返回 $null 让调用方回退规则引擎（实际 key 注入在 libllm.ps1 的 Invoke-LLM 内部）
            $key = Get-CredentialValue 'api_key'
            if (-not $key) {
                Write-Log "LLM config: api_key missing in credentials.md"
                return $null
            }
            $script:llmConfig = $cfg
            return $cfg
        } catch {}
    }
    return $null
}

# 回复代理系统提示词（从 reply_agent_prompt.md 读取，带修改时间失效缓存）
$script:replyPromptCache = $null
$script:replyPromptCacheTime = $null
function Get-ReplyPrompt {
    $promptFile = Join-Path $LogDir "reply_agent_prompt.md"
    if (Test-Path $promptFile) {
        $fileTime = (Get-Item $promptFile).LastWriteTimeUtc.Ticks
        # 文件未修改且已有缓存 → 直接返回；否则重读
        if ($script:replyPromptCache -and $script:replyPromptCacheTime -eq $fileTime) { return $script:replyPromptCache }
        try {
            $script:replyPromptCache = Get-Content $promptFile -Raw -Encoding UTF8
            $script:replyPromptCacheTime = $fileTime
            return $script:replyPromptCache
        } catch {}
    }
    if ($script:replyPromptCache) { return $script:replyPromptCache }
    return "You are a professional logistics sales assistant replying to Alibaba.com buyers. Keep replies short and natural."
}

# 语料库内容（带修改时间失效缓存，用户编辑 reply_rules.json 后自动重读）
$script:rulesRawCache = $null
$script:rulesRawCacheTime = $null
function Get-RulesRaw {
    $rulesFile = Join-Path $LogDir "reply_rules.json"
    if (Test-Path $rulesFile) {
        $fileTime = (Get-Item $rulesFile).LastWriteTimeUtc.Ticks
        if ($script:rulesRawCache -and $script:rulesRawCacheTime -eq $fileTime) { return $script:rulesRawCache }
        try {
            $script:rulesRawCache = Get-Content $rulesFile -Raw -Encoding UTF8
            $script:rulesRawCacheTime = $fileTime
            return $script:rulesRawCache
        } catch {}
    }
    if ($script:rulesRawCache) { return $script:rulesRawCache }
    return ""
}

# LLM 生成回复：DeepSeek (OpenAI 兼容) API。失败返回 $null（由调用方回退规则引擎）
function Generate-Reply-LLM([object]$rules, [string]$convoName, [string]$latest, [string[]]$context, [switch]$BanRetry) {
    $cfg = Get-LLMConfig
    if (-not $cfg) { return $null }
    $rulesRaw = Get-RulesRaw
    $systemPrompt = (Get-ReplyPrompt) + "`n`n=== 语料库 reply_rules.json ===`n" + $rulesRaw
    if ($BanRetry) {
        # 发送前拦截重写（仅 LLM 路径 1 次）：系统提示词追加重写要求（默认不带，避免长系统提示）
        $systemPrompt += "`n`n[重写要求] 上一稿含被禁措辞，已弃用；重写：不得出现任何需上级确认的表述（manager/boss/supervisor/经理/上级/请示），一律改用正面承诺：正在核算并给出明确跟进时限（如 I'll finalize your exact quote and get back to you shortly.）。"
    }
    $ctxText = ($context | Select-Object -First 20) -join "`n"

    # A1 追问硬约束:统计 ME 侧问句按字段计数 + 买家承诺字段,结构化注入 LLM 上下文
    $askCount = @{ weight = 0; dimension = 0; address = 0; image = 0; supplier = 0 }
    foreach ($_line in $context) {
        if ($_line -match '^\[ME\]' -and $_line -match '[\?？]') {
            $lc = $_line.ToLower()
            if ($lc -match 'weight|kg|peso|公斤|千克|gross') { $askCount.weight++ }
            if ($lc -match 'dimension|size|尺寸|medida|cm\b|mm\b') { $askCount.dimension++ }
            if ($lc -match 'address|addr|地址|calle|street|endere|rua') { $askCount.address++ }
            if ($lc -match 'image|photo|picture|图片|图') { $askCount.image++ }
            if ($lc -match 'supplier|供应商|fornecedor|proveedor') { $askCount.supplier++ }
        }
    }
    # 承诺字段:买家说 will send/share/provide + 字段词 → 该字段不再问(逻辑与规则引擎共用 reply_engine.ps1 的 Get-PromisedFields)
    $promised = @(Get-PromisedFields $context)
    $metaLine = ""
    $askParts = @()
    foreach ($k in @('weight','dimension','address','image','supplier')) { if ($askCount[$k] -gt 0) { $askParts += "$k x$($askCount[$k])" } }
    if ($askParts.Count -gt 0) {
        $metaLine = "[追问统计] " + ($askParts -join ", ") + "。已问满 2 次的字段绝不再追问,转收尾等待语气;"
    }
    if ($promised.Count -gt 0) {
        $metaLine += "[承诺字段] " + ($promised -join ", ") + " 买家已承诺提供,绝不再问。"
    }
    # P3.4 买家档案:国家注入 LLM 上下文(个性化称呼/时效参考,无则省略)
    $profileLine = ""
    $bp = Get-BuyerProfile (Get-StateKey $convoName)
    if ($bp -and $bp.country) { $profileLine = "买家国家: $($bp.country)" }

    $userMsg = "买家名: $convoName`n$profileLine`n最新买家消息: $latest`n$metaLine`n`n=== 完整对话上下文（倒序，第一条最新） ===`n$ctxText"
    $messages = @(
        @{ role = "system"; content = $systemPrompt },
        @{ role = "user"; content = $userMsg }
    )
    return Invoke-LLM $messages ([double]$cfg.temperature) ([int]$cfg.max_tokens) $logFile
}


function Get-RepliedState {
    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    }
    # 主文件缺失时回退到备份
    $bak = Join-Path $LogDir "state.json.bak"
    if (Test-Path $bak) {
        try { return Get-Content $bak -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    }
    return $null
}


function Set-RepliedState([object]$state) {
    # 双写：主文件 + 备份，防止文件损坏/丢失导致 dedup 失效重复回复
    $json = $state | ConvertTo-Json -Depth 5
    Set-Content -Path $stateFile -Value $json -Encoding UTF8
    Set-Content -Path (Join-Path $LogDir "state.json.bak") -Value $json -Encoding UTF8
}

# 启动时清理：msgs 快照只保留最近 200 份，防止无限增长
function Cleanup-LegacyQueues {
    Get-ChildItem -Path $script:dataDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 200 | Remove-Item -Force -ErrorAction SilentlyContinue
}

# P3.4 买家档案:解析卡片原始文本,提取国家/注册时间,存 data\buyers\<key>.json(PII 仅本机,不入备份/仓库)
function Save-BuyerProfile([string]$skey, [string]$profileRaw) {
    if (-not $profileRaw) { return }
    $buyerDir = Join-Path $script:dataDir "buyers"
    if (-not (Test-Path $buyerDir)) { New-Item -ItemType Directory -Path $buyerDir -Force | Out-Null }
    $country = ""
    foreach ($c in @(
        @("Brazil","brazil|brasil"), @("United States","united states|usa|eua"), @("Mexico","mexico|m[eé]xico"),
        @("India","india"), @("Spain","spain|espa[añ]a"), @("France","france"), @("Italy","italy|italia"),
        @("Germany","germany|deutschland"), @("Nigeria","nigeria"), @("Argentina","argentina"),
        @("Chile","chile"), @("Peru","per[uú]"), @("Colombia","colombia"), @("UK","united kingdom|uk\b"),
        @("Canada","canada"), @("Pakistan","pakistan"), @("Turkey","turkey|t[uü]rkiye"), @("Egypt","egypt"),
        @("Vietnam","vietnam"), @("Philippines","philippines"), @("Indonesia","indonesia"),
        @("Saudi Arabia","saudi"), @("Russia","russia|r[uú]ssia"), @("Poland","poland"), @("Portugal","portugal")
    )) {
        if ($profileRaw -match $c[1]) { $country = $c[0]; break }
    }
    $regTime = ""
    $m = [regex]::Match($profileRaw, '(\d{4}[-/]\d{1,2}[-/]\d{1,2})')
    if ($m.Success) { $regTime = $m.Groups[1].Value }
    $fname = ($skey -replace '[^\w\-]','_') + ".json"
    $file = Join-Path $buyerDir $fname
    $profile = [pscustomobject]@{
        buyer = $skey
        country = $country
        registered = $regTime
        raw = $profileRaw
        updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $profile | ConvertTo-Json -Depth 3 | Set-Content -Path $file -Encoding UTF8
}

# 读取买家档案(内存缓存,文件 mtime 失效)
$script:__buyerProfileCache = @{}
$script:__buyerProfileCacheTime = @{}
function Get-BuyerProfile([string]$skey) {
    # 注意:Join-Path 只接受 2 个位置参数,多级路径必须嵌套或合并 ChildPath
    $f = Join-Path $script:dataDir (Join-Path "buyers" (($skey -replace '[^\w\-]','_') + ".json"))
    if (-not (Test-Path $f)) { return $null }
    $ft = (Get-Item $f).LastWriteTimeUtc.Ticks
    if ($script:__buyerProfileCache.ContainsKey($skey) -and $script:__buyerProfileCacheTime[$skey] -eq $ft) { return $script:__buyerProfileCache[$skey] }
    try {
        $p = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:__buyerProfileCache[$skey] = $p
        $script:__buyerProfileCacheTime[$skey] = $ft
        return $p
    } catch { return $null }
}

# A1 new inquiry wecom alert (24h throttle, state in data\inquiry_state.json)
function Send-NewInquiryAlert([string]$buyer, [string]$preview) {
    try {
        $isf = Join-Path $script:dataDir "inquiry_state.json"
        if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null }
        $st = $null
        if (Test-Path $isf) { try { $st = (Get-Content $isf -Raw -Encoding UTF8 | ConvertFrom-Json).pushed } catch { $st = $null } }
        $sk = $buyer.Trim().ToLowerInvariant()
        $prev = $null
        if ($st -and $st.PSObject.Properties.Name -contains $sk) { $prev = $st.$sk }
        if ($prev) {
            $ageH = 999
            try { $ageH = ((Get-Date) - ([datetime]::ParseExact([string]$prev, "yyyy-MM-dd HH:mm", $null))).TotalHours } catch {}
            if ($ageH -lt 24) { return }
        }
        $previewTxt = if ($preview) { [string]$preview } else { "(no preview)" }
        if ($previewTxt.Length -gt 120) { $previewTxt = $previewTxt.Substring(0, 120) + "..." }
        $msg = "[NEW-INQUIRY] $buyer" + [char]10 + $previewTxt
        $res = Send-WecomMessage $msg
        if ($res -eq "SENT_OK") {
            $new = @{}
            if ($st) { foreach ($p in $st.PSObject.Properties) { $new[$p.Name] = $p.Value } }
            $new[$sk] = (Get-Date -Format "yyyy-MM-dd HH:mm")
            @{ pushed = $new } | ConvertTo-Json -Depth 5 | Set-Content -Path $isf -Encoding UTF8
            Write-Log "INQUIRY-ALERT: $buyer -> $res"
        } else {
            Write-Log "INQUIRY-ALERT-FAIL: $buyer -> $res (will retry next cycle)"
        }
    } catch {
        Write-Log "INQUIRY-ALERT-ERR: $($_.Exception.Message)"
    }
}
function Invoke-LayoutMigration {
    if (-not (Test-Path $script:logFileDir)) { New-Item -ItemType Directory -Path $script:logFileDir -Force | Out-Null }
    if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Path $script:dataDir -Force | Out-Null }
    foreach ($name in @("monitor.log","monitor_out.log","monitor_err.log","watchdog.log")) {
        $src = Join-Path $LogDir $name
        $dst = Join-Path $script:logFileDir $name
        if ((Test-Path $src) -and -not (Test-Path $dst)) {
            Move-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -Path $LogDir -Filter "monitor_*.log" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path (Join-Path $script:logFileDir $_.Name))) {
            Move-Item -Path $_.FullName -Destination (Join-Path $script:logFileDir $_.Name) -Force -ErrorAction SilentlyContinue
        }
    }
    Get-ChildItem -Path $LogDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not (Test-Path (Join-Path $script:dataDir $_.Name))) {
            Move-Item -Path $_.FullName -Destination (Join-Path $script:dataDir $_.Name) -Force -ErrorAction SilentlyContinue
        }
    }
}
# CDP/Chrome 不可达自愈:连续 3 次错误则重启 Chrome 并重新登录(监控主循环 catch 与 CDP 掉线分支共用)
function Invoke-CdpSelfHeal {
    $script:cdpFailStreak++
    if ($script:cdpFailStreak -ge 3) {
        $script:cdpFailStreak = 0
        Write-Log "CDP fail x3 - running chrome_ensure.ps1..."
        $ensure = powershell -ExecutionPolicy Bypass -File $script:ensureScript 2>&1
        Write-Log "chrome_ensure result: $($ensure -join ' | ')"
        Start-Sleep -Seconds 10
        return $true
    }
    return $false
}

# P2.2 页面重载:释放写锁 → reload → 记时 → 清零失败计数(空闲/忙时两条触发路径共用)
function Invoke-PageReload([string]$reason) {
    Release-AppLock 'onetalk-write'
    $re = Invoke-CdpEval "location.reload(); 'RELOADED'"
    Write-Log ($reason + " - $re, waiting for reconnection")
    Start-Sleep -Seconds 12
    $script:lastReload = Get-Date
    $script:emptyStreak = 0
}

function Start-Monitor {
    # 单实例保护：PID 文件记录当前实例，重复启动时直接退出
    $pidFile = Join-Path $LogDir "monitor.pid"
    if (Test-Path $pidFile) {
        try {
            $oldPid = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$oldPid" -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -match 'powershell') {
                Write-Log "Another monitor instance already running (PID $oldPid) - exiting"
                exit 0
            }
        } catch {}
    }
    try { Set-Content -Path $pidFile -Value $PID -Encoding ASCII } catch {}
    try {
        # 退出时清理 PID 文件（正常退出路径；被强杀时由新实例检测失效 PID 覆盖）
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            Remove-Item -Path (Join-Path $LogDir "monitor.pid") -Force -ErrorAction SilentlyContinue
        } | Out-Null
    } catch {}
    # P2.4 容量治理：state 记录超阈值(200)且买家 30 天无快照活动 → 清理陈旧记录
    function Cleanup-StaleState {
        try {
            $st = Get-RepliedState
            if (-not $st -or -not $st.replied) { return }
            $names = @($st.replied.PSObject.Properties.Name)
            if ($names.Count -lt 200) { return }
            $cutoff = (Get-Date).AddDays(-30)
            $removed = @()
            foreach ($n in $names) {
                $latest = $null
                Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | Where-Object {
                    (Get-Content $_.FullName -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue) -eq ("# BUYER: " + $n)
                } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $latest = $_.LastWriteTime }
                if (-not $latest -or $latest -lt $cutoff) {
                    $st.replied.PSObject.Properties.Remove($n)
                    $removed += $n
                }
            }
            if ($removed.Count -gt 0) {
                Set-RepliedState $st
                Write-Log "STATE-CLEANUP: removed $($removed.Count) stale entries (total was $($names.Count))"
            }
        } catch {
            Write-Log "STATE-CLEANUP: error $($_.Exception.Message)"
        }
    }

    Invoke-LayoutMigration
    Write-Log "=== Monitor started (PID $PID, auto-reply engine built-in) ==="
    Cleanup-LegacyQueues
    Cleanup-StaleState
    $script:emptyStreak = 0
    $script:sendFailCount = @{}
    $script:failAlertAt = @{}
    $openCooldown = @{}
    $skipCooldown = @{}
    $script:noReplyPreview = @{}
    # P2.2 reload 按需化:OneTalk 长连接会失效,但无需每 2 分钟无条件刷新。
    # 仅当 (a)列表抓取失败连续 2 次(emptyStreak, 上方处理), 或 (b)空闲超过 reload_idle_min(默认10分钟),
    # 或 (c)持续忙处理超过 30 分钟 时才 reload。列表有新会话/预览变化视为活跃,重置 idle 计时。
    $script:reloadIdleMin = 10
    if ($script:skillCfg -and $script:skillCfg.reload_idle_min) { $script:reloadIdleMin = [int]$script:skillCfg.reload_idle_min }
    if ($script:reloadIdleMin -lt 3) { $script:reloadIdleMin = 3 }
    $script:lastReload = Get-Date
    $lastActivity = Get-Date
    # CDP 连续失败计数：达到阈值触发 Chrome 自愈（重启+重登）
    $script:cdpFailStreak = 0
    while ($true) {
        # P2.3 写互斥:与其他写者(如 nudge)互斥,避免并发操作同一页面。拿不到锁则本轮跳过。
        $lockHeld = Get-AppLock 'onetalk-write' 0
        if (-not $lockHeld) {
            Write-Log "LOCK-BUSY: onetalk-write held by another process, skipping round"
            Start-Sleep -Seconds 5
            continue
        }
        try {
            # 待回复板块 = 待办队列：板块里出现的每个会话都需要处理，回复后自动从板块消失。
            $snapRaw = Get-Snapshot
            $snap = $null
            if ($snapRaw -match '^\[') { $snap = $snapRaw | ConvertFrom-Json }
            if ($snap -and $snap.Count -gt 0) {
                $script:emptyStreak = 0
                $lastActivity = Get-Date
                $state = Get-RepliedState
                foreach ($item in $snap) {
                    if (-not $item.name) { continue }
                    $key = $item.name.Trim()
                    $skey = Get-StateKey $key
                    Write-Log "PROCESS convo from pending-list: $($key) | $($item.preview)"
                    # A1: new inquiry alert (24h throttle)
                    if (-not $state -or -not $state.replied -or ($state.replied.PSObject.Properties.Name -notcontains $skey)) {
                        Send-NewInquiryAlert $key $item.preview
                    }
                    # A5 人工接管白名单(NO-REPLY):名单买家不自动回复(LLM/规则/图片模板/QUICK 全跳过,不发送);
                    # 只读留痕(买家档案+msgs 快照)且不写 replied 去重状态 → 移出名单后自动恢复正常;
                    # 新消息仍由上方 A1 提醒主人(24h 节流);预览不变时后续轮免打扰跳过
                    if (Test-NoReplyBuyer $key) {
                        if ($script:noReplyPreview.ContainsKey($key) -and $script:noReplyPreview[$key] -eq $item.preview) {
                            Write-Log "TEMP-SKIP $($key): manual-override whitelist (preview unchanged, no auto reply)"
                            continue
                        }
                        $nrConvo = Open-ConvoAndGetMessages $key
                        if ($nrConvo -is [string]) {
                            Write-Log "NO-REPLY-SNAP-FAIL $($key): $nrConvo"
                            continue
                        }
                        if ($nrConvo.profile) { Save-BuyerProfile $skey $nrConvo.profile }
                        $nrLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
                        Add-Content -Path $nrLog -Value ("# BUYER: " + $key) -Encoding UTF8
                        Add-Content -Path $nrLog -Value $nrConvo.msgs -Encoding UTF8
                        $script:noReplyPreview[$key] = $item.preview
                        Write-Log "NO-REPLY-SNAPSHOT $($key): manual-override whitelist, snapshot kept, no auto reply"
                        continue
                    }
                    # dedup 跳过会话进冷却（3→6→12→15 分钟递增），预览变化（买家新消息）立即打破冷却
                    if ($skipCooldown.ContainsKey($key)) {
                        $co = $skipCooldown[$key]
                        $previewChanged = $co.preview -and ($co.preview -ne $item.preview)
                        if ($previewChanged) {
                            Write-Log "BREAK $($key): preview changed, cooldown lifted"
                            $skipCooldown.Remove($key)
                        } else {
                            $skipMins = [int]((Get-Date) - $co.time).TotalMinutes
                            # 冷却随重复命中次数递增（3→6→12→15 分钟封顶）：
                            # 已回复且无新消息的会话不必每 3 分钟重新打开一次，减少页面负担
                            $coolMin = [Math]::Min(3 * [Math]::Pow(2, ([int]$co.count - 1)), 15)
                            if ($skipMins -lt $coolMin) {
                                Write-Log "TEMP-SKIP $($key): dedup cooldown ${skipMins}m/${coolMin}m"
                                continue
                            } else {
                                $skipCooldown.Remove($key)
                            }
                        }
                    }
                    # 已打开失败的会话缓存在 blacklist 中，3 分钟内不重复尝试
                    if ($openCooldown.ContainsKey($key)) {
                        $skipMins = [int]((Get-Date) - $openCooldown[$key]).TotalMinutes
                        if ($skipMins -lt 3) {
                            Write-Log "TEMP-SKIP $($key): open failed recently (cooldown ${skipMins}m)"
                            continue
                        } else {
                            $openCooldown.Remove($key)
                        }
                    }
                    # P2.1a:打开+校验+抓消息合并为一次 eval(原 Open-Convo + 轮询 + Get-AllMessages 共 5 次调用)
                    $convo = Open-ConvoAndGetMessages $item.name
                    if ($convo -is [string]) {
                        # 打开失败/超时:切回待回复标签重试一次
                        Write-Log "RETRY-OPEN $($key): $convo - switching to pending tab and retry"
                        Switch-ToPendingTab | Out-Null
                        Start-Sleep -Seconds 3
                        $convo = Open-ConvoAndGetMessages $item.name
                    }
                    if ($convo -is [string]) {
                        $listCount = Invoke-CdpEval "document.querySelectorAll('.contact-item-container').length"
                        Write-Log "SKIP $($key): cannot open convo ($convo, list items=$listCount)"
                        $openCooldown[$key] = Get-Date
                        continue
                    }
                    $openCooldown.Remove($key)
                    $msgs = $convo.msgs
                    # P3.4 保存买家档案(国家/注册时间等,PII 仅存本机 data\buyers\)
                    if ($convo.profile) { Save-BuyerProfile $skey $convo.profile }
                    $msgLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
                    Add-Content -Path $msgLog -Value ("# BUYER: " + $key) -Encoding UTF8
                    Add-Content -Path $msgLog -Value $msgs -Encoding UTF8
                    $lines = @($msgs -split "`n") | Where-Object { $_ -notmatch '在Alibaba|平台聊天和交易|由阿里翻译提供|翻译提示|已读$|反馈$|举报$|自动接待' }
                    $buyerMsgs = @($lines | Where-Object { $_ -match '^\[BUYER\]' })
                    if ($buyerMsgs.Count -gt 0) {
                        $latest = ($buyerMsgs[0] -replace '^\[BUYER\] ','')
                        if ($latest.Trim().Length -eq 0) {
                            Write-Log "SKIP $($key): empty latest message"
                            $skipCooldown[$key] = @{ time = Get-Date; preview = $item.preview; count = 1 }
                            continue
                        }
                        # 解析消息时间戳（@@TS），并剥掉供 LLM/规则引擎使用；时间戳用于 dedup 区分
                        # "买家重复发送同内容消息"（内容 hash 相同但时间戳不同 → 视为新消息需回复）
                        $ts = ''
                        if ($latest -match '@@TS:(.+)$') { $ts = $Matches[1].Trim() }
                        $latestClean = $latest -replace '@@TS:.*?$','' -replace '\s+$',''
                        $lines = $lines | ForEach-Object { $_ -replace '@@TS:.*?$','' }
                        Write-Log "Latest buyer msg: $latestClean"
                        $hText = Get-StableHash $latestClean
                        # 新格式：文本 hash + 时间戳；无时间戳时回退纯文本 hash（兼容旧 state）
                        $hash = if ($ts) { "$hText|$ts" } else { $hText }
                        $already = $false
                        if ($state -and $state.replied -and ($state.replied.PSObject.Properties.Name -contains $skey)) {
                            $saved = $state.replied.$skey
                            if ($ts) {
                                # 带时间戳的新格式：完全匹配才算已回复；旧格式记录视为未回复并升级
                                if ($saved -eq $hash) { $already = $true }
                            } else {
                                if ($saved -eq $hText) { $already = $true }
                            }
                        }
                        if ($already) {
                            Write-Log "SKIP $($key): already replied (dedup)"
                            $prev = $null
                            if ($skipCooldown.ContainsKey($key)) { $prev = $skipCooldown[$key] }
                            $count = 1
                            if ($prev -and $prev.count) { $count = [int]$prev.count + 1 }
                            $skipCooldown[$key] = @{ time = Get-Date; preview = $item.preview; count = $count }
                        } else {
                            $rules = Get-Rules
                            $reply = $null
                            $src = 'RULE'
                            # 1) 所有非图片消息优先走 LLM（含简短确认，LLM 已提速至 ~1.5s，回复更自然）
                            if ($latestClean -ne '[IMG]') {
                                $reply = Generate-Reply-LLM $rules $key $latestClean $lines
                                if ($reply) { Write-Log "Reply source: LLM"; $src = 'LLM' }
                            }
                            # 2) LLM 未配置/失败/超时 → 图片消息 → 多语言引导话术
                            if ($latestClean -eq '[IMG]') {
                                $imgReply = @{
                                    en = "Thanks for the images! To give you an accurate quote, could you also share the goods details in text - total weight (kg), packaging dimensions (L*W*H) and the destination address?"
                                    es = "¡Gracias por las imágenes! Para darle una cotización precisa, ¿podría compartir también el peso total (kg), las dimensiones del embalaje (L*A*H) y la dirección de destino?"
                                    pt = "Obrigado pelas imagens! Para dar uma cotação precisa, poderia compartilhar também o peso total (kg), as dimensões da embalagem (C*L*A) e o endereço de destino?"
                                    fr = "Merci pour les images ! Pour un devis précis, pourriez-vous aussi partager le poids total (kg), les dimensions de l'emballage (L*l*H) et l'adresse de destination ?"
                                }
                                $imgLang = Get-ReplyLang
                                $reply = $imgReply[$imgLang]
                                Write-Log "Reply source: IMG_TEMPLATE"
                            }
                            # 3) LLM 失败时：简短确认走规则引擎 QUICK 快回，其余走完整规则引擎
                            if (-not $reply) {
                                $latestLower = $latestClean.ToLower()
                                $quick = $latestLower -match '^(ok|okay|okey|yes|yeah|yep|yup|sure|fine|perfect|great|nice|good|thanks|thank you|thx|gracias|obrigad|merci|no|non|não|nao)\b' -and $latestLower.Length -lt 30
                                $reply = Generate-Reply $rules $key $latestClean $lines
                                $srcLabel = 'RULE_ENGINE'
                                if ($quick) { $srcLabel = 'QUICK' }
                                Write-Log "Reply source: $srcLabel (LLM failback)"
                            }
                            if ($reply -and $reply.Trim().Length -gt 0) {
                                # === 发送前禁词拦截（spec 禁词拦截 Phase 4）：LLM/引擎双路径均过检；命中→LLM 重写一次→仍命中或引擎命中→安全兜底句 ===
                                $banList = $null
                                if ($rules -and $rules.banned_phrases) { $banList = @($rules.banned_phrases) }
                                $banHit = Test-BannedText $reply $banList
                                if ($banHit) {
                                    $sum = $reply.Trim()
                                    if ($sum.Length -gt 60) { $sum = $sum.Substring(0, 60) + "..." }
                                    if ($src -eq 'LLM') {
                                        Write-Log "BANLIST-BLOCK $($key) src=LLM word=$($banHit) action=REWRITE summary=$($sum)"
                                        $retry = Generate-Reply-LLM $rules $key $latestClean $lines -BanRetry
                                        if ($retry -and $retry.Trim().Length -gt 0) {
                                            $retryHit = Test-BannedText $retry $banList
                                            if ($retryHit) {
                                                $sum2 = $retry.Trim()
                                                if ($sum2.Length -gt 60) { $sum2 = $sum2.Substring(0, 60) + "..." }
                                                Write-Log "BANLIST-BLOCK $($key) src=LLM word=$($retryHit) action=FALLBACK summary=$($sum2)"
                                                $reply = $script:banSafeFallback
                                            } else { $reply = $retry }
                                        } else {
                                            Write-Log "BANLIST-BLOCK $($key) src=LLM word=$($banHit) action=FALLBACK summary="
                                            $reply = $script:banSafeFallback
                                        }
                                    } else {
                                        Write-Log "BANLIST-BLOCK $($key) src=RULE word=$($banHit) action=FALLBACK summary=$($sum)"
                                        $reply = $script:banSafeFallback
                                    }
                                }
                                $sendRes = Send-OneTalkMessage $key $reply
                                Write-Log "REPLIED to $($key): $sendRes"
                                Write-Log "Reply text: $($reply)"
                                # 仅发送成功才记录去重；发送失败（ABORT/未发出）不记录，
                                # 否则会话会永久卡在待回复板块且永不重试
                                if ($sendRes -match 'SENT_OK') {
                                    # V12:统一键赋值。注意:首次创建时 replied 是 @{} (IDictionary),
                                    # PSObject.Properties 会枚举出 CLR 内部属性(Count/Keys/Values/IsFixedSize等)污染 state.json,
                                    # 必须按类型分流:IDictionary 用 Keys,反序列化的 PSCustomObject 用 Properties
                                    if (-not $state -or -not $state.replied) { $state = [pscustomobject]@{ replied = @{} } }
                                    $rep = @{}
                                    $__src = $state.replied
                                    if ($__src -is [System.Collections.IDictionary]) {
                                        foreach ($__k in $__src.Keys) { $rep[$__k] = $__src[$__k] }
                                    } else {
                                        foreach ($__p in $__src.PSObject.Properties) { $rep[$__p.Name] = $__p.Value }
                                    }
                                    $rep[$skey] = $hash
                                    $state = [pscustomobject]@{ replied = $rep }
                                    Set-RepliedState $state
                                    # B2 报价提醒:买家数据齐全(重量+尺寸+地址)则推送企微提醒(24h 节流由 remind_state 控制)
                                    try {
                                        $gst = Get-GoodsDataStatus $key $script:dataDir
                                        if ($gst -and $gst.weight -and $gst.dims -and $gst.addr) {
                                            $n = Send-QuoteReminders -OnlyBuyer $key -logFile $logFile
                                            if ($n -gt 0) { Write-Log "QUOTE-REMIND: pushed for $key" }
                                        }
                                    } catch {
                                        Write-Log "QUOTE-REMIND-ERR: $($_.Exception.Message)"
                                    }
                                } else {
                                    # A4: count consecutive send failures, alert after 3 (30m throttle per buyer)
                                    $failCount = 0
                                    if ($script:sendFailCount.ContainsKey($key)) { $failCount = $script:sendFailCount[$key] }
                                    $failCount++
                                    $script:sendFailCount[$key] = $failCount
                                    # 首次失败累计到 3 次立即告警;再次告警需距上次告警超过 30 分钟(节流)
                                    $lastAlert = 0
                                    if ($script:failAlertAt.ContainsKey($key)) { $lastAlert = [int]((Get-Date) - $script:failAlertAt[$key]).TotalMinutes }
                                    if ($failCount -ge 3 -and (-not $script:failAlertAt.ContainsKey($key) -or $lastAlert -gt 30)) {
                                        $script:failAlertAt[$key] = Get-Date
                                        $script:sendFailCount[$key] = 0
                                        $af = Send-WecomMessage ("[ALERT] send failed x" + $failCount + " for " + $key + ": " + $sendRes)
                                        Write-Log "FAIL-ALERT: $key -> $af (streak=$failCount)"
                                    }
                                    Write-Log "RETRY-QUEUE $($key): send failed ($sendRes), will retry after cooldown"
                                    $openCooldown[$key] = Get-Date
                                }
                            } else {
                                Write-Log "SKIP $($key): empty reply generated"
                            }
                        }
                    } else {
                        Write-Log "SKIP $($key): no buyer msgs found"
                    }
                }
            }
            Write-Log "Scan cycle done"
        } catch {
            Write-Log "Monitor error: $($_.Exception.Message)"
            # CDP/Chrome 不可达自愈：连续 3 次错误则重启 Chrome 并重新登录
            Invoke-CdpSelfHeal | Out-Null
        }
        # 列表抓取失败（非合法 JSON / 页面未就绪）时连续 3 次强制刷新重连；
        # 列表为空数组 [] 是正常"无待办"状态，不刷新避免打断连接
        if ($null -eq $snap -and $snapRaw -notmatch '^\[') {
            # CDP 掉线识别(修复盲区):Cdp-Eval 把子进程错误当普通输出返回,
            # 此前 CDP 掉线只走下方"重载循环"而永不触发 chrome_ensure 自愈。
            # 现在检测到 CDP 错误标记 → 计入 cdpFailStreak,连续 3 次自动自愈;
            # CDP 已断时重载请求必然也失败,跳过重载直接等待下一轮
            if ($snapRaw -match 'CDP ERROR|WS CONNECT TIMEOUT|WS RECV TIMEOUT|无法连接到远程服务器|CMD ERROR') {
                $cdpStreak = $script:cdpFailStreak + 1
                Write-Log "CDP error detected ($cdpStreak/3): $($snapRaw.Substring(0, [Math]::Min(90, $snapRaw.Length)))"
                if (Invoke-CdpSelfHeal) { $script:emptyStreak = 0 }
            } else {
                $script:emptyStreak++
                if ($script:emptyStreak -ge 3) {
                    $script:emptyStreak = 0
                    $re = Invoke-CdpEval "location.reload(); 'RELOADED'"
                    Write-Log "List fetch failed x3 - forced page reload ($re), waiting for reconnection"
                    Start-Sleep -Seconds 12
                }
            }
        } else {
            # 本轮列表抓取正常 → 失败计数清零
            $script:emptyStreak = 0
            $script:cdpFailStreak = 0
        }
        # P2.2 按需 reload(替代原每 2 分钟无条件刷新):空闲且距上次活动超过阈值才刷新;忙时超过 30 分钟兜底
        $minsSinceReload = [int]((Get-Date) - $script:lastReload).TotalMinutes
        $minsSinceActivity = [int]((Get-Date) - $lastActivity).TotalMinutes
        if ($minsSinceReload -ge $script:reloadIdleMin -and $snap.Count -eq 0 -and $minsSinceActivity -ge $script:reloadIdleMin) {
            Invoke-PageReload "Scheduled page reload (${minsSinceReload}m since last, idle ${minsSinceActivity}m)"
            continue
        } elseif ($minsSinceReload -ge 30) {
            # 长时间无法空闲（一直在处理会话），强制刷新防止列表失活
            Invoke-PageReload "Forced page reload (${minsSinceReload}m, busy)"
            continue
        }
        Release-AppLock 'onetalk-write'
        Start-Sleep -Seconds 5
    }
}

function Stop-Monitor {
    $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'monitor\.ps1' }
    foreach ($proc in $p) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Log "=== Monitor stopped ==="
}

switch ($Action) {
    "start" { Start-Monitor }
    "stop" { Stop-Monitor }
    default { Write-Output "Usage: monitor.ps1 -Action start|stop" }
}
