---
feature: epub-batch-locate-deadlock
status: delivered
updated: 2026-09-11
branch: master
commits: d2de38c..062cc89
---

# EPUB 笔记批量定位死锁 + 摘录首字 + 重进卡加载

## Report

**What was built** — 三处修复：① Rust `batch_locate_notes` 在探测书籍是否为结构化格式后立即释放 `BOOKS.read()` 守卫，再进入 EPUB/TXT 分支调用会取 BOOKS 锁的分页 API，消除 std RwLock 非重入死锁——该死锁导致 EPUB 笔记列表无页码（`note.list.locate.skip TimeoutException`）、列表长时间转圈、以及退出重进时 `releaseBook` 写锁永久阻塞卡页面；② `beginSelection` 增加可选 `end` 参数，长按路径传入 `expandToWordBoundary` 的词终点并 clamp 到当前页 `endCharIndex`，修复划线摘录只剩第一个字；③ 批量定位 Dart 侧超时 2s → 800ms（锁修复后毫秒级返回，超时仅降级页码不挡列表）。

**Verification** — `cargo check --release -p bridge` PASS（4 个既有 warning）；`flutter analyze` 34 条均为既有问题，改动文件无新增告警；独立审查 subagent 结论：Spec 合规 PASS、正确性 PASS（无 critical）、代码一致性 PASS。

**Journey log** — 死锁根因模式：`process_structured_chapter`（api.rs:2361）缓存未命中时取 `BOOKS.write()`，因此任何持有 BOOKS 锁的 FFI 入口都不得再调用经它中转的 `get_page_structured`/`get_page_count_structured`/`get_page_count`——审查其它 FFI 入口时可复用此结论。用户日志中超时为 2s 证明测试包未包含修复，验证修复需重新 `build_apk.ps1` 构建 Android Rust so。

## [S1] Problem

1. 笔记列表无页码：`note.list.locate.skip TimeoutException`（log 实证）。
2. 摘录只有首字：`beginSelection` 固定 `end=start+1`。
3. 退出再进卡加载：`batch_locate_notes` 在 **持有 BOOKS.read() 时**再调 `get_page_count_structured`（内部再锁 BOOKS，缓存未命中路径为写锁）→ RwLock 死锁；随后 `releaseBook`/`parse` 等写锁永久阻塞。

## [S2] Design

- Rust `batch_locate_notes`：探测 `structured` 后 **立刻放锁**，再调 structured API。
- `beginSelection(charOffset, {end})`：长按传入 `expandToWordBoundary` 的词终。
- 定位超时降到 800ms（修锁后应毫秒级返回）。

## [S3] Out of Scope

- 已存 1 字摘录的历史笔记迁移
- 选区状态机加固（页尾防御路径 `charOffset == endCharIndex` 时的空选区退化，触发概率极低，已记录）

## Tasks

- [x] T1: Rust 放锁修复 (covers: S2)
- [x] T2: 词边界选区 (covers: S2)
- [x] T3: 重建 bridge + analyze/test (covers: S1 S2)
