# reply_engine.ps1 - Pure decision, dedup and validation primitives for the reply chain.
#
# SCOPE (spec 5): this file holds the small, side-effect-free primitives that more than one caller
# needs. It reads no files, touches no page and calls no model.
#
# WHAT WAS REMOVED HERE (2026-10-03, spec 5 "one authoritative implementation" + spec 6 "remove
# duplicated wording and retired production branches"):
#   - Detect-Lang and the es/pt/fr reply branches. Get-ReplyLang has returned a hard 'en' since the
#     American-English-only decision (spec 4.3), so every non-English branch was unreachable
#     production code; Detect-Lang's only remaining caller was its own regression assertion.
#   - New-ReplyContext and the three intent resolvers (Resolve-IntentEarly / -Info / -Data), plus
#     Build-MissingQuestion and Resolve-Template. They were a SECOND, competing implementation of
#     business policy: their own ask limits, their own scenario wording, their own idea of when to
#     push for information. Business policy now has exactly one implementation in
#     lib\reply_policy.ps1 (decision) and lib\reply_gen.ps1 (wording and fallbacks), shared by the
#     model path and the fallback path.
#   - Generate-Reply, the entry point of that second engine. Fallback wording is now
#     lib\reply_gen.ps1::Get-ScenarioFallback, driven by the same decision object the model path uses.
#   - $script:SupplierContactAsk, a duplicate of the first sentence in Get-DimensionGuidance below.
#
# Kept deliberately: Get-MissingInfo and Get-PromisedFields are still consumed (the policy layer
# uses Get-PromisedFields; Get-MissingInfo remains under regression test).
#
# Callers: monitor.ps1, auto_optimize.ps1, analyze_replies.ps1, lib\msg_norm.ps1,
#          lib\reply_policy.ps1, lib\reply_gen.ps1, lib\send.ps1 and tests\.

# 统一回复语言：当前强制美式英文（规则引擎所有多语言分支走 en）
function Get-ReplyLang { return 'en' }

# 信息缺口核对：返回缺失项列表
function Get-MissingInfo([string]$ctxText, [object]$dataToCollect) {
    $ctx = $ctxText.ToLower()
    $missing = New-Object System.Collections.ArrayList
    foreach ($item in $dataToCollect) {
        $it = $item.ToString().ToLower()
        if ($it -match 'weight|重量|kg') {
            if ($ctx -notmatch '(weight|peso|gross|公斤|千克)|\d+\s*(kg|kgs|kilo|kilos)\b') { [void]$missing.Add("weight (kg)") }
        } elseif ($it -match 'dimension|尺寸|package') {
            if ($ctx -notmatch '(dimension|tamanho|medidas|尺寸)|\d+\s*[x×*]\s*\d+|\d+\s*(cm|mm)\b') { [void]$missing.Add("packaging dimensions (L*W*H)") }
        } elseif ($it -match 'image|图片|reference') {
            if ($ctx -notmatch 'image|photo|pic|picture|foto|imagen|图片|图') { [void]$missing.Add("reference images") }
        } elseif ($it -match 'address|地址|recipient') {
            if ($ctx -notmatch 'address|addr|calle|rua|street|avenue|road|endere|direcci|地址|邮编|cep|postal|city|ciudad|cidade|country|país|pais|deliver to|consignee|destinatario') { [void]$missing.Add("recipient's address") }
        }
    }
    return $missing
}

# 买家承诺字段检测:买家说 will send/share/provide + 字段词 → 返回承诺字段列表(该字段不再追问)
function Get-PromisedFields([string[]]$context) {
    $promised = New-Object System.Collections.ArrayList
    foreach ($_line in $context) {
        if ($_line -match '^\[BUYER\]') {
            $lc = $_line.ToLower()
            if ($lc -notmatch 'already|sent|provided|attached|here is|here are') {
                if ($lc -match '(will|gonna|going to|let me|i.?ll|i will|as soon as|tomorrow|later).*(weight|kg|peso|公斤|千克)') { if ($promised -notcontains 'weight') { [void]$promised.Add('weight') } }
                if ($lc -match '(will|gonna|going to|let me|i.?ll|i will|as soon as|tomorrow|later).*(dimension|size|尺寸|medida|\d+\s*cm)') { if ($promised -notcontains 'dimension') { [void]$promised.Add('dimension') } }
                if ($lc -match '(will|gonna|going to|let me|i.?ll|i will|as soon as|tomorrow|later).*(address|addr|地址|calle|street|rua)') { if ($promised -notcontains 'address') { [void]$promised.Add('address') } }
                if ($lc -match '(will|gonna|going to|let me|i.?ll|i will|as soon as|tomorrow|later).*(image|photo|picture|图片)') { if ($promised -notcontains 'image') { [void]$promised.Add('image') } }
                if ($lc -match '(will|gonna|going to|let me|i.?ll|i will|as soon as|tomorrow|later).*(supplier|供应商|fornecedor|proveedor)') { if ($promised -notcontains 'supplier') { [void]$promised.Add('supplier') } }
            }
        }
    }
    return $promised
}

