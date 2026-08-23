# 分页精度与配置迁移方案

> **本文档是《核心排版引擎深度技术设计》的续篇**  
> 聚焦：分页精度保证、配置变化后的位置恢复、段落完整性算法

---

## 🎯 问题 5: 配置变化后分页失效

### 核心挑战

用户调整字号、行距、字体后，之前的分页位置完全失效：

```
场景：
用户在第 5 章第 12 页阅读，字号 18px
↓ 用户调整字号为 20px
问题：
  - 第 12 页的内容边界变化
  - 可能现在是第 10 页或第 14 页
  - 需要重新定位到"相同的阅读位置"
```

### 解决方案：基于字符偏移的位置恢复

**核心思想**：不依赖页码，而是记录字符偏移量

```rust
// rust/crates/reader_core/src/session/position_tracker.rs

/// 阅读位置追踪器
pub struct ReadPositionTracker {
    /// 当前书籍 ID
    book_id: String,
    
    /// 当前章节索引
    chapter_index: usize,
    
    /// 当前字符偏移（在章节内的字符位置，不是字节位置）
    char_offset: usize,
    
    /// 当前页面索引（配置特定）
    page_index: usize,
    
    /// 当前配置哈希（用于检测配置变化）
    config_hash: u64,
}

impl ReadPositionTracker {
    /// 保存阅读位置
    pub fn save_position(&mut self, position: ReadPosition) -> Result<()> {
        self.chapter_index = position.chapter_index;
        self.char_offset = position.char_offset;
        self.page_index = position.page_index;
        self.config_hash = position.config_hash;
        
        // 持久化到数据库
        // TODO: 保存到 SQLite
        
        Ok(())
    }
    
    /// 恢复阅读位置（配置可能已变化）
    pub async fn restore_position(
        &self,
        current_config_hash: u64,
        chapter_pages: &ChapterPages,
    ) -> RestoredPosition {
        if current_config_hash == self.config_hash {
            // 配置未变化，直接使用页码
            return RestoredPosition {
                page_index: self.page_index,
                char_offset: self.char_offset,
                scroll_offset: 0.0,
            };
        }
        
        // 配置已变化，需要根据字符偏移重新定位
        self.find_page_by_char_offset(chapter_pages, self.char_offset)
    }
    
    /// 根据字符偏移查找页面
    fn find_page_by_char_offset(
        &self,
        chapter_pages: &ChapterPages,
        target_char_offset: usize,
    ) -> RestoredPosition {
        for (page_idx, page) in chapter_pages.pages.iter().enumerate() {
            if target_char_offset >= page.start_char_idx && 
               target_char_offset < page.end_char_idx {
                // 找到包含目标偏移的页面
                
                // 计算页内滚动偏移（对于滚动模式）
                let page_char_count = page.end_char_idx - page.start_char_idx;
                let offset_in_page = target_char_offset - page.start_char_idx;
                let scroll_ratio = offset_in_page as f32 / page_char_count as f32;
                
                return RestoredPosition {
                    page_index: page_idx,
                    char_offset: target_char_offset,
                    scroll_offset: scroll_ratio,
                };
            }
        }
        
        // 未找到（可能在章节末尾），返回最后一页
        RestoredPosition {
            page_index: chapter_pages.pages.len().saturating_sub(1),
            char_offset: target_char_offset,
            scroll_offset: 0.0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ReadPosition {
    pub chapter_index: usize,
    pub char_offset: usize,
    pub page_index: usize,
    pub config_hash: u64,
}

#[derive(Debug, Clone)]
pub struct RestoredPosition {
    pub page_index: usize,
    pub char_offset: usize,
    pub scroll_offset: f32,  // 0.0 - 1.0，用于滚动模式
}
```

### 配置哈希计算

