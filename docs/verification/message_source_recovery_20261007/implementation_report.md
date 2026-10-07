# 消息来源三类判定与接待恢复修复 - 交付报告（含独立复核 R1–R7 与第二轮 R8–R10 整改）

日期：2026-10-07（北京时间）。执行规格：[消息来源三类判定与接待恢复修复_spec_20261007.md](../../specs/消息来源三类判定与接待恢复修复_spec_20261007.md)。
独立复核：[review_report.md](review_report.md)（第一轮，结论"未通过验收，需继续修复"）、
[review_round2.md](review_round2.md)（第二轮，结论"已验证整改进展，但仍有三个阻断项"）。
执行工作区：`C:\path\to\alibaba-auto-reply`。

**结论摘要（先说边界）**：本报告覆盖两轮整改。第一轮完成 **R1–R7** 与**两条 A9 失败**；
第二轮（见 §0，最新）完成第二轮复核的 **R8–R10** 三个阻断项，并按该单 §3 的交接要求
补齐**实际消费者**与**真实子进程中断恢复**回归、补齐**到期积压主动回读**的消费者覆盖。
R1–R7 的整改**原样保留**，没有回退或放宽任何未知/收据判据。

第二轮整改后的完整 Offline 复跑**权威结果**（`offline_final7.txt`：全部**代码、测试与规则清单**改动冻结之后的复跑，
运行期间未改动仓库任何文件；其后只再修改了本报告与 `CHANGELOG.md` 的说明文字）。
它与改动冻结前的 `offline_final6.txt` **逐字相同**：

```text
TEST-SUMMARY: layer=Offline files=62 failedFiles=0 pass=3387 fail=0
LogicTests=PASS files=62 failedFiles=0 pass=3387 fail=0
IsolationChecks=PASS checked=62 issues=0
ProductionPathAudit=PASS changes=0 writerRunning=False reason=no production path changed during this run
Overall=PASS exitCode=0
NATIVE_EXIT=0
```

第一轮的权威结果（`offline_final5.txt`，62 文件 / 3302 通过 / 0 失败 / 四项全 PASS / 退出码 0）
及其之前两次落在 Chrome 写 profile 窗口里的 `UNRESOLVED` 记录（`offline_final3/4.txt`）
**原样保留**，见 §7。

**S0 来源真值仍然没有样本**（本轮同样未获授权读取实时 OnePage，生产自 2026-10-06 23:09 起全线停机）：
`platform` 与 `human` 两条规则在生产上依旧不会自行成立，没有证据的我方消息一律 `unknown`。
本轮可以宣称的是"**机制、接线与消费者在隔离条件下按规格工作**"，
**不能**宣称"已可靠三分真实消息"或"真实送达/通知已验收"。

---

## 0. 第二轮复核（R8–R10）整改 —— 本报告的最新一轮

日期：2026-10-07（第二轮复核 [review_round2.md](review_round2.md) 之后）。本轮只处理该单点名的
**R8 / R9 / R10 三个 P1 阻断项**，并补齐它要求的两类回归：**实际消费者**与**真实中断恢复**。
第一轮的 R1–R7 与两条 A9 修复**原样保留**（没有删除任何原负例，也没有放宽任何判据）。

### 0.1 R8–R10 落实位置

| 项 | 复核要求 | 落实位置 | 消费者/回归 |
|---|---|---|---|
| R8 | 把"送达已证明"和"持久化全部完成"分别判断；任何有有效收据但账本未提交/未回读的尝试必须**保持会话保护**并纳入幂等恢复，不能按 `receipt_verified` 单独认定 settled 或淘汰；monitor 对账成功必须**接通实际提交**或可靠排入恢复 | `scripts/lib/send_attempts.ps1`：新增 `Test-SendAttemptHasValidReceipt` / `Test-SendAttemptPersistenceComplete` / `Test-SendAttemptPersistencePending` / `Test-SendAttemptSettled` / `Test-SendAttemptBlocksConversation` / `Get-SendAttemptBlockReason`；`Get-SendAttempts -ActiveOnly`、`Remove-ExcessSendAttempts`、`Test-SendAttemptBlocksResend` / `Test-SendAttemptRetryAllowed`、`Resume-SendAttemptPersistence`、`Invoke-SendAttemptPersistenceRecovery` 全部改用这套判据；`Invoke-SendAttemptReconciliation` 取得收据后**立刻用生产写入器**提交 `sent_records` 与去重账本并回读；`scripts/monitor.ps1` 对账日志新增 `SEND-ATTEMPT-RECONCILE-PERSIST` | `send_attempt_receipt.tests.ps1#R8-*`（含"保留上限不得淘汰未闭环尝试"）、`send_attempt_restart.tests.ps1#R8-*`（**真实子进程**在收据后 / 账本提交中被强杀） |
| R9 | 先判定逐条结构类型、附件与真实气泡边界；保留没有文本 rich 的真实图片/文件事件（即使只能标为身份不确定）；明确的公共控件/结构噪声可排除；**不能靠删除气泡获取唯一收据** | `scripts/lib/msg_extract_js.ps1::__aarExtractRow`：判定顺序改为「结构类型 → **附件证据**（`img` 的阿里域 src/data-src + `[class*=image]/[class*=picture]` 结构选择器；无 rich 时文件卡用行文本）→ 正文 → 方向」；删除 `if (!rich) return null`，改成"既无正文、也无附件/文件证据"才不是真实气泡 | `send_attempt_receipt.tests.ps1#R9-*`（执行**真实收据 DOM JavaScript**）、`msg_source_three_class.tests.ps1#extractor-keeps-an-image-bubble-without-a-rich-node`（执行**生产会话抽取 JavaScript**） |
| R10 | 已核实左/右结构先确定方向；显示名和翻译标记仅作观测，不改写明确方向；方向冲突/不明必须**显式记录**，不默认作为买家问题或出站证明 | `scripts/lib/msg_extract_js.ps1`：`item-right` / `item-left` 先定方向（`dirsrc='layout'`）；两者同现 ⇒ `dir='unknown'` + `dirsrc='conflict'`；两者都缺 ⇒ 只有在**观测性**依据（`.item-base-info .name` / 翻译提示）存在时才推断（`name-field` / `translation-marker`），否则 `dirsrc='missing'`。`scripts/lib/msg_events.ps1::ConvertFrom-MessageRawLine` 区分"逐条元数据**显式**声明方向"与"旧行没有元数据"：前者保持 `unknown` 并原样保留依据，只有后者才回退到角色标记（`role-marker-only`） | `send_attempt_receipt.tests.ps1#R10-*`（收据消费者 + `Resolve-MessageSourceClass`）、`msg_source_three_class.tests.ps1#extractor-explicit-right-* / direction-conflict-*`（抽取 → 事件 → 四态 → **发送闸门**） |
| 交接 §3 | "到期积压主动回读的消费者覆盖仍需补齐，不能只证明时间已到期" | 机制未改（到期后自然落回正常门禁并重新读取会话）；本轮补真实入口的消费者断言 | `review_fixes_entry.tests.ps1#E-A2f-backlog-*`（窗口内不发送且暂停成立；到期轮**真的重新读取会话**；当前诉求 = 窗口内**最新**那条积压消息，且两条积压都进了模型输入） |

### 0.2 关键语义变化（下游必须知道的影响面）

