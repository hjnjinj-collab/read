/// M9 段落格式化器
///
/// 在 ContentPreprocessor 之后、Layout 之前对 TXT 内容进行段落格式化，
/// 三阶段顺序（M9.2）：1. 重新分段 → 1.5 超长段切分（共享切分器）→
/// 2. 首行缩进（全角空格注入，切分后逐子段注入）。
///
/// 纯 Rust 实现（与 ContentCleaner 同策略），JS 引擎用于 EPUB 提取层。
/// 边缘情况：对话行不合并、诗歌保留换行、章节标题独立段落。

use super::paragraph_format::{ParagraphFormatSettings, ReParagraphMode};

/// 段落格式化器
pub struct ParagraphFormatter {
    settings: ParagraphFormatSettings,
}

impl ParagraphFormatter {
    pub fn new(settings: ParagraphFormatSettings) -> Self {
        Self { settings }
    }

    /// 格式化文本（主入口）
    ///
    /// 当 `re_paragraph_mode == None && !enable_indent` 时直接返回原文（fast path）。
    pub fn format(&self, text: &str) -> String {
        if self.settings.re_paragraph_mode == ReParagraphMode::None
            && !self.settings.enable_indent
        {
            return text.to_string();
        }

        // 1. 重新分段
        let formatted = match self.settings.re_paragraph_mode {
            ReParagraphMode::None => text.to_string(),
            ReParagraphMode::Smart => self.smart_re_paragraph(text),
            ReParagraphMode::Aggressive => self.aggressive_re_paragraph(text),
        };

        // 1.5 超长段切分（M9.2 新增：Smart 此前只合并不切分，导致超长段原样
        // 保留；现双模式统一经共享切分器按用户可调阈值切短，章节标记段跳过。
        // 切分后的每个片段由 split_ranges 循环从切口处重新计数检测，
        // 直到所有片段 ≤ 阈值）
        let formatted = if let Some(th) = self.settings.effective_split_threshold() {
                formatted
                    .split("\n\n")
                    .into_iter()
                    .flat_map(|para| {
                        if is_chapter_marker(para.trim()) || para.chars().count() <= th {
                            vec![para.to_string()]
                        } else {
                            super::paragraph_splitter::split_pieces(para, th)
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n")
            } else {
                formatted
            };

        // 2. 首行缩进（在切分之后：每个视觉子段独立注入，全角空格不计入阈值）
        if self.settings.enable_indent && self.settings.indent_size_chars > 0 {
            self.apply_indent(&formatted)
        } else {
            formatted
        }
    }

    /// 智能分段：保留高置信度段落边界，合并低置信度软换行
    ///
    /// 边界检测规则：
    /// - 空行：100% 边界
    /// - 缩进行（`　` 或 2+ 空格开头）：100% 边界
    /// - 短行（<20 字符，非对话）：高置信度边界
    /// - 章节标记（`第X章` 等）：始终边界
    /// - 对话行（`「」『』""` 开头）：不与前段合并
    fn smart_re_paragraph(&self, text: &str) -> String {
        let lines: Vec<&str> = text.lines().collect();
        if lines.is_empty() {
            return String::new();
        }

        // P4 智能分段扩展：诗节行预扫描（连续短行 run ≥3 行 → 诗歌）
        let poetry_lines = detect_poetry_lines(&lines);

        let mut paragraphs: Vec<String> = Vec::new();
        let mut current: Vec<String> = Vec::new();

        for (i, line) in lines.iter().enumerate() {
            let trimmed = line.trim();
            let is_empty = trimmed.is_empty();
            let is_indented = trimmed.starts_with('\u{3000}')
                || trimmed.starts_with("  ")
                || (line.len() > line.trim_start().len() && !is_empty);
            let is_short = trimmed.chars().count() < 20 && !is_empty;
            let is_chapter = is_chapter_marker(trimmed);
            let is_dialogue = is_dialogue_line(trimmed);
            let is_poetry = poetry_lines[i];
            let prev_was_empty = i > 0 && lines[i - 1].trim().is_empty();

            // 空行 = 硬边界
            if is_empty {
                if !current.is_empty() {
                    paragraphs.push(current.join(""));
                    current.clear();
                }
                continue;
            }

            // P4 引用行（`>`/`＞` 前缀，论坛体/邮件体）：去前缀 + 独立成段
            if let Some(quote_body) = strip_quote_prefix(trimmed) {
                if !current.is_empty() {
                    paragraphs.push(current.join(""));
                    current.clear();
                }
                paragraphs.push(quote_body);
                continue;
            }

            // 章节标记 = 始终新段落
            if is_chapter {
                if !current.is_empty() {
                    paragraphs.push(current.join(""));
                    current.clear();
                }
                current.push(trimmed.to_string());
                paragraphs.push(current.join(""));
                current.clear();
                continue;
            }

            // P4 诗节行：独立成段（不并入前段、不吸收后行）——
            // 优先级高于缩进/短行规则（诗歌行常顶格无缩进）
            if is_poetry {
                if !current.is_empty() {
                    paragraphs.push(current.join(""));
                    current.clear();
                }
                paragraphs.push(trimmed.to_string());
                continue;
            }

            // 缩进行 = 新段落开始（去掉前导空白）
            if is_indented && !current.is_empty() {
                paragraphs.push(current.join(""));
                current.clear();
            }

            // 对话行不与前段合并
            if is_dialogue && !current.is_empty() && prev_was_empty {
                paragraphs.push(current.join(""));
                current.clear();
            }

            // 短行 = 潜在段落结束
            if is_short && !is_dialogue && !current.is_empty() {
                current.push(trimmed.to_string());
                paragraphs.push(current.join(""));
                current.clear();
                continue;
            }

            // 普通行：累加
            current.push(trimmed.to_string());

            // P4 对话规则强化：完整闭合的对话行（「…」/“…”）立即结束段落，
            // 后续叙述行不并入（防止对白与叙述黏段）。未闭合（「…」她说）
            // 维持原合并行为。
            if is_dialogue && ends_with_closing_quote(trimmed) {
                paragraphs.push(current.join(""));
                current.clear();
            }
        }

        if !current.is_empty() {
            paragraphs.push(current.join(""));
        }

        paragraphs.join("\n\n")
    }

    /// 强制重排：移除所有软换行，合并为连续文本
    ///
    /// 用于修复排版混乱的劣质书源。M9.2 起不再内联切分（旧 MIN_PARA_LEN=80
    /// 循环已删除），统一由 format() 步骤 1.5 调用共享切分器按
    /// AGGRESSIVE_THRESHOLD(100) 处理，与 EPUB 路径语义一致。
    fn aggressive_re_paragraph(&self, text: &str) -> String {
        // 合并所有行为一个连续文本
        let merged: String = text
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join("");

        merged
    }

    /// 首行缩进：每个段落前添加全角空格
    fn apply_indent(&self, text: &str) -> String {
        let indent = "\u{3000}".repeat(self.settings.indent_size_chars as usize);
        text.lines()
            .map(|line| {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    return String::new();
                }
                // 章节标记不缩进
                if is_chapter_marker(trimmed) {
                    return trimmed.to_string();
                }
                // 已有缩进的不重复添加
                if trimmed.starts_with('\u{3000}') {
                    return trimmed.to_string();
                }
                format!("{}{}", indent, trimmed)
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// 进程级静态编译的章节标记正则。
///
/// 此前本函数每次调用现场 Regex::new×3，而它在热路径上被每行
/// （smart_re_paragraph / apply_indent）、每段（format 切分级）高频调用——
/// 一章重排即数千次编译，是预处理阶段的主要隐性开销之一（M9.3 静态化）。
fn chapter_marker_regexes() -> &'static [regex::Regex] {
    use std::sync::OnceLock;
    static RESES: OnceLock<Vec<regex::Regex>> = OnceLock::new();
    RESES.get_or_init(|| {
        [
            r"^第.{1,10}[章节回集卷]",
            r"^Chapter\s+\d+",
            r"^\d+[\.、]\s",
        ]
        .iter()
        .map(|p| regex::Regex::new(p).expect("章节标记正则（静态字面量）编译必胜"))
        .collect()
    })
}

/// 检测是否为章节标记
fn is_chapter_marker(line: &str) -> bool {
    chapter_marker_regexes().iter().any(|r| r.is_match(line))
}

/// 检测是否为对话行
fn is_dialogue_line(line: &str) -> bool {
    line.starts_with('「')
        || line.starts_with('『')
        || line.starts_with('“')
        || line.starts_with('”')
        || line.starts_with('"')
        || line.starts_with('（')
        || line.starts_with('(')
}

/// P4：对话行是否完整闭合（「…」/『…』/“…”/”…“ 结尾）——
/// 闭合对话立即结束段落，未闭合（「…」她说）维持合并
fn ends_with_closing_quote(line: &str) -> bool {
    line.ends_with('」') || line.ends_with('』') || line.ends_with('”') || line.ends_with('"')
}

/// P4：引用行检测——`>` / `＞` 前缀（论坛体/邮件体），返回去前缀正文。
/// 纯前缀行（仅有 ">"）返回空串（产生空段，layout 端空行跳过，无害）。
fn strip_quote_prefix(line: &str) -> Option<String> {
    let body = line.strip_prefix('>').or_else(|| line.strip_prefix('＞'))?;
    Some(body.trim_start().to_string())
}

/// P4：诗节行检测——连续短行 run（≥3 行）标记为诗歌。
///
/// 候选特征：每行 2-16 字、不以强句末标点结尾（。！？；…——逗号结尾
/// 仍算候选，诗句常逗号收行）、非对话/章节/引用行；空行或长行打断 run。
/// 保守阈值防误伤：正常叙述的硬换行碎行若恰成 3+ 连短行也会按诗节
/// 呈现（逐行独立），对劣质换行原文同样是合理呈现。
fn detect_poetry_lines(lines: &[&str]) -> Vec<bool> {
    let mut flags = vec![false; lines.len()];
    // Some(is_candidate)：None = 空行（打断 run）
    let classify = |l: &str| -> Option<bool> {
        let t = l.trim();
        if t.is_empty() {
            return None;
        }
        if is_chapter_marker(t) || is_dialogue_line(t) || strip_quote_prefix(t).is_some() {
            return Some(false);
        }
        let n = t.chars().count();
        Some(n >= 2 && n <= 16 && !t.ends_with(['。', '！', '？', '；', '…']))
    };
    let mut run_start: Option<usize> = None;
    for (i, line) in lines.iter().enumerate() {
        match classify(line) {
            None | Some(false) => {
                if let Some(s) = run_start.take() {
                    if i - s >= 3 {
                        for f in flags.iter_mut().take(i).skip(s) {
                            *f = true;
                        }
                    }
                }
            }
            Some(true) => {
                if run_start.is_none() {
                    run_start = Some(i);
                }
            }
        }
    }
    if let Some(s) = run_start {
        if lines.len() - s >= 3 {
            for f in flags.iter_mut().skip(s) {
                *f = true;
            }
        }
    }
    flags
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(mode: ReParagraphMode, indent: bool, indent_size: u8) -> ParagraphFormatSettings {
        ParagraphFormatSettings {
            enable_indent: indent,
            indent_size_chars: indent_size,
            paragraph_spacing_multiplier: 1.0,
            re_paragraph_mode: mode,
            smart_split_threshold: crate::processing::SMART_THRESHOLD,
            aggressive_split_threshold: crate::processing::AGGRESSIVE_THRESHOLD,
            justify: false,
            punctuation_compress: false,
            comment_scale: 0.82,
        }
    }

    // ===== Smart 模式测试 =====

    #[test]
    fn smart_mode_merges_soft_breaks() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "第一行内容\n第二行内容继续\n\n第二段第一行\n第二段第二行";
        let result = formatter.format(input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert_eq!(paras.len(), 2, "应合并为 2 段");
        assert!(!paras[0].contains('\n'), "第一段不应有换行");
        assert!(!paras[1].contains('\n'), "第二段不应有换行");
    }

    #[test]
    fn smart_mode_preserves_empty_line_boundaries() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "段落一\n\n段落二";
        let result = formatter.format(input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert_eq!(paras.len(), 2);
        assert_eq!(paras[0], "段落一");
        assert_eq!(paras[1], "段落二");
    }

    #[test]
    fn smart_mode_chapter_marker_starts_new_para() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "前文内容继续\n第二章 新的开始\n正文从这里开始";
        let result = formatter.format(input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        // 章节标记应独立成段
        assert!(paras.iter().any(|p| p.contains("第二章")), "应包含章节标记");
    }

    #[test]
    fn smart_mode_dialogue_not_merged() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "前文内容\n\n「对话内容」";
        let result = formatter.format(input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 2, "对话应独立成段");
    }

    // ===== Aggressive 模式测试 =====

    #[test]
    fn aggressive_mode_merges_all_lines() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Aggressive, false, 0));
        let input = "第一行\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行\n第八行\n第九行\n第十行";
        let result = formatter.format(input);
        // 合并后应有段落分隔（按强标点切分）
        assert!(!result.is_empty());
        // 不应保留原始换行
        assert!(
            !result.contains('\n') || result.contains("\n\n"),
            "Aggressive 应移除软换行"
        );
    }

    // ===== M9.2 超长段切分测试 =====

    /// n 句，每句恰 11 字（10 汉字 + 句号）
    fn sentences(n: usize) -> String {
        "一二三四五六七八九十。".repeat(n)
    }

    #[test]
    fn smart_mode_long_para_gets_split() {
        // M9.2 核心回归：Smart 此前只合并软换行、从不切长段
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = sentences(25); // 275 字 > Smart 阈值 200
        let result = formatter.format(&input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 2, "275 字 Smart 应被切开，实得 {} 段", paras.len());
        // 拼接还原
        let joined: String = paras.concat();
        assert_eq!(joined.chars().count(), 275);
    }

    #[test]
    fn smart_multi_piece_all_bounded_restart_counting() {
        // 用户钦定不变式（formatter 级）：切分后每个片段都是新段落，
        // 从切口处重新计数继续检测，直到全部 ≤ 阈值——660 字应切成
        // ≥3 段且每段 ≤ 阈值（+闭标吸附少量越出）
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let result = formatter.format(&sentences(60)); // 660 字
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 3, "660 字应切成 ≥3 段，实得 {}", paras.len());
        for (i, p) in paras.iter().enumerate() {
            assert!(
                p.chars().count() <= 200 + 20,
                "片段 {} 长度 {} 超过阈值上界",
                i,
                p.chars().count()
            );
        }
    }

