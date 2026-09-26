# heartbeat tests — 每日心跳的"是否到点"判定（纯逻辑，不发送任何东西）
#   被测对象：scripts\lib\heartbeat.ps1::Test-HeartbeatDue
#   不碰网络、不碰企微、不碰 data\ —— 可在任何时刻安全重跑。
#
#   ⚠️ 必须 UTF-8 带 BOM（KNOWN_EXCEPTIONS E-10）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"
. (Join-Path $scripts "lib\heartbeat.ps1")

$script:pass = 0; $script:fail = 0
Write-Output "== heartbeat tests (table-driven) =="
if (-not (Get-Command Test-HeartbeatDue -EA SilentlyContinue)) {
    Write-Output "  FATAL: Test-HeartbeatDue 未定义"; Write-Output "RESULT: pass=0 fail=1"; exit 1
}

$cases = @(
    @{ id='C1';  name='09:00 当天未发 -> 该发';        now='2026-09-26 09:00:00'; last='';                 hour=9;  due=$true  },
    @{ id='C2';  name='08:59 未到点 -> 不发';          now='2026-09-26 08:59:59'; last='';                 hour=9;  due=$false },
    @{ id='C3';  name='09:00 当天已发 -> 不重复';      now='2026-09-26 09:00:00'; last='2026-09-26';       hour=9;  due=$false },
    @{ id='C4';  name='跨天 -> 该发';                  now='2026-09-27 09:00:00'; last='2026-09-26';       hour=9;  due=$true  },
    @{ id='C5';  name='同一天晚些时候 -> 仍不发';      now='2026-09-26 23:59:00'; last='2026-09-26';       hour=9;  due=$false },
    @{ id='C6';  name='lastSent 非法 -> 按该发处理';   now='2026-09-26 10:00:00'; last='not-a-date';       hour=9;  due=$true  },
    @{ id='C7';  name='hour=0 任意时刻到点';           now='2026-09-26 00:05:00'; last='';                 hour=0;  due=$true  },
    @{ id='C8';  name='hour=23 时 22:00 未到点';       now='2026-09-26 22:00:00'; last='';                 hour=23; due=$false },
    @{ id='C9';  name='跨天但未到点 -> 不发';          now='2026-09-27 07:00:00'; last='2026-09-26';       hour=9;  due=$false },
    @{ id='C10'; name='带时间戳的 lastSent 同日';      now='2026-09-26 12:00:00'; last='2026-09-26 09:01:00'; hour=9; due=$false }
)
foreach ($c in $cases) {
    $r = Test-HeartbeatDue -Now ([datetime]$c.now) -LastSent $c.last -Hour $c.hour
    if ($r -eq $c.due) { $script:pass++ }
    else { $script:fail++; Write-Output ("  FAIL: " + $c.id + " " + $c.name + " -> got " + $r + " expect " + $c.due) }
}
Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"