# 部署与运维

更新：2026-10-08。本文对应 **0.1.2** 版本的 PowerShell、Chrome CDP、程序回复计划、统一事实与任务存储和 dsh-im 通知出口。总体功能见 [README](README.md)，更新与验证见 [发布记录](docs/verification/release_0.1.2.md)，现场运行状态见 [当前状态](docs/当前状态.md)。

0.0.2 统一可信新消息的冷却门禁，并支持将明确的 Amazon/FBA 收货仓代码用于报价准备。代码推送与打标签不自动重新加载运行进程；上线时按既有授权协调任务和进程，保留配置、账本及人工接管名单。真实模型、页面发送和通知投递须单独验收。

## 1. 部署前提

使用 Windows、Windows PowerShell 5.1、Chrome 和 Node.js。`doc-reader` 声明 Node.js >=18；主监控程序没有根目录 npm 工程。Accio Desktop 仅在启用网关增强时需要；企业微信通知需要已经配置好的 DSH/dsh-im 宿主。

先在 PowerShell 中进入代码根目录。下文的相对命令均以该目录为基准。本文提供操作方法；任务与进程的实际状态以查询结果为准，按用户授权执行启停。

~~~powershell
Get-Command powershell.exe, node.exe
git status --short
~~~

安装文档解析依赖：

~~~powershell
Push-Location tools\doc-reader
npm.cmd ci
Pop-Location
~~~

Accio 客户端与邮箱验证工具的用法分别见 [Accio README](tools/accio-client/README.md) 和 [邮箱验证 README](tools/email-verify/README.md)。

## 2. 配置与目录

### 首次配置

已有部署不要重新复制模板覆盖本机值。新部署可执行：

~~~powershell
if (-not (Test-Path scripts\config.json)) {
    Copy-Item scripts\config.json.example scripts\config.json
}
~~~

编辑 `scripts/config.json`，逐项核对代码根、运行数据目录、Chrome 路径、独立 profile、脚本路径和功能开关。模板包含占位路径，不能直接启动。配置字段名以 [config.json.example](scripts/config.json.example) 为准，实际读取和回退以 [config.ps1](scripts/config.ps1) 及调用方为准；不要假设模板值就是代码的所有默认行为。

可只查看路径是否落在预期位置：

~~~powershell
. .\scripts\config.ps1
Get-SkillPath "scripts"
Get-SkillPath "logs"
Get-SkillPath "data"
Get-SkillPath "reports"
Get-SkillPath "profile"
~~~

路径职责：

| 配置定位 | 保存内容 |
|---|---|
| `scripts_dir` | 可执行脚本、回复配置；`state.json`、`state.json.bak`、`monitor.pid`、`watchdog.pid` 等部分本机状态仍在这里 |
| `logs_dir` | monitor/watchdog/health 日志、授权负缓存和守护冷却状态 |
| `data_dir` | 消息快照、买家档案、人工接管名单、重试表、建议记录、`sent_records.json`、`investigations.json`、`send_attempts.json` 等 |
| `reports_dir` | 摘要、质量分析与周报 |
| `backups_dir` | 代码快照 |
| `chrome_profile` | OneTalk 独立登录态 |
| `credentials_file` / `llm_config_file` | 凭据与模型非敏感配置 |

本机已将日志等外迁到 `<代码根>-runtime`。路径外迁没有消除 `scripts_dir` 下的全部状态文件，迁移、备份和回滚时需同时考虑两处。

### 卖家身份与业务时区（`seller_profile`）

回复链需要"我方是谁"和"现在几点"两个可核实来源。二者都只来自集中配置的 `seller_profile` 块，不来自对话、附件、页面店名或项目名：

| 字段 | 含义 |
|---|---|
| `company_name_en` | 经营者确认的客户可见英文公司名 |
| `assistant_display_name_en` | 经营者批准的接待显示名（是服务显示名，不代表真人此刻在回复） |
| `company_name_verified` / `assistant_display_name_verified` | 逐字段确认标记；只有 true 才允许对外陈述 |
| `timezone` | 卖家业务时区，默认 `Asia/Shanghai`（Windows 侧映射 `China Standard Time`） |

