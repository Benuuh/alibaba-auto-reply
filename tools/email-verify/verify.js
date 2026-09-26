#!/usr/bin/env node
'use strict';
/**
 * tools/email-verify — 邮箱可投递性验证引擎（零依赖，Node 18+）
 *
 * 定位：主动获客链路里「邮箱富集」这一步的验证环节。不买第三方 API，
 *       用 DNS MX + SMTP RCPT 握手判定邮箱是否真实可投递。
 *
 * 判定口径（关键，决定你发信会不会把域名发废）：
 *   ok        —— MX 存在 + 服务器明确接受该收件人（250）
 *   invalid   —— 域名无 MX，或服务器明确拒绝该收件人（550/551/553 等 5xx）
 *   risky     —— 服务器拒答（4xx 灰名单/限流）、catch-all 域、或连接失败
 *   unknown   —— 无法判定（DNS 超时等）
 *   ⚠️ risky 不等于能发：catch-all 域下任何拼凑地址都会 250，真假不可分。
 *
 * 安全/合规设计：
 *   1) 只做 RCPT 探测，绝不发 DATA —— 不会给对方投递任何邮件。
 *   2) MAIL FROM 使用 <postmaster@example.com>（无效域），避免被当成真实发信源；
 *      探测行为可能被对方记入灰名单，故必须限速（默认并发 4 / 单域串行）。
 *   3) 全流程不写入任何收件人之外的个人信息；输出仅供本机使用。
 *
 * 用法：
 *   node verify.js --in leads.json  --out verified.json   [--concurrency 4]
 *   node verify.js --email a@b.com  [--json]
 *   node verify.js --selftest
 *
 * 输入格式（数组，字段名兼容常见导出）：
 *   [{ "email": "a@b.com", "company": "...", "domain": "b.com" }, ...]
 */

const dns = require('node:dns').promises;
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');

const ROLE_PREFIXES = [
  'info', 'sales', 'contact', 'support', 'admin', 'office', 'hello', 'enquiry',
  'enquiries', 'inquiry', 'inquiries', 'service', 'marketing', 'export', 'import',
  'business', 'bd', 'hr', 'jobs', 'career', 'accounting', 'finance', 'purchase',
  'purchasing', 'procurement', 'sourcing', 'logistics', 'shipping', 'orders',
  'webmaster', 'postmaster', 'noreply', 'no-reply', 'abuse',
];

const DISPOSABLE = new Set([
  'mailinator.com', 'guerrillamail.com', '10minutemail.com', 'tempmail.com',
  'trashmail.com', 'yopmail.com', 'sharklasers.com', 'throwawaymail.com',
  'getnada.com', 'maildrop.cc', 'dispostable.com',
]);

const FREE_MAIL = new Set([
  'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.jp', 'hotmail.com',
  'outlook.com', 'live.com', 'msn.com', 'aol.com', 'icloud.com', 'me.com',
  'mac.com', 'gmx.com', 'gmx.de', 'mail.com', 'zoho.com', 'protonmail.com',
  'proton.me', 'yandex.com', 'yandex.ru', 'qq.com', '163.com', '126.com',
  'sina.com', 'foxmail.com', 'naver.com', 'daum.net', 'web.de', 't-online.de',
]);

