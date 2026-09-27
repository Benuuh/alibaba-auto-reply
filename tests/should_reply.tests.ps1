# should_reply tests -- [SPEC-单出口 2026-09-27] 「是否回复」唯一出口 Test-ShouldReply 的纯逻辑回归
#
# 对应 spec: docs\specs\误发终止_单出口判据_20260927.md（唯一事实源）
# 本文件覆盖:
#   §4.1 判定表 8 行（Reason 字符串逐字断言）
#   §5.1 A7  旧格式账本(13 位时间戳)不误发
#   §5.1 A8  静态检查：单出口 / 无旧判据调用 / nudge 无买家发送
#   §5.2 A10 事故现场回归（erico/Riyad 两条真重复必须 Reply=false）
#   §5.2 A11 首次询盘仍能回（防"修成哑巴"）
#   §5.2 A12 买家真说新话仍能回
#
# ⚠️ 本文件必须保持 UTF-8 **带 BOM**（同 page_health_verdict.tests.ps1 的 M12 陷阱）。
# 纯逻辑：不碰页面、不碰 Chrome、不碰 CDP、不写任何文件（事故快照只读）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent
$scripts = Join-Path $root "scripts"
. (Join-Path $scripts "config.ps1")      # 取集中配置(config.json 的 data_dir), 见下方 A10
. (Join-Path $scripts "reply_engine.ps1")

$script:pass = 0; $script:fail = 0
function Assert-Eq([string]$n, [object]$a, [object]$b) { if ($a -eq $b) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n | got:[$a] want:[$b]" } }
function Assert-True([string]$n, [bool]$c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Output "  FAIL: $n" } }

Write-Output "== should_reply tests =="

# ---------------------------------------------------------------------------
# 0) 判据存在 + 返回形状
# ---------------------------------------------------------------------------
Assert-True "fn-exists" ($null -ne (Get-Command Test-ShouldReply -EA SilentlyContinue))
$r = Test-ShouldReply -ConvoLines @('[BUYER] hi') -LedgerKey '' -NormLastBuyerHash ''
Assert-True "returns-object-with-Reply" ($r.PSObject.Properties.Name -contains 'Reply')
Assert-True "returns-object-with-Reason" ($r.PSObject.Properties.Name -contains 'Reason')

# ---------------------------------------------------------------------------
# 1) 判定表 8 行（顺序固定, 先命中先返回; Reason 逐字）
#    $hA / $hB 是两条**不同**消息的 hash; MISS 是一个与两者都不相等的假账本 hash。
# ---------------------------------------------------------------------------
$hA = Get-StableHash (Get-NormalizedMsgText 'ok')
$hB = Get-StableHash (Get-NormalizedMsgText 'ok i will send it now to my director')
$MISS = 'DEADBEEFDEADBEEFDEADBEEFDEADBEEF'
$meLine = '[ME] We have branches in major Chinese logistics cities @@TS:1790480539217'
$buyerA = '[BUYER] ok'
Assert-True "fixtures-differ" ($hA -ne $hB -and $hA -ne $MISS)

# 行1: 账本第 2 段可解析为条数 且 == [BUYER] 行数 ⇒ false / LEDGER_COUNT_MATCH
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|1" -NormLastBuyerHash $hA
Assert-Eq "row1-count-match-Reply" $r.Reply $false
Assert-Eq "row1-count-match-Reason" $r.Reason 'LEDGER_COUNT_MATCH'

# 行2: 账本第 1 段 == NormLastBuyerHash ⇒ false / LEDGER_HASH_MATCH
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$hA|99" -NormLastBuyerHash $hA
Assert-Eq "row2-hash-match-Reply" $r.Reply $false
Assert-Eq "row2-hash-match-Reason" $r.Reason 'LEDGER_HASH_MATCH'
# 行1 优先于行2：条数相等且 hash 也相等时, Reason 必须是 COUNT_MATCH
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$hA|1" -NormLastBuyerHash $hA
Assert-Eq "row1-precedes-row2" $r.Reason 'LEDGER_COUNT_MATCH'

# 行3: 账本键为空 ⇒ true / NO_SELLER_MSG（从未回复过）
#   追加一条空行以证明 lastLine 的空白判定不影响本行
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA, '   ') -LedgerKey '' -NormLastBuyerHash $hA
Assert-Eq "row3-empty-key-Reply" $r.Reply $true
Assert-Eq "row3-empty-key-Reason" $r.Reason 'NO_SELLER_MSG'

