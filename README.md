# Alibaba-Auto-Reply

**阿里巴巴国际站卖家消息自动回复工具（物流/货运场景）**

24/7 自动监控阿里国际站 OneTalk 卖家消息中心：买家询盘进来 → 自动识别意图 → LLM 或规则引擎生成回复 → 发送 → 去重；货物信息齐了自动推送到你的企业微信提醒报价。专为**跨境物流/货运代理**业务设计（中美专线、海空运、DDP 门到门、FBA 头程等）。

> English: An automated reply system for Alibaba.com OneTalk seller messages, built for freight-forwarding businesses. It monitors buyer inquiries 24/7, replies via a DeepSeek LLM with a rule-engine fallback (19 scenario templates), and pushes quote-ready reminders to your WeCom through `wecom-connector` — a local HTTP bridge over the official WeCom bot WebSocket SDK. You can also control the service from WeCom with natural language via `control-agent`, or just clone `tools/` components for your own projects.

---

## ✨ 特性

| 能力 | 说明 |
|---|---|
| 🔄 **24h 自动监控** | CDP 控制 Chrome 登录 OneTalk，每 12 秒轮询"待回复"板块，断线自动自愈（重启 Chrome + 自动登录），Chrome 登录态独立 profile 持久保存 |
| 🤖 **双引擎回复** | DeepSeek LLM 生成自然回复（意图识别 + 质量红线）；LLM 失败/超时自动回退规则引擎（19 类场景） |
| 🌍 **多语言买家** | 中/英/西/葡/法买家消息识别，统一美式英文回复，西语/葡语先呼应原文要点 |
| 📦 **信息收集** | 自动追问缺失货物信息（总重/尺寸/图片/收货地址），**同字段最多追问 2 次**（防骚扰），买家承诺提供后不再追问 |
| 📱 **企业微信报价提醒** | 官方智能机器人 WebSocket 长连接由独立组件 `wecom-connector`（本地 HTTP 桥 127.0.0.1:19886）承载，买家数据齐全（重量+尺寸+地址）实时推送概要提醒（24h 节流、信息变化自动再提醒） |
| 🎛️ **自然语言远程控制** | 企微发**任意自然语言指令**（运维/改语料/查数据/写代码），`control-agent` 经确认闸门后派发外部执行 agent（默认 dsh）执行并回发结果；owner 自动锁定、无固定命令表 |
| 📊 **质量闭环** | 每日质量报告（负面案例/重复提问证据化）、规则自动提炼优化、周报（含买家国别分布）、沉睡买家自动唤醒（nudge） |
| 📈 **数据看板** | HTML 聚合看板：回复量/LLM 成功率/来源分布，无买家 PII；关键事件通知（9 类，可接 webhook） |
| 🧩 **组件可复用** | `wecom-connector`（HTTP 桥）与 `control-agent`（远程控制桥）独立成目录、独立测试，可被任意项目/agent 复用 |
| 🛡️ **安全设计** | 凭据唯一文件（`credentials.md`）、日志/快照/报告目录隔离、`status.ps1` 内置敏感审计、`pre-commit/pre-push` 敏感扫描、买家 PII 仅存本机 |
| 🔍 **买家档案** | 自动抓取买家国家/注册时间，注入 LLM 上下文个性化回复 |
| 🔕 **人工接管白名单** | 企微发"白名单 添加 <客户名>"即不再自动回复该客户：只读留快照+新消息提醒，报价/唤醒免打扰，移出即恢复，≤10s 生效 |

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
└──────────────┘   └──────────────┘   │ /health /receiver/status│
                                      └──┬───────────────────▲──┘
                        消费方: alibaba-auto-reply ──────────┘
                        消费方: control-agent(独立游标) ─┐
