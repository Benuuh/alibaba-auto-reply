# page_health tests — FIX-PAGEHEALTH 2026-09-25（纯函数/纯逻辑，不需要真浏览器）
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")
. (Join-Path $scripts "lib\cdp.ps1")
$script:pass=0; $script:fail=0
function Assert-True([string]$n,[bool]$c){ if($c){$script:pass++}else{$script:fail++;Write-Output "  FAIL: $n"} }
Write-Output "== page_health tests =="

# 断言 1：函数存在
Assert-True "function-exists" ($null -ne (Get-Command Test-PageHealth -EA SilentlyContinue))

# 断言 2：真实调用一次（真页面）：返回值形状完整
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Test-PageHealth
$sw.Stop()
Write-Output ("  (Test-PageHealth latency = " + $sw.ElapsedMilliseconds + " ms)")
Assert-True "returns-single-object-not-array" (@($r).Count -eq 1)
Assert-True "is-pscustomobject" ($r -is [psobject] -and $r -isnot [array] -and $r -isnot [hashtable])
foreach($k in 'PageDown','Reason','Items','Spinner','Tab','Tip'){ Assert-True "key-$k" ($r.PSObject.Properties.Name -contains $k) }
Assert-True "PageDown-is-bool" ($r.PageDown -is [bool])
Assert-True "Items-is-int" ($r.Items -is [int])
Assert-True "reason-nonempty" (-not [string]::IsNullOrWhiteSpace($r.Reason))
# [ADDED 2026-09-25 执行者] 主循环每轮都会同步调用本函数；若单次耗时逼近扫描周期(≈12s)会拖垮监控节奏。
# 30s 是"明显劣化"的硬上限（实测值在上方 latency 行打印，便于 REPORT 引用）。
Assert-True "call-latency-under-30s" ($sw.ElapsedMilliseconds -lt 30000)
# URL 守卫：探到非 onetalk 页面时绝不能判 healthy
if ($r.Tab -and $r.Tab -notmatch 'onetalk\.alibaba\.com') { Assert-True "wrong-tab-not-ok" ($r.Reason -like 'wrong-tab:*') } else { Assert-True "wrong-tab-guard-skipped-on-onetalk" $true }

# 断言 3：与独立探针的结论一致（防"函数说 OK 但页面确实断连"）
#   ⚠️ 独立探针必须同样走 -ScriptB64 + JS 内 btoa（附录 B/C1、C3），不得用内联 JS 或原始文本
$probeJs = @'
(function(){
  var e=document.querySelector('.connection-status-container .status-tip');
  var t=e?(e.innerText||'').replace(/\s+/g,' ').trim():'';
  var c=document.querySelector('.connection-status-container');
  return JSON.stringify({tipB64: t?btoa(unescape(encodeURIComponent(t))):'', containerH: c?c.offsetHeight:-1});
})()
'@
$probeB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($probeJs))
$probe = [string]((powershell -ExecutionPolicy Bypass -NoProfile -File (Get-SkillPath "cdp") -Action eval -ScriptB64 $probeB64 2>&1) -join "`n")
$pv = $probe | ConvertFrom-Json
$ptip = if ($pv.tipB64) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$pv.tipB64)) } else { '' }
# [FIX-PAGEHEALTH2 2026-09-26] 旧断言把"tip 文案 ⇒ 必然 down"固化成了误报判据：
#   tip 文案在重连后仍残留，而容器 offsetHeight=0（被父级折叠）⇒ 文案不可见。
#   现改为：tip 文案**且容器可见**才要求 PageDown=true；容器折叠时要求 PageDown=false。
#   [DEVIATION D-08] 原 spec S7-3 用第二次 cdp eval 取 $ch；此处直接从上面**同一次**探针结果解析：
#   少一次 CDP 往返，且 $ch 与被断言的 $r 取自同一时刻的页面状态（更自洽，避免两次采样状态漂移）。
$ch = -1
if (($pv.PSObject.Properties.Name -contains 'containerH') -and $null -ne $pv.containerH) { $ch = [int]$pv.containerH }
if ($ptip -match '网络连接已经断开|连接已断开|网络异常|重新连接') {
  if ($ch -le 5 -and $ch -ge 0) { Assert-True "consistency-stale-tip-means-up" ($r.PageDown -eq $false) }
  else { Assert-True "consistency-visible-tip-means-down" ($r.PageDown -eq $true) }
} else { Assert-True "consistency-no-tip-means-up" ($r.PageDown -eq $false) }

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if($script:fail -gt 0){ Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
