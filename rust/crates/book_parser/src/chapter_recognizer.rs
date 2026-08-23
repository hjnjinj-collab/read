use std::collections::{HashMap, HashSet};

use regex::Regex;

/// Pattern category for chapter recognition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PatternCategory {
    /// Standard format: 第X章
    Standard,
    /// English format: Chapter X
    English,
    /// Numeric: 001, 1.
    Numeric,
    /// Volume/Part: 卷、部、篇
    Volume,
    /// Special format
    Special,
}

/// A chapter recognition pattern.
#[derive(Debug, Clone)]
pub struct ChapterPattern {
    pub name: &'static str,
    pub regex: Regex,
    pub priority: i32,
    pub category: PatternCategory,
    pub requires_context: bool,
}

/// Line context for辅助判断.
#[derive(Debug, Clone, Default)]
pub struct LineContext {
    pub line_number: usize,
    pub total_lines: usize,
    pub has_blank_before: bool,
    pub has_blank_after: bool,
    pub previous_chapter_number: Option<usize>,
    pub has_previous_chapter: bool,
    pub is_near_start: bool,
}

/// Chapter match result.
#[derive(Debug, Clone)]
pub struct ChapterMatch {
    pub title: String,
    pub priority: i32,
    pub pattern_name: &'static str,
    pub category: PatternCategory,
    pub requires_context_validation: bool,
    pub confidence: f32,
}

/// Raw chapter before hierarchy building.
#[derive(Debug, Clone)]
pub struct RawChapter {
    pub title: String,
    pub category: PatternCategory,
    pub start_pos: usize,
    pub end_pos: usize,
}

/// Chapter info after hierarchy building.
#[derive(Debug, Clone)]
pub struct RecognizedChapter {
    pub index: usize,
    pub title: String,
    pub start_offset: Option<usize>,
    pub end_offset: Option<usize>,
    pub estimated_words: usize,
}

/// Context analyzer for tracking chapter intervals.
pub struct ContextAnalyzer {
    chapter_intervals: Vec<usize>,
    last_chapter_line: Option<usize>,
}

impl ContextAnalyzer {
    pub fn new() -> Self {
        Self {
            chapter_intervals: Vec::new(),
            last_chapter_line: None,
        }
    }

    pub fn record_chapter(&mut self, line_number: usize) {
        if let Some(last) = self.last_chapter_line {
            self.chapter_intervals.push(line_number - last);
        }
        self.last_chapter_line = Some(line_number);
    }

    /// Validate if a line is likely a real chapter title based on context.
    pub fn validate(&self, line: &str, context: &LineContext) -> bool {
        // Must have blank line before or after
        if !context.has_blank_before && !context.has_blank_after {
            return false;
        }
        // Length check (allow short titles like 序章, 楔子)
        let len = line.chars().count();
        if len < 2 || len > 100 {
            return false;
        }
        // First line is likely a chapter
        if context.line_number == 0 {
            return true;
        }
        true
    }
}

/// Enhanced chapter recognizer with multi-level patterns and context analysis.
pub struct ChapterRecognizer {
    primary_patterns: Vec<ChapterPattern>,
    secondary_patterns: Vec<ChapterPattern>,
    blacklist: HashSet<String>,
    context_analyzer: ContextAnalyzer,
}

