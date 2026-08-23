use anyhow::{anyhow, Result};
use regex::Regex;
use crate::types::AnalyzeResult;

/// 正则表达式分析器
pub struct RegexAnalyzer;

impl RegexAnalyzer {
    /// 使用正则表达式提取内容
    /// 
    /// # 参数
    /// - `content`: 待分析的内容
    /// - `pattern`: 正则表达式模式
    /// - `get_all`: 是否获取所有匹配项
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::RegexAnalyzer;
    /// let content = "书名：《测试》，作者：张三";
    /// let result = RegexAnalyzer::find(content, r"书名：《(.+?)》", false)?;
    /// // 结果: "测试"
    /// # Ok(())
    /// # }
    /// ```
    pub fn find(content: &str, pattern: &str, get_all: bool) -> Result<AnalyzeResult> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        if get_all {
            let results: Vec<String> = re
                .find_iter(content)
                .map(|m| m.as_str().to_string())
                .collect();
            Ok(AnalyzeResult::Multiple(results))
        } else {
            if let Some(mat) = re.find(content) {
                Ok(AnalyzeResult::Single(mat.as_str().to_string()))
            } else {
                Ok(AnalyzeResult::Single(String::new()))
            }
        }
    }
    
    /// 使用正则表达式提取捕获组
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::RegexAnalyzer;
    /// let content = "书名：《测试》，作者：张三";
    /// let result = RegexAnalyzer::capture(content, r"书名：《(.+?)》", 1, false)?;
    /// // 结果: "测试"
    /// # Ok(())
    /// # }
    /// ```
    pub fn capture(content: &str, pattern: &str, group: usize, get_all: bool) -> Result<AnalyzeResult> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        if get_all {
            let results: Vec<String> = re
                .captures_iter(content)
                .filter_map(|caps| caps.get(group).map(|m| m.as_str().to_string()))
                .collect();
            Ok(AnalyzeResult::Multiple(results))
        } else {
            if let Some(caps) = re.captures(content) {
                if let Some(mat) = caps.get(group) {
                    Ok(AnalyzeResult::Single(mat.as_str().to_string()))
                } else {
                    Ok(AnalyzeResult::Single(String::new()))
                }
            } else {
                Ok(AnalyzeResult::Single(String::new()))
            }
        }
    }
    
    /// 正则替换
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::RegexAnalyzer;
    /// let content = "  多余空格  ";
    /// let result = RegexAnalyzer::replace(content, r"\s+", " ")?;
    /// // 结果: " 多余空格 "
    /// # Ok(())
    /// # }
    /// ```
    pub fn replace(content: &str, pattern: &str, replacement: &str) -> Result<String> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        Ok(re.replace_all(content, replacement).to_string())
    }
    
    /// 正则替换（只替换第一个匹配）
    pub fn replace_first(content: &str, pattern: &str, replacement: &str) -> Result<String> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        Ok(re.replace(content, replacement).to_string())
    }
    
    /// 正则分割
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::RegexAnalyzer;
    /// let content = "项目1|项目2|项目3";
    /// let result = RegexAnalyzer::split(content, r"\|")?;
    /// // 结果: ["项目1", "项目2", "项目3"]
    /// # Ok(())
    /// # }
    /// ```
    pub fn split(content: &str, pattern: &str) -> Result<Vec<String>> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        let results: Vec<String> = re
            .split(content)
            .map(|s| s.to_string())
            .collect();
        
        Ok(results)
    }
    
    /// 智能提取（自动判断是匹配还是捕获组）
    /// 
    /// - 如果正则没有捕获组，返回整个匹配
    /// - 如果有捕获组，返回第一个捕获组
    pub fn extract(content: &str, pattern: &str, get_all: bool) -> Result<AnalyzeResult> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        // 检查是否有捕获组
        let has_captures = re.captures_len() > 1;
        
        if has_captures {
            // 有捕获组，提取第一个捕获组（group 1）
            Self::capture(content, pattern, 1, get_all)
        } else {
            // 没有捕获组，提取整个匹配
            Self::find(content, pattern, get_all)
        }
    }
    
    /// 多个捕获组提取（返回所有捕获组）
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::RegexAnalyzer;
    /// let content = "书名：《测试》，作者：张三";
    /// let result = RegexAnalyzer::capture_groups(content, r"书名：《(.+?)》，作者：(.+)")?;
    /// // 结果: ["测试", "张三"]
    /// # Ok(())
    /// # }
    /// ```
    pub fn capture_groups(content: &str, pattern: &str) -> Result<Vec<String>> {
        let re = Regex::new(pattern)
            .map_err(|e| anyhow!("无效的正则表达式 '{}': {}", pattern, e))?;
        
        if let Some(caps) = re.captures(content) {
            let results: Vec<String> = caps
                .iter()
                .skip(1) // 跳过完整匹配（group 0）
                .filter_map(|m| m.map(|m| m.as_str().to_string()))
                .collect();
            Ok(results)
        } else {
            Ok(vec![])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_find() {
        let content = "书名：《测试书名》，作者：张三";
        let result = RegexAnalyzer::find(content, r"《.+?》", false).unwrap();
        assert_eq!(result.as_string(), "《测试书名》");
    }
    
    #[test]
    fn test_find_all() {
        let content = "《书1》《书2》《书3》";
        let result = RegexAnalyzer::find(content, r"《.+?》", true).unwrap();
        let items = result.as_list();
        
        assert_eq!(items.len(), 3);
        assert_eq!(items[0], "《书1》");
        assert_eq!(items[1], "《书2》");
        assert_eq!(items[2], "《书3》");
    }
    
    #[test]
    fn test_capture() {
        let content = "书名：《测试书名》";
        let result = RegexAnalyzer::capture(content, r"《(.+?)》", 1, false).unwrap();
        assert_eq!(result.as_string(), "测试书名");
    }
    
    #[test]
    fn test_capture_all() {
        let content = "《书1》《书2》《书3》";
        let result = RegexAnalyzer::capture(content, r"《(.+?)》", 1, true).unwrap();
        let items = result.as_list();
        
        assert_eq!(items.len(), 3);
        assert_eq!(items[0], "书1");
        assert_eq!(items[1], "书2");
        assert_eq!(items[2], "书3");
    }
    
    #[test]
    fn test_replace() {
        let content = "  多余   空格  ";
        let result = RegexAnalyzer::replace(content, r"\s+", " ").unwrap();
        assert_eq!(result, " 多余 空格 ");
    }
    
    #[test]
    fn test_replace_first() {
        let content = "aaa bbb aaa";
        let result = RegexAnalyzer::replace_first(content, "aaa", "ccc").unwrap();
        assert_eq!(result, "ccc bbb aaa");
    }
    
    #[test]
    fn test_split() {
        let content = "项目1|项目2|项目3";
        let result = RegexAnalyzer::split(content, r"\|").unwrap();
        
        assert_eq!(result.len(), 3);
        assert_eq!(result[0], "项目1");
        assert_eq!(result[1], "项目2");
        assert_eq!(result[2], "项目3");
    }
    
    #[test]
    fn test_extract_with_capture() {
        let content = "书名：《测试》";
        let result = RegexAnalyzer::extract(content, r"《(.+?)》", false).unwrap();
        assert_eq!(result.as_string(), "测试");
    }
    
    #[test]
    fn test_extract_without_capture() {
        let content = "书名：《测试》";
        let result = RegexAnalyzer::extract(content, r"《.+?》", false).unwrap();
        assert_eq!(result.as_string(), "《测试》");
    }
    
    #[test]
    fn test_capture_groups() {
        let content = "书名：《测试》，作者：张三";
        let result = RegexAnalyzer::capture_groups(content, r"书名：《(.+?)》，作者：(.+)").unwrap();
        
        assert_eq!(result.len(), 2);
        assert_eq!(result[0], "测试");
        assert_eq!(result[1], "张三");
    }
    
    #[test]
    fn test_no_match() {
        let content = "没有匹配的内容";
        let result = RegexAnalyzer::find(content, r"《.+?》", false).unwrap();
        assert_eq!(result.as_string(), "");
    }
}
