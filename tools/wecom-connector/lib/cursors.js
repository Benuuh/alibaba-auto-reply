// lib/cursors.js - 多消费者游标存储:每个消费方独立 last_seq,持久化到 JSON 文件,重启不丢
'use strict';

const fs = require('node:fs');
const path = require('node:path');

class CursorStore {
  constructor(file) {
    this._file = file;
    this._data = {};
    this._load();
  }

  _load() {
    try {
      if (fs.existsSync(this._file)) {
        const raw = JSON.parse(fs.readFileSync(this._file, 'utf8'));
        if (raw && typeof raw === 'object' && !Array.isArray(raw)) { this._data = raw; }
      }
    } catch (e) {
      // 损坏文件回退为空 store,不崩溃(下次写入时重建)
      this._data = {};
    }
  }

  _save() {
    try {
      const dir = path.dirname(this._file);
      if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
      // 原子写:先写 .tmp 再 rename,杜绝崩溃窗口产生半文件(游标半文件会导致消费方回退重放)
      const tmp = this._file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(this._data, null, 2), 'utf8');
      fs.renameSync(tmp, this._file);
    } catch (e) {
      // 写入失败不抛:游标仍保存在内存,下一条消息推进时重试
    }
  }

  get(consumer) {
    const v = this._data[consumer];
    return Number.isInteger(v) && v >= 0 ? v : 0;
  }

  exists(consumer) {
    const v = this._data[consumer];
    return Number.isInteger(v) && v >= 0;
  }

  // 仅接受 ≥0 整数;非法值返回 false 不写入
  set(consumer, seq) {
    const n = Number(seq);
    if (!Number.isInteger(n) || n < 0 || typeof consumer !== 'string' || consumer.length === 0) { return false; }
    this._data[consumer] = n;
    this._save();
    return true;
  }

  list() {
    return Object.assign({}, this._data);
  }
}

module.exports = { CursorStore };
