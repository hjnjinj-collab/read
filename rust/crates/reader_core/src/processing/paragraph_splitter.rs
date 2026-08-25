//! M9.2 共享超长段切分器
//!
//! EPUB（bridge::apply_paragraph_format_settings）与 TXT（ParagraphFormatter）
//! 双端共用的纯函数库：核心只返回字符区间，文本切片与样式 runs 裁剪由调用方
//! 完成，因此本模块零外部依赖（reader_core 不依赖 book_parser）。
//!
//! 切分语义（用户钦定 M9.2）：超过阈值的段落按标点切短——
//! 1. 窗口内从后往前找句末强标点（纯 CJK 集，ASCII 句读降级为次级，避免
//!    切在 "3.14"/"Mr." 处）；
//! 2. 窗口内无强标点 → 有界回退再扫一个窗口长度找次级标点（杜绝旧实现的
//!    全文无上界扫描）；
//! 3. 仍无 → 硬切在阈值处；
//! 4. 切点后紧随的闭引号/闭括号吸附到前片（中文禁则：”不得落段首）；
//! 5. 省略号 …… 具有原子性，任何切口不得落在两个 U+2026 之间；
//! 6. 不产出空尾段；末片过短时并入前片（再平衡硬上限 1.2×threshold）。
//!
//! 关键不变式（用户钦定）：切口之后的剩余文本作为新段落从头计数——
//! while 循环每轮以 start=上一切口为新起点重建窗口，直到所有片段 ≤ 阈值。
//! 实际生效阈值经 ParagraphFormatSettings::effective_split_threshold() 解析
//! （用户可调），本模块只接收数值。

/// Smart 模式切分阈值默认值（字）；用户可在设置面板调节
pub const SMART_THRESHOLD: usize = 200;
/// Aggressive 模式切分阈值默认值（字）；TXT 原 80，M9.2 起双路径统一。
/// 实际生效阈值经 ParagraphFormatSettings::effective_split_threshold() 解析
/// （用户可调），本常量仅作默认值与测试基准。
pub const AGGRESSIVE_THRESHOLD: usize = 100;

/// 句末强标点（纯 CJK 集）。刻意不含 ASCII `. ! ?` 与直引号 `"`：
/// 小数点/缩写/英文引语中途被切属高频误切场景。
pub fn is_strong_punct(c: char) -> bool {
    matches!(c, '。' | '！' | '？' | '…' | '；' | '」' | '』' | '\u{201D}')
}

/// 次级标点：仅用于强标点缺失时的有界回退扫描
fn is_secondary_punct(c: char) -> bool {
    matches!(c, '，' | '、' | '：' | ',' | '.' | ';' | ':' | '!' | '?')
}

/// 闭标吸附集：切点后紧随这些字符时吞并到前片，保证不落段首
fn is_closing_glue(c: char) -> bool {
    matches!(
        c,
        '\u{201D}' | '\u{2019}' | '」' | '』' | '）' | '】' | '》' | '〉' | '〕'
    )
}

/// 主入口：把文本切为字符区间列表
///
/// 返回区间按 char 计数、升序、无缝无叠，并集恒等于 `[0, total)`；
/// 文本长度 ≤ threshold 时返回覆盖全文的单区间。
pub fn split_ranges(text: &str, threshold: usize) -> Vec<(usize, usize)> {
    let chars: Vec<char> = text.chars().collect();
    let total = chars.len();
    // 阈值 0 无意义（会退化为逐字符死循环），防御性返回单区间
    if threshold == 0 || total <= threshold {
        return vec![(0, total)];
    }

    let mut out: Vec<(usize, usize)> = Vec::new();
    let mut start = 0usize;
    while total - start > threshold {
        let limit = start + threshold;
        // ① 窗口内从后往前找强标点；省略号原子性：候选切口若落在
        //    两个 U+2026 之间则作废，继续向前找
        let mut cut = (start + 1..=limit).rev().find(|&i| {
            is_strong_punct(chars[i - 1]) && !(chars[i - 1] == '…' && i < total && chars[i] == '…')
        });
        // ② 有界回退：仅再扫一个窗口长度找次级标点
        if cut.is_none() {
            let ext = (limit + threshold).min(total);
            cut = (limit..ext)
                .find(|&i| is_secondary_punct(chars[i]))
                .map(|i| i + 1);
        }
        // ③ 硬切兜底
        let mut c = cut.unwrap_or(limit);
        // 回退/硬切落点仍可能恰好落在省略号对中间，越过整对
        if c > 0 && c < total && chars[c - 1] == '…' && chars[c] == '…' {
            c += 1;
        }
        // ④ 闭标吸附：向后吞并紧随的闭引号/闭括号序列
        while c < total && is_closing_glue(chars[c]) {
            c += 1;
        }
        out.push((start, c));
        start = c;
    }
    // ⑤ 空尾段修复：吸附推进到文末时不再追加空段
    if start < total {
        out.push((start, total));
    }
    // ⑥ 尾段再平衡：末片 <20%·threshold 且并入后 ≤1.2×threshold 才合并
    if out.len() >= 2 {
        let last_len = out.last().map(|&(s, e)| e - s).unwrap_or(0);
        let prev = out[out.len() - 2];
        if last_len * 5 < threshold && (prev.1 - prev.0 + last_len) * 10 <= threshold * 12 {
            out.pop();
            if let Some(last) = out.last_mut() {
                last.1 = total; // 区间连续，直接延伸到文末
            }
        }
    }
    out
}

