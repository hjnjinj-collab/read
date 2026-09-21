---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 设置页液态分段契约：
- **动画/鼓动**：glassStyle `Colors.transparent` + blur/refraction/grow，
  透出底下内容，不叠派生滤镜色
- **静止**：restStyle 保留 `pillBase` 派生色（lerp surface α0.30）
- ClipRRect 防外泄；前景细腻 rim；二级页霜壳跟 frostOn

**Verification** — analyze 零 issue；审查动画透明/静止派生 PASS。

**Journey log** —
- 设置页分段：glass/rest **可拆色**（动画清玻璃 / 静止派生色）；
  底栏导航仍双层同色，勿混用。
- 防外泄用 ClipRRect，不要清零 glass 质感。
- rim 在 Clip 兄弟层（T9）。

## [S1] Problem

（历史）外泄/描边/鼓动丢失/动画态滤镜色挡内容。

## [S2] Design

- glassStyle transparent；restStyle pillBase
- Clip + 细腻 rim + frostOn

## [S3] Out of Scope

- 外观页/底栏 pill 同色语义

## Tasks

- [x] T1: 动画透明 + 静止派生色 (covers: S2)
- [x] T2: 验证 — analyze + 审查 PASS (covers: S2)
- [x] 历史: 全页霜壳/frostOn/Clip/鼓动恢复等
