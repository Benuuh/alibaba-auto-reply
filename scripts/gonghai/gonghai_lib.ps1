# gonghai/gonghai_lib.ps1 - 公海开发模块共享库:限速 / 幂等 / 状态 / 页面恢复 / 发送。
#
# 依赖:scripts\config.ps1(Get-SkillConfig / Get-SkillPath)、scripts\lib\lock.ps1、
#       scripts\lib\log.ps1、scripts\lib\cdp.ps1(Test-PageHealth)、gonghai\gonghai_cdp.ps1。
#
# 硬约束(本 spec,不得放宽):
#   §6.5.4 限速:最小间隔 >= 90000ms(90s),抖动 ±30%(即 63–117s);单次运行上限 3 条(硬编码)。
#   §6.5.2 页面写锁必须复用 lib\lock.ps1 的 Get-AppLock 'onetalk-write'。
#   §6.5.2 页面健康判定必须复用 lib\cdp.ps1 的 Test-PageHealth。
#   §6.5.2 日志必须复用 lib\log.ps1 的 Write-SkillLog。
#   §6.5.14 任何操作 OneTalk 的收尾**必须**把页面恢复到"会话列表可见"(清空搜索 → 点「全部」→ 断言 >0),
#          否则会给 monitor 留下一个空列表。
#   §4-6   本文件必须 UTF-8 带 BOM。
# 编码:UTF-8 带 BOM。

# ---- 单次运行上限(可调常量;§6.5.4。老板 2026-09-27 16:46 裁决:3 → 10) ----
#   ⚠️ 变更留痕:原值 3,注释为"硬编码;禁止调高"。
#   老板明确要求"单次处理 10 个人" ⇒ 上调为 10。风控风险随批量线性上升,由老板承担。
#   与 config.json 的 gonghai_run_cap 的关系:两者取小(见 Get-GonghaiConfig 的夹取逻辑)。
#   若要再调大,**这三处必须同时改**,否则会被静默夹回:
#     ① 本常量 ② config.json / config.json.example 的 gonghai_run_cap ③ probe 的 ValidateRange。
$script:GonghaiRunCapHard = 10

# ---- 当日配额(§6.5.4;老板 2026-09-27 晚裁决:**取消每日限制** ⇒ 现役 = 0 = 不限) ----
#   ⚠️ 变更留痕:原值 20(每日上限)。老板明确要求"取消每日的限制" ⇒ config.json 与
#      config.json.example 都设为 0,语义见 Test-GonghaiDailyCapReached(0 或负数 = 不限)。
#      不放松的仍然是:单次上限(10 条);被取消的**只有**每日总量这一条。
#      若要恢复限制:把 `gonghai_daily_cap` 写成正数即可,probe 与 batch 会一起生效。
$script:GonghaiDailyCapDefault = 20

# ---- 最小间隔(毫秒;**下限 = 0 = 不间隔**) ----
#   ⚠️ 变更留痕:原值 90000,注释为"硬编码下限;禁止调低"。**老板 2026-09-27 深夜裁决:取消这个限制**
#      (原话"取消这个限制";直接动因:单批 ~64% 的时间花在这一条上)。
#   ⇒ 现役 = 0 ⇒ `Get-GonghaiWaitMs` 恒返回 0、限速门恒放行,每条之间只剩页面操作耗时(约 15–20 秒)。
#   语义:0/负数 = 不间隔;**要恢复节奏就把 config 的 `gonghai_min_interval_ms` 写回正数**
#      (例如 90000),无需改代码 —— 与"取消每日配额"同款做法,判据只有一处实现。
#   ⚠️ 间隔闸取消后,**风控闸成为唯一的主动止损手段**:`Get-GonghaiRiskSignal`(验证码/滑块/频繁)
#      已同时接到 batch 与 probe 的主流程(见各自调用点)。
$script:GonghaiMinIntervalFloorMs = 0

# ---- [SPEC-公海独立Chrome 2026-09-27 §3.3] 公海 OneTalk 页的匹配串 ----
# ⚠️ 语义已回到最朴素的一版:**就是 onetalk 域名**,不带任何标记。
#   为什么:公海现在跑在自己的 Chrome 上(9225 + chrome-profile-gonghai),
#   这个端口上只会有公海自己的页 ⇒ 不需要标记,也不可能取到 monitor 的页(spec §2.1)。
#   [SPEC-公海页面隔离 2026-09-27] 那份 spec 的 `dshgh=1` 标记方案已按本 spec §2.2 **整体撤销**。
# 为什么仍然用函数取而不是直接写 `$script:OnetalkUrlPattern`:
#   本文件被单独 dot-source 时(例如 tests\gonghai.tests.ps1)并没有加载 gonghai_cdp.ps1,
#   而 PowerShell 的参数缺省值在**每次调用时**求值 ⇒ 用函数可以既"优先用 gonghai_cdp.ps1 的
#   权威值",又在未加载时兜底,不至于让缺省值变成 $null(那会让 `-match $null` 恒真 = 完全不设防)。
function Get-GonghaiOnetalkUrlMatch {
    if ($script:OnetalkUrlPattern) { return [string]$script:OnetalkUrlPattern }
    return 'onetalk\.alibaba\.com'
}

function ConvertFrom-GonghaiOutput {
    # 从 eval 输出里安全取出最外层 JSON 对象。
    # 为什么不用 `-match '(?s)\{.*\}'`:那是**贪婪**匹配,遇到"输出里有两个对象"
    # 或客户名里带花括号时会截错。这里用花括号深度扫描,取第一个完整对象。
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $start = $Raw.IndexOf('{')
    if ($start -lt 0) { return $null }
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $start; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($ch -eq '\') { $esc = $true }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $json = $Raw.Substring($start, $i - $start + 1)
                try { return ($json | ConvertFrom-Json) } catch { return $null }
            }
        }
    }
    return $null
}

function Get-GonghaiPath {
    # 全部状态落在运行数据根下(含 PII/状态,不入库)
    param([string]$Name)
    $dataDir = Get-SkillPath "data"
    $dir = Join-Path $dataDir "gonghai"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir $Name)
}

function Test-GonghaiDisabled {
    # disabled 标记 => 模块停用(照 control-agent.disabled 先例)
    return (Test-Path (Get-GonghaiPath "disabled"))
}

function Read-GonghaiStateJson {
    param([string]$Path, $Default = $null)
    if (-not (Test-Path $Path)) { return $Default }
    try { return ((Get-Content $Path -Raw -Encoding UTF8) | ConvertFrom-Json) } catch { return $Default }
}

function Write-GonghaiJson {
    # 原子写:临时文件 + Move-Item -Force(§6.5.3)
    param([string]$Path, $Obj)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $env:TEMP ("gh_" + [Guid]::NewGuid().ToString("N") + ".json")
    $json = $Obj | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $Path -Force
}

function Get-GonghaiHash8 {
    param([string]$Text)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        $hash = $sha1.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 8)
    } finally { $sha1.Dispose() }
}

function Get-GonghaiIcebreaker {
    # 读取老板定稿话术(§6.5.15):取第一个非空、非注释行。**不做变量替换、不做个性化**。
    $p = Join-Path $PSScriptRoot "icebreaker.md"
    if (-not (Test-Path $p)) { throw "ICEBREAKER_MISSING: $p" }
    $lines = Get-Content $p -Encoding UTF8
    foreach ($l in $lines) {
        $t = ([string]$l).Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('<')) { continue }      # 跳过 HTML 注释行
        return $t
    }
    throw "ICEBREAKER_EMPTY: $p"
}

function Get-GonghaiIcebreakerId {
    # icebreaker_id = 文件内容 sha1 前 8 位(§6.5.15-3):
    #   话术一改,幂等键随之改变 => **有意设计**:改话术后允许对同一客户重发一次新版。
    $text = Get-GonghaiIcebreaker
    return (Get-GonghaiHash8 $text)
}

# ---- 幂等账本 sent_index.json(§6.5.3) ----
function Get-GonghaiSentIndex {
    $p = Get-GonghaiPath "sent_index.json"
    $o = Read-GonghaiStateJson $p $null
    if (-not $o) { return [pscustomobject]@{ version = 1; items = [pscustomobject]@{} } }
    if (-not ($o.PSObject.Properties.Name -contains 'items')) { $o | Add-Member -NotePropertyName items -NotePropertyValue ([pscustomobject]@{}) -Force }
    return $o
}

# ---- 账本状态语义(2026-09-27 收敛;状态只允许这四个) ----
#   sent      : 发送成功(输入框已清空 = 发出去的实证)          ⇒ 永远拒发
#   unverified: 「先写后发」留下的记录(进程在发送中途死了)      ⇒ **拒发**(崩溃防线,§6.5.3)
#   notsent   : **可证明没发出去**(开会话失败/发对人校验失败/没有输入框/没有发送按钮)
#               ⇒ **允许重试**(人不该因为一次页面故障被永久拉黑)
#   failed    : 结果**未知**(点了发送但输入框没清空)            ⇒ 拒发(保守:可能已经发出去了)
#   事故背景:2026-09-27 批次3 有 6 条发送在 `OPEN_FAIL (NOT_FOUND)` 处失败并被写成 `failed`,
#   而旧判据**只看 key_hash、不看 status** ⇒ 这 6 个人被永久拒发,只能手工清账本才补发成功。
$script:GonghaiRetryableStatus = 'notsent'

