# tests/run_tests.ps1 - wecom-connector 测试总入口
# 流程: 启动两个 fake server(主+空接收方) → node:test 全部单测 → PS 客户端库测试 → 清理
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$node = "node.exe"

if (-not (Get-Command $node -ErrorAction SilentlyContinue)) { Write-Output "FATAL: node.exe 不存在"; exit 1 }

$portMain = 19899
$portEmpty = 19898
$logMain = Join-Path $env:TEMP "wecom-fake-main.log"
$logEmpty = Join-Path $env:TEMP "wecom-fake-empty.log"
$fakeJs = Join-Path $here "helpers\fake_server.js"

# 启动主 fake server(有接收方 + 3 条预置消息)
$env:WECOM_TEST_PORT = [string]$portMain
$env:FAKE_SEED_COUNT = "3"
Remove-Item Env:FAKE_EMPTY_RECEIVER -ErrorAction SilentlyContinue
$p1 = Start-Process -FilePath $node -ArgumentList ("`"" + $fakeJs + "`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $logMain -RedirectStandardError ($logMain + ".err")

# 启动空接收方 fake server(无预置消息)
$env:WECOM_TEST_PORT = [string]$portEmpty
$env:FAKE_SEED_COUNT = "0"
$env:FAKE_EMPTY_RECEIVER = "1"
$p2 = Start-Process -FilePath $node -ArgumentList ("`"" + $fakeJs + "`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $logEmpty -RedirectStandardError ($logEmpty + ".err")

# 等待两个桥就绪(最多 15 秒)
function Wait-ForBridge([int]$port) {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -Uri ("http://127.0.0.1:" + $port + "/health") -TimeoutSec 2 -UseBasicParsing; if ($r.StatusCode -eq 200) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}
$ok1 = Wait-ForBridge $portMain
$ok2 = Wait-ForBridge $portEmpty
if (-not $ok1 -or -not $ok2) {
    Write-Output "FATAL: fake server 未就绪 (main=$ok1 empty=$ok2)"
    try { Stop-Process -Id $p1.Id -Force -ErrorAction SilentlyContinue } catch {}
    try { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue } catch {}
    exit 1
}

$failedFiles = New-Object System.Collections.ArrayList
$totalPass = 0
$totalFail = 0

# ---- Node 侧单测 ----
Write-Output "=== node:test ==="
$testFiles = @(Get-ChildItem -Path $here -Filter "*.test.js" | ForEach-Object { $_.FullName })
$out = & $node --test $testFiles 2>&1
$out | ForEach-Object { Write-Output ("  " + $_) }
$nodeExit = $LASTEXITCODE
if ($nodeExit -ne 0) { [void]$failedFiles.Add("node:test") }

# ---- PS 客户端库测试 ----
Write-Output "=== ps/wecom-client.tests.ps1 ==="
$env:WECOM_BASE_URL = "http://127.0.0.1:" + $portMain
$env:WECOM_EMPTY_URL = "http://127.0.0.1:" + $portEmpty
$psOut = powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $here "ps\wecom-client.tests.ps1") 2>&1
$psExit = $LASTEXITCODE
$psOut | ForEach-Object { Write-Output ("  " + $_) }
if ($psExit -ne 0) { [void]$failedFiles.Add("ps/wecom-client.tests.ps1") }

# ---- 清理 ----
Remove-Item Env:WECOM_BASE_URL -ErrorAction SilentlyContinue
Remove-Item Env:WECOM_EMPTY_URL -ErrorAction SilentlyContinue
Remove-Item Env:WECOM_TEST_PORT -ErrorAction SilentlyContinue
Remove-Item Env:FAKE_SEED_COUNT -ErrorAction SilentlyContinue
Remove-Item Env:FAKE_EMPTY_RECEIVER -ErrorAction SilentlyContinue
try { Stop-Process -Id $p1.Id -Force -ErrorAction SilentlyContinue } catch {}
try { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue } catch {}

Write-Output ""
if ($failedFiles.Count -gt 0) {
    Write-Output ("TEST-SUMMARY: FAILED - " + ($failedFiles -join ", "))
    exit 1
}
Write-Output "TEST-SUMMARY: ALL PASS"
