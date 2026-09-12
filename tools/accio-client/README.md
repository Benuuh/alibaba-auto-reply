# accio-client

Accio Desktop 本地网关客户端（Node，零第三方依赖）。协议按实测调用方式自行重写（未复制参考项目代码）。

## 用法

```
node cli.js status                                  # 网关可达性/鉴权探测（JSON）
node cli.js conversations [--pages N] [--count N]   # 会话列表（分页聚合去重）
node cli.js messages --conversation <id> [--limit N] [--self <aliId>] [--timeout-ms N]
node cli.js send --conversation <id> --to <buyerAliId> --self <selfAliId> --text "..." --yes
```

- 配置来源：`%USERPROFILE%\.accio\accounts\*\.accio\runtime\gateway-cli.json`（每次调用重读；Accio 每次启动会重写该文件）。
- 鉴权值仅内存使用，不打印；错误码：`GATEWAY-DOWN` / `AUTH-401` / `TIMEOUT` / `PROTOCOL-ERROR` / `AUTH-REQUIRED` / `TOOL-ERROR`。
- `send` 必须 `--yes`，仅限用户确认过的测试会话；发送后由调用方回读验证。
- stdout 仅 JSON；stderr 为人类可读信息。

## 测试

```
node --test tests/gateway.test.js tests/api.test.js
```

覆盖：分页聚合、参数包裹差异（timeRange 扁平 / query_* 包 request）、401/超时/协议错误/配置缺失、业务错误（-32001 未登录）、send 双边 receiverAliID。

## 被谁调用

- `scripts\lib\accio.ps1`（PS 适配层）→ monitor 影子/读取切换、send 灰度、status。
- `shadow_compare.ps1`：一次性影子对比（CDP 快照 vs 网关历史），仅写 monitor.log。
