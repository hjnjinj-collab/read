# 深度预处理优化技术文档

> **文档目标**：详细说明章节标题提取、内容净化、分页精度、排版性能的深度优化方案  
> **适用阶段**：第三阶段 Week 3-4  
> **依赖**：JS 引擎、TextBoundaryHandler、SmartPaginator

---

## 📋 目录

1. [章节标题提取深度优化](#1-章节标题提取深度优化)
2. [标题重复去除优化](#2-标题重复去除优化)
3. [内容净化深度优化](#3-内容净化深度优化)
4. [分页精度优化](#4-分页精度优化)
5. [排版性能优化](#5-排版性能优化)
6. [预处理流水线整合](#6-预处理流水线整合)
7. [质量评估与测试](#7-质量评估与测试)

---

## 1. 章节标题提取深度优化

### 1.1 当前问题分析

**第二阶段实现的问题**：
- 正则模式过于简单，遗漏特殊格式
- 黑名单不完善，仍有误判
- 无法处理嵌套章节（卷、部、篇、章）
- 章节识别准确率约 85-90%（目标 >95%）

### 1.2 改进方案

#### 1.2.1 多层次正则模式库

```rust
// book_parser/src/txt_parser/chapter_recognizer.rs

use regex::Regex;
use std::collections::{HashMap, HashSet};

/// 章节识别器
pub struct ChapterRecognizer {
    /// 主模式（高置信度）
    primary_patterns: Vec<ChapterPattern>,
    
    /// 次级模式（需要额外验证）
    secondary_patterns: Vec<ChapterPattern>,
    
    /// 黑名单词汇
    blacklist: HashSet<String>,
    
    /// 上下文分析器
    context_analyzer: ContextAnalyzer,
}

#[derive(Debug, Clone)]
pub struct ChapterPattern {
    pub name: &'static str,
    pub regex: Regex,
    pub priority: i32,
    pub category: PatternCategory,
    pub requires_context: bool,  // 是否需要上下文验证
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PatternCategory {
    Standard,      // 标准格式：第X章
    English,       // 英文格式：Chapter X
    Numeric,       // 数字编号：001、1.
    Volume,        // 卷、部、篇
    Special,       // 特殊格式
}

impl ChapterRecognizer {
    pub fn new() -> Self {
        let primary_patterns = vec![
            // 优先级 10: 最常见的标准格式
            ChapterPattern {
                name: "标准章节（数字）",
                regex: Regex::new(r"^第\s*[0-9]{1,4}\s*[章回节集部卷篇]").unwrap(),
                priority: 10,
                category: PatternCategory::Standard,
                requires_context: false,
            },
            ChapterPattern {
                name: "标准章节（中文数字）",
                regex: Regex::new(r"^第\s*[一二三四五六七八九十百千零壹贰叁肆伍陆柒捌玖拾佰仟]+\s*[章回节集部卷篇]").unwrap(),
                priority: 10,
                category: PatternCategory::Standard,
                requires_context: false,
            },
            
            // 优先级 9: 英文格式
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
            
            // 优先级 8: 卷、部、篇
            ChapterPattern {
                name: "卷/部/篇（数字）",
                regex: Regex::new(r"^[卷部篇]\s*[0-9一二三四五六七八九十百千]+").unwrap(),
                priority: 8,
                category: PatternCategory::Volume,
                requires_context: false,
            },
            
            // 优先级 7: 特殊格式（带"正文"前缀）
            ChapterPattern {
                name: "正文前缀",
                regex: Regex::new(r"^正文\s+第.{1,30}[章回节]").unwrap(),
                priority: 7,
                category: PatternCategory::Special,
                requires_context: false,
            },
        ];
        
        let secondary_patterns = vec![
            // 优先级 5: 纯数字编号（需要上下文验证）
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
            
            // 优先级 4: 特殊关键词
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
        
        // 扩展黑名单
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
            // 日期时间
            "第一天", "第二天", "第三天", "第一夜", "第二夜",
            "第一年", "第二年", "第一次", "第二次", "第三次",
            "第一时间", "第二天早上", "第二天上午", "第三天晚上",
            
            // 排名序号
            "第一名", "第二名", "第三名", "第一位", "第二位",
            "第一个", "第二个", "第三个", "第一批", "第二批",
            
            // 其他常见误判
            "第一印象", "第二印象", "第三方", "第一感觉",
            "第一眼", "第二眼", "第一步", "第二步", "第三步",
            "第一关", "第二关", "第一层", "第二层",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }
    
    /// 识别章节（核心方法）
    pub fn recognize_line(&self, line: &str, context: &LineContext) -> Option<ChapterMatch> {
        let trimmed = line.trim();
        
        // 1. 长度过滤（章节标题通常不超过 100 字）
        if trimmed.len() > 100 {
            return None;
        }
        
        // 2. 黑名单过滤
        if self.is_blacklisted(trimmed) {
            return None;
        }
        
        // 3. 尝试主模式
        if let Some(matched) = self.try_patterns(&self.primary_patterns, trimmed, context) {
            return Some(matched);
        }
        
        // 4. 尝试次级模式（需要上下文验证）
        if let Some(matched) = self.try_patterns(&self.secondary_patterns, trimmed, context) {
            if matched.requires_context_validation {
                // 进行上下文验证
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
        patterns.iter()
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
        self.blacklist.iter().any(|word| line.contains(word))
    }
    
    /// 计算匹配置信度（0.0-1.0）
    fn calculate_confidence(
        &self,
        line: &str,
        pattern: &ChapterPattern,
        context: &LineContext,
    ) -> f32 {
        let mut confidence = 0.8;  // 基础置信度
        
        // 1. 长度评分（15-50 字符最理想）
        let len = line.len();
        if len >= 15 && len <= 50 {
            confidence += 0.1;
        } else if len < 10 || len > 80 {
            confidence -= 0.1;
        }
        
        // 2. 位置评分（在文件前 20% 或后续出现）
        if context.is_near_start || context.has_previous_chapter {
            confidence += 0.05;
        }
        
        // 3. 周围空行评分（前后都有空行更可能是章节）
        if context.has_blank_before && context.has_blank_after {
            confidence += 0.05;
        }
        
        // 4. 数字连续性评分
        if let Some(prev_number) = context.previous_chapter_number {
            if let Some(current_number) = self.extract_chapter_number(line) {
                // 连续编号增加置信度
                if current_number == prev_number + 1 {
                    confidence += 0.1;
                } else if current_number > prev_number {
                    confidence += 0.05;
                }
            }
        }
        
        confidence.min(1.0).max(0.0)
    }
    
    /// 提取章节编号
    fn extract_chapter_number(&self, line: &str) -> Option<usize> {
        // 尝试提取数字
        if let Some(caps) = Regex::new(r"\d+").unwrap().captures(line) {
            if let Some(num_str) = caps.get(0) {
                return num_str.as_str().parse().ok();
            }
        }
        
        // 尝试提取中文数字
        self.chinese_number_to_usize(line)
    }
    
    /// 中文数字转阿拉伯数字
    fn chinese_number_to_usize(&self, text: &str) -> Option<usize> {
        let char_map: HashMap<char, usize> = [
            ('零', 0), ('一', 1), ('二', 2), ('三', 3), ('四', 4),
            ('五', 5), ('六', 6), ('七', 7), ('八', 8), ('九', 9),
            ('十', 10), ('百', 100), ('千', 1000),
        ].iter().cloned().collect();
        
        // 简单实现（完整实现需要更复杂的解析）
        let chars: Vec<char> = text.chars()
            .filter(|c| char_map.contains_key(c))
            .collect();
        
        if chars.is_empty() {
            return None;
        }
        
        // 处理简单情况
        if chars.len() == 1 {
            return char_map.get(&chars[0]).copied();
        }
        
        // TODO: 完整的中文数字解析
        None
    }
}

/// 行上下文（用于辅助判断）
#[derive(Debug, Clone, Default)]
pub struct LineContext {
    pub line_number: usize,
    pub total_lines: usize,
    pub has_blank_before: bool,
    pub has_blank_after: bool,
    pub previous_chapter_number: Option<usize>,
    pub has_previous_chapter: bool,
    pub is_near_start: bool,  // 是否在文件开头（前 20%）
}

/// 章节匹配结果
#[derive(Debug, Clone)]
pub struct ChapterMatch {
    pub title: String,
    pub priority: i32,
    pub pattern_name: &'static str,
    pub category: PatternCategory,
    pub requires_context_validation: bool,
    pub confidence: f32,
}

/// 上下文分析器
pub struct ContextAnalyzer {
    // 章节间隔统计（用于判断连续性）
    chapter_intervals: Vec<usize>,
}

impl ContextAnalyzer {
    pub fn new() -> Self {
        Self {
            chapter_intervals: Vec::new(),
        }
    }
    
    /// 验证是否是真正的章节标题
    pub fn validate(&self, line: &str, context: &LineContext) -> bool {
        // 1. 检查前后空行
        if !context.has_blank_before && !context.has_blank_after {
            return false;
        }
        
        // 2. 检查长度合理性
        let len = line.len();
        if len < 3 || len > 100 {
            return false;
        }
        
        // 3. 检查位置合理性
        if context.line_number == 0 {
            return true;  // 第一行很可能是章节
        }
        
        // 4. 检查间隔合理性（章节间通常有几十到几百行）
        if context.has_previous_chapter {
            let avg_interval = self.average_interval();
            // 如果有平均间隔，检查当前间隔是否合理
            if avg_interval > 0 {
                // TODO: 实现间隔检查
            }
        }
        
        true
    }
    
    fn average_interval(&self) -> usize {
        if self.chapter_intervals.is_empty() {
            return 0;
        }
        
        self.chapter_intervals.iter().sum::<usize>() / self.chapter_intervals.len()
    }
    
    pub fn record_chapter(&mut self, line_number: usize) {
        if let Some(&last) = self.chapter_intervals.last() {
            self.chapter_intervals.push(line_number - last);
        }
    }
}
```

#### 1.2.2 嵌套章节结构支持

```rust
/// 章节层次结构
#[derive(Debug, Clone)]
pub enum ChapterHierarchy {
    Volume {
        title: String,
        chapters: Vec<ChapterHierarchy>,
    },
    Chapter {
        title: String,
        start_pos: usize,
        end_pos: usize,
    },
}

impl ChapterRecognizer {
    /// 构建嵌套章节结构
    pub fn build_hierarchy(&self, raw_chapters: Vec<RawChapter>) -> Vec<ChapterInfo> {
        let mut result = Vec::new();
        let mut current_volume: Option<String> = None;
        
        for ch in raw_chapters {
            // 判断是否是卷/部/篇
            if ch.category == PatternCategory::Volume {
                current_volume = Some(ch.title.clone());
                // 卷本身不作为独立章节
                continue;
            }
            
            // 构建完整标题
            let full_title = if let Some(vol) = &current_volume {
                format!("{} · {}", vol, ch.title)
            } else {
                ch.title.clone()
            };
            
            result.push(ChapterInfo {
                index: result.len(),
                title: full_title,
                start_offset: Some(ch.start_pos),
                end_offset: Some(ch.end_pos),
                estimated_words: ch.end_pos - ch.start_pos,
                resource_href: None,
                fragment_id: None,
            });
        }
        
        result
    }
}
```

### 1.3 质量保证

#### 测试用例覆盖

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_standard_chapters() {
        let recognizer = ChapterRecognizer::new();
        let context = LineContext::default();
        
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
            assert!(result.unwrap().confidence > 0.8);
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
    fn test_nested_structure() {
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
    }
}
```

---

## 2. 标题重复去除优化

### 2.1 问题分析

**当前实现问题**：
- 只能完全匹配
- 无法处理变体（"第一章"vs"第一章："）
- 无法处理装饰字符（【】《》等）

### 2.2 改进方案

```rust
// reader_core/src/processing/stages/duplicate_title_remover.rs

use strsim::levenshtein;

pub struct DuplicateTitleRemover {
    fuzzy_threshold: f32,  // 相似度阈值（默认 0.8）
    max_search_lines: usize,  // 最多搜索前 N 行（默认 5）
}

impl DuplicateTitleRemover {
    pub fn new() -> Self {
        Self {
            fuzzy_threshold: 0.8,
            max_search_lines: 5,
        }
    }
    
    /// 移除重复标题（支持模糊匹配）
    pub fn remove_duplicate(&self, content: &str, title: &str) -> String {
        let lines: Vec<&str> = content.lines().collect();
        
        // 清理标题（移除装饰字符）
        let title_clean = self.clean_title(title);
        
        // 在前 N 行中查找匹配
        let mut skip_lines = 0;
        for (i, line) in lines.iter().take(self.max_search_lines).enumerate() {
            let line_clean = self.clean_title(line);
            
            if self.is_similar(&title_clean, &line_clean) {
                skip_lines = i + 1;
                break;
            }
        }
        
        if skip_lines > 0 {
            // 跳过匹配的行，并移除开头的空行
            lines[skip_lines..]
                .iter()
                .skip_while(|l| l.trim().is_empty())
                .copied()
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            content.to_string()
        }
    }
    
    /// 清理标题（移除装饰字符和空白）
    fn clean_title(&self, title: &str) -> String {
        let decorators = ['【', '】', '「', '」', '《', '》', '『', '』',
                         '[', ']', '(', ')', '<', '>', '{', '}',
                         '：', ':', '。', '.', '！', '!'];
        
        title.chars()
            .filter(|c| !c.is_whitespace() && !decorators.contains(c))
            .collect()
    }
    
    /// 判断两个字符串是否相似
    fn is_similar(&self, s1: &str, s2: &str) -> bool {
        // 1. 完全匹配
        if s1 == s2 {
            return true;
        }
        
        // 2. 包含关系（较短的完全包含在较长的中）
        if s1.len() < s2.len() && s2.contains(s1) {
            return true;
        }
        if s2.len() < s1.len() && s1.contains(s2) {
            return true;
        }
        
        // 3. 模糊匹配（编辑距离）
        let distance = levenshtein(s1, s2);
        let max_len = s1.len().max(s2.len());
        
        if max_len == 0 {
            return false;
        }
        
        let similarity = 1.0 - (distance as f32 / max_len as f32);
        similarity >= self.fuzzy_threshold
    }
}

#[async_trait]
impl ProcessingStage for DuplicateTitleRemover {
    async fn process(&mut self, input: StageInput) -> Result<StageOutput> {
        let (content, context) = match input {
            StageInput::Content(c, ctx) => (c, ctx),
            _ => return Err(anyhow!("Invalid input")),
        };
        
        let title = context.chapter_title.as_deref().unwrap_or("");
        
        if title.is_empty() {
            return Ok(StageOutput::Content(content, context));
        }
        
        let processed = self.remove_duplicate(&content, title);
        
        Ok(StageOutput::Content(processed, context))
    }
    
    fn stage_name(&self) -> &'static str {
        "DuplicateTitleRemover"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_exact_match() {
        let remover = DuplicateTitleRemover::new();
        let content = "第一章 开始\n\n正文内容...";
        let title = "第一章 开始";
        
        let result = remover.remove_duplicate(content, title);
        assert_eq!(result, "正文内容...");
    }
    
    #[test]
    fn test_with_decorators() {
        let remover = DuplicateTitleRemover::new();
        let content = "【第一章】新的开始\n\n正文内容...";
        let title = "第一章 新的开始";
        
        let result = remover.remove_duplicate(content, title);
        assert_eq!(result, "正文内容...");
    }
    
    #[test]
    fn test_fuzzy_match() {
        let remover = DuplicateTitleRemover::new();
        let content = "第一章：新的开始\n\n正文内容...";
        let title = "第一章 新的开始";
        
        let result = remover.remove_duplicate(content, title);
        assert_eq!(result, "正文内容...");
    }
    
    #[test]
    fn test_no_match() {
        let remover = DuplicateTitleRemover::new();
        let content = "这是一段正文内容...";
        let title = "第一章 开始";
        
        let result = remover.remove_duplicate(content, title);
        assert_eq!(result, content);
    }
}
```

---

## 3. 内容净化深度优化

### 3.1 问题分析

**需要净化的内容**：
1. 页眉页脚（页码、网站来源）
2. OCR 错误（扫描版常见）
3. 多余的分隔线
4. 乱码字符
5. 特殊格式标记

### 3.2 详细实现

```rust
// reader_core/src/processing/stages/content_cleaner.rs

pub struct ContentCleaner {
    /// 页眉页脚模式
    header_footer_patterns: Vec<Regex>,
    
    /// OCR 错误修正表
    ocr_fixes: HashMap<String, String>,
    
    /// 分隔线模式
    separator_patterns: Vec<Regex>,
    
    /// 格式检测器
    format_detector: FormatDetector,
}

impl ContentCleaner {
    pub fn new() -> Self {
        Self {
            header_footer_patterns: Self::build_header_footer_patterns(),
            ocr_fixes: Self::build_ocr_fixes(),
            separator_patterns: Self::build_separator_patterns(),
            format_detector: FormatDetector::new(),
        }
    }
    
    fn build_header_footer_patterns() -> Vec<Regex> {
        vec![
            // 页码模式
            Regex::new(r"(?m)^.{0,10}第\s*\d+\s*页.{0,10}$").unwrap(),
            Regex::new(r"(?m)^.{0,10}-\s*\d+\s*-.{0,10}$").unwrap(),
            Regex::new(r"(?m)^.{0,10}\d+\s*/\s*\d+.{0,10}$").unwrap(),
            
            // 网站来源
            Regex::new(r"(?m)^.{0,10}(www\.|http|https|来源：|本书来自).{0,80}$").unwrap(),
            Regex::new(r"(?m)^.{0,10}(小说|书籍|下载).{0,30}(网|站).{0,10}$").unwrap(),
            
            // 版权声明
            Regex::new(r"(?m)^.{0,10}(版权|copyright|©).{0,50}$").unwrap(),
            
            // 更新时间
            Regex::new(r"(?m)^.{0,10}\d{4}[-/年]\d{1,2}[-/月]\d{1,2}[日]?.{0,10}$").unwrap(),
        ]
    }
    
    fn build_ocr_fixes() -> HashMap<String, String> {
        [
            // 常见 OCR 错误
            ("巳", "已"), ("己", "已"), ("巴", "把"),
            ("氵", ""), ("亻", ""), ("彳", ""),
            ("讠", ""), ("纟", ""),
            
            // 标点符号混淆
            ("，。", "，"), ("。，", "。"),
            ("！。", "！"), ("？。", "？"),
            
            // 空格问题
            (" ，", "，"), (" 。", "。"),
            (" ！", "！"), (" ？", "？"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }
    
    fn build_separator_patterns() -> Vec<Regex> {
        vec![
            // 连续的分隔线
            Regex::new(r"(?m)^[-=_*]{5,}$").unwrap(),
            Regex::new(r"(?m)^[·•]{3,}$").unwrap(),
            
            // 重复的装饰字符
            Regex::new(r"(?m)^[◆◇■□●○]{3,}$").unwrap(),
        ]
    }
    
    /// 净化内容
    pub fn clean(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        // 1. 移除页眉页脚
        result = self.remove_headers_footers(&result);
        
        // 2. 修复 OCR 错误
        result = self.fix_ocr_errors(&result);
        
        // 3. 移除分隔线
        result = self.remove_separators(&result);
        
        // 4. 规范化空行
        result = self.normalize_blank_lines(&result);
        
        // 5. 清理乱码
        result = self.remove_garbled_text(&result);
        
        // 6. 保留特殊格式（诗歌、对话）
        result = self.preserve_special_formats(&result);
        
        result
    }
    
    fn remove_headers_footers(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        for pattern in &self.header_footer_patterns {
            result = pattern.replace_all(&result, "").to_string();
        }
        
        result
    }
    
    fn fix_ocr_errors(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        for (wrong, correct) in &self.ocr_fixes {
            result = result.replace(wrong, correct);
        }
        
        result
    }
    
    fn remove_separators(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        for pattern in &self.separator_patterns {
            result = pattern.replace_all(&result, "").to_string();
        }
        
        result
    }
    
    fn normalize_blank_lines(&self, content: &str) -> String {
        // 1. 连续 3+ 空行 → 2 空行
        let result = Regex::new(r"\n{3,}")
            .unwrap()
            .replace_all(content, "\n\n")
            .to_string();
        
        // 2. 段落首行缩进标准化
        let result = Regex::new(r"(?m)^[\s　]+")
            .unwrap()
            .replace_all(&result, "　　")
            .to_string();
        
        result
    }
    
    fn remove_garbled_text(&self, content: &str) -> String {
        // 移除明显的乱码行
        let lines: Vec<&str> = content.lines().collect();
        let mut cleaned_lines = Vec::new();
        
        for line in lines {
            if !self.is_garbled(line) {
                cleaned_lines.push(line);
            }
        }
        
        cleaned_lines.join("\n")
    }
    
    fn is_garbled(&self, line: &str) -> bool {
        let trimmed = line.trim();
        
        // 空行不算乱码
        if trimmed.is_empty() {
            return false;
        }
        
        // 统计特殊字符比例
        let special_chars = trimmed.chars()
            .filter(|c| !c.is_alphanumeric() && !c.is_whitespace() && !Self::is_cjk(*c))
            .count();
        
        let ratio = special_chars as f32 / trimmed.len() as f32;
        
        // 特殊字符超过 50% 可能是乱码
        ratio > 0.5
    }
    
    fn is_cjk(c: char) -> bool {
        matches!(c,
            '\u{4E00}'..='\u{9FFF}' | // CJK Unified Ideographs
            '\u{3400}'..='\u{4DBF}' | // CJK Extension A
            '\u{20000}'..='\u{2A6DF}' | // CJK Extension B
            '\u{2A700}'..='\u{2B73F}' | // CJK Extension C
            '\u{2B740}'..='\u{2B81F}'   // CJK Extension D
        )
    }
    
    fn preserve_special_formats(&self, content: &str) -> String {
        let format_info = self.format_detector.detect(content);
        
        match format_info.format_type {
            FormatType::Poetry => {
                // 诗歌：保留短行和缩进
                content.to_string()
            }
            FormatType::Dialogue => {
                // 对话：保留引号格式
                content.to_string()
            }
            FormatType::Normal => {
                // 普通文本：标准处理
                content.to_string()
            }
        }
    }
}

/// 格式检测器
pub struct FormatDetector;

impl FormatDetector {
    pub fn new() -> Self {
        Self
    }
    
    pub fn detect(&self, content: &str) -> FormatInfo {
        let lines: Vec<&str> = content.lines().collect();
        
        // 统计短行比例（诗歌特征）
        let short_lines = lines.iter()
            .filter(|l| l.trim().len() > 0 && l.trim().len() < 20)
            .count();
        let short_ratio = short_lines as f32 / lines.len() as f32;
        
        // 统计引号行比例（对话特征）
        let quote_lines = lines.iter()
            .filter(|l| l.trim().starts_with('"') || l.trim().starts_with('"') || l.trim().starts_with('「'))
            .count();
        let quote_ratio = quote_lines as f32 / lines.len() as f32;
        
        let format_type = if short_ratio > 0.5 {
            FormatType::Poetry
        } else if quote_ratio > 0.3 {
            FormatType::Dialogue
        } else {
            FormatType::Normal
        };
        
        FormatInfo {
            format_type,
            short_line_ratio: short_ratio,
            quote_line_ratio: quote_ratio,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatType {
    Normal,
    Poetry,
    Dialogue,
}

#[derive(Debug, Clone)]
pub struct FormatInfo {
    pub format_type: FormatType,
    pub short_line_ratio: f32,
    pub quote_line_ratio: f32,
}
```

---

## 4. 分页精度优化

### 4.1 孤行/寡行问题

**定义**：
- **孤行（Orphan）**：段落的第一行单独留在上一页的页尾
- **寡行（Widow）**：段落的最后一行单独出现在新页的页首

**影响**：严重影响阅读体验，破坏段落连贯性

### 4.2 详细实现

```rust
// layout_engine/src/pagination/smart_paginator.rs

impl SmartPaginator {
    /// 智能分页（避免孤行/寡行）
    pub fn paginate_smart(
        &self,
        lines: Vec<Line>,
        page_height: f32,
    ) -> Vec<Page> {
        // 1. 检测段落边界
        let paragraphs = self.detect_paragraphs(&lines);
        
        let mut pages = Vec::new();
        let mut current_page_lines = Vec::new();
        let mut current_height = self.config.padding.top;
        let effective_height = page_height - self.config.padding.top - self.config.padding.bottom;
        
        for para in paragraphs {
            // 计算段落总高度
            let para_height: f32 = para.lines.iter()
                .map(|l| l.height + self.config.line_spacing)
                .sum();
            
            // 检查段落完整性
            if para.lines.len() >= self.config.min_lines_per_paragraph {
                let fill_ratio = current_height / effective_height;
                
                // 如果页面已填充超过阈值，且段落较长，考虑段落完整性
                if fill_ratio >= self.config.paragraph_break_threshold {
                    // 段落完整放在新页
                    if !current_page_lines.is_empty() {
                        pages.push(self.create_page(current_page_lines.clone(), pages.len()));
                        current_page_lines.clear();
                        current_height = self.config.padding.top;
                    }
                }
            }
            
            // 逐行添加，检查孤行/寡行
            for (line_idx, line) in para.lines.iter().enumerate() {
                let is_first_line = line_idx == 0;
                let is_last_line = line_idx == para.lines.len() - 1;
                let remaining_space = effective_height - current_height;
                
                // 孤行检测
                if self.config.avoid_orphan && is_first_line {
                    // 如果是段落第一行，且空间不足放下第二行
                    if para.lines.len() > 1 {
                        let first_two_height = line.height + para.lines[1].height + self.config.line_spacing * 2.0;
                        
                        if remaining_space >= line.height && remaining_space < first_two_height {
                            // 会产生孤行，将这一行移到新页
                            if !current_page_lines.is_empty() {
                                pages.push(self.create_page(current_page_lines.clone(), pages.len()));
                                current_page_lines.clear();
                                current_height = self.config.padding.top;
                            }
                        }
                    }
                }
                
                // 寡行检测
                if self.config.avoid_widow && is_last_line && para.lines.len() > 1 {
                    // 如果是段落最后一行，检查是否会单独在新页
                    if remaining_space < line.height {
                        // 最后一行会在新页，尝试将前一行也移过去
                        if let Some(prev_line) = current_page_lines.pop() {
                            pages.push(self.create_page(current_page_lines.clone(), pages.len()));
                            current_page_lines = vec![prev_line, line.clone()];
                            current_height = self.config.padding.top + prev_line.height + line.height + self.config.line_spacing * 2.0;
                            continue;
                        }
                    }
                }
                
                // 正常添加行
                if current_height + line.height > effective_height {
                    // 页面已满
                    pages.push(self.create_page(current_page_lines.clone(), pages.len()));
                    current_page_lines.clear();
                    current_height = self.config.padding.top;
                }
                
                current_page_lines.push(line.clone());
                current_height += line.height + self.config.line_spacing;
            }
            
            // 段落间距
            current_height += self.config.paragraph_spacing;
        }
        
        // 最后一页
        if !current_page_lines.is_empty() {
            pages.push(self.create_page(current_page_lines, pages.len()));
        }
        
        pages
    }
    
    /// 检测段落边界
    fn detect_paragraphs(&self, lines: &[Line]) -> Vec<Paragraph> {
        let mut paragraphs = Vec::new();
        let mut current_para_lines = Vec::new();
        
        for (i, line) in lines.iter().enumerate() {
            current_para_lines.push(line.clone());
            
            // 检测段落结束
            let is_para_end = if i < lines.len() - 1 {
                let next_line = &lines[i + 1];
                
                // 段落结束的判断条件
                line.spacing_after > self.config.line_spacing * 1.5 || // 行后有较大间距
                next_line.text.starts_with("　　") || // 下一行首行缩进
                line.text.ends_with('。') || line.text.ends_with('！') || line.text.ends_with('？') // 句子结束
            } else {
                true // 最后一行
            };
            
            if is_para_end {
                paragraphs.push(Paragraph {
                    lines: current_para_lines.clone(),
                    paragraph_type: ParagraphType::Normal,
                });
                current_para_lines.clear();
            }
        }
        
        paragraphs
    }
    
    fn create_page(&self, lines: Vec<Line>, page_index: usize) -> Page {
        let start_char = lines.first().map(|l| l.char_start).unwrap_or(0);
        let end_char = lines.last().map(|l| l.char_end).unwrap_or(0);
        
        Page {
            page_index,
            lines,
            start_char,
            end_char,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Paragraph {
    pub lines: Vec<Line>,
    pub paragraph_type: ParagraphType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParagraphType {
    Normal,
    Poetry,
    Dialogue,
    Quote,
    Heading,
}
```

---

## 5. 排版性能优化

### 5.1 并行排版

```rust
// layout_engine/src/parallel.rs

use rayon::prelude::*;

impl LayoutEngine {
    /// 并行排版（段落级别）
    pub fn layout_text_parallel(&mut self, content: &str, config: &LayoutConfig) -> Result<LayoutResult> {
        // 1. 按段落分割
        let paragraphs: Vec<&str> = content.split("\n\n").collect();
        
        // 2. 准备字体管理器（每个线程一个副本）
        let font_manager = Arc::new(Mutex::new(self.font_manager.clone()));
        let glyph_cache = Arc::new(Mutex::new(self.glyph_cache.clone()));
        
        // 3. 并行排版每个段落
        let paragraph_results: Vec<Vec<Line>> = paragraphs
            .par_iter()
            .enumerate()
            .map(|(para_idx, para)| {
                let mut fm = font_manager.lock().unwrap();
                let mut gc = glyph_cache.lock().unwrap();
                
                Self::layout_paragraph_static(para, config, &mut fm, &mut gc, para_idx)
            })
            .collect::<Result<Vec<_>>>()?;
        
        // 4. 合并结果并重新编号
        let mut all_lines = Vec::new();
        let mut char_offset = 0;
        
        for para_lines in paragraph_results {
            for mut line in para_lines {
                line.char_start += char_offset;
                line.char_end += char_offset;
                all_lines.push(line);
            }
            
            char_offset += para.len() + 2;  // +2 for "\n\n"
        }
        
        Ok(LayoutResult {
            lines: all_lines,
        })
    }
    
    fn layout_paragraph_static(
        paragraph: &str,
        config: &LayoutConfig,
        font_manager: &mut FontManager,
        glyph_cache: &mut GlyphCache,
        para_index: usize,
    ) -> Result<Vec<Line>> {
        // 段落排版逻辑（无需修改）
        // ...
        Ok(vec![])
    }
}
```

### 5.2 增量重排版

```rust
impl ReadSession {
    /// 增量重排版（配置微调）
    pub async fn update_config_incremental(
        &mut self,
        new_config: LayoutConfig,
    ) -> Result<()> {
        let change_type = self.detect_config_change_type(&self.page_config, &new_config);
        
        match change_type {
            ConfigChangeType::OnlyPagination => {
                // 只影响分页（页面尺寸变化）
                info!("Only pagination affected, repaginating...");
                self.repaginate_current_chapter().await?;
            }
            ConfigChangeType::MinorLayout => {
                // 轻微影响排版（行距、段间距变化）
                info!("Minor layout changes, relayouting current chapter ±1...");
                self.relayout_adjacent_chapters(1).await?;
            }
            ConfigChangeType::MajorLayout => {
                // 严重影响排版（字号、字体变化）
                info!("Major layout changes, clearing all caches...");
                self.clear_all_caches().await;
                self.reload_current_chapter().await?;
            }
        }
        
        self.page_config = new_config;
        Ok(())
    }
    
    fn detect_config_change_type(
        &self,
        old_config: &LayoutConfig,
        new_config: &LayoutConfig,
    ) -> ConfigChangeType {
        // 检查字号或字体变化（Major）
        if old_config.font_size != new_config.font_size ||
           old_config.font_name != new_config.font_name {
            return ConfigChangeType::MajorLayout;
        }
        
        // 检查行距或边距变化（Minor）
        if old_config.line_height_multiplier != new_config.line_height_multiplier ||
           old_config.padding != new_config.padding ||
           old_config.letter_spacing != new_config.letter_spacing {
            return ConfigChangeType::MinorLayout;
        }
        
        // 只有页面尺寸变化（OnlyPagination）
        ConfigChangeType::OnlyPagination
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigChangeType {
    OnlyPagination,   // 只需重新分页
    MinorLayout,      // 需要重新排版（但影响范围小）
    MajorLayout,      // 需要完全重新排版
}
```

---

## 6. 预处理流水线整合

### 6.1 优化后的流水线

```rust
impl ProcessingPipeline {
    /// 构建优化的流水线
    pub fn build_optimized(
        js_pool: Arc<JsRuntimePool>,
        config: PipelineConfig,
    ) -> Self {
        let stages: Vec<Box<dyn ProcessingStage>> = vec![
            // Stage 1: 标题去重（快速，优先级最高）
            Box::new(DuplicateTitleRemover::new()
                .with_fuzzy_threshold(0.8)),
            
            // Stage 2: HTML 保护（JS 前置）
            Box::new(HtmlProtector::new()),
            
            // Stage 3: 内容净化（移除页眉页脚、OCR 错误）
            Box::new(ContentCleaner::new()),
            
            // Stage 4: JS 规则执行（核心，可选）
            Box::new(JsExecutor::new(js_pool)
                .with_timeout(5000)
                .with_retry(2)),
            
            // Stage 5: HTML 恢复
            Box::new(HtmlRestorer::new()),
            
            // Stage 6: 重新分段
            Box::new(ResegmentProcessor::new()),
            
            // Stage 7: 简繁转换（可选）
            Box::new(ChineseConvertStage::new()),
        ];
        
        ProcessingPipeline {
            stages,
            config,
            stats: Arc::new(Mutex::new(PipelineStats::default())),
        }
    }
}
```

---

## 7. 质量评估与测试

### 7.1 评估指标

| 指标 | 目标 | 测试方法 |
|------|------|---------|
| **章节识别准确率** | >95% | 100本真实书籍测试 |
| **标题去重成功率** | >98% | 人工标注数据集 |
| **内容净化效果** | 页眉页脚移除率>90% | 扫描版TXT测试 |
| **分页精度** | 孤行/寡行<5% | 随机抽样测试 |
| **预处理性能** | <100ms（10k字） | 基准测试 |
| **排版性能** | <50ms（10k字） | 基准测试 |

### 7.2 测试套件

```rust
// tests/preprocessing_quality_test.rs

#[tokio::test]
async fn test_chapter_recognition_accuracy() {
    let recognizer = ChapterRecognizer::new();
    
    // 加载测试数据集（100本真实书籍）
    let test_books = load_test_books("tests/data/books/");
    
    let mut total_chapters = 0;
    let mut correct_chapters = 0;
    
    for book in test_books {
        let detected = recognizer.recognize_chapters(&book.content);
        let ground_truth = &book.ground_truth_chapters;
        
        total_chapters += ground_truth.len();
        
        // 计算正确识别的数量
        for gt in ground_truth {
            if detected.iter().any(|d| d.title == gt.title && (d.start_pos as i32 - gt.start_pos as i32).abs() < 100) {
                correct_chapters += 1;
            }
        }
    }
    
    let accuracy = correct_chapters as f32 / total_chapters as f32;
    println!("Chapter recognition accuracy: {:.2}%", accuracy * 100.0);
    
    assert!(accuracy > 0.95, "Accuracy {} is below target 0.95", accuracy);
}

#[tokio::test]
async fn test_preprocessing_performance() {
    let pipeline = ProcessingPipeline::build_optimized(/* ... */);
    
    // 10k 字测试内容
    let content = generate_test_content(10000);
    
    let start = Instant::now();
    let _ = pipeline.process(content).await.unwrap();
    let elapsed = start.elapsed();
    
    println!("Preprocessing 10k chars took: {:?}", elapsed);
    assert!(elapsed < Duration::from_millis(100));
}
```

---

**文档版本**：v1.0  
**创建日期**：2025-01-XX  
**维护者**：Kiro AI Agent  
**更新频率**：随第三阶段实施更新
