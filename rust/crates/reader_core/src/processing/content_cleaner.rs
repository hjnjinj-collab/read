use std::collections::HashMap;

use regex::Regex;

use super::pipeline::PipelineData;
use super::stages::ProcessingStage;

/// Content cleaner that removes headers/footers, fixes OCR errors,
/// removes separators, and normalizes whitespace.
pub struct ContentCleaner {
    header_footer_patterns: Vec<Regex>,
    ocr_fixes: HashMap<String, String>,
    separator_patterns: Vec<Regex>,
}

impl ContentCleaner {
    pub fn new() -> Self {
        Self {
            header_footer_patterns: Self::build_header_footer_patterns(),
            ocr_fixes: Self::build_ocr_fixes(),
            separator_patterns: Self::build_separator_patterns(),
        }
    }

    fn build_header_footer_patterns() -> Vec<Regex> {
        vec![
            // 页码: "第 X 页", "- X -", "X / Y"
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
            ("巳", "已"),
            ("己", "已"),
            ("巴", "把"),
            // 标点符号混淆
            ("，。", "，"),
            ("。，", "。"),
            ("！。", "！"),
            ("？。", "？"),
            // 空格问题
            (" ，", "，"),
            (" 。", "。"),
            (" ！", "！"),
            (" ？", "？"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    fn build_separator_patterns() -> Vec<Regex> {
        vec![
            Regex::new(r"(?m)^[-=_*]{5,}$").unwrap(),
            Regex::new(r"(?m)^[·•]{3,}$").unwrap(),
            Regex::new(r"(?m)^[◆◇■□●○]{3,}$").unwrap(),
        ]
    }

    /// Clean content through all stages.
    pub fn clean(&self, content: &str) -> String {
        let mut result = content.to_string();
        result = self.remove_headers_footers(&result);
        result = self.fix_ocr_errors(&result);
        result = self.remove_separators(&result);
        result = self.normalize_blank_lines(&result);
        result = self.remove_garbled_text(&result);
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
        // 连续 3+ 空行 → 2 空行
        let result = Regex::new(r"\n{3,}")
            .unwrap()
            .replace_all(content, "\n\n")
            .to_string();
        // 段落首行缩进标准化（全角空格）
        let result = Regex::new(r"(?m)^[\s　]+")
            .unwrap()
            .replace_all(&result, "　　")
            .to_string();
        result
    }

    fn remove_garbled_text(&self, content: &str) -> String {
        content
            .lines()
            .filter(|line| !self.is_garbled(line))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn is_garbled(&self, line: &str) -> bool {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return false;
        }
        let special_chars = trimmed
            .chars()
            .filter(|c| !c.is_alphanumeric() && !c.is_whitespace() && !Self::is_cjk(*c))
            .count();
        let ratio = special_chars as f32 / trimmed.chars().count() as f32;
        ratio > 0.5
    }

    fn is_cjk(c: char) -> bool {
        matches!(
            c,
            '\u{4E00}'..='\u{9FFF}'
                | '\u{3400}'..='\u{4DBF}'
                | '\u{20000}'..='\u{2A6DF}'
                | '\u{2A700}'..='\u{2B73F}'
                | '\u{2B740}'..='\u{2B81F}'
        )
    }
}

impl Default for ContentCleaner {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl ProcessingStage for ContentCleaner {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData, anyhow::Error> {
        input.content = self.clean(&input.content);
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "ContentCleaner"
    }
}

/// Format type detected in content.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatType {
    Normal,
    Poetry,
    Dialogue,
}

/// Format detection result.
#[derive(Debug, Clone)]
pub struct FormatInfo {
    pub format_type: FormatType,
    pub short_line_ratio: f32,
    pub quote_line_ratio: f32,
}

/// Detect content format (poetry, dialogue, normal).
pub fn detect_format(content: &str) -> FormatInfo {
    let lines: Vec<&str> = content.lines().collect();
    if lines.is_empty() {
        return FormatInfo {
            format_type: FormatType::Normal,
            short_line_ratio: 0.0,
            quote_line_ratio: 0.0,
        };
    }

    let non_empty: Vec<&str> = lines.iter().filter(|l| !l.trim().is_empty()).copied().collect();
    let total = non_empty.len() as f32;

    let short_lines = non_empty
        .iter()
        .filter(|l| l.trim().len() > 0 && l.trim().len() < 20)
        .count();
    let short_ratio = short_lines as f32 / total;

    let quote_lines = non_empty
        .iter()
        .filter(|l| {
            let t = l.trim();
            t.starts_with('"') || t.starts_with('"') || t.starts_with('「')
        })
        .count();
    let quote_ratio = quote_lines as f32 / total;

    let format_type = if quote_ratio > 0.3 {
        FormatType::Dialogue
    } else if short_ratio > 0.5 {
        FormatType::Poetry
    } else {
        FormatType::Normal
    };

    FormatInfo {
        format_type,
        short_line_ratio: short_ratio,
        quote_line_ratio: quote_ratio,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remove_headers_footers() {
        let cleaner = ContentCleaner::new();
        let content = "正文内容\n第 5 页\n更多内容";
        let result = cleaner.clean(content);
        assert!(!result.contains("第 5 页"));
        assert!(result.contains("正文内容"));
    }

    #[test]
    fn test_fix_ocr_errors() {
        let cleaner = ContentCleaner::new();
        let content = "他巳经走了，这是一件好事。";
        let result = cleaner.clean(content);
        assert!(result.contains("他已经走了"));
    }

    #[test]
    fn test_remove_separators() {
        let cleaner = ContentCleaner::new();
        let content = "段落1\n-----\n段落2";
        let result = cleaner.clean(content);
        assert!(!result.contains("-----"));
    }

    #[test]
    fn test_normalize_blank_lines() {
        let cleaner = ContentCleaner::new();
        let content = "段落1\n\n\n\n\n段落2";
        let result = cleaner.clean(content);
        assert!(!result.contains("\n\n\n"));
    }

    #[test]
    fn test_remove_garbled() {
        let cleaner = ContentCleaner::new();
        let content = "正常内容\n\x00\x01\x02\x03\x04\x05\x06\x07\n更多内容";
        let result = cleaner.clean(content);
        assert!(result.contains("正常内容"));
    }

    #[test]
    fn test_detect_format_poetry() {
        let content = "春眠不觉晓\n处处闻啼鸟\n夜来风雨声\n花落知多少";
        let info = detect_format(content);
        assert_eq!(info.format_type, FormatType::Poetry);
    }

    #[test]
    fn test_detect_format_dialogue() {
        let content = "\"你好吗？\"\n\"我很好。\"\n\"那就好。\"\n\"再见。\"";
        let info = detect_format(content);
        assert_eq!(info.format_type, FormatType::Dialogue);
    }

    #[test]
    fn test_detect_format_normal() {
        let content = "这是一段很长的正文内容，用来测试普通文本格式的检测。";
        let info = detect_format(content);
        assert_eq!(info.format_type, FormatType::Normal);
    }

    #[tokio::test]
    async fn test_content_cleaner_stage() {
        let cleaner = ContentCleaner::new();
        let input = PipelineData {
            content: "第 1 页\n正文内容\n\n\n\n更多".to_string(),
            ..Default::default()
        };
        let output = cleaner.process(input).await.unwrap();
        assert!(!output.content.contains("第 1 页"));
        assert!(!output.content.contains("\n\n\n"));
    }
}
