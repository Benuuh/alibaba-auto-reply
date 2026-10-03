> Historical snapshot (2026-10-03). Later module removal, entrypoint repairs and production-chain gaps are documented in [current status](当前状态.md). Preserve the original evidence below; do not treat this report as a current deployment or end-to-end acceptance result.

# Test-suite side-effect audit — alibaba-auto-reply

**Date:** 2026-10-03 · **Repo:** <repo-root> (git) · **Shell:** Windows PowerShell 5.1
**Runtime data root (LIVE):** <runtime-root> · **Code root:** <repo-root>
**Scope:** every tests\*.tests.ps1 + tests\run_tests.ps1 (28 .ps1 files, 4 566 lines), read-only analysis.
**Nothing from the suite was executed; no monitor / watchdog / chrome_ensure / health_check / scheduled task was run.**

Live roots come from scripts\config.json and are resolved by scripts\config.ps1 — data_dir = <runtime-root>\data
(config.json:6), logs_dir (config.json:5), reports_dir (config.json:4), backups_dir (config.json:7), chrome_profile (config.json:9).
Get-SkillPath (config.ps1:30-50) has **no environment-variable override**: the only input is scripts\config.json (config.ps1:8).
That fact drives §4(c).

Classification legend: **NONE** · **TEMP-ONLY** (writes only under %TEMP% or repo fixtures) · **READS-LIVE-RUNTIME** ·
**WRITES-LIVE-RUNTIME** · **NETWORK** (TCP/HTTP incl. localhost) · **STARTS-PROCESS** · **TOUCHES-BROWSER-CDP**.

---

## 1. Inventory

