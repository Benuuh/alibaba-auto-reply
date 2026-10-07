# lib\msg_extract_js.ps1 - 页面消息行的**唯一**浏览器侧抽取实现（spec §3.1 / §4-1 / A07 / A16）
#
# 为什么单独成文件：生产发送前后的收据快照（lib\outbound_receipts.ps1）与 monitor 的会话读取
#   必须使用**同一份**真实消息边界、方向依据、平台 ID 与结构噪声规则。此前收据快照自己枚举
#   全部 message-item-wrapper、MessageId 恒为空、用"有没有名字"猜我方，于是 flow 卡与真实气泡
#   混在一起、身份也建立不起来（复核 R1）。统一到本文件后，两处产出的行逐字同源。
#
# 契约：
#   * 本文件只提供浏览器侧 JS 源码字符串，没有任何 PowerShell 副作用，可被任意调用方注入。
#   * __aarExtractRow(w)     ：一个 wrapper 元素 -> 逐条结构化观测（不是真实气泡时返回 null）。
#   * __aarRowsToLines(rows) ：观测数组 -> 与 monitor 完全一致的 [BUYER]/[ME] ... @@META 行。
#   * 正文、方向、结构类型、平台 ID、逐条来源标签都在这里一次确定；调用方不得各自再扫 DOM。
#   * 真实气泡一律保留（含身份不确定的）：只能把它们标成不确定观测，不得为通过收据测试而删除。
#   * [复核 R9] 附件证据先于 rich 判定：没有 .session-rich-content / .content-with-translation.text-content
#     的真实图片/文件气泡同样必须成为事件（body='[IMG]'），收据必须看到它而不是在假快照上成立。
#   * [复核 R10] dirsrc 的完整取值：layout（已核实的左右结构，方向由此**先**确定）
#     / name-field / translation-marker（观测性依据，只在没有明确结构时使用）
#     / conflict（左右结构同时在）/ missing（没有任何方向依据，显式记录为不明）。

