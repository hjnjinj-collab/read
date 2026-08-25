# Legado Flutter 阅读器 —— 双路线管线架构总览

> 本文件是**管线级架构速览**（按阶段与双路线组织）。
> 模块级设计决策、里程碑记录见 [`docs/design/ARCHITECTURE.md`](./docs/design/ARCHITECTURE.md)；
> 踩坑排查见 [`docs/BUGFIX_INDEX.md`](./docs/BUGFIX_INDEX.md)。

```
                        ┌─────────────── Flutter UI (Riverpod) ───────────────┐
                        │  ReaderNotifier._loadCurrentPage 按 _isEpub 分流 API │
                        │  之后完全合流 → PagePainter 按 (x,y) 绝对坐标绘制     │
                        └──────────────────────┬──────────────────────────────┘
                                               │ FFI (bridge/api.rs)
        ┌──────────────────────────────────────┴───────────────────────────────────┐
        │ ①加载解析 ──► ②内容预处理 ──► ②.5段落格式化 ──► ③分页+排版 ──► ④缓存      │
        │   TXT│EPUB 分流        内部各有子路线        ★合流★            TXT│EPUB 分流 │
        └───────────────────────────────────────────────────────────────────────────┘
```

## ① 加载解析阶段（分流）

| | TXT | EPUB |
|---|---|---|
| 解析器 | `TxtParser`：mmap 零拷贝 + 编码检测（GB18030 兜底）+ `ChapterRecognizer` 章节识别 | `EpubParser`：zip → container.xml → OPF(spine) → 资源 LRU 按需解压；封面落盘 |
| 产物 | 章节偏移表 + 原文 | 章节→xhtml 映射 + css 样式表集合 |

## ② 内容预处理阶段（各自内部又有子路线）

**TXT 文本路线**：

1. **净化子路线**：`ensure_cleaned_chapter_cache`（parser 内嵌章节级净化缓存，config_hash 变更自动重建）← `ContentCleaner`（HTML 清理 / 去广告 / smart_paragraph_split 段落整理 / 简繁）
2. **预处理管线**：`ContentPreprocessor::process`——去重复标题 → 替换规则（JS 主路径，string/regex 兜底 D9）→ 阅读级简繁 → protect_html_tags

**EPUB 结构化路线**：

1. **净化子路线**：`epub_cleaned` 整书文本净化缓存（文件大小+mtime 指纹），仅服务文本级读取
2. **结构化提取主路线**（BOOKS 写锁内）：DOM 构建（超限整体回落）→ JS `extract_rules` → **`Vec<ContentBlock>` IR**（7 种块 + runs 锚定）→ 兜底纯文本化
3. **CSS 物化**：`apply_css_to_block`（css_lite 选择器+继承 → 对齐/颜色/字号倍率/text-indent；本章说 is_comment 三重验证；表格单元格缩进豁免）

### ★ 合流点 A：段落格式化

同一套 `ParagraphFormatSettings`（全局 FFI 同步 + 切分阈值用户可调），双路径共享切分器 `paragraph_splitter.rs`：

- TXT：`ParagraphFormatter` 三阶段 = 合并软换行 → 共享切分器切长段 → U+3000 缩进注入
- EPUB：`apply_paragraph_format_settings` = `split_ranges` 切短（clip_runs 同步重写 runs，D10 契约）+ 用户缩进覆盖 CSS

## ③ 分页 + 排版阶段（分流；两者在各自函数内一体完成，非先后两步）

| | TXT `layout_text` | EPUB `layout_items` |
|---|---|---|
| 断行 | `layout_paragraph`（禁则回退，M9.1 修重复发射） | `layout_styled_paragraph`（样式断行，runs 区间同步裁剪） |
| 分页策略 | **行级精度**（M9.2）：算剩余空间容几行→放得下留下→余量续排；孤行/寡行轻保护 | 场景 A/B/C：填充率推页 / 低填充首行强制 / 标题孤立避免 |
| 特殊块 | 无 | 图片原子块、表格多列原子排版、背景页 |
| 产物 | `Page { entries, start/end_char_index }` | 同左 + background_href |

**共用底座**：`FONT_MANAGER` + `SHARED_GLYPH_CACHE`（跨章跨路线共享字形度量，clone 仅 Arc bump）。

## ④ 缓存层（两条独立路线 + Dart 一层）

| 缓存 | TXT | EPUB |
|---|---|---|
| Rust 分页缓存 | `PAGINATION_CACHE`：LRU 10 章，`pages: Arc<Vec<Page>>`，命中零克隆 | `STRUCTURED_PAGINATION_CACHE`：LRU 10 章，`Arc<Vec<PageInfo>>` |
| 键构成 | book+chapter+config_hash(f32 bits)+options_hash(**para_format_hash**) | StructuredPageKey：尺寸/font/chinese_convert/**para_format_hash** |
| 后台预热 | `trigger_preload_async`：**N±1、去重、断级联**（M9.3） | 下一章幂等预取（try_lock 让路） |
| Dart 层 | `_chapterPageCounts` 内存页数缓存（排版参数指纹键） | 同左 |

## ⑤ 渲染（合流）

Rust 把两种产物统一压平为 `PageInfo/PageEntryInfo` FFI 形态 → Dart 单一状态源加载 → `PagePainter` 遍历条目按绝对坐标绘制，**对段落语义零假设**——跨页续排的行天然可绘，`startCharIndex` 只用于进度锚点。

## 贯穿性设计契约

1. **D10**：IR→布局零文本变换；凡动文本必同步重写 runs 区间（`clip_runs` 先例）
2. **D11**：TXT/EPUB 双分页核心有意分离不合并
3. **设置即缓存键**：任何影响排版的设置（含段落格式哈希、阈值）变更即换键自然失效，无脏缓存
4. **锚点进度体系**：字符偏移贯穿 分页→定位→恢复，设置变更后停留原阅读位置

---

一句话：**入口分流、格式化合流、分页排版各走一套但共享字体度量与产物形态、缓存各管一摊、渲染归一**。
