# 消息来源与接待恢复交付复核

日期：2026-10-07。复核对象为当前未提交工作区、implementation_report.md 与 offline_final2.txt，未启停生产、未读取实时会话、未调用真实发送或通知。

结论：**未通过验收，需继续修复**。四态模型、发送尝试与调查模块已落地，但真实收据、重启保护与恢复操作未形成规格要求的完整链路。来源真值样本仍缺失，不能宣称已可靠区分真实平台/人工/项目消息。

## 1. 复核证据

- 交付方最后一次完整回归：60 文件、3182 通过、2 失败；LogicTests=FAIL，IsolationChecks=PASS，ProductionPathAudit=PASS，Overall=FAIL，退出码 1。这里只核对保存的完整运行输出，没有再次跑完整套件。
- 本会话单独复跑 new_message_cooldown：80 通过、2 失败，退出码 1。失败仍是两条 A9 人工介入断言；实际日志在 MSG-ORDER-UNVERIFIED 提前拒绝，原因 missing-message-timestamps，并未走到预期人工门禁。需要修正夹具和验证目标，不能删除断言或放宽顺序门禁。
- 审阅实际生产调用关系，并在明确 AAR_RUNTIME_ROOT 的临时隔离根运行虚构数据探针；未修改功能代码。复现结果见各问题。

复核探针第一次调用 run_child 时漏设运行根环境变量，脚本作用域切换后写入了运行根的虚构记录。已移除本次虚构发送尝试及其备份，从 investigations.json 及其备份中仅移除本次两条虚构调查，保留原有六条记录；确认本次虚构记录数为零。后续探针显式设置环境变量并在脚本内初始化隔离，结果仅作为隔离复现证据；第一次探针不作为隔离成功证据。

## 2. 必须修复的问题

### R1 — P1：真实收据仍使用旧 DOM 集合，统一抽取未接入真实发送

位置：scripts/lib/outbound_receipts.ps1:23–36；scripts/lib/send.ps1:250、269；tests/send_attempt_receipt.tests.ps1:32–40。

Get-OutboundSnapshot 仍枚举全部 message-item-wrapper，MessageId 固定为空，仍以姓名是否存在辅助推断我方；没有复用新事件抽取的真实消息边界、平台 ID 与结构噪声规则。实际 Send-OneTalkMessageEx 仍调用它取得前后快照。

新增 Confirm-SendAttemptFromSnapshots 没有生产调用点；新测试所谓“生产收据 DOM 适配器矩阵”给 Invoke-SendEval 直接返回构造好的 JSON，没有执行该 DOM JavaScript。这无法证明 flow、无时间 wrapper、附件等真实页面结构下的采集已修复。原始 incomplete-before-identities 阻断仍可能存在。

修复：生产发送前后均使用共享真实事件抽取和身份构造；运行实际收据 DOM JavaScript 的虚构 DOM 矩阵，并验证完整发送消费者。保留身份不确定的真实气泡，不能过滤它们来获取有效收据。

### R2 — P1：点击后、结果登记前中断，重启会允许重复发送

位置：scripts/lib/send_attempts.ps1:137–151、395–401；scripts/monitor.ps1:2218–2226、2248–2258。

发送前记录 deliveryState=not_attempted；进入实际发送前没有持久化“即将产生外部发送副作用”的状态。只有发送函数返回后才登记 pending_confirmation 等状态。不重发闸门忽略 not_attempted，且预先记录不保存完整待发送正文，只存哈希与长度。

复现：New-PersistedSendAttempt 成功后回读状态为 not_attempted，Test-SendAttemptBlocksResend 对同一触发返回 Blocked=False。若真实点击后进程中断，磁盘状态与此相同，重启无法证明未发送却允许再次进入发送。

修复：外部副作用前可靠持久化发送阶段，失败不得发送；重启遇到可能产生过副作用的尝试先对账。保存规格要求的完整正文及可恢复基线。新增真实子进程中断/重启的隔离消费者回归。

### R3 — P1：待确认/待持久化仅挡同一触发，新触发绕过会话保护

位置：scripts/lib/send_attempts.ps1:395–401；scripts/monitor.ps1:2187–2194。

monitor 传入当前 newKey 作为 TriggerRef，函数过滤掉不同 triggerRef 的未确认尝试。因此买家再来一条消息时，可以在该会话旧发送 pending_confirmation 或 persistence_pending 时继续发送。规格 §4.6 要求持久化失败暂停该会话新增发送，§5 也把相关待确认发送列为新诉求放行前提。

复现：同一买家 trigger-A 为 pending_confirmation，检查 trigger-B 返回 Blocked=False。

修复：明确会话级与触发级保护，持久化失败必须阻断该会话新增发送；未确认发送须先对账并明确与当前诉求关系，不能仅因去重键不同自动放行。将检查接入实际消费者。

### R4 — P1：调查显示 resolved，却不能恢复发送尝试或账本

位置：scripts/investigate.ps1:122–126；scripts/lib/investigations.ps1:539–568；scripts/lib/send_attempts.ps1:381–388。

