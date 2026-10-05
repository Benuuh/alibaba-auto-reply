# 独立复核证据索引（2026-10-06）

关联报告：[独立复核](../../../../业务约束收敛与完整闭环修复独立复核_20261006.md)。当前代码指纹与交付最终166项一致。新增探针在TEMP运行后归档；不改交付原测试、历史探针或生产。页面、模型、通知、发送均使用桩，monitor只抽取函数，没有加载主入口。

| 文件/组 | 结果 | 对应问题 |
|---|---|---|
| [全量日志](aar_closure_delivery_offline_20261006.txt) / [审计](aar_closure_delivery_offline_20261006.txt.production-audit.json) | 55文件，2994/0；隔离自证55/0；UNRESOLVED，7项变化，exit3 | 环境层次独立报告 |
| [交付指纹比对](aar_closure_delivery_hashcheck_20261006.json) | 166项、0不一致 | 所审当前代码 |
| [S1正式脚本](aar_closure_s1_independent_assertions_20261006.ps1) / [输出](aar_closure_s1_independent_assertions_20261006.txt) | 2pass/6fail，exit1 | R01/R02/R05/R07/R08；同事件和合法箱重两个阳性 |
| [S1诊断脚本](aar_closure_s1_independent_20261006.ps1) / [输出](aar_closure_s1_independent_20261006.txt) | 诊断输出，exit0不算通过 | 每组实际字段和quote/生成/校验消费者 |
| [S2实际入口脚本](aar_closure_s2_monitor_20261006.ps1) / [输出](aar_closure_s2_monitor_20261006.txt) | 2pass/2fail，exit1 | R06；实际TEMP账本记录，占位不算业务成功 |
| [S2接口诊断](aar_closure_s2_independent_20261006.ps1) / [输出](aar_closure_s2_independent_20261006.txt) | 诊断输出，不作为正式通过 | 澄清字段/计划/解析细节及其他澄清正例 |
| [托盘实际入口脚本](aar_closure_independent_pallet_monitor_20261006.ps1) / [输出](aar_closure_independent_pallet_monitor_20261006.txt) | 1pass/1fail，exit1 | R07；箱确认正常、托盘确认退化占位 |
| [来源/暂停/切根脚本](aar-review-closure-source-formal-20261006.ps1) / [输出](aar-review-closure-source-formal-20261006.ps1.txt) | 0pass/3fail，exit1 | R03/R04/R10；真实收据链与实际run_child PID/nonce |
| [C05脚本](aar_closure_independent_c05_20261006.ps1) / [输出](aar_closure_independent_c05_20261006.txt) | 2pass/2fail，exit1 | R09；普通用途解释与个人联系红线阳性/阴性仍正常 |
| [C05首次夹具加载错误](aar_closure_independent_c05_20261006.fixture-error.txt) | 缺少reply_policy加载，不计产品失败；正式脚本已修正加载 | 保留执行边界 |
| [时间实际入口脚本](aar_closure_independent_time_20261006.ps1) / [输出](aar_closure_independent_time_20261006.txt) | 6pass/0fail，exit0 | 跨日/双城/混合/未知/本地时区正例 |
| [原时间探针复跑](aar_closure_original_time_20261006.txt) | 9pass/0fail，exit0 | 原文件未改，完整错误正文被挡住 |
| [原联系入口复跑](aar_closure_original_contact_20261006.txt) | exit0，非法模型正文未到发送桩 | 原文件未改，合法供应商补问保留 |

## 复跑方法

在工作区根执行：

```powershell
$env:AAR_TEST_LAYER='Offline'
powershell -NoProfile -ExecutionPolicy Bypass -File docs/verification/architecture_opt_20261005/review_fixes/closure_independent_review_20261006/aar_closure_s1_independent_assertions_20261006.ps1
$reviewExit=$LASTEXITCODE
exit $reviewExit
```

其他正式探针替换文件名即可；它们在自身新TEMP目录运行，路径中的repo固定当前工作区。无需启停生产。不能运行编辑辅助脚本或monitor主分发。

全量使用 `tests/run_tests.ps1 -Layer Offline -KeepTemp -LogFile <TEMP日志绝对路径>`，保留原生退出码。若生产路径来源仍未证实，即使业务全绿也保留exit3。父子marker证明限于所记录上下文；R10证明未登记切根仍存在漏核验。

本目录正式失败集有重复覆盖，不按断言数累计问题；报告按10组根因和业务结果归类。证据哈希见artifact_sha256.json。