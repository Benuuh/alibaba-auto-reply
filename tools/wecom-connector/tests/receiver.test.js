// tests/receiver.test.js - ReceiverCache 行为测试
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { ReceiverCache } = require('../lib/receiver.js');

function tmpFile() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wcrecv-')), 'receiver.json');
}

test('save 后 read 读回,重启(新实例同文件)不丢', () => {
  const f = tmpFile();
  const r1 = new ReceiverCache(f);
  r1.save({ last_userid: 'u1', last_ts: 't1' });
  const r2 = new ReceiverCache(f);
  const d = r2.read();
  assert.strictEqual(d.last_userid, 'u1');
  assert.strictEqual(d.last_ts, 't1');
});

test('多次 save 合并字段,不互相覆盖', () => {
  const f = tmpFile();
  const r = new ReceiverCache(f);
  r.save({ last_userid: 'u1', last_ts: 't1' });
  r.save({ last_chatid: 'c1', last_ts: 't2' });
  const d = r.read();
  assert.strictEqual(d.last_userid, 'u1');
  assert.strictEqual(d.last_chatid, 'c1');
  assert.strictEqual(d.last_ts, 't2');
});

test('文件不存在时 read 返回空对象', () => {
  const r = new ReceiverCache(tmpFile());
  assert.deepStrictEqual(r.read(), {});
});

test('损坏文件 read 回退空对象且 save 可重建', () => {
  const f = tmpFile();
  fs.writeFileSync(f, '{bad', 'utf8');
  const r = new ReceiverCache(f);
  assert.deepStrictEqual(r.read(), {});
  r.save({ last_userid: 'u2' });
  assert.strictEqual(r.read().last_userid, 'u2');
});

test('原子写:保存后无 .tmp 残留', () => {
  const f = tmpFile();
  const r = new ReceiverCache(f);
  r.save({ last_userid: 'u1' });
  assert.strictEqual(fs.existsSync(f + '.tmp'), false);
});
