> Historical snapshot (2026-10-03). Later module removal, entrypoint repairs and production-chain gaps are documented in [current status](当前状态.md). Preserve the original evidence below; do not treat this report as a current deployment or end-to-end acceptance result.

# Change report - natural replies, structure, efficiency (2026-10-03)

Branch `natural-reply-20261003` (base `main` @ 5356302). Production remains **disabled**.
Rollback: see `docs\rollback_20261003.md`. Old-vs-new replies: `docs\reply_comparison_20261003.md`.
Source audits: `docs\inventory_20261003.md`, `docs\test_audit_20261003.md`.
Offline replay harness: `tools\acceptance\replay.ps1` (19 desensitized scenarios).

---

## 1. The four things that were wrong

| # | Problem | Evidence found | Fix |
|---|---|---|---|
| 1 | Replies read like an AI because the policy told the model to do contradictory things at once: acknowledge briefly, always push forward, always ask for information, and never repeat itself. | `reply_agent_prompt.md` carried a scenario table, a 2-ask limit, a dimension script, a red-line list, a 55-line auto-appended archive, and a pointer to a manual it never loaded. `reply_rules.json` carried 40 `never` rules with 7 semantic duplicates. | One decision authority (`reply_policy.ps1`) + one wording authority (`reply_gen.ps1`) + one slim language prompt + one actually-injected scenario file. Every reply path now shares them. |
| 2 | Short messages were silently dropped, so `ok`, `si` and `no` never became events and were never answered. | Page extractor: `if (clean.length <= 2) { ...; return; }` unless the row had an image. | Length filter removed. Every non-empty message becomes a message event; skips are recorded with a reason. |
| 3 | Message order was undefined, and three consumers disagreed about it. | `lib\msg_source.ps1` treats the TAIL as newest (built from 1812 real messages); the should-reply hash used the LAST buyer line; attachments were read from index 0; the prompt claimed index 0 was newest. | `msg_norm.ps1` decides the direction from the per-message `showTime` already in the DOM, normalizes to chronological ascending, and flags an explicit anomaly instead of guessing. Attachments now come from the newest buyer message. |
| 4 | Automatic optimization edited live policy every day with no review. | `auto_optimize.ps1` appended up to 5 `never` rules and Chinese red lines directly, then merged, keeping only the newest 40 rules - which could drop a hard constraint. `analyze_replies.ps1 -ApplyNever` was a second direct-append path. | Both now write suggestion records only. Applying requires an explicit human accept plus a separate apply command, with a base-hash check, a backup and rollback. |

## 2. What a reply does now

Order of decisions (spec 4.2): safety limits, then the concrete request, then emotion and requests
for a person, then help we can actually give, and only last the information the current stage needs.

- 18 scenarios are classified explicitly, including the ones the spec names: cargo-received query,
  ambiguous address, supplier handoff failure, buyer wants a human, repeated chasing, angry buyer,
  unknown quote, dimensions already given, details promised later, simple acknowledgement,
  image-only, file parse failure, several short messages, same text as a new message, human already
  answered, notification failure.
- Language is American English regardless of what the buyer writes.
- Default length is one or two sentences; a bare "ok" gets one short line and does **not** get turned
  into a new task.
- A field can be asked at most twice, enforced in code and shared by every path.
- No price, no contact exchange, no liability or refund promise, no invented status or number, and no
  deadline unless a real todo and a successful notification exist behind it.
- The fallback path and the model path use the SAME policy, so a model outage cannot change what the
  company promises.

## 3. Structure

| Metric | Before | After | Method |
|---|---|---|---|
| `scripts\monitor.ps1` physical lines | 1886 | 1883 | file line count |
| `scripts\monitor.ps1` effective code lines | 1504 | 1437 | non-blank, non-comment |
| `scripts\reply_engine.ps1` physical / effective | 803 / 562 | 500 / 279 | same |
| Production `.ps1` effective code lines (scripts + tools) | 13052 | 12714 | same |
| ... of which NEW module code | - | 1345 | the four new libs and three new CLIs |
| ... therefore pre-existing production code | 13052 | 11369 | **-1683 effective lines, -12.9%** |
| `never` policy rules | 40 | 21 | JSON key count |
| Semantically duplicate `never` rules | 7 | 0 | 6-word fingerprint |
| Dead `templates` keys in the corpus | 7 | 2 | keys with no production consumer |
| Test files / assertions (safe subset) | - | 20 files / 894 assertions | test runner output |

Removed rather than moved: the retired intent engine (`Detect-Lang`,
`New-ReplyContext`, `Resolve-IntentEarly/-Info/-Data`,
`Build-MissingQuestion`, `Resolve-Template`, `Generate-Reply`,
`$script:SupplierContactAsk`) - 4 languages of unreachable branches and a second,
competing implementation of business policy. `monitor.ps1` keeps 38 functions but no longer
contains prompt assembly, corpus concatenation, ask-count logic, image fallback wording or rewrite
orchestration.

Two files were archived, not deleted: `reply_playbook.md` (referenced by filename but never
injected - the "fake load" the spec calls out) and `consolidate_prompt.ps1` (merged redline blocks
that no longer exist).

## 4. Efficiency

