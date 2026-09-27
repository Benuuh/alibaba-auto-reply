# A9_red_baseline.ps1 -- [SPEC-单出口 2026-09-27] §5.2-A9 红灯复现（改动前代码 + spec 字面顺序判据）
#
# 用途: 把"本次事故为什么会误发"钉成可复跑的证据。
#   - 加载**改动前**的 reply_engine.ps1（从规划时刻备份包解出，见 -RedCodeDir），
#     证明现场那套判据的失败形态；
#   - 同时按 spec §4.1 表格的**字面顺序**(规则1→5)跑"唯一出口"原型，证明字面顺序与 A2/A10 不可同时成立。
#
# ⚠️ 本脚本**只读**: 不碰页面、不发送、不写账本、不修改任何部署根文件。
# ⚠️ 需要先备好改动前代码: 见 -RedCodeDir 参数说明。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -NoProfile -File tools\dedup_acceptance\A9_red_baseline.ps1 `
#       -RedCodeDir "$env:TEMP\dedup_stop_20260927\red_baseline_code"
param(
    [string]$RedCodeDir = "",
    [string]$DataDir = "",
    [string]$StateFile = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path (Split-Path $here -Parent) -Parent
. (Join-Path $root "scripts\config.ps1")
# 运行数据根从集中配置取, 不写死本机绝对路径(部署根路径属敏感模式, sanitize 钩子会阻断; 写死也换机即失效)
if (-not $DataDir) { $DataDir = [string](Get-SkillConfig).data_dir }
if (-not $DataDir) { $DataDir = Join-Path (Split-Path $root -Parent) "alibaba-auto-reply-runtime\data" }
if (-not $StateFile) { $StateFile = Join-Path $root "scripts\state.json" }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP "dedup_stop_20260927" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not $RedCodeDir -or -not (Test-Path (Join-Path $RedCodeDir "reply_engine.ps1"))) {
    Write-Output "A9-RED-SKIP: -RedCodeDir 未提供或不含 reply_engine.ps1"
    Write-Output "  复现方式: 从运行数据根 backups\alibaba-auto-reply_20260927_115212.zip 解出"
    Write-Output "  scripts\reply_engine.ps1(改动前代码) 到某目录, 再用 -RedCodeDir 指过去。"
    exit 2
}

. (Join-Path $RedCodeDir "reply_engine.ps1")
. (Join-Path $root "scripts\reply_engine.ps1")   # 之后的定义覆盖同名函数 ⇒ 本作用域用新代码
# 说明: 红基线需要的是**旧代码的两个函数**(Test-NewBuyerMessage), 它们在旧文件里独有;
#       新文件的 Test-ShouldReply 供"字面顺序原型"之外的对照使用。

function Test-ShouldReply-LiteralSpecOrder {
    param([string[]]$ConvoLines, [string]$LedgerKey, [string]$NormLastBuyerHash)
    $lines = @($ConvoLines)
    $bc = @($lines | Where-Object { $_ -match '^\[BUYER\]' }).Count
    $mc = @($lines | Where-Object { $_ -match '^\[ME\]' }).Count
    $last = if ($lines.Count -gt 0) { $lines[$lines.Count - 1] } else { '' }
    if ($mc -ge 1 -and $last -match '^\[BUYER\]') { return [pscustomobject]@{ Reply = $true; Reason = 'BUYER_AFTER_ME' } }
    if ($mc -eq 0) { return [pscustomobject]@{ Reply = $true; Reason = 'NO_SELLER_MSG' } }
    $seg = $null; $ledHash = ''
    if (-not [string]::IsNullOrWhiteSpace($LedgerKey)) {
        $p = $LedgerKey -split '\|', 2
        $ledHash = [string]$p[0]
        if ($p.Count -gt 1) { $s = ([string]$p[1]).Trim(); if ($s -match '^\d{1,9}$') { $seg = [int]$s } }
    }
    if ($null -ne $seg -and $seg -eq $bc) { return [pscustomobject]@{ Reply = $false; Reason = 'LEDGER_COUNT_MATCH' } }
    if ($ledHash -ne '' -and $ledHash -eq $NormLastBuyerHash) { return [pscustomobject]@{ Reply = $false; Reason = 'LEDGER_HASH_MATCH' } }
    return [pscustomobject]@{ Reply = $false; Reason = 'UNCERTAIN_FAILCLOSED' }
}

function Get-ConvoLines([string]$path) {
    $all = @(Get-Content -Path $path -Encoding UTF8)
    $body = if ($all.Count -gt 0 -and $all[0] -match '^# BUYER:') { $all[1..($all.Count - 1)] } else { $all }
    return @($body | Where-Object { $_ -notmatch '在Alibaba|平台聊天和交易|由阿里翻译提供|翻译提示|已读$|反馈$|举报$|自动接待' })
}
function Get-BuyerName([string]$path) {
    $first = Get-Content -Path $path -Encoding UTF8 -TotalCount 1
    if ($first -match '^# BUYER:\s*(.+)$') { return $Matches[1].Trim() }
    return ''
}
function Get-OrigText([string]$line) {
    $ot = $line
    $m = [regex]::Match($line, '@@OT:([A-Za-z0-9+/=]+)')
    if ($m.Success) { try { $ot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value)) } catch { $ot = $line } }
    return ($ot -replace '^\[BUYER\]\s*', '' -replace '@@TS:.*$', '' -replace '@@OT:[A-Za-z0-9+/=]+', '').Trim()
}

