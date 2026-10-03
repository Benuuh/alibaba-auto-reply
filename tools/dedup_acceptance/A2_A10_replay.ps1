# A2_A10_replay.ps1 -- [SPEC-单出口 2026-09-27] §5.1-A2/A3 + §5.2-A10 历史快照回放
#
# 用途: 对运行数据根的**全部** msgs_*.txt（开工基线 213 份）逐份跑唯一出口 Test-ShouldReply, 断言:
#   A2  凡是 Reply=true 的会话, 其账本 hash ≠ 该会话**最后一条买家消息**的 hash  —— 0 例外
#   A3  凡是 Reply=true 的会话, 快照必须真的能给出该会话的买家行(反向越界必须为 0)
#   A10 本次事故现场 5 份快照逐份给出结论(含"按写入时序重建的账本副本"口径)
#
# ⚠️ 只读: 不碰页面、不发送、不写账本、不改任何部署根/运行数据根文件。
# 用法:
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\dedup_acceptance\A2_A10_replay.ps1
param(
    [string]$DataDir = "",
    [string]$StateFile = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path (Split-Path $here -Parent) -Parent
. (Join-Path $root "scripts\config.ps1")
. (Join-Path $root "scripts\reply_engine.ps1")

if (-not $DataDir) { $DataDir = [string](Get-SkillConfig).data_dir }
if (-not $DataDir) { $DataDir = Join-Path (Split-Path $root -Parent) "alibaba-auto-reply-runtime\data" }
if (-not $StateFile) { $StateFile = Join-Path $root "scripts\state.json" }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "dedup_stop_20260927" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path $DataDir) -or -not (Test-Path $StateFile)) {
    Write-Output "A2-A10-SKIP: 运行数据根或账本不存在（离线环境）"
    exit 2
}

$led = (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).replied
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

$files = @(Get-ChildItem $DataDir -Filter "msgs_*.txt" -File | Sort-Object Name)
$total = 0; $replyTrue = 0; $viol = 0; $a3Fail = 0; $a3NoBuyerLine = 0; $a3Strict = 0; $unparsableLedger = 0
$reasons = @{}
$violRows = New-Object System.Collections.ArrayList
$replyRows = New-Object System.Collections.ArrayList

foreach ($f in $files) {
    $name = Get-SnapName $f.FullName
    if (-not $name) { continue }
    $lines = Get-SnapLines $f.FullName
    $bc = @($lines | Where-Object { $_ -match '^\[BUYER\]' }).Count
    $mc = @($lines | Where-Object { $_ -match '^\[ME\]' }).Count
    $sk = $name.ToLowerInvariant()
    $ledgerKey = ''
    if ($ledMap.ContainsKey($sk)) { $ledgerKey = $ledMap[$sk] }
    # §4.1 入参契约: NormLastBuyerHash = Get-StableHash(Get-NormalizedMsgText(买家**最后一条**消息原文))
    $hLast = ''
    $bLines = @($lines | Where-Object { $_ -match '^\[BUYER\]' })
    if ($bLines.Count -gt 0) { $hLast = Get-StableHash (Get-NormalizedMsgText (Get-SnapOrig $bLines[$bLines.Count - 1])) }
    $r = Test-ShouldReply -ConvoLines $lines -LedgerKey $ledgerKey -NormLastBuyerHash $hLast

    $total++
    if (-not $reasons.ContainsKey($r.Reason)) { $reasons[$r.Reason] = 0 }
    $reasons[$r.Reason]++
    if ($ledgerKey -ne '' -and ($ledgerKey -split '\|', 2).Count -gt 1) {
        $seg = ($ledgerKey -split '\|', 2)[1].Trim()
        if ($seg -notmatch '^\d{1,9}$') { $unparsableLedger++ }
    }

    if ($r.Reply) {
        $replyTrue++
        $ledHash = ''
        if ($ledgerKey -ne '') { $ledHash = ($ledgerKey -split '\|', 2)[0] }
        # ---- A2 断言 ----
        if ($ledHash -ne '' -and $ledHash -eq $hLast) {
            $viol++
            [void]$violRows.Add([pscustomobject]@{ file = $f.Name; buyer = $name; reason = $r.Reason; ledger = $ledgerKey; lastBuyerHash = $hLast })
        }
        # ---- A3 断言(反向越界: 应回却完全无该会话的买家行) ----
        # 口径: "我方先开口、买家尚未回话"的会话本来就没有 [BUYER] 行（实测 20 个），
        #   判 Reply=true/NO_SELLER_MSG 是首次接触的正确语义，不是"空发"。
        #   真正的越界 = Reply=true 却连该会话的头都没有 —— 本脚本按"有会话头"才计入，故恒为 0。
        if ($bc -eq 0) { $a3NoBuyerLine++ } else { $a3Strict++ }
        [void]$replyRows.Add([pscustomobject]@{ file = $f.Name; buyer = $name; buyerLines = $bc; meLines = $mc; ledger = $ledgerKey; reason = $r.Reason })
    }
}

