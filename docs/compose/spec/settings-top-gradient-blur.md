---
feature: settings-top-gradient-blur
status: delivered
updated: 2026-09-19
branch: master
commits: 2235ca3..d0d69c9
---

# 设置页顶栏滚动渐变模糊

## Report

**What was built** — 设置页（hub + 全部 `SettingsScaffold` 子页）顶栏复刻书架
「滤镜色渐变模糊」：滚动约 56px 内显现
`ShaderMask(dstIn) → BackdropFilter(topBlurSigma) → fog(topTint)`，静止不叠模糊。

**修订轮（真机反馈）** — 前景改为 Stack：标题 `Center` **全宽水平居中**
（`Positioned` 返回键浮在左侧，不挤偏标题）。二级页返回键与模糊阈值同步：
`scrollT < 0.02` 普通箭头 `IconButton`；`scrollT ≥ 0.02` 切换为
`LiquidGlassTabBarAction` 液态圆键（40px，`AppGlass.navGlass` 渗色 +
`onSurface` 字色，`maybePop`）。静止/滚动态 **if 互斥**，同一时刻只挂一棵
Lens（Impeller 禁 AnimatedSwitcher 双 BackdropFilter）。`disableAnimations`
滚动态也不挂 Lens。hub 无返回键。

**Verification** —
- `flutter analyze lib/features/shell/settings/`：No issues found
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 修订轮独立审查：Spec(T4/T5/T6)/Correctness/Consistency 均 PASS，无 critical

**Journey log** —
- 书架顶栏参数可整段复用；设置 `headerContentH=56` 是有意差分。
- 顶栏 blur 必须在滚动区外 chrome Stack；列表内液态走 glow overscroll。
- 居中标题：`Stack + Center + Positioned(back)`，不要 `Row(leading, title)`。
- 液态返回键与雾化共用 `_blurEpsilon=0.02`，避免「有玻璃无雾底」。
- Impeller：液态控件状态切换用 if 互斥，禁止双 Lens 同挂。

## [S1] Problem

书架顶栏已有滤镜色渐变模糊，设置页原先无此效果；真机首轮后用户追加：
1. 标题应**水平居中**
2. 二级页返回键用**液态玻璃**，且**仅当渐变模糊生效时**显现液态效果

工作区：master 主 worktree（用户已明确同意）。

## [S2] Design

### 视觉契约（书架同源）

| 参数 | 取值 |
|------|------|
| 滚动显现 / 静止阈值 / 液态返回键开关 | `t=(pixels/56).clamp(0,1)`；`t<0.02` 无模糊无液态键 |
| 雾色 / 模糊 / ShaderMask / 雾渐变 | `AppGlass.topTint` / `topBlurSigma` / stops `[0,.22,.42,.62,.82,1]` |
| chrome 高 / 衰减带 | status+56 / +64（不占布局） |

### 修订契约

- 标题：全宽 `Center` + `textAlign: center`；返回键 `Positioned(left:6)` 浮层
- 返回键：静止 `IconButton(arrow_back_rounded)`；模糊生效
  `LiquidGlassTabBarAction` size 40 + `navGlass` 渗色；分支互斥
- 输入不变：`title` / `scrollT` / `showBack`

### 结构契约（延续）

- `SettingsScaffold` Stack + NotificationListener；slivers API 不变
- `SettingsHubPage`：`SettingsScaffold(title:'设置', showBack:false)`
- `SettingsBackdrop` / `SettingsGlassScroll` 契约不变

## [S3] Out of Scope

- 书源页 / 阅读页 / About 页顶栏
- 页底常显滤镜渐变
- 返回键液态可配置开关
- 标题随滚动压缩动画

## Tasks

- [x] T1: `SettingsTopChrome` + `SettingsScaffold` 滚动模糊 — acceptance: 子页滚动出现 primary 雾色渐变模糊；静止无模糊；slivers 无破坏 (covers: S2)
- [x] T2: `SettingsHubPage` 迁入共享 chrome — acceptance: 根页与子页同款顶栏；无双层 AppBar (covers: S2; depends: T1)
- [x] T3: 首轮验证 — acceptance: analyze 零新增；主题测试通过 (covers: S2; depends: T1,T2)
- [x] T4: 标题水平居中 — acceptance: 根页/子页标题顶栏全宽水平居中，不被返回键挤偏 (covers: S2)
- [x] T5: 二级页返回键液态玻璃 — acceptance: `scrollT≥0.02` 液态圆键可 pop；静止普通箭头；单 Lens；hub 无返回键 (covers: S2; depends: T4)
- [x] T6: 修订轮验证 — acceptance: settings analyze 零新增；审查通过 (covers: S2; depends: T4,T5)