impl ChapterRecognizer {
    pub fn new() -> Self {
        let primary_patterns = vec![
            // Priority 10: Standard Chinese chapter formats
            ChapterPattern {
                name: "标准章节（数字）",
                regex: Regex::new(r"^第\s*[0-9]{1,4}\s*[章回节集卷篇]").unwrap(),
                priority: 10,
                category: PatternCategory::Standard,
                requires_context: false,
            },
            ChapterPattern {
                name: "标准章节（中文数字）",
                regex: Regex::new(r"^第\s*[一二三四五六七八九十百千零壹贰叁肆伍陆柒捌玖拾佰仟]+\s*[章回节集卷篇]").unwrap(),
                priority: 10,
                category: PatternCategory::Standard,
                requires_context: false,
            },
            // Priority 9: English formats
            ChapterPattern {
                name: "英文章节",
                regex: Regex::new(r"^Chapter\s+\d+").unwrap(),
                priority: 9,
                category: PatternCategory::English,
                requires_context: false,
            },
            ChapterPattern {
                name: "英文章节（罗马数字）",
                regex: Regex::new(r"^Chapter\s+[IVX]+").unwrap(),
                priority: 9,
                category: PatternCategory::English,
                requires_context: false,
            },
            // Priority 8: Volume/Part/Book
            ChapterPattern {
                name: "卷/部/篇（数字）",
                regex: Regex::new(r"^[卷部篇]\s*[0-9一二三四五六七八九十百千]+").unwrap(),
                priority: 8,
                category: PatternCategory::Volume,
                requires_context: false,
            },
            ChapterPattern {
                name: "第X部/卷/篇",
                regex: Regex::new(r"^第\s*[0-9一二三四五六七八九十百千零]+\s*[部卷篇]").unwrap(),
                priority: 8,
                category: PatternCategory::Volume,
                requires_context: false,
            },
            // Priority 7: Special prefix
            ChapterPattern {
                name: "正文前缀",
                regex: Regex::new(r"^正文\s+第.{1,30}[章回节]").unwrap(),
                priority: 7,
                category: PatternCategory::Special,
                requires_context: false,
            },
        ];

        let secondary_patterns = vec![
            // Priority 5: Numeric (needs context)
            ChapterPattern {
                name: "数字编号（三位）",
                regex: Regex::new(r"^\d{3}[^\d]").unwrap(),
                priority: 5,
                category: PatternCategory::Numeric,
                requires_context: true,
            },
            ChapterPattern {
                name: "数字编号（带点）",
                regex: Regex::new(r"^\d{1,3}\.\s*.{1,50}$").unwrap(),
                priority: 5,
                category: PatternCategory::Numeric,
                requires_context: true,
            },
            // Priority 4: Special keywords
            ChapterPattern {
                name: "序章/楔子",
                regex: Regex::new(r"^(序章|楔子|序言|前言|引子|开端)").unwrap(),
                priority: 4,
                category: PatternCategory::Special,
                requires_context: true,
            },
            ChapterPattern {
                name: "尾声/后记",
                regex: Regex::new(r"^(尾声|后记|结语|终章|番外)").unwrap(),
                priority: 4,
                category: PatternCategory::Special,
                requires_context: true,
            },
        ];

        let blacklist = Self::build_blacklist();

        Self {
            primary_patterns,
            secondary_patterns,
            blacklist,
            context_analyzer: ContextAnalyzer::new(),
        }
    }

