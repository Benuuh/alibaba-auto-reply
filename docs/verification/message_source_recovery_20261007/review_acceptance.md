# 消息来源与接待恢复：整改后离线交付复核

日期：2026-10-07。复核基于当前磁盘源码、最新 implementation_report.md、offline_final7.txt、其生产路径审计，以及本会话独立运行的定向测试和上轮反例。

**结论：本轮 R8–R10 的源码与离线整改验收通过。** 本轮复核范围内没有发现这些事项仍存在的阻断。此结论不代表真实来源识别、生产加载或页面端到端验收已完成。

## 1. 验证结果

交付方保存的完整 Offline 权威结果（本会话核对输出和审计文件，没有重复跑完整套件）：

```text
files=62 pass=3387 fail=0 failedFiles=0
LogicTests=PASS
IsolationChecks=PASS checked=62 issues=0
ProductionPathAudit=PASS changes=0
Overall=PASS exitCode=0
```

本会话在每个子进程的明确 AAR_RUNTIME_ROOT 临时隔离根下经 run_child 独立复跑：

| 文件 | 通过 | 失败 | 原生退出码 |
|---|---:|---:|---:|
| send_attempt_receipt.tests.ps1 | 112 | 0 | 0 |
| send_attempt_restart.tests.ps1 | 53 | 0 | 0 |
| msg_source_three_class.tests.ps1 | 51 | 0 | 0 |
| review_fixes_entry.tests.ps1 | 201 | 0 | 0 |
| 合计 | 417 | 0 | 全部 0 |

覆盖共享会话/收据 JavaScript、发送消费者、子进程中断后恢复、收据保存后与账本提交中的中断、人工暂停到期后积压回读以及相关入口门禁。本轮未修改测试或功能代码。

## 2. 上轮三个反例的独立重验

| 项 | 代码与消费者核对 | 独立反例结果 |
|---|---|---|
| R8 收据保存后未提交账本 | settled/active/会话阻断/保留上限均区分送达与持久化；恢复扫描包含有效收据但两段未完成的尝试；对账成功接入实际写入和回读 | 重跑上轮同一隔离对账探针：ReceiptValid=True；sentRecord=ok；ledger=ok；磁盘 sent_records=1、账本键=1；提交完成后解除保护。另以子进程测试覆盖收据后和账本提交中被强杀，未闭环时保持阻断，重启幂等补齐 |
| R9 无 rich 节点附件丢失 | 附件收集不再以 rich 存在为前提，真实附件保留到共享事件与收据集合 | 重跑上轮实际 JavaScript 反例：imageWithoutRichRetained=True |
| R10 右侧消息被名字/翻译覆盖 | 明确左右结构优先，冲突/不明显式记录；共享事件解析不再强制把显式 unknown 改成角色方向 | 重跑上轮实际 JavaScript 反例：右侧带名字 dir=out；右侧含翻译文字 dir=out；相关消费者和冲突负例在定向测试中通过 |

上轮失败报告 review_round2.md 保留作为历史证据；其 R8–R10 结论应结合本轮重验结果阅读。

## 3. 剩余真实验收范围

1. **S0 来源真值**仍缺真实对照样本；默认规则集为空，真实 platform/human 不会仅凭标签自动成立。没有证明的我方事件仍为 unknown，不能宣称已可靠三分真实消息。
2. **真实页面与出口**：真实送达收据、dsh-im 通知、人工五分钟暂停和积压恢复、页面中断及生成中人工介入尚未端到端验收。
3. **生产加载与发布**：交付仍为未提交工作区代码；本会话未部署、未启停生产、未修改生产配置或运行账本、未发送消息/通知、未提交/推送或变更发布标签。

下一阶段应先取得真实来源对照和明确规则有效范围，再在既有授权范围内组织可控页面验收与部署。离线交付通过不替代这些事实证明。

本轮新增测试与探针数据均位于明确临时隔离根；DOM 反例仅运行本地 JavaScript，不使用浏览器或网络。
