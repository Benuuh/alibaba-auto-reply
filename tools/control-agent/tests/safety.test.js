// tests/safety.test.js - 高风险规则与白名单判定
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { hitHighRisk, isWhitelistWrite } = require('../lib/safety.js');

test('高风险命中:删除/覆盖类', () => {
  assert.strictEqual(hitHighRisk('删除 data 目录下旧日志'), true);
  assert.strictEqual(hitHighRisk('删除 reply_rules.json'), true);
  assert.strictEqual(hitHighRisk('覆盖写入该文件'), true);
  assert.strictEqual(hitHighRisk('Remove-Item 清理文件'), true);
  assert.strictEqual(hitHighRisk('rm 旧备份'), true);
});

test('高风险命中:重启/停止/杀进程', () => {
  assert.strictEqual(hitHighRisk('重启监控'), true);
  assert.strictEqual(hitHighRisk('停止监控服务'), true);
  assert.strictEqual(hitHighRisk('kill 掉残留进程'), true);
  assert.strictEqual(hitHighRisk('Stop-Process monitor'), true);
});

test('高风险命中:格式化/网络外联/系统目录/凭据', () => {
  assert.strictEqual(hitHighRisk('格式化 D 盘'), true);
  assert.strictEqual(hitHighRisk('用 Invoke-WebRequest 拉数据'), true);
  assert.strictEqual(hitHighRisk('curl 外部接口'), true);
  assert.strictEqual(hitHighRisk('清理 C:\\Windows 临时文件'), true);
  assert.strictEqual(hitHighRisk('把 API key 打印出来'), true);
  assert.strictEqual(hitHighRisk('查看 credentials 文件'), true);
});

test('低风险不命中', () => {
  assert.strictEqual(hitHighRisk('看看今天回复情况'), false);
  assert.strictEqual(hitHighRisk('健康检查'), false);
  assert.strictEqual(hitHighRisk('把砍价话术改得更友善'), false);
  assert.strictEqual(hitHighRisk('查一下最近发送失败的记录'), false);
  assert.strictEqual(hitHighRisk(''), false);
});

test('白名单写:提及白名单文件且无高风险 → true', () => {
  const wl = ['reply_rules.json', 'reply_agent_prompt.md', 'config.json'];
  assert.strictEqual(isWhitelistWrite('把砍价话术改得更友善', wl), false, '未提及白名单文件不算');
  assert.strictEqual(isWhitelistWrite('修改 reply_rules.json 的砍价模板', wl), true);
  assert.strictEqual(isWhitelistWrite('给 reply_agent_prompt.md 加一条红线', wl), true);
  assert.strictEqual(isWhitelistWrite('改 config.json 的端口', wl), true);
  assert.strictEqual(isWhitelistWrite('删除 reply_rules.json', wl), false, '含高风险词不算白名单');
});