┌────────────── watchdog.ps1 (30s) 四重守护 ─────────────▼──────────┐
│ 进程拉起 / 日志新鲜度 / CDP 连续 10 次不可达自动跑 chrome_ensure /  │
│ 企微保活(wecom_start.ps1 v2 幂等三段)                              │
└───────────────────────────────────────────────────────────────────┘
┌────────────── control-agent (Node 常驻, 可选) ────────────────────┐
│ 企微消息 → owner 校验 → 60s 节流 → 确认闸门(高风险确认码/白名单免确认) │
│  → 外部执行 agent(dsh 默认, 可换 opencode/claude/自定义) → ≤200 字回发 │
└─────────────────────────────────────────────────────────────────────┘
```

## 🚀 快速开始

**前置条件**：Windows 10+、Chrome、PowerShell 5.1、Node.js 18+（企微通道需要）。

**完整部署手册见 [`README_部署说明.md`](README_%E9%83%A8%E7%BD%B2%E8%AF%B4%E6%98%8E.md)**（含凭据、Chrome 登录、企微通道、计划任务、回滚）。最简链路：

```powershell
# 1. 复制配置模板并编辑（路径/凭据）
Copy-Item scripts\config.json.example scripts\config.json   # 改路径为实际目录
# 创建 credentials.md（账号/密码/API Key/企微 Bot ID+Secret，唯一凭据文件）
# tools 依赖（企微通道）
cd tools\wecom-connector; npm install

# 2. Chrome 自愈脚本：启动 Chrome + 导航 OneTalk + 自动登录
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\chrome_ensure.ps1

# 3. 启动监控（输出必须重定向到 logs\）
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "<部署根>\logs\monitor_out.log" -RedirectStandardError "<部署根>\logs\monitor_err.log"

# 4. 启动守护（进程/日志/CDP/企微四重，推荐）
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden

