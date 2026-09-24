// lib/config.js - 配置加载:环境变量 > 配置文件(config.json) > 默认值
// 环境变量: WX_BOT_ID / WX_BOT_SECRET / WECOM_PORT / WX_RECEIVER_FILE / WECOM_DATA_DIR / WX_EXIT_ON_KICKED_OFFLINE
// 配置文件示例见 config.json.example;bot 凭据既可入配置文件(仅本地),也可由启动方经环境变量注入
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const DEFAULTS = {
  host: '127.0.0.1',
  port: 19886,
  dataDir: 'data',
  receiverFile: 'data/wecom_receiver.json',
  botId: '',
  botSecret: '',
  // 被顶下线(disconnected_event)后的自愈开关与退避参数;SDK 在该态永不重连,故只能由进程退出+守护者拉起接管
  exitOnKickedOffline: true,
  kickExitDelayMs: 1000,
  kickWindowMin: 30,
  kickThreshold: 3,
  kickShortBackoffSec: 60,
  kickLongBackoffMin: 30,
  kickStableResetMin: 10
};

function parsePort(v) {
  const n = parseInt(v, 10);
  if (Number.isInteger(n) && n > 0 && n < 65536) { return n; }
  return DEFAULTS.port;
}

// 类型守卫:非法类型/空值回退默认(防止 path 拼接 TypeError 等)
function asString(v, d) {
  return typeof v === 'string' && v.length > 0 ? v : d;
}

// 正整数守卫:非法/NaN/越界回退默认
function asInt(v, d, min, max) {
  const n = parseInt(String(v), 10);
  if (!Number.isInteger(n) || n < min || n > max) { return d; }
  return n;
}

// 布尔语义:只有显式 false 才关闭(缺省/非法值一律保持开启,避免静默失效)
function asBool(v, d) {
  return v === undefined ? d : v !== false;
}

// 取值顺序:环境变量 > 配置文件 > 默认值;两者都非法时回退默认
function pickInt(envRaw, confRaw, d, min, max) {
  if (envRaw !== undefined && envRaw !== '') { return asInt(envRaw, d, min, max); }
  return asInt(confRaw, d, min, max);
}

// cfgFile: 配置文件路径(不存在或损坏时用默认)
function loadConfig(cfgFile) {
  const conf = {};
  if (cfgFile && fs.existsSync(cfgFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
      if (parsed && typeof parsed === 'object') { Object.assign(conf, parsed); }
    } catch (e) { /* 损坏回退默认 */ }
  }
  const baseDir = cfgFile ? path.dirname(cfgFile) : process.cwd();
  const resolvePath = (p) => (path.isAbsolute(p) ? p : path.join(baseDir, p));

  const env = process.env;
  const port = env.WECOM_PORT ? parsePort(env.WECOM_PORT) : parsePort(conf.port || DEFAULTS.port);
  // 环境变量原样使用(启动方精确控制);配置文件相对路径基于 config.json 所在目录解析
  const dataDir = env.WECOM_DATA_DIR ? asString(env.WECOM_DATA_DIR, DEFAULTS.dataDir) : resolvePath(asString(conf.data_dir, DEFAULTS.dataDir));
  // 被顶下线自愈参数:环境变量 WX_EXIT_ON_KICKED_OFFLINE(仅字符串 'false' 关闭) > config.json 布尔 > 默认开
  const envExitOnKick = (env.WX_EXIT_ON_KICKED_OFFLINE === undefined || env.WX_EXIT_ON_KICKED_OFFLINE === '')
    ? undefined
    : env.WX_EXIT_ON_KICKED_OFFLINE !== 'false';
  return {
    host: asString(conf.host, DEFAULTS.host),
    port,
    dataDir,
    receiverFile: env.WX_RECEIVER_FILE ? asString(env.WX_RECEIVER_FILE, DEFAULTS.receiverFile) : resolvePath(asString(conf.receiver_file, DEFAULTS.receiverFile)),
    botId: asString(env.WX_BOT_ID, asString(conf.bot_id, DEFAULTS.botId)),
    botSecret: asString(env.WX_BOT_SECRET, asString(conf.bot_secret, DEFAULTS.botSecret)),
    // 嵌套成 cfg.kick,便于 server.js / 测试集中引用;上限为防呆(退避不得长到掩盖故障)
    kick: {
      exitOnKickedOffline: asBool(envExitOnKick, asBool(conf.exit_on_kicked_offline, DEFAULTS.exitOnKickedOffline)),
      exitDelayMs: pickInt(undefined, conf.kick_exit_delay_ms, DEFAULTS.kickExitDelayMs, 0, 600000),
      windowMin: pickInt(undefined, conf.kick_window_min, DEFAULTS.kickWindowMin, 1, 1440),
      threshold: pickInt(undefined, conf.kick_threshold, DEFAULTS.kickThreshold, 1, 100),
      shortBackoffSec: pickInt(undefined, conf.kick_short_backoff_sec, DEFAULTS.kickShortBackoffSec, 1, 86400),
      longBackoffMin: pickInt(undefined, conf.kick_long_backoff_min, DEFAULTS.kickLongBackoffMin, 1, 10080),
      stableResetMin: pickInt(undefined, conf.kick_stable_reset_min, DEFAULTS.kickStableResetMin, 1, 10080)
    }
  };
}

module.exports = { loadConfig };
