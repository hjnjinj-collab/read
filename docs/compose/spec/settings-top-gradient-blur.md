---
feature: settings-top-gradient-blur
status: delivered
updated: 2026-09-19
branch: master
commits: 2235ca3..82eb089
---

# 设置页顶栏滚动渐变模糊

## Report

**What was built** — 设置页（hub + 全部经 `SettingsScaffold` 的子页）顶栏
复刻书架「滤镜色渐变模糊」：静止只画标题行；滚动约 56px 内显现
`ShaderMask(dstIn) → BackdropFilter(AppGlass.topBlurSigma) → fog(AppGlass.topTint)`
并叠 primary 雾渐变（α 随 scrollT）。`SettingsChrome`（header 56 / blur 延伸 64）
与 `SettingsTopChrome` 落在 `settings_chrome.dart`；`SettingsScaffold` 改为
Stack + NotificationListener，去掉内嵌 SliverAppBar；`SettingsHubPage` 迁入同一
chrome（`showBack: false`）。子页 slivers API 不变。`disableAnimations` 路径
不叠 BackdropFilter。

**Verification** —
- `flutter analyze lib/features/shell/settings/`：No issues found
- `flutter analyze`：25 issues 全部 PRE-EXISTING（reader/test），settings 改动零新增
- `flutter test test/app_theme_flex_scheme_test.dart`：2 PASS
- 独立审查三项 PASS（Spec/Correctness/Consistency），无 critical
  （审查子代理 bash 被拦，以终点文件 + spec + 书架参照逐条核对）

**Journey log** —
- 书架顶栏参数（56px 显现、fog stops、IgnorePointer 分层）可整段复用；
  设置页 `headerContentH=56`（Material toolbar）是有意差分，不是漏改书架 72。
- 顶栏 blur 必须放在滚动区外 chrome Stack（Impeller / ImageFiltered subpass）；
  设置列表内液态控件继续走 glow overscroll，两套策略并存。
- Grill 先定「复刻什么」再写 spec：用户选顶栏滚动滤镜而非页底常显，避免做偏。
- 审查与 heavy verify 严格串行；审查子代理权限受限时以文件终点状态核对并如实标注。

## [S1] Problem

书架顶栏已实现「带滤镜颜色的渐变模糊」：滚动时全宽
`BackdropFilter + ShaderMask(dstIn)`，雾色 `AppGlass.topTint`（primary 0.52）
随 `_scrollT` 浮现；静止时不叠模糊。设置页（hub + 全部子页）标题栏仍是
透明 `SliverAppBar`，滚动时内容从标题下穿过时无雾化/滤镜，与书架视觉语言
不一致。DESIGN.md 设置草图已标注「（渐变模糊）」。

用户决策（Grill）：
1. 复刻目标 = **顶栏滚动渐变模糊**（非页底常显滤镜）
2. 生效范围 = **全部设置页**（经共享 chrome）
3. 工作区 = **master 主 worktree**（用户明确同意，不建 worktree）

## [S2] Design

### 视觉契约（与书架同源）

| 参数 | 取值 | 来源 |
|------|------|------|
| 滚动显现区间 | `t = (pixels / 56).clamp(0,1)` | `bookshelf_page._onScrollNotification` |
| 静止阈值 | `t < 0.02` 时不叠模糊，只画标题行 | 书架顶栏 |
| 雾色 | `AppGlass.topTint(scheme)` | primary 0.52 lerp |
| 模糊 | `AppGlass.topBlurSigma`（48） | 书架顶栏 |
| ShaderMask | 白→透明，stops `[0, 0.22, 0.42, 0.62, 0.82, 1]`，`BlendMode.dstIn` | 书架顶栏 |
| 叠层雾渐变 | fog α 0.58/0.48/0.32/0.16/0.05/0 × `t`，同 stops | 书架顶栏 |
| 内容区高度 | `statusPad + headerContentH(56)` | Material toolbar |
| 衰减带 | `topBlurExtend = 64`（只盖内容、不占布局） | 书架 `BookshelfLayout` |

### 结构契约

- 共享组件 `SettingsTopChrome` 于 `settings_chrome.dart`：
  - Stack：`IgnorePointer` 背景层（ShaderMask→Blur→ColoredBox fog + 雾渐变）
    + 标题行（返回键 + 标题，字色/字号对齐 `AppTheme` appBarTheme）
  - 输入：`title`、`scrollT`、`showBack`（hub=false，子页=可 pop 时 true）
  - 背景层 `IgnorePointer`，不抢滚动/点击
- `SettingsScaffold` 为 Stateful：
  - `NotificationListener` 跟踪 depth=0 垂直滚动 → `_scrollT`
  - Stack：内容 `CustomScrollView`（顶部 spacer = chrome 高，**不再内嵌 SliverAppBar**）
    + `Positioned` 顶栏 chrome
  - slivers API 不变
- `SettingsHubPage`：同一 `SettingsScaffold(title: '设置', showBack: false)`
- `MediaQuery.disableAnimationsOf`：不叠 BackdropFilter，滚动后 chrome 用
  半透明 surface 色
- `SettingsBackdrop` / `SettingsGlassScroll` 契约不变；顶栏 blur 在滚动区外

### 回退与边界

- 静止态 chrome 高度 = status + 56；滚动态视觉延伸 +64（不占布局）
- 子页返回：`Navigator.canPop` 时显示 `BackButton`
- About 页不在设置壳（独立 Scaffold+AppBar）——本轮 Out of Scope
- 书源 Tab 不在本轮范围

## [S3] Out of Scope

- 书源页 / 阅读页顶栏
- 页底常显滤镜渐变（用户未选）
- About 页 chrome 迁移
- 新增用户可调「设置顶栏模糊」滑杆（沿用书架固定参数；后续可接到 glass 设置）

## Tasks

- [x] T1: `SettingsTopChrome` + `SettingsScaffold` 滚动模糊 — acceptance: 设置子页滚动时顶栏出现 primary 雾色渐变模糊，静止无模糊；返回键/标题可读；slivers 调用方无破坏性改动 (covers: S2)
- [x] T2: `SettingsHubPage` 迁入共享 chrome — acceptance: 设置根页与子页同款顶栏；无双层 AppBar；滚动显现行为一致 (covers: S2; depends: T1)
- [x] T3: 验证 — acceptance: `flutter analyze` 改动文件零新增；设置页可进入/滚动/返回；disableAnimations 路径无崩溃 (covers: S2; depends: T1,T2)
