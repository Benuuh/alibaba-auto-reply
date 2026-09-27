# static_call_closure.ps1 -- [SPEC-单出口 2026-09-27 阶段 D 补] 生产脚本的"被调用函数必须存在"静态检查
#
# 为什么必须加（本次实测教训）:
#   阶段 A 改 monitor.ps1 时, 一次失败的回退编辑在 `Invoke-ConvoItem` 里留下一行
#   `Get-HumanInterjectionGate @(Get-HumanInterjectionProbeLines $item.preview)` ——
#   `Get-HumanInterjectionProbeLines` **在生产代码里根本不存在**(只在我的测试桩里有)。
#   A1 全量测试 23 个文件全绿、A16 语法解析全 OK、A2/A9/A10 全绿, 都**没能**发现它:
#     - 测试只 dot-source 纯函数文件, 不执行 monitor.ps1 的函数体;
#     - 语法解析只保证语法对, 不保证"名字存在"。
#   直到阶段 D 真跑起来才炸: 第 2 轮 `Monitor error: The term 'Get-HumanInterjectionProbeLines'
#   is not recognized` ⇒ 每个会话都在发送前中断 ⇒ 会话永久卡在待回复列表 + 每 10 秒重试。
#   本脚本就是补这个洞: 对每个生产 .ps1, 用 AST 取出所有**命令调用**, 逐一确认
#   "该名字在仓库内有定义, 或它是内建 cmdlet / 别名 / 语言关键字"。
#
# ⚠️ 只读: 只解析文件, 不执行任何脚本。
# 用法: powershell -ExecutionPolicy Bypass -NoProfile -File tools\dedup_acceptance\static_call_closure.ps1
param(
    [string[]]$Files = @(),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$here = Split-Path $MyInvocation.MyCommand.Path -Parent
$root = Split-Path (Split-Path $here -Parent) -Parent
$scripts = Join-Path $root "scripts"

if (-not $Files -or $Files.Count -eq 0) {
    # 默认: 生产脚本(scripts 下全部 .ps1, 排除 node_modules 与归档目录)
    $Files = @(Get-ChildItem -Path $scripts -Recurse -Include *.ps1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
            ForEach-Object { $_.FullName })
}

# ---- 1) 收集"可用名字" —— 按**本文件的 dot-source 闭包**算, 不按"全仓扫一遍" ----
#   为什么要按闭包: 今天的病灶是"桩函数里有、生产代码里没有"(Get-HumanInterjectionProbeLines 只存在于
#   tools\ 的测试桩)。若把全仓所有 function 都当作"已定义", 这个 bug 就会被漏掉(实测反面验证过)。
#   闭包构造: 沿本文件自己的 `. (Join-Path ... "x.ps1")` 语句递归收集被 dot-source 的文件, 再加自身定义。
$scriptDir = $scripts
$sourceCache = @{}

function Get-DotSourcedFiles([string]$path, [System.Collections.ArrayList]$acc) {
    if ($sourceCache.ContainsKey($path)) { return }
    $sourceCache[$path] = $true
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) { return }
    # 取法: 直接扫**所有字符串常量**, 凡以 .ps1 结尾且能按"本文件所在目录 / scripts 根"解析到文件的,
    #   就当作被 dot-source 的依赖。
    #   为什么不按 `CommandAst 里 GetCommandName() -eq '.'` 找: 实测 `. (Join-Path ...)` 的 CommandAst
    #   嵌套在 PipelineAst/ParenExpression 里, 那样过滤**一条都取不到** ⇒ 闭包恒为 1 个文件 ⇒
    #   真实存在的函数全被误报 UNDEF(第一版就这样, 输出 100+ 条假阳性)。
    #   风险: 注释/日志文案里若出现 "...ps1" 且恰好解析得到文件, 会被多收一个 —— 方向安全(判定更宽松);
    #   本仓库注释里写的是反引号包裹的路径, 实际未命中。
    $cands = @()
    foreach ($sn in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
        $v = [string]$sn.Value
        if ($v -notmatch '\.ps1$') { continue }
        # 排除含通配符/换行的候选: 日志文案或正则片段也可能以 ".ps1" 收尾, 直接喂给 Test-Path 会抛
        #   "The specified wildcard character pattern is not valid"（实测踩过: 候选里出现 "lib["）。
        if ($v -match '[\*\?\[\]\r\n]') { continue }
        $cands += $v
    }
    foreach ($cand in ($cands | Select-Object -Unique)) {
        if ([System.IO.Path]::IsPathRooted($cand)) {
            if (Test-Path -LiteralPath $cand) { $rp = (Resolve-Path -LiteralPath $cand).Path; [void]$acc.Add($rp); Get-DotSourcedFiles $rp $acc }
            continue
        }
        # `Join-Path $PSScriptRoot "lib\cdp.ps1"` 的目录部分是变量 ⇒ 先按本文件目录解析(=$PSScriptRoot 语义)
        foreach ($p2 in @((Join-Path (Split-Path $path -Parent) $cand), (Join-Path $scriptDir $cand))) {
            if (Test-Path -LiteralPath $p2) { $rp = (Resolve-Path -LiteralPath $p2).Path; [void]$acc.Add($rp); Get-DotSourcedFiles $rp $acc; break }
        }
    }
}

