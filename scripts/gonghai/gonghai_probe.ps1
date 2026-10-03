# gonghai/gonghai_probe.ps1 - 公海试发 CLI(阶段 2)。
#
# 只做一件事:按指定数量,给公海客户发破冰消息。**严格限速、可幂等、可一键停**。
#
# 硬约束(spec §6-S7 / §6.5.4 / §6.5.14,不得放宽):
#   - 每条之间 >= 90000ms(90 秒),且带 ±30% 随机抖动(=> 63–117 秒);
#   - **单次运行最多 10 条**(硬编码常量 GonghaiRunCapHard,见 gonghai_lib.ps1;老板 2026-09-27 16:46 裁决 3 → 10)。
#     ⚠️ 禁止再调高;要调大必须**三处同时改**(lib 常量 / config 的 gonghai_run_cap / 本文件的 ValidateRange),
#     否则会被静默夹回 —— 留痕见 gonghai_lib.ps1 §6.5.4 上方注释;
#   - 写锁 Get-AppLock 'onetalk-write' **只覆盖真正的页面写窗口**(2026-09-27 修订):
#       认领窗口 = 点「加为我的客户」那一下;发送窗口 = 开搜索结果(读 customerId) → 核对 → 发送 → 恢复页面;
#     拿不到就放弃本次(不强上);用完 Release-AppLock;
#     为什么收窄:原实现把"取页(最长 15 秒)/页面健康探针/认领生效轮询(最长 20 秒)/
#       6 轮搜索重试(每轮含 10、15 秒等待)"全放在锁里 ⇒ 实测 monitor.log 出现 844 次 LOCK-BUSY、
#       单段最长 11.6 分钟**完全没有扫描**(买家消息干等)。这些是读/等待/可复原中间态,不需要互斥。
#     ⚠️ 硬约束不变:发对人校验与发送必须**同一个**锁窗口(不许校验完就放锁再发送 = 可能发错人)。
#   - 每条之间检查页面健康(Test-PageHealth);异常即停本轮;
#   - 操作 OneTalk 后**必须**恢复页面状态(清空搜索 → 点「全部」→ 断言 .contact-item-container > 0);
#   - 幂等:命中的客户不重发;发送前**先写** sent_index(status=unverified),成功后改 sent;
#   - 日志只记**代号**(客户 ID 的 sha1 前 8 位),**不得**记客户全名(PII,§4-12);
#   - 遇验证码/风控(baxia 类)立即停机、清锁、上报,不得重试、不得绕过(§4-14)。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_probe.ps1 -Count 1 -DryRun
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_probe.ps1 -Count 3 -Loop
#   powershell -ExecutionPolicy Bypass -NoProfile -File scripts\gonghai\gonghai_probe.ps1 -Claim -Count 1
# 编码:UTF-8 带 BOM(§4-6)。
param(
    # 本次运行最多发送条数;上限由 GonghaiRunCapHard(=10,老板 2026-09-27 裁决)夹住。
    #   三处必须同改,否则会被静默夹回:本 ValidateRange / gonghai_lib 的 GonghaiRunCapHard / config 的 gonghai_run_cap。
    [ValidateRange(1, 10)][int]$Count = 1,
    # 连续模式:在同一进程内按限速等待后继续发下一条(阶段 2 试发用)。
    # 不开启则"发一条就退出",由下次运行接着发(§6.5.4 推荐的滴灌方式)。
    [switch]$Loop,
    # 只读演练:走完全部判定与定位,但**不点击发送**。
    [switch]$DryRun,
    # 认领模式:在公海页点「加为我的客户」(§6.5.16 要求先 1 个、再 2 个)。
    [switch]$Claim,          # 旧名,等同 -DoClaim
    # 认领模式:在公海页点「加为我的客户」(§6.5.16 要求先 1 个、再 2 个)。
    [switch]$DoClaim,
    # 发送前**跳过**认领步骤(用于"已认领客户"的复跑/重试)。
    [switch]$NoClaim,
    # 指定客户 ID(32 位 hex);留空则按公海列表顺序自动取。
    [string]$CustomerId = "",
    # [FIX-SENDBYNAME 2026-09-27] 直接指定**已认领客户**的名字(OneTalk 会话名)。
    #   用途:认领成功后该客户会从公海列表消失 ⇒ -CustomerId 失效(ABORT TARGET_NOT_ON_PAGE)。
    #   传了 -Name 就走"搜索 → 核对 customerId → 发送",不读公海列表选人。
    #   ⚠️ 与 -CustomerId 互斥:同时传时以 -Name 为准(-CustomerId 被忽略)。
    [string]$Name = "",
    # [FIX-SENDBYNAME] 配合 -Name 使用的**公海 key**(32 位 hex),用于"发对人"核对。
    #   为什么需要:身份核对拿 expected 与 cardId 比对(`$open.cardId -ne $c.key`),
    #   且失败分支要打印 `$c.key.Substring(0,8)`;若 key 为空串 ⇒
    #   ① 核对必然不等(误判 ABORT_WRONG_CONVO);② Substring(0,8) 抛
    #   ArgumentOutOfRangeException 把整轮打死(实测 2026-09-27 16:19)。
    #   取值来源:认领时的 `GONGHAI-CLAIM <code>` + 公海列表的 data-row-key 反查。
    #   留空 ⇒ 退化为"只按名字核对"(由 lib\send.ps1 的会话名校验兜底),跳过 key 比对。
    [string]$Key = "",
    # 起始行号(自决的续跑游标;按"页内行序 + 页"切片,见 §6.5.10)。
    [int]$StartRow = 0,
    # [2026-09-27 收敛] 出队重试:处理 `data\gonghai\pending.json` 里"认领了却没发成功"的人。
    #   为什么需要:认领不可逆且占名额,而他们已从公海列表消失 ⇒ 只有这个队列还留着名字。
    #   与 -Name 互斥(同时传时以 -RetryPending 为准)。
    [switch]$RetryPending
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$here = $PSScriptRoot
. (Join-Path (Split-Path $here -Parent) "config.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\log.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\lock.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\cdp.ps1")
# §6.5.2:发送必须复用 lib\send.ps1::Send-OneTalkMessage。
# ⚠️ send.ps1 内部用 Get-StateKey(会话名归一化),该方法在 reply_engine.ps1 里 ⇒ 两者都要 dot-source,
#    否则会在发送那一刻抛 CommandNotFound(实测 2026-09-27:整轮跑到"该发"才失败)。
. (Join-Path (Split-Path $here -Parent) "reply_engine.ps1")
. (Join-Path (Split-Path $here -Parent) "lib\send.ps1")
. (Join-Path $here "gonghai_cdp.ps1")
. (Join-Path $here "gonghai_lib.ps1")

$script:LockName = 'onetalk-write'
$script:Abort = $null          # 非空 => 停机原因(遇风控/前置断言失败)

function ConvertFrom-GonghaiOutput {
    # 从 eval 输出里安全取出最外层 JSON 对象。
    # 为什么不直接用 `-match '(?s)\{.*\}'`:那是**贪婪**匹配,遇到"输出里有两个对象"或
    # 客户名里带花括号时会截错;而且 400 字符的宽字符串容易触发正则回溯问题。
    # 这里用花括号深度扫描,取第一个完整对象。
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

function Say([string]$m) { Write-Output $m }
function CodeName([string]$key) { return ("gh-" + (Get-GonghaiHash8 $key)) }

# [2026-09-27 收敛] 风控探测已移入 gonghai_lib.ps1(唯一实现;batch 也用它)
function Get-GonghaiRows {
    param([int]$Max = 6)
    $jsRows = @"
(function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var out = [];
  rows.slice(0, $Max).forEach(function(r, i){
    var tds = r.querySelectorAll('td');
    var td1 = tds[1];
    // ⚠️ 取**粗体客户名**(.name--ECjwwoJJ 里的无 class SPAN,font-weight:600)。
    //    曾误取 .companyName--oljcmVQI(浅色次要行),那里面是公司名/邮箱/别名,
    //    不是客户名 ⇒ 拿它去 OneTalk 搜必然对不上(2026-09-27 实测纠正,老板截图确认)。
    // ⚠️ 取**粗体客户名**(.name--ECjwwoJJ 里的无 class SPAN,font-weight:600)。
    //    曾误取 .companyName--oljcmVQI(浅色次要行),那里面是公司名/邮箱/别名,
    //    不是客户名 ⇒ 拿它去 OneTalk 搜必然对不上(2026-09-27 实测纠正,老板截图确认)。
    var nameEl = td1 ? td1.querySelector('.name--ECjwwoJJ span') : null;
    var secEl = td1 ? td1.querySelector('.companyName--oljcmVQI') : null;
    var secName = secEl ? (secEl.innerText||'').replace(/[ \t\r\n]+/g,' ').trim() : '';
    var name = nameEl ? (nameEl.innerText||'').replace(/[ \t\r\n]+/g,' ').trim() : '';
    var claimBtn = null;
    if (tds[14]) {
      // [FIX-CLAIMBTN 2026-09-27] 必须取**最深的**含「加为我的客户」文字的元素。
      //   该操作列实测 DOM 树（文字相同的元素共 5 个）:
      //     TD > DIV > SPAN > DIV.noOutlineContainer > DIV > **SPAN.noOutlineText** ← 真正的按钮
      //   踩过的两个坑（症状相同:hasClaim 判对、点了不生效、总数不变、无弹窗、按钮仍在）:
      //     ① `querySelectorAll('sup,span,div,button,a')` 取第一个 ⇒ 命中外层 SPAN;
      //     ② 改成 `span` + `children.length===0` ⇒ 命中的**仍是外层那个无子节点 SPAN**
      //        （它自己没有孩子，文字靠 CSS 渲染，但不是事件目标）。
      //   故判据改为"文字命中的元素里，没有任何子孙也命中" ⇒ 必然落到最内层的事件目标。
      //   受控实验(2026-09-27 15:5x)实测:点它之后该行 gone=True（认领生效）。
      var hit = Array.from(tds[14].querySelectorAll('span,div,a,button,sup')).filter(function(e){
        return (e.innerText||'').trim() === '加为我的客户';
      });
      var deepest = hit.filter(function(e){
        return !Array.from(e.children).some(function(c){ return (c.innerText||'').trim() === '加为我的客户'; });
      });
      claimBtn = deepest.length ? deepest[deepest.length - 1] : null;
    }
    out.push({
      row: i,
      key: String(r.getAttribute('data-row-key')||''),
      nameB64: (function(){ try { return btoa(unescape(encodeURIComponent(name))); } catch(e){ return ''; } })(),
      nameLen: name.length,
      country: (function(){ var t = tds[8] ? (tds[8].innerText||'').replace(/[ \t\r\n]+/g,' ').trim() : ''; return t.split('/')[0].trim(); })(),
      hasClaim: !!claimBtn,
      secName: secName
    });
  });
  var e = document.querySelector('.ant-pagination-total-text');
  return JSON.stringify({ total: (e ? (e.innerText||'').trim() : ''), rowCount: rows.length, rows: out });
})()
"@
    $raw = Invoke-GonghaiEval -Script $jsRows -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
    $o = ConvertFrom-GonghaiOutput $raw
    if (-not $o) { throw "PUBLIC_LIST_READ_FAIL: $raw" }
    foreach ($r in @($o.rows)) {
        $nm = ""
        if ($r.nameB64) { try { $nm = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$r.nameB64)) } catch { } }
        $r | Add-Member -NotePropertyName name -NotePropertyValue $nm -Force
    }
    return $o
}

