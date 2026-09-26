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
# [FIX-PAGEHEALTH 2026-09-25] 数据面断连告警只走既有本地告警通道（文件+弹窗+企微），禁止自建通知路径
. (Join-Path $PSScriptRoot "lib\alert_local.ps1")
. (Join-Path $PSScriptRoot "lib\goods.ps1")
. (Join-Path $PSScriptRoot "lib\wecom.ps1")
. (Join-Path $PSScriptRoot "lib\quote.ps1")
. (Join-Path $PSScriptRoot "lib\no_reply.ps1")
. (Join-Path $PSScriptRoot "lib\vision.ps1")
. (Join-Path $PSScriptRoot "lib\doc.ps1")
. (Join-Path $PSScriptRoot "lib\accio.ps1")
. (Join-Path $PSScriptRoot "log_rotate.ps1")
. (Join-Path $PSScriptRoot "retention.ps1")
$script:skillCfg = Get-SkillConfig
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:cdpScript = Get-SkillPath "cdp"
$script:ensureScript = Get-SkillPath "ensure"
$script:llmCfgFile = Get-SkillPath "llmcfg"

$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
$stateFile = Join-Path $LogDir "state.json"
# Accio 网关灰度开关(默认全关;影子/读取失败一律回退 CDP)
$script:accioFlags = Get-AccioFlags $script:skillCfg
Set-AccioLogFile $logFile
# F7:恢复 Accio 鉴权负缓存(跨重启生效),避免上一进程记录的 AUTH-REQUIRED 冷却窗口丢失
Restore-AccioAuthState

# F4(2026-09-15 停摆根因修复):回复轮次总预算(秒,缺省 180)。超预算则本轮不发送、保留待处理,下一轮重试
$script:replyRoundBudgetSec = 180
if ($script:skillCfg.PSObject.Properties.Name -contains 'reply_round_budget_sec' -and $script:skillCfg.reply_round_budget_sec) {
    $script:replyRoundBudgetSec = [int]$script:skillCfg.reply_round_budget_sec
}
if ($script:replyRoundBudgetSec -lt 30) { $script:replyRoundBudgetSec = 30 }

