---
feature: a36-reader-stability-release
status: delivered
updated: 2026-09-13
branch: master
commits: c8a4008..HEAD
---

# A36 阅读稳定性与发布收口

## Report

**What was built** — ① EPUB 页数查询统一字体参数：`_pageCountOfUncached()` 补传 `fontName: ReaderFont.family`，与 `getPageStructured()` 完全同参，消除 pageCount 与实际布局页数漂移的根因。② 首翻 MeasureCache warm-up 清理 structured pagination cache 后同步清理 Dart chapter page-count cache。③ 跨章 previous adopt 要求页面必须是上一章真实末页（`pageIndex == pageCount-1`）。④ 三本真实 EPUB 探针验证：剑来封面转整页背景、瓦尔登湖 H1+正文+indent、大奉打更人 6 张画廊图全部提取。⑤ README/ARCHITECTURE 更新 A36 状态。

**Verification** — `fix_sync.ps1` PASS；`flutter analyze` 29 issues 0 error（PRE-EXISTING）；probe_cover：剑来 1122964 / 瓦尔登湖 13827270 / 大奉打更人 800282 均 Some；probe_epub_chapter：三本关键章节结构正确。

**Journey log** —
1. EPUB pageCount 与 getPage 必须完全同参——fontName 漏传是最隐蔽的页数漂移根因。
2. MeasureCache warm-up 重排后必须同步清理 Dart 页数缓存。
3. 跨章 previous adopt 不能仅凭 chapterIndex 相邻，必须校验真实末页。
4. 并行 cargo test + fix_sync 会因 patch PATH 竞态假失败——串行执行。

## [S1] Problem

A32-A35 已完成主要 EPUB 能力，但真实书验证仍暴露稳定性风险：分页页数缓存与实际布局可能不一致，短章/纯图章/跨章翻页需要持续回归。

## [S2] Design

### 分页与翻页稳定性

- 结构化分页的 page count 与实际 `Page[]` 使用同一布局参数、同一缓存指纹。
- 请求页码被布局钳制时，状态必须回写实际页码；若前进请求回到当前页，视为章末并进入下一章。
- 跨章 previous adopt 必须校验真实末页。

### EPUB 真实书回归矩阵

| 样例 | 锁定能力 |
|---|---|
| 剑来 | 封面全屏背景、SVG 封面、长章跨页 |
| 瓦尔登湖 | 非标 coverpage、章末注、正文标题 |
| 大奉打更人 | 画廊分页、短章、装饰诗词页 |

## [S3] Out of Scope

- PDF/MOBI/在线书源
- 翻页动画或笔记产品功能重设计
- 完整商业 EPUB 样纳入仓库

## Tasks

- [x] T1: 结构化分页/翻页稳定性回归与必要修复
- [x] T2: 三本真实 EPUB 回归探针与矩阵验证
- [x] T3: 发布文档与工作区收口
- [x] T4: 全量验证、提交（不推送）