confirm-delivery 只关闭调查，没有更新关联 AttemptId、保存真实收据、登记 sent_records/replied 或核对未送达后的新门禁。Resume-SendAttemptPersistence 没有生产调用点，内部又不传必需的写入器，实际只会得到 no-sent-record-writer / no-ledger-writer。待确认尝试没有后续生产快照对账调度。

复现：调查确认操作返回成功，调查为 resolved，但关联发送尝试仍 pending_confirmation，后续同一触发仍被阻断。

修复：把证据核验、尝试状态更新、部分提交恢复及调查关闭接成可恢复操作；已确认未送达也只允许重新走当前门禁。提供实际可用 CLI 和 monitor 恢复入口，测试不能直接调用未接线辅助函数后声称生产闭环。

### R5 — P1：证据校验只看非空文本，收据 ID 还与 AttemptId 错误比较

位置：scripts/lib/investigations.ps1:493–514；scripts/investigate.ps1:115–119。

来源校验只要求 Class、非空 Evidence 和相同 EventRef；“handled/已处理”等无出处文字也会被接受。送达校验把 ReceiptId 与 Record.attemptId 比较：真实收据号通常不同于尝试号而遭拒，反而把 AttemptId 当作 ReceiptId 就能通过，没有加载和核验真实收据。持久化调查也没有实际账本回读。来源 CLI 先关闭调查再另存更正，第二段失败时会留下已关闭但更正未生效的记录，且关闭后无法按相同动作重试。

复现：Evidence='handled' 的来源确认被接受；ReceiptId=AttemptId、Evidence='handled' 的送达确认也被接受，即使该尝试 receipt=$null。

修复：使用有出处的结构化证据和准确事件/尝试绑定；已送达必须验证真实收据对象，持久化成功必须回读实际状态。“已处理”等备注不能充当证明。来源更正和关闭采用可恢复提交，落盘失败保留可继续处理的状态。

### R6 — P2：通知结果 UNKNOWN 后会自动再次投递

位置：scripts/lib/investigations.ps1:326–329、364–366、439–456。

失败/不明响应设置 notifiedOnce=False，下一轮 sweep 再次调用 Sender；nextCheckUtc 只延后一次，之后一直到期。通道可能已经送达但响应丢失，会因周期扫描产生重复通知，不符合规格“响应不明分开记录、人工显式重试”的要求。

复现：虚构 Sender 始终返回 UNKNOWN，两次正常扫描产生 senderCalls=2，没有 OperatorRetry。

修复：保留首次投递尝试和未知结果，正常扫描不得盲重发；人工显式 retry-notify 单独审计。确认未投递的自动重试若要保留，需有明确策略、间隔与通道证据，不能把 UNKNOWN 当作未送达。

### R7 — P2：旧来源入口和消费者仍绕过共享判定

位置：scripts/lib/msg_source.ps1:10–17；scripts/lib/human_style.ps1:41；scripts/lib/reply_metrics.ps1:24、52。

Get-MessageSource 仍把带 @@TS 的我方行判 bot、无标记行判 human，仍被 human_style 和 reply_metrics 调用。交付宣称消除旧入口旁路，但这里只修改了 Ex/Class 路径，规格要求的全部旧入口/消费者接线尚未完成。

修复：统一委托共享判定，处理 project 与旧 bot 的兼容及消费者实际语义，给旧入口与实际消费者加入未知、时间戳、平台和收据回归。

## 3. 尚未验证的事实与验收缺口

- S0 没有真实发送者真值对照，默认空规则下 platform/human 无法自行成立。保守 unknown 是正确降级，但核心“平台无需买家再发即可接管、真实人工五分钟暂停”尚不能据此宣称实现完成。
- 到期恢复仅复用待回复扫描，没有证明已离开待回复列表的积压会话能被主动重新读取；需要实际到期调度消费者回归，而非仅检查暂停时间已过。
- A10 白名单仅用“模块没有修改名单”的断言，A17 未演练进程中断，A23 未覆盖生成中介入的完整入口，不能标为完整验收通过。
- 真实页面、真实送达、通知和生产重载仍未验收；继续完成离线修复后逐项列出，不能用机制测试替代来源真值。

## 4. 执行方下一步与重验门槛

继续以原执行 spec 为准，依次补齐 R1–R7 与两条 A9 失败，保留其他会话已有改动；不要靠删除负例、放宽未知/收据判据或伪造来源证明通过。

每个缺陷先保存消费者级失败复现，再修复并验证；重点覆盖实际收据 JavaScript、发送前副作用状态、重启对账、新触发阻断、CLI 恢复、证据拒绝与 UNKNOWN 通知。

重新运行完整 Offline 并写入新的完整输出，分别报告四项结果和原生退出码；更新 implementation_report.md 的 A01–A24 实际覆盖、完成标准与残留事实。生产审计若为 UNRESOLVED 必须如实保留。

此次复核只新增本报告，未修改源码、原交付报告或原测试。生产启停与真实消息/通知仍按执行会话的既有授权范围处理。
