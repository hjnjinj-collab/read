# 架构设计：端到端处理框架

> 更新: 2026-09-04
> 地位: 本文档是当前架构的**权威描述**，以代码实际状态为准。
> 视角: **主流程主线**——从应用启动到阅读翻页的完整链路；按模块查代码的速查表见 §11。
> 上一版（2026-09-02）覆盖到 A18/M10-B/M11/M12；本次更新到 **A19 翻页动画家族（水波纹 v16.10 / 坍塌溶解 / 快照按页 LRU / 手势互斥治理）**，动画域权威文档见 [PAGE_TURN_ANIMATION_ARCHITECTURE.md](./PAGE_TURN_ANIMATION_ARCHITECTURE.md)。

---

## 0. 架构总原则

### D9：JS 引擎主链路原则 ⚡

**内容提炼、章节识别、规则替换一律以 QuickJS(rquickjs) 执行 JS 规则为主路径。
正则仅允许出现在两类位置：**

1. **降级兜底**：JS 异常/超时时的自动回退路径；
2. **极简构建**：`js-engine` feature 关闭时的无 JS 模式。

历史违例已全部清零（mmap 大文件章节识别走纯正则 / 阅读级替换规则 string/regex 过渡态 / 广告净化硬编码正则均迁移至 JS 规则集）。

### D10：结构化路径 IR→布局零文本变换契约

`process_structured_chapter` 的 IR→布局链路**禁止任何文本改写**——行内富文本 StyledRun 字符区间锚定依赖此契约。正文文本变换只允许发生在 **IR 构建之前的 DOM 文本层**（先例：`convert_text_nodes` 在 DOM 构建后、JS 规则提取前就地转换）。

### D11：双分页核心有意分离

- `layout_text`（TXT 进度锚点字符偏移逐字节精确依赖）
- `layout_items`（EPUB 富内容：样式化文本 / 图片原子 / 表格多列）

两者**禁止合并重构**；后者镜像前者的锚点约定（图片项不消耗锚点、每段落 +1 分隔）。

### D12：双引擎字体同源（M7）

Rust `ab_glyph` 测量与 Dart `TextPainter` 绘制必须使用**同一份字体字节**。
默认状态：Rust `embedded_default`（include_bytes! NotoSansSC-Regular.otf）⇄
Dart `ReaderSerif`（rootBundle 加载 assets/fonts/NotoSansSC-Regular.otf）。
字体切换：用户选 .ttf/.otf → `loadFontData(name, bytes)` + `setDefaultFont(name)`
+ `FontLoader(name).addFont(bytes)` 三处同步。

---

## 1. 主流程总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│ 应用启动 (main.dart)                                                       │
│   │ WidgetsFlutterBinding.ensureInitialized()                              │
│   │ Rust FFI init → FONT_MANAGER 自动 load_embedded_default                 │
│   │ ReaderFont.initialize() → assets/fonts/NotoSansSC 注册为 'ReaderSerif'  │
│   ▼                                                                      │
│ 书架页 (BookshelfPage) — drift 持久化（书籍/进度/书签）                     │
│   │ 选书 / file_picker 选 .txt/.epub / 已存进度                            │
│   ▼                                                                      │
│ 阅读器 (ReaderPage) — 加载 session：parseTxtFileAsync / createReadingSession │
│   │ Rust BookService.init 内的 BOOKS HashMap 注册新书                    │
│   ▼                                                                      │
│ ┌─ 阶段二 加载解析工厂 ────────────────────────────────────────────────┐  │
│ │ BookSourceLoader::load() → 扩展名/魔数/启发式 → TxtParser / EpubParser │  │
│ └────────────────────────────────────────────────────────────────────┘  │
│   │                                                                      │
│ ┌─ 阶段三 内容处理（双线路）─────────────────────────────────────────┐  │
│ │ TXT: 编码检测 → mmap/整本解码 → JS 章节识别 → 净化缓存               │  │
│ │ EPUB: roxmltree 结构解析 → DOM JSON → JS 规则提取 → 结构化 IR        │  │
│ │ 阅读级预处理：六阶段流水线（去重/分段/HTML保护/替换/恢复/简繁）       │  │
│ │ 段落格式化（M9.2）：共享切分器 paragraph_splitter.rs（双路径统一）    │  │
│ └────────────────────────────────────────────────────────────────────┘  │
│   │                                                                      │
│ ┌─ 阶段四 分页与缓存 ──────────────────────────────────────────────┐    │
│ │ TXT:  layout_text（行级分页，ab_glyph 测宽 + GlyphCache LRU 10K）   │    │
│ │ EPUB: layout_items（混合分页：图片原子/出血/锚点文本累加/css_lite） │    │
│ │ 缓存：PAGINATION_CACHE (10章 LRU) + STRUCTURED_PAGINATION_CACHE      │    │
│ │       + 跨章共享 GlyphCache + Dart PageFrame 体系（M9）              │    │
│ └────────────────────────────────────────────────────────────────────┘  │
│   │                                                                      │
│ ┌─ 阶段五 渲染与翻页（PageFrame 体系，M9 + 动画家族 A19）──────────┐    │
│ │ ReaderProvider: _prepareAndPublishFrameSet → FrameSet 原子发布       │    │
│ │ ReaderRenderStateStore: 三槽 (current/previous/next) FrameSlot      │    │
│ │ PageTurnComposer: 门控(Ready/OutOfRange/Wait) + _startTurnAnimated  │    │
│ │   四模式: simulation卷曲 / verticalScroll / ripple水波纹 / collapse │    │
│ │   快照按页 LRU(8) + 串行链 + 排队互斥（详见动画架构文档）           │    │
│ │ PageContentRenderer: 文字直绘 + 图片查 ui.Image                      │    │
│ └────────────────────────────────────────────────────────────────────┘  │
│   │                                                                      │
│ ┌─ 阶段六 构建与发布 ──────────────────────────────────────────────┐    │
│ │ Windows: fix_sync.ps1（Rust DLL + Flutter）                         │    │
│ │ Android:  build_apk.ps1（cargo ndk 4 ABI → jniLibs → flutter build）│    │
│ │ Rust 端：reqwest 切 rustls-tls + rquickjs 切 bindgen + sqlite3 source│    │
│ │ 字体：NotoSansSC-Regular.otf（assets/fonts/，7.95 MB）              │    │
│ └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 阶段一：应用启动与字体（M9 字体架构重写）

