// lib/config.js - 配置加载:环境变量 > 配置文件(config.json) > 默认值
// 环境变量: WX_BOT_ID / WX_BOT_SECRET / WECOM_PORT / WX_RECEIVER_FILE / WECOM_DATA_DIR
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
  botSecret: ''
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
  return {
    host: asString(conf.host, DEFAULTS.host),
    port,
    dataDir,
    receiverFile: env.WX_RECEIVER_FILE ? asString(env.WX_RECEIVER_FILE, DEFAULTS.receiverFile) : resolvePath(asString(conf.receiver_file, DEFAULTS.receiverFile)),
    botId: asString(env.WX_BOT_ID, asString(conf.bot_id, DEFAULTS.botId)),
    botSecret: asString(env.WX_BOT_SECRET, asString(conf.bot_secret, DEFAULTS.botSecret))
  };
}

module.exports = { loadConfig };
