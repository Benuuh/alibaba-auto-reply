# alert_dedup tests — [FIX-ALERTDEDUP 2026-09-26] 表驱动单测（纯逻辑）
#   被测对象：scripts\lib\alert_dedup.ps1::Test-AlertDue
#   不碰 DOM、不碰浏览器、不碰进程、不碰端口、不碰 health_check.ps1 —— 可在任何时刻安全重跑。
#
#   ⚠️ 本文件必须保持 UTF-8 带 BOM（Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI/GBK 解码，
#      中文与判据会静默失真 —— 同 lib\cdp.ps1 的陷阱、KNOWN_EXCEPTIONS E-10）。
#
#   跑红/跑绿机制：
#     默认（跑绿）= dot-source 部署根 scripts\lib\alert_dedup.ps1。
#     设 ALERTDEDUP_SRC=<临时文件>（跑红）= dot-source 该文件（"旧逻辑等价实现"，见 S3-2）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$scripts = Join-Path (Split-Path $here -Parent) "scripts"

$src = $env:ALERTDEDUP_SRC
if (-not $src) { $src = Join-Path $scripts "lib\alert_dedup.ps1" }
. $src

$script:pass = 0; $script:fail = 0
Write-Output "== alert_dedup tests (table-driven) =="
Write-Output ("  dedup source = " + $src)

if (-not (Get-Command Test-AlertDue -EA SilentlyContinue)) {
    Write-Output "  FATAL: Test-AlertDue is not defined by the source above"
    Write-Output "RESULT: pass=0 fail=1"; exit 1
}

$T0 = [datetime]'2026-09-26 13:03:06'     # = data\health_state.json 实测的 lastAlert

# hh:mm:ss 用秒表达差值，便于逐字核对
$cases = @(
    @{ id='C1';  name='empty lastAlert -> due';          last='';                       due=$true  },
    @{ id='C2';  name='garbage lastAlert -> due';        last='not-a-date';             due=$true  },
    @{ id='C3';  name='plus 15m (next tick) -> NOT due'; last='2026-09-26 12:48:06';   due=$false },
    @{ id='C4';  name='plus 29m58s -> the real race';    last='2026-09-26 12:33:08';   due=$true  },
    @{ id='C5';  name='plus 30m00s exactly -> due';      last='2026-09-26 12:33:06';   due=$true  },
    @{ id='C6';  name='plus 30m01s -> due';              last='2026-09-26 12:33:05';   due=$true  },
    @{ id='C7';  name='plus 45m (2nd tick) -> due';      last='2026-09-26 12:18:06';   due=$true  },
    @{ id='C8';  name='plus 28m59s -> NOT due';          last='2026-09-26 12:34:07';   due=$false },
    @{ id='C9';  name='plus 29m00s boundary -> due';     last='2026-09-26 12:34:06';   due=$true  },
    @{ id='C10'; name='plus 0s -> NOT due';              last='2026-09-26 13:03:06';   due=$false }
)

foreach ($c in $cases) {
    $r = Test-AlertDue -Now $T0 -LastAlert $c.last
    if ($r -eq $c.due) { $script:pass++ }
    else { $script:fail++; Write-Output ("  FAIL: " + $c.id + " " + $c.name + " -> got " + $r + " | expect " + $c.due) }
}
Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
