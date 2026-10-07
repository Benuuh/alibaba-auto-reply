# 消息来源与恢复交付第二轮复核

日期：2026-10-07。范围：整改后的当前磁盘源码、implementation_report.md、offline_final5.txt 及定向隔离回归。未部署、未启停生产、未读取实时会话、未调用真实发送或通知。本轮没有修改功能代码、原测试或执行方交付报告。

结论：**已验证整改进展，但仍有三个阻断项，尚不能验收完成**。完整 Offline 保存结果确实全绿；下列新增反例未被该套件覆盖，不能由全绿结果推出这些链路已正确。

## 1. 已核实结果

交付方保存的权威完整运行 offline_final5.txt：62 文件，3302 通过，0 失败；LogicTests、IsolationChecks、ProductionPathAudit、Overall 均 PASS，原生退出码 0。本会话没有重复运行完整套件。

本会话显式为每个子进程设置 AAR_RUNTIME_ROOT 并经 run_child 初始化临时隔离根，独立复跑：

| 文件 | 通过 | 失败 | 原生退出码 |
|---|---:|---:|---:|
| send_attempt_receipt.tests.ps1 | 73 | 0 | 0 |
| send_attempt_restart.tests.ps1 | 23 | 0 | 0 |
| source_recovery_schedule.tests.ps1 | 59 | 0 | 0 |
| new_message_cooldown.tests.ps1 | 84 | 0 | 0 |
| msg_source_consumers.tests.ps1 | 23 | 0 | 0 |

确认已具备共享 DOM 抽取入口、发送前 dispatching 持久阶段、会话级待确认保护、CLI/monitor 恢复入口、UNKNOWN 通知不自动重投及旧来源消费者委托。两条 A9 失败已修复，断言进一步要求实际走到人工让路分支。

子进程中断回归验证的是派发阶段后的恢复。它在取得收据后显式调用 Complete-SendAttemptPersistence，因此没有覆盖下述“收据已保存但提交未完成”的生产消费者缺口。

## 2. 必须修复与补测

### R8 — P1：取得收据后过早解除保护，未提交账本不再恢复

位置：scripts/lib/send_attempts.ps1:283、413–425、552–555、763–774；scripts/monitor.ps1:1546–1552。

Set-SendAttemptReceipt 将尝试写成 receipt_verified 时，persistence.sentRecord 和 persistence.ledger 仍为 pending。Get-SendAttempts -ActiveOnly 直接排除所有 receipt_verified；恢复扫描只处理 persistence_pending。因此收据保存后、账本提交前发生中断，该尝试不会进入恢复队列，也不再阻止新增发送。

这也发生在正常重启对账路径：monitor 调用 Invoke-SendAttemptReconciliation 后只写日志；该函数保存 receipt_verified 后立即返回，没有提交两份账本。之后扫描同样不会补齐。

本会话在明确临时隔离根下运行实际函数，保存虚构基线、dispatching 阶段及唯一新消息，复现输出：

```text
Reconciled=True
ReceiptValid=True
State=receipt_verified
SentRecordCommit=pending
LedgerCommit=pending
RecoveryResults=0
ResendBlocked=False
StoredSentRecords=0
LedgerKeys=0
```

影响：有效送达证明没有发布到 sent_records/replied，来源无法使用发送记录纠正，旧诉求也缺少去重登记；会话却已解除保护。不能宣称部分提交与重启闭环已完成。

修复要求：将“送达已证明”和“持久化全部完成”分别判断；任何有有效收据但账本未提交/未回读的尝试必须保持会话保护，并纳入幂等恢复，不能按 receipt_verified 单独认定 settled 或淘汰。monitor 对账成功必须接通实际提交或可靠排入恢复。补测两个真实消费者路径：正常重启对账取得收据；收据保存后、各账本提交阶段前后分别中断并重启。

### R9 — P1：无 rich 节点的真实附件气泡仍被直接删除

位置：scripts/lib/msg_extract_js.ps1:20–23。

__aarExtractRow 在附件检测前执行 if (!rich) return null。图片/文件真实气泡只要没有 .session-rich-content 或 .content-with-translation.text-content 就不会进入共享事件集合，收据也看不到它。现有 after-attachment 夹具给每条附件行都提供 rich 对象，因此测试没有覆盖这个反例。

本会话运行实际 Get-MessageRowExtractJs 返回的 JavaScript，对含真实图片节点但无 rich 节点的虚构 wrapper，输出 imageWithoutRichRetained=false。

修复要求：先判定逐条结构类型、附件与真实气泡边界，保留没有文本 rich 的真实图片/文件事件，即使只能标为身份不确定；明确的公共控件/结构噪声可排除。共享抽取、消息排序及收据消费者都要覆盖无 rich 附件，不能靠删除气泡获取唯一收据。

### R10 — P1：名字或翻译文字仍能覆盖明确右侧方向

位置：scripts/lib/msg_extract_js.ps1:38–40、75、109–110。

isBuyer0 使用“name 非空 OR 翻译文字 OR item-left”，没有先处理明确 item-right。因此右侧消息带显示名，或正文出现翻译提示，仍被设为 in/[BUYER]。这违反执行 spec §3.1“显示名、翻译标记不得覆盖明确方向”，会影响人工来源识别、暂停、买家诉求与出站收据。

本会话执行实际共享 JavaScript 的虚构 DOM 反例：

```text
明确 item-right + name='Fictional Owner' => dir=in
明确 item-right + 正文含翻译中 => dir=in
```

修复要求：已核实左/右结构先确定方向；显示名和翻译标记仅作为观测，不改写明确方向。方向冲突/不明必须显式记录，不默认作为买家问题或出站证明。让抽取、来源/人工暂停和收据实际消费者同时覆盖上述反例。

## 3. 执行交接与验收要求

继续按原执行 spec 与本单修复 R8–R10，保留已完成的 R1–R7 和其他会话已有改动。针对本单先保存失败反例，再实施并验证实际消费者，不删除负例、不仅修改状态标签。

补齐定向回归后重新跑完整 Offline，登记测试分层并记录四项结果与原生退出码。更新 implementation_report.md 和相关状态文档，区分已实现、离线已验收与真实已验收。

S0 真值、真实页面、送达、通知、五分钟恢复及生产重载仍未验收；空规则保持 unknown 是合理降级，但不能称真实平台/人工已可靠分开。到期积压主动回读的消费者覆盖仍需补齐，不能只证明时间已到期。

本轮所有新增探针数据均在显式临时隔离根，DOM 探针仅执行本地 JavaScript，无浏览器或网络。
