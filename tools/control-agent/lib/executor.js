// lib/executor.js - 可插拔外部执行 agent(adapter 模式,config.executor 决定具体 agent)
// type: dsh(默认) | opencode | claude | command;命令模板支持 {prompt} 占位符(执行时替换)
// 桥不感知具体 agent:换 executor 只需改 config
'use strict';

const { spawn } = require('node:child_process');

class ExecutorError extends Error {
  constructor(message, code) {
    super(message);
    this.code = code || 'EXECUTOR_ERROR';
  }
}

// 参数 shell 安全转义(cmd.exe 语义):整体双引号包裹;内部双引号→单引号(防引号逃逸);
// 换行→空格(命令行不允许换行);cmd 中双引号内的 & | < > ^ 为字面量,无需处理
function quoteArg(text) {
  const safe = String(text).replace(/"/g, "'").replace(/[\r\n]+/g, ' ');
  return '"' + safe + '"';
}

// 命令模板替换:{prompt} → shell 引号包裹并转义的指令;{workdir} → 同(也经 cwd 传入)
function buildCommandLine(template, prompt, workdir) {
  let cmd = String(template || '').replace(/\{prompt\}/g, quoteArg(prompt));
  if (workdir) { cmd = cmd.replace(/\{workdir\}/g, quoteArg(workdir)); }
  return cmd;
}

// 默认命令模板按 type 兜底(未配置 command 时)。注意:{prompt}/{workdir} 占位符不要自行加引号,
// executor 会统一做 shell 引号包裹与转义
function defaultCommand(type) {
  switch (type) {
    case 'opencode': return 'opencode.cmd run {prompt} --format text';
    case 'claude': return 'claude -p {prompt}';
    case 'dsh': return 'dsh --profile headless {prompt}';
    default: return '{prompt}';
  }
}

// 派发 prompt 模板(桥不解释指令,只包边界;工作目录/技能位置随配置注入)
function buildPrompt(instruction, workdir, config) {
  const lines = [];
  lines.push('你是企微远程控制的执行 agent(由 control-agent 桥派发)。');
  if (workdir) { lines.push('工作目录: ' + workdir); }
  lines.push('可用技能(如需要请先读取其 SKILL.md 并按其流程执行): ' + config.skills_dir);
  lines.push('  (implement / tdd / code-review / diagnosing-bugs)');
  lines.push('');
  lines.push('任务(用户指令原文):');
  lines.push(String(instruction || '').substring(0, 2000));
  lines.push('');
  lines.push('要求:');
  lines.push('- 只做指令要求之事,不扩大范围;');
  lines.push('- 完成后输出简洁中文总结(≤200 字),列出改动文件与 diff 摘要(如适用);');
  lines.push('- 白名单文件(' + (config.whitelist_files || []).join(' / ') + ')允许直接修改并展示 diff 摘要;');
  lines.push('- 不输出任何凭据/密钥;不删除关键文件;不执行系统级高危操作(注册表/服务安装/磁盘格式化)。');
  return lines.join('\n');
}

// 工作目录解析:指令提及项目名(projects.name)→ 该项目路径;否则 executor.workdir
function resolveWorkdir(instruction, config) {
  const text = String(instruction || '');
  const projects = config.projects || {};
  for (const name of Object.keys(projects)) {
    if (text.includes(name)) { return projects[name]; }
  }
  return config.executor.workdir || '';
}

function createExecutor(config, log) {
  const timeoutSec = Number(config.executor.timeout_sec) || 300;

  async function dispatch(instruction, workdir) {
    const template = config.executor.command || defaultCommand(config.executor.type);
    const promptText = buildPrompt(instruction, workdir, config);
    const cmdLine = buildCommandLine(template, promptText, workdir);
    log.log('EXECUTOR: type=' + config.executor.type + ' cmd=' + cmdLine.substring(0, 120) + '...');
    const result = await run(cmdLine, workdir, timeoutSec * 1000);
    if (result.timedOut) {
      throw new ExecutorError('执行超时(' + timeoutSec + '秒),已终止', 'EXECUTOR_TIMEOUT');
    }
    if (result.exitCode !== 0) {
      const hint = executorHint(config.executor.type);
      throw new ExecutorError('执行失败(exit=' + result.exitCode + ')' + (result.errText ? '\n' + result.errText.substring(0, 500) : '') + '\n' + hint, 'EXECUTOR_FAIL');
    }
    const text = result.outText.trim();
    if (!text) { throw new ExecutorError('执行完成但无输出(exit=0)', 'EXECUTOR_EMPTY'); }
    return { text, exitCode: result.exitCode };
  }

  function status() {
    return { type: config.executor.type, command: (config.executor.command || defaultCommand(config.executor.type)), timeout_sec: timeoutSec };
  }

  return { dispatch, status, buildPrompt, resolveWorkdir: (i) => resolveWorkdir(i, config) };
}

// executor 不可用提示(不崩溃,回发配置方式)
function executorHint(type) {
  switch (type) {
    case 'dsh':
      return 'dsh 不可用: 请先 npm.cmd install -g @deepseek-ai/dsh,并在 dsh web 的 Models 页面配置 API key(或导出 DEEPSEEK_API_KEY)。';
    case 'opencode':
      return 'opencode 不可用: 请先 npm.cmd install -g opencode-ai(win 下需 opencode.cmd 在 PATH)。';
    case 'claude':
      return 'claude 不可用: 请先安装 Claude CLI 并登录。';
    default:
      return 'executor 命令不可用: 请在 config.json 的 executor.command 配置正确命令(支持 {prompt} 占位符)。';
  }
}

function run(cmdLine, workdir, timeoutMs) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmdLine, { shell: true, cwd: workdir || undefined, windowsHide: true });
    let out = '';
    let err = '';
    let killed = false;
    const timer = setTimeout(() => {
      killed = true;
      try { spawn('taskkill.exe', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true }); } catch (e) {}
      try { child.kill(); } catch (e) {}
    }, timeoutMs || 300000);
    child.stdout.on('data', (c) => { out += c; if (out.length > 200000) { out = out.substring(0, 200000); } });
    child.stderr.on('data', (c) => { err += c; if (err.length > 100000) { err = err.substring(0, 100000); } });
    child.on('error', (e) => { clearTimeout(timer); reject(e); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (killed) { resolve({ exitCode: -1, outText: out, errText: err, timedOut: true }); return; }
      resolve({ exitCode: code, outText: out, errText: err, timedOut: false });
    });
  });
}

module.exports = { createExecutor, buildCommandLine, buildPrompt, resolveWorkdir, ExecutorError, defaultCommand, quoteArg };