- **`receipt_verified` 不再等于 settled**：只有"有效收据 **且** `persistence.sentRecord='ok'` **且** `persistence.ledger='ok'`"才算闭环。
  收据已保存、账本未提交的尝试：仍然阻断同一会话的新增发送、仍然出现在 `-ActiveOnly` 集合里、
  **不会**被每买家保留上限淘汰，并由 `Invoke-SendAttemptPersistenceRecovery`（monitor 每轮扫描 / CLI `-Action recover`）幂等补齐。
- **对账返回值把两条结论分开**：`Invoke-SendAttemptReconciliation` 的 `DeliveryState` 仍是**送达**结论
  （`receipt_verified`），新增 `PersistenceOk` / `PersistenceComplete` / `SentRecord` / `Ledger` /
  `PersistError` / `Blocked` 才是**持久化与闸门**结论。提交失败 ⇒ 保持 `persistence_pending` +
  `receipt_persistence_failed` 调查 + 会话保护（fail-closed），不会写成已闭环。
- **方向**：`item-right` / `item-left` 的**结构**证据优先。左右同现、或完全没有结构依据也没有观测性依据的
  wrapper 现在产出 `dir='unknown'` 的事件（身份不可用）：既不会被判成买家诉求，也不能作为出站证明，
  只会以 `unknown-me-tail` 保守地挡住发送闸门。
- **无 rich 的附件气泡真的进入共享事件集合**：买家侧产出 `[BUYER] [IMG] @@IMG:...`（保留阿里域 URL），
  我方侧产出 `[ME] [IMG]`。收据判定因此看得到它，而不是在"少了一条气泡"的快照上成立。
- **顺带修正一处相邻缺陷**：`Remove-ExcessSendAttempts` 旧写法用嵌套数组 + `.Item1/.Item2`
  （PowerShell 数组没有这两个成员，`$settled` 恒为空），保留上限**从来没有真正淘汰过任何尝试**；
  现在用显式对象承载 (Key, Record)，并由 `R8-cap-*` 钉住"只淘汰已闭环的尝试、绝不淘汰唯一送达证据"。

### 0.3 第二轮定向回归：先落盘失败反例，再验证修复

按复核"先保存失败反例"的要求，先把三条反例在**显式临时隔离根**（经 `tests\run_child.ps1`）复现并保存到
[round3_targeted_before.txt](round3_targeted_before.txt)：

| 文件 | 保存下来的失败反例（节选） |
|---|---|
| `send_attempt_receipt.tests.ps1` | `R9-image-bubble-without-rich-is-retained`、`R9-image-bubble-without-rich-keeps-a-real-body`、`R9-our-attachment-bubble-without-rich-is-kept-not-deleted`、`R10-explicit-right-beats-the-name-field`、`R10-explicit-right-with-a-name-still-yields-a-receipt`、`R10-explicit-right-beats-the-translation-marker`、`R10-explicit-right-with-a-translation-still-yields-a-receipt`、`R10-direction-conflict-is-recorded-not-guessed`、`R8-reconciliation-alone-does-not-release-the-conversation` 等 |
| `msg_source_three_class.tests.ps1` | 生产抽取器虚构 DOM 直接断言失败：`every invented row must still produce a line`（`3 !== 4`）—— 无 rich 的图片气泡整条消失 |
| `send_attempt_restart.tests.ps1` | `restart-reconciliation-alone-committed-both-writes`（对账只写收据、不提交两段账本） |

修复后的同一组回归（再加 `review_fixes_entry.tests.ps1`）：**4 个文件 / 417 通过 / 0 失败**，
证据见 [round3_targeted_after.txt](round3_targeted_after.txt)。**没有删除任何负例**：
三条反例断言全部保留，只是现在通过。

