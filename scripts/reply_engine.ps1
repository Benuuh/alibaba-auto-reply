# 回复引擎(纯逻辑,无文件/网络依赖):语言检测/信息缺口核对/规则回复生成/模板解析。

function Resolve-Template([string]$tpl, [hashtable]$vars) {
    $result = $tpl
    foreach ($k in $vars.Keys) {
        $result = $result.Replace("{$k}", [string]$vars[$k])
    }
    return $result
}

# 语言检测：先西语后葡语（cuanto/para el 等词更常见；envio 无重音时西语优先），固定英文回复策略保留多语言分支
function Detect-Lang([string]$text) {
    $t = $text.ToLower()
    if ($t -match 'gracias|hola|precio|cuánto|cuanto|envío|envio|por favor|claro|perfecto|dónde|donde|amigo|bien|buenas|para el|para la|cuesta|tarda|demora') { return 'es' }
    if ($t -match 'obrigado|obrigada|preço|preco|qual|quanto|você|voce|amigo|não|nao|bom dia|perfeito|pode|fazer|enviar|carga|mercadoria|quero|para o|para a|custa|frete|prazo|orçamento|orcamento') { return 'pt' }
    if ($t -match "d'accord|daccord|merci|oui|non|bonjour|très|tres bien|marchandise|livraison|remboursement|endroit|demain|ici|c'est|n'hésitez|je vous|tu vas|elle") { return 'fr' }
    return 'en'
}

# 统一回复语言：当前强制美式英文（规则引擎所有多语言分支走 en）
function Get-ReplyLang { return 'en' }

# 将缺失项组合成一句自然的问题
function Build-MissingQuestion([object]$missing) {
    $names = @()
    foreach ($m in $missing) {
        if ($m -match 'weight') { $names += "the total weight (kg)" }
        elseif ($m -match 'dimension') { $names += "the packaging dimensions (L*W*H)" }
        elseif ($m -match 'address') { $names += "the recipient's detailed address" }
        elseif ($m -match 'image') { $names += "reference images of the goods" }
        else { $names += $m }
    }
    if ($names.Count -eq 1) { return "Could you share $($names[0])?" }
    if ($names.Count -eq 2) { return "Could you share $($names[0]) and $($names[1])?" }
    return "Could you share $($names[0..($names.Count-2)] -join ', ') and $($names[-1])?"
}

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

# 构造回复上下文:一次性计算 Generate-Reply 各意图族共享的派生状态(显式返回,避免隐式作用域)
function New-ReplyContext([object]$rules, [string]$convoName, [string]$latest, [string[]]$context) {
    $vars = @{ name = $convoName; brand_sales = "" }
    if ($rules -and $rules.brand) { $vars.brand_sales = $rules.brand.sales_contact }
    $templates = @{}
    if ($rules -and $rules.templates) { $templates = $rules.templates }
    $dataCollect = @()
    if ($rules -and $rules.data_to_collect) { $dataCollect = $rules.data_to_collect }

    $latestLower = $latest.ToLower()
    $ctxAll = ($context | ForEach-Object { ($_ -replace '^\[(BUYER|ME)\] ','') }) -join ' '
    $ctxLower = $ctxAll.ToLower()
    $lang = Get-ReplyLang
    $missing = @(Get-MissingInfo $ctxAll $dataCollect)
    # A2:买家承诺提供的字段不再追问(从缺失清单移除)
    $promised = @(Get-PromisedFields $context)
    if ($promised.Count -gt 0) {
        $missing = @($missing | Where-Object {
            $m = $_.ToLower()
            -not (($m -match 'weight' -and $promised -contains 'weight') -or
                  ($m -match 'dimension' -and $promised -contains 'dimension') -or
                  ($m -match 'address' -and $promised -contains 'address') -or
                  ($m -match 'image' -and $promised -contains 'image') -or
                  ($m -match 'supplier' -and $promised -contains 'supplier'))
        })
    }
    $hasAddr = $ctxLower -match 'address|addr|calle|rua|street|avenue|road|endere|direcci|地址|邮编|cep|postal|city|ciudad|cidade|country|país|pais|deliver to|consignee|destinatario'
    $hasWeight = $ctxLower -match '\d+\s*(kg|kgs|kilo|kilos|千克|公斤)|weight|peso|gross'

    # 追问计数:统计我方(ME)此前追问缺失信息的次数。同一字段累计追问 ≥2 次后,
    # 不再重复问(转"收尾等待"语气防骚扰),与提示词"追问上限"规则保持一致
    $meAskCount = 0
    foreach ($_ctxLine in $context) {
        if ($_ctxLine -match '^\[ME\]' -and $_ctxLine -match 'weight|dimension|address|image|photo|picture|supplier|share|provide|send (me|over)|need') { $meAskCount++ }
    }
    $waitTone = @{
        en = "No rush at all - whenever you have the details, just send them over and I'll get your quote ready."
        es = "Sin prisa - cuando tenga los datos, envíemelos y preparo su cotización."
        pt = "Sem pressa - quando tiver os dados, me envie e preparo sua cotação."
        fr = "Pas de presse - dès que vous avez les informations, envoyez-les-moi et je prépare votre devis."
    }

    return @{
        vars = $vars
        templates = $templates
        dataCollect = $dataCollect
        latestLower = $latestLower
        ctxAll = $ctxAll
        ctxLower = $ctxLower
        lang = $lang
        missing = $missing
        hasAddr = $hasAddr
        hasWeight = $hasWeight
        meAskCount = $meAskCount
        waitTone = $waitTone
        context = $context
    }
}

