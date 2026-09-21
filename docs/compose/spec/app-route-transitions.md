---
feature: app-route-transitions
status: delivered
updated: 2026-09-19
branch: master
commits: b8775a9..HEAD
---

# 整体路由切换动画（书架不动 + 预测返回）

## Report

**What was built** — 三类转场分工：(1) 层级路由（设置子页/关于）`AppRouteTransitions.hierarchical`：Fade+轻 slide 8%，push 300ms / pop 280ms。(2) Shell 三 Tab：`pageBuilder` 仍 `NoTransitionPage`（StatefulShell 不跑 page 转场），由 `AppShell` 自播 Fade+方向轻 slide 280ms，**不 remount** `navigationShell`，IndexedStack 状态保活。(3) `/reader` 槽位缩放 720ms 契约未改。Android 预测返回：Manifest `enableOnBackInvokedCallback` + `PredictiveBackPageTransitionsBuilder`。「更多」按钮：非设置 Tab **直接进设置**；已在设置时展开面板保留「添加书籍」。

**Verification** — `flutter analyze` 25 PRE-EXISTING；触碰文件 No issues；主题测试 2 PASS。评审无 CRITICAL。

**Journey log** —
- StatefulShell 分支切换不跑 `pageBuilder`，Tab 动画须在 AppShell 层且禁止 AnimatedSwitcher 换 key
- 底栏 `ValueKey` 不可含 `selectedIndex`，否则 remount 丢分支状态
- go_router CustomTransitionPage 不走 pageTransitionsTheme
- 代码 `readerShrinkDuration=720ms`
- 更多 = 默认进设置；在设置再展开，导入不丢

## [S1] Problem

层级路由无统一转场；Zoom 与预测返回不兼容；三 Tab 瞬时切换；更多按钮需二次点击才进设置；书架槽位缩放不得被覆盖。

## [S2] Design

### 书架契约

| 路由 | 行为 |
|------|------|
| Tab `pageBuilder` | 仍 `NoTransitionPage`（shell 换分支不跑 page 动画） |
| Tab **观感** | AppShell 自播 Fade + 方向 slide（见下） |
| `/reader` | 槽位缩放 720ms，push `shelfIndex` / pop index 0 |

### 层级路由

Fade + `Offset(0.08,0)`→0；push 300ms / pop 280ms / `easeInOutCubic`；`disableAnimations` → 零时长。

### Tab 页转场

AppShell `goBranch` 后对 `navigationShell` 播：

| 条件 | 表现 |
|------|------|
| index 增大 | 自右 `Offset(0.06,0)` 滑入 + 淡入 |
| index 减小 | 自左滑入 |
| 时长 / 曲线 | 280ms `easeInOutCubic` |
| 状态 | 不 remount shell |

### 「更多」按钮

| 点击位置 | 行为 |
|----------|------|
| 不在设置 Tab | **直接** `goBranch(2)` |
| 已在设置 Tab | 展开 `[设置\|添加书籍]` |

### Android 预测返回

Manifest `enableOnBackInvokedCallback=true`；Android `PredictiveBackPageTransitionsBuilder`。

### AppMotion

`routePush/PopDuration`、`routeCurve`、`routeSlideBegin`；`tabDuration`、`tabCurve`、`tabSlideBegin`。

## [S3] Out of Scope

- 书架 FLIP / Hero、阅读页封面飞行
- 动效页可调转场时长
- 更多长按导入等手势扩展（导入仍在设置 Tab 展开面板）

## Tasks

- [x] T1: AppMotion + hierarchical (covers: S2)
- [x] T2: 设置子页/about 接入 hierarchical；reader 槽位缩放未改 (covers: S2)
- [x] T3: 预测返回 Manifest + 主题 builder (covers: S2)
- [x] T4: analyze 基线无新增 + 主题测试 PASS (covers: S2)
- [x] T5: Tab Fade+方向 slide（AppShell，不 remount）(covers: S2 Tab)
- [x] T6: 更多默认进设置；设置 Tab 内展开面板 (covers: S2 更多)
- [x] T7: 本轮验证 analyze 无新增 (covers: S2; depends: T5, T6)