function Get-GonghaiSendStatus([string]$SendResult) {
    # 把 Send-OneTalkMessage 的返回串映射成账本状态(唯一映射处,调用方不许再各写一份)
    if (-not $SendResult) { return '' }                       # 窗口没走到发送那一步 ⇒ 不记账
    if ($SendResult -match 'SENT_OK') { return 'sent' }
    if ($SendResult -match 'OPEN_FAIL|ABORT_WRONG_CONVO|ABORT_WRONG_PAGE|NO_TEXTAREA|NO_BTN') { return 'notsent' }
    return 'failed'
}

function Test-GonghaiAlreadySent {
    # 判定顺序第 3 条(§6.5.3):**崩溃重启的唯一防线**。
    #   ⚠️ 2026-09-27 收敛:命中记录后还要看 status —— `notsent`(可证明没发出去)必须允许重试,
    #      否则一次页面故障就把这个人永久拉黑(当天真实事故)。其余状态一律拒发。
    param($Index, [string]$CustomerKey)
    $keyHash = Get-GonghaiHash8 ($CustomerKey + "|" + (Get-GonghaiIcebreakerId))
    if (-not $Index.items) { return $false }
    foreach ($prop in $Index.items.PSObject.Properties) {
        $v = $prop.Value
        if (-not $v) { continue }
        if (-not ($v.PSObject.Properties.Name -contains 'key_hash')) { continue }
        if ([string]$v.key_hash -ne $keyHash) { continue }
        $st = ''
        if ($v.PSObject.Properties.Name -contains 'status') { $st = [string]$v.status }
        if ($st -eq $script:GonghaiRetryableStatus) {
            Write-GonghaiLog ("GONGHAI-RETRY-NOTSENT " + $(if ($v.PSObject.Properties.Name -contains 'code_name') { [string]$v.code_name } else { '?' }) + " (账本状态=notsent ⇒ 允许重试)")
            return $false
        }
        return $true
    }
    return $false
}

function Complete-GonghaiSend {
    # 发送结果记账(**唯一处**):账本状态 + 限速 + `GONGHAI-SENT` 日志。
    #   把"返回串 → 状态 → 三处写"收在一个函数里,是为了让 batch/probe **不可能**再各写一份
    #   (2026-09-27 的教训:同一个判据两处实现 ⇒ 一处 fail-open 另一处 fail-closed)。
    param($Index, [string]$CustomerKey, [string]$Code, [string]$SendResult)
    $status = Get-GonghaiSendStatus $SendResult
    if (-not $status) { return '' }
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [void](Set-GonghaiSentRecord -Index $Index -CustomerKey $CustomerKey -Status $status -CodeName $Code)
    if ($status -eq 'sent') {
        Set-GonghaiRate -LastSentAt $now
        Write-GonghaiLog ("GONGHAI-SENT " + $Code + " " + $now)
    } elseif ($status -eq 'notsent') {
        Write-GonghaiLog ("GONGHAI-NOTSENT " + $Code + " " + $now)
    } else {
        Write-GonghaiLog ("GONGHAI-FAILED-UNKNOWN " + $Code + " " + $now)
    }
    return $status
}


function Set-GonghaiSentRecord {
    # **先写后发**(§6.5.3):宁可留 unverified,也不可漏记(漏记 = 可能重发骚扰)
    param(
        $Index,
        [string]$CustomerKey,
        [string]$Status,                 # sent | unverified | notsent | failed(语义见上方 §账本状态语义)
        [string]$CodeName                # 代号(日志/PII 纪律)
    )
    $keyHash = Get-GonghaiHash8 ($CustomerKey + "|" + (Get-GonghaiIcebreakerId))
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $existing = $null
    foreach ($prop in $Index.items.PSObject.Properties) {
        if ($prop.Name -eq $CustomerKey) { $existing = $prop.Value; break }
    }
    $attempts = 1
    $firstSent = $now
    if ($existing) {
        if ($existing.PSObject.Properties.Name -contains 'attempts') { $attempts = [int]$existing.attempts + 1 }
        if ($existing.PSObject.Properties.Name -contains 'first_sent_at') { $firstSent = [string]$existing.first_sent_at }
    }
    $rec = [pscustomobject]@{
        key_hash      = $keyHash
        icebreaker_id = (Get-GonghaiIcebreakerId)
        first_sent_at = $firstSent
        attempts      = $attempts
        status        = $Status
        code_name     = $CodeName
        updated_at    = $now
    }
    $items = @{}
    foreach ($prop in $Index.items.PSObject.Properties) { $items[$prop.Name] = $prop.Value }
    $items[$CustomerKey] = $rec
    $Index.items = [pscustomobject]$items
    Write-GonghaiJson (Get-GonghaiPath "sent_index.json") $Index
    return $rec
}

# ---- 限速状态 gonghai_rate.json(§6.5.3 / §6.5.4) ----
function Get-GonghaiRate {
    $p = Get-GonghaiPath "gonghai_rate.json"
    $o = Read-GonghaiStateJson $p $null
    if (-not $o) { return [pscustomobject]@{ version = 1; last_sent_at = ""; day = ""; day_count = 0 } }
    return $o
}

function Set-GonghaiRate {
    param([string]$LastSentAt)
    $day = (Get-Date -Format "yyyy-MM-dd")
    $cur = Get-GonghaiRate
    $count = 1
    if ([string]$cur.day -eq $day) { $count = [int]$cur.day_count + 1 }
    Write-GonghaiJson (Get-GonghaiPath "gonghai_rate.json") ([pscustomobject]@{
        version = 1; last_sent_at = $LastSentAt; day = $day; day_count = $count
    })
}

function Get-GonghaiConfig {
    $cfg = Get-SkillConfig
    $o = [pscustomobject]@{
        enabled      = $false
        minIntervalMs = $script:GonghaiMinIntervalFloorMs
        jitterPct    = 30
        runCap       = $script:GonghaiRunCapHard
        # 缺键时的缺省:保守 20(**不**跟着老板"取消每日限制"改成 0 —— 配置读不到时宁可少发)。
        #   ⚠️ 现役 config.json = **0 = 不限**(老板 2026-09-27 晚裁决);语义见 Test-GonghaiDailyCapReached。
        dailyCap     = $script:GonghaiDailyCapDefault
        # [SPEC-公海独立Chrome 2026-09-27 §2.1] 公海自己的 CDP 端口(现役 9225)。
        #   ⚠️ 这里**不再**回退到 9222:配置缺失时 Get-GonghaiCdpPort 会抛异常(fail-closed)。
        port         = 9225
        # [SPEC-公海独立Chrome §2.1/§3.2] 公海自己的 Chrome profile(独立实例 = 独立 --user-data-dir)。
        profile      = ""
    }
    if ($cfg) {
        $names = $cfg.PSObject.Properties.Name
        if ($names -contains 'gonghai_enabled') { $o.enabled = [bool]$cfg.gonghai_enabled }
        if ($names -contains 'gonghai_min_interval_ms') { $o.minIntervalMs = [int]$cfg.gonghai_min_interval_ms }
        if ($names -contains 'gonghai_jitter_pct') { $o.jitterPct = [int]$cfg.gonghai_jitter_pct }
        if ($names -contains 'gonghai_run_cap') { $o.runCap = [int]$cfg.gonghai_run_cap }
        if ($names -contains 'gonghai_daily_cap') { $o.dailyCap = [int]$cfg.gonghai_daily_cap }
        if ($names -contains 'gonghai_cdp_port') { $o.port = [int]$cfg.gonghai_cdp_port }
        if ($names -contains 'gonghai_profile') { $o.profile = [string]$cfg.gonghai_profile }
    }
    # 硬下限保护:配置不能把单次上限抬到 10 以上(§4-9 / §11)
    # ⚠️ dailyCap **不在此夹取**:它是"有没有上限"的策略值,0/负数在 Test-GonghaiDailyCapReached 里
    #    被解释为"不限"(老板 2026-09-27 晚裁决)。夹取它会把"取消限制"静默变回"20/日"。
    # ⚠️ minIntervalMs 同理:下限常量现为 **0**(老板 2026-09-27 深夜"取消这个限制"),
    #    所以这里实际上不再抬高任何值;要恢复节奏只需把配置写回正数。
    if ($o.minIntervalMs -lt $script:GonghaiMinIntervalFloorMs) { $o.minIntervalMs = $script:GonghaiMinIntervalFloorMs }
    if ($o.runCap -gt $script:GonghaiRunCapHard) { $o.runCap = $script:GonghaiRunCapHard }
    if ($o.jitterPct -gt 30) { $o.jitterPct = 30 }
    if ($o.jitterPct -lt 0) { $o.jitterPct = 0 }
    return $o
}