# 意图族 A(寒暄/情绪/终止):命中返回文本,未命中返回 $null
function Resolve-IntentEarly($c) {
    $latestLower = $c.latestLower
    $lang = $c.lang
    $vars = $c.vars

    # A0. 买家指责"你们不读/看不懂/没看" → 先道歉并确认信息已收到，不追问（只做推进）
    $cantReadPattern = '(vous (ne )?savez pas lire|vous lisez pas|vous n.avez pas lu|vous ne lisez|can.t you read|dont you read|don.t you read|you (don.t|dont) (even )?(read|listen|understand)|you are not reading|you.re not reading|you arent reading|no entiende|no lees|no entende|você não lê|nao le|no leen|no escuchan|não leram|nao leram|没有看|看不懂|根本不会看|根本不会读|不读|没看|vous savez pas compter|vous ne savez pas compter|dont you see|can.t you see|didnt you read|didn.t you read|did you not read)'
    if ($latestLower -match $cantReadPattern) {
        $sr = @{
            en = "Sorry about that - my mistake. I do have your details; let me confirm the exact quote and get back to you shortly."
            es = "Lo siento, fue un error mío. Ya tengo sus datos; confirmo la cotización exacta y le respondo en breve."
            pt = "Desculpe, foi erro meu. Já tenho seus dados; vou confirmar a cotação exata e retorno em breve."
            fr = "Désolé, c'est de ma faute. J'ai bien vos informations ; je confirme le devis exact et je reviens vers vous très vite."
        }
        return $sr[$lang]
    }
    # A1. 否定/拒绝/终止意图拦截：买家表示不要了/取消/不需要 → 返回友好收尾（不再推模板）
    if ($latestLower -match '(no thanks|no thank|never mind|not interested|skip it|skip this|pass|cancel|stop|don.t need|dont need|no need|not needed|no longer|don.t want|dont want|no quiero|no necesito|não quero|nao quero|não preciso|nao preciso|no preciso|no necessito|another one|不用了|不需要|算了|取消|停止|退订|unsubscribe|laisser tomber|laisse tomber|forget it|forget about it|forget this|drop it|abandonner|abandonar|deixar de lado)' -or
        ($latestLower -match '^(no|non|não|nao)\b' -and $latestLower.Length -lt 30)) {
        $n = @{
            en = "No problem at all - appreciate you reaching out. Should anything change, I'm here whenever you need."
            es = "Sin problema, gracias por escribir. Si algo cambia, aquí estoy cuando lo necesite."
            pt = "Sem problema, obrigado pelo contato. Se mudar de ideia, estarei aqui."
            fr = "Pas de souci, merci de votre intérêt. Si quelque chose change, je suis là."
        }
        return $n[$lang]
    }

    # A. 区分感谢 vs 简短确认 vs 语气词，分别自然回应（避免把 ok 当 thanks）
    # 注意：感谢词出现在业务内容中（询盘/报价/货物/重量等词并存）时不按感谢处理，避免对完整询盘回 "You're welcome!"
    $inquiryWords = 'quote|price|cost|devis|how much|freight|ship|shipping|carton|poids|weight|dimension|envoi|envio|entrega|货物|报价|多少钱|寄|發|send|cargo|package'
    if ($latestLower -match '(thank you|thanks|thx|gracias|obrigad|merci|spasibo)' -and $latestLower -notmatch "(no thanks|no thank|never mind|not interested|skip|pass|não|nao quero|no quiero|cancel|$inquiryWords)") {
        $t = @{
            en = "You're welcome! Happy to help - reach out anytime."
            es = "¡De nada! Estoy a su disposición para lo que necesite."
            pt = "Por nada! Estou à disposição para o que precisar."
            fr = "Avec plaisir ! Je reste à votre disposition."
        }
        return $t[$lang]
    }
    # 简短确认（排除携带货物信息的确认，如 "yes it is 20 kg" 应走信息处理分支）
    $confirmOnly = '^(ok|okay|okey|yes|yeah|yep|yup|perfect|fine|sure|got it|sounds good|roger|alright|de acuerdo|de acordo|vale|claro|perfeito|boa)\b'
    if ($latestLower -match $confirmOnly -and $latestLower.Length -lt 40 -and $latestLower -notmatch '\d+\s*(kg|kgs|kilo|kilos)|(total|all|the) (weight|dimension)|cm\b|mm\b|carton|box|size|dimensions|address|weight') {
        $a = @{
            en = "That works - I'll finalize your quote and get back to you shortly. Anything else you'd like me to check?"
            es = "¡Perfecto! Confirmaré la cotización con mi gerente y le aviso. ¿Necesita algo más?"
            pt = "Perfeito! Vou confirmar a cotação com meu gerente e retorno. Precisa de mais alguma coisa?"
            fr = "Parfait ! Je confirme le devis avec mon responsable et je reviens vers vous. Besoin d'autre chose ?"
        }
        return $a[$lang]
    }
    if ($latestLower -match '^(haha|lol|jk|nice|great|cool|amazing)\b') {
        return "Haha indeed! Let me know if I can help you finalize the shipment details."
    }

    # 0.5 买家问是否 AI/机器人/闲聊/自我介绍
    if ($latestLower -match 'are (you|u|ya) (ai|robot|bot|automatic|human|real|machine)|is this (ai|robot|bot)|am i (talking|speaking) (to|with)|你是|机器人|人工智能|真人|自动回复|人工|humano|robot|inteligencia artificial|é você|você é|você e|eres un|es usted|tu es|êtes') {
        return "Haha, I'm Benjamin's assistant handling your messages to get you answers fast - but you're always welcome to talk to a real person if you prefer! Now, how can I help with your shipment today?"
    }
    # 0.6 纯问候（不含询价/货物等业务词）
    if ($latestLower -match '^(hi|hello|hey|good (morning|afternoon|evening)|hola|bom dia|boa tarde|bonjour|salut|hello there|hi there)\b' -and $latestLower.Length -lt 40 -and $latestLower -notmatch 'quote|price|cost|ship|freight|how much|报价|precio|preco|enviar|cargo|goods') {
        $greet = @{
            en = "Hi {name}! Thanks for reaching out. We're a freight forwarder providing door-to-door shipping from China. What goods would you like to ship, and to where?"
            es = "¡Hola {name}! ¿Qué mercancía desea enviar y a qué destino?"
            pt = "Olá {name}! O que deseja enviar e para qual destino?"
            fr = "Bonjour {name} ! Que souhaitez-vous expédier et vers quelle destination ?"
        }
        return (Resolve-Template $greet[$lang] $vars)
    }

    # 0.7 买家表示稍后回来/暂时离开 → 友好收尾，不强推
    if ($latestLower -match "(get back|come back|later|tomorrow|check.*later|busy now|i will send|will share|let me (check|confirm|find)|i'll (check|confirm|send)|vou ver|me aviso|regreso|reviens|luego|depois|manana|amanha)") {
        $b = @{
            en = "Take your time - I'll be right here when you're ready. If it helps, just send over the weight/dimensions and destination whenever you have them."
            es = "Tómate el tiempo que necesites, estaré aquí cuando quieras. Cuando tengas el peso, las dimensiones y el destino, me los envías."
            pt = "Sem pressa, estarei aqui quando precisar. Assim que tiver o peso, dimensões e destino, me passe."
            fr = "Prenez votre temps, je serai là quand vous voudrez. Dès que vous avez le poids, les dimensions et la destination, envoyez-les moi."
        }
        return $b[$lang]
    }
    return $null
}

