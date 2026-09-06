// tests/config.test.js - control-agent 配置加载:BOM 容错 + 默认值(v0.4 无命令死配置)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { loadConfig } = require('../lib/config.js');

function tmpConf(obj, bom) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'caconf-'));
  const f = path.join(d, 'config.json');
  fs.writeFileSync(f, (bom ? '\uFEFF' : '') + JSON.stringify(obj), 'utf8');
  return f;
}

test('BOM 前缀配置可正常解析(PS 5.1 Set-Content 写出的文件),projects/key_file 生效', () => {
  const f = tmpConf({
    wecom_base_url: 'http://127.0.0.1:20002',
    projects: { 'alibaba-auto-reply': 'C:\\a', 'wecom-connector': '../wecom-connector' },
    classify_key_file: 'C:\\creds.md',
    owner_userid: 'owner1'
  }, true);
  const c = loadConfig(f);
  assert.strictEqual(c.wecom_base_url, 'http://127.0.0.1:20002', '带 BOM 也应解析成功');
  assert.strictEqual(c.projects['alibaba-auto-reply'], 'C:\\a');
  assert.strictEqual(c.projects['wecom-connector'], path.join(path.dirname(f), '..', 'wecom-connector'), '相对路径按配置文件目录解析');
  assert.strictEqual(c.classify_key_file, 'C:\\creds.md');
  assert.strictEqual(c.owner_userid, 'owner1');
});

test('无配置文件时回退默认(v0.4 无 cmd_reply_max_chars/default_workdir 死配置)', () => {
  const c = loadConfig(path.join(os.tmpdir(), 'absent-config.json'));
  assert.strictEqual(c.wecom_base_url, 'http://127.0.0.1:19886');
  assert.strictEqual(c.consumer, 'control-agent');
  assert.strictEqual(c.executor.type, 'dsh');
  assert.strictEqual(c.executor.workdir, path.resolve(__dirname, '..', '..', '..'), '默认工作区根由本模块位置推导');
  assert.strictEqual(c.reply_max_chars, 4000);
  assert.strictEqual(c.cmd_reply_max_chars, undefined, 'v0.4 已移除命令专用截断');
  assert.strictEqual(c.default_workdir, undefined, 'v0.4 已移除顶层 default_workdir(executor.workdir 为准)');
});

test('损坏配置回退默认不崩溃', () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'caconf2-'));
  const f = path.join(d, 'config.json');
  fs.writeFileSync(f, '{oops', 'utf8');
  const c = loadConfig(f);
  assert.strictEqual(c.consumer, 'control-agent');
});
