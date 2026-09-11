#!/usr/bin/env node
// read.js - CLI: node read.js <filePath> [--max-chars 6000] [--render-max-pages 2]
// stdout JSON: {"ok":true,"kind":"pdf-text|pdf-scan|xlsx|csv|docx","text":"...","images":["data:image/png;base64,..."],"meta":{...}}
'use strict';
const { extractFile } = require('./lib/extract');

function parseArgs(argv) {
  const out = { filePath: '', maxChars: 6000, renderMaxPages: 2 };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--max-chars') { out.maxChars = parseInt(argv[++i], 10) || 6000; }
    else if (a === '--render-max-pages') { out.renderMaxPages = parseInt(argv[++i], 10) || 2; }
    else rest.push(a);
  }
  out.filePath = rest[0] || '';
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.filePath) {
    process.stdout.write(JSON.stringify({ ok: false, error: 'usage: node read.js <filePath> [--max-chars N] [--render-max-pages N]' }));
    process.exit(2);
  }
  const res = await extractFile(args.filePath, { maxChars: args.maxChars, renderMaxPages: args.renderMaxPages });
  process.stdout.write(JSON.stringify(res));
  process.exit(res.ok ? 0 : 1);
}

main().catch((e) => {
  process.stdout.write(JSON.stringify({ ok: false, error: 'parse-failed', message: String(e && e.message ? e.message : e) }));
  process.exit(1);
});
