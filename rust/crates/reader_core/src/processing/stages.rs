use std::collections::HashMap;

use anyhow::Result;
use regex::Regex;

use super::pipeline::PipelineData;

/// Processing stage trait - each stage transforms content.
#[async_trait::async_trait]
pub trait ProcessingStage: Send + Sync {
    /// Process the input and return output.
    async fn process(&self, input: PipelineData) -> Result<PipelineData>;

    /// Stage name for logging.
    fn stage_name(&self) -> &'static str;

    /// Whether this stage can be skipped.
    fn is_skippable(&self) -> bool {
        false
    }
}

/// Decorator characters to strip when comparing titles.
const TITLE_DECORATORS: &[char] = &[
    '【', '】', '「', '」', '《', '》', '『', '』',
    '[', ']', '(', ')', '<', '>', '{', '}',
    '：', ':', '。', '.', '！', '!',
];

/// Stage 1: Remove duplicate title from chapter content.
///
/// Supports exact match, decorator-stripped match, and fuzzy match (edit distance).
pub struct DuplicateTitleRemover {
    /// Similarity threshold for fuzzy matching (0.0 - 1.0).
    pub fuzzy_threshold: f32,
    /// Max lines at the start of content to search for duplicate title.
    pub max_search_lines: usize,
}

impl Default for DuplicateTitleRemover {
    fn default() -> Self {
        Self {
            fuzzy_threshold: 0.8,
            max_search_lines: 5,
        }
    }
}

impl DuplicateTitleRemover {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_fuzzy_threshold(mut self, threshold: f32) -> Self {
        self.fuzzy_threshold = threshold;
        self
    }

    pub fn with_max_search_lines(mut self, max: usize) -> Self {
        self.max_search_lines = max;
        self
    }

    /// Clean a title by removing decorators and whitespace.
    fn clean_title(title: &str) -> String {
        title
            .chars()
            .filter(|c| !c.is_whitespace() && !TITLE_DECORATORS.contains(c))
            .collect()
    }

    /// Check if two strings are similar using edit distance.
    fn is_similar(s1: &str, s2: &str, threshold: f32) -> bool {
        if s1 == s2 {
            return true;
        }
        if s1.is_empty() || s2.is_empty() {
            return false;
        }
        // Contains check
        if s1.len() < s2.len() && s2.contains(s1) {
            return true;
        }
        if s2.len() < s1.len() && s1.contains(s2) {
            return true;
        }
        // Fuzzy match via levenshtein
        let distance = strsim::levenshtein(s1, s2);
        let max_len = s1.len().max(s2.len());
        if max_len == 0 {
            return false;
        }
        let similarity = 1.0 - (distance as f32 / max_len as f32);
        similarity >= threshold
    }

    /// Remove duplicate title from content.
    pub fn remove_duplicate(&self, content: &str, title: &str) -> String {
        if title.is_empty() {
            return content.to_string();
        }

        let title_clean = Self::clean_title(title);
        let lines: Vec<&str> = content.lines().collect();

        // Search in first N lines for a match
        for (i, line) in lines.iter().take(self.max_search_lines).enumerate() {
            let line_trimmed = line.trim();
            if line_trimmed.is_empty() {
                continue;
            }
            let line_clean = Self::clean_title(line_trimmed);

            if Self::is_similar(&title_clean, &line_clean, self.fuzzy_threshold) {
                // Skip matched line and leading blank lines
                return lines[(i + 1)..]
                    .iter()
                    .skip_while(|l| l.trim().is_empty())
                    .copied()
                    .collect::<Vec<_>>()
                    .join("\n");
            }
        }

        content.to_string()
    }
}

#[async_trait::async_trait]
impl ProcessingStage for DuplicateTitleRemover {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        let title = &input.chapter_title;
        if !title.is_empty() {
            input.content = self.remove_duplicate(&input.content, title);
        }
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "DuplicateTitleRemover"
    }
}

/// Stage 2: Re-segment paragraphs.
pub struct ResegmentProcessor;

#[async_trait::async_trait]
impl ProcessingStage for ResegmentProcessor {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        let content = &input.content;
        let mut result = String::with_capacity(content.len());
        let mut prev_was_newline = false;

        for ch in content.chars() {
            match ch {
                '\n' | '\r' => {
                    if !prev_was_newline {
                        result.push('\n');
                        prev_was_newline = true;
                    }
                }
                _ => {
                    result.push(ch);
                    prev_was_newline = false;
                }
            }
        }

        input.content = result;
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "ResegmentProcessor"
    }
}

/// Stage 3: Chinese conversion.
pub struct ChineseConvertStage {
    mode: super::chinese_converter::ConvertMode,
    converter: super::chinese_converter::ChineseConverter,
}

impl ChineseConvertStage {
    pub fn new(mode: super::chinese_converter::ConvertMode) -> Self {
        let converter = super::chinese_converter::ChineseConverter::new();
        Self { mode, converter }
    }
}

