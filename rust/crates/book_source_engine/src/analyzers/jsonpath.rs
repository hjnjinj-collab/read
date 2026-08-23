use anyhow::{anyhow, Result};
use serde_json::Value;
use crate::types::AnalyzeResult;

/// JSONPath 分析器
/// 
/// 支持简化的 JSONPath 语法：
/// - `$.data.list` - 访问嵌套属性
/// - `$[0]` - 访问数组元素
/// - `$.data.list[*]` - 访问数组所有元素
/// - `$.data.list[0].name` - 组合访问
pub struct JsonPathAnalyzer;

impl JsonPathAnalyzer {
    /// 使用 JSONPath 提取内容
    /// 
    /// # 参数
    /// - `json`: JSON 字符串
    /// - `path`: JSONPath 表达式
    /// - `get_all`: 是否获取所有匹配项
    /// 
    /// # 示例
    /// ```
    /// # fn main() -> Result<(), Box<dyn std::error::Error>> {
    /// use book_source_engine::JsonPathAnalyzer;
    /// let json = r#"{"data": {"list": [{"name": "书1"}, {"name": "书2"}]}}"#;
    /// let result = JsonPathAnalyzer::query(json, "$.data.list[*].name", true)?;
    /// // 结果: ["书1", "书2"]
    /// # Ok(())
    /// # }
    /// ```
    pub fn query(json: &str, path: &str, get_all: bool) -> Result<AnalyzeResult> {
        let value: Value = serde_json::from_str(json)
            .map_err(|e| anyhow!("JSON 解析失败: {}", e))?;
        
        let results = Self::query_value(&value, path)?;
        
        if results.is_empty() {
            return Ok(AnalyzeResult::Multiple(vec![]));
        }
        
        if get_all {
            let strings: Vec<String> = results
                .iter()
                .map(|v| Self::value_to_string(v))
                .collect();
            Ok(AnalyzeResult::Multiple(strings))
        } else {
            let text = Self::value_to_string(&results[0]);
            Ok(AnalyzeResult::Single(text))
        }
    }
    
    /// 在 JSON Value 上执行 JSONPath 查询
    fn query_value(value: &Value, path: &str) -> Result<Vec<Value>> {
        let path = path.trim();
        
        // 移除开头的 $ 符号
        let path = if path.starts_with('$') {
            &path[1..]
        } else {
            path
        };
        
        // 如果路径为空，返回根节点
        if path.is_empty() || path == "." {
            return Ok(vec![value.clone()]);
        }
        
        // 解析路径段
        let segments = Self::parse_path(path)?;
        
        // 执行查询
        let mut current = vec![value.clone()];
        
        for segment in segments {
            let mut next = Vec::new();
            
            for val in current {
                match segment {
                    PathSegment::Property(ref prop) => {
                        if let Some(v) = val.get(prop) {
                            next.push(v.clone());
                        }
                    }
                    PathSegment::Index(index) => {
                        if let Some(v) = val.get(index) {
                            next.push(v.clone());
                        }
                    }
                    PathSegment::AllElements => {
                        if let Some(arr) = val.as_array() {
                            next.extend(arr.iter().cloned());
                        }
                    }
                }
            }
            
            current = next;
        }
        
        Ok(current)
    }
    
    /// 解析 JSONPath 为路径段
    fn parse_path(path: &str) -> Result<Vec<PathSegment>> {
        let mut segments = Vec::new();
        let mut current = String::new();
        let mut in_brackets = false;
        
        for ch in path.chars() {
            match ch {
                '.' if !in_brackets => {
                    if !current.is_empty() {
                        segments.push(PathSegment::Property(current.clone()));
                        current.clear();
                    }
                }
                '[' => {
                    if !current.is_empty() {
                        segments.push(PathSegment::Property(current.clone()));
                        current.clear();
                    }
                    in_brackets = true;
                }
                ']' => {
                    if in_brackets {
                        if current == "*" {
                            segments.push(PathSegment::AllElements);
                        } else if let Ok(index) = current.parse::<usize>() {
                            segments.push(PathSegment::Index(index));
                        } else if !current.is_empty() {
                            // 字符串索引（作为属性名）
                            segments.push(PathSegment::Property(current.clone()));
                        }
                        current.clear();
                        in_brackets = false;
                    }
                }
                _ => {
                    current.push(ch);
                }
            }
        }
        
        // 处理最后一个段
        if !current.is_empty() {
            segments.push(PathSegment::Property(current));
        }
        
        Ok(segments)
    }
    
    /// 将 JSON Value 转换为字符串
    fn value_to_string(value: &Value) -> String {
        match value {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            Value::Null => String::new(),
            Value::Array(_) | Value::Object(_) => {
                serde_json::to_string(value).unwrap_or_default()
            }
        }
    }
    
    /// 提取 JSON 对象的所有键
    pub fn get_keys(json: &str) -> Result<Vec<String>> {
        let value: Value = serde_json::from_str(json)
            .map_err(|e| anyhow!("JSON 解析失败: {}", e))?;
        
        if let Some(obj) = value.as_object() {
            Ok(obj.keys().cloned().collect())
        } else {
            Ok(vec![])
        }
    }
    
