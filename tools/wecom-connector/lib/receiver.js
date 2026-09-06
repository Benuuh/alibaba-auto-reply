// lib/receiver.js - 接收方缓存(owner 判定与主动推送目标):持久化到 JSON 文件
'use strict';

const fs = require('node:fs');
const path = require('node:path');

class ReceiverCache {
  constructor(file) {
    this._file = file;
  }

  _read() {
    try {
      if (fs.existsSync(this._file)) {
        const raw = JSON.parse(fs.readFileSync(this._file, 'utf8'));
        if (raw && typeof raw === 'object' && !Array.isArray(raw)) { return raw; }
      }
    } catch (e) { /* 损坏回退空对象 */ }
    return {};
  }

  // save({last_userid}|{last_chatid}, last_ts) 合并写入(原子:tmp+rename)
  save(info) {
    try {
      const dir = path.dirname(this._file);
      if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
      const cache = this._read();
      Object.assign(cache, info);
      const tmp = this._file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(cache, null, 2), 'utf8');
      fs.renameSync(tmp, this._file);
      return true;
    } catch (e) {
      return false;
    }
  }

  read() {
    return this._read();
  }
}

module.exports = { ReceiverCache };