字段为空、标记为 false、值里仍有 `[company name]` 一类模板标记，或时区无法解析时，该字段单独降级：对客只说明当前无法确认，不编造、不借用另一字段的确认状态、也不承诺"核实后再回复"。模板文件保持空值，真实值只写本机不入库的 `scripts/config.json`。

修改该块或回复库后需重启 monitor 才会生效。


### 人工任务、收据与运行根（0.1.1）

通过 Get-SkillPath 'tasks' / 'pause' / 'sent_records' / 'investigations' / 'send_attempts' / 'state' 核对实际位置。显式 RuntimeRoot、AAR_RUNTIME_ROOT 或配置 runtime_root 可覆盖运行态；离线根必须有隔离标记。本机生产配置与运行态不得用模板覆盖。任务、暂停、收据和账本需一起备份，损坏存储不得通过删除或清空来绕过发送保护。

人工任务 API 在 lib/human_tasks.ps1 与 task_contracts.ps1：Get-HumanTaskList 读取；Set-HumanTaskOwnerAccepted 记录认领；Add-HumanTaskActionRecord 记录实际行动与供应商原始回复、ConfirmedFields（字段值/单位/范围/来源）；Set-HumanTaskStatus 请求完成。填写真实执行记录后再修改状态，resolved 会核验原始核实项、当前同流事实及冲突；不能用状态标签代替行动证据，也不能跨货物流引用旧确认。

发送确认使用前后快照中唯一新增事件和完整正文；人工与 unknown 等待按可信事件锚点重算。**来源标签在取得来源真值对照前不参与判定**（`config.json` 的 `source_rules` 段默认不存在 ⇒ 没有已验证标签/字段，无证据的我方消息一律 `unknown`）。

发送前后快照与 monitor 的会话读取使用**同一份**浏览器侧抽取脚本（`lib/msg_extract_js.ps1`）：真实消息边界、方向依据、平台 MessageId 与结构噪声规则只有一处实现；flow 卡与身份不确定的真实气泡都保留在快照里，由收据判定拒绝，而不是被过滤掉。发送前分两步落盘：先写唯一发送尝试（AttemptId、目标会话、**完整正文**、发送前快照证明与可恢复基线），再写"即将输入/点击"的 `dispatching` 阶段并回读核验——两步任一步失败都**不发送**。因此进程在点击前后中断时，磁盘上只有两种状态：`persisted/not_attempted`（可证明没有产生外部副作用）或 `dispatching` 及更晚（必须先对账）。收据有效但 `sent_records` 或账本写入失败时进入 `persistence_pending` 并生成调查，**不重发已送达正文**。

**会话级不重发**：同一会话只要还有 `pending_confirmation` / `persistence_pending` / `delivery_ambiguous` 的尝试，本轮就不发送——去重键（触发）不同也不构成放行理由；只有对账结论（收据确认送达，或可靠未送达证据）才解除。每轮扫描会对这类尝试做同口径重读对账，并用真实写入器重试未完成的持久化并回读。

迁移和排障先只读核对来源、FlowRef 与依赖，不伪造收据、确认值或通知结果。真实联系供应商与通知到达仍需要人工执行和单独验收。

来源与送达调查的操作入口（只操作运行数据根，不发客户消息）：

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list -ActiveOnly -Buyer "Buyer Name"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action detail -Id <调查号>
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action claim -Id <调查号> -Operator "ops"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-source -Id <调查号> -Class platform -Evidence "page:sender field read on the page at 2026-10-07 10:00" -Operator "ops"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <调查号> -DeliveryState receipt_verified -ReceiptId <收据号> -Evidence "receipt:read back from the same conversation"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <调查号> -DeliveryState not_delivered_verified -Evidence "page:NOT_SENT reported by the send adapter"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retry-notify -Id <调查号> [-DryRun]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action audit -Id <调查号>
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action attempts [-Buyer "Buyer Name"]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action recover [-Buyer "Buyer Name"] [-Max 5]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retention -Days 30 [-DryRun]
~~~

