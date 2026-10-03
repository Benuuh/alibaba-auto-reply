# tools\gonghai_doctor.ps1 - 公海链路**只读**体检工具(2026-09-27 收敛:合并原 7 个 _gh_*.ps1 临时脚本)
#
# 为什么要有它:2026-09-27 的 OPEN_FAIL 事故排查里,现场是"东一个脚本、西一个脚本"
#   (`_gh_state / _gh_mine / _gh_search_diag / _gh_left_list / _gh_verify_sent / _gh_pane_text`),
#   事后没人记得哪个是哪个。现在收成一个入口、四个动作。
#
# 用法:
#   gonghai_doctor.ps1 -Action state                        # OneTalk 页状态(登录/列表条数/验证码/详情卡)
#   gonghai_doctor.ps1 -Action mine                         # 我的客户列表(代号 + 明文名,用于把代号反查成人)
#   gonghai_doctor.ps1 -Action mine -Codes gh-xxxx,gh-yyyy  # 只反查指定代号
#   gonghai_doctor.ps1 -Action search -Name "<客户名>"       # 复现"开面板 → 打字 → 计数 → 点结果"这条链
#   gonghai_doctor.ps1 -Action pane   -Name "<客户名>" -Code gh-xxxx   # 打开会话并回读正文(核验消息是否真发出)
#
# ⚠️ 只读纪律:
#   · `state` / `mine` 不写任何页面(只在缺页时新开一个只读列表页);
#   · `search` / `pane` 会做**可复原**的页面写(开搜索面板 / 打字 / 点结果),全程持 onetalk-write 写锁,
#     结束必调 `Restore-OneTalkList`;**从不**填输入框、**从不**点"发送"。
#   · 端口一律走 `Get-GonghaiCdpPort`(现役 9225);绝不碰 9222(monitor 的浏览器)。
param(
    [Parameter(Mandatory = $true)][ValidateSet('state', 'mine', 'search', 'pane', 'pending', 'pool', 'status', 'replies')][string]$Action,
    [string]$Name = '',
    [string]$Code = '',
    [string[]]$Codes = @(),
    [switch]$DoOpen,         # search:连"点开第 1/N 条结果读 cardId"一起做
    [switch]$Reload          # mine:先刷新列表页(列表会冻结在加载那一刻)
)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$S = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'   # 本文件在 <部署根>\tools\ ⇒ 上一级是部署根
. (Join-Path $S 'config.ps1')
. (Join-Path $S 'lib\log.ps1')
. (Join-Path $S 'lib\lock.ps1')
. (Join-Path $S 'lib\cdp.ps1')
. (Join-Path $S 'gonghai\gonghai_cdp.ps1')
. (Join-Path $S 'gonghai\gonghai_lib.ps1')

$port = Get-GonghaiCdpPort
Write-Output ("=== GONGHAI-DOCTOR action=$Action port=$port " + (Get-Date -Format 'HH:mm:ss') + " ===")

function Read-LiveLogLines([string]$Path) {
    # [GH-32] **共享读**:用 FileShare.ReadWrite 打开,绝不挡住 monitor/batch 的追加写。
    # 为什么:实测 PowerShell 的 Select-String/Get-Content 读日志时持有句柄、不允许他进程写入 ⇒
    #   巡检期间生产的 Write-SkillLog 会抛 `Add-Content ... used by another process`。
    if (-not (Test-Path $Path)) { return @() }
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        return @($sr.ReadToEnd() -split "`r?`n")
    } catch { return @() } finally { if ($sr) { $sr.Dispose() }; if ($fs) { $fs.Dispose() } }
}
function Show([string]$tag, $obj) {
    if ($null -eq $obj) { Write-Output ("[" + $tag + "] (null)"); return }
    Write-Output ("[" + $tag + "] " + (($obj | ConvertTo-Json -Compress -Depth 6) -replace '\s+', ' '))
}

function Invoke-Gh([string]$js, [string]$urlMatch) {
    $r = ''
    try { $r = [string](Invoke-GonghaiEval -Script $js -UrlMatch $urlMatch) } catch { $r = "EVAL-ERR: " + $_.Exception.Message }
    return $r
}

