'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startFakeGateway, envelope, sendJson } = require('./fake-gateway');
const api = require('../lib/api');

function cfgFor(srv) {
  return { url: srv.url, username: 'u', password: 'p', authMode: 'basic' };
}

test('detectSelf: derives self aliId from conversationId + contactAliId', () => {
  assert.strictEqual(api.detectSelf({ conversationId: '111-222#11011', contactAliId: '222' }), 111);
  assert.strictEqual(api.detectSelf({ conversationId: '111-222#11011', contactAliId: 111 }), 222);
  assert.strictEqual(api.detectSelf({ conversationId: 'bad', contactAliId: '222' }), null);
  assert.strictEqual(api.detectSelf({ conversationId: '111-222#11011' }), null);
});

test('pullConversations: wraps request, aggregates pages, dedupes', async () => {
  const calls = [];
  const srv = await startFakeGateway((req, res, body) => {
    calls.push(body);
    const reqArg = body.arguments.request || {};
    if (!reqArg.limitTimeStamp) {
      sendJson(res, envelope({ data: { conversations: [
        { conversationId: 'a-1#1', contactAliId: 1, contactName: 'x' },
        { conversationId: 'a-2#1', contactAliId: 2, contactName: 'y' },
      ], nextTimeStamp: 999, hasMore: true } }));
    } else {
      sendJson(res, envelope({ data: { conversations: [
        { conversationId: 'a-2#1', contactAliId: 2, contactName: 'y' },
        { conversationId: 'a-3#1', contactAliId: 3, contactName: 'z' },
      ], hasMore: false } }));
    }
  });
  try {
    const convs = await api.pullConversations(cfgFor(srv), { pages: 5, count: 50 });
    assert.strictEqual(convs.length, 3);
    assert.ok(calls[0].arguments.request, 'query_recent_conversation must be wrapped in request');
    assert.strictEqual(calls[1].arguments.request.limitTimeStamp, 999);
  } finally {
    await srv.close();
  }
});

test('pullMessages: flat args (no request wrapper), paginates via nextPointTimeStamp, sorts ascending', async () => {
  const calls = [];
  let n = 0;
  const srv = await startFakeGateway((req, res, body) => {
    calls.push(body);
    n++;
    if (n === 1) {
      sendJson(res, envelope({ data: { messages: [
        { timestamp: 200, senderAliId: 1, content: 'b' },
        { timestamp: 300, senderAliId: 2, content: 'c' },
      ], nextPointTimeStamp: 150, hasMore: true } }));
    } else {
      sendJson(res, envelope({ data: { messages: [
        { timestamp: 100, senderAliId: 1, content: 'a' },
      ], hasMore: false } }));
    }
  });
  try {
    const msgs = await api.pullMessages(cfgFor(srv), { conversationId: 'a-1#1', selfAliId: 1, pauseMs: 0 });
    assert.strictEqual(msgs.length, 3);
    assert.deepStrictEqual(msgs.map((m) => m.timestamp), [100, 200, 300]);
    assert.strictEqual(calls[0].arguments.request, undefined, 'timeRange must be flat');
    assert.strictEqual(calls[0].arguments.domain, 'icbu');
    assert.strictEqual(calls[1].arguments.endTime, 150);
  } finally {
    await srv.close();
  }
});

test('callTool: business error auth_required -> AUTH-REQUIRED', async () => {
  const srv = await startFakeGateway((req, res) => {
    sendJson(res, envelope(JSON.stringify({ success: false, errorMsg: 'Alibaba未登录', errorCode: '-32001', auth_required: true }), { isError: true }));
  });
  try {
    await assert.rejects(
      api.callTool(cfgFor(srv), 'query_recent_conversation', { count: 10 }),
      (e) => e.code === 'AUTH-REQUIRED'
    );
  } finally {
    await srv.close();
  }
});

test('callTool: unknown tool -> TOOL-ERROR', async () => {
  const srv = await startFakeGateway((req, res) => {
    sendJson(res, envelope('Unknown tool: nope', { isError: true }));
  });
  try {
    await assert.rejects(
      api.callTool(cfgFor(srv), 'nope', {}),
      (e) => e.code === 'TOOL-ERROR'
    );
  } finally {
    await srv.close();
  }
});

test('sendMessage: builds double-sided receiverAliID with conversationID', async () => {
  let seen = null;
  const srv = await startFakeGateway((req, res, body) => {
    seen = body;
    sendJson(res, envelope({ success: true, data: { messageID: 'm1' } }));
  });
  try {
    const r = await api.sendMessage(cfgFor(srv), {
      conversationId: 'a-1#1', buyerAliId: 1, selfAliId: 2, content: 'hello',
    });
    assert.deepStrictEqual(seen.arguments.sendRequest.receiverAliID, [1, 2]);
    assert.strictEqual(seen.arguments.sendRequest.conversationID, 'a-1#1');
    assert.strictEqual(seen.arguments.sendRequest.messageType, 'CUSTOMER_TEXT');
    assert.strictEqual(r.data.messageID, 'm1');
  } finally {
    await srv.close();
  }
});
