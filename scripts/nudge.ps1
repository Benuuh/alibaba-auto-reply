# 沉睡买家唤醒:扫描消息快照,找出超过 N 天未回复的活跃买家,发送温和跟进消息。
# 只跟进"买家主动开过口"的会话,不冷启动;不打扰已收尾(拒绝/取消)的会话;单买家最多提醒 1 次。
# 话术:LLM 根据对话上下文个性化生成,失败时回退模板。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File nudge.ps1 [-DaysSilent 2] [-DryRun]
param(
    [int]$DaysSilent = 2,
    [string]$LogDir = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lib\creds.ps1")
. (Join-Path $PSScriptRoot "lib\log.ps1")
. (Join-Path $PSScriptRoot "lib\cdp.ps1")
. (Join-Path $PSScriptRoot "lib\send.ps1")
. (Join-Path $PSScriptRoot "lib\llm.ps1")
. (Join-Path $PSScriptRoot "lib\lock.ps1")
. (Join-Path $PSScriptRoot "lib\no_reply.ps1")
if (-not $LogDir) { $LogDir = Get-SkillPath "scripts" }
$script:logFileDir = Get-SkillPath "logs"
$script:dataDir = Get-SkillPath "data"
$logFile = Join-Path $script:logFileDir "monitor.log"
$nudgeStateFile = Join-Path $LogDir "nudge_state.json"

function Write-Log([string]$msg) { Write-SkillLog $msg $logFile }

# 读取唤醒状态(去重)
function Get-NudgeState {
    if (Test-Path $nudgeStateFile) {
        try { return Get-Content $nudgeStateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return $null
}
function Save-NudgeState([object]$state) {
    $json = $state | ConvertTo-Json -Depth 5
    Set-Content -Path $nudgeStateFile -Value $json -Encoding UTF8
    Set-Content -Path "$nudgeStateFile.bak" -Value $json -Encoding UTF8
}

# LLM 生成个性化跟进(失败返回 $null → 调用方回退模板)
function Get-NudgeText-LLM([string]$buyer, [string]$ctxText) {
    $sys = "你是外贸销售助理。给一位几天没回复的买家写一条简短的 WhatsApp/站内跟进消息:1-2 句,自然随意像同事,不推销、不催促、不给压力,可以呼应上次对话的具体内容(如货物信息/报价/物流),结尾给对方空间(如 whenever you're ready / no rush)。只输出消息文本。"
    $messages = @(
        @{ role = "system"; content = $sys },
        @{ role = "user"; content = "买家名: $buyer`n=== 上次对话(倒序,第一条最新) ===`n$ctxText" }
    )
    $text = Invoke-LLM $messages 0.7 200 $logFile
    if ($text) { return $text.Trim() }
    return $null
}


# ===== 主流程 =====
Write-Log "NUDGE: start (DaysSilent=$DaysSilent, DryRun=$DryRun)"

# 1) 扫描快照,按买家分组
$files = @(Get-ChildItem (Join-Path $script:dataDir "msgs_*.txt") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($files.Count -eq 0) { Write-Log "NUDGE: no snapshots"; Write-Output "NUDGE-NO-SNAPSHOTS"; exit 0 }

$buyers = @{}   # name -> @{ lastTime=datetime; ctx=string }
foreach ($f in $files) {
    try {
        $head = Get-Content $f.FullName -Encoding UTF8 -TotalCount 1
        if ($head -match '^# BUYER: (.+)$') {
            $name = $Matches[1].Trim()
            if (-not $buyers.ContainsKey($name)) {
                $buyers[$name] = @{ lastTime = $f.LastWriteTime; file = $f.FullName }
            }
        }
    } catch {}
}
if ($buyers.Count -eq 0) { Write-Log "NUDGE: no buyers found"; Write-Output "NUDGE-NO-BUYERS"; exit 0 }

# 2) 状态加载
$state = Get-NudgeState
if (-not $state -or -not $state.nudged) { $state = [pscustomobject]@{ nudged = @{} } }

$deadline = (Get-Date).AddDays(-$DaysSilent)
$candidates = @()
foreach ($name in $buyers.Keys) {
    # 人工接管白名单买家:跳过唤醒,免打扰
    if (Test-NoReplyBuyer $name) {
        Write-Log "NUDGE-SKIP ${name}: manual-override whitelist (no auto reply)"
        continue
    }
    $info = $buyers[$name]
    $skey = $name.Trim().ToLowerInvariant()
    # 已有唤醒记录 → 跳过
    if ($state.nudged.PSObject.Properties.Name -contains $skey) { continue }
    # 最近活跃时间未超阈值 → 跳过
    if ($info.lastTime -gt $deadline) { continue }
    # 快照太新(监控可能正在处理)→ 跳过
    if (((Get-Date) - $info.lastTime).TotalMinutes -lt 5) { continue }
    # 会话是否已收尾(买家最后表达拒绝/取消/感谢收尾)→ 不打扰
    $raw = Get-Content $info.file -Raw -Encoding UTF8
    $buyerLines = @($raw -split "`r?`n" | Where-Object { $_ -match '^\[BUYER\]' })
    if ($buyerLines.Count -gt 0) {
        $lastBuyer = ($buyerLines[0] -replace '^\[BUYER\] ','').ToLower()
        if ($lastBuyer -match 'no thanks|never mind|not interested|laisser tomber|forget it|cancel|不用了|算了|退订|unsubscribe|no problem.*thanks') { continue }
    }
    # 上下文(最近 8 条)供 LLM 个性化
    $ctx = @($raw -split "`r?`n" | Where-Object { $_ -match '^\[(BUYER|ME)\]' } | Select-Object -First 8) -join "`n"
    $candidates += @{ name = $name; skey = $skey; lastTime = $info.lastTime; ctx = $ctx }
}
if ($candidates.Count -eq 0) { Write-Log "NUDGE: no candidates"; Write-Output "NUDGE-NO-CANDIDATES"; exit 0 }

Write-Output "NUDGE: $($candidates.Count) 个候选买家"
foreach ($c in $candidates) {
    Write-Output ("  - {0} (最后活跃 {1})" -f $c.name, $c.lastTime.ToString("MM-dd HH:mm"))
}
if ($DryRun) { Write-Output "NUDGE-DRYRUN: 未发送任何消息"; exit 0 }

# 3) 发送前确认 CDP 可用
if (-not (Test-CdpReady)) { Write-Log "NUDGE: CDP not ready, skip"; Write-Output "NUDGE-CDP-DOWN"; exit 0 }

# ===== [SPEC §4.1 2026-09-27] 「沉睡买家唤醒」不再自动发给买家 =====
# 决定来源: spec §4.1「必须删掉的旧出口」表 —— `QUOTE-REMIND`/`nudge` 的自动发送路径一律改为
#   **只推企微/dsh-im 内部提醒, 不自动发给买家**(老板原话:"又给不需要回复的客户发消息了" —— 提醒不是消息)。
# 为什么这里不能只删 Send-OneTalkMessage 的调用而保留"扫描+通知": 唤醒消息本身没有"买家是否在等我回"的
#   证据锚点(与 Test-ShouldReply 无关), 属于 spec §4.4-1 禁止的"Test-ShouldReply 之外的发送判据"。
# 保持可观测: 仍打印候选并写一行日志, 老板在企微/dsh-im 侧收到提醒后自行决定是否手动联系。
Write-Log ("NUDGE: auto-send DISABLED by spec §4.1 - {0} candidate(s) listed only, nothing sent" -f $candidates.Count)
foreach ($c in $candidates) { Write-Log ("NUDGE-CANDIDATE {0} (last active {1}) - manual follow-up only" -f $c.name, $c.lastTime.ToString("MM-dd HH:mm")) }
Write-Output ("NUDGE-DISABLED-BY-SPEC: candidates={0} sent=0 (auto-send to buyers removed per spec 4.1)" -f $candidates.Count)
exit 0
