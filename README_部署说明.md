# 阿里国际站自动回复系统 - 部署说明

> 本文档是**部署与运维手册**；项目总览、特性与原理见根 `README.md`。内容对应 2026-09 结构（monitor/watchdog 主程序 + wecom-connector/control-agent 企微组件）。

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
│   ├── watchdog.ps1        ← 守护（monitor 死亡/僵死重启；CDP 连不可达 10 次自动 chrome_ensure；防风暴）
│   ├── wecom_start.ps1     ← 企微保活启动器 v2（幂等三段，watchdog 每 30s 调用）
│   ├── agent_start.ps1     ← control-agent 保活启动器（幂等，停用标记感知，watchdog 每 30s 调用）
│   ├── status.ps1          ← 一键健康检查（进程/CDP/日志/去重/任务/敏感审计）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像同步/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 计划任务脚本（4h/05:00/05:30）
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报+唤醒 / 报价提醒 CLI
│   ├── dashboard.ps1       ← 数据看板（手动工具，按需运行）
│   ├── state.json(+bak)    ← 已回复去重状态（双写）
│   └── lib\                ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom/no_reply/vision/doc/report_push）
├── tools\
│   ├── wecom-connector\    ← 企微 HTTP 桥（Node 常驻 127.0.0.1:19886；bin\wecom-connector.ps1 启停）
│   ├── doc-reader\         ← 买家文档解析（PDF 文本/扫描渲染、xlsx/csv/docx → 文本或 PNG；node --test）
│   │   ├── config.json     ← 由 config.json.example 复制（host/port/data_dir/receiver_file/log_dir，无凭据）
│   │   ├── client\wecom-client.ps1   ← PowerShell 客户端库（Conn-* 系列，零依赖可复用）
│   │   └── data\ / logs\ / tests\    ← 游标与接收方缓存 / 日志 / 63 例测试
│   └── control-agent\      ← 企微自然语言远程控制桥（Node 常驻；bin\control-agent.ps1 启停）
│       ├── config.json     ← 由 config.json.example 复制（owner_userid 留空=首条消息自动锁定）
│       └── data\ / logs\ / tests\    ← 游标/待确认/历史 / 日志 / 46 例测试
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
| Node.js | ≥ 18（实测 24） | 仅企微通道需要（wecom-connector / control-agent） |
| git | 可选 | 克隆与镜像同步 |
| dsh | 可选 | control-agent 默认外部执行 agent：`npm.cmd install -g @deepseek-ai/dsh` |

## 三、首次部署（分阶段）

### Phase A：代码与依赖
```powershell
git clone https://github.com/Benuuh/alibaba-auto-reply.git
cd alibaba-auto-reply
# 企微通道依赖（不需要企微可跳过，但建议装齐便于后续启用）
cd tools\wecom-connector; npm install; cd ..\..
cd tools\control-agent; npm install; cd ..\..
# dsh（control-agent 默认执行 agent，可选备选 opencode/claude）
npm.cmd install -g @deepseek-ai/dsh
```

### Phase B：路径与凭据配置
1. `Copy-Item scripts\config.json.example scripts\config.json`，把 `deploy_root` 与派生路径改为实际绝对路径（换机只改此文件）
2. 创建根目录 `credentials.md`（**敏感信息唯一文件**，格式见根 README；账号/密码/API Key 用实际值；企微 Bot ID/Secret 启用企微时填）
3. `llm_config.json` 只保留非敏感项，**不要写 api_key**
4. 企微组件配置（如需）：复制两个 `config.json.example` → `config.json`；**config 不含任何凭据**——Bot ID/Secret 由启动器经环境变量注入
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
# 启动 monitor（输出必须重定向，日志落 logs\）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "<部署根>\logs\monitor_out.log" -RedirectStandardError "<部署根>\logs\monitor_err.log"
# 启动 watchdog
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
# 验证
Get-Content <部署根>\logs\monitor.log -Tail 20
```
监控为**单实例**：启动前检查 `scripts\monitor.pid`；`-Action stop` 正常停止。

### Phase E：企微通道（wecom-connector 必须；control-agent 可选/当前未运行）
```powershell
# 1. 启动 HTTP 桥（凭据经环境变量注入：WX_BOT_ID/WX_BOT_SECRET；启动器自动注入）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\bin\wecom-connector.ps1 -Action start
#    输出 WECOM-STARTED / WECOM-ALREADY-RUNNING；查看连接状态：
curl http://127.0.0.1:19886/health   # {"connected":true}