| Test file | Lines | What it asserts | Side effects |
|---|---|---|---|
| tests\accio.tests.ps1 | 110 | Accio adapter pure logic: ConvertTo-ReplyLines order/identity/timestamp, Get-AccioNormText, ConvertFrom-AccioTs (ms vs s vs date), flag parsing, Windows argv quoting, gateway-config parsing against a temp USERPROFILE, shadow-compare log lines, line-overlap detection, gateway-unreachable fallback | **TEMP-ONLY** + **STARTS-PROCESS** + **NETWORK** + **WRITES-LIVE-RUNTIME (conditional)** — accio.tests.ps1:100 calls the real Get-AccioConversations -Force after restoring the real USERPROFILE (:99) → lib\accio.ps1:216 (TCP probe), lib\accio.ps1:217 → :150 (node.exe cli.js), lib\accio.ps1:183 → :26-33 (writes …-runtime\logs\accio_auth_state.json on AUTH-REQUIRED). Temp dir :23-24, removed :104; $env:USERPROFILE save/restore :25/:99/:103 (process-local — see §2) |
| tests\alert_dedup.tests.ps1 | 51 | Table-driven Test-AlertDue (30-min window ± 1-min tolerance, empty/garbage lastAlert) | **NONE** — dot-sources lib\alert_dedup.ps1 (:16), which is pure (alert_dedup.ps1:18-31). Optional RED mode via $env:ALERTDEDUP_SRC (:15) |
| tests\daemon_launch.tests.ps1 | 86 | Start-DaemonClean really writes a long-lived child's startup output to a file, returns promptly, the child survives the launcher, later output still lands in the file, cleanup kills the real target process | **STARTS-PROCESS** + **TEMP-ONLY** — daemon_launch.tests.ps1:47 → lib\cdp.ps1:291/:325 (Start-Process of a generated .bat); reaper :71-73 (Get-CimInstance + Stop-Process, matched to the test's own child-script name :69-72); every path under %TEMP% (:25-27, :43, :60, :79) incl. the .launch.bat/.pid artifacts (:81-82) |
| tests\dedup_order.tests.ps1 | 237 | Order-independence of the "should reply" verdict (2 orders × 3 ledger keys), retired evidence anchors, legacy 13-digit ledger keys, Select-LatestBuyerLine | **NONE** — pure logic over reply_engine.ps1 (:29); header :11 "No CDP, no Chrome, no page, no file writes" |
| tests\dimension_guidance.tests.ps1 | 83 | Dimension-guidance wording identical in code, prompt and playbook; Test-NoDimensionQuoteHint truth table | **NONE** — reads repo files reply_agent_prompt.md (:22-23), reply_playbook.md (:65-68); dot-sources reply_engine.ps1 (:11) |
| tests\docs_consistency.tests.ps1 | 103 | README_部署说明.md health-check list (count + names) matches Add-Check calls in health_check.ps1 (:22-50); config.json.example is valid JSON and a superset of the live scripts\config.json keys (:53-71); the two rate-limit keys are present and = 5 in **both** files (:76-86); no hard-coded "N files M assertions" in README / README_部署说明 / KNOWN_EXCEPTIONS / SKILL (:91-99) | **NONE** — read-only repo reads (Select-String, ConvertFrom-Json). It reads the live in-repo scripts\config.json (:54) but never writes it. Header :5: "纯读文件、不改任何东西" |
| tests\env_block.tests.ps1 | 66 | Case-insensitive duplicate env keys are collapsed; Start-ProcessClean starts a child with and without stdio redirection and the child gets a non-empty deduplicated env block | **STARTS-PROCESS** + **TEMP-ONLY** — :28, :45, :57 → lib\cdp.ps1:95/:130 (Process.Start); redirect targets under %TEMP% (:43-44), deleted (:50, :62) |
| tests\gonghai.tests.ps1 | 838 | 36 cases: icebreaker text/compliance, idempotency-key shape, rate/cap clamping (tamper config → verify clamp), sent-ledger atomic write + re-send blocking, rate gate, module-file BOM, static prohibitions, lock-window AST checks, behavioural send-window with stubs, daily-cap gate, pending queue enqueue/dequeue/idempotency, ~20 static source anchors (GH-24 … GH-63) | **WRITES-LIVE-RUNTIME** + **TEMP-ONLY** + repo-config writes — see §3 R1/R2. Live ledger :139/:148/:170 (restore :185-186), live rate file :195/:203 (restore :210-211), live pending queue :628/:635/:643/:650/:658-659 (restore :662-663), live disabled marker :612/:615 (removed :620), repo scripts\config.json rewritten twice (:97, :521; restored :121, :544). No CDP/network: the send window runs on stubs (:386-404) |
| tests\gonghai_chrome_isolation.tests.ps1 | 373 | Independent Chrome on 9225: config keys/ports/profiles pairwise distinct (:117-139), Get-Page body SHA256 baseline + both copies identical (:81-102), URL-marker scheme removed, -Page port gate in lib\send.ps1, ensure-scripts kill only their own profile | **NONE** — reads source text plus config.json / config.json.example (:117-118, :360-361); page list is stubbed (:189-210). Header :12 "不联网、不开页、不发送" |
| tests\goods_engine.tests.ps1 | 90 | Goods extraction from repo fixtures: qty vs dimensions, box weight, address truncation, goods-name sanitising | **NONE** — repo fixtures only ($fixtures = tests\fixtures, :8; snapshot dir passed explicitly :34, :48, :58, :68, :75, :79) |
| tests\heartbeat.tests.ps1 | 36 | Table-driven Test-HeartbeatDue (hour boundary, same-day dedup, cross-day, bad lastSent) | **NONE** — calls only the pure Test-HeartbeatDue (lib\heartbeat.ps1:18-30). Save-HeartbeatSent (heartbeat.ps1:42-50) would write live data\heartbeat_state.json, but the test never calls it |
| tests\lock.tests.ps1 | 75 | Get-AppLock / Release-AppLock: acquire when free, stale-lock self-heal with a dead PID, refuse while the holder is alive, no residue | **WRITES-LIVE-RUNTIME** — $lockDir = Get-SkillPath "data" (:31) → live D:\…-runtime\data\pytest-lock.lock: pre-clean :36, create :39 (lib\lock.ps1:14), read :42, release/delete :44, dead-holder write :51, live-holder write :61, release :67, residue assert :70. Deliberately never touches the production onetalk-write lock (:33-35) |
| tests\log_maintenance.tests.ps1 | 110 | Invoke-LogRotation (over/under limit, missing file, -DryRun, archive cap) and Invoke-SnapshotRetention (dry-run, monthly zip, untouched dirs, second-run no-op) | **TEMP-ONLY** — both modules are dot-source-guarded (log_rotate.ps1:60-61, retention.ps1:59-60) so loading them has no live effect; all calls pass temp dirs (:44, :53, :57, :63, :90, :96, :102); temp dirs :24-27, :72-73, removed :69, :105 |
| tests\msg_source.tests.ps1 | 106 | Get-MessageSource / Test-HumanInterjection / Get-HumanInterjectionGate case table | **NONE** — pure lib\msg_source.ps1 (:7) |
| tests\no_reply.tests.ps1 | 88 | Manual-takeover whitelist read side: normalization, exact matching (no prefix/substring), fault tolerance, cache refresh | **TEMP-ONLY** — temp whitelist :24-27, removed :82; never touches live data\manual_override.json |
| tests\no_reply_write.tests.ps1 | 116 | Whitelist write side: byte-identical to Node JSON.stringify(list,null,2)+LF, idempotency, corruption recovery, 50-entry round-trip, CJK | **TEMP-ONLY** + **STARTS-PROCESS** — temp whitelist :31-33, removed :110; spawns node -e (:53-55) whose only output is a temp file (:54-55) |
| tests\page_health.tests.ps1 | 59 | Test-PageHealth returns the 6-key shape, latency < 30 s, and agrees with an independent CDP probe (stale tip vs visible tip) | **TOUCHES-BROWSER-CDP** + **NETWORK** + **STARTS-PROCESS** — calls Test-PageHealth (:16), which spawns powershell -File scripts\cdp.ps1 -Action eval (lib\cdp.ps1:199-219, spawn :219) and reads http://127.0.0.1:9222/json (lib\cdp.ps1:55); the test's own probe spawns cdp.ps1 again (:42) |
| tests\page_health_verdict.tests.ps1 | 62 | Table-driven Get-PageHealthVerdict (10 cases incl. stale-tip vs real disconnect, wrong tab, spinner) | **NONE** — pure function (lib\cdp.ps1:180-197); optional RED mode via $env:PAGEHEALTH_VERDICT_SRC (:18) |
| tests\page_heal_throttle.tests.ps1 | 50 | Get-PageHealAction: quiet window, backoff ladder, hard cap, reload carries no quiet period | **NONE** — pure function (lib\cdp.ps1:363-389) |
| tests\page_select.tests.ps1 | 115 | Get-Page URL guard exists in both same-named files and the bodies are byte-identical (:41-65), **live** page selection equals the URL-matched page (:68-86), Invoke-CdpEval no longer returns the guard error (:89-92), selection logic skips non-OneTalk pages (:105-111) | **TOUCHES-BROWSER-CDP** + **NETWORK** + **STARTS-PROCESS** — live /json/list read (:30 → lib\cdp.ps1:55), live Get-Page (:68), live JS eval in the OneTalk page (:89 → lib\cdp.ps1:19 → cdp.ps1 WebSocket) |
| tests\reply_engine.tests.ps1 | 283 | Generate-Reply branch table (45 cases), banned manager wording, financial-commitment detector, epoch parsing, Test-AlreadyReplied, dedup-key stability | **NONE** — pure engine (:6), in-memory rules object (:29-47) |
| tests\reply_gate_dupskip.tests.ps1 | 103 | Test-BuyerMsgAlreadyAnswered truth table + AST purity check (:51-59), monitor.ps1 wiring/anchors (:64-97) | **NONE** — reads monitor.ps1 as text (:65); never dot-sources monitor (:18) |
| tests\report_push.tests.ps1 | 109 | Report-summary parser on 2 repo fixtures + degraded/empty/missing cases + output-line format | **TEMP-ONLY** — fixtures :27-29, generated files under %TEMP% (:55-56, :65, :82, :92) removed :102. Send-ReportWecomSummary (which would write live logs/data, lib\report_push.ps1:90-129) is never called |
| tests\run_tests.ps1 | 23 | Runner (not a test): executes every *.tests.ps1 and prints TEST-SUMMARY/FAILED | **STARTS-PROCESS** (one child PowerShell per test file, :11); performs **no** state isolation — see §2 |
| tests\send_page_param.tests.ps1 | 279 | Send-OneTalkMessage return strings and call order on 5 branches (CDP stubbed in the child), -AlreadyOpen semantics, -Page shared-port refusal (ABORT_WRONG_PAGE), Get-SendPageWsPort | **STARTS-PROCESS** + **TEMP-ONLY** — two generated child scripts in %TEMP% (:114-115, :233-234) executed with powershell -File (:119, :238) and deleted (:121, :240); the child overrides Invoke-CdpEval / Invoke-GonghaiEvalOnPage (:47-57, :171-188), so no CDP socket is used |
| tests\should_reply.tests.ps1 | 545 | Test-ShouldReply 5-row table with verbatim Reasons, old→new semantic migration (8 cases), anchor independence, RequiredSeenRounds clamp, config-key assertions, A8 single-exit/single-send-site static checks, static call-closure gate (:385-403), incident-snapshot readability (:471-517), GH-56 ledger-key parse | **READS-LIVE-RUNTIME** + **STARTS-PROCESS** — reads live data_dir incident snapshots and <runtime>\specs\incident_evidence (:472-490, :496-508; read-only; NOTE-skip when absent :474/:492); spawns tools\dedup_acceptance\static_call_closure.ps1 (:387, :397 — that script only parses files, static_call_closure.ps1:15/:173) and writes a probe file under %TEMP% (:395-396, deleted :399) |
| tests\should_reply_v2.tests.ps1 | 247 | Spec acceptance of the new judge: 5-row table, transient misread, consecutive-2-round confirmation driven by the **real** Update-PendingSeen extracted via AST + Invoke-Expression (:106-187), config defaults | **NONE** — reads monitor.ps1 / reply_engine.ps1 as text (:106-108, :208-214); no file writes |
| tests\vision.tests.ps1 | 123 | Data-URL builder, marker stripping/hash stability, vision content parts, extract parsing/whitelist/caps, sidecar read-merge-write, goods+vision merge, doc-name sanitising | **TEMP-ONLY** — temp dir :68-69 removed :116; every sidecar/goods call receives the temp dir explicitly (:71, :79, :85, :91-110) |

