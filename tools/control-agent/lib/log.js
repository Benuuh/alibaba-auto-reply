// lib/log.js - 日志:yyyy-MM-dd HH:mm:ss | msg,超过 maxBytes 轮转(留 keep 份)
'use strict';

const fs = require('node:fs');
const path = require('node:path');

function createLogger(file, maxBytes, keep) {
  const ensureDir = () => {
    const dir = path.dirname(file);
    if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
  };
  const rotate = () => {
    ensureDir();
    try {
      if (fs.existsSync(file) && fs.statSync(file).size > maxBytes) {
        for (let i = keep - 1; i >= 1; i--) {
          const from = file + '.' + i;
          const to = file + '.' + (i + 1);
          if (fs.existsSync(from)) { fs.renameSync(from, to); }
        }
        if (fs.existsSync(file)) { fs.renameSync(file, file + '.1'); }
      }
    } catch (e) { /* 轮转失败不影响运行 */ }
  };
  const ts = () => {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  };
  return {
    log(msg) {
      const line = ts() + ' | ' + msg;
      try {
        rotate();
        ensureDir();
        fs.appendFileSync(file, line + '\n', 'utf8');
      } catch (e) { /* 写日志失败静默 */ }
      return line;
    }
  };
}

module.exports = { createLogger };
