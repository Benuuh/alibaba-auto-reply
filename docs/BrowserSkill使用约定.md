# BrowserSkill 使用约定（2026-09-26 起）

> 适用范围：**项目的部署根目录**（下称 `<部署根>`）这套 24/7 阿里卖家自动回复系统的**调试 profile**
> （`chrome-profile`，`--remote-debugging-port=9222`）。
> 权威依据：`specs\BrowserSkill接入_20260926.md` §6-S5；风险分析见同 spec §1.1 / §1.6 / §1.7。
> **本约定是"约定级"缓解，不是机制级**（见铁律 7）。

## 铁律

1. **agent 操作前必须先拿写锁**：`Get-AppLock 'onetalk-write' <timeout>`；
   拿不到就**放弃本次操作，绝不强上**。用完必须 `Release-AppLock 'onetalk-write'`。
2. **只读优先**：默认只做「读 DOM / 取选择器 / 截图」。**发送消息、点提交/保存/下单/删除一律不做**
   （确需写操作须另立 spec）。
3. **用完关窗口**：agent 会话结束必须关闭其窗口/标签页，然后**确认 `Get-Page` 仍指向 OneTalk**。
4. **发现 monitor 异常就停手**：若 `logs\monitor.log` 出现
   `CMD ERROR: no onetalk page found`、`wrong-tab`、`PAGE-DOWN`，
   立即停止使用 BrowserSkill，并检查标签页是否把 OneTalk 挤掉。
5. **不要用 BrowserSkill 替代 24/7 路径**：生产回复仍走自研 CDP（`lib\cdp.ps1` + `scripts\cdp.ps1`）；
   BrowserSkill 是**人的工具**，不得让 `monitor` 依赖它。
6. **`FORCE-RESTART` 之后必须重新初始化**：`monitor.log` 出现 `FORCE-RESTART`
   （`chrome_ensure.ps1` 会按 profile 杀掉该 profile 下**所有** chrome 进程、且只回到 `about:blank`）
   ⇒ agent 的窗口会全部消失、扩展会话需重建。
   **在重新确认 `Get-Page` 指向 OneTalk 之前，不得继续 agent 操作。**
7. **写锁只是约定级保护**：BrowserSkill 扩展**不认识** `onetalk-write` 锁，
   写锁**约束不了扩展本身**；唯一机制级保护是「只读」（铁律 2）。

## 与本项目既有资产的关系（避免另造轮子）

| 现有能力 | 位置 | 与 BrowserSkill 的关系 |
|---|---|---|
| CDP 求值 | `lib\cdp.ps1::Invoke-CdpEval` / `scripts\cdp.ps1 -Action eval -ScriptB64` | BrowserSkill **不替代**它；24/7 路径继续走自研 CDP |
| 数据面判据 | `lib\cdp.ps1::Test-PageHealth` | **不得**改其判据语义（`wrong-tab` 仍算 Down） |
| 写锁 | `lib\lock.ps1::Get-AppLock('onetalk-write')` | **必须**用它避免 agent 与 monitor 同时操作页面 |
| 页面重载/自愈 | `monitor.ps1::Invoke-PageReload`、`chrome_ensure.ps1` | agent 侧**不得**触发它们（否则自伤循环） |

## 页面选择安全前提（FIX-PAGESELECT 2026-09-26）

`Get-Page` 已是 **URL 感知**：优先返回 URL 匹配 `onetalk\.alibaba\.com` 的 `type=page`；
找不到则**明确返回 `$null`**（调用方会输出 `CMD ERROR: no onetalk page found (url guard)` 并走自愈链）。

- 两个**同名文件**里各有一份 `Get-Page`，**必须逐字一致**：
  `scripts\lib\cdp.ps1`（消费者 dot-source 的那份）与 `scripts\cdp.ps1`（子进程桥那份）。
  修改任何一份都要同步另一份，并跑 `tests\page_select.tests.ps1`（该测试含"两处一致"断言）。
- `navigate` 动作**例外**：它是"把页面开到 OneTalk"的**引导动作**，
  在 `about:blank` 阶段**必须**允许退化到"任意可用 page"，否则重启后永远回不到 OneTalk
  （见 `REPORT_插件接入_20260926.md` 偏差 D-03）。

## 使用前自检（30 秒）

```powershell
cd <部署根>
# 1) 数据面是否可用（业务能力判据，比 status-tip 更可信：看最近是否有 REPLIED ... SENT_OK）
Get-Content logs\monitor.log -Tail 120 | Select-String 'REPLIED|PAGE-DOWN|CMD ERROR|wrong-tab' | Select-Object -Last 5
# 2) Get-Page 是否指向 OneTalk
powershell -ExecutionPolicy Bypass -NoProfile -Command ". .\scripts\config.ps1; . .\scripts\lib\cdp.ps1; (Get-Page).url"
# 3) 写锁是否空闲
Get-ChildItem data\onetalk-write.lock -EA SilentlyContinue
```

⚠️ **判据陷阱（2026-09-26 实测）**：页面上的 `status-tip`「网络连接已经断开」**可能长期陈旧不刷新**，
而业务其实正常（实测 09:54–09:55 有 4 条 `REPLIED ... SENT_OK`，而 `Test-PageHealth.PageDown` 仍为 `True`）。
⇒ 判断"能不能干活"时，**`REPLIED ... SENT_OK` 的记录比 `status-tip` 更可信**。

## 已知未决事项（2026-09-26）

- `bsk` CLI **未安装**：官方安装脚本走 `raw.githubusercontent.com`，在本机被网络阻断
  （npm 源可达）；npm 上的 `browser-skill` 是**第三方同名包**（非 Tencent 官方，且指示以
  "Load unpacked" 侧载扩展 —— **本项目禁止**），**不得**用它代替。详见
  `specs\REPORT_插件接入_20260926.md` §3 与偏差 D-16。
- 扩展**未安装**（属用户动作 U2）。
- 数据面 `status-tip` 判据失真问题（同上）需另立 spec 处理。