Totals: 28 files, 4 566 lines (4 543 lines of tests + the 23-line runner).

---

## 2. How the runner works (tests\run_tests.ps1)

| Aspect | Implementation | Citation |
|---|---|---|
| Discovery | Get-ChildItem -Path $here -Filter "*.tests.ps1" \| Sort-Object Name — non-recursive, top level of tests\ only, culture sort by name (tests\fixtures\* and tools\* are never picked up). Execution order is alphabetical: accio, alert_dedup, daemon_launch, dedup_order, dimension_guidance, docs_consistency, env_block, **gonghai (8th)**, gonghai_chrome_isolation, goods_engine, heartbeat, **lock (12th)**, log_maintenance, msg_source, no_reply, no_reply_write, page_heal_throttle, page_health, page_health_verdict, page_select, reply_engine, reply_gate_dupskip, report_push, send_page_param, should_reply, should_reply_v2, vision | run_tests.ps1:9 |
| State isolation | **None on the filesystem.** Each test file runs in a fresh child process (powershell -ExecutionPolicy Bypass -NoProfile -File $t.FullName), so dot-sourced globals, functions and $env: mutations cannot leak between files (e.g. accio.tests.ps1:70-74 changes USERPROFILE only inside its own process). The child inherits the parent's working directory and **the live scripts\config.json** — i.e. the live runtime root. No temp root, no env override, no sandbox, no lock | run_tests.ps1:11; config.ps1:8 |
| Failure handling | $LASTEXITCODE is captured per file (:12), the file's output is echoed indented (:13), the file name is appended to $failFiles (:14). The run always continues with the next file. Summary TEST-SUMMARY: files=N failedFiles=M (:18); on any failure it prints FAILED: <names> and exit 1 (:19-21); otherwise ALL TEST FILES PASS (:23) | run_tests.ps1:12-23 |
| Guard against live-state writes | **There is none.** No allow/deny list, no backup/restore, no config snapshot, no "runtime root is off-limits" check, no Set-Location, no environment pinning. The only protection is each test's own try/finally cleanup — which does not run if the process is killed | run_tests.ps1:9-15 (whole body) |

