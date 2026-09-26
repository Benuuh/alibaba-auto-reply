# 阿里国际站自动回复系统 - 部署说明

> 本文档是**部署与运维手册**；项目总览、特性与原理见根 `README.md`。内容对应 2026-09 结构（monitor/watchdog 主程序 + dsh-im 告警出口）。
>
> **2026-09-26 重要变更**：告警推送出口已从 `wecom-connector` 的本地长连接桥（`127.0.0.1:19886`）迁到
> **dsh-im 主动投递 HTTP 接口**。原因是两者会抢同一个企微机器人（`exit_on_kicked_offline: true`）而互相顶下线，
> 且旧启动器曾悬死 17 分钟把 watchdog 整体堵停。
> **[2026-09-26 收口] 两套退休告警桥 `tools\wecom-connector\`、`tools\control-agent\` 及其启动器
> `scripts\wecom_start.ps1` / `scripts\agent_start.ps1` 已一并**物理移除**（净减约 4,000 行 ≈ 全仓 24%）。
> ⇒ **告警只剩 dsh-im 单通道**，`DSH Desktop` 未运行时告警哑火属**已知风险**；"交接门"与
> `data\alert-channel.handover.json`、`WECOM_FORCE_RUN` 均已作废。复活/回退路径见 `docs\KNOWN_EXCEPTIONS.md` **E-24**。
> 原 Phase E（部署旧通道）与 Phase L 相关步骤**已失效，不要再执行**（历史留痕，见「五、回滚」）。

## 一、部署目录结构

```
<部署根>\alibaba-auto-reply\
├── credentials.md          ← 敏感信息唯一文件（账号/密码/API key/Bot 凭据，不入库不入备份）
├── llm_config.json         ← LLM 非敏感配置（model=deepseek-v4-flash / temperature / max_tokens / timeout_sec / endpoint / thinking:disabled）
├── SKILL.md / README.md / README_部署说明.md ← 技能说明与文档（opencode 技能镜像同步对象）
├── chrome-profile\         ← Chrome 登录态（含登录态，勿删除）
├── scripts\                ← 代码 + 状态 + 规则（常驻目录）
│   ├── config.json         ← 集中路径配置（由 config.json.example 复制；换机/换目录只改此文件）
│   ├── config.ps1          ← 配置加载器（Get-SkillPath 统一取路径）
│   ├── monitor.ps1         ← 监控+自动回复主程序（单实例）
│   ├── reply_engine.ps1 / reply_rules.json / reply_agent_prompt.md ← 回复引擎/语料/提示词（后两者可热编辑）
│   ├── cdp.ps1             ← CDP 桥接
│   ├── chrome_ensure.ps1   ← Chrome 自愈（重启+复用登录态+自动登录）
│   ├── watchdog.ps1        ← 三重守护（monitor 死亡/僵死重启；CDP 连不可达自动 chrome_ensure；防风暴）
│   ├── status.ps1          ← 一键健康检查（进程/CDP/日志/去重/任务/敏感审计）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像同步/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 计划任务脚本（4h/05:00/05:30）
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报+唤醒 / 报价提醒 CLI
│   ├── dashboard.ps1       ← 数据看板（手动工具，按需运行）
│   ├── state.json(+bak)    ← 已回复去重状态（双写）
│   └── lib\                ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom/no_reply/vision/doc/report_push/accio/alert_local/deadman）
│       └── wecom.ps1       ← **告警推送唯一出口**（7 个调用点共用；2026-09-26 起内部改走 dsh-im 投递；文件名是历史命名）
│   （原 wecom_start.ps1 / agent_start.ps1 两个保活启动器已于 2026-09-26 随两个企微桥**物理移除** —— E-24）
├── data\
│   └── alert-channel.handover.json ← **告警通道交接标记**（历史机制；2026-09-26 收口后旧桥已移除 ⇒ **已作废**，见 E-24）
├── tools\
│   ├── doc-reader\         ← 买家文档解析（PDF 文本/扫描渲染、xlsx/csv/docx → 文本或 PNG；node --test）
│   ├── email-verify\       ← 邮箱可投递性验证（MX/SMTP 探测；Node 零依赖，无 npm install）
│   └── accio-client\       ← Accio 网关只读客户端（Node 零依赖）
│   （原 wecom-connector\ 与 control-agent\ 两个企微桥已于 2026-09-26 **物理移除** —— `docs\KNOWN_EXCEPTIONS.md` E-24；
│     部署根可能残留其 gitignore 运行数据（config.json / data\ / logs\ / node_modules\），**不含可执行代码**，属预期）
├── logs\                   ← 运行日志（monitor.log 5MB 轮转留 20 份 / watchdog.log / out / err）
├── data\                   ← 买家消息快照 msgs_*.txt（保留 200 份，含对话 PII 勿外发）；manual_override.json=人工接管白名单（企微"白名单"指令维护，热生效≤10s）
├── reports\                ← 质量/总结/周报 md
├── backups\                ← 代码快照 zip（保留 20 份，不含凭据；含 2026-09-07 企微升级任务 XML 备份）
└── docs\CHANGELOG.md       ← 版本变更记录
```

## 二、前置条件

| 依赖 | 要求 | 说明 |
|---|---|---|
| Windows | 10+ | 全脚本 PowerShell 5.1 |
| Chrome | 默认安装路径 | `C:\Program Files\Google\Chrome\Application\chrome.exe`（config.json 可改） |
| Node.js | ≥ 18（实测 24） | `tools\doc-reader` / `tools\accio-client` / `tools\email-verify` 需要 |
| git | 可选 | 克隆与镜像同步 |
| dsh | **推荐** | **告警出口 dsh-im 的宿主**（见 Phase E）：`npm.cmd install -g @deepseek-ai/dsh` |
| ▸ 本机执行策略 | Restricted 时 | 所有 `.ps1` 用 `powershell -ExecutionPolicy Bypass -NoProfile -File <路径>`；`npm` 必须用 `npm.cmd`（`npm.ps1` 会被策略拦下） |

## 三、首次部署（分阶段）

### Phase A：代码与依赖
```powershell
git clone https://github.com/Benuuh/alibaba-auto-reply.git
cd alibaba-auto-reply
# 主仓库无 npm 依赖；tools 组件各装各的（doc-reader / email-verify / accio-client）
# dsh（告警出口 dsh-im 的宿主）
npm.cmd install -g @deepseek-ai/dsh
```
> **[2026-09-26 收口]** 原 Phase A 里的 `cd tools\wecom-connector; npm install` 与
> `cd tools\control-agent; npm install` 两步**已删除** —— 两个组件已物理移除（见 E-24）。

### Phase B：路径与凭据配置
1. `Copy-Item scripts\config.json.example scripts\config.json`，把 `deploy_root` 与派生路径改为实际绝对路径（换机只改此文件）
2. 创建根目录 `credentials.md`（**敏感信息唯一文件**，格式见根 README；账号/密码/API Key 用实际值；企微 Bot ID/Secret 启用企微时填）
3. `llm_config.json` 只保留非敏感项，**不要写 api_key**
4. ~~企微组件配置~~（**已作废，2026-09-26 收口**）：原需复制两个 `config.json.example` → `config.json`；两个组件已物理移除（E-24），**此步跳过**
5. 自检：`git status` 确认 credentials.md、chrome-profile、logs/data/reports/backups 均未被跟踪；全库搜索不得出现凭据明文

### Phase C：Chrome 登录 OneTalk
```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\chrome_ensure.ps1
```
- 自动启动 Chrome（独立 chrome-profile）、导航 OneTalk 并尝试登录；验证标志：页面出现消息输入框、CDP 9222 可访问
- 滑块验证码无法自动通过：刷新页面通常可消除，**不要反复点提交**；必要时人工完成一次登录，登录态持久保存
- 多实例注意：chrome_ensure 使用独立 profile，不影响日常浏览器

### Phase D：启动监控与守护
```powershell
# ⛔ 一律走计划任务启动常驻进程 —— 禁止 Start-Process：
#    E-12：从代理会话用 WMI/Start-Process 启的常驻进程会被回收
#    E-18：Start-Process -RedirectStandard* 在本机必抛
Register-ScheduledTask ...   # 首次部署：按 Phase F 注册 AlibabaAutoReplyWatchdog
Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'   # 拉起 watchdog（它再带起 monitor）
Start-ScheduledTask -TaskName 'AlibabaAutoReplyHealth'     # 需要时由 Health 兜底拉起
# 验证
Get-Content <部署根>\logs\monitor.log -Tail 20
```
监控为**单实例**：启动前检查 `scripts\monitor.pid`；停止**一律按 pid 文件精确停**
（`Stop-Process -Id (Get-Content <部署根>\scripts\monitor.pid -Raw)`），**禁止 `-Action stop`**（历史自杀式匹配缺陷 F6 未修）。

### Phase E：告警推送出口（**推荐：dsh-im 主动投递**，2026-09-26 起取代旧 Phase E）

> **先说结论**：新部署**只做本节即可，不要起旧的企微长连接桥**。两者会抢同一个企微机器人并互相顶下线。
> 旧桥的部署与回滚见 Phase L（**仅在你选择"旧通道为准"时才做**）。

**E-1 准备 dsh-im 与投递目标**（在 DSH Desktop 图形界面里，一次性）：

1. 安装并启用 `@xmanrui/dsh-im` 插件（DSH 设置 → 插件市场 / 或 profile 级安装）
2. 接入**企业微信**渠道，扫码授权该机器人 → 确认长连接已建立（可给机器人发一条消息，收到回复即通）
3. 进入该机器人的齿轮设置 → **「新建目标」** → 从已聊会话里选你自己 → 点**「测试」**（手机应收到 `DSH-IM 主动投递测试成功。`）→ **「保存目标」**
4. 点**「复制调用参数」**，得到 `{ botId, targetId }`（形如 `wecom_xxxx` / `tgt_xxxxxxxxxxxxxxxx`）
   - `botId` = 该机器人的**调用标识**（不是机器人名称、不是平台 App ID）
   - `targetId` = 你为该目标起的稳定别名；**保存后不可修改**，调用方长期使用同一个 `botId + targetId`

**E-2 写入配置**（`scripts\config.json`，三个新键；**不得给该文件加 BOM**）：

```jsonc
"dshim_delivery_url":  "http://127.0.0.1:<DSH Host 端口>/api/dsh-im/delivery/messages",
"dshim_bot_id":        "<上一步的 botId>",
"dshim_target_id":     "<上一步的 targetId>"
```
> DSH Host 端口以启动时显示的地址为准（Web profile 默认 `3080`；本机实测为 `43120`）。
> 校验：`Get-NetTCPConnection -State Listen -LocalPort <端口>` 应有监听。

**E-3 落交接标记**（让旧桥保活永久让路）：

```powershell
$m = Join-Path (Get-SkillPath "data") 'alert-channel.handover.json'   # 或直接写 <部署根>\data\alert-channel.handover.json
[pscustomobject]@{ channel='dsh-im'; since=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); note='legacy 19886 bridge retired' } |
  ConvertTo-Json | Set-Content -Path $m -Encoding UTF8
