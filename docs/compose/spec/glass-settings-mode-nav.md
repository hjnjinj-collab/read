---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**Iconsax 方向图标** — `AppIcons.dirAxis/dirDown` + 对角 rotate。

**A+B 倒角立体感**（用户选定）—
- A 轨道包内：`borderWidth 1.0` + 白边 α0.42/0.24 + `lightIntensity 1.0`
  + refraction 0.05/14（对齐底栏光学语言）
- B 前景 bevel：上白亮 / 下暗 / 侧中，Clip 外整圈可见
- ClipRRect / restPillTint / 动画透明无阴影 契约保留

**调研结论（存档）** — 设置页曾为防外泄关掉 light/border/shadow，
前景又是单色细线，故倒角弱；底栏 `_shellFrost` 有 lightIntensity 1.1
+ 厚白边 + 接触影。

## [S1] Problem

方向图标旧；切换倒角立体感弱。

## [S2] Design

- Iconsax + rotate；A+B 光学描边与 bevel（见 Report）

## [S3] Out of Scope

- 外观页明暗分段同步光学边（可后续统一）
- 底栏本体参数

## Tasks

- [x] T1: Iconsax 方向图标 (covers: S2)
- [x] T2: 高光/描边调研 (covers: S2)
- [x] T3: A+B 倒角/立体感 (covers: S2)
