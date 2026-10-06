---
feature: pdf-scan-reflow
status: delivered
updated: 2026-10-01
branch: master
commits: 14a4d88..HEAD
---

# 扫描件 PDF 文字化收口（全链路当字读）

## Report

**What was built** — 扫描 PDF 从「看得清」收到「当字读」：①书内搜索与展示同源——`pdf_chapter_items` 统一条目流（文本层 + OCR 缓存/现场识别 + `pdf_text_items`），`search_pdf_chapter` 按 `layout_items` 同口径累计锚点，命中可跳转；live OCR 结果回写 `OCR_PAGE_CACHE`，避免「展示有字、搜索无词」。②Windows 下 OCR 缓存键 `pdfimg:0:0` 含冒号写盘失败，`path_for` 净化非法文件名字符。③选区/笔记/复制：重排页 Text 条目携带递增 char 区间（与 TXT 同口径）；原图页无文本不可选。④字体/字号走同一 `LayoutConfig`，重排模式生效。

**Verification** —
- `cargo test -p bridge --lib`：PASS 23/23（含 `search_in_book_pdf_text_layer_anchor_alignment`、`search_pdf_ocr_cache_hits`、`pdf_reflow_pages_carry_selection_char_ranges`、`pdf_font_size_changes_pagination`）
- `cargo test -p book_parser --lib`：PASS 149（含 `page_cache_sanitizes_windows_illegal_key`）
- `flutter analyze --no-pub`：31 issues，与既有基线一致，无本轮新增
- `build_apk.ps1 -Abis arm64-v8a`：PASS，`app-arm64-v8a-release.apk`

**Journey log** —
- 搜索不能走 `get_chapter_content`（PDF 无净化 parser，且仅文本层）；必须与 `process_pdf_chapter` 共用条目构建
- OCR 磁盘缓存键含 `:` 在 Windows 非法；Android 可用但桌面断
- `is_illustration_text` 阈值 24 字：短 OCR 文当插画丢弃，不进字流
- live OCR 回写缓存是展示/搜索同源的关键一环
- PDF 分页用 `process_structured_chapter`，不是 TXT 的 `process_and_layout_chapter`

## [S1] Problem

扫描版 PDF 已能 OCR 重排出「像字一样的正文」，但还没真正**当字读**：

1. **书内搜索搜不到**：`search_in_book` 对 PDF 走 `extract_pages_text`（纯文本层），扫描页文本层为空，OCR 重排文本不进搜索草堆。
2. **选区/笔记/复制**依赖展示字符流与 `PageInfo` 锚点一致——重排路径需确认与 TXT 同口径可选中。
3. **字体/字号/字距**在重排模式应走同一 `TextStyle`；对照（原图）模式仍不可改字。

根因：展示走 `process_pdf_chapter` → OCR/文本层 → `layout_items`；搜索走 `get_chapter_content` → 仅文本层。两条链不同源。

## [S2] Design

### 收口目标（本轮）

| 能力 | 文字重排模式 | 原图对照模式 |
|------|--------------|--------------|
| 书内搜索 | 命中 OCR/文本层展示同源文本，锚点可跳转 | 不要求（无文字层） |
| 选区/笔记/复制 | 与 TXT 同口径（charOffset） | 不支持 |
| 字体/字号/字距/行距 | 与 TXT 同一路径生效 | 不生效（图） |
| 主题纸色 | 纸色底 | 图上叠色（已有） |

### 合同

**A. 搜索与展示同源（PDF）**

1. 新 `search_pdf_chapter`：章内按页组装与 `process_pdf_chapter` 相同的 `LayoutItem` 序列（文本页 `extract_pages_text` + 图像页 OCR 缓存/`pdf_text_items`，含标题缩放项）。
2. 字符流累加规则与 `search_epub_chapter` / `layout_items` 一致：`Text` = `chars()+1`（段落 newline）；`Image` = 0。
3. `search_in_book` 分派：`"pdf"` → `search_pdf_chapter`（不再落入 TXT 路径）。
4. 跳转：`SearchHit.anchor_char_offset` 经 `locate_page_for_offset` 落页，与进度恢复同机制。
5. 未 OCR 的扫描页：搜索时**同步**尝试 OCR 缓存读取；无缓存不阻塞整书搜索（跳过该页），不强制现场识别。
6. live OCR 结果**回写** `OCR_PAGE_CACHE`，后续搜索/展示同源。

**B. 选区/笔记/复制**

- 重排文本页必须是 `LayoutItem::Text`（已有）；`beginSelection`/`noteAtCharOffset`/摘录走 `PageInfo.startCharIndex` 偏移，与 TXT 相同。
- 页内无文本（原图/空 OCR）不建立选区（已有页尾空选区防御）。

**C. 字体解除限制**

- 文字重排模式：排版设置（字体/字号/字重/字距/行距/段距）与 TXT 同一 setter；切换后带锚点重排。
- 对照模式：设置可保留但不影响像素字（现状）；UI 文案标明「原图模式不可改字」。

**D. 测试边界**

- `search_pdf_chapter`：假 OCR 缓存文本 → 命中词 → `anchor_char_offset` 与 layout 字符流对齐（同 EPUB 锚点测试形态）。
- 分派：`get_book_format=="pdf"` 不再走 `search_txt_chapter`。
- 选区：重排页 Text 条目 char 区间非空且单调；原图页无文本。
- 字体：改 `font_size` 改变分页结果。

## [S3] Out of Scope

- 保留原版面的「OCR 文字层覆盖在扫描图上」精确对齐（二期）。
- 表格/公式版面还原、手写体专项。
- 对照模式搜索/选中。
- OCR 识别质量专项（错字表/分栏）。

## Tasks

- [x] T1: `search_pdf_chapter` + 分派接入 — acceptance: 扫描 PDF 书内搜索命中 OCR 文本且锚点可跳转 (covers: S2)
- [x] T2: 选区/笔记/复制在重排页回归 — acceptance: 重排页可选中复制加笔记；原图页不可 (covers: S2)
- [x] T3: 字体/字号在重排模式生效确认/解除限制 — acceptance: 改字体即时重排可见 (covers: S2)
- [x] T4: 单测 + 真机清单 + 规格收口 — acceptance: 测试过；Report 含验证命令 (covers: S2; depends: T1,T2,T3)