**Verdict — is a full run_tests.ps1 run SAFE while the production monitor tasks are disabled but the real runtime data root must stay intact?**

**Not "safe" in the strict sense — it is *conditionally* safe.** A full run does touch live state; it will not destroy the runtime
root, but it can leave it modified:

* It **mutates the live runtime data root** in three places: data\gonghai\{sent_index.json, gonghai_rate.json, pending.json, disabled}
  (gonghai.tests.ps1:148 / :203 / :615 / :635 …), data\pytest-lock.lock (lock.tests.ps1:36-67) and — only if the Accio desktop app is
  running — logs\accio_auth_state.json (accio.tests.ps1:100 → lib\accio.ps1:183). Each is restored or deleted by the test's own
  finally block, so a clean, uninterrupted run leaves the runtime root equivalent to its pre-run state.
* It **rewrites the live deployment config** <repo-root>\scripts\config.json twice (gonghai.tests.ps1:97 and :521, restored
  at :121 and :544). That file is **git-ignored** (.gitignore:68 → /scripts/config.json), so there is **no VCS recovery** if the run is
  interrupted between tamper and restore.
* It **talks to the live production browser**: page_health.tests.ps1 (:16, :42) and page_select.tests.ps1 (:30, :68, :89) evaluate
  read-only JS in the OneTalk page on port 9222 (verified open during this audit). No clicks, no sends, no navigation.
* It **reads** live runtime data (should_reply.tests.ps1:472-508) and starts short-lived helper processes
  (env_block :28/:45/:57, daemon_launch :47, send_page_param :119/:238, should_reply :387/:397, no_reply_write :53).
* Nothing in the suite writes logs\monitor.log, reports\, backups\ or any Chrome profile: Write-GonghaiLog — which appends to the
  live logs\monitor.log (gonghai_lib.ps1:371) — is stubbed at gonghai.tests.ps1:404 before the extracted window functions run, and the
  only other caller path (Test-GonghaiAlreadySent, gonghai_lib.ps1:189) fires only on a notsent ledger match, which the test's unique
  fake keys cannot produce.

⇒ Safe-run preconditions: (1) back up scripts\config.json; (2) do **not** Ctrl-C or kill the run (that is exactly what skips the
finally restores); (3) run when no *Ready* scheduled task fires (see the recipe); (4) accept a read-only visit to the live 9222
browser, or exclude the two CDP tests. If any of those cannot be guaranteed, use the copied-tree recipe in §4(c).

---

## 3. Risk list

### R1 — tests\gonghai.tests.ps1: live deployment config rewritten (highest risk)
* **What:** $cfgFile = Join-Path $scripts "config.json" (:90) is overwritten with a tampered variant (gonghai_min_interval_ms=90000,
  gonghai_run_cap=99, gonghai_jitter_pct=90) at **tests\gonghai.tests.ps1:97** and restored at **:121**. A second tamper
  (gonghai_daily_cap:1) is written at **tests\gonghai.tests.ps1:521** and restored at **:544**.
* **Why it can hurt:** this is the live file every production script reads (config.ps1:8). An interrupted run leaves the live config
  altered (e.g. a 90 s gonghai interval where 0 is intended) and there is **no git copy** to fall back on (.gitignore:68). Restore
  rides on finally only; the tampered window is also re-entered by a [powershell]::Create() runspace (:100-110 — in-process, not a
  separate process) that re-dot-sources the tampered config.
* **Minimal safe way:** copy scripts\config.json to %TEMP% before the run and compare/restore afterwards (§4(a)). Never Ctrl-C.
  There is **no env var or parameter** to redirect it: $scripts is derived from the test's own location (:9) and Get-SkillPath reads
  only $PSScriptRoot\config.json (config.ps1:8). Full isolation requires the copied-tree recipe (§4(c)).

