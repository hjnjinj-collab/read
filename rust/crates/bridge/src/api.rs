use crate::{BookHandle, ChapterInfo, PageInfo, BOOKS};
use crate::diagnostics::{diagnose_file_encoding, diagnose_chapter_content};
use book_parser::{BookParser, BookFormat, ContentCleaner, ConvertMode, ParagraphMode, CleanOptions};
use layout_engine::{LayoutConfig, LayoutEngine, EdgeInsets, FontManager, AdvancedGlyphCache, Page};
use reader_core::{
    ContentPreprocessor, ProcessOptions, ChineseConvertType, ReplaceRule, RuleType,
    PaginationCache, CacheKey, CachedChapterPages,
    CACHE_SCHEMA_REVISION, LAYOUT_REVISION,
    ReadSessionManager,
    PreloadExecutor, PreloadExecutorConfig,
    PreloadTask, DefaultPreloadStrategy, PreloadStrategy,
};
use std::sync::{Arc, Mutex, OnceLock};
use once_cell::sync::Lazy;
use std::time::{Instant, SystemTime};
use crate::{
    FfiBookSource, FfiSearchBookItem, FfiBookInfo,
    FfiChapterInfo, FfiChapterContent, BOOK_SOURCE_ENGINE
};

// Global font manager
static FONT_MANAGER: Lazy<Arc<Mutex<FontManager>>> = Lazy::new(|| {
    // 启动时自动加载内置 Noto Sans CJK SC：开箱即有 CJK 字体可用，
    // 不依赖宿主系统字体（Windows/macOS/Linux/Android/iOS 行为一致）。
    // 用户后续可用 load_font_file/load_font_data 注入新字体并 set_default_font 切换。
    Arc::new(Mutex::new(FontManager::new_with_embedded_default()))
});

// M8-P4：跨章共享字形缓存——所有章节排版复用同一 GlyphCache，
// 消除每章新建 LayoutEngine → 新建 GlyphCache 的冷启动开销。
// GlyphCache 内部键含 font_name + font_size_bits，不同字体/字号自然隔离；
// load_font_file/load_font_data 会 clear() 防容量污染。
//
// M9.4-F：升级为 AdvancedGlyphCache，首次取用时预热 GB2312 一级常用字
// （一次 batch_measure 单锁批量测量，约 <50ms）。预热键与热路径对齐：
// - Dart 端 getPageProcessed/getPageCountProcessed 的 fontName 默认参数是
//   'default'（book_service.dart），reader_provider 全部调用点未覆盖
//   → 热路径 GlyphKey.font_name 恒为 "default"
// - Dart 端默认阅读字号 18.0 = LayoutConfig::default().font_size
// 因此用 LayoutConfig::default() 的 (font_name, font_size) 预热可全量命中。
// 用户改字号/触发字体 clear() 后本次预热条目失效属预期——只优化默认启动态。
// 注：原 plan 设想在 BookService::init() 触发，但 Rust 侧无该入口
// （Dart 的 BookService.init 仅调 RustLib.init），故收敛到首次取用时机。
static SHARED_GLYPH_CACHE: Lazy<Mutex<AdvancedGlyphCache>> = Lazy::new(|| {
    let cache = AdvancedGlyphCache::with_capacity(10_000, FONT_MANAGER.clone());
    let cfg = LayoutConfig::default();
    cache.prewarm(&cfg.font_name, cfg.font_size);
    log::info!(
        "AdvancedGlyphCache prewarmed: {} glyphs (font={}, size={})",
        cache.stats().len,
        cfg.font_name,
        cfg.font_size
    );
    Mutex::new(cache)
});

// Global content preprocessor（无替换规则的默认实例）
static CONTENT_PREPROCESSOR: Lazy<Arc<ContentPreprocessor>> = Lazy::new(|| {
    Arc::new(ContentPreprocessor::empty())
});

// 按规则集哈希缓存的预处理器（规则不变则复用编译结果，避免重复编译正则）
static RULES_PREPROCESSORS: Lazy<Mutex<std::collections::HashMap<u64, Arc<ContentPreprocessor>>>> =
    Lazy::new(|| Mutex::new(std::collections::HashMap::new()));

// Global pagination cache (缓存10个章节的分页结果)
static PAGINATION_CACHE: Lazy<Arc<Mutex<PaginationCache>>> = Lazy::new(|| {
    Arc::new(Mutex::new(PaginationCache::new(10)))
});

// M9.5-G：预处理结果缓存——reader_core::PreprocessedCache 首次接入生产路径。
// process_and_layout_chapter_inner 在预处理前查缓存，命中则连「取原文+六阶段
// 预处理流水线」一并跳过；miss 正常处理后回填。容量 20 章，进程内存不落盘。
// 键=book_id+章节+预处理选项 hash（para_format_hash 不参与预处理输出、置 0，
// 段落格式化在缓存之后执行）。净化选项（ContentCleaningOptions）不在键中，
// 但 set_content_cleaning_options 重建章节偏移时同步 clear_book 失效，
// 不产生陈旧命中。内部 tokio Mutex 自同步，无需外层 std Mutex。
static PREPROCESSED_CACHE: Lazy<reader_core::cache::PreprocessedCache> =
    Lazy::new(|| reader_core::cache::PreprocessedCache::new());

// M10-B：进程级 Skia 测量缓存。详见 layout_engine::MeasureCache。
// Dart 端 MeasureTextService 通过 feed_text_widths 批量注入；
// layout 二分命中后用 Skia 真实宽度做断行决策，避免 ttf-parser hmtx 与
// Skia/HarfBuzz 整形后宽度不一致导致的左右边距不对称。
static MEASURE_CACHE: Lazy<Arc<layout_engine::MeasureCache>> =
    Lazy::new(|| Arc::new(layout_engine::MeasureCache::with_default_capacity()));

/// M10-B：构造 LayoutEngine 并注入共享 MeasureCache。
///
/// 所有 FFI 入口（layout_chapter / get_page / get_page_count / get_page_processed /
/// get_page_count_processed / get_page_structured / get_page_count_structured）
/// 走此 helper，确保 Dart 端 Dart MeasureTextService 注入的 Skia 实测宽度对所有
/// 排版入口即时可见。
fn build_layout_engine(config: LayoutConfig, font_manager: FontManager) -> LayoutEngine {
    // P4：同时注入 SHARED_GLYPH_CACHE 共享克隆——此前此 helper 仅注入
    // measure cache，structured（EPUB）路径每章全新 GlyphCache 全冷
    // （首排逐字 ttf 查询）。glyph_cache() 为 O(1) Arc bump 共享克隆，
    // prewarm 字形对全部排版入口直接可见。
    let glyph_cache = SHARED_GLYPH_CACHE.lock().unwrap().glyph_cache();
    LayoutEngine::with_cache_and_measure(config, font_manager, glyph_cache, MEASURE_CACHE.clone())
}

// M9.5-G helper: invalidate preprocessed cache. Some(book_id) = per-book
// (update_book_cleaning / release_book / per-book clear), None = clear all.
fn invalidate_preprocessed_cache(book_id: Option<&str>) {
    match book_id {
        Some(id) => shared_tokio_runtime().block_on(PREPROCESSED_CACHE.clear_book(id)),
        None => shared_tokio_runtime().block_on(PREPROCESSED_CACHE.clear()),
    }
}

/// 最近一次 TXT 前台排版参数快照（book_id + 完整处理选项）。
/// 预加载 load_fn 据此以同参重建相邻章分页写入 PAGINATION_CACHE——
/// 保证预取缓存键与前台键逐字节一致（含 f32 bits 口径）
#[derive(Clone)]
struct TxtLayoutSnapshot {
    config: LayoutConfig,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    replace_rules: Vec<FfiReplaceRule>,
    segment_rules: Vec<FfiSegmentRule>,
    para_format_hash: u64,
}

static LAST_TXT_LAYOUT_SNAPSHOT: Mutex<Option<(String, TxtLayoutSnapshot)>> =
    Mutex::new(None);

/// 记录最近一次 TXT 前台排版参数（get_page_processed / get_page_count 成功路径调用）
fn remember_txt_layout(
    book_id: &str,
    config: &LayoutConfig,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    replace_rules: &[FfiReplaceRule],
    segment_rules: &[FfiSegmentRule],
    para_format_hash: u64,
) {
    *LAST_TXT_LAYOUT_SNAPSHOT.lock().unwrap() = Some((
        book_id.to_string(),
        TxtLayoutSnapshot {
            config: config.clone(),
            remove_duplicate_title,
            re_segment,
            chinese_convert,
            replace_rules: replace_rules.to_vec(),
            segment_rules: segment_rules.to_vec(),
            para_format_hash,
        },
    ));
}

/// 进程级共享 Tokio 运行时（前台预处理与预加载共用，消除 per-call 新建）
static SHARED_TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn shared_tokio_runtime() -> &'static tokio::runtime::Runtime {
    SHARED_TOKIO_RUNTIME.get_or_init(|| {
        tokio::runtime::Runtime::new().expect("Failed to create shared Tokio runtime")
    })
}

/// TXT 相邻章预热：按最近一次前台排版快照重建目标章分页并写入
/// PAGINATION_CACHE（缓存命中即零开销，副作用即目的）。
/// 无快照或书不匹配时跳过返回 false。
///
/// M9.3：走 inner 变体（allow_preload_trigger=false）——预热自身严禁
/// 再触发预热，否则形成自激级联冲刷 LRU、前台翻页退化为同步全章重排。
fn preload_txt_warm(book_id: &str, chapter_index: usize) -> anyhow::Result<bool> {
    let snap = LAST_TXT_LAYOUT_SNAPSHOT.lock().unwrap().clone();
    let Some((snap_book, snap)) = snap else {
        return Ok(false);
    };
    if snap_book != book_id {
        return Ok(false);
    }
    process_and_layout_chapter_inner(
        book_id,
        chapter_index,
        &snap.config,
        snap.remove_duplicate_title,
        snap.re_segment,
        snap.chinese_convert,
        &snap.replace_rules,
        &snap.segment_rules,
        snap.para_format_hash,
        /*allow_preload_trigger=*/ false,
    )?;
    Ok(true)
}

/// 结构化路径分页结果缓存（EPUB；键含排版配置，容量 10 章）
///
/// 阶段2优化：EPUB 分页缓存 TTL 包装（带时间戳）
#[derive(Clone)]
struct StructuredCacheEntry {
    pages: Arc<Vec<crate::PageInfo>>,
    created_at: SystemTime,
}

impl StructuredCacheEntry {
    fn new(pages: Arc<Vec<crate::PageInfo>>) -> Self {
        Self {
            pages,
            created_at: SystemTime::now(),
        }
    }
    
    fn is_expired(&self, ttl_secs: u64) -> bool {
        if let Ok(elapsed) = self.created_at.elapsed() {
            elapsed.as_secs() > ttl_secs
        } else {
            // 时钟回退异常 → 视为过期
            true
        }
    }
}

/// 与 PAGINATION_CACHE 分离的原因：后者存 layout_engine::Page（无背景
/// 字段且属 reader_core 类型）；结构化路径交付 PageInfo（含 background）
/// 且不经过文本预处理，生命周期独立。
///
/// M8-P4：值类型从 `Vec<PageInfo>` 改为 `Arc<Vec<PageInfo>>`，
/// 命中时 Arc::clone 后锁外取单页，免整章克隆。
///
/// 阶段2优化：值类型改为 `StructuredCacheEntry`（带 TTL 时间戳），
/// TTL = 900秒（与 TXT 缓存对齐）。
static STRUCTURED_PAGINATION_CACHE: Lazy<Mutex<lru::LruCache<StructuredPageKey, StructuredCacheEntry>>> =
    Lazy::new(|| {
        Mutex::new(lru::LruCache::new(
            std::num::NonZeroUsize::new(10).unwrap(),
        ))
    });

/// EPUB 分页缓存 TTL（秒），与 TXT PAGINATION_CACHE 对齐
const STRUCTURED_CACHE_TTL_SECS: u64 = 900;

/// 结构化分页缓存键
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct StructuredPageKey {
    cache_schema_revision: u32,
    layout_revision: u32,
    book_id: String,
    chapter_index: usize,
    width: u32,
    height: u32,
    font_size: u32,
    line_height: u32,
    padding: (u32, u32, u32, u32),
    font_name: String,
    /// 阅读级简繁转换模式（0=无 1=简→繁 2=繁→简）；换模式即换键，
    /// LRU 自然淘汰旧缓存
    convert_mode: u8,
    page_fill_threshold_bits: u32,
    /// 是否显示本章说（缓存键：不同设置独立缓存）
    show_comments: bool,
    /// M9 段落格式化设置哈希（缩进/重分段/间距变更即换键）
    para_format_hash: u64,
    /// A30c：去重标题开关（变更即换键自然重算）
    remove_duplicate_title: bool,
    /// A30b：用户替换规则集哈希（规则变更即换键自然重算）
    rules_hash: u64,
}

impl StructuredPageKey {
    #[allow(clippy::too_many_arguments)]
    fn new(
        book_id: &str,
        chapter_index: usize,
        config: &LayoutConfig,
        convert_mode: u8,
        para_format_hash: u64,
        remove_duplicate_title: bool,
        rules_hash: u64,
    ) -> Self {
        Self {
            cache_schema_revision: CACHE_SCHEMA_REVISION,
            layout_revision: LAYOUT_REVISION,
            book_id: book_id.to_string(),
            chapter_index,
            width: config.width.to_bits(),
            height: config.height.to_bits(),
            font_size: config.font_size.to_bits(),
            line_height: config.line_height_multiplier.to_bits(),
            padding: (
                config.padding.left.to_bits(),
                config.padding.top.to_bits(),
                config.padding.right.to_bits(),
                config.padding.bottom.to_bits(),
            ),
            font_name: config.font_name.clone(),
            convert_mode,
            page_fill_threshold_bits: config.page_fill_threshold.to_bits(),
            show_comments: config.show_comments,
            para_format_hash,
            remove_duplicate_title,
            rules_hash,
        }
    }
}

// Global content cleaning options
static CONTENT_CLEANING_OPTIONS: Lazy<Arc<Mutex<Option<ContentCleaningOptions>>>> = Lazy::new(|| {
    Arc::new(Mutex::new(None))
});

/// M9：全局段落格式化设置
static PARAGRAPH_FORMAT_SETTINGS: Lazy<Mutex<reader_core::ParagraphFormatSettings>> =
    Lazy::new(|| Mutex::new(reader_core::ParagraphFormatSettings::default()));

/// M9.2：段距有效值 = 基准（字号×0.8）× 用户倍率。
/// 仅活跃 FFI 入口（get_page_processed / get_page_count_processed /
/// structured_layout_config）消费；遗留入口保持原值（App 未调用）。
fn effective_paragraph_spacing(font_size: f32) -> f32 {
    let multiplier = PARAGRAPH_FORMAT_SETTINGS
        .lock()
        .unwrap()
        .paragraph_spacing_multiplier;
    font_size * 0.8 * multiplier
}

/// P2：两端对齐全局开关（PARAGRAPH_FORMAT_SETTINGS.justify 单源）。
/// 全部 LayoutConfig 构造点统一消费，遗留 FFI 入口同样跟随（行为一致无害）。
fn effective_justify() -> bool {
    PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().justify
}

/// P3：行尾标点压缩悬挂开关（单源同上）
fn effective_punct_compress() -> bool {
    PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().punctuation_compress
}

/// P4：字体变更后按新字体重建 GB2312 预热。
///
/// 键 = (font_name, 默认字号)——必须与热路径 LayoutConfig.font_name 一致，
/// 否则预热条目对热路径不可见（历史 bug：SHARED Lazy 预热键 "default"
/// vs 热路径 Dart 传入的 "ReaderSerif"）。prewarm 内部按 last_prewarm
/// 去重，load_font_data + set_default_font 连续调用不重复预热开销。
/// 锁序：调用点必须已释放 FONT_MANAGER（prewarm 内部会取 FONT_MANAGER）。
fn prewarm_shared_glyph(font_name: &str) {
    let size = LayoutConfig::default().font_size;
    SHARED_GLYPH_CACHE.lock().unwrap().prewarm(font_name, size);
}

/// Load font from file path（软失败：找不到文件/读失败时只 log，不抛错）
///
/// 行为：写入 `tracing` 日志 + 静默返回 Ok，让上层 Dart 代码不因字体
/// 加载失败而崩溃。FontManager 内置 Noto Sans CJK SC 默认字体，
/// 即使所有 load_font_file 失败，仍有可用字体兜底。
pub fn load_font_file(font_name: String, font_path: String) -> anyhow::Result<()> {
    // M9.4-F：必须先释放 FONT_MANAGER 锁再取 SHARED_GLYPH_CACHE 锁——
    // SHARED 的 Lazy 初始化会 prewarm（内部 lock FONT_MANAGER），
    // 持 FONT_MANAGER 锁的同时取 SHARED 锁构成 ABBA 死锁。
    // 锁序约定：只允许 FONT_MANAGER ← SHARED 方向嵌套，禁止反向。
    let loaded = {
        let mut manager = FONT_MANAGER.lock().unwrap();
        manager.load_font_from_file(font_name.clone(), &font_path)
    };
    match loaded {
        Ok(()) => {
            // M8-P4：字体变更清共享字形缓存，防旧字体字形混入
            // P4：清后按新字体重建预热（键对齐热路径）
            {
                let shared = SHARED_GLYPH_CACHE.lock().unwrap();
                shared.clear();
                shared.prewarm(&font_name, LayoutConfig::default().font_size);
            }
            Ok(())
        }
        Err(e) => {
            log::warn!("load_font_file failed ({}): {}", font_path, e);
            Ok(()) // 软失败
        }
    }
}

/// Load font from byte array
pub fn load_font_data(font_name: String, font_data: Vec<u8>) -> anyhow::Result<()> {
    // M9.4-F：锁序约定同 load_font_file——先释放 FONT_MANAGER 再取 SHARED
    let result = {
        let mut manager = FONT_MANAGER.lock().unwrap();
        manager.load_font(font_name.clone(), font_data)
    };
    result?;
    // M8-P4：字体变更清共享字形缓存
    // P4：清后按新字体重建预热（键对齐热路径）
    {
        let shared = SHARED_GLYPH_CACHE.lock().unwrap();
        shared.clear();
        shared.prewarm(&font_name, LayoutConfig::default().font_size);
    }
    Ok(())
}

/// Get loaded font count
pub fn get_font_count() -> usize {
    let manager = FONT_MANAGER.lock().unwrap();
    manager.font_count()
}

/// 切换默认字体（用户选字体后调用）
///
/// name 必须是已 load_font_* 加载过的字体名，否则抛错。
/// 切换后清共享字形缓存防旧字体字形混入；同时清共享 MeasureCache
/// （旧字体的 Skia 实测宽度对当前字体失效）。
pub fn set_default_font(font_name: String) -> anyhow::Result<()> {
    // M9.4-F：锁序约定同 load_font_file——先释放 FONT_MANAGER 再取 SHARED
    let result = {
        let mut manager = FONT_MANAGER.lock().unwrap();
        manager.set_default_font(&font_name)
    };
    result?;
    // P4：清后按新默认字体重建预热（键对齐热路径；与 load_font_data 同名
    // 时由 last_prewarm 去重，不重复预热开销）
    {
        let shared = SHARED_GLYPH_CACHE.lock().unwrap();
        shared.clear();
        shared.prewarm(&font_name, LayoutConfig::default().font_size);
    }
    // M10-B：字体切换时清测量缓存（Dart 端的 Skia 测宽只对当前字体有效）
    MEASURE_CACHE.clear();
    Ok(())
}

/// 获取当前默认字体名
pub fn get_default_font_name() -> String {
    let manager = FONT_MANAGER.lock().unwrap();
    manager
        .default_font_name()
        .unwrap_or("embedded_default")
        .to_string()
}

