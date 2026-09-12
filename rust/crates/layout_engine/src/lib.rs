mod font_manager;
mod glyph_cache;
mod kinsoku;
mod parallel;
pub mod measure_cache;
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
pub use measure_cache::MeasureCache;

use unicode_segmentation::UnicodeSegmentation;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

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
    /// 页面填充率（0.0-1.0）：A25 语义重定义为**内容区利用率**——
    /// 底界 = content_top + content_height × threshold，行级断行提前发生，
    /// 页底按比例统一留白（1.0 填满、0.9 底部收 10%）。
    /// TXT/EPUB 双路径统一消费（对齐行级分页精度批次）
    pub page_fill_threshold: f32,
    /// 是否显示注释（章末注/旁注段落）；true=渲染、false=跳过绘制但保留锚点
    pub show_comments: bool,
    /// 注释行字号倍率（0.70–1.00）。行高与上报 font_scale 均单次覆盖用此值。
    pub comment_scale: f32,
    /// P2 两端对齐（2026-09-04）：TXT 全局开关；段落末行/短行豁免。
    /// EPUB 走 TextItem.align==Justify（CSS 或全局开关在 bridge 层重写）
    pub justify: bool,
    /// P3 行尾标点压缩悬挂（2026-09-04）：判满失败且行尾可压缩标点折半宽
    /// 能放下时收进行尾（预算按压缩宽），渲染端全宽绘制自然悬挂出右缘。
    /// 记录宽度保持 raw 口径（justify 自动豁免悬挂行；TextLine.width 跳过钳制）
    pub punctuation_compress: bool,
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
            page_fill_threshold: 1.0, // A25：1.0 = 行级填满（旧行为基线）
            show_comments: true,
            comment_scale: 0.82,
            justify: false,
            punctuation_compress: false,
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
    /// P2 两端对齐：行内字符间隙（px）。0=左对齐；>0 时 Dart 端经
    /// TextStyle.letterSpacing 消费（含行尾字符的 n_chars 均分语义）
    #[serde(default)]
    pub letter_gap: f32,
    /// A31: 本行章内字符区间 [start, end)（锚点口径，与 Page.start/end_char_index
    /// 同源计数器）。笔记/划线渲染与长按命中测试依赖；表格行 0/0=未知不高亮
    #[serde(default)]
    pub start_char_index: usize,
    #[serde(default)]
    pub end_char_index: usize,
}

/// 行内样式分段：`[start, end)` 字符区间（Rust char 计数）的样式覆盖。
/// None 字段继承行级默认
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LineSeg {
    pub start: usize,
    pub end: usize,
    #[serde(default)]
    pub color: Option<String>,
    /// A31-v6: 段级背景色（#rrggbb；笔记高亮用；None=无背景）
    #[serde(default)]
    pub background_color: Option<String>,
    #[serde(default)]
    pub font_scale: Option<f32>,
    #[serde(default)]
    pub bold: bool,
    #[serde(default)]
    pub italic: bool,
    #[serde(default)]
    pub underline: bool,
    /// P2 两端对齐：拉丁词保护段（Some(0)=该区间不参与空隙拉伸）
    #[serde(default)]
    pub letter_spacing: Option<f32>,
    /// A34：脚注引用 id（点按弹层）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub footnote_ref: Option<String>,
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
    /// P2 两端对齐（2026-09-04）：CSS text-align:justify 回正 +
    /// 全局开关（ParagraphFormatSettings.justify）在 bridge 层重写
    Justify,
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
    /// M9：首行缩进（em 倍数，相对基准字号；None=无缩进）
    /// 布局时首行宽度减去 indent_px，首行 x 偏移 indent_px
    pub indent_first_line_em: Option<f32>,
    /// 本章说标记（JS 提取层 aside/footnote 或 CSS 小字号兜底）
    pub is_comment: bool,
    /// P2：行高倍率覆盖（EPUB CSS line-height 物化；None=用全局
    /// line_height_multiplier——书内显式声明优先，未声明用用户全局）
    pub line_height: Option<f32>,
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
    /// A34：脚注引用 id
    pub footnote_ref: Option<String>,
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
    /// P2 两端对齐：行内字符间隙（px；0=左对齐/豁免行）
    letter_gap: f32,
    /// A33：本行字号倍率（块级 × 行内 run max）；行高 = font_size × line_h × scale
    scale: f32,
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
    /// M10-B：Dart Skia 实测宽度缓存（替代 ttf-parser hmtx 估算）。
    /// 命中 → 返回 Skia 真实宽度；miss → 回退 ttf-parser 估算（不影响 layout 完成）。
    /// 字体切换时通过 `set_measure_cache` 全量 clear()。
    measure_cache: Arc<MeasureCache>,
}

impl LayoutEngine {
    /// Create layout engine with font manager
    pub fn new(config: LayoutConfig, font_manager: FontManager) -> Self {
        Self::with_measure_cache(config, font_manager, Arc::new(MeasureCache::with_default_capacity()))
    }

    /// Create layout engine with existing cache (for parallel use)
    pub fn with_cache(config: LayoutConfig, font_manager: FontManager, cache: GlyphCache) -> Self {
        Self {
            config,
            font_manager,
            glyph_cache: cache,
            measure_cache: Arc::new(MeasureCache::with_default_capacity()),
        }
    }

    /// Create layout engine with explicit measure cache（M10-B：Dart prefill 后调用）
    pub fn with_measure_cache(
        config: LayoutConfig,
        font_manager: FontManager,
        measure_cache: Arc<MeasureCache>,
    ) -> Self {
        Self {
            config,
            font_manager,
            glyph_cache: GlyphCache::new(),
            measure_cache,
        }
    }

    /// P4：双缓存显式注入（共享字形缓存 + 共享测量缓存）。
    ///
    /// structured（EPUB）路径此前经 with_measure_cache 每次全新 GlyphCache——
    /// EPUB 每章首排逐字 ttf 冷查；经此构造器接入 SHARED_GLYPH_CACHE 的
    /// O(1) Arc 共享克隆，prewarm 字形对 EPUB 热路径直接可见。
    pub fn with_cache_and_measure(
        config: LayoutConfig,
        font_manager: FontManager,
        glyph_cache: GlyphCache,
        measure_cache: Arc<MeasureCache>,
    ) -> Self {
        Self {
            config,
            font_manager,
            glyph_cache,
            measure_cache,
        }
    }

    /// 替换 measure cache（Dart prefill 完成后接管）
    pub fn set_measure_cache(&mut self, cache: Arc<MeasureCache>) {
        self.measure_cache = cache;
    }

    /// 当前 measure cache（FFI 暴露给 Dart 用于批量写入）
    pub fn measure_cache(&self) -> Arc<MeasureCache> {
        Arc::clone(&self.measure_cache)
    }

