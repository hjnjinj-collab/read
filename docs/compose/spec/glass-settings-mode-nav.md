---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 材质与玻璃页六组统一霜壳 + 液态分段；静止 pill
半透明（lerp surface α0.30）；嵌套 BF 跳过；**二级页霜壳跟随
`shell.frostOn`**（关=轻透 `floatRowFill` 壳，开=渐变 FrostShell）；
**分段轨道外轮廓** rim 明暗分档（0.42/0.26 + rimWidth）。

**Verification** — settings analyze 零 issue；本轮审查 Spec/Correctness/
Consistency 均 PASS、无 critical。真机观感待确认。

**Journey log** —
- Impeller：`blurSigma=0` 的 BackdropFilter 仍要**条件跳过**。
- 二级页霜壳必须读 `frostOn`，与根页 float 组同语义。
- 液态轨道勿 `borderWidth:0`——设置页需要可见外描边。

## [S1] Problem

二级页霜壳未关联「垫底霜层」；液态分段无外轮廓；（历史）嵌套 BF /
rest 过实。

## [S2] Design

- frostOn true → FrostShell(blurSigma:0)；false → RowShell + floatRowFill
- 分段轨道：rimWidth + 白 rim α 0.42/0.26
- pill：lerp(primaryContainer, surface, 0.28) α0.30，glass/rest 同色

## [S3] Out of Scope

- 外观页切换器、底栏 α0.9、包源码

## Tasks

- [x] T1: frostOn 联动二级页霜壳 (covers: S2)
- [x] T2: 分段外轮廓 (covers: S2)
- [x] T3: 验证 — analyze 零新增；审查 PASS (covers: S2)
- [x] 历史: 全页液态/压淡/嵌套 BF/窄窗 Sliver 等