```rust
// rust/crates/layout_engine/src/config.rs

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

#[derive(Debug, Clone)]
pub struct LayoutConfig {
    pub width: f32,
    pub height: f32,
    pub font_size: f32,
    pub font_name: String,
    pub line_height_multiplier: f32,
    pub padding: EdgeInsets,
    pub letter_spacing: f32,
    pub paragraph_spacing: f32,
}

impl LayoutConfig {
    /// 计算配置哈希（用于检测配置变化）
    pub fn hash(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        
        // 只哈希影响分页的关键配置
        self.width.to_bits().hash(&mut hasher);
        self.height.to_bits().hash(&mut hasher);
        self.font_size.to_bits().hash(&mut hasher);
        self.font_name.hash(&mut hasher);
        self.line_height_multiplier.to_bits().hash(&mut hasher);
        self.padding.left.to_bits().hash(&mut hasher);
        self.padding.top.to_bits().hash(&mut hasher);
        self.padding.right.to_bits().hash(&mut hasher);
        self.padding.bottom.to_bits().hash(&mut hasher);
        self.letter_spacing.to_bits().hash(&mut hasher);
        self.paragraph_spacing.to_bits().hash(&mut hasher);
        
        hasher.finish()
    }
}
```

### 实际使用场景

```rust
// 用户打开书籍
let session = ReadSession::open_book(book_path, page_config).await?;

// 用户翻到第 5 章第 12 页
session.jump_to_chapter(4, 11).await?;  // chapter_index=4, page_index=11

// 保存位置
let position = ReadPosition {
    chapter_index: 4,
    char_offset: 15234,  // 当前页面起始字符偏移
    page_index: 11,
    config_hash: page_config.hash(),
};
position_tracker.save_position(position)?;

// --- 用户退出应用 ---

// --- 用户重新打开，并修改了字号 ---
let new_page_config = PageConfig {
    font_size: 20.0,  // 从 18.0 改为 20.0
    ..page_config
};

// 恢复会话
let restored = ReadSession::restore_session(
    book_path,
    saved_progress,
    new_page_config,
).await?;

// 自动定位到正确的页面（基于字符偏移）
// 可能从第 11 页变为第 9 页，但阅读位置不变
```

---

## 🎯 问题 6: 段落完整性与智能分页

### 核心挑战

**避免出现"孤行"和"寡行"问题**：

```
❌ 不好的分页：
┌──────────────────────┐
│ ...段落结尾。        │
│                      │
│ 　　这是新段落的第一│  ← 孤行（只有一行）
└──────────────────────┘
        [翻页]
┌──────────────────────┐
│ 行，后面还有很多内容│
│ 巴拉巴拉...          │
└──────────────────────┘

✅ 好的分页：
┌──────────────────────┐
│ ...段落结尾。        │
│                      │
└──────────────────────┘
        [翻页]
┌──────────────────────┐
│ 　　这是新段落的第一│  ← 完整段落开始
│ 行，后面还有很多内容│
│ 巴拉巴拉...          │
└──────────────────────┘
```

### 解决方案：智能分页算法