# 发送前拦截安全兜底句（spec 禁词拦截 Phase 4 + 2026-09-10 责任承诺拦截）：命中禁词/责任承诺且重写仍越线/引擎路径命中时整体替换；争议与通用场景安全，纯 ASCII，非空保证
$script:banSafeFallback = "Thanks for your patience - I've noted this and I'm checking with the team. I'll get back to you with a clear update shortly."

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
    // [FIX-DUP 2026-09-25] 原文节点优先：译文是冗余的，且未渲染时会与原文重复导致 hash 突变
    var richOrig = w.querySelector('.session-rich-content.text')
                || w.querySelector('.content-with-translation .session-rich-content')
                || rich;
    var otxt = (richOrig.innerText || '').replace(/\n+/g,' ').trim();
    if (!otxt) { otxt = txt; }
    var clean = txt.replace(/翻译中…|反馈|已读|回复|翻译|Revert|由阿里提供|自动接待发送/g,'').trim();
    var hasImg = !!w.querySelector('img[src*="alicdn"], [class*=image] img, [class*=Image] img, [class*=picture]');
    var nameEl0 = w.querySelector('.item-base-info .name');
    var buyerName0 = (nameEl0 && nameEl0.innerText.trim()) || '';
    var isBuyer0 = buyerName0.length > 0 || /由阿里翻译提供|翻译中/.test(txt) || cls.indexOf('item-left') >= 0;
    // B2 附件标记: 图片 src/data-src(阿里域, 去重, ≤3); 文件卡片兜底特征 "<name>.<ext> <size> K/M"
    var imgUrls = [];
    if (isBuyer0) {
      w.querySelectorAll('img').forEach(function(im){
        var u = im.getAttribute('src') || im.getAttribute('data-src') || '';
        if (!u) return;
        if (!/(alicdn\.com|alibaba\.com|aliimg\.com|data:image)/.test(u)) return;
        if (imgUrls.indexOf(u) < 0) imgUrls.push(u);
      });
      if (imgUrls.length > 3) imgUrls = imgUrls.slice(0, 3);
    }
    var fileInfo = null;
    if (isBuyer0) {
      var mf = clean.match(/([^\s\/\\]+\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt))\s+(\d+(\.\d+)?\s*[KMG]?B?)/i);
      if (mf) {
        var furl = '';
        var anchors = w.querySelectorAll('a[href]');
        for (var ai = 0; ai < anchors.length; ai++) {
          var h = anchors[ai].getAttribute('href') || '';
          if (/^https?:/.test(h) && (/\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt)($|\?)/i.test(h) || /download/i.test(h))) { furl = h; break; }
        }
        if (!furl) {
          var mUrl = (w.innerHTML || '').match(/https?:\/\/[^"'\s<>]+\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt)(\?[^"'\s<>]*)?/i);
          if (mUrl) furl = mUrl[0];
        }
        fileInfo = { name: mf[1], url: furl };
      }
    }
    if (clean.length <= 2) {
      if (hasImg && (cls.indexOf('item-left') >= 0)) out.push({b:true, t:'[IMG]', ot:'[IMG]', ts:'', imgs: imgUrls, file: fileInfo}); // [FIX-DUP 2026-09-25] ot=原文
      return;
    }
    var buyerName = (nameEl0 && nameEl0.innerText.trim()) || '';
    var isBuyer = isBuyer0;
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
    out.push({b: isBuyer, t: clean.substring(0,1000), ot: otxt.substring(0,1000), ts: ts, imgs: isBuyer ? imgUrls : [], file: isBuyer ? fileInfo : null}); // [FIX-DUP 2026-09-25] ot=原文,仅用于去重键
  });
  // B2 附件标记挂载: 仅最新买家消息; 最新无标记但含指代词(photo/image/图/文件等) → 回溯最近带标记的买家消息
  var buyerIdx = [];
  out.forEach(function(o, i){ if (o.b) buyerIdx.push(i); });
  if (buyerIdx.length > 0) {
    var last = out[buyerIdx[buyerIdx.length - 1]];
    var aimgs = (last.imgs || []).slice(0, 3);
    var afile = last.file || null;
    if (aimgs.length === 0 && !afile && /(photo|image|pic|picture|foto|imagen|图片|图|文件|附件|document|attachment|pdf|excel|csv|word)/i.test(last.t)) {
      for (var bi = buyerIdx.length - 1; bi >= 0; bi--) {
        var cand = out[buyerIdx[bi]];
        if ((cand.imgs && cand.imgs.length) || cand.file) { aimgs = (cand.imgs || []).slice(0, 3); afile = cand.file || null; break; }
      }
    }
    if (aimgs.length > 0) { last.t = last.t + ' @@IMG:' + aimgs.join('|'); }
    if (afile) { last.t = last.t + ' @@FILE:' + encodeURIComponent(afile.name) + '|' + (afile.url || ''); }
  }
  var lines = [];
  // [FIX-DUP 2026-09-25] 行尾追加原文标记(@@OT,B64/UTF-8),供 PS 侧构造去重键;@@TS 产出保持不变
  out.forEach(function(o){
    var line = (o.b ? '[BUYER] ' : '[ME] ') + o.t + (o.ts ? ' @@TS:' + o.ts : '');
    if (o.b && o.ot) {
      var otb = (typeof btoa === 'function') ? btoa(unescape(encodeURIComponent(o.ot))) : '';
      if (otb) { line += ' @@OT:' + otb; }
    }
    lines.push(line);
  });
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
# -ImageDataUrls: 多模态附件图片(data URL, ≤3); -AttachmentText: 文档文本/说明(与文本消息合并)
function Generate-Reply-LLM([object]$rules, [string]$convoName, [string]$latest, [string[]]$context, [switch]$BanRetry, [switch]$CommitRetry, [string[]]$ImageDataUrls = $null, [string]$AttachmentText = $null) {
    $cfg = Get-LLMConfig
    if (-not $cfg) { return $null }
    $rulesRaw = Get-RulesRaw
    $systemPrompt = (Get-ReplyPrompt) + "`n`n=== 语料库 reply_rules.json ===`n" + $rulesRaw
    if ($CommitRetry) {
        # 发送前责任承诺拦截重写（仅 LLM 路径 1 次）：系统提示词追加重写要求（默认不带，避免长系统提示）
        $systemPrompt += "`n`n[重写要求] 上一稿含对买家的责任/费用承诺，已弃用；重写：禁止承认或暗示责任在我司（禁用 on us / we take responsibility for this cost / it's our fault / you shouldn't be out of pocket 等归因句式），禁止承诺支付/报销/退款/赔偿任何金额（禁用 we'll pay / cover / reimburse / refund / compensate / make it right 等承诺句式）。正确写法：真诚致歉共情（I'm really sorry for the trouble this has caused）→ 说明正在核实实际原因与最新进度 → 给具体回访时限（today / tomorrow morning）→ 费用赔偿类诉求答复 I'll have that reviewed carefully and get back to you with a clear answer；不得出现 manager/boss/supervisor/经理/上级 等请示措辞。"
    } elseif ($BanRetry) {
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
    if ($AttachmentText) { $userMsg += "`n`n[附件内容]`n" + $AttachmentText }
    if ($ImageDataUrls -and @($ImageDataUrls).Count -gt 0) {
        $messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user"; content = @(New-VisionContentParts $ImageDataUrls $userMsg) }
        )
    } else {
        $messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user"; content = $userMsg }
        )
    }
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

