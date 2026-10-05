# lib\sent_records.ps1 - 本系统**已确认发送记录**（2026-10-05 spec §2.2 / §5-3 的证据来源）
#
# 用途：消息来源分级里的第 2 级证据。发送成功（页面动作 + 会话内新我方消息双证据）后落盘一条记录，
#   之后判定"这条 [ME] 是不是我们发的"就不再依赖 @@TS 这种时间字段。
# 存储：运行数据根下的 sent_records.json，经 state_store 原子替换；
#   每个买家只保留最近 N 条（默认 50），避免无限增长。
# 边界：这里只记录"我方发出的文本"，不含买家 PII；不写日志正文。
#
# 依赖：scripts\config.ps1、lib\paths.ps1、lib\state_store.ps1
if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Write-JsonDocumentAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'state_store.ps1')
}

$script:SentRecordMaxPerBuyer = 50

function Get-SentRecordFile {
    $p = Get-SkillPath 'sent_records'
    if ($p -and (Test-Path (Split-Path $p -Parent))) { return $p }
    return (Join-Path (Get-SkillPath 'data') 'sent_records.json')
}

function Get-SentRecordKey([string]$Buyer) {
    if ([string]::IsNullOrWhiteSpace($Buyer)) { return '' }
    return (($Buyer -replace '\s+', ' ').Trim().ToLowerInvariant())
}

# 归一化：与发送核对同一套口径（去不可见字符、折叠空白、小写）。本模块不依赖 send.ps1。
function Get-SentRecordNormText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $t = ([string]$Text) -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', ''
    return (($t -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Read-SentRecordStore {
    $doc = Read-JsonDocument (Get-SentRecordFile)
    if ($doc.Status -eq 'valid' -and $doc.Data -and ($doc.Data.PSObject.Properties.Name -contains 'buyers')) {
        return $doc.Data
    }
    if ($doc.Status -eq 'corrupt' -or $doc.Status -eq 'empty') {
        # 损坏的运行态不静默重建：返回空表但带上标记，调用方（日志）可据此判断。
        return [pscustomobject]@{ version = 1; buyers = [pscustomobject]@{}; __status = $doc.Status }
    }
    return [pscustomobject]@{ version = 1; buyers = [pscustomobject]@{}; __status = 'missing' }
}

function Save-SentRecordStore($Store) {
    $w = Write-JsonDocumentAtomic -Path (Get-SentRecordFile) -Data $Store -Depth 8
    return $w.Ok
}

function Add-SentRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$SentAt = '',
        [string]$Source = 'monitor',
        $Receipt = $null
    )
    $key = Get-SentRecordKey $Buyer
    if (-not $key) { return $false }
    $norm = Get-SentRecordNormText $Text
    if (-not $norm) { return $false }
    if (-not (Test-ConfirmedOutboundReceipt $Receipt $Buyer $Text)) { return $false }
    if (-not $SentAt) { $SentAt = (Get-Date).ToString('o') }
    $store = Read-SentRecordStore
    if($store.__status -in @('corrupt','empty','schema-invalid')){return $false}
    $buyers = @{}
    if ($store.buyers) {
        foreach ($p in $store.buyers.PSObject.Properties) { $buyers[$p.Name] = @($p.Value) }
    }
    $list = New-Object System.Collections.ArrayList
    if ($buyers.ContainsKey($key)) { foreach ($r in @($buyers[$key])) { [void]$list.Add($r) } }
    # 每个确认收据独立保存；同文不能覆盖已有事件。
    $kept = New-Object System.Collections.ArrayList
    foreach ($r in $list) { if ([string]$r.receipt.ReceiptId -ne $Receipt.ReceiptId) { [void]$kept.Add($r) } }
    [void]$kept.Add([pscustomobject]@{
        id = ([guid]::NewGuid().ToString('N').Substring(0, 12))
        normText = $norm
        chars = $norm.Length
        sentAt = $SentAt
        source = $Source
        receipt = $Receipt
        ambiguous = $false
    })
    while ($kept.Count -gt $script:SentRecordMaxPerBuyer) { $kept.RemoveAt(0) }
    $buyers[$key] = @($kept.ToArray())
    $out = [ordered]@{ version = 1; updatedAt = (Get-Date).ToString('o'); buyers = $buyers }
    return (Save-SentRecordStore $out)
}

function Get-SentRecords([string]$Buyer) {
    $key = Get-SentRecordKey $Buyer
    if (-not $key) { return @() }
    $store = Read-SentRecordStore
    if (-not $store.buyers) { return @() }
    # 逐属性比较，不用 $obj.$key 动态成员访问：键里可能含空格/特殊字符，动态访问会静默取不到值。
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $store.buyers.PSObject.Properties) {
        if ([string]$p.Name -ne $key) { continue }
        foreach ($r in @($p.Value)) { [void]$out.Add($r) }
    }
    return @($out.ToArray())
}

# 文本是否命中本系统已确认发送记录（归一化相等，或记录足够长且是页面文本的前缀）。

if (-not (Get-Command Get-MessageLineFingerprint -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'msg_source.ps1') }
. (Join-Path $PSScriptRoot 'outbound_receipts.ps1')
function Test-SentRecordMatch([string]$Buyer,[string]$Text) { return $false } # text alone never identifies an event
function Get-SentRecordMatchIndexes([string]$Buyer,[string[]]$Lines) {
    $map=@{};$records=@(Get-SentRecords $Buyer);$changed=$false
    foreach($record in $records){
        $receipt=$record.receipt
        if(-not $receipt -or -not $receipt.Valid -or $record.ambiguous){continue}
        $indices=@()
        for($index=0;$index -lt $Lines.Count;$index++){
            $line=$Lines[$index];if($line -notmatch '^\[ME\]'){continue}
            $body=($line -replace '^\[ME\]\s*','' -replace '@@[A-Z]+:[^\s]*','').Trim()
            if((Get-MessageLineFingerprint (Get-SentRecordNormText $body)) -ne $receipt.TextHash){continue}
            $mid=[regex]::Match($line,'@@MID:([^\s]+)');$time=[regex]::Match($line,'@@MT:([^\s]+)')
            if($receipt.MessageId){if($mid.Success -and $mid.Groups[1].Value -eq $receipt.MessageId){$indices+=$index}}
            elseif(-not $mid.Success -and $time.Success -and (Get-ReceiptTimestamp $time.Groups[1].Value) -eq (Get-ReceiptTimestamp $receipt.MessageTime)){$indices+=$index}
        }
        if($indices.Count -gt 1){$record|Add-Member -NotePropertyName ambiguous -NotePropertyValue $true -Force;$changed=$true;continue}
        if($indices.Count -eq 1 -and -not $map.ContainsKey($indices[0])){$map[$indices[0]]=$true}
    }
    if($changed){$store=Read-SentRecordStore;$key=Get-SentRecordKey $Buyer;$store.buyers|Add-Member -NotePropertyName $key -NotePropertyValue $records -Force;if(-not(Save-SentRecordStore $store)){return @{}}}
    return $map
}