# state 键标准化：去空白 + 小写，避免大小写/空格差异导致 dedup 失效
function Get-StateKey([string]$name) {
    return $name.Trim().ToLowerInvariant()
}

# 尺寸引导话术(2026-09-26 更像真人销售 S4/§12.2): "买家说没有尺寸/量不了"时的**唯一话术定义处**。
# 依据: 实测 86.4% 的买家从未给过尺寸, 而尺寸是报价硬需求(不能用重量+件数代替)。
# 主推 = 主动提出"我直接联系供应商"(替买家干活 + 顺手拿到供应商联系方式 + 供应商手上有装箱数据);
# 三种退一步说法仅在"买家没有供应商/不愿意给/就是个普通纸箱"时用。
# 消费方(2026-10-03 起): lib\reply_gen.ps1::Get-ScenarioFallback 与 lib\reply_policy.ps1 的
#   dimension_missing 场景、reply_scenarios.md 的 dimension_missing 小节、tests\dimension_guidance.tests.ps1。
#   (旧的 reply_playbook.md 已归档到 docs\archive\；它从未被真正加载过。)
# ⚠️ 本函数**只提供话术**, 不含任何价格/区间/折扣; 机器人在任何情况下不得声称"已联系供应商"。
function Get-DimensionGuidance {
    return @{
        primary = "If you can share your supplier's contact, I can confirm the cargo details with them directly - that way I get you an accurate quote faster, and you don't have to go back and forth."
        fallbacks = @(
            @{ case = 'goods still at the factory / buyer is a middleman'; text = "No problem - if it's easier, just the carton sizes from the factory's packing list would do." },
            @{ case = 'buyer will not share the contact';                 text = "Understood, no pressure. A rough size is fine to start - we can adjust it once the cargo reaches our warehouse." },
            @{ case = 'just an ordinary carton, easy to measure';         text = "If it's a carton, just the L x W x H in cm is enough." }
        )
    }
}

# 尺寸引导的"禁止暗示"检测(纯函数, 供发送前检查与测试共用):
# 命中 = 回复里出现了"没尺寸也能报价/也可以报"这类暗示 ⇒ 违反定价红线(D1/D7), 必须重写。
function Test-NoDimensionQuoteHint([string]$text) {
    if (-not $text) { return $false }
    $pats = @(
        'quote you without the dimensions',
        'quote without the dimensions',
        'quote you without dimensions',
        'can quote without dimensions',
        "don't need the dimensions",
        'do not need the dimensions',
        'no need for the dimensions',
        'dimensions are not required',
        'dimensions not required',
        'no dimensions needed',
        'without sizes we can still quote',
        'we can quote you anyway'
    )
    foreach ($p in $pats) { if ($text -match [regex]::Escape($p)) { return $true } }
    # 形态2: "no need ... dimension(s)/size(s)/measure" 这类组合(含"不用量了也能往下走"的暗示)
    if ($text -match '(?i)no need\b[^.!?]{0,40}\b(dimension|size|measur)') { return $true }
    return $false
}

# 稳定哈希：去翻译标记/标点/空白/大小写，保证同一买家消息两次抓取 hash 一致
# 注意顺序：先删标点再压空白（先压空白会留下"标点删除后的双空格"导致 hash 不一致）
function Get-StableHash([string]$text) {
    $norm = $text
    foreach ($tok in @('由阿里提供','由阿里翻译提供','翻译中…','翻译中','Revert','反馈','已读','未读')) {
        $norm = $norm.Replace($tok, '')
    }
    $norm = $norm -replace '[,.;:!?¡¿"''()\-]', ''
    $norm = $norm -replace '[\s\u00A0\u200B]+', ' '
    $norm = $norm.Trim().ToLowerInvariant()
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.MD5]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($norm))).Replace('-','')
}

