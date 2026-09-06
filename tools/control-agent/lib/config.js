// lib/config.js - control-agent 配置加载:环境变量 > config.json > 默认值
// 环境变量: WECOM_BASE_URL / CONTROL_AGENT_CONFIG(配置文件路径,缺省 agent 根目录 config.json)
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ALIBABA_ROOT = path.resolve(__dirname, '..', '..');
const WORKSPACE_ROOT = path.resolve(__dirname, '..', '..', '..');

const DEFAULTS = {
  wecom_base_url: 'http://127.0.0.1:19886',
  consumer: 'control-agent',
  owner_userid: '',
  projects: {},
  whitelist_files: ['reply_rules.json', 'reply_agent_prompt.md', 'config.json'],
  // 可插拔执行层:type = dsh | opencode | claude | command
  executor: {
    type: 'dsh',
    command: 'dsh --profile headless {prompt}',
    timeout_sec: 300,
    workdir: WORKSPACE_ROOT
  },
  // 可选 LLM 风险分类兜底(默认关闭,纯规则零依赖)
  use_llm_classify: false,
  classify_endpoint: 'https://api.deepseek.com/chat/completions',
  classify_model: 'deepseek-chat',
  classify_timeout_ms: 20000,
  alibaba_data_dir: path.join(ALIBABA_ROOT, 'alibaba-auto-reply-main', 'data'),
  poll_interval_ms: 5000,
  throttle_sec: 60,
  confirm_ttl_sec: 300,
  reply_max_chars: 4000,
  skills_dir: path.join(WORKSPACE_ROOT, 'skills-main', 'skills', 'engineering'),
  data_dir: 'data',
  logs_dir: 'logs',
  history_max: 1000,
  log_max_bytes: 5242880,   // 5MB
  log_keep: 10
};

function loadConfig(cfgFile) {
  const conf = {};
  if (cfgFile && fs.existsSync(cfgFile)) {
    try {
      // 容错:PS 5.1 Set-Content -Encoding UTF8 写出的文件带 BOM,JSON.parse 遇 BOM 抛 SyntaxError,
      // 必须先剥 \uFEFF 再解析(否则配置静默回退默认)
      const raw = fs.readFileSync(cfgFile, 'utf8').replace(/^\uFEFF/, '');
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') { Object.assign(conf, parsed); }
    } catch (e) { /* 损坏回退默认 */ }
  }
  const root = cfgFile ? path.dirname(cfgFile) : process.cwd();
  const resolvePath = (p) => (path.isAbsolute(p) ? p : path.join(root, p));
  const env = process.env;

  const executor = Object.assign({}, DEFAULTS.executor, conf.executor || {});
  const projects = {};
  if (conf.projects && typeof conf.projects === 'object') {
    for (const name of Object.keys(conf.projects)) { projects[name] = resolvePath(conf.projects[name]); }
  }
  const cfg = {
    wecom_base_url: env.WECOM_BASE_URL || conf.wecom_base_url || DEFAULTS.wecom_base_url,
    consumer: conf.consumer || DEFAULTS.consumer,
    owner_userid: conf.owner_userid || DEFAULTS.owner_userid,
    projects,
    whitelist_files: Array.isArray(conf.whitelist_files) && conf.whitelist_files.length ? conf.whitelist_files : DEFAULTS.whitelist_files,
    executor: {
      type: executor.type || DEFAULTS.executor.type,
      command: executor.command || DEFAULTS.executor.command,
      timeout_sec: Number(executor.timeout_sec) || DEFAULTS.executor.timeout_sec,
      workdir: resolvePath(executor.workdir) || DEFAULTS.executor.workdir
    },
    use_llm_classify: !!conf.use_llm_classify,
    classify_endpoint: conf.classify_endpoint || DEFAULTS.classify_endpoint,
    classify_model: conf.classify_model || DEFAULTS.classify_model,
    classify_timeout_ms: Number(conf.classify_timeout_ms) || DEFAULTS.classify_timeout_ms,
    classify_key_file: conf.classify_key_file ? resolvePath(conf.classify_key_file) : '',
    alibaba_data_dir: conf.alibaba_data_dir ? resolvePath(conf.alibaba_data_dir) : DEFAULTS.alibaba_data_dir,
    poll_interval_ms: Number(conf.poll_interval_ms) || DEFAULTS.poll_interval_ms,
    throttle_sec: Number(conf.throttle_sec) || DEFAULTS.throttle_sec,
    confirm_ttl_sec: Number(conf.confirm_ttl_sec) || DEFAULTS.confirm_ttl_sec,
    reply_max_chars: Number(conf.reply_max_chars) || DEFAULTS.reply_max_chars,
    skills_dir: conf.skills_dir ? resolvePath(conf.skills_dir) : DEFAULTS.skills_dir,
    data_dir: resolvePath(conf.data_dir || DEFAULTS.data_dir),
    logs_dir: resolvePath(conf.logs_dir || DEFAULTS.logs_dir),
    history_max: Number(conf.history_max) || DEFAULTS.history_max,
    log_max_bytes: Number(conf.log_max_bytes) || DEFAULTS.log_max_bytes,
    log_keep: Number(conf.log_keep) || DEFAULTS.log_keep
  };
  cfg.cursor_file = path.join(cfg.data_dir, 'cursor.json');
  cfg.pending_file = path.join(cfg.data_dir, 'pending.json');
  cfg.history_file = path.join(cfg.data_dir, 'history.jsonl');
  cfg.log_file = path.join(cfg.logs_dir, 'agent.log');
  return cfg;
}

module.exports = { loadConfig, DEFAULTS };
