# KNOWN_EXCEPTIONS — 已知例外清单

> **用途**：把「看起来像故障、实际是已知预期」的现象固定下来，避免后续会话/执行者把它们误判为回归、误当成功、或为"让告警变绿"去改判据/阈值。
> **建立**：2026-09-26，由 `specs\告警通道交接固化_20260926.md` §10.1 交付物 #6 要求创建（此前不存在）。
> **维护纪律**：**只增不改**。每条必须写清「现象 / 证据 / 影响 / 不要误判为 / 下游处置」。
> **证据强度**沿用本仓 spec 惯例：`[已核实·文件内部逻辑]` ＞ `[已核实·隔离实验]` ＞ `[已核实·生产观察]` ＞ `[需实测]`。
> **红线提醒**：**不许**为了让某条例外"消失"而放宽阈值、关计划任务、改判据——那属于另立 spec 的能力型改动。

---

## E-01 `lib\deadman.ps1` 恒返回 `fail`（"假安全"）

- **现象**：带外心跳（deadman）探测在本机**恒为 `fail`**，即使链路正常也不会变绿；`config` 里的 `deadman_ping_url` 为空。
- **原因**：该脚本依赖 `Invoke-WebRequest`，在本机受限环境下无法正常出网/执行，属实现缺陷而非网络故障。
- **证据**：前序 `REPORT_插件接入_20260926.md` §0 遗留风险 / §6.3；本仓 spec `告警通道交接固化_20260926.md` §2 D4、§3 非目标 1、附录 C 问 3 均以其为前提。
- **影响**：**给不出"带外兜底"**——一旦本机整体失能（如断电、断网、进程全灭），没有任何外部通道能发现。它当前提供的是**虚假的安全感**。
- **不要误判为**：① "deadman 探测失败 ⇒ 本机网络坏了"；② "deadman 在跑 ⇒ 有带外保障"（两者都错）。
- **下游处置**：另立 spec 修 `lib\deadman.ps1` 并配置 `deadman_ping_url`（spec 附录 D 第 2 条）。**本轮明令不修**。

## E-02 `status-tip` 判据失真：业务可用但 `PageDown` 恒为 `True`

- **现象**：`monitor` 的页面判据读 `.connection-status-container .status-tip`，会出现**业务实际可用、判据却恒判 `PageDown=True`**，进而触发无意义的软刷新/重启。
- **证据**：前序 REPORT 已登记；本仓 spec `告警通道交接固化_20260926.md` §3 非目标 2、附录 D 第 3 条。本机 2026-09-26 11:05 只读探针实测 `tip=网络连接已经断开`、`hasTa=false`（**该次确为真断连**，见 E-03 的区分说明）。
- **影响**：自愈动作（reload / `chrome_ensure -ForceRestart`）可能被**误触发**，白白重启 Chrome、中断业务。
- **不要误判为**：① "`PAGE-DOWN` 一定是误报"（真断连与误报**都会**打印同一行，必须另取证据区分）；② "看到 `PAGE-DOWN` 就说明某次修复失败"（spec §8 R1 明确禁止这样用）。
- **下游处置**：另立 spec 修判据（spec 附录 D 第 3 条）。**本轮明令不改判据**。

## E-03 `monitor.log` 的 `items=` 在 `0` 与 `20` 之间跳变

- **现象**：同一页面状态下，`Scan cycle done` / `PAGE-DOWN` 行里的 `items=` 会在 `0` 与 `20` 之间跳。
- **证据**：前序 REPORT 自偏差 D-15 起持续记录；本仓 spec `告警通道交接固化_20260926.md` §8 R3。
- **影响**：**不能用 `items=` 判断"页面上有没有待处理会话"**；据它做业务判断会得出错误结论（本次实测同一天内既见到 `items=0` 也见到 `items=1`）。
- **不要误判为**：① "`items=0` ⇒ 没有客户消息"；② "`items` 跳变 ⇒ monitor 逻辑坏了"。
- **下游处置**：属既有已知失真，**本仓 spec 不修**（§8 R3 明文）。若要修，另立 spec。

## E-04 旧通道 `lib\wecom.ps1::Send-WecomMessage` 恒 `SERVICE_DOWN`（D2 的**预期**后果）

- **现象**：自决策 D2（企微告警以新通道 dsh-im 为准、停掉 watchdog 对旧通道 19886 的保活）落地后，走旧通道的告警发送**恒返回 `SERVICE_DOWN`**，`health.log` 也会持续 `SERVICE_DOWN`。
- **原因**：旧通道被有意停用/不再保活；`tools\wecom-connector` 不再常驻监听 `127.0.0.1:19886`。
- **证据**：本仓 spec `告警通道交接固化_20260926.md` §1.1（`wecom-connector.ps1 -Action status ⇒ SERVICE_DOWN`）、§2 D2、§8 R5/R6；`config.json` 的 `exit_on_kicked_offline: true` 与新旧通道**同一个 bot**（`wecom_7ffc7620be27735ce1ec4cf3`）的互踢逻辑见 §1.4。
- **影响**：**在 A8 完成（新通道业务级验证）之前，告警仍是"哑"的**——`alert_active.json` 里会出现"全是 `SERVICE_DOWN`/`local-only`、没有一项真推出去"。这是**决策的代价，不是新故障**。
- **不要误判为**：① "告警链路修好了"（`SERVICE_DOWN` 消失≠能到达人，唯一硬证据是 A8：用户发消息后 `dsh-wecom` 的 `state.json` 时间戳推进）；② "`SERVICE_DOWN` ⇒ 赶紧把旧通道再拉起来"（那会与 dsh-im 抢同一个 bot，回到互踢状态）。
- **下游处置**：把 7 处告警调用点从 `Send-WecomMessage` 改走 dsh-im（spec 附录 D 第 1 条，**下一份 spec**）。**不许**为让告警变绿改阈值或关任务。

