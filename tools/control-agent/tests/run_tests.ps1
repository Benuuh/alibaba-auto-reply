# tests/run_tests.ps1 - control-agent 测试总入口(node:test 全部单测/集成测试)
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent

if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) { Write-Output "FATAL: node.exe 不存在"; exit 1 }

Write-Output "=== node:test ==="
$testFiles = @(Get-ChildItem -Path $here -Filter "*.test.js" | ForEach-Object { $_.FullName })
$out = & node.exe --test $testFiles 2>&1
$out | ForEach-Object { Write-Output ("  " + $_) }
$exit = $LASTEXITCODE
Write-Output ""
if ($exit -ne 0) { Write-Output "TEST-SUMMARY: FAILED (exit=$exit)"; exit 1 }
Write-Output "TEST-SUMMARY: ALL PASS"
