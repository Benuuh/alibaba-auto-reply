# 阿里国际站自动回复系统 - 部署说明

## 部署目录结构

```
C:\path\to\alibaba-auto-reply\
├── credentials.md          ← 敏感信息唯一文件（账号/密码/API key，不入备份包）
├── llm_config.json         ← LLM 非敏感配置（model/temperature/endpoint，无 api_key）
├── SKILL.md                ← 技能说明（镜像同步对象）
├── README_部署说明.md      ← 本文档（镜像同步对象）
├── chrome-profile\         ← Chrome 登录态（含登录态，勿删除）
├── scripts\                ← 代码 + 状态 + 规则（常驻目录）
│   ├── config.json         ← 集中路径配置（换机/换目录只改此文件）
│   ├── config.ps1          ← 配置加载器（Get-SkillPath 统一取路径）
│   ├── monitor.ps1         ← 监控+自动回复主程序
│   ├── reply_engine.ps1    ← 规则回复引擎（纯逻辑，可单测）
│   ├── cdp.ps1             ← CDP 桥接（newtab/navigate/eval/screenshot）
│   ├── watchdog.ps1        ← 守护（monitor 死亡/僵死自动重启，防风暴）
│   ├── chrome_ensure.ps1   ← Chrome 自愈（重启+复用登录态+自动登录）
│   ├── status.ps1          ← 一键健康检查（含敏感信息审计）
│   ├── backup.ps1          ← 基线快照（-Snapshot → backups\，不含凭据）
│   ├── sync.ps1            ← 工作副本↔镜像同步（-Push/-Pull/-Status）
│   ├── consolidate_prompt.ps1 ← prompt 红线归档合并（-DryRun）
│   ├── summarize.ps1       ← 每 4 小时回复总结（计划任务）
│   ├── analyze_replies.ps1 ← 每日质量分析（计划任务 05:00）
│   ├── auto_optimize.ps1   ← 每日规则自动提炼（计划任务 05:30，去重+上限）
│   ├── weekly_report.ps1   ← 每周一 08:00 周报 + 顺带 nudge
│   ├── nudge.ps1           ← 沉睡买家唤醒（≥2 天未回，单买家限 1 次）
│   ├── reply_rules.json    ← 语料库（品牌/价格/收集字段/模板，可编辑）
│   ├── reply_agent_prompt.md ← LLM 回复代理提示词（可编辑）
│   ├── wecom_start.ps1     ← 企微长连接保活启动器（v2：拉起 tools\wecom-connector；watchdog 每轮调用）
│   ├── state.json(+bak)    ← 已回复去重状态（双备份）
│   └── lib\creds.ps1       ← 凭据统一解析（Get-CredentialValue）
├── logs\                   ← 运行日志（monitor.log 5MB 轮转留 20 份 / watchdog.log / out / err）
├── data\                   ← 买家消息快照 msgs_*.txt（保留 200 份，含对话 PII 勿外发）
├── reports\                ← 质量/总结/周报 md
├── backups\                ← 代码快照 zip（保留 20 份，不含凭据）
├── tools\wecom-connector\  ← 企微长连接 HTTP 桥（常驻 127.0.0.1:19886；config.json 无凭据）
└── tools\control-agent\    ← 企微自然语言远程控制（常驻；取代旧 6 命令体系）
```

## 路径配置（换机/换目录）

**不再需要全局替换**：所有脚本通过 `scripts\config.json` 取路径（config.ps1 提供 Get-SkillPath）。换机只需：

1. 把整个目录复制到新机器
2. 修改 `scripts\config.json` 中的绝对路径（deploy_root 及其派生的 scripts/logs/data/reports/chrome 等）
3. 复制 `credentials.md`（凭据单独管理，不入备份包）

## 首次初始化

1. 安装 Chrome（默认路径 `C:\Program Files\Google\Chrome\Application\chrome.exe`）
2. 创建 `credentials.md`（**敏感信息唯一文件**，账号/密码/API key 用实际值替换）：
```markdown
- **账号 (account)**：你的账号
- **密码 (password)**：你的密码
- **API Key (api_key)**：你的 DeepSeek API key
```
3. `llm_config.json` 只留非敏感项：model / temperature / max_tokens / timeout_sec / endpoint（**不要写 api_key**）
4. 运行 Chrome 自愈脚本（自动启动 Chrome、导航 OneTalk、登录）：
```powershell
powershell -ExecutionPolicy Bypass -File ...\scripts\chrome_ensure.ps1
```
5. 确认登录成功（OneTalk 页面出现消息输入框）
6. 验证登录态后启动监控（输出必须重定向，日志落在 logs\）：
```powershell
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "C:\path\to\alibaba-auto-reply\logs\monitor_out.log" -RedirectStandardError "C:\path\to\alibaba-auto-reply\logs\monitor_err.log"
```
7. 启动守护：
```powershell
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File C:\path\to\alibaba-auto-reply\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
```
8. 配置计划任务（4 个，均指向 scripts\ 下脚本）：
   - `AlibabaAutoReplySummary`：summarize.ps1，每 4 小时
   - `AlibabaAutoReplyQuality`：analyze_replies.ps1，每日 05:00
   - `AlibabaAutoReplyOptimize`：auto_optimize.ps1，每日 05:30
   - `AlibabaAutoReplyWeekly`：weekly_report.ps1，每周一 08:00（含 nudge 唤醒）

