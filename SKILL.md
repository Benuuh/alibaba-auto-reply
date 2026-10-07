---
name: alibaba-auto-reply
description: 在本项目中检查阿里 OneTalk 自动回复状态、维护回复策略与建议、分析买家资料、处理已授权的监控或公海操作时使用。
license: MIT
compatibility: opencode
metadata:
  platform: win32
  chrome: required
  workflow: monitor
---

# 阿里 OneTalk 项目操作说明

本说明服务于当前仓库，源码版本 0.1.2（2026-10-08）。系统总览见 [README](README.md)，操作步骤见 [部署手册](README_部署说明.md)，实施缺口与现场快照见 [当前状态](docs/当前状态.md)。

## 1. 先确定当前任务

| 用户需求 | 入口 |
|---|---|
| 查看运行情况、为什么没回复 | status、任务与进程查询、monitor 日志；部署手册 §4–5 |
| 理解或修改回复逻辑 | 项目地图、reply_engine、msg_norm、reply_policy、reply_gen |
| 查看或应用优化建议 | review_suggestions、apply_suggestion；部署手册 §6 |
| 买家资料和人工接管 | data 目录、goods、whitelist |
| 公海认领、破冰或补发 | gonghai 专用入口；先看下文公海约束 |
| 部署、启停、恢复 | 部署手册；结合用户授权和当前状态操作 |
| 来源与送达调查 | `scripts\investigate.ps1`（list / detail / claim / confirm-source / confirm-delivery / retry-notify / audit / retention / attempts / recover）；只改状态或给出来源猜测不能关闭调查 |

读取文档、解释结构、离线验证不自动包含恢复生产运行。用户已经授权的操作按既有授权继续，不重复确认。

## 2. 会影响执行选择的事实

- monitor 启动后会处理真实会话。研究模块时不要加载整个 monitor 主程序。
- health_check 会写状态、推送告警，并可能拉起 watchdog；查询使用 status 与任务/进程读取。
- 新版回复链通过离线测试，但真实模型、入口完整行为和端到端发送尚未完成验收，具体见当前状态。
- 2026-10-07 当前源码以待回复列表为主：出现一次即处理；新旧识别只防同一次答复重复发送，不消费五分钟间隔、来源等待、20 秒下限、两轮确认或冷启动只观察。发送锁内再次核对待回复成员、精确会话名与买家输入。显式人工接管名单仍排除自动发送；收据不明先对账。读取重试一次仍失败则落人工任务，其他会话继续。详见 docs/verification/pending_reply_policy_20261007/report.md。
- 当前任务已持久化并分开记录通知、认领、实际联系、供应商回复与确认；状态标签不能证明动作。完整闭环与隔离证据见 docs/业务约束收敛与完整闭环修复交付_20261005.md。
- 消息来源四态（platform/project/human/unknown）由 `scripts\lib\msg_events.ps1` 唯一判定：旧入口（`Get-MessageSource`）与其消费者（human_style / reply_metrics）一律委托它，没有"有时间就是 bot、无标记就是 human"的旁路。来源标签在取得来源真值对照（S0）前**不参与判定**，因此没有证据的我方消息一律 unknown，不会自动当作人工或机器人。浏览器侧逐条抽取只有一份实现（`lib/msg_extract_js.ps1`），会话读取与发送前后快照共用。
- 发送前分两步落盘：唯一发送尝试（完整正文 + 可恢复基线）→ `dispatching` 阶段（点击前，回读核验）；任一步失败即不发送，因此"点击后进程中断"在磁盘上一定留下必须先对账的状态。**不重发是会话级**的：同一会话有未确认/待持久化/歧义尝试时，新买家消息（新去重键）也不放行。收据有效但账本/发送记录写入失败 ⇒ 保留已送达证明 + 待持久化 + 调查，**不重发已送达正文**。见 docs/verification/message_source_recovery_20261007/implementation_report.md。
- 调查提醒：一次投递尝试（含失败/响应不明）之后周期扫描不再自动重发，只能人工 `retry-notify`（显式且单独审计）；关闭调查必须提交结构化出处、真实收据对象或未送达证据，并回读尝试与账本。
- nudge 已移除买家自动发送，只列出候选；公海链路仍能认领与发送。
- waimao 与旧企微/control-agent 桥已移除。远程指令路由属于外部 DSH 配置。
- 修改运行中的库或集中配置后需要重启 monitor；保持用户要求的启停状态。

## 3. 路径、凭据与浏览器

通过 `scripts/config.ps1` 的 `Get-SkillPath` 定位代码、日志、数据和报告。部分账本/PID 仍位于 scripts_dir，不能一概按 data_dir 查找。

凭据仅从配置指向的 credentials.md 读取。真实配置、会话、报告和 profile 是本机数据，不打印密钥，不把真实买家数据写入测试或提交。

