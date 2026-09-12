'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { startFakeGateway, envelope, sendJson } = require('./fake-gateway');
const gw = require('../lib/gateway');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'accio-test-'));
}

test('findGatewayConfigPath: missing accounts dir -> GATEWAY-DOWN', () => {
  const dir = tempDir();
  const saved = process.env.ACCIO_GATEWAY_FILE;
  delete process.env.ACCIO_GATEWAY_FILE;
  try {
    assert.throws(() => gw.findGatewayConfigPath(dir), (e) => e.code === gw.ERR.GATEWAY_DOWN);
  } finally {
    if (saved) process.env.ACCIO_GATEWAY_FILE = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('findGatewayConfigPath: picks most recently modified account config', () => {
  const dir = tempDir();
  const saved = process.env.ACCIO_GATEWAY_FILE;
  delete process.env.ACCIO_GATEWAY_FILE;
  try {
    const a = path.join(dir, '.accio', 'accounts', '111', '.accio', 'runtime');
    const b = path.join(dir, '.accio', 'accounts', '222', '.accio', 'runtime');
    fs.mkdirSync(a, { recursive: true });
    fs.mkdirSync(b, { recursive: true });
    fs.writeFileSync(path.join(a, 'gateway-cli.json'), '{"url":"http://127.0.0.1:1/"}');
    fs.writeFileSync(path.join(b, 'gateway-cli.json'), '{"url":"http://127.0.0.1:2/"}');
    const now = Date.now() / 1000;
    fs.utimesSync(path.join(a, 'gateway-cli.json'), now - 100, now - 100);
    fs.utimesSync(path.join(b, 'gateway-cli.json'), now, now);
    const found = gw.findGatewayConfigPath(dir);
    assert.ok(found.indexOf(path.join('222', '.accio', 'runtime')) >= 0);
  } finally {
    if (saved) process.env.ACCIO_GATEWAY_FILE = saved;
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('readGatewayConfig: rejects invalid json / missing url', () => {
  const dir = tempDir();
  const bad = path.join(dir, 'bad.json');
  fs.writeFileSync(bad, '{oops');
  assert.throws(() => gw.readGatewayConfig(bad), (e) => e.code === gw.ERR.PROTOCOL_ERROR);
  const nourl = path.join(dir, 'nourl.json');
  fs.writeFileSync(nourl, '{"username":"u","password":"p","authMode":"basic"}');
  assert.throws(() => gw.readGatewayConfig(nourl), (e) => e.code === gw.ERR.PROTOCOL_ERROR);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('callProxy: 401 -> AUTH-401', async () => {
  const srv = await startFakeGateway((req, res) => {
    res.writeHead(401);
    res.end('unauthorized');
  });
  try {
    const cfg = { url: srv.url, username: 'u', password: 'p', authMode: 'basic' };
    await assert.rejects(gw.callProxy(cfg, { name: 'x', arguments: {} }), (e) => e.code === gw.ERR.AUTH_401);
  } finally {
    await srv.close();
  }
});

test('callProxy: timeout -> TIMEOUT', async () => {
  const srv = await startFakeGateway((req, res) => {
    setTimeout(() => sendJson(res, envelope({ ok: true })), 500);
  });
  try {
    const cfg = { url: srv.url, username: 'u', password: 'p', authMode: 'basic' };
    await assert.rejects(
      gw.callProxy(cfg, { name: 'x', arguments: {} }, { timeoutMs: 80 }),
      (e) => e.code === gw.ERR.TIMEOUT
    );
  } finally {
    await srv.close();
  }
});

test('callProxy: non-JSON body -> PROTOCOL-ERROR', async () => {
  const srv = await startFakeGateway((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('not json');
  });
  try {
    const cfg = { url: srv.url, username: 'u', password: 'p', authMode: 'basic' };
    await assert.rejects(gw.callProxy(cfg, { name: 'x', arguments: {} }), (e) => e.code === gw.ERR.PROTOCOL_ERROR);
  } finally {
    await srv.close();
  }
});

test('callProxy: sends basic auth header and returns envelope', async () => {
  let seenAuth = null;
  let seenBody = null;
  const srv = await startFakeGateway((req, res, body) => {
    seenAuth = req.headers.authorization;
    seenBody = body;
    sendJson(res, envelope({ data: { ok: 1 } }));
  });
  try {
    const cfg = { url: srv.url, username: 'user', password: 'p', authMode: 'basic' };
    const out = await gw.callProxy(cfg, { name: 'tool', arguments: { a: 1 } });
    assert.strictEqual(seenAuth, 'Basic ' + Buffer.from('user:p').toString('base64'));
    assert.deepStrictEqual(seenBody, { name: 'tool', arguments: { a: 1 } });
    assert.strictEqual(out.success, true);
  } finally {
    await srv.close();
  }
});

test('callProxy: connection refused -> GATEWAY-DOWN', async () => {
  const cfg = { url: 'http://127.0.0.1:1/', username: 'u', password: 'p', authMode: 'basic' };
  await assert.rejects(gw.callProxy(cfg, { name: 'x', arguments: {} }, { timeoutMs: 3000 }), (e) => e.code === gw.ERR.GATEWAY_DOWN);
});