# ---------------------------------------------------------------- state
if ($Action -eq 'state') {
    $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
    $tabs | Where-Object { $_.type -eq 'page' } | ForEach-Object { Write-Output ("  tab: " + $_.url.Substring(0, [Math]::Min(110, $_.url.Length))) }
    $js = @'
(function(){
  var q = function(s){ try { return document.querySelectorAll(s).length; } catch(e){ return -1; } };
  var contacts = Array.from(document.querySelectorAll('.contact-item-container'));
  var inp = Array.from(document.querySelectorAll('input')).filter(function(x){ return String(x.placeholder||'').indexOf('搜索') >= 0; })[0];
  var g = function(k){ try { return (window[k]===undefined||window[k]===null)?'':String(window[k]); } catch(e){ return ''; } };
  var m = String(location.href).match(/activeAccountId=(\d+)/);
  return JSON.stringify({
    urlAccountId: m ? m[1] : '', currentUserAccountId: g('currentUserAccountId'), loginId: g('currentUserLoginId'),
    hasTextarea: !!document.querySelector('textarea.send-textarea'), leftItems: contacts.length,
    leftFirst5: contacts.slice(0,5).map(function(e){ var n=e.querySelector('.contact-info .name'); return ((n&&n.innerText)||'').replace(/\s+/g,' ').trim().substring(0,26); }),
    hasSearchInput: !!inp, searchValue: inp ? String(inp.value||'') : '',
    panelItems: q('.contact-list-item, .all-list-content li'), baxiaCaptcha: q('#baxia-dialog-content'),
    detailCard: q('.alicrm-customer-detail-card')
  });
})()
'@
    Show 'state' (ConvertFrom-GonghaiOutput (Invoke-Gh $js (Get-GonghaiOnetalkUrlMatch)))
    exit 0
}

# ---------------------------------------------------------------- pending
# "认领了却没发成功"的人 —— 老板要的"发不出去就记录"就是这里(明文名只在本机输出)。
if ($Action -eq 'pending') {
    $pl = @(Get-GonghaiPendingList)
    Write-Output ("待办队列 = " + $pl.Count + " 条（补发: gonghai_probe.ps1 -RetryPending [-Count N|-CustomerId <key>]）")
    if ($pl.Count -eq 0) { Write-Output "  (空)"; exit 0 }
    $i = 0
    foreach ($p in $pl) {
        $i++
        Write-Output ("  [$i] " + $p.code + "  key=" + $p.key + "  reason=" + $p.reason + "  tries=" + $p.tries + "  入队=" + $p.added_at + "  name=[" + $p.name + "]")
    }
    exit 0
}

# ---------------------------------------------------------------- replies
# 破冰**回音统计**(只读,纯本地):扫 monitor 的会话快照,找出"含我方破冰话术"的会话,
#   再看破冰之后有没有买家消息 ⇒ 直接回答"我们发的破冰有多少人回了"。
#   原理:快照是**按会话逐份**导出的(首行 `# BUYER: <名>`),消息按**新→旧**排列,
#   所以"买家在破冰之后回过话" = 某条 `[BUYER]` 行出现在破冰那行的**前面**。
#   ⚠️ 口径限制:快照只覆盖 monitor 处理过的会话、且受保留策略(约 200 份)约束 ⇒ 这是**下界**,
#      不是"发出多少条里有多少人回"的精确值;精确值要等阿里侧会话列表统计。
if ($Action -eq 'replies') {
    $dataDir = Get-SkillPath 'data'
    $ib = Get-GonghaiIcebreaker
    $ibHead = $ib.Substring(0, [Math]::Min(40, $ib.Length))
    $files = @(Get-ChildItem $dataDir -Filter 'msgs_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    Write-Output ("扫描快照 = " + $files.Count + " 份 ; 破冰话术指纹 = [" + $ibHead + "...]")
    $seen = @{}; $replied = @{}
    foreach ($f in $files) {
        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($f.FullName) } catch { continue }
        if ($lines.Count -lt 2) { continue }
        $name = ''
        if ($lines[0] -match '^#\s*BUYER:\s*(.+)$') { $name = $Matches[1].Trim().ToLower() }
        if (-not $name) { continue }
        $ibIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].IndexOf($ibHead) -ge 0 -and $lines[$i] -match '\[ME\]') { $ibIdx = $i; break }
        }
        if ($ibIdx -lt 0) { continue }                       # 这条会话不是我们破冰的
        $seen[$name] = $true
        for ($i = 0; $i -lt $ibIdx; $i++) {                  # 破冰行**之前** = 更新 ⇒ 买家回过话
            if ($lines[$i] -match '\[BUYER\]') {
                $txt = ($lines[$i] -replace '@@TS:\d+', '' -replace '@@OT:\S+', '' -replace '\s+', ' ').Trim()
                if ($txt.Length -gt 90) { $txt = $txt.Substring(0, 90) }
                $replied[$name] = $txt
                break
            }
        }
    }
    Write-Output ("可见的破冰会话 = " + $seen.Count + " 条 ; 其中**买家回过话** = " + $replied.Count + " 条")
    if ($seen.Count -gt 0) { Write-Output ("回音率(以可见会话为分母) = " + [Math]::Round(100.0 * $replied.Count / $seen.Count, 1) + " %") }
    Write-Output "--- 回过话的会话 ---"
    foreach ($k in ($replied.Keys | Sort-Object)) { Write-Output ("  " + $k + "： " + $replied[$k]) }
    Write-Output "（⚠️ 下界口径：快照只覆盖 monitor 处理过的会话且受保留份数限制）"
    exit 0
}