证据必须是**有出处的结构化文本** `<source>:<detail>`：来源类可用 `page / api / field / receipt / sent-record / operator-observation`，未送达类必须来自直接观察发送动作的 `page / adapter / send-result / dispatch`，`detail` 至少 8 个字符。只改状态、填写"已处理"或给出来源猜测都不能关闭调查：来源类必须提交真实出处 + **确切事件身份**（`id:` / `cmp|` / `ambiguous:`），收据类必须能在尝试存储或 `sent_records` 里找到**真实收据对象**（收据号必须与该尝试的实际收据一致，并且正文哈希匹配），完成后要**回读**尝试状态与账本；`receipt_persistence_failed` 的关闭会用真实写入器补齐 `sent_records` 与账本，写不成功就保持调查未关闭（可重试，幂等）。人工确认来源只授权**确切事件**的来源更正（先落盘更正、再关闭调查），不制造机器人发送收据，也不解除其他人工暂停。`retry-notify` 是**唯一**的重发路径（一次投递尝试之后周期扫描不再自动重发，响应不明单独记为 `unknown`），走既有 dsh-im 出口，离线/隔离上下文直接拒绝。`-Action list` 的输出含买家名，分享前脱敏。

### 凭据与模型

创建配置所指向的 `credentials.md`。读取器依赖以下字段格式，冒号为中文全角，冒号后紧接值：

~~~text
- **账号 (account)**：<账号>
- **密码 (password)**：<密码>
- **API Key (api_key)**：<API密钥>
~~~

OKKI 自动登录需要时另填 `okki_account` 和 `okki_password`，格式见 `lib/creds.ps1`。旧 `wx_bot_id`/`wx_bot_secret` 字段仍有读取兼容，但当前投递适配器使用本机配置中的 `dshim_*`，不会用旧桥登录。

`llm_config.json` 保存 endpoint、model、timeout_sec，以及可选 thinking/reasoning_effort 等非敏感项。生成调用的 temperature/max_tokens 还由调用方传入，不能只改配置文件便认定所有调用参数都会改变。

凭据、买家消息、报告、浏览器登录态不入库。不要把真实密钥粘贴到日志、测试、文档或聊天。

### 通知出口

在 DSH/dsh-im 中配置目标，再填写 `dshim_delivery_url`、`dshim_bot_id` 和 `dshim_target_id`。URL 应指向本机 `/api/dsh-im/delivery/messages`。

适配器发送 UTF-8 JSON，仅含 `botId`、`targetId` 和 `text`。`SENT_OK` 表示接口返回 `sent=true`；其他返回包括 `SERVICE_DOWN`、`NO_RECEIVER`、`SEND_FAIL` 与 `SEND_ERROR`。

GET 返回 405 只能证明接口可达且只接受 POST，不能证明机器人、目标和最终收件端正常。端到端通知验收需要一条明确的测试投递。宿主关闭时该通知通道不可用，见 [已知例外 E-24](docs/KNOWN_EXCEPTIONS.md)。

## 3. 浏览器与读取来源

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\chrome_ensure.ps1
~~~

该操作会启动或恢复配置的 Chrome 并尝试登录 OneTalk。人工核对消息中心和输入框是否可用；验证码可能需要人工处理。CDP 可达不等于页面已登录或数据面正常。

`accio_shadow` 开启影子对比，`accio_read_enabled` 开启历史上下文读取；失败、授权不可用或与 CDP 消息不匹配时回退页面读取。更改开关后重启 monitor。`accio_send_enabled` 为单独发送开关，本机保持关闭；当前验收不要将读取增强等同于网关发送已验证。