---

## 补充：本轮执行者新发现的例外（依 spec §11-6「允许补充、只增不改」）

> 来源：`specs\REPORT_告警通道交接固化_20260926.md` §8 D-04 / D-05 / D-06。均为 **2026-09-26 11:04–11:07 只读实测**。

## E-05 `data\onetalk-write.lock` 的两面性：瞬时锁 + `pid=0` 假阳性

- **现象 A（瞬时锁）**：该锁并非长期驻留文件——实测 `11:05:05` 不存在 → `11:05:56` 存在 → `11:06:05` 又不存在（现役 monitor 按轮创建/删除）。因此"锁文件存在"**不等于**"有进程持锁不放"。
- **现象 B（假阳性陷阱）**：若照抄 `[int](((Get-Content $lock -Raw) -split '\|')[0])` 再 `[bool](Get-Process -Id $lockPid ...)`，当锁文件**不存在**时 `$lockPid = 0`，而 `Get-Process -Id 0` 会返回 **Idle 进程** ⇒ 打印出 `lock pid=0 alive=True`，把"没有锁"误判成"有活进程持锁，禁止操作"。
- **证据**：本轮实测原始输出（`Get-Content : Cannot find path '<部署根>\data\onetalk-write.lock'` 与同一行的 `lock pid=0 alive=True`）。
- **影响**：① 会误判"陈旧锁"仍然存在（规划会话 `10:52` 观察到的 `19600|…` 陈旧锁，在 `11:05` 已不复存在）；② 会让"清锁"步骤错误地走 `LOCK HELD BY LIVE PROCESS - DO NOT REMOVE` 分支。
- **不要误判为**：① "锁在 ⇒ 有人正在写 ⇒ 不能起 monitor"；② "`alive=True` ⇒ 持有者活着"。
- **下游处置**：后续 spec 应改为**先 `Test-Path` 再解析**，并把 `$lockPid -le 4` 视为无效值。本轮未执行任何清锁动作。

## E-06 现役 `monitor` 会**自主**调用 `chrome_ensure.ps1 -ForceRestart` 重启 Chrome

- **现象**：`monitor` 在页面判据连续 N 次为 `PAGE-DOWN` 后，会自行升级为 `chrome_ensure.ps1 -ForceRestart`，**杀掉并重启 Chrome**，随后走 `navigate+login` 路径；这段时间内 9222 的持有者 pid 会变（实测 `11:05:08` 触发，`18988 → 7412`，`11:05:11` 就绪，`11:05:18` 转入 navigate+login，`11:06:14` 该 `chrome_ensure` 进程仍在跑）。
- **证据**：`monitor.log` 原文 `PAGE-HEAL: escalating to chrome_ensure -ForceRestart` / `CHROME-ENSURE: FORCE-RESTART triggered by …` / `FORCE-RESTART targets=10 pids=…`；`Get-CimInstance` 捕获到 `chrome_ensure.ps1 -ForceRestart` 命令行与其 pid。
- **影响**：任何"我这次保证不动 Chrome / 不动页面"的承诺，都**可能被现役自愈层自己打破**；观测窗口内的页面状态、9222 持有者、`chrome-profile` 都会变。做变更前必须先确认 monitor 的当前自愈档位与重启计数。
- **不要误判为**：① "有人手动重启了 Chrome"；② "重启后还是 `PAGE-DOWN` ⇒ 修复失败"（真断连需要人工重连，见 spec §3-3 / 附录 D 第 4 条）。
- **下游处置**：页面人工重连另立 spec；在此之前，任何 spec 都应把"monitor 可能自主重启 Chrome"写进前置假设。

## E-07 `wecom_start.ps1` 报 `WECOM-START-FAIL`，但旧通道进程**实际已经起来**

- **现象**：实测同一秒内既出现 `watchdog.log: WATCHDOG-WECOM: issue - WECOM-START-FAIL`，旧通道**也确实在跑**：`node.exe "<部署根>\tools\wecom-connector\server.js"`（起始时间同一秒）、`19886` LISTEN、节点日志 `HTTP-READY 127.0.0.1:19886` + `AUTH-OK: long connection established`。
- **证据**：三份独立只读证据（进程起始时间、监听端口、`tools\wecom-connector\logs\wecom_bot.log` 末两行），2026-09-26 11:03:51。
- **影响**：**不能拿 `WECOM-START-FAIL` 当"旧通道没起来"的证据**；反过来说，"启动器返回失败"会让 watchdog 在下一轮继续尝试启动，叠加 `exit_on_kicked_offline: true` 就是**反复互踢**的燃料。
- **不要误判为**：① "报 FAIL ⇒ 通道是死的"；② "报 FAIL ⇒ 与 dsh-im 不冲突"。
- **下游处置**：列为后续 spec 输入（核查 `wecom_start.ps1` 的启动成功判定与其返回码语义）。本轮**未改该文件**。

---

## 附：本清单与"失败/回归"的边界