### R2 — tests\gonghai.tests.ps1: live runtime state files rewritten
* **What (all under <runtime-root>\data\, resolved by Get-SkillPath "data" → gonghai_lib.ps1:88-91, which also creates
  data\gonghai if missing at :90):**
  * gonghai\sent_index.json — path resolved :139, backup :141, written through the **real** Set-GonghaiSentRecord (:148, again :170 →
    gonghai_lib.ps1:218-252, write at :251), restored/deleted :185-186.
  * gonghai\gonghai_rate.json — path :195, backup :197, written through the real Set-GonghaiRate (:203 → gonghai_lib.ps1:263-272,
    write at :269), restored/deleted :210-211.
  * gonghai\pending.json — path :628, backup :630, written through the real Add-GonghaiPending / Remove-GonghaiPending (:635, :643,
    :650, :658-659 → gonghai_lib.ps1:1006-1045 write at :1044; :1047-1063 write at :1062), restored/deleted :662-663.
  * gonghai\disabled — created by the test at :615 (path :612), removed at :620 (only if the test created it).
* **Why it can hurt:** an interrupted run leaves test keys (TESTKEY…, PENDKEY…) in the live idempotency ledger / pending queue, or
  deletes a state file that existed. A *clean* run is byte-neutral because the restore re-writes the exact original bytes. A
  concurrently running production job would also read the tampered files — irrelevant while the tasks are disabled.
* **Minimal safe way:** let the file finish (its finally restores all four artifacts), then run the post-run checks in §4(a). The stub
  lock name is never created (asserted at :488-489). For true isolation run the copied tree (§4(c)) — the state functions hard-wire
  Get-SkillPath "data", so there is no per-call redirection.

### R3 — tests\lock.tests.ps1: live lock file created and deleted
* **What:** $lockDir = Get-SkillPath "data" (:31) → live D:\…-runtime\data; $testLockFile = …\pytest-lock.lock (:34). Deleted before
  use (:36), created by Get-AppLock (:39 → lib\lock.ps1:14), read (:42), deleted by Release-AppLock (:44); a fake dead-holder lock is
  written (:51) and a live-holder lock (:61), each released (:57, :67); residue asserted absent (:70).
* **Why it can hurt:** it writes inside the live data directory. The lock **name** is unique (never onetalk-write, comment :33-35) and
  file plus content are removed on the normal path, so the blast radius is one transient file in a directory that must already exist.
  An interrupted run can leave pytest-lock.lock behind (harmless: no production code reads that name).
* **Minimal safe way:** already safe enough to run as-is; to be strict, run it after R1/R2 and check
  Test-Path …\data\pytest-lock.lock afterwards. Full isolation is only possible through the copied tree (§4(c)) because the data dir is
  resolved once at :31 from the live config.

### R4 — tests\accio.tests.ps1: conditional process start, gateway network call, live log write
* **What:** at :99 the real USERPROFILE is restored, then :100 runs Get-AccioConversations -Force -Pages 1. With -Force the negative
  cache is skipped (lib\accio.ps1:208), so Test-AccioGateway checks for a running Accio process (lib\accio.ps1:102-103) and TCP-connects
  to its gateway (lib\accio.ps1:108-110); on success Invoke-AccioCli starts node.exe … cli.js conversations (lib\accio.ps1:217 →
  [System.Diagnostics.Process]::Start at :150). If the gateway answers AUTH-REQUIRED, Save-AccioAuthState writes **live**
  …-runtime\logs\accio_auth_state.json (lib\accio.ps1:183 → :26-33, Set-Content at :33).
* **Why it can hurt:** a live gateway interaction and a live log-directory write. The test's own comment ("回退安全", :98) only asserts a
  null/empty result.
* **Minimal safe way:** make sure the Accio desktop app is **not running** for the duration of the run — Get-Process Accio must return
  nothing; then Test-AccioGateway short-circuits at lib\accio.ps1:103 and no process, socket or file write happens. (The test restores
  USERPROFILE at :99 by design, so pointing it at a temp profile does not protect this call.) No env var or parameter can skip only this
  case.

### R5 — tests\should_reply.tests.ps1: reads live runtime data (read-only) and spawns a helper
* **What:** :472 reads (Get-SkillConfig).data_dir → live …-runtime\data; :488-508 opens incident snapshots msgs_20260927_1142xx.txt from
  there (or from <runtime>\specs\incident_evidence, :489) and hashes the first line; :387/:397 spawn
  tools\dedup_acceptance\static_call_closure.ps1 (parses .ps1 files only — static_call_closure.ps1:15, :173 — and exits 1 on undefined
  commands); :395-396 writes a probe .ps1 under %TEMP% and deletes it (:399).
* **Why it can hurt:** nothing is written; it is the only test that requires the live data root to exist for its last section
  (it NOTE-skips otherwise, :474, :492). PII stays in-process (a SHA of the buyer line is compared, :498).
