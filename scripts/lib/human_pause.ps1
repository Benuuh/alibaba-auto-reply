# lib\human_pause.ps1 - 人工临时暂停（5 分钟）与"来源不明我方消息"等待（2026-10-05 八项补修 F2/F3）
#
# 时间口径（spec §3.1 第 1/2 条）：
#   * 内部**只**用绝对 UTC 时刻做比较与持久化：untilUtc / lastHumanReplyAtUtc / firstSeenAtUtc / atUtc；
#   * 消息的 @@MT 是 epoch 毫秒 ⇒ 直接换算成绝对时刻；带明确偏移的时间串按偏移解析；
#   * 只有写日志/给人看时才转成本地时间（Format-HumanPauseLocal）；
#   * **绝不**把"最大消息时间"映射到本轮 Now，也绝不按历史消息与最大值的相对差值重造回复时刻。
#
# 事件身份（spec §3.1 第 3 条）：
#   * 真实逐条时间 + 角色 + 规范化正文 = 稳定身份：'me|mt:<@@MT 原样>|h:<SHA1(去标记正文)>'；
#   * 没有可靠逐条时间时退回 'me|h:<SHA1(去标记正文)>'；
#   * 位置下标、扫描时刻、易变 UI 文本都不参与身份。
#
# 无可靠时间的事件（spec §3.1 第 5 条）：用**首次观察时刻**建立一次保守窗口，该时刻随事件身份
#   持久化并标记来源；同一条重扫、重启、换位置都不会重新赋时。
#
# 兼容（spec §3.1 第 8 条）：旧 v1/v2 记录不清空。旧的 until（带偏移 ISO）按绝对时刻接管为
#   untilUtc 并写一次 HUMAN-PAUSE-LEGACY-ADOPTED 日志；无法验证时保留原截止，**不**改成 Now+5。
#
# 失败封闭（spec §3.1 第 9 条 / §4.1 第 8 条）：读取/保存/事件同步失败 ⇒ SyncOk=false，调用方本轮不发送。

if (-not (Get-Command Get-SkillPath -ErrorAction SilentlyContinue)) {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.ps1')
}
if (-not (Get-Command Write-JsonDocumentAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'state_store.ps1')
}
if (-not (Get-Command Get-TrustedHumanReplies -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'msg_source.ps1')
}

$script:HumanPauseDefaultMinutes = 5
$script:HumanPauseStoreVersion = 3
# 可靠时间超出"本轮 UTC 时钟 + 容差"⇒ 异常未来时刻：不改写成"刚刚回复"，按首次观察锚点有界处理。
$script:HumanPauseFutureToleranceSec = 120
$script:HumanPauseEventCapPerBuyer = 80

function Get-HumanPauseMinutes {
    $m = Get-SkillConfigValue 'human_pause_minutes' $script:HumanPauseDefaultMinutes
    try { $m = [int]$m } catch { $m = $script:HumanPauseDefaultMinutes }
    if ($m -lt 1) { $m = $script:HumanPauseDefaultMinutes }
    return $m
}

function Get-HumanPauseFile { return (Get-SkillPath 'pause') }

# 显示/元数据用的本机时钟（日志、updatedAt）。计时口径一律走 Get-HumanPauseNowUtc。
function Get-HumanPauseNow { return [datetime]::Now }
# **唯一计时口径**：UTC。夹具覆盖这一个函数即可让整条暂停/等待链跟随注入的 UTC 时钟。
function Get-HumanPauseNowUtc { return [datetime]::UtcNow }

# 任意输入 -> UTC DateTime（Kind=Utc）。无法识别返回 $null。
#   * DateTimeOffset ⇒ UtcDateTime；
#   * Kind=Utc 的 DateTime ⇒ 原样；Kind=Local ⇒ 按本机偏移换算；
#   * Kind=Unspecified 的 DateTime 与无偏移的字符串 ⇒ 按 **UTC** 解释（注入时钟的确定口径，
#     避免把宿主时区叠加到已经用 UTC 表述的夹具时间上）；
#   * 带偏移的字符串 ⇒ 按偏移解析（spec §3.1 第 1 条）。
function ConvertTo-HumanPauseUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.DateTimeOffset]) { return ([System.DateTimeOffset]$Value).UtcDateTime }
    if ($Value -is [System.DateTime]) {
        $d = [System.DateTime]$Value
        if ($d.Kind -eq [System.DateTimeKind]::Utc) { return $d }
        if ($d.Kind -eq [System.DateTimeKind]::Local) { return ([System.DateTimeOffset]$d).UtcDateTime }
        return [System.DateTime]::SpecifyKind($d, [System.DateTimeKind]::Utc)
    }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    $dto = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([System.DateTimeOffset]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dto)) {
        return $dto.UtcDateTime
    }
    return $null
}

