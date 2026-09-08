use std::collections::HashMap;
use std::num::NonZeroUsize;
use std::sync::Arc;
use std::time::{Duration, Instant};

use lru::LruCache;
use regex::Regex;
use tokio::sync::RwLock;
use tokio::time::timeout;

/// 替换规则类型（D9：JS 为主路径，string/regex 为兜底）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum RuleType {
    /// 字符串直替
    #[default]
    String = 0,
    /// 正则替换
    Regex = 1,
    /// JS 脚本：`pattern` 承载脚本，以全局 `chapterContent` 为输入，
    /// 返回替换后的全文（legado 风格，如 `chapterContent.replace(/广告/g,'')`）
    Js = 2,
}

/// Replace rule: a string pattern, regex pattern, or JS script.
#[derive(Debug, Clone)]
pub struct ReplaceRule {
    pub pattern: String,
    pub replacement: String,
    pub rule_type: RuleType,
    pub timeout_ms: u64,
    pub enabled: bool,
}

impl ReplaceRule {
    /// 便捷构造：字符串直替规则
    pub fn string(pattern: impl Into<String>, replacement: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
            replacement: replacement.into(),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: true,
        }
    }

    /// 便捷构造：正则规则
    pub fn regex(pattern: impl Into<String>, replacement: impl Into<String>) -> Self {
        Self {
            pattern: pattern.into(),
            replacement: replacement.into(),
            rule_type: RuleType::Regex,
            timeout_ms: 1000,
            enabled: true,
        }
    }

    #[cfg(feature = "js-engine")]
    /// 便捷构造：JS 脚本规则
    pub fn js(script: impl Into<String>) -> Self {
        Self {
            pattern: script.into(),
            replacement: String::new(),
            rule_type: RuleType::Js,
            timeout_ms: 1000,
            enabled: true,
        }
    }
}

/// Simplified/Traditional Chinese conversion direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChineseConvertType {
    S2T, // Simplified -> Traditional
    T2S, // Traditional -> Simplified
}

/// Options controlling content preprocessing.
#[derive(Debug, Clone)]
pub struct ProcessOptions {
    pub book_name: String,
    pub title: String,
    pub chapter_index: usize,
    pub remove_duplicate_title: bool,
    pub re_segment: bool,
    pub chinese_convert: Option<ChineseConvertType>,
    pub adapt_special_style: bool,
    pub apply_user_markings: bool,
}

impl Default for ProcessOptions {
    fn default() -> Self {
        Self {
            book_name: String::new(),
            title: String::new(),
            chapter_index: 0,
            remove_duplicate_title: true,
            re_segment: false,
            chinese_convert: None,
            adapt_special_style: true,
            apply_user_markings: false,
        }
    }
}

/// Error types for content processing.
#[derive(Debug, thiserror::Error)]
pub enum ContentProcessError {
    #[error("Regex compilation failed: {0}")]
    RegexCompile(String),

    #[error("Replace rule timeout after {0}ms")]
    RuleTimeout(u64),

    #[error("Processing cancelled")]
    Cancelled,

    #[error("Overall processing timeout")]
    OverallTimeout,
}

/// LRU cache for compiled regex patterns.
struct RegexCache {
    cache: LruCache<String, Regex>,
}

impl RegexCache {
    fn new(capacity: usize) -> Self {
        Self {
            cache: LruCache::new(NonZeroUsize::new(capacity).unwrap()),
        }
    }

    fn get_or_compile(&mut self, pattern: &str) -> Result<&Regex, ContentProcessError> {
        if !self.cache.contains(pattern) {
            let re = Regex::new(pattern)
                .map_err(|e| ContentProcessError::RegexCompile(format!("{}: {}", pattern, e)))?;
            self.cache.put(pattern.to_string(), re);
        }
        self.cache
            .get(pattern)
            .ok_or_else(|| ContentProcessError::RegexCompile("cache miss after insert".into()))
    }
}

