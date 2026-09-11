---
feature: note-list-empty-and-reopen-hang
status: delivered
updated: 2026-09-11
branch: master
commits: pending
---

# 笔记列表空白 + 退出重进卡加载

## Report

**What was built** — 笔记列表 FutureBuilder 区分 waiting/error/empty；`batchLocateNotes` 2s 超时，失败仍返回笔记。`openBook` 会话序号守卫覆盖 parse/meta/format/upsert/progress/load，`closeBook` 作废在途 open。

**Verification** — analyze 无 error；note_highlight + selection_handle 17 tests PASS。Review 后补齐 format/upsert 后的 seq 检查。

**Journey log**
- FutureBuilder `data ?? []` 会把加载中画成「暂无」。
- openBook 每个 await 写 state 前都要校验 seq，不能只查主路径。

## [S1] Problem

高亮正常但列表「暂无」；退出再进卡加载。

## [S2] Design

- 列表：超时定位 + 正确加载态
- openBook：`_openBookSeq` 全路径守卫

## [S3] Out of Scope

- FFI 死锁根治、书签 Dialog 同类加载态

## Tasks

- [x] T1: batch 超时 + Dialog 加载态 (covers: S2)
- [x] T2: openBook 序号守卫 (covers: S2)
- [x] T3: analyze + 回归测试 (covers: S1 S2)
