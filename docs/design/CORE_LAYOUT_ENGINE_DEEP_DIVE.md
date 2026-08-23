# 核心排版引擎深度技术设计

> **聚焦问题**：分页精度、字符边界、EPUB 图文混排、字形测量性能、智能分段  
> **设计目标**：解决最核心、最棘手、最容易产生性能波动的技术难题

---

## 🎯 核心问题诊断

### 问题 1: 字符边界计算不准确

**现象**：
```rust
// ❌ 错误示例：直接按字节切分
let chapter_content = &content[start..end];  // panic: 可能不在字符边界

// ❌ 问题根源
"你好世界".len() = 12 字节  // UTF-8: 每个汉字 3 字节
content[0..3] = "你"  // ✅ 正确
content[0..4] = ???   // ❌ panic: 不在字符边界 (4 在 "好" 的中间)
```

**根本原因分析**：
1. **UTF-8 变长编码**：
   - ASCII: 1 字节
   - 汉字: 3 字节
   - Emoji: 4 字节（如 "😀"）
   - 特殊字符: 2-6 字节

2. **Grapheme Cluster（字形簇）**：
   ```rust
   "é" 可能是：
   - 单个 Unicode 码点: U+00E9 (2 字节)
   - 组合字符: e (1 字节) + ́ (2 字节) = 3 字节
   
   // 视觉上是 1 个字符，但实际占 2 个 Unicode 码点
   ```

3. **全角字符**：
   ```rust
   "　　" (全角空格) = 6 字节 (每个 3 字节)
   "  " (半角空格) = 2 字节 (每个 1 字节)
   ```

**核心解决方案**：

```rust
// rust/crates/layout_engine/src/text_boundary.rs

use unicode_segmentation::UnicodeSegmentation;

/// 安全的文本边界处理器
pub struct TextBoundaryHandler {
    content: String,
    
    /// 字符索引 → 字节偏移映射
    char_to_byte_map: Vec<usize>,
    
    /// 字形簇边界（用于光标移动）
    grapheme_boundaries: Vec<usize>,
}

impl TextBoundaryHandler {
    pub fn new(content: String) -> Self {
        // 1. 构建字符索引映射
        let mut char_to_byte_map = vec![0];
        for (byte_offset, _) in content.char_indices() {
            char_to_byte_map.push(byte_offset);
        }
        char_to_byte_map.push(content.len());
        
        // 2. 构建字形簇边界
        let grapheme_boundaries = content
            .grapheme_indices(true)
            .map(|(idx, _)| idx)
            .collect();
        
        Self {
            content,
            char_to_byte_map,
            grapheme_boundaries,
        }
    }
    
    /// 获取字符范围（安全）
    pub fn get_char_range(&self, start_char: usize, end_char: usize) -> Result<&str> {
        let start_byte = self.char_to_byte_map.get(start_char)
            .ok_or_else(|| anyhow!("Start char out of bounds"))?;
        let end_byte = self.char_to_byte_map.get(end_char)
            .ok_or_else(|| anyhow!("End char out of bounds"))?;
        
        Ok(&self.content[*start_byte..*end_byte])
    }
    
    /// 查找最近的字符边界（向前）
    pub fn find_char_boundary_before(&self, byte_offset: usize) -> usize {
        // 二分查找最近的字符边界
        match self.char_to_byte_map.binary_search(&byte_offset) {
            Ok(idx) => self.char_to_byte_map[idx],
            Err(idx) => {
                if idx > 0 {
                    self.char_to_byte_map[idx - 1]
                } else {
                    0
                }
            }
        }
    }
    
    /// 查找最近的字形簇边界（用于光标移动）
    pub fn find_grapheme_boundary(&self, byte_offset: usize) -> usize {
        match self.grapheme_boundaries.binary_search(&byte_offset) {
            Ok(idx) => self.grapheme_boundaries[idx],
            Err(idx) => {
                if idx > 0 {
                    self.grapheme_boundaries[idx - 1]
                } else {
                    0
                }
            }
        }
    }
    
    /// 计算字符数（不是字节数）
    pub fn char_count(&self) -> usize {
        self.char_to_byte_map.len() - 1
    }
    
    /// 计算字形簇数量（视觉上的字符数）
    pub fn grapheme_count(&self) -> usize {
        self.grapheme_boundaries.len()
    }
}
```

