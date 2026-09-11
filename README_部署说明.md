# 阿里国际站自动回复系统 - 部署说明

> 本文档是**部署与运维手册**；项目总览、特性与原理见根 `README.md`。内容对应 2026-09 结构（monitor/watchdog 主程序 + wecom-connector/control-agent 企微组件）。

## 一、部署目录结构

```
<部署根>\alibaba-auto-reply\
├── credentials.md          ← 敏感信息唯一文件（账号/密码/API key/Bot 凭据，不入库不入备份）
├── llm_config.json         ← LLM 非敏感配置（model/temperature/max_tokens/timeout_sec/endpoint）
├── SKILL.md / README.md / README_部署说明.md ← 技能说明与文档（镜像同步对象）
├── chrome-profile\         ← Chrome 登录态（含登录态，勿删除）
├── scripts\                ← 代码 + 状态 + 规则（常驻目录）
│   ├── config.json         ← 集中路径配置（由 config.json.example 复制；换机/换目录只改此文件）
│   ├── config.ps1          ← 配置加载器（Get-SkillPath 统一取路径）
│   ├── monitor.ps1         ← 监控+自动回复主程序（单实例）
│   ├── reply_engine.ps1 / reply_rules.json / reply_agent_prompt.md ← 回复引擎/语料/提示词（后两者可热编辑）
│   ├── cdp.ps1             ← CDP 桥接
│   ├── chrome_ensure.ps1   ← Chrome 自愈（重启+复用登录态+自动登录）
│   ├── watchdog.ps1        ← 守护（monitor 死亡/僵死重启；CDP 连不可达 10 次自动 chrome_ensure；防风暴）
│   ├── wecom_start.ps1     ← 企微保活启动器 v2（幂等三段，watchdog 每 30s 调用）
│   ├── status.ps1          ← 一键健康检查（进程/CDP/日志/去重/任务/敏感审计）
│   ├── backup.ps1 / sync.ps1 / consolidate_prompt.ps1 ← 快照/镜像同步/红线归档
│   ├── summarize.ps1 / analyze_replies.ps1 / auto_optimize.ps1 ← 计划任务脚本（4h/05:00/05:30）
│   ├── weekly_report.ps1 / nudge.ps1 / quote_remind.ps1 ← 周报+唤醒 / 报价提醒 CLI
│   ├── dashboard.ps1 / notify.ps1 / health_report.ps1 / task_health.ps1 ← 看板/告警/健康/任务巡检
│   ├── wecom_command.ps1   ← 旧六命令远程控制（已停用留档，勿启用）
│   ├── state.json(+bak)    ← 已回复去重状态（双写）
│   └── lib\                ← 公共库（creds/log/cdp/send/llm/lock/goods/quote/wecom）
├── tools\
│   ├── wecom-connector\    ← 企微 HTTP 桥（Node 常驻 127.0.0.1:19886；bin\wecom-connector.ps1 启停）
│   │   ├── config.json     ← 由 config.json.example 复制（host/port/data_dir/receiver_file/log_dir，无凭据）
│   │   ├── client\wecom-client.ps1   ← PowerShell 客户端库（Conn-* 系列，零依赖可复用）
│   │   └── data\ / logs\ / tests\    ← 游标与接收方缓存 / 日志 / 57 例测试
│   └── control-agent\      ← 企微自然语言远程控制桥（Node 常驻；bin\control-agent.ps1 启停）
│       ├── config.json     ← 由 config.json.example 复制（owner_userid 留空=首条消息自动锁定）
│       └── data\ / logs\ / tests\    ← 游标/待确认/历史 / 日志 / 46 例测试
├── logs\                   ← 运行日志（monitor.log 5MB 轮转留 20 份 / watchdog.log / out / err）
├── data\                   ← 买家消息快照 msgs_*.txt（保留 200 份，含对话 PII 勿外发）；manual_override.json=人工接管白名单（企微"白名单"指令维护，热生效≤10s）
├── reports\                ← 质量/总结/周报 md
├── backups\                ← 代码快照 zip（保留 20 份，不含凭据；含 2026-09-07 企微升级任务 XML 备份）
└── docs\CHANGELOG.md       ← 版本变更记录
```

## 二、前置条件

| 依赖 | 要求 | 说明 |
|---|---|---|
| Windows | 10+ | 全脚本 PowerShell 5.1 |
| Chrome | 默认安装路径 | `C:\Program Files\Google\Chrome\Application\chrome.exe`（config.json 可改） |
| Node.js | ≥ 18（实测 24） | 仅企微通道需要（wecom-connector / control-agent） |
| git | 可选 | 克隆与镜像同步 |
| dsh | 可选 | control-agent 默认外部执行 agent：`npm.cmd install -g @deepseek-ai/dsh` |

## 三、首次部署（分阶段）

