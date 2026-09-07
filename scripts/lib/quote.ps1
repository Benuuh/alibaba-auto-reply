# lib/quote.ps1 - 报价提醒核心逻辑
# Get-QuoteReadyBuyers: 扫描快照,返回数据齐全(重量+尺寸+地址 3 项)的买家列表(人工接管白名单买家除外)
# Send-QuoteReminders: 推送提醒 + 去重(24h 节流,内容 hash 变化可再提醒);名单买家跳过
# 依赖: config.ps1, lib\goods.ps1, lib\wecom.ps1, lib\log.ps1, lib\no_reply.ps1
. (Join-Path $PSScriptRoot "no_reply.ps1")
function Get-QuoteReadyBuyers([string]$snapDir = "") {
    if (-not $snapDir) { $snapDir = Get-SkillPath "data" }
    if (-not (Test-Path $snapDir)) { return @() }
    $result = @()
    $seen = @{}
    Get-ChildItem -Path $snapDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $head = Get-Content $_.FullName -Encoding UTF8 -TotalCount 1 -ErrorAction SilentlyContinue
        if ($head -match '^# BUYER: (.+)$') {
            $buyer = $Matches[1].Trim()
            if (Test-NoReplyBuyer $buyer) { return }
            $key = $buyer.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { return }
            $seen[$key] = $true
            $st = Get-GoodsDataStatus $buyer $snapDir
            if ($st -and $st.weight -and $st.dims -and $st.addr) {
                $g = Get-GoodsName $buyer $snapDir
                $result += [pscustomobject]@{ buyer = $buyer; goods = $g.name; goodsKnown = $g.known; file = $st.file }
            }
        }
    }
    return $result
}

# 返回本次推送数量(只统计新提醒);OnlyBuyer 指定时只处理该买家
function Send-QuoteReminders([string]$OnlyBuyer = "", [string]$stateFile = "", [string]$snapDir = "", [string]$logFile = "") {
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
        # 提取具体详情(货物品名/件数/单件重量/单件尺寸/收货地址/运输方案)用于提醒展示
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
                [System.Text.Encoding]::UTF8.GetBytes(($b.buyer + "|" + $b.goods.Trim() + "|" + $gd.weight + "|" + $gd.dims + "|" + $gd.addr + "|" + $gd.qty + "|" + $gd.unit_weight + "|" + $gd.transport)))).Replace('-','')
        $saved = $null
        if ($state.reminded.ContainsKey($skey)) { $saved = $state.reminded[$skey] }
        if ($saved -and $saved.time -and $saved.hash) {
            $ageH = 999
            try { $ageH = ((Get-Date) - ([datetime]::ParseExact($saved.time, "yyyy-MM-dd HH:mm:ss", $null))).TotalHours } catch {}
            if ($ageH -lt 24 -and $saved.hash -eq $contentHash) { continue }
        }
        # 消息按 货物品名/件数/单件重量/单件尺寸/收货地址 逐行显示,有运输方案则追加一行(项目间换行)
        $msg = "[报价提醒] 买家 $($b.buyer) 货物信息已齐全`n货物品名: $($b.goods)`n件数: $qTxt`n单件重量: $uTxt`n单件尺寸: $dTxt`n收货地址: $aTxt"
        if ($tTxt) { $msg += "`n运输方案: $tTxt" }
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
