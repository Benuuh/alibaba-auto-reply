# alibaba-auto-reply 代码更新 Spec

- 版本: v0.2 (草案)
- 日期: 2026-08-24
- 范围: 工作副本 `C:\path\to\alibaba-auto-reply` + 技能镜像 `C:\path\to\.dsh\skills\alibaba-auto-reply`
- 总目标: 在**不破坏当前稳定闭环**的前提下，分阶段完成 敏感信息治理 → 工程化重构 → 稳定性与性能 → 新功能

## 0. 已确认决策（用户拍板）

| 编号 | 决策 |
|---|---|
| D1 | **不做自动报价发送**（原 P3.1 取消；不生成、不发送报价，报价仍由人工完成） |
| D2 | **敏感信息（账号/密码/API key）只存 `credentials.md` 一个位置**，任何其他文件（配置/日志/报告/快照/备份）不得出现 |
| D3 | **日志与报告单独隔离存放**：日志独立目录、报告独立目录，与代码/状态分离，避免泄露 |
| D4 | 更新方向：全部分阶段（先治理敏感信息，再重构、性能、其余新功能） |
| D5 | **API key 不轮换**（2026-08-24 用户确认）：现有 key 直接迁入 credentials.md；历史明文残留由 P0.1 审计清理 |

## 0.5 执行状态（2026-08-24 更新）

| 条目 | 状态 | 备注 |
|---|---|---|
| P0.1 API key 收敛 | ✅ 完成 | credentials.md 三字段、lib\creds.ps1、4 脚本改造、双副本、全树 0 残留、LLM 实测 OK |
| P0.2 目录隔离 | ✅ 完成 | logs\ / data\ 生效、9 脚本路径拆分、启动迁移、status 全绿、Weekly 补跑成功 |
| P0.3 敏感审计 | ✅ 完成 | status.ps1 第 8 节，实测 [OK] |
| P1.1 backup.ps1 | ✅ 完成 | 快照 69KB/21 条目、无凭据/无运行时产物、保留 20 份 |
| P1.2 sync.ps1 | ✅ 完成 | -Status 实测 16 DIFFERS + 2 ONLY-WORK（待推送）；-Push 待执行 |
| P1.3 文档一致性 | ✅ 完成 | SKILL.md/README 重写：新目录结构、credentials 三字段、sync/backup/status 用法、reload 2 分钟、敏感铁律 |
| P1.4 数据修复 | ✅ 完成 | 乱码修复、never 21→18、auto_optimize 去重+上限40、prompt 8 段→1 段归档 |
| P1.5 公共库抽取 | ✅ 完成 | lib\llm/cdp/send/log/creds 五件套；monitor/nudge/chrome_ensure/watchdog/auto_optimize 全部接入；HttpWebRequest/send-textarea 复制归零；Invoke-LLM 实测 OK；重启后全绿 |
| P1.6 回归测试 | ⏳ 待做 | tests\ |
| P1.6 回归测试 | ✅ 完成 | tests\ 34/34 通过；测试驱动修复 4 个引擎缺陷（billing/process 顺序、查件/询价顺序、Detect-Lang 字典、StableHash 归一化） |
| P1.7 配置收敛 | ✅ 完成 | 7 处硬编码兜底归零，仅 config.ps1 合法 |
| Phase 2 全部 | ✅ 完成 | P2.1 评估后暂缓（2.1a/2.1b 改动热路径风险>收益，P2.2 已大幅降载）；P2.2 按需 reload（10min idle+30min busy 兜底，config 可调）；P2.3 写互斥锁（修复 timeoutSec=0 死锁 bug，nudge 10s 超时）；P2.4 state TTL 清理(200 条阈值/30 天)+reports 90 天清理；P2.5 watchdog CDP 兜底+风暴参数化+task_health.ps1+weekly 补跑；P2.6 回滚文档(README) |
| Phase 3 全部 | ✅ 完成 | P3.2 notify.ps1（9 类事件/去重/webhook 可选）；P3.3 dashboard.ps1（HTML 聚合看板，无 PII）；P3.4 评估后暂缓（页面操作风险>收益，按需实施） |

## 1. 现状基线（Spec 依据，均来自代码与运行数据实测）

