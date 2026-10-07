const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const {documentFor} = require('./conversation_dom.fixture');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let passed = 0;
function rows() {
  return ['first question', 'latest question'].map((text, i) => ({
    className: 'message-item-wrapper item-left', innerText: text,
    dataset: {messageId: 'invented-message-' + i},
    querySelector(sel) {
      if (sel === '.item-base-info .name') return {innerText: 'Buyer A'};
      if (sel === '.item-base-info') return {innerText: '2026-10-5 09:00:0' + i};
      if (sel.includes('session-rich-content')) return {innerText: text};
      return null;
    },
    querySelectorAll() { return []; }
  }));
}
function context(document) {
  return vm.createContext({document, Date, JSON, Promise, setTimeout: cb => cb(),
    btoa: x => Buffer.from(x, 'binary').toString('base64'), unescape, encodeURIComponent});
}
async function run(code, opts = {}, ctx) {
  const document = documentFor(opts.rows || rows(), opts);
  ctx = ctx || context(document);
  ctx.document = document;
  return {result: JSON.parse(await vm.runInContext(code, ctx)), ctx};
}
function check(name, condition) { assert(condition, name); passed++; }
(async () => {
  let x = await run(scripts.readA);
  check('normal target is scoped', x.result.name === 'Buyer A' && x.result.scope.key === 'buyer a');
  x = await run(scripts.readA, {outsideRows: rows()});
  check('global residual rows excluded', x.result.msgs.split('\n').length === 2);
  x = await run(scripts.readA, {contacts: ['Buyer AB', 'Buyer A'], preview: 'Buyer A'});
  check('exact name wins over preview and longer substring', x.result.name === 'Buyer A');
  x = await run(scripts.readA, {contacts: ['Buyer AB'], preview: 'Buyer A'});
  check('preview match is not a contact match', x.result.error === 'NOT_FOUND');
  x = await run(scripts.readA, {contacts: ['Buyer A', 'Buyer A']});
  check('duplicate target names refused', x.result.error === 'AMBIGUOUS_CONTACT');
  x = await run(scripts.readA, {contacts: ['  BUYER\u200b  A  ']});
  check('invisible characters and whitespace normalized', x.result.scope.key === 'buyer a');
  x = await run(scripts.readA, {extraVisiblePanel: true});
  check('multiple visible panels refused', x.result.error === 'CONTAINER_COUNT_2');
  x = await run(scripts.readA, {extraHeader: true});
  check('multiple visible headers refused', x.result.error === 'HEADER_COUNT_2');
  x = await run(scripts.readA, {detachedHeader: true});
  check('header in wrong container refused', x.result.error === 'HEADER_CONTAINER_MISMATCH');
  x = await run(scripts.readA, {initialName: 'Buyer B', neverSwitch: true});
  check('wrong header after polling never accepted', x.result.error === 'TARGET_MISMATCH');
  x = await run(scripts.readA, {initialName: 'Buyer B'});
  check('header switches before old rows clear', x.result.error === 'CROSS_CONVERSATION_DUPLICATE');
  const first = await run(scripts.readA);
  x = await run(scripts.readB, {name: 'Buyer B', contacts: ['Buyer B']}, first.ctx);
  check('same semantic events under different names refused', x.result.error === 'CROSS_CONVERSATION_DUPLICATE');
  x = await run(scripts.readA, {}, first.ctx);
  check('repeat read of same target remains valid', !x.result.error);
  x = await run(scripts.already, {contacts: []});
  check('already open can be read without clicking a list contact', x.result.name === 'Buyer A');
  x = await run(scripts.already, {name: 'Buyer B'});
  check('already open still verifies target', x.result.error === 'TARGET_MISMATCH');
  x = await run(scripts.snapshot, {outsideRows: rows()});
  check('receipt snapshot only contains current panel', x.result.name === 'Buyer A' && x.result.lines.length === 2);
  x = await run(scripts.snapshot, {name: 'Buyer B'});
  check('receipt snapshot rejects different buyer', x.result.error === 'TARGET_MISMATCH');
  x = await run(scripts.snapshot, {extraVisiblePanel: true});
  check('receipt cannot accept another active panel', x.result.error === 'CONTAINER_COUNT_2');
  x = await run(scripts.already, {rows: []});
  check('empty conversation never succeeds', x.result.error === 'MESSAGES_NOT_READY');
  x = await run(scripts.snapshot, {rows: []});
  check('empty receipt snapshot is rejected', x.result.error === 'MESSAGES_NOT_READY');
  x = await run(scripts.already, {rowSequence: [[], rows(), rows()]});
  check('delayed message rendering recovers after stable samples', x.result.name === 'Buyer A');
  x = await run(scripts.already, {rowSequence: Array.from({length: 12}, (_, i) => rows().slice(0, i % 2 + 1))});
  check('continually changing rows never succeed', x.result.error === 'MESSAGES_NOT_STABLE');
  x = await run(scripts.readB, {name: 'Buyer B', contacts: ['Buyer B'], rows: rows().reverse()}, first.ctx);
  check('reordered duplicate DOM is still detected', x.result.error === 'CROSS_CONVERSATION_DUPLICATE');
  const one = await run(scripts.readA, {rows: rows().slice(0, 1)});
  x = await run(scripts.readB, {name: 'Buyer B', contacts: ['Buyer B'], rows: rows().slice(0, 1)}, one.ctx);
  check('single stable message ID under another name is refused', x.result.error === 'CROSS_CONVERSATION_DUPLICATE');
  process.stdout.write('PASS conversation_scope DOM regressions=' + passed + '\n');
})().catch(e => {process.stderr.write(e.stack); process.exitCode=1;});
