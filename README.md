# Alibaba-Auto-Reply

**阿里巴巴国际站卖家消息自动回复工具（物流/货运场景）**

24/7 自动监控阿里国际站 OneTalk 卖家消息中心：买家询盘进来 → 自动识别意图 → LLM 或规则引擎生成回复 → 发送 → 去重；货物信息齐了自动推送到你的企业微信提醒报价。专为**跨境物流/货运代理**业务设计（中美专线、海空运、DDP 门到门、FBA 头程等）。

> English: An automated reply system for Alibaba.com OneTalk seller messages, built for freight-forwarding businesses. Monitors buyer inquiries 24/7, replies via LLM + rule engine, and pushes quote-ready reminders to your WeCom (WeChat Work) via official long-connection SDK.

---

## ✨ 特性

| 能力 | 说明 |
|---|---|
| 🔄 **24h 自动监控** | CDP 控制 Chrome 登录 OneTalk，每 12 秒轮询"待回复"板块，断线自动自愈（重启 Chrome + 自动登录） |
| 🤖 **双引擎回复** | DeepSeek LLM 生成自然回复（意图识别 + 质量红线）；LLM 失败/超时自动回退规则引擎（19 类场景） |
| 🌍 **多语言买家** | 中/英/西/葡/法买家消息识别，统一美式英文回复，西语/葡语先呼应原文要点 |
| 📦 **信息收集** | 自动追问缺失货物信息（总重/尺寸/图片/收货地址），**同字段最多追问 2 次**（防骚扰），买家承诺提供后不再追问 |
| 📱 **企业微信报价提醒** | 官方智能机器人 **WebSocket 长连接**，买家数据齐全（重量+尺寸+地址）实时推送概要提醒（24h 节流、信息变化自动再提醒） |
| 📊 **质量闭环** | 每日质量报告（负面案例/重复提问证据化）、规则自动提炼优化、周报（含买家国别分布） |
| 📈 **数据看板** | HTML 聚合看板：回复量/LLM 成功率/来源分布，无买家 PII |
| 🎛️ **企微远程指令** | 向企微机器人发命令远程操控：帮助/健康检查/看板/最新买家/报价提醒/重启监控，执行结果回发（仅 owner、60s 节流） |
| 🛡️ **安全设计** | 凭据唯一文件（`credentials.md`）、日志/快照/报告目录隔离、健康检查内置敏感审计、买家 PII 仅存本机 |
| 🔍 **买家档案** | 自动抓取买家国家/注册时间，注入 LLM 上下文个性化回复 |

## 🏗️ 架构

```
┌─────────────────────────────────────────────────────────────┐
│  monitor.ps1 (常驻, 12s/轮)                                  │
│  抓待回复列表 → 打开会话 → 提取消息(1000字符) → 去重(hash+TS)  │
│   → LLM/规则引擎生成回复 → 发送校验 → 买家档案/报价提醒        │
└──────────────┬──────────────────────────────────────────────┘
               │
    ┌──────────┴───────────┬──────────────────────┐
    ▼                      ▼                      ▼
┌─────────┐          ┌──────────┐          ┌──────────────┐
│ Chrome   │          │ DeepSeek │          │ WeCom 长连接 │
│ (CDP9222)│          │  LLM API │          │ (Node SDK)  │
│ OneTalk  │          │          │          │ 报价提醒推送 │
└─────────┘          └──────────┘          └──────────────┘
    ▲
    │ watchdog.ps1 (30s): 进程/日志/CDP/企微 四重守护, 自动拉起
```

## 🚀 快速开始

**前置条件**：Windows 10+、Chrome、PowerShell 5.1、Node.js 18+（企微提醒可选）

```powershell
# 1. 配置凭据（敏感信息唯一文件，格式见下）
#    credentials.md + llm_config.json + config.json

# 2. Chrome 自愈脚本：启动 Chrome + 导航 OneTalk + 自动登录
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\chrome_ensure.ps1

# 3. 启动监控（输出必须重定向）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "C:\path\to\alibaba-auto-reply\logs\monitor_out.log" -RedirectStandardError "C:\path\to\alibaba-auto-reply\logs\monitor_err.log"

# 4. 启动守护（推荐）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden

# 5. 健康检查
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
```

**credentials.md**（所有敏感信息只存这里）：

```markdown
- **账号 (account)**：xxx
- **密码 (password)**：xxx
- **API Key (api_key)**：xxx
- **企微机器人 Bot ID (wx_bot_id)**：xxx（可选）
- **企微机器人 Secret (wx_bot_secret)**：xxx（可选）
```

## ⚙️ 配置