### Phase A：代码与依赖
```powershell
git clone https://github.com/Benuuh/alibaba-auto-reply.git
cd alibaba-auto-reply
# 企微通道依赖（不需要企微可跳过，但建议装齐便于后续启用）
cd tools\wecom-connector; npm install; cd ..\..
cd tools\control-agent; npm install; cd ..\..
# dsh（control-agent 默认执行 agent，可选备选 opencode/claude）
npm.cmd install -g @deepseek-ai/dsh
```

### Phase B：路径与凭据配置
1. `Copy-Item scripts\config.json.example scripts\config.json`，把 `deploy_root` 与派生路径改为实际绝对路径（换机只改此文件）
2. 创建根目录 `credentials.md`（**敏感信息唯一文件**，格式见根 README；账号/密码/API Key 用实际值；企微 Bot ID/Secret 启用企微时填）
3. `llm_config.json` 只保留非敏感项，**不要写 api_key**
4. 企微组件配置（如需）：复制两个 `config.json.example` → `config.json`；**config 不含任何凭据**——Bot ID/Secret 由启动器经环境变量注入
5. 自检：`git status` 确认 credentials.md、chrome-profile、logs/data/reports/backups 均未被跟踪；全库搜索不得出现凭据明文

### Phase C：Chrome 登录 OneTalk
```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\chrome_ensure.ps1
```
- 自动启动 Chrome（独立 chrome-profile）、导航 OneTalk 并尝试登录；验证标志：页面出现消息输入框、CDP 9222 可访问
- 滑块验证码无法自动通过：刷新页面通常可消除，**不要反复点提交**；必要时人工完成一次登录，登录态持久保存
- 多实例注意：chrome_ensure 使用独立 profile，不影响日常浏览器

### Phase D：启动监控与守护
```powershell
# 启动 monitor（输出必须重定向，日志落 logs\）
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\monitor.ps1 -Action start" -WindowStyle Hidden -RedirectStandardOutput "<部署根>\logs\monitor_out.log" -RedirectStandardError "<部署根>\logs\monitor_err.log"
# 启动 watchdog
Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\watchdog.ps1 -Action start" -WindowStyle Hidden
# 验证
Get-Content <部署根>\logs\monitor.log -Tail 20
```
监控为**单实例**：启动前检查 `scripts\monitor.pid`；`-Action stop` 正常停止。

### Phase E：企微通道（wecom-connector + control-agent）
```powershell
# 1. 启动 HTTP 桥（凭据经环境变量注入：WX_BOT_ID/WX_BOT_SECRET；启动器自动注入）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\wecom-connector\bin\wecom-connector.ps1 -Action start
#    输出 WECOM-STARTED / WECOM-ALREADY-RUNNING；查看连接状态：
curl http://127.0.0.1:19886/health   # {"connected":true}

# 2. 启动远程控制桥
powershell -ExecutionPolicy Bypass -NoProfile -File tools\control-agent\bin\control-agent.ps1 -Action start

# 3. owner 绑定：config.json 的 owner_userid 留空时，向机器人发第一条消息即自动锁定并回写
# 4. 保活：watchdog 每 30s 调用 scripts\wecom_start.ps1（幂等三段，无风暴）
```
- 消费方（monitor/quote_remind/notify/health_report 经 `scripts\lib\wecom.ps1`）端点同构，零额外配置
- control-agent 保活暂未并入 watchdog（遗留项，用其 `bin\control-agent.ps1` 手动管理）
- 无凭据时 HTTP 桥也可启动（`connected=false`，/send 返回 503），便于联调

### Phase F：计划任务（5 个，均指向 scripts\ 下脚本）
| 任务名 | 脚本 | 周期 |
|---|---|---|
| `AlibabaAutoReplySummary` | summarize.ps1 | 每 4 小时 |
| `AlibabaAutoReplyQuality` | analyze_replies.ps1 | 每日 05:00 |
| `AlibabaAutoReplyOptimize` | auto_optimize.ps1 | 每日 05:30 |
| `AlibabaAutoReplyWeekly` | weekly_report.ps1（含 nudge 唤醒） | 每周一 08:00 |
| `AlibabaAutoReplyWatchdog` | watchdog.ps1 | 用户登录时（+30s 延迟，Hidden） |

- watchdog 自启任务 = 整套常驻的恢复入口：watchdog 启动后自动拉起 monitor / Chrome 自愈 / 企微保活；任务幂等（watchdog.pid 单实例检测），与手动启动的实例并存无害，重复触发直接退出
- watchdog 自身的守护即本任务（2026-09-10 注册，解决 Windows Update/手动重启后常驻进程无人拉起问题）；未启用无人登录（ONSTART/自动登录）场景，注销重登录或重启即生效

