mod font_manager;
mod glyph_cache;
mod parallel;
pub mod text_boundary;
pub mod glyph_cache_advanced;
pub mod pagination;

pub use font_manager::{FontManager, GlyphMetrics};
pub use glyph_cache::{GlyphCache, GlyphKey, CacheStats};
pub use parallel::{layout_chapters_parallel, layout_chapter_range_parallel};
pub use glyph_cache_advanced::{
    AdvancedGlyphCache, gb2312_level1_chars, gb2312_level1_count, gb2312_level2_chars,
};
pub use pagination::{SmartPaginator, SmartPaginatorConfig};

use unicode_segmentation::UnicodeSegmentation;
use anyhow::Result;
use serde::{Deserialize, Serialize};

/// Text layout configuration
#[derive(Debug, Clone)]
pub struct LayoutConfig {
    pub width: f32,
    pub height: f32,
    pub font_size: f32,
    pub line_height_multiplier: f32,  // 行高倍数，如 1.5
    pub padding: EdgeInsets,
    pub font_name: String,           // 字体名称
    pub letter_spacing: f32,
    pub paragraph_spacing: f32,
    /// 页面填充率门槛（0.0-1.0）：填充达到该比例后段落放不下才整段推下页，
    /// 低于则允许段落跨页拆分。TXT/EPUB 双路径共用
    pub page_fill_threshold: f32,
    /// 是否显示本章说（注释/旁注段落）；true=渲染、false=跳过绘制但保留锚点
    pub show_comments: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct EdgeInsets {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

impl Default for LayoutConfig {
    fn default() -> Self {
        Self {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 20.0,
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
            },
            font_name: "default".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
            show_comments: true,
        }
    }
}

/// A line of text with positioning
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextLine {
    pub text: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    /// 行级默认色（CSS color 物化；None=主题默认色）
    #[serde(default)]
    pub color: Option<String>,
    /// 行级字号倍率（相对基准字号；None=1.0）
    #[serde(default)]
    pub font_scale: Option<f32>,
    /// 行内富文本分段（span 等样式覆盖；空=整行统一用行级样式）。
    /// 区间为行文本内的字符偏移，仅携带与行级不同的覆盖值
    #[serde(default)]
    pub segments: Vec<LineSeg>,
    /// 标记是否是章节开头的第一行（用于强制分页）
    #[serde(default)]
    pub is_chapter_start: bool,
    /// 本章说标记（Dart 层据此渲染灰色小字或隐藏）
    #[serde(default)]
    pub is_comment: bool,
}

/// 行内样式分段：`[start, end)` 字符区间（Rust char 计数）的样式覆盖。
/// None 字段继承行级默认
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LineSeg {
    pub start: usize,
    pub end: usize,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub font_scale: Option<f32>,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub underline: bool,
}

/// 图片项的绘制参数（坐标已由布局引擎折算）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageEntry {
    /// ZIP 内资源路径（渲染层据此取字节解码）
    pub resource_href: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 矩形项（表格单元格线框）：坐标为页面绝对值，绘制层描边不填充
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RectEntry {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// 水平对齐（CSS text-align 的布局层镜像；与 book_parser 解耦的独立定义）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutAlign {
    Left,
    Center,
    Right,
}

/// 页面内容项：文本行、图片或矩形（图片/表格均为不可分割原子块）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PageEntry {
    Text(TextLine),
    Image(ImageEntry),
    Rect(RectEntry),
}

/// 文本项样式载荷（bridge 层由 ContentBlock 物化结果映射而来）
#[derive(Debug, Clone, Default)]
pub struct TextItem {
    pub text: String,
    /// 水平对齐（None=左对齐）
    pub align: Option<LayoutAlign>,
    /// 块级默认色（None=主题默认）
    pub color: Option<String>,
    /// 块级字号倍率（None=1.0）
    pub font_scale: Option<f32>,
    /// 行内富文本区段（字符区间锚定；样式为最终物化值，None=继承块级）
    pub runs: Vec<RunSpan>,
    /// 段前间距（em 倍数，layout 期按基准字号折算 px；标题分级用，普通段落 0）
    pub spacing_before_em: f32,
    /// 段后间距（em 倍数；页首自动折叠）
    pub spacing_after_em: f32,
    /// 本章说标记（JS 提取层 aside/footnote 或 CSS 小字号兜底）
    pub is_comment: bool,
}

/// 文本项的行内样式区段
#[derive(Debug, Clone)]
pub struct RunSpan {
    pub start: usize,
    pub end: usize,
    pub color: Option<String>,
    pub font_scale: Option<f32>,
    /// 字形样式（绘制期合成；不参与 Rust 测量）
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
}

/// 样式化排版的单行产物（layout_styled_paragraph 内部使用）
#[derive(Debug, Clone)]
struct LaidLine {
    text: String,
    /// 实测行宽（对齐折算用）
    width: f32,
    /// 本行在段落中的字符区间 [start, end)（不含行前软换行符）
    char_start: usize,
    char_end: usize,
    /// 本行之前被跳过的 `\n` 个数（锚点计数用：区间不含换行符）
    newlines_before: usize,
}

/// 表格输入（原子排版：列宽提示 + 单元格文本项序列）
#[derive(Debug, Clone, Default)]
pub struct TableInput {
    /// 表格前垂直留白（CSS margin-top 百分比 × 内容高）
    pub margin_top_percent: Option<f32>,
    /// CSS margin-left:auto：表格水平右置（内容区内贴右缘）
    pub margin_left_auto: bool,
    pub rows: Vec<Vec<TableCellInput>>,
}

/// 表格单元格输入
#[derive(Debug, Clone, Default)]
pub struct TableCellInput {
    /// CSS width em 列宽提示（None=均分剩余空间）
    pub width_em: Option<f32>,
    pub items: Vec<TextItem>,
}

/// 结构化分页输入项（bridge 层把 ContentBlock 映射为此最小类型，
/// layout_engine 不依赖 book_parser）
#[derive(Debug, Clone)]
pub enum LayoutItem {
    Text(TextItem),
    Image {
        resource_href: String,
        /// 宽高比 w/h（探测失败由调用方填默认值 0.75）
        aspect: f32,
        /// CSS width 百分比（None=占满可用宽度）
        width_percent: Option<f32>,
        align: Option<LayoutAlign>,
        /// 出血图（duokan-bleed）：占满整窗宽、x=0，页首时 y 贴顶，
        /// 忽略水平 padding 与 width_percent/align
        bleed: bool,
    },
    Table(TableInput),
}

impl LayoutItem {
    /// 纯文本项构造辅助（无样式）
    pub fn text(s: impl Into<String>) -> Self {
        LayoutItem::Text(TextItem {
            text: s.into(),
            ..Default::default()
        })
    }
}

impl Default for LayoutItem {
    fn default() -> Self {
        LayoutItem::text(String::new())
    }
}

/// A page of content
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Page {
    pub page_index: usize,
    pub chapter_index: usize,
    pub entries: Vec<PageEntry>,
    pub start_char_index: usize,
    pub end_char_index: usize,
}

/// Layout engine with real font metrics
pub struct LayoutEngine {
    config: LayoutConfig,
    font_manager: FontManager,
    glyph_cache: GlyphCache,
}

impl LayoutEngine {
    /// Create layout engine with font manager
    pub fn new(config: LayoutConfig, font_manager: FontManager) -> Self {
        Self {
            config,
            font_manager,
            glyph_cache: GlyphCache::new(),
        }
    }
    
    /// Create layout engine with existing cache (for parallel use)
    pub fn with_cache(config: LayoutConfig, font_manager: FontManager, cache: GlyphCache) -> Self {
        Self {
            config,
            font_manager,
            glyph_cache: cache,
        }
    }

