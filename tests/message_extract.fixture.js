// Execute the production extractor against an invented DOM. No browser or network.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
let showTimeReads = 0;
function row(text, time, buyer = true, extra = {}) {
  const rich = {innerText: text};
  const images = (extra.images || []).map(url => ({getAttribute: name => name === 'src' ? url : ''}));
  return {
    innerText: text + (extra.card ? ' 系统自动发送' : ''),
    innerHTML: '', className: buyer ? 'message-item-wrapper item-left' : 'message-item-wrapper item-right',
    getAttribute() { showTimeReads++; throw new Error('showTime must not be read'); },
    querySelector(selector) {
      if (selector === '.item-base-info .name') return buyer ? {innerText: 'Buyer A'} : null;
      if (selector === '.item-base-info') return {innerText: (buyer ? 'Buyer A ' : '') + time};
      if (selector.startsWith('img[')) return images[0] || null;
      if (selector.includes('session-rich-content') || selector.includes('content-with-translation')) return rich;
      return null;
    },
    querySelectorAll(selector) { return selector === 'img' ? images : []; }
  };
}
async function extract(rows) {
  const contact = {innerText: 'Buyer A', querySelector: () => ({innerText: 'Buyer A'}), click() {}};
  const document = {
    querySelector: selector => selector === '.content-header' ? {innerText: 'Buyer A'} : null,
    querySelectorAll: selector => selector === '.contact-item-container' ? [contact] :
      selector === '[class*=message-item-wrapper]' ? rows : []
  };
  const result = await vm.runInNewContext(source, {
    document, Date, JSON, Promise, setTimeout: callback => callback(),
    btoa: value => Buffer.from(value, 'binary').toString('base64'), unescape, encodeURIComponent
  });
  return JSON.parse(result);
}
function timeOf(line) { const match = line.match(/@@MT:(\d+)/); return match ? Number(match[1]) : null; }
(async () => {
  const question = 'Is the rate still high for a 40ft container of modular cabins?';
  const reverse = await extract([
    row(question, '2026-10-4 14:33:39'),
    row('Do you have any upcoming procurement needs?', '2026-10-1 09:02:37', false),
    row('Shipping service Freight Supplier $0.30-0.80 最小订购量: 1 Kilometer', '2026-9-26 09:00:00', true,
      {card: true, images: ['https://example.alicdn.com/invented-product.png']})
  ]);
  const lines = reverse.msgs.split('\n');
  assert(timeOf(lines[0]) > timeOf(lines[1]) && timeOf(lines[1]) > timeOf(lines[2]));
  assert.strictEqual(timeOf(lines[0]), new Date(2026, 9, 4, 14, 33, 39).getTime());
  assert(!lines[0].includes('@@IMG:'));
  assert(lines[2].includes('@@IMG:') && lines[2].includes('@@CARD:system'));
  assert(!reverse.msgs.includes('系统自动发送'));
  const seconds = await extract([row('no', '2026-10-4 14:33:01'), row('ok', '2026-10-4 14:33:39')]);
  assert.strictEqual(timeOf(seconds.msgs.split('\n')[1]) - timeOf(seconds.msgs.split('\n')[0]), 38000);
  const missing = await extract([row('first', ''), row('second', '2026-10-4 14:33:39')]);
  assert.strictEqual(timeOf(missing.msgs.split('\n')[0]), null);
  const invalid = await extract([row('bad date', '2026-2-30 14:33:39')]);
  assert.strictEqual(timeOf(invalid.msgs), null);
  const image = await extract([row('', '2026-10-4 14:33:40', true,
    {images: ['https://example.alicdn.com/invented-cargo.png']})]);
  assert(image.msgs.startsWith('[BUYER] [IMG] @@IMG:') && timeOf(image.msgs));
  assert.strictEqual(showTimeReads, 0);
  process.stdout.write(JSON.stringify({reverse, missing, invalid, image, seconds}));
})().catch(error => { process.stderr.write(error.stack); process.exitCode = 1; });
