// tests/buffer.test.js - MessageBuffer 行为测试(红绿循环:先写测试再实现)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { MessageBuffer } = require('../lib/buffer.js');

test('push 赋 seq 且严格单调递增', () => {
  const b = new MessageBuffer();
  const m1 = b.push({ userid: 'u1', chatid: 'c1', content: 'hello' });
  const m2 = b.push({ userid: 'u2', chatid: '', content: 'world' });
  assert.ok(m1.seq < m2.seq, 'seq 必须严格递增');
  assert.strictEqual(m1.userid, 'u1');
  assert.strictEqual(m2.content, 'world');
  assert.ok(m1.ts.length > 0);
});

test('push 携带 userid/chatid 与 content', () => {
  const b = new MessageBuffer();
  const m = b.push({ userid: 'u9', chatid: 'c9', content: '中文内容' });
  assert.strictEqual(m.userid, 'u9');
  assert.strictEqual(m.chatid, 'c9');
  assert.strictEqual(m.content, '中文内容');
});

test('push 无 userid/chatid 时字段为空串(非 undefined)', () => {
  const b = new MessageBuffer();
  const m = b.push({ content: 'x' });
  assert.strictEqual(m.userid, '');
  assert.strictEqual(m.chatid, '');
});

test('listAfter 返回 seq>after 且按 seq 升序', () => {
  const b = new MessageBuffer();
  const a = b.push({ userid: 'u', content: 'a' });
  const c = b.push({ userid: 'u', content: 'c' });
  const d = b.push({ userid: 'u', content: 'd' });
  const items = b.listAfter(a.seq);
  assert.deepStrictEqual(items.map((m) => m.content), ['c', 'd']);
  assert.ok(items[0].seq < items[1].seq);
  assert.strictEqual(b.maxSeq(), d.seq);
});

test('listAfter 返回新数组(不共享内部引用)', () => {
  const b = new MessageBuffer();
  b.push({ userid: 'u', content: 'x' });
  const items = b.listAfter(0);
  assert.notStrictEqual(items, b._items);
});

test('maxSeq 无消息时为 0', () => {
  const b = new MessageBuffer();
  assert.strictEqual(b.maxSeq(), 0);
});

test('环形上限:超过 MAX=200 只保留最新 200 条', () => {
  const b = new MessageBuffer();
  for (let i = 0; i < 250; i++) { b.push({ userid: 'u', content: 'm' + i }); }
  assert.strictEqual(b._items.length, 200);
  assert.strictEqual(b.maxSeq(), b._items[b._items.length - 1].seq);
  const items = b.listAfter(0);
  assert.strictEqual(items.length, 200);
});

test('同毫秒连续 push 时 seq 仍严格递增(旧实现 bug 回归)', () => {
  const b = new MessageBuffer();
  const m1 = b.push({ userid: 'u', content: '1' });
  const m2 = b.push({ userid: 'u', content: '2' });
  assert.ok(m2.seq > m1.seq);
});
