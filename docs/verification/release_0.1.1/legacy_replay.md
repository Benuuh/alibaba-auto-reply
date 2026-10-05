# Offline acceptance replay - reply chain

Generated: 2026-10-06 03:58:55  
Repo: C:\path\to\alibaba-auto-reply  
Scenario dir: C:\path\to\alibaba-auto-reply\tests\scenarios  
Model: FAKE stub Invoke-LLM (marker aar-acceptance-fake-llm-v1); scripts/lib/llm.ps1 NOT loaded; no network, no browser.  
Clock: SIMULATED (fixture clock object; overridable with -FirstSeenAt/-SentAt). A missing first-seen time is reported as UNKNOWN, never as 0.

## Summary

- scenarios: 20
- scenario PASS: 0
- scenario FAIL: 20
- assertions: 594 (82 failed)

## Per scenario

| id | want action | got action | source | model calls | ctx chars | sys chars | guidance chars | order confident | reply | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 01_cargo_received_query | delivery_status | delivery_status | FALLBACK | 2 | 1830 | 1983 | 454 | True | Could you share the number of cartons or pallets? | FAIL: quality:acknowledges-and-confirms, model-calls, stub-invocations, reply-source, guidance-injected |
| 02_address_ambiguous | address_clarify | address_clarify | FALLBACK | 1 | 1887 | 1923 | 394 | True | Could you confirm which delivery destination we should use? | FAIL: model-calls, guidance-injected |
| 03_supplier_handoff_failure | supplier_unreachable | supplier_unreachable | FALLBACK | 2 | 1941 | 1989 | 460 | True | Could you share the total weight? | FAIL: quality:acknowledges-the-handoff-problem, model-calls, stub-invocations, reply-source, guidance-injected |
| 04_human_requested | human_requested | human_requested | FALLBACK | 2 | 1889 | 2060 | 531 | True | Thanks for your message. | FAIL: quality:commits-to-handoff, model-calls, stub-invocations, reply-source, guidance-injected |
| 05_repeated_chasing | delivery_status | delivery_status | FALLBACK | 2 | 1886 | 1983 | 454 | True | Could you share the number of cartons or pallets? | FAIL: quality:concrete-next-step, reply-source, guidance-injected |
| 06_angry_buyer | complaint | complaint | FALLBACK | 2 | 1918 | 2101 | 572 | True | Thanks for your message. | FAIL: quality:acknowledges, quality:says-what-happens-next, model-calls, guidance-injected |
| 07_unknown_quote | new_inquiry | new_inquiry | FALLBACK | 2 | 1720 | 1846 | 317 | True | Could you share the total weight? | FAIL: model-calls, stub-invocations, reply-source, guidance-injected |
| 08_dimensions_already_given | details_given | details_given | FALLBACK | 2 | 1884 | 2586 | 1057 | True | Could you share the total weight? Could you share the delivery address? | FAIL: quality:confirms-receipt, model-calls, stub-invocations, reply-source, guidance-injected |
| 09_material_promised | material_promised | material_promised | FALLBACK | 1 | 1987 | 1955 | 426 | True | Thanks for your message. | FAIL: quality:accepts-the-promise, model-calls, guidance-injected |
| 10_simple_acknowledgement | short_ack | short_ack | FALLBACK | 2 | 1777 | 1948 | 419 | True | Thanks for your message. | FAIL: model-calls, stub-invocations, reply-source, guidance-injected |
| 11_image_only_message | attachment_only | attachment_only | FALLBACK | 2 | 1762 | 1930 | 401 | True | Could you share the total weight? Could you share the carton sizes (L x W x H)? | FAIL: quality:acknowledges-attachment, model-calls, stub-invocations, reply-source, guidance-injected |
| 12_file_parse_failure | details_given | details_given | FALLBACK | 2 | 1723 | 2586 | 1057 | True | Could you share the total weight? Could you share the carton sizes (L x W x H)? | FAIL: quality:still-useful, guidance-injected |
| 13_several_short_messages | short_ack | short_ack | FALLBACK | 2 | 1737 | 1948 | 419 | True | Thanks for your message. | FAIL: model-calls, stub-invocations, reply-source, guidance-injected |
| 14_same_text_new_message | delivery_status | delivery_status | FALLBACK | 2 | 1858 | 1983 | 454 | True | Could you share the number of cartons or pallets? | FAIL: quality:treats-it-as-new, model-calls, stub-invocations, reply-source, guidance-injected |
| 15_human_already_answered | short_ack | short_ack | FALLBACK | 2 | 1857 | 1948 | 419 | True | Thanks for your message. | FAIL: model-calls, stub-invocations, reply-source, guidance-injected |
| 16_notification_failure | delivery_status | delivery_status | FALLBACK | 1 | 1902 | 1983 | 454 | True | Could you share the number of cartons or pallets? | FAIL: quality:says-it-is-being-confirmed, model-calls, guidance-injected |
| 17_quote_ready_query | quote_ready_query | quote_ready_query | FALLBACK | 2 | 1790 | 1920 | 391 | True | Could you share the total weight? Could you share the carton sizes (L x W x H)? | FAIL: quality:still-working, reply-source, guidance-injected |
| 18_reverse_dom_order | delivery_status | delivery_status | FALLBACK | 2 | 1936 | 1983 | 454 | True | Could you share the number of cartons or pallets? | FAIL: quality:answers-the-newest-line, model-calls, stub-invocations, reply-source, guidance-injected |
| 19_two_char_refusal | refusal | refusal | FALLBACK | 2 | 1703 | 1852 | 323 | True | Thanks for your message. | FAIL: model-calls, stub-invocations, reply-source, guidance-injected |
| 20_render_clock_vs_message_time | new_inquiry | new_inquiry | FALLBACK | 2 | 1806 | 1846 | 317 | True | Could you share the total weight? | FAIL: quality:addresses-container-rate, model-calls, stub-invocations, reply-source, guidance-injected |

