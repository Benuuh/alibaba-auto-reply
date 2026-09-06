// tests/integration.test.js - 桥集成测试(v0.4:无固定命令,全部消息统一走确认闸门→executor)
// 全部 mock:mock wecom-connector HTTP + fake executor/classifier;显式标注为 mock 数据,不连真实企微/LLM/agent
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createMockWecomServer } = require('./helpers/mock_wecom_server.js');
const wecom = require('../lib/wecom_client.js');
const { StateStore } = require('../lib/state.js');
const { createBridge } = require('../agent_bridge.js');

// 统一关闭所有 mock server(断言失败时也不泄漏端口,避免 node --test 挂起)
const openServers = [];
test.after(async () => {
  for (const s of openServers) { try { s.server.close(); } catch (e) {} }
});

function silentLog() { return { log: () => {} }; }

function tmpCfg(baseUrl, extra) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcint-'));
  return Object.assign({
    wecom_base_url: baseUrl,
    consumer: 'control-agent',
    owner_userid: 'owner1',
    projects: {},
    whitelist_files: ['reply_rules.json', 'reply_agent_prompt.md', 'config.json'],
    executor: { type: 'fake', workdir: 'C:\\work', timeout_sec: 300 },
    use_llm_classify: false,
    throttle_sec: 60,
    confirm_ttl_sec: 300,
    reply_max_chars: 4000,
    cursor_file: path.join(d, 'cursor.json'),
    pending_file: path.join(d, 'pending.json'),
    history_file: path.join(d, 'history.jsonl'),
    history_max: 100
  }, extra || {});
}

function fakeExecutor(dispatchImpl) {
  const calls = [];
  return {
    calls,
    dispatch: async (instruction, workdir) => {
      calls.push({ instruction, workdir });
      if (dispatchImpl) { return dispatchImpl(instruction, workdir); }
      return { text: 'FAKE-EXEC done:' + instruction };
    },
    resolveWorkdir: (i) => 'C:\\work',
    status: () => ({ type: 'fake' })
  };
}

async function setupBridge(extra, executorImpl, classifierImpl) {
  const mock = await createMockWecomServer();
  openServers.push(mock);
  const config = tmpCfg('http://127.0.0.1:' + mock.port, extra);
  const state = new StateStore(config);
  const executor = fakeExecutor(executorImpl);
  const bridge = createBridge({
    config,
    log: silentLog(),
    state,
    wecomClient: wecom,
    executor,
    classifier: classifierImpl || (async () => ({ intent: 'content', risk: 'low', summary: '' }))
  });
  return { mock, config, state, bridge, executor };
}

function lastSent(mock) {
  return mock.sent.length ? mock.sent[mock.sent.length - 1].text : '';
}

// ---- 场景 1:普通开放式指令 → 直接派发 executor,回发结果,游标双提交 ----
test('S1 开放式"看看今天的回复情况"→ 直接派发 executor', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '看看今天的回复情况怎么样');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 1, 'executor 被调用一次');
  assert.strictEqual(executor.calls[0].instruction, '看看今天的回复情况怎么样');
  const t = lastSent(mock);
  assert.ok(t.includes('✅'), '回发成功标记');
  assert.strictEqual(state.getCursor(), 1, '本地游标推进');
  assert.strictEqual(mock.cursor, 1, 'wecom-connector 服务端游标已提交');
  mock.server.close();
});

// ---- 场景 2:高风险确认流 ----
test('S2 "重启一下监控服务"→ 确认码请求 → 回复确认 → 派发 executor → 清除待确认', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '重启一下监控服务');
  await bridge.tick();
  const req = lastSent(mock);
  assert.ok(req.includes('[高风险操作]'), '回发确认请求,实际:' + req.substring(0, 60));
  const m = req.match(/确认(\d{4}) 执行/);
  assert.ok(m, '确认码格式正确');
  assert.strictEqual(state.listPending().length, 1, '待确认落盘');
  // 回复确认码
  mock.pushMsg('owner1', '确认' + m[1] + ' 执行');
  await bridge.tick();
  const reply = lastSent(mock);
  assert.ok(reply.includes('✅'), '确认后派发执行并回发成功');
  assert.strictEqual(executor.calls.length, 1, '确认后 executor 被调用');
  assert.strictEqual(executor.calls[0].instruction, '重启一下监控服务', '派发的是原始指令');
  assert.strictEqual(state.listPending().length, 0, '确认后清除待确认');
  assert.strictEqual(state.getCursor(), 2);
  mock.server.close();
});

