# Alibaba-Auto-Reply

**阿里巴巴国际站卖家消息自动回复工具（物流/货运场景）**

24/7 自动监控阿里国际站 OneTalk 卖家消息中心：买家询盘进来 → 自动识别意图 → LLM 或规则引擎生成回复 → 发送 → 去重；货物信息齐了自动推送到你的企业微信提醒报价。专为**跨境物流/货运代理**业务设计（中美专线、海空运、DDP 门到门、FBA 头程等）。

> English: An automated reply system for Alibaba.com OneTalk seller messages, built for freight-forwarding businesses. It monitors buyer inquiries 24/7, replies via a DeepSeek LLM with a rule-engine fallback (19 scenario branches), and pushes quote-ready reminders to your WeCom through `wecom-connector` — a local HTTP bridge over the official WeCom bot WebSocket SDK. You can also control the service from WeCom with natural language via `control-agent`.

---

## ✨ 特性

| 能力 | 说明 |
|---|---|
| 🔄 **24h 自动监控** | CDP 控制 Chrome 登录 OneTalk，每 12 秒轮询"待回复"板块，断线自动自愈（重启 Chrome + 自动登录），登录态独立 profile 持久保存 |
| 🤖 **双引擎回复** | DeepSeek LLM 生成自然回复（意图识别 + 质量红线 + 发送前禁词/责任承诺双检）；LLM 失败/超时自动回退规则引擎（19 类场景） |
| 🌍 **多语言买家** | 中/英/西/葡/法买家消息识别，统一美式英文回复 |
| 📦 **信息收集** | 自动追问缺失货物信息（总重/尺寸/图片/收货地址），同字段最多追问 2 次，买家承诺提供后不再追问 |
| 📱 **企业微信报价提醒** | 官方智能机器人长连接由独立组件 `wecom-connector`（本地 HTTP 桥 127.0.0.1:19886）承载；数据齐全（重量+尺寸+地址）实时推送（24h 节流） |
| 🎛️ **自然语言远程控制** | 企微发任意自然语言指令，`control-agent` 经 owner 校验 + 确认闸门后派发外部执行 agent 执行并回发结果 |
| 📊 **质量闭环** | 每日质量报告 → 规则自动提炼（40 条上限 + 阈值自动合并）→ 周报（含国别分布）+ 沉睡买家唤醒 |
| 📈 **数据看板** | `dashboard.ps1` 手动生成无 PII 的 HTML 聚合看板（回复量/LLM 成功率/来源分布） |
| 🧩 **组件可复用** | `wecom-connector`（HTTP 桥）与 `control-agent`（远程控制桥）独立成目录、独立测试 |
| 🛡️ **安全设计** | 凭据唯一文件（`credentials.md`）、目录隔离、`status.ps1` 敏感审计、`pre-commit/pre-push` 扫描、PII 仅存本机 |
| 🔍 **买家档案** | 自动抓取买家国家/注册时间，注入 LLM 上下文个性化回复 |
| 🔕 **人工接管白名单** | 企微发"白名单 添加 <客户名>"即不再自动回复该客户：只读留快照+新消息提醒，报价/唤醒免打扰，移出即恢复 |

## 🏗️ 架构

```
┌──────────────────────────────────────────────────────────────┐
│ monitor.ps1 (常驻, 12s/轮)                                   │
│  抓待回复列表 → 打开会话 → 提取消息(1000字符) → 去重(hash+TS)   │
│   → LLM/规则引擎生成回复 → 发送校验 → 买家档案/报价提醒         │
└──────┬──────────────────────────────────────────┬───────────┘
       │ CDP(9222)                                │ HTTP(19886)
┌──────▼───────┐   ┌──────────────┐   ┌───────────▼────────────┐
│ Chrome        │   │ DeepSeek     │   │ wecom-connector (Node)  │
│ (独立 profile)│   │ LLM API      │   │ 官方长连接 SDK + HTTP 桥 │
│  OneTalk 页面 │   │ (无 key 落盘)│   │ /send /messages /cursor │
└──────────────┘   └──────────────┘   └──┬───────────────────▲──┘
                        消费方: alibaba-auto-reply ──────────┘
                        消费方: control-agent(独立游标) ─┐
┌────────────── watchdog.ps1 (30s) 四重守护 ─────────────▼──────────┐
│ 进程拉起 / 日志新鲜度 / CDP 连续 10 次不可达自动跑 chrome_ensure /  │
│ 企微保活(wecom_start.ps1 v2 幂等三段)                              │
└───────────────────────────────────────────────────────────────────┘
┌────────────── control-agent (Node 常驻, 可选/当前未运行) ──────────┐
│ 企微消息 → owner 校验 → 60s 节流 → 确认闸门 → 外部执行 agent → 回发 │
└─────────────────────────────────────────────────────────────────────┘
```