| 看到这个 | 属于 | 该怎么做 |
|---|---|---|
| `PAGE-DOWN (Nx) reason=tip:网络连接已经断开` | **已知例外 R1**（除非另证为误报，见 E-02） | 不要重启 Chrome、不要动页面；真断连要人工重连（另立 spec） |
| `PAGE-HEAL-ALERT-ONLY: max-restarts-reached` | 预期（自愈已到上限、停自动重启） | 不要为了它改上限 |
| `Send-WecomMessage` / `health.log` 报 `SERVICE_DOWN` | **已知例外 E-04**（D2 预期） | 不要改阈值、不要关计划任务、不要把旧通道再拉起来 |
| `items=` 在 0/20 跳变 | **已知例外 E-03** | 不要用 `items=` 做业务判断 |
| deadman 恒 `fail` | **已知例外 E-01** | 知道"带外兜底目前不存在"，别当成"有保障" |
| `watchdog.log` 十几分钟没新行 | 预期（ACCIO 约每 10 分钟一条、且仅"每 20 轮"或状态变化才写） | 判"卡死"要结合 `watchdog.pid` + 采样，别只看几分钟空窗（spec §8 R2） |

> **唯一能证明"告警真的能到达人"的证据**：用户给企微机器人发一条消息后，`%USERPROFILE%\.dsh\integrations\dsh-wecom\bots\<botId>\state.json` 的 `LastWriteTime` **晚于**发消息时刻（spec §7 A8）。其余任何"绿了"的日志都**不能**替代它。

---

## E-08 判据已修但**现役进程尚未加载**：`status-tip` 陈旧残留（原 E-02 的修复，含"未生效窗口"）

- **现象（修复本身）**：`scripts\lib\cdp.ps1` 的 `Test-PageHealth` 已把判定抽成纯函数 `Get-PageHealthVerdict`，并新增**可见性维度**：
  `.status-tip` 文案匹配断连词 **且** `.connection-status-container` 的 `offsetHeight ≤ 5`（且 ≥ 0）⇒ 判为**陈旧残留**（`Reason=tip-hidden-stale`、`PageDown=False`），不再判 down。
  容器不可见时**退回旧行为**（只看文案）——最坏与修复前一致，不制造新的静默失守。
- **现象（未生效窗口，最易误判）**：`monitor.ps1` 在启动时 **只 dot-source 一次** `lib\cdp.ps1`（`monitor.ps1:14`，主循环在 `:1190`），
  因此**已在运行的 monitor 进程仍在用内存里的旧判据**。实测：`lib\cdp.ps1` 于 `11:44` 修好并跑绿（10/10），
  而 pid 32568（`11:04:22` 启动）在 `11:45` 仍继续打印 `PAGE-DOWN (2xx) reason=tip:网络连接已经断开`。
  **不动 monitor 进程 ⇒ 该修复要等下一次 monitor 重启才生效**（无需再改代码）。
- **证据**：`scripts\lib\cdp.ps1` 的 `Get-PageHealthVerdict` 原文（含 `$tipDown -and $ContainerHeight -le 5 -and $ContainerHeight -ge 0` 分支）；
  只读 CDP 探针 `containerH=0/rectH=0` + 祖先链 `DIV.connection-status-container h=0 overflow:hidden`（父级 `h=354`）；
  `tests\page_health_verdict.tests.ps1` 跑红 C1/C4 FAIL → 跑绿 `RESULT: pass=10 fail=0`；
  新进程实测 `Test-PageHealth ⇒ PageDown=False Reason=tip-hidden-stale`（679 ms）；`monitor.ps1:14` 与 `:1190` 原文。
- **影响**：① 修好之后**短时间内仍会看到 `PAGE-DOWN reason=tip:…`**，那不是"修复失败"；② 反向风险：若把"日志不再有 PAGE-DOWN"当作唯一验收证据，会在**代码已对、进程未换**时误判为未修好。
- **不要误判为**：① "改了 `lib\cdp.ps1` ⇒ monitor 立刻按新判据跑"（**错**：dot-source 一次，需重启进程）；② "`tail monitor.log` 还有 `tip:…` ⇒ 这次修复没生效"（要看**进程启动时间**与**文件修改时间**的先后）。
- **下游处置**：验收"判据是否生效"必须二选一 ——（a）在**新进程**里调用 `Test-PageHealth`（本轮的 S8 做法，实测 `tip-hidden-stale`）；或（b）显式重启 monitor 后再看 `monitor.log` 的 `Reason=`。
  **重启 monitor 不在本轮授权范围内**（本轮禁令：不动页面、不动 Chrome、不做计划任务以外的写操作），故 `G-B4` 记为**未取证**并列为本轮**待用户决策项 #1**。

## E-09 既有回归测试 `tests\page_health.tests.ps1` 曾**固化**误报判据（已在本轮修正）

- **现象**：该测试第 44 行原为 `if ($ptip -match '网络连接已经断开|…') { Assert-True "consistency-tip-means-down" ($r.PageDown -eq $true) }` ——
  它把"tip 文案存在 ⇒ 必然 PageDown=true"**写死成断言**。于是判据一旦按可见性修正（E-08），**这个测试必然变红**，且红得"理直气壮"。
- **证据**：G0-1 快照（`%TEMP%\g0b_20260926_113405\page_health.tests.ps1`，SHA256 前 16 位 `032D7B101BBE355C`，与开工基线一致）
  在新判据代码下实跑 ⇒ `FAIL: consistency-tip-means-down`、`RESULT: pass=14 fail=1`、`exit=1`；
  改为"tip 文案**且容器可见**才要求 down、容器折叠时要求 up"后 ⇒ `RESULT: pass=15 fail=0`、`ALL PASS`。