    fn build_blacklist() -> HashSet<String> {
        [
            "第一天", "第二天", "第三天", "第一夜", "第二夜",
            "第一年", "第二年", "第一次", "第二次", "第三次",
            "第一时间", "第二天早上", "第二天上午", "第三天晚上",
            "第一名", "第二名", "第三名", "第一位", "第二位",
            "第一个", "第二个", "第三个", "第一批", "第二批",
            "第一印象", "第二印象", "第三方", "第一感觉",
            "第一眼", "第二眼", "第一步", "第二步", "第三步",
            "第一关", "第二关", "第一层", "第二层",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    /// Recognize a line as a chapter title.
    pub fn recognize_line(&self, line: &str, context: &LineContext) -> Option<ChapterMatch> {
        let trimmed = line.trim();

        // Length filter
        if trimmed.chars().count() > 100 {
            return None;
        }

        // Blacklist filter
        if self.is_blacklisted(trimmed) {
            return None;
        }

        // Try primary patterns
        if let Some(matched) = self.try_patterns(&self.primary_patterns, trimmed, context) {
            return Some(matched);
        }

        // Try secondary patterns (need context validation)
        if let Some(matched) = self.try_patterns(&self.secondary_patterns, trimmed, context) {
            if matched.requires_context_validation {
                if self.context_analyzer.validate(trimmed, context) {
                    return Some(matched);
                }
            } else {
                return Some(matched);
            }
        }

        None
    }

    fn try_patterns(
        &self,
        patterns: &[ChapterPattern],
        line: &str,
        context: &LineContext,
    ) -> Option<ChapterMatch> {
        patterns
            .iter()
            .filter_map(|pattern| {
                if pattern.regex.is_match(line) {
                    Some(ChapterMatch {
                        title: line.to_string(),
                        priority: pattern.priority,
                        pattern_name: pattern.name,
                        category: pattern.category,
                        requires_context_validation: pattern.requires_context,
                        confidence: self.calculate_confidence(line, pattern, context),
                    })
                } else {
                    None
                }
            })
            .max_by_key(|m| (m.priority, (m.confidence * 100.0) as i32))
    }

    fn is_blacklisted(&self, line: &str) -> bool {
        self.blacklist.iter().any(|word| line.contains(word.as_str()))
    }

    /// Calculate match confidence (0.0 - 1.0).
    fn calculate_confidence(
        &self,
        line: &str,
        _pattern: &ChapterPattern,
        context: &LineContext,
    ) -> f32 {
        let mut confidence: f32 = 0.8;

        // Length score (15-50 chars ideal)
        let len = line.chars().count();
        if len >= 15 && len <= 50 {
            confidence += 0.1;
        } else if len < 10 || len > 80 {
            confidence -= 0.1;
        }

        // Position score
        if context.is_near_start || context.has_previous_chapter {
            confidence += 0.05;
        }

        // Blank line score
        if context.has_blank_before && context.has_blank_after {
            confidence += 0.05;
        }

        // Sequential number score
        if let Some(prev_number) = context.previous_chapter_number {
            if let Some(current_number) = self.extract_chapter_number(line) {
                if current_number == prev_number + 1 {
                    confidence += 0.1;
                } else if current_number > prev_number {
                    confidence += 0.05;
                }
            }
        }

        confidence.min(1.0).max(0.0)
    }

    /// Extract chapter number from title.
    pub fn extract_chapter_number(&self, line: &str) -> Option<usize> {
        // Try Arabic numerals
        if let Some(caps) = Regex::new(r"\d+").unwrap().captures(line) {
            if let Some(num_str) = caps.get(0) {
                if let Ok(n) = num_str.as_str().parse::<usize>() {
                    return Some(n);
                }
            }
        }
        // Try Chinese numerals
        self.chinese_number_to_usize(line)
    }

    fn chinese_number_to_usize(&self, text: &str) -> Option<usize> {
        let char_map: HashMap<char, usize> = [
            ('零', 0), ('一', 1), ('二', 2), ('三', 3), ('四', 4),
            ('五', 5), ('六', 6), ('七', 7), ('八', 8), ('九', 9),
            ('十', 10), ('百', 100), ('千', 1000),
        ]
        .iter()
        .cloned()
        .collect();

        let chars: Vec<char> = text
            .chars()
            .filter(|c| char_map.contains_key(c))
            .collect();

        if chars.is_empty() {
            return None;
        }
        if chars.len() == 1 {
            return char_map.get(&chars[0]).copied();
        }

        // Simple Chinese number parsing
        let mut result = 0;
        let mut current = 0;
        for &c in &chars {
            let val = char_map[&c];
            if val == 10 || val == 100 || val == 1000 {
                if current == 0 {
                    current = 1;
                }
                result += current * val;
                current = 0;
            } else {
                current = val;
            }
        }
        result += current;

        if result > 0 { Some(result) } else { None }
    }

    /// Build nested chapter hierarchy (卷 → 章).
    pub fn build_hierarchy(&self, raw_chapters: Vec<RawChapter>) -> Vec<RecognizedChapter> {
        let mut result = Vec::new();
        let mut current_volume: Option<String> = None;

        for ch in raw_chapters {
            if ch.category == PatternCategory::Volume {
                current_volume = Some(ch.title.clone());
                continue;
            }

            let full_title = if let Some(ref vol) = current_volume {
                format!("{} · {}", vol, ch.title)
            } else {
                ch.title.clone()
            };

            let estimated_words = if ch.end_pos > ch.start_pos {
                ch.end_pos - ch.start_pos
            } else {
                0
            };

            result.push(RecognizedChapter {
                index: result.len(),
                title: full_title,
                start_offset: Some(ch.start_pos),
                end_offset: Some(ch.end_pos),
                estimated_words,
            });
        }

        result
    }

    /// Recognize all chapters from content lines.
    pub fn recognize_chapters(
        &mut self,
        lines: &[&str],
        byte_offsets: &[usize],
    ) -> Vec<RawChapter> {
        let total_lines = lines.len();
        let mut chapters = Vec::new();
        let mut prev_blank = true;
        let mut prev_chapter_num: Option<usize> = None;

        for (i, line) in lines.iter().enumerate() {
            let trimmed = line.trim();
            let has_blank_after = if i + 1 < total_lines {
                lines[i + 1].trim().is_empty()
            } else {
                true
            };

            let context = LineContext {
                line_number: i,
                total_lines,
                has_blank_before: prev_blank,
                has_blank_after,
                previous_chapter_number: prev_chapter_num,
                has_previous_chapter: !chapters.is_empty(),
                is_near_start: i < total_lines / 5,
            };

            if let Some(chapter_match) = self.recognize_line(trimmed, &context) {
                let start_pos = byte_offsets.get(i).copied().unwrap_or(0);
                let end_pos = byte_offsets.get(i + 1).copied().unwrap_or(start_pos);

                chapters.push(RawChapter {
                    title: chapter_match.title,
                    category: chapter_match.category,
                    start_pos,
                    end_pos,
                });

                prev_chapter_num = self.extract_chapter_number(trimmed);
                self.context_analyzer.record_chapter(i);
            }

            prev_blank = trimmed.is_empty();
        }

        chapters
    }
}

impl Default for ChapterRecognizer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_standard_chapters() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext {
            has_blank_before: true,
            has_blank_after: true,
            ..Default::default()
        };

        let cases = vec![
            "第1章 开始",
            "第001章 新的冒险",
            "第一章 序幕",
            "第二十三章 转折",
            "第一百章 终章",
        ];

        for case in cases {
            let result = recognizer.recognize_line(case, &context);
            assert!(result.is_some(), "Failed to recognize: {}", case);
        }
    }

