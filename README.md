# Alibaba-Auto-Reply

**阿里巴巴国际站卖家消息自动回复工具（物流/货运场景）**

24/7 自动监控阿里国际站 OneTalk 卖家消息中心：买家询盘进来 → 自动识别意图 → LLM 或规则引擎生成回复 → 发送 → 去重；货物信息齐了自动推送到你的企业微信提醒报价。专为**跨境物流/货运代理**业务设计（中美专线、海空运、DDP 门到门、FBA 头程等）。

> **告警出口（2026-09-26 变更）**：推送出口已从"`wecom-connector` 的本地长连接桥"迁到 **dsh-im 主动投递 HTTP 接口**（`POST /api/dsh-im/delivery/messages`）。原因是该长连接桥与 dsh-im 插件会抢同一个企微机器人（`exit_on_kicked_offline`）而互相顶下线。旧桥代码保留在仓库中但**不再被自动拉起**；见下文「企微通道」一节。

> English: An automated reply system for Alibaba.com OneTalk seller messages, built for freight-forwarding businesses. It monitors buyer inquiries 24/7, replies via a DeepSeek LLM with a rule-engine fallback (19 scenario branches), and pushes quote-ready reminders to WeCom. As of 2026-09-26 the push outlet is the **dsh-im proactive-delivery HTTP endpoint** rather than the legacy local WebSocket bridge (the bridge and the dsh-im plugin competed for the same WeCom bot and kicked each other offline).

---

## ✨ 特性

| 能力 | 说明 |
|---|---|
| 🔄 **24h 自动监控** | CDP 控制 Chrome 登录 OneTalk，主循环实测 **~9 秒/轮**（页面正常时；`Start-Sleep 12` 为上限，含自愈动作会拉长），断线自动自愈（分级：软刷新 → `chrome_ensure` 重启 Chrome + 自动登录），登录态独立 profile 持久保存 |
| 🔌 **Accio 读取增强（可选）** | 官方 Accio Desktop 本地网关只读拉取全量历史（无 30 天墙）；影子对比 → 读取开关灰度，任何失败自动回退 CDP；发送保持 CDP（未启用） |
| 🤖 **双引擎回复** | DeepSeek LLM 生成自然回复（意图识别 + 质量红线 + 发送前禁词/责任承诺双检）；LLM 失败/超时自动回退规则引擎（19 类场景） |
| 🌍 **多语言买家** | 中/英/西/葡/法买家消息识别，统一美式英文回复 |
| 📦 **信息收集** | 自动追问缺失货物信息（总重/尺寸/图片/收货地址），同字段最多追问 2 次，买家承诺提供后不再追问 |
| 📱 **企微告警推送** | 出口为 **dsh-im 主动投递**（`POST 127.0.0.1:<dsh-host-port>/api/dsh-im/delivery/messages`，字段严格为 `botId`+`targetId`+`text`）；推送出口统一收敛在 `scripts\lib\wecom.ps1` 一处，7 个调用点共用；数据齐全（重量+尺寸+地址）实时推送（24h 节流） |
| 🎛️ **自然语言远程控制** | 企微发任意自然语言指令，`control-agent` 经 owner 校验 + 确认闸门后派发外部执行 agent 执行并回发结果 |
| 📊 **质量闭环** | 每日质量报告 → 规则自动提炼（40 条上限 + 阈值自动合并）→ 周报（含国别分布）+ 沉睡买家唤醒；**质量报告/周报生成后自动推企微摘要**（统计+重点项+文件名，可开关） |
| 🖼️ **附件识别** | 买家图片/文档（PDF/Excel/CSV/Word）自动识别：图片走视觉多模态、文档解析文本或渲染扫描件；明确可见的重量/尺寸/箱数/单号机会性提取入货物档案（带来源标记，不臆造） |
| 📈 **数据看板** | `dashboard.ps1` 手动生成无 PII 的 HTML 聚合看板（回复量/LLM 成功率/来源分布） |
| 🧩 **组件可复用** | `wecom-connector`（HTTP 桥）与 `control-agent`（远程控制桥）独立成目录、独立测试 |
| 🛡️ **安全设计** | 凭据唯一文件（`credentials.md`）、目录隔离、`status.ps1` 敏感审计、`pre-commit/pre-push` 扫描、PII 仅存本机 |
| 🔍 **买家档案** | 自动抓取买家国家/注册时间，注入 LLM 上下文个性化回复 |
| 🔕 **人工接管白名单** | 企微发"白名单 添加 <客户名>"即不再自动回复该客户：只读留快照+新消息提醒，报价/唤醒免打扰，移出即恢复 |

