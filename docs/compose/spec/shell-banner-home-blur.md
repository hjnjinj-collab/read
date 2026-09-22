---
feature: shell-banner-home-blur
status: delivered
updated: 2026-09-20
branch: master
commits: 1092ee2..HEAD
---

# 书架横幅轮换 + 首页上滑渐变模糊

## Report

**What was built** — 书架顶条改为最近 3 本自动轮换（6s），`HeroSlideSwitcher` 真 index 左入右出推挤 + 圆点；首页固定顶栏 + 书架同款上滑渐变模糊（`TopScrollBlurChrome`）；书架顶栏迁入同一 chrome。切页变暗：去掉 `navigationShell` 外的 `FadeTransition(0.55→1)`，仅保留 `SlideTransition(0.06)`——液态不再进 Opacity layer，与底栏一致不发暗。

**Verification** —
- 触碰文件 `flutter analyze`：No issues found（含 `app_shell.dart`）
- 全量 `flutter analyze`：25 issues（PRE-EXISTING）
- 横幅/模糊：子代理审查 critical 已修，复审 PASS；**真机已通过**
- 变暗修复：子代理审查 PASS；真机待验（切 Tab 看顶栏液态是否仍变暗）

**Journey log** —
- `HeroSlideSwitcher` 只在 **index** 变化时推挤；书架禁止写死 `index: 0`
- 顶栏玻璃层序：模糊/雾在 `ClipRect` 内，前景（含 liquid `growHeight`）在外叠上
- 自动轮换 Timer 必须对齐 `disableAnimationsOf`（arm 与 tick 双侧）
- 空态不可滚时 `_scrollT` 必须复位
- **禁止**对含 LiquidGlass 的 `navigationShell` 做 Fade/Opacity；切页只 slide

## [S1] Problem

真机反馈三点：

1. **书架横幅切换** — 首页 Hero 已是 `HeroSlideSwitcher` 左入右出推挤；书架顶条虽包了同一组件，但 `index` 恒为 `0` 且只显示静止单本，换帧无动画、也不轮换。
2. **首页缺上滑渐变模糊** — 书架顶栏滚动约 56px 内显现滤镜色渐变模糊（ShaderMask + BackdropFilter + fog）；首页标题仍在 ListView 里随内容滚走，无同款 chrome。
3. **切页顶栏液态变暗** — Tab 切换时书架右上角网格/列表液态分段会先变暗一下，底栏液态不会。（本轮只定位与写计划，不实现。）

工作区：master 主 worktree（用户已明确同意）。

## [S2] Design

### [S2.1] 书架横幅多本轮换 + 推挤（本轮实现）

| 契约 | 取值 |
|------|------|
| 轮换源 | `_entries`（已按 lastRead 降序）取前 **3** 本 |
| 切换动画 | `HeroSlideSwitcher` **真 index** 变化 → 新帧左入 / 旧帧右出，560ms `easeInOutCubic` |
| 轮换间隔 | **6s**（与首页 Hero 一致）；`Timer` 单实例，重进/换书目时 cancel 再 arm |
| 首帧 | 书目列表变化时 `_bannerIndex = 0` 并重新计时 |
| 指示点 | 叠在横幅上（与首页同语言）：选中 14×6、未选中 6×6；**多帧才显示** |
| 单本 | 不轮换、不挂 Timer、无指示点 |
| 减弱动态 | 不自动轮换；`HeroSlideSwitcher` 直接换帧不播推挤 |
| 视觉 | 仍用 `ThinContinueBar`（海报取色 + 派生色「继续」按钮）；高度 148 |

`HeroSlideSwitcher` 契约：`index` 变化才播推挤；同 index 仅换 child 则静默替换。书架必须传入随轮换变化的 index，禁止写死 `0`。

### [S2.2] 首页上滑渐变模糊（本轮实现）

与书架 **同款** chrome，不套设置页居中标题语言：

| 契约 | 取值 |
|------|------|
| 滚动显现 | `t = (pixels/56).clamp(0,1)`；`t < 0.02` 无模糊 |
| 模糊 | `AppGlass.topBlurSigma` + `ShaderMask(dstIn)` stops `[0,.22,.42,.62,.82,1]` |
| 雾色 α | 与书架一致 `0.58 / 0.48 / 0.32 / 0.16 / 0.05 / 0 × scrollT` |
| 标题 | 左对齐「首页」；滚动压缩 `headlineSmall → titleLarge` |
| 副标题 / trailing | 无 |
| 布局 | 标题移出 ListView；`Stack` 固定 chrome 叠在滚动区上；内容顶距 = `padding.top + headerContentH + contentTopGap` |
| 层序 | 模糊/雾在 `ClipRect` 内；标题/液态前景在外叠上（对齐 Settings，防 `growHeight` 被裁） |
| 减弱动态 | 无模糊，实底 surface 条；不自动轮换 |