## Stage metrics (MEASURED)

system chars and ctx chars are measured AT THE MODEL BOUNDARY by the fake Invoke-LLM stub, not estimated.

| id | scenario | model calls (want) | stub calls (want) | rewrites | ctx chars | sys chars | request chars | guidance chars | order confident | order reason | wall ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01_cargo_received_query | delivery_status | 2 (1) | 2 (1) | 1 | 1830 | 1983 | 3813 | 454 | True | timestamps-monotonic-ascending | 261 |
| 02_address_ambiguous | address_clarify | 1 (0) | 1 (1) | 0 | 1887 | 1923 | 3810 | 394 | True | timestamps-monotonic-ascending | 75 |
| 03_supplier_handoff_failure | supplier_unreachable | 2 (1) | 2 (1) | 1 | 1941 | 1989 | 3930 | 460 | True | timestamps-monotonic-ascending | 29 |
| 04_human_requested | human_requested | 2 (1) | 2 (1) | 1 | 1889 | 2060 | 3949 | 531 | True | timestamps-monotonic-ascending | 24 |
| 05_repeated_chasing | delivery_status | 2 (2) | 2 (2) | 1 | 1886 | 1983 | 3869 | 454 | True | timestamps-monotonic-ascending | 57 |
| 06_angry_buyer | complaint | 2 (1) | 2 (2) | 1 | 1918 | 2101 | 4019 | 572 | True | timestamps-monotonic-ascending | 40 |
| 07_unknown_quote | new_inquiry | 2 (1) | 2 (1) | 1 | 1720 | 1846 | 3566 | 317 | True | single-message | 22 |
| 08_dimensions_already_given | details_given | 2 (1) | 2 (1) | 1 | 1884 | 2586 | 4470 | 1057 | True | timestamps-monotonic-ascending | 47 |
| 09_material_promised | material_promised | 1 (0) | 1 (1) | 0 | 1987 | 1955 | 3942 | 426 | True | timestamps-monotonic-ascending | 50 |
| 10_simple_acknowledgement | short_ack | 2 (1) | 2 (1) | 1 | 1777 | 1948 | 3725 | 419 | True | timestamps-monotonic-ascending | 33 |
| 11_image_only_message | attachment_only | 2 (1) | 2 (1) | 1 | 1762 | 1930 | 3692 | 401 | True | timestamps-monotonic-ascending | 42 |
| 12_file_parse_failure | details_given | 2 (2) | 2 (2) | 1 | 1723 | 2586 | 4309 | 1057 | True | timestamps-monotonic-ascending | 28 |
| 13_several_short_messages | short_ack | 2 (1) | 2 (1) | 1 | 1737 | 1948 | 3685 | 419 | True | timestamps-monotonic-ascending | 33 |
| 14_same_text_new_message | delivery_status | 2 (1) | 2 (1) | 1 | 1858 | 1983 | 3841 | 454 | True | timestamps-monotonic-ascending | 29 |
| 15_human_already_answered | short_ack | 2 (1) | 2 (1) | 1 | 1857 | 1948 | 3805 | 419 | True | timestamps-monotonic-ascending | 19 |
| 16_notification_failure | delivery_status | 1 (0) | 1 (1) | 0 | 1902 | 1983 | 3885 | 454 | True | timestamps-monotonic-ascending | 28 |
| 17_quote_ready_query | quote_ready_query | 2 (2) | 2 (2) | 1 | 1790 | 1920 | 3710 | 391 | True | timestamps-monotonic-ascending | 61 |
| 18_reverse_dom_order | delivery_status | 2 (1) | 2 (1) | 1 | 1936 | 1983 | 3919 | 454 | True | timestamps-monotonic-descending | 43 |
| 19_two_char_refusal | refusal | 2 (1) | 2 (1) | 1 | 1703 | 1852 | 3555 | 323 | True | timestamps-monotonic-ascending | 17 |
| 20_render_clock_vs_message_time | new_inquiry | 2 (1) | 2 (1) | 1 | 1806 | 1846 | 3652 | 317 | True | timestamps-monotonic-descending | 22 |

