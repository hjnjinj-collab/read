---
feature: large-file-loading
status: in-progress
updated: 2026-09-27
branch: master
commits: # leave empty while in progress; fill at delivery
---

# 大文件加载优化（GB 级压缩包 / 大 PDF）

## Report

## [S1] Problem

1. **GB 级压缩包卡死**：`ComicArchiveParser::build_chapters` 对**每张图 `read_entry` 整文件解压**只为了 `probe_image_size` 取宽高比；封面再整图解压。百图 × 大图 = 打开即卡死/内存爆。
2. **大 PDF 打不开**：`BookFormat::Pdf` 只识别，`create_parser` 直接「暂不支持」。用户需要能打开很大的 PDF 阅读。

## [S2] Design

### 已拍板

| 轴 | 选择 |
|----|------|
| 压缩包宽高 | **懒探测 + 只读文件头**，不在打开时全量解压 |
| PDF | **支持大 PDF 阅读**（页级按需，不整书进内存） |

### 压缩包懒探测

1. `ArchiveReader::read_entry_head(path, max_bytes) -> Vec<u8>`  
   - Zip：`by_name` 后只读前 N 字节（默认 64KB，覆盖 PNG/JPEG/WEBP/GIF/BMP 头）。  
   - Rar：流式 `read()` 循环拼到 N 字节即停。
2. `build_chapters` **不再解压整图**：  
   - 章/页列表只来自 `list_entries`（中央目录，秒开）。  
   - `aspect` 用 `read_entry_head` + `probe_image_size`；失败记 `None`（懒补）。  
   - 封面：`read_entry_head` 截断字节即可（CoverStore 可显示缩略；完整图走 BookImageStore）。
3. **懒补 aspect**：`process_comic_chapter` 分页时若 `aspect` 为 None，再 `read_entry_head`（或整图）探测一次并写回缓存；分页缓存键含已解析 aspect 集合版本。
4. **内存**：单次打开只保留 path 列表 + aspect 表（每图 ~50B），不保留像素。

### 大 PDF

1. 新 `book_parser/src/pdf_parser.rs`，实现 `BookParser`。  
2. **mmap 打开**（`memmap2` 已有），不把整文件读入 Vec。  
3. **页数**：读 trailer/Root/Pages 树计数，不渲染。  
4. **按页消费**：`get_chapter_content` / 资源按页提取；一章 = 固定页块（如 20 页）或整本一章「全本」（与漫画一致：目录可按书签/页码）。  
5. **渲染路径**：页 → 图（扫描版）或 文本块（文字版）：  
   - 文字版：提取文本行进现有 TXT/EPUB 排版。  
   - 扫描/混合：页转图（`pdf`/`lopdf` 能提则提；否则占位「本页为图」+ 后续接 pdfium 渲染）。  
6. **大文件约束**：单页对象缓存 LRU；禁止整书对象表常驻；打开超时可取消（`openBookSeq`）。

### 加载 UX

- 打开书立即进阅读器骨架，目录就绪即可读；宽高/页图后台补。  
- 进度：`readerTrace` 打 `open.latency` / `archive.head_probe` / `pdf.open`。

### 测试边界

- Zip：多图 CBZ 打开不调用全量 `read_entry`（可用计数断言）；`read_entry_head` 能出 JPEG/PNG 宽高。  
- PDF：构造最小 PDF，`parse` 得页数；大文件 mmap 不整读（接口层）。

## [S3] Out of Scope

- pdfium 全功能渲染管线（扫描页高清光栅可二期）。  
- 加密 PDF。  
- 压缩包解压到磁盘缓存目录。  
- 并行多卷 RAR。

## Tasks

- [x] T1: `ArchiveReader::read_entry_head` + comic 懒探测（打开不解压全图） — acceptance: 多图 CBZ parse 只 head 读；单测宽高来自头 (covers: S2)
- [x] T2: aspect 懒补与分页缓存 — acceptance: 首次分页探测一次，二次命中缓存 (covers: S2; depends: T1)
- [x] T3: `PdfParser` mmap + 页数 + 分章/页结构 — acceptance: 最小 PDF parse 成功；大文件不整读 (covers: S2)
- [x] T4: PDF 文字页进排版 / 图页占位 + 导入接线 — acceptance: 文字 PDF 可翻页阅读 (covers: S2; depends: T3)
- [ ] T5: 打开延迟日志 + 测试 + 构建 — acceptance: cargo 测试过；fix_sync/analyze 无新错 (covers: S2; depends: T1, T4)
