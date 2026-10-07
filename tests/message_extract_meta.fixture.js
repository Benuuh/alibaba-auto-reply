// Execute the production extractor against an invented DOM and verify per-message metadata.
// No browser, no network, no production paths.
//
// [复核 R9/R10] 第二组虚构行专门覆盖抽取顺序的两个反例：
//   R9  没有 .session-rich-content / .content-with-translation.text-content 的真实图片气泡
//       （修复前 __aarExtractRow 直接 return null，整条气泡消失）；
//   R10 明确的 item-right 结构遇到显示名或翻译提示时不得被改写成 in/[BUYER]，
//       左右结构同时出现时必须显式记录冲突而不是默认成买家问题或出站证明。
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const {documentFor} = require('./conversation_dom.fixture');
const source = fs.readFileSync(process.argv[2], 'utf8');
const REPLY = 'Your cartons are booked for Friday pickup.';
let showTimeReads = 0;
function row(text, time, opts = {}) {
  const buyer = opts.buyer !== false;
  const extraText = opts.labels ? ' ' + opts.labels.join(' ') : '';
  const rich = opts.noRich ? null : { innerText: text };
  const images = (opts.images || []).map(url => ({ getAttribute: name => (name === 'src' ? url : ''), dataset: {} }));
  const nameText = opts.name !== undefined ? opts.name : (buyer ? 'Buyer A' : '');
  const layout = opts.layout !== undefined ? opts.layout : (buyer ? 'item-left item-left-text' : 'item-right');
  const el = {
    innerText: text + extraText,
    innerHTML: '',
    className: 'message-item-wrapper ' + layout +
      (opts.flow ? ' flow-message-item-wrapper' : '') + ' wider messenger',
    getAttribute() { showTimeReads++; throw new Error('showTime/attribute must not be read'); },
    querySelector(selector) {
      if (selector === '.item-base-info .name') return nameText ? { innerText: nameText } : null;
      if (selector === '.item-base-info') return { innerText: (nameText ? nameText + ' ' : '') + time };
      if (selector.startsWith('img[')) return images[0] || null;
      if (selector.includes('session-rich-content') || selector.includes('content-with-translation')) return rich;
      return null;
    },
    querySelectorAll(selector) { return selector === 'img' ? images : []; }
  };
  if (opts.mid) { el.dataset = { messageId: opts.mid }; }
  return el;
}
async function extract(rows) {
  const document = documentFor(rows);
  const result = await vm.runInNewContext(source, {
    document, Date, JSON, Promise, setTimeout: cb => cb(),
    btoa: value => Buffer.from(value, 'binary').toString('base64'), unescape, encodeURIComponent
  });
  return JSON.parse(result);
}
function metaOf(line) {
  const m = line.match(/@@META:([A-Za-z0-9+/=_-]+)\s*$/);
  if (!m) return null;
  try { return JSON.parse(Buffer.from(m[1], 'base64').toString('utf8')); } catch (e) { return null; }
}
(async () => {
  const question = 'Is the rate still high for a 40ft container of modular cabins?';
  const res = await extract([
    row('进展 买家确认采购产品链接及规格', '2026-10-5 09:00:00', { flow: true, buyer: true }),
    row('消息总结', '2026-10-5 09:00:10', { flow: true, buyer: false }),
    row('ok', '2026-10-5 09:01:00', { buyer: true }),
    row(question, '2026-10-5 09:02:00', { buyer: true }),
    row('Our team will assist you here.', '2026-10-5 09:03:00', { buyer: false, labels: ['自动接待发送', '去优化'], mid: 'PLAT-777' }),
    row('', '2026-10-5 09:04:00', { buyer: true, images: ['https://example.alicdn.com/invented.png'] }),
    row('نقدر نشحن إلى الرياض', '2026-10-5 09:05:00', { buyer: false, labels: ['去优化'] })
  ]);
  const lines = res.msgs.split('\n');
  assert.strictEqual(showTimeReads, 0, 'the extractor must not read element attributes via getAttribute');
  const metas = lines.map(metaOf);
  assert(metas.every(m => m && m.v === 'msgevent-2026-10-07.1'), 'every line carries the metadata payload');
  const flow = metas.filter(m => m.st === 'flow' || m.st === 'summary');
  assert.strictEqual(flow.length, 2, 'flow and summary rows are marked structurally, not dropped');
  const platform = metas.find(m => m.mid === 'PLAT-777');
  assert(platform && platform.dir === 'out' && platform.tprec === 'second', 'platform id row keeps direction and precision');
  assert(platform.src.indexOf('tag:自动接待发送') >= 0 && platform.src.indexOf('tag:去优化') >= 0,
    'raw source labels are preserved as metadata');
  assert(!res.msgs.includes('自动接待发送'), 'the UI label is not left in the visible body (ledger keys must not drift)');
  const shortMsgs = lines.filter(l => l.startsWith('[BUYER] ok '));
  assert.strictEqual(shortMsgs.length, 1, 'short acknowledgements survive extraction');
  const imgMsg = lines.find(l => l.indexOf('@@IMG:') >= 0);
  assert(imgMsg && metaOf(imgMsg).dir === 'in', 'image-only messages stay real events');
  const decoded = metas.map(m => Buffer.from(m.t, 'base64').toString('utf8'));
  assert(decoded.indexOf('ok') >= 0 && decoded.indexOf(question) >= 0 && decoded.some(d => d === '[IMG]'),
    'the metadata body is the authoritative text');
  // Body stability: the decoded body must equal the DOM text minus UI labels the legacy cleaner strips.
  const our = metas.find(m => m.mid === 'PLAT-777');
  assert.strictEqual(Buffer.from(our.t, 'base64').toString('utf8'), 'Our team will assist you here.',
    'body text is unchanged by the metadata upgrade');

  // ---------------------------------------------------------------- [复核 R9/R10] 第二组
  const strict = await extract([
    // 明确的右侧结构 + 页面显示名：方向必须由结构决定
    row(REPLY, '2026-10-5 10:00:00', { buyer: false, name: 'Fictional Owner' }),
    // 明确的右侧结构 + 正文带翻译提示：清洗后正文与发送正文逐字一致，方向仍必须是 out
    row('翻译中…' + REPLY, '2026-10-5 10:01:00', { buyer: false }),
    // 没有 rich 文本节点的真实图片气泡：必须保留，且带 @@IMG
    row('', '2026-10-5 10:02:00', { images: ['https://example.alicdn.com/invented-norich.png'], noRich: true }),
    // 左右结构同时出现：方向冲突必须显式记录（这一条排在最后，用于验证发送闸门）
    row(REPLY, '2026-10-5 10:03:00', { layout: 'item-left item-right' })
  ]);
  const sLines = strict.msgs.split('\n');
  const sMetas = sLines.map(metaOf);
  assert.strictEqual(sLines.length, 4, 'every invented row must still produce a line');
  assert(sMetas.every(m => !!m), 'every invented row carries metadata');
  const explicitRightBeatsName = (sMetas[0].dir === 'out' && sMetas[0].dirsrc === 'layout');
  const explicitRightBeatsTranslation = (sMetas[1].dir === 'out' && sMetas[1].dirsrc === 'layout');
  const translatedBodyStable = Buffer.from(sMetas[1].t, 'base64').toString('utf8') === REPLY;
  const imageWithoutRichRetained = (sMetas[2].dir === 'in' && sLines[2].indexOf('@@IMG:') >= 0 &&
    Buffer.from(sMetas[2].t, 'base64').toString('utf8') === '[IMG]');
  const directionConflictRecorded = (sMetas[3].dir === 'unknown' && sMetas[3].dirsrc === 'conflict');
  assert(explicitRightBeatsName, 'an explicit item-right must win over the display name');
  assert(explicitRightBeatsTranslation, 'an explicit item-right must win over the translation marker');
  assert(translatedBodyStable, 'the translated row still carries the sent body');
  assert(imageWithoutRichRetained, 'an image bubble without a rich text node must be kept');
  assert(directionConflictRecorded, 'a direction conflict is recorded, never guessed');

  process.stdout.write(JSON.stringify({
    msgs: res.msgs,
    hasMeta: metas.every(m => !!m),
    flowExcluded: flow.length === 2,
    realBubbles: shortMsgs.length === 1 && !!imgMsg,
    showTimeReads,
    labelsInMeta: platform.src.length === 2,
    bodyStable: Buffer.from(our.t, 'base64').toString('utf8') === 'Our team will assist you here.',
    strictMsgs: strict.msgs,
    explicitRightBeatsName,
    explicitRightBeatsTranslation,
    translatedBodyStable,
    imageWithoutRichRetained,
    directionConflictRecorded
  }));
})().catch(error => { process.stderr.write(error.stack); process.exitCode = 1; });
