# cache for llm config (invalidated by file mtime)
$script:__llmCfgCache = $null
$script:__llmCfgCacheTime = $null
# lib/llm.ps1 - LLM 调用统一封装(DeepSeek OpenAI 兼容)。
# 编码铁律:HttpWebRequest + StreamReader(UTF8) 显式解码(PS5.1 Invoke-RestMethod 会按 Latin-1 解码乱码)。
# 敏感铁律:api_key 只从 credentials.md 读取(Get-CredentialValue),禁止任何调用方传入 key。
# 重试:429/5xx/连接错误重试 1 次(3s 退避);超时类错误不重试。
# 依赖: config.ps1(Get-SkillPath "llmcfg"), lib\creds.ps1, lib\log.ps1(可选,提供 $logFile 时记录)。
# 返回:回复文本 或 $null(调用方回退规则引擎/模板)。
#
# ===== 2026-09-15 停摆根因修复 F2(a)/F4 新增:轮次预算与心跳 =====
# 背景:2026-09-15 monitor 被 watchdog 以"日志静默 > 90s"误杀(回复轮次耗时超阈值),随后僵锁自锁 +
#       风暴保护永久放弃 → 停摆 3h04m。修复思路是把"日志静默"重新等价于"僵死":
#       ① 轮次内每 15s 至少一行 ROUND-* 进度日志(含 LLM 阻塞等待期间);
#       ② 轮次总预算(reply_round_budget_sec,缺省 180s),预算不足时不再发起 LLM 调用。
# 说明:这两个能力需要"跨函数共享轮次上下文",而 Invoke-LLM 是所有 LLM HTTP 调用的唯一收口,
#       故把轮次上下文与心跳工具放在本文件(由 monitor.ps1 通过 Start-LlmRound/Stop-LlmRound 使用)。
$script:LlmRound = $null
# 心跳间隔(秒):阻塞等待期间每满该间隔输出一行,保证轮次内最大日志静默 < 30s
$script:LlmHeartbeatSec = 15

# 开始一个"回复轮次"上下文:记录起点与预算,供 Invoke-LLM 做预算检查与心跳
function Start-LlmRound([string]$key, [int]$budgetSec) {
    if ($budgetSec -lt 30) { $budgetSec = 30 }
    $script:LlmRound = @{
        key            = $key
        budgetSec      = $budgetSec
        sw             = [System.Diagnostics.Stopwatch]::StartNew()
        budgetExceeded = $false
    }
    return $script:LlmRound
}

# 结束轮次上下文
function Stop-LlmRound() { $script:LlmRound = $null }

# 轮次已耗时(秒);无上下文时返回 0
function Get-LlmRoundElapsedSec() {
    if (-not $script:LlmRound) { return 0 }
    return [int]$script:LlmRound.sw.Elapsed.TotalSeconds
}

# 剩余预算(秒);无上下文时返回 [int]::MaxValue(等价于不限)
function Get-LlmRoundRemainingSec() {
    if (-not $script:LlmRound) { return [int]::MaxValue }
    return [int]($script:LlmRound.budgetSec - $script:LlmRound.sw.Elapsed.TotalSeconds)
}

# 轮次预算是否已耗尽(供 monitor 在"发送前"决定本轮是否放弃)
function Test-LlmRoundBudgetExceeded() {
    if (-not $script:LlmRound) { return $false }
    return [bool]$script:LlmRound.budgetExceeded
}

