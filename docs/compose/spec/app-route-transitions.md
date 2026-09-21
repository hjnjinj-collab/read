---
feature: app-route-transitions
status: delivered
updated: 2026-09-19
branch: master
commits: b8775a9..HEAD
---

# 整体路由切换动画（书架不动 + 预测返回）

## Report

**What was built** — 层级路由统一转场：设置子页与 `/about` 使用 `AppRouteTransitions.hierarchical`（Fade + 轻 slide 8%，push 300ms / pop 280ms，`easeInOutCubic`）。**书架契约未改**：三 Tab 仍 `NoTransitionPage`；`/reader` 仍 `_ReaderShrinkTransition`（从 `shelfIndex` 放大 / pop 缩回 index 0，**720ms** `easeInOutQuart`）。Android：Manifest `enableOnBackInvokedCallback=true` + 主题 `PredictiveBackPageTransitionsBuilder`；减弱动态时层级转场 duration 0。

**Verification** — `flutter analyze` 25 PRE-EXISTING；router/theme 文件 No issues；`app_theme_flex_scheme_test` 2 PASS。评审 Spec/Correctness/Consistency 无 CRITICAL。

**Journey log** —
- 书架/阅读「从哪来/去哪」不得被全局动画覆盖
- go_router `CustomTransitionPage` 不走 `pageTransitionsTheme`，需自建 hierarchical
- 预测返回依赖 Manifest OnBackInvoked + 跟手 animation reverse
- 代码 `readerShrinkDuration=720ms`（旧文档曾写 620ms，以代码为准）

## [S1] Problem

设置子页/关于缺少统一转场；Zoom 主题与 Android 预测返回不兼容；书架槽位缩放不得被覆盖。

## [S2] Design

### 不改动（书架契约）

| 路由 | 行为 |
|------|------|
| Shell Tab | `NoTransitionPage` |
| `/reader` | 槽位缩放 720ms，push `shelfIndex` / pop index 0 |

### 层级路由

`AppRouteTransitions.hierarchical`：Fade + `Offset(0.08,0)`→0；push 300ms / pop 280ms / `easeInOutCubic`；`MediaQuery.disableAnimationsOf` → 零时长。

### Android 预测返回

- Manifest `android:enableOnBackInvokedCallback="true"`
- Android `PredictiveBackPageTransitionsBuilder`；iOS Cupertino；Windows Zoom

### AppMotion

`routePushDuration` / `routePopDuration` / `routeCurve` / `routeSlideBegin`

## [S3] Out of Scope

- 书架 FLIP / Hero、Tab 页转场、动效页可调时长

## Tasks

- [x] T1: AppMotion + hierarchical — acceptance: 设置子页 Fade+轻 slide (covers: S2)
- [x] T2: 路由接入 — acceptance: 子页/about 有动画；Tab 与 reader 未改 (covers: S2)
- [x] T3: 预测返回 Manifest + 主题 builder (covers: S2)
- [x] T4: analyze 基线无新增 + 主题测试 PASS (covers: S2)