# ts 归一化(epoch ms,纯函数):13 位数字=ms 原样;10 位数字=秒*1000;
# 'yyyy-MM-dd HH:mm:ss' / 'yyyy/MM/dd HH:mm:ss' 按本地时区转 epoch ms;无法解析返回 $null
function ConvertTo-EpochMs([string]$ts) {
    if ([string]::IsNullOrWhiteSpace($ts)) { return $null }
    $t = $ts.Trim()
    if ($t -match '^\d{13}$') { return [long]$t }
    if ($t -match '^\d{10}$') { return ([long]$t * 1000) }
    foreach ($fmt in @('yyyy-MM-dd HH:mm:ss','yyyy/MM/dd HH:mm:ss')) {
        try {
            $d = [datetime]::ParseExact($t, $fmt, [Globalization.CultureInfo]::InvariantCulture)
            return [long](([datetimeoffset]$d).ToUnixTimeMilliseconds())
        } catch { }
    }
    return $null
}

# 去重判定(纯函数):文本 hash 相同才可能判已回复;任一侧 ts 缺失/不可解析→保守判已回复(防重复发送);
# 两侧均可解析时,仅当新 ts 严格大于 saved ts 才视为新消息(买家重发同文案且时间戳更新)。
function Test-AlreadyReplied([string]$savedHash, [string]$hText, [string]$ts) {
    if ([string]::IsNullOrWhiteSpace($savedHash)) { return $false }
    $parts = $savedHash -split '\|', 2
    $savedText = $parts[0]
    $savedTs = ''
    if ($parts.Count -gt 1) { $savedTs = $parts[1] }
    if ($savedText -ne $hText) { return $false }
    $cur = ConvertTo-EpochMs $ts
    $old = ConvertTo-EpochMs $savedTs
    if ($null -eq $cur -or $null -eq $old) { return $true }
    return ($cur -le $old)
}

