# tests\second_fix_summary.tests.ps1 - F7：摘要直接显示统一报价结果（P2，isolated 层）
#
# 分层：isolated。**实际运行** scripts\summarize.ps1 子进程（不是把几行逻辑抄进测试）：
#   本文件每个进程使用独有的临时运行根（Initialize-AarIsolation 写 .aar-isolation.json 标记），
#   显式传 -LogFile / -OutDir / -StateFile，快照目录（Get-SkillPath 'data'）也落在该临时根内，
#   随后读取**真实生成**的 .md 报告，把它的结论文字、必要缺口、辅助缺口、澄清与 RuleVersion
#   与同一份统一结果（Get-GoodsDataStatus / Get-QuoteReadinessForConversationText）逐项对齐。
#   只使用虚构买家；没有任何发送、通知、浏览器或模型出口（隔离模式下真实发送适配器直接抛错）。
#
# 覆盖（spec §8.1 / §8.2）：
#   S1 货名 cable、总重 200 kg、每箱 50x40x30 cm、Amazon FTW1、**缺箱数**：
#      统一 ready=false / missingFields=[carton_count] ⇒ 报告"不可进入报价准备"并列出缺外包装件数，
#      不再出现旧判据的"齐全，可报价"。
#   S2 四项齐全（件数/重量/尺寸/目的地）、无货名/无图/无联系人：
#      统一 ready=true ⇒ 报告"可进入人工报价准备"，辅助缺口按 OptionalMissingFields 另列，不改判。
#   S3 件数冲突 / 重量范围未明：报告给出统一模型**实际产生**的澄清文字，且不写"齐全"。
#   S4 事实模型故障注入（只注入故障边界：覆盖 Get-QuoteReadinessForSidecarText 使其抛错，
#      不 stub 任何被测算术）⇒ 报告"资料判定失败，需核对"，不因缺口数组为空而写齐全。
#   S5 Amazon 目的仓代码满足目的地 + 明确更正（买家改口）+ 合法完整资料：
#      摘要结论与统一 ready、与 Get-QuoteReadyBuyers 报价候选一致。
#   S6 报告里的 RuleVersion 与同一份统一结果一致；表格列数稳定（转义未破坏结构）。
$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path $here -Parent
$scripts = Join-Path $repo 'scripts'
. (Join-Path $scripts 'config.ps1')
. (Join-Path $scripts 'lib\paths.ps1')

$script:pass = 0
$script:fail = 0
$script:fails = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++; [void]$script:fails.Add($name); Write-Output ('  FAIL: ' + $name + ' ' + $detail) }
}
function Eq([string]$name, $a, $b) { Check $name ($a -eq $b) ('got=[' + $a + '] want=[' + $b + ']') }

Write-Output '== second_fix summary tests (actual summarize.ps1 subprocess, isolated runtime root) =='

$isoRoot = Join-Path $env:TEMP ('aar-secondfix-summary-' + [guid]::NewGuid().ToString('N'))
[void](Initialize-AarIsolation -Root $isoRoot)
$env:AAR_RUNTIME_ROOT = $isoRoot
Check 'S0-runtime-is-isolated' (Test-AarIsolatedRuntime) 'isolation marker missing'
Write-Output ('ISOLATED-ROOT: ' + $isoRoot)

. (Join-Path $scripts 'lib\goods.ps1')
. (Join-Path $scripts 'lib\quote.ps1')

$LF = [string][char]10
$dataDir = Join-Path $isoRoot 'data'
$outDir = Join-Path $isoRoot 'reports'
$enc = New-Object System.Text.UTF8Encoding($true)
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
# 报价候选（统一判据的另一个消费方）会读人工接管名单：隔离运行根里显式放一份**空**名单，
#   这样读到的事实就是"本临时根没有人工接管买家"，测试输出里也不会出现"名单不存在"的告警噪声。
[System.IO.File]::WriteAllText((Join-Path $dataDir 'manual_override.json'), '[]', (New-Object System.Text.UTF8Encoding($false)))

