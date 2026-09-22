---
feature: shell-solid-glass-ia
status: delivered
updated: 2026-09-20
branch: master
commits: 70bc80c..HEAD
---

# Solid / 玻璃底栏 IA 统一

## Report

**What was built** — 减弱动态 `_SolidBottomNav` 收成与 `ExpandableGlassNav` 同构：默认 `[首页|书架|书源]` + 更多圆键；更多态左「首页」+ 右 `[设置|添加书籍]`。共用 `goBranch`/`onToggleExpand`；减弱动态下更多**立即**进设置（无 280ms），布局瞬时切换。尺寸与放大后玻璃对齐（72 / 248，主段 24/12）。

**Verification** —
- `flutter analyze lib/features/shell/app_shell.dart`：No issues found
- 子代理审查：T1–T4 全达标，PASS
- 真机待验（含上一轮同 Tab/尺寸）

**Journey log** —
- Solid/玻璃宽度算法同构（72 / 248 / available=width-32）——改一侧必须同步另一侧
- 减弱动态：`onToggleExpand` 同步 `goBranch(3)`；Solid 槽位禁止 AnimatedContainer
- `ExpandableGlassNav.onSources` 为死参数，书源走主胶囊 `onChanged(2)`

## [S1] Problem

减弱动态（`disableAnimations`）下的 `_SolidBottomNav` 仍是四键并列 `首页|书架|书源|设置`，玻璃底栏是「左三段 + 更多 / 更多态左首页 + 右设置|添加书籍」。同一 IA 两套长相。用户点名本轮统一。

## [S2] Design

### [S2.1] 共用 IA（两套底栏同一结构）

| 态 | 左 | 右 |
|----|----|----|
| 默认 | 主胶囊 `[首页\|书架\|书源]` | 圆键「更多」 |
| 更多态 | 圆键「首页」（收起并回首页） | 面板 `[设置\|添加书籍]` |

- 点「更多」：展开 → 进设置（路由不抢跑；减弱动态**立即**进设置，无 280ms 延迟）
- 同 Tab 策略 / `homeIntroTick` 复用 `AppShell.goBranch`
- Solid **无**液态/BackdropFilter；布局与命中区与玻璃对齐（高 72、主胶囊目标宽 248）
- 更多态切换：减弱动态 **瞬时** 换布局（无 AnimatedContainer）

### [S2.2] Solid 视觉

实底 `primaryContainer@0.92` + 圆角 `AppGlass.navBarRadius`；选中 `primary`，未选 `onSurfaceVariant`；主段 icon 24 / 字 12，面板 22 / 13。

## [S3] Out of Scope

- 玻璃折射/Lens 参数
- 数据真实化（统一流程后再做）
- 横屏/平板底栏形态

## Tasks

- [x] T1: `_SolidBottomNav` 收成 3+更多同构 — acceptance: 减弱动态下结构与玻璃一致；设置/导入入口对齐 (covers: S2.1)
- [x] T2: 更多态瞬时切换 + 立即进设置 — acceptance: disableAnimations 无 280ms 延迟、无宽度动画 (covers: S2.1; depends: T1)
- [x] T3: 尺寸对齐（72 / 248） — acceptance: Solid 触达/字面与放大后玻璃同级 (covers: S2.2; depends: T1)
- [x] T4: 验证 + 审查 — acceptance: 触碰文件 analyze 无新增；审查通过 (covers: S2)