```rust
// rust/crates/layout_engine/src/pagination/smart_paginator.rs

/// 智能分页器
pub struct SmartPaginator {
    config: SmartPaginationConfig,
}

#[derive(Debug, Clone)]
pub struct SmartPaginationConfig {
    /// 页面高度
    pub page_height: f32,
    
    /// 最小行数保护（每页至少 N 行）
    pub min_lines_per_page: usize,
    
    /// 段落完整性阈值（页面填充率超过此值时优先在段落边界分页）
    pub paragraph_break_threshold: f32,
    
    /// 是否避免孤行（段落最后一行单独在新页）
    pub avoid_orphan: bool,
    
    /// 是否避免寡行（段落第一行单独在上一页末尾）
    pub avoid_widow: bool,
}

impl Default for SmartPaginationConfig {
    fn default() -> Self {
        Self {
            page_height: 800.0,
            min_lines_per_page: 3,
            paragraph_break_threshold: 0.75,  // 75% 填充率
            avoid_orphan: true,
            avoid_widow: true,
        }
    }
}

/// 段落信息
#[derive(Debug, Clone)]
pub struct ParagraphLayout {
    /// 段落起始行索引
    pub start_line: usize,
    
    /// 段落结束行索引（不包含）
    pub end_line: usize,
    
    /// 段落总高度
    pub total_height: f32,
    
    /// 段落类型
    pub para_type: ParagraphType,
}

impl SmartPaginator {
    /// 智能分页（考虑段落完整性）
    pub fn paginate_with_paragraph_awareness(
        &self,
        lines: &[LayoutLine],
        paragraphs: &[ParagraphLayout],
    ) -> Vec<PageBoundary> {
        let mut pages = Vec::new();
        let mut current_page_start_line = 0;
        let mut current_height = 0.0;
        
        let mut line_idx = 0;
        
        for paragraph in paragraphs {
            let para_lines = &lines[paragraph.start_line..paragraph.end_line];
            let para_height = paragraph.total_height;
            
            // 检查段落是否会溢出当前页面
            let would_overflow = current_height + para_height > self.config.page_height;
            
            if would_overflow {
                // 计算当前页面填充率
                let fill_ratio = current_height / self.config.page_height;
                
                // 检查当前页面是否满足最小行数
                let current_line_count = line_idx - current_page_start_line;
                let has_min_lines = current_line_count >= self.config.min_lines_per_page;
                
                // 决策：是否在段落前分页
                if has_min_lines && fill_ratio >= self.config.paragraph_break_threshold {
                    // ✅ 策略 1：段落完整性优先
                    // 在段落前分页，保持段落完整
                    
                    pages.push(PageBoundary {
                        start_line: current_page_start_line,
                        end_line: line_idx,
                        start_char_idx: lines[current_page_start_line].start_char_idx,
                        end_char_idx: lines[line_idx - 1].end_char_idx,
                    });
                    
                    current_page_start_line = line_idx;
                    current_height = 0.0;
                }
            }
            
            // 逐行添加到当前页面
            for line in para_lines {
                if current_height + line.height > self.config.page_height {
                    // 页面已满
                    
                    let current_line_count = line_idx - current_page_start_line;
                    
                    if current_line_count >= self.config.min_lines_per_page {
                        // 满足最小行数，可以分页
                        
                        // ✅ 策略 2：避免寡行（widow）
                        if self.config.avoid_widow {
                            // 检查是否是段落的第一行
                            if line_idx == paragraph.start_line {
                                // 这是段落第一行，不应该单独留在上一页
                                // 将上一行也移到新页
                                if current_page_start_line < line_idx - 1 {
                                    pages.push(PageBoundary {
                                        start_line: current_page_start_line,
                                        end_line: line_idx - 1,
                                        start_char_idx: lines[current_page_start_line].start_char_idx,
                                        end_char_idx: lines[line_idx - 2].end_char_idx,
                                    });
                                    
                                    current_page_start_line = line_idx - 1;
                                    current_height = lines[line_idx - 1].height;
                                    continue;
                                }
                            }
                        }
                        
                        // ✅ 策略 3：避免孤行（orphan）
                        if self.config.avoid_orphan {
                            // 检查是否是段落的最后一行
                            if line_idx == paragraph.end_line - 1 {
                                // 这是段落最后一行，尽量不让它单独在新页
                                // 将倒数两行一起移到新页
                                if current_page_start_line < line_idx - 2 {
                                    pages.push(PageBoundary {
                                        start_line: current_page_start_line,
                                        end_line: line_idx - 1,
                                        start_char_idx: lines[current_page_start_line].start_char_idx,
                                        end_char_idx: lines[line_idx - 2].end_char_idx,
                                    });
                                    
                                    current_page_start_line = line_idx - 1;
                                    current_height = lines[line_idx - 1].height + line.height;
                                    line_idx += 1;
                                    continue;
                                }
                            }
                        }
                        
                        // 正常分页
                        pages.push(PageBoundary {
                            start_line: current_page_start_line,
                            end_line: line_idx,
                            start_char_idx: lines[current_page_start_line].start_char_idx,
                            end_char_idx: lines[line_idx - 1].end_char_idx,
                        });
                        
                        current_page_start_line = line_idx;
                        current_height = 0.0;
                    } else {
                        // 不满足最小行数，强制添加当前行
                        // （避免页面太空）
                    }
                }
                
                current_height += line.height;
                line_idx += 1;
            }
        }
        
        // 保存最后一页
        if current_page_start_line < lines.len() {
            pages.push(PageBoundary {
                start_line: current_page_start_line,
                end_line: lines.len(),
                start_char_idx: lines[current_page_start_line].start_char_idx,
                end_char_idx: lines.last().unwrap().end_char_idx,
            });
        }
        
        pages
    }
    
    /// 识别段落边界（从行列表中）
    pub fn detect_paragraphs(lines: &[LayoutLine]) -> Vec<ParagraphLayout> {
        let mut paragraphs = Vec::new();
        let mut para_start = 0;
        let mut para_height = 0.0;
        
        for (i, line) in lines.iter().enumerate() {
            para_height += line.height;
            
            // 检测段落结束（下一行是新段落开始）
            if i + 1 < lines.len() {
                let next_line = &lines[i + 1];
                
                // 段落结束条件：
                // 1. 下一行是新段落（有缩进）
                // 2. 或者当前行后有较大间距
                
                let is_para_end = next_line.text.starts_with("　　") ||  // 全角缩进
                                  next_line.text.starts_with("  ") ||   // 半角缩进
                                  (next_line.y - (line.y + line.height)) > line.height * 0.5;  // 较大间距
                
                if is_para_end {
                    paragraphs.push(ParagraphLayout {
                        start_line: para_start,
                        end_line: i + 1,
                        total_height: para_height,
                        para_type: ParagraphType::Normal,
                    });
                    
                    para_start = i + 1;
                    para_height = 0.0;
                }
            }
        }
        
        // 最后一个段落
        if para_start < lines.len() {
            paragraphs.push(ParagraphLayout {
                start_line: para_start,
                end_line: lines.len(),
                total_height: para_height,
                para_type: ParagraphType::Normal,
            });
        }
        
        paragraphs
    }
}
```