# 行4: 账本键非空, 条数**不可解析**(旧格式) 且最后一行是 [BUYER] ⇒ true / BUYER_AFTER_ME
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|1789826752752" -NormLastBuyerHash $hB
Assert-Eq "row4-buyer-after-me-Reply" $r.Reply $true
Assert-Eq "row4-buyer-after-me-Reason" $r.Reason 'BUYER_AFTER_ME'

# 行2: 账本条数可解析且**小于**当前买家条数 ⇒ true / BUYER_COUNT_INCREASED(买家确实又说话了)
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|0" -NormLastBuyerHash $hB
Assert-Eq "row2-count-increased-Reply" $r.Reply $true
Assert-Eq "row2-count-increased-Reason" $r.Reason 'BUYER_COUNT_INCREASED'
# 行1 优先于行2: 条数相等时不得判"增加"
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|1" -NormLastBuyerHash $hB
Assert-Eq "row1-precedes-row2-on-equal" $r.Reason 'LEDGER_COUNT_MATCH'
# 行2 优先于位置判据: 条数增加时不得因为"我方回复排在买家之前"而改判 false
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|0" -NormLastBuyerHash $hA
Assert-Eq "row2-precedes-row3-hash" $r.Reason 'BUYER_COUNT_INCREASED'

# 行5: [ME] == 0 且账本键非空 ⇒ true / NO_SELLER_MSG
$r = Test-ShouldReply -ConvoLines @($buyerA) -LedgerKey "$MISS|1789826752752" -NormLastBuyerHash $hB
Assert-Eq "row5-no-me-lines-Reply" $r.Reply $true
Assert-Eq "row5-no-me-lines-Reason" $r.Reason 'NO_SELLER_MSG'

# 行6: 账本键非空但第 2 段不可解析(旧格式 13 位) ⇒ 若 hash 也不等 且我方尾部最后一句 ⇒ false / UNCERTAIN_FAILCLOSED
#   ⚠️ 这正是第 6 次修复的**危险回退路径**: 旧代码在此判"文本 hash 不同即算新消息"⇒ 重发。
$convMeTail = @($buyerA, $meLine)   # 最后一行是 [ME](我方收尾), meCount=1
$r = Test-ShouldReply -ConvoLines $convMeTail -LedgerKey "$MISS|1789826752752" -NormLastBuyerHash $hB
Assert-Eq "row6-legacy-13digit-Reply" $r.Reply $false
Assert-Eq "row6-legacy-13digit-Reason" $r.Reason 'UNCERTAIN_FAILCLOSED'
#   13 位段绝不能被当成条数(第 6 次修复曾因 [int] 溢出崩过) —— 断言不抛异常
$threw = $false
try { Test-ShouldReply -ConvoLines $convMeTail -LedgerKey "$MISS|1789826752752" -NormLastBuyerHash '' | Out-Null } catch { $threw = $true }
Assert-True "row6-legacy-does-not-throw" (-not $threw)

# 行7: 无账本键(null) ⇒ 行3 返回"新询盘"(纵深防御: 行为不得变成 false)
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey $null -NormLastBuyerHash ''
Assert-Eq "row7-null-key-still-first-contact" $r.Reason 'NO_SELLER_MSG'

# 行8: 账本第 2 段异常(负数 / 超长数字 / 纯垃圾 / 缺失) ⇒ 一律 fail-closed
foreach ($bad in @('-1', '9999999999', 'abc', '')) {
    $key = if ($bad -eq '') { $MISS } else { "$MISS|$bad" }
    $r = Test-ShouldReply -ConvoLines $convMeTail -LedgerKey $key -NormLastBuyerHash $hB
    Assert-Eq ("row8-bad-seg[$bad]-Reply") $r.Reply $false
    Assert-Eq ("row8-bad-seg[$bad]-Reason") $r.Reason 'UNCERTAIN_FAILCLOSED'
}

# 行7: 条数可解析但**减少**(抽取漂移)且 hash 也对不上 ⇒ fail-closed, 不发
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$MISS|9" -NormLastBuyerHash $hB
Assert-Eq "row7-count-decreased-Reply" $r.Reply $false
Assert-Eq "row7-count-decreased-Reason" $r.Reason 'UNCERTAIN_FAILCLOSED'

