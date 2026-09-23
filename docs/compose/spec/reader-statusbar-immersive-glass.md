---
feature: reader-statusbar-immersive-glass
status: delivered
updated: 2026-09-20
branch: master
commits: 8bf211d..83d588c
---

# 阅读页状态栏沉浸 + 液态玻璃修复

## Report

**What was built** — 沉浸状态栏 + 液态与书架同源。真机观感迭代：阅读圆键 52；顶距收紧 `systemTop + clamp(padV×0.35, 6, 12)`；壳层底栏 **60 / 208**（展开面板 = 收起 barW，禁止吃满宽）；阅读底部雾加浓、extend 96。

**Verification** —
- `flutter analyze`（reader + shell nav）：0 error（全量 reader 23 PRE-EXISTING）
- 子代理审查：液态同源 / S2.4 四项 / 底栏 60·208 同步 均 PASS
- 真机已确认液态与沉浸主路径；底栏尺寸本轮再收

**Journey log** —
- 液态只准 `shellFrostLiquidStyle`；禁止 ClipOval/saveLayer/Batch
- 底栏展开面板必须与收起 barW 同宽；整体高宽 60/208
- 沉浸后首行空白用收紧 padTop，勿整段 paddingVertical 叠状态栏
- veil 雾实际绘制是 `fogAlphas × 0.9`
- `padTop` 必须进 layoutFingerprint

## [S1] Problem

真机截图（阅读菜单 T0 壳）两处硬伤：

1. **状态栏落差/色差** — 正文 SafeArea 把状态栏抠出画布，缝里露出 `scaffoldColor`（0xFFF5F5DC），与纸色 `paperColor`（0xFFF5F1E8）不一致；系统状态栏也未跟随阅读主题，顶部一截色带 + 空白，与阅读页割裂。
2. **液态玻璃无液态** — 圆键被 `ClipOval(Clip.antiAliasWithSaveLayer)` 包住。`liquid_glass_easy` 全链路要求祖先 `Clip.none`（saveLayer 裁切会破坏 Backdrop/折射采样）；壳层同款 `LiquidGlassTabBarAction` 无此外层裁切故有液态。真机观感为灰圆片、无折射。

## [S2] Design

### [S2.1] 状态栏沉浸（本轮实现，开关留给后期）

| 契约 | 取值 |
|------|------|
| 系统栏 | `AnnotatedRegion<SystemUiOverlayStyle>`：`statusBarColor: transparent`；图标亮度随阅读日夜（暗主题 light icons / 亮主题 dark icons）；导航栏底色随 `paperColor` |
| 画布 | body **去顶 SafeArea**，仅 `SafeArea(top: false)` 护手势/导航条；纸色由 PagePainter 铺满含状态栏整页 |
| Scaffold 底 | `PageContentRenderer.theme.paperColor`（与纸同色，消缝） |
| 排版 | viewport 高 = 全高 − 底手势；`padTop = 用户 paddingVertical + viewPadding.top`（状态栏高）——**内容区净高不变**，分页稳定 |
| 顶栏 chrome | 仍叠在状态栏上；`ReaderBlurVeil` / 轻雾继续吃 `padding.top` |
| 后期 | 用户开关「显示状态栏」本轮 **不做** |

### [S2.2] 液态玻璃修复（真机复测后二次修正）

| 契约 | 取值 |
|------|------|
| 样式同源 | 圆键**必须**用 `shellFrostLiquidStyle`（`lib/core/theme/shell_glass_style.dart`）——与书架底栏/壳层 `_shellFrost` 唯一实现；blur/tint 跟 `shellSettingsProvider` |
| 构造同源 | `LiquidGlassTabBarAction` 对齐 `ExpandableGlassNav` 圆键（icon/size/foregroundColor/touch/onTap），禁止另写折射参数 |
| 裁切 | 祖先 `Clip.none`（含 Stack）；**禁止** `ClipOval`/`saveLayer` |
| Batch | **不用** `LiquidGlassBatch`（书架正常路径无 Batch；合批曾导致无液态） |
| 垫层 BF | `ReaderBlurVeil` 仅渐变雾，无 BackdropFilter |
| 命中 | `ReaderToolBall` 单命中，无外层 InkWell |

