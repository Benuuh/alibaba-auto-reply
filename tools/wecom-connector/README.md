# wecom-connector

企业微信官方智能机器人（@wecom/aibot-node-sdk）的独立可复用对接组件：**读取 + 发送 + 健康检查 + 多消费者游标**，通过本地 HTTP 桥（127.0.0.1，默认端口 19886）对外提供服务。从 alibaba-auto-reply 项目独立而来，可被任意项目/agent 复用。

## 架构

```
┌────────────────────────── 调用方(任意项目/agent) ──────────────────────────┐
│  PowerShell: client\wecom-client.ps1 (Conn-* 系列)                          │
│  HTTP/CLI:   curl http://127.0.0.1:19886/...  |  bin\wecom-connector.ps1    │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │ 127.0.0.1:<port> (默认 19886)
┌───────────────────────────────▼─────────────────────────────────────────────┐
│  server.js + lib\http_api.js (本地 HTTP 桥: /send /health /messages         │
│                    /cursor /receiver /status)                                │
│  lib\cursors.js(多消费者游标,持久化 data\cursors.json)                        │
│  lib\buffer.js(消息环形缓冲,上限 200)  lib\receiver.js(接收方缓存)            │
│  lib\config.js(env > config.json > 默认值)                                   │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │ @wecom/aibot-node-sdk
┌───────────────────────────────▼─────────────────────────────────────────────┐
│  企微官方 WebSocket 长连接 wss://openws.work.weixin.qq.com (自动认证/心跳/重连) │
└─────────────────────────────────────────────────────────────────────────────┘
```

设计要点（深模块思想）：

- **小接口**：HTTP 6 个端点覆盖读取/发送/游标/接收方/健康，调用方无需了解 SDK 与长连接细节。
- **多消费者游标**：每个消费方用唯一名称注册（如 `alibaba-auto-reply`、`agent-x`），各自推进自己的 `last_seq`，互不影响；游标持久化到 `data\cursors.json`，服务重启不丢。
- **游标语义 = at-least-once**：`GET /messages` 只读不推进；消费方处理完显式 `POST /cursor` 提交。崩溃重跑会重复读到未提交消息（与旧实现一致）。
- **seq 语义**：`seq = Date.now()` 毫秒，严格单调递增（同毫秒 +1），跨重启不回退；消息缓冲仅内存（上限 200 条），重启后新消息 seq 必然大于旧 seq，游标依然有效。
- **配置三层优先级**：环境变量 > 组件 `config.json` > 默认值。

## 目录结构

```
wecom-connector\
├── server.js              服务入口(node server.js [config.json 路径])
├── config.json.example    配置模板(bot 凭据占位符)
├── lib\                   服务端模块(config/cursors/buffer/receiver/http_api)
├── bin\wecom-connector.ps1 启动/停止/状态(幂等)
├── client\wecom-client.ps1 PowerShell 客户端库(Conn-* 系列,零外部依赖)
├── data\                  运行时: cursors.json / wecom_receiver.json
├── logs\                  运行时: wecom_bot.log / wecom_bot.err.log
└── tests\                 自带测试(node:test + PS 自写断言)
```

## 安装

前置：Node.js ≥ 18（开发与测试环境实测 Node v24）。

```powershell
cd wecom-connector
npm.cmd install          # 安装 @wecom/aibot-node-sdk(唯一依赖)
Copy-Item config.json.example config.json
# 编辑 config.json 填入真实 bot_id/bot_secret(仅本地,勿提交/外发)
```

## 配置

`config.json`（字段说明）：

```json
{
  "host": "127.0.0.1",
  "port": 19886,
  "data_dir": "data",
  "receiver_file": "data/wecom_receiver.json",
  "log_dir": "logs",
  "bot_id": "替换为真实 Bot ID",
  "bot_secret": "替换为真实 Secret"
}
```

| 配置项 | 环境变量覆盖 | 默认值 | 说明 |
|---|---|---|---|
| host | — | 127.0.0.1 | 监听地址（仅本机） |
| port | `WECOM_PORT` | 19886 | HTTP 桥端口（bin 启动脚本同样遵循该优先级） |
| data_dir | `WECOM_DATA_DIR` | `data`（组件目录下） | 游标/接收方缓存目录 |
| receiver_file | `WX_RECEIVER_FILE` | `data\wecom_receiver.json` | 接收方缓存文件 |
| bot_id | `WX_BOT_ID` | 空 | 企微机器人 ID |
| bot_secret | `WX_BOT_SECRET` | 空 | 企微机器人 Secret |

**凭据优先级：环境变量 > 配置文件 > 默认**。环境变量由启动方注入（更安全，不落盘）；配置文件仅限本地使用。文档与示例一律使用占位符，不出现真实凭据。

无凭据也能启动服务（health `connected=false`，`/send` 返回 503）——便于联调与迁移测试；凭据缺失会输出 WARN 日志。**自愈**：若组件以无凭据模式运行、而启动方现在提供了凭据（环境变量或配置文件），`bin\wecom-connector.ps1 -Action start` 会重启进程应用凭据（输出 `WECOM-RESTARTING`）。

## 启动 / 停止 / 状态

```powershell
powershell -ExecutionPolicy Bypass -File bin\wecom-connector.ps1 -Action start
# 输出: WECOM-STARTED (PID 1234) / WECOM-ALREADY-RUNNING (...) / WECOM-START-FAIL
powershell -ExecutionPolicy Bypass -File bin\wecom-connector.ps1 -Action stop
powershell -ExecutionPolicy Bypass -File bin\wecom-connector.ps1 -Action status
```