### 2.1 启动序列（main.dart）

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BookService.init();              // ① Rust FFI 初始化
  await ReaderFont.initialize();         // ② Dart 端注册内置字体
  runApp(const ProviderScope(child: MyApp()));
}
```

### 2.2 字体架构（双引擎同源，D12）

```
[启动 BookService.init]
  └─ FONT_MANAGER 懒加载
     └─ FontManager::new_with_embedded_default()
        ├─ include_bytes!("../../../assets/NotoSansSC-Regular.otf")
        ├─ 解析为 ab_glyph::FontRef（Box::leak → 'static）
        └─ 注册名 "embedded_default"，设为 default_font

[启动 ReaderFont.initialize]
  ├─ rootBundle.load("assets/fonts/NotoSansSC-Regular.otf")
  ├─ FontLoader("ReaderSerif").addFont(bytes)
  └─ _isFontActive 探针（同文本同字号宽度对比默认）

[用户切字体 FontProvider.pickAndLoadCustomFont]
  ├─ FilePicker.pickFiles(.ttf/.otf/.ttc)
  ├─ 读 bytes → FNV-1a short hash 拼 fontName = 'user_${stem}_$hash'
  ├─ rust_api.loadFontData(name, bytes)   [Rust 注入]
  ├─ rust_api.setDefaultFont(name)        [Rust 切换]
  └─ FontLoader(name).addFont(bytes)      [Dart 注入]

[FontManager.get_font 三级 fallback]
  name → default_font → 任意已加载 → 抛错
```

### 2.3 关键文件

| 文件 | 职责 |
|------|------|
| `rust/crates/layout_engine/src/font_manager.rs` | FontManager + embed + fallback + set_default_font |
| `rust/crates/bridge/src/api.rs` | FONT_MANAGER + load_font_file 软失败 + load_font_data + set_default_font + get_default_font_name FFI |
| `lib/core/services/reader_font.dart` | initialize / loadCustomFont / 探针 |
| `lib/core/services/font_provider.dart` | file_picker 选 .ttf/.otf/.ttc 入口 |
| `assets/fonts/NotoSansSC-Regular.otf` | 内置字体（Dart）7.95 MB |
| `rust/assets/NotoSansSC-Regular.otf` | 内置字体副本（Rust，.gitignore 排除） |

---

## 3. 阶段二：加载解析工厂

**统一入口**：`rust/crates/book_parser/src/loader.rs`
`BookSourceLoader::load()` 按三级策略检测格式：扩展名 → 16 字节魔数 → 文本内容分析（默认 TXT 兜底），再分发构造器：
- Txt → `TxtParser::from_file`
- Epub → `EpubParser::from_file`
- PDF / MOBI 明确拒绝

```
┌─ 用户点 + 按钮 / file_picker ─┐
│ FilePicker.pickFiles(.txt/.epub) │
└──────────────┬─────────────────┘
               ▼
   parseTxtFileAsync (tokio spawn_blocking)
        │
        ├─ Rust: BookSourceLoader::detect_format
        │   ├─ extension
        │   ├─ magic bytes (16 bytes)
        │   └─ heuristic (默认 TXT 兜底)
        ├─ Rust: TxtParser::from_file 或 EpubParser::from_file
        └─ Rust: 返回 book_id（UUID，BOOKS HashMap 注册）
```

| 线路 | 解析 | 状态 |
|------|------|------|
| TXT | 编码检测（BOM → chardetng → 启发式评分 → GB18030 兜底）；>10MB mmap 模式 | ✅ |
| EPUB | ZIP 容器（roxmltree 结构解析 container/OPF/NCX/nav，命名空间按本地名匹配） | ✅ |

**A3 收敛后**：`parse_txt_file_inner` 经工厂格式判定 → 具体解析器；保留净化缓存能力；非 TXT 明确报错。

---

## 4. 阶段三：内容处理（双线路）

### 4.1 阶段三总览

```
                ┌─ TXT 线路 ─────────────────┐    ┌─ EPUB 线路 ─────────────────────┐
文件字节流       │                              │    │                                  │
  │             ▼                              │    ▼                                  │
  │     编码检测 (4 级策略)                    │  ZIP 容器 (roxmltree)                │
  │             │                              │    │                                  │
  │     解码文本 (整本/mmap)                    │  结构 XML (container/OPF/NCX/nav)   │
  │             │                              │    │                                  │
  │     JS 章节规则识别 (rquickjs 0.6)         │  TOC 提取（OPF nav 优先/NCX 兜底）   │
  │             │                              │    │                                  │
  │     ┌── 导入级净化 ──┐                    │  ┌── 导入级净化 ──┐                  │
  │     │ 净化缓存落盘   │                    │  │ EpubCleanedBook │                 │
  │     │ 净化后再识别   │                    │  │ 逐章清洗+偏移重算 │                 │
  │     └────────┬─────┘                    │  └────────┬─────┘                  │
  │              ▼                              │           ▼                        │
  │     ┌── 阅读级六阶段流水线 ──┐              │  ┌── 结构化提取 ──┐                  │
  │     │ 去重→分段→HTML保护    │              │  │ DOM JSON→JS规则 │                 │
  │     │ 替换(JS)→恢复→简繁     │              │  │ → ContentBlock IR │               │
  │     └────────┬─────┘                    │  └────────┬─────┘                  │
  │              ▼                              │           ▼                        │
  │     段落格式化 (M9.2 paragraph_splitter)    │  段落格式化 (同 splitter)            │
  │              │                              │           │                        │
  │              ▼                              │           ▼                        │
  │          最终显示文本                       │  IR v2 (Text/Image/Table/...)        │
  │              │                              │           │                        │
  │              └─────── 分页阶段 ─────────────┴───────────┘                        │
