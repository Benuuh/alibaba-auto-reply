# 部署与运维

更新：2026-10-04。本文对应 0.0.1 版本的 PowerShell、Chrome CDP、回复决策/生成模块和 dsh-im 通知出口。总体功能见 [README](README.md)，现场运行状态与待解决问题见 [当前状态](docs/当前状态.md)。

## 1. 部署前提

使用 Windows、Windows PowerShell 5.1、Chrome 和 Node.js。`doc-reader` 声明 Node.js >=18；主监控程序没有根目录 npm 工程。Accio Desktop 仅在启用网关增强时需要；企业微信通知需要已经配置好的 DSH/dsh-im 宿主。

先在 PowerShell 中进入代码根目录。下文的相对命令均以该目录为基准。本文提供操作方法，不表示应立即恢复当前停用的生产任务。

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
| `data_dir` | 消息快照、买家档案、人工接管名单、重试表、建议记录等 |
| `reports_dir` | 摘要、质量分析与周报 |
| `backups_dir` | 代码快照 |
| `chrome_profile` | OneTalk 独立登录态 |
| `credentials_file` / `llm_config_file` | 凭据与模型非敏感配置 |

本机已将日志等外迁到 `<代码根>-runtime`。路径外迁没有消除 `scripts_dir` 下的全部状态文件，迁移、备份和回滚时需同时考虑两处。

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
| 企业微信未收到 | 查 dsh-im 配置、宿主和 `SENT_OK`；HTTP 探活不替代实际投递 |
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
powershell -ExecutionPolicy Bypass -NoProfile -File tests\suggestions.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\gonghai_chrome_isolation.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1
~~~

这些入口使用源码、夹具、桩模型或临时目录，不启动主监控、不发真实买家消息。完整测试运行器 `tests/run_tests.ps1` 没有隔离；`gonghai.tests.ps1` 会改写本机配置/运行数据，页面测试会访问当前 CDP。全套测试前先读 [测试副作用审计](docs/test_audit_20261003.md)，并核对实际最新代码。

真实模型质量、端到端耗时、真实页面发送和通知到达需另行验证。回放中的模拟时间不能作为实测回复延迟。

`backup.ps1 -Snapshot` 是有限的代码快照，`sync.ps1` 是有限的镜像同步。当前二者的文件过滤会排除 `apply_*.ps1`，且未覆盖完整根目录、tools 和所有运行数据；不能把它们当作整项目可恢复备份。保留 Git 状态和需要的未跟踪源码，并在恢复前核对实际归档内容。凭据、浏览器登录态、账本等本机数据需按各自用途另行保存。

回滚前暂停相关入口，恢复经过核对的代码与配置，再跑离线检查。不要用新配置覆盖本机路径，不要用空账本覆盖真实去重状态。历史重构回退记录见 [2026-10-03 回滚说明](docs/rollback_20261003.md)。

## 8. 公海与 OKKI

公海链路具有认领、破冰发送和补发能力，使用独立 Chrome，并由 `gonghai_enabled` 和运行数据中的 disabled 标记控制。配置开关为 true 不代表循环进程正在运行。

`gonghai_probe.ps1 -DryRun` 与 `gonghai_batch.ps1 -DryRun` 的含义不同：后者仍会认领客户，只跳过发送。按 [项目操作说明](SKILL.md) 和脚本参数选择实际动作，不将 batch 的 DryRun 当作全程只读。

OKKI 脚本用于专用 CRM 页面、登录、探测和商机处理，按需要独立部署。waimao 已移除，旧设计文档中的命令不再适用。