## 🏗️ 架构

```
┌──────────────────────────────────────────────────────────────┐
│ monitor.ps1 (常驻, ~9s/轮)                                    │
│  抓待回复列表 → 打开会话 → 提取消息(1000字符) → 去重(hash+TS)   │
│   → Test-PageHealth(页面判据) → LLM/规则引擎 → 发送校验         │
│   → 买家档案 / 报价提醒 / 告警                                  │
└──────┬──────────────────────────────────────────┬───────────┘
       │ CDP(9222)                                │ HTTP(推送出口)
┌──────▼───────┐   ┌──────────────┐   ┌───────────▼────────────────┐
│ Chrome        │   │ DeepSeek     │   │ lib\wecom.ps1               │
│ (独立 profile)│   │ LLM API      │   │  Send-WecomMessage(唯一出口) │
│  OneTalk 页面 │   │ (无 key 落盘)│   │   7 个调用点共用             │
└──────┬───────┘   └──────────────┘   └───────────┬────────────────┘
       │ CDP 探针(Test-PageHealth)                 │ POST /api/dsh-im/delivery/messages
       │                                          ▼
       │                            ┌──────────────────────────────┐
       │                            │ DSH Host (本机 127.0.0.1)     │
       │                            │  dsh-im 插件 → 企微长连接     │
       │                            └──────────────────────────────┘
       │
┌──────▼──────────────── watchdog.ps1 (30s) 五重守护 ────────────────┐
│ ① monitor 进程  ② 日志新鲜度(240s)  ③ CDP 兜底(chrome_ensure)      │
│ ④ 企微保活(wecom_start.ps1) —— **已加交接门**：交接标记存在且新通道  │
│    宿主在 ⇒ 主动让路、连 spawn 都不做（避免把 dsh-im 顶下线）        │
│ ⑤ control-agent 保活(agent_start.ps1)                              │
└───────────────────────────────────────────────────────────────────┘
┌────────────── control-agent (Node 常驻, 由 watchdog 保活) ─────────┐
│ 企微消息 → owner 校验 → 60s 节流 → 确认闸门 → 外部执行 agent → 回发 │
└─────────────────────────────────────────────────────────────────────┘
```

**页面判据（2026-09-26）**：`Test-PageHealth` 的判定抽成纯函数 `Get-PageHealthVerdict`，新增**可见性维度**——
`.status-tip` 的"网络连接已经断开"文案在**重连成功后仍残留在 DOM**，但此时容器 `.connection-status-container`
被父级压成 `offsetHeight=0`（自带 `overflow:hidden`）。旧判据只看文案 ⇒ 业务可用却恒判 `PageDown=True`
（实测导致每 10 分钟无谓重启一次 Chrome）。现改为"文案在**且**容器可见"才判 down，探针缺该字段时退回旧行为。

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
| `scripts\config.json`（由 `.example` 复制） | 集中路径配置（换机只改它）+ `cdp_port` + `report_push_enabled`（报告推送开关，缺省 true）+ Accio 开关 `accio_shadow` / `accio_read_enabled` / `accio_send_enabled`（缺省全 false）+ **告警出口 `dshim_delivery_url` / `dshim_bot_id` / `dshim_target_id`**；经 `scripts\config.ps1` 统一读取 |
| `scripts\reply_rules.json` | 语料库：品牌/价格准则/收集字段/模板/规则（编辑后立即生效） |
| `scripts\reply_agent_prompt.md` | LLM 提示词：意图识别 + 质量红线（编辑后立即生效） |
| `llm_config.json` | LLM 非敏感配置（model=`deepseek-v4-flash` / temperature / max_tokens / timeout / endpoint / `thinking:disabled`，**不存 key**） |
| `data\alert-channel.handover.json` | **告警通道交接标记**（存在 ⇒ 旧企微长连接保活让路；删除即回滚到旧通道，见上节） |
| `tools\wecom-connector\config.json` | HTTP 桥 host/port/数据目录（凭据走环境变量注入）；**2026-09-26 起默认不再被自动拉起** |
| `tools\control-agent\config.json` | owner/projects/executor/节流等（`owner_userid` 留空首条消息自动锁定） |

