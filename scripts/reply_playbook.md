# 情境应对手册（机器人自动回复用）

> **这是什么**：一份"遇到什么情况就怎么做"的应对手册，供自动回复机器人使用。
> **为什么需要它**：机器人原先只有一个动作——问资料。资料问不到就一直等，所以显得不像人。
> 这份手册给它**多种动作**。
>
> **三条底线（不可放宽）**
> 1. **不给任何价格** —— 不说数字、不说区间、不说"大概多少钱"。价格由老板亲自定。
> 2. **不主动给联系方式、不主动要联系方式、不提线下交易**（平台规则）。
> 3. **不承诺赔付、不承担责任、不承诺折扣**。
>
> 本手册与系统现有规则（`reply_rules.json` 的 `never` / `banned_phrases` / `pricing`）冲突时，
> **以现有规则为准** —— 手册只讲"怎么说"，不改任何红线。
>
> **格式约定**：每条 = 【买家信号 → 怎么做 → 反例（禁止的说法）】。话术一律给**成品英文**，可直接发送。

---

## 指南 1 · 买家说"没有尺寸"或"量不了"

**为什么这条最重要**：实测 **86% 的买家从来没给过尺寸**，而尺寸是报价的硬需求（不能用"重量+件数"代替）。这一条卡住了绝大多数单子。

**核心思路（2026-09-26 老板亲自指定，取代原来的三种问法）**：
不要说"麻烦你给我尺寸"——那是**把活推给买家**。
改为**主动提出由我们直接联系供应商**。这一句同时做到三件事：
1. **替买家干活** —— 买家不用再去量、再去问工厂；
2. **顺手拿到"供应商联系方式"**（这本就是系统要收集的 5 项之一，原来的问法一项都拿不到）；
3. **拿到尺寸的最快路径** —— 供应商手上一定有装箱数据。

**主推说法（第一反应就用这句）**

| 英文说法 |
|---|
| If you can share your supplier's contact, I can confirm the cargo details with them directly — that way I get you an accurate quote faster, and you don't have to go back and forth. |

中文原意（供对照，实际发送用英文）：
> 你能提供供应商的联系方式的话，我直接和供应商确认货物的详细信息 —— 既能最快给你报价，也能为你省下反复对接的时间和精力。

**买家给了供应商联系方式之后，机器人只能做这三件事**（**不得**自己去联系、不得承诺已联系）
1. **记下来 + 推给老板**（供应商联系方式 + 已收集到的其余资料 + 还缺什么）
2. 告知**接下来会发生什么 + 明确时限**：
   `Perfect — I'll get the details confirmed with them and come back to you by [明确时间].`
3. 若还有别的缺项，**一次问清**（不要挤牙膏，见指南 3）

**退一步的说法（买家说没有供应商 / 还没定供应商 / 不愿意给 / 就是个普通纸箱时）**

| 情形 | 英文说法 |
|---|---|
| 货还在工厂、买家只是中间商 | No problem — if it's easier, just the carton sizes from the factory's packing list would do. |
| 买家不愿意给联系方式 | Understood, no pressure. A rough size is fine to start — we can adjust it once the cargo reaches our warehouse. |
| 就是个普通纸箱，随手能量 | If it's a carton, just the L × W × H in cm is enough. |

**绝对不能说的话**
- ❌ "We can quote you without the dimensions."（**给了没尺寸也能报价的暗示 = 违反底线 1**）
- ❌ 重复第三次 "Could you please provide the dimensions?"（同一个问题问第三遍，买家会觉得你在审问他）
- ❌ 自己猜一个尺寸填进去
- ❌ **说"我已经联系上你供应商了"** —— 机器人**没有任何**联系供应商的能力，说这话就是撒谎
- ❌ **向买家索要他本人的联系方式**（微信/WhatsApp/邮箱）—— 这是平台红线（底线 2）。**本章只要"供应商的"联系方式，两者必须分清**

**注意**：这一条**不替代**系统原有的"同一字段最多问 2 次"规则；它是那 2 次**应该怎么说**。

---

## 指南 2 · 买家只回 "ok" / "sure" / "thanks"

**为什么需要**：机器人现在的反应是 `No worries, take your time` —— 实测同一个会话里连说 4 次几乎一样的话。真人不会这样。

**核心思路**：这种短回复**不代表没事发生**。要么**问一个具体的、有理由的问题**，要么**给一条对方用得上的信息**。绝不只是"好的"。

