// tests/cursors.test.js - CursorStore 行为测试:多消费者独立游标 + 持久化 + 重启不丢
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { CursorStore } = require('../lib/cursors.js');

function tmpFile() {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wccursor-')), 'cursors.json');
  return f;
}

test('新 store 无任何消费者游标,exists=false', () => {
  const s = new CursorStore(tmpFile());
  assert.strictEqual(s.exists('alibaba-auto-reply'), false);
  assert.strictEqual(s.get('alibaba-auto-reply'), 0);
});

test('set 后 get 返回该值,exists=true', () => {
  const s = new CursorStore(tmpFile());
  s.set('alibaba-auto-reply', 12345);
  assert.strictEqual(s.get('alibaba-auto-reply'), 12345);
  assert.strictEqual(s.exists('alibaba-auto-reply'), true);
});

test('多消费者互不覆盖', () => {
  const s = new CursorStore(tmpFile());
  s.set('alibaba-auto-reply', 100);
  s.set('agent-x', 50);
  s.set('alibaba-auto-reply', 200);
  assert.strictEqual(s.get('agent-x'), 50, 'agent-x 不被其他消费者推进影响');
  assert.strictEqual(s.get('alibaba-auto-reply'), 200);
});

test('持久化:重新加载后游标仍在(重启不丢)', () => {
  const f = tmpFile();
  const s1 = new CursorStore(f);
  s1.set('agent-x', 777);
  const s2 = new CursorStore(f);
  assert.strictEqual(s2.get('agent-x'), 777);
  assert.strictEqual(s2.exists('alibaba-auto-reply'), false);
});

test('list 返回全部消费者快照', () => {
  const s = new CursorStore(tmpFile());
  s.set('a', 1);
  s.set('b', 2);
  const all = s.list();
  assert.strictEqual(all['a'], 1);
  assert.strictEqual(all['b'], 2);
});

test('损坏文件回退为空 store 不崩溃', () => {
  const f = tmpFile();
  fs.writeFileSync(f, '{not-json', 'utf8');
  const s = new CursorStore(f);
  assert.strictEqual(s.exists('x'), false);
  s.set('x', 5);
  assert.strictEqual(s.get('x'), 5);
});

test('原子写:保存后无 .tmp 残留,文件始终为完整 JSON', () => {
  const f = tmpFile();
  const s = new CursorStore(f);
  s.set('a', 1);
  s.set('b', 2);
  assert.strictEqual(fs.existsSync(f + '.tmp'), false, 'tmp 文件应被 rename 掉');
  const raw = JSON.parse(fs.readFileSync(f, 'utf8'));
  assert.deepStrictEqual(raw, { a: 1, b: 2 });
});

test('seq 非整数被拒绝(不写入)', () => {
  const s = new CursorStore(tmpFile());
  s.set('a', -1);
  assert.strictEqual(s.exists('a'), false);
  s.set('a', 1.5);
  assert.strictEqual(s.exists('a'), false);
  s.set('a', 'NaN');
  assert.strictEqual(s.exists('a'), false);
});