function Format-HumanPauseLocal($UtcValue) {
    $u = ConvertTo-HumanPauseUtc $UtcValue
    if (-not $u) { return '' }
    return ([System.DateTime]::SpecifyKind($u, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('HH:mm:ss')
}

function Resolve-HumanPauseNowUtc {
    param($NowUtc, $Now, [bool]$UtcProvided = $false, [bool]$NowProvided = $false)
    if ($UtcProvided -and $null -ne $NowUtc) {
        $u = ConvertTo-HumanPauseUtc $NowUtc
        if ($u) { return $u }
    }
    if ($NowProvided -and $null -ne $Now) {
        $u = ConvertTo-HumanPauseUtc $Now
        if ($u) { return $u }
    }
    return (ConvertTo-HumanPauseUtc (Get-HumanPauseNowUtc))
}

# 兼容包装：旧调用点传 -Now（墙上时钟）。现在统一返回 UTC 绝对时刻。
function Resolve-HumanPauseNow($Now, [switch]$Provided) {
    return (Resolve-HumanPauseNowUtc -Now $Now -NowProvided:([bool]$Provided))
}

function Get-HumanPauseKey([string]$Buyer) {
    if ([string]::IsNullOrWhiteSpace($Buyer)) { return '' }
    return (($Buyer -replace '\s+', ' ').Trim().ToLowerInvariant())
}

# [独立复核 R04] 嵌套字段校验：顶层容器合法不等于内容合法。已有暂停/等待/事件的截止时间、
#   时间字段和分类写坏时必须按 schema 损坏处理（fail-closed），不能被当成"没有暂停"放行。
function Test-HumanPauseStoreNested($Store) {
    foreach ($section in @('pauses','sourceUnknownHolds','interventionEvents')) {
        if (-not $Store -or $Store.PSObject.Properties.Name -notcontains $section) { continue }
        $map = $Store.$section
        if ($null -eq $map) { continue }
        if ($map -is [string] -or $map -is [ValueType]) { return $false }
        $table = ConvertTo-HumanPauseTable $map
        foreach ($k in @($table.Keys)) {
            $entry = $table[$k]
            if ($null -eq $entry) { continue }
            if ($entry -is [string] -or $entry -is [ValueType] -or $entry -is [System.Array]) { return $false }
            if ($section -eq 'interventionEvents') {
                $kind = [string](Get-PauseStoreValue $entry 'kind')
                if ($kind -and $kind -notin @('human','unknown','bot')) { return $false }
                foreach ($field in @('atUtc','firstSeenAtUtc','trustedAnchorUtc','updatedAt','correctedAtUtc')) {
                    $raw = Get-PauseStoreValue $entry $field
                    if ($null -eq $raw) { continue }
                    $text = [string]$raw
                    if ($text -eq '') { continue }
                    if (-not (ConvertTo-HumanPauseUtc $text)) { return $false }
                }
                continue
            }
            foreach ($field in @('untilUtc','until','anchorUtc','lastHumanReplyAt','lastHumanReplyAtUtc','firstSeenAtUtc','startedAt','updatedAt')) {
                $raw = Get-PauseStoreValue $entry $field
                if ($null -eq $raw) { continue }
                # 空串是本模块自己的"无此时间"写法（例如 legacy 接管写的 lastHumanReplyAtUtc=''），
                #   只有**非空但解析不了**的值才是 schema 损坏。
                $text = [string]$raw
                if ($text -eq '') { continue }
                if (-not (ConvertTo-HumanPauseUtc $text)) { return $false }
            }
        }
    }
    return $true
}
function Read-HumanPauseStore {
    $doc = Read-JsonDocument (Get-HumanPauseFile)
    if ($doc.Status -eq 'valid' -and $doc.Data -and ($doc.Data.PSObject.Properties.Name -contains 'pauses')) {
        if($doc.Data.pauses -is [string] -or $null -eq $doc.Data.pauses){return [pscustomobject]@{__status='schema-invalid'}}
        foreach($key in @('pauses','sourceUnknownHolds','interventionEvents')){if($doc.Data.PSObject.Properties.Name -contains $key){$map=$doc.Data.$key;if($map -isnot [Collections.IDictionary] -and $map -isnot [pscustomobject]){return [pscustomobject]@{__status='schema-invalid'}}}}
        if(-not (Test-HumanPauseStoreNested $doc.Data)){return [pscustomobject]@{__status='schema-invalid'}}
        return $doc.Data
    }
    if($doc.Status -eq 'valid'){$doc.Status='schema-invalid'}
    # 损坏/空文件不静默重建：返回空表 + 状态标记，调用方决定是否告警。
    #   missing/empty = 还没有这份状态（合法的新建起点）；corrupt = 必须按故障处理（fail-closed）。
    return [pscustomobject]@{ version = $script:HumanPauseStoreVersion; pauses = [pscustomobject]@{}
                              sourceUnknownHolds = [pscustomobject]@{}; interventionEvents = [pscustomobject]@{}
                              __status = $doc.Status }
}

function ConvertTo-HumanPauseTable($Object) {
    $t = @{}
    if ($null -eq $Object) { return $t }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in @($Object.Keys)) { $t[[string]$k] = $Object[$k] }
        return $t
    }
    foreach ($p in $Object.PSObject.Properties) { $t[$p.Name] = $p.Value }
    return $t
}

function Get-PauseStoreValue($Store, [string]$Name) {
    if ($null -eq $Store) { return $null }
    if ($Store -is [System.Collections.IDictionary]) {
        if ($Store.Contains($Name)) { return $Store[$Name] }
        return $null
    }
    if ($Store.PSObject.Properties.Name -contains $Name) { return $Store.$Name }
    return $null
}

function Save-HumanPauseStore($Store) {
    $pauses = ConvertTo-HumanPauseTable (Get-PauseStoreValue $Store 'pauses')
    $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $Store 'sourceUnknownHolds')
    $events = ConvertTo-HumanPauseTable (Get-PauseStoreValue $Store 'interventionEvents')
    $nowText = (ConvertTo-HumanPauseUtc (Get-HumanPauseNowUtc))
    $payload = [ordered]@{
        version            = $script:HumanPauseStoreVersion
        updatedAt          = $nowText.ToString('o')
        pauses             = $pauses
        sourceUnknownHolds = $holds
        interventionEvents = $events
    }
    $w = Write-JsonDocumentAtomic -Path (Get-HumanPauseFile) -Data $payload -Depth 8
    return $w.Ok
}

function Get-HumanPause([string]$Buyer) {
    $key = Get-HumanPauseKey $Buyer
    if (-not $key) { return $null }
    $store = Read-HumanPauseStore
    $pauses = ConvertTo-HumanPauseTable $store.pauses
    if (-not $pauses.ContainsKey($key)) { return $null }
    return $pauses[$key]
}

# 暂停条目的绝对截止（UTC）。旧记录只有 until（本地 ISO + 偏移）时按绝对时刻接管。
# [独立复核 R04] 条目是否携带可验证截止（untilUtc/until）。缺字段＝合法 legacy；字段存在但解析失败＝schema 损坏。
function Test-HumanPauseEntryHasDeadline($Entry) {
    if (-not $Entry) { return $false }
    foreach ($field in @('untilUtc','until')) {
        $raw = Get-PauseStoreValue $Entry $field
        if ($null -ne $raw -and [string]$raw -ne '') { return $true }
    }
    return $false
}
function Get-HumanPauseUntilUtc($Entry) {
    if (-not $Entry) { return $null }
    $u = $null
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('untilUtc')) { $u = ConvertTo-HumanPauseUtc $Entry['untilUtc'] }
        if (-not $u -and $Entry.Contains('until')) { $u = ConvertTo-HumanPauseUtc $Entry['until'] }
        return $u
    }
    if ($Entry.PSObject.Properties.Name -contains 'untilUtc') { $u = ConvertTo-HumanPauseUtc $Entry.untilUtc }
    if (-not $u -and ($Entry.PSObject.Properties.Name -contains 'until')) { $u = ConvertTo-HumanPauseUtc $Entry.until }
    return $u
}

# =============================================================================================
# 事件身份与事件提取（spec §3.1 第 3/4 条）
# =============================================================================================

function Get-InterventionEventIdentity([string]$Line, [string]$Role = 'me') {
    if ([string]::IsNullOrWhiteSpace($Line)) { return '' }
    $mid=[regex]::Match($Line,'@@MID:([^\s]+)');if($mid.Success){return $Role+'|id:'+$mid.Groups[1].Value}
    $mt = [regex]::Match([string]$Line, '@@MT:([^\s]+)')
    $tsRaw = ''
    if ($mt.Success) { $tsRaw = [string]$mt.Groups[1].Value }
    $body = [regex]::Replace([string]$Line, '@@[A-Za-z]+:[^\s]*', ' ')
    $body = ($body -replace '^\s*\[(BUYER|ME)\]\s*', '').Trim()
    $norm = ($body -replace '\s+', ' ').Trim()
    $h = ''
    if (Get-Command Get-MessageLineFingerprint -ErrorAction SilentlyContinue) { $h = [string](Get-MessageLineFingerprint $norm) }
    else { $h = [string]([Math]::Abs($norm.GetHashCode())) }
    if ($tsRaw) { return ($Role + '|mt:' + $tsRaw + '|h:' + $h) }
    return ($Role + '|h:' + $h)
}