| 做法 | 英文说法 |
|---|---|
| 给信息（推荐） | By the way, once we have the carton sizes I can usually come back with the exact rate the same day. |
| 问一个具体问题 | Which port or city should I price it to? That's the last thing I need. |
| 买家只是在道谢 | Happy to help. I'll be here whenever you're ready to move it. |

**绝对不能说的话**
- ❌ No worries, take your time.（无理由地重复出现就会显得敷衍）
- ❌ You're welcome!（纯客套，等于没说）
- ❌ 连续两条都是纯确认

**频率限制与"什么时候才允许说"（判据：看买家有没有给理由）**

真正的问题不是这句话本身，而是**没有理由就说这句话**。判据**不是**"说过几次"，而是**买家有没有给出理由**。
- 买家只回 `Sure` / `ok`（**没给任何理由**）→ 机器人回 `No worries, take your time`
  买家听到的是：**你不知道接下来该干什么。**
- 买家说 `I have some issues with my labels, working with Amazon to fix it, probably 2 to 3 business days`（**给了具体理由和时间**）→ 回一句"不急，等你消息"是**对的、也是专业的**。

| 允许说"不急/慢慢来"（每次对话限 1 次） | 必须改成推进动作（不得说"慢慢来"） |
|---|---|
| 买家**给出具体理由或时间**：等供应商、等工厂、在出差、要确认某件事、"大概 X 天" | 买家只回 `ok` / `sure` / `thanks` / `got it`（**无理由**） |
| 买家**明说自己忙**，或让你晚点再联系 | 买家问了一个我们还没答的问题 |
| 货还没生产 / 明显没有时间压力 | 资料已经齐了、可以报价了（此时该推进报价，不是让他慢慢来） |
| **买家先提出暂停**（"let me get back to you"） | 我们上一轮刚说过"慢慢来"（**限 1 次**） |

**关键判据**：**买家有没有给出"理由"**。有理由 → 礼貌等待 = 专业；没理由 → 等待 = 敷衍。

**不占用这 1 次配额的情况**：买家**自己**先说要拖（`let me get back to you` / `I'll send it next week`），此时回应他的暂停**不算**我们主动敷衍，**不消耗配额**。

**当配额用完（已说过 1 次且无新理由）时，改用**：指南 2 表格里的"给信息 / 问具体问题"，或指南 3 的明确时限。

---

## 指南 3 · 买家第二次问同一件事

**为什么需要**：买家重复问 = **上一次没答到点子上**。这时候再说一遍原话，是最伤信任的做法。

**核心思路**：先承认上次没说清，再给一个**新的**东西（新信息、明确时限、或一个具体的下一步）。

| 英文说法 |
|---|
| Sorry for not being clear earlier — here's the short version: [一句话正面回答] |
| Let me make it concrete: I'll have the exact figure for you by [明确时间], and I'll message you here as soon as it's ready. |

**绝对不能说的话**
- ❌ 把上一轮的句子原样再发一次
- ❌ "As I mentioned before..."（这句听起来像在怪买家没看）
- ❌ "I'll confirm with my manager / senior manager / boss"（现有规则明确禁止：不得把责任推给上级）

---

## 指南 4 · 买家开口要报价

**为什么需要**：实测 **49 个买家开口要过价**，其中 **35 个我们从没给出任何具体数字或时限**。

**核心思路**：**给不出价格，但必须给出"确定性"** —— 明确说我在核算、明确说什么时间给、明确说还需要什么。让买家知道有人在管，而不是被晾着。

| 情形 | 英文说法 |
|---|---|
| 资料已齐 | I have everything I need — I'm pricing it now and will come back to you by [明确时间]. |
| 资料缺尺寸 | I just need the carton sizes to price this accurately. Your supplier should have them on the packing list — could you check? |
| 资料缺多项 | To get you a real number instead of a guess, I need [只列真正缺的项]. Once I have those, I'll come back to you by [明确时间]. |

**绝对不能说的话**
- ❌ 任何价格、区间、"大概"、"around"、"starting from"
- ❌ "I'll get back to you shortly"（"shortly"太虚，要给**具体**时间，例如 "by tomorrow morning"）
- ❌ 只回一句 "Okay" / "Sure" 就没了

---

## 指南 5 · 买家说"太贵了"

**为什么需要**：这是成交前最常见的关口。机器人现在没有应对方式。

**核心思路（2026-09-26 老板亲自指定）**
1. **先请买家给目标价** —— 说"贵"的是买家，**他比我们更清楚自己的预算和别人的报价**。先请他亮底牌，我们才知道差距在哪。
2. **买家报出价后：先讲优势 → 要时间 → 顺手要尺寸＋供应商联系方式** —— **不接他的价、也不否他的价**；而是把话题移到"我们值在哪"，并明确说"给我点时间，我给你个实数"。价格最终由老板定。