> 注：旧任务 `AlibabaAutoReplyWeComCmd` 已于 2026-09-07 企微通道升级时停用并删除（XML 备份：`backups\wecom_upgrade_20260907\AlibabaAutoReplyWeComCmd.xml`），请勿重建；企微远程控制改由 `tools\control-agent` 提供（见下节）。

## 企微通道（wecom-connector + control-agent）

自 2026-09-07 起，企微长连接与远程控制由两常驻组件提供，取代旧 `scripts\wecom\wecom_bot.js`（文件保留留档）与 6 命令轮询体系：

1. **wecom-connector**（HTTP 桥 127.0.0.1:19886）：
   - 启动/保活：watchdog 每 30s 调用 `scripts\wecom_start.ps1`（v2）。幂等三段：health connected → `WECOM-ALREADY-RUNNING`（静默）；connector 进程在但未连接 → `WECOM-NOT-CONNECTED`（等待 SDK 重连，不风暴）；否则从 credentials.md 读凭据经**环境变量注入**并调用 `tools\wecom-connector\bin\wecom-connector.ps1 -Action start` 拉起。
   - 手动管理：`powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\bin\wecom-connector.ps1 -Action start|stop|status`
   - **config.json 不含任何凭据**（host/port/data_dir/receiver_file/log_dir）；凭据只走 env。
2. **control-agent**（自然语言远程控制）：
   - 启动：`powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\bin\control-agent.ps1 -Action start|stop|status`
   - owner 锁定：config.json `owner_userid` 为空时，企微发第一条消息即自动锁定并回写 config.json；确认闸门后经 `dsh --profile headless` 执行，回发 ≤200 字总结。保活暂未并入 watchdog（遗留项）。
3. 消费方（monitor/quote_remind/notify/health_report 经 `scripts\lib\wecom.ps1`）端点同构，零代码改动。

## 常用操作

```powershell
# 健康检查（进程/CDP/日志/去重/计划任务/敏感审计）
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\status.ps1
# 代码快照（发布前必做）
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\backup.ps1 -Snapshot
# 镜像同步（改完代码后推送技能镜像；-Status 先看差异）
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\sync.ps1 -Status
powershell -ExecutionPolicy Bypass -NoProfile -File ...\scripts\sync.ps1 -Push
# 停止监控
powershell -ExecutionPolicy Bypass -File ...\scripts\monitor.ps1 -Action stop
# 查看运行状态
Get-Content ...\logs\monitor.log -Tail 20
# 查看消息快照
Get-Content ...\data\msgs_<时间戳>.txt
```

## 回滚

- **代码回滚**：解压 `backups\` 中最近快照 → 覆盖 scripts\ → 重启 monitor
- **配置回滚**：`reply_rules.json.pre` / `reply_agent_prompt.md.pre` / sync 的 `*.prev` 还原
- **状态回滚**：`state.json.bak` 还原（注意：去重记录丢失可能造成重复回复，需人工评估）
- **凭据回滚**：credentials.md 由人工保管，任何备份均不含凭据

## 注意事项

- 登录页滑块验证码无法自动通过：刷新页面通常可消除，不要反复点提交
- 监控为单实例：多实例会操作同一页面互相干扰，检查 `monitor.pid`
- 修改 `reply_rules.json` / `reply_agent_prompt.md` 后立即生效，无需重启
- **敏感信息铁律**：账号/密码/API key 只存 credentials.md；日志/报告/备份不得出现；status.ps1 每次运行自动审计
- **脚本编码**：所有 .ps1 必须 UTF-8 带 BOM（无 BOM 中文按 GBK 解析报错）
- 2026-08-24 更新：目录隔离（logs\ data\）、凭据收敛（api_key 入 credentials.md）、新增 backup/sync/consolidate 工具、weekly 补跑机制
- 2026-08-14 更新：dedup 加入消息时间戳（showTime），修复"买家重复发送同内容消息被误判为已回复导致漏回"
