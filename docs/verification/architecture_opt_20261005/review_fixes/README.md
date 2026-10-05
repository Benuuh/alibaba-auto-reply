# 架构审查六项与时间地点绑定修复 —— 证据索引

依据：[架构审查六项与时间地点绑定修复 spec](../../../specs/架构审查六项与时间地点绑定修复_spec_20261005.md)。
交付报告：[架构审查与时间地点绑定修复交付](../../../架构审查与时间地点绑定修复交付_20261005.md)。

| 文件 | 内容 | 生成方式（真实工具输出） |
|---|---|---|
| `baseline_before_fix_at_20261005.txt` | 修复动作**之前**的第一次实测控制台输出（逐字保留，fail=15） | `tools\acceptance\review_fixes_baseline.ps1` 首跑 |
| `baseline_before.txt` | 同一夹具在**当前工作区**的实测输出（可作为回归基线重复运行） | 同上 |
| `baseline_after.txt` | 修复后的同一夹具输出（`BASELINE-ALL-PASS`） | 同上，`-Out` 指向本文件 |
| `offline_layer.txt` | 修复过程中一次完整的 Offline 分层回归日志（含生产守卫结论） | `tests\run_tests.ps1 -Layer Offline -KeepTemp -LogFile ...` |
| `offline_layer_final.txt` | **最终**一次完整 Offline 回归日志 | 同上 |
| `isolation_and_production_paths.txt` | 隔离方式、生产守卫结论、生产关键文件只读核对、本轮写入路径与未执行动作 | 只读命令输出 + 说明 |

全部夹具只使用虚构买家、`.invalid` 联系地址、虚构公司与多词接待名，并注入时钟；
不含真实本机身份、买家数据或凭据。全部命令在隔离运行根下执行：无浏览器、无模型、无发送、无通知。
