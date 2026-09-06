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

通过 CDP 控制本机 Chrome 登录 OneTalk 卖家消息中心，监控买家询盘，按语料库规则自动分析并回复。本技能 5 个入口分支：

| 分支 | 用户说法（触发词） | 流程 |
|------|-------------------|------|
| 监控询盘 | "监控阿里询盘" | A |
| 自动回复 | "自动回复买家消息" | A |
| 分析买家 | "分析阿里买家/买家档案" | D |
| 配置语料库 | "配置回复语料库/改回复规则" | C |
| 健康检查 | "健康检查/监控状态/系统是否正常" | B |

---

## 主流程 A：监控与自动回复（默认入口）

### A1. 确认监控在运行
- 检查 `scripts\monitor.pid` 存在，且 `logs\monitor.log` 最后写入在 2 分钟内（有 `Scan cycle done`）。
- **完成标准**：进程存在 + 日志新鲜（<90 秒）。不满足则走 A2。

### A2. 启动监控（未运行时）
- 执行启动命令（见参考区"启动/停止命令"），带重定向参数。
- **完成标准**：`logs\monitor.log` 出现 `=== Monitor started (PID xxx) ===`，且 30 秒内出现首个 `Scan cycle done`。

### A3. 监控循环（系统自动执行，agent 观察确认）
monitor 每 12 秒扫描"待回复"板块，对每个会话依次：打开 → 提取消息（上限 1000 字符，含阿里翻译）→ 意图识别 → 信息缺口核对 → 生成回复 → 发送 → 去重记录。
- **完成标准**：日志中该会话出现 `REPLIED to <买家>: FILLED | CLICKED | SENT_OK`。若出现 `RETRY-QUEUE` 说明发送失败，进入冷却重试（3→6→12→15 分钟封顶），agent 应等待下一轮而非重复操作。

### A4. 回复生成依据（agent 干预回复质量时查阅）
- 查参考区"回复规则优先级（19 条）"决定话术方向；
- 对照 `scripts\reply_rules.json` 的 `data_to_collect` **只问缺失项**；
- LLM 生成遵循 `scripts\reply_agent_prompt.md`（改后立即生效，无需重启）。
- **完成标准**：生成的回复满足"答必所问、不重复提问已答字段、数字与上下文一致"三条硬底线（详见参考区质量红线）。

### A5. 新询盘提醒（A1 功能，自动）
- 新买家首次出现在待回复板块时自动推企微 `[NEW-INQUIRY] 买家名 + 预览`，24h 节流。
- **完成标准**：`logs\monitor.log` 出现 `INQUIRY-ALERT: <买家> -> SENT_OK`；`SERVICE_DOWN` 或 `SEND_FAIL` 时只记日志，不影响回复主流程。

---

## 主流程 B：健康检查与维护

### B1. 一键健康检查
- 运行 `scripts\status.ps1`。
- **完成标准**：无 `[!!]` 项；"敏感信息审计"为 `[OK]`（无 sk-key/password 明文）。有 `[!!]` 时逐项定位修复后重跑。

### B2. 检查守护与任务
- `watchdog.ps1` 运行中（每 30s 检查，log 90s 未更新判定僵死）；计划任务 4 项 Ready：Summary/Quality/Optimize/Weekly（旧 AlibabaAutoReplyWeComCmd 已于 2026-09-07 企微通道升级时停用删除，勿重建；Dashboard/HealthReport/Notify/TaskHealth 未注册属正常）。
- **完成标准**：任务列表无缺失、无卡死。

### B3. 镜像同步检查
- 运行 `scripts\sync.ps1 -Status`；查看 `last_sync.json` 距今天数。
- **完成标准**：无 DIFFERS/ONLY-WORK 需要推送，或执行 `sync.ps1 -Push` 后两侧一致；距上次推送 <7 天。