// =========================================================================
// M10-B — Skia 测量缓存 FFI 表面
// =========================================================================
//
// 解决左右边距不对称的根因：Rust 端 layout 期间用 Dart TextPainter 真实测量宽度
// 替代 ttf-parser hmtx 估算。Dart 端 MeasureTextService 通过此组 FFI 注入测量结果。
//
// 数据流：
// 1. Dart MeasureTextService 用 TextPainter 测一批子串宽度
// 2. Dart 调 feed_text_widths(widths) 批量写入 MEASURE_CACHE
// 3. 后续 layout 调用命中 MeasureCache 时用 Skia 真实宽度做二分搜索
// 4. cache miss 回退 ttf-parser 估算（与原版等价，不会破坏任何已有路径）

/// M10-B：单条测量结果（font_name + font_size + text + width_px）
///
/// text 必须与 Rust layout 期间实际查询的子串**逐字节一致**——内部 key 用
/// SipHash(text) 而非 text 本身，避免 key 长度爆炸。
#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct FfiTextWidth {
    pub font_name: String,
    pub font_size: f32,
    pub text: String,
    pub width: f32,
}

/// M10-B：批量写入 Skia 实测宽度到 MeasureCache。
///
/// 典型调用：Dart MeasureTextService 测完本章常用子串后调一次（数百~数千条）。
/// 内部 LRU 自动淘汰，单章 ≤ 50k 条足够覆盖。重复写入覆盖（写入永远是最新值）。
pub fn feed_text_widths(widths: Vec<FfiTextWidth>) -> usize {
    let entries: Vec<(String, f32, String, f32)> = widths
        .into_iter()
        .map(|w| (w.font_name, w.font_size, w.text, w.width))
        .collect();
    let n = entries.len();
    MEASURE_CACHE.put_many(&entries);
    n
}

/// M10-B：清空 MeasureCache（Dart 端主动失效时使用，例如 settings 变更或字体切换兜底）
pub fn clear_measure_cache() -> usize {
    let n = MEASURE_CACHE.len();
    MEASURE_CACHE.clear();
    n
}

/// M10-B：查询 MeasureCache 状态（诊断用：当前条目数 / 容量）
pub fn get_measure_cache_stats() -> String {
    format!(
        "{{\"len\":{},\"capacity\":{}}}",
        MEASURE_CACHE.len(),
        layout_engine::measure_cache::MEASURE_CACHE_CAPACITY,
    )
}

/// Parse TXT file and return book ID
pub fn parse_txt_file(file_path: String, book_name: Option<String>) -> anyhow::Result<String> {
    parse_txt_file_inner(file_path, book_name, None)
}

/// Parse TXT file asynchronously（在 tokio 工作线程执行，不阻塞 UI）
///
/// 大文件解析耗时随体积线性增长，同步版本会阻塞 Dart isolate；
/// 此版本通过 spawn_blocking 把解析移到线程池。
///
/// `cleaning_options` 非空时在导入阶段启用结构净化
/// （去 HTML/去广告/空白规整/智能分段），并在此文本上完成 JS 章节识别。
pub async fn parse_txt_file_async(
    file_path: String,
    book_name: Option<String>,
    cleaning_options: Option<ContentCleaningOptions>,
) -> anyhow::Result<String> {
    tokio::task::spawn_blocking(move || parse_txt_file_inner(file_path, book_name, cleaning_options))
        .await
        .map_err(|e| anyhow::anyhow!("解析任务被取消: {}", e))?
}

/// 解析书籍的统一实现（导入唯一入口，经加载工厂做格式判定）
///
/// TXT：具体解析器 + 净化缓存机制；
/// EPUB：逐章提取并物化为与 TXT 同构的 Book（后续取内容走
/// 「切片 + 全局净化」分支），章节偏移同样与内容同源。
fn parse_txt_file_inner(
    file_path: String,
    book_name: Option<String>,
    cleaning_options: Option<ContentCleaningOptions>,
) -> anyhow::Result<String> {
    use book_parser::{BookFormat, EpubParser};

    // 工厂格式判定
    let path = std::path::Path::new(&file_path);
    let format = book_parser::loader::BookSourceLoader::detect_format(path)?;

    let handle = match format {
        BookFormat::Txt => {
            let mut parser = book_parser::TxtParser::from_file(path)?;

            // 导入级结构净化：净化器就位后，首次阅读的 ensure 会基于净化文本建缓存，
            // 章节边界也在净化后文本上重新识别（compute_cleaned_offsets）
            if let Some(opts) = &cleaning_options {
                parser.set_content_cleaner(build_cleaner_from_options(opts));
            }

            // 解析元数据（触发章节识别）
            let _metadata = parser.parse()?;
            let book = parser.to_book(book_name)?;
            BookHandle {
                book,
                parser: Some(Box::new(parser)),
                source_path: Some(file_path.clone()),
                epub_cleaned: None,
                structured: None,
            }
        }
        BookFormat::Epub => {
            let mut parser = EpubParser::from_file(path)
                .map_err(|e| anyhow::anyhow!("EPUB 解析失败: {}", e))?;
            let metadata = parser.parse()?;
            let list = parser.get_chapter_list()?;

            // 路线2 主路径：不再物化全文 Book（72MB 级书省下等量内存）。
            // 章节表保留（标题/层级供目录页），正文经
            // get_page_structured 按章提取 + 分页；book.content 置空，
            // 旧切片 API 对 EPUB 不再可用。
            let chapters = list
                .iter()
                .map(|c| book_parser::Chapter {
                    title: c.title.clone(),
                    start_pos: 0,
                    end_pos: 0,
                    level: c.level,
                    parent_index: c.parent_index,
                })
                .collect();

            BookHandle {
                book: crate::Book {
                    title: book_name.unwrap_or(metadata.title),
                    content: String::new(),
                    chapters,
                },
                parser: None,
                source_path: Some(file_path.clone()),
                epub_cleaned: None,
                structured: Some(crate::StructuredEpubHandle { parser }),
            }
        }
        other => anyhow::bail!(
            "暂不支持该格式导入: {}（支持 TXT / EPUB）",
            other.extension()
        ),
    };

    // Generate unique book ID
    let book_id = format!("book_{}", uuid::Uuid::new_v4());

    // Store book and parser
    let mut books = BOOKS.write().unwrap();
    books.insert(book_id.clone(), handle);

    Ok(book_id)
}

/// 内容净化选项
#[derive(Debug, Clone)]
pub struct ContentCleaningOptions {
    /// 繁简转换模式: "none", "t2s"(繁转简), "s2t"(简转繁)
    pub convert_mode: String,
    /// 段落处理模式: "none", "smart"(智能), "force"(强制)
    pub paragraph_mode: String,
    /// 是否清理 HTML 标签
    pub clean_html: bool,
    /// 是否删除广告
    pub remove_ads: bool,
}

impl Default for ContentCleaningOptions {
    fn default() -> Self {
        Self {
            convert_mode: "none".to_string(),
            paragraph_mode: "smart".to_string(),
            clean_html: true,
            remove_ads: true,
        }
    }
}

/// 设置全局内容净化选项
pub fn set_content_cleaning_options(options: ContentCleaningOptions) -> anyhow::Result<()> {
    let mut global_options = CONTENT_CLEANING_OPTIONS.lock().unwrap();
    *global_options = Some(options);
    Ok(())
}

/// 清除内容净化选项（恢复默认：不净化）
pub fn clear_content_cleaning_options() -> anyhow::Result<()> {
    let mut global_options = CONTENT_CLEANING_OPTIONS.lock().unwrap();
    *global_options = None;
    Ok(())
}

/// M9：设置全局段落格式化参数
///
/// Dart 侧调用：用户在设置 UI 修改缩进/重分段模式/切分阈值时，
/// 通过此函数同步 Rust 全局设置，随后 FFI 分页调用自动应用。
/// 阈值钳制在 [20, 2000]，防病态输入（过小退化为逐句切分、过大等同不切）。
pub fn set_paragraph_format_settings(
    enable_indent: bool,
    indent_size_chars: u8,
    paragraph_spacing_multiplier: f32,
    re_paragraph_mode: u8,
    smart_split_threshold: u32,
    aggressive_split_threshold: u32,
    justify: bool,
    punctuation_compress: bool,
) -> anyhow::Result<()> {
    let mut settings = PARAGRAPH_FORMAT_SETTINGS.lock().unwrap();
    settings.enable_indent = enable_indent;
    settings.indent_size_chars = indent_size_chars;
    settings.paragraph_spacing_multiplier = paragraph_spacing_multiplier;
    settings.re_paragraph_mode = reader_core::ReParagraphMode::from_u8(re_paragraph_mode);
    settings.smart_split_threshold = smart_split_threshold.clamp(20, 2000) as usize;
    settings.aggressive_split_threshold = aggressive_split_threshold.clamp(20, 2000) as usize;
    settings.justify = justify;
    settings.punctuation_compress = punctuation_compress;
    Ok(())
}

/// 运行中更新已打开书籍的净化设置（即时生效）
///
/// 更新 parser 的净化器并清空该书分页缓存；
/// 净化缓存由读取路径按 config_hash 检测变更后自动重建。
pub fn update_book_cleaning(
    book_id: String,
    options: ContentCleaningOptions,
) -> anyhow::Result<()> {
    // 同步全局选项（供非 parser 路径使用）
    {
        let mut global_options = CONTENT_CLEANING_OPTIONS.lock().unwrap();
        *global_options = Some(options.clone());
    }

    let cleaner = build_cleaner_from_options(&options);
    {
        let mut books = BOOKS.write().unwrap();
        let handle = books.get_mut(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        if let Some(ref mut parser) = handle.parser {
            parser.set_content_cleaner(cleaner);
        }
    }

    // 章节偏移可能随重建变化，分页缓存全部失效
    PAGINATION_CACHE.lock().unwrap().clear_book(&book_id);
    clear_structured_pagination_cache_for_book(&book_id);
    invalidate_preprocessed_cache(Some(book_id.as_str()));
    Ok(())
}

/// 清除指定书籍的结构化分页缓存。
fn clear_structured_pagination_cache_for_book(book_id: &str) {
    let mut structured = STRUCTURED_PAGINATION_CACHE.lock().unwrap();
    let stale: Vec<StructuredPageKey> = structured
        .iter()
        .filter(|(key, _)| key.book_id == book_id)
        .map(|(key, _)| key.clone())
        .collect();
    for key in stale {
        structured.pop(&key);
    }
}

/// FFI 替换规则（用户自定义净化/替换规则）
///
/// `rule_type`: 0=字符串直替, 1=正则, 2=JS 脚本（pattern 承载脚本，
/// 以全局 `chapterContent` 为输入、返回替换后全文，legado 风格）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiReplaceRule {
    pub pattern: String,
    pub replacement: String,
    pub rule_type: u8,
    pub enabled: bool,
}

impl From<FfiReplaceRule> for ReplaceRule {
    fn from(r: FfiReplaceRule) -> Self {
        ReplaceRule {
            pattern: r.pattern,
            replacement: r.replacement,
            rule_type: match r.rule_type {
                1 => RuleType::Regex,
                2 => RuleType::Js,
                _ => RuleType::String,
            },
            timeout_ms: 1000,
            enabled: r.enabled,
        }
    }
}

/// A35-L2: FFI 传入的分段规则（Dart → Rust）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiSegmentRule {
    pub id: String,
    pub pattern: String,
    pub action: u8,  // 0=ForceBreakAfter, 1=ForceBreakBefore, 2=KeepIndependent, 3=MergeWithPrev
    pub enabled: bool,
    pub is_builtin: bool,
    pub is_regex: bool,
}

impl From<&FfiSegmentRule> for reader_core::SegmentRule {
    fn from(r: &FfiSegmentRule) -> Self {
        reader_core::SegmentRule {
            id: r.id.clone(),
            kind: if r.is_regex { reader_core::SegmentRuleKind::Regex } else { reader_core::SegmentRuleKind::Builtin },
            pattern: r.pattern.clone(),
            action: match r.action {
                0 => reader_core::SegmentAction::ForceBreakAfter,
                1 => reader_core::SegmentAction::ForceBreakBefore,
                2 => reader_core::SegmentAction::KeepIndependent,
                _ => reader_core::SegmentAction::MergeWithPrev,
            },
            enabled: r.enabled,
            builtin: r.is_builtin,
        }
    }
}

/// 获取（或构建）与替换规则集绑定的预处理器
///
/// 规则不变则复用实例（内部正则 LRU 持续生效）；规则变更才重建。
fn get_preprocessor_for_rules(rules: &[ReplaceRule]) -> Arc<ContentPreprocessor> {
    if rules.is_empty() {
        return CONTENT_PREPROCESSOR.clone();
    }
    let hash = CacheKey::hash_replace_rules(rules);
    let mut map = RULES_PREPROCESSORS.lock().unwrap();
    if map.len() > 8 {
        // 防止无限增长：规则集通常稳定，清空后按需重建
        map.clear();
    }
    map.entry(hash)
        .or_insert_with(|| Arc::new(ContentPreprocessor::new(rules.to_vec())))
        .clone()
}

/// 在已排版页面中定位包含指定章内字符偏移的页（用于进度保持）
///
/// 页面按 start_char_index 升序；返回最后一个 start <= offset 的页。
fn locate_page_for_offset(pages: &[Page], char_offset: usize) -> usize {
    if pages.is_empty() {
        return 0;
    }
    match pages.binary_search_by(|p| p.start_char_index.cmp(&char_offset)) {
        Ok(i) => i,
        Err(ins) => ins.saturating_sub(1),
    }
}

/// A30d：批量定位笔记锚点（避免逐条 FFI 开销）
///
/// 给定章节内的多个字符偏移，返回对应的页面索引数组。
///
/// # 参数
/// - `book_id`: 书籍 ID
/// - `chapter_index`: 章节索引
/// - `offsets`: 字符偏移数组（章节内，从 0 开始）
/// - 其他分页参数：与 `get_page_count` 一致
///
/// # 返回
/// - `Vec<usize>`：每个 offset 对应的页面索引（0-based）
pub fn batch_locate_notes(
    book_id: String,
    chapter_index: usize,
    offsets: Vec<usize>,
    // 分页参数（与 get_page_count 一致）
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    chinese_convert: u8,
    page_fill_threshold: f32,
    show_comments: bool,
    remove_duplicate_title: bool,
    replace_rules: Vec<FfiReplaceRule>,
) -> anyhow::Result<Vec<usize>> {
    // 参数校验
    if offsets.is_empty() {
        return Ok(vec![]);
    }

    // 构造分页参数（复用 get_page_count 的逻辑）
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name: font_name.clone(),
        letter_spacing: 0.0,
        paragraph_spacing: effective_paragraph_spacing(font_size),
        page_fill_threshold,
        show_comments,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    // 获取书籍（只探测格式，**不得**在持锁期间调用会再取 BOOKS 的 API——
    // RwLock 非可重入，否则 EPUB 批量定位死锁并拖死后续 parse/release）
    let is_structured = {
        let books = BOOKS.read().map_err(|e| anyhow::anyhow!("锁失败: {}", e))?;
        let handle = books
            .get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("书籍未找到: {}", book_id))?;
        handle.structured.is_some()
    };

    // 分路径（EPUB 用结构化路径，TXT 用传统路径）
    if is_structured {
        // EPUB 路径：获取结构化分页并批量定位
        let page_count = get_page_count_structured(
            book_id.clone(),
            chapter_index,
            width,
            height,
            font_size,
            line_height_multiplier,
            padding_left,
            padding_top,
            padding_right,
            padding_bottom,
            font_name.clone(),
            chinese_convert,
            page_fill_threshold,
            show_comments,
            /* para_format_hash= */ 0,
            remove_duplicate_title,
            replace_rules.clone(),
        )?;

        // 构建页面起始偏移数组用于定位
        let mut page_starts: Vec<usize> = Vec::with_capacity(page_count);
        for page_idx in 0..page_count {
            let page = get_page_structured(
                book_id.clone(),
                chapter_index,
                page_idx,
                width,
                height,
                font_size,
                line_height_multiplier,
                padding_left,
                padding_top,
                padding_right,
                padding_bottom,
                font_name.clone(),
                /* anchor_char_offset= */ None,
                chinese_convert,
                page_fill_threshold,
                show_comments,
                /* para_format_hash= */ 0,
                remove_duplicate_title,
                replace_rules.clone(),
            )?;
            page_starts.push(page.start_char_index);
        }

        // 批量定位（复用 locate_page_for_offset 逻辑）
        Ok(offsets
            .into_iter()
            .map(|offset| {
                match page_starts.binary_search(&offset) {
                    Ok(i) => i,
                    Err(ins) => ins.saturating_sub(1),
                }
            })
            .collect())
    } else {
        // TXT 路径：获取分页并批量定位
        let pages = process_and_layout_chapter(
            &book_id,
            chapter_index,
            &config,
            remove_duplicate_title,
            /* re_segment= */ false,
            chinese_convert,
            &replace_rules,
            &[],
            /* para_format_hash= */ 0,
        )?;

        Ok(offsets
            .into_iter()
            .map(|offset| locate_page_for_offset(&pages, offset))
            .collect())
    }
}

/// 统一的"内容处理 + 分页"实现，带 LRU 缓存
///
/// 缓存 key 同时覆盖排版配置与处理选项（options_hash）：
/// 任一变更即产生新 key 自然重算——设置即时生效；命中时零计算开销。
fn process_and_layout_chapter(
    book_id: &str,
    chapter_index: usize,
    config: &LayoutConfig,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    replace_rules: &[FfiReplaceRule],
    segment_rules: &[FfiSegmentRule],
    para_format_hash: u64,
) -> anyhow::Result<std::sync::Arc<Vec<Page>>> {
    process_and_layout_chapter_inner(
        book_id,
        chapter_index,
        config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        replace_rules,
        segment_rules,
        para_format_hash,
        /*allow_preload_trigger=*/ true,
    )
}