## 🚀 快速开始

**前置条件**：Windows 10+、Chrome、PowerShell 5.1、Node.js 18+（企微通道需要）。

**完整部署手册见 [`README_部署说明.md`](README_%E9%83%A8%E7%BD%B2%E8%AF%B4%E6%98%8E.md)**（凭据、Chrome 登录、企微通道、计划任务、回滚）。最简链路：

```powershell
# 1. 复制配置模板并编辑（路径）；创建 credentials.md；装 tools 依赖
Copy-Item scripts\config.json.example scripts\config.json
cd tools\wecom-connector; npm install

# 2. Chrome 自愈：启动 Chrome + 导航 OneTalk + 自动登录
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\chrome_ensure.ps1

# 3. 启动监控（输出必须重定向到 logs\）
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "<部署根>\logs\monitor_out.log" -RedirectStandardError "<部署根>\logs\monitor_err.log"

# 4. 启动守护（推荐）→ 5. 健康检查
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
```

**credentials.md**（所有敏感信息只存这里，字段名不可改）：账号(account) / 密码(password) / API Key(api_key) / 企微 Bot ID(wx_bot_id) / 企微 Secret(wx_bot_secret)。

## ⚙️ 配置

| 文件 | 作用 |
|---|---|
| `scripts\config.json`（由 `.example` 复制） | 集中路径配置（换机只改它）+ `cdp_port`；经 `scripts\config.ps1` 统一读取 |
| `scripts\reply_rules.json` | 语料库：品牌/价格准则/收集字段/模板/规则（编辑后立即生效） |
| `scripts\reply_agent_prompt.md` | LLM 提示词：意图识别 + 质量红线（编辑后立即生效） |
| `llm_config.json` | LLM 非敏感配置（model/temperature/max_tokens/timeout/endpoint，**不存 key**） |
| `tools\wecom-connector\config.json` | HTTP 桥 host/port/数据目录（凭据走环境变量注入） |
| `tools\control-agent\config.json` | owner/projects/executor/节流等（`owner_userid` 留空首条消息自动锁定） |

## 🧠 工作原理

**自动回复闭环**（每 12 秒一轮）：切"待回复"标签 → 抓列表 → 逐会话（一次 CDP eval 完成打开+会话名校验+消息提取）→ 去重（消息 hash+时间戳 vs `state.json`，已回复进递增冷却）→ 生成回复（LLM 优先，失败回退规则引擎）→ 发送（原生 setter + 清空校验）→ 数据齐全检测 → 经 `wecom-connector` 推送报价提醒。

**规则引擎 19 类场景**：指责不读/拒绝/感谢/简短确认/问 AI/问候/稍后回来/联系方式/流程/计费/时效/电池合规/砍价/比价/无供应商/信息提供/地址/查件/默认追问——实现见 `scripts\reply_engine.ps1`，分支清单见 `SKILL.md` 或测试 `tests\reply_engine.tests.ps1`。

**质量闭环**：05:00 质量报告（`analyze_replies.ps1`）→ 05:30 LLM 自动提炼（`auto_optimize.ps1`，精确去重 + never 保留最新 40 条 + 阈值自动调用 `consolidate_prompt.ps1` 合并归档）→ 次日报告对比；周报（周一 08:00，含国别分布 + nudge 唤醒）。

## 📱 企微通道与远程控制

自 2026-09-07 起企微能力由两个独立可复用组件提供（旧六命令轮询体系已退役归档）：

- **wecom-connector（必须）**：Node 常驻，官方 WebSocket 长连接，HTTP 桥 `127.0.0.1:19886`（`/health /send /messages /cursor /receiver /status`）；多消费者游标持久化；凭据仅环境变量注入；自带测试 63 例（node 46 + PS 17）。详见 `tools\wecom-connector\README.md`。
- **control-agent（可选/当前未运行）**：企微自然语言指令 → owner 校验 → 节流 → 确认闸门（白名单文件免确认、高风险回发 4 位确认码）→ 外部执行 agent（默认 dsh）→ ≤200 字回发；测试 46 例。详见 `tools\control-agent\README.md`。

