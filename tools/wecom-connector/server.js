// server.js - wecom-connector 入口:企微智能机器人长连接 + 本地 HTTP 桥
// 用法: node server.js [config.json 路径]   (缺省读 server.js 同目录 config.json)
// 凭据优先级: 环境变量 WX_BOT_ID/WX_BOT_SECRET > 配置文件 bot_id/bot_secret
// 无凭据时不连接企微(health.connected=false,/send→503),HTTP 桥仍可用(便于测试与迁移)
'use strict';

const path = require('node:path');
const http = require('node:http');
const fs = require('node:fs');

const { loadConfig } = require('./lib/config.js');
const { CursorStore } = require('./lib/cursors.js');
const { MessageBuffer } = require('./lib/buffer.js');
const { ReceiverCache } = require('./lib/receiver.js');
const { createHttpServer } = require('./lib/http_api.js');
const { decideKickBackoff } = require('./lib/kick.js');

const configFile = process.env.WECOM_CONFIG || process.argv[2] || path.join(__dirname, 'config.json');
const cfg = loadConfig(configFile);

function ts() { return new Date().toISOString(); }
function log(msg) { console.log(ts() + ' ' + msg); }

const buffer = new MessageBuffer();
const cursorStore = new CursorStore(path.join(cfg.dataDir, 'cursors.json'));
const receiver = new ReceiverCache(cfg.receiverFile);

// ===== 被顶下线状态(kick_state.json;与 scripts\wecom_start.ps1 的"未连接自愈"共用) =====
// 语义: kicks=窗口内被顶下线时间戳(ms); backoffUntilMs>now 表示本实例被顶下线后主动退避,
// 期间不连接企微(HTTP 桥照常服务);退避结束才 bot.connect()。读写一律 try/catch(C9:损坏视为无状态)。
const kickStateFile = path.join(cfg.dataDir, 'kick_state.json');
const freshKickState = () => ({ kicks: [], backoffUntilMs: 0 });

function loadKickState() {
  try {
    if (!fs.existsSync(kickStateFile)) { return freshKickState(); }
    const raw = fs.readFileSync(kickStateFile, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') { return freshKickState(); }
    const kicks = Array.isArray(parsed.kicks) ? parsed.kicks.filter((t) => Number.isFinite(t)) : [];
    const backoffUntilMs = Number.isFinite(parsed.backoffUntilMs) ? parsed.backoffUntilMs : 0;
    return { kicks, backoffUntilMs };
  } catch (e) {
    console.error(ts() + ' KICK-STATE-READ-FAIL: ' + ((e && e.message) || e));
    return freshKickState();
  }
}

function saveKickState(state) {
  try {
    fs.mkdirSync(cfg.dataDir, { recursive: true });
    fs.writeFileSync(kickStateFile, JSON.stringify(state), 'utf8');
  } catch (e) {
    console.error(ts() + ' KICK-STATE-WRITE-FAIL: ' + ((e && e.message) || e));
  }
}

const kickState = loadKickState();
let kickStableTimer = null;

function clearKickStableTimer() {
  if (kickStableTimer) { clearTimeout(kickStableTimer); kickStableTimer = null; }
}

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

  // 被顶下线(disconnected_event)处理:SDK 在收到该事件后设 isManualClose=true 且永不重连(R1),
  // 因此本进程的唯一自愈路径是"退出 + 由 watchdog/wecom_start.ps1 重新拉起"。
  // 注意:事件名与本 handler 必须写在 bot.connect() 之前,避免连接早于监听建立而漏掉该帧。
  bot.on('event.disconnected_event', () => {
    const r = decideKickBackoff(kickState.kicks, Date.now(), cfg.kick);
    kickState.kicks = r.kicks;
    kickState.backoffUntilMs = r.backoffUntilMs;
    saveKickState(kickState);
    log('KICKED-OFFLINE: server closed this connection because a new connection was established;'
      + ' exiting in ' + cfg.kick.exitDelayMs + 'ms (backoff ' + (r.long ? 'LONG' : 'short') + ')');
    if (cfg.kick.exitOnKickedOffline) {
      setTimeout(() => process.exit(0), cfg.kick.exitDelayMs);
    }
  });

  // 启动退避:上次被顶下线后的退避未结束 → 延后连接(HTTP 桥照常先监听,/health 返回 connected:false)
  const backoffLeftMs = kickState.backoffUntilMs - Date.now();
  if (backoffLeftMs > 0) {
    log('KICK-BACKOFF-WAIT ms=' + backoffLeftMs);
    setTimeout(() => { if (bot) { bot.connect(); } }, backoffLeftMs);
  } else {
    bot.connect();
  }

  bot.on('authenticated', () => {
    log('AUTH-OK: long connection established');
    // 稳定清窗:连续在线 kickStableResetMin 分钟后清空被顶下线历史与退避,避免长期累积误触长退避
    if (cfg.kick.stableResetMin > 0) {
      clearKickStableTimer();
      kickStableTimer = setTimeout(() => {
        kickStableTimer = null;
        kickState.kicks = [];
        kickState.backoffUntilMs = 0;
        saveKickState(kickState);
        log('KICK-WINDOW-CLEARED');
      }, cfg.kick.stableResetMin * 60000);
      if (kickStableTimer.unref) { kickStableTimer.unref(); }
    }
  });
  bot.on('error', (e) => {
    console.error(ts() + ' ERROR: ' + ((e && e.message) || e));
  });
  bot.on('disconnected', (reason) => {
    clearKickStableTimer();
    log('DISCONNECTED (reason: ' + (reason || 'unknown') + ')');
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
  clearKickStableTimer();
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
