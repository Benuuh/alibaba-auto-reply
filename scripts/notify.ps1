# 异常告警通知:扫描 monitor.log 关键事件 → 去重(30 分钟窗口) → 写入 logs\events.json;
# 配置 notify_webhook(config.json) 后 POST 通用 JSON(企业微信/钉钉/Slack 兼容格式)。
# 通知内容禁止包含凭据/完整账号/API key。
# 用法: notify.ps1 [-LookbackMin 60] [-Force]
# 建议: 每日 4 次计划任务(与 Summary 同频)或由 watchdog 顺带调用
param(
    [int]$LookbackMin = 60,
    [switch]$Force,
    [string]$LogDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$monitorLog = Join-Path $script:logFileDir "monitor.log"
$eventsFile = Join-Path $script:logFileDir "events.json"

function Write-Log([string]$msg) { Write-SkillLog $msg $monitorLog }

# 事件模式:名称 -> (正则, 级别, 说明)
$patterns = @(
    @{ name = "CDP_FAIL_X3";     re = 'CDP fail x3';                              level = "high" },
    @{ name = "RESTART_STORM";   re = 'RESTART-STORM';                            level = "high" },
    @{ name = "AUTH_ERROR";      re = 'LLM error \[(AUTH|HTTP_401|HTTP_402|HTTP_403)\]'; level = "high" },
    @{ name = "WRONG_CONVO";     re = 'ABORT_WRONG_CONVO';                        level = "high" },
    @{ name = "SEND_RETRY";      re = 'RETRY-QUEUE';                              level = "medium" },
    @{ name = "LOGIN_FAIL";      re = 'CHROME-ENSURE: login may have failed|CHROME-ENSURE: cannot parse credentials'; level = "high" },
    @{ name = "LOCK_BUSY";       re = 'LOCK-BUSY';                                level = "low" },
    @{ name = "TASK_STALE";      re = 'TASK-HEALTH: .* stale';                    level = "medium" },
    @{ name = "STATE_CLEANUP";   re = 'STATE-CLEANUP: error';                     level = "medium" }
)

# 加载已有事件(去重用)
$events = @()
if (Test-Path $eventsFile) {
    try { $events = @((Get-Content $eventsFile -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch { $events = @() }
}
$knownKeys = @{}
foreach ($e in $events) { if ($e.key) { $knownKeys[$e.key] = $e.time } }
# 清理超过 7 天的旧事件
$cut7d = (Get-Date).AddDays(-7)
$events = @($events | Where-Object { $_.time -and ([datetime]$_.time) -gt $cut7d })

$cutoff = (Get-Date).AddMinutes(-$LookbackMin)
$newEvents = New-Object System.Collections.ArrayList
if (Test-Path $monitorLog) {
    Get-Content $monitorLog -Encoding UTF8 | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \| ' } | ForEach-Object {
        $m = [regex]::Match($_, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| (.+)$')
        if (-not $m.Success) { return }
        $ts = $null
        try { $ts = [datetime]::ParseExact($m.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", $null) } catch { return }
        if ($ts -lt $cutoff) { return }
        $line = $m.Groups[2].Value
        foreach ($p in $patterns) {
            if ($line -match $p.re) {
                $key = $p.name + "|" + ([System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($line))).Replace('-',''))
                if ($Force -or -not $knownKeys.ContainsKey($key)) {
                    [void]$newEvents.Add([pscustomobject]@{
                        key   = $key
                        name  = $p.name
                        level = $p.level
                        time  = $m.Groups[1].Value
                        line  = $line.Substring(0, [Math]::Min(160, $line.Length))
                    })
                    $knownKeys[$key] = $m.Groups[1].Value
                }
                break
            }
        }
    }
}

if ($newEvents.Count -gt 0) {
    $events = @($newEvents) + $events
    # 保留最近 200 条
    if ($events.Count -gt 200) { $events = $events[0..199] }
    $events | ConvertTo-Json -Depth 4 | Set-Content -Path $eventsFile -Encoding UTF8
    Write-Log "NOTIFY: $($newEvents.Count) new event(s) -> $eventsFile"
    Write-Output "NOTIFY-NEW: $($newEvents.Count)"
    foreach ($e in $newEvents) { Write-Output ("  [{0}] {1} {2}" -f $e.level, $e.name, $e.time) }

    # Webhook 推送(可选)
    $cfg = Get-SkillConfig
    if ($cfg.notify_webhook) {
        $payload = @{
            msgtype = "text"
            text = @{ content = ("[alibaba-auto-reply] " + $newEvents.Count + " 个新事件`n" + (($newEvents | Select-Object -First 5 | ForEach-Object { "[$($_.level)] $($_.name) @ $($_.time): $($_.line)" }) -join "`n")) }
        } | ConvertTo-Json -Depth 5
        try {
            $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create([string]$cfg.notify_webhook)
            $req.Method = "POST"
            $req.ContentType = "application/json; charset=utf-8"
            $req.Timeout = 15000
            $req.ReadWriteTimeout = 15000
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            $rs.Write($bytes, 0, $bytes.Length)
            $rs.Dispose()
            $hr = $req.GetResponse()
            $rd = New-Object System.IO.StreamReader($hr.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $resp = $rd.ReadToEnd()
            $rd.Dispose(); $hr.Dispose()
            Write-Log "NOTIFY: webhook delivered ($resp)"
            Write-Output "NOTIFY-WEBHOOK-OK"
        } catch {
            Write-Log "NOTIFY: webhook failed: $($_.Exception.Message)"
            Write-Output "NOTIFY-WEBHOOK-FAIL"
        }
    }
} else {
    Write-Output "NOTIFY-NONE"
}
