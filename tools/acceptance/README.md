# 离线回复验收工具

本目录使用仓库生产模块、虚构场景和桩模型验证回复链。它不启动监控、不访问浏览器、不调用真实模型、不发送买家消息。

## 场景回放

在仓库根目录运行：

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\replay.ps1
~~~

默认报告输出到新建临时目录。可通过 `-WorkDir` 指定输出位置；工具禁止使用仓库目录、兄弟运行数据根以及本机配置中的 data/logs/reports/backups/profile 目录。不要将生产路径作为实验输出位置。

`-Filter` 选择场景，`-Quiet` 抑制输出。退出码 0 表示断言通过，1 表示失败，2 表示输出目录被拒绝。结果中的时间模拟不能作为真实响应延迟。

## 新旧回复比较

~~~powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tools\acceptance\old_vs_new.ps1
~~~

旧引擎默认固定读取重构前提交 `5356302`，不随 HEAD 前进。可通过 `-BaseRef` 指定其他经过确认的旧版本。默认报告写入 `docs/reply_comparison_20261003.md`，使用 `-OutFile` 可改到临时文件。

比较使用固定场景和新路径的固定话术，不代表真实模型效果。历史报告保留生成时结论；生产链仍需入口、模型、发送和通知验收。

## 发布前

先运行回复链与建议测试，使用桩模型回放验证实际源码。脱敏检查会阻止本机真实路径与凭据进入提交；本机配置、运行数据和临时排查脚本不入库。
