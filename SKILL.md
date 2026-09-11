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
- A3 自动循环：每 12s 扫描待回复板块 → 打开会话 → 提取消息 → 意图识别/缺口核对 → 生成回复 → 发送 → 去重。成功=`REPLIED ... SENT_OK`；`RETRY-QUEUE`=发送失败进冷却重试，等待即可。
- A4 回复依据：`scripts\reply_rules.json`（规则/字段/模板）+ `scripts\reply_agent_prompt.md`（LLM 提示词，改后立即生效）；规则引擎见 `scripts\reply_engine.ps1`。
- A5 新询盘提醒：新买家首次出现自动推企微（24h 节流）；`SERVICE_DOWN`/`SEND_FAIL` 只记日志不影响回复。

## B. 健康检查与维护
- B1 `scripts\status.ps1`：无 `[!!]` 且敏感审计 `[OK]`。
- B2 守护与任务：`watchdog.ps1` 运行中（30s 检查，五重守护：进程/日志/CDP/企微/control-agent）；计划任务 5 项：Summary/Quality/Optimize/Weekly（Ready）+ Watchdog（登录自启，常驻 Running）。control-agent 由 watchdog 保活（`scripts\agent_start.ps1`，失败 5 分钟冷却）；停用/恢复用 `bin\control-agent.ps1 -Action stop/start`（标记 `data\control-agent.disabled`）。
- B3 镜像：`scripts\sync.ps1 -Status` 无 DIFFERS/ONLY-WORK，否则 `-Push`；镜像目录 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`。
- B4 发布：`backup.ps1 -Snapshot` → 改代码（UTF-8 BOM）→ `status.ps1` → `sync.ps1 -Push` → git commit/push（`.githooks\` 自动脱敏，[BLOCK] 必须整改，禁止 `--no-verify`）→ 观察 24h；改 `monitor.ps1` 需低询盘时段重启。

## C. 配置语料库
- C1 编辑 `scripts\reply_rules.json`（品牌/价格/`data_to_collect`/`templates`/`reply_rules.always|never`）与 `scripts\reply_agent_prompt.md`（意图+质量红线）；JSON 需 `ConvertFrom-Json` 通过；改后立即生效。
- C2 验证：参照 `tests\reply_engine.tests.ps1` 或最近快照跑意图分支；自动追加受 40 条上限与阈值合并保护（`consolidate_prompt.ps1`）。

## D. 分析买家
- D1 读取：会话列表 `.contact-item-container`；消息 `[class*=message]`（[买家]带"由阿里翻译提供"）；档案 `.alicrm-customer-detail-card`（国家/注册时间/标签）。
- D2 齐全度：对照 `data_to_collect`（重量/尺寸/图片/地址/供应商）标记；齐全（重量+尺寸+地址）→ 提示人工报价（不自动报价）。

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
| `data\` | 买家快照 + buyers 档案（PII，仅本机） |
| `reports\` | 质量/总结/周报 |
| `backups\` | 代码快照 zip（不含凭据） |

### PS 5.1 与编码
- 不支持 `? :`/`??`/`||`；脚本必须 UTF-8 带 BOM。
- LLM 必须 HttpWebRequest + StreamReader(UTF8)（`lib\llm.ps1` 已封装，勿改）。
- 长消息提取上限 1000 字符；CDP 端口默认 9222（config.json `cdp_port` 可配）。
- 状态写入用 Hashtable 键赋值，勿 Add-Member。

## 启停命令
```powershell
# 启动 monitor（必须重定向）
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File ...\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "...\logs\monitor_out.log" -RedirectStandardError "...\logs\monitor_err.log"
# 启动 / 停止 watchdog
Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File ...\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
powershell -ExecutionPolicy Bypass -File ...\scripts\watchdog.ps1 -Action stop
# 停止 monitor / 健康检查 / 快照 / 镜像
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'monitor\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\status.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\sync.ps1 -Status
```
> 单实例：`monitor.pid` 记录 PID；双实例时按 pid 清理。

## 参考文件（按需阅读）
- 规则/字段/模板：`scripts\reply_rules.json`；规则引擎：`scripts\reply_engine.ps1`；LLM 提示词：`scripts\reply_agent_prompt.md`
- 部署/架构/机制/工具：`README_部署说明.md`；企微组件：`tools\wecom-connector\README.md`、`tools\control-agent\README.md`
- 质量闭环：`scripts\analyze_replies.ps1`（05:00 质量报告）→ `scripts\auto_optimize.ps1`（05:30 自动提炼）→ `scripts\consolidate_prompt.ps1`（阈值合并归档）
- 监控机制要点：去重=state.json 消息 hash+时间戳（仅 SENT_OK 记录）；防错发=发送前会话名校验；断线自愈=抓列表失败×3 刷新页、CDP 掉线×3 跑 `chrome_ensure.ps1`；按需 reload（idle 10m / busy 30m）