# F4:预算不足时标记本轮并写 ROUND-BUDGET-EXCEEDED(只记一次,避免刷屏)
function Set-LlmRoundBudgetExceeded([string]$stage, [string]$logFile) {
    if (-not $script:LlmRound) { return }
    if ($script:LlmRound.budgetExceeded) { return }
    $script:LlmRound.budgetExceeded = $true
    if ($logFile) {
        Write-SkillLog ("ROUND-BUDGET-EXCEEDED {0} elapsed={1}s budget={2}s stage={3}" -f `
            $script:LlmRound.key, (Get-LlmRoundElapsedSec), $script:LlmRound.budgetSec, $stage) $logFile
    }
}

function Invoke-LLM([object[]]$messages, [double]$temperature, [int]$maxTokens, [string]$logFile) {
    # F4(2026-09-15 修复):轮次预算检查 —— 预算不足则跳过本次调用,由调用方走安全收尾(本轮不回复,下一轮重试)
    if ($script:LlmRound) {
        $remain = Get-LlmRoundRemainingSec
        if ($remain -le 5) {
            Set-LlmRoundBudgetExceeded "llm-entry" $logFile
            return $null
        }
    }
    $cfgFile = Get-SkillPath "llmcfg"
    $cfg = $null
    $ft = 0
    if (Test-Path $cfgFile) { $ft = (Get-Item $cfgFile).LastWriteTimeUtc.Ticks }
    if ($script:__llmCfgCache -and $script:__llmCfgCacheTime -eq $ft) {
        $cfg = $script:__llmCfgCache
    } elseif (Test-Path $cfgFile) {
        try {
            $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:__llmCfgCache = $cfg
            $script:__llmCfgCacheTime = $ft
        } catch {}
    }
    if (-not $cfg -or -not $cfg.endpoint -or -not $cfg.model) { return $null }

    $key = Get-CredentialValue 'api_key'
    if (-not $key) {
        if ($logFile) { Write-SkillLog "LLM config: api_key missing in credentials.md" $logFile }
        return $null
    }

    $payload = @{
        model       = [string]$cfg.model
        temperature = $temperature
        max_tokens  = $maxTokens
        messages    = $messages
    }
    # 可选透传(仅当 llm_config.json 显式配置): thinking / reasoning_effort(多模态新模型可能支持)
    if ($cfg.PSObject.Properties.Name -contains 'thinking' -and $cfg.thinking) { $payload.thinking = $cfg.thinking }
    if ($cfg.PSObject.Properties.Name -contains 'reasoning_effort' -and $cfg.reasoning_effort) { $payload.reasoning_effort = [string]$cfg.reasoning_effort }
    $body = $payload | ConvertTo-Json -Depth 6

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $attempts = 1
        $resp = $null
        $lastErr = $null
        while ($attempts -le 2 -and -not $resp) {
            try {
                if ($logFile) { Write-SkillLog "ROUND-LLM-BEGIN attempt=$attempts (t=$temperature max=$maxTokens)" $logFile }
                $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create([string]$cfg.endpoint)
                $req.Method = "POST"
                $req.ContentType = "application/json; charset=utf-8"
                $req.Timeout = ([int]$cfg.timeout_sec) * 1000
                $req.ReadWriteTimeout = ([int]$cfg.timeout_sec) * 1000
                $req.Headers.Add("Authorization", "Bearer $key")
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $req.ContentLength = $bodyBytes.Length
                $reqStream = $req.GetRequestStream()
                $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
                $reqStream.Dispose()
                # F2(a):阻塞等待期间按时心跳,不改变超时语义(仍为 timeout_sec,超时错误仍归类 TIMEOUT 不重试)。
                # 这样单次 LLM 调用(最坏 60s)不会再造成 >30s 的日志静默。
                $reqDeadline = (Get-Date).AddSeconds([int]$cfg.timeout_sec)
                $async = $req.BeginGetResponse($null, $null)
                while (-not $async.AsyncWaitHandle.WaitOne($script:LlmHeartbeatSec * 1000)) {
                    if ((Get-Date) -ge $reqDeadline) {
                        try { $req.Abort() } catch {}
                        throw (New-Object System.Net.WebException("The operation has timed out (llm heartbeat deadline $([int]$cfg.timeout_sec)s)"))
                    }
                    if ($logFile) { Write-SkillLog "ROUND-LLM-WAIT ms=$($sw.ElapsedMilliseconds) (awaiting LLM response, timeout=$([int]$cfg.timeout_sec)s)" $logFile }
                }
                $httpResp = $req.EndGetResponse($async)
                # 分块读取响应体(StreamReader 保持 UTF-8 解码状态,与 ReadToEnd 等价),同样按时心跳
                $reader = New-Object System.IO.StreamReader($httpResp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $respSb = New-Object System.Text.StringBuilder
                $charBuf = New-Object char[] 8192
                $lastHb = Get-Date
                while (($nRead = $reader.Read($charBuf, 0, $charBuf.Length)) -gt 0) {
                    [void]$respSb.Append($charBuf, 0, $nRead)
                    if ($logFile -and ((Get-Date) - $lastHb).TotalSeconds -ge $script:LlmHeartbeatSec) {
                        Write-SkillLog "ROUND-LLM-WAIT ms=$($sw.ElapsedMilliseconds) body=$($respSb.Length)chars (reading)" $logFile
                        $lastHb = Get-Date
                    }
                }
                $reader.Dispose()
                $httpResp.Dispose()
                $respJson = $respSb.ToString()
                $resp = $respJson | ConvertFrom-Json
            } catch {
                $lastErr = $_.Exception.Message
                $isRetriable = $lastErr -match '\((429|500|502|503|504)\)' -or $lastErr -match '无法连接到远程服务器|connection|Connection'
                if ($attempts -lt 2 -and $isRetriable) {
                    if ($logFile) { Write-SkillLog "LLM retry #$attempts after: $lastErr" $logFile }
                    Start-Sleep -Seconds 3
                    $attempts++
                } else { break }
            }
        }
        $sw.Stop()
        if (-not $resp) { throw $lastErr }
        $reply = $resp.choices[0].message.content
        if ($reply) {
            $reply = $reply.Trim()
            $reply = $reply -replace '^"|"$', ''
            if ($reply.Length -gt 0) {
                if ($logFile) {
                    Write-SkillLog "ROUND-LLM-END ms=$($sw.ElapsedMilliseconds) attempt=$attempts chars=$($reply.Length)" $logFile
                    Write-SkillLog "LLM ok ($($sw.ElapsedMilliseconds)ms, attempt $attempts)" $logFile
                }
                return $reply
            }
        }
        if ($logFile) { Write-SkillLog "ROUND-LLM-END ms=$($sw.ElapsedMilliseconds) attempt=$attempts chars=0" $logFile }
        return $null
    } catch {
        $errMsg = $_.Exception.Message
        $errType = "UNKNOWN"
        if ($errMsg -match 'timed out|timeout|Timeout') { $errType = "TIMEOUT" }
        elseif ($errMsg -match '\((400|401|402|403|429)\)') { $errType = "HTTP_$($Matches[1])" }
        elseif ($errMsg -match '\((5\d\d)\)') { $errType = "HTTP_$($Matches[1])" }
        elseif ($errMsg -match '无法连接到远程服务器|connection|Connection') { $errType = "NETWORK" }
        elseif ($errMsg -match 'API key|unauthorized|401') { $errType = "AUTH" }
        if ($logFile) {
            Write-SkillLog "ROUND-LLM-END ms=$($sw.ElapsedMilliseconds) attempt=$attempts result=ERROR type=$errType" $logFile
            Write-SkillLog "LLM error [$errType]: $errMsg" $logFile
            if ($_.ErrorDetails) { Write-SkillLog "LLM error details: $($_.ErrorDetails.Message)" $logFile }
        }
        return $null
    }
}
