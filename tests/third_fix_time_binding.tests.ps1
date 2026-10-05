# tests\third_fix_time_binding.tests.ps1 - R6：每个时间声明绑定地点/时区/时刻，逐目标检查覆盖（spec §8 / §10.4）
#
# 失败基线（edge_probes.txt）：注入 UTC 04:00 时，错误正文
#   "It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9)." 被完整检查放行，
#   因为两个数值都在 expectedValues 集合里 —— 数值集合授权已在本轮删除，改为逐目标身份绑定。
#
# 分层：pure（注入时钟，不读系统时间、不联网、不发送）。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }
function HasCode($r, [string]$code) { return (@($r.Violations | Where-Object { $_.Code -eq $code }).Count -gt 0) }
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }
$LF = [string][char]10

Write-Output '== third_fix time binding tests (R6) =='

$utc = [datetime]::SpecifyKind([datetime]'2026-10-05T04:00:00', [DateTimeKind]::Utc)
$ts = ([System.DateTimeOffset]$utc).ToUnixTimeMilliseconds()
$P = '{"seller_profile":{"company_name_en":"Example Freight","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$profile = Get-SellerProfile -Config ($P | ConvertFrom-Json)
$rt = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc $utc
function Decide([string]$q, $rtc = $null) {
    if (-not $rtc) { $rtc = $rt }
    $conv = ConvertTo-MessageList (BLine $q $ts) 'Virtual Buyer'
    return (Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -Rules $null -RuntimeContext $rtc)
}
function Chk([string]$text, $dec) { return (Test-ReplyCompliance -Text $text -Rules $null -Decision $dec) }

$decCNJP = Decide 'What time is it in China? What time is it in Tokyo?'

# ---- T01 原输入：China 1:00 PM / Japan 12:00 PM 互换 => 完整检查阻断 ----
$t01 = Chk "It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9)." $decCNJP
Check 'T01-swapped-clock-blocked' (-not $t01.Ok) (Codes $t01)
Check 'T01-code-mismatch' (HasCode $t01 'FACT_TIME_MISMATCH') (Codes $t01)
# 每个目标正确的表达仍然通过（同钟点/同 offset 的不同点名地点不能靠相等关系合并）。
Check 'T01-correct-answer-passes' ([bool](Chk "It's 12:00 PM in China (UTC+8). It's 1:00 PM in Tokyo (UTC+9)." $decCNJP).Ok) ''

# ---- T02 正确程序前缀 + 错误正文（真实生成入口）=> 最终不能出现错误正文 ----
$script:modelQueue = New-Object System.Collections.ArrayList
[void]$script:modelQueue.Add("It's 12:00 PM in China (UTC+8). It's 1:00 PM in Japan (UTC+9). It's 1:00 PM in China (UTC+8). It's 12:00 PM in Japan (UTC+9). Happy to help with the rate.")
[void]$script:modelQueue.Add('Thanks - the rate depends on the packed weight and carton sizes.')
$script:modelCalls = 0
function Invoke-LLM {
    param($Messages, $Temperature, $MaxTokens, $LogFile)
    $script:modelCalls++
    if ($script:modelQueue.Count -gt 0) { $r = [string]$script:modelQueue[0]; $script:modelQueue.RemoveAt(0); return $r }
    return ''
}
$convT02 = ConvertTo-MessageList (BLine 'What time is it in China? What time is it in Tokyo? I also need a quote.' $ts) 'Virtual Buyer'
$factsT02 = Get-ConversationFacts $convT02
$decT02 = Get-ReplyDecision -Conversation $convT02 -Facts $factsT02 -Rules $null -RuntimeContext $rt
$genT02 = Invoke-ReplyGeneration -Conversation $convT02 -Decision $decT02 -Rules $null -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -MaxRewrites 1 -RuntimeContext $rt
Check 'T02-final-text-has-no-swapped-clock' (-not ([string]$genT02.Text -match '1:00 PM in China')) ([string]$genT02.Text)
Check 'T02-final-text-has-no-wrong-japan-clock' (-not ([string]$genT02.Text -match '12:00 PM in Japan')) ([string]$genT02.Text)
Check 'T02-model-calls-bounded' ([bool]($script:modelCalls -le 2)) ([string]$script:modelCalls)
Check 'T02-final-text-passes-own-check' ([bool](Chk ([string]$genT02.Text) $decT02).Ok) (Codes (Chk ([string]$genT02.Text) $decT02))