## Timing (SIMULATED clock - this is NOT send latency)

| id | first seen (simulated) | sent (simulated) | latency seconds |
|---|---|---|---|
| 01_cargo_received_query | 2026-10-03T09:04:00Z | 2026-10-03T09:06:00Z | 120 |
| 02_address_ambiguous | 2026-10-03T09:03:00Z | 2026-10-03T09:07:00Z | 240 |
| 03_supplier_handoff_failure | 2026-10-03T09:02:00Z | 2026-10-03T09:05:00Z | 180 |
| 04_human_requested | 2026-10-03T09:03:00Z | 2026-10-03T09:06:00Z | 180 |
| 05_repeated_chasing | 2026-10-03T09:10:00Z | 2026-10-03T09:21:00Z | 660 |
| 06_angry_buyer | 2026-10-03T09:15:00Z | 2026-10-03T09:31:00Z | 960 |
| 07_unknown_quote | 2026-10-03T09:05:00Z | 2026-10-03T09:06:00Z | 60 |
| 08_dimensions_already_given | 2026-10-03T09:07:00Z | 2026-10-03T09:09:00Z | 120 |
| 09_material_promised | 2026-10-03T09:11:00Z | 2026-10-03T09:13:00Z | 120 |
| 10_simple_acknowledgement | 2026-10-03T09:06:00Z | 2026-10-03T09:08:00Z | 120 |
| 11_image_only_message | 2026-10-03T09:05:00Z | 2026-10-03T09:07:00Z | 120 |
| 12_file_parse_failure | 2026-10-03T09:03:00Z | 2026-10-03T09:06:00Z | 180 |
| 13_several_short_messages | 2026-10-03T09:02:00Z | 2026-10-03T09:06:00Z | 240 |
| 14_same_text_new_message | 2026-10-03T09:20:00Z | 2026-10-03T09:31:00Z | 660 |
| 15_human_already_answered | UNKNOWN | 2026-10-03T09:09:00Z | UNKNOWN |
| 16_notification_failure | 2026-10-03T09:09:00Z | 2026-10-03T09:11:00Z | 120 |
| 17_quote_ready_query | 2026-10-03T09:05:00Z | 2026-10-03T09:07:00Z | 120 |
| 18_reverse_dom_order | 2026-10-03T09:51:00Z | 2026-10-03T09:53:00Z | 120 |
| 19_two_char_refusal | 2026-10-03T09:03:00Z | 2026-10-03T09:05:00Z | 120 |
| 20_render_clock_vs_message_time | 2026-10-04T06:33:39Z | 2026-10-04T06:34:03Z | 24 |

