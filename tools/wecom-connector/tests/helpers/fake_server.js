// tests/helpers/fake_server.js - 为 PS 客户端测试提供无凭据 HTTP 桥实例(FAKE 模式)
// 环境变量: WECOM_TEST_PORT(端口,默认 0=随机) / FAKE_EMPTY_RECEIVER=1(接收方缓存置空) / FAKE_SEED_COUNT(n,预置消息数)
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createHttpServer } = require('../../lib/http_api.js');
const { CursorStore } = require('../../lib/cursors.js');
const { MessageBuffer } = require('../../lib/buffer.js');
const { ReceiverCache } = require('../../lib/receiver.js');

const port = parseInt(process.env.WECOM_TEST_PORT || '0', 10);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wcfake-'));
const buffer = new MessageBuffer();
const cursorStore = new CursorStore(path.join(dir, 'cursors.json'));
const receiver = new ReceiverCache(path.join(dir, 'receiver.json'));
if (process.env.FAKE_EMPTY_RECEIVER !== '1') {
  receiver.save({ last_userid: 'owner1', last_ts: new Date().toISOString() });
}
const seedCount = parseInt(process.env.FAKE_SEED_COUNT || '0', 10);
for (let i = 0; i < seedCount; i++) {
  buffer.push({ userid: 'u' + i, chatid: '', content: 'seed message ' + i });
}

const bot = {
  get isConnected() { return true; },
  async sendMessage(to) { console.log('FAKE-SENT to=' + to); return { ok: true }; }
};

const server = createHttpServer({ bot, cursorStore, buffer, receiver });
server.on('error', (e) => {
  console.error('FAKE-ERROR code=' + e.code);
  process.exit(3);
});
server.listen(port, '127.0.0.1', () => {
  console.log('FAKE-SERVER-READY port=' + server.address().port);
});
process.on('SIGINT', () => { server.close(); process.exit(0); });
process.on('SIGTERM', () => { server.close(); process.exit(0); });