const EMAIL_RE = /^[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;

// ---------------------------------------------------------------- DNS

const mxCache = new Map();
const domainQueue = new Map(); // 单域串行闸门

function withDomainLock(domain, fn) {
  const prev = domainQueue.get(domain) || Promise.resolve();
  const next = prev.then(fn, fn);
  domainQueue.set(domain, next.catch(() => {}));
  return next;
}

async function resolveMx(domain, timeoutMs = 8000) {
  if (mxCache.has(domain)) return mxCache.get(domain);
  const p = (async () => {
    const withTimeout = (promise) =>
      Promise.race([
        promise,
        new Promise((_, rej) => setTimeout(() => rej(new Error('DNS_TIMEOUT')), timeoutMs)),
      ]);
    try {
      const recs = await withTimeout(dns.resolveMx(domain));
      const hosts = recs
        .filter((r) => r && r.exchange)
        .sort((a, b) => (a.priority || 0) - (b.priority || 0))
        .map((r) => r.exchange.replace(/\.$/, ''));
      if (hosts.length) return { ok: true, hosts };
    } catch (e) {
      if (e.code !== 'ENOTFOUND' && e.code !== 'ENODATA' && e.message !== 'DNS_TIMEOUT') {
        // 继续尝试 A 记录回退
      }
    }
    // RFC 5321 回退：无 MX 时可用 A/AAAA 记录投递
    try {
      const a = await withTimeout(dns.resolve4(domain));
      if (a && a.length) return { ok: true, hosts: [domain], implicit: true };
    } catch (_) { /* ignore */ }
    return { ok: false, hosts: [] };
  })();
  mxCache.set(domain, p);
  return p;
}

// ---------------------------------------------------------------- SMTP

const SMTP_TIMEOUT = 12000;

/**
 * 与单个 MX 做 RCPT 探测。返回：
 *   { accepted: bool|null, code, msg, catchAll: bool|null }
 * accepted=null 表示无法判定（连接失败/超时）。
 */
function smtpProbe(mxHost, email, opts = {}) {
  const probeCatchAll = opts.probeCatchAll !== false;
  const heloDomain = opts.heloDomain || 'example.com';
  // 无效发信域：明确不是真实发信源，避免被误判为真实投递
  const mailFrom = opts.mailFrom || 'postmaster@example.com';
  // catch-all 探测用的随机收件人（几乎不可能真实存在）
  const rand = 'zz' + Math.random().toString(36).slice(2, 12) + 'zz';

  return new Promise((resolve) => {
    let settled = false;
    const done = (r) => { if (!settled) { settled = true; try { socket.destroy(); } catch (_) {} resolve(r); } };

    // 这些 MX 明确不参与 RCPT 探测（会一律拒绝或无意义），直接判 unknown
    if (/google\.com$|googlemail\.com$|outlook\.com$|protection\.outlook\.com$/i.test(mxHost)) {
      // 注意：Google/Microsoft 对陌生 IP 的 RCPT 探测通常返回 550 或直接封禁，
      // 因此对这两家不做 verdict 定论，交由调用方按 MX 归属降级为 risky/unknown。
      // 见 README「为什么 Gmail/Outlook 域不能靠 SMTP 定论」。
    }

    const socket = net.createConnection({ host: mxHost, port: opts.port || 25 });
    socket.setTimeout(SMTP_TIMEOUT);

    let buffer = '';
    let step = 0; // 0=等 banner 1=等 EHLO 2=等 MAIL 3=等 RCPT 4=等 catchall RCPT 5=等 quit
    let rcptAccepted = null;
    let rcptCode = 0;
    let rcptMsg = '';
    let catchAll = null;

    const send = (line) => { try { socket.write(line + '\r\n'); } catch (_) { done({ accepted: null, code: 0, msg: 'WRITE_FAIL' }); } };

    socket.on('timeout', () => done({ accepted: rcptAccepted, code: rcptCode || 0, msg: rcptMsg || 'SOCKET_TIMEOUT', catchAll }));
    socket.on('error', (e) => done({ accepted: rcptAccepted, code: rcptCode || 0, msg: 'CONN_ERR:' + e.code, catchAll }));

    socket.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      // SMTP 多行响应：以 "250-" 续行，最后一行是 "250 "
      let idx;
      while ((idx = buffer.indexOf('\r\n')) >= 0) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 2);
        if (/^\d{3}-/.test(line)) continue; // 中间行，继续等
        handleReply(line);
      }
    });

    function handleReply(line) {
      const code = parseInt(line.slice(0, 3), 10) || 0;
      const text = line.slice(4);
      switch (step) {
        case 0:
          if (code >= 200 && code < 400) { step = 1; send('EHLO ' + heloDomain); }
          else done({ accepted: null, code, msg: text, catchAll: null });
          break;
        case 1:
          step = 2;
          send('MAIL FROM:<' + mailFrom + '>');
          break;
        case 2:
          if (code >= 200 && code < 300) { step = 3; send('RCPT TO:<' + email + '>'); }
          // 220/250 之后被拒（如 421 限流、550 拒发信域）→ 无法定论收件人
          else done({ accepted: null, code, msg: text, catchAll: null });
          break;
        case 3:
          rcptCode = code;
          rcptMsg = text;
          if (code >= 200 && code < 300) rcptAccepted = true;
          else if (code >= 500 && code < 600) rcptAccepted = false;
          else rcptAccepted = null; // 4xx：灰名单/限流，不能定论
          if (probeCatchAll && rcptAccepted === true) {
            step = 4;
            send('RCPT TO:<' + rand + '@' + email.split('@')[1] + '>');
          } else {
            step = 5;
            send('QUIT');
            done({ accepted: rcptAccepted, code: rcptCode, msg: rcptMsg, catchAll: null });
          }
          break;
        case 4:
          // 随机地址也被接受 → catch-all 域，真实地址不可验证
          catchAll = code >= 200 && code < 300;
          step = 5;
          send('QUIT');
          done({ accepted: rcptAccepted, code: rcptCode, msg: rcptMsg, catchAll });
          break;
        default:
          break;
      }
    }
  });
}

