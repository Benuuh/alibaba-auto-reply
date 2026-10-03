---
name: alibaba-auto-reply
description: 监控阿里询盘、自动回复买家消息、分析阿里买家、配置回复语料库、检查监控健康状态时使用——阿里国际站(Alibaba OneTalk)卖家消息自动监控与回复技能：登录卖家账号、监控询盘、意图分析、按语料库自动回复并收集货物/收货人信息。
license: MIT
compatibility: opencode
metadata:
  platform: win32
  chrome: required
  workflow: monitor
---

# 阿里国际站自动回复 (Alibaba OneTalk Auto-Reply)

CDP 控制本机 Chrome 登录 OneTalk 卖家消息中心：监控询盘、按语料库自动分析回复、收集货物/收货人信息。5 个入口分支：

| 分支 | 触发词 | 流程 |
|------|--------|------|
| 监控询盘 | "监控阿里询盘" | A |
| 自动回复 | "自动回复买家消息" | A |
| 分析买家 | "分析阿里买家/买家档案" | D |
| 配置语料库 | "配置回复语料库/改回复规则" | C |
| 健康检查 | "健康检查/监控状态" | B |

## A. 监控与自动回复（默认入口）
- A1 运行确认：`scripts\monitor.pid` 存在且 `logs\monitor.log` <90s 有 `Scan cycle done`；不满足走 A2。
- A2 启动：用文末启停命令（Hidden+重定向）；完成标准=`=== Monitor started` + 30s 内首个 `Scan cycle done`。
- A3 自动循环：每 12s 扫描待回复板块 → 打开会话 → 提取消息 → 意图识别/缺口核对 → 生成回复 → 发送 → 去重。成功=`REPLIED ... SENT_OK`；`RETRY-QUEUE`=发送失败进冷却重试，等待即可。附件：图片走视觉多模态、文档（PDF/xlsx/csv/docx）解析文本或渲染扫描件，失败回退 IMG_TEMPLATE/普通文本流程；明确可见的重量/尺寸/箱数/单号机会性提取入 `data\vision_extract\<buyer>.json`（不臆造）。
- A4 回复依据：`scripts\reply_rules.json`（规则/字段/模板）+ `scripts\reply_agent_prompt.md`（LLM 提示词，改后立即生效）；规则引擎见 `scripts\reply_engine.ps1`。
- A5 新询盘提醒：新买家首次出现自动推企微（24h 节流）；`SERVICE_DOWN`/`SEND_FAIL` 只记日志不影响回复。
- A6 Accio 读取增强（可选）：`accio_read_enabled=true` 时回复上下文优先用 Accio 网关全量历史（无 30 天墙），失败/内容不匹配自动回退 CDP（日志 `ACCIO-READ src=gateway|cdp`）；`accio_shadow` 影子对比（`ACCIO-SHADOW`）；开关在 `scripts\config.json`，改后需重启 monitor；发送（`accio_send_enabled`）未启用。

