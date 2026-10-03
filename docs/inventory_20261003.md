> Historical snapshot (2026-10-03). Later module removal, entrypoint repairs and production-chain gaps are documented in [current status](当前状态.md). Preserve the original evidence below; do not treat this report as a current deployment or end-to-end acceptance result.

# PowerShell inventory — responsibility & call-relation audit (2026-10-03, branch natural-reply-20261003)

Scope: tracked `.ps1` files only (`git ls-files`), 96 files. Excluded business lines (gonghai / okki / waimao / tools\accio-client) are **inventoried** but must not be rewritten. `node_modules` ignored.
Line counts are **physical lines** (`(Get-Content -LiteralPath <f>).Count`), not `Measure-Object -Line` (which drops blank lines). Read-only audit: no repository file was modified except this document.

**Revision pinned.** Every line citation below was verified against the **committed** content of branch `natural-reply-20261003`. Control check: `git show HEAD:scripts/reply_engine.ps1` is 803 lines with `Detect-Lang`@12, `New-ReplyContext`@76, `Generate-Reply`@416, `Get-DimensionGuidance`@436, `Test-AlreadyReplied`@504, `Test-DedupHit`@571, `Test-ShouldReply`@648, `Test-BannedText`@768, `Test-FinancialCommitment`@788 — identical to the numbers cited here. At the time of writing every other tracked file was unmodified in the working tree.

