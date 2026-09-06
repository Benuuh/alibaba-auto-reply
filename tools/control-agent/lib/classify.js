// lib/classify.js - 桥层快速分类:DeepSeek(control_api_key)输出严格 JSON,失败走规则兜底
// 敏感铁律:key 只在进程内使用,绝不落盘/入日志/回发
'use strict';

const INTENTS = ['ops', 'query', 'content', 'unknown'];
const RISKS = ['low', 'high'];

// 容错解析 LLM 返回 JSON:剥 ```json 围栏 / 前后杂文本 / 提取首个平衡 JSON 对象
function parseJsonLoose(text) {
  if (!text) { return null; }
  let s = String(text).trim();
  // 剥 markdown 围栏
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) { s = fence[1].trim(); }
  try { return JSON.parse(s); }
  catch (e) { /* 继续尝试提取对象 */ }
  // 提取首个 { ... } 平衡段
  const start = s.indexOf('{');
  if (start < 0) { return null; }
  let depth = 0;
  for (let i = start; i < s.length; i++) {
    if (s[i] === '{') { depth++; }
    else if (s[i] === '}') {
      depth--;
      if (depth === 0) {
        try { return JSON.parse(s.substring(start, i + 1)); } catch (e2) { return null; }
      }
    }
  }
  return null;
}

// 规则兜底(LLM 不可用/失败/无 key)
function fallbackClassify(message) {
  const text = String(message || '');
  let intent = 'content';
  if (/(重启|停止|停用|杀掉|kill|restart|stop)/i.test(text)) { intent = 'ops'; }
  else if (/(状态|健康|看板|买家|报价|帮助|status|dashboard|buyers|quote|help|查看|查询|统计|情况|总结|汇报)/i.test(text)) { intent = 'query'; }
  let risk = 'low';
  if (/(删除|覆盖|格式化|Remove-Item|\brm\b|\bdel\b|Clear-Content|Stop-Process|kill|重启|restart|格式化|Invoke-WebRequest|curl)/i.test(text)) { risk = 'high'; }
  return { intent, risk, summary: text.substring(0, 60) };
}

function normalizeResult(raw) {
  if (!raw || typeof raw !== 'object') { return null; }
  const intent = INTENTS.includes(raw.intent) ? raw.intent : null;
  const risk = RISKS.includes(raw.risk) ? raw.risk : null;
  if (!intent || !risk) { return null; }
  return {
    intent,
    risk,
    summary: String(raw.summary || '').substring(0, 120)
  };
}

// httpFn(baseUrl?, opts) 可注入(测试用);默认用全局 fetch
async function classify(message, projects, apiKey, config, httpFn) {
  if (!apiKey) { return fallbackClassify(message); }
  const projectNames = Object.keys(projects || {}).join('、') || '(无)';
  const system = '你是企微远程控制指令的快速分类器。只输出严格 JSON,格式:{"intent":"ops|query|content|unknown","risk":"low|high","summary":"一句话中文摘要(≤30字)"}。intent 含义:ops=运维动作(重启/停服务等),query=查询只读,content=内容/代码修改,unknown=无法分类或闲聊。risk:涉及删除/覆盖/重启/停服务/网络外联/凭据的操作为 high。';
  const user = '可用项目:' + projectNames + '\n用户消息:' + String(message).substring(0, 500);
  const body = JSON.stringify({
    model: config.classify_model,
    temperature: 0,
    max_tokens: 200,
    response_format: { type: 'json_object' },
    messages: [
      { role: 'system', content: system },
      { role: 'user', content: user }
    ]
  });
  const fn = httpFn || ((url, opts) => fetch(url, opts));
  let timer;
  try {
    const ctrl = new AbortController();
    timer = setTimeout(() => ctrl.abort(), config.classify_timeout_ms || 20000);
    const resp = await fn(config.classify_endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer ' + apiKey
      },
      body,
      signal: ctrl.signal
    });
    if (!resp.ok) { return fallbackClassify(message); }
    const data = await resp.json();
    const content = data && data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
    const normalized = normalizeResult(parseJsonLoose(content));
    return normalized || fallbackClassify(message);
  } catch (e) {
    return fallbackClassify(message);
  } finally {
    if (timer) { clearTimeout(timer); }
  }
}

module.exports = { classify, fallbackClassify, parseJsonLoose, normalizeResult };
