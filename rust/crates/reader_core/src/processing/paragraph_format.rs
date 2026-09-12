/// M9 段落格式化设置
///
/// 控制首行缩进和重新分段行为，影响分页前的文本处理。
/// 设置变更通过 `para_format_hash` 纳入缓存键，自动触发重布局。

/// 重新分段模式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReParagraphMode {
    /// 不处理：保持原文所有换行
    None = 0,
    /// 智能分段：基于缩进、空行、行长检测段落边界（保守）
    Smart = 1,
    /// 强制重排：移除所有软换行，按语义重新切分（修复劣质书源）
    Aggressive = 2,
}

impl Default for ReParagraphMode {
    fn default() -> Self {
        Self::Smart
    }
}

impl ReParagraphMode {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::None,
            1 => Self::Smart,
            2 => Self::Aggressive,
            _ => Self::default(),
        }
    }
}

/// 段落格式化设置
#[derive(Debug, Clone, PartialEq)]
pub struct ParagraphFormatSettings {
    /// 启用首行缩进
    pub enable_indent: bool,
    /// 缩进大小（全角字符数，0-4；典型值 2）
    pub indent_size_chars: u8,
    /// 段间距倍率（相对 line_height，1.0-2.0；1.0=无额外间距）
    pub paragraph_spacing_multiplier: f32,
    /// 重新分段模式
    pub re_paragraph_mode: ReParagraphMode,
    /// M9.2：Smart 模式超长段切分阈值（字，用户可调）
    pub smart_split_threshold: usize,
    /// M9.2：Aggressive 模式超长段切分阈值（字，用户可调）
    pub aggressive_split_threshold: usize,
    /// P2：两端对齐全局开关（EPUB 书内 css text-align:justify 直接启用；
    /// Left/未指定段落跟随本开关；TXT 全部跟随）
    pub justify: bool,
    /// P3：行尾标点压缩悬挂（判满失败且行尾可压缩标点折半宽能放下时
    /// 收进行尾，渲染端全宽绘制自然悬挂出右缘）
    pub punctuation_compress: bool,
    /// 注释行字号倍率（0.70–1.00；默认 0.82）。进布局行高与分页缓存键。
    pub comment_scale: f32,
}

impl Default for ParagraphFormatSettings {
    fn default() -> Self {
        Self {
            enable_indent: true,
            indent_size_chars: 2,
            paragraph_spacing_multiplier: 1.0,
            re_paragraph_mode: ReParagraphMode::Smart,
            smart_split_threshold: super::paragraph_splitter::SMART_THRESHOLD,
            aggressive_split_threshold: super::paragraph_splitter::AGGRESSIVE_THRESHOLD,
            justify: false,
            punctuation_compress: false,
            comment_scale: 0.82,
        }
    }
}

impl ParagraphFormatSettings {
    /// 当前模式生效的切分阈值；None = 不切。
    /// EPUB（apply_paragraph_format_settings）与 TXT（ParagraphFormatter）
    /// 双路径统一经此解析——切分后的每一段由 split_ranges 循环从切口处
    /// 重新计数检测，直到所有片段 ≤ 阈值。
    pub fn effective_split_threshold(&self) -> Option<usize> {
        match self.re_paragraph_mode {
            ReParagraphMode::None => None,
            ReParagraphMode::Smart => Some(self.smart_split_threshold),
            ReParagraphMode::Aggressive => Some(self.aggressive_split_threshold),
        }
    }

    /// 计算设置的哈希值（用于缓存键）
    pub fn hash_value(&self) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        self.enable_indent.hash(&mut hasher);
        self.indent_size_chars.hash(&mut hasher);
        self.paragraph_spacing_multiplier.to_bits().hash(&mut hasher);
        self.re_paragraph_mode.hash(&mut hasher);
        self.smart_split_threshold.hash(&mut hasher);
        self.aggressive_split_threshold.hash(&mut hasher);
        self.justify.hash(&mut hasher);
        self.punctuation_compress.hash(&mut hasher);
        self.comment_scale.to_bits().hash(&mut hasher);
        hasher.finish()
    }

    /// 是否需要段落格式化（任一设置非默认即需要）
    pub fn needs_formatting(&self) -> bool {
        self.enable_indent || self.re_paragraph_mode != ReParagraphMode::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_values_correct() {
        let s = ParagraphFormatSettings::default();
        assert!(s.enable_indent);
        assert_eq!(s.indent_size_chars, 2);
        assert!((s.paragraph_spacing_multiplier - 1.0).abs() < 0.001);
        assert_eq!(s.re_paragraph_mode, ReParagraphMode::Smart);
        // M9.2：默认切分阈值 200/100
        assert_eq!(s.smart_split_threshold, 200);
        assert_eq!(s.aggressive_split_threshold, 100);
    }

    #[test]
    fn effective_split_threshold_follows_mode_and_settings() {
        let mut s = ParagraphFormatSettings::default();
        assert_eq!(s.effective_split_threshold(), Some(200));
        s.smart_split_threshold = 150;
        assert_eq!(s.effective_split_threshold(), Some(150), "阈值应可调");
        s.re_paragraph_mode = ReParagraphMode::Aggressive;
        assert_eq!(s.effective_split_threshold(), Some(100));
        s.aggressive_split_threshold = 80;
        assert_eq!(s.effective_split_threshold(), Some(80));
        s.re_paragraph_mode = ReParagraphMode::None;
        assert_eq!(s.effective_split_threshold(), None);
    }

    #[test]
    fn re_paragraph_mode_from_u8() {
        assert_eq!(ReParagraphMode::from_u8(0), ReParagraphMode::None);
        assert_eq!(ReParagraphMode::from_u8(1), ReParagraphMode::Smart);
        assert_eq!(ReParagraphMode::from_u8(2), ReParagraphMode::Aggressive);
        // 越界回退默认
        assert_eq!(ReParagraphMode::from_u8(99), ReParagraphMode::Smart);
    }

    #[test]
    fn hash_value_changes_with_settings() {
        let s1 = ParagraphFormatSettings::default();
        let mut s2 = s1.clone();
        s2.enable_indent = false;
        assert_ne!(s1.hash_value(), s2.hash_value());

        let mut s3 = s1.clone();
        s3.indent_size_chars = 3;
        assert_ne!(s1.hash_value(), s3.hash_value());

        let mut s4 = s1.clone();
        s4.re_paragraph_mode = ReParagraphMode::None;
        assert_ne!(s1.hash_value(), s4.hash_value());

        // M9.2：阈值参与哈希（调整即换缓存键）
        let mut s5 = s1.clone();
        s5.smart_split_threshold = 150;
        assert_ne!(s1.hash_value(), s5.hash_value());
    }

    #[test]
    fn needs_formatting_detection() {
        let mut s = ParagraphFormatSettings::default();
        assert!(s.needs_formatting());

        s.enable_indent = false;
        s.re_paragraph_mode = ReParagraphMode::None;
        assert!(!s.needs_formatting());

        s.enable_indent = true;
        assert!(s.needs_formatting());
    }
}