OneTalk、OKKI、公海使用各自的 Chrome profile 和调试端口。不要通过进程名批量结束 Chrome。

## 4. 计划任务与启停

### 查询现有任务

~~~powershell
Get-ScheduledTask -TaskName 'AlibabaAutoReply*' |
    Select-Object TaskName, State
Get-ScheduledTask -TaskName 'AlibabaAutoReply*' |
    Get-ScheduledTaskInfo |
    Select-Object TaskName, LastRunTime, LastTaskResult, NextRunTime
~~~

当前本机任务状态见 [当前状态](docs/当前状态.md)。新机器上没有任务时，应先建立任务再启动，不能使用缺参数的 `Register-ScheduledTask ...` 占位命令。

### 新部署创建任务

使用 Windows 任务计划程序创建任务，操作为 `powershell.exe`，参数为：

~~~text
-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "<代码根>\scripts\<脚本名>"
~~~

Watchdog 另加 `-Action start`。使用有 Chrome 登录态的同一 Windows 用户，选择“只在用户登录时运行”，起始目录为代码根。按实际机器权限设置任务；不要在普通文档中保存用户密码。

| 任务 | 脚本 | 本机排程设计 |
|---|---|---|
| `AlibabaAutoReplyWatchdog` | `watchdog.ps1` | 登录后触发，另加每分钟重复的时间触发；允许错过后补跑 |
| `AlibabaAutoReplyHealth` | `health_check.ps1` | 每 15 分钟 |
| `AlibabaAutoReplySummary` | `summarize.ps1` | 每 4 小时 |
| `AlibabaAutoReplyQuality` | `analyze_replies.ps1` | 每日 05:00 |
| `AlibabaAutoReplyOptimize` | `auto_optimize.ps1` | 每日 05:30 |
| `AlibabaAutoReplyWeekly` | `weekly_report.ps1` | 每日 08:00、登录后补跑，允许错过后运行；脚本按周去重 |

表中时间按部署机器本地时区执行，本机为北京时间。Watchdog 健康判据要求时间触发的重复间隔为 `PT1M`，仅创建登录触发不满足判据。设置不要因空闲结束而停止任务，常驻 Watchdog 不应使用短执行时限。

### 启动或恢复

先完成 [当前状态](docs/当前状态.md) 中的缺口处理与所需验收。确认要恢复自动回复时，在已有任务上执行：

~~~powershell
Enable-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'
Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'
Enable-ScheduledTask -TaskName 'AlibabaAutoReplyHealth'
~~~

守护会带起 monitor。常驻入口通过计划任务启动，避免代理会话退出时回收进程，背景见已知例外 E-12/E-18。启动后核对 `Monitor started`、扫描日志和真实进程，不能仅凭计划任务显示 Running 判定业务可用。

### 暂停或重启监控

先禁用 Health 和 Watchdog 的未来触发，并停止正在运行的任务，再按 PID 与脚本命令行核验后结束已分离的进程：

~~~powershell
Disable-ScheduledTask -TaskName 'AlibabaAutoReplyHealth'
Disable-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'
Stop-ScheduledTask -TaskName 'AlibabaAutoReplyHealth'
Stop-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'

. .\scripts\config.ps1
$taskScripts = Get-SkillPath "scripts"
foreach ($scriptName in @("watchdog", "monitor")) {
    $pidFile = Join-Path $taskScripts ($scriptName + ".pid")
    if (-not (Test-Path $pidFile)) { continue }
    $pidText = (Get-Content $pidFile -Raw).Trim()
    if ($pidText -notmatch '^\d+$') { continue }
    $process = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $pidText)
    $scriptPattern = [regex]::Escape($scriptName + ".ps1")
    if ($process -and $process.Name -eq "powershell.exe" -and
        $process.CommandLine -match $scriptPattern) {
        Stop-Process -Id ([int]$pidText) -Force
    }
}
~~~