- **影响**：**测试会为错误行为背书**。当下游按新证据修正实现时，会被旧测试判成回归，从而诱导执行者把实现改回错误行为（或在实现与测试之间来回拉锯）。
- **不要误判为**：① "既有测试红了 ⇒ 新实现错了"（先看这条断言是否把**现象**当成了**规格**）；② "把断言删掉/放宽就能过"（正确做法是补上缺失的那一维——此处是**可见性**，而不是削弱文案匹配）。
- **下游处置**：修测试时**只加维度、不删维度**：中文匹配串与旧实现**逐字保留**（本轮 `lib\cdp.ps1` 的 `$tipDown` 匹配串即与原 `if ($tip -match …)` 完全一致）。
  另注：`page_health.tests.ps1` 的探针 JS 现在也返回 `containerH`，与 `lib\cdp.ps1::Test-PageHealth` 的探针字段保持一致；两处探针**字段名必须同步**，否则 `$ch` 会静默退回 `-1`（= 旧行为）。

## E-10 `edit` 类工具改 `.ps1` 会**剥掉 BOM** ⇒ PowerShell 5.1 按 ANSI 读 ⇒ 中文字面量静默失配

- **现象**：用文本编辑/补丁类工具修改**带 BOM**的 `.ps1` 后，文件首 3 字节由 `239,187,191` 变成正文首字符（本轮实测 `lib\cdp.ps1:` `35,32,108`＝`#`、空格、`l`；`tests\page_health.tests.ps1:` `35,32,112`＝`#`、空格、`p`）。
- **后果（比误报更危险）**：Windows PowerShell 5.1 对**无 BOM**的 `.ps1` 按 **ANSI/GBK** 解码 ⇒ 文件内所有中文字面量变乱码 ⇒
  `lib\cdp.ps1` 的断连文案匹配 `'网络连接已经断开|…'` **静默失配** ⇒ `Test-PageHealth` **永远**返回 `PageDown=$false`（既不报错也不告警）；
  `wecom_start.ps1` 的中文门禁注释、`tests\page_health_verdict.tests.ps1` 的中文用例数据同理会乱码。
- **证据**：本轮三次实测（`lib\cdp.ps1`、`tests\page_health.tests.ps1`、`tests\page_health_verdict.tests.ps1` 均被剥）；用
  `[System.IO.File]::ReadAllText($f,[Text.Encoding]::UTF8)` + `New-Object System.Text.UTF8Encoding($true)` 写回后 ⇒ `BOM3=239,187,191`、`ParseErrors=0`、中文 `Contains('网络连接已经断开')=True`。
- **注入面提醒（本轮新发现）**：该坑**不只影响被 `edit` 改的文件**——**任何新建的 `.ps1`** 若由不带 BOM 的写入路径创建（本轮实测新建的 `tests\page_health_verdict.tests.ps1` 与 `%TEMP%` 下的临时 shim 都是 `35,32,...`），同样必须补 BOM。**跑红用的临时 shim 也会中招**：不补 BOM 会让"旧逻辑等价实现"里的中文正则失配，跑红会**假通过**。
- **不要误判为**：① "解析没报错 ⇒ 文件没问题"（ANSI 解码不报错，只静默改变字面量）；② "只有 `edit` 过的文件才要补 BOM"（新建的也要）。
- **下游处置**：**只对 `.ps1`** 执行 BOM 恢复（`scripts\config.json` 本来就是无 BOM 的 `123,13,10`，给它加 BOM 会改变文件语义）；
  顺序必须是"该文件**所有**编辑做完 → 补 BOM → **只跑只读复验**（复验中不得再编辑）；补 BOM 后必须复验 **BOM3** 与 **中文完整性** 两项。

## E-11 进程枚举**自匹配假阳性**：执行者自己的命令行被算成被观察对象（本轮新发现）

- **现象**：用 `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'watchdog\.ps1' }` 统计守护实例数时，
  **执行者自身**只要在命令行/脚本文本里出现过 `watchdog.ps1`（本轮更宽：`watchdog.pid`、`watchdog.log`、甚至正则字面量 `watchdog\.ps1`）就会被计入 ⇒ 实例数**虚高**。
- **证据**：2026-09-26 11:33 复核会话实测原始输出 —— 同一次枚举返回两条：真实守护 `pid=31792 ... -File "<部署根>\scripts\watchdog.ps1" -Action start`，
  以及 `pid=36120 self=True`（即**执行者自己**那条 `-Command "... watchdog.pid ... watchdog.log ... watchdog\.ps1 ..."`）。
  注：`watchdog\.ps1` 里的 `.` 在正则中匹配任意字符，`watchdog.pid`/`watchdog.log` **都会**命中。
- **影响**：① 会把 `watchdog instances` 判成 `2` ⇒ 触发"M6 瞬态第二实例"的误判（真的等 60 s 复测也等不出结果，因为那个"第二实例"就是自己）；
  ② 会让"单实例保护是否生效"的判定整体失真；③ **危险**：若据此执行 `Stop-Process`，会**杀掉执行者自己**（本仓 `watchdog.ps1::Stop-Watchdog` 内部已用 `$_.ProcessId -ne $self` 规避，但一次性复核命令/新脚本没有这层保护）。
- **不要误判为**：① "出现 2 个 watchdog ⇒ 真有双实例"（**先排除自身 PID**）；② "命令行含 `watchdog` 就是守护进程"。
- **下游处置**：所有进程枚举**必须显式排除 `$PID`**，并把模式收紧为 `-File .*watchdog\.ps1` 这类"只匹配真实启动形态"的写法；
  spec/REPORT 里的"实例数"判据必须写明**"排除自身后计数"**。本轮 G0-3/A10 的 `watchdog instances` 已按此口径统计（=1）。

---