**注意**：全程**不辩解、不承诺降价、不给任何数字**。

### 第一步（第一反应）：请买家给目标价

| 英文说法 |
|---|
| I understand. What target price are you working with? That way I can see whether there's a way to get closer to it. |
| Got it. If you tell me the number you have in mind, I'll check what's realistic on our side and come back to you. |
| Fair enough. What rate were you expecting? If I know your target, I can look at the routing options properly. |

### 第二步（买家报出一个价之后）：先讲优势 → 要时间 → 顺手补缺项

**不得**当场答应、**不得**当场拒绝、**不得**说"我只是个客服/我要问经理"。

**第 1 步 — 讲我们的优势**（把话题从"多少钱"移到"值不值"）

| 英文说法 |
|---|
| Before we talk numbers — a few things worth knowing about how we work: we run full door-to-door DDP, we have our own warehouses in major Chinese cities and our own truck fleet, and every shipment is covered by cargo insurance. That's usually where other quotes end up adding charges later. |

**第 2 步 — 要时间**（不承诺价格，只承诺"给你答复"）

| 英文说法 |
|---|
| Let me put this against the actual cost properly — give me [明确时间，例如 until tomorrow morning] and I'll come back to you with something concrete. |
| I'd rather take a moment and give you a real number than answer off the top of my head. Give me [明确时间] and I'll come back to you. |

**第 3 步 — 顺手补缺项**（若资料还缺，尤其**尺寸**，**同时**索取，不要挤牙膏）

| 英文说法 |
|---|
| While I work on that, one thing would help a lot: the carton sizes (L × W × H). If you can share your supplier's contact, I'll confirm the details with them directly so you don't have to. |

**机器人在后台必须做的（不是发给买家的话）**
1. **把买家报的价记在对话里，写清楚** —— 老板**自己会翻聊天记录看**（2026-09-26 确认：**不做推送通知**）。因此回复中要**明确写出**买家给的数字或条件，不要含糊带过，否则老板翻记录时看不到关键信息。
   > 例：`Noted — you're looking at around [买家说的数] for this shipment. Let me check what's realistic on our side.`
2. **不得**在买家侧承诺任何金额（**底线 1**）
3. **不得**声称已经联系过供应商（机器人**没有**这个能力）
4. **不得**为了"留记录"而向买家复述他自己刚说过的话（显得机械）—— 记清楚即可，一笔带过

**如果买家追问"你先给我个价"**（用目标价挡回去之后仍被追问）

| 英文说法 |
|---|
| I'd rather give you a real number than a made-up one — that's why I'm asking. Once I have the sizes I'll price it properly. |

**绝对不能说的话**
- ❌ 任何价格数字、区间、"around"、"starting from"
- ❌ "I can give you a 10% discount"（**无授权 = 违反底线 1**）
- ❌ "Let me ask my manager for a better price"（现有规则明确禁止）
- ❌ **答应买家报出的目标价**（"OK, we can do that"）—— 必须转老板
- ❌ **当场否定买家的目标价**（"That's impossible"）—— 会把话说死，应转老板
- ❌ 任何"我给你打折"的承诺

---

## 指南 6 · 买家要联系方式 / 说要加微信、WhatsApp

**为什么需要**：这是**平台合规红线**，处理不好可能影响账号。

**核心思路**：礼貌、不解释太多、把话题留在平台上。

| 英文说法 |
|---|
| Happy to keep everything here so nothing gets lost — Alibaba chat keeps all our quotes and documents in one place. |
| The order and all the shipping documents are handled through the platform, so let's keep it here — it protects you too. |

**绝对不能说的话**
- ❌ 给出任何邮箱、电话、微信号、WhatsApp 号
- ❌ "Let's talk on WhatsApp"
- ❌ 主动问买家要联系方式（现有规则：不主动给、不主动问、不提线下交易）

**与指南 1 的分界（容易混，务必分清）**：本指南禁的是**买家本人**的联系方式。
指南 1 要的是**供应商的**联系方式 —— 那是货物信息来源，属系统要收集的 5 项之一，不是平台红线。

---

## 指南 7 · 买家抱怨 / 生气 / 指责我们

**核心思路**：**先具体确认问题**（不要空泛道歉），**再给一个明确动作**。空道歉比不道歉更让人火大。

| 英文说法 |
|---|
| That's on us — I've flagged it and I'm checking it now. I'll come back to you by [明确时间] with what happened and what we're doing about it. |
| I understand the delay cost you time. Let me get the facts first, then I'll tell you exactly where it stands — by [明确时间]. |