### 0.4 第二轮完整 Offline 复跑与逐文件对比

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final6.txt
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final7.txt
```

| 运行 | 输出文件 | LogicTests | IsolationChecks | ProductionPathAudit | Overall | 原生退出码 |
|---|---|---|---|---|---|---|
| 第一轮权威 | `offline_final5.txt` | PASS 62 / 0 / 3302 / 0 | PASS checked=62 issues=0 | PASS changes=0 | PASS | 0 |
| 第二轮（改动冻结前） | `offline_final6.txt`（+ `.production-audit.json`） | PASS 62 / 0 / 3387 / 0 | PASS checked=62 issues=0 | PASS changes=0 writerRunning=False | PASS | 0 |
| **第二轮权威**（代码/测试/规则清单冻结后） | `offline_final7.txt`（+ `.production-audit.json`） | **PASS 62 / 0 / 3387 / 0** | **PASS checked=62 issues=0** | **PASS changes=0 writerRunning=False** | **PASS** | **0** |

与第一轮权威运行做**逐文件**断言数对比：**只有 4 个文件**变化，其余 58 个字面不变 ——

| 文件 | 第一轮 | 第二轮 | 增量 |
|---|---:|---:|---:|
| `msg_source_three_class.tests.ps1` | 41 | 51 | +10 |
| `review_fixes_entry.tests.ps1` | 195 | 201 | +6 |
| `send_attempt_receipt.tests.ps1` | 73 | 112 | +39 |
| `send_attempt_restart.tests.ps1` | 23 | 53 | +30 |
| **合计** | **3302** | **3387** | **+85** |

这条对比本身就是"改动没有外溢"的证据：`msg_source` / `message_order` / `human_pause` /
`new_message_cooldown` / `reception_facts` / `closure_*` / `send_reconcile_closure` 等
**既有消费者一个断言都没有变**，全部仍然通过。

---

## 0b. 第一轮复核 R1–R7 与 A9 的落实位置（上一轮，原样保留）

| 项 | 复核要求 | 落实位置 | 消费者/回归 |
|---|---|---|---|
| R1 | 生产发送前后都用共享真实事件抽取与身份构造；运行实际收据 DOM JavaScript；验证完整发送消费者；不得过滤身份不确定的真实气泡 | 新增 `scripts/lib/msg_extract_js.ps1`（浏览器侧逐条抽取与行序列化的**唯一**实现）；`scripts/monitor.ps1::Open-ConvoAndGetMessages` 与 `scripts/lib/outbound_receipts.ps1::Get-OutboundSnapshot` 共用它；`Get-OutboundSnapshot` 返回 `Get-ConversationEventIndex` 的共享事件；`New-ConfirmedOutboundReceipt` 拒绝新的无法识别气泡（`new-unidentified-event`）与不可用身份（`new-event-identity-not-usable`），并排除结构噪声行 | `tests/send_attempt_receipt.tests.ps1`（真实 DOM JS 矩阵 + `Send-OneTalkMessageEx` 消费者）、`tests/outbound_receipt_dom.fixture.js` |
| R2 | 外部副作用前可靠持久化发送阶段；失败不得发送；重启先对账；保存完整正文与可恢复基线；真实子进程中断/重启回归 | `scripts/lib/send_attempts.ps1`：`text` 完整正文、`beforeProof.Baseline` 可恢复基线、`Start-SendAttemptSideEffect`（点击前落盘 `dispatching` 并回读核验）、`Resolve-SendAttemptFromEvents` / `Invoke-SendAttemptReconciliation`；monitor 发送路径两步落盘 | `tests/send_attempt_restart.tests.ps1`（真实子进程被强杀 + 新进程重启恢复）、`send_attempt_receipt.tests.ps1` |
| R3 | 会话级与触发级保护分离；去重键不同不得自动放行 | `Test-SendAttemptBlocksResend` 改为**会话级**（不再按 `TriggerRef` 过滤），monitor 传 `-ConvoKey`；`SameTrigger` 仅作诊断字段 | `send_attempt_receipt.tests.ps1`（`R3-new-trigger-*`）、`send_attempt_restart.tests.ps1` |
| R4 | confirm-delivery 接通尝试/收据/账本/部分提交恢复；提供可用 CLI 与 monitor 恢复入口 | `scripts/lib/investigations.ps1::Complete-InvestigationDeliveryClosure`；`send_attempts.ps1` 的 `Invoke-SendAttemptSentRecordWrite` / `Invoke-SendAttemptLedgerWrite` / `Invoke-SendAttemptPersistenceRecovery`；monitor 新增 `Invoke-MonitorSendAttemptRecovery` 并在每轮扫描调用；CLI 新增 `-Action attempts` / `-Action recover` | `send_attempt_receipt.tests.ps1`（`R4-*`）、`send_attempt_restart.tests.ps1` |
| R5 | 结构化出处证据；准确事件/尝试绑定；已送达必须验证真实收据对象；持久化成功必须回读；可恢复提交 | `Test-InvestigationStructuredEvidence` / `Test-InvestigationSourceEvidence` / `Test-InvestigationDeliveryEvidence`（拒绝 `handled`/"已处理"、要求 `id:`/`cmp|`/`ambiguous:` 事件身份、校验真实收据对象与正文哈希）；`Resolve-Investigation` 先落盘更正再关闭并**重新读取存储**写回 | `source_recovery_schedule.tests.ps1`（A22 新负例）、`send_attempt_receipt.tests.ps1` |
| R6 | 通知 UNKNOWN 不得自动再次投递；人工显式 retry 单独审计 | `notifyState`（none/sent/unknown/failed）+ `notifyAttempts`；`Test-InvestigationNotificationDue` 只对"从未尝试"为真；`Invoke-InvestigationNotification` 非人工重试直接拒绝（`delivery-attempt-recorded-operator-retry-required`）；`nextCheckUtc` 不再排自动重发 | `source_recovery_schedule.tests.ps1`（`A21-unknown-*`，复刻复核给出的 senderCalls 复现） |
| R7 | 旧入口与消费者统一委托共享判定；处理 project 与旧 bot 兼容；加未知/时间戳/平台/收据回归 | `scripts/lib/msg_source.ps1::Get-MessageSource` 委托 `Get-MessageSourceClassForLine`（`ConvertTo-LegacyMessageSource`：project→`bot`、platform 单独保留）；`scripts/lib/human_style.ps1`（只采有出处的人工消息、剥离 `@@MT/@@META`）；`scripts/lib/reply_metrics.ps1`（`Get-SnapshotLineSources` 逐行共享判定 + 收据匹配）；`scripts/analyze_replies.ps1` 传入 buyer | 新增 `tests/msg_source_consumers.tests.ps1`、重写 `tests/msg_source.tests.ps1` |
| A9 | 两条失败：夹具与验证目标 | `tests/new_message_cooldown.tests.ps1`：夹具行改为 `OwnerLine`（`@@MT` 与 `@@META` 之间有分隔空格——原夹具缺空格使 `@@MT:([^\s]+)` 把整个 `@@META` 一起吞掉，逐条时间不可解析，顺序门禁抢先拒绝），并**加强**验证目标：必须真的走到人工让路分支（`HUMAN-REPLIED-SKIP` / `reason=human-last`）且**不得**落在未验证顺序分支 | `new_message_cooldown.tests.ps1`（80→84 断言，0 失败） |


---

## 1. 实施前基线与改动边界

### 1.1 Git 基线

| 项 | 值 |
|---|---|
| 分支 | `main` |
| HEAD | `4575c470add3a8c4636059af3207fe59d44490df`（本轮与上一轮均未提交） |
| 实施前已修改（未提交） | `docs/当前状态.md`、`scripts/monitor.ps1`、`tests/layers.json`、`tests/new_message_cooldown.tests.ps1`、`tests/reception_facts.tests.ps1`、`tests/review_fixes_entry.tests.ps1` |
| 实施前已存在（未跟踪） | `tests/send_reconcile_closure.tests.ps1`、规格与两份来源证据文档、`docs/verification/architecture_opt_20261005/review_fixes/r01_r10_fix_20261006/deploy_20261006.md` |

### 1.2 复核轮次的改动边界

- 复核报告本身、上一轮的 `offline_*.txt` 与 `implementation_report.md` 均**未被复核方修改**；两轮都没有删除任何原负例。
- 第一轮新增 2 个测试文件（`msg_source_consumers.tests.ps1`、`send_attempt_restart.tests.ps1`）与 1 个 Node 夹具（`outbound_receipt_dom.fixture.js`），全部登记在 `tests/layers.json`。
- 被"改判"的既有夹具只有两类，且都是**收紧**方向：把已被新规则取代的旧正例改成新规则的等价正例（结构化证据、真实事件身份），以及把"人工 5 分钟"夹具从"无标记即人工"改为"逐条已验证发送者字段"。没有放宽任何未知/收据判据。
- **第二轮（R8–R10）没有新增测试文件**：全部改动落在 `send_attempt_receipt.tests.ps1`、`send_attempt_restart.tests.ps1`、`msg_source_three_class.tests.ps1`、`review_fixes_entry.tests.ps1` 与两个 Node 夹具里，`tests/layers.json` 无需变更（4 个文件都已在册）。
  唯一被"改判"的既有断言是 `R2-unconfirmed-block-is-lifted-only-by-the-reconciliation`：它在旧语义下断言"对账一成功就解除会话保护"，
  正是复核 R8 认定为缺陷的行为，现改为 `R8-reconciliation-alone-does-not-release-the-conversation`（更强，不是更弱）。

### 1.3 本交付涉及的文件与核心接线

| 文件 | 类型 | 核心接线 |
|---|---|---|
| `scripts/lib/msg_extract_js.ps1` | **第一轮新增；第二轮改判定顺序（R9/R10）** | 浏览器侧逐条抽取（`__aarExtractRow`）与行序列化（`__aarRowsToLines`）的**唯一**实现；会话读取与发送前后收据快照共用。第二轮：附件证据先于 rich 判定收集（无 rich 的真实图片/文件气泡保留）；`item-right`/`item-left` 结构先定方向，冲突/不明显式记录 |
| `scripts/lib/msg_events.ps1` | 新增（上轮） | 统一事件模型、`@@META` 解析、事件身份、四态判定、冲突检测、发送闸门 |
| `scripts/lib/send_attempts.ps1` | 新增（上轮大改；第二轮 R8 再改） | 尝试存储（完整正文 + 可恢复基线）、`Start-SendAttemptSideEffect`、重启对账、会话级不重发、真实写入器（sent_records + 账本，均回读核验）、持久化恢复。**第二轮**：送达已证明与持久化完成分开判断（`Test-SendAttemptSettled` / `Test-SendAttemptBlocksConversation` / `Test-SendAttemptPersistencePending`）；对账取得收据后立刻接通真实提交；恢复扫描与保留上限都按"是否闭环"而不是状态标签 |
| `scripts/lib/investigations.ps1` | 新增（上轮，本轮大改） | 调查存储、结构化证据校验、真实收据对象核验、送达关闭的完整恢复链、通知状态机 |
| `scripts/lib/outbound_receipts.ps1` | 修改 | `Get-OutboundSnapshot` 走共享抽取与共享身份；收据拒绝新出现的无法识别气泡与不可用身份；排除结构噪声行 |
| `scripts/lib/send.ps1` | 修改 | `Send-OneTalkMessageEx` 返回**同口径前后快照**（`BeforeSnapshot` / `AfterSnapshot`）供尝试级确认 |
| `scripts/monitor.ps1` | 修改（第二轮 R8 再加日志字段） | 抽取层使用共享 JS；发送前两步落盘（尝试 → `dispatching`）；尝试级确认（`Confirm-SendAttemptFromSnapshots`）成为生产调用点；读段加入重启对账；每轮扫描加入持久化恢复。**第二轮**：对账日志新增 `SEND-ATTEMPT-RECONCILE-PERSIST`（`ok/complete/sentRecord/ledger/blocked/err`），让"送达已证明但账本没提交"在日志里可见 |
| `scripts/lib/msg_source.ps1` | 修改 | `Get-MessageSource` 委托共享判定（旧词表映射 project→`bot`、platform 保留）；新增 `Test-MessageSourceIsProject` |
| `scripts/lib/human_style.ps1` | 修改 | 只采集有出处的人工消息；`Get-HumanMessageText` 剥离全部逐条标记（含 `@@MT/@@META`） |
| `scripts/lib/reply_metrics.ps1` | 修改 | `Get-SnapshotLineSources` 逐行共享判定（可带 buyer 启用收据匹配）；安抚语重复与尺寸引导只计 project；返回分类计数 |
| `scripts/analyze_replies.ps1` | 修改 | 载入共享判定与发送记录，指标计算传入 buyer |
| `scripts/investigate.ps1` | 修改 | 载入收据与发送记录库（`outbound_receipts.ps1` / `sent_records.ps1`）——否则恢复路径会因为"写入器函数不存在"退化成 `sent-record-write-returned-false`；`confirm-source` 回读核验更正；`confirm-delivery` 走完整恢复链；新增 `attempts` / `recover` |
| `scripts/lib/send_attempts.ps1` 的加载守卫 | 修改 | 只要加载了本库，就必须能拿到可用的 `Test-ConfirmedOutboundReceipt` / `Add-SentRecord`（守卫式补载），避免恢复路径静默失败 |
| `scripts/reply_rules.registry.json` | 修改 | `R-HUMAN-SOURCE-EVIDENCE` 更新为 2026-10-07.2（含旧入口与消费者委托链、新样本） |
| 测试 | 新增/修改 | 新增 `msg_source_consumers.tests.ps1`、`send_attempt_restart.tests.ps1`、`outbound_receipt_dom.fixture.js`；改写 `send_attempt_receipt.tests.ps1`、`msg_source.tests.ps1`；修正并加强 `new_message_cooldown.tests.ps1`；同步 `message_order.tests.ps1`、`source_recovery_schedule.tests.ps1`、`layers.json` |
| 测试（第二轮 R8–R10） | 修改（无新增文件） | `send_attempt_receipt.tests.ps1` 73→112：新增 R8 持久化分离 / 恢复 / 保留上限、R9 无 rich 附件、R10 明确右侧与方向冲突（含 `Resolve-MessageSourceClass` 与收据两个消费者）；`send_attempt_restart.tests.ps1` 23→53：新增"收据已保存、账本提交前被杀"与"sent_records 已提交、账本写入中被杀"两条**真实子进程**中断 + 新进程恢复；`msg_source_three_class.tests.ps1` 41→51：生产抽取器的无 rich 附件 / 明确右侧 / 翻译提示 / 方向冲突，并一路断言到事件身份与发送闸门；`review_fixes_entry.tests.ps1` 195→201：到期积压主动回读；`outbound_receipt_dom.fixture.js` / `message_extract_meta.fixture.js` 增加对应虚构 DOM 场景 |

### 1.4 生产运行数据的清理（如实记录）

本轮开始前，复核方已在报告中说明其探针产生的虚构记录已移除。
本次执行期间出现过一次**非隔离调用**：调试时直接运行
`powershell -File tests\send_attempt_receipt.tests.ps1`（未设置 `AAR_RUNTIME_ROOT`），
该次运行按当时的工作区代码向**生产运行根**写入了 5 条 `Buyer X/Y` 虚构发送尝试、
2 条虚构调查与 1 条 `buyer x` 发送记录。发现后立即清理并逐项核验：

| 存储 | 处理 | 核验结果 |
|---|---|---|
| `<runtime>\data\send_attempts.json`（+ `.bak`） | 删除（5 条全部为本轮虚构，创建时间集中在同一次运行内） | 文件不存在 |
| `<runtime>\data\investigations.json`（+ `.bak`） | 仅移除 `Buyer X` / `Buyer Y` 两条虚构调查 | 保留原有 **6** 条（`Buyer A12 / A20×3 / A22 / A23`，与复核报告口径一致） |
| `<runtime>\data\sent_records.json` | 从 `.bak` 还原（该备份即本次运行前状态） | 只剩真实买家键 1 个、4 条记录（与原始证据 §G 一致） |

此后所有测试与探针均在显式隔离根（`AAR_RUNTIME_ROOT` + 标记）下运行。
为排除"测试写生产"的可能，本轮另做了**逐文件核验**：对 `tests/layers.json` 中全部 62 个测试文件，
逐个在隔离根下运行并比对生产 `human_tasks.json` / `.bak` 的 mtime —— **没有任何测试文件改动生产运行数据**。


---

## 2. S0 对照证据与规则有效范围（与上一轮相同，未新增真值样本）

### 2.1 可用的证据

| 来源 | 内容 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| [原始证据 §A/§B](消息来源三类判定_原始证据_20261006.md) | 某个会话的 DOM 行与标签命中（`自动接待发送` / `去优化`） | 页面上确实存在这两类字面标签；左右侧结构与"有无 name 字段" | 带标签的那一行**是谁发的**；标签是否被平台独占 |
| [原始证据 §D](消息来源三类判定_原始证据_20261006.md) | 整页 HTML 命中数（`去优化`=5、`自动接待发送`=7） | 标签出现的绝对次数 | 每个标签绑定到哪一条消息 |
| [原始证据 §G](消息来源三类判定_原始证据_20261006.md) | `sent_records.json` 只有 1 个买家键、4 条记录 | 本项目的收据存储确有真实记录 | 这 4 条对应页面上哪一条消息 |
| [原始证据 §H](消息来源三类判定_原始证据_20261006.md) | 5 条 `HUMAN-SOURCE-UNKNOWN ... evidence=timer-marker-only` | "我方尾部只有时间戳"在生产是常态 | 那条到底是老板手打还是平台自动回复 |

### 2.2 本轮仍未取得的证据

- 未在真实页面上标注任何一条消息的发送者真值；未验证两个标签的独占性与一一对应关系。
- 未取得平台原生发送者字段的取值（`@@MID` 通道就绪但不伪造）。
- 未做真实发送、真实收据、真实通知投递与真实暂停/恢复。

### 2.3 规则有效范围（本轮补充 R7 后的消费者口径）

- `Get-MessageSourceRuleSet` 默认 = 空规则集；`config.json` 无 `source_rules` 段。
- 空规则集下的判定：`[BUYER]`/方向 in ⇒ `buyer`；flow/总结卡 ⇒ `noise`；
  命中**有效收据**的逐条事件 ⇒ `project`；其余我方消息 ⇒ `unknown`
  （`timer-marker-only` 或 `no-sender-evidence`）。`platform` 与 `human` 不会自行成立。
- **消费者口径（本轮收紧，必须知道的影响面）**：
  - `reply_metrics` 的"安抚语重复"与"尺寸引导命中"只把 **project（含已确认收据）** 计入我方；
    没有收据的历史 `[ME]` 行记为 `UnprovenOurLines`，**不再**被默认算成我方话术。
    报告仍能读到这个计数，因此"历史行缺证据"是可见的，而不是静默为 0。
  - `human_style` 只采集带出处的人工证据（已验证发送者字段或确切事件确认），
    平台/项目/未知行一律不算"老板手打"。
  - 旧词表语义：`project → bot`（我方自动发送）、`platform → platform`（平台发的，**不是我方**）、
    `unknown → unknown`；消费者必须显式区分，不得把 platform 当 bot。

---

## 3. 验收矩阵 A01–A24 逐项结果（本轮复核后）

测试位置代号：
`T1` = `tests/msg_source_three_class.tests.ps1`（pure）、
`T2` = `tests/send_attempt_receipt.tests.ps1`（isolated，真实 DOM JS + 完整发送消费者）、
`T3` = `tests/source_recovery_schedule.tests.ps1`（isolated）、
`T4` = `tests/human_pause.tests.ps1`、
`T5` = `tests/message_extract_meta.fixture.js`（生产抽取器虚构 DOM）、
`T6` = 既有回归（`reply_gate_dupskip` / `new_message_cooldown` / `reception_facts` / `closure_*` / `send_reconcile_closure` 等）、
`T7` = `tests/msg_source_consumers.tests.ps1`（消费者回归）、
`T8` = `tests/send_attempt_restart.tests.ps1`（**真实子进程中断 + 重启恢复**）、
`T9` = `tests/outbound_receipt_dom.fixture.js`（**生产收据 DOM JavaScript** 的虚构 DOM 执行）。

| 编号 | 场景 | 结果 | 证据 |
|---|---|---|---|
| A01 | 已验证平台来源、诉求仍待回复 | **机制通过 / 规则未验证** | T1 `A01-platform-last-allows-takeover`、`A01-platform-tail-sends`；T1 `A01b-unverified-tag-is-not-platform`（默认规则集下同一行仍是 unknown） |
| A02 | 只有通用自动接待/去优化标签 | 通过 | T1 `A02-*`；T7 `R7-unverified-tag-stays-unknown`、`R7-unverified-tag-evidence-gap` |
| A03 | 有效本项目收据唯一命中 | 通过 | T1 `A03-*`；T2 `A15-sent-record-written-with-valid-receipt`；T7 `R7-soothing-counts-receipt-proven-lines`、`R7-dimension-guidance-accepts-receipt-proven-line`、`R7-receipt-match-is-project` |
| A04 | 强来源证据冲突 | 通过 | T1 `A04-*`；T3 `A23-send-time-gate-detects-conflict`；monitor `SOURCE-CONFLICT` 分支建立 `source_conflict` 调查 |
| A05 | 无标签或只有 MT/TS | 通过 | T1 `A05-*`；T4 `P7-*`；T7 `R7-timer-only-line-is-unknown`、`R7-no-marker-line-is-unknown`；**旧入口同样**：`msg_source.tests.ps1#me-with-ts-is-not-bot`、`#me-without-ts-is-not-human`（共享库未加载时的保守阶梯也拒绝外推） |
| A06 | 翻译标记 / 名字 / 正文伪造元数据 | 通过 | T1 `A06-*`；T4 `P7-inline-marker-not-metadata` |
| A07 | flow/无 rich 噪声 + 卡片 + 真实短消息/附件混合 | 通过（**本轮接入真实收据**） | T1 `A07-*`；T5 `flowExcluded` / `realBubbles`；T2/T9 `R1-flow-card-is-not-the-sent-message`、`R1-flow-card-does-not-hide-the-real-bubble`、`R1-attachment-bubble-does-not-break-the-receipt`、`dom-adapter-keeps-flow-row-as-noise` |
| A08 | 已确认人工回复，期间买家继续发言 | 通过（隔离） | T3 `A08-*`；T4 `P1`-`P4`、`P9`、`F3a/F3d` |
| A09 | 同一人工/unknown 事件重扫、重启、窗口变化 | 通过（**两条失败已修**） | T3 `A09-*`；T4 `P2`、`P5`；T6 `new_message_cooldown`：`A9 real human interjection gate blocks`（同时断言真的走到 `HUMAN-REPLIED-SKIP` / `reason=human-last`，且未落在 `MSG-ORDER-UNVERIFIED`）、`A9 explicit human hold not cancelled by periodic scheduler` |
| A10 | 新的连续人工回复 / 白名单会话 | 部分通过（隔离） | T3 `A10-*`；T4 `P3`、`P10`（白名单实现未改，仍是"该模块不动名单"的断言） |
| A11 | 平台或人工历史已无当前待回复诉求 | 通过 | T3 `A11-*` |
| A12 | unknown 超时仍为当前相关尾部 | 通过 | T3 `A12-*` |
| A13 | 久远 unknown 不再相关 + 可信新买家诉求 | 通过 | T3 `A13-*` |
| A14 | 来源更正为 project/platform，另有可信人工事件 | 通过 | T1 `A14-*`；T3 `A14-*` |
| A15 | 唯一真实新增事件、正文完全匹配、会话一致 | 通过（**真实 DOM JS**） | T2 `A15-*`、`dom-adapter-*`、`R1-send-consumer-reports-SENT_OK-with-valid-receipt`；T9 由 Node 执行 `Get-OutboundSnapshot` 实际注入的脚本 |
| A16 | 同文不同事件、多条同刻、截断、无法建立身份 | 通过（**不再靠过滤**） | T2 `A16-*`、`R1-unidentified-new-bubble-kept-and-refused`、`R1-unidentified-bubble-is-not-filtered-away` |
| A17 | 点击后超时、进程崩溃或页面离开待回复列表 | **本轮补齐进程级演练**（隔离） | T8：子进程落盘 `dispatching` 后被**强制终止**；父进程看到 `pending_confirmation` 且会话被挡住；没有新事件时不放行；新进程重启对账 + 真实写入器恢复；T2 `A17-*`；T6 `send_reconcile_closure`（`NOT_IN_LIST` 分支，不伪造收据） |
| A18 | 收据有效但 sent_records false/异常，或账本部分成功 | 通过 | T2 `A18-*`、`R4-recovery-does-not-fake-success-without-a-ledger`、`R4-recovery-completes-when-both-writes-really-succeed`、`R4-ledger-entry-is-verified-by-read-back` |
| A19 | 可靠未送达证明，但原诉求已被人工处理/过期 | 通过 | T2 `A19-*`（含新证据格式）；**重新过门禁**由既有 `Test-ShouldReply` / 发送前复核链保证（T6） |
| A20 | 不同事件同类调查 / 同一事件反复扫描 | 通过 | T3 `A20-*` |
| A21 | 通知失败、超时、重启及人工重试 | 通过（隔离，桩通道） | T3 `A21-*`：失败/不明**分开记录**、正常路径不再自动重发（`A21-failed-attempt-blocks-the-automatic-path`、`A21-unknown-is-never-resent-by-the-normal-path`，senderCalls 恰为 1）、人工 `retry-notify` 显式且审计 |
| A22 | 只改状态或提交没有出处的确认 | 通过（**判据收紧**） | T3 `A22-claim-does-not-resolve`、`A22-source-closure-needs-provenance`、`A22-source-closure-rejects-a-bare-note`、`A22-source-closure-rejects-an-unattributable-source`、`A22-source-closure-needs-exact-event`、`A22-source-closure-with-provenance-succeeds`、`A22-correction-is-persisted-before-the-closure` |
| A23 | 生成期间人工介入、来源冲突或新买家消息 | 部分通过（接线级 + 会话级闸门） | T3 `A23-*`（含唯一的发送出口断言）；**没有**跑通"生成中人工介入 ⇒ 真发送被拒"的完整页面入口演练（见 §8） |
| A24 | 旧格式、迁移、损坏状态、保留策略与隔离根 | 部分通过 | T2 `A24-*`；T6 `atomic_state` / `isolation` 回归；本轮新增：`send_attempt_restart` 的运行根守卫（非临时隔离根直接拒绝运行） |