## 📵 人工接管白名单（不自动回复客户）

企微向机器人发指令（owner 专属）：`白名单 添加 John Smith` / `白名单 列表` / `白名单 删除 John Smith`（≤10s 生效）。

- **行为**：名单买家新消息不触发任何自动回复（LLM/规则/图片模板/QUICK 全跳过）；只读留痕（快照 + 档案）并照常 [NEW-INQUIRY] 提醒人工接管。
- **联动**：报价提醒与沉睡唤醒对名单买家跳过；豁免期不写去重状态，移出后自动恢复。
- **存储**：`data\manual_override.json`（本机 PII 不入库）；按会话显示名匹配（大小写/空格/下划线容错）。

## 🛡️ 安全

- **敏感信息铁律**：账号/密码/API key/机器人凭据只存在于 `credentials.md`；`status.ps1` 自动审计，`.githooks`（pre-commit/pre-push）自动扫描拦截。
- **目录隔离**：`logs\`（运行日志）/ `data\`（快照与档案，含 PII 仅本机）/ `reports\`（聚合报告）/ `backups\`（代码快照，不含凭据）。
- **凭据通道**：企微凭据经环境变量注入组件进程，config/代码/日志均不落盘。
- **仓库安全**：凭据、登录态、买家数据、运行状态全部 gitignore；配置以 `.example` 模板公开。

## 📁 目录结构

```
alibaba-auto-reply/
├── credentials.md            ← 敏感信息唯一文件（不入库）
├── llm_config.json           ← LLM 非敏感配置
├── README_部署说明.md        ← 部署与运维手册
├── SKILL.md                  ← agent 技能定义（opencode 镜像同步对象）
├── docs\CHANGELOG.md         ← 版本变更记录
├── .githooks\                ← pre-commit / pre-push 敏感扫描
├── scripts\                  ← 主代码 + 状态 + 规则
│   ├── monitor.ps1           ← 监控主程序（全自动闭环，单实例）
│   ├── reply_engine.ps1      ← 规则回复引擎（纯逻辑，可单测）
│   ├── reply_rules.json      ← 语料库/模板（可热编辑）
│   ├── reply_agent_prompt.md ← LLM 提示词（可热编辑）
│   ├── config.ps1            ← 配置加载器（Get-SkillPath/Get-CdpPort）
│   ├── config.json.example   ← 路径配置模板
│   ├── chrome_ensure.ps1     ← Chrome 自愈 + 自动登录
│   ├── cdp.ps1               ← CDP 桥接（navigate/eval）
│   ├── watchdog.ps1          ← 四重守护（进程/日志/CDP/企微保活）
│   ├── wecom_start.ps1       ← 企微保活启动器 v2（幂等三段）
│   ├── status.ps1            ← 一键健康检查（含敏感审计）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 报告/质量/规则提炼
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报/唤醒/报价提醒
│   ├── dashboard.ps1         ← 数据看板（手动工具）
│   ├── state.json(+bak)      ← 已回复去重状态
│   └── lib\                  ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom/no_reply）
├── tools\                    ← 独立可复用组件（各自 npm 依赖与测试）
│   ├── wecom-connector\      ← 企微 HTTP 桥（Node，63 例测试）
│   └── control-agent\        ← 企微自然语言远程控制桥（Node，46 例测试）
├── tests\                    ← 主仓库回归测试（3 文件 140 断言，fixtures 虚构数据）
├── logs\  data\  reports\  backups\   ← 运行时数据（均不入库）
└── chrome-profile\           ← Chrome 登录态（独立 profile，勿删除）
```

## 🧪 开发与运维

```powershell
# 主仓库回归测试（3 文件 140 断言：goods 27 + no_reply 29 + reply_engine 84）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1

# tools 组件测试
powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\tests\run_tests.ps1   # 63 例
powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\tests\run_tests.ps1     # 46 例

# 代码快照 / 镜像同步 / 健康检查
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\sync.ps1 -Status   # 或 -Push
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
```

**计划任务（自动运维，见部署手册注册）**：Summary（每 4h 总结）、Quality（每日 05:00 质量报告）、Optimize（每日 05:30 规则提炼）、Weekly（周一 08:00 周报 + nudge）。

## 📄 License

MIT