共用组件 `TopScrollBlurChrome`（`headerContentH` / `topBlurExtend` 由调用方传 `BookshelfLayout` 常量）。设置页 `SettingsTopChrome` 本轮不迁。

### [S2.3] 切页顶栏液态变暗 — 根因与修复（本轮实现方案 A）

**现象**：Tab 切换瞬间，页内液态控件（书架网格/列表分段）先变暗，底栏液态不变。

**根因**：

```text
AppShell.bottomNavigationBar  ── ExpandableGlassNav     ← 不在 fade 内 → 不变暗
AppShell.body.Stack
  └ AnimatedBuilder
      └ FadeTransition(opacity: 0.55 → 1)              ← 整棵 navigationShell
          └ SlideTransition
              └ StatefulNavigationShell
                  └ BookshelfPage 顶栏 LiquidGlassSegmented  ← 在 fade 内 → 变暗
```

`app_shell.dart` `_playTabTransition` 用 `tabFade = Tween(0.55 → 1)` 包住整个 `navigationShell`。Flutter 在 `opacity < 1` 时合成 **Opacity layer**；Impeller 下 LiquidGlass / `BackdropFilter` / Lens 在该 layer 内采样失真，观感为「玻璃发暗」。底栏在 `bottomNavigationBar`，不进这层 opacity，故稳定。

**本轮采用方案 A**：去掉 `FadeTransition` / `tabFade`，仅保留 `SlideTransition(0.06)`。与底栏「不变暗」一致。

| 方案 | 做法 | 取舍 |
|------|------|------|
| **A. 仅 slide（本轮实现）** | 去掉 `FadeTransition`，保留 `SlideTransition(0.06)` | 与底栏「不变暗」一致；转场稍硬 |
| B. 抬高 fade 下限 | `0.55 → 0.92` | 仍有轻微变暗，不根治（弃） |
| C. chrome 提出 fade | 顶栏液态挂到 shell 外 | 每页 chrome 结构被拆，成本高（弃） |

约束：**禁止** 对含 LiquidGlass/Lens 的子树做 `Opacity`/`FadeTransition` 动画（Impeller）。与 `settings-glass-scroll-flicker` 同类层序问题。

## [S3] Out of Scope

- 方案 B/C（fade 下限 / chrome 拆出）
- 设置页 `SettingsTopChrome` 迁到共用组件
- 首页统计/折线真实埋点
- 书架横幅手动滑动/点点切换（仅自动轮换）
- Solid 底栏与玻璃 IA 统一

## Tasks

- [x] T1: 共用 `TopScrollBlurChrome`（书架同款 stops/雾 α）— acceptance: 组件可被书架与首页引用；静止无模糊 (covers: S2.2)
- [x] T2: 书架横幅多本轮换 + `HeroSlideSwitcher` 真 index 推挤 — acceptance: ≥2 本时 6s 轮换且左入右出；换书目回第一本；单本静止 (covers: S2.1; depends: T1)
- [x] T3: 书架 `_buildHeader` 迁入共用 chrome — acceptance: 滚动模糊观感与迁前一致；网格/列表分段仍在 (covers: S2.2; depends: T1)
- [x] T4: 首页固定顶栏 + 上滑渐变模糊 — acceptance: 滚动约 56px 内显现同款雾色模糊；标题左对齐并压缩；内容从 chrome 下穿入 (covers: S2.2; depends: T1)
- [x] T5: 切页变暗根因/计划写入本文 — acceptance: S2.3 含层序图与方案表 (covers: S2.3)
- [x] T6: 验证 — acceptance: 触碰文件 `flutter analyze` 无新增；基线 25 PRE-EXISTING 不扩散 (covers: S2)
- [x] T7: 切页去 `FadeTransition`，仅 `SlideTransition` — acceptance: 转场无 opacity 动画；页内液态顶栏切 Tab 不变暗；底栏行为不变 (covers: S2.3)
- [x] T8: 变暗修复验证 + 审查 — acceptance: `app_shell.dart` analyze 无新增；审查通过 (covers: S2.3; depends: T7)