// ---- 场景 3:白名单免确认直接派发 ----
test('S3 "修改 reply_rules.json 的砍价模板"→ 免确认派发 executor', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '修改 reply_rules.json 的砍价模板');
  await bridge.tick();
  assert.strictEqual(state.listPending().length, 0, '未进入确认流程');
  assert.strictEqual(executor.calls.length, 1, '直接派发');
  const t = lastSent(mock);
  assert.ok(t.includes('✅'), '回发成功标记');
  mock.server.close();
});

// ---- 场景 4:非 owner 忽略 ----
test('S4 非 owner 消息被忽略但游标仍推进', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('hacker1', '重启一下监控服务');
  mock.pushMsg('owner1', '看看今天的回复情况');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 1, '非 owner 未派发');
  assert.strictEqual(state.getCursor(), 2, '两条消息都推进游标');
  mock.server.close();
});

// ---- 场景 5:executor 不可用 → 回发错误不崩溃 ----
test('S5 executor 抛错 → 回发 ❌ 错误与提示,不崩溃', async () => {
  const { mock, bridge, state } = await setupBridge(null,
    async () => { throw new Error('dsh 未安装或未配置 key'); });
  mock.pushMsg('owner1', '帮我生成一份周报');
  await bridge.tick();
  const t = lastSent(mock);
  assert.ok(t.includes('❌'), '回发失败原因');
  assert.ok(t.length > 0, '有错误内容');
  assert.strictEqual(state.getCursor(), 1, '游标正常推进(不卡死)');
  mock.server.close();
});

// ---- 场景 6:节流(同内容 60 秒内不重复) ----
test('S6 同内容两条消息只派发一次', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '看看今天的回复情况');
  mock.pushMsg('owner1', '看看今天的回复情况');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 1, '节流生效');
  assert.strictEqual(state.getCursor(), 2, '两条都推进游标');
  mock.server.close();
});

// ---- 场景 7:问候也派发(无帮助分支,v0.4) ----
test('S7 "你好"→ 直接派发 executor(无 help 分支)', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '你好');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 1, '问候也派发');
  assert.ok(lastSent(mock).includes('✅'));
  mock.server.close();
});

// ---- 场景 8:高风险开放式指令 → 确认 ----
test('S8 "删除 data 目录下旧日志"→ 确认码流程', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '删除 data 目录下旧日志');
  await bridge.tick();
  const t = lastSent(mock);
  assert.ok(t.includes('[高风险操作]'));
  assert.strictEqual(state.listPending().length, 1);
  assert.strictEqual(executor.calls.length, 0, '确认前不派发');
  mock.server.close();
});

// ---- 场景 9:可选 LLM 判 high → 确认 ----
test('S9 use_llm_classify=true 且 LLM 判 high → 确认', async () => {
  const { mock, bridge, state } = await setupBridge(
    { use_llm_classify: true },
    null,
    async () => ({ intent: 'content', risk: 'high', summary: '清理脚本含删除' }));
  mock.pushMsg('owner1', '跑个清理脚本');
  await bridge.tick();
  const t = lastSent(mock);
  assert.ok(t.includes('[高风险操作]'));
  assert.strictEqual(state.listPending().length, 1);
  mock.server.close();
});

// ---- 场景 10:确认码不匹配 ----
test('S10 回复错误确认码 → 提示不匹配,不执行', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '确认9999');
  await bridge.tick();
  const t = lastSent(mock);
  assert.ok(t.includes('确认码不匹配或已过期'));
  assert.strictEqual(executor.calls.length, 0);
  mock.server.close();
});

