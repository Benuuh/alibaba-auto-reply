# CHANGELOG - alibaba-auto-reply

> 注：历史条目中提到的部分脚本（如 notify / task_health / health_report / wecom_command）已于 2026-09-12 归档至 `backups\精简优化_20260912\`，条目内容保留当时事实。

## 2026-09-27 - 终结误发（阶段 A）：`Test-ShouldReply` 单一判据出口 + 整轮硬门禁，删除旧判据与回退分支

**背景**：09-27 11:42–11:50 恢复运行后 8 分钟内对外发出 8 条，其中至少 3 条是对不需要回复的买家重复发言（"修重复"第 6 次 `4eb39fe` 之后再次复发）。spec 判定根因不是判据不够聪明，而是"是否回复"没有**唯一出口**、且判据建立在不稳定信号（列表位置/条数/预览串）上。详见 `docs\specs\误发终止_单出口判据_20260927.md`。

- **唯一出口**：`reply_engine.ps1` 新增纯函数 `Test-ShouldReply -ConvoLines -LedgerKey -NormLastBuyerHash`，返回 `@{Reply;Reason}`；证据锚点 = "账本记录的那次回复 vs 该会话最后一条买家消息"，不依赖列表位置/条数抖动/预览串
- **删除旧出口**：整体删除 `Test-NewBuyerMessage`（其回退分支"文本 hash 不同即算新消息"是第 6 次修复失效的直接原因）；`monitor.ps1` 去重块的 `Test-DedupHit` 调用与 `$isNew/$already` 兜底闸门全部由 `Test-ShouldReply` 单点取代；`nudge.ps1` 的自动发送路径删除（改为只留内部提醒，spec §4.1）
- **整轮硬门禁**：G1 页面不可用/无 OneTalk 页 ⇒ 整轮 `ABORT-PAGE-DOWN ... action=skip-round`、零会话处理零发送；G1b 连续 2 轮升级既有 `PAGE-HEAL`（自愈失败 ≥2 次 ⇒ `ABORT-PAGE-DOWN-FATAL` 停机等人工）；G2 `ABORT_WRONG_CONVO` 升级为**整轮中止** `round-halt`；G3 冷启动第 1 个 scan cycle 只观察不发送 `COLD-START observe-only`；G4 最小版：同一买家 15 分钟内不再发第 2 条 `RATE-SKIP`（完整限流属阶段 B）
- **验收（离线，全程 monitor 停止）**：A1 全量 23 个测试文件 `failedFiles=0`；A2 213 份历史快照回放 **0 违例**；A9 用改动前代码复现事故 5 份快照的红灯（erico/Ganesan/Riyad 各至少 1 次误判"应回"）→ A10 同一现场跑绿；新增 `tests\should_reply.tests.ps1`（88 断言）与 `tools\dedup_acceptance\`（A9 红基线 + A4/A5/A6 门禁离线验收）
- ⚠️ **阶段 A 完成后监控仍保持停止**：`AlibabaAutoReplyWatchdog` / `AlibabaAutoReplyHealth` 均 Disabled，未启动任何 monitor/watchdog 进程。阶段 B（完整限流）/ C（自愈定因）/ D（经老板同意后启用并观察 30 分钟）未做

## 2026-09-27 - 公海客户开发模块（阶段 1 侦察 + 阶段 2 试发）：新增 `scripts\gonghai\` 与 71 项回归测试

**背景**：老板要求在"不猜网页结构"的前提下开发阿里公海客户。链路经规划会话只读探测 + 本次实测确认：取客户名 → 加为我的客户 → OneTalk 搜索 → 校验 customerId → 发破冰消息。**试发是对外不可逆动作**，故模块默认关（`gonghai_enabled=false`）且带多重门禁。

- 新增 `scripts\gonghai\`：`gonghai_cdp.ps1`（公海专用 CDP 桥：按域取页、短连接、凭据事件静默丢弃）、`gonghai_lib.ps1`（限速/幂等/状态/页面恢复/认领/搜索）、`gonghai_probe.ps1`（试发 CLI，判定链固定顺序）、`gonghai_recon.ps1`（只读侦察器，含凭据擦除）、`icebreaker.md`（老板定稿话术）
- **未改** `monitor.ps1` / `reply_rules.json` / `reply_agent_prompt.md` / `lib\cdp.ps1` / `cdp.ps1`：发送复用 `lib\send.ps1` 的 `Send-OneTalkMessage`、写锁复用 `lib\lock.ps1`、健康复用 `lib\cdp.ps1` 的 `Test-PageHealth`、日志复用 `lib\log.ps1` 的 `Write-SkillLog`。公海取页因既有 `Get-Page` 是 onetalk-only 守卫而**另写**，不动共享实现
- **实测纠正 4 处早期记录**：①数据行须 `tbody tr.ant-table-row`（首行是 measure-row，全 TH）②行内 **15** 个 td（含选择列）③**客户名**是 `.name--ECjwwoJJ span`（粗体 600），`.companyName--oljcmVQI` 是公司名/别名/邮箱的次要行 ④OneTalk 搜索框 `type` 属性为空串，`input[type=text]` 永不匹配，须按 placeholder 过滤
- **关键时序（务必记住）**：认领后 OneTalk 搜索索引有同步延迟（实测约 1 分钟）⇒ 立即搜索得 0 结果，**不可据此判定路径不通**；`gonghai_probe.ps1` 内置 6 次重试
- **发对人判据**：详情卡 `.alicrm-customer-detail-card` 的 `customerId` 必须**精确等于**公海行 `data-row-key`，不等即 `ABORT_WRONG_CONVO` 拒发
- 新增 `tests\gonghai.tests.ps1`（**71 断言**）：话术与定稿逐字一致 + 合规（无数字/@/价格词/群发腔）+ 幂等键 + 限速硬下限（不小于 90000ms）与抖动区间 [63000,117000] + 配置越界**硬夹回** + 状态原子写 + 幂等判定 + BOM + 禁止项静态检查（不得出现表头全选 / 清空所有筛选项 / `Invoke-PageReload` / `chrome_ensure`）
- 硬约束：每条间隔不小于 90s 且 ±30% 抖动；单次运行不超过 3 条；写锁 `Get-AppLock` 取不到不强上；**操作 OneTalk 后必恢复列表**（清空搜索 → 点「全部」→ 断言 `.contact-item-container` 数量大于 0）；遇验证码/风控立即停机
- ⚠️ **阶段 2 未完成**：已发出 **2 条**（`GONGHAI-SENT`），未达 spec 要求的完整验证；**§1 #10「公海客户回复是否进待回复板块」未验证**（发送后 monitor 恰好停摆）。偏差与事故详见运行时数据根 `specs\` 下的 REPORT（不入库）

## 2026-09-26 - 周报补跑与守护判据加严：Weekly 改每日触发 + 每周幂等；`Test-WatchdogAlive` 去掉 logon-only 兜底

- `AlibabaAutoReplyWeekly` 触发器由"每周一 08:00"（关机即整周消失，实测 09-21 08:00 机器关着、20:01 才补跑且 `LastTaskResult=2147946720`）改为**每日 08:00 + `StartWhenAvailable` 补跑 + 保留 `LogonTrigger`**；`weekly_report.ps1` 新增**每周幂等守卫**（ISO 周键，状态存 `data\weekly_state.json`）保证一周只真跑一次，避免每日重发周报推送与重复 nudge——守卫命中时输出 `WEEKLY-SKIP` 并跳过生成与 nudge，写状态失败则 fail-open（宁可重跑一次也不整周不生成）；另加 `-DryRun`（只测守卫判定、零副作用）。`Test-WatchdogAlive` 删除"有 `LogonTrigger` 就返回 `$true`"的兜底分支（该分支对病灶态假阴性），改为**只有 `TimeTrigger + Interval=PT1M + Enabled=true` 才算已武装**，`detail` 三态区分"进程死 / 仅登录触发未武装 / 有 TimeTrigger 但未 PT1M"；未改 `Get-TaskFreshness` 名单与阈值。详见 `docs\KNOWN_EXCEPTIONS.md` E-22。

## 2026-09-26 - 守护可靠启动：Watchdog 任务恢复周期拉起（PT1M）+ 计划任务新鲜度自检

- `AlibabaAutoReplyWatchdog` 任务恢复时间触发器（`Interval=PT1M` 每分钟重复 + 失败重试 `PT1M`×3），静默无守护窗口由最长约 30 分钟压到 ≤1 分钟；`health_check.ps1` 新增第 7 项检查 `scheduled_tasks_fresh`（5 个"每日/每周型"任务的 `LastRunTime` 新鲜度，Watchdog 改由 `Test-WatchdogAlive` 断言"pid 存活 + `TimeTrigger`/`PT1M` 已武装"），`status.ps1` 删除"未排程 ⇒ 登录时触发"过时旁路；详见 `docs\KNOWN_EXCEPTIONS.md` E-21。

## 2026-09-18 - P0 优化：守护加固（任务修正 + Health 自动拉起）/ 重复发送修复 / 日志与 PII 治理 / 死信心跳

**背景**：09-16 watchdog 被任务空闲条件终止（0xC000013A）后未再运行；14 天日志分析发现 725 次发送中 141 对同买家同文案、间隔 ≤600s（≈19%）的重复发送；`ACCIO-PARSE-ERR` 因保留 JSON 换行产生多行日志；工作区残留 13 条含 PII 的未跟踪案卷。用户二次拍板取消 WinSW 服务化，改为任务修正 + Health 自动拉起（全程无需 Windows 密码）。

### 守护加固（P0-1）
- `AlibabaAutoReplyWatchdog` / `AlibabaAutoReplyHealth` 任务 `StopOnIdleEnd` true→false（根因修复；对象方式修改，BEFORE/AFTER XML 留证 `specs\_evidence_20260918_p0\`）
- `health_check.ps1` F8b：`watchdog_process=FAIL` 时以分离进程拉起 `watchdog.ps1 -Action start`（幂等：pid + 命令行双确认；heal 30 分钟节流，状态键 `watchdog_heal`；`HEALTH-HEAL pid=<new>` / `HEALTH-HEAL-FAIL` 留痕，不影响 exit 0）
- 实测：启动任务 → 按 pid kill → health_check → `HEALTH-HEAL pid=1960`，新进程存活（证据 `specs\_evidence_20260918_p0\heal_test.txt`）

### 重复发送修复（P0-2）
- `reply_engine.ps1` 新增 `ConvertTo-EpochMs`（13 位毫秒/10 位秒/`yyyy-MM-dd HH:mm:ss`/`yyyy/MM/dd HH:mm:ss` → epoch ms，非法 `$null`）与 `Test-AlreadyReplied`（文本相同且 ts 不更新=已回复；任一侧 ts 缺失/不可解析=保守判已回复；新 ts 严格更大=新消息）
- `monitor.ps1` 去重块改调 `Test-AlreadyReplied`；旧无 ts 记录升级写 `DEDUP-UPGRADE`；发送成功后 3 分钟会话冷却 `POST-SEND-COOLDOWN`（preview 变化自动解除）
- `tests\reply_engine.tests.ps1` 新增 17 断言（含 sandy 回归场景）

### 日志与 PII 治理（P0-3/4）
- `lib\accio.ps1`：`ACCIO-PARSE-ERR` 单行化（JSON 换行压空格 + `jsonErr=` 异常原因 + 截断 200 字符）
- 新增 `scripts\log_rotate.ps1`（超限移入 `logs\archive\`，保留 N 份，重试 3 次×2s，`-DryRun`）与 `scripts\retention.ps1`（`data\msgs_*.txt` 超期按月份打包 `data\archive\msgs_<yyyyMM>.zip`，只碰 msgs，`-DryRun`）；monitor 启动自动执行
- 新增 `tests\log_maintenance.tests.ps1`（22 断言：轮转/保留/DryRun）
- 13 条未跟踪案卷移入 `specs\案卷_20260915\`（SHA256 全部 MATCH，MANIFEST 留档）；8 个一次性脚本移入 `specs\归档\`；AUTOOPT 产物提交 `66a9e8b`

### 死信心跳（P0-5）
- 新增 `scripts\lib\deadman.ps1`（`Send-DeadmanPing`：空 URL→skip，GET 超时 10s，异常→fail 吞掉）；`health_check.ps1` 每轮 ping，`health.log` 每 6h 一行 `DEADMAN-PING ok|fail`（`data\deadman_state.json`）
- 本地 mock 实测通过（`PING /ping` → `ok`；空 URL → `skip`）；真实 healthchecks.io URL 待用户注册后填入 `deadman_ping_url`

### 配置与文档
- `config.json(.example)` 新增 `log_max_mb`(20) / `log_keep_files`(10) / `snapshot_retention_days`(90) / `deadman_ping_url`("")
- README / SKILL / 部署说明增补；`status.ps1` watchdog 行增加命令行校验

## 2026-09-16 - watchdog 死亡事故恢复 + F5 保活实测 + F8 健康心跳告警

**事故**：2026-09-15 20:30 Windows Update 计划外重启后，watchdog（PID 15532）仅存活约 19s 即被终止（LastTaskResult=0xC000013A；Task Scheduler Operational 日志当时禁用，死因未定论），此后 17.5h 无守护；monitor（PID 17256）存活但页面无会话，持续 `Scan cycle done` 静默空转，直至 14:03 CDP 掉线触发自愈、14:05 重新登录后才恢复回复。

### F5 保活路径实测（验证通过，未改代码）
- 分离进程实测 `control-agent.ps1 -Action start` 冷启动：`finished=True elapsed=2s`，输出 `CONTROL-STARTED`；`agent_start.ps1`（WaitForExit 60s）与 `watchdog.ps1`（75s 轮询）均为有界等待。结论：现网代码不存在"保活路径永久阻塞 watchdog"，不改代码；`agent_start.ps1` 的 60s 长等待列为观察项（出现 `WATCHDOG-AGENT: timeout` 时人工关注）

### F8 健康心跳告警上线
- 新增 `scripts\health_check.ps1`（8 项检查：monitor 进程/日志新鲜度、watchdog 进程、风暴冷却、企微连通、control-agent、CDP、页面登录态；每项 30 分钟去重，恢复推送 RECOVERED），结果写 `logs\health.log`，状态写 `data\health_state.json`
- 新增计划任务 `AlibabaAutoReplyHealth`（每 15 分钟，Interactive/Limited，IgnoreNew，ExecutionTimeLimit 5 分钟）
- 端到端实测：停 watchdog → `watchdog_process=FAIL` + `HEALTH-ALERT ... SENT_OK`；恢复 watchdog → `watchdog_process=OK` + `HEALTH-RECOVER ... SENT_OK`

### 事故期间发现
- 2026-09-16 15:24 调试 Chrome 实例消失（无崩溃事件记录），CDP 掉线；monitor 因旧列表逐项重试延迟自愈，人工执行 `chrome_ensure.ps1` 恢复 Chrome 后发现登录会话已过期，页面停在登录页且 `sif_form-submit` 按钮 disabled；用 CDP 可信输入重填并提交后恢复登录（15:32 起 `hasTa:true`）。F8 的 `page_logged_in` 检查覆盖此类"CDP 通但未登录"静默故障
- Task Scheduler Operational 日志本次尝试启用失败（执行会话非管理员，`wevtutil` 拒绝访问）；需管理员手动执行 `wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true`

## 2026-09-15 - 停摆根因修复（monitor 被误杀 / 僵锁自锁 / 风暴保护永久放弃）

**事故**：04:44–07:57 停摆约 3h05m。一轮真实回复耗时 >90s → watchdog 按"日志静默 > 90s"杀掉**正在工作**的 monitor → 强杀导致 `data\onetalk-write.lock` 残留僵锁 → `Get-AppLock` 删锁却不重试（`timeoutSec=0` 时 deadline 已过）→ 后续每轮 `LOCK-BUSY` 空转且日志静默 → 再被判 stale → 再杀，5 次后触发风暴保护 `exit 1` **永久停止自愈**，无人知晓直至人工巡检。

### F1 锁自愈（`lib\lock.ps1`）
- `Get-AppLock`：判定 holder 已死后**当场重试创建锁并返回 $true**（原实现 `continue` 在 `timeoutSec=0` 时直接退出循环返回 $false）。切断"僵锁 → 空转 → 误杀 → 新僵锁"闭环
- 新增回归测试 `tests\lock.tests.ps1`（11 断言：无锁可取 / 僵锁自愈 / 活锁不抢占且不删他人锁 / 测试锁不残留）；主套件 6 → 7 文件

### F2 stale 判定（`monitor.ps1` + `watchdog.ps1` + `lib\llm.ps1`）
- (a) **轮次心跳**：回复轮次内输出 `ROUND-START / ROUND-VISION-BEGIN|END / ROUND-LLM-BEGIN|END / ROUND-LLM-WAIT / ROUND-SEND / ROUND-DONE`；LLM 阻塞等待改为 `BeginGetResponse` + 15s 心跳轮询（**超时语义不变**，仍为 `timeout_sec`，超时仍归类 TIMEOUT 不重试），响应体改分块读取（StreamReader 保持 UTF-8 解码等价），使单次最长 LLM 调用不再产生 >30s 静默
- (b) **活锁豁免**：新增 `Test-LiveWriteLock`；`onetalk-write.lock` 持有 PID 存活时，watchdog 判 stale **不杀**只记 `treated as busy, skip`；真僵死路径日志也带上锁状态，便于复盘区分"在忙"与"真死"
- (c) **阈值**：静默阈值 90 → **240s**，新增 `config.json` 键 `watchdog_log_stale_sec`（缺省 240，可覆盖）；README Phase I 记录参数与语义

### F3 风暴保护改冷却 + 告警（`watchdog.ps1` + `status.ps1`）
- 命中风暴不再 `exit 1`，改为写入 `logs\watchdog_cooldown.json`（`until`/`reason`/`count`）进入冷却（`restart_storm_cooldown_min`，缺省 30min），并推企微 `[ALERT] watchdog 重启风暴(...)，进入冷却 N 分钟；请人工检查 monitor.log`（推送失败只记日志）
- 冷却期内主循环继续运行（抑制 monitor 重启，企微/control-agent 保活照常），每分钟留一行 `COOLDOWN` 状态；到期自动清冷却、恢复完整守护；进程被杀后重启会继承未到期冷却
- `status.ps1` 新增 `WATCHDOG COOLDOWN` 行

### F4 回复轮次总预算（`monitor.ps1` + `lib\llm.ps1`）
- 新增 `config.json` 键 `reply_round_budget_sec`（缺省 180s）；每次 LLM 调用前检查剩余预算，不足则跳过该调用并标记本轮；发送前若预算已耗尽则**本轮不发送**、保留待处理、下一轮重试，日志 `ROUND-BUDGET-EXCEEDED <key> elapsed=..s budget=..s stage=..`
- 多模态/附件识别路径纳入同一预算；重试的 3s 退避与总耗时计入预算

### F7 Accio 授权降噪与可观测（`lib\accio.ps1` + `status.ps1`）
- `AUTH-REQUIRED` 做 **5 分钟负缓存**：命中后不再每轮探测 `conversations`，直接回退 CDP（回复不受影响）；日志去重（命中一行 `negative-cache 300s`，期间每 ≥60s 一行 `ACCIO-AUTH-SKIP`）
- 负缓存状态落盘 `logs\accio_auth_state.json`，跨 monitor 重启生效；`status.ps1` 新增 `Accio 授权` 行
- 该状态多与 Accio 桌面应用更新/重启窗口重合，属瞬态；恢复直读需在 Accio 桌面应用重新登录

### 其他
- `lib\accio.ps1` 补 UTF-8 BOM（原文件无 BOM，违反"所有 .ps1 必须 UTF-8 带 BOM"，导致其中文日志行按 GBK 解析出现乱码）


## 2026-09-12 - Accio 网关迁移（读取增强）与 watchdog 保活修复

### A 包：Accio 读取增强（影子→读取灰度，CDP 始终兜底）
- 新增组件 `tools\accio-client`（Node 零依赖 CLI：status/conversations/messages/send + fake gateway 测试 14 例）；协议按实测调用方式自行重写（`/mcp/proxy`；`query_recent_conversation` 包 request、`query_conversation_msg_timeRange` 扁平、`send_msg` 双边 receiverAliID）
- 新增适配层 `scripts\lib\accio.ps1`：网关探测（60s 缓存）、会话映射（买家名归一化）、消息→`[BUYER]/[ME] ... @@TS:` 行转换、影子对比（模糊匹配+覆盖率）、内容重叠校验、发送封装；失败一律回退 CDP
- `monitor.ps1`：影子/读取钩子（日志 `ACCIO-SHADOW` / `ACCIO-READ`）；**去重/最新消息基准保持 CDP**，网关仅替换回复上下文（零行为突变）
- `lib\send.ps1`：发送切换钩子（`accio_send_enabled` 默认关；网关失败回退 CDP；未对真实买家测试）
- `config.json(.example)`：新增 `accio_shadow` / `accio_read_enabled` / `accio_send_enabled`（默认 false）
- 影子对比实测：22 会话，最新买家消息 20/22 匹配（2 例为同名多线程/DOM 杂质，已有重叠校验防护）
- 登录自启：启动文件夹快捷方式 `Accio Desktop.lnk`（计划任务注册需管理员权限，未采用）
- `status.ps1`：新增 Accio 状态行（进程/端口 4097/版本）；`watchdog.ps1`：Accio 轻量探测（持续不可达记 `WATCHDOG-ACCIO`，不自动重启桌面应用）
- 测试：`tests\accio.tests.ps1`（29 断言）+ accio-client node 测试（14 例）；主套件 6 文件 245 断言全绿

### C 包：watchdog control-agent 保活修复
- 保活块新增超时留痕：75s 无 `CONTROL-` 输出 → `WATCHDOG-AGENT: timeout waiting result (will retry next cycle)`（不设冷却，下轮立即重试）
- kill 测试 2 次（含 watchdog 重启后首轮）均在 1 个周期内拉起并留 `WATCHDOG-AGENT: CONTROL-STARTED` 日志

## 2026-09-12 - 报告企微推送 + 附件识别与模型切换

### 报告推送（A 包）
- 新增 `scripts\lib\report_push.ps1`：质量/周报生成后自动推企微摘要（统计+重点项+文件名，≤800 字符）；同报告去重（`data\report_push_state.json`，上限 100）；`report_push_enabled` 开关；失败只记日志
- 挂接：`analyze_replies.ps1`（quality）/ `weekly_report.ps1`（weekly，nudge 前），全程 try/catch 不影响任务退出码
- 测试 `tests\report_push.tests.ps1`（解析器 33 断言）+ 两份 fixture

### 附件识别与模型切换（B 包）
- 模型切换：`llm_config.json` → `deepseek-v4-flash` + `thinking:{type:disabled}`（默认思考模式会耗尽 max_tokens 导致空回复，实测确认后关闭；文本延迟 ~1.5s）
- 新增 `scripts\lib\vision.ps1`（图片下载/多模态构造/提取解析/sidecar）与 `scripts\lib\doc.ps1`（CDP 页面上下文 fetch 优先 → PS 兜底 → 临时文件 → doc-reader）
- 新增组件 `tools\doc-reader`：PDF（文本层/扫描渲染）/xlsx/csv/docx → 文本或 PNG；PDF 引擎用 `@hyzyla/pdfium`（WASM；pdfjs+native canvas 实测原生崩溃）
- monitor 集成：JS 收集 `@@IMG`/`@@FILE` 标记（图片 ≤3、文件卡片兜底特征）→ PS 剥离后入快照/算 hash（格式不变）→ 图片多模态回复 / 文档解析回复 → 与回复解耦的提取调用（JSON → `data\vision_extract\<buyer>.json`，source=image/document）→ 失败回退 IMG_TEMPLATE / 普通文本流程
- `lib\goods.ps1`：Get-GoodsDataStatus / Get-GoodsDetails 合并 sidecar（weight/dims/cartons）
- 测试 `tests\vision.tests.ps1`（43 断言：data URL/多模态构造/提取解析/标记剥离 hash 稳定/sidecar/goods 合并）

## 2026-09-12 - control-agent 保活与整栈自启

- watchdog 升级五重守护：新增 control-agent 保活块（每 30s 幂等调用 `scripts\agent_start.ps1`；启动失败 5 分钟冷却；ALREADY-RUNNING/DISABLED 静默）
- 新增 `scripts\agent_start.ps1`：control-agent 保活启动器（四码：CONTROL-ALREADY-RUNNING / CONTROL-DISABLED / CONTROL-STARTED / CONTROL-START-FAIL）
- 停用标记机制：`tools\control-agent\data\control-agent.disabled`——`bin -Action stop` 自动创建（保活跳过）、`-Action start` 自动删除；status 显示 DISABLED 态
- `status.ps1` 纳入 control-agent（RUNNING/DISABLED/DOWN + agent.log 年龄）与计划任务第 5 项 `AlibabaAutoReplyWatchdog`
- 注册登录自启任务 `AlibabaAutoReplyWatchdog`（ONLOGON +30s，Hidden，ExecutionTimeLimit=PT0S 不限时，IgnoreNew）：登录后由 watchdog 带起 monitor / 企微 / control-agent

## 2026-09-12 - 精简与优化轮

### 资产归档
- 退役/休眠脚本归档：`wecom_command.ps1` / `notify.ps1` / `task_health.ps1` / `health_report.ps1` + 对应测试 → `backups\精简优化_20260912\`（manifest 可回溯，含哈希）
- 根残留清理：SKILL.md.pre / README_部署说明.md.pre / README_本地重建.md / package-lock.json / UPDATE_SPEC.md；auto_optimize 运行产物 .bak
- specs\ 已执行/报告（20 份）移入 `specs\归档\`

### 代码重构
- `cdp.ps1`：删除死分支 newtab/type/screenshot（仅保留 navigate/eval）
- CDP 端口收敛：`config.json` 新增 `cdp_port`（默认 9222），lib\cdp.ps1 / cdp.ps1 / status.ps1 / chrome_ensure.ps1 统一读取
- `reply_engine.ps1`：Generate-Reply 拆分（New-ReplyContext + Resolve-IntentEarly/Info/Data），签名与返回值不变，84 断言全绿
- `monitor.ps1`：Start-Monitor 拆分（Initialize-MonitorRuntime / Invoke-ScanRound / Invoke-ConvoItem），Cleanup-StaleState 优化为单次遍历；字面量逐字核对无丢失
- 删除零引用函数 `Get-WecomMessages`

### 提示词/语料治理
- `consolidate_prompt.ps1`：合并范围扩展到已有"历史红线归档"节，全局精确去重（32 条 → 32 条，无重复），prompt 159→143 行
- `auto_optimize.ps1`：新增 `-ConsolidateThresholdChars`（14000）/`-ConsolidateBlockThreshold`（4）阈值自动合并；never 超限由"保留最旧"改为"保留最新 40 条"并记录丢弃数

### 文档
- SKILL.md 激进瘦身（20.9KB → 6.6KB），参考区改为指向文件
- README.md 精简（-25%），事实修正（测试 140 断言 / 目录树 / 退役脚本移除）
- README_部署说明.md：计划任务 4 个、镜像新默认、control-agent 标注可选
- 镜像同步默认目录改为 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`

