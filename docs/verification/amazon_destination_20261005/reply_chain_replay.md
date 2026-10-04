# Offline acceptance replay - reply chain

Generated: 2026-10-05 04:26:25  
Repo: <repo>  
Scenario dir: <repo>\tests\scenarios  
Model: FAKE stub Invoke-LLM (marker aar-acceptance-fake-llm-v1); scripts/lib/llm.ps1 NOT loaded; no network, no browser.  
Clock: SIMULATED (fixture clock object; overridable with -FirstSeenAt/-SentAt). A missing first-seen time is reported as UNKNOWN, never as 0.

## Summary

- scenarios: 20
- scenario PASS: 20
- scenario FAIL: 0
- assertions: 580 (0 failed)

## Per scenario

| id | want action | got action | source | model calls | ctx chars | sys chars | guidance chars | order confident | reply | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 01_cargo_received_query | delivery_status | delivery_status | LLM | 1 | 749 | 3925 | 508 | True | Thanks for checking in. I am confirming the current status with the warehouse and will come back to you as soon as I have it. | PASS |
| 02_address_ambiguous | address_clarify | address_clarify | FALLBACK | 0 | 787 | 3811 | 394 | True | Happy to help with the address. Just so I get this right - is this the pickup address for the cargo, or the address it should be delivered to? | PASS |
| 03_supplier_handoff_failure | supplier_unreachable | supplier_unreachable | LLM | 1 | 841 | 3835 | 413 | True | That is frustrating, and I do not want to leave you stuck. I am having this checked from our side so it does not sit with you. | PASS |
| 04_human_requested | human_requested | human_requested | LLM | 1 | 789 | 3918 | 501 | True | Understood - I will get a person on this. I am passing it to the team now so they can take it from here. | PASS |
| 05_repeated_chasing | delivery_status | delivery_status | LLM_REWRITE | 2 | 805 | 3925 | 508 | True | I am confirming the actual status right now and I will come back to you as soon as I have something concrete. | PASS |
| 06_angry_buyer | complaint | complaint | FALLBACK | 1 | 818 | 4018 | 607 | True | I am sorry about this, and I understand why you are frustrated. I am checking the actual status right now, and I will come back to you as soon as I have something concrete. | PASS |
| 07_unknown_quote | new_inquiry | new_inquiry | LLM | 1 | 620 | 3730 | 317 | True | Happy to help with this. To price it accurately, could you share the total weight? | PASS |
| 08_dimensions_already_given | details_given | details_given | LLM | 1 | 784 | 4352 | 937 | True | Perfect, thanks - I have noted the carton measurements you sent. To finish the rate I just need the total weight and the delivery address. | PASS |
| 09_material_promised | material_promised | material_promised | FALLBACK | 0 | 887 | 3845 | 426 | True | Sounds good, no rush at all. Send them over whenever they are ready and I will take it from there. | PASS |
| 10_simple_acknowledgement | short_ack | short_ack | LLM | 1 | 677 | 3792 | 381 | True | Got it, thanks. I will keep an eye on this and let you know if anything needs you. | PASS |
| 11_image_only_message | attachment_only | attachment_only | LLM | 1 | 662 | 3818 | 401 | True | Thanks for the images. I am looking at them now - if the carton sizes or the total weight are handy, send them over and I can price this accurately. | PASS |
| 12_file_parse_failure | details_given | details_given | FALLBACK | 2 | 623 | 4352 | 937 | True | Thanks, I have noted those details. To finish the rate I just need the total weight and the carton sizes (L x W x H). | PASS |
| 13_several_short_messages | short_ack | short_ack | LLM | 1 | 637 | 3792 | 381 | True | Got it, thanks. I will keep an eye on this and let you know if anything needs you. | PASS |
| 14_same_text_new_message | delivery_status | delivery_status | LLM | 1 | 777 | 3925 | 508 | True | I am on it - I am confirming the actual status now and will come back to you as soon as I have it. | PASS |
| 15_human_already_answered | short_ack | short_ack | LLM | 1 | 757 | 3792 | 381 | True | Got it, thanks. I will keep an eye on this and let you know if anything needs you. | PASS |
| 16_notification_failure | delivery_status | delivery_status | FALLBACK | 0 | 821 | 3925 | 508 | True | Thanks for checking in. I do not want to give you a guess, so I am confirming the current status and will come back to you as soon as I have it. | PASS |
| 17_quote_ready_query | quote_ready_query | quote_ready_query | LLM_REWRITE | 2 | 690 | 3795 | 376 | True | I am still working on your rate and I do not want to send you a rough number. I will come back to you as soon as it is ready. | PASS |
| 18_reverse_dom_order | delivery_status | delivery_status | LLM | 1 | 855 | 3925 | 508 | True | I do not want to give you a guess on this. I am confirming the actual container status right now and will come back to you as soon as I have it. | PASS |
| 19_two_char_refusal | refusal | refusal | LLM | 1 | 603 | 3732 | 323 | True | No problem at all - thanks for letting me know. If anything changes, I am here. | PASS |
| 20_render_clock_vs_message_time | new_inquiry | new_inquiry | LLM | 1 | 706 | 3730 | 317 | True | The current rate needs checking for that container size before I can confirm whether it is lower. | PASS |

