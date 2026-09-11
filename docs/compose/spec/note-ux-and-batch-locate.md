---
feature: note-ux-and-batch-locate
status: delivered
updated: 2026-09-10
branch: master
commits: pending
---

# 笔记 UX 收尾 + 批量定位接线

## Report

**What was built** — 选区/笔记列表支持系统剪贴板复制；`BookService.batchLocateNotes` 接上 Rust A30d API；笔记列表按章一次批量定位并显示页码。

**Verification** — `flutter test test/note_highlight_test.dart test/selection_handle_test.dart` → 14 passed；analyze 无 error。

**Journey log**
- FRB `Uint64List` 与 `dart:typed_data` 不同源，须用 `flutter_rust_bridge_for_generated` 的类型。

## [S1] Problem

1. 选区工具条「复制」是 TODO。
2. 笔记列表无法复制摘录，也不显示页码。
3. `batch_locate_notes` Dart 未接线。

## [S2] Design

### 剪贴板

- 选区「复制」写入系统剪贴板后清选区并 Snackbar。
- 笔记列表项复制摘录+备注。

### 批量定位

- `BookService.batchLocateNotes`：与 `getPageCountProcessed` 同口径。
- `groupNotesByChapter` + `loadNotesWithPages`：每章一次 FFI；失败 `pageIndex=null`。
- 列表副标题「第 N 章 · 第 P 页」。

## [S3] Out of Scope

- 排版变更后笔记模糊重定位
- 笔记导出/分享
- 跨章选区

## Tasks

- [x] T1: 选区/笔记复制到剪贴板 (covers: S2)
- [x] T2: BookService.batchLocateNotes + loadNotesWithPages (covers: S2)
- [x] T3: 测试与 analyze (covers: S1 S2; depends: T1 T2)