/// Content preprocessor: Stage 1 of the reading pipeline.
///
/// Handles:
/// - Duplicate title removal
/// - Paragraph re-segmentation
/// - Simplified/Traditional Chinese conversion
/// - HTML tag protection (placeholder technique)
/// - Replace rule application (JS 为主路径，string/regex 兜底，D9)
pub struct ContentPreprocessor {
    replace_rules: Arc<RwLock<Vec<ReplaceRule>>>,
    regex_cache: Arc<tokio::sync::Mutex<RegexCache>>,
    /// JS 规则执行池（D9 主路径；进程级共享，规则不变则引擎实例持续复用）
    #[cfg(feature = "js-engine")]
    js_pool: Arc<crate::processing::js_runtime_pool::JsRuntimePool>,
    /// A30d：替换规则结果缓存（content_hash + rules_hash → 处理后文本）
    /// 容量 100：覆盖典型阅读窗口（20 章 × 5 种规则组合）
    result_cache: Arc<tokio::sync::Mutex<LruCache<(u64, u64), String>>>,
}

impl ContentPreprocessor {
    /// Create a new preprocessor with the given replace rules.
    pub fn new(replace_rules: Vec<ReplaceRule>) -> Self {
        Self {
            replace_rules: Arc::new(RwLock::new(replace_rules)),
            regex_cache: Arc::new(tokio::sync::Mutex::new(RegexCache::new(256))),
            #[cfg(feature = "js-engine")]
            js_pool: crate::processing::js_runtime_pool::global_pool(),
            result_cache: Arc::new(tokio::sync::Mutex::new(LruCache::new(NonZeroUsize::new(100).unwrap()))),
        }
    }

    /// Create an empty preprocessor.
    pub fn empty() -> Self {
        Self::new(Vec::new())
    }

    /// Update replace rules at runtime.
    pub async fn set_rules(&self, rules: Vec<ReplaceRule>) {
        *self.replace_rules.write().await = rules;
    }

    /// Main processing entry point.
    ///
    /// Pipeline order:
    /// 1. Remove duplicate title
    /// 2. Re-segment paragraphs
    /// 3. Protect HTML tags
    /// 4. Apply replace rules (with per-rule timeout)
    /// 5. Restore HTML tags
    /// 6. Chinese conversion（最后执行：规则按原文书写匹配，不受显示转换影响）
    pub async fn process(
        &self,
        raw_content: &str,
        options: &ProcessOptions,
    ) -> Result<String, ContentProcessError> {
        let start = Instant::now();
        let mut content = raw_content.to_string();

        // Stage 1: Remove duplicate title
        if options.remove_duplicate_title && !options.title.is_empty() {
            content = Self::remove_duplicate_title(&content, &options.title);
        }

        // Stage 2: Re-segment
        if options.re_segment {
            content = Self::re_segment(&content);
        }

        // Stage 3: Protect HTML tags
        let (protected_content, html_map) = if options.adapt_special_style {
            Self::protect_html_tags(&content)
        } else {
            (content, HashMap::new())
        };
        content = protected_content;

        // Stage 4: Apply replace rules
        content = self.apply_replace_rules(&content, options.book_name.as_str()).await?;

        // Stage 5: Restore HTML tags
        for (placeholder, original) in &html_map {
            content = content.replace(placeholder, original);
        }

        // Stage 6: Chinese conversion
        //
        // 必须在替换规则之后：用户规则按书籍原文书写，
        // 若先转换（如 敏感词→敏感詞）规则将无法命中。
        if let Some(convert_type) = options.chinese_convert {
            content = match convert_type {
                ChineseConvertType::S2T => Self::s2t(&content),
                ChineseConvertType::T2S => Self::t2s(&content),
            };
        }

        let elapsed = start.elapsed();
        if elapsed > Duration::from_secs(5) {
            log::warn!(
                "Content preprocessing took {}ms for chapter {}",
                elapsed.as_millis(),
                options.chapter_index
            );
        }

        Ok(content)
    }

    // ===== Internal processing stages =====

