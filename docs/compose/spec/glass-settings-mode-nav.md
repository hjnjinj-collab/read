---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..03fa5a9
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 「材质与玻璃」页六个分组（模式 / 底栏 / 页面色渗 /
页底渐变 / 设置页霜层 / 说明）统一套用同一视觉契约：
`_SectionHeader` + `SettingsFrostShell`（方向与渐变跟随用户
`frostDir`/`frostGrad*`）。枚举项由 `SettingsMd3Segments` 全部换成
`_LiquidValueSegmented`（`LiquidGlassSegmented`，选中 pill
`primaryContainer α0.9`，glassStyle/restStyle 双层同色）。滑杆统一
`LiquidGlassSlider`，壳内宽 `width-32-24`。行标题去组内冗余前缀。
Provider 字段、量程、storage key 均不变。

**Verification** —
- `flutter analyze lib/features/shell/settings/`：No issues found
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 独立审查：Spec(T4/T5)/Correctness/Consistency 均 PASS，无 critical

**Journey log** —
- 液态切换器必须 glassStyle + restStyle 双层同色（T16）。
- 霜壳内滑杆宽 = 屏宽 − 页边距 32 − 壳内 padding 24。
- `_FrostSection` / `_LiquidValueSegmented` 收口后全页零手写重复壳。
- 方向 UI 只暴露 4 个常用 `ambientDirs`；历史 bottom/right 值会回落显示
  为首项，直到用户重选（包行为，非本页缺陷）。

## [S1] Problem

同页部分分组曾为 MD3 tonal + `SettingsMd3Segments`，与模式/底栏不一致。
用户要求按同一思路套到其他分组。

工作区：master 主 worktree（已同意）。

## [S2] Design

### 统一契约（全页）

- 每组：`_FrostSection`（header + `SettingsFrostShell`）
- 枚举：`_LiquidValueSegmented`（pill 派生色 + restStyle 同色）
- 滑杆：`LiquidGlassSlider`，宽 `width-32-24`
- 开关：`SettingSwitchRow` 在霜壳内
- provider / storage / 量程不变；行标题去冗余前缀

### 分组

| 组 | 控件 |
|----|------|
| 模式 | 渲染材质 液态/毛玻璃 |
| 底栏 | 模糊 · 色渗滤镜 滑杆 |
| 页面色渗 | 均匀渗入开关；浅色底/深色底 滑杆 |
| 页底渐变 | 氛围渐变开关；方向 液态四段 |
| 设置页霜层 | 垫底霜层；方案/方向 液态；高度/深浅滑杆；色 chips |
| 说明 | 果冻效应开关 + 文案 |

## [S3] Out of Scope

- `ExpandableGlassNav` 本体
- Windows 强制 lite 策略
- 新增设置项 / 外观页
- 方向枚举扩到 bottom/right（UI 仍四段）

## Tasks

- [x] T1: 模式组霜壳 + 渲染材质液态切换 (covers: S2)
- [x] T2: 底栏组霜壳 + 文案与液态控件 (covers: S2)
- [x] T3: 首轮验证 (covers: S2)
- [x] T4: 页面色渗 / 页底渐变 霜壳 + 液态分段 (covers: S2)
- [x] T5: 设置页霜层 / 说明 霜壳 + 液态分段 (covers: S2)
- [x] T6: 全页验证 — acceptance: analyze 零新增；审查通过 (covers: S2; depends: T4,T5)