```

### 4.2 TXT 线路详情

**编码检测**（`encoding.rs::SmartEncodingDetector` L21）：
1. BOM 探测（L64）
2. chardetng 前 8KB 采样，置信度 ≥0.9 直接采纳
3. 启发式评分（GBK/GB18030/BIG5/UTF-8 四级）
4. 默认 UTF-8；GB18030 双重兜底

**JS 章节规则识别**（`chapter_extractor.rs::execute_js_sync`）：
- rquickjs 0.6，新建 Runtime+Context
- 注入全局 `content`，脚本返回 JSON `Vec<JsChapterInfo>`
- **中断机制（A10）**：AtomicBool 置位型中断 + 中断句柄 + 32MB 内存帽/1MB 栈帽
- tokio timeout 5s 仅作延迟兜底
- 规则优先级链（首个非空胜出）：p100 卷章结构 / p90 标准网文 / p80 英文 / p70 数字编号 / p60 特殊章节

**导入级净化缓存**（`content_cleaner.rs` + `txt_parser.rs::ensure_cleaned_chapter_cache`）：
- 懒构建于首读
- 净化后重新 JS 识别（数量不符按标题单调对齐兜底）
- 落盘 `{temp}/legado_cleaned/{filehash}_{config_hash}.txt`（mmap 模式 L552）
- `config_hash()` 含 `ruleset_hash()`——规则升级即失效全部净化缓存

### 4.3 EPUB 线路详情

**结构解析**（`epub_parser.rs`，A5 roxmltree 迁移完成）：
- container.xml → OPF → manifest/spine
- NCX navMap / EPUB3 nav 标题映射到 spine
- 命名空间按本地名匹配
- 嵌套目录 TocEntry{href_full, title, level, parent_index} 文档序 Vec

**结构化阅读主路径**（A7-A11 M0-M4 落地）：
- `XHTML → dom_json.rs (html5ever 容错→JSON DOM, 深度 512/尺寸 8MB)`
- `extract_rules.rs 独立 JS 执行器`（持久 Context / 中断超时 / warn_once，不与净化执行器共享）
- `ContentBlock IR v2`（Text/Image/Table/PageBackground/StyledRun/PageEntry...）
- `css_lite.rs` CSS 子集解析（tag/.class/tag.class/后代/specificity）
- `image_size.rs` 手写 PNG/JPEG/GIF/WEBP 头探测
- `layout_items 混合分页`（图片原子块 / 出血图整窗宽 / 锚点只随文本累加）
- 路线 2 权威规则见 `docs/design/EPUB_RENDER_RULES.md`

**EpubCleanedBook**（`epub_clean_cache.rs`，A5）：
- 逐章独立清洗（无跨章上下文）
- 强制 `clean_html=false`（EPUB 内容已是纯文本）
- 落盘 `{temp}/legado_cleaned/{pathhash}_{hash}.epub.txt`（首行 JSON 偏移头 + 全文）

### 4.4 阅读级预处理六阶段流水线（D7 决策顺序铁律）

```
① 去重标题 → ② 重分段 → ③ HTML保护(占位符映射)
→ ④ 替换规则(string直替 + regex带超时 + JS规则主路径)
→ ⑤ HTML恢复 → ⑥ 简繁转换(最后执行: 用户规则按原文书写)
```

**D7**：替换规则**先于**简繁转换执行——用户规则按原文书写，先转换则规则无法命中。

**D6**：简繁转换唯一权威实现 = `book_parser::chinese_convert`（zhconv 词组级）；导入级与阅读级共用。

**M9.2 段落格式化**（`paragraph_splitter.rs` 共享切分器）：
- 双路径（reader_core 不依赖 book_parser）纯函数库
- 阈值 Smart/Aggressive **用户可调**（默认 200/100 字）
- 强标点纯 CJK 集 + 次级标点有界回退（≤2×threshold）
- 闭标吸附（”永不落段首）+ 省略号原子（切口不落……中间）
- 切口后剩余内容作为新段落从头计数继续检测
- TXT 三阶段顺序铁律：合并→切分→缩进注入

---

## 5. 阶段四：分页与缓存

### 5.1 双分页核心

```
                ┌─ layout_text (TXT 承重) ────────────────┐
                │ grapheme 切分 + ab_glyph 字形测宽         │
                │ GlyphCache 线程安全 LRU 10,000           │
                │ 智能断页：75% 填充阈值 + 孤行守卫        │
                │ M9.2：行级分页（fill≥threshold 不再      │
                │      整段推页，改为算可容行数留/推）      │
                │ page.startCharIndex / endCharIndex 锚点  │
                └──────────────────────────────────────┘

                ┌─ layout_items (EPUB 富内容) ─────────────┐
                │ css_lite 物化 → layout_items 混合分页     │
                │ 图片原子块 / 出血图整窗宽 / 锚点文本累加  │
                │ StyledRun runs 跨行切段 / 表格多列排版    │
                │ StyledRun.bold/italic/underline 全链     │
                │ 灰小字注释 (is_comment) 单独通路          │
                │ 整页背景 (backgroundHref) 与装饰页同通道  │
                └──────────────────────────────────────┘
```

### 5.2 缓存体系（5 层）

```
┌─ L1 PAGINATION_CACHE ─────────────────────────────────────┐
│ reader_core::PaginationCache                              │
│ LRU(10) 按 (book_id, chapter, options_hash, para_format)│
│ CachedChapterPages.pages: Arc<Vec<Page>>（命中零克隆）    │
│ 容量淘汰为主，TTL 300s 为辅（M9）                         │
└───────────────────────────────────────────────────────────┘

┌─ L2 STRUCTURED_PAGINATION_CACHE ─────────────────────────┐
│ reader_core::StructuredPaginationCache (桥接层)          │
│ LRU(10) 按 StructuredPageKey 含布局配置                   │
│ 值类型 Arc<Vec<PageInfo>>（含 backgroundHref）            │
└───────────────────────────────────────────────────────────┘

┌─ L3 SHARED_GLYPH_CACHE ──────────────────────────────────┐
│ layout_engine::GlyphCache（ab_glyph 测宽用）              │
│ LRU 10,000 条 + 命中率统计                                │
│ 跨章共享 + 字体变更清空（M8-P4）                          │
└───────────────────────────────────────────────────────────┘

┌─ L4 净化缓存（落盘） ─────────────────────────────────────┐
│ TXT:  {temp}/legado_cleaned/{filehash}_{config_hash}.txt  │
│ EPUB: {temp}/legado_cleaned/{pathhash}_{hash}.epub.txt   │
│ 跨启动命中免重建                                         │
└───────────────────────────────────────────────────────────┘

┌─ L5 Dart PageFrame 体系（M9）─────────────────────────────┐
│ ReaderRenderStateStore: FrameSet 原子发布 (current/prev/next)│
│ FrameSlot 四态 (ready / outOfRange / failed / pending)   │
│ dirty 标记 + pending 手势登记                             │
│ 永不滞后于 state（degraded-from-state 补发）             │
└───────────────────────────────────────────────────────────┘