# [FIX-DUP 2026-09-25] 归一化买家文本/列表预览:剔除 UI 噪声与译文的重复呈现,保证同一消息跨抽取一致。
#   顺序:翻译标记(含短形态"由阿里提供") -> 译文尾段 -> 时间/日期 -> 单独出现的未读计数数字 -> 整段对半重复 -> 压空白。
#   译文尾段剥离依据(只读 CDP 实测 DOM):.content-with-translation.text-content
#     > [0] .session-rich-content.text(原文,cjk=0) / [1] .session-translate(译文,cjk>0),
#   父节点 innerText = 原文 + 译文(未渲染译文时 = 原文×2);仅当 CJK 之前存在非空非 CJK 前缀时才剥离,
#   纯中文原文(首字符即 CJK)不剥离,避免把中文买家消息归一化成空串。
#   注意:本函数只用于"同一性判定",不用于展示文本;不转小写(大小写差异视为不同消息)。
function Get-NormalizedMsgText([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $s = $text.Trim()
    if ($s.Length -eq 0) { return '' }
    # 1) 翻译标记与状态词(大小写不敏感;长形态先删)
    foreach ($tok in @('由阿里翻译提供','由阿里提供','翻译中…','翻译中','Revert','[未读]','反馈','已读','未读','自动接待发送','系统自动发送')) {
        $s = [regex]::Replace($s, [regex]::Escape($tok), ' ', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    # 2) 译文尾段剥离(见函数头注释)
    $cjk = [regex]::Match($s, '[\u4e00-\u9fff]')
    if ($cjk.Success -and $cjk.Index -gt 0) { $s = $s.Substring(0, $cjk.Index) }
    # 3) 时间与日期
    $s = $s -replace '\d{1,2}:\d{2}',' '
    $s = $s -replace '\d{4}[-/]\d{1,2}[-/]\d{1,2}',' '
    # 4) 单独出现的未读计数数字(词边界内的纯数字串;不碰 UN3481 / 13kg 这类内嵌数字)
    $s = $s -replace '\b\d+\b',' '
    # 5) 整段对半重复压缩(只处理"整段对半重复"这一种形态;按原始串截断以保留空格形态)
    $squashed = $s -replace '[\s\u00A0\u200B]+',''
    if ($squashed.Length -ge 2 -and (($squashed.Length % 2) -eq 0)) {
        $half = [int]($squashed.Length / 2)
        if ($squashed.Substring(0, $half) -ceq $squashed.Substring($half)) {
            $nonWs = [regex]::Matches($s, '[^\s\u00A0\u200B]')
            if ($nonWs.Count -ge $half) {
                $last = $nonWs[$half - 1]
                $s = $s.Substring(0, $last.Index + $last.Length)
            }
        }
    }
    # 6) 压空白(不转小写)
    $s = $s -replace '[\s\u00A0\u200B]+',' '
    return $s.Trim()
}

# [FIX-DUP 2026-09-25] 去重键 = 文本 hash | 买家消息条数(替代不可信的 @@TS:showTime 为会话级时间,
#   会被我们自己发出的回复推大,导致永远判"新消息")。
function Get-DedupKey([string]$normText, [int]$buyerCount) {
    return ((Get-StableHash $normText) + '|' + [string]$buyerCount)
}

# [FIX-DUP 2026-09-25] 已回复判定:文本 hash 相同 且 当前买家条数未增加 → 已回复(不发送)。
#   旧格式(<hash>|<ts>,ts 为合成值或日期)第 2 段无法作为"条数"比较 → 一律按"文本相同即已回复"保守处理。
#   返回 $true = 已回复、不发送;$false = 新消息。
#   $hText 为 Get-StableHash(归一化文本) 的结果(与 $savedKey 第 1 段同口径;见 REPORT §7 偏差记录)。
#   ⚠️ [SPEC-单出口 2026-09-27] **已退役, 不得再用于生产判定**。spec §4.1「必须删掉的旧出口」要求删除
#   本函数在 monitor.ps1 去重块里的**调用**; 调用点已删除, 本函数定义暂时保留(仅为既有回归测试
#   tests\reply_engine.tests.ps1 的规格断言不失效)。「是否回复」的唯一出口是 Test-ShouldReply。
#   新增生产调用点即违反 spec §4.4-1 —— 静态检查见 tests\should_reply.tests.ps1(A8)。
function Test-DedupHit([string]$savedKey, [string]$hText, [int]$buyerCount) {
    if ([string]::IsNullOrWhiteSpace($savedKey)) { return $false }
    $parts = $savedKey -split '\|', 2
    $savedText = [string]$parts[0]
    if ($savedText -ne $hText) { return $false }
    $savedCount = -1
    if ($parts.Count -gt 1) {
        $seg = ([string]$parts[1]).Trim()
        if ($seg -match '^\d+$') {
            $parsed = 0
            if ([int]::TryParse($seg, [ref]$parsed)) { $savedCount = $parsed }
        }
    }
    # 旧格式(ts 形态)或缺失 → 保守判已回复;新格式则要求条数真的增加才算新消息
    if ($savedCount -lt 0) { return $true }
    return ($buyerCount -le $savedCount)
}

# [SPEC-单出口 2026-09-27] ⚠️ 旧判据 Test-NewBuyerMessage 已整体删除(不是改, 是删)。
#   删除理由(spec §2.3/§4.1, 实测):
#     1) 它的回退分支(原第 627-630 行"文本 hash 不同即算新消息")是**第 6 次"修重复"失效的直接原因**:
#        账本第二段不可解析时(旧格式 13 位时间戳 / 该分支未算出条数)退回 hash 比较, 而抽取顺序一漂
#        hash 就变 ⇒ 判"有新消息" ⇒ 对已回复过的会话重发。
#     2) 它构成"是否回复"的第二套出口。spec §3-R2 的取向是**减少出口**, 不是再加一条判据。
#   取而代之的唯一出口是下方 Test-ShouldReply。任何"再补一条判据"的做法都违反 spec §4.4-1。

# 唯一时间策略（2026-10-05 spec 修订旧无条件五分钟条款）。
# 账本可用与连续两轮待回复确认先行；调用方将已回复同一条消息的轮数置零。
# 已确认新消息只受上次成功发送起算的秒级下限；其余情况保留分钟冷却和间隔。
# 生产传入 SecondsSinceLastSend，全部时间比较保留精度；旧分钟/布尔入参兼容。
# ConvoLines/LedgerKey/NormLastBuyerHash 仅兼容日志，证据由唯一辅助函数计算。
# 本函数不读文件、不碰页面，人工/顺序/身份/锁/发送保护由生产入口保留。
function Test-ShouldReply {
    [CmdletBinding()]
    param(
        [switch]$PendingListAuthoritative,
        [bool]$AlreadyAnswered = $false,
        # ===== 基础门禁与普通消息时间输入 =====
        [bool]$LedgerUsable           = $false,   # 账本可读(整轮已挡, 此处再挡一道)
        [int]$PendingSeenRounds       = 0,        # 该会话连续在待回复列表里出现的轮数
        [int]$RequiredSeenRounds      = 2,        # 连续确认轮数门槛(§2.1)
        [double]$MinutesSinceLastSend = -1,       # 兼容分钟输入; 保留小数，禁止四舍五入提前放行
        [int]$MinGapMinutes           = 5,        # 最小间隔(配置键 reply_min_gap_min, 缺省 5)
        [bool]$InPostSendCooldown     = $false,   # 是否在发送后冷却期内
        [int]$PostSendCooldownMinutes = 5,        # 发送后冷却(配置键 reply_post_send_cooldown_min, 缺省 5)
        # ===== [SPEC 4.1 2026-10-03] A CONFIRMED NEW message must not be blocked by the
        # old-message cooldown. Spec 4.1: "the 5-minute interval and the cooldown only suppress a
        # repeat response to an OLD message; they must not unconditionally block an already
        # confirmed new message."
        #   ConfirmedNewMessage is only ever set from POSITIVE evidence that the newest buyer
        #   message is not the one we already answered (see Test-ConfirmedNewBuyerMessage). It is
        #   never inferred from a fail-open path.
        #   When it is set, rows 3 and 4 (post-send cooldown / min gap) are SKIPPED and row 4b
        #   applies a small wall-clock floor instead, so two sends still cannot happen back to back
        #   in the same instant. Identity checks, the ledger gate, the 2-round transient defence,
        #   the write lock and the page-health gate are all unaffected.
        [bool]$ConfirmedNewMessage    = $false,
        [int]$NewMessageFloorSeconds  = 20,       # 新消息的最小墙钟间隔(秒); <=0 表示不设
        [double]$SecondsSinceLastSend = -1,       # 距上次成功发送的秒数; -1 = 未知/从未发过

        # ===== 仅为日志与既有测试兼容保留; 判定逻辑**不得**再读它们(§2.2 / §3.1) =====
        [string[]]$ConvoLines,
        [string]$LedgerKey,
        [string]$NormLastBuyerHash
    )
    # Current pending-list contract. Legacy arguments remain for compatibility callers.
    if ($PendingListAuthoritative) {
        if (-not $LedgerUsable) { return [pscustomobject]@{Reply=$false;Reason='LEDGER_UNUSABLE'} }
        if ($PendingSeenRounds -lt 1) { return [pscustomobject]@{Reply=$false;Reason='NOT_IN_PENDING_LIST'} }
        if ($AlreadyAnswered) { return [pscustomobject]@{Reply=$false;Reason='ALREADY_ANSWERED'} }
        return [pscustomobject]@{Reply=$true;Reason='IN_PENDING_LIST'}
    }
    # §0.1「连续确认轮数 ... 不可再降」的技术兜底: 传 0/1 一律抬回 2。
    #   没有这一行, 一次误配(或未来某个调用点漏传)就会让 §2.1 的瞬态防线静默失效 —— 那正是本次要修的病根。
    if ($RequiredSeenRounds -lt 2) { $RequiredSeenRounds = 2 }

    # 行 1: 账本(去重状态)不可用 ⇒ fail-closed。
    #   §4.1 裁决 = **方案甲**(保守, 推荐): 账本读不到时补发队列与 state.json 的关联也断了, 发出去可能重复。
    #   故保持 P6: 整轮一条都不发; 本行是同一取向的第二道。
    if (-not $LedgerUsable) {
        return [pscustomobject]@{ Reply = $false; Reason = 'LEDGER_UNUSABLE_FAILCLOSED' }
    }
    # 行 2: 不在待回复列表(轮数 0), 或连续确认轮数不足 ⇒ 不发。
    #   ⚠️ 这是 §2.1 的瞬态防线: 标签切换/虚拟滚动残留通常只存活 1 轮 ⇒ 永远到不了 2。
    if ($PendingSeenRounds -lt $RequiredSeenRounds) {
        return [pscustomobject]@{ Reply = $false; Reason = 'NOT_IN_PENDING_LIST' }
    }
    # 行 3/4 的适用条件: 它们只用于抑制"旧消息"的重复响应。已确认的新消息走行 4b。
    if (-not $ConfirmedNewMessage) {
        # 2026-10-05: production supplies exact seconds from the one successful-send clock.
        # Legacy callers may still supply minutes and the cooldown flag.
        if ($SecondsSinceLastSend -ge 0) {
            $MinutesSinceLastSend = $SecondsSinceLastSend / 60.0
            $InPostSendCooldown = ($SecondsSinceLastSend -lt ($PostSendCooldownMinutes * 60.0))
        }
        # 行 3: 发送后冷却期内 ⇒ 不发。数据面与行 4 共用 $ctx.lastSendAt(调用方传入判定结果)。
        if ($InPostSendCooldown) {
            return [pscustomobject]@{ Reply = $false; Reason = 'POST_SEND_COOLDOWN' }
        }
        # 普通消息距上次成功发送 < 分钟间隔 ⇒ 不发；已确认新消息由秒级分支处理。
        #   -1(= 从未发过)不命中本行; 间隔"刚好等于"最小间隔时放行(严格小于才拦)。
        if ($MinutesSinceLastSend -ge 0 -and $MinutesSinceLastSend -lt $MinGapMinutes) {
            return [pscustomobject]@{ Reply = $false; Reason = 'RATE_MIN_GAP' }
        }
    } else {
        # 新消息默认下限 20 秒，从上次成功发送起算；并非收到新消息再等 20 秒。
        if ($NewMessageFloorSeconds -gt 0 -and $SecondsSinceLastSend -ge 0 -and $SecondsSinceLastSend -lt $NewMessageFloorSeconds) {
            return [pscustomobject]@{ Reply = $false; Reason = 'NEW_MESSAGE_FLOOR' }
        }
    }
    # 行 5: 以上都不命中 ⇒ **在待回复列表里且不在冷却/间隔内 ⇒ 必回**(§0 硬判据 1)。
    return [pscustomobject]@{ Reply = $true; Reason = 'IN_PENDING_LIST' }
}

# [SPEC 4.1 2026-10-03] Positive-evidence test for "the newest buyer message is genuinely new".
#   Returns $true ONLY when the ledger is in the current "<hash>|<count>" format AND the freshly
#   scraped conversation is trusted: count increased, or equal count with changed original hash.
#   A shrinking window, malformed key or untrusted latest identity cannot authorise the bypass.
#   Everything else returns $false (fail-closed), because this result is what authorises skipping
#   the old-message cooldown. In particular an unparseable or legacy ledger key never authorises it.
#   Pure function: no file access, no page access, no side effects.
function Test-ConfirmedNewBuyerMessage {
    [CmdletBinding()]
    param(
        [string]$LedgerKey,
        [int]$BuyerCount = -1,
        [string]$NormLastBuyerHash,
        [bool]$MessageEvidenceTrusted = $false
    )
    if (-not $MessageEvidenceTrusted) { return $false }
    if ($BuyerCount -lt 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($LedgerKey)) { return $false }
    if ([string]::IsNullOrWhiteSpace($NormLastBuyerHash)) { return $false }
    $parts = @([string]$LedgerKey -split '\|')
    if ($parts.Count -ne 2) { return $false }
    if ([string]$parts[1] -notmatch '^\d+$') { return $false }
    $savedCount = 0
    if (-not [int]::TryParse([string]$parts[1], [ref]$savedCount)) { return $false }
    if ($savedCount -lt 1) { return $false }
    $savedHash = [string]$parts[0]
    if ([string]::IsNullOrWhiteSpace($savedHash)) { return $false }
    if ($BuyerCount -gt $savedCount) { return $true }
    if ($BuyerCount -eq $savedCount -and $NormLastBuyerHash -ne $savedHash) { return $true }
    return $false
}

# [FIX-DUP-GUARD 2026-09-27] 「这条买家消息是不是我们已经回过的同一条」—— 纯函数: 只比对证据, 不做决定。
#
#   为什么需要它(实测 2026-09-27 16:31-16:50): 新判据只答"该会话在不在待回复列表里", 按 §2.2 明文
#   不再读账本 ⇒ "账本已经证明这条回过"这一事实**无处落地**。于是买家一句话没变(Buyer-A:
#   buyerMsgs=9 恒定 / lastBuyerHash 恒定 / 列表预览逐字相同)却被连回 3 次
#   (16:31:47 / 16:41:09 / 16:50:35, 间隔 9 分半) —— 每次都走"冷却到期 ⇒ 判据放行 ⇒ 再发一条"。
#
#   调用方用它把「没有待回复的新内容」当作**判据的入参**(连续确认轮数按 0 计), 由唯一出口
#   Test-ShouldReply 返回 NOT_IN_PENDING_LIST; 本函数**不产生**第二个出口, 也不碰页面/文件。
#
#   与旧判据(被 spec §1.2 推翻的那个)的本质差别 —— 也是它不会重演 Ganesan 事故的原因:
#     旧判据问的是"我发过消息了吗"(只看账本); 本函数问的是"**页面此刻抓到的最后一条买家消息**
#     是不是账本记的那条", 且要求**条数与原文 hash 同时**逐字相等。买家只要再说一句, 同一次抓取里
#     的 [BUYER] 行数必增、原文 hash 必变 ⇒ 两个条件同时失效 ⇒ 必定放行(不拦)。
#   证据不足一律返回 $false(**fail-open, 不拦**): 旧格式键(只有 hash)/条数 <1/hash 缺失都算证据不足。
#     拦错的代价是买家永远等不到回复(Ganesan 形态), 比多发一条更重 —— 故只认"逐字对上"这一种正面证据。
function New-PendingReplyHumanTask {
    param([string]$Buyer, [string]$Reason)
    try {
        if (-not (Get-Command New-OrUpdate-HumanTask -ErrorAction SilentlyContinue)) { throw 'pending-reply task store unavailable' }
        $result = New-OrUpdate-HumanTask -Buyer $Buyer -Kind 'pending_reply' -Status 'pending_human' -TriggerMessage $Reason -Note $Reason
        if (-not $result.StoreOk) { throw 'pending-reply task persistence failed' }
        return $result
    } catch {
        Write-Log "PENDING-HUMAN-TASK-STORE-FAIL ${Buyer}: $($_.Exception.Message)"
        return [pscustomobject]@{StoreOk=$false;Error=$_.Exception.Message}
    }
}

function Get-PendingConversationName([string]$Name) {
    return (($Name -replace '[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]', '') -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function Test-PendingBuyerAlreadyAnswered {
    param($LatestBuyer, [string]$LedgerKey, [int]$BuyerCount, [object[]]$Attempts = @())
    $identified = @($Attempts | Where-Object { $_.triggerIdentity -and $_.receipt -and $_.receipt.Valid })
    if ($identified.Count -gt 0 -and $LatestBuyer.IdConfident) {
        return (@($identified | Where-Object { $_.triggerIdentity -ceq $LatestBuyer.StableId }).Count -gt 0)
    }
    # Compatibility for historical ledger entries without a stored trigger identity.
    return (Test-BuyerMsgAlreadyAnswered -LedgerKey $LedgerKey -BuyerCount $BuyerCount -NormLastBuyerHash (Get-StableHash (Get-NormalizedMsgText $LatestBuyer.Orig)))
}

function Test-BuyerMsgAlreadyAnswered {
    [CmdletBinding()]
    param(
        [string]$LedgerKey,          # 账本键, 新格式 "<hash>|<count>"; 旧格式(只有 hash)不参与本判据
        [int]$BuyerCount = -1,       # 同一次抓取里该会话的 [BUYER] 行数
        [string]$NormLastBuyerHash   # 同一次抓取里**最后一条**买家消息(归一化原文)的 hash
    )
    if ($BuyerCount -lt 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($LedgerKey)) { return $false }
    if ([string]::IsNullOrWhiteSpace($NormLastBuyerHash)) { return $false }
    $parts = @([string]$LedgerKey -split '\|')
    if ($parts.Count -lt 2) { return $false }
    if ([string]$parts[1] -notmatch '^\d+$') { return $false }
    # [GH-56 2026-09-29 05:4x] **必须安全解析，不能硬转**：
    #   原写法 `[int]$parts[1]` 在位数超 Int32 时**抛异常**
    #   ("Cannot convert value \"1788799769241\" to type \"System.Int32\"")，而它发生在 monitor 扫描轮的
    #   try 里 ⇒ **整轮扫描被终止**、10 秒后重试又撞同一处（实测 196 次；09-28 09 时一小时 125 次；
    #   受影响会话 4 人：买家P ×134 / 买家M2 ×28 / 买家X ×19 / 买家Y ×15）。
    #   坏值来源：**旧版本**把毫秒时间戳写进了 `HASH|count` 的 count 位（旧备份 state.json 可查：
    #   `"faith s": "C0297…|1788799769241"`）；上面那条 `^\d+$` 守卫只保证"是数字"、**不管范围**。
    #   现在：解析失败/超范围 ⇒ 视为"无法证明已回复" ⇒ 返回 $false（fail-safe，不再抛异常打断整轮）。
    $savedCount = 0
    if (-not [int]::TryParse([string]$parts[1], [ref]$savedCount)) { return $false }
    if ($savedCount -ne $BuyerCount) { return $false }
    if ([string]$parts[0] -ne $NormLastBuyerHash) { return $false }
    return $true
}

# [FIX-DUP-ORDER 2026-09-27] 不依赖位置地挑出"我们上一次回复所针对的那条买家消息"(纯函数)。
#   用途: 日志与 LLM 输入口显示的 latest 必须是我们真正回复过的那条, 而不是恰好排在位置 0 的那条
#   —— 顺序不稳定时位置 0 可能是最旧的消息(实测 02:11:41 的日志就把 6 小时前的旧消息当成了 latest)。
#   判据: 账本 hash 与候选消息的 hash(归一化原文)相同者胜出; 旧格式账本只有 hash, 缺条数, 走同一条路。
#   取不到(首次问询/文本已变/账本为空) -> 返回最后一条(沿用既有"最后一条=最新"的假设, 不引入新判据)。
#   同样为纯函数: 无副作用、不读文件、不碰页面。
function Select-LatestBuyerLine {
    [CmdletBinding()]
    param(
        [string[]]$BuyerLines,
        [string]$SavedKey
    )
    $arr = @($BuyerLines)
    if ($arr.Count -eq 0) { return '' }
    $savedHash = ''
    if (-not [string]::IsNullOrWhiteSpace($SavedKey)) { $savedHash = [string](($SavedKey -split '\|', 2)[0]) }
    if (-not [string]::IsNullOrWhiteSpace($savedHash)) {
        foreach ($l in $arr) {
            $ot = $l
            $m = [regex]::Match($l, '@@OT:([A-Za-z0-9+/=]+)')
            if ($m.Success) { try { $ot = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value)) } catch { $ot = $l } }
            $plain = ($ot -replace '^\[BUYER\]\s*', '' -replace '@@TS:.*$', '' -replace '@@OT:[A-Za-z0-9+/=]+', '').Trim()
            if ((Get-StableHash (Get-NormalizedMsgText $plain)) -eq $savedHash) { return $l }
        }
    }
    return $arr[$arr.Count - 1]
}

# 发送前禁词检测（纯函数；monitor 发送前拦截与回归测试共用定义，避免复制）：
# 大小写不敏感；ASCII 词按词边界匹配并容忍复数/'s 后缀；中文按子串命中；长词先匹配避免短词抢先命中长词。
# 词表主源在 reply_rules.json banned_phrases；$bannedList 缺省/$null 时回退本函数内置默认表（同语料词表）。返回命中词或 $null。
function Test-BannedText([string]$text, $bannedList) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    if (-not $bannedList) { $bannedList = @('manager','senior manager','boss','supervisor','上级','经理','主管') }
    foreach ($__p in ($bannedList | Sort-Object @{ Expression = { ([string]$_).Length }; Descending = $true })) {
        $__ps = [string]$__p
        if ($__ps -match '[\u4e00-\u9fff]') {
            $__pat = '(?i)' + [regex]::Escape($__ps)
            if ($text -match $__pat) { return $__ps }
        } else {
            $__pat = '(?i)(?<![A-Za-z0-9_])(' + [regex]::Escape($__ps) + ')(s|''s)?(?![A-Za-z0-9_])'
            if ($text -match $__pat) { return $__ps }
        }
    }
    return $null
}

# 责任/金钱承诺检测（纯函数；monitor 发送前拦截与回归测试共用）：命中即可能向买家作出费用/责任承诺,须重写或兜底。
# 与 Test-BannedText 的差异:句子级正则而非词表,避免 responsible/cover 等词的正当用法误伤（如 process_overview 模板
# "we will be responsible for delivering the package to your designated address as agreed upon" 属正当业务表述,不得命中）。
# 返回命中的正则模式或 $null。
function Test-FinancialCommitment([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $s = [string]$text
    $pats = @(
        '(?i)(take|taking|accept(ed)?|assume)\s+responsibility\s+for',
        '(?i)responsib(le|ility)\s+(for|of)\s+(this|the|that|your|all|any)\s+(cost|fee|charge|expense|damage|loss|rental)',
        '(?i)((this|that|it)(\x27|\u2019)?s|this is|that is)\s+on\s+us',
        '(?i)((we|i)(\x27|\u2019)?(ll|ve|d)|\bwe( will| would| can| could| should)?)\s+(pay|reimburse|refund|compensate)\s+(you|for|the)',
        '(?i)((we|i)(\x27|\u2019)?(ll|ve|d)|\bwe( will| would| can| could| should)?)\s+cover\s+(you for |(this|that|the|all|any)\s+(cost|fee|charge|expense|rental|damage|loss|amount|\$\s?\d))',
        '(?i)\b(reimburse|refund|compensate|compensation|reimbursement)\b',
        '(?i)out\s+of\s+pocket\s+for',
        '(?i)owe\s+you'
    )
    foreach ($p in $pats) { if ($s -match $p) { return $p } }
    return $null
}