```

**E-4 停掉旧桥**：**[2026-09-26 收口后已无对象]** —— 旧桥及其启动器已物理移除（E-24），
`19886` 不可能再监听，**此步跳过**。原命令（历史留痕，**不要执行**）：
~~`tools\wecom-connector\bin\wecom-connector.ps1 -Action stop`~~。
> ⛔ **禁止**以任何形式重新启动 19886 桥（与 dsh-im 抢同一企微机器人会互踢），
> 也**禁止**重建 `AlibabaAutoReplyWeComCmd` 计划任务。

**E-5 端到端验证**（会真的给目标发消息）：

```powershell
. <部署根>\scripts\config.ps1; . <部署根>\scripts\lib\wecom.ps1
Test-WecomService            # 期望 True（405 = 接口在且只收 POST）
Send-WecomMessage '部署验证：告警出口已接通。'   # 期望 SENT_OK
```

**E-6 契约与坑（实测）**：

| 现象 | 含义 / 处置 |
|---|---|
| `{"sent":true}` / `SENT_OK` | 成功 |
| `404 unknown-bot` | `botId` 与 dsh-im 设置页不一致 |
| `404 unknown-target` | `targetId` 没配、被改名或被删（改配置即可，不用改代码） |
| `400 bad-request` | 字段**必须恰好** `botId`+`targetId`+`text`（可选 `format`）——**多一个键也会 400**；空白 `text` 同样 400（出口封装已在本地拦为 `NO_RECEIVER`） |
| 中文乱码 | PS 5.1 字符串 body 按 GBK 编码 ⇒ 必须 `[System.Text.Encoding]::UTF8.GetBytes($body)` 再发 |
| 接口可达性 | 官方文档明示该接口**不含鉴权**，只应在本机使用，**不要暴露到公网** |

**E-7 出问题时怎么回到旧通道**：**[2026-09-26 收口后此路径已不存在]** —— 旧桥代码已物理移除，
"回到旧通道"不再是一个可用选项（此前需：删交接标记 → 清空三个 `dshim_*` 键 → 起旧桥）。
若确需恢复，**必须**按 `docs\KNOWN_EXCEPTIONS.md` **E-24** 的复活路径从 git 历史取回并**另立 spec 评审**
（含"与 dsh-im 互斥"的重新评估）。当前唯一出口是 dsh-im。

### Phase L：旧企微通道 —— **【已作废，2026-09-26 收口】**

> ⛔ **本节整体作废，禁止再执行。** `tools\wecom-connector\`、`tools\control-agent\` 及其启动器
> `scripts\wecom_start.ps1` / `scripts\agent_start.ps1` **已物理移除**（净减约 4,000 行）。
> 原内容（启动 HTTP 桥 `19886`、启动 control-agent、watchdog 每 30s 调 `wecom_start.ps1` 保活、
> 交接门与 `WECOM_FORCE_RUN` 逃生门）**全部失去对象**。
>
> **为什么删**：用户裁决 D3 —— 接受"告警只剩 dsh-im 单通道"的后果。规划会话曾建议保留 `wecom-connector`
> 作兜底（交接门有"`DSH Desktop` 不在 ⇒ 恢复保活旧桥"的逃生分支），**用户明确选择删除**。
> ⇒ `DSH Desktop` 未运行期间告警**完全哑火**属**已知风险**，**不是缺陷**，**不得**因此恢复代码或另建通道。
>
> 复活路径（含取回命令）见 `docs\KNOWN_EXCEPTIONS.md` **E-24**；历史实现见
> `git -C <部署根> log --diff-filter=D --oneline -- tools/wecom-connector tools/control-agent`。
> 历史要点保留如下（仅作溯源）：旧桥与 dsh-im **互斥** —— 两者接入同一个机器人时
> `exit_on_kicked_offline=true` 会让后连的一方把先连的顶下线（实测旧桥 `AUTH-OK` 后 87 秒即被 `KICKED-OFFLINE`）；
> control-agent 曾由 watchdog 保活，且 `owner_userid` 被填成占位符导致指令全被静默丢弃（E-20）。

### Phase F：计划任务（6 个，均指向 scripts\ 下脚本）
| 任务名 | 脚本 | 周期 |
|---|---|---|
| `AlibabaAutoReplySummary` | summarize.ps1 | 每 4 小时 |
| `AlibabaAutoReplyQuality` | analyze_replies.ps1 | 每日 05:00 |
| `AlibabaAutoReplyOptimize` | auto_optimize.ps1 | 每日 05:30 |
| `AlibabaAutoReplyWeekly` | weekly_report.ps1（含 nudge 唤醒） | 每日 08:00（`StartWhenAvailable` 补跑）+ 登录后补跑；每周幂等（`data\weekly_state.json`，首个成功运行后本周其余触发走 `WEEKLY-SKIP`，不重复生成也不重复 nudge） |
| `AlibabaAutoReplyWatchdog` | watchdog.ps1（整栈自启，ExecutionTimeLimit=PT0S） | 登录时 +30s（Hidden） |
| `AlibabaAutoReplyHealth` | health_check.ps1（健康心跳，每项 30 分钟去重告警） | 每 15 分钟 |

- 注册示例（管理员）：`schtasks /Create /TN AlibabaAutoReplyQuality /TR "powershell.exe -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\analyze_replies.ps1" /SC DAILY /ST 05:00 /F`（Summary 用 `/SC HOURLY` 或等距任务）
- 已注册 `AlibabaAutoReplyWatchdog`（watchdog.ps1，ONLOGON +30s 延迟，Hidden，ExecutionTimeLimit=PT0S 不限时）：登录后自动拉起整栈——watchdog 带起 monitor / Chrome 自愈（**2026-09-26 收口后不再有"企微保活"与"control-agent 保活"两环**，见 E-24）；任务幂等（watchdog.pid 单实例检测），与手动启动的实例并存无害。
  ⛔ **启守护/常驻进程一律用 `Start-ScheduledTask`，禁止 `Start-Process`**（E-12 / E-18）
- 旧任务 `AlibabaAutoReplyWeComCmd` 已于 2026-09-07 企微通道升级时停用并删除（XML 备份：`backups\wecom_upgrade_20260907\`），**请勿重建**；企微远程控制现由 **DSH agent** 承担（原 `control-agent` 已于 2026-09-26 物理移除，E-20 / E-24）

### Phase G：首次验收
```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\status.ps1
```
逐项确认：monitor/watchdog 进程、CDP 9222、日志新鲜度、去重状态、企微 connected、计划任务、敏感审计无 [!!] 级问题。

### Phase H：Accio 网关（可选，读取增强）
官方 **Accio Desktop** 本地网关可只读拉取全量历史（无 30 天墙），作为可选数据源（CDP 始终兜底）。启用步骤：

1. 安装并登录 Accio Desktop（官方渠道，国际站店铺在 Accio 内完成 Alibaba 连接器登录）；**首次登录后重启一次 Accio**（网关凭据文件 `%USERPROFILE%\.accio\accounts\*\...\gateway-cli.json` 只在启动时且已登录才写入）
2. 登录自启：启动文件夹快捷方式 `Accio Desktop.lnk`（指向 Accio 安装目录，本机已配置；计划任务方式需管理员权限）
3. 灰度开关（`scripts\config.json`，默认全 false）：
   - `accio_shadow=true` → 影子对比（只记 `ACCIO-SHADOW` 日志，不改行为）
   - `accio_read_enabled=true` → 回复上下文优先用网关全量历史（失败/内容不匹配自动回退 CDP，日志 `ACCIO-READ src=gateway|cdp`）
   - `accio_send_enabled`（保持 false）→ 网关发送通道（需用户指定测试会话 + 回读验证后才可开启）
4. 改开关后需重启 monitor 生效；组件测试：`node --test tools\accio-client\tests\gateway.test.js tools\accio-client\tests\api.test.js`
5. 一键影子对比（只读，不打开浏览器）：`powershell -File tools\accio-client\shadow_compare.ps1 -MaxConversations 25`
6. 健康检查：`status.ps1` 新增 Accio 状态行（进程/端口 4097/版本）；watchdog 每轮轻量探测，网关持续不可达会记 `WATCHDOG-ACCIO` 日志（不自动重启桌面应用）
7. 授权降噪（2026-09-15）：Accio 桌面应用更新/重启期间网关会返回 `AUTH-REQUIRED`。此时 monitor 记录**负缓存 5 分钟**（日志 `ACCIO-ERR: conversations code=AUTH-REQUIRED -> negative-cache 300s`，期间仅每 60s 一行 `ACCIO-AUTH-SKIP`），直接回退 CDP 只读，**回复不受影响**；`status.ps1` 以 `Accio 授权` 行显示该状态。恢复直读需在 Accio 桌面应用**重新登录**（负缓存状态落盘 `logs\accio_auth_state.json`，可跨 monitor 重启生效）

### Phase I：watchdog 守护参数与"静默阈值"含义（2026-09-15 停摆整改）

watchdog 每 30s 巡检一轮，monitor 的"僵死"判定同时依赖**进程是否存在**与**日志是否新鲜**。理解这两个参数是避免误杀的关键：

| 参数 | 位置 | 缺省 | 含义 |
|---|---|---|---|
| `LogStaleSec`（静默阈值） | `watchdog.ps1 -LogStaleSec`，可被 `config.json` 的 `watchdog_log_stale_sec` 覆盖 | **240s**（原 90s） | 进程存活但日志静默超过该值 → 判定僵死并杀掉重启 |
| `CheckIntervalSec` | `watchdog.ps1 -CheckIntervalSec` | 30s | 巡检周期 |
| `restart_storm_count` / `restart_storm_window_min` | `config.json` | 4 / 10 | 窗口内重启达该次数 → 判定重启风暴 |
| `restart_storm_cooldown_min` | `config.json` | 30（min） | 命中风暴后的**冷却时长**：冷却内不重启 monitor，到期自动恢复守护，并向企微推 `[ALERT]` |
| `reply_round_budget_sec` | `config.json` | 180（s） | 单轮回复总预算；不足则本轮不发送、保留待处理，下一轮重试（日志 `ROUND-BUDGET-EXCEEDED`） |

**静默阈值的语义（重要）**：阈值放宽到 240s **不等于**可以长时间静默。monitor 在回复轮次内每 15s 至少写一行 `ROUND-*` 进度日志（`ROUND-START` / `ROUND-VISION-*` / `ROUND-LLM-BEGIN|WAIT|END` / `ROUND-SEND` / `ROUND-DONE`），因此**正常轮次的最大日志静默 < 30s**；一旦静默接近 240s，基本可判定真僵死。

**双重防误杀**：
1. **活锁豁免**——若 `data\onetalk-write.lock` 的持有 PID 仍存活，说明 monitor 正在处理轮次（含长耗时 LLM/多模态识别），watchdog **不得**以 stale 为由杀它，只记 `WATCHDOG: log quiet Ns > 240s but onetalk-write held by LIVE PID n - treated as busy, skip`。
2. **僵锁自愈**——`Get-AppLock` 发现锁持有者已死会当场删除并**立即重试获取**（`timeoutSec=0` 亦然），避免"删了锁却仍返回 false → 该轮 LOCK-BUSY 空转 → 再被判 stale"的自锁闭环。

**风暴保护不再永久放弃**：命中风暴时写入 `logs\watchdog_cooldown.json`（`until`/`reason`/`count`）并推企微告警，冷却期内主循环继续运行（仅抑制 monitor 重启；**2026-09-26 收口后守护为三重（进程/日志/CDP），不再有企微/control-agent 保活环节**），到期自动恢复。冷却状态见 `status.ps1` 的 `WATCHDOG COOLDOWN` 行；人为解除可删除该 json 文件。

**排障速查**：`Select-String 'ROUND-' logs\monitor.log`（轮次心跳）、`Select-String 'COOLDOWN|RESTART-STORM|treated as busy' logs\watchdog.log`（守护动作）、`Select-String 'LOCK-BUSY' logs\monitor.log`（写锁争用，正常应为 0）。

### Phase J：健康心跳告警（F8，2026-09-16）

计划任务 `AlibabaAutoReplyHealth` 每 15 分钟运行 `scripts\health_check.ps1`，独立于 watchdog 检查整栈健康；异常时经企微推送告警（**每项检查 30 分钟去重**，恢复时推送 `RECOVERED`），每轮结果写入 `logs\health.log`，去重状态写入 `data\health_state.json`（可安全删除，删除后下一轮重新告警）。

检查项（共 7 项，缺一不可）：`monitor_process`（monitor.pid 对应进程存活且命令行为 monitor.ps1）、`monitor_log_fresh`（monitor.log 静默 < 600s）、`watchdog_process`（watchdog.pid 存活）、`watchdog_cooldown`（无未到期风暴冷却）、`cdp_9222`（CDP 可达）、`page_logged_in`（页面存在 `textarea.send-textarea`，用于发现"CDP 通但未登录/空白"的静默空转）、`scheduled_tasks_fresh`（计划任务新鲜度 —— 6 个 `AlibabaAutoReply*` 任务的 `LastRunTime` 均在各自周期余量内，用于发现"任务不再被触发"这类静默停摆）。

> ✅ **2026-09-26 起已移除 `wecom_connected` 检查**：它探的旧桥 `19886` 已停用，该检查永久 FAIL、只能产生噪声，故按决策删除。
> **[2026-09-26 收口更新]** 旧桥随后**物理移除**；`scripts\status.ps1` 中残留的 19886 探活段也已同步**删除**，
> 改为**基于 dsh-im 的可判真假探活**（`StatusLine "告警出口(dsh-im)"`，URL 从 config 读取、不硬编码）。
> 验收项 A8 要求 `status.ps1` **不再出现** `企微通道 19886 不可达`。见 E-24。
>
> ✅ **2026-09-26 起已移除 `control_agent` 检查**：该组件已退休（唯一收信入口旧企微桥退役、未迁移到 dsh-im、且 `owner_userid` 被填成占位符导致指令全被静默丢弃）。它原恒返回 `OK` + detail `disabled by flag`，读起来像"工作正常"，会误导排查。企微远程控制能力现由 **DSH agent** 承担；`watchdog` 守护同步由五重降为**四重**（进程/日志/CDP/企微）。
> **[2026-09-26 收口更新]** `status.ps1` 里同类残留的 `control-agent` 探测段（会恒报 `[!!] control-agent DOWN(保活将在下轮拉起)`）也已**一并删除**；且守护的第四重"企微保活"随双桥移除 ⇒ **现状为三重（进程/日志/CDP）**。详见 E-20 / **E-24**。
>
> 📌 **本节是检查项清单的唯一权威定义处**。清单可由 `scripts\health_check.ps1` 的 `Add-Check` 调用自动派生；口径见 `docs\文档权威约定.md`，并由 `tests\docs_consistency.tests.ps1` 自动校验。

排障：`Get-Content logs\health.log -Tail 20`（每行 `HEALTH: name=OK|FAIL ...`）；任务状态 `Get-ScheduledTaskInfo -TaskName AlibabaAutoReplyHealth`（LastTaskResult 应为 0）。

### Phase K：守护加固 P0（2026-09-18，取消服务化，无需密码）

1. **任务空闲终止修正（根因）**：`AlibabaAutoReplyWatchdog` / `AlibabaAutoReplyHealth` 两个计划任务的 `StopOnIdleEnd` 由 `true` 改为 `false`（09-16 15:44 watchdog 被 0xC000013A 终止的根因是空闲条件结束）。Watchdog 任务保持 Enabled（watchdog 运行宿主）。
2. **Health 自动拉起 watchdog（F8b）**：`health_check.ps1` 在 `watchdog_process=FAIL` 时以分离进程拉起 `watchdog.ps1 -Action start`（幂等：pid 文件 + 命令行双重确认；heal 尝试 30 分钟节流，状态 `data\health_state.json` 的 `watchdog_heal` 键）。成功写 `HEALTH-HEAL pid=<new>`，失败写 `HEALTH-HEAL-FAIL`；异常不影响 exit 0。
3. **新增 config 键**：`log_max_mb`（20）、`log_keep_files`（10）、`snapshot_retention_days`（90）、`deadman_ping_url`（""）。
4. **日志轮转**：`scripts\log_rotate.ps1`（`Invoke-LogRotation`，超限重试 3 次×2s 移入 `logs\archive\<name>_<时间戳>.log`，保留最近 N 份；支持 `-DryRun`）；monitor 启动时对 monitor.log 执行一次。
5. **快照保留**：`scripts\retention.ps1`（`Invoke-SnapshotRetention`，`data\msgs_*.txt` 超 N 天按月份打包 `data\archive\msgs_<yyyyMM>.zip` 后删除源文件；只处理 msgs_*.txt，不碰 buyers/vision_extract/manual_override/state/报告；支持 `-DryRun`）；monitor 启动时先 DryRun 记录再执行。
6. **死信心跳**：`scripts\lib\deadman.ps1`（`Send-DeadmanPing`，GET 超时 10s；空 URL→skip，异常→fail）；`health_check.ps1` 每轮 ping 一次，`health.log` 每 6 小时最多一行 `DEADMAN-PING ok|fail`（状态 `data\deadman_state.json`）。真实 URL 待用户在 healthchecks.io 注册后填入 `deadman_ping_url`（仅 ping 无 PII）。
7. **重复发送修复（P0-2）**：`reply_engine.ps1` 新增 `ConvertTo-EpochMs`（ts 归一化）与 `Test-AlreadyReplied`（文本相同且 ts 不更新=已回复；任一侧 ts 缺失=保守判已回复）；`monitor.ps1` 去重块改调该函数，旧无 ts 记录遇可解析 ts 时写 `DEDUP-UPGRADE`；发送成功后设置 3 分钟会话冷却（日志 `POST-SEND-COOLDOWN`，preview 变化自动解除）。
8. **ACCIO-PARSE-ERR 单行化**：JSON 解析失败日志压成单行（附 `jsonErr=`），截断 200 字符，不再产生多行 JSON 块。

排障：`Get-Content logs\health.log -Tail 20 | Select-String 'HEALTH-HEAL|DEADMAN'`；`Select-String 'DEDUP-UPGRADE|POST-SEND-COOLDOWN' logs\monitor.log`；轮转 DryRun `powershell -File scripts\log_rotate.ps1 -DryRun`；保留 DryRun `powershell -File scripts\retention.ps1 -DryRun`。


## 四、常用运维

| 操作 | 命令 |
|---|---|
| 健康检查 | `scripts\status.ps1` |
| 查看运行状态 | `Get-Content logs\monitor.log -Tail 20` |
| 停止/启动监控 | `scripts\monitor.ps1 -Action stop/start`（**改完 `lib\cdp.ps1` 等库文件必须重启 monitor 才生效**——它只在启动时 dot-source 一次） |
| **告警出口自检** | `. scripts\config.ps1; . scripts\lib\wecom.ps1; Test-WecomService`（期望 True）→ `Send-WecomMessage '测试'`（期望 `SENT_OK`） |
| **交接标记状态** | ~~`Test-Path data\alert-channel.handover.json`（在 ⇒ 旧桥保活让路）~~ **已作废**（2026-09-26 收口：旧桥已物理移除，交接门不存在了 —— E-24） |
| ~~旧企微桥状态~~ | **已移除**（2026-09-26）：`tools\wecom-connector\` 整个目录已从仓库删除，无命令可用 —— E-24 |
| ~~control-agent 保活/停用~~ | **已移除**（2026-09-26）：`scripts\agent_start.ps1` 与 `tools\control-agent\` 均已删除；能力改由 **DSH agent** 承担 —— E-20 / E-24 |
| 代码快照（发布前必做） | `scripts\backup.ps1 -Snapshot` |
| 镜像同步 | `scripts\sync.ps1 -Status` / `scripts\sync.ps1 -Push`（默认镜像 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`，`-MirrorRoot` 可覆盖） |
| 报价提醒手动触发 | `scripts\quote_remind.ps1` |
| Accio 网关状态/影子对比 | `status.ps1`（Accio 状态行）；`tools\accio-client\shadow_compare.ps1`（只读对比）；开关见 config.json 的 `accio_*` |
| **发布前脱敏自检** | `powershell -File .githooks\sanitize_check.ps1 -Mode staged`（与 pre-commit/pre-push 同款；exit 1 = 阻断） |
| **推送后历史核查** | 泄漏是永久的 ⇒ 扫全历史而非只看本次 diff：`git log --all --pretty=format: --name-only --diff-filter=ACMRT \| Sort-Object -Unique` |
| **守护被回收后补拉** | `Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'`（**常驻守护只许走计划任务**；让 watchdog 自己去拉起 monitor） |

