use anyhow::Result;
use regex::Regex;

use crate::clean_rules;

/// 繁简转换模式
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ConvertMode {
    /// 不转换
    None,
    /// 繁体转简体
    TraditionalToSimplified,
    /// 简体转繁体
    SimplifiedToTraditional,
}

/// 段落规范化模式
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ParagraphMode {
    /// 不处理
    None,
    /// 智能分段（识别缩进、空行）
    Smart,
    /// 强制重新分段（每2行一段）
    Force,
}

/// 内容清理选项
#[derive(Debug, Clone)]
pub struct CleanOptions {
    /// 是否清理 HTML 标签
    pub clean_html: bool,
    /// 是否删除广告（基于黑名单）
    pub remove_ads: bool,
    /// 是否删除多余空白
    pub remove_extra_whitespace: bool,
}

impl Default for CleanOptions {
    fn default() -> Self {
        Self {
            clean_html: true,
            remove_ads: true,
            remove_extra_whitespace: true,
        }
    }
}

/// 内容净化器
#[derive(Clone)]
pub struct ContentCleaner {
    convert_mode: ConvertMode,
    paragraph_mode: ParagraphMode,
    clean_options: CleanOptions,
    
    // 预编译的正则表达式
    html_tag_regex: Regex,
    whitespace_regex: Regex,
    ad_patterns: Vec<Regex>,
}

impl ContentCleaner {
    /// 创建新的内容净化器
    pub fn new(
        convert_mode: ConvertMode,
        paragraph_mode: ParagraphMode,
        clean_options: CleanOptions,
    ) -> Self {
        // 预编译正则表达式
        let html_tag_regex = Regex::new(r"<[^>]+>").unwrap();
        let whitespace_regex = Regex::new(r"[ \t]+").unwrap();

        // 广告黑名单正则
        let ad_patterns = vec![
            Regex::new(r"(?i)本书由.*?首发").unwrap(),
            Regex::new(r"(?i)更新最快的.*?网").unwrap(),
            Regex::new(r"(?i)笔趣阁|顶点小说|飘天文学").unwrap(),
            Regex::new(r"(?i)请记住本站|收藏本站").unwrap(),
            Regex::new(r"(?i)www\.\w+\.com").unwrap(),
        ];

        Self {
            convert_mode,
            paragraph_mode,
            clean_options,
            html_tag_regex,
            whitespace_regex,
            ad_patterns,
        }
    }

