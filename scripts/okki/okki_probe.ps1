# okki/okki_probe.ps1 - 只读实测探针(附加交付物,见报告 §7 偏差/P1)。
#   目的:把 spec §1.5 的 5 项待实测 + Q2/Q3/Q4/Q5/Q6/Q8 用真实登录态一次性问出来,
#         避免"凭附录想象字段名"(C10/N6)。
#   铁律:本文件**不得**出现任何商机写入接口(只读;仅 okki_opportunity 含写入路径)。
#   隐私:不打印响应正文、不打印 cookie/token;只打印"键名 + 值类型 + 截断样例"(C7)。
param(
    [ValidateSet("shape","keys","list-sample","flows","stages","me","detail-sample","all")]
    [string]$What = "all",
    [int]$Page = 1,
    [int]$PageSize = 5,
    [string]$CompanyId = "",
    [int]$SampleLen = 40
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
. (Join-Path (Split-Path $PSScriptRoot -Parent) "config.ps1")
. (Join-Path (Split-Path $PSScriptRoot -Parent) "lib\log.ps1")
. (Join-Path $PSScriptRoot "okki_lib.ps1")

function Show([string]$s) { Write-Host $s }

# 值 → 诊断字符串:类型 + 截断样例;对象/数组只报形状(不下钻,避免 PII 扩散)
function Fmt([object]$v) {
    if ($null -eq $v) { return "null" }
    if ($v -is [string]) {
        $s = $v
        if ($s.Length -gt $SampleLen) { $s = $s.Substring(0,$SampleLen) + "…" }
        return "string(" + $v.Length + ")='" + $s + "'"
    }
    if ($v -is [bool]) { return "bool=" + $v }
    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return "num=" + $v }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
        $n = 0; foreach ($x in $v) { $n++ }
        return "array[$n]"
    }
    $keys = @($v.PSObject.Properties.Name)
    if ($keys.Count -gt 12) { return "object{" + ($keys[0..11] -join ",") + ",…共" + $keys.Count + "键}" }
    return "object{" + ($keys -join ",") + "}"
}

function DumpKeys($Obj, [string]$Indent = "  ") {
    if ($null -eq $Obj) { Show ($Indent + "(null)"); return }
    foreach ($p in $Obj.PSObject.Properties) { Show ($Indent + $p.Name + " = " + (Fmt $p.Value)) }
}

