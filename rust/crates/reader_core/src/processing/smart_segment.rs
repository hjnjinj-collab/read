//! 统一智能分段核（A35 语义，TXT 行流 / EPUB 块内共用）
//!
//! 产品契约：对纯文本长段落做智能重分段。默认阈值 50 字（可配）；
//! 强语气终结构（。！…）+ 引号吸附 + 闭标禁则；可叠加用户规则。
//! 表格/图片等非纯文本块不参与（调用方保证只喂纯文本段）。

use regex::Regex;
use std::sync::OnceLock;

/// 分段规则动作类型
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

/// 分段规则来源
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SegmentRuleKind {
    /// 内置谓词（按 id 分派）
    Builtin,
    /// 用户自定义正则
    Regex,
}

/// 统一分段规则模型（内置 + 用户同模型）
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
    pub fn user_regex(
        id: impl Into<String>,
        pattern: impl Into<String>,
        action: SegmentAction,
    ) -> Self {
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

/// 默认智能分段阈值（字）。用户可在设置面板调节。
pub const DEFAULT_SEG_THRESHOLD: usize = 50;

/// 引擎配置（由规则列表 + 阈值解析而来）
pub struct SmartSegConfig {
    pub threshold: usize,
    pub quote_unclosed: bool,
    pub chapter_title: bool,
    pub scene_sep: bool,
    pub short_poem: bool,
    pub user_merge: Vec<Regex>,
    pub user_break_after: Vec<Regex>,
    pub user_break_before: Vec<Regex>,
    pub user_independent: Vec<Regex>,
}

impl SmartSegConfig {
    /// 从规则列表解析配置（Dart 未传内置项时按默认兜底）
    pub fn from_rules(threshold: usize, rules: &[SegmentRule]) -> Self {
        let rule_enabled = |id: &str, default: bool| -> bool {
            rules
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.enabled)
                .unwrap_or(default)
        };
        let mut user_merge = Vec::new();
        let mut user_break_after = Vec::new();
        let mut user_break_before = Vec::new();
        let mut user_independent = Vec::new();
        for r in rules {
            if !r.enabled || r.kind != SegmentRuleKind::Regex || r.pattern.is_empty() {
                continue;
            }
            match Regex::new(&r.pattern) {
                Ok(re) => match r.action {
                    SegmentAction::MergeWithPrev => user_merge.push(re),
                    SegmentAction::ForceBreakAfter => user_break_after.push(re),
                    SegmentAction::ForceBreakBefore => user_break_before.push(re),
                    SegmentAction::KeepIndependent => user_independent.push(re),
                },
                Err(e) => log::warn!("分段规则正则编译失败 '{}': {}", r.pattern, e),
            }
        }
        Self {
            threshold: threshold.max(1),
            quote_unclosed: rule_enabled("builtin:quote_unclosed", true),
            chapter_title: rule_enabled("builtin:chapter_title", true),
            scene_sep: rule_enabled("builtin:scene_separator", true),
            short_poem: rule_enabled("builtin:short_line_poem", false),
            user_merge,
            user_break_after,
            user_break_before,
            user_independent,
        }
    }

    /// 默认配置（阈值 50 + 内置默认规则，无用户正则）
    pub fn default_with_threshold(threshold: usize) -> Self {
        Self::from_rules(threshold, &[])
    }
}

/// 终结标点（强语气段尾）：。！？…（省略号原子性由 run 吞并 + 跨行 defer 保证；
/// 刻意不含分号/冒号/逗号/顿号/破折号——非终结标点不作段尾）
pub fn is_terminal_punct(c: char) -> bool {
    matches!(c, '。' | '！' | '？' | '…')
}

/// 次级标点：无终结构时的硬上限兜底切点（仍吞并紧随闭标）
pub fn is_secondary_punct(c: char) -> bool {
    matches!(c, '，' | '、' | '；' | '：' | ',' | ';' | ':')
}