| 项 | 实测值 |
|---|---|
| 运行时长 | ~10 天（monitor.log 18,685 行） |
| 闭环健康度 | 54 条 `SENT_OK`，0 LLM 错误，0 发送失败，0 监控异常 |
| 页面刷新 | 8 天 1834 次 reload（约每 6-7 分钟一次），每次 reload 后停 12s |
| 扫描周期 | 每轮 12-15 秒（主要开销 = 每次 CDP eval 新起 powershell 进程） |
| state.json | 107 条去重记录，**无 TTL，只增不减** |
| reply_rules.json | never 区 21 条原文 / 18 条去重后 → **3 组完全重复** |
| reply_agent_prompt.md | 已被 auto_optimize 追加 8 段红线，内容重叠，共 11488 字节 |
| 计划任务 | Summary(4h)/Quality(05:00)/Optimize(05:30)/Weekly(周一08:00) 均存在；**Weekly 8/24 应跑未跑**（Last Run 仍为 8/17） |
| 版本管理 | **无 git**，无任何版本化手段（仅 .bak 文件） |
| 双副本 | 工作副本 ↔ 镜像的 `reply_rules.json`/`reply_agent_prompt.md` 已漂移；SKILL.md 引用的 `sync.ps1` 不存在 |
| 🔴 敏感信息 | `llm_config.json` **明文存 API key**（工作副本+镜像各一份）；`credentials.md` 仅存账号/密码；脚本无硬编码凭据；日志/状态/报告无 key/password 泄露 |
| 目录布局 | `scripts\` 混放：代码、状态(pid/state)、规则、**日志(856KB+5MB归档)**、**816份买家快照(1.44MB,含对话PII)**；`reports\` 已独立(59份md) |

## 2. 硬性约束（所有阶段必须遵守）

1. PS 5.1：禁止 `? :` / `??` / `||`；CancellationToken 用 `::None`
2. 所有脚本 **UTF-8 带 BOM**（无 BOM 中文按 GBK 解析报错）
3. LLM 调用必须 `HttpWebRequest` + `StreamReader(UTF8)` 显式解码（禁止改回 Invoke-RestMethod）
4. 常驻目录 `scripts\`，不依赖 Temp
5. **敏感信息铁律（D2）**：账号/密码/API key 只允许出现在 `credentials.md`（工作副本与镜像各一份副本）；代码只允许引用字段名，不允许内联值；日志中禁止输出凭据值（登录状态只记布尔/阶段，不记账号）
6. **目录隔离铁律（D3）**：运行日志 → `logs\`；报告 → `reports\`；买家快照等业务数据 → `data\`；代码+状态+规则 → `scripts\`
7. CDP 超时保护保留：WS 连接 15s / 接收 20s；截图响应超 64MB 风险维持 DOM 优先
8. 改动 monitor.ps1 需重启监控：先 `stop` 再 `start`（含重定向参数），并在低询盘时段操作
9. 任何会改变行为/格式的改动，先备份原文件（`*.pre` 后缀），发布观察 24h 无回归后再清理
10. 所有输出文件（日志/报告/JSON）继续 UTF-8；与既有格式保持兼容：日志 `yyyy-MM-dd HH:mm:ss | msg`、快照 `# BUYER: x`、`[BUYER]/[ME]` 标记（下游 summarize/analyze_replies/weekly_report 依赖）

---

## Phase 0 — 敏感信息治理与目录隔离（最高优先级，先行）

### P0.1 API key 收敛到 credentials.md
- **现状**：`llm_config.json` 明文存 `api_key`（工作副本 + 镜像各一份，历史备份中可能也有）。
- **方案**：
  1. `credentials.md` 增加字段 `- **API Key (api_key)**：<key>`（与现有 account/password 行同格式）
  2. `llm_config.json` **删除 api_key 字段**，只保留非敏感项：`model / temperature / max_tokens / timeout_sec / endpoint`
  3. 新建 `scripts\lib\creds.ps1`：`Get-CredentialValue($name)` 统一解析 credentials.md（兼容现有正则：`- \*\*账号 \(account\)\*\*：(\S+)`、`- \*\*密码 \(password\)\*\*：(\S+)`，新增 `- \*\*API Key \(api_key\)\*\*：(\S+)`）；解析失败返回 $null 并日志
  4. 改造 LLM 读取方：monitor.ps1（Get-LLMConfig）、auto_optimize.ps1、nudge.ps1 的 `$cfg.api_key` 改为 `Get-CredentialValue 'api_key'`；chrome_ensure.ps1 的账号/密码解析改走同一函数（消除 3 处正则复制）
  5. 全树审计：grep `sk-[A-Za-z0-9]{10,}`（排除 chrome-profile）确认 0 命中，含 `*.bak / *.pre / backups\*`；发现残留立即清理
  6. **不轮换 key（决策 D5）**：现有 key 直接迁移至 credentials.md；镜像同步清理；未来如需轮换，走 P0.1 第 5 步审计流程
- **验收**：`grep -r "sk-" scripts\ llm_config.json` 0 命中（lib\creds.ps1 与镜像 credentials.md 除外）；monitor 重启后 LLM 回复正常（key 从 credentials.md 读到）；删除 credentials.md 模拟 → 各脚本日志报"凭据缺失"而非崩溃。