## B. 健康检查与维护
- B1 `scripts\status.ps1`：无 `[!!]` 且敏感审计 `[OK]`。
- B2 守护与任务：`watchdog.ps1` 运行中（30s 检查，**三重守护：进程/日志/CDP**；另有 Accio 轻量探测，网关不可达记 `WATCHDOG-ACCIO` 日志）。计划任务 5 项：Summary/Quality/Optimize/Weekly（Ready）+ Watchdog（登录自启 + **每分钟重复触发**，常驻 Running；`watchdog_process` 判据为 **pid 存活 + TimeTrigger/PT1M**，仅登录触发一律 FAIL）。**Weekly 自 2026-09-26 起改为每日 08:00 + `StartWhenAvailable` 补跑**（原"每周一 08:00"在关机时整周消失），由 `data\weekly_state.json` 按 ISO 周键保证一周只真跑一次（其余触发输出 `WEEKLY-SKIP`、不重复生成也不重复 nudge）。**⛔ 启守护一律 `Start-ScheduledTask -TaskName 'AlibabaAutoReply*'`，禁止 `Start-Process`**（从代理会话用 WMI/`Start-Process` 启动的常驻进程会被回收 —— `docs\KNOWN_EXCEPTIONS.md` E-12；`-RedirectStandard*` 在本机必抛 —— E-18）。**2026-09-26 收口已物理移除**：两套退休告警桥 `tools\wecom-connector\`、`tools\control-agent\`，连带启动器 `scripts\wecom_start.ps1`（守护原第四重"企微保活"）与 `scripts\agent_start.ps1`（control-agent 保活）⇒ 守护为**三重**，**告警只剩 dsh-im 单通道**（`DSH Desktop` 未运行时哑火属已知风险）；企微远程控制能力由 **DSH agent** 承担。复活路径见 `docs\KNOWN_EXCEPTIONS.md` **E-24**（原 E-20 已改写指向 E-24；`control-agent` 复活必须先接 dsh-im 新通道并清掉 `owner_userid` 占位符）。
- B3 镜像：`scripts\sync.ps1 -Status` 无 DIFFERS/ONLY-WORK，否则 `-Push`；镜像目录 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`。
- B4 发布：`backup.ps1 -Snapshot` → 改代码（UTF-8 BOM）→ `status.ps1` → `sync.ps1 -Push` → git commit/push（`.githooks\` 自动脱敏，[BLOCK] 必须整改，禁止 `--no-verify`）→ 观察 24h；改 `monitor.ps1` 需低询盘时段重启。

## C. 配置语料库
- C1 编辑 `scripts\reply_rules.json`（品牌/价格/`data_to_collect`/`templates`/`reply_rules.always|never`）与 `scripts\reply_agent_prompt.md`（意图+质量红线）；JSON 需 `ConvertFrom-Json` 通过；改后立即生效。
- C2 验证：参照 `tests\reply_engine.tests.ps1` 或最近快照跑意图分支；自动追加受 40 条上限与阈值合并保护（`consolidate_prompt.ps1`）。

## D. 分析买家
- D1 读取：会话列表 `.contact-item-container`；消息 `[class*=message]`（[买家]带"由阿里翻译提供"）；档案 `.alicrm-customer-detail-card`（国家/注册时间/标签）。
- D2 齐全度：对照 `data_to_collect`（重量/尺寸/图片/地址/供应商）标记；齐全（重量+尺寸+地址）→ 提示人工报价（不自动报价）。

## E. 公海客户开发（⚠️ 对外发消息，动作不可逆）
> **前置**：`gonghai_enabled=true`；公海跑在**自己的 Chrome**（`gonghai_cdp_port`，现役 **9225** + `chrome-profile-gonghai`）且已登录 ——
> **不再与自动回复共用 9222**（共用会抢页面，见 `docs\specs\公海独立Chrome_20260927.md`）；起实例：`gonghai_ensure.ps1`。
> 脚本见 `scripts\gonghai\`。**认领会占用客户名额且不可逆（能否退回公海未知）**，务必逐个确认。
- E1 只读侦察（零写入）：`gonghai_recon.ps1 -Action install` → 在页面上手工操作 → `-Action dump`；
  改过钩子实现后必须加 `-ForceReinstall`（否则旧闭包仍在）。请求体已做凭据擦除（`chatToken`/`_csrf`）。
- E2 单步演练（推荐先跑）：`gonghai_probe.ps1 -Count 1 -DoClaim -DryRun` —— 走完全部判定与定位，**不点击不发送**。
- E3 试发：`gonghai_probe.ps1 -Count 1 -DoClaim`（`-Count` 上限被硬夹到 **10**；`-Loop` 才在单进程内连发）。
  判定链顺序固定：`disabled` → 当日配额 → 幂等键 → 限速门 → 写锁 → 页面健康 → 风控 → 认领 → 搜索 → **发对人校验** → 发送 → 恢复。
- E3b 批量（老板常用入口）：`gonghai_batch.ps1 -Batch 10` —— 读公海列表 → 逐个认领 → 等索引同步 → 逐个搜索/核对身份/发送；
  `-DryRun` 只认领不发（⚠️ 加 `-SkipClaim` 也不会绕过这道闸）；`-SkipClaim` 跳过认领直接发当前页这批（仅用于已认领客户）；
  `-SyncBudgetSec 240` 是**索引同步预算**（正常 10/10 只要 ~135s；超预算的 straggler 转待办队列，批次不再为 1 个人干等 8 分钟）。
  **配额**：单次 ≤10 条由代码强制；**每日总量已取消**（`gonghai_daily_cap` = 0 = 不限，0/负数 = 不限、正数 = 上限）；
  **最小间隔也已取消**（`gonghai_min_interval_ms` = 0 = 不间隔，老板 2026-09-27 深夜裁决；写回正数即恢复 90s±30% 节奏）。
  ⚠️ 间隔取消后**风控闸就是唯一的主动止损**：`Get-GonghaiRiskSignal`（验证码/滑块/"操作过于频繁"）在 batch 的**认领逐行 + 发送逐条**都探，命中即 `ABORT RISK_SIGNAL` + `exit 9`。
- E3c **唯一发送窗口**（2026-09-27 收敛）：取锁 → 开搜索结果（按 `customerId` 挑人） → 核对身份 → 先写后发 → 发送 → 恢复页面 → 释放锁，
  **实现在 `gonghai_lib.ps1::Invoke-GonghaiSendWindow` 一份**，batch 与 probe 都只调它（此前各写一份 ⇒ 一处 fail-open 一处 fail-closed）。
  硬约束不变：**核对与发送必须在同一个写锁窗口内**；窗口内不等待、不搜索、不取页。
- E3d **连续跑**（老板常用节奏）：`gonghai_loop.ps1 -Target 200 -MaxRounds 40` —— 把"每批 10 个"串起来跑到当天达标。
  内含三条纪律（都是 2026-09-27 深夜真踩到后固化的）：① **并发闸**（判据含 `-File …batch.ps1` 且不含 `-Command` 以排除调用方自身；
  调用处必须 `@()` 包裹防"单元素解包 ⇒ `.Count` 为 `$null`"；并要求**连续静默 30 秒**才开跑，防撞进别条链路的批间空档）；
  ② **退出码分级**（`exit 1` 列表冻结/认领异常 = 可恢复，重试 3 次；`9` 风控 / `3` 模块闸 / `4` 配额 / `10` 认领上限 = 立即停）；
  ③ 单例锁 `gonghai-loop`（两个 loop 绝不同时跑）。`-DryRunProbe` 可空跑自检。
- E3d **待办队列**（2026-09-27 新增）："认领了却没发成功"的人自动进 `data\gonghai\pending.json`（键 + 明文名 + 原因）；
  补发：`gonghai_probe.ps1 -RetryPending [-Count N]`。原因取 `INDEX_NOT_SYNCED`（阿里索引没建成）/`NO_CARDID`/`NOTSENT`。
  ⚠️ 明文名只落运行数据根（与 `data\buyers\` 同级、不入库），日志/镜像仍只有代号。
- E3e **只读体检**：`tools\gonghai_doctor.ps1 -Action state|mine|search|pane`
  （页状态 / 我的客户反查代号↔人 / 复现搜索链 / 回读会话正文核验消息是否真发出；后两个会持锁但**从不发送**）。
- E3f **定向补发待办队列**（[2026-09-29 实测 42/51 = 82%]）：`tools\gonghai_recover.ps1 [-DryRun] [-Reasons ...]`
  只补**"我们没发成功"**那几类（`LOST_AFTER_ABORT` / `WRONG_CONVO` / `NOTSENT` / `NO_CARDID`），
  **故意排除 `INDEX_NOT_SYNCED`**（阿里侧没建索引，实测 27 条 0 成功 ⇒ 只取样判断、不成批跑）。
  ⚠️ 跑前必须**停链路**（同一个 9225 页面不能并发用）；链路自带的轮转补发是"每 5 轮 2 条"，覆盖全队列要十几小时，本工具用来立刻把可救的捞回来。
- E4 **关键时序**：认领后 OneTalk 索引有同步延迟（实测约 1 分钟）⇒ 立刻搜索会得 0 结果，
  **不要据此判定"路径不通"**。`gonghai_probe.ps1` 已内置 6 次重试；手工核对时请等待后重试。
  ⚠️ 少数客户（实测 ~3%）**始终**搜不到（阿里侧索引没建成，等 1.5 小时也一样）⇒ 由待办队列兜住，人工隔时重试。
- E5 **发对人判据**：详情卡 `.alicrm-customer-detail-card` 里的 `customerId` 必须**精确等于**公海行的
  `data-row-key`。不等即 `ABORT_WRONG_CONVO` 停机；**读不到**即 `NO_CARDID` 拒发（两者都**绝不发送**）。
- E6 停用：写 `data\gonghai\disabled` 标记，或把 `gonghai_enabled` 设为 false —— 两者都由 `Test-GonghaiRunnable` 在
  batch/probe **开头**判定（2026-09-27 才真正接上；此前"没有任何脚本读它"）。
- E7 账本：`data\gonghai\sent_index.json` 只存 `key_hash` + 代号（`gh-`+sha1 前 8 位），**不含客户名**（PII 纪律）。
  状态语义：`sent`/`unverified`/`failed` ⇒ 拒发；**`notsent`（可证明没发出去）⇒ 允许重试**。
  **分步手工发送也必须记账**，否则会重发。

## 不该自动回复（先读本节）
1. 买家否定/拒绝（no thanks / not interested / forget it）→ 友好收尾，不发模板。
2. 指责"不读/看不懂"或已读不回 → 道歉确认收到，不再追问。
3. 无新消息（dedup 命中）→ 跳过。
4. 冷却中（TEMP-SKIP）→ 不打开、不发送。
5. 同一字段已问 ≥2 次 → 转等待语气。
6. 买家承诺提供某字段 → 不再追问该字段。
7. 会话名校验不一致（ABORT_WRONG_CONVO）→ 绝不发送。
8. 验证码/风控滑块（`#baxia-dialog-content`）→ 刷新登录页后重填，不反复提交。

