$env:AAR_TEST_LAYER='Offline'
. ./scripts/lib/msg_norm.ps1
. ./scripts/lib/reply_policy.ps1
. ./scripts/lib/reply_gen.ps1
. ./scripts/lib/seller_context.ps1
$p=Get-SellerProfile -Config ('{"seller_profile":{"timezone":"Asia/Shanghai"}}'|ConvertFrom-Json)
$rt=New-ReplyRuntimeContext -SellerProfile $p -NowUtc ([datetime]::SpecifyKind([datetime]'2026-10-05T18:05:00',[DateTimeKind]::Utc))
$c=ConvertTo-MessageList '[BUYER] What time is it now? @@MT:1791172800000' Fixture
$d=Get-ReplyDecision -Conversation $c -Facts (Get-ConversationFacts $c) -RuntimeContext $rt
$d.DirectFactText
$d.TimeExpectations|ConvertTo-Json -Depth 5
Get-OutputTimeClaims $d.DirectFactText|ConvertTo-Json -Depth 5
(Test-ReplyCompliance $d.DirectFactText -Decision $d).Violations|ConvertTo-Json -Depth 5