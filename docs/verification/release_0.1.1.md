# 0.1.1 发布检查与脱敏记录

日期：2026-10-06（北京时间）。基线：`c6dc820` / `v0.0.2`；版本来源：[VERSION](../../VERSION)，标签 `v0.1.1`。更新说明见 [CHANGELOG](../CHANGELOG.md)。

## 发布范围

汇总接待身份和时间问答、架构优化、业务约束闭环及 [R01–R10 整改](../业务约束收敛与完整闭环修复整改交付_20261006.md)。ResponsePlan、CargoFacts/Readiness、FlowRef/FactRef、人工暂停、发送收据和子进程隔离使用共享实现；独立正式探针保留断言，只修改仓库定位方式以支持新克隆路径。

README、部署说明、项目地图、项目操作说明、CHANGELOG 与当前状态同步更新。旧状态文档归档为历史快照；各轮交付中的未提交、未上线及失败结论保留其日期与当时效力。

## 本次验证

本次冻结发布文件后复跑，原生命令为 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_tests.ps1 -Layer Offline`：

```text
TEST-SUMMARY: layer=Offline files=56 failedFiles=0 pass=3036 fail=0
LogicTests=PASS files=56 failedFiles=0 pass=3036 fail=0
IsolationChecks=PASS checked=56 issues=0
ProductionPathAudit=UNRESOLVED changes=4 writerRunning=True reason=production changes have unknown provenance; source is NOT proven (process existence or absence is not write attribution)
Overall=BLOCKED-UNRESOLVED exitCode=3
```

原始公开结果：[offline.txt](release_0.1.1/offline.txt)、[生产路径审计](release_0.1.1/offline.production-audit.json)。变化路径见审计；生产进程存在不是归因证明，保留 exit 3 与 BLOCKED-UNRESOLVED 结论。首次复跑期间发布文档仍在编辑，其额外路径变化原件仅作本机诊断保存，不用于本次最终环境结论。

补充独立回放：历史 20 场景、594 个断言、82 个失败，原生 exit 1。失败类别包括场景注入、模型调用次数/来源、旧桩文本与回复质量；需逐项对照新的 ResponsePlan 契约复核，未删改原断言，未将所有失败归为无效预期。公开证据：[回放报告](release_0.1.1/legacy_replay.md)、[逐项结果](release_0.1.1/legacy_replay.json)。**本版本按预发布代码快照发布，不声明完整验收通过。**

105 个新增/修改 PowerShell 脚本通过 Windows PowerShell 5.1 解析与 UTF-8 BOM 检查；索引内 JSON 和主要文档链接通过复核。历史验证输出保留原始空白格式，源码/维护文档单独检查空白。实际索引 blob 的补充扫描未发现本机私有值、凭据/token/私钥、本机路径或私有运行产物；模板 seller_profile 为空且 verified=false。钩子的邮箱警告逐项复核为虚构测试或工具示例。

## 脱敏范围与可复核性

- 公开源码、规格、交付和验收材料中的部署根、运行数据根及本机用户目录改为占位路径；PowerShell 探针从自身位置向上查找仓库，动态注入 harness 路径时转义单引号。
- 脱敏前原始文件保存在本机忽略目录 `release-private/original/`；公开历史日志与 JSON 的路径已替换，测试结果、失败基线、时间与指纹哈希保留。历史源码哈希描述脱敏前原件，不能用于验证改过路径的公开脚本；本次发布以 Git 提交对象为源码身份。
- 本机 `scripts/config.json`、credentials、seller_profile 真实身份、客户会话、运行日志、报告、账本与 Chrome profile 不入库。模板身份为空且 verified=false；公开邮箱为虚构测试/工具示例，不含真实客户联系人。
- 误生成的 `%SystemDrive%` 系统缓存目录和一次性源码改写/测试预期迁移脚本加入忽略规则，仅保留本地；不删除生产或本机历史数据。
- 发布前执行既有提交/推送钩子，并检查实际索引 blob、凭据与私钥/token 形态、本机私有值、文件路径和 JSON/PowerShell 格式。扫描器中的阻断规则定义属于守卫描述，单独审阅。

## 运行状态与验收边界

只读查询发现 monitor 与 watchdog 各一个运行进程，Watchdog=Running，Health/Summary/Quality/Optimize/Weekly=Ready。本次不启停服务、不改生产配置、计划任务或账本，不调用真实模型、页面、发送或通知，不联系供应商；源码发布不能证明现存进程加载本版本。

最新历史整改回归 LogicTests/IsolationChecks=PASS，但 ProductionPathAudit=UNRESOLVED、Overall=BLOCKED-UNRESOLVED、exit 3。没有独立逐路径归因就保留未验收结论。隔离自证不证明任意直接 IO 零越界；直接环境变量切根的登记盲区、当前事实读取异常等限制见整改交付。真实模型质量、页面收据、通知到达与端到端时效需上线前另行验收。
