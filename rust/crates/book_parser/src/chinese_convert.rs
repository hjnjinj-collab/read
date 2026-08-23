//! 简繁转换（全项目唯一权威实现）
//!
//! 基于 zhconv（内嵌 OpenCC/MediaWiki 词组级转换表，静态初始化一次）。
//! 两条链路必须经由本模块，保证行为一致：
//! - 导入级：[`crate::content_cleaner::ContentCleaner`]（章节识别基于转换后文本）
//! - 阅读级：reader_core::ContentPreprocessor（设置变更即时生效）

use zhconv::{zhconv, Variant};

/// 简体 → 繁体
pub fn convert_s2t(content: &str) -> String {
    zhconv(content, Variant::ZhHant)
}

/// 繁体 → 简体
pub fn convert_t2s(content: &str) -> String {
    zhconv(content, Variant::ZhHans)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_s2t_novel_vocab() {
        // 小说常见字：占位实现时代全部失效
        assert_eq!(convert_s2t("贷款武圣读书"), "貸款武聖讀書");
        assert_eq!(convert_s2t("头发发展"), "頭髮發展");
    }

    #[test]
    fn test_t2s_novel_vocab() {
        assert_eq!(convert_t2s("貸款武聖讀書"), "贷款武圣读书");
    }

    #[test]
    fn test_roundtrip() {
        let src = "主角在阅读章节内容";
        assert_eq!(convert_t2s(&convert_s2t(src)), src);
    }
}
