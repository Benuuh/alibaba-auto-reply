// lib/http_api.js - 本地 HTTP 桥(深模块):把 bot/游标/缓冲/接收方封装成小接口
// 端点:
//   GET  /health                        → {connected}
//   POST /send      {to, text}          → {ok:true} | 400/503/500 {error}
//   GET  /messages  ?consumer=&after=   → {consumer, after, last_seq, cursor_seq, items}
//   GET  /cursor    ?consumer=          → {consumer, seq, exists}
//   POST /cursor    {consumer, seq}     → {consumer, seq}
//   GET  /receiver                      → 接收方缓存对象(可空 {})
//   GET  /status                        → {connected, uptime_sec, msg_count, consumers}
// 游标语义:GET /messages 只读不推进;消费方处理完显式 POST /cursor 提交(at-least-once)
'use strict';

const http = require('node:http');
const { URL } = require('node:url');

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(body);
}

// 请求体读取:JSON 解析 + 上限保护(超限 destroy → reject code=TOO_LARGE,防内存 DoS)
const MAX_BODY_BYTES = 1048576;   // 1MB

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    let size = 0;
    let settled = false;
    const fail = (err) => {
      if (settled) { return; }
      settled = true;
      reject(err);
    };
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        fail(Object.assign(new Error('body too large'), { code: 'TOO_LARGE' }));
        // 排空剩余请求体(不缓冲),让路由能正常回写 413 响应
        req.resume();
        return;
      }
      body += c;
    });
    req.on('end', () => {
      if (settled) { return; }
      settled = true;
      try { resolve(body ? JSON.parse(body) : {}); }
      catch (e) { reject(Object.assign(new Error('invalid json body'), { code: 'BAD_JSON' })); }
    });
    req.on('error', (e) => { fail(e); });
  });
}

// 读请求体并映射错误:返回 {data} 或 {error:'too_large'|'bad_json'}(两处 POST 分支共用)
async function readJsonOrError(req) {
  try { return { data: await readBody(req) }; }
  catch (e) { return { error: (e && e.code === 'TOO_LARGE') ? 'too_large' : 'bad_json' }; }
}

function sendJsonBodyError(res, err) {
  if (err === 'too_large') { sendJson(res, 413, { error: 'body too large' }); return; }
  sendJson(res, 400, { error: 'invalid json body' });
}

// deps: {bot:{isConnected, sendMessage(to,payload)}, cursorStore, buffer, receiver:{read}}
function createHttpServer(deps) {
  const { bot, cursorStore, buffer, receiver } = deps;
  const startTs = Date.now();

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      const route = url.pathname;

      if (req.method === 'GET' && route === '/health') {
        sendJson(res, 200, { connected: !!bot.isConnected });

      } else if (req.method === 'POST' && route === '/send') {
        const r = await readJsonOrError(req);
        if (r.error) { sendJsonBodyError(res, r.error); return; }
        const data = r.data;
        if (!data.to || !data.text) { sendJson(res, 400, { error: 'to and text required' }); return; }
        if (!bot.isConnected) { sendJson(res, 503, { error: 'long connection not established' }); return; }
        try {
          await bot.sendMessage(String(data.to), {
            msgtype: 'markdown',
            markdown: { content: String(data.text) }
          });
          sendJson(res, 200, { ok: true });
        } catch (e) {
          sendJson(res, 500, { error: String((e && e.message) || e) });
        }

      } else if (req.method === 'GET' && route === '/messages') {
        const consumer = url.searchParams.get('consumer') || '';
        if (!consumer) { sendJson(res, 400, { error: 'consumer required' }); return; }
        let after = url.searchParams.get('after');
        if (after === null) { after = cursorStore.get(consumer); }
        const afterNum = Number(after);
        const afterOk = Number.isFinite(afterNum) && afterNum >= 0;
        const items = buffer.listAfter(afterOk ? afterNum : 0);
        sendJson(res, 200, {
          consumer,
          after: afterOk ? afterNum : 0,
          last_seq: buffer.maxSeq(),
          cursor_seq: cursorStore.get(consumer),
          items
        });

      } else if (req.method === 'GET' && route === '/cursor') {
        const consumer = url.searchParams.get('consumer') || '';
        if (!consumer) { sendJson(res, 400, { error: 'consumer required' }); return; }
        sendJson(res, 200, { consumer, seq: cursorStore.get(consumer), exists: cursorStore.exists(consumer) });

      } else if (req.method === 'POST' && route === '/cursor') {
        const r = await readJsonOrError(req);
        if (r.error) { sendJsonBodyError(res, r.error); return; }
        const data = r.data;
        if (!data.consumer || data.seq === undefined) { sendJson(res, 400, { error: 'consumer and seq required' }); return; }
        if (!cursorStore.set(String(data.consumer), Number(data.seq))) { sendJson(res, 400, { error: 'invalid seq (must be non-negative integer)' }); return; }
        sendJson(res, 200, { consumer: String(data.consumer), seq: cursorStore.get(String(data.consumer)) });

      } else if (req.method === 'GET' && route === '/receiver') {
        sendJson(res, 200, receiver.read() || {});

      } else if (req.method === 'GET' && route === '/status') {
        sendJson(res, 200, {
          connected: !!bot.isConnected,
          uptime_sec: Math.floor((Date.now() - startTs) / 1000),
          msg_count: buffer.count(),
          consumers: cursorStore.list()
        });

      } else {
        sendJson(res, 404, { error: 'not found' });
      }
    } catch (e) {
      try { sendJson(res, 500, { error: String((e && e.message) || e) }); } catch (e2) {}
    }
  });
  return server;
}

module.exports = { createHttpServer };
