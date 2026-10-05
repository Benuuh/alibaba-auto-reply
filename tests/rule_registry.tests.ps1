# tests\rule_registry.tests.ps1 - 规则清单与消费方一致性（2026-10-05 spec §6.1）
#
# 目的：把"这条规则到底有没有生产消费方"变成可核对的机器事实，而不是文档里的说法。
#   G1  规则清单可解析、字段齐全、RuleId 唯一、Status 取值合法
#   G2  Status=wired 的规则：ConsumerFile 存在且真的定义了 Consumer 函数
#   G3  Status=not_wired/partial 的规则：必须指向一个真实存在的配置键（否则"未接入"这句话本身不可核对）
#   G4  Test-ReplyCompliance 及其协作者实际抛出的 violation code 必须都在清单里登记
#   G5  已知没有生产消费方的配置键（reply_rules.always/never/urgency）必须显式标为 not_wired，
#       不得被描述成"已生效"
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'

$script:pass = 0; $script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}

Write-Output '== rule_registry tests =='

# ------------------------------------------------------------------ G1
$regPath = Join-Path $scripts 'reply_rules.registry.json'
Check 'registry-exists' (Test-Path $regPath) $regPath
$reg = $null
try { $reg = Get-Content $regPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
Check 'registry-parses' ($null -ne $reg) 'ConvertFrom-Json failed'
Check 'registry-has-version' ($reg -and $reg.version) ''
$rules = @()
if ($reg -and $reg.rules) { $rules = @($reg.rules) }
Check 'registry-has-rules' ($rules.Count -ge 20) ('count=' + $rules.Count)
$ids = @($rules | ForEach-Object { [string]$_.RuleId })
Check 'registry-ids-unique' ((@($ids | Select-Object -Unique)).Count -eq $ids.Count) 'duplicate RuleId'
$missingFields = @()
foreach ($r in $rules) {
    foreach ($f in @('RuleId', 'Stage', 'ConsumerFile', 'Evidence', 'Version', 'Sample', 'Status')) {
        if (-not ($r.PSObject.Properties.Name -contains $f) -or -not [string]$r.$f) { $missingFields += ($r.RuleId + ':' + $f) }
    }
    if (@('decision', 'generation', 'compliance', 'send', 'state', 'human') -notcontains [string]$r.Stage) { $missingFields += ($r.RuleId + ':stage') }
    if (@('wired', 'partial', 'not_wired') -notcontains [string]$r.Status) { $missingFields += ($r.RuleId + ':status') }
}
Check 'registry-fields-complete' ($missingFields.Count -eq 0) ($missingFields -join ',')

# ------------------------------------------------------------------ G2
$wired = @($rules | Where-Object { [string]$_.Status -eq 'wired' })
Check 'registry-has-wired-rules' ($wired.Count -ge 15) ('wired=' + $wired.Count)
$badConsumers = @()
foreach ($r in $wired) {
    $file = Join-Path $repo ([string]$r.ConsumerFile)
    if (-not (Test-Path $file)) { $badConsumers += ($r.RuleId + ':file-missing'); continue }
    $src = Get-Content $file -Raw -Encoding UTF8
    if ($src -notmatch ('function\s+' + [regex]::Escape([string]$r.Consumer) + '\b')) { $badConsumers += ($r.RuleId + ':' + $r.Consumer) }
}
Check 'wired-consumers-exist' ($badConsumers.Count -eq 0) ($badConsumers -join ' ; ')

# ------------------------------------------------------------------ G3
$rulesJson = Get-Content (Join-Path $scripts 'reply_rules.json') -Raw -Encoding UTF8 | ConvertFrom-Json
function Test-ConfigPointer($root, [string]$pointer) {
    $cur = $root
    foreach ($part in ($pointer -split '\.')) {
        if ($null -eq $cur) { return $false }
        if (-not ($cur.PSObject.Properties.Name -contains $part)) { return $false }
        $cur = $cur.$part
    }
    return $true
}
$badPointers = @()
foreach ($r in @($rules | Where-Object { [string]$_.Status -ne 'wired' })) {
    $ptr = ''
    if ($r.PSObject.Properties.Name -contains 'ConfigPointer') { $ptr = [string]$r.ConfigPointer }
    if (-not $ptr) { $badPointers += ($r.RuleId + ':no-pointer'); continue }
    if (-not (Test-ConfigPointer $rulesJson $ptr)) { $badPointers += ($r.RuleId + ':' + $ptr) }
}
Check 'unwired-rules-point-at-real-config' ($badPointers.Count -eq 0) ($badPointers -join ' ; ')

# ------------------------------------------------------------------ G4
$codeSources = @(
    (Join-Path $scripts 'lib\reply_policy.ps1'),
    (Join-Path $scripts 'lib\contact_rules.ps1'),
    (Join-Path $scripts 'lib\time_claims.ps1')
)
$emitted = @()
foreach ($f in $codeSources) {
    $src = Get-Content $f -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($src, "Code\s*=\s*'([A-Z_]+)'")) { $emitted += [string]$m.Groups[1].Value }
    foreach ($m in [regex]::Matches($src, "Code\s*=\s*\[string\]\\\`$v\.Code")) { }
}
$emitted = @($emitted | Select-Object -Unique)
$registered = @()
foreach ($r in $rules) {
    if ($r.PSObject.Properties.Name -contains 'Codes' -and $r.Codes) { foreach ($c in @($r.Codes)) { $registered += [string]$c } }
}
$registered = @($registered | Select-Object -Unique)
$unregistered = @($emitted | Where-Object { $registered -notcontains $_ })
Check 'every-violation-code-is-registered' ($unregistered.Count -eq 0) ('unregistered: ' + ($unregistered -join ','))
# 反向：登记为代码级规则的 Code 必须真的出现在代码里（防止清单里写"已生效"但代码没有）
$ghost = @()
foreach ($r in $wired) {
    if (-not ($r.PSObject.Properties.Name -contains 'Codes') -or -not $r.Codes) { continue }
    foreach ($c in @($r.Codes)) { if ($emitted -notcontains [string]$c) { $ghost += ($r.RuleId + ':' + $c) } }
}
Check 'wired-codes-exist-in-code' ($ghost.Count -eq 0) ($ghost -join ' ; ')

# ------------------------------------------------------------------ G5
foreach ($ptr in @('reply_rules.always', 'reply_rules.never', 'reply_rules.urgency')) {
    $hit = @($rules | Where-Object { ($_.PSObject.Properties.Name -contains 'ConfigPointer') -and [string]$_.ConfigPointer -eq $ptr })
    Check ('unwired-key-declared[' + $ptr + ']') (($hit.Count -eq 1) -and ([string]$hit[0].Status -ne 'wired')) ('hits=' + $hit.Count)
}

Write-Output ''
Write-Output ('RESULT: pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