# 行8b: 我方尾部是 [ME] 且最后一条买家消息的 hash **等于**账本 hash ⇒ 由行2 拦下(证明已回过这条)
$convBuyerLast = @($meLine, $buyerA)
$r = Test-ShouldReply -ConvoLines $convBuyerLast -LedgerKey "$hA|1789826752752" -NormLastBuyerHash $hA
Assert-Eq "row8b-hash-proven-duplicate-Reply" $r.Reply $false
Assert-Eq "row8b-hash-proven-duplicate-Reason" $r.Reason 'LEDGER_HASH_MATCH'

# 空输入不得抛异常
$threw2 = $false
try { Test-ShouldReply -ConvoLines @() -LedgerKey '' -NormLastBuyerHash '' | Out-Null } catch { $threw2 = $true }
Assert-True "empty-input-no-throw" (-not $threw2)

# ---------------------------------------------------------------------------
# 2) §5.2-A11 首次询盘仍能回（防"修成哑巴"）
# ---------------------------------------------------------------------------
$q1 = 'Hello, do you offer air shipping to Brazil?'
$newInquiry = @("[BUYER] $q1 @@TS:1790480539217 @@OT:SGVsbG8=")
$r = Test-ShouldReply -ConvoLines $newInquiry -LedgerKey '' -NormLastBuyerHash (Get-StableHash (Get-NormalizedMsgText $q1))
Assert-Eq "A11-first-inquiry-Reply" $r.Reply $true
Assert-Eq "A11-first-inquiry-Reason" $r.Reason 'NO_SELLER_MSG'

# ---------------------------------------------------------------------------
# 3) §5.2-A12 买家真说新话仍能回（账本 hash 之后追加一条 [BUYER]）
#    Reason 取决于是"条数证据"还是"位置证据":
#      - 账本键带可解析条数且条数增加 ⇒ BUYER_COUNT_INCREASED(与位置无关的硬证据);
#      - 账本键不可解析(旧格式) ⇒ BUYER_AFTER_ME(补充判据)。
#    两种都必须是 Reply=true —— 这是防"修成哑巴"的底线。
# ---------------------------------------------------------------------------
$q2 = 'one more thing, what is the ETA'
$convOld = @($meLine, $buyerA)
$convNew = @($meLine, $buyerA, "[BUYER] $q2")
$hNew = Get-StableHash (Get-NormalizedMsgText $q2)
$r = Test-ShouldReply -ConvoLines $convNew -LedgerKey "$hA|1" -NormLastBuyerHash $hNew
Assert-Eq "A12-new-buyer-msg-Reply" $r.Reply $true
Assert-Eq "A12-new-buyer-msg-Reason" $r.Reason 'BUYER_COUNT_INCREASED'
# 旧格式账本键(条数不可解析)时的同一条新消息: 仍必须能回
$r = Test-ShouldReply -ConvoLines $convNew -LedgerKey "$hA|1789826752752" -NormLastBuyerHash $hNew
Assert-Eq "A12-legacy-key-new-msg-Reply" $r.Reply $true
Assert-Eq "A12-legacy-key-new-msg-Reason" $r.Reason 'BUYER_AFTER_ME'

# 顺序无关性(第 6 次修复的核心目标, 必须保持): 同一内容集合, 顺序翻转 ⇒ 同一结论
$revNew = @("[BUYER] $q2", $meLine, $buyerA)
$rA = Test-ShouldReply -ConvoLines $convNew -LedgerKey "$hA|1" -NormLastBuyerHash $hNew
$rB = Test-ShouldReply -ConvoLines $revNew -LedgerKey "$hA|1" -NormLastBuyerHash $hNew
Assert-Eq "order-independent-same-verdict" $rA.Reply $rB.Reply
Assert-Eq "order-independent-same-reason" $rA.Reason $rB.Reason

