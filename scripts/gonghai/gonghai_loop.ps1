# gonghai/gonghai_loop.ps1 — 公海**连续跑**入口(把"每批 10 个"串起来,跑到达标或必须停为止)
#
# 为什么要有这个文件(2026-09-27 深夜):
#   当晚的连跑是用"内联命令"驱动的,踩了两个只有长期连跑才暴露的坑,都已在这里固化:
#     · GH-24 **命令行自匹配陷阱**:判"有没有批次在跑"时用 `CommandLine -match 'gonghai_batch\.ps1'`,
#       会把**调用方自己**(也是 powershell.exe -Command "…gonghai_batch.ps1…")算成批次 ⇒ 空转卡死。
#       ⇒ 本文件的判据收紧为:命令行含 `-File …batch.ps1` **且** 不含 `-Command`。
#     · GH-28 **退出码不分级**:一遇非零就停,把可恢复故障(列表页冻结/认领异常 = exit 1)和
#       必须停的故障(风控 9 / 模块闸 3 / 配额 4 / 认领上限 10)混为一谈。
#       ⇒ 本文件:exit 1 等 20 秒重试(连续 3 次才停),其余非零**立即停**。
#
# 用法:
#   gonghai_loop.ps1                        # 目标=当天 day_count 到 200,最多 25 轮
#   gonghai_loop.ps1 -Target 300 -MaxRounds 40
#   gonghai_loop.ps1 -Batch 10 -DryRunProbe # 只打印将要执行什么,不真跑(安全演练)
#
# 纪律:
#   · **绝不并发**:开跑前等"真实批次进程"归零;每轮之间也复查(拿不到就等,不硬上)。
#   · 每轮日志独立落 `logs\gonghai_loop_r<N>_<HHmmss>.txt`,便于按批复盘。
#   · 目标读的是 `data\gonghai\gonghai_rate.json` 的**当天** `day_count` ⇒ 跨零点会自动按新的一天算。
#   · 风控一旦命中,batch 自身 `exit 9` ⇒ 本循环立即停止(不再开下一批)。
# 编码:UTF-8 带 BOM。
param(
    [int]$Target = 200,             # 当天累计发送目标；**-Target 0 = 长期连跑(不设当日目标)**
    [int]$MaxRounds = 25,           # 最多跑几批(防失控;每批默认 10 个)
    [ValidateRange(1, 20)][int]$Batch = 10,
    [int]$MaxRecoverableRetry = 3,  # 可恢复故障(exit 1)最多连续重试几次
    [int]$RetryWaitSec = 20,
    # 每轮开跑前要求的"连续无其它批次"静默秒数。
    #   为什么需要:另一条链路若是**内联命令**拼的(不持本锁),它每轮之间只有 ~3 秒空档;
    #   只查一次进程可能正好卡进那个空档 ⇒ 仍然并发。连续静默才说明对方真的收工了。
    [int]$QuietSec = 30,
    # ---- 待办队列定期补发（"认领了却发不出去"的人不能一直躺着）----
    #   每 $DrainEveryRounds 轮补发一次，每次最多 $DrainCount 条，**只挑入队已满 $DrainMinAgeHours 小时**的。
    #   为什么按年龄筛:GH-01 那批客户的头几次重试必然失败（阿里侧索引还没建成），
    #   刚失败就重试是纯浪费（每次 6 轮搜索 ≈ 90 秒）；给足时间再补才有机会捞回来。
    #   DrainEveryRounds=0 ⇒ 关闭定期补发（需要时手工跑 `gonghai_probe.ps1 -RetryPending`）。
    [int]$DrainEveryRounds = 5,
    [int]$DrainCount = 2,
    [int]$DrainMinAgeHours = 6,
    # ---- 硬停止时间（老板 2026-09-28 04:12 指示："跑到北京时间 8 点半就行"）----
    #   格式 'HH:mm'（本机即北京时间）。到点后**不再开新的一批**，收工并打印当日总账。
    #   为什么写进脚本而不是靠人工 kill:这样**不依赖我在不在线**——到点自己停，不会跑过头。
    #   留空 ⇒ 不设停止时间（长期连跑）。
    [string]$StopAt = '',
    [switch]$DryRunProbe            # 只打印计划,不执行
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$S = Split-Path $PSScriptRoot -Parent   # 本文件在 <部署根>\scripts\gonghai\ ⇒ 上一级即 scripts
. (Join-Path $S 'config.ps1')
. (Join-Path $S 'lib\log.ps1')
. (Join-Path $S 'lib\lock.ps1')
. (Join-Path $S 'gonghai\gonghai_cdp.ps1')   # [GH-36] 为了 Get-GonghaiCdpPort(守护 9225 存活)
. (Join-Path $S 'gonghai\gonghai_lib.ps1')

$batchScript = Join-Path $S 'gonghai\gonghai_batch.ps1'
$LockName = 'gonghai-loop'      # 单例锁:同一时刻只允许一个 loop
$ratePath = Join-Path (Get-SkillPath 'data') 'gonghai\gonghai_rate.json'
$logDir = Get-SkillPath 'logs'

function Say([string]$m) { Write-Output $m }

function Test-GonghaiBrowserAlive {
    # [GH-36] 公海 Chrome(9225)存活探针。为什么必须每轮查:
    #   2026-09-28 02:10 那个实例**整个消失**,把正在认领的批次打断、loop 也随之停摆,
    #   而链路**没有任何守护**去拉起它(monitor 侧的 chrome_ensure 只管 9222) ⇒ 静默停摆 7 分钟。
    try {
        $port = Get-GonghaiCdpPort
        $v = Invoke-RestMethod -Uri ("http://127.0.0.1:$port/json/version") -TimeoutSec 6
        return [bool]$v
    } catch { return $false }
}

function Invoke-GonghaiEnsure {
    # 9225 不可达 ⇒ 调专用恢复脚本(自建实例 + OneTalk 页 + 公海页 + 登录态自述)。
    $out = Join-Path $logDir ('gonghai_loop_ensure_' + (Get-Date -Format 'HHmmss') + '.txt')
    Say ("--- 9225 不可达 ⇒ 调 gonghai_ensure.ps1 拉起（日志 " + (Split-Path $out -Leaf) + "）")
    & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $S 'gonghai\gonghai_ensure.ps1') 2>&1 | Tee-Object -FilePath $out
    return (Test-GonghaiBrowserAlive)
}