**Working-tree drift observed *while writing* (outside this inventory's scope — do not confuse with the audited tree).** `git status --porcelain` reports two tracked files modified (`scripts/reply_agent_prompt.md`, `scripts/reply_engine.ps1`; diff stat 85 insertions / 602 deletions) and these **untracked** files, which are *not* in `git ls-files` and therefore *not* covered by any table below: `scripts/lib/msg_norm.ps1` (309 lines), `scripts/lib/reply_gen.ps1` (451), `scripts/lib/reply_policy.ps1` (596), `scripts/reply_scenarios.md`, `tools/_gh56_hunt.ps1` (25), `tools/_my.ps1` (54), `tools/_u.ps1` (52). A parallel refactor is already in flight there: the working-tree `reply_engine.ps1` is down to 445 lines and its header states that `Detect-Lang`, `New-ReplyContext` + the three intent resolvers, `Build-MissingQuestion`, `Resolve-Template`, `Generate-Reply` and `$script:SupplierContactAsk` were removed, with policy/wording moved to `lib\reply_policy.ps1` + `lib\reply_gen.ps1` + `lib\msg_norm.ps1`; `Get-DimensionGuidance` gains new callers (`lib/reply_gen.ps1:278,279,287`, `lib/reply_policy.ps1:345`). **Consequence: the §4(a)/§4(b) verdicts for `Detect-Lang`, `Get-DimensionGuidance`, `Test-NoDimensionQuoteHint` and `$script:SupplierContactAsk` must be re-checked against that working tree before anything is deleted; the committed-tree verdicts recorded here remain the authoritative description of HEAD.**

---

## 1. Module responsibility table

`Loaded by` = dot-source sites found by scanning every tracked `.ps1` for `^\s*\.\s` (plus guarded `. (Join-Path ...)` inside `if (-not (Get-Command ...))`). Complete per-file load lists are in §5.0.

| File | Lines | Responsibility (one sentence) | Entrypoint or library? | Loaded by (. sourced) |
|---|---|---|---|---|
| .githooks/sanitize_check.ps1 | 138 | Pre-commit/pre-push secret scanner; exit 1 on a blocking finding. | Entrypoint (git hook CLI) | (none — invoked by the git hook) |
| scripts/analyze_replies.ps1 | 201 | Quality report over snapshots/monitor.log using reply_metrics + goods; pushes a WeCom summary. | Entrypoint (scheduled task AlibabaAutoReplyQuality) | (none) |
| scripts/auto_optimize.ps1 | 135 | LLM-driven **additive** rule/redline optimization of the reply corpus and prompt, with backup-first guardrails. | Entrypoint (task AlibabaAutoReplyOptimize) | (none) |
| scripts/backup.ps1 | 46 | Zips code+config into backups\ keeping the latest 20; never packages credentials.md. | Entrypoint | (none) |
| scripts/cdp.ps1 | 135 | CDP CLI bridge run as a **child process** (`-Action eval|navigate|ports`); also defines the authoritative URL-aware `Get-Page`. | Entrypoint CLI **and** shared helper | (none; launched by scripts/lib/cdp.ps1:19 via `Get-SkillPath "cdp"`) |
| scripts/chrome_ensure.ps1 | 261 | Ensures the debug Chrome instance and the OneTalk data plane are healthy; `-ForceRestart` heals a dead page. | Entrypoint (spawned child process) | (none; spawned at monitor.ps1:130, monitor.ps1:687, monitor.ps1:1702) |
| scripts/config.ps1 | 51 | Central config loader: `Get-SkillConfig` / `Get-CdpPort` / `Get-SkillPath` from config.json with fallbacks. | Library (loader) | 59 sites — full list in §5.0 |
| scripts/consolidate_prompt.ps1 | 67 | Merges duplicated auto-appended redline sections in the reply prompt to stop unbounded prompt growth. | Entrypoint | (none) |
| scripts/dashboard.ps1 | 110 | Aggregates monitor.log into reports\dashboard.html with no PII. | Entrypoint | (none) |
| scripts/gonghai/gonghai_batch.ps1 | 512 | **EXCLUDED business line** — public-pool (gonghai) batch send driver. | Entrypoint | (none) |
| scripts/gonghai/gonghai_cdp.ps1 | 449 | **EXCLUDED** — gonghai-specific CDP bridge pinned to port 9225. | Library (module) | gonghai_batch.ps1:50, gonghai_ensure.ps1:33, gonghai_loop.ps1:55, gonghai_probe.ps1:79, gonghai_recon.ps1:34, tests/gonghai.tests.ps1:13, tests/gonghai_chrome_isolation.tests.ps1:26, tools/gonghai_doctor.ps1:35, tools/gonghai_recover.ps1:25 |
| scripts/gonghai/gonghai_ensure.ps1 | 315 | **EXCLUDED** — gonghai environment/login ensure for the isolated Chrome profile. | Entrypoint | (none) |
| scripts/gonghai/gonghai_lib.ps1 | 1180 | **EXCLUDED** — gonghai domain library (icebreakers, idempotency, rate gates, list/search/send window). | Library (module) | gonghai_batch.ps1:51, gonghai_ensure.ps1:35, gonghai_loop.ps1:56, gonghai_probe.ps1:80, tests/gonghai.tests.ps1:14,103,525, tests/gonghai_chrome_isolation.tests.ps1:27, tools/gonghai_doctor.ps1:36, tools/gonghai_night_report.ps1:10, tools/gonghai_recover.ps1:26 |
| scripts/gonghai/gonghai_loop.ps1 | 273 | **EXCLUDED** — gonghai long-running loop / scheduler. | Entrypoint | (none) |
| scripts/gonghai/gonghai_probe.ps1 | 643 | **EXCLUDED** — gonghai probe/claim experiment harness. | Entrypoint | (none) |
| scripts/gonghai/gonghai_recon.ps1 | 348 | **EXCLUDED** — gonghai read-only reconnaissance. | Entrypoint | (none) |
| scripts/health_check.ps1 | 324 | Periodic health heartbeat (process/log/CDP/login/task checks) with alert dedup; always exits 0. | Entrypoint (task AlibabaAutoReplyHealth — currently **Disabled**) | (none) |
| scripts/human_style.ps1 | 43 | CLI wrapper that prints the "what the boss typed by hand" style statistics. | Entrypoint | (none) |
| scripts/lib/accio.ps1 | 390 | Accio gateway adapter (CLI wrapper) with auth negative-cache and CDP fallback. | Library | monitor.ps1:30, tests/accio.tests.ps1:6, tools/accio-client/shadow_compare.ps1:9 |
| scripts/lib/alert_dedup.ps1 | 32 | Pure function `Test-AlertDue` — 30-minute per-check alert throttling. | Library (pure) | health_check.ps1:12, tests/alert_dedup.tests.ps1:17 |
| scripts/lib/alert_local.ps1 | 107 | Local alert fallback channel (files + popup) used when the push channel is down. | Library | health_check.ps1:10, monitor.ps1:21, status.ps1:86 |
| scripts/lib/cdp.ps1 | 389 | Shared CDP wrapper: `Invoke-CdpEval`, page health verdict, page-heal throttle, daemon launcher, `Get-Page` (must stay byte-identical with scripts/cdp.ps1:36). | Library | 19 sites — §5.0 |
| scripts/lib/creds.ps1 | 41 | Sole reader of credentials.md (`Get-CredentialValue`). | Library | auto_optimize.ps1:22, chrome_ensure.ps1:12, gonghai_ensure.ps1:32, monitor.ps1:14, nudge.ps1:13, okki_ensure.ps1:98, okki_login.ps1:17 |
| scripts/lib/deadman.ps1 | 16 | External dead-man ping (healthchecks.io style); swallows all errors. | Library | health_check.ps1:14 |
| scripts/lib/doc.ps1 | 124 | Buyer document fetch + parse (CDP fetch → HTTP fallback → temp file → tools\doc-reader). | Library | monitor.ps1:29, tests/vision.tests.ps1:7 |
| scripts/lib/goods.ps1 | 194 | Buyer goods-data extraction/status from snapshots (weight/dims/images/address/supplier). | Library | analyze_replies.ps1:13, monitor.ps1:22, quote_remind.ps1:11, summarize.ps1:11, tests/goods_engine.tests.ps1:7, tests/vision.tests.ps1:8 |
| scripts/lib/heartbeat.ps1 | 62 | Daily "I am alive" heartbeat decision + send. | Library | health_check.ps1:13, tests/heartbeat.tests.ps1:9 |
| scripts/lib/human_style.ps1 | 138 | Read-only extraction/statistics of hand-typed (human) messages. | Library | scripts/human_style.ps1:23 |
| scripts/lib/llm.ps1 | 195 | Unified DeepSeek/OpenAI-compatible LLM call plus per-round budget/heartbeat. | Library | auto_optimize.ps1:24, monitor.ps1:18, nudge.ps1:17 |
| scripts/lib/lock.ps1 | 48 | App-level write lock with PID liveness and stale-lock recovery. | Library | gonghai_batch.ps1:46, gonghai_loop.ps1:54, gonghai_probe.ps1:72, monitor.ps1:19, nudge.ps1:18, okki_opportunity.ps1:22, tests/lock.tests.ps1:10, tools/gonghai_doctor.ps1:33 |
| scripts/lib/log.ps1 | 46 | Single log writer: UTF-8 append, 5MB rotation, never throws. | Library | 25 sites — §5.0 |
| scripts/lib/msg_source.ps1 | 61 | **Sole** decision point for message source (buyer/bot/human) and the human-interjection send gate. | Library (pure) | analyze_replies.ps1:12, human_style.ps1:22, monitor.ps1:28, tests/msg_source.tests.ps1:7, tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1:82 |
| scripts/lib/no_reply.ps1 | 159 | Manual-override ("no auto reply") whitelist: normalization, read, match, add/remove, summary. | Library | monitor.ps1:25, nudge.ps1:19, whitelist.ps1:27, tests/no_reply.tests.ps1:6, tests/no_reply_write.tests.ps1:14, (also lib/quote.ps1:5) |
| scripts/lib/quote.ps1 | 87 | Quote-ready buyer detection + throttled WeCom quote reminders. | Library | monitor.ps1:24, quote_remind.ps1:13 |
| scripts/lib/reply_metrics.ps1 | 92 | Read-only quality metrics: soothing-phrase repeats, dimension-guidance hits, human-interjection count, quotable buyers. | Library | analyze_replies.ps1:14 |
| scripts/lib/report_push.ps1 | 131 | Pushes a WeCom summary after a report is generated (pure parser + pusher). | Library | tests/report_push.tests.ps1:6 (self-loads config/wecom/log at lines 5-7) |
| scripts/lib/send.ps1 | 195 | Single OneTalk send implementation: open convo → identity check → native setter fill → click → verify; optional `-Page`/`-AlreadyOpen`. | Library | gonghai_batch.ps1:49, gonghai_probe.ps1:78, monitor.ps1:17, nudge.ps1:16, tests/gonghai_chrome_isolation.tests.ps1:25, tests/send_page_param.tests.ps1:42,164 |
| scripts/lib/vision.ps1 | 125 | Image/document attachment pipeline: download → data URL → multimodal parts → extract parse → sidecar. | Library | monitor.ps1:26, tests/vision.tests.ps1:6 |
| scripts/lib/wecom.ps1 | 98 | Alert push exit (now dsh-im HTTP POST); `Send-WecomMessage` + `Test-WecomService`. | Library | health_check.ps1:9, monitor.ps1:23, quote_remind.ps1:12, (also lib/report_push.ps1:6, watchdog.ps1:70) |
| scripts/log_rotate.ps1 | 71 | Log rotation: move oversized logs to archive\ and keep N archives. | Library + standalone CLI | monitor.ps1:31, tests/log_maintenance.tests.ps1:6 |
| scripts/monitor.ps1 | 1886 | The auto-reply daemon: scan round → per-conversation gate → reply generation → send-time checks → send → ledger write → retry queue. | Entrypoint (daemon; started by watchdog) | (none) |
| scripts/nudge.ps1 | 126 | Dormant-buyer scan; **auto-send removed** (spec §4.1) so it now only lists candidates and logs. | Entrypoint (invoked by weekly_report.ps1) | (none) |
| scripts/okki/make_country_names.ps1 | 66 | **EXCLUDED** — generates the ISO→Chinese country-name map for OKKI. | Entrypoint (one-shot generator) | (none) |
| scripts/okki/okki_cdp.ps1 | 133 | **EXCLUDED** — OKKI CDP bridge pinned to port 9223. | Library/CLI module | okki_ensure? (not dot-sourced; invoked as child process) |
| scripts/okki/okki_ensure.ps1 | 121 | **EXCLUDED** — OKKI environment/login ensure on 9223. | Entrypoint | (none) |
| scripts/okki/okki_lib.ps1 | 597 | **EXCLUDED** — OKKI domain library (API calls, field mapping, state, idempotency). | Library | okki_ensure.ps1:15, okki_login.ps1:18, okki_opportunity.ps1:23, okki_probe.ps1:19 |
| scripts/okki/okki_login.ps1 | 255 | **EXCLUDED** — OKKI credential form login with rate limiting; stops on 2FA. | Entrypoint | (none) |
| scripts/okki/okki_opportunity.ps1 | 362 | **EXCLUDED** — OKKI opportunity bulk creation with dry-run and idempotency layers. | Entrypoint | (none) |
| scripts/okki/okki_probe.ps1 | 177 | **EXCLUDED** — OKKI read-only API shape prober. | Entrypoint | (none) |
| scripts/quote_remind.ps1 | 38 | CLI: scan quote-ready buyers and push WeCom reminders. | Entrypoint | (none) |
| scripts/reply_engine.ps1 | 803 | Pure reply engine + the **single "should reply" exit** `Test-ShouldReply`, dedup key/hash/normalization, banned-phrase and financial-commitment checks. | Library (pure logic; shared by monitor and tests) | 17 sites — §5.0 |
| scripts/retention.ps1 | 74 | Snapshot retention: zip msgs_*.txt older than N days into monthly archives and delete sources. | Library + standalone CLI | monitor.ps1:32, tests/log_maintenance.tests.ps1:7 |
| scripts/status.ps1 | 248 | One-shot human health overview (process/CDP/logs/dedup/snapshots/reports/tasks). | Entrypoint | (none) |
| scripts/summarize.ps1 | 137 | Generates the periodic summary report from snapshots. | Entrypoint (task AlibabaAutoReplySummary) | (none) |
| scripts/sync.ps1 | 87 | Working copy ↔ skill mirror sync (Push/Pull/Status) with credential and runtime-artifact exclusions. | Entrypoint | (none) |
| scripts/waimao/waimao_cdp.ps1 | 143 | **EXCLUDED** — NetEase waimao CDP bridge on port 9224. | Library/CLI module | (none) |
| scripts/waimao/waimao_recon.ps1 | 190 | **EXCLUDED** — waimao read-only API reconnaissance. | Entrypoint | (none) |
| scripts/watchdog.ps1 | 293 | Resident guardian: monitor process, log freshness, CDP fallback, restart-storm cooldown. | Entrypoint (task AlibabaAutoReplyWatchdog — currently **Disabled**) | (none) |
| scripts/weekly_report.ps1 | 207 | Weekly business report; also triggers nudge.ps1. | Entrypoint (task AlibabaAutoReplyWeekly) | (none) |
| scripts/whitelist.ps1 | 77 | CLI for the manual-override whitelist (add/remove/list) — the only write path. | Entrypoint | (none) |
| tests/accio.tests.ps1 | 110 | Regression tests for lib/accio.ps1 (config parsing, line conversion, shadow compare, fallback safety). | Test | (self; loads lib/accio.ps1) |
| tests/alert_dedup.tests.ps1 | 51 | Table-driven tests for `Test-AlertDue` (red/green via `ALERTDEDUP_SRC`). | Test | (self; loads lib/alert_dedup.ps1 or `$src`) |
| tests/daemon_launch.tests.ps1 | 86 | Proves long-lived daemon launch writes real output and survives the launcher (locks `Start-DaemonClean`). | Test | (self) |
| tests/dedup_order.tests.ps1 | 237 | Position-independence regression for dedup keys/judging (reimplements ledger-key helpers locally). | Test | (self; loads reply_engine.ps1:29) |
| tests/dimension_guidance.tests.ps1 | 83 | Locks dimension-guidance wording across engine + prompt + playbook. | Test | (self; loads reply_engine.ps1:11) |
| tests/docs_consistency.tests.ps1 | 103 | Docs↔code consistency (config template keys, README numbers). | Test | (self) |
| tests/env_block.tests.ps1 | 66 | Regression for the duplicated-NO_PROXY environment-block launch failure. | Test | (self) |
| tests/gonghai.tests.ps1 | 838 | Gonghai module regression (EXCLUDED line) incl. stub redefinitions of shared functions at 386-404. | Test | (self) |
| tests/gonghai_chrome_isolation.tests.ps1 | 373 | Locks the gonghai independent-Chrome isolation contract (ports 9225, Get-Page body hash). | Test | (self) |
| tests/goods_engine.tests.ps1 | 90 | Fixture-driven goods extraction regression. | Test | (self) |
| tests/heartbeat.tests.ps1 | 36 | Table-driven tests for `Test-HeartbeatDue`. | Test | (self) |
| tests/lock.tests.ps1 | 75 | Stale-lock self-healing regression (F1). | Test | (self) |
| tests/log_maintenance.tests.ps1 | 110 | Log rotation + snapshot retention tests. | Test | (self) |
| tests/msg_source.tests.ps1 | 106 | Message-source / human-interjection gate truth table. | Test | (self) |
| tests/no_reply.tests.ps1 | 88 | Whitelist normalization/matching/fault tolerance (read side). | Test | (self) |
| tests/no_reply_write.tests.ps1 | 116 | Whitelist write side: format, idempotency, self-heal. | Test | (self) |
| tests/page_heal_throttle.tests.ps1 | 50 | Page-heal throttle/backoff/cap logic. | Test | (self) |
| tests/page_health.tests.ps1 | 59 | `Test-PageHealth` presence + behavior. | Test | (self) |
| tests/page_health_verdict.tests.ps1 | 62 | Table-driven `Get-PageHealthVerdict` (red/green via `PAGEHEALTH_VERDICT_SRC`). | Test | (self) |
| tests/page_select.tests.ps1 | 115 | Locks that scripts/cdp.ps1:36 and scripts/lib/cdp.ps1:43 `Get-Page` bodies are **identical** and URL-aware. | Test | (self) |
| tests/reply_engine.tests.ps1 | 283 | Reply-engine spec assertions (bans, financial commitment, dedup, epochs, state key). | Test | (self; `. $engine` = scripts\reply_engine.ps1) |
| tests/reply_gate_dupskip.tests.ps1 | 103 | Production wiring for dup-guard / wait-stack (static assertions on monitor.ps1). | Test | (self) |
| tests/report_push.tests.ps1 | 109 | Pure parser assertions for report_push. | Test | (self) |
| tests/run_tests.ps1 | 23 | Runs every `*.tests.ps1` and aggregates pass/fail. | Test runner | (none) |
| tests/send_page_param.tests.ps1 | 279 | Behavior-level regression of `Send-OneTalkMessage` `-Page`/`-AlreadyOpen` in a child process. | Test | (self) |
| tests/should_reply.tests.ps1 | 545 | `Test-ShouldReply` 5-row decision table + single-exit static checks. | Test | (self) |
| tests/should_reply_v2.tests.ps1 | 247 | New-spec acceptance for the pending-list criterion, drives real `Update-PendingSeen` via AST. | Test | (self) |
| tests/vision.tests.ps1 | 123 | Attachment pipeline pure functions + sidecar + goods merge. | Test | (self) |
| tools/accio-client/shadow_compare.ps1 | 46 | **EXCLUDED** — one-shot gateway-vs-CDP shadow comparison (read-only). | Entrypoint (tool) | (none) |
| tools/dedup_acceptance/A2_A10_replay.ps1 | 155 | Offline replay of all snapshots against `Test-ShouldReply` (A2/A3/A10). | Entrypoint (acceptance tool) | (none) |
| tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1 | 415 | Offline gate acceptance with stub scope + AST assertions on the real monitor. | Entrypoint (acceptance tool) | (none) |
| tools/dedup_acceptance/A9_red_baseline.ps1 | 153 | Red-baseline reproduction using the pre-change reply_engine copy. | Entrypoint (acceptance tool) | (none) |
| tools/dedup_acceptance/static_call_closure.ps1 | 173 | AST check that every command called by production scripts actually exists. | Entrypoint (acceptance tool) | (none) |
| tools/gonghai_doctor.ps1 | 330 | **EXCLUDED** — read-only gonghai link doctor. | Entrypoint (tool) | (none) |
| tools/gonghai_night_report.ps1 | 75 | **EXCLUDED** — read-only end-of-day gonghai ledger. | Entrypoint (tool) | (none) |
| tools/gonghai_recover.ps1 | 57 | **EXCLUDED** — targeted gonghai re-send tool. | Entrypoint (tool) | (none) |

---

## 2. Reply-chain call relation

Traced from `Start-Monitor`. Every hop below was read in the file; line numbers are exact.

### 2.1 Round level

| # | Function | File:line | Reads / writes |
|---|---|---|---|
| 1 | `Start-Monitor` | scripts/monitor.ps1:1807 | builds `$ctx` hashtable (1810-1827); infinite loop 1828; calls `Invoke-ScanRound` 1829; sleeps 5s 1846 |
| 2 | `Initialize-MonitorRuntime` | scripts/monitor.ps1:1742 (called 1808) | PID file `monitor.pid` (1744-1755), log rotation (1768), snapshot retention (1773-1774), layout migration (1776), rate-config log line (1779) |
| 3 | `Invoke-ScanRound` | scripts/monitor.ps1:1505 | takes write lock `Get-AppLock 'onetalk-write' 0` (1507); retry queue first (1516-1546); snapshot (1549); ledger (1554); page gates (1586-1605); `Update-PendingSeen` (1618); per-item loop (1623-1632) |
| 3a | `Read-RetryTable` / `Send-PendingRetry` / `Add-PendingRetry` / `Remove-PendingRetry` | monitor.ps1:751 / 836 / 795 / 822 (called 1517, 1532, 1536, 1540, 1543, 1533) | data\pending_retry.json (path built by `Get-RetryFile` monitor.ps1:749) |
| 3b | `Get-RepliedState` / `Test-RepliedStateUsable` / `Repair-RepliedState` | monitor.ps1:502 / 488 / 516 (called 1554, 1558, 1561) | `state.json` + `state.json.bak` in `$LogDir` |
| 3c | `Test-OneTalkPagePresent` / `Test-PageHealth` / `Invoke-PageHealFromGate` | monitor.ps1:105 / lib/cdp.ps1:199 / monitor.ps1:115 (called 1586, 1587, 1600) | CDP `/json` + page DOM; on heal spawns chrome_ensure.ps1 (130) |
| 3d | `Update-PendingSeen` | monitor.ps1:1482 (called 1618) | writes `$ctx.pendingSeen` (consecutive rounds in the pending list) |
| 3e | `Invoke-ConvoItem` | monitor.ps1:857 (called 1631 with `$script:scanCycleNo`) | see 2.2 |

### 2.2 `Invoke-ConvoItem` (scripts/monitor.ps1:857-1473) — one conversation

| # | Hop | File:line | Reads / writes |
|---|---|---|---|
| 4 | cold-start guard | monitor.ps1:865 | returns if cycle ≤ 1 (observe-only) |
| 5 | round-halt guard | monitor.ps1:874 | returns if `$script:roundHalt` |
| 6 | `Test-NoReplyBuyer` (manual-override whitelist) | lib/no_reply.ps1:84, called monitor.ps1:883 | reads data\manual_override.json; read-only snapshot path 888-899 |
| 7 | `Open-ConvoAndGetMessages` | monitor.ps1:193, called 888 and 946 (retry 952) | CDP eval on the OneTalk page (327); returns `{name, msgs, profile}`; writes data\msgs_<ts>.txt (894/989-991) and data\buyers\<key>.json via `Save-BuyerProfile` (monitor.ps1:580, called 893/988) |
| 8 | attachment marker parse | monitor.ps1:963-985 | parses `@@IMG:`/`@@FILE:` from the newest [BUYER] line |
| 9 | `Remove-AttachmentMarkers` | lib/vision.ps1:15, called monitor.ps1:896, 986 | strips markers for the stored snapshot / working line set |
| 10 | UI-noise line filter | monitor.ps1:992 | builds `$cdpLines` (inline regex) |
| 11 | `Get-HumanInterjectionGate` → `Test-HumanInterjection` → `Get-MessageSource` | lib/msg_source.ps1:53/27/10, called monitor.ps1:1000 | pure; SKIP branch 1001-1016 also calls `Remove-PendingRetry` (1011) and writes `$ctx.skipCooldown` (1014) |
| 12 | Accio shadow/read (flags default off) | monitor.ps1:1027-1040 | `Get-AccioReplyLines` lib/accio.ps1:315 (1028), `Invoke-AccioShadowCompare` lib/accio.ps1:350 (1030), `Test-AccioLinesOverlap` lib/accio.ps1:340 (1034) |
| 13 | `Select-LatestBuyerLine` | scripts/reply_engine.ps1:743, called monitor.ps1:1058 | pure; picks the line matching the ledger hash |
| 14 | dedup-key computation | monitor.ps1:1067-1096 | `Get-NormalizedMsgText` reply_engine.ps1:524 (1089,1092,1096), `Get-StableHash` reply_engine.ps1:473 (1090,1092), `Get-DedupKey` reply_engine.ps1:559 (1096) |
| 15 | `Test-BuyerMsgAlreadyAnswered` | scripts/reply_engine.ps1:709, called monitor.ps1:1127 | pure; `$true` forces seenRounds = 0 (1128) |
| 16 | **should-reply gate** `Test-ShouldReply` | scripts/reply_engine.ps1:648, called monitor.ps1:1135-1139 | pure; rows: 672 (LEDGER_UNUSABLE_FAILCLOSED), 677 (NOT_IN_PENDING_LIST), 681 (POST_SEND_COOLDOWN), 686 (RATE_MIN_GAP), 690 (IN_PENDING_LIST) |
| 17 | second (defence-in-depth) rate gate | monitor.ps1:1146-1152 | re-reads `$ctx.lastSendAt[$skey]`, sets Reason `RATE_MIN_GAP` locally |
| 18 | "do not reply" branches | monitor.ps1:1153-1213 | writes `$ctx.skipCooldown` (1171, 1209); dup-guard counter `$ctx.dupGuardHolds` (1182-1191); WeCom alert at 3 holds (1189) |
| 19 | new-inquiry alert | `Send-NewInquiryAlert` monitor.ps1:629, called 1223 | data\inquiry_state.json (24h throttle), `Send-WecomMessage` |
| 20 | rules load | `Get-Rules` monitor.ps1:337, called 1227 | reply_rules.json |
| 21 | round budget start | `Start-LlmRound` lib/llm.ps1:23, called monitor.ps1:1236 | in-memory stopwatch |
| 22 | image multimodal path | monitor.ps1:1241-1256 | `Get-ImageDataUrl` lib/vision.ps1:96 (1244) → `Generate-Reply-LLM` (1249) |
| 23 | document path | monitor.ps1:1258-1295 | `Get-DocumentBase64ViaCdp` lib/doc.ps1:42 (1261) → `Get-DocumentBase64ViaHttp` lib/doc.ps1:69 (1262) → `Save-DocTempFile` lib/doc.ps1:29 (1266) → `Invoke-DocReader` lib/doc.ps1:97 (1267) → `Generate-Reply-LLM` (1275 or 1281) → `Remove-DocTemp` lib/doc.ps1:37 (1289) |
| 24 | **LLM path** `Generate-Reply-LLM` | monitor.ps1:413, called 1249/1275/1281/1298 (rewrites 1362/1387) | `Get-LLMConfig` monitor.ps1:354 (414) reads llm_config.json + `Get-CredentialValue 'api_key'` (362); `Get-RulesRaw` monitor.ps1:396 (416); `Get-ReplyPrompt` monitor.ps1:377 (417) reads reply_agent_prompt.md; `Get-PromisedFields` reply_engine.ps1:58 (440); `Get-BuyerProfile` monitor.ps1:614 (452); `New-VisionContentParts` lib/vision.ps1:21 (460); `Invoke-LLM` lib/llm.ps1:66 (468) → HTTPS to DeepSeek + `Write-SkillLog` |
| 25 | image template fallback | monitor.ps1:1302-1312 | in-file hashtable, `Get-ReplyLang` reply_engine.ps1:21 (1309) |
| 26 | **rule-engine fallback** `Generate-Reply` | scripts/reply_engine.ps1:416, called monitor.ps1:1317 | → `New-ReplyContext` reply_engine.ps1:76 (417) → `Resolve-IntentEarly` 135 (418) → `Resolve-IntentInfo` 232 (420) → `Resolve-IntentData` 325 (422). Pure; reads only `reply_rules.json` content already loaded. QUICK label decided at monitor.ps1:1316 |
| 27 | vision extract (2nd LLM call) | monitor.ps1:1323-1344 | `Invoke-LLM` lib/llm.ps1:66 (1333), `Get-VisionExtract` lib/vision.ps1:35 (1334), `Save-VisionExtract` lib/vision.ps1:67 (1339) → data\vision_extract\ |
| 28 | budget gate | `Test-LlmRoundBudgetExceeded` lib/llm.ps1:50 (1347) + `Set-LlmRoundBudgetExceeded` lib/llm.ps1:56 (1348) | in-memory; returns without sending, keeps pending |
| 29 | **send-time validation 1** banned phrase | `Test-BannedText` reply_engine.ps1:768, called monitor.ps1:1356 and 1364; list from `reply_rules.json` `banned_phrases` (1355) | on hit: LLM rewrite `Generate-Reply-LLM -BanRetry` (1362) → if still hit or rule path → `$script:banSafeFallback` (monitor.ps1:83; used 1369/1373/1377) |
| 30 | **send-time validation 2** financial commitment | `Test-FinancialCommitment` reply_engine.ps1:788, called monitor.ps1:1381 and 1389 | on hit: `Generate-Reply-LLM -CommitRetry` (1387) → fallback `$script:banSafeFallback` (1394/1398/1402) |
| 31 | **send** `Send-OneTalkMessage` | lib/send.ps1:56, called monitor.ps1:1405 | → `Send-OneTalkMessageCore` lib/send.ps1:75 (69). Reads/writes: Accio send attempt 78-97; port gate 108; open convo JS 114-130; **identity verification** 135-171; native-setter fill + click + textarea-clear check 176-194. Returns `SENT_OK` / `ABORT_WRONG_CONVO (...)` / `OPEN_FAIL` |
| 32 | success path | monitor.ps1:1411-1433 | `Set-StateHash` (1413) → `Remove-PendingRetry` (1414) → `$ctx.skipCooldown` (1417) → `$ctx.lastSendAt` (1423) → quote reminder `Get-GoodsDataStatus` lib/goods.ps1:32 (1426) + `Send-QuoteReminders` lib/quote.ps1:30 (1428) |
| 33 | state write | `Set-StateHash` monitor.ps1:544 → `Test-RepliedStateUsable` 549 → `Repair-RepliedState` 552 → `Get-RepliedState` 553 → `Set-RepliedState` 571 (534) | writes `state.json` **and** `state.json.bak` (537-538) |
| 34 | failure path | monitor.ps1:1434-1463 | `ABORT_WRONG_CONVO` ⇒ `$script:roundHalt = $true` (1440) + WeCom alert (1442); fail counter 1445-1448; alert at 3 fails (1452-1456); `Add-PendingRetry` (1462) |
| 35 | round end | `Stop-LlmRound` lib/llm.ps1:35 (1468) | in-memory |
| 36 | **retry queue re-entry** | `Send-PendingRetry` monitor.ps1:836 → `Get-Snapshot` (839) → match by normalized name (846) → `Invoke-ConvoItem` (851) | re-uses the whole pipeline; `NOT_IN_LIST` returns without sending (849) |

---

## 3. Duplicate / competing implementations

Grep evidence is given as the PowerShell search plus its hit list (comments excluded from "caller" counts; method: word-boundary regex over all tracked `.ps1`, skipping lines whose trimmed form starts with `#`).

### 3.1 Question-asking limit ("max 2 questions per field")

* **A** scripts/reply_engine.ps1:106-109 computes one **global** counter `$meAskCount` (any ME line mentioning weight/dimension/address/image/supplier/share/provide/need) and short-circuits at reply_engine.ps1:344, 351, 364, 397, 400, 408.
* **B** scripts/monitor.ps1:428-446 computes **per-field** counters `$askCount.weight/dimension/address/image/supplier` and injects the text `"[追问统计] ... 已问满 2 次的字段绝不再追问,转收尾等待语气;"` into the LLM prompt (monitor.ps1:445).
* **C** scripts/reply_agent_prompt.md:66,77 restates the same rule as prompt prose ("同一字段最多追问 2 次"), and tests/dimension_guidance.tests.ps1:45 asserts that literal is present.

**Difference:** A is a single conversation-wide count and is *enforced in code*; B is per-field and only *advisory prompt text* (nothing in code blocks a third ask on the LLM path). **Authoritative at runtime:** A for the rule-engine path (reply_engine.ps1:1317); B for the LLM path (prompt only, monitor.ps1:1249/1275/1281/1298); C is documentation.
**Grep:** `meAskCount` → reply_engine.ps1:106,108,128,334,344,351,364,397,400,408 · `askCount` → monitor.ps1:428,432-436,443 + the reply_engine hits.

### 3.2 "Buyer declined / conversation is closed" detection

* **A** scripts/reply_engine.ps1:152 (Resolve-IntentEarly negative-intent list: no thanks|cancel|不用了|算了|unsubscribe|laisser tomber|… ).
* **B** scripts/nudge.ps1:100 (a shorter, partly different list: `no thanks|never mind|not interested|laisser tomber|forget it|cancel|不用了|算了|退订|unsubscribe|no problem.*thanks`).
* **C** scripts/reply_engine.ps1:166 re-uses a *third* negation snippet to avoid treating "no thanks" as a thank-you.

**Difference:** B lacks `skip it|pass|stop|don't need|no longer|drop it|abandonner` and adds `no problem.*thanks`; it is a plain regex on the newest buyer line while A is anchored on the *latest* message only. **Authoritative:** A for replies (reply_engine.ps1:416-422); B only gates the (already disabled) nudge scan — nudge.ps1:117-126 no longer sends, so B is currently decision-only.
**Grep:** `no thanks` → nudge.ps1:100, reply_engine.ps1:152, reply_engine.ps1:166, tests/reply_engine.tests.ps1:55.

### 3.3 Banned-phrase policy

* **A** scripts/reply_engine.ps1:768-782 `Test-BannedText` — the only wired detector (monitor.ps1:1356, 1364). Word list comes from `reply_rules.json` `banned_phrases` (monitor.ps1:1355) with an in-function default at reply_engine.ps1:770.
* **B** scripts/monitor.ps1:421-424 — the `-BanRetry` system-prompt rewrite **repeats the word list in prose**: `manager/boss/supervisor/经理/上级`.
* **C** scripts/reply_engine.ps1:449-469 `Test-NoDimensionQuoteHint` — a **second banned-phrase detector whose header comment (reply_engine.ps1:447-448) claims it is "供发送前检查与测试共用" (shared with a pre-send check)**. There is no such pre-send call site.
* **D** scripts/monitor.ps1:83 `$script:banSafeFallback` is the single replacement text used by both ban and financial paths (1369/1373/1377/1394/1398/1402).

**Authoritative:** A (+ the list key). **C is a documented-but-unwired competing check.**
**Grep:** `Test-BannedText` → reply_engine.ps1:768 + monitor.ps1:1356,1364 + tests/reply_engine.tests.ps1:166-180 + tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1:155 (stub). `Test-NoDimensionQuoteHint` → reply_engine.ps1:449 + tests/dimension_guidance.tests.ps1 only (no production caller).

### 3.4 Financial-commitment / liability policy

* **A** scripts/reply_engine.ps1:788-802 `Test-FinancialCommitment` — the wired send-time check (monitor.ps1:1381, 1389).
* **B** scripts/reply_engine.ps1:371-380 `$claimPat` — a **separate** claim detector used to pick a canned rule-engine reply (reply_engine.ps1:372-379).
* **C** scripts/monitor.ps1:420 — the `-CommitRetry` prompt restates the policy in Chinese prose (on us / we take responsibility / out of pocket / we'll pay / cover / reimburse …).

**Difference:** B is intent classification (buyer's message) and returns a template; A is output validation (our draft) and blocks/rewrites. They overlap on `reimburse|refund|compensat|responsib*` but are not the same rule set; C is unenforced prose.
**Authoritative:** A for anything that leaves the machine; B decides which canned text the rule engine returns.
**Grep:** `responsib` → monitor.ps1:420, reply_engine.ps1:371,792,793, tests/reply_engine.tests.ps1:184-211. `out of pocket` → monitor.ps1:420, reply_engine.ps1:798, tests/reply_engine.tests.ps1:188,206.

### 3.5 Human-request / message-source handling

* **A** scripts/lib/msg_source.ps1:10 `Get-MessageSource` — declared sole decision point (contract in the file header, lines 6-7).
* **B** scripts/lib/msg_source.ps1:27/53 `Test-HumanInterjection` / `Get-HumanInterjectionGate` — the send gate, consumed once at monitor.ps1:1000.
* **C** scripts/lib/reply_metrics.ps1:62-73 `Get-HumanInterjectionCount` — a **second, derived implementation** of "a human interjected": it counts `HUMAN-REPLIED-SKIP` lines in monitor.log instead of reading messages.
* **D** The gate only sees what monitor.ps1:992 kept: the inline UI-noise filter there is a prerequisite for B and is not part of msg_source.ps1.

**Authoritative:** A/B. **C is measurement only** (consumed by analyze_replies.ps1:140) and can drift from A/B (tail-limited to 20 000 lines, reply_metrics.ps1:62).
**Grep:** `Get-HumanInterjectionCount` → reply_metrics.ps1:62 + analyze_replies.ps1:140. `Get-HumanInterjectionGate` → msg_source.ps1:53 + monitor.ps1:1000 + tests/msg_source.tests.ps1:85-97.

### 3.6 Message / preview normalization (UI-noise stripping)

Five distinct strip-lists for the same Alibaba UI tokens (`由阿里翻译提供 / 翻译中 / 反馈 / 已读 / [未读] / Revert / 自动接待发送`):

| # | Location | Purpose |
|---|---|---|
| A | scripts/reply_engine.ps1:524-555 `Get-NormalizedMsgText` | dedup-key normalization (**authoritative**) |
| B | scripts/reply_engine.ps1:473-484 `Get-StableHash` (token list at 475) | hashes the already-normalized text; **different token list** from A (no `自动接待发送`, no `[未读]`) |
| C | scripts/monitor.ps1:992 | builds `$cdpLines` (adds `在Alibaba|平台聊天和交易|翻译提示|举报`) |
| D | scripts/monitor.ps1:241 (page-side JS `clean`) | strips tokens in the DOM before PS ever sees them |
| E | scripts/lib/goods.ps1:66, 76, 174 | independent inline replaces for goods extraction |
| F | scripts/lib/human_style.ps1:16 `Get-HumanMessageText` / scripts/lib/vision.ps1:15 `Remove-AttachmentMarkers` | marker (`@@TS/@@OT/@@IMG/@@FILE`) stripping, two more variants |

**Authoritative:** A for the dedup key (monitor.ps1:1089/1092/1096). C/D/E/F are intentionally narrower but any change to the token set must be mirrored in all six places.
**Grep:** `由阿里翻译提供` → lib/goods.ps1:66,76,174; monitor.ps1:245,992; reply_engine.ps1:475,529; tests/reply_engine.tests.ps1:134; tests/should_reply.tests.ps1:502; tools/dedup_acceptance/A2_A10_replay.ps1:47; A9_red_baseline.ps1:66.

### 3.7 Conversation-name normalization / identity key

| # | Location | Transform |
|---|---|---|
| A | scripts/reply_engine.ps1:426 `Get-StateKey` | Trim + ToLowerInvariant (**authoritative for state keys**) |
| B | scripts/lib/no_reply.ps1:13 `ConvertTo-NoReplyKey` | trim → lower → `_`→space → collapse spaces (**order frozen**, different result) |
| C | scripts/lib/accio.ps1:225 `Get-AccioNameKey` | collapse spaces + trim + lower |
| D | scripts/lib/send.ps1:164-165 | strip U+200B-‏/U+202A-‮/U+2060/U+FEFF → collapse spaces → trim → lower |
| E | scripts/monitor.ps1:635; lib/goods.ps1:25; lib/vision.ps1:61; lib/quote.ps1:16,50; nudge.ps1:88 | `Trim().ToLowerInvariant()` (+ filename sanitizing in goods/vision) |

**Authoritative:** A for `state.json` keys and `$ctx.lastSendAt`; B for the whitelist file (documented as frozen at no_reply.ps1:3-6); D only to defeat invisible characters in the send-time name check (lib/send.ps1:157-167).
**Grep:** `ToLowerInvariant` → 18 hits listed in §5 evidence; `ConvertTo-NoReplyKey` → no_reply.ps1:13,62,86,143,153 + whitelist.ps1:65,73 + tests.

### 3.8 "Quotable buyer" (weight + dims + address all present)

* scripts/monitor.ps1:1427 `if ($gst -and $gst.weight -and $gst.dims -and $gst.addr)`
* scripts/lib/quote.ps1:19-21 (same conjunction, plus whitelist skip at quote.ps1:46)
* scripts/lib/reply_metrics.ps1:85-86 (same conjunction, **no whitelist skip**)
* scripts/lib/goods.ps1:32 `Get-GoodsDataStatus` defines the field names (lower-case keys)

**Authoritative:** goods.ps1 for field semantics; the 3-field conjunction is copy-pasted 3×, and reply_metrics' copy deliberately(?) ignores the whitelist — a behavioural divergence.
**Grep:** `Get-GoodsDataStatus` → goods.ps1:32; quote.ps1:19; reply_metrics.ps1:85; monitor.ps1:1426; summarize.ps1:110; analyze_replies.ps1:173; tests/vision.tests.ps1:92,98,107; tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1:161.

### 3.9 Page-down detection & healing

* **A** scripts/monitor.ps1:105 `Test-OneTalkPagePresent` vs **B** scripts/lib/cdp.ps1:199 `Test-PageHealth` — two probes, documented as complementary (monitor.ps1:103-104) and both used per round (1586, 1587 and again 1668).
* **C** scripts/monitor.ps1:115 `Invoke-PageHealFromGate` (gate path) and **D** scripts/monitor.ps1:1691-1719 (end-of-round path) — both call `Get-PageHealAction` (lib/cdp.ps1:363) but maintain the streak differently.
* **E** scripts/monitor.ps1:682 `Invoke-CdpSelfHeal` (CDP errors → chrome_ensure **without** -ForceRestart) vs C/D (−ForceRestart).

**Competing state:** `$script:pageDownStreak` is incremented **twice per round** in the page-down case — monitor.ps1:1597 (gate) and monitor.ps1:1677 (tail) — while it is reset at 1608 and 1687.
**Authoritative:** the tail path (D) performs the actual throttle/restart; the gate path (C) can additionally return `PageDownFatal` (1601) which stops the daemon loop (monitor.ps1:1837-1844).
**Grep:** `pageDownStreak` → monitor.ps1:123,1597,1599,1606,1608,1677,1680,1681,1687,1691,1698,1708,1713,1721.

### 3.10 Duplicated DOM extraction JS (verbatim copies)

The "current conversation name" JS block is copy-pasted in three places:

* scripts/monitor.ps1:209-224 (inside `Open-ConvoAndGetMessages`)
* scripts/lib/send.ps1:135-152 (inside `Send-OneTalkMessageCore`, the send-time identity check)
* scripts/gonghai/gonghai_lib.ps1:578-585 (**EXCLUDED line** — `Assert-OneTalkConversationName`)

All three use `.content-header` + `[class*=header] [class*=name], [class*=Title], h1,h2,h3,[class*=contact-name]` and skip `.alicrm-customer-detail-card`.
**Authoritative:** monitor's copy decides *which* conversation is open; send.ps1's copy decides *whether we may send* (it is the G2 gate referenced by monitor.ps1:869-873). They must stay in sync but nothing enforces it — tests/send_page_param.tests.ps1:49 only keys off the `content-header` marker.
**Grep:** `content-header` → gonghai_lib.ps1:580,809; lib/send.ps1:138; monitor.ps1:210; tests/send_page_param.tests.ps1:49,176,185. `customer-detail-card` → gonghai_lib.ps1:583,807; lib/send.ps1:144; monitor.ps1:216,322; tools/gonghai_doctor.ps1:81.

### 3.11 Dimension-guidance wording — three copies, one of them a dead function

* **A** scripts/reply_engine.ps1:225-230 `$script:SupplierContactAsk` — **used at runtime** (reply_engine.ps1:247 and 305).
* **B** scripts/reply_engine.ps1:436-445 `Get-DimensionGuidance` — `primary` is **byte-identical** to `$script:SupplierContactAsk.en` (verified: PowerShell `-ceq` returns `True`, both length 180). **No production caller.**
* **C** scripts/reply_agent_prompt.md:67-78 (and reply_playbook.md) carries the same strings as static prose; tests/dimension_guidance.tests.ps1:26-39 asserts the prose and the function agree.

**Authoritative:** A. **B is dead code kept alive only by its test**, and its `fallbacks` (B only) exist nowhere in the runtime path.

### 3.12 Soothing / wait-tone wording

* scripts/reply_engine.ps1:110-115 `$waitTone` (the actual texts returned by the rule engine).
* scripts/lib/reply_metrics.ps1:11-14 `Get-SoothingPhrasePatterns` — a **separate substring list** (`take your time`, `no rush`, `whenever you are ready`, …) used to *measure* repeats.
* scripts/reply_agent_prompt.md:78 ("安抚式等待语全对话最多 1 次").

**Authoritative:** reply_engine for what is sent; reply_metrics only measures. The two lists can diverge silently (the metric does not know the production strings).

---

## 4. Dead-code candidates WITH EVIDENCE

> ⚠️ All verdicts below describe **HEAD**. The working tree already contains an in-flight refactor that removes some of these symbols / re-wires others — see the *Revision pinned* + *Working-tree drift* note at the top of this file before acting on any (a)/(b) item.

**Search method used throughout** (unless a different one is quoted): for each function name, a word-boundary regex `(?<![A-Za-z0-9_-])<Name>(?![A-Za-z0-9_-])` evaluated against every tracked `.ps1` line, skipping lines whose trimmed form begins with `#` and skipping the definition line itself; production = paths outside `tests/`. Cross-checks over **all** tracked files (any extension) used `Select-String -SimpleMatch` over `git ls-files`, with substring false positives resolved by hand.

### (a) PROVEN dead — no caller anywhere except the definition (and, where noted, tests)

| File:line | Symbol | Exact search & result | Notes |
|---|---|---|---|
| scripts/lib/wecom.ps1:24 | `Get-WecomReceiver` | `Select-String -SimpleMatch 'Get-WecomReceiver'` over `git ls-files` → **2 hits, both in wecom.ps1**: :24 (definition) and :86 (inside the **commented-out** legacy block wecom.ps1:77-98). Word-boundary scan → 0 callers. | Function body is live code; the only reference is a comment. |
| scripts/lib/cdp.ps1:253 | `Get-DaemonProcessId` | whole-repo `SimpleMatch` → **2 hits, both in cdp.ps1**: :252 (comment) and :253 (definition). | Legacy of FIX-DAEMONLAUNCH; `Start-DaemonClean` no longer calls it. |
| scripts/lib/accio.ps1:20 | `Get-AccioAuthState` | whole-repo → **1 hit**: accio.ps1:20. The comment at accio.ps1:19 says "供 status.ps1 巡检", but `status.ps1` contains no reference (verified by the same search). | Auth state is now read by `Restore-AccioAuthState` (accio.ps1:37) directly from disk. |
| scripts/health_check.ps1:23 | `Get-CimByCmd` | whole-repo → **1 hit**: health_check.ps1:23. | `Test-PidAlive` (health_check.ps1:26-34) inlines the same `Get-CimInstance Win32_Process` query at :31 — a duplicate of the helper, not a caller. |
| scripts/nudge.ps1:35 | `Save-NudgeState` | whole-repo → **1 hit**: nudge.ps1:35. | `$state` is read at nudge.ps1:76 and written nowhere; the auto-send path was removed at nudge.ps1:117-126 (spec §4.1). |
| scripts/nudge.ps1:42 | `Get-NudgeText-LLM` | whole-repo → **1 hit**: nudge.ps1:42. | Same removal (nudge.ps1:117-126). Its only possible consumer was the deleted send loop. |
| scripts/reply_engine.ps1:436 | `Get-DimensionGuidance` | word-boundary scan → production callers **0**; whole-repo hits = def :436, docs scripts/reply_agent_prompt.md:67, tests/dimension_guidance.tests.ps1:4,19,21. | Superseded verbatim by `$script:SupplierContactAsk` (reply_engine.ps1:225-230) — see §3.11. |
| scripts/reply_engine.ps1:449 | `Test-NoDimensionQuoteHint` | production callers **0**; hits = def :449 + tests/dimension_guidance.tests.ps1:5,20,55-62. | Its own comment (reply_engine.ps1:447-448) claims a pre-send check that does not exist. |
| scripts/gonghai/gonghai_cdp.ps1:429 | `Get-GonghaiPageSummary` | whole-repo → **1 hit**: its definition. | **EXCLUDED business line** — recorded, do not rewrite. |
| scripts/gonghai/gonghai_cdp.ps1:307 | `Invoke-GonghaiCmd` | word-boundary scan → production callers **0**; the `SimpleMatch` hits at gonghai_cdp.ps1:154,225,288,327,361 and gonghai_lib.ps1:500,509 are all **`Invoke-GonghaiCmdOn`** (different symbol) or comments — verified by reading those lines. | Superseded by `Invoke-GonghaiCmdOn` usages, **but** gonghai_cdp.ps1:288 documents `Invoke-GonghaiCmd` as the *preferred* API. Classify as dead-but-intended → treat as (c) if you must be conservative. |

### (b) Kept only for regression-test compatibility (test named)

| File:line | Symbol | Test that pins it | Evidence |
|---|---|---|---|
| scripts/reply_engine.ps1:571 | `Test-DedupHit` | tests/reply_engine.tests.ps1:265-270, 277; also asserted "no production call site" by tests/should_reply.tests.ps1:292 | The code itself documents the situation at reply_engine.ps1:567-570 ("调用点已删除, 本函数定义暂时保留(仅为既有回归测试 …)"). Grep: production hits 0; other hits are docs/specs/误发终止_单出口判据_20260927.md:106,154,288 and monitor.ps1:474 (a comment). |
| scripts/lib/cdp.ps1:291 | `Start-DaemonClean` | tests/daemon_launch.tests.ps1:23, 47 | Only non-definition, non-comment references in the repo are those two test lines. No production script calls the daemon launcher any more. |
| scripts/lib/vision.ps1:89 | `Get-VisionSidecar` | tests/vision.tests.ps1:74, 80, 84 | Word-boundary scan → production 0. (The `goods.ps1:22,33,108` `SimpleMatch` hits are `Get-VisionSidecarForGoods`, a different function.) |
| scripts/reply_engine.ps1:504 | `Test-AlreadyReplied` | tests/reply_engine.tests.ps1:227-238 | Production 0. **Caveat:** it is named in README.md:367, README_部署说明.md:269, SKILL.md:143, docs/CHANGELOG.md:178-179 as part of the documented dedup design → treat as test-pinned/documentation-pinned, not free to delete. |
| scripts/reply_engine.ps1:12 | `Detect-Lang` | tests/reply_engine.tests.ps1:137-141 | Production 0. `Get-ReplyLang` (reply_engine.ps1:21) hard-returns `'en'` and every call site uses `Get-ReplyLang`, so `Detect-Lang`'s result can never reach production. Also mentioned in docs/CHANGELOG.md:322. |

### (c) Unproven / DO NOT TOUCH

* **Everything called only from untracked runtime helpers.** `<runtime-root>\tools-local\smoke_shouldreply.ps1` (lines 4-19) and `spec_E_static.ps1` (lines 2,17,24,33,69,71,74,75) call `Test-ShouldReply` and `Update-PendingSeen`; `gh_sendtarget_probe.ps1`:5,10,43,58,59 and `spec_E_static.ps1`:88,91 call `Send-OneTalkMessage` / `Invoke-CdpEval`; `probe_pending_list.ps1`:24 calls `Invoke-CdpEval`. **These are real callers outside the tracked tree** — nothing reachable that way may be declared dead.
* `Invoke-GonghaiCmd` (gonghai_cdp.ps1:307) — see (a); documented as the preferred API, so a refactor must confirm with the gonghai line first.
* `Find-OneTalkConversation` (gonghai_lib.ps1:419) and `Assert-OneTalkConversationName` (gonghai_lib.ps1:574) — no code caller, but both are named as refactor targets in docs/specs/公海页面隔离_20260927.md:113 and :117. **Unproven.**
* Functions whose only callers are in the same file (internal helpers — **not** dead): `Get-LocalAlertDir/File/Md/LogFile`, `Add-LocalAlertMd`, `Save-LocalAlert`, `Show-LocalAlertPopup` (lib/alert_local.ps1); `Get-DocTempDir` (doc.ps1:9 → :30); `Get-LatestSnapshot`, `Get-VisionSidecarForGoods` (goods.ps1); `Get-HeartbeatStateFile` (heartbeat.ps1:32); `Get-HumanMessageText`, `Get-StyleToken` (lib/human_style.ps1); `Get-LlmRoundRemainingSec` (llm.ps1:44 → :69); `Get-SoothingPhrasePatterns` (reply_metrics.ps1:11 → :21); `Get-VisionExtractFile` (vision.ps1:58 → :69,:90); `Invoke-AccioCli`/`Get-AccioMessages`/`Get-AccioConversations` (accio.ps1); `Get-ReportSummaryText` (report_push.ps1:10 → :106); `Get-SendPageWsPort`/`Assert-SendPageNotSharedPort`/`Invoke-SendEval` (lib/send.ps1).
* `Save-AccioAuthState` (accio.ps1:26 → :183), `Restore-AccioAuthState` (accio.ps1:37 → monitor.ps1:47), `Test-AccioGateway` (accio.ps1:95 → :216,:261,:386 and tools/accio-client/shadow_compare.ps1:14) are all live.
* `Test-WecomService` (wecom.ps1:47) has exactly one caller (quote_remind.ps1:31) — single-caller, **not** dead.
* `scripts/lib/cdp.ps1:43 Get-Page` and `scripts/cdp.ps1:36 Get-Page` are **not** duplicates to delete: tests/page_select.tests.ps1:40-65 extracts both bodies and asserts they are identical, and tests/gonghai_chrome_isolation.tests.ps1:83 pins a SHA256 of the body. Any "deduplication" here breaks two tests and the documented same-name-file trap (lib/cdp.ps1:34-42).
* Functions **defined inside tests** are test doubles, not production code: tests/gonghai.tests.ps1:386-404 (`Get-AppLock`, `Release-AppLock`, `Send-OneTalkMessage`, …), tests/send_page_param.tests.ps1:47,180 (`Invoke-CdpEval`), tests/dedup_order.tests.ps1:45,52 (local ledger-key reimplementations), tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1:109-161 (stubs). A naive text search for those names will hit the stubs — do not treat them as callers.

---

## 5. Shared-library caller verification

Method: word-boundary regex per function over all tracked `.ps1`, **comments excluded**, definition line excluded, grouped by file with line numbers. Excluded business lines (gonghai / okki / waimao / tools\accio-client) are included — a library change must be checked against them too.

### 5.0 Dot-source (load) sites — complete list

* **config.ps1 (59):** analyze_replies:11, auto_optimize:14, backup:7, cdp:9, chrome_ensure:11, consolidate_prompt:10, dashboard:11, gonghai_batch:44, gonghai_ensure:29, gonghai_loop:52, gonghai_probe:70, gonghai_recon:32, health_check:7, human_style:21, lib/creds:14, lib/report_push:5, lib/vision:6, log_rotate:63, monitor:12, nudge:12, okki_cdp:14, okki_ensure:13, okki_login:15, okki_opportunity:20, okki_probe:17, quote_remind:9, retention:66, status:6, summarize:10, sync:13, waimao_cdp:16, waimao_recon:26, watchdog:18, weekly_report:12, whitelist:26, tests/daemon_launch:17, tests/env_block:7, tests/gonghai:10,102,524, tests/gonghai_chrome_isolation:21, tests/goods_engine:6, tests/lock:9, tests/page_heal_throttle:6, tests/page_health:5, tests/page_health_verdict:16, tests/page_select:18, tests/reply_gate_dupskip:23, tests/send_page_param:38,160, tests/should_reply:22, tests/should_reply_v2:15, tools/accio-client/shadow_compare:7, tools/dedup_acceptance/A2_A10_replay:20, A4_A5_A6:80, A9_red_baseline:24, tools/gonghai_doctor:31, tools/gonghai_night_report:8, tools/gonghai_recover:22 · plus guarded `lib/accio.ps1:4`.
* **lib/log.ps1 (25):** auto_optimize:23, chrome_ensure:13, gonghai_batch:45, gonghai_ensure:30, gonghai_loop:53, gonghai_probe:71, gonghai_recon:33, health_check:8, monitor:15, nudge:14, okki_ensure:14, okki_login:16, okki_opportunity:21, okki_probe:18, quote_remind:10, waimao_recon:27, watchdog:19, tests/gonghai:11, tests/gonghai_chrome_isolation:22, tests/send_page_param:39,161, tools/accio-client/shadow_compare:8, tools/gonghai_doctor:32, tools/gonghai_night_report:9, tools/gonghai_recover:23 · plus guarded `lib/accio.ps1:5`.
* **lib/cdp.ps1 (19):** chrome_ensure:14, gonghai_batch:47, gonghai_ensure:31, gonghai_probe:73, health_check:11, monitor:16, nudge:15, watchdog:20, tests/daemon_launch:18, tests/env_block:8, tests/gonghai:12, tests/gonghai_chrome_isolation:23, tests/page_heal_throttle:7, tests/page_health:6, tests/page_select:19, tests/send_page_param:40,162, tools/gonghai_doctor:34, tools/gonghai_recover:24 · plus guarded `lib/doc.ps1:7`.
* **reply_engine.ps1 (17):** gonghai_batch:48, gonghai_probe:77, monitor:13, tests/dedup_order:29, tests/dimension_guidance:11, tests/gonghai_chrome_isolation:24, tests/reply_gate_dupskip:24, tests/send_page_param:41,163, tests/should_reply:23,525, tests/should_reply_v2:16, tests/vision:9, tools/dedup_acceptance/A2_A10_replay:21, A4_A5_A6:81, A9_red_baseline:39,40 · plus `tests/reply_engine.tests.ps1:6 . $engine`.
* **gonghai_lib.ps1 (11):** gonghai_batch:51, gonghai_ensure:35, gonghai_loop:56, gonghai_probe:80, tests/gonghai:14,103,525, tests/gonghai_chrome_isolation:27, tools/gonghai_doctor:36, tools/gonghai_night_report:10, tools/gonghai_recover:26.
* **gonghai_cdp.ps1 (9):** gonghai_batch:50, gonghai_ensure:33, gonghai_loop:55, gonghai_probe:79, gonghai_recon:34, tests/gonghai:13, tests/gonghai_chrome_isolation:26, tools/gonghai_doctor:35, tools/gonghai_recover:25.
* **lib/lock.ps1 (8):** gonghai_batch:46, gonghai_loop:54, gonghai_probe:72, monitor:19, nudge:18, okki_opportunity:22, tests/lock:10, tools/gonghai_doctor:33.
* **lib/send.ps1 (7):** gonghai_batch:49, gonghai_probe:78, monitor:17, nudge:16, tests/gonghai_chrome_isolation:25, tests/send_page_param:42,164.
* **lib/creds.ps1 (7):** auto_optimize:22, chrome_ensure:12, gonghai_ensure:32, monitor:14, nudge:13, okki_ensure:98, okki_login:17.
* **lib/goods.ps1 (6):** analyze_replies:13, monitor:22, quote_remind:11, summarize:11, tests/goods_engine:7, tests/vision:8.
* **lib/msg_source.ps1 (5):** analyze_replies:12, human_style:22, monitor:28, tests/msg_source:7, tools/dedup_acceptance/A4_A5_A6_gate_offline:82.
* **lib/no_reply.ps1 (5):** monitor:25, nudge:19, whitelist:27, tests/no_reply:6, tests/no_reply_write:14 · plus `lib/quote.ps1:5`.
* **okki_lib.ps1 (4):** okki_ensure:15, okki_login:18, okki_opportunity:23, okki_probe:19.
* **lib/accio.ps1 (3):** monitor:30, tests/accio:6, tools/accio-client/shadow_compare:9 · **lib/llm.ps1 (3):** auto_optimize:24, monitor:18, nudge:17 · **lib/wecom.ps1 (3):** health_check:9, monitor:23, quote_remind:12 · **lib/alert_local.ps1 (3):** health_check:10, monitor:21, status:86.
* **2 sites:** lib/heartbeat.ps1 (health_check:13, tests/heartbeat:9) · lib/doc.ps1 (monitor:29, tests/vision:7) · lib/quote.ps1 (monitor:24, quote_remind:13) · lib/vision.ps1 (monitor:26, tests/vision:6) · log_rotate.ps1 (monitor:31, tests/log_maintenance:6) · retention.ps1 (monitor:32, tests/log_maintenance:7).
* **1 site:** lib/alert_dedup.ps1 (health_check:12) · lib/deadman.ps1 (health_check:14) · lib/human_style.ps1 (human_style:23) · lib/reply_metrics.ps1 (analyze_replies:14) · lib/report_push.ps1 (tests/report_push:6) · lib/report_push.ps1:6 loads lib/wecom.ps1, :7 loads lib/log.ps1 · lib/quote.ps1:5 loads lib/no_reply.ps1 · scripts/watchdog.ps1:70 (dynamic) loads lib/wecom.ps1.
* **Dynamic:** `tests/reply_engine.tests.ps1:6 . $engine` → scripts\reply_engine.ps1; `tests/alert_dedup.tests.ps1:17 . $src` → lib/alert_dedup.ps1; `tests/page_health_verdict.tests.ps1:20 . $src` → lib/cdp.ps1; `tests/gonghai.tests.ps1:415 . ([scriptblock]::Create($fnLock))` → in-test function bodies.

### 5.1 scripts/lib/alert_dedup.ps1
* `Test-AlertDue` @18 → health_check.ps1:197,268 | tests/alert_dedup.tests.ps1:23,24,45

### 5.2 scripts/lib/alert_local.ps1
* `Get-LocalAlertDir` @8 → alert_local.ps1:15,16 · `Get-LocalAlertFile` @15 → alert_local.ps1:36,48,98 · `Get-LocalAlertMd` @16 → alert_local.ps1:25 · `Get-LocalAlertLogFile` @18 → alert_local.ps1:79 · `Add-LocalAlertMd` @23 → alert_local.ps1:77,104 · `Get-LocalAlert` @33 → alert_local.ps1:74,94 | status.ps1:87 · `Save-LocalAlert` @46 → alert_local.ps1:76,102 · `Show-LocalAlertPopup` @58 → alert_local.ps1:78
* `Write-LocalAlert` @71 → health_check.ps1:220 | **monitor.ps1:556,1004,1568,1713**
* `Clear-LocalAlert` @92 → health_check.ps1:230 | **monitor.ps1:1022,1566,1574,1685**

### 5.3 scripts/lib/accio.ps1
* `Get-AccioAuthState` @20 → **(none)** · `Save-AccioAuthState` @26 → accio.ps1:183 · `Restore-AccioAuthState` @37 → monitor.ps1:47
* `Set-AccioLogFile` @54 → monitor.ps1:45 | tests/accio.tests.ps1:79 | **tools/accio-client/shadow_compare.ps1:12** · `Write-AccioLog` @55 → accio.ps1:89,138,155,172,185,188,194,211,318,381,386 | **lib/send.ps1:88,91,94,99**
* `Get-AccioNodeExe` @57 → accio.ps1:139 · `Get-AccioFlags` @65 → monitor.ps1:44 | tests/accio.tests.ps1:52,56 · `Get-AccioGatewayInfo` @77 → accio.ps1:104 | tests/accio.tests.ps1:71,75 · `Test-AccioGateway` @95 → accio.ps1:216,261,386 | **tools/accio-client/shadow_compare.ps1:14** · `ConvertTo-AccioCliArg` @120 → accio.ps1:140 | tests/accio.tests.ps1:62,63,64
* `Invoke-AccioCli` @137 → accio.ps1:217,265,388 · `Get-AccioConversations` @202 → accio.ps1:232 | tests/accio.tests.ps1:100 · `Get-AccioNameKey` @225 → accio.ps1:236,317 | **lib/send.ps1:82** · `Get-AccioConversationMap` @231 → accio.ps1:316 | **lib/send.ps1:81** · `Get-AccioMessages` @260 → accio.ps1:320
* `Get-AccioNormText` @271 → accio.ps1:343,345,357,358,373 | tests/accio.tests.ps1:45,46 · `ConvertFrom-AccioTs` @280 → accio.ps1:367,368 | tests/accio.tests.ps1:47,48,49 · `ConvertTo-ReplyLines` @295 → accio.ps1:322 | tests/accio.tests.ps1:35,40,41
* `Get-AccioReplyLines` @315 → **monitor.ps1:1028** | **tools/accio-client/shadow_compare.ps1:35** · `Test-AccioLineMatch` @326 → accio.ps1:345,361,376 · `Test-AccioLinesOverlap` @340 → **monitor.ps1:1034** | tests/accio.tests.ps1:93,95,96 · `Invoke-AccioShadowCompare` @350 → **monitor.ps1:1030** | tests/accio.tests.ps1:82,86 | tools/accio-client/shadow_compare.ps1:37 · `Send-AccioMessage` @385 → **lib/send.ps1:78,86**

### 5.4 scripts/lib/cdp.ps1
* `Invoke-CdpEval` @3 → chrome_ensure.ps1:36,248 | health_check.ps1:120 | lib/doc.ps1:60 | lib/send.ps1:53 | **monitor.ps1:98,184,327,698,955,1655** | tests/gonghai_chrome_isolation:107,237,247 | tests/page_select:89,90 | tests/reply_gate_dupskip:57 | tests/send_page_param:47,180 | tests/should_reply_v2:239 | tools/dedup_acceptance/A4_A5_A6:143
* `Test-CdpReady` @23 → chrome_ensure.ps1:127,128,157,174,177 | **gonghai_ensure.ps1:148,191,194** | **gonghai_probe.ps1:285** | health_check.ps1:113 | nudge.ps1:115 | watchdog.ps1:238 | tests/gonghai_chrome_isolation:110
* `Get-Page` @43 → **scripts/cdp.ps1:36,85,112** | lib/cdp.ps1:15 | monitor.ps1:107 | tests/gonghai_chrome_isolation:86,108 | tests/page_select:44,61,62,68,74,79 | tools/dedup_acceptance/A4_A5_A6:146
* `Get-CleanEnvSnapshot` @70 → lib/cdp.ps1:103 | tests/env_block:15 · `Start-ProcessClean` @95 → health_check.ps1:284 | lib/doc.ps1:7,109 | watchdog.ps1:163 | tests/env_block:28,45,57 · `Get-PageHealthVerdict` @180 → **gonghai_cdp.ps1:422,425** | lib/cdp.ps1:243 | tests/gonghai_chrome_isolation:224 | tests/page_health_verdict:27,28,50
* `Test-PageHealth` @199 → chrome_ensure.ps1:53 | health_check.ps1:123 | **monitor.ps1:1587,1668** | tests/gonghai_chrome_isolation:227 | tests/page_health:12,16,18 · `Get-DaemonProcessId` @253 → **(none)** · `Start-DaemonClean` @291 → tests/daemon_launch:23,47 (test only)
* `Get-PageHealAction` @363 → **monitor.ps1:123,1698** | tests/page_heal_throttle:13,17,22,27,28,30,31,34,37,40,41,46

### 5.5 scripts/lib/creds.ps1
* `Get-CredentialValue` @19 → chrome_ensure.ps1:223,224 | **gonghai_ensure.ps1:259,260** | lib/llm.ps1:90 | **monitor.ps1:362** | **okki_ensure.ps1:99** | **okki_login.ps1:141,142**

### 5.6 scripts/lib/deadman.ps1
* `Send-DeadmanPing` @7 → health_check.ps1:311

### 5.7 scripts/lib/doc.ps1
* `Get-DocTempDir` @9 → doc.ps1:30 · `Get-SafeDocName` @16 → doc.ps1:31 | tests/vision:113,114 · `Save-DocTempFile` @29 → **monitor.ps1:1266** · `Remove-DocTemp` @37 → **monitor.ps1:1289** · `Get-DocumentBase64ViaCdp` @42 → **monitor.ps1:1261** · `Get-DocumentBase64ViaHttp` @69 → **monitor.ps1:1262** · `Invoke-DocReader` @97 → **monitor.ps1:1267**

### 5.8 scripts/lib/goods.ps1
* `Get-LatestSnapshot` @7 → goods.ps1:34,58,109 · `Get-VisionSidecarForGoods` @22 → goods.ps1:33,108
* `Get-GoodsDataStatus` @32 → analyze_replies.ps1:173 | lib/quote.ps1:19 | lib/reply_metrics.ps1:85 | **monitor.ps1:1426** | summarize.ps1:110 | tests/vision:92,98,107 | tools/dedup_acceptance/A4_A5_A6:161
* `Get-GoodsName` @57 → lib/quote.ps1:21 | summarize.ps1:112 | tests/goods_engine:48 · `Get-GoodsDetails` @107 → lib/quote.ps1:52 | tests/goods_engine:34,58,68,75,79 | tests/vision:101,109

### 5.9 scripts/lib/heartbeat.ps1
* `Test-HeartbeatDue` @18 → health_check.ps1:248 | tests/heartbeat:13,14,30 · `Get-HeartbeatStateFile` @32 → heartbeat.ps1:35,48 · `Get-HeartbeatLastSent` @34 → health_check.ps1:248 · `Save-HeartbeatSent` @42 → health_check.ps1:251 · `Send-DailyHeartbeat` @53 → health_check.ps1:249

### 5.10 scripts/lib/human_style.ps1
* `Get-HumanMessageText` @16 → human_style.ps1:44 · `Get-HumanMessages` @30 → human_style.ps1 (CLI):33 | human_style.ps1 (lib):64 · `Get-StyleToken` @54 → lib/human_style.ps1:95 · `Get-HumanStyleStats` @63 → scripts/human_style.ps1:42

### 5.11 scripts/lib/llm.ps1
* `Start-LlmRound` @23 → **monitor.ps1:1236** | tools/dedup_acceptance/A4_A5_A6:150 · `Stop-LlmRound` @35 → **monitor.ps1:1350,1468** | A4_A5_A6:151 · `Get-LlmRoundElapsedSec` @38 → llm.ps1:62 | **monitor.ps1:1255,1294,1406** | A4_A5_A6:152 · `Get-LlmRoundRemainingSec` @44 → llm.ps1:69
* `Test-LlmRoundBudgetExceeded` @50 → **monitor.ps1:1347** | A4_A5_A6:157 · `Set-LlmRoundBudgetExceeded` @56 → llm.ps1:71 | **monitor.ps1:1348**
* `Invoke-LLM` @66 → auto_optimize.ps1:58 | **monitor.ps1:468,1333** | nudge.ps1:48

### 5.12 scripts/lib/lock.ps1
* `Get-AppLock` @4 → **gonghai_lib.ps1:1108** | **gonghai_loop.ps1:111** | **gonghai_probe.ps1:333** | **monitor.ps1:1507,1693** | **okki_opportunity.ps1:184** | tests/gonghai:233,335,359,361,384,386,704 | tests/lock:39,53,62 | tests/should_reply:463 | tools/gonghai_doctor:285
* `Release-AppLock` @43 → **gonghai_batch.ps1:279** | **gonghai_lib.ps1:1145,1177** | **gonghai_loop.ps1:267** | **gonghai_probe.ps1:339,492** | **monitor.ps1:697,1692,1697,1841,1845** | **okki_opportunity.ps1:361** | tests/gonghai:234,299,352,362,387,705 | tests/lock:44,57,67 | tools/gonghai_doctor:329

### 5.13 scripts/lib/log.ps1
* `Write-SkillLog` @13 → auto_optimize:19 | chrome_ensure:28 | gonghai_ensure:45 | gonghai_lib:371 | health_check:21 | lib/accio:5,55 | lib/alert_local:80 | lib/llm:61,92,114,135,146,158,172,173,178,189,190,191 | lib/quote:47,78,80 | lib/report_push:108,123,129 | monitor:85 | nudge:26 | okki_lib:62 | quote_remind:18 | watchdog:123 | tools/accio-client/shadow_compare:42

### 5.14 scripts/lib/msg_source.ps1
* `Get-MessageSource` @10 → lib/human_style.ps1:41 | lib/msg_source.ps1:31 | lib/reply_metrics.ps1:24,52 | tests/msg_source:15,20,21,23,25,27,28,30,31
* `Test-HumanInterjection` @27 → lib/msg_source.ps1:54 | tests/msg_source:16,35,41,46,51,53,58,63,68,73,78
* `Get-HumanInterjectionGate` @53 → **monitor.ps1:1000** | tests/msg_source:85,86,90,93,97

### 5.15 scripts/lib/no_reply.ps1
* `ConvertTo-NoReplyKey` @13 → no_reply.ps1:62,86,143,153 | whitelist.ps1:65,73 | tests/no_reply:34,43 · `Get-NoReplyList` @27 → no_reply.ps1:88,134,145,155 | tests/no_reply:77 | tests/no_reply_write:41,76,79,83,97
* `Test-NoReplyBuyer` @84 → lib/quote.ps1:15,46 | **monitor.ps1:883** | nudge.ps1:83 | tests/no_reply:32-79 (many) | tests/no_reply_write:38,67,68,105 | tests/should_reply:460 | tools/dedup_acceptance/A4_A5_A6:130
* `Save-NoReplyList` @115 → no_reply.ps1:116,147,157 | tests/no_reply_write:96 · `Get-NoReplySummary` @133 → whitelist.ps1:58 | tests/no_reply_write:63,72,106 · `Add-NoReplyBuyer` @142 → whitelist.ps1:62 | tests/no_reply_write:37-104 · `Remove-NoReplyBuyer` @152 → whitelist.ps1:70 | tests/no_reply_write:66,69,70,91

### 5.16 scripts/lib/quote.ps1
* `Get-QuoteReadyBuyers` @6 → quote.ps1:42 | quote_remind.ps1:20 · `Send-QuoteReminders` @30 → **monitor.ps1:1428** | quote_remind.ps1:36

### 5.17 scripts/lib/reply_metrics.ps1
* `Get-SoothingPhrasePatterns` @11 → reply_metrics.ps1:21 · `Get-SoothingPhraseRepeatStats` @18 → analyze_replies.ps1:105 · `Test-DimensionGuidanceHit` @41 → analyze_replies.ps1:107 · `Get-HumanInterjectionCount` @62 → analyze_replies.ps1:140 · `Get-QuotableBuyerCount` @76 → analyze_replies.ps1:142

### 5.18 scripts/lib/report_push.ps1
* `Get-ReportSummaryText` @10 → report_push.ps1:106 | tests/report_push:32,43,66,83,93,94,95 · `Send-ReportWecomSummary` @89 → analyze_replies.ps1:182 | weekly_report.ps1:172

### 5.19 scripts/lib/send.ps1
* `Get-SendPageWsPort` @19 → **gonghai_probe.ps1:586** | send.ps1:39 | tests/gonghai_chrome_isolation:256-264 | tests/send_page_param:219-222
* `Assert-SendPageNotSharedPort` @32 → send.ps1:108 | tests/gonghai_chrome_isolation:240,244,252 | tests/send_page_param:274 · `Invoke-SendEval` @48 → send.ps1:129,154,192 | tests/gonghai_chrome_isolation:238,241,246
* `Send-OneTalkMessage` @56 → **gonghai_batch.ps1:49 (dot-source) / gonghai_lib.ps1:1166 (call)** | **monitor.ps1:1405** | tests/gonghai:236,311,329,391,558 | tests/gonghai_chrome_isolation:232,271 | tests/send_page_param:61-226 | tools/dedup_acceptance/A4_A5_A6:52,66,70,144
* `Send-OneTalkMessageCore` @75 → send.ps1:69 | tests/gonghai_chrome_isolation:233,234,236

### 5.20 scripts/lib/vision.ps1
* `ConvertTo-DataUrl` @8 → vision.ps1:122 | tests/vision:27,29 · `Remove-AttachmentMarkers` @15 → **monitor.ps1:896,986** | tests/vision:34,35,36 | tools/dedup_acceptance/A4_A5_A6:141 · `New-VisionContentParts` @21 → **monitor.ps1:460,1328** | tests/vision:39,43,48
* `Get-VisionExtract` @35 → **monitor.ps1:1334** | tests/vision:52,57,59,60,61,63,65 · `Get-VisionExtractFile` @58 → vision.ps1:69,90 · `Save-VisionExtract` @67 → **monitor.ps1:1339** | tests/vision:71,79,85,97,106 · `Get-VisionSidecar` @89 → tests/vision:74,80,84 (**test only**) · `Get-ImageDataUrl` @96 → **monitor.ps1:1244**

### 5.21 scripts/lib/wecom.ps1
* `Get-WecomReceiver` @24 → **(none)** · `Get-DshImConfig` @32 → wecom.ps1:48,62 · `Test-WecomService` @47 → quote_remind.ps1:31
* `Send-WecomMessage` @61 → health_check.ps1:215,227 | lib/heartbeat.ps1:61 | lib/quote.ps1:74 | lib/report_push.ps1:112 | **monitor.ps1:119,646,1189,1442,1455** | watchdog.ps1:72 | tools/dedup_acceptance/A4_A5_A6:124

---

## 6. Per-file production vs test line counts

Counting convention: `Total` = physical lines (`(Get-Content -LiteralPath f).Count`); `Code` = Total − blank − comment-only lines (a line counts as a comment only when its **trimmed** form starts with `#`, so inline trailing comments are counted as code). `Measure-Object -Line` was **not** used — it silently drops blank lines and under-reports (e.g. monitor.ps1 as 1835 instead of 1886).

### 6.1 Production tree (scripts\ + tools\)

| File | Total | Code |
|---|---|---|
| scripts/analyze_replies.ps1 | 201 | 173 |
| scripts/auto_optimize.ps1 | 135 | 107 |
| scripts/backup.ps1 | 46 | 38 |
| scripts/cdp.ps1 | 135 | 94 |
| scripts/chrome_ensure.ps1 | 261 | 183 |
| scripts/config.ps1 | 51 | 43 |
| scripts/consolidate_prompt.ps1 | 67 | 52 |
| scripts/dashboard.ps1 | 110 | 100 |
| scripts/health_check.ps1 | 324 | 261 |
| scripts/human_style.ps1 | 43 | 24 |
| scripts/log_rotate.ps1 | 71 | 60 |
| scripts/monitor.ps1 | **1886** | **1504** |
| scripts/nudge.ps1 | 126 | 91 |
| scripts/quote_remind.ps1 | 38 | 34 |
| scripts/reply_engine.ps1 | 803 | 562 |
| scripts/retention.ps1 | 74 | 63 |
| scripts/status.ps1 | 248 | 204 |
| scripts/summarize.ps1 | 137 | 116 |
| scripts/sync.ps1 | 87 | 74 |
| scripts/watchdog.ps1 | 293 | 221 |
| scripts/weekly_report.ps1 | 207 | 166 |
| scripts/whitelist.ps1 | 77 | 51 |
| scripts/gonghai/gonghai_batch.ps1 (excluded) | 512 | 333 |
| scripts/gonghai/gonghai_cdp.ps1 (excluded) | 449 | 321 |
| scripts/gonghai/gonghai_ensure.ps1 (excluded) | 315 | 234 |
| scripts/gonghai/gonghai_lib.ps1 (excluded) | 1180 | 893 |
| scripts/gonghai/gonghai_loop.ps1 (excluded) | 273 | 168 |
| scripts/gonghai/gonghai_probe.ps1 (excluded) | 643 | 416 |
| scripts/gonghai/gonghai_recon.ps1 (excluded) | 348 | 311 |
| scripts/okki/make_country_names.ps1 (excluded) | 66 | 48 |
| scripts/okki/okki_cdp.ps1 (excluded) | 133 | 111 |
| scripts/okki/okki_ensure.ps1 (excluded) | 121 | 98 |
| scripts/okki/okki_lib.ps1 (excluded) | 597 | 492 |
| scripts/okki/okki_login.ps1 (excluded) | 255 | 203 |
| scripts/okki/okki_opportunity.ps1 (excluded) | 362 | 295 |
| scripts/okki/okki_probe.ps1 (excluded) | 177 | 158 |
| scripts/waimao/waimao_cdp.ps1 (excluded) | 143 | 118 |
| scripts/waimao/waimao_recon.ps1 (excluded) | 190 | 160 |
| scripts/lib/accio.ps1 | 390 | 338 |
| scripts/lib/alert_dedup.ps1 | 32 | 13 |
| scripts/lib/alert_local.ps1 | 107 | 81 |
| scripts/lib/cdp.ps1 | 389 | 224 |
| scripts/lib/creds.ps1 | 41 | 25 |
| scripts/lib/deadman.ps1 | 16 | 11 |
| scripts/lib/doc.ps1 | 124 | 103 |
| scripts/lib/goods.ps1 | 194 | 155 |
| scripts/lib/heartbeat.ps1 | 62 | 40 |
| scripts/lib/human_style.ps1 | 138 | 111 |
| scripts/lib/llm.ps1 | 195 | 158 |
| scripts/lib/lock.ps1 | 48 | 37 |
| scripts/lib/log.ps1 | 46 | 28 |
| scripts/lib/msg_source.ps1 | 61 | 37 |
| scripts/lib/no_reply.ps1 | 159 | 112 |
| scripts/lib/quote.ps1 | 87 | 77 |
| scripts/lib/reply_metrics.ps1 | 92 | 70 |
| scripts/lib/report_push.ps1 | 131 | 120 |
| scripts/lib/send.ps1 | 195 | 128 |
| scripts/lib/vision.ps1 | 125 | 106 |
| scripts/lib/wecom.ps1 | 98 | 42 |
| tools/accio-client/shadow_compare.ps1 (excluded) | 46 | 39 |
| tools/dedup_acceptance/A2_A10_replay.ps1 | 155 | 123 |
| tools/dedup_acceptance/A4_A5_A6_gate_offline.ps1 | 415 | 289 |
| tools/dedup_acceptance/A9_red_baseline.ps1 | 153 | 122 |
| tools/dedup_acceptance/static_call_closure.ps1 | 173 | 112 |
| tools/gonghai_doctor.ps1 (excluded) | 330 | 270 |
| tools/gonghai_night_report.ps1 (excluded) | 75 | 55 |
| tools/gonghai_recover.ps1 (excluded) | 57 | 40 |

**Production subtotals:** `scripts\` = 59 files, **13 914** total / **10 596** code · `tools\` = 8 files, **1 404** total / **1 050** code · **production (scripts\ + tools\) = 67 files, 15 318 total / 11 646 code**.
`.githooks\sanitize_check.ps1` is reported separately (not under scripts\/tools\): 138 total / 114 code.

### 6.2 Test tree (tests\)

| File | Total | Code |
|---|---|---|
| tests/accio.tests.ps1 | 110 | 86 |
| tests/alert_dedup.tests.ps1 | 51 | 34 |
| tests/daemon_launch.tests.ps1 | 86 | 56 |
| tests/dedup_order.tests.ps1 | 237 | 124 |
| tests/dimension_guidance.tests.ps1 | 83 | 59 |
| tests/docs_consistency.tests.ps1 | 103 | 73 |
| tests/env_block.tests.ps1 | 66 | 46 |
| tests/gonghai.tests.ps1 | 838 | 587 |
| tests/gonghai_chrome_isolation.tests.ps1 | 373 | 261 |
| tests/goods_engine.tests.ps1 | 90 | 63 |
| tests/heartbeat.tests.ps1 | 36 | 29 |
| tests/lock.tests.ps1 | 75 | 55 |
| tests/log_maintenance.tests.ps1 | 110 | 89 |
| tests/msg_source.tests.ps1 | 106 | 67 |
| tests/no_reply.tests.ps1 | 88 | 71 |
| tests/no_reply_write.tests.ps1 | 116 | 83 |
| tests/page_heal_throttle.tests.ps1 | 50 | 31 |
| tests/page_health.tests.ps1 | 59 | 42 |
| tests/page_health_verdict.tests.ps1 | 62 | 42 |
| tests/page_select.tests.ps1 | 115 | 73 |
| tests/reply_engine.tests.ps1 | 283 | 207 |
| tests/reply_gate_dupskip.tests.ps1 | 103 | 63 |
| tests/report_push.tests.ps1 | 109 | 91 |
| tests/run_tests.ps1 | 23 | 19 |
| tests/send_page_param.tests.ps1 | 279 | 196 |
| tests/should_reply.tests.ps1 | 545 | 368 |
| tests/should_reply_v2.tests.ps1 | 247 | 170 |
| tests/vision.tests.ps1 | 123 | 99 |

**Test subtotal:** 28 files, **4 566** total / **3 184** code.

### 6.3 Ratios and the headline number

* Production vs test **code** lines: 11 646 vs 3 184 → test/code ratio ≈ **0.27**.
* Excluding the excluded business lines, the "business rewrite" surface (scripts\ root + scripts\lib + tools\dedup_acceptance) is ≈ **8 200** code lines, of which `scripts\monitor.ps1` alone is **1 504** (18 %) and `scripts\reply_engine.ps1` is **562** (7 %).
* `scripts\monitor.ps1`: **1 886 physical lines**, 1 504 code lines, 331 comment-only lines, 51 blank lines, **38 functions**. Largest function: `Invoke-ConvoItem` scripts/monitor.ps1:857-1473 = **617 lines** (33 % of the file); second largest `Invoke-ScanRound` scripts/monitor.ps1:1505-1739 = 235 lines.
