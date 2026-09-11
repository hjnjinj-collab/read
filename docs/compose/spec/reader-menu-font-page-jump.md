---
feature: reader-menu-font-page-jump
status: delivered
updated: 2026-09-10
branch: master
commits: pending
---

# 阅读器菜单：字号± / 跳页 / 页数

## Report

**What was built** — 菜单进度条接真实章内页数并可在松手时跳页；字号 ± 调用已有 `setFontSize`（10–40）。页数缓存带所属章节（`_pageCountForChapter`），覆盖翻页/目录跳转/adopt 等换章路径。

**Verification** — analyze 无 error；note_highlight + selection_handle 测试 17 passed。

**Journey log**
- 换章常在 `_loadCurrentPage` 前就改 `currentChapterIndex`，`targetChapterIndex` 钩子不够；用「页数所属章」比对才完整。

## [S1] Problem

菜单进度条写死 `max: 100` 且不跳页；字号 ± 为 TODO。

## [S2] Design

- `ReadingState.currentChapterPageCount` + `_pageCountForChapter`
- `refreshCurrentChapterPageCount` / `jumpToPage`
- 菜单 Slider `onChangeEnd` 跳页；字号 ± 钳 [10,40]
- 刷新触发：开书、字号/行距、以及 commit 时所属章 ≠ 展示章

## [S3] Out of Scope

- 跨章连续滑杆、全书页数、行高快捷入口

## Tasks

- [x] T1: state 页数 + refresh + jumpToPage (covers: S2)
- [x] T2: 菜单 UI 接线 (covers: S2; depends: T1)
- [x] T3: analyze + 回归测试 (covers: S1 S2; depends: T1 T2)
