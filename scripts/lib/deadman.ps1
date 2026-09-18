# deadman.ps1 - 死信心跳(2026-09-18):外部托管 ping(healthchecks.io 等),仅 ping 无 PII。
# 用法: . lib\deadman.ps1; $r = Send-DeadmanPing $url   # 返回 ok / fail / skip
# 说明:URL 为空返回 skip(不记日志);异常全部吞掉返回 fail,不得影响调用方(health_check)主流程。
$ErrorActionPreference = "Continue"

# 发送死信心跳:GET 请求,超时 10s;2xx→ok,其余/异常→fail
function Send-DeadmanPing([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) { return 'skip' }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 10 -UseBasicParsing
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return 'ok' }
        return 'fail'
    } catch {
        return 'fail'
    }
}