## 🧠 工作原理

**自动回复闭环**（实测 ~9 秒一轮）：切"待回复"标签 → 抓列表 → 逐会话（一次 CDP eval 完成打开+会话名校验+消息提取）→ 页面判据 `Test-PageHealth` → 去重（消息 hash+时间戳 vs `state.json`，已回复进递增冷却）→ 生成回复（LLM 优先，失败回退规则引擎）→ 发送（原生 setter + 清空校验）→ 数据齐全检测 → 经 `lib\wecom.ps1` 推送报价提醒。

**分级自愈**：页面判据为 down 时先软刷新（`reload_idle_min` 空闲才动），连续多轮才升级到
`chrome_ensure.ps1 -ForceRestart`（按 profile 精确匹配重启 Chrome → navigate 回 OneTalk → 自动登录 → 等数据面恢复）。
升级阈值递增（3 → 6 → 12 轮）、每次重启后有 **10 分钟静默期**、并设**硬上限 4 次**；
达上限后只告警、停止自动重启（`PAGE-HEAL-ALERT-ONLY`）。
> 这些节流参数由真实事故倒推而来：早期"验证窗口 25s + 升级周期 90s"会导致**每 90 秒掐断一次正在握手的 IM 长连接**，17 次重启全部无效。

**规则引擎 19 类场景**：指责不读/拒绝/感谢/简短确认/问 AI/问候/稍后回来/联系方式/流程/计费/时效/电池合规/砍价/比价/无供应商/信息提供/地址/查件/默认追问——实现见 `scripts\reply_engine.ps1`，分支清单见 `SKILL.md` 或测试 `tests\reply_engine.tests.ps1`（119 断言）。

**质量闭环**：05:00 质量报告（`analyze_replies.ps1`）→ 05:30 LLM 自动提炼（`auto_optimize.ps1`，精确去重 + never 保留最新 40 条 + 阈值自动调用 `consolidate_prompt.ps1` 合并归档）→ 次日报告对比；周报（周一 08:00，含国别分布 + nudge 唤醒）。

## 📱 企微通道与远程控制

自 2026-09-07 起企微能力由两个独立可复用组件提供（旧六命令轮询体系已退役归档）：

- **wecom-connector**：Node 常驻，官方 WebSocket 长连接，HTTP 桥 `127.0.0.1:19886`（`/health /send /messages /cursor /receiver /status`）；多消费者游标持久化；凭据仅环境变量注入；自带测试 63 例（node 46 + PS 17）。详见 `tools\wecom-connector\README.md`。
  ⚠️ **自 2026-09-26 起其保活被"交接门"阻断**（见下节），`19886` 默认不再监听。
- **control-agent（由 watchdog 保活）**：企微自然语言指令 → owner 校验 → 节流 → 确认闸门（白名单文件免确认、高风险回发 4 位确认码）→ 外部执行 agent（默认 dsh）→ ≤200 字回发；测试 46 例。保活：watchdog 每 30s 幂等调用 `scripts\agent_start.ps1`（启动失败 5 分钟冷却）；手动停用用 `bin\control-agent.ps1 -Action stop`（建停用标记 `data\control-agent.disabled`，保活跳过），`-Action start` 恢复。详见 `tools\control-agent\README.md`。