## 2026-08-24 - v2.0 大版本更新（Phase 0-3）

### 敏感信息与安全（P0）
- API key 迁入 `credentials.md`（新增 `- **API Key (api_key)**` 字段），`llm_config.json` 不再存任何敏感值
- 新建 `lib\creds.ps1`：`Get-CredentialValue` 统一解析账号/密码/API key（chrome_ensure 同步改用）
- `status.ps1` 新增"敏感信息审计"节：每次健康检查扫描 sk-key/password 明文
- `backup.ps1` 备份包不含凭据；`sync.ps1` 不推送凭据

### 目录隔离（P0）
- 运行日志 → `logs\`；买家消息快照 → `data\`；`scripts\` 仅保留代码/状态/规则；启动时自动迁移旧文件
- 涉及 9 个脚本路径拆分，全部走 `config.json` / `config.ps1` 集中配置

### 工程化（P1）
- 新增 `backup.ps1`（基线快照，保留 20 份）、`sync.ps1`（工作副本↔镜像同步）、`consolidate_prompt.ps1`（红线归档）
- 公共库五件套 `lib\`：creds / log / cdp / send / llm；monitor/nudge/chrome_ensure/watchdog/auto_optimize 全部接入，HttpWebRequest 与发送逻辑复制归零
- 回归测试 `tests\`（34 用例）：驱动修复 4 个引擎缺陷——计费/流程分支顺序、查件/询价分支顺序、Detect-Lang 西葡字典、Get-StableHash 归一化顺序
- 数据修复：reply_engine.ps1 首行乱码、reply_rules.json never 21→18 去重、auto_optimize 写入前精确去重+40 条上限、prompt 8 段红线→1 段归档
- 配置收敛：7 处硬编码兜底路径归零
- SKILL.md / README_部署说明.md 全量重写（目录结构、凭据格式、工具用法、回滚流程）

### 稳定性与性能（P2）
- reload 按需化：10 分钟 idle + 30 分钟 busy 兜底（config `reload_idle_min` 可调），替代原每 2 分钟无条件刷新
- 写互斥：`lib\lock.ps1`（锁文件+PID 存活校验+僵锁回收），monitor 每轮拿锁、nudge 发送前拿锁（10s 超时）
- 容量治理：state 记录 ≥200 条时清理 30 天无快照活动的买家；周报顺带删除 90 天前报告
- watchdog 增强：CDP 连续不可达 10 次自动跑 chrome_ensure；风暴阈值参数化（`restart_storm_count/window_min`）
- 新增 `task_health.ps1`：4 个计划任务超龄检测（Summary≤4.5h / Quality|Optimize≤26h / Weekly≤8 天）
- weekly_report 补跑机制：上次周报 >7 天自动补跑并标注
- P2.1（CDP 批量合并/常驻 daemon）评估后暂缓：热路径改动风险>收益，P2.2 已大幅降低页面负担

### 新功能（P3）
- `notify.ps1`：9 类关键事件扫描 + 30 分钟去重 → `logs\events.json`；配置 `notify_webhook` 可推企业微信/钉钉/Slack
- `dashboard.ps1`：聚合统计 HTML 看板（每日 06:00 建议），无买家 PII
- P3.4 买家档案评估后暂缓

### 已知说明
- 2026-08-24 08:00 Weekly 任务首次运行失败（新目录 logs\ 尚未创建），已补跑生成周报；补跑机制已落地
- monitor 期间两次双实例窗口（watchdog 重启竞态）已清理；单实例保护 + 写锁双重防线已生效
