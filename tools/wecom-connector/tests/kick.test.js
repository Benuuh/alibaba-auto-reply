// tests/kick.test.js - decideKickBackoff 退避决策纯函数测试(含 loadConfig 新键透出)
// 发现机制:tests\run_tests.ps1 以 -Filter "*.test.js" 收集本目录下全部 *.test.js,无需登记
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { decideKickBackoff } = require('../lib/kick.js');
const { loadConfig } = require('../lib/config.js');

const CFG = { windowMin: 30, threshold: 3, shortBackoffSec: 60, longBackoffMin: 30 };
const MIN = 60000;

test('用例1: 窗口内 1 次踢下线 -> long=false, 退避 = now + shortBackoffSec*1000', () => {
  const now = 1700000000000;
  const r = decideKickBackoff([], now, CFG);
  assert.strictEqual(r.long, false);
  assert.strictEqual(r.backoffUntilMs, now + CFG.shortBackoffSec * 1000);
  assert.deepStrictEqual(r.kicks, [now]);
});

test('用例2: 窗口内连续 3 次 -> 第 3 次 long=true, 退避 = now + longBackoffMin*60000', () => {
  const t0 = 1700000000000;
  const r1 = decideKickBackoff([], t0, CFG);
  assert.strictEqual(r1.long, false);
  const r2 = decideKickBackoff(r1.kicks, t0 + 1000, CFG);
  assert.strictEqual(r2.long, false);
  const r3 = decideKickBackoff(r2.kicks, t0 + 2000, CFG);
  assert.strictEqual(r3.long, true, '第 3 次达到阈值 threshold=3');
  assert.strictEqual(r3.backoffUntilMs, t0 + 2000 + CFG.longBackoffMin * MIN);
  assert.strictEqual(r3.kicks.length, 3);
});

test('用例3: 窗口外旧记录被剔除(now - t >= windowMin*60000 不计入)', () => {
  const now = 1700000000000;
  const justOutside = now - CFG.windowMin * MIN;          // 恰好等于边界 -> 剔除
  const wellOutside = now - CFG.windowMin * MIN - 1;      // 超出窗口 -> 剔除
  const justInside = now - CFG.windowMin * MIN + 1;       // 窗口内 -> 保留
  const r = decideKickBackoff([wellOutside, justOutside, justInside], now, CFG);
  assert.deepStrictEqual(r.kicks, [justInside, now]);
  assert.strictEqual(r.long, false, '仅剩 2 次(含本次),未达 threshold');
  assert.strictEqual(r.backoffUntilMs, now + CFG.shortBackoffSec * 1000);
});

test('用例4: 非数组 / NaN / 负数 -> 不抛异常,按有效项计算', () => {
  const now = 1700000000000;
  const inWindow = now - 1000;
  assert.doesNotThrow(() => decideKickBackoff(null, now, CFG));
  assert.doesNotThrow(() => decideKickBackoff(undefined, now, CFG));
  assert.doesNotThrow(() => decideKickBackoff('1700000000000', now, CFG));
  assert.doesNotThrow(() => decideKickBackoff({ length: 1 }, now, CFG));

  const rNull = decideKickBackoff(null, now, CFG);
  assert.deepStrictEqual(rNull.kicks, [now], '非数组 -> 只有本次');
  assert.strictEqual(rNull.long, false);

  const rJunk = decideKickBackoff([NaN, Infinity, -Infinity, -1, inWindow], now, CFG);
  // -1 是有限数(窗口判定 now-(-1) 远超窗口 -> 剔除);NaN/Infinity 非有限 -> 剔除
  assert.deepStrictEqual(rJunk.kicks, [inWindow, now]);
  assert.strictEqual(rJunk.long, false);

  const rAllJunk = decideKickBackoff([NaN, Infinity, -Infinity], now, CFG);
  assert.deepStrictEqual(rAllJunk.kicks, [now]);
  assert.strictEqual(rAllJunk.backoffUntilMs, now + CFG.shortBackoffSec * 1000);
});

test('用例2b: 次数边界 - 累计 <threshold 不长退避, 达到 threshold 即长退避', () => {
  const now = 1700000000000;
  // 本次之前窗口内已有 1 次 -> 本次为第 2 次,未达 threshold=3 -> 短退避
  const r2 = decideKickBackoff([now - 1000], now, CFG);
  assert.strictEqual(r2.kicks.length, 2);
  assert.strictEqual(r2.long, false);
  assert.strictEqual(r2.backoffUntilMs, now + CFG.shortBackoffSec * 1000);
  // 本次之前窗口内已有 2 次 -> 本次为第 3 次,达到 threshold -> 长退避
  const r3 = decideKickBackoff(r2.kicks, now + 1000, CFG);
  assert.strictEqual(r3.kicks.length, CFG.threshold);
  assert.strictEqual(r3.long, true);
  assert.strictEqual(r3.backoffUntilMs, now + 1000 + CFG.longBackoffMin * MIN);
});