# ---------------------------------------------------------------------------
# 4) §5.1-A7 旧格式账本（13 位时间戳）不误发
#    (a) 账本 hash 与快照最后一条买家消息的 hash 相同 ⇒ 命中行2(已回过这条), 不发;
#    (b) 账本 hash 不同(抽取漂移) ⇒ 第二段不可解析 ⇒ 命中 fail-closed, 不发。
#    两种形态都不得发出 —— 这正是旧代码(回退"hash 不同即新消息")会误发的那条路径。
# ---------------------------------------------------------------------------
$r = Test-ShouldReply -ConvoLines @($meLine, $buyerA) -LedgerKey "$hA|1789826752752" -NormLastBuyerHash $hA
Assert-Eq "A7-legacy-key-Reply-via-hash" $r.Reply $false
Assert-Eq "A7-legacy-key-Reason-via-hash" $r.Reason 'LEDGER_HASH_MATCH'
$r = Test-ShouldReply -ConvoLines $convMeTail -LedgerKey "$MISS|1789826752752" -NormLastBuyerHash $hB
Assert-Eq "A7-legacy-key-Reply-failclosed" $r.Reply $false
Assert-Eq "A7-legacy-key-Reason-failclosed" $r.Reason 'UNCERTAIN_FAILCLOSED'

# ---------------------------------------------------------------------------
# 5) §5.2-A10 事故现场回归（绿）
#    证据 = 5 份真实快照（只读）+ **按 monitor.log 的写入时序重建的账本副本**。
#    重建规则（每一步都有日志行支撑, 见 REPORT 的 A9/A10 小节）:
#      取当前 scripts\state.json(事故中 11:42-11:49 被 monitor 写入), 再把这 3 个买家回退到
#      "该快照被处理之前"的账本值 —— 即上一次回复写入的值。
#    为什么要重建: 现役 state.json 里 Ganesan 仍是 11:42:28 写入的 |7, 而 11:45:19 那次回复
#      的写入没有落盘(日志 `savedCount=- nowCount=8` 在 11:45:10 与 11:49:07 两次出现可佐证)。
# ---------------------------------------------------------------------------
# 运行数据根从集中配置取(config.json 的 data_dir), 不写死本机绝对路径
# —— 部署根/运行数据根的绝对路径属敏感模式(sanitize 钩子会阻断), 且写死会换机即失效。
$dataDir = ""
try { $dataDir = [string](Get-SkillConfig).data_dir } catch { }
$stateFile = Join-Path $scripts "state.json"