**配置热更新**：改 `scripts\reply_rules.json` / `reply_agent_prompt.md` 立即生效，无需重启；改 config.json 类路径/凭据后需重启对应进程。

## 五、回滚

- **代码回滚**：解压 `backups\` 中最近快照 → 覆盖 `scripts\` → 重启 monitor
- **配置回滚**：`reply_rules.json.pre` / `reply_agent_prompt.md.pre` / 各 `.prev` 还原（backup.ps1 自动留 .pre）
- **状态回滚**：`state.json.bak` 还原（注意：去重记录丢失可能造成重复回复，需人工评估）
- **凭据回滚**：credentials.md 由人工保管，任何备份均不含凭据
- **告警出口回滚（2026-09-26 收口后只剩一条路）**：
  **[原"两条路互斥"回滚已作废]** —— 旧企微桥代码已**物理移除**，"回到旧企微桥"不再是可执行选项
  （原先需：删交接标记 → 清空三个 `dshim_*` 键 → 起旧桥 → `curl 19886/health`）。
  若要恢复旧桥，**必须**先按 `docs\KNOWN_EXCEPTIONS.md` **E-24** 从 git 历史取回
  （`git -C <部署根> checkout <删除该目录的提交>~1 -- tools/wecom-connector`）并**另立 spec 评审**。
  ⛔ **禁止**以任何形式直接启动 19886 桥（与 dsh-im 抢同一企微机器人 ⇒ 反复互踢）。
  当前**唯一**出口：`scripts\lib\wecom.ps1` → dsh-im 投递；三个 `dshim_*` 键必须齐全（见 Phase E）。
  > ⚠️ 历史教训（**仍然适用**）：**严禁**让两条通道同时"活着" —— 同一机器人 + `exit_on_kicked_offline=true`
  > ⇒ 反复互踢，且旧启动器曾在互踢中悬死 17 分钟把 watchdog 堵停。
  > **回归风险 R1**：单通道下 `DSH Desktop` 未运行期间告警**完全哑火**（E-14 形态）—— 属用户裁决接受的已知风险，不是缺陷。

## 六、故障排查

| 现象 | 排查 |
|---|---|
| status [!!] 双实例 | 检查 monitor.pid，停止多余实例；写锁 `lib\lock.ps1` 兜底。**注意 pid 文件可能是陈旧的** ⇒ 一律 `Get-Process -Id (Get-Content <pid文件>)` 双向核对 |
| 滑块验证码 | 刷新页面消除，勿反复提交；必要时人工登录一次 |
| **告警推不出去（`SERVICE_DOWN`）** | 出口仍指向已停用的 `19886`：检查 `config.json` 的三个 `dshim_*` 键是否齐全；`Test-WecomService` 应为 True |
| **推送 `404 unknown-target`** | dsh-im 里没建投递目标，或目标被改名/删除 ⇒ 在 dsh-im 设置页重建目标并把新 `targetId` 写回配置（**不用改代码**） |
| **推送 `400 bad-request`** | 请求体多/少字段（接口用严格等值校验）；空白 `text` 同样被拒（出口封装已本地拦为 `NO_RECEIVER`） |
| **推送中文乱码** | PS 5.1 字符串 body 按 GBK 编码 ⇒ 必须 `[System.Text.Encoding]::UTF8.GetBytes($body)` 再发送 |
| **机器人在两个程序间反复掉线** | 两条通道抢同一机器人（`exit_on_kicked_offline`）⇒ 只保留 dsh-im 一条。**[2026-09-26 收口] 旧桥已物理移除，此冲突源已消除**；原"交接标记 + 清对面配置"的做法随交接门一并作废（E-24） |
| **重启旧桥 / 改回该检查** | **禁止**：旧桥与 dsh-im 抢同一个企微机器人（E-04），且其代码已移除（E-24）。要确认告警是否真的到达，看 `health.log` 里告警行的**结尾返回码**是否为 `SENT_OK` |
| **改了 `lib\cdp.ps1` 但行为没变** | monitor 只在启动时 dot-source 一次 ⇒ **必须重启 monitor**；重启后仍无变化再查是否 BOM 丢失 |
| **.ps1 改完中文全失效/判据恒真** | 编辑工具**剥掉了 UTF-8 BOM** ⇒ PS 5.1 按 ANSI 解码 ⇒ 中文字面量静默失配。复验前三字节是否 `239,187,191`，丢了用 `[System.IO.File]::WriteAllText($f,$c,(New-Object System.Text.UTF8Encoding($true)))` 写回 |
| ~~**/health connected=false（旧桥）**~~ | **已移除**（2026-09-26）：旧桥不存在 ⇒ 该现象不可能再出现（E-24） |
| LLM 全失败/回退规则 | 检查 credentials.md api_key、llm_config endpoint；看 monitor.log |
| 计划任务超龄 | 运行 `scripts\status.ps1` 查看任务状态与下次运行时间；检查 schtasks 是否被禁用/权限 |
| **守护"自己消失"且无日志** | ① 从代理/脚本会话直接建进程会被回收；② 控制台被关闭（`0xC000013A`，重启 DSH Desktop 会发生）⇒ **只走计划任务**：`Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'` |
| **看到"两个 watchdog"** | 多为**自匹配假阳性**（命令自身的命令行含 `watchdog\.ps1`）⇒ 排除自身 PID 或用 `-File .*watchdog\.ps1` 匹配 |
| monitor 日志乱码 | .ps1 必须 UTF-8 带 BOM 保存（无 BOM 中文按 GBK 解析） |
| 控制台输出重定向失败 | ⛔ **不要再手写 Start-Process 启动常驻进程**（E-12：代理会话启的进程会被回收；E-18：`-RedirectStandard*` 在本机必抛 `NO_PROXY / no_proxy` 重复键异常）⇒ **一律 `Start-ScheduledTask -TaskName 'AlibabaAutoReply*'`**；确需直接启进程时用组件自带的 `Start-ProcessClean`（.NET 直启 + 已去重环境块） |