# ---- T03 China + Singapore 同钟点：只答 China 判漏答；两地都明确回答合法 ----
$decCNSG = Decide 'What time is it in China? What time is it in Singapore?'
$t03a = Chk "It's 12:00 PM in China (UTC+8)." $decCNSG
Check 'T03-same-clock-other-place-unanswered' (-not $t03a.Ok) (Codes $t03a)
Check 'T03-code-unanswered' (HasCode $t03a 'FACT_TIME_TARGET_UNANSWERED') (Codes $t03a)
$t03b = Chk "It's 12:00 PM in China (UTC+8). It's 12:00 PM in Singapore (UTC+8)." $decCNSG
Check 'T03-both-places-answered-passes' ([bool]$t03b.Ok) (Codes $t03b)

# ---- T04 正确钟点但 offset 错 / 地点错 / 无法绑定的裸时刻 => 阻断 ----
$t04a = Chk "It's 12:00 PM in China (UTC+9)." $decCNSG
Check 'T04-wrong-offset-blocked' (-not $t04a.Ok) (Codes $t04a)
$t04b = Chk "It's 12:00 PM in Singapore (UTC+8)." $decCNSG
Check 'T04-wrong-place-only-blocked' (-not $t04b.Ok) (Codes $t04b)
$t04c = Chk "It's 3:00 PM in China (UTC+8)." $decCNSG
Check 'T04-unrelated-clock-blocked' (-not $t04c.Ok) (Codes $t04c)

# ---- T05 Atlantis + Elbonia：只澄清 Atlantis 判另一目标未澄清 ----
$decAtlElb = Decide 'What time is it in Atlantis? What time is it in Elbonia?'
$t05 = Chk 'Which city or time zone do you mean for Atlantis?' $decAtlElb
Check 'T05-one-of-two-unknowns-unclarified' (-not $t05.Ok) (Codes $t05)
Check 'T05-code-unclarified' (HasCode $t05 'FACT_TIME_TARGET_UNCLARIFIED') (Codes $t05)

# ---- T06 只写一句地名陈述不算时间澄清 ----
$decAtl = Decide 'What time is it in Atlantis?'
$t06 = Chk 'The shipment is going to Atlantis.' $decAtl
Check 'T06-plain-place-statement-blocked' (-not $t06.Ok) (Codes $t06)
Check 'T06-code-unclarified' (HasCode $t06 'FACT_TIME_TARGET_UNCLARIFIED') (Codes $t06)
# 程序受控澄清（前一句点名地点 + 明确的时间地点问题）继续合法。
Check 'T06-program-clarification-passes' ([bool](Chk ([string]$decAtl.DirectFactText) $decAtl).Ok) ([string]$decAtl.DirectFactText)

# ---- T07 两个未知地名共同出现在明确的时间澄清问题里 => 合法 ----
$t07 = Chk 'Which city or time zone do you mean for Atlantis or Elbonia?' $decAtlElb
Check 'T07-both-unknowns-listed-passes' ([bool]$t07.Ok) (Codes $t07)

# ---- T08 同地点别名重复可归并；同时区两个不同点名城市需明确覆盖 ----
$decRepeat = Decide 'What time is it in China? What time is it in China?'
$t08a = Chk "It's 12:00 PM in China (UTC+8)." $decRepeat
Check 'T08-repeated-same-place-merged' ([bool]$t08a.Ok) (Codes $t08a)
$t08b = Chk "It's 12:00 PM in China (UTC+8)." $decCNSG
Check 'T08-same-zone-different-cities-not-merged' (-not $t08b.Ok) (Codes $t08b)