# 逐条时间的绝对时刻（只认 @@MT = epoch 毫秒 / 带偏移时间串）。
function Get-InterventionEventTimeUtc([string]$Line) {
    $mt = [regex]::Match([string]$Line, '@@MT:([^\s]+)')
    if (-not $mt.Success) { return $null }
    $raw = [string]$mt.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw -match '^\d{13}$') { return ([System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$raw)).UtcDateTime }
    if ($raw -match '^\d{10}$') { return ([System.DateTimeOffset]::FromUnixTimeMilliseconds(([long]$raw * 1000))).UtcDateTime }
    return (ConvertTo-HumanPauseUtc $raw)
}

# [2026-10-05 第三轮 spec §6] 同一份快照统一来源分类：人工 / 来源不明 / 已确认机器人三类都用
#   **同一次带下标的遍历**，按当前 Lines 的**真实下标**取 SentMatches。
#   * 不再用 [array]::IndexOf 找重复行的第一处（那会把第二条相同文本的发送证据借给第一条）；
#   * 人工下标不再恒为 -1（那正是"已确认机器人也被当成人工"的根因）；
#   * 下标只服务本次快照的证据对齐，绝不进入持久 Identity。
function Get-InterventionEvents {
    param(
        [string[]]$Lines,
        $SentMatches = $null,
        $NowUtc = $null,
        [switch]$Unknown,
        [switch]$Bot
    )
    $out = New-Object System.Collections.ArrayList
    if (-not $Lines) { return @() }
    $count = @($Lines).Count
    for ($i = 0; $i -lt $count; $i++) {
        $line = [string]$Lines[$i]
        if (-not $line) { continue }
        $sentMatch = $false
        if ($SentMatches -and $SentMatches.ContainsKey($i)) { $sentMatch = [bool]$SentMatches[$i] }
        $cls = Get-MessageSourceClass $line $sentMatch
        if ($Bot) {
            if ($cls.Class -ne 'bot') { continue }
        } elseif ($Unknown) {
            if ($cls.Class -ne 'unknown') { continue }
            if ([string]$cls.Evidence -ne 'timer-marker-only') { continue }
        } else {
            if ($cls.Class -ne 'human') { continue }
        }
        $identity = Get-InterventionEventIdentity $line
        if (-not $identity) { continue }
        $atUtc = Get-InterventionEventTimeUtc $line
        $trust = 'none'
        if ($atUtc) {
            if ($NowUtc -and $atUtc -gt ([datetime]$NowUtc).AddSeconds($script:HumanPauseFutureToleranceSec)) { $trust = 'anomalous-future' }
            else { $trust = 'reliable' }
        }
        $preview = ($line -replace '@@[A-Za-z]+:[^\s]*', ' ').Trim()
        if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) }
        [void]$out.Add([pscustomobject]@{
            Identity   = $identity
            LineIndex  = $i
            AtUtc      = $atUtc
            TimeTrust  = $trust
            TimeSource = $(if ($atUtc) { 'message-mtime-epoch-ms' } else { 'none' })
            Evidence   = [string]$cls.Evidence
            SourceClass = [string]$cls.Class
            Preview    = $preview
            RawLine    = $line
        })
    }
    return @($out.ToArray())
}

