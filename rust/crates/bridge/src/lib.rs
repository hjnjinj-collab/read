mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
pub mod api;
pub mod diagnostics;

use book_parser::{Book, Chapter};
use layout_engine::Page;
use std::sync::{Arc, Mutex, RwLock};
use std::collections::HashMap;

/// EPUB 结构化阅读句柄（路线2：解析器随书会话存活，
/// 内含样式表缓存与资源 LRU；换书随句柄释放）
pub struct StructuredEpubHandle {
    pub parser: book_parser::EpubParser,
}

/// FFI-safe book handle
pub struct BookHandle {
    pub book: Book,
    /// 保留 TxtParser 实例用于按需净化（可选，仅 TXT 格式）
    pub parser: Option<Box<book_parser::TxtParser>>,
    /// 源文件路径（EPUB 净化缓存磁盘键的稳定依据，跨启动一致）
    pub source_path: Option<String>,
    /// EPUB 导入级净化缓存（parser 为 None 的书籍使用；config_hash 变更自动重建）
    pub epub_cleaned: Option<book_parser::EpubCleanedBook>,
    /// EPUB 结构化阅读句柄（路线2 主路径；EPUB 书恒有，TXT 为 None）
    pub structured: Option<StructuredEpubHandle>,
    /// 净化缓存 singleflight 门：锁外重建期间同一本书的并发重建在此汇合
    /// （调用方在读锁内 clone Arc 后在 BOOKS 锁外等待/持有，见 api.rs
    /// get_chapter_content_impl 两阶段重建）
    pub clean_rebuild_gate: Arc<Mutex<()>>,
}

/// FFI-safe chapter info
#[derive(Debug, Clone)]
pub struct ChapterInfo {
    pub title: String,
    pub start_pos: usize,
    pub end_pos: usize,
    /// 章节层级：1=顶层（EPUB 嵌套目录；TXT 平铺恒为 1）
    pub level: u8,
    /// 父章节索引（None=顶层）
    pub parent_index: Option<usize>,
}

impl From<Chapter> for ChapterInfo {
    fn from(chapter: Chapter) -> Self {
        Self {
            title: chapter.title,
            start_pos: chapter.start_pos,
            end_pos: chapter.end_pos,
            level: chapter.level,
            parent_index: chapter.parent_index,
        }
    }
}

/// FFI-safe page info
#[derive(Debug, Clone)]
pub struct PageInfo {
    pub page_index: usize,
    pub chapter_index: usize,
    pub entries: Vec<PageEntryInfo>,
    pub start_char_index: usize,
    pub end_char_index: usize,
    /// 整页背景图 ZIP 路径（仅结构化路径的装饰页/卷首页；每页重复携带，
    /// Dart 侧按需解码一次）
    pub background_href: Option<String>,
    /// 背景缩放模式："cover" | "contain" | "stretch"
    /// （绘制严格按 CSS 语义：cover=铺满裁切；None=无背景）
    pub background_size: Option<String>,
    /// 背景位置关键字原文（"bottom center"/"left top"...），
    /// 决定 cover 裁切锚点方位；None=居中
    pub background_position: Option<String>,
}

/// 页面内容项：文本行或图片
///
/// 判别方式：`resource_href` 为 None 即文本项，Some 即图片项。
/// 有意不用枚举——FRB 对枚举变体强制要求 freezed 依赖，
/// 与项目「手写模型、克制依赖」约定冲突。
#[derive(Debug, Clone)]
pub struct PageEntryInfo {
    /// 文本行内容（None=图片项）
    pub text: Option<String>,
    /// 图片资源 ZIP 路径（None=文本项）
    pub resource_href: Option<String>,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    /// 行级默认色（#rrggbb；None=主题默认色，仅文本项携带）
    pub color: Option<String>,
    /// 行级字号倍率（None=1.0，仅文本项携带）
    pub font_scale: Option<f32>,
    /// 行内富文本分段（span 等，区间为行内字符偏移；空=整行统一）
    pub segments: Vec<PageSegInfo>,
    /// P2 两端对齐：行内字符间隙（px；0=左对齐/豁免行，绘制端转 letterSpacing）
    pub letter_gap: f32,
    /// 章节首行标记（TXT 强制分页用；绘制端按粗体开关渲染标题加粗）
    pub is_chapter_start: bool,
    /// 表格单元格线框矩形（x/y/width/height 即几何；绘制端描边）
    pub is_table_frame: bool,
    /// 本章说/注释行标记（小号灰字渲染；开关隐藏时 char_index 照常累计）
    pub is_comment: bool,
    /// A31: 本行章内字符区间 [start, end)（锚点口径；表格行 0/0=未知不高亮）
    pub start_char_index: usize,
    pub end_char_index: usize,
}