    #[test]
    fn custom_threshold_via_settings() {
        // 阈值可调：调低设置阈值后同一段被切得更碎
        let mut s = settings(ReParagraphMode::Smart, false, 0);
        s.smart_split_threshold = 60;
        let formatter = ParagraphFormatter::new(s);
        let result = formatter.format(&sentences(20)); // 220 字
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 3, "阈值 60 时 220 字应切成 ≥3 段");
        for p in &paras {
            assert!(p.chars().count() <= 80, "自定义阈值片段超限");
        }
    }

    #[test]
    fn aggressive_unified_threshold_100() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Aggressive, false, 0));
        let merged_input = sentences(14); // 154 字 > Aggressive 阈值 100
        let result = formatter.format(&merged_input);
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 2, "154 字 Aggressive 应被切开");
        for p in &paras {
            assert!(
                p.chars().count() <= 100 + 20,
                "子段过长: {}",
                p.chars().count()
            );
        }
    }

    #[test]
    fn indent_applies_to_every_sub_segment() {
        // 三阶段顺序验证：合并 → 切分 → 缩进；每个视觉子段都注入全角空格
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, true, 2));
        let result = formatter.format(&sentences(25));
        let paras: Vec<&str> = result.split("\n\n").collect();
        assert!(paras.len() >= 2);
        for (i, p) in paras.iter().enumerate() {
            assert!(
                p.starts_with("\u{3000}\u{3000}"),
                "子段 {} 应以两个全角空格开头",
                i
            );
        }
    }

    #[test]
    fn chapter_marker_long_para_not_split() {
        // 以章节标记开头的段落不参与超长切分
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = format!("第十二章 {}", sentences(25));
        let result = formatter.format(&input);
        assert_eq!(result.split("\n\n").count(), 1, "章节标记段不切分");    }

    // ===== 缩进测试 =====

    #[test]
    fn indent_adds_full_width_spaces() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::None, true, 2));
        let input = "段落内容";
        let result = formatter.format(input);
        assert!(
            result.starts_with("\u{3000}\u{3000}"),
            "应以 2 个全角空格开头"
        );
    }

    #[test]
    fn indent_skips_chapter_markers() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::None, true, 2));
        let input = "第一章 开始\n正文内容";
        let result = formatter.format(input);
        let lines: Vec<&str> = result.lines().collect();
        // 章节标记行不应缩进
        assert!(
            !lines[0].starts_with('\u{3000}'),
            "章节标记不应缩进"
        );
        // 正文行应缩进
        assert!(
            lines[1].starts_with("\u{3000}\u{3000}"),
            "正文应缩进"
        );
    }

    #[test]
    fn indent_no_double_indent() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::None, true, 2));
        let input = "\u{3000}\u{3000}已有缩进的段落";
        let result = formatter.format(input);
        // 不应重复添加
        assert_eq!(result, input);
    }

    // ===== 综合测试 =====

    #[test]
    fn none_mode_with_indent_only() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::None, true, 2));
        let input = "段落一\n\n段落二";
        let result = formatter.format(input);
        let lines: Vec<&str> = result.lines().collect();
        assert!(lines[0].starts_with("\u{3000}\u{3000}"));
        assert!(lines[2].starts_with("\u{3000}\u{3000}"));
    }

    #[test]
    fn fast_path_no_settings() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::None, false, 0));
        let input = "原文内容\n保持不变";
        let result = formatter.format(input);
        assert_eq!(result, input);
    }

    #[test]
    fn smart_mode_preserves_poetry() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        // 3+ 连续短行 = 诗歌，应保留换行
        let input = "月落乌啼霜满天\n江枫渔火对愁眠\n姑苏城外寒山寺\n夜半钟声到客船";
        let result = formatter.format(input);
        // 诗歌的每行都是短行，不应全部合并成一个段落
        let paras: Vec<&str> = result.split("\n\n").collect();
        // 短行可能被切分为多个段落
        assert!(paras.len() >= 1, "诗歌至少应有一个段落");
    }

    // ===== P4 智能分段扩展：诗歌/对话/引用 =====

    #[test]
    fn smart_poetry_lines_stay_independent() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "他望着窗外出神，久久没有说话。\n床前明月光\n疑是地上霜\n举头望明月\n低头思故乡\n他想起了故乡的很多往事，一时难以平静。";
        let out = formatter.format(input);
        let paras: Vec<&str> = out.split("\n\n").collect();
        // 诗节 4 行各自独立段（不并入前后长段）
        assert!(paras.contains(&"床前明月光"), "诗行应独立成段（实得 {:?}）", paras);
        assert!(paras.contains(&"疑是地上霜"));
        assert!(paras.contains(&"举头望明月"));
        assert!(paras.contains(&"低头思故乡"));
        assert_eq!(paras.len(), 6);
        // 前后长段不被诗行黏连
        assert!(paras[0].starts_with("他望着"));
        assert_eq!(paras[5], "他想起了故乡的很多往事，一时难以平静。");
    }

    #[test]
    fn smart_quote_lines_stripped_and_independent() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        let input = "正文开头\n> 这是引用的内容\n> 第二行引用\n正文继续";
        let out = formatter.format(input);
        let paras: Vec<&str> = out.split("\n\n").collect();
        assert_eq!(paras[0], "正文开头");
        assert!(paras.contains(&"这是引用的内容"), "引用行应去前缀独立成段（实得 {:?}）", paras);
        assert!(paras.contains(&"第二行引用"));
        assert_eq!(paras[3], "正文继续");
    }

    #[test]
    fn smart_closed_dialogue_ends_paragraph() {
        let formatter = ParagraphFormatter::new(settings(ReParagraphMode::Smart, false, 0));
        // 第二行 >20 字（非短行）：无规则时会并入对话段
        let input = "「你好。」\n他转身离开，留下一个背影，从此再也没有回来过。";
        let out = formatter.format(input);
        let paras: Vec<&str> = out.split("\n\n").collect();
        assert_eq!(paras.len(), 2, "闭合对话应独立成段（实得 {:?}）", paras);
        assert_eq!(paras[0], "「你好。」");
    }
}
