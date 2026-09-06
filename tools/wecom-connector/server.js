// server.js - wecom-connector 入口:企微智能机器人长连接 + 本地 HTTP 桥
// 用法: node server.js [config.json 路径]   (缺省读 server.js 同目录 config.json)
// 凭据优先级: 环境变量 WX_BOT_ID/WX_BOT_SECRET > 配置文件 bot_id/bot_secret
// 无凭据时不连接企微(health.connected=false,/send→503),HTTP 桥仍可用(便于测试与迁移)
'use strict';

const path = require('node:path');
const http = require('node:http');

const { loadConfig } = require('./lib/config.js');
const { CursorStore } = require('./lib/cursors.js');
const { MessageBuffer } = require('./lib/buffer.js');
const { ReceiverCache } = require('./lib/receiver.js');
const { createHttpServer } = require('./lib/http_api.js');

const configFile = process.env.WECOM_CONFIG || process.argv[2] || path.join(__dirname, 'config.json');
const cfg = loadConfig(configFile);

function ts() { return new Date().toISOString(); }
function log(msg) { console.log(ts() + ' ' + msg); }

const buffer = new MessageBuffer();
const cursorStore = new CursorStore(path.join(cfg.dataDir, 'cursors.json'));
const receiver = new ReceiverCache(cfg.receiverFile);

// ===== 企微帧解析(与原 wecom_bot.js 语义一致) =====
function chatIdOf(frame) {
  const b = (frame && frame.body) || {};
  return b.chatid || (b.conv && b.conv.chatid) || (b.chat && b.chat.chatid) || '';
}
function frameIds(frame) {
  const b = (frame && frame.body) || {};
  return {
    userid: (b.from && b.from.userid) || '',
    chatid: chatIdOf(frame)
  };
}
function saveReceiverIfKnown(frame, tag, userSuffix, chatSuffix) {
  const ids = frameIds(frame);
  const us = userSuffix ? ' ' + userSuffix : '';
  const cs = chatSuffix ? ' ' + chatSuffix : '';
  if (ids.userid) {
    receiver.save({ last_userid: ids.userid, last_ts: ts() });
    log(tag + ' userid=' + ids.userid + us);
  } else if (ids.chatid) {
    receiver.save({ last_chatid: ids.chatid, last_ts: ts() });
    log(tag + ' chatid=' + ids.chatid + cs);
  }
}

let bot = null;
let botName = 'no-bot';
if (!cfg.botId || !cfg.botSecret) {
  log('WARN: WX_BOT_ID/WX_BOT_SECRET not provided (config file or env). Bot NOT connected; HTTP bridge serves health/send(503)/messages/cursor/receiver/status.');
} else {
  const AiBot = require('@wecom/aibot-node-sdk');
  // 敏感铁律:SDK 默认 DEBUG 日志会把真实 bot id/userid 写入日志,注入仅 warn/error 的静音 logger
  const quietLogger = {
    debug: function () {},
    info: function () {},
    warn: function () { console.error(ts() + ' SDK-WARN: ' + Array.prototype.join.call(arguments, ' ')); },
    error: function () { console.error(ts() + ' SDK-ERROR: ' + Array.prototype.join.call(arguments, ' ')); }
  };
  bot = new AiBot.WSClient({ botId: cfg.botId, secret: cfg.botSecret, logger: quietLogger });
  botName = 'WSClient';
  bot.connect();

  bot.on('authenticated', () => {
    log('AUTH-OK: long connection established');
  });
  bot.on('error', (e) => {
    console.error(ts() + ' ERROR: ' + ((e && e.message) || e));
  });
  bot.on('disconnected', () => {
    log('DISCONNECTED (SDK will reconnect)');
  });
  bot.on('message.text', (frame) => {
    const content = (frame && frame.body && frame.body.text && frame.body.text.content) || '';
    const ids = frameIds(frame);
    buffer.push({ userid: ids.userid, chatid: ids.chatid, content });
    saveReceiverIfKnown(frame, 'MSG', 'text=' + content.substring(0, 80));
  });
  bot.on('event.enter_chat', (frame) => {
    log('ENTER-CHAT chatid=' + chatIdOf(frame));
  });
  bot.on('message', (frame) => {
    saveReceiverIfKnown(frame, 'EVENT', null, 'type=' + (frame.type || ''));
  });
}

// ===== 本地 HTTP 桥 =====
const server = createHttpServer({
  bot: { get isConnected() { return !!bot && !!bot.isConnected; }, sendMessage: (to, payload) => bot.sendMessage(to, payload) },
  cursorStore,
  buffer,
  receiver
});

server.listen(cfg.port, cfg.host, () => {
  log('HTTP-READY ' + cfg.host + ':' + cfg.port + ' (bot=' + botName + ', dataDir=' + cfg.dataDir + ')');
});

function shutdown() {
  if (bot) { try { bot.disconnect(); } catch (e) {} }
  server.close();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// 端口被占时友好退出(供启动脚本判断)
server.on('error', (e) => {
  if (e && e.code === 'EADDRINUSE') {
    console.error(ts() + ' PORT-IN-USE: ' + cfg.port);
    process.exit(3);
  }
  console.error(ts() + ' SERVER-ERROR: ' + ((e && e.message) || e));
});