/// 文本行内样式分段
#[derive(Debug, Clone)]
pub struct PageSegInfo {
    pub start: usize,
    pub end: usize,
    /// 段级色覆盖（None=继承行级默认色）
    pub color: Option<String>,
    /// A31-v6: 段级背景色（#rrggbb；笔记高亮用；None=无背景）
    pub background_color: Option<String>,
    /// 段级字号倍率覆盖（None=继承行级）
    pub font_scale: Option<f32>,
    /// 字形样式（绘制端按用户开关决定是否应用；下划线恒应用）
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    /// P2 justify 拉丁词保护段（Some(0)=该区间不加间隙；None=继承行级）
    pub letter_spacing: Option<f32>,
}

impl From<Page> for PageInfo {
    fn from(page: Page) -> Self {
        Self {
            page_index: page.page_index,
            chapter_index: page.chapter_index,
            entries: page
                .entries
                .into_iter()
                .map(|entry| match entry {
                    layout_engine::PageEntry::Text(line) => PageEntryInfo {
                        text: Some(line.text),
                        resource_href: None,
                        x: line.x,
                        y: line.y,
                        width: line.width,
                        height: line.height,
                        color: line.color,
                        font_scale: line.font_scale,
                        segments: line
                            .segments
                            .into_iter()
                            .map(|s| PageSegInfo {
                                start: s.start,
                                end: s.end,
                                color: s.color,
                                background_color: s.background_color,
                                font_scale: s.font_scale,
                                bold: s.bold,
                                italic: s.italic,
                                underline: s.underline,
                                letter_spacing: s.letter_spacing,
                            })
                            .collect(),
                        letter_gap: line.letter_gap,
                        is_chapter_start: line.is_chapter_start,
                        is_table_frame: false,
                        is_comment: line.is_comment,
                        start_char_index: line.start_char_index,
                        end_char_index: line.end_char_index,
                    },
                    layout_engine::PageEntry::Image(image) => PageEntryInfo {
                        text: None,
                        resource_href: Some(image.resource_href),
                        x: image.x,
                        y: image.y,
                        width: image.width,
                        height: image.height,
                        color: None,
                        font_scale: None,
                        segments: Vec::new(),
                        letter_gap: 0.0,
                        is_chapter_start: false,
                        is_table_frame: false,
                        is_comment: false,
                        start_char_index: 0,
                        end_char_index: 0,
                    },
                    layout_engine::PageEntry::Rect(rect) => PageEntryInfo {
                        text: None,
                        resource_href: None,
                        x: rect.x,
                        y: rect.y,
                        width: rect.width,
                        height: rect.height,
                        color: None,
                        font_scale: None,
                        segments: Vec::new(),
                        letter_gap: 0.0,
                        is_chapter_start: false,
                        is_table_frame: true,
                        is_comment: false,
                        start_char_index: 0,
                        end_char_index: 0,
                    },
                })
                .collect(),
            start_char_index: page.start_char_index,
            end_char_index: page.end_char_index,
            background_href: None,
            background_size: None,
            background_position: None,
        }
    }
}

// ===== 书源解析引擎 FFI 类型 =====

/// FFI-safe search book item
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiSearchBookItem {
    pub name: String,
    pub author: String,
    pub kind: String,
    pub last_chapter: String,
    pub intro: String,
    pub cover_url: String,
    pub book_url: String,
    pub source_url: String,
}

