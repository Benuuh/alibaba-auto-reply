# tests\send_reconcile_closure.tests.ps1 - 补发对账闭环（2026-10-06 生产观察 R1）
#
# 背景：真实会话（消息缺稳定平台身份）里发送返回 UNKNOWN（receipt-unclear: incomplete-before-identities），
#   页面侧却已完成 FILLED|CLICKED|SENT_OK 且会话随即离开待回复列表；旧实现只会把补发项反复重排到放弃，
#   账本永不推进。本测试固定新判据：
#   ① 页面侧发送动作已完成（三段齐全）且当时算出的去重键存在 ⇒ 才允许把 NOT_IN_LIST 当作已送达；
#   ② 对账只推进**去重账本**（同一把键），不伪造已确认收据；
#   ③ 证据字段在补发表读写与重排之间不丢失、不被无参重排覆盖。
# 分层：isolated。monitor.ps1 **不被 dot-source**（那会执行主分发），函数由 AST 抽取；写盘只打 TEMP 隔离根。
$ErrorActionPreference='Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
$script:pass=0;$script:fail=0
function Check([string]$name,[bool]$ok,[string]$detail=''){if($ok){$script:pass++;Write-Output ('  ok   '+$name)}else{$script:fail++;Write-Output ('  FAIL '+$name+' :: '+$detail)}}
Write-Output '== send reconcile closure tests =='

. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')
$root = Join-Path $env:TEMP ('aar-reconcile-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $root)
. (Join-Path $scripts 'reply_engine.ps1')
. (Join-Path $scripts 'lib\state_store.ps1')

$tk=$null;$errs=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'monitor.ps1'),[ref]$tk,[ref]$errs)
if($errs.Count){throw 'monitor.ps1 failed to parse'}
$fns=@('Get-RetryFile','Read-RetryTable','Save-RetryTable','Get-RetryBackoffMin','Add-PendingRetry','Remove-PendingRetry','Test-PageConfirmedSendResult','Test-ReconciledDeliveryEvidence','Complete-ReconciledDelivery')
foreach($fnName in $fns){
    $fnAst=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName},$true)
    if(-not $fnAst){throw ('monitor.ps1 does not define ' + $fnName)}
    Invoke-Expression $fnAst.Extent.Text
}
$script:logs=New-Object System.Collections.ArrayList
function Write-Log([string]$m){[void]$script:logs.Add($m)}
$script:ledgerWrites=New-Object System.Collections.ArrayList
function Set-StateHash($ctx,[string]$skey,[string]$hash){[void]$script:ledgerWrites.Add($skey+'='+$hash);if($ctx.state -and $ctx.state.replied){$ctx.state.replied[$skey]=$hash}}

# ---- 1) 页面侧发送动作完成的判据 ----
Check 'P1-real-production-reason-is-page-confirmed' (Test-PageConfirmedSendResult 'FILLED | CLICKED | SENT_OK | RECONCILE_UNVERIFIED') ''
Check 'P2-abort-is-not-page-confirmed' (-not (Test-PageConfirmedSendResult 'ABORT_WRONG_CONVO expected=A current=B')) ''
Check 'P3-cdp-error-is-not-page-confirmed' (-not (Test-PageConfirmedSendResult 'CDP-EVAL-FAIL: timeout')) ''
Check 'P4-clicked-but-not-sent-is-not-confirmed' (-not (Test-PageConfirmedSendResult 'FILLED | CLICKED | SEND_BUTTON_MISSING')) ''
Check 'P5-empty-is-not-confirmed' (-not (Test-PageConfirmedSendResult '')) ''

# ---- 2) 只有"页面已确认 + 有去重键 + 原因成立"三件套才允许当作已送达 ----
Check 'E1-full-evidence-pass' (Test-ReconciledDeliveryEvidence 'FILLED | CLICKED | SENT_OK | RECONCILE_UNVERIFIED' $true 'ABC|5') ''
Check 'E2-no-dedup-key-blocked' (-not (Test-ReconciledDeliveryEvidence 'FILLED | CLICKED | SENT_OK' $true '')) ''
Check 'E3-not-page-confirmed-blocked' (-not (Test-ReconciledDeliveryEvidence 'FILLED | CLICKED | SENT_OK' $false 'ABC|5')) ''
Check 'E4-reason-not-page-confirmed-blocked' (-not (Test-ReconciledDeliveryEvidence 'ABORT_WRONG_CONVO' $true 'ABC|5')) ''