# 2. 启动远程控制桥（可选，当前部署未运行）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\bin\control-agent.ps1 -Action start

# 3. owner 绑定：config.json 的 owner_userid 留空时，向机器人发第一条消息即自动锁定并回写
# 4. 保活：watchdog 每 30s 调用 scripts\wecom_start.ps1（幂等三段，无风暴）
```
- 消费方（monitor / quote_remind / nudge 经 `scripts\lib\wecom.ps1`）端点同构，零额外配置
- control-agent 已由 watchdog 保活（每 30s 幂等调用 `scripts\agent_start.ps1`，启动失败 5 分钟冷却）；手动停用：`bin\control-agent.ps1 -Action stop`（建停用标记 `data\control-agent.disabled`，保活跳过），`-Action start` 删除标记并恢复
- 无凭据时 HTTP 桥也可启动（`connected=false`，/send 返回 503），便于联调

### Phase F：计划任务（6 个，均指向 scripts\ 下脚本）
| 任务名 | 脚本 | 周期 |
|---|---|---|
| `AlibabaAutoReplySummary` | summarize.ps1 | 每 4 小时 |
| `AlibabaAutoReplyQuality` | analyze_replies.ps1 | 每日 05:00 |
| `AlibabaAutoReplyOptimize` | auto_optimize.ps1 | 每日 05:30 |
| `AlibabaAutoReplyWeekly` | weekly_report.ps1（含 nudge 唤醒） | 每周一 08:00 |
| `AlibabaAutoReplyWatchdog` | watchdog.ps1（整栈自启，ExecutionTimeLimit=PT0S） | 登录时 +30s（Hidden） |
| `AlibabaAutoReplyHealth` | health_check.ps1（健康心跳，每项 30 分钟去重告警） | 每 15 分钟 |

- 注册示例（管理员）：`schtasks /Create /TN AlibabaAutoReplyQuality /TR "powershell.exe -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\analyze_replies.ps1" /SC DAILY /ST 05:00 /F`（Summary 用 `/SC HOURLY` 或等距任务）
- 已注册 `AlibabaAutoReplyWatchdog`（watchdog.ps1，ONLOGON +30s 延迟，Hidden，ExecutionTimeLimit=PT0S 不限时）：登录后自动拉起整栈——watchdog 带起 monitor / Chrome 自愈 / 企微保活 / control-agent 保活；任务幂等（watchdog.pid 单实例检测），与手动启动的实例并存无害
- 旧任务 `AlibabaAutoReplyWeComCmd` 已于 2026-09-07 企微通道升级时停用并删除（XML 备份：`backups\wecom_upgrade_20260907\`），**请勿重建**；企微远程控制由 control-agent（可选）提供

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

**风暴保护不再永久放弃**：命中风暴时写入 `logs\watchdog_cooldown.json`（`until`/`reason`/`count`）并推企微告警，冷却期内主循环继续运行（仅抑制 monitor 重启，企微/control-agent 保活照常），到期自动恢复。冷却状态见 `status.ps1` 的 `WATCHDOG COOLDOWN` 行；人为解除可删除该 json 文件。

**排障速查**：`Select-String 'ROUND-' logs\monitor.log`（轮次心跳）、`Select-String 'COOLDOWN|RESTART-STORM|treated as busy' logs\watchdog.log`（守护动作）、`Select-String 'LOCK-BUSY' logs\monitor.log`（写锁争用，正常应为 0）。

### Phase J：健康心跳告警（F8，2026-09-16）

计划任务 `AlibabaAutoReplyHealth` 每 15 分钟运行 `scripts\health_check.ps1`，独立于 watchdog 检查整栈健康；异常时经企微推送告警（**每项检查 30 分钟去重**，恢复时推送 `RECOVERED`），每轮结果写入 `logs\health.log`，去重状态写入 `data\health_state.json`（可安全删除，删除后下一轮重新告警）。

检查项（缺一不可）：`monitor_process`（monitor.pid 对应进程存活且命令行为 monitor.ps1）、`monitor_log_fresh`（monitor.log 静默 < 600s）、`watchdog_process`（watchdog.pid 存活）、`watchdog_cooldown`（无未到期风暴冷却）、`wecom_connected`（19886 /health connected=true）、`control_agent`（agent_bridge.js 进程存在，或有 `data\control-agent.disabled` 停用标记）、`cdp_9222`（CDP 可达）、`page_logged_in`（页面存在 `textarea.send-textarea`，用于发现"CDP 通但未登录/空白"的静默空转）。

排障：`Get-Content logs\health.log -Tail 20`（每行 `HEALTH: name=OK|FAIL ...`）；任务状态 `Get-ScheduledTaskInfo -TaskName AlibabaAutoReplyHealth`（LastTaskResult 应为 0）。


## 四、常用运维

| 操作 | 命令 |
|---|---|
| 健康检查 | `scripts\status.ps1` |
| 查看运行状态 | `Get-Content logs\monitor.log -Tail 20` |
| 停止/启动监控 | `scripts\monitor.ps1 -Action stop/start` |
| 企微桥状态 | `tools\wecom-connector\bin\wecom-connector.ps1 -Action status`（control-agent 同款） |
| control-agent 保活/停用 | `scripts\agent_start.ps1`（幂等保活启动器）；停用 `tools\control-agent\bin\control-agent.ps1 -Action stop`（建标记 `data\control-agent.disabled`），恢复用 `-Action start`（删标记） |
| 代码快照（发布前必做） | `scripts\backup.ps1 -Snapshot` |
| 镜像同步 | `scripts\sync.ps1 -Status` / `scripts\sync.ps1 -Push`（默认镜像 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`，`-MirrorRoot` 可覆盖） |
| 报价提醒手动触发 | `scripts\quote_remind.ps1` |
| Accio 网关状态/影子对比 | `status.ps1`（Accio 状态行）；`tools\accio-client\shadow_compare.ps1`（只读对比）；开关见 config.json 的 `accio_*` |
| 发送测试消息 | 见 `tools\wecom-connector\client\wecom-client.ps1`（Conn-SendMessage） |