function Get-GonghaiWaitMs {
    # 抖动公式原样保留:wait = minIntervalMs * (1 ± jitter%)。
    #   [DECISION 2026-09-27 深夜] minIntervalMs = 0 ⇒ **恒返回 0 = 不间隔**(老板取消了这道闸)。
    #   为什么保留公式而不是删掉:将来把 `gonghai_min_interval_ms` 写回正数即可恢复原有节奏
    #   (90000 ± 30% ⇒ 63000..117000),行为与取消前逐字一致 —— 取消要**可逆**。
    $c = Get-GonghaiConfig
    if ([int]$c.minIntervalMs -le 0) { return 0 }
    $r = Get-Random -Minimum 0 -Maximum 10000
    $frac = ($r / 10000.0) * (2 * $c.jitterPct / 100.0) - ($c.jitterPct / 100.0)
    return [int]($c.minIntervalMs * (1 + $frac))
}

function Get-GonghaiDailyCount {
    $day = (Get-Date -Format "yyyy-MM-dd")
    $r = Get-GonghaiRate
    if ([string]$r.day -eq $day) { return [int]$r.day_count }
    return 0
}

# ---- 当日配额闸(唯一判据;§6.5.3 判定链第 2 条) ----
# [DECISION 2026-09-27 晚] 老板要求"取消每日的限制" ⇒ `gonghai_daily_cap` = **0 = 不限**。
#   为什么把语义收进这一个函数:此前 `daily_cap` **只有 probe 检查**(batch 完全不检查,
#   见 runtime REPORT_回复闸门与公海缩锁_20260927.md §7-2 的登记缺口)⇒ 两处口径必然漂移。
#   现在 probe 与 batch **都**调本函数,"0 = 不限"的语义只有一份实现、一份测试。
#   ⚠️ 缺键时的缺省值仍是 20(见 Get-GonghaiConfig):配置损坏时**宁可保守**少发,
#      不因为"读不到配置"就变成无限量对外发送。要真正不限,必须显式写 0。
function Test-GonghaiDailyCapReached {
    # 返回 @{ reached=bool; daily=int; cap=int; unlimited=bool; reason=string }
    $c = Get-GonghaiConfig
    $daily = Get-GonghaiDailyCount
    $cap = [int]$c.dailyCap
    if ($cap -le 0) {
        return @{ reached = $false; daily = $daily; cap = $cap; unlimited = $true; reason = "UNLIMITED" }
    }
    $reached = ($daily -ge $cap)
    return @{
        reached   = $reached
        daily     = $daily
        cap       = $cap
        unlimited = $false
        reason    = $(if ($reached) { "DAILY_CAP" } else { "OK" })
    }
}

function Test-GonghaiRateGate {
    # 返回 @{ ok=$true/$false; waitMs=..; waitedMs=..; reason=.. }
    $c = Get-GonghaiConfig
    $rate = Get-GonghaiRate
    if (-not $rate.last_sent_at) { return @{ ok = $true; waitMs = 0; waitedMs = 0; reason = "FIRST" } }
    $last = $null
    try { $last = [datetime]::ParseExact([string]$rate.last_sent_at, "yyyy-MM-dd HH:mm:ss", $null) } catch { return @{ ok = $true; waitMs = 0; waitedMs = 0; reason = "PARSE_FAIL_ASSUME_OK" } }
    $wait = Get-GonghaiWaitMs
    $elapsed = ((Get-Date) - $last).TotalMilliseconds
    if ($elapsed -ge $wait) { return @{ ok = $true; waitMs = $wait; waitedMs = [int]$elapsed; reason = "OK" } }
    return @{ ok = $false; waitMs = $wait; waitedMs = [int]$elapsed; reason = "RATE_WAIT" }
}

function Write-GonghaiLog {
    param([string]$Msg)
    Write-SkillLog $Msg (Join-Path (Get-SkillPath "logs") "monitor.log")
}

# ---- OneTalk 页面状态恢复(§6.5.14 硬要求;**任何** OneTalk 操作后必须调用) ----
function Restore-OneTalkList {
    # 清空搜索框 → 点「全部」→ 断言 .contact-item-container 数量 > 0
    # 返回 @{ ok=bool; contacts=int; raw=string }
    $js = @'
(async function(){
  var out = { steps: [] };
  // ⚠️ 实测修正(2026-09-27):该输入框的 type 属性是**空字符串**,
  //    所以 `input[type=text][placeholder="搜索"]` **永远匹配不到**它
  //    (§6.5.14 记录的选择器不准确)。改用"按 placeholder 过滤"的宽选择器。
  var inp = Array.from(document.querySelectorAll('input')).filter(function(x){ return String(x.placeholder||'').indexOf('搜索') >= 0; })[0];
  if (inp && inp.value) {
    try {
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(inp, '');
      inp.dispatchEvent(new Event('input', { bubbles: true }));
      out.steps.push('CLEARED');
    } catch(e) { out.steps.push('CLEAR_ERR'); }
    await new Promise(function(r){ setTimeout(r, 900); });
  } else {
    out.steps.push('NO_CLEAR_NEEDED');
  }
  var tab = Array.from(document.querySelectorAll('.list-tab-item')).find(function(t){ return (t.innerText||'').trim() === '全部'; });
  if (tab) { tab.click(); out.steps.push('CLICKED_ALL'); } else { out.steps.push('NO_ALL_TAB'); }
  await new Promise(function(r){ setTimeout(r, 2500); });
  out.contacts = document.querySelectorAll('.contact-item-container').length;
  out.ok = out.contacts > 0;
  return JSON.stringify(out);
})()
'@
    $raw = ""
    try { $raw = Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch) } catch { $raw = "" }
    $contacts = 0
    $ok = $false
    if ($raw -match '(?s)\{.*\}') {
        try {
            $o = $Matches[0] | ConvertFrom-Json
            $contacts = [int]$o.contacts
            $ok = [bool]$o.ok
        } catch { }
    }
    return @{ ok = $ok; contacts = $contacts; raw = $raw }
}

# ---- OneTalk 会话查找/打开 ----
function Find-OneTalkConversation {
    # 在会话列表里按名字找;返回 @{ found=bool; exact=int; partial=int; clicked=bool; raw=.. }
    # ⚠️ 只在**会话列表**里找(不展开搜索面板),找不到由上层决定是否用搜索。
    param([string]$Name)
    $esc = $Name.Replace('\','\\').Replace("'","\'").Replace('"','\"')
    $js = @"
(function(){
  var items = Array.from(document.querySelectorAll('.contact-item-container'));
  var norm = function(s){ return String(s||'').replace(/\s+/g,' ').trim().toLowerCase(); };
  var target = norm('$esc');
  var exact = 0, partial = 0, hit = null;
  items.forEach(function(e){
    var nameEl = e.querySelector('.contact-info .name');
    var t = norm(nameEl ? nameEl.innerText : '');
    if (!t) { t = norm((e.innerText||'').split('\n')[0]); }
    if (t === target) { exact++; if (!hit) hit = e; }
    else if (t.indexOf(target) >= 0 || target.indexOf(t) >= 0) { partial++; }
  });
  return JSON.stringify({ total: items.length, exact: exact, partial: partial, hasHit: !!hit });
})()
"@
    $raw = ""
    try { $raw = Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch) } catch { $raw = "" }
    $o = $null
    if ($raw -match '(?s)\{.*\}') { try { $o = $Matches[0] | ConvertFrom-Json } catch { } }
    if (-not $o) { return @{ found = $false; exact = 0; partial = 0; total = 0; raw = $raw } }
    return @{ found = ($o.exact -eq 1); exact = [int]$o.exact; partial = [int]$o.partial; total = [int]$o.total; raw = $raw }
}

