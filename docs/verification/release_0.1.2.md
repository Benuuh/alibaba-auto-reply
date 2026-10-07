# 0.1.2 发布检查与脱敏记录

日期：2026-10-08（北京时间）。基线 `4575c47` / `v0.1.1`；版本 [VERSION](../../VERSION)，标签 `v0.1.2`。本次按预发布发布，说明见 [更新说明](../releases/0.1.2.md)。

## 范围

待回复优先、自然模型回复、读取边界、逐条事件、来源证据、持久发送尝试、收据和账本恢复。现役待回复入口不再消费五分钟来源/发送等待、20 秒门槛、两轮确认或冷启动只观察；显式接管及发送对账保护保留。

各轮修复报告保留原生历史结果与当时状态：[待回复修复](pending_reply_policy_20261007/report.md)、[读取修复](conversation_read_fix_20261007/report.md)、[消息来源与发送恢复](message_source_recovery_20261007/implementation_report.md)。发布后，“未提交/未发布”仍表示对应报告当时的快照。

## 本次验证

冻结源码后执行 `powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_tests.ps1 -Layer Offline`：

```text
TEST-SUMMARY: layer=Offline files=64 failedFiles=0 pass=3306 fail=0
LogicTests=PASS files=64 failedFiles=0 pass=3306 fail=0
IsolationChecks=PASS checked=64 issues=0
ProductionPathAudit=PASS changes=0 writerRunning=False reason=no production path changed during this run
Overall=PASS exitCode=0
```

64 文件、3306 项通过、0 失败；隔离及生产路径审计 PASS，变化 0，原生退出码 0。公开原生结果：[offline.txt](release_0.1.2/offline.txt)、[生产路径审计](release_0.1.2/offline.production-audit.json)。回归后仅补充发布文档及 cdp.ps1 的 UTF-8 BOM，逻辑正文未变。历史 UNRESOLVED 和旧回放失败保留，不被本次 PASS 覆盖。

45 个新增/修改 PowerShell 文件通过 PS5.1 解析与 UTF-8 BOM 检查；实际索引共 576 个文件，私有值/凭据/客户身份/本机路径扫描、JSON 与主要文档链接检查通过。源码和维护文档空白检查通过，历史测试输出保留原生空白。邮箱警告已核对为虚构测试及工具示例。

## 脱敏

本机部署根、运行根和用户目录替换为占位路径；客户姓名统一替换为匿名代号，原始 DOM 附录中的客户正文和地址隐去，结构、标记和统计保留。公开日志以 txt 保存，原始 log 与脱敏前原件留在本机忽略目录 release-private/original-0.1.2。结果、失败、退出码及指纹哈希不因脱敏改成通过；历史哈希描述原件，本次源码身份以 Git 提交对象为准。

真实配置、凭据、账本、客户会话、通知目标、浏览器登录态及本机运行产物不入库。发布前检查实际索引文件的敏感内容、JSON、PowerShell 5.1 解析与 UTF-8 BOM、主要文档链接及提交/推送钩子。

## 未验收与恢复限制

此前读取修复曾因直接运行状态写入测试，误写虚构记录并覆盖账本；已清理及重建，但缺少事故前即时副本，无法证明逐字一致。保留 [事故说明](conversation_read_fix_20261007/report.md)，不以后续测试通过替代。

显示名、唯一可见区域和稳定采样仍不能替代已证实的平台客户/会话 ID，也不能证明全部历史加载完成。客户 profile 的全局读取、人工 CLI 发送仍待处理。真实模型、页面收据、通知投递与端到端时效未验收；0.1.1 历史 20 场景回放的 82 项失败未专项复核。

本次不启停生产、不改真实配置或账本、不调用真实模型、发送或通知。发布不自动加载新代码。