### P0.2 目录隔离（logs\ / data\ / reports\）
- **现状**：`scripts\` 混放运行日志（monitor.log 856KB + monitor_*.log 5MB 归档 + watchdog.log + out/err）与买家快照（816 份 1.44MB，含对话 PII）。
- **方案**：
  1. 新建目录：`logs\`（运行日志）、`data\`（msgs_* 快照；预留 buyers 档案）
  2. `config.json` 增加 `logs_dir` / `data_dir`；config.ps1 `Get-SkillPath` 增加 "logs" / "data"（缺省 = deploy_root 下对应目录）
  3. 路径拆分（全脚本）：
     - **日志**：monitor.log 及归档、watchdog.log、monitor_out/err.log → `logs\`
     - **快照**：msgs_*.txt → `data\`
     - **保留 scripts\**：代码、state.json(+bak)、*.pid、summary_last.json、nudge_state.json(+bak)、reply_rules.json、reply_agent_prompt.md、config.json
     - 涉及脚本：monitor / watchdog / chrome_ensure / auto_optimize / nudge / summarize / analyze_replies / weekly_report / status
  4. 迁移：启动时自动把旧文件 **move**（非复制）到新目录一次；迁移动作写日志
  5. 轮转/保留策略沿用：monitor.log 5MB 轮转留 20 份（在 logs\ 内）；msgs 保留 200 份（在 data\ 内）
  6. status.ps1 按新路径检查并显示目录分布
  7. SKILL.md / README_部署说明.md 更新目录结构与启动命令
- **验收**：重启 monitor 后 24h，`logs\` 出现新日志且 `scripts\` 不再新增 .log/.txt 快照；旧文件已迁移（scripts\ 仅剩代码+状态+规则）；status.ps1 全绿。

### P0.3 凭据写入防线（防未来回潮）
- **方案**：`status.ps1` 增加"敏感信息审计"小节：扫描 `scripts\*.ps1,*.json,*.md,*.log` + `logs\` + `reports\`（排除 lib\creds.ps1、credentials.md）中的 `sk-[A-Za-z0-9]{10,}` 与 `(password|pwd)\s*[:=]\s*\S+` 模式，命中显示 [!!]；作为每次健康检查的固定项。
- **验收**：注入一行含 sk- 的测试日志 → status 显示 [!!]；清除后恢复 [OK]。

---

## Phase 1 — 工程化重构（底子）

### P1.1 基线快照与版本化
- **现状**：无 git；`.bak` 覆盖式备份无历史。
- **方案**：新建 `scripts\backup.ps1`：
  - `-Snapshot`：把 `scripts\*.ps1,*.json,*.md` + 根目录 `SKILL.md,README_部署说明.md,llm_config.json` 打包为 `backups\alibaba-auto-reply_<yyyyMMdd_HHmmss>.zip`，保留最近 20 份（**不打包 credentials.md 内容以外的敏感文件**——credentials.md 不入备份包，防止备份文件成为新的泄露点）
  - 每次 `sync.ps1 -Push` 前自动触发快照
- **验收**：`backups\` 存在且可还原；备份包内 grep 无 sk-key 明文；README 记录还原步骤。

### P1.2 补齐 sync.ps1（SKILL.md 已引用但文件不存在）
- **现状**：SKILL.md L22「改完代码跑 `sync.ps1 -Push` 同步」，文件缺失 → 双副本必然漂移（已发生）。
- **方案**：新建 `sync.ps1`，默认方向 **工作副本 → 镜像**：
  - `-Push`：同步 `scripts\*.ps1 / *.json / *.md`（含 reply_rules.json、reply_agent_prompt.md）与根 `SKILL.md / README_部署说明.md / llm_config.json`；先备份镜像旧版为 `*.prev`
  - `-Pull`：反向（镜像 → 工作副本，用于恢复）
  - `-Status`：两侧 hash 对比，列出 AHEAD/BEHIND/DIFFERS/ONLY-ONE-SIDE，不改动文件
  - **credentials.md 处理（D2）**：默认**不推送不拉取**，仅 `-Status` 显示"两侧凭据存在性一致"；镜像中的 credentials.md 保留为占位模板（账号/密码/API key 行替换为占位符），工作副本为真实值 —— 防止镜像文件（可能被技能分发/备份带走）扩大泄露面
  - `-Exclude` 默认排除：运行时产物 `msgs_* / state.json* / *.pid / *.log / *.bak / *.pre / nudge_state* / summary_last.json`、`chrome-profile\`、`reports\`、`logs\`、`data\`、`backups\`
  - 同步前自动跑 P1.1 快照
- **验收**：`-Status` 输出与真实差异一致；`-Push` 后镜像 hash 与工作副本一致（credentials.md 除外）；SKILL.md 同步更新为真实用法。

### P1.3 文档-代码一致性修正
- **现状**（实测不一致项）：
  1. SKILL.md L96「每 10 分钟强制 reload」 vs monitor.ps1 L465 `$reloadIntervalMin = 2`（实际 2 分钟）
  2. monitor.ps1 L9 注释「与回归测试共用同一份代码」 vs 无任何测试脚本
  3. SKILL.md 核心文件表缺 nudge 触发条件细节
  4. README_部署说明.md 需核对与现状一致（部署路径/计划任务清单/新目录结构）
- **方案**：逐一修正；P2.2 落地后把 reload 描述改写为新策略；P1.6 落地后把注释改为真实测试路径。
- **验收**：grep 全文不存在"引用不存在文件/与代码不符"的表述；SKILL.md/README 与代码行为一致。

### P1.4 数据修复
- **P1.4a reply_engine.ps1 L1 乱码**：`# 鍥炲寮曟搸...` 为 UTF-8 双重编码损坏。修复为正确注释「回复引擎(纯逻辑,无文件/网络依赖):语言检测/信息缺口核对/规则回复生成/模板解析」。改后验证整文件可被 PS 解析（`[scriptblock]::Create((Get-Content -Raw))`）。
- **P1.4b reply_rules.json never 区去重**：21 → 18 条（3 组完全重复：L33/L42、L36/L41、L38/L40）。去重前备份；去重后校验 JSON 合法。
- **P1.4c auto_optimize.ps1 防重复追加**：追加前对 `never`/`redlines` 做 **Trim + 小写归一后的精确去重**；增加总量上限 `MaxNeverTotal=40`、`MaxRedlinesTotal=40`，超限停止追加并写日志告警。
- **P1.4d prompt 膨胀治理**：新建 `scripts\consolidate_prompt.ps1`：合并 8 段自动优化红线（保留日期归档节，正文只留生效红线）；`-DryRun` 预览；合并前备份；auto_optimize 写入前检测 prompt > 12KB 时提示运行。
- **验收**：修复后文件可解析、无重复条目、prompt 体积下降且语义无损（合并前后 LLM 行为抽查 5 条真实快照）。