/// 糖衣：直接产出文本片段（TXT 路径用）
pub fn split_pieces(text: &str, threshold: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    split_ranges(text, threshold)
        .into_iter()
        .map(|(s, e)| chars[s..e].iter().collect())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repeat(ch: char, n: usize) -> String {
        std::iter::repeat(ch).take(n).collect()
    }

    #[test]
    fn default_threshold_constants() {
        // 默认阈值 200/100（实际生效值可经 ParagraphFormatSettings 调节）
        assert_eq!(SMART_THRESHOLD, 200);
        assert_eq!(AGGRESSIVE_THRESHOLD, 100);
    }

    #[test]
    fn split_restarts_counting_from_each_cut() {
        // 用户钦定不变式：切口后的剩余内容作为新段落从头计数继续检测切分。
        // 句长 11（10 字+句号），句号在索引 10+11k。阈值 200 时各轮窗口
        // 以上一切口为起点重建：切点应落在 198 / 396 / 594（非阈值整数倍对齐），
        // 全部片段 ≤ 阈值。
        let text = "一二三四五六七八九十。".repeat(60); // 660 字
        let ranges = split_ranges(&text, 200);
        assert_eq!(
            ranges,
            vec![(0, 198), (198, 396), (396, 594), (594, 660)],
            "每轮窗口必须从上一切口重新计数"
        );
        for &(s, e) in &ranges {
            assert!(e - s <= 200, "片段长度 {} 超过阈值", e - s);
        }
    }

    #[test]
    fn custom_threshold_respected() {
        // 阈值可调：同一文本按调用方传入的阈值切分
        let text = "一二三四五六七八九十。".repeat(30); // 330 字
        let ranges = split_ranges(&text, 80);
        assert!(ranges.len() >= 4, "阈值 80 应产出更多片段");
        for &(s, e) in &ranges {
            assert!(e - s <= 80 + 20, "自定义阈值下片段超限: {}", e - s);
        }
    }

    #[test]
    fn short_text_single_range() {
        assert_eq!(split_ranges("短文本", 200), vec![(0, 3)]);
        // 恰好等于阈值：不切
        let exact = repeat('甲', 200);
        assert_eq!(split_ranges(&exact, 200), vec![(0, 200)]);
        // 阈值 0 防御：单区间不死循环
        assert_eq!(split_ranges("任意", 0), vec![(0, 2)]);
    }

    #[test]
    fn cuts_at_last_strong_punct_in_window() {
        // 150甲 + 。 + 30乙 + 。 + 80丙 = 262 字，阈值 200
        let mut text = repeat('甲', 150);
        text.push('。');
        text.push_str(&repeat('乙', 30));
        text.push('。');
        text.push_str(&repeat('丙', 80));
        let ranges = split_ranges(&text, 200);
        // 窗口 [1,200] 内最后一个强标点在索引 181（第二个。）→ 切在 182
        assert_eq!(ranges, vec![(0, 182), (182, 262)]);
    }

    #[test]
    fn quote_absorption_keeps_closer_with_left() {
        // 199X + 。” + 50Y = 251 字：切在 。 后，”必须吸附到前片
        let mut text = repeat('X', 199);
        text.push('。');
        text.push('\u{201D}');
        text.push_str(&repeat('Y', 50));
        let pieces = split_pieces(&text, 200);
        assert_eq!(pieces.len(), 2);
        assert!(pieces[0].ends_with("。”"), "闭引号应吸附在前片尾部");
        assert!(!pieces[1].starts_with('\u{201D}'), "右片不得以闭引号开头");
    }

    #[test]
    fn ellipsis_never_split() {
        // 省略号对恰在窗口边界：不得从两个 … 中间切开
        let mut text = repeat('A', 199);
        text.push_str("……");
        let pieces = split_pieces(&text, 200);
        assert_eq!(pieces.len(), 1, "吸附越过后全文 201 字应整体保留");

        // 省略号对在窗口中部：向后扫到的第一个有效候选是完整对之后的切口
        // （两个 … 都留在左片，属合法切点）；唯一禁区是对中间（边界 196）
        let mut text2 = repeat('A', 195);
        text2.push_str("……");
        text2.push_str(&repeat('B', 40));
        let ranges = split_ranges(&text2, 200);
        let bounds: Vec<usize> = ranges.iter().map(|&(s, _)| s).skip(1).collect();
        for b in bounds {
            assert!(b != 196, "切口不得落在省略号对中间（得到 {}）", b);
        }
        for p in split_pieces(&text2, 200) {
            assert!(!p.starts_with('\u{2026}') || text2.starts_with('\u{2026}'));
        }
    }

    #[test]
    fn fallback_bounded_secondary_scan() {
        // 无强标点，逗号只在第二窗口（200~400 区间）
        let mut text = repeat('甲', 250);
        text.push('，');
        text.push_str(&repeat('乙', 100));
        let ranges = split_ranges(&text, 200);
        assert_eq!(ranges.first(), Some(&(0, 251)), "应切在次级标点之后");
    }

    #[test]
    fn hard_cut_at_limit_when_no_punct() {
        let text = repeat('甲', 500);
        let ranges = split_ranges(&text, 200);
        assert_eq!(ranges, vec![(0, 200), (200, 400), (400, 500)]);
    }

    #[test]
    fn no_empty_tail_after_absorb_to_end() {
        // 强标点+闭标恰达文末：吸附推到 total 后不得产生空尾段
        let mut text = repeat('X', 199);
        text.push('。');
        text.push('\u{201D}');
        let pieces = split_pieces(&text, 200);
        assert_eq!(pieces.len(), 1);
        assert_eq!(pieces[0].chars().count(), 201);
        assert!(pieces.iter().all(|p| !p.is_empty()));
    }

    #[test]
    fn tail_rebalance_merges_tiny_tail() {
        // 150甲。+55乙。 = 尾片远小于 20%·200？构造：主片 ~190，尾片 12
        let mut text = repeat('甲', 189);
        text.push('。');
        text.push_str(&repeat('乙', 11));
        text.push('。');
        // 总长 202 > 200：窗口内最后强标点是索引 189 的 。→ 切 190，尾片 12 字
        let ranges = split_ranges(&text, 200);
        // 12*5=60 < 200 且 (190+12)*10=2020 <= 2400 → 合并为单区间
        assert_eq!(ranges, vec![(0, 202)], "微小尾片应并入前片");

        // 反例：合并后超 1.2×threshold 则不合并
        let mut text2 = repeat('甲', 190);
        text2.push('。');
        text2.push_str(&repeat('乙', 60));
        text2.push('。');
        // 总 253：切 191 后余 62；62*5=310 >= 200 → 不触发再平衡
        let ranges2 = split_ranges(&text2, 200);
        assert_ne!(ranges2.len(), 1, "尾片不小或合并超限时不应合并");
    }

    #[test]
    fn ranges_contiguous_ordered_cover_all() {
        let cases: Vec<String> = vec![
            format!("{}。{}", repeat('甲', 350), repeat('乙', 30)),
            format!("{}，{}", repeat('甲', 95), repeat('乙', 120)),
            repeat('丙', 700),
            "短句。".to_string(),
        ];
        // 空输入防御：单零区间
        assert_eq!(split_ranges("", 200), vec![(0, 0)]);
        for text in cases {
            let total = text.chars().count();
            let ranges = split_ranges(&text, 200);
            let mut expect_start = 0usize;
            for &(s, e) in &ranges {
                assert_eq!(s, expect_start, "区间必须无缝衔接");
                assert!(e > s, "不得出现空区间");
                expect_start = e;
            }
            assert_eq!(expect_start, total, "区间并集必须覆盖全文");
        }
    }
}