# =============================================================================================
# 事件 -> 持久化状态的核心同步（读一次、改一次、写一次；两张表不会互相覆盖）
# =============================================================================================
function Invoke-InterventionEventSync {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [object[]]$HumanEvents = @(),
        [object[]]$UnknownEvents = @(),
        # [spec §6] 同一快照里**已确认**的机器人事件：用于更正历史误判分类（不新增暂停，也不延长）。
        [object[]]$BotEvents = @(),
        $NowUtc = $null,
        [int]$Minutes = 0
    )
    $res = [pscustomobject]@{
        SyncOk = $false; PauseChanged = $false; PauseReason = 'no-trusted-human-reply'; PauseUntilUtc = $null
        HoldChanged = $false; HoldReason = 'no-unknown-event'; HoldUntilUtc = $null
        NewHuman = @(); NewUnknown = @(); Anomalies = @(); UnknownHistory = @(); LegacyAdopted = $false; Error = ''
        CorrectedBotEvents = @()
    }
    $key = Get-HumanPauseKey $Buyer
    if (-not $key) { $res.SyncOk = $true; $res.PauseReason = 'no-buyer'; $res.HoldReason = 'no-buyer'; return $res }
    $nowUtc = ConvertTo-HumanPauseUtc $NowUtc
    if (-not $nowUtc) { $res.Error = 'no-clock'; return $res }
    if ($Minutes -le 0) { $Minutes = Get-HumanPauseMinutes }
    try {
        $store = Read-HumanPauseStore
        $status = [string](Get-PauseStoreValue $store '__status')
        if ($status -in @('corrupt','empty','schema-invalid')) { $res.Error = 'pause-store-corrupt'; return $res }
        $pauses = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'pauses')
        $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'sourceUnknownHolds')
        $allEvents = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'interventionEvents')
        $buyerEvents = @{}
        if ($allEvents.ContainsKey($key)) { $buyerEvents = ConvertTo-HumanPauseTable $allEvents[$key] }
        $dirty = $false
        $anomalies = New-Object System.Collections.ArrayList
        $newHuman = New-Object System.Collections.ArrayList
        $newUnknown = New-Object System.Collections.ArrayList
        $history = New-Object System.Collections.ArrayList

        # ---- [spec §6] 兼容更正：同一持久事件现在有**确切 bot 证据** ⇒ 更正该事件的分类 ----
        #   只更正分类，不全局清暂停、不因为看见机器人就删另一条真实人工造成的暂停。
        $botIds = @{};$botEvidence = @{}
        foreach ($b in @($BotEvents)) {
            if (-not $b) { continue }
            $botIds[[string]$b.Identity] = $true
            $botEvidence[[string]$b.Identity] = [string]$b.Evidence
        }
        $correctedIds = @{}
        foreach ($bk in @($botIds.Keys)) {
            $rec = $null
            if ($buyerEvents.ContainsKey($bk)) { $rec = $buyerEvents[$bk] }
            if ($rec) {
                $kindNow = [string](Get-PauseStoreValue $rec 'kind')
                if ($kindNow -eq 'human' -or $kindNow -eq 'unknown') {
                    $rec | Add-Member -NotePropertyName 'kind' -NotePropertyValue 'bot' -Force
                    $rec | Add-Member -NotePropertyName 'kindEvidence' -NotePropertyValue ([string]$botEvidence[$bk]) -Force
                    $rec | Add-Member -NotePropertyName 'correctedAtUtc' -NotePropertyValue $nowUtc.ToString('o') -Force
                    $rec | Add-Member -NotePropertyName 'correctionEvidence' -NotePropertyValue 'confirmed-send-record' -Force
                    $correctedIds[$bk] = $true
                    $dirty = $true
                }
            } else {
                $buyerEvents[$bk] = [pscustomobject]@{
                    kind = 'bot'; identity = $bk; firstSeenAtUtc = $nowUtc.ToString('o')
                    atUtc = ''; timeSource = 'none'; timeTrust = 'none'; preview = ''
                    kindEvidence = [string]$botEvidence[$bk]
                    updatedAt = $nowUtc.ToString('o')
                }
                $dirty = $true
            }
        }
        if ($correctedIds.Count -gt 0) { $res.CorrectedBotEvents = @($correctedIds.Keys) }

        # ---- 旧记录接管（不清空、不重算，只把绝对截止搬到 untilUtc） ----
        $entry = $null
        if ($pauses.ContainsKey($key)) { $entry = $pauses[$key] }
        if ($entry) {
            # [独立复核 R04] 已经接管过的记录以**可解析的截止**为准：只有 untilUtc 属性但值为空
            #   仍视为未接管（一次有界接管），避免"有空字段但永远不生效"的假状态。
            $hasUtc = [bool](Get-HumanPauseUntilUtc $entry)
            if (-not $hasUtc) {
                $legacyUntil = Get-HumanPauseUntilUtc $entry
                if(-not $legacyUntil){$legacyUntil=$nowUtc.AddMinutes(5);$entry|Add-Member -NotePropertyName trustedAnchorUtc -NotePropertyValue ($nowUtc.ToString('o')) -Force;$entry|Add-Member -NotePropertyName timeTrust -NotePropertyValue 'legacy-first-adoption' -Force}
                if ($legacyUntil) {
                    $entry | Add-Member -NotePropertyName 'untilUtc' -NotePropertyValue ($legacyUntil.ToString('o')) -Force
                    $legacyAt = $null
                    if ($entry.PSObject.Properties.Name -contains 'lastHumanReplyAt') { $legacyAt = ConvertTo-HumanPauseUtc $entry.lastHumanReplyAt }
                    $entry | Add-Member -NotePropertyName 'lastHumanReplyAtUtc' -NotePropertyValue ($(if ($legacyAt) { $legacyAt.ToString('o') } else { '' })) -Force
                    $res.LegacyAdopted = $true
                    $dirty = $true
                }
            }
        }
        $lastAtUtc = $null
        $lastIdentity = ''
        if ($entry) {
            if ($entry.PSObject.Properties.Name -contains 'lastHumanMessageId') { $lastIdentity = [string]$entry.lastHumanMessageId }
            if ($entry.PSObject.Properties.Name -contains 'lastHumanReplyAtUtc') { $lastAtUtc = ConvertTo-HumanPauseUtc $entry.lastHumanReplyAtUtc }
            if (-not $lastAtUtc) { $lastAtUtc = Get-HumanPauseUntilUtc $entry }
        }

        # ---- 人工事件（按绝对时间升序处理；不可靠时间排在最后） ----
        $ordered = @($HumanEvents | Sort-Object -Property @{ Expression = { if ($_.TimeTrust -eq 'reliable' -and $_.AtUtc) { 0 } else { 1 } } }, @{ Expression = { if ($_.AtUtc) { $_.AtUtc } else { [datetime]::MaxValue } } })
        foreach ($e in $ordered) {
            $known = $buyerEvents.ContainsKey([string]$e.Identity)
            $firstSeen = $nowUtc
            if ($known) {
                $rec = $buyerEvents[[string]$e.Identity]
                $fs = $null
                if ($rec.PSObject.Properties.Name -contains 'firstSeenAtUtc') { $fs = ConvertTo-HumanPauseUtc $rec.firstSeenAtUtc }
                if ($fs) { $firstSeen = $fs }
                # [独立复核 R03] 已存在事件同样应用**当前快照的可信分类**（显式来源标记优先，不被覆盖）。
                $kindNow = [string](Get-PauseStoreValue $rec 'kind')
                $kindEvidenceNow = [string](Get-PauseStoreValue $rec 'kindEvidence')
                if ($kindNow -ne 'human' -and $kindEvidenceNow -ne 'explicit-sender-marker') {
                    $rec | Add-Member -NotePropertyName 'kind' -NotePropertyValue 'human' -Force
                    $rec | Add-Member -NotePropertyName 'kindEvidence' -NotePropertyValue ([string]$e.Evidence) -Force
                    $rec | Add-Member -NotePropertyName 'updatedAt' -NotePropertyValue $nowUtc.ToString('o') -Force
                    $dirty = $true
                }
            } else {
                $buyerEvents[[string]$e.Identity] = [pscustomobject]@{
                    kind = 'human'; identity = [string]$e.Identity; firstSeenAtUtc = $nowUtc.ToString('o')
                    atUtc = $(if ($e.AtUtc) { ([datetime]$e.AtUtc).ToString('o') } else { '' })
                    timeSource = [string]$e.TimeSource; timeTrust = [string]$e.TimeTrust; preview = [string]$e.Preview
                    kindEvidence = [string]$e.Evidence
                    updatedAt = $nowUtc.ToString('o')
                }
                [void]$newHuman.Add([string]$e.Identity)
                $dirty = $true
            }
            if ([string]$e.TimeTrust -eq 'anomalous-future') {
                [void]$anomalies.Add([pscustomobject]@{ Identity = [string]$e.Identity; Reason = 'future-message-time'; AtUtc = $e.AtUtc; Preview = [string]$e.Preview })
            }
            # 有效回复时刻：可靠时间用绝对时刻；异常未来/无时间用**持久化的首次观察时刻**。
            $effectiveAt = $null
            if ([string]$e.TimeTrust -eq 'reliable' -and $e.AtUtc) { $effectiveAt = [datetime]$e.AtUtc }
            else { $effectiveAt = $firstSeen }
            if (-not $effectiveAt) { continue }
            $stored=$buyerEvents[[string]$e.Identity];if($stored.PSObject.Properties.Name -contains 'trustedAnchorUtc'){$effectiveAt=ConvertTo-HumanPauseUtc $stored.trustedAnchorUtc}else{$stored|Add-Member -NotePropertyName trustedAnchorUtc -NotePropertyValue $effectiveAt.ToString('o') -Force}
            if ($entry -and $lastIdentity -and $lastIdentity -eq [string]$e.Identity) {
                # 同一条历史人工消息重扫：保留原截止（绝不因为"又扫到一次"而延长）。
                $res.PauseReason = 'unchanged-same-message'
                continue
            }
            if ($entry -and $lastAtUtc -and $effectiveAt -le $lastAtUtc) {
                # 旧事件 / 相同事件：不更新截止时间。
                $res.PauseReason = 'unchanged-older-message'
                continue
            }
            $until = $effectiveAt.AddMinutes($Minutes)
            $prevUntil = Get-HumanPauseUntilUtc $entry
            if ($entry -and $prevUntil -and $until -le $prevUntil) {
                $res.PauseReason = 'unchanged-later-deadline'
                continue
            }
            $reason = 'started'
            if ($entry) { $reason = 'extended' }
            $startedAt = $nowUtc.ToString('o')
            if ($entry -and ($entry.PSObject.Properties.Name -contains 'startedAt') -and $entry.startedAt) { $startedAt = [string]$entry.startedAt }
            $entry = [pscustomobject]@{
                buyer              = $Buyer
                lastHumanMessageId = [string]$e.Identity
                lastHumanReplyAtUtc = $effectiveAt.ToString('o')
                lastHumanReplyAt   = $effectiveAt.ToString('o')
                untilUtc           = $until.ToString('o')
                # 兼容字段：本地时间 + 偏移的绝对时刻，旧读取方仍能解析。
                until              = ([System.DateTime]::SpecifyKind($until, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('o')
                minutes            = $Minutes
                timeSource         = [string]$e.TimeSource
                timeTrust          = [string]$e.TimeTrust
                clockBasis         = 'utc-absolute'
                startedAt          = $startedAt
                updatedAt          = $nowUtc.ToString('o')
            }
            $pauses[$key] = $entry
            $lastAtUtc = $effectiveAt
            $lastIdentity = [string]$e.Identity
            $res.PauseChanged = $true
            $res.PauseUntilUtc = $until
            $res.PauseReason = $reason
            $dirty = $true
        }

        # ---- 来源不明我方事件（独立等待窗口；同一条不延长，买家补充/重扫/换位置都不影响） ----
        $holdEntry = $null
        if ($holds.ContainsKey($key)) { $holdEntry = $holds[$key] }
        # [独立复核 R04] 合法 legacy 等待记录（既无锚点也无截止）只做**一次**有界接管：
        #   写一次绝对截止与兼容锚点；之后重扫/重启按已存截止处理，不重算、不延长。
        if ($holdEntry -and -not (Test-HumanPauseEntryHasDeadline $holdEntry)) {
            $legacyAnchor = ConvertTo-HumanPauseUtc (Get-PauseStoreValue $holdEntry 'anchorUtc')
            if (-not $legacyAnchor) { $legacyAnchor = $nowUtc }
            $legacyHoldUntil = $legacyAnchor.AddMinutes($Minutes)
            $holdEntry | Add-Member -NotePropertyName 'anchorUtc' -NotePropertyValue ($legacyAnchor.ToString('o')) -Force
            $holdEntry | Add-Member -NotePropertyName 'anchorSource' -NotePropertyValue 'legacy-first-adoption' -Force
            $holdEntry | Add-Member -NotePropertyName 'timeTrust' -NotePropertyValue 'legacy-first-adoption' -Force
            $holdEntry | Add-Member -NotePropertyName 'untilUtc' -NotePropertyValue ($legacyHoldUntil.ToString('o')) -Force
            $holdEntry | Add-Member -NotePropertyName 'until' -NotePropertyValue ($legacyHoldUntil.ToString('o')) -Force
            $res.LegacyAdopted = $true
            $dirty = $true
        }
        $holdUntil = $null
        if ($holdEntry -and ($holdEntry.PSObject.Properties.Name -contains 'until')) { $holdUntil = ConvertTo-HumanPauseUtc $holdEntry.until }
        $holdIdentity = ''
        if ($holdEntry -and ($holdEntry.PSObject.Properties.Name -contains 'lastMessageId')) { $holdIdentity = [string]$holdEntry.lastMessageId }
        $orderedU = @($UnknownEvents | Sort-Object -Property @{ Expression = { if ($_.AtUtc) { $_.AtUtc } else { [datetime]::MaxValue } } })
        foreach ($u in $orderedU) {
            $known = $buyerEvents.ContainsKey([string]$u.Identity)
            $firstSeen = $nowUtc
            if ($known) {
                $rec = $buyerEvents[[string]$u.Identity]
                $fs = $null
                if ($rec.PSObject.Properties.Name -contains 'firstSeenAtUtc') { $fs = ConvertTo-HumanPauseUtc $rec.firstSeenAtUtc }
                if ($fs) { $firstSeen = $fs }
                # [独立复核 R03] 收据在同一快照里已变为歧义（同文同刻多条）时，该事件不再算已确认机器人：
                #   已存在记录按当前可信分类改为 unknown，原锚点保留，等待窗口不从异常未来时刻重算。
                $kindNow = [string](Get-PauseStoreValue $rec 'kind')
                $kindEvidenceNow = [string](Get-PauseStoreValue $rec 'kindEvidence')
                if ($kindNow -ne 'unknown' -and $kindEvidenceNow -ne 'explicit-sender-marker') {
                    $rec | Add-Member -NotePropertyName 'kind' -NotePropertyValue 'unknown' -Force
                    $rec | Add-Member -NotePropertyName 'kindEvidence' -NotePropertyValue ([string]$u.Evidence) -Force
                    $rec | Add-Member -NotePropertyName 'updatedAt' -NotePropertyValue $nowUtc.ToString('o') -Force
                    $dirty = $true
                }
            } else {
                $buyerEvents[[string]$u.Identity] = [pscustomobject]@{
                    kind = 'unknown'; identity = [string]$u.Identity; firstSeenAtUtc = $nowUtc.ToString('o')
                    atUtc = $(if ($u.AtUtc) { ([datetime]$u.AtUtc).ToString('o') } else { '' })
                    timeSource = [string]$u.TimeSource; timeTrust = [string]$u.TimeTrust; preview = [string]$u.Preview
                    kindEvidence = [string]$u.Evidence
                    updatedAt = $nowUtc.ToString('o')
                }
                [void]$newUnknown.Add([string]$u.Identity)
                $dirty = $true
            }
            $anchor = $null
            $anchorSource = ''
            if ([string]$u.TimeTrust -eq 'reliable' -and $u.AtUtc) {
                $at = [datetime]$u.AtUtc
                if ($at -ge $nowUtc.AddMinutes(-1 * $Minutes)) { $anchor = $at; $anchorSource = 'message-time' }
                else {
                    # 可靠但已经过了窗口的历史事件：登记为历史，不重新等待（spec §4.1 第 6 条）。
                    [void]$history.Add([pscustomobject]@{ Identity = [string]$u.Identity; AtUtc = $at; Reason = 'outside-window-history' })
                    continue
                }
            } elseif ([string]$u.TimeTrust -eq 'anomalous-future') {
                [void]$anomalies.Add([pscustomobject]@{ Identity = [string]$u.Identity; Reason = 'future-message-time'; AtUtc = $u.AtUtc; Preview = [string]$u.Preview })
                $anchor = $firstSeen; $anchorSource = 'first-observed'
            } else {
                $anchor = $firstSeen; $anchorSource = 'first-observed'
            }
            if (-not $anchor) { continue }
            $stored=$buyerEvents[[string]$u.Identity];if($stored.PSObject.Properties.Name -contains 'trustedAnchorUtc'){$anchor=ConvertTo-HumanPauseUtc $stored.trustedAnchorUtc}else{$stored|Add-Member -NotePropertyName trustedAnchorUtc -NotePropertyValue $anchor.ToString('o') -Force}
            if ($holdEntry -and $holdIdentity -and $holdIdentity -eq [string]$u.Identity) {
                $res.HoldReason = 'unchanged-same-message'
                continue
            }
            $candidateUntil = $anchor.AddMinutes($Minutes)
            if ($holdEntry -and $holdUntil -and $candidateUntil -le $holdUntil) {
                $res.HoldReason = 'unchanged-later-deadline'
                continue
            }
            $reason = 'started'
            if ($holdEntry) { $reason = 'extended-newer-message' }
            $startedAt = $nowUtc.ToString('o')
            if ($holdEntry -and ($holdEntry.PSObject.Properties.Name -contains 'startedAt') -and $holdEntry.startedAt) { $startedAt = [string]$holdEntry.startedAt }
            $holdEntry = [pscustomobject]@{
                buyer         = $Buyer
                lastMessageId = [string]$u.Identity
                anchorUtc     = $anchor.ToString('o')
                anchorSource  = $anchorSource
                timeTrust     = [string]$u.TimeTrust
                untilUtc      = $candidateUntil.ToString('o')
                until         = ([System.DateTime]::SpecifyKind($candidateUntil, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('o')
                minutes       = $Minutes
                startedAt     = $startedAt
                updatedAt     = $nowUtc.ToString('o')
            }
            $holds[$key] = $holdEntry
            $holdUntil = $candidateUntil
            $holdIdentity = [string]$u.Identity
            $res.HoldChanged = $true
            $res.HoldUntilUtc = $candidateUntil
            $res.HoldReason = $reason
            $dirty = $true
        }

        # ---- [spec §6] 更正后的截止重算：当前暂停/等待若是被**已更正为机器人**的那一条事件驱动的，
        #   就按其余真实人工/unknown 事件重算有效截止；没有任何真实事件时只解除该买家的这一个暂停。
        #   绝不延长、绝不动别的买家、绝不动另一条真实人工造成的暂停。
        if ($correctedIds.Count -gt 0 -and $entry -and $lastIdentity -and $correctedIds.ContainsKey($lastIdentity)) {
            $best = $null; $bestId = ''
            foreach ($k2 in @($buyerEvents.Keys)) {
                $r2 = $buyerEvents[$k2]
                if (-not $r2) { continue }
                if ([string](Get-PauseStoreValue $r2 'kind') -ne 'human') { continue }
                $t = Get-TrustedInterventionAnchor $r2
                if (-not $t) { $t = ConvertTo-HumanPauseUtc (Get-PauseStoreValue $r2 'firstSeenAtUtc') }
                if ($t -and ((-not $best) -or ($t -gt $best))) { $best = $t; $bestId = [string]$k2 }
            }
            if ($best) {
                $until = $best.AddMinutes($Minutes)
                $entry = [pscustomobject]@{
                    buyer = $Buyer; lastHumanMessageId = $bestId
                    lastHumanReplyAtUtc = $best.ToString('o'); lastHumanReplyAt = $best.ToString('o')
                    untilUtc = $until.ToString('o')
                    until = ([System.DateTime]::SpecifyKind($until, [System.DateTimeKind]::Utc)).ToLocalTime().ToString('o')
                    minutes = $Minutes; timeSource = 'recomputed-after-bot-correction'; timeTrust = 'reliable'
                    clockBasis = 'utc-absolute'; startedAt = $nowUtc.ToString('o'); updatedAt = $nowUtc.ToString('o')
                }
                $pauses[$key] = $entry
                $res.PauseChanged = $true
                $res.PauseUntilUtc = $until
                $res.PauseReason = 'recomputed-after-bot-correction'
            } else {
                $pauses.Remove($key) | Out-Null
                $res.PauseChanged = $true
                $res.PauseUntilUtc = $null
                $res.PauseReason = 'bot-correction-removed-misclassified-pause'
            }
            $dirty = $true
        }
        if ($correctedIds.Count -gt 0 -and $holdEntry -and $holdIdentity -and $correctedIds.ContainsKey($holdIdentity)) {
            $best=$null;$bestId=''
            foreach($eventId in @($buyerEvents.Keys)){$record=$buyerEvents[$eventId];if((Get-PauseStoreValue $record kind) -ne 'unknown'){continue};$anchor=Get-TrustedInterventionAnchor $record;if($anchor -and (-not $best -or $anchor -gt $best)){$best=$anchor;$bestId=$eventId}}
            if($best){$until=$best.AddMinutes($Minutes);$holds[$key]=[pscustomobject]@{buyer=$Buyer;lastMessageId=$bestId;anchorUtc=$best.ToString('o');untilUtc=$until.ToString('o');until=$until.ToString('o');minutes=$Minutes};$res.HoldUntilUtc=$until;$res.HoldReason='recomputed-after-bot-correction'}
            else{$holds.Remove($key)|Out-Null;$res.HoldUntilUtc=$null;$res.HoldReason='bot-correction-removed-misclassified-hold'}
            $res.HoldChanged=$true
            $dirty = $true
        }

        # ---- 事件表按买家限量，避免无限膨胀（保留最近 N 条） ----
        if ($buyerEvents.Count -gt $script:HumanPauseEventCapPerBuyer) {
            $keep = @($buyerEvents.Keys | Sort-Object -Property @{ Expression = { $k = $_; $r = $buyerEvents[$k]; if ($r.PSObject.Properties.Name -contains 'firstSeenAtUtc') { [string]$r.firstSeenAtUtc } else { '' } } } | Select-Object -Last $script:HumanPauseEventCapPerBuyer)
            $trimmed = @{}
            foreach ($k in $keep) { $trimmed[$k] = $buyerEvents[$k] }
            $buyerEvents = $trimmed
            $dirty = $true
        }
        $allEvents[$key] = $buyerEvents

        if ($dirty) {
            $ok = Save-HumanPauseStore ([ordered]@{
                version = $script:HumanPauseStoreVersion; updatedAt = $nowUtc.ToString('o')
                pauses = $pauses; sourceUnknownHolds = $holds; interventionEvents = $allEvents
            })
            if (-not $ok) { $res.Error = 'store-write-failed'; return $res }
        }
        $res.NewHuman = @($newHuman.ToArray())
        $res.NewUnknown = @($newUnknown.ToArray())
        $res.Anomalies = @($anomalies.ToArray())
        $res.UnknownHistory = @($history.ToArray())
        $res.SyncOk = $true
        return $res
    } catch {
        $res.Error = $_.Exception.Message
        return $res
    }
}

# 从会话行里识别可信人工回复并据此开始/延长暂停。返回
#   @{ Started; Changed; Until; UntilUtc; Reason; HumanIndex; Identity; HumanCount; SyncOk; Anomalies }
function Update-HumanPauseFromLines {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [string[]]$Lines,
        $SentMatches = $null,
        $Now = $null,
        $NowUtc = $null,
        $Conversation = $null
    )
    $out = [pscustomobject]@{
        Started = $false; Changed = $false; Until = $null; UntilUtc = $null; Reason = 'no-trusted-human-reply'
        HumanIndex = -1; Identity = ''; HumanCount = 0; SyncOk = $true; Anomalies = @(); LegacyAdopted = $false
    }
    try {
        $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
        if (-not $nowUtc) { $out.SyncOk = $false; $out.Reason = 'no-clock'; return $out }
        $useLines = $Lines
        if (($null -eq $useLines -or @($useLines).Count -eq 0) -and $Conversation -and $Conversation.Lines) { $useLines = @($Conversation.Lines) }
        $humans = @(Get-InterventionEvents -Lines $useLines -SentMatches $SentMatches -NowUtc $nowUtc)
        if ($humans.Count -eq 0) { return $out }
        $sync = Invoke-InterventionEventSync -Buyer $Buyer -HumanEvents $humans -NowUtc $nowUtc
        $out.SyncOk = [bool]$sync.SyncOk
        $out.Anomalies = @($sync.Anomalies)
        $out.LegacyAdopted = [bool]$sync.LegacyAdopted
        if (-not $out.SyncOk) { $out.Reason = ('sync-failed: ' + [string]$sync.Error); return $out }
        $last = $humans[$humans.Count - 1]
        $out.HumanCount = $humans.Count
        $out.Identity = [string]$last.Identity
        $active = Test-HumanPauseActive -Buyer $Buyer -NowUtc $nowUtc
        $out.Changed = [bool]$sync.PauseChanged
        $out.Reason = [string]$sync.PauseReason
        $out.UntilUtc = $active.Until
        $out.Until = $active.Until
        $out.Started = ((($out.Reason -eq 'started') -or ($out.Reason -eq 'extended')) -and [bool]$active.Active)
        # HumanIndex 只作日志用途：位置下标不参与任何状态判定（取本次快照的**真实下标**，
        #   不再用 IndexOf 找重复行的第一处）。
        $out.HumanIndex = [int]$last.LineIndex
        return $out
    } catch {
        $out.SyncOk = $false
        $out.Reason = ('sync-error: ' + $_.Exception.Message)
        return $out
    }
}

# 兼容入口（规则登记 R-HUMAN-PAUSE-5MIN 的生产消费方）：直接按『一条可信人工回复事件』
#   开始/延长暂停。身份由调用方给出（真实平台消息身份，或规范化原文 + 可靠逐条时间构成的身份）。
#   计时口径与 Update-HumanPauseFromLines 完全一致：until = 该回复的**绝对时刻** + 5 分钟。
function Start-HumanPause {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$HumanReplyIdentity,
        [datetime]$HumanReplyAt = [datetime]::MinValue,
        $HumanReplyAtUtc = $null,
        [int]$Minutes = 0,
        $Now = $null,
        $NowUtc = $null
    )
    $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
    $atUtc = ConvertTo-HumanPauseUtc $HumanReplyAtUtc
    if (-not $atUtc) { $atUtc = ConvertTo-HumanPauseUtc $HumanReplyAt }
    $trust = 'reliable'
    if (-not $atUtc) { $atUtc = $nowUtc; $trust = 'none' }
    $ev = [pscustomobject]@{ Identity = $HumanReplyIdentity; AtUtc = $atUtc; TimeTrust = $trust
                             TimeSource = $(if ($trust -eq 'reliable') { 'explicit' } else { 'none' }); Preview = ''; RawLine = '' }
    $sync = Invoke-InterventionEventSync -Buyer $Buyer -HumanEvents @($ev) -NowUtc $nowUtc -Minutes $Minutes
    $until = $null
    if ($sync.SyncOk) {
        $active = Test-HumanPauseActive -Buyer $Buyer -NowUtc $nowUtc
        $until = $active.Until
    }
    return [pscustomobject]@{ Changed = [bool]$sync.PauseChanged; Until = $until; UntilUtc = $until; Reason = [string]$sync.PauseReason; Entry = (Get-HumanPause $Buyer); SyncOk = [bool]$sync.SyncOk }
}
# =============================================================================================
# 来源不明我方消息的保守等待状态 source_unknown_hold（spec §4.1 第 4/5/6 条）
# =============================================================================================
function Get-SourceUnknownHold([string]$Buyer) {
    $key = Get-HumanPauseKey $Buyer
    if (-not $key) { return $null }
    $store = Read-HumanPauseStore
    $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'sourceUnknownHolds')
    if (-not $holds.ContainsKey($key)) { return $null }
    return $holds[$key]
}

