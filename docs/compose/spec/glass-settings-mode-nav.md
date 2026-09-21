---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 分段/滑杆内容层 `ClipRRect` 锁模糊（包内 Stack
为 `Clip.none`，不裁会外泄）；pill/轨道 blur+shadow 清零；外轨 R16、
内 pill R10；前景 rim 细腻档（浅 0.6/α0.38 · 深 0.8/α0.30）且仍在
Clip 之外（T9）。frostOn 联动与 pill α0.30 契约保留。

**Verification** — analyze 零 issue；审查 Clip/rim/T9 层序 PASS。

**Journey log** —
- `LiquidGlassSegmented` 默认 `Clip.none` + 可选 blur/shadow → 必须外层 ClipRRect。
- rim 必须在 Clip **兄弟层**，不能进裁切内。
- `Appearance.copyWith` 清不掉 shadow，要新建 appearance。

## [S1] Problem

模糊泄露到霜壳；描边偏重、圆角不够细腻。

## [S2] Design

- ClipRRect(16) 包分段与滑杆；blur 0 / shadow null；grow 2/0
- 前景 rim 细腻档在 Clip 外
- pill lerp α0.30；frostOn 分支不变

## [S3] Out of Scope

- 外观页 grow/blur、底栏、包源码

## Tasks

- [x] T1: 分段/滑杆裁切 + 细腻 rim (covers: S2)
- [x] T2: 验证 — analyze + 审查 PASS (covers: S2)
- [x] 历史: frostOn、前景 rim T9、压淡、全页霜壳等
