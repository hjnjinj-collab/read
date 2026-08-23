//! 书源解析引擎
//! 
//! 提供 HTML/JSON/正则/JS 规则解析，支持 Legado 书源格式

pub mod types;
pub mod rule_parser;
pub mod analyzers;
pub mod http_client;

pub use types::*;
pub use rule_parser::RuleParser;
pub use analyzers::{JsoupAnalyzer, JsonPathAnalyzer, RegexAnalyzer};
pub use http_client::{HttpClient, HttpResponse, UrlUtils};

use anyhow::{anyhow, Result};

/// 书源引擎
pub struct BookSourceEngine {
    http_client: HttpClient,
}

impl BookSourceEngine {
    /// 创建新的书源引擎
    pub fn new() -> Result<Self> {
        Ok(Self {
            http_client: HttpClient::new()?,
        })
    }
    
    /// 搜索书籍
    /// 
    /// # 参数
    /// - `source`: 书源配置
    /// - `keyword`: 搜索关键词
    /// 
    /// # 返回
    /// 搜索结果列表
    pub async fn search(
        &self,
        source: &BookSource,
        keyword: &str,
    ) -> Result<Vec<SearchBookItem>> {
        if !source.enabled {
            return Err(anyhow!("书源已禁用"));
        }
        
        let search_rule = &source.rule_search;
        
        // 替换 URL 中的关键词占位符
        let url = search_rule.url.replace("{{key}}", keyword)
            .replace("{{keyword}}", keyword)
            .replace("${key}", keyword);
        
        // 发送请求
        let response = if search_rule.method.to_uppercase() == "POST" {
            let body = if !search_rule.body.is_empty() {
                Some(search_rule.body.replace("{{key}}", keyword))
            } else {
                None
            };
            self.http_client.post(&url, body).await?
        } else {
            self.http_client.get(&url).await?
        };
        
        if !response.is_success() {
            return Err(anyhow!("HTTP 请求失败: {}", response.status));
        }
        
        // 解析搜索结果
        self.parse_search_result(&response.body, source, &url)
    }
    
    /// 解析搜索结果
    fn parse_search_result(
        &self,
        content: &str,
        source: &BookSource,
        base_url: &str,
    ) -> Result<Vec<SearchBookItem>> {
        let search_rule = &source.rule_search;
        
        // 1. 提取书籍列表
        let book_list_rule = RuleParser::parse(&search_rule.book_list)?;
        let book_list = self.analyze(content, &book_list_rule)?;
        
        let book_elements = match book_list {
            AnalyzeResult::Multiple(list) => list,
            AnalyzeResult::Single(single) => vec![single],
            AnalyzeResult::Object(_) => return Err(anyhow!("书籍列表规则返回了对象")),
        };
        
        // 2. 遍历每个书籍元素，提取字段
        let mut results = Vec::new();
        
        for book_html in book_elements {
            let name = self.extract_field(&book_html, &search_rule.name)?;
            let author = self.extract_field(&book_html, &search_rule.author)?;
            let book_url = self.extract_field(&book_html, &search_rule.book_url)?;
            
            // 可选字段
            let kind = self.extract_field(&book_html, &search_rule.kind).unwrap_or_default();
            let last_chapter = self.extract_field(&book_html, &search_rule.last_chapter).unwrap_or_default();
            let intro = self.extract_field(&book_html, &search_rule.intro).unwrap_or_default();
            let cover_url = self.extract_field(&book_html, &search_rule.cover_url).unwrap_or_default();
            
            // 处理相对 URL
            let book_url = UrlUtils::resolve(base_url, &book_url)?;
            let cover_url = if !cover_url.is_empty() {
                UrlUtils::resolve(base_url, &cover_url).unwrap_or(cover_url)
            } else {
                cover_url
            };
            
            results.push(SearchBookItem {
                name,
                author,
                kind,
                last_chapter,
                intro,
                cover_url,
                book_url,
                source_url: source.book_source_url.clone(),
            });
        }
        
        Ok(results)
    }
    
    /// 获取书籍信息
    pub async fn get_book_info(
        &self,
        source: &BookSource,
        book_url: &str,
    ) -> Result<BookInfo> {
        if !source.enabled {
            return Err(anyhow!("书源已禁用"));
        }
        
        // 发送请求
        let response = self.http_client.get(book_url).await?;
        
        if !response.is_success() {
            return Err(anyhow!("HTTP 请求失败: {}", response.status));
        }
        
        let info_rule = &source.rule_book_info;
        let content = &response.body;
        
        // 提取字段
        let name = self.extract_field(content, &info_rule.name)?;
        let author = self.extract_field(content, &info_rule.author)?;
        let toc_url = self.extract_field(content, &info_rule.toc_url)?;
        
        let kind = self.extract_field(content, &info_rule.kind).unwrap_or_default();
        let last_chapter = self.extract_field(content, &info_rule.last_chapter).unwrap_or_default();
        let intro = self.extract_field(content, &info_rule.intro).unwrap_or_default();
        let cover_url = self.extract_field(content, &info_rule.cover_url).unwrap_or_default();
        let word_count = self.extract_field(content, &info_rule.word_count).unwrap_or_default();
        
        // 处理相对 URL
        let toc_url = UrlUtils::resolve(book_url, &toc_url)?;
        let cover_url = if !cover_url.is_empty() {
            UrlUtils::resolve(book_url, &cover_url).unwrap_or(cover_url)
        } else {
            cover_url
        };
        
        Ok(BookInfo {
            name,
            author,
            kind,
            last_chapter,
            intro,
            cover_url,
            toc_url,
            word_count,
        })
    }
    