**第二轮（R8–R10）对矩阵的补充**（详见 §0，不改变上表的结论口径）：

| 编号 | 第二轮补充 | 证据 |
|---|---|---|
| A07 | 无 rich 文本节点的真实图片/文件气泡**保留**为事件（买家侧带 `@@IMG`），不再被抽取器删除 | `send_attempt_receipt.tests.ps1#R9-*`、`msg_source_three_class.tests.ps1#extractor-keeps-an-image-bubble-without-a-rich-node` |
| A15/A16 | 明确的 `item-right` 结构遇到显示名或翻译标记**不再**被判成买家消息；方向冲突的事件身份不可用，收据必须拒绝 | `#R10-*`（真实收据 DOM JS + `Resolve-MessageSourceClass`） |
| A17 | 除原有的"点击后中断"外，新增两条**真实子进程**中断：收据保存后、账本提交前；以及 sent_records 已提交、账本写入中 | `send_attempt_restart.tests.ps1#R8-receipt-stage-*` / `#R8-ledger-stage-*` |
| A18 | "收据有效但账本失败"的闭环补齐了**正常重启对账**这条生产路径：`Invoke-SendAttemptReconciliation` 本身接通真实提交，恢复扫描覆盖 `receipt_verified`（不再是只处理 `persistence_pending`） | `send_attempt_restart.tests.ps1#restart-reconciliation-alone-committed-both-writes`、`send_attempt_receipt.tests.ps1#R8-recovery-picks-up-a-receipt_verified-attempt` |
| 到期积压 | 补上"主动回读"的消费者覆盖：到期轮真的重新读会话，当前诉求 = 窗口内最新积压消息 | `review_fixes_entry.tests.ps1#E-A2f-backlog-*` |

