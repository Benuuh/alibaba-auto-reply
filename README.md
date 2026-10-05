# Alibaba Auto Reply

当前版本：**0.1.1**，对应 Git 标签 `v0.1.1`。版本号记录于 [VERSION](VERSION)。

阿里巴巴国际站 OneTalk 卖家消息自动接待工具，面向跨境物流与货运代理业务。它读取待回复会话，整理买家提供的货物信息，生成简短英文回复；资料齐全时提醒人工报价。

项目以 Windows PowerShell 为主，通过 Chrome CDP 操作页面，可选用 Accio Desktop 网关增强历史消息读取。通知通过本机 DSH 的 dsh-im 接口发送到企业微信。

> 文档更新：2026-10-06。0.1.1 汇总接待身份与时间问答、统一货物事实、人工任务与介入暂停、程序控制的回复计划及发送收据，并包含 [R01–R10 独立复核整改](docs/业务约束收敛与完整闭环修复整改交付_20261006.md)。更新说明见 [CHANGELOG](docs/CHANGELOG.md)，验证与脱敏范围见 [发布记录](docs/verification/release_0.1.1.md)。代码发布不自动重启生产；真实模型、页面发送与通知仍待验收，生产路径来源未证实的变化保留为 UNRESOLVED。

## 阅读入口

| 需要了解什么 | 文档 |
|---|---|
| 部署、配置、启停、排查与验证 | [部署与运维](README_部署说明.md) |
| 核心模块如何配合、改动应该落在哪里 | [项目地图](docs/项目地图.md) |
| 当前启用状态、未完成项与验收边界 | [当前状态](docs/当前状态.md) |
| 执行者的操作约束 | [项目操作说明](SKILL.md) |
| 历史问题与变更原因 | [已知例外](docs/KNOWN_EXCEPTIONS.md)、[变更记录](docs/CHANGELOG.md) |
| 文档之间的职责 | [文档维护约定](docs/文档权威约定.md) |

## 能力与边界

| 能力 | 当前实现 |
|---|---|
| 待回复会话处理 | 连续扫描待回复列表，检查页面、会话身份、去重状态与人工接管名单 |
| 回复决策 | 按当前诉求、已知资料和对话记录选择场景，控制允许追问的字段 |
| 回复生成 | ResponsePlan 渲染追问、事实与行动片段；模型仅补充登记的普通说明，最多重写一次，失败使用受控回退 |
| 内容检查 | 初稿、重写、回退和最终发送共用校验；发送锁内回读任务依赖并用新时钟重组 |
| 身份与时间问答 | 使用逐字段确认的 seller_profile 和注入时钟；明确地点逐目标回答，歧义地点澄清，不编造身份 |
| 多语言输入 | 接收买家原文；提示词要求统一使用美式英文 |
| 图片与文档 | 图片走多模态，文档转文本或渲染图；只提取明确可见的信息 |
| 资料收集与报价提醒 | CargoFacts 统一包装数量、包装重量、尺寸与目的地；商品净重不能充当包装重量，Amazon/FBA 仓代码可满足报价目的地 |
| 人工接管 | 名单跳过自动回复；可信人工介入按事件锚点暂停五分钟，来源不明单独有界等待 |
| 人工任务 | 持久化同流任务与逐字段证据；通知、认领、联系、供应商回复及完成分别记录，状态标签不证明实际动作 |
| 历史消息增强 | Accio 读取失败或与页面内容不匹配时回退 CDP |
| 质量改进 | 分析报告生成建议，经人工接受后单独应用，带基准哈希、备份和回滚 |
| 守护与恢复 | watchdog 检查监控进程、日志和 CDP；health_check 另做健康检测并可能拉起守护 |
| 扩展业务 | OKKI 商机相关脚本、公海认领与破冰链路独立存在 |

上述能力描述对应发布源码与隔离验证，运行中的旧进程需重新加载后才会生效。规则的实际消费方见 [规则清单](scripts/reply_rules.registry.json)；部分旧 JSON 字段仍未接线。环境审计与真实验收的剩余边界见 [当前状态](docs/当前状态.md)。

## 消息处理链

~~~mermaid
flowchart TD
    A[OneTalk 待回复列表] --> B[monitor：页面、人工接管与会话检查]
    B --> C[reply_engine：待回复确认、去重与时间门禁]
    C --> D[msg_norm：消息排序、身份和资料整理]
    D --> E[reply_policy：场景和允许追问的字段]
    E --> F[reply_gen：模型生成与一次可选重写]
    F --> G[ResponsePlan 组合与完整内容检查]
    G --> H[send：会话核对与发送]
    H --> I[唯一新增事件收据确认后更新去重状态]
    I --> J[资料齐全则提醒人工报价]
~~~

程序决定追问、澄清、身份、时间和行动事实；模型仅补充登记的普通说明。简单身份与时间问答由程序直接渲染，无需模型。附件提取和 HTTP 重试可能额外调用模型，因此“生成一次、重写一次”不等于整个会话只发生两次请求。

## 目录结构