/// 硬上限：累积超过此长度仍无终结构时强制切开（2×阈值，至少阈值+10）
pub fn hard_limit(threshold: usize) -> usize {
    threshold.saturating_mul(2).max(threshold.saturating_add(10))
}

/// 在 buf 中自 from 起找最后一次级标点，切开为 (前段, 剩余)；找不到返回 None
fn split_at_last_secondary(buf: &str, from: usize) -> Option<(String, String)> {
    let chars: Vec<char> = buf.chars().collect();
    if chars.len() <= from {
        return None;
    }
    let pos = chars[from..]
        .iter()
        .rposition(|&c| is_secondary_punct(c))
        .map(|i| i + from)?;
    let head: String = chars[..=pos].iter().collect();
    let tail: String = chars[pos + 1..].iter().collect();
    Some((head, tail))
}

fn recount_quote_depth(s: &str) -> i32 {
    let mut d = 0i32;
    for c in s.chars() {
        if is_open_quote(c) {
            d += 1;
        } else if is_close_quote(c) {
            d -= 1;
        }
    }
    d
}

/// 闭标吸附集：终结标点后紧随这些字符时不切，吞并到段尾
///（”不得落段首；！” ？） 等组合整体收尾）
pub fn is_closing_glue(c: char) -> bool {
    matches!(
        c,
        '\u{201D}' | '\u{2019}' | '」' | '』' | '）' | '】' | '》' | '〉' | '〕'
    )
}

fn is_open_quote(c: char) -> bool {
    // 简体弯引号 / 繁体直角引号「」『』/ 繁体双直角 〝 / 竖排﹁
    matches!(
        c,
        '\u{201C}' | '\u{300C}' | '\u{300E}' | '\u{301D}' | '\u{FE41}'
    )
}

fn is_close_quote(c: char) -> bool {
    matches!(
        c,
        '\u{201D}' | '\u{300D}' | '\u{300F}' | '\u{301E}' | '\u{301F}' | '\u{FE42}'
    )
}

/// 章节标题行：第X章/回/卷/节/集/部/篇（独立成段硬边界）
pub fn is_chapter_marker_line(line: &str) -> bool {
    static CHAPTER_RE: OnceLock<Regex> = OnceLock::new();
    let re = CHAPTER_RE.get_or_init(|| {
        Regex::new(
            r"^第[0-9零一二三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+\s*[章回卷节集部篇]",
        )
        .expect("章节标题正则编译必胜")
    });
    re.is_match(line)
}

/// 场景切换分隔符：*** / ---（至少3个）
pub fn is_scene_separator(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.chars().count() < 3 {
        return false;
    }
    let all_stars = trimmed.chars().all(|c| c == '*');
    let all_dashes = trimmed.chars().all(|c| c == '-' || c == '—');
    all_stars || all_dashes
}

