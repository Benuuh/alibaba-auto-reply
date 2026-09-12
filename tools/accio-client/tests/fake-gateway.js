'use strict';

// 测试用 fake gateway：本地随机端口 HTTP server，按工具名返回 fixture。
const http = require('http');

function startFakeGateway(handler) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => { body += c; });
      req.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(body); } catch (e) { /* ignore */ }
        handler(req, res, parsed);
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      resolve({
        url: 'http://127.0.0.1:' + port + '/',
        port,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

function envelope(payload, opts) {
  const options = opts || {};
  return {
    success: options.success !== false,
    data: {
      content: [{ type: 'text', text: typeof payload === 'string' ? payload : JSON.stringify(payload) }],
      isError: !!options.isError,
    },
  };
}

function sendJson(res, obj, statusCode) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode || 200, { 'Content-Type': 'application/json' });
  res.end(body);
}

module.exports = { startFakeGateway, envelope, sendJson };