**分页时的精确边界计算**：

```rust
// rust/crates/layout_engine/src/pagination/precise_boundary.rs

/// 精确分页边界计算器
pub struct PrecisePaginationBoundary {
    boundary_handler: TextBoundaryHandler,
    lines: Vec<LayoutLine>,
}

#[derive(Debug, Clone)]
pub struct LayoutLine {
    /// 起始字符索引（不是字节）
    pub start_char_idx: usize,
    
    /// 结束字符索引（不是字节）
    pub end_char_idx: usize,
    
    /// 实际渲染宽度（像素）
    pub width: f32,
    
    /// 行高（像素）
    pub height: f32,
    
    /// Y 坐标
    pub y: f32,
}

impl PrecisePaginationBoundary {
    /// 分页时精确定位边界
    pub fn split_into_pages(
        &self,
        page_height: f32,
        padding_top: f32,
        padding_bottom: f32,
    ) -> Vec<PageBoundary> {
        let content_height = page_height - padding_top - padding_bottom;
        let mut pages = Vec::new();
        let mut current_page_start_line = 0;
        let mut current_height = padding_top;
        
        for (line_idx, line) in self.lines.iter().enumerate() {
            if current_height + line.height > page_height - padding_bottom {
                // 需要分页
                
                // ✅ 关键：记录精确的字符边界，而不是字节偏移
                let page = PageBoundary {
                    start_line: current_page_start_line,
                    end_line: line_idx,
                    start_char_idx: self.lines[current_page_start_line].start_char_idx,
                    end_char_idx: self.lines[line_idx - 1].end_char_idx,
                };
                
                pages.push(page);
                
                current_page_start_line = line_idx;
                current_height = padding_top + line.height;
            } else {
                current_height += line.height;
            }
        }
        
        // 最后一页
        if current_page_start_line < self.lines.len() {
            pages.push(PageBoundary {
                start_line: current_page_start_line,
                end_line: self.lines.len(),
                start_char_idx: self.lines[current_page_start_line].start_char_idx,
                end_char_idx: self.lines.last().unwrap().end_char_idx,
            });
        }
        
        pages
    }
}

#[derive(Debug, Clone)]
pub struct PageBoundary {
    pub start_line: usize,
    pub end_line: usize,
    
    /// ✅ 精确的字符索引（用于跨配置恢复位置）
    pub start_char_idx: usize,
    pub end_char_idx: usize,
}
```

---

## 问题 2: 字形测量性能瓶颈

**现象**：
```
10,000 字的章节排版耗时：
  - 字形测量: 80ms (占比 80%)
  - 换行计算: 15ms
  - 分页计算: 5ms
```

**根本原因**：
1. **重复测量**：相同字符在不同位置重复测量
2. **字体加载慢**：每次排版都重新加载字体
3. **缓存未命中**：简单的 HashMap 缓存，没有考虑字号/字体组合

**核心解决方案**：

