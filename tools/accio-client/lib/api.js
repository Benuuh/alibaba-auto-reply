'use strict';

// 协议层：按验证会话读到的调用方式自行重写（未复制参考项目代码）。
// 端点 /mcp/proxy；工具 query_recent_conversation / query_conversation_msg_timeRange / send_msg；域 icbu。
const { GatewayError, ERR, callProxy } = require('./gateway');

const MS_DAY = 86400000;

class ApiError extends Error {
  constructor(code, message, detail) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.detail = detail || null;
  }
}

// 网关信封 → 业务 JSON；业务错误（如 Alibaba 未登录 -32001）映射为 ApiError。
function parseEnvelope(out) {
  if (!out || typeof out !== 'object') {
    throw new GatewayError(ERR.PROTOCOL_ERROR, 'empty gateway envelope');
  }
  if (out.success === false) {
    const code = out.errorCode ? String(out.errorCode) : 'GATEWAY-ERROR';
    throw new ApiError(code, out.errorMsg || 'gateway call failed', out);
  }
  const data = out.data || {};
  const content = Array.isArray(data.content) ? data.content : [];
  const first = content[0];
  if (first && first.type === 'text') {
    const text = String(first.text || '');
    if (text.indexOf('Unknown tool') === 0 || data.isError) {
      let biz = null;
      try { biz = JSON.parse(text); } catch (e) { /* keep raw */ }
      if (biz && (biz.auth_required || String(biz.errorCode) === '-32001')) {
        throw new ApiError('AUTH-REQUIRED', biz.errorMsg || 'Alibaba login required', biz);
      }
      throw new ApiError('TOOL-ERROR', (biz && biz.errorMsg) || text.slice(0, 300), biz);
    }
    try {
      return JSON.parse(text);
    } catch (e) {
      throw new GatewayError(ERR.PROTOCOL_ERROR, 'tool result is not JSON');
    }
  }
  return out;
}

// 调用一个 MCP 工具（自动处理参数包裹差异）。
async function callTool(cfg, name, args, options) {
  let payloadArgs = args;
  if (name === 'query_conversation_msg_timeRange') {
    payloadArgs = args; // 扁平传参：包 request 会导致缺少必填参数
  } else if (name.indexOf('query_') === 0) {
    payloadArgs = { request: args };
  }
  const envelope = await callProxy(cfg, { name, arguments: payloadArgs }, options);
  return parseEnvelope(envelope);
}

// 从 conversationId（形如 a-b#11011）与 contactAliId 推断本店 selfAliId。
function detectSelf(conversation) {
  const cid = String((conversation && conversation.conversationId) || '');
  const contact = String((conversation && conversation.contactAliId) || '');
  const base = cid.split('#')[0];
  const parts = base.split('-');
  if (parts.length !== 2 || !contact) return null;
  if (parts[0] === contact) return Number(parts[1]);
  if (parts[1] === contact) return Number(parts[0]);
  return null;
}

// 会话列表（分页聚合，按 conversationId 去重）。
async function pullConversations(cfg, options) {
  const opts = options || {};
  const pages = opts.pages || 5;
  const count = opts.count || 50;
  const timeoutMs = opts.timeoutMs || 15000;
  const conversations = [];
  let cursor = null;
  for (let i = 0; i < pages; i++) {
    const args = { count };
    if (opts.selfAliId) args.selfAliId = opts.selfAliId;
    if (cursor) args.limitTimeStamp = cursor;
    const d = await callTool(cfg, 'query_recent_conversation', args, { timeoutMs });
    const data = d.data || {};
    const batch = Array.isArray(data.conversations) ? data.conversations : [];
    conversations.push.apply(conversations, batch);
    cursor = data.nextTimeStamp;
    if (!data.hasMore || !cursor) break;
  }
  const seen = new Set();
  const unique = [];
  for (const c of conversations) {
    const key = c && c.conversationId;
    if (key && !seen.has(key)) {
      seen.add(key);
      unique.push(c);
    }
  }
  return unique;
}

// 历史消息（全量 timeRange；用 nextPointTimeStamp 向更早翻页）。
async function pullMessages(cfg, options) {
  const opts = options || {};
  const conversationId = opts.conversationId;
  if (!conversationId) throw new ApiError('INVALID-ARGS', 'conversationId is required');
  const timeoutMs = opts.timeoutMs || 15000;
  const maxPages = opts.maxPages || 500;
  const pauseMs = opts.pauseMs == null ? 300 : opts.pauseMs;
  const now = Date.now();
  let start = opts.startTime || (now - 3650 * MS_DAY);
  let end = opts.endTime || (now + 60000);
  const messages = [];
  for (let i = 0; i < maxPages; i++) {
    const args = {
      conversationId,
      domain: 'icbu',
      startTime: start,
      endTime: end,
    };
    if (opts.selfAliId) args.selfAliId = String(opts.selfAliId);
    const d = await callTool(cfg, 'query_conversation_msg_timeRange', args, { timeoutMs });
    const data = d.data || d;
    const batch = Array.isArray(data.messages) ? data.messages : [];
    if (batch.length === 0) break;
    messages.push.apply(messages, batch);
    const next = data.nextPointTimeStamp;
    if (!data.hasMore || !next || next >= end) break;
    end = next;
    if (pauseMs > 0) await new Promise((r) => setTimeout(r, pauseMs));
  }
  const seen = new Set();
  const unique = [];
  for (const m of messages) {
    const key = [m.timestamp, m.senderAliId, String(m.content)].join('\u0001');
    if (!seen.has(key)) {
      seen.add(key);
      unique.push(m);
    }
  }
  unique.sort((a, b) => (a.timestamp || 0) - (b.timestamp || 0));
  return unique;
}

// 发送消息（写操作；仅 Phase 4 用户指定测试会话允许调用）。
// receiverAliID 必须同时包含买家与本店（单边会导致“假成功”）。
async function sendMessage(cfg, options) {
  const opts = options || {};
  const buyer = opts.buyerAliId;
  const self = opts.selfAliId;
  if (!buyer || !self) throw new ApiError('INVALID-ARGS', 'buyerAliId and selfAliId are required');
  const sendRequest = {
    chatTypeEnum: 'SINGLE',
    messageType: 'CUSTOMER_TEXT',
    content: opts.content,
    receiverAliID: [buyer, self],
  };
  if (opts.conversationId) sendRequest.conversationID = opts.conversationId;
  return callTool(cfg, 'send_msg', { sendRequest }, { timeoutMs: opts.timeoutMs || 30000 });
}

module.exports = {
  ApiError,
  parseEnvelope,
  callTool,
  detectSelf,
  pullConversations,
  pullMessages,
  sendMessage,
};