或直接 `node server.js`（日志到 stdout）。

## HTTP API

| 端点 | 说明 |
|---|---|
| `GET /health` | `{connected}` 企微长连接状态 |
| `POST /send` | body `{to, text}` 发送 markdown 消息；`to` = userid（单聊）或 chatid（群聊）。`400` 缺参 / `503` 未连接 / `500` 发送失败，成功 `{ok:true}` |
| `GET /messages?consumer=<名>[&after=<seq>]` | 增量读取：返回 `seq>after` 的消息（升序）。`after` 缺省取该消费者已存游标。**只读不推进游标**。响应 `{consumer, after, last_seq, cursor_seq, items[]}`；`items[]` 元素 `{seq, ts, userid, chatid, content}` |
| `GET /cursor?consumer=<名>` | `{consumer, seq, exists}` |
| `POST /cursor` | body `{consumer, seq}` 推进游标（提交已读位置）；seq 必须为非负整数，否则 `400` |
| `GET /receiver` | 接收方缓存（`{last_userid, last_chatid, last_ts}`，可空 `{}`） |
| `GET /status` | `{connected, uptime_sec, msg_count, consumers:{<名>:seq}}` 运维总览 |

## 游标语义（多消费者）

1. **独立**：消费方以唯一名称注册（首次使用即隐式注册）。`alibaba-auto-reply` 推进到 100 不影响 `agent-x` 从 0 开始读取。
2. **持久化**：游标存 `data\cursors.json`，服务重启不丢；损坏自动回退为空（不崩溃）。
3. **不丢不重（at-least-once）**：读 → 处理 → `POST /cursor` 提交。崩溃重跑会重读未提交消息（幂等处理方无副作用）。
4. **迁移**：首次使用可把旧状态文件（含 `last_seq` 字段的 JSON）作为初始游标，见 PS 客户端 `Conn-InitCursor` 或 HTTP `POST /cursor`。

## PowerShell 客户端库（client\wecom-client.ps1）

| 函数 | 返回 | 说明 |
|---|---|---|
| Conn-BaseUrl | URL | env WECOM_BASE_URL > config.json > 默认 |
| Conn-GetJson -PathAndQuery | 对象 / $null | GET+UTF8 解码统一封装（HttpWebRequest + StreamReader，防 PS 5.1 Latin-1 乱码） |
| Conn-TestService | bool | /health connected |
| Conn-GetReceiver | 对象 / $null | /receiver |
| Conn-SendMessage -Text [-To] | SENT_OK / NO_RECEIVER / SERVICE_DOWN / SEND_FAIL / SEND_ERROR: msg | 返回码与原项目 lib\wecom.ps1 完全一致 |
| Conn-GetMessages -Consumer [-After] | items 数组 / $null | 服务不可达返回 $null 不抛错 |
| Conn-GetCursor -Consumer | seq（无则 0） | — |
| Conn-SetCursor -Consumer -Seq | bool | — |
| Conn-InitCursor -Consumer -LegacyFile | SEEDED / ALREADY / NO_LEGACY / FAILED | 旧状态文件 last_seq → 组件游标 |

## 接入示例

### PowerShell 示例

```powershell
. './client/wecom-client.ps1'

# 健康检查
if (-not (Conn-TestService)) { Write-Output '服务未运行或未连接企微' }

# 发送消息(指定接收人)
Conn-SendMessage -Text '您的报价已生成' -To 'wx_userid'

# 发送消息(自动用接收方缓存 last_userid)
Conn-SendMessage -Text '老板,有新询盘'

# 增量读取 + 推进游标(消费者 agent-x 独立游标)
$msgs = Conn-GetMessages -consumer 'agent-x'
foreach ($m in $msgs) { Write-Output ($m.content) }
$max = 0
foreach ($m in $msgs) { if ([long]$m.seq -gt $max) { $max = [long]$m.seq } }
if ($max -gt 0) { [void](Conn-SetCursor -consumer 'agent-x' -seq $max) }
```

### HTTP 示例

```bash
# 健康检查
curl http://127.0.0.1:19886/health

# 发送消息
curl -X POST http://127.0.0.1:19886/send -H "Content-Type: application/json" -d '{"to":"wx_userid","text":"你的包裹已发出"}'

# 增量读取(消费者 agent-x,取游标之后的消息)
curl "http://127.0.0.1:19886/messages?consumer=agent-x"

# 提交已读位置
curl -X POST http://127.0.0.1:19886/cursor -H "Content-Type: application/json" -d '{"consumer":"agent-x","seq":12345}'

# 运维总览
curl http://127.0.0.1:19886/status
```

## 测试

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tests\run_tests.ps1
```

覆盖：node:test 40 例（缓冲/游标持久化与独立性/配置三层优先级/HTTP 全端点含 FakeBot 注入/接收方缓存）+ PS 客户端库 17 例（返回码、游标提交回读、多消费者独立、服务不可达、游标迁移）。

## 从 alibaba-auto-reply 适配（2026-08-27）

- 原 `scripts\wecom\wecom_bot.js` 与 `scripts\lib\wecom.ps1` 职责移交本组件；原项目 4 个脚本改为引用本组件（历史适配过程见 `..\specs\归档\REPORT_适配报告.md`）。
- 原项目日志 `logs\wecom_bot.log` 移交至组件 `logs\`。