**配置热更新**：改 `scripts\reply_rules.json` / `reply_agent_prompt.md` 立即生效，无需重启；改 config.json 类路径/凭据后需重启对应进程。

## 五、回滚

- **代码回滚**：解压 `backups\` 中最近快照 → 覆盖 `scripts\` → 重启 monitor
- **配置回滚**：`reply_rules.json.pre` / `reply_agent_prompt.md.pre` / 各 `.prev` 还原（backup.ps1 自动留 .pre）
- **状态回滚**：`state.json.bak` 还原（注意：去重记录丢失可能造成重复回复，需人工评估）
- **凭据回滚**：credentials.md 由人工保管，任何备份均不含凭据

## 六、故障排查

| 现象 | 排查 |
|---|---|
| status [!!] 双实例 | 检查 monitor.pid，停止多余实例；写锁 `lib\lock.ps1` 兜底 |
| 滑块验证码 | 刷新页面消除，勿反复提交；必要时人工登录一次 |
| /health connected=false | Bot ID/Secret 注入是否正确；`bin\wecom-connector.ps1 -Action start` 自愈重启应用凭据 |
| LLM 全失败/回退规则 | 检查 credentials.md api_key、llm_config endpoint；看 monitor.log |
| 计划任务超龄 | 运行 `scripts\status.ps1` 查看任务状态与下次运行时间；检查 schtasks 是否被禁用/权限 |
| monitor 日志乱码 | .ps1 必须 UTF-8 带 BOM 保存（无 BOM 中文按 GBK 解析） |
| 控制台输出重定向失败 | monitor 启动必须带 -RedirectStandardOutput/-RedirectStandardError |

## 七、注意事项与变更记录

- 登录页滑块验证码无法自动通过：刷新页面通常可消除，不要反复点提交
- 监控为单实例：多实例会操作同一页面互相干扰
- 修改 `reply_rules.json` / `reply_agent_prompt.md` 后立即生效，无需重启
- **人工接管白名单**：企微向机器人发「白名单 添加 <客户名>」→ 该买家不再自动回复（只读快照 + [NEW-INQUIRY] 提醒；报价/唤醒免打扰）；「白名单 删除」即恢复；名单存 `data\manual_override.json`（损坏/缺失=空名单，热生效≤10s，无需重启 monitor）
- **敏感信息铁律**：账号/密码/API key/Bot 凭据只存 credentials.md（企微组件凭据走环境变量）；日志/报告/备份不得出现；status.ps1 与 .githooks 双重审计
- **脚本编码**：所有 .ps1 必须 UTF-8 带 BOM
- 变更记录（详见 docs\CHANGELOG.md）：
  - 2026-09-12（3）：报告企微推送（`lib\report_push.ps1`，quality/weekly 生成后自动推摘要，`report_push_enabled` 开关 + 去重）+ 模型切换 `deepseek-v4-flash`（`thinking:disabled`）+ 附件识别（`lib\vision.ps1`/`lib\doc.ps1` + `tools\doc-reader` 组件；monitor 图片多模态/文档解析/机会性提取 → `data\vision_extract\`；goods 合并 sidecar）
  - 2026-09-12（2）：control-agent 保活并入 watchdog（五重守护，agent_start.ps1，启动失败 5 分钟冷却）+ 停用标记机制（bin stop/start 自动维护）+ 注册 `AlibabaAutoReplyWatchdog` 登录自启任务（+30s/Hidden/不限时）+ status 纳入 control-agent 与第 5 项任务
  - 2026-09-12：精简与优化轮——退役/休眠脚本归档至 `backups\精简优化_20260912\`（manifest 可回溯）；cdp.ps1 删死分支（仅保留 navigate/eval）；CDP 端口收敛到 `config.json` 的 `cdp_port`（默认 9222）；巨型函数拆分（Generate-Reply / Start-Monitor）；prompt 红线合并归档 + auto_optimize 阈值自动合并与 never 保留最新 40 条；SKILL/README 瘦身；镜像默认改为 opencode 技能目录
  - 2026-09-07：企微通道升级 v2——wecom-connector（HTTP 桥 19886）+ control-agent（自然语言远程控制，取代旧 6 命令体系）；`AlibabaAutoReplyWeComCmd` 计划任务停用删除；watchdog 企微保活改 wecom_start.ps1 v2
  - 2026-08-27：企微长连接职责移交独立组件 tools\wecom-connector（原 scripts\wecom\wecom_bot.js、scripts\lib\wecom.ps1 移交适配）
  - 2026-08-24：v2.0——目录隔离（logs\ data\）、凭据收敛（api_key 入 credentials.md）、lib\ 公共库五件套、tests 34→36 用例、backup/sync/consolidate 工具、watchdog 风暴防护、计划任务超龄检测与补跑
  - 2026-08-14：dedup 加入消息时间戳（showTime），修复同内容重复发送被误判已回复
- 2026-08-24 备注：Quality/Weekly 类任务首跑需 logs\ 存在（目录由 status/部署创建后即可）
