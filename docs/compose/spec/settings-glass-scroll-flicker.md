---
feature: settings-glass-scroll-flicker
status: delivered
updated: 2026-09-20
branch: master
commits: f439461..(pending)
---

# 设置页滚动玻璃闪烁修复

## Report

**What was built** — 对齐书架架构，而不是简单关掉 overscroll：

1. **书架为何没事**：玻璃（分段/底栏）在滚动区外的 chrome Stack；滚动内容本身无 Lens。设置却把整卡 `LiquidGlassLens` + 滑杆/分段嵌在短 `CustomScrollView` 里。
2. **`SettingsGlassScroll` 改 glow**：Android 上用 `GlowingOverscrollIndicator`（画光晕），不用 M3 默认 stretch（`ImageFiltered` 隔离 layer → backdrop 读黑）。保留边界反馈。
3. **根页玻璃恢复 + 子页 tonal**：`SettingsGroup(glass: true)` 仅用于根页入口卡；子页控件区仍 tonal，避免卡 Lens 套滑杆 Lens。
4. **MD3 分段**：`SettingsMd3Segments`——段间 8px gap；仅首尾段外侧圆角，中间段直角。

**Verification** — `flutter analyze lib/features/shell/settings/` → No issues found。真机：拖动不再黑闪；根页入口卡有液态；明暗三段中间无圆角、有间隔。

**Journey log** — 1) 根因是 stretch 把含 Lens 的滚动区隔离进 subpass。2) `overscroll: false` 能修但丢掉边界反馈。3) glow 后根页可安全恢复整卡 Lens；子页滑杆区仍 tonal。4) MD3 SegmentedButton 外轮廓规则：>2 段时中间直角 + 段间距。

## [S1] Problem

移动端在设置子页拖动时：

1. **液态模式**：卡片底层纹理短暂变成黑色并闪烁
2. **液态 + 毛玻璃**：组件边缘高光 / 倒角闪烁后消失

对照书架：滚动区**没有** Lens（玻璃只在滚动区外 chrome Stack / 底栏），拖动无此问题。设置把整卡 `LiquidGlassLens` + `LiquidGlassSlider`/`LiquidGlassSegmented` 嵌在短 `CustomScrollView` 内；Android M3 默认 **stretch** overscroll 会把内容隔离进 `ImageFiltered` subpass，`BackdropFilter`（液态 shader 与霜面 rim 共用）读不到真实背景 → 黑闪、高光/倒角丢失。

短页几乎任意拖动都会触发 stretch，所以比长列表书架更明显。

## [S2] Design

| 决策 | 内容 |
|------|------|
| 对齐书架 | 子页控件区 tonal；根页入口卡 `glass: true` 恢复液态 |
| overscroll | 设置滚动区改 **glow**（`GlowingOverscrollIndicator`），不隔离 layer，保留边界反馈 |
| 保留液态 | 根页卡 Lens + 页内 Slider 自身 Lens；分段改 MD3 `SettingsMd3Segments` |
| MD3 分段 | 段间 gap 8；仅首尾外侧圆角，中间直角 |
| 不变 | 底栏/顶栏 chrome；书架；glassMode；Windows 强制 lite |
| 不采用 | `overscroll: false`（丢掉全部边界反馈，书架也不需要） |

实现契约：`SettingsGlassScroll` = `_GlowOverscrollBehavior`（Android 强制 glow）；`SettingsGroup` 无 Lens 路径；`SettingsScaffold` / `SettingsHubPage` 均经 `SettingsGlassScroll`。

## [S3] Out of Scope

- 书架滚动区（无 Lens）
- 阅读菜单 attached sheet
- Windows 强制 lite 策略
- 改写 `liquid_glass_easy` 包内实现

## Tasks

- [x] T1: `SettingsGlassScroll` 改 glow 而非 stretch/overscroll:false — acceptance: Android 边界仍有光晕，不触发 ImageFiltered 隔离 (covers: S2)
- [x] T2: `SettingsGroup` 去掉整卡 LiquidGlassLens，恒 tonal — acceptance: 设置子页无全卡 BackdropFilter；书架式「玻璃只在 chrome/控件」 (covers: S2; depends: T1)
- [x] T3: `flutter analyze` 通过 — acceptance: settings 相关 0 error (covers: S2; depends: T2)
