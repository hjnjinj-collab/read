---
feature: shell-tab-reselect-policy
status: delivered
updated: 2026-09-20
branch: master
commits: 70bc80c..HEAD
---

# 壳层同 Tab 重选 / 回首页解耦 / 面板选中态

## Report

**What was built** — 同 Tab 重选：仅设置子页（path ≠ `/settings`）`initialLocation: true` 回 hub；其它同 Tab no-op（保留滚动位/分支栈）。`homeIntroTick` 仅跨 Tab 进首页时递增，同 Tab 重选不重播入场。主胶囊在设置时不再 `clamp` 亮书源，无选中 rest 透明；更多面板「设置」选中与 `selectedIndex==3` 同源。主胶囊/面板统一用 `segmentBuilder` 内 `GestureDetector` 接管点击，绕开库内 `i != selectedIndex` 守卫。`onToggleExpand` 延迟进设置前校验仍展开。

**Verification** —
- `flutter analyze`（app_shell + expandable_glass_nav）：No issues found
- 子代理审查：发现主胶囊设置态「首页」被占位 index 吞点击（critical）+ 开收竞态；已修，复审 PASS
- 真机待验

**Journey log** —
- `LiquidGlassSegmented` 不接受 `selectedIndex: -1`，无选中态用透明 rest + 占位 index
- 库内 `if (i != selectedIndex) onChanged(i)` 会吞占位段点击 → 必须 GestureDetector 自接管
- 同 Tab 策略：仅设置子页 reset；其它 no-op
- `homeIntroTick` 绑定 `from != 0 && i == 0`
- Solid/玻璃 IA 本轮不统一（用户拍板）

## [S1] Problem

真机/梳理（`docs/design/shell-nav-routing-status.md`）三处硌手：

1. **同 Tab 踢回子页** — `goBranch` 使用 `initialLocation: i == from`，点当前 Tab 会重置到分支根：`/settings/glass` 被弹回 hub；回首页丢滚动位。
2. **回首页连击** — 只要目标是首页就 `homeIntroTick++`，同 Tab 重选也重播入场，与 tab slide 叠戏。
3. **面板选中态** — 更多面板 `selectedIndex: 0` 写死；主胶囊在 `selectedIndex==3` 时 `clamp(0,2)` 会把 pill 落到「书源」。

导入入口已在更多面板「添加书籍」，无需再收。Solid/玻璃 IA 本轮**不统一**（用户拍板）。

工作区：master 主 worktree（既定）。

## [S2] Design

### [S2.1] 同 Tab 策略

| 场景 | 行为 |
|------|------|
| 跨 Tab | `goBranch(i, initialLocation: false)`，保留该分支栈；播 tab slide |
| 同 Tab · 设置且在子页（path ≠ `/settings`） | `initialLocation: true` 回 hub |
| 同 Tab · 其它（含设置 hub、首页、书架、书源） | **no-op**（不 goBranch、不播 slide）；仅当需要时收起更多面板 |
| 同 Tab 首页 | no-op，且**不** `homeIntroTick++` |

子页判定：`GoRouter.of(context).state.uri.path`；设置分支根为 `/settings`，其余 `/settings/*` 为子页。

### [S2.2] 回首页动画解耦

`homeIntroTick++` **仅当** `from != 0 && i == 0`（跨 Tab 进入首页）。同 Tab 重选首页不重播 Dashboard 入场，不与 slide 叠戏。

### [S2.3] 面板 / 主胶囊选中态

| 控件 | 契约 |
|------|------|
| 主胶囊（收起态） | `selectedIndex == 0/1/2` 时选中对应段；`selectedIndex == 3`（设置）时**无段选中**（禁止 clamp 成书源） |
| 更多面板 | 「设置」在 `selectedIndex == 3` 时选中；「添加书籍」永非分支选中 |
| 点击 | `segmentBuilder` 内 `GestureDetector` 无条件 `onChanged(i)`；库 `onChanged: (_) {}`（绕开 `i != selectedIndex` 守卫） |
| pill 源 | 与 builder `isSel` 同源；无选中时 rest 透明 |

实现：`LiquidGlassSegmented` 断言 `selectedIndex` 必须落在 `[0, len)`，不能传 -1。主胶囊在 `selectedIndex > 2` 时占位 `0` + rest 透明；面板 pill 槽位在「设置」，仅 `selectedIndex == 3` 时 rest 有色。

### [S2.4] 三段主胶囊尺寸（真机反馈补丁）

| 参数 | 原 | 现 |
|------|----|----|
| 底栏 height | 64 | **72** |
| 主胶囊 `_barW` | 196 | **248** |
| 主段 icon / 字 | 20 / 10 | **24 / 12** |
| labels 字号 | 11 | **12** |
| 更多面板 icon / 字 | 20 / 12 | **22 / 13** |

窄窗仍走原有 clamp，不溢出。

## [S3] Out of Scope

- Solid 底栏与玻璃 IA 统一（本轮不动）
- 导入入口改造（已在更多面板）
- 书源入口再设计（左三段已缓解）
- 跨 Tab 时强制回分支根
- 设置子页面包屑 / 返回栈可视化
- 多个 pending `Future.delayed` 代际化（开→收→再开极短竞态，不破坏导航）

## Tasks

- [x] T1: 同 Tab 策略 — acceptance: 设置子页同 Tab 回 hub；其它同 Tab 不重置、不丢首页滚动位 (covers: S2.1)
- [x] T2: `homeIntroTick` 仅跨 Tab 进首页 — acceptance: 同 Tab 重选首页不重播入场；跨 Tab 进首页仍重播 (covers: S2.2; depends: T1)
- [x] T3: 主胶囊/更多面板选中态 — acceptance: 在设置时主胶囊不亮书源；面板「设置」选中与 `selectedIndex==3` 一致；任意段可点 (covers: S2.3)
- [x] T4: 验证 + 审查 — acceptance: 触碰文件 analyze 无新增；审查通过 (covers: S2)
- [x] T5: 三段主胶囊尺寸增大 — acceptance: 视觉字面/触达大于改前；窄窗不溢出 (covers: S2.4)
- [x] T6: 尺寸轮验证 — acceptance: analyze 无新增 (covers: S2.4; depends: T5)