┌─ L6 MEASURE_CACHE (M10-B, 2026-09-02) ───────────────────┐
│ layout_engine::MeasureCache                               │
│ Dart TextPainter Skia 实测宽度缓存                        │
│ LRU 50,000 条                                             │
│ Key: (font_name, font_size_bits, text_hash)               │
│ 命中 → Skia 真实宽度；miss → ttf-parser 兜底             │
│ 命中率 ~95%+ (feedPageTextsWithPrefixes 预热后)         │
│ 字体切换时清空（set_default_font 调用）                  │
│                                                           │
│ 背景：ttf-parser hmtx ≠ Skia HarfBuzz 整形后宽度         │
│ 问题：左右边距视觉不对称                                  │
│ 方案：Rust layout 二分搜索时查 Dart 实测宽度             │
└───────────────────────────────────────────────────────────┘
```

**M10-B/M11/M12 MeasureCache 架构**（2026-09-02）

**问题背景**：
- Rust 用 `ttf-parser` 的 `glyph_hor_advance` 测量字符宽度
- Skia 渲染时经过 HarfBuzz 整形（连字、kerning、GSUB/GPOS、CJK 标点宽度类）
- 原始 hmtx ≠ 整形后 advance → 断行位置偏差 → 左右边距不对称

**解决方案**：
- Dart 端用 `TextPainter.layout` 测真实渲染宽度
- 批量回传给 Rust `MEASURE_CACHE`（FFI: `feed_text_widths`）
- Rust layout 二分搜索命中 cache 时用 Skia 真实宽度做断行决策

**M11 修复**：`TextLine.width` 字段语义从"容器宽"改为"本行实测宽"
- TXT 路径：`emit_line!` 宏调 `measure_text_width()`
- EPUB 路径：3 处 TextLine 构造点用 `line.width`
- 4 处 FFI 调用显式传 `fontName: ReaderFont.family`

**M12 优化**：
- 必修 1：`measure_text_width` 加 `font_size` 参数（支持标题行不同字号）
- 必修 2：Dart `feedPageTextsWithPrefixes` 喂入所有 char-boundary prefix
  - 字符边界对齐：`substring` vs `characters`，跳过 low surrogate
  - 与 Rust 二分查询 key 集合对齐，命中率从 0% → 95%+
- 必修 3：Cache miss fallback `min(ttf, content_width)`

**性能指标**：
- 首翻延迟：+22ms（仅首页，喂入 prefix 开销）
- 翻页稳定后：0ms 命中
- 内存占用：LRU 50k 条 ≈ 2-3 MB
- 命中率：~95%+（M12 必修 2 后）

```

### 5.3 缓存键单源化（M9）

**`StructuredParams` + `structured_cache_key()`**（M9 Stage 3）：三个 FFI 入口 + `process_structured_chapter` 共用，FFI 签名不变免 codegen。

**`para_format_hash`** 进入 `CacheKey` + `StructuredPageKey`——M9 段落格式化设置变更即换键自然重算。

**`get_book_resource` 资源锁优化**：parser 内 `peek_resource_cache(&self)` 读锁窥探，未命中才落写锁读 ZIP——避免渲染重复图/预热去重的锁竞争。

### 5.4 预加载调度（M9.3）

- **TXT 路径**：`PreloadExecutor` 任务身份与 Flutter frame fingerprint 对齐；策略收窄 [N±1]；`try_submit_dedup` 去重；oneshot sender drop 自动取消的陷阱已修（内联等待终态）
- **EPUB 路径**：独立 FFI `prefetch_structured_chapter` 幂等键查秒回；`process_structured_chapter` 加 `prefer_try_lock`——提取段 try_write 抢锁失败即让路 Ok(None)，前台恒阻塞等待恒 Some
- **Dart 端**：prewarm 按 next → current → prev 分组串行（目标方向最先就绪）、解码并发闸门 `_Semaphore(2)`
- 指标：`image.hit` / `set.drop` / `turn.wait{waitMs}` / `frame.commit{latencyMs}` / `image.failed` / `page.adopt.reject`

---

## 6. 阶段五：渲染与翻页（PageFrame 体系，M9 全阶段）

### 6.1 PageFrame 体系核心概念

```
PageFrame（不可变页面帧）
├── 页面身份：bookId + chapterIndex + pageIndex + startCharIndex + endCharIndex
├── 配置身份：layoutFingerprint (config fingerprint)
├── sessionEpoch：打开/关闭/换书/设置改变时递增
├── requestGeneration：每批异步加载递增
├── PageInfo：文字布局 + 图片几何 + 背景信息
├── ResourceManifest：背景图 + 所有图片 entry 的去重引用
└── ResourceState：ready / loading / failed（pending 表示「未拉取」）

FrameSet（一次发布的不可变快照）
├── current: FrameSlot
├── previous: FrameSlot
├── next: FrameSlot
├── configFingerprint
└── sessionEpoch

FrameSlot 四态：ready / outOfRange / failed / pending（永不静默置 null）
```

### 6.2 6 大不变量（M9 文档定义）

1. 动画期间 folding page 和 target page 不从全局 state 动态替换
2. 动画末帧、定格帧和提交后的第一帧引用同一目标 frame
3. 旧 generation 的页面、图片和预取结果不得回写当前状态
4. 复杂图文页的所有图片依赖在动画启动前已 ready 或稳定 failed
5. page identity 必须包含章节，不能只使用章节内 `pageIndex`
6. 配置或内容处理设置改变后，旧 fingerprint 的缓存结果不得复用

### 6.3 三阶段实施

**Stage 1：渲染重绘与提交原子性（止血）**
- `CurlPainter` 构造器增加 `required Listenable repaint` → 图片解码完成 `ValueNotifier` 通知直达 `markNeedsPaint`
- `PageTurnComposer` `onTapTurn` 重入守卫 + `_commitInFlight` 双保险
- 定格释放收紧为身份匹配 + 1500ms 安全超时
- `BookImageStore` failed 终态改 3 次退避重试（500ms/2s/8s）

**Stage 2：PageFrame / FrameSet 体系**
- `page_frame.dart` 新增：FrameIdentity / ResourceManifest / PageFrame / FrameSlot 四态 / FrameSet / PendingTurnGesture / TargetFrameResult 密封三态
- `reader_render_state.dart` 重写：FrameSet 原子发布 / advanceSession / publishEmpty / pending 手势登记-消费-取消 / dirty 标记
- `reader_provider.dart`：`layoutFingerprint()` 单源指纹 / `_invalidateFrames` 单入口失效联动 / `_prepareAndPublishFrameSet` 发布协议（stale 不静默丢弃 → degraded-from-state 补发）
- `page_turn_composer.dart`：手势门控三态 + pending 挂起重试（tap 400ms / drag 600ms 超时直翻保底）

