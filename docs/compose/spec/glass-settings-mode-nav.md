---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..519feec
---

# 材质与玻璃页：模式 + 底栏 液态/霜壳

## Report

**What was built** — 「材质与玻璃」页「模式」「底栏」两组改用
`SettingsFrostShell` 霜壳（方向/渐变跟随 `frostDir`/`frostGrad*`）。
「渲染材质」由 `SettingsMd3Segments` 换为 `LiquidGlassSegmented`
（液态玻璃/毛玻璃），选中 pill `primaryContainer α0.9` 且 `restStyle`
同色（外观页 T16 契约）；切换仍写入 `shell.glassMode`。
「底栏」组行标题改为「**模糊**」「**色渗滤镜**」（去掉行内「底栏」前缀，
组头仍为「底栏」）；滑杆继续 `LiquidGlassSlider`，语义/量程不变。

**Verification** —
- `flutter analyze lib/features/shell/settings/`：No issues found
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 独立审查：Spec(T1/T2)/Correctness/Consistency 均 PASS，无 critical

**Journey log** —
- 液态切换器选中态必须 glassStyle + restStyle 双层同色，否则静止回落白 pill。
- 霜壳内滑杆宽度 = 屏宽 − 页边距 32 − 壳内 padding 24。
- Windows 强制霜面说明保留在副标题；策略层不变。

## [S1] Problem

「材质与玻璃」二级页「模式」「底栏」偏 MD3 tonal：渲染材质为实色分段；
行文案「底栏模糊/底栏色渗」冗余；两组未用霜壳。用户要求液态切换、
文案精简（模糊 / 色渗滤镜）、组件用霜壳材质。

工作区：master 主 worktree（已同意）。

## [S2] Design

### 模式组

- `SettingsFrostShell` + `SettingLabel(渲染材质)` + `LiquidGlassSegmented`
- segments `['液态玻璃','毛玻璃']` / `['liquid','lite']`；height 60 / padding 10
- pill：`primaryContainer α0.9`，restStyle 同色；字色 `onPrimaryContainer`
- `onPick → n.setGlassMode`；Windows 副标题保留强制霜面说明

### 底栏组

- `SettingsFrostShell` + 组头「底栏」
- 标题：「模糊」「色渗滤镜」；滑杆 `LiquidGlassSlider` 绑
  `navBlurSigma`/`navTintStrength`（量程 0–48 / 0–1 不变）
- 滑杆宽 = `width - 32 - 24`（页 16×2 + 壳 12×2）

### 其余

- 页面色渗 / 页底渐变 / 设置页霜层 / 说明 本轮不动
- provider 字段名与 storage key 不变

## [S3] Out of Scope

- 其余分组视觉重做
- `ExpandableGlassNav` 本体
- Windows 强制 lite 策略变更
- 新增设置项

## Tasks

- [x] T1: 模式组霜壳 + 渲染材质液态切换 — acceptance: SettingsFrostShell；LiquidGlassSegmented 液态/毛玻璃；pill 派生色 restStyle 同色；仍写 glassMode (covers: S2)
- [x] T2: 底栏组霜壳 + 文案与液态控件 — acceptance: SettingsFrostShell；标题「模糊」「色渗滤镜」；LiquidGlassSlider 可调 (covers: S2)
- [x] T3: 验证 — acceptance: analyze 零新增；审查通过 (covers: S2; depends: T1,T2)