$script:MessageRowExtractJs = @'
// ---- 逐条抽取：一个 message-item-wrapper -> 一条结构化观测（或 null） ----
// [复核 R9/R10] 判定顺序是固定的：结构类型 -> 附件与真实气泡边界 -> 正文 -> 方向。
//   * 附件证据必须在 rich 判定**之前**收集：图片/文件真实气泡在页面上没有文本 rich 节点时
//     也必须进入共享事件集合，不能靠"删掉这条气泡"让收据在假快照上成立。
//   * 方向由**已核实的左右结构**先确定（item-right/item-left）；页面显示的 name 字段与翻译
//     标记只是观测，不改写明确方向；左右结构同时出现或完全缺失时显式记录冲突/不明，
//     不默认当成买家问题，也不默认当成出站证明。
function __aarExtractRow(w){
  var cls = (w.className||'').toString();
  var inner = (w.innerText||'');
  var rich = w.querySelector('.content-with-translation.text-content, .session-rich-content');
  var txt = (rich && typeof rich.innerText === 'string') ? rich.innerText.replace(/\n+/g,' ').trim() : '';
  // [FIX-DUP 2026-09-25] 原文节点优先：译文是冗余的，且未渲染时会与原文重复导致 hash 突变
  var richOrig = w.querySelector('.session-rich-content.text')
              || w.querySelector('.content-with-translation .session-rich-content')
              || rich;
  var otxt = (richOrig && typeof richOrig.innerText === 'string') ? richOrig.innerText.replace(/\n+/g,' ').trim() : '';
  if (!otxt) { otxt = txt; }
  var systemCard = /系统自动发送/.test(inner + ' ' + txt + ' ' + otxt)
                || (/最小订购量|minimum\s+order|min\.?\s*order/i.test(otxt) && /\$\s*\d/.test(otxt));
  var clean = txt.replace(/翻译中…|反馈|已读|回复|翻译|Revert|由阿里提供|自动接待发送|系统自动发送/g,'').trim();
  otxt = otxt.replace(/系统自动发送|自动接待发送/g,'').trim();

  // ---- [复核 R9] 附件证据：先于 rich/正文判定收集，且不依赖方向 ----
  // B2 附件标记: 图片 src/data-src(阿里域, 去重, ≤3); 文件卡片兜底特征 "<name>.<ext> <size> K/M"
  var imgNodes = [];
  try { imgNodes = Array.prototype.slice.call(w.querySelectorAll('img') || []); } catch (e0) { imgNodes = []; }
  var imgUrls = [];
  for (var ii = 0; ii < imgNodes.length; ii++) {
    var iu = '';
    try { iu = imgNodes[ii].getAttribute('src') || imgNodes[ii].getAttribute('data-src') || ''; } catch (e1) { iu = ''; }
    if (!iu) { continue; }
    if (!/(alicdn\.com|alibaba\.com|aliimg\.com|data:image)/.test(iu)) { continue; }
    if (imgUrls.indexOf(iu) < 0) { imgUrls.push(iu); }
  }
  var hasAttachment = imgUrls.length > 0;
  if (!hasAttachment) {
    var attachEl = null;
    try { attachEl = w.querySelector('img[src*="alicdn"], [class*=image] img, [class*=Image] img, [class*=picture]'); } catch (e2) { attachEl = null; }
    hasAttachment = !!attachEl;
  }
  if (imgUrls.length > 3) { imgUrls = imgUrls.slice(0, 3); }
  var fileInfo = null;
  // 没有 rich 节点时，附件气泡自身的行文本就是文件卡（"<name>.<ext> <size> K"）。
  var fileSrc = clean || (rich ? '' : String(inner).replace(/\n+/g,' ').trim());
  var mf = fileSrc.match(/([^\s\/\\]+\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt))\s+(\d+(\.\d+)?\s*[KMG]?B?)/i);
  if (mf) {
    var furl = '';
    var anchors = w.querySelectorAll('a[href]');
    for (var ai = 0; ai < anchors.length; ai++) {
      var h = anchors[ai].getAttribute('href') || '';
      if (/^https?:/.test(h) && (/\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt)($|\?)/i.test(h) || /download/i.test(h))) { furl = h; break; }
    }
    if (!furl) {
      var mUrl = (w.innerHTML || '').match(/https?:\/\/[^"'\s<>]+\.(pdf|xlsx?|csv|docx?|pptx?|zip|rar|txt)(\?[^"'\s<>]*)?/i);
      if (mUrl) { furl = mUrl[0]; }
    }
    fileInfo = { name: mf[1], url: furl };
  }
  // [复核 R9] 真实气泡边界：既没有正文、也没有附件/文件证据的 wrapper 不是消息
  //   （公共控件/结构噪声可以排除）；带附件证据的一律保留，即使只能标成身份不确定。
  if (clean.length === 0 && !hasAttachment && !fileInfo) { return null; }
  // [SPEC 4.1 2026-10-03] NO text-length filter. The previous version dropped every message
  // whose cleaned text was <= 2 characters unless it carried an image, so "ok", "si" and "no"
  // never became message events at all - even though spec 4.1 requires short acknowledgements,
  // refusals, complaints, images and documents to ALL be able to form a new-message event.
  // Only a genuinely empty body is skipped here, and an empty body WITH an image still becomes
  // an attachment event. The buyer flag is taken from the same detection as every other message
  // (the old code hard-coded b:true for image-only rows, which mislabelled our own images).
  if (clean.length === 0) {
    clean = '[IMG]'; otxt = '[IMG]';
  }

  // ---- [复核 R10] 方向：已核实的左右结构优先；显示名与翻译标记只作观测 ----
  var nameEl0 = w.querySelector('.item-base-info .name');
  var buyerName0 = '';
  try { buyerName0 = ((nameEl0 && nameEl0.innerText) || '').replace(/\s+/g,' ').trim(); } catch (e3) { buyerName0 = ''; }
  var translationMark = /由阿里翻译提供|翻译中/.test(txt);
  var hasLeft = cls.indexOf('item-left') >= 0;
  var hasRight = cls.indexOf('item-right') >= 0;
  var dirVal = 'unknown';
  var dirSrc = 'missing';
  if (hasRight && !hasLeft) { dirVal = 'out'; dirSrc = 'layout'; }
  else if (hasLeft && !hasRight) { dirVal = 'in'; dirSrc = 'layout'; }
  else if (hasLeft && hasRight) { dirVal = 'unknown'; dirSrc = 'conflict'; }
  else if (buyerName0) { dirVal = 'in'; dirSrc = 'name-field'; }
  else if (translationMark) { dirVal = 'in'; dirSrc = 'translation-marker'; }
  var isBuyer0 = (dirVal === 'in');
  var structType = 'message';
  if (cls.indexOf('flow-message-item-wrapper') >= 0) { structType = 'flow'; }
  else if (/message-summary|summary-message/.test(cls)) { structType = 'summary'; }

  var isBuyer = isBuyer0;
  var ts = '';
  // Only the time printed on THIS message is evidence. data-expinfo.showTime is a
  // conversation/render clock and must never be used as a fallback for ordering.
  var baseEl = w.querySelector('.item-base-info');
  var baseTxt = (baseEl && baseEl.innerText) || '';
  var m2 = baseTxt.match(/\b(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\b/);
  if (m2) {
    var y = +m2[1], mo = +m2[2] - 1, d = +m2[3], h = +m2[4], mi = +m2[5], s = +(m2[6] || 0);
    var dt = new Date(y, mo, d, h, mi, s);
    if (dt.getFullYear() === y && dt.getMonth() === mo && dt.getDate() === d
        && dt.getHours() === h && dt.getMinutes() === mi && dt.getSeconds() === s) ts = String(dt.getTime());
  }
  // [2026-10-07 spec §3.1] 逐条结构化观测：平台 ID（若页面确实给出）、结构类型、
  //   逐条绑定的原始来源字段/标签。标签只作原始观测，不作为来源证明（规则由 lib\msg_events.ps1 判定）。
  var mid = '';
  try {
    if (w.dataset) { mid = w.dataset.messageId || w.dataset.msgId || w.dataset.messageid || ''; }
    if (!mid && w.attributes && w.attributes.length) {
      for (var ai2 = 0; ai2 < w.attributes.length; ai2++) {
        var an = String(w.attributes[ai2].name || '').toLowerCase();
        if (an === 'data-message-id' || an === 'data-msg-id' || an === 'data-id') { mid = String(w.attributes[ai2].value || ''); break; }
      }
    }
  } catch (e) { mid = ''; }
  mid = mid ? String(mid).substring(0, 80) : '';
  var rowText = inner + ' ' + txt + ' ' + otxt;
  var srcTags = [];
  if (/自动接待发送/.test(rowText)) { srcTags.push('tag:自动接待发送'); }
  if (/系统自动发送/.test(rowText)) { srcTags.push('tag:系统自动发送'); }
  if (/去优化/.test(rowText)) { srcTags.push('tag:去优化'); }
  var tprec = ts ? 'second' : 'none';
  return {b: isBuyer, t: clean.substring(0,1000), body: clean.substring(0,1000), ot: otxt.substring(0,1000),
          ts: ts, card: isBuyer && systemCard, imgs: isBuyer ? imgUrls : [], file: isBuyer ? fileInfo : null,
          mid: mid, st: structType, src: srcTags, dir: dirVal, dirsrc: dirSrc, tprec: tprec};
}

// ---- 行序列化：结构化观测数组 -> 与生产完全一致的抽取行 ----
function __aarRowsToLines(out){
  // Keep attachments on their own rows. The PS normalizer determines chronology before
  // selecting the latest attachment or resolving references to earlier images/documents.
  out.forEach(function(o){
    if (o.b && o.imgs.length) { o.t += ' @@IMG:' + o.imgs.join('|'); }
    if (o.b && o.file) { o.t += ' @@FILE:' + encodeURIComponent(o.file.name) + '|' + (o.file.url || ''); }
  });
  var lines = [];
  // Keep @@TS for legacy source classification; @@MT explicitly identifies the per-message clock.
  // Original text remains base64 UTF-8 in @@OT for the existing ledger key.
  out.forEach(function(o){
    var line = (o.b ? '[BUYER] ' : '[ME] ') + o.t + (o.ts ? ' @@TS:' + o.ts + ' @@MT:' + o.ts : '');
    if (o.card) line += ' @@CARD:system';
    if (o.b && o.ot) {
      var otb = (typeof btoa === 'function') ? btoa(unescape(encodeURIComponent(o.ot))) : '';
      if (otb) { line += ' @@OT:' + otb; }
    }
    // [2026-10-07 spec §3.1] @@MID 只在页面确实给出稳定 ID 时输出（当前不伪造；空即不写）。
    if (o.mid) { line += ' @@MID:' + o.mid; }
    // @@META 固定在行尾，是唯一可信的逐条元数据载体；正文里的同类文本不会被当成元数据。
    //   正文真值直接放在 t 里（base64），因此正文中出现 "@@" 也不会影响身份或正文哈希。
    var metaObj = {
      v: 'msgevent-2026-10-07.1',
      t: (typeof btoa === 'function') ? btoa(unescape(encodeURIComponent((o.body === undefined ? o.t : o.body)))) : '',
      dir: o.dir, dirsrc: o.dirsrc, mid: o.mid || '', ts: o.ts || '',
      tprec: o.tprec || 'none', st: o.st || 'message', src: o.src || [],
      at: new Date().toISOString(),
      idq: (o.mid ? 'platform-id' : (o.ts ? 'composite' : 'unusable'))
    };
    var metaB64 = (typeof btoa === 'function') ? btoa(unescape(encodeURIComponent(JSON.stringify(metaObj)))) : '';
    if (metaB64) { line += ' @@META:' + metaB64; }
    lines.push(line);
  });
  return lines;
}
'@

function Get-MessageRowExtractJs { return [string]$script:MessageRowExtractJs }

# Conversation boundaries are shared by monitoring and receipt snapshots. Display names are
# normalized exact matches, not stable conversation IDs; suspicious cross-name copies block.
$script:ConversationScopeJs = @'
function __aarName(value){
  return String(value || '').replace(/[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]/g, '')
    .replace(/\s+/g, ' ').trim().toLowerCase();
}
function __aarVisible(node){
  if (!node || node.isConnected === false || typeof node.getClientRects !== 'function') return false;
  if (!node.getClientRects().length) return false;
  if (typeof getComputedStyle === 'function') {
    var style = getComputedStyle(node);
    if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
  }
  return true;
}
function __aarFindContact(expected){
  var key = __aarName(expected);
  if (!key) throw new Error('EMPTY_TARGET');
  var found = Array.from(document.querySelectorAll('.contact-item-container')).filter(function(node){
    var name = node.querySelector('.contact-info .name');
    return __aarVisible(node) && name && __aarName(name.innerText || name.textContent) === key;
  });
  if (!found.length) throw new Error('NOT_FOUND');
  if (found.length !== 1) throw new Error('AMBIGUOUS_CONTACT');
  return found[0];
}
function __aarScope(expected){
  var headers = Array.from(document.querySelectorAll('.content-header')).filter(__aarVisible);
  var panels = Array.from(document.querySelectorAll('.message-container')).filter(__aarVisible);
  if (headers.length !== 1) throw new Error('HEADER_COUNT_' + headers.length);
  if (panels.length !== 1) throw new Error('CONTAINER_COUNT_' + panels.length);
  var header = headers[0], panel = panels[0];
  if (!header.closest || header.closest('.message-container') !== panel || !panel.contains(header))
    throw new Error('HEADER_CONTAINER_MISMATCH');
  var name = String(header.innerText || header.textContent || '').split('\n')[0].trim();
  if (!__aarName(name)) throw new Error('EMPTY_HEADER');
  if (expected && __aarName(name) !== __aarName(expected)) throw new Error('TARGET_MISMATCH');
  return {name: name, key: __aarName(name), header: header, panel: panel};
}
function __aarRemember(snapshot){
  // Compare semantic events, never serialized @@META.at or DOM positions.
  if (!snapshot.fingerprint) return;
  var history = globalThis.__aarConversationReadHistory || [];
  if (history.some(function(item){ return item.key !== snapshot.scope.key && item.fingerprint === snapshot.fingerprint; }))
    throw new Error('CROSS_CONVERSATION_DUPLICATE');
  history = history.filter(function(item){ return item.key !== snapshot.scope.key; });
  history.push({key: snapshot.scope.key, fingerprint: snapshot.fingerprint});
  globalThis.__aarConversationReadHistory = history.slice(-32);
}
function __aarCapture(expected){
  var scope = __aarScope(expected), out = [];
  Array.from(scope.panel.querySelectorAll('[class*=message-item-wrapper]')).forEach(function(wrapper){
    if (!__aarVisible(wrapper)) return;
    if (!wrapper.closest || wrapper.closest('.message-container') !== scope.panel)
      throw new Error('ROW_CONTAINER_MISMATCH');
    var row = __aarExtractRow(wrapper);
    if (row) out.push(row);
  });
  var checked = __aarScope(expected);
  if (checked.header !== scope.header || checked.panel !== scope.panel || checked.key !== scope.key)
    throw new Error('SCOPE_CHANGED');
  var real = out.filter(function(row){ return row.st !== 'flow' && row.st !== 'summary' && row.st !== 'noise'; });
  if (!real.length) throw new Error('MESSAGES_NOT_READY');
  var semantic = real.map(function(row){
    return JSON.stringify([row.mid || '', row.dir, row.ts || '', row.body, row.ot, row.imgs, row.file]);
  }).sort().join('\n');
  var fingerprint = '';
  // Common single acknowledgements are not enough to prove a cross-conversation duplicate.
  if (real.some(function(row){ return row.mid; }) ||
      (real.length >= 2 && real.some(function(row){ return row.ts; }))) {
    fingerprint = semantic;
  }
  var snapshot = {scope: scope, rows: out, fingerprint: fingerprint, semantic: semantic};
  __aarRemember(snapshot);
  return snapshot;
}
'@

function Get-ConversationScopeJs { return [string]$script:ConversationScopeJs }

function Get-ConversationReadJs {
    param([string]$Buyer, [bool]$AlreadyOpen = $false)
    $target = ConvertTo-Json -InputObject $Buyer -Compress
    $open = $(if ($AlreadyOpen) { 'false' } else { 'true' })
    $rowJs = Get-MessageRowExtractJs
    $scopeJs = Get-ConversationScopeJs
    return @"
(async function(){
$rowJs
$scopeJs
  var target = $target;
  if ($open) {
    var contact;
    try { contact = __aarFindContact(target); } catch (error) { return JSON.stringify({error: error.message}); }
    // Preserve the old panel evidence before its header can change during navigation.
    try { __aarCapture(''); } catch (error) { /* the target still must pass its own guard */ }
    contact.click();
  }
  var failure = 'SWITCH_TIMEOUT';
  var previous = null;
  for (var attempt = 0; attempt < 12; attempt++) {
    if ($open || attempt) await new Promise(function(resolve){ setTimeout(resolve, 500); });
    try {
      var snapshot = __aarCapture(target);
      // The header can change before the messages finish rendering. Require two matching
      // nonempty reads of the same nodes; a changing/empty sample resets the check.
      if (!previous || previous.scope.panel !== snapshot.scope.panel ||
          previous.scope.header !== snapshot.scope.header || previous.semantic !== snapshot.semantic) {
        previous = snapshot;
        failure = 'MESSAGES_NOT_STABLE';
        continue;
      }
      var lines = __aarRowsToLines(snapshot.rows);
      var card = document.querySelector('.alicrm-customer-detail-card');
      var profile = card ? String(card.innerText || '').replace(/\s+/g, ' ').trim().substring(0, 300) : '';
      return JSON.stringify({name: snapshot.scope.name, msgs: lines.join('\n'), profile: profile,
        scope: {version: 1, key: snapshot.scope.key, boundary: 'single-visible-header-container'}});
    } catch (error) { previous = null; failure = error.message; }
  }
  return JSON.stringify({error: failure});
})()
"@
}

if (-not (Get-Command Get-MessageRowExtractJs -ErrorAction SilentlyContinue)) {
    throw 'msg_extract_js.ps1 failed to define Get-MessageRowExtractJs'
}