# ---- T09 生成后跨分钟：新鲜时钟重新渲染 + 与业务正文重新组合（不叠加旧答案） ----
$laterUtc = $utc.AddMinutes(37)
$laterRt = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc $laterUtc
$decLate = Decide 'What time is it in China?' $laterRt
Check 'T09-fresh-clock-rendered' ([bool]([string]$decLate.DirectFactText -match "It's 12:37 PM in China")) ([string]$decLate.DirectFactText)
$businessBody = 'Happy to quote once you confirm the delivery address.'
$recombined = Join-FactPrefix ([string]$decLate.DirectFactText) $businessBody
Check 'T09-recomposition-uses-new-clock-only' (([bool]($recombined -match '12:37 PM')) -and (-not ($recombined -match '12:00 PM'))) $recombined
# 身份事实（公司/姓名）与时间同轮时，重新组合不丢身份答案。
$decMix = Decide "What's the name of your company? And what time is it in Tokyo?" $laterRt
Check 'T09-mixed-keeps-company-answer' ([bool]([string]$decMix.DirectFactText -match 'Example Freight')) ([string]$decMix.DirectFactText)
Check 'T09-mixed-keeps-fresh-time' ([bool]([string]$decMix.DirectFactText -match '1:37 PM in Tokyo')) ([string]$decMix.DirectFactText)

# ---- T10 业务地点前/后、多消息、大小写、there/here、多时区国家、身份混问 ----
foreach ($q in @(
    'My company is in Tokyo, what time is it in China?',
    'What time is it in China? The warehouse is in Hamburg.',
    'What time is it in hamburg?',
    'What time is it now? My company is in Tokyo.'
)) {
    $d = Decide $q
    Check ('T10-scope-stable [' + $q + ']') ([bool](Chk ([string]$d.DirectFactText) $d).Ok) (Codes (Chk ([string]$d.DirectFactText) $d))
}
$decMulti = Decide 'What time is it in China?'
$d10 = Decide 'What time is it in China? What time is it in Australia?'
Check 'T10-multi-zone-country-clarified' ([bool](Chk ([string]$d10.DirectFactText) $d10).Ok) ([string]$d10.DirectFactText)
foreach ($q in @('what time is it here?', 'what is my local time')) {
    $d = Decide $q
    Check ('T10-buyer-local-clarified [' + $q + ']') ([bool](Chk ([string]$d.DirectFactText) $d).Ok) ([string]$d.DirectFactText)
}

# ---- T11 客户已有预约时间/运输时长 vs 当前时间：区分事实类别 ----
$decBusiness = Decide 'What time is it in China? My warehouse booking is at 3:00 PM and transit time is 12 days.'
Check 'T11-business-time-not-current-clock' ([bool](Chk "It's 12:00 PM in China (UTC+8). Your booking is at 3:00 PM." $decBusiness).Ok) (Codes (Chk "It's 12:00 PM in China (UTC+8). Your booking is at 3:00 PM." $decBusiness))
$t11b = Chk "It's 3:00 PM in China (UTC+8)." $decBusiness
Check 'T11-wrong-current-clock-still-blocked' (-not $t11b.Ok) (Codes $t11b)

# ---- T12 需要改稿时：不锁内调用模型、不超过一次重写，重新组合不误删身份答案 ----
$script:modelQueue.Clear()
[void]$script:modelQueue.Add("It's 9:40 AM in China (UTC+8). We're Example Freight.")
[void]$script:modelQueue.Add("We're Example Freight. Happy to help with the rate.")
$script:modelCalls = 0
$convT12 = ConvertTo-MessageList (BLine 'What time is it in China? Also, what is your company name?' $ts) 'Virtual Buyer'
$factsT12 = Get-ConversationFacts $convT12
$decT12 = Get-ReplyDecision -Conversation $convT12 -Facts $factsT12 -Rules $null -RuntimeContext $rt
$genT12 = Invoke-ReplyGeneration -Conversation $convT12 -Decision $decT12 -Rules $null -PromptPath (Join-Path $scripts 'reply_agent_prompt.md') -ScenarioPath (Join-Path $scripts 'reply_scenarios.md') -MaxRewrites 1 -RuntimeContext $rt
Check 'T12-at-most-one-rewrite' ([bool]($genT12.Rewrites -le 1)) ([string]$genT12.Rewrites)
Check 'T12-final-has-no-wrong-clock' (-not ([string]$genT12.Text -match '9:40')) ([string]$genT12.Text)
Check 'T12-final-keeps-company-answer' ([bool]([string]$genT12.Text -match 'Example Freight')) ([string]$genT12.Text)
Check 'T12-final-passes-own-check' ([bool](Chk ([string]$genT12.Text) $decT12).Ok) (Codes (Chk ([string]$genT12.Text) $decT12))
Check 'T12-composition-records-fact-fragments' ([bool]($genT12.Composition -and @($genT12.Composition.FactFragments).Count -gt 0)) ''

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
