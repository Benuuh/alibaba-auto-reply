# okki/okki_opportunity.ps1 - OKKI 商机批量建档主流程(spec §5.7 / S3 / S5)。
#   流程:配置校验 → 单实例锁 → 拉「商机阶段为空」候选 → 逐条映射/校验
#         → (-DryRun:只打印,零写入) 或 (真写:submitOpportunity + 逐条落盘) → 汇总日志。
#   幂等:① 服务端筛选(stage is_null) ② 本地 data\okki_opp_state.json(每条成功即落盘)
#         ③ 写入前复检(-Recheck,默认关)。
#   门禁:C12 —— 未经用户确认 Q7 不得写入(含 -Limit 5);-DryRun 零写入。
#   编码:UTF8-BOM(C1);state 无 BOM(C2)。
#   隐私:不记录 cookie/token;不整包转存响应(C7)。
param(
    [switch]$DryRun,          # 只报告不写入(不调用 submitOpportunity)
    [int]$Limit = 0,          # 最多处理 N 条;0 = 不限
    [int]$BatchSize = 6,      # 每批条数(进度打印粒度,默认 6)
    [switch]$Recheck,         # 写入前复检该客户阶段是否仍为空(幂等第③层,默认关)
    [int]$LockTimeoutSec = 10
)

$ErrorActionPreference = "Stop"
# 中文输出到管道/控制台不依赖控制台代码页
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\log.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\lock.ps1")
. (Join-Path $PSScriptRoot "okki_lib.ps1")

$script:Mode = if ($DryRun) { "DRYRUN" } else { "WRITE" }
$script:Seq = 0
$script:SkipUnknownCountry = 0
$script:SkipNoContact = 0
$script:FailCount = 0
$script:OkCount = 0
$script:PrefilterSkipped = 0

function Log2([string]$msg) { Write-OkkiLog ("[" + $script:Mode + "] " + $msg) }

# ---------------------------------------------------------------- 映射与校验

# 客户记录 → 候选对象;返回 @{Ok=$true;...} 或 @{Ok=$false;Reason=...}
function ConvertTo-OkkiCandidate($Rec, [hashtable]$Map, [hashtable]$Rev) {
    $cid = Get-OkkiRecValue $Rec "company_id"
    if (-not $cid) { $cid = Get-OkkiRecValue $Rec "id" }
    if (-not $cid) { return @{ Ok = $false; Reason = "SKIP-NO-COMPANY-ID" } }
    $name = Get-OkkiCompanyName $Rec
    if (-not $name) { return @{ Ok = $false; Reason = "SKIP-NO-NAME"; CompanyId = $cid } }
    $iso = Get-OkkiCompanyIso $Rec $Map $Rev
    if (-not $iso) {
        $raw = Get-OkkiRecValue $Rec "country"
        $rawTxt = if ($null -eq $raw) { "<无 country 字段>" } else { [string]$raw }
        return @{ Ok = $false; Reason = "SKIP-UNKNOWN-COUNTRY"; CompanyId = $cid; Name = $name; CountryRaw = $rawTxt }
    }
    $zh = Get-OkkiCountryName $iso
    if (-not $zh) { return @{ Ok = $false; Reason = "SKIP-UNKNOWN-COUNTRY"; CompanyId = $cid; Name = $name; Iso = $iso } }
    return @{
        Ok = $true
        CompanyId = [string]$cid
        Name = $name
        Iso = $iso
        CountryZh = $zh
        OppName = ($zh + $name)
        Contact = Get-OkkiMainCustomer $Rec
        Follower = Get-OkkiFollowerId $Rec
        Origin = Get-OkkiOriginCandidate $Rec
        Rec = $Rec
    }
}

