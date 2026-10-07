# lib\outbound_receipts.ps1 - 真实出站收据（spec §4-4 / §4-5，复核 R1）
#
# 契约：
#   * 收据绑定**确切的新增出站事件**；DOM 下标、正文相似、页面位置都不是身份。
#   * 发送前后快照必须与生产会话读取使用**同一份**真实事件抽取（lib\msg_extract_js.ps1）与
#     同一套事件身份构造（lib\msg_events.ps1），不再各自扫描不同的 DOM 集合（复核 R1）。
#   * 无法建立身份的真实气泡**保留**在快照里：收据判定据此拒绝，而不是把它们过滤掉换取有效收据。
#   * 收据键的口径保持与既有已落盘收据兼容（sent_records.json 里的历史收据仍可校验）。

if (-not (Get-Command Get-MessageRowExtractJs -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'msg_extract_js.ps1')
}
if (-not (Get-Command Get-ConversationEventIndex -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'msg_events.ps1')
}

# A receipt binds an exact new outbound event. DOM position is never an identity.
function Get-OutboundEventKey($Event) {
    if($Event.MessageId){return 'id:'+[string]$Event.MessageId}
    if($Event.MessageTime -and $Event.TimePrecision -in @('millisecond','second','minute')){return 'at:'+[string]$Event.MessageTime+'|'+(Get-MessageLineFingerprint (Get-SentRecordNormText $Event.Text))}
    return ''
}
function Get-ReceiptTimestamp([string]$Time) {
    if($Time -match '^\d{13}$'){return $Time}
    $parsed=[DateTimeOffset]::MinValue
    if([DateTimeOffset]::TryParse($Time,[ref]$parsed)){return [string]$parsed.ToUnixTimeMilliseconds()}
    return ''
}

# 事件的身份质量：共享抽取器给出 platform-id / composite / legacy / ambiguous / unusable。
#   没有该字段的对象（旧收据、测试构造）按 'unspecified' 处理，沿用旧的键口径。
function Get-OutboundEventIdentityQuality($Event) {
    if (-not $Event) { return 'unusable' }
    if (-not ($Event.PSObject.Properties.Name -contains 'IdentityQuality')) { return 'unspecified' }
    $q = [string]$Event.IdentityQuality
    if (-not $q) { return 'unusable' }
    return $q
}

# "无法建立身份的真实气泡"的签名（复核 R1）：平台 ID、逐条时间、正文与方向都不足以唯一定位时，
#   这条观测只能作为不确定气泡保留，不能用来证明"新增了一条我方消息"。
function Get-OutboundUnidentifiedSignature($Event) {
    if (-not $Event) { return '' }
    if ($Event.PSObject.Properties.Name -contains 'IsNoise' -and [bool]$Event.IsNoise) { return '' }
    $key = Get-OutboundEventKey $Event
    $q = Get-OutboundEventIdentityQuality $Event
    if ($key -and $q -notin @('ambiguous', 'unusable')) { return '' }
    $dir = 'out'
    if ($Event.PSObject.Properties.Name -contains 'Direction' -and [string]$Event.Direction) { $dir = [string]$Event.Direction }
    elseif ($Event.PSObject.Properties.Name -contains 'IsMine' -and -not [bool]$Event.IsMine) { $dir = 'in' }
    $body = ''
    if ($Event.PSObject.Properties.Name -contains 'BodyHash' -and $Event.BodyHash) { $body = [string]$Event.BodyHash }
    else { $body = Get-MessageBodyFingerprint ([string]$Event.Text) }
    return ($dir + '|' + $q + '|' + [string]$Event.MessageId + '|' + [string]$Event.MessageTime + '|' + $body)
}

# 发送后快照里是否出现了**发送前不存在**的无法识别真实气泡。
#   返回 @{ New = @(signature...); Count = <int> }
function Compare-OutboundUnidentifiedEvents($Before, $After) {
    $pool = @{}
    foreach ($e in @($Before)) {
        $s = Get-OutboundUnidentifiedSignature $e
        if (-not $s) { continue }
        if (-not $pool.ContainsKey($s)) { $pool[$s] = 0 }
        $pool[$s] = [int]$pool[$s] + 1
    }
    $new = New-Object System.Collections.ArrayList
    foreach ($e in @($After)) {
        $s = Get-OutboundUnidentifiedSignature $e
        if (-not $s) { continue }
        if ($pool.ContainsKey($s) -and [int]$pool[$s] -gt 0) { $pool[$s] = [int]$pool[$s] - 1; continue }
        [void]$new.Add($s)
    }
    return [pscustomobject]@{ New = @($new.ToArray()); Count = @($new).Count }
}

