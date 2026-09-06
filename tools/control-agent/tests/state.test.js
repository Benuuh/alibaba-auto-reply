// tests/state.test.js - 状态存储:游标/待确认/历史(重启不丢,滚动上限)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { StateStore } = require('../lib/state.js');

function tmpCfg(extra) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcstate-'));
  return Object.assign({
    cursor_file: path.join(d, 'cursor.json'),
    pending_file: path.join(d, 'pending.json'),
    history_file: path.join(d, 'history.jsonl'),
    history_max: 5
  }, extra || {});
}

test('游标:初始 0,保存后可读回,新实例(重启)不丢', () => {
  const s1 = new StateStore(tmpCfg());
  assert.strictEqual(s1.getCursor(), 0);
  s1.saveCursor(12345);
  const s2 = new StateStore(tmpCfg());
  // 同一文件:
  const cfg = tmpCfg();
  const a = new StateStore(cfg);
  a.saveCursor(777);
  const b = new StateStore(cfg);
  assert.strictEqual(b.getCursor(), 777);
});

test('游标:非法值拒绝', () => {
  const s = new StateStore(tmpCfg());
  assert.strictEqual(s.saveCursor(-1), false);
  assert.strictEqual(s.saveCursor(1.5), false);
  assert.strictEqual(s.getCursor(), 0);
});

test('待确认:保存/读取/移除/过期清理', () => {
  const cfg = tmpCfg();
  const s = new StateStore(cfg);
  s.savePending({ seq: 1, code: '1111', expire_at: 100 });
  s.savePending({ seq: 2, code: '2222', expire_at: 200 });
  assert.strictEqual(s.getPending(1).code, '1111');
  const removed = s.cleanupExpiredPending(150);
  assert.strictEqual(removed, 1, '过期 1 条');
  assert.strictEqual(s.getPending(1), null);
  assert.strictEqual(s.getPending(2).code, '2222');
  assert.strictEqual(s.removePending(2), true);
  assert.strictEqual(s.getPending(2), null);
});

test('历史:追加 + 超上限滚动保留最后 N 条', () => {
  const cfg = tmpCfg({ history_max: 3 });
  const s = new StateStore(cfg);
  for (let i = 1; i <= 7; i++) { s.appendHistory({ n: i }); }
  const lines = fs.readFileSync(cfg.history_file, 'utf8').split('\n').filter((l) => l.trim());
  assert.strictEqual(lines.length, 3, '只保留最后 3 条');
  assert.ok(lines[0].includes('"n":5'), '首行是最新的保留起点');
  assert.ok(lines[2].includes('"n":7'));
});

test('损坏文件回退默认不崩溃', () => {
  const cfg = tmpCfg();
  fs.writeFileSync(cfg.cursor_file, '{bad', 'utf8');
  const s = new StateStore(cfg);
  assert.strictEqual(s.getCursor(), 0);
  s.saveCursor(5);
  assert.strictEqual(s.getCursor(), 5);
});
