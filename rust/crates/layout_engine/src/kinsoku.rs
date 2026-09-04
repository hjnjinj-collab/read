//! 避头尾/行首行尾禁则 + 两端对齐空隙分配（2026-09-04 P2 排版批次）
//!
//! 收口背景：LINE_START_FORBIDDEN / LINE_END_FORBIDDEN / is_word_char 此前在
//! lib.rs 三处各自复制（layout_paragraph 旧版 / layout_paragraph_with_oracle /
//! layout_styled_paragraph），本模块统一字符表、词字符判定与 justify 空隙算法。
//!
//! 设计约定：
//! - **禁则回退先行**：justify 空隙在禁则/整词回退完成后的最终行文本上现算，
//!   回退导致的短行自动少分（禁则回退逻辑不感知本模块）
//! - **短行豁免**：富余超过行宽 40% 或单字间隙超过半字 → 回退左对齐
//!   （防止三两个字撑满一行的「天窗」效果）
//! - **除以 n_chars**：Flutter letterSpacing 对行尾字符也加宽（n 个间隙
//!   而非 n−1），分母必须用字符总数右缘才能精确贴合

/// 行首禁则字符：不可出现在行首（闭合类标点 / 尾随符号）
pub const LINE_START_FORBIDDEN: &[char] = &[
    // 全角
    '，', '。', '、', '；', '：', '？', '！', '”', '’', '」', '』', '）', '】',
    '〉', '》', '…', '—', '～', '·', '％',
    // 半角
    ',', '.', ';', ':', '!', '?', '%', ')', ']', '}', '\'', '"',
    // 单位/符号
    '‰', '°', '℃',
];

/// 行尾禁则字符：不可出现在行尾（开放类标点）
pub const LINE_END_FORBIDDEN: &[char] = &[
    // 全角
    '「', '『', '（', '【', '〈', '《', '‘', '“',
    // 半角
    '(', '[', '{', '\'', '"',
];

/// 词字符判定（英文整词回退用）：ASCII 字母数字 + 下划线
pub fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// 两端对齐空隙分配：返回每字符 letterSpacing（px）
///
/// - `natural_width`：禁则/整词回退完成后的最终行文本实测宽度
/// - `available_width`：本行可用宽度（首行含缩进折减后的有效宽度）
/// - `n_chars`：行字符总数（含拉丁字符——Flutter 行尾字符也加一个间隙，
///   除以总数右缘才精确贴合）
pub fn justify_gap(
    natural_width: f32,
    available_width: f32,
    n_chars: usize,
    font_size: f32,
) -> f32 {
    if n_chars < 2 {
        return 0.0;
    }
    let slack = available_width - natural_width;
    // 已超宽（epsilon 溢出行）或短行豁免（富余 > 40% 行宽）
    if slack <= 0.0 || slack > available_width * 0.4 {
        return 0.0;
    }
    let gap = slack / n_chars as f32;
    // 单字间隙超过半字 → 回退左对齐（防「天窗」）
    if gap > font_size * 0.5 {
        return 0.0;
    }
    gap
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_char_classification() {
        assert!(is_word_char('a'));
        assert!(is_word_char('Z'));
        assert!(is_word_char('0'));
        assert!(is_word_char('_'));
        assert!(!is_word_char('中'));
        assert!(!is_word_char(' '));
        assert!(!is_word_char(','));
    }

    #[test]
    fn kinsoku_tables_disjoint() {
        // 行首/行尾禁则表不得有交集（字符不可能既禁首又禁尾）。
        // 例外：直引号 '/" 开闭中性——原三处副本即为双表成员
        // （禁止单独引号贴行边），沿袭语义并在白名单中显式声明。
        let neutral: &[char] = &['\'', '"'];
        for c in LINE_START_FORBIDDEN {
            assert!(
                !LINE_END_FORBIDDEN.contains(c) || neutral.contains(c),
                "字符 {c} 同时在两张表中且不在白名单"
            );
        }
    }

    #[test]
    fn justify_gap_short_line_exemption() {
        // 富余 > 40% 行宽 → 不分配
        assert_eq!(justify_gap(100.0, 200.0, 10, 18.0), 0.0);
        // 富余 20 行宽 → 每字符 4px
        assert!((justify_gap(160.0, 200.0, 10, 18.0) - 4.0).abs() < 1e-4);
        // 单字间隙超半字 → 不分配（gap=25 > 18/2）
        assert_eq!(justify_gap(160.0, 200.0, 2, 18.0), 0.0);
        // 单字符行不分配
        assert_eq!(justify_gap(0.0, 200.0, 1, 18.0), 0.0);
        // 已超宽不分配
        assert_eq!(justify_gap(210.0, 200.0, 10, 18.0), 0.0);
    }
}
