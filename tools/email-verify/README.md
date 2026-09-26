# email-verify — 邮箱可投递性验证引擎

主动获客链路中「邮箱富集」的验证环节。**零依赖、纯自建、不买第三方 API**，用 DNS MX + SMTP RCPT 握手判定邮箱能否真实投递。

```
node verify.js --in leads.json --out verified.json --concurrency 4
node verify.js --email someone@acme.com --json
node verify.js --selftest
```

## 为什么需要它

开发信最大的隐性成本不是写，是**发到不存在的地址**。硬退信（hard bounce）会直接拉低发信域信誉，几轮之后你的域名就进垃圾箱了。所以发信前必须先剔除 `invalid`。

## 判定口径（务必读，决定你会不会把域名发废）

| verdict | 含义 | 处置 |
|---|---|---|
| `ok` | MX 存在 + 服务器明确接受（250）+ **非** catch-all | 可优先发信 |
| `invalid` | 语法错/无 MX/一次性邮箱域/服务器明确拒绝（5xx） | **必须剔除，不要发** |
| `risky` | catch-all 域、灰名单拒答、连接失败 | **不等于能发**，须人工或抽样 |
| `unknown` | 无法判定（大厂邮箱对探测无差别拒绝） | 靠该域历史发送表现判断 |

### ⚠️ catch-all 域是最大的坑

很多企业（尤其用 Google Workspace / Microsoft 365 的）配了 catch-all：**任意地址都返回 250**。实测中 `zzz-not-a-real-person-9931@stripe.com` 也返 250。

这意味着：
- catch-all 域上的地址，**SMTP 无法验证真假**，工具会如实标 `risky / CATCH_ALL_DOMAIN`，不会假装成功。
- 不要因为拿到 250 就批量拼凑地址硬发 —— 那是在赌退信率。
- 正确做法：① 优先用官网/领英上明确公开的地址 ② 或人工抽样发信观察退信 ③ 对 catch-all 域降权处理。

工具会在汇总里单独列出所有 catch-all 域。

### 为什么 Gmail / Outlook 的 550 不能当"地址不存在"

Google 与 Microsoft 对陌生 IP 的 RCPT 探测**无差别拒绝**。若把这种 550 判成 `invalid`，你会误删大量真实客户。工具对此类域名降级为 `unknown / PROVIDER_BLOCKS_PROBE`。

反过来说：**RCPT 探测对这两家基本无效**，别指望靠它验证 Gmail 收件人。

## 安全与合规设计

1. **只做 RCPT 探测，绝不发 `DATA`** —— 不会给对方投递任何邮件，不产生任何可被投诉的行为。
2. `MAIL FROM:<postmaster@example.com>` —— 使用无效发信域，明确不是真实发信源。
3. **单域串行 + 全局并发上限**（默认 4）—— 避免把某个域的 MX 打成灰名单，保护本机 IP。
4. 仅输出收件人相关的判定结果，不落其他个人信息。

> 提示：本机出口 **25 端口必须可用**。国内部分运营商封 25，届时本工具只能给出 MX 层判定（`ok` 会退化为 `unknown`）。启动时会自动检测。

## 输出

`verified.json`：

```jsonc
{
  "total": 120,
  "summary":   { "ok": 41, "invalid": 52, "risky": 22, "unknown": 5 },
  "reason_breakdown": { "CATCH_ALL_DOMAIN": 18, "SMTP_REJECT_550": 31, ... },
  "catch_all_domains": ["stripe.com", "shopify.com"],   // 需人工处置
  "ok_emails": ["..."],                                  // 可直接进发信队列
  "results": [ { "email": "...", "verdict": "...", "reason": "...", "mx": [...],
                 "catch_all": false, "local_type": "person", "latency_ms": 812 } ]
}
```

`local_type` 区分 `role`（info@/sales@ 等角色邮箱）与 `person`（john.smith@ 决策人直邮）—— 群发时角色邮箱退信与投诉率更高，决策人邮箱转化更好，建议分开策略。

## 实测样例（2026-09-25 本机真实跑通）

| 地址 | verdict | reason | 说明 |
|---|---|---|---|
| `support@stripe.com` | risky | CATCH_ALL_DOMAIN | 真实地址，但域是 catch-all，无法验证 |
| `zzz-not-a-real-person-9931@stripe.com` | risky | CATCH_ALL_DOMAIN | 假地址也返 250 → 证明 catch-all 不可验 |
| `sales@shopify.com` | risky | CATCH_ALL_DOMAIN | Google Workspace catch-all |
| `info@tesla.com` | unknown | PROVIDER_BLOCKS_PROBE(550) | Outlook 拒绝探测 |
| `nonexistent-person-8821@siemens.com` | invalid | SMTP_REJECT_550 | 域非 catch-all 且明确拒绝 → 判定可信 |
| `bad-syntax-email` | invalid | SYNTAX | |
| `test@mailinator.com` | invalid | DISPOSABLE_DOMAIN | 一次性邮箱 |
| `nobody@no-such-domain-zz991.com` | invalid | NO_MX | |

自测：`node verify.js --selftest` → 10 passed, 0 failed（含并发上限与保序验证）。

## 作为库使用

```js
const { verifyEmail, resolveMx, mapPool } = require('./verify.js');
const r = await verifyEmail('someone@acme.com');   // { verdict, reason, mx, catch_all, ... }
```

## 后续可扩展（未实现，按需再做）

- **邮箱推断**：已知姓名 + 域名 → 排列组合生成候选（`first.last` / `flast` / `first`），再用本引擎批量验证。开源侧无成熟实现，逻辑简单可自建。
- **SPF/DKIM/DMARC 检测**：发信前先查目标域的安全策略，判断对方是否严格（影响送达率预期）。
- **结果缓存**：同一域短期内重复验证无意义，可加 TTL 缓存减少探测。
