# CHANGELOG - alibaba-auto-reply

## 0.0.2 - 2026-10-05

- 汇总下列消息顺序、新消息冷却、Amazon/FBA 报价目的地修复及回复模块精简；历史交付保留各自完成时的未发布状态。
- 独立审查补齐最终固定回退的发送前合规检查；所有候选均须通过，失败不发送、不推进账本或发送时间。
- 复跑隔离入口、目的地、消息顺序、回复链、资料、文档与 20 场景回放；公开证据的本机路径替换为占位值，真实配置和运行数据不入库。
- 版本号为 0.0.2，Git 标签为 v0.0.2；代码发布不自动上线，不重启生产。验证范围和边界见 [发布审查记录](verification/release_0.0.2.md)。

## 2026-10-05 - Amazon 收货仓代码作为报价目的地（未上线）

- 新增带买家/明确人工来源证据的共享目的地事实，区分仓代码、邮寄地址、未知和歧义；可信顺序支持换仓，旧无时间快照不猜测冲突顺序。
- 接通回复策略、模型事实区、一次重写/固定回退、发送前检查、goods、人工报价候选/提醒及 summarize 展示，停止重复索取已满足的地址或仓代码。
- 虚拟数据 B1–B17、故意追问地址的模型桩、真实 goods→quote 模拟提醒、前置冷却回归通过；保留源码修改前失败输出及相对开始工作区差异。见目的地修复交付。
- 不查询或编造仓库完整地址/价格；未重启生产、投递通知、真实发送、修改版本或发布。


## 未发布 - 2026-10-05 新消息冷却与统一时间门禁

- 以已有消息顺序修复及回复模块精简工作区为基线，按 [本次 spec](specs/新消息冷却豁免与统一时间门禁_20261005.md) 修订旧无条件五分钟条款；历史事故和验收报告保留。
- monitor 时间策略统一到 `Test-ShouldReply`：可信新消息满足默认 20 秒成功发送间隔后通过，普通消息仍受五分钟门禁；精确秒数比较，等待锚定成功发送时刻，不叠加。
- 发送/去重时间缓存增加来源与 `nextVerifyAt`，预览不变也周期读取，人工插话及输入失败来源保持原阻断；旧记录有限到期兼容，不以 `buyers=-1` 制造新消息证据。
- 新消息确认收紧为可信最新消息、有效两段键和条数增加/等条数原文改变；下降窗口、溢出/损坏键、身份碰撞不获豁免。原文、附件与写账本共用规范化 CDP 最新消息，兼容内存字典和落盘对象，Accio 增强需匹配最新身份。
- 先留存 A1/A2/A3 入口失败基线，再完成 A1–A14 离线验证及关联测试。未启停进程/任务、未改生产配置或账本、未发送消息或通知、未提交/推送；代码尚未上线。证据与上线步骤见 [交付说明](新消息冷却修复交付_20261005.md)。

## 未发布 - 2026-10-05 消息顺序与系统卡片修复

- 页面抽取改用逐条 item-base-info 时间，保留秒数和图片行时间；showTime 不再参与方向判定。
- 消息 schema 升至 3，新增明确的逐条时间与卡片标记；全序列检查方向，证据不足时阻止生成和发送。
- 系统卡片不驱动最新诉求或资料事实，不进入模型上下文；保留账本的买家条数口径。
- 生成、附件与固定话术复用已验证会话；移除账本旧 hash 对当前问题的选择，Accio 也需通过方向和最新文本一致性检查。
- 补充实际抽取器 DOM 回归、监控函数护栏和虚构验收场景；真实回放边界见 [修复说明](消息顺序修复_20261005.md)。未重启服务或发送消息。

## 0.0.1 - 2026-10-04

- 首次编号版本，汇总自然回复链重构、模块加载修复、waimao 移除、文档重写及发布脱敏。
- 版本号以根目录 VERSION 为准，Git 标签为 v0.0.1。通过离线验证；真实模型和发送验收仍待完成，已知缺口见当前状态文档。

## 2026-10-04 - GitHub 发布前脱敏与验收工具整理

- 文档本机路径改为占位说明，注释买家名和邮箱示例脱敏；真实配置与运行数据保持本机私有。
- 三个一次性排查脚本加入 gitignore，仅保留在本机。
- 离线回放按本机配置保护运行数据目录，移除硬编码路径；旧引擎比较固定基线 5356302，避免提交后 HEAD 改变导致工具失效。
- 补充验收工具说明与发布后的回滚方法。业务服务和计划任务状态未改变。


## 2026-10-04 - 当前架构与运维文档重写

- 重写 README、部署手册与项目地图，按实际调用链描述模块、路径和操作。
- 新增带日期的当前状态快照，记录停用任务、离线验证边界与尚未接通的功能。
- 同步 SKILL 和文档维护约定，撤下旧规则自动追加、退休模块入口及过时启停说明。
- 明确 nudge 已无买家自动发送；记录新消息豁免被额外限流覆盖、语料消费和人工交接等缺口。
- 本次只维护文档，未修改业务实现、配置或计划任务，未启动服务或发送消息。


## 2026-10-04 - 移除 waimao 模块

- 删除 scripts/waimao 下的专用 CDP 桥和只读侦察脚本，并移除本机配置与配置模板中的六项 waimao_* 配置。
- 更新项目结构说明与浏览器隔离测试；外贸获客设计文档标注为历史资料。
- 保留历史运行数据和浏览器 profile。自动回复、OKKI、公海模块的业务逻辑未改动。

## 2026-10-03 - 自然回复 / 结构精简 / 效率（隔离分支 natural-reply-20261003，生产保持停用）

**背景**：老板确认四件事——回复太像 AI（以 Sandy 对话为样本）、每条新消息都涉及回复时效考核、自动优化必须改为"经审阅采纳后生效"的建议制、对客户回复统一使用美式英文。执行稿见会话产出 `spec_自然回复与结构精简_v0.1.md`。