# ---- 夹具：虚构买家 + 虚构快照（写入隔离运行根的 data 目录） ----
function Save-Snapshot([string]$Buyer, [string]$File, [string[]]$Msgs) {
    $lines = @()
    $ts = 1791000000000L
    foreach ($m in $Msgs) { $lines += ('[BUYER] ' + $m + ' @@MT:' + $ts); $ts += 1000 }
    $path = Join-Path $dataDir $File
    [System.IO.File]::WriteAllText($path, ('# BUYER: ' + $Buyer + $LF + ($lines -join $LF)), $enc)
}
function Save-Log([string]$Path, [string[]]$Buyers) {
    $out = @()
    $t = 0
    foreach ($b in $Buyers) {
        $stamp = '2026-10-05 12:00:' + ('{0:d2}' -f $t)
        $out += ($stamp + ' | REPLIED to ' + $b + ': SENT_OK')
        $out += ($stamp + ' | Reply text: Thanks for the details.')
        $t++
    }
    [System.IO.File]::WriteAllText($Path, ($out -join $LF), $enc)
}
# 实际 summarize 入口：独立 PS 5.1 子进程 + 显式三路径（运行根经 AAR_RUNTIME_ROOT 继承）。
function Invoke-SummarizeEntry([string]$LogFile, [string]$Out, [string]$State) {
    $res = @(& powershell -ExecutionPolicy Bypass -NoProfile -File (Join-Path $scripts 'summarize.ps1') -LogFile $LogFile -OutDir $Out -StateFile $State 2>&1)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $res }
}
function Get-SingleReport([string]$Out) {
    $md = @(Get-ChildItem -LiteralPath $Out -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($md.Count -ne 1) { throw ('expected exactly one generated report in ' + $Out + ', got ' + $md.Count) }
    return $md[0].FullName
}
function Read-Report([string]$Path) { return @(Get-Content -LiteralPath $Path -Encoding UTF8) }
# Markdown 表格行 -> 单元格（单元格内的竖线已被转义为 \|，拆分时必须跳过它）。
function Get-RowCells([string]$Row) {
    $t = [string]$Row
    if ($t.StartsWith('|')) { $t = $t.Substring(1) }
    if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
    return @([regex]::Split($t, '(?<!\\)\|') | ForEach-Object { $_.Trim() })
}
function Get-BuyerRow([string[]]$Lines, [string]$Buyer) {
    $rows = @($Lines | Where-Object { $_ -match ('^\| ' + [regex]::Escape($Buyer) + ' \|') })
    if ($rows.Count -ne 1) { throw ('expected exactly one readiness row for ' + $Buyer + ', got ' + $rows.Count) }
    return [string]$rows[0]
}
# 统一模型的字段键 -> 报表人话（与 summarize.ps1 的展示映射一致；仅用于交叉核对，不参与生产判据）。
function Get-ExpectedGapLabel([string]$Key) {
    switch ([string]$Key) {
        'carton_count'       { return '外包装件数' }
        'count'              { return '数量（范围未明）' }
        'unit_weight'        { return '包装重量（单件或总重）' }
        'total_weight'       { return '总重量' }
        'weight'             { return '重量（范围未明）' }
        'unit_dimensions'    { return '包装尺寸（单件或整批）' }
        'lot_dimensions'     { return '整批尺寸' }
        'dimensions'         { return '尺寸（范围未明）' }
        'delivery_address'   { return '可用报价目的地' }
        'goods_name'         { return '货物名称' }
        'reference_images'   { return '参考图片' }
        'supplier_address'   { return '供应商地址' }
        'supplier_contact'   { return '供应商联系方式' }
        'recipient_name'     { return '收货人名称' }
        'recipient_contact'  { return '收货人联系方式' }
        'unassigned_contact' { return '联系方式（角色未明）' }
        default              { return [string]$Key }
    }
}
# 缺口单元格必须逐项列出统一结果里的字段（'—' 仅当统一结果本身为空）。
function Test-CellCoversFields([string]$Cell, $Fields) {
    $list = @($Fields)
    if ($list.Count -eq 0) { return ($Cell -eq '—') }
    foreach ($f in $list) {
        if (-not ($Cell -match [regex]::Escape((Get-ExpectedGapLabel ([string]$f))))) { return $false }
    }
    return $true
}
function Get-StatusCellReadyClaim([string]$StatusCell) {
    return [bool](($StatusCell -match '可进入人工报价准备') -and -not ($StatusCell -match '不可进入报价准备') -and -not ($StatusCell -match '资料判定失败'))
}

$cases = @(
    [pscustomobject]@{ Buyer = 'Virtual Buyer F1'; File = 'msgs_f1_0001.txt'; Msgs = @('Cargo name: cable. Total gross weight 200 kg; each carton 50x40x30 cm; DDP to Amazon FTW1') }
    [pscustomobject]@{ Buyer = 'Virtual Buyer F2'; File = 'msgs_f2_0001.txt'; Msgs = @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1') }
    [pscustomobject]@{ Buyer = 'Virtual Buyer F3'; File = 'msgs_f3_0001.txt'; Msgs = @('20 cartons total', '24 cartons total') }
    [pscustomobject]@{ Buyer = 'Virtual Buyer F4'; File = 'msgs_f4_0001.txt'; Msgs = @('The weight is 20 kg, DDP to Amazon FTW1, dimensions 50x40x30 cm, 10 cartons') }
    [pscustomobject]@{ Buyer = 'Virtual Buyer F5'; File = 'msgs_f5_0001.txt'; Msgs = @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, Amazon FTW1', 'Change to Amazon TEST2') }
    [pscustomobject]@{ Buyer = 'Virtual Buyer F6'; File = 'msgs_f6_0001.txt'; Msgs = @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1', 'Sorry, correction: 24 cartons') }
)
foreach ($c in $cases) { Save-Snapshot $c.Buyer $c.File $c.Msgs }
$logFile = Join-Path $isoRoot 'monitor_virtual.log'
Save-Log $logFile @($cases | ForEach-Object { $_.Buyer })
$stateFile = Join-Path $isoRoot 'summary_last.json'

try {
    # ==========================================================================================
    # S1/S2/S3/S5/S6：一次真实运行覆盖 6 个虚构买家（每行一个买家），随后逐行对齐统一结果。
    # ==========================================================================================
    $runA = Invoke-SummarizeEntry $logFile $outDir $stateFile
    Eq 'S1-summarize-file-mode-exit' $runA.ExitCode 0
    Check 'S1-summarize-reports-written-file' ([bool](($runA.Output -join ' ') -match 'summary written:')) ($runA.Output -join ' | ')
    $mdA = Get-SingleReport $outDir
    $linesA = Read-Report $mdA
    Check 'S5-report-keeps-all-buyers' (@($linesA | Where-Object { $_ -match '^\| Virtual Buyer F\d \|' }).Count -eq 6) 'one readiness row per virtual buyer'

    # ---- S6：RuleVersion 与同一份统一结果一致；旧判据文字不再出现；表格结构未被破坏 ----
    $unified = @{}
    foreach ($c in $cases) { $unified[$c.Buyer] = Get-GoodsDataStatus $c.Buyer $dataDir }
    $ruleVersions = @(@($cases | ForEach-Object { [string]$unified[$_.Buyer].ruleVersion }) | Where-Object { $_ } | Select-Object -Unique)
    Eq 'S6-unified-rule-version-is-single' $ruleVersions.Count 1
    Check 'S6-report-declares-unified-rule-version' ([bool](($linesA -join $LF) -match ('规则版本（统一事实模型 RuleVersion）: ' + [regex]::Escape([string]$ruleVersions[0])))) ('rule=' + $ruleVersions[0])
    Check 'S6-report-has-no-legacy-ready-claim' (-not (($linesA -join $LF) -match '齐全，可报价')) 'the old self-composed verdict must be gone'
    foreach ($row in @($linesA | Where-Object { $_ -match '^\| Virtual Buyer ' })) {
        $cells = Get-RowCells $row
        Check ('S6-row-is-well-formed-table-row [' + $cells[0] + ']') (([regex]::Matches($row, '(?<!\\)\|').Count -eq 12) -and ($cells.Count -eq 11)) ('row=' + $row)
    }

    # ---- 逐买家：报表结论/缺口/澄清 = 同一份统一结果 ----
    foreach ($c in $cases) {
        $b = $c.Buyer
        $st = $unified[$b]
        $row = Get-BuyerRow $linesA $b
        $cells = Get-RowCells $row
        $claim = Get-StatusCellReadyClaim $cells[10]
        Check ('SC-ready-matches-unified [' + $b + ']') ($claim -eq [bool]$st.ready) ('unifiedReady=' + [bool]$st.ready + ' status=' + $cells[10])
        Check ('SC-necessary-gaps-match-unified [' + $b + ']') (Test-CellCoversFields $cells[8] @($st.missingFields)) ('cell=[' + $cells[8] + '] unified=[' + (@($st.missingFields) -join ',') + ']')
        Check ('SC-auxiliary-gaps-match-unified [' + $b + ']') (Test-CellCoversFields $cells[9] @($st.optionalMissingFields)) ('cell=[' + $cells[9] + '] unified=[' + (@($st.optionalMissingFields) -join ',') + ']')
        $clar = @($st.clarifications)
        $clarOk = $true
        foreach ($one in $clar) { if (-not ($row -match [regex]::Escape([string]$one))) { $clarOk = $false } }
        Check ('SC-clarifications-match-unified [' + $b + ']') $clarOk ('unified=[' + ($clar -join ' ;; ') + '] row=' + $cells[10])
        Check ('SC-carton-cell-matches-unified [' + $b + ']') (($cells[2] -eq '✅') -eq (($st.missingFields -notcontains 'carton_count') -and ($st.missingFields -notcontains 'count'))) ('cell=' + $cells[2])
    }

    # ---- S1：缺箱数 => 不可进入报价准备，并列出缺外包装件数 ----
    $b1 = 'Virtual Buyer F1'
    Check 'S1-unified-not-ready' (-not [bool]$unified[$b1].ready) 'fixture must be not-ready under the one fact model'
    Check 'S1-unified-missing-is-carton-count' (@($unified[$b1].missingFields) -contains 'carton_count') ('missing=' + (@($unified[$b1].missingFields) -join ','))
    $row1 = Get-BuyerRow $linesA $b1
    $cells1 = Get-RowCells $row1
    Check 'S1-report-not-ready' ($cells1[10] -match '不可进入报价准备') ('status=' + $cells1[10])
    Check 'S1-report-names-missing-carton-count' ($cells1[8] -match '外包装件数') ('necessary=[' + $cells1[8] + ']')
    Check 'S1-report-status-names-carton-count' ($cells1[10] -match '缺: 外包装件数') ('status=' + $cells1[10])
    Check 'S1-report-no-ready-claim' (-not ($row1 -match '可进入人工报价准备')) ('row=' + $row1)
    Check 'S1-report-no-complete-claim' (-not ($row1 -match '齐全')) ('row=' + $row1)
    Check 'S1-report-keeps-goods-name-and-destination' (($cells1[1] -match 'cable') -and ($cells1[5] -eq 'Amazon FTW1')) ('goods=[' + $cells1[1] + '] dest=[' + $cells1[5] + ']')

    # ---- S2：四项齐全、无货名/图片/联系人 => 可进入人工报价准备，辅助缺口另列 ----
    $b2 = 'Virtual Buyer F2'
    Check 'S2-unified-ready' ([bool]$unified[$b2].ready) 'fixture must be ready under the one fact model'
    Check 'S2-unified-no-necessary-gap' (@($unified[$b2].missingFields).Count -eq 0) ('missing=' + (@($unified[$b2].missingFields) -join ','))
    foreach ($k in @('goods_name', 'reference_images', 'supplier_contact', 'recipient_name', 'recipient_contact')) {
        Check ('S2-unified-aux-gap [' + $k + ']') (@($unified[$b2].optionalMissingFields) -contains $k) ('optional=' + (@($unified[$b2].optionalMissingFields) -join ','))
    }
    $cells2 = Get-RowCells (Get-BuyerRow $linesA $b2)
    Check 'S2-report-ready' ($cells2[10] -match '可进入人工报价准备') ('status=' + $cells2[10])
    Check 'S2-report-not-blocked' (-not ($cells2[10] -match '不可进入报价准备')) ('status=' + $cells2[10])
    Check 'S2-report-necessary-gap-cell-empty' ($cells2[8] -eq '—') ('necessary=[' + $cells2[8] + ']')
    Check 'S2-report-aux-gaps-separate-column' (($cells2[9] -match '货物名称') -and ($cells2[9] -match '参考图片') -and ($cells2[9] -match '收货人联系方式')) ('aux=[' + $cells2[9] + ']')
    Check 'S2-report-aux-does-not-change-verdict' ($cells2[10] -match '不阻挡报价准备') ('status=' + $cells2[10])
    Check 'S2-report-keeps-destination' ($cells2[5] -eq 'Amazon FTW1') ('dest=[' + $cells2[5] + ']')

    # ---- S3a：件数冲突 => 报告给出统一模型实际产生的澄清 ----
    $b3 = 'Virtual Buyer F3'
    Check 'S3a-unified-not-ready' (-not [bool]$unified[$b3].ready) 'conflicting carton counts must not be ready'
    Check 'S3a-unified-has-clarification' (@($unified[$b3].clarifications).Count -ge 1) ('clar=[' + (@($unified[$b3].clarifications) -join ' ;; ') + ']')
    $cells3 = Get-RowCells (Get-BuyerRow $linesA $b3)
    foreach ($one in @($unified[$b3].clarifications)) { Check ('S3a-report-shows-real-clarification [' + $one + ']') ($cells3[10] -match [regex]::Escape([string]$one)) ('status=' + $cells3[10]) }
    Check 'S3a-report-not-ready' ($cells3[10] -match '不可进入报价准备') ('status=' + $cells3[10])
    Check 'S3a-report-no-complete-claim' (-not ($cells3[10] -match '齐全')) ('status=' + $cells3[10])
    Check 'S3a-report-names-missing-carton-count' ($cells3[8] -match '外包装件数') ('necessary=[' + $cells3[8] + ']')

    # ---- S3b：重量范围未明（未确认）=> 同样给出实际澄清 ----
    $b4 = 'Virtual Buyer F4'
    Check 'S3b-unified-not-ready' (-not [bool]$unified[$b4].ready) 'unclear weight scope must not be ready'
    Check 'S3b-unified-has-clarification' (@($unified[$b4].clarifications).Count -ge 1) ('clar=[' + (@($unified[$b4].clarifications) -join ' ;; ') + ']')
    $cells4 = Get-RowCells (Get-BuyerRow $linesA $b4)
    foreach ($one in @($unified[$b4].clarifications)) { Check ('S3b-report-shows-real-clarification [' + $one + ']') ($cells4[10] -match [regex]::Escape([string]$one)) ('status=' + $cells4[10]) }
    Check 'S3b-report-not-ready' ($cells4[10] -match '不可进入报价准备') ('status=' + $cells4[10])
    Check 'S3b-report-no-complete-claim' (-not ($cells4[10] -match '齐全')) ('status=' + $cells4[10])

    # ---- S5：Amazon 目的仓代码满足目的地 + 明确更正 + 合法完整资料 ----
    $b5 = 'Virtual Buyer F5'
    Check 'S5-unified-ready-after-destination-correction' ([bool]$unified[$b5].ready) 'explicit correction keeps the conversation ready'
    $cells5 = Get-RowCells (Get-BuyerRow $linesA $b5)
    Check 'S5-report-destination-is-corrected-warehouse' ($cells5[5] -eq 'Amazon TEST2') ('dest=[' + $cells5[5] + ']')
    Check 'S5-report-ready' ($cells5[10] -match '可进入人工报价准备') ('status=' + $cells5[10])
    $b6 = 'Virtual Buyer F6'
    Check 'S5-unified-ready-after-count-correction' ([bool]$unified[$b6].ready) ('missing=' + (@($unified[$b6].missingFields) -join ','))
    Check 'S5-report-ready-after-count-correction' ((Get-RowCells (Get-BuyerRow $linesA $b6))[10] -match '可进入人工报价准备') 'corrected carton count keeps it ready'
    # 摘要结论必须与报价候选（同一判据的另一个消费方）一致。
    $readyBuyers = @(Get-QuoteReadyBuyers $dataDir | ForEach-Object { [string]$_.buyer })
    $reportedReady = @($cases | Where-Object { Get-StatusCellReadyClaim ((Get-RowCells (Get-BuyerRow $linesA $_.Buyer))[10]) } | ForEach-Object { $_.Buyer })
    Eq 'S5-report-ready-set-equals-quote-candidates' (@($reportedReady | Sort-Object) -join '|') (@($readyBuyers | Sort-Object) -join '|')
    Check 'S5-quote-candidates-are-exactly-f2-f5-f6' ((@($readyBuyers | Sort-Object) -join '|') -eq (@('Virtual Buyer F2', 'Virtual Buyer F5', 'Virtual Buyer F6') -join '|')) ('ready=' + ($readyBuyers -join ','))
    # 同一份统一结果的另一个入口（会话文本入口）必须给出相同的 Ready/MissingFields。
    $snapF5 = Get-Content -LiteralPath (Join-Path $dataDir 'msgs_f5_0001.txt') -Raw -Encoding UTF8
    $rw5 = Get-QuoteReadinessForConversationText -Text $snapF5 -ConvoName $b5
    Check 'S5-conversation-entry-agrees-on-ready' (([bool]$rw5.Ready) -eq ([bool]$unified[$b5].ready)) ('conv=' + [bool]$rw5.Ready + ' goods=' + [bool]$unified[$b5].ready)
    Eq 'S5-conversation-entry-agrees-on-missing-fields' (@($rw5.MissingFields) -join ',') (@($unified[$b5].missingFields) -join ',')
    Eq 'S5-conversation-entry-agrees-on-rule-version' ([string]$rw5.RuleVersion) ([string]$unified[$b5].ruleVersion)

    # ==========================================================================================
    # S4：事实模型故障注入（只注入故障边界）。不直接 -File 调用：在同一个会话里先加载
    #     config/paths/msg_norm，再覆盖 Get-QuoteReadinessForSidecarText 抛错，然后调用真实
    #     summarize.ps1（goods.ps1 只在 ConvertTo-MessageList 不存在时才重新加载 msg_norm.ps1，
    #     因此覆盖生效）。被测算术（summarize 的表格与结论、goods 的适配器）全部是生产实现。
    # ==========================================================================================
    $injBuyer = 'Virtual Buyer INJ'
    Save-Snapshot $injBuyer 'msgs_inj_0001.txt' @('18 cartons, 53 x 41 x 32 cm, 216 kg gross, DDP to Amazon FTW1')
    $injLog = Join-Path $isoRoot 'monitor_injected.log'
    Save-Log $injLog @($injBuyer)
    $injOut = Join-Path $isoRoot 'reports_injected'
    $injState = Join-Path $isoRoot 'summary_injected_state.json'
    $inner = @'
. '__REPO__\scripts\config.ps1'
. '__REPO__\scripts\lib\paths.ps1'
. '__REPO__\scripts\lib\msg_norm.ps1'
function Get-QuoteReadinessForSidecarText { throw 'injected facts-model failure' }
& '__REPO__\scripts\summarize.ps1' -LogFile '__LOG__' -OutDir '__OUT__' -StateFile '__STATE__'
'@
    $innerCmd = $inner.Replace('__REPO__', $repo).Replace('__LOG__', $injLog).Replace('__OUT__', $injOut).Replace('__STATE__', $injState)
    Check 'S4-injection-overrides-fact-model-entry' ([bool](Get-Command Get-QuoteReadinessForSidecarText -ErrorAction SilentlyContinue)) 'the production entry must exist before it is overridden'
    $runB = @(& powershell -ExecutionPolicy Bypass -NoProfile -Command $innerCmd 2>&1)
    Eq 'S4-summarize-command-mode-exit' $LASTEXITCODE 0
    Check 'S4-summarize-reports-written' ([bool](($runB -join ' ') -match 'summary written:')) ($runB -join ' | ')
    $mdB = Get-SingleReport $injOut
    $linesB = Read-Report $mdB
    $rowInj = Get-BuyerRow $linesB $injBuyer
    $cellsInj = Get-RowCells $rowInj
    Check 'S4-report-says-judgement-failed' ($cellsInj[10] -match '资料判定失败，需核对') ('status=' + $cellsInj[10])
    Check 'S4-report-exposes-unavailable-fact-model' ($cellsInj[10] -match 'one-fact-model-unavailable') ('status=' + $cellsInj[10])
    Check 'S4-report-no-ready-claim' (-not ($rowInj -match '可进入人工报价准备')) ('row=' + $rowInj)
    Check 'S4-report-no-complete-claim-despite-empty-gap-array' (-not ($rowInj -match '齐全')) ('row=' + $rowInj)
    Check 'S4-report-marks-items-unknown-not-ok' (($cellsInj[2] -eq '⚠️') -and ($cellsInj[3] -eq '⚠️') -and ($cellsInj[4] -eq '⚠️') -and ($cellsInj[8] -eq '—')) ('cells=' + ($cellsInj -join ' | '))
    Check 'S4-report-rule-version-marked-unavailable' ([bool](($linesB -join $LF) -match '规则版本（统一事实模型 RuleVersion）: \(不可用\)')) 'no rule version may be claimed when the model is unavailable'
    # 同一个完整资料夹具：未注入时（S2）判为可报价准备，注入后判为判定失败 ⇒ 证明本用例真的走了故障边界。
    Check 'S4-injection-actually-changed-the-verdict' ((Get-RowCells (Get-BuyerRow $linesA 'Virtual Buyer F2'))[10] -match '可进入人工报价准备') ('F2 status=' + (Get-RowCells (Get-BuyerRow $linesA 'Virtual Buyer F2'))[10])
} finally {
    Write-Output ''
    if ($script:fail -gt 0) { Write-Output ('TEMP-KEPT-FOR-DIAGNOSIS: ' + $isoRoot) }
    else { Remove-Item -LiteralPath $isoRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output ('RESULT pass={0} fail={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { Write-Output ('FAILED CASES: ' + ($script:fails -join ', ')); exit 1 }
Write-Output 'ALL PASS'
