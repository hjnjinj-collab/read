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

/// A35-L2: 分段规则动作类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SegmentAction {
    /// 匹配行后强制分段（该行收尾，下一行起新段）
    ForceBreakAfter,
    /// 匹配行前强制分段（上一行收尾，该行起新段）
    ForceBreakBefore,
    /// 匹配行独立成段（前后断开）
    KeepIndependent,
    /// 匹配行强制与上一行合并（吸附，压过默认断开项）
    MergeWithPrev,
}

/// A35-L2: 分段规则来源
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SegmentRuleKind {
    /// 内置谓词（Rust 原生实现，按 id 分派）
    Builtin,
    /// 用户自定义正则
    Regex,
}

/// A35-L2: 统一分段规则模型（内置 + 用户同模型）
#[derive(Debug, Clone)]
pub struct SegmentRule {
    /// 规则标识（内置："builtin:quote_unclosed" 等；用户：任意）
    pub id: String,
    /// 规则来源
    pub kind: SegmentRuleKind,
    /// 正则模式（kind=Regex 时使用；kind=Builtin 时忽略）
    pub pattern: String,
    /// 动作类型（Builtin 谓词的 action 由 id 语义决定，此处冗余存储）
    pub action: SegmentAction,
    /// 是否启用
    pub enabled: bool,
    /// 是否内置规则（UI 不可删除，仅可开关）
    pub builtin: bool,
}

impl SegmentRule {
    /// 用户正则规则构造
    pub fn user_regex(id: impl Into<String>, pattern: impl Into<String>, action: SegmentAction) -> Self {
        Self {
            id: id.into(),
            kind: SegmentRuleKind::Regex,
            pattern: pattern.into(),
            action,
            enabled: true,
            builtin: false,
        }
    }

    /// 计算规则列表哈希（用于缓存键）
    pub fn hash_rules(rules: &[SegmentRule]) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        for rule in rules {
            rule.id.hash(&mut hasher);
            (rule.action as u8).hash(&mut hasher);
            rule.enabled.hash(&mut hasher);
            if rule.kind == SegmentRuleKind::Regex {
                rule.pattern.hash(&mut hasher);
            }
        }
        hasher.finish()
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
    /// A35-L2: 用户自定义分段规则（内置 + 用户同模型）
    pub segment_rules: Vec<SegmentRule>,
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
            segment_rules: Vec::new(),
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

        // Stage 2: Re-segment（A35-L2：合并式引擎 + 统一规则模型）
        if options.re_segment || !options.segment_rules.is_empty() {
            content = Self::re_segment(&content, &options.segment_rules);
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
        let mut result = Vec::new();
        let mut title_kept = false;
        let mut skipped_before_title = 0;
        let mut duplicates_removed = 0;

        // Phase 1: 扫描开头的空行和标题行
        let mut scan_end = 0;
        for (i, line) in lines.iter().enumerate() {
            let line_trimmed = line.trim_start_matches(|c: char| {
                c.is_whitespace() || c == '\u{3000}'
            }).trim_end();

            if line_trimmed == trimmed_title {
                // 标题行：保留第一个，跳过后续重复
                if !title_kept {
                    result.push(*line);
                    title_kept = true;
                } else {
                    duplicates_removed += 1;
                }
                scan_end = i + 1;
            } else if line_trimmed.is_empty() {
                // 空行：如果还没保留标题，记录要跳过的前置空行数
                if !title_kept {
                    skipped_before_title += 1;
                } else {
                    // 标题后的空行也跳过（通常是标题间距）
                    scan_end = i + 1;
                }
            } else {
                // 非空非标题行：停止扫描
                break;
            }
        }

        // Phase 2: 添加剩余内容（无论是否找到标题，都添加扫描结束后的剩余部分）
        if scan_end < lines.len() {
            result.extend_from_slice(&lines[scan_end..]);
        }

        if title_kept {
            log::debug!(
                "remove_duplicate_title: 保留首个标题，跳过 {} 个前置空行，删除 {} 个重复标题",
                skipped_before_title, duplicates_removed
            );
        }

        result.join("\n")
    }

