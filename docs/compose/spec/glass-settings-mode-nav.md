---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 六组霜壳跟随 `frostOn`；液态分段：外轨 R20 +
内 pill R12 嵌套；**前景 rim**（T9 层序：`Positioned.fill` +
`IgnorePointer`，浅 1.0/α0.55 · 深 1.2/α0.40），包内 border 关闭，
避免 Lens/Clip 边缘吃掉圆角描边。pill 仍为 lerp surface α0.30。

**Bug 依据** — `appearance-scheme-preview-picker` T9 / 工程约束：
rim 必须画在模糊层之上，否则圆角视觉缺角。

**Verification** — analyze 零 issue；审查对照 T9 + 圆角嵌套 PASS。

**Journey log** —
- 包内 shape.border 不可靠作唯一外轮廓——与 FrostShell 同款前景 rim。
- glass=true 时静止仍画 restStyle——glass/rest **shape 都要设**。
- 内 pill 圆角 = outerR − padding（clamp ≥12），勿用任意全胶囊。

## [S1] Problem

分段外轮廓弱/仅四角可见；内 pill 圆角与外轨不协调。（历史：frostOn
未联动二级页、rest 过实、嵌套 BF 等已修。）

## [S2] Design

- outerR 20 / pad 10 / pillR 12；glass+rest 同 shape
- 前景 rim T9 层序；包 border 关
- frostOn true=FrostShell(0) / false=RowShell+floatRowFill

## [S3] Out of Scope

- 外观页切换器、底栏、包源码

## Tasks

- [x] T1: pill 圆角嵌套 + 前景描边 (covers: S2)
- [x] T2: 验证 — analyze + 审查 PASS (covers: S2)
- [x] 历史: frostOn 联动、压淡、嵌套 BF、全页霜壳等