### 分页效果对比

```rust
// 普通分页（不考虑段落完整性）
let simple_paginator = SimplePaginator::new(page_height);
let pages_simple = simple_paginator.paginate(lines);
// 结果：可能出现孤行、寡行

// 智能分页（考虑段落完整性）
let smart_paginator = SmartPaginator::new(SmartPaginationConfig::default());
let paragraphs = SmartPaginator::detect_paragraphs(&lines);
let pages_smart = smart_paginator.paginate_with_paragraph_awareness(&lines, &paragraphs);
// 结果：段落完整，阅读体验更好
```

---

## 🚀 性能优化：增量重排版

### 问题

用户调整字号后，整本书需要重新排版，非常耗时。

### 解决方案：智能增量重排版

```rust
// rust/crates/layout_engine/src/incremental_layout.rs

/// 增量重排版管理器
pub struct IncrementalLayoutManager {
    /// 上一次配置
    last_config: Option<LayoutConfig>,
    
    /// 章节排版结果缓存
    chapter_layouts: HashMap<usize, ChapterLayoutCache>,
}

#[derive(Debug, Clone)]
pub struct ChapterLayoutCache {
    pub lines: Vec<LayoutLine>,
    pub pages: Vec<PageBoundary>,
    pub config_hash: u64,
    pub created_at: Instant,
}

impl IncrementalLayoutManager {
    /// 智能重排版（只重排变化部分）
    pub async fn relayout_on_config_change(
        &mut self,
        old_config: &LayoutConfig,
        new_config: &LayoutConfig,
        current_chapter: usize,
    ) -> RelayoutStrategy {
        // 分析配置变化
        let change_type = self.analyze_config_change(old_config, new_config);
        
        match change_type {
            ConfigChangeType::OnlyPagination => {
                // 只影响分页，不影响排版
                // 策略：只重新分页，不重新排版
                RelayoutStrategy::RepaginateOnly
            }
            
            ConfigChangeType::MinorLayout => {
                // 影响排版，但影响较小（如行距变化）
                // 策略：重排当前章 + 前后各 1 章，其他章懒加载
                RelayoutStrategy::RelayoutAdjacent {
                    center: current_chapter,
                    radius: 1,
                }
            }
            
            ConfigChangeType::MajorLayout => {
                // 影响排版较大（如字号、字体变化）
                // 策略：清空所有缓存，按需重排
                RelayoutStrategy::ClearAllAndRelayout
            }
        }
    }
    
    /// 分析配置变化类型
    fn analyze_config_change(
        &self,
        old: &LayoutConfig,
        new: &LayoutConfig,
    ) -> ConfigChangeType {
        // 只有页面尺寸变化 → 只需重新分页
        if old.font_size == new.font_size &&
           old.font_name == new.font_name &&
           old.line_height_multiplier == new.line_height_multiplier &&
           old.letter_spacing == new.letter_spacing {
            return ConfigChangeType::OnlyPagination;
        }
        
        // 字号或字体变化 → 需要重新排版（影响大）
        if old.font_size != new.font_size || old.font_name != new.font_name {
            return ConfigChangeType::MajorLayout;
        }
        
        // 行距、字间距变化 → 需要重新排版（影响小）
        ConfigChangeType::MinorLayout
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigChangeType {
    OnlyPagination,   // 只影响分页
    MinorLayout,      // 轻微影响排版
    MajorLayout,      // 严重影响排版
}

#[derive(Debug, Clone)]
pub enum RelayoutStrategy {
    /// 只重新分页，复用排版结果
    RepaginateOnly,
    
    /// 重排相邻章节
    RelayoutAdjacent { center: usize, radius: usize },
    
    /// 清空所有缓存，重新排版
    ClearAllAndRelayout,
}
```