## 七、注意事项与变更记录

- 登录页滑块验证码无法自动通过：刷新页面通常可消除，不要反复点提交
- 监控为单实例：多实例会操作同一页面互相干扰
- 修改 `reply_rules.json` / `reply_agent_prompt.md` 后立即生效，无需重启
- **人工接管白名单**（2026-09-26 恢复）：**名单买家不自动回复**（LLM/规则/图片模板/QUICK 全跳过，只读留痕 + `[NEW-INQUIRY]` 提醒），
  且报价提醒与沉睡唤醒对其跳过。名单存 `data\manual_override.json`（本机 PII，不入库），热生效。

  ```powershell
  # 确定性 CLI（不经 LLM）：增 / 删 / 查
  powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command '白名单 列表'
  powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command '白名单 添加 John Smith'
  powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command '白名单 删除 John Smith'
  ```

  **企微指令要靠一个执行端**：DSH agent（`control-agent` 已于 2026-09-26 退休并**物理移除**）。给 agent 的指令模板：

  > 当用户从企微发来形如 `白名单 添加|删除|列表 <客户名>` 的消息时，执行
  > `powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Command "<原样指令>"`
  > 并把该命令的单行输出原样回发给用户。**不要**自行编辑 `data\manual_override.json`。

  > **历史**：写侧原在 `tools\control-agent\agent_bridge.js::handleWhitelistCmd`（同为确定性处理），
  > 依赖已停用的本地桥 `127.0.0.1:19886`。现已搬到 `scripts\lib\no_reply.ps1` + `scripts\whitelist.ps1`，
  > 且 `agent_bridge.js` 及其目录已随两套退休告警桥**物理移除**（E-24）⇒ 这两个文件是名单读写侧的**唯一实现**；
  > **读侧（monitor/nudge/quote）一行未改**；写出的文件与原 JS 侧 `JSON.stringify(list,null,2)+'\n'` 逐字节一致，
  > 由 `tests\no_reply_write.tests.ps1` 守护（断言数以实时输出为准）。