## 🔀 告警推送出口与"交接门"（2026-09-26）

**事故背景（实测）**：`wecom-connector` 的官方长连接与 **dsh-im 插件**接入的是**同一个企微机器人**，而旧桥配置 `exit_on_kicked_offline: true` ⇒ **谁后连谁把对方顶下线**。实测互踢时间线：旧桥 `AUTH-OK` → 87 秒后被 `KICKED-OFFLINE`；watchdog 每 30s 再把它拉起来，如此往复。更严重的是旧启动器在一次拉起中**悬死 17 分钟**，把 watchdog 的五重守护整体堵停。

**解法（两层）**：

1. **交接门**（`scripts\wecom_start.ps1` + `scripts\watchdog.ps1` 各一道，语义一致）：
   若**交接标记** `data\alert-channel.handover.json` 存在**且**新通道宿主（`DSH Desktop` 进程）在 ⇒ **主动让路**，
   watchdog 连 spawn 都不做。标记不存在或宿主不在 ⇒ 退回原行为（继续保活，**绝不静默失守**）。
   逃生门：设环境变量 `WECOM_FORCE_RUN=1` 可强制恢复旧行为。
   > 设计原则：**只有"新通道宿主真的在"才敢停旧通道**；任何不确定一律退回旧行为。
2. **推送出口迁移**：`scripts\lib\wecom.ps1::Send-WecomMessage` 的内部实现改为调用 dsh-im 主动投递 HTTP 接口。
   **函数名与返回码契约保持不变**（`SENT_OK` / `SERVICE_DOWN` / `NO_RECEIVER` / `SEND_ERROR`），
   因此 `health_check.ps1` / `monitor.ps1` / `watchdog.ps1` / `lib\quote.ps1` / `lib\report_push.ps1`
   这 **7 个调用点一行都不用改**。配置项：`dshim_delivery_url` / `dshim_bot_id` / `dshim_target_id`。

**接口契约（实测，写代码前请复核）**：

```bash
curl -X POST http://127.0.0.1:<dsh-host-port>/api/dsh-im/delivery/messages \
  -H 'Content-Type: application/json' \
  --data '{"botId":"<botId>","targetId":"<targetId>","text":"消息内容"}'
# 成功: {"sent":true}
```

| 现象 | 含义 |
|---|---|
| `405` + `allow: POST` | 接口活着，只收 POST（可用作探活） |
| `404 unknown-bot` | `botId` 不对（须与 dsh-im 设置页"调用标识"一致） |
| `404 unknown-target` | `targetId` 未配置（在 dsh-im 设置里"新建目标"并保存） |
| `400 bad-request` | 字段**必须恰好**是 `botId`+`targetId`+`text`（可选 `format`）——**多一个键也会 400** |

> ⚠️ **编码铁律**：PowerShell 5.1 的字符串 body 会按 GBK 编码 ⇒ 中文乱码。
> 必须显式转 UTF-8 字节再发送：`[System.Text.Encoding]::UTF8.GetBytes($body)`。
> ⚠️ 该 HTTP 接口**不包含鉴权**（官方文档明示），只应在本机使用，**不要暴露到公网**。

## 📵 人工接管白名单（不自动回复客户）

企微向机器人发指令（owner 专属）：`白名单 添加 John Smith` / `白名单 列表` / `白名单 删除 John Smith`（≤10s 生效）。

- **行为**：名单买家新消息不触发任何自动回复（LLM/规则/图片模板/QUICK 全跳过）；只读留痕（快照 + 档案）并照常 [NEW-INQUIRY] 提醒人工接管。
- **联动**：报价提醒与沉睡唤醒对名单买家跳过；豁免期不写去重状态，移出后自动恢复。
- **存储**：`data\manual_override.json`（本机 PII 不入库）；按会话显示名匹配（大小写/空格/下划线容错）。