function Open-OneTalkSearchPanel {
    #   ④ 放大镜是**开关**:面板已展开时再点会收起 ⇒ 必须"先查后点 + 点后轮询",
    #     不能无条件点(否则会把自己关掉,出现"面板打不开"的假象)。
    param([string]$UrlMatch = (Get-GonghaiOnetalkUrlMatch))
    $probe = @'
(function(){
  var i = Array.from(document.querySelectorAll('input')).filter(function(x){ return String(x.placeholder||'').indexOf('搜索') >= 0; })[0];
  // ⚠️ 判定要**宽**:只要输入框存在且拿到非零尺寸就算就绪。
  //    用严格 `width>0` 会在展开动画中途误判成"未开",于是再点一次放大镜把它**收起**,
  //    形成"永远打不开"的假象(实测 2026-09-27,连续两轮 STILL_CLOSED 就是这么来的)。
  if (i) { var r0 = i.getBoundingClientRect(); if (r0.width >= 10 && r0.height >= 10) return JSON.stringify({ stage:'READY' }); }
  var ic = document.querySelector('.im-next-icon-search');
  if (!ic) return JSON.stringify({ stage:'NO_ICON' });
  var r = ic.getBoundingClientRect();
  return JSON.stringify({ stage:'NEED_OPEN', x: Math.round(r.left + r.width/2), y: Math.round(r.top + r.height/2) });
})()
'@
    $tries = 0
    for ($round = 1; $round -le 4; $round++) {
        $o = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $probe -UrlMatch $UrlMatch)
        if (-not $o) { return @{ ok = $false; stage = 'PROBE_FAILED'; tries = $tries } }
        if ($o.stage -eq 'READY') { return @{ ok = $true; stage = $(if ($round -eq 1) { 'ALREADY_OPEN' } else { 'OPENED' }); tries = $tries } }
        if ($o.stage -eq 'NO_ICON') { return @{ ok = $false; stage = 'NO_ICON'; tries = $tries } }

        $page = Get-GonghaiOnetalkPage
        if (-not $page) { return @{ ok = $false; stage = 'NO_PAGE'; tries = $tries } }
        $tries++

        # 【首选】JS 的 el.click() —— 实测(2026-09-27)对折叠态的放大镜**有效**:
        #   [初始] 搜索input=0, im-search=0x0  →  JS click  →  搜索input=1(147x30), im-search=480x285(show)
        #   早先误判"JS click 无效",是因为当时面板**已经开着**,那次点击其实是把它关掉。
        $jsClick = @'
(async function(){
  var ic = document.querySelector('.im-next-icon-search');
  if (!ic) return 'NO_ICON';
  ic.click();
  await new Promise(function(x){ setTimeout(x, 2200); });
  return 'JS_CLICKED';
})()
'@
        $clickErr = ''
        try { [void](Invoke-GonghaiEval -Script $jsClick -UrlMatch $UrlMatch) }
        catch { $clickErr = $_.Exception.Message }
        for ($w = 1; $w -le 4; $w++) {
            Start-Sleep -Milliseconds 700
            $ow = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $probe -UrlMatch $UrlMatch)
            if ($ow -and $ow.stage -eq 'READY') { return @{ ok = $true; stage = 'OPENED_JS'; tries = $tries } }
        }

        # 【回退】真实鼠标事件(JS click 无效时用)
        $ws = Connect-GonghaiPage $page.webSocketDebuggerUrl
        try {
            [void](Invoke-GonghaiCmdOn -Ws $ws -Id 1 -Method "Page.bringToFront" -ParamsJson '{}' -TimeoutMs 8000)
            $mx = [int]$o.x; $my = [int]$o.y
            $seq = @(
                '{"type":"mouseMoved","x":' + $mx + ',"y":' + $my + '}',
                '{"type":"mousePressed","x":' + $mx + ',"y":' + $my + ',"button":"left","clickCount":1}',
                '{"type":"mouseReleased","x":' + $mx + ',"y":' + $my + ',"button":"left","clickCount":1}'
            )
            $id = 2
            foreach ($p in $seq) {
                [void](Invoke-GonghaiCmdOn -Ws $ws -Id $id -Method "Input.dispatchMouseEvent" -ParamsJson $p -TimeoutMs 8000)
                $id++
                Start-Sleep -Milliseconds 180
            }
        } catch {
            # 点失败继续下一轮(多为时序问题),不立刻判死
        } finally {
            try { $ws.Dispose() } catch { }
        }
        for ($w = 1; $w -le 8; $w++) {
            Start-Sleep -Milliseconds 900
            $o2 = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $probe -UrlMatch $UrlMatch)
            if ($o2 -and $o2.stage -eq 'READY') { return @{ ok = $true; stage = 'OPENED'; tries = $tries } }
        }
    }
    return @{ ok = $false; stage = 'STILL_CLOSED'; tries = $tries }
}

function Invoke-OneTalkSearch {
    # 在搜索框里输入关键字(原生 setter + input 事件,React 受控组件必需)。
    #
    # 🔴 [GH-42 2026-09-28] **必须先清空搜索框,再输入,并回报"实际内容是否等于关键词"**。
    #   事故:实测同一页连续搜索时,框里会**残留上一次的关键词**,新词被拼在后面 ——
    #   例如先搜 "Greg Jerum"(10 字符)、再搜 "Greg" ⇒ 框里变成 15 字符的两个词拼在一起 ⇒ **必然 0 结果**。
    #   而调用方把 "0 结果" 一律当成"阿里侧索引没建成"(GH-01) ⇒ **失败率被虚增**,待办队列里
    #   可能混着"其实早就可搜到、只是被脏关键词挡住"的人。所以:
    #     ① 先 setter('') + input 事件清空,等 200ms;
    #     ② 再 setter(关键词) + input 事件,等 3s(等结果渲染);
    #     ③ 回报 `mismatch`(框内容 ≠ 关键词) 与 `typedLen`,调用方据此重试或告警。
    param([string]$Keyword, [string]$UrlMatch = (Get-GonghaiOnetalkUrlMatch))
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Keyword))
    $js = @'
(async function(){
  var inp = Array.from(document.querySelectorAll('input')).filter(function(x){ return String(x.placeholder||'').indexOf('搜索') >= 0; })[0];
  if (!inp) return JSON.stringify({ ok: false, err: 'NO_INPUT' });
  var nm = decodeURIComponent(escape(atob('__B64__')));
  var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  // ⚠️ [GH-42 回退修正 2026-09-28 05:08] **不能无条件先清空**:
  //   实测"先清空→再输入"会让应用退回**全部会话列表**,而"点第 1 条结果"于是点到了列表里的人
  //   ⇒ 连续两轮 `ABORT_WRONG_CONVO actual=29583ea4`(同一个错误会话)、每轮认领 10 个却发 0 条。
  //   正确做法:**先按原行为直接输入**(这条路径已被整夜验证),输入后**读回校验**;
  //   只有当框内容 ≠ 关键词(确实被追加污染)时,才清空重输一次。
  setter.call(inp, nm);
  inp.dispatchEvent(new Event('input', { bubbles: true }));
  await new Promise(function(r){ setTimeout(r, 3000); });
  if (String(inp.value||'') !== nm) {
    setter.call(inp, '');
    inp.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise(function(r){ setTimeout(r, 250); });
    setter.call(inp, nm);
    inp.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise(function(r){ setTimeout(r, 2500); });
  }
  var v = String(inp.value||'');
  return JSON.stringify({ ok: true, typedLen: v.length, expect: nm.length, mismatch: (v !== nm), value: v,
                          contacts: document.querySelectorAll('.contact-item-container').length });
})()
'@
    $js = $js.Replace('__B64__', $b64)
    $raw = Invoke-GonghaiEval -Script $js -UrlMatch $UrlMatch
    $o = ConvertFrom-GonghaiOutput $raw
    if (-not $o) { return @{ ok = $false; err = "SEARCH_EVAL_FAIL"; raw = $raw } }
    return $o
}

function Assert-OneTalkConversationName {
    # "发对人"校验(§6.5.5 S2):当前会话标题必须与目标一致,否则 ABORT_WRONG_CONVO
    param([string]$Expected)
    $js = @'
(function(){
  var cands = [];
  var hdr = document.querySelector('.content-header');
  if (hdr) { var t=(hdr.innerText||'').trim().split('\n')[0].trim(); if (t) cands.push(t); }
  Array.from(document.querySelectorAll('[class*=header] [class*=name], [class*=Title], h1,h2,h3,[class*=contact-name]')).forEach(function(e){
    if (e.closest && e.closest('.alicrm-customer-detail-card')) return;
    var t = (e.innerText||'').trim();
    if (t && t.length < 60) cands.push(t);
  });
  var ta = document.querySelector('textarea.send-textarea');
  return JSON.stringify({ cands: cands.slice(0, 6), hasTa: !!ta });
})()
'@
    $raw = ""
    try { $raw = Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch) } catch { $raw = "" }
    $normExp = ($Expected -replace '\s+',' ').Trim().ToLower()
    $matched = $false
    $cands = @()
    if ($raw -match '(?s)\{.*\}') {
        try {
            $o = $Matches[0] | ConvertFrom-Json
            $cands = @($o.cands)
            foreach ($c in $cands) {
                $n = ([string]$c -replace '\s+',' ').Trim().ToLower()
                if ($n -eq $normExp -or $n.Contains($normExp) -or $normExp.Contains($n)) { $matched = $true; break }
            }
        } catch { }
    }
    return @{ matched = $matched; cands = $cands; raw = $raw }
}

# ================= 认领 / 搜索 / 开会话(阶段 2 主链路,2026-09-27 实测打通) =================