## 附：本轮（2026-09-26 Phase B）新增例外的速查

| 看到这个 | 属于 | 该怎么做 |
|---|---|---|
| 改了 `lib\cdp.ps1` 但 `monitor.log` 仍打印 `reason=tip:网络连接已经断开` | **已知例外 E-08 的"未生效窗口"** | 查 monitor 进程启动时间 vs 文件修改时间；验收要在**新进程**里调用 `Test-PageHealth` |
| `Test-PageHealth` 恒返回 `PageDown=False`（连真断连也不报） | 可能是 **E-10**（`.ps1` 丢了 BOM，中文正则静默失配） | `Get-Content $f -Encoding Byte -TotalCount 3`，必须是 `239,187,191` |
| `watchdog instances = 2` | 先按 **E-11** 排除自身 PID，再看是否为 M6 瞬态 | 等 60 s 复测；复测命令本身也要排除自身 |
| `tests\page_health.tests.ps1` 的 `consistency-tip-means-down` 变红 | **已知例外 E-09**（旧测试固化了误报） | 补"可见性"维度，**不要**删断言、**不要**放宽中文匹配串 |

---

## E-08 补记（2026-09-26 12:02:57 —— **"未生效窗口"在本机已关闭**，不改上文）

> 依维护纪律**只增不改**：E-08 正文保持原样；本补记只记录"该窗口后来是怎么关掉的"，供后续会话判断**当前**处于哪一侧。

- **关闭动作**：用户授权后，复核者按 `monitor.pid`（`32568`）**精确停**（先校验命令行含 `-File <部署根>\scripts\monitor.ps1`、且非自身 PID、且当时 `data\onetalk-write.lock` 不存在=不在写轮次中），再用**与旧实例逐字一致**的命令行
  `"powershell.exe" -ExecutionPolicy Bypass -NoProfile -File "<部署根>\scripts\monitor.ps1" -Action start` 经 `Win32_Process.Create` 拉起新实例 **pid 28132（12:02:57）**；`monitor.pid` 更新为 28132、排除自身后实例数 = 1、旧 pid 确认已死。
- **关闭后的实测对照（同一页面 DOM、只换代码）**：

| 时刻 | 判据代码来源 | 页面 DOM | `monitor.log` |
|---|---|---|---|
| `12:02:48`（重启前） | 内存（`11:04` 加载的**旧**版） | `containerH=0`、`rectH=0`、`hasTa=true`、tip=`网络连接已经断开` | `PAGE-DOWN (376x) reason=tip:网络连接已经断开`（每 ~8s 一条） |
| `12:04:37`（重启后） | 磁盘（**新**版） | **完全相同** | **无 `PAGE-DOWN`**（连续 12 条 `Scan cycle done`） |

- **据此更新使用方式**：现在若再看到 `monitor.log` 打印 `PAGE-DOWN reason=tip:网络连接已经断开`，**不能再**用"进程没换代码"解释——那说明**真断连**或**容器重新展开**，应按 E-02/R1 另取证据（`Reason=` 字段与 `containerH`）。
- **仍成立的部分**：E-08 的**机理**（`monitor.ps1:14` 只 dot-source 一次 ⇒ 改文件不等于换判据）**永远成立**。任何后续对 `lib\cdp.ps1` 的修改，**都必须**再走一次"重启 monitor 才算生效"，否则会重新落回"未生效窗口"。
- **本次重启的已知代价**：`$script:pageHealRestarts` 归零 ⇒ monitor **重新获得 `$MaxRestarts=4` 次** `chrome_ensure -ForceRestart` 自主重启额度（与 E-06 联动）。

## E-12 **从代理会话用 WMI 启动的常驻守护会被回收**：启守护只许走计划任务（本轮新发现）

- **现象**：用 `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`（或任何"从代理/脚本会话直接建进程"的方式）启动的**常驻守护**（watchdog / monitor），会在**无告警、无日志**的情况下消失。
  实测 2026-09-26：watchdog pid `7476` 由该方式于 `11:33:57` 启动、存活 **40 分钟**后死亡（`watchdog.log` 最后一行 `12:14:29`）；
  monitor pid `28132` 由该方式于 `12:02:57` 启动、存活 **12 分钟**后死亡（`monitor.log` 最后一行 `12:14:43`）。两者死后约 75 秒内**系统完全无守护**。
  对照：**不是**我启动的同类进程长期存活（watchdog `31792` 存活 11h+、monitor `32568` 存活 58min）。
- **已排除的原因**：生产代码**没有**按名称杀进程的实现（`taskkill|Stop-Process -Name` 在 `scripts\*.ps1`、`scripts\lib\*.ps1`、`tools\*\bin\*.ps1` **零命中**）；
  无 `watchdog_cooldown.json`（未进冷却）；`watchdog.log` 无 `RESTART-STORM`/`COOLDOWN`/`Watchdog error`；`AlibabaAutoReplyHealth`（`12:03` 运行、结果 `0`）与 `...Watchdog`（`LastRun=09/21`）都不是触发源；系统其余部分完好（`DSH Desktop=8`、`chrome=29`、`9222=True`）。