/// TXT：行流 → 段落文本（换行连接）
pub fn segment_lines(content: &str, config: &SmartSegConfig) -> Vec<String> {
    let lines: Vec<&str> = content.lines().collect();
    if lines.is_empty() {
        return Vec::new();
    }

    let user_indep_hit = |t: &str| config.user_independent.iter().any(|re| re.is_match(t));
    let user_break_before_hit =
        |t: &str| config.user_break_before.iter().any(|re| re.is_match(t));
    let user_break_after_hit =
        |t: &str| config.user_break_after.iter().any(|re| re.is_match(t));
    let user_merge_hit = |t: &str| config.user_merge.iter().any(|re| re.is_match(t));

    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut count: usize = 0;
    let mut quote_depth: i32 = 0;
    // 行尾省略号 defer：不在行末 … 处 flush，与下一行行首 … 连成原子 run
    let mut pending_ellipsis_eol = false;

    macro_rules! flush {
        () => {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
                count = 0;
                quote_depth = 0;
            }
            pending_ellipsis_eol = false;
        };
    }

    for line in lines {
        let t = line.trim();

        if t.is_empty() {
            flush!();
            continue;
        }

        // 行尾 … 与本行行首 … 续接；否则先收掉上一段
        if pending_ellipsis_eol {
            if !t.starts_with('…') {
                flush!();
            }
            // starts_with('…') 时保持 cur，继续累积
            pending_ellipsis_eol = false;
        }

        let indep = user_indep_hit(t);
        if indep || user_break_before_hit(t) {
            flush!();
        }
        if indep {
            out.push(t.to_string());
            continue;
        }

        if (config.chapter_title && is_chapter_marker_line(t))
            || (config.scene_sep && is_scene_separator(t))
        {
            flush!();
            out.push(t.to_string());
            continue;
        }

        if config.short_poem && t.chars().count() < 20 {
            flush!();
            out.push(t.to_string());
            continue;
        }

        // 闭标禁则：新行以闭合引号/括号开头且当前缓冲非空 → 吸附到上一段
        if !cur.is_empty() && t.starts_with(|c| is_closing_glue(c)) {
            if let Some(prev) = out.last_mut() {
                prev.push_str(t);
                continue;
            }
        }

        let user_merge = user_merge_hit(t);

        let chars: Vec<char> = t.chars().collect();
        let mut k = 0usize;
        while k < chars.len() {
            let ch = chars[k];
            cur.push(ch);
            count += 1;
            if is_open_quote(ch) {
                quote_depth += 1;
            } else if is_close_quote(ch) {
                quote_depth -= 1;
            }
            k += 1;

            if count <= config.threshold {
                continue;
            }
            // 引号吸附：未闭合时不打软终结构切分；
            // 但不得永久压制——硬上限兜底仍生效（防「」未闭合导致整章不切）
            let quote_blocks_soft = config.quote_unclosed && quote_depth > 0;
            if user_merge {
                continue;
            }

            if !quote_blocks_soft && is_terminal_punct(ch) {
                let mut j = k;
                while j < chars.len()
                    && (is_closing_glue(chars[j]) || is_terminal_punct(chars[j]))
                {
                    j += 1;
                }
                while k < j {
                    let g = chars[k];
                    cur.push(g);
                    count += 1;
                    if is_open_quote(g) {
                        quote_depth += 1;
                    } else if is_close_quote(g) {
                        quote_depth -= 1;
                    }
                    k += 1;
                }
                // 省略号跨行原子：行末 … 不立刻切，等下一行行首是否续 …
                let ends_with_ellipsis_eol =
                    k == chars.len() && cur.ends_with('…');
                if ends_with_ellipsis_eol {
                    pending_ellipsis_eol = true;
                } else {
                    flush!();
                }
            } else if count >= hard_limit(config.threshold) {
                // 无终结构兜底：次级标点优先，否则段内回溯次级，再否则硬切
                if is_secondary_punct(ch) {
                    let mut j = k;
                    while j < chars.len() && is_closing_glue(chars[j]) {
                        j += 1;
                    }
                    while k < j {
                        let g = chars[k];
                        cur.push(g);
                        count += 1;
                        k += 1;
                    }
                    flush!();
                } else if let Some((head, tail)) =
                    split_at_last_secondary(&cur, config.threshold)
                {
                    out.push(head);
                    quote_depth = recount_quote_depth(&tail);
                    count = tail.chars().count();
                    cur = tail;
                } else {
                    flush!();
                }
            }
        }

        if user_break_after_hit(t) {
            flush!();
        }
    }
    flush!();
    out
}

