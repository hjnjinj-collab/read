---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** —
- 液态分段/底栏/外观切换器：**动画态**透明透底 + 无阴影；**静止**
  统一 `AppGlass.restPillTint`（lerp primaryContainer→surface 0.28，
  α0.42，较高透明度派生色）
- 二级页霜壳 `SettingsFrostGate` 读 frostOn：关=floatRowFill 壳，
  开=FrostShell(blurSigma 0)；外观页 + 材质页均已接入
- 分段 ClipRRect 防模糊外泄；前景细腻 rim（T9）

**Verification** — analyze settings/nav/app_theme 零 issue；
审查指出底栏/外观 pill 未对齐后已补齐。

**Journey log** —
- rest 派生色单点 token `AppGlass.restPillTint`，勿各页各写 α。
- 动画 glassStyle 用新建 Appearance（copyWith 清不掉 shadow）。
- 二级页壳一律 `SettingsFrostGate`，勿直接 FrostShell。

## [S1] Problem

动画阴影、rest 透明度不统一、外观页 frostOn 未联动。

## [S2] Design

见 Report；契约：动画 transparent+无 shadow，静止 restPillTint。

## [S3] Out of Scope

- 根页 Group 结构、包源码

## Tasks

- [x] T1: 动画无阴影 + restPillTint 统一 + Gate 外观页 (covers: S2)
- [x] T2: 验证 — analyze + 一致性补齐 (covers: S2)
- [x] 历史: 全页霜壳/Clip/鼓动/透明动画等