# 意图族 B(业务咨询):联系方式/计费/流程/时效/电池/砍价/比价/供应商。命中返回文本,未命中返回 $null
# [2026-09-26 更像真人销售 §12.2 冲突 A]
# 场景 (b) 的成品话术("我直接联系供应商"): 买家**有**供应商但拿不到尺寸 / 不愿意给联系方式时用。
# 放在本函数**最前面**是必须的: 实测这两类句子会被更早的分支抢走 ——
#   "i'd rather not share their contact" 命中 #1(问联系方式) → 回了我们的联系方式模板;
#   "i can't get the dimensions from them" 命中 #6(砍价) → 回了"要准确尺寸才能报最优价"。
# 两条都不是本场景该说的话。本分支判据很窄(H1 供应商 且 H2 拿不到/不愿给), 不覆盖既有任何场景。
$script:SupplierContactAsk = @{
    en = "If you can share your supplier's contact, I can confirm the cargo details with them directly - that way I get you an accurate quote faster, and you don't have to go back and forth."
    es = "Si puede compartir el contacto de su proveedor, puedo confirmar los detalles de la carga directamente con ellos: así le doy una cotización precisa más rápido y usted no tiene que ir y venir."
    pt = "Se puder compartilhar o contato do seu fornecedor, posso confirmar os detalhes da carga diretamente com eles - assim consigo uma cotação precisa mais rápido e você não precisa ficar indo e voltando."
    fr = "Si vous pouvez partager le contact de votre fournisseur, je peux confirmer les détails de la marchandise directement avec lui - ainsi je vous obtiens un devis précis plus vite, sans allers-retours de votre part."
}