# 记录/更新等待窗口。返回 @{ Changed; Until; UntilUtc; Reason; Entry; SyncOk }
function Set-SourceUnknownHold {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        [Parameter(Mandatory = $true)][string]$MessageIdentity,
        [int]$Minutes = 0,
        $Now = $null,
        $NowUtc = $null,
        $AnchorUtc = $null,
        [string]$TimeTrust = '',
        [switch]$EventIsNew
    )
    $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
    if ($Minutes -le 0) { $Minutes = Get-HumanPauseMinutes }
    $atUtc = ConvertTo-HumanPauseUtc $AnchorUtc
    if (-not $atUtc) { $atUtc = $nowUtc }
    $ev = [pscustomobject]@{ Identity = $MessageIdentity; AtUtc = $atUtc; TimeTrust = $(if ($TimeTrust) { $TimeTrust } else { 'none' }); TimeSource = 'explicit'; Preview = ''; RawLine = '' }
    $sync = Invoke-InterventionEventSync -Buyer $Buyer -UnknownEvents @($ev) -NowUtc $nowUtc -Minutes $Minutes
    $entry = Get-SourceUnknownHold $Buyer
    $until = $null
    if ($entry -and ($entry.PSObject.Properties.Name -contains 'until')) { $until = ConvertTo-HumanPauseUtc $entry.until }
    return [pscustomobject]@{ Changed = [bool]$sync.HoldChanged; Until = $until; UntilUtc = $until; Reason = [string]$sync.HoldReason; Entry = $entry; SyncOk = [bool]$sync.SyncOk }
}