**Stage 3：缓存一致性与调度**
- Rust `pagination_cache.rs`：条目 TTL 300s 辅助淘汰
- Rust `api.rs`：`StructuredParams` + `structured_cache_key()` 缓存键单源
- Dart 调度：prewarm 按 next → current → prev 分组串行（目标方向最先就绪）、解码并发闸门 `_Semaphore(2)`

### 6.4 关键文件

| 文件 | 职责 |
|------|------|
| `lib/features/reader/presentation/providers/page_frame.dart` | FrameIdentity/ResourceManifest/PageFrame/FrameSlot/FrameSet 不可变数据类 |
| `lib/features/reader/presentation/providers/reader_render_state.dart` | ReaderRenderStateStore 框架（5 个核心方法） |
| `lib/features/reader/presentation/providers/reader_provider.dart` | ReaderNotifier：FrameSet 发布协议（_prepareAndPublishFrameSet / adopt 双道校验 / _invalidateFrames） |
| `lib/features/reader/presentation/widgets/page_turn_composer.dart` | 手势门控 + pending 重试 + PageFrame 升格 + **_startTurnAnimated 启动封装（A19）** |
| `lib/features/reader/presentation/widgets/page_turn/curl_painter.dart` | CurlPainter（required Listenable repaint） |
| `lib/features/reader/presentation/services/book_image_store.dart` | LRU 64 + pin + prewarmManifest + failed 重试 |

### 6.5 翻页动画家族（A19，2026-09-04）

四模式（simulation / verticalScroll / ripple / collapse）+ 统一启动封装 `_startTurnAnimated`（快照就绪门控）+ 按页 LRU 快照缓存 + 排队互斥治理。**权威文档：[PAGE_TURN_ANIMATION_ARCHITECTURE.md](./PAGE_TURN_ANIMATION_ARCHITECTURE.md)**（分层架构 / 缓存体系 / 工程硬约束 / 诊断 trace 全集）。

---

## 7. 阶段六：构建与发布

### 7.1 Windows 构建（`fix_sync.ps1`）

```
[1/8] 关闭相关进程
[2/8] flutter clean
[3/8] cargo clean
[4/8] flutter pub get
[5/8] flutter_rust_bridge_codegen generate
[6/8] cargo build --release           # Rust → rust/target/release/bridge.dll
[7/8] Copy bridge.dll → rust/crates/bridge/target/release/bridge.dll
[8/8] flutter build windows --debug
```

### 7.2 Android 构建（`build_apk.ps1`，墙内环境）

```
[0/6] 前置检查：cargo-ndk / NDK / Java 路径
[1/6] flutter clean + 清空 jniLibs（避免 stale so）
[2/6] flutter pub get（pub.flutter-io.cn 镜像）
[3/6] 修补 pub cache plugin build.gradle（compileSdk = 36，AGP 9 强制）
[4/6] cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64
      -o android/app/src/main/jniLibs/ build --release
      → libbridge.so 4 ABI 落到 jniLibs/<abi>/
[5/6] flutter build apk（自动把 jniLibs/<abi>/libbridge.so 打进 APK lib/<abi>/）
[6/6] 验证 APK 内含 3 个 libbridge.so
```

### 7.3 Android 编译关键修复

| 修复 | 原因 | 详细 |
|------|------|------|
| 移除 `libbridge.so` 缺失 | 旧 build_apk.ps1 没 cargo build 步骤，APK 缺 Rust so | `docs/bugfixes/2026-08-29_APK启动黑屏_缺失libbridge.so.md` |
| `reqwest` 切 `rustls-tls` | 默认 `default-tls` = `openssl-sys`，Android 交叉编译无 sysroot 必 fail | `docs/bugfixes/2026-08-29_Android编译openssl-sys找不到OpenSSL切rustls-tls.md` |
| `rquickjs` 加 `bindgen` feature | 默认走预编译 `src/bindings/<target>.rs`，Android ABI 不在列表 | `docs/bugfixes/2026-08-29_Android编译rquickjs-sys缺bindings加bindgen.md` |
| AGP 9 compileSdk=36 | Flutter 17.x 默认 34 不满足 AAR metadata 校验 | `docs/bugfixes/2026-08-29_AGP9_强制compileSdk36_pub_cache修补.md` |
| sqlite3 hook 走 source 模式 | 默认从 GitHub 下载预编译 .so 墙内网络超时 | `docs/bugfixes/2026-08-29_Android构建sqlite3_hook_GitHub下载不通.md` |
| file_picker 升级到 12.1.2 | 8.1.6 走 FilePicker.platform 在 12.x 移除 | `docs/bugfixes/2026-08-29_file_picker_12.x_API破坏性变更.md` |

### 7.4 Android 关键配置

```kotlin
// android/app/build.gradle.kts
android {
    namespace = "com.legado.legado_flutter"
    compileSdk = 36  // AGP 9 强制 ≥ 36
    ndkVersion = flutter.ndkVersion  // 27.0.12077973
}

// android/settings.gradle.kts（pluginManagement）
repositories {
    maven { url = uri("https://maven.aliyun.com/repository/google") }
    maven { url = uri("https://maven.aliyun.com/repository/public") }
    maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
    google(); mavenCentral(); gradlePluginPortal()
}
plugins {
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}
```

```properties
# android/gradle.properties
kotlin.incremental=false  # 跨盘符相对路径错误（pub cache C: vs 项目 D:）
kotlin.incremental.useClasspathSnapshot=false
```

```properties
# android/gradle/wrapper/gradle-wrapper.properties
distributionUrl=file\:/D\:/dowland/gradle-9.1.0-all.zip  # 本机专用，绕开 services.gradle.org
```

---

## 8. 双线路现状矩阵（2026-08-29）