Windows PowerShell 5.1 的 `.ps1` 保持 UTF-8 BOM，使用 `powershell -ExecutionPolicy Bypass -NoProfile -File` 调用；HTTP 中文载荷显式使用 UTF-8。不要引入 PS 5.1 不支持的语法。

Chrome 按独立 profile 操作，不按 chrome 进程名批量结束。CDP CLI 与 lib/cdp 的 Get-Page 一致性受到测试保护，二者各有职责。

调试生产 OneTalk 页面时遵循 [浏览器约定](docs/BrowserSkill使用约定.md)，与主程序的页面写操作协调。独立 Chrome 与身份校验仍不能被任意手工切页替代。

## 4. 启停与发送结果

常驻入口经计划任务启动；暂停时先阻止 Health/Watchdog 再拉起进程，再按 PID 和命令行核验后停止。完整命令见部署手册，不使用 monitor/watchdog 的宽泛 -Action stop 路径。

`REPLIED` 可能记录失败，必须连同 `SENT_OK` 和状态写入判断。会话身份错误使整轮停止，账本不可读时不发送；不要删除去重记录来绕过阻塞。

任务 Ready 不是业务正在运行；Health exit 0 也不是全部检查通过。通知 HTTP 探活只说明接口可达，投递成功与收件确认需分别核实。

## 5. 回复配置与建议维护

查明目标文件和实际消费方再修改。提示词、场景示例、代码策略与 JSON 是不同层次；当前 always/never 和 data_to_collect 没有生产回复消费方，向其追加内容不能当作模型行为变化。

优化流程为报告 → 建议 → 人工接受/拒绝 → 显式应用。查看建议和接受建议均不等于应用。应用工具默认做基准哈希检查、备份及校验；校验脚本缺失时会降级为结构检查。不要使用 SkipValidation 来声称通过离线验收。

修改话术时考虑是否有实际执行动作支撑。模型可自然撰写业务解释，不再局限九句登记话术；程序 ResponsePlan 决定敏感请求和事实，所有出口完整校验；提示词和场景例句不能单独授权敏感内容。

## 6. 公海操作

公海使用独立 Chrome/端口，运行条件为 gonghai_enabled 和 disabled 标记。配置开关与当前进程状态分别核对；参数以实际脚本为准。

| 入口 | 行为 |
|---|---|
| gonghai_recon -Action install/dump | 侦察记录；会注入页面记录钩子 |
| gonghai_probe -Count 1 -DoClaim -DryRun | 试跑定位与判定，不认领、不发送 |
| gonghai_probe -Count 1 -DoClaim | 认领并试发 |
| gonghai_batch -Batch 10 | 批量认领、等待同步、搜索并发送 |
| gonghai_batch -DryRun | 仍认领客户，只跳过发送 |
| gonghai_probe -RetryPending | 根据待办尝试补发 |
| gonghai_loop | 连续批次运行，具有认领与发送副作用 |

认领与发送按用户授权范围执行。不能把 batch DryRun 当成完全只读，也不能以本机配置为 true 推定用户要求开始整批运行。

核对 customerId 与发送必须在同一个发送锁窗口。读不到或身份不一致时拒发；验证码、滑块或频繁操作等风控信号按脚本停止条件处理。

单次数量、间隔和日上限以实际配置和代码夹限为准。本机间隔、日上限可为零，不复述旧文档“必有 90 秒间隔/每日限量”的说法。认领后搜索索引可能延迟，未找到需进入实际补发判据，不能绕过身份检查发送。

## 7. 验证与交付

文档修改跑 docs_consistency；回复逻辑选择 reply_chain、对应原语测试和离线 acceptance 回放。

2026-10-05 起测试入口分层（[清单](tests/layers.json)）：`tests\run_tests.ps1` 默认只跑 **Offline**（pure + isolated），
每个子测试进程使用本次运行独有的临时运行根与隔离标记，真实 CDP/发送出口在隔离模式下直接抛错，
并在运行前后比对**生产路径指纹**（确证越界变化为 FAIL；并发变化无独立来源证明为 UNRESOLVED，整体退出码 3）；
未在清单登记的 `*.tests.ps1` 直接判失败。会读写生产运行根或访问 9222 页面的 5 个历史测试归入 `live` 层，
本轮 runner 拒绝 `-Layer Live|All`，真实验收另行授权（[副作用审计](docs/test_audit_20261003.md) 仍适用）。
新增/改写 .ps1 后跑 `tools\ps_bom.ps1` 核对 UTF-8 BOM（编辑工具会丢 BOM）。

分别报告入口加载、离线逻辑、真实模型、页面发送和通知的验证证据，不用模拟时间推定平台时效。

backup/sync 当前并非完整备份或部署镜像，会过滤 apply_suggestion.ps1 等内容；恢复前核对归档文件，并保留需要的未跟踪源码与本机状态。

提交前检查敏感扫描和实际差异。文档维护不自动包含镜像同步、提交、推送、启用任务或客户消息发送。
