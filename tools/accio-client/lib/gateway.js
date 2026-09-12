'use strict';

// Accio Desktop 本地网关客户端：读取 gateway-cli.json（每次调用重读）+ 调用 /mcp/proxy。
// 协议为按观察结果自行重写（参考项目仅用于阅读调用方式，未复制代码）。
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const ERR = {
  GATEWAY_DOWN: 'GATEWAY-DOWN',
  AUTH_401: 'AUTH-401',
  TIMEOUT: 'TIMEOUT',
  PROTOCOL_ERROR: 'PROTOCOL-ERROR',
};

class GatewayError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'GatewayError';
    this.code = code;
  }
}

function defaultRootDir() {
  return process.env.USERPROFILE || os.homedir();
}

// 查找 gateway-cli.json：%USERPROFILE%\.accio\accounts\*\.accio\runtime\gateway-cli.json
// 多账号时取最近修改的一份；测试可用 ACCIO_GATEWAY_FILE 覆盖。
function findGatewayConfigPath(rootDir) {
  if (process.env.ACCIO_GATEWAY_FILE) {
    return process.env.ACCIO_GATEWAY_FILE;
  }
  const base = rootDir || defaultRootDir();
  const accountsDir = path.join(base, '.accio', 'accounts');
  let entries;
  try {
    entries = fs.readdirSync(accountsDir);
  } catch (e) {
    throw new GatewayError(ERR.GATEWAY_DOWN, 'accounts dir not found: ' + accountsDir);
  }
  let best = null;
  let bestM = -1;
  for (const name of entries) {
    const file = path.join(accountsDir, name, '.accio', 'runtime', 'gateway-cli.json');
    try {
      const st = fs.statSync(file);
      if (st.mtimeMs > bestM) {
        best = file;
        bestM = st.mtimeMs;
      }
    } catch (e) { /* skip missing */ }
  }
  if (!best) {
    throw new GatewayError(ERR.GATEWAY_DOWN, 'gateway-cli.json not found under ' + accountsDir);
  }
  return best;
}

// 读取并校验配置；鉴权值只在内存中使用，不打印。
function readGatewayConfig(filePath) {
  let raw;
  try {
    raw = fs.readFileSync(filePath, 'utf8');
  } catch (e) {
    throw new GatewayError(ERR.GATEWAY_DOWN, 'cannot read gateway config');
  }
  let cfg;
  try {
    cfg = JSON.parse(raw);
  } catch (e) {
    throw new GatewayError(ERR.PROTOCOL_ERROR, 'gateway config is not valid JSON');
  }
  if (!cfg || typeof cfg.url !== 'string' || !cfg.url) {
    throw new GatewayError(ERR.PROTOCOL_ERROR, 'gateway config missing url');
  }
  if (cfg.authMode === 'basic' && (!cfg.username || !cfg.password)) {
    throw new GatewayError(ERR.PROTOCOL_ERROR, 'gateway config missing basic auth fields');
  }
  const pw = cfg.password || '';
  return {
    url: cfg.url,
    username: cfg.username || '',
    password: pw,
    authMode: cfg.authMode || 'none',
    relayPort: cfg.relayPort,
    pid: cfg.pid,
    filePath,
  };
}

function buildAuthHeader(cfg) {
  if (cfg.authMode !== 'basic' || !cfg.username) return null;
  const token = Buffer.from(cfg.username + ':' + cfg.password, 'utf8').toString('base64');
  return 'Basic ' + token;
}

// POST {url}/mcp/proxy；返回网关信封对象（{success, data:{content,isError}}）。
function callProxy(cfg, body, options) {
  const timeoutMs = (options && options.timeoutMs) || 15000;
  return new Promise((resolve, reject) => {
    let target;
    try {
      target = new URL('/mcp/proxy', cfg.url);
    } catch (e) {
      reject(new GatewayError(ERR.PROTOCOL_ERROR, 'invalid gateway url'));
      return;
    }
    const payload = JSON.stringify(body);
    const headers = {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(payload),
    };
    const auth = buildAuthHeader(cfg);
    if (auth) headers.Authorization = auth;

    const req = http.request(
      {
        hostname: target.hostname,
        port: target.port || 80,
        path: target.pathname,
        method: 'POST',
        headers,
      },
      (res) => {
        let data = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          if (res.statusCode === 401) {
            reject(new GatewayError(ERR.AUTH_401, 'gateway rejected credentials (401)'));
            return;
          }
          if (res.statusCode !== 200) {
            reject(new GatewayError(ERR.PROTOCOL_ERROR, 'unexpected HTTP status ' + res.statusCode));
            return;
          }
          let parsed;
          try {
            parsed = JSON.parse(data);
          } catch (e) {
            reject(new GatewayError(ERR.PROTOCOL_ERROR, 'gateway response is not JSON'));
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.setTimeout(timeoutMs, () => {
      req.destroy(new GatewayError(ERR.TIMEOUT, 'gateway request timed out after ' + timeoutMs + 'ms'));
    });
    req.on('error', (e) => {
      if (e instanceof GatewayError) reject(e);
      else reject(new GatewayError(ERR.GATEWAY_DOWN, 'gateway connection failed: ' + e.message));
    });
    req.write(payload);
    req.end();
  });
}

module.exports = {
  ERR,
  GatewayError,
  findGatewayConfigPath,
  readGatewayConfig,
  buildAuthHeader,
  callProxy,
};
