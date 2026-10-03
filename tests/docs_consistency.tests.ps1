# docs_consistency tests — 文档与代码一致性（2026-09-26 起）
#   依据：docs\文档权威约定.md §4
#   覆盖三次真实事故：① README 内部测试数字自相矛盾 ② 配置模板缺键(会导致告警全哑)
#                     ③ 移除健康检查项导致 README_部署说明 当场过时
#   纯读文件、不改任何东西 —— 可在任何时刻安全重跑。
#
#   ⚠️ 本文件必须保持 UTF-8 带 BOM（Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI/GBK 解码，
#      中文与判据会静默失真 —— KNOWN_EXCEPTIONS E-10）。
$ErrorActionPreference = "Stop"
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path $here -Parent

$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++; Write-Output ("  ok   " + $name) }
    else { $script:fail++; Write-Output ("  FAIL " + $name + "  -> " + $detail) }
}

Write-Output "== docs_consistency tests =="

# ---- 1+2: 健康检查项清单：README_部署说明.md 必须与 health_check.ps1 一致 ----
$hc  = Join-Path $root "scripts\health_check.ps1"
$dep = Join-Path $root "README_部署说明.md"

$codeNames = @()
if (Test-Path $hc) {
    $codeNames = @(Select-String -Path $hc -Pattern 'Add-Check\s+"([^"]+)"' |
                   ForEach-Object { $_.Matches[0].Groups[1].Value })
}
Check "health_check.ps1 能派生出检查项" ($codeNames.Count -gt 0) "Add-Check 命中 0 项"

$decl = $null
if (Test-Path $dep) {
    $decl = Select-String -Path $dep -Pattern '检查项（共\s*(\d+)\s*项' | Select-Object -First 1
}
Check "README_部署说明.md 有检查项声明行" ($null -ne $decl) "未找到 '检查项（共 N 项' 形式的行"

if ($decl -and $codeNames.Count -gt 0) {
    $declared = [int]$decl.Matches[0].Groups[1].Value
    Check "检查项【数量】一致" ($declared -eq $codeNames.Count) ("文档声明 $declared 项，代码实际 " + $codeNames.Count + " 项")

    $docNames = @()
    foreach ($m in [regex]::Matches($decl.Line, '`([a-z0-9_]+)`')) { $docNames += $m.Groups[1].Value }
    $docNames  = @($docNames  | Sort-Object -Unique)
    $codeUniq  = @($codeNames | Sort-Object -Unique)
    $missing = @($codeUniq | Where-Object { $docNames -notcontains $_ })
    $extra   = @($docNames | Where-Object { $codeUniq -notcontains $_ })
    Check "检查项【名单】无遗漏" ($missing.Count -eq 0) ("文档缺: " + ($missing -join ','))
    Check "检查项【名单】无多余" ($extra.Count -eq 0) ("文档多列: " + ($extra -join ','))
}

# ---- 3: 配置模板不得落后于现役配置（缺键会导致告警全哑且看起来正常）----
$ex   = Join-Path $root "scripts\config.json.example"
$live = Join-Path $root "scripts\config.json"
Check "config.json.example 存在" (Test-Path $ex) "缺文件"

if (Test-Path $ex) {
    $ek = @(); $okJson = $true
    try { $ek = @((Get-Content $ex -Raw | ConvertFrom-Json).PSObject.Properties.Name) } catch { $okJson = $false }
    Check "config.json.example 是合法 JSON" ($okJson -and $ek.Count -gt 0) "ConvertFrom-Json 失败或键数为 0"

    if (Test-Path $live) {
        $lk = @(); $lokJson = $true
        try { $lk = @((Get-Content $live -Raw | ConvertFrom-Json).PSObject.Properties.Name) } catch { $lokJson = $false }
        if ($lokJson -and $ek.Count -gt 0) {
            $miss = @($lk | Where-Object { $ek -notcontains $_ })
            Check "模板键集 ⊇ 现役键集" ($miss.Count -eq 0) ("模板缺 " + $miss.Count + " 个键: " + ($miss -join ', '))
        }
    } else {
        Write-Output "  skip scripts\config.json 不存在（新克隆/未部署），只校验模板本身"
    }

    # ---- 3b: [SPEC-待回复列表 2026-09-27 §0.1/§3.4] 两个新限流键必须**同时**在模板与现役配置里, 且值 = 5 ----
    #   为什么单列一条: "模板键集 ⊇ 现役键集"只保证"现役有的模板都有"; 若两个键被误从**两边同时**
    #   删掉, 上面那条仍然全绿 —— 而 monitor 会静默回落到内部缺省。这条断言把这对键钉死。
    $rlKeys = @('reply_min_gap_min', 'reply_post_send_cooldown_min')
    $exObj = $null; $liveObj = $null
    try { $exObj = Get-Content $ex -Raw | ConvertFrom-Json } catch { }
    try { $liveObj = Get-Content $live -Raw | ConvertFrom-Json } catch { }
    foreach ($k in $rlKeys) {
        Check ("config.json.example 含 $k = 5") ($exObj -and ($exObj.PSObject.Properties.Name -contains $k) -and ([int]$exObj.$k -eq 5)) ("值为 " + $(if ($exObj -and ($exObj.PSObject.Properties.Name -contains $k)) { $exObj.$k } else { '<缺失>' }))
        Check ("config.json 含 $k = 5") ($liveObj -and ($liveObj.PSObject.Properties.Name -contains $k) -and ([int]$liveObj.$k -eq 5)) ("值为 " + $(if ($liveObj -and ($liveObj.PSObject.Properties.Name -contains $k)) { $liveObj.$k } else { '<缺失>' }))
    }
    if ($liveObj -and ($liveObj.PSObject.Properties.Name -contains 'reply_min_gap_min') -and ($liveObj.PSObject.Properties.Name -contains 'reply_post_send_cooldown_min')) {
        Check "发送后冷却 ≥ 最小间隔（§0.1 硬要求）" ([int]$liveObj.reply_post_send_cooldown_min -ge [int]$liveObj.reply_min_gap_min) ("cooldown=" + $liveObj.reply_post_send_cooldown_min + " < gap=" + $liveObj.reply_min_gap_min)
    }
}

# ---- 4: 文档里不得写死"易漂数字"（规则三）----
#   事故 ① 的根因就是 README 两处各写了一个不同的"文件数 断言数"。
foreach ($doc in @("README.md","README_部署说明.md","docs\KNOWN_EXCEPTIONS.md","SKILL.md")) {
    $p = Join-Path $root $doc
    if (-not (Test-Path $p)) { continue }
    # 历史记录豁免：变更记录里描述"当时"的快照是合法历史，但必须显式标注（含"当时快照"字样），
    # 以免与"现役声称"混淆 —— 这正是事故①的形态（同一份文档两处不同的现役数字）。
    $hits = @(Select-String -Path $p -Pattern '\d+\s*文件\s*\d+\s*断言' |
              Where-Object { $_.Line -notmatch '当时快照' })
    Check ("$doc 未写死测试数字") ($hits.Count -eq 0) (($hits | ForEach-Object { "行" + $_.LineNumber } ) -join ',')
}

Write-Output ("RESULT: pass=$($script:pass) fail=$($script:fail)")
if ($script:fail -gt 0) { Write-Output "FAILED"; exit 1 }
Write-Output "ALL PASS"