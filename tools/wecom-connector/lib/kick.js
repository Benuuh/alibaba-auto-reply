// lib/kick.js - 被顶下线(disconnected_event)后的退避决策(纯函数,便于单测)
'use strict';

// 输入: kicksMs=历史踢下线时间戳数组(ms), nowMs=当前时间, cfg={windowMin,threshold,shortBackoffSec,longBackoffMin}
// 输出: { kicks: 保留在窗口内的数组(含本次), backoffUntilMs, long: 是否进入长退避 }
function decideKickBackoff(kicksMs, nowMs, cfg) {
  const windowMs = cfg.windowMin * 60000;
  const kept = (Array.isArray(kicksMs) ? kicksMs : [])
    .filter((t) => Number.isFinite(t) && nowMs - t < windowMs);
  kept.push(nowMs);
  const long = kept.length >= cfg.threshold;
  const backoffUntilMs = nowMs + (long ? cfg.longBackoffMin * 60000 : cfg.shortBackoffSec * 1000);
  return { kicks: kept, backoffUntilMs, long };
}

module.exports = { decideKickBackoff };