### B4. 代码发布流程（改代码时）
- 完整流程：`backup.ps1 -Snapshot` → 改代码（UTF-8 带 BOM）→ `status.ps1` 验证 → `sync.ps1 -Push` → **git commit（pre-commit 自动脱敏扫描）→ git push（pre-push 自动脱敏扫描）** → 观察 24h。
- **默认脱敏防线（git hook，仓库自带 `.githooks\`）**：
  - `pre-commit`：暂存区扫描，发现敏感内容/文件直接拒绝提交（exit 1）。
  - `pre-push`：推送范围全量扫描，同样阻断。
  - 扫描内容：文件名黑名单（credentials.md / state.json / remind_state.json / *.log / *.pid / *.local / chrome-profile / data / reports 等运行时产物与 PII 目录）+ 内容模式（API key、password/api_key 赋值、真实用户目录路径、公司名、凭据行）。警告级（邮箱/买家名）只提示不阻断。
  - 被阻断时：按 [BLOCK] 提示定位并移除敏感内容后重试；**不得**用 `--no-verify` 绕过。
- 改动 `monitor.ps1` 需重启监控（低询盘时段；先 stop 再 start，见参考区命令）。
- **完成标准**：快照已生成、status 无 [!!]、镜像已同步、git commit 与 push 均通过脱敏扫描（无 [BLOCK]）、重启后日志心跳正常。

---

## 主流程 C：配置语料库（回复规则）

### C1. 编辑规则
- `scripts\reply_rules.json`：品牌/价格准则/`data_to_collect` 字段清单/`templates` 模板；
- `scripts\reply_agent_prompt.md`：意图识别 + 质量红线（`never` 区）。
- **完成标准**：JSON 合法（`ConvertFrom-Json` 无错）；改后立即生效，无需重启 monitor。

### C2. 验证生效
- 对最近一条真实快照（`data\msgs_*.txt`）跑意图分支确认话术符合新规则（可参考 `tests\reply_engine.tests.ps1` 用例）。
- **完成标准**：规则变更在日志中下一次回复可见；若 auto_optimize 曾自动追加，确认 `never`/红线未超过 40 条上限。

---

## 主流程 D：分析买家（手动会话分析）

### D1. 读取会话
- 会话列表：`.contact-item-container`（含 [未读] 标记/买家名/预览/意向标签）；
- 消息：`[class*=message]` 元素 innerText；[买家]消息带"由阿里翻译提供"翻译，[我]为卖家发送；
- 买家档案：`.alicrm-customer-detail-card`（国家/注册时间/标签/ID）。
- **完成标准**：已提取买家名 + 最新消息 + 档案字段。

### D2. 判断信息齐全度
- 对照 `data_to_collect`（重量/尺寸/图片/地址/供应商）标记已给/缺失。
- **完成标准**：输出清单明确列出每项状态；齐全（重量+尺寸+地址）→ 可提示人工报价（D1 决策：不自动报价）。

---

## 不该自动回复（先读本节，再决定是否回复）

以下情形 **不要发送模板/追问**：

1. **买家否定/拒绝**（no thanks / not interested / laisser tomber / forget it）→ 友好收尾，不发模板（防骚扰）。
2. **买家指责"不读/看不懂"或已读不回** → 先道歉确认收到，不再追问。
3. **无新消息**（dedup 命中：最新买家消息 hash 已在 `state.json`）→ 跳过，不重复回复。
4. **冷却中**（`skipCooldown`/`openCooldown` 生效，日志显示 TEMP-SKIP）→ 不打开会话、不发送。
5. **同一字段已问 ≥2 次**（`[追问统计] weight×2`）→ 不再问，转等待语气。
6. **买家承诺提供某字段**（`[承诺字段]`）→ 不再追问该字段。
7. **会话名校验不一致**（`ABORT_WRONG_CONVO`）→ 绝不发送，检查是否串台。
8. **验证码/风控滑块**（`#baxia-dialog-content`）→ 不反复提交；刷新登录页后重填（见参考区登录）。

---

## 参考区（按需查阅，非每轮必读）

### 目录隔离（D3 铁律）

