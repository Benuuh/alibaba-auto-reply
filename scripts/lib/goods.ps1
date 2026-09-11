# lib/goods.ps1 - 买家货物数据判断(从 summarize.ps1 抽取,复用不复制)
# Get-GoodsDataStatus: 判断快照中买家货物 5 项数据齐全度(重量/尺寸/图片/地址/供应商)
# Get-GoodsName: 提取货物品名(产品链接标题优先,其次品名词)
# Get-GoodsDetails: 提取重量/尺寸/地址具体值
# 依赖: config.ps1(Get-SkillPath "data")
# 快照查找(三个函数共用):返回该买家最新的 msgs_*.txt(文件名升序中最后一个匹配,即最新快照)
function Get-LatestSnapshot([string]$buyer, [string]$snapDir = "") {
    if (-not $snapDir) { $snapDir = Get-SkillPath "data" }
    if (-not $snapDir -or -not (Test-Path $snapDir)) { return $null }
    $files = @(Get-ChildItem -Path $snapDir -Filter "msgs_*.txt" -ErrorAction SilentlyContinue | Sort-Object Name)
    $latest = $null
    foreach ($f in $files) {
        try {
            $head = (Get-Content $f.FullName -Encoding UTF8 -TotalCount 1)
            if ($head -eq ("# BUYER: " + $buyer)) { $latest = $f }
        } catch {}
    }
    return $latest
}