- **消息顺序以前是未定义的**：页面抽取保留 DOM 顺序并如此注明，但三个消费方对"哪一端是最新"意见不一致——`lib\msg_source.ps1` 的防抢话闸门（依据 1812 条真实消息设计）把**尾部**当最新；判据 hash 取**最后一条**买家消息；而附件却从**下标 0** 读取，提示词还写着"第一条是最新"。**修法**：新增 `scripts\lib\msg_norm.ps1`，用页面本来就有的每条 `showTime` 判定方向，统一归一到**时间正序**，证据矛盾时进入**显式异常态**（记 `MSG-ORDER-UNVERIFIED`）而不是猜。附件改取**最新**买家消息。
- **短消息被静默丢弃**：抽取 JS 里 `if (clean.length <= 2) { ...; return; }`（带图除外）⇒ `ok`/`si`/`no` **根本不构成消息事件**，永远不会被回复，与 spec 4.1"每条新消息都要回应"直接冲突。已删除该长度过滤，被跳过的行改为带原因记录。
- **业务政策曾有四份实现**：提示词（场景表 + 追问上限 + 尺寸话术 + 红线 + 55 行自动追加归档 + 指向一个从未加载的手册）、`reply_rules.json`（40 条 never，7 条为语义重复）、`reply_engine.ps1` 的意图引擎、`monitor.ps1` 内联的图片回退话术。**现在只有一份**：`lib\reply_policy.ps1` 决定"说什么"、`lib\reply_gen.ps1` 决定"怎么说"（含回退话术），精简提示词只管语言表达，`reply_scenarios.md` 才是**真正按场景注入**的示例。
- **假加载已消除**：`reply_playbook.md` 以前只在提示词里被**点名**，正文从未进入请求。已归档到 `docs\archive\reply_playbook_zh_20261003.md`，其内容改写为 `scripts\reply_scenarios.md`（`Get-ScenarioGuidance` 按命中的场景只注入该小节）。
- **旧意图引擎整体删除**（`Detect-Lang`/`New-ReplyContext`/`Resolve-IntentEarly|Info|Data`/`Build-MissingQuestion`/`Resolve-Template`/`Generate-Reply`/`$script:SupplierContactAsk`）：`Get-ReplyLang` 早已恒返回 `en`，多语言分支是**不可达的生产代码**；其余部分是对同一政策竞争性的第二实现。`reply_engine.ps1` 803 → 500 行，只保留纯原语。
- **模型调用最多 4 次 → 最多 2 次**：旧流程对同一稿可能先跑禁词重写、再跑责任承诺重写（各自一整轮）；现在**只允许一次重写**，由完整违规清单驱动，且剩余预算 < 30s 时直接跳过重写走回退。注入字符数 29718 → 12479（**-58%**）。
- **自动优化改为建议制**：`auto_optimize.ps1` 不再写任何生效文件，只把建议写入 `<运行数据根>\data\suggestions\`；`analyze_replies.ps1 -ApplyNever` 这**第二条直改通道**也一并改道。新增 `review_suggestions.ps1`（查看/采纳/拒绝）与 `apply_suggestion.ps1`（**仅**对已采纳者生效：基准哈希校验 + 备份 + 离线校验 + 失败回滚）。**移除了"never 只保留最新 40 条"的截断**——它可能挤掉硬约束。
- **判据新增正向证据**：spec 4.1 要求"5 分钟间隔与冷却只用于抑制**旧消息**的重复响应，不得无条件挡住已确认的新消息"。新增 `Test-ConfirmedNewBuyerMessage`（只有账本键可解析**且**条数增加或原文 hash 变化才给正向证据）与 `Test-ShouldReply` 行 4b（新消息只受 `reply_new_msg_floor_sec`（缺省 20s）的墙钟下限约束）。身份校验、账本闸、2 轮瞬态防线、写锁与页面健康闸一律不动。
- **修掉一个真 bug**：`\bdimension\b` **匹配不到复数** `dimensions`，而"我把尺寸发给你"正是最常见的买家句式 ⇒ 承诺字段识别静默失效、下一轮又会追问同一个字段。已补复数形态。
- **接回一个从未被调用的检查**：`Test-NoDimensionQuoteHint`（"没尺寸也能报价"的暗示检测）此前**没有任何生产调用点**，其保护的定价红线实际未生效。现接入 `Test-ReplyCompliance`，成为发送前硬拦截。
- **BOM 修复**：`scripts\watchdog.ps1` 缺 UTF-8 BOM 且字符串字面量内含中文 ⇒ PS 5.1 按 ANSI 解码，**日志里是乱码**。已补 BOM（另补 `tests\accio.tests.ps1`、`tests\daemon_launch.tests.ps1`、`tests\page_heal_throttle.tests.ps1`）。
- **验证**：安全子集 17 个测试文件 817 断言全绿；其中 `reply_engine.tests.ps1`(73)、`reply_chain.tests.ps1`(148)、`dimension_guidance.tests.ps1`(44)、`suggestions.tests.ps1`(25) 为本轮新增或重写。离线回放与新旧对比见 `tools\acceptance\`。**未做真实模型调用与真实发送**；本地待办/通知链路（spec 4.4）尚未接线，因此当前配置下**任何回复都不会承诺具体时限**。
- **交付与回滚**：`docs\change_report_20261003.md`（变化、限制、未做项）、`docs\rollback_20261003.md`（回滚步骤）、`docs\efficiency_20261003.md`（前后数据）、`docs\inventory_20261003.md` 与 `docs\test_audit_20261003.md`（只读审计）。生产仍停用：Watchdog/Health 保持 Disabled，未启用或新增任何计划任务，未发送任何买家消息或企微通知。

> 注：历史条目中提到的部分脚本（如 notify / task_health / health_report / wecom_command）已于 2026-09-12 归档至 `backups\精简优化_20260912\`，条目内容保留当时事实。
> 另：`reply_playbook.md` 与 `consolidate_prompt.ps1` 已于 2026-10-03 归档至 `docs\archive\`（见当天条目）。

## 2026-09-28（凌晨二） - 浏览器"失踪"的根因 / OneTalk 客户端空壳 / 搜索框污染 / 我的一次回归与回收

**背景**：老板 03:00 指示"重新拉起来继续跑，设定长期任务目标，每次十个，遇到问题或不能正常激活的客户进行记录"，04:12 追加"跑到北京时间 8 点半就行"。这一程踩到 4 个新问题，其中**一个是我自己改出来的**。

- **GH-38 公海 Chrome 反复"消失"的根因（最重）**：`gonghai_ensure.ps1` 用 `Start-Process` 拉起 Chrome ⇒ 它是调用方（工具命令/后台作业）的**子进程**，而 Windows **作业对象在父进程结束时连同子进程一起回收** ⇒ 每次拉起只能活几分钟。连锁后果：批次"认领 9 个 → 搜索时浏览器已死 → 9 个全被记成索引未同步"（假故障）、loop 静默停摆 7 分钟。**修法**：改用 **WMI `Win32_Process.Create`**（父进程为 WmiPrvSE，不在调用方作业对象里）。`chrome_ensure.ps1` 两处启动同样修正（GH-38b）。**实机验证**：修复后 Chrome 跨工具调用存活
- **GH-41 OneTalk 客户端卡成"空壳" ⇒ 搜索对所有人返回 0（持续 45 分钟）**：两个实例都显示"网络连接已经断开"，**同账号 CRM 页却完全正常**（排除封号）；铁证是监控实例那页 `bodyLen` 只剩 **128** 字符（正常 ~4900）。**有效修法只有关页重开**（关页重开后联系人 0 → 22、搜索 `n=7` 恢复）；**重登、强制重启 Chrome、普通刷新都无效**。已做成自愈：`Repair-GonghaiOnetalkTab` + batch 在认领前搜索闸失败时自动调用并复检（GH-41）。经验：**"能用 eval" ≠ "客户端还活着"**
- **GH-39/39b 搜索健康闸（救命闸）**：搜索不可用时旧逻辑照样认领 9–10 人却一个都发不出 ⇒ 待办队列被冲到 60+。新增 `Test-GonghaiSearchUsable`（**只以烟雾搜索为准**；"断开横幅"实测两个实例都挂着、监控却仍能发送 ⇒ 横幅仅作参考，否则会**假拦截**），放在**认领之前**；不可用 ⇒ `exit 1` 零认领
- **GH-42 搜索框残留上一个关键词**（真 bug，会让**每轮后几个搜索互相污染**）：实测先搜 `Greg Jerum` 再搜 `Greg` ⇒ `typedLen=15`（两词拼接）⇒ 0 结果。修法：输入前清空 + 回报 `mismatch/value`。⚠️ 但这条修复的第一版**被我改错了**，见 GH-43
- **GH-43 我的回归（代价：30 次认领）**：把 GH-42 改成"**无条件先清空再输入**"后，应用会**退回全部会话列表**，"点第 1 条结果"于是点到列表里的人 ⇒ 连续三轮 `ABORT_WRONG_CONVO actual=29583ea4`（**同一个错误会话**）、每轮认领 10 个却发 0 条。**已回退为安全变体**（先按原行为输入 → 读回校验 → 仅确实污染时清空重输）。**教训**：修 bug 必须先在**小范围**验证再上生产
- **GH-44 中断兜底（补机制）**：上述三轮里，批次只把"索引未同步"那 1 个入队，**其余 9–10 个已认领未发送的人直接丢了**（只能事后翻「我的客户」列表按 code→key 反查找回）。已做：① 写工具脚本人工回收（入队 12 条 `LOST_AFTER_ABORT`）；② **batch 在 `$abort` 路径自动把所有"已认领未发送"的人入队**（判据 = 不在 `$sentKeys` 且账本无成功记录；`Add-GonghaiPending` 幂等）。**实机验证**：05:16 那轮中断后自动入队 6 条
- **GH-40 测试脆弱性**：`should_reply` 把"事故快照永存"当硬前提，而 `data\msgs_*.txt` 受 200 份保留策略限制 ⇒ 断言随时间必然变红。新增 **`specs\incident_evidence\` 永久证据目录**（附 README 纪律），测试两处都找不到时 **NOTE 跳过而非 FAIL**；并把今晚关键快照固化留档
- **GH-37 周报/告警推送被 DSH 拒（403，需老板决定）**：投递端点 `http://127.0.0.1:43120/api/dsh-im/delivery/messages` 返回 `forbidden`；读 DSH 源码确认判定链 = ① 带 `x-dsh-desktop-renderer` 令牌（每代随机、只在 Electron 渲染进程里）或 ② `ordinaryBrowserEnabled=true`；**当前为 false** ⇒ 普通客户端一律被拒。**脚本侧无法修**（不应伪造令牌），两条正路：打开该开关，或改走带鉴权的通道
- **测试**：`gonghai.tests.ps1` 增至 **239 断言**（新增 G20 缩水自愈 / G21 翻页 / G22 日志韧性 / G23 搜索闸 / G24 OneTalk 重建 / G25 搜索清空 / G26 中断兜底）；全量回归 **27 文件 0 失败**。**注意**：G26 第一版断言用 `Contains('$script:Abort')`，被**我自己写的注释**触发假报警，已改为只匹配代码形态
- **运行数据**：09-28 当日发出 **300+ 条**（本夜累计 500+）；台账 `公海运行问题台账.md` 增至 **50+ 行**；新增只读收工总账脚本 `tools\gonghai_night_report.ps1`

## 2026-09-28（深夜四） - 页面冻死自愈升级 / 池子首页缩水靠翻页解决（产能 6→10）/ 一个"自伤型"监控缺陷

**背景**：跨零点后继续按目标跑到 09-28 的 200 条。这一程又暴露 4 个问题，其中 1 个是**我自己巡检造成的**，1 个**直接偷走 40% 产能**。

- **GH-31 页面冻死，"刷新"救不回来**：批次 12/13/14 连续 3 轮 `ABORT 公海列表读不到（3 轮重试含刷新页仍失败）` ⇒ `exit 1` ×3 ⇒ 目标链按设计停机。**根因**：渲染进程卡死时 `Page.navigate`（刷新）**不生效** —— 反复刷新永远救不回来。**修法**：`Repair-GonghaiPublicListPage` 升级两阶段，新增 `-Force`（新增 `gonghai_cdp::Close-GonghaiPage`，走 CDP `GET /json/close/<targetId>`：**关掉卡死页再新开**）；`Read-GonghaiPublicRows` 第 1 次失败只刷新、**第 2 次起强制关页重开**。**实机验证**：卡死状态下强制重开后 `OK rows=10`
- **GH-32 "自伤型"缺陷：巡检把生产写入挡住了**：`Add-Content ... monitor.log ... used by another process`（批次 `Write-SkillLog` 抛 IOException）。**影响实证**：`GONGHAI-SENT` 行数 40 而 `rate.json` `day_count` = 41 ⇒ **真丢了一条日志行**。**根因**：PowerShell 的 `Select-String`/`Get-Content` 读文件时持有句柄、**不允许他进程写入**，而我在批次运行期间反复扫 `monitor.log`。**修法**：体检工具新增 `Read-LiveLogLines`（`File.Open(..., FileShare.ReadWrite)` 共享读）并接进 `-Action status`；纪律入台账（**监控动作本身也能干扰生产**）
- **GH-33 编辑工具会剥掉 UTF-8 BOM**：全量回归红了一次（`G7-bom-present gonghai_cdp.ps1 / gonghai_lib.ps1`）。PS 5.1 无 BOM 会按 ANSI 解码（E-10）。已补 BOM 并复跑：`gonghai` 全绿、**全量 27 文件 0 失败**。纪律：**每次改完 .ps1 立即复核 BOM**，别依赖 G7 兜底
- **GH-34 / GH-34c 池子首页「可用行」缩水 —— 每轮从 10 掉到 6（偷走 40% 产能）**：`doctor -Action pool` 显示 10 行里 **4 行 nameLen=-1**，而且这些 key **不在我们账本里**（不是我们认领的）；**连全新打开的页面也只有 6 行** ⇒ 不是页面陈旧，是**首页确实没那么多可认领的人**。所以"刷新/关页重开"（治卡死的招）对它无效。**正解：翻页**。新增 `gonghai_lib::Move-GonghaiPublicListPage`（点 `.ant-pagination-next/prev`，识别禁用态，写 `GONGHAI-LIST-PAGE`）；batch 阶段 0 升级为**三级自愈**（① 翻下一页 ② 导航刷新 ③ 关页重开，**每级只有确实更多才采用**）。**实机验证**：第 8 轮 `本页可用仅 6 行 ⇒ 翻页后可用 = 10 行（已采用）` ⇒ **认领 10 / 发出 9**（前 3 轮只有 6/5）
  > 经验：**页面级自愈能治"页面卡死"，治不了"池子没数据"** —— 诊断时先分清这两类，否则会在错的方向上加自愈层级
