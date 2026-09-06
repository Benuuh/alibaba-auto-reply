// tests/http_api.test.js - HTTP 桥端点行为测试(注入 FakeBot,不依赖真实企微连接)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const { createHttpServer } = require('../lib/http_api.js');
const { CursorStore } = require('../lib/cursors.js');
const { MessageBuffer } = require('../lib/buffer.js');

function FakeBot(opts) {
  this.isConnected = (opts && opts.connected !== undefined) ? opts.connected : true;
  this.sent = [];
  this.sendFail = (opts && opts.sendFail) || null;
}
FakeBot.prototype.sendMessage = async function (to, payload) {
  if (this.sendFail) { throw new Error(this.sendFail); }
  this.sent.push({ to, payload });
  return { ok: true };
};

function FakeReceiver(initial) {
  this.data = initial || {};
}
FakeReceiver.prototype.read = function () { return this.data; };

function startServer(extra) {
  const store = new CursorStore(path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wchttp-')), 'cursors.json'));
  const buffer = new MessageBuffer();
  const receiver = new FakeReceiver({ last_userid: 'owner1' });
  const bot = new FakeBot(extra && extra.bot);
  const srv = createHttpServer({ bot, cursorStore: store, buffer, receiver });
  return new Promise((resolve) => {
    srv.listen(0, '127.0.0.1', () => {
      resolve({ srv, store, buffer, bot, port: srv.address().port });
    });
  });
}

function req(port, method, url, bodyObj) {
  return new Promise((resolve, reject) => {
    const data = bodyObj ? JSON.stringify(bodyObj) : null;
    const r = http.request({
      host: '127.0.0.1', port, method, path: url,
      headers: data ? { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data) } : {}
    }, (res) => {
      let chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = JSON.parse(text); } catch (e) {}
        resolve({ status: res.statusCode, json, text });
      });
    });
    r.on('error', reject);
    if (data) { r.write(data); }
    r.end();
  });
}

async function withServer(fn, extra) {
  const ctx = await startServer(extra);
  try { await fn(ctx); }
  finally { ctx.srv.close(); }
}

test('GET /health 反映连接状态', async () => {
  await withServer(async ({ port, bot }) => {
    let r = await req(port, 'GET', '/health');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.connected, true);
    bot.isConnected = false;
    r = await req(port, 'GET', '/health');
    assert.strictEqual(r.json.connected, false);
  });
});

test('POST /send 成功:bot 收到 markdown payload,返回 {ok:true}', async () => {
  await withServer(async ({ port, bot }) => {
    const r = await req(port, 'POST', '/send', { to: 'u1', text: '中文提醒内容' });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.ok, true);
    assert.strictEqual(bot.sent.length, 1);
    assert.strictEqual(bot.sent[0].to, 'u1');
    assert.strictEqual(bot.sent[0].payload.msgtype, 'markdown');
    assert.strictEqual(bot.sent[0].payload.markdown.content, '中文提醒内容');
  });
});

test('POST /send 缺 to/text 返回 400', async () => {
  await withServer(async ({ port }) => {
    let r = await req(port, 'POST', '/send', { to: 'u1' });
    assert.strictEqual(r.status, 400);
    r = await req(port, 'POST', '/send', { text: 'x' });
    assert.strictEqual(r.status, 400);
    r = await req(port, 'POST', '/send', {});
    assert.strictEqual(r.status, 400);
  });
});

test('POST 畸形 JSON body → 400,不崩溃', async () => {
  await withServer(async ({ port }) => {
    const r = await rawReq(port, 'POST', '/send', '{not json!!');
    assert.strictEqual(r.status, 400);
    assert.ok(r.text.includes('invalid json body'));
    const r2 = await rawReq(port, 'POST', '/cursor', 'hello');
    assert.strictEqual(r2.status, 400);
  });
});

test('POST 超大 body(>1MB)→ 413', async () => {
  await withServer(async ({ port }) => {
    const big = JSON.stringify({ to: 'u1', text: 'x'.repeat(1048576 + 100) });
    const r = await rawReq(port, 'POST', '/send', big);
    assert.strictEqual(r.status, 413);
  });
});

test('POST 非 JSON Content-Type(纯文本)→ 400', async () => {
  await withServer(async ({ port }) => {
    const r = await new Promise((resolve, reject) => {
      const req2 = http.request({ host: '127.0.0.1', port, method: 'POST', path: '/send',
        headers: { 'Content-Type': 'text/plain', 'Content-Length': 5 } }, (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
      });
      req2.on('error', reject);
      req2.end('plain');
    });
    assert.strictEqual(r.status, 400);
  });
});