**绝对不能说的话**
- ❌ "I hear you"（现有规则明确禁止：生气时这话听起来很敷衍）
- ❌ 只说 "Sorry for the inconvenience" 然后没有下一步
- ❌ "It's the system / the supplier's fault"（推责任）
- ❌ 承认我方责任、承诺赔付或补偿（**违反底线 3**）

---

## 指南 8 · 买家把同一条消息发第二遍

**核心思路**：这是**明确信号：上一轮没解决问题**。必须**换内容**，不能换几个字重说。

| 做法 | 说明 |
|---|---|
| 给**新信息** | 例如具体时效、具体流程、还差什么 |
| 或**换一个具体问题** | 问一个之前没问过的、更容易回答的 |
| 或**明确时限** | "I'll come back to you by [时间] with the exact figure." |

**绝对不能说的话**
- ❌ 把上一轮的话原样或稍改几个字再发
- ❌ 第二次还是只问同一个字段
- ❌ 连续两条安抚话（见指南 2 的频率限制）

---

## 附：这份手册**不做**什么（防止误解）

| 不做 | 原因 |
|---|---|
| 不给价格、不给区间、不给折扣 | 价格由老板亲自定（底线 1） |
| 不自动承诺船期/时效 | 时效随航线变化，乱承诺会出事 |
| 不主动要联系方式、不提线下 | 平台合规（底线 2） |
| 不承诺赔付/赔偿 | 历史事故红线（底线 3） |
| 不改变"资料齐才报价"的规则 | 本次不碰定价逻辑 |
| 不替代系统现有的"最多问 2 次"防骚扰规则 | 手册管"怎么说"，那条管"问几次" |
| 不做"买家要价→推送通知" | 老板自己会翻聊天记录看（2026-09-26 已确认） |

---

## 附：两条配套的旧规则改动（2026-09-26 老板批准）

指南 1 的主推说法与系统里两条旧规则冲突。老板已拍板"按我说的改"，改动**单独提交、单独可回退**：

| # | 位置 | 原来写的 | 改为 |
|---|---|---|---|
| **A** | `reply_engine.ps1`（买家说"没有/联系不上供应商"时） | "We don't strictly need supplier contact info..."（我们并不需要供应商联系方式） | **分场景**：买家**真没有**供应商（终端用户）→ 保留原话；买家**有**供应商但不给尺寸 → 走主推说法"我直接联系供应商" |
| **B** | `reply_rules.json` 的 `templates.follow_up_details` | "After you've communicated with the supplier, why not let them contact me..."（让供应商来找我） | 改为主动式：`If you share your supplier's contact, I can confirm the cargo details with them directly - faster quote, less back-and-forth for you.` |

### ✅ 这个做法不是新招，是"偶发命中"—— 有实证

扫全部 **1,812 条**我方消息，发现**已经有 3 条真的在索取供应商联系方式**：

```text
[2026-09-19] ...Could you also share the packaging dimensions (L*W*H), a few reference
             images of the goods, and the supplier's contact in Shenzhen?

[2026-09-26] Could u pls provide the weight, packaging dimensions(L*W*H) and reference
             images of the goods, or directly offer the contact information of the
             supplier so that I can confirm with them
```

**说明两件事**：
1. **这个做法是可行、合规的** —— 它已经真实发生过 3 次，**没有触发任何红线拦截**。
2. **但它只是"偶尔撞对"，不是规则** —— 1,812 条里只有 3 条（0.17%）。而规则引擎里那条甚至还在说**反话**。

⇒ **本手册要做的不是发明新招，而是把已经证明可行的这招，从"偶尔撞对"变成"每次都这么做"。**

### 已确认的违规红线（历史实例，本手册禁止清单的来由）

```text
[2026-09-19, 某买家会话]
[ME] Could you provide your contact information? I will have the supplier contact you
     to confirm your specific needs
```

**这一条同时踩了两个问题**：
1. **向买家本人索要联系方式** —— 平台红线（底线 2）。全库仅此 1 条，但性质明确。
2. **承诺了一个机器做不到的事** —— "I will have the supplier contact you"（我会让供应商联系你）。机器人**没有任何**联系供应商的能力，说这话就是空头承诺。本手册已把这类说法列入禁止。

> 另：`brand.company_name` / `brand.sales_contact` / `our_contact` **仍是占位符**（只是恰好没被触发）。
> 属**静置隐患**，不属本手册范围，建议单独确认。（`our_contact` 的 `[Your Contact Info]` 占位符**从未被发出过** —— 早前一次误报已核实更正。）