## Stage metrics (MEASURED)

system chars and ctx chars are measured AT THE MODEL BOUNDARY by the fake Invoke-LLM stub, not estimated.

| id | scenario | model calls (want) | stub calls (want) | rewrites | ctx chars | sys chars | request chars | guidance chars | order confident | order reason | wall ms |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 01_cargo_received_query | delivery_status | 1 (1) | 1 (1) | 0 | 749 | 3925 | 4674 | 508 | True | timestamps-monotonic-ascending | 64 |
| 02_address_ambiguous | address_clarify | 0 (0) | 1 (1) | 0 | 787 | 3811 | 4598 | 394 | True | timestamps-monotonic-ascending | 20 |
| 03_supplier_handoff_failure | supplier_unreachable | 1 (1) | 1 (1) | 0 | 841 | 3835 | 4676 | 413 | True | timestamps-monotonic-ascending | 5 |
| 04_human_requested | human_requested | 1 (1) | 1 (1) | 0 | 789 | 3918 | 4707 | 501 | True | timestamps-monotonic-ascending | 10 |
| 05_repeated_chasing | delivery_status | 2 (2) | 2 (2) | 1 | 805 | 3925 | 4730 | 508 | True | timestamps-monotonic-ascending | 30 |
| 06_angry_buyer | complaint | 1 (1) | 2 (2) | 1 | 818 | 4018 | 4836 | 607 | True | timestamps-monotonic-ascending | 7 |
| 07_unknown_quote | new_inquiry | 1 (1) | 1 (1) | 0 | 620 | 3730 | 4350 | 317 | True | single-message | 4 |
| 08_dimensions_already_given | details_given | 1 (1) | 1 (1) | 0 | 784 | 4352 | 5136 | 937 | True | timestamps-monotonic-ascending | 3 |
| 09_material_promised | material_promised | 0 (0) | 1 (1) | 0 | 887 | 3845 | 4732 | 426 | True | timestamps-monotonic-ascending | 10 |
| 10_simple_acknowledgement | short_ack | 1 (1) | 1 (1) | 0 | 677 | 3792 | 4469 | 381 | True | timestamps-monotonic-ascending | 3 |
| 11_image_only_message | attachment_only | 1 (1) | 1 (1) | 0 | 662 | 3818 | 4480 | 401 | True | timestamps-monotonic-ascending | 3 |
| 12_file_parse_failure | details_given | 2 (2) | 2 (2) | 1 | 623 | 4352 | 4975 | 937 | True | timestamps-monotonic-ascending | 12 |
| 13_several_short_messages | short_ack | 1 (1) | 1 (1) | 0 | 637 | 3792 | 4429 | 381 | True | timestamps-monotonic-ascending | 5 |
| 14_same_text_new_message | delivery_status | 1 (1) | 1 (1) | 0 | 777 | 3925 | 4702 | 508 | True | timestamps-monotonic-ascending | 5 |
| 15_human_already_answered | short_ack | 1 (1) | 1 (1) | 0 | 757 | 3792 | 4549 | 381 | True | timestamps-monotonic-ascending | 5 |
| 16_notification_failure | delivery_status | 0 (0) | 1 (1) | 0 | 821 | 3925 | 4746 | 508 | True | timestamps-monotonic-ascending | 7 |
| 17_quote_ready_query | quote_ready_query | 2 (2) | 2 (2) | 1 | 690 | 3795 | 4485 | 376 | True | timestamps-monotonic-ascending | 10 |
| 18_reverse_dom_order | delivery_status | 1 (1) | 1 (1) | 0 | 855 | 3925 | 4780 | 508 | True | timestamps-monotonic-descending | 3 |
| 19_two_char_refusal | refusal | 1 (1) | 1 (1) | 0 | 603 | 3732 | 4335 | 323 | True | timestamps-monotonic-ascending | 3 |
| 20_render_clock_vs_message_time | new_inquiry | 1 (1) | 1 (1) | 0 | 706 | 3730 | 4436 | 317 | True | timestamps-monotonic-descending | 5 |

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

None.

## Informational probes

- 12_file_parse_failure / forced-attachment-parse-failed-fallback: scenario=attachment_parse_failed -> I could not open the attachment. Could you share the total weight?
- 16_notification_failure / notify-channel-verified-allows-deadline: scenario=delivery_status -> Thanks for checking in. I do not want to give you a guess, so I am confirming the current status with the warehouse and will come back to you by tomorrow morning.