# ---------------------------------------------------------------- status
# 一屏看全:今日进度 / 链路状态 / 风控信号 / 待办队列 / 最近几轮结果。**只读**,可与批次并行跑。
if ($Action -eq 'status') {
    $ratePath = Join-Path (Get-SkillPath 'data') 'gonghai\gonghai_rate.json'
    $rate = $null
    try { $rate = Get-Content $ratePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    $today = (Get-Date -Format 'yyyy-MM-dd')
    $logPath = Join-Path (Get-SkillPath 'logs') 'monitor.log'
# [GH-59] 统计类读取必须**含轮转归档**（monitor*.log），否则会漏掉当天更早的行（实测差 12 倍）。
$logAll = @(Get-ChildItem (Get-SkillPath 'logs') -Filter 'monitor*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_(out|err)\.log$' } | Sort-Object LastWriteTime)
    $sentToday = 0
    $live = Read-LiveLogLines $logPath
    try { $sentToday = @($live | Where-Object { $_ -match ("^" + $today + " .*GONGHAI-SENT") }).Count } catch { }
    Write-Output ("【今日】" + $today + " 已发 = " + $sentToday + "  (rate.json day=" + $(if ($rate) { $rate.day } else { '?' }) + " count=" + $(if ($rate) { $rate.day_count } else { '?' }) + " last=" + $(if ($rate) { $rate.last_sent_at } else { '?' }) + ")")

    $batches = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match '\-File\s+\S*batch\.ps1' -and $_.CommandLine -notmatch '\-Command' })
    $loops = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'gonghai_loop\.ps1' -and $_.CommandLine -notmatch '\-Command' })
    Write-Output ("【链路】批次进程 = " + $batches.Count + " ; loop 实例 = " + $loops.Count)
    $lock = Join-Path (Get-SkillPath 'data') 'gonghai-loop.lock'
    if (Test-Path $lock) {
        $v = (Get-Content $lock -Raw).Trim(); $hp = ($v -split '\|')[0]
        $alive = ($hp -match '^\d+$') -and [bool](Get-Process -Id ([int]$hp) -ErrorAction SilentlyContinue)
        Write-Output ("         单例锁: " + $v + "  持有者存活=" + $alive)
    } else { Write-Output "         单例锁: 无(没有 loop 在跑)" }

    $keys = @('RISK-ABORT', 'RISK-EVALFAIL', 'LIST-REPAIR', 'LIST-READFAIL', 'CLAIM-ERR', 'LIST-DEAD')
    $line = "【风控/自愈】"
    foreach ($k in $keys) { $line += $k + "=" + @($live | Where-Object { $_ -match $k }).Count + "  " }
    Write-Output $line

    $pl = @(Get-GonghaiPendingList)
    Write-Output ("【待办】" + $pl.Count + " 条（发不出去的人；-Action pending 看明细；gonghai_probe.ps1 -RetryPending 补发）")
    if ($pl.Count -gt 0) { Write-Output ("        原因分布: " + (($pl | Group-Object reason | ForEach-Object { $_.Name + ':' + $_.Count }) -join ', ')) }

    Write-Output "【最近轮次】"
    $dir = Get-SkillPath 'logs'
    @(Get-ChildItem $dir -Filter 'gonghai_*_r*.txt' -ErrorAction SilentlyContinue) | Sort-Object LastWriteTime | Select-Object -Last 5 | ForEach-Object {
        $d = Get-Content $_.FullName | Select-String -Pattern '^=== done:' | Select-Object -Last 1
        Write-Output ("  " + $_.Name.PadRight(32) + " " + $(if ($d) { ($d.Line -replace '=== done: ', '') } else { '(进行中/异常退出)' }))
    }
    exit 0
}

