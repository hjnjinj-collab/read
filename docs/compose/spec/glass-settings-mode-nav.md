---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..c843735
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 霜壳 Gate/frostOn；液态分段动画透明无阴影、静止
`restPillTint`；Clip 防外泄；方向分段改为**纯图标**（SE/SW/S/E），
避免「左上↘右下」文字溢出 pill 且 ↘ 字形不稳。

**Verification** — analyze 通过；方向四段图标映射 tlbr/trbl/top/left。

**Journey log** —
- 短枚举优先图标 + segmentBuilder，segments 传空串占位个数。
- pill 勿写死 shape（影响包 morph 鼓动）。
- rest 派生色单点 `AppGlass.restPillTint`。

## [S1] Problem

方向切换文字溢出浮标；中间箭头字形不对。

## [S2] Design

- `dirIcons`: south_east / south_west / south / east
- valueSeg 支持 `icons` → segmentBuilder Icon(22)

## [S3] Out of Scope

- AmbientDir 副标题文案；外观页明暗文字分段

## Tasks

- [x] T1: 方向分段图标化 (covers: S2)
- [x] T2: analyze (covers: S2)
- [x] 历史: 动画/rest/霜壳 Gate 等