function Get-ClosureNames([string]$file) {
    $fs = New-Object System.Collections.ArrayList
    [void]$fs.Add((Resolve-Path -LiteralPath $file).Path)
    Get-DotSourcedFiles $file $fs
    $names = @{}
    foreach ($f2 in $fs) {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f2, [ref]$t, [ref]$e)
        if ($e -and $e.Count -gt 0) { continue }
        foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $names[$fn.Name] = $f2
        }
    }
    return $names
}

# ---- 全局名字索引（仓库内任意 .ps1 里定义过的名字） ----
#   判定用**两层**, 缺一不可:
#     ① 本文件 dot-source 闭包内的定义 —— 精确。能抓到"只存在于测试桩里的名字"这类真实缺陷
#        (桩在 tools\ 里、被 dot-source 进 harness, 但生产文件的闭包内**没有**它)。
#     ② 仓库内任意 .ps1 的定义 —— 兜底。有些脚本**故意**不 dot-source 任何文件
#        (cdp.ps1 走父作用域、chrome_ensure.ps1 由调用方 dot-source), 其闭包本来就是空的,
#        只看 ① 会产生大量假阳性。
$repoDefined = @{}
foreach ($rf in @(Get-ChildItem -Path $root -Recurse -Include *.ps1 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\node_modules\\|\\\.git\\' })) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($rf.FullName, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) { continue }
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $repoDefined[$fn.Name] = $rf.FullName
    }
}

# ---- 2) 逐文件取命令调用, 判定存在性 ----
$cmdCache = @{}
function Test-CommandExists([string]$name) {
    if ($cmdCache.ContainsKey($name)) { return $cmdCache[$name] }
    $ok = $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
    $cmdCache[$name] = $ok
    return $ok
}

# 语言关键字/常见自动变量写法（AST 里会以 CommandAst 出现但不需要是命令）
$builtinLike = @('if', 'else', 'elseif', 'foreach', 'for', 'while', 'switch', 'return', 'throw', 'try', 'catch', 'finally')

$report = New-Object System.Collections.ArrayList
$unknown = New-Object System.Collections.ArrayList

foreach ($f in $Files) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)
    if ($e -and $e.Count -gt 0) {
        [void]$unknown.Add([pscustomobject]@{ file = $f.Substring($root.Length + 1); line = $e[0].Extent.StartLineNumber; name = '<PARSE-ERROR>'; msg = $e[0].Message })
        continue
    }
    # 本文件 dot-source 闭包内可用的名字（不含 tests\/tools\ 的桩）
    $defined = Get-ClosureNames $f
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }                 # 只有内联表达式/子表达式, 例如 & $var
        # ⚠️ 大小写: 不能写 `$builtinLike -contains $name.ToLower()` —— 那会把 $name 本身改成小写,
        #    于是下面的 `^[A-Za-z_]` 判定仍成立(数字/字母都算), 但**日志与比对都会失真**;
        #    真正踩过的坑是相反方向: 用 `-contains $name.ToLower()` 之后接 `$name -cmatch` 之类的
        #    大小写敏感判定, 会让未定义命令整条被跳过。这里统一用不改变 $name 的写法。
        $lc = $name.ToLowerInvariant()
        if ($builtinLike -contains $lc) { continue }
        # ⚠️ 这里曾经写成 `^[A-Za-z_][A-Za-z0-9_]*$` —— **不允许连字符**, 而 PowerShell 的
        #    "动词-名词"函数名都带连字符 ⇒ 每个未定义的 cmdlet 风格名字都被归入下面的 else 分支
        #    ("动态调用, 跳过判定"), 检查看起来 OK 却什么都没查到。实测: 把今天的病灶行注入后
        #    本检查仍报 STATIC-CALL-OK。修正: `-` 放进字符类并置于末尾(避免被解析成区间)。
        if ($name -match '^[A-Za-z_][A-Za-z0-9_-]*$') {
            if ($defined.ContainsKey($name)) { continue }
            if ($repoDefined.ContainsKey($name)) { continue }   # 兜底: 仓库内别处有定义（如调用方 dot-source 提供）
            if (Test-CommandExists $name) { continue }
            [void]$unknown.Add([pscustomobject]@{
                    file = $f.Substring($root.Length + 1)
                    line = $c.Extent.StartLineNumber
                    name = $name
                    msg  = '既不是本文件 dot-source 闭包内的定义, 也不是本机可用命令'
                })
        } else {
            # 形如 .\x.ps1 / & $var 等动态调用: 只记录不判失败
            [void]$report.Add([pscustomobject]@{ file = $f.Substring($root.Length + 1); line = $c.Extent.StartLineNumber; name = $name; msg = 'dynamic-call (skipped)' })
        }
    }
}

if (-not $Quiet) {
    Write-Output ("== static_call_closure: 扫描 {0} 个生产脚本, 仓库内定义名 {1} 个 ==" -f $Files.Count, $defined.Count)
    Write-Output ("   动态调用(跳过判定) = {0}" -f $report.Count)
}
if ($unknown.Count -gt 0) {
    Write-Output "STATIC-CALL-FAIL: 发现未定义的命令调用（真跑起来会抛 CommandNotFoundException）:"
    $unknown | Sort-Object file, line | ForEach-Object { Write-Output ("  [UNDEF] {0}:{1}  {2}  ({3})" -f $_.file, $_.line, $_.name, $_.msg) }
    exit 1
}
Write-Output "STATIC-CALL-OK: 所有命令调用都能在仓库内或本机解析到"
exit 0