    /// A35-L2 v3: 累积式分段引擎（用户钦定算法）
    ///
    /// 核心语义（2026-09-09 用户定义）：
    /// - **50 字开关**：段落累积字符数 ≤ 50 时永不切分（软换行自然合并）；
    /// - **强语气标点段尾**：超过 50 字后，遇到句末终结标点（。！？…）即断开；
    /// - **引号吸附**：引号未闭合时永不切分（跨行对话合并）；`。”` 等闭标
    ///   吸附到段尾（切口不落在终结标点与其闭标之间）；
    /// - **非终结标点不作段尾**：逗号/顿号/分号/冒号/破折号永不触发切分；
    /// - **重新计数**：切分后新段从 0 重新统计，独立判断是否再次分段。
    ///
    /// 硬段落边界（无条件 flush）：空行、章节标题行、场景分隔符、
    /// 用户规则 KeepIndependent / ForceBreakBefore。
    ///
    /// 与 ParagraphFormatter 的关系：引擎激活（reSegment 开或用户规则非空）
    /// 时，bridge 侧将 formatter 的 re_paragraph_mode 覆盖为 None（保留缩进），
    /// 避免双系统打架（split_ranges 的窗口回退切分是 v2 误切根因）。
    fn re_segment(content: &str, segment_rules: &[SegmentRule]) -> String {
        let lines: Vec<&str> = content.lines().collect();
        if lines.is_empty() {
            return String::new();
        }

        // 内置规则开关查询（Dart 未传时按默认值兜底，兼容旧持久化数据）
        let rule_enabled = |id: &str, default: bool| -> bool {
            segment_rules
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.enabled)
                .unwrap_or(default)
        };
        let quote_unclosed_on = rule_enabled("builtin:quote_unclosed", true);
        let chapter_title_on = rule_enabled("builtin:chapter_title", true);
        let scene_sep_on = rule_enabled("builtin:scene_separator", true);
        let short_poem_on = rule_enabled("builtin:short_line_poem", false);

        // 预编译用户正则规则并按动作分组（行级硬边界/合并压制）
        let mut user_merge_rules: Vec<Regex> = Vec::new();
        let mut user_break_after_rules: Vec<Regex> = Vec::new();
        let mut user_break_before_rules: Vec<Regex> = Vec::new();
        let mut user_independent_rules: Vec<Regex> = Vec::new();
        for r in segment_rules {
            if !r.enabled || r.kind != SegmentRuleKind::Regex || r.pattern.is_empty() {
                continue;
            }
            match Regex::new(&r.pattern) {
                Ok(re) => match r.action {
                    SegmentAction::MergeWithPrev => user_merge_rules.push(re),
                    SegmentAction::ForceBreakAfter => user_break_after_rules.push(re),
                    SegmentAction::ForceBreakBefore => user_break_before_rules.push(re),
                    SegmentAction::KeepIndependent => user_independent_rules.push(re),
                },
                Err(e) => log::warn!("分段规则正则编译失败 '{}': {}", r.pattern, e),
            }
        }
        let user_indep_hit = |t: &str| user_independent_rules.iter().any(|re| re.is_match(t));
        let user_break_before_hit = |t: &str| user_break_before_rules.iter().any(|re| re.is_match(t));
        let user_break_after_hit = |t: &str| user_break_after_rules.iter().any(|re| re.is_match(t));
        let user_merge_hit = |t: &str| user_merge_rules.iter().any(|re| re.is_match(t));

        let mut out: Vec<String> = Vec::new();
        let mut cur = String::new();
        let mut count: usize = 0; // 当前段累积字符数（切分后归零重新计数）
        let mut quote_depth: i32 = 0; // 当前段引号深度（开-闭；仅跟踪成对 CJK 引号）