function Invoke-GonghaiClaimRow {
    # 点某行的「加为我的客户」。**必须点最内层的无子节点 span**
    #   (实测外层 wrapper <span><div class=noOutlineContainer>... 点了不生效:总数不变、无弹窗)。
    # 一次只点一行,永不批量(§6.5.12)。返回 @{ ok; err; limitHit; limitTxt }
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [int]$RowIdx = -1
    )
    $esc = $Key.Replace('\','\\').Replace("'","\'")
    $js = @"
(async function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var r = rows.find(function(x){ return String(x.getAttribute('data-row-key')||'') === '$esc'; });
  if (!r) return JSON.stringify({ ok:false, err:'ROW_GONE' });
  var tds = r.querySelectorAll('td');
  // [FIX-CLAIMBTN 2026-09-27] 取**最深的**文字命中元素（真正的事件目标 = SPAN.noOutlineText）。
  //   旧注释说"必须点最内层的无子节点 span"，实测**不够**:外层 SPAN 自己也没有子节点，
  //   于是 `children.length===0` 仍会命中它 ⇒ 点了不生效(总数不变、无弹窗、按钮仍在)。
  //   操作列文字相同的元素共 5 个: TD>DIV>SPAN>DIV.noOutlineContainer>DIV>SPAN.noOutlineText。
  var hit = Array.from(tds[14].querySelectorAll('span,div,a,button,sup')).filter(function(e){
    return (e.innerText||'').trim() === '加为我的客户';
  });
  var deepest = hit.filter(function(e){
    return !Array.from(e.children).some(function(c){ return (c.innerText||'').trim() === '加为我的客户'; });
  });
  var inner = deepest.length ? deepest[deepest.length - 1] : null;
  if (!inner) return JSON.stringify({ ok:false, err:'NO_INNER_BTN', candidates: hit.length });
  inner.click();
  await new Promise(function(x){ setTimeout(x, 2500); });
  var body = document.body.innerText || '';
  var modals = Array.from(document.querySelectorAll('.ant-modal, .ant-confirm, [class*=dialog], [class*=Dialog]'))
                    .filter(function(e){ var q = e.getBoundingClientRect(); return q.width > 0 && q.height > 0; });
  var limitKeys = ['已达上限','达到上限','超过上限','次数已用完','不能超过','今日上限','剩余认领','认领上限'];
  var limitHit = false, limitTxt = '';
  limitKeys.forEach(function(k){ if (body.indexOf(k) >= 0) { limitHit = true; limitTxt += k + ';'; } });
  return JSON.stringify({ ok:true, err:'', modalCount: modals.length, limitHit: limitHit, limitTxt: limitTxt });
})()
"@
    $raw = Invoke-GonghaiEval -Script $js -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
    $o = ConvertFrom-GonghaiOutput $raw
    if (-not $o) { return @{ ok = $false; err = "CLAIM_EVAL_FAIL"; limitHit = $false; limitTxt = '' } }
    return @{ ok = [bool]$o.ok; err = [string]$o.err; limitHit = [bool]$o.limitHit; limitTxt = [string]$o.limitTxt; modalCount = [int]$o.modalCount }
}

function Test-GonghaiRowClaimed {
    # 轮询用:判断某行是否"已被认领"。
    #   认领生效的两种表现:①该行从列表消失;②该行的「加为我的客户」按钮消失。
    # 返回 @{ gone; hasClaim }
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [int]$RowIdx = -1
    )
    $esc = $Key.Replace('\','\\').Replace("'","\'")
    $js = @"
(function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var r = rows.find(function(x){ return String(x.getAttribute('data-row-key')||'') === '$esc'; });
  if (!r) return JSON.stringify({ gone:true, hasClaim:false });
  var tds = r.querySelectorAll('td');
  // [FIX-CLAIMBTN 2026-09-27] 判据与 Invoke-GonghaiClaimRow **必须同款**(见那里的注释):
  //   按钮存在 = 存在"文字命中且没有子孙也命中"的最深元素。
  var hit = tds[14] ? Array.from(tds[14].querySelectorAll('span,div,a,button,sup')).filter(function(e){
    return (e.innerText||'').trim() === '加为我的客户';
  }) : [];
  var deepest = hit.filter(function(e){
    return !Array.from(e.children).some(function(c){ return (c.innerText||'').trim() === '加为我的客户'; });
  });
  return JSON.stringify({ gone:false, hasClaim: deepest.length > 0 });
})()
"@
    $o = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $js -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer')
    if (-not $o) { return @{ gone = $false; hasClaim = $true } }
    return @{ gone = [bool]$o.gone; hasClaim = [bool]$o.hasClaim }
}

function Get-GonghaiSearchResultCount {
    # 搜索结果条目数(面板里的 .contact-list-item / .all-list-content li)
    $js = @'
(function(){
  var items = Array.from(document.querySelectorAll('.contact-list-item, .all-list-content li'));
  return JSON.stringify({ n: items.length, lens: items.slice(0,5).map(function(e){ return (e.innerText||'').replace(/\s+/g,' ').trim().length; }) });
})()
'@
    $o = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch))
    if (-not $o) { return @{ n = 0; lens = @() } }
    return @{ n = [int]$o.n; lens = @($o.lens) }
}

function Test-GonghaiSearchUsable {
    # [GH-39 2026-09-28] **认领前的搜索健康闸**（本函数存在的唯一理由：不许再制造"已认领未激活"的客户）。
    #   事故当晚：OneTalk 页面数据面断开（页面横幅"网络连接已经断开"），搜索对**任何人**都返回 0 结果
    #   —— 连几小时前发过、必然已索引的老客户也搜不到（"Brian Casco" 实测 n=0）。
    #   而批次把"搜不到"一律当成"索引未同步" ⇒ 每轮照样认领 9–10 个人、然后一个都发不出去
    #   ⇒ 当晚待办队列被冲到 60+，全是**真需要补发**的客户。这是可预防的浪费。
    #   判据（两条，任一不过即视为不可用）：
    #     ① 页面出现"网络连接已经断开"横幅；
    #     ② 单字符烟雾搜索（默认 "a"）返回 0 结果 —— 正常时必然有结果。
    #   返回 @{ ok=[bool]; reason='' }（**永不抛**，调用方按 ok 决定是否继续）。
    param([string[]]$SmokeKeywords = @('a', 'an', 'e', 'i'))
    $res = [pscustomobject]@{ ok = $false; reason = ''; banner = $false }
    $jsBanner = @'
(function(){
  var b = document.body ? (document.body.innerText||'') : '';
  return JSON.stringify({ disconnected: /网络连接已经断开|网络连接已断开/.test(b) });
})()
'@
    $st = $null
    try { $st = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $jsBanner -UrlMatch (Get-GonghaiOnetalkUrlMatch)) } catch { $st = $null }
    if (-not $st) { $res.reason = 'eval-failed'; return $res }
    $res.banner = [bool]$st.disconnected
    # ⚠️ [2026-09-28 03:25 修正] **横幅只作参考、不作判据**：
    #   实测 9222(监控) 与 9225(公海) 两个实例**都**显示"网络连接已经断开"，而监控实例**仍能正常发送回复**
    #   ⇒ 横幅只是"实时通道断了"的表象（可能长期挂着），不等于"搜索不可用"。
    #   若拿它当闸门，会出现"搜索已恢复、却因横幅仍在而一直不认领"的**假拦截**。
    #   唯一判据 = **烟雾搜索**：任一关键词能搜出结果 ⇒ 搜索可用（多试几个关键词，防"太短的关键词本就不出结果"）。
    foreach ($kw in $SmokeKeywords) {
        try {
            # ① **负对照**（[GH-49 2026-09-28] 关键）：先搜一个几乎不可能匹配的词，必须 **0 结果**。
            #   为什么需要：实测页面会进入"**搜索结果面板冻结**"的退化态——面板里只剩 1 条**陈旧项**
            #   （重建前实测 `.contact-list-item,.all-list-content li` = 1），而同步检查只要求 "n ≥ 1"，
            #   于是**每一位都被误判成"已可搜到"** ⇒ 认领 10 个、打开时全点到同一个错误会话
            #   ⇒ 单轮 9/10 全是 `WRONG_CONVO`（2026-09-28 19:33 实测）。负对照能一眼识破这种冻结。
            $null = Open-OneTalkSearchPanel
            $null = Invoke-OneTalkSearch -Keyword 'zzqx'
            Start-Sleep -Seconds 2
            $rcNeg = Get-GonghaiSearchResultCount
            if ($rcNeg -and [int]$rcNeg.n -gt 0) {
                $res.reason = ('search-stale-panel(负对照 zzqx 得到 ' + $rcNeg.n + ' 条 ⇒ 搜索未真正生效)')
                return $res
            }
            # ② 正对照：真实关键词必须能搜出结果
            $null = Open-OneTalkSearchPanel
            $null = Invoke-OneTalkSearch -Keyword $kw
            Start-Sleep -Seconds 2
            $rc = Get-GonghaiSearchResultCount
            if ($rc -and [int]$rc.n -ge 1) { $res.ok = $true; return $res }
        } catch {
            $res.reason = ('smoke-error: ' + $_.Exception.Message)
        }
    }
    if (-not $res.reason) {
        $res.reason = ('smoke-zero-all(' + ($SmokeKeywords -join '/') + ')' + $(if ($res.banner) { ' banner=disconnected' } else { '' }))
    }
    return $res
}

