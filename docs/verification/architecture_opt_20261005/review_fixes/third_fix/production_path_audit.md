# G1 生产路径审计证据（第三轮，2026-10-05）

本文件记录 spec §9 要求的可审查证据：精确路径、前后指纹、内容哈希、采样区间、当时测试文件、
测试/子进程身份与进程线索。**结论口径**：并发写者存在只是线索，不是写入归因证据；
来源未证实时一律记 UNRESOLVED（不是 PASS，也不是 benign）。

## 1. 采样区间与运行身份

| 项 | 值 |
|---|---|
| 采样区间 | 见 offline_layer.txt.production-audit.json 的 generatedAtUtc 与 attributionCluesBefore/After.capturedAtUtc |
| 运行方式 | powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1 -Layer Offline -LogFile <证据路径> |
| 测试文件数 | 48（pure 33 + isolated 15） |
| 每个测试文件的运行根 | %TEMP%\aar-test-<guid>\（含 .aar-isolation.json 标记） |
| 生产路径清单 | lib\paths.ps1::Get-AarProductionPaths（由 scripts\config.json 的运行态键推导） |
| 写者自有路径 | PRODUCTION-WRITER-OWNED-PATHS 行（本轮 = C:\path\to\alibaba-auto-reply-runtime\chrome-profile，因为 Chrome 正在运行） |

## 2. 判定口径（spec §9 第 3/4/5/6 条）

| 情形 | 结论 | 退出码 |
|---|---|---|
| 没有任何生产路径变化 | PASS | 0 |
| 有变化，且**没有存活写者** | FAIL（越界/本进程写入） | 1 |
| 有变化，路径在写者输出根**之外**、也不属于任何在跑的生产进程 | FAIL（越界） | 1 |
| 有变化，路径在写者输出根内，或在**在跑的生产进程自有路径**内（Chrome profile），但无独立写入来源证明 | **UNRESOLVED** | 3 |
| 调用方给出独立写入来源证明（-AttributionProven） | PASS（并记录证明文本） | 0 |

"在跑的生产进程自有路径"**不是排除目录**：落在其中的变化仍然不是通过，只是不再被当作
"测试越界"的证据。没有该进程在跑时，同一路径的变化仍然是 FAIL。

## 3. 本轮实测（多次运行，全部保留）

### 3.1 运行 A：chrome-profile 差异**复现**（对应上轮 fatal=2）

| 路径 | 变化 | 分类 |
|---|---|---|
| C:\path\to\alibaba-auto-reply-runtime\chrome-profile | changed | dir-metadata |
| C:\path\to\alibaba-auto-reply-runtime\chrome-profile\Local State | changed | file-content |
| C:\path\to\alibaba-auto-reply-runtime\chrome-profile\VariationsSeedV2 | changed | file-content |
| C:\path\to\alibaba-auto-reply-runtime\data | changed | dir-metadata |
| C:\path\to\alibaba-auto-reply-runtime\data\onetalk-write.lock | changed | file-content |
| C:\path\to\alibaba-auto-reply-runtime\data\health_state.json | changed | file-time |
| C:\path\to\alibaba-auto-reply-runtime\logs\monitor.log | changed | file-time |
| C:\path\to\alibaba-auto-reply-runtime\logs\health.log | changed | file-content |

进程线索：采样前后 Chrome 进程集合发生变化（38844 消失、23220 出现）；
monitor/watchdog 进程 2344、34196 全程存在；写锁持有者 PID 34196。
**这些只是线索**：Chrome 在后台会自行写 profile，本轮没有任何浏览器操作，因此**不**据此宣称
"测试越界"，也**不**宣称"已归因到 Chrome"；按第 2 节口径记 UNRESOLVED（不是通过）。

### 3.2 运行 B（最终交付运行）

```text
PRODUCTION-WRITER-OWNED-PATHS: C:\path\to\alibaba-auto-reply-runtime\chrome-profile
TEST-SUMMARY: layer=Offline files=48 failedFiles=0 pass=2926 fail=0
LogicTests=PASS files=48 failedFiles=0 pass=2926 fail=0
IsolationChecks=PASS checked=48 issues=0
ProductionPathAudit=UNRESOLVED changes=2 writerRunning=True reason=concurrent change inside the live writer's output roots; the source is NOT proven (process existence is not write attribution)
Overall=BLOCKED-UNRESOLVED exitCode=3
```

结构化审计明细（精确路径 / 前后取值 / 变化分类 / 采样区间 / 进程线索 / 每个测试文件的差异）见
offline_layer.txt.production-audit.json（本轮仅保留差异明细，完整前后指纹体积过大且无额外信息）。

## 4. 只读审查：Offline 测试及子进程调用链（spec §9 第 2 条）

审查方法：对 48 个测试文件做静态扫描（是否以程序方式运行生产入口、是否启动浏览器/真实发送出口、
是否显式进入隔离、是否可能绕开隔离出口），并人工核对全部命中点。

| 检查项 | 结论 |
|---|---|
| 以**程序方式**运行 scripts\monitor.ps1 | 无。没有任何 "-File ...monitor.ps1" 形式的调用；对 monitor.ps1 的引用全部是 Parser::ParseFile（AST 抽取函数定义）或注释 |
| 启动生产 watchdog.ps1 / chrome_ensure.ps1 / Chrome | 无。Start-Process 命中点只启动**临时根内生成的辅助脚本**（atomic_state 的并发写者、lock 的竞争子进程、env_block/daemon_launch 的 powershell 探测） |
| 真实发送出口 | isolation.tests.ps1 断言 Send-OneTalkMessage 与 Invoke-CdpEval 在隔离模式下**抛 ISOLATION-VIOLATION**；isolated 层不调用真实发送适配器 |
| 隔离入口 | isolated 层 15 个文件：10 个显式 Initialize-AarIsolation；其余（amazon_destination / daemon_launch / env_block / new_message_cooldown / reception_facts / send_page_param）由 runner 注入的 AAR_RUNTIME_ROOT + 标记文件承担，运行态路径全部落在临时根内 |
| 生产写操作 | 所有运行态写入都经过 Write-JsonDocumentAtomic → Assert-AarNoProductionPath；隔离模式下写生产路径会直接抛错（有专门回归：isolation.tests.ps1 / env_block.tests.ps1） |

**审查结论**：Offline 测试链**没有**发现"读取真实配置后写生产路径、启动生产入口/Chrome、
或绕开真实出口隔离"的越界，因此本轮不需要把测试改到 TEMP 路径的改动，
runner 的副作用守卫保持原样（未放宽、未扩大排除目录、未把任何路径加入 benign）。

## 5. 验收口径修正（spec §9 第 4/5 条）

* runner 不再写 "attributed to the live writer, not to this run"；改为
  "concurrent change inside the live writer's output roots; the source is NOT proven
  (process existence is not write attribution)"，并明确 "a running writer is a clue, not proof"。
* 分开报告 LogicTests= / IsolationChecks= / ProductionPathAudit= / Overall=，保留真实退出码
  0 / 1 / 2 / 3（见第 2 节）。
* 结构化审计证据写入 "<LogFile>.production-audit.json"。

## 6. 本轮未能完成的层面（如实声明）

* 生产路径的**独立写入溯源**未取得（未安装新系统工具、未启停生产、未改权限，均由本轮边界决定）。
* 因此完整验收保持待确认：**业务回归通过，生产路径验收待核查**，需要在获授权的受控环境里复验。
