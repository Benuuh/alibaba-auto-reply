// tests\outbound_receipt_dom.fixture.js
//
// [复核 R1/R9/R10] 执行**生产收据 DOM JavaScript**（lib\outbound_receipts.ps1::Get-OutboundSnapshot 内联的
//   真实脚本，由 lib\msg_extract_js.ps1 的共享抽取器组成）针对一组虚构 DOM 行，返回它实际产出的
//   抽取行 JSON。这里没有浏览器、没有网络、没有生产路径：只有 document 桩与 vm。
//
// 用法：node outbound_receipt_dom.fixture.js <jsFile> <scenario>
//   scenario: before | after-composite | after-platform-id | after-no-time | after-flow-only
//             | after-flow-and-real | after-attachment
//             | after-attachment-norich | after-own-attachment-norich
//             | after-right-with-name | after-right-with-translation | after-direction-conflict
const fs = require('fs');
const vm = require('vm');
const {documentFor} = require('./conversation_dom.fixture');

const source = fs.readFileSync(process.argv[2], 'utf8');
const scenario = process.argv[3] || 'before';

const REPLY = 'Your cartons are booked for Friday pickup.';
const QUESTION = 'Is the rate still valid for 40ft to Jeddah?';
const EARLIER = 'Our earlier reply about the rate.';

function row(opts) {
  const buyer = opts.buyer !== false;
  const extra = opts.labels ? ' ' + opts.labels.join(' ') : '';
  // [复核 R9] noRich：真实附件气泡没有 .session-rich-content / .content-with-translation.text-content。
  const rich = opts.noRich ? null : { innerText: opts.text };
  const images = (opts.images || []).map(u => ({ getAttribute: n => (n === 'src' || n === 'data-src' ? u : '') }));
  const nameText = opts.name !== undefined ? opts.name : (buyer ? 'Buyer A' : '');
  const layout = opts.layout !== undefined ? opts.layout : (buyer ? 'item-left item-left-text' : 'item-right');
  const el = {
    innerText: opts.text + extra,
    innerHTML: '',
    className: 'message-item-wrapper ' + layout +
      (opts.flow ? ' flow-message-item-wrapper' : '') + ' wider messenger',
    getAttribute() { throw new Error('attributes must not be read directly'); },
    querySelector(sel) {
      if (sel === '.item-base-info .name') return nameText ? { innerText: nameText } : null;
      if (sel === '.item-base-info') return { innerText: (nameText ? nameText + ' ' : '') + (opts.time || '') };
      if (sel === 'img') return images[0] || null;
      if (sel.startsWith('img[')) return images[0] || null;
      if (sel.includes('session-rich-content') || sel.includes('content-with-translation')) return rich;
      return null;
    },
    querySelectorAll(sel) { return sel === 'img' ? images : []; }
  };
  if (opts.mid) { el.dataset = { messageId: opts.mid }; }
  return el;
}

const before = [
  row({ text: QUESTION, time: '2026-10-5 09:00:00' }),
  row({ text: EARLIER, time: '2026-10-5 09:01:00', buyer: false }),
  // flow 卡：真实页面里与消息混排，必须被标成结构噪声而不是真实气泡
  row({ text: '进展 买家确认采购产品链接及规格', time: '2026-10-5 09:02:00', flow: true })
];

let rows = before.slice();
if (scenario === 'after-composite') {
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', buyer: false }));
} else if (scenario === 'after-platform-id') {
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', buyer: false, mid: 'PLAT-4242' }));
} else if (scenario === 'after-no-time') {
  // 没有逐条时间的真实气泡：身份无法建立，但**必须保留**在快照里
  rows.push(row({ text: REPLY, time: '', buyer: false }));
} else if (scenario === 'after-flow-only') {
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', flow: true }));
} else if (scenario === 'after-flow-and-real') {
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', flow: true }));
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:01', buyer: false }));
} else if (scenario === 'after-attachment') {
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', buyer: false }));
  rows.push(row({ text: '', time: '2026-10-5 09:03:05', images: ['https://example.alicdn.com/invented.png'] }));
} else if (scenario === 'after-attachment-norich') {
  // [复核 R9] 买家侧真实图片气泡，**没有** rich 文本节点：必须留在共享事件集合里，
  //   而不是被抽取器删除（那会让收据在"少了一条气泡"的假快照上成立）。
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', buyer: false }));
  rows.push(row({ text: '', time: '2026-10-5 09:03:05', images: ['https://example.alicdn.com/invented-norich.png'], noRich: true }));
} else if (scenario === 'after-own-attachment-norich') {
  // [复核 R9] 我方侧的无 rich 附件气泡：同样不得被删除来换取"唯一新增事件"。
  rows.push(row({ text: '', time: '2026-10-5 09:03:05', buyer: false, images: ['https://example.alicdn.com/invented-ours.png'], noRich: true }));
} else if (scenario === 'after-right-with-name') {
  // [复核 R10] 明确的 item-right 结构 + 页面给出显示名：方向由结构决定，显示名只是观测。
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', buyer: false, name: 'Fictional Owner' }));
} else if (scenario === 'after-right-with-translation') {
  // [复核 R10] 明确的 item-right + 正文带翻译提示：不得被改写成 in/[BUYER]。
  //   翻译提示前缀会被正文清洗规则整段剥掉，因此清洗后的正文仍与发送正文逐字一致。
  rows.push(row({ text: '翻译中…' + REPLY, time: '2026-10-5 09:03:00', buyer: false }));
} else if (scenario === 'after-direction-conflict') {
  // [复核 R10] 左右结构同时出现：方向冲突必须显式记录，不能默认成买家问题或出站证明。
  rows.push(row({ text: REPLY, time: '2026-10-5 09:03:00', layout: 'item-left item-right' }));
} else if (scenario !== 'before') {
  throw new Error('unknown scenario: ' + scenario);
}

const documentStub = documentFor(rows);

(async () => {
  const out = await vm.runInNewContext(source, {
    document: documentStub, Date, JSON, Promise,
    btoa: v => Buffer.from(v, 'binary').toString('base64'), unescape, encodeURIComponent
  });
  process.stdout.write(String(out));
})().catch(e => { process.stderr.write(e.stack); process.exitCode = 1; });