## 铁律
### D2 敏感信息
- 账号/密码/API key/企微密钥只存在于 `credentials.md`；`llm_config.json` 禁写 api_key。
- 日志/报告/快照/备份不得出现敏感值；`status.ps1` 自动审计；`backup.ps1` 不含凭据；凭据不进仓库/聊天。

### D3 目录隔离
| 目录 | 内容 |
|------|------|
| `scripts\` | 代码 + 状态(state.json/pid) + 规则 |
| `logs\` | 运行日志 |
| `data\` | 买家快照 + buyers 档案（PII，仅本机）+ 状态文件（`summary_last.json`/`health_state.json`/`weekly_state.json`，非配置键） |
| `reports\` | 质量/总结/周报 |
| `backups\` | 代码快照 zip（不含凭据） |

### PS 5.1 与编码
- 不支持 `? :`/`??`/`||`；脚本必须 UTF-8 带 BOM。
- LLM 必须 HttpWebRequest + StreamReader(UTF8)（`lib\llm.ps1` 已封装，勿改）。
- 长消息提取上限 1000 字符；CDP 端口默认 9222（config.json `cdp_port` 可配）。
- 状态写入用 Hashtable 键赋值，勿 Add-Member。

## 启停命令
```powershell
# ⛔ 启守护/常驻进程：一律走计划任务（E-12：从代理会话用 WMI/Start-Process 启的常驻进程会被回收；
#    E-18：Start-Process -RedirectStandard* 在本机必抛）
Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'   # 拉起 watchdog（它再带起 monitor）
Start-ScheduledTask -TaskName 'AlibabaAutoReplyHealth'     # 需要时由 Health 兜底拉起
# 停 watchdog / monitor：一律按 pid 文件精确停（禁止 -Action stop，历史自杀式匹配缺陷 F6 未修）
$wp=(Get-Content ...\scripts\watchdog.pid -Raw).Trim(); if($wp -match '^\d+$'){ Stop-Process -Id ([int]$wp) -Force }
$mp=(Get-Content ...\scripts\monitor.pid -Raw).Trim(); if($mp -match '^\d+$'){ Stop-Process -Id ([int]$mp) -Force }
# 健康检查 / 快照 / 镜像 / 日志轮转 / 快照保留
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\status.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\sync.ps1 -Status
```
> 单实例：`monitor.pid` 记录 PID；双实例时按 pid 清理。

## 参考文件（按需阅读）
- 规则/字段/模板：`scripts\reply_rules.json`；规则引擎：`scripts\reply_engine.ps1`；LLM 提示词：`scripts\reply_agent_prompt.md`
- 部署/架构/机制/工具：`README_部署说明.md`；企微告警出口：`scripts\lib\wecom.ps1`（实为 dsh-im 投递适配层，名字是历史命名）；告警单通道与复活路径见 `docs\KNOWN_EXCEPTIONS.md` **E-24**（两套退休桥 `tools\wecom-connector\`、`tools\control-agent\` 已物理移除，其 README 已随之删除）
- 报告推送：`scripts\lib\report_push.ps1`（quality/weekly 生成后自动推企微摘要；开关 config `report_push_enabled`；去重 `data\report_push_state.json`）
- 附件识别：`scripts\lib\vision.ps1`（图片/提取/sidecar）、`scripts\lib\doc.ps1`（下载/临时文件）、`tools\doc-reader\README.md`（PDF/xlsx/csv/docx 解析）
- Accio 网关（可选读取增强）：`tools\accio-client\README.md`（Node CLI）、`scripts\lib\accio.ps1`（适配层）、`tools\accio-client\shadow_compare.ps1`（影子对比）
- 质量闭环：`scripts\analyze_replies.ps1`（05:00 质量报告）→ `scripts\auto_optimize.ps1`（05:30 自动提炼）→ `scripts\consolidate_prompt.ps1`（阈值合并归档）
  - 公海客户开发（默认关）：`scripts\gonghai\`（`gonghai_probe.ps1` 试发 / `gonghai_recon.ps1` 只读侦察 / `gonghai_lib.ps1` 限速与幂等）；回归测试 `tests\gonghai.tests.ps1`；设计过程见 `<部署根>-runtime\specs\`（spec + REPORT，不入库）
- 监控机制要点：去重=state.json 消息 hash+时间戳（仅 SENT_OK 记录；ts 归一化判定 `Test-AlreadyReplied`，任一侧 ts 缺失判已回复）；发送后会话冷却与同一买家最小间隔**都走配置键**（`reply_post_send_cooldown_min`/`reply_min_gap_min`，缺省各 5 分钟，日志 `POST-SEND-COOLDOWN`/`RATE-SKIP`），冷却记录带 `until` 字段、**锚在阻塞条件到期的那一刻**（避免"5 分钟冷却 + 5 分钟最小间隔"叠加成 ~9.5 分钟）；"同一条买家消息不重复回"= `Test-BuyerMsgAlreadyAnswered` 把账本事实喂成判据第 2 行入参（`DUP-GUARD-HOLD`，连挂 3 次 `DUP-GUARD-ALERT` 告警），冷却期内预览变化走 `COOLDOWN-RECHECK`→`COOLDOWN-HOLD|LIFT`；防错发=发送前会话名校验；断线自愈=抓列表失败×3 刷新页、CDP 掉线×3 跑 `chrome_ensure.ps1`；按需 reload（idle 10m / busy 30m）；明细见 `docs\specs\判据改为待回复列表_20260927.md` §12
- 守护加固（2026-09-18）：Watchdog/Health 任务 `StopOnIdleEnd=false`；Health 自动拉起 watchdog（`HEALTH-HEAL`，30 分钟节流）；monitor 启动自动日志轮转（`log_rotate.ps1`，logs\archive\）与快照保留（`retention.ps1`，data\archive\msgs_<yyyyMM>.zip）；死信心跳 `deadman_ping_url`（空=不发，health.log 每 6h 一行）