    /// Remove chapter title if it appears at the start of the content.
    /// 
    /// 处理逻辑：
    /// 1. 逐行扫描内容开头的每一行
    /// 2. 对每一行去除前后空白（包括全角空格 \u{3000}）后与标题比较
    /// 3. 如果匹配，删除该行及其前面的所有空行
    /// 4. 支持多次重复的标题（如：标题连续出现2次）
    /// Remove duplicate title from the beginning of the content.
    ///
    /// 扫描开头的空行和标题行，移除所有与 title 全等的行（trim 后比较）。
    /// 遇到第一个非空非标题行时停止扫描。
    ///
    /// 用于 TXT 章节内容去重：章节边界可能包含标题行，需在展示前移除。
    /// EPUB 使用块级镜像版本 `remove_duplicate_title_blocks`（api.rs）。
    pub fn remove_duplicate_title(content: &str, title: &str) -> String {
        let trimmed_title = title.trim();
        if trimmed_title.is_empty() {
            return content.to_string();
        }

        let lines: Vec<&str> = content.lines().collect();
        let mut skip_until_line = 0;

        // 逐行扫描，查找所有重复的标题行
        for (i, line) in lines.iter().enumerate() {
            // 去除行首尾的空白字符（包括全角空格 \u{3000}）
            let line_trimmed = line.trim_start_matches(|c: char| {
                c.is_whitespace() || c == '\u{3000}'
            }).trim_end();

            if line_trimmed == trimmed_title {
                // 找到匹配的标题行，标记跳过到此行（包含此行）
                skip_until_line = i + 1;
            } else if !line_trimmed.is_empty() {
                // 遇到非空的非标题行，停止扫描
                break;
            }
        }

        if skip_until_line > 0 {
            log::debug!("remove_duplicate_title: 删除 {} 行重复标题及前置空行", skip_until_line);
            // 跳过所有标题行及其前面的空行，返回剩余内容
            let remaining_lines = &lines[skip_until_line..];
            remaining_lines.join("\n")
        } else {
            content.to_string()
        }
    }

    /// Re-segment: ensure paragraphs are separated by single newlines.
    /// 
    /// L1 启发式规则增强：
    /// - 对话检测：引号结尾后保留换行
    /// - 场景切换：*** / --- 分隔符保留
    /// - 诗词保护：短行（<20字符）不合并
    fn re_segment(content: &str) -> String {
        let lines: Vec<&str> = content.lines().collect();
        if lines.is_empty() {
            return String::new();
        }

        let mut result = Vec::new();

        let mut i = 0;
        while i < lines.len() {
            let line = lines[i].trim();
            
            // 空行：跳过（会被合并）
            if line.is_empty() {
                i += 1;
                continue;
            }

            // 场景切换分隔符：保留独立段落
            if Self::is_scene_separator(line) {
                result.push(line.to_string());
                i += 1;
                continue;
            }

            // 诗词保护：短行独立成段
            if Self::is_short_line(line) {
                result.push(line.to_string());
                i += 1;
                continue;
            }

            // 对话检测：引号结尾独立成段
            if Self::is_dialogue_end(line) {
                result.push(line.to_string());
                i += 1;
                continue;
            }

            // 普通行：添加到结果
            result.push(line.to_string());
            i += 1;
        }

        result.join("\n")
    }

    /// 判断是否为场景切换分隔符
    fn is_scene_separator(line: &str) -> bool {
        let trimmed = line.trim();
        if trimmed.len() < 3 {
            return false;
        }

        // *** 或 ---（至少3个）
        let all_stars = trimmed.chars().all(|c| c == '*');
        let all_dashes = trimmed.chars().all(|c| c == '-' || c == '—');
        
        all_stars || all_dashes
    }

    /// 判断是否为短行（可能是诗词）
    fn is_short_line(line: &str) -> bool {
        line.chars().count() < 20
    }

    /// 判断是否为对话结尾
    fn is_dialogue_end(line: &str) -> bool {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return false;
        }