* **Minimal safe way:** already safe. For zero live reads, point the copied tree's data_dir at an empty temp dir (§4(c)) — the section
  then NOTE-skips instead of failing.

### R6 — tests\page_health.tests.ps1 and tests\page_select.tests.ps1: live browser on 9222
* **What:** Test-PageHealth (:16) → powershell -File scripts\cdp.ps1 -Action eval (lib\cdp.ps1:199-219, spawn :219) plus an independent
  probe at :42; Get-Page (:68) → Invoke-RestMethod http://127.0.0.1:9222/json (lib\cdp.ps1:55); Invoke-CdpEval (:89) → another cdp.ps1
  child process (lib\cdp.ps1:19) that opens a WebSocket into the OneTalk page. The injected JS is read-only (location.href,
  querySelectorAll counts, offsetHeight — lib\cdp.ps1:200-216).
* **Why it can hurt:** the tests drive the **production** browser instance. A hung CDP round-trip makes them slow/red (lib\cdp.ps1:27-31
  has 3 s timeouts; cdp.ps1 has 15 s / 20 s WS timeouts), and page_select.tests.ps1:85 (first-page-is-onetalk-today) is documented as
  brittle right after a Chrome restart (:98-101). No click, no send, no reload.
* **Minimal safe way:** run them only while the live Chrome is in a known state (OneTalk tab present, not being restarted). If a green
  suite is not required, skip these two files when port 9222 is closed (Test-NetConnection 127.0.0.1 -Port 9222) — the red is
  environmental, not a regression. No parameter or env var can redirect the port: the child cdp.ps1 reads cdp_port from the live config
  (lib\cdp.ps1:28).

### R7 — process-starting tests that are safe by construction (no isolation needed)
* tests\env_block.tests.ps1:28, :45, :57 — powershell.exe -Command "exit 0" / one-line writers; all output files in %TEMP% (:43-44,
  :50, :55, :62). **Safe.**
* tests\daemon_launch.tests.ps1:47 — starts a generated child under %TEMP% and later kills only PIDs whose command line contains that
  exact temp script name (:69-73, re-checked :76-78). **Safe** (it cannot match monitor/Chrome; the child script is deleted at :79).
* tests\send_page_param.tests.ps1:119, :238 — two child processes running generated scripts under %TEMP% with stubbed CDP (:47-57,
  :171-188), files deleted at :121, :240. **Safe** (no network, no browser, no live file).
* tests\no_reply_write.tests.ps1:53-55 — node -e writes a comparison file in %TEMP%, deleted at :110. **Safe.**
* tests\should_reply.tests.ps1:387, :397 — read-only static-analysis helper (§R5). **Safe.**

### R8 — everything else: explicitly safe
tests\alert_dedup.tests.ps1, tests\dedup_order.tests.ps1, tests\dimension_guidance.tests.ps1, tests\docs_consistency.tests.ps1,
tests\goods_engine.tests.ps1, tests\heartbeat.tests.ps1, tests\gonghai_chrome_isolation.tests.ps1, tests\log_maintenance.tests.ps1,
tests\msg_source.tests.ps1, tests\no_reply.tests.ps1, tests\page_health_verdict.tests.ps1, tests\page_heal_throttle.tests.ps1,
tests\reply_engine.tests.ps1, tests\reply_gate_dupskip.tests.ps1, tests\report_push.tests.ps1, tests\should_reply_v2.tests.ps1,
tests\vision.tests.ps1 — **no live-runtime writes, no network, no browser, no long-lived process.** They touch only %TEMP%, repo
fixtures and repo source text. (docs_consistency.tests.ps1 does read the live in-repo scripts\config.json, docs_consistency.tests.ps1:54
— read-only, but it goes red if the live config legitimately drifts from the two = 5 keys.)

**Live artifacts touched by a full run (summary):** …-runtime\data\gonghai\*.json, …-runtime\data\pytest-lock.lock, conditionally
…-runtime\logs\accio_auth_state.json, <repo-root>\scripts\config.json, read-only …-runtime\data\msgs_*.txt and
<runtime>\specs\incident_evidence\*, plus the read-only live Chrome page on 9222.

---

## 4. Safe run recipe (Windows PowerShell 5.1)

Project convention — every .ps1 is invoked as:
`powershell -ExecutionPolicy Bypass -NoProfile -File <path>`

### (a) Whole suite, with live-state protection

