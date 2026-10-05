# 架构优化离线验收证据（2026-10-05）

## 1. 运行方式

```powershell
# 默认入口（纯逻辑 + 隔离集成）
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
# 原始证据（每个文件的逐条输出与生产指纹结论）
docs\verification\architecture_opt_20261005\offline_layer.txt
```

未运行 `-Layer Live`（会读写生产运行根并访问 9222 页面）。未启动/停止任何生产进程或计划任务。

## 2. 结果

```text
TEST-SUMMARY: layer=Offline files=37 failedFiles=0 pass=2101 fail=0
PRODUCTION-GUARD: fatal=0 benign=2 writerRunning=True
ALL SELECTED TEST FILES PASS
```

- 分层：pure=25、isolated=12、live=5（清单见 `tests/layers.json`；未登记文件会让运行器直接失败）。
- 每个子测试进程使用本次运行独有的临时运行根 + `.aar-isolation.json` 标记；
  真实 CDP 出口（`lib/cdp.ps1`）与真实发送适配器（`lib/send.ps1`）在隔离模式下直接抛
  `ISOLATION-VIOLATION`（由 `tests/isolation.tests.ps1` I08/I09 断言）。
- 生产指纹比对：运行前后对生产路径（代码根、scripts、data、logs、backups、凭据、账本、锁/PID 等）
  取"大小 + 最后写入时间"指纹。本次 fatal=0。
  运行期间本机有**生产 monitor/watchdog 在跑**（写自己的 data 目录时间戳与 logs/monitor.log），
  这些变化被归因给该写者并记为 `PRODUCTION-GUARD-WARN`，不计入本次运行。

## 3. 关键专项（可在 offline_layer.txt 内检索）

| 专项 | 文件 | 断言 |
|---|---|---|
| 联系方式最高优先级红线 | contact_redline.tests.ps1 | 57 |
| 人工暂停 / 可信人工来源 / 已确认发送记录 | human_pause.tests.ps1 | 45 |
| 人工任务闭环与执行证据 | human_tasks.tests.ps1 | 48 |
| 单一货物事实模型与报价准备度 | cargo_facts.tests.ps1 | 159 |
| 原子锁（含两进程竞争） | lock.tests.ps1 | 22 |
| 页面锁范围与过期草稿 | lock_scope.tests.ps1 | 25 |
| 原子状态持久化 | atomic_state.tests.ps1 | 23 |
| 发送结果结构化与核对 | send_result.tests.ps1 | 25 |
| 隔离基础与生产守卫 | isolation.tests.ps1 | 25 |
| 规则清单与消费方一致性 | rule_registry.tests.ps1 | 14 |
| 真实入口（隔离桩）回归 | reception_facts.tests.ps1 / new_message_cooldown.tests.ps1 | 506 / 80 |

## 4. 边界（离线通过 ≠ 生产上线）

- 工作区代码版本与运行进程已加载版本**不同**：生产 monitor/watchdog 仍运行旧代码，本轮未重启。
- 未做：真实模型质量、真实页面发送、通知投递到达确认、真实端到端时效测量。
- 页面锁持有时间/生成耗时等指标已写入日志（`PAGE-LOCK-ACQUIRED / LOCK-RELEASED-FOR-GENERATION /
  PAGE-LOCK-REACQUIRED / STALE-DRAFT-DISCARD`），但**尚无**生产实测数据。
