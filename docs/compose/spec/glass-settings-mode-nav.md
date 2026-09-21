---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 分段 ClipRRect 防模糊外泄 + 前景细腻 rim +
frostOn 联动；在 Clip **内**恢复液态鼓动：grow 6、glassStyle
blur 1.2 / shadow 8·0.14 / refraction 0.08；静止 rest 仍半透明无 blur。
峰值 46 < 轨高 60，不靠外泄表现鼓动。

**Verification** — analyze 零 issue；审查 grow/glass/Clip 契约 PASS。
请确认设置→说明→「果冻效应」为开。

**Journey log** —
- 防外泄用 Clip，不要靠清零 glass 质感（会丢鼓动）。
- 包内 Stack `Clip.none` → 外层 ClipRRect 必备。
- rim 在 Clip 兄弟层（T9）。

## [S1] Problem

模糊外泄、描边不细腻、鼓动被裁没。

## [S2] Design

- ClipRRect + 前景细腻 rim + frostOn 分支
- Clip 内 grow 6 + glass 质感；rest α0.30 无 blur

## [S3] Out of Scope

- 外观页、底栏、包源码

## Tasks

- [x] T1: Clip 内恢复 grow + glass 质感 (covers: S2)
- [x] T2: 验证 — analyze + 审查 PASS (covers: S2)
- [x] 历史: 全页霜壳/frostOn/细腻 rim 等