| 处理阶段 | TXT 线路 | EPUB 线路 |
|----------|----------|-----------|
| ① 加载解析工厂 | ✅ `BookSourceLoader` 格式判定 → TxtParser | ✅ 同一工厂判定 → EpubParser |
| ② 解码/解析 | ✅ BOM→chardetng→启发式→GB18030 兜底 | ✅ ZIP 容器 + roxmltree 结构 XML |
| ③ 章节识别 | ✅ **JS 引擎**内置优先级链，正则仅降级 | ✅ TOC 提取：OPF nav 优先/NCX 兜底 |
| ④ 内容净化（导入级） | ✅ JS 规则集主路径；净化缓存落盘 | ✅ EpubCleanedBook + 同构落盘 |
| ④' 内容预处理（阅读级） | ✅ 六阶段流水线；JS 替换主路径 | ✅ 与 TXT 共用同一预处理 |
| ④'' 段落格式化（M9.2） | ✅ 共享切分器 paragraph_splitter.rs | ✅ 共享切分器（双路径统一） |
| ⑤ 排版分页 | ✅ layout_text 行级分页（M9.2 改）+ 字形缓存 | ✅ layout_items 富内容：图片/出血/锚点/表格/行内 runs |
| ⑥ 字体统一 | ✅ Rust ab_glyph + Dart TextPainter 同源（embedded_default） | ✅ 同上 |
| ⑦ 渲染翻页 | ✅ PageFrame 体系（M9 全阶段） + 3 槽 FrameSet | ✅ 同上（结构化 IR 作为 PageInfo） |
| ⑧ 缓存 | ✅ PAGINATION_CACHE + 净化落盘缓存 | ✅ STRUCTURED_PAGINATION_CACHE + 净化落盘缓存 |
| ⑨ 预加载 | ✅ PreloadExecutor try_submit_dedup（修 oneshot 误取消） | ✅ 独立 FFI prefetch_structured_chapter 幂等 |
| 跨启动持久化 | ✅ 书架/进度/书签落库（drift），字符锚点恢复 | ✅ 同一机制（filePath 身份键） |
| 跨平台构建 | ✅ fix_sync.ps1（Windows） | ✅ build_apk.ps1（Android 4 ABI） |

---

## 9. 性能实测汇总（v3 口径，2026-08-29）

测试环境：Windows release；《贷款武圣(1-280章)》5.0MB / 279 章。
复现：`cargo run --release --package reader_core --example perf_baseline`

| 链路 | 实测 | 设计目标 | 结论 |
|------|------|----------|------|
| 导入 parse（JS 章节识别） | 无净化 99ms / 含净化 98ms | 打开 <300ms | ✅ |
| 净化缓存构建 | ~101ms（一次性） | — | ✅ |
| 章节读取 ×20（缓存命中） | max 3µs | — | ✅ |
| 内容预处理（单章，小规则集） | avg ~67–162µs | <100ms/10k 字 | ✅ |
| 排版分页（单章 12 页，字形缓存热） | avg 438µs | 首屏 <100ms | ✅ |
| 锚点定位（二分，单次） | ~3ns | — | ✅ |
| 设置变更重建 | 118ms / ΔWS +0.3MB | 即时响应 | ✅ |
| JS 规则扩展（B2） | 0.13ms/条/10KB 线性 | — | ✅ |
| QuickJS 池化（B3） | 冷 0.92ms / 池 0.57ms / 1.6x | — | ✅ |
| 大文件缩放（B4） | 1/5/20/50MB → 24/74/237/581ms（亚线性） | — | ✅ |
| 端到端 miss 分解（B5） | 0.771ms = 取 7% + JS 70% + 排版 23% | — | ✅ |

**M9 改进后增量指标**：
- `image.hit` / `set.drop` / `turn.wait{waitMs}` / `frame.commit{latencyMs}` / `image.failed` / `page.adopt.reject`
- 快速连翻无"翻给当前页"，图片密集 EPUB 拖拽占位解码后立即更新，改字号后旧排版页不回写

---

## 10. 关键决策记录（DR 系列）

### D1–D8（历史沿用，2026-08-22 前）
- **D1** 章节识别走 JS 引擎规则，放弃多级正则+置信度评分
- **D2** 字节偏移一律扫描原始字节 `\n` 建立行起始表（禁止 `lines()[i].len()+1` 累加）
- **D3** 章节边界与所索引文本同源：净化后必须重新计算边界
- **D4** 调度落地形态为 PreloadExecutor + DefaultPreloadStrategy（**[A16 M9.3 修正]**：executor 真实职责是相邻章 TXT 分页缓存预热；EPUB 走独立 FFI）
- **D5** 章节强制分页通过 `TextLine.is_chapter_start` 标记传递
- **D6** 简繁转换唯一权威实现 = `book_parser::chinese_convert`（zhconv 词组级）
- **D7** 替换规则先于简繁转换执行（用户规则按原文书写）
- **D8** 处理选项进 `CacheKey.options_hash`：设置变更新 key 自然重算

### D9 JS 引擎主链路原则（2026-08-22）
内容提炼/识别/替换以 QuickJS 执行 JS 规则为主，正则仅降级兜底与极简构建两种存在形式（§0）

### D10 结构化路径 IR→布局零文本变换契约（2026-08-23）
process_structured_chapter 的 IR→布局链路禁止任何文本改写——行内富文本 StyledRun 字符区间锚定依赖此契约。

### D11 双分页核心有意分离（2026-08-23）
layout_text（TXT 进度锚点字符偏移精确）与 layout_items（EPUB 富内容）禁止合并重构。

### D12 双引擎字体同源（M7，2026-08-28）
Rust ab_glyph 测量与 Dart TextPainter 绘制必须使用同一份字体字节。默认 embedded_default ⇄ ReaderSerif（同字节）；切换时 Rust FontManager + Dart FontLoader 同步注册。

### A13 双引擎漂移治理（M7，2026-08-28）
统一字体（ReaderSerif/simsun.ttc face 0）、参数传递（fontSize/lineHeight 从 provider 经 FFI 至 painter）、无约束排版+分级兜底（≤2% 原样/>2% 缩字号）、断行 epsilon 混合式（max(1px,0.5%) 上限 2%）；GlyphKey f32.to_bits() 消碰撞；避头尾禁则双路径统一。

### A14 EPUB 分页精度与性能（M8，2026-08-28）
LayoutConfig.page_fill_threshold 默认 0.9 双路径统一门槛；标题按 h1-h6 分级默认倍率与间距；注释块 (aside/footnote/CSS 小字号)→本章说灰字小行 (is_comment 通路到 Dart)，开关切换锚点恒定；跨章共享 GlyphCache + Arc<Vec<PageInfo>> 单页克隆 + 双锁合并 + Dart 页数缓存。