### [S2.2b] 已废弃做法（勿再引入）

- 阅读侧自写 `LiquidGlassStyle`（弱 blur 2.5 / 弱折射）——与书架观感不一致
- `ClipOval(antiAliasWithSaveLayer)` 包圆键——杀液态
- `LiquidGlassBatch` 包整页 chrome——书架无此层，真机无液态

### [S2.3] 排版同源（回归红线）

- `LayoutConfig.width/height` 仍只来自 LayoutBuilder constraints（禁 `MediaQuery.size` 全屏值）
- `padTop` 进 MeasureCache / fingerprint 键，防缓存串页
- 翻页几何与 canvas 同用新 viewport

### [S2.4] 真机第二轮观感修正（本轮）

| 契约 | 取值 |
|------|------|
| 阅读圆键 | `ReaderGlassCircle` 默认 **52**（原 44 偏小）；顶栏行高 60 |
| 顶距收紧 | `padTop = systemTopInset + clamp(paddingVertical×0.35, 6, 12)`——沉浸后**压掉**首行上方大片空白 |
| 底栏展开 | **居右、向右满宽填充**（原布局不变）；仅缩高度/收起 barW，不改动画与对齐 |
| 底栏整体 | 高 **60** / 收起主胶囊 **208**；主段 icon 22、面板 icon 20 |
| 底部渐变 | **阅读菜单垫 ≠ 壳层**：`ReaderBlurVeil` 高模糊 σ=**64** + 实雾（0.90→0），仅菜单态；壳层仍轻雾；底部 `band` 180/280、`extend` 96 |

### [S2.5] 菜单控件升级（本轮）

| 契约 | 取值 |
|------|------|
| 进度/亮度 | `LiquidGlassSlider`；亮度 0.25–1 叠黑遮罩 |
| 齿轮 | **中心液态胶囊固定**，选项循环滚过；透视圆柱；速度/方式带图标；**无**阴影槽 |
| 并栏 | 「翻页」一栏并列 方式\|速度；腾出「亮度」行 |
| 左间距 | 行标签自然宽度 + 8px |
| 字面 | 行标签 14；选中 15；非选中 13 |

## [S3] Out of Scope

- 状态栏显隐用户开关（后期）
- 字号/边距设置四页、菜单形态持久化（T1+）
- 液态 Group 合面（Batch 已够用）
- iOS 状态栏单独调校（按同一 overlayStyle 走）

## Tasks

- [x] T1: 系统栏 AnnotatedRegion + Scaffold 纸色底 — acceptance: 亮/暗主题下状态栏透明且图标对比可读；缝色与纸一致 (covers: S2.1)
- [x] T2: viewport 去顶 SafeArea + padTop 并入 viewPadding.top — acceptance: 纸色铺到状态栏下；正文净高与改前相当；切章/翻页无错位 (covers: S2.1,S2.3; depends: T1)
- [x] T3: 去掉 ClipOval saveLayer + veil Clip.none + 垫层去 BF — acceptance: 祖先无 Clip≠none (covers: S2.2)
- [x] T3b: 圆键改 `shellFrostLiquidStyle` 同源 + 去 Batch — acceptance: 样式/构造与书架底栏圆键一致；真机液态与书架同观感（待真机） (covers: S2.2)
- [x] T4: analyze + 审查 — acceptance: 触碰文件 analyze 无新增；基线 25 PRE-EXISTING 不扩散 (covers: S2)
- [x] T5: 圆键 52 + 顶距收紧 + 底栏展开同宽 + 底部渐变加浓 — acceptance: 键更大；首行空白变小；展开面板不再暴涨；底部雾更可读 (covers: S2.4)
- [x] T6: 底栏整体收小 60/208 — acceptance: 玻璃/Solid 同步；展开宽仍 = barW；analyze 无新增 (covers: S2.4)