### P1.5 公共库抽取（消灭复制）
- **现状**：LLM 调用体在 monitor.ps1 L347-409 / auto_optimize.ps1 L66-87 / nudge.ps1 L64-87 三处复制；发送逻辑 monitor `Send-Message` 与 nudge `Send-Nudge` 两处复制；`Cdp-Eval`/`Test-CdpReady` 四处复制；`Write-Log` 五个脚本各一份。
- **方案**：新建 `scripts\lib\`（UTF-8 带 BOM、PS 5.1 兼容、dot-source）：
  - `lib\creds.ps1`（P0.1 已建）：Get-CredentialValue
  - `lib\llm.ps1`：`Invoke-LLM($messages, $temperature, $maxTokens)` → content 或 $null；内含 HttpWebRequest+UTF8、重试(429/5xx 一次,3s 退避)、超时、错误分类日志（`LLM error [TYPE]` 保持现有格式）；**key 从 Get-CredentialValue 取，禁止接收 key 参数**
  - `lib\cdp.ps1`：`Invoke-CdpEval($js)` / `Test-CdpReady`
  - `lib\send.ps1`：`Send-OneTalkMessage($buyer, $text)` = 打开会话 + 会话名校验(ABORT_WRONG_CONVO) + 原生 setter 填值 + 发送按钮 + `LEN:0` 校验
  - `lib\log.ps1`：`Write-Log($msg, $logFile)`（轮转逻辑从 monitor.ps1 L26-37 抽出，日志目标目录 = logs\）
- **迁移要求**：monitor.ps1 行为零变化（日志行格式、返回值、冷却逻辑不变）；auto_optimize/nudge 输出码（AUTOOPT-*/NUDGE-*）不变。
- **验收**：`grep -c "HttpWebRequest" scripts\*.ps1` 只剩 lib 一份；`grep -c "send-textarea"` 只剩 lib 一份；回归测试全绿；monitor 重启后 24h 无行为差异。

### P1.6 回归测试（monitor.ps1 注释声称存在，实际没有）
- **方案**：新建 `tests\reply_engine.tests.ps1`（零依赖自写断言）：
  - 覆盖 19 条规则分支：指责不读 / 否定拒绝 / 感谢(含询盘词不误判) / 简短确认(含"yes it is 20kg"不误判) / 语气词 / 问是否 AI / 纯问候 / 稍后回来 / 联系方式 / 流程 / 计费 / 时效 / 电池(含已给 SDS 不重复要) / 砍价 / 比价 / 无供应商 / 供应商 / 信息提供(缺失 0/1/2/3 项、追问≥2 次转 waitTone) / 地址 / 询价 / 查件 / 默认追问
  - `Get-MissingInfo` 中英西葡混合用例；`Get-StableHash` 归一化用例；`Detect-Lang`；`Get-CredentialValue` 解析用例（用测试夹具 credentials）
  - 黄金样本：从真实 `data\msgs_*.txt`（P0.2 后新路径）抽 5 条脱敏会话断言意图分支
  - 新建 `tests\run_tests.ps1`：汇总 PASS/FAIL，失败退出码非 0
- **验收**：全部通过；monitor.ps1 L9 注释改为真实路径；后续改动 reply_engine/lib 必跑。

### P1.7 配置收敛
- **现状**：`if (-not $LogDir) { $LogDir = Join-Path "<deploy_root>\..." }` 兜底硬编码散落 7 个脚本。
- **方案**：删除各脚本兜底硬编码，统一 `Get-SkillPath`；config.json 增加可选参数（缺省不变，向后兼容）：`reload_idle_min`、`llm_retry`、`state_ttl_days`、`restart_storm_count/window_min`。
- **验收**：grep 确认 `Join-Path "<deploy_root>` 只出现在 config.ps1（最后兜底）与 config.json；无 config.json 时各脚本仍可用默认路径。

---

## Phase 2 — 稳定性与性能

