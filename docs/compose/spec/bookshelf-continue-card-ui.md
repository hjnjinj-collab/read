---
feature: bookshelf-continue-card-ui
status: delivered
updated: 2026-09-19
branch: master
commits: 9fc7d94..HEAD
---

# 首页 Dashboard + 书架续读（实现轮）

## Report

**What was built** — 继续按钮改为 `restPillTint` + `onPrimaryContainer` 派生色。新增 **首页 Tab**（`/home`，initialLocation）：Hero 轮换首帧「今日目标」→ 海报续读 → 统计三格 → 近 7 日 CustomPaint 折线 → 最近阅读横滑；点书进 `/reader`。路由四分支：home/bookshelf/sources/settings；底栏主胶囊 `[首页|书架]`，更多→设置，设置态展开 `[书源|设置]`（选中态按真实 branch 映射）。书架顶条保持海报语言 + 派生色按钮。

**Verification** — 触碰文件 analyze No issues；全量 25 PRE-EXISTING。评审 Spec/Correctness 无 CRITICAL。

**Journey log** —
- 派生色 CTA：`restPillTint` / `onPrimaryContainer`
- 分支索引 0–3 与 go_router 顺序绑定
- 底栏主胶囊在书源/设置不高亮书架
- 周折线/今日分钟暂为演示序列，待埋点

## [S1] Problem

按钮需派生色；需独立首页 Tab 与 Dashboard 落地。

## [S2] Design

见 Report；模块顺序以布局稿为准。

## [S3] Out of Scope

真实时长埋点、WebDav 卡、solid 底栏与玻璃底栏 IA 完全统一

## Tasks

- [x] T1: 继续按钮派生色 (covers: S2)
- [x] T2: 四 Tab 路由 + 底栏映射 (covers: S2)
- [x] T3: HomePage 模块布局 (covers: S2)
- [x] T4: analyze 无新增 (covers: S2)
