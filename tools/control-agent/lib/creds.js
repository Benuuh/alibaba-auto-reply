// lib/creds.js - 从 alibaba-auto-reply credentials.md 读取 control_api_key(只读,不落盘)
'use strict';

const fs = require('node:fs');

// 兼容 alibaba-auto-reply\lib\creds.ps1 的行格式:
//   - **控制 Agent API Key (control_api_key)**：<value>
function readControlApiKey(file) {
  if (!file) { return null; }
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const m = raw.match(/- \*\*控制 Agent API Key \(control_api_key\)\*\*：(\S+)/);
    return m ? m[1] : null;
  } catch (e) { return null; }
}

module.exports = { readControlApiKey };