---

## 📊 性能测试与基准

### 测试场景设计

```rust
// tests/performance_benchmark.rs

#[tokio::test]
async fn benchmark_layout_performance() {
    // 测试数据：10,000 字章节
    let test_content = generate_chinese_text(10000);
    
    // 配置
    let config = LayoutConfig {
        width: 800.0,
        height: 1200.0,
        font_size: 18.0,
        font_name: "SimSun".to_string(),
        line_height_multiplier: 1.5,
        padding: EdgeInsets::all(20.0),
        letter_spacing: 0.0,
        paragraph_spacing: 10.0,
    };
    
    // 性能测试
    let mut layout_engine = EnhancedLayoutEngine::new(config.clone());
    
    // 1. 冷启动（无缓存）
    let start = Instant::now();
    let lines_cold = layout_engine.layout_text(&test_content, 0).await.unwrap();
    let cold_duration = start.elapsed();
    
    // 2. 热启动（有缓存）
    let start = Instant::now();
    let lines_hot = layout_engine.layout_text(&test_content, 0).await.unwrap();
    let hot_duration = start.elapsed();
    
    // 3. 分页
    let start = Instant::now();
    let paginator = SmartPaginator::new(SmartPaginationConfig::default());
    let paragraphs = SmartPaginator::detect_paragraphs(&lines_hot);
    let pages = paginator.paginate_with_paragraph_awareness(&lines_hot, &paragraphs);
    let pagination_duration = start.elapsed();
    
    println!("=== 性能测试结果 (10,000 字) ===");
    println!("排版（冷启动）: {:?}", cold_duration);
    println!("排版（热启动）: {:?}", hot_duration);
    println!("分页: {:?}", pagination_duration);
    println!("总页数: {}", pages.len());
    
    // 断言性能目标
    assert!(cold_duration < Duration::from_millis(100), "冷启动应 <100ms");
    assert!(hot_duration < Duration::from_millis(10), "热启动应 <10ms");
    assert!(pagination_duration < Duration::from_millis(5), "分页应 <5ms");
}

#[test]
fn benchmark_char_boundary_performance() {
    let test_content = generate_chinese_text(100000);  // 100k 字
    
    let start = Instant::now();
    let handler = TextBoundaryHandler::new(test_content);
    let init_duration = start.elapsed();
    
    println!("=== 字符边界处理器性能 (100k 字) ===");
    println!("初始化: {:?}", init_duration);
    println!("字符数: {}", handler.char_count());
    println!("字形簇数: {}", handler.grapheme_count());
    
    // 测试随机访问性能
    let start = Instant::now();
    for _ in 0..1000 {
        let random_char = rand::random::<usize>() % handler.char_count();
        let _ = handler.get_char_range(random_char, random_char + 10);
    }
    let access_duration = start.elapsed();
    
    println!("1000 次随机访问: {:?}", access_duration);
    
    assert!(init_duration < Duration::from_millis(50), "初始化应 <50ms");
    assert!(access_duration < Duration::from_millis(10), "随机访问应 <10ms");
}
```