// ---- loadConfig 透出新键(R5:只改 config.json 不改 lib\config.js 会导致开关静默失效) ----
function backupEnv() {
  const prev = {};
  for (const k of ['WX_EXIT_ON_KICKED_OFFLINE', 'WECOM_DATA_DIR']) { prev[k] = process.env[k]; }
  return prev;
}
function restoreEnv(prev) {
  for (const k of Object.keys(prev)) {
    if (prev[k] === undefined) { delete process.env[k]; } else { process.env[k] = prev[k]; }
  }
}
function tmpConf(obj) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wckick-'));
  const f = path.join(d, 'config.json');
  fs.writeFileSync(f, JSON.stringify(obj), 'utf8');
  return f;
}

test('loadConfig: 缺省时 kick 组为默认值(开关默认开)', () => {
  const prev = backupEnv();
  try {
    delete process.env.WX_EXIT_ON_KICKED_OFFLINE;
    const c = loadConfig(path.join(os.tmpdir(), 'no-such-kick-config.json'));
    assert.strictEqual(c.kick.exitOnKickedOffline, true, '默认开:只有显式 false 才关闭');
    assert.strictEqual(c.kick.exitDelayMs, 1000);
    assert.strictEqual(c.kick.windowMin, 30);
    assert.strictEqual(c.kick.threshold, 3);
    assert.strictEqual(c.kick.shortBackoffSec, 60);
    assert.strictEqual(c.kick.longBackoffMin, 30);
    assert.strictEqual(c.kick.stableResetMin, 10);
  } finally { restoreEnv(prev); }
});

test('loadConfig: config.json 下划线键生效(含 exit_on_kicked_offline=false)', () => {
  const prev = backupEnv();
  try {
    delete process.env.WX_EXIT_ON_KICKED_OFFLINE;
    const f = tmpConf({
      exit_on_kicked_offline: false,
      kick_exit_delay_ms: 2500,
      kick_window_min: 5,
      kick_threshold: 2,
      kick_short_backoff_sec: 3,
      kick_long_backoff_min: 1,
      kick_stable_reset_min: 1
    });
    const c = loadConfig(f);
    assert.strictEqual(c.kick.exitOnKickedOffline, false);
    assert.strictEqual(c.kick.exitDelayMs, 2500);
    assert.strictEqual(c.kick.windowMin, 5);
    assert.strictEqual(c.kick.threshold, 2);
    assert.strictEqual(c.kick.shortBackoffSec, 3);
    assert.strictEqual(c.kick.longBackoffMin, 1);
    assert.strictEqual(c.kick.stableResetMin, 1);
  } finally { restoreEnv(prev); }
});

test('loadConfig: 环境变量 WX_EXIT_ON_KICKED_OFFLINE 覆盖配置文件', () => {
  const prev = backupEnv();
  try {
    const f = tmpConf({ exit_on_kicked_offline: true });
    process.env.WX_EXIT_ON_KICKED_OFFLINE = 'false';
    assert.strictEqual(loadConfig(f).kick.exitOnKickedOffline, false, "env 'false' 关闭");
    process.env.WX_EXIT_ON_KICKED_OFFLINE = 'true';
    assert.strictEqual(loadConfig(f).kick.exitOnKickedOffline, true, "env 'true' 开启");
    process.env.WX_EXIT_ON_KICKED_OFFLINE = '0';
    assert.strictEqual(loadConfig(f).kick.exitOnKickedOffline, true, "env 任意非 'false' 串视为开");
  } finally { restoreEnv(prev); }
});

test('loadConfig: 非法类型/越界回退默认(不崩溃)', () => {
  const prev = backupEnv();
  try {
    delete process.env.WX_EXIT_ON_KICKED_OFFLINE;
    const f = tmpConf({
      exit_on_kicked_offline: 'no',
      kick_exit_delay_ms: -5,
      kick_window_min: 'abc',
      kick_threshold: 0,
      kick_short_backoff_sec: null,
      kick_long_backoff_min: 1e9,
      kick_stable_reset_min: []
    });
    const c = loadConfig(f);
    assert.strictEqual(c.kick.exitOnKickedOffline, true, "非布尔 false 的值不关闭开关");
    assert.strictEqual(c.kick.exitDelayMs, 1000);
    assert.strictEqual(c.kick.windowMin, 30);
    assert.strictEqual(c.kick.threshold, 3);
    assert.strictEqual(c.kick.shortBackoffSec, 60);
    assert.strictEqual(c.kick.longBackoffMin, 30);
    assert.strictEqual(c.kick.stableResetMin, 10);
  } finally { restoreEnv(prev); }
});

test('loadConfig: 既有 6 键语义未回归', () => {
  const prev = backupEnv();
  try {
    delete process.env.WX_EXIT_ON_KICKED_OFFLINE;
    const f = tmpConf({ host: '0.0.0.0', port: 20002, data_dir: 'dd', receiver_file: 'rr.json' });
    const c = loadConfig(f);
    assert.strictEqual(c.host, '0.0.0.0');
    assert.strictEqual(c.port, 20002);
    assert.strictEqual(c.dataDir, path.join(path.dirname(f), 'dd'));
    assert.strictEqual(c.receiverFile, path.join(path.dirname(f), 'rr.json'));
  } finally { restoreEnv(prev); }
});