if (-not $dataDir) {
    Write-Output "  NOTE: 未配置 data_dir, 跳过 A10 现场回归（离线环境）"
} elseif (-not (Test-Path $dataDir) -or -not (Test-Path $stateFile)) {
    Write-Output "  NOTE: 运行数据根或账本不存在, 跳过 A10 现场回归（离线环境）"
} else {
    $led = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).replied
    $ledMap = @{}
    foreach ($p in $led.PSObject.Properties) { $ledMap[$p.Name] = [string]$p.Value }

    function Get-SnapName([string]$path) {
        $first = Get-Content -Path $path -Encoding UTF8 -TotalCount 1
        if ($first -match '^# BUYER:\s*(.+)$') { return $Matches[1].Trim() }
        return ''
    }
    function Get-SnapLines([string]$path) {
        $all = @(Get-Content -Path $path -Encoding UTF8)
        $body = if ($all.Count -gt 0 -and $all[0] -match '^# BUYER:') { $all[1..($all.Count - 1)] } else { $all }
        # 与 monitor.ps1 的快照口径一致（同一过滤行）
        return @($body | Where-Object { $_ -notmatch '在Alibaba|平台聊天和交易|由阿里翻译提供|翻译提示|已读$|反馈$|举报$|自动接待' })
    }
    function Get-SnapOrig([string]$line) {
        $ot = $line
        $m = [regex]::Match($line, '@@OT:([A-Za-z0-9+/=]+)')
        if ($m.Success) { try { $ot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value)) } catch { $ot = $line } }
        return ($ot -replace '^\[BUYER\]\s*', '' -replace '@@TS:.*$', '' -replace '@@OT:[A-Za-z0-9+/=]+', '').Trim()
    }

    # ledgerOverride 给出"该快照被处理之前"的账本值; 未给出的用现役 state.json。
    $cases = @(
        @{ file = 'msgs_20260927_114208.txt'; buyer = 'erico Rodrigues';     override = $null },
        @{ file = 'msgs_20260927_114235.txt'; buyer = 'Riyad Tantawi';       override = $null },
        @{ file = 'msgs_20260927_114453.txt'; buyer = 'erico Rodrigues';     override = $null },
        # 11:45:10 快照处理时, 11:42:28 那次回复已写入 |7 ⇒ 与快照 buyerLines=8 不等;
        # 而 11:45:19 的回复本该写入 |8(11:45:10 快照的条数) ⇒ 用 |8 表示"已回过这一批"。
        @{ file = 'msgs_20260927_114510.txt'; buyer = 'Ganesan Krishnasamy'; override = '5A32DC15E20319AAC7349A9FF44CDEB2|8' }
    )

    foreach ($c in $cases) {
        $path = Join-Path $dataDir $c.file
        if (-not (Test-Path $path)) { Assert-True ("A10-snapshot-exists[{0}]" -f $c.file) $false; continue }
        $name = Get-SnapName $path
        Assert-Eq ("A10-snapshot-buyer-name[{0}]" -f $c.file) $name $c.buyer
        $lines = Get-SnapLines $path
        $bl = @($lines | Where-Object { $_ -match '^\[BUYER\]' })
        Assert-True ("A10-snapshot-has-buyer-lines[{0}]" -f $c.file) ($bl.Count -gt 0)
        $hLast = Get-StableHash (Get-NormalizedMsgText (Get-SnapOrig $bl[$bl.Count - 1]))
        $ledgerKey = ''
        $sk = $name.ToLowerInvariant()
        if ($ledMap.ContainsKey($sk)) { $ledgerKey = $ledMap[$sk] }
        if ($c.override) { $ledgerKey = $c.override }
        $r = Test-ShouldReply -ConvoLines $lines -LedgerKey $ledgerKey -NormLastBuyerHash $hLast
        Assert-Eq ("A10-reply-false[{0}]" -f $c.file) $r.Reply $false
        Assert-True ("A10-reason-not-buyer-after-me[{0}]" -f $c.file) ($r.Reason -ne 'BUYER_AFTER_ME')
        Assert-True ("A10-reason-is-expected-set[{0}]" -f $c.file) (@('LEDGER_HASH_MATCH', 'LEDGER_COUNT_MATCH', 'UNCERTAIN_FAILCLOSED') -contains $r.Reason)
    }

    # erico 的两条是本次事故**对外真的重复发出**的两条(11:42:18 / 11:45:02) —— 必须由 hash 命中判据拦下
    $p1 = Join-Path $dataDir 'msgs_20260927_114208.txt'
    $l1 = Get-SnapLines $p1
    $b1 = @($l1 | Where-Object { $_ -match '^\[BUYER\]' })
    $h1 = Get-StableHash (Get-NormalizedMsgText (Get-SnapOrig $b1[$b1.Count - 1]))
    Assert-Eq "A10-erico-reason-is-hash-match" (Test-ShouldReply -ConvoLines $l1 -LedgerKey $ledMap['erico rodrigues'] -NormLastBuyerHash $h1).Reason 'LEDGER_HASH_MATCH'
    $p2 = Join-Path $dataDir 'msgs_20260927_114235.txt'
    $l2 = Get-SnapLines $p2
    $b2 = @($l2 | Where-Object { $_ -match '^\[BUYER\]' })
    $h2 = Get-StableHash (Get-NormalizedMsgText (Get-SnapOrig $b2[$b2.Count - 1]))
    Assert-Eq "A10-riyad-reason-is-hash-match" (Test-ShouldReply -ConvoLines $l2 -LedgerKey $ledMap['riyad tantawi'] -NormLastBuyerHash $h2).Reason 'LEDGER_HASH_MATCH'
    Write-Output "  A10 现场回归: 4 个用例(含 erico x2 / Riyad / Ganesan 11:45:10) 全部 Reply=false"
}

# ---------------------------------------------------------------------------
# 6) §5.1-A8 静态检查：单出口
#    只剔除"整行注释"; 判定用**函数调用形态**的正则(函数名紧跟空格+'-' 或 '(' ),
#    这样 `function Test-DedupHit([string]...` 这种**定义行**不会被误判成调用。
#    不用字符串剥离: 本仓库含撇号缩写(can't / don't), 朴素引号正则会跨行吃掉代码(实测踩过)。
# ---------------------------------------------------------------------------
function Get-CodeLines([string]$path) {
    $out = New-Object System.Collections.ArrayList
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        $n++
        if ($line -match '^\s*#') { continue }                  # 整行注释
        [void]$out.Add([pscustomobject]@{ line = $n; code = $line })
    }
    return $out
}
# 调用形态: 函数名 + 空白 + ('-' 参数 | '(' 参数)
$CALL_RE = '\b(Test-NewBuyerMessage|Test-DedupHit)\s+(-|\()'