## 🔌 Accio 网关（可选，读取增强）

官方 **Accio Desktop**（阿里国际站桌面端）在 `localhost:4097` 暴露本地 IM 网关，可只读拉取全量历史（无 30 天墙）。系统把它作为**可选的读取增强数据源**，CDP 永远是主路径与降级通道：

- **影子模式**（`accio_shadow=true`）：处理会话时并行对比网关历史与 CDP 提取（`ACCIO-SHADOW` 日志：条数/最新文本/时间戳/覆盖率），不改任何行为
- **读取开关**（`accio_read_enabled=true`）：LLM/规则上下文优先用网关全量历史（日志 `ACCIO-READ src=gateway`）；内容重叠校验失败或网关不可用自动回退 CDP（`ACCIO-READ src=cdp`）；去重/最新消息基准仍取 CDP，保证零行为突变
- **发送开关**（`accio_send_enabled`，默认关）：网关发送通道已实现（双边 receiverAliID + 回读验证约定），需用户指定测试会话验证后才启用；当前保持 CDP 发送
- **组件**：`tools\accio-client`（Node 零依赖 CLI，自研协议实现 + fake gateway 测试）；适配层 `scripts\lib\accio.ps1`；登录自启：启动文件夹快捷方式 `Accio Desktop.lnk`
- **凭据纪律**：只读 `%USERPROFILE%\.accio\accounts\*\...\gateway-cli.json`（每次调用重读），鉴权值不落日志/仓库

## 🛡️ 安全

- **敏感信息铁律**：账号/密码/API key/机器人凭据只存在于 `credentials.md`；`status.ps1` 自动审计，`.githooks`（pre-commit/pre-push）自动扫描拦截。
- **目录隔离**：`logs\`（运行日志）/ `data\`（快照与档案，含 PII 仅本机）/ `reports\`（聚合报告）/ `backups\`（代码快照，不含凭据）/ `specs\`（设计与执行记录，含绝对路径 ⇒ 已 gitignore）。
- **凭据通道**：企微凭据经环境变量注入组件进程，config/代码/日志均不落盘。
- **仓库安全**：凭据、登录态、买家数据、运行状态全部 gitignore；配置以 `.example` 模板公开。
- **发布前扫描器**（`.githooks\sanitize_check.ps1`）：文件名/目录黑名单 + 内容阻断模式（key/密码/webhook/本机绝对路径/本机用户名）+ PII 警告；**退出码 1 = 阻断提交/推送**。
  扫描器自身文件被豁免（它必须包含这些模式的定义行）；`*.json.example` 亦豁免（占位模板）。
- **推送后的历史核查**：泄漏是永久的 ⇒ 发布后应扫**全部历史**而非只看本次 diff：
  ```powershell
  git log --all --pretty=format: --name-only --diff-filter=ACMRT | Sort-Object -Unique   # 历史文件名
  git rev-list --all | ForEach-Object { git show "$_`:path" }                            # 历史内容抽检
  ```

## 🔧 常见问题（真实踩过的坑）

| 症状 | 真实原因 | 处置 |
|---|---|---|
| 告警推送一直 `SERVICE_DOWN` | 出口仍指向已停用的 `127.0.0.1:19886` | 确认 `config.json` 的三个 `dshim_*` 键；`Test-WecomService` 应返回 True |
| 推送 `404 unknown-target` | dsh-im 里没建投递目标，或目标被改名/删除 | 在 dsh-im 设置页"新建目标"并保存，把新的 `targetId` 写回配置 |
| 推送 `400 bad-request` | 请求体多/少字段（接口用严格等值校验） | 只发 `botId`+`targetId`+`text`（可选 `format`） |
| 推送内容中文乱码 | PS 5.1 字符串 body 按 GBK 编码 | 显式 `[System.Text.Encoding]::UTF8.GetBytes($body)` 再发送 |
| 企微机器人在两个程序间反复掉线 | 两个进程抢同一机器人 + `exit_on_kicked_offline` | 只保留一个出口；本项目用 `data\alert-channel.handover.json` 交接标记 |
| 改了 `lib\cdp.ps1` 但行为没变 | `monitor.ps1` 只在启动时 dot-source 一次 | **必须重启 monitor** 才生效；`watchdog.pid`/`monitor.pid` 都要 `Get-Process -Id` 复核（pid 文件可能是陈旧的） |
| 改完 `.ps1` 后中文全失效/判据恒真 | 编辑工具**剥掉了 UTF-8 BOM** ⇒ PS 5.1 按 ANSI 解码 | 复验前三字节是否 `239,187,191`，丢了就用 `UTF8Encoding($true)` 写回 |
| 看进程数发现"两个 watchdog" | 命令自身的命令行里含 `watchdog\.ps1`，被 `Where-Object` 自匹配 | 排除自身 PID，或匹配 `-File .*watchdog\.ps1` 而非裸文件名 |
| 守护进程"自己消失"且无日志 | 从代理/脚本会话直接建进程会被回收；或控制台被关闭（`0xC000013A`） | **常驻守护只走计划任务**：`Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'` |

