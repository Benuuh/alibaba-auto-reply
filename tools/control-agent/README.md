# control-agent（企微远程 vibe coding 控制桥，单设备）

把用户在企微发的**任意自然语言指令**变成远程执行任务：常驻 Node 桥负责消息收发与安全闸门，智能执行交给**可插拔的外部执行 agent**（默认 dsh，备选 opencode / claude / 自定义命令），结果回发企微。**无固定命令、无规则匹配**——全部消息统一走"确认闸门 → 派发执行"流程，符合 vibe coding 工作流。

## 架构

```
企微消息 → wecom-connector (HTTP 127.0.0.1:19886)
              ↑ 每 5s 轮询 /messages (消费方游标 "control-agent",独立于 alibaba-auto-reply)
control-agent 桥 (Node 常驻, agent_bridge.js)：
    owner 校验 → 60s 节流
    └─ 确认闸门
       ├─ 低风险/白名单文件 → 直接派发
       └─ 高风险 → 回发 4 位确认码 → 你回复确认 → 派发
              ↓ CLI 子进程(可插拔)
    外部执行 agent(默认 dsh --profile headless;可换 opencode/claude/自定义命令)
              ↓ 执行结果(≤200 字总结)
control-agent 桥 → POST /send 回发 owner(截断 4000 字符)
```

## 安装

前置：Node ≥ 18；wecom-connector 已运行（HTTP 桥 19886）；dsh 全局安装（默认 executor）。

```powershell
# 1. 安装默认执行 agent dsh(可选备选: opencode-ai)
npm.cmd install -g @deepseek-ai/dsh

# 2. 复制配置模板并编辑
Copy-Item config.json.example config.json
#    owner_userid 可留空(首次消息自动识别并写入)

# 3. 启动 / 状态 / 停止
powershell -ExecutionPolicy Bypass -File bin\control-agent.ps1 -Action start
powershell -ExecutionPolicy Bypass -File bin\control-agent.ps1 -Action status
powershell -ExecutionPolicy Bypass -File bin\control-agent.ps1 -Action stop
```

> **dsh 模型 key**：dsh 使用 `control_api_key`（alibaba-auto-reply credentials.md 同字段）。按 dsh 官方配置方式传入（`~/.dsh/.credentials.yaml` 或 `DEEPSEEK_API_KEY` 环境变量），**不写死在 config/代码中**；未配置时开放式指令回发配置提示，不崩溃。

## 保活与停用（watchdog 集成）

- **保活**：主仓库 `scripts\watchdog.ps1`（五重守护）每 30s 幂等调用 `scripts\agent_start.ps1`：进程在跑 → 静默；未跑 → 文件重定向调 `bin\control-agent.ps1 -Action start`（60s 上限）拉起；启动失败 → watchdog.log 记一行并 5 分钟冷却（避免刷屏）。
- **停用标记**：`data\control-agent.disabled`（纯 ASCII 时间戳）。
  - `bin\control-agent.ps1 -Action stop` → 停止进程并**创建标记**；保活见标记即跳过（静默），不会自动拉起。
  - `bin\control-agent.ps1 -Action start` → 启动并**删除标记**（恢复保活意图）。
  - 也可手动删除标记文件后由 watchdog 下轮自动拉起。
- **status**：主仓库 `scripts\status.ps1` §1 显示 control-agent 三态：RUNNING（PID + agent.log 年龄）/ DISABLED（停用标记）/ DOWN（保活将在下轮拉起）。
- **整栈自启**：计划任务 `AlibabaAutoReplyWatchdog`（登录 +30s，Hidden，不限时）拉起 watchdog，由 watchdog 带起 monitor / 企微 / control-agent。

## 配置项表（config.json）

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `wecom_base_url` | `http://127.0.0.1:19886` | wecom-connector HTTP 桥（env `WECOM_BASE_URL` 优先） |
| `consumer` | `control-agent` | 消费方游标名（独立，不影响 alibaba-auto-reply） |
| `owner_userid` | 空（自动识别） | 仅该 userid 的消息可执行。**留空时自动识别**：首次收到企微消息（receiver 最近发消息人）即锁定并写入 config.json |
| `projects` | 三个项目映射 | 指令提及项目名（如 "alibaba-auto-reply"）→ 派发到该项目目录 |
| `whitelist_files` | reply_rules.json / reply_agent_prompt.md / config.json | 白名单文件：仅涉及它们的写操作免确认 |
| `executor.type` | `dsh` | 可插拔执行 agent：`dsh` / `opencode` / `claude` / `command` |
| `executor.command` | `dsh --profile headless {prompt}` | 命令模板，`{prompt}` 占位符由执行器做 cmd 安全转义（整体加引号、内部双引号→单引号、换行→空格，**模板内不要自行加引号**） |
| `executor.timeout_sec` | 300 | 派发超时（超时杀进程树并回发失败） |
| `executor.workdir` | 工作区根 | 未命中 projects 时的默认工作目录 |
| `use_llm_classify` | `false` | 可选：用 control_api_key 调 DeepSeek 补充风险判断（默认纯规则零依赖） |
| `classify_key_file` | alibaba credentials.md | 仅当 `use_llm_classify=true` 时读取「控制 Agent API Key (control_api_key)」，绝不落盘/入日志/回发 |
| `poll_interval_ms` / `throttle_sec` / `confirm_ttl_sec` / `reply_max_chars` | 5000 / 60 / 300 / 4000 | 轮询周期 / 同内容节流 / 确认码有效期 / 回发截断 |
| `data_dir` / `logs_dir` | data / logs | 状态与日志（cursor.json / pending.json / history.jsonl / agent.log 5MB×10 轮转） |