function Test-SourceUnknownHoldActive {
    param([Parameter(Mandatory = $true)][string]$Buyer, $Now = $null, $NowUtc = $null)
    $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
    $e = Get-SourceUnknownHold $Buyer
    if (-not $e) { return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $null; Reason = 'no-hold' } }
    $until = ConvertTo-HumanPauseUtc $e.until
    if (-not $until) { return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $e; Reason = 'unparsable-until' } }
    $remaining = [int][Math]::Ceiling(($until - $nowUtc).TotalSeconds)
    if ($remaining -gt 0) { return [pscustomobject]@{ Active = $true; Until = $until; RemainingSec = $remaining; Entry = $e; Reason = 'active' } }
    return [pscustomobject]@{ Active = $false; Until = $until; RemainingSec = 0; Entry = $e; Reason = 'expired' }
}

function Clear-SourceUnknownHold([string]$Buyer) {
    $key = Get-HumanPauseKey $Buyer
    if (-not $key) { return $false }
    $store = Read-HumanPauseStore
    $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'sourceUnknownHolds')
    if (-not $holds.ContainsKey($key)) { return $false }
    $holds.Remove($key)
    $pauses = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'pauses')
    $events = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'interventionEvents')
    return (Save-HumanPauseStore ([ordered]@{ version = $script:HumanPauseStoreVersion; updatedAt = (ConvertTo-HumanPauseUtc (Get-HumanPauseNowUtc)).ToString('o'); pauses = $pauses; sourceUnknownHolds = $holds; interventionEvents = $events }))
}

