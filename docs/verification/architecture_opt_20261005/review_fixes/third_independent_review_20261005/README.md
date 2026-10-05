# 第三轮交付独立复核证据

报告：[独立复核七项修复交付复核](../../../../独立复核七项修复交付复核_20261005.md)。日期：2026-10-05。

| 文件 | 内容/退出口径 |
|---|---|
| offline_rerun.txt | 48 文件、2926/0；ProductionPathAudit=UNRESOLVED、Overall=BLOCKED-UNRESOLVED，runner 日志 exitCode=3；工具启动外层为非零1 |
| offline_rerun.production-audit.json | 同次生产路径指纹和变化证据，不将并发线索当来源证明 |
| original_probes.ps1 / original_probes_rerun.txt | 原七项复现 7/0，子进程 exit0 |
| contact_entry_probe.ps1 / contact_entry_probe.txt | AST 抽取真实 monitor，IO 为桩，泛化联系方式请求 Sends=1；脚本明确 exit1 |
| time_probes.ps1 / time_probes.txt | 同类 monitor 隔离入口及完整规则；1 pass、8 fail、exit1 |
| request_probes.ps1 / request_probes.txt | 纯库、真实事实提取、LLM桩及真实生成；记录 Ok/Source/Calls/Rewrites。exit0只是脚本完成 |
| task_probes.ps1 / task_probes.txt | TEMP任务库，真实记录/回读/统一事实/报价候选；exit0只是脚本完成 |
| pause_probes.ps1 / pause_probes.txt | TEMP发送/暂停库，真实发送记录匹配及同步；exit0只是脚本完成 |
| reviewed_source_hashes.json | 审阅源文件的SHA256，不含真实配置或密钥内容 |

独立脚本自行建立 TEMP 运行根；不执行 monitor 主分发。所有测试资料均为虚构。复制保留原脚本及原始输出；部分原始输出为 Windows PowerShell 重定向的 UTF-16，脚本为 UTF-8 BOM。

复跑独立脚本（示例）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\path\to\alibaba-auto-reply\docs\verification\architecture_opt_20261005\review_fixes\third_independent_review_20261005\contact_entry_probe.ps1'
```

不要把诊断记录脚本的 exit0 当作业务通过；以输出实际行为和复核报告中的预期对比为准。本目录未包含 Live/真实模型/浏览器发送/通知或生产部署证明。