    /// Calculate pages from text content with real font metrics
    pub fn layout_text(&self, text: &str, chapter_index: usize) -> Result<Vec<Page>> {
        let content_width = self.config.width
            - self.config.padding.left
            - self.config.padding.right;
        // M9.2：行级分页不再需要整页填充率，content_height 仅 EPUB 路径使用
        let line_height = self.config.font_size * self.config.line_height_multiplier;
        
        // 分页控制参数
        const MIN_LINES_PER_PAGE: usize = 3;  // 每页最少3行，避免孤行

        let mut pages = Vec::new();
        let mut current_lines = Vec::new();
        let mut current_y = self.config.padding.top;
        let mut char_index = 0;
        let mut page_start_char = 0;
        let mut pending_paragraph_lines: Vec<(String, usize, f32)> = Vec::new(); // (line_text, char_count, letter_gap)
        let mut is_first_line = true;  // 标记是否是章节的第一行

        // M9.2 行级分页辅助宏：放置一行并推进游标（预置阶段与主循环共用）。
        // 必须定义在上述可变绑定之后（macro_rules 标识符按定义点解析）
        macro_rules! emit_line {
            ($line_text:expr, $line_char_count:expr, $letter_gap:expr) => {{
                // M11：width 改用本行实测宽度（cache 命中即 Skia 实宽，
                // miss 仍走 ttf-parser 估算——总比 content_width 硬编码更接近 Skia 实际）
                // M12：传入 effective_font_size=TXT 路径始终 baseFontSize
                let measured_w = self.measure_text_width($line_text, self.config.font_size);
                // M12 必修3 兜底：width 不超过 content_width，避免绘制端"行宽声明 > 实际"
                // （仅影响 TextLine.width 报告值，不影响二分搜索路径——二分搜索用 raw 宽度）
                // P3：悬挂行跳过钳制（见 report_line_width 注释）
                let content_width = self.content_width();
                let clamped_w = self.report_line_width(measured_w, $line_text, content_width);
                current_lines.push(TextLine {
                    text: $line_text.clone(),
                    x: self.config.padding.left,
                    y: current_y,
                    width: clamped_w,
                    height: line_height,
                    color: None,
                    font_scale: None,
                    segments: Vec::new(),
                    letter_gap: $letter_gap,
                    is_chapter_start: is_first_line,  // 标记章节第一行
                    is_comment: false,
                    // A31: 行级字符区间（推进前打戳，与页级同计数器）
                    start_char_index: char_index,
                    end_char_index: char_index + $line_char_count,
                });
                is_first_line = false;
                current_y += line_height;
                char_index += $line_char_count;
            }};
        }

        // Get font for measuring（layout_paragraph 仍消费 FontRef；
        // measure_char 已切到按字体名直读 ttf-parser，font 句柄仅
        // 满足旧签名，删除 font 后所有调用点会编译失败）
        let _font = self.font_manager.get_font(&self.config.font_name)?;

        // Split into paragraphs
        for paragraph in text.split('\n') {
            if paragraph.trim().is_empty() {
                char_index += 1;
                continue;
            }

            // M10-B：layout_paragraph_with_oracle 走 MeasureCache + 二分搜索，
            // 优先用 Dart TextPainter 测的真实 Skia 宽度；
            // cache miss 时仍用 ttf-parser 估算（与原版等价）。
            let para_lines = self.layout_paragraph_with_oracle(paragraph, content_width)?;

            // 收集当前段落的所有行
            pending_paragraph_lines.clear();
            let para_line_count = para_lines.len();
            for (li, line_text) in para_lines.iter().enumerate() {
                let line_char_count = line_text.chars().count();
                // P2 两端对齐：段末行豁免；其余行按 (content_width − 自然宽) / 字符数 分配
                let letter_gap = if self.config.justify && li + 1 < para_line_count {
                    kinsoku::justify_gap(
                        self.measure_text_width(line_text, self.config.font_size),
                        content_width,
                        line_char_count,
                        self.config.font_size,
                    )
                } else {
                    0.0
                };
                pending_paragraph_lines.push((line_text.clone(), line_char_count, letter_gap));
            }

            // ── M9.2 行级分页决策（取代旧"整段推页"分支）──
            //
            // 用户钦定策略：段落容纳不下时，计算剩余空间可容纳的整行数，
            // 放得下的行留在本页、剩余推下一页。仅保留轻量孤行/寡行保护
            // （最多浪费 ~2 行空间）。
            // A25：page_fill_threshold 恢复消费——语义重定义为内容区利用率
            // （对齐 EPUB layout_items），底界按比例收紧，行级断行自然留白
            let bottom_limit = self.config.padding.top
                + (self.config.height - self.config.padding.top - self.config.padding.bottom)
                    * self.config.page_fill_threshold;
            let paragraph_height =
                pending_paragraph_lines.len() as f32 * line_height + self.config.paragraph_spacing;
            let would_overflow = current_y + paragraph_height > bottom_limit;

            let mut pre_place = 0usize;   // 预置到本页的行数
            let mut manual_break = false; // 预置后手动翻页
            // A25b：填充率 100% = 纯行级填满，孤寡行保护自动挂起——
            // 保护的牺牲/推页会让"填满"出现 1~2 行槽缺口（对话密集段
            // 高频触发，用户实测"有的填满有的留白"）；<100% 时保护生效
            let protect_enabled = self.config.page_fill_threshold < 1.0;
            if would_overflow
                && !pending_paragraph_lines.is_empty()
                && protect_enabled
            {
                // 本页剩余空间可容纳的整行数（+0.01 浮点容差防舍入抖动）
                let mut lines_fit =
                    (((bottom_limit - current_y).max(0.0) + 0.01) / line_height) as usize;
                // 寡行保护：拆分将给下页留单行 → 本页少放一行（下页收两行）
                if lines_fit > 0 && pending_paragraph_lines.len() - lines_fit == 1 {
                    lines_fit -= 1;
                }
                // 孤行保护：本页放不下 ≥2 行且已有足够行 → 整段推下页
                if lines_fit < 2 && current_lines.len() >= MIN_LINES_PER_PAGE {
                    lines_fit = 0;
                }
                if lines_fit == 0 {
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
                    // 页行数不足 MIN_LINES：交给下方行循环的强制添加分支
                } else {
                    pre_place = lines_fit.min(pending_paragraph_lines.len());
                    // 行恰好全部放下（仅段距溢出）时不产生假翻页
                    manual_break = pre_place < pending_paragraph_lines.len();
                }
            }

            // 长段预置：前 pre_place 行留在本页
            for (line_text, line_char_count, letter_gap) in pending_paragraph_lines.iter().take(pre_place) {
                emit_line!(line_text, line_char_count, *letter_gap);
            }
            if manual_break {
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

            // 逐行添加段落剩余内容（跨多页的超长段由循环内断页自然处理）
            for (line_text, line_char_count, letter_gap) in pending_paragraph_lines.iter().skip(pre_place) {
                // 检查是否需要分页（强制分页，空间不足；A25 用收紧后的底界）
                if current_y + line_height > bottom_limit {
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

                emit_line!(line_text, line_char_count, *letter_gap);
            }
            
            // 段落间距（A25：页底折叠——底界处虚增 current_y 会侵蚀下段
            // 可用空间，行级精度下表现为提前断页；下段起点越过底界则不计入）
            if current_y + self.config.paragraph_spacing <= bottom_limit {
                current_y += self.config.paragraph_spacing;
            }
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
        // A25：page_fill_threshold 语义重定义——内容区利用率（对齐 TXT layout_text），
        // 底界按比例收紧，行级断行自然实现统一可预期的页底留白
        let bottom_limit = self.config.padding.top + content_height * self.config.page_fill_threshold;
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

        for (item_idx, item) in items.iter().enumerate() {
            match item {
                LayoutItem::Text(item) => {
                    let laid = self.layout_styled_paragraph(item, content_width, font)?;
                    if laid.is_empty() {
                        continue;
                    }
                    // A33：行高基准 = font_size × 书内/全局行高倍率；
                    // 每行再乘自身 scale。注释行强制 comment_scale **覆盖**
                    // （不得再乘 CSS scale——否则与 Dart 绘制双缩）。
                    let comment_scale = self.config.comment_scale.clamp(0.5, 1.2);
                    let line_h_base = self.config.font_size
                        * item.line_height.unwrap_or(self.config.line_height_multiplier);
                    let line_h_of = |scale: f32| {
                        if item.is_comment {
                            line_h_base * comment_scale
                        } else {
                            line_h_base * scale.max(1e-6)
                        }
                    };
                    // 段首 fit 估计用行 scale 最大值（偏保守，避免少放行）
                    let para_max_scale = laid
                        .iter()
                        .map(|l| l.scale)
                        .fold(0.0f32, f32::max)
                        .max(1.0);
                    let line_h = line_h_of(para_max_scale);

                    // M9 P5：首行缩进 px（em × 基准字号）
                    let indent_px = item.indent_first_line_em.unwrap_or(0.0) * self.config.font_size;

                    // 段前间距（em → px）：页首折叠
                    // A33 页尾折叠：预加后若首行放不下，不计入段前距（避免虚增 current_y）
                    let space_before = if entries.is_empty() && text_lines_on_page == 0 {
                        0.0
                    } else {
                        item.spacing_before_em * self.config.font_size
                    };
                    if space_before > 0.0 {
                        let first_h = laid.first().map(|l| line_h_of(l.scale)).unwrap_or(line_h);
                        if current_y + space_before + first_h <= bottom_limit + 0.5 {
                            current_y += space_before;
                        }
                    }

                    // M9 P2 场景 C：标题孤立避免
                    // 标题特征：font_scale > 1.0 或有段前间距（M8 标题分级设置）
                    // 当前页已有内容且剩余空间不足以容纳标题 1 行 + 正文 2 行时，
                    // 标题推到下一页，避免标题孤立在页底
                    let is_heading =
                        item.font_scale.unwrap_or(1.0) > 1.0 || item.spacing_before_em > 0.0;
                    if is_heading && !entries.is_empty() {
                        let remaining = bottom_limit - current_y;
                        if remaining < line_h + 2.0 * line_height {
                            break_page!();
                        }
                    }

                    // P2 两端对齐：Justify 直接启用；Left/未指定跟随全局 justify 开关
                    let justify_on = match item.align {
                        Some(LayoutAlign::Justify) => true,
                        Some(LayoutAlign::Left) | None => self.config.justify,
                        _ => false,
                    };

                    // A25 统一行级分页：场景 A（整段推页）与场景 B（低填充
                    // 强制首行）退役——行级拆分由下方 P4 孤寡行 cap 流式路径
                    // 承担（TXT M9.2 同构），页底留白由 bottom_limit（填充率）
                    // 统一控制，消除策略两档导致的留白不统一
                    
                    let para_line_count = laid.len(); // P2 justify：段末行判定
                    // P4 孤行/寡行保护（对齐 TXT M9.2 行级分页口径）：
                    // 段首一次性决策本页可容纳行数——拆分给下页残留单行 →
                    // 本页少放一行（寡行）；本页仅能容 <2 行且页已有足够行 →
                    // 整段推下页（孤行）。页行数不足 MIN_LINES 时交由既有
                    // 逐行强制放置分支（与 TXT 一致）。
                    let mut para_bottom_limit = bottom_limit;
                    // A26：图文混排分页统一——Text 段落为后续 Image/Table 预留空间
                    let next_item_height = self.peek_next_atomic_height(
                        items, item_idx + 1, content_width, content_height, font
                    );
                    // A25b：填充率 100% = 纯行级填满，孤寡行保护自动挂起
                    // （对齐 TXT 决策块门控；<100% 时保护生效）
                    let protect_enabled = self.config.page_fill_threshold < 1.0;
                    if para_line_count > 1 && protect_enabled {
                        let mut avail_height = (bottom_limit - current_y).max(0.0);
                        // A26：如果下一个是图表，预留其高度
                        if let Some(next_h) = next_item_height {
                            let para_h_estimate = para_line_count as f32 * line_h;
                            if current_y + para_h_estimate + next_h <= bottom_limit {
                                // 段落+图表能同页放下 → 降低段落 cap，为图表预留空间
                                avail_height = avail_height - next_h;
                            }
                        }
                        let fit_avail = ((avail_height + 0.01) / line_h) as usize;
                        let mut fit = fit_avail.min(para_line_count);
                        if para_line_count - fit == 1 {
                            fit -= 1; // 寡行：下页收两行
                        }
                        if fit < 2 && text_lines_on_page >= MIN_LINES_PER_PAGE {
                            fit = 0; // 孤行：整段推下页
                        }
                        if fit == 0 {
                            if text_lines_on_page >= MIN_LINES_PER_PAGE {
                                break_page!();
                            }
                        } else {
                            para_bottom_limit = current_y + fit as f32 * line_h;
                        }
                    }
                    for (line_idx, line) in laid.into_iter().enumerate() {
                        // A33：逐行真实行高（scale / comment）
                        let line_h_i = line_h_of(line.scale);
                        // A33.1：能放下一行就放下——容差 1px + 3% 行高，
                        // 消除「肉眼还有一行空间却提前换页」的观感
                        //（浮点 ULP + 行高微差导致 0.5px 容差不够）
                        let fit_eps = 1.0 + line_h_i * 0.03;
                        if current_y + line_h_i > para_bottom_limit + fit_eps
                            && text_lines_on_page >= MIN_LINES_PER_PAGE
                        {
                            break_page!();
                            // P4 修复（分页精度回归）：cap 是按段落起点页的
                            // 剩余空间算的——断页后 current_y 已到新页顶部，
                            // 旧 cap 会让余行每 3~4 行被再次断页（页碎片化）。
                            // 对齐 TXT 语义：保护只作用于段落首个页面，
                            // 断页后余行按新页普通流式排布。
                            para_bottom_limit = bottom_limit;
                        }
                        // 本章说 + 隐藏模式：跳过绘制但照常累计锚点
                        if item.is_comment && !self.config.show_comments {
                            char_index += line.char_end - line.char_start + line.newlines_before;
                            continue;
                        }
                        // A34.1：对齐×缩进——首行可用宽先扣 indent，
                        // 再折算对齐原点并加回 indent（CSS：indent 只缩
                        // 首行可用宽，Right 短行仍贴右缘，不得溢出）。
                        let indent_here = if line_idx == 0 { indent_px } else { 0.0 };
                        let align_w = (content_width - indent_here).max(0.0);
                        let x = self.align_line_x(line.width, align_w, item.align) + indent_here;
                        let segments = Self::segments_for_line(&line, item);
                        // P2 justify：末行豁免；首行可用宽扣除缩进
                        let gap = if justify_on && line_idx + 1 < para_line_count {
                            let avail =
                                if line_idx == 0 && indent_px > 0.01 { content_width - indent_px } else { content_width };
                            kinsoku::justify_gap(
                                line.width,
                                avail,
                                line.text.chars().count(),
                                self.config.font_size,
                            )
                        } else {
                            0.0
                        };
                        // A31: 行级字符区间（增量前捕获；锚点口径与页级同计数器）
                        let line_cs = char_index + line.newlines_before;
                        let line_ce = line_cs + (line.char_end - line.char_start);
                        char_index += line.char_end - line.char_start + line.newlines_before;
                        // P3：悬挂行上报 raw 宽（先取再 move text）
                        let w_report =
                            self.report_line_width(line.width, &line.text, content_width);
                        entries.push(PageEntry::Text(TextLine {
                            text: line.text,
                            x,
                            y: current_y,
                            width: w_report, // M11+12 实测宽；P3 悬挂行跳过钳制
                            height: line_h_i,
                            // 注释：颜色由 Dart 设置覆盖；此处仅占位灰
                            color: if item.is_comment {
                                Some("#888888".to_string())
                            } else {
                                item.color.clone()
                            },
                            // 注释：强制 comment_scale 覆盖；否则上报本行真实 scale
                            font_scale: if item.is_comment {
                                Some(comment_scale)
                            } else {
                                (line.scale != 1.0).then_some(line.scale)
                            },
                            segments,
                            letter_gap: gap,
                            is_chapter_start: char_index == 0 && page_start_char == 0,
                            is_comment: item.is_comment,
                            start_char_index: line_cs,
                            end_char_index: line_ce,
                        }));
                        text_lines_on_page += 1;
                        current_y += line_h_i;
                    }
                    // 段后间距（em → px）：页首自动折叠已由段前处理。
                    // A25：页底折叠——底界处虚增 current_y 会侵蚀下段可用
                    // 空间（提前断页偏差），下段起点越过底界则不计入
                    let space_after = item.spacing_after_em * self.config.font_size;
                    let advance = space_after.max(self.config.paragraph_spacing);
                    if current_y + advance <= bottom_limit {
                        current_y += advance;
                    }
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
                        let original_height = img_height;
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
                        // A26：极端缩放警告（缩放比 <0.5）
                        let scale = img_height / original_height;
                        if scale < 0.5 {
                            eprintln!(
                                "[WARN] Image '{}' scaled down to {:.1}% (aspect ratio {:.2}), consider reducing image height in source",
                                resource_href, scale * 100.0, ratio
                            );
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

                    // A26：极端高度警告（表格 >0.85×content_height）
                    if total_h > content_height * 0.85 {
                        eprintln!(
                            "[WARN] Table spans {:.1}% of page height, may cause pagination gaps",
                            total_h / content_height * 100.0
                        );
                    }

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

    /// A26：前瞻下一个原子块（Image/Table）的高度，用于 Text 段落 fit_avail 计算
    ///
    /// 返回 Some(h) 如果下一个是 Image/Table 且高度可预测；None 如果是 Text 或无后续。
    /// 仅前瞻直接后继（items[idx+1]），不递归扫描。
    fn peek_next_atomic_height(
        &self,
        items: &[LayoutItem],
        start_idx: usize,
        content_width: f32,
        content_height: f32,
        font: &ab_glyph::FontRef<'static>,
    ) -> Option<f32> {
        for item in items.iter().skip(start_idx) {
            match item {
                LayoutItem::Image { aspect, bleed, .. } => {
                    let ratio = if *aspect > 0.01 { *aspect } else { 0.75 };
                    let img_width = if *bleed { self.config.width } else { content_width };
                    let mut h = img_width / ratio;
                    let max_h = if *bleed { content_height } else { content_height };
                    if h > max_h { 
                        h = max_h; 
                    }
                    return Some(h + self.config.paragraph_spacing);
                }
                LayoutItem::Table(table) => {
                    if let Ok(Some((_, _, total_h, _))) = self.layout_table(table, content_width, font) {
                        return Some(total_h + self.config.paragraph_spacing);
                    }
                    return None; // 表格布局失败，保守不预留
                }
                LayoutItem::Text { .. } => return None, // 下一个是文本，不预留
            }
        }
        None // 无后续元素
    }

    /// Layout a single paragraph into lines with real glyph measurement
    ///
    /// M7-P4 断行精修（保留为参考实现，M10-B 后由 `layout_paragraph_with_oracle` 取代）：
    /// - 行首禁则（。，」等不得居行首）：断行点命中禁则时回退上一行末片段；
    /// - 英文整词移行：断点落在词字符内时，把上一行尾部连续词字符整体带下。
    /// 两种回退只在相邻行间搬移已计宽片段，Σ字符数不变 ⇒ 锚点口径不变。
    ///
    /// 缺点：逐字累加 width，无法捕捉 HarfBuzz 整形（连字/kerning/标点宽度类），
    /// 与 Skia 渲染宽度有系统性偏差 → 断行位置与 Skia 实绘不一致 →
    /// 左右边距视觉不对称（content偏右/偏左）。已被 `layout_paragraph_with_oracle` 替代。
    #[allow(dead_code)]
    fn layout_paragraph(
        &self,
        paragraph: &str,
        max_width: f32,
        font: &ab_glyph::FontRef<'static>,
    ) -> Result<Vec<String>> {
        // 2026-09-04 P2: 禁则表/词判定收口到 kinsoku 模块（原三处复制）
        use kinsoku::{LINE_START_FORBIDDEN, LINE_END_FORBIDDEN, is_word_char};

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
                    let mut pulled_ew: Vec<f32> = Vec::new();
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
                            let ew = eff_widths.pop().unwrap_or(0.0);
                            pulled.insert(0, p);
                            pulled_ew.insert(0, ew);
                            pulled_w += ew;
                            continue;
                        }
                        if pulled.is_empty() && head_forbidden {
                            let p = pieces.pop().unwrap();
                            let ew = eff_widths.pop().unwrap_or(0.0);
                            pulled.insert(0, p);
                            pulled_ew.insert(0, ew);
                            pulled_w += ew;
                            continue;
                        }
                        if pulled.is_empty()
                            && tail_c.map_or(false, |c| LINE_END_FORBIDDEN.contains(&c))
                        {
                            let p = pieces.pop().unwrap();
                            let ew = eff_widths.pop().unwrap_or(0.0);
                            pulled.insert(0, p);
                            pulled_ew.insert(0, ew);
                            pulled_w += ew;
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
                        // M9.1 修复：清空已发射前缀后仅保留拉回片段——
                        // 原实现把 pulled 压在未清空的前缀之上，导致下一行
                        // 重复发射整个前缀（EPUB/TXT 双路径同源 bug）
                        pieces.clear();
                        pieces.extend(pulled.drain(..));
                        eff_widths.clear();
                        eff_widths.extend(pulled_ew);
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

    /// M10-B：用 MeasureCache + 二分搜索重写 layout_paragraph
    ///
    /// 关键变化：
    /// - **不再逐 grapheme 累加 width**（逐字累加无法捕捉 HarfBuzz 整形）
    /// - **二分搜索**：对每行候选 mid 子串整串调 `measure_text_width` 拿 Skia 真实宽度
    /// - **保留禁则逻辑**：与原版一致的行首/行尾禁则字符处理
    /// - **缓存 miss 回退 ttf-parser**：保证 layout 永不阻塞
    ///
    /// 返回的 lines 与原 `layout_paragraph` 一一对应，调用方可直接替换
    fn layout_paragraph_with_oracle(
        &self,
        paragraph: &str,
        max_width: f32,
    ) -> Result<Vec<String>> {
        // 2026-09-04 P2: 禁则表/词判定收口到 kinsoku 模块
        use kinsoku::{LINE_START_FORBIDDEN, LINE_END_FORBIDDEN, is_word_char};

        if paragraph.is_empty() {
            return Ok(Vec::new());
        }

        let mut finished: Vec<String> = Vec::new();
        let mut remaining = paragraph.to_string();

        while !remaining.is_empty() {
            // 二分搜索：在 remaining 中找最长前缀 prefix，使得
            // measure_text_width(prefix) ≤ max_width
            let (line_text, after) = self.find_longest_fit(&remaining, max_width);

            // 处理禁则/词边界回退（返回 owned String 以便循环使用）
            let (committed_line, leftover) =
                self.apply_linebreak_rules(&line_text, &after, is_word_char, LINE_START_FORBIDDEN, LINE_END_FORBIDDEN);

            finished.push(committed_line);

            // 推进 remaining：若 leftover 非空，则用 leftover 作为下一轮起点
            // （pulled_back 字符 + after 剩余）；否则用 after
            if !leftover.is_empty() {
                remaining = leftover;
            } else if !after.is_empty() {
                remaining = after.to_string();
            } else {
                break;
            }

            // 安全防卡死：若 remaining 完全没变化，break
            if remaining == line_text {
                break;
            }
        }

        Ok(finished)
    }

    /// 二分搜索 text 中最长的前缀 prefix，使得 measure_text_width(prefix) ≤ max_width
    /// 返回 (prefix, remaining_after_prefix)
    fn find_longest_fit(&self, text: &str, max_width: f32) -> (String, String) {
        // 先做 UTF-8 安全二分：在 char boundary 上做索引
        let char_indices: Vec<usize> = text.char_indices().map(|(i, _)| i).collect();
        let total_chars = char_indices.len();
        if total_chars == 0 {
            return (String::new(), text.to_string());
        }

        // M12 修复：允许略微超出 max_width（在 epsilon 范围内），
        // 让文字排得更满，减少右侧留白
        let eps = Self::line_fill_epsilon(max_width);

        let mut low = 1usize; // 至少 1 个字符
        let mut high = total_chars;
        let mut best_end_char = 1usize;

        while low <= high {
            let mid = (low + high) / 2;
            let end_byte = if mid >= total_chars {
                text.len()
            } else {
                char_indices[mid]
            };
            let candidate = &text[..end_byte];
            // M12：find_longest_fit 在 TXT 路径，effective_font_size = config.font_size
            let w = self.measure_text_width(candidate, self.config.font_size);

            // M12 修复：允许在 epsilon 范围内超出，让行更满
            if w <= max_width + eps {
                best_end_char = mid;
                low = mid + 1;
            } else {
                if mid == 0 {
                    break;
                }
                high = mid - 1;
            }
        }

        // P3 行尾标点压缩悬挂：二分已把预算排满，若下一字符是行尾可压缩
        // 标点、且其折半宽能放进剩余空间 → 多吃一个字符。渲染端全宽绘制
        // 自然悬挂出右缘（该字符恒为行尾字符）。
        // 折扣按 Skia 单字符自然宽 × (1−率) 计——MeasureCache 缓存的仍是
        // raw 整串宽，压缩只作用于本判定，不污染缓存（M12 红线）。
        if self.config.punctuation_compress && best_end_char < total_chars {
            let next_ch = text[char_indices[best_end_char]..]
                .chars()
                .next()
                .unwrap_or('\0');
            if kinsoku::is_line_end_compressible(next_ch) {
                let ext_end_char = best_end_char + 1;
                let ext_byte = if ext_end_char >= total_chars {
                    text.len()
                } else {
                    char_indices[ext_end_char]
                };
                let candidate = &text[..ext_byte];
                let w_full = self.measure_text_width(candidate, self.config.font_size);
                let natural = self.measure_text_width(&next_ch.to_string(), self.config.font_size);
                let discount = kinsoku::compression_discount(natural);
                if w_full - discount <= max_width + eps {
                    best_end_char = ext_end_char;
                }
            }
        }

        let end_byte = if best_end_char >= total_chars {
            text.len()
        } else {
            char_indices[best_end_char]
        };
        let prefix = text[..end_byte].to_string();
        let rest = text[end_byte..].to_string();
        (prefix, rest)
    }

    /// 禁则/词边界回退处理
    /// 输入：line_text（本行已确定前缀）、after（前缀之后的剩余）、is_word_char、禁则列表
    /// 返回：(最终本行文本, 拖回待续行首的片段 + after；可能为空)
    fn apply_linebreak_rules(
        &self,
        line_text: &str,
        after: &str,
        is_word_char: fn(char) -> bool,
        line_start_forbidden: &[char],
        line_end_forbidden: &[char],
    ) -> (String, String) {
        // 如果本行已经是整个文本，直接返回
        if after.is_empty() {
            return (line_text.to_string(), String::new());
        }

        // 检视 after 第一个字符
        let next_ch = after.chars().next().unwrap_or(' ');
        let last_ch = line_text.chars().last().unwrap_or(' ');

        let mut pulled_back = String::new();

        // 行尾禁则：上一行末字符是开括号类，把这个字符拖到下行首
        if line_end_forbidden.contains(&last_ch) {
            pulled_back.push(last_ch);
        }

        // 行首禁则：after 第一个字符是禁则标点 → 把上一行末字符拖到下行首
        if pulled_back.is_empty() && line_start_forbidden.contains(&next_ch) {
            pulled_back.push(last_ch);
        }

        // 整词回退：after 首字符是词字符 + line_text 末字符也是词字符 → 拖回整词
        if pulled_back.is_empty() && is_word_char(next_ch) && is_word_char(last_ch) {
            // 把 line_text 末尾连续词字符拖回
            let trailing_word: String = line_text
                .chars()
                .rev()
                .take_while(|c| is_word_char(*c))
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            if !trailing_word.is_empty() {
                pulled_back = trailing_word;
            }
        }

        if pulled_back.is_empty() {
            return (line_text.to_string(), String::new());
        }

        // 实际回退：去掉 line_text 末尾与 pulled_back 字符数相同的字符
        let pulled_char_count = pulled_back.chars().count();
        let committed: String = if pulled_back.is_ascii() {
            // ASCII 子串：字节数 = char 数
            let new_len = line_text.len() - pulled_char_count;
            line_text[..new_len].to_string()
        } else {
            // 多字节字符：按 char 边界从末尾切
            line_text
                .chars()
                .take(line_text.chars().count() - pulled_char_count)
                .collect()
        };
        let mut new_after = String::with_capacity(pulled_back.len() + after.len());
        new_after.push_str(&pulled_back);
        new_after.push_str(after);
        (committed, new_after)
    }

    /// 测量一个 UTF-8 字符串的渲染宽度（优先查 MeasureCache，miss 回退 ttf-parser）
    ///
    /// **关键**：必须传入**完整 UTF-8 子串**——逐字累加无法捕捉 HarfBuzz 整形
    /// （连字 `fi`/`fl`、kerning、标点宽度类差异等）
    ///
    /// M12：接收 effective_font_size 参数，cache key 用此值。
    /// 调用方传入 `config.font_size * scale`，让 Rust 端 cache key 与 Dart 端
    /// `MeasureTextService.configure(fontSize: ...)` 对齐。
    /// font_scale!=1.0 的章节标题/评论行也能命中。
    pub fn measure_text_width(&self, text: &str, font_size: f32) -> f32 {
        if text.is_empty() {
            return 0.0;
        }
        // 优先查 MeasureCache（命中 = Skia 真实宽度）
        if let Some(w) = self
            .measure_cache
            .get(&self.config.font_name, font_size, text)
        {
            return w;
        }
        // miss → 用 ttf-parser 累加（带 letter_spacing 同步逻辑）
        let letter_spacing = self.config.letter_spacing;
        let mut total = 0.0f32;
        let mut count = 0usize;
        for ch in text.chars() {
            let w = self.get_char_width_inner(ch, font_size);
            // 与原版一致：letter_spacing 加到每个字符（含最后一个，潜在 bug 但保留以不破坏锚点）
            total += w + letter_spacing;
            count += 1;
        }
        // 与原 layout_paragraph 一致：最后字符不加 letter_spacing，避免多算一次
        if count > 0 {
            total -= letter_spacing;
        }
        // M12 必修3：兜底放在 emit_line! 内，不在这里。理由：
        // 二分搜索路径需 raw 宽度做 `w <= max_width - eps` 判定，
        // 在这里截断会破坏二分收敛（test_multi_page_layout 在 fallback 字体下失败）。
        // emit_line! 处仅对 TextLine.width 报告值做 min 截断，让 line.width <= content_width。
        total
    }

    /// content_width 内部辅助（M12 必修3 用）
    fn content_width(&self) -> f32 {
        self.config.width - self.config.padding.left - self.config.padding.right
    }

    /// 内部单字符宽度查询（与 get_char_width 一样走 LRU + ttf-parser，但不写入 font 句柄）
    ///
    /// M12：font_size 由调用方传入，使 cache key 与 measure_text_width 的 font_size 对齐
    fn get_char_width_inner(&self, ch: char, font_size: f32) -> f32 {
        let key = GlyphKey::new(ch, font_size, &self.config.font_name);
        if let Some(metrics) = self.glyph_cache.get(&key) {
            return metrics.width;
        }
        let metrics = self.font_manager.measure_char(&self.config.font_name, ch, font_size);
        self.glyph_cache.put(key, metrics);
        metrics.width
    }

    /// 判满安全余量（M12-v4 修正）：增大 epsilon 以减少右侧留白
    /// 改为 1% 最小 5px，允许行排得更满
    fn line_fill_epsilon(max_width: f32) -> f32 {
        (max_width * 0.01).max(5.0)
    }

    /// Get character width with caching
    fn get_char_width(&self, ch: char, font: &ab_glyph::FontRef<'static>) -> f32 {
        let key = GlyphKey::new(ch, self.config.font_size, &self.config.font_name);
        
        // Try cache first
        if let Some(metrics) = self.glyph_cache.get(&key) {
            return metrics.width;
        }
        
        // Measure and cache（font 句柄弃用，measure_char 走 ttf-parser 按名寻址）
        let metrics = self.font_manager.measure_char(&self.config.font_name, ch, self.config.font_size);
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
        let metrics = self.font_manager.measure_char(&self.config.font_name, ch, fs);
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

    /// A33：行内字符区间上的最大字号倍率（行高按此行真实 scale 计）
    fn line_scale_at(item: &TextItem, start: usize, end: usize) -> f32 {
        if end <= start {
            return item.font_scale.unwrap_or(1.0);
        }
        let mut m = item.font_scale.unwrap_or(1.0);
        for i in start..end {
            let s = Self::scale_at(&item.runs, item.font_scale, i);
            if s > m {
                m = s;
            }
        }
        m
    }

    /// P3：行宽上报——悬挂行（压缩开关开 + 行尾可压缩标点）跳过
    /// content_width 钳制，上报 raw 宽。若仍钳制，Dart 端 2% 超宽检查
    /// （naturalWidth > width×1.02）会触发整行 canvas.scale 缩小而非悬挂。
    /// 上报 raw 后 skiaW==rustW，检查天然通过，标点自然悬挂出右缘。
    fn report_line_width(&self, line_width: f32, line_text: &str, content_width: f32) -> f32 {
        if self.config.punctuation_compress
            && line_text.chars().last().map_or(false, kinsoku::is_line_end_compressible)
        {
            line_width
        } else {
            line_width.min(content_width)
        }
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
                    background_color: None,
                    font_scale: r.font_scale,
                    bold: r.bold,
                    italic: r.italic,
                    underline: r.underline,
                    footnote_ref: r.footnote_ref.clone(),
                    // P2 justify 拉丁词保护：段内以 ASCII 字母/数字为主 → 不参与空隙拉伸
                    letter_spacing: if line.letter_gap > 0.0 {
                        let seg: String = item.text.chars().skip(s).take(e - s).collect();
                        let (latin, total) = seg
                            .chars()
                            .fold((0usize, 0usize), |(l, t), c| {
                                (l + usize::from(c.is_ascii_alphanumeric()), t + 1)
                            });
                        (total > 0 && latin * 2 > total).then_some(0.0)
                    } else {
                        None
                    },
                })
            })
            .collect()
    }

    /// EPUB styled 段落：MeasureCache 优先二分断行（与 TXT find_longest_fit 同精度模型）
    ///
    /// - 判宽走 `measure_styled_prefix_width`（按 run scale 分段查 MeasureCache，
    ///   命中 = Skia 实测；miss 回退 ttf，永不阻塞 UI）
    /// - 硬换行 `\n` 仍为段内硬边界
    /// - 禁则/断词回退与 TXT `apply_linebreak_rules` 同规则
    /// - 锚点：char_start/char_end/newlines_before 口径与旧实现一致
    fn layout_styled_paragraph(
        &self,
        item: &TextItem,
        max_width: f32,
        _font: &ab_glyph::FontRef<'static>,
    ) -> Result<Vec<LaidLine>> {
        use kinsoku::{LINE_START_FORBIDDEN, LINE_END_FORBIDDEN, is_word_char};

        if item.text.is_empty() {
            return Ok(Vec::new());
        }
        let chars: Vec<char> = item.text.chars().collect();
        let total = chars.len();
        let indent_px = item.indent_first_line_em.unwrap_or(0.0) * self.config.font_size;
        let mut first_line = indent_px > 0.01;
        let mut lines: Vec<LaidLine> = Vec::new();
        let mut pos = 0usize;
        let mut pending_newlines = 0usize;

        while pos < total {
            if chars[pos] == '\n' {
                pending_newlines += 1;
                pos += 1;
                continue;
            }
            // 本行硬边界（段内 \n）
            let seg_end = chars[pos..]
                .iter()
                .position(|&c| c == '\n')
                .map(|i| pos + i)
                .unwrap_or(total);

            let max_w = if first_line {
                (max_width - indent_px).max(1.0)
            } else {
                max_width
            };
            let (mut end, mut width) = self.find_longest_fit_styled(item, pos, seg_end, max_w);

            // 禁则/断词连续回退（与旧 per-char 实现同构）：
            // ① 词连续（含已拉回片段作 next）② 行首禁则 ③ 行尾禁则——循环直至稳定
            if end < seg_end && end > pos + 1 {
                let mut pulled = 0usize;
                loop {
                    if end <= pos + 1 || pulled >= 16 {
                        break;
                    }
                    let last = chars[end - 1];
                    let next = chars[end]; // end < seg_end 保证存在
                    // 词连续：当前行尾与「行首（含已拉回）」都是词字符 → 继续拖
                    if is_word_char(last) && is_word_char(next) {
                        end -= 1;
                        pulled += 1;
                        continue;
                    }
                    if pulled == 0 && LINE_START_FORBIDDEN.contains(&next) {
                        end -= 1;
                        pulled += 1;
                        continue;
                    }
                    if pulled == 0 && LINE_END_FORBIDDEN.contains(&last) {
                        end -= 1;
                        pulled += 1;
                        continue;
                    }
                    break;
                }
                if pulled > 0 {
                    width = self.measure_styled_prefix_width(item, pos, end);
                }
            }

            lines.push(LaidLine {
                text: chars[pos..end].iter().collect(),
                width,
                char_start: pos,
                char_end: end,
                newlines_before: pending_newlines,
                letter_gap: 0.0,
                scale: Self::line_scale_at(item, pos, end),
            });
            pending_newlines = 0;
            first_line = false;
            pos = end;
            // 消费本行末的 \n（若有）
            if pos < total && chars[pos] == '\n' {
                pos += 1;
                // 下一行的 newlines_before 从下一循环的 \n 累计或 0；
                // 与旧实现一致：行后单个 \n 不额外计入下一行（由 line_start+line+1 消费）
            }
            if lines.len() > 10_000 {
                break; // 安全阀
            }
        }

        // P2 两端对齐：与旧实现同逻辑
        if lines.len() > 1 {
            let justify_on = match item.align {
                Some(LayoutAlign::Justify) => true,
                Some(LayoutAlign::Left) | None => self.config.justify,
                _ => false,
            };
            if justify_on {
                let n = lines.len();
                for (i, line) in lines.iter_mut().enumerate() {
                    if i + 1 >= n {
                        break;
                    }
                    let avail = if i == 0 && indent_px > 0.01 {
                        max_width - indent_px
                    } else {
                        max_width
                    };
                    line.letter_gap = kinsoku::justify_gap(
                        line.width,
                        avail,
                        line.text.chars().count(),
                        self.config.font_size,
                    );
                }
            }
        }
        Ok(lines)
    }

    /// styled 前缀宽：按 run/scale 分段调用 measure_text_width（MeasureCache 优先）
    ///
    /// 全段同 scale 时退化为一次整串测量（与 TXT 同路径，命中率最高）。
    fn measure_styled_prefix_width(
        &self,
        item: &TextItem,
        start_chars: usize,
        end_chars: usize,
    ) -> f32 {
        if end_chars <= start_chars {
            return 0.0;
        }
        let chars: Vec<char> = item.text.chars().collect();
        let end_chars = end_chars.min(chars.len());
        if start_chars >= end_chars {
            return 0.0;
        }
        // 快路径：无 runs 或整段同一 scale → 一次测量
        let base = item.font_scale.unwrap_or(1.0);
        let uniform = item.runs.is_empty()
            || item.runs.iter().all(|r| {
                r.font_scale.map(|s| (s - base).abs() < 1e-6).unwrap_or(true)
            });
        let slice: String = chars[start_chars..end_chars].iter().collect();
        if uniform {
            return self.measure_text_width(&slice, self.config.font_size * base);
        }
        // 混 scale：按连续同 scale 切段求和
        let mut total = 0.0f32;
        let mut i = start_chars;
        while i < end_chars {
            let scale = Self::scale_at(&item.runs, item.font_scale, i);
            let mut j = i + 1;
            while j < end_chars {
                let s2 = Self::scale_at(&item.runs, item.font_scale, j);
                if (s2 - scale).abs() > 1e-6 {
                    break;
                }
                j += 1;
            }
            let seg: String = chars[i..j].iter().collect();
            total += self.measure_text_width(&seg, self.config.font_size * scale);
            i = j;
        }
        total
    }

    /// styled 最长可容前缀：贪心自左向右测宽（仅查询「最终行前缀」，
    /// 与 Dart feedPageTextsWithPrefixes 的 key 集合对齐，二次布局命中率最高）
    /// 返回 (end_char, width)
    fn find_longest_fit_styled(
        &self,
        item: &TextItem,
        start_chars: usize,
        seg_end: usize,
        max_width: f32,
    ) -> (usize, f32) {
        if start_chars >= seg_end {
            return (start_chars, 0.0);
        }
        let eps = Self::line_fill_epsilon(max_width);
        let mut best = start_chars;
        let mut best_w = 0.0f32;

        for end in (start_chars + 1)..=seg_end {
            let w = self.measure_styled_prefix_width(item, start_chars, end);
            if w <= max_width + eps {
                best = end;
                best_w = w;
            } else {
                if best == start_chars {
                    // 单字已超宽：强制 1 字防死循环
                    return (start_chars + 1, w);
                }
                break;
            }
        }

        // P3 标点压缩：下一字可压缩且折半宽能进 → 多吃一字
        if self.config.punctuation_compress && best < seg_end {
            let chars: Vec<char> = item.text.chars().collect();
            let next_ch = chars[best];
            if kinsoku::is_line_end_compressible(next_ch) {
                let ext_end = best + 1;
                let w_full = self.measure_styled_prefix_width(item, start_chars, ext_end);
                let natural = self.measure_text_width(
                    &next_ch.to_string(),
                    self.config.font_size
                        * Self::scale_at(&item.runs, item.font_scale, best),
                );
                let discount = kinsoku::compression_discount(natural);
                if w_full - discount <= max_width + eps {
                    best = ext_end;
                    best_w = w_full;
                }
            }
        }

        (best, best_w)
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
                        * titem.line_height.unwrap_or(self.config.line_height_multiplier)
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
                            // P2 justify：表格单元格窄列拉伸效果差，整体豁免
                            letter_gap: 0.0,
                            is_chapter_start: false,
                            is_comment: false,
                            // A31: 表格行区间未知（x/y 为单元格相对坐标），
                            // 0/0 = 不参与高亮/命中
                            start_char_index: 0,
                            end_char_index: 0,
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

    /// A31: TXT 路径行级字符区间一致性——区间单调、衔接、覆盖页级范围
    #[test]
    fn test_txt_entry_char_ranges_monotonic_and_covered() {
        let (engine, config) = create_test_engine();
        // 多段文本，触发分页与软换行
        let text = format!("{}\n{}\n{}", "甲".repeat(80), "乙".repeat(80), "丙".repeat(40));
        let pages = engine.layout_text(&text, 0).expect("布局失败");
        assert!(pages.len() >= 1);

        let mut prev_end: Option<usize> = None;
        for page in &pages {
            // 页级区间内的 Text entry 区间必须 ⊆ [page.start, page.end]
            for entry in &page.entries {
                if let PageEntry::Text(l) = entry {
                    assert!(
                        l.start_char_index < l.end_char_index,
                        "区间必须有效: [{}, {})",
                        l.start_char_index, l.end_char_index
                    );
                    assert!(
                        l.start_char_index >= page.start_char_index
                            && l.end_char_index <= page.end_char_index,
                        "行区间 [{}, {}) 必须落在页区间 [{}, {}) 内",
                        l.start_char_index, l.end_char_index,
                        page.start_char_index, page.end_char_index
                    );
                    // 单调衔接（允许页间锚点间隙：空行 +1 等）
                    if let Some(pe) = prev_end {
                        assert!(
                            l.start_char_index >= pe,
                            "区间必须单调: prev_end={} start={}",
                            pe, l.start_char_index
                        );
                    }
                    prev_end = Some(l.end_char_index);
                }
            }
        }
    }

    /// A31: styled（EPUB）路径行级字符区间一致性
    #[test]
    fn test_styled_entry_char_ranges_monotonic() {
        let (engine, _config) = create_test_engine();
        let items: Vec<LayoutItem> = vec![
            LayoutItem::text("第一段比较长的内容，用来触发软换行断行逻辑的执行与验证。"),
            LayoutItem::text("第二段同样足够长，跨越多行以验证行级区间的单调衔接性。"),
        ];
        let pages = engine.layout_items(&items, 0).expect("styled 布局失败");

        let mut prev_end: Option<usize> = None;
        for page in &pages {
            for entry in &page.entries {
                if let PageEntry::Text(l) = entry {
                    assert!(l.start_char_index < l.end_char_index);
                    assert!(l.end_char_index <= page.end_char_index);
                    if let Some(pe) = prev_end {
                        assert!(l.start_char_index >= pe, "区间必须单调");
                    }
                    prev_end = Some(l.end_char_index);
                }
            }
        }
    }

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
            page_fill_threshold: 1.0, // A25：1.0 = 行级填满（测试基线，阈值行为单测）
            show_comments: true,
            comment_scale: 0.82,
            justify: false,
            punctuation_compress: false,
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
            indent_first_line_em: None,
            is_comment: false,
            line_height: None,
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
                RunSpan { start: 0, end: 2, color: Some("#ff0000".into()), font_scale: None, bold: false, italic: false, underline: false, footnote_ref: None },
                RunSpan { start: 3, end: 5, color: Some("#00ff00".into()), font_scale: None, bold: false, italic: false, underline: false, footnote_ref: None },
            ],
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            indent_first_line_em: None,
            is_comment: false,
            line_height: None,
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
                footnote_ref: None,
            }],
            spacing_before_em: 0.0,
            spacing_after_em: 0.0,
            indent_first_line_em: None,
            is_comment: false,
            line_height: None,
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
            indent_first_line_em: None,
            is_comment: false,
            line_height: None,
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
                indent_first_line_em: None,
                is_comment: false,
                line_height: None,
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
                indent_first_line_em: None,
                is_comment: false,
                line_height: None,
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
                indent_first_line_em: None,
                is_comment: false,
                line_height: None,
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

    // ===== M9 P2：底部留白智能优化 =====

    /// 辅助：创建标题项（带字号倍率 + 段前间距）
    fn heading_item(text: &str, scale: f32) -> TextItem {
        TextItem {
            text: text.to_string(),
            font_scale: Some(scale),
            spacing_before_em: 0.6,
            spacing_after_em: 0.3,
            ..Default::default()
        }
    }

    /// 辅助：创建长文本段落（指定字符数，内容为重复"测试"）
    fn long_text_item(char_count: usize) -> TextItem {
        let text: String = "测试".repeat(char_count / 2 + 1);
        TextItem {
            text,
            ..Default::default()
        }
    }

    /// 辅助：统计页面中的文本行数
    fn count_text_lines(page: &Page) -> usize {
        page.entries
            .iter()
            .filter(|e| matches!(e, PageEntry::Text(_)))
            .count()
    }

    /// A25 统一行级分页：场景 A（整段推页）与场景 B（仅强制首行）退役后，
    /// 长段落跨页只走行级拆分一路——首页容纳前置短段 + 剩余空间可容的
    /// 整行数（孤寡行保护最多 -1 行），不再出现"仅首行 / 整段推页"两档
    #[test]
    fn items_long_para_splits_line_level_regardless_of_fill_ratio() {
        for t in [0.5f32, 0.95f32] {
            let (mut engine, mut cfg) = create_test_engine();
            cfg.page_fill_threshold = t;
            engine.config.page_fill_threshold = t;

            let short = LayoutItem::text("短段落测试一二三四五六七八");
            let items = vec![
                short.clone(),
                short.clone(),
                short.clone(),
                // 长段落：300+ 字 → 18+ 行，无法整段容纳
                LayoutItem::Text(long_text_item(300)),
            ];
            let pages = engine.layout_items(&items, 0).unwrap();
            assert!(pages.len() >= 2, "长段落应跨页（threshold={t}）");

            let page0_lines = count_text_lines(&pages[0]);
            let page1_lines = count_text_lines(&pages[1]);
            // 3 短段（各 1 行 + 段距 8）之后剩余空间可容的整行数
            let line_h = cfg.font_size * cfg.line_height_multiplier;
            let bottom_limit = cfg.padding.top
                + (cfg.height - cfg.padding.top - cfg.padding.bottom) * t;
            let y_after_shorts = cfg.padding.top + 3.0 * (line_h + cfg.paragraph_spacing);
            let fit = (((bottom_limit - y_after_shorts).max(0.0) + 0.01) / line_h) as usize;
            assert!(
                fit >= 2 && page0_lines == 3 + fit,
                "threshold={t} 首页应行级拆分：3 短段 + {fit} 长行（实得 {page0_lines}）"
            );
            assert!(
                page1_lines > 1,
                "threshold={t} page 1 应有长段剩余行（实得 {page1_lines}）"
            );
        }
    }

    /// P2 场景 C：标题孤立避免——剩余空间不足标题+2 行时推到下一页
    #[test]
    fn items_scene_c_heading_isolation_avoidance() {
        let (engine, _config) = create_test_engine();

        // 10 个短段落填充至 current_y ≈ 330
        // (10 * 32 - 8) + 10 = 322, current_y = 330
        let short = LayoutItem::text("短段落测试一二三四五六七八");
        let heading = LayoutItem::Text(heading_item("第一章 测试标题", 1.4));
        let items: Vec<LayoutItem> = (0..10)
            .map(|_| short.clone())
            .chain(std::iter::once(heading))
            .collect();

        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 2, "标题应被推到下一页");

        // page 0 不应以标题结尾（标题被 Scene C 推走）
        let page0_last = pages[0].entries.last();
        let last_is_heading = page0_last.map_or(false, |e| match e {
            PageEntry::Text(l) => l.font_scale == Some(1.4),
            _ => false,
        });
        assert!(
            !last_is_heading,
            "Scene C：标题不应孤立在 page 0 末尾"
        );

        // page 1 应以标题开始
        let page1_first = pages[1].entries.first();
        let first_is_heading = page1_first.map_or(false, |e| match e {
            PageEntry::Text(l) => l.font_scale == Some(1.4),
            _ => false,
        });
        assert!(
            first_is_heading,
            "Scene C：标题应在 page 1 顶部"
        );
    }

    /// P2 场景 C 反向：空间充足时标题不推页
    #[test]
    fn items_scene_c_heading_fits_when_space_sufficient() {
        let (engine, _config) = create_test_engine();

        // 3 个短段落：current_y ≈ 106，剩余空间充足
        let short = LayoutItem::text("短段落测试一二三四五六七八");
        let heading = LayoutItem::Text(heading_item("第一章 测试标题", 1.4));
        let items = vec![short.clone(), short.clone(), short.clone(), heading];

        let pages = engine.layout_items(&items, 0).unwrap();

        // 空间充足：标题应在 page 0（同页）
        assert_eq!(
            pages.len(),
            1,
            "空间充足时不应分页，实际 {} 页",
            pages.len()
        );

        let has_heading = pages[0].entries.iter().any(|e| match e {
            PageEntry::Text(l) => l.font_scale == Some(1.4),
            _ => false,
        });
        assert!(has_heading, "标题应在 page 0");
    }

    /// P2 综合（A25 收紧）：多种段落长度混合布局，非末页底部留白
    /// < 1 行高 + 段距（行级分页下留白只来自孤寡行保护/段距折叠）
    #[test]
    fn items_mixed_layout_whitespace_under_15_percent() {
        let (engine, config) = create_test_engine();
        let bottom_limit = config.height - config.padding.bottom;
        // A25：15% → 2 行高（行级分页下留白只来自孤行/寡行保护——
        // 孤行推页最多让出一个行槽 + 页内节距余数，实测 ≤ 1.5 行高）
        let max_whitespace = 2.0 * config.font_size * config.line_height_multiplier;

        // 混合段落：短（1 行）、中（3 行）、长（5 行），模拟真实章节
        let p1 = LayoutItem::text("短段一二三四五六七");
        let p3 = LayoutItem::Text(long_text_item(48)); // ~3 行
        let p5 = LayoutItem::Text(long_text_item(82)); // ~5 行

        let items: Vec<LayoutItem> = vec![
            p1.clone(), p3.clone(), p5.clone(),
            p1.clone(), p3.clone(), p5.clone(),
            p1.clone(), p3.clone(), p5.clone(),
            p1.clone(), p3.clone(), p5.clone(),
            p1.clone(), p3.clone(),
        ];

        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() > 1, "应有多页");

        // 验证非末页底部留白 < 15%
        for i in 0..pages.len().saturating_sub(1) {
            let page = &pages[i];
            if page.entries.is_empty() {
                continue;
            }
            let last_bottom = page
                .entries
                .iter()
                .filter_map(|e| match e {
                    PageEntry::Text(l) => Some(l.y + l.height),
                    _ => None,
                })
                .fold(0.0f32, f32::max);

            let whitespace = bottom_limit - last_bottom;
            assert!(
                whitespace < max_whitespace,
                "page {} 底部留白 {:.1}px 超过 15%（{:.1}px）",
                i,
                whitespace,
                max_whitespace
            );
        }
    }

    // ===== M9 P5：首行缩进渲染 =====

    /// P5：首行缩进——首行 x 偏移 indent_px，后续行 x=padding.left
    #[test]
    fn items_first_line_indent_offsets_x() {
        let (engine, config) = create_test_engine();
        let indent_em = 2.0f32; // 2em
        let indent_px = indent_em * config.font_size; // 2 × 16 = 32px

        let item = TextItem {
            text: "首行缩进测试这是一段很长很长的文本用来确保产生多行".to_string(),
            indent_first_line_em: Some(indent_em),
            ..Default::default()
        };
        let pages = engine.layout_items(&[LayoutItem::Text(item)], 0).unwrap();
        assert_eq!(pages.len(), 1);

        let texts: Vec<&TextLine> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .collect();
        assert!(texts.len() > 1, "应产生多行");

        // 首行 x = padding.left + indent_px
        let expected_first_x = config.padding.left + indent_px;
        assert!(
            (texts[0].x - expected_first_x).abs() < 1.0,
            "首行 x 应为 {}（padding.left + indent_px），实际 {}",
            expected_first_x,
            texts[0].x
        );

        // 后续行 x = padding.left（无缩进）
        for (i, line) in texts.iter().enumerate().skip(1) {
            assert!(
                (line.x - config.padding.left).abs() < 1.0,
                "第 {} 行 x 应为 {}（padding.left），实际 {}",
                i + 1,
                config.padding.left,
                line.x
            );
        }
    }

    /// A34.1：Right 对齐 + 首行缩进——短行仍贴右缘，不得溢出
    #[test]
    fn items_right_align_with_indent_stays_in_content() {
        let (engine, config) = create_test_engine();
        let indent_em = 2.0f32;
        let indent_px = indent_em * config.font_size;
        let content_right = config.padding.left + (config.width - config.padding.left - config.padding.right);

        let item = TextItem {
            text: "——梭罗".to_string(),
            align: Some(LayoutAlign::Right),
            indent_first_line_em: Some(indent_em),
            ..Default::default()
        };
        let pages = engine.layout_items(&[LayoutItem::Text(item)], 0).unwrap();
        let line = pages[0]
            .entries
            .iter()
            .find_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .expect("应有一行");
        let right_edge = line.x + line.width;
        assert!(
            right_edge <= content_right + 0.5,
            "Right+indent 短行右缘 {:.1} 不得超过内容右缘 {:.1}（indent_px={:.1}）",
            right_edge,
            content_right,
            indent_px
        );
        // 右对齐短行应贴近右缘（而非左起点+indent）
        assert!(
            right_edge >= content_right - line.width - 1.0,
            "右缘 {:.1} 应贴近内容右缘 {:.1}",
            right_edge,
            content_right
        );
    }

    /// P5：无缩进时布局与 M8 一致（x = padding.left）
    #[test]
    fn items_no_indent_matches_m8_layout() {
        let (engine, config) = create_test_engine();

        let item = TextItem {
            text: "无缩进段落测试这是一段很长很长的文本".to_string(),
            indent_first_line_em: None,
            ..Default::default()
        };
        let pages = engine.layout_items(&[LayoutItem::Text(item)], 0).unwrap();
        let texts: Vec<&TextLine> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .collect();

        // 所有行 x = padding.left
        for (i, line) in texts.iter().enumerate() {
            assert!(
                (line.x - config.padding.left).abs() < 1.0,
                "第 {} 行 x 应为 {}，实际 {}",
                i + 1,
                config.padding.left,
                line.x
            );
        }
    }

    /// P5：首行缩进减小首行可用宽度（首行容纳更少字符）
    #[test]
    fn items_indent_reduces_first_line_capacity() {
        let (engine, _config) = create_test_engine();

        // 同一文本，有缩进 vs 无缩进，首行字符数应不同
        let text = "首行缩进对比测试这是一段很长很长的文本内容啊".to_string();

        let no_indent = LayoutItem::Text(TextItem {
            text: text.clone(),
            indent_first_line_em: None,
            ..Default::default()
        });
        let with_indent = LayoutItem::Text(TextItem {
            text,
            indent_first_line_em: Some(2.0),
            ..Default::default()
        });

        let pages_no = engine.layout_items(&[no_indent], 0).unwrap();
        let pages_indent = engine.layout_items(&[with_indent], 0).unwrap();

        let no_first = &pages_no[0].entries[0];
        let indent_first = &pages_indent[0].entries[0];

        // 有缩进的首行应更短（容纳更少字符）
        match (no_first, indent_first) {
            (PageEntry::Text(no_line), PageEntry::Text(indent_line)) => {
                assert!(
                    indent_line.text.chars().count() <= no_line.text.chars().count(),
                    "有缩进首行字符数应 ≤ 无缩进首行（{} ≤ {}）",
                    indent_line.text.chars().count(),
                    no_line.text.chars().count()
                );
            }
            _ => panic!("应为文本行"),
        }
    }

    /// M9.1 回归：禁则回退不得重复/丢失文本（真书《剑来》段落15，129 字）
    ///
    /// 根因：pull-back 分支 flush 后未清空 pieces 的已发射前缀，pulled 压在
    /// 前缀之上，下一行重复发射整个前缀（EPUB styled / TXT 双路径同源）。
    /// 本测试用真书文本 + 探针同参（内容宽 360、字号 18、缩进 2em），
    /// 行边界恰好命中「、」行首禁则触发回退路径。
    #[test]
    fn kinsoku_pullback_no_text_duplication() {
        // 用探针精确条件：400×800、字号18、padding 20（内容宽 360）
        let mut font_manager = FontManager::new();
        let _ = font_manager.load_font_from_file("TestFont".to_string(), "C:/Windows/Fonts/simsun.ttc");
        let config = LayoutConfig {
            width: 400.0,
            height: 800.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets { left: 20.0, top: 20.0, right: 20.0, bottom: 20.0 },
            font_name: "TestFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 8.0,
            page_fill_threshold: 0.9,
            show_comments: true,
            comment_scale: 0.82,
            justify: false,
            punctuation_compress: false,
        };
        let engine = LayoutEngine::new(config, font_manager);
        let text = "暮色里，小镇名叫泥瓶巷的僻静地方，有个孤苦伶仃的清瘦少年。此时，他正按照习俗，一手持蜡烛，一手持桃枝，照耀房梁、墙壁、木床等处，用桃枝敲敲打打，试图借此驱赶蛇蝎、蜈蚣等。他嘴里念念有词，是这座小镇祖祖辈辈传下来的老话：二月二，烛照梁，桃打墙，人间蛇虫无处藏。".to_string();
        assert_eq!(text.chars().count(), 129);

        let item = LayoutItem::Text(TextItem {
            text: text.clone(),
            indent_first_line_em: Some(2.0),
            ..Default::default()
        });
        let pages = engine.layout_items(&[item], 0).unwrap();

        // 不变量 1：行文本拼接 == 原文（无重复无丢失）
        let joined: String = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.text.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(joined, text, "行拼接必须还原原文（禁则回退不得重复/丢失）");

        // 不变量 2：任一行不得超出内容宽（超宽行会触发 Dart 端缩字兜底）
        let content_w = 360.0;
        for e in &pages[0].entries {
            if let PageEntry::Text(l) = e {
                let n = l.text.chars().count() as f32;
                assert!(
                    n * 18.0 <= content_w * 1.02,
                    "行宽超限：{} 字符 × 18px > 内容宽",
                    l.text
                );
            }
        }
    }

    // ===== M9.2 TXT 行级分页测试 =====
    //
    // 基线引擎：300×400、字号16、行高24、padding10、段距8
    // → 内容区 280×380，每页至多 15 行（floor(380/24)），底边 y=390。

    /// 构造恰好折行为 target_lines 行的填充段（按实际字体度量搜索字数）
    fn text_with_lines(engine: &LayoutEngine, target_lines: usize, filler: char) -> String {
        let cw = engine.config.width - engine.config.padding.left - engine.config.padding.right;
        for n in 1..20000 {
            let text: String = std::iter::repeat(filler).take(n).collect();
            let lines = engine.layout_paragraph_with_oracle(&text, cw).unwrap().len();
            if lines >= target_lines {
                assert_eq!(lines, target_lines, "单字增减跳过了目标行数");
                return text;
            }
        }
        panic!("无法构造 {} 行文本", target_lines);
    }

    fn page_text_lines(page: &Page) -> Vec<&TextLine> {
        page.entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn txt_long_para_line_level_split_fills_bottom() {
        // 长段落跨页续排：首页吃满到底边，底部留白 < 1 行高
        let (engine, config) = create_test_engine();
        let bottom = config.height - config.padding.bottom;
        let lh = config.font_size * config.line_height_multiplier;
        let input = text_with_lines(&engine, 40, '甲');
        let pages = engine.layout_text(&input, 0).unwrap();

        assert!(pages.len() >= 3, "40 行应跨 ≥3 页，实得 {}", pages.len());
        for (i, page) in pages.iter().enumerate() {
            if i + 1 == pages.len() {
                continue; // 末页允许留白
            }
            let lines = page_text_lines(page);
            assert!(!lines.is_empty());
            let last_bottom = lines.last().unwrap().y + lines.last().unwrap().height;
            let gap = bottom - last_bottom;
            assert!(
                gap >= -0.01 && gap < lh,
                "第 {} 页底部留白 {} 应 ∈ [0, 行高)",
                i,
                gap
            );
        }
    }

    #[test]
    fn txt_widow_pull_back_leaves_two_lines() {
        // 寡行保护：拆分将给下页留 1 行 → 本页少放一行，下页收两行
        // （A25b：保护仅在 threshold<1.0 生效，显式设 0.9 激活）
        let (mut engine, mut cfg) = create_test_engine();
        cfg.page_fill_threshold = 0.9;
        engine.config.page_fill_threshold = 0.9;
        let para = text_with_lines(&engine, 15, '甲'); // 0.9 页容 14 行，15 行差 1
        let pages = engine.layout_text(&para, 0).unwrap();

        assert_eq!(pages.len(), 2);
        let p0 = page_text_lines(&pages[0]).len();
        let p1 = page_text_lines(&pages[1]).len();
        assert_eq!(p0, 13, "寡行控制应本页少放一行");
        assert_eq!(p1, 2, "下页应至少两行");
    }

    #[test]
    fn txt_orphan_avoided_when_lt2_fit() {
        // 孤行保护：页尾仅剩 1 行空间且页已 ≥3 行 → 下一段整段推页
        // （A25b：保护仅在 threshold<1.0 生效，显式设 0.9 激活）
        let (mut engine, mut cfg) = create_test_engine();
        cfg.page_fill_threshold = 0.9;
        engine.config.page_fill_threshold = 0.9;
        let a = text_with_lines(&engine, 12, '甲'); // 占 12 行后剩 1 行空间
        let b = text_with_lines(&engine, 5, '乙');
        let input = format!("{}\n{}", a, b);
        let pages = engine.layout_text(&input, 0).unwrap();

        assert!(pages.len() >= 2);
        let p0 = page_text_lines(&pages[0]);
        assert_eq!(p0.len(), 12, "第一页应只有 A 的 12 行");
        assert!(p0.iter().all(|l| l.text.starts_with('甲')), "B 不得出现在第一页");
        let p1_first = &page_text_lines(&pages[1])[0];
        assert!(p1_first.text.starts_with('乙'), "B 应从新页开始");
    }

    #[test]
    fn txt_exact_fit_no_extra_break() {
        // 恰好放满一页的段：不产生多余翻页/假空尾页
        let (engine, _) = create_test_engine();
        let para = text_with_lines(&engine, 15, '甲'); // floor(380/24)=15 恰满
        let pages = engine.layout_text(&para, 0).unwrap();
        assert_eq!(pages.len(), 1, "15 行应恰好一页");
        assert_eq!(page_text_lines(&pages[0]).len(), 15);
    }

    #[test]
    fn txt_punct_compression_extends_line_fit() {
        // P3：行尾压缩悬挂——实测口径 fs=16/cw=280/eps=5：
        // 17 字=272≤285 全收；第 18 字「。」折半预算 280≤285 → 压缩收进行尾；
        // 关闭开关时 288>285 判满 + 行首禁则回退拉回 1 字（16 字）
        let para = format!("{}。乙", "甲".repeat(17));

        let (mut engine, _) = create_test_engine();
        engine.config.punctuation_compress = true;
        let lines = engine.layout_paragraph_with_oracle(&para, 280.0).unwrap();
        assert_eq!(
            lines[0].chars().count(),
            18,
            "「。」应以压缩预算收进行尾（实得 {} 字）",
            lines[0].chars().count()
        );
        assert!(lines[0].ends_with('。'), "被压缩字符应恒为行尾字符");
        assert!(lines[1].starts_with('乙'));

        let (engine2, _) = create_test_engine();
        let lines2 = engine2.layout_paragraph_with_oracle(&para, 280.0).unwrap();
        assert_eq!(
            lines2[0].chars().count(),
            16,
            "关闭压缩时行首禁则回退应拉回 1 字（实得 {} 字）",
            lines2[0].chars().count()
        );
    }

    #[test]
    fn styled_punct_compression_hangs_and_reports_raw_width() {
        // P3：styled 路径压缩接受 + 悬挂行 width 上报 raw（跳过钳制）
        let (mut engine, _) = create_test_engine();
        engine.config.punctuation_compress = true;
        let items = vec![LayoutItem::text(format!("{}。乙", "甲".repeat(17)))];
        let pages = engine.layout_items(&items, 0).unwrap();
        let line = match &pages[0].entries[0] {
            PageEntry::Text(l) => l,
            other => panic!("应为文本行，实为 {:?}", other),
        };
        assert!(line.text.ends_with('。'), "「。」应以压缩预算收进行尾");
        assert_eq!(line.text.chars().count(), 18);
        // raw 宽 ≈ 18×16=288 > content_width 280：悬挂行不钳制
        assert!(
            line.width > 280.0,
            "悬挂行 width 应上报 raw 宽（实得 {}）",
            line.width
        );
    }

    #[test]
    fn txt_fill_threshold_scales_bottom_limit() {
        // A25：填充率语义重定义 = 内容区利用率（TXT 恢复消费）——
        // 底界 = top + content_height × threshold，行级断行按比例提前，
        // 页底留白统一可预期（0.8 → 底部收 20% ≈ 3 行）
        let run = |t: f32| -> Vec<usize> {
            let (mut engine, mut cfg) = create_test_engine();
            cfg.page_fill_threshold = t;
            engine.config.page_fill_threshold = t;
            let short = "第一段落。";
            let long = text_with_lines(&engine, 20, '甲');
            let short_line = format!("{short}\n").repeat(6);
            let input = short_line + &long;
            let pages = engine.layout_text(&input, 0).unwrap();
            pages.iter().map(|p| page_text_lines(p).len()).collect()
        };
        let full = run(1.0);
        let tight = run(0.8);
        assert_eq!(full[0], 13, "填满基线：6 短行 + 7 长行（实得 {full:?}）");
        assert_eq!(
            tight[0], 10,
            "0.8 底界收紧：6 短行 + 4 长行（实得 {tight:?}）"
        );
        assert!(full[0] > tight[0], "更高填充率应容纳更多行");
    }

    #[test]
    fn txt_anchor_continuity_across_manual_split() {
        // 字符锚点不变式：页间 end==下一页 start；每页跨度==Σ行字符数；
        // is_chapter_start 仅全书首行
        let (engine, _) = create_test_engine();
        let input = text_with_lines(&engine, 40, '甲');
        let total_chars = input.chars().count();
        let pages = engine.layout_text(&input, 0).unwrap();
        assert!(pages.len() >= 3);

        let mut covered = 0usize;
        for (i, window) in pages.windows(2).enumerate() {
            assert_eq!(
                window[0].end_char_index, window[1].start_char_index,
                "第 {} 页与次页锚点必须无缝衔接",
                i
            );
        }
        for (i, page) in pages.iter().enumerate() {
            let span: usize = page_text_lines(page).iter().map(|l| l.text.chars().count()).sum();
            // 段尾换行计入其所在页的 end 锚点：单段输入时仅末页 +1
            let newline_tail = if i + 1 == pages.len() { 1 } else { 0 };
            assert_eq!(
                page.end_char_index - page.start_char_index,
                span + newline_tail,
                "第 {} 页锚点跨度应等于行字符和(+段尾换行)",
                i
            );
            covered += span;
            for (j, l) in page_text_lines(page).iter().enumerate() {
                let expect_start = i == 0 && j == 0;
                assert_eq!(l.is_chapter_start, expect_start, "章节起始标记错位");
            }
        }
        assert_eq!(covered, total_chars, "全部行字符数应还原原文");
    }

    #[test]
    fn txt_spacing_once_after_continuation() {
        // 跨页续排后段间距只加一次：续排末行与下一段首行的 y 差 = 行高+段距
        let (engine, config) = create_test_engine();
        let lh = config.font_size * config.line_height_multiplier;
        let spacing = config.paragraph_spacing;
        let long = text_with_lines(&engine, 20, '甲');
        let input = format!("{}\n末段。", long);
        let pages = engine.layout_text(&input, 0).unwrap();
        assert!(pages.len() >= 2);

        let p1 = page_text_lines(&pages[1]);
        assert!(p1.len() >= 2, "续排页应有长段余行 + 末段");
        let gap = p1[p1.len() - 1].y - p1[p1.len() - 2].y;
        assert!(
            (gap - (lh + spacing)).abs() < 0.01,
            "续排末行→下段首行间距应为 行高+段距（{}），实得 {}",
            lh + spacing,
            gap
        );
    }

    #[test]
    fn styled_orphan_avoided_on_page_break() {
        // P4：EPUB styled 路径孤行保护——段落行数 = 页容+1 时，
        // 无保护下页残留 1 行；有保护本页少放一行、下页收两行
        let (mut engine, cfg) = create_test_engine();
        let usable_full = cfg.height - cfg.padding.top - cfg.padding.bottom;
        engine.config.page_fill_threshold = 0.9; // A25b：显式激活孤寡行保护
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let usable = usable_full * 0.9;
        let fit = ((usable + 0.01) / line_h) as usize; // 页可容行数
        let para_lines = fit + 1;
        let para = "甲".repeat(para_lines * 17);
        let items = vec![LayoutItem::text(para)];
        let pages = engine.layout_items(&items, 0).unwrap();
        let counts: Vec<usize> = pages
            .iter()
            .map(|p| {
                p.entries
                    .iter()
                    .filter(|e| matches!(e, PageEntry::Text(_)))
                    .count()
            })
            .collect();
        assert_eq!(
            counts,
            vec![fit - 1, 2],
            "本页少放一行、下页收两行（实得 {:?}，fit={})",
            counts,
            fit
        );
    }

    #[test]
    fn styled_long_para_continuation_pages_stay_full() {
        // P4 回归：孤寡行 cap 断页后必须重置——否则跨页余行每 3~4 行
        // 被再次断页（页碎片化，用户实测分页精度回归）
        let (engine, cfg) = create_test_engine();
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let usable = cfg.height - cfg.padding.top - cfg.padding.bottom;
        let fit = ((usable + 0.01) / line_h) as usize; // 页可容行数
        // 2.5 页容量的单段落（每行 17 字）
        let para_lines = fit * 2 + (fit / 2);
        let para = "甲".repeat(para_lines * 17);
        let items = vec![LayoutItem::text(para)];
        let pages = engine.layout_items(&items, 0).unwrap();
        let counts: Vec<usize> = pages
            .iter()
            .map(|p| {
                p.entries
                    .iter()
                    .filter(|e| matches!(e, PageEntry::Text(_)))
                    .count()
            })
            .collect();
        // 除末页外每页都应排满（首页可能因寡行保护少 1 行）
        for (i, c) in counts.iter().enumerate() {
            if i + 1 < counts.len() {
                assert!(
                    *c >= fit - 1,
                    "第 {i} 页应接近排满（实得 {c}，fit={fit}，全量 {counts:?}）"
                );
            }
        }
        assert_eq!(
            counts.iter().sum::<usize>(),
            para_lines,
            "总行数不得丢失"
        );
    }

    #[test]
    fn styled_short_para_dialogue_pages_fill_at_full_threshold() {
        // A25b 回归：填充率 100% = 纯行级填满（孤寡行保护自动挂起）——
        // 对话密集 1~2 行短段下，保护曾在页底吃掉 1~2 个行槽
        // （用户实测"有的填满有的留白"）。非末页残差必须 < 1 行槽 + 段距
        let mut cfg = LayoutConfig::default();
        cfg.width = 399.3333333333333;
        cfg.height = 854.0;
        cfg.font_size = 16.0;
        cfg.line_height_multiplier = 1.4;
        cfg.page_fill_threshold = 1.0;
        let font_manager = {
            let mut fm = FontManager::new();
            for path in ["C:/Windows/Fonts/simsun.ttc", "C:/Windows/Fonts/msyh.ttc"] {
                if std::path::Path::new(path).exists()
                    && fm.load_font_from_file("TestFont".to_string(), path).is_ok()
                {
                    break;
                }
            }
            fm
        };
        let engine = LayoutEngine::new(cfg.clone(), font_manager);
        let paras = [
            "尤其是你和他踏上修行大道之后，不管是名结为道侣，都应当收敛锐气，不可跋扈怂唯。".to_string(),
            "这并非什么威胁，而是离别之际，我的一些肺腑之言，也算是善意的提醒。".to_string(),
            "照理说，两人身份天壤之别，婢女稚圭却极为不卑不亢，甚至当下气势还要隐约压过齐静春半头。".to_string(),
            "她讥笑道：\"善意?".to_string(),
            "数千年来，你们这些了不起的修行中人，高高在上，画地为牢，拿此地作为一块庄稼地，今年割一茬明年拔一捆，年复一年，".to_string(),
            "千年不变，怎么到了现在，才开始想要同我这孽障'与人为善'了。".to_string(),
            "哈哈，我听少爷说过一句话，被你们很多人奉为圭臬，叫作'非我族类，其心必异'，对吧?".to_string(),
            "所以也怪不得齐先生，毕竟……".to_string(),
            "齐静春继续前行，轻轻踏出一步，似笑非笑：\"哦?".to_string(),
            "一步之后。婢女稚圭脸色微变。".to_string(),
            "两人不知何时站在了一处地方，四处漆黑，伸手不见五指，唯有遥遥的头顶上方，有无数孕育着神圣气息的光线洒落而下。".to_string(),
            "他们如同置身于一口深不见底的水井井底，那些金黄色的阳光从井口缓缓落下。".to_string(),
        ];
        let items: Vec<LayoutItem> = paras
            .iter()
            .cycle()
            .take(paras.len() * 4)
            .map(|p| LayoutItem::text(p.clone()))
            .collect();
        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 3, "应跨 ≥3 页（实得 {}）", pages.len());
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let bottom_limit = cfg.padding.top
            + (cfg.height - cfg.padding.top - cfg.padding.bottom) * cfg.page_fill_threshold;
        for (i, p) in pages.iter().enumerate() {
            if i + 1 == pages.len() {
                continue; // 末页合法不满
            }
            let last_bottom = p
                .entries
                .iter()
                .filter_map(|e| match e {
                    PageEntry::Text(l) => Some(l.y + l.height),
                    _ => None,
                })
                .fold(0.0f32, f32::max);
            let residue = bottom_limit - last_bottom;
            assert!(
                residue < line_h + cfg.paragraph_spacing + 0.5,
                "第 {i} 页残差 {residue:.1}px ≥ 1 行槽+段距（保护应挂起）"
            );
        }
        // 锚点无缝衔接
        for w in pages.windows(2) {
            assert_eq!(w[0].end_char_index, w[1].start_char_index, "锚点必须衔接");
        }
    }

    #[test]
    fn styled_epub_page_fill_under_user_params() {
        // P4 回归（A25 强化断言）：用户实测参数（fs=16/行距 1.4/399x854/
        // fill 0.95）下长内容应产满页——防「孤寡行 cap 浮点 ULP 漂移」
        // 碎片化回归（非末页 ≥ 3/4 页容 + 锚点无缝衔接）
        let mut cfg = LayoutConfig::default();
        cfg.width = 399.3333333333333;
        cfg.height = 854.0;
        cfg.font_size = 16.0;
        cfg.line_height_multiplier = 1.4;
        cfg.page_fill_threshold = 0.95;
        let font_manager = {
            let mut fm = FontManager::new();
            for path in ["C:/Windows/Fonts/simsun.ttc", "C:/Windows/Fonts/msyh.ttc"] {
                if std::path::Path::new(path).exists()
                    && fm.load_font_from_file("TestFont".to_string(), path).is_ok()
                {
                    break;
                }
            }
            fm
        };
        let engine = LayoutEngine::new(cfg.clone(), font_manager);

        // 截图文案：短段与长段混合，重复 8 次构造跨页长文
        let paras = [
            "能听天由命。".to_string(),
            "不过在烧窑之前，拉坯无疑又是重中之重，只不过陈平安被姚老头认为资质差，多是做些练泥的体力活，而且他多是只能在旁边仔细观摩，".to_string(),
            "然后自己练泥，自己拉坯，寻找手感。".to_string(),
            "隔壁院子响起柴门推开的声音，原来是宋集薪带着婢女稚圭从学塾返回，英俊少年一个冲刺，轻轻巧巧地翻身而上，动作熟练得像是做过千百遍。".to_string(),
            "刘羡阳挠头，.o".to_string(),
        ];
        let items: Vec<LayoutItem> = paras
            .iter()
            .cycle()
            .take(paras.len() * 8)
            .map(|p| LayoutItem::text(p.clone()))
            .collect();
        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 3, "重复 8 次应跨 ≥3 页（实得 {}）", pages.len());

        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let bottom_limit = cfg.padding.top
            + (cfg.height - cfg.padding.top - cfg.padding.bottom) * cfg.page_fill_threshold;
        let fit = (((bottom_limit - cfg.padding.top) + 0.01) / line_h) as usize;
        let counts: Vec<usize> = pages
            .iter()
            .map(|p| {
                p.entries
                    .iter()
                    .filter(|e| matches!(e, PageEntry::Text(_)))
                    .count()
            })
            .collect();
        for (i, c) in counts.iter().enumerate() {
            if i + 1 < counts.len() {
                assert!(
                    *c >= fit * 3 / 4,
                    "第 {i} 页应接近排满（实得 {c}，fit={fit}，全量 {counts:?}）"
                );
            }
        }
        // 锚点无缝衔接（总行数守恒的间接不变式）
        for w in pages.windows(2) {
            assert_eq!(
                w[0].end_char_index, w[1].start_char_index,
                "页间锚点必须无缝衔接"
            );
        }
    }

    // ===== A33：页底行级填满一致性基线 =====

    fn page_bottom_residual(page: &Page, bottom_limit: f32) -> f32 {
        let last_bottom = page
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l.y + l.height),
                PageEntry::Image(img) => Some(img.y + img.height),
                PageEntry::Rect(r) => Some(r.y + r.height),
            })
            .fold(0.0f32, f32::max);
        (bottom_limit - last_bottom).max(0.0)
    }

    /// 纯文本长段 @ fill=1.0：非末页残余必须 < 1 行高（A33 产品契约）
    #[test]
    fn items_pure_text_full_fill_residual_under_one_line() {
        let (engine, cfg) = create_test_engine();
        assert!(
            (cfg.page_fill_threshold - 1.0).abs() < 1e-6,
            "基线夹具应用 fill=1.0"
        );
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let bottom_limit = cfg.padding.top
            + (cfg.height - cfg.padding.top - cfg.padding.bottom) * cfg.page_fill_threshold;

        let items: Vec<LayoutItem> = (0..40)
            .map(|_| LayoutItem::Text(long_text_item(200)))
            .collect();
        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 3, "应跨多页（实得 {}）", pages.len());

        for (i, p) in pages.iter().enumerate() {
            if i + 1 == pages.len() {
                continue;
            }
            let residual = page_bottom_residual(p, bottom_limit);
            assert!(
                residual < line_h + 0.5,
                "page {} 残余 {:.1}px ≥ 1 行高 {:.1}px（忽满忽空）",
                i,
                residual,
                line_h
            );
        }
    }

    /// 页尾 space_before 折叠：段前距不得单独把本页顶出一截空洞
    #[test]
    fn items_space_before_folded_at_page_bottom() {
        let (engine, cfg) = create_test_engine();
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let bottom_limit = cfg.padding.top
            + (cfg.height - cfg.padding.top - cfg.padding.bottom) * cfg.page_fill_threshold;

        // 先用若干短段把页填到只剩约 1.5 行，再接大段前距段落
        let short = LayoutItem::text("短段测试一二三四五六七八九十");
        let mut items: Vec<LayoutItem> = Vec::new();
        for _ in 0..12 {
            items.push(short.clone());
        }
        // 段前距 2em ≈ 32px，接近 1.5 行——若页尾预加后正文放不下会空洞
        items.push(LayoutItem::Text(TextItem {
            text: "带段前距的段落内容一二三四五六七八九十十一十二十三十四十五十六十七十八十九二十。".into(),
            spacing_before_em: 2.0,
            ..Default::default()
        }));
        // 后续长段保证至少 2 页
        for _ in 0..10 {
            items.push(LayoutItem::Text(long_text_item(180)));
        }

        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 2);
        for (i, p) in pages.iter().enumerate() {
            if i + 1 == pages.len() {
                continue;
            }
            let residual = page_bottom_residual(p, bottom_limit);
            assert!(
                residual < line_h + 0.5,
                "page {} 段前距未折叠，残余 {:.1}px（行高 {:.1}）",
                i,
                residual,
                line_h
            );
        }
    }

    /// 混 scale 段落：fit 应按逐行真实行高累计，非末页残余 < 1 行
    #[test]
    fn items_mixed_scale_per_line_height_fill() {
        let (engine, cfg) = create_test_engine();
        let line_h = cfg.font_size * cfg.line_height_multiplier;
        let bottom_limit = cfg.padding.top
            + (cfg.height - cfg.padding.top - cfg.padding.bottom) * cfg.page_fill_threshold;

        // 同段内混 scale：主体 1.0，中间一段 1.5
        let text = format!(
            "{}{}{}",
            "甲".repeat(40),
            "乙".repeat(40),
            "丙".repeat(80)
        );
        let chars_len = text.chars().count();
        let item = TextItem {
            text,
            runs: vec![RunSpan {
                start: 80,
                end: (80 + 40).min(chars_len),
                color: None,
                font_scale: Some(1.5),
                bold: false,
                italic: false,
                underline: false,
                footnote_ref: None,
            }],
            ..Default::default()
        };
        let items: Vec<LayoutItem> = (0..20).map(|_| LayoutItem::Text(item.clone())).collect();
        let pages = engine.layout_items(&items, 0).unwrap();
        assert!(pages.len() >= 2);
        for (i, p) in pages.iter().enumerate() {
            if i + 1 == pages.len() {
                continue;
            }
            let residual = page_bottom_residual(p, bottom_limit);
            // 混 scale 允许略松，但仍不得超过 1 行 + 半个大字号行
            let loose = line_h * 1.6;
            assert!(
                residual < loose + 0.5,
                "page {} 混 scale 残余 {:.1}px 过大（宽松上限 {:.1}）",
                i,
                residual,
                loose
            );
        }
    }

    /// 注释行高：强制 comment_scale 覆盖，不得与 CSS font_scale 双重相乘
    #[test]
    fn items_comment_line_height_single_scale() {
        let (engine, cfg) = create_test_engine();
        let base = cfg.font_size * cfg.line_height_multiplier;
        let cs = cfg.comment_scale.clamp(0.5, 1.2);
        let item = TextItem {
            text: "这是一条注释内容，用于验证行高只乘一次 comment_scale。".repeat(2),
            is_comment: true,
            font_scale: Some(0.7), // CSS 物化常见路径——应被覆盖
            ..Default::default()
        };
        let items = vec![LayoutItem::Text(item)];
        let pages = engine.layout_items(&items, 0).unwrap();
        let lines: Vec<_> = pages[0]
            .entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                _ => None,
            })
            .collect();
        assert!(lines.len() >= 2, "应有多行注释");
        let expected_h = base * cs;
        for l in &lines {
            assert!(
                (l.height - expected_h).abs() < 0.05,
                "注释行高 {:.2} 应为 base×{:.2}={:.2}（禁止再乘 CSS scale）",
                l.height,
                cs,
                expected_h
            );
        }
        // y 递进一致
        for w in lines.windows(2) {
            assert!(
                (w[1].y - (w[0].y + w[0].height)).abs() < 0.05,
                "注释行 y 递进应等于单倍 comment_scale 行高"
            );
        }
    }
}