    /// 净化配置的哈希值（用于检测配置变更、失效净化缓存）
    pub fn config_hash(&self) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        std::mem::discriminant(&self.convert_mode).hash(&mut hasher);
        std::mem::discriminant(&self.paragraph_mode).hash(&mut hasher);
        self.clean_options.clean_html.hash(&mut hasher);
        self.clean_options.remove_ads.hash(&mut hasher);
        self.clean_options.remove_extra_whitespace.hash(&mut hasher);
        // 内置净化规则集内容哈希：规则升级即自动失效全部净化缓存
        clean_rules::ruleset_hash().hash(&mut hasher);
        hasher.finish()
    }
    
    /// 清理内容
    pub fn clean(&self, content: &str) -> Result<String> {
        let mut result = content.to_string();
        
        // 1. 清理 HTML 标签
        if self.clean_options.clean_html {
            result = self.clean_html_tags(&result);
        }
        
        // 2. 删除广告
        if self.clean_options.remove_ads {
            result = self.remove_ads(&result);
        }
        
        // 3. 繁简转换
        if self.convert_mode != ConvertMode::None {
            result = self.convert_text(&result)?;
        }
        
        // 4. 段落规范化
        if self.paragraph_mode != ParagraphMode::None {
            result = self.normalize_paragraphs(&result)?;
        }
        
        // 5. 删除多余空白
        if self.clean_options.remove_extra_whitespace {
            result = self.remove_extra_whitespace(&result);
        }
        
        Ok(result)
    }
    
    /// 清理 HTML 标签
    fn clean_html_tags(&self, content: &str) -> String {
        self.html_tag_regex.replace_all(content, "").to_string()
    }
    
    /// 删除广告内容（D9：JS 规则主路径，失败/极简构建回落正则兜底）
    fn remove_ads(&self, content: &str) -> String {
        if let Some(result) = clean_rules::apply_js_ad_rules(content) {
            if let Ok(cleaned) = result {
                return cleaned;
            }
            // JS 失败已限频告警，此处静默落兜底
        }
        self.remove_ads_regex_fallback(content)
    }

    /// 正则兜底广告清理（与内置 JS 规则语义一致）
    fn remove_ads_regex_fallback(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        for pattern in &self.ad_patterns {
            result = pattern.replace_all(&result, "").to_string();
        }
        
        result
    }
    
    /// 繁简转换
    fn convert_text(&self, content: &str) -> Result<String> {
        match self.convert_mode {
            ConvertMode::None => Ok(content.to_string()),
            ConvertMode::TraditionalToSimplified => {
                Ok(crate::chinese_convert::convert_t2s(content))
            }
            ConvertMode::SimplifiedToTraditional => {
                Ok(crate::chinese_convert::convert_s2t(content))
            }
        }
    }
    
    /// 段落规范化
    fn normalize_paragraphs(&self, content: &str) -> Result<String> {
        match self.paragraph_mode {
            ParagraphMode::None => Ok(content.to_string()),
            ParagraphMode::Smart => self.smart_paragraph_split(content),
            ParagraphMode::Force => self.force_paragraph_split(content),
        }
    }
    
    /// 智能分段
    fn smart_paragraph_split(&self, content: &str) -> Result<String> {
        let mut paragraphs = Vec::new();
        let mut current_paragraph = String::new();
        
        for line in content.lines() {
            let trimmed = line.trim();
            
            // 空行分段
            if trimmed.is_empty() {
                if !current_paragraph.is_empty() {
                    paragraphs.push(current_paragraph.trim().to_string());
                    current_paragraph.clear();
                }
                continue;
            }
            
            // 缩进开头认为是新段落
            if line.starts_with("　") || line.starts_with("  ") {
                if !current_paragraph.is_empty() {
                    paragraphs.push(current_paragraph.trim().to_string());
                    current_paragraph.clear();
                }
                current_paragraph.push_str(trimmed);
            } else {
                // 继续当前段落
                if !current_paragraph.is_empty() {
                    current_paragraph.push_str(trimmed);
                } else {
                    current_paragraph.push_str(trimmed);
                }
            }
        }
        
        // 添加最后一段
        if !current_paragraph.is_empty() {
            paragraphs.push(current_paragraph.trim().to_string());
        }
        
        // 用双换行符连接段落
        Ok(paragraphs.join("\n\n"))
    }
    
    /// 强制重新分段
    fn force_paragraph_split(&self, content: &str) -> Result<String> {
        let lines: Vec<&str> = content.lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect();
        
        let mut paragraphs = Vec::new();
        
        // 每2行一段
        for chunk in lines.chunks(2) {
            paragraphs.push(chunk.join(""));
        }
        
        Ok(paragraphs.join("\n\n"))
    }
    
    /// 删除多余空白
    fn remove_extra_whitespace(&self, content: &str) -> String {
        let mut result = content.to_string();
        
        // 替换多个空格为单个空格
        result = self.whitespace_regex.replace_all(&result, " ").to_string();
        
        // 删除行首行尾空白
        result = result.lines()
            .map(|l| l.trim())
            .collect::<Vec<_>>()
            .join("\n");
        
        // 删除多余的空行（保留最多2个连续换行）
        while result.contains("\n\n\n") {
            result = result.replace("\n\n\n", "\n\n");
        }
        
        result
    }
}

impl Default for ContentCleaner {
    fn default() -> Self {
        Self::new(
            ConvertMode::None,
            ParagraphMode::Smart,
            CleanOptions::default(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_clean_html_tags() {
        let cleaner = ContentCleaner::default();
        let content = "<p>这是一段<span>文字</span></p>";
        let result = cleaner.clean_html_tags(content);
        assert_eq!(result, "这是一段文字");
    }
    
    #[test]
    fn test_remove_ads() {
        let cleaner = ContentCleaner::default();
        let content = "正文内容\n本书由笔趣阁首发\n继续正文\nwww.biquge.com";
        let result = cleaner.remove_ads(content);
        assert!(!result.contains("笔趣阁"));
        assert!(!result.contains("www.biquge.com"));
    }
    
    #[test]
    fn test_smart_paragraph_split() {
        let cleaner = ContentCleaner::default();
        let content = "　　这是第一段。\n这是第一段继续。\n\n　　这是第二段。";
        let result = cleaner.smart_paragraph_split(content).unwrap();
        
        let paragraphs: Vec<&str> = result.split("\n\n").collect();
        assert_eq!(paragraphs.len(), 2);
    }
    
    #[test]
    fn test_remove_extra_whitespace() {
        let cleaner = ContentCleaner::default();
        let content = "这是   多个空格\n  \n\n\n这是多个空行";
        let result = cleaner.remove_extra_whitespace(content);
        assert!(!result.contains("   "));
        assert!(!result.contains("\n\n\n"));
    }
    
    #[test]
    fn test_full_clean() {
        let cleaner = ContentCleaner::new(
            ConvertMode::None,
            ParagraphMode::Smart,
            CleanOptions::default(),
        );
        
        let content = r#"
<div>
　　这是第一段<span>内容</span>。
本书由笔趣阁首发
　　这是第二段内容。
</div>
"#;
        
        let result = cleaner.clean(content).unwrap();
        assert!(!result.contains("<div>"));
        assert!(!result.contains("笔趣阁"));
        assert!(result.contains("这是第一段内容"));
        assert!(result.contains("这是第二段内容"));
    }
}