## 📁 目录结构

```
alibaba-auto-reply/
├── credentials.md            ← 敏感信息唯一文件（不入库）
├── llm_config.json           ← LLM 非敏感配置
├── README.md                 ← 本文件
├── README_部署说明.md        ← 部署与运维手册
├── SKILL.md                  ← agent 技能定义（opencode 镜像同步对象）
├── docs\
│   ├── CHANGELOG.md          ← 版本变更记录
│   ├── BrowserSkill使用约定.md ← BrowserSkill CLI 接入铁律（7 条）
│   └── 外贸主动获客系统_*.md  ← 主动获客（Leadgen）设计文档
├── .githooks\                ← pre-commit / pre-push 敏感扫描（sanitize_check.ps1）
├── clean-c\                  ← C 盘可再生产物清理（普通版 + 管理员版）
├── scripts\                  ← 主代码 + 状态 + 规则
│   ├── monitor.ps1           ← 监控主程序（全自动闭环，单实例）
│   ├── reply_engine.ps1      ← 规则回复引擎（纯逻辑，可单测）
│   ├── health_check.ps1      ← 健康心跳（计划任务 15 分钟；含 watchdog 自动拉起）
│   ├── reply_rules.json      ← 语料库/模板（可热编辑）
│   ├── reply_agent_prompt.md ← LLM 提示词（可热编辑）
│   ├── config.ps1            ← 配置加载器（Get-SkillPath/Get-CdpPort）
│   ├── config.json.example   ← 路径配置模板
│   ├── chrome_ensure.ps1     ← Chrome 自愈 + 自动登录（按 profile 精确匹配）
│   ├── cdp.ps1 / lib\cdp.ps1 ← CDP 桥接（navigate/eval）+ 页面判据 Test-PageHealth
│   ├── watchdog.ps1          ← 五重守护（进程/日志/CDP/企微/control-agent 保活 + 交接门）
│   ├── wecom_start.ps1       ← 企微保活启动器 v3（幂等三段 + **交接门**）
│   ├── agent_start.ps1       ← control-agent 保活启动器（幂等，停用标记感知）
│   ├── status.ps1            ← 一键健康检查（含敏感审计）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 报告/质量/规则提炼
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报/唤醒/报价提醒
│   ├── log_rotate.ps1 / retention.ps1 ← 日志轮转 / 快照保留（90 天归档）
│   ├── dashboard.ps1         ← 数据看板（手动工具）
│   ├── state.json(+bak)      ← 已回复去重状态
│   ├── okki\                 ← 小满 CRM(OKKI) 链路：CDP(9223)/登录/商机建档
│   ├── waimao\               ← 网易外贸(王野)CDP 桥(9224) + 只读侦察
│   └── lib\                  ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom/no_reply/vision/doc/report_push/accio/alert_local/deadman）
├── tools\                    ← 独立可复用组件（各自依赖与测试）
│   ├── wecom-connector\      ← 企微 HTTP 桥（Node，63 例测试；**保活已由交接门阻断**）
│   ├── doc-reader\           ← 买家文档解析（PDF/xlsx/csv/docx → 文本或渲染图，node --test）
│   ├── accio-client\         ← Accio 网关只读客户端（Node 零依赖，14 例 + shadow_compare.ps1）
│   ├── control-agent\        ← 企微自然语言远程控制桥（Node，46 例测试）
│   ├── email-verify\         ← 邮箱可投递性验证（MX/SMTP 探测，Node 零依赖）
│   └── status-verify\        ← 状态核实工具（verify_all.ps1）
├── tests\                    ← 主仓库回归测试（14 文件 390 断言，fixtures 虚构数据）
├── logs\  data\  reports\  backups\   ← 运行时数据（均不入库）
└── chrome-profile\           ← Chrome 登录态（独立 profile，勿删除）
```