# ---- 认领(§6.5.16:一次一个,永不批量) ----
function Invoke-GonghaiClaim {
    param([string]$Key)
    $esc = $Key.Replace('\','\\').Replace("'","\'").Replace('"','\"')
    $jsRows = @"
(async function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var row = rows.find(function(r){ return String(r.getAttribute('data-row-key')||'') === '$esc'; });
  if (!row) return JSON.stringify({ ok: false, err: 'ROW_NOT_FOUND' });
  var tds = row.querySelectorAll('td');
  if (!tds[14]) return JSON.stringify({ ok: false, err: 'NO_OP_CELL' });
  // [FIX-CLAIMBTN 2026-09-27] 取**最深的**文字命中元素（真正的事件目标是 SPAN.noOutlineText）。
  //   旧写法 `querySelectorAll('sup,span,div,button,a').find(...)` 取的是**第一个**命中者
  //   = 外层 wrapper，点它不生效（实测:总数不变、无弹窗、按钮仍在）。
  //   与同文件 Get-GonghaiRows 的判据保持一致（两处必须同款，否则"列表说有按钮、点击点不动"）。
  var hit = Array.from(tds[14].querySelectorAll('span,div,a,button,sup')).filter(function(e){
    return (e.innerText||'').trim() === '加为我的客户';
  });
  var deepest = hit.filter(function(e){
    return !Array.from(e.children).some(function(c){ return (c.innerText||'').trim() === '加为我的客户'; });
  });
  var btn = deepest.length ? deepest[deepest.length - 1] : null;
  if (!btn) return JSON.stringify({ ok: false, err: 'NO_CLAIM_BTN', candidates: hit.length });
  btn.click();
  await new Promise(function(r){ setTimeout(r, 2500); });
  // 观察:确认弹窗?上限提示?
  var bodyTxt = (document.body.innerText || '');
  var modals = Array.from(document.querySelectorAll('.ant-modal, .ant-confirm, [class*=dialog], [class*=Dialog]'))
                    .filter(function(e){ var r=e.getBoundingClientRect(); return r.width>0 && r.height>0; });
  var modalTxts = modals.slice(0,3).map(function(e){ return (e.innerText||'').replace(/\s+/g,' ').trim().substring(0,160); });
  var limitHit = false;
  ['已达上限','达到上限','超过上限','上限','每日','次数已用完','不能超过'].forEach(function(k){ if (bodyTxt.indexOf(k) >= 0) limitHit = true; });
  var total = (function(){ var e=document.querySelector('.ant-pagination-total-text'); return e?(e.innerText||'').trim():''; })();
  return JSON.stringify({ ok: true, modalCount: modals.length, modalTxts: modalTxts, limitHit: limitHit, total: total });
})()
"@
    $raw = Invoke-GonghaiEval -Script $jsRows -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
    $co = ConvertFrom-GonghaiOutput $raw
    if ($co) { return $co }
    return [pscustomobject]@{ ok = $false; err = "CLAIM_EVAL_FAIL: $raw" }
}

