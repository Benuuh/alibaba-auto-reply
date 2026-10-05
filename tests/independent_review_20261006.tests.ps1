# tests\independent_review_20261006.tests.ps1 - 把独立复核（2026-10-06）的正式失败探针纳入 Offline 回归。
#
# 依据：docs\业务约束收敛与完整闭环修复独立复核_20261006.md（R01–R10）。
#   * 断言与期望保持不变：探针只做进程级复跑，改动探针里的断言名会让本测试失败；
#   * 探针在自身 TEMP 根运行，不读生产存储、不调真实模型/页面/发送/通知；
#   * 运行时临时清掉本进程的 attestation 环境变量，避免嵌套探针写到本测试的证据文件。
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$dir=Join-Path $repo 'docs\verification\architecture_opt_20261005\review_fixes\closure_independent_review_20261006'
$script:pass=0;$script:fail=0
function Check([string]$name,[bool]$ok,[string]$detail=''){if($ok){$script:pass++;Write-Output ('  ok   '+$name)}else{$script:fail++;Write-Output ('  FAIL '+$name+' :: '+$detail)}}
Write-Output '== independent review 20261006 regression (R01-R10) =='
$probes=@(
 @{ File='aar_closure_s1_independent_assertions_20261006.ps1'; Asserts=@('NEG_distinct_new_batch_cannot_reuse_prior_flow_or_quote','NEG_product_each_item_weight_cannot_satisfy_packed_weight','POS_explicit_outer_carton_weight_remains_ready','NEG_current_buyer_conflict_prevents_verified_completion','NEG_explicit_added_verification_item_is_preserved_and_gates_completion','NEG_valid_pallet_confirmation_keeps_unit_and_generates_legal_reply','NEG_waiting_note_does_not_authorize_supplier_reply_claim') },
 @{ File='aar-review-closure-source-formal-20261006.ps1'; Asserts=@('C1-remaining-collision-must-still-hold','C2-invalid-stored-deadline-fails-closed','C3-unattested-current-root-change-cannot-pass') },
 @{ File='aar_closure_s2_monitor_20261006.ps1'; Asserts=@('legal-weight-clarification-preserved','legal-supplier-clarification-preserved','ordinary-business-body-still-sends','unknown-business-body-controlled-fallback') },
 @{ File='aar_closure_independent_pallet_monitor_20261006.ps1'; Asserts=@('confirmation-preserved','foreach($packageUnit in @(') },
 @{ File='aar_closure_independent_c05_20261006.ps1'; Asserts=@('missing-evidence-must-block-','ordinary-contact-explanation-positive','generic-contact-redline-negative') },
 @{ File='aar_closure_independent_time_20261006.ps1'; Asserts=@() }
)
foreach($probe in $probes){
    $path=Join-Path $dir $probe.File
    Check ('probe-present '+$probe.File) (Test-Path $path) $path
    if(-not (Test-Path $path)){continue}
    $probeText=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach($assertion in @($probe.Asserts)){Check ('assertion-present '+$probe.File+' :: '+$assertion) ([bool]($probeText -match [regex]::Escape($assertion))) ''}
}
$savedProof=$env:AAR_ATTESTATION_FILE;$savedNonce=$env:AAR_TEST_NONCE;$savedName=$env:AAR_TEST_NAME
try{
    Remove-Item Env:AAR_ATTESTATION_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:AAR_TEST_NONCE -ErrorAction SilentlyContinue
    Remove-Item Env:AAR_TEST_NAME -ErrorAction SilentlyContinue
    foreach($probe in $probes){
        $path=Join-Path $dir $probe.File
        if(-not (Test-Path $path)){continue}
        $out=@(powershell -NoProfile -ExecutionPolicy Bypass -File $path 2>&1)
        $code=$LASTEXITCODE
        $tail=(@($out|Where-Object {$_ -match 'RESULT|FAIL'}|Select-Object -Last 4) -join ' | ')
        Check ('probe-reports-all-pass '+$probe.File) (($code -eq 0) -and (($out -join [string][char]10) -notmatch '(?m)^\s*FAIL')) ('exit='+$code+' :: '+$tail)
    }
}finally{
    if($null -ne $savedProof){$env:AAR_ATTESTATION_FILE=$savedProof}
    if($null -ne $savedNonce){$env:AAR_TEST_NONCE=$savedNonce}
    if($null -ne $savedName){$env:AAR_TEST_NAME=$savedName}
}
Write-Output ('RESULT: pass=' + $script:pass + ' fail=' + $script:fail)
if($script:fail -gt 0){Write-Output 'FAILED';exit 1}
Write-Output 'ALL PASS'