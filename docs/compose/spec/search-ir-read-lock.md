---
feature: search-ir-read-lock
status: delivered
updated: 2026-09-11
branch: master
commits: 6100b3e..b19e09e
---

# 搜索逐章 IR 提取写锁消除（热点 3）

## Report

**What was built** — 消除 EPUB 搜索/分页 IR 提取的 BOOKS 写锁：`EpubParser.css_cache` 改内部 Mutex（与 archive 同构），`collect_stylesheets`/`fill_intrinsic_sizes`/`get_chapter_content_structured(_ex)` 全部降为 `&self`；`search_epub_chapter` 逐章循环与 `process_structured_chapter` IR 提取段从 `BOOKS.write`/`try_write` 降为 `BOOKS.read`/`try_read`。搜索不再饿死并发翻页，前台分页与预取同样受益。至此四个已审计锁竞争热点全部闭环。

**Verification** — `cargo check -p bridge` PASS；`cargo test`：bridge lib 17 + book_parser 123 + reader_core 154 + layout_engine 85 + epub_flow 9 全 PASS。独立审查无 critical；2 处过时注释（try_write 语义、前台争写锁表述）已修正。

**Journey log** — ①「内部 Mutex + BOOKS.read」是本仓消除热点锁的既定模式（archive → resource_cache → css_cache 三段同构）；检查新改锁时优先验证「短锁作用域内是否调用另一把内部锁」。②`prefer_try_lock` 语义从「与任意他者让路」收窄为「仅写者让路」——预取与前台分页现在可并发读，由内部 Mutex 串行化可变点。③std RwLock 非可重入纪律在 lib.rs BOOKS 声明处有完整审计清单，新增锁点须同步该清单。

## [S1] Problem

EPUB 书内搜索逐章循环持 `BOOKS.write()` 做 IR 提取（ZIP 解压+DOM+JS+CSS 收集，单章数 ms～数十 ms × 章数，预算 5s），期间所有并发翻页（读锁）被饿死。分页路径 `process_structured_chapter` 同样在写锁内做 IR 提取。根因：`get_chapter_content_structured_ex(&mut self)` 的唯一硬写点是 `css_cache: HashMap` 的 get/insert（archive 已在热点 4 改为内部 Mutex）。

## [S2] Design

与热点 4 archive 互斥同构的改造：

1. `EpubParser.css_cache` 改 `Mutex<HashMap<...>>`；`collect_stylesheets` 降为 `&self`（查/插分段持锁，不与 archive 锁嵌套）。
2. `fill_intrinsic_sizes` 降为 `&self`（内部仅 `get_resource_cached(&self)`；`blocks: &mut` 是独立借用）。
3. `get_chapter_content_structured_ex` / `get_chapter_content_structured` 降为 `&self`。
4. `search_epub_chapter`：`BOOKS.write` → `BOOKS.read`。
5. `process_structured_chapter`：IR 提取段 `BOOKS.write`/`try_write` → `BOOKS.read`/`try_read`（前台分页与预取同样受益）。

锁序：css_cache 锁与 archive 锁分段持有，从不嵌套；均在 BOOKS 锁内侧，无反向依赖。

## [S3] Out of Scope

- parse() 等导入期 `&mut self` 方法（单线程导入路径，无竞争）
- 搜索结果缓存/并行化
- collect_stylesheets/get_resource_cached 并发 miss 双解析（结果正确，仅浪费一次 IO，稳态命中后消失）

## Tasks

- [x] T1: css_cache Mutex + structured_ex 降 &self — acceptance: book_parser 编译通过，锁序无嵌套 (covers: S2)
- [x] T2: 搜索/分页调用点降读锁 — acceptance: search_epub_chapter 与 process_structured_chapter 无 BOOKS.write (covers: S2)
- [x] T3: 验证 — acceptance: cargo test --lib 全过，审计清单同步 (covers: S1 S2)