function Wait-GonghaiClaimEffect {
    # [FIX-CLAIMVERIFY 2026-09-27] 认领**生效校验** —— 本函数存在的唯一理由:
    #   `btn.click()` 之后的 `ok:true` 只证明"点了",**不证明"认领成功"**。
    #   实测(2026-09-27):旧实现连点两次、两次都返回 ok=True,而 DOM 里该行的
    #   「加为我的客户」按钮**原封不动**,公海总数也不变 ⇒ 典型的"假成功":
    #   脚本以为认领了、后面拿去 OneTalk 搜必然搜不到,却被写成"索引未同步",
    #   把根因指向了错误的方向(浪费一整轮排查)。
    #   判据(任一成立即算生效,复用 lib 的 Test-GonghaiRowClaimed):
    #     ① 该行从列表消失(gone=true);或
    #     ② 该行的「加为我的客户」按钮消失(hasClaim=false)。
    #   返回 @{ ok; gone; hasClaim; tries; waitedMs }
    param(
        [Parameter(Mandatory=$true)][string]$Key,
        [int]$TimeoutSec = 20,
        [int]$PollMs = 2000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tries = 0
    $last = @{ gone = $false; hasClaim = $true }
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $tries++
        $last = Test-GonghaiRowClaimed -Key $Key
        if ($last.gone -or -not $last.hasClaim) {
            return @{ ok = $true; gone = [bool]$last.gone; hasClaim = [bool]$last.hasClaim; tries = $tries; waitedMs = [int]$sw.Elapsed.TotalMilliseconds }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return @{ ok = $false; gone = [bool]$last.gone; hasClaim = [bool]$last.hasClaim; tries = $tries; waitedMs = [int]$sw.Elapsed.TotalMilliseconds }
}

# ---- 发送(复用 lib\send.ps1::Send-OneTalkMessage) ----
# [2026-09-27 收敛] 原来这里有三份本地实现(`Invoke-GonghaiSend` / `Wait-ProbeLock` /
#   `Invoke-GonghaiSendWindow`)。它们与 `gonghai_batch.ps1` 里的内联副本**各写一份同一个判据**,
#   结果 2026-09-27 20:03 事故里一处 fail-open、一处 fail-closed。现已**整体移入**
#   `gonghai_lib.ps1`(`Wait-GonghaiLock` / `Invoke-GonghaiSendWindow` / `Complete-GonghaiSend`),
#   batch 与 probe 共用同一份 —— 本文件不再持有任何持锁发送逻辑。

# ================= [2026-09-27] 页面互斥窗口(锁的唯一用法) =================
# 窗口边界 = "与 monitor 互斥的范围"。事故背景(实测 monitor.log):LOCK-BUSY 844 次/天、
#   单段最长 11.9 分钟**完全没有任何扫描**。根因 = 原实现从"取锁"到"释放"之间塞进了:
#   取页面句柄(最长 15 秒轮询)、页面健康探针、风控探针、认领点击 + 认领生效轮询(最长 20 秒)、
#   **6 轮搜索重试(每轮含 10/15 秒等待)**、先写后发记账。其中只有"点击/填字/发送"这类
#   **页面写**需要互斥,其余都是读/等待/可复原中间态 ⇒ 一律移到锁外。
#   现在锁只出现在两个窗口里:① 认领点击;② 发送(`gonghai_lib::Invoke-GonghaiSendWindow`)。


# ================= 主流程 =================
Say ("=== GONGHAI-PROBE " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " ===")
$cfg = Get-GonghaiConfig
# [DECISION 2026-09-27 晚] dailyCap 现役 = 0 = 不限 ⇒ 回显必须能一眼看出"没上限",
#   不能再打印 `dailyCap=0`(会被读成"零配额")。
$capText = $(if ([int]$cfg.dailyCap -le 0) { "unlimited" } else { [string]$cfg.dailyCap })
Say ("config: enabled=$($cfg.enabled) minIntervalMs=$($cfg.minIntervalMs) jitterPct=$($cfg.jitterPct) runCap=$($cfg.runCap) dailyCap=$capText port=$($cfg.port)")

# [SPEC-公海独立Chrome 2026-09-27 §3.2/§5-E1] 先自述"我在哪个 Chrome 上" —— 这是本 spec 的**核心证据**。
#   为什么放在最前面:若公海仍在 9222 上,后面所有"发送落点"的结论都不可信(E5),
#   所以第一行就必须能看出端口与页身份。
#   ⚠️ Get-GonghaiCdpPort 内置 9222 否决闸(配成 9222 会直接抛异常),这里再兜一层可读输出。
$ghPort = 0
try { $ghPort = Get-GonghaiCdpPort } catch { Say ("ABORT " + $_.Exception.Message); exit 8 }
$ghCdpUp = Test-CdpReady -Port $ghPort
Say ("gonghai chrome: port=$ghPort cdpReady=$ghCdpUp profile=$($cfg.profile)")
if (-not $ghCdpUp) {
    Say ("ABORT GONGHAI_CDP_DOWN (端口 $ghPort 不可达;先跑 scripts\gonghai\gonghai_ensure.ps1 起公海自己的 Chrome)")
    Say ("提示: 不要再让公海使用 9222 —— 那会和自动回复抢页面(spec §1.3)")
    exit 7
}

$ibText = Get-GonghaiIcebreaker
$ibId = Get-GonghaiIcebreakerId
Say ("icebreaker: id=$ibId words=" + (@($ibText -split '\s+') | Where-Object { $_ }).Count + " chars=$($ibText.Length)")
$runCap = [Math]::Min($Count, $script:GonghaiRunCapHard)

# ---- 判定顺序(§6.5.3,不可调换) ----
# 1) 模块闸([2026-09-27 收敛] 把 spec 第 1 步真正接上:`disabled` 标记 + `gonghai_enabled`)
$run = Test-GonghaiRunnable
if (-not $run.ok) { Say ("ABORT " + $run.reason); exit 3 }
# 2) 当日配额(唯一判据在 gonghai_lib::Test-GonghaiDailyCapReached;
#    [DECISION 2026-09-27 晚] `gonghai_daily_cap` = 0 = **不限** ⇒ 这一闸对现役配置恒放行)
$dc = Test-GonghaiDailyCapReached
if ($dc.reached) { Say "ABORT DAILY_CAP ($($dc.daily)/$($dc.cap))"; exit 4 }

# ---- 认领模式(§6.5.16) ----
if ($Claim) {
    $rows = Get-GonghaiRows -Max 6
    Say ("public list: total=$($rows.total) rows=$($rows.rowCount)")
    $target = $null
    if ($CustomerId) {
        $target = @($rows.rows) | Where-Object { $_.key -eq $CustomerId } | Select-Object -First 1
        if (-not $target) { Say "ABORT TARGET_NOT_ON_PAGE (指定 ID 不在当前页)"; exit 5 }
    } else {
        $claimables = @($rows.rows | Where-Object { $_.hasClaim -and $_.key -and $_.nameLen -gt 0 })
        if (@($claimables).Count -eq 0) { Say "ABORT NO_CLAIMABLE_ROW"; exit 5 }
        $target = $claimables[$StartRow % @($claimables).Count]
    }
    $code = CodeName $target.key
    if ($DryRun) {
        Say ("DRYRUN would claim: code=$code row=$($target.row) nameLen=$($target.nameLen) country=$($target.country) hasClaim=$($target.hasClaim)")
        exit 0
    }
    # 风控探测(只读)⇒ 放锁外:它不写页面,没有理由占用互斥窗口。
    $risk = Get-GonghaiRiskSignal -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
    if ($risk.risk) { Say ("ABORT RISK_SIGNAL " + ($risk.raw -replace '\s+',' ')); exit 9 }
    $beforeTotal = $rows.total
    # ★ 页面写窗口(认领模式):**只包住"点一下『加为我的客户』"**这一下。
    #   生效校验(Wait-GonghaiClaimEffect,最长 20 秒)是纯只读轮询 ⇒ 移到锁外;
    #   原实现把它算在锁里,单次认领就把 monitor 挡住 20 秒以上
    #   (与 gonghai_batch 阶段1 的认领窗口是同款修法,两处必须一致)。
    if (-not (Get-AppLock $script:LockName 0)) { Say "ABORT LOCK_BUSY"; exit 6 }
    $res = $null
    try {
        $res = Invoke-GonghaiClaim -Key $target.key
    } finally {
        # 点击成功/失败/抛异常都由 finally 覆盖 ⇒ 下面那些 exit 之前锁一定已释放。
        Release-AppLock $script:LockName
    }
    Say ("claim click: ok=$($res.ok) err=$($res.err) modals=$($res.modalCount) limitHit=$($res.limitHit)")
    if ($res.modalTxts) { foreach ($m in @($res.modalTxts)) { Say ("  modal: " + $m) } }
    Say ("total: before=$beforeTotal after=$($res.total)")
    if ($res.limitHit) { Say "ABORT CLAIM_LIMIT_HIT(上限提示,立即停机报告)"; exit 10 }
    if (-not $res.ok) { Say "ABORT CLAIM_FAILED"; exit 11 }
    # [FIX-CLAIMVERIFY] 点击 ≠ 生效:必须轮询确认按钮消失/整行消失,否则一律按失败处置。
    #   绝不再出现"ok=True 但人根本没认领"的假成功(见 Wait-GonghaiClaimEffect 注释)。
    #   ★ 锁外轮询:判据只读 DOM(不写页面)⇒ 不需要与 monitor 互斥。
    $vf = Wait-GonghaiClaimEffect -Key $target.key
    Say ("claim verified = $($vf.ok)  (gone=$($vf.gone) btnStillThere=$($vf.hasClaim) polls=$($vf.tries) waited=$($vf.waitedMs)ms)")
    if (-not $vf.ok) {
        Say "ABORT CLAIM_NOT_EFFECTIVE(点击已发出但列表未变化:按钮仍在且行未消失 ⇒ 视为未认领)"
        exit 12
    }
    Say ("GONGHAI-CLAIM $code " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    exit 0
}

# ---- 发送模式 ----
# [FIX-SENDBYNAME 2026-09-27] 支持直接指定**已认领客户**的名字发送。
#   为什么必须加这个入口:发送阶段的候选**只从公海列表读**(Get-GonghaiRows),
#   而认领成功的客户会**从公海列表消失**(这正是认领生效的证据)⇒
#   于是出现死结:未认领的人搜不到(OneTalk 没这个联系人)、已认领的人脚本挑不到。
#   实测:认领 Martin Jordanovski 后再用 -CustomerId 指定他 ⇒ ABORT TARGET_NOT_ON_PAGE。
#   加了 -Name 之后:已认领的客户可直接按名字走"搜索 → 核对 customerId → 发送";
#   公海里未认领的人仍走原路(先 -Claim,再 -Name)。
$rows = $null
$cands = @()
if ($RetryPending) {
    # [2026-09-27 收敛] 出队重试:处理"认领了却没发成功"的人(他们已从公海列表消失,
    #   名字只留在 `data\gonghai\pending.json`)。
    $pl = @(Get-GonghaiPendingList)
    Say ("pending queue: " + $pl.Count + " 个待重试")
    if ($pl.Count -eq 0) { Say "PENDING_EMPTY 队列为空,无事可做"; exit 0 }
    $cands = @($pl | ForEach-Object { [pscustomobject]@{ key = $_.key; name = $_.name; nameLen = $_.name.Length; row = -1; country = ''; pendingReason = $_.reason } })
    if ($CustomerId) { $cands = @($cands | Where-Object { $_.key -eq $CustomerId }) }
    if (@($cands).Count -eq 0) { Say "ABORT PENDING_TARGET_NOT_FOUND"; exit 5 }
} elseif ($Name) {
    Say ("target by name: [$Name] (已认领客户直发路径; 不读公海列表选人)")
    $cands = @([pscustomobject]@{ key = $Key; name = $Name; nameLen = $Name.Length; row = -1; country = '' })
    if (-not $Key) { Say "  WARN: 未提供 -Key ⇒ 跳过 customerId 比对,仅按会话名校验(lib\send.ps1 兜底)" }
} else {
    $rows = Get-GonghaiRows -Max 8
    Say ("public list: total=$($rows.total) rows=$($rows.rowCount)")
    $cands = @($rows.rows | Where-Object { $_.key -and $_.key.Length -eq 32 -and $_.nameLen -gt 0 })
    if ($CustomerId) {
        $cands = @($cands | Where-Object { $_.key -eq $CustomerId })
        if (@($cands).Count -eq 0) { Say "ABORT TARGET_NOT_ON_PAGE"; exit 5 }
    }
}
if (@($cands).Count -eq 0) { Say "ABORT NO_CANDIDATE"; exit 5 }
if ($StartRow -gt 0 -and -not $Name -and -not $RetryPending) { $cands = @($cands | Select-Object -Skip $StartRow) }

$index = Get-GonghaiSentIndex
$sentThisRun = 0
$consecFail = 0

foreach ($c in $cands) {
    if ($sentThisRun -ge $runCap) { Say "RUN_CAP_REACHED ($sentThisRun)"; break }
    if ($script:Abort) { break }

    $code = CodeName $c.key

    # 3) 幂等:key_hash 命中 => 拒发(⚠️ `notsent` 状态**允许重试**,见 lib 的账本状态语义)
    if (Test-GonghaiAlreadySent -Index $index -CustomerKey $c.key) {
        Say "SKIP ALREADY_SENT code=$code"
        if ($RetryPending) { Remove-GonghaiPending -CustomerKey $c.key }   # 已发过 ⇒ 出队,别留在队列里
        continue
    }

    # 4) 限速门(§6.5.4):未到间隔 => 不再硬等,直接结束本轮(推荐"下次运行再发")
    $gate = Test-GonghaiRateGate
    if (-not $gate.ok) {
        $needMs = $gate.waitMs - $gate.waitedMs
        if ($Loop -and $needMs -gt 0) {
            Say ("RATE_WAIT sleeping " + [int]($needMs/1000) + "s (wait=" + [int]($gate.waitMs/1000) + "s elapsed=" + [int]($gate.waitedMs/1000) + "s)")
            Start-Sleep -Milliseconds $needMs
        } else {
            # 单次运行内也走等待:否则本轮第 2/3 条会被限速门直接终止,永远发不满。
            # (spec §6.5.4 提醒"不要长 sleep 阻塞"针对的是"等几十分钟"的场景;
            #  这里是 63–117 秒的档位间隔,属正常节流。)
            Say ("RATE_WAIT sleep " + [int]($needMs/1000) + "s (wait=" + [int]($gate.waitMs/1000) + "s elapsed=" + [int]($gate.waitedMs/1000) + "s)")
            Start-Sleep -Milliseconds $needMs
        }
    } elseif ($gate.waitMs -gt 0) {
        Say ("RATE_OK wait=" + [int]($gate.waitMs/1000) + "s elapsed=" + [int]($gate.waitedMs/1000) + "s")
    }

    # 5) [2026-09-27 修订] 页面句柄 / 页面健康 / 风控 探针 = **全部锁外**。
    #    为什么:取页(页被关掉时要新开并轮询最长 15 秒)、健康探针、风控探针都**不写页面内容**,
    #    没有任何理由占用"与 monitor 互斥"的窗口。原实现把它们连同"6 轮搜索重试(每轮含
    #    10/15 秒等待)"和"认领生效轮询(最长 20 秒)"一起放在锁里 ⇒ 实测(2026-09-27)
    #    monitor.log 出现 844 次 LOCK-BUSY、单段最长 **11.6 分钟完全没有扫描**(买家消息干等)。
    #    现在锁只出现在两个窗口里:① 认领点击(见 6b);② 发送(见 6d,函数 Invoke-GonghaiSendWindow)。
    $script:SendWindowRestored = $false   # 发送窗口已负责恢复页面时,外层收尾不再重复恢复
    $ghTab = $null
    try {
        # 6a) [SPEC-公海独立Chrome 2026-09-27 §3.2/§3.3] 取(必要时新开)**公海自己 Chrome 上的** OneTalk 页。
        #     必须在任何 OneTalk 操作之前:下面 Open-OneTalkSearchPanel / Invoke-OneTalkSearch /
        #     Open-GonghaiSearchResult 全部经 Invoke-GonghaiEval(公海端口),
        #     没有这个页它们会全线 NO_PAGE。
        #     页被关掉 / Chrome 重启 ⇒ 这里自愈重开;**绝不**回退到 9222 上 monitor 的页。
        #     ⚠️ 顺序说明:本块原来在健康探针**之后**,导致 `Test-GonghaiPageHealth -Page $ghTab`
        #        在首次循环时拿到的是 $null(未赋值),实际走了"按 URL 取第一个 OneTalk 页"的兜底分支。
        #        现在"先取页、再探针",两者指向同一个页,语义不再依赖变量上轮的残留值。
        $ghTab = Ensure-GonghaiOnetalkTab
        if (-not $ghTab) {
            Say ("ABORT NO_GONGHAI_TAB (公海端口 " + (Get-GonghaiCdpPort) + " 上无法获得 OneTalk 页,拒绝回退到 monitor 的浏览器)")
            $script:Abort = "NO_GONGHAI_TAB"
            break
        }
        Say ("gonghai tab: id=" + (([string]$ghTab.id -split '\s+')[0]) + " port=" + (Get-GonghaiCdpPort))
        # 6) 页面健康([SPEC-公海独立Chrome §3.3] **改探公海自己的实例**,并**显式指定 OneTalk 页**)
        #    为什么必须换:Test-PageHealth 固定走 config 的 cdp_port(9222)= 自动回复的浏览器;
        #    公海搬到 9225 之后,继续探 9222 就是"拿别人的页当自己的健康判据"(判据与对象错配)。
        #    为什么必须传 -Page:页清单**顺序会变** —— 实测(2026-09-27 15:07)公海实例上
        #      public_customer 排到了第一位,不指定页就会探到 CRM 页并误判 PageDown=True(wrong-tab)。
        #    判定逻辑仍复用同一份纯函数 Get-PageHealthVerdict,只是取页/求值在公海端口 + 指定页上做。
        $health = Test-GonghaiPageHealth -Page $ghTab
        Say ("health: PageDown=$($health.PageDown) Reason=$($health.Reason) Items=$($health.Items) Tab=$($health.Tab)")
        if ($health.PageDown) { Say "END PAGE_UNHEALTHY ($($health.Reason))"; break }

        # 风控探测(OneTalk + 公海页)
        $riskOt = Get-GonghaiRiskSignal -UrlMatch (Get-GonghaiOnetalkUrlMatch)
        if ($riskOt.risk) { $script:Abort = "RISK_SIGNAL_ONETALK"; Say ("ABORT RISK_SIGNAL " + ($riskOt.raw -replace '\s+',' ')); break }
        $riskGh = Get-GonghaiRiskSignal -UrlMatch 'i\.alibaba\.com/hub/alicrm/public_customer'
        if ($riskGh.risk) { $script:Abort = "RISK_SIGNAL_PUBLIC"; Say ("ABORT RISK_SIGNAL_PUBLIC " + ($riskGh.raw -replace '\s+',' ')); break }

        # 6a) 取页已在上面(锁外)完成 ⇒ 此处**不再重复取页**:
        #     取页会(在页缺失时)新开页并轮询最长 15 秒,不该出现在任何持锁路径上。

        # 6b) 若尚未认领 ⇒ **先加为客户**(老板定稿流程:认领 → 发消息)。
        #     §6.5.16:一次一个,认领后**必须轮询确认生效**再搜索 ——
        #     实测教训:不确认就搜,会在"没认领成"的脏状态下搜到 0 结果,误判成路径不通。
        # ⚠️ -DryRun 是"只读演练",**不得认领**(认领会真实占用名额且不可逆)。
        #    实测教训:一次 DRYRUN 认领了一个客户却没进账本 ⇒ 既占名额又无记录。
        if (($Claim -or $DoClaim) -and -not $DryRun) {
            if (-not $c.hasClaim) {
                Say "SKIP 该行没有认领按钮(可能已认领) code=$code"
            } else {
                Say ("claim: 点击「加为我的客户」 code=$code row=$($c.row)")
                # ★ 页面写窗口①(认领):**只有"点一下按钮"这一下**需要与 monitor 互斥。
                #   下面的生效校验是纯只读轮询(最长 10×2 秒)⇒ 移到锁外;
                #   原实现把点击+轮询一起放在锁里,单次认领就能把互斥窗口撑到 20 秒以上。
                $cl = $null
                $cw = Wait-GonghaiLock -MaxWaitSec 90 -LockName $script:LockName
                if (-not $cw.ok) { Say "END LOCK_BUSY (认领:等待超时,放弃本轮)"; break }
                try {
                    $cl = Invoke-GonghaiClaimRow -Key $c.key -RowIdx $c.row
                } finally {
                    # 点击成功/失败/抛异常都由 finally 覆盖 ⇒ 认领路径绝不留锁。
                    Release-AppLock $script:LockName
                }
                Say ("claim click: ok=$($cl.ok) err=$($cl.err)")
                if ($cl.limitHit) { $script:Abort = "CLAIM_LIMIT_HIT"; Say ("ABORT CLAIM_LIMIT_HIT limitTxt=" + $cl.limitTxt); break }
                if (-not $cl.ok) { Say "END CLAIM_FAILED"; continue }
                $verified = $false
                for ($t = 1; $t -le 10; $t++) {
                    Start-Sleep -Seconds 2
                    $chk = Test-GonghaiRowClaimed -Key $c.key -RowIdx $c.row
                    if ($chk.gone) { Say ("  t+" + ($t*2) + "s: 行已消失 -> 认领生效"); $verified = $true; break }
                    if (-not $chk.hasClaim) { Say ("  t+" + ($t*2) + "s: 按钮消失 -> 认领生效"); $verified = $true; break }
                }
                Say ("claim verified = $verified")
                if (-not $verified) { $script:Abort = "CLAIM_NOT_VERIFIED"; Say "ABORT CLAIM_NOT_VERIFIED"; break }
                $clTs = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Write-GonghaiLog ("GONGHAI-CLAIM " + $code + " " + $clTs)
                Say ("GONGHAI-CLAIM $code " + $clTs)
            }
        }

        # [FIX-DRYRUNCOUNT 2026-09-27] DryRun 的配额必须在**开始试这个人之前**记账。
        #   原实现在"搜索成功"分支里才 `$sentThisRun++`,于是**搜索失败的人从不计数**,
        #   而配额只在循环开头检查 ⇒ `-Count 1 -DryRun` 在"候选人普遍没认领、个个搜不到"时
        #   会把 8 个候选人 × 6 次重试 × 15 秒 ≈ 十几分钟全跑完都不退出
        #   (实测 2026-09-27 两次,均由老板手动掐断)。
        #   口径澄清:配额 = 「本次运行**尝试处理**的人数」(成功/失败都算) ⇒ 必然收敛。
        if ($DryRun) { $sentThisRun++ }

        # 6c) OneTalk 搜索定位。
        # ⚠️ **必须带重试等待**:实测(2026-09-27)认领后立刻搜 = n=0,等约 1 分钟 = n=1。
        #    OneTalk 索引有同步延迟 ⇒ 一次判否会误判成"路径不通"(我曾因此错误结案)。
        # ⚠️ 为什么整段放在**锁外**:搜索只是把关键字填进搜索框(可由 Restore-OneTalkList 复原的
        #    中间态),而每轮重试里含 10 秒 / 15 秒的**等待** —— 放在锁里就是"拿着互斥锁睡觉"。
        #    实测代价:一个人最多 6 轮 × ~15 秒 ≈ 90 秒以上,monitor 全程 LOCK-BUSY 干等。
        $opened = $null
        $sendRes = ''
        $sendStatus = ''
        for ($try = 1; $try -le 6; $try++) {
            $op = Open-OneTalkSearchPanel
            if (-not $op.ok) { Say ("panel: ok=False stage=" + $op.stage + " (try $try)"); Start-Sleep -Seconds 10; continue }
            $sr = Invoke-OneTalkSearch -Keyword $c.name
            if (-not $sr.ok) { Say ("search failed (try $try): " + $sr.err); Start-Sleep -Seconds 10; continue }
            Start-Sleep -Seconds 2
            $rc = Get-GonghaiSearchResultCount
            Say ("search try $try : typed=$($sr.typedLen) results=$($rc.n)")
            if ($rc.n -lt 1) {
                Say ("  索引未同步,等 15 秒重试")
                Start-Sleep -Seconds 15
                continue
            }

            # 6d) ★ 页面写窗口②(发送):唯一持锁的发送路径(**实现已在 gonghai_lib.ps1**)。
            #   窗口内容 = 「开搜索结果(按 customerId 挑人) → 核对身份 → 先写后发 → 发送 → 恢复页面」,
            #   **一个都不能拆到窗口外**(拆开 = 校验用的会话可能已被换掉 = 发错人,硬约束)。
            #   返回 @{ gotLock; verdict; open; send; status }。窗口结束后页面已复原、锁已释放(异常路径同样如此)。
            $W = Invoke-GonghaiSendWindow -Code $code -ExpectedName $c.name -ExpectedKey $c.key -Text $ibText -Page $ghTab -Index $index -DryRun:$DryRun
            $script:SendWindowRestored = $true   # 窗口内部**必然**恢复过页面(§6.5.14)⇒ 外层收尾不再重复恢复
            if ($W.open) { Say ("  open: clicked=$($W.open.clicked) hasTa=$($W.open.hasTa) cardId=$($W.open.cardIdAbbrev) tried=$($W.open.tried)") }
            if ($W.verdict -eq 'LOCK_BUSY') { Say "END LOCK_BUSY code=$code (等待超时,放弃本轮)"; break }
            if ($W.verdict -eq 'WRONG_CONVO') {
                # [FIX-SENDBYNAME 2026-09-27] 走到这里 key 必然非空(无 key 路径不比对 customerId)
                #   ⇒ Substring(0,8) 安全,不会重演 2026-09-27 16:19 的 ArgumentOutOfRange。
                Say ("ABORT_WRONG_CONVO code=$code expected=" + $c.key.Substring(0,8) + " actual=" + $W.open.cardId.Substring(0,8))
                $script:Abort = "ABORT_WRONG_CONVO"
                break
            }
            if ($W.verdict -eq 'NO_CARDID') {
                # [2026-09-27 收敛] 打开了会话却读不到 customerId ⇒ 无法证明发对人 ⇒ 不发送。
                #   与 WRONG_CONVO 的区别:后者是"证明发错人"(停机);这里是"证不出来"(跳过 + 入队等重试)。
                Say ("SKIP NO_CARDID code=$code (详情卡读不到 customerId ⇒ 拒发)")
                if (-not $DryRun) { Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $code -Reason 'NO_CARDID' }
                break
            }
            if ($W.verdict -eq 'DONE') { $opened = $W.open; $sendRes = [string]$W.send; $sendStatus = [string]$W.status; break }
            # OPEN_FAIL / INCONCLUSIVE(cardId 尚未渲染):与旧实现一致 —— 等 10 秒重搜。
            #   注意这一步在**锁外**(窗口已释放锁),不会再把 10 秒算进互斥窗口。
            Start-Sleep -Seconds 10
        }
        if ($script:Abort) { break }
        if (-not $opened) {
            Say "END NOT_FOUND_IN_SEARCH code=$code (重试 6 次仍搜不到 -> 跳过,不发送)"
            # [2026-09-27 收敛] 搜不到 = 认领了却发不出去 ⇒ **必须入队**,否则这个人就永久卡住(当天 2 例)
            #   ⚠️ 但 `-DryRun` **不入队**:演练对象多是"根本没认领"的公开行(搜不到本来就是正常的),
            #      把演练对象写进待办队列等于制造假待办(实测 2026-09-27 21:23 踩到并已清理)。
            if (-not $DryRun) { Add-GonghaiPending -CustomerKey $c.key -Name $c.name -Code $code -Reason 'INDEX_NOT_SYNCED' }
            # [FIX-DRYRUNCOUNT] 失败也要看配额:DryRun 下这个人是"已尝试"过的(上面已计数)。
            if ($sentThisRun -ge $runCap) { Say "RUN_CAP_REACHED ($sentThisRun)"; break }
            continue
        }
        if ($c.key) { Say "identity OK (customerId == data-row-key)" } else { Say "identity OK (会话已打开; key 未提供,身份由发送侧会话名校验兜底)" }

        if ($DryRun) {
            # [SPEC-公海独立Chrome §5-E5] -DryRun 报告必须能证明"目标页属于公海自己的 Chrome(9225)"。
            #   所以这里显式打出端口的 ws 端点 —— 这是"发送会落在 9225"的直接证据。
            $sendPagePort = Get-SendPageWsPort $ghTab
            Say ("DRYRUN would send to code=$code nameLen=$($c.nameLen) country=$($c.country) icebreakerId=$ibId")
            Say ("DRYRUN target page: port=$sendPagePort tabId=" + (([string]$ghTab.id -split '\s+')[0]) + " url=" + ((([string]$ghTab.url) -replace '[?#].*$','')))
            Say ("DRYRUN page-port-matches-gonghai=" + ($sendPagePort -eq $ghPort) + " (gonghaiPort=$ghPort)")
            # [FIX-DRYRUNCOUNT 2026-09-27] 配额已在"开始试这个人之前"记过账(见上方 `if ($DryRun) { $sentThisRun++ }`),
            #   这里**不再自增**(否则一次尝试记两笔)。只做"达上限即退出"。
            #   旧实现把自增放在这里 ⇒ 只有"搜到人"的候选才计数,搜不到的从不计数,
            #   配合"配额只在循环开头检查" ⇒ `-Count 1 -DryRun` 可能十几分钟都不退出。
            if ($sentThisRun -ge $runCap) { Say "RUN_CAP_REACHED ($sentThisRun) [dryrun]"; break }
            continue
        }

        # 发送结果处理（**锁外**）:「先写后发」+ 发送 + 账本/限速/日志**都已在窗口内**由
        #   `Complete-GonghaiSend` 一次做完(唯一处) ⇒ 这里只做控制流(计数/熔断/停机/入队)。
        #   为什么把记账收进窗口:2026-09-27 事故里 batch 与 probe 各写一份同一判据,结果一份 fail-open。
        $r = $sendRes
        Say ("send: " + ($r -replace '\s+',' '))
        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        if ($sendStatus -eq 'sent') {
            Say ("GONGHAI-SENT $code $now")
            if ($RetryPending) { Remove-GonghaiPending -CustomerKey $c.key }   # 补发成功 ⇒ 出队
            $sentThisRun++
            $consecFail = 0
        } elseif ($r -match 'ABORT_WRONG_PAGE') {
            # [SPEC §5-P10] 发送前双重校验失败(页不属于公海实例 / 会话名不精确相等)
            #   ⇒ 一条都不发。记日志、本轮停机(锁已在窗口内释放)。
            Write-GonghaiLog ("GONGHAI-ABORT_WRONG_PAGE " + $code + " " + $now)
            Say ("GONGHAI-ABORT_WRONG_PAGE $code $now")
            $script:Abort = "ABORT_WRONG_PAGE"
            break
        } elseif ($r -match 'ABORT_WRONG_CONVO') {
            Say ("GONGHAI-ABORT_WRONG_CONVO $code $now")
            $script:Abort = "ABORT_WRONG_CONVO"
            break
        } else {
            # `notsent`(可证明没发出去)/ `failed`(结果未知)统一显示,便于人工判断
            Say ("GONGHAI-" + $sendStatus.ToUpper() + " $code $now ($r)")
            $consecFail++
            if ($consecFail -ge 2) { Say "ABORT 连续 2 条失败,停本轮(§6.5.4 熔断)"; break }
        }
    } finally {
        # ★ 无论成功失败:恢复 OneTalk 页面状态(§6.5.14 硬要求)。
        #   ⚠️ 锁**不在这里**释放 —— 本循环外层已经不再持锁(锁只在两个窗口内部持有,
        #      窗口自己的 finally 负责释放)。在这里无条件 Release-AppLock 会误删**别人**
        #      (monitor / nudge)持有的锁文件,那是比"漏释放"更严重的错。
        #   发送窗口已经恢复过页面时(见 $script:SendWindowRestored)不再重复恢复,
        #      避免多花约 3.4 秒做一次没有意义的页面写。
        if (-not $script:SendWindowRestored) {
            $restore = Restore-OneTalkList
            Say ("restore: ok=$($restore.ok) contacts=$($restore.contacts)")
            if (-not $restore.ok) { Say ("RESTORE-FAILED raw=" + ($restore.raw -replace '\s+',' ')) }
        }
    }
}

Say ("=== done: sentThisRun=$sentThisRun abort=$($script:Abort) ===")
if ($script:Abort) { exit 9 }
exit 0
