// tests/executor.test.js - 可插拔执行层(模板构建/占位符/工作目录解析)
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { buildCommandLine, buildPrompt, resolveWorkdir, defaultCommand, quoteArg } = require('../lib/executor.js');

test('quoteArg:双引号包裹,内部双引号→单引号(防 cmd 引号逃逸),换行→空格', () => {
  assert.strictEqual(quoteArg('hi'), '"hi"');
  assert.strictEqual(quoteArg('说 "你好"'), '"说 \'你好\'"');
  assert.strictEqual(quoteArg('a"b"c'), '"a\'b\'c"');
  assert.strictEqual(quoteArg('多行\n文本'), '"多行 文本"');
});

test('buildCommandLine:{prompt} 占位符替换并加引号转义', () => {
  const cmd = buildCommandLine('dsh --profile headless {prompt}', '把砍价话术改得更友善', '');
  assert.strictEqual(cmd, 'dsh --profile headless "把砍价话术改得更友善"');
  const cmd2 = buildCommandLine('echo {workdir} {prompt}', 'x', 'C:\\work');
  assert.strictEqual(cmd2, 'echo "C:\\work" "x"');
});

test('defaultCommand:各 type 兜底模板', () => {
  assert.match(defaultCommand('dsh'), /^dsh --profile headless/);
  assert.match(defaultCommand('opencode'), /^opencode\.cmd run/);
  assert.match(defaultCommand('claude'), /^claude -p/);
  assert.strictEqual(defaultCommand('command'), '{prompt}');
});

test('buildPrompt:包含角色/工作目录/技能/白名单/边界', () => {
  const cfg = {
    skills_dir: 'C:\\skills',
    whitelist_files: ['reply_rules.json', 'config.json']
  };
  const p = buildPrompt('任务原文', 'C:\\proj', cfg);
  assert.ok(p.includes('企微远程控制的执行 agent'));
  assert.ok(p.includes('C:\\proj'));
  assert.ok(p.includes('C:\\skills'));
  assert.ok(p.includes('reply_rules.json / config.json'));
  assert.ok(p.includes('不输出任何凭据'));
  assert.ok(p.includes('任务原文'));
});

test('resolveWorkdir:指令提及项目名 → 该项目路径;否则 executor.workdir', () => {
  const cfg = {
    projects: { 'alibaba-auto-reply': 'C:\\a', 'wecom-connector': 'C:\\w' },
    executor: { workdir: 'C:\\default' }
  };
  assert.strictEqual(resolveWorkdir('帮我在 alibaba-auto-reply 里查发送失败记录', cfg), 'C:\\a');
  assert.strictEqual(resolveWorkdir('wecom-connector 的 /send 端点', cfg), 'C:\\w');
  assert.strictEqual(resolveWorkdir('随便一个任务', cfg), 'C:\\default');
});
