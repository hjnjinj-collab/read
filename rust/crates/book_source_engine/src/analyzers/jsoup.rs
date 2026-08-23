use anyhow::{anyhow, Result};
use scraper::{Html, Selector};
use crate::types::AnalyzeResult;

/// HTML/CSS 选择器分析器
pub struct JsoupAnalyzer;

impl JsoupAnalyzer {
    /// 使用 CSS 选择器提取内容
    /// 
    /// # 参数
    /// - `html`: HTML 内容
    /// - `selector`: CSS 选择器
    /// - `get_all`: 是否获取所有匹配项（false 只返回第一个）
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::JsoupAnalyzer;
    /// let html = r#"<div class="book"><span class="title">书名</span></div>"#;
    /// let result = JsoupAnalyzer::select(html, ".title", false)?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn select(html: &str, selector: &str, get_all: bool) -> Result<AnalyzeResult> {
        let document = Html::parse_document(html);
        let selector = Selector::parse(selector)
            .map_err(|e| anyhow!("无效的 CSS 选择器 '{}': {:?}", selector, e))?;
        
        let elements: Vec<_> = document.select(&selector).collect();
        
        if elements.is_empty() {
            return Ok(AnalyzeResult::Multiple(vec![]));
        }
        
        if get_all {
            let results: Vec<String> = elements
                .iter()
                .map(|el| Self::extract_text(el))
                .collect();
            Ok(AnalyzeResult::Multiple(results))
        } else {
            let text = Self::extract_text(&elements[0]);
            Ok(AnalyzeResult::Single(text))
        }
    }
    
    /// 获取元素的文本内容
    fn extract_text(element: &scraper::ElementRef) -> String {
        element.text().collect::<Vec<_>>().join("")
    }
    
    /// 获取元素的 HTML 内容
    pub fn select_html(html: &str, selector: &str, get_all: bool) -> Result<AnalyzeResult> {
        let document = Html::parse_document(html);
        let selector = Selector::parse(selector)
            .map_err(|e| anyhow!("无效的 CSS 选择器 '{}': {:?}", selector, e))?;
        
        let elements: Vec<_> = document.select(&selector).collect();
        
        if elements.is_empty() {
            return Ok(AnalyzeResult::Multiple(vec![]));
        }
        
        if get_all {
            let results: Vec<String> = elements
                .iter()
                .map(|el| el.html())
                .collect();
            Ok(AnalyzeResult::Multiple(results))
        } else {
            let html = elements[0].html();
            Ok(AnalyzeResult::Single(html))
        }
    }
    
    /// 获取元素的属性值
    /// 
    /// 选择器格式: `.selector@attr` 或 `.selector@href`
    pub fn select_attr(html: &str, selector: &str, attr: &str, get_all: bool) -> Result<AnalyzeResult> {
        let document = Html::parse_document(html);
        let selector = Selector::parse(selector)
            .map_err(|e| anyhow!("无效的 CSS 选择器 '{}': {:?}", selector, e))?;
        
        let elements: Vec<_> = document.select(&selector).collect();
        
        if elements.is_empty() {
            return Ok(AnalyzeResult::Multiple(vec![]));
        }
        
        if get_all {
            let results: Vec<String> = elements
                .iter()
                .filter_map(|el| el.value().attr(attr).map(|v| v.to_string()))
                .collect();
            Ok(AnalyzeResult::Multiple(results))
        } else {
            if let Some(value) = elements[0].value().attr(attr) {
                Ok(AnalyzeResult::Single(value.to_string()))
            } else {
                Ok(AnalyzeResult::Single(String::new()))
            }
        }
    }
    
    /// 解析选择器中的属性指定
    /// 
    /// 例如: `.book-title@text` -> (`.book-title`, `text`)
    ///      `.book-link@href` -> (`.book-link`, `href`)
    pub fn parse_selector_with_attr(rule: &str) -> (String, Option<String>) {
        if let Some(at_pos) = rule.rfind('@') {
            let selector = rule[..at_pos].to_string();
            let attr = rule[at_pos + 1..].to_string();
            
            // 特殊属性名
            match attr.as_str() {
                "text" => (selector, None),           // 提取文本
                "html" => (selector, Some("__html__".to_string())),  // 提取 HTML
                _ => (selector, Some(attr)),          // 提取指定属性
            }
        } else {
            (rule.to_string(), None)
        }
    }
    
    /// 智能选择（自动判断是文本、HTML 还是属性）
    pub fn select_smart(html: &str, rule: &str, get_all: bool) -> Result<AnalyzeResult> {
        let (selector, attr) = Self::parse_selector_with_attr(rule);
        
        match attr {
            None => {
                // 提取文本
                Self::select(html, &selector, get_all)
            }
            Some(ref a) if a == "__html__" => {
                // 提取 HTML
                Self::select_html(html, &selector, get_all)
            }
            Some(ref a) => {
                // 提取属性
                Self::select_attr(html, &selector, a, get_all)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_select_text() {
        let html = r#"
            <div class="book">
                <span class="title">测试书名</span>
                <span class="author">测试作者</span>
            </div>
        "#;
        
        let result = JsoupAnalyzer::select(html, ".title", false).unwrap();
        assert_eq!(result.as_string(), "测试书名");
    }
    
    #[test]
    fn test_select_all() {
        let html = r#"
            <ul>
                <li class="item">项目1</li>
                <li class="item">项目2</li>
                <li class="item">项目3</li>
            </ul>
        "#;
        
        let result = JsoupAnalyzer::select(html, ".item", true).unwrap();
        let items = result.as_list();
        
        assert_eq!(items.len(), 3);
        assert_eq!(items[0], "项目1");
        assert_eq!(items[1], "项目2");
        assert_eq!(items[2], "项目3");
    }
    
    #[test]
    fn test_select_attr() {
        let html = r#"
            <div class="book">
                <a href="/book/123" class="link">详情</a>
            </div>
        "#;
        
        let result = JsoupAnalyzer::select_attr(html, ".link", "href", false).unwrap();
        assert_eq!(result.as_string(), "/book/123");
    }
    
    #[test]
    fn test_parse_selector_with_attr() {
        let (selector, attr) = JsoupAnalyzer::parse_selector_with_attr(".link@href");
        assert_eq!(selector, ".link");
        assert_eq!(attr, Some("href".to_string()));
        
        let (selector, attr) = JsoupAnalyzer::parse_selector_with_attr(".title@text");
        assert_eq!(selector, ".title");
        assert_eq!(attr, None);
    }
    
    #[test]
    fn test_select_smart() {
        let html = r#"
            <div class="book">
                <span class="title">书名</span>
                <a href="/book/123" class="link">链接</a>
            </div>
        "#;
        
        // 文本
        let result = JsoupAnalyzer::select_smart(html, ".title@text", false).unwrap();
        assert_eq!(result.as_string(), "书名");
        
        // 属性
        let result = JsoupAnalyzer::select_smart(html, ".link@href", false).unwrap();
        assert_eq!(result.as_string(), "/book/123");
        
        // HTML
        let result = JsoupAnalyzer::select_smart(html, ".book@html", false).unwrap();
        assert!(result.as_string().contains("<span"));
    }
    
    #[test]
    fn test_empty_result() {
        let html = r#"<div class="empty"></div>"#;
        
        let result = JsoupAnalyzer::select(html, ".not-exist", false).unwrap();
        assert_eq!(result.as_list().len(), 0);
    }
}
