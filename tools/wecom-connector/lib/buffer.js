// lib/buffer.js - 消息环形缓冲:接收 → 缓冲 → 增量读取(seq 严格单调递增)
'use strict';

const MAX = 200;

class MessageBuffer {
  constructor() {
    this._items = [];
    this._maxSeq = 0;
  }

  // push({userid, chatid, content}) → {seq, ts, userid, chatid, content}
  // seq = Date.now() 毫秒,严格递增(同毫秒 +1),跨重启因时间戳单调天然不回退
  push(msg) {
    let seq = Date.now();
    if (seq <= this._maxSeq) { seq = this._maxSeq + 1; }
    this._maxSeq = seq;
    const item = {
      seq,
      ts: new Date().toISOString(),
      userid: String((msg && msg.userid) || ''),
      chatid: String((msg && msg.chatid) || ''),
      content: String((msg && msg.content) || '')
    };
    this._items.push(item);
    if (this._items.length > MAX) { this._items = this._items.slice(this._items.length - MAX); }
    return item;
  }

  // 返回 seq > after 的条目(升序),返回新数组
  listAfter(after) {
    const n = Number(after) || 0;
    return this._items.filter((m) => m.seq > n);
  }

  maxSeq() {
    return this._maxSeq;
  }

  count() {
    return this._items.length;
  }
}

module.exports = { MessageBuffer };