function Repair-GonghaiOnetalkTab {
    # [GH-41 2026-09-28] **重建 OneTalk 客户端页面**：关掉当前页 → 新开一个。
    #   事故当晚(02:50–03:35,约 45 分钟)：搜索对**所有关键词**返回 0（连会话列表里存在的名字、以及
    #   必然广匹配的单字母都是 0），而同一账号的 **CRM 页完全正常** ⇒ 不是封号、不是断网，
    #   是 **OneTalk web 客户端这一页卡死了**（实测监控实例那页 `bodyLen` 只剩 **128** 字符的空壳）。
    #   实测有效：关页重开后联系人 0 → **22**，公海侧烟雾搜索随即 `ok=True`、真实搜索 `n=7`。
    #   ⚠️ 与 GH-31 的区别：GH-31 治"渲染进程卡死（连 eval 都不回）"；
    #      本函数治"页面能 eval、但客户端数据是空的"——**两类故障，两种修法，别混用**。
    #   返回 $true 表示已重建（不代表业务已恢复，调用方仍需复检）。
    $page = $null
    try { $page = Get-GonghaiOnetalkPage } catch { $page = $null }
    if ($page) {
        try { [void](Close-GonghaiPage -Page $page) } catch { }
        Start-Sleep -Seconds 3
    }
    try { [void](New-GonghaiOnetalkTab); Start-Sleep -Seconds 20 } catch { return $false }
    Write-GonghaiLog "GONGHAI-ONETALK-REBUILD"
    return $true
}

function Open-GonghaiSearchResult {
    # 点搜索结果 -> 打开会话 -> 读详情卡 customerId(发对人校验用)
    # 返回 @{ clicked; hasTa; cardId; cardIdAbbrev; hdrLen; tried; matched }
    #
    # [FIX-MULTI-RESULT 2026-09-27 20:15] 原来**只点第 1 条**结果 ⇒ 名字撞车时必然判死:
    #   实测客户名就是占位符 "User name"(公海里的显示名),OneTalk 搜索返回 **3 条**,
    #   第 1 条不是他 ⇒ cardId 不等于公海 key ⇒ WRONG_CONVO/INCONCLUSIVE,6 轮重试全废,
    #   人已经认领走却永远发不出(gh-fbc008e4)。
    #   现在:传了 `-ExpectedKey` 就在结果里**按 customerId 挑对的人**(最多试前 3 条,每条约 3.5 秒)。
    #   为什么必须用 customerId 挑而不是"名字像就算":名字本身不可信(撞车/占位符/改名),
    #   customerId 与公海 data-row-key 的**精确相等**才是本模块唯一的"发对人"强判据(spec §6.5.5)。
    #   ⚠️ 不传 `-ExpectedKey` 时行为与旧版**逐字一致**(只看第 1 条)⇒ probe 的旧语义不被静默改变。
    param(
        [string]$ExpectedKey = "",
        [int]$MaxTry = 3
    )
    $escKey = ([string]$ExpectedKey).Replace('\','\\').Replace("'","\'").ToLower()
    if ($MaxTry -lt 1) { $MaxTry = 1 }
    $js = @'
(async function(){
  var items = Array.from(document.querySelectorAll('.contact-list-item, .all-list-content li'));
  if (!items.length) return JSON.stringify({ clicked:false, hasTa:false, cardId:'', hdrLen:0, tried:0, matched:null });
  var want = '__WANT__';
  var maxTry = __MAXTRY__;
  var max = want ? Math.min(items.length, maxTry) : 1;
  var last = { clicked:false, hasTa:false, cardId:'', hdrLen:0 };
  for (var i = 0; i < max; i++) {
    items[i].click();
    await new Promise(function(x){ setTimeout(x, 3500); });
    var ta = document.querySelector('textarea.send-textarea');
    var a = document.querySelector('.alicrm-customer-detail-card a[href*=customerId]');
    var m = a ? String(a.getAttribute('href')||'').match(/customerId=([0-9a-fA-F]{32})/) : null;
    var hdr = document.querySelector('.content-header');
    var ht = hdr ? (hdr.innerText||'').trim().split('\n')[0].trim() : '';
    last = { clicked:true, hasTa:!!ta, cardId: m ? m[1] : '', hdrLen: ht.length };
    if (!want) break;
    if (last.cardId && last.cardId.toLowerCase() === want) {
      return JSON.stringify({ clicked:true, hasTa:last.hasTa, cardId:last.cardId, hdrLen:last.hdrLen, tried:i+1, matched:true });
    }
  }
  return JSON.stringify({ clicked:last.clicked, hasTa:last.hasTa, cardId:last.cardId, hdrLen:last.hdrLen, tried:max, matched:(want ? false : null) });
})()
'@
    $js = $js.Replace('__WANT__', $escKey).Replace('__MAXTRY__', [string]$MaxTry)
    $o = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $js -UrlMatch (Get-GonghaiOnetalkUrlMatch))
    if (-not $o) { return @{ clicked = $false; hasTa = $false; cardId = ''; cardIdAbbrev = '(none)'; hdrLen = 0; tried = 0; matched = $null } }
    $cid = [string]$o.cardId
    return @{
        clicked    = [bool]$o.clicked
        hasTa      = [bool]$o.hasTa
        cardId     = $cid
        cardIdAbbrev = $(if ($cid.Length -ge 8) { $cid.Substring(0, 8) + '…' } else { '(none)' })
        hdrLen     = [int]$o.hdrLen
        tried      = [int]$o.tried
        matched    = $o.matched
    }
}

# ================= 公海列表页(public_customer):自愈 + 带重试的读取 =================
# [2026-09-27 23:30 事故 GH-27] 该页会**整个冻住**:标签页还在、URL 还在,但 `Runtime.evaluate` 超时
#   (连只读探针都读不出来)。而 phase 0 的读列表**没有重试** ⇒ 整批 exit 1,串联因此停机。
#   修法照抄模块里既有的自愈思路(Ensure-GonghaiOnetalkTab):读失败 ⇒ 刷新页 ⇒ 再读 ⇒ 仍失败才放弃。
$script:GonghaiPublicListUrl = 'https://i.alibaba.com/hub/alicrm/public_customer'
$script:GonghaiPublicListMatch = 'i\.alibaba\.com/hub/alicrm/public_customer'

function Repair-GonghaiPublicListPage {
    # 修复公海列表页。**两阶段**(2026-09-28 升级,GH-31):
    #   ① 默认:刷新(reload) —— 便宜,治"页面只是慢了/加载失败";
    #   ② `-Force`:先**关掉这个标签页**、再在公海端口上**新开一个** —— 治"渲染进程卡死"。
    #      实测卡死时 reload 完全不生效:批次12/13/14 连续 3 轮 `exit=1` 停机就是这么来的。
    #   ⚠️ 只在读失败时调用,平时绝不打扰正在用的列表页。
    param([int]$WaitSec = 12, [switch]$Force)
    $page = $null
    try { $page = Get-GonghaiPage -UrlMatch $script:GonghaiPublicListMatch } catch { $page = $null }
    if ($page -and -not $Force) {
        Write-GonghaiLog "GONGHAI-LIST-REPAIR reload public_customer"
        try { [void](Set-GonghaiPageUrl -Page $page -Url $script:GonghaiPublicListUrl) } catch { }
    } else {
        Write-GonghaiLog ("GONGHAI-LIST-REPAIR recreate public_customer (force=" + [bool]$Force + ")")
        if ($page) {
            try { [void](Close-GonghaiPage -Page $page) } catch { }   # 关掉卡死的页;关不掉也继续
            Start-Sleep -Seconds 2
        }
        try { [void](New-GonghaiPage -Url $script:GonghaiPublicListUrl) } catch { }
    }
    Start-Sleep -Seconds $WaitSec
}

function Move-GonghaiPublicListPage {
    # [GH-34c 2026-09-28] 公海列表**翻页**(下一页/上一页)。
    #   为什么需要:第 1 页顶部会残留"不可用"的行(2026-09-28 01:0x 实测:10 行里 4 行 nameLen=-1,
    #   且这些 key **不在我们账本里** ⇒ 不是我们认领过的;换新页也只有 6 行可用)。
    #   即"池子首页确实没那么多可认领的人" ⇒ 继续在本页硬读只会每轮少拿人,
    #   正确做法是**翻到下一页**取新鲜行(共 3138 页,量足够)。
    #   分页控件:.ant-pagination-next / .ant-pagination-prev(禁用时带 ant-pagination-disabled)。
    param([ValidateSet('next', 'prev')][string]$Direction = 'next', [int]$WaitSec = 4)
    $sel = if ($Direction -eq 'next') { '.ant-pagination-next' } else { '.ant-pagination-prev' }
    $js = @"
(function(){
  var el = document.querySelector('$sel');
  if (!el) { return JSON.stringify({ok:false, why:'not-found'}); }
  if (/disabled/.test(String(el.className||''))) { return JSON.stringify({ok:false, why:'disabled'}); }
  var btn = el.querySelector('button') || el;
  btn.click();
  return JSON.stringify({ok:true});
})()
"@
    $r = $null
    try { $r = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $js -UrlMatch $script:GonghaiPublicListMatch) } catch { $r = $null }
    if ($r -and $r.ok) {
        Start-Sleep -Seconds $WaitSec
        Write-GonghaiLog ("GONGHAI-LIST-PAGE " + $Direction)
        return $true
    }
    Write-GonghaiLog ("GONGHAI-LIST-PAGE $Direction failed (" + $(if ($r) { $r.why } else { 'eval-failed' }) + ")")
    return $false
}