impl From<book_source_engine::SearchBookItem> for FfiSearchBookItem {
    fn from(item: book_source_engine::SearchBookItem) -> Self {
        Self {
            name: item.name,
            author: item.author,
            kind: item.kind,
            last_chapter: item.last_chapter,
            intro: item.intro,
            cover_url: item.cover_url,
            book_url: item.book_url,
            source_url: item.source_url,
        }
    }
}

/// FFI-safe book info
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiBookInfo {
    pub name: String,
    pub author: String,
    pub kind: String,
    pub last_chapter: String,
    pub intro: String,
    pub cover_url: String,
    pub toc_url: String,
    pub word_count: String,
}

impl From<book_source_engine::BookInfo> for FfiBookInfo {
    fn from(info: book_source_engine::BookInfo) -> Self {
        Self {
            name: info.name,
            author: info.author,
            kind: info.kind,
            last_chapter: info.last_chapter,
            intro: info.intro,
            cover_url: info.cover_url,
            toc_url: info.toc_url,
            word_count: info.word_count,
        }
    }
}

/// FFI-safe chapter info for book source
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiChapterInfo {
    pub name: String,
    pub url: String,
    pub is_vip: bool,
    pub update_time: String,
    pub is_volume: bool,
    pub index: usize,
}

impl From<book_source_engine::ChapterInfo> for FfiChapterInfo {
    fn from(info: book_source_engine::ChapterInfo) -> Self {
        Self {
            name: info.name,
            url: info.url,
            is_vip: info.is_vip,
            update_time: info.update_time,
            is_volume: info.is_volume,
            index: info.index,
        }
    }
}

/// FFI-safe chapter content
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiChapterContent {
    pub content: String,
    pub next_url: Option<String>,
}

impl From<book_source_engine::ChapterContent> for FfiChapterContent {
    fn from(content: book_source_engine::ChapterContent) -> Self {
        Self {
            content: content.content,
            next_url: content.next_url,
        }
    }
}

/// FFI-safe book source (for storage/transfer)
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FfiBookSource {
    pub book_source_url: String,
    pub book_source_name: String,
    pub book_source_group: String,
    pub enabled: bool,
    pub header: String,
    pub cookie: String,
    pub rule_search_url: String,
    pub rule_search_book_list: String,
    pub rule_search_name: String,
    pub rule_search_author: String,
    pub rule_search_book_url: String,
    pub rule_book_info_name: String,
    pub rule_book_info_author: String,
    pub rule_book_info_toc_url: String,
    pub rule_toc_chapter_list: String,
    pub rule_toc_chapter_name: String,
    pub rule_toc_chapter_url: String,
    pub rule_content_content: String,
    pub rule_content_next_url: String,
}

impl FfiBookSource {
    /// Convert to internal BookSource
    pub fn to_book_source(&self) -> book_source_engine::BookSource {
        book_source_engine::BookSource {
            book_source_url: self.book_source_url.clone(),
            book_source_name: self.book_source_name.clone(),
            book_source_group: self.book_source_group.clone(),
            book_source_type: 0,
            enabled: self.enabled,
            enabled_explore: false,
            header: self.header.clone(),
            login_url: String::new(),
            cookie: self.cookie.clone(),
            rule_search: book_source_engine::SearchRule {
                url: self.rule_search_url.clone(),
                method: "GET".to_string(),
                body: String::new(),
                charset: String::new(),
                book_list: self.rule_search_book_list.clone(),
                name: self.rule_search_name.clone(),
                author: self.rule_search_author.clone(),
                kind: String::new(),
                last_chapter: String::new(),
                intro: String::new(),
                cover_url: String::new(),
                book_url: self.rule_search_book_url.clone(),
            },
            rule_book_info: book_source_engine::BookInfoRule {
                name: self.rule_book_info_name.clone(),
                author: self.rule_book_info_author.clone(),
                toc_url: self.rule_book_info_toc_url.clone(),
                ..Default::default()
            },
            rule_toc: book_source_engine::TocRule {
                chapter_list: self.rule_toc_chapter_list.clone(),
                chapter_name: self.rule_toc_chapter_name.clone(),
                chapter_url: self.rule_toc_chapter_url.clone(),
                ..Default::default()
            },
            rule_content: book_source_engine::ContentRule {
                content: self.rule_content_content.clone(),
                next_content_url: self.rule_content_next_url.clone(),
                ..Default::default()
            },
            rule_explore: None,
            weight: 0,
        }
    }
}

