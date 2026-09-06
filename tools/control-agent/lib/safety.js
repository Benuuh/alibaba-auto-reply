// lib/safety.js - 高风险规则与白名单判定(纯函数)
'use strict';

const HIGH_RISK_PATTERNS = [
  /删除|覆盖|格式化|Remove-Item|Clear-Content|Clear-Host|truncate|覆盖写入/i,
  /\brm\b|\bdel\b|\brmdir\b|\bunlink\b/i,
  /重启|停止|停用|杀掉|kill|Stop-Process|Stop-Service|restart|shutdown/i,
  /Invoke-WebRequest|Invoke-RestMethod|curl|wget|\bnc\b|ncat|外联/i,
  /C:\\Windows|system32/i,
  /凭据|密码|api[\s_-]?key|credentials|secret|token/i,
  /format|格式化/i
];

function hitHighRisk(text) {
  const s = String(text || '');
  return HIGH_RISK_PATTERNS.some((re) => re.test(s));
}

// 白名单写:指令提及白名单文件(如 reply_rules.json)且未命中高风险模式 → 免确认
function isWhitelistWrite(text, whitelistFiles) {
  const s = String(text || '');
  if (hitHighRisk(s)) { return false; }
  return (whitelistFiles || []).some((f) => s.includes(String(f)));
}

module.exports = { hitHighRisk, isWhitelistWrite, HIGH_RISK_PATTERNS };