# 主联系人兜底:列表无 main_customer → /api/customerV2Read/detail(附录 §四.2)
function Get-OkkiContactViaDetail([string]$CompanyId) {
    try {
        $form = New-OkkiOrderedDict
        $form["company_id"] = [string]$CompanyId
        $form["fields"] = "all"
        $resp = Invoke-OkkiApi -Path "/api/customerV2Read/detail" -Method POST -Form $form -TimeoutSec 25
        return (Get-OkkiContactFromDetail $resp)
    } catch {
        Log2 ("联系人兜底 detail 失败: " + $_.Exception.Message)
        return $null
    }
}

# 构造 submitOpportunity 的 body(附录 §四.3 结构)
function New-OkkiSubmitForm($Cand, $Cfg, [string]$AccountDate) {
    $contactId = $Cand.Contact
    if ($null -eq $contactId) { $contactId = "" }
    $opp = New-OkkiOrderedDict
    $opp["company_id"] = [string]$Cand.CompanyId
    # customer_id 是联系人 id 数组(附录原文 customer_id:[联系人id])
    $arr = New-Object 'System.Collections.ArrayList'
    [void]$arr.Add($contactId)
    $opp["customer_id"] = $arr
    $opp["flow_id"] = [string]$Cfg.FlowId
    $opp["name"] = $Cand.OppName
    $opp["currency"] = "USD"
    $opp["exchange_rate"] = 100
    $opp["amount"] = 1
    $opp["stage"] = [string]$Cfg.StageId
    $mainUser = $Cand.Follower
    if (-not $mainUser) { $mainUser = $Cfg.DefaultMainUser }
    $opp["main_user"] = $mainUser
    $opp["account_date"] = $AccountDate
    # origin_list 是数组(附录原文 origin_list:[客户来源])
    $originVal = $Cand.Origin
    if ($null -eq $originVal -or ([string]$originVal).Trim() -eq "") { $originVal = $Cfg.DefaultOrigin }
    $oarr = New-Object 'System.Collections.ArrayList'
    [void]$oarr.Add($originVal)
    $opp["origin_list"] = $oarr
    $opp["handler"] = New-OkkiOrderedDict   # {}

    $wrapper = New-OkkiOrderedDict
    $wrapper["opportunity"] = $opp
    $wrapper["product_list"] = New-Object 'System.Collections.ArrayList'   # 必须是 [](附录 §六)
    $dataJson = ConvertTo-OkkiJson $wrapper

    $form = New-OkkiOrderedDict
    $form["data"] = $dataJson
    $form["department"] = "0"
    return $form
}

# 从写响应里取 opportunity_id(字段名实测;探测多条路径,取到即返)
function Get-OkkiOpportunityId($Resp) {
    foreach ($p in @("data.opportunity_id","data.id","data.opportunity.id","opportunity_id","id","data.data.opportunity_id")) {
        $node = $Resp
        foreach ($seg in $p.Split('.')) {
            if ($null -eq $node) { break }
            $node = Get-OkkiRecValue $node $seg
        }
        if ($node -and ([string]$node).Trim() -ne "") { return [string]$node }
    }
    return $null
}

function Test-OkkiRespOk($Resp) {
    foreach ($k in @("code","status","errno","error_code")) {
        $v = Get-OkkiRecValue $Resp $k
        if ($null -ne $v) {
            $s = [string]$v
            if ($s -in @("0","200","true","success","ok")) { return $true }
            return $false
        }
    }
    # 无码字段:有 data 视为成功(实测确认)
    if (Get-OkkiRecValue $Resp "data") { return $true }
    return $false
}

# ---------------------------------------------------------------- DryRun 打印

function Show-OkkiDryRun($Cand, $Cfg, [string]$AccountDate) {
    $script:Seq++
    $form = New-OkkiSubmitForm $Cand $Cfg $AccountDate
    Log2 ("seq=" + $script:Seq + " company_id=" + $Cand.CompanyId + " 客户名=" + $Cand.Name + " 国别=" + $Cand.Iso + "/" + $Cand.CountryZh + " 商机名=" + $Cand.OppName + " 联系人=" + (Fmt-OkkiVal $Cand.Contact) + " 跟进人=" + (Fmt-OkkiVal $Cand.Follower) + " 来源=" + (Fmt-OkkiVal $Cand.Origin))
    Write-Host ("  [DRYRUN] 将提交的 body(仅打印,不发送): data=" + [string]$form["data"] + " & department=" + [string]$form["department"])
}

