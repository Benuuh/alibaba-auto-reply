// tests/classify.test.js - 可选 LLM 分类:JSON 容错解析 + 规则兜底(纯函数)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { classify, parseJsonLoose, fallbackClassify, normalizeResult } = require('../lib/classify.js');

test('parseJsonLoose:标准 JSON', () => {
  assert.deepStrictEqual(parseJsonLoose('{"intent":"ops","risk":"high","summary":"重启"}'),
    { intent: 'ops', risk: 'high', summary: '重启' });
});

test('parseJsonLoose:markdown 围栏', () => {
  const raw = '```json\n{"intent":"query","risk":"low","summary":"查询"}\n```';
  assert.deepStrictEqual(parseJsonLoose(raw), { intent: 'query', risk: 'low', summary: '查询' });
});

test('parseJsonLoose:前后杂文本(提取首个平衡对象)', () => {
  const raw = '好的，结果如下：{"intent":"content","risk":"low","summary":"改话术"} 请查收';
  assert.deepStrictEqual(parseJsonLoose(raw), { intent: 'content', risk: 'low', summary: '改话术' });
});

test('parseJsonLoose:损坏输入返回 null', () => {
  assert.strictEqual(parseJsonLoose('not json at all'), null);
  assert.strictEqual(parseJsonLoose(''), null);
  assert.strictEqual(parseJsonLoose(null), null);
});

test('normalizeResult:非法 intent/risk 拒绝', () => {
  assert.strictEqual(normalizeResult({ intent: 'evil', risk: 'high' }), null);
  assert.strictEqual(normalizeResult({ intent: 'ops', risk: 'medium' }), null);
  assert.strictEqual(normalizeResult(null), null);
});

test('规则兜底:关键词映射', () => {
  assert.deepStrictEqual(fallbackClassify('重启监控'), { intent: 'ops', risk: 'high', summary: '重启监控' });
  assert.strictEqual(fallbackClassify('看看今天回复情况').intent, 'query');
  assert.strictEqual(fallbackClassify('健康检查').intent, 'query');
  assert.strictEqual(fallbackClassify('把砍价话术改得更友善').intent, 'content');
  assert.strictEqual(fallbackClassify('把砍价话术改得更友善').risk, 'low');
  assert.strictEqual(fallbackClassify('删除旧日志').risk, 'high');
  assert.strictEqual(fallbackClassify('随便聊聊').intent, 'content', '无关键词默认 content');
});

test('分类请求失败时释放超时计时器', async () => {
  const originalSetTimeout = global.setTimeout;
  const originalClearTimeout = global.clearTimeout;
  const timer = {};
  let cleared = false;
  global.setTimeout = () => timer;
  global.clearTimeout = (value) => { if (value === timer) { cleared = true; } };
  try {
    const result = await classify('查看状态', {}, 'test-key', {
      classify_model: 'test-model',
      classify_timeout_ms: 20000,
      classify_endpoint: 'https://example.invalid'
    }, async () => { throw new Error('network unavailable'); });
    assert.strictEqual(result.intent, 'query');
    assert.strictEqual(cleared, true);
  } finally {
    global.setTimeout = originalSetTimeout;
    global.clearTimeout = originalClearTimeout;
  }
});
