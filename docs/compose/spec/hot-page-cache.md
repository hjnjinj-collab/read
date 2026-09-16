---
feature: hot-page-cache
status: delivered
updated: 2026-09-15
branch: master
commits: 
---

# 跨重启热分页缓存

## Report

**What was built** — EPUB + TXT 分页热缓存落盘（`legado_page_hot/`）。内存 miss 先读盘；成功分页后异步写盘。键用 source_path + 布局指纹（不含 UUID）。EPUB 当前章成功后后台预写前后各 1 章。会话 LRU 3→**10** 本。磁盘文件按 mtime 淘汰至 **400** 个。

**Verification** — `fix_sync.ps1` 构建成功。连开多本后回开、以及杀进程重开，首屏应命中热缓存。

**Journey log** — 1) 磁盘键必须用 source_path，不能用 book_id。2) 写盘放后台 + tmp/rename。3) 邻居章用 try_lock 预写，不挡前台。4) 会话 LRU 与磁盘缓存分层：内存管连开，磁盘管重启。

## [S1] Problem

内存分页缓存与 `book_id` 绑定且会话 LRU 仅 3 本；连开第 4 本或重启后仍要全量分页。用户要求每本都可缓存，并完成 TXT 落盘、邻居章预写、热缓存淘汰。

## [S2] Design

### 分层

| 层 | 范围 | 失效 |
|----|------|------|
| 会话 BOOKS LRU | 10 本 parse 会话 | 换书挤出 |
| 内存分页 LRU | 10 章（EPUB/TXT 各自） | TTL 900s |
| 磁盘热缓存 | 当前章 + 邻居±1（EPUB/TXT 同） | 指纹变更 / mtime 淘汰 |

### 启动预热

- 书架首帧后后台 `parse` 最近 3 本（不进阅读页）
- 常用书会话在内存；开书时分页先命中磁盘热缓存

### 磁盘

- EPUB：`{source_fp}_{layout_fp}_{ch}.json`
- TXT：`txt_{source_fp}_{config_hash}_{options_hash}_{ch}.json`
- 写：入内存后后台线程；tmp+rename
- 读：内存 miss → 注入 LRU（键含当前 book_id）
- 淘汰：目录内 json 超过 400 个时按 mtime 删最旧

## [S3] Out of Scope

- 热缓存预读到 app 启动时（仍按打开书 lazy 命中）
- 图片资源落盘

## Tasks

- [x] T1: 会话 LRU 扩到 10
- [x] T2: TXT 热缓存读写
- [x] T3: EPUB 邻居章预写
- [x] T4: 磁盘 mtime 淘汰 + 构建
- [x] T5: TXT 邻居章预写（与 EPUB 对齐）
- [x] T6: 书架启动后台预热最近 3 本
