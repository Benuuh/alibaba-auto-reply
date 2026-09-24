# okki/make_country_names.ps1 - 生成 country_names.json(ISO 3166-1 alpha-2 → 中文国别)。
#   来源:本机 Windows/.NET 的 zh-CN 区域性数据(CultureInfo 全量区域性枚举 +
#         RegionInfo.DisplayName 在 zh-CN 下返回的中文名),生成过程可复现、可核验。
#   理由:spec §5.7 要求写明来源且"不得凭空编造 250 国映射";用系统自带区域数据而非手抄。
#   关键坑:RegionInfo.DisplayName 取的是**当前线程区域性**的资源,不是构造参数。
#           不钉住会退化成英文名(实测:同机一次生成只剩 8 条带重音符号的英文名)。
#   只保留 ISO-3166-1 alpha-2(2 位大写)且中文名含 CJK 的条目。
#   输出:无 BOM UTF-8(C2)。
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$map = @{}
$source = "本机 Windows .NET 区域数据(CultureInfo 枚举 + RegionInfo.DisplayName,生成时线程区域性钉为 zh-CN)"
$skipped = New-Object 'System.Collections.ArrayList'

$prevCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
$prevUi = [System.Threading.Thread]::CurrentThread.CurrentUICulture
$zh = [System.Globalization.CultureInfo]::GetCultureInfo('zh-CN')
try {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $zh
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $zh

    foreach ($cu in [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures)) {
        $name = $cu.Name
        if ($name -notmatch '-') { continue }
        $iso = ($name -split '-')[-1].ToUpperInvariant()
        if ($iso -notmatch '^[A-Z]{2}$') { continue }
        # 已废弃/非国家代码
        if ($iso -in @("ZZ","QO","AN","CS","YU","ZR","TP","SU")) { continue }
        try {
            $ri = New-Object System.Globalization.RegionInfo($iso)
            $dn = $ri.DisplayName
            if (-not $dn) { continue }
            # 必须含 CJK,否则判定 zh-CN 资源未生效(退化成英文名)→ 拒绝采纳
            if ($dn -notmatch '[\u4e00-\u9fff]') { [void]$skipped.Add($iso + ":" + $dn); continue }
            if (-not $map.ContainsKey($iso)) { $map[$iso] = $dn }
        } catch { [void]$skipped.Add($iso + ":REGIONINFO_ERR") }
    }
} finally {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $prevCulture
    [System.Threading.Thread]::CurrentThread.CurrentUICulture = $prevUi
}

$sorted = New-Object 'System.Collections.Specialized.OrderedDictionary'
foreach ($k in ($map.Keys | Sort-Object)) { $sorted[$k] = $map[$k] }

$root = [ordered]@{
    "_comment"      = "ISO 3166-1 alpha-2 -> 中文国别。生成脚本:scripts\okki\make_country_names.ps1(可复现)。"
    "_source"       = $source
    "_generated_at" = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    "countries"     = $sorted
}

$out = Join-Path $PSScriptRoot "country_names.json"
$json = $root | ConvertTo-Json -Depth 6
# 无 BOM(C2);PS 5.1 的 Set-Content -Encoding UTF8 会写 BOM,必须用 .NET 写入
[IO.File]::WriteAllText($out, $json, (New-Object Text.UTF8Encoding($false)))

Write-Host ("生成完成: " + $out)
Write-Host ("条目数: " + $sorted.Count)
Write-Host ("跳过(无中文名/异常): " + $skipped.Count)
if ($skipped.Count -gt 0) { Write-Host ("  跳过样例: " + (($skipped | Select-Object -First 12) -join ', ')) }
foreach ($probe in @("US","GB","DE","JP","KR","IN","BR","RU","AU","VN","TH","ID","MY","SG","SA","AE","ZA","MX","TR","IT","FR","ES","CA","EG","NG")) {
    if ($sorted.Contains($probe)) { Write-Host ("  " + $probe + " = " + $sorted[$probe]) }
    else { Write-Host ("  " + $probe + " = <缺失>") }
}
