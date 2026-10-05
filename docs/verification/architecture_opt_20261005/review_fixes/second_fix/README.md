# 八项补修（F1–F8）证据目录

日期：2026-10-05。仓库：C:\path\to\alibaba-auto-reply。对应交付报告：docs\架构交付复核八项补修交付_20261005.md。

| 文件 | 内容 |
|---|---|
| independent_probes_before.txt | **失败基线**：由独立复核的原始探针 independent_review_20261005\independent_probes.ps1 逐字产出（修改前工作区） |
| independent_probes_after.ps1 | 与原始探针**同一组输入**的复跑脚本；只改夹具时间口径三处（切割点字面量、暂停链 -NowUtc、推进时钟 Set-FixNow） |
| independent_probes_after.txt | 上述脚本在修复后工作区的实测输出（逐字保存） |
| offline_layer.txt | 全量离线回归的**第一次**运行（files=42 failedFiles=1 pass=2665 fail=1；唯一失败为 reception_facts C19 合并文本口径） |
| offline_layer_final.txt | 全量离线回归的**最终**运行（files=42 failedFiles=0 pass=2666 fail=0，生产指纹 fatal=0） |
| isolation_and_production_paths.txt | 本轮实际写入的工作区路径、生产路径守卫结论与归因说明、隔离根与未执行动作 |
| f7_before.txt / f7_after.txt | F7 的失败/通过原始输出（同一复现脚本，实际 summarize.ps1 子进程） |
| f7_repro_summary.ps1 | F7 复现脚本（含故障注入探针调用） |
| f7_probe_facts.ps1 / f7_probe_inject.ps1 / f7_probe2.ps1 / f7_fingerprint_probe.ps1 | F7 期间使用的辅助探针（事实模型、故障注入、指纹） |

说明：
- 原始独立复核文件（independent_review_20261005\）保持不动，本目录不覆盖任何失败证据。
- 所有运行都使用独立临时运行根；未启动/重启生产、未操作真实页面、未发送消息或真实通知、未提交或推送。
