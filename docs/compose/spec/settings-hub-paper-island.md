---
feature: settings-hub-paper-island
status: delivered
updated: 2026-09-19
branch: master
commits: fde9e22..HEAD
---

# 设置根页「纸页浮雕」（方向 A 底）

## Report

**What was built** — A 底 + B 章节色带：根页连续组卡（`settingsCardRadius=16`，与二级霜壳同圆角）；组内相邻行 **装饰条**（indent 20，accent α0.14）；分区 **章节色带**——组顶 3px accent 渐变条 + 头线 accent 渐变（个性化 primary / 阅读与数据 tertiary / 隐私与关于 secondary）。图标圆 tonal、无行描边；IA/占位/悬浮底栏未改。

**Verification** — 触碰文件 analyze No issues；全量基线 25 PRE-EXISTING。真机待验。

**Journey log** —
- A 去硬后仍缺组内节奏 → B 用装饰条 + 角色色带补「目录章节」感
- 圆角 token `AppGlass.settingsCardRadius` 统一根页与二级，避免岛比子页更圆
- 色带跟 seed/角色走，不新造色板

## [S1] Problem

A 底后：组内无分隔装饰；根页圆角（26）与二级设置页不协调；需继续 B 艺术层。

## [S2] Design

A：连续组卡、无行描边、圆 tonal 图标。

B 叠层：

| 项 | 契约 |
|----|------|
| 组内装饰条 | 行间 Divider，水平 indent 20，色 accent α0.14 |
| 章节色带 | 组卡顶缘 3px accent→α0.2 渐变；分区头 4×44 accent 渐变短线 |
| 角色 | 个性化 primary · 阅读与数据 tertiary · 隐私与关于 secondary |
| 圆角 | `AppGlass.settingsCardRadius=16` 根页 float 与 `SettingsFrostGate`/`SettingsFrostShell` 共用 |

## [S3] Out of Scope

表现型色板 C、子页控件、续读卡、IA 重排

## Tasks

- [x] T1: 根页 float 真连续无行描边 (covers: S2)
- [x] T2: 圆 tonal 图标 + 渐变分区短线 (covers: S2)
- [x] T3: 路由与占位不变 (covers: S2)
- [x] T4: analyze 基线无新增 (covers: S2)
- [x] T5: 组内装饰条 + 章节色带 accent (covers: S2 B)
- [x] T6: settingsCardRadius=16 根页/二级统一 (covers: S2 B)
- [x] T7: B 轮 analyze 触碰文件 No issues (covers: S2; depends: T5, T6)
