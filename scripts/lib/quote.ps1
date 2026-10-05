# lib\quote.ps1 - 报价提醒核心逻辑
# Get-QuoteReadyBuyers: 扫描快照,返回**四项基本报价条件齐备**
#   (运输外包装件数 + 有效包装重量或已明确总重 + 有效包装尺寸 + 可用报价目的地) 的买家列表
#   (人工接管白名单买家除外)。
#   判据 = 唯一的 Get-QuoteReadiness（经 msg_norm::Get-QuoteReadinessForConversationText 适配），
#   不再是本文件自己的"重量 + 尺寸 + 地址"三个布尔值（2026-10-05 spec §4.2 第 1/2 条）。
# Send-QuoteReminders: 推送提醒 + 去重(24h 节流,内容 hash 变化可再提醒);名单买家跳过
# 依赖: config.ps1, lib\msg_norm.ps1, lib\facts_engine.ps1, lib\goods.ps1, lib\wecom.ps1, lib\log.ps1, lib\no_reply.ps1
. (Join-Path $PSScriptRoot "no_reply.ps1")
if (-not (Get-Command ConvertTo-MessageList -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "msg_norm.ps1")
}

function Get-QuoteReadyBuyers([string]$snapDir = "") {
    if (-not $snapDir) { $snapDir = Get-SkillPath "data" }
    if (-not (Test-Path $snapDir)) { return @() }
    $result = @()
    $seen = @{}
    Get-ChildItem -Path $snapDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $raw = $null
        try { $raw = [string](Get-Content $_.FullName -Raw -Encoding UTF8 -ErrorAction Stop) } catch { return }
        $head = ''
        $firstLine = ($raw -split "`n")[0]
        if ($firstLine -match '^# BUYER: (.+)$') { $head = $Matches[1].Trim() }
        if (-not $head) { return }
        $buyer = $head
        if (Test-NoReplyBuyer $buyer) { return }
        $key = $buyer.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        # 单一判据：Get-QuoteReadiness。缺件数的样例（只有总毛重/每箱尺寸/DDP 目的地）不再进入名单。
        $rw = $null
        # [spec §5.4 第 3 条] 与回复决策/摘要共用同一证据适配契约（已验证的确认资料并入统一事实模型）。
        try { $rw = Get-QuoteReadinessForConversationText -Text $raw -ConvoName $buyer -WithTaskEvidence } catch { $rw = $null }
        if (-not $rw -or -not $rw.Available -or -not $rw.Ready) { return }
        $g = Get-GoodsName $buyer $snapDir
        $dest = $null
        if ($rw.Facts) { $dest = $rw.Facts.Destination }
        $result += [pscustomobject]@{
            buyer = $buyer; goods = $g.name; goodsKnown = $g.known; file = $_.Name
            Destination = $dest
            Readiness = $rw.Readiness
            MissingFields = @($rw.MissingFields)
            OptionalMissingFields = @($rw.OptionalMissingFields)
            CollectionComplete = [bool]$rw.CollectionComplete
            RuleVersion = [string]$rw.RuleVersion
        }
    }
    return $result
}