- **取证边界**：非管理员 ⇒ 读不到 Security 日志 `4689`（进程退出/终止者）；且该启动方式**未重定向 stdout/stderr**（连 `-WindowStyle Hidden` 都没加）⇒ 崩溃现场随控制台丢失。**故"谁杀的"未能确证**，只能确证"这个启动方式不可靠"。
- **影响**：① 会让"我明明起了守护"变成**静默无守护**，而 `*.pid` 文件仍指向死进程（`Get-Process -Id <pid>` 是唯一可靠的存活判据）；② 若据此认为"守护已恢复"，会把系统留在**无自愈**状态。
- **不要误判为**：① "守护自己崩了 ⇒ 代码有 bug"（未确证，且同样的脚本由 Task Scheduler 启动后长期稳定）；② "`watchdog.pid` 有内容 ⇒ 守护活着"（**必须** `Get-Process -Id` 复核）。
- **下游处置（硬性）**：**常驻守护只许走计划任务通道** —— `Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'`（spec §9 R-5 给的正是这条）。
  实测该通道：`12:15:56` 启动 watchdog `34364`（`ppid=2420`，Task Scheduler 服务拥有，完全脱离代理会话树），它**自己在 2 秒内**发现 monitor 缺失并拉起 monitor `17240`。
  ⇒ 恢复守护**不需要**手工起 monitor；只起 watchdog，让它在自己的职责内拉起 monitor（这样也顺带自证守护逻辑完好）。
  另：任何"停/起"操作前后都应 `Get-Process -Id (Get-Content <pid文件>)` **双向核对**，不要相信 pid 文件本身。

## E-13 **重启 DSH Desktop 会连带杀死 watchdog**：重启后必须补一次 `Start-ScheduledTask`（本轮新发现）

- **现象**：用户于 `2026-09-26 12:24:04` 重启 DSH Desktop（为让 `@xmanrui/dsh-im` 重新接管企微长连接）。
  重启前经**计划任务通道**正常启动的 watchdog `34364`（`12:15:56` 起、`ppid=2420`）在 `12:17:00` 之后**消失**：
  `watchdog.log` 末行 `12:17:00`、`Get-Process -Id 34364` = 不存在、`watchdog.pid` 仍写着 `34364`（**陈旧 pid**）。
  计划任务侧留痕：`AlibabaAutoReplyWatchdog` 的 `LastTaskResult = 3221225786`（= `0xC000013A` = **进程被 Ctrl+C / 控制台关闭终止**）。
  结果：**12:17–12:27 约 10 分钟系统完全无守护**（monitor 靠自身循环侥幸存活）。
- **实测恢复（唯一被验证有效的方式）**：
  `Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'` ⇒ `12:27:04` 起 watchdog `22660`（`ppid=2420`）、
  `watchdog.pid` 更新为 `22660`、`12:28:08` 正常写 `WATCHDOG-ACCIO`，**且日志中不再出现每 30s 的 `WECOM-HANDOVER-SKIP` 刷屏**（证明 11:32 加入的交接前置门已随新进程加载生效）。
- **机理（未确证，标注为推测）**：DSH Desktop 与当时的 watchdog 可能共享同一控制台/进程组，DSH 主进程重启时该控制台被关闭 ⇒ 组内 powershell 收到控制台关闭事件而终止。
  E-12 已排除"WMI 代理会话启动被回收"，但**没有**排除"控制台关闭终止"这条路径；两者可叠加。
- **不要误判为**：① "watchdog 代码有 bug"（同一文件由计划任务启动后长期稳定，且本次是**外部事件**终止码）；② "`watchdog.pid` 有内容 ⇒ 守护在跑"（E-12 同款陷阱，**必须** `Get-Process -Id` 复核）；③ "DSH 重启不影响业务守护"（**会**影响）。
- **下游处置（硬性）**：
  1. **任何**重启 DSH Desktop / 关闭其控制台窗口的操作之后，**必须**补做：`Start-ScheduledTask -TaskName 'AlibabaAutoReplyWatchdog'`，然后按 E-12 的双向核对确认 `watchdog.pid` 指向活进程。
  2. 长期修法（另立 spec）：把 watchdog 改为**无控制台**常驻（计划任务已带 `-WindowStyle Hidden`，但仍继承控制台）——例如改为计划任务"开机触发 + 不依赖登录会话"并显式脱离控制台，或在 DSH 重启脚本里自动补拉 watchdog。
  3. **健康检查存在覆盖空窗（规划会话 2026-09-26 12:29 复核后据实修正本条）**：
     初稿曾推测"`health_check` 读 pid 文件而非活进程"，**该推测已被推翻**——`health_check.ps1:51` 为
     `$wdOk = Test-PidAlive (Join-Path $LogDir "watchdog.pid") 'watchdog\.ps1'`，是**活进程判定**（非只读文件）。
     实际证据是**采样空窗**：`AlibabaAutoReplyHealth` 每 **15 分钟**跑一次，`12:18:06` 那次报
     `watchdog_process=OK`（当时 `34364` 是否已死，**未能取证** —— `watchdog.log` 只证明它 `12:17:00` 后没再写日志，
     不足以区分"已死"与"活着但静默"），而下一次 `12:33` 之前我已在 `12:27:04` 用计划任务把守护补起来了。
     ⇒ **结论**：守护死亡最多可被健康检查漏掉 **15 分钟**（下次 tick 前无人知晓），这是一条**真实的监控空窗**，
     不是判据缺陷。**待实测**：`Test-PidAlive` 面对"pid 文件里的进程已死"时是否确实返回 false（我未构造该用例验证）。

---

## E-14 旧出口停用后 7 处告警的**哑火窗口期**（E-04 的收尾）

> 来源：`specs\REPORT_告警推送出口改造_20260926.md`（2026-09-26 12:42–13:12 执行）。
> 与 **E-04 直接相关**：E-04 记录"恒 `SERVICE_DOWN` 是 D2 的预期后果"，本条记录**该后果的起止窗口**与收尾方式。

