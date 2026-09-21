---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 六组霜壳 + 液态分段；嵌套 BF 跳过；静止 pill
压淡为 `lerp(primaryContainer, surface, 0.28) α0.30`（glass/rest 同色，
防色跳）；轨道 blur 0；grow 4；底栏窄窗 barW / Sliver 包装修复。

**Verification** — settings analyze 零 issue；主题测试 2 PASS；
本轮 pill 压淡审查 PASS、无 critical。真机观感待用户确认。

**Journey log** —
- Impeller：`blurSigma=0` 的 BackdropFilter 仍是一层 BF，必须条件跳过。
- 包内 rest pill 是 `DecoratedBox(color)`，α 直接生效；0.55 叠霜壳仍偏实。
- 设置页分段勿绑底栏 `navBlurSigma`。
- 箱式分组进 `slivers` 必须 `SliverToBoxAdapter`。

## [S1] Problem

材质与玻璃页液态分段：纹理错乱/色盖/过实；静止派生色仍不够半透明。

## [S2] Design

- 霜壳 `blurSigma<=0` 不挂 BF
- pill = `lerp(primaryContainer, surface, 0.28)!.withValues(alpha: 0.30)`，
  glass/rest 同色；选中字 `primary`
- 轨道 blur 0；growHeight 4

## [S3] Out of Scope

- 外观页 / 底栏 α0.9 pill；包源码；新增设置项

## Tasks

- [x] T1: rest/glass pill 压淡 — acceptance: 静止更半透明；glass/rest 同色 (covers: S2)
- [x] T2: 验证 — analyze 零新增；审查 PASS (covers: S2; depends: T1)
- [x] 历史: 全页霜壳 + 嵌套 BF 跳过 + 窄窗/Sliver 修复（b9a2741 等）
