// tests/config.test.js - loadConfig 行为测试:环境变量 > 配置文件 > 默认值
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadConfig } = require('../lib/config.js');

const PREV = {};
function backupEnv() {
  for (const k of ['WX_BOT_ID', 'WX_BOT_SECRET', 'WECOM_PORT', 'WX_RECEIVER_FILE', 'WECOM_DATA_DIR']) {
    PREV[k] = process.env[k];
  }
}
function restoreEnv() {
  for (const k of Object.keys(PREV)) {
    if (PREV[k] === undefined) { delete process.env[k]; } else { process.env[k] = PREV[k]; }
  }
}

function tmpConf(obj) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcconf-'));
  const f = path.join(d, 'config.json');
  fs.writeFileSync(f, JSON.stringify(obj), 'utf8');
  return f;
}

test('无配置无环境变量时使用默认值', () => {
  backupEnv(); try {
    delete process.env.WX_BOT_ID; delete process.env.WX_BOT_SECRET;
    delete process.env.WECOM_PORT; delete process.env.WX_RECEIVER_FILE;
    const c = loadConfig(path.join(os.tmpdir(), 'no-such-config.json'));
    assert.strictEqual(c.port, 19886);
    assert.strictEqual(c.host, '127.0.0.1');
    assert.strictEqual(c.botId, '');
    assert.strictEqual(c.botSecret, '');
    assert.ok(c.dataDir.length > 0);
  } finally { restoreEnv(); }
});

test('配置文件提供 botId/secret/port/receiverFile(相对路径基于配置目录解析)', () => {
  backupEnv(); try {
    delete process.env.WX_BOT_ID; delete process.env.WX_BOT_SECRET;
    delete process.env.WECOM_PORT; delete process.env.WX_RECEIVER_FILE;
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcconf-'));
    const f = path.join(d, 'config.json');
    fs.writeFileSync(f, JSON.stringify({ port: 20001, bot_id: 'cfg-id', bot_secret: 'cfg-secret', receiver_file: 'r.json', data_dir: 'd' }), 'utf8');
    const c = loadConfig(f);
    assert.strictEqual(c.port, 20001);
    assert.strictEqual(c.botId, 'cfg-id');
    assert.strictEqual(c.botSecret, 'cfg-secret');
    assert.strictEqual(c.receiverFile, path.join(d, 'r.json'));
    assert.strictEqual(c.dataDir, path.join(d, 'd'));
  } finally { restoreEnv(); }
});

test('环境变量覆盖配置文件(bot 凭据 + 端口 + receiver)', () => {
  backupEnv(); try {
    process.env.WX_BOT_ID = 'env-id';
    process.env.WX_BOT_SECRET = 'env-secret';
    process.env.WECOM_PORT = '21000';
    process.env.WX_RECEIVER_FILE = 'env-r.json';
    const f = tmpConf({ port: 20001, bot_id: 'cfg-id', bot_secret: 'cfg-secret', receiver_file: 'cfg-r.json' });
    const c = loadConfig(f);
    assert.strictEqual(c.botId, 'env-id');
    assert.strictEqual(c.botSecret, 'env-secret');
    assert.strictEqual(c.port, 21000);
    assert.strictEqual(c.receiverFile, 'env-r.json');
  } finally { restoreEnv(); }
});

test('配置缺失文件但环境变量齐全可运行', () => {
  backupEnv(); try {
    process.env.WX_BOT_ID = 'env-id';
    process.env.WX_BOT_SECRET = 'env-secret';
    const c = loadConfig(path.join(os.tmpdir(), 'absent-config.json'));
    assert.strictEqual(c.botId, 'env-id');
    assert.strictEqual(c.port, 19886);
  } finally { restoreEnv(); }
});

test('config 文件损坏时回退默认不崩溃', () => {
  backupEnv(); try {
    delete process.env.WX_BOT_ID; delete process.env.WX_BOT_SECRET;
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcconf2-'));
    const f = path.join(d, 'config.json');
    fs.writeFileSync(f, '{oops', 'utf8');
    const c = loadConfig(f);
    assert.strictEqual(c.port, 19886);
  } finally { restoreEnv(); }
});

test('端口非法时回退默认', () => {
  backupEnv(); try {
    const f = tmpConf({ port: 'not-a-port' });
    const c = loadConfig(f);
    assert.strictEqual(c.port, 19886);
  } finally { restoreEnv(); }
});

test('非法类型回退默认(非字符串路径/布尔值等不崩溃)', () => {
  backupEnv(); try {
    delete process.env.WX_RECEIVER_FILE; delete process.env.WECOM_DATA_DIR;
    const f = tmpConf({ data_dir: 123, receiver_file: false, bot_id: 42, host: ['x'] });
    const c = loadConfig(f);
    assert.strictEqual(c.dataDir, path.join(path.dirname(f), 'data'), '非字符串 data_dir 回退默认');
    assert.strictEqual(c.receiverFile, path.join(path.dirname(f), 'data', 'wecom_receiver.json'));
    assert.strictEqual(c.botId, '', '非字符串 bot_id 回退空');
    assert.strictEqual(c.host, '127.0.0.1');
  } finally { restoreEnv(); }
});

test('相对路径基于 config 文件所在目录解析', () => {
  backupEnv(); try {
    delete process.env.WX_RECEIVER_FILE; delete process.env.WECOM_DATA_DIR;
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcconf3-'));
    const f = path.join(d, 'config.json');
    fs.writeFileSync(f, JSON.stringify({ receiver_file: 'data/r.json', data_dir: 'data' }), 'utf8');
    const c = loadConfig(f);
    assert.strictEqual(c.receiverFile, path.join(d, 'data', 'r.json'));
    assert.strictEqual(c.dataDir, path.join(d, 'data'));
  } finally { restoreEnv(); }
});