**仍未验证项（不得写成已解决）**：
A01/A10 的**规则侧**（标签独占性）、A19 的"过期后重新过门禁才发送"端到端用例、
A23 的完整页面入口演练、A24 的真实索引库迁移（本轮没有既有生产索引库需要迁移）。
A17 现在是**离线进程级**演练（页面动作仍是桩，没有真实浏览器）；第二轮把它的覆盖面从
"点击之后中断"扩展到"收据已保存但账本未提交"与"两段提交之间中断"，但**仍然**是离线桩页面。


---

## 4. 存储 schema、迁移、损坏与回滚

### 4.1 存储与新增字段

| 文件 | 路径解析 | 版本 | 本轮新增/变更字段 |
|---|---|---|---|
| `data/investigations.json` | `Get-SkillPath 'investigations'` | `version = 1` | `notifyState`（none/sent/unknown/failed）、`notifyAttempts`；`notifications[]` 与 `resolution` 语义不变 |
| `data/send_attempts.json` | `Get-SkillPath 'send_attempts'` | `version = 1` | `text`（**完整正文**）、`sideEffectAtUtc`、`beforeProof.Baseline[]`（可恢复基线：Key/Sig/Identity/Quality/BodyHash/Direction/MessageId/MessageTime）、`reconciliation`（对账次数/结论）；`stage` 新增 `dispatching` |
| `sent_records.json` / `state.json` | 既有 | 不变 | 恢复路径写入的 `source = 'recovery'` 记录；schema 未变 |

