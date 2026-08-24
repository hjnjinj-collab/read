use crate::{BookHandle, ChapterInfo, PageInfo, BOOKS};
use crate::diagnostics::{diagnose_file_encoding, diagnose_chapter_content};
use book_parser::{BookParser, BookFormat, ContentCleaner, ConvertMode, ParagraphMode, CleanOptions};
use layout_engine::{LayoutConfig, LayoutEngine, EdgeInsets, FontManager, GlyphCache, Page};
use reader_core::{
    ContentPreprocessor, ProcessOptions, ChineseConvertType, ReplaceRule, RuleType,
    PaginationCache, CacheKey, CachedChapterPages,
    ReadSessionManager,
    PreloadExecutor, PreloadExecutorConfig,
    PreloadTask, DefaultPreloadStrategy, PreloadStrategy,
};
use std::sync::{Arc, Mutex, OnceLock};
use once_cell::sync::Lazy;
use std::time::Instant;
use crate::{
    FfiBookSource, FfiSearchBookItem, FfiBookInfo,
    FfiChapterInfo, FfiChapterContent, BOOK_SOURCE_ENGINE
};

// Global font manager
static FONT_MANAGER: Lazy<Arc<Mutex<FontManager>>> = Lazy::new(|| {
    Arc::new(Mutex::new(FontManager::new()))
});