    /// 提取数组长度
    pub fn array_length(json: &str, path: &str) -> Result<usize> {
        let value: Value = serde_json::from_str(json)
            .map_err(|e| anyhow!("JSON 解析失败: {}", e))?;
        
        let results = Self::query_value(&value, path)?;
        
        if results.is_empty() {
            return Ok(0);
        }
        
        if let Some(arr) = results[0].as_array() {
            Ok(arr.len())
        } else {
            Ok(0)
        }
    }
}

/// JSONPath 路径段
#[derive(Debug, Clone, PartialEq)]
enum PathSegment {
    /// 对象属性: `.name` 或 `['name']`
    Property(String),
    
    /// 数组索引: `[0]`
    Index(usize),
    
    /// 所有元素: `[*]`
    AllElements,
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_simple_property() {
        let json = r#"{"name": "测试书名"}"#;
        let result = JsonPathAnalyzer::query(json, "$.name", false).unwrap();
        assert_eq!(result.as_string(), "测试书名");
    }
    
    #[test]
    fn test_nested_property() {
        let json = r#"{"data": {"book": {"name": "测试书名"}}}"#;
        let result = JsonPathAnalyzer::query(json, "$.data.book.name", false).unwrap();
        assert_eq!(result.as_string(), "测试书名");
    }
    
    #[test]
    fn test_array_index() {
        let json = r#"{"list": ["项目1", "项目2", "项目3"]}"#;
        let result = JsonPathAnalyzer::query(json, "$.list[1]", false).unwrap();
        assert_eq!(result.as_string(), "项目2");
    }
    
    #[test]
    fn test_array_all_elements() {
        let json = r#"{"list": ["项目1", "项目2", "项目3"]}"#;
        let result = JsonPathAnalyzer::query(json, "$.list[*]", true).unwrap();
        let items = result.as_list();
        
        assert_eq!(items.len(), 3);
        assert_eq!(items[0], "项目1");
        assert_eq!(items[1], "项目2");
        assert_eq!(items[2], "项目3");
    }
    
    #[test]
    fn test_array_of_objects() {
        let json = r#"{
            "data": {
                "list": [
                    {"name": "书1", "author": "作者1"},
                    {"name": "书2", "author": "作者2"}
                ]
            }
        }"#;
        
        let result = JsonPathAnalyzer::query(json, "$.data.list[*].name", true).unwrap();
        let items = result.as_list();
        
        assert_eq!(items.len(), 2);
        assert_eq!(items[0], "书1");
        assert_eq!(items[1], "书2");
    }
    
    #[test]
    fn test_get_keys() {
        let json = r#"{"name": "书名", "author": "作者", "price": 100}"#;
        let keys = JsonPathAnalyzer::get_keys(json).unwrap();
        
        assert_eq!(keys.len(), 3);
        assert!(keys.contains(&"name".to_string()));
        assert!(keys.contains(&"author".to_string()));
        assert!(keys.contains(&"price".to_string()));
    }
    
    #[test]
    fn test_array_length() {
        let json = r#"{"list": [1, 2, 3, 4, 5]}"#;
        let length = JsonPathAnalyzer::array_length(json, "$.list").unwrap();
        assert_eq!(length, 5);
    }
    
    #[test]
    fn test_parse_path() {
        let segments = JsonPathAnalyzer::parse_path(".data.list[0].name").unwrap();
        
        assert_eq!(segments.len(), 4);
        assert_eq!(segments[0], PathSegment::Property("data".to_string()));
        assert_eq!(segments[1], PathSegment::Property("list".to_string()));
        assert_eq!(segments[2], PathSegment::Index(0));
        assert_eq!(segments[3], PathSegment::Property("name".to_string()));
    }
    
    #[test]
    fn test_parse_path_wildcard() {
        let segments = JsonPathAnalyzer::parse_path(".list[*].name").unwrap();
        
        assert_eq!(segments.len(), 3);
        assert_eq!(segments[0], PathSegment::Property("list".to_string()));
        assert_eq!(segments[1], PathSegment::AllElements);
        assert_eq!(segments[2], PathSegment::Property("name".to_string()));
    }
    
    #[test]
    fn test_no_match() {
        let json = r#"{"name": "书名"}"#;
        let result = JsonPathAnalyzer::query(json, "$.not_exist", false).unwrap();
        assert_eq!(result.as_list().len(), 0);
    }
    
    #[test]
    fn test_number_value() {
        let json = r#"{"price": 99.5}"#;
        let result = JsonPathAnalyzer::query(json, "$.price", false).unwrap();
        assert_eq!(result.as_string(), "99.5");
    }
    
    #[test]
    fn test_boolean_value() {
        let json = r#"{"available": true}"#;
        let result = JsonPathAnalyzer::query(json, "$.available", false).unwrap();
        assert_eq!(result.as_string(), "true");
    }
}
