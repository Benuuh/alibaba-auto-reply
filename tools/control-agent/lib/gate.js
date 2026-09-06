// lib/gate.js - 确认闸门(v0.4:无固定命令/无帮助分支,全部消息统一走"闸门→派发")
// 决策(纯函数):高风险正则命中 → confirm;白名单写 → 免确认 dispatch;
// 可选 LLM risk=high → confirm;其余(含问候/unknown)→ dispatch
'use strict';

const { hitHighRisk, isWhitelistWrite } = require('./safety.js');

// 决策(纯函数):返回 {action: 'confirm'|'dispatch', reason, summary}
function decide(message, classification, config) {
  const cl = classification || {};

  if (hitHighRisk(message)) {
    return { action: 'confirm', reason: 'high_risk_pattern', summary: cl.summary || String(message).substring(0, 60) };
  }
  if (isWhitelistWrite(message, config.whitelist_files)) {
    return { action: 'dispatch', reason: 'whitelist_write', summary: cl.summary || '' };
  }
  if (cl.risk === 'high') {
    return { action: 'confirm', reason: 'llm_high_risk', summary: cl.summary || String(message).substring(0, 60) };
  }
  return { action: 'dispatch', reason: 'low_risk', summary: cl.summary || '' };
}

// 4 位随机确认码(可注入随机源便于测试)
function makeCode(rnd) {
  const r = rnd || Math.random;
  let code = '';
  for (let i = 0; i < 4; i++) { code += String(Math.floor(r() * 10)); }
  return code;
}

// 确认消息解析:"确认1234" / "确认 1234" / "确认1234 执行" → "1234" | null
function extractConfirmCode(text) {
  const m = String(text || '').trim().match(/^确认\s*(\d{4})(?:\s*执行)?\s*$/);
  return m ? m[1] : null;
}

// 构造待确认条目(字段: code/action/summary/expire_at/seq)
function buildPending(seq, message, summary, ttlSec, nowMs) {
  return {
    seq: Number(seq),
    code: makeCode(),
    action: String(message),
    summary: String(summary || '').substring(0, 200),
    expire_at: (nowMs || Date.now()) + (Number(ttlSec) || 300) * 1000
  };
}

// 在待确认列表中按码匹配(未过期),返回条目或 null
function findPendingByCode(pendingList, code, nowMs) {
  const now = nowMs || Date.now();
  for (const p of pendingList) {
    if (p.code === code && Number(p.expire_at) > now) { return p; }
  }
  return null;
}

module.exports = { decide, makeCode, extractConfirmCode, buildPending, findPendingByCode };