function Read-GonghaiPublicRows {
    # 读公海列表(带自愈)。返回与 batch 旧 Read-Rows 同形的对象;彻底读不到返回 $null。
    #   为什么允许返回 $null:调用方必须**显式**处理"列表读不到",而不是让异常把整批打死。
    param([int]$MaxTries = 3, [int]$RetryWaitSec = 12)
    $js = @'
(function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var out = [];
  rows.forEach(function(r, i){
    var tds = r.querySelectorAll('td');
    var td1 = tds[1];
    var nameEl = td1 ? td1.querySelector('.name--ECjwwoJJ span') : null;
    var name = nameEl ? (nameEl.innerText||'').replace(/\s+/g,' ').trim() : '';
    out.push({ i:i, key:String(r.getAttribute('data-row-key')||''), name:name });
  });
  var e = document.querySelector('.ant-pagination-total-text');
  return JSON.stringify({ total: e?(e.innerText||'').trim():'', rows: out });
})()
'@
    for ($t = 1; $t -le $MaxTries; $t++) {
        $o = $null
        try { $o = ConvertFrom-GonghaiOutput (Invoke-GonghaiEval -Script $js -UrlMatch $script:GonghaiPublicListMatch) } catch { $o = $null }
        if ($o -and $o.rows) { return $o }
        Write-GonghaiLog ("GONGHAI-LIST-READFAIL try=" + $t + "/" + $MaxTries)
        if ($t -lt $MaxTries) {
            # 自愈升级(GH-31):第 1 次失败只刷新;第 2 次起**关页重开**(渲染进程卡死时只有这招有效)
            if ($t -eq 1) { Repair-GonghaiPublicListPage -WaitSec $RetryWaitSec }
            else { Repair-GonghaiPublicListPage -WaitSec $RetryWaitSec -Force }
        }
    }
    return $null
}

# ================= 风控/验证码探测(§4-14:见到即停机) =================
# [2026-09-27 收敛] 原来**只在 probe 里有**一份;batch 完全没有这道探针 ⇒
#   而当晚老板又取消了"最小间隔"这道闸,**风控探测就成了唯一的主动止损手段**。
#   现在实现收进 lib,probe 与 batch 共用(且 batch 在**认领**与**发送**两处都探)。
function Get-GonghaiRiskSignal {
    param([string]$UrlMatch = (Get-GonghaiOnetalkUrlMatch))
    $js = @'
(function(){
  // [GH-54 2026-09-29 00:2x] **不再全文匹配**。原实现拿 body.innerText 全文找
  //   ['验证码','滑块','安全验证','拖动','请完成验证','risk','baxia','操作过于频繁','频繁']
  //   ⇒ 实测**误报**：买家回信里正常出现英文单词 "risk"（"…there's a real risk of seizure or fines
  //   at Saudi customs…"，还是我们自己清关话术引出来的）⇒ 探针判"风控命中" ⇒ 批次 ABORT，
  //   配合 GH-53 的停机传播还会**把整条链路停掉**。误报比漏报贵得多（停链），必须收紧。
  //   新判据（两条取或）：① **验证容器节点**存在（baxia/captcha/弹窗）——最可靠；
  //                      ② **验证容器内部**文本命中中文验证短语（只看弹窗内文本，**不看客户消息区**）。
  //   被移除的高危词：`risk`（英文常用词，已在客户消息里误报）、`baxia`（改走节点判据更准）、
  //   `频繁`（太泛，如"发货频繁"）。
  //   ⚠️ [GH-62 2026-09-29 21:4x] **通用弹窗选择器必须排除"加载遮罩"**。
  //   GH-54 时我把 `.next-dialog, [role=dialog]` 也当成验证容器 ⇒ 实测**新误报**：
  //   `<div class="aocn-mask aocn-loading-mask" role="dialog" aria-modal="true" data-testid="mask">`
  //   —— 这是**页面加载遮罩**（无文本、visible），却让 `nodes=1` ⇒ 探针判 risk=True
  //   ⇒ 配合 GH-53 的停机传播，**链路刚重启就会被自己停掉**（实测 21:42 恢复时的第一道闸即命中）。
  //   现在分两类：
  //     ① **真验证容器**（baxia/captcha 专属类名）⇒ 节点存在即算命中（最可靠）；
  //     ② **通用弹窗**（`.next-dialog` / `[role=dialog]`）⇒ 必须 (a) class 不含 mask/loading
  //        且 (b) 文本里含中文验证短语，才算命中（纯加载遮罩/通知弹窗一律不算）。
  var trueSel = '#baxia-dialog-content, .baxia-dialog, [class*=baxia], [class*=captcha], [id*=captcha]';
  var nodes = document.querySelectorAll(trueSel).length;
  var scope = '';
  Array.prototype.forEach.call(document.querySelectorAll(trueSel), function(e){ scope += ' ' + ((e.innerText||'') + ' ' + (e.textContent||'')); });
  var hit = [];
  ['验证码','滑块','安全验证','拖动','请完成验证','操作过于频繁','人机验证'].forEach(function(k){
    if (scope.indexOf(k) >= 0) hit.push(k);
  });
  var genNodes = 0;
  Array.prototype.forEach.call(document.querySelectorAll('.next-dialog, [role=dialog]'), function(e){
    var cls = String(e.className || '');
    if (/loading|mask/i.test(cls)) return;                 // 排除加载遮罩（GH-62 误报源）
    var t = (e.innerText || '').trim();
    if (!t) return;                                        // 无文本的空壳弹窗不算
    genNodes++;
    ['验证码','滑块','安全验证','拖动','请完成验证','操作过于频繁','人机验证'].forEach(function(k){
      if (t.indexOf(k) >= 0 && hit.indexOf(k) < 0) hit.push(k);
    });
  });
  return JSON.stringify({ txt: hit, nodes: (nodes + ((hit.length > 0) ? genNodes : 0)) });
})()
'@
    $raw = ""
    try { $raw = Invoke-GonghaiEval -Script $js -UrlMatch $UrlMatch } catch { return @{ risk = $false; raw = "eval-failed" } }
    $risk = $false; $txt = @(); $nodes = 0
    if ($raw -match '(?s)\{.*\}') {
        try {
            $o = $Matches[0] | ConvertFrom-Json
            $txt = @($o.txt); $nodes = [int]$o.nodes
            if (@($txt).Count -gt 0 -or $nodes -gt 0) { $risk = $true }
        } catch { }
    }
    return @{ risk = $risk; txt = $txt; nodes = $nodes; raw = $raw }
}