```rust
// rust/crates/layout_engine/src/glyph_cache_advanced.rs

use lru::LruCache;
use ab_glyph::{FontArc, ScaleFont, GlyphId};

/// 高级字形缓存（支持多字体、多字号）
pub struct AdvancedGlyphCache {
    /// 三级缓存键：(字体名, 字号, 字符)
    cache: LruCache<GlyphCacheKey, GlyphMetrics>,
    
    /// 统计信息
    hit_count: u64,
    miss_count: u64,
    
    /// 预热常用字符集
    prewarmed: bool,
}

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
struct GlyphCacheKey {
    font_name: String,
    font_size_bits: u32,  // f32 转为位表示，避免浮点比较
    character: char,
}

#[derive(Debug, Clone, Copy)]
pub struct GlyphMetrics {
    pub advance_width: f32,
    pub height: f32,
    pub ascent: f32,
    pub descent: f32,
}

impl AdvancedGlyphCache {
    pub fn new(capacity: usize) -> Self {
        Self {
            cache: LruCache::new(std::num::NonZeroUsize::new(capacity).unwrap()),
            hit_count: 0,
            miss_count: 0,
            prewarmed: false,
        }
    }
    
    /// 预热常用汉字（3500 个常用字）
    pub fn prewarm(&mut self, font: &FontArc, font_name: &str, font_size: f32) {
        if self.prewarmed {
            return;
        }
        
        // GB2312 一级常用字（3755 个）
        const COMMON_CHARS: &str = include_str!("../data/gb2312_level1.txt");
        
        let scaled_font = font.as_scaled(font_size);
        
        for ch in COMMON_CHARS.chars() {
            let glyph_id = font.glyph_id(ch);
            let advance = scaled_font.h_advance(glyph_id);
            
            // 计算行高相关指标
            let v_metrics = scaled_font.v_metrics();
            
            let key = GlyphCacheKey {
                font_name: font_name.to_string(),
                font_size_bits: font_size.to_bits(),
                character: ch,
            };
            
            let metrics = GlyphMetrics {
                advance_width: advance,
                height: v_metrics.ascent - v_metrics.descent,
                ascent: v_metrics.ascent,
                descent: v_metrics.descent,
            };
            
            self.cache.put(key, metrics);
        }
        
        self.prewarmed = true;
    }
    
    /// 获取字形指标（带缓存）
    pub fn get_metrics(
        &mut self,
        font: &FontArc,
        font_name: &str,
        font_size: f32,
        character: char,
    ) -> GlyphMetrics {
        let key = GlyphCacheKey {
            font_name: font_name.to_string(),
            font_size_bits: font_size.to_bits(),
            character,
        };
        
        // 尝试从缓存获取
        if let Some(metrics) = self.cache.get(&key) {
            self.hit_count += 1;
            return *metrics;
        }
        
        // 未命中，实际测量
        self.miss_count += 1;
        
        let scaled_font = font.as_scaled(font_size);
        let glyph_id = font.glyph_id(character);
        let advance = scaled_font.h_advance(glyph_id);
        let v_metrics = scaled_font.v_metrics();
        
        let metrics = GlyphMetrics {
            advance_width: advance,
            height: v_metrics.ascent - v_metrics.descent,
            ascent: v_metrics.ascent,
            descent: v_metrics.descent,
        };
        
        self.cache.put(key, metrics);
        metrics
    }
    
    /// 批量测量（性能优化）
    pub fn batch_measure(
        &mut self,
        font: &FontArc,
        font_name: &str,
        font_size: f32,
        text: &str,
    ) -> Vec<GlyphMetrics> {
        let mut results = Vec::with_capacity(text.len());
        
        for ch in text.chars() {
            results.push(self.get_metrics(font, font_name, font_size, ch));
        }
        
        results
    }
    
    /// 获取缓存统计
    pub fn stats(&self) -> CacheStats {
        let total = self.hit_count + self.miss_count;
        CacheStats {
            hit_count: self.hit_count,
            miss_count: self.miss_count,
            hit_rate: if total > 0 {
                self.hit_count as f32 / total as f32
            } else {
                0.0
            },
            size: self.cache.len(),
            capacity: self.cache.cap().get(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct CacheStats {
    pub hit_count: u64,
    pub miss_count: u64,
    pub hit_rate: f32,
    pub size: usize,
    pub capacity: usize,
}
```

**性能优化策略**：

