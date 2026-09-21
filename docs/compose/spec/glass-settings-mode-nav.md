---
feature: glass-settings-mode-nav
status: delivered
updated: 2026-09-19
branch: master
commits: 3ec3693..HEAD
---

# 材质与玻璃页：全页 霜壳 + 液态切换

## Report

**What was built** — 六组统一 `_FrostSection` + 半透明液态分段。
真机修复轮：
1. `SettingsFrostShell(blurSigma<=0)` **跳过 BackdropFilter**（不再与
   内层 Lens 嵌套，消除纹理错乱/色盖）
2. 分段 pill/rest/glass 统一 `primaryContainer α0.55`（静止有透明度）
3. 轨道 blur=0（不绑底栏 navBlurSigma）；growHeight 4；选中字 `primary`
4. 顺带：底栏窄窗 `barW` 收缩；`frostSection` 包 `SliverToBoxAdapter`

**Verification** —
- `flutter analyze` settings + expandable_glass_nav：No issues
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 审查：嵌套 BF 残留为 critical，已改为条件跳过后复验 analyze PASS

**Journey log** —
- Impeller：**sigma=0 的 BackdropFilter 仍是一层 BF**，与 Lens 嵌套照样
  纹理错乱——必须 `if (blurSigma > 0)` 整层不挂。
- 设置页液态分段勿复用底栏 `navBlurSigma` 作轨道模糊。
- 静止/动画 pill 同色且半透明（α0.55），避免实色盖住折射。
- 设置页 slivers 只能放 Sliver，箱式分组必须 `SliverToBoxAdapter`。

## [S1] Problem

移动端：分段鼓动偏移、动画色盖、rest 过实、纹理错乱。
根因：霜壳 BF × Lens 嵌套；pill α0.9；轨道误用 navBlurSigma。

## [S2] Design

- 霜壳：`blurSigma: 0` 时无 BackdropFilter，仅渐变 + rim
- 分段：pill α0.55 同色双层；轨道 blur 0；grow 4；字色 primary
- provider/量程不变

## [S3] Out of Scope

- 外观页明暗分段、底栏液态本体、新增设置项

## Tasks

- [x] T1: 霜壳条件跳过 BF + 分段半透明/无轨道 blur/grow 收敛 (covers: S2)
- [x] T2: 验证 — analyze 零新增；critical 嵌套 BF 已修 (covers: S2; depends: T1)
- [x] 历史: T1–T6 全页霜壳+液态统一（519feec / 03fa5a9）
