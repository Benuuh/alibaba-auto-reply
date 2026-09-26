# page_health_verdict tests — [FIX-PAGEHEALTH2 2026-09-26] 表驱动单测（10 用例，纯逻辑）
#   被测对象：scripts\lib\cdp.ps1::Get-PageHealthVerdict（DOM 信号 → 判定 的纯函数）
#   不碰 DOM、不碰浏览器、不碰进程、不碰端口 —— 可在任何时刻安全重跑。
#
#   ⚠️ 本文件必须保持 UTF-8 **带 BOM**：Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI/GBK 解码，
#      文件里的中文 tip 字面量会变乱码 ⇒ 测试会以"看起来通过/失败"的假象静默失真
#      （同 lib\cdp.ps1 的 M12 陷阱）。改完请跑 spec §6 S9-BOM 的恢复命令。
#
#   跑红/跑绿机制（S7-1 / S7-2）：
#     默认（跑绿）= dot-source 部署根 scripts\lib\cdp.ps1。
#     设 PAGEHEALTH_VERDICT_SRC=<临时文件>（跑红）= dot-source 该文件（"旧逻辑等价实现"）。
#     这样跑红**无需**去改部署根的文件，避免两次 BOM 往返（见 REPORT 偏差记录）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "config.ps1")

$src = $env:PAGEHEALTH_VERDICT_SRC
if (-not $src) { $src = Join-Path $scripts "lib\cdp.ps1" }
. $src

$script:pass = 0; $script:fail = 0

Write-Output "== page_health_verdict tests (table-driven) =="
Write-Output ("  verdict source = " + $src)

if (-not (Get-Command Get-PageHealthVerdict -EA SilentlyContinue)) {
    Write-Output "  FATAL: Get-PageHealthVerdict is not defined by the source above"
    Write-Output "RESULT: pass=0 fail=1"
    exit 1
}

$ONETALK = 'https://onetalk.alibaba.com/message/weblitePWA.htm'
$TIP = '网络连接已经断开'

$cases = @(
    @{ id='C1';  name='stale-residue (2026-09-26 real scene)'; tab=$ONETALK;      tip=$TIP; h=0;   items=0; spin=0; down=$false; reason='tip-hidden-stale' },
    @{ id='C2';  name='real disconnect (tip visible)';        tab=$ONETALK;      tip=$TIP; h=15;  items=0; spin=0; down=$true;  reason='tip:网络连接已经断开' },
    @{ id='C3';  name='probe gave no height -> legacy';       tab=$ONETALK;      tip=$TIP; h=-1;  items=0; spin=0; down=$true;  reason='tip:网络连接已经断开' },
    @{ id='C4';  name='boundary h=5';                         tab=$ONETALK;      tip=$TIP; h=5;   items=0; spin=0; down=$false; reason='tip-hidden-stale' },
    @{ id='C5';  name='boundary h=6';                         tab=$ONETALK;      tip=$TIP; h=6;   items=0; spin=0; down=$true;  reason='tip:网络连接已经断开' },
    @{ id='C6';  name='wrong tab (highest priority)';         tab='about:blank'; tip='';   h=0;   items=0; spin=0; down=$true;  reason='wrong-tab:about:blank' },
    @{ id='C7';  name='wrong tab + stale tip (mixed)';        tab='about:blank'; tip=$TIP; h=0;   items=0; spin=0; down=$true;  reason='wrong-tab:about:blank' },
    @{ id='C8';  name='skeleton spinner resident';            tab=$ONETALK;      tip='';   h=0;   items=0; spin=1; down=$true;  reason='list-stalled' },
    @{ id='C9';  name='all good';                             tab=$ONETALK;      tip='';   h=0;   items=3; spin=0; down=$false; reason='ok' },
    @{ id='C10'; name='counterfactual: tall c, empty tip';    tab=$ONETALK;      tip='';   h=40;  items=0; spin=0; down=$false; reason='ok' }
)

foreach ($c in $cases) {
    $v = Get-PageHealthVerdict -Tab $c.tab -Tip $c.tip -Items $c.items -Spinner $c.spin -ContainerHeight $c.h
    $ok = (($v.PageDown -eq $c.down) -and ($v.Reason -eq $c.reason))
    if ($ok) {
        $script:pass++
    } else {
        $script:fail++
        Write-Output ("  FAIL: " + $c.id + " " + $c.name + " -> got PageDown=" + $v.PageDown + " Reason=" + $v.Reason + " | expect PageDown=" + $c.down + " Reason=" + $c.reason)
    }
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