$led = (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).replied
$ledMap = @{}
foreach ($p in $led.PSObject.Properties) { $ledMap[$p.Name] = [string]$p.Value }

# spec §5.2-A9 指定的 5 份事故快照, 与 monitor.log 的 REPLIED 行一一对应
$snapFiles = @(
    @{ f = 'msgs_20260927_114208.txt'; log = '11:42:08 DEDUP-JUDGE erico savedCount=- nowCount=5 isNew=True -> 11:42:18 REPLIED #1' },
    @{ f = 'msgs_20260927_114219.txt'; log = '11:42:19 DEDUP-JUDGE Ganesan savedCount=- nowCount=8 isNew=True -> 11:42:28 REPLIED' },
    @{ f = 'msgs_20260927_114235.txt'; log = '11:42:35 DEDUP-JUDGE Riyad savedCount=- nowCount=5 isNew=True -> 11:42:44 REPLIED #1' },
    @{ f = 'msgs_20260927_114453.txt'; log = '11:44:53 DEDUP-JUDGE erico savedCount=5 nowCount=7 isNew=True -> 11:45:02 REPLIED #2' },
    @{ f = 'msgs_20260927_114510.txt'; log = '11:45:10 DEDUP-JUDGE Ganesan savedCount=- nowCount=8 isNew=True -> 11:45:19 REPLIED #2' }
)

Write-Output "=== A9 红灯: 改动前代码 + spec 字面顺序判据, 跑本次事故现场 5 份快照 ==="
Write-Output ""
$rows = New-Object System.Collections.ArrayList
foreach ($sf in $snapFiles) {
    $path = Join-Path $DataDir $sf.f
    if (-not (Test-Path $path)) { Write-Output "MISSING $path"; continue }
    $name = Get-BuyerName $path
    $lines = Get-ConvoLines $path
    $bl = @($lines | Where-Object { $_ -match '^\[BUYER\]' })
    $hLast = ''
    if ($bl.Count -gt 0) { $hLast = Get-StableHash (Get-NormalizedMsgText (Get-OrigText $bl[$bl.Count - 1])) }
    $sk = $name.ToLowerInvariant()
    $ledgerKey = ''
    if ($ledMap.ContainsKey($sk)) { $ledgerKey = $ledMap[$sk] }
    $ledHash = ''
    if ($ledgerKey -ne '') { $ledHash = ($ledgerKey -split '\|', 2)[0] }

    # 改动前判据的实际形态: monitor.log 记录 savedCount=- ⇒ 账本第二段不可解析(旧格式 13 位 ts)。
    $preLedgerKey = $ledHash + '|1790000000000'
    $oldVerdict = Test-NewBuyerMessage -BuyerLines $bl -SavedKey $preLedgerKey -CurrentHash $hLast
    $literal = Test-ShouldReply-LiteralSpecOrder -ConvoLines $lines -LedgerKey $ledgerKey -NormLastBuyerHash $hLast

    [void]$rows.Add([pscustomobject]@{
            snapshot              = $sf.f
            buyer                 = $name
            buyerLines            = $bl.Count
            lastLineIsBuyer       = [bool]($lines[$lines.Count - 1] -match '^\[BUYER\]')
            ledgerKey             = $ledgerKey
            ledgerHashEqLastBuyer = [bool]($ledHash -ne '' -and $ledHash -eq $hLast)
            oldFallbackVerdict    = $oldVerdict
            literalOrderVerdict   = $literal.Reply
            literalOrderReason    = $literal.Reason
            incidentLog           = $sf.log
        })
}
$rows | Format-Table snapshot, buyer, buyerLines, lastLineIsBuyer, ledgerHashEqLastBuyer, oldFallbackVerdict, literalOrderVerdict, literalOrderReason -AutoSize | Out-String -Width 250 | Write-Output
Write-Output "对应事故日志(逐条):"
foreach ($r in $rows) { Write-Output ("  {0} | {1}" -f $r.snapshot, $r.incidentLog) }

$redHits = @{}
foreach ($r in $rows) {
    if ($r.oldFallbackVerdict -eq $true -or $r.literalOrderVerdict -eq $true) { $redHits[$r.buyer] = $true }
}
Write-Output ""
Write-Output "=== A9 红灯结论（spec 期望: erico/Ganesan/Riyad 至少各判出 1 次『应回』）==="
$allRed = $true
foreach ($who in @('erico Rodrigues', 'Ganesan Krishnasamy', 'Riyad Tantawi')) {
    $hit = $redHits.ContainsKey($who)
    if (-not $hit) { $allRed = $false }
    Write-Output ("  {0,-24} 至少 1 次判'应回' = {1}" -f $who, $hit)
}
$contra = @($rows | Where-Object { $_.literalOrderVerdict -eq $true -and $_.ledgerHashEqLastBuyer })
Write-Output ""
Write-Output ("字面顺序下『应回』但账本 hash == 最后买家 hash 的自相矛盾条数 = {0}" -f $contra.Count)
$contra | Format-Table snapshot, buyer, ledgerKey -AutoSize | Out-String -Width 200 | Write-Output

$rows | Export-Csv -Path (Join-Path $OutDir "A9_red_baseline.csv") -NoTypeInformation -Encoding UTF8
Write-Output ("evidence: {0}" -f (Join-Path $OutDir "A9_red_baseline.csv"))
if ($allRed) { Write-Output "A9-RED-OK: 三个买家全部复现出'应回'误判"; exit 0 }
Write-Output "A9-RED-FAIL: 未能复现全部三个买家的误判"; exit 1