# ---------------------------------------------------------------- pool
# 公海首页逐行体检:看清"本页 10 行里为什么只有 9 行可用"(GH-25) —— 只读,不点任何按钮。
if ($Action -eq 'pool') {
    $js = @'
(function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var out = rows.map(function(r, i){
    var tds = r.querySelectorAll('td');
    var td1 = tds[1];
    var nameEl = td1 ? td1.querySelector('.name--ECjwwoJJ span') : null;
    var cands = [];
    Array.from(r.querySelectorAll('[class*=name],[class*=Name]')).slice(0,4).forEach(function(e){
      var t = (e.innerText||'').replace(/\s+/g,' ').trim();
      cands.push(String(e.className).substring(0,30) + '=>' + (t.length > 36 ? t.substring(0,36) : t));
    });
    return { i: i, key: String(r.getAttribute('data-row-key')||''), tdCount: tds.length,
             nameLen: nameEl ? ((nameEl.innerText||'').replace(/\s+/g,' ').trim().length) : -1,
             td1Head: td1 ? (td1.innerText||'').replace(/\s+/g,' ').trim().substring(0,60) : '',
             cands: cands,
             hasClaimBtn: (function(){ try { return /加为我的客户/.test(r.innerText||''); } catch(e){ return false; } })() };
  });
  var e = document.querySelector('.ant-pagination-total-text');
  return JSON.stringify({ total: e ? (e.innerText||'').trim() : '', rows: out });
})()
'@
    $o = ConvertFrom-GonghaiOutput (Invoke-Gh $js 'i\.alibaba\.com/hub/alicrm/public_customer')
    if (-not $o) { Write-Output "ABORT 读不到公海列表"; exit 1 }
    Write-Output ("公海总数 = " + $o.total + " ; DOM 行数 = " + @($o.rows).Count)
    $usable = 0
    foreach ($r in @($o.rows)) {
        $ok = ($r.key -and $r.key.Length -eq 32 -and $r.nameLen -gt 0)
        if ($ok) { $usable++ }
        Write-Output ("  [" + $r.i + "] usable=" + $ok + "  keyLen=" + $r.key.Length + "  nameLen=" + $r.nameLen + "  hasClaimBtn=" + $r.hasClaimBtn + "  code=" + $(if ($r.key.Length -eq 32) { 'gh-' + (Get-GonghaiHash8 $r.key) } else { '(bad-key)' }))
        if (-not $ok) {
            Write-Output ("       td1Head=[" + $r.td1Head + "]")
            foreach ($c in @($r.cands)) { Write-Output ("       cand: " + $c) }
        }
    }
    Write-Output ("=> 可用行 = " + $usable + " / " + @($o.rows).Count)
    exit 0
}

# ---------------------------------------------------------------- mine
if ($Action -eq 'mine') {
    $url = 'https://i.alibaba.com/hub/alicrm/my_customer'
    $match = 'i\.alibaba\.com/hub/alicrm/my_customer'
    $page = Get-GonghaiPage -UrlMatch $match
    if ($page -and $Reload) {
        # 实测教训:这条列表和 OneTalk 的会话列表一样会**冻结**(页面加载那一刻的快照),
        #   "刚认领的客户"不在里面 ⇒ 反查前必须先刷新。
        Write-Output "刷新 my_customer 页(列表会冻结在加载那一刻,反查新认领客户必须先刷新)"
        try { [void](Set-GonghaiPageUrl -Page $page -Url $url) } catch { Write-Output ("刷新失败: " + $_.Exception.Message) }
        Start-Sleep -Seconds 12
    }
    if (-not $page) {
        Write-Output "my_customer 页不在,新开一个(只读列表页)"
        try { [void](New-GonghaiPage -Url $url) } catch { Write-Output ("新开失败: " + $_.Exception.Message) }
        Start-Sleep -Seconds 12
    }
    $js = @'
(function(){
  var rows = Array.from(document.querySelectorAll('tbody tr.ant-table-row'));
  var out = rows.map(function(r){
    var td1 = r.querySelectorAll('td')[1];
    var nameEl = td1 ? td1.querySelector('.name--ECjwwoJJ span') : null;
    return { key: String(r.getAttribute('data-row-key')||''),
             name: nameEl ? (nameEl.innerText||'').replace(/\s+/g,' ').trim() : (td1 ? (td1.innerText||'').replace(/\s+/g,' ').trim().substring(0,40) : '') };
  });
  var e = document.querySelector('.ant-pagination-total-text');
  return JSON.stringify({ total: e ? (e.innerText||'').trim() : '', rows: out });
})()
'@
    $o = ConvertFrom-GonghaiOutput (Invoke-Gh $js $match)
    if (-not $o) { Write-Output "ABORT 读不到行"; exit 1 }
    Write-Output ("总数 = " + $o.total + " ; 本页 = " + @($o.rows).Count + " 行")
    $want = @(); foreach ($c in $Codes) { foreach ($x in ([string]$c -split ',')) { $t = $x.Trim(); if ($t) { $want += $t } } }
    foreach ($r in @($o.rows)) {
        if (-not $r.key) { continue }
        $code = 'gh-' + (Get-GonghaiHash8 $r.key)
        if ($want.Count -gt 0 -and ($want -notcontains $code)) { continue }
        Write-Output ("  " + $code + "  key=" + $r.key + "  name=[" + $r.name + "]")
    }
    if ($want.Count -gt 0) {
        $have = @($o.rows | Where-Object { $_.key } | ForEach-Object { 'gh-' + (Get-GonghaiHash8 $_.key) })
        foreach ($w in $want) { if ($have -notcontains $w) { Write-Output ("  " + $w + "  ->  本页没有(在别的分页/筛选后不可见)") } }
    }
    exit 0
}