### P2.1 消除 CDP 进程启动开销（扫描周期 12-15s → ≤6s）
- **现状**：monitor 每个 CDP 操作都 `powershell -File cdp.ps1` 新起进程（1-2s），单会话处理含 ~8 次 eval。
- **方案（先 2.1a 后 2.1b）**：
  - **2.1a 批量合并（低风险，先做）**：「打开会话 + 等待 + 抓消息」与「填值 + 点击 + 校验」各自合并为 1 次 eval（JS 内 Promise 轮询实现等待，cdp.ps1 已带 `awaitPromise:true`）。预计单会话 eval 次数 8 → 3。
  - **2.1b 常驻 CDP daemon（中风险，评估后做）**：`scripts\cdp_daemon.ps1` 由 monitor 启动为子进程，stdin/stdout JSON 行协议；lib\cdp.ps1 优先走 daemon、失败自动回退子进程模式；daemon 僵死检测（心跳超时 10s 重启）。
- **验收**：monitor.log 两次 `Scan cycle done` 间隔均值 ≤6s；无新增错误；CDP 掉线自愈路径仍生效。

### P2.2 reload 策略优化（1834 次/8 天 → 降 70%+）
- **现状**：monitor.ps1 L465 每 2 分钟无条件 `location.reload()`，每次后停 12s；SKILL.md 误写 10 分钟。
- **方案**：按需 reload，仅当满足其一：① 列表抓取失败连续 2 次（现有 emptyStreak 保留）；② 距上次「列表出现新会话/预览变化」超过 `reload_idle_min`（默认 10 分钟，config 可调）；③ 连续忙处理超过 30 分钟。与 CDP 掉线自愈路径互斥不冲突。
- **验收**：8 天对照期 reload 次数下降 ≥70%；用 data\msgs_*.txt 时间线验证无新询盘漏检（新会话距上次处理 >15 分钟记为失败）；SKILL.md 同步改写。

### P2.3 monitor/nudge 写互斥
- **现状**：nudge（计划任务）与 monitor 可能同时操作同一页面发送消息，无互斥。
- **方案**：`lib\lock.ps1`：`Get-AppLock('onetalk-write', $timeoutSec)` / `Release-AppLock`（锁文件含 PID+时间戳，持锁进程存活校验，僵锁自动回收）。monitor 每轮处理前非阻塞尝试获取，失败本轮跳过；nudge 发送前获取，超时 10s 放弃并记日志。
- **验收**：monitor 运行中手动跑 nudge（-DryRun 后再真实跑一次）无 ABORT_WRONG_CONVO、无重复发送；日志有明确锁记录。

### P2.4 数据容量治理
- **现状**：state.json 107 条只增不减；reports 无限累积（59 份）；msgs 保留 200 份（已有，P0.2 后位于 data\）。
- **方案**：
  - state.json：启动时 + 每日 04:00 前清理 `state.replied` 中超 `state_ttl_days`（默认 30 天）的记录；清理动作写日志
  - reports：weekly_report 顺带删除 90 天前的 `quality_* / reply_summary_* / weekly_*`
- **验收**：state.json 条目数封顶；日志记录每次清理数量；报告目录有界。

### P2.5 守护与任务自愈增强
- **现状**：watchdog 只盯 monitor 进程与日志；**实测 8/24 周一 08:00 Weekly 任务应跑未跑**（Last Run 仍为 8/17）。
- **方案**：
  1. watchdog 增加 CDP 兜底：CDP 连续不可达 > 10 分钟由 watchdog 直接跑 chrome_ensure.ps1
  2. 新建 `scripts\task_health.ps1`（每日 07:00 或并入 watchdog）：检查 4 个计划任务最近运行时间——Summary ≤4.5h、Quality/Optimize ≤26h、Weekly ≤8 天；超龄写告警日志（供 P3.2 通知消费）
  3. weekly_report.ps1 增加「补跑」：若上次周报 >7 天（读 reports\weekly_*.md 最新时间），任意一次运行时自动补跑并写日志
  4. watchdog 风暴阈值参数化（config: `restart_storm_count`=4 / `restart_storm_window_min`=10）
- **验收**：模拟删除最新周报后手动跑 weekly_report 触发补跑；task_health 能识别"任务超龄"；告警进入日志。

