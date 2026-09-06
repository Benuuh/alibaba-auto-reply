// tests/helpers/mock_wecom_server.js - 集成测试用的 mock wecom-connector HTTP 服务(进程内,不连真实企微)
// 显式标注:全部为 mock 数据,仅用于桥的集成测试
'use strict';
const http = require('node:http');

function createMockWecomServer() {
  let seq = 0;
  const messages = [];      // {seq, ts, userid, content}
  let cursor = 0;           // 最近一次 POST /cursor
  const sent = [];          // {to, text}
  let receiver = { last_userid: 'owner1' };

  function pushMsg(userid, content) {
    seq += 1;
    const m = { seq, ts: new Date().toISOString(), userid, chatid: userid, content };
    messages.push(m);
    return m;
  }

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const sendJson = (status, obj) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
    };
    if (req.method === 'GET' && url.pathname === '/messages') {
      const consumer = url.searchParams.get('consumer');
      const after = Number(url.searchParams.get('after') || 0);
      const items = messages.filter((m) => m.seq > after);
      sendJson(200, { consumer, after, last_seq: seq, cursor_seq: cursor, items });
    } else if (req.method === 'POST' && url.pathname === '/cursor') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const d = JSON.parse(body);
        cursor = Number(d.seq);
        sendJson(200, { consumer: d.consumer, seq: cursor });
      });
    } else if (req.method === 'POST' && url.pathname === '/send') {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        const d = JSON.parse(body);
        sent.push({ to: d.to, text: d.text });
        sendJson(200, { ok: true });
      });
    } else if (req.method === 'GET' && url.pathname === '/receiver') {
      sendJson(200, receiver);
    } else {
      sendJson(404, { error: 'not found' });
    }
  });

  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({
        server,
        port: server.address().port,
        pushMsg,
        get sent() { return sent; },
        get cursor() { return cursor; },
        get messages() { return messages; },
        setReceiver(r) { receiver = r; }
      });
    });
  });
}

module.exports = { createMockWecomServer };
