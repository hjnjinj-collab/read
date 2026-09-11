---
feature: note-fuzzy-relocate-and-hygiene
status: delivered
updated: 2026-09-10
branch: master
commits: pending
---

# 笔记模糊重定位 + 仓库卫生

## Report

**What was built** — 净化/简繁/分段等改写正文后，按 `excerpt` 在处理后章节全文中就近重挂笔记锚点并写库；仅在会改正文的设置项上触发（replace/segment 规则不在 processed FFI 口径内故不触发）。仓库卫生：删除误建 `%SystemDrive%/`、还原 `pubspec.lock` 镜像源噪音、`ARCHITECTURE.md` 将笔记持久化标为已完成。

**Verification** — `flutter test test/note_highlight_test.dart` → 11 passed；analyze 无 error。Review 后已补：EPUB 路径钩子、trim 长度一致、收窄触发条件、多命中测试。

**Journey log**
- `get_chapter_content_processed` 不接受 replace/segment 规则，钩子不能与 `needsCleaningUpdate` 完全对齐。
- 字号/行距不改字符偏移，不触发重定位。
- EPUB processed FFI 可能失败 → relocate 返回 0 静默。

## [S1] Problem

1. 简繁/净化等改写后笔记偏移失效，`excerpt` 未用于重定位。
2. 误建目录、lockfile 噪音、架构文档过时。

## [S2] Design

- `relocateNoteInText(text, oldStart, excerpt)`：全文 indexOf，取距 oldStart 最近命中。
- `relocateChapterNotes`：`getChapterContentProcessed` + `updateNoteOffsets`；当前章 force 刷新。
- 触发：`removeDuplicateTitle` / `chineseConvert` / `reSegment` / `removeHtmlTags` / `removeAds` 变更后（TXT 与 EPUB）。
- 卫生：删 `%SystemDrive%/`、`git checkout pubspec.lock`、更新 ARCHITECTURE。

## [S3] Out of Scope

- 替换规则与分段规则参与的完整重定位
- 跨章笔记批量迁移

## Tasks

- [x] T1: relocateNoteInText + 单测 (covers: S2)
- [x] T2: DB + BookService + relocateChapterNotes + 设置钩子（含 EPUB） (covers: S2; depends: T1)
- [x] T3: 仓库卫生 + ARCHITECTURE (covers: S2)
- [x] T4: analyze + 测试 (covers: S1 S2; depends: T1 T2 T3)
