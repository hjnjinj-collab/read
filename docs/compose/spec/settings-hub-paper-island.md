---
feature: settings-hub-paper-island
status: delivered
updated: 2026-09-19
branch: master
commits: fde9e22..HEAD
---

# 设置根页「纸页浮雕」（方向 A 底）

## Report

**What was built** — 设置根页视觉去硬（方向 A）：`SettingsGroup(float)` **强制连续一张卡**（`rowGap=0`、圆角 26、忽略 slice）；组内行无 rim、无行缝；图标改圆 tonal 徽（无描边方盒）；分区头加重 + primary→tertiary 渐变短线。IA、占位条目、悬浮底栏、路由均未改。艺术层（章节色带/表现型色板）按用户选择留待后续叠层。

**Verification** — `flutter analyze`：25 PRE-EXISTING；`settings_chrome.dart` No issues。评审源码 T1–T3 PASS；真机待验。

**Journey log** —
- 「发硬」根因是行缝+行描边+图标盒，不是 IA
- hub float 忽略 `frostStyle=slice`，与设置页霜层切片正交
- 悬浮底栏叠压 = 产品体系优势，不修
- 占位 IA 有意保留，不靠删条目「减负」

## [S1] Problem

根页每行独立描边 + 行缝 + 图标方框 → 线框感；需艺术向去硬且不改 IA/底栏。

## [S2] Design

见 `docs/design/settings-hub-visual-direction.md` 方向 A：

- 连续组卡 ClipRRect + frost 填充；行 `showBorder=false`
- 图标圆 tonal α0.12
- 分区头 + 3px 渐变短线
- 后续可叠 B/C 艺术层

## [S3] Out of Scope

章节色带/表现型色板、子页控件、续读卡、IA 重排

## Tasks

- [x] T1: 根页 float 真连续无行描边 (covers: S2)
- [x] T2: 圆 tonal 图标 + 渐变分区短线 (covers: S2)
- [x] T3: 路由与占位不变 (covers: S2)
- [x] T4: analyze 基线无新增 (covers: S2)
