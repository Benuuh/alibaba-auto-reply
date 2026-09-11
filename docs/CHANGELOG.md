# CHANGELOG - alibaba-auto-reply

> 注：历史条目中提到的部分脚本（如 notify / task_health / health_report / wecom_command）已于 2026-09-12 归档至 `backups\精简优化_20260912\`，条目内容保留当时事实。

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