PID 文件失效时先查询命令行再处理，不能扩大为按名称批量杀进程。不使用 `monitor.ps1 -Action stop` 或 `watchdog.ps1 -Action stop` 的宽泛匹配路径。

这组步骤只暂停主监控。摘要、报告、优化建议、公海及其他正在运行的操作需要按目的分别处理。Health 是有告警和恢复副作用的脚本；暂停期间不要把手动运行它当作纯查询。

## 5. 观察与排查

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\status.ps1
~~~

`status.ps1` 查询进程、CDP、日志、任务和本机文件；会输出部分日志/文件名，分享结果前检查买家信息。当前有意暂停时，监控缺失、日志陈旧等红项应结合暂停状态解释。

`health_check.ps1` 检查项（共 7 项）：`monitor_process`、`monitor_log_fresh`、`watchdog_process`、`watchdog_cooldown`、`cdp_9222`、`page_logged_in`、`scheduled_tasks_fresh`。

检查项名字和数量由代码的 `Add-Check` 调用定义，文档一致性测试校验该行。Health 会写状态、推送告警，且可能自动拉起 watchdog；脚本通常 exit 0，不代表所有检查通过。

| 现象 | 核对位置与判断 |
|---|---|
| 没有回复 | 查 monitor 进程、待回复列表、`SHOULD-REPLY`、人工接管和页面状态 |
| 新消息被延迟 | 查 `NEW-MSG-EVIDENCE`、`RATE-SKIP`；当前主循环存在额外时间闸门，见当前状态 |
| 重复回复或去重异常 | 查 `STATE-UNUSABLE`、`DUP-GUARD`；保留账本及备份，不删除它来“恢复发送” |
| 页面不可用 | 查 `PAGE-DOWN`、`PAGE-HEAL`、`CDP`；分清浏览器可达与页面业务可用 |
| 会话身份不一致 | `ABORT_WRONG_CONVO` 会中止该轮后续发送，应查页面切换与并发操作 |
| 模型或内容检查失败 | 查 `REPLY-GEN` 的来源、场景、重写与 violations，及 `SEND-GATE` 日志 |
| 企业微信未收到 | 查 dsh-im 配置、宿主和 `SENT_OK`；HTTP 探活不替代实际投递。调查提醒的真实状态用 `investigate.ps1 -Action detail` 的 `notifications` 记录核对 |
| 会话长时间不回复 | 查 `HUMAN-SOURCE-UNKNOWN` / `SOURCE-CONFLICT` / `SEND-ATTEMPT-BLOCKS-RESEND` / `SEND-PERSISTENCE-PENDING`，并用 `investigate.ps1 -Action list -ActiveOnly` 看是否有待处理调查；不要靠重启或删库"恢复发送" |
| Accio 授权失败 | 重新登录 Accio；负缓存期间回退 CDP，不需要反复重启 Chrome |
| 守护频繁重启 | 查 watchdog 日志、`watchdog_cooldown.json` 和日志新鲜度配置 |

只有 `REPLIED ... SENT_OK` 才应按程序口径视为发送成功；单独出现 `REPLIED` 行也可能是发送失败记录。该口径仍不等于买家已读或平台提供了远端确认。

## 6. 人工接管与规则维护

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Action list
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Action add -Name "<买家名>"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\whitelist.ps1 -Action remove -Name "<买家名>"
~~~

名单保存在 `data_dir/manual_override.json`，是本机买家数据。白名单让机器人跳过自动回复，不等于创建人工待办或确认有人已处理。通过企业微信执行该命令依赖外部 DSH 的指令路由，仓库内没有旧远程控制桥。

修改 `.ps1` 或集中配置后重启 monitor。提示词、场景文件和规则 JSON 有按读取/修改时间更新的机制；但部分 JSON 字段没有回复消费方，见当前状态，不能承诺任意编辑立即生效。