### P2.6 恢复与回滚流程
- **方案**（写入 README_部署说明.md）：
  - 代码回滚：`backups\` 解包还原 → 重启 monitor
  - 配置回滚：`reply_rules.json.pre / reply_agent_prompt.md.pre / *.prev`（sync 备份）还原
  - 状态回滚：`state.json.bak` 还原（dedup 丢失风险 = 可能重复回复，需人工评估）
- **验收**：README 有可照做的回滚章节。

---

## Phase 3 — 新功能（P3.1 已按决策 D1 取消）

### P3.2 异常告警通知
- **方案**：新建 `scripts\notify.ps1`：
  - 事件源 1（内嵌）：monitor 关键事件（LLM error 连续 3 次 / SENT 失败进重试队列 ≥3 次 / CDP fail x3 / ABORT_WRONG_CONVO / RESTART-STORM / 登录失败 / 凭据缺失）写 `logs\events.json`（追加式，去重窗口 30 分钟）
  - 事件源 2（兜底）：watchdog / task_health 扫描补写
  - 通道：默认日志；config.json `notify_webhook` 配置后发通用 JSON POST（企业微信/钉钉/Slack 兼容格式）；**通知内容禁止包含凭据、完整账号、API key**
- **验收**：注入模拟事件能产出事件记录；配置 webhook 后收到真实推送；无 webhook 时零影响。

### P3.3 数据看板（HTML）
- **方案**：`scripts\dashboard.ps1`：解析 `logs\monitor.log`（回复数/买家/LLM 成功率/平均周期/每日分布）生成 `reports\dashboard.html`（纯内联 JS 图表，无外部依赖）；计划任务每日 06:00。**看板只输出聚合统计，不输出买家名/对话内容/地址等 PII**。
- **验收**：页面数据与 status.ps1/周报口径一致（同源解析）；无 PII 字段。

### P3.4 买家档案利用（可选，stretch）
- **方案**：抓取 `.alicrm-customer-detail-card`（国家/注册时间/标签/ID）→ `data\buyers\<key>.json`；国家并入 LLM 上下文；周报增加国别分布。**档案含买家 PII，仅存本机 data\，不入 reports\ 与任何备份/同步包**。
- **验收**：新增档案文件；LLM 上下文含国家字段且不影响既有红线；status.ps1 可显示档案数量。

---

## 3. 每阶段验收与发布流程

1. **阶段内**：每项按验收标准逐条过；改 monitor.ps1 前先 `backup.ps1 -Snapshot`，发布窗口选低询盘时段，重启后观察 30 分钟（日志心跳 + 一轮完整会话处理）
2. **阶段闸门**：`tests\run_tests.ps1` 全绿 + `status.ps1` 无 [!!]（含 P0.3 敏感审计项）+ 24h 无回归
3. **阶段交付**：更新 SKILL.md / README_部署说明.md；`sync.ps1 -Push` 镜像同步；发布记录写入 `docs\CHANGELOG.md`（新建）
4. **每次发布后执行 P0.3 审计**：确认无敏感信息回流

## 4. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| API key 迁移后 LLM 调用失败 | 高 | P0.1 先做解析函数并单测；删除 key 前先验证 credentials.md 读取路径可用；保留旧 key 至观察期结束再提示轮换 |
| 目录迁移导致脚本找不到日志/快照 | 高 | P0.2 迁移逻辑 move+写日志；status.ps1 先行适配；24h 观察 |
| P2.1 合并 JS 引入页面操作行为变化 | 中 | 2.1a 先行 24h 观察；回退模式保底 |
| P2.2 reload 减少导致长连接失效漏检 | 中 | reload_idle_min 默认 10 分钟保守值；msgs 时间线验证漏检 |
| P1.5 公共库抽取改动 monitor 热路径 | 中 | 行为零变化要求 + 全量回归 + 24h 观察 |
| auto_optimize 继续追加导致规则膨胀 | 低 | P1.4c 上限 + P1.4d 合并工具 |
| 双副本漂移复发 | 低 | P1.2 sync.ps1 落地 + 发布流程强制 -Push |
| 敏感信息回潮（新脚本内联 key） | 中 | P0.3 status 审计项 + 代码评审约束 |

## 5. 建议排期

- **Phase 0**（敏感信息+目录隔离）：约 1-2 个工作日，**最先做**
- **Phase 1**：约 3-4 个工作日（P1.1/1.2/1.3/1.4 可并行，P1.5 依赖 1.4 完成后统一动 monitor，P1.6 可与 1.5 同步编写）
- **Phase 2**：约 2-3 个工作日（2.1a/2.2/2.4/2.5 可并行；2.1b 单独评估）
- **Phase 3**：约 2-3 个工作日（3.2/3.3 可并行；3.4 可选）
- 每阶段之间至少 24h 观察期，全部完成约 2 周

---

# v0.3 迭代 Spec（2026-08-24 与用户商议确定）

- 版本: v0.3 (草案)
- 日期: 2026-08-24
- 目标: 在 v2.0 稳定基线上，深化回复质量、打通企业微信报价提醒、补全运维闭环、加固稳定性
- 运行依据: 重复提问连续 3 天出现（08-22/23/24 各 3-4 位买家）；task_health/notify/dashboard 未接入计划任务；今日两次双实例竞态；reload 降频已验证（-75%）

## v0.3 已确认决策

| 编号 | 决策 |
|---|---|
| V1 | ~~模拟已登录的企业微信 PC 客户端~~ **变更（2026-08-24 实施后修订）**：用户坚持长连接方案 → 最终采用**企业微信官方智能机器人 WebSocket 长连接**（`wss://openws.work.weixin.qq.com`，官方 @wecom/aibot-node-sdk，Node 常驻服务 wecom_bot.js，自动认证+心跳+指数退避重连）；凭据 botId/secret 存 credentials.md |
| V2 | 提醒**先发给自己验证**（机器人单聊，userid 即 chatid）→ 已跑通（测试消息接收、中文 UTF-8 修复） |
| V3 | **实时触发**：监控检测到买家数据齐全立即提醒；同买家节流（24h 内最多 1 次） |
| V4 | 提醒内容**概要式**：买家名 + 货物名称 + 重量/尺寸/地址齐全度 + 建议动作；不含对话原文 |
| V5 | 不做自动报价发送（D1 保持不变，仅提醒人工报价） |
| V6 | **齐全判定 = 重量+尺寸+地址 3 项**即可提醒；图片作参考不阻塞 |
| V7 | **全天实时**提醒，不设免打扰时段（用户明确） |
| V8 | ~~允许激活企业微信窗口~~ **已过时**：长连接方案不依赖窗口，无打扰（SendKeys 方案实测否决：窗口前置依赖不可行） |
| V9 | 货名提取不到显示"未知"，不阻塞提醒 |
| V10 | 发送编码：PS 5.1 必须显式 UTF-8 字节 POST（字符串 body 按 GBK 发送会中文乱码） |
| V11 | PS 5.1 坑：`Add-Member` 到 Hashtable 后 `ConvertTo-Json` 序列化为空——状态写入必须用 Hashtable 键赋值 |