注册示例（管理员）：`schtasks /Create /TN AlibabaAutoReplyQuality /TR "powershell.exe -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\analyze_replies.ps1" /SC DAILY /ST 05:00 /F`（Summary 用 `/SC HOURLY` 或等距任务）。
- 旧任务 `AlibabaAutoReplyWeComCmd` 已于 2026-09-07 企微通道升级时停用并删除（XML 备份：`backups\wecom_upgrade_20260907\`），**请勿重建**；企微远程控制由 control-agent 提供
- 建议额外注册：`dashboard.ps1`（每日 06:00）、`health_report.ps1`（按需/每日）；`task_health.ps1` 手动巡检任务超龄（Summary≤4.5h / Quality|Optimize≤26h / Weekly≤8 天）

### Phase G：首次验收
```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File <部署根>\scripts\status.ps1
```
逐项确认：monitor/watchdog 进程、CDP 9222、日志新鲜度、去重状态、企微 connected、计划任务、敏感审计无 [!!] 级问题。

## 四、常用运维

| 操作 | 命令 |
|---|---|
| 健康检查 | `scripts\status.ps1` |
| 查看运行状态 | `Get-Content logs\monitor.log -Tail 20` |
| 停止/启动监控 | `scripts\monitor.ps1 -Action stop/start` |
| 企微桥状态 | `tools\wecom-connector\bin\wecom-connector.ps1 -Action status`（control-agent 同款） |
| 代码快照（发布前必做） | `scripts\backup.ps1 -Snapshot` |
| 镜像同步 | `scripts\sync.ps1 -Status` / `scripts\sync.ps1 -Push` |
| 报价提醒手动触发 | `scripts\quote_remind.ps1` |
| 发送测试消息 | 见 `tools\wecom-connector\client\wecom-client.ps1`（Conn-SendMessage） |

**配置热更新**：改 `scripts\reply_rules.json` / `reply_agent_prompt.md` 立即生效，无需重启；改 config.json 类路径/凭据后需重启对应进程。

## 五、回滚

- **代码回滚**：解压 `backups\` 中最近快照 → 覆盖 `scripts\` → 重启 monitor
- **配置回滚**：`reply_rules.json.pre` / `reply_agent_prompt.md.pre` / 各 `.prev` 还原（backup.ps1 自动留 .pre）
- **状态回滚**：`state.json.bak` 还原（注意：去重记录丢失可能造成重复回复，需人工评估）
- **凭据回滚**：credentials.md 由人工保管，任何备份均不含凭据

## 六、故障排查

| 现象 | 排查 |
|---|---|
| status [!!] 双实例 | 检查 monitor.pid，停止多余实例；写锁 `lib\lock.ps1` 兜底 |
| 滑块验证码 | 刷新页面消除，勿反复提交；必要时人工登录一次 |
| /health connected=false | Bot ID/Secret 注入是否正确；`bin\wecom-connector.ps1 -Action start` 自愈重启应用凭据 |
| LLM 全失败/回退规则 | 检查 credentials.md api_key、llm_config endpoint；看 monitor.log |
| 计划任务超龄 | 运行 `task_health.ps1`；检查 schtasks 是否被禁用/权限 |
| monitor 日志乱码 | .ps1 必须 UTF-8 带 BOM 保存（无 BOM 中文按 GBK 解析） |
| 控制台输出重定向失败 | monitor 启动必须带 -RedirectStandardOutput/-RedirectStandardError |

## 七、注意事项与变更记录

- 登录页滑块验证码无法自动通过：刷新页面通常可消除，不要反复点提交
- 监控为单实例：多实例会操作同一页面互相干扰
- 修改 `reply_rules.json` / `reply_agent_prompt.md` 后立即生效，无需重启
- **人工接管白名单**：企微向机器人发「白名单 添加 <客户名>」→ 该买家不再自动回复（只读快照 + [NEW-INQUIRY] 提醒；报价/唤醒免打扰）；「白名单 删除」即恢复；名单存 `data\manual_override.json`（损坏/缺失=空名单，热生效≤10s，无需重启 monitor）
- **敏感信息铁律**：账号/密码/API key/Bot 凭据只存 credentials.md（企微组件凭据走环境变量）；日志/报告/备份不得出现；status.ps1 与 .githooks 双重审计
- **脚本编码**：所有 .ps1 必须 UTF-8 带 BOM
- 变更记录（详见 docs\CHANGELOG.md）：
  - 2026-09-07：企微通道升级 v2——wecom-connector（HTTP 桥 19886）+ control-agent（自然语言远程控制，取代旧 6 命令体系）；`AlibabaAutoReplyWeComCmd` 计划任务停用删除；watchdog 企微保活改 wecom_start.ps1 v2
  - 2026-08-27：企微长连接职责移交独立组件 tools\wecom-connector（原 scripts\wecom\wecom_bot.js、scripts\lib\wecom.ps1 移交适配）
  - 2026-08-24：v2.0——目录隔离（logs\ data\）、凭据收敛（api_key 入 credentials.md）、lib\ 公共库五件套、tests 34→36 用例、backup/sync/consolidate 工具、watchdog 风暴防护、计划任务超龄检测与补跑
  - 2026-08-14：dedup 加入消息时间戳（showTime），修复同内容重复发送被误判已回复
- 2026-08-24 备注：Quality/Weekly 类任务首跑需 logs\ 存在（目录由 status/部署创建后即可）