$prodFiles = @(Get-ChildItem -Path $scripts -Recurse -Include *.ps1 -File -ErrorAction SilentlyContinue)
$sendSites = @()
$legacyCalls = @()
foreach ($f in $prodFiles) {
    foreach ($cl in (Get-CodeLines $f.FullName)) {
        if ($cl.code -match '\bSend-OneTalkMessage\b') {
            $sendSites += [pscustomobject]@{ file = $f.FullName.Substring($root.Length + 1); line = $cl.line; code = $cl.code.Trim() }
        }
        if ($cl.code -match $CALL_RE) {
            $legacyCalls += [pscustomobject]@{ file = $f.FullName.Substring($root.Length + 1); line = $cl.line; code = $cl.code.Trim() }
        }
    }
}

# 允许的发送调用点: lib\send.ps1(定义处) / monitor.ps1(唯一生产调用点) / gonghai\gonghai_probe.ps1(公海独立子系统, 其自身 spec §6.5.2 要求复用)
$unexpected = @($sendSites | Where-Object {
        $_.file -notmatch 'scripts\\lib\\send\.ps1$' -and
        $_.file -notmatch 'scripts\\monitor\.ps1$' -and
        $_.file -notmatch 'scripts\\gonghai\\gonghai_probe\.ps1$'
    })
Assert-True "A8-no-unexpected-send-site" ($unexpected.Count -eq 0)
if ($unexpected.Count -gt 0) { $unexpected | ForEach-Object { Write-Output ("    unexpected: {0}:{1} {2}" -f $_.file, $_.line, $_.code) } }

$monSites = @($sendSites | Where-Object { $_.file -match 'scripts\\monitor\.ps1$' })
Assert-Eq "A8-monitor-single-send-site" $monSites.Count 1

# 该调用点必须位于 Test-ShouldReply 调用点之后（同一文件内的行号比较）
$monPath = Join-Path $scripts "monitor.ps1"
$shouldLine = 0; $sendLine = 0
foreach ($cl in (Get-CodeLines $monPath)) {
    if ($shouldLine -eq 0 -and $cl.code -match 'Test-ShouldReply\s+-ConvoLines') { $shouldLine = $cl.line }
    if ($sendLine -eq 0 -and $cl.code -match '\bSend-OneTalkMessage\b') { $sendLine = $cl.line }
}
Assert-True "A8-should-reply-line-found" ($shouldLine -gt 0)
Assert-True "A8-send-line-found" ($sendLine -gt 0)
Assert-True "A8-send-after-should-reply" ($sendLine -gt $shouldLine)

# nudge.ps1 不得再有面向买家的发送
$nudgeHits = @(Get-CodeLines (Join-Path $scripts 'nudge.ps1') | Where-Object { $_.code -match '\bSend-OneTalkMessage\b' })
Assert-Eq "A8-nudge-no-buyer-send" $nudgeHits.Count 0
# quote_remind.ps1 同样不得有
$qrHits = @(Get-CodeLines (Join-Path $scripts 'quote_remind.ps1') | Where-Object { $_.code -match '\bSend-OneTalkMessage\b' })
Assert-Eq "A8-quote-remind-no-buyer-send" $qrHits.Count 0

# 旧判据函数必须已不存在（Test-DedupHit 定义保留但不得再被调用 —— 上面的 $legacyCalls 已断言）
Assert-True "A8-Test-NewBuyerMessage-removed" ($null -eq (Get-Command Test-NewBuyerMessage -EA SilentlyContinue))
# Test-DedupHit 仍可调用(定义保留), 但生产代码里不得有调用点
Assert-True "A8-no-legacy-verdict-call" ($legacyCalls.Count -eq 0)
if ($legacyCalls.Count -gt 0) { $legacyCalls | ForEach-Object { Write-Output ("    legacy call: {0}:{1} {2}" -f $_.file, $_.line, $_.code) } }