# 返回本次推送数量(只统计新提醒);OnlyBuyer 指定时只处理该买家
function Send-QuoteReminders([string]$OnlyBuyer = "", [string]$stateFile = "", [string]$snapDir = "", [string]$logFile = "") {
    # 具名运行态路径 'remind'（生产=scripts\remind_state.json，隔离模式=运行根下的同名文件）。
    #   之前写死成 scripts 目录，隔离测试会给**生产**提醒去重表写入记录（违反隔离保证）。
    if (-not $stateFile) { $stateFile = Get-SkillPath "remind" }
    if (-not $stateFile) { $stateFile = Join-Path (Get-SkillPath "scripts") "remind_state.json" }
    $state = [pscustomobject]@{ reminded = @{} }
    if (Test-Path $stateFile) {
        try { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    # 统一转 Hashtable:Add-Member 到 @{} 后 ConvertTo-Json 会序列化为空(PS 5.1 坑),必须用键赋值
    $reminded = @{}
    if ($state -and $state.reminded) {
        foreach ($p in $state.reminded.PSObject.Properties) { $reminded[$p.Name] = $p.Value }
    }
    $state = [pscustomobject]@{ reminded = $reminded }
    $ready = Get-QuoteReadyBuyers $snapDir
    if ($OnlyBuyer) { $ready = @($ready | Where-Object { $_.buyer -eq $OnlyBuyer }) }
    $sent = 0
    foreach ($b in $ready) {
        if (Test-NoReplyBuyer $b.buyer) {
            if ($logFile) { Write-SkillLog "QUOTE-REMIND: skip manual-override buyer $($b.buyer)" $logFile }
            continue
        }
        $skey = $b.buyer.Trim().ToLowerInvariant()
        # 提取具体详情(货物品名/件数/单件重量/单件尺寸/报价目的地/运输方案)用于提醒展示
        $gd = Get-GoodsDetails $b.buyer $snapDir
        $wTxt = if ($gd.weight) { $gd.weight } else { "未知" }
        $dTxt = if ($gd.dims) { $gd.dims } else { "未知" }
        $aTxt = if ($gd.addr) { $gd.addr } else { "未知" }
        $qTxt = if ($gd.qty) { $gd.qty } else { "未知" }
        $uTxt = if ($gd.unit_weight) { $gd.unit_weight } else { "未知" }
        $tTxt = if ($gd.transport) { $gd.transport } else { "" }
        # 去重 hash 含新字段:买家补充件数/单件重量/运输方案后内容变化可再次提醒(24h 节流不变)
        $contentHash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.MD5]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes(($b.buyer + "|" + $b.goods.Trim() + "|" + $gd.weight + "|" + $gd.dims + "|" + $gd.addr + "|" + $gd.qty + "|" + $gd.unit_weight + "|" + $gd.transport + "|" + [string]$b.RuleVersion)))).Replace('-','')
        $saved = $null
        if ($state.reminded.ContainsKey($skey)) { $saved = $state.reminded[$skey] }
        if ($saved -and $saved.time -and $saved.hash) {
            $ageH = 999
            try { $ageH = ((Get-Date) - ([datetime]::ParseExact($saved.time, "yyyy-MM-dd HH:mm:ss", $null))).TotalHours } catch {}
            if ($ageH -lt 24 -and $saved.hash -eq $contentHash) { continue }
        }
        # 消息按 货物品名/件数/单件重量/单件尺寸/报价目的地 逐行显示,有运输方案则追加一行(项目间换行)
        $msg = "[报价提醒] 买家 $($b.buyer) 货物信息已齐全`n货物品名: $($b.goods)`n件数: $qTxt`n单件重量: $uTxt`n单件尺寸: $dTxt`n报价目的地: $aTxt"
        if ($tTxt) { $msg += "`n运输方案: $tTxt" }
        # 完整清单与"可报价"分开显示：可报价 ≠ 标准收集清单齐全（spec §4.2 第 5 条）。
        if (-not $b.CollectionComplete) {
            $opt = @($b.OptionalMissingFields)
            if ($opt.Count -gt 0) { $msg += "`n清单未齐(不阻挡报价): " + ($opt -join ', ') }
        }
        $msg += "`n建议: 人工核对后给出报价"
        $res = Send-WecomMessage $msg
        if ($res -eq 'SENT_OK') {
            $state.reminded[$skey] = @{ time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); hash = $contentHash }
            $sent++
            if ($logFile) { Write-SkillLog "QUOTE-REMIND: $($b.buyer) -> $res" $logFile }
        } else {
            if ($logFile) { Write-SkillLog "QUOTE-REMIND-FAIL: $($b.buyer) -> $res" $logFile }
        }
    }
    if ($sent -gt 0) {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8
    }
    return $sent
}