#[async_trait::async_trait]
impl ProcessingStage for ChineseConvertStage {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        input.content = self.converter.convert(&input.content, self.mode);
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "ChineseConvertStage"
    }

    fn is_skippable(&self) -> bool {
        true
    }
}

/// Stage 4: Protect HTML tags from modification.
pub struct HtmlProtector {
    placeholder_prefix: String,
}

impl Default for HtmlProtector {
    fn default() -> Self {
        Self {
            placeholder_prefix: "__HTML_PH_".to_string(),
        }
    }
}

#[async_trait::async_trait]
impl ProcessingStage for HtmlProtector {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        let html_regex = Regex::new(r"<[^>]+>")?;
        let mut html_map = HashMap::new();
        let mut counter: usize = 0;

        let protected = html_regex.replace_all(&input.content, |caps: &regex::Captures| {
            let placeholder = format!("{}{}__", self.placeholder_prefix, counter);
            html_map.insert(placeholder.clone(), caps[0].to_string());
            counter += 1;
            placeholder
        });

        input.content = protected.to_string();
        input.html_map = Some(html_map);
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "HtmlProtector"
    }
}

/// Stage 5: Apply string replace rules.
pub struct StringReplacer {
    rules: Vec<(String, String)>,
}

impl StringReplacer {
    pub fn new(rules: Vec<(String, String)>) -> Self {
        Self { rules }
    }
}

#[async_trait::async_trait]
impl ProcessingStage for StringReplacer {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        for (pattern, replacement) in &self.rules {
            input.content = input.content.replace(pattern, replacement);
        }
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "StringReplacer"
    }
}

/// Stage 6: Apply regex replace rules.
pub struct RegexReplacer {
    rules: Vec<(String, String)>,
}

impl RegexReplacer {
    pub fn new(rules: Vec<(String, String)>) -> Self {
        Self { rules }
    }
}

#[async_trait::async_trait]
impl ProcessingStage for RegexReplacer {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        for (pattern, replacement) in &self.rules {
            let re = Regex::new(pattern)?;
            input.content = re.replace_all(&input.content, replacement.as_str()).to_string();
        }
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "RegexReplacer"
    }
}

/// Stage 7: Execute JS rules.
///
/// 已改为经共享池执行（此前每条规则新建 QuickJS 实例 ~10–20ms，
/// 是池化要消除的反模式）。
#[cfg(feature = "js-engine")]
pub struct JsExecutor {
    rules: Vec<String>,
    js_context: super::js_runtime::JsExecContext,
    timeout_ms: u64,
}

#[cfg(feature = "js-engine")]
impl JsExecutor {
    pub fn new(rules: Vec<String>, js_context: super::js_runtime::JsExecContext) -> Self {
        Self {
            rules,
            js_context,
            timeout_ms: 1000,
        }
    }
}

#[cfg(feature = "js-engine")]
#[async_trait::async_trait]
impl ProcessingStage for JsExecutor {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        if self.rules.is_empty() {
            return Ok(input);
        }

        let pool = super::js_runtime_pool::global_pool();
        for rule in &self.rules {
            let mut ctx = self.js_context.clone();
            ctx.chapter_content = input.content.clone();

            // 持有守卫跨 await 安全：内部仅持 Arc<Mutex<JsRuntime>>，drop 时归还池
            let mut pooled = match pool.acquire().await {
                Ok(p) => p,
                Err(e) => {
                    log::warn!("JS stage skipped, pool unavailable: {}", e);
                    return Ok(input);
                }
            };
            match pooled.execute_async(rule, &ctx, self.timeout_ms).await {
                Ok(result) => {
                    if !result.is_empty() {
                        input.content = result;
                    }
                }
                Err(e) => {
                    log::warn!("JS rule execution failed: {}", e);
                    // Continue with original content on failure
                }
            }
        }

        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "JsExecutor"
    }

    fn is_skippable(&self) -> bool {
        self.rules.is_empty()
    }
}

/// Stage 8: Restore HTML tags from placeholders.
pub struct HtmlRestorer;

#[async_trait::async_trait]
impl ProcessingStage for HtmlRestorer {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        if let Some(html_map) = &input.html_map {
            for (placeholder, original) in html_map {
                input.content = input.content.replace(placeholder, original);
            }
        }
        input.html_map = None;
        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "HtmlRestorer"
    }
}

/// Stage: Execute JS rules using the shared pooled runtime.
///
/// 规则来自 `input.js_rules`（legado 风格：脚本以全局 `chapterContent`
/// 为输入，返回替换后全文）。单条规则失败仅跳过并告警，不中断流水线。
#[cfg(feature = "js-engine")]
pub struct JsExecutorWithPool {
    pool: Arc<super::js_runtime_pool::JsRuntimePool>,
    timeout_ms: u64,
}

#[cfg(feature = "js-engine")]
impl JsExecutorWithPool {
    pub fn new(pool: Arc<super::js_runtime_pool::JsRuntimePool>) -> Self {
        Self {
            pool,
            timeout_ms: 5000,
        }
    }