```rust
// rust/crates/layout_engine/src/layout_optimizer.rs

/// 排版性能优化器
pub struct LayoutOptimizer {
    glyph_cache: AdvancedGlyphCache,
    
    /// 段落级缓存（避免重复排版相同段落）
    paragraph_cache: LruCache<ParagraphCacheKey, Vec<LayoutLine>>,
}

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
struct ParagraphCacheKey {
    content_hash: u64,  // 段落内容的哈希
    config_hash: u64,   // 排版配置的哈希
}

impl LayoutOptimizer {
    /// 智能排版（带多级缓存）
    pub fn layout_text_optimized(
        &mut self,
        text: &str,
        font: &FontArc,
        config: &LayoutConfig,
    ) -> Vec<LayoutLine> {
        // 1. 按段落切分
        let paragraphs: Vec<&str> = text.split("\n\n").collect();
        let mut all_lines = Vec::new();
        
        for paragraph in paragraphs {
            // 2. 检查段落缓存
            let para_key = ParagraphCacheKey {
                content_hash: Self::hash_str(paragraph),
                config_hash: config.hash(),
            };
            
            if let Some(cached_lines) = self.paragraph_cache.get(&para_key) {
                all_lines.extend_from_slice(cached_lines);
                continue;
            }
            
            // 3. 未命中缓存，执行排版
            let lines = self.layout_paragraph(paragraph, font, config);
            
            // 4. 存入段落缓存
            self.paragraph_cache.put(para_key, lines.clone());
            
            all_lines.extend(lines);
        }
        
        all_lines
    }
    
    /// 排版单个段落（核心逻辑）
    fn layout_paragraph(
        &mut self,
        paragraph: &str,
        font: &FontArc,
        config: &LayoutConfig,
    ) -> Vec<LayoutLine> {
        let mut lines = Vec::new();
        let mut current_line = String::new();
        let mut current_width = 0.0;
        let mut current_char_idx = 0;
        let line_start_char_idx = current_char_idx;
        
        // ✅ 性能优化：批量预取字形指标
        let metrics = self.glyph_cache.batch_measure(
            font,
            &config.font_name,
            config.font_size,
            paragraph,
        );
        
        for (ch, metric) in paragraph.chars().zip(metrics.iter()) {
            let char_width = metric.advance_width;
            
            // 检查是否需要换行
            if current_width + char_width > config.content_width && !current_line.is_empty() {
                // 保存当前行
                lines.push(LayoutLine {
                    start_char_idx: line_start_char_idx,
                    end_char_idx: current_char_idx,
                    width: current_width,
                    height: metric.height,
                    y: lines.len() as f32 * (metric.height + config.line_spacing),
                });
                
                current_line.clear();
                current_width = 0.0;
                line_start_char_idx = current_char_idx;
            }
            
            current_line.push(ch);
            current_width += char_width;
            current_char_idx += 1;
        }
        
        // 保存最后一行
        if !current_line.is_empty() {
            lines.push(LayoutLine {
                start_char_idx: line_start_char_idx,
                end_char_idx: current_char_idx,
                width: current_width,
                height: config.font_size * 1.2,  // 默认行高
                y: lines.len() as f32 * (config.font_size * 1.2 + config.line_spacing),
            });
        }
        
        lines
    }
    
    fn hash_str(s: &str) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        
        let mut hasher = DefaultHasher::new();
        s.hash(&mut hasher);
        hasher.finish()
    }
}
```

**预期性能提升**：

```
优化前：
  10,000 字排版耗时: 100ms
  - 字形测量: 80ms (每个字符重复测量)
  
优化后：
  10,000 字排版耗时: 15ms
  - 字形测量: 5ms (缓存命中率 98%)
  - 段落缓存: 相同段落排版耗时 <1ms
  
性能提升: 6.7倍
```

---

## 问题 3: EPUB 图文混排

**核心挑战**：
1. **图片高度未知**：排版时需要预加载图片获取尺寸
2. **图片异步加载**：网络图片可能很慢，不能阻塞排版
3. **占位符策略**：先用占位符排版，图片加载后重新计算
4. **表格处理**：HTML 表格需要转换为文本表格或截图

**解决方案**：