两个新存储仍由 `state_store.ps1` 的原子替换写入（临时文件 → 回读校验 → 备份 → 原子替换），
且都落在 `data` 目录内，已被 `Get-AarProductionPaths` 的 data 目录指纹覆盖。
**没有新增配置键**，`config.json` / `config.json.example` 未变。

### 4.2 迁移

- 仍然**不需要数据迁移**（两个存储都是本特性新增）。
- 旧记录兼容：没有 `Baseline` 的尝试在重启对账时返回 `no-recoverable-baseline`（**拒绝给结论**，
  不凭空重建基线）；没有 `notifyState` 的调查按 `notifiedOnce` / `notifyAttempts` 推断状态。
- 既有去重键不漂移：抽取层正文清洗正则、`@@OT` 编码与 `Get-DedupKey` 口径未改；
  `@@META` 仍不进正文哈希与去重键（T5 `bodyStable` 与 `new_message_cooldown` 全绿）。

### 4.3 损坏与部分提交

| 情形 | 行为 |
|---|---|
| `investigations.json` 损坏/空/schema 非法 | 各写入口返回 `Error='investigation-store-<status>'`，不静默重建、不删库；调用方 fail-closed |
| `send_attempts.json` 损坏 | `New-PersistedSendAttempt` 返回 `send-attempt-store-<status>` ⇒ 该会话本轮不发送 |
| 尝试落盘后回读不一致 | `attempt-persist-readback-mismatch` ⇒ 不发送 |
| `dispatching` 阶段落盘失败或回读不一致 | `attempt-store-write-failed` / `attempt-stage-readback-mismatch` ⇒ **不执行输入/点击** |
| 收据有效但 `sent_records` 或账本失败 | 保持 `persistence_pending` + `receipt_persistence_failed` 调查；会话级闸门挡住新增发送；monitor 每轮与 CLI `recover` 用真实写入器重试 |
| 恢复时账本不存在/损坏 | `Set-SendAttemptLedgerEntry` 与 monitor 的 `Set-StateHash` 同方向**拒绝写入**（不用空账本覆盖历史），恢复不伪造成功 |
| 通知通道失败/响应不明 | 记 `failed` / `unknown`，不写已通知、不排自动重发、不释放闸门 |

### 4.4 备份与回滚

- 备份：两个存储与既有运行态一起备份；写入时 `state_store` 自行产生 `.bak`。
- 回滚（源码级）：改动全部在**未提交**工作区；本轮新增文件为
  `scripts/lib/msg_extract_js.ps1`、`tests/msg_source_consumers.tests.ps1`、
  `tests/send_attempt_restart.tests.ps1`、`tests/outbound_receipt_dom.fixture.js`。
  **不要**用 `git checkout` 整体还原（会丢掉上一轮与本次全部未提交改动）。
- 回滚（数据级）：两个新存储是只增的旁路证据，删除它们不影响既有发送保护，
  但会丢失活跃调查、待持久化尝试与来源更正（生产**不建议**删除）。

---