    /// 获取章节目录
    pub async fn get_toc(
        &self,
        source: &BookSource,
        toc_url: &str,
    ) -> Result<Vec<ChapterInfo>> {
        if !source.enabled {
            return Err(anyhow!("书源已禁用"));
        }
        
        let response = self.http_client.get(toc_url).await?;
        
        if !response.is_success() {
            return Err(anyhow!("HTTP 请求失败: {}", response.status));
        }
        
        let toc_rule = &source.rule_toc;
        let content = &response.body;
        
        // 提取章节列表
        let chapter_list_rule = RuleParser::parse(&toc_rule.chapter_list)?;
        let chapter_list = self.analyze(content, &chapter_list_rule)?;
        
        let chapter_elements = match chapter_list {
            AnalyzeResult::Multiple(list) => list,
            AnalyzeResult::Single(single) => vec![single],
            AnalyzeResult::Object(_) => return Err(anyhow!("章节列表规则返回了对象")),
        };
        
        let mut results = Vec::new();
        
        for (index, chapter_html) in chapter_elements.iter().enumerate() {
            let name = self.extract_field(chapter_html, &toc_rule.chapter_name)?;
            let url = self.extract_field(chapter_html, &toc_rule.chapter_url)?;
            
            let is_vip = self.extract_field(chapter_html, &toc_rule.is_vip)
                .unwrap_or_else(|_| "false".to_string())
                .to_lowercase() == "true";
            
            let update_time = self.extract_field(chapter_html, &toc_rule.update_time).unwrap_or_default();
            
            let is_volume = self.extract_field(chapter_html, &toc_rule.is_volume)
                .unwrap_or_else(|_| "false".to_string())
                .to_lowercase() == "true";
            
            // 处理相对 URL
            let url = UrlUtils::resolve(toc_url, &url)?;
            
            results.push(ChapterInfo {
                name,
                url,
                is_vip,
                update_time,
                is_volume,
                index,
            });
        }
        
        Ok(results)
    }
    
    /// 获取章节正文
    pub async fn get_content(
        &self,
        source: &BookSource,
        chapter_url: &str,
    ) -> Result<ChapterContent> {
        if !source.enabled {
            return Err(anyhow!("书源已禁用"));
        }
        
        let response = self.http_client.get(chapter_url).await?;
        
        if !response.is_success() {
            return Err(anyhow!("HTTP 请求失败: {}", response.status));
        }
        
        let content_rule = &source.rule_content;
        let html = &response.body;
        
        // 提取正文
        let content = self.extract_field(html, &content_rule.content)?;
        
        // 提取下一页 URL（如果有）
        let next_url = if !content_rule.next_content_url.is_empty() {
            self.extract_field(html, &content_rule.next_content_url).ok()
                .and_then(|url| UrlUtils::resolve(chapter_url, &url).ok())
        } else {
            None
        };
        
        // 应用替换规则
        let content = if !content_rule.replace_regex.is_empty() {
            self.apply_replace_rule(&content, &content_rule.replace_regex)?
        } else {
            content
        };
        
        Ok(ChapterContent {
            content,
            next_url,
        })
    }
    
    /// 提取字段值
    fn extract_field(&self, content: &str, rule: &str) -> Result<String> {
        if rule.is_empty() {
            return Ok(String::new());
        }
        
        let parsed_rule = RuleParser::parse(rule)?;
        let result = self.analyze(content, &parsed_rule)?;
        
        Ok(result.as_string())
    }
    
    /// 执行分析
    fn analyze(&self, content: &str, rule: &ParsedRule) -> Result<AnalyzeResult> {
        // 先根据规则类型选择分析器
        let result = match rule.rule_type {
            RuleType::Css | RuleType::Default => {
                JsoupAnalyzer::select_smart(content, &rule.expression, rule.get_all)?
            }
            RuleType::Json => {
                JsonPathAnalyzer::query(content, &rule.expression, rule.get_all)?
            }
            RuleType::Regex => {
                RegexAnalyzer::extract(content, &rule.expression, rule.get_all)?
            }
            RuleType::XPath => {
                // XPath 暂未实现，降级为 CSS
                JsoupAnalyzer::select_smart(content, &rule.expression, rule.get_all)?
            }
            RuleType::JavaScript => {
                // JS 引擎在 Flutter 侧实现
                return Err(anyhow!("JavaScript 规则需要在 Flutter 侧执行"));
            }
        };
        
        // 应用正则替换规则（如果有）
        if let Some((regex_pattern, replacement)) = &rule.regex_replacement {
            let content_str = result.as_string();
            let replaced = RegexAnalyzer::replace(&content_str, regex_pattern, replacement)?;
            Ok(AnalyzeResult::Single(replaced))
        } else {
            Ok(result)
        }
    }
    
    /// 应用替换规则
    fn apply_replace_rule(&self, content: &str, rule: &str) -> Result<String> {
        let parsed = RuleParser::parse(rule)?;
        
        if let Some((regex_pattern, replacement)) = parsed.regex_replacement {
            RegexAnalyzer::replace(content, &regex_pattern, &replacement)
        } else {
            Ok(content.to_string())
        }
    }
}

impl Default for BookSourceEngine {
    fn default() -> Self {
        Self::new().unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_parse_book_source() {
        let json = r#"{
            "bookSourceUrl": "https://example.com",
            "bookSourceName": "示例书源",
            "enabled": true,
            "ruleSearch": {
                "url": "https://example.com/search?key={{key}}",
                "bookList": ".book-item",
                "name": ".title",
                "author": ".author",
                "bookUrl": "a@href"
            }
        }"#;
        
        let source: BookSource = serde_json::from_str(json).unwrap();
        
        assert_eq!(source.book_source_url, "https://example.com");
        assert_eq!(source.book_source_name, "示例书源");
        assert!(source.enabled);
        assert_eq!(source.rule_search.book_list, ".book-item");
    }
}