function Fmt-OkkiVal($v) {
    if ($null -eq $v) { return "<空>" }
    $s = [string]$v
    if ($s.Trim() -eq "") { return "<空>" }
    return $s
}

# ---------------------------------------------------------------- 主流程

$lockName = "okki_opportunity"
$gotLock = $false
$runStart = Get-Date
$runRec = New-OkkiOrderedDict
$state = $null

try {
    $cfg = Assert-OkkiConfig -ForWrite:(-not $DryRun)

    if (-not $DryRun) {
        # C12 硬门禁:写入前必须已有用户对 Q7 的书面确认,由 config 的 okki_q7_confirmed 承载
        $q7 = (Get-SkillConfig).okki_q7_confirmed
        if ($q7 -ne $true) {
            Log2 "OKKI-GATE-BLOCKED: 未确认 Q7(currency/exchange_rate/amount/account_date 业务语义),拒绝任何写入(C12/N4)。"
            Write-Host "OKKI-GATE-BLOCKED: Q7 未确认,已停机,零写入。"
            exit 12
        }
    }

    # 单实例锁:必须在**任何请求之前**拿到(§6 S5 "先取锁";C5/D2:拿不到锁即零请求退出)
    $gotLock = Get-AppLock $lockName $LockTimeoutSec
    if (-not $gotLock) {
        Log2 "OKKI-LOCK-BUSY: 另一实例正在运行,本次退出(零请求)"
        Write-Host "OKKI-LOCK-BUSY"
        exit 6
    }

    # CDP 前置检查(端口不可达 → 零写入,退出码 3)
    if (-not (Test-OkkiCdpReady -Port $cfg.CdpPort)) {
        Log2 ("OKKI-CDP-DOWN: 端口 " + $cfg.CdpPort + " 不可达(零写入)")
        Write-Host ("OKKI-CDP-DOWN: " + $cfg.CdpPort)
        exit 3
    }
    Log2 ("开始: port=" + $cfg.CdpPort + " pageSize=" + $cfg.PageSize + " intervalMs=" + $cfg.IntervalMs + " limit=" + $Limit + " batch=" + $BatchSize + " recheck=" + [bool]$Recheck)

    # 登录态前置检查(未登录则零写入)
    $st = Invoke-OkkiCdpEval (Get-OkkiLoginStateJs) | ConvertFrom-Json
    if (-not $st.loggedIn) {
        Log2 ("OKKI-ENSURE: NEED_LOGIN host=" + $st.host + " path=" + $st.path + " reason=" + $st.reason + " → 零写入")
        Write-Host "OKKI-ENSURE: NEED_LOGIN"
        exit 2
    }

    if ($DryRun) {
        $state = New-OkkiState
        if (Test-Path (Get-OkkiStateFile)) { $state = Read-OkkiState }
    } else {
        $state = New-OkkiState
        if (Test-Path (Get-OkkiStateFile)) { $state = Read-OkkiState }
    }
    $createdBefore = @($state.created.PSObject.Properties).Count

    # 1. 拉候选
    $pull = Get-OkkiCandidates -Limit $Limit -PageSize $cfg.PageSize
    $records = @($pull.Records)
    Log2 ("候选拉取: records=" + $records.Count + " total=" + (Fmt-OkkiVal $pull.Total) + " listPath=" + $pull.ListPath + " totalPath=" + $pull.TotalPath + " pages=" + $pull.Pages)
    Log2 "筛选参数原文: filter_type=3&criteria_type=1&filters[0][field]=stage&filters[0][operator]=is_null&filters[0][object_name]=objOpportunity&filters[0][refer_type]=9&filters[0][field_type]=3&curPage=N&pageSize=" + $cfg.PageSize + "&show_field_key=company.private.list.field&swarm_id=1"

    $map = Get-OkkiCountryMap
    $rev = Get-OkkiZhToIso $map
    $accountDate = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")

    # 2. 映射
    $cands = New-Object 'System.Collections.ArrayList'
    foreach ($r in $records) {
        $c = ConvertTo-OkkiCandidate $r $map $rev
        if ($c.Ok) { [void]$cands.Add($c) } else {
            $script:PrefilterSkipped++
            if ($c.Reason -eq "SKIP-UNKNOWN-COUNTRY") { $script:SkipUnknownCountry++ } else { $script:FailCount++ }
            $cidTxt = Fmt-OkkiVal $c.CompanyId
            $nmTxt = Fmt-OkkiVal $c.Name
            $rawTxt = Fmt-OkkiVal $c.CountryRaw
            Log2 ("seq=" + $script:Seq + " " + $c.Reason + " company_id=" + $cidTxt + " 客户名=" + $nmTxt + " country原文=" + $rawTxt)
        }
    }

    # 3. 逐条处理
    $processed = 0
    foreach ($cand in $cands) {
        if ($Limit -gt 0 -and $processed -ge $Limit) { break }
        # 幂等第②层:state 命中即跳过
        if (Test-OkkiAlreadyCreated $state $cand.CompanyId) {
            $script:PrefilterSkipped++
            Log2 ("SKIP-STATE-EXISTS company_id=" + $cand.CompanyId + " 客户名=" + $cand.Name)
            continue
        }
        $processed++

        if ($DryRun) {
            Show-OkkiDryRun $cand $cfg $accountDate
            continue
        }

        # ---- 写入路径(Q7 已确认才会到这里) ----
        # 幂等第③层(可选):写入前复检
        if ($Recheck) {
            try {
                $pg = Get-OkkiCompanyPage -Page 1 -PageSize 1 -ExtraFilters ("filters[1][field]=company_id&filters[1][operator]=eq&filters[1][value]=" + $cand.CompanyId)
                if (@($pg.List).Count -eq 0) {
                    Log2 ("SKIP-RECHECK-GONE company_id=" + $cand.CompanyId + "(已不再匹配『阶段为空』)")
                    continue
                }
            } catch { Log2 ("复检失败(继续按服务端筛选结果处理): " + $_.Exception.Message) }
        }

        # 联系人兜底
        if ($null -eq $cand.Contact -or ([string]$cand.Contact).Trim() -eq "") {
            $cand.Contact = Get-OkkiContactViaDetail $cand.CompanyId
        }
        if ($null -eq $cand.Contact -or ([string]$cand.Contact).Trim() -eq "") {
            $script:SkipNoContact++
            Log2 ("seq=" + $script:Seq + " SKIP-NO-CONTACT company_id=" + $cand.CompanyId + " 客户名=" + $cand.Name)
            Add-OkkiStateFailed $state $cand.CompanyId "SKIP-NO-CONTACT"
            continue
        }

        # 频控:相邻两条写入间隔 ≥ intervalMs
        if ($script:OkCount -gt 0 -and $cfg.IntervalMs -gt 0) { Start-Sleep -Milliseconds $cfg.IntervalMs }

        $seqNo = $script:OkCount + 1
        $form = New-OkkiSubmitForm $cand $cfg $accountDate
        $attempt = 0
        $done = $false
        while (-not $done -and $attempt -lt 2) {
            $attempt++
            try {
                $resp = Invoke-OkkiApi -Path "/api/opportunityV2Write/submitOpportunity" -Method POST -Form $form -TimeoutSec 40
                if (Test-OkkiRespOk $resp) {
                    $oid = Get-OkkiOpportunityId $resp
                    if (-not $oid) { $oid = "(响应未含 opportunity_id;顶层键=" + ((@($resp.PSObject.Properties.Name)) -join ",") + ")" }
                    $script:OkCount++
                    Add-OkkiStateCreated $state $cand.CompanyId $oid $cand.OppName
                    $script:Seq++
                    Log2 ("seq=" + $script:Seq + " CREATED:" + $oid + " company_id=" + $cand.CompanyId + " 客户名=" + $cand.Name + " 国别=" + $cand.CountryZh + " 联系人id=" + (Fmt-OkkiVal $cand.Contact))
                    $done = $true
                } else {
                    $keys = (@($resp.PSObject.Properties.Name)) -join ","
                    $code = Fmt-OkkiVal (Get-OkkiRecValue $resp "code")
                    $msg = Fmt-OkkiVal (Get-OkkiRecValue $resp "msg")
                    if (-not (Get-OkkiRecValue $resp "msg")) { $msg = Fmt-OkkiVal (Get-OkkiRecValue $resp "message") }
                    throw ("接口返回非成功: code=" + $code + " msg=" + $msg + " 顶层键=[" + $keys + "]")
                }
            } catch {
                $reason = $_.Exception.Message
                if ($attempt -ge 2) {
                    $script:FailCount++
                    Add-OkkiStateFailed $state $cand.CompanyId $reason
                    $script:Seq++
                    Log2 ("seq=" + $script:Seq + " FAIL:" + $reason + " company_id=" + $cand.CompanyId + " 客户名=" + $cand.Name)
                } else {
                    Log2 ("第 " + $attempt + " 次失败,重试一次: " + $reason)
                    Start-Sleep -Seconds 2
                }
            }
        }

        if ($script:OkCount -gt 0 -and ($script:OkCount % $BatchSize) -eq 0) {
            Log2 ("进度: 已成功 " + $script:OkCount + " 条 / 候选 " + $cands.Count + " 条")
        }
    }

    # 4. 汇总
    $runEnd = Get-Date
    $createdAfter = @($state.created.PSObject.Properties).Count
    Log2 ("汇总: 候选=" + $cands.Count + " 处理=" + $processed + " 成功=" + $script:OkCount + " 跳过-未知国别=" + $script:SkipUnknownCountry + " 跳过-无联系人=" + $script:SkipNoContact + " 失败=" + $script:FailCount + " 预筛跳过=" + $script:PrefilterSkipped)
    Log2 ("state.created: 前=" + $createdBefore + " 后=" + $createdAfter + " 耗时=" + [int]($runEnd - $runStart).TotalSeconds + "s")

    if (-not $DryRun) {
        $runRec["start"] = $runStart.ToString("yyyy-MM-dd HH:mm:ss")
        $runRec["end"] = $runEnd.ToString("yyyy-MM-dd HH:mm:ss")
        $runRec["mode"] = $script:Mode
        $runRec["candidates"] = $cands.Count
        $runRec["processed"] = $processed
        $runRec["ok"] = $script:OkCount
        $runRec["skip_unknown_country"] = $script:SkipUnknownCountry
        $runRec["skip_no_contact"] = $script:SkipNoContact
        $runRec["fail"] = $script:FailCount
        $recs = New-Object 'System.Collections.ArrayList'
        foreach ($x in @($state.created.PSObject.Properties)) {
            $recs.Add([pscustomobject]@{ seq = $recs.Count + 1; at = $x.Value.at })
        }
        $runRec["write_times"] = $recs
        Add-OkkiStateRun $state $runRec
        Log2 ("Runs 已记录(最近 " + $state.runs.Count + " 次)")
    } else {
        Log2 "DRYRUN 结束:零写入(未调用 submitOpportunity,未改动 state)"
    }

    if ($script:FailCount -gt 0 -and $script:OkCount -eq 0 -and $cands.Count -gt 0) { exit 7 }
    exit 0
} catch {
    $msg = $_.Exception.Message
    Write-Host ("OKKI-ERROR: " + $msg)
    try { Log2 ("ERROR: " + $msg) } catch {}
    if ($msg -match '^OKKI-CONFIG-MISSING') { exit 9 }
    exit 1
} finally {
    if ($gotLock) { Release-AppLock $lockName }
}