## 5. 调查 CLI 的用法、离线结果与真实投递状态

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list [-ActiveOnly] [-Buyer "Buyer Name"] [-AsJson]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action detail -Id <调查号>
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action audit -Id <调查号>
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action claim -Id <调查号> -Operator "ops"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-source -Id <调查号> -Class platform -Evidence "page:sender field read on the page at 2026-10-07 10:00" -Operator "ops"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <调查号> -DeliveryState receipt_verified -ReceiptId <收据号> -Evidence "receipt:read back from the same conversation"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action confirm-delivery -Id <调查号> -DeliveryState not_delivered_verified -Evidence "page:NOT_SENT reported by the send adapter"
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retry-notify -Id <调查号> [-DryRun]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action sweep [-Max 5] [-DryRun]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action attempts [-Buyer "Buyer Name"]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action recover [-Buyer "Buyer Name"] [-Max 5]
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action retention [-Days 30] [-DryRun]
```

退出码：`0` 成功；`1` 操作被拒/失败（含证据不足）；`2` 用法或运行根错误。

**证据格式（本轮收紧）**：`<source>:<detail>`
- 来源类 allowed sources：`page / api / field / receipt / sent-record / operator-observation`；
- 未送达类 allowed sources：`page / adapter / send-result / dispatch`（"消息不在窗口/不在待回复列表"单独不算未送达证明）；
- `detail` ≥ 8 字符，且 `handled` / `已处理` / `done` 等状态词被显式拒绝；
- 来源更正必须绑定**确切事件身份**（`id:` / `cmp|` / `ambiguous:`）；
- `receipt_verified` 必须能在尝试存储或 `sent_records` 里找到**真实收据对象**（收据号一致 + 正文哈希匹配），
  并在关闭前**回读**尝试状态与两段持久化结论。

**离线实测（隔离根，2026-10-07，真实 CLI 进程）**：

| 操作 | 实际输出 |
|---|---|
| `-Action list` | 列出 `receipt_persistence_failed` 与 `source_unverified` 两条，`TOTAL=2 ACTIVE=2`，exit 0 |
| `-Action attempts` | `att-… \| Cli Buyer \| dispatching \| persistence_pending \| True \| cli\|1 \| <收据号>`，exit 0 |
| `-Action recover`（账本已建好） | `ok=True sentRecord=ok ledger=ok`，尝试变为 `receipt_verified` |
| `-Action confirm-delivery -ReceiptId <该尝试真实收据号>` | `RESOLVED inv-receipt_persistence_failed-… delivery=receipt_verified attempt=receipt_verified`，exit 0 |
| 账本回读 | `state.json` 里 `cli buyer` 键确实写入，值为该尝试的去重键 |

其余拒绝路径：

`confirm-source` 缺证据 → `evidence-provenance-required`；
`Evidence='handled'` → 拒绝；`note:handled by the operator` → `evidence-source-not-attributable`；
事件引用不匹配 → `event-ref-does-not-match-investigation`；
`confirm-delivery` 收据号与尝试实际收据不一致 → `receipt-object-not-found-for-this-attempt`；
账本缺失时恢复 → `ledger-write-returned-false`（**不伪造成功**），建好账本后重试 → 两段 `ok` 且键可回读。

**通知适配器**：`Invoke-InvestigationNotification` 默认 `Send-WecomMessage`（离线/隔离上下文直接抛错）。
本轮**没有**向任何真实通道投递通知；真实投递仍未验证。


---

## 6. 文档同步清单

### 6.1 第一轮

| 文档 | 同步内容 |
|---|---|
| `README.md` | 能力与边界三行改写（共享抽取脚本、会话级不重发、中断后先对账、通知不再自动重发、关闭调查的证据要求）；目录结构新增 `msg_extract_js.ps1` |
| `README_部署说明.md` | 新增"发送前后同源抽取 + 两步落盘 + 会话级不重发"段落；CLI 用法补 `attempts` / `recover` 与结构化证据格式；排查表口径不变 |
| `docs/CHANGELOG.md` | 追加"未发布 - 2026-10-07 独立复核整改（R1–R7）"条目 |
| `docs/当前状态.md` | 发送收据行、消息来源与送达行更新；新增"调查与通知"行 |
| `docs/项目地图.md` | 消息来源行加入 `lib/msg_extract_js.ps1` 与旧入口/消费者委托链；发送尝试行与调查行更新 |
| `SKILL.md` | 路由行补 `attempts` / `recover`；事实段更新为"旧入口与消费者一律委托共享判定"、"两步落盘 + 会话级不重发"、"一次投递尝试后不再自动重发" |
| `scripts/reply_rules.registry.json` | `R-HUMAN-SOURCE-EVIDENCE` → 2026-10-07.2（旧入口与消费者委托链、新样本） |
| 未改 | `scripts/config.json.example`（没有新增配置键）、`VERSION`（无发版指令） |

### 6.2 第二轮（R8–R10）

| 文档 | 同步内容 |
|---|---|
| `docs/CHANGELOG.md` | 追加"未发布 - 2026-10-07 第二轮独立复核整改（R8–R10）"条目（含语义变化与"未上线"声明） |
| `docs/当前状态.md` | 发送收据行、消息来源与送达行补充"收据已保存但账本未提交 ⇒ 保持会话保护 + 幂等恢复"；人工介入行补充方向冲突不明不得外推 |
| `docs/项目地图.md` | 发送尝试行与消息来源行补充第二轮的判据与消费者 |
| `scripts/reply_rules.registry.json` | `R-HUMAN-SOURCE-EVIDENCE` → 2026-10-07.3（明确左右结构优先、冲突/不明显式记录、无 rich 附件保留、新样本） |
| 本报告 | 新增 §0（R8–R10 落实位置、语义变化、失败反例/修复后定向证据、完整复跑与逐文件对比）；§1.2/§1.3、§3、§6–§10 同步 |
| 未改 | `scripts/config.json.example`、`README.md` / `README_部署说明.md` / `SKILL.md` 的能力描述（第二轮没有新增入口或配置键）、`VERSION` |

---

## 7. 第一轮完整 Offline 复跑与退出码

> **第二轮（R8–R10）的完整复跑见 §0.4**：权威结果是 `offline_final7.txt`（全树冻结后；与 `offline_final6.txt` 逐字相同）
> —— 62 文件 / **3387** 通过 / 0 失败 / 四项全 PASS / 原生退出码 0，并与本节的第一轮结果做了逐文件对比。
> 本节保留第一轮的原始记录。

命令（三次干净复跑，运行期间都未改动仓库任何文件；权威结果取第三次）：

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final3.txt
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final4.txt
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final5.txt
```

| 运行 | 输出文件 | LogicTests | IsolationChecks | ProductionPathAudit | Overall | 原生退出码 |
|---|---|---|---|---|---|---|
| 复跑 A | `offline_final3.txt`（+ `.production-audit.json`） | PASS 62 文件 / 0 失败文件 / 3302 通过 / 0 失败 | PASS checked=62 issues=0 | UNRESOLVED changes=3（Chrome profile） | BLOCKED-UNRESOLVED | 3 |
| 复跑 B | `offline_final4.txt`（+ `.production-audit.json`） | PASS 62 文件 / 0 失败文件 / 3302 通过 / 0 失败 | PASS checked=62 issues=0 | UNRESOLVED changes=2（Chrome profile） | BLOCKED-UNRESOLVED | 3 |
| **权威复跑 C** | `offline_final5.txt`（+ `.production-audit.json`） | **PASS 62 文件 / 0 失败文件 / 3302 通过 / 0 失败** | **PASS checked=62 issues=0** | **PASS changes=0** | **PASS** | **0** |

**前两次复跑为什么是 UNRESOLVED（如实保留，不掩盖）**：那两次的变化项全部落在
`C:\path\to\alibaba-auto-reply-runtime\chrome-profile`（`Local State`、`VariationsSeedV2`、目录元数据），
即**运行中的 Chrome 自己写的 profile 文件**；runner 的既定口径是
"落在正在运行的生产进程自有路径中的变化不再算测试越界，但仍然不是通过（UNRESOLVED）"，
`writerRunning=False`、无独立写入来源证明 ⇒ 那两次不得写成 PASS。本轮**没有**启停 Chrome
（按约定不按进程名结束），第三次复跑等到浏览器不再写 profile 的正常窗口，得到 `changes=0`；
这也说明前两次的变化不是代码或测试写入，而是浏览器运行态的并发写入。