## A. 回复质量深化（重复提问根因）

### A1. LLM 追问上限硬约束
- **现状**：回复主要走 LLM；prompt 的"同字段追问≤2 次/承诺提供不再问"是软约束，LLM 不严格遵循 → 质量报告 3 天连续标记重复提问
- **方案**：monitor 调用 LLM 前，从 context 统计 ME 侧问句按字段计数（weight/dimension/address/image/supplier），在 user 消息中附加结构化段落：
  `[追问统计] weight×2, address×1（≥2 视为已问尽，转为收尾等待语气；买家承诺提供 X 的字段不再问）`
- **涉及**：monitor.ps1 Generate-Reply-LLM、reply_agent_prompt.md 第三步补充该段落的语义说明、tests 补 2 个用例
- **验收**：注入含 2 次 weight 追问的 context → LLM 回复不含再次索要 weight；下周质量报告重复提问标记较本周（7 例）下降 ≥50%

### A2. 买家承诺识别（结构化）
- **现状**：买家说 "will send dimensions later" 后，后续轮次可能仍被追问（prompt 软规则偶尔不生效）
- **方案**：monitor 从 context 检测买家承诺句（will send/share/provide/let me check + 字段词），生成 `[承诺字段] dimension` 附入 LLM 上下文；规则引擎 Get-MissingInfo 增加承诺字段跳过逻辑
- **涉及**：monitor.ps1、reply_engine.ps1（Get-MissingInfo 加参数）、reply_agent_prompt.md、tests 补用例
- **验收**：承诺场景 5 组真实快照抽测，回复不再追问承诺字段；回归测试全绿

### A3. 质量报告证据化
- **现状**：analyze_replies 只标记"重复提问"布尔，无法定位哪两轮问了什么
- **方案**：报告中重复提问行附上最近两次问句（时间+内容截断 60 字符）
- **涉及**：analyze_replies.ps1
- **验收**：报告出现"⚠️ 重复提问: 08-22 10:31 'Could you share the weight?' / 08-22 12:05 '...weight...'" 形式

## B. 企业微信报价提醒（V1-V5）

### B0. 可行性探测（前置，必须先过）
- 确认 WXWork 主窗口可激活（AppActivate）；探测 UI 自动化可行性：
  - 方案 P1（推荐先试）：**UIAutomation** 枚举主窗口控件树，找会话列表/输入框/发送按钮
  - 方案 P2（备选）：**SendKeys 键盘流**——激活窗口 → Ctrl+F 搜索"文件传输助手" → Enter → 输入消息 → Enter
  - 以"文件传输助手"实测发送一条 "test" 成功为通过标准
- **验收**：文件传输助手收到测试消息；失败则记录原因并回退方案

### B1. quote_remind.ps1（提醒生成与发送）
- 数据源：复用 summarize 的齐全度判断（Get-GoodsDataStatus 逻辑抽到 lib，避免复制）
- 流程：扫描 data\msgs_*.txt 最新快照 → 4 项齐全（重量/尺寸/地址/图片）且货名可识别 → 未提醒过（state.reminded.<buyer> = 日期）→ 组装概要消息 → 发送（B0 通道）→ 记录去重
- 节流：同买家 24h 内最多 1 次；已提醒后买家又有新信息变化 → 可再提醒（按快照内容 hash 变化判断）
- 消息模板：
  ```
  [报价提醒] 买家 {name} 货物信息已齐全
  货物: {goods}
  重量/尺寸/地址: 齐全
  建议: 人工核对后给出报价
  ```
- **验收**：手动运行 quote_remind.ps1 在文件传输助手收到真实买家概要；重复运行不重复发送；无齐全买家时输出 NO-READY

### B2. 实时触发（monitor 内嵌）
- monitor 处理完会话、判断买家数据齐全（复用 B1 判断）→ 异步触发 quote_remind 逻辑（不阻塞主循环；失败仅记日志）
- 触发节流与 B1 共用 state.reminded
- **验收**：测试买家补全数据后 1 个扫描周期内收到提醒；monitor 日志有 QUOTE-REMIND 记录

## C. 运维闭环（工具接入计划任务）

