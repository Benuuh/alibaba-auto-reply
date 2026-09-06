// agent_bridge.js - control-agent 常驻桥(v0.4):轮询 wecom-connector → 确认闸门 → 可插拔 executor → 回发
// 主循环每 poll_interval_ms 一次 tick;消费方游标 "control-agent"(独立于 alibaba-auto-reply)
// v0.4:无固定命令、无规则匹配,所有消息统一走 owner 校验 → 60s 节流 → 确认闸门 → 派发 executor
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { loadConfig } = require('./lib/config.js');
const { createLogger } = require('./lib/log.js');
const { StateStore } = require('./lib/state.js');
const wecom = require('./lib/wecom_client.js');
const { classify } = require('./lib/classify.js');
const { readControlApiKey } = require('./lib/creds.js');
const gate = require('./lib/gate.js');
const { createExecutor } = require('./lib/executor.js');

// deps 可注入(集成测试): {config, log, state, wecomClient, classifier, executor, keyProvider, nowMs}
function createBridge(deps) {
  const config = deps.config;
  const log = deps.log;
  const state = deps.state;
  const wecomClient = deps.wecomClient;
  const classifier = deps.classifier || classify;
  const executor = deps.executor;
  const keyProvider = deps.keyProvider || (() => (config.use_llm_classify ? readControlApiKey(config.classify_key_file) : null));
  const nowMs = deps.nowMs || (() => Date.now());

  let timer = null;
  let running = false;
  const lastExecByContent = {};   // 节流: content → ts

  function truncate(text, max) {
    const s = String(text || '');
    return s.length > max ? s.substring(0, max) + '...(截断)' : s;
  }

  function errMsg(e) {
    return (e && e.message) || e;
  }

  async function sendReply(to, text) {
    try { await wecomClient.send(config.wecom_base_url, to, truncate(text, config.reply_max_chars)); }
    catch (e) { log.log('SEND-FAIL: ' + errMsg(e)); }
  }

  // 人工接管白名单 data\manual_override.json(与 monitor.ps1 同源同格式:JSON 数组,买家名小写保空格)
  function whitelistFile() {
    return (config.alibaba_data_dir ? path.join(config.alibaba_data_dir, 'manual_override.json') : '');
  }
  function loadWhitelist() {
    const p = whitelistFile();
    if (!p || !fs.existsSync(p)) { return { path: p, list: [] }; }
    try {
      const arr = JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, ''));
      return { path: p, list: Array.isArray(arr) ? arr.map((x) => String(x).trim()) : [] };
    } catch (e) { return { path: p, list: [] }; }
  }
  function saveWhitelist(p, list) {
    fs.writeFileSync(p, JSON.stringify(list, null, 2) + '\n', 'utf8');
  }
  // 归一化:小写、下划线转空格、压空白(与 Get-StateKey 对齐,便于 monitor 匹配)
  function normCustomer(s) {
    return String(s || '').toLowerCase().replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
  }
  // 白名单管理指令(硬编码直处理,不经外部 agent/确认闸门)
  async function handleWhitelistCmd(m, content, userid) {
    const wlRe = /^(?:白名单|whitelist)\s+(添加|删除|列表|add|remove|list)\s*(.*)$/i;
    const wm = wlRe.exec(content);
    if (!wm) { return false; }
    const action = wm[1].toLowerCase();
    const customer = normCustomer(wm[2]);
    if (action === 'list' || action === '列表') {
      const { list } = loadWhitelist();
      const reply = list.length ? ('当前人工接管白名单(' + list.length + '): ' + list.join('、')) : '白名单为空,所有客户均自动回复';
      await sendReply(userid, reply);
      addHistory({ seq: m.seq, userid: userid, content: content, result: 'whitelist-list' });
      log.log('WHITELIST-LIST: count=' + list.length);
      return true;
    }
    if (!customer) {
      await sendReply(userid, '用法: 白名单 添加|删除|列表 <客户名>');
      return true;
    }
    const { path: p, list } = loadWhitelist();
    if (!p) {
      await sendReply(userid, '无法定位白名单文件(control-agent 未配置 alibaba_data_dir)');
      return true;
    }
    const isAdd = (action === '添加' || action === 'add');
    const exists = list.indexOf(customer) >= 0;
    if (isAdd) {
      if (exists) { await sendReply(userid, '已在白名单中(人工接管,不自动回复): ' + customer); }
      else { saveWhitelist(p, list.concat([customer])); await sendReply(userid, '已加入人工接管白名单(不再自动回复): ' + customer); }
      log.log('WHITELIST-ADD: ' + customer);
    } else {
      if (!exists) { await sendReply(userid, '不在白名单中: ' + customer); }
      else { saveWhitelist(p, list.filter((x) => x !== customer)); await sendReply(userid, '已移出白名单(恢复自动回复): ' + customer); }
      log.log('WHITELIST-REMOVE: ' + customer);
    }
    addHistory({ seq: m.seq, userid: userid, content: content, result: isAdd ? 'whitelist-add' : 'whitelist-remove' });
    return true;
  }

  // owner 自动识别(单设备 bootstrap):config.owner_userid 为空时,
  // 取 wecom-connector receiver.last_userid(最近给 bot 发消息的人=单 owner 场景的控制者)；
  // 命中则锁定并写入 config.json(用户可复核/修改),回发确认提示
  async function resolveOwner(userid) {
    if (config.owner_userid) { return config.owner_userid; }
    if (!userid) { return ''; }
    let rcv = null;
    try { rcv = await wecomClient.getReceiver(config.wecom_base_url); } catch (e) { return ''; }
    if (!rcv || !rcv.last_userid || rcv.last_userid !== userid) { return ''; }
    config.owner_userid = String(userid);
    try {
      const cfgFile = process.env.CONTROL_AGENT_CONFIG || path.join(__dirname, 'config.json');
      if (fs.existsSync(cfgFile)) {
        const raw = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
        raw.owner_userid = config.owner_userid;
        fs.writeFileSync(cfgFile, JSON.stringify(raw, null, 2) + '\n', 'utf8');
      }
    } catch (e) { log.log('OWNER-PERSIST-FAIL: ' + errMsg(e)); }
    log.log('OWNER-AUTO-DETECTED: ' + config.owner_userid + ' (written to config.json)');
    return config.owner_userid;
  }

  function addHistory(entry) {
    state.appendHistory(Object.assign({ ts: new Date().toISOString() }, entry));
  }

  // 确认码流程:回复 "确认1234" → 匹配待确认项 → 派发原指令执行 → 清除
  async function handleConfirm(m, code) {
    if (!code) { return false; }
    const pendingList = state.listPending().filter((p) => p.userid === m.userid);
    const found = gate.findPendingByCode(pendingList, code, nowMs());
    if (!found) {
      await sendReply(m.userid, '确认码不匹配或已过期,请重新发送指令。');
      addHistory({ seq: m.seq, userid: m.userid, content: m.content, confirmed: false, result: 'confirm-rejected' });
      log.log('CONFIRM-MISMATCH: code=' + code);
      return true;
    }
    state.removePending(found.seq);
    const action = found.action || found.message;   // action 为 Spec 字段名;message 兼容旧数据
    addHistory({ seq: m.seq, userid: m.userid, content: m.content, confirmed: true, result: 'confirm-ok', summary: found.summary });
    log.log('CONFIRM-OK: seq=' + found.seq + ' code=' + code + ' action=[' + action.substring(0, 60) + ']');
    await dispatchAndReply(action, m.userid, found.summary, true, found.seq, 'high');
    return true;
  }

  // 派发 executor 并回发(唯一执行路径:确认后或直发)
  async function dispatchAndReply(instruction, to, summary, confirmed, seq, risk) {
    const workdir = executor.resolveWorkdir(instruction);
    log.log('DISPATCH: workdir=' + (workdir || '(default)') + ' confirmed=' + (confirmed ? 'y' : 'n'));
    try {
      const r = await executor.dispatch(instruction, workdir);
      // 结果截断至 reply_max_chars,前缀(✅+摘要)预留 300 字符,sendReply 保证总长 ≤ reply_max_chars
      const reply = '✅ 执行完成' + (summary ? '\n指令摘要: ' + summary : '') + '\n\n' + truncate(r.text, config.reply_max_chars - 300);
      await sendReply(to, reply);
      addHistory({ seq: seq, userid: to, content: instruction, risk: risk, confirmed: !!confirmed, summary: summary || '', result: 'ok:' + String(r.text).substring(0, 80) });
      log.log('EXEC-OK: len=' + String(r.text).length);
    } catch (e) {
      const errText = truncate(errMsg(e) || String(e), 800);
      await sendReply(to, '❌ 执行失败\n' + errText);
      addHistory({ seq: seq, userid: to, content: instruction, risk: risk, confirmed: !!confirmed, summary: summary || '', result: 'error:' + errText.substring(0, 120) });
      log.log('EXEC-FAIL: ' + errText);
    }
  }

  // 单条消息处理(v0.4:无命令匹配,全部消息 → 闸门 → 派发)
  async function processMessage(m) {
    const userid = String(m.userid || '');
    const content = String(m.content || '').trim();
    if (!content) { return; }

    // owner 自动识别(未配置时):receiver.last_userid 命中即锁定
    const effectiveOwner = await resolveOwner(userid);
    if (userid !== effectiveOwner) {
      log.log('IGNORE-NON-OWNER: userid=' + userid + ' content=[' + content.substring(0, 40) + ']');
      addHistory({ seq: m.seq, userid: userid, content: content, result: 'ignored-non-owner' });
      return;
    }

    // 白名单管理指令(owner 专属,直接处理)
    if (await handleWhitelistCmd(m, content, userid)) { return; }

    // 确认码优先
    const confirmCode = gate.extractConfirmCode(content);
    if (confirmCode) {
      await handleConfirm(m, confirmCode);
      return;
    }

    // 节流:同内容 60 秒内不重复处理(定期清理过期条目,防长跑内存增长)
    const now = nowMs();
    const lastTs = lastExecByContent[content];
    if (lastTs && (now - lastTs) < (config.throttle_sec || 60) * 1000) {
      log.log('THROTTLE: content=[' + content.substring(0, 40) + ']');
      return;
    }
    lastExecByContent[content] = now;
    if (Object.keys(lastExecByContent).length > 200) {
      const cutoff = now - (config.throttle_sec || 60) * 1000 * 2;
      for (const k of Object.keys(lastExecByContent)) {
        if (lastExecByContent[k] < cutoff) { delete lastExecByContent[k]; }
      }
    }

    // 可选 LLM 风险分类兜底(use_llm_classify=true 时;默认 false 纯规则零依赖)
    let cl = {};
    if (config.use_llm_classify) {
      const key = keyProvider();
      if (!key) {
        log.log('CLASSIFY-KEY-MISSING: control_api_key 未读取(' + (config.classify_key_file || '') + '),按纯规则判定');
      }
      cl = await classifier(content, config.projects, key, config);
      log.log('CLASSIFY: intent=' + cl.intent + ' risk=' + cl.risk);
    }

    const d = gate.decide(content, cl, config);
    log.log('MSG seq=' + m.seq + ' action=' + d.action + ' (' + d.reason + ')');

    if (d.action === 'confirm') {
      const entry = gate.buildPending(m.seq, content, d.summary, config.confirm_ttl_sec, nowMs());
      entry.userid = userid;
      state.savePending(entry);
      const ttlMin = Math.round((config.confirm_ttl_sec || 300) / 60);
      await sendReply(userid, '[高风险操作] 将执行: ' + (entry.summary || content) + '\n回复 确认' + entry.code + ' 执行(' + ttlMin + ' 分钟内有效)。');
      addHistory({ seq: m.seq, userid: userid, content: content, summary: entry.summary, result: 'confirm-requested' });
      log.log('CONFIRM-REQUEST: seq=' + m.seq + ' code=' + entry.code);
      return;
    }
    // dispatch(低风险/白名单/普通开放式指令)
    const riskLabel = (cl.risk || 'low');
    await dispatchAndReply(content, userid, d.summary, false, m.seq, riskLabel);
  }

  // 一轮扫描
  async function tick() {
    try {
      const removed = state.cleanupExpiredPending(nowMs());
      if (removed > 0) { log.log('PENDING-EXPIRED-CLEANUP: ' + removed); }
      const cursor = state.getCursor();
      const r = await wecomClient.getMessages(config.wecom_base_url, config.consumer, cursor);
      let maxSeq = cursor;
      for (const m of r.items) {
        if (Number(m.seq) > maxSeq) { maxSeq = Number(m.seq); }
        try { await processMessage(m); }
        catch (e) { log.log('MSG-ERROR seq=' + m.seq + ': ' + errMsg(e)); }
      }
      if (maxSeq > cursor) {
        // 双保险:先提交 wecom-connector 服务端游标(at-least-once 权威),再本地持久化(重启不丢)
        try { await wecomClient.setCursor(config.wecom_base_url, config.consumer, maxSeq); }
        catch (e) { log.log('CURSOR-COMMIT-FAIL: ' + errMsg(e)); }
        state.saveCursor(maxSeq);
        log.log('CURSOR: ' + cursor + ' -> ' + maxSeq + ' (items ' + r.items.length + ')');
      }
      return { items: r.items.length, maxSeq };
    } catch (e) {
      log.log('TICK-ERROR: ' + errMsg(e));
      return { items: 0, maxSeq: state.getCursor() };
    }
  }

  function start() {
    if (running) { return; }
    running = true;
    const removed = state.cleanupExpiredPending(nowMs());
    if (removed > 0) { log.log('STARTUP-PENDING-CLEANUP: ' + removed); }
    log.log('=== control-agent started (owner=' + (config.owner_userid || '(自动识别)') + ', executor=' + config.executor.type + ', llm_classify=' + config.use_llm_classify + ') ===');
    tick();
    timer = setInterval(tick, config.poll_interval_ms);
  }

  function stop() {
    running = false;
    if (timer) { clearInterval(timer); timer = null; }
    log.log('=== control-agent stopped ===');
  }

  function status() {
    return {
      running,
      owner_configured: !!config.owner_userid,
      cursor: state.getCursor(),
      pending: state.listPending().length,
      executor: executor.status()
    };
  }

  return { tick, start, stop, status, processMessage, handleConfirm };
}

// 真实入口
function main() {
  const root = __dirname;
  const cfgFile = process.env.CONTROL_AGENT_CONFIG || path.join(root, 'config.json');
  const config = loadConfig(cfgFile);
  const log = createLogger(config.log_file, config.log_max_bytes, config.log_keep);
  const state = new StateStore(config);
  const executor = createExecutor(config, log);
  const bridge = createBridge({ config, log, state, wecomClient: wecom, executor });
  if (!config.owner_userid) {
    log.log('INFO: owner_userid 未配置,启用自动识别——向企微机器人发送任意消息即锁定 owner 并写入 config.json');
  }
  bridge.start();

  const shutdown = () => {
    bridge.stop();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

if (require.main === module) { main(); }

module.exports = { createBridge };