// M8-P4：跨章共享字形缓存——所有章节排版复用同一 GlyphCache，
// 消除每章新建 LayoutEngine → 新建 GlyphCache 的冷启动开销。
// GlyphCache 内部键含 font_name + font_size_bits，不同字体/字号自然隔离；
// load_font_file/load_font_data 会 clear() 防容量污染。
static SHARED_GLYPH_CACHE: Lazy<Mutex<GlyphCache>> =
    Lazy::new(|| Mutex::new(GlyphCache::with_capacity(10_000)));

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
) {
    *LAST_TXT_LAYOUT_SNAPSHOT.lock().unwrap() = Some((
        book_id.to_string(),
        TxtLayoutSnapshot {
            config: config.clone(),
            remove_duplicate_title,
            re_segment,
            chinese_convert,
            replace_rules: replace_rules.to_vec(),
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
fn preload_txt_warm(book_id: &str, chapter_index: usize) -> anyhow::Result<bool> {
    let snap = LAST_TXT_LAYOUT_SNAPSHOT.lock().unwrap().clone();
    let Some((snap_book, snap)) = snap else {
        return Ok(false);
    };
    if snap_book != book_id {
        return Ok(false);
    }
    process_and_layout_chapter(
        book_id,
        chapter_index,
        &snap.config,
        snap.remove_duplicate_title,
        snap.re_segment,
        snap.chinese_convert,
        &snap.replace_rules,
    )?;
    Ok(true)
}

/// 结构化路径分页结果缓存（EPUB；键含排版配置，容量 10 章）
///
/// 与 PAGINATION_CACHE 分离的原因：后者存 layout_engine::Page（无背景
/// 字段且属 reader_core 类型）；结构化路径交付 PageInfo（含 background）
/// 且不经过文本预处理，生命周期独立。
///
/// M8-P4：值类型从 `Vec<PageInfo>` 改为 `Arc<Vec<PageInfo>>`，
/// 命中时 Arc::clone 后锁外取单页，免整章克隆。
static STRUCTURED_PAGINATION_CACHE: Lazy<Mutex<lru::LruCache<StructuredPageKey, Arc<Vec<crate::PageInfo>>>>> =
    Lazy::new(|| {
        Mutex::new(lru::LruCache::new(
            std::num::NonZeroUsize::new(10).unwrap(),
        ))
    });

/// 结构化分页缓存键
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct StructuredPageKey {
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
}

impl StructuredPageKey {
    fn new(
        book_id: &str,
        chapter_index: usize,
        config: &LayoutConfig,
        convert_mode: u8,
    ) -> Self {
        Self {
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
        }
    }
}

// Global content cleaning options
static CONTENT_CLEANING_OPTIONS: Lazy<Arc<Mutex<Option<ContentCleaningOptions>>>> = Lazy::new(|| {
    Arc::new(Mutex::new(None))
});

/// Load font from file path
pub fn load_font_file(font_name: String, font_path: String) -> anyhow::Result<()> {
    let mut manager = FONT_MANAGER.lock().unwrap();
    manager.load_font_from_file(font_name, &font_path)?;
    // M8-P4：字体变更清共享字形缓存，防旧字体字形混入
    SHARED_GLYPH_CACHE.lock().unwrap().clear();
    Ok(())
}

/// Load font from byte array
pub fn load_font_data(font_name: String, font_data: Vec<u8>) -> anyhow::Result<()> {
    let mut manager = FONT_MANAGER.lock().unwrap();
    manager.load_font(font_name, font_data)?;
    // M8-P4：字体变更清共享字形缓存
    SHARED_GLYPH_CACHE.lock().unwrap().clear();
    Ok(())
}

/// Get loaded font count
pub fn get_font_count() -> usize {
    let manager = FONT_MANAGER.lock().unwrap();
    manager.font_count()
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
    Ok(())
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
) -> anyhow::Result<Vec<Page>> {
    let rules: Vec<ReplaceRule> = replace_rules.iter().cloned().map(Into::into).collect();
    let rules_hash = CacheKey::hash_replace_rules(&rules);
    let options_hash = CacheKey::hash_process_options(
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        rules_hash,
    );
    let cache_key = CacheKey::with_options(book_id, chapter_index, config, options_hash);

    // 缓存命中：零计算
    if let Some(cached) = PAGINATION_CACHE.lock().unwrap().get(&cache_key).cloned() {
        return Ok(cached.pages);
    }

    // 未命中：重活全部在锁外执行
    let raw_content = get_chapter_content(book_id.to_string(), chapter_index)?;
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

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    // M8-P4：跨章复用共享字形缓存
    let glyph_cache = SHARED_GLYPH_CACHE.lock().unwrap().clone();
    let engine = LayoutEngine::with_cache(config.clone(), font_manager, glyph_cache);
    let pages = engine.layout_text(&processed, chapter_index)?;

    PAGINATION_CACHE.lock().unwrap().put(
        cache_key,
        CachedChapterPages {
            pages: pages.clone(),
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
pub fn get_chapter_content(book_id: String, chapter_index: usize) -> anyhow::Result<String> {
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
        
        // 异步触发预加载（非阻塞）
        trigger_preload_async(book_id, chapter_index);
        
        Ok(content)
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
                    // 异步触发预加载（非阻塞）
                    trigger_preload_async(book_id, chapter_index);
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

        // 异步触发预加载（非阻塞）
        trigger_preload_async(book_id, chapter_index);

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

            if let Err(e) = executor.submit(task).await {
                log::warn!("预加载任务提交失败: {}", e);
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
    let raw_content = get_chapter_content(book_id.clone(), chapter_index)?;
    
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
    let content = get_chapter_content(book_id, chapter_index)?;
    
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
    };
    
    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = LayoutEngine::new(config, font_manager);
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
    let content = get_chapter_content(book_id, chapter_index)?;

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
    };

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = LayoutEngine::new(config, font_manager);
    engine.get_page(&content, chapter_index, page_index)?
        .map(PageInfo::from)
        .ok_or_else(|| anyhow::anyhow!("Page not found"))
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
    let content = get_chapter_content(book_id, chapter_index)?;

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
    };

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    let engine = LayoutEngine::new(config, font_manager);
    engine.get_page_count(&content, chapter_index)
}

/// Get specific page with content preprocessing (带内容预处理的分页获取)
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
    anchor_char_offset: Option<usize>,
    page_fill_threshold: f32,
) -> anyhow::Result<PageInfo> {
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
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold,
        show_comments: true,
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
    )?;
    remember_txt_layout(
        &book_id,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
    );

    // 3. 页面定位：优先锚点（进度保持），否则用请求页码
    let effective = match anchor_char_offset {
        Some(offset) => locate_page_for_offset(&pages, offset),
        None => page_index,
    };

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
    page_fill_threshold: f32,
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
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold,
        show_comments: true,
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
    )?;
    remember_txt_layout(
        &book_id,
        &config,
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        &replace_rules,
    );

    Ok(pages.len())
}

// ===== 结构化阅读路径（EPUB 路线2 主入口） =====

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
                    spacing_after_em: 0.0,
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
                    is_comment: false,
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
                                                is_comment: *is_comment,
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
                                                is_comment: false,
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
    config: &LayoutConfig,
    chinese_convert: u8,
    prefer_try_lock: bool,
) -> anyhow::Result<Option<Arc<Vec<crate::PageInfo>>>> {
    let cache_key = StructuredPageKey::new(book_id, chapter_index, config, chinese_convert);

    // M8-P4 缓存命中：Arc::clone 免整章克隆
    if let Some(arc_pages) = STRUCTURED_PAGINATION_CACHE
        .lock()
        .unwrap()
        .get(&cache_key)
        .cloned()
    {
        return Ok(Some(arc_pages));
    }

    // u8 → ConvertMode（与 TXT process_and_layout_chapter 同编码：1=简→繁 2=繁→简）
    let convert_mode = match chinese_convert {
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
        .get_chapter_content_structured_ex(chapter_index, convert_mode, config.font_size)?;
    let background = content.background.clone();
    drop(books);

    // IR → 布局项 → 分页（重活在锁外）
    let mut items = Vec::with_capacity(content.blocks.len());
    blocks_to_layout_items(&content.blocks, &mut items);

    let font_manager = FONT_MANAGER.lock().unwrap().clone();
    // M8-P4：跨章复用共享字形缓存
    let glyph_cache = SHARED_GLYPH_CACHE.lock().unwrap().clone();
    let engine = LayoutEngine::with_cache(config.clone(), font_manager, glyph_cache);
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
    let arc_infos = Arc::new(infos);
    STRUCTURED_PAGINATION_CACHE
        .lock()
        .unwrap()
        .put(cache_key, Arc::clone(&arc_infos));

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
        paragraph_spacing: font_size * 0.8,
        page_fill_threshold,
        show_comments,
    }
}

/// 结构化分页获取（EPUB 主路径）
///
/// `anchor_char_offset`: 进度锚点——章内文本字符偏移（与 TXT 路径同语义，
/// 图片项不消耗锚点）；提供时返回包含该偏移的页（跳过纯图装饰页）。
/// `chinese_convert`: 阅读级简繁转换（0=无 1=简→繁 2=繁→简；与 TXT 同编码）
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
) -> anyhow::Result<crate::PageInfo> {
    let config = structured_layout_config(
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
    );
    let pages =
        process_structured_chapter(&book_id, chapter_index, &config, chinese_convert, false)?
            .expect("前台结构化分页恒返回 Some");

    let effective = match anchor_char_offset {
        Some(offset) => locate_structured_page(&pages, offset),
        None => page_index,
    };

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
) -> anyhow::Result<usize> {
    let config = structured_layout_config(
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
    );
    let pages =
        process_structured_chapter(&book_id, chapter_index, &config, chinese_convert, false)?
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
) -> anyhow::Result<bool> {
    let config = structured_layout_config(
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
    );
    let cache_key = StructuredPageKey::new(&book_id, chapter_index, &config, chinese_convert);
    if STRUCTURED_PAGINATION_CACHE.lock().unwrap().contains(&cache_key) {
        return Ok(true);
    }
    Ok(
        process_structured_chapter(&book_id, chapter_index, &config, chinese_convert, true)?
            .is_some(),
    )
}