# 暂停是否仍然生效。Until/UntilUtc 都是**绝对 UTC 时刻**。返回 @{ Active; Until; RemainingSec; Entry; Reason }
function Test-HumanPauseActive {
    param([Parameter(Mandatory = $true)][string]$Buyer, $Now = $null, $NowUtc = $null)
    $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
    $e = Get-HumanPause $Buyer
    if (-not $e) { return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $null; Reason = 'no-pause' } }
    $until = Get-HumanPauseUntilUtc $e
    if (-not $until) { return [pscustomobject]@{ Active = $false; Until = $null; RemainingSec = 0; Entry = $e; Reason = 'unparsable-until' } }
    $remaining = [int][Math]::Ceiling(($until - $nowUtc).TotalSeconds)
    if ($remaining -gt 0) { return [pscustomobject]@{ Active = $true; Until = $until; RemainingSec = $remaining; Entry = $e; Reason = 'active' } }
    return [pscustomobject]@{ Active = $false; Until = $until; RemainingSec = 0; Entry = $e; Reason = 'expired' }
}

function Clear-HumanPause([string]$Buyer) {
    $key = Get-HumanPauseKey $Buyer
    if (-not $key) { return $false }
    $store = Read-HumanPauseStore
    $pauses = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'pauses')
    if (-not $pauses.ContainsKey($key)) { return $false }
    $pauses.Remove($key)
    $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'sourceUnknownHolds')
    $events = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'interventionEvents')
    return (Save-HumanPauseStore ([ordered]@{ version = $script:HumanPauseStoreVersion; updatedAt = (ConvertTo-HumanPauseUtc (Get-HumanPauseNowUtc)).ToString('o'); pauses = $pauses; sourceUnknownHolds = $holds; interventionEvents = $events }))
}

