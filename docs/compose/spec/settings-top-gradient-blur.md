---
feature: settings-top-gradient-blur
status: delivered
updated: 2026-09-19
branch: master
commits: 2235ca3..1cdc75c
---

# 设置页顶栏滚动渐变模糊

## Report

**What was built** — 设置页（hub + 全部 `SettingsScaffold` 子页）顶栏复刻书架
「滤镜色渐变模糊」：滚动约 56px 内显现
`ShaderMask(dstIn) → BackdropFilter(topBlurSigma) → fog(topTint)`，静止不叠模糊。

标题全宽水平居中；二级页返回键与模糊阈值同步（静止普通箭头 / 滚动
`LiquidGlassTabBarAction` 液态圆键，if 互斥单 Lens）。

**修订 3（真机）** — 标题/返回键曾观感落在模糊「下方」、顶部有空隙。现：
模糊/雾在 `ClipRect` 内作底层；标题带（`sysTop + headerContentH=64`）以
`Positioned` 叠在模糊**之上**；`sysTop = max(viewPadding.top, padding.top)`；
顶栏 spacer 与标题带一致；顶栏雾 α 加强（0.72→0.06）。

**Verification** —
- `flutter analyze lib/features/shell/settings/`：No issues found
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 各修订轮独立审查：Spec/Correctness/Consistency 均 PASS，无 critical

**Journey log** —
- 顶栏 blur 必须在滚动区外 chrome Stack；列表内液态走 glow overscroll。
- 居中标题：前景独立 `Positioned` 层，不要 `Row(leading, title)`。
- 液态返回键与雾化共用 `_blurEpsilon=0.02`。
- Impeller：液态控件状态切换用 if 互斥，禁止双 Lens 同挂。
- **修订 3**：前景必须叠在 ClipRect 模糊层之外之上；edge-to-edge 用
  `viewPadding`；标题带 64 + spacer 同源。书架 chrome 仍用 `padding.top`，
  后续可对齐 `sysTop`。

## [S1] Problem

书架顶栏已有滤镜色渐变模糊，设置页原先无此效果。真机反馈依次追加：
1. 标题应**水平居中**
2. 二级页返回键用**液态玻璃**，且**仅当渐变模糊生效时**显现
3. 标题/返回键曾落在模糊层**下方**，顶部空隙未盖住

工作区：master 主 worktree（用户已明确同意）。

## [S2] Design

### 视觉契约

| 参数 | 取值 |
|------|------|
| 滚动显现 / 静止阈值 / 液态返回键开关 | `t=(pixels/56).clamp(0,1)`；`t<0.02` 无模糊无液态键 |
| 雾色 / 模糊 / ShaderMask stops | `AppGlass.topTint` / `topBlurSigma` / `[0,.22,.42,.62,.82,1]` |
| 标题带 / 衰减带 | `sysTop + headerContentH(64)` / `+64`（不占布局） |
| 系统 inset | `sysTop = max(viewPadding.top, padding.top)` |
| 顶栏雾 α（滚动态） | 0.72 / 0.58 / 0.40 / 0.20 / 0.06 / 0 × `scrollT` |

### 结构契约

- 模糊+雾：外层 Stack 内 `Positioned.fill → IgnorePointer → ClipRect`
- 标题/返回键：同一 Stack **更后**的 `Positioned(top:0, height: band)`，
  z 序高于模糊；标题带内 `Center` 全宽居中，返回键 `left` 浮层
- 返回键：静止 `IconButton`；`scrollT≥0.02` 且非 disableAnimations 时
  `LiquidGlassTabBarAction`（40px，`navGlass`）；分支互斥
- `SettingsScaffold` spacer = `sysTop + headerContentH`；slivers API 不变
- `SettingsHubPage`：`SettingsScaffold(title:'设置', showBack:false)`

## [S3] Out of Scope

- 书源页 / 阅读页 / About 页顶栏
- 页底常显滤镜渐变
- 返回键液态可配置开关
- 标题随滚动压缩动画
- 书架 chrome 对齐 `sysTop`（后续可选）

## Tasks

- [x] T1: `SettingsTopChrome` + `SettingsScaffold` 滚动模糊 — acceptance: 子页滚动出现 primary 雾色渐变模糊；静止无模糊；slivers 无破坏 (covers: S2)
- [x] T2: `SettingsHubPage` 迁入共享 chrome — acceptance: 根页与子页同款顶栏；无双层 AppBar (covers: S2; depends: T1)
- [x] T3: 首轮验证 — acceptance: analyze 零新增；主题测试通过 (covers: S2; depends: T1,T2)
- [x] T4: 标题水平居中 — acceptance: 根页/子页标题顶栏全宽水平居中，不被返回键挤偏 (covers: S2)
- [x] T5: 二级页返回键液态玻璃 — acceptance: `scrollT≥0.02` 液态圆键可 pop；静止普通箭头；单 Lens；hub 无返回键 (covers: S2; depends: T4)
- [x] T6: 修订轮验证 — acceptance: settings analyze 零新增；审查通过 (covers: S2; depends: T4,T5)
- [x] T7: 标题/返回键叠在模糊层之上并补顶部空间 — acceptance: 滚动态标题与返回键位于雾区上部、z 序高于模糊；顶部无未盖空隙；spacer 与标题带一致 (covers: S2)
- [x] T8: 修订 3 验证 — acceptance: analyze 零新增；审查通过 (covers: S2; depends: T7)