/// M9.3 内部变体：`allow_preload_trigger=false` 供预加载路径使用，
/// 严禁回源时再触发预热（打断 warm→miss→trigger→warm 自激级联）。
///
/// M9.3：返回 `Arc<Vec<Page>>`——命中路径仅引用计数交付，免整章深克隆。
#[allow(clippy::too_many_arguments)]
fn process_and_layout_chapter_inner(
    book_id: &str,
    chapter_index: usize,
    config: &LayoutConfig,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    replace_rules: &[FfiReplaceRule],
    segment_rules: &[FfiSegmentRule],
    para_format_hash: u64,
    allow_preload_trigger: bool,
) -> anyhow::Result<std::sync::Arc<Vec<Page>>> {
    let rules: Vec<ReplaceRule> = replace_rules.iter().cloned().map(Into::into).collect();
    let rules_hash = CacheKey::hash_replace_rules(&rules);
    let seg_rules: Vec<reader_core::SegmentRule> = segment_rules.iter().map(|sr| sr.into()).collect();
    let seg_hash = reader_core::SegmentRule::hash_rules(&seg_rules);
    let options_hash = CacheKey::hash_process_options(
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        rules_hash,
        para_format_hash,
        seg_hash,
    );
    let cache_key = CacheKey::with_options(book_id, chapter_index, config, options_hash);

    // 缓存命中：Arc bump 免整章深克隆【M9.3 H2】
    if let Some(cached) = PAGINATION_CACHE.lock().unwrap().get(&cache_key).cloned() {
        return Ok(cached.pages);
    }

    // M9.5-G：预处理结果缓存——命中则跳过取原文与整个预处理流水线。
    // para_format_hash 置 0：段落格式化（PARAGRAPH_FORMAT_SETTINGS）在缓存
    // 之后执行、不影响预处理输出，段落设置变更不应失效本缓存。
    let pre_key = reader_core::cache::CacheKey {
        book_id: book_id.to_string(),
        chapter_index,
        rules_hash: CacheKey::hash_process_options(
            remove_duplicate_title,
            re_segment,
            chinese_convert,
            rules_hash,
            /*para_format_hash=*/ 0,
            seg_hash,
        ),
    };
    let processed = match shared_tokio_runtime().block_on(PREPROCESSED_CACHE.get(&pre_key)) {
        Some(hit) => hit,
        None => {
            // 未命中：重活全部在锁外执行（quiet 回源，是否触发预热由调用方语义决定）
            let raw_content = if allow_preload_trigger {
                get_chapter_content(book_id.to_string(), chapter_index, remove_duplicate_title)?
            } else {
                get_chapter_content_quiet(book_id.to_string(), chapter_index, remove_duplicate_title)?
            };
            let chapter_title = {
                let books = BOOKS.read().unwrap();
                let handle = books.get(book_id)
                    .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
                handle.book.chapters.get(chapter_index)
                    .map(|ch| ch.title.clone())
                    .unwrap_or_default()
            };

            let options = ProcessOptions {
                book_name: String::new(),
                title: chapter_title,
                chapter_index,
                remove_duplicate_title,
                re_segment,
                segment_rules: segment_rules.iter().map(|sr| reader_core::SegmentRule {
                    id: sr.id.clone(),
                    kind: if sr.is_regex { reader_core::SegmentRuleKind::Regex } else { reader_core::SegmentRuleKind::Builtin },
                    pattern: sr.pattern.clone(),
                    action: match sr.action {
                        0 => reader_core::SegmentAction::ForceBreakAfter,
                        1 => reader_core::SegmentAction::ForceBreakBefore,
                        2 => reader_core::SegmentAction::KeepIndependent,
                        _ => reader_core::SegmentAction::MergeWithPrev,
                    },
                    enabled: sr.enabled,
                    builtin: sr.is_builtin,
                }).collect(),
                chinese_convert: match chinese_convert {
                    1 => Some(ChineseConvertType::S2T),
                    2 => Some(ChineseConvertType::T2S),
                    _ => None,
                },
                adapt_special_style: true,
                apply_user_markings: false,
            };

            let preprocessor = get_preprocessor_for_rules(&rules);
            let processed =
                shared_tokio_runtime().block_on(preprocessor.process(&raw_content, &options))?;
            // 回填预处理结果（LRU 容量 20 章自淘汰，不落盘）
            shared_tokio_runtime().block_on(PREPROCESSED_CACHE.put(pre_key, processed.clone()));
            processed
        }
    };

    // M9 P4：段落格式化（缩进 + 重新分段），在预处理后、布局前
    // A35-L2：智能分段引擎激活（reSegment 开或用户分段规则非空）时，
    // 接管重新分段+超长段切分语义（50字开关+终结标点+引号吸附），
    // formatter 覆盖为仅缩进——否则 split_ranges 的窗口回退切分会在
    // 顿号/闭引号处误切（v2 真机误切根因），双系统打架。
    // 缓存安全：options_hash 已含 re_segment 与 seg_hash，切换即换键重算。
    let mut para_settings = PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().clone();
    if re_segment || !seg_rules.is_empty() {
        para_settings.re_paragraph_mode = reader_core::ReParagraphMode::None;
    }
    let processed = if para_settings.needs_formatting() {
        let formatter = reader_core::ParagraphFormatter::new(para_settings);
        formatter.format(&processed)
    } else {
        processed
    };

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    // M8-P4：跨章复用共享字形缓存（M9.4-F：O(1) Arc bump，共享 prewarm 条目）
    let glyph_cache = SHARED_GLYPH_CACHE.lock().unwrap().glyph_cache();
    let engine = LayoutEngine::with_cache(config.clone(), font_manager, glyph_cache);
    let pages = std::sync::Arc::new(engine.layout_text(&processed, chapter_index)?);

    PAGINATION_CACHE.lock().unwrap().put(
        cache_key,
        CachedChapterPages {
            pages: std::sync::Arc::clone(&pages),
            total_pages: pages.len(),
            created_at: Instant::now(),
        },
    );

    Ok(pages)
}

/// 从 FFI 净化选项构造 ContentCleaner
fn build_cleaner_from_options(options: &ContentCleaningOptions) -> ContentCleaner {
    let convert_mode = match options.convert_mode.as_str() {
        "t2s" => ConvertMode::TraditionalToSimplified,
        "s2t" => ConvertMode::SimplifiedToTraditional,
        _ => ConvertMode::None,
    };

    let paragraph_mode = match options.paragraph_mode.as_str() {
        "smart" => ParagraphMode::Smart,
        "force" => ParagraphMode::Force,
        _ => ParagraphMode::None,
    };

    let clean_options = CleanOptions {
        clean_html: options.clean_html,
        remove_ads: options.remove_ads,
        remove_extra_whitespace: true,
    };

    ContentCleaner::new(convert_mode, paragraph_mode, clean_options)
}

/// 应用内容净化（内部辅助函数，用于非 parser 路径如 EPUB）
fn apply_content_cleaning(content: &str) -> String {
    let options_guard = CONTENT_CLEANING_OPTIONS.lock().unwrap();

    if let Some(options) = options_guard.as_ref() {
        let cleaner = build_cleaner_from_options(options);

        // 应用净化
        match cleaner.clean(content) {
            Ok(cleaned) => cleaned,
            Err(e) => {
                log::warn!("内容净化失败: {}", e);
                content.to_string()
            }
        }
    } else {
        // 没有设置净化选项，返回原内容
        content.to_string()
    }
}

/// 解析 TXT 文件（带内容净化选项）
pub fn parse_txt_file_with_cleaning(
    file_path: String,
    book_name: Option<String>,
    options: ContentCleaningOptions,
) -> anyhow::Result<String> {
    // 设置全局净化选项
    set_content_cleaning_options(options)?;
    
    // 使用标准的 parse_txt_file
    parse_txt_file(file_path, book_name)
}

/// 诊断用：直接从 EPUB 文件提取某章结构化内容 IR v2（JSON 字符串）
///
/// 无状态探针——不经 BOOKS 句柄（句柄版结构化阅读路径见
/// get_page_structured 等）。
/// 返回 StructuredContent 的 JSON
/// （schema 见 book_parser::content_ir，含 background/blocks）。
pub fn epub_chapter_structured(
    file_path: String,
    chapter_index: usize,
) -> anyhow::Result<String> {
    let path = std::path::Path::new(&file_path);
    let mut parser = book_parser::EpubParser::from_file(path)
        .map_err(|e| anyhow::anyhow!("EPUB 打开失败: {}", e))?;
    parser.parse().map_err(|e| anyhow::anyhow!("EPUB 解析失败: {}", e))?;
    let content = parser.get_chapter_content_structured(chapter_index)?;
    Ok(serde_json::to_string(&content)?)
}