# ================= 待办队列 pending.json(2026-09-27 收敛) =================
#   解决什么:"认领成功但没发出去"的人以前**没有任何记录** —— 认领占名额且不可逆,
#   而公海列表里已经没有他了 ⇒ 名字丢了,连重试都无从下手(当天 2 个客户就是这样卡住的)。
#   现在:凡是"认领了却没发成功"的候选一律入队(键 + 明文名 + 原因),
#   由 `gonghai_probe.ps1 -RetryPending` 出队重试。
#   ⚠️ PII 纪律:明文名**只**落在这里(运行数据根 `data\gonghai\`,与 `data\buyers\` 同级、不入库);
#      日志/报告/镜像里仍然只有代号。
function Get-GonghaiPending {
    $p = Get-GonghaiPath "pending.json"
    $o = Read-GonghaiStateJson $p $null
    if (-not $o) { return [pscustomobject]@{ version = 1; items = [pscustomobject]@{} } }
    if (-not ($o.PSObject.Properties.Name -contains 'items')) {
        $o | Add-Member -NotePropertyName items -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $o
}

function Add-GonghaiPending {
    # 幂等 upsert(同一 key 重复入队只更新时间/原因,不产生重复行)
    param(
        [string]$CustomerKey,
        [string]$Name,
        [string]$Code,
        [string]$Reason,           # INDEX_NOT_SYNCED | NOTSENT | LOCK_BUSY | ...
        [string]$Page = ''         # 认领来源页(续跑游标用;可空)
    )
    if (-not $CustomerKey) { return }
    # [GH-46 2026-09-28] **缺省自动推导 code**：调用方常只给 key+name（如中断兜底路径），
    #   若这里留空，待办条目就没有 code ⇒ 看板/报告里那一列是空的、人工核对困难。
    #   code 本来就是 key 的 sha1 前 8 位（与 batch/probe 的 Code8 同一算法），推导无损。
    if (-not $Code) { $Code = 'gh-' + (Get-GonghaiHash8 $CustomerKey) }
    $p = Get-GonghaiPath "pending.json"
    $o = Get-GonghaiPending
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $items = @{}
    $tries = 0
    $addedAt = $now
    foreach ($prop in $o.items.PSObject.Properties) {
        if ($prop.Name -eq $CustomerKey) {
            if ($prop.Value.PSObject.Properties.Name -contains 'tries') { $tries = [int]$prop.Value.tries }
            if ($prop.Value.PSObject.Properties.Name -contains 'added_at') { $addedAt = [string]$prop.Value.added_at }
            continue
        }
        $items[$prop.Name] = $prop.Value
    }
    $items[$CustomerKey] = [pscustomobject]@{
        code       = $Code
        name       = $Name
        reason     = $Reason
        page       = $Page
        tries      = ($tries + 1)
        added_at   = $addedAt
        updated_at = $now
    }
    $o.items = [pscustomobject]$items
    Write-GonghaiJson $p $o
}

function Remove-GonghaiPending {
    # 出队(发送成功 / 人工放弃时调用)
    param([string]$CustomerKey)
    if (-not $CustomerKey) { return }
    $p = Get-GonghaiPath "pending.json"
    if (-not (Test-Path $p)) { return }
    $o = Get-GonghaiPending
    $items = @{}
    $found = $false
    foreach ($prop in $o.items.PSObject.Properties) {
        if ($prop.Name -eq $CustomerKey) { $found = $true; continue }
        $items[$prop.Name] = $prop.Value
    }
    if (-not $found) { return }
    $o.items = [pscustomobject]$items
    Write-GonghaiJson $p $o
}

function Get-GonghaiPendingList {
    # 出队顺序:先入先出(added_at 升序)
    $o = Get-GonghaiPending
    $list = @()
    foreach ($prop in $o.items.PSObject.Properties) {
        $v = $prop.Value
        $list += [pscustomobject]@{
            key      = $prop.Name
            name     = [string]$v.name
            code     = [string]$v.code
            reason   = [string]$v.reason
            tries    = [int]$v.tries
            added_at = [string]$v.added_at
            # [GH-45 2026-09-28] 最近一次尝试时间(缺省回落到入队时间)。用途:补发**轮转** ——
            #   见 gonghai_loop.ps1 的"按最久没试过优先"排序(原实现只按 added_at 取前 N 个,
            #   导致每轮都重试同样那两个最老的、其余 90+ 条永远轮不到)。
            updated_at = $(if ($v.updated_at) { [string]$v.updated_at } else { [string]$v.added_at })
        }
    }
    return @($list | Sort-Object added_at)
}

# ================= 模块闸(把 spec 判定链第 1 步真正接上) =================
#   spec 的第 1 步是"`disabled` 标记存在 ⇒ 拒绝(MODULE_DISABLED)",但**从来没有任何脚本读它**
#   (运行时 REPORT §7-2 登记的缺口);`gonghai_enabled` 也只被读出来、没人据此设闸。
#   现在 batch/probe 开头统一调本函数 ⇒ "模块能不能跑"终于有实现,且**不满足即拒发**(fail-closed)。
function Test-GonghaiRunnable {
    # 返回 @{ ok; reason }  reason = OK | DISABLED_MARKER | MODULE_DISABLED
    if (Test-GonghaiDisabled) { return @{ ok = $false; reason = 'DISABLED_MARKER' } }
    $c = Get-GonghaiConfig
    if (-not $c.enabled) { return @{ ok = $false; reason = 'MODULE_DISABLED' } }
    return @{ ok = $true; reason = 'OK' }
}

# ================= 写锁有界等待(等待期间**不持有**锁) =================
function Wait-GonghaiLock {
    # 纪律:拿不到就放弃、不强上(§6.5.2)。
    #   ★ 等待期间不持有锁 —— 这正是"缩锁"的关键:等锁时间不计入与 monitor 的互斥窗口。
    #   返回 @{ ok; waitedSec }。
    param([int]$MaxWaitSec = 90, [string]$LockName = 'onetalk-write', [switch]$Quiet)
    $tries = [int][Math]::Ceiling($MaxWaitSec / 2.0)
    if ($tries -lt 1) { $tries = 1 }   # 至少试一次(与 lib\lock.ps1 的 timeoutSec=0 非阻塞语义一致)
    for ($i = 1; $i -le $tries; $i++) {
        if (Get-AppLock $LockName 0) { return @{ ok = $true; waitedSec = [int](($i - 1) * 2) } }
        if (-not $Quiet -and $i -eq 1) { Write-GonghaiLog ("GONGHAI-LOCK-BUSY 等 monitor 释放(最多 " + $MaxWaitSec + "s)") }
        Start-Sleep -Seconds 2
    }
    return @{ ok = $false; waitedSec = $MaxWaitSec }
}

# ================= 发送窗口(全模块**唯一**一处持锁发送;batch 与 probe 共用) =================
function Invoke-GonghaiSendWindow {
    # 取锁 → 开搜索结果(按 customerId 挑人) → 核对身份 → 先写后发 → 发送 → 恢复页面 → 释放锁。
    # 返回 @{ gotLock; verdict; open; send; status }
    #   verdict:
    #     LOCK_BUSY    = 等锁超时,放弃本轮(不发送、不记账)
    #     NO_TAB       = 没有可用的公海页(纵深防御:绝不允许回落到 monitor 的浏览器)
    #     OPEN_FAIL    = 会话没打开(hasTa=false)
    #     NO_CARDID    = 打开了但**读不到** customerId ⇒ 无法证明发对人 ⇒ 不发送(fail-closed)
    #     WRONG_CONVO  = cardId 与公海 data-row-key **不等** ⇒ 停机(绝不放行,spec §6.5.5)
    #     INCONCLUSIVE = 未提供 key(仅按会话名核对的历史路径)且 cardId 没渲染出来
    #     DONE         = 已尝试发送(send = Send-OneTalkMessage 原始返回串;status 见 Get-GonghaiSendStatus)
    # 为什么"核对 + 发送"必须在同一个锁窗口:核对读的是**此刻打开的会话**;先放锁再发送,
    #   中间任何写者都能把会话换掉 ⇒ 发错人。这条硬约束优先于"把窗口缩到最小"。
    # 为什么窗口收进 lib:2026-09-27 事故里 batch 与 probe **各写了一份**,结果一处 fail-open、
    #   一处 fail-closed —— 同一个判据两份实现必然漂移。现在只有这一份。
    param(
        [string]$Code,
        [string]$ExpectedName,
        [string]$ExpectedKey,
        [string]$Text,
        $Page,
        $Index,
        [switch]$DryRun,
        [int]$MaxWaitSec = 90,
        [string]$LockName = 'onetalk-write'
    )
    $w = Wait-GonghaiLock -MaxWaitSec $MaxWaitSec -LockName $LockName
    if (-not $w.ok) { return @{ gotLock = $false; verdict = 'LOCK_BUSY'; open = $null; send = ''; status = '' } }
    if (-not $Page) {
        Release-AppLock $LockName
        return @{ gotLock = $false; verdict = 'NO_TAB'; open = $null; send = ''; status = '' }
    }
    try {
        $open = Open-GonghaiSearchResult -ExpectedKey $ExpectedKey
        if (-not $open.hasTa) { return @{ gotLock = $true; verdict = 'OPEN_FAIL'; open = $open; send = ''; status = '' } }
        if ($ExpectedKey) {
            if (-not $open.cardId) { return @{ gotLock = $true; verdict = 'NO_CARDID'; open = $open; send = ''; status = '' } }
            if ($open.cardId -ne $ExpectedKey) { return @{ gotLock = $true; verdict = 'WRONG_CONVO'; open = $open; send = ''; status = '' } }
        } elseif (-not $open.cardId) {
            # 没给 key 的历史路径:只能按会话名核对(lib\send.ps1 第 2 步)⇒ 标 INCONCLUSIVE 交上层决定
            return @{ gotLock = $true; verdict = 'INCONCLUSIVE'; open = $open; send = ''; status = '' }
        }
        if ($DryRun) { return @{ gotLock = $true; verdict = 'DONE'; open = $open; send = ''; status = '' } }

        # 先写后发(§6.5.3):发送前**先**落 unverified,防崩溃漏记。
        #   ★ 位置刻意贴着发送:抢锁失败时**不能**留 unverified(它会被当成"已发"永久拒发)。
        [void](Set-GonghaiSentRecord -Index $Index -CustomerKey $ExpectedKey -Status 'unverified' -CodeName $Code)
        $sendStr = ''
        try {
            # ⚠️ 必须传 -Page(否则发送会落到 monitor 的 9222 上);`-AlreadyOpen` 见 lib\send.ps1 的说明。
            $sendStr = [string](Send-OneTalkMessage -buyer $ExpectedName -text $Text -Page $Page -AlreadyOpen)
        } catch {
            $m = [string]$_.Exception.Message
            if ($m -match 'ABORT_WRONG_PAGE') { $sendStr = $m } else { throw }
        }
        $status = Complete-GonghaiSend -Index $Index -CustomerKey $ExpectedKey -Code $Code -SendResult $sendStr
        return @{ gotLock = $true; verdict = 'DONE'; open = $open; send = $sendStr; status = $status }
    } finally {
        # ★ 收尾与发送同一个窗口:先恢复页面(§6.5.14),再释放锁 —— 恢复本身就是页面写。
        #   finally 覆盖 return / 异常所有路径 ⇒ 不会漏释放。
        try { [void](Restore-OneTalkList) } catch { }
        Release-AppLock $LockName
    }
}