function New-ConfirmedOutboundReceipt {
    param([string]$Buyer,[string]$Text,$Before=@(),$After=@())
    $r=[pscustomobject]@{Valid=$false;BuyerKey=(Get-SentRecordKey $Buyer);ReceiptId=[guid]::NewGuid().ToString('N');MessageId='';MessageTime='';TimePrecision='';TextHash=(Get-MessageLineFingerprint (Get-SentRecordNormText $Text));BeforeKeys=@();AfterKeys=@();ConfirmationType='';Error='no-unique-new-event';UnidentifiedNew=@()}
    $beforeKeys=@($Before|ForEach-Object {Get-OutboundEventKey $_});$afterKeys=@($After|ForEach-Object {Get-OutboundEventKey $_});$r.BeforeKeys=$beforeKeys;$r.AfterKeys=$afterKeys
    # [复核 R1] 发送后出现新的、无法建立身份的真实气泡 ⇒ 无法证明唯一新增事件，保持未确认。
    $unid = Compare-OutboundUnidentifiedEvents -Before $Before -After $After
    if ($unid.Count -gt 0) { $r.UnidentifiedNew=@($unid.New); $r.Error='new-unidentified-event'; return $r }
    # [spec §3.1 / A07 / 复核 R1] 结构噪声（flow 卡 / 总结卡）不是真实气泡，不能充当"新发出的消息"。
    $matches=@($After|Where-Object {$_.IsMine -and -not $_.IsNoise -and (Get-SentRecordNormText $_.Text) -eq (Get-SentRecordNormText $Text)})
    $new=@($matches|Where-Object {$key=Get-OutboundEventKey $_;$key -and $beforeKeys -notcontains $key -and @($afterKeys|Where-Object {$_ -eq $key}).Count -eq 1})
    if($new.Count -ne 1){return $r};$m=$new[0]
    # 候选事件自身的身份质量：ambiguous/unusable 不能作为收据绑定的事件（共享身份构造的结论）。
    if((Get-OutboundEventIdentityQuality $m) -in @('ambiguous','unusable')){$r.Error='new-event-identity-not-usable';return $r}
    if(-not $m.MessageId -and @($beforeKeys|Where-Object {$_}).Count -ne @($Before).Count){$r.Error='incomplete-before-identities';return $r}
    $r.MessageId=[string]$m.MessageId;$r.MessageTime=[string]$m.MessageTime;$r.TimePrecision=[string]$m.TimePrecision;$r.ConfirmationType=$(if($m.MessageId){'new-platform-message-id'}else{'unique-exact-new-event'});$r.Valid=$true;$r.Error='';return $r
}

# 发送前/后的真实出站快照（共享抽取 + 共享身份）。
#   * 逐条抽取、方向依据（已核实的左右侧/名字字段）、平台 ID（页面确实给出时）与结构噪声规则
#     全部来自 lib\msg_extract_js.ps1 —— 与会话读取同源；
#   * flow/总结卡与身份不确定的真实气泡**都保留**在返回值里（各自带 IsNoise / IdentityQuality），
#     由收据判定决定能不能证明，而不是在这里过滤（复核 R1）。
function Get-OutboundSnapshot {
    param([string]$Buyer = '')
    $rowJs = Get-MessageRowExtractJs
    $scopeJs = Get-ConversationScopeJs
    $target = ConvertTo-Json -InputObject $Buyer -Compress
    $scriptText = @"
(function(){
$rowJs
$scopeJs
  try {
    var snapshot = __aarCapture($target);
    return JSON.stringify({name: snapshot.scope.name, lines: __aarRowsToLines(snapshot.rows)});
  } catch (error) { return JSON.stringify({error: error.message}); }
})()
"@
    $raw = Invoke-SendEval $scriptText
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed -or -not $parsed.name -or $parsed.error) { throw ('OUTBOUND-SNAPSHOT-UNREADABLE:' + [string]$parsed.error) }
    $lines = @($parsed.lines | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($lines.Count -eq 0) { throw 'OUTBOUND-SNAPSHOT-UNREADABLE:MESSAGES_NOT_READY' }
    if (-not (Get-Command Get-ConversationEventIndex -ErrorAction SilentlyContinue)) { throw 'OUTBOUND-SNAPSHOT-NO-SHARED-EXTRACTOR' }
    return @(Get-ConversationEventIndex $lines)
}

function Test-ConfirmedOutboundReceipt($Receipt,[string]$Buyer,[string]$Text) {
    if (-not $Receipt -or -not $Receipt.Valid -or $Receipt.BuyerKey -ne (Get-SentRecordKey $Buyer) -or $Receipt.TextHash -ne (Get-MessageLineFingerprint (Get-SentRecordNormText $Text))){return $false}
    $event=[pscustomobject]@{MessageId=$Receipt.MessageId;MessageTime=$Receipt.MessageTime;TimePrecision=$Receipt.TimePrecision;Text=$Text};$key=Get-OutboundEventKey $event
    return ($key -and @($Receipt.AfterKeys|Where-Object {$_ -eq $key}).Count -eq 1 -and @($Receipt.BeforeKeys|Where-Object {$_ -eq $key}).Count -eq 0 -and ($Receipt.MessageId -or (Get-ReceiptTimestamp $Receipt.MessageTime)))
}