## 🧪 开发与运维

```powershell
# 主仓库回归测试（14 文件 390 断言，实测全绿）
# 分布：accio 29 / daemon_launch 10 / env_block 12 / goods 27 / lock 11 / log_maintenance 22 /
#       no_reply 29 / page_heal_throttle 15 / page_health 15 / page_health_verdict 10 /
#       page_select 15 / reply_engine 119 / report_push 33 / vision 43
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1

# 单跑某个测试文件（更快，便于定位）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\page_health_verdict.tests.ps1

# tools 组件测试
powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\tests\run_tests.ps1   # 63 例
powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\tests\run_tests.ps1     # 46 例
node --test tools\doc-reader\tests\read.test.js                                                 # 7 例
node --test tools\accio-client\tests\gateway.test.js tools\accio-client\tests\api.test.js      # 14 例

# 代码快照 / 镜像同步 / 健康检查
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\sync.ps1 -Status   # 或 -Push
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1

# 日志轮转 / 快照保留（DryRun 只报告不动文件；monitor 启动时也会自动执行一次）
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\log_rotate.ps1 -DryRun
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\retention.ps1 -DryRun

# 发布前脱敏自检（与 pre-commit / pre-push 同款扫描器）
powershell -ExecutionPolicy Bypass -NoProfile -File .githooks\sanitize_check.ps1 -Mode staged
```

> ⚠️ **本机环境注意（Windows + Restricted 执行策略）**：`.ps1` 一律用
> `powershell -ExecutionPolicy Bypass -NoProfile -File <路径>` 调用；`npm` 需用 `npm.cmd`（`npm.ps1` 会被策略拦下）。

**守护加固（2026-09-18 P0）**：Watchdog/Health 任务 `StopOnIdleEnd=false`；Health 发现 watchdog 死亡时自动拉起（`HEALTH-HEAL pid=<new>`，30 分钟节流）；去重判定改为 ts 归一化（`Test-AlreadyReplied`）+ 发送后 3 分钟冷却；死信心跳 `deadman_ping_url`（healthchecks.io，仅 ping 无 PII，默认空=不发）。

**计划任务（自动运维，见部署手册注册）**：Summary（每 4h 总结）、Quality（每日 05:00 质量报告）、Optimize（每日 05:30 规则提炼）、Weekly（周一 08:00 周报 + nudge）、Watchdog（登录自启，常驻守护）、Health（每 15 分钟健康心跳 + 自动拉起 watchdog）。

> ⚠️ **Watchdog 任务只有"登录自启"触发器**（无时间触发器）⇒ 机器重启后若无人登录，守护不会自动起来。
> 另：重启 DSH Desktop 可能连带终止 watchdog（控制台关闭事件，`0xC000013A`），
> 之后用 `Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'` 补拉即可（让 watchdog 自己去拉起 monitor）。

## 📄 License

MIT