    /// Calculate pages from text content with real font metrics
    pub fn layout_text(&self, text: &str, chapter_index: usize) -> Result<Vec<Page>> {
        let content_width = self.config.width 
            - self.config.padding.left 
            - self.config.padding.right;
        let content_height = self.config.height 
            - self.config.padding.top 
            - self.config.padding.bottom;
        
        let line_height = self.config.font_size * self.config.line_height_multiplier;
        
        // 分页控制参数
        const MIN_LINES_PER_PAGE: usize = 3;  // 每页最少3行，避免孤行
        // 页面填充率达到门槛后才优先在段落边界分页（与 layout_items 共用配置）
        let paragraph_break_threshold = self.config.page_fill_threshold;
        
        let mut pages = Vec::new();
        let mut current_lines = Vec::new();
        let mut current_y = self.config.padding.top;
        let mut char_index = 0;
        let mut page_start_char = 0;
        let mut pending_paragraph_lines: Vec<(String, usize)> = Vec::new(); // (line_text, char_count)
        let mut is_first_line = true;  // 标记是否是章节的第一行
        
        // Get font for measuring
        let font = self.font_manager.get_font(&self.config.font_name)?;
        
        // Split into paragraphs
        for paragraph in text.split('\n') {
            if paragraph.trim().is_empty() {
                char_index += 1;
                continue;
            }
            
            // Layout paragraph into lines
            let para_lines = self.layout_paragraph(paragraph, content_width, font)?;
            
            // 收集当前段落的所有行
            pending_paragraph_lines.clear();
            for line_text in &para_lines {
                let line_char_count = line_text.chars().count();
                pending_paragraph_lines.push((line_text.clone(), line_char_count));
            }
            
            // 尝试添加整个段落
            let paragraph_height = para_lines.len() as f32 * line_height + self.config.paragraph_spacing;
            let would_overflow = current_y + paragraph_height > self.config.height - self.config.padding.bottom;
            let page_fill_ratio = (current_y - self.config.padding.top) / content_height;
            let has_min_lines = current_lines.len() >= MIN_LINES_PER_PAGE;
            
            // 决策：是否在段落前分页
            let should_break_before_paragraph = would_overflow
                && has_min_lines
                && page_fill_ratio >= paragraph_break_threshold;
            
            if should_break_before_paragraph {
                // 在段落前分页（段落完整性优先）
                pages.push(Page {
                    page_index: pages.len(),
                    chapter_index,
                    entries: current_lines
                        .iter()
                        .map(|l: &TextLine| PageEntry::Text(l.clone()))
                        .collect(),
                    start_char_index: page_start_char,
                    end_char_index: char_index,
                });

                current_lines.clear();
                current_y = self.config.padding.top;
                page_start_char = char_index;
            }
            
            // 逐行添加段落内容
            for (line_text, line_char_count) in &pending_paragraph_lines {
                // 检查是否需要分页（强制分页，空间不足）
                if current_y + line_height > self.config.height - self.config.padding.bottom {
                    // 只有当前页已有足够行数时才分页，否则强制添加
                    if current_lines.len() >= MIN_LINES_PER_PAGE {
                        pages.push(Page {
                            page_index: pages.len(),
                            chapter_index,
                            entries: current_lines
                                .iter()
                                .map(|l: &TextLine| PageEntry::Text(l.clone()))
                                .collect(),
                            start_char_index: page_start_char,
                            end_char_index: char_index,
                        });
                        
                        current_lines.clear();
                        current_y = self.config.padding.top;
                        page_start_char = char_index;
                    }
                    // 如果当前页行数不足MIN_LINES，强制添加此行（避免过早分页）
                }
                
                // 添加行
                current_lines.push(TextLine {
                    text: line_text.clone(),
                    x: self.config.padding.left,
                    y: current_y,
                    width: content_width,
                    height: line_height,
                    color: None,
                    font_scale: None,
                    segments: Vec::new(),
                    is_chapter_start: is_first_line,  // 标记章节第一行
                    is_comment: false,
                });
                
                is_first_line = false;  // 后续行不再是章节开头
                current_y += line_height;
                char_index += line_char_count;
            }
            
            // 段落间距
            current_y += self.config.paragraph_spacing;
            char_index += 1; // newline
        }
        
        // 最后一页
        if !current_lines.is_empty() {
            pages.push(Page {
                page_index: pages.len(),
                chapter_index,
                entries: current_lines.into_iter().map(PageEntry::Text).collect(),
                start_char_index: page_start_char,
                end_char_index: char_index,
            });
        }
        
        // 空内容保护
        if pages.is_empty() {
            pages.push(Page {
                page_index: 0,
                chapter_index,
                entries: Vec::new(),
                start_char_index: 0,
                end_char_index: 0,
            });
        }
        
        Ok(pages)
    }