- **敏感信息铁律**：账号/密码/API key/Bot 凭据只存 credentials.md（企微组件凭据走环境变量）；日志/报告/备份不得出现；status.ps1 与 .githooks 双重审计
- **脚本编码**：所有 .ps1 必须 UTF-8 带 BOM
- **告警通道二选一**：同一企微机器人**只能有一条长连接**（`exit_on_kicked_offline`）。当前默认走 dsh-im 投递，
  旧桥由 `data\alert-channel.handover.json` 交接标记阻断保活；**不要**为了"多一条路更保险"而同时开两条
- **常驻守护只走计划任务**：从脚本/代理会话直接建进程会被静默回收；重启 DSH Desktop 也可能连带终止 watchdog
  ⇒ 之后用 `Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'` 补拉
- **`AlibabaAutoReplyWatchdog` 只有"登录自启"触发器**：机器重启后若无人登录，守护不会自动起来
  （如需开机即跑，应另加开机触发器并保留单实例保护）
- 变更记录（详见 docs\CHANGELOG.md）：
  - **2026-09-26（部署根改名）**：仓库目录 `D:\Agent_work` → **`alibaba-auto-reply`**（部署根，本机位于 D 盘；下文一律写作 `<部署根>`），运行时目录 `D:\Agent_work-runtime` → **`alibaba-auto-reply-runtime`**（即 `<部署根>-runtime`）（与 git remote `alibaba-auto-reply.git` 及当时的 control-agent 项目键名对齐）。同步改动：`scripts\config.json` 13 处绝对路径（`deploy_root` + 5 个仓库内路径 + 7 个 `-runtime` 路径）、`tools\control-agent\config.json` 6 处、`tools\wecom-connector\config.json` 2 处、`.githooks\sanitize_check.ps1` 的**本机路径防泄露规则**（由旧部署根名改为新部署根名，不同步改则该规则失效）、6 个 `AlibabaAutoReply*` 计划任务的 `-File` 参数。**未改**：`scripts\config.json.example`（占位符本即新名）、`config.ps1` 的 `Split-Path $PSScriptRoot -Parent` 兜底（天然随目录走）、`tests\*`（全相对路径）。仓库外的历史归档 `D:\Agent_work-removed_<时间戳>` / `D:\Agent_work_legacy_<日期>` **保持旧名**（快照名对应当时状态，改名会破坏可回溯性）。
    > 📌 **本行原写作两个新目录的完整绝对路径**，但该字面量正是 `.githooks\sanitize_check.ps1` L51 的**阻断规则**（防本机路径泄露）⇒ 会被 pre-commit 判 `[BLOCK]`。故改写为不含盘符的目录名（同一含义，可正常提交）。这是**规划期遗留的未提交改动**，本轮收口时修正。
  - **2026-09-26：告警通道交接 + dsh-im 主动投递出口 + 页面判据修复**——旧企微长连接桥（`127.0.0.1:19886`）与 dsh-im 插件抢同一机器人而互踢（实测旧桥 `AUTH-OK` 后 87 秒被 `KICKED-OFFLINE`，且旧启动器曾悬死 17 分钟把 watchdog 堵停）；新增**交接门**（`data\alert-channel.handover.json` + 新通道宿主存在才让路，`WECOM_FORCE_RUN=1` 逃生门）阻断旧桥保活；`lib\wecom.ps1::Send-WecomMessage` 内部改走 dsh-im 投递 HTTP 接口（**函数名与返回码契约不变 ⇒ 7 个调用点一行未改**）；`Test-PageHealth` 判定抽成纯函数 `Get-PageHealthVerdict` 并新增**可见性维度**（陈旧 tip 被容器折叠时不再误判 `PageDown`，此前导致每 10 分钟无谓重启 Chrome）；新增测试 `page_health_verdict` / `page_health` / `page_select` / `page_heal_throttle` / `daemon_launch` / `env_block`（主仓库回归由 8 个测试文件增至 15 个 —— **当时快照**：296 → 427 条断言；此处为历史记录，当前值见 `tests\run_tests.ps1` 实时输出，勿据本行判断现状）；新增 `scripts\okki`、`scripts\waimao`、`tools\email-verify`
  - **2026-09-26（清理）**：移除与本项目无关的 `clean-c\`（C 盘缓存清理工具，误入库）与一次性验收工具 `tools\status-verify\`，并清掉 `scripts\` 下的旧备份残留（`reply_agent_prompt.md.bak/.pre`、`reply_rules.json.bak`）；被移除内容已归档到**部署根的上一级**（目录名 `Agent_work-removed_<时间戳>`，含哈希；该归档产生于部署根改名前，故保留旧名），`clean-c\` 与 `status-verify\` 另可从 git 历史取回。**未删除任何被引用的代码**：静态引用分析显示的"无调用"脚本（`backup.ps1`/`dashboard.ps1`/`quote_remind.ps1`）经核实均为**手动工具**，已在根 README「手动工具」表中登记
  - 2026-09-18：P0 优化——守护加固（任务 `StopOnIdleEnd=false` + Health 自动拉起 watchdog，取消 WinSW 服务化）、重复发送修复（ts 归一化去重 + 发送后 3 分钟冷却）、日志/PII 治理（ACCIO-PARSE-ERR 单行化、日志轮转、快照保留、案卷归档）、死信心跳（healthchecks.io ping 接口就绪）
  - 2026-09-12（3）：报告企微推送（`lib\report_push.ps1`，quality/weekly 生成后自动推摘要，`report_push_enabled` 开关 + 去重）+ 模型切换 `deepseek-v4-flash`（`thinking:disabled`）+ 附件识别（`lib\vision.ps1`/`lib\doc.ps1` + `tools\doc-reader` 组件；monitor 图片多模态/文档解析/机会性提取 → `data\vision_extract\`；goods 合并 sidecar）
  - 2026-09-12（2）：control-agent 保活并入 watchdog（五重守护，agent_start.ps1，启动失败 5 分钟冷却）+ 停用标记机制（bin stop/start 自动维护）+ 注册 `AlibabaAutoReplyWatchdog` 登录自启任务（+30s/Hidden/不限时）+ status 纳入 control-agent 与第 5 项任务
  - 2026-09-12：精简与优化轮——退役/休眠脚本归档至 `backups\精简优化_20260912\`（manifest 可回溯）；cdp.ps1 删死分支（仅保留 navigate/eval）；CDP 端口收敛到 `config.json` 的 `cdp_port`（默认 9222）；巨型函数拆分（Generate-Reply / Start-Monitor）；prompt 红线合并归档 + auto_optimize 阈值自动合并与 never 保留最新 40 条；SKILL/README 瘦身；镜像默认改为 opencode 技能目录
  - 2026-09-07：企微通道升级 v2——wecom-connector（HTTP 桥 19886）+ control-agent（自然语言远程控制，取代旧 6 命令体系）；`AlibabaAutoReplyWeComCmd` 计划任务停用删除；watchdog 企微保活改 wecom_start.ps1 v2
  - 2026-08-27：企微长连接职责移交独立组件 tools\wecom-connector（原 scripts\wecom\wecom_bot.js、scripts\lib\wecom.ps1 移交适配）
  - 2026-08-24：v2.0——目录隔离（logs\ data\）、凭据收敛（api_key 入 credentials.md）、lib\ 公共库五件套、tests 34→36 用例、backup/sync/consolidate 工具、watchdog 风暴防护、计划任务超龄检测与补跑
  - 2026-08-14：dedup 加入消息时间戳（showTime），修复同内容重复发送被误判已回复
- 2026-08-24 备注：Quality/Weekly 类任务首跑需 logs\ 存在（目录由 status/部署创建后即可）
