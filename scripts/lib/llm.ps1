# cache for llm config (invalidated by file mtime)
$script:__llmCfgCache = $null
$script:__llmCfgCacheTime = $null
# lib/llm.ps1 - LLM 调用统一封装(DeepSeek OpenAI 兼容)。
# 编码铁律:HttpWebRequest + StreamReader(UTF8) 显式解码(PS5.1 Invoke-RestMethod 会按 Latin-1 解码乱码)。
# 敏感铁律:api_key 只从 credentials.md 读取(Get-CredentialValue),禁止任何调用方传入 key。
# 重试:429/5xx/连接错误重试 1 次(3s 退避);超时类错误不重试。
# 依赖: config.ps1(Get-SkillPath "llmcfg"), lib\creds.ps1, lib\log.ps1(可选,提供 $logFile 时记录)。
# 返回:回复文本 或 $null(调用方回退规则引擎/模板)。
function Invoke-LLM([object[]]$messages, [double]$temperature, [int]$maxTokens, [string]$logFile) {
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
    $body = $payload | ConvertTo-Json -Depth 6

    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $attempts = 1
        $resp = $null
        $lastErr = $null
        while ($attempts -le 2 -and -not $resp) {
            try {
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
                $httpResp = $req.GetResponse()
                $reader = New-Object System.IO.StreamReader($httpResp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $respJson = $reader.ReadToEnd()
                $reader.Dispose()
                $httpResp.Dispose()
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
                if ($logFile) { Write-SkillLog "LLM ok ($($sw.ElapsedMilliseconds)ms, attempt $attempts)" $logFile }
                return $reply
            }
        }
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
            Write-SkillLog "LLM error [$errType]: $errMsg" $logFile
            if ($_.ErrorDetails) { Write-SkillLog "LLM error details: $($_.ErrorDetails.Message)" $logFile }
        }
        return $null
    }
}