    /// 结构化内容混合分页（EPUB 路线2 主路径：文本行 + 图片原子块）
    ///
    /// 与 layout_text 的约定差异（有意为之，勿合并）：
    /// - layout_text 的字符偏移被 TXT 进度锚点精确依赖（空行+1 等），
    ///   保持其逐字节不动；本方法镜像同样的锚点约定——图片项不消耗
    ///   字符锚点，char_index 只随文本行累加；
    /// - 图片是不可分割块，不参与 MIN_LINES_PER_PAGE/段落阈值逻辑；
    /// - 空输入（纯背景装饰页）产出单张空页。
    pub fn layout_items(&self, items: &[LayoutItem], chapter_index: usize) -> Result<Vec<Page>> {
        const MIN_LINES_PER_PAGE: usize = 3;

        let content_width = self.config.width
            - self.config.padding.left
            - self.config.padding.right;
        let content_height = self.config.height
            - self.config.padding.top
            - self.config.padding.bottom;
        let bottom_limit = self.config.height - self.config.padding.bottom;
        let line_height = self.config.font_size * self.config.line_height_multiplier;
        let font = self.font_manager.get_font(&self.config.font_name)?;

        let mut pages: Vec<Page> = Vec::new();
        let mut entries: Vec<PageEntry> = Vec::new();
        let mut text_lines_on_page = 0usize;
        let mut current_y = self.config.padding.top;
        let mut char_index = 0usize;
        let mut page_start_char = 0usize;

        // 翻页：封存当前页并重置游标
        macro_rules! break_page {
            () => {{
                pages.push(Page {
                    page_index: pages.len(),
                    chapter_index,
                    entries: std::mem::take(&mut entries),
                    start_char_index: page_start_char,
                    end_char_index: char_index,
                });
                entries = Vec::new();
                text_lines_on_page = 0;
                current_y = self.config.padding.top;
                page_start_char = char_index;
            }};
        }

        for item in items {
            match item {
                LayoutItem::Text(item) => {
                    let laid = self.layout_styled_paragraph(item, content_width, font)?;
                    if laid.is_empty() {
                        continue;
                    }
                    // 行高取段落内最大字号倍率（行内 run 可能超过块级）
                    let para_max_scale = item
                        .font_scale
                        .unwrap_or(1.0)
                        .max(item.runs.iter().filter_map(|r| r.font_scale).fold(1.0, f32::max));
                    // 本章说：固定小字倍率覆盖 para_max_scale；正常段落用 para_max_scale
                    let effective_scale = if item.is_comment { 0.7 } else { para_max_scale };
                    let line_h = line_height * effective_scale;

                    // 段前间距（em → px）：页首折叠
                    let space_before = if entries.is_empty() && text_lines_on_page == 0 {
                        0.0
                    } else {
                        item.spacing_before_em * self.config.font_size
                    };
                    current_y += space_before;

                    // 段落完整性优先：整段放不下、页已有足够行数、且填充率
                    // 达到门槛时才提前翻页；未达门槛允许段落跨页拆分，
                    // 避免大面积底部留白（门槛可在 LayoutConfig 调整）
                    let para_height =
                        laid.len() as f32 * line_h + self.config.paragraph_spacing;
                    let page_fill_ratio =
                        (current_y - self.config.padding.top) / content_height.max(1.0);
                    if current_y + para_height > bottom_limit
                        && text_lines_on_page >= MIN_LINES_PER_PAGE
                        && page_fill_ratio >= self.config.page_fill_threshold
                    {
                        break_page!();
                    }

                    for line in laid {
                        if current_y + line_h > bottom_limit
                            && text_lines_on_page >= MIN_LINES_PER_PAGE
                        {
                            break_page!();
                        }
                        // 本章说 + 隐藏模式：跳过绘制但照常累计锚点
                        if item.is_comment && !self.config.show_comments {
                            char_index += line.char_end - line.char_start + line.newlines_before;
                            continue;
                        }
                        let x = self.align_line_x(line.width, content_width, item.align);
                        let segments = Self::segments_for_line(&line, item);
                        char_index += line.char_end - line.char_start + line.newlines_before;
                        entries.push(PageEntry::Text(TextLine {
                            text: line.text,
                            x,
                            y: current_y,
                            width: content_width,
                            height: line_h,
                            // 本章说：灰色小字；非注释走原始色
                            color: if item.is_comment {
                                Some("#888888".to_string())
                            } else {
                                item.color.clone()
                            },
                            // 本章说：强制固定小字号覆盖
                            font_scale: if item.is_comment {
                                Some(0.7)
                            } else {
                                (para_max_scale != 1.0).then_some(para_max_scale)
                            },
                            segments,
                            is_chapter_start: char_index == 0 && page_start_char == 0,
                            is_comment: item.is_comment,
                        }));
                        text_lines_on_page += 1;
                        current_y += line_h;
                    }
                    // 段后间距（em → px）：页首自动折叠已由段前处理
                    let space_after = item.spacing_after_em * self.config.font_size;
                    current_y += space_after.max(self.config.paragraph_spacing);
                    char_index += 1; // newline
                }
                LayoutItem::Image {
                    resource_href,
                    aspect,
                    width_percent,
                    align,
                    bleed,
                } => {
                    let ratio = if *aspect > 0.01 { *aspect } else { 0.75 };
                    let (mut img_width, mut img_x) = if *bleed {
                        // 出血：整窗宽、左右贴边
                        (self.config.width, 0.0)
                    } else {
                        let width_pct = width_percent.unwrap_or(100.0).clamp(1.0, 100.0);
                        let w = content_width * width_pct / 100.0;
                        let x = match align {
                            Some(LayoutAlign::Center) => {
                                self.config.padding.left + (content_width - w) / 2.0
                            }
                            Some(LayoutAlign::Right) => {
                                self.config.padding.left + content_width - w
                            }
                            _ => self.config.padding.left,
                        };
                        (w, x)
                    };
                    let mut img_height = img_width / ratio;
                    // 超页高大图：缩至整页内容高内（宽等比收缩）
                    let max_height = if *bleed { bottom_limit } else { content_height };
                    if img_height > max_height {
                        img_height = max_height;
                        // 宽随高收缩并保持对齐基准
                        let scaled_w = img_height * ratio;
                        if *bleed {
                            // 出血图超高：保持 x=0 铺满会破坏纵横比，改为居中收窄
                            img_width = scaled_w;
                            img_x = (self.config.width - scaled_w) / 2.0;
                        } else {
                            img_width = scaled_w;
                        }
                    }

                    // 当前页放不下且页非空 → 翻页；翻页后仍放不下（整页高）
                    // 则独占新页顶部。出血图在页首贴顶（y=0）
                    if current_y + img_height > bottom_limit && !entries.is_empty() {
                        break_page!();
                    }
                    let y = if *bleed && entries.is_empty() && text_lines_on_page == 0 {
                        0.0
                    } else {
                        current_y
                    };

                    entries.push(PageEntry::Image(ImageEntry {
                        resource_href: resource_href.clone(),
                        x: img_x,
                        y,
                        width: img_width,
                        height: img_height,
                    }));
                    // 图片不消耗字符锚点；图后留段间距
                    current_y = y + img_height + self.config.paragraph_spacing;
                }
                LayoutItem::Table(table) => {
                    // 表格前垂直留白（margin-top 百分比 × 内容高）
                    if let Some(pct) = table.margin_top_percent {
                        let gap = content_height * pct / 100.0;
                        if current_y + gap > bottom_limit && !entries.is_empty() {
                            break_page!();
                        }
                        current_y += gap;
                    }
                    let Some((lines, rects, total_h, chars)) =
                        self.layout_table(table, content_width, font)?
                    else {
                        continue;
                    };

                    // 原子块：当前页放不下且页非空 → 整表翻页
                    if current_y + total_h > bottom_limit && !entries.is_empty() {
                        break_page!();
                    }

                    for (mut line, x_off) in lines {
                        line.y += current_y;
                        line.x += x_off;
                        line.is_chapter_start = char_index == 0 && page_start_char == 0;
                        text_lines_on_page += 1;
                        entries.push(PageEntry::Text(line));
                    }
                    // 单元格线框：y 平移到页面绝对坐标（x 在 layout_table 已折算）
                    for mut rect in rects {
                        rect.y += current_y;
                        entries.push(PageEntry::Rect(rect));
                    }
                    current_y += total_h + self.config.paragraph_spacing;
                    char_index += chars; // 锚点由 layout_table 统一累计（含段落分隔）
                }
            }
        }

        // 末页
        if !entries.is_empty() {
            pages.push(Page {
                page_index: pages.len(),
                chapter_index,
                entries,
                start_char_index: page_start_char,
                end_char_index: char_index,
            });
        }

        // 空内容保护（纯背景装饰页：单张空页承载整页背景）
        if pages.is_empty() {
            pages.push(Page {
                page_index: 0,
                chapter_index,
                entries: Vec::new(),
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        Ok(pages)
    }

    /// Layout a single paragraph into lines with real glyph measurement
    ///
    /// M7-P4 断行精修：
    /// - 行首禁则（。，」等不得居行首）：断行点命中禁则时回退上一行末片段；
    /// - 英文整词移行：断点落在词字符内时，把上一行尾部连续词字符整体带下。
    /// 两种回退只在相邻行间搬移已计宽片段，Σ字符数不变 ⇒ 锚点口径不变。
    fn layout_paragraph(
        &self,
        paragraph: &str,
        max_width: f32,
        font: &ab_glyph::FontRef<'static>,
    ) -> Result<Vec<String>> {
        const LINE_START_FORBIDDEN: &[char] = &[
            '，', '。', '、', '；', '：', '？', '！', '”', '’', '」', '』', '）',
            '】', '〉', '》', '…', '—', '～', '·', '%', '％',
        ];
        const LINE_END_FORBIDDEN: &[char] =
            &['「', '『', '（', '【', '〈', '《'];
        fn is_word_char(c: char) -> bool {
            c.is_ascii_alphanumeric() || c == '_'
        }

        let eps = Self::line_fill_epsilon(max_width);
        let mut finished: Vec<String> = Vec::new();
        // 当前行按 grapheme 片段维护（含判满有效宽度 = 字宽 + 字距），
        // 禁则回退需按片段弹出
        let mut pieces: Vec<&str> = Vec::new();
        let mut eff_widths: Vec<f32> = Vec::new();
        let mut current_width = 0.0f32;

        let gs: Vec<&str> = paragraph.graphemes(true).collect();
        for &g in &gs {
            let ch = g.chars().next().unwrap_or(' ');
            let w = self.get_char_width(ch, font);

            if current_width + w > max_width - eps && !pieces.is_empty() {
                let head_forbidden = LINE_START_FORBIDDEN.contains(&ch);
                let word_boundary = is_word_char(ch)
                    && pieces
                        .last()
                        .and_then(|p| p.chars().next())
                        .map_or(false, is_word_char);

                if head_forbidden || word_boundary {
                    // 统一回退循环：
                    // ① 断词连续性——边界两侧同为词字符 ⇒ 整词拖带；
                    // ② 行首禁则——ch 为禁则标点 ⇒ 至少带一个直接前导片段；
                    // ③ 行尾禁则——上一行末尾是开括号类 ⇒ 移入下行。
                    // 拖带过程持续维持「不产生新的词中断裂」。
                    let mut pulled: Vec<&str> = Vec::new();
                    let mut pulled_w = 0.0f32;
                    loop {
                        if pieces.is_empty() || pulled.len() >= 16 {
                            break;
                        }
                        let tail_c = pieces.last().and_then(|p| p.chars().next());
                        let tail_word = tail_c.map_or(false, is_word_char);
                        let head_c = pulled
                            .first()
                            .and_then(|p| p.chars().next())
                            .unwrap_or(ch);
                        if is_word_char(head_c) && tail_word {
                            let p = pieces.pop().unwrap();
                            pulled.insert(0, p);
                            pulled_w += eff_widths.pop().unwrap_or(0.0);
                            continue;
                        }
                        if pulled.is_empty() && head_forbidden {
                            let p = pieces.pop().unwrap();
                            pulled.insert(0, p);
                            pulled_w += eff_widths.pop().unwrap_or(0.0);
                            continue;
                        }
                        if pulled.is_empty()
                            && tail_c.map_or(false, |c| LINE_END_FORBIDDEN.contains(&c))
                        {
                            let p = pieces.pop().unwrap();
                            pulled.insert(0, p);
                            pulled_w += eff_widths.pop().unwrap_or(0.0);
                            continue;
                        }
                        break;
                    }
                    if pulled.is_empty() {
                        finished.push(pieces.concat());
                        pieces.clear();
                        eff_widths.clear();
                        current_width = 0.0;
                    } else {
                        finished.push(pieces.concat());
                        for p in pulled.drain(..) {
                            pieces.push(p);
                        }
                        current_width = pulled_w;
                    }
                } else {
                    finished.push(pieces.concat());
                    pieces.clear();
                    eff_widths.clear();
                    current_width = 0.0;
                }
            }

            pieces.push(g);
            eff_widths.push(w + self.config.letter_spacing);
            current_width += w + self.config.letter_spacing;
        }

        if !pieces.is_empty() {
            finished.push(pieces.concat());
        }

        Ok(finished)
    }
    
    /// 判满安全余量（M7）：吸收 Skia 相对 ab_glyph 的正向测量偏差。
    /// 混合式 max(1px, 0.5%)、上限 2%——纯固定值大宽度占比失衡，
    /// 纯百分比窄列失效
    fn line_fill_epsilon(max_width: f32) -> f32 {
        ((max_width * 0.005).max(1.0)).min(max_width * 0.02)
    }

    /// Get character width with caching
    fn get_char_width(&self, ch: char, font: &ab_glyph::FontRef<'static>) -> f32 {
        let key = GlyphKey::new(ch, self.config.font_size, &self.config.font_name);
        
        // Try cache first
        if let Some(metrics) = self.glyph_cache.get(&key) {
            return metrics.width;
        }
        
        // Measure and cache
        let metrics = self.font_manager.measure_char(font, ch, self.config.font_size);
        self.glyph_cache.put(key, metrics);
        
        metrics.width
    }

    /// 按字号倍率取字符宽（缩放字号独立进缓存键；1.0 走原路径）
    fn get_char_width_scaled(
        &self,
        ch: char,
        font: &ab_glyph::FontRef<'static>,
        scale: f32,
    ) -> f32 {
        if (scale - 1.0).abs() < 0.001 {
            return self.get_char_width(ch, font);
        }
        let fs = (self.config.font_size * scale).max(1.0);
        let key = GlyphKey::new(ch, fs, &self.config.font_name);
        if let Some(metrics) = self.glyph_cache.get(&key) {
            return metrics.width;
        }
        let metrics = self.font_manager.measure_char(font, ch, fs);
        self.glyph_cache.put(key, metrics);
        metrics.width
    }

    /// 字符位置处生效的字号倍率：覆盖 run 优先，块级兜底
    fn scale_at(runs: &[RunSpan], item_scale: Option<f32>, idx: usize) -> f32 {
        runs.iter()
            .find(|r| idx >= r.start && idx < r.end)
            .and_then(|r| r.font_scale)
            .or(item_scale)
            .unwrap_or(1.0)
    }

    /// 对齐折算为行起点 x（width 保持内容宽不变，仅平移原点）
    fn align_line_x(&self, line_width: f32, content_width: f32, align: Option<LayoutAlign>) -> f32 {
        match align {
            Some(LayoutAlign::Center) => {
                self.config.padding.left + (content_width - line_width).max(0.0) / 2.0
            }
            Some(LayoutAlign::Right) => {
                self.config.padding.left + (content_width - line_width).max(0.0)
            }
            _ => self.config.padding.left,
        }
    }

    /// 段落 runs 与行的字符区间求交 → 行内分段（偏移转为行内坐标）
    fn segments_for_line(line: &LaidLine, item: &TextItem) -> Vec<LineSeg> {
        if line.char_end <= line.char_start {
            return Vec::new();
        }
        item.runs
            .iter()
            .filter_map(|r| {
                let s = r.start.max(line.char_start);
                let e = r.end.min(line.char_end);
                if e <= s {
                    return None;
                }
                Some(LineSeg {
                    start: s - line.char_start,
                    end: e - line.char_start,
                    color: r.color.clone(),
                    font_scale: r.font_scale,
                    bold: r.bold,
                    italic: r.italic,
                    underline: r.underline,
                })
            })
            .collect()
    }

    /// 样式化段落排版：按逐字倍率测量换行，产出带实测宽度与段落内
    /// 字符区间的行列表。与 layout_paragraph 的差异：支持 \n 显式断行、
    /// 字号缩放测量、记录行区间供分段映射。TXT 路径仍走旧函数不动。
    ///
    /// M7-P4 断行精修与 TXT 同款：行首禁则回退 + 英文整词移行；
    /// 片段搬移只在相邻行间进行，char 区间总量不变 ⇒ 锚点口径不变。
    fn layout_styled_paragraph(
        &self,
        item: &TextItem,
        max_width: f32,
        font: &ab_glyph::FontRef<'static>,
    ) -> Result<Vec<LaidLine>> {
        const LINE_START_FORBIDDEN: &[char] = &[
            '，', '。', '、', '；', '：', '？', '！', '”', '’', '」', '』', '）',
            '】', '〉', '》', '…', '—', '～', '·', '%', '％',
        ];
        const LINE_END_FORBIDDEN: &[char] =
            &['「', '『', '（', '【', '〈', '《'];
        fn is_word_char(c: char) -> bool {
            c.is_ascii_alphanumeric() || c == '_'
        }

        let mut lines: Vec<LaidLine> = Vec::new();
        // 当前行片段：(grapheme, 字符数, 判满有效宽度)
        let mut pieces: Vec<(&str, usize, f32)> = Vec::new();
        let mut line_chars = 0usize;
        let mut current_width = 0.0f32;
        let mut line_start = 0usize;
        let mut gi = 0usize;
        let mut pending_newlines = 0usize;
        // M7 安全余量：吸收 Dart/Skia 相对 ab_glyph 的正向测量偏差
        let eps = Self::line_fill_epsilon(max_width);

        macro_rules! flush_line {
            ($flushed_len:expr) => {{
                lines.push(LaidLine {
                    text: pieces.iter().map(|p| p.0).collect(),
                    width: current_width,
                    char_start: line_start,
                    char_end: line_start + $flushed_len,
                    newlines_before: pending_newlines,
                });
                pending_newlines = 0;
            }};
        }

        for grapheme in item.text.graphemes(true) {
            if grapheme == "\n" {
                if !pieces.is_empty() {
                    flush_line!(line_chars);
                    line_start += line_chars + 1; // 越过行内容与该 \n
                    pieces.clear();
                    line_chars = 0;
                    current_width = 0.0;
                } else {
                    // 行首换行（连续 <br>）：计入下一行
                    pending_newlines += 1;
                    line_start = gi + 1;
                }
                gi += 1;
                continue;
            }
            let scale = Self::scale_at(&item.runs, item.font_scale, gi);
            let ch = grapheme.chars().next().unwrap_or(' ');
            let w_eff =
                self.get_char_width_scaled(ch, font, scale) + self.config.letter_spacing;

            if current_width + w_eff > max_width - eps && !pieces.is_empty() {
                let head_forbidden = LINE_START_FORBIDDEN.contains(&ch);
                let word_boundary = is_word_char(ch)
                    && pieces
                        .last()
                        .and_then(|p| p.0.chars().next())
                        .map_or(false, is_word_char);

                if head_forbidden || word_boundary {
                    // 统一回退循环（与 TXT 路径同规则）：
                    // ① 断词连续性 ② 行首禁则 ③ 行尾禁则
                    let mut pulled: Vec<(&str, usize, f32)> = Vec::new();
                    let mut pulled_chars = 0usize;
                    let mut pulled_w = 0.0f32;
                    loop {
                        if pieces.is_empty() || pulled.len() >= 16 || line_chars <= 1 {
                            break;
                        }
                        let tail_c = pieces.last().and_then(|p| p.0.chars().next());
                        let tail_word = tail_c.map_or(false, is_word_char);
                        let head_c = pulled
                            .first()
                            .and_then(|p| p.0.chars().next())
                            .unwrap_or(ch);
                        if is_word_char(head_c) && tail_word {
                            let (g0, c0, w0) = pieces.pop().unwrap();
                            pulled.insert(0, (g0, c0, w0));
                            pulled_chars += c0;
                            pulled_w += w0;
                            line_chars -= c0;
                            current_width -= w0;
                            continue;
                        }
                        if pulled.is_empty() && head_forbidden {
                            let (g0, c0, w0) = pieces.pop().unwrap();
                            pulled.insert(0, (g0, c0, w0));
                            pulled_chars += c0;
                            pulled_w += w0;
                            line_chars -= c0;
                            current_width -= w0;
                            continue;
                        }
                        if pulled.is_empty()
                            && tail_c.map_or(false, |c| LINE_END_FORBIDDEN.contains(&c))
                        {
                            let (g0, c0, w0) = pieces.pop().unwrap();
                            pulled.insert(0, (g0, c0, w0));
                            pulled_chars += c0;
                            pulled_w += w0;
                            line_chars -= c0;
                            current_width -= w0;
                            continue;
                        }
                        break;
                    }
                    flush_line!(line_chars);
                    line_start += line_chars;
                    for (g0, c0, w0) in pulled {
                        pieces.push((g0, c0, w0));
                    }
                    line_chars = pulled_chars;
                    current_width = pulled_w;
                } else {
                    flush_line!(line_chars);
                    line_start += line_chars;
                    pieces.clear();
                    line_chars = 0;
                    current_width = 0.0;
                }
            }
            let g_chars = grapheme.chars().count();
            pieces.push((grapheme, g_chars, w_eff));
            line_chars += g_chars;
            current_width += w_eff;
            gi += g_chars;
        }
        if !pieces.is_empty() {
            flush_line!(line_chars);
        }
        Ok(lines)
    }

    /// 表格原子排版：返回（定位行[(行, 列x偏移)], 单元格线框矩形,
    /// 总高, 锚点字符增量）。列宽：同列 em 提示最大值 × 基准字号；
    /// 提示总量超内容宽等比收缩，无提示列均分剩余；全无提示则等分。
    /// 单元格文本按列宽换行，行高取该行最大字号倍率的行高累计。
    /// 空表返回 None。
    fn layout_table(
        &self,
        table: &TableInput,
        content_width: f32,
        font: &ab_glyph::FontRef<'static>,
    ) -> Result<Option<(Vec<(TextLine, f32)>, Vec<RectEntry>, f32, usize)>> {
        let Some(col_count) = table.rows.iter().map(|r| r.len()).max() else {
            return Ok(None);
        };
        if col_count == 0 {
            return Ok(None);
        }

        // 列宽分配
        let mut col_hint: Vec<Option<f32>> = vec![None; col_count];
        for row in &table.rows {
            for (ci, cell) in row.iter().enumerate() {
                if let Some(em) = cell.width_em {
                    let w = em * self.config.font_size;
                    col_hint[ci] = Some(col_hint[ci].map_or(w, |cur| cur.max(w)));
                }
            }
        }
        let hinted_sum: f32 = col_hint.iter().flatten().sum();
        let mut col_widths = vec![0.0f32; col_count];
        if col_hint.iter().all(Option::is_none) {
            let w = content_width / col_count as f32;
            col_widths.iter_mut().for_each(|c| *c = w);
        } else {
            let k = if hinted_sum > content_width && hinted_sum > 0.0 {
                content_width / hinted_sum
            } else {
                1.0
            };
            let free_count = col_hint.iter().filter(|c| c.is_none()).count();
            let free_w = if free_count > 0 {
                (content_width - hinted_sum * k).max(0.0) / free_count as f32
            } else {
                0.0
            };
            for ci in 0..col_count {
                col_widths[ci] = match col_hint[ci] {
                    Some(w) => w * k,
                    None => free_w,
                };
            }
        }
        // 列 x 前缀和（含水平基准：默认左缘=左 padding；
        // margin-left:auto 时整表右移至内容区右缘）
        let table_w: f32 = col_widths.iter().sum();
        let base_x = if table.margin_left_auto {
            self.config.padding.left + (content_width - table_w).max(0.0)
        } else {
            self.config.padding.left
        };
        let mut col_x = vec![0.0f32; col_count + 1];
        for ci in 0..col_count {
            col_x[ci + 1] = col_x[ci] + col_widths[ci];
        }

        let mut out: Vec<(TextLine, f32)> = Vec::new();
        let mut rects: Vec<RectEntry> = Vec::new();
        let mut table_h = 0.0f32;
        let mut anchor_chars = 0usize;

        for row in &table.rows {
            let mut row_h = 0.0f32;
            // 先逐单元格排（y 相对行顶），行高取最大者
            let mut cell_lines: Vec<(usize, Vec<TextLine>)> = Vec::new();
            for (ci, cell) in row.iter().enumerate() {
                let col_w = col_widths[ci.min(col_count - 1)].max(1.0);
                let mut lines_rel: Vec<TextLine> = Vec::new();
                let mut cy = 0.0f32;
                for titem in &cell.items {
                    let laid = self.layout_styled_paragraph(titem, col_w, font)?;
                    if laid.is_empty() {
                        continue;
                    }
                    let max_scale = titem
                        .font_scale
                        .unwrap_or(1.0)
                        .max(titem.runs.iter().filter_map(|r| r.font_scale).fold(1.0, f32::max));
                    let line_h = self.config.font_size
                        * self.config.line_height_multiplier
                        * max_scale;
                    for line in laid {
                        let x_in_cell =
                            match titem.align {
                                Some(LayoutAlign::Center) => ((col_w - line.width).max(0.0)) / 2.0,
                                Some(LayoutAlign::Right) => (col_w - line.width).max(0.0),
                                _ => 0.0,
                            };
                        lines_rel.push(TextLine {
                            text: line.text.clone(),
                            x: x_in_cell,
                            y: cy,
                            width: col_w,
                            height: line_h,
                            color: titem.color.clone(),
                            font_scale: (max_scale != 1.0).then_some(max_scale),
                            segments: Self::segments_for_line(&line, titem),
                            is_chapter_start: false,
                            is_comment: false,
                        });
                        cy += line_h;
                        anchor_chars += line.char_end - line.char_start + line.newlines_before;
                    }
                    cy += self.config.paragraph_spacing;
                    anchor_chars += 1;
                }
                row_h = row_h.max((cy - self.config.paragraph_spacing).max(0.0));
                cell_lines.push((ci, lines_rel));
            }

            for (ci, lines_rel) in cell_lines {
                let x_off = base_x + col_x[ci.min(col_count)];
                for mut tl in lines_rel {
                    tl.y += table_h;
                    out.push((tl, x_off));
                }
            }
            // 单元格线框矩形：x 已含水平基准（margin_left_auto 右置随 base_x）
            for (ci, _) in row.iter().enumerate() {
                rects.push(RectEntry {
                    x: base_x + col_x[ci.min(col_count)],
                    y: table_h,
                    width: col_widths[ci.min(col_count - 1)],
                    height: row_h,
                });
            }
            table_h += row_h;
        }

        if out.is_empty() {
            return Ok(None);
        }
        Ok(Some((out, rects, table_h, anchor_chars)))
    }

    /// Get specific page
    pub fn get_page(&self, text: &str, chapter_index: usize, page_index: usize) -> Result<Option<Page>> {
        let pages = self.layout_text(text, chapter_index)?;
        Ok(pages.get(page_index).cloned())
    }

    /// Get total page count
    pub fn get_page_count(&self, text: &str, chapter_index: usize) -> Result<usize> {
        let pages = self.layout_text(text, chapter_index)?;
        Ok(pages.len())
    }
    
    /// Get cache statistics
    pub fn get_cache_stats(&self) -> CacheStats {
        self.glyph_cache.stats()
    }
    
    /// Clear glyph cache
    pub fn clear_cache(&self) {
        self.glyph_cache.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_engine() -> (LayoutEngine, LayoutConfig) {
        let mut font_manager = FontManager::new();
        
        // Try to load a system font (Windows example)
        let font_paths = vec![
            "C:/Windows/Fonts/simsun.ttc",
            "C:/Windows/Fonts/msyh.ttc",
            "C:/Windows/Fonts/arial.ttf",
        ];
        
        let mut loaded = false;
        for path in font_paths {
            if std::path::Path::new(path).exists() {
                if font_manager.load_font_from_file("TestFont".to_string(), path).is_ok() {
                    loaded = true;
                    break;
                }
            }
        }
        
        if !loaded {
            // Create a mock font for testing without system fonts
            println!("Warning: No system fonts found, tests may fail");
        }
        
        let config = LayoutConfig {
            width: 300.0,
            height: 400.0,
            font_size: 16.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 10.0,
                top: 10.0,
                right: 10.0,
                bottom: 10.0,
            },
            font_name: "TestFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 8.0,
            page_fill_threshold: 0.9,
            show_comments: true,
        };
        
        let engine = LayoutEngine::new(config.clone(), font_manager);
        (engine, config)
    }

    #[test]
    fn test_layout_simple_text() {
        let (engine, _) = create_test_engine();
        let text = "这是一段测试文本。\n这是第二段。";
        
        match engine.layout_text(text, 0) {
            Ok(pages) => {
                assert!(!pages.is_empty());
                assert!(pages[0].entries.len() > 0);
                println!("生成了 {} 页", pages.len());
                
                // Check cache stats
                let stats = engine.get_cache_stats();
                println!("缓存统计: {:?}", stats);
            }
            Err(e) => {
                println!("布局失败（可能是没有字体）: {}", e);
            }
        }
    }

    #[test]
    fn test_get_page_count() {
        let (engine, _) = create_test_engine();
        let text = "Short text";
        
        match engine.get_page_count(text, 0) {
            Ok(count) => {
                assert_eq!(count, 1);
            }
            Err(e) => {
                println!("获取页数失败: {}", e);
            }
        }
    }
    
    #[test]
    fn test_cache_hit_rate() {
        let (engine, _) = create_test_engine();
        let text = "测试测试测试"; // Repeated characters
        
        if let Ok(_pages) = engine.layout_text(text, 0) {
            let stats = engine.get_cache_stats();
            println!("缓存命中率: {:.2}%", stats.hit_rate);
            
            // With repeated characters, hit rate should be high
            if stats.hits + stats.misses > 0 {
                assert!(stats.hit_rate > 0.0);
            }
        }
    }
    
    #[test]
    fn test_multi_page_layout() {
        let (engine, _) = create_test_engine();
        
        // Generate long text to span multiple pages
        let text = "这是一段很长的文本。".repeat(100);
        
        if let Ok(pages) = engine.layout_text(&text, 0) {
            println!("长文本生成了 {} 页", pages.len());
            
            // Should have multiple pages
            assert!(pages.len() > 1);
            
            // Check page indices
            for (i, page) in pages.iter().enumerate() {
                assert_eq!(page.page_index, i);
                assert_eq!(page.chapter_index, 0);
            }
        }
    }

    // ===== layout_items（结构化混合分页） =====

    fn img(href: &str, aspect: f32) -> LayoutItem {
        LayoutItem::Image {
            resource_href: href.to_string(),
            aspect,
            width_percent: None,
            align: Some(LayoutAlign::Center),
            bleed: false,
        }
    }

    /// 空输入（纯背景装饰页）：单张空页承载背景，page_count=1
    #[test]
    fn items_empty_produces_single_blank_page() {
        let (engine, _) = create_test_engine();
        let pages = engine.layout_items(&[], 3).unwrap();
        assert_eq!(pages.len(), 1);
        assert!(pages[0].entries.is_empty());
        assert_eq!(pages[0].start_char_index, 0);
        assert_eq!(pages[0].end_char_index, 0);
        assert_eq!(pages[0].chapter_index, 3);
    }

    /// 出血图（duokan-bleed）：整窗宽、x=0、页首贴顶
    #[test]
    fn items_bleed_image_spans_full_window_at_top() {
        let (engine, config) = create_test_engine();
        let items = vec![LayoutItem::Image {
            resource_href: "OEBPS/Images/logo.png".to_string(),
            aspect: 1.5,
            width_percent: Some(100.0),
            align: Some(LayoutAlign::Center),
            bleed: true,
        }];
        let pages = engine.layout_items(&items, 0).unwrap();
        let e = match &pages[0].entries[0] {
            PageEntry::Image(i) => i.clone(),
            other => panic!("首项应为图片，实为 {:?}", other),
        };
        assert!((e.x - 0.0).abs() < 0.01, "出血图 x 必须为 0");
        assert!((e.width - config.width).abs() < 0.01, "出血图必须占满整窗宽");
        assert!((e.y - 0.0).abs() < 0.01, "页首出血图必须贴顶");

        // 后续文本从图片底部继续流动
        let items2 = vec![
            items[0].clone(),
            LayoutItem::text("正文段落"),
        ];
        let pages2 = engine.layout_items(&items2, 0).unwrap();
        let first_text_y = pages2[0]
            .entries
            .iter()
            .find_map(|e| match e {
                PageEntry::Text(l) => Some(l.y),
                _ => None,
            })
            .expect("应有文本行");
        assert!(
            first_text_y >= e.y + e.height,
            "文本不得与出血图重叠"
        );
    }

    /// 图片宽度/对齐折算 + 不消耗字符锚点
    #[test]
    fn items_image_measured_and_anchor_free() {
        let (engine, config) = create_test_engine();
        let content_width = config.width - config.padding.left - config.padding.right;
        let items = vec![
            LayoutItem::text("第一段"),
            img("OEBPS/Images/logo.png", 2.0), // 宽:高=2:1 → 高为宽一半
        ];
        let pages = engine.layout_items(&items, 0).unwrap();

        // 图与文同页（默认页面尺寸下两者都能放下）
        assert_eq!(pages.len(), 1);
        let texts: Vec<&str> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(texts, vec!["第一段"]);

        let image_entry = pages[0]
            .entries
            .iter()
            .find_map(|e| match e {
                PageEntry::Image(i) => Some(i),
                _ => None,
            })
            .expect("应含图片项");
        assert_eq!(image_entry.resource_href, "OEBPS/Images/logo.png");
        assert!((image_entry.width - content_width).abs() < 0.01, "width_percent 缺省=100%");
        assert!((image_entry.height - content_width / 2.0).abs() < 0.01);
        // 居中
        assert!((image_entry.x - (config.padding.left + (content_width - image_entry.width) / 2.0)).abs() < 0.01);

        // 锚点：图片不消耗字符——末页 end_char_index == 文本字符数+换行
        let text_chars = "第一段".chars().count();
        assert_eq!(pages[0].end_char_index, text_chars + 1);
        assert_eq!(pages[0].start_char_index, 0);
    }

    /// 剩余空间放不下图片 → 图片推至次页；文本锚点跨页保持连续
    #[test]
    fn items_image_pushed_to_next_page_when_overflowing() {
        let (engine, _) = create_test_engine();
        // aspect=0.5 → 高度是内容宽的两倍，远超剩余空间
        let items = vec![
            LayoutItem::text("段落甲。".repeat(30)),
            img("a.png", 0.5),
            LayoutItem::text("段落乙。".repeat(5)),
        ];
        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 2);

        // a.png 所在页的首项即该图（顶部对齐）
        let img_page = pages
            .iter()
            .find(|p| p.entries.iter().any(|e| matches!(e, PageEntry::Image(i) if i.resource_href == "a.png")))
            .expect("应存在含图页");
        match &img_page.entries[0] {
            PageEntry::Image(i) => assert_eq!(i.resource_href, "a.png"),
            other => panic!("含图页首项应为图片，实为 {:?}", other),
        }
        // 锚点单调不减且连续
        for w in pages.windows(2) {
            assert!(w[0].end_char_index <= w[1].start_char_index);
        }
    }

    /// 超整页高大图：缩至页高内、独占一页
    #[test]
    fn items_oversized_image_scaled_to_page_height() {
        let (engine, config) = create_test_engine();
        let content_height = config.height - config.padding.top - config.padding.bottom;
        let items = vec![
            LayoutItem::text("前文"),
            img("huge.png", 10.0), // 极宽图：等比缩放前高度必超页高
        ];
        let pages = engine.layout_items(&items, 0).unwrap();
        let image_entry = pages
            .iter()
            .flat_map(|p| p.entries.iter())
            .find_map(|e| match e {
                PageEntry::Image(i) if i.resource_href == "huge.png" => Some(i.clone()),
                _ => None,
            })
            .expect("应含超大图");
        assert!(
            image_entry.height <= content_height + 0.01,
            "图高不得超过整页内容高"
        );
    }

    /// 连续多图依次排列、各自独立成块
    #[test]
    fn items_consecutive_images_stack() {
        let (engine, _) = create_test_engine();
        let items = vec![img("a.png", 4.0), img("b.png", 4.0)];
        let pages = engine.layout_items(&items, 0).unwrap();
        let images: Vec<&str> = pages
            .iter()
            .flat_map(|p| p.entries.iter())
            .filter_map(|e| match e {
                PageEntry::Image(i) => Some(i.resource_href.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(images, vec!["a.png", "b.png"]);
    }

    // ===== 样式化文本与表格（M3） =====

    fn text_item(text: &str) -> TextItem {
        TextItem {
            text: text.to_string(),
            ..Default::default()
        }
    }

    /// 块级颜色与字号倍率落到行上；缩放段落的行高同步放大；
    /// 居中对齐折算 x 起点
    #[test]
    fn styled_text_carries_color_scale_and_align() {
        let (engine, config) = create_test_engine();
        let content_width = config.width - config.padding.left - config.padding.right;
        let base_line_h = config.font_size * config.line_height_multiplier;
        let items = vec![LayoutItem::Text(TextItem {
            text: "卷".to_string(),
            align: Some(LayoutAlign::Center),
            color: Some("#b50a02".to_string()),
            font_scale: Some(1.4),
            runs: Vec::new(),
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            is_comment: false,
        })];
        let pages = engine.layout_items(&items, 0).unwrap();
        let line = match &pages[0].entries[0] {
            PageEntry::Text(l) => l.clone(),
            other => panic!("应为文本行，实为 {:?}", other),
        };
        assert_eq!(line.color.as_deref(), Some("#b50a02"));
        assert_eq!(line.font_scale, Some(1.4));
        assert!((line.height - base_line_h * 1.4).abs() < 0.01);

        // 居中：单字宽 ≈ font_size×scale（全角字形），x 应落在内容区中点附近
        let char_w = config.font_size * 1.4;
        let x_lo = config.padding.left + (content_width - char_w * 1.05) / 2.0 - 0.5;
        let x_hi = config.padding.left + content_width / 2.0;
        assert!(
            line.x >= x_lo && line.x <= x_hi,
            "居中行 x={} 应在 [{}, {}] 区间内",
            line.x,
            x_lo,
            x_hi
        );

        // 默认段落不携带样式字段、x 恒为左 padding
        let plain = engine.layout_items(&[LayoutItem::text("普通")], 0).unwrap();
        let pline = match &plain[0].entries[0] {
            PageEntry::Text(l) => l.clone(),
            _ => panic!("应为文本行"),
        };
        assert_eq!(pline.color, None);
        assert_eq!(pline.font_scale, None);
        assert!((pline.x - config.padding.left).abs() < 0.01);
    }

    /// 行内 run 跨软换行/自动换行时按行切分分段，偏移转为行内坐标
    #[test]
    fn runs_split_into_per_line_segments() {
        let (engine, _) = create_test_engine();
        // 红字覆盖整段含 \n：两行各得一段
        let items = vec![LayoutItem::Text(TextItem {
            text: "红甲\n红乙".to_string(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                RunSpan { start: 0, end: 2, color: Some("#ff0000".into()), font_scale: None, bold: false, italic: false, underline: false },
                RunSpan { start: 3, end: 5, color: Some("#00ff00".into()), font_scale: None, bold: false, italic: false, underline: false },
            ],
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            is_comment: false,
        })];
        let pages = engine.layout_items(&items, 0).unwrap();
        let lines: Vec<TextLine> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(lines.len(), 2);
        let segs0 = &lines[0].segments;
        assert_eq!(segs0.len(), 1);
        assert_eq!((segs0[0].start, segs0[0].end), (0, 2));
        assert_eq!(segs0[0].color.as_deref(), Some("#ff0000"));
        let segs1 = &lines[1].segments;
        assert_eq!(segs1.len(), 1);
        assert_eq!((segs1[1 - 1].start, segs1[0].end), (0, 2));
        assert_eq!(segs1[0].color.as_deref(), Some("#00ff00"));
    }

    /// 字形样式（bold/italic/underline）跨软换行切段后逐段保持
    #[test]
    fn glyph_flags_survive_line_split() {
        let (engine, _) = create_test_engine();
        // 粗体覆盖整段含 \n：两行各得一段且 bold 保持
        let items = vec![LayoutItem::Text(TextItem {
            text: "粗甲\n粗乙".to_string(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![RunSpan {
                start: 0,
                end: 5,
                color: None,
                font_scale: None,
                bold: true,
                italic: true,
                underline: true,
            }],
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            is_comment: false,
        })];
        let pages = engine.layout_items(&items, 0).unwrap();
        let lines: Vec<TextLine> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(lines.len(), 2);
        for line in &lines {
            assert_eq!(line.segments.len(), 1);
            let seg = &line.segments[0];
            assert!(seg.bold && seg.italic && seg.underline);
        }
    }


    /// M7-P3：判满带 epsilon——styled 路径实测行宽（LaidLine.width）必须
    /// 填到「再放一字即超限」，且不超过 max_width - eps（给 Skia 正向偏差留缓冲）
    #[test]
    fn styled_lines_fill_within_epsilon_margin() {
        let (engine, config) = create_test_engine();
        let cw = config.width - config.padding.left - config.padding.right;
        let item = TextItem {
            text: "测".repeat(200),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            is_comment: false,
        };
        let font = engine
            .font_manager
            .get_font(&config.font_name)
            .expect("测试字体应已加载");
        let lines = engine.layout_styled_paragraph(&item, cw, &font).unwrap();
        assert!(lines.len() >= 2, "200 字应产生多行");

        let eps = LayoutEngine::line_fill_epsilon(cw);
        for line in &lines[..lines.len() - 1] {
            assert!(
                line.width <= cw - eps + 0.01,
                "行宽 {} 超过判满上限 {}",
                line.width,
                cw - eps
            );
            // 剩余空间不足以再放一个全角字（advance≈font_size）
            assert!(
                line.width > cw - eps - config.font_size * 1.2,
                "行宽 {} 距上限超过一个字宽，断行过早",
                line.width
            );
        }
    }

    /// M7-P4：避头尾 + 英文整词移行——多宽度扫描行为断言 + 锚点不变量
    #[test]
    fn kinsoku_pullback_and_word_wrap_invariants() {
        const START_FORBIDDEN: &[char] = &[
            '，', '。', '、', '；', '：', '？', '！', '”', '’', '」', '』', '）',
            '】', '〉', '》', '…', '—', '～', '·', '%', '％',
        ];
        fn is_word_char(c: char) -> bool {
            c.is_ascii_alphanumeric() || c == '_'
        }
        let text = "阅读器排版引擎要处理标点悬挂，English words must stay intact，两种规则都要兼顾。";

        for cw in (80..200).step_by(9) {
            let (engine, config) = create_test_engine();
            let font = engine
                .font_manager
                .get_font(&config.font_name)
                .expect("测试字体应已加载");
            let item = TextItem {
                text: text.to_string(),
                align: None,
                color: None,
                font_scale: None,
                runs: Vec::new(),
                spacing_before_em: 0.0,
                spacing_after_em: 0.0,
                is_comment: false,
            };
            let lines = engine
                .layout_styled_paragraph(&item, cw as f32, &font)
                .unwrap();
            if lines.len() < 2 {
                continue;
            }

            // 行为断言：非末行的下一行不得以禁则标点开头；不得切在词中
            for i in 0..lines.len() - 1 {
                let head = lines[i + 1].text.chars().next().unwrap();
                assert!(
                    !START_FORBIDDEN.contains(&head),
                    "cw={cw}: 第{i}行断行使禁则标点居行首（{:#?}）",
                    &lines
                );
                let tail = lines[i].text.chars().last().unwrap();
                assert!(
                    !(is_word_char(tail) && is_word_char(head)),
                    "cw={cw}: 第{i}行在单词中间断开（{}|{}）",
                    &lines[i].text,
                    &lines[i + 1].text
                );
            }

            // 锚点不变量：char 区间从 0 起无缝覆盖全段
            let mut covered = 0usize;
            for l in &lines {
                assert_eq!(l.char_start, covered, "cw={cw}: 区间断层");
                covered += l.char_end - l.char_start;
            }
            assert_eq!(
                covered,
                text.chars().count(),
                "cw={cw}: 行区间总量必须等于原文字符数"
            );
        }
    }

    /// 双列表格：em 列宽强制逐字竖排（卷首页形态）、单元格定位与锚点
    #[test]
    fn table_two_columns_em_width_vertical_stack() {
        let (engine, config) = create_test_engine();
        let content_width = config.width - config.padding.left - config.padding.right;

        let cell = |text: &str, scale: f32| TableCellInput {
            width_em: Some(1.2),
            items: vec![TextItem {
                text: text.to_string(),
                align: Some(LayoutAlign::Center),
                color: Some("#b50a02".to_string()),
                font_scale: Some(scale),
                runs: Vec::new(),
                spacing_before_em: 0.0,
                spacing_after_em: 0.0,
                is_comment: false,
            }],
        };
        let items = vec![LayoutItem::Table(TableInput {
            margin_top_percent: Some(20.0),
            margin_left_auto: false,
            rows: vec![vec![cell("卷一", 1.4), cell("第一卷", 0.9)]],
        })];

        let pages = engine.layout_items(&items, 0).unwrap();
        let lines: Vec<&TextLine> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .collect();

        // 列宽 = 1.2em × 16px = 19.2px；字号 1.4×16≈22px > 列宽 → 逐字换行。
        // 单元格「卷一」→ 2 行、「第一卷」→ 3 行，共 5 行
        assert_eq!(lines.len(), 5, "窄列必须逐字竖排");

        // 两列 x 偏移不同：第一列贴左 padding，第二列在其右一个列宽处
        let col_w = 1.2 * config.font_size;
        let first_col_x = lines.iter().map(|l| l.x).fold(f32::MAX, f32::min);
        let second_col_x = lines
            .iter()
            .map(|l| l.x)
            .fold(f32::MIN, f32::max);
        assert!(
            (second_col_x - first_col_x).abs() >= col_w - 1.0,
            "第二列相对第一列应至少偏移一个列宽"
        );
        assert!(
            (first_col_x - config.padding.left).abs() < 0.01,
            "首列应精确落在左 padding（x={}，padding={})",
            first_col_x,
            config.padding.left
        );

        // margin-top 20% 内容高：首行 y ≥ padding.top + gap
        let gap = (config.height - config.padding.top - config.padding.bottom) * 0.2;
        let min_y = lines.iter().map(|l| l.y).fold(f32::MAX, f32::min);
        assert!(
            min_y >= config.padding.top + gap - 0.01,
            "表格前应有 margin-top 留白，y={} gap={}",
            min_y,
            gap
        );

        // 锚点：单元格文本字符 + 段落分隔（2 个单元格 → +2）
        let total_chars: usize = lines.iter().map(|l| l.text.chars().count()).sum();
        assert_eq!(pages[0].end_char_index, total_chars + 2);
        assert_eq!(pages[0].start_char_index, 0);

        // 内容宽兜底：总提示未超宽时不等比收缩（col_w 即实际列宽）
        assert!(content_width > col_w * 2.0, "测试前提：双列远小于内容宽");
    }

    /// 单元格线框矩形：数量=行列积、几何与列宽/行高一致、右置随 base_x 平移
    #[test]
    fn table_cell_rects_emitted() {
        let (engine, config) = create_test_engine();
        let content_width = config.width - config.padding.left - config.padding.right;

        let cell = |text: &str| TableCellInput {
            width_em: Some(1.2),
            items: vec![TextItem {
                text: text.to_string(),
                align: Some(LayoutAlign::Center),
                color: None,
                font_scale: None,
                runs: Vec::new(),
                spacing_before_em: 0.0,
                spacing_after_em: 0.0,
                is_comment: false,
            }],
        };
        // 2 行 × 2 列
        let items = vec![LayoutItem::Table(TableInput {
            margin_top_percent: None,
            margin_left_auto: false,
            rows: vec![
                vec![cell("甲"), cell("乙")],
                vec![cell("丙"), cell("丁")],
            ],
        })];
        let pages = engine.layout_items(&items, 0).unwrap();

        let rects: Vec<RectEntry> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Rect(r) => Some(r.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(rects.len(), 4, "矩形数应等于行列积");

        let col_w = 1.2 * config.font_size;
        let left = config.padding.left;
        let right_col_x = left + col_w;
        for r in &rects {
            assert!(
                (r.x - left).abs() < 0.01 || (r.x - right_col_x).abs() < 0.01,
                "矩形 x 应落在两列左缘之一，x={}",
                r.x
            );
            assert!((r.width - col_w).abs() < 0.01);
            assert!(r.height > 0.0);
        }
        // 两行 y 不同（第二行 y = 第一行行高）
        let mut ys: Vec<f32> = rects.iter().map(|r| r.y).collect();
        ys.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert!(ys[3] > ys[0], "两行矩形应有不同 y");

        // 右置表：全部矩形 x 整体平移到内容区右缘
        let items_right = vec![LayoutItem::Table(TableInput {
            margin_top_percent: None,
            margin_left_auto: true,
            rows: rows_single(cell("单")),
        })];
        let pages_r = engine.layout_items(&items_right, 0).unwrap();
        let rect_r = pages_r[0]
            .entries
            .iter()
            .find_map(|e| match e {
                PageEntry::Rect(r) => Some(r.clone()),
                _ => None,
            })
            .expect("应含线框矩形");
        let expected_x = left + (content_width - col_w).max(0.0);
        assert!(
            (rect_r.x - expected_x).abs() < 0.01,
            "margin-left:auto 时矩形应右移，x={} 期望={}",
            rect_r.x,
            expected_x
        );
    }

    fn rows_single(cell: TableCellInput) -> Vec<Vec<TableCellInput>> {
        vec![vec![cell]]
    }

    /// 表格整体放不下当前页 → 整表翻页；空表跳过
    #[test]
    fn table_atomic_break_and_empty_skip() {
        let (engine, _) = create_test_engine();
        let filler = LayoutItem::text("占位。".repeat(40));
        let big_cell = |t: &str| TableCellInput {
            width_em: None,
            items: vec![TextItem {
                text: t.to_string(),
                ..Default::default()
            }],
        };
        // 高表格（多行长文本单元格 × 多行）
        let tall_table = LayoutItem::Table(TableInput {
            margin_top_percent: None,
            margin_left_auto: false,
            rows: (0..6)
                .map(|ri| {
                    vec![
                        big_cell(&format!("第{}行长文本内容较多需要换行展示", ri).repeat(3)),
                        big_cell(&format!("旁注{}", ri)),
                    ]
                })
                .collect(),
        });
        let pages = engine
            .layout_items(&[filler, tall_table], 0)
            .unwrap();
        assert!(pages.len() >= 2, "表格应触发翻页");

        // 含表页的首项必须是表格行（原子性）
        let table_page = pages
            .iter()
            .find(|p| p.entries.iter().any(|e| matches!(e, PageEntry::Text(_)) && p.page_index > 0))
            .expect("应有表格页");
        match &table_page.entries[0] {
            PageEntry::Text(_) => {}
            other => panic!("表格页首项应为文本，实为 {:?}", other),
        }

        // 空表：无行无列 → 跳过不产出条目
        let empty = engine
            .layout_items(
                &[LayoutItem::Table(TableInput {
                    margin_top_percent: None,
                    margin_left_auto: false,
                    rows: Vec::new(),
                })],
                0,
            )
            .unwrap();
        assert!(empty[0].entries.is_empty());
    }

    /// margin-left:auto：整表右置（内容区内贴右缘，卷首页 CSS 语义）
    #[test]
    fn table_margin_left_auto_aligns_right() {
        let (engine, config) = create_test_engine();
        let content_width = config.width - config.padding.left - config.padding.right;
        let col_w = 1.2 * config.font_size;
        let items = vec![LayoutItem::Table(TableInput {
            margin_top_percent: None,
            margin_left_auto: true,
            rows: vec![vec![
                TableCellInput {
                    width_em: Some(1.2),
                    items: vec![text_item("卷")],
                },
                TableCellInput {
                    width_em: Some(1.2),
                    items: vec![text_item("一")],
                },
            ]],
        })];
        let pages = engine.layout_items(&items, 0).unwrap();
        // 双列窄表：右缘对齐 = 左 padding + (内容宽 − 表宽)
        let expected_left = config.padding.left + content_width - col_w * 2.0;
        let min_x = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.x),
                _ => None,
            })
            .fold(f32::MAX, f32::min);
        assert!(
            (min_x - expected_left).abs() < 1.0,
            "auto 表应贴内容区右缘：x={} 预期={}",
            min_x,
            expected_left
        );
    }
}