### A15 段落格式化与留白优化（M9，2026-08-29）
- **本章说检测修正**：CSS 兜底门槛收紧 0.85→0.75 + 字数 200→150 + 三重验证（祖先链/类名/孤立块）
- **底部留白智能优化**：场景 B（低填充率 <50% 长段落首行强制留当前页）+ 场景 C（标题孤立避免）
- **段落格式化**：ParagraphFormatter（纯 Rust，Smart/Aggressive/None 三模式）；首行缩进通过 TextItem.indent_first_line_em → layout_styled_paragraph 首行减宽 + layout_items 首行 x 偏移；EPUB CSS text-indent 由 resolved_text_indent 解析
- **M9.1 补充**：断行禁则回退 flush 后必须清空 pieces 已发射前缀再保留 pulled（否则下一行重复发射整个前缀——EPUB styled 与 TXT 双路径同源）
- **M9.2 补充**：
  - 共享超长段切分器 paragraph_splitter.rs（区间契约纯函数库，reader_core 不依赖 book_parser）
  - 阈值 Smart/Aggressive **用户可调**（默认 200/100 字，FFI setter 钳制 [20,2000]）
  - 强标点纯 CJK 集 + 次级标点有界回退（≤2×threshold）+ 闭标吸附 + 省略号原子
  - 切口后剩余内容作为新段落从头计数继续检测
  - TXT 三阶段顺序铁律：合并→切分→缩进注入
  - 表格单元格禁散文缩进：解析层 clear_cell_indent 递归清零 + 转换层强制 None
  - TXT 行级分页：layout_text 删除 fill≥threshold 整段推页决策，改为算剩余空间可容行数

### A16 TXT 翻页性能与预加载治理（M9.3，2026-08-29）
- **级联教训**：预热"真重排"路径必须与预热触发路径解耦——`process_and_layout_chapter` 拆 inner(allow_preload_trigger) 变体，`get_chapter_content` 拆 impl(trigger)+quiet
- **DefaultPreloadStrategy 收敛为 [N±1]**（±2 Low 取消）
- **PreloadExecutor.try_submit_dedup**：(book_id, chapter) 在途去重，worker 终态回收键
- **oneshot sender drop 误取消陷阱**：fire-and-forget 丢弃 PreloadHandle 会误发取消信号，try_submit_dedup 内联等待终态规避
- **命中零克隆**：CachedChapterPages.pages 包 Arc<Vec<Page>>（对齐 EPUB Arc<Vec<PageInfo>> 先例）
- **正则静态化**：is_chapter_marker / protect_html_tags 的现场 Regex::new 改 OnceLock 进程级单次编译

### A17 字体架构用户可选（M9 字体重写，2026-08-29）
- FontManager 启动自动 load_embedded_default（include_bytes! NotoSansSC）
- get_font 三级 fallback（name → default → 任意）
- load_font_file 软失败（log warn，不再抛）
- FontProvider 经 file_picker 选 .ttf/.otf/.ttc 注入两侧
- M7 同源约束保留（双引擎用同名字体名）

---

## 11. 模块速查表

| 模块 | 路径 | 一句话职责 |
|------|------|-----------|
| **book_parser** | `rust/crates/book_parser/src/` | 加载工厂、TXT 主解析、EPUB 解析 (roxmltree 结构解析 + 结构化提取主路径)、JS 章节规则、置信度识别器(未接线)、导入级净化 (JS 规则主路径)、EPUB 净化缓存、zhconv 简繁权威实现、编码检测、XHTML→JSON DOM、结构化提取 JS 规则集、CSS 子集解析物化、图片头尺寸探测、内容 IR v2 定义 |
| **layout_engine** | `rust/crates/layout_engine/src/` | 排版分页（layout_text = TXT 承重路径逐字节不动；layout_items = 结构化富内容路径：样式化文本/图片原子/表格多列）、智能分页、字形测宽缓存、**MeasureCache (M10-B, Skia 实测宽度缓存)**、FontManager (embed + 三级 fallback)、多章并行 (未接线)、GB2312 预热 (未接线) |
| **reader_core** | `rust/crates/reader_core/src/` | 阅读级六阶段预处理、段落格式化（共享切分器）、富流水线 + JS 池、ReadSessionManager、位置追踪、PaginationCache (LRU + TTL 300s)、PreloadExecutor (try_submit_dedup) |
| **bridge** | `rust/crates/bridge/src/` | 全部 FFI 入口：parse / get_chapter / get_page / get_page_processed / get_page_structured / get_page_count_processed / get_page_count_structured / prefetch_structured_chapter / get_book_resource / get_book_cover / get_book_format / font_*, session_*, cache_*, process_*, batch_*, search_*, book_source_* |
| **book_source_engine** | `rust/crates/book_source_engine/src/` | CSS/JSONPath/Regex 分析器（书源规则无 JS，与章节识别 JS 是两回事） |
| **lib/core/ffi** | `lib/core/ffi/` | Rust 端 FFI 的 Dart 封装：book_service.dart 调 Rust API；rust_bridge.dart/ FRB 自动生成 |
| **lib/core/services** | `lib/core/services/` | reader_font.dart（字体管理）+ font_provider.dart（file_picker 入口）+ **measure_text_service.dart (M10-B, TextPainter 实测宽度服务)**+ book_source_service.dart |
| **lib/core/database** | `lib/core/database/` | drift 数据库：书架 (Books) / 进度 (ReadingProgress) / 书签 (Bookmarks) |
| **lib/features/reader/providers** | `lib/features/reader/presentation/providers/` | reader_provider.dart (Riverpod Notifier) / reader_render_state.dart (FrameSet store) / page_frame.dart (不可变数据类) |
| **lib/features/reader/widgets** | `lib/features/reader/presentation/widgets/` | page_turn_composer.dart (手势门控 + pending 重试) / curl_painter.dart (Listenable repaint) / reader_page_widget.dart (PageContentRenderer) / reader_settings_dialog.dart (含字体选择) / reader_menu.dart / chapter_list_dialog.dart |
| **lib/features/reader/widgets/page_turn** | `lib/features/reader/presentation/widgets/page_turn/` | curl_painter / ripple_painter(_v16) / collapse_painter / page_turn_controller（turnDuration + .orCancel）/ page_turn_gesture / page_turn_types（PageTurnMode×4 + PageTurnSpeed 三档）/ simulation·scroll·ripple·collapse_turn_controller / block_collapse·ripple_shredder.frag |
| **lib/features/reader/services** | `lib/features/reader/presentation/services/` | book_image_store.dart (LRU 64 + pin + prewarmManifest + failed 退避重试) |

---

## 12. 工程硬约束（违反即出 Bug）

