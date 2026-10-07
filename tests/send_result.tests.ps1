# tests\send_result.tests.ps1 - 发送结果结构化与发送后核对（2026-10-05 spec §5-3）
#
# 纯逻辑：不联网、不开页、不发送。lib\send.ps1 只提供定义；页面出口 Invoke-SendEval 在下面被桩替换。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
. (Join-Path $scripts 'lib\send.ps1')

$LF = [string][char]10
$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== send_result tests =='

# ---- Test-TextMatchesSent 真值表（纯函数） ----
Check 'M-exact' (Test-TextMatchesSent -Expected 'Hello there, thanks!' -Actual 'Hello there, thanks!')
Check 'M-case-insensitive' (Test-TextMatchesSent -Expected 'Hello There' -Actual 'hello there')
Check 'M-whitespace-folded' (Test-TextMatchesSent -Expected ('Hello' + $LF + '  there') -Actual 'Hello there')
Check 'M-invisible-chars' (Test-TextMatchesSent -Expected 'Hello there' -Actual ('Hello' + [char]0x200B + ' there'))
Check 'M-prefix-rejected' (-not (Test-TextMatchesSent -Expected 'Thanks for the details, we will check the carton count and the packing weight before quoting.' -Actual 'Thanks for the details, we will check the carton count and the packing weight before quoting. [translated]'))
Check 'M-empty-actual-rejected' (-not (Test-TextMatchesSent -Expected 'Hi' -Actual ''))
Check 'M-empty-expected-rejected' (-not (Test-TextMatchesSent -Expected '' -Actual 'Hi'))
Check 'M-different-text-rejected' (-not (Test-TextMatchesSent -Expected 'We can ship by sea.' -Actual 'What is your best price?'))
Check 'M-short-prefix-not-enough' (-not (Test-TextMatchesSent -Expected 'Yes' -Actual 'Yesterday I sent it'))

# ---- Confirm-OneTalkOutboundMessage：页面返回解析（Invoke-SendEval 桩） ----
$script:probe = ''
function Invoke-SendEval([string]$js) { return $script:probe }
function Get-OutboundSnapshot {param([string]$Buyer = '')  $p=$script:probe|ConvertFrom-Json;if($p.lastIsMine){return @([pscustomobject]@{MessageId='new-event';MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$p.lastText;IsMine=$true})};return @()}
$script:probe = '{"rows":4,"lastIsMine":true,"lastText":"Could you share the consignee name and delivery address?"}'
$c1 = Confirm-OneTalkOutboundMessage -Before @() -buyer 'Buyer A' -text 'Could you share the consignee name and delivery address?'
Eq 'P-confirmed-status' $c1.Status 'confirmed'
Check 'P-confirmed-evidence' ($c1.Evidence -match 'new-platform-message-id') $c1.Evidence

$script:probe = '{"rows":4,"lastIsMine":false,"lastText":"ok thanks"}'
Eq 'P-buyer-last-is-absent' (Confirm-OneTalkOutboundMessage -Before @() -buyer 'Buyer A' -text 'Hello').Status 'unverified'

$script:probe = '{"rows":4,"lastIsMine":true,"lastText":"something else entirely"}'
Eq 'P-other-ours-is-absent' (Confirm-OneTalkOutboundMessage -Before @() -buyer 'Buyer A' -text 'Hello there').Status 'unverified'

$script:probe = 'not json'
Eq 'P-unparsable-is-unverified' (Confirm-OneTalkOutboundMessage -Before @() -buyer 'Buyer A' -text 'Hello').Status 'unverified'

$script:probe = ''
Eq 'P-empty-is-unverified' (Confirm-OneTalkOutboundMessage -Before @() -buyer 'Buyer A' -text 'Hello').Status 'unverified'

# ---- Send-OneTalkMessageEx 状态映射（Send-OneTalkMessage 桩） ----
function Prepare-OneTalkConversation { param([string]$Buyer, [switch]$AlreadyOpen) return [pscustomobject]@{name=$Buyer} }
$script:rawResult = 'FILLED | CLICKED | SENT_OK';$script:sendSnapshotPhase=0
function Send-OneTalkMessage([string]$buyer, [string]$text, $Page = $null, [switch]$AlreadyOpen) { $script:sendSnapshotPhase=1;return $script:rawResult }
function Get-OutboundSnapshot {param([string]$Buyer = '') if(-not $script:sendSnapshotPhase){return @()};$p=$script:probe|ConvertFrom-Json;if($p.lastIsMine){return @([pscustomobject]@{MessageId='new-event';MessageTime='2026-10-05T04:00:00Z';TimePrecision='second';Text=$p.lastText;IsMine=$true})};return @()}

$script:probe = '{"rows":2,"lastIsMine":true,"lastText":"Your cartons are booked for Friday pickup."}'
$e1 = Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Your cartons are booked for Friday pickup.'
Eq 'X-confirmed-is-sent-ok' $e1.Status 'SENT_OK'
Eq 'X-confirmed-flag' $e1.Confirmed $true

$script:probe = '{"rows":2,"lastIsMine":false,"lastText":"still waiting"}'
$e2 = Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Your cartons are booked for Friday pickup.'
Eq 'X-unclear-is-unknown' $e2.Status 'UNKNOWN'
Check 'X-unknown-not-confirmed' (-not $e2.Confirmed)
Check 'X-unknown-detail' ($e2.Detail -match 'receipt-unclear') $e2.Detail

$e3 = Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Hello' -SkipConfirmation
Eq 'X-skip-confirmation-is-unknown' $e3.Status 'UNKNOWN'

$script:rawResult = 'ABORT_WRONG_CONVO (expected=A, current=B)'
$e4 = Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Hello'
Eq 'X-wrong-convo-is-failed' $e4.Status 'FAILED'
Eq 'X-wrong-convo-detail' $e4.Detail 'wrong-conversation'

$script:rawResult = 'OPEN_FAIL (NOT_FOUND)'
Eq 'X-open-fail-is-failed' (Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Hello').Status 'FAILED'

$script:rawResult = 'FILLED | CLICKED | LEN:12 | NOT_SENT'
Eq 'X-not-sent-is-failed' (Send-OneTalkMessageEx -buyer 'Buyer A' -text 'Hello').Status 'FAILED'

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