### executor 可插拔示例（只改 config，桥代码不感知具体 agent）

```json
// dsh(默认)
"executor": { "type": "dsh", "command": "dsh --profile headless {prompt}", "timeout_sec": 300, "workdir": "../../.." }

// opencode 备选(win 下用 opencode.cmd,.ps1 垫片会被执行策略挡)
"executor": { "type": "opencode", "command": "opencode.cmd run {prompt} --format text", "timeout_sec": 300, "workdir": "../../.." }

// claude 备选
"executor": { "type": "claude", "command": "claude -p {prompt}", "timeout_sec": 300, "workdir": "../../.." }

// 任意自定义命令({prompt} 占位)
"executor": { "type": "command", "command": "python D:\\tools\\runner.py {prompt}", "timeout_sec": 120, "workdir": "../../.." }
```

## 指令语义（全部自然语言，无固定命令）

| 你想做的 | 直接发 | 是否需要确认 |
|---|---|---|
| 运维 | "重启一下监控服务" / "看看今天的回复情况怎么样" | 重启类命中高风险 → **确认码** |
| 改语料 | "把砍价话术改得更友善" | 白名单文件 → 免确认 |
| 查数据 | "帮我在 alibaba-auto-reply 里查最近发送失败的记录" | 低风险直发（派发到对应项目目录） |
| 写代码/任意任务 | "给 wecom-connector 的 /messages 加个分页参数" | 低风险直发 |
| 闲聊/问候 | "你好" / "你能做什么" | 直发（executor 自行理解回答） |

> "你能做什么"类问题不需要固定 help 命令——执行 agent（dsh）会自行理解并回答。

## 确认流程

- **高风险判定**（正则命中即需确认码）：删除/覆盖类（Remove-Item/rm/del/覆盖写入）、重启/停止服务（restart/stop/kill/Stop-Process）、格式化、网络外联（Invoke-WebRequest 等）、系统目录（C:\Windows\）、凭据相关
- **白名单免确认**：指令只涉及白名单文件（reply_rules.json / reply_agent_prompt.md / config.json）且无高风险词 → 直接派发
- **可选 LLM 兜底**：`use_llm_classify=true` 时用 DeepSeek 补充风险判断（默认关闭，纯规则零依赖）
- **确认码流程**：高风险 → 回发 `[高风险操作] 将执行: <摘要> 回复 确认<4位码> 执行(5 分钟内有效)` → 回复确认码后派发执行并清除；不匹配/过期 → 提示；启动时清理过期项

## 派发 prompt 模板

executor 收到的指令 prompt 包含：角色（企微远程控制执行 agent）、工作目录、技能位置（`skills-main\skills\engineering\` 的 implement/tdd/code-review/diagnosing-bugs，会话内读取 SKILL.md 执行）、任务原文、要求（只做指令要求之事、≤200 字中文总结、白名单文件允许直接修改并展示 diff 摘要、不输出凭据/不删除关键文件）。

## 与 wecom-connector 对接

- 轮询 `GET /messages?consumer=control-agent&after=<游标>`（只读不推进）；处理后 `POST /cursor` 提交服务端游标（at-least-once 权威），并本地持久化 `data\cursor.json` 双保险（重启不丢）
- 回发 `POST /send`；单设备简化：单一消费方、单 owner、全部状态本地

## 状态与日志

- `data\cursor.json`：游标（重启不丢）
- `data\pending.json`：待确认（5 分钟过期自动清理）
- `data\history.jsonl`：追加式历史（时间/seq/消息/风险/是否确认/派发结果摘要，上限 1000 条滚动）
- `logs\agent.log`：`yyyy-MM-dd HH:mm:ss | msg`，5MB 轮转留 10 份

## 测试

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
```

覆盖（46 例）：风险规则、白名单、确认码生成/匹配/过期、节流、executor 模板/工作目录、分类 JSON 容错与兜底、状态持久化；集成 mock（mock wecom-connector HTTP + fake executor/classifier）：开放式直发、高风险确认流、白名单免确认、非 owner 忽略、executor 不可用回发错误不崩溃、节流、问候直发、确认码不匹配/过期、owner 自动识别。

## 目录结构

```
control-agent\
├── agent_bridge.js         桥主入口(主循环/owner/节流/确认闸门/派发)
├── config.json.example     配置模板(owner_userid 可留空自动识别)
├── lib\
│   ├── config.js           配置加载(env > config.json > 默认)
│   ├── gate.js             确认闸门(高风险确认码/白名单免确认)
│   ├── executor.js         可插拔执行层(dsh/opencode/claude/command)
│   ├── safety.js           高风险规则+白名单
│   ├── classify.js         可选 LLM 风险分类(JSON 容错+规则兜底)
│   ├── creds.js            control_api_key 只读(不落盘)
│   ├── state.js            游标/待确认/历史存储
│   ├── log.js              日志轮转
│   └── wecom_client.js     wecom-connector HTTP 客户端
├── bin\control-agent.ps1   幂等启停/状态(PID 文件防双实例)
├── data\ / logs\           运行时状态与日志
├── docs\停用旧命令.md       旧 wecom_command 系统停用步骤
└── tests\                  46 例(node:test + 集成 mock)
```

## 停用旧系统

`alibaba-auto-reply\scripts\wecom_command.ps1` 已标记停用（v0.4 起**不再迁移其 6 命令逻辑**，全部开放式指令由执行 agent 理解），计划任务 `AlibabaAutoReplyWeComCmd` 停用步骤见 `docs\停用旧命令.md`（schtasks /Delete 命令，不擅自删除）。watchdog.ps1 保留不动。