### 预期性能目标

| 场景 | 数据规模 | 目标性能 | 优化策略 |
|------|----------|----------|---------|
| **字符边界初始化** | 100k 字 | <50ms | 一次性构建索引 |
| **字形测量（冷启动）** | 10k 字 | <100ms | 批量测量 + 预热常用字 |
| **字形测量（热启动）** | 10k 字 | <10ms | 缓存命中率 98%+ |
| **文本排版** | 10k 字 | <50ms | 段落缓存 + 增量排版 |
| **智能分页** | 50 页 | <5ms | 段落边界预计算 |
| **配置变化重排** | 当前章 | <100ms | 增量重排 + 懒加载 |
| **图片预加载** | 10 张 | <200ms | 异步并发加载 |

---

## 🎯 实施优先级

### P0: 字符边界安全（2 天）
- [ ] 实现 `TextBoundaryHandler`
- [ ] 修复所有字节切片为字符索引
- [ ] 单元测试（UTF-8、Emoji、全角字符）

### P1: 字形测量优化（2 天）
- [ ] 实现 `AdvancedGlyphCache`
- [ ] 预热常用汉字（3500 字）
- [ ] 批量测量接口
- [ ] 性能基准测试

### P2: 智能分页（3 天）
- [ ] 实现 `SmartPaginator`
- [ ] 段落边界检测
- [ ] 孤行/寡行避免算法
- [ ] 分页效果测试

### P3: 配置迁移（2 天）
- [ ] 实现 `ReadPositionTracker`
- [ ] 配置哈希计算
- [ ] 位置恢复算法
- [ ] 端到端测试

### P4: EPUB 图文混排（3 天）
- [ ] 实现 `EpubMixedLayoutEngine`
- [ ] HTML 解析和清洗
- [ ] 图片异步预加载
- [ ] 占位符策略

### P5: 智能分段（2 天）
- [ ] 实现 `SmartResegmentProcessor`
- [ ] 格式检测（诗歌、对话、引用）
- [ ] 扫描错误修复
- [ ] 分段效果测试

**总工期**：14 天

---

## 🎓 总结

本设计文档深入解决了阅读器最核心的技术难题：

✅ **字符边界精度**：基于字符索引而非字节偏移，支持 UTF-8、Emoji、字形簇  
✅ **字形测量性能**：多级缓存 + 预热，性能提升 6-10 倍  
✅ **智能分页算法**：段落完整性、孤行寡行避免、最小行数保护  
✅ **配置变化恢复**：基于字符偏移的位置追踪，配置变化不丢失阅读位置  
✅ **EPUB 图文混排**：异步图片预加载、占位符策略、HTML 清洗  
✅ **智能重新分段**：格式检测（诗歌/对话/引用）、扫描错误修复

这些才是真正影响用户体验和性能的核心技术细节！

---

**文档编写日期**：2025-01-XX  
**文档版本**：v1.0  
**作者**：Kiro AI Agent
