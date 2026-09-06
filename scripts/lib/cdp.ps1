# lib/cdp.ps1 - CDP 桥接统一封装:执行 JS / 健康探测。
# 依赖: config.ps1(Get-SkillPath "cdp")。WS 超时保护在 cdp.ps1 内(连接 15s/接收 20s)。
function Invoke-CdpEval([string]$js) {
    $cdp = Get-SkillPath "cdp"
    # 防碎参:JS 先 Base64 再传子进程(-ScriptB64),避免文本含双引号/特殊字符时
    # powershell -File -Script <内联参数> 在命令行层被拆碎导致 eval 失败(cdp.ps1 内解码)
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($js))
    $out = powershell -ExecutionPolicy Bypass -File $cdp -Action eval -ScriptB64 $b64 2>&1
    return ($out -join "`n")
}

function Test-CdpReady {
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:9222/json/version" -TimeoutSec 3 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}