/// Get book title
pub fn get_book_title(book_id: String) -> anyhow::Result<String> {
    let books = BOOKS.read().unwrap();
    let handle = books.get(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    
    Ok(handle.book.title.clone())
}

/// Get chapter list
pub fn get_chapters(book_id: String) -> anyhow::Result<Vec<ChapterInfo>> {
    let books = BOOKS.read().unwrap();
    let handle = books.get(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    
    Ok(handle.book.chapters.iter()
        .map(|ch| ChapterInfo::from(ch.clone()))
        .collect())
}

/// Get chapter content
pub fn get_chapter_content(
    book_id: String,
    chapter_index: usize,
    remove_duplicate_title: bool,
) -> anyhow::Result<String> {
    get_chapter_content_impl(book_id, chapter_index, true, remove_duplicate_title)
}

/// M9.3：get_chapter_content 的"安静版"——跳过 trigger_preload_async。
/// 仅供 process_and_layout_chapter 回源使用（预加载路径严禁再触发预热，
/// 否则形成自激级联：warm→miss→trigger→warm→…推进到全书末尾）。
fn get_chapter_content_quiet(
    book_id: String,
    chapter_index: usize,
    remove_duplicate_title: bool,
) -> anyhow::Result<String> {
    get_chapter_content_impl(book_id, chapter_index, false, remove_duplicate_title)
}

fn get_chapter_content_impl(
    book_id: String,
    chapter_index: usize,
    trigger_preload: bool,
    remove_duplicate_title: bool,
) -> anyhow::Result<String> {
    use book_parser::TxtParser;

    // 1. 检查是否有 parser 实例（仅 TXT 格式支持净化缓存）
    let has_parser = {
        let books = BOOKS.read().unwrap();
        let handle = books.get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        handle.parser.is_some()
    };

    // 2. 如果有 parser，使用净化缓存机制
    if has_parser {
        // 2.1 确保缓存存在且与当前净化配置一致（配置变更时自动重建，写锁）
        {
            let mut books = BOOKS.write().unwrap();
            let handle = books.get_mut(&book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

            if let Some(ref mut parser) = handle.parser {
                parser.ensure_cleaned_chapter_cache()?;
            }
        }

        // 2.3 从缓存读取章节内容（只读锁）
        let content = {
            let books = BOOKS.read().unwrap();
            let handle = books.get(&book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

            if let Some(ref parser) = handle.parser {
                parser.get_chapter_content_from_cache(chapter_index)?
            } else {
                return Err(anyhow::anyhow!("Parser not available"));
            }
        };

        // 去重标题逻辑已移至 ContentPreprocessor::process（Stage 1），
        // 预处理缓存会包含去重后的内容，避免缓存命中时去重被跳过。
        
        // 异步触发预加载（非阻塞；quiet 路径跳过以打断自激级联）
        if trigger_preload {
            trigger_preload_async(book_id, chapter_index);
        }

        Ok(content.to_string())
    } else {
        // 3. 无 parser（工厂已拒绝其他格式，此分支必为 EPUB）
        let options_snapshot = CONTENT_CLEANING_OPTIONS.lock().unwrap().clone();

        // 3.1 已设置净化选项：懒构建/重建净化缓存后直接切片（不再逐读净化）
        if let Some(options) = options_snapshot {
            let ensured: anyhow::Result<String> = {
                let mut books = BOOKS.write().unwrap();
                let handle = books.get_mut(&book_id)
                    .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

                ensure_epub_cleaned_cache(handle, &options)?;

                let cache = handle.epub_cleaned.as_ref()
                    .ok_or_else(|| anyhow::anyhow!("EPUB 净化缓存缺失"))?;
                let (start, end) = *cache.offsets.get(chapter_index)
                    .ok_or_else(|| anyhow::anyhow!("Chapter not found"))?;

                Ok(slice_utf8_safe(&cache.content, start, end))
            };

            match ensured {
                Ok(cleaned) => {
                    // 异步触发预加载（非阻塞；quiet 路径跳过）
                    if trigger_preload {
                        trigger_preload_async(book_id, chapter_index);
                    }
                    return Ok(cleaned);
                }
                Err(e) => log::warn!("EPUB 净化缓存不可用，回落逐读净化: {}", e),
            }
        }

        // 3.2 兜底：原样切片 + 逐读净化（旧行为；亦覆盖未设置净化选项场景）
        let content = {
            let books = BOOKS.read().unwrap();
            let handle = books.get(&book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

            TxtParser::get_chapter_content(&handle.book, chapter_index)
                .ok_or_else(|| anyhow::anyhow!("Chapter not found"))?
        };

        // 应用内容净化（如果已设置）
        let cleaned_content = apply_content_cleaning(&content);

        // 异步触发预加载（非阻塞；quiet 路径跳过）
        if trigger_preload {
            trigger_preload_async(book_id, chapter_index);
        }

        Ok(cleaned_content)
    }
}

/// 字符边界安全切片（工程硬约束 #3；偏移异常时向前收敛而非 panic）
fn slice_utf8_safe(content: &str, start: usize, end: usize) -> String {
    let clamp = |mut i: usize| {
        i = i.min(content.len());
        while i > 0 && !content.is_char_boundary(i) {
            i -= 1;
        }
        i
    };
    let s = clamp(start);
    let e = clamp(end).max(s);
    content[s..e].to_string()
}

/// 构造 EPUB 专用净化器：内容已是纯文本，强制 clean_html=false，
/// 防止正则误删正文字面 `<xxx>`（如涉及代码的文本）
fn build_epub_cleaner_from_options(options: &ContentCleaningOptions) -> ContentCleaner {
    let convert_mode = match options.convert_mode.as_str() {
        "t2s" => ConvertMode::TraditionalToSimplified,
        "s2t" => ConvertMode::SimplifiedToTraditional,
        _ => ConvertMode::None,
    };
    let paragraph_mode = match options.paragraph_mode.as_str() {
        "smart" => ParagraphMode::Smart,
        "force" => ParagraphMode::Force,
        _ => ParagraphMode::None,
    };
    ContentCleaner::new(
        convert_mode,
        paragraph_mode,
        CleanOptions {
            clean_html: false,
            remove_ads: options.remove_ads,
            remove_extra_whitespace: true,
        },
    )
}

/// EPUB 净化缓存的懒构建与配置变更检测
/// （与 TXT `ensure_cleaned_chapter_cache` 同构：hash 不符即重建）
fn ensure_epub_cleaned_cache(
    handle: &mut crate::BookHandle,
    options: &ContentCleaningOptions,
) -> anyhow::Result<()> {
    let cleaner = build_epub_cleaner_from_options(options);
    let current_hash = cleaner.config_hash();

    let needs_rebuild = match &handle.epub_cleaned {
        None => true,
        Some(cache) => cache.config_hash != current_hash,
    };
    if !needs_rebuild {
        return Ok(());
    }
    if handle.epub_cleaned.is_some() {
        log::info!("净化配置变更，重建 EPUB 净化缓存 (hash={:x})", current_hash);
    }

    let source = handle
        .source_path
        .clone()
        .ok_or_else(|| anyhow::anyhow!("缺少源文件路径，无法定位 EPUB 净化缓存"))?;
    let cleaned =
        book_parser::EpubCleanedBook::load_or_build(std::path::Path::new(&source), &handle.book, &cleaner)?;
    handle.epub_cleaned = Some(cleaned);
    Ok(())
}

/// 异步触发预加载（在泄漏的共享 Runtime 上提交任务，无新建线程/运行时）
fn trigger_preload_async(book_id: String, current_chapter: usize) {
    // M9.3 测试探针：级联打断回归测试用（仅测试构建）
    #[cfg(test)]
    PRELOAD_TRIGGER_CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

    let rt_handle = get_preload_runtime().handle.clone();
    rt_handle.spawn(async move {
        // 获取总章节数
        let total_chapters = {
            let books = BOOKS.read().unwrap();
            books.get(&book_id)
                .map(|h| h.book.chapters.len())
                .unwrap_or(0)
        };

        if total_chapters == 0 {
            return;
        }

        // 使用 DefaultPreloadStrategy 计算预加载范围
        let strategy = DefaultPreloadStrategy::default();
        let chapters_to_preload =
            strategy.calculate_preload_chapters(current_chapter, total_chapters);

        let executor = get_preload_executor();
        for (chapter_index, priority) in chapters_to_preload {
            if chapter_index == current_chapter {
                continue; // 跳过当前章节
            }

            let task = PreloadTask {
                chapter_index,
                priority,
                book_id: book_id.clone(),
            };

            // M9.3：去重提交——同章已在队列/执行中时静默跳过，
            // 防重复任务挤占队列与分页缓存
            match executor.try_submit_dedup(task).await {
                Ok(_) => {}
                Err(e) => log::warn!("预加载任务提交失败: {}", e),
            }
        }
    });
}

/// Get chapter content with preprocessing (简繁转换、去重标题等)
pub fn get_chapter_content_processed(
    book_id: String,
    chapter_index: usize,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8, // 0=none, 1=s2t, 2=t2s
) -> anyhow::Result<String> {
    // 1. 获取原始内容
    let raw_content = get_chapter_content(book_id.clone(), chapter_index, remove_duplicate_title)?;
    
    // 2. 获取章节标题
    let chapter_title = {
        let books = BOOKS.read().unwrap();
        let handle = books.get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        handle.book.chapters.get(chapter_index)
            .map(|ch| ch.title.clone())
            .unwrap_or_default()
    };
    
    // 3. 构建处理选项
    let options = ProcessOptions {
        book_name: String::new(),
        title: chapter_title,
        chapter_index,
        remove_duplicate_title,
        re_segment,
        segment_rules: Vec::new(),
        chinese_convert: match chinese_convert {
            1 => Some(ChineseConvertType::S2T),
            2 => Some(ChineseConvertType::T2S),
            _ => None,
        },
        adapt_special_style: true,
        apply_user_markings: false,
    };
    
    // 4. 异步处理内容
    let preprocessor = CONTENT_PREPROCESSOR.clone();
    let processed = tokio::runtime::Runtime::new()?
        .block_on(preprocessor.process(&raw_content, &options))?;
    
    Ok(processed)
}

/// Layout chapter text into pages (using new layout engine)
pub fn layout_chapter(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
) -> anyhow::Result<Vec<PageInfo>> {
    let content = get_chapter_content(book_id, chapter_index, false)?;
    
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };
    
    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = build_layout_engine(config, font_manager);
    let pages = engine.layout_text(&content, chapter_index)?;
    
    Ok(pages.into_iter().map(PageInfo::from).collect())
}

/// Get specific page (using new layout engine)
pub fn get_page(
    book_id: String,
    chapter_index: usize,
    page_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    page_fill_threshold: f32,
) -> anyhow::Result<PageInfo> {
    let content = get_chapter_content(book_id, chapter_index, false)?;

    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = build_layout_engine(config, font_manager);
    // A25c：越界兜底——陈旧索引钳制到末页（对齐 processed 路径）
    match engine.get_page(&content, chapter_index, page_index)? {
        Some(p) => Ok(PageInfo::from(p)),
        None => {
            eprintln!(
                "[READER][clamp] get_page requested={page_index} -> 末页"
            );
            let count = engine.get_page_count(&content, chapter_index)?;
            engine
                .get_page(&content, chapter_index, count.saturating_sub(1))?
                .map(PageInfo::from)
                .ok_or_else(|| anyhow::anyhow!("Page not found"))
        }
    }
}

/// Get page count for a chapter (using new layout engine)
pub fn get_page_count(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    page_fill_threshold: f32,
) -> anyhow::Result<usize> {
    let content = get_chapter_content(book_id, chapter_index, false)?;

    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = build_layout_engine(config, font_manager);
    engine.get_page_count(&content, chapter_index)
}

/// Get specific page with content preprocessing (带内容预处理的分页获取)
/// A31: PageEntry 文本行携带行级字符区间 start/end_char_index（笔记划线用）
///
/// `replace_rules`: 用户自定义替换规则（随设置传入，即时生效）
/// `anchor_char_offset`: 进度锚点——章内字符偏移；提供时返回包含该偏移的页
/// （用于设置变更后停留在原阅读位置，而非固定页码）
#[allow(clippy::too_many_arguments)]
pub fn get_page_processed(
    book_id: String,
    chapter_index: usize,
    page_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8, // 0=none, 1=s2t, 2=t2s
    replace_rules: Vec<FfiReplaceRule>,
    segment_rules: Vec<FfiSegmentRule>,
    anchor_char_offset: Option<usize>,
    page_fill_threshold: f32,
    para_format_hash: u64,
) -> anyhow::Result<PageInfo> {
    // M12-v4 诊断：输出 FFI 入口收到的 width 参数（仅首次）
    use std::sync::atomic::{AtomicBool, Ordering};
    static LOGGED_PROCESSED: AtomicBool = AtomicBool::new(false);
    if !LOGGED_PROCESSED.swap(true, Ordering::Relaxed) {
        eprintln!("[M12-v4] get_page_processed FIRST CALL: width={:.1}, padding_left={:.1}, padding_right={:.1}, content_width={:.1}", 
            width, padding_left, padding_right, width - padding_left - padding_right);
    }
    
    // 1. 排版配置
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: effective_paragraph_spacing(font_size),
        page_fill_threshold,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    // 2. 处理 + 排版（带缓存，选项变更自动重算）
    let pages = process_and_layout_chapter(
        &book_id,
        chapter_index,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
        &segment_rules,
        para_format_hash,
    )?;
    remember_txt_layout(
        &book_id,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
        &segment_rules,
        para_format_hash,
    );

    // 3. 页面定位：优先锚点（进度保持），否则用请求页码
    let effective = match anchor_char_offset {
        Some(offset) => locate_page_for_offset(&pages, offset),
        None => page_index,
    };

    // 4. 越界兜底（A25c）：无锚点请求的页码可能来自旧排版的陈旧索引
    // （设置变更竞态/邻页预取在途）——钳制到末页而非抛错。错误页会
    // 打断阅读；Dart 端 adopt 指纹校验识别内容不符后按新状态重试。
    if pages.get(effective).is_none() {
        eprintln!(
            "[READER][clamp] get_page_processed requested={effective} pages={} -> 末页",
            pages.len()
        );
    }
    let effective = effective.min(pages.len().saturating_sub(1));

    pages
        .get(effective)
        .cloned()
        .map(PageInfo::from)
        .ok_or_else(|| anyhow::anyhow!("Page not found"))
}

/// Get page count with content preprocessing (带内容预处理的分页计数)
#[allow(clippy::too_many_arguments)]
pub fn get_page_count_processed(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8, // 0=none, 1=s2t, 2=t2s
    replace_rules: Vec<FfiReplaceRule>,
    segment_rules: Vec<FfiSegmentRule>,
    page_fill_threshold: f32,
    para_format_hash: u64,
) -> anyhow::Result<usize> {
    // 1. 排版配置
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: effective_paragraph_spacing(font_size),
        page_fill_threshold,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    // 2. 处理 + 排版（带缓存）
    let pages = process_and_layout_chapter(
        &book_id,
        chapter_index,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
        &segment_rules,
        para_format_hash,
    )?;
    remember_txt_layout(
        &book_id,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
        &segment_rules,
        para_format_hash,
    );

    Ok(pages.len())
}

// ===== 结构化阅读路径（EPUB 路线2 主入口） =====

/// M9.1：EPUB 路径段落格式化（重新分段 + 用户缩进覆盖）
///
/// 在 IR 提取之后、blocks_to_layout_items 之前调用。D10 契约保持：
/// 文本变换与 runs 区间重写同步发生（先例 = list_prefix 的 runs 平移），
/// 变换后 runs 锚定在最终文本上，布局层零感知。
///
/// - 重新分段（用户钦定语义：超长段按标点切短）：
///   M9.2 起切点策略下沉到共享切分器 paragraph_splitter（EPUB/TXT 双路径统一，
///   Smart >200 字 / Aggressive >100 字；闭标吸附、省略号原子、有界回退）；
///   None 不切。仅处理顶层普通段落（注释块/嵌套块不动）。
/// - 缩进覆盖（用户设置优先）：开启 → 用设置值替换 CSS text-indent；
///   关闭 → 压制书自带缩进（None）。
fn apply_paragraph_format_settings(
    blocks: &mut Vec<book_parser::ContentBlock>,
    settings: &reader_core::ParagraphFormatSettings,
) {
    use book_parser::ContentBlock;

    // 模式 → 切分阈值（字，用户可调）；None = 不切。
    // split_ranges 循环保证：切口后的剩余文本作为新段落从头计数继续检测切分
    let split_threshold = settings.effective_split_threshold();

    let indent_override = if settings.enable_indent {
        Some(settings.indent_size_chars as f32)
    } else {
        None
    };

    let mut out: Vec<ContentBlock> = Vec::with_capacity(blocks.len());
    for block in blocks.drain(..) {
        // 仅顶层普通段落参与切分；注释块不切分（仅缩进覆盖）；其余块透传
        let is_normal_para =
            matches!(&block, ContentBlock::Paragraph { is_comment: false, .. });
        if !is_normal_para {
            let mut b = block;
            if let ContentBlock::Paragraph {
                indent_first_line_em: ref mut f,
                ..
            } = b
            {
                *f = indent_override;
            }
            out.push(b);
            continue;
        }

        let ContentBlock::Paragraph {
            text,
            align,
            color,
            font_scale,
            runs,
            anc,
            is_comment: _,
            indent_first_line_em: _,
            spacing_after_em,
            line_height,
        } = block
        else {
            unreachable!("is_normal_para 已判定为 Paragraph");
        };

        // P3：用户缩进覆盖（设置优先于 CSS 物化值）
        let indent_first_line_em = indent_override;

        // P2：超长段按强标点切短（runs 区间同步裁剪/平移）
        let mut pieces: Vec<String> = Vec::new();
        let mut piece_runs: Vec<Vec<book_parser::StyledRun>> = Vec::new();
        if let Some(threshold) = split_threshold {
            let total = text.chars().count();
            if total > threshold {
                // M9.2：切点策略在共享切分器（区间契约：升序无缝无叠、无空片、
                // 闭标吸附、省略号原子），此处只做文本切片与 runs 裁剪（D10 同步重写）
                let chars: Vec<char> = text.chars().collect();
                for (s, e) in reader_core::split_ranges(&text, threshold) {
                    pieces.push(chars[s..e].iter().collect());
                    piece_runs.push(clip_runs(&runs, s, e));
                }
            }
        }
        if pieces.is_empty() {
            out.push(ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs,
                anc,
                is_comment: false,
                indent_first_line_em,
                spacing_after_em,
                // P2：行高为段级属性，未切分时原样保留
                line_height,
            });
        } else {
            // 切分后的段：全部保留原对齐（M9.2：居中段切后不再突变左对齐），
            // 段后间距归属末段；余段视为新段落
            let last = pieces.len() - 1;
            for (i, piece) in pieces.into_iter().enumerate() {
                out.push(ContentBlock::Paragraph {
                    text: piece,
                    align: align.clone(),
                    color: color.clone(),
                    font_scale,
                    runs: std::mem::take(&mut piece_runs[i]),
                    anc: anc.clone(),
                    is_comment: false,
                    indent_first_line_em,
                    spacing_after_em: if i == last { spacing_after_em } else { None },
                    // P2：行高为段级属性——切分后每段继承原段行高
                    line_height,
                });
            }
        }
    }
    *blocks = out;
}

/// 裁剪 runs 至字符区间 [start, end) 并平移到新块坐标（D10 同步重写）
fn clip_runs(
    runs: &[book_parser::StyledRun],
    start: usize,
    end: usize,
) -> Vec<book_parser::StyledRun> {
    runs.iter()
        .filter_map(|r| {
            let s = r.start.max(start);
            let e = r.end.min(end);
            (e > s).then(|| book_parser::StyledRun {
                start: s - start,
                end: e - start,
                color: r.color.clone(),
                font_scale: r.font_scale,
                bold: r.bold,
                italic: r.italic,
                underline: r.underline,
                anc: r.anc.clone(),
            })
        })
        .collect()
}

/// 把章节 IR 块流映射为布局输入项（嵌套结构前序展平）
///
/// - Paragraph/Heading → 样式化文本项（对齐/颜色/字号/行内 runs）；
/// - Image → 图片项（intrinsic 缺失按 3:4 兜底）；
/// - List/Quote 递归展平；Table → 原子表格项（列宽提示 + 单元格文本）；
/// - Rule → 分隔线文本。
fn blocks_to_layout_items(
    blocks: &[book_parser::ContentBlock],
    out: &mut Vec<layout_engine::LayoutItem>,
) {
    blocks_to_layout_items_inner(blocks, out, &mut None);
}

/// 列表项前缀（Some=该 li 的前缀尚未挂到首个非空段落）
/// 先例：hr→「────」文本即 bridge 层合成；runs 区间同步偏移保证锚定自洽
fn blocks_to_layout_items_inner(
    blocks: &[book_parser::ContentBlock],
    out: &mut Vec<layout_engine::LayoutItem>,
    list_prefix: &mut Option<String>,
) {
    use book_parser::ContentBlock;
    for block in blocks {
        match block {
            ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
                ..
            } => {
                if text.trim().is_empty() {
                    continue;
                }
                // 消费本 li 前缀：文本加前缀，runs 区间整体平移 k 个字符
                let (text, runs) = match list_prefix.take() {
                    Some(marker) => {
                        let k = marker.chars().count();
                        (
                            format!("{}{}", marker, text),
                            runs.iter()
                                .map(|r| {
                                    let mut m = map_run(r);
                                    m.start += k;
                                    m.end += k;
                                    m
                                })
                                .collect(),
                        )
                    }
                    None => (text.clone(), runs.iter().map(map_run).collect()),
                };
                out.push(layout_engine::LayoutItem::Text(layout_engine::TextItem {
                    text,
                    align: map_align(*align),
                    color: color.clone(),
                    font_scale: *font_scale,
                    runs,
                    spacing_before_em: 0.0,
                    // P2：CSS margin-bottom 物化（epub_parser resolved_spacing_after_em
                    // 产出；None=书内未声明）。布局层与用户段距取 max（书内样式
                    // 提供下限，用户倍率兜底）——先例：标题分级 space_after 同模式
                    spacing_after_em: spacing_after_em.unwrap_or(0.0),
                    // P2：CSS line-height 物化（书内显式声明优先，未声明用用户全局）
                    line_height: *line_height,
                    indent_first_line_em: *indent_first_line_em,
                    is_comment: *is_comment,
                }));
            }
            ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                ..
            } => {
                if text.trim().is_empty() {
                    continue;
                }
                // 标题分级：仅 CSS 未指定倍率时给默认值与前后间距
                let (default_scale, space_before, space_after) = match level {
                    1 => (1.6, 0.6, 0.3),
                    2 => (1.4, 0.5, 0.3),
                    3 => (1.25, 0.4, 0.3),
                    _ => (1.1, 0.3, 0.3), // h4-h6
                };
                let final_scale = font_scale.or(Some(default_scale));
                out.push(layout_engine::LayoutItem::Text(layout_engine::TextItem {
                    text: text.clone(),
                    align: map_align(*align),
                    color: color.clone(),
                    font_scale: final_scale,
                    runs: Vec::new(),
                    spacing_before_em: space_before,
                    spacing_after_em: space_after,
                    indent_first_line_em: None,
                    is_comment: false,
                    line_height: None,
                }));
            }
            ContentBlock::Image {
                resource_href,
                intrinsic,
                width_percent,
                align,
                bleed,
                hidden,
                ..
            } => {
                if *hidden {
                    continue;
                }
                let aspect = match intrinsic {
                    Some((w, h)) if *h > 0 => *w as f32 / *h as f32,
                    _ => 0.75,
                };
                out.push(layout_engine::LayoutItem::Image {
                    resource_href: resource_href.clone(),
                    aspect,
                    width_percent: *width_percent,
                    align: align.map(|a| match a {
                        book_parser::Align::Left => layout_engine::LayoutAlign::Left,
                        book_parser::Align::Center => layout_engine::LayoutAlign::Center,
                        book_parser::Align::Right => layout_engine::LayoutAlign::Right,
                        book_parser::Align::Justify => layout_engine::LayoutAlign::Justify,
                    }),
                    bleed: *bleed,
                });
            }
            ContentBlock::List { items, ordered, .. } => {
                // 每个 li 独立前缀：ol 同级递增（恒从 1 起，start 属性不支持）、
                // ul 项目符号；嵌套列表自建计数器。前缀挂 li 内首个非空段落，
                // 其前的 Image/Heading 跳过不加；无段落的 li 无前缀
                let mut counter = 0u32;
                for item in items {
                    counter += 1;
                    let mut prefix = if *ordered {
                        Some(format!("{}. ", counter))
                    } else {
                        Some("• ".to_string())
                    };
                    blocks_to_layout_items_inner(&item.blocks, out, &mut prefix);
                }
            }
            ContentBlock::Quote { blocks } => {
                blocks_to_layout_items_inner(blocks, out, list_prefix);
            }
            ContentBlock::Table {
                caption: _,
                rows,
                anc: _,
                margin_top_percent,
                margin_left_auto,
            } => {
                let layout_rows = rows
                    .iter()
                    .map(|row| {
                        row.iter()
                            .map(|cell| layout_engine::TableCellInput {
                                width_em: cell.width_em,
                                items: cell
                                    .blocks
                                    .iter()
                                    .filter_map(|b| match b {
                                        ContentBlock::Paragraph {
                                            text,
                                            align,
                                            color,
                                            font_scale,
                                            runs,
                                            is_comment,
                                            indent_first_line_em: _,
                                            line_height,
                                            ..
                                        } => {
                                            if text.trim().is_empty() {
                                                return None;
                                            }
                                            Some(layout_engine::TextItem {
                                                text: text.clone(),
                                                align: map_align(*align),
                                                color: color.clone(),
                                                font_scale: *font_scale,
                                                runs: runs.iter().map(map_run).collect(),
                                                spacing_before_em: 0.0,
                                                spacing_after_em: 0.0,
                                                // M9.2 兜底：表格单元格不做散文首行缩进
                                                // （解析层已递归清零，此处强制防御）
                                                indent_first_line_em: None,
                                                is_comment: *is_comment,
                                                line_height: *line_height,
                                            })
                                        }
                                        ContentBlock::Heading {
                                            text,
                                            align,
                                            color,
                                            font_scale,
                                            ..
                                        } => {
                                            if text.trim().is_empty() {
                                                return None;
                                            }
                                            Some(layout_engine::TextItem {
                                                text: text.clone(),
                                                align: map_align(*align),
                                                color: color.clone(),
                                                font_scale: *font_scale,
                                                runs: Vec::new(),
                                                spacing_before_em: 0.0,
                                                spacing_after_em: 0.0,
                                                indent_first_line_em: None,
                                                is_comment: false,
                                                line_height: None,
                                            })
                                        }
                                        _ => None,
                                    })
                                    .collect(),
                            })
                            .collect()
                    })
                    .collect();
                out.push(layout_engine::LayoutItem::Table(layout_engine::TableInput {
                    margin_top_percent: *margin_top_percent,
                    margin_left_auto: *margin_left_auto,
                    rows: layout_rows,
                }));
            }
            ContentBlock::Rule => {
                out.push(layout_engine::LayoutItem::text("────────"));
            }
        }
    }
}

fn map_align(a: Option<book_parser::Align>) -> Option<layout_engine::LayoutAlign> {
    a.map(|a| match a {
        book_parser::Align::Left => layout_engine::LayoutAlign::Left,
        book_parser::Align::Center => layout_engine::LayoutAlign::Center,
        book_parser::Align::Right => layout_engine::LayoutAlign::Right,
        book_parser::Align::Justify => layout_engine::LayoutAlign::Justify,
    })
}

fn map_run(r: &book_parser::StyledRun) -> layout_engine::RunSpan {
    layout_engine::RunSpan {
        start: r.start,
        end: r.end,
        color: r.color.clone(),
        font_scale: r.font_scale,
        bold: r.bold,
        italic: r.italic,
        underline: r.underline,
    }
}

/// A30c：EPUB 去重标题（TXT `ContentPreprocessor::remove_duplicate_title`
/// 的块级镜像，语义严格对齐）：
/// - 逐块扫描开头，Paragraph/Heading 文本裁剪空白（含全角空格 \u{3000}）
///   后与章节标题全等 → 该块移除（支持连续重复标题块）；
/// - Image/Rule 等无文本块视作空行等价物，随标题一并移除；
/// - 首个非空非标题块即停。
/// 语义差异说明：TXT 预处理器做整章逐行扫描；EPUB 标题是结构化块（spine
/// 导航的章名与正文首个 Heading 天然同文），仅开头扫描即可覆盖全部场景。
fn remove_duplicate_title_blocks(blocks: &mut Vec<book_parser::ContentBlock>, title: &str) {
    let title_trimmed = title.trim();
    if title_trimmed.is_empty() {
        return;
    }
    let mut last_match: Option<usize> = None;
    for (i, block) in blocks.iter().enumerate() {
        let text: Option<&str> = match block {
            book_parser::ContentBlock::Paragraph { text, .. }
            | book_parser::ContentBlock::Heading { text, .. } => Some(text),
            book_parser::ContentBlock::Image { .. } | book_parser::ContentBlock::Rule => {
                // 空白等价物：可随标题一并移除，继续向后扫描
                continue;
            }
            // 其它结构块（List/Quote/Table）视作正文，停止扫描
            _ => break,
        };
        match text {
            Some(t) => {
                let t_trimmed = t
                    .trim_start_matches(|c: char| c.is_whitespace() || c == '\u{3000}')
                    .trim_end();
                if t_trimmed == title_trimmed {
                    last_match = Some(i);
                } else {
                    break;
                }
            }
            None => continue,
        }
    }
    if let Some(idx) = last_match {
        log::debug!("remove_duplicate_title_blocks: 移除开头 {} 个重复标题块", idx + 1);
        blocks.drain(..=idx);
    }
}

/// A30b：对 IR 块流递归应用用户替换规则（EPUB 结构化路径）。
///
/// TXT 侧规则在 ContentPreprocessor::process 内整章应用；EPUB 无整章文本
/// 形态，按块应用（跨段正则不命中——legado 净化规则以段内模式为主，可接受）。
/// 文本发生变化的块清空 runs（StyledRun 字符区间基于原文，规则改写后区间
/// 失配，降级为整块统一样式，防错位绘制）。
fn apply_replace_rules_to_blocks(
    blocks: &mut [book_parser::ContentBlock],
    pre: &ContentPreprocessor,
) -> anyhow::Result<()> {
    shared_tokio_runtime().block_on(apply_replace_rules_to_blocks_inner(blocks, pre))
}

async fn apply_replace_rules_to_blocks_inner(
    blocks: &mut [book_parser::ContentBlock],
    pre: &ContentPreprocessor,
) -> anyhow::Result<()> {
    for block in blocks.iter_mut() {
        match block {
            book_parser::ContentBlock::Paragraph { text, runs, .. } => {
                let new_text = pre.apply_replace_rules(text, "").await?;
                if new_text != *text {
                    runs.clear();
                    *text = new_text;
                }
            }
            book_parser::ContentBlock::Heading { text, .. } => {
                let new_text = pre.apply_replace_rules(text, "").await?;
                if new_text != *text {
                    *text = new_text;
                }
            }
            book_parser::ContentBlock::List { items, .. } => {
                for item in items.iter_mut() {
                    // 递归 async fn 需装箱引入间接层（嵌套仅 2-3 层深，开销可忽略）
                    Box::pin(apply_replace_rules_to_blocks_inner(&mut item.blocks, pre)).await?;
                }
            }
            book_parser::ContentBlock::Quote { blocks } => {
                Box::pin(apply_replace_rules_to_blocks_inner(blocks, pre)).await?;
            }
            book_parser::ContentBlock::Table { rows, .. } => {
                for row in rows.iter_mut() {
                    for cell in row.iter_mut() {
                        Box::pin(apply_replace_rules_to_blocks_inner(&mut cell.blocks, pre))
                            .await?;
                    }
                }
            }
            _ => {} // Image / Rule 无文本
        }
    }
    Ok(())
}

/// 结构化章节的「提取 + 分页」（带 LRU 缓存；键含排版配置+简繁模式）
///
/// `prefer_try_lock`: 预取语义——提取段用 try_write 抢 BOOKS 写锁，
/// 被前台占用时让路返回 Ok(None)（绝不阻塞前台）；前台调用恒传 false
/// （阻塞等待、恒返回 Some）。
///
/// M8-P4：返回类型改为 `Arc<Vec<PageInfo>>`，命中时 Arc::clone（~8ns）
/// 替代整章 Vec 克隆（~数十μs），锁外取单页。
fn process_structured_chapter(
    book_id: &str,
    chapter_index: usize,
    params: &StructuredParams,
    prefer_try_lock: bool,
) -> anyhow::Result<Option<Arc<Vec<crate::PageInfo>>>> {
    let cache_key = structured_cache_key(book_id, chapter_index, params);

    // M8-P4 缓存命中：Arc::clone 免整章克隆
    // 阶段2优化：检查 TTL 过期
    if let Some(entry) = STRUCTURED_PAGINATION_CACHE
        .lock()
        .unwrap()
        .get(&cache_key)
        .cloned()
    {
        if !entry.is_expired(STRUCTURED_CACHE_TTL_SECS) {
            return Ok(Some(entry.pages));
        }
        // TTL 过期 → 移除旧缓存并重新计算
        STRUCTURED_PAGINATION_CACHE.lock().unwrap().pop(&cache_key);
    }

    // u8 → ConvertMode（与 TXT process_and_layout_chapter 同编码：1=简→繁 2=繁→简）
    let convert_mode = match params.convert_mode {
        1 => book_parser::content_cleaner::ConvertMode::SimplifiedToTraditional,
        2 => book_parser::content_cleaner::ConvertMode::TraditionalToSimplified,
        _ => book_parser::content_cleaner::ConvertMode::None,
    };

    // 提取 IR（锁内：parser 独占可变状态；预取抢不到写锁即让路）
    let mut books = if prefer_try_lock {
        match BOOKS.try_write() {
            Ok(guard) => guard,
            Err(_) => return Ok(None),
        }
    } else {
        BOOKS.write().unwrap()
    };
    let handle = books
        .get_mut(book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    let structured = handle
        .structured
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("非结构化书籍（TXT 请走旧分页 API）"))?;
    let content = structured
        .parser
        .get_chapter_content_structured_ex(chapter_index, convert_mode, params.config.font_size)?;
    // A30c：章节标题（去重标题比对基准，与 search_txt_chapter 同源）；
    // IR 文本已经过简繁转换，标题需按同一方向转换后再比对
    let raw_title = handle
        .book
        .chapters
        .get(chapter_index)
        .map(|c| c.title.clone())
        .unwrap_or_default();
    let background = content.background.clone();
    drop(books);

    // M9.1：EPUB 段落格式化（超长段切短 + 用户缩进覆盖 CSS）。
    // 设置经 para_format_hash 入缓存键——变更即换键重排，此处读全局即可。
    let mut content = content;

    // A30c：去重标题（TXT 预处理 Stage1 同口径，先于替换规则——规则可能
    // 改写标题文本）。IR 块文本是转换后文本，标题按同方向转换后比对。
    if params.remove_duplicate_title {
        let title_cmp = match params.convert_mode {
            1 => book_parser::chinese_convert::convert_s2t(&raw_title),
            2 => book_parser::chinese_convert::convert_t2s(&raw_title),
            _ => raw_title,
        };
        remove_duplicate_title_blocks(&mut content.blocks, &title_cmp);
    }

    // A30b：用户替换规则块级应用（与 TXT 预处理同口径；规则可能改变文本
    // 长度，必须先于段落格式化与布局项字符累计——展示/搜索/锚点三方同源）。
    if !params.rules.is_empty() {
        let pre = get_preprocessor_for_rules(&params.rules);
        apply_replace_rules_to_blocks(&mut content.blocks, pre.as_ref())?;
    }

    {
        let para_settings = PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().clone();
        if para_settings.needs_formatting() {
            apply_paragraph_format_settings(&mut content.blocks, &para_settings);
        }
    }

    // IR → 布局项 → 分页（重活在锁外）
    let mut items = Vec::with_capacity(content.blocks.len());
    blocks_to_layout_items(&content.blocks, &mut items);

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    // M10-B：注入共享 MEASURE_CACHE，让 Dart TextPainter 测宽在分页时即时可用。
    // 注意：此路径（M9.5-G structured layout）原本通过 with_cache 注入 SHARED_GLYPH_CACHE，
    // 而 with_cache 内部不复用 measure_cache 字段。为简单计本路径暂用 build_layout_engine
    // （measure_cache 命中率高时几乎无损；如有回归可后续加 with_cache_and_measure 合并）。
    let engine = build_layout_engine(params.config.clone(), font_manager);
    let pages = engine.layout_items(&items, chapter_index)?;

    // 背景为章节级属性：逐页携带（Dart 侧按 href 去重解码一次）
    let infos: Vec<crate::PageInfo> = pages
        .into_iter()
        .map(|p| {
            let mut info = crate::PageInfo::from(p);
            if let Some(bg) = &background {
                info.background_href = Some(bg.image_href.clone());
                info.background_size = Some(
                    match bg.size {
                        book_parser::BgSize::Cover => "cover",
                        book_parser::BgSize::Contain => "contain",
                        book_parser::BgSize::Stretch => "stretch",
                    }
                    .to_string(),
                );
                info.background_position = bg.position.clone();
            }
            info
        })
        .collect();

    // M8-P4：Arc 包裹后入缓存，后续命中 Arc::clone 免克隆
    // 阶段2优化：使用 TTL 包装结构
    let arc_infos = Arc::new(infos);
    let entry = StructuredCacheEntry::new(Arc::clone(&arc_infos));
    STRUCTURED_PAGINATION_CACHE
        .lock()
        .unwrap()
        .put(cache_key, entry);

    Ok(Some(arc_infos))
}

/// 页内是否含文本项（纯图/空页判定）
fn page_has_text(info: &crate::PageInfo) -> bool {
    info.entries.iter().any(|e| e.text.is_some())
}

/// 结构化路径的锚点定位：先按字符偏移二分，再跳过与命中页同起点的
/// 纯图页（图片不消耗锚点，装饰图页与后继文本页 start 相同）
fn locate_structured_page(pages: &[crate::PageInfo], char_offset: usize) -> usize {
    if pages.is_empty() {
        return 0;
    }
    let starts: Vec<usize> = pages.iter().map(|p| p.start_char_index).collect();
    let base = match starts.binary_search(&char_offset) {
        Ok(i) => i,
        Err(ins) => ins.saturating_sub(1),
    };
    let mut i = base;
    while i + 1 < pages.len()
        && !page_has_text(&pages[i])
        && pages[i + 1].start_char_index == pages[i].start_char_index
    {
        i += 1;
    }
    i
}

fn structured_layout_config(
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    page_fill_threshold: f32,
    show_comments: bool,
) -> LayoutConfig {
    LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: effective_paragraph_spacing(font_size),
        page_fill_threshold,
        show_comments,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    }
}