- **现象**：旧长连接桥（`127.0.0.1:19886`）按用户授权停用后，`lib\wecom.ps1::Send-WecomMessage` **恒返回 `SERVICE_DOWN`**，
  而 7 处调用点（`health_check.ps1:143/155`、`monitor.ps1:507/979`、`watchdog.ps1:70`、`lib\quote.ps1:74`、`lib\report_push.ps1:112`）
  **全部只经过这一个函数** ⇒ **全部告警哑火**：日志照写（`HEALTH-ALERT:` 行照出），但**没有任何一条能到达人**。
- **窗口期界定**：起 = 旧通道被停用（E-04 记录的时刻）；止 = `2026-09-26 12:43` 出口切换到 dsh-im 主动投递并实测 `SENT_OK`。
  本窗口期的**关键误导性**在于：`health.log` 在这段时间里**一直在写 `HEALTH-ALERT:` 行**，看起来"告警系统在工作"，
  实际只是写给本地看的。
- **证据（窗口期结束的硬证据，全部实测原文）**：

  | 时刻 | `health.log` 告警行结尾 | 含义 |
  |---|---|---|
  | `12:33:08` | `-> SERVICE_DOWN` | 窗口期内（出口是旧的/已停） |
  | **`13:03:06`** | **`-> SENT_OK`** | **窗口期已关闭**（同判据、同调用点、自动 tick） |

  另：`12:43:05` 前后 G0-4 正例 `[HTTP 200] {"sent":true}`；`12:44` S6 `发送结果 = SENT_OK`。
- **不要误判为**：① **"哑火期"≠"推送失败期"** —— 推送链路本身是通的，只是**没有出口**；两者症状相同（都是 `SERVICE_DOWN`）。
  ② **"`health.log` 有 `HEALTH-ALERT:` 行 ⇒ 人收到了"**（**错**：窗口期内该行恒有、而告警恒不到人）；
  唯一硬证据仍是"告警行**结尾**是否为 `SENT_OK`"（以及用户确认收到）。
  ③ **"`SERVICE_DOWN` 消失了 ⇒ 一切正常"**（`wecom_connected` 仍探已停通道 ⇒ 仍 `FAIL`，见 R1/E-04）。
- **下游处置**：① 判断告警是否真的推出去，**必须看该行结尾的返回码**，不能看该行是否存在；
  ② 若 `SERVICE_DOWN` 重新出现 ⇒ 查 `scripts\config.json` 的 `dshim_delivery_url`/`dshim_bot_id`/`dshim_target_id`
  三键是否还在（该文件被 `.gitignore` 忽略，**`git status` 判它会给假"未改动"**，见 spec §5 G0-5）；
  ③ **严禁**用"把旧通道拉起来"或"改 `wecom_connected` 判据"来消除该现象（E-04 同款红线）。

## E-15 dsh-im 投递接口用 `exactKeys` **严格校验**：多一个键即 `400 bad-request`

> 来源：同上 REPORT §1 G0-4 的三条反事实对照 + §3/§5 的改造实现（2026-09-26 实测）。

- **现象**：`POST http://127.0.0.1:43120/api/dsh-im/delivery/messages` 的请求体**必须恰好**是
  `botId` + `targetId` + `text` 三键（或再加一个 `format ∈ {plain, markdown}`）；
  **多一个键 ⇒ 400**，**少一个键 ⇒ 400** —— **不是**"忽略多余字段"的宽松语义。
- **实测原文（三条反事实对照，逐字）**：

  ```
  错 targetId      -> HTTP 404 {"error":{"code":"unknown-target",...}}
  错 botId         -> HTTP 404 {"error":{"code":"unknown-bot",...}}
  多一个 "extra":1 -> HTTP 400 {"error":{"code":"bad-request","message":"Invalid delivery request.",...}}
  正例（恰好三键）  -> HTTP 200 {"sent":true}
  ```
- **影响**：① 任何"顺手多带一个字段"的包装（如 `to`、调试字段、`timestamp`）都会**让整条告警变成 400**，
  且症状是 `SEND_ERROR: ... (400) Bad Request`，**看起来像网络/服务故障，实为契约违规**；
  ② **空白 `text`** 同样会被拒为 400 ⇒ 必须在本地先拦成 `NO_RECEIVER`，否则返回码语义退化
  （`lib\wecom.ps1` 的 `Send-WecomMessage` 已用 `[string]::IsNullOrWhiteSpace($text)` 挡住这条）；
  ③ `GET` 同路径返回 **405 + `allow: POST`** 是"接口活着且只收 POST"的**正常探活语义**，不是接口坏。
- **不要误判为**：① "接口宽松 ⇒ 可以照抄别人的请求体"（**错**，会被 400）；
  ② "400 ⇒ 服务端故障/网络问题"（先查请求体**键集**是否恰好三键）；
  ③ "`format` 可以随便加"（**只有** `plain`/`markdown` 两个合法值，且加它仍须保持其余三键不变）。
- **下游处置**：① 构造投递体时**显式**只放三个键并检查键集；② 用户改名导致 `404 unknown-target` 时，
  **只改 `scripts\config.json` 的 `dshim_target_id`**（配置问题），**不要改代码**；
  ③ 该接口官方文档明示**不含鉴权**、只应在本机使用 ⇒ 不要把它暴露到本机以外。

## E-16 `wecom_connected` 检查已**移除**（E-04 的收尾，2026-09-26）