```rust
// rust/crates/layout_engine/src/epub/mixed_layout.rs

use image::GenericImageView;

/// EPUB 图文混排处理器
pub struct EpubMixedLayoutEngine {
    /// 图片尺寸缓存
    image_size_cache: HashMap<String, ImageSize>,
    
    /// 占位符配置
    placeholder_config: PlaceholderConfig,
}

#[derive(Debug, Clone)]
pub struct ImageSize {
    pub width: u32,
    pub height: u32,
    pub aspect_ratio: f32,
}

#[derive(Debug, Clone)]
pub struct PlaceholderConfig {
    /// 默认图片占位高度（像素）
    pub default_image_height: f32,
    
    /// 最大图片高度（防止超大图片撑爆页面）
    pub max_image_height: f32,
    
    /// 图片两侧留白（像素）
    pub image_margin: f32,
}

/// 混排内容元素
#[derive(Debug, Clone)]
pub enum MixedContentElement {
    Text(String),
    Image {
        src: String,
        alt: String,
        size: Option<ImageSize>,
    },
    Table {
        html: String,
        rendered_image: Option<Vec<u8>>,  // 表格截图
    },
}

impl EpubMixedLayoutEngine {
    /// 解析 EPUB HTML 为混排元素
    pub fn parse_html_to_mixed_elements(&self, html: &str) -> Result<Vec<MixedContentElement>> {
        use scraper::{Html, Selector};
        
        let document = Html::parse_document(html);
        let mut elements = Vec::new();
        
        // 1. 遍历 DOM 树
        let body_selector = Selector::parse("body").unwrap();
        if let Some(body) = document.select(&body_selector).next() {
            for node in body.descendants() {
                match node.value() {
                    scraper::Node::Text(text) => {
                        let content = text.text.trim();
                        if !content.is_empty() {
                            elements.push(MixedContentElement::Text(content.to_string()));
                        }
                    }
                    scraper::Node::Element(elem) => {
                        match elem.name() {
                            "img" => {
                                let src = elem.attr("src").unwrap_or("").to_string();
                                let alt = elem.attr("alt").unwrap_or("").to_string();
                                
                                elements.push(MixedContentElement::Image {
                                    src,
                                    alt,
                                    size: None,  // 稍后异步加载
                                });
                            }
                            "table" => {
                                // 表格转换为截图或文本
                                let table_html = elem.html();
                                elements.push(MixedContentElement::Table {
                                    html: table_html,
                                    rendered_image: None,
                                });
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
        }
        
        Ok(elements)
    }
    
    /// 异步预加载图片尺寸
    pub async fn preload_image_sizes(
        &mut self,
        elements: &[MixedContentElement],
        epub_parser: &mut EpubParser,
    ) -> Result<()> {
        for element in elements {
            if let MixedContentElement::Image { src, .. } = element {
                if !self.image_size_cache.contains_key(src) {
                    // 从 EPUB 中提取图片
                    if let Ok(image_data) = epub_parser.get_resource(src) {
                        if let Ok(img) = image::load_from_memory(&image_data) {
                            let (width, height) = img.dimensions();
                            self.image_size_cache.insert(
                                src.clone(),
                                ImageSize {
                                    width,
                                    height,
                                    aspect_ratio: width as f32 / height as f32,
                                },
                            );
                        }
                    }
                }
            }
        }
        
        Ok(())
    }
    
    /// 排版混排内容
    pub fn layout_mixed_content(
        &self,
        elements: &[MixedContentElement],
        config: &LayoutConfig,
    ) -> Vec<MixedLayoutLine> {
        let mut lines = Vec::new();
        let mut current_y = config.padding.top;
        
        for element in elements {
            match element {
                MixedContentElement::Text(text) => {
                    // 文本排版（复用现有逻辑）
                    let text_lines = self.layout_text_simple(text, config);
                    for line in text_lines {
                        lines.push(MixedLayoutLine::Text(TextLine {
                            content: line.text.clone(),
                            x: config.padding.left,
                            y: current_y,
                            width: line.width,
                            height: line.height,
                        }));
                        current_y += line.height + config.line_spacing;
                    }
                }
                
                MixedContentElement::Image { src, alt, size } => {
                    // 图片排版
                    let image_size = size.as_ref()
                        .or_else(|| self.image_size_cache.get(src))
                        .cloned();
                    
                    let display_height = if let Some(img_size) = image_size {
                        // 按宽度缩放
                        let display_width = config.content_width - self.placeholder_config.image_margin * 2.0;
                        let display_height = display_width / img_size.aspect_ratio;
                        
                        // 限制最大高度
                        display_height.min(self.placeholder_config.max_image_height)
                    } else {
                        // 使用占位高度
                        self.placeholder_config.default_image_height
                    };
                    
                    lines.push(MixedLayoutLine::Image(ImageLine {
                        src: src.clone(),
                        alt: alt.clone(),
                        x: config.padding.left + self.placeholder_config.image_margin,
                        y: current_y,
                        width: config.content_width - self.placeholder_config.image_margin * 2.0,
                        height: display_height,
                    }));
                    
                    current_y += display_height + config.paragraph_spacing;
                }
                
                MixedContentElement::Table { html, rendered_image } => {
                    // 表格作为图片处理
                    if let Some(_img_data) = rendered_image {
                        // 使用渲染好的表格图片
                        lines.push(MixedLayoutLine::Table(TableLine {
                            html: html.clone(),
                            x: config.padding.left,
                            y: current_y,
                            width: config.content_width,
                            height: 200.0,  // TODO: 动态计算
                        }));
                        current_y += 200.0 + config.paragraph_spacing;
                    }
                }
            }
        }
        
        lines
    }
}

/// 混排行类型
#[derive(Debug, Clone)]
pub enum MixedLayoutLine {
    Text(TextLine),
    Image(ImageLine),
    Table(TableLine),
}

#[derive(Debug, Clone)]
pub struct TextLine {
    pub content: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone)]
pub struct ImageLine {
    pub src: String,
    pub alt: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone)]
pub struct TableLine {
    pub html: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}
```