# ---------------------------------------------------------------- search / pane
if (-not $Name) { Write-Output "ABORT -Action $Action 需要 -Name"; exit 2 }

$got = $false
for ($i = 1; $i -le 40; $i++) { if (Get-AppLock 'onetalk-write' 0) { $got = $true; break }; Start-Sleep -Milliseconds 1200 }
Write-Output ("lock = " + $got)
try {
    $op = Open-OneTalkSearchPanel
    Write-Output ("panel: ok=" + $op.ok + " stage=" + $op.stage)
    $sr = Invoke-OneTalkSearch -Keyword $Name
    Write-Output ("search: ok=" + $sr.ok + " typedLen=" + $sr.typedLen + " err=" + $sr.err)
    Start-Sleep -Seconds 2
    $rc = Get-GonghaiSearchResultCount
    Write-Output ("results: n=" + $rc.n + " lens=" + (($rc.lens) -join ','))
    if ($rc.n -lt 1) { Write-Output "0 结果 ⇒ 阿里侧索引未建成(模块侧无解)"; exit 0 }

    if ($Action -eq 'search' -and -not $DoOpen) { exit 0 }

    $open = Open-GonghaiSearchResult -ExpectedKey $Code
    $cardCode = ''
    if ($open.cardId) { $cardCode = 'gh-' + (Get-GonghaiHash8 $open.cardId) }
    Write-Output ("open: clicked=" + $open.clicked + " hasTa=" + $open.hasTa + " tried=" + $open.tried + " cardId=" + $open.cardId + " (" + $cardCode + ") hdrLen=" + $open.hdrLen)
    if ($Code) { Write-Output ("      期望 code=" + $Code + " 一致=" + ($cardCode -eq $Code)) }
    if ($Action -eq 'search') { exit 0 }

    # pane:回读会话正文,核验破冰话术是否真的在(证明 SENT_OK 不是假成功)
    $ib = Get-GonghaiIcebreaker
    $js = @'
(function(){
  var ta = document.querySelector('textarea.send-textarea');
  if (!ta) return JSON.stringify({ err: 'NO_TEXTAREA' });
  var node = ta, best = null;
  for (var i = 0; i < 10 && node; i++) {
    node = node.parentElement; if (!node) break;
    var c = String(node.className || ''); var t = (node.innerText || '');
    if (/chat|message|conversation|session|im-/i.test(c) && t.length > 60) { best = node; break; }
  }
  if (!best) best = ta.parentElement ? ta.parentElement.parentElement : null;
  var txt = best ? (best.innerText || '') : '';
  return JSON.stringify({ cls: best ? String(best.className).substring(0,60) : '', len: txt.length,
    hasIcebreaker: txt.indexOf('reaching out') >= 0, tail: txt.replace(/\s+/g,' ').trim().slice(-400) });
})()
'@
    $o = ConvertFrom-GonghaiOutput (Invoke-Gh $js (Get-GonghaiOnetalkUrlMatch))
    Show 'pane' $o
    if ($o) { Write-Output ("=> 破冰话术命中 = " + [bool]$o.hasIcebreaker + "  (icebreakerId=" + (Get-GonghaiIcebreakerId) + ")") }
} finally {
    try { [void](Restore-OneTalkList) } catch { }
    if ($got) { Release-AppLock 'onetalk-write' }
}
