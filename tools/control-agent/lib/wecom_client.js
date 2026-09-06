// lib/wecom_client.js - wecom-connector 的 Node HTTP 客户端(薄封装)
// 对接端点: GET /messages?consumer=&after= / POST /cursor / POST /send / GET /receiver
'use strict';

const http = require('node:http');
const { URL } = require('node:url');

function request(baseUrl, method, pathAndQuery, bodyObj, timeoutMs) {
  return new Promise((resolve, reject) => {
    const url = new URL(pathAndQuery, baseUrl);
    const data = bodyObj ? JSON.stringify(bodyObj) : null;
    const req = http.request({
      host: url.hostname,
      port: url.port,
      method,
      path: url.pathname + url.search,
      headers: data ? { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data) } : {}
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try { json = text ? JSON.parse(text) : null; } catch (e) { json = null; }
        resolve({ status: res.statusCode, json, text });
      });
    });
    req.on('error', (e) => reject(e));
    if (timeoutMs) { req.setTimeout(timeoutMs, () => { req.destroy(new Error('timeout')); }); }
    if (data) { req.write(data); }
    req.end();
  });
}

// GET /messages?consumer=<name>[&after=<seq>] → {items[], last_seq} | throw
async function getMessages(baseUrl, consumer, after) {
  let q = '/messages?consumer=' + encodeURIComponent(consumer);
  if (after !== undefined && after !== null) { q += '&after=' + Number(after); }
  const r = await request(baseUrl, 'GET', q, null, 8000);
  if (r.status !== 200 || !r.json) { throw new Error('getMessages failed status=' + r.status + ' ' + (r.text || '').substring(0, 100)); }
  return { items: r.json.items || [], last_seq: r.json.last_seq || 0 };
}

// POST /cursor {consumer, seq} → true | throw
async function setCursor(baseUrl, consumer, seq) {
  const r = await request(baseUrl, 'POST', '/cursor', { consumer, seq }, 5000);
  if (r.status !== 200 || !r.json) { throw new Error('setCursor failed status=' + r.status); }
  return true;
}

// POST /send {to, text} → {ok} | throw
async function send(baseUrl, to, text) {
  const r = await request(baseUrl, 'POST', '/send', { to, text }, 15000);
  if (r.status !== 200 || !r.json || !r.json.ok) {
    throw new Error('send failed status=' + r.status + ' ' + (r.json && r.json.error ? r.json.error : ''));
  }
  return true;
}

// GET /receiver → 对象(可能为空) | throw(owner 自动识别用)
async function getReceiver(baseUrl) {
  const r = await request(baseUrl, 'GET', '/receiver', null, 5000);
  if (r.status !== 200 || !r.json) { throw new Error('getReceiver failed status=' + r.status); }
  return r.json;
}

module.exports = { getMessages, setCursor, send, getReceiver, request };