建议的查看、接受与应用分开执行：

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\review_suggestions.ps1 -Status pending
$suggestionId = "<建议ID>"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\review_suggestions.ps1 -Show $suggestionId
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\review_suggestions.ps1 -Accept $suggestionId
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\apply_suggestion.ps1 -Id $suggestionId -WhatIf
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\apply_suggestion.ps1 -Id $suggestionId
~~~

应用前先核对目标内容与消费链。默认校验脚本是 `tools/acceptance/replay.ps1`，不存在时会降级为结构检查；`-SkipValidation` 会跳过校验。文件变更、结构通过或应用状态为 applied，都不代表真实模型行为已经改变。备份位置由应用命令输出。

## 7. 验证、备份和回滚

文档重写或普通离线逻辑检查可执行：

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tests\docs_consistency.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_chain.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\reception_facts.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\suggestions.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\gonghai_chrome_isolation.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1
~~~

这些入口使用源码、夹具、桩模型或临时目录，不启动主监控、不发真实买家消息。

0.1.1 发布检查中，历史 `tools/acceptance/replay.ps1` 的 20 场景仍有失败；新回复计划的正式回归通过不代表旧回放已经通过。生成契约预期与回复质量需逐项复核，见 [发布记录](docs/verification/release_0.1.1.md)。

2026-10-05 起默认入口是**分层**的：

~~~powershell
# 默认：纯逻辑 + 隔离集成（每个子测试进程独立临时运行根 + 隔离标记 + 生产指纹比对）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
# 只跑某一层
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Pure
# 只跑隔离集成
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Isolated
~~~

分层清单见 `tests\layers.json`：`pure`（纯逻辑）/ `isolated`（临时存储、竞争进程、模拟适配器）/ `live`（真实模型、页面、通知）。
未登记在清单里的 `*.tests.ps1` 会让运行器直接失败；`gonghai.tests.ps1`、页面探针等历史测试属于 `live` 层。
当前运行器拒绝 `-Layer Live|All`。真实验收需按 [测试副作用审计](docs/test_audit_20261003.md) 和最新代码另行组织。

结果分为 `LogicTests / IsolationChecks / ProductionPathAudit / Overall`：退出码 0 为全部通过，1 为测试或生产路径审计失败，2 为分层清单错误，3 为生产变化来源未证实（`UNRESOLVED / BLOCKED-UNRESOLVED`）。Chrome、monitor 或 watchdog 正在运行只能作为线索，不能证明某条路径变化由它们造成；不要把业务断言全绿写成完整验收通过。

真实模型质量、端到端耗时、真实页面发送和通知到达需另行验证。回放中的模拟时间不能作为实测回复延迟。

`backup.ps1 -Snapshot` 是有限的代码快照，`sync.ps1` 是有限的镜像同步。当前二者的文件过滤会排除 `apply_*.ps1`，且未覆盖完整根目录、tools 和所有运行数据；不能把它们当作整项目可恢复备份。保留 Git 状态和需要的未跟踪源码，并在恢复前核对实际归档内容。凭据、浏览器登录态、账本等本机数据需按各自用途另行保存。

回滚前暂停相关入口，恢复经过核对的代码与配置，再跑离线检查。不要用新配置覆盖本机路径，不要用空账本覆盖真实去重状态。历史重构回退记录见 [2026-10-03 回滚说明](docs/rollback_20261003.md)。

## 8. 公海与 OKKI

公海链路具有认领、破冰发送和补发能力，使用独立 Chrome，并由 `gonghai_enabled` 和运行数据中的 disabled 标记控制。配置开关为 true 不代表循环进程正在运行。

`gonghai_probe.ps1 -DryRun` 与 `gonghai_batch.ps1 -DryRun` 的含义不同：后者仍会认领客户，只跳过发送。按 [项目操作说明](SKILL.md) 和脚本参数选择实际动作，不将 batch 的 DryRun 当作全程只读。

OKKI 脚本用于专用 CRM 页面、登录、探测和商机处理，按需要独立部署。waimao 已移除，旧设计文档中的命令不再适用。
