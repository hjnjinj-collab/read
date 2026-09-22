---
feature: bookshelf-continue-card-ui
status: delivered
updated: 2026-09-19
branch: master
commits: 9fc7d94..HEAD
---

# 首页 Dashboard + 书架续读（实现轮）

## Report

**What was built** — 首页 Hero 修观感四点：**定高 128**（封面/目标同构）；**M3 Expressive 异变进度环**（theme `year2023: false` + trackGap）；**去外层 Card**，与书架顶条同级海报块 + 轮换圆点叠放；最近阅读加大并收 bottom pad，消掉大块留白。

**Verification** — `home_page.dart` analyze 无新增。真机待验。

**Journey log** —
- 派生色 CTA：`restPillTint` / `onPrimaryContainer`
- 分支索引 0–3 与 go_router 顺序绑定
- 底栏主胶囊在书源/设置不高亮书架
- 周折线/今日分钟暂为演示序列，待埋点

## [S1] Problem

按钮需派生色；需独立首页 Tab 与 Dashboard 落地。

## [S2] Design

见 Report；模块顺序以布局稿为准。

### 首页 Hero 观感（真机四点）

| 问题 | 契约 |
|------|------|
| 封面帧 / 目标帧高度不一 | **定高**（约 128–140）；两帧同构，切换不推挤下方 |
| 目标环过素 | 用异变进度（`ProgressIndicatorThemeData(year2023: false)` 或等价形变环），随进度形变 |
| Hero 外还有一层 Card | **去掉外包装**；与书架顶条一样直接海报块（圆点叠在块上） |
| 最近阅读下留白 | 收紧 bottom pad / 加高图表与横滑，消掉无效空白 |

### 首页质感（真机再一轮）

| 项 | 契约 |
|----|------|
| 续读封面 | 加大（约 56×80 → 64×92） |
| 继续按钮 | 提高不透明度（restPill α 提高或 primaryContainer 近实色）+ 文字 onPrimaryContainer |
| Hero 切换 | 明确 **Fade + 轻 Slide** 过渡，禁止双帧叠影 |
| 折线 / 统计 | 数据变化 **补间过渡**；统计加 Iconsax 图标 |
| 封面投影 | 封面类卡片用 **CoverPalette 取色阴影** 悬浮感 |
| 外层卡霜层 | **设计结论**：统计/图表等 chrome 卡 **采用霜层/tonal 轻霜**（对齐设置页）；封面海报 **不套霜**（用取色投影），避免材质打架 |

## [S3] Out of Scope

真实时长埋点、WebDav 卡、solid 底栏与玻璃底栏 IA 完全统一

## Tasks

- [x] T1: 继续按钮派生色 (covers: S2)
- [x] T2: 四 Tab 路由 + 底栏映射 (covers: S2)
- [x] T3: HomePage 模块布局 (covers: S2)
- [x] T4: analyze 无新增 (covers: S2)
- [x] T5: Hero 定高 128 + M3 异变环 + 去外层 Card + 收底留白 (covers: S2 Hero)
- [x] T6: 封面放大+按钮实色+Hero/折线/统计过渡+取色投影+chrome 霜层 (covers: S2 质感)