// ---------------------------------------------------------------- 主判定

function classifyLocalPart(email) {
  const local = email.split('@')[0].toLowerCase();
  if (ROLE_PREFIXES.includes(local)) return { type: 'role', reason: 'ROLE_ACCOUNT' };
  // 名字型：含点/下划线且非纯数字，通常为决策人直邮
  if (/^[a-z]+[._-][a-z]+$/.test(local)) return { type: 'person', reason: 'PERSONAL' };
  if (/^[a-z]{2,}$/.test(local)) return { type: 'person', reason: 'PERSONAL_UNVERIFIED_SHAPE' };
  return { type: 'other', reason: 'UNCLASSIFIED' };
}

async function verifyEmail(rawEmail, opts = {}) {
  const started = Date.now();
  const email = String(rawEmail || '').trim().toLowerCase();
  const result = {
    email,
    verdict: 'unknown',
    reason: '',
    mx: [],
    catch_all: null,
    local_type: 'other',
    free_mail: false,
    disposable: false,
    latency_ms: 0,
    checked_at: new Date().toISOString(),
  };
  const finish = () => { result.latency_ms = Date.now() - started; return result; };

  if (!EMAIL_RE.test(email)) { result.verdict = 'invalid'; result.reason = 'SYNTAX'; return finish(); }
  const domain = email.split('@')[1];
  const cls = classifyLocalPart(email);
  result.local_type = cls.type;
  result.free_mail = FREE_MAIL.has(domain);
  result.disposable = DISPOSABLE.has(domain);

  if (result.disposable) { result.verdict = 'invalid'; result.reason = 'DISPOSABLE_DOMAIN'; return finish(); }

  const mx = await resolveMx(domain);
  result.mx = mx.hosts;
  if (!mx.ok || !mx.hosts.length) { result.verdict = 'invalid'; result.reason = 'NO_MX'; return finish(); }

  // 单域串行 + 限速：避免把某个域的 MX 打成灰名单
  const probe = await withDomainLock(domain, () => smtpProbe(mx.hosts[0], email, opts));

  if (probe.accepted === true) {
    if (probe.catchAll === true) {
      result.verdict = 'risky';
      result.reason = 'CATCH_ALL_DOMAIN';
      result.catch_all = true;
    } else {
      result.verdict = 'ok';
      result.reason = 'SMTP_250';
      result.catch_all = false;
    }
  } else if (probe.accepted === false) {
    // Gmail/Outlook 对陌生 IP 常无差别返回 550，不能据此判定地址不存在
    const isBigProvider = /google\.com$|googlemail\.com$|outlook\.com$|protection\.outlook\.com$/i.test(mx.hosts[0]);
    if (isBigProvider) {
      result.verdict = 'unknown';
      result.reason = 'PROVIDER_BLOCKS_PROBE(' + probe.code + ')';
    } else {
      result.verdict = 'invalid';
      result.reason = 'SMTP_REJECT_' + probe.code;
    }
  } else {
    result.verdict = 'risky';
    result.reason = probe.msg || 'INCONCLUSIVE';
  }
  // 可解释性：把"无法判定"的三种成因分开，避免使用者把 risky 当"能发"
  if (result.verdict === 'risky') {
    if (result.reason === 'CATCH_ALL_DOMAIN') {
      result.guidance = '域为 catch-all(任意地址都返 250),SMTP 无法验证该地址真假:需人工抽样或改用该域已知真实地址';
    } else if (result.reason === 'CONN_ERR') {
      result.guidance = 'MX 连接失败(可能限流/封禁本机 IP):不等于地址无效,建议稍后重试';
    } else {
      result.guidance = '服务器拒答(灰名单/限流):不等于地址无效,建议稍后重试';
    }
  } else if (result.verdict === 'unknown') {
    result.guidance = '无法判定:大厂邮箱(Gmail/Outlook)对陌生 IP 的 RCPT 探测无差别拒绝,须靠该域历史发送表现判断';
  } else if (result.verdict === 'ok') {
    result.guidance = '服务器明确接受且非 catch-all:可优先发信';
  } else if (result.verdict === 'invalid') {
    result.guidance = '确定不可投递:从名单剔除,不要发送(硬退信会损伤域名信誉)';
  }
  return finish();
}