| 目录 | 内容 |
|------|------|
| `scripts\` | 代码 + 状态(state.json/pid) + 规则(reply_rules.json/prompt) |
| `logs\` | 运行日志（monitor.log 及归档 / watchdog.log / out / err） |
| `data\` | 买家消息快照 msgs_*.txt + buyers 档案（含对话 PII，仅本机） |
| `reports\` | 质量/总结/周报/看板（聚合为主，不含凭据） |
| `backups\` | 代码快照 zip（**不含 credentials.md**，保留 20 份） |

### 核心文件清单（scripts\ 下）

| 文件 | 作用 |
|------|------|
| `monitor.ps1` | 监控主程序：检测待回复 → 提取 → 分析 → 生成 → 发送（全自动闭环） |
| `reply_engine.ps1` | 回复引擎（语言检测/信息缺口核对/规则生成），monitor 内置使用 |
| `cdp.ps1` / `lib\cdp.ps1` | CDP 桥接（newtab/navigate/eval/screenshot，WS 15s/20s 超时保护） |
| `watchdog.ps1` | 守护：monitor 退出/僵死自动重启（10 分钟 4 次防风暴） |
| `chrome_ensure.ps1` | Chrome 自愈：重启 + 复用登录态 + 自动登录 |
| `status.ps1` | 一键健康检查（进程/CDP/日志/去重/计划任务/**敏感信息审计**） |
| `backup.ps1` / `sync.ps1` | 基线快照 / 工作副本↔镜像同步（-Push/-Pull/-Status） |
| `health_report.ps1` | 每日 08:30 健康报告推企微（计划任务驱动） |
| `dashboard.ps1` | 数据看板 HTML（每 2h 生成，10 分钟自动刷新） |
| `quote_remind.ps1` / `lib\quote.ps1` | 报价提醒（数据齐全买家推企微，24h 节流） |
| `wecom_command.ps1` | 旧企微 6 命令轮询（**已停用 2026-09-07**，被 tools\control-agent 取代；头部已标注，保留留档可回滚） |
| `tools\wecom-connector` / `tools\control-agent` | 企微长连接 HTTP 桥(127.0.0.1:19886) / 自然语言远程控制（详见"企微长连接通道/企微远程控制"节） |
| `consolidate_prompt.ps1` | prompt 自动优化红线归档合并（-DryRun 预览） |
| `lib\creds.ps1` 等 7 件 | 凭据解析 / LLM 调用 / 消息发送 / 企微推送 / 货物解析 / 写互斥 / 日志轮转 |
| `summarize.ps1` 等 6 件 | 报告与质量闭环（计划任务驱动） |
| `reply_rules.json` | 语料库（品牌/价格准则/收集字段/模板），可编辑，每次回复前重读 |
| `reply_agent_prompt.md` | LLM 回复代理提示词（意图识别 + 质量红线），改后立即生效 |

### 启动 / 停止 / 维护命令


```powershell
# 启动监控（必须带重定向参数，否则隐藏窗口输出阻塞导致退出；日志落在 logs\）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "C:\path\to\alibaba-auto-reply\logs\monitor_out.log" -RedirectStandardError "C:\path\to\alibaba-auto-reply\logs\monitor_err.log"

# 启动 watchdog 守护（每 30s 检查，log 90s 未更新判定僵死）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
# 停止 watchdog（不影响已运行的 monitor）
powershell -ExecutionPolicy Bypass -File C:\path\to\alibaba-auto-reply\scripts\watchdog.ps1 -Action stop

# 停止监控
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'monitor\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 健康检查 / 代码快照 / 镜像同步 / 健康报告
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\status.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\backup.ps1 -Snapshot
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\sync.ps1 -Status   # 或 -Push
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\health_report.ps1  # 手动触发企微健康报告
```

> 单实例保护：`monitor.pid` 记录 PID；残留旧 PID 导致启动被拒时先删 `monitor.pid`；watchdog 重复启动或重启 monitor 时可能出现双实例，查 pid 杀掉多余。

### Chrome 自愈与登录

- 一键自愈（CDP 掉线/需要登录时）：`powershell -ExecutionPolicy Bypass -NoProfile -File ...\chrome_ensure.ps1`
- 登录页字段：`input[name=account]` / `input[name=password]`，提交按钮 `button.sif_form-submit`；React 受控组件**必须用原生 setter + input/change 事件**赋值
- 登录成功标志：URL 变为 `onetalk.alibaba.com/message/weblitePWA.htm`
- **验证码**：频繁登录触发无痕滑块（`#baxia-dialog-content`）。CDP 合成事件无法通过；**唯一办法：`cdp.ps1 -Action navigate` 刷新登录页，验证码通常消失**，然后重新填表；不要反复点提交（越点越被风控）

### 回复规则优先级（19 条）