| 文件 | 作用 |
|---|---|
| `scripts\config.json` | 集中路径配置（换机/换目录只改它） |
| `scripts\reply_rules.json` | 语料库：品牌/价格准则/收集字段/19+ 回复模板（编辑后立即生效） |
| `scripts\reply_agent_prompt.md` | LLM 回复代理提示词：意图识别策略 + 质量红线（编辑后立即生效） |
| `llm_config.json` | LLM 非敏感配置（model/temperature/endpoint，**不存 key**） |

## 🧠 工作原理

**自动回复闭环**（每 12 秒一轮）：
1. 切"待回复"标签 → 抓会话列表 → 逐个处理
2. 打开会话（一次 CDP eval 完成：打开+会话名校验+消息提取，防串台防错发）
3. 去重：最新买家消息 hash + 时间戳 vs `state.json`，已回复的进入递增冷却
4. 生成回复：LLM 优先（上下文含追问统计/承诺字段硬约束）→ 失败回退规则引擎
5. 发送：原生 setter 填值 + 发送按钮 + 输入框清空校验
6. 数据齐全检测 → 企业微信推送报价提醒（重量/尺寸/地址具体值）

**回复引擎 19 类场景**：指责不读 → 道歉 / 拒绝 → 友好收尾 / 感谢 / 简短确认 / 问是否 AI / 问候 / 稍后回来 / 联系方式 / 流程 / 计费 / 时效 / 电池合规(SDS+UN38.3) / 砍价 / 比价 / 无供应商 / 信息提供 / 地址 / 查件 / 默认追问——每条都防骚扰、不编造、答必所问。

**质量闭环**：每日 05:00 质量报告 → 05:30 LLM 自动提炼改进规则（去重 + 上限护栏）→ 次日报告对比验证；周报含买家国别分布；每周一自动唤醒沉睡买家（nudge）。

## 🛡️ 安全

- **敏感信息铁律**：账号/密码/API key/机器人凭据只存在于 `credentials.md`，任何其他文件（配置/日志/报告/备份/仓库）不得出现；`status.ps1` 每次运行自动审计
- **目录隔离**：`logs\`（运行日志）/ `data\`（买家快照与档案，含 PII 仅本机）/ `reports\`（聚合报告）/ `backups\`（代码快照，不含凭据）
- **仓库安全**：凭据、Chrome 登录态、买家数据、运行状态全部 gitignore 排除；语料库已脱敏（占位符）后公开

## 📁 目录结构

```
alibaba-auto-reply/
├── credentials.md        ← 敏感信息唯一文件（不入库）
├── llm_config.json       ← LLM 非敏感配置
├── scripts/              ← 代码 + 状态 + 规则
│   ├── monitor.ps1       ← 监控主程序（全自动闭环）
│   ├── reply_engine.ps1  ← 规则回复引擎（纯逻辑，可单测）
│   ├── watchdog.ps1      ← 守护（进程/日志/CDP/企微四重检查）
│   ├── chrome_ensure.ps1 ← Chrome 自愈 + 自动登录
│   ├── lib/              ← 公共库（creds/log/cdp/send/llm/lock/goods/wecom/quote）
│   ├── quote_remind.ps1  ← 报价提醒 CLI（手动/调试）
│   ├── wecom/            ← 企微长连接机器人服务（Node SDK）
│   └── ...               ← status/backup/sync/task_health/notify/dashboard/报告工具
├── tests/                ← 回归测试（36 用例）
├── logs/  data/  reports/  backups/   ← 运行时数据（均不入库）
└── SKILL.md              ← DSH/opencode 技能定义
```

## 🧪 开发

```powershell
# 回归测试
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1

# 代码快照备份 / 工作副本↔技能镜像同步
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\sync.ps1 -Status   # 或 -Push

# 计划任务（自动运维）：总结/质量/优化/周报/健康检查/通知/看板
```

## 🎛️ 企微远程指令

向企微智能机器人发送以下命令，即可远程操控监控（仅绑定 owner 可执行，同命令 60 秒内不重复执行）：

| 命令 | 作用 | 回发内容 |
|------|------|----------|
| 帮助 / help | 命令清单 | 全部命令与一句话说明 |
| 健康检查 / status | 运行健康检查 | monitor/watchdog 进程、CDP、日志新鲜度、LLM 错误数、[!!] 清单 |
| 看板 / dashboard | 生成数据看板 | 看板路径 + 发送成功数/活跃买家/LLM 成功率 |
| 最新买家 / buyers | 活跃买家扫描 | 近 7 天买家列表 + 货物齐全度标记 |
| 报价提醒 / quote | 候选买家预览 | 数据齐全买家清单（买家 | 货名） |
| 重启监控 / restart | 重启 monitor | 新 PID + 心跳状态 |

实现：`scripts\wecom_command.ps1` 每分钟轮询 bot 消息缓冲（seq=毫秒时间戳单调递增，跨重启不丢不重），匹配命令 → 执行 → 回发结果。状态存 `data\wecom_cmd_state.json`（双写 .bak）。

## 📄 License

MIT