    pub fn with_timeout(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = timeout_ms;
        self
    }
}

#[cfg(feature = "js-engine")]
#[async_trait::async_trait]
impl ProcessingStage for JsExecutorWithPool {
    async fn process(&self, mut input: PipelineData) -> Result<PipelineData> {
        use crate::processing::js_runtime::JsExecContext;

        if input.js_rules.is_empty() {
            return Ok(input);
        }

        for rule in input.js_rules.iter().filter(|r| r.enabled) {
            let ctx = JsExecContext {
                chapter_title: input.chapter_title.clone(),
                chapter_index: input.chapter_index,
                book_title: input.book_title.clone(),
                chapter_content: input.content.clone(),
                ..Default::default()
            };

            let mut pooled = match self.pool.acquire().await {
                Ok(p) => p,
                Err(e) => {
                    log::warn!("JS stage skipped, pool unavailable: {}", e);
                    return Ok(input);
                }
            };

            let timeout = if rule.timeout_ms == 1000 {
                self.timeout_ms
            } else {
                rule.timeout_ms
            };
            match pooled.execute_async(&rule.pattern, &ctx, timeout).await {
                Ok(output) if !output.is_empty() => input.content = output,
                Ok(_) => log::warn!("JS rule returned empty content, keeping original"),
                Err(e) => log::warn!("JS rule failed (skipped): {}", e),
            }
        }

        Ok(input)
    }

    fn stage_name(&self) -> &'static str {
        "JsExecutorWithPool"
    }

    fn is_skippable(&self) -> bool {
        false // 已实现真语义：无规则时 process 内部直接短路
    }
}

use std::sync::Arc;

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_duplicate_title_remover_exact() {
        let stage = DuplicateTitleRemover::new();
        let input = PipelineData {
            content: "第一章 测试\n这是内容".to_string(),
            chapter_title: "第一章 测试".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "这是内容");
    }

    #[tokio::test]
    async fn test_duplicate_title_remover_with_decorators() {
        let stage = DuplicateTitleRemover::new();
        let input = PipelineData {
            content: "【第一章】新的开始\n正文内容...".to_string(),
            chapter_title: "第一章 新的开始".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "正文内容...");
    }

    #[tokio::test]
    async fn test_duplicate_title_remover_fuzzy() {
        let stage = DuplicateTitleRemover::new();
        let input = PipelineData {
            content: "第一章：新的开始\n正文内容...".to_string(),
            chapter_title: "第一章 新的开始".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "正文内容...");
    }

    #[tokio::test]
    async fn test_duplicate_title_remover_no_match() {
        let stage = DuplicateTitleRemover::new();
        let input = PipelineData {
            content: "这是一段正文内容...".to_string(),
            chapter_title: "第一章 开始".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "这是一段正文内容...");
    }

    #[tokio::test]
    async fn test_resegment_processor() {
        let stage = ResegmentProcessor;
        let input = PipelineData {
            content: "段落1\n\n\n\n段落2\r\n\r\n段落3".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "段落1\n段落2\n段落3");
    }

    #[tokio::test]
    async fn test_html_protector() {
        let stage = HtmlProtector::default();
        let input = PipelineData {
            content: "文字<b>粗体</b>更多".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert!(output.content.contains("__HTML_PH_0__"));
        assert!(output.content.contains("__HTML_PH_1__"));
        assert!(output.html_map.is_some());
        let map = output.html_map.unwrap();
        assert_eq!(map.len(), 2);
    }

    #[tokio::test]
    async fn test_string_replacer() {
        let stage = StringReplacer::new(vec![("测试".to_string(), "TEST".to_string())]);
        let input = PipelineData {
            content: "这是测试内容".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "这是TEST内容");
    }

    #[tokio::test]
    async fn test_regex_replacer() {
        let stage = RegexReplacer::new(vec![(
            r"\d{4}-\d{2}-\d{2}".to_string(),
            "[日期]".to_string(),
        )]);
        let input = PipelineData {
            content: "发布于2026-08-17的内容".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "发布于[日期]的内容");
    }

    #[tokio::test]
    async fn test_html_restorer() {
        let stage = HtmlRestorer;
        let mut html_map = std::collections::HashMap::new();
        html_map.insert("__HTML_PH_0__".to_string(), "<b>".to_string());
        html_map.insert("__HTML_PH_1__".to_string(), "</b>".to_string());

        let input = PipelineData {
            content: "文字__HTML_PH_0__粗体__HTML_PH_1__更多".to_string(),
            html_map: Some(html_map),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "文字<b>粗体</b>更多");
        assert!(output.html_map.is_none());
    }

    #[tokio::test]
    async fn test_chinese_convert_stage() {
        let stage = ChineseConvertStage::new(super::super::chinese_converter::ConvertMode::S2T);
        let input = PipelineData {
            content: "简体字".to_string(),
            ..Default::default()
        };
        let output = stage.process(input).await.unwrap();
        assert_eq!(output.content, "簡體字");
    }
}