~~~text
alibaba-auto-reply/
├─ README.md / README_部署说明.md / SKILL.md
├─ llm_config.json                 模型非敏感配置
├─ scripts/
│  ├─ config.ps1 / config.json.example
│  ├─ monitor.ps1                 会话处理主入口
│  ├─ watchdog.ps1 / health_check.ps1 / status.ps1
│  ├─ chrome_ensure.ps1 / cdp.ps1  Chrome 恢复和 CDP CLI
│  ├─ reply_engine.ps1            判据、哈希、禁词等基础函数
│  ├─ reply_agent_prompt.md / reply_scenarios.md / reply_rules.json
│  ├─ lib/
│  │  ├─ msg_norm.ps1 / reply_policy.ps1 / reply_gen.ps1
│  │  ├─ facts_engine.ps1 / response_plan.ps1 / contact_rules.ps1
│  │  ├─ task_contracts.ps1 / task_facts.ps1 / human_tasks.ps1
│  │  ├─ human_pause.ps1 / sent_records.ps1 / outbound_receipts.ps1
│  │  ├─ seller_context.ps1 / time_claims.ps1
│  │  ├─ paths.ps1 / state_store.ps1 / test_context.ps1
│  │  ├─ llm.ps1 / cdp.ps1 / send.ps1 / lock.ps1
│  │  ├─ msg_source.ps1 / no_reply.ps1 / accio.ps1
│  │  ├─ goods.ps1 / quote.ps1 / vision.ps1 / doc.ps1
│  │  ├─ wecom.ps1 / report_push.ps1 / heartbeat.ps1
│  │  └─ suggestions.ps1 / 日志与告警辅助库
│  ├─ analyze_replies.ps1 / auto_optimize.ps1
│  ├─ review_suggestions.ps1 / apply_suggestion.ps1
│  ├─ summarize.ps1 / weekly_report.ps1 / nudge.ps1
│  ├─ whitelist.ps1 / dashboard.ps1 / backup.ps1 / sync.ps1
│  ├─ okki/                       小满 CRM 扩展
│  └─ gonghai/                    阿里公海扩展
├─ tools/
│  ├─ doc-reader/                 文档解析
│  ├─ accio-client/               Accio 网关客户端
│  ├─ email-verify/               邮箱验证工具
│  └─ acceptance/                 离线回复回放
├─ tests/                         测试、夹具和场景
├─ docs/                          当前说明、历史设计和验收记录
└─ .githooks/                     提交与推送前敏感扫描
~~~

`scripts/config.json` 和 `credentials.md` 为本机文件，不入库。日志、买家资料、报告、备份和浏览器登录态按配置定位，本机已将这些目录外迁到运行数据根。部分去重状态与 PID 文件仍放在 `scripts_dir`，详见部署手册。

## 回复策略与质量改进

`msg_norm.ps1` 统一消息格式与顺序；`reply_policy.ps1` 决定场景和问什么；`reply_gen.ps1` 组装上下文、注入匹配场景的示例，并生成或回退。代码库在 monitor 启动时加载，修改后需要重启；提示词、场景文件和 JSON 的读取有缓存更新机制。

质量改进链为：

~~~text
质量报告 → 优化建议 → 人工接受或拒绝 → 显式应用 → 离线校验
~~~

`auto_optimize.ps1` 和 `analyze_replies.ps1 -ApplyNever` 不直接修改生效规则。`review_suggestions.ps1` 与 `apply_suggestion.ps1` 分离。建议应用成功表示文件修改并通过指定验证，不等于生产消费链和真实模型效果已经验收。

## 通知与其他业务

`lib/wecom.ps1` 保留历史函数名，实际调用 dsh-im 的本机 HTTP 投递接口。仓库已移除旧企微长连接桥和远程控制桥，远程指令执行依赖外部 DSH 配置。

周报会默认调用 `nudge.ps1`，但该脚本已移除买家自动发送路径，目前只列出跟进候选并记日志。公海链路仍具有认领和发送能力，使用独立 Chrome；不要将它与沉睡买家候选统计混淆。

`waimao/` 及专用配置已移除，相关设计文档标注为历史资料。

## 验证

默认运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_tests.ps1 -Layer Offline`。运行器按 [分层清单](tests/layers.json) 执行 pure 与 isolated，每个子进程使用临时运行根并核验隔离自证；真实模型、CDP、发送与通知出口在 Offline 拒绝。当前运行器拒绝 Live/All。

结果分开报告 LogicTests、IsolationChecks、ProductionPathAudit 与 Overall。退出码 0 表示三项通过；1 为测试或审计失败，2 为清单错误，3 为生产路径变化来源未证实。业务断言通过不能覆盖 exit 3 的环境未验收结论。

0.1.1 发布检查发现历史 `tools/acceptance/replay.ps1` 的 20 场景仍有失败，涉及旧生成契约预期及回复质量，尚待复核；详情见 [发布记录](docs/verification/release_0.1.1.md)。本版本作为预发布代码快照，保留未通过项。

离线通过可证明对应逻辑和回放结果；真实模型质量、完整回复延迟、通知到达和页面发送效果需单独验收。不要依据旧文档中的“每轮约若干秒”推定当前端到端响应时间。
