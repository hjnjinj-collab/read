---
feature: books-lock-contention
status: delivered
updated: 2026-09-11
branch: master
commits: 4c2da83..eceda42
---

# BOOKS 稳态写锁消除 + 净化缓存锁外重建

## Report

**What was built** — 消除翻页热路径的三个 BOOKS 写锁竞争热点：①`get_chapter_content_impl` 稳态（hash 相符）只取读锁，原实现每次取原文都取写锁，是翻页卡顿主因；②净化缓存 hash 不符/首次时改两阶段锁外重建——per-book `clean_rebuild_gate` singleflight、读锁取快照后 BOOKS 锁外构建、短写锁装回并复查当前配置 hash、仅真正装回时 invalidate PREPROCESSED/PAGINATION 缓存；TXT 侧 install 失败持门有界重试（≤3）；③`get_book_resource` 慢路径 ZIP IO 降为读锁（`EpubParser.archive` 改内部 Mutex，`get_resource_cached` 降为 `&self`）。附带：EPUB route-2 空 content 守卫（防磁盘缓存空正文污染）、BOOKS 审计清单同步（热点 1/2/4 消除，仅剩搜索逐章 IR）。

**Verification** — `cargo check -p bridge` PASS；`cargo test --lib`：bridge 17 / book_parser 123 / reader_core 154 / layout_engine 85 全 PASS；bridge 集成测试编译错误为 PRE-EXISTING（A35-L2 签名漂移，stash 验证）。独立审查 3 critical（EPUB 块表达式 `?` 死代码、TXT install 失败读脏、EPUB install 未复查当前配置）+ 6 minor；修复提交 eceda42 后聚焦复审全部 PASS，锁序无环、TXT 重试有界无活锁。

**Journey log** — ①Rust 块表达式不是 try block：`let x: Result = { ...?... }` 内 `?` 作用于外层函数，写了兜底却永远不走——涉及 `?` 的 Result 块必须用闭包 `(|| { ... })()` 隔离。②`update_book_cleaning` 不占 clean_rebuild_gate，配置可在重建窗口内穿透，所有 install 路径必须在写锁内复查**当前** hash，不能只信入口 snapshot。③route-2 EPUB `Book.content` 为空，任何依赖 `book.content` 的路径（`EpubCleanedBook::build`、旧切片 API）结构上无法产出正文，structured 分流是唯一正确入口。④gate 应先于快照：singleflight 不仅合并构建，也应合并昂贵的输入克隆。

## [S1] Problem

翻页热路径 `get_chapter_content_impl` 稳态每次取原文都先取 `BOOKS.write()`（hash 相符也是写锁）；hash 不符时在写锁内做全书量级净化缓存重建（数十 ms～秒），阻塞并发翻页。`get_book_resource` 慢路径在写锁内做 ZIP 解压 IO。三个已审计标记的锁竞争热点。

## [S2] Design

**快路径（稳态）**：`BOOKS.read()` 校验净化缓存 hash，相符直接切片——稳态翻页从写锁降为读锁。

**慢路径（hash 不符/首次）**：per-book singleflight 锁外重建：
1. 读锁取 `Arc<Mutex<()>>` 重建门 → 持门（BOOKS 锁外）；
2. 门内复查缓存（他人已重建则直接切片返回）；
3. 仍未命中：读锁取输入快照（TXT：content+cleaner+chapters+file_path；EPUB：source_path+Book 克隆），锁外构建（TXT 全书 clean+JS 重识别；EPUB `load_or_build` 磁盘优先）；
4. 短写锁装回：写锁内复查**当前**配置 hash 与构建物一致才装（TXT 经 `install_cleaned_cache`；EPUB 重读 `CONTENT_CLEANING_OPTIONS` 重算），不一致丢弃；TXT 持门有界重试 ≤3 次，耗尽返回 Err；
5. 仅真正装回时 `invalidate_preprocessed_cache` + `PAGINATION_CACHE.clear_book`（`PREPROCESSED_CACHE` 键不含净化 config_hash）；
6. EPUB 构建失败（闭包内 `?`）回落既有逐读净化 3.2；route-2 空 content 守卫不落盘。

**热点 4**：`EpubParser.archive` 改 `Mutex<Option<ZipArchive<File>>>` 内部互斥，`get_zip_entry`/`get_resource`/`get_resource_cached` 降为 `&self`，`get_book_resource` 慢路径写锁降为读锁。锁序：archive 锁与 resource_cache 锁从不同时持有；BOOKS → CONTENT_CLEANING_OPTIONS 单向，无环。

## [S3] Out of Scope

- 搜索逐章 IR 提取（热点 3，parser 独占，结构性改造下轮）
- `PREPROCESSED_CACHE` 键加入净化 config_hash（本轮只在装回时 invalidate）
- `Book`/`TxtParser.content` 改 `Arc`（本轮克隆，仅重建路径）
- 3.2 对 route-2 空 content 返回 Err 而非空串（主路径 structured 不经此，复审认定可接受）

## Tasks

- [x] T1: TxtParser 拆分 — acceptance: build 拆为快照输入的纯函数 + hash 匹配检查方法，既有调用方不受影响 (covers: S2)
- [x] T2: TXT 路径两阶段 — acceptance: 稳态只取读锁；配置变更时重建不持 BOOKS 锁；装回后 invalidate (covers: S2)
- [x] T3: EPUB 路径两阶段 — acceptance: 同 T2 (covers: S2)
- [x] T4: 热点4 archive 内部锁 — acceptance: get_book_resource 慢路径只取读锁 (covers: S2)
- [x] T5: 验证 — acceptance: cargo test / flutter analyze 通过，审计清单注释同步 (covers: S1 S2)