1. **字节偏移禁止 `lines()[i].len()+1` 累加** → 扫描原始 `\n`（D2）
2. **章节边界必须与所索引文本同源**（净化后需重算，D3）
3. **UTF-8 切片必过字符边界检查**；`\u{3000}` 占 3 字节
4. **标题比对前两侧都需 trim**（全角空格）
5. **替换规则先于简繁转换执行**（D7）
6. **简繁转换只经由 `book_parser::chinese_convert`**（D6）
7. **影响页面文本的处理选项必须纳入 options_hash**（D8）；分页计数与内容携带同一组选项
8. **内容提炼/替换类新能力禁止以正则为主实现**——正则仅兜底（D9）
9. **结构化路径 IR→布局零文本变换**（D10）——正文文本变换只允许发生在 IR 构建之前的 DOM 文本层
10. **双分页核心禁止合并重构**（D11）——layout_text 与 layout_items 是有意分离
11. **双引擎字体必须同源**（D12）——Rust FontManager + Dart FontLoader 同步注册同名字体名
12. **缓存键单源**——`StructuredParams` + `structured_cache_key()` 三处 FFI 入口共用（M9）
13. **预热"真重排"路径必须与预热触发路径解耦**（A16）——inner(allow_preload_trigger) 变体 + get_chapter_content 拆 impl(trigger)+quiet
14. **oneshot sender drop 会误发取消信号**——PreloadHandle 不可 fire-and-forget（A16）
15. **AGP 9 强制 compileSdk ≥ 36**——AAR metadata 强约束，所有 plugin `compileSdk flutter.compileSdkVersion` 改 `compileSdk = 36`（build_apk.ps1 自动扫所有 plugin）
16. **`reqwest` Android 编译必须 `default-features = false + rustls-tls`**——`default-tls` = `native-tls` = `openssl-sys` 必 fail

---

## 13. 修正路线图

| # | 任务 | 状态 |
|---|------|------|
| A1 | 激活 JS 预处理流水线 | ✅ 2026-08-22 |
| A2 | 统一章节识别走 JS | ✅ 2026-08-22 |
| A3 | 收敛统一加载工厂 | ✅ 2026-08-22 |
| A4 | 净化规则 JS 化 | ✅ 2026-08-22 |
| A5 | EPUB 净化链路对齐 TXT | ✅ 2026-08-22 |
| A6 | EPUB 嵌套目录（M0） | ✅ 2026-08-22 |
| A7 | 结构化 IR 地基（M1） | ✅ 2026-08-22 |
| A8 | 图片/富元素全链路渲染（M2） | ✅ 2026-08-23 |
| A9 | 文字样式·行内富文本·表格排版（M3） | ✅ 2026-08-23 |
| A10 | EPUB 阅读级简繁转换 + JS 中断迁移（M4） | ✅ 2026-08-24 |
| A11 | M5 元素渲染补全 + TXT 标题对齐 | ✅ 2026-08-24 |
| A12 | 预加载修复 + EPUB 翻章预取（M6） | ✅ 2026-08-24 |
| A13 | 双引擎漂移治理（M7，字体统一） | ✅ 2026-08-28 |
| A14 | EPUB 分页精度与性能（M8） | ✅ 2026-08-28 |
| A15 | 段落格式化与留白优化（M9）+ M9.1/M9.2 | ✅ 2026-08-29 |
| A16 | TXT 翻页性能与预加载治理（M9.3） | ✅ 2026-08-29 |
| A17 | 字体架构用户可选（M9 字体重写） | ✅ 2026-08-29 |
| A18 | MeasureCache 架构与左右边距修复（M10-B/M11/M12） | ✅ 2026-09-02 |
| A19 | 翻页动画家族：水波纹 v16.10 + 坍塌溶解 + 快照按页 LRU + 手势互斥/排队治理（权威文档 PAGE_TURN_ANIMATION_ARCHITECTURE.md） | ✅ 2026-09-04 |
| APK | Android 构建管线（libbridge.so + cargo ndk + rustls + bindgen + compileSdk 36 + sqlite3 source + file_picker 12） | ✅ 2026-08-29 |

**A18 详细说明（M10-B/M11/M12 三阶段修复）**：

- **M10-B**：创建 MeasureCache 架构
  - `measure_cache.rs`：LRU 50k 条，key=(font_name, font_size, text_hash)
  - `measure_text_service.dart`：Dart 端 TextPainter 测宽服务
  - FFI: `feed_text_widths` / `clear_measure_cache` / `get_measure_cache_stats`

- **M11**：修复 TextLine.width 字段语义
  - 从硬编码 `content_width` 改为 `measure_text_width()` 实测值
  - 4 处 FFI 调用显式传 `fontName: ReaderFont.family`
  - 解决根因：cache key 字体名错配（Dart 'ReaderSerif' vs Rust 'default'）

- **M12**：Cache 命中率优化（0% → 95%+）
  - 必修 1：`measure_text_width` 加 `font_size` 参数
  - 必修 2：`feedPageTextsWithPrefixes` 喂入所有 char-boundary prefix
  - 必修 3：Cache miss fallback `min(ttf, content_width)`
  - M12-v2：字符边界对齐（substring vs characters，跳过 surrogate pair）

**问题根源**：ttf-parser hmtx ≠ Skia HarfBuzz 整形后宽度 → 左右边距不对称  
**最终效果**：rustW ≈ skiaW（偏差 ≤ 1px），左右边距精准对称

**所有 A1–A19 + APK 全线落地**。下一阶段候选：
- P1：设置持久化（翻页模式/速度/字体——当前全部内存态，重启回默认）
- P1：坍塌动画参数设置化（阴影色 / 崩解节奏 / 方块大小 / 中心区阈值）
- P1：暗黑主题（PageContentRenderer.paperColor 硬编码，无主题字段）
- P2：CJK 避头尾与行首行尾禁则（A14 已部分实现，全量收口）
- P2：两端对齐（行内 justify pass）
- P2：诗歌/对话/引用智能分段（挂接规则扩展点）
- P2：激活 SmartPaginator / parallel / AdvancedGlyphCache 至 bridge 热路径
- P3：图文混排（EPUB 链路已具备，关键扩 Page 结构）
- P3：动画域清理（revealPageImage 字段 / buildSimulation 死代码 / RipplePainter v15 fallback 删除评估）
- P3：Android 真机验证动画体系（手势坐标/dpr/toImage 性能）
- P4：首字下沉、竖排（远期）
- 字体：可调字号/行距/字重的预览滑杆、字体持久化（重启自动恢复）