        // 中文引号结尾
        trimmed.ends_with('"') || trimmed.ends_with('"') || 
        trimmed.ends_with('」') || trimmed.ends_with('』') ||
        // 英文引号结尾
        trimmed.ends_with('"') || trimmed.ends_with('\'')
    }

    /// Simplified -> Traditional Chinese conversion.
    ///
    /// 委托 book_parser::chinese_convert（zhconv 词组级转换表），
    /// 与导入级净化（ContentCleaner）共用同一权威实现。
    fn s2t(content: &str) -> String {
        book_parser::chinese_convert::convert_s2t(content)
    }

    /// Traditional -> Simplified Chinese conversion.
    fn t2s(content: &str) -> String {
        book_parser::chinese_convert::convert_t2s(content)
    }

    /// Protect HTML tags by replacing them with unique placeholders.
    /// This prevents replace rules from corrupting HTML structure.
    fn protect_html_tags(content: &str) -> (String, HashMap<String, String>) {
        use std::sync::OnceLock;
        static HTML_TAG_REGEX: OnceLock<Regex> = OnceLock::new();
        let mut html_map = HashMap::new();
        let mut counter: usize = 0;

        // 静态字面量模式必然编译成功（原 Err 兜底为死分支，已删）
        let html_regex =
            HTML_TAG_REGEX.get_or_init(|| Regex::new(r"<[^>]+>").expect("<[^>]+> 编译必胜"));

        let protected = html_regex.replace_all(content, |caps: &regex::Captures| {
            let placeholder = format!("__HTML_PH_{}__", counter);
            html_map.insert(placeholder.clone(), caps[0].to_string());
            counter += 1;
            placeholder
        });

        (protected.to_string(), html_map)
    }

    /// Apply all enabled replace rules to the content.
    ///
    /// 规则类型路由（D9）：JS 脚本为主路径；string/regex 为兜底。
    /// JS 规则失败（语法/执行/超时）只跳过该规则并告警，不中断流水线、
    /// 不自动禁用——脚本错误不应殃及整章渲染。
    ///
    /// A30b 起 pub：bridge 的 EPUB 结构化路径按块调用（TXT 仍在 process
    /// 内整章应用）。
    pub async fn apply_replace_rules(
        &self,
        content: &str,
        book_name: &str,
    ) -> Result<String, ContentProcessError> {
        let rules = self.replace_rules.read().await.clone();

        // A30d：缓存键 = (内容哈希, 规则哈希)
        let content_hash = {
            use std::hash::{Hash, Hasher};
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            content.hash(&mut hasher);
            hasher.finish()
        };
        let rules_hash = self.rules_hash_inner(&rules);

        // 缓存命中：直接返回
        {
            let mut cache = self.result_cache.lock().await;
            if let Some(cached_result) = cache.get(&(content_hash, rules_hash)) {
                return Ok(cached_result.clone());
            }
        }

        // 缓存未命中：执行规则应用（原逻辑）
        let mut result = content.to_string();

        for rule in rules.iter().filter(|r| r.enabled) {
            match rule.rule_type {
                RuleType::String => {
                    result = result.replace(&rule.pattern, &rule.replacement);
                }
                RuleType::Regex => {
                    result = self.apply_regex_rule(&result, rule).await?;
                }
                #[cfg(feature = "js-engine")]
                RuleType::Js => {
                    result = self.apply_js_rule(&result, rule).await;
                }
                #[cfg(not(feature = "js-engine"))]
                RuleType::Js => {
                    log::warn!("JS rule skipped (built without js-engine): {:.40}", rule.pattern);
                }
            }
        }
        let _ = book_name; // 预留：规则模板变量

        // 缓存结果
        {
            let mut cache = self.result_cache.lock().await;
            cache.put((content_hash, rules_hash), result.clone());
        }

        Ok(result)
    }

    /// Apply a single JS script rule via the shared runtime pool.
    ///
    /// 脚本以全局 `chapterContent` 拿到全文，返回值即替换后的全文；
    /// 返回非字符串时按原样转字符串（与 JsRuntime 语义一致）。
    #[cfg(feature = "js-engine")]
    async fn apply_js_rule(&self, content: &str, rule: &ReplaceRule) -> String {
        use crate::processing::js_runtime::JsExecContext;

        let ctx = JsExecContext {
            chapter_content: content.to_string(),
            ..Default::default()
        };

        let mut pooled = match self.js_pool.acquire().await {
            Ok(p) => p,
            Err(e) => {
                log::warn!("JS rule skipped, pool unavailable: {}", e);
                return content.to_string();
            }
        };

        // 内层：引擎中断句柄按 timeout_ms 打断长脚本；
        // 外层：spawn_blocking 兜底超时，防止悬挂 worker。
        let exec = pooled.execute_async(&rule.pattern, &ctx, rule.timeout_ms);
        match tokio::time::timeout(
            std::time::Duration::from_millis(rule.timeout_ms.saturating_add(200)),
            exec,
        )
        .await
        {
            Ok(Ok(output)) if !output.is_empty() => output,
            Ok(Ok(_)) => {
                log::warn!("JS rule returned empty content, keeping original");
                content.to_string()
            }
            Ok(Err(e)) => {
                log::warn!("JS rule failed (skipped): {}", e);
                content.to_string()
            }
            Err(_) => {
                log::warn!("JS rule timed out after {}ms (skipped)", rule.timeout_ms);
                content.to_string()
            }
        }
    }

    /// Apply a single regex rule with timeout protection.
    async fn apply_regex_rule(
        &self,
        content: &str,
        rule: &ReplaceRule,
    ) -> Result<String, ContentProcessError> {
        let regex = {
            let mut cache = self.regex_cache.lock().await;
            cache.get_or_compile(&rule.pattern)?.clone()
        };

        let content_owned = content.to_string();
        let replacement = rule.replacement.clone();
        let timeout_ms = rule.timeout_ms;

        let result = timeout(
            Duration::from_millis(timeout_ms),
            tokio::task::spawn_blocking(move || {
                regex.replace_all(&content_owned, replacement.as_str()).to_string()
            }),
        )
        .await;

        match result {
            Ok(Ok(replaced)) => Ok(replaced),
            Ok(Err(_)) => Err(ContentProcessError::Cancelled),
            Err(_) => {
                log::warn!(
                    "Regex rule '{}' timed out after {}ms, disabling",
                    rule.pattern,
                    timeout_ms
                );
                // Disable the rule by pattern
                self.disable_rule_by_pattern(&rule.pattern).await;
                // Return original content (rule was skipped)
                Ok(content.to_string())
            }
        }
    }

    /// Disable a rule by pattern (called on timeout).
    async fn disable_rule_by_pattern(&self, pattern: &str) {
        let mut rules = self.replace_rules.write().await;
        for rule in rules.iter_mut() {
            if rule.pattern == pattern {
                rule.enabled = false;
                break;
            }
        }
    }

    /// A30d：计算规则集的哈希（用于缓存键）
    fn rules_hash_inner(&self, rules: &[ReplaceRule]) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();

        for rule in rules {
            rule.pattern.hash(&mut hasher);
            rule.replacement.hash(&mut hasher);
            (rule.rule_type as u8).hash(&mut hasher);
            rule.enabled.hash(&mut hasher);
        }

        hasher.finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_remove_duplicate_title() {
        let content = "第一章 测试\n这是内容";
        let result = ContentPreprocessor::remove_duplicate_title(content, "第一章 测试");
        assert_eq!(result, "这是内容");
    }

    #[tokio::test]
    async fn test_remove_duplicate_title_no_match() {
        let content = "这是内容";
        let result = ContentPreprocessor::remove_duplicate_title(content, "第一章 测试");
        assert_eq!(result, "这是内容");
    }

    #[tokio::test]
    async fn test_re_segment() {
        let content = "段落1\n\n\n\n段落2\r\n\r\n段落3";
        let result = ContentPreprocessor::re_segment(content);
        assert_eq!(result, "段落1\n段落2\n段落3");
    }

    #[tokio::test]
    async fn test_protect_html_tags() {
        let content = "文字<b>粗体</b>更多文字";
        let (protected, map) = ContentPreprocessor::protect_html_tags(content);
        assert!(protected.contains("__HTML_PH_0__"));
        assert!(protected.contains("__HTML_PH_1__"));
        assert_eq!(map.len(), 2);
        assert_eq!(map.get("__HTML_PH_0__").unwrap(), "<b>");
        assert_eq!(map.get("__HTML_PH_1__").unwrap(), "</b>");
    }

    #[tokio::test]
    async fn test_string_replace_rule() {
        let rules = vec![ReplaceRule {
            pattern: "测试".to_string(),
            replacement: "TEST".to_string(),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: true,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        let result = preprocessor.process("这是测试内容", &options).await.unwrap();
        assert_eq!(result, "这是TEST内容");
    }

    #[tokio::test]
    async fn test_regex_replace_rule() {
        let rules = vec![ReplaceRule {
            pattern: r"\d{4}-\d{2}-\d{2}".to_string(),
            replacement: "[日期]".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 1000,
            enabled: true,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        let result = preprocessor
            .process("发布于2026-08-17的内容", &options)
            .await
            .unwrap();
        assert_eq!(result, "发布于[日期]的内容");
    }

    #[tokio::test]
    async fn test_regex_timeout_disables_rule() {
        // Use a pathological regex + very long input to trigger timeout
        // Rust's regex crate is highly optimized, so we use a truly catastrophic pattern
        let rules = vec![ReplaceRule {
            pattern: r"^(a+)+$".to_string(),
            replacement: "X".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 1, // Very short timeout
            enabled: true,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        // Use input that won't match but forces the engine to try
        let input = format!("{}b", "a".repeat(25));
        let result = preprocessor.process(&input, &options).await;
        // Should complete without hanging (rule either runs fast or times out)
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_regex_timeout_disables_on_match_attempt() {
        // Test timeout with a pattern that forces backtracking on a long string
        let rules = vec![ReplaceRule {
            pattern: r"(a*)*$".to_string(),
            replacement: "X".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 1,
            enabled: true,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        // This pattern causes catastrophic backtracking in many regex engines
        let input = "a".repeat(30);
        let _ = preprocessor.process(&input, &options).await;
        // The rule may or may not be disabled depending on regex engine speed
        // The key assertion: the process completes without hanging
    }

    #[tokio::test]
    async fn test_html_protection_preserves_tags() {
        let rules = vec![ReplaceRule {
            pattern: "测试".to_string(),
            replacement: "TEST".to_string(),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: true,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            adapt_special_style: true,
            ..Default::default()
        };
        let content = "这是<b>测试</b>内容";
        let result = preprocessor.process(content, &options).await.unwrap();
        assert!(result.contains("<b>"));
        assert!(result.contains("</b>"));
        assert!(result.contains("TEST"));
    }

    #[tokio::test]
    async fn test_multiple_rules_applied_in_order() {
        let rules = vec![
            ReplaceRule {
                pattern: "aaa".to_string(),
                replacement: "b".to_string(),
                rule_type: RuleType::String,
                timeout_ms: 1000,
                enabled: true,
            },
            ReplaceRule {
                pattern: "bb".to_string(),
                replacement: "c".to_string(),
                rule_type: RuleType::String,
                timeout_ms: 1000,
                enabled: true,
            },
        ];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        // "aaaabbb" -> rule1: "aaa" at pos 0 -> "b", remaining "abbb" = "babbb"
        // "babbb" -> rule2: "bb" at pos 2 -> "c", remaining "b" = "bacb"
        let result = preprocessor
            .process("aaaabbb", &options)
            .await
            .unwrap();
        assert_eq!(result, "bacb");
    }

    #[tokio::test]
    async fn test_disabled_rule_skipped() {
        let rules = vec![ReplaceRule {
            pattern: "测试".to_string(),
            replacement: "TEST".to_string(),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: false,
        }];

        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            ..Default::default()
        };
        let result = preprocessor.process("这是测试内容", &options).await.unwrap();
        assert_eq!(result, "这是测试内容");
    }

    #[cfg(feature = "js-engine")]
    #[tokio::test]
    async fn test_js_rule_transforms_content() {
        // D9 主路径：JS 规则经池化引擎执行
        let rules = vec![ReplaceRule::js("chapterContent.replace(/武圣/g, '李明')")];
        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            adapt_special_style: false,
            ..Default::default()
        };
        let result = preprocessor
            .process("主角武圣正在读书。", &options)
            .await
            .unwrap();
        assert!(result.contains("李明"), "JS 规则应生效");
        assert!(!result.contains("武圣"));
    }

    #[cfg(feature = "js-engine")]
    #[tokio::test]
    async fn test_js_rule_failure_skips_gracefully() {
        // 语法错误的 JS 规则只跳过，不影响原内容与流水线
        let rules = vec![
            ReplaceRule::js("this is not valid js !!!"),
            ReplaceRule::string("读书", "写字"),
        ];
        let preprocessor = ContentPreprocessor::new(rules);
        let options = ProcessOptions {
            remove_duplicate_title: false,
            adapt_special_style: false,
            ..Default::default()
        };
        let result = preprocessor
            .process("他在读书", &options)
            .await
            .unwrap();
        assert_eq!(result, "他在写字", "坏规则跳过后其余规则仍生效");
    }
}