| 工具 | 计划任务 | 频率 | 说明 |
|---|---|---|---|
| task_health.ps1 | AlibabaAutoReplyTaskHealth | 每日 07:00 | 4 任务超龄检测 → monitor.log 告警（notify 消费） |
| notify.ps1 | AlibabaAutoReplyNotify | 每 4 小时（与 Summary 同频 10:28/14:28/18:28/22:28/02:28/06:28） | 事件扫描+去重→events.json；webhook 未配置时仅本地 |
| dashboard.ps1 | AlibabaAutoReplyDashboard | 每日 06:00 | 生成 reports\dashboard.html |

- **验收**：schtasks 列表出现 3 个新任务；次日确认各自产物（告警日志/events.json/dashboard.html 时间戳更新）

## D. 稳定性加固

### D1. watchdog 双实例竞态加固
- **现状**：08-24 发生两次双实例（watchdog 误判 NOT_FOUND 重启 + 手动启动并存）；pid 文件校验在启动竞态下可能失效
- **方案**：Start-Monitor 重启前 1) 再次核对 pid 文件持有进程命令行确实为 monitor（防残留 pid 误判）；2) 启动后 5s 校验"本进程写入的 pid 未被覆盖"；watchdog 重启前检查是否存在**其他** monitor 进程（有则不重启只记录）
- **涉及**：watchdog.ps1、monitor.ps1（启动时 pid 写入加原子校验）
- **验收**：模拟"monitor 进程在但 pid 文件缺失"场景，watchdog 不产生双实例；连续 7 天无双实例日志

### D2. 重新评估 P2.1（CDP 合并）
- **评估结论（2026-08-24）**：单轮扫描 eval 调用 ~10 次/会话（快照 2 + 打开 1-2 + 会话名校验 3 + 抓消息 1 + 发送 3），每次新起 powershell 进程 ~1-1.5s，构成扫描周期 12-15s 的主因。合并 JS 理论可省 ~70%（10→3 次），但属页面交互热路径重构，且 v0.3 已多次重启 monitor。**结论：2.1a 列为 v0.4 优先项，本轮不动热路径**（收益是 12s→5s 周期，对处理实时性影响有限，风险收益比不划算）。
- **验收**：结论已记录，v0.4 按此优先实施。

## v0.3 执行顺序与验收

1. **B0 探测**（最快出结论，决定 B 方案形态）
2. A1/A2/A3（质量，测试先行）
3. C（计划任务，低风险）
4. D1（守护加固，需重启验证）
5. B1/B2（依赖 B0 结论）
6. D2（评估）
- 全部完成后：tests 全绿 + status 无 [!!] + sync -Push + 24h 观察
- 排期预估：B0+质量 A 约 1 天；C+D1 约 0.5 天；B1/B2 约 1 天（含客户端自动化调试）；共约 2.5 天

## v0.3 执行状态（2026-08-24 完成）

| 项 | 状态 | 备注 |
|---|---|---|
| A1 追问硬约束 | ✅ | [追问统计]/[承诺字段] 注入 LLM；prompt 同步 |
| A2 承诺识别 | ✅ | Get-PromisedFields；测试 36/36 |
| A3 报告证据化 | ✅ | 重复提问附具体问句 |
| B0 通道 | ✅ | 官方智能机器人长连接（V1 修订） |
| B1 quote_remind | ✅ | 3 项齐全（V6）+ 未知不阻塞（V9）+ 24h 节流 |
| B2 实时触发 | ✅ | monitor SENT_OK 后触发，实测 Liudmyla 全链路 |
| C 计划任务 | ✅ | 3 新任务（共 7 个） |
| D1 watchdog 加固 | ✅ | 重启前命令行兜底复查 |
| D2 P2.1 评估 | ✅ | 结论：v0.4 实施 2.1a |

---

# v0.4 迭代 Spec（2026-08-24）

- 版本: v0.4 (实施中)
- 目标: 性能（CDP 合并）+ 数据利用（买家档案）+ 观察期

| 项 | 状态 | 备注 |
|---|---|---|
| P2.1a CDP eval 合并 | ✅ | Open-ConvoAndGetMessages（5 次→1 次）+ Send-OneTalkMessage 发送段合并（3 次→1 次）；单会话 eval ~10→4；**待真实询盘验证周期**（12:00 部署，观察中） |
| P3.4 买家档案 | ✅ | 卡片抓取（并入合并 JS）→ data\buyers\<key>.json → 国家注入 LLM → 周报国别分布 → status 计数 |
| P3.4 hotfix | ✅ | Get-BuyerProfile Join-Path 3 参错误修复（该错误曾中断会话处理，Carlos 无回复） |
| node_modules 清理 | ✅ | 457 文件误提交 → gitignore 排除 + git rm --cached；审计排除 node_modules |

## v0.4 观察项

1. P2.1a 周期改善验证（有会话轮：~25-30s → 目标 ~15s）
2. 买家档案建档效果（新会话自动建档）
3. 重复提问标记下降（A1/A2 生效）
4. 网络恢复后 `git push` 补交（本地领先 origin 7 commit）