# 去重状态统一写入:按类型分流合并 replied 表并双写落盘(发送成功路径与旧记录升级共用)。
# 注意:首次创建时 replied 是 @{} (IDictionary),PSObject.Properties 会枚举 CLR 内部属性污染 state.json,
# 必须按类型分流:IDictionary 用 Keys,反序列化的 PSCustomObject 用 Properties。
function Set-StateHash($ctx, [string]$skey, [string]$hash) {
    if (-not $ctx.state -or -not $ctx.state.replied) { $ctx.state = [pscustomobject]@{ replied = @{} } }
    $rep = @{}
    $src = $ctx.state.replied
    if ($src -is [System.Collections.IDictionary]) {
        foreach ($k in $src.Keys) { $rep[$k] = $src[$k] }
    } else {
        foreach ($p in $src.PSObject.Properties) { $rep[$p.Name] = $p.Value }
    }
    $rep[$skey] = $hash
    $ctx.state = [pscustomobject]@{ replied = $rep }
    Set-RepliedState $ctx.state
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

# P2.4 容量治理：state 记录超阈值(200)且买家 30 天无快照活动 → 清理陈旧记录（单次遍历 msgs 快照建索引）
function Cleanup-StaleState {
    try {
        $st = Get-RepliedState
        if (-not $st -or -not $st.replied) { return }
        $names = @($st.replied.PSObject.Properties.Name)
        if ($names.Count -lt 200) { return }
        $cutoff = (Get-Date).AddDays(-30)
        # 单次遍历:一次扫描全部快照首行,建立 买家名 -> 最新快照时间 索引(原实现按买家重复扫描目录)
        $latestMap = @{}
        Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | ForEach-Object {
            $first = Get-Content $_.FullName -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue
            if ($first -and $first.StartsWith("# BUYER: ")) {
                $bn = $first.Substring(9)
                if (-not $latestMap.ContainsKey($bn) -or $latestMap[$bn] -lt $_.LastWriteTime) { $latestMap[$bn] = $_.LastWriteTime }
            }
        }
        $removed = @()
        foreach ($n in $names) {
            $latest = $null
            if ($latestMap.ContainsKey($n)) { $latest = $latestMap[$n] }
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

# 会话处理:处理待办板块中的单个会话(提醒/白名单/冷却/打开/去重/生成/双检/发送/状态/提醒推送)。
# $ctx 为可写上下文引用: state/openCooldown/skipCooldown/noReplyPreview/sendFailCount/failAlertAt/lastActivity
function Invoke-ConvoItem($ctx, $item) {
    $key = $item.name.Trim()
    $skey = Get-StateKey $key
    Write-Log "PROCESS convo from pending-list: $($key) | $($item.preview)"
    # A1: new inquiry alert (24h throttle)
    if (-not $ctx.state -or -not $ctx.state.replied -or ($ctx.state.replied.PSObject.Properties.Name -notcontains $skey)) {
        Send-NewInquiryAlert $key $item.preview
    }
    # A5 人工接管白名单(NO-REPLY):名单买家不自动回复(LLM/规则/图片模板/QUICK 全跳过,不发送);
    # 只读留痕(买家档案+msgs 快照)且不写 replied 去重状态 → 移出名单后自动恢复正常;
    # 新消息仍由上方 A1 提醒主人(24h 节流);预览不变时后续轮免打扰跳过
    if (Test-NoReplyBuyer $key) {
        if ($ctx.noReplyPreview.ContainsKey($key) -and $ctx.noReplyPreview[$key] -eq $item.preview) {
            Write-Log "TEMP-SKIP $($key): manual-override whitelist (preview unchanged, no auto reply)"
            return
        }
        $nrConvo = Open-ConvoAndGetMessages $key
        if ($nrConvo -is [string]) {
            Write-Log "NO-REPLY-SNAP-FAIL $($key): $nrConvo"
            return
        }
        if ($nrConvo.profile) { Save-BuyerProfile $skey $nrConvo.profile }
        $nrLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
        Add-Content -Path $nrLog -Value ("# BUYER: " + $key) -Encoding UTF8
        Add-Content -Path $nrLog -Value (Remove-AttachmentMarkers $nrConvo.msgs) -Encoding UTF8
        $ctx.noReplyPreview[$key] = $item.preview
        Write-Log "NO-REPLY-SNAPSHOT $($key): manual-override whitelist, snapshot kept, no auto reply"
        return
    }
    # dedup 跳过会话进冷却（3→6→12→15 分钟递增）
    # [FIX-DUP 2026-09-25] 方案甲：冷却期内不再"预览变化即提前解除"。列表预览含未读计数/翻译标记等 UI 噪声
    #   （实测两轮预览只差未读计数 "1"），且我方回复本身就会改变预览 → 原逻辑必然误判为"买家新动态"而提前解除冷却。
    #   现改为冷却期内一律 TEMP-SKIP，到期后自然处理；买家新消息最晚延迟一个冷却周期（默认 3 分钟）。
    if ($ctx.skipCooldown.ContainsKey($key)) {
        $co = $ctx.skipCooldown[$key]
        $pkeyNow = Get-NormalizedMsgText $item.preview   # [FIX-DUP 2026-09-25] 归一化预览仅用于日志留痕
        $skipMins = [int]((Get-Date) - $co.time).TotalMinutes
        # 冷却随重复命中次数递增（3→6→12→15 分钟封顶）：
        # 已回复且无新消息的会话不必每 3 分钟重新打开一次，减少页面负担
        $coolMin = [Math]::Min(3 * [Math]::Pow(2, ([int]$co.count - 1)), 15)
        if ($skipMins -lt $coolMin) {
            Write-Log "TEMP-SKIP $($key): dedup cooldown ${skipMins}m/${coolMin}m pkey=[$($co.pkey) -> $pkeyNow] buyers=$($co.buyers)"
            return
        } else {
            $ctx.skipCooldown.Remove($key)
        }
    }
    # 已打开失败的会话缓存在 blacklist 中，3 分钟内不重复尝试
    if ($ctx.openCooldown.ContainsKey($key)) {
        $skipMins = [int]((Get-Date) - $ctx.openCooldown[$key]).TotalMinutes
        if ($skipMins -lt 3) {
            Write-Log "TEMP-SKIP $($key): open failed recently (cooldown ${skipMins}m)"
            return
        } else {
            $ctx.openCooldown.Remove($key)
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
        $ctx.openCooldown[$key] = Get-Date
        return
    }
    $ctx.openCooldown.Remove($key)
    $msgsRaw = $convo.msgs
    # B2: 附件标记解析(仅最新买家消息) + 快照剥离标记(格式不变)
    $attImages = @(); $attFile = $null
    $rawBuyerLines = @($msgsRaw -split "`n" | Where-Object { $_ -match '^\[BUYER\]' })
    if ($rawBuyerLines.Count -gt 0) {
        $rawLatest = $rawBuyerLines[0]
        if ($rawLatest -match '@@IMG:([^\s]+)') { $attImages = @(@($Matches[1] -split '\|') | Where-Object { $_ } | Select-Object -First 3) }
        if ($rawLatest -match '@@FILE:([^\s]+)') {
            $fp = $Matches[1] -split '\|', 2
            $attFile = @{ name = [uri]::UnescapeDataString($fp[0]); url = '' }
            if ($fp.Count -gt 1) { $attFile.url = $fp[1] }
        }
        # 增强路径: 最新消息含指代词但无标记 → 回溯最近带标记的买家消息
        if ($attImages.Count -eq 0 -and -not $attFile -and $rawLatest -match '(?i)(photo|image|pic|picture|foto|imagen|图片|图|文件|附件|document|attachment|pdf|excel|csv|word)') {
            foreach ($bl in $rawBuyerLines) {
                if ($bl -match '@@IMG:([^\s]+)') { $attImages = @(@($Matches[1] -split '\|') | Where-Object { $_ } | Select-Object -First 3); break }
                if ($bl -match '@@FILE:([^\s]+)') {
                    $fp2 = $Matches[1] -split '\|', 2
                    $attFile = @{ name = [uri]::UnescapeDataString($fp2[0]); url = '' }
                    if ($fp2.Count -gt 1) { $attFile.url = $fp2[1] }
                    break
                }
            }
        }
    }
    $msgs = Remove-AttachmentMarkers $msgsRaw
    # P3.4 保存买家档案(国家/注册时间等,PII 仅存本机 data\buyers\)
    if ($convo.profile) { Save-BuyerProfile $skey $convo.profile }
    $msgLog = Join-Path $script:dataDir ("msgs_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
    Add-Content -Path $msgLog -Value ("# BUYER: " + $key) -Encoding UTF8
    Add-Content -Path $msgLog -Value $msgs -Encoding UTF8
    $cdpLines = @($msgs -split "`n") | Where-Object { $_ -notmatch '在Alibaba|平台聊天和交易|由阿里翻译提供|翻译提示|已读$|反馈$|举报$|自动接待' }
    $lines = $cdpLines
    # Accio 影子/读取切换（开关默认关；任何失败自动回退 CDP）。
    # 去重/最新买家消息基准始终取 CDP，避免网关行文本差异导致 hash 突变→重复回复。
    if ($script:accioFlags.shadow -or $script:accioFlags.read) {
        $gwLines = Get-AccioReplyLines $key
        if ($script:accioFlags.shadow) {
            if ($gwLines) { Invoke-AccioShadowCompare $key $cdpLines $gwLines }
            else { Write-Log "ACCIO-SHADOW $($key): gateway unavailable (cdp-only)" }
        }
        if ($script:accioFlags.read) {
            if ($gwLines -and (Test-AccioLinesOverlap $cdpLines $gwLines)) {
                $lines = @($gwLines); Write-Log "ACCIO-READ src=gateway $($key) lines=$(@($gwLines).Count)"
            } else {
                Write-Log "ACCIO-READ src=cdp $($key) (gateway unavailable or content mismatch)"
            }
        }
    }
    $buyerMsgs = @($cdpLines | Where-Object { $_ -match '^\[BUYER\]' })
    if ($buyerMsgs.Count -gt 0) {
        $latest = ($buyerMsgs[0] -replace '^\[BUYER\] ','')
        if ($latest.Trim().Length -eq 0) {
            Write-Log "SKIP $($key): empty latest message"
            # [FIX-DUP 2026-09-25] buyers=-1 表示"未知"（该分支尚未计算买家条数），判定侧按"不解除冷却"处理
            $ctx.skipCooldown[$key] = @{ time = Get-Date; preview = $item.preview; pkey = (Get-NormalizedMsgText $item.preview); buyers = -1; count = 1 }
            return
        }
        # 解析消息时间戳（@@TS），并剥掉供 LLM/规则引擎使用
        $ts = ''
        if ($latest -match '@@TS:(.+)$') { $ts = $Matches[1].Trim() }
        # [FIX-DUP 2026-09-25] 取出原文（@@OT，B64）用于去重键；缺失则回退剥离了标记的文本
        $otB64 = ''
        if ($latest -match '@@OT:([A-Za-z0-9+/=]+)') { $otB64 = $Matches[1] }
        $latestOrig = ''
        if ($otB64) { try { $latestOrig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($otB64)) } catch { $latestOrig = '' } }
        $latestClean = $latest -replace '@@TS:.*?$','' -replace '@@OT:[A-Za-z0-9+/=]+','' -replace '\s+$',''
        if (-not $latestOrig) { $latestOrig = $latestClean }   # [FIX-DUP 2026-09-25] 兜底：原文缺失时用剥离标记后的文本
        # [FIX-DUP 2026-09-25] LLM/规则输入必须剥离 @@OT（否则提示词里会出现 B64 垃圾）
        $lines = $lines | ForEach-Object { $_ -replace '@@TS:.*?$','' -replace '@@OT:[A-Za-z0-9+/=]+','' }
        Write-Log "Latest buyer msg: $latestClean"
        # [FIX-DUP 2026-09-25] 去重键 = 归一化原文 hash + 买家消息条数，不再使用合成 @@TS
        $normText = Get-NormalizedMsgText $latestOrig
        $hText = Get-StableHash $normText
        $buyerCount = @($buyerMsgs).Count
        $newKey = Get-DedupKey $normText $buyerCount
        $already = $false
        $saved = ''
        if ($ctx.state -and $ctx.state.replied -and ($ctx.state.replied.PSObject.Properties.Name -contains $skey)) {
            $saved = [string]$ctx.state.replied.$skey
            $already = Test-DedupHit $saved $hText $buyerCount
        }
        if ($already) {
            Write-Log "SKIP $($key): already replied (dedup text=$($hText.Substring(0,8)) buyers=$buyerCount)"
            # [FIX-DUP 2026-09-25] removed DEDUP-UPGRADE (key no longer carries ts)
            $prev = $null
            if ($ctx.skipCooldown.ContainsKey($key)) { $prev = $ctx.skipCooldown[$key] }
            $count = 1
            if ($prev -and $prev.count) { $count = [int]$prev.count + 1 }
            $ctx.skipCooldown[$key] = @{ time = Get-Date; preview = $item.preview; pkey = (Get-NormalizedMsgText $item.preview); buyers = $buyerCount; count = $count }   # [FIX-DUP 2026-09-25]
        } else {
            $rules = Get-Rules
            $reply = $null
            $src = 'RULE'
            $visionSource = ''
            $visionUrls = @()
            $docExtractText = ''
            $attFileName = ''
            # F2(a)/F4:回复轮次开始 —— 起心跳上下文与总预算,并打出第一行 ROUND-* 进度日志
            $roundBudget = $script:replyRoundBudgetSec
            $roundCtx = Start-LlmRound $key $roundBudget
            $attFlag = 'none'
            if ($attFile) { $attFlag = 'file' } elseif (@($attImages).Count -gt 0) { $attFlag = 'img' }
            Write-Log "ROUND-START $($key) attach=$attFlag imgs=$(@($attImages).Count) ctx=$(@($lines).Count) budget=${roundBudget}s"
            # 0) B5 图片多模态: 下载 → 多模态回复(与提取解耦)
            if ($attImages.Count -gt 0) {
                Write-Log "ROUND-VISION-BEGIN $($key) kind=image n=$($attImages.Count)"
                $dataUrls = @()
                foreach ($u in $attImages) { $du = Get-ImageDataUrl $u; if ($du) { $dataUrls += $du } }
                if ($dataUrls.Count -gt 0) {
                    $visionSource = 'image'
                    $visionUrls = $dataUrls
                    Write-Log "VISION-IMG $($key): $($dataUrls.Count)/$($attImages.Count) image(s) downloaded"
                    $reply = Generate-Reply-LLM $rules $key $latestClean $lines -ImageDataUrls $dataUrls
                    if ($reply) { Write-Log "VISION-REPLY $($key) src=LLM(multimodal)"; $src = 'LLM' }
                    else { Write-Log "VISION-REPLY-FAIL $($key): multimodal LLM returned null" }
                } else {
                    Write-Log "VISION-IMG-FAIL $($key): image download failed"
                }
                Write-Log "ROUND-VISION-END $($key) kind=image elapsed=$(Get-LlmRoundElapsedSec)s got=$([bool]$reply)"
            }
            # 0b) B5 文档: CDP 页面上下文 fetch 优先 → 兜底 PS 下载 → doc-reader → 文本/扫描图
            if (-not $reply -and $attFile) {
                Write-Log "ROUND-VISION-BEGIN $($key) kind=document name=$($attFile.name)"
                $b64 = $null
                if ($attFile.url) { $b64 = Get-DocumentBase64ViaCdp $attFile.url }
                if (-not $b64 -and $attFile.url) { $b64 = Get-DocumentBase64ViaHttp $attFile.url }
                if ($b64) {
                    $docTmp = $null
                    try {
                        $docTmp = Save-DocTempFile $attFile.name ([Convert]::FromBase64String($b64))
                        $docRes = Invoke-DocReader $docTmp 6000 2
                        if ($docRes -and $docRes.ok) {
                            Write-Log "DOC-READ $($key): $($attFile.name) kind=$($docRes.kind) chars=$($docRes.text.Length) images=$(@($docRes.images).Count)"
                            $visionSource = 'document'
                            $attFileName = $attFile.name
                            if ($docRes.kind -eq 'pdf-scan' -and @($docRes.images).Count -gt 0) {
                                $visionUrls = @($docRes.images)
                                $docPrompt = "买家发送了文件《$($attFile.name)》(扫描件, 已渲染为图片)。请结合文件内容回复; 明确可见的重量/尺寸/箱数/单号可确认, 不确定不臆造。"
                                $reply = Generate-Reply-LLM $rules $key $latestClean $lines -ImageDataUrls @($docRes.images) -AttachmentText $docPrompt
                                if ($reply) { Write-Log "VISION-REPLY $($key) src=LLM(doc-scan)"; $src = 'LLM' }
                                else { Write-Log "VISION-REPLY-FAIL $($key): doc-scan LLM returned null" }
                            } else {
                                $docExtractText = $docRes.text
                                $docPrompt = "买家发送了文件《$($attFile.name)》（类型：$($docRes.kind)）：`n" + $docRes.text + "`n请结合文件内容回复；明确可见的重量/尺寸/箱数/单号可确认，不确定不臆造。"
                                $reply = Generate-Reply-LLM $rules $key $latestClean $lines -AttachmentText $docPrompt
                                if ($reply) { Write-Log "VISION-REPLY $($key) src=LLM(doc)"; $src = 'LLM' }
                                else { Write-Log "VISION-REPLY-FAIL $($key): doc LLM returned null" }
                            }
                        } else {
                            Write-Log "DOC-READ-FAIL $($key): $($attFile.name) (fallback to text flow)"
                        }
                    } finally {
                        Remove-DocTemp $docTmp
                    }
                } else {
                    Write-Log "DOC-DOWNLOAD-FAIL $($key): $($attFile.name) (fallback to text flow)"
                }
                Write-Log "ROUND-VISION-END $($key) kind=document elapsed=$(Get-LlmRoundElapsedSec)s got=$([bool]$reply)"
            }
            # 1) 所有非图片消息优先走 LLM（含简短确认，LLM 已提速至 ~1.5s，回复更自然）
            if (-not $reply -and $latestClean -ne '[IMG]') {
                $reply = Generate-Reply-LLM $rules $key $latestClean $lines
                if ($reply) { Write-Log "Reply source: LLM"; $src = 'LLM' }
            }
            # 2) LLM 未配置/失败/超时 → 图片消息 → 多语言引导话术
            if (-not $reply -and $latestClean -eq '[IMG]') {
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
            # 2b) B5 提取调用(与回复解耦): 附件存在时第二次 LLM 只输出 JSON → sidecar(source+文件名)
            if ($visionSource) {
                try {
                    $exPrompt = 'Read the attached content. Output ONLY JSON: {"weight_kg":"","dims":"","cartons":"","tracking":"","note":""}. Use only clearly visible values; leave fields empty if unsure.'
                    $exMsgs = $null
                    if ($visionUrls.Count -gt 0) {
                        $exMsgs = @(@{ role = 'user'; content = @(New-VisionContentParts $visionUrls $exPrompt) })
                    } elseif ($docExtractText) {
                        $exMsgs = @(@{ role = 'user'; content = ($exPrompt + "`n`n=== 文件内容 ===`n" + $docExtractText) })
                    }
                    if ($exMsgs) {
                        $exText = Invoke-LLM $exMsgs 0.2 300 $logFile
                        $ex = Get-VisionExtract $exText
                        if ($ex) {
                            $exFile = 'attachment'
                            if ($attFileName) { $exFile = $attFileName }
                            elseif ($attImages.Count -gt 0) { $exFile = (($attImages[0] -split '\?')[0].Split('/')[-1]) }
                            Save-VisionExtract $key $ex $visionSource $exFile $script:dataDir | Out-Null
                            Write-Log "VISION-EXTRACT $($key) src=$visionSource fields=$((@($ex.Keys)) -join ',')"
                        }
                    }
                } catch { Write-Log "VISION-EXTRACT-ERR $($key): $($_.Exception.Message)" }
            }
            if ($reply -and $reply.Trim().Length -gt 0) {
                # F4:预算耗尽 → 本轮不发送,保留待处理状态,下一轮重试(避免超预算轮次拖长静默)
                if (Test-LlmRoundBudgetExceeded) {
                    Set-LlmRoundBudgetExceeded "pre-send" $logFile
                    Write-Log "ROUND-DONE $($key) ms=$($roundCtx.sw.ElapsedMilliseconds) result=BUDGET-SKIP (kept pending for next round)"
                    Stop-LlmRound
                    return
                }
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
                # === 发送前责任承诺双检（2026-09-10 事故整改）：句级检测责任/费用承诺；命中→LLM 重写一次→仍命中→安全兜底句（与 BANLIST 同构，日志前缀 COMMIT-BLOCK） ===
                $finHit = Test-FinancialCommitment $reply
                if ($finHit) {
                    $sum3 = $reply.Trim()
                    if ($sum3.Length -gt 60) { $sum3 = $sum3.Substring(0, 60) + "..." }
                    if ($src -eq 'LLM') {
                        Write-Log "COMMIT-BLOCK $($key) src=LLM pat=$($finHit) action=REWRITE summary=$($sum3)"
                        $retry2 = Generate-Reply-LLM $rules $key $latestClean $lines -CommitRetry
                        if ($retry2 -and $retry2.Trim().Length -gt 0) {
                            $retryHit2 = Test-FinancialCommitment $retry2
                            if ($retryHit2) {
                                $sum4 = $retry2.Trim()
                                if ($sum4.Length -gt 60) { $sum4 = $sum4.Substring(0, 60) + "..." }
                                Write-Log "COMMIT-BLOCK $($key) src=LLM pat=$($retryHit2) action=FALLBACK summary=$($sum4)"
                                $reply = $script:banSafeFallback
                            } else { $reply = $retry2 }
                        } else {
                            Write-Log "COMMIT-BLOCK $($key) src=LLM pat=$($finHit) action=FALLBACK summary="
                            $reply = $script:banSafeFallback
                        }
                    } else {
                        Write-Log "COMMIT-BLOCK $($key) src=RULE pat=$($finHit) action=FALLBACK summary=$($sum3)"
                        $reply = $script:banSafeFallback
                    }
                }
                $sendRes = Send-OneTalkMessage $key $reply
                Write-Log "ROUND-SEND $($key) chars=$($reply.Length) elapsed=$(Get-LlmRoundElapsedSec)s"
                Write-Log "REPLIED to $($key): $sendRes"
                Write-Log "Reply text: $($reply)"
                # 仅发送成功才记录去重；发送失败（ABORT/未发出）不记录，
                # 否则会话会永久卡在待回复板块且永不重试
                if ($sendRes -match 'SENT_OK') {
                    # [FIX-DUP 2026-09-25] 写新格式去重键（归一化原文 hash + 买家消息条数）
                    Set-StateHash $ctx $skey $newKey
                    # 发送成功后短冷却:同一会话 3 分钟内不再重复处理（方案甲：冷却期内不再提前解除）
                    $ctx.skipCooldown[$key] = @{ time = Get-Date; preview = $item.preview; pkey = (Get-NormalizedMsgText $item.preview); buyers = $buyerCount; count = 1 }   # [FIX-DUP 2026-09-25]
                    Write-Log "POST-SEND-COOLDOWN $($key) 3min"
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
                    if ($ctx.sendFailCount.ContainsKey($key)) { $failCount = $ctx.sendFailCount[$key] }
                    $failCount++
                    $ctx.sendFailCount[$key] = $failCount
                    # 首次失败累计到 3 次立即告警;再次告警需距上次告警超过 30 分钟(节流)
                    $lastAlert = 0
                    if ($ctx.failAlertAt.ContainsKey($key)) { $lastAlert = [int]((Get-Date) - $ctx.failAlertAt[$key]).TotalMinutes }
                    if ($failCount -ge 3 -and (-not $ctx.failAlertAt.ContainsKey($key) -or $lastAlert -gt 30)) {
                        $ctx.failAlertAt[$key] = Get-Date
                        $ctx.sendFailCount[$key] = 0
                        $af = Send-WecomMessage ("[ALERT] send failed x" + $failCount + " for " + $key + ": " + $sendRes)
                        Write-Log "FAIL-ALERT: $key -> $af (streak=$failCount)"
                    }
                    Write-Log "RETRY-QUEUE $($key): send failed ($sendRes), will retry after cooldown"
                    $ctx.openCooldown[$key] = Get-Date
                }
            } else {
                Write-Log "SKIP $($key): empty reply generated"
            }
            Write-Log "ROUND-DONE $($key) ms=$($roundCtx.sw.ElapsedMilliseconds) budget=${roundBudget}s"
            Stop-LlmRound
        }
    } else {
        Write-Log "SKIP $($key): no buyer msgs found"
    }
}

# 扫描轮:抓列表 → 逐会话处理 → CDP 错误识别/自愈 → 按需 reload 决策。
# 返回 @{ Action = 'LockBusy' | 'Reloaded' | 'Normal' },调用方据此决定 sleep/continue
function Invoke-ScanRound($ctx) {
    # P2.3 写互斥:与其他写者(如 nudge)互斥,避免并发操作同一页面。拿不到锁则本轮跳过。
    $lockHeld = Get-AppLock 'onetalk-write' 0
    if (-not $lockHeld) {
        Write-Log "LOCK-BUSY: onetalk-write held by another process, skipping round"
        return @{ Action = 'LockBusy' }
    }
    $snapRaw = ''
    $snap = $null
    try {
        # 待回复板块 = 待办队列：板块里出现的每个会话都需要处理，回复后自动从板块消失。
        $snapRaw = Get-Snapshot
        if ($snapRaw -match '^\[') { $snap = $snapRaw | ConvertFrom-Json }
        if ($snap -and $snap.Count -gt 0) {
            $script:emptyStreak = 0
            $ctx.lastActivity = Get-Date
            $ctx.state = Get-RepliedState
            foreach ($item in $snap) {
                if (-not $item.name) { continue }
                Invoke-ConvoItem $ctx $item
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
    # [FIX-PAGEHEALTH 2026-09-25] 数据面连通性判定（与 CDP 错误判定相互独立、互补）
    #   背景：页面断连时 $snapRaw 返回 '[]'（合法 JSON），既不会进 CDP-ERROR 分支、也不触发 emptyStreak
    #   之外的任何动作 → 22:24-22:56 业务空转 32 分钟而日志只有 "Scan cycle done"。
    $pageHealth = Test-PageHealth
    # [FIX-PAGESELECT 2026-09-26] S1-3 空守卫：Get-Page 无 OneTalk 页时返回 $null，本函数仍返回对象
    #   （wrong-tab ⇒ PageDown），但异常路径可能返回字符串/数组：直接取 $pageHealth.PageDown 会静默拿到
    #   $null ⇒ 把"判据失效"伪装成"未断连"（附录 B/C12 同类教训）。这里显式归一化后再判定。
    if ($pageHealth -is [array]) { $pageHealth = $pageHealth[0] }
    if ($null -eq $pageHealth -or -not ($pageHealth.PSObject.Properties.Name -contains 'PageDown')) {
        $pageHealth = [pscustomobject]@{ PageDown=$true; Reason='probe-invalid'; Items=0; Spinner=0; Tab=''; Tip='' }
    }
    if ($pageHealth.PageDown) {
        $script:pageDownStreak++
        Write-Log "PAGE-DOWN ($($script:pageDownStreak)x) reason=$($pageHealth.Reason) items=$($pageHealth.Items) spin=$($pageHealth.Spinner)"
    } else {
        if ($script:pageDownStreak -gt 0) { Write-Log "PAGE-RECOVERED after $($script:pageDownStreak) down round(s)" }
        $script:pageDownStreak = 0
    }
    # [FIX-THROTTLE 2026-09-26] 分级自愈（带静默期/退避/上限，取代原来的 `% 3` 无退避写法）
    $healSkipped = $false
    if ($pageHealth.PageDown -and $script:pageDownStreak -ge 2) {
        Release-AppLock 'onetalk-write'
        if (-not (Get-AppLock 'onetalk-write' 0)) {
            $healSkipped = $true
            Write-Log "PAGE-HEAL-SKIP: onetalk-write held by another process (avoid disturbing an in-flight send)"
        } else {
            Release-AppLock 'onetalk-write'
            $act = Get-PageHealAction -Streak $script:pageDownStreak -Restarts $script:pageHealRestarts -QuietUntil $script:pageHealQuietUntil
            switch ($act.Action) {
                'restart' {
                    Write-Log ("PAGE-HEAL: escalating to chrome_ensure -ForceRestart [$($act.Reason)] quiet=$($act.NextQuietSec)s")
                    $ensure = powershell -ExecutionPolicy Bypass -NoProfile -File $script:ensureScript -ForceRestart 2>&1
                    Write-Log "PAGE-HEAL chrome_ensure exit=$LASTEXITCODE result: $(($ensure -join ' | '))"
                    $script:pageHealRestarts++
                    if ($act.NextQuietSec -gt 0) { $script:pageHealQuietUntil = (Get-Date).AddSeconds($act.NextQuietSec) }
                    Write-Log ("PAGE-HEAL: restarts=$($script:pageHealRestarts) quietUntil=" + $(if($script:pageHealQuietUntil){$script:pageHealQuietUntil.ToString('HH:mm:ss')}else{'-'}))
                }
                'reload' { Invoke-PageReload "Scheduled page reload (PAGE-DOWN x$($script:pageDownStreak))" }
                'alert-only' {
                    if (-not $script:pageHealAlerted) {
                        $script:pageHealAlerted = $true
                        Write-Log ("PAGE-HEAL-ALERT-ONLY: $($act.Reason) - 停止自动重启，等待人工介入")
                        Write-LocalAlert 'page_data_plane' ("OneTalk 数据面断连持续 $($script:pageDownStreak) 轮，已达重启上限 $($script:pageHealRestarts) 次（$($act.Reason)）") 'local-only'
                    }
                }
                default { }
            }
        }
    }
    # 恢复/稳定后清零计数（D4）
    if (-not $pageHealth.PageDown -and $script:pageDownStreak -eq 0 -and $script:pageHealRestarts -gt 0) {
        Write-Log ("PAGE-HEAL: page healthy - reset restart counter (was $($script:pageHealRestarts))")
        $script:pageHealRestarts = 0
        $script:pageHealQuietUntil = $null
        $script:pageHealAlerted = $false
    }
    # P2.2 按需 reload(替代原每 2 分钟无条件刷新):空闲且距上次活动超过阈值才刷新;忙时超过 30 分钟兜底
    $minsSinceReload = [int]((Get-Date) - $script:lastReload).TotalMinutes
    $minsSinceActivity = [int]((Get-Date) - $ctx.lastActivity).TotalMinutes
    if ($minsSinceReload -ge $script:reloadIdleMin -and $snap.Count -eq 0 -and $minsSinceActivity -ge $script:reloadIdleMin) {
        Invoke-PageReload "Scheduled page reload (${minsSinceReload}m since last, idle ${minsSinceActivity}m)"
        return @{ Action = 'Reloaded' }
    } elseif ($minsSinceReload -ge 30) {
        # 长时间无法空闲（一直在处理会话），强制刷新防止列表失活
        Invoke-PageReload "Forced page reload (${minsSinceReload}m, busy)"
        return @{ Action = 'Reloaded' }
    }
    return @{ Action = 'Normal' }
}

# 启动初始化:单实例保护 + PID 文件 + 退出清理 + 迁移/清理 + 脚本级运行态
function Initialize-MonitorRuntime {
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
    # P0 日志/快照治理(2026-09-18):启动时轮转 monitor.log 并执行快照保留(先 DryRun 记录再实际执行);失败不影响启动
    try {
        $__logMaxMb = 20
        $__logKeep = 10
        if ($script:skillCfg.PSObject.Properties.Name -contains 'log_max_mb' -and $script:skillCfg.log_max_mb) { $__logMaxMb = [int]$script:skillCfg.log_max_mb }
        if ($script:skillCfg.PSObject.Properties.Name -contains 'log_keep_files' -and $script:skillCfg.log_keep_files) { $__logKeep = [int]$script:skillCfg.log_keep_files }
        Write-Log (Invoke-LogRotation -LogDir $script:logFileDir -Name 'monitor' -MaxMb $__logMaxMb -KeepFiles $__logKeep)
    } catch { }
    try {
        $__snapDays = 90
        if ($script:skillCfg.PSObject.Properties.Name -contains 'snapshot_retention_days' -and $script:skillCfg.snapshot_retention_days) { $__snapDays = [int]$script:skillCfg.snapshot_retention_days }
        Write-Log (Invoke-SnapshotRetention -DataDir $script:dataDir -Days $__snapDays -DryRun)
        Write-Log (Invoke-SnapshotRetention -DataDir $script:dataDir -Days $__snapDays)
    } catch { }
    Invoke-LayoutMigration
    Write-Log "=== Monitor started (PID $PID, auto-reply engine built-in) ==="
    Cleanup-LegacyQueues
    Cleanup-StaleState
    $script:emptyStreak = 0
    # P2.2 reload 按需化:OneTalk 长连接会失效,但无需每 2 分钟无条件刷新。
    # 仅当 (a)列表抓取失败连续 2 次(emptyStreak, 上方处理), 或 (b)空闲超过 reload_idle_min(默认10分钟),
    # 或 (c)持续忙处理超过 30 分钟 时才 reload。列表有新会话/预览变化视为活跃,重置 idle 计时。
    $script:reloadIdleMin = 10
    if ($script:skillCfg -and $script:skillCfg.reload_idle_min) { $script:reloadIdleMin = [int]$script:skillCfg.reload_idle_min }
    if ($script:reloadIdleMin -lt 3) { $script:reloadIdleMin = 3 }
    $script:lastReload = Get-Date
    # CDP 连续失败计数：达到阈值触发 Chrome 自愈（重启+重登）
    $script:cdpFailStreak = 0
    # [FIX-PAGEHEALTH 2026-09-25] 数据面断连连续轮次（分级自愈用）
    $script:pageDownStreak = 0
    # [FIX-THROTTLE 2026-09-26] 自愈节流运行态
    $script:pageHealRestarts = 0      # 本轮累计 FORCE-RESTART 次数
    $script:pageHealQuietUntil = $null # 静默期截止时间
    $script:pageHealAlerted = $false   # 达上限后只告警一次
}

function Start-Monitor {
    Initialize-MonitorRuntime
    # 运行态上下文(显式传递,避免隐式作用域):state 去重 + 各类冷却/节流表 + 最近活动时间
    $ctx = @{
        state = $null
        openCooldown = @{}
        skipCooldown = @{}
        noReplyPreview = @{}
        sendFailCount = @{}
        failAlertAt = @{}
        lastActivity = Get-Date
    }
    while ($true) {
        $r = Invoke-ScanRound $ctx
        if ($r.Action -eq 'LockBusy') {
            Start-Sleep -Seconds 5
            continue
        }
        if ($r.Action -eq 'Reloaded') {
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