/// 结构化路径参数单源：config + 简繁模式 + 段落哈希打包。
///
/// 三个 FFI 入口（get_page_structured / get_page_count_structured /
/// prefetch_structured_chapter）与 process_structured_chapter 全部经由
/// 本结构构造 config 与缓存键，杜绝「多处手抄参数 → bit 级错位 → 静默 miss」。
///
/// A30b：新增用户替换规则（块级应用）。rules_hash 入结构化分页缓存键——
/// 规则变更即换键自然重算；规则本体供 process_structured_chapter 应用。
struct StructuredParams {
    config: LayoutConfig,
    convert_mode: u8,
    para_format_hash: u64,
    /// A30c：去重标题（入缓存键：开关变更即换键重算）
    remove_duplicate_title: bool,
    rules: Arc<Vec<ReplaceRule>>,
    rules_hash: u64,
}

impl StructuredParams {
    #[allow(clippy::too_many_arguments)]
    fn from_args(
        width: f32,
        height: f32,
        font_size: f32,
        line_height_multiplier: f32,
        padding_left: f32,
        padding_top: f32,
        padding_right: f32,
        padding_bottom: f32,
        font_name: String,
        chinese_convert: u8,
        page_fill_threshold: f32,
        show_comments: bool,
        para_format_hash: u64,
        remove_duplicate_title: bool,
        replace_rules: Vec<FfiReplaceRule>,
    ) -> Self {
        let rules: Vec<ReplaceRule> = replace_rules.into_iter().map(Into::into).collect();
        let rules_hash = CacheKey::hash_replace_rules(&rules);
        Self {
            config: structured_layout_config(
                width,
                height,
                font_size,
                line_height_multiplier,
                padding_left,
                padding_top,
                padding_right,
                padding_bottom,
                font_name,
                page_fill_threshold,
                show_comments,
            ),
            convert_mode: chinese_convert,
            para_format_hash,
            remove_duplicate_title,
            rules: Arc::new(rules),
            rules_hash,
        }
    }
}

/// 结构化分页缓存键的唯一构造点
fn structured_cache_key(
    book_id: &str,
    chapter_index: usize,
    params: &StructuredParams,
) -> StructuredPageKey {
    StructuredPageKey::new(
        book_id,
        chapter_index,
        &params.config,
        params.convert_mode,
        params.para_format_hash,
        params.remove_duplicate_title,
        params.rules_hash,
    )
}

/// 结构化分页获取（EPUB 主路径）
///
/// `anchor_char_offset`: 进度锚点——章内文本字符偏移（与 TXT 路径同语义，
/// 图片项不消耗锚点）；提供时返回包含该偏移的页（跳过纯图装饰页）。
/// `chinese_convert`: 阅读级简繁转换（0=无 1=简→繁 2=繁→简；与 TXT 同编码）
/// `replace_rules`: 用户替换规则（A30b：块级应用；哈希入缓存键，规则变更
/// 即换键重算。与 TXT 路径同口径）
/// `remove_duplicate_title`: 去重标题（A30c：TXT 预处理 Stage1 同口径，
/// 开关入缓存键）
#[allow(clippy::too_many_arguments)]
pub fn get_page_structured(
    book_id: String,
    chapter_index: usize,
    page_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    anchor_char_offset: Option<usize>,
    chinese_convert: u8,
    page_fill_threshold: f32,
    show_comments: bool,
    para_format_hash: u64,
    remove_duplicate_title: bool,
    replace_rules: Vec<FfiReplaceRule>,
) -> anyhow::Result<crate::PageInfo> {
    // M12-v4 诊断：输出 FFI 入口收到的 width 参数（仅首次）
    use std::sync::atomic::{AtomicBool, Ordering};
    static LOGGED_STRUCTURED: AtomicBool = AtomicBool::new(false);
    if !LOGGED_STRUCTURED.swap(true, Ordering::Relaxed) {
        eprintln!("[M12-v4] get_page_structured FIRST CALL: width={:.1}, padding_left={:.1}, padding_right={:.1}, content_width={:.1}", 
            width, padding_left, padding_right, width - padding_left - padding_right);
    }
    
    let params = StructuredParams::from_args(
        width,
        height,
        font_size,
        line_height_multiplier,
        padding_left,
        padding_top,
        padding_right,
        padding_bottom,
        font_name,
        chinese_convert,
        page_fill_threshold,
        show_comments,
        para_format_hash,
        remove_duplicate_title,
        replace_rules,
    );
    let pages =
        process_structured_chapter(&book_id, chapter_index, &params, false)?
            .expect("前台结构化分页恒返回 Some");

    let effective = match anchor_char_offset {
        Some(offset) => locate_structured_page(&pages, offset),
        None => page_index,
    };

    // A25c：越界兜底（对齐 get_page_processed）——陈旧索引钳制到末页
    if pages.get(effective).is_none() {
        eprintln!(
            "[READER][clamp] get_page_structured requested={effective} pages={} -> 末页",
            pages.len()
        );
    }
    let effective = effective.min(pages.len().saturating_sub(1));

    pages
        .get(effective)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("Page not found: {}", effective))
}

/// 结构化分页计数（EPUB 主路径）
#[allow(clippy::too_many_arguments)]
pub fn get_page_count_structured(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    chinese_convert: u8,
    page_fill_threshold: f32,
    show_comments: bool,
    para_format_hash: u64,
    remove_duplicate_title: bool,
    replace_rules: Vec<FfiReplaceRule>,
) -> anyhow::Result<usize> {
    let params = StructuredParams::from_args(
        width,
        height,
        font_size,
        line_height_multiplier,
        padding_left,
        padding_top,
        padding_right,
        padding_bottom,
        font_name,
        chinese_convert,
        page_fill_threshold,
        show_comments,
        para_format_hash,
        remove_duplicate_title,
        replace_rules,
    );
    let pages =
        process_structured_chapter(&book_id, chapter_index, &params, false)?
            .expect("前台结构化分页恒返回 Some");
    Ok(pages.len())
}

/// EPUB 翻章预取：以与前台完全一致的参数预计算目标章分页并写入缓存。
///
/// 幂等——键已存在立即返回 true；BOOKS 写锁被前台占用时让路返回 false。
/// ⚠ 参数必须与 get_page_structured/get_page_count_structured 完全同参
/// （f32 按 bits 入键），否则入键错位、预取无效。Dart 侧 fire-and-forget
/// 调用（当前章渲染完成后预取下一章）。
#[allow(clippy::too_many_arguments)]
pub fn prefetch_structured_chapter(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    chinese_convert: u8,
    page_fill_threshold: f32,
    show_comments: bool,
    para_format_hash: u64,
    remove_duplicate_title: bool,
    replace_rules: Vec<FfiReplaceRule>,
) -> anyhow::Result<bool> {
    let params = StructuredParams::from_args(
        width,
        height,
        font_size,
        line_height_multiplier,
        padding_left,
        padding_top,
        padding_right,
        padding_bottom,
        font_name,
        chinese_convert,
        page_fill_threshold,
        show_comments,
        para_format_hash,
        remove_duplicate_title,
        replace_rules,
    );
    let cache_key = structured_cache_key(&book_id, chapter_index, &params);
    // 阶段2优化：检查缓存存在且未过期
    if let Some(entry) = STRUCTURED_PAGINATION_CACHE.lock().unwrap().peek(&cache_key) {
        if !entry.is_expired(STRUCTURED_CACHE_TTL_SECS) {
            return Ok(true);
        }
    }
    Ok(process_structured_chapter(&book_id, chapter_index, &params, true)?.is_some())
}

/// 读取书内资源字节（EPUB 图片；ZIP 全路径，与 IR resource_href 同基准）
///
/// 快路径：read 锁内窥探 parser 资源缓存，命中（渲染重复图/预热去重后
/// 的图）直接返回，不与前台分页（BOOKS.write）争写锁；未命中才落写锁
/// 慢路径（ZIP 读取 + 写缓存，仅每资源首次）。
pub fn get_book_resource(book_id: String, resource_href: String) -> anyhow::Result<Vec<u8>> {
    // 快路径：读锁窥探缓存
    {
        let books = BOOKS.read().unwrap();
        let handle = books
            .get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        let structured = handle
            .structured
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("非结构化书籍，无资源句柄"))?;
        if let Some(data) = structured.parser.peek_resource_cache(&resource_href) {
            return Ok(data);
        }
    }
    // 慢路径：写锁内 ZIP 读取 + 写缓存（只读快路径未命中才到达）
    let mut books = BOOKS.write().unwrap();
    let handle = books
        .get_mut(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    let structured = handle
        .structured
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("非结构化书籍，无资源句柄"))?;
    structured.parser.get_resource_cached(&resource_href)
}