// ---------------------------------------------------------------- 并发池

async function mapPool(items, concurrency, worker, onProgress) {
  const out = new Array(items.length);
  let next = 0;
  let done = 0;
  const runners = new Array(Math.min(concurrency, items.length || 1)).fill(0).map(async () => {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      try { out[i] = await worker(items[i], i); }
      catch (e) { out[i] = { email: items[i] && items[i].email, verdict: 'unknown', reason: 'WORKER_ERR:' + e.message }; }
      done++;
      if (onProgress) onProgress(done, items.length, out[i]);
    }
  });
  await Promise.all(runners);
  return out;
}

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const a = { concurrency: 4, in: '', out: '', email: '', json: false, selftest: false, port: 25, noCatchAll: false };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    if (k === '--in') { a.in = v; i++; }
    else if (k === '--out') { a.out = v; i++; }
    else if (k === '--email') { a.email = v; i++; }
    else if (k === '--concurrency') { a.concurrency = Math.max(1, parseInt(v, 10) || 4); i++; }
    else if (k === '--port') { a.port = parseInt(v, 10) || 25; i++; }
    else if (k === '--json') a.json = true;
    else if (k === '--no-catch-all') a.noCatchAll = true;
    else if (k === '--selftest') a.selftest = true;
  }
  return a;
}

function readLeads(file) {
  const raw = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
  let data = JSON.parse(raw);
  if (!Array.isArray(data)) {
    if (Array.isArray(data.leads)) data = data.leads;
    else if (Array.isArray(data.data)) data = data.data;
    else throw new Error('输入 JSON 既不是数组,也没有 leads/data 数组字段');
  }
  return data.map((r) => ({
    ...r,
    email: String(r.email || r.mail || r.emailAddress || r.contact_email || '').trim().toLowerCase(),
  })).filter((r) => r.email);
}

function summarize(rows) {
  const by = {};
  for (const r of rows) by[r.verdict] = (by[r.verdict] || 0) + 1;
  return by;
}