# 附件识别 sidecar(B6): data\vision_extract\<buyer>.json 读取(损坏/缺失返回 $null)
function Get-VisionSidecarForGoods([string]$buyer, [string]$dataDir) {
    if (-not $dataDir) { $dataDir = Get-SkillPath "data" }
    if (-not $buyer) { return $null }
    $key = ($buyer.Trim().ToLowerInvariant() -replace '[\\/:*?"<>|]', '_')
    if (-not $key) { return $null }
    $f = Join-Path (Join-Path $dataDir "vision_extract") ($key + ".json")
    if (-not (Test-Path $f)) { return $null }
    try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-GoodsDataStatus([string]$buyer, [string]$snapDir = "") {
    $side = Get-VisionSidecarForGoods $buyer $snapDir
    $latest = Get-LatestSnapshot $buyer $snapDir
    if (-not $latest) {
        if ($side -and ($side.weight_kg -or $side.dims)) {
            return @{ weight = [bool]$side.weight_kg; dims = [bool]$side.dims; img = $false; addr = $false; supplier = $false; file = $null; source = 'vision' }
        }
        return $null
    }
    $raw = Get-Content $latest.FullName -Raw -Encoding UTF8
    $w = $false; $d = $false; $i = $false; $a = $false; $s = $false
    foreach ($line in @($raw -split "`r?`n")) {
        if ($line -notmatch '^\[BUYER\]') { continue }
        if ($line -match '(?i)\b\d+(\.\d+)?\s*(kg|kgs|kilograms?|ton|tons|tonnes?)\b') { $w = $true }
        if ($line -match '(?i)\bdimensions?\b' -or $line -match '\b\d+\s*[x×*]\s*\d+\s*[x×*]\s*\d+\s*(cm|mm|m)?\b') { $d = $true }
        if ($line -match '\[IMG\]') { $i = $true }
        if ($line -match '(?i)\b(address|street|avenue|av\.|avenida|rua|calle|road|endere[cç]o|direcci[oó]n|cep|zip code)\b' -or $line -match '(?i)(brazil|brasil|united states|usa|eua|estados unidos|são paulo|sao paulo|rio de janeiro|los angeles|new york|houston|miami|dallas|curitiba|manaus|fortaleza|recife|belo horizonte|porto alegre)') { $a = $true }
        if ($line -match '(?i)\b(supplier|vendor|fornecedor|proveedor|fabricante|manufacturer)\b') { $s = $true }
    }
    # B6: 快照正则外合并 sidecar(附件识别提取的重量/尺寸)
    if (-not $w -and $side -and $side.weight_kg) { $w = $true }
    if (-not $d -and $side -and $side.dims) { $d = $true }
    return @{ weight = $w; dims = $d; img = $i; addr = $a; supplier = $s; file = $latest.Name }
}

function Get-GoodsName([string]$buyer, [string]$snapDir = "") {
    $latest = Get-LatestSnapshot $buyer $snapDir
    if (-not $latest) { return @{ known = $false; name = "未知" } }
    $text = Get-Content $latest.FullName -Raw -Encoding UTF8
    # 具体品名词表(只认具体词;box/boxes/item/cargo/goods/parts/device/equipment 等泛词不算,避免整句废话当货名)
    $nameWords = 'treadmill|monitor|printer|furniture|appliance|charger|cable|phone|solar|battery|pump|valve|motor|engine|paint|chemical|facial|cartridge|filter|card|holder|lamp|camera|speaker|headphone|keyboard|laptop|tablet|router|modem|generator|compressor|scanner|sensor|controller|adapter|transformer|converter|inverter|drone|tractor|forklift|conveyor|pallet|crate|drum|tank|rack|shelf|stand|powerbank|power bank'
    foreach ($line in @($text -split "`r?`n")) {
        if ($line -notmatch '^\[BUYER\]') { continue }
        # 匹配前剥离行首标记与时间戳/图片/翻译标记,避免混入货名
        $line = $line -replace '^\[BUYER\] ', '' -replace '@@TS:.*?$','' -replace '\[IMG\]','' -replace '由阿里翻译提供|翻译中…|反馈|已读',''
        $m = [regex]::Match($line, 'product-detail/([^\s/?]+)')
        if ($m.Success) {
            $title = $m.Groups[1].Value -replace '\.html$', '' -replace '-\d+$', '' -replace '-', ' '
            $title = $title.Trim()
            if ($title) { return @{ known = $true; name = $title } }
        }
    }
    foreach ($line in @($text -split "`r?`n")) {
        if ($line -notmatch '^\[BUYER\]') { continue }
        $line = $line -replace '^\[BUYER\] ', '' -replace '@@TS:.*?$','' -replace '\[IMG\]','' -replace '由阿里翻译提供|翻译中…|反馈|已读',''
        $m = [regex]::Match($line, '(?i)\b(' + $nameWords + ')\b')
        if ($m.Success) {
            # 只取关键词附近短片段(前 20 字 + 后 30 字),截到句号/逗号边界,禁止输出整行消息
            $start = [Math]::Max(0, $m.Index - 20)
            $end = [Math]::Min($line.Length, $m.Index + $m.Length + 30)
            # 起点/终点回退到最近空格,避免从单词中间切割
            $sp = $line.LastIndexOf(' ', $start)
            if ($sp -ge 0 -and $sp -lt $m.Index) { $start = $sp + 1 }
            $sp2 = $line.LastIndexOf(' ', $end)
            if ($sp2 -gt $m.Index + $m.Length) { $end = $sp2 }
            $frag = $line.Substring($start, $end - $start)
            # 去掉片段开头的填充词(动词/冠词/代词),让品名更干净("contains 6 ..." -> "6 ...")
            for ($fi = 0; $fi -lt 3; $fi++) {
                # 双引号包裹:单引号/弯引号都是字面字符(PS 会把弯引号 U+2019 当字符串分隔符)
                $newFrag = $frag -replace "^(?i)(contains|have|has|with|for|the|a|an|is|are|need|want|we|i|it|its|it's|it’s|this|please|and|of|to|on|in)\s+", ''
                if ($newFrag -eq $frag) { break }
                $frag = $newFrag
            }
            foreach ($sep in @('.', '。', '!', '？', '?', '；', ';', '，', ',')) {
                $idx = $frag.IndexOf($sep)
                if ($idx -gt 0) { $frag = $frag.Substring(0, $idx); break }
            }
            $frag = ($frag -replace '^\s+|\s+$','').Trim()
            if ($frag) { return @{ known = $true; name = $frag } }
        }
    }
    return @{ known = $false; name = "未知" }
}

# 提取买家货物详情具体值(重量/尺寸/地址),供报价提醒展示。提取不到返回空串。
function Get-GoodsDetails([string]$buyer, [string]$snapDir = "") {
    $side = Get-VisionSidecarForGoods $buyer $snapDir
    $latest = Get-LatestSnapshot $buyer $snapDir
    if (-not $latest) {
        if ($side) {
            return @{ weight = [string]$side.weight_kg; dims = [string]$side.dims; addr = ''; qty = [string]$side.cartons; unit_weight = ''; transport = '' }
        }
        return @{ weight = ''; dims = ''; addr = '' }
    }
    $weight = ''; $dims = ''; $addr = ''; $qty = ''; $unitW = ''; $transport = ''
    foreach ($line in @((Get-Content $latest.FullName -Raw -Encoding UTF8) -split "`r?`n")) {
        if ($line -notmatch '^\[BUYER\]') { continue }
        # 重量:所有重量数值(如 "10kg/box x 50" 或 "47 kg total")
        if (-not $weight) {
            $m = [regex]::Matches($line, '(?i)\d+(\.\d+)?\s*(kg|kgs|kilo|kilos|kilograms?|ton|tons|tonnes?|千克|公斤)')
            if ($m.Count -gt 0) {
                $vals = @()
                foreach ($mm in $m) { $v = $mm.Value.Trim(); if ($vals -notcontains $v) { $vals += $v } }
                $weight = ($vals | Select-Object -First 3) -join ', '
            }
        }
        # 尺寸:三维或两维(52x43x40cm / 10x10x10 / 120x80 cm)
        if (-not $dims) {
            $m2 = [regex]::Match($line, '(?i)(?<!\d)\d+(\.\d+)?\s*[x×*]\s*\d+(\.\d+)?(\s*[x×*]\s*\d+(\.\d+)?)?\s*(cm|mm|m|inch|in)?\b')
            if ($m2.Success) { $dims = $m2.Value.Trim() }
        }
        # 件数:三种写法——(a) 数量/件数/quantity/qty 显式字段;(b) x N;(c) "50 pcs/boxes/件/箱" 后缀。
        # x N 尺寸串防护:严禁匹配"数字 × 数字"(如 40 × 50 × 50)——(b1) N 必须带单位后缀;
        # (b2) × 前必须是非数字单词(如 box x 50 / kg x 50)。"10kg/box x 50" 裸数字允许漏提(单件重量正则兜底)。
        if (-not $qty) {
            # 件数 = 箱数/托盘数:箱/托盘字段词优先于数量词(Total Boxes: 20 / Number of cartons: 2 → 2)。
            # 要求复数或 total/number of 前缀,避免 Weight per Box: 5kg 的裸单数 box 误命中
            $mq = [regex]::Match($line, '(?i)((total\s+)?(boxes|cartons|pallets|托盘|箱数|总箱数|件数))\s*[:：]?\s*(\d+)')
            if (-not $mq.Success) { $mq = [regex]::Match($line, '(?i)number of (box|carton|pallet|箱|托盘)\s*[:：]?\s*(\d+)') }
            if (-not $mq.Success) { $mq = [regex]::Match($line, '(?i)(数量|quantity|qty|quantidade|cantidad)\s*[:：]?\s*(\d+)') }
            if (-not $mq.Success) { $mq = [regex]::Match($line, '(?i)(?<![\dx×*])\s*[x×]\s*(\d+)\s*(pcs|pieces|boxes|box|cartons|carton|units|unit|sets|set|件|箱|个|台)\b') }
            if (-not $mq.Success) { $mq = [regex]::Match($line, '(?i)(?<![0-9×*])\s*([\p{L}]+(?:\s+[\p{L}]+)?)\s*[x×]\s*(\d+)\b') }
            if (-not $mq.Success) { $mq = [regex]::Match($line, '(?i)(?<!\d)(\d+)\s*(pcs|pieces|boxes|box|cartons|carton|units|sets?|件|箱|个|台)\b') }
            if ($mq.Success) {
                # 取最后一个纯数字捕获组(不同写法数字所在组位置不同,后缀词组不算数)
                for ($gi = $mq.Groups.Count - 1; $gi -ge 1; $gi--) {
                    if ($mq.Groups[$gi].Value -match '^\d+$') { $qty = $mq.Groups[$gi].Value; break }
                }
            }
        }
        # 单件重量:"each 25kg" / "20kg per piece" / "10kg/box" / "单件重量: 20kg"
        if (-not $unitW) {
            $mu = [regex]::Match($line, '(?i)(单件重量|单件重|unit weight|box weight|carton weight|weight per piece|weight per box|weight per carton|weight of each carton|weight of each box|each carton|each box|peso por unidad|peso unitário|peso unitario|each|per piece|per box|per carton|per unit|每件|每箱|每盒|每箱重|每盒重|每箱重量)\s*[:：]?\s*(\d+(\.\d+)?)\s*(kg|kgs|kilo|kilos|kilograms?|g|grams?|公斤|千克)\b')
            if (-not $mu.Success) { $mu = [regex]::Match($line, '(?i)(?<!\d)(\d+(\.\d+)?)\s*(kg|kgs|kilo|kilos|kilograms?|公斤|千克)\s*(/|per|each)\s*(piece|box|carton|unit|件|箱|个)\b') }
            if ($mu.Success) {
                # 去掉前缀关键词("unit weight 1.5kg" -> "1.5kg";保留 "20kg per carton" 完整描述)
                $unitW = ($mu.Value -replace '^(单件重量|单件重|unit weight|box weight|carton weight|weight per piece|weight per box|weight per carton|weight of each carton|weight of each box|each carton|each box|peso por unidad|peso unitário|peso unitario|each|per piece|per box|per carton|per unit|每件|每箱|每盒|每箱重|每盒重|每箱重量)\s*[:：]?\s*', '').Trim()
            }
        }
        # 运输方案:海运/空运/整柜/拼箱/快递等(买家提过才显示)
        if (-not $transport) {
            $mt = [regex]::Match($line, '(?i)(海运|空运|整柜|拼箱|铁路|快递|卡派|海派|空派|船运|走海|走空|fcl|lcl|by sea|by air|sea freight|air freight|ocean freight|express|dhl|fedex|ups|ems|rail|por mar|por aire|por avión|por avion|marítimo|maritimo|aéreo|aereo|por navio|navio|barco|naval)')
            if ($mt.Success) { $transport = $mt.Value.Trim() }
        }
        # 地址:起点按优先级——(1) 门牌号+街道结构(12999 Murphy Rd) 优先;(2) 地址关键词表(含街道缩写 rd/st/ave 等)
        if (-not $addr) {
            # 门牌号模式:数字 + [街道名] + 街道类型词(Rd/St/Ave/Street/Road/Lane 等)
            # '12999 Murphy Rd' → 命中;'50 to 1 \$per kg' / '200 units' / '1 Kilometer' → 街道类型词不匹配,不误判
            $mAddr = [regex]::Match($line, '(?i)\b\d{1,5}\s+([A-Za-z]+(\s+[A-Za-z]+)?\s+)?(rd|st|ave|blvd|ln|dr|pkwy|hwy|cres|ct|pl|way|street|road|avenue|lane|drive|boulevard|highway|circle|place|terrace|court)\b')
            if (-not $mAddr.Success) { $mAddr = [regex]::Match($line, '(?i)(delivery address|收货地址|address|street|avenue|av\.|avenida|rua|calle|road|endere[cç]o|direcci[oó]n|cep|zip code|postal code|邮编|地址)\b|(?<![0-9])\b(?:rd|st|ave|blvd|ln|dr|pkwy|hwy|cres|ct|pl|way)\b') }
            if ($mAddr.Success) {
                $seg = $line.Substring($mAddr.Index)
                $clean = ($seg -replace '^\[BUYER\] ','') -replace '由阿里翻译提供|翻译中…|反馈|已读','' -replace '@@TS:.*?$',''
                # 去掉行首地址标签(避免"收货地址: 收货地址: ..."双标签)与尾部运输方案词(运输方案单独成行)
                $clean = ($clean -replace '^(delivery address|收货地址|address|邮寄地址|收件地址|destino|endere[cç]o|direcci[oó]n)\s*[:：]?\s*', '') -replace '\s*(海运|空运|整柜|拼箱|铁路|快递|卡派|海派|空派|船运|fcl|lcl|by sea|by air|sea freight|air freight|ocean freight|express|dhl|fedex|ups|ems|por mar|por aire|marítimo|maritimo|aéreo|aereo)$',''
                # 在下一个字段关键词处截断(Shipping/Total Boxes/Box Dimensions 等后续内容不得混入地址);
                # 关键词位于句尾时不截断(如 "this is my shipping address" 整句就是地址本身)
                # 字段关键词必须后跟冒号("Shipping:" 是字段; "shipping address" 是地址短语,不截断)
                $cut = [regex]::Match($clean, '(?i)\b(Shipping|Total Boxes|Total Weight|Box Dimensions|Box Weight|Cartons|Delivery Method|运输|海运|空运|快递|件数|数量)\s*[:：]')
                if ($cut.Success -and $cut.Index -gt 0 -and ($cut.Index + $cut.Length) -lt $clean.Length) { $clean = $clean.Substring(0, $cut.Index) }
                # 阿里翻译占位符 ?? / ???? 替换为空格;<br> 换行标签归一为空格
                $clean = $clean -replace '\?{2,}', ' ' -replace '<br\s*/?>', ' '
                $clean = ($clean -replace '\s+',' ').Trim()
                if ($clean.Length -gt 0) { $addr = $clean.Substring(0, [Math]::Min(100, $clean.Length)) }
            }
        }
    }
    # B6: 快照提取为空时用 sidecar 填充(附件识别提取的重量/尺寸/箱数)
    if (-not $weight -and $side -and $side.weight_kg) { $weight = [string]$side.weight_kg }
    if (-not $dims -and $side -and $side.dims) { $dims = [string]$side.dims }
    if (-not $qty -and $side -and $side.cartons) { $qty = [string]$side.cartons }
    return @{ weight = $weight; dims = $dims; addr = $addr; qty = $qty; unit_weight = $unitW; transport = $transport }
}