- **测试**：`gonghai.tests.ps1` 新增 **G20**（缩水自愈判据）与 **G21**（翻页：助手存在 / 用 `ant-pagination-next` / 识别禁用态 / **翻页先于刷新** / 只有更多才采用）；本轮全量回归 **27 文件 0 失败**（含全部改动）
- **业务成果（首次闭环验证）**：公海破冰 → 买家回音 → **进"待回复"板块** → `INQUIRY-ALERT` → 意图识别（含图片走视觉）→ 自动回复 → 记账，**零人工介入**。可见的 8 条破冰会话里 **6 条有买家回音**，其中 **2 条是真实询盘**（24V 车用空调指定三品牌；电动滑板车/电动车运以色列含清关）。⚠️ 口径警告：分母是"monitor 处理过的会话"、受快照保留限制，**6/8 不能当整体回音率**（台账 GH-14b）
- **运行数据**：台账 `公海运行问题台账.md` 增至 **41 行**（GH-01…GH-34c）；09-28 当日发出数按 `rate.json` 为准（日志因 GH-32 曾丢 1 行）

## 2026-09-27（深夜三） - 公海连跑暴露的 4 个真故障：列表页冻结自愈 / 风控探针静默失效 / 串联自匹配 / 退出码不分级

**背景**：取消限速后改为"目标链"连续跑（每批 10 个），跑起来的头 20 分钟又暴露 4 个**只有长时间连跑才会出现**的问题。全部已修，其中"列表页冻结"这条已由实机日志验证闭环。

- **GH-27 公海列表页整个冻结**（最重）：第 16 批读列表时 `CDP CMD TIMEOUT (Runtime.evaluate id=1)` ⇒ 整批 `exit 1`、串联停机；事后只读探针也读不出来（标签页与 URL 都在，页面冻死）。**根因**：phase 0 读列表**没有任何重试/自愈**（模块对 OneTalk 页早有自愈，公海列表页漏了）。**修法**：新增 `gonghai_lib::Read-GonghaiPublicRows`（最多 3 轮：读 → 失败则 `Repair-GonghaiPublicListPage` 刷新/重开页 → 再读；彻底失败返回 `$null` 交调用方显式处理）+ 认领点击加 `catch`（CDP 超时降级为"这一行失败"，不再打死整批）。**实机验证**：`GONGHAI-LIST-READFAIL try=1/3` → `GONGHAI-LIST-REPAIR reload public_customer` → 第二次读通、批次继续
- **GH-26 风控探针静默失效**：`Get-GonghaiRiskSignal` 内部 catch 后返回 `risk=false` ⇒ 求值失败与"确认无风险"不可区分，而取消限速后它是**唯一的主动止损**。改为 `raw='eval-failed'` 时打印 `WARN` + 写 `GONGHAI-RISK-EVALFAIL`
- **GH-24 串联脚本自匹配卡死**：等待判据 `CommandLine -match 'gonghai_batch\.ps1'` 会把**调用方自己的诊断命令**也算成批次（代码里注释过的"命令行自匹配陷阱"）⇒ 空转。收紧为「`-File …batch.ps1` **且** 不含 `-Command`」
- **GH-28 退出码不分级**：串联"一遇非零就停"把**可恢复**（列表冻结/认领异常 = `exit 1`）与**必须停**（风控 `9` / 模块闸 `3` / 配额 `4` / 认领上限 `10`）混为一谈。改为：`exit 1` 自动等 20 秒重试（连续 3 次才停），其余立即停
- **顺带查清（不改）**：公海首页每页 10 行里 **第 0 行是空行**（key 合法、带认领按钮，但名字列为空、行内无 `name` 类元素；连读 3 次 8 秒完全一致 ⇒ 非渲染竞态）⇒ 每批实际 9 人。**量化结论：不影响吞吐**（逐客户成本 = 认领 8s + 同步 12s + 发送 11s ≈ 31s/人，与每轮 9 还是 10 人无关），故不做翻页补足
- **测试**：`tests\gonghai.tests.ps1` 新增 **G18**（列表自愈/无本地 Read-Rows/认领 catch 的静态钉死）⇒ **191 断言全绿**；`static_call_closure.ps1` = 全库无未定义调用；`docs_consistency.tests.ps1` = 17 全绿
- **运行数据**：台账 `公海运行问题台账.md` 增至 **30 条**（已修 21 / 外部 1 / 待观察与待决定 8），并逐批记录发出数与失败原因
- **GH-29 并发闸静默失效（连跑时才抓到）**：判"有没有批次在跑"的函数返回**单元素数组**时会被 PowerShell **解包成标量**，而进程对象的 `.Count` 是 `$null` ⇒ `$null -gt 0` 恒 False ⇒ 闸门等于没有（`-DryRunProbe` 打印出空值才暴露；最小脚本对照：裸调用 `.Count=null`、加 `@()` 后 `=1`）。**后果**：若在旧链路还活着时启动新链路，两批会同时操作同一个 OneTalk 页。已修：所有调用处统一 `@(Get-RealBatchProcesses).Count`
- **GH-30 连跑逻辑工程化**：新增 `scripts\gonghai\gonghai_loop.ps1`（`-Target/-MaxRounds/-Batch/-QuietSec` 参数化；单例锁 `gonghai-loop`；**连续静默 30 秒**才开跑以避开别条链路的批间空档；退出码分级；逐轮独立日志；目标读**当天** `day_count` ⇒ 跨零点自动按新一天算；`-DryRunProbe` 空跑自检）。此前三次"目标链"都是会话里的内联字符串，不可复用、无法测试
- **测试**：`tests\gonghai.tests.ps1` 新增 **G19**（loop 脚本存在 + BOM + 并发闸排除 `-Command` + `@()` 包裹 + 单例锁与 `finally` 释放 + 静默窗口 + 退出码分级 + 读当天计数）⇒ **204 断言全绿**。G19 的断言刻意用**字面量 Contains** 而非深层正则——正则嵌套反斜杠最容易写成假绿

## 2026-09-27（深夜二） - 公海提速：取消最小间隔 + 风控闸补到 batch + 自适应止损 + 批次串联

**背景**：老板反馈"处理的效率太慢了"。实测拆解单批 ~19 分钟的去向：认领 ~85s + 等索引 135–330s + **发送 ~740s（占 64%，本质是"每条间隔 90 秒（±30%）"这道防封下限）**。老板裁决：**取消这个限制**。

- **取消最小间隔（`gonghai_min_interval_ms` = 0 = 不间隔）**：`$script:GonghaiMinIntervalFloorMs` 90000 → **0**；`Get-GonghaiWaitMs` 在间隔 ≤0 时**恒返回 0**，限速门恒放行 ⇒ 每条之间只剩页面操作耗时（约 15–20 秒）。**取消是可逆的**：抖动公式原样保留，把配置写回正数（如 90000）即恢复 63000–117000 的原节奏（由 G4 子进程用例证明）
- **⚠️ 风控闸成为唯一的主动止损手段**：`Get-GonghaiRiskSignal`（验证码/滑块/"操作过于频繁"）此前**只在 probe 里有**、batch 完全没有；现收进 `gonghai_lib.ps1`（唯一实现）并接到 **batch 的认领逐行 + 发送逐条**两处 ⇒ 命中即 `ABORT RISK_SIGNAL` + `exit 9`（不重试、不绕过）
- **索引同步改"自适应止损"**：连续 `-SyncStallSec`（默认 75s）**没有新增同步**就立刻止损，而不是等满预算。实测省下：批次8 白等 181s、批次3 白等 350s、批次5 白等 371s —— 全是"已经不会再变"的等待；有进展则继续等，不误杀慢客户
- **批次串联**：批次之间原来要我这边人工周转（每批 1–5 分钟空档）；改为一个后台作业连续跑多批（非零退出即停），空档归零
- **测试**：`tests\gonghai.tests.ps1` **183 断言全绿** —— G4 改写为"下限=0 + 现役=0 + 间隔=0 时等待恒 0 + **篡改配置回 90000 后抖动区间仍是 63000..117000**（可逆性）"；G6 改写为"间隔=0 ⇒ 刚发过也放行且 waitMs=0"（原"必须拦住"的语义随裁决消失）
- **留痕**：本裁决同时写入 `gonghai_lib.ps1` 常量注释、`config.json(.example)`、`SKILL.md` E 节、运行时 spec §6.5.5b 与 `公海运行问题台账.md`

## 2026-09-27（深夜） - 公海「流程与代码收敛」：唯一发送窗口 + 待办队列 + 模块闸 + 同步预算

**背景**：老板要求"根据目前的问题优化精简流程和代码"。当天暴露的问题几乎都是**同一个判据被写了两遍**（batch 与 probe 各一份），于是修一处、漏一处；另有三个"没有归宿"的状态（认领了却没发出去的人、失败的账本记录、没人读的模块开关）。