// ---- 场景 11:确认码匹配但过期 ----
test('S11 过期待确认项被清理,确认码失效', async () => {
  const { mock, bridge, state, executor } = await setupBridge();
  mock.pushMsg('owner1', '重启一下监控服务');
  await bridge.tick();
  const req = lastSent(mock);
  const code = req.match(/确认(\d{4}) 执行/)[1];
  const p = state.listPending()[0];
  p.expire_at = Date.now() - 1000;   // mock 强制过期
  state.savePending(p);
  mock.pushMsg('owner1', '确认' + code);
  await bridge.tick();
  const t = lastSent(mock);
  assert.ok(t.includes('确认码不匹配或已过期'), '过期码被拒绝');
  assert.strictEqual(state.listPending().length, 0, '过期项被清理');
  assert.strictEqual(executor.calls.length, 0, '过期确认不派发');
  mock.server.close();
});

// ---- 场景 12:owner 自动识别(单设备 bootstrap) ----
test('S12 owner 未配置时,receiver.last_userid 命中 → 自动锁定并执行', async () => {
  const { mock, bridge, state, executor } = await setupBridge({ owner_userid: '' });
  mock.pushMsg('owner1', '看看今天的回复情况');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 1, 'owner 自动识别后派发');
  assert.strictEqual(state.getCursor(), 1);
  mock.server.close();
});

// ---- 场景 13:owner 自动识别未命中(非 receiver 用户)→ 忽略 ----
test('S13 owner 未配置且消息来自非 receiver 用户 → 忽略', async () => {
  const { mock, bridge, state, executor } = await setupBridge({ owner_userid: '' });
  mock.pushMsg('stranger', '看看今天的回复情况');
  await bridge.tick();
  assert.strictEqual(executor.calls.length, 0, '未派发');
  assert.strictEqual(state.getCursor(), 1, '游标仍推进');
  mock.server.close();
});

// ---- 场景 14:人工接管白名单指令(添加/列表/删除),直处理不经 executor ----
test('S14 白名单 添加/列表/删除 指令直处理并落盘 manual_override.json', async () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'wcwl-'));
  fs.writeFileSync(path.join(d, 'manual_override.json'), '[]\n', 'utf8');
  const { mock, bridge, state, executor } = await setupBridge({ alibaba_data_dir: d });
  const wlFile = path.join(d, 'manual_override.json');
  const readWl = () => JSON.parse(fs.readFileSync(wlFile, 'utf8'));

  mock.pushMsg('owner1', '白名单 添加 Milan_Miljkovic');
  await bridge.tick();
  assert.ok(lastSent(mock).includes('已加入人工接管白名单'), '添加回执');
  assert.deepStrictEqual(readWl(), ['milan miljkovic'], '归一化(下划线转空格+小写)落盘');
  assert.strictEqual(executor.calls.length, 0, '指令不经 executor');

  mock.pushMsg('owner1', '白名单 添加 milan miljkovic');
  await bridge.tick();
  assert.ok(lastSent(mock).includes('已在白名单中'), '重复添加提示');
  assert.strictEqual(readWl().length, 1, '不重复');

  mock.pushMsg('owner1', '白名单 列表');
  await bridge.tick();
  assert.ok(lastSent(mock).includes('milan miljkovic'), '列表含客户');
  assert.strictEqual(executor.calls.length, 0, '列表不经 executor');

  mock.pushMsg('owner1', '白名单 删除 Milan Miljkovic');
  await bridge.tick();
  assert.ok(lastSent(mock).includes('已移出白名单'), '删除回执');
  assert.deepStrictEqual(readWl(), [], '删除后为空');

  mock.pushMsg('owner1', '白名单 删除 milan miljkovic');
  await bridge.tick();
  assert.ok(lastSent(mock).includes('不在白名单中'), '删除不存在提示');
  assert.strictEqual(state.getCursor(), 5, '五条消息游标推进');
  mock.server.close();
});
