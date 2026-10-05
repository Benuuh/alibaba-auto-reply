# tests\second_fix_policy.tests.ps1 - 八项补修纯逻辑层回归（F5 供应商身份 / F6 时间目标 / F8 字段澄清）
#
# 依据：docs\specs\架构交付复核八项补修_spec_20261005.md §5 / §7 / §9，
#   输入逐条对应 docs\verification\architecture_opt_20261005\review_fixes\independent_review_20261005
#   的独立探针（供应商键冲突 / 时间决策 / 字段免检），本文件把它们转为正式回归。
#
# 分层：pure（不访问浏览器/模型/通知/生产路径）。F1 的联系方式输入在 second_fix_contact.tests.ps1，
#   F3 的暂停输入在 human_pause.tests.ps1，F2/F4/F6 的真实入口输入在 review_fixes_entry.tests.ps1。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\msg_norm.ps1')
. (Join-Path $scripts 'lib\reply_policy.ps1')
. (Join-Path $scripts 'lib\reply_gen.ps1')
. (Join-Path $scripts 'lib\seller_context.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')
. (Join-Path $scripts 'lib\human_tasks.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }
function Codes($r) { return (@($r.Violations | ForEach-Object { $_.Code }) -join ',') }

Write-Output '== second_fix policy tests (F5 / F6 / F8) =='

$LF = [string][char]10
function B64([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function BLine([string]$t, [long]$ts) { return ('[BUYER] ' + $t + ' @@TS:' + $ts + ' @@MT:' + $ts + ' @@OT:' + (B64 $t)) }

$utcNow = [datetime]::SpecifyKind([datetime]'2026-10-05T06:05:00', [DateTimeKind]::Utc)
$ts = ([System.DateTimeOffset]$utcNow).ToUnixTimeMilliseconds()
$P_FULL = '{"seller_profile":{"company_name_en":"Harbor Freight Management Co., Ltd.","assistant_display_name_en":"Taylor Reed","company_name_verified":true,"assistant_display_name_verified":true,"timezone":"Asia/Shanghai"}}'
$profile = Get-SellerProfile -Config ($P_FULL | ConvertFrom-Json)
$runtime = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc $utcNow

function Decide([string[]]$lines, $rt = $null) {
    if (-not $rt) { $rt = $runtime }
    $conv = ConvertTo-MessageList (($lines -join $LF)) 'Virtual Buyer'
    return (Get-ReplyDecision -Conversation $conv -Facts (Get-ConversationFacts $conv) -Rules $null -RuntimeContext $rt)
}

# =============================================================================================
# F6 时间目标（§7.1 / §7.2）
# =============================================================================================
# 业务位置位于时间问题**之前**：目标仍是中国（旧实现在这里截成空后退回整段文本，答成东京）。
$f6a = Decide @((BLine 'My company is in Tokyo, what time is it in China?' $ts))
Eq 'F6-business-before-question-place' ([string]$f6a.RequestedPlace) 'China'
Eq 'F6-business-before-question-state' ([string]$f6a.TimeTargets[0].State) 'explicit_resolved'
Check 'F6-business-before-question-answers-china' ([bool]([string]$f6a.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6a.DirectFactText)
Check 'F6-business-before-question-not-japan' (-not ([string]$f6a.DirectFactText -match 'Japan')) ([string]$f6a.DirectFactText)

# 句号分隔（口语/大小写变体）：显式中国仍然是 explicit，不能碰巧用卖家默认。
$f6b = Decide @((BLine 'My company is in Tokyo. what time is it in China?' $ts))
Eq 'F6-lowercase-sentence-place' ([string]$f6b.RequestedPlace) 'China'
Eq 'F6-lowercase-sentence-state' ([string]$f6b.TimeTargets[0].State) 'explicit_resolved'
Check 'F6-lowercase-sentence-answers-china' ([bool]([string]$f6b.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6b.DirectFactText)

# 问题前后的供应商/仓库位置都不能覆盖时间目标。
foreach ($pair in @(
    @{ q = 'What time is it in China? Our supplier is in Tokyo.'; want = 'China' },
    @{ q = 'What time is it in China? The warehouse is in Hamburg.'; want = 'China' },
    @{ q = 'Our supplier is in Tokyo, what time is it in China?'; want = 'China' },
    @{ q = 'What time is it in China? We are shipping to Tokyo.'; want = 'China' })) {
    $d = Decide @((BLine $pair.q $ts))
    Eq ('F6-business-place-ignored [' + $pair.q + ']') ([string]$d.RequestedPlace) $pair.want
    Check ('F6-business-place-answers-china [' + $pair.q + ']') ([bool]([string]$d.DirectFactText -match "It's 2:05 PM in China")) ([string]$d.DirectFactText)
}

# 原先"先问 China、后说明 Tokyo 公司"必须继续正确。
$f6c = Decide @((BLine 'What time is it in China? My company is in Tokyo.' $ts))
Eq 'F6-question-before-business-place' ([string]$f6c.RequestedPlace) 'China'
Check 'F6-question-before-business-answers-china' ([bool]([string]$f6c.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6c.DirectFactText)

# 两个时间问题：两个目标都在列表里，且都被回答（旧实现只答第一个，静默漏答东京）。
$f6d = Decide @((BLine 'What time is it in China? What time is it in Tokyo?' $ts))
Eq 'F6-two-questions-two-requests' (@($f6d.TimeRequests).Count) 2
Eq 'F6-two-questions-two-targets' (@($f6d.TimeTargets).Count) 2
Check 'F6-two-questions-answers-china' ([bool]([string]$f6d.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6d.DirectFactText)
Check 'F6-two-questions-answers-tokyo' ([bool]([string]$f6d.DirectFactText -match "It's 3:05 PM in Tokyo")) ([string]$f6d.DirectFactText)
Check 'F6-two-questions-passes-own-check' ([bool](Test-ReplyCompliance -Text ([string]$f6d.DirectFactText) -Rules $null -Decision $f6d).Ok) ''

# 同问句多个时间地点：两个目标都保留。
$f6e = Decide @((BLine 'What time is it in China and in Tokyo?' $ts))
Eq 'F6-one-question-two-places' (@($f6e.TimeTargets).Count) 2
Check 'F6-one-question-answers-both' ([bool](([string]$f6e.DirectFactText -match "2:05 PM in China") -and ([string]$f6e.DirectFactText -match "3:05 PM in Tokyo"))) ([string]$f6e.DirectFactText)

# 分消息多个问题：消息边界保留。
$f6f = Decide @((BLine 'What time is it in China?' $ts), (BLine 'And what time is it in Tokyo?' ($ts + 1000)))
Eq 'F6-multi-message-two-requests' (@($f6f.TimeRequests).Count) 2
Check 'F6-multi-message-answers-both' ([bool](([string]$f6f.DirectFactText -match 'China') -and ([string]$f6f.DirectFactText -match 'Tokyo'))) ([string]$f6f.DirectFactText)
Eq 'F6-multi-message-distinct-message-ids' (@($f6f.TimeRequests | ForEach-Object { [string]$_.MessageId } | Select-Object -Unique).Count) 2

# 每个请求都带 RequestId / MessageId / QuestionSpan / 状态 / 时区。
$req = @($f6f.TimeRequests)[0]
Check 'F6-request-has-id' ([bool]([string]$req.RequestId)) ''
Check 'F6-request-has-message-id' ([bool]([string]$req.MessageId)) ''
Check 'F6-request-has-span' ($null -ne $req.QuestionSpan) ''
Check 'F6-target-has-timezone' ([bool]([string](@($f6f.TimeTargets)[0].TimeZone))) ([string](@($f6f.TimeTargets)[0].TimeZone))
Eq 'F6-target-timezone-value' ([string](@($f6f.TimeTargets)[0].TimeZone)) 'Asia/Shanghai'

# 已解析目标 + 多时区国家：可靠目标正确，未解析目标逐项澄清，绝不默认中国。
$f6g = Decide @((BLine 'What time is it in China and in Australia?' $ts))
Eq 'F6-mixed-targets-count' (@($f6g.TimeTargets).Count) 2
Eq 'F6-mixed-targets-resolved-state' ([string](@($f6g.TimeTargets)[0].State)) 'explicit_resolved'
Eq 'F6-mixed-targets-unresolved-state' ([string](@($f6g.TimeTargets)[1].State)) 'explicit_unresolved'
Eq 'F6-mixed-targets-unresolved-reason' ([string](@($f6g.TimeTargets)[1].Reason)) 'ambiguous-multiple-time-zones'
Check 'F6-mixed-targets-answers-china' ([bool]([string]$f6g.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6g.DirectFactText)
Check 'F6-mixed-targets-clarifies-australia' ([bool]([string]$f6g.DirectFactText -match 'Which city or time zone in Australia')) ([string]$f6g.DirectFactText)
Check 'F6-mixed-targets-pass-own-check' ([bool](Test-ReplyCompliance -Text ([string]$f6g.DirectFactText) -Rules $null -Decision $f6g).Ok) ''

# 未知地名：明确指定但解析不了 ⇒ 逐项澄清，不退回中国。
$f6h = Decide @((BLine 'What time is it in Atlantis?' $ts))
Eq 'F6-unknown-place-state' ([string]$f6h.TimeTargets[0].State) 'explicit_unresolved'
Check 'F6-unknown-place-clarifies' ([bool]([string]$f6h.DirectFactText -match 'Which country or time zone')) ([string]$f6h.DirectFactText)
Check 'F6-unknown-place-no-clock' (-not ([string]$f6h.DirectFactText -match '\d{1,2}:\d{2}')) ([string]$f6h.DirectFactText)

# 原规则保持：小写地名、东京口语变体、there / here / local time。
foreach ($q in @('What time is it in hamburg?', 'What time is it now in Tokyo?', 'What time is it in Tokyo now?', "What's the current time in Tokyo?")) {
    $d = Decide @((BLine $q $ts))
    Check ('F6-variant-keeps-place [' + $q + ']') ([bool]([string]$d.RequestedPlace -match '(?i)hamburg|tokyo')) ([string]$d.RequestedPlace)
}
foreach ($q in @('what time is it here?', 'what is my local time')) {
    $d = Decide @((BLine $q $ts))
    Eq ('F6-here-kind [' + $q + ']') ([string]$d.RequestedPlaceKind) 'unknown'
    Check ('F6-here-clarify [' + $q + ']') ([bool]([string]$d.DirectFactText -match 'Which country or time zone')) ([string]$d.DirectFactText)
}
$f6i = Decide @((BLine 'What time is it now? My company is in Tokyo.' $ts))
Eq 'F6-unspecified-answers-seller-zone' ([string]$f6i.TimeTargets[0].State) 'unspecified'
Check 'F6-unspecified-seller-clock' ([bool]([string]$f6i.DirectFactText -match "It's 2:05 PM in China")) ([string]$f6i.DirectFactText)

# 正文错误/漏答第二个目标：发送前检查必须阻断（正确前缀不能掩盖错误正文）。
$f6j = Decide @((BLine 'What time is it in China? What time is it in Tokyo?' $ts))
$dropSecond = "It's 2:05 PM in China (UTC+8)."
Check 'F6-dropped-target-blocked' (-not (Test-ReplyCompliance -Text $dropSecond -Rules $null -Decision $f6j).Ok) (Codes (Test-ReplyCompliance -Text $dropSecond -Rules $null -Decision $f6j))
Check 'F6-dropped-target-code' ([bool]((Codes (Test-ReplyCompliance -Text $dropSecond -Rules $null -Decision $f6j)) -match 'FACT_TIME_TARGET_UNANSWERED')) (Codes (Test-ReplyCompliance -Text $dropSecond -Rules $null -Decision $f6j))
$wrongBody = "It's 2:05 PM in China (UTC+8). It's 9:40 AM in Japan (UTC+9)."
Check 'F6-wrong-second-clock-blocked' (-not (Test-ReplyCompliance -Text $wrongBody -Rules $null -Decision $f6j).Ok) (Codes (Test-ReplyCompliance -Text $wrongBody -Rules $null -Decision $f6j))
# 未解析目标被静默丢掉（只答可靠目标）也要阻断。
$f6k = Decide @((BLine 'What time is it in China and in Australia?' $ts))
$dropUnresolved = "It's 2:05 PM in China (UTC+8)."
Check 'F6-dropped-unresolved-target-blocked' (-not (Test-ReplyCompliance -Text $dropUnresolved -Rules $null -Decision $f6k).Ok) (Codes (Test-ReplyCompliance -Text $dropUnresolved -Rules $null -Decision $f6k))
Check 'F6-dropped-unresolved-code' ([bool]((Codes (Test-ReplyCompliance -Text $dropUnresolved -Rules $null -Decision $f6k)) -match 'FACT_TIME_TARGET_UNCLARIFIED')) (Codes (Test-ReplyCompliance -Text $dropUnresolved -Rules $null -Decision $f6k))
# 生成后时间/请求变化：用新时钟重新决策，直接事实答案随之刷新（同一份目标列表 + 新鲜时钟）。
$laterUtc = $utcNow.AddMinutes(37)
$laterRuntime = New-ReplyRuntimeContext -SellerProfile $profile -NowUtc $laterUtc
$f6l = Decide @((BLine 'What time is it in China?' $ts)) $laterRuntime
Check 'F6-fresh-clock-renders-fresh-time' ([bool]([string]$f6l.DirectFactText -match "It's 2:42 PM in China")) ([string]$f6l.DirectFactText)
Check 'F6-fresh-clock-passes-own-check' ([bool](Test-ReplyCompliance -Text ([string]$f6l.DirectFactText) -Rules $null -Decision $f6l).Ok) ''

# 混合公司名 + 时间：身份内容不漏答。
$f6m = Decide @((BLine "What's the name of your company? And what time is it in Tokyo?" $ts))
Check 'F6-mixed-request-keeps-company' ([bool]([string]$f6m.DirectFactText -match 'Harbor Freight')) ([string]$f6m.DirectFactText)
Check 'F6-mixed-request-keeps-time' ([bool]([string]$f6m.DirectFactText -match '3:05 PM in Tokyo')) ([string]$f6m.DirectFactText)

# =============================================================================================
# F8 字段澄清必须有证据（§9.1 / §9.2）
# =============================================================================================
$weightOnly = [pscustomobject]@{ AskFields = @('weight'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
Check 'F8-authorized-unit-ask-passes' ([bool](Test-ReplyCompliance -Text 'Could you share the packed weight per carton?' -Rules $null -Decision $weightOnly).Ok) (Codes (Test-ReplyCompliance -Text 'Could you share the packed weight per carton?' -Rules $null -Decision $weightOnly))
$askCount = Test-ReplyCompliance -Text 'Could you share the carton count?' -Rules $null -Decision $weightOnly
Check 'F8-plain-count-ask-blocked' (-not $askCount.Ok) (Codes $askCount)
Check 'F8-plain-count-code' ([bool]((Codes $askCount) -match 'ASK_OUT_OF_SCOPE')) (Codes $askCount)
# 定语从句不再免检：which / whose / is this / do you mean 都只是语气线索。
foreach ($t in @(
    'Could you share the carton count, which we need for the quote?',
    'Could you share the carton count, whose number we need?',
    'Is this the carton count you need from me?',
    'Do you mean you need the carton count?')) {
    $c = Test-ReplyCompliance -Text $t -Rules $null -Decision $weightOnly
    Check ('F8-relative-clause-not-exempt [' + $t + ']') (-not $c.Ok) (Codes $c)
    Check ('F8-relative-clause-code [' + $t + ']') ([bool]((Codes $c) -match 'ASK_OUT_OF_SCOPE|ASK_ALREADY_PROVIDED')) (Codes $c)
}
# 已提供的字段重复索取仍然阻断（没有相关澄清证据）。
$providedFacts = [pscustomobject]@{
    HasQuantity = $true
    CargoFacts = [pscustomobject]@{ ByKey = @{ carton_count = [pscustomobject]@{ Status = 'provided'; Label = '件数（箱/托盘）' } } }
}
$providedDecision = [pscustomobject]@{ AskFields = @(); Facts = $providedFacts; RequestedFacts = @(); ActionEvidence = $null }
$reask = Test-ReplyCompliance -Text 'Could you confirm the carton count?' -Rules $null -Decision $providedDecision
Check 'F8-reask-provided-blocked' (-not $reask.Ok) (Codes $reask)
Check 'F8-reask-provided-code' ([bool]((Codes $reask) -match 'ASK_ALREADY_PROVIDED')) (Codes $reask)
# 真实澄清（结构化冲突证据 + 澄清句式）允许；同一句里的未授权箱数索取仍然阻断。
# [2026-10-05 第三轮 spec §7.1 / §11.1 第 3 条] 仅伪造 Status=conflict 而没有候选/来源的旧夹具已不足：
#   候选必须来自唯一事实模型（Conflicts.Candidates 带值/单位/范围/来源）。这里按真实冲突的形态补全夹具，
#   业务断言不放宽：编造候选（999/1000）仍然必须被拦。
$conflictFacts = [pscustomobject]@{
    CargoFacts = [pscustomobject]@{
        ByKey = @{ carton_count = [pscustomobject]@{ Status = 'conflict'; Value = ''; Unit = 'cartons'; Scope = 'cartons'; Label = '件数（箱/托盘）'; Evidence = @([pscustomobject]@{ Source = 'buyer'; MessageId = 'msg-2' }) } }
        Conflicts = @(@{
            Key = 'carton_count'
            Values = @(20, 24)
            Candidates = @(
                @{ Value = '20'; Unit = 'cartons'; Scope = 'cartons'; SourceRefs = @('message:msg-1') },
                @{ Value = '24'; Unit = 'cartons'; Scope = 'cartons'; SourceRefs = @('message:msg-2') }
            )
        })
    }
}
$conflictDecision = [pscustomobject]@{ AskFields = @(); Facts = $conflictFacts; RequestedFacts = @(); ActionEvidence = $null
                                      ClarifyFields = @('carton_count') }
$clarify = Test-ReplyCompliance -Text 'Which carton count is correct - 20 per carton or 24?' -Rules $null -Decision $conflictDecision
Check 'F8-real-clarification-allowed' ([bool]$clarify.Ok) (Codes $clarify)
$mixedClause = Test-ReplyCompliance -Text 'Which carton count is correct, and could you also share the carton count in the packing list?' -Rules $null -Decision $conflictDecision
Check 'F8-clarify-plus-unauthorized-ask-blocked' (-not $mixedClause.Ok) (Codes $mixedClause)
# 没有结构化证据时，同样的澄清句式也不得放行。
$noEvidence = [pscustomobject]@{ AskFields = @('weight'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
$noEvidenceCheck = Test-ReplyCompliance -Text 'Which carton count is correct - 20 or 24?' -Rules $null -Decision $noEvidence
Check 'F8-clarify-without-evidence-blocked' (-not $noEvidenceCheck.Ok) (Codes $noEvidenceCheck)
# 单位修饰语仍不是件数请求（每箱/每托盘的重量与尺寸）。
$weightDim = [pscustomobject]@{ AskFields = @('weight', 'dimension'); Facts = $null; RequestedFacts = @(); ActionEvidence = $null }
$unitMod = Test-ReplyCompliance -Text 'Could you share the packed dimensions per carton or pallet (L x W x H)?' -Rules $null -Decision $weightDim
Check 'F8-unit-modifier-not-count' ([bool]$unitMod.Ok) (Codes $unitMod)
# 地址澄清：场景本身授权 delivery_address（address_clarify 回退话术必须仍然合规）。
$addressConv = ConvertTo-MessageList (BLine 'Can you quote 10 cartons to Hamburg?' $ts) 'Virtual Buyer'
$addressFacts = Get-ConversationFacts $addressConv
$addressDecision = Get-ReplyDecision -Conversation $addressConv -Facts $addressFacts -ForceScenario 'address_clarify'
Check 'F8-address-clarify-scenario-authorises-field' (@($addressDecision.ClarifyFields) -contains 'delivery_address') (@($addressDecision.ClarifyFields) -join ',')
$addressFallback = Get-ScenarioFallback -Decision $addressDecision
Check 'F8-address-clarify-fallback-compliant' ([bool](Test-ReplyCompliance -Text $addressFallback -Rules $null -Decision $addressDecision).Ok) (Codes (Test-ReplyCompliance -Text $addressFallback -Rules $null -Decision $addressDecision))

# =============================================================================================
# F5 供应商身份按实际联系人（§5.1）
# =============================================================================================
Eq 'F5-same-domain-one' (Get-SupplierTaskKey -SupplierContact 'factory-one@mail.example.invalid') 'email:factory-one@mail.example.invalid'
Eq 'F5-same-domain-two' (Get-SupplierTaskKey -SupplierContact 'factory-two@mail.example.invalid') 'email:factory-two@mail.example.invalid'
Check 'F5-same-domain-keys-differ' ((Get-SupplierTaskKey -SupplierContact 'factory-one@mail.example.invalid') -ne (Get-SupplierTaskKey -SupplierContact 'factory-two@mail.example.invalid')) ''
Check 'F5-domain-alone-is-not-an-identity' (-not ((Get-SupplierTaskKey -SupplierContact 'factory-one@mail.example.invalid') -match '^email-domain:')) ''
Eq 'F5-different-domains' (Get-SupplierTaskKey -SupplierContact 'ops@other.example.net') 'email:ops@other.example.net'
Eq 'F5-case-and-space-normalised' (Get-SupplierTaskKey -SupplierContact '  FACTORY-One@Mail.Example.INVALID ') 'email:factory-one@mail.example.invalid'
Eq 'F5-phone-key-from-digits' (Get-SupplierTaskKey -SupplierContact '+86 138-0000-0000') 'phone:8613800000000'
Check 'F5-short-number-is-not-a-phone' ((Get-SupplierTaskKey -SupplierContact 'ext 12') -notmatch '^phone:') ''
Eq 'F5-name-fallback' (Get-SupplierTaskKey -SupplierContact '' -SupplierName 'Delta Components') 'name:delta components'
Eq 'F5-unknown-fallback' (Get-SupplierTaskKey -SupplierContact '') 'supplier-identity-unknown'
Eq 'F5-explicit-supplier-id-wins' (Get-SupplierTaskKey -SupplierContact 'factory-one@mail.example.invalid' -SupplierId 'SUP-42') 'supplier-id:sup-42'
$idEmail = Get-SupplierIdentity -SupplierContact 'Factory-One@Mail.Example.Invalid'
Eq 'F5-identity-kind' ([string]$idEmail.Kind) 'email'
Eq 'F5-identity-confidence' ([string]$idEmail.Confidence) 'full-contact'
Eq 'F5-identity-keeps-raw-contact' ([string]$idEmail.Raw) 'Factory-One@Mail.Example.Invalid'

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
