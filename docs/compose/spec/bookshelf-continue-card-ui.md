---
feature: bookshelf-continue-card-ui
status: delivered
updated: 2026-09-19
branch: master
commits: # filled at delivery
---

# 首页 Dashboard 与书架分工（续读/图表）

## Report

**What was built** — (1) 布局稿 `index.html` 按定稿顺序：Hero 轮换（**首帧永远今日目标** → 续读卡）→ 统计 → 折线图 → 底部最近阅读。(2) 书架 Flutter 落地 **ThinContinueBar**：网格/列表上方薄续读条（封面+章进度+「继续」），替换高海报 Hero；有书即显示，优先带章节进度的书。

**Verification** — bookshelf 相关 analyze 通过（去 unused import 后）；布局稿可浏览器预览。首页 Flutter Tab 未实现（下一轮）。

**Journey log** —
- Home ≠ Bookshelf；书架只要薄条
- 今日目标进 Hero 轮换且**每次进首页 index=0**
- 折线图用 SVG；Flutter 可 CustomPaint 同构

## [S1] Problem

首页模块顺序与 Hero 内容需按产品定稿；书架需薄续读条可直接实现。

## [S2] Design

见上 Report；Hero 轮换契约、书架 ThinContinueBar 契约如 S2 设计表。

## [S3] Out of Scope

首页 Flutter 页/四 Tab 路由、真实阅读时长埋点

## Tasks

- [x] T1: index.html 顺序 + Hero 含今日目标首帧 (covers: S2)
- [x] T2: 书架 ThinContinueBar Flutter 落地 (covers: S2)
- [x] T3: analyze bookshelf 路径无新增 (covers: S2)