**另有一次非验收运行的说明**：执行中的第一次完整复跑（`offline_fix1.txt`）记录了 9 项变化，
其中 7 项是**本会话在运行期间编辑仓库文档/源码**造成的（README、README_部署说明、SKILL、investigate.ps1 等），
另 2 项为生产 `human_tasks.json` 的**仅时间戳**变化（内容 sha256 未变）。
该次运行不作为验收依据；随后按"逐文件"方式核验了全部 62 个测试文件，**没有任何测试改动生产运行数据**。

**结论**：第一轮把上一轮的两条 A9 失败修好，把 LogicTests 从 3182 通过 / 2 失败推进到
3302 通过 / 0 失败（失败文件数 1 → 0），并在权威复跑 C 上拿到
`LogicTests=PASS / IsolationChecks=PASS / ProductionPathAudit=PASS / Overall=PASS` 与**原生退出码 0**。
第二轮（§0）再推进到 3387 通过 / 0 失败，且逐文件对比证明只有 4 个被改的文件断言数变化。
**两轮加在一起仍然只是离线验收**：S0 来源真值、真实送达/通知/暂停与生产重载都没有做（见 §8.2）。

---

## 8. 生产加载状态与尚需明确授权或外部证据的验收项

### 8.1 生产状态

- **未部署、未重启、未改生产配置**；生产任务自 2026-10-06 23:09 起全线停机，本轮没有启停任何任务或进程。
- 运行进程**没有**加载本轮代码；改动只存在于工作区（未提交）。
- 本轮没有向任何真实会话发送消息、没有投递任何通知。
- 运行数据根：本轮清理了调试期间误写入的虚构记录（见 §1.4），此后所有测试都在显式隔离根运行。

### 8.2 仍需授权或外部证据的验收项

1. **S0 来源真值对照**（标签独占性、是否存在稳定的平台发送者字段）——决定 `platform` / `human` 规则能否成立。
2. **真实送达验收**：在可控会话发一条真实回复，验证收据、`sent_records`、`replied` 的幂等登记，
   以及"收据有效但账本失败 ⇒ persistence_pending + 调查 + 不重发"的真实路径。
3. **真实通知验收**：真实通道上一次 `SENT_OK`、一次失败/不明的分别记录与人工 `retry-notify`。
4. **真实暂停/恢复验收**：人工回一条建立五分钟暂停，到期后积压消息被处理。
   离线的**消费者覆盖**已补齐（到期轮真的重新读取会话、当前诉求 = 窗口内最新积压消息，
   见 `review_fixes_entry.tests.ps1#E-A2f-backlog-*`），但真实页面的时效仍未验收。
5. **页面级 A17 与 A23 演练**：本轮已有离线的**进程级**中断/重启恢复（T8；第二轮又补了
   "收据已保存但账本未提交"与"两段提交之间"两条中断）与接线级 A23 断言，
   但仍需在真实页面上验证"点击后崩溃/超时"与"生成期间人工介入 ⇒ 发送被拒"。
6. **发布/提交/推送/GitHub 更新**：按规格 §7/§11.3，仅在收到该会话中的明确发布指令后才执行；
   本轮**未**提交、未推送、未移动 `v0.1.1` 标签、未发布 Release。

---

## 9. 完成标准逐条对照（规格 §10）

| 标准 | 状态 |
|---|---|
| 有出处的三类来源可识别 | **部分**：机制与全部旧入口/消费者都已接线并可回归；**仍无真实出处对照样本** |
| 来源与送达不混淆 | 是（`msg_events` 判来源，`send_attempts` 判送达；收据只判 project） |
| 人工五分钟与白名单有效 | **部分**：隔离条件下按确切事件更正工作；真实人工回复的**来源证据**仍缺（依赖 §8.2 第 1/4 项） |
| 平台待回复可接管 | **部分**：机制上 platform 不启动暂停且允许接管；规则未验证 ⇒ 生产上仍是 unknown |
| 未知不无限静默 | 是（固定首次观察 + 截止 + 到期调查 + 独立提醒；一次投递尝试后人工显式重试） |
| 待确认发送不重复 | **是（第二轮再加强）**：会话级不重发 + 重启对账 + 真实子进程回归；`receipt_verified` 不再自动解除保护，收据已保存但账本未提交的尝试继续挡住该会话直到真的补齐并回读 |
| 到期积压可恢复 | **部分**：到期重算与到期调查有固定锚点；"到期后主动回读积压"的**消费者覆盖已补齐**（真实入口 + 可计数读桩），但真实页面/时效仍未验收 |
| 写入/通知失败有可操作闭环 | 是（真实写入器 + 回读 + CLI `recover` + 通知状态机 + 显式人工重试）；第二轮把**正常重启对账**这条路径也接进真实提交，恢复扫描覆盖所有"有收据但未闭环"的尝试 |

**总体**：两轮复核提出的缺陷都已逐项落到**源码、实际消费者与回归测试**；
**S0 真值、真实送达/通知/暂停与生产重载**仍按规格边界留给后续明确授权。

---

## 10. 复现命令

```powershell
# 1) 完整 Offline 回归（默认层 = pure + isolated；第二轮权威结果见 offline_final7.txt）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile docs\verification\message_source_recovery_20261007\offline_final7.txt

# 2) 定向回归（必须在隔离根下运行，见文末注意）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\send_attempt_receipt.tests.ps1   # 真实 DOM JS + 发送消费者 + R8/R9/R10
powershell -ExecutionPolicy Bypass -NoProfile -File tests\send_attempt_restart.tests.ps1    # 真实子进程中断（含 R8 两条新阶段）+ 重启恢复
powershell -ExecutionPolicy Bypass -NoProfile -File tests\msg_source_three_class.tests.ps1 # 生产抽取器：无 rich 附件 / 明确右侧 / 方向冲突
powershell -ExecutionPolicy Bypass -NoProfile -File tests\review_fixes_entry.tests.ps1     # 真实入口：到期积压主动回读
powershell -ExecutionPolicy Bypass -NoProfile -File tests\msg_source_consumers.tests.ps1   # 旧入口与消费者
powershell -ExecutionPolicy Bypass -NoProfile -File tests\msg_source.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\new_message_cooldown.tests.ps1   # 两条 A9

# 2b) 第二轮"修复前反例 / 修复后"两份定向证据（同样必须在隔离根下运行）
#     docs\verification\message_source_recovery_20261007\round3_targeted_before.txt
#     docs\verification\message_source_recovery_20261007\round3_targeted_after.txt

# 3) 文档一致性
powershell -ExecutionPolicy Bypass -NoProfile -File tests\docs_consistency.tests.ps1

# 4) BOM 守卫（新增/修改的 .ps1）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\ps_bom.ps1

# 5) 调查 CLI（需先按部署手册确认运行数据根）
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action list -ActiveOnly
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action attempts
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\investigate.ps1 -Action recover
```

> 注意：第 2–5 行的定向测试**必须通过 `run_tests.ps1` 或在显式隔离根下运行**；
> 直接 `-File` 运行会解析到真实运行数据根（本会话的一次调试即因此误写，见 §1.4）。