try {
    $c = Assert-OkkiConfig

    if ($What -eq "shape" -or $What -eq "all") {
        Show "=== [1] companyList 响应形状(只读)==="
        Show ("筛选参数: filter_type=3 criteria_type=1 filters[0][field]=stage operator=is_null object_name=objOpportunity refer_type=9 field_type=3 curPage=$Page pageSize=$PageSize show_field_key=company.private.list.field swarm_id=1")
        $p = Get-OkkiCompanyPage -Page $Page -PageSize $PageSize -Raw
        Show ("列表路径=" + $p.ListPath + " 总数路径=" + $p.TotalPath + " 本页条数=" + $p.Count + " total=" + $p.Total)
        Show "响应顶层键:"
        DumpKeys $p.Raw "  "
        if ($p.Raw.data) { Show "  data 键:"; DumpKeys $p.Raw.data "    " }
    }

    if ($What -eq "keys" -or $What -eq "all") {
        Show "=== [2] 客户记录字段清单(Q6/Q8 字段名实测)==="
        $p = Get-OkkiCompanyPage -Page $Page -PageSize $PageSize
        if ($p.Count -eq 0) { Show "  本页 0 条" } else {
            $i = 0
            foreach ($r in $p.List) {
                $i++
                if ($i -gt $PageSize) { break }
                Show ("  --- 记录 #" + $i + " ---")
                DumpKeys $r "    "
            }
        }
    }

    if ($What -eq "list-sample" -or $What -eq "all") {
        Show "=== [3] 映射试算(国别原文→ISO→中文→商机名)==="
        $map = Get-OkkiCountryMap
        $rev = Get-OkkiZhToIso $map
        Show ("  字典条目数=" + $map.Count)
        $p = Get-OkkiCompanyPage -Page $Page -PageSize $PageSize
        $i = 0
        foreach ($r in $p.List) {
            $i++
            if ($i -gt $PageSize) { break }
            $cid = Get-OkkiRecValue $r "company_id"; if (-not $cid) { $cid = Get-OkkiRecValue $r "id" }
            $nm = Get-OkkiCompanyName $r
            $iso = Get-OkkiCompanyIso $r $map $rev
            $zh = if ($iso) { Get-OkkiCountryName $iso } else { $null }
            $mc = Get-OkkiMainCustomer $r
            $fu = Get-OkkiFollowerId $r
            $og = Get-OkkiOriginCandidate $r
            $oppName = "<无法构造>"
            if ($zh -and $nm) { $oppName = $zh + $nm }
            Show ("  #" + $i + " company_id=" + $cid + " 客户名=" + $nm + " country原文=" + (Fmt (Get-OkkiRecValue $r "country")) + " ISO=" + $iso + " 中文=" + $zh + " 商机名=" + $oppName)
            Show ("       main_customer=" + (Fmt $mc) + " main_customer原文=" + (Fmt (Get-OkkiRecValue $r "main_customer")) + " 跟进人=" + (Fmt $fu) + " 来源候选=" + (Fmt $og))
        }
    }

    if ($What -eq "flows" -or $What -eq "all") {
        Show "=== [4] flow 列表(Q2:取本账号真实 flow_id,禁止用附录示例值)==="
        $paths = @("/api/opportunityV3Read/list","/api/opportunityV3Read/flowList","/api/opportunitySettingRead/flowList","/api/opportunityV2Read/flowList")
        foreach ($path in $paths) {
            try {
                $r = Invoke-OkkiApi -Path $path -Method GET -TimeoutSec 20
                Show ("  " + $path + " → 顶层键: " + ((@($r.PSObject.Properties.Name)) -join ","))
                foreach ($lp in @("data.list","data.rows","data","list","rows")) {
                    $l = Get-OkkiListByPath $r $lp
                    if ($null -ne $l -and @($l).Count -gt 0) {
                        Show ("    列表路径=" + $lp + " 条数=" + @($l).Count)
                        DumpKeys (@($l)[0]) "      "
                        break
                    }
                }
            } catch { Show ("  " + $path + " → " + $_.Exception.Message) }
        }
    }

    if ($What -eq "stages" -or $What -eq "all") {
        Show "=== [5] stage 列表(Q3:找『首次接触』)==="
        if (-not $c.FlowId) {
            Show "  okki_flow_id 未配置 → 跳过(缺键即停机约定,见 §5.2)"
        } else {
            try {
                $form = New-OkkiOrderedDict
                $form["flow_id"] = [string]$c.FlowId
                $r = Invoke-OkkiApi -Path "/api/opportunitySettingRead/stageList" -Method POST -Form $form
                Show ("  顶层键: " + ((@($r.PSObject.Properties.Name)) -join ","))
                if ($r.data) { Show "  data 键:"; DumpKeys $r.data "    " }
                foreach ($lp in @("data.list","data.rows","data","list","rows","data.stage_list")) {
                    $l = Get-OkkiListByPath $r $lp
                    if ($null -ne $l) {
                        foreach ($s in $l) { Show ("    stage: " + (Fmt (Get-OkkiRecValue $s "name")) + " id=" + (Fmt (Get-OkkiRecValue $s "id")) + " 其它键=" + ((@($s.PSObject.Properties.Name)) -join ",")) }
                        break
                    }
                }
            } catch { Show ("  stageList → " + $_.Exception.Message) }
        }
    }

    if ($What -eq "me" -or $What -eq "all") {
        Show "=== [6] 当前用户(Q5:main_user 缺省值)==="
        $paths = @("/api/userV3Read/currentUser","/api/userV3Read/info","/api/userV2Read/current","/api/userV3Read/detail")
        foreach ($path in $paths) {
            try {
                $r = Invoke-OkkiApi -Path $path -Method GET -TimeoutSec 20
                Show ("  " + $path + " → 顶层键: " + ((@($r.PSObject.Properties.Name)) -join ","))
                if ($r.data) { DumpKeys $r.data "    " }
            } catch { Show ("  " + $path + " → " + $_.Exception.Message) }
        }
    }

    if ($What -eq "detail-sample") {
        Show "=== [7] customerV2Read/detail 形状(Q8 兜底路径)==="
        $cid = $CompanyId
        if (-not $cid) {
            $p = Get-OkkiCompanyPage -Page $Page -PageSize 1
            if ($p.Count -gt 0) { $cid = Get-OkkiRecValue $p.List[0] "company_id" }
        }
        if (-not $cid) { Show "  无 company_id 可测" } else {
            Show ("  测试 company_id=" + $cid)
            $form = New-OkkiOrderedDict
            $form["company_id"] = [string]$cid
            $form["fields"] = "all"
            try {
                $r = Invoke-OkkiApi -Path "/api/customerV2Read/detail" -Method POST -Form $form -TimeoutSec 25
                Show ("  顶层键: " + ((@($r.PSObject.Properties.Name)) -join ","))
                if ($r.data) { DumpKeys $r.data "    " }
                $mc = Get-OkkiContactFromDetail $r
                Show ("  Get-OkkiContactFromDetail → " + (Fmt $mc))
            } catch { Show ("  detail → " + $_.Exception.Message) }
        }
    }

    Show "=== 探针结束(全程只读)==="
} catch {
    Write-Host ("OKKI-PROBE-ERROR: " + $_.Exception.Message)
    exit 1
}