# ---------------------------------------------------------------------------
# 6b) [阶段 D 补 2026-09-27] 生产脚本的"被调用函数必须存在"静态闭包检查。
#   为什么必须有这一条（实测教训）: 阶段 A 一次失败的回退编辑在 monitor.ps1 里留下
#     `Get-HumanInterjectionGate @(Get-HumanInterjectionProbeLines $item.preview)`,
#     而 `Get-HumanInterjectionProbeLines` **生产代码里根本不存在**（只在测试桩里有）。
#     A1 全量测试全绿 / A16 语法解析全 OK / A2/A9/A10 全绿 —— 没有一条能发现它:
#       · 测试只 dot-source 纯函数文件, 不执行 monitor.ps1 的函数体;
#       · 语法解析只保证语法对, 不保证"名字存在"。
#     阶段 D 真跑起来才炸: 第 2 轮 `Monitor error: The term '...' is not recognized`
#     ⇒ 会话永久卡在待回复列表 + 每 10 秒重试。
# ---------------------------------------------------------------------------
$staticCheck = Join-Path $root "tools\dedup_acceptance\static_call_closure.ps1"
if (Test-Path $staticCheck) {
    $scOut = & powershell -ExecutionPolicy Bypass -NoProfile -File $staticCheck 2>&1
    $scCode = $LASTEXITCODE
    Assert-Eq "A8b-static-call-closure-passes" $scCode 0
    if ($scCode -ne 0) {
        Write-Output "    --- static_call_closure 输出 ---"
        $scOut | Select-Object -First 30 | ForEach-Object { Write-Output ("    " + $_) }
    }
    # 反向自检: 检查本身必须真的能抓到"未定义命令"（否则它只是个安慰剂）
    $probe = Join-Path $env:TEMP ("closure_probe_" + [guid]::NewGuid().ToString("N") + ".ps1")
    Set-Content -LiteralPath $probe -Value "function Test-Probe { Call-NoSuchFunction-At-All }`nTest-Probe" -Encoding UTF8
    $probeOut = & powershell -ExecutionPolicy Bypass -NoProfile -File $staticCheck -Files $probe 2>&1
    $probeCode = $LASTEXITCODE
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Assert-True "A8b-closure-check-catches-undefined" ($probeCode -ne 0)
} else {
    Assert-True "A8b-static-call-closure-script-exists" $false
}

# ---------------------------------------------------------------------------
# 7) §4.2 G1/G2/G3 门禁的静态存在性（运行态验收属阶段 D 的 A13-A15, 阶段 A 只做离线可断言部分）
# ---------------------------------------------------------------------------
$monRaw = [System.IO.File]::ReadAllText($monPath, [System.Text.Encoding]::UTF8)
Assert-True "G1-abort-page-down-log" ($monRaw -match 'ABORT-PAGE-DOWN reason=')
Assert-True "G1-round-skip-before-convo-loop" ($monRaw -match 'action=skip-round')
Assert-True "G1b-heal-escalate" ($monRaw -match 'PAGE-HEAL-ESCALATE')
Assert-True "G1b-fatal" ($monRaw -match 'ABORT-PAGE-DOWN-FATAL')
Assert-True "G2-round-halt" ($monRaw -match 'round-halt')
Assert-True "G2-abort-wrong-convo-consumed" ($monRaw -match "sendRes -match 'ABORT_WRONG_CONVO'")
Assert-True "G3-cold-start" ($monRaw -match 'COLD-START observe-only cycle=')
Assert-True "G4-rate-skip-min-gap" ($monRaw -match 'RATE-SKIP buyer=')
# G1 门禁必须在会话处理循环之前(行号比较)
$g1Line = 0; $loopLine = 0
foreach ($cl in (Get-CodeLines $monPath)) {
    if ($g1Line -eq 0 -and $cl.code -match 'ABORT-PAGE-DOWN reason=') { $g1Line = $cl.line }
    if ($loopLine -eq 0 -and $cl.code -match 'foreach \(\$item in \$snap\)') { $loopLine = $cl.line }
}
Assert-True "G1-before-convo-loop" ($g1Line -gt 0 -and $loopLine -gt 0 -and $g1Line -lt $loopLine)

# ---------------------------------------------------------------------------
Write-Output ""
Write-Output ("RESULT: pass={0} fail={1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"
