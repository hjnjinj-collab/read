//! 【A22 退役标记（2026-09-04，P4 性能激活批次评估定案）】
//!
//! 本模块经评估**不接入生产分页管线**：
//! - 其「段落完整性分页」与 M9.2 行级分页职责重叠（TXT 路径本就有
//!   寡行/孤行保护 lib.rs 行级分页决策块；EPUB styled 路径的孤行/寡行
//!   保护已在 P4 于布局层断页判定处实现）
//! - 后处理重分组需重排 y 坐标与页边界，触及进度锚点连续性这一
//!   最难缠的不变量，回归风险与收益不成比例（用户确认锚点安全方案）
//! - `avoid_orphan`/`avoid_widow` 字段在本模块内从未被消费（空壳），
//!   真正的保护逻辑落在布局层
//!
//! 本模块保留作检测器思路参考与测试基线，**勿接入热路径**。

use crate::{Page, TextLine};

/// Smart pagination configuration.
#[derive(Debug, Clone)]
pub struct SmartPaginatorConfig {
    /// Minimum lines per page to avoid orphan lines
    pub min_lines_per_page: usize,
    /// Paragraph break threshold (0.0 - 1.0)
    /// When paragraph height / page height > threshold, break before paragraph
    pub paragraph_break_threshold: f32,
    /// Avoid orphan lines (first line of paragraph alone on previous page)
    pub avoid_orphan: bool,
    /// Avoid widow lines (last line of paragraph alone on new page)
    pub avoid_widow: bool,
}

impl Default for SmartPaginatorConfig {
    fn default() -> Self {
        Self {
            min_lines_per_page: 3,
            paragraph_break_threshold: 0.75,
            avoid_orphan: true,
            avoid_widow: true,
        }
    }
}

/// A paragraph detected in the text
#[derive(Debug, Clone)]
struct Paragraph {
    /// Line indices belonging to this paragraph
    line_indices: Vec<usize>,
    /// Total height of the paragraph
    height: f32,
}

/// Smart paginator with paragraph boundary detection
pub struct SmartPaginator {
    config: SmartPaginatorConfig,
}

impl SmartPaginator {
    /// Create a new smart paginator
    pub fn new(config: SmartPaginatorConfig) -> Self {
        Self { config }
    }

    /// Create a paginator with default config
    pub fn default_paginator() -> Self {
        Self::new(SmartPaginatorConfig::default())
    }

    /// Paginate lines into pages with smart paragraph handling
    pub fn paginate(
        &self,
        lines: &[TextLine],
        page_height: f32,
        chapter_index: usize,
    ) -> Vec<Page> {
        if lines.is_empty() {
            return vec![Page {
                page_index: 0,
                chapter_index,
                entries: Vec::new(),
                start_char_index: 0,
                end_char_index: 0,
            }];
        }

        // Detect paragraphs (consecutive lines with small gaps are one paragraph)
        let paragraphs = self.detect_paragraphs(lines);

        let mut pages = Vec::new();
        let mut current_lines: Vec<TextLine> = Vec::new();
        let mut current_y = 0.0;
        let mut page_start_char = 0;
        let mut current_char_index = 0;

        for para in &paragraphs {
            let para_height = para.height;

            // Check if paragraph should start on a new page
            let should_break_before = if current_lines.is_empty() {
                false
            } else {
                let page_fill_ratio = current_y / page_height;
                let has_min_lines = current_lines.len() >= self.config.min_lines_per_page;

                // Break if paragraph would overflow and we have enough lines
                if current_y + para_height > page_height && has_min_lines {
                    // Check paragraph完整性优先
                    if para_height / page_height > self.config.paragraph_break_threshold {
                        true // 段落太长，必须在新页开始
                    } else if page_fill_ratio >= self.config.paragraph_break_threshold {
                        true // 页面填充足够，在段落前分页
                    } else {
                        false
                    }
                } else {
                    false
                }
            };

            if should_break_before {
                // Create new page
                let end_char = current_char_index;
                pages.push(Page {
                    page_index: pages.len(),
                    chapter_index,
                    entries: current_lines.clone().into_iter().map(crate::PageEntry::Text).collect(),
                    start_char_index: page_start_char,
                    end_char_index: end_char,
                });

                current_lines.clear();
                current_y = 0.0;
                page_start_char = current_char_index;
            }

            // Add paragraph lines
            for &line_idx in &para.line_indices {
                let line = &lines[line_idx];
                let line_height = line.height;

                // 检查是否是章节开头（强制分页）
                if line.is_chapter_start && !current_lines.is_empty() {
                    // 章节开头必须另起一页
                    let end_char = current_char_index;
                    pages.push(Page {
                        page_index: pages.len(),
                        chapter_index,
                        entries: current_lines.clone().into_iter().map(crate::PageEntry::Text).collect(),
                        start_char_index: page_start_char,
                        end_char_index: end_char,
                    });

                    current_lines.clear();
                    current_y = 0.0;
                    page_start_char = current_char_index;
                }

                // Check if line would overflow
                if current_y + line_height > page_height && current_lines.len() >= self.config.min_lines_per_page {
                    // Create new page
                    let end_char = current_char_index;
                    pages.push(Page {
                        page_index: pages.len(),
                        chapter_index,
                        entries: current_lines.clone().into_iter().map(crate::PageEntry::Text).collect(),
                        start_char_index: page_start_char,
                        end_char_index: end_char,
                    });

                    current_lines.clear();
                    current_y = 0.0;
                    page_start_char = current_char_index;
                }

                current_lines.push(line.clone());
                current_y += line_height;
                current_char_index += line.text.len();
            }

            // Add paragraph spacing
            current_y += 12.0; // paragraph spacing
            current_char_index += 1; // newline
        }

        // Last page
        if !current_lines.is_empty() {
            pages.push(Page {
                page_index: pages.len(),
                chapter_index,
                entries: current_lines.into_iter().map(crate::PageEntry::Text).collect(),
                start_char_index: page_start_char,
                end_char_index: current_char_index,
            });
        }

        pages
    }