- **① 发送窗口收成唯一一份**：`Wait-GonghaiLock` / `Invoke-GonghaiSendWindow` 从 `gonghai_probe.ps1` **整体移入** `gonghai_lib.ps1`，batch 里那段 30 行内联窗口**删除**；两个入口现在都只是"调它"。窗口内职责固定为：取锁 → 开结果（按 customerId 挑人） → 核对身份 → 先写后发 → 发送（`-AlreadyOpen`） → 恢复页面 → 释放锁。**结构上不可能再出现两份实现**（由 `tests\gonghai.tests.ps1` 的 G10/G11 钉死：lib 恰好 1 个发送窗口、两个入口文件内**不得含发送调用**）
- **② 账本状态语义收紧**（`Get-GonghaiSendStatus` + `Complete-GonghaiSend` 唯一映射处）：`sent`/`unverified`/`failed` 一律拒发；**`notsent`（可证明没发出去：开会话失败/发对人失败/没有输入框或发送按钮）允许重试**。修掉"一条 `failed` 记录把客户永久拉黑、只能手工清账本"的坑（当天真实事故）
- **③ 新增待办队列 `data\gonghai\pending.json`**："认领成功却没发出去"的人以前**没有任何记录**（认领不可逆且占名额、公海列表里又已经没了他）⇒ 现在自动入队（键 + 明文名 + 原因），新增 `gonghai_probe.ps1 -RetryPending` 出队补发。明文名只落运行数据根（与 `data\buyers\` 同级、不入库），日志/镜像仍只有代号
- **④ 模块闸接上了**：新增 `Test-GonghaiRunnable`，batch/probe 开头统一调用 —— spec 判定链第 1 步（`disabled` 标记 / `gonghai_enabled`）**从"没有任何脚本读它"变成真闸**（运行时 REPORT §7-2 登记的缺口闭合）
- **⑤ 索引同步改"有预算"**：原来只要还剩 1 个人没同步就干等到 8 分钟（实测批次3/5 各多花 ~6 分钟）；现在超 `-SyncBudgetSec`（默认 240 秒，正常 10/10 只要 132–136 秒）即止损，straggler 转待办队列，批次不再为一个人停摆
- **⑥ 修一个本轮自测暴露的新缺陷**：`-DryRun` 演练时"搜不到"也会入队 ⇒ 会往待办队列里塞**根本没认领**的公开行（实测 21:23 踩到并清理）。已改为 DryRun 不入队
- **⑦ 工具收敛**：把排查事故时临时建的 6 个 `tools\_gh_*.ps1` 合并为**一个** `tools\gonghai_doctor.ps1`（`-Action state|mine|search|pane`，全程只读；`search`/`pane` 会持写锁并复原页面，从不填输入框、从不点发送）
- **测试**：`tests\gonghai.tests.ps1` **164 断言全绿**（G10 改为"唯一窗口 + 两入口委派"、G11 改为从 lib 抽函数跑行为、新增 NO_TAB/NO_CARDID/`-AlreadyOpen` 用例、G13/G14 指向新归属）；`tests\gonghai_chrome_isolation.tests.ps1` 与 `tests\should_reply.tests.ps1` 的发送点白名单补 `gonghai_lib.ps1`（调用点随窗口一起搬家）；`tests\run_tests.ps1` = **27 文件 / 0 失败**；`tools\dedup_acceptance\static_call_closure.ps1` = 全库无未定义调用
- **实机验证**：`probe -DryRun` 走通新窗口（不发送）；`probe -Name/-Key` 走通"搜不到 ⇒ 自动入队"；两个已知卡住的客户（`gh-01c3cbec`/`gh-6eeb3c00`）已按真实路径补进待办队列；批次6 为重构后的批量路径实机验证

## 2026-09-27（晚） - 公海：取消每日配额 + 修「认领成功却发不出去」（`OPEN_FAIL (NOT_FOUND)` 事故）

**背景**：老板要求"公海激活继续跑、每次 10 个"，并在当日已发 19 条时裁决**取消每日的限制**。当晚连跑 4 批（每批 10 个），**第 3 批暴露真实事故**：10 个里只发出去 3 个 —— 6 条 `send: OPEN_FAIL (NOT_FOUND)`、1 条索引从未同步。

### 一、事故根因（两条，都是"判据错配"）

| # | 现象 | 根因 |
|---|---|---|
| 1 | 搜索正常、`cardId` 也**精确等于**公海 `data-row-key`，但发送返回 `OPEN_FAIL (NOT_FOUND)` | `lib\send.ps1` 第 1 步要在 `.contact-item-container`（左侧会话列表）里**按名字再找一次人**。实测该列表会**冻结**（不再包含新认领的客户）⇒ 明明人已经开在对的面板里，也照样 `NOT_FOUND` |
| 2 | `✓ 身份核对通过` 之后仍可能发错人 | `gonghai_batch.ps1` 的判据是 `$open.cardId -and $open.cardId -ne $c.key` ⇒ **cardId 读不到时直接落到 else**，打印"核对通过"却**根本没核对**（fail-open） |

**补充实证**：`OPEN_FAIL` 之后**没有真的发出去**（用只读脚本回读会话正文确认：那次 `SENT_OK` 的会话里确实有破冰话术，失败的那些一条都没有）。

### 二、修复

- **`lib\send.ps1` 新增可选 `-AlreadyOpen`**（`[FIX-ALREADYOPEN]`）：调用方**显式声明**"这条会话已经打开并核对过 customerId" ⇒ 跳过第 1 步那次脆弱的列表查找。**第 2 步的会话名核对照做**（"发对人"仍是双闸），且仍在**同一个写锁窗口**内。**不传时行为与改动前逐字一致** ⇒ monitor 一行不改（与 `-Page` 同款纪律，由 `tests\send_page_param.tests.ps1` 行为级钉死）
- **公海两条发送路径都传 `-AlreadyOpen`**：`gonghai_batch.ps1`、`gonghai_probe.ps1`（后者只在 `Invoke-GonghaiSendWindow` 内调用，那里已经核对过 cardId）
- **batch 身份核对改 fail-closed**（`[FIX-FAILCLOSED]`）：读不到 `customerId` ⇒ `ABORT_NO_CARDID`、**跳过不发送**；读得到但不等 ⇒ `ABORT_WRONG_CONVO` 停机（spec §6.5.5）
- **搜索结果多条时"按 customerId 挑对的人"**（`[FIX-MULTI-RESULT]`）：`Open-GonghaiSearchResult` 新增可选 `-ExpectedKey`，在结果里**严格相等**地挑（最多前 3 条，每条约 3.5 秒），不再撞死在第 1 条上。事故样本：某客户在公海里的显示名就是占位符 `User name`，搜索返回 3 条，第 1 条不是他 ⇒ 6 轮重试全废。**不传 `-ExpectedKey` 时仍只看第 1 条**（旧语义保留）
- **恢复动作**：6 条 `failed` 的账本记录**已备份后清除**（`logs\sent_index_backup_20260927_2145.json`）—— 它们是被 `OPEN_FAIL` 挡在填字之前的、**可证明没发出去**的失败；不清掉会被幂等门永久拒发（`Test-GonghaiAlreadySent` 只看 `key_hash`、不看 status）。随后用修复后的 `probe -Name/-Key` 路径补发 **5/7 成功**；剩 2 个：1 个名字撞车（已由上面第 3 条修掉）、1 个（`gh-01c3cbec`）**阿里侧索引 1.5 小时后仍未建成**、搜索 0 结果 —— 属外部问题，待重试

### 三、配额（老板裁决：取消每日限制）

- **判据收进唯一实现**：新增 `gonghai_lib.ps1::Test-GonghaiDailyCapReached`（`0` 或负数 = **不限**，正数才当上限），`probe` 与 `batch` **都**改调它，两处内联比较删除；回显改打印 `dailyCap=unlimited`（`0` 会被读成"零配额"）
- **batch 补齐缺口**：此前 `daily_cap` **只有 probe 检查**（batch 完全不检查，属 `REPORT_回复闸门与公海缩锁_20260927.md` §7-2 登记的缺口）⇒ batch 开头先过同一道闸，并把批大小夹到"剩余额度"；上限为 0 时恒放行
- **没有一起放开的**：缺键时缺省仍是 20（配置读不到宁可少发）；最小间隔 ≥90s、单次 ≤10 条仍是硬约束 —— 本次只取消"每日总量"这一条
- `config.json` / `config.json.example` 的 `gonghai_daily_cap`：`20` → **`0`**

### 四、测试与文档

- `tests\send_page_param.tests.ps1` 新增 `-AlreadyOpen` 行为级用例（`O8=name,send` 证明跳过列表查找；`O9` 证明**跳过后仍会因会话名不符而拒发**）
- `tests\gonghai.tests.ps1` 新增 **G12**（0 = 不限；probe/batch 共用判据、不许内联重写；把 cap 篡改成 1 后复核"正数上限仍拦得住"）、**G13**（事故回归：两条发送路径必须传 `-AlreadyOpen`、batch 身份核对必须 fail-closed、send 开关必须"缺省即旧行为"、会话名核对必须留着）、**G14**（多条结果按 `customerId` 严格相等挑人；不传参数时旧语义保留）
- 被改动的 5 个脚本/测试**逐个复核 UTF-8 带 BOM**（E-10）
- `README.md` / `SKILL.md`：更正已过时的事实（单次上限 3 → **10**；公海**已不共用 9222**、跑独立 Chrome 9225；补 `gonghai_batch.ps1` 与"每日不限"的说明）
- 事故与偏差全过程见运行时数据根 `specs\REPORT_公海每日配额与OPENFAIL事故_20260927.md`（不入库）

## 2026-09-27 - 修「回得慢」与「同一条消息重复回」：冷却锚定 + 账本事实入参 + 公海缩锁

**背景**：老板报"自动回复现在回的很慢"。排查结论：**单轮回复本身没慢**（`ROUND-DONE` 中位数 8–10 秒、LLM 0.7–1.1 秒，两天一致），慢的是**等待**——两处实测事故：① 买家 买家B 收到 **3 条**回复（16:31:47 / 16:41:09 / 16:50:35，间隔 9 分半），期间 `lastBuyerHash` 与 `buyerMsgs` 恒定、列表预览逐字相同；② 买家 买家N 发来我们要的重量数据后 **8 分 43 秒**才被回复（17:24:47 到达 → 17:28:42 判据判"该回"却被 `RATE-SKIP gap=4.63m` 挡下并**又装一整段 5 分钟冷却** → 17:33:30 才发出）。规格修订见 `docs\specs\判据改为待回复列表_20260927.md` **§12**。

- **冷却锚定（消除 5+5 叠加）**：`$ctx.skipCooldown` 记录新增 `until`，写入时锚在**阻塞条件到期的那一刻**（`RATE_MIN_GAP` ⇒ 上次发送 + `reply_min_gap_min`），到期判定改精确比较（不再 `[int]` 取整提前放行）。效果：`ALREADY-REPLIED-WAIT` 的"next check"从"此刻 + 5 分钟"变成"最小间隔满的那一刻"（离线实测锚点误差 0 秒、距现在 24 秒）
- **账本事实作为判据入参（不新增出口）**：新增纯函数 `reply_engine.ps1::Test-BuyerMsgAlreadyAnswered`（账本键 `HASH|count` 与同轮抓取的"最后一条买家消息 hash + `[BUYER]` 行数"**逐字相等**）。命中 ⇒ `$seenRounds=0` ⇒ 仍由唯一出口 `Test-ShouldReply` 返回 `NOT_IN_PENDING_LIST`（Reason 集合仍是那 5 个，**没有第 6 个出口**）。证据不足一律 **fail-open 不拦**（旧格式键/条数 <1/hash 缺失）——拦错的代价是买家永远等不到回复，比多发一条更重
- **可观测**：命中写 `DUP-GUARD-HOLD`（含 `buyerCount`/`ledgerKey`/`holds`）；连续 `holds=3` 推一次 dsh-im 告警 `DUP-GUARD-ALERT`（"页面待回复标记可能是陈旧的"）交人工判断，不静默；真发出或买家说了新话则 `holds` 归零
- **冷却期内的"预览变化"改判为下探信号**：`COOLDOWN-RECHECK`（下探一次）→ `COOLDOWN-HOLD`（还是已回过的那条：重新校准预览基准 + 继续让路）或 `COOLDOWN-LIFT`（买家确实说了新话：解除**页面跳过**，冷却/最小间隔两道时间闸门**照常生效**）。§2.2/FIX-DUP 方案甲"预览变化不可信"的结论**保留**，只是不再"一律跳过"
- **公海缩锁**：`scripts\gonghai\` 把 `onetalk-write` 写锁的持有范围收到真正写页面的窗口（发对人校验与发送仍在同一持锁窗口内）。事故面：2026-09-27 全天 `LOCK-BUSY` 844 次 / 36 段，最长一段 15:59:34→16:11:28 **11.9 分钟没有任何扫描**（买家消息在这段时间里就是干等）
- **测试**：`tools\dedup_acceptance\A4_A5_A6_gate_offline.ps1` 新增 **A7**（同一条买家消息 ⇒ 发送数 0 + `DUP-GUARD-HOLD`；负对照：买家再说一句 ⇒ 发送数 1）与 **A8**（被 `RATE-SKIP` 挡下后 `until` 锚点误差 ≤5s、距现在 <60s，且时间一到就能发出）；新增 `tests\reply_gate_dupskip.tests.ps1`（纯函数真值表 + 生产接线静态断言）
- **顺手修（三处既有红项 + 一个误发入口）**：① `tests\should_reply.tests.ps1` 与 `tests\gonghai_chrome_isolation.tests.ps1` 的发送点白名单补上 `scripts\gonghai\gonghai_batch.ps1`（该文件 09-27 新增时白名单没跟上 ⇒ 两条断言一直红，属**先于本次改动**的既有红项）；② `tests\gonghai.tests.ps1` 的 4 条 G4 断言把单次运行上限 3 → **10**（老板 16:46 裁决，留痕见 `gonghai_lib.ps1`），并把"配置未被测试改坏"的复核改成**与篡改前原值比对**（不再写死策略值，以后调上限不会产生假红）；③ 被改动的 4 个脚本补/确认 **UTF-8 带 BOM**（E-10：无 BOM 时 PS 5.1 按 ANSI 解码 ⇒ 中文静默失真、可能假绿）；④ ⚠️ **误发入口**：`gonghai_batch.ps1` 的 `-DryRun` 原先只在"认领分支"出口判 ⇒ 与 `-SkipClaim` 同用时阶段3 会**真发**（脚本自己的示例写的是"只认领，不发送"）。已在阶段3 开头补一道与分支无关的闸
- **文档**：`specs\公海客户开发_20260926.md` 两处"单次上限 3 条"补 16:46 裁决留痕；运行数据根新增 `REPORT_回复闸门与公海缩锁_20260927.md`（含未解决张力与待决项）
- **未解决张力（如实登记）**：① 两处等待仍有一个 5 分钟量级的下限（`reply_min_gap_min` / `reply_post_send_cooldown_min` 均为 5，是 §0.1 老板的观察窗口决策，并被 `docs_consistency` 钉死）。现在按条去重已在位，**若要进一步缩短买家等待，该动的就是 `reply_min_gap_min`**，且必须同步 spec §0.1 / 两份 config / `docs_consistency` 的钉值断言。② 公海的**软件开关没有实现**：spec 判定链第 1 步"`disabled` 标记存在 ⇒ 拒绝（MODULE_DISABLED）"无任何脚本实现，`gonghai_enabled` 也无人据此设闸，而现役 `gonghai_enabled=true` 且标记不存在 ⇒ 任何一次手工运行 batch 都会真认领并发送（batch 连 `daily_cap` 都不检查）。建议按 spec 补一道统一闸（属"模块能不能跑"的策略面，未擅自实施）

## 2026-09-27 - 判据改用「待回复列表」：`Test-ShouldReply` 换证据锚点 + 连续 2 轮确认 + 两个限流键改配置

**背景**：09-27 13:1x 老板裁决「回复的核心是该对话在页面待回复的列表里」。实证：买家 买家G 问了 6 次报价，我方回了 6 次"马上给你报价"、真实价格 0 条、最后一句（能不能到工厂提货）无人回答，而旧判据每 9 秒判一次 `LEDGER_COUNT_MATCH` ⇒ **无限跳过**。旧判据回答的是"我发过消息了吗"，业务需要的是"客户的问题被回答了吗"。详见 `docs\specs\判据改为待回复列表_20260927.md`。

- **换判据（不是加第二个出口）**：`reply_engine.ps1::Test-ShouldReply` 仍是「是否回复」唯一出口，但证据锚点由「账本 hash / 买家消息条数」换成「该会话此刻在不在页面的待回复列表里」；原 8 行判定表收为 5 行：`LEDGER_UNUSABLE_FAILCLOSED` / `NOT_IN_PENDING_LIST` / `POST_SEND_COOLDOWN` / `RATE_MIN_GAP` / `IN_PENDING_LIST`。函数头旧论证「列表只当触发器，不当判据」**已显式标注被推翻**，防后人照旧注释改回去
- **连续 2 轮确认（瞬态误读防线）**：新增 `$ctx.pendingSeen`（会话名 → 连续命中轮数）+ `Update-PendingSeen`，每轮 `Get-Snapshot` 后**整表对齐**（命中 +1、未命中**删键**），且放在 G1 页门禁之后、会话循环之前 —— 页面被判不可用的那一轮不计入确认。只有 ≥2 轮才允许发；代价是多等 1 轮（约 9 秒）
- **两个限流值改配置键**：新增 `reply_min_gap_min`（原硬编码 15 ⇒ 缺省 **5**）与 `reply_post_send_cooldown_min`（原硬编码 3 ⇒ 缺省 **5**，且强制不小于最小间隔）。最小间隔与发送后冷却**共用同一个 `$ctx.lastSendAt`**，不各记一套。⚠️ 已知张力：最小间隔 15→5 意味着同一买家每小时最多可收到 12 条（原 4 条），这是老板为缩短观察窗口主动接受的代价；若出现重复打扰投诉，**第一个要调回的就是 `reply_min_gap_min`**
- **`NOT_IN_PENDING_LIST`（轮数不足）不写多分钟冷却**：只记 `PENDING-CONFIRM-WAIT` 一行；写冷却会让下一轮在 `TEMP-SKIP` 处被挡回，第 2 轮永远等不到（§2.1 明说这条路的代价就是 9 秒）
- **判"不发"时的冷却按新 Reason 区分**：旧 `ALREADY-REPLIED-WAIT` 的 3/6/12/15 递增不再适用（那批 Reason 全是"已回过"，而本次裁决恰恰推翻了它）；时间性/异常 Reason 写一次按配置值的短冷却，只为省页面负担
- **§4.1 裁决 = 方案甲（保守）**：账本不可读 ⇒ 整轮一条都不发（P6 保持），判据行 1 再挡一道。§4 的九项既有保护（P1–P9）全部未动
- **测试**：`tests\should_reply.tests.ps1` 按 §3.3 改写（旧 8 行 → 新 5 行**逐条语义迁移**，含"旧证据锚点已退出判定"的显式断言）；`tests\dedup_order.tests.ps1` 改写为"顺序/hash/条数都不影响结论"；新增 `tests\should_reply_v2.tests.ps1`（用 AST 取出**生产函数** `Update-PendingSeen` 驱动连续确认的整条时间线）；`tests\docs_consistency.tests.ps1` 新增"两个新键必须同时在模板与现役配置且值=5 + 冷却≥间隔"。规模见 `tests\run_tests.ps1` 输出
- **A2/A10 失效（规格演进，不是回归失败）**：旧 spec 的验收判据 A2「回放快照应回的会话账本 hash ≠ 最后买家 hash（0 例外）」与 A10「三会话 Reply=false」**随判据换锚点而失效**，已从测试中退役并在 REPORT 里逐条登记
- **实机验收**：重启 monitor（PID 10340）后，一个此前被旧判据反复挡回的买家 —— 重启前旧判据对它循环 `UNCERTAIN_FAILCLOSED` + `ALREADY-REPLIED-WAIT`，重启后第 2 轮即 `Reply=True Reason=IN_PENDING_LIST seen=2/2` 并成功发送，日志出现 `POST-SEND-COOLDOWN ... 5min`。实际秒数与观察窗口用时见运行时数据根 `specs\REPORT_判据改为待回复列表_20260927.md`（不入库）

## 2026-09-27 - 终结误发（阶段 A）：`Test-ShouldReply` 单一判据出口 + 整轮硬门禁，删除旧判据与回退分支

**背景**：09-27 11:42–11:50 恢复运行后 8 分钟内对外发出 8 条，其中至少 3 条是对不需要回复的买家重复发言（"修重复"第 6 次 `4eb39fe` 之后再次复发）。spec 判定根因不是判据不够聪明，而是"是否回复"没有**唯一出口**、且判据建立在不稳定信号（列表位置/条数/预览串）上。详见 `docs\specs\误发终止_单出口判据_20260927.md`。

- **唯一出口**：`reply_engine.ps1` 新增纯函数 `Test-ShouldReply -ConvoLines -LedgerKey -NormLastBuyerHash`，返回 `@{Reply;Reason}`；证据锚点 = "账本记录的那次回复 vs 该会话最后一条买家消息"，不依赖列表位置/条数抖动/预览串
- **删除旧出口**：整体删除 `Test-NewBuyerMessage`（其回退分支"文本 hash 不同即算新消息"是第 6 次修复失效的直接原因）；`monitor.ps1` 去重块的 `Test-DedupHit` 调用与 `$isNew/$already` 兜底闸门全部由 `Test-ShouldReply` 单点取代；`nudge.ps1` 的自动发送路径删除（改为只留内部提醒，spec §4.1）
- **整轮硬门禁**：G1 页面不可用/无 OneTalk 页 ⇒ 整轮 `ABORT-PAGE-DOWN ... action=skip-round`、零会话处理零发送；G1b 连续 2 轮升级既有 `PAGE-HEAL`（自愈失败 ≥2 次 ⇒ `ABORT-PAGE-DOWN-FATAL` 停机等人工）；G2 `ABORT_WRONG_CONVO` 升级为**整轮中止** `round-halt`；G3 冷启动第 1 个 scan cycle 只观察不发送 `COLD-START observe-only`；G4 最小版：同一买家 15 分钟内不再发第 2 条 `RATE-SKIP`（完整限流属阶段 B）
- **验收（离线，全程 monitor 停止）**：A1 全量 23 个测试文件 `failedFiles=0`；A2 213 份历史快照回放 **0 违例**；A9 用改动前代码复现事故 5 份快照的红灯（erico/Ganesan/Riyad 各至少 1 次误判"应回"）→ A10 同一现场跑绿；新增 `tests\should_reply.tests.ps1`（88 断言）与 `tools\dedup_acceptance\`（A9 红基线 + A4/A5/A6 门禁离线验收）
- ⚠️ **阶段 A 完成后监控仍保持停止**：`AlibabaAutoReplyWatchdog` / `AlibabaAutoReplyHealth` 均 Disabled，未启动任何 monitor/watchdog 进程。阶段 B（完整限流）/ C（自愈定因）/ D（经老板同意后启用并观察 30 分钟）未做

## 2026-09-27 - 公海客户开发模块（阶段 1 侦察 + 阶段 2 试发）：新增 `scripts\gonghai\` 与 71 项回归测试

**背景**：老板要求在"不猜网页结构"的前提下开发阿里公海客户。链路经规划会话只读探测 + 本次实测确认：取客户名 → 加为我的客户 → OneTalk 搜索 → 校验 customerId → 发破冰消息。**试发是对外不可逆动作**，故模块默认关（`gonghai_enabled=false`）且带多重门禁。

- 新增 `scripts\gonghai\`：`gonghai_cdp.ps1`（公海专用 CDP 桥：按域取页、短连接、凭据事件静默丢弃）、`gonghai_lib.ps1`（限速/幂等/状态/页面恢复/认领/搜索）、`gonghai_probe.ps1`（试发 CLI，判定链固定顺序）、`gonghai_recon.ps1`（只读侦察器，含凭据擦除）、`icebreaker.md`（老板定稿话术）
- **未改** `monitor.ps1` / `reply_rules.json` / `reply_agent_prompt.md` / `lib\cdp.ps1` / `cdp.ps1`：发送复用 `lib\send.ps1` 的 `Send-OneTalkMessage`、写锁复用 `lib\lock.ps1`、健康复用 `lib\cdp.ps1` 的 `Test-PageHealth`、日志复用 `lib\log.ps1` 的 `Write-SkillLog`。公海取页因既有 `Get-Page` 是 onetalk-only 守卫而**另写**，不动共享实现
- **实测纠正 4 处早期记录**：①数据行须 `tbody tr.ant-table-row`（首行是 measure-row，全 TH）②行内 **15** 个 td（含选择列）③**客户名**是 `.name--ECjwwoJJ span`（粗体 600），`.companyName--oljcmVQI` 是公司名/别名/邮箱的次要行 ④OneTalk 搜索框 `type` 属性为空串，`input[type=text]` 永不匹配，须按 placeholder 过滤
- **关键时序（务必记住）**：认领后 OneTalk 搜索索引有同步延迟（实测约 1 分钟）⇒ 立即搜索得 0 结果，**不可据此判定路径不通**；`gonghai_probe.ps1` 内置 6 次重试
- **发对人判据**：详情卡 `.alicrm-customer-detail-card` 的 `customerId` 必须**精确等于**公海行 `data-row-key`，不等即 `ABORT_WRONG_CONVO` 拒发
- 新增 `tests\gonghai.tests.ps1`（**71 断言**）：话术与定稿逐字一致 + 合规（无数字/@/价格词/群发腔）+ 幂等键 + 限速硬下限（不小于 90000ms）与抖动区间 [63000,117000] + 配置越界**硬夹回** + 状态原子写 + 幂等判定 + BOM + 禁止项静态检查（不得出现表头全选 / 清空所有筛选项 / `Invoke-PageReload` / `chrome_ensure`）
- 硬约束：每条间隔不小于 90s 且 ±30% 抖动；单次运行不超过 3 条；写锁 `Get-AppLock` 取不到不强上；**操作 OneTalk 后必恢复列表**（清空搜索 → 点「全部」→ 断言 `.contact-item-container` 数量大于 0）；遇验证码/风控立即停机
- ⚠️ **阶段 2 未完成**：已发出 **2 条**（`GONGHAI-SENT`），未达 spec 要求的完整验证；**§1 #10「公海客户回复是否进待回复板块」未验证**（发送后 monitor 恰好停摆）。偏差与事故详见运行时数据根 `specs\` 下的 REPORT（不入库）

## 2026-09-26 - 周报补跑与守护判据加严：Weekly 改每日触发 + 每周幂等；`Test-WatchdogAlive` 去掉 logon-only 兜底

- `AlibabaAutoReplyWeekly` 触发器由"每周一 08:00"（关机即整周消失，实测 09-21 08:00 机器关着、20:01 才补跑且 `LastTaskResult=2147946720`）改为**每日 08:00 + `StartWhenAvailable` 补跑 + 保留 `LogonTrigger`**；`weekly_report.ps1` 新增**每周幂等守卫**（ISO 周键，状态存 `data\weekly_state.json`）保证一周只真跑一次，避免每日重发周报推送与重复 nudge——守卫命中时输出 `WEEKLY-SKIP` 并跳过生成与 nudge，写状态失败则 fail-open（宁可重跑一次也不整周不生成）；另加 `-DryRun`（只测守卫判定、零副作用）。`Test-WatchdogAlive` 删除"有 `LogonTrigger` 就返回 `$true`"的兜底分支（该分支对病灶态假阴性），改为**只有 `TimeTrigger + Interval=PT1M + Enabled=true` 才算已武装**，`detail` 三态区分"进程死 / 仅登录触发未武装 / 有 TimeTrigger 但未 PT1M"；未改 `Get-TaskFreshness` 名单与阈值。详见 `docs\KNOWN_EXCEPTIONS.md` E-22。

## 2026-09-26 - 守护可靠启动：Watchdog 任务恢复周期拉起（PT1M）+ 计划任务新鲜度自检

- `AlibabaAutoReplyWatchdog` 任务恢复时间触发器（`Interval=PT1M` 每分钟重复 + 失败重试 `PT1M`×3），静默无守护窗口由最长约 30 分钟压到 ≤1 分钟；`health_check.ps1` 新增第 7 项检查 `scheduled_tasks_fresh`（5 个"每日/每周型"任务的 `LastRunTime` 新鲜度，Watchdog 改由 `Test-WatchdogAlive` 断言"pid 存活 + `TimeTrigger`/`PT1M` 已武装"），`status.ps1` 删除"未排程 ⇒ 登录时触发"过时旁路；详见 `docs\KNOWN_EXCEPTIONS.md` E-21。

## 2026-09-18 - P0 优化：守护加固（任务修正 + Health 自动拉起）/ 重复发送修复 / 日志与 PII 治理 / 死信心跳

**背景**：09-16 watchdog 被任务空闲条件终止（0xC000013A）后未再运行；14 天日志分析发现 725 次发送中 141 对同买家同文案、间隔 ≤600s（≈19%）的重复发送；`ACCIO-PARSE-ERR` 因保留 JSON 换行产生多行日志；工作区残留 13 条含 PII 的未跟踪案卷。用户二次拍板取消 WinSW 服务化，改为任务修正 + Health 自动拉起（全程无需 Windows 密码）。

### 守护加固（P0-1）
- `AlibabaAutoReplyWatchdog` / `AlibabaAutoReplyHealth` 任务 `StopOnIdleEnd` true→false（根因修复；对象方式修改，BEFORE/AFTER XML 留证 `specs\_evidence_20260918_p0\`）
- `health_check.ps1` F8b：`watchdog_process=FAIL` 时以分离进程拉起 `watchdog.ps1 -Action start`（幂等：pid + 命令行双确认；heal 30 分钟节流，状态键 `watchdog_heal`；`HEALTH-HEAL pid=<new>` / `HEALTH-HEAL-FAIL` 留痕，不影响 exit 0）
- 实测：启动任务 → 按 pid kill → health_check → `HEALTH-HEAL pid=1960`，新进程存活（证据 `specs\_evidence_20260918_p0\heal_test.txt`）

### 重复发送修复（P0-2）
- `reply_engine.ps1` 新增 `ConvertTo-EpochMs`（13 位毫秒/10 位秒/`yyyy-MM-dd HH:mm:ss`/`yyyy/MM/dd HH:mm:ss` → epoch ms，非法 `$null`）与 `Test-AlreadyReplied`（文本相同且 ts 不更新=已回复；任一侧 ts 缺失/不可解析=保守判已回复；新 ts 严格更大=新消息）
- `monitor.ps1` 去重块改调 `Test-AlreadyReplied`；旧无 ts 记录升级写 `DEDUP-UPGRADE`；发送成功后 3 分钟会话冷却 `POST-SEND-COOLDOWN`（preview 变化自动解除）
- `tests\reply_engine.tests.ps1` 新增 17 断言（含 sandy 回归场景）

### 日志与 PII 治理（P0-3/4）
- `lib\accio.ps1`：`ACCIO-PARSE-ERR` 单行化（JSON 换行压空格 + `jsonErr=` 异常原因 + 截断 200 字符）
- 新增 `scripts\log_rotate.ps1`（超限移入 `logs\archive\`，保留 N 份，重试 3 次×2s，`-DryRun`）与 `scripts\retention.ps1`（`data\msgs_*.txt` 超期按月份打包 `data\archive\msgs_<yyyyMM>.zip`，只碰 msgs，`-DryRun`）；monitor 启动自动执行
- 新增 `tests\log_maintenance.tests.ps1`（22 断言：轮转/保留/DryRun）
- 13 条未跟踪案卷移入 `specs\案卷_20260915\`（SHA256 全部 MATCH，MANIFEST 留档）；8 个一次性脚本移入 `specs\归档\`；AUTOOPT 产物提交 `66a9e8b`

### 死信心跳（P0-5）
- 新增 `scripts\lib\deadman.ps1`（`Send-DeadmanPing`：空 URL→skip，GET 超时 10s，异常→fail 吞掉）；`health_check.ps1` 每轮 ping，`health.log` 每 6h 一行 `DEADMAN-PING ok|fail`（`data\deadman_state.json`）
- 本地 mock 实测通过（`PING /ping` → `ok`；空 URL → `skip`）；真实 healthchecks.io URL 待用户注册后填入 `deadman_ping_url`

### 配置与文档
- `config.json(.example)` 新增 `log_max_mb`(20) / `log_keep_files`(10) / `snapshot_retention_days`(90) / `deadman_ping_url`("")
- README / SKILL / 部署说明增补；`status.ps1` watchdog 行增加命令行校验

## 2026-09-16 - watchdog 死亡事故恢复 + F5 保活实测 + F8 健康心跳告警

**事故**：2026-09-15 20:30 Windows Update 计划外重启后，watchdog（PID 15532）仅存活约 19s 即被终止（LastTaskResult=0xC000013A；Task Scheduler Operational 日志当时禁用，死因未定论），此后 17.5h 无守护；monitor（PID 17256）存活但页面无会话，持续 `Scan cycle done` 静默空转，直至 14:03 CDP 掉线触发自愈、14:05 重新登录后才恢复回复。

### F5 保活路径实测（验证通过，未改代码）
- 分离进程实测 `control-agent.ps1 -Action start` 冷启动：`finished=True elapsed=2s`，输出 `CONTROL-STARTED`；`agent_start.ps1`（WaitForExit 60s）与 `watchdog.ps1`（75s 轮询）均为有界等待。结论：现网代码不存在"保活路径永久阻塞 watchdog"，不改代码；`agent_start.ps1` 的 60s 长等待列为观察项（出现 `WATCHDOG-AGENT: timeout` 时人工关注）

### F8 健康心跳告警上线
- 新增 `scripts\health_check.ps1`（8 项检查：monitor 进程/日志新鲜度、watchdog 进程、风暴冷却、企微连通、control-agent、CDP、页面登录态；每项 30 分钟去重，恢复推送 RECOVERED），结果写 `logs\health.log`，状态写 `data\health_state.json`
- 新增计划任务 `AlibabaAutoReplyHealth`（每 15 分钟，Interactive/Limited，IgnoreNew，ExecutionTimeLimit 5 分钟）
- 端到端实测：停 watchdog → `watchdog_process=FAIL` + `HEALTH-ALERT ... SENT_OK`；恢复 watchdog → `watchdog_process=OK` + `HEALTH-RECOVER ... SENT_OK`

### 事故期间发现
- 2026-09-16 15:24 调试 Chrome 实例消失（无崩溃事件记录），CDP 掉线；monitor 因旧列表逐项重试延迟自愈，人工执行 `chrome_ensure.ps1` 恢复 Chrome 后发现登录会话已过期，页面停在登录页且 `sif_form-submit` 按钮 disabled；用 CDP 可信输入重填并提交后恢复登录（15:32 起 `hasTa:true`）。F8 的 `page_logged_in` 检查覆盖此类"CDP 通但未登录"静默故障
- Task Scheduler Operational 日志本次尝试启用失败（执行会话非管理员，`wevtutil` 拒绝访问）；需管理员手动执行 `wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true`

## 2026-09-15 - 停摆根因修复（monitor 被误杀 / 僵锁自锁 / 风暴保护永久放弃）

**事故**：04:44–07:57 停摆约 3h05m。一轮真实回复耗时 >90s → watchdog 按"日志静默 > 90s"杀掉**正在工作**的 monitor → 强杀导致 `data\onetalk-write.lock` 残留僵锁 → `Get-AppLock` 删锁却不重试（`timeoutSec=0` 时 deadline 已过）→ 后续每轮 `LOCK-BUSY` 空转且日志静默 → 再被判 stale → 再杀，5 次后触发风暴保护 `exit 1` **永久停止自愈**，无人知晓直至人工巡检。

### F1 锁自愈（`lib\lock.ps1`）
- `Get-AppLock`：判定 holder 已死后**当场重试创建锁并返回 $true**（原实现 `continue` 在 `timeoutSec=0` 时直接退出循环返回 $false）。切断"僵锁 → 空转 → 误杀 → 新僵锁"闭环
- 新增回归测试 `tests\lock.tests.ps1`（11 断言：无锁可取 / 僵锁自愈 / 活锁不抢占且不删他人锁 / 测试锁不残留）；主套件 6 → 7 文件

### F2 stale 判定（`monitor.ps1` + `watchdog.ps1` + `lib\llm.ps1`）
- (a) **轮次心跳**：回复轮次内输出 `ROUND-START / ROUND-VISION-BEGIN|END / ROUND-LLM-BEGIN|END / ROUND-LLM-WAIT / ROUND-SEND / ROUND-DONE`；LLM 阻塞等待改为 `BeginGetResponse` + 15s 心跳轮询（**超时语义不变**，仍为 `timeout_sec`，超时仍归类 TIMEOUT 不重试），响应体改分块读取（StreamReader 保持 UTF-8 解码等价），使单次最长 LLM 调用不再产生 >30s 静默
- (b) **活锁豁免**：新增 `Test-LiveWriteLock`；`onetalk-write.lock` 持有 PID 存活时，watchdog 判 stale **不杀**只记 `treated as busy, skip`；真僵死路径日志也带上锁状态，便于复盘区分"在忙"与"真死"
- (c) **阈值**：静默阈值 90 → **240s**，新增 `config.json` 键 `watchdog_log_stale_sec`（缺省 240，可覆盖）；README Phase I 记录参数与语义

### F3 风暴保护改冷却 + 告警（`watchdog.ps1` + `status.ps1`）
- 命中风暴不再 `exit 1`，改为写入 `logs\watchdog_cooldown.json`（`until`/`reason`/`count`）进入冷却（`restart_storm_cooldown_min`，缺省 30min），并推企微 `[ALERT] watchdog 重启风暴(...)，进入冷却 N 分钟；请人工检查 monitor.log`（推送失败只记日志）
- 冷却期内主循环继续运行（抑制 monitor 重启，企微/control-agent 保活照常），每分钟留一行 `COOLDOWN` 状态；到期自动清冷却、恢复完整守护；进程被杀后重启会继承未到期冷却
- `status.ps1` 新增 `WATCHDOG COOLDOWN` 行

### F4 回复轮次总预算（`monitor.ps1` + `lib\llm.ps1`）
- 新增 `config.json` 键 `reply_round_budget_sec`（缺省 180s）；每次 LLM 调用前检查剩余预算，不足则跳过该调用并标记本轮；发送前若预算已耗尽则**本轮不发送**、保留待处理、下一轮重试，日志 `ROUND-BUDGET-EXCEEDED <key> elapsed=..s budget=..s stage=..`
- 多模态/附件识别路径纳入同一预算；重试的 3s 退避与总耗时计入预算

### F7 Accio 授权降噪与可观测（`lib\accio.ps1` + `status.ps1`）
- `AUTH-REQUIRED` 做 **5 分钟负缓存**：命中后不再每轮探测 `conversations`，直接回退 CDP（回复不受影响）；日志去重（命中一行 `negative-cache 300s`，期间每 ≥60s 一行 `ACCIO-AUTH-SKIP`）
- 负缓存状态落盘 `logs\accio_auth_state.json`，跨 monitor 重启生效；`status.ps1` 新增 `Accio 授权` 行
- 该状态多与 Accio 桌面应用更新/重启窗口重合，属瞬态；恢复直读需在 Accio 桌面应用重新登录

### 其他
- `lib\accio.ps1` 补 UTF-8 BOM（原文件无 BOM，违反"所有 .ps1 必须 UTF-8 带 BOM"，导致其中文日志行按 GBK 解析出现乱码）


## 2026-09-12 - Accio 网关迁移（读取增强）与 watchdog 保活修复

### A 包：Accio 读取增强（影子→读取灰度，CDP 始终兜底）
- 新增组件 `tools\accio-client`（Node 零依赖 CLI：status/conversations/messages/send + fake gateway 测试 14 例）；协议按实测调用方式自行重写（`/mcp/proxy`；`query_recent_conversation` 包 request、`query_conversation_msg_timeRange` 扁平、`send_msg` 双边 receiverAliID）
- 新增适配层 `scripts\lib\accio.ps1`：网关探测（60s 缓存）、会话映射（买家名归一化）、消息→`[BUYER]/[ME] ... @@TS:` 行转换、影子对比（模糊匹配+覆盖率）、内容重叠校验、发送封装；失败一律回退 CDP
- `monitor.ps1`：影子/读取钩子（日志 `ACCIO-SHADOW` / `ACCIO-READ`）；**去重/最新消息基准保持 CDP**，网关仅替换回复上下文（零行为突变）
- `lib\send.ps1`：发送切换钩子（`accio_send_enabled` 默认关；网关失败回退 CDP；未对真实买家测试）
- `config.json(.example)`：新增 `accio_shadow` / `accio_read_enabled` / `accio_send_enabled`（默认 false）
- 影子对比实测：22 会话，最新买家消息 20/22 匹配（2 例为同名多线程/DOM 杂质，已有重叠校验防护）
- 登录自启：启动文件夹快捷方式 `Accio Desktop.lnk`（计划任务注册需管理员权限，未采用）
- `status.ps1`：新增 Accio 状态行（进程/端口 4097/版本）；`watchdog.ps1`：Accio 轻量探测（持续不可达记 `WATCHDOG-ACCIO`，不自动重启桌面应用）
- 测试：`tests\accio.tests.ps1`（29 断言）+ accio-client node 测试（14 例）；主套件 6 文件 245 断言全绿

### C 包：watchdog control-agent 保活修复
- 保活块新增超时留痕：75s 无 `CONTROL-` 输出 → `WATCHDOG-AGENT: timeout waiting result (will retry next cycle)`（不设冷却，下轮立即重试）
- kill 测试 2 次（含 watchdog 重启后首轮）均在 1 个周期内拉起并留 `WATCHDOG-AGENT: CONTROL-STARTED` 日志

## 2026-09-12 - 报告企微推送 + 附件识别与模型切换

### 报告推送（A 包）
- 新增 `scripts\lib\report_push.ps1`：质量/周报生成后自动推企微摘要（统计+重点项+文件名，≤800 字符）；同报告去重（`data\report_push_state.json`，上限 100）；`report_push_enabled` 开关；失败只记日志
- 挂接：`analyze_replies.ps1`（quality）/ `weekly_report.ps1`（weekly，nudge 前），全程 try/catch 不影响任务退出码
- 测试 `tests\report_push.tests.ps1`（解析器 33 断言）+ 两份 fixture

### 附件识别与模型切换（B 包）
- 模型切换：`llm_config.json` → `deepseek-v4-flash` + `thinking:{type:disabled}`（默认思考模式会耗尽 max_tokens 导致空回复，实测确认后关闭；文本延迟 ~1.5s）
- 新增 `scripts\lib\vision.ps1`（图片下载/多模态构造/提取解析/sidecar）与 `scripts\lib\doc.ps1`（CDP 页面上下文 fetch 优先 → PS 兜底 → 临时文件 → doc-reader）
- 新增组件 `tools\doc-reader`：PDF（文本层/扫描渲染）/xlsx/csv/docx → 文本或 PNG；PDF 引擎用 `@hyzyla/pdfium`（WASM；pdfjs+native canvas 实测原生崩溃）
- monitor 集成：JS 收集 `@@IMG`/`@@FILE` 标记（图片 ≤3、文件卡片兜底特征）→ PS 剥离后入快照/算 hash（格式不变）→ 图片多模态回复 / 文档解析回复 → 与回复解耦的提取调用（JSON → `data\vision_extract\<buyer>.json`，source=image/document）→ 失败回退 IMG_TEMPLATE / 普通文本流程
- `lib\goods.ps1`：Get-GoodsDataStatus / Get-GoodsDetails 合并 sidecar（weight/dims/cartons）
- 测试 `tests\vision.tests.ps1`（43 断言：data URL/多模态构造/提取解析/标记剥离 hash 稳定/sidecar/goods 合并）

## 2026-09-12 - control-agent 保活与整栈自启

- watchdog 升级五重守护：新增 control-agent 保活块（每 30s 幂等调用 `scripts\agent_start.ps1`；启动失败 5 分钟冷却；ALREADY-RUNNING/DISABLED 静默）
- 新增 `scripts\agent_start.ps1`：control-agent 保活启动器（四码：CONTROL-ALREADY-RUNNING / CONTROL-DISABLED / CONTROL-STARTED / CONTROL-START-FAIL）
- 停用标记机制：`tools\control-agent\data\control-agent.disabled`——`bin -Action stop` 自动创建（保活跳过）、`-Action start` 自动删除；status 显示 DISABLED 态
- `status.ps1` 纳入 control-agent（RUNNING/DISABLED/DOWN + agent.log 年龄）与计划任务第 5 项 `AlibabaAutoReplyWatchdog`
- 注册登录自启任务 `AlibabaAutoReplyWatchdog`（ONLOGON +30s，Hidden，ExecutionTimeLimit=PT0S 不限时，IgnoreNew）：登录后由 watchdog 带起 monitor / 企微 / control-agent

## 2026-09-12 - 精简与优化轮

### 资产归档
- 退役/休眠脚本归档：`wecom_command.ps1` / `notify.ps1` / `task_health.ps1` / `health_report.ps1` + 对应测试 → `backups\精简优化_20260912\`（manifest 可回溯，含哈希）
- 根残留清理：SKILL.md.pre / README_部署说明.md.pre / README_本地重建.md / package-lock.json / UPDATE_SPEC.md；auto_optimize 运行产物 .bak
- specs\ 已执行/报告（20 份）移入 `specs\归档\`

### 代码重构
- `cdp.ps1`：删除死分支 newtab/type/screenshot（仅保留 navigate/eval）
- CDP 端口收敛：`config.json` 新增 `cdp_port`（默认 9222），lib\cdp.ps1 / cdp.ps1 / status.ps1 / chrome_ensure.ps1 统一读取
- `reply_engine.ps1`：Generate-Reply 拆分（New-ReplyContext + Resolve-IntentEarly/Info/Data），签名与返回值不变，84 断言全绿
- `monitor.ps1`：Start-Monitor 拆分（Initialize-MonitorRuntime / Invoke-ScanRound / Invoke-ConvoItem），Cleanup-StaleState 优化为单次遍历；字面量逐字核对无丢失
- 删除零引用函数 `Get-WecomMessages`

### 提示词/语料治理
- `consolidate_prompt.ps1`：合并范围扩展到已有"历史红线归档"节，全局精确去重（32 条 → 32 条，无重复），prompt 159→143 行
- `auto_optimize.ps1`：新增 `-ConsolidateThresholdChars`（14000）/`-ConsolidateBlockThreshold`（4）阈值自动合并；never 超限由"保留最旧"改为"保留最新 40 条"并记录丢弃数

### 文档
- SKILL.md 激进瘦身（20.9KB → 6.6KB），参考区改为指向文件
- README.md 精简（-25%），事实修正（测试 140 断言 / 目录树 / 退役脚本移除）
- README_部署说明.md：计划任务 4 个、镜像新默认、control-agent 标注可选
- 镜像同步默认目录改为 `%USERPROFILE%\.config\opencode\skills\alibaba-auto-reply`

## 2026-08-24 - v2.0 大版本更新（Phase 0-3）

### 敏感信息与安全（P0）
- API key 迁入 `credentials.md`（新增 `- **API Key (api_key)**` 字段），`llm_config.json` 不再存任何敏感值
- 新建 `lib\creds.ps1`：`Get-CredentialValue` 统一解析账号/密码/API key（chrome_ensure 同步改用）
- `status.ps1` 新增"敏感信息审计"节：每次健康检查扫描 sk-key/password 明文
- `backup.ps1` 备份包不含凭据；`sync.ps1` 不推送凭据

### 目录隔离（P0）
- 运行日志 → `logs\`；买家消息快照 → `data\`；`scripts\` 仅保留代码/状态/规则；启动时自动迁移旧文件
- 涉及 9 个脚本路径拆分，全部走 `config.json` / `config.ps1` 集中配置

### 工程化（P1）
- 新增 `backup.ps1`（基线快照，保留 20 份）、`sync.ps1`（工作副本↔镜像同步）、`consolidate_prompt.ps1`（红线归档）
- 公共库五件套 `lib\`：creds / log / cdp / send / llm；monitor/nudge/chrome_ensure/watchdog/auto_optimize 全部接入，HttpWebRequest 与发送逻辑复制归零
- 回归测试 `tests\`（34 用例）：驱动修复 4 个引擎缺陷——计费/流程分支顺序、查件/询价分支顺序、Detect-Lang 西葡字典、Get-StableHash 归一化顺序
- 数据修复：reply_engine.ps1 首行乱码、reply_rules.json never 21→18 去重、auto_optimize 写入前精确去重+40 条上限、prompt 8 段红线→1 段归档
- 配置收敛：7 处硬编码兜底路径归零
- SKILL.md / README_部署说明.md 全量重写（目录结构、凭据格式、工具用法、回滚流程）

### 稳定性与性能（P2）
- reload 按需化：10 分钟 idle + 30 分钟 busy 兜底（config `reload_idle_min` 可调），替代原每 2 分钟无条件刷新
- 写互斥：`lib\lock.ps1`（锁文件+PID 存活校验+僵锁回收），monitor 每轮拿锁、nudge 发送前拿锁（10s 超时）
- 容量治理：state 记录 ≥200 条时清理 30 天无快照活动的买家；周报顺带删除 90 天前报告
- watchdog 增强：CDP 连续不可达 10 次自动跑 chrome_ensure；风暴阈值参数化（`restart_storm_count/window_min`）
- 新增 `task_health.ps1`：4 个计划任务超龄检测（Summary≤4.5h / Quality|Optimize≤26h / Weekly≤8 天）
- weekly_report 补跑机制：上次周报 >7 天自动补跑并标注
- P2.1（CDP 批量合并/常驻 daemon）评估后暂缓：热路径改动风险>收益，P2.2 已大幅降低页面负担

### 新功能（P3）
- `notify.ps1`：9 类关键事件扫描 + 30 分钟去重 → `logs\events.json`；配置 `notify_webhook` 可推企业微信/钉钉/Slack
- `dashboard.ps1`：聚合统计 HTML 看板（每日 06:00 建议），无买家 PII
- P3.4 买家档案评估后暂缓

### 已知说明
- 2026-08-24 08:00 Weekly 任务首次运行失败（新目录 logs\ 尚未创建），已补跑生成周报；补跑机制已落地
- monitor 期间两次双实例窗口（watchdog 重启竞态）已清理；单实例保护 + 写锁双重防线已生效