## Failures

- **01_cargo_received_query** (quality:acknowledges-and-confirms): no match for '(?i)(confirm|check|look into|verif)'
- **01_cargo_received_query** (model-calls): gen=2 want=1
- **01_cargo_received_query** (stub-invocations): stub=2 want=1
- **01_cargo_received_query** (reply-source): got 'FALLBACK' want 'LLM'
- **01_cargo_received_query** (guidance-injected): marker=False guidanceChars=454 key=delivery_status
- **02_address_ambiguous** (model-calls): gen=1 want=0
- **02_address_ambiguous** (guidance-injected): marker=False guidanceChars=394 key=address_clarify
- **03_supplier_handoff_failure** (quality:acknowledges-the-handoff-problem): no match for '(?i)(supplier|frustrating|sorry|understand|stuck|help)'
- **03_supplier_handoff_failure** (model-calls): gen=2 want=1
- **03_supplier_handoff_failure** (stub-invocations): stub=2 want=1
- **03_supplier_handoff_failure** (reply-source): got 'FALLBACK' want 'LLM'
- **03_supplier_handoff_failure** (guidance-injected): marker=False guidanceChars=460 key=supplier_unreachable
- **04_human_requested** (quality:commits-to-handoff): no match for '(?i)(person|human|team|colleague)'
- **04_human_requested** (model-calls): gen=2 want=1
- **04_human_requested** (stub-invocations): stub=2 want=1
- **04_human_requested** (reply-source): got 'FALLBACK' want 'LLM'
- **04_human_requested** (guidance-injected): marker=False guidanceChars=531 key=human_requested
- **05_repeated_chasing** (quality:concrete-next-step): no match for '(?i)(confirm|check|status|concrete)'
- **05_repeated_chasing** (reply-source): got 'FALLBACK' want 'LLM_REWRITE'
- **05_repeated_chasing** (guidance-injected): marker=False guidanceChars=454 key=delivery_status
- **06_angry_buyer** (quality:acknowledges): no match for '(?i)(sorry|apolog)'
- **06_angry_buyer** (quality:says-what-happens-next): no match for '(?i)(check|confirm|status|looking into|come back)'
- **06_angry_buyer** (model-calls): gen=2 want=1
- **06_angry_buyer** (guidance-injected): marker=False guidanceChars=572 key=complaint
- **07_unknown_quote** (model-calls): gen=2 want=1
- **07_unknown_quote** (stub-invocations): stub=2 want=1
- **07_unknown_quote** (reply-source): got 'FALLBACK' want 'LLM'
- **07_unknown_quote** (guidance-injected): marker=False guidanceChars=317 key=new_inquiry
- **08_dimensions_already_given** (quality:confirms-receipt): no match for '(?i)(noted|thanks|perfect|got it|received)'
- **08_dimensions_already_given** (model-calls): gen=2 want=1
- **08_dimensions_already_given** (stub-invocations): stub=2 want=1
- **08_dimensions_already_given** (reply-source): got 'FALLBACK' want 'LLM'
- **08_dimensions_already_given** (guidance-injected): marker=False guidanceChars=1057 key=details_given
- **09_material_promised** (quality:accepts-the-promise): no match for '(?i)(no rush|whenever|sounds good|no problem|sure|take your time|ready)'
- **09_material_promised** (model-calls): gen=1 want=0
- **09_material_promised** (guidance-injected): marker=False guidanceChars=426 key=material_promised
- **10_simple_acknowledgement** (model-calls): gen=2 want=1
- **10_simple_acknowledgement** (stub-invocations): stub=2 want=1
- **10_simple_acknowledgement** (reply-source): got 'FALLBACK' want 'LLM'
- **10_simple_acknowledgement** (guidance-injected): marker=False guidanceChars=419 key=short_ack
- **11_image_only_message** (quality:acknowledges-attachment): no match for '(?i)(image|photo|picture)'
- **11_image_only_message** (model-calls): gen=2 want=1
- **11_image_only_message** (stub-invocations): stub=2 want=1
- **11_image_only_message** (reply-source): got 'FALLBACK' want 'LLM'
- **11_image_only_message** (guidance-injected): marker=False guidanceChars=401 key=attachment_only
- **12_file_parse_failure** (quality:still-useful): no match for '(?i)(noted|thanks|need|send|tell me)'
- **12_file_parse_failure** (guidance-injected): marker=False guidanceChars=1057 key=details_given
- **12_file_parse_failure** (probe:forced-attachment-parse-failed-fallback:fallback-matches): fallback 'Could you share the total weight? Thanks for your message.' does not match '(?i)could not open'
- **13_several_short_messages** (model-calls): gen=2 want=1
- **13_several_short_messages** (stub-invocations): stub=2 want=1
- **13_several_short_messages** (reply-source): got 'FALLBACK' want 'LLM'
- **13_several_short_messages** (guidance-injected): marker=False guidanceChars=419 key=short_ack
- **14_same_text_new_message** (quality:treats-it-as-new): no match for '(?i)(confirm|check|status|on it)'
- **14_same_text_new_message** (model-calls): gen=2 want=1
- **14_same_text_new_message** (stub-invocations): stub=2 want=1
- **14_same_text_new_message** (reply-source): got 'FALLBACK' want 'LLM'
- **14_same_text_new_message** (guidance-injected): marker=False guidanceChars=454 key=delivery_status
- **15_human_already_answered** (model-calls): gen=2 want=1
- **15_human_already_answered** (stub-invocations): stub=2 want=1
- **15_human_already_answered** (reply-source): got 'FALLBACK' want 'LLM'
- **15_human_already_answered** (guidance-injected): marker=False guidanceChars=419 key=short_ack
- **16_notification_failure** (quality:says-it-is-being-confirmed): no match for '(?i)(confirm|check)'
- **16_notification_failure** (model-calls): gen=1 want=0
- **16_notification_failure** (guidance-injected): marker=False guidanceChars=454 key=delivery_status
- **16_notification_failure** (probe:real-action-evidence-allows-deadline:fallback-matches): fallback 'Could you share the number of cartons or pallets? Thanks for your message.' does not match '(?i)by tomorrow morning'
- **17_quote_ready_query** (quality:still-working): no match for '(?i)(working|soon|ready|number)'
- **17_quote_ready_query** (reply-source): got 'FALLBACK' want 'LLM_REWRITE'
- **17_quote_ready_query** (guidance-injected): marker=False guidanceChars=391 key=quote_ready_query
- **18_reverse_dom_order** (quality:answers-the-newest-line): no match for '(?i)(confirm|check|status|container)'
- **18_reverse_dom_order** (model-calls): gen=2 want=1
- **18_reverse_dom_order** (stub-invocations): stub=2 want=1
- **18_reverse_dom_order** (reply-source): got 'FALLBACK' want 'LLM'
- **18_reverse_dom_order** (guidance-injected): marker=False guidanceChars=454 key=delivery_status
- **19_two_char_refusal** (model-calls): gen=2 want=1
- **19_two_char_refusal** (stub-invocations): stub=2 want=1
- **19_two_char_refusal** (reply-source): got 'FALLBACK' want 'LLM'
- **19_two_char_refusal** (guidance-injected): marker=False guidanceChars=323 key=refusal
- **20_render_clock_vs_message_time** (quality:addresses-container-rate): no match for '(?i)(rate|container)'
- **20_render_clock_vs_message_time** (model-calls): gen=2 want=1
- **20_render_clock_vs_message_time** (stub-invocations): stub=2 want=1
- **20_render_clock_vs_message_time** (reply-source): got 'FALLBACK' want 'LLM'
- **20_render_clock_vs_message_time** (guidance-injected): marker=False guidanceChars=317 key=new_inquiry

## Informational probes

- 12_file_parse_failure / forced-attachment-parse-failed-fallback: scenario=attachment_parse_failed -> Could you share the total weight? Thanks for your message.
- 16_notification_failure / reachable-channel-is-not-action-evidence: scenario=delivery_status -> Could you share the number of cartons or pallets? Thanks for your message.
- 16_notification_failure / real-action-evidence-allows-deadline: scenario=delivery_status -> Could you share the number of cartons or pallets? Thanks for your message.


