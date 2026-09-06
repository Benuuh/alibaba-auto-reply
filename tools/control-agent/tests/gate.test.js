// tests/gate.test.js - 确认闸门决策(v0.4:无固定命令/无帮助分支,全部消息统一走闸门→派发)+ 确认码(纯函数)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const gate = require('../lib/gate.js');

const cfg = {
  whitelist_files: ['reply_rules.json', 'reply_agent_prompt.md', 'config.json'],
  confirm_ttl_sec: 300
};

test('G1 普通开放式指令(无高风险/非白名单/无 LLM 判定)→ 直接 dispatch', () => {
  assert.strictEqual(gate.decide('看看今天的回复情况怎么样', {}, cfg).action, 'dispatch');
  assert.strictEqual(gate.decide('把砍价话术改得更友善', {}, cfg).action, 'dispatch');
  assert.strictEqual(gate.decide('你好', {}, cfg).action, 'dispatch', 'v0.4 无帮助分支,问候也派发');
  assert.strictEqual(gate.decide('帮我在 alibaba-auto-reply 里查发送失败记录', {}, cfg).action, 'dispatch');
});

test('G2 高风险规则命中 → confirm(需确认码)', () => {
  const d = gate.decide('删除 data 目录下旧日志', {}, cfg);
  assert.strictEqual(d.action, 'confirm');
  assert.strictEqual(d.reason, 'high_risk_pattern');
  assert.strictEqual(gate.decide('重启一下监控服务', {}, cfg).action, 'confirm');
  assert.strictEqual(gate.decide('kill 掉残留进程', {}, cfg).action, 'confirm');
});

test('G3 白名单写 → 免确认直接 dispatch', () => {
  const d = gate.decide('修改 reply_rules.json 的砍价模板', {}, cfg);
  assert.strictEqual(d.action, 'dispatch');
  assert.strictEqual(d.reason, 'whitelist_write');
});

test('G4 可选 LLM 判 high → confirm;low → dispatch', () => {
  assert.strictEqual(gate.decide('跑个清理脚本', { intent: 'content', risk: 'high' }, cfg).action, 'confirm');
  assert.strictEqual(gate.decide('跑个清理脚本', { intent: 'content', risk: 'low' }, cfg).action, 'dispatch');
  assert.strictEqual(gate.decide('随便聊聊', { intent: 'unknown', risk: 'low' }, cfg).action, 'dispatch', 'unknown 也派发(v0.4 无帮助分支)');
});

test('G5 确认码生成:4 位数字;注入随机源可复现', () => {
  const code = gate.makeCode();
  assert.match(code, /^\d{4}$/);
  const rnd = () => 0.5;
  assert.strictEqual(gate.makeCode(rnd), '5555');
});

test('G6 确认消息解析:支持 "确认1234" / "确认 1234" / "确认1234 执行"', () => {
  assert.strictEqual(gate.extractConfirmCode('确认1234'), '1234');
  assert.strictEqual(gate.extractConfirmCode('确认 5678'), '5678');
  assert.strictEqual(gate.extractConfirmCode('确认9012 执行'), '9012');
  assert.strictEqual(gate.extractConfirmCode('确认123'), null);
  assert.strictEqual(gate.extractConfirmCode('随便聊聊'), null);
  assert.strictEqual(gate.extractConfirmCode(''), null);
});

test('G7 待确认条目:匹配/错误码/过期', () => {
  const now = 1000000;
  const p = gate.buildPending(42, '重启一下监控服务', '重启服务', 300, now);
  assert.strictEqual(p.seq, 42);
  assert.strictEqual(p.code.length, 4);
  assert.strictEqual(p.expire_at, now + 300000);
  assert.strictEqual(gate.findPendingByCode([p], p.code, now), p);
  assert.strictEqual(gate.findPendingByCode([p], '0000', now), null, '错误码');
  assert.strictEqual(gate.findPendingByCode([p], p.code, now + 300001), null, '已过期');
  assert.strictEqual(gate.findPendingByCode([], p.code, now), null, '空列表');
});