/// EPUB：单段纯文本 → 字符区间（升序无缝无叠，并集 = 全文；不切则单区间）
///
/// 与 `segment_lines` 同核：阈值 + 终结构 + 引号深度 + 闭标吸附。
/// 无行结构，故无跨行省略号 defer——run 吞并已保证 `……` 原子。
pub fn split_paragraph_ranges(text: &str, config: &SmartSegConfig) -> Vec<(usize, usize)> {
    let chars: Vec<char> = text.chars().collect();
    let total = chars.len();
    if total == 0 {
        return vec![(0, 0)];
    }

    // 整段命中 MergeWithPrev / 未超阈值 → 不切
    // （块级用户规则由调用方处理；此处仅压制段内切分）
    let block_merge = config
        .user_merge
        .iter()
        .any(|re| re.is_match(text));
    if block_merge || total <= config.threshold {
        return vec![(0, total)];
    }

    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut start = 0usize;
    let mut count = 0usize;
    let mut quote_depth = 0i32;
    let mut k = 0usize;

    while k < total {
        let ch = chars[k];
        count += 1;
        if is_open_quote(ch) {
            quote_depth += 1;
        } else if is_close_quote(ch) {
            quote_depth -= 1;
        }
        k += 1;

        if count <= config.threshold {
            continue;
        }
        // 引号吸附仅压制软终结构；硬上限仍强制切开
        let quote_blocks_soft = config.quote_unclosed && quote_depth > 0;

        if !quote_blocks_soft && is_terminal_punct(ch) {
            let mut j = k;
            while j < total && (is_closing_glue(chars[j]) || is_terminal_punct(chars[j])) {
                j += 1;
            }
            // 吞并 run 时同步更新引号深度与计数
            while k < j {
                let g = chars[k];
                count += 1;
                if is_open_quote(g) {
                    quote_depth += 1;
                } else if is_close_quote(g) {
                    quote_depth -= 1;
                }
                k += 1;
            }
            out.push((start, k));
            start = k;
            count = 0;
            quote_depth = 0;
        } else if count >= hard_limit(config.threshold) {
            // 无终结构兜底（与 segment_lines 同语义）
            if is_secondary_punct(ch) {
                let mut j = k;
                while j < total && is_closing_glue(chars[j]) {
                    j += 1;
                }
                while k < j {
                    let g = chars[k];
                    count += 1;
                    if is_open_quote(g) {
                        quote_depth += 1;
                    } else if is_close_quote(g) {
                        quote_depth -= 1;
                    }
                    k += 1;
                }
                out.push((start, k));
                start = k;
                count = 0;
                quote_depth = 0;
            } else {
                // 段内自 threshold 起回溯次级标点
                let piece: String = chars[start..k].iter().collect();
                if let Some((head, tail)) =
                    split_at_last_secondary(&piece, config.threshold)
                {
                    let cut = start + head.chars().count();
                    out.push((start, cut));
                    start = cut;
                    // tail 是当前段剩余，已含刚读入的 ch；k 不回退，count 按 tail 重算
                    count = tail.chars().count();
                    quote_depth = recount_quote_depth(&tail);
                } else {
                    out.push((start, k));
                    start = k;
                    count = 0;
                    quote_depth = 0;
                }
            }
        }
    }
    if start < total {
        out.push((start, total));
    }
    if out.is_empty() {
        out.push((0, total));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg50() -> SmartSegConfig {
        SmartSegConfig::default_with_threshold(DEFAULT_SEG_THRESHOLD)
    }

    fn cfg_n(n: usize) -> SmartSegConfig {
        SmartSegConfig::default_with_threshold(n)
    }

    #[test]
    fn short_lines_merge() {
        let content = "他说：\u{201C}你好啊。\u{201D}\n我点了点头，\n然后转身离开。";
        let paras = segment_lines(content, &cfg50());
        assert_eq!(
            paras,
            vec!["他说：\u{201C}你好啊。\u{201D}我点了点头，然后转身离开。"]
        );
    }

    #[test]
    fn cumulative_threshold_splits() {
        let l1 = format!("{}。", "甲".repeat(29));
        let l2 = format!("{}。", "乙".repeat(29));
        let l3 = format!("{}。", "丙".repeat(29));
        let content = format!("{}\n{}\n{}", l1, l2, l3);
        let paras = segment_lines(&content, &cfg50());
        assert_eq!(paras.len(), 2);
        assert_eq!(paras[0], format!("{}。{}。", "甲".repeat(29), "乙".repeat(29)));
        assert_eq!(paras[1], format!("{}。", "丙".repeat(29)));
    }

    #[test]
    fn comma_never_breaks() {
        let content = format!(
            "{}、\n{}，\n{}。",
            "驱".repeat(20),
            "赶".repeat(20),
            "蜈".repeat(20)
        );
        let paras = segment_lines(&content, &cfg50());
        assert_eq!(paras.len(), 1);
    }

    #[test]
    fn quote_unclosed_glue() {
        let content = format!(
            "小镇的瓷器极负盛名，本朝开国以来，就承担起\u{201C}{}。\u{201D}{}\n{}。",
            "奉".repeat(30),
            "的重任，有朝廷官员常年驻扎此地，监理官窑事务。",
            "无依无靠的陈平安，很早就成了烧瓷的窑匠。"
        );
        let paras = segment_lines(&content, &cfg50());
        assert!(!paras.iter().any(|p| p.ends_with("就承担起")));
    }

    #[test]
    fn closing_glue_atomic() {
        let content = format!(
            "{}。{}。”{}。",
            "甲".repeat(45),
            "乙".repeat(10),
            "丙".repeat(10)
        );
        let paras = segment_lines(&content, &cfg50());
        assert_eq!(paras.len(), 2);
        assert_eq!(
            paras[0],
            format!("{}。{}。”", "甲".repeat(45), "乙".repeat(10))
        );
    }

    #[test]
    fn ellipsis_same_line_atomic() {
        let content = format!("{}……{}。", "甲".repeat(50), "乙".repeat(10));
        let paras = segment_lines(&content, &cfg50());
        assert!(paras.iter().all(|p| !p.starts_with('…')));
    }

    #[test]
    fn ellipsis_across_soft_wrap_atomic() {
        // 行尾 … 与下一行行首 … 必须连成同一段，不得拆成「…」「…」
        let content = format!("{}…\n…{}。", "甲".repeat(52), "乙".repeat(5));
        let paras = segment_lines(&content, &cfg50());
        assert!(
            !paras.iter().any(|p| p.starts_with('…')),
            "跨行省略号不得拆开落段首: {:?}",
            paras
        );
        assert!(
            paras.iter().any(|p| p.contains("……")),
            "省略号对必须完整: {:?}",
            paras
        );
    }

    #[test]
    fn ellipsis_three_ideographic_fullstops_atomic() {
        // 「。。。」三个句号作为省略号观感时，同行 run 吞并不得拆开
        let content = format!("{}。。{}。", "甲".repeat(50), "乙".repeat(8));
        let paras = segment_lines(&content, &cfg50());
        assert!(paras.iter().all(|p| !p.starts_with('。')));
    }

    #[test]
    fn hard_boundaries() {
        let content = "第一段内容。\n\n第二章 测试\n正文开始。\n***\n后续内容。";
        let paras = segment_lines(content, &cfg50());
        assert!(paras.contains(&"第二章 测试".to_string()));
        assert!(paras.contains(&"***".to_string()));
    }

    #[test]
    fn user_rules() {
        let rules = vec![SegmentRule::user_regex(
            "u1",
            "^——.*$",
            SegmentAction::KeepIndependent,
        )];
        let cfg = SmartSegConfig::from_rules(50, &rules);
        let content = "前文内容。\n——分割线——\n后文内容。";
        let paras = segment_lines(content, &cfg);
        assert!(paras.iter().any(|l| l == "——分割线——"));
    }

    #[test]
    fn custom_threshold() {
        let content = format!("{}。{}。", "甲".repeat(30), "乙".repeat(30));
        let paras = segment_lines(&content, &cfg_n(20));
        assert!(paras.len() >= 2, "阈值 20 应切开: {:?}", paras);
    }

    #[test]
    fn ranges_cover_full_text() {
        let text = format!("{}。{}。{}。", "甲".repeat(40), "乙".repeat(40), "丙".repeat(40));
        let ranges = split_paragraph_ranges(&text, &cfg50());
        let total = text.chars().count();
        assert_eq!(ranges.first().map(|r| r.0), Some(0));
        assert_eq!(ranges.last().map(|r| r.1), Some(total));
        for w in ranges.windows(2) {
            assert_eq!(w[0].1, w[1].0, "区间必须无缝");
        }
        for &(s, e) in &ranges {
            assert!(e > s, "无空区间");
        }
    }

    #[test]
    fn ranges_ellipsis_atomic() {
        let text = format!("{}……{}。", "甲".repeat(50), "乙".repeat(10));
        let ranges = split_paragraph_ranges(&text, &cfg50());
        let chars: Vec<char> = text.chars().collect();
        for &(s, e) in &ranges {
            let piece: String = chars[s..e].iter().collect();
            assert!(!piece.starts_with('…'), "区间不得以省略号开头: {:?}", piece);
        }
    }

    #[test]
    fn ranges_short_no_split() {
        let text = "短段落。";
        let ranges = split_paragraph_ranges(text, &cfg50());
        assert_eq!(ranges, vec![(0, text.chars().count())]);
    }

    #[test]
    fn no_terminal_hard_limit_splits() {
        // 超 2×阈值仍无终结构 → 次级标点兜底切开
        let text = format!("{}，{}", "甲".repeat(55), "乙".repeat(55));
        let paras = segment_lines(&text, &cfg50());
        assert!(
            paras.len() >= 2,
            "无终结构长段应在硬上限附近切开: {:?}",
            paras.iter().map(|p| p.chars().count()).collect::<Vec<_>>()
        );
        let joined = paras.join("");
        assert_eq!(joined, text, "兜底切分不得丢字");
    }

    #[test]
    fn no_punct_at_all_hard_cuts() {
        // 全程无任何标点：硬上限处硬切
        let text = "甲".repeat(120);
        let paras = segment_lines(&text, &cfg50());
        assert!(paras.len() >= 2, "无标点 120 字应硬切: {}", paras.len());
        for p in &paras {
            assert!(
                p.chars().count() <= hard_limit(50) + 1,
                "片段过长 {}",
                p.chars().count()
            );
        }
        assert_eq!(paras.concat(), text);
    }

    #[test]
    fn ranges_no_terminal_hard_limit() {
        let text = format!("{}，{}", "甲".repeat(55), "乙".repeat(55));
        let ranges = split_paragraph_ranges(&text, &cfg50());
        assert!(ranges.len() >= 2, "EPUB 无终结构也应兜底切开");
        let total = text.chars().count();
        assert_eq!(ranges.first().map(|r| r.0), Some(0));
        assert_eq!(ranges.last().map(|r| r.1), Some(total));
    }

    #[test]
    fn quote_open_still_suppresses_soft_but_not_hard_limit() {
        // 引号未闭合：压制软终结构，但硬上限必须切开（A33.1：防整章不切）
        let text = format!("\u{300C}{}", "甲".repeat(120));
        let paras = segment_lines(&text, &cfg50());
        assert!(
            paras.len() >= 2,
            "未闭合直角引号下硬上限仍应切开: {}",
            paras.len()
        );
        assert_eq!(paras.concat(), text, "切分不得丢字");
    }

    #[test]
    fn traditional_corner_quotes_tracked() {
        // 繁体「」：闭合前不软切；闭合后累积超阈值再遇终结构可切
        let text = format!(
            "{}「{}。」{}。",
            "前".repeat(20),
            "话".repeat(40),
            "后".repeat(55)
        );
        let paras = segment_lines(&text, &cfg50());
        assert!(
            paras.len() >= 2,
            "闭合后应恢复软切: {:?}",
            paras.iter().map(|p| p.chars().count()).collect::<Vec<_>>()
        );
        assert!(paras.iter().any(|p| p.contains('「')));
    }
}