impl From<book_source_engine::BookSource> for FfiBookSource {
    fn from(source: book_source_engine::BookSource) -> Self {
        Self {
            book_source_url: source.book_source_url,
            book_source_name: source.book_source_name,
            book_source_group: source.book_source_group,
            enabled: source.enabled,
            header: source.header,
            cookie: source.cookie,
            rule_search_url: source.rule_search.url,
            rule_search_book_list: source.rule_search.book_list,
            rule_search_name: source.rule_search.name,
            rule_search_author: source.rule_search.author,
            rule_search_book_url: source.rule_search.book_url,
            rule_book_info_name: source.rule_book_info.name,
            rule_book_info_author: source.rule_book_info.author,
            rule_book_info_toc_url: source.rule_book_info.toc_url,
            rule_toc_chapter_list: source.rule_toc.chapter_list,
            rule_toc_chapter_name: source.rule_toc.chapter_name,
            rule_toc_chapter_url: source.rule_toc.chapter_url,
            rule_content_content: source.rule_content.content,
            rule_content_next_url: source.rule_content.next_content_url,
        }
    }
}

// Global book storage (使用 RwLock 支持读写分离)
//
// ⚠ 锁纪律（2026-09-11 死锁审计后立规，新增锁点必须遵守）：
// std RwLock **非可重入**——持任何 BOOKS 锁期间调用会再取 BOOKS 锁的函数
// 必然死锁（实证：batch_locate_notes 曾持 read 调 get_page_count_structured，
// 后者缓存未命中路径经 process_structured_chapter:2361 取 write）。
//
// 铁律：持 BOOKS.read()/write() 期间禁止调用：
//   get_page_* / get_chapter_content* / process_and_layout_chapter /
//   process_structured_chapter / get_book_resource 等任何内部再取 BOOKS 的函数。
// 跨锁取数据一律「作用域内探测 → 立即放锁 → 再调用」（参照 api.rs
// batch_locate_notes 的 is_structured 探测块）。
//
// 审计清单（2026-09-11，api.rs 全部锁点；1.0.5 锁竞争优化后更新）：
//   ✅ 纯读/写、作用域内不再取锁：591/678/1033/1190/1199/1238/1259/1314/
//      1412/1462/2808/2820/2906/3060/3232(release_book)/3695/3927/4077
//   ✅ get_chapter_content_impl（原热点1/2）：稳态只取读锁；净化缓存重建
//      改两阶段——读锁取快照+clean_rebuild_gate → 锁外构建 → 短写锁装回
//      + invalidate 下游缓存（PREPROCESSED_CACHE 键不含净化 config_hash）
//   ✅ get_book_resource（原热点4）：EpubParser.archive 内部互斥，慢路径
//      ZIP IO 也只取 BOOKS.read()
//   ⚠ 搜索逐章 IR 提取：仍持写锁做 parser 独占提取（竞争隐患，待结构性改造）
//   ✅ 2361 process_structured_chapter：写锁仅覆盖 IR 提取（2382 即 drop），
//      风险在调用方——现调用方 2607/2654/2679/2716/2771 均未持锁
//   ✅ 855 batch_locate_notes：探测后放锁（唯一发生过死锁处，已修）
lazy_static::lazy_static! {
    pub static ref BOOKS: Arc<RwLock<HashMap<String, BookHandle>>> = Arc::new(RwLock::new(HashMap::new()));
}

// Global book source engine (using tokio::sync::Mutex for async support)
lazy_static::lazy_static! {
    pub static ref BOOK_SOURCE_ENGINE: tokio::sync::Mutex<book_source_engine::BookSourceEngine> = 
        tokio::sync::Mutex::new(book_source_engine::BookSourceEngine::new().unwrap());
}