    /// Detect paragraphs from lines
    ///
    /// Lines with small vertical gaps are grouped into paragraphs
    fn detect_paragraphs(&self, lines: &[TextLine]) -> Vec<Paragraph> {
        if lines.is_empty() {
            return Vec::new();
        }

        let mut paragraphs = Vec::new();
        let mut current_para_lines = vec![0];
        let mut current_height = lines[0].height;

        for i in 1..lines.len() {
            let prev_line = &lines[i - 1];
            let curr_line = &lines[i];

            // Calculate gap between lines
            let gap = curr_line.y - (prev_line.y + prev_line.height);

            // If gap is small (less than line height), consider same paragraph
            let line_height = prev_line.height;
            if gap < line_height * 0.5 {
                // Same paragraph
                current_para_lines.push(i);
                current_height += curr_line.height;
            } else {
                // New paragraph
                paragraphs.push(Paragraph {
                    line_indices: current_para_lines,
                    height: current_height,
                });
                current_para_lines = vec![i];
                current_height = curr_line.height;
            }
        }

        // Add last paragraph
        paragraphs.push(Paragraph {
            line_indices: current_para_lines,
            height: current_height,
        });

        paragraphs
    }
}

impl Default for SmartPaginator {
    fn default() -> Self {
        Self::default_paginator()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PageEntry;

    fn create_test_lines(count: usize, line_height: f32, start_y: f32) -> Vec<TextLine> {
        (0..count)
            .map(|i| TextLine {
                text: format!("Line {}", i),
                x: 0.0,
                y: start_y + i as f32 * line_height,
                width: 100.0,
                height: line_height,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            })
            .collect()
    }

    #[test]
    fn test_smart_paginator_new() {
        let config = SmartPaginatorConfig::default();
        let paginator = SmartPaginator::new(config);
        assert_eq!(paginator.config.min_lines_per_page, 3);
        assert_eq!(paginator.config.paragraph_break_threshold, 0.75);
    }

    #[test]
    fn test_smart_paginator_default() {
        let paginator = SmartPaginator::default_paginator();
        assert!(paginator.config.avoid_orphan);
        assert!(paginator.config.avoid_widow);
    }

    /// 测试辅助：取页内文本行
    fn text_lines(p: &Page) -> Vec<&TextLine> {
        p.entries
            .iter()
            .filter_map(|e| match e {
                PageEntry::Text(l) => Some(l),
                PageEntry::Image(_) | PageEntry::Rect(_) => None,
            })
            .collect()
    }

    #[test]
    fn test_paginate_empty() {
        let paginator = SmartPaginator::default_paginator();
        let pages = paginator.paginate(&[], 100.0, 0);
        assert_eq!(pages.len(), 1);
        assert!(text_lines(&pages[0]).is_empty());
    }

    #[test]
    fn test_paginate_single_page() {
        let paginator = SmartPaginator::default_paginator();
        let lines = create_test_lines(5, 20.0, 0.0);
        let pages = paginator.paginate(&lines, 200.0, 0);

        assert_eq!(pages.len(), 1);
        assert_eq!(text_lines(&pages[0]).len(), 5);
    }

    #[test]
    fn test_paginate_multiple_pages() {
        let paginator = SmartPaginator::default_paginator();
        let lines = create_test_lines(20, 20.0, 0.0);
        let pages = paginator.paginate(&lines, 100.0, 0);

        // 20 lines * 20px = 400px, page height 100px => 4 pages
        assert!(pages.len() >= 3);
    }

    #[test]
    fn test_detect_paragraphs() {
        let paginator = SmartPaginator::default_paginator();

        // Create lines with gaps
        let mut lines = Vec::new();

        // Paragraph 1: lines 0-2 (small gaps)
        for i in 0..3 {
            lines.push(TextLine {
                text: format!("P1 Line {}", i),
                x: 0.0,
                y: i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        // Gap between paragraphs
        lines.push(TextLine {
            text: "P2 Line 0".to_string(),
            x: 0.0,
            y: 100.0, // Large gap
            width: 100.0,
            height: 20.0,
            is_chapter_start: false,
            color: None,
            font_scale: None,
            segments: Vec::new(),
            is_comment: false,
            letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
        });

        // Paragraph 2: lines 3-4 (small gaps)
        for i in 1..3 {
            lines.push(TextLine {
                text: format!("P2 Line {}", i),
                x: 0.0,
                y: 100.0 + i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        let paragraphs = paginator.detect_paragraphs(&lines);
        assert_eq!(paragraphs.len(), 2); // Two paragraphs
        assert_eq!(paragraphs[0].line_indices.len(), 3); // First paragraph has 3 lines
        assert_eq!(paragraphs[1].line_indices.len(), 3); // Second paragraph has 3 lines
    }

    #[test]
    fn test_paragraph_break_threshold() {
        let config = SmartPaginatorConfig {
            min_lines_per_page: 2,
            paragraph_break_threshold: 0.5,
            avoid_orphan: true,
            avoid_widow: true,
        };
        let paginator = SmartPaginator::new(config);

        // Create lines that fill most of the page
        let mut lines = Vec::new();
        for i in 0..5 {
            lines.push(TextLine {
                text: format!("Line {}", i),
                x: 0.0,
                y: i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        // Add a tall paragraph
        for i in 5..10 {
            lines.push(TextLine {
                text: format!("Tall Line {}", i),
                x: 0.0,
                y: 100.0 + (i - 5) as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        let pages = paginator.paginate(&lines, 150.0, 0);
        // Should have multiple pages due to threshold
        assert!(pages.len() >= 2);
    }

    #[test]
    fn test_chapter_start_forces_new_page() {
        let paginator = SmartPaginator::default_paginator();

        // 模拟：上一章末尾几行 + 章节开头行（页面还有大量空间）
        let mut lines = Vec::new();
        for i in 0..3 {
            lines.push(TextLine {
                text: format!("Prev chapter line {}", i),
                x: 0.0,
                y: i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }
        // 章节开头行，页面远未填满
        lines.push(TextLine {
            text: "New chapter first line".to_string(),
            x: 0.0,
            y: 60.0,
            width: 100.0,
            height: 20.0,
            is_chapter_start: true,
            color: None,
            font_scale: None,
            segments: Vec::new(),
            is_comment: false,
            letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
        });
        for i in 1..3 {
            lines.push(TextLine {
                text: format!("New chapter line {}", i),
                x: 0.0,
                y: 60.0 + i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        let pages = paginator.paginate(&lines, 500.0, 0);

        // 页面高度足够容纳所有行，但章节开头必须强制分页 => 至少2页
        assert!(pages.len() >= 2, "章节开头应强制另起一页");
        // 第一页只包含上一章的3行
        assert_eq!(text_lines(&pages[0]).len(), 3);
        assert_eq!(text_lines(&pages[0])[0].text, "Prev chapter line 0");
        // 第二页以章节开头行开始
        assert_eq!(text_lines(&pages[1])[0].is_chapter_start, true);
        assert_eq!(text_lines(&pages[1])[0].text, "New chapter first line");
    }

    #[test]
    fn test_chapter_start_at_page_top_no_empty_page() {
        let paginator = SmartPaginator::default_paginator();

        // 章节开头是第一行（当前页为空），不应产生空页
        let mut lines = Vec::new();
        lines.push(TextLine {
            text: "Chapter first line".to_string(),
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 20.0,
            is_chapter_start: true,
            color: None,
            font_scale: None,
            segments: Vec::new(),
            is_comment: false,
            letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
        });
        for i in 1..5 {
            lines.push(TextLine {
                text: format!("Line {}", i),
                x: 0.0,
                y: i as f32 * 20.0,
                width: 100.0,
                height: 20.0,
                is_chapter_start: false,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_comment: false,
                letter_gap: 0.0,
                start_char_index: 0,
                end_char_index: 0,
            });
        }

        let pages = paginator.paginate(&lines, 200.0, 0);

        // 单页即可容纳，且不应有空页
        assert_eq!(pages.len(), 1);
        assert_eq!(text_lines(&pages[0]).len(), 5);
        assert_eq!(text_lines(&pages[0])[0].is_chapter_start, true);
    }
}