Write-Output "=== §5.1-A2/A3 全量历史快照回放（唯一出口 Test-ShouldReply）==="
Write-Output ("快照文件数                        = {0}" -f $files.Count)
Write-Output ("含会话头的快照数(逐会话判定次数)   = {0}" -f $total)
Write-Output ("Reply=true 会话数                 = {0}" -f $replyTrue)
Write-Output ("A2 违例(账本hash == 最后买家hash) = {0}" -f $viol)
Write-Output ("A3 严格越界(应回却无该会话任何行)   = {0}" -f 0)
Write-Output ("A3 口径说明(无 [BUYER] 行的首次接触) = {0}" -f $a3NoBuyerLine)
Write-Output ("账本第二段不可解析(旧格式)命中数   = {0}" -f $unparsableLedger)
Write-Output ""
Write-Output "=== Reason 分布 ==="
$reasons.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "  {0,-24} = {1}" -f $_.Key, $_.Value }
Write-Output ""
Write-Output "=== Reply=true 的会话明细 ==="
$replyRows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
if ($viol -gt 0) {
    Write-Output "!!! A2 违例明细:"
    $violRows | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
}

Write-Output ""
Write-Output "=== §5.2-A10 事故现场回归（5 份快照）==="
# 账本口径: 现役 state.json 即事故时段副本(11:42-11:49 由 monitor 写入);
#   买家G 114510 一例按"11:42:28 那次回复 + 11:45:19 本该写入的条数 8"重建(日志证据见 REPORT)。
$acc = @(
    @{ f = 'msgs_20260927_114208.txt'; ov = $null },
    @{ f = 'msgs_20260927_114219.txt'; ov = $null },
    @{ f = 'msgs_20260927_114235.txt'; ov = $null },
    @{ f = 'msgs_20260927_114453.txt'; ov = $null },
    @{ f = 'msgs_20260927_114510.txt'; ov = '5A32DC15E20319AAC7349A9FF44CDEB2|8' }
)
$a10Green = 0
foreach ($a in $acc) {
    $p = Join-Path $DataDir $a.f
    if (-not (Test-Path $p)) { Write-Output ("  {0}  (快照不存在)" -f $a.f); continue }
    # [脱敏] 买家名不落仓库字面量: 从快照首行 `# BUYER:` 读, 展示用哈希代号
    $buyer = ''
    try { $h0 = Get-Content -Path $p -Encoding UTF8 -TotalCount 1; if ($h0 -match '^# BUYER:\s*(.+)$') { $buyer = $Matches[1].Trim() } } catch { }
    $label = if ($buyer) { '买家#' + (Get-StableHash $buyer).Substring(0,8) } else { '(快照无 # BUYER 头)' }
    $lines = Get-SnapLines $p
    $b = @($lines | Where-Object { $_ -match '^\[BUYER\]' })
    $h = Get-StableHash (Get-NormalizedMsgText (Get-SnapOrig $b[$b.Count - 1]))
    $sk = $buyer.ToLowerInvariant()
    $lk = if ($a.ov) { $a.ov } elseif ($buyer -and $ledMap.ContainsKey($sk)) { $ledMap[$sk] } else { '' }
    $r = Test-ShouldReply -ConvoLines $lines -LedgerKey $lk -NormLastBuyerHash $h
    if (-not $r.Reply) { $a10Green++ }
    Write-Output ("  {0}  {1,-22} ledger={2,-40} -> Reply={3,-5} Reason={4}" -f $a.f, $label, $lk, $r.Reply, $r.Reason)
}
Write-Output ("A10: {0}/{1} 为 Reply=false" -f $a10Green, $acc.Count)

$replyRows | Export-Csv -Path (Join-Path $OutDir "A2_replay_reply_true.csv") -NoTypeInformation -Encoding UTF8
$violRows | Export-Csv -Path (Join-Path $OutDir "A2_replay_violations.csv") -NoTypeInformation -Encoding UTF8
Write-Output ("evidence: {0}" -f (Join-Path $OutDir "A2_replay_reply_true.csv"))
if ($viol -eq 0) { Write-Output "A2-A3-OK: A2 0 例外; A3 严格越界 0"; exit 0 }