- **动作**：按用户决策，`scripts\health_check.ps1` 中 `Add-Check "wecom_connected"` 及其 `19886` 探活整段**已删除**。
- **为什么删而不是改判据**：该检查探的旧桥 `19886` 已按 Phase L 永久退场 ⇒ 它**必然**恒 `FAIL`；把它"改成探新出口"会让一个已废弃通道的检查伪装成在看新通道。**改判据去迎合现状**是 E-04 明令禁止的；**删除**才是把这个已知例外从噪声源里摘掉。
- **不要误判为**：① "`health.log` 全绿 ⇒ 一切正常"（它只说明这 7 项判据都过；**告警链路从此没有真实流量**，见下）；② "移除 = 问题解决了"（旧桥相关的**同判据仍在 `scripts\status.ps1:78-84`**，本仓未改，属遗留项）。
- **留下的坑（重要）**：移除后 `health.log`（实测其余 7 项当前全 OK）将**长期无 FAIL 项** ⇒ **"告警能否真的到达人"不再被日常验证**。判断告警链路是否健康，只能靠人工/定期的端到端探针（另立 spec）。
- **`data\health_state.json` 的残留**：该文件会**永久保留** `wecom_connected` 键（脚本不再遍历它，故不会被清除也**不该手改**）。看到它**不是**故障。

## E-17 运行数据已外迁到 `<部署根>-runtime\`（2026-09-26）

- **动作**：`chrome-profile` / `chrome-profile-okki` / `specs` / `backups` / `logs` / `data` / `reports` 七个目录由部署根移出到 `<部署根>-runtime\`；部署根只留代码与配置。同卷 `Move-Item`，瞬时完成。
- **路径来源仍只有一个**：`scripts\config.json` 的路径键（`logs_dir`/`data_dir`/`reports_dir`/`chrome_profile`/`okki_profile`/`backups_dir`）。
- **不要误判为**：① "部署根出现 `logs\` 是正常的"（**错**：它若重新出现，说明某个路径键没改对，或某处多了硬编码）；② "搬完就可以删旧备份/旧 spec"（**错**：`specs\` 是过程记录与经验册，只移动不删除）。
- **`backups` 的新配置键**：`backups_dir`。若该键缺失，`Get-SkillPath "backups"` 会退回 `deploy_root\backups` —— 于是快照又写回代码根。
- **`.opencode`（52 MB）刻意不搬**：它是 opencode 工具的插件依赖目录（`@opencode-ai/plugin`），不是本项目数据。
- **兜底代码仍在**：`analyze_replies.ps1:14` / `dashboard.ps1:16` / `weekly_report.ps1:18` / `chrome_ensure.ps1:23` / `lib\lock.ps1:6,45` / `lib\alert_local.ps1:11` / `wecom_start.ps1:17` / `quote_remind.ps1:16` 是"**配置优先 + 硬编码兜底**"两行结构。兜底仅在配置缺失/损坏时触发，**当前不会执行**；但它们构成"同一件事两套解析规则"，建议另立 spec 清理。


## E-18 `Start-Process -RedirectStandard*` 在本机必抛，且对无限循环进程做管道重定向会死锁

- **现象**：用 `Start-Process … -RedirectStandardOutput/-RedirectStandardError` 启动**任何**进程，在本机抛
  `ArgumentException: Item has already been added. Key in dictionary: 'NO_PROXY' Key being added: 'no_proxy'`。
- **原因**：本机进程环境块含 **3 组仅大小写不同的重复键**（`NO_PROXY`/`no_proxy` 等），
  .NET 在构造重定向所需的子进程环境块时抛异常。**不是参数写错，是本机环境缺陷。**
- **证据**：① `scripts\watchdog.ps1:151-158` 的 `[FIX-ENVBLOCK 2026-09-25]` 注释（原始抛点，watchdog.log 22:27:18 起连续
  4 条 `Monitor process NOT FOUND … Restarting…`）；② `specs\结构优化与运行数据外迁_20260926.md` §6-S2-7-2
  **再次踩到同一坑**（该命令未能拉起 monitor，最终由 watchdog 自愈接管）。
- **影响**：① 命令直接失败，进程起不来；② **即使不抛也不能这么用** —— `monitor.ps1` 是无限循环，
  父进程必须**持续排空**管道，否则子进程写满管道缓冲区即**死锁**。
- **不要误判为**：① "是我参数写错了"（**错**，换任何参数都会抛）；② "重定向只是少了个日志文件"（**错**，对无限循环用它会把进程卡死）。
- **下游处置**：用 `Start-ProcessClean`（.NET 直启 + 已去重环境块）。
  **写 spec 时不要给出带 `-RedirectStandard*` 的启停命令**；已实证两次踩坑。

## E-19 双引号字符串里 `"$var:"` 会被解析成**驱动器限定引用**，导致整脚本不执行

- **现象**：PowerShell 把 `"$f:"` 里的 `$f:` 当作驱动器/作用域限定符（形如 `$env:PATH`），
  于是**整个脚本在解析期就失败**，一行都不执行。
- **证据**：2026-09-26 结构优化轮，执行者首次 S2-1/S2-2 脚本因 `"$f:"` 整脚本未执行（系统状态零变化），
  改用字符串拼接后一次成功。
- **影响**：**不是"跑到某一行报错"，而是整块不执行**。若出现在停机序列里，会造成
  "以为已经停了、其实一步都没停"——**最危险的形态**。
- **不要误判为**：① "脚本没输出 = 命令没命中条件"（**错**，先看是不是整脚本没跑）；
  ② "PowerShell 会报错所以能发现"（**错**，它可能只在你没看的那段输出里报解析错）。
- **下游处置**：变量后紧跟 `:` 时一律写成 `"$($var):"` 或字符串拼接（`"$f" + ": "`）。