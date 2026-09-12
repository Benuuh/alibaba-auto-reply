#!/usr/bin/env node
'use strict';

// accio-client CLI：Accio Desktop 本地网关只读客户端（send 仅限用户指定的测试会话）。
// 输出：stdout 仅 JSON；stderr 仅人类可读信息。
const net = require('net');
const {
  ERR,
  GatewayError,
  findGatewayConfigPath,
  readGatewayConfig,
  callProxy,
} = require('./lib/gateway');
const api = require('./lib/api');

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--yes') { out.yes = true; continue; }
    if (a.indexOf('--') === 0) {
      const key = a.slice(2);
      const val = argv[i + 1] != null && argv[i + 1].indexOf('--') !== 0 ? argv[++i] : 'true';
      out[key] = val;
      continue;
    }
    out._.push(a);
  }
  return out;
}

function emit(obj, exitCode) {
  process.stdout.write(JSON.stringify(obj, null, 2) + '\n');
  process.exit(exitCode || 0);
}

function fail(e) {
  const code = e && e.code ? e.code : 'ERROR';
  const message = e && e.message ? e.message : String(e);
  process.stderr.write('[' + code + '] ' + message + '\n');
  emit({ ok: false, error: { code, message } }, 1);
}

function tcpProbe(url, timeoutMs) {
  return new Promise((resolve) => {
    let target;
    try { target = new URL(url); } catch (e) { resolve(false); return; }
    const socket = net.connect({ host: target.hostname, port: Number(target.port) || 80 });
    const timer = setTimeout(() => { socket.destroy(); resolve(false); }, timeoutMs || 3000);
    socket.once('connect', () => { clearTimeout(timer); socket.destroy(); resolve(true); });
    socket.once('error', () => { clearTimeout(timer); resolve(false); });
  });
}

async function cmdStatus() {
  const file = findGatewayConfigPath();
  const cfg = readGatewayConfig(file);
  const reachable = await tcpProbe(cfg.url, 3000);
  let auth = null;
  if (reachable) {
    try {
      await callProxy(cfg, { name: '__accio_client_probe__', arguments: {} }, { timeoutMs: 5000 });
      auth = true;
    } catch (e) {
      if (e && e.code === ERR.AUTH_401) auth = false;
      else if (e && (e.code === ERR.TIMEOUT || e.code === ERR.PROTOCOL_ERROR)) auth = true; // 网关应答即鉴权通过
      else auth = false;
    }
  }
  emit({
    ok: reachable,
    gateway: {
      configFound: true,
      url: cfg.url,
      relayPort: cfg.relayPort || null,
      pid: cfg.pid || null,
      reachable,
      auth,
    },
  });
}

async function cmdConversations(args) {
  const cfg = readGatewayConfig(findGatewayConfigPath());
  const conversations = await api.pullConversations(cfg, {
    pages: Number(args.pages || 5),
    count: Number(args.count || 50),
    timeoutMs: Number(args['timeout-ms'] || 15000),
  });
  emit({
    ok: true,
    count: conversations.length,
    conversations: conversations.map((c) => ({
      conversationId: c.conversationId,
      contactName: c.contactName,
      contactAliId: c.contactAliId,
      contactCountry: c.contactCountry,
      contactLevel: c.contactLevel,
      unreadMessageCount: c.unreadMessageCount,
      latestSendTime: c.latestMessage ? c.latestMessage.sendTime : null,
      latestSenderAliId: c.latestMessage ? c.latestMessage.senderAliId : null,
    })),
  });
}

async function cmdMessages(args) {
  const conversationId = args.conversation;
  if (!conversationId) throw new api.ApiError('INVALID-ARGS', '--conversation is required');
  const cfg = readGatewayConfig(findGatewayConfigPath());
  const self = args.self ? Number(args.self) : null;
  const messages = await api.pullMessages(cfg, {
    conversationId,
    selfAliId: self,
    timeoutMs: Number(args['timeout-ms'] || 60000),
    maxPages: Number(args['max-pages'] || 500),
  });
  const limit = args.limit ? Number(args.limit) : 0;
  const picked = limit > 0 ? messages.slice(-limit) : messages;
  emit({
    ok: true,
    conversationId,
    total: messages.length,
    count: picked.length,
    messages: picked.map((m) => ({
      timestamp: m.timestamp || null,
      sendTime: m.sendTime || null,
      senderAliId: m.senderAliId || null,
      fromUs: self ? String(m.senderAliId) === String(self) : null,
      content: m.content == null ? '' : String(m.content),
    })),
  });
}

async function cmdSend(args) {
  if (!args.yes) throw new api.ApiError('CONFIRM-REQUIRED', 'send requires --yes (only for user-approved test conversation)');
  const cfg = readGatewayConfig(findGatewayConfigPath());
  const r = await api.sendMessage(cfg, {
    conversationId: args.conversation || null,
    buyerAliId: args.to ? Number(args.to) : null,
    selfAliId: args.self ? Number(args.self) : null,
    content: args.text || '',
    timeoutMs: Number(args['timeout-ms'] || 30000),
  });
  const data = (r && r.data) || {};
  emit({ ok: true, messageID: data.messageID || null, businessID: data.businessID || null });
}

async function main() {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);
  const cmd = args._[0];
  try {
    if (cmd === 'status') return await cmdStatus();
    if (cmd === 'conversations') return await cmdConversations(args);
    if (cmd === 'messages') return await cmdMessages(args);
    if (cmd === 'send') return await cmdSend(args);
    emit({ ok: false, error: { code: 'USAGE', message: 'usage: cli.js status|conversations|messages|send' } }, 1);
  } catch (e) {
    if (e instanceof GatewayError || e instanceof api.ApiError) fail(e);
    else fail(new Error(e && e.message ? e.message : String(e)));
  }
}

main();
