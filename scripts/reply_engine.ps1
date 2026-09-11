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

# 内置回复引擎：根据完整对话上下文 + 语料库生成回复。不依赖任何外部 LLM 会话。
function Generate-Reply([object]$rules, [string]$convoName, [string]$latest, [string[]]$context) {
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
    if ($latestLower -match "(no|don't have|dont have|do not have|doesn't have|doesnt have|without|not (have|find)|can't (find|get|reach)|dont (have|find|get|reach)|cannot (find|get|reach)|unable|no tengo|nao tenho|never had).*(supplier|vendor|factory|proveedor|fornecedor|供应商)|没有供应商") {
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

# state 键标准化：去空白 + 小写，避免大小写/空格差异导致 dedup 失效
function Get-StateKey([string]$name) {
    return $name.Trim().ToLowerInvariant()
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
