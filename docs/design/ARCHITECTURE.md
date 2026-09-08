# 架构设计：端到端处理框架

> 更新: 2026-09-05
> 地位: 本文档是当前架构的**权威描述**，以代码实际状态为准。
> 视角: **主流程主线**——从应用启动到阅读翻页的完整链路；按模块查代码的速查表见 §11。
> 上一版（2026-09-04）覆盖到 A19 翻页动画家族 + A25 行级分页统一；本次更新增加**版本管理说明**。

---

## 版本管理说明

**本文档中的 A1-A25 是 ADR 编号（Architecture Decision Record，架构决策记录）**，用于追踪技术决策历史，**独立于用户可见的应用版本号**。

- **应用版本号**：在 `pubspec.yaml` 中维护（格式：`1.0.0+1`，遵循[语义化版本](https://semver.org/lang/zh-CN/)）
- **版本历史**：在根目录 `CHANGELOG.md` 中记录（遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 格式）
- **版本同步**：`pubspec.yaml` 版本号自动同步到 Android `versionCode`/`versionName` 和 iOS `CFBundleVersion`/`CFBundleShortVersionString`
- **git tag**：每次正式发布时创建对应 tag（如 `v1.0.1`）

ADR 编号示例：
- **A25**：统一 EPUB/TXT 行级分页精度（2026-09-05 技术决策）
- **A19**：翻页动画家族架构（水波纹/坍塌/快照 LRU）
- **M9**：段落格式化共享切分器

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
| A20 | P2 排版批次：kinsoku 收口扩表 + 两端对齐 justify + EPUB margin-bottom/line-height 物化 | ✅ 2026-09-04 |
| A21 | P3 行尾标点压缩悬挂：断行预算压缩 + 悬挂渲染 + 设置开关 | ✅ 2026-09-04 |
| A22 | P4 性能激活（缓存共享/预热键对齐/孤寡行保护/SmartPaginator 退役）+ 智能分段扩展 | ✅ 2026-09-04 |
| A23 | P3 动画域清理：v15 fallback 删除 + buildSimulation 家族/PageFlipSession/viewport 只写链清退 | ✅ 2026-09-05 |
| A24 | 字体设置批次（字号/行距滑杆 + 字体选择持久化）+ EPUB 分页碎片化回归修复 | ✅ 2026-09-05 |
| A25 | 统一行级分页精度：EPUB 场景 A/B 退役 + fill_threshold 语义重定义（双路径统一消费） | ✅ 2026-09-05 |
| A30 | 书内全文搜索（Rust 统一 API + 锚点对齐单测 + UI 跳转） | ✅ 2026-09-07 |
| A30b | EPUB 替换规则接入（块级应用 + rules_hash 缓存键）+ 搜索键盘/跳转闪帧修复 | ✅ 2026-09-07 |
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

**A20 详细说明（P2 排版批次，2026-09-04）**：

- **kinsoku.rs 收口扩表**：LINE_START/END_FORBIDDEN + is_word_char 三处复制
  （layout_paragraph 旧版/with_oracle/styled）统一单源；扩表半角标点/省略号
  变体/单位符号（°′″‰℃）。直引号 ' " 为历史双表成员（禁止单独引号贴行边），
  disjoint 测试以白名单显式声明。
- **两端对齐 justify**：`justify_gap = (可用宽 − 自然宽) / n_chars`（除以
  n_chars 吸收 Flutter letterSpacing 对行尾字符的加宽）；短行豁免（富余
  >40% 行宽或单字间隙 >半字）；末行/Center/Right/表格单元格豁免；EPUB
  `text-align:justify` 解析回正（此前折叠 Left）+ 全局开关
  `ParagraphFormatSettings.justify`（Left/未指定段落跟随）；**Dart 消费 =
  TextStyle.letterSpacing（单 TextPainter 模型不变，char_positions 否决）**；
  拉丁词保护段 `LineSeg.letter_spacing=Some(0)`；**MeasureCache 红线：测量
  样式恒 letterSpacing=0**。justify 在行 emit 层与预处理层（重新分段）零交集，
  formatter 全量测试零回归（硬性承诺达成）。
- **margin-bottom 物化**：真缺口在 bridge——IR `spacing_after_em` 字段早已
  存在却被硬编码 0.0 丢弃；`resolved_spacing_after_em`（em/%/px/pt；margin
  非继承 → self-only）；布局期与用户段距取 max（书内样式下限、用户倍率兜底）。
- **line-height 物化**：IR/TextItem 增 `line_height: Option<f32>`；
  `resolved_line_height`（继承属性 → self_or_inherited；无单位数字最常见
  形态经 Keyword parse）；**书内显式声明优先、未声明用用户全局**（与缩进的
  "用户覆盖"语义相反，样式保真）；表格单元格同享；重新分段切分后每段继承
  原段行高（段级属性）。

**A21 详细说明（P3 行尾标点压缩悬挂，2026-09-04，用户实测验收）**：

- **语义定案**：压缩只作用于 Rust 断行的**宽度预算**（判满比较点），
  渲染端 Dart 以全宽字形原样绘制 → 行尾标点自然悬挂出右缘约半个字宽
  （悬挂语义，用户确认观感可接受）。ab_glyph 无法应用 GSUB halt 特性 →
  FontFeature.halt 方案双引擎脱钩，否决。
- **接入点**：oracle 路径 find_longest_fit 判满后压缩延伸（下一字符可压缩
  且 w_full − discount ≤ max+eps → 多吃一字）；styled 判满分支压缩接受并
  立即 flush（**被压缩字符恒为行尾字符**不变量）。折扣按 Skia 单字符自然宽
  ×(1−0.5) 计，MeasureCache 只存 raw 整串宽——M12 红线不破。
- **关键坑**：M12 必修3 的 `width.min(content_width)` 钳制与悬挂冲突——
  钳制后 Dart 端 2% 超宽检查触发整行 canvas.scale 压小而非悬挂。修复 =
  `report_line_width` 悬挂行跳过钳制上报 raw（skiaW==rustW 检查天然通过）。
- **记录口径**：pieces/LaidLine.width 保持 raw → justify_gap 的 slack≤0
  对悬挂行自动豁免（零特判）；行首维持既有避头尾 pull-back 不动。
- **设置**：`ParagraphFormatSettings.punctuation_compress`（默认关）+ FFI +
  持久化 + 设置面板开关 + para_format_hash 纳入。行中邻接挤压（segments
  细化 + letterSpacing 负值合并）经用户拍板**彻底砍掉**，勿再评估。

**A22 详细说明（P4 性能激活 + 智能分段扩展，2026-09-04，用户实测验收）**：

- **structured 路径字形缓存共享**：新构造器 `with_cache_and_measure`，
  `build_layout_engine` 升级双缓存注入——此前 EPUB 排版每章全新
  GlyphCache 全冷（首排逐字 ttf 查询），prewarm 字形现对全部排版入口可见。
- **预热键对齐（修复隐性历史 bug）**：SHARED 预热键 `("default",18)` vs
  热路径键（Dart 传入 `"ReaderSerif"`）不匹配——GB2312 预热对热路径
  **完全无效**（M9.4-F 只验证了缓存填充未验证命中）。修复 = ① Dart 启动
  loadFontData('ReaderSerif') 向 Rust 注册热路径字体名；② 三个字体 FFI
  clear() 后按新字体重建预热；③ `last_prewarm` 去重防连续调用重复 40ms。
- **孤行/寡行保护**：盘点确认 TXT 路径 M9.2 已有（行级分页决策块），
  缺口仅 EPUB styled 路径 → 段首一次性决策本页容行数（寡行：拆分给下页
  残留单行 → 本页少放一行；孤行：本页仅容 <2 行且页有足够行 → 整段推下页），
  对齐 TXT 口径。**教训：决策变量在流式循环内逐轮重置则 cap 失效——
  一次性决策必须提到循环外**。
- **SmartPaginator 退役（A22 定案）**：不接入生产管线——与 M9.2 行级分页
  职责重叠、后处理重分组触及进度锚点连续性（用户确认锚点安全方案）；
  avoid_orphan/avoid_widow 字段在本模块内从未被消费（空壳）；模块保留
  作检测器参考与测试基线。parallel 维持跳过（M9.3 后预热仅单章，rayon 零收益）。
- **智能分段扩展（挂现有"重新分段=智能分段"开关，零 FFI 变更）**：
  ① 诗节行——连续 ≥3 短行 run（2-16 字、无句末标点、非对话/章节/引用）
  独立成段不并入前后长段；② 引用行——`>`/`＞` 前缀去前缀独立成段；
  ③ 对话闭合——「…」完整闭合立即断段，未闭合（「…」她说）维持合并。
  用户拍板：不加新设置项，避免 FFI 签名再膨胀；未来要开关时一次换
  struct 传参。

**A23 详细说明（P3 动画域清理，2026-09-05，用户实测四模式验收）**：

- **删除 ~1120 行**：① buildSimulation 家族（基类抽象 + 4 子类实现 +
  4 个私有 Simulation 类，基类 _animateTo 自 M10 起走 animateTo +
  easeOutCubic，Simulation 路径 0 消费）；② revealPageImage（composer
  恒传 null，paint 零消费，v16.9.3 揭示层已实时矢量直绘）；③
  PageFlipSession 整文件（M9.5 未接线早期方案，composer 实际用散装
  互斥旗标）+ 专属测试；④ RipplePainter v15（283 行——仅 shader 加载
  失败时可达，且直绘无纸色底/无渲染参数违反硬约束 5；shader 失败降级
  改 curl 直绘，对齐 collapse 先例）；⑤ ReaderRenderViewport 只写发布链
  （全库零 listener 的"未来契约"，触点/进度由 composer 自有字段承载，
  git 历史可找回）；⑥ widget_test.dart 模板残留（永久挂红）。
- **保留确认**：CurlPainter fallback 直绘（collapse fallback + 定格/释放
  依赖）、互斥旗标体系、快照串行链、PageTurnMode 4 枚举（按 name 持久化，
  不可改名/删值）。
- **顺带修复**：page_turn_controller_test 红测试（断言模式数 2 → 4）。

**A24 详细说明（字体设置批次 + 分页碎片化修复，2026-09-05，用户实测验收）**：

- **字号/行距滑杆**：设置面板字体区两条滑杆（字号 12-32 / 行距 1.0-2.0），
  `onChangedEnd` 才落地重排（防拖动逐帧全量排版）；`setLineHeight` 镜像
  setFontSize 失效链（行距不改字形宽 → 测量缓存不动）。fontSize/lineHeight
  的持久化 P1 已备，本批只补 UI 与 setter。
- **字体选择持久化（补齐 M9 遗留"重启全丢"）**：选字体时文件复制到
  `<appSupport>/fonts/`（file_picker 原路径不可依赖）+ 持久化 family/path；
  启动按副本注入两侧引擎（P4 预热重建自动跟上）；副本丢失静默回退内置；
  新增"恢复内置字体"入口。
- **锚点红线（滑杆路径回归教训）**：任何排版参数变更的重载**必须带
  `anchorCharOffset`**——裸页码在新排版下越界会打回 "Page not found"
  错误页（滑杆路径曾回归，用户被迫重启）。定位链：anchor 优先
  locate_page_for_offset（saturating 二分，恒返回合法下标），无锚点才用
  请求页码。
- **EPUB 分页碎片化回归（P5 孤寡行保护两连修）**：① cap 断页后必须重置
  （旧 cap 按段落起点页剩余空间算，跨页后余行每 3~4 行被再断）；②
  **浮点 ULP 漂移**——cap 用乘法、current_y 用逐行累加，整段恰好 fit 时
  末行被 ULP 判越界甩到下页 → 修复 = cap 比较 +0.5px 容差。复现测试
  （用户实测参数）留在套件防再犯。**教训：累加量与乘法量比较必须加容差，
  "数学上相等"在 f32 累加链下不可靠**。

**A25 详细说明（统一行级分页精度，2026-09-05）**：

- **背景**：用户要求 EPUB 与 TXT 统一实现基于行的分页精度（重新分段后
  每页留白仍不统一）。盘点结论：EPUB Text 臂的**场景 A（fill≥threshold
  整段推页）+ 场景 B（fill<0.5 硬编码仅强制首行）**两档策略是留白不统一
  的根因；而 P4 孤寡行 cap 本质上已是 TXT `lines_fit` 决策的流式等价版。
- **场景 A/B 退役**：删除两段策略代码（~110 行），EPUB 断页唯一路径 =
  P4 cap 行级拆分（段首一次性 fit + 寡行/孤行保护 + 0.5px 容差 + 断页
  重置），与 TXT M9.2 同构。场景 C（标题孤立避免）保留（EPUB 标题分级
  语义，TXT 无此概念）。
- **fill_threshold 语义重定义（用户拍板：滑杆保留且双类型生效）**：
  由"EPUB 整段推页门槛"重定义为**内容区利用率**——`bottom_limit =
  content_top + content_height × threshold`，行级断行提前发生，页底按
  比例统一留白。TXT（此前零消费但入缓存键=白白换键）与 EPUB 统一接线；
  零 FFI 签名变更（threshold 已在链路中）；缓存键分量保留（滑杆改动
  换键重排从此真实有效）。Dart 默认值 0.9 → 1.0（新语义下 1.0 = 旧行为
  "填满"基线）；测试引擎基线同 1.0，阈值行为由专项单测覆盖。
- **页底 space_after 折叠**：段后距在底界处不再虚增 current_y（双路径
  统一）——下段起点越过底界时本段后距不计入，消除提前断页偏差。
- **A25b（首轮实测追加）：填充率 100% = 孤寡行保护自动挂起**。用户实测
  对话密集段（1-2 行短段）在 100% 下仍有页底 1~2 行槽缺口——诊断确认
  是寡行牺牲/孤行推页的固有代价（保护每次页底触发损失 1~2 行槽，短段
  高频触发 → "有的填满有的留白"）。修复 = threshold≥1.0 时双路径统一
  挂起保护（纯行级填满，残差恒 <1 行槽+段距）；<100% 时保护生效（用户
  主动预留空间，保护代价可预期）。保护类单测显式设 0.9 激活。
- **A25c（真机实测追加）：页码越界钳制 + 滑杆 1% 步进**。①翻页中偶发
  "Page not found"——设置变更竞态/邻页预取在途时，无锚点请求的页码可能
  来自旧排版的陈旧索引（≥ 新页数）。三路径（get_page / get_page_processed /
  get_page_structured）统一钳制到末页并打 [READER][clamp] 日志，不再抛错；
  Dart 端 PageFrame adopt 指纹校验识别内容不符后按新状态重试（既有机制）。
  锚点路径 locate_page_for_offset 本就 saturating，不受影响。②填充率滑杆
  divisions 10→50（1% 步进，可选 98%/99%）；既有 5% 刻度值全部落在 1% 网格
  上，持久化值无迁移。
- **教训**：①"两种策略各管一段填充率区间"（A: ≥threshold / B: <0.5
  硬编码 / 其余裸流）在参数轴开放后必然产生观感断层——**断页策略唯一化
  + 连续参数控制底界**才是可预期的留白；②死参数（TXT 零消费 threshold）
  留在缓存键里会静默制造无效重排，参数语义变更时全链路（消费点/键/UI
  文案/默认值）必须同步盘点；③**排版保护与显式用户目标冲突时，用户目标
  优先**——保护在 100% 填满语义下挂起，而非让用户在"精确控件"与"隐藏
  策略"之间猜；④**FFI 边界对陈旧索引要兜底而非报错**——排版参数可变
  系统里，请求页码与当前页数的竞态不可根除，钳制+上层指纹重试比错误页
  体验好。

**A26 详细说明（图文混排分页算法优化，2026-09-05）**：

- **背景**：用户反馈"图文混合似乎没考虑"。盘点确认 Image/Table 作为**原子块**
  处理（放不下→整体推下页），**未参与 Text 臂的行级 `fit_avail` 计算**，导致
  Text 行级拆分精准填充后图片被迫翻页产生页底留白。
- **核心改动：预扫描前瞻 + 虚拟 bottom_limit**。新增 `peek_next_atomic_height`
  方法前瞻下一个 Image/Table 的高度；Text 臂 `fit_avail` 计算时检查后继原子块，
  如果段落+图表能同页放下 → 降低 `para_bottom_limit` 为图表预留空间。
- **原子块语义保持**：Image/Table 不支持跨页拆分（排版完整性 > 极端场景），
  通过警告日志提示边缘情况（表格 >0.85×content_height、图片缩放比 <0.5）。
- **收益**：Text 最后几行与后续 Image/Table 协同决策，避免图表被迫翻页导致
  留白；`page_fill_threshold` 对混排页统一生效（降低 threshold → Text 提前
  预留空间 → 图表与文本同页留白一致）。
- **边缘情况处理**：① 前瞻仅限直接后继（不递归），连续原子块的分页由其自身
  翻页逻辑处理；② 预留空间但图表实际翻页（如 margin-top 推高）→ Text 留白
  可接受（边缘情况，且留白在 threshold 控制范围内）。
- **测试验证**：所有现有测试保持全绿（前瞻返回 None 时行为不变），锚点口径
  与 A25 一致（Image 不消耗 char_index，Table 消耗 chars）。

**A27 详细说明（图片加载三阶段性能优化，2026-09-05）**：

- **背景**：用户实测"进入书籍后图文混合页面图片出现比较晚"。explore-22/23
  双代理并行调查锁定三大根因：①**无首屏预加载**——打开书籍只加载 PageInfo，
  首次绘制触发懒加载（FFI 取字节 ~10-30ms + 解码 ~50-150ms）；②**并发限流
  过严**——`BookImageStore._decodeGate = Semaphore(2)`，图片密集页 10 张图需
  5 轮串行批次累积 500ms+；③**预热时机滞后**——仅在 FrameSet 发布/翻页提交
  后触发，首屏无预热。Rust 侧 `ResourceCache` 字节缓存 + `get_book_resource`
  快慢路径本已完备，瓶颈在 Dart 解码层与预热时机。
- **阶段 1 快速见效（f2fb58f）**：①首屏预热——reader_provider 新增
  `_prewarmCurrentPageImages()`，`_loadCurrentPage` 成功后 fire-and-forget
  预热当前页图片（不阻塞 UI、不等待邻居页）；②解码并发 2→4（常量
  `_maxConcurrentDecodes`）；③Rust `ResourceCache` 容量 50→150。
- **阶段 2 智能预测（ce4a4c8）**：①翻页方向统计（`_lastTurnDirection` +
  `_consecutiveTurns`，5s 窗口）+ 连续 ≥2 次同向翻页预热"下下页"；②
  `STRUCTURED_PAGINATION_CACHE` 添加 TTL 900s（`StructuredCacheEntry` 时间戳包装，
  与 TXT PAGINATION_CACHE 对齐），长时间静读后陈旧缓存自动失效。
- **阶段 3 进度反馈（62712e0）**：占位框状态化 `_drawImagePlaceholder()`——
  loading 画圆弧加载指示器 / failed 画 × 错误标记 / 未请求纯灰块，替代
  无差别灰块，用户可区分"加载中"与"加载失败"。
- **关键决策**：①预热恒 fire-and-forget，`ReaderNotifier` 是 Riverpod
  Notifier 无 `notifyListeners()`，重绘由 `PageContentRenderer.ensureLoaded`
  回调链自动驱动——预热层不主动触发重绘；②快照等待图片（原任务 1.4）**暂
  缓**——首屏预热后翻页时图片大概率已在缓存，若真机实测快照仍含占位框再
  评估（等待会延迟动画启动）；③**ZIP 池化评估后否决**——`EpubParser.archive`
  （`Option<ZipArchive<File>>`）本就常驻整个书会话，不存在"频繁重开"，原计
  划的池化前提不成立，阶段 3 改为进度反馈（用户收益更直接）。
- **预期指标**：首屏图片延迟 200-500ms → <50ms；翻页图片延迟 100-300ms →
  <20ms；10 图页加载 5 轮批次 ~500ms → 2-3 轮 ~200ms。调优入口与真机验证
  清单见 `docs/design/IMAGE_LOADING_PERFORMANCE.md`。

**A28 详细说明（图片就绪重绘修复 + 快照完整性失效机制，2026-09-06）**：

- **背景（A27 真机验证反馈）**：①图片就绪后页面不重绘，需翻页才显示；
  ②含占位框的陈旧快照被翻页动画复用。用户定案方向：**不用"等待"延迟
  动画，用"失效重建"提高快照命中率**——空间代价（LRU 8 张快照）必须
  兑换为完整快照命中。
- **根因一（重绘断裂）**：`BookImageStore.ensureLoaded` 幂等短路丢弃
  onReady——key 已在 `_loading` 时立即 return。预热路径（prewarmManifest
  空回调）必然先于 paint 端发起加载 → paint 端真实重绘回调必输竞争被
  丢弃 → 解码完成只触发空回调 → 静态页无下一帧。Widget 侧 repaint 链
  （`_repaintTick` ValueNotifier → PagePainter repaint 参数）本身闭合。
- **修复一（多播回调）**：`_pendingCallbacks: Map<String, Set<VoidCallback>>`
  ——命中 `_loading` 时挂入集合而非丢弃；解码终态（成功/失败）全部触发
  并清理；成功同时自增全局 `imageReadyTick`。效果：图片就绪 → 下一帧
  自动重绘（用户无操作也推送）；curl/scroll 直绘路径同步受益。
- **根因二（陈旧快照）**：快照键 `_snapshotKey` 不含图片状态分量、无
  主动失效 API、`_pageToImage` 的 onImageNeeded 传空回调 → 占位快照
  入库后永久复用；`_startResourceMonitoring` 就绪重发布后重预热仍命中
  缓存里的陈旧快照（闭环断裂）。
- **修复二（依赖旁表 + 失效重建）**：①`_snapshotPendingDeps` 旁表登记
  快照生成时未就绪的 href 集合（`_ensureSnapshotFor` 入库时计算）；②
  composer 监听 `imageReadyTick` → `_onImagesReady`：动画活跃时挂起
  （folding 纹理使用中禁 dispose——崩溃红线），复位点 `_resetState`
  drain；空闲时清除依赖已就绪的快照（先 remove 后 dispose）并重预热
  当前页；③`_snapshotFor` 防御式自愈：命中但旁表依赖已就绪 → 视为
  陈旧丢弃重生成（通知丢失也能自愈）。
- **教训**：①**"幂等短路丢弃回调"是多播缺失的通病**——单播归属"发起
  竞争的赢家"，任何先行的空回调路径都会吞掉后续真实回调；②**缓存键
  遗漏内容状态分量时，必须配主动失效通道**——仅靠键变化自然失效，
  状态转换（图片就绪）永远不会触发重建；③快照失效必须尊重纹理使用
  中禁 dispose 红线（挂起到复位点，对齐快照串行链/排队机制先例）。

**A29 详细说明（翻页手势接管，2026-09-07）**：

- **背景（真机日志实锤）**：快翻拖拽仅 30-150ms 而收尾动画 600-1100ms，
  动画在途期间新手势被排队互斥整段拒绝（A19/A24 防动画消失的架构），
  观感「不跟手、松手后等一会才动画」；快速点击偶发「闪一下」（A29b：
  接管提交后 `_isActive` 未复位 → 发布重试被守卫挡掉 → pending 400ms
  超时 directFlip 无动画跳页）。
- **接管机制**：动画在途（非提交/定格窗口）+ 新手势 → `fastForward`
  快进到终点（翻页→1.0/回弹→0.0）→ 在途 animateTo 经 orCancel 返回
  false → `_runAuto` aborted 分支按接管标志转「立即提交」——提交输入
  在 fastForward 前捕获（`_commitPageTurn` 加可选参数），规避异步恢复
  期 `_turnDirection/_targetFrame` 被新手势覆写的竞态。
- **新手势启动**：registerPending 等发布重试（提交实测 10-90ms），不
  走旧帧门控——杜绝双重推进。A29b 修复：接管分支 `_isActive` 置 false
  （发布 postFrame 重试通过 `_onModelPublished` 守卫）+ 提交后主动
  `_retryPendingTurn` 双保险 + 回弹分支补重试 + end-during-pending
  提交窗口期重新登记（不用旧帧开新动画）。
- **教训**：①接管类功能必须审计「异步恢复期读到的共享字段是否已被
  覆写」——提交输入前置捕获是唯一安全姿势；②新增提交路径后，发布
  驱动的重试守卫链（_isActive/_pendingDirection）必须逐一对账。

**A30 详细说明（书内全文搜索，2026-09-07）**：

- **功能**：菜单「搜索」→ 关键词全书搜索 → 结果列表（章节+摘录，命中
  词高亮）→ 点击跳转命中位置（复用书签的章节+字符锚点机制，零新定位
  逻辑）。TXT/EPUB 统一体验。
- **架构（用户定案）**：①计算全在 Rust——单次异步 FFI `search_in_book`
  （flutter_rust_bridge 线程池），Dart 零逐章循环/文本处理，UI 线程零
  堵塞；②格式分派封装在 Rust 内部，SearchHit 契约统一；③复用既有内
  容引擎（preprocessor 替换规则/简繁、`blocks_to_layout_items` 同函数
  映射），bridge 薄封装。
- **锚点同源（正确性核心）**：TXT 锚点 = processed + 段落格式化后文本
  （与 layout_text 输入同源，搜索管线与展示管线 :843-874 严格同源）；
  EPUB 锚点 = IR 布局项字符流，字符累计与 `layout_items` 的 char_index
  同规则（Text=chars+1 段落 newline :803 / Table=Σ单元格段落(chars+1)
  :1828 / Image=0）——**对齐单测**（`search_in_book_{txt,epub}_anchor_
  alignment`）对每个命中 anchor 经 locate 断言落页含命中词，规则漂移
  即红。
- **高效性**：命中词集合 = 原词 + 双向简繁变体（一次扫描覆盖转换方向）；
  预算 200 命中/5s 扫描即停；逐章短锁；TXT 不回填 PREPROCESSED_CACHE
  （全书扫描不挤占 20 章 LRU 阅读窗口）；不走分页 API（零排版缓存污
  染）。原计划 EpubCleanedBook 章节预筛经查在路线2下退化（book.content
  置空），已改为预算内全章 IR 扫描。
- **教训**：①复用引擎产物前必须验证产物在当前管线下仍有效（路线2切
  换后 EpubCleanedBook 已退化）——「已物化」不等于「仍同源」；②跨语
  言锚点换算的规则必须以**对齐单测**锁死，而非人工推演。

**A30b 详细说明（EPUB 替换规则接入 + 搜索闪帧修复，2026-09-07 真机验证反馈）**：

- **问题一（EPUB 替换规则不生效）**：规则仅在 TXT 预处理路径生效
  （`ContentPreprocessor::process` 内），EPUB 结构化管线
  （`get_page_structured`→`process_structured_chapter`）设计上未接
  replace_rules（api.rs 旧注释自认「与展示一致」——展示本身就没规则）。
- **修复（块级应用）**：`StructuredParams` 增 `rules: Arc<Vec<ReplaceRule>>`
  + `rules_hash`；三 FFI 入口（get_page_structured /
  get_page_count_structured / prefetch_structured_chapter）加
  `replace_rules` 参数，`rules_hash` 入 `StructuredPageKey`（换规则即
  换键重算，Dart 页数缓存键经 layoutFingerprint 已含规则指纹无需改）。
  新增 `apply_replace_rules_to_blocks`：递归应用 Paragraph/Heading/
  List/Quote/Table 单元格（Image/Rule 跳过），经 `shared_tokio_runtime
  ().block_on` 调用（复用 `get_preprocessor_for_rules` 正则 LRU）；
  **规则先于段落格式化**（文本长度变化不得污染缩进注入）；文本变化的
  块清空 runs（StyledRun 字符区间基于原文，降级整块统一样式防错位绘
  制）。`search_epub_chapter` 同函数同时机应用——搜索/展示/锚点三方
  同源（红线保持）。语义差异：TXT 整章应用（跨行正则可命中），EPUB
  按块（跨段正则不命中，legado 规则以段内为主，可接受）。
- **问题二（搜索输入时内容闪现刷新）**：搜索对话框是唯一带输入框的对
  话框——TextField 弹软键盘 → Scaffold resizeToAvoidBottomInset 压缩
  body → LayoutBuilder 测得假尺寸变化 → onWindowResized 全章重排。
  真机日志实锤：键盘开屏动画 15+ 帧 = 15+ 次 window-resized → 15 次
  page.load.start（808→478 逐帧下滑），收起时反向再来一遍（808 的最
  终 commit 就是闪现来源）；且该设备上 viewInsets 与窗口压缩不同步，
  推断式守卫失效。
- **修复（显式冻结 + 防抖，用户定案「查找只是查找，只有点击结果才切
  换内容」）**：①搜索对话框 initState/dispose 接线
  `setViewportResizeFrozen`——冻结期间 onWindowResized 直接忽略（不更
  新尺寸、不作废 FrameSet、不重排），冻结瞬间丢弃在途防抖；②尺寸变
  化 200ms 防抖——动画期中间值被后到事件覆盖，动画结束只应用最终值
  一次；键盘收回时最终值==冻结前原值 → 天然零重排。冻结只拦视口尺
  寸处理，不拦页面加载（点击结果时对话框先 pop 再 jumpToSearchHit，
  时序正确）。诊断入口：`viewport.resize.frozen` 日志行。
- **问题三（跳转旧章闪帧）**：jumpToSearchHit/jumpToBookmark 先
  copyWith 切章再加载 → 加载期间显示旧章一帧 + FFI 返回二次重建。
- **修复（deferred commit）**：`_loadCurrentPage` 加 `targetChapterIndex`
  参数，目标章排版在 FFI 内完成，章节切换与页面在返回后一次性提交；
  状态守卫基准改为「请求发起时章节」（普通加载两者相等语义不变）。
- **测试**：`tests/epub_replace_rules.rs` 三红线——展示含规则后文本/
  换规则换缓存键重算（哈希不在键则第二次调用命中旧缓存必红）/搜索
  「规则后文本」命中且锚点落页含命中词。
- **教训**：①「展示路径不应用 X」的旧注释会固化为隐式契约，新功能接
  X 时搜索侧若同步跟进反而固化错误——对齐的基准是**正确口径**而非现
  状；②递归 async fn 必须显式 Box::pin（块流递归深度浅，开销可忽略）；
  ③键盘动画引发的视口"假 resize"必须**显式冻结**（对话框生命周期钩子）
  而非 viewInsets 推断——不同设备 insets 与窗口压缩时序不同步，推断式
  守卫不可靠；凡"后台必须纹丝不动"的语义，冻结开关挂在语义主体（对
  话框）的生命周期上，而不是靠测量信号反推。

**所有 A1–A30b + APK 全线落地**。下一阶段候选：
- P1：书源引擎接线（在线书城 UI——Rust 规则引擎+网络层已完备，Dart BookSourceService 已封装，UI 零调用）
- P2：TTS 朗读（渲染高亮基建已有，缺语音引擎+分句调度）
- P2：笔记/划线持久化（ReaderSelection 渲染模型已有，缺表结构与 UI）
- P3：书架管理完善（分组/排序/书架内搜索/重命名）
- P2：智能分段规则继续扩展（A22 已落地诗歌/引用/对话；候选：竖排诗、信件体）
- P4：首字下沉、竖排（远期）