1. 买家指责"不读/看不懂" → 先道歉确认收到，不再追问
2. 否定/拒绝（no/non/não/laisser tomber/forget it）→ 友好收尾，**不发模板**（防骚扰）
3. 仅图片消息 → 多语言引导补充文字（重量/尺寸/地址）
4. 感谢（thanks/gracias/merci；含询盘词的长消息不按感谢处理）→ 4 语言道谢
5. 简短确认（ok/yes/perfect）→ 确认下一步；携带货物信息（"yes it is 20 kg"）走信息处理
6. 语气词 / 问是否 AI / 纯问候（排除含询价词）→ 简短自然回应
7. 稍后回来（get back/later/tomorrow）→ 友好等待，不强推
8. 问联系方式 / 流程 / 计费 → 对应模板（our_contact / process_overview / billing_rule）
9. 问时效 → 空运 5-10 天 / 海运 35-45 天（含法/西/葡话术）
10. 电池/危险品 → 索要 SDS + UN38.3（合规必要）；已提供 SDS 不重复要
11. 砍价（mejor precio/melhor preço）→ 说明计费规则，引导给准确数据
12. 比价 → 强调服务价值（仓网/车队/保险/门到门）
13. 无供应商（no supplier/没有供应商）→ 直接要货物详情，不追问供应商
14. 不感兴趣（no thanks/not interested）→ 大方收尾，不推销
15. 提供货物信息（kg/cm/尺寸/地址）→ 确认收到，**只问缺失项**；已问过用跟进语气，不机械重复
16. 地址相关 → 已给则确认，否则 ask_address 模板
17. 查件/催进度（status/tracking/estado/suivi）→ 跟进承诺（"I'll check with the warehouse and get back to you today"），**不编造日期**
18. 询价/货物/发货（含 cuánto cuesta/quanto custa）→ 缺失项 ≤3 个组合问句，否则 first_inquiry 模板
19. 默认 → 动态追问缺失信息（不允许空回复）

### 核心机制

- **去重**：state.json 按最新买家消息 hash（去翻译标记/空白/标点/小写）+时间戳；发送成功（SENT_OK）才记录，失败进冷却重试（3→6→12→15 分钟封顶），预览变化立即打破
- **防错发**：发送前比对当前会话名与目标（Get-CurrentConvoName，排除 `.alicrm-customer-detail-card` 客户详情卡片），不一致 ABORT
- **防串台**：打开会话后轮询校验会话名（最多 6 秒）才抓消息
- **断线自愈**：抓列表失败连续 3 次自动刷新页面；CDP 掉线连续 3 次自动跑 `chrome_ensure.ps1`（只杀调试实例，不误杀用户个人 Chrome）；空数组 `[]` 是正常无待办，不误刷新
- **定时刷新**：按需 reload（10 分钟 idle + 30 分钟 busy 兜底，config 可调）
- **发送模式**：`textarea.send-textarea` 原生 setter 填值 + input 事件；按钮 `发送`（类名含 gray 是正常样式）；成功标志=输入框清空

### 语料库配置（reply_rules.json 结构）

```json
{
  "brand": { "company_name": "", "service_description": "", "sales_contact": "" },
  "pricing": { "quote_policy": "", "currency": "USD", "validity": "", "payment_terms": "" },
  "data_to_collect": ["货物信息清单"],
  "reply_rules": { "always": [], "never": [], "urgency": [] },
  "templates": { "first_inquiry": "", "follow_up_details": "", "battery_inquiry": "", "address_received": "", "ack_only": "" }
}
```

### 质量闭环

1. 每日质量报告 `reports\quality_*.md`（analyze_replies，计划任务 05:00）→ 找负面模式
2. 改 `reply_rules.json` never 区 / `reply_agent_prompt.md` 质量红线（改后立即生效，无需重启）；或 `auto_optimize.ps1` 每日 05:30 自动提炼（`-DryRun` 预览；**写入前精确去重 + never/redlines 各 40 条上限**）
3. `consolidate_prompt.ps1` 定期把自动追加红线归档合并（防 prompt 膨胀）
4. 次日报告对比同买家评分验证

**已内置质量红线**：答必所问 / 已给信息不再重复要 / 信息核对错先道歉只纠错 / 不耐烦先收尾不推销 / 数字与上下文一致（不确定引用原话）/ 查件不编造日期 / 不复述买家旧消息 / 锂电池索要 SDS+UN38.3。

### 企微远程控制（control-agent，2026-09-07 企微通道升级后）

向企微机器人发送**任意自然语言指令**即可远程操控（取代旧 6 命令固定指令体系）：