```powershell
# --- 0) pre-flight (read-only) -------------------------------------------------
# monitor/watchdog must be disabled and nothing must be mid-run:
Get-ScheduledTask | Where-Object TaskName -match 'AlibabaAutoReply' |
    Select-Object TaskName, State, @{n='Trigger';e={($_.Triggers | ForEach-Object { $_.CimClass.CimClassName + ' ' + $_.StartBoundary }) -join ';'}}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'monitor\.ps1|gonghai_(batch|probe|loop)\.ps1' } |
    Select-Object ProcessId, CommandLine
# NOTE (audit finding): Health + Watchdog are Disabled, but Optimize (auto_optimize.ps1, daily 05:30),
# Quality (analyze_replies.ps1, daily 05:00), Summary (summarize.ps1, every 4h from 18:33) and
# Weekly (weekly_report.ps1, daily 08:00) are Ready -> do not start a run at those times.

# --- 1) BACK UP the live config (git-ignored: no VCS recovery) ------------------
$pre = Join-Path $env:TEMP ("aar_pretest_" + (Get-Date -Format yyyyMMdd_HHmmss))
New-Item -ItemType Directory -Path $pre -Force | Out-Null
Copy-Item '<repo-root>\scripts\config.json' (Join-Path $pre 'config.json') -Force
$preHashes = @{}
foreach ($f in 'sent_index.json','gonghai_rate.json','pending.json') {
    $p = Join-Path '<runtime-root>\data\gonghai' $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $pre $f) -Force; $preHashes[$f] = (Get-FileHash $p).Hash }
}
"backup dir = $pre"; Get-FileHash (Join-Path $pre 'config.json') | Format-List

# --- 2) run the suite (do NOT press Ctrl-C) -----------------------------------
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\run_tests.ps1 2>&1 |
    Tee-Object -FilePath (Join-Path $pre 'run.log')
"exit code = $LASTEXITCODE"     # 0 = all files pass; 1 = see the FAILED: line

# --- 3) post-run verification (live state must be intact) ---------------------
(Get-FileHash '<repo-root>\scripts\config.json').Hash -eq (Get-FileHash (Join-Path $pre 'config.json')).Hash
foreach ($f in 'sent_index.json','gonghai_rate.json','pending.json') {
    $p = Join-Path '<runtime-root>\data\gonghai' $f
    if ($preHashes.ContainsKey($f)) { "$f restored = " + ((Get-FileHash $p).Hash -eq $preHashes[$f]) }
}
Test-Path '<runtime-root>\data\pytest-lock.lock'                 # must be False
Test-Path '<runtime-root>\data\gonghai-window-unit-test.lock'    # must be False
Test-Path '<runtime-root>\data\gonghai\disabled'                 # must be False (unless it pre-existed)
Select-String -Path '<runtime-root>\data\gonghai\sent_index.json' -Pattern 'TESTKEY' -Quiet   # must be False
Select-String -Path '<runtime-root>\data\gonghai\pending.json'    -Pattern 'PENDKEY' -Quiet   # must be False

# --- 4) emergency recovery (only if a run was killed mid-way) -----------------
Copy-Item (Join-Path $pre 'config.json') '<repo-root>\scripts\config.json' -Force
foreach ($f in 'sent_index.json','gonghai_rate.json','pending.json') {
    $b = Join-Path $pre $f
    if (Test-Path $b) {
        $dst = Join-Path '<runtime-root>\data\gonghai' $f
        if (Test-Path $dst) { Remove-Item $dst -Force }   # confirm $dst is the intended path before deleting
        Copy-Item $b $dst -Force
    }
}
```

### (b) A single test file, safely

```powershell
# generic form (cwd does not matter: every test derives its paths from $MyInvocation):
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\<name>.tests.ps1
# exit code 0 = ALL PASS, 1 = FAILED (see the RESULT: pass=.. fail=.. line)

# examples
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\docs_consistency.tests.ps1   # pure, always safe
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\reply_engine.tests.ps1       # pure, always safe

# live-state-risk files: back up first, run, then verify (same 3 commands as (a))
Copy-Item '<repo-root>\scripts\config.json' "$env:TEMP\config.json.bak" -Force
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\gonghai.tests.ps1
(Get-FileHash '<repo-root>\scripts\config.json').Hash -eq (Get-FileHash "$env:TEMP\config.json.bak").Hash
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\lock.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File <repo-root>\tests\accio.tests.ps1   # only with Accio.exe NOT running
```

Never dot-source a test file into an interactive session (`. .\tests\gonghai.tests.ps1`): the tests rely on
$MyInvocation.MyCommand.Path (which points at your session when dot-sourced) and on exit to report status; dot-sourcing also runs the
live-state writes in your own session without a finally boundary you control.

### (c) Redirected / temp runtime root — no test supports it; use a copied tree

**Finding:** there is **no** environment variable, switch or parameter that redirects the runtime root. Get-SkillPath reads only
Join-Path $PSScriptRoot 'config.json' (config.ps1:8) and config.ps1:1-51 contains no $env: lookup. The only $env: reads in the suite
are $env:TEMP and $env:USERPROFILE (tests\accio.tests.ps1:23-25, tests\daemon_launch.tests.ps1:25-27, tests\env_block.tests.ps1:43-44,
tests\log_maintenance.tests.ps1:24, tests\no_reply.tests.ps1:24, tests\no_reply_write.tests.ps1:31,
tests\page_health_verdict.tests.ps1:18, tests\report_push.tests.ps1:55, tests\send_page_param.tests.ps1:114, tests\vision.tests.ps1:68,
tests\should_reply.tests.ps1:395, tests\alert_dedup.tests.ps1:15). The only redirect that leaves the live repo untouched is to run a
**copy** of the repo whose scripts\config.json points at a temp runtime root:

