# S0 固定验收与消费者

规格为本轮唯一业务依据。原 independent_review 目录只读保留；before_* 保存本轮真实原探针输出，诊断 exit0 不表示 PASS。

冲突处理：recipient_contact 仅授权联系方式，不展开 recipient_name/address；无证据的 “已收到/存档” 不是普通说明；缺身份不通配；单 open/旧触发/显式 TaskId 不单独证明货物流；独立不同值保留冲突，显式逐字段更正才失效旧版本；resolved 需原 VerificationItems 完成证据，IsOpen 只限制未来行动；原人工状态仅保留内部展示，实际联系需显式记录上下文。测试数据应补齐真实契约，业务预期不得弱化。

| 唯一判据 | 消费入口 | 固定验收 |
|---|---|---|
| 健康读取+同锁读改写 | 所有任务写入/列表/任务依赖发送 | D09–D11 |
| 当前持久 FlowRef+供应商身份 | 选择/确切回读/task_facts/msg_norm/goods/quote/monitor | D01–D04,D12,X01,X02 |
| Test-CargoFieldValue | 买家候选/任务确认/Readiness/摘要 | D05–D08 |
| 可信行动+FactRef+VerificationItems | 行动读写/更正/resolved/历史声明 | D13–D16,X01 |
| ResponsePlan/Compose/完整校验 | 初稿/一次重写/回退/DIRECT_FACT/锁内重建 | P01–P11,T01–T08,X04 |
| 共用请求项+候选语义 | contact_rules/reply_policy | P01–P10 |
| 确切消息收据+可信时间锚 | send/sent_records/msg_source/human_pause/两次快照 | H01–H08,X03,X05 |
| 全部依赖回读+单新时钟 | monitor 最终发送 | X02,T07 |
| 子进程自证+粘性出口拒绝+逐路径归因 | runner/paths/模型/CDP/发送/通知 | G01–G03 |

正式测试先运行失败基线，之后保留同一断言与输入；新增函数缺失也记录为失败，不伪装已通过。