# 5. 健康检查
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
```

**credentials.md**（所有敏感信息只存这里，字段名不可改）：

```markdown
- **账号 (account)**：xxx
- **密码 (password)**：xxx
- **API Key (api_key)**：xxx
- **企微机器人 Bot ID (wx_bot_id)**：xxx（可选，企微通道用）
- **企微机器人 Secret (wx_bot_secret)**：xxx（可选，企微通道用）
```

## ⚙️ 配置

| 文件 | 作用 |
|---|---|
| `scripts\config.json`（由 `config.json.example` 复制） | 集中路径配置（换机/换目录只改它）；所有脚本经 `scripts\config.ps1` 统一读取 |
| `scripts\reply_rules.json` | 语料库：品牌/价格准则/收集字段/19+ 回复模板（编辑后立即生效） |
| `scripts\reply_agent_prompt.md` | LLM 回复代理提示词：意图识别策略 + 质量红线（编辑后立即生效） |
| `llm_config.json` | LLM 非敏感配置（model/temperature/max_tokens/timeout/endpoint，**不存 key**） |
| `tools\wecom-connector\config.json` | HTTP 桥 host/port/数据目录（由 `config.json.example` 复制；凭据走环境变量注入，不入配置） |
| `tools\control-agent\config.json` | owner/projects/executor/节流等（由 `config.json.example` 复制；`owner_userid` 留空首条消息自动锁定） |

## 🧠 工作原理

**自动回复闭环**（每 12 秒一轮）：
1. 切"待回复"标签 → 抓会话列表 → 逐个处理
2. 打开会话（一次 CDP eval 完成：打开+会话名校验+消息提取，防串台防错发）
3. 去重：最新买家消息 hash + 时间戳 vs `state.json`，已回复的进入递增冷却
4. 生成回复：LLM 优先（上下文含追问统计/承诺字段硬约束）→ 失败回退规则引擎
5. 发送：原生 setter 填值 + 发送按钮 + 输入框清空校验
6. 数据齐全检测 → 经 `wecom-connector` 推送企微报价提醒（重量/尺寸/地址具体值）

**回复引擎 19 类场景**：指责不读 → 道歉 / 拒绝 → 友好收尾 / 感谢 / 简短确认 / 问是否 AI / 问候 / 稍后回来 / 联系方式 / 流程 / 计费 / 时效 / 电池合规(SDS+UN38.3) / 砍价 / 比价 / 无供应商 / 信息提供 / 地址 / 查件 / 默认追问——每条都防骚扰、不编造、答必所问。

**质量闭环**：每日 05:00 质量报告 → 05:30 LLM 自动提炼改进规则（去重 + 40 条上限护栏）→ 次日报告对比验证；周报（周一 08:00）含买家国别分布并顺带唤醒沉睡买家（nudge，≥2 天未回、单买家限 1 次）；`task_health.ps1` 巡检各计划任务是否超龄。

**告警与看板**：`notify.ps1` 扫描 9 类关键事件（30 分钟去重入 `logs\events.json`，可配 webhook 外推）；`dashboard.ps1` 生成无 PII 的 HTML 聚合看板（建议每日 06:00 计划任务）。

## 📱 企微通道与远程控制

自 2026-09-07 起，企微能力由两个**独立可复用组件**提供（取代旧 `scripts\wecom\wecom_bot.js` + `wecom_command.ps1` 六命令轮询，旧文件保留留档）：

### 1. wecom-connector —— 本地 HTTP 桥（必须）
- Node 常驻（`@wecom/aibot-node-sdk` 官方 WebSocket 长连接，自动认证/心跳/重连），监听 `127.0.0.1:19886`
- **6 个端点**：`GET /health`、`POST /send`、`GET /messages?consumer=&after=`、`GET /cursor`、`POST /cursor`、`GET /receiver`、`GET /status`
- **多消费者游标**（at-least-once）：`alibaba-auto-reply` 与 `control-agent` 各自独立推进 seq，互不影响；持久化于 `data\cursors.json`，重启不丢
- 凭据只经环境变量注入（`WX_BOT_ID`/`WX_BOT_SECRET`）；无凭据可启动（`connected=false`），供联调
- 自带测试 57 例（node 40 + PowerShell 客户端 17）；PS 客户端库 `client\wecom-client.ps1` 零依赖，任意项目可复用
- 详文档见 `tools\wecom-connector\README.md`

### 2. control-agent —— 自然语言远程控制（可选）
- 读取企微任意自然语言指令 → **owner 校验**（`owner_userid` 留空时首条消息自动锁定并回写 config）→ 60s 同内容节流 → **确认闸门** → 派发**外部执行 agent**（默认 `dsh --profile headless`，可插拔换 opencode/claude/自定义命令）→ 结果 ≤200 字回发
- 闸门规则：低风险指令直接派发；命中白名单文件（`reply_rules.json`/`reply_agent_prompt.md`/`config.json`）且无高风险词 → 免确认；删除/重启/网络外联/凭据类 → 回发 4 位确认码，人工回复后执行（5 分钟有效）
- 自带测试 46 例；详文档见 `tools\control-agent\README.md`
- 依赖 dsh：`npm.cmd install -g @deepseek-ai/dsh`，模型 key 复用 credentials.md 的 `api_key`（按 dsh 官方方式配置）

### 指令示例（全部自然语言，无固定命令表）

| 你想做的 | 直接发 | 是否确认 |
|---|---|---|
| 运维 | "重启一下监控服务" / "看看今天的回复情况" | 重启类 → 确认码 |
| 改语料 | "把砍价话术改得更友善" | 白名单文件 → 免确认 |
| 查数据 | "查最近发送失败的记录" | 低风险直发 |
| 写代码 | "给 wecom-connector 的 /messages 加分页" | 低风险直发 |
| 闲聊 | "你能做什么" | 直发（执行 agent 自行理解） |

> 旧 `AlibabaAutoReplyWeComCmd` 计划任务已于 2026-09-07 停用删除（XML 备份在 `backups\`），**请勿重建**；`scripts\wecom_command.ps1` 停用留档，不参与运行。

## 📵 人工接管白名单（不自动回复客户）

对个别买家（如已转人工跟进、线下报价中的客户），在企微向机器人发指令即可让系统停止自动回复该买家，由你人工接管：

| 企微指令（owner 专属，即时回执） | 效果 |
|---|---|
| `白名单 添加 John Smith` | 该买家不再自动回复（≤10s 生效） |
| `白名单 列表` | 查看当前名单 |
| `白名单 删除 John Smith` | 移出名单，恢复自动回复 |

- **行为**：名单买家的新消息不触发任何自动回复（LLM/规则/图片模板/QUICK 全部跳过、不发送）；只读留痕——保存会话快照 `data\msgs_*.txt` 与买家档案，并照常经 [NEW-INQUIRY] 企微提醒你人工接管（24h 节流不变）
- **免打扰联动**：报价提醒（quote）与沉睡唤醒（nudge）对名单买家一律跳过
- **可逆**：豁免期间不写"已回复"去重状态，移出名单后自动恢复正常（先回复最新一条）
- **名单存储**：`data\manual_override.json`（JSON 数组；本机 PII 不入库；由企微指令维护，损坏/缺失视为空名单）
- **匹配规则**：按买家会话显示名匹配，大小写、多余空格、下划线均容错（如 `ABC_Trading` 与 `ABC Trading` 视为同一买家）

## 🛡️ 安全

- **敏感信息铁律**：账号/密码/API key/机器人凭据只存在于 `credentials.md`，任何其他文件（配置/日志/报告/备份/仓库）不得出现；`status.ps1` 每次运行自动审计，`.githooks`（pre-commit/pre-push）自动扫描拦截
- **目录隔离**：`logs\`（运行日志）/ `data\`（买家快照与档案，含 PII 仅本机）/ `reports\`（聚合报告）/ `backups\`（代码快照，不含凭据）
- **凭据通道**：企微凭据经环境变量注入组件进程（`wecom-connector`），config/代码/日志均不落盘
- **仓库安全**：凭据、Chrome 登录态、买家数据、运行状态全部 gitignore 排除；语料库与配置文件以 `.example` 模板形式公开（`config.json.example` 等）

## 📁 目录结构

```
alibaba-auto-reply/
├── credentials.md            ← 敏感信息唯一文件（不入库）
├── llm_config.json           ← LLM 非敏感配置
├── README_部署说明.md        ← 部署与运维手册
├── SKILL.md                  ← agent 技能定义（opencode/dsh 镜像同步对象）
├── UPDATE_SPEC.md            ← 历史开发规格（工作方式参考）
├── docs\CHANGELOG.md         ← 版本变更记录
├── .githooks\                ← pre-commit / pre-push 敏感扫描（sanitize_check.ps1）
├── scripts\                  ← 主代码 + 状态 + 规则
│   ├── monitor.ps1           ← 监控主程序（全自动闭环，单实例）
│   ├── reply_engine.ps1      ← 规则回复引擎（纯逻辑，可单测）
│   ├── reply_rules.json      ← 语料库/回复模板（可热编辑）
│   ├── reply_agent_prompt.md ← LLM 代理提示词（可热编辑）
│   ├── config.ps1            ← 配置加载器（Get-SkillPath）
│   ├── config.json.example   ← 路径配置模板（复制为 config.json 后编辑）
│   ├── chrome_ensure.ps1     ← Chrome 自愈 + 自动登录
│   ├── cdp.ps1               ← CDP 桥接（newtab/navigate/eval/screenshot）
│   ├── watchdog.ps1          ← 四重守护（进程/日志/CDP/企微保活，防风暴）
│   ├── wecom_start.ps1       ← 企微保活启动器 v2（幂等三段，watchdog 每轮调用）
│   ├── status.ps1            ← 一键健康检查（含敏感审计、任务超龄）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像同步/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 总结/质量/规则提炼（计划任务）
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报/唤醒/报价提醒 CLI
│   ├── dashboard.ps1 / notify.ps1 / health_report.ps1 / task_health.ps1 ← 看板/告警/健康报告
│   ├── wecom_command.ps1     ← 旧六命令远程控制（已停用留档，勿启用）
│   ├── state.json(+bak)      ← 已回复去重状态（双写）
│   └── lib\                  ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom）
├── tools\                    ← 独立可复用组件（各自 npm 依赖与测试）
│   ├── wecom-connector\      ← 企微 HTTP 桥（Node，127.0.0.1:19886，57 例测试）
│   └── control-agent\        ← 企微自然语言远程控制桥（Node，46 例测试）
├── tests\                    ← 主仓库回归测试（36 用例，fixtures 为虚构数据）
├── logs\  data\  reports\  backups\   ← 运行时数据（均不入库）
│   └── data\manual_override.json      ← 人工接管白名单（企微"白名单"指令维护，本机 PII）
└── chrome-profile\           ← Chrome 登录态（独立 profile，勿删除）
```

## 🧪 开发与运维

```powershell
# 主仓库回归测试（36 用例：回复引擎/货物引擎/旧命令兼容）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1

# tools 组件测试
powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\tests\run_tests.ps1   # 57 例
powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\tests\run_tests.ps1     # 46 例

# 代码快照备份 / 镜像同步（-Status 先看差异，-Push 推送）
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\sync.ps1 -Status
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\sync.ps1 -Push

# 健康检查（进程/CDP/日志/去重/计划任务/敏感审计）
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
```

**计划任务（自动运维，见部署手册注册）**：Summary（每 4h 总结）、Quality（每日 05:00 质量报告）、Optimize（每日 05:30 规则提炼）、Weekly（周一 08:00 周报 + nudge）。`task_health.ps1` 检测任务超龄。

## 📄 License

MIT