function rawReq(port, method, path, body) {
  return new Promise((resolve, reject) => {
    const data = Buffer.isBuffer(body) ? body : Buffer.from(String(body), 'utf8');
    const r = http.request({
      host: '127.0.0.1', port, method, path,
      headers: { 'Content-Type': 'application/json', 'Content-Length': data.length }
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    r.on('error', reject);
    r.write(data);
    r.end();
  });
}

test('POST /send 长连接未建立返回 503', async () => {
  await withServer(async ({ port }) => {
    const r = await req(port, 'POST', '/send', { to: 'u1', text: 'x' });
    assert.strictEqual(r.status, 503);
  }, { bot: { connected: false } });
});

test('POST /send bot 抛错返回 500', async () => {
  await withServer(async ({ port }) => {
    const r = await req(port, 'POST', '/send', { to: 'u1', text: 'x' });
    assert.strictEqual(r.status, 500);
    assert.ok(r.json.error.length > 0);
  }, { bot: { sendFail: 'boom' } });
});

test('GET /messages 必须带 consumer,否则 400', async () => {
  await withServer(async ({ port }) => {
    const r = await req(port, 'GET', '/messages');
    assert.strictEqual(r.status, 400);
  });
});

test('GET /messages 返回 seq>after 的消息与 last_seq/cursor_seq,不推进游标', async () => {
  await withServer(async ({ port, buffer, store }) => {
    const m1 = buffer.push({ userid: 'u', content: 'one' });
    buffer.push({ userid: 'u', content: 'two' });
    const r = await req(port, 'GET', '/messages?consumer=agent-x&after=' + m1.seq);
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.consumer, 'agent-x');
    assert.deepStrictEqual(r.json.items.map((m) => m.content), ['two']);
    assert.strictEqual(r.json.cursor_seq, 0, '读取不推进游标');
    assert.strictEqual(r.json.last_seq, buffer.maxSeq());
  });
});

test('GET /messages 未给 after 时默认取消费者游标位置', async () => {
  await withServer(async ({ port, buffer, store }) => {
    const m1 = buffer.push({ userid: 'u', content: 'a' });
    const m2 = buffer.push({ userid: 'u', content: 'b' });
    store.set('agent-x', m1.seq);
    const r = await req(port, 'GET', '/messages?consumer=agent-x');
    assert.deepStrictEqual(r.json.items.map((m) => m.content), ['b']);
  });
});

test('POST /cursor 推进游标,GET /cursor 可读回', async () => {
  await withServer(async ({ port }) => {
    let r = await req(port, 'POST', '/cursor', { consumer: 'alibaba-auto-reply', seq: 12345 });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.seq, 12345);
    r = await req(port, 'GET', '/cursor?consumer=alibaba-auto-reply');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.seq, 12345);
    assert.strictEqual(r.json.exists, true);
    r = await req(port, 'GET', '/cursor?consumer=nobody');
    assert.strictEqual(r.json.exists, false);
    assert.strictEqual(r.json.seq, 0);
  });
});

test('POST /cursor 非法参数返回 400(缺 consumer / 缺 seq / 负值)', async () => {
  await withServer(async ({ port }) => {
    assert.strictEqual((await req(port, 'POST', '/cursor', { seq: 5 })).status, 400);
    assert.strictEqual((await req(port, 'POST', '/cursor', { consumer: 'x' })).status, 400);
    assert.strictEqual((await req(port, 'POST', '/cursor', { consumer: 'x', seq: -2 })).status, 400);
    assert.strictEqual((await req(port, 'POST', '/cursor', { consumer: 'x', seq: 1.5 })).status, 400);
  });
});

test('GET /receiver 返回接收方缓存', async () => {
  await withServer(async ({ port }) => {
    const r = await req(port, 'GET', '/receiver');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.last_userid, 'owner1');
  });
});

test('GET /status 汇总连接/消息数/消费者游标', async () => {
  await withServer(async ({ port, buffer, store }) => {
    buffer.push({ userid: 'u', content: 'x' });
    store.set('agent-x', 7);
    const r = await req(port, 'GET', '/status');
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.json.connected, true);
    assert.strictEqual(r.json.msg_count, 1);
    assert.deepStrictEqual(r.json.consumers, { 'agent-x': 7 });
    assert.ok(typeof r.json.uptime_sec === 'number');
  });
});

test('未知路径返回 404', async () => {
  await withServer(async ({ port }) => {
    const r = await req(port, 'GET', '/nope');
    assert.strictEqual(r.status, 404);
  });
});

test('多消费者通过 HTTP 各自推进互不影响', async () => {
  await withServer(async ({ port, buffer }) => {
    const m1 = buffer.push({ userid: 'u', content: 'a' });
    const m2 = buffer.push({ userid: 'u', content: 'b' });
    await req(port, 'POST', '/cursor', { consumer: 'alibaba-auto-reply', seq: m2.seq });
    await req(port, 'POST', '/cursor', { consumer: 'agent-x', seq: m1.seq });
    let r = await req(port, 'GET', '/messages?consumer=agent-x');
    assert.deepStrictEqual(r.json.items.map((m) => m.content), ['b'], 'agent-x 仍能读到自己的未读');
    r = await req(port, 'GET', '/messages?consumer=alibaba-auto-reply');
    assert.strictEqual(r.json.items.length, 0, 'alibaba-auto-reply 已读尽');
  });
});