    #[test]
    fn test_english_chapters() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext::default();

        let cases = vec!["Chapter 1", "Chapter 12", "Chapter IV"];

        for case in cases {
            let result = recognizer.recognize_line(case, &context);
            assert!(result.is_some(), "Failed to recognize: {}", case);
        }
    }

    #[test]
    fn test_volume_chapters() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext {
            has_blank_before: true,
            has_blank_after: true,
            ..Default::default()
        };

        let cases = vec!["卷一", "卷123", "第一部", "篇三"];

        for case in cases {
            let result = recognizer.recognize_line(case, &context);
            assert!(result.is_some(), "Failed to recognize: {}", case);
            assert_eq!(result.unwrap().category, PatternCategory::Volume);
        }
    }

    #[test]
    fn test_blacklist() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext::default();

        let blacklisted = vec![
            "第一天早上，他醒来了",
            "这是第二名的成绩",
            "第三方机构认证",
        ];

        for case in blacklisted {
            let result = recognizer.recognize_line(case, &context);
            assert!(result.is_none(), "Should be blacklisted: {}", case);
        }
    }

    #[test]
    fn test_chinese_number_conversion() {
        let recognizer = ChapterRecognizer::new();
        assert_eq!(recognizer.chinese_number_to_usize("一"), Some(1));
        assert_eq!(recognizer.chinese_number_to_usize("十"), Some(10));
        assert_eq!(recognizer.chinese_number_to_usize("十三"), Some(13));
        assert_eq!(recognizer.chinese_number_to_usize("二十"), Some(20));
        assert_eq!(recognizer.chinese_number_to_usize("一百"), Some(100));
    }

    #[test]
    fn test_build_hierarchy() {
        let recognizer = ChapterRecognizer::new();

        let raw = vec![
            RawChapter {
                title: "卷一".to_string(),
                category: PatternCategory::Volume,
                start_pos: 0,
                end_pos: 0,
            },
            RawChapter {
                title: "第一章 开始".to_string(),
                category: PatternCategory::Standard,
                start_pos: 100,
                end_pos: 1000,
            },
            RawChapter {
                title: "第二章 发展".to_string(),
                category: PatternCategory::Standard,
                start_pos: 1000,
                end_pos: 2000,
            },
        ];

        let result = recognizer.build_hierarchy(raw);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].title, "卷一 · 第一章 开始");
        assert_eq!(result[1].title, "卷一 · 第二章 发展");
    }

    #[test]
    fn test_special_chapters() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext {
            has_blank_before: true,
            has_blank_after: true,
            ..Default::default()
        };

        let cases = vec!["序章", "楔子", "尾声", "后记", "番外"];
        for case in cases {
            let result = recognizer.recognize_line(case, &context);
            assert!(result.is_some(), "Failed to recognize: {}", case);
        }
    }

    #[test]
    fn test_confidence_calculation() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext {
            has_blank_before: true,
            has_blank_after: true,
            is_near_start: true,
            ..Default::default()
        };

        let result = recognizer.recognize_line("第一章 开始新的冒险之旅", &context);
        assert!(result.is_some());
        assert!(result.unwrap().confidence > 0.8);
    }
}