# =============================================================================================
# [spec §4.1 第 1/2/7 条] 共用编排接口：读取与发送前**共用**同一次同步。
#   顺序固定：规范化快照与来源 → 同步全部新可信人工/unknown 我方事件 → 检查暂停/等待。
#   返回 HumanPauseActive / UnknownHoldActive / UntilUtc / SyncOk / Reason，供两处消费。
# =============================================================================================
function Sync-ConversationInterventionState {
    param(
        [Parameter(Mandatory = $true)][string]$Buyer,
        $Conversation = $null,
        [string[]]$Lines = $null,
        $SentMatches = $null,
        $Now = $null,
        $NowUtc = $null,
        [int]$Minutes = 0
    )
    $out = [pscustomobject]@{
        SyncOk = $false; Buyer = $Buyer; NowUtc = $null
        HumanPauseActive = $false; HumanPauseUntilUtc = $null; HumanPauseReason = ''
        UnknownHoldActive = $false; UnknownHoldUntilUtc = $null; UnknownHoldReason = ''
        NewHumanEvents = @(); NewUnknownEvents = @(); Anomalies = @(); UnknownHistory = @()
        CorrectedBotEvents = @()
        LegacyAdopted = $false; Reason = ''; Error = ''
    }
    try {
        $nowUtc = Resolve-HumanPauseNowUtc -NowUtc $NowUtc -UtcProvided:($PSBoundParameters.ContainsKey('NowUtc')) -Now $Now -NowProvided:($PSBoundParameters.ContainsKey('Now'))
        if (-not $nowUtc) { $out.Error = 'no-clock'; $out.Reason = 'no-clock'; return $out }
        $out.NowUtc = $nowUtc
        $useLines = $Lines
        if (($null -eq $useLines -or @($useLines).Count -eq 0) -and $Conversation -and $Conversation.Lines) { $useLines = @($Conversation.Lines) }
        $humans = @(Get-InterventionEvents -Lines $useLines -SentMatches $SentMatches -NowUtc $nowUtc)
        $unknowns = @(Get-InterventionEvents -Lines $useLines -SentMatches $SentMatches -NowUtc $nowUtc -Unknown)
        # 同一份快照、同一套来源判据：已确认机器人事件用于更正历史误判分类（不产生暂停/等待）。
        $bots = @(Get-InterventionEvents -Lines $useLines -SentMatches $SentMatches -NowUtc $nowUtc -Bot)
        $sync = Invoke-InterventionEventSync -Buyer $Buyer -HumanEvents $humans -UnknownEvents $unknowns -BotEvents $bots -NowUtc $nowUtc -Minutes $Minutes
        $out.LegacyAdopted = [bool]$sync.LegacyAdopted
        $out.Anomalies = @($sync.Anomalies)
        $out.UnknownHistory = @($sync.UnknownHistory)
        $out.NewHumanEvents = @($sync.NewHuman)
        $out.NewUnknownEvents = @($sync.NewUnknown)
        if ($sync.PSObject.Properties.Name -contains 'CorrectedBotEvents') { $out.CorrectedBotEvents = @($sync.CorrectedBotEvents) }
        if (-not $sync.SyncOk) {
            $out.SyncOk = $false
            $out.Reason = ('sync-failed: ' + [string]$sync.Error)
            $out.Error = [string]$sync.Error
            return $out
        }
        $p = Test-HumanPauseActive -Buyer $Buyer -NowUtc $nowUtc
        $h = Test-SourceUnknownHoldActive -Buyer $Buyer -NowUtc $nowUtc
        $out.HumanPauseActive = [bool]$p.Active
        $out.HumanPauseUntilUtc = $p.Until
        $out.HumanPauseReason = [string]$p.Reason
        $out.UnknownHoldActive = [bool]$h.Active
        $out.UnknownHoldUntilUtc = $h.Until
        $out.UnknownHoldReason = [string]$h.Reason
        $out.SyncOk = $true
        $out.Reason = $(if ($out.HumanPauseActive) { 'human-pause-active' } elseif ($out.UnknownHoldActive) { 'unknown-hold-active' } else { 'clear' })
        return $out
    } catch {
        $out.SyncOk = $false
        $out.Error = $_.Exception.Message
        $out.Reason = ('sync-error: ' + $_.Exception.Message)
        return $out
    }
}

function Get-HumanPauseSummary {
    $store = Read-HumanPauseStore
    $pauses = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'pauses')
    $holds = ConvertTo-HumanPauseTable (Get-PauseStoreValue $store 'sourceUnknownHolds')
    return [pscustomobject]@{ Count = $pauses.Count; Holds = $holds.Count; Version = [int](Get-PauseStoreValue $store 'version'); Status = [string](Get-PauseStoreValue $store '__status') }
}

function Get-TrustedInterventionAnchor($Record) {
    $anchor=ConvertTo-HumanPauseUtc (Get-PauseStoreValue $Record trustedAnchorUtc)
    if($anchor){return $anchor}
    if((Get-PauseStoreValue $Record timeTrust) -eq 'reliable'){$anchor=ConvertTo-HumanPauseUtc (Get-PauseStoreValue $Record atUtc);if($anchor){return $anchor}}
    return (ConvertTo-HumanPauseUtc (Get-PauseStoreValue $Record firstSeenAtUtc))
}