/// 读取书内资源字节（EPUB 图片；ZIP 全路径，与 IR resource_href 同基准）
pub fn get_book_resource(book_id: String, resource_href: String) -> anyhow::Result<Vec<u8>> {
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

/// Release book from memory
pub fn release_book(book_id: String) -> anyhow::Result<()> {
    let mut books = BOOKS.write().unwrap();
    books.remove(&book_id)
        .ok_or_else(|| anyhow::anyhow!("Book not found"))?;

    // 结构化分页缓存随之失效（LRU 无按键删除接口，整体清理代价可忽略）
    STRUCTURED_PAGINATION_CACHE.lock().unwrap().clear();

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
        let engine = LayoutEngine::new(config.clone(), font_manager);
        let pages = engine.layout_text(&content, chapter_index)?;
        
        // 存入缓存
        let mut cache = PAGINATION_CACHE.lock().unwrap();
        cache.put(
            cache_key,
            CachedChapterPages {
                pages: pages.clone(),
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
    // 结构化缓存：按键前缀过滤（LRU 无按键删除，逐键清理）
    let mut structured = STRUCTURED_PAGINATION_CACHE.lock().unwrap();
    let stale: Vec<StructuredPageKey> = structured
        .iter()
        .filter(|(k, _)| k.book_id == book_id)
        .map(|(k, _)| k.clone())
        .collect();
    for key in stale {
        structured.pop(&key);
    }
    Ok(())
}

/// 清除所有分页缓存
pub fn clear_all_pagination_cache() -> anyhow::Result<()> {
    let mut cache = PAGINATION_CACHE.lock().unwrap();
    cache.clear();
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
    // 1. 获取原始内容
    let raw_content = get_chapter_content(book_id.clone(), chapter_index)?;

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
    let ffi_config = config.unwrap_or_default();
    let options = ProcessOptions {
        book_name: String::new(),
        title: chapter_title,
        chapter_index,
        remove_duplicate_title: ffi_config.remove_duplicate_title,
        re_segment: ffi_config.re_segment,
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
    let mut cache = PAGINATION_CACHE.lock().unwrap();
    cache.clear_book(&book_id);
    Ok(())
}

/// 清除所有缓存
pub fn clear_all_caches() -> anyhow::Result<()> {
    let mut cache = PAGINATION_CACHE.lock().unwrap();
    cache.clear();
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
    let content = get_chapter_content(book_id.clone(), chapter_index)?;
    
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
    let raw_content = get_chapter_content(book_id.clone(), chapter_index)?;
    
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

#[cfg(test)]
mod tests {
    use super::*;

    /// M6-S1：TXT 预加载真预热——load_fn 副作用（分页缓存回填）验证。
    /// 旧实现只读原始文本即丢弃、对缓存零贡献；本测试锁定「预热→命中」语义
    #[test]
    fn preload_txt_warm_fills_pagination_cache() {
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
            false, false, 0, Vec::new(), None, 0.9,
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
            false, false, 0, Vec::new(), None, 0.9,
        )
        .expect("ch1 前台读取失败");
        let hits_after = get_cache_statistics().unwrap().hits;
        assert!(hits_after > hits_before, "预热后的同参调用应命中分页缓存");

        // 无快照的书 → 跳过不报错
        assert!(!preload_txt_warm("nonexistent-book", 0).unwrap());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