# ---- 3) 补发表读写与重排不丢证据 ----
Remove-PendingRetry 'Reconcile Buyer'
Add-PendingRetry 'Reconcile Buyer' 'FILLED | CLICKED | SENT_OK | RECONCILE_UNVERIFIED' 'ABC|5' $true
$t=Read-RetryTable;$it=$t.items['reconcile buyer']
Check 'T1-evidence-persisted' (([string]$it.dedupKey -eq 'ABC|5') -and [bool]$it.pageConfirmed) ('key=' + [string]$it.dedupKey + ' page=' + [bool]$it.pageConfirmed)
Add-PendingRetry 'Reconcile Buyer' 'NOT_IN_LIST (conversation no longer in pending list)'
$t=Read-RetryTable;$it=$t.items['reconcile buyer']
Check 'T2-reason-updated' ([string]$it.reason -match 'NOT_IN_LIST') ([string]$it.reason)
Check 'T3-evidence-preserved-on-requeue' (([string]$it.dedupKey -eq 'ABC|5') -and [bool]$it.pageConfirmed) ('key=' + [string]$it.dedupKey + ' page=' + [bool]$it.pageConfirmed)
Check 'T4-tries-incremented-once-per-requeue' ([int]$it.tries -eq 1) ([string]$it.tries)
Add-PendingRetry 'Reconcile Buyer' 'NOT_IN_LIST (conversation no longer in pending list)'
$t=Read-RetryTable;$it=$t.items['reconcile buyer']
Check 'T5-repeated-requeue-keeps-evidence' (([string]$it.dedupKey -eq 'ABC|5') -and [bool]$it.pageConfirmed -and [int]$it.tries -eq 2) ('tries=' + [string]$it.tries + ' key=' + [string]$it.dedupKey)

# ---- 4) 对账推进账本（同一把键）并可验证写没写进去 ----
$ctx=[pscustomobject]@{ state=[pscustomobject]@{ replied=@{} }; lastSendAt=@{} }
$ok=Complete-ReconciledDelivery $ctx 'reconcile buyer' 'ABC|5' 'page-send-ok+pending-list-cleared'
Check 'L1-ledger-advanced' ([bool]$ok) ''
Check 'L2-ledger-value-is-the-send-time-key' ([string]$ctx.state.replied['reconcile buyer'] -eq 'ABC|5') ([string]$ctx.state.replied['reconcile buyer'])
Check 'L3-no-fabricated-receipt' ((@($script:logs) -join ' ' ) -match 'receipt=unpublished') ''
Check 'L4-no-op-without-key' (-not (Complete-ReconciledDelivery $ctx 'reconcile buyer' '' 'page-send-ok')) ''
$script:ledgerWrites.Clear()
function Set-StateHash($ctx,[string]$skey,[string]$hash){[void]$script:ledgerWrites.Add($skey+'='+$hash)}
$bad=Complete-ReconciledDelivery $ctx 'reconcile buyer' 'ZZZ|9' 'page-send-ok+pending-list-cleared'
Check 'L5-unwritten-ledger-is-not-success' (-not [bool]$bad) ''
Check 'L6-failure-logged' ((@($script:logs) -join ' ') -match 'RETRY-RECONCILE-LEDGER-WRITE-FAIL') ''

# ---- 5) 生产接线静态断言：闭环确实接在 NOT_IN_LIST 分支上 ----
$mon=Get-Content (Join-Path $scripts 'monitor.ps1') -Raw -Encoding UTF8
Check 'W1-not-in-list-branch-uses-evidence' ([bool]($mon -match "NOT_IN_LIST[\s\S]{0,700}Test-ReconciledDeliveryEvidence")) ''
Check 'W2-not-in-list-branch-advances-ledger' ([bool]($mon -match "Test-ReconciledDeliveryEvidence[\s\S]{0,400}Complete-ReconciledDelivery")) ''
Check 'W3-failure-site-records-evidence' ([bool]($mon -match 'Add-PendingRetry .{0,40}\[string\]\$sendRaw\) \$newKey')) ''

Write-Output ('RESULT: pass=' + $script:pass + ' fail=' + $script:fail)
if($script:fail -gt 0){Write-Output 'FAILED';exit 1}
Write-Output 'ALL PASS'