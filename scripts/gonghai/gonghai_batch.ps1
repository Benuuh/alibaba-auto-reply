# 公海批量：一次性认领 N 个 → 等索引同步 → 逐个搜索发送
#
# 用法:
#   gonghai_batch.ps1 -Batch 10                 # 完整流程（认领 → 等同步 → 发送）
#   gonghai_batch.ps1 -Batch 10 -DryRun         # 只认领，不发送
#   gonghai_batch.ps1 -Batch 10 -SkipClaim      # 跳过认领/等待，直接发送当前页这 N 个
#
# 设计要点（都是实测踩坑换来的，改前先读注释）:
#   · 写锁:抢不到要**耐心等**(monitor 每 9 秒一轮、每轮短暂持锁)；
#     但**绝不能长久占据** —— 实测持锁 45 秒会把 monitor 饿死 5 轮(连续 5 行 LOCK-BUSY)。
#   · [2026-09-27 修订] 锁范围 = **只包"页面写窗口"**:
#       认领窗口 = 「点一下『加为我的客户』」这一下;
#       发送窗口 = 「开搜索结果(读 customerId) → 核对 → 发送 → 恢复页面」。
#     为什么必须收窄:当天 monitor.log 里 LOCK-BUSY 844 次、单段最长 11.6 分钟**完全没有扫描**
#     (买家消息干等)。根因就是"认领生效轮询(最长 10×2 秒)""搜索""限速等待(最长 117 秒)"
#     全被算进了互斥窗口。这些步骤要么是只读、要么可由 Restore-OneTalkList 复原，
#     不需要互斥 ⇒ 一律移到锁外。
#     ⚠️ 硬约束**不放松**:"发对人校验"与"发送"必须在**同一个**锁窗口内。
#        校验完就放锁再发送，中间被换了会话就是发错人 —— 这条比缩锁重要。
#   · 依赖链三者缺一不可:lib\send.ps1 的 Send-OneTalkMessage 内部用 Get-StateKey，
#     而 Get-StateKey 在 reply_engine.ps1 里 ⇒ 少引一行就整段发送不可用。
#   · 认领生效必须**校验**(按钮消失或整行消失)，不能只看"点过了"。
#   · 每步失败立即停机报告；日志只记代号，不落明文 PII。
param(
    [ValidateRange(1, 20)][int]$Batch = 10,
    [switch]$DryRun,
    [switch]$SkipClaim,
    # [2026-09-27 收敛] 索引同步等待**预算**(秒):从进入阶段2 起算。
    #   为什么要有:原实现只要还剩 1 个人没同步就干等到 8 分钟上限 —— 实测(批次3/5)那 1 个
    #   straggler 让整批多花 6 分钟,而正常情况 10/10 只需 132–136 秒。
    #   现在:超预算的 straggler **转入待办队列**(pending.json),由 `probe -RetryPending` 补,
    #   批次不再为一个人停摆。设 0 表示"不等待,全部入队"。
    [ValidateRange(0, 480)][int]$SyncBudgetSec = 240,
    # [2026-09-27 提速] 停滞判据(秒):连续这么久**没有新增**同步成功就立刻止损。
    #   为什么比"预算"更合适:正常 10/10 只要 132–136s,而"永远不会同步"的 straggler 会让
    #   预算白等满(批次3 白等 350s、批次5 白等 371s、批次8 白等 181s)。有进展则继续等 ⇒ 不误杀慢客户。
    [ValidateRange(20, 300)][int]$SyncStallSec = 75
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$S = Split-Path $PSScriptRoot -Parent   # 本文件在 <部署根>\scripts\gonghai\ ⇒ 上一级即 scripts
. (Join-Path $S 'config.ps1')
. (Join-Path $S 'lib\log.ps1')
. (Join-Path $S 'lib\lock.ps1')
. (Join-Path $S 'lib\cdp.ps1')
. (Join-Path $S 'reply_engine.ps1')     # ← Get-StateKey 在这里（send.ps1 依赖它）
. (Join-Path $S 'lib\send.ps1')         # ← Send-OneTalkMessage
. (Join-Path $S 'gonghai\gonghai_cdp.ps1')
. (Join-Path $S 'gonghai\gonghai_lib.ps1')

function Say([string]$m) { Write-Output $m }
function HR() { Write-Output ("-" * 62) }
function Code8([string]$k) { return ("gh-" + (Get-GonghaiHash8 $k)) }

# [2026-09-27 收敛] 本文件**不再自带** Wait-Lock —— 用 lib 的 `Wait-GonghaiLock`
#   (同一份实现:等待期间不持有锁;probe 也用它)。
# [2026-09-27 GH-27] 本地 Read-Rows 已删除 —— 改用 gonghai_lib::Read-GonghaiPublicRows(带自愈:读失败自动刷新页重试)

$PORT = Get-GonghaiCdpPort
$NUL = Ensure-GonghaiOnetalkTab
$IB = Get-GonghaiIcebreaker
$CFG = Get-GonghaiConfig

# [2026-09-27 收敛] 模块闸:**第一道**,与 probe 同一实现(`Test-GonghaiRunnable`)。
#   此前 spec 判定链第 1 步(`disabled` 标记 / `gonghai_enabled`)没有任何脚本读它 ——
#   运行时 REPORT §7-2 登记的缺口。现在"模块能不能跑"有实现,且不满足即拒跑。
$RUN = Test-GonghaiRunnable
if (-not $RUN.ok) { Say ("ABORT " + $RUN.reason + "（公海模块不可运行:检查 data\gonghai\disabled 与 config 的 gonghai_enabled）"); exit 3 }

# [FIX-DAILY-CAP 2026-09-27 晚] 当日配额闸 + "按剩余额度夹批大小"。
#   为什么 batch 必须也检查:此前**只有 probe** 检查 `daily_cap`,batch 完全不检查
#     (runtime REPORT_回复闸门与公海缩锁_20260927.md §7-2 已登记的缺口)⇒ 一次 batch 就能越线。
#   现役 `gonghai_daily_cap` = 0 = **不限**(老板 2026-09-27 晚"取消每日的限制")
#     ⇒ 本闸恒放行、批大小也不夹;一旦有人把上限写回正数,这里会同时"拦住越线"与"只发剩余额度"。
#   ⚠️ 判据是 gonghai_lib 的**唯一**实现,不许在此重写一遍(否则两处口径必然漂移)。
$CAP = Test-GonghaiDailyCapReached
if ($CAP.reached) {
    Say ("ABORT DAILY_CAP (" + $CAP.daily + "/" + $CAP.cap + ")")
    exit 4
}
$effBatch = $Batch
if (-not $CAP.unlimited) {
    $left = [int]$CAP.cap - [int]$CAP.daily
    if ($left -lt $effBatch) { $effBatch = $left }
}

Say ("=== GONGHAI-BATCH " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " ===")
$capText = $(if ($CAP.unlimited) { "unlimited" } else { [string]$CAP.cap })
Say ("port=$PORT batch=$Batch effBatch=$effBatch dryRun=$($DryRun.IsPresent) skipClaim=$($SkipClaim.IsPresent) minGap=$($CFG.minIntervalMs)ms runCap=$($CFG.runCap) dailyCap=$capText todaySent=$($CAP.daily)")

# ---------- 阶段0：读公海列表 ----------
# [2026-09-27 GH-27] 改用 lib 的**带自愈**读法:该页会整个冻住(Runtime.evaluate 超时),
#   旧实现在这里直接抛异常 ⇒ 整批 exit 1(串联因此停机)。现在:读失败 ⇒ 刷新页 ⇒ 再读(最多 3 轮)。
HR; Say "[阶段0] 读公海列表"
$rows = Read-GonghaiPublicRows -MaxTries 3 -RetryWaitSec 12
if (-not $rows) {
    Say "  ABORT 公海列表读不到（3 轮重试含刷新页仍失败 ⇒ 页面可能仍冻结）"
    Write-GonghaiLog ("GONGHAI-LIST-DEAD " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    exit 1
}
$pool = @($rows.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.name })
Say ("  公海总数 = " + $rows.total + " ; 本页可用 = " + $pool.Count + " 行")
# [GH-52 2026-09-28 23:0x] ⚠️ **"0 行"不能直接 ABORT** —— 必须先走下面的"翻页找新鲜行"。
#   实测:池子首页可用行会一路缩到 **0**（22:58/23:03 两轮都是"本页可用 = 0 行"），
#   而原实现在这里直接 `exit 1` ⇒ **永远不去翻页** ⇒ 链路对着 3 万多人的池子干耗、每轮空转。
#   正确顺序:先用"翻页/刷新/关页重开"去把可用行捞回来,捞不到才判死。

# [GH-34 2026-09-28] **可用行不足**时自愈(三级)。目标：把每轮能认领的人数从"缩水后的 6"抢回 10。
#   实测(01:0x):第 1 页 10 行里**前 4 行是空行**(nameLen=-1),而且这 4 行的 key **不在我们账本里**
#   ⇒ 不是我们认领过的;换一张全新页面仍是 6 行 ⇒ **池子首页确实没那么多可认领的人**。
#   因此正解不是"刷新页面",而是**翻到下一页拿新鲜行**(共 3138 页)。
#   三级自愈(由轻到重,每级都**只有确实更多才采用**):
#     ① 翻下一页(轻、最可能有效) ② 导航刷新 ③ 关页重开(治渲染卡死,GH-31)
if ($pool.Count -lt $effBatch -and $pool.Count -lt 10) {
    Say ("  本页可用仅 " + $pool.Count + " 行 ⇒ 三级自愈(由轻到重)")
    $improved = $false

    # ① **连翻若干页**取新鲜行（[GH-52] 单翻一页可能仍是 0–2 行：实测首页可用会缩到 0，
    #    而池子里还有 3 万多人 ⇒ 必须能连着往后翻，直到凑够数或翻不动为止）
    $maxPages = 3
    for ($pg = 1; $pg -le $maxPages; $pg++) {
        if (-not (Move-GonghaiPublicListPage -Direction next -WaitSec 4)) {
            Say ("  第 " + $pg + " 次翻页不可用(无下一页/控件禁用) ⇒ 停止翻页")
            break
        }
        $rowsP = Read-GonghaiPublicRows -MaxTries 2 -RetryWaitSec 8
        if (-not $rowsP) { Say ("  第 " + $pg + " 次翻页后读不到"); continue }
        $poolP = @($rowsP.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.name })
        Say ("  翻到下一页面后可用 = " + $poolP.Count + " 行（第 " + $pg + " 次翻页）")
        if ($poolP.Count -gt $pool.Count) {
            $rows = $rowsP; $pool = $poolP; $improved = $true
            Say ("  已采用（可用 = " + $pool.Count + " 行）")
        }
        if ($pool.Count -ge $effBatch) { break }
    }

    # ② 导航刷新
    if (-not $improved) {
        try { Repair-GonghaiPublicListPage -WaitSec 12 } catch { }
        $rows2 = Read-GonghaiPublicRows -MaxTries 2 -RetryWaitSec 10
        if ($rows2) {
            $pool2 = @($rows2.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.name })
            if ($pool2.Count -gt $pool.Count) {
                $rows = $rows2; $pool = $pool2; $improved = $true
                Say ("  刷新后可用 = " + $pool.Count + " 行（已采用）")
            } else {
                Say ("  刷新后可用仍为 " + $pool2.Count + " 行（SPA 同 URL 导航常不重新拉数据）")
            }
        } else {
            Say "  刷新后读不到"
        }
    }

    # ③ 关页重开(治渲染卡死)
    if (-not $improved) {
        Say "  ⇒ 升级为**关页重开**再读（GH-31 实测这一招才能治渲染卡死）"
        try { Repair-GonghaiPublicListPage -WaitSec 15 -Force } catch { }
        $rows3 = Read-GonghaiPublicRows -MaxTries 2 -RetryWaitSec 10
        if ($rows3) {
            $pool3 = @($rows3.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.name })
            if ($pool3.Count -gt $pool.Count) {
                $rows = $rows3; $pool = $pool3
                Say ("  关页重开后可用 = " + $pool.Count + " 行（已采用）")
            } else {
                Say ("  关页重开后仍为 " + $pool3.Count + " 行 ⇒ 保持原样继续（本页确实只有这些人可认领）")
            }
        } else {
            Say "  关页重开后读不到 ⇒ 保持原样继续"
        }
    }

    # [GH-63 2026-09-29 22:4x] ⚠️ **翻过页就必须以"当前显示的那一页"为目标**。
    #   事故：三级自愈里翻页把视图挪到了第 N 页，但"没拿到更多行"时**不采纳**⇒
    #   `$pool` 仍是**最初那一页**的行键，而认领阶段是"按行键在 DOM 里找"（`tbody tr.ant-table-row`）
    #   ⇒ 当前页里当然找不到 ⇒ 连续三轮 `点击失败：ROW_GONE` ×9、`认领成功 0/N`、链路空转
    #   （实测 22:22/22:28/22:34 三轮全废；而成功那轮恰好"采纳了当前页"）。
    #   修法：自愈结束前**重读当前视图**并按它对齐（只要读得到 ≥1 行就采纳；读不到才保留原样）。
    try {
        $rowsNow = Read-GonghaiPublicRows -MaxTries 2 -RetryWaitSec 8
        if ($rowsNow) {
            $poolNow = @($rowsNow.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.name })
            if ($poolNow.Count -ge 1) {
                $sameKeys = ($poolNow.Count -eq $pool.Count) -and (@($poolNow | Where-Object { $_.key -notin @($pool.key) }).Count -eq 0)
                $rows = $rowsNow; $pool = $poolNow
                Say ("  ⇒ [GH-63] 以**当前显示页**为准：重读可用 = " + $pool.Count + " 行" + $(if ($sameKeys) { "（与原先相同）" } else { "（已对齐，原先那一页的行在此页找不到）" }))
            } else {
                Say "  [GH-63] 当前视图重读为 0 行 ⇒ 保持原样继续"
            }
        } else {
            Say "  [GH-63] 当前视图重读失败 ⇒ 保持原样继续"
        }
    } catch { Say ("  [GH-63] 当前视图重读异常 ⇒ 保持原样继续: " + $_.Exception.Message) }
}