```powershell
$src = '<repo-root>'
$dst = Join-Path $env:TEMP ('aar_saferun_' + (Get-Date -Format yyyyMMdd_HHmmss))
$rt  = Join-Path $dst 'runtime'                       # temp runtime root (data/logs/reports/backups)
New-Item -ItemType Directory -Path $rt -Force | Out-Null
robocopy $src $dst /E /XD .git node_modules .opencode /NFL /NDL /NJH /NJS /NP | Out-Null

# rewrite ONLY the runtime paths in the copy; keep every policy value byte-identical, otherwise
# should_reply.tests.ps1:267-273 / should_reply_v2.tests.ps1:203-206 / gonghai* policy assertions go red
$cfgPath = Join-Path $dst 'scripts\config.json'
$cfg = Get-Content $cfgPath -Raw
$cfg = $cfg -replace [regex]::Escape('D:\\alibaba-auto-reply-runtime'), ($rt -replace '\\','\\')
$cfg = $cfg -replace [regex]::Escape('D:\\alibaba-auto-reply'), ($dst -replace '\\','\\')
Set-Content -Path $cfgPath -Value $cfg -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $rt 'data'),(Join-Path $rt 'logs'),(Join-Path $rt 'reports'),(Join-Path $rt 'backups') -Force | Out-Null

# run the copy (its tests\ derive their root from their own location, so they exercise the copy's config)
powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $dst 'tests\run_tests.ps1')
# everything the suite writes now lands in $rt; the live repo and the live runtime root are untouched.
```

Caveats for (c): the copy is a snapshot (docs-vs-code tests compare the copy, which is fine at copy time); the two CDP tests still reach
the live browser on 9222 because the port comes from the same config (cdp_port: 9222) — remove those two files from the copy's tests\
folder if the live browser must not be touched at all; docs_consistency.tests.ps1 compares scripts\config.json with
scripts\config.json.example inside the copy, so keep the rewritten JSON valid; robocopy excludes **all** node_modules directories (the
suite needs none — no_reply_write.tests.ps1:53 uses the system node.exe).

---

## 5. BOM / encoding check

Requirement: every .ps1 in scripts\ and tests\ must start with a UTF-8 BOM (EF BB BF = 239,187,191) — see docs\KNOWN_EXCEPTIONS.md
E-10 and the in-file warnings (tests\alert_dedup.tests.ps1:5-6, tests\page_health_verdict.tests.ps1:5-7,
tests\docs_consistency.tests.ps1:7-8). tests\gonghai.tests.ps1:218-224 asserts the BOM for the gonghai module files only.

```powershell
# check every .ps1 under scripts\ and tests\ (read-only)
$root = '<repo-root>'
Get-ChildItem -Path (Join-Path $root 'scripts'),(Join-Path $root 'tests') -Recurse -Filter *.ps1 -File | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    $ok = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $ok) { 'NO-BOM: ' + $_.FullName }
}
# one-liner variant:
# Get-ChildItem <repo-root>\scripts,<repo-root>\tests -Recurse -Filter *.ps1 -File |
#   Where-Object { $b=[IO.File]::ReadAllBytes($_.FullName); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) } |
#   Select-Object -ExpandProperty FullName
```

**Current result (2026-10-03): 88 .ps1 files scanned (60 under scripts\, 28 under tests\), 5 files missing the BOM.**

| # | File missing BOM | Non-ASCII bytes | Where the non-ASCII text sits | Practical impact of the missing BOM |
|---|---|---|---|---|
| 1 | scripts\watchdog.ps1 | 4 025 | inside **string literals** of Write-Log / $alert (lines 66, 71, 180, 212) | Real: PowerShell 5.1 decodes a BOM-less .ps1 as ANSI/GBK, so those Chinese log and alert strings are mojibake in watchdog.log and in the alert message |
| 2 | scripts\lib\msg_norm.ps1 | 59 | inside **regex literals** (lines 283-285, 288-289: 公斤/千克/吨, 尺寸, 收货地址/邮编, 供应商, 件/箱) | Real: the Chinese alternatives silently fail to match, i.e. message classification degrades. File is untracked/new (git status: ?? scripts/lib/msg_norm.ps1) and is not yet dot-sourced by any script or test |
| 3 | tests\accio.tests.ps1 | 297 | comments only (0 code lines) | Cosmetic: comments render garbled; no assertion depends on them |
| 4 | tests\daemon_launch.tests.ps1 | 1 859 | comments only, incl. trailing comments on lines 54-57 | Cosmetic |
| 5 | tests\page_heal_throttle.tests.ps1 | 612 | comments only | Cosmetic |

Notes: (i) the project's own BOM assertion covers only the gonghai module files (tests\gonghai.tests.ps1:218-224), so items 3-5 are
currently invisible to the suite; (ii) items 1-2 are production files, not test files, but they are in scope of the "every .ps1 starts
with a BOM" rule; (iii) the fix is a byte-prefix change (prepend EF BB BF) — **not performed here** (this audit is read-only). A wider
check outside the requested scope also reports untracked scratch scripts under tools\ (tools\_gh56_hunt.ps1, tools\_my.ps1, tools\_u.ps1)
without a BOM.