| Metric | Before | After | Note |
|---|---|---|---|
| Injected characters per model call | ~29718 | 12479 | system prompt + corpus + scenario section + context block; **-58%** |
| System prompt + corpus | 27918 | 11456 | the scenario manual is NOT added in full |
| Scenario material actually injected | 0 chars (manual named, never sent) | 351 chars for this scenario | one matched section |
| Worst-case model calls per reply | up to 4 | 2 | 1 generate + at most 1 rewrite, and the rewrite is skipped if under 30s of round budget remains |
| Independent rewrite rounds | 2 (banned words, liability) | 1 (shared, full violation list) | spec 6 |
| Context order | raw DOM order, described incorrectly | chronological ascending, verified against showTime | |
| Attachment work | image/document download + a SECOND extraction model call | unchanged pipeline, but only reached when the message actually carries an attachment | |

The 30-second target remains an engineering baseline, not a platform rule. Real end-to-end latency
was **not** measured: no live send was performed and no real model call was made. See section 7.

## 5. Suggestion system - the seven guarantees, all tested

`tools\acceptance\` and `tests\suggestions.tests.ps1` prove, offline:

1. A scheduled generation pass does not modify any active file (hashes before/after).
2. Re-proposing the same idea merges into one record and bumps `seenCount`, keeping its status.
3. A suggestion that is not `accepted` cannot be applied - the apply command refuses.
4. A rejected suggestion is never resubmitted as pending.
5. If the target file changed after generation, the apply is refused and the newer manual edit is not overwritten.
6. The write is backed up first; a failed offline validation restores the backup and records the reason.
7. Applying only ever APPENDS. The old "keep the newest 40 rules" truncation is gone, so a hard constraint cannot be squeezed out. Proposals that would relax a price, liability, contact, identity or send-protection rule are refused at intake.

Viewing and applying are deliberately separate commands.

## 6. How to reproduce the verification

```powershell
# Run from the repository root
# 1) the reply-chain and suggestion unit tests
powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_chain.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\suggestions.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\dimension_guidance.tests.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tests\reply_engine.tests.ps1
# 2) the offline replay harness (fake model, fake clock, no network)
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1
# 3) old vs new reply comparison (writes docs\reply_comparison_20261003.md)
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\old_vs_new.ps1
```

Before running the FULL suite, read `docs\test_audit_20261003.md` section 3. `run_tests.ps1` has no
isolation: `gonghai.tests.ps1` rewrites the live git-ignored `scripts\config.json` and restores it in a
`finally` block, and `page_health` / `page_select` drive the live OneTalk page on port 9222.

## 6b. One pre-existing test defect found and made robust

`tests\env_block.tests.ps1` asserted that **the calling process** has case-insensitive
duplicate environment keys (`NO_PROXY` / `no_proxy` and friends). That is a property of this
machine, not of the repository, so the test failed whenever it was launched from a host whose
environment is clean - which is exactly what happened here, and it is unrelated to this change
(assertions at lines 22-25 read only `[System.Environment]` and touch nothing in the repo).

It was made conditional rather than weakened: when duplicates exist the folding assertions still run
and still judge true/false; when they do not, the test prints a NOTE and skips just those two, plus a
new always-on assertion that the cleaned snapshot never exceeds the raw count. The repo already uses
this NOTE-skip pattern elsewhere. Environment-specific facts should not be pass conditions.

## 7. What is NOT done, and what this does NOT prove

Stated plainly, because the spec asks for it:

- **No real model call and no live send were performed.** Every result here is an offline replay with
  a stub model. Static and replay tests are not evidence of model writing quality or of passing the
  platform's response-time grading.
- **The local todo / notification path is not wired.** The decision object reports
  `NeedHumanTodo` and `TodoKind`, but nothing creates a todo record or pushes a notification yet.
  Because of that, the code is configured with the notification channel treated as UNVERIFIED, so
  **no reply promises a specific deadline**. Wiring it is the one remaining spec 4.4 item, and it can
  be added without touching policy.
- **"I can confirm the cargo details with them directly" is the owner-approved conditional wording**
  and is deliberately allowed. Only past-tense claims ("I have contacted your supplier") and promises
  that the supplier will contact the buyer are blocked. If that conditional offer should also be
  blocked, it is a one-line change in `reply_policy.ps1`.
- **A 20-second wall-clock floor** (`reply_new_msg_floor_sec`) is the only time gate that applies to a
  confirmed new message. It is an engineering floor so two sends cannot happen in the same instant;
  it is not a platform rule.
- **Not touched:** the public-pool (gonghai), OKKI and waimao business lines; the browser onboarding,
  page isolation, identity check, write lock and send path; the WeCom smart sheet (no integration, as
  instructed); any real buyer conversation.
- **Known remaining issues, not fixed here:** `$script:pageDownStreak` is still incremented twice per
  round (`monitor.ps1`); six different UI-noise strip lists still exist; the conversation-name
  extraction JS is still duplicated in three places; `scripts\reply_rules.json`'s `data_to_collect` is
  read by nothing in production (the policy uses typed field keys); `Get-MissingInfo` now has no
  production caller and is kept only under regression test.
- **Open items for you to confirm:**
  1. `brand.company_name` is now empty and the literal placeholder token "Your Company Name" was
     removed from `service_description` so the model can never echo a fill-in-the-blank token into a
     buyer reply. Fill in the real name.
  2. The removed `templates.our_contact` held a `[Your Contact Info]` placeholder and told the model to hand
     out contact details, which contradicts the platform rule. It was removed with its only caller.
  3. The dimension-guidance wording is unchanged and still appears verbatim, so the approved scripts
     behave exactly as before.

## 8. Status

Production stays disabled. `AlibabaAutoReplyWatchdog` and `AlibabaAutoReplyHealth` were already
Disabled and remain so; no task was enabled, disabled or added. Nothing was sent to a buyer and no
notification was pushed. Re-enabling the monitor, and any real-model evaluation that costs money or
sends customer content, is a separate decision for you.