# [GH-52] 三级自愈跑完仍是 0 行 ⇒ 现在才判死（原实现在自愈**之前**就 exit 1，导致永远不翻页）。
if ($pool.Count -eq 0) {
    Say "  ABORT 公海列表读不到可用行（翻页/刷新/关页重开都拿不到人 ⇒ 池子当前页确实空）"
    Write-GonghaiLog ("GONGHAI-POOL-EMPTY " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    exit 1
}
$targets = @($pool | Select-Object -First $effBatch)
Say ""
Say "  目标 $($targets.Count) 个："
$n = 0
foreach ($t in $targets) { $n++; Say ("    [$n] " + (Code8 $t.key) + "  nameLen=$($t.name.Length)") }

# ---------- [GH-39] 认领前的搜索健康闸（救命闸：不许再制造"已认领未激活"的客户）----------
#   事故当晚：OneTalk 数据面断开 ⇒ 搜索对**任何人**返回 0 结果（连已索引的老客户也搜不到），
#   而批次把"搜不到"当"索引未同步" ⇒ 照样认领 9-10 人、一个也发不出去，待办队列被冲到 60+。
#   现在：搜索不可用 ⇒ **一个都不认领**，直接 exit 1（可恢复故障，由 loop 等会儿重试）。
if ($targets.Count -gt 0) {
    $gate = Test-GonghaiSearchUsable
    if (-not $gate.ok) {
        # [GH-41] 先自愈一次：**重建 OneTalk 客户端页**（关页重开）。实测这是"搜索全 0"的**唯一有效修法**
        #   （重登无效、重启 Chrome 无效、普通刷新无效；关页重开后联系人 0→22、搜索随即恢复）。
        Say ("  搜索不可用 reason=" + $gate.reason + " ⇒ 自愈：重建 OneTalk 客户端页后复检")
        $rb = Repair-GonghaiOnetalkTab
        if ($rb) { $gate = Test-GonghaiSearchUsable }
        if (-not $gate.ok) {
            Say ("  ABORT GONGHAI-SEARCH-DOWN reason=" + $gate.reason + "（已尝试重建页面仍未恢复）⇒ 本轮**不认领任何人**")
            Write-GonghaiLog ("GONGHAI-SEARCH-DOWN " + $gate.reason + " " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            exit 1
        }
        Say "  重建后搜索已恢复 ⇒ 继续本轮"
    }
    Say "  搜索健康闸通过（数据面正常、烟雾搜索有结果）⇒ 开始认领"
}

# ---------- 阶段1：认领（-SkipClaim 时跳过）----------
$claimed = @()
$ready = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()

if ($SkipClaim) {
    HR; Say "[阶段1/2] 已跳过（-SkipClaim）：把这 $($targets.Count) 个当作已认领客户"
    $claimed = @($targets | ForEach-Object { [pscustomobject]@{ key = $_.key; name = $_.name; code = (Code8 $_.key) } })
    foreach ($c in $claimed) { $ready[$c.key] = $true }
}
else {
    HR; Say "[阶段1] 逐个认领（每个约 25 秒）"
    $n = 0
    foreach ($t in $targets) {
        $n++
        $code = Code8 $t.key
        Say ("  [$n/$($targets.Count)] 认领 $code …")
        $ok = $false
        # ★ 风控闸(§4-14):见验证码/滑块/"操作过于频繁" ⇒ **立即停机**,不重试、不绕过。
        #   为什么放在每一行认领前:老板 2026-09-27 深夜取消了"最小间隔"这道闸 ⇒
        #   风控探测成为**唯一的主动止损手段**,必须逐行探(一次 eval,约 0.3s)。
        $rkClaim = Get-GonghaiRiskSignal -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
        if ($rkClaim.risk) {
            Say ("  ABORT RISK_SIGNAL(公海页) " + ($rkClaim.raw -replace '\s+',' '))
            Write-GonghaiLog ("GONGHAI-RISK-ABORT claims " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            exit 9
        } elseif ($rkClaim.raw -eq 'eval-failed') {
            # [2026-09-27] 探针**求值失败**时原来静默当成"安全"(Get-GonghaiRiskSignal 内部 catch 后返回 risk=false)
            #   ⇒ 唯一的止损手段可能无声失效。这里显式告警,让人能从日志看出"这段没探到"。
            Say "       WARN 风控探针求值失败(eval-failed)——本次未探到,不视为安全"
            Write-GonghaiLog ("GONGHAI-RISK-EVALFAIL claims " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        }
        # ★ 锁窗口①：只包住"点一下按钮"这一下页面写。
        #   为什么:生效校验(Test-GonghaiRowClaimed)只是读 DOM、不写页面，却要轮询最多 10×2 秒；
        #   原实现把它算在锁里 ⇒ 单行最多占锁约 27 秒，10 行连起来能把 monitor 饿死 4 分钟以上。
        if (-not (Wait-GonghaiLock -MaxWaitSec 90).ok) { Say "       抢锁超时 90 秒，跳过这个"; continue }
        $res = $null
        try {
            $res = Invoke-GonghaiClaimRow -Key $t.key
        } catch {
            # [2026-09-27 GH-27] 公海页**冻住**时 CDP 求值会超时抛异常 —— 旧实现直接打死整批。
            #   现在:转成"这一行失败",继续下一行(该客户仍在公海列表里,下一批还能认领,无损失)。
            Say ("       认领异常(页面可能冻结): " + ($_.Exception.Message -replace '\s+',' '))
            Write-GonghaiLog ("GONGHAI-CLAIM-ERR " + $code + " " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            $res = [pscustomobject]@{ ok = $false; err = 'EXCEPTION'; limitHit = $false; limitTxt = '' }
        } finally {
            # 用 finally 覆盖"点击成功/失败/抛异常"全部退出方式:任何路径都不留锁。
            # (limitHit 的 exit 10 也在这之后才判，所以退出前锁一定已释放。)
            Release-AppLock 'onetalk-write'
        }
        if ($res.limitHit) { Say "  ABORT 认领上限提示：$($res.limitTxt)"; exit 10 }
        if (-not $res.ok) { Say "       点击失败：$($res.err)" }
        else {
            # 生效校验（**锁外**，纯只读轮询）:判据见 gonghai_lib 的 Test-GonghaiRowClaimed
            #   ——「行消失」或「加为我的客户按钮消失」任一成立才算认领生效。
            $vf = $false
            for ($w = 1; $w -le 10; $w++) {
                Start-Sleep -Seconds 2
                $chk = Test-GonghaiRowClaimed -Key $t.key
                if ($chk.gone -or -not $chk.hasClaim) { $vf = $true; break }
            }
            if ($vf) { $ok = $true; Say "       ✓ 认领生效" }
            else { Say "       ✗ 点击已发但列表未变化（视为未认领）" }
        }
        if ($ok) { $claimed += [pscustomobject]@{ key = $t.key; name = $t.name; code = $code } }
        else { Say "       跳过这个（认领没成功）" }
        Start-Sleep -Milliseconds 600
    }
    Say ""
    Say ("  认领成功 $($claimed.Count) / $($targets.Count)")
    if ($claimed.Count -eq 0) { Say "ABORT 一个都没认领成功"; exit 1 }

    if ($DryRun) {
        HR; Say "[DryRun] 到此停止，不等待、不搜索、不发送"
        Say "  已认领名单（明文仅此处显示，不落盘）："
        foreach ($c in $claimed) { Say ("    " + $c.code + "  " + $c.name) }
        exit 0
    }

    # ---------- 阶段2：等索引同步（**自适应止损**：有进展就继续等，停滞就立刻走）----------
    # [2026-09-27 收敛] 实测:正常 10/10 只需 132–136 秒。旧实现只要还剩 1 个就用满预算/上限:
    #   批次3 白等 350 秒、批次5 白等 371 秒、批次8 白等 181 秒 —— 全是**已经不会再变**的等待。
    #   现在判据换成"**还有没有新进展**":每轮记住已同步条数,一旦连续 $SyncStallSec 秒没有新增,
    #   立刻止损(而不是等满 240s)。有进展就继续等 ⇒ 不牺牲"慢一点但会同步"的客户。
    HR; Say ("[阶段2] 等 OneTalk 索引同步（停滞 " + $SyncStallSec + "s 即止损，预算 " + $SyncBudgetSec + "s）")
    $syncDeadline = (Get-Date).AddSeconds($SyncBudgetSec)
    $lastProgress = Get-Date
    while ((Get-Date) -lt $syncDeadline -and $sw.Elapsed.TotalMinutes -lt 8) {
        $todo = @($claimed | Where-Object { -not $ready.ContainsKey($_.key) })
        if ($todo.Count -eq 0) { break }
        $before = $ready.Count
        foreach ($c in $todo) {
            $op = Open-OneTalkSearchPanel
            if (-not $op.ok) { continue }
            $sr = Invoke-OneTalkSearch -Keyword $c.name
            if (-not $sr.ok) { continue }
            Start-Sleep -Seconds 2
            $rc = Get-GonghaiSearchResultCount
            if ($rc.n -ge 1) { $ready[$c.key] = $true; Say ("  ✓ " + $c.code + " 已可搜到  (t+" + [int]$sw.Elapsed.TotalSeconds + "s)") }
        }
        if ($ready.Count -gt $before) { $lastProgress = Get-Date }
        $left = @($claimed | Where-Object { -not $ready.ContainsKey($_.key) }).Count
        if ($left -gt 0) {
            if (((Get-Date) - $lastProgress).TotalSeconds -ge $SyncStallSec) {
                Say ("  ⏹ 已停滞 " + $SyncStallSec + "s 无新增同步 ⇒ 止损（剩下 $left 个入待办队列）")
                break
            }
            Say ("  …还有 $left 个未同步，等 20 秒 (t+" + [int]$sw.Elapsed.TotalSeconds + "s)"); Start-Sleep -Seconds 20
        }
    }
    # straggler 一律入待办队列:他们已经认领走(公海列表里没了),不入队就等于永久失联。
    $stragglers = @($claimed | Where-Object { -not $ready.ContainsKey($_.key) })
    foreach ($c in $stragglers) {
        Say ("  ⏳ " + $c.code + " 索引未同步 ⇒ 入待办队列（原因 INDEX_NOT_SYNCED）")
        Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $c.code -Reason 'INDEX_NOT_SYNCED'
    }
    Say ("  同步完成：$($ready.Count) / $($claimed.Count)  (用时 $([int]$sw.Elapsed.TotalSeconds)s,入队 $($stragglers.Count))")
}

# ---------- 阶段3：逐个搜索 + 核对 + 发送 ----------
# ★ 锁范围（2026-09-27 修订）:**只有**「开搜索结果(读 customerId) → 核对 → 发送 → 恢复页面」
#   这一段在锁里。搜索/展开面板/限速等待/幂等记账全部移到锁外，理由:
#     ① 它们的页面副作用(搜索框被填)由 Restore-OneTalkList 负责复原，不需要与 monitor 互斥；
#     ② 阶段2 的索引探测本来就是无锁搜索，两边口径一致；
#     ③ 发错人的风险由"核对与发送同窗口"消除（见下面 ★ 硬约束），缩锁不牺牲它。
# ⛔ [FIX-DRYRUN 2026-09-27] -DryRun 必须在**任何参数组合**下都不发送。
#   原实现只在阶段1(认领)的出口判 DryRun（L153 附近）⇒ 与 -SkipClaim 同用时那个出口**根本到不了**,
#   阶段3 会**真发**给真人。而本脚本自己的用法示例写的是 `-DryRun # 只认领，不发送` ——
#   语义被破坏 = 一次手滑就是对外发送(不可逆)。故补一道与分支无关的闸。
if ($DryRun) {
    HR; Say "[DryRun] 阶段3 不发送（-SkipClaim 不能绕过 DryRun）；已跳过搜索/核对/发送"
    exit 0
}
HR; Say "[阶段3] 逐个搜索 + 核对身份 + 发送"
$sent = 0; $fail = 0; $sentKeys = New-Object System.Collections.Generic.List[string]   # [GH-44] 记录已发成功的 key,供中断兜底判断
$abort = $false; $riskAbort = $false   # [GH-53] $riskAbort = 风控命中(决定本批是否 exit 9)
$n = 0
foreach ($c in $claimed) {
    $n++
    if (-not $ready.ContainsKey($c.key)) { Say ("  [$n] " + $c.code + " 索引未同步，跳过"); $fail++; continue }
    Say ("  [$n/$($claimed.Count)] " + $c.code + " …")

    # ★ 风控闸(§4-14;锁外只读探针):见验证码/滑块/"操作过于频繁" ⇒ **立即停机**。
    #   为什么每条都探:最小间隔已取消(老板 2026-09-27 深夜)⇒ 这里就是唯一的主动止损点。
    $rkSend = Get-GonghaiRiskSignal -UrlMatch (Get-GonghaiOnetalkUrlMatch)
    if ($rkSend.risk) {
        Say ("       ABORT RISK_SIGNAL(OneTalk) " + ($rkSend.raw -replace '\s+',' '))
        Write-GonghaiLog ("GONGHAI-RISK-ABORT send " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        # 🔴 [GH-53 2026-09-29 00:0x] **必须标记"风控停机"，让本批最后 `exit 9`**。
        #   原实现只写 `$abort = $true; break`（只跳出本轮的 foreach）⇒ 批次照常走到结尾、
        #   **以 exit 0 正常退出** ⇒ loop 以为这轮成功、**在风控持续命中的情况下每 3 分钟继续认领新客户**。
        #   实测后果:23:50/23:53/23:57 连续 3 次 `GONGHAI-RISK-ABORT send`，而 loop 仍在开新批次，
        #   把"认领了却发不出去"的队列从 122 冲到 **149**。这违背老板的硬要求"风控命中即停机"。
        #   现在:先 `$abort`（停本轮、让下面的 GH-44 兜底把未发的人入队），再由文件末尾统一 `exit 9`。
        $abort = $true; $riskAbort = $true; break
    } elseif ($rkSend.raw -eq 'eval-failed') {
        # 同认领侧:求值失败原来静默当"安全" ⇒ 显式告警(见上)
        Say "       WARN 风控探针求值失败(eval-failed)——本次未探到,不视为安全"
        Write-GonghaiLog ("GONGHAI-RISK-EVALFAIL send " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    }

    # 限速等待（锁外）:间隔已取消 ⇒ waitMs=0,这里恒不等;
    #   若将来把 `gonghai_min_interval_ms` 写回正数,本块自动恢复原有节流。
    $gate = Test-GonghaiRateGate
    if (-not $gate.ok) {
        $need = [int](($gate.waitMs - $gate.waitedMs) / 1000)
        if ($need -gt 0) { Say ("       RATE_WAIT ${need}s"); Start-Sleep -Seconds $need }
    }

    # 页面句柄（锁外）:页被关掉时 Ensure 会在公海端口上新开页并轮询最长 15 秒
    #   —— 那 15 秒属于"等页面就绪"，不属于"写页面"，不该占互斥窗口。
    $page = Ensure-GonghaiOnetalkTab
    if (-not $page) { Say "       ABORT 公海端口上没有 OneTalk 页（拒绝回退到 monitor 的实例）"; break }

    # ---- 搜索定位（锁外）----
    $op = Open-OneTalkSearchPanel
    $sr = Invoke-OneTalkSearch -Keyword $c.name
    Start-Sleep -Seconds 2
    $rc = Get-GonghaiSearchResultCount
    if ($rc.n -lt 1) {
        Say "       搜索 0 结果，跳过（入待办队列）"; $fail++
        Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $c.code -Reason 'INDEX_NOT_SYNCED'
        # ⚠️ 页面上已经搜过 ⇒ 收尾必须恢复（§6.5.14）。这条路径没进锁，
        #    所以不能靠下面的 finally:要在这里显式恢复一次，否则会给下一个使用者留下搜索态。
        try { [void](Restore-OneTalkList) } catch { }
        continue
    }

    # ★ 发送窗口（**唯一实现**在 gonghai_lib.ps1；batch 与 probe 共用同一份）:
    #   取锁 → 开结果(按 customerId 挑人) → 核对身份 → 先写后发 → 发送 → 恢复页面 → 释放锁。
    #   2026-09-27 收敛原因:原来是**batch 内联一份、probe 里再一份**,结果同一判据一处 fail-open、
    #   一处 fail-closed(当天 6 条发送事故)。现在窗口边界只有一处定义,两个入口不可能再漂移。
    #   ⚠️ 硬约束不变:身份核对与发送必须在**同一个**锁窗口内(spec §6.5.5)。
    $open = $null
    $W = Invoke-GonghaiSendWindow -Code $c.code -ExpectedName $c.name -ExpectedKey $c.key `
            -Text $IB -Page $page -Index (Get-GonghaiSentIndex) -MaxWaitSec 60
    if ($W.open) { $open = $W.open; Say ("       open: tried=" + $open.tried + " cardId=" + $open.cardIdAbbrev) }
    switch ([string]$W.verdict) {
        'LOCK_BUSY'   { Say "       ABORT 抢锁超时 60 秒"; $abort = $true }
        'NO_TAB'      { Say "       ABORT 公海端口上没有 OneTalk 页（拒绝回退到 monitor 的实例）"; $abort = $true }
        'WRONG_CONVO' {
            # [GH-48 2026-09-28] **不再把"这一个人搜不到对的人"当成整轮致命**。
            #   原因:名字撞车 / 占位名（"User name" / "S S" / "n t"）是**单个客户**的常态,
            #   原先 `$abort = true` 会把**该轮剩余所有名额一起掐掉**——
            #   实测当晚出现 6-7 次、每次损失 4-10 个名额（只能靠 GH-44 兜底入队、再靠补发救回）。
            #   安全性**不受影响**:每一位客户在发送前都各自在**同一个锁窗口内**独立做
            #   customerId 身份核对（`Invoke-GonghaiSendWindow` 的硬约束）⇒ "继续下一位"绝不会发错人,
            #   只是把**这一个人**放进待办队列等重试。
            #   ⚠️ 仍然会停机的情形保留不变:风控信号(exit 9)、抢锁超时(LOCK_BUSY)、公海端口没有 OneTalk 页(NO_TAB)。
            Say ("       WRONG_CONVO expected=" + $c.key.Substring(0,8) + " actual=" + $open.cardId.Substring(0,8) + " ⇒ 这一个人发不了（入待办队列），继续下一位")
            Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $c.code -Reason 'WRONG_CONVO'
            $fail++
        }
        'NO_CARDID'   {
            # 读不到 customerId ⇒ 无法证明发对人 ⇒ 拒发（fail-closed）。入队等重试,不静默丢弃。
            Say "       SKIP NO_CARDID（详情卡读不到 customerId，无法证明发对人）⇒ 入待办队列"
            Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $c.code -Reason 'NO_CARDID'
            $fail++
        }
        'DONE' {
            # ⚠️ 必须**加括号**:`Say "x" + $y` 在参数模式下会被当成三个参数(PowerShell 经典坑,
            #   实测 2026-09-27 批次6 打出空的 `send:` —— 状态是对的,但输出丢了发送返回串)。
            Say ("       send: " + ($W.send -replace '\s+',' '))
            if ($W.status -eq 'sent') {
                Say ("       ✓ 已发 " + $c.code); $sent++; [void]$sentKeys.Add($c.key)
            } elseif ($W.status -eq 'notsent') {
                # 可证明没发出去(没填字/没点发送) ⇒ 入队重试,不当成"失败就完了"
                Say ("       GONGHAI-NOTSENT ⇒ 入待办队列"); $fail++
                Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $c.code -Reason 'NOTSENT'
            } elseif ($W.status -eq 'failed') {
                # 结果未知(点了发送但输入框没清空) ⇒ 保守:记 failed、**不入队**(避免重复打扰)
                Say ("       GONGHAI-FAILED-UNKNOWN（结果未知，保守处理：不重试）"); $fail++
            } else {
                Say ("       (DryRun 未发送)"); 
            }
        }
        default {
            Say ("       未确认（" + $W.verdict + "），跳过"); $fail++
        }
    }
    if ($abort) { break }
}

# ---------- [GH-44] 中断路径的兜底:把"已认领但没发成功"的人**全部**补进待办队列 ----------
#   为什么必须在这里做:2026-09-28 05:00 那三轮 `ABORT_WRONG_CONVO` 停机时,批次只把
#   "索引未同步"那 1 个入了队,**其余 9-10 个已认领、未发送的人直接丢了**
#   (公海列表里已经没有了 ⇒ 不入队就等于永久失联)。事后只能靠人工翻「我的客户」列表反查 code→key 找回。
#   判据:凡是"认领成功"但**既没进已发集合、也没进过待办队列**的,一律入队(原因 LOST_AFTER_ABORT)。
#   幂等:Add-GonghaiPending 对同一 key 是覆盖写,重复调用不会产生重复条目。
if ($abort -and -not $SkipClaim) {   # ⚠️ 不要加 `$script:Abort`:批次里只有局部 `$abort`,那个变量在此文件不存在 ⇒ 会让整块永不执行
    $sentKeys = @($sentKeys)
    $lost = @()
    foreach ($c in $claimed) {
        if ($sentKeys -contains $c.key) { continue }
        if (Test-GonghaiAlreadySent -Index (Get-GonghaiSentIndex) -CustomerKey $c.key) { continue }
        $lost += $c
    }
    if (@($lost).Count -gt 0) {
        Say ("[GH-44] 中断兜底:把 " + @($lost).Count + " 个已认领未发送的人补进待办队列")
        foreach ($c in $lost) {
            Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Reason 'LOST_AFTER_ABORT'
            Say ("    ⏳ " + $c.code + " ⇒ 入待办队列（原因 LOST_AFTER_ABORT）")
        }
    }
}

try { [void](Restore-OneTalkList) } catch { }

HR
Say ("=== done: 认领 $($claimed.Count) / 已发 $sent / 失败 $fail / 用时 $([int]$sw.Elapsed.TotalSeconds)s ===")
if ($sent -gt 0) { Say "GONGHAI-BATCH-SENT $sent" }

# [GH-53 2026-09-29] **风控命中 ⇒ 以 exit 9 结束**（loop 收到 9 立即停机、不重试、不绕过）。
#   放在文件最后:先让上面的 GH-44 兜底把"已认领未发送"的人全部入队、并恢复页面状态,再退出。
#   为什么必须在这里:原实现只 `$abort = $true; break`（只跳出本轮 foreach）⇒ 批次以 **exit 0** 正常收尾,
#   loop 以为这轮成功 ⇒ **在风控持续命中时每 3 分钟继续认领新客户**（实测 23:50/23:53/23:57 连续三次命中,
#   队列被从 122 冲到 149）。这违背老板的硬要求"风控命中即停机"。
if ($riskAbort) {
    Say "  ⇒ 风控命中（发送阶段）：本批以 exit 9 结束 ⇒ 串联会**立即停机**（不重试、不绕过）"
    Write-GonghaiLog ("GONGHAI-RISK-STOP-EXIT9 " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    exit 9
}