/// 读取书封面字节（导入时提取；空返回=无封面）
pub fn get_book_cover(book_id: String) -> anyhow::Result<Vec<u8>> {
    let books = BOOKS.read().unwrap();
    let handle = books
        .get(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    let Some(structured) = handle.structured.as_ref() else {
        return Ok(Vec::new());
    };
    Ok(structured.parser.cover_data().cloned().unwrap_or_default())
}

/// 书籍格式标记（Dart 据此分流结构化/旧 API："epub" | "txt"）
pub fn get_book_format(book_id: String) -> anyhow::Result<String> {
    let books = BOOKS.read().unwrap();
    let handle = books
        .get(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    Ok(if handle.structured.is_some() {
        "epub"
    } else {
        "txt"
    }
    .to_string())
}

/// Get glyph cache statistics
pub fn get_cache_stats() -> String {
    // This would need to be tracked globally, for now return a placeholder
    "Cache stats: Use layout engine instance to get detailed stats".to_string()
}

// ===== A30：书内全文搜索 =====
//
// 设计约束（用户定案）：
// - 计算全在 Rust（单次异步 FFI，flutter_rust_bridge 线程池执行），Dart 零扫描
// - EPUB/TXT 同一 SearchHit 契约，格式分派封装在 Rust 内部
// - 复用既有内容引擎产物（CleanedChapterCache / EpubCleanedBook / 预处理器），
//   绝不走分页 API（防排版缓存污染 + BOOKS 写锁竞争）

/// 单条搜索命中（EPUB/TXT 同构契约）
#[derive(Clone, Debug)]
pub struct SearchHit {
    pub chapter_index: usize,
    /// 章内字符偏移（锚点口径）：
    /// TXT = processed + 段落格式化后文本（与 layout_text 输入同源）；
    /// EPUB = IR 布局项字符流（与 layout_items 的 char_index 累加同源）
    pub anchor_char_offset: usize,
    /// 命中前后摘录（约 ±40 字符）
    pub excerpt: String,
    /// 命中词在摘录中的字符偏移
    pub match_offset_in_excerpt: usize,
}

/// 命中前后摘录字符数
const SEARCH_EXCERPT_CONTEXT_CHARS: usize = 40;
/// 全书扫描时间预算（超即停，返回已得结果）
const SEARCH_TIME_BUDGET_MS: u128 = 5000;

/// A30：书内全文搜索
///
/// 命中词集合 = 原词 + 双向简繁变体（展示文本可能被转换，用户输入方向不定）。
/// 计算全在本函数（同步、调用方经 flutter_rust_bridge 线程池异步执行）；
/// 超过 [SEARCH_TIME_BUDGET_MS] 或命中 [max_hits] 即停止扫描。
pub fn search_in_book(
    book_id: String,
    query: String,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    replace_rules: Vec<FfiReplaceRule>,
    segment_rules: Vec<FfiSegmentRule>,
    max_hits: usize,
) -> anyhow::Result<Vec<SearchHit>> {
    let started = std::time::Instant::now();
    let query = query.trim().to_string();
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let max_hits = max_hits.clamp(1, 500);

    // 命中词集合：原词 + 双向简繁变体（去重）
    let mut needle_strings = vec![query.clone()];
    for mode in [1u8, 2] {
        let v = if mode == 1 {
            book_parser::chinese_convert::convert_s2t(&query)
        } else {
            book_parser::chinese_convert::convert_t2s(&query)
        };
        if !needle_strings.contains(&v) {
            needle_strings.push(v);
        }
    }
    let needles: Vec<Vec<char>> = needle_strings
        .iter()
        .map(|s| s.chars().collect())
        .collect();

    let format = get_book_format(book_id.clone())?;
    let total_chapters = {
        let books = BOOKS.read().unwrap();
        books
            .get(&book_id)
            .map(|h| h.book.chapters.len())
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?
    };

    // 用户替换规则：TXT 在预处理内应用；A30b 起 EPUB 结构化路径块级应用
    // （与展示同口径），两格式搜索与展示同源
    let rules: Vec<ReplaceRule> = replace_rules.into_iter().map(Into::into).collect();
    // A35-L2：分段规则与展示同口径（TXT 路径预处理 + formatter 覆盖）
    let seg_rules: Vec<reader_core::SegmentRule> =
        segment_rules.iter().map(|sr| sr.into()).collect();

    let mut hits: Vec<SearchHit> = Vec::new();
    for chapter_index in 0..total_chapters {
        if hits.len() >= max_hits || started.elapsed().as_millis() > SEARCH_TIME_BUDGET_MS {
            break;
        }
        let result = match format.as_str() {
            "epub" => search_epub_chapter(
                &book_id,
                chapter_index,
                chinese_convert,
                remove_duplicate_title,
                &rules,
                &needles,
                &mut hits,
                max_hits,
            ),
            _ => search_txt_chapter(
                &book_id,
                chapter_index,
                remove_duplicate_title,
                re_segment,
                chinese_convert,
                &rules,
                &segment_rules,
                &needles,
                &mut hits,
                max_hits,
            ),        };
        if let Err(e) = result {
            log::warn!("search_in_book 章节搜索失败 chapter={}: {}", chapter_index, e);
        }
    }

    readerTraceCompat(&format!(
        "search.in_book done hits={} truncated={} elapsed_ms={}",
        hits.len(),
        hits.len() >= max_hits,
        started.elapsed().as_millis()
    ));
    Ok(hits)
}

/// 诊断输出（复用 readerTrace 控制台约定：print 直出便于真机查看）
fn readerTraceCompat(msg: &str) {
    println!("[READER][search] {}", msg);
}

/// 字符级 1:1 小写化（多字符展开取首字符——中文场景无影响，保留下标对齐）
fn search_lower_char(c: char) -> char {
    c.to_lowercase().next().unwrap_or(c)
}

/// 大小写不敏感查找：返回全部命中的起始字符偏移（升序、非重叠）
fn find_all_ci(hay: &[char], needle: &[char]) -> Vec<usize> {
    let n = needle.len();
    if n == 0 || hay.len() < n {
        return Vec::new();
    }
    let hay_lower: Vec<char> = hay.iter().map(|c| search_lower_char(*c)).collect();
    let nd_lower: Vec<char> = needle.iter().map(|c| search_lower_char(*c)).collect();
    let mut out = Vec::new();
    let mut start = 0usize;
    while start + n <= hay_lower.len() {
        if hay_lower[start..start + n] == nd_lower[..] {
            out.push(start);
            start += n; // 非重叠：同词连续命中取第一个
        } else {
            start += 1;
        }
    }
    out
}

/// 多词命中收集：合并 + 按偏移排序 + 重叠去重（保留最先者）
fn merge_needle_hits(
    text_chars: &[char],
    needles: &[Vec<char>],
    hits: &mut Vec<SearchHit>,
    chapter_index: usize,
    anchor_base: usize,
    max_hits: usize,
) {
    let mut offsets: Vec<(usize, usize)> = Vec::new(); // (char offset, needle len)
    for nd in needles {
        for off in find_all_ci(text_chars, nd) {
            offsets.push((off, nd.len()));
        }
    }
    if offsets.is_empty() {
        return;
    }
    offsets.sort_by_key(|(off, _)| *off);
    let mut accepted: Vec<(usize, usize)> = Vec::new();
    for (off, len) in offsets {
        if hits.len() + accepted.len() >= max_hits {
            break;
        }
        if let Some(&(po, pl)) = accepted.last() {
            if off < po + pl {
                continue; // 与前一命中重叠 → 丢弃
            }
        }
        accepted.push((off, len));
    }
    for (off, len) in accepted {
        let (excerpt, mo) = build_excerpt(text_chars, off, len);
        hits.push(SearchHit {
            chapter_index,
            anchor_char_offset: anchor_base + off,
            excerpt,
            match_offset_in_excerpt: mo,
        });
    }
}

/// 摘录构造：命中词前后 ±40 字符的字符安全窗口
fn build_excerpt(text_chars: &[char], match_start: usize, match_len: usize) -> (String, usize) {
    let from = match_start.saturating_sub(SEARCH_EXCERPT_CONTEXT_CHARS);
    let to = (match_start + match_len + SEARCH_EXCERPT_CONTEXT_CHARS).min(text_chars.len());
    let excerpt: String = text_chars[from..to].iter().collect();
    (excerpt, match_start - from)
}

/// TXT 章节搜索：processed + 段落格式化后文本（与 layout_text 输入同源，
/// 锚点口径天然一致）。管线与 process_and_layout_chapter :843-874 严格同源，
/// 但**不回填 PREPROCESSED_CACHE**（全书扫描会挤占 20 章 LRU 阅读窗口）。
fn search_txt_chapter(
    book_id: &str,
    chapter_index: usize,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
    rules: &[ReplaceRule],
    segment_rules: &[FfiSegmentRule],
    needles: &[Vec<char>],
    hits: &mut Vec<SearchHit>,
    max_hits: usize,
) -> anyhow::Result<()> {
    let raw_content = get_chapter_content_quiet(book_id.to_string(), chapter_index, remove_duplicate_title)?;
    let chapter_title = {
        let books = BOOKS.read().unwrap();
        books
            .get(book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?
            .book
            .chapters
            .get(chapter_index)
            .map(|ch| ch.title.clone())
            .unwrap_or_default()
    };
    let seg_rules: Vec<reader_core::SegmentRule> = segment_rules.iter().map(|sr| sr.into()).collect();
    let options = ProcessOptions {
        book_name: String::new(),
        title: chapter_title,
        chapter_index,
        remove_duplicate_title,
        re_segment,
        segment_rules: seg_rules.clone(),
        chinese_convert: match chinese_convert {
            1 => Some(ChineseConvertType::S2T),
            2 => Some(ChineseConvertType::T2S),
            _ => None,
        },
        adapt_special_style: true,
        apply_user_markings: false,
    };
    let preprocessor = get_preprocessor_for_rules(rules);
    let processed = shared_tokio_runtime().block_on(preprocessor.process(&raw_content, &options))?;
    // 段落格式化（缩进字符注入/重新分段改变文本与偏移——锚点口径必须含此步）
    // A35-L2：与展示同口径——引擎激活时 formatter 覆盖为仅缩进
    let mut para_settings = PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().clone();
    if re_segment || !seg_rules.is_empty() {
        para_settings.re_paragraph_mode = reader_core::ReParagraphMode::None;
    }
    let processed = if para_settings.needs_formatting() {
        reader_core::ParagraphFormatter::new(para_settings).format(&processed)
    } else {
        processed
    };
    let text_chars: Vec<char> = processed.chars().collect();
    merge_needle_hits(&text_chars, needles, hits, chapter_index, 0, max_hits);
    Ok(())
}

/// EPUB 章节搜索：IR 布局项字符流精算锚点（与 process_structured_chapter
/// 提取+规则应用+段落格式化同源、与 layout_items char_index 累加同规则：
/// Text = text.chars()+1 段落 newline；Image = 0；Table = Σ单元格段落(chars+1)）。
/// A30b：replace_rules 在段落格式化前块级应用（与展示路径同函数同时机，
/// 锚点/摘录基于「规则后文本」——与展示口径一致）。
/// A30c：remove_duplicate_title 同步接入（先于规则，与展示同时机同语义）
fn search_epub_chapter(
    book_id: &str,
    chapter_index: usize,
    chinese_convert: u8,
    remove_duplicate_title: bool,
    rules: &[ReplaceRule],
    needles: &[Vec<char>],
    hits: &mut Vec<SearchHit>,
    max_hits: usize,
) -> anyhow::Result<()> {
    let convert_mode = match chinese_convert {
        1 => book_parser::content_cleaner::ConvertMode::SimplifiedToTraditional,
        2 => book_parser::content_cleaner::ConvertMode::TraditionalToSimplified,
        _ => book_parser::content_cleaner::ConvertMode::None,
    };
    // IR 提取（写锁内，parser 独占可变状态——与分页路径同模式）。
    // font_size 仅影响 IR 的图片尺寸提示，与文本锚点无关——搜索取默认基准。
    let (content, raw_title) = {
        let mut books = BOOKS.write().unwrap();
        let handle = books
            .get_mut(book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        let structured = handle
            .structured
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("非结构化书籍"))?;
        let content = structured
            .parser
            .get_chapter_content_structured_ex(
                chapter_index,
                convert_mode,
                book_parser::epub_parser::DEFAULT_BASE_FONT_PX,
            )?;
        let raw_title = handle
            .book
            .chapters
            .get(chapter_index)
            .map(|c| c.title.clone())
            .unwrap_or_default();
        (content, raw_title)
    };
    let mut content = content;

    // A30c：去重标题——与 process_structured_chapter 同时机同语义
    if remove_duplicate_title {
        let title_cmp = match chinese_convert {
            1 => book_parser::chinese_convert::convert_s2t(&raw_title),
            2 => book_parser::chinese_convert::convert_t2s(&raw_title),
            _ => raw_title,
        };
        remove_duplicate_title_blocks(&mut content.blocks, &title_cmp);
    }

    // A30b：用户替换规则块级应用——与 process_structured_chapter 同函数
    // 同时机（先规则后段落格式化），锚点字符流与展示天然同源
    if !rules.is_empty() {
        let pre = get_preprocessor_for_rules(rules);
        apply_replace_rules_to_blocks(&mut content.blocks, pre.as_ref())?;
    }

    {
        let para_settings = PARAGRAPH_FORMAT_SETTINGS.lock().unwrap().clone();
        if para_settings.needs_formatting() {
            apply_paragraph_format_settings(&mut content.blocks, &para_settings);
        }
    }
    // 块流 → 布局项（与分页路径调用同一函数，规则零漂移）
    let mut items = Vec::with_capacity(content.blocks.len());
    blocks_to_layout_items(&content.blocks, &mut items);

    let mut accumulated = 0usize;
    for item in &items {
        if hits.len() >= max_hits {
            return Ok(());
        }
        match item {
            layout_engine::LayoutItem::Text(t) => {
                let text_chars: Vec<char> = t.text.chars().collect();
                if text_chars.is_empty() {
                    continue;
                }
                merge_needle_hits(
                    &text_chars,
                    needles,
                    hits,
                    chapter_index,
                    accumulated,
                    max_hits,
                );
                // +1 段落 newline（layout_items :803）
                accumulated += text_chars.len() + 1;
            }
            layout_engine::LayoutItem::Image { .. } => {}
            layout_engine::LayoutItem::Table(table) => {
                for row in &table.rows {
                    for cell in row {
                        for titem in &cell.items {
                            let text_chars: Vec<char> = titem.text.chars().collect();
                            if text_chars.is_empty() {
                                continue;
                            }
                            merge_needle_hits(
                                &text_chars,
                                needles,
                                hits,
                                chapter_index,
                                accumulated,
                                max_hits,
                            );
                            // +1 段落 newline（layout_table :1828）
                            accumulated += text_chars.len() + 1;
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

/// Release book from memory
pub fn release_book(book_id: String) -> anyhow::Result<()> {
    let mut books = BOOKS.write().unwrap();
    books.remove(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

    // 两种格式的分页缓存都随书籍释放而失效。
    PAGINATION_CACHE.lock().unwrap().clear_book(&book_id);
    clear_structured_pagination_cache_for_book(&book_id);
    invalidate_preprocessed_cache(Some(book_id.as_str()));

    Ok(())
}

// ===== 书源解析引擎 API =====

/// Load book source from JSON string
/// Returns book source URL as identifier
pub fn load_book_source(source_json: String) -> anyhow::Result<String> {
    let source: book_source_engine::BookSource = serde_json::from_str(&source_json)?;
    let source_url = source.book_source_url.clone();
    
    // Store in a global map (simplified: just validate it can be parsed)
    // In real implementation, you'd store this in a HashMap<String, BookSource>
    Ok(source_url)
}

/// Load book source from FfiBookSource
pub fn load_book_source_ffi(source: FfiBookSource) -> anyhow::Result<String> {
    let book_source = source.to_book_source();
    let source_url = book_source.book_source_url.clone();
    
    // Store in a global map
    // For now, just validate the source
    Ok(source_url)
}

/// Get book source as JSON string
pub fn get_book_source_json(source_url: String) -> anyhow::Result<String> {
    // This would retrieve from a global storage
    // For now, return error if not found
    Err(anyhow::anyhow!("Book source not found: {}", source_url))
}

/// Search books using a book source
/// Returns JSON array of search results
pub async fn search_book(
    source: FfiBookSource,
    keyword: String,
) -> anyhow::Result<String> {
    let book_source = source.to_book_source();
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let results = engine.search(&book_source, &keyword).await?;
    
    let ffi_results: Vec<FfiSearchBookItem> = results
        .into_iter()
        .map(FfiSearchBookItem::from)
        .collect();
    
    serde_json::to_string(&ffi_results)
        .map_err(|e| anyhow::anyhow!("Failed to serialize results: {}", e))
}

/// Search books using source JSON string
pub async fn search_book_by_json(
    source_json: String,
    keyword: String,
) -> anyhow::Result<String> {
    let source: book_source_engine::BookSource = serde_json::from_str(&source_json)?;
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let results = engine.search(&source, &keyword).await?;
    
    let ffi_results: Vec<FfiSearchBookItem> = results
        .into_iter()
        .map(FfiSearchBookItem::from)
        .collect();
    
    serde_json::to_string(&ffi_results)
        .map_err(|e| anyhow::anyhow!("Failed to serialize results: {}", e))
}

/// Get book info from a book source
/// Returns JSON string of book info
pub async fn get_book_info(
    source: FfiBookSource,
    book_url: String,
) -> anyhow::Result<String> {
    let book_source = source.to_book_source();
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let info = engine.get_book_info(&book_source, &book_url).await?;
    
    let ffi_info = FfiBookInfo::from(info);
    
    serde_json::to_string(&ffi_info)
        .map_err(|e| anyhow::anyhow!("Failed to serialize book info: {}", e))
}

/// Get book info using source JSON string
pub async fn get_book_info_by_json(
    source_json: String,
    book_url: String,
) -> anyhow::Result<String> {
    let source: book_source_engine::BookSource = serde_json::from_str(&source_json)?;
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let info = engine.get_book_info(&source, &book_url).await?;
    
    let ffi_info = FfiBookInfo::from(info);
    
    serde_json::to_string(&ffi_info)
        .map_err(|e| anyhow::anyhow!("Failed to serialize book info: {}", e))
}

/// Get table of contents (chapter list) from a book source
/// Returns JSON array of chapters
pub async fn get_toc(
    source: FfiBookSource,
    toc_url: String,
) -> anyhow::Result<String> {
    let book_source = source.to_book_source();
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let chapters = engine.get_toc(&book_source, &toc_url).await?;
    
    let ffi_chapters: Vec<FfiChapterInfo> = chapters
        .into_iter()
        .map(FfiChapterInfo::from)
        .collect();
    
    serde_json::to_string(&ffi_chapters)
        .map_err(|e| anyhow::anyhow!("Failed to serialize chapters: {}", e))
}

/// Get table of contents using source JSON string
pub async fn get_toc_by_json(
    source_json: String,
    toc_url: String,
) -> anyhow::Result<String> {
    let source: book_source_engine::BookSource = serde_json::from_str(&source_json)?;
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let chapters = engine.get_toc(&source, &toc_url).await?;
    
    let ffi_chapters: Vec<FfiChapterInfo> = chapters
        .into_iter()
        .map(FfiChapterInfo::from)
        .collect();
    
    serde_json::to_string(&ffi_chapters)
        .map_err(|e| anyhow::anyhow!("Failed to serialize chapters: {}", e))
}

/// Get chapter content from a book source
/// Returns JSON string of chapter content
pub async fn get_chapter_content_from_source(
    source: FfiBookSource,
    chapter_url: String,
) -> anyhow::Result<String> {
    let book_source = source.to_book_source();
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let content = engine.get_content(&book_source, &chapter_url).await?;
    
    let ffi_content = FfiChapterContent::from(content);
    
    serde_json::to_string(&ffi_content)
        .map_err(|e| anyhow::anyhow!("Failed to serialize chapter content: {}", e))
}

/// Get chapter content using source JSON string
pub async fn get_chapter_content_from_source_json(
    source_json: String,
    chapter_url: String,
) -> anyhow::Result<String> {
    let source: book_source_engine::BookSource = serde_json::from_str(&source_json)?;
    
    let engine = BOOK_SOURCE_ENGINE.lock().await;
    let content = engine.get_content(&source, &chapter_url).await?;
    
    let ffi_content = FfiChapterContent::from(content);
    
    serde_json::to_string(&ffi_content)
        .map_err(|e| anyhow::anyhow!("Failed to serialize chapter content: {}", e))
}

/// List all loaded book sources (placeholder)
pub fn list_book_sources() -> anyhow::Result<String> {
    // This would retrieve all stored book sources
    // For now, return empty array
    Ok("[]".to_string())
}

/// Delete a book source
pub fn delete_book_source(_source_url: String) -> anyhow::Result<()> {
    // This would remove from storage
    // For now, just acknowledge
    Ok(())
}

/// Enable/disable a book source
pub fn set_book_source_enabled(
    _source_url: String, 
    _enabled: bool
) -> anyhow::Result<()> {
    // This would update the source in storage
    // For now, just acknowledge
    Ok(())
}

// ===== 优化版分页 API（带缓存） =====

/// Get specific page with caching (优化版，使用分页缓存)
pub fn get_page_cached(
    book_id: String,
    chapter_index: usize,
    page_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
) -> anyhow::Result<PageInfo> {
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    // 委托统一实现：全关处理选项 = 原文行为；同样享受 options_hash 隔离的 LRU 缓存
    let pages = process_and_layout_chapter(
        &book_id,
        chapter_index,
        &config,
        false,
        false,
        0,
        &[],
        &[],
        0,
    )?;

    pages
        .get(page_index)
        .cloned()
        .map(PageInfo::from)
        .ok_or_else(|| anyhow::anyhow!("Page {} not found", page_index))
}

/// Get page count with caching (优化版，使用分页缓存)
pub fn get_page_count_cached(
    book_id: String,
    chapter_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
) -> anyhow::Result<usize> {
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    // 委托统一实现（全关处理选项 = 原文行为）
    let pages = process_and_layout_chapter(
        &book_id,
        chapter_index,
        &config,
        false,
        false,
        0,
        &[],
        &[],
        0,
    )?;

    Ok(pages.len())
}

/// Get specific page with caching and preprocessing (最优化版本)
pub fn get_page_cached_processed(
    book_id: String,
    chapter_index: usize,
    page_index: usize,
    width: f32,
    height: f32,
    font_size: f32,
    line_height_multiplier: f32,
    padding_left: f32,
    padding_top: f32,
    padding_right: f32,
    padding_bottom: f32,
    font_name: String,
    remove_duplicate_title: bool,
    re_segment: bool,
    chinese_convert: u8,
) -> anyhow::Result<PageInfo> {
    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier,
        padding: EdgeInsets {
            left: padding_left,
            top: padding_top,
            right: padding_right,
            bottom: padding_bottom,
        },
        font_name: font_name.clone(),
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };
    
    // 生成缓存键（需要包含预处理参数）
    let cache_key = CacheKey::new(&book_id, chapter_index, &config);
    
    // 尝试从缓存获取
    let cached_pages = {
        let mut cache = PAGINATION_CACHE.lock().unwrap();
        cache.get(&cache_key).cloned()
    };
    
    let pages = if let Some(cached) = cached_pages {
        // 缓存命中
        cached.pages
    } else {
        // 缓存未命中，获取预处理后的内容并排版
        let content = get_chapter_content_processed(
            book_id.clone(),
            chapter_index,
            remove_duplicate_title,
            re_segment,
            chinese_convert,
        )?;
        
        let font_manager = FONT_MANAGER.lock().unwrap().clone();
        let engine = build_layout_engine(config.clone(), font_manager);
        let pages = std::sync::Arc::new(engine.layout_text(&content, chapter_index)?);

        // 存入缓存
        let mut cache = PAGINATION_CACHE.lock().unwrap();
        cache.put(
            cache_key,
            CachedChapterPages {
                pages: std::sync::Arc::clone(&pages),
                total_pages: pages.len(),
                created_at: Instant::now(),
            },
        );

        pages
    };
    
    // 返回指定页
    pages.get(page_index)
        .cloned()
        .map(PageInfo::from)
        .ok_or_else(|| anyhow::anyhow!("Page {} not found", page_index))
}

/// 获取分页缓存统计信息（用于性能调试）
pub fn get_pagination_cache_stats() -> anyhow::Result<String> {
    let cache = PAGINATION_CACHE.lock().unwrap();
    let stats = cache.stats();
    Ok(stats.to_string())
}

/// 清除指定书籍的分页缓存
pub fn clear_pagination_cache_for_book(book_id: String) -> anyhow::Result<()> {
    PAGINATION_CACHE.lock().unwrap().clear_book(&book_id);
    clear_structured_pagination_cache_for_book(&book_id);
    invalidate_preprocessed_cache(Some(book_id.as_str()));
    Ok(())
}

/// 清除所有分页缓存
pub fn clear_all_pagination_cache() -> anyhow::Result<()> {
    PAGINATION_CACHE.lock().unwrap().clear();
    STRUCTURED_PAGINATION_CACHE.lock().unwrap().clear();
    invalidate_preprocessed_cache(None);
    Ok(())
}

// ===== 统一加载 API =====

/// FFI 加载进度状态
#[derive(Debug, Clone)]
pub struct FfiLoadingProgress {
    /// 进度值 (0.0 - 1.0)
    pub progress: f32,
    /// 状态描述消息
    pub message: String,
    /// 当前阶段
    pub stage: String,
}

/// FFI 书籍元信息
#[derive(Debug, Clone)]
pub struct FfiBookMetadata {
    /// 书籍 ID
    pub book_id: String,
    /// 书名
    pub title: String,
    /// 作者
    pub author: String,
    /// 总章节数
    pub total_chapters: usize,
    /// 文件格式
    pub format: String,
}

/// 检测文件格式
///
/// 返回格式名称："txt", "epub", "unknown"
pub fn detect_book_format(file_path: String) -> anyhow::Result<String> {
    let format = book_parser::loader::BookSourceLoader::get_format(&file_path)?;
    Ok(format.extension().to_string())
}

/// 获取书籍信息
pub fn get_book_info_by_id(book_id: String) -> anyhow::Result<FfiBookMetadata> {
    let books = BOOKS.read().unwrap();
    let handle = books.get(&book_id)
        .ok_or_else(|| anyhow::anyhow!("书籍未找到: {}", book_id))?;

    Ok(FfiBookMetadata {
        book_id,
        title: handle.book.title.clone(),
        author: String::new(), // 旧 API 没有 author 字段
        total_chapters: handle.book.chapters.len(),
        format: "txt".to_string(), // 旧 API 默认 TXT
    })
}

// ===== 统一书籍解析 API（支持 TXT + EPUB） =====

/// 检测文件格式并返回详细信息
pub fn detect_format_detailed(file_path: String) -> anyhow::Result<FfiFormatInfo> {
    let result = book_parser::loader::BookSourceLoader::detect_format_detailed(
        std::path::Path::new(&file_path)
    )?;

    Ok(FfiFormatInfo {
        format: result.format.extension().to_string(),
        format_name: result.format.display_name().to_string(),
        method: format!("{:?}", result.method),
        confidence: result.confidence,
    })
}

/// FFI 格式检测结果
#[derive(Debug, Clone)]
pub struct FfiFormatInfo {
    pub format: String,
    pub format_name: String,
    pub method: String,
    pub confidence: f32,
}

// ===== ReadSession FFI =====

/// 全局 ReadSessionManager
static SESSION_MANAGER: Lazy<Arc<Mutex<ReadSessionManager>>> = Lazy::new(|| {
    Arc::new(Mutex::new(ReadSessionManager::with_max_sessions(5)))
});

/// 创建阅读会话
pub fn create_reading_session(
    file_path: String,
    width: f32,
    height: f32,
    font_size: f32,
    font_name: String,
) -> anyhow::Result<String> {
    let mut parser = book_parser::loader::BookSourceLoader::load(&file_path)?;

    let config = LayoutConfig {
        width,
        height,
        font_size,
        line_height_multiplier: 1.5,
        padding: EdgeInsets {
            left: 20.0,
            top: 20.0,
            right: 20.0,
            bottom: 20.0,
        },
        font_name,
        letter_spacing: 0.0,
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
        justify: effective_justify(),
        punctuation_compress: effective_punct_compress(),
    };

    let book_id = format!("session_{}", uuid::Uuid::new_v4());

    let manager = SESSION_MANAGER.lock().unwrap();
    manager.create_session(book_id.clone(), &mut parser, config)?;

    Ok(book_id)
}

/// 获取会话的书籍信息
pub fn get_session_book_info(session_id: String) -> anyhow::Result<FfiBookMetadata> {
    let manager = SESSION_MANAGER.lock().unwrap();
    let session = manager.get_session(&session_id)
        .ok_or_else(|| anyhow::anyhow!("会话未找到: {}", session_id))?;

    Ok(FfiBookMetadata {
        book_id: session_id,
        title: session.metadata.title.clone(),
        author: session.metadata.author.clone(),
        total_chapters: session.total_chapters(),
        format: session.metadata.format.extension().to_string(),
    })
}

/// 获取会话的章节列表
pub fn get_session_chapters(session_id: String) -> anyhow::Result<Vec<ChapterInfo>> {
    let manager = SESSION_MANAGER.lock().unwrap();
    let session = manager.get_session(&session_id)
        .ok_or_else(|| anyhow::anyhow!("会话未找到: {}", session_id))?;

    Ok(session.chapters.iter().map(|ch| {
        ChapterInfo {
            title: ch.title.clone(),
            start_pos: ch.start_byte_offset.unwrap_or(0),
            end_pos: ch.end_byte_offset.unwrap_or(0),
            level: ch.level,
            parent_index: ch.parent_index,
        }
    }).collect())
}

/// 获取会话的指定章节内容
pub fn get_session_chapter_content(
    session_id: String,
    chapter_index: usize,
) -> anyhow::Result<String> {
    let manager = SESSION_MANAGER.lock().unwrap();
    let session = manager.get_session(&session_id)
        .ok_or_else(|| anyhow::anyhow!("会话未找到: {}", session_id))?;

    // 根据格式获取内容
    match session.metadata.format {
        BookFormat::Txt => {
            // TXT 格式：使用偏移量切片
            if let Some(chapter) = session.chapters.get(chapter_index) {
                if chapter.start_byte_offset.is_some() && chapter.end_byte_offset.is_some() {
                    // 需要重新打开文件读取内容
                    // 这是一个简化实现，实际应该使用缓存
                    return Err(anyhow::anyhow!("TXT 章节内容获取需要文件路径"));
                }
            }
            Err(anyhow::anyhow!("章节不存在"))
        }
        BookFormat::Epub => {
            Err(anyhow::anyhow!("EPUB 章节内容获取需要解析器"))
        }
        _ => Err(anyhow::anyhow!("不支持的格式"))
    }
}

/// 关闭阅读会话
pub fn close_session(session_id: String) -> anyhow::Result<()> {
    let manager = SESSION_MANAGER.lock().unwrap();
    manager.remove_session(&session_id);
    Ok(())
}

/// 获取活跃会话数量
pub fn get_active_session_count() -> usize {
    let manager = SESSION_MANAGER.lock().unwrap();
    manager.session_count()
}

// ===== 预加载系统 FFI =====

/// 预加载运行时：执行器 + 泄漏 Tokio Runtime 的句柄
/// （worker 线程挂在泄漏的 Runtime 上；handle 供外部 spawn 提交任务，
/// 消除历史上每次触发的 thread::spawn + Runtime::new 风暴）
struct PreloadRuntime {
    executor: Arc<PreloadExecutor>,
    handle: tokio::runtime::Handle,
}

static PRELOAD_RUNTIME: OnceLock<PreloadRuntime> = OnceLock::new();

fn get_preload_runtime() -> &'static PreloadRuntime {
    PRELOAD_RUNTIME.get_or_init(|| {
        let rt = tokio::runtime::Runtime::new().expect("Failed to create Tokio runtime");
        let handle = rt.handle().clone();
        let executor = rt.block_on(async {
            Arc::new(PreloadExecutor::new_with_book_id(
                PreloadExecutorConfig::default(),
                |book_id, chapter_index| match preload_txt_warm(book_id, chapter_index) {
                    // 预热目的在副作用（分页缓存回填），返回值仅作诊断
                    Ok(true) => Ok(format!("warmed ch{}", chapter_index)),
                    Ok(false) => Ok("skipped (no snapshot)".to_string()),
                    Err(e) => Err(e),
                },
            ))
        });
        // 泄漏运行时保活 worker；handle 已克隆可继续使用
        std::mem::forget(rt);
        PreloadRuntime { executor, handle }
    })
}

/// 获取或初始化预加载执行器
fn get_preload_executor() -> Arc<PreloadExecutor> {
    get_preload_runtime().executor.clone()
}

/// 获取预加载统计信息
pub fn get_preload_stats() -> anyhow::Result<FfiPreloadStats> {
    let executor = get_preload_executor();
    let stats = executor.stats();
    Ok(FfiPreloadStats {
        total_tasks: stats.total_tasks.load(std::sync::atomic::Ordering::Relaxed),
        completed_tasks: stats.completed_tasks.load(std::sync::atomic::Ordering::Relaxed),
        failed_tasks: stats.failed_tasks.load(std::sync::atomic::Ordering::Relaxed),
        cancelled_tasks: stats.cancelled_tasks.load(std::sync::atomic::Ordering::Relaxed),
    })
}

/// FFI 预加载统计信息
#[derive(Debug, Clone)]
pub struct FfiPreloadStats {
    pub total_tasks: usize,
    pub completed_tasks: usize,
    pub failed_tasks: usize,
    pub cancelled_tasks: usize,
}

// ===== 增强的预处理管道 FFI =====

/// 使用增强的预处理管道处理章节内容
pub fn process_chapter_content(
    book_id: String,
    chapter_index: usize,
    config: Option<FfiProcessOptions>,
) -> anyhow::Result<String> {
    // 1. 获取配置
    let ffi_config = config.unwrap_or_default();
    
    // 2. 获取原始内容
    let raw_content = get_chapter_content(book_id.clone(), chapter_index, ffi_config.remove_duplicate_title)?;

    // 2. 获取章节标题
    let chapter_title = {
        let books = BOOKS.read().unwrap();
        let handle = books.get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        handle.book.chapters.get(chapter_index)
            .map(|ch| ch.title.clone())
            .unwrap_or_default()
    };

    // 3. 构建处理选项
    let options = ProcessOptions {
        book_name: String::new(),
        title: chapter_title,
        chapter_index,
        remove_duplicate_title: ffi_config.remove_duplicate_title,
        re_segment: ffi_config.re_segment,
        segment_rules: Vec::new(),
        chinese_convert: match ffi_config.chinese_convert {
            1 => Some(ChineseConvertType::S2T),
            2 => Some(ChineseConvertType::T2S),
            _ => None,
        },
        adapt_special_style: ffi_config.adapt_special_style,
        apply_user_markings: false,
    };

    // 4. 使用增强的预处理管道
    let preprocessor = CONTENT_PREPROCESSOR.clone();
    let processed = tokio::runtime::Runtime::new()?
        .block_on(preprocessor.process(&raw_content, &options))?;

    Ok(processed)
}

/// FFI 处理选项
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiProcessOptions {
    pub remove_duplicate_title: bool,
    pub re_segment: bool,
    pub chinese_convert: u8, // 0=none, 1=s2t, 2=t2s, 3=s2tw, 4=s2hk
    pub adapt_special_style: bool,
}

impl Default for FfiProcessOptions {
    fn default() -> Self {
        Self {
            remove_duplicate_title: true,
            re_segment: false,
            chinese_convert: 0,
            adapt_special_style: true,
        }
    }
}

/// 批量处理多个章节（异步）
pub async fn batch_process_chapters(
    book_id: String,
    chapter_indices: Vec<usize>,
    options: FfiProcessOptions,
) -> anyhow::Result<Vec<String>> {
    let mut results = Vec::new();

    for &chapter_index in &chapter_indices {
        let result = process_chapter_content(
            book_id.clone(),
            chapter_index,
            Some(options.clone()),
        )?;
        results.push(result);
    }

    Ok(results)
}

// ===== 缓存管理 FFI =====

/// 清除指定书籍的分页缓存
pub fn clear_book_cache(book_id: String) -> anyhow::Result<()> {
    PAGINATION_CACHE.lock().unwrap().clear_book(&book_id);
    clear_structured_pagination_cache_for_book(&book_id);
    invalidate_preprocessed_cache(Some(book_id.as_str()));
    Ok(())
}

/// 清除所有缓存
pub fn clear_all_caches() -> anyhow::Result<()> {
    PAGINATION_CACHE.lock().unwrap().clear();
    STRUCTURED_PAGINATION_CACHE.lock().unwrap().clear();
    invalidate_preprocessed_cache(None);
    Ok(())
}

/// 获取缓存统计信息
pub fn get_cache_statistics() -> anyhow::Result<FfiCacheStats> {
    let cache = PAGINATION_CACHE.lock().unwrap();
    let stats = cache.stats();
    Ok(FfiCacheStats {
        hits: stats.hit_count,
        misses: stats.miss_count,
        size: stats.size,
        capacity: stats.capacity,
    })
}

/// FFI 缓存统计信息
#[derive(Debug, Clone)]
pub struct FfiCacheStats {
    pub hits: u64,
    pub misses: u64,
    pub size: usize,
    pub capacity: usize,
}

// ===== 编码诊断 API =====

/// 诊断文件编码
pub fn diagnose_file_encoding_api(file_path: String) -> anyhow::Result<String> {
    let diagnostic = diagnose_file_encoding(&file_path)?;
    
    Ok(format!(
        "=== 文件编码诊断 ===\n\
        文件路径: {}\n\
        检测编码: {}\n\
        字节长度: {}\n\
        字符长度: {}\n\
        UTF-8有效: {}\n\
        有解码错误: {}\n\n\
        前100字符样本:\n{}\n",
        file_path,
        diagnostic.detected_encoding,
        diagnostic.byte_length,
        diagnostic.char_length,
        diagnostic.is_valid_utf8,
        diagnostic.has_errors,
        diagnostic.sample_text
    ))
}

/// 诊断章节内容编码
pub fn diagnose_chapter_encoding_api(
    book_id: String,
    chapter_index: usize,
) -> anyhow::Result<String> {
    // 获取原始章节内容
    let content = get_chapter_content(book_id.clone(), chapter_index, false)?;
    
    // 诊断内容
    let diagnostic_info = diagnose_chapter_content(&content)?;
    
    // 获取章节标题
    let chapter_title = {
        let books = BOOKS.read().unwrap();
        let handle = books.get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        handle.book.chapters.get(chapter_index)
            .map(|ch| ch.title.clone())
            .unwrap_or_default()
    };
    
    Ok(format!(
        "=== 章节内容诊断 ===\n\
        书籍ID: {}\n\
        章节索引: {}\n\
        章节标题: {}\n\n\
        {}\n",
        book_id,
        chapter_index,
        chapter_title,
        diagnostic_info
    ))
}

/// 对比原始内容和处理后内容
pub fn compare_raw_and_processed_content(
    book_id: String,
    chapter_index: usize,
) -> anyhow::Result<String> {
    // 1. 获取原始内容
    let raw_content = get_chapter_content(book_id.clone(), chapter_index, false)?;
    
    // 2. 获取处理后的内容
    let processed_content = get_chapter_content_processed(
        book_id.clone(),
        chapter_index,
        true,  // remove_duplicate_title
        false, // re_segment
        0,     // no chinese convert
    )?;
    
    // 3. 对比统计
    let raw_char_count = raw_content.chars().count();
    let raw_byte_count = raw_content.len();
    let raw_line_count = raw_content.lines().count();
    let raw_replacement_chars = raw_content.chars().filter(|&c| c == '�').count();
    
    let processed_char_count = processed_content.chars().count();
    let processed_byte_count = processed_content.len();
    let processed_line_count = processed_content.lines().count();
    let processed_replacement_chars = processed_content.chars().filter(|&c| c == '�').count();
    
    // 4. 获取样本
    let raw_sample: String = raw_content.chars().take(200).collect();
    let processed_sample: String = processed_content.chars().take(200).collect();
    
    Ok(format!(
        "=== 原始内容 vs 处理后内容对比 ===\n\n\
        【原始内容】\n\
        字符数: {}\n\
        字节数: {}\n\
        行数: {}\n\
        替换字符(�): {}\n\n\
        前200字符:\n{}\n\n\
        【处理后内容】\n\
        字符数: {}\n\
        字节数: {}\n\
        行数: {}\n\
        替换字符(�): {}\n\n\
        前200字符:\n{}\n\n\
        【差异】\n\
        字符数变化: {} ({:+})\n\
        字节数变化: {} ({:+})\n\
        行数变化: {} ({:+})\n\
        替换字符变化: {} ({:+})\n",
        raw_char_count, raw_byte_count, raw_line_count, raw_replacement_chars,
        raw_sample,
        processed_char_count, processed_byte_count, processed_line_count, processed_replacement_chars,
        processed_sample,
        processed_char_count, processed_char_count as i64 - raw_char_count as i64,
        processed_byte_count, processed_byte_count as i64 - raw_byte_count as i64,
        processed_line_count, processed_line_count as i64 - raw_line_count as i64,
        processed_replacement_chars, processed_replacement_chars as i64 - raw_replacement_chars as i64,
    ))
}

// 死 FFI 已删（Dart 零调用，AGENTS.md「确定无用彻底删」）：
// preload_chapter / get_preload_queue_depth / cancel_preload——
// 相邻章预热由 get_chapter_content 尾部自动触发（trigger_preload_async）

/// M9.3 测试探针：trigger_preload_async 调用计数（级联打断回归用）
#[cfg(test)]
static PRELOAD_TRIGGER_CALLS: std::sync::atomic::AtomicUsize =
    std::sync::atomic::AtomicUsize::new(0);

/// M9.3：串行化依赖全局单槽 LAST_TXT_LAYOUT_SNAPSHOT 的预热测试
/// （cargo test 多线程并发会互相覆盖快照导致偶发断言失败）
#[cfg(test)]
static PRELOAD_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as IoWrite;

    /// M9.4-F：SHARED_GLYPH_CACHE 首次取用即触发 prewarm，
    /// 且热路径键（font_name="default", font_size=18.0）直接命中预热条目
    #[test]
    fn shared_glyph_cache_prewarmed_and_shared() {
        let cache = SHARED_GLYPH_CACHE.lock().unwrap();
        assert!(cache.stats().len > 0, "首次取用应已触发 prewarm");

        // glyph_cache() 为 O(1) Arc 共享克隆——prewarm 条目对热路径可见
        let key = layout_engine::GlyphKey::new('的', 18.0, "default");
        assert!(
            cache.glyph_cache().get(&key).is_some(),
            "热路径键应命中预热条目"
        );
    }

    /// M6-S1：TXT 预加载真预热——load_fn 副作用（分页缓存回填）验证。
    /// 旧实现只读原始文本即丢弃、对缓存零贡献；本测试锁定「预热→命中」语义
    /// M9.5-G：预处理缓存接入——para_format_hash 变更击穿分页缓存键后，
    /// 同章重读应命中预处理缓存（预处理键不含 para_format_hash，
    /// 段落格式化在缓存之后执行、不影响预处理输出）。
    #[test]
    fn preprocessed_cache_hit_and_para_format_neutrality() {
        let _serial = PRELOAD_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

        let dir = std::env::temp_dir().join(format!("preproc_cache_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("preproc.txt");
        std::fs::write(
            &txt_path,
            "第一章 起点\n\n正文内容第一段落。\n\n第二章 终点\n\n第二章节的正文内容。\n",
        )
        .unwrap();

        let book_id =
            parse_txt_file(txt_path.to_string_lossy().to_string(), None).expect("TXT 导入失败");

        let read = |para_hash: u64| {
            get_page_processed(
                book_id.clone(),
                0,
                0,
                360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
                "TestFont".to_string(),
                false, false, 0, Vec::new(), Vec::new(), None, 0.9, para_hash,
            )
            .expect("前台读取失败")
        };

        // 首次读取：预处理缓存 miss → 回填（若此前已有同键条目则为 hit，不影响断言）
        let _ = read(0);
        let stats_first = shared_tokio_runtime().block_on(PREPROCESSED_CACHE.stats());

        // 换 para_format_hash → 分页缓存换键 miss → 深入到预处理层；
        // 预处理键 para_format_hash 置 0 → 应命中
        let _ = read(0x1234);
        let stats_second = shared_tokio_runtime().block_on(PREPROCESSED_CACHE.stats());

        assert!(
            stats_second.hits > stats_first.hits,
            "para_format_hash 变更后同章重读应命中预处理缓存（hits {} → {}）",
            stats_first.hits,
            stats_second.hits
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn preload_txt_warm_fills_pagination_cache() {
        let _serial = PRELOAD_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

        let dir = std::env::temp_dir().join(format!("txt_preload_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("preload.txt");
        std::fs::write(
            &txt_path,
            "第一章 起点\n\n正文内容第一段落。\n\n第二章 终点\n\n第二章节的正文内容。\n",
        )
        .unwrap();

        let book_id =
            parse_txt_file(txt_path.to_string_lossy().to_string(), None).expect("TXT 导入失败");

        // 前台读 ch0：建立排版快照
        get_page_processed(
            book_id.clone(),
            0,
            0,
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(),
            false, false, 0, Vec::new(), Vec::new(), None, 0.9, 0,
        )
        .expect("ch0 前台读取失败");

        // 预热 ch1（与 load_fn 同路径）
        assert!(
            preload_txt_warm(&book_id, 1).expect("预热失败"),
            "有快照时应执行预热"
        );

        // 同参前台读取 ch1 应命中缓存（预热回填生效）
        let hits_before = get_cache_statistics().unwrap().hits;
        get_page_processed(
            book_id.clone(),
            1,
            0,
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(),
            false, false, 0, Vec::new(), Vec::new(), None, 0.9, 0,
        )
        .expect("ch1 前台读取失败");
        let hits_after = get_cache_statistics().unwrap().hits;
        assert!(hits_after > hits_before, "预热后的同参调用应命中分页缓存");

        // 无快照的书 → 跳过不报错
        assert!(!preload_txt_warm("nonexistent-book", 0).unwrap());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn preload_txt_warm_does_not_retrigger_preload() {
        let _serial = PRELOAD_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // M9.3 级联打断回归：预加载路径（allow_preload_trigger=false）回源
        // miss 时严禁再触发 trigger_preload_async——否则自激级联推进到全书
        // 末尾、冲刷 LRU，前台翻页退化为同步全章重排（卡顿根因 H1）
        let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

        let dir = std::env::temp_dir().join(format!("txt_cascade_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("cascade.txt");
        let mut content = String::new();
        for i in 1..=3 {
            content.push_str(&format!("第{}章 测试\n\n第{i}章的正文内容，足够触发排版。\n\n", i));
        }
        std::fs::write(&txt_path, &content).unwrap();

        let book_id =
            parse_txt_file(txt_path.to_string_lossy().to_string(), None).expect("TXT 导入失败");

        // 前台读 ch0 建立快照（此过程允许触发预热）
        get_page_processed(
            book_id.clone(),
            0,
            0,
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(),
            false, false, 0, Vec::new(), Vec::new(), None, 0.9, 0,
        )
        .expect("ch0 前台读取失败");

        // 等待前台读取引发的异步预热波平息
        std::thread::sleep(std::time::Duration::from_millis(500));

        // 归零探针前重建快照（防并发测试窗口覆盖），随后走预热路径
        // （ch2 未读过 → 必然 miss 回源）
        get_page_processed(
            book_id.clone(),
            0,
            0,
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(),
            false, false, 0, Vec::new(), Vec::new(), None, 0.9, 0,
        )
        .expect("ch0 快照重建失败");
        std::thread::sleep(std::time::Duration::from_millis(300));
        PRELOAD_TRIGGER_CALLS.store(0, std::sync::atomic::Ordering::Relaxed);
        assert!(
            preload_txt_warm(&book_id, 2).expect("预热失败"),
            "有快照时应执行预热"
        );

        // 若存在泄漏触发，会在此窗口内异步发生
        std::thread::sleep(std::time::Duration::from_millis(400));

        assert_eq!(
            PRELOAD_TRIGGER_CALLS.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "预加载路径回源不得再触发预热（级联打断失效）"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ===== M9.1：EPUB 段落格式化（切短 + 缩进覆盖） =====

    use book_parser::ContentBlock;
    use reader_core::{ParagraphFormatSettings, ReParagraphMode};

    fn para(text: &str) -> ContentBlock {
        ContentBlock::paragraph(text)
    }

    fn para_text(b: &ContentBlock) -> &str {
        match b {
            ContentBlock::Paragraph { text, .. } => text,
            other => panic!("应为段落，实为 {:?}", other),
        }
    }

    fn settings(mode: ReParagraphMode, indent: bool) -> ParagraphFormatSettings {
        ParagraphFormatSettings {
            enable_indent: indent,
            indent_size_chars: 2,
            paragraph_spacing_multiplier: 1.0,
            re_paragraph_mode: mode,
            smart_split_threshold: reader_core::SMART_THRESHOLD,
            aggressive_split_threshold: reader_core::AGGRESSIVE_THRESHOLD,
            justify: false,
            punctuation_compress: false,
        }
    }

    /// 长文本：n 句，每句恰 11 字（10 汉字 + 句号）
    fn long_text(sentences: usize) -> String {
        "一二三四五六七八九十。".repeat(sentences)
    }

    #[test]
    fn epub_split_smart_over_200_chars() {
        // 28 句 = 308 字 > Smart 阈值 200（M9.2 统一）→ 应切分
        let text = long_text(28);
        assert_eq!(text.chars().count(), 308);
        let mut blocks = vec![para(&text)];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::Smart, false));

        assert!(blocks.len() >= 2, "超长段应被切开，实得 {} 块", blocks.len());
        // 拼接不变量：切分不丢字不重字
        let joined: String = blocks.iter().map(|b| para_text(b)).collect();
        assert_eq!(joined, text, "切分后拼接必须还原原文");
        // 每块 ≤ 阈值上界（闭标吸附允许略超，但不得翻倍）
        for b in &blocks {
            assert!(
                para_text(b).chars().count() <= 200 + 60,
                "切分块过长: {}",
                para_text(b).chars().count()
            );
        }
    }

    #[test]
    fn epub_split_aggressive_lower_threshold() {
        // 14 句 = 154 字：Smart(200) 不切、Aggressive(100) 切
        let text = long_text(14);
        assert_eq!(text.chars().count(), 154);
        let mut smart = vec![para(&text)];
        apply_paragraph_format_settings(&mut smart, &settings(ReParagraphMode::Smart, false));
        assert_eq!(smart.len(), 1, "154 字不应触发 Smart 切分");

        let mut agg = vec![para(&text)];
        apply_paragraph_format_settings(&mut agg, &settings(ReParagraphMode::Aggressive, false));
        assert!(agg.len() >= 2, "154 字应触发 Aggressive 切分");
        let joined: String = agg.iter().map(|b| para_text(b)).collect();
        assert_eq!(joined, text);
    }

    #[test]
    fn epub_none_mode_no_split() {
        let text = long_text(20); // 600 字
        let mut blocks = vec![para(&text)];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::None, false));
        assert_eq!(blocks.len(), 1, "None 模式不切分");
    }

    #[test]
    fn epub_indent_override_on_off() {
        // 开：覆盖为 Some(2)（即使 CSS 已物化 3em 也被替换）
        let mut b = ContentBlock::Paragraph {
            text: "测试段落".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: Some(3.0),
            spacing_after_em: None,
            line_height: None,
        };
        let mut blocks = vec![b];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::None, true));
        match &blocks[0] {
            ContentBlock::Paragraph {
                indent_first_line_em, ..
            } => assert_eq!(*indent_first_line_em, Some(2.0), "用户设置应覆盖 CSS 值"),
            _ => unreachable!(),
        }

        // 关：压制书自带缩进 → None
        b = ContentBlock::Paragraph {
            text: "测试段落".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: Some(3.0),
            spacing_after_em: None,
            line_height: None,
        };
        let mut blocks = vec![b];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::None, false));
        match &blocks[0] {
            ContentBlock::Paragraph {
                indent_first_line_em, ..
            } => assert_eq!(*indent_first_line_em, None, "关闭缩进应压制 CSS 值"),
            _ => unreachable!(),
        }
    }

    #[test]
    fn epub_comment_block_not_split() {
        // 注释块即使超长也不切分（仅缩进覆盖）
        let text = long_text(20);
        let mut b = ContentBlock::Paragraph {
            text,
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: true,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        if let ContentBlock::Paragraph {
            indent_first_line_em: ref mut f,
            ..
        } = b
        {
            *f = None;
        }
        let mut blocks = vec![b];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::Aggressive, true));
        assert_eq!(blocks.len(), 1, "注释块不切分");
        match &blocks[0] {
            ContentBlock::Paragraph {
                is_comment,
                indent_first_line_em,
                ..
            } => {
                assert!(*is_comment, "注释标记保持");
                assert_eq!(*indent_first_line_em, Some(2.0), "注释块缩进照常覆盖");
            }
            _ => unreachable!(),
        }
    }

    #[test]
    fn epub_split_runs_clip_and_shift() {
        // 20 句 = 220 字，runs 覆盖 [10,150)；Aggressive(100) 切分
        let text = long_text(20);
        assert_eq!(text.chars().count(), 220);
        let runs = vec![book_parser::StyledRun {
            start: 10,
            end: 150,
            color: Some("#ff0000".into()),
            font_scale: None,
            bold: false,
            italic: false,
            underline: false,
            anc: None,
        }];
        let mut blocks = vec![ContentBlock::Paragraph {
            text,
            align: None,
            color: None,
            font_scale: None,
            runs,
            anc: None,
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        }];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::Aggressive, false));
        assert!(blocks.len() >= 2);

        // runs 区间必须落在各块文本范围内（锚定自洽）
        for b in &blocks {
            let (t, rs) = match b {
                ContentBlock::Paragraph { text, runs, .. } => (text, runs),
                _ => unreachable!(),
            };
            let len = t.chars().count();
            for r in rs {
                assert!(r.start <= len && r.end <= len, "run 越界: [{},{}] > {}", r.start, r.end, len);
            }
        }
        // 全局覆盖不变量：所有块 runs 的原坐标拼接后仍覆盖 [10,150)
        let mut covered: Vec<(usize, usize)> = Vec::new();
        let mut offset = 0usize;
        for b in &blocks {
            if let ContentBlock::Paragraph { text, runs, .. } = b {
                for r in runs {
                    covered.push((offset + r.start, offset + r.end));
                }
                offset += text.chars().count();
            }
        }
        covered.sort();
        let merged_start = covered.first().map(|c| c.0).unwrap_or(0);
        let merged_end = covered.last().map(|c| c.1).unwrap_or(0);
        assert_eq!(merged_start, 10, "runs 起点应保持");
        assert_eq!(merged_end, 150, "runs 终点应保持（裁剪不丢样式区段）");
    }

    #[test]
    fn epub_split_preserves_align_and_glues_closer() {
        // M9.2：居中长段切分后所有子段保留 align（回归：旧实现仅首段保留）；
        // 闭引号 ” 吸附在前片尾部，不得悬到后一段段首
        let mut text = "他说完了。".repeat(30); // 150 字
        text.push('\u{201C}');
        text.push_str(&"继续讲述。".repeat(20)); // +100 字，含开引号共 251 字
        assert_eq!(text.chars().count(), 251);
        let original = text.clone();

        let mut blocks = vec![ContentBlock::Paragraph {
            text,
            align: Some(book_parser::Align::Center),
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        }];
        apply_paragraph_format_settings(&mut blocks, &settings(ReParagraphMode::Smart, false));
        // 注：末片 55 字 ≥ 20%·阈值，不会触发尾段再平衡合并
        assert!(blocks.len() >= 2, "251 字应被切开");
        for (i, b) in blocks.iter().enumerate() {
            match b {
                ContentBlock::Paragraph { align, text, .. } => {
                    assert_eq!(*align, Some(book_parser::Align::Center),
                        "子段 {} 应保留居中对齐", i);
                    if i > 0 {
                        let first = text.chars().next();
                        assert_ne!(first, Some('\u{201D}'), "子段 {} 不得以闭引号开头", i);
                    }
                }
                _ => unreachable!(),
            }
        }
        // 拼接不变量：切分不丢字不重字
        let joined: String = blocks.iter().map(|b| para_text(b)).collect();
        assert_eq!(joined, original);
    }

    #[test]
    fn table_cell_indent_forced_none_in_layout_items() {
        // M9.2 兜底层：单元格内段落即使携带 CSS 物化缩进，转 TextItem 时强制 None
        let cell_para = ContentBlock::Paragraph {
            text: "卷首信息".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: Some(2.0),
            spacing_after_em: None,
            line_height: None,
        };
        let table = ContentBlock::Table {
            caption: None,
            rows: vec![vec![book_parser::TableCell {
                header: false,
                blocks: vec![cell_para],
                anc: None,
                width_em: None,
            }]],
            anc: None,
            margin_top_percent: None,
            margin_left_auto: false,
        };
        // 对照组：顶层段落缩进应原样透传
        let top_para = ContentBlock::paragraph("正文段落");
        let mut items: Vec<layout_engine::LayoutItem> = Vec::new();
        blocks_to_layout_items(&[table, top_para], &mut items);

        let mut saw_cell_text = false;
        let mut saw_top_indent: Option<Option<f32>> = None;
        for item in &items {
            if let layout_engine::LayoutItem::Table(t) = item {
                for row in &t.rows {
                    for cell in row {
                        for ti in &cell.items {
                            assert_eq!(
                                ti.indent_first_line_em, None,
                                "单元格 TextItem 缩进必须为 None"
                            );
                            saw_cell_text = true;
                        }
                    }
                }
            }
            if let layout_engine::LayoutItem::Text(ti) = item {
                if ti.text == "正文段落" {
                    saw_top_indent = Some(ti.indent_first_line_em);
                }
            }
        }
        assert!(saw_cell_text, "应产出表格条目");
        assert_eq!(saw_top_indent, Some(None), "顶层无 CSS 缩进段落透传 None");
    }

    // ── A30：书内全文搜索对齐验证 ────────────────────────────────

    /// A30 红线验证：TXT 搜索锚点必须落页含命中词。
    /// anchor 口径 = processed + 段落格式化后文本（与 layout_text 输入同源），
    /// 本测试同时锁定「搜索管线与展示管线同源」——若任一侧规则漂移即偏页。
    #[test]
    fn search_in_book_txt_anchor_alignment() {
        let _serial = PRELOAD_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

        let dir = std::env::temp_dir().join(format!("a30_txt_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt_path = dir.join("search.txt");
        std::fs::write(
            &txt_path,
            "第一章 起点\n\n正文内容第一段落。\n\n第二章 终点\n\n第二章节的正文内容提到搜索目标词两次：搜索目标词。\n",
        )
        .unwrap();
        let book_id =
            parse_txt_file(txt_path.to_string_lossy().to_string(), None).expect("TXT 导入失败");

        let hits = search_in_book(
            book_id.clone(),
            "搜索目标词".into(),
            false,
            false,
            0,
            Vec::new(),
            Vec::new(),
            100,
        )
        .expect("搜索失败");
        assert_eq!(hits.len(), 2, "第二章应命中两次：{:?}", hits);
        assert!(hits.iter().all(|h| h.chapter_index == 1), "命中应在第二章");

        // 锚点对齐：每个命中 anchor 经 locate_page_for_offset 定位的页面
        // 文本必须包含命中词
        let config = layout_engine::LayoutConfig {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: layout_engine::EdgeInsets {
                left: 20.0,
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
            },
            font_name: "TestFont".into(),
            letter_spacing: 0.0,
            paragraph_spacing: 18.0 * 0.8,
            page_fill_threshold: 0.9,
            show_comments: true,
            justify: false,
            punctuation_compress: false,
        };
        for hit in &hits {
            let pages = process_and_layout_chapter(
                &book_id, hit.chapter_index, &config, false, false, 0, &[], &[], 0,
            )
            .expect("分页失败");
            let page_idx = locate_page_for_offset(&pages, hit.anchor_char_offset);
            let page_text: String = pages[page_idx]
                .entries
                .iter()
                .filter_map(|e| match e {
                    layout_engine::PageEntry::Text(l) => Some(l.text.clone()),
                    _ => None,
                })
                .collect();
            assert!(
                page_text.contains("搜索目标词"),
                "anchor={} 定位页应包含命中词，实际页文本：{}",
                hit.anchor_char_offset,
                page_text
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A30 红线验证：EPUB 搜索锚点必须落页含命中词（IR 字符流累计规则
    /// 与 layout_items 同源——Text chars+1 段落 newline / Image 0 / Table
    /// Σ单元格段落(chars+1)）。规则漂移即偏页，本测试是漂移探测器。
    #[test]
    fn search_in_book_epub_anchor_alignment() {
        let _serial = PRELOAD_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());

        let dir = std::env::temp_dir().join(format!("a30_epub_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("OEBPS")).unwrap();
        std::fs::create_dir_all(dir.join("META-INF")).unwrap();

        let ch1 = "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>c1</title></head><body><p>这是第一章的正文内容，藏着独特关键词蓝鲸座。</p></body></html>";
        let ch2 = "<?xml version=\"1.0\" encoding=\"utf-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>c2</title></head><body><p>第二章正文也提到蓝鲸座，还有普通句子。</p></body></html>";
        std::fs::write(dir.join("OEBPS/ch1.xhtml"), ch1).unwrap();
        std::fs::write(dir.join("OEBPS/ch2.xhtml"), ch2).unwrap();
        let container = "<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>";
        std::fs::write(dir.join("META-INF/container.xml"), container).unwrap();
        let opf = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>搜索测试书</dc:title><dc:language>zh</dc:language><dc:creator>t</dc:creator><dc:identifier id=\"id\">search-test</dc:identifier></metadata><manifest><item id=\"c1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/><itemref idref=\"c2\"/></spine></package>";
        std::fs::write(dir.join("OEBPS/content.opf"), opf).unwrap();

        let epub_path = dir.join("test.epub");
        {
            let file = std::fs::File::create(&epub_path).unwrap();
            let mut zw = zip::ZipWriter::new(file);
            let opts = zip::write::FileOptions::default();
            zw.start_file("mimetype", opts).unwrap();
            zw.write_all(b"application/epub+zip").unwrap();
            zw.start_file(
                "META-INF/container.xml",
                zip::write::FileOptions::default(),
            )
            .unwrap();
            zw.write_all(container.as_bytes()).unwrap();
            zw.start_file("OEBPS/content.opf", zip::write::FileOptions::default())
                .unwrap();
            zw.write_all(opf.as_bytes()).unwrap();
            zw.start_file("OEBPS/ch1.xhtml", zip::write::FileOptions::default())
                .unwrap();
            zw.write_all(ch1.as_bytes()).unwrap();
            zw.start_file("OEBPS/ch2.xhtml", zip::write::FileOptions::default())
                .unwrap();
            zw.write_all(ch2.as_bytes()).unwrap();
            zw.finish().unwrap();
        }

        let book_id = parse_txt_file_inner(
            epub_path.to_string_lossy().to_string(),
            None,
            None,
        )
        .expect("EPUB 导入失败");

        let hits = search_in_book(
            book_id.clone(),
            "蓝鲸座".into(),
            false,
            false,
            0,
            Vec::new(),
            Vec::new(),
            100,
        )
        .expect("搜索失败");
        assert_eq!(hits.len(), 2, "两章应各命中一次：{:?}", hits);
        assert_eq!(hits[0].chapter_index, 0);
        assert_eq!(hits[1].chapter_index, 1);

        // 锚点对齐：每个命中 anchor 经 locate_structured_page 定位的页面
        // 文本必须包含命中词
        let params = StructuredParams::from_args(
            360.0, 640.0, 18.0, 1.5, 20.0, 20.0, 20.0, 20.0,
            "TestFont".to_string(), 0, 0.9, true, 0, false, Vec::new(),
        );
        for hit in &hits {
            let pages = process_structured_chapter(&book_id, hit.chapter_index, &params, false)
                .expect("分页失败")
                .expect("前台语义恒 Some");
            let page_idx = locate_structured_page(&pages, hit.anchor_char_offset);
            let page_text: String = pages[page_idx]
                .entries
                .iter()
                .filter_map(|e| e.text.clone())
                .collect();
            assert!(
                page_text.contains("蓝鲸座"),
                "anchor={} 定位页应包含命中词，实际页文本：{}",
                hit.anchor_char_offset,
                page_text
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