function Get-RealBatchProcesses {
    # ⚠️ [GH-29] 调用方**必须**写成 `@(Get-RealBatchProcesses).Count`:
    #    函数返回**单元素数组**时 PowerShell 会把它**解包成标量**,而 CIM 对象的 `.Count` 是 $null
    #    ⇒ `$null -gt 0` 恒为 False ⇒ **并发闸静默失效**(2026-09-28 00:10 实测抓到:明明有批次在跑却打印空值)。
    # ★★ 判据必须**排除调用方自身**:含 `-File …batch.ps1` 且不含 `-Command`(详见文件头 GH-24)。
    #   本函数**不得**改成只匹配 `batch.ps1` 字面量 —— 那样会把本脚本自己的命令行也算进去。
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match '\-File\s+\S*batch\.ps1' -and $_.CommandLine -notmatch '\-Command' })
}

function Get-DayCount {
    try { return [int]((Get-Content $ratePath -Raw -Encoding UTF8 | ConvertFrom-Json).day_count) } catch { return -1 }
}
function Get-RateDay {
    try { return [string]((Get-Content $ratePath -Raw -Encoding UTF8 | ConvertFrom-Json).day) } catch { return '' }
}

Say ("=== GONGHAI-LOOP " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===")
Say ("target=$Target maxRounds=$MaxRounds batch=$Batch 可恢复重试=$MaxRecoverableRetry 次/每轮 静默窗口=$QuietSec 秒")
if ($DryRunProbe) {
    Say ("[DryRunProbe] 将执行: " + $batchScript + " -Batch " + $Batch + " ; 真实批次在跑 = " + @(Get-RealBatchProcesses).Count + " ; 当前 day=" + (Get-RateDay) + " count=" + (Get-DayCount))
    exit 0
}

# ---- 单例锁:两个 loop 绝不允许同时在跑(否则两批抢同一个 OneTalk 页) ----
#   为什么光有进程判据不够:另一个"链路"若是**内联命令**拼的(不持本锁),它每轮之间只有 ~3 秒空档,
#   光轮询进程可能正好卡进那个空档 ⇒ 仍然并发。所以再加"静默窗口"(见下)双保险。
if (-not (Get-AppLock $LockName 0)) {
    Say ("另一个 gonghai_loop 正在运行(锁 $LockName 被占) ⇒ 本次退出，不并发")
    exit 0
}
Say ("已取得单例锁 $LockName")

try {
# 解析 -StopAt（'HH:mm'，本机时间即北京时间）。非法格式 ⇒ 忽略并 WARN（不能因为参数写错就跑飞）。
$stopAtDt = $null
if ($StopAt) {
    $m = [regex]::Match($StopAt, '^\s*(\d{1,2}):(\d{2})\s*$')
    if ($m.Success) {
        $hh = [int]$m.Groups[1].Value; $mm = [int]$m.Groups[2].Value
        if ($hh -ge 0 -and $hh -le 23 -and $mm -ge 0 -and $mm -le 59) {
            $stopAtDt = (Get-Date).Date.AddHours($hh).AddMinutes($mm)
            # 若该时刻已过去超过 12 小时 ⇒ 视为"明天这个点"；否则就是今天（已过则立刻收工）
            if ((Get-Date) - $stopAtDt -gt (New-TimeSpan -Hours 12)) { $stopAtDt = $stopAtDt.AddDays(1) }
            Say ("停止时间 = " + $stopAtDt.ToString('yyyy-MM-dd HH:mm') + "（到点不再开新批次）")
        }
    }
    if (-not $stopAtDt) { Say ("WARN: -StopAt 格式无法识别('" + $StopAt + "') ⇒ 本次不设停止时间") }
}

$recoverFails = 0
$drainFailCount = @{}   # [GH-58] key -> 本 run 内补发失败次数（补发失败**不**递增 pending.json 的 tries，所以必须自己记）
$round = 0
for ($round = 1; $round -le $MaxRounds; $round++) {
    $day = Get-RateDay; $count = Get-DayCount
    # [2026-09-28 老板指示] **长期任务模式**:`-Target 0` = 不设当日目标,一直按批跑下去
    #   （只受 -MaxRounds 与风控/退出码约束）。老板此前已裁决"取消每日上限",所以"跑满 N 条就停"是可选行为。
    if ($Target -gt 0 -and $count -ge $Target) { Say ("已达标：$day count=$count >= $Target ⇒ 停"); break }

    # ★ [StopAt] 到点收工(不依赖人工):到点后**不再开新的一批**,直接跳出并打总账。
    if ($stopAtDt -and (Get-Date) -ge $stopAtDt) {
        Say ("已到停止时间 " + $StopAt + "（本机 " + (Get-Date -Format 'HH:mm:ss') + "）⇒ 收工，不再开新批次")
        break
    }

    # ★ [GH-36] 浏览器存活守护:9225 一没,批次必死、链路会静默停摆(2026-09-28 02:10 真实发生)。
    #   每轮开跑前查一次;不可达就调 gonghai_ensure 拉起,两次都拉不起来 ⇒ **停**(不空转)。
    if (-not (Test-GonghaiBrowserAlive)) {
        if (-not (Invoke-GonghaiEnsure)) {
            Say "拉起失败 ⇒ 等 30 秒再试一次"
            Start-Sleep -Seconds 30
            if (-not (Invoke-GonghaiEnsure)) { Say "两次拉起均失败 ⇒ 停止（需人工看 9225 / 登录态）"; break }
        }
        Say ("公海 Chrome 已恢复 ⇒ 继续")
    }

    # ★ 并发闸(双判据):
    #   ① 真实批次进程必须归零(含排除调用方自身的判据,GH-24;调用处 @() 包裹防解包,GH-29);
    #   ② 而且要**连续 $QuietSec 秒**都归零 —— 否则会撞进另一条链路的批间空档(约 3 秒)里。
    $quiet = 0
    while ($quiet -lt $QuietSec) {
        if (@(Get-RealBatchProcesses).Count -eq 0) { $quiet += 10 } else { $quiet = 0; }
        if ($quiet -lt $QuietSec) { Start-Sleep -Seconds 10 }
    }
    Say ("并发闸通过:已连续 " + $QuietSec + "s 无其它批次")

    $out = Join-Path $logDir ('gonghai_loop_r' + $round + '_' + (Get-Date -Format 'HHmmss') + '.txt')
    Say ("--- round $round start " + (Get-Date -Format 'HH:mm:ss') + " day=$day count=$count -> " + (Split-Path $out -Leaf))
    & powershell -ExecutionPolicy Bypass -NoProfile -File $batchScript -Batch $Batch 2>&1 | Tee-Object -FilePath $out
    $code = $LASTEXITCODE
    $count2 = Get-DayCount
    Say ("--- round $round end exit=$code count=$count2 " + (Get-Date -Format 'HH:mm:ss'))

    if ($code -eq 0) {
        # 解析 -StopAt（'HH:mm'，本机时间即北京时间）。非法格式 ⇒ 忽略并 WARN（不能因为参数写错就跑飞）。
$stopAtDt = $null
if ($StopAt) {
    $m = [regex]::Match($StopAt, '^\s*(\d{1,2}):(\d{2})\s*$')
    if ($m.Success) {
        $hh = [int]$m.Groups[1].Value; $mm = [int]$m.Groups[2].Value
        if ($hh -ge 0 -and $hh -le 23 -and $mm -ge 0 -and $mm -le 59) {
            $stopAtDt = (Get-Date).Date.AddHours($hh).AddMinutes($mm)
            # 若该时刻已过去超过 12 小时 ⇒ 视为"明天这个点"；否则就是今天（已过则立刻收工）
            if ((Get-Date) - $stopAtDt -gt (New-TimeSpan -Hours 12)) { $stopAtDt = $stopAtDt.AddDays(1) }
            Say ("停止时间 = " + $stopAtDt.ToString('yyyy-MM-dd HH:mm') + "（到点不再开新批次）")
        }
    }
    if (-not $stopAtDt) { Say ("WARN: -StopAt 格式无法识别('" + $StopAt + "') ⇒ 本次不设停止时间") }
}

        # [GH-58] ⚠️ 这里**不能**再 `$drainFailCount = @{}`：它必须跨轮累计（否则每轮清零，失败上限永不生效）。
        #   初始化在轮循环**之外**（见文件上方 `$recoverFails = 0` 旁边）。
        # ---- 待办队列定期补发（默认每 5 轮一次，每次最多 2 条，且只挑**入队 ≥6 小时**的）----
        #   为什么按年龄筛:GH-01 那批客户的头几次重试**必然失败**（阿里侧索引还没建），
        #   刚失败就重试纯属浪费页面时间（每次 6 轮搜索 ≈ 90 秒）。给足时间再补，才有机会捞回来。
        if ($DrainEveryRounds -gt 0 -and ($round % $DrainEveryRounds) -eq 0) {
            $cands = @()
            try {
                # [GH-55 2026-09-29 02:1x] **补发只挑"值得补"的原因类别**。
                #   实测证据（GH-47）：`INDEX_NOT_SYNCED`（阿里侧从未建索引）27 条 **0 成功**；
                #   而"我们没发成功"那几类（LOST_AFTER_ABORT / WRONG_CONVO / NOTSENT / NO_CARDID）
                #   补发成功率 **64%–82%**（2026-09-28 夜两次定向补发实测）。
                #   队列里前者常占 90%+ ⇒ 原实现按 updated_at 盲轮转，绝大多数尝试（每次 6 轮搜索≈90 秒）
                #   都花在**已知无收益**的条目上（约 12% 产能被吃掉）。现在只补后四类，收益≈100%。
                $drainReasons = @('LOST_AFTER_ABORT', 'WRONG_CONVO', 'NOTSENT', 'NO_CARDID')
                # [GH-58 2026-09-29 06:1x] **再补一层"重试次数上限"**：
                #   GH-55 之后候选只剩那 6 条可救的（4×LOST_AFTER_ABORT + 1×NOTSENT + 1×NO_CARDID），
                #   实测 `gh-2e16c1b0` / `gh-31e1a884` 这两条**每次都失败**（详情卡 customerId 与目标不符，
                #   是 key 级不符、不是名字问题）⇒ 每 5 轮白花约 3 分钟（≈12% 产能）在**已知补不出来**的条目上。
                #   加 `tries < 5` 上限：成功会出队、真能补的通常第一次就成（实测 82%）；
                #   试满 5 次仍失败的就不再占用页面时间（它们仍留在队列里，需要时可手工 `gonghai_recover.ps1`）。
                $drainMaxTries = 3
                $cands = @(Get-GonghaiPendingList | Where-Object {
                        $drainReasons -contains $_.reason -and
                        ([int]$drainFailCount[$_.key] -lt $drainMaxTries) -and
                        $_.added_at -and ((New-TimeSpan -Start ([datetime]$_.added_at) -End (Get-Date)).TotalHours -ge $DrainMinAgeHours)
                    } | Sort-Object updated_at, added_at | Select-Object -First $DrainCount)
                # [GH-45] ⚠️ 必须按 **updated_at**(最近一次尝试时间) 排序,不能只按 added_at:
                #   原实现按入队时间取前 N 个 ⇒ 每轮都挑**同样那两个最老的**,而它们大概率永远搜不到,
                #   于是补发永远在原地打转(实测 6 次补发全是同两个人),其余 90+ 条**永远轮不到**。
                #   按"最久没试过"排序 ⇒ 每轮自然轮转,全队列都能被覆盖到。
            } catch { $cands = @() }
            if ($cands.Count -eq 0) {
                Say ("--- 待办补发: 暂无满足条件(入队≥" + $DrainMinAgeHours + "h)的条目，跳过")
            } else {
                Say ("--- 待办补发 " + $cands.Count + " 条(入队≥" + $DrainMinAgeHours + "h)")
                foreach ($pd in $cands) {
                    # [GH-46b 2026-09-29] 老条目的 `code` 可能是空的（GH-46 之前入队的）⇒ 日志名/标签会空白。
                    #   这里就地推导：code 本来就是 key 的 sha1 前 8 位，推导无损（发送用的是 `-CustomerId $pd.key`，不受影响）。
                    $pc = if ($pd.code) { $pd.code } else { 'gh-' + (Get-GonghaiHash8 $pd.key) }
                    Say ("    retry " + $pc + " [" + $pd.reason + "] (入队 " + $pd.added_at + ", 本run内已失败 " + [int]$drainFailCount[$pd.key] + " 次)")
                    $pout = Join-Path $logDir ('gonghai_loop_drain_' + $pc + '_' + (Get-Date -Format 'HHmmss') + '.txt')
                    $pres = & powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $S 'gonghai\gonghai_probe.ps1') -RetryPending -CustomerId $pd.key 2>&1 | Tee-Object -FilePath $pout
                    # [GH-58 2026-09-29 06:2x] **本次运行内的失败计数**（本地、不依赖 pending.json 的 tries）：
                    #   为什么不能用 `tries`：它只在**重新入队**时由 Add-GonghaiPending 递增，
                    #   而补发失败（尤其 `ABORT_WRONG_CONVO` 这种"key 级不符"）**不重新入队** ⇒ tries 永远停在 1
                    #   （实测 gh-2e16c1b0 / gh-31e1a884 已补发 4+ 次仍显示 tries=1）⇒ 任何基于 tries 的上限都失效。
                    #   判据：输出里出现 SENT_OK / 已发 / ALREADY_SENT ⇒ 视为成功（出队或已发过）；否则计一次失败。
                    $ptxt = ($pres | Out-String)
                    if ($ptxt -match 'SENT_OK|✓ 已发|ALREADY_SENT') {
                        if ($drainFailCount.ContainsKey($pd.key)) { $drainFailCount.Remove($pd.key) | Out-Null }
                    } else {
                        $drainFailCount[$pd.key] = ([int]$drainFailCount[$pd.key] + 1)
                        Say ("      ↳ 补发未成功（本 run 内第 " + [int]$drainFailCount[$pd.key] + " 次）⇒ 失败满 3 次后本 run 不再占用页面时间")
                    }
                }
            }
        }
        Start-Sleep -Seconds 3
        continue
    }
    if ($code -eq 1) {
        $recoverFails++
        Say ("exit=1（列表冻结/认领异常等**可恢复**故障）第 $recoverFails 次 ⇒ 等 $RetryWaitSec 秒重试")
        if ($recoverFails -ge $MaxRecoverableRetry) { Say "连续 $MaxRecoverableRetry 次 exit=1 ⇒ 停（页面可能持续异常，需人工看台账 GH-27）"; break }
        Start-Sleep -Seconds $RetryWaitSec
        continue
    }
    # 9=风控 / 3=模块闸 / 4=配额 / 10=认领上限 —— 一律**立即停**,不重试、不绕过
    Say ("exit=$code（9=风控 3=模块闸 4=配额 10=认领上限）⇒ 立即停止，不重试")
    break
}
} finally {
    Release-AppLock $LockName
}

Say ("=== GONGHAI-LOOP done day=" + (Get-RateDay) + " count=" + (Get-DayCount) + " rounds=" + $round + " ===")
try { $pd = @(Get-GonghaiPendingList); Say ("待办队列剩余 = " + $pd.Count + " 条（可稍后 probe -RetryPending 补发）") } catch { }
if ($Target -gt 0 -and (Get-DayCount) -ge $Target) { exit 0 }
exit 0
