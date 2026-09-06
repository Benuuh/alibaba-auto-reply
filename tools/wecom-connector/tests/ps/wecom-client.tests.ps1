# tests/ps/wecom-client.tests.ps1 - wecom-connector PS 客户端库测试(自写断言风格)
# 前置: tests\run_tests.ps1 已启动两个 fake server,并设置环境变量:
#   WECOM_BASE_URL   = 主 fake server(有接收方缓存+预置消息)
#   WECOM_EMPTY_URL  = 空接收方 fake server(测 NO_RECEIVER)
# 也可手动: 先跑 node tests\helpers\fake_server.js 再设置上述环境变量后执行本文件
$ErrorActionPreference = "Stop"

$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$client = Join-Path (Split-Path (Split-Path $here -Parent) -Parent) "client\wecom-client.ps1"
. $client

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList

function Assert-Test([string]$name, [bool]$cond, [string]$detail = "") {
    if ($cond) { $script:pass++ }
    else {
        $script:fail++
        [void]$script:fails.Add($name)
        Write-Output ("  FAIL: " + $name + $(if ($detail) { " | " + $detail } else { "" }))
    }
}

Write-Output "== wecom-client tests =="
if (-not $env:WECOM_BASE_URL) { Write-Output "  SKIP: WECOM_BASE_URL 未设置(请经 run_tests.ps1 运行)"; exit 0 }

# ---- 健康 ----
Assert-Test "P1-health-ok" (Conn-TestService) "主 fake server 应 connected"

# ---- 接收方 ----
$rcv = Conn-GetReceiver
Assert-Test "P2-receiver-userid" ($rcv -and $rcv.last_userid -eq "owner1") "receiver 应含 last_userid=owner1"

# ---- 发送 ----
$r1 = Conn-SendMessage -Text "测试消息" -To "u_owner"
Assert-Test "P3-send-with-to" ($r1 -eq "SENT_OK") ("got: " + $r1)
$r2 = Conn-SendMessage -Text "测试消息"   # 无 to → 用接收方缓存
Assert-Test "P4-send-receiver-fallback" ($r2 -eq "SENT_OK") ("got: " + $r2)

# ---- 消息读取(consumer 游标) ----
$msgs = Conn-GetMessages -consumer "ps-test-consumer"
Assert-Test "P5-messages-nonempty" ($null -ne $msgs -and @($msgs).Count -ge 2) ("got count: " + @($msgs).Count)
$maxSeq = 0
if ($null -ne $msgs) { foreach ($m in $msgs) { if ([long]$m.seq -gt $maxSeq) { $maxSeq = [long]$m.seq } } }

# ---- 游标:初始为 0,提交后可读回,提交后增量读取为空 ----
$cur0 = Conn-GetCursor -consumer "ps-test-consumer"
Assert-Test "P6-cursor-initial-zero" ($cur0 -eq 0) ("got: " + $cur0)
$setOk = Conn-SetCursor -consumer "ps-test-consumer" -seq $maxSeq
Assert-Test "P7-cursor-set" ($setOk) "POST /cursor 应成功"
$cur1 = Conn-GetCursor -consumer "ps-test-consumer"
Assert-Test "P8-cursor-readback" ($cur1 -eq $maxSeq) ("got: " + $cur1 + " want: " + $maxSeq)
$msgs2 = Conn-GetMessages -consumer "ps-test-consumer"
Assert-Test "P9-messages-after-cursor-empty" ($null -ne $msgs2 -and @($msgs2).Count -eq 0) ("got count: " + @($msgs2).Count + " (应为 0,数组非 null)")

# ---- 多消费者独立 ----
$msgs3 = Conn-GetMessages -consumer "ps-other-consumer"
Assert-Test "P10-consumer-independent" ($null -ne $msgs3 -and @($msgs3).Count -ge 2) "其他消费者不受 ps-test-consumer 游标影响"

# ---- 服务不可达:SERVICE_DOWN / $null ----
$oldUrl = $env:WECOM_BASE_URL
$env:WECOM_BASE_URL = "http://127.0.0.1:1"
Assert-Test "P11-health-down" (-not (Conn-TestService)) "死端口应 connected=false"
$r3 = Conn-SendMessage -Text "x" -To "u1"
Assert-Test "P12-send-service-down" ($r3 -eq "SERVICE_DOWN") ("got: " + $r3)
$msgs4 = Conn-GetMessages -consumer "x"
Assert-Test "P13-messages-null-on-down" ($null -eq $msgs4) "服务不可达应返回 $null"
$env:WECOM_BASE_URL = $oldUrl

# ---- NO_RECEIVER(空接收方 + 无 to) ----
$oldUrl = $env:WECOM_BASE_URL
$env:WECOM_BASE_URL = $env:WECOM_EMPTY_URL
$r4 = Conn-SendMessage -Text "x"
Assert-Test "P14-send-no-receiver" ($r4 -eq "NO_RECEIVER") ("got: " + $r4)
$env:WECOM_BASE_URL = $oldUrl

# ---- 游标迁移 ----
$legacy = Join-Path $env:TEMP ("wccmd_state_" + [guid]::NewGuid().ToString("N") + ".json")
@{ last_seq = 8888; last_cmd_time = "2026-08-01 00:00:00" } | ConvertTo-Json | Set-Content -Path $legacy -Encoding UTF8
$mig1 = Conn-InitCursor -consumer "migrated-consumer" -legacyFile $legacy
Assert-Test "P15-migrate-seed" ($mig1 -eq "SEEDED") ("got: " + $mig1)
$curM = Conn-GetCursor -consumer "migrated-consumer"
Assert-Test "P16-migrate-cursor-value" ($curM -eq 8888) ("got: " + $curM)
$mig2 = Conn-InitCursor -consumer "migrated-consumer" -legacyFile $legacy
Assert-Test "P17-migrate-idempotent" ($mig2 -eq "ALREADY") ("got: " + $mig2)
Remove-Item -Path $legacy -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ("FAILED CASES: " + ($script:fails -join ", ")); exit 1 }
Write-Output "ALL PASS"