- **Owner 锁定**：config.json `owner_userid` 为空时，向机器人发送第一条消息即自动锁定该用户并回写 config.json（可人工复核/修改）。
- **确认闸门**：指令执行前需 owner 回复"确认"，同 owner 60 秒节流，5 分钟确认过期。
- **执行**：`dsh --profile headless`（executor.type=dsh），工作目录按指令提及项目名解析（alibaba-auto-reply / wecom-connector / control-agent），超时 300s。
- **回发**：≤200 字中文总结 + 改动文件/diff 摘要（白名单 reply_rules.json / reply_agent_prompt.md / config.json 允许直接修改并展示 diff）；不回发凭据/密钥。
- 组件：`tools\control-agent\`（bin\control-agent.ps1 -Action start|stop|status；心跳见 logs\agent.log；PID 文件 data\control-agent.pid；**保活暂未并入 watchdog——遗留项**）。
- 旧体系停用（2026-09-07）：`scripts\wecom_command.ps1` 头部已标注停用（行为未改、保留留档）；计划任务 AlibabaAutoReplyWeComCmd 已停用并删除（XML 备份 `backups\wecom_upgrade_20260907\AlibabaAutoReplyWeComCmd.xml`）；`status.ps1` 任务清单已随之移除该任务。

### 企微长连接通道（wecom-connector，2026-09-07 起）

- 长连接服务 = `tools\wecom-connector`（node server.js，HTTP 桥 127.0.0.1:19886；端点 `/send /health /messages?consumer= /cursor /receiver /status`；多消费者游标持久化于组件 `data\`）。旧 `scripts\wecom\wecom_bot.js` 不再运行（文件保留留档）。
- 启动/保活：watchdog 每 30s 调用 `scripts\wecom_start.ps1`（v2，幂等三段：health connected→`WECOM-ALREADY-RUNNING` 静默；进程在未连接→`WECOM-NOT-CONNECTED` 等 SDK 重连；否则经 `bin\wecom-connector.ps1 -Action start` 以 env 凭据拉起→`WECOM-STARTED`）。凭据只从 credentials.md 经环境变量注入，**config.json 无任何凭据**。
- 消费方（monitor 询盘/报价提醒、quote_remind、notify、health_report 经 `lib\wecom.ps1`）端点同构，零代码改动。
- **常驻进程清单（四件套）**：`monitor.ps1`（自动回复主循环）/ `watchdog.ps1`（守护，自愈拉起 monitor 与企微通道）/ wecom-connector（企微长连接桥）/ control-agent（企微自然语言远程控制）。

### 敏感信息与目录铁律（D2/D3）

- **敏感信息（账号/密码/API key/企微 bot 密钥）只允许存在于 `credentials.md`**，格式：
  ```markdown
  - **账号 (account)**：xxx
  - **密码 (password)**：xxx
  - **API Key (api_key)**：xxx
  ```
- `llm_config.json` 只存非敏感项（model/temperature/max_tokens/timeout_sec/endpoint），**禁止写入 api_key**
- 日志/报告/快照/备份不得出现敏感值；`status.ps1` 每次运行自动审计（sk-key/password 模式）
- `backup.ps1` 打包不含 credentials.md；`sync.ps1` 不推送凭据
- 运行日志在 `logs\`、买家快照在 `data\`（含对话 PII，勿外发）
- **凭据安全**：账号密码 API key 不写入仓库、日志、报告或聊天
- **git 默认防线**：`.githooks\pre-commit` / `.githooks\pre-push` 在提交/推送前自动扫描（`core.hooksPath=.githooks` 已配置，hook 随仓库分发）；扫描器 `.githooks\sanitize_check.ps1` 按文件名黑名单 + 内容模式阻断敏感信息，警告级 PII 仅提示。发现 [BLOCK] 时移除敏感内容后重试，**禁止 `--no-verify` 绕过**

### PS 5.1 与编码注意事项

- **PS 5.1 限制**：不支持 `? :`/`??`/`||`；CancellationToken 用 `::None`；**脚本必须 UTF-8 带 BOM**（无 BOM 中文按 GBK 解析报错）
- **LLM 编码（重要）**：PS 5.1 `Invoke-RestMethod` 缺 charset 时按 Latin-1 解码会乱码（`—`→`â`、数字幻觉）。**必须用 `HttpWebRequest` + `StreamReader(UTF8)` 显式解码**（lib\llm.ps1 已封装，勿改回）
- **截图**：`Page.captureScreenshot` 响应可能超 64MB 导致 ConvertFrom-Json 失败，优先 DOM 检查
- **长消息**：提取上限 1000 字符（原 300 会丢箱数/总重）
- **CDP 端口**：9222
- **状态写入**：PS 5.1 `Add-Member` 到 Hashtable 后 `ConvertTo-Json` 序列化为空——状态写入必须用 Hashtable 键赋值（V11/V12）