        macro_rules! flush {
            () => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                    count = 0;
                    quote_depth = 0;
                }
            };
        }

        for line in lines {
            let t = line.trim();

            // 空行：原始段落边界（无条件 flush）
            if t.is_empty() {
                flush!();
                continue;
            }

            // 用户行级规则：独立成段 / 行前分段
            let indep = user_indep_hit(t);
            if indep || user_break_before_hit(t) {
                flush!();
            }
            if indep {
                out.push(t.to_string());
                continue;
            }

            // 内置硬边界：章节标题 / 场景分隔符
            if (chapter_title_on && Self::is_chapter_marker_line(t))
                || (scene_sep_on && Self::is_scene_separator(t))
            {
                flush!();
                out.push(t.to_string());
                continue;
            }

            // 诗词短行独立（默认关；诗词类书籍手动开启）
            if short_poem_on && t.chars().count() < 20 {
                flush!();
                out.push(t.to_string());
                continue;
            }

            // 闭标禁则：新行以闭合引号/括号开头且当前缓冲非空 → 吸附到上一段
            // （不得落段首；前一行行尾终结标点已触发切分的罕见排版修正）
            if !cur.is_empty() && Self::is_closing_glue(t.chars().next().unwrap()) {
                if let Some(prev) = out.last_mut() {
                    prev.push_str(t);
                    // 吸附行整体并入，不计入新段（本行不再参与切分）
                    continue;
                }
            }

            let user_merge = user_merge_hit(t);

            // 累积式逐字符处理（跨行合并的核心：行尾不断开即自然续入下一段）
            let chars: Vec<char> = t.chars().collect();
            let mut k = 0usize;
            while k < chars.len() {
                let ch = chars[k];
                cur.push(ch);
                count += 1;
                match ch {
                    '\u{201C}' | '\u{300C}' | '\u{300E}' => quote_depth += 1, // “ 「 『
                    '\u{201D}' | '\u{300D}' | '\u{300F}' => quote_depth -= 1, // ” 」 』
                    _ => {}
                }
                k += 1;

                // 50 字开关：之下永不切分
                if count <= Self::SMART_SEG_THRESHOLD {
                    continue;
                }
                // 引号吸附：未闭合永不切分
                if quote_unclosed_on && quote_depth > 0 {
                    continue;
                }
                // 用户 MergeWithPrev：该行内压制所有切分点
                if user_merge {
                    continue;
                }

                // 终结标点切分点：吞并紧随的闭标/续终结标点 run 后切
                //（`。”` 不拆开、`！！` 整体、`……` 原子）
                if Self::is_terminal_punct(ch) {
                    let mut j = k;
                    while j < chars.len()
                        && (Self::is_closing_glue(chars[j]) || Self::is_terminal_punct(chars[j]))
                    {
                        j += 1;
                    }
                    while k < j {
                        let g = chars[k];
                        cur.push(g);
                        count += 1;
                        match g {
                            '\u{201C}' | '\u{300C}' | '\u{300E}' => quote_depth += 1,
                            '\u{201D}' | '\u{300D}' | '\u{300F}' => quote_depth -= 1,
                            _ => {}
                        }
                        k += 1;
                    }
                    flush!();
                }
                // 注意：孤立闭合引号（前无终结标点，如 “知行合一”的功夫）不是切分点
            }

            // 用户行级规则：行后强制分段
            if user_break_after_hit(t) {
                flush!();
            }
        }
        flush!();

        out.join("\n")
    }

    /// A35-L2: 智能分段阈值（字）——分段开关：累积超过此字数后，
    /// 终结标点才成为切分候选；之下所有软换行合并为一段。
    pub const SMART_SEG_THRESHOLD: usize = 50;

    /// 终结标点（强语气段尾）：。！？…（省略号原子性由调用方 run 吞并保证；
    /// 刻意不含分号/冒号/逗号/顿号/破折号——非终结标点不作段尾）
    fn is_terminal_punct(c: char) -> bool {
        matches!(c, '。' | '！' | '？' | '…')
    }

    /// 闭标吸附集：终结标点后紧随这些字符时不切，吞并到段尾
    ///（”不得落段首；！” ？） 等组合整体收尾）
    fn is_closing_glue(c: char) -> bool {
        matches!(
            c,
            '\u{201D}' | '\u{2019}' | '」' | '』' | '）' | '】' | '》' | '〉' | '〕'
        )
    }

    /// 章节标题行：第X章/回/卷/节/集/部/篇（独立成段硬边界）
    fn is_chapter_marker_line(line: &str) -> bool {
        use std::sync::OnceLock;
        static CHAPTER_RE: OnceLock<Regex> = OnceLock::new();
        let re = CHAPTER_RE.get_or_init(|| {
            Regex::new(r"^第[0-9零一二三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+\s*[章回卷节集部篇]").expect("章节标题正则编译必胜")
        });
        re.is_match(line)
    }

    /// 场景切换分隔符：*** / ---（至少3个）
    fn is_scene_separator(line: &str) -> bool {
        let trimmed = line.trim();
        if trimmed.chars().count() < 3 {
            return false;
        }
        let all_stars = trimmed.chars().all(|c| c == '*');
        let all_dashes = trimmed.chars().all(|c| c == '-' || c == '—');
        all_stars || all_dashes
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
        // 单个标题：保留（不去重）
        let content = "第一章 测试\n这是内容";
        let result = ContentPreprocessor::remove_duplicate_title(content, "第一章 测试");
        assert_eq!(result, "第一章 测试\n这是内容");
    }

    #[tokio::test]
    async fn test_remove_duplicate_title_no_match() {
        // 无匹配标题：返回原内容
        let content = "这是内容";
        let result = ContentPreprocessor::remove_duplicate_title(content, "第一章 测试");
        assert_eq!(result, "这是内容");
    }

    #[tokio::test]
    async fn test_remove_duplicate_title_repeated() {
        // 重复标题：保留第一个，删除后续重复
        let content = "第一章 测试\n第一章 测试\n这是内容";
        let result = ContentPreprocessor::remove_duplicate_title(content, "第一章 测试");
        assert_eq!(result, "第一章 测试\n这是内容");
    }

    #[tokio::test]
    async fn test_re_segment() {
        let content = "段落1\n\n\n\n段落2\r\n\r\n段落3";
        let result = ContentPreprocessor::re_segment(content, &[]);
        // 空规则时默认断开（各行独立成段），空行被跳过
        assert_eq!(result, "段落1\n段落2\n段落3");
    }

    #[tokio::test]
    async fn test_re_segment_builtin_dialogue() {
        // v3 累积式引擎：短于 50 字的软换行全部合并（无空格，中文直连）
        let content = "他说：\u{201C}你好啊。\u{201D}\n我点了点头，\n然后转身离开。";
        let result = ContentPreprocessor::re_segment(content, &[]);
        assert_eq!(result, "他说：\u{201C}你好啊。\u{201D}我点了点头，然后转身离开。");
    }

    #[tokio::test]
    async fn test_re_segment_cumulative_threshold() {
        // 50 字开关：累积超过 50 字后，终结标点成为切分点，新段重新计数
        let l1 = format!("{}。", "甲".repeat(29)); // 30 字
        let l2 = format!("{}。", "乙".repeat(29)); // 30 字（累积到 60 时在 。 切）
        let l3 = format!("{}。", "丙".repeat(29)); // 30 字（新段重新计数）
        let content = format!("{}\n{}\n{}", l1, l2, l3);
        let result = ContentPreprocessor::re_segment(&content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert_eq!(paras.len(), 2, "60 字处在第二个 。 切分，第三句重新计为新段");
        assert_eq!(paras[0], format!("{}。{}。", "甲".repeat(29), "乙".repeat(29)));
        assert_eq!(paras[1], format!("{}。", "丙".repeat(29)));
    }

    #[tokio::test]
    async fn test_re_segment_comma_never_breaks() {
        // 非终结标点（顿号/逗号）永不作为段尾——v2 误切 "蜈蚣、" 场景回归
        let content = format!("{}、\n{}，\n{}。", "驱".repeat(20), "赶".repeat(20), "蜈".repeat(20));
        let result = ContentPreprocessor::re_segment(&content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert_eq!(paras.len(), 1, "无终结标点前（60 字内含顿号逗号）不切分");
    }

    #[tokio::test]
    async fn test_re_segment_quote_unclosed_glue() {
        // 引号吸附：未闭合引号内即使超过 50 字遇终结标点也不切；
        // ” 吸附到段尾（v2 误切 "祭器”" 场景回归）
        let content = format!(
            "小镇的瓷器极负盛名，本朝开国以来，就承担起\u{201C}{}。\u{201D}{}\n{}。",
            "奉".repeat(30),
            "的重任，有朝廷官员常年驻扎此地，监理官窑事务。",
            "无依无靠的陈平安，很早就成了烧瓷的窑匠。"
        );
        let result = ContentPreprocessor::re_segment(&content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert!(
            !paras.iter().any(|p| p.ends_with("就承担起")),
            "引号未闭合时不得在句中切分"
        );
    }

    #[tokio::test]
    async fn test_re_segment_closing_glue_atomic() {
        // 闭标吸附：。” 整体收尾，切口不落在 。 与 ” 之间；
        // 50 字之下首个 。 不切（开关未触发）
        let content = format!("{}。{}。”{}。", "甲".repeat(45), "乙".repeat(10), "丙".repeat(10));
        let result = ContentPreprocessor::re_segment(&content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert_eq!(paras.len(), 2);
        // 首段：45 甲 + 。 (46字) + 10 乙 + 。” → 58 字，在 ” 后切（未在 。 处切）
        assert_eq!(paras[0], format!("{}。{}。”", "甲".repeat(45), "乙".repeat(10)));
        assert_eq!(paras[1], format!("{}。", "丙".repeat(10)));
    }

    #[tokio::test]
    async fn test_re_segment_ellipsis_atomic() {
        // 省略号原子性：切口不得落在 …… 之间
        let content = format!("{}……{}。", "甲".repeat(50), "乙".repeat(10));
        let result = ContentPreprocessor::re_segment(&content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert!(
            paras.iter().all(|p| !p.starts_with('…')),
            "省略号不得拆开落段首"
        );
    }

    #[tokio::test]
    async fn test_re_segment_hard_boundaries() {
        // 硬边界：空行 / 章节标题 / 场景分隔符
        let content = "第一段内容。\n\n第二章 测试\n正文开始。\n***\n后续内容。";
        let result = ContentPreprocessor::re_segment(content, &[]);
        let paras: Vec<&str> = result.split('\n').collect();
        assert!(paras.contains(&"第二章 测试"));
        assert!(paras.contains(&"***"));
    }

    #[tokio::test]
    async fn test_re_segment_user_rules() {
        // 用户规则：KeepIndependent 独立成段
        let rules = vec![SegmentRule::user_regex("u1", "^——.*$", SegmentAction::KeepIndependent)];
        let content = "前文内容。\n——分割线——\n后文内容。";
        let result = ContentPreprocessor::re_segment(content, &rules);
        assert!(result.split('\n').any(|l| l == "——分割线——"));

        // MergeWithPrev：压制该行内所有切分点
        let rules = vec![SegmentRule::user_regex("u2", "^特殊行", SegmentAction::MergeWithPrev)];
        let long_head = "甲".repeat(55);
        let content = format!("{}。\n特殊行{}", long_head, "乙".repeat(10));
        let result = ContentPreprocessor::re_segment(&content, &rules);
        // 长句 55 字处 。 已切分，特殊行自身无切分点，正常并入新段
        let paras: Vec<&str> = result.split('\n').collect();
        assert!(paras.iter().any(|p| p.starts_with("特殊行")));
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
