# CHANGELOG - alibaba-auto-reply

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