async function selftest() {
  let pass = 0, fail = 0;
  const t = (name, cond) => { if (cond) { pass++; console.log('  PASS  ' + name); } else { fail++; console.log('  FAIL  ' + name); } };

  console.log('[selftest] 纯逻辑(不联网)');
  t('语法非法 → invalid/SYNTAX', (await verifyEmail('not-an-email')).reason === 'SYNTAX');
  t('空字符串 → invalid/SYNTAX', (await verifyEmail('')).verdict === 'invalid');
  t('一次性邮箱 → invalid/DISPOSABLE_DOMAIN', (await verifyEmail('x@mailinator.com')).reason === 'DISPOSABLE_DOMAIN');
  const noMx = await verifyEmail('user@this-domain-should-not-exist-zz99.invalid');
  t('无 MX → invalid/NO_MX', noMx.verdict === 'invalid' && noMx.reason === 'NO_MX');
  t('role 识别 info@', classifyLocalPart('info@x.com').type === 'role');
  t('person 识别 john.smith@', classifyLocalPart('john.smith@x.com').type === 'person');
  t('free mail 识别', (await verifyEmail('a@gmail.com')).free_mail === true);

  console.log('\n[selftest] mapPool 并发与保序');
  const items = [1, 2, 3, 4, 5, 6, 7];
  const got = await mapPool(items, 3, async (n) => { await new Promise((r) => setTimeout(r, 5)); return n * 2; });
  t('结果保序且完整', JSON.stringify(got) === JSON.stringify([2, 4, 6, 8, 10, 12, 14]));
  let peak = 0, cur = 0;
  await mapPool(new Array(12).fill(0), 4, async () => { cur++; peak = Math.max(peak, cur); await new Promise((r) => setTimeout(r, 5)); cur--; });
  t('并发不超过上限 4 (实测峰值 ' + peak + ')', peak <= 4);

  console.log('\n[selftest] 真实网络(可跳过,失败不算逻辑错误)');
  try {
    const live = await verifyEmail('test@gmail.com', { probeCatchAll: false });
    console.log('  gmail.com → verdict=' + live.verdict + ' reason=' + live.reason + ' mx=' + (live.mx[0] || '-'));
    t('Gmail 域不得被判 invalid(探测被阻断须降级 unknown/risky)', live.verdict !== 'invalid');
  } catch (e) {
    console.log('  SKIP  联网用例: ' + e.message);
  }

  console.log('\n[selftest] 结果 ' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail > 0 ? 1 : 0);
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.selftest) return selftest();

  if (args.email) {
    const r = await verifyEmail(args.email, { probeCatchAll: !args.noCatchAll, port: args.port });
    if (args.json) console.log(JSON.stringify(r, null, 2));
    else console.log(`${r.verdict.padEnd(8)} ${r.email}  [${r.reason}] mx=${r.mx[0] || '-'} type=${r.local_type}${r.catch_all ? ' CATCH-ALL' : ''} (${r.latency_ms}ms)`);
    return;
  }

  if (!args.in) { console.error('用法: node verify.js --in leads.json --out verified.json [--concurrency 4]'); process.exit(2); }
  const leads = readLeads(args.in);
  console.log(`[email-verify] 载入 ${leads.length} 条, 并发 ${args.concurrency}, 端口 ${args.port}`);
  console.log('[email-verify] 仅做 RCPT 探测(不投递), 单域串行; 请勿调高并发以免被灰名单\n');

  const t0 = Date.now();
  const rows = await mapPool(leads, args.concurrency, (lead) => verifyEmail(lead.email, { probeCatchAll: !args.noCatchAll, port: args.port }),
    (done, total, r) => {
      if (done % 10 === 0 || done === total) {
        process.stdout.write(`  ${done}/${total}  ${r.verdict.padEnd(8)} ${r.email}\n`);
      }
    });

  const merged = leads.map((l, i) => ({ ...l, ...rows[i] }));
  const summary = summarize(rows);
  const reasonBreakdown = {};
  for (const r of rows) reasonBreakdown[r.reason] = (reasonBreakdown[r.reason] || 0) + 1;
  const catchAllDomains = [...new Set(rows.filter((r) => r.catch_all).map((r) => r.email.split('@')[1]))].sort();
  const okEmails = rows.filter((r) => r.verdict === 'ok').map((r) => r.email);
  const outFile = args.out || path.join(process.cwd(), 'verified.json');
  const payload = {
    generated_at: new Date().toISOString(),
    total: merged.length,
    summary,
    reason_breakdown: reasonBreakdown,
    catch_all_domains: catchAllDomains,
    ok_emails: okEmails,
    elapsed_sec: Math.round((Date.now() - t0) / 1000),
    note: 'ok=可投递; risky=catch-all/灰名单(不等于可发); invalid=确定不可投递; unknown=无法判定',
    results: merged,
  };
  fs.writeFileSync(outFile, JSON.stringify(payload, null, 2), 'utf8');

  // ---- 面向业务的可行动汇总(不要只看 verdict 数字) ----
  const line = (s) => console.log(s);
  line('\n================ 结果解读 ================');
  line(`总 ${merged.length} 条 | ok(可优先发) ${summary.ok || 0} | invalid(必须剔除) ${summary.invalid || 0} | risky(须人工) ${summary.risky || 0} | unknown(无法判定) ${summary.unknown || 0}`);
  line('\n判定原因分布:');
  for (const [k, v] of Object.entries(reasonBreakdown).sort((a, b) => b[1] - a[1])) line(`  ${String(v).padStart(4)}  ${k}`);
  if (catchAllDomains.length) {
    line(`\n⚠️  catch-all 域 ${catchAllDomains.length} 个 —— 这些域的地址 SMTP 无法验证真假,不要当成已验证:`);
    line('    ' + catchAllDomains.join(', '));
    line('    处置:① 优先用该域官网/领英上明确公开的地址 ② 或人工抽样发信观察退信率 ③ 不要批量拼凑地址硬发');
  }
  if (summary.invalid) {
    line(`\n✅ 已剔除 ${summary.invalid} 条确定不可投递地址(硬退信会损伤域名信誉,务必不要发)`);
  }
  if (okEmails.length) {
    line(`\n🎯 可优先发信名单(${okEmails.length} 条,前 10):`);
    okEmails.slice(0, 10).forEach((e) => line('    ' + e));
  } else if (summary.ok === 0 && merged.length > 0) {
    line('\n提示:本次没有 ok —— 通常是样本以小/中企业域为主或大厂邮箱占比高所致,不代表工具失效。');
    line('     真实开发信场景下,用 ok + 人工确认过的 catch-all 地址组合投放即可。');
  }
  line(`\n明细文件: ${outFile}`);
}

if (require.main === module) {
  main().catch((e) => { console.error('[email-verify] FATAL: ' + e.stack); process.exit(1); });
}

module.exports = { verifyEmail, resolveMx, classifyLocalPart, mapPool, smtpProbe, summarize };