---

## 问题 4: 智能重新分段（处理特殊格式）

**核心挑战**：
1. **识别诗歌格式**：短行、固定缩进，不应该合并
2. **识别对话格式**：引号开头，可能有说话人前缀
3. **识别引用格式**：缩进、特殊标记
4. **修复扫描错误**：多余空行、错误分段

**解决方案**：

```rust
// rust/crates/reader_core/src/processing/smart_resegment.rs

/// 智能重新分段处理器
pub struct SmartResegmentProcessor {
    /// 特殊格式检测器
    format_detector: FormatDetector,
    
    /// 配置
    config: ResegmentConfig,
}

#[derive(Debug, Clone)]
pub struct ResegmentConfig {
    /// 是否保留诗歌格式
    pub preserve_poetry: bool,
    
    /// 是否保留对话格式
    pub preserve_dialogue: bool,
    
    /// 是否修复扫描错误
    pub fix_scan_errors: bool,
    
    /// 标准段落首行缩进（字符数）
    pub standard_indent: usize,
}

/// 格式检测器
pub struct FormatDetector;

impl FormatDetector {
    /// 检测段落类型
    pub fn detect_paragraph_type(&self, para: &str) -> ParagraphType {
        let trimmed = para.trim();
        
        // 1. 检测诗歌
        if self.is_poetry(para) {
            return ParagraphType::Poetry;
        }
        
        // 2. 检测对话
        if self.is_dialogue(trimmed) {
            return ParagraphType::Dialogue;
        }
        
        // 3. 检测引用
        if self.is_quote(para) {
            return ParagraphType::Quote;
        }
        
        // 4. 检测标题
        if self.is_heading(trimmed) {
            return ParagraphType::Heading;
        }
        
        ParagraphType::Normal
    }
    
    /// 检测是否为诗歌
    fn is_poetry(&self, para: &str) -> bool {
        let lines: Vec<&str> = para.lines().collect();
        
        if lines.len() < 2 {
            return false;
        }
        
        // 诗歌特征：
        // 1. 多行短句（平均长度 < 20 字符）
        // 2. 固定缩进
        // 3. 无句号结尾
        
        let avg_length = lines.iter()
            .map(|l| l.trim().chars().count())
            .sum::<usize>() / lines.len();
        
        let has_fixed_indent = lines.iter()
            .all(|l| l.starts_with("    ") || l.starts_with("　　"));
        
        let no_period_end = lines.iter()
            .all(|l| !l.trim().ends_with('。') && !l.trim().ends_with('.'));
        
        avg_length < 20 && has_fixed_indent && no_period_end
    }
    
    /// 检测是否为对话
    fn is_dialogue(&self, para: &str) -> bool {
        // 对话特征：
        // 1. 以引号开头
        // 2. 可能有说话人："张三说："
        
        para.starts_with('"') || 
        para.starts_with('"') ||
        para.starts_with(''') ||
        para.contains("说：") ||
        para.contains("道：") ||
        para.contains("问：")
    }
    
    /// 检测是否为引用
    fn is_quote(&self, para: &str) -> bool {
        // 引用特征：
        // 1. 特殊缩进（4+ 空格或全角空格）
        // 2. 特殊标记（>、※ 等）
        
        para.starts_with("    ") || 
        para.starts_with("　　　") ||
        para.starts_with(">") ||
        para.starts_with("※")
    }
    
    /// 检测是否为标题
    fn is_heading(&self, para: &str) -> bool {
        // 标题特征：
        // 1. 较短（< 30 字符）
        // 2. 无标点结尾
        // 3. 可能有序号
        
        let char_count = para.chars().count();
        let no_punctuation = !para.ends_with('。') && 
                             !para.ends_with('！') &&
                             !para.ends_with('？');
        
        char_count < 30 && no_punctuation
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParagraphType {
    Normal,
    Poetry,
    Dialogue,
    Quote,
    Heading,
}

impl SmartResegmentProcessor {
    /// 智能重新分段
    pub fn resegment(&self, content: &str) -> Result<String> {
        let mut result = String::new();
        let paragraphs: Vec<&str> = content.split("\n\n").collect();
        
        for para in paragraphs {
            let para_type = self.format_detector.detect_paragraph_type(para);
            
            match para_type {
                ParagraphType::Poetry => {
                    // 保留诗歌格式（不合并换行）
                    if self.config.preserve_poetry {
                        result.push_str(para);
                        result.push_str("\n\n");
                    }
                }
                
                ParagraphType::Dialogue => {
                    // 保留对话格式
                    if self.config.preserve_dialogue {
                        result.push_str(para);
                        result.push_str("\n\n");
                    }
                }
                
                ParagraphType::Normal => {
                    // 标准化正常段落
                    let normalized = self.normalize_paragraph(para);
                    result.push_str(&normalized);
                    result.push_str("\n\n");
                }
                
                _ => {
                    result.push_str(para);
                    result.push_str("\n\n");
                }
            }
        }
        
        Ok(result)
    }
    
    /// 标准化段落
    fn normalize_paragraph(&self, para: &str) -> String {
        let mut lines: Vec<&str> = para.lines().collect();
        
        // 1. 移除多余空行
        lines.retain(|l| !l.trim().is_empty());
        
        // 2. 合并软换行（扫描错误导致的）
        let mut merged = String::new();
        for (i, line) in lines.iter().enumerate() {
            let trimmed = line.trim();
            merged.push_str(trimmed);
            
            // 如果当前行不是以句号结尾，且不是最后一行，则不换行
            if !trimmed.ends_with('。') && 
               !trimmed.ends_with('！') &&
               !trimmed.ends_with('？') &&
               i < lines.len() - 1 {
                // 软换行，合并到下一行
                merged.push(' ');
            }
        }
        
        // 3. 标准化首行缩进
        let indent = "　　";  // 两个全角空格
        if !merged.starts_with(indent) {
            format!("{}{}", indent, merged)
        } else {
            merged
        }
    }
}
```

---

由于内容很长，我将继续创建第二部分文档。是否继续？