function Resolve-IntentInfo($c) {
    $latestLower = $c.latestLower
    $ctxAll = $c.ctxAll
    $ctxLower = $c.ctxLower
    $lang = $c.lang
    $vars = $c.vars
    $templates = $c.templates
    $dataCollect = $c.dataCollect

    # 0. [§12.2 冲突 A 场景 (b)] 有供应商, 但拿不到尺寸 / 不愿意给联系方式 → 主推"我直接联系供应商"
    $hasSupplier = $latestLower -match 'supplier|vendor|factory|proveedor|fornecedor|供应商'
    if ($hasSupplier) {
        $cantGetDims = $latestLower -match '(can''t|cannot|can not|unable to|no way to|hard to|difficult to|don''t have access).{0,30}(get|obtain|find|measure|know).{0,30}(dimension|size|measurement|spec|尺寸|规格)'
        $wontShare = $latestLower -match "(rather not|prefer not|not allowed|not permitted|not comfortable|won''t|will not|can''t|cannot|no puedo|nao posso|não posso).{0,30}(share|give|send|provide|pass on|pass along|compartir|dar|enviar|fornecer)"
        if ($cantGetDims -or $wontShare) {
            return (Resolve-Template $script:SupplierContactAsk[$lang] $vars)
        }
    }

    # 1. 客户询问我方联系方式 → 提供（被问到才给）
    if ($latestLower -match 'contact|whatsapp|wechat|phone|number|email|reach you|how to contact|联系方式|telefono|whats') {
        $tpl = $templates.our_contact
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    # 2. 询问计费/体积重规则（在 process 之前：how do you calculate 等不应命中流程模板）
    if ($latestLower -match 'billing|volumetric|charge|how.*(calculate|count)|fee|计费|体积重|重量|como.*(calcula|conta)|quanto.*(cobra|pesa)') {
        $tpl = $templates.billing_rule
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    # 3. 询问流程/如何运作
    if ($latestLower -match 'process|procedure|how (does|is|do|does it|will|does this)|step|work flow|流程|como funciona|cómo funciona|como é que') {
        $tpl = $templates.process_overview
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    # 4. 问时效（补充法语/西语/葡语）
    if ($latestLower -match 'how long|transit|eta|arrive.*(day|time)|when.*(arrive|deliver)|多久|几天|什么时候|demora|cuanto.*(tarda|demora)|quanto.*(demora|tempo)|days to|delivery time|shipping time|combien de temps|quel délai|quel delai|cuánto tiempo|cuanto tiempo|quanto tempo|prazo|plazo|délai|delai|tempo de entrega|tiempo de entrega|temps de livraison') {
        return "For air freight it usually takes 5-10 days, sea freight 35-45 days depending on the route. Once I have your goods details and destination, I can give you a more precise estimate."
    }
    # 5. 电池/锂电池/DG 危险品货物：合规信息（SDS/UN38.3）+ 常规缺失项
    if ($latestLower -match 'battery|batteries|lithium|li-ion|li ion|dangerous goods|hazmat|hazardous|锂电池|电池|危险品|bateria|baterías|baterias|batterie|piles|pilha|pilas|power bank|powerbank') {
        $hasSds = $ctxLower -match 'sds|un38|un 38|msds|safety data sheet|declaration|鉴定书|运输鉴定'
        $bt = @{
            en = "Thanks! Since the goods include batteries, please share the SDS and UN38.3 test report for DG compliance. "
            es = "¡Gracias! Como la mercancía incluye baterías, comparta la SDS y el informe de prueba UN38.3 para el cumplimiento DG. "
            pt = "Obrigado! Como a carga inclui baterias, compartilhe a SDS e o relatório de teste UN38.3 para conformidade DG. "
            fr = "Merci ! La marchandise contenant des batteries, veuillez fournir la SDS et le rapport de test UN38.3 pour la conformité DG. "
        }
        if (-not $hasSds) {
            $rest = @(Get-MissingInfo $ctxAll $dataCollect)
            $q = $bt[$lang]
            if ($rest.Count -gt 0) { $q += (Build-MissingQuestion $rest) }
            else { $q += "Once I have those, I'll finalize your quote." }
            return $q
        }
    }
    # 6. 砍价/太贵/预算（补充西语/葡语：mejor precio=最好价格, preço=价格, barato=便宜）
    if ($latestLower -match 'expensive|too high|too much|cheap|discount|budget|best price|lower|reduc|太贵|贵了|更便宜|mais barato|caro|más barato|caro|mejor precio|melhor preço|melhor preco|preço|preco|barato|economizar|poupar|negociar|regatear') {
        return "I understand you're looking for the best rate. Our billing is based on the higher of gross vs volumetric weight, so accurate weight/dimensions help us give you the most competitive price. Share the exact details and I'll finalize the best option for you."
    }
    # 7. 比价/其他同行
    if ($latestLower -match 'compare|another|other company|other agent|competitor|别的|其他.*(公司|代理)|outra|otra|compara') {
        return "We offer full door-to-door service with warehouses across major Chinese cities, our own truck fleet and cargo insurance, which helps avoid extra charges others may add later. If you share your goods details and destination, I'll make sure you get a fair, transparent quote."
    }
    # 8. 买家表示没有供应商/无法联系供应商 → 引导提供货物详情（别套 follow_up_details）
    #    [2026-09-26 更像真人销售 §12.2 冲突 A] 本句按场景拆分（老板已批准）：
    #      (a) 买家**真没有**供应商（终端用户 / 货还没定工厂）→ 保留原话（我们并不需要供应商联系方式）
    #      (b) 买家**有**供应商但拿不到尺寸 → 走"我直接联系供应商"主推说法（替买家干活，
    #          顺手拿到供应商联系方式，供应商手上有装箱数据）
    #    注意 (b) 只在"同一句里既提到供应商、又提到给不了尺寸/数据"时命中，改动面尽量小。
    if ($latestLower -match "(no|don't have|dont have|do not have|doesn't have|doesnt have|without|not (have|find)|can't (find|get|reach)|dont (have|find|get|reach)|cannot (find|get|reach)|unable|no tengo|nao tenho|never had).*(supplier|vendor|factory|proveedor|fornecedor|供应商)|没有供应商") {
        # (b) 有供应商但不给尺寸/给不了数据 —— 话术定义见本文件顶部的 $script:SupplierContactAsk
        if ($latestLower -match '(supplier|vendor|factory|proveedor|fornecedor|供应商)') {
            if ($latestLower -match "(dimension|size|measurement|spec|sizes|尺寸|规格)|(can't|cannot|dont|don't|won't|not able to|unable|rather not|prefer not|not allowed|private|confidential).{0,40}(share|give|send|provide|量|给|提供)") {
                return (Resolve-Template $script:SupplierContactAsk[$lang] $vars)
            }
        }
        $noSup = @{
            en = "No problem at all! We don't strictly need supplier contact info - just tell us what you're shipping (goods type, total weight, packaging dimensions L*W*H) and the destination address, and we'll handle the quote and shipping from there."
            es = "¡No hay problema! No necesitamos estrictamente el contacto del proveedor - solo díganos qué mercancía envía, el peso, las dimensiones del embalaje (L*A*H) y la dirección de destino, y desde ahí hacemos la cotización y el envío."
            pt = "Sem problema! Não precisamos estritamente do contato do fornecedor - basta nos dizer a mercadoria, o peso, as dimensões (C*L*A) e o endereço de destino, e seguimos com a cotação e o envio."
            fr = "Pas de souci ! Le contact du fournisseur n'est pas indispensable : indiquez-nous simplement la marchandise, le poids, les dimensions (L*l*H) et l'adresse de destination, et nous nous occupons du devis et de l'expédition."
        }
        return (Resolve-Template $noSup[$lang] $vars)
    }
    # 9. 提及供应商 → 引导供应商联系我们
    if ($latestLower -match 'supplier|vendor|factory|proveedor|fornecedor|供应商|fornecedor') {
        $tpl = $templates.follow_up_details
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    return $null
}

# 意图族 C(数据/售后):货物信息/地址/索赔/查件/询价/兜底。始终返回文本
function Resolve-IntentData($c) {
    $latestLower = $c.latestLower
    $ctxLower = $c.ctxLower
    $lang = $c.lang
    $vars = $c.vars
    $templates = $c.templates
    $missing = $c.missing
    $hasAddr = $c.hasAddr
    $hasWeight = $c.hasWeight
    $meAskCount = $c.meAskCount
    $waitTone = $c.waitTone
    $context = $c.context

    # 10. 买家主动提供货物信息（含数字/尺寸/地址等）→ 确认并只问缺失项
    if (($ctxLower -match '\d+\s*(kg|kgs|kilo|cm|mm|m\b)') -or ($ctxLower -match '\d+\s*[x×*]\s*\d+') -or ($ctxLower -match 'address|addr|calle|rua|street|endere|direcci|地址|cep|postal')) {
        if ($missing.Count -eq 0) {
            return "Thanks for all the details! I'll finalize your exact quote and get back to you shortly."
        } elseif ($missing.Count -le 3) {
            # 追问上限:已问过 2 次 → 收尾等待,不再重复问
            if ($meAskCount -ge 2) { return $waitTone[$lang] }
            # 若此前我们已问过信息（上下文里有我方问句），用跟进语气，避免机械重复
            if ($context -match '^\[ME\].*\?' ) {
                return "Just a couple more details and we're set: " + (Build-MissingQuestion $missing)
            }
            return "Almost there! " + (Build-MissingQuestion $missing)
        } else {
            if ($meAskCount -ge 2) { return $waitTone[$lang] }
            $tpl = $templates.first_inquiry
            if ($tpl) { return (Resolve-Template $tpl $vars) }
        }
    }
    # 11. 地址相关（买家提供地址时确认，问地址时给出）
    if ($latestLower -match 'address|addr|calle|rua|street|endere|direcci|地址|cep|postal code|warehouse|收货|destinatario|consignee') {
        if ($missing.Count -eq 0) {
            return "Got it, thank you! All the details are confirmed. I'll proceed with the quote and keep you updated."
        }
        if ($hasAddr) {
            return "Got it, thank you! Your delivery address is confirmed. I'll proceed and keep you updated."
        }
        if ($meAskCount -ge 2) { return $waitTone[$lang] }
        $tpl = $templates.ask_address
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    # 12. 延误/费用/责任索赔（2026-09-10 事故整改）：买家主张或暗示我方承担费用/损失/赔偿 → 致歉共情+核实+时限，不揽责不承诺金额。
    #     聚焦"钱+责任"双重信号与明确索赔词，先于查件/询价分支命中；纯催单/纯询价不得进入（由测试保障）。
    #     此分支只是规则引擎兜底话术；真实运行时 LLM 回复另有发送前责任承诺双检拦截（Test-FinancialCommitment）。
    $claimPat = '(responsible|responsibility|liab\w*|fault|blame|responsab\w*|culpa).{0,60}(cost|fee|expense|rental|charge|pay|compensat|damage|loss|costo|gastos)|(cost|fee|expense|rental|charge|costo|gastos).{0,60}(responsible|liab\w*|you pay|we pay|cover|owe|refund|reimburse|compensat)|reimburse|refund|compensat|crane\s*(rental|cost|fee)|demurrage|detention|storage\s*fee|someone\s+needs\s+to|it\s+(isn\x27t|is not)\s+me|shouldn\x27t\s+have\s+to|customs\s+(hold|delay|fee|charge)|(delay|delayed)\s*.{0,40}(cost|fee|expense|rental|pay)'
    if ($latestLower -match $claimPat) {
        $cl = @{
            en = "I'm really sorry for the trouble this has caused - that's not the experience we want for you. I'm checking with the team right now to find out exactly what's happening with the release and delivery schedule, and I'll get back to you today with a clear update. Regarding the costs on your end, I'll have that reviewed properly and come back to you with a straight answer."
            es = "Siento mucho las molestias causadas; no es la experiencia que queremos para usted. Estoy verificando con el equipo ahora mismo qué está pasando exactamente con la liberación y el cronograma de entrega, y hoy le daré una actualización clara. Sobre los costos de su lado, haré que los revisen debidamente y le daré una respuesta clara y directa."
            pt = "Sinto muito pelo transtorno causado; não é essa a experiência que queremos para você. Estou verificando com a equipe agora mesmo o que está acontecendo com a liberação e o cronograma de entrega, e volto hoje com uma atualização clara. Sobre os custos do seu lado, farei uma revisão adequada e voltarei com uma resposta clara."
            fr = "Je suis vraiment désolé pour les désagréments causés ; ce n'est pas l'expérience que nous voulons pour vous. Je vérifie avec l'équipe en ce moment même ce qui se passe avec la libération et le calendrier de livraison, et je reviens vers vous aujourd'hui avec une mise à jour claire. Concernant les coûts de votre côté, je vais faire examiner cela correctement et vous revenir avec une réponse claire."
        }
        return $cl[$lang]
    }
    # 13. 查件/催进度（售后）：不做编造，给出明确的跟进承诺时限（在询价之前：where is my cargo 不应收到询价模板）
    if ($latestLower -match 'status|tracking|track|where is|where.s|my cargo|my shipment|my package|my parcel|did you check|current update|progress|update on|latest|check on|what.s the (status|update)|how far|how is it going|estado|rastreo|status do|onde esta|où en est|ou en est|suivi|avancement') {
        $st = @{
            en = "Sorry for the wait - let me check with the warehouse right now and I'll get back to you with the latest status today."
            es = "Disculpe la espera - estoy consultando con el almacén ahora mismo y le vuelvo con el estado actual hoy."
            pt = "Desculpe a demora - vou verificar com o armazém agora e volto com o status atual hoje."
            fr = "Désolé de l'attente - je vérifie auprès de l'entrepôt tout de suite et je reviens vers vous avec le statut actuel aujourd'hui."
        }
        return $st[$lang]
    }
    # 14. 询价/货物/发货 → 动态追问缺失信息（补充西语/葡语询价词）
    if ($latestLower -match 'quote|price|cost|how much|报价|precio|preco|orçamento|orcamento|cotizacion|cuánto cuesta|cuanto cuesta|quanto custa|freight rate|shipping cost|ship|cargo|goods|deliver|enviar|import|运输|发货|flete|mercancia|enviar|encomenda|pedido|mercadería|mercaderia|custo') {
        if ($missing.Count -eq 0) {
            if ($hasWeight) { return "Thanks for all the details! I'll finalize your exact quote and get back to you shortly." }
            return "Thanks! All key details are noted - I'll finalize your exact quote and get back to you shortly."
        } elseif ($missing.Count -le 3) {
            if ($meAskCount -ge 2) { return $waitTone[$lang] }
            return "Almost there! " + (Build-MissingQuestion $missing)
        } else {
            if ($meAskCount -ge 2) { return $waitTone[$lang] }
            $tpl = $templates.first_inquiry
            if ($tpl) { return (Resolve-Template $tpl $vars) }
            return "Hi {name}, could you please provide the weight, packaging dimensions (L*W*H), reference images and the recipient's address so I can quote you accurately?"
        }
    }
    # 15. 默认兜底：动态追问
    if ($missing.Count -gt 0) {
        if ($meAskCount -ge 2) { return $waitTone[$lang] }
        $tpl = $templates.first_inquiry
        if ($tpl) { return (Resolve-Template $tpl $vars) }
    }
    return "Thanks for your message! Could you share the goods details (weight, dimensions L*W*H, reference images) and the recipient's address? Then I can arrange everything for you."
}

# 内置回复引擎：根据完整对话上下文 + 语料库生成回复。不依赖任何外部 LLM 会话。
function Generate-Reply([object]$rules, [string]$convoName, [string]$latest, [string[]]$context) {
    $c = New-ReplyContext $rules $convoName $latest $context
    $r = Resolve-IntentEarly $c
    if ($null -ne $r) { return $r }
    $r = Resolve-IntentInfo $c
    if ($null -ne $r) { return $r }
    return (Resolve-IntentData $c)
}

# state 键标准化：去空白 + 小写，避免大小写/空格差异导致 dedup 失效
function Get-StateKey([string]$name) {
    return $name.Trim().ToLowerInvariant()
}

# 尺寸引导话术(2026-09-26 更像真人销售 S4/§12.2): "买家说没有尺寸/量不了"时的**唯一话术定义处**。
# 依据: 实测 86.4% 的买家从未给过尺寸, 而尺寸是报价硬需求(不能用重量+件数代替)。
# 主推 = 主动提出"我直接联系供应商"(替买家干活 + 顺手拿到供应商联系方式 + 供应商手上有装箱数据);
# 三种退一步说法仅在"买家没有供应商/不愿意给/就是个普通纸箱"时用。
# 消费方: reply_agent_prompt.md §第三步之二、reply_playbook.md 指南 1、tests\reply_engine.tests.ps1。
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
    foreach ($tok in @('由阿里翻译提供','由阿里提供','翻译中…','翻译中','Revert','[未读]','反馈','已读','未读','自动接待发送')) {
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

# [SPEC-单出口 2026-09-27] 「是否回复」的**唯一出口**(纯函数: 不读文件、不碰页面、无副作用)。
#   设计依据(spec §4.1 + 本地实测):
#     - 判据的证据锚点 = **账本(我们上一次回复针对的那条买家消息) vs 该会话最后一条买家消息**,
#       不看消息在快照里的位置、不看条数抖动、不看预览串(§3-R1: 位置/条数/预览都是抖动源)。
#     - 列表只当**触发器**, 不当判据(§2.2): 会话出现在待回复列表 ≠ 买家在等我回。
#     - 取向: **证明不了就不发**(fail-closed)。宁可漏回一条真询盘(会留在待回复列表, 老板看得见),
#       也不误发一条骚扰(不可撤回、直接掉客户)。
#
#   ⚠️ 与 spec §4.1 表格的**唯一偏差**(已获老板裁决, 见 REPORT「与 spec 的偏差」):
#     spec 表格把「规则1 BUYER_AFTER_ME」排在「规则3 LEDGER_COUNT_MATCH / 规则4 LEDGER_HASH_MATCH」之前。
#     实测 213 份历史快照回放: 页面消息顺序是**上旧下新**, 193 个含 [BUYER] 行的会话里 81 个"最后一行是
#     [BUYER]" ⇒ 按字面顺序 Reply=true 会出现 6 例账本 hash == 最后买家 hash 的自相矛盾(含本次事故
#     erico/Ganesan/Riyad 三条), 即 §5.1-A2「0 例外」与 §5.2-A10「三会话 Reply=false」**不可能达成**。
#     故本实现把**证据判据(规则3/4)排在位置判据(规则1)之前**; 规则1/2 仍保留为"账本证明不了"时的补充判据。
#     裁决结果: A2 0 例外、A10 三会话 Reply=false 全部成立(证据见 REPORT)。
#
#   入参:
#     -ConvoLines        该会话在快照中的原始行(含 [BUYER]/[ME] 与 @@TS/@@OT 标记)。
#     -LedgerKey         账本中原样取出的字符串(HASH|count、HASH|13位ts、或 HASH); **本函数之外不得解析第二段**。
#     -NormLastBuyerHash Get-StableHash(Get-NormalizedMsgText(买家最后一条消息原文)), 由调用方算好(同口径)。
#   返回: [pscustomobject]@{ Reply = <bool>; Reason = <string> }。Reason 逐字取自下表(便于 grep 与回归断言)。
#
#   判定表(顺序固定, 先命中先返回; §4.1 的 5 条 + 实际实现拆分共 8 行、Reason 集合不变):
#     序 | 条件                                                  | Reply | Reason
#     1  | 账本第 2 段可解析为条数 且 == [BUYER] 行数             | false | LEDGER_COUNT_MATCH
#     2  | 账本第 2 段可解析为条数 且 < [BUYER] 行数(增加了)       | true  | BUYER_COUNT_INCREASED
#     3  | 账本第 1 段 == NormLastBuyerHash                      | false | LEDGER_HASH_MATCH
#     4  | 账本键为空/缺失(从未回复过)                            | true  | NO_SELLER_MSG
#     5  | 账本键非空 且 [ME] 行数 == 0                          | true  | NO_SELLER_MSG
#     6  | 账本键非空 且条数**不可解析** 且最后一行是 [BUYER]      | true  | BUYER_AFTER_ME
#     7  | 账本键非空(条数减少 / 不可解析且非买家收尾)             | false | UNCERTAIN_FAILCLOSED
#     8  | 其余(无账本键; 理论不可达 —— 行 4 已覆盖)              | false | UNCERTAIN_FAILCLOSED
#   §4.1 原表规则 5「以上都不成立」= 本表第 7/8 行(同一 Reason、同一 Reply) —— 语义等价, 不改结果。
#   行 2(条数增加) 承接既有 Test-NewBuyerMessage 的**唯一有效结论**(条数增加 ⇒ 必有新消息; 条数不依赖列表顺序),
#   也是 §5.2-A12「买家真说新话仍能回」的判定行。
#   行 6 只在"账本给不出条数"时生效: 一旦有可解析条数, 位置判据不参与(相等/增加/减少都被行 1/2/7 吃掉)。
function Test-ShouldReply {
    [CmdletBinding()]
    param(
        [string[]]$ConvoLines,
        [string]$LedgerKey,
        [string]$NormLastBuyerHash
    )
    $lines = @($ConvoLines)
    $buyerCount = 0
    $meCount = 0
    $lastLine = ''
    foreach ($l in $lines) {
        if ($l -match '^\[BUYER\]') { $buyerCount++ }
        elseif ($l -match '^\[ME\]') { $meCount++ }
        if (-not [string]::IsNullOrWhiteSpace($l)) { $lastLine = $l }
    }
    # 账本键按**原样**解析(不 trim 掉内部分隔符; 空串 = "该会话从未回复过")
    $ledgerKeyRaw = [string]$LedgerKey
    if ([string]::IsNullOrWhiteSpace($ledgerKeyRaw)) {
        # 账本里没有这个会话 ⇒ 我们从未在此会话发言 ⇒ 新询盘(与 §4.1 规则 2 同义)。
        # 注: 账本"读取失败"绝不允许走到这里 —— 调用方在整轮开头已用 Test-RepliedStateUsable 挡住(§4.2)。
        return [pscustomobject]@{ Reply = $true; Reason = 'NO_SELLER_MSG' }
    }
    $parts = $ledgerKeyRaw -split '\|', 2
    $ledgerHash = [string]$parts[0]
    # 第 2 段既可能是"买家消息条数", 也可能是**旧格式 epoch 毫秒时间戳**(13 位)。
    # 后者绝不能直接 [int] 转换(会抛 Int32 溢出; 实测键 ...|1789826752752 触发过一次崩溃)。故先限长再 TryParse。
    $ledgerCount = $null
    if ($parts.Count -gt 1) {
        $seg = ([string]$parts[1]).Trim()
        if ($seg -match '^\d{1,9}$') {
            $parsed = 0
            if ([int]::TryParse($seg, [ref]$parsed)) { $ledgerCount = $parsed }
        }
    }
    # 1) 条数相等 ⇒ 账本记录的那次回复针对的就是当前这批买家消息 ⇒ 没有新东西可说
    if ($null -ne $ledgerCount -and $ledgerCount -ge 0 -and $ledgerCount -eq $buyerCount) {
        return [pscustomobject]@{ Reply = $false; Reason = 'LEDGER_COUNT_MATCH' }
    }
    # 2) 条数**增加** ⇒ 账本记录之后买家确实又说话了(与位置无关的硬证据) ⇒ 应回。
    #    这是 [FIX-DUP-ORDER] 唯一被保留下来的有效结论(条数不依赖列表顺序), 也是防"修成哑巴"的关键一行。
    if ($null -ne $ledgerCount -and $ledgerCount -ge 0 -and $buyerCount -gt $ledgerCount) {
        return [pscustomobject]@{ Reply = $true; Reason = 'BUYER_COUNT_INCREASED' }
    }
    # 3) 账本 hash == 最后一条买家消息的 hash ⇒ 已回过这条
    if ((-not [string]::IsNullOrWhiteSpace($NormLastBuyerHash)) -and ($ledgerHash -eq $NormLastBuyerHash)) {
        return [pscustomobject]@{ Reply = $false; Reason = 'LEDGER_HASH_MATCH' }
    }
    # 4) 完全没有 [ME] 行(账本键非空但快照里抓不到我方消息) ⇒ 按新询盘处理
    if ($meCount -eq 0) {
        return [pscustomobject]@{ Reply = $true; Reason = 'NO_SELLER_MSG' }
    }
    # 5) 账本**没有任何可解析的条数证据**(旧格式 13 位 / 无第二段) 且最后一行是 [BUYER]
    #    ⇒ 我方回复排在买家最后一条之前 ⇒ 补充判据 BUYER_AFTER_ME
    #    ⚠️ 只在"条数不可解析"时生效: 条数可解析但不等时, 位置判据不得翻案(否则会把已回复过的
    #       会话又判成"应回" —— 实测在有账本条数证据的快照上复现过), 那种情形直接走下方 fail-closed。
    if ($null -eq $ledgerCount -and $lastLine -match '^\[BUYER\]') {
        return [pscustomobject]@{ Reply = $true; Reason = 'BUYER_AFTER_ME' }
    }
    # 6) 以上都不能证明"有新消息" ⇒ fail-closed:
    #    - **旧格式 13 位时间戳键**(第二段不可解析) 一律走这里 ⇒ Reply=false(§5.1-A7);
    #      这是对第 6 次修复的直接纠正: 旧格式键不再回退"hash 不同即算新消息", 而是判"证明不了 ⇒ 不发"。
    #    - 条数可解析但**减少**(抽取漂移) ⇒ 同样不发。
    return [pscustomobject]@{ Reply = $false; Reason = 'UNCERTAIN_FAILCLOSED' }
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
