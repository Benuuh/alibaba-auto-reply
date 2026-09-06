// lib/state.js - 状态存储:cursor/pending 原子读写(重启不丢),history 追加式滚动
'use strict';

const fs = require('node:fs');
const path = require('node:path');

class StateStore {
  constructor(config) {
    this.config = config;
    this.cursor = this._readJson(config.cursor_file, { last_seq: 0 });
    this.pending = this._readJson(config.pending_file, {});
  }

  _readJson(file, fallback) {
    try {
      if (fs.existsSync(file)) {
        const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (raw && typeof raw === 'object' && !Array.isArray(raw)) { return raw; }
      }
    } catch (e) { /* 损坏回退 */ }
    return fallback;
  }

  _writeJson(file, obj) {
    try {
      const dir = path.dirname(file);
      if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
      const tmp = file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
      fs.renameSync(tmp, file);
      return true;
    } catch (e) { return false; }
  }

  getCursor() {
    const v = Number(this.cursor.last_seq);
    return Number.isInteger(v) && v >= 0 ? v : 0;
  }

  saveCursor(seq) {
    const n = Number(seq);
    if (!Number.isInteger(n) || n < 0) { return false; }
    this.cursor.last_seq = n;
    return this._writeJson(this.config.cursor_file, this.cursor);
  }

  getPending(seq) {
    const key = String(seq);
    return this.pending[key] || null;
  }

  listPending() {
    return Object.keys(this.pending).map((k) => this.pending[k]);
  }

  savePending(entry) {
    this.pending[String(entry.seq)] = entry;
    return this._writeJson(this.config.pending_file, this.pending);
  }

  removePending(seq) {
    const key = String(seq);
    if (!this.pending[key]) { return false; }
    delete this.pending[key];
    return this._writeJson(this.config.pending_file, this.pending);
  }

  cleanupExpiredPending(nowMs) {
    let removed = 0;
    for (const k of Object.keys(this.pending)) {
      const p = this.pending[k];
      if (!p.expire_at || Number(p.expire_at) <= nowMs) {
        delete this.pending[k];
        removed++;
      }
    }
    if (removed > 0) { this._writeJson(this.config.pending_file, this.pending); }
    return removed;
  }

  // history.jsonl 追加;超过 history_max 行滚动保留最后 history_max 行
  appendHistory(entry) {
    try {
      const file = this.config.history_file;
      const dir = path.dirname(file);
      if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
      fs.appendFileSync(file, JSON.stringify(entry) + '\n', 'utf8');
      let lines = 0;
      try { lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()).length; } catch (e) {}
      if (lines > this.config.history_max) {
        try {
          const all = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim());
          fs.writeFileSync(file, all.slice(all.length - this.config.history_max).join('\n') + '\n', 'utf8');
        } catch (e) {}
      }
      return true;
    } catch (e) { return false; }
  }
}

module.exports = { StateStore };
