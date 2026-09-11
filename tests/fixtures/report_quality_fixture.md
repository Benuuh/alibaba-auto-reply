# 自动回复质量报告

- **统计时段**: 最近 48 小时
- **生成时间**: 2026-09-12 05:00:03
- **涉及买家**: 3 位

| 买家 | 快照数 | 评分 | 负面 | 重复提问 | 新信息推进 |
|------|--------|------|------|----------|------------|
| Alice Test | 2 | -2 | ⚠️ too expensive | - | - |
| Bob Demo | 1 | 3 | - | - | ✅ |
| Carol Fake | 4 | 1 | - | - | ✅ |

## 负面案例

- **Alice Test** (2026-09-11 10:00:00): too expensive for me
  - 我方上轮回复: We will check with the team
  - 快照: msgs_fixture_20260911_100000.txt
- **Carol Fake** (2026-09-11 11:00:00): not paying extra
  - 我方上轮回复: Please allow me to verify
  - 快照: msgs_fixture_20260911_110000.txt

## 风险会话 Top1

- **Alice Test** 评分 -2，最近快照 msgs_fixture_20260911_100000.txt
- 建议人工查看该会话，必要时在 reply_rules.json 增加规则

---
质量评分说明: 负面 -3 / 重复提问 -2 / 新信息 +2 / 实质互动 +1
