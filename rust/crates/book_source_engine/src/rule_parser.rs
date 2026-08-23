use crate::types::{ParsedRule, RuleType};
use anyhow::{anyhow, Result};

/// 规则解析器
pub struct RuleParser;

impl RuleParser {
    /// 解析规则字符串
    /// 
    /// 规则格式示例：
    /// - `@css:.book-name` - CSS 选择器
    /// - `@json:$.data.list` - JSONPath
    /// - `@xpath://div[@class='title']` - XPath
    /// - `@js:java.title` - JavaScript
    /// - `##正则##替换文本` - 正则替换
    /// - `.book-name` - 默认（自动检测）
    pub fn parse(rule: &str) -> Result<ParsedRule> {
        if rule.is_empty() {
            return Err(anyhow!("规则不能为空"));
        }
        
        // 不要在这里 trim，因为正则替换规则可能需要保留空格
        // let rule = rule.trim();
        
        // 检查是否有规则类型前缀
        let (rule_type, expression, get_all) = if rule.starts_with("@@") {
            // @@css: 表示获取所有匹配项
            let rest = &rule[2..];
            let (rt, expr) = Self::parse_type_prefix(rest)?;
            (rt, expr, true)
        } else if rule.starts_with('@') {
            // @css: 表示获取第一个匹配项
            let rest = &rule[1..];
            let (rt, expr) = Self::parse_type_prefix(rest)?;
            (rt, expr, false)
        } else {
            // 没有前缀，自动检测
            (RuleType::Default, rule.to_string(), false)
        };
        
        // 检查是否有正则替换
        let (expression, regex_replacement) = Self::parse_regex_replacement(&expression)?;
        
        Ok(ParsedRule {
            rule_type,
            expression,
            regex_replacement,
            get_all,
        })
    }
    
    /// 解析类型前缀（css:, json:, xpath:, js:）
    fn parse_type_prefix(rule: &str) -> Result<(RuleType, String)> {
        if let Some(colon_pos) = rule.find(':') {
            let type_str = &rule[..colon_pos];
            let expression = &rule[colon_pos + 1..];
            
            let rule_type = match type_str.to_lowercase().as_str() {
                "css" => RuleType::Css,
                "xpath" => RuleType::XPath,
                "json" => RuleType::Json,
                "js" => RuleType::JavaScript,
                _ => return Err(anyhow!("未知的规则类型: {}", type_str)),
            };
            
            Ok((rule_type, expression.to_string()))
        } else {
            // 没有冒号，使用默认类型
            Ok((RuleType::Default, rule.to_string()))
        }
    }
    
    /// 解析正则替换规则
    /// 格式: ##正则表达式##替换文本
    fn parse_regex_replacement(rule: &str) -> Result<(String, Option<(String, String)>)> {
        if !rule.contains("##") {
            return Ok((rule.to_string(), None));
        }
        
        let parts: Vec<&str> = rule.split("##").collect();
        
        if parts.len() >= 3 && parts[0].is_empty() {
            // ##regex##replacement 格式
            let regex_pattern = parts[1].to_string();
            let replacement = parts[2].to_string();
            Ok((regex_pattern.clone(), Some((regex_pattern, replacement))))
        } else if parts.len() >= 3 {
            // rule##regex##replacement 格式（规则后跟正则替换）
            let base_rule = parts[0].to_string();
            let regex_pattern = parts[1].to_string();
            let replacement = parts[2].to_string();
            Ok((base_rule, Some((regex_pattern, replacement))))
        } else if parts.len() == 2 {
            // rule##regex 格式（只有规则和正则，没有替换）
            let base_rule = parts[0].to_string();
            Ok((base_rule, None))
        } else {
            Ok((rule.to_string(), None))
        }
    }
    
    /// 拆分规则（处理 @, |, &, || 等分隔符）
    /// 
    /// 分隔符说明：
    /// - `@` - 顺序执行，前一个结果作为下一个的输入
    /// - `|` - 取第一个非空结果
    /// - `&` - 合并所有结果
    /// - `||` - 或运算，有一个成功就返回
    pub fn split_rules(rule: &str) -> Vec<String> {
        let mut rules = Vec::new();
        let mut current = String::new();
        let mut in_brackets = 0; // 跟踪 {{}} 嵌套层级
        
        let chars: Vec<char> = rule.chars().collect();
        let mut i = 0;
        
        while i < chars.len() {
            let ch = chars[i];
            
            // 检查嵌套规则标记 {{}}
            if ch == '{' && i + 1 < chars.len() && chars[i + 1] == '{' {
                in_brackets += 1;
                current.push(ch);
                current.push(chars[i + 1]);
                i += 2;
                continue;
            } else if ch == '}' && i + 1 < chars.len() && chars[i + 1] == '}' {
                in_brackets -= 1;
                current.push(ch);
                current.push(chars[i + 1]);
                i += 2;
                continue;
            }
            
            // 只在不在嵌套规则内时处理分隔符
            if in_brackets == 0 {
                // 检查分隔符
                if ch == '@' || ch == '|' || ch == '&' {
                    if !current.trim().is_empty() {
                        rules.push(current.trim().to_string());
                        current.clear();
                    }
                    i += 1;
                    continue;
                }
            }
            
            current.push(ch);
            i += 1;
        }
        
        // 添加最后一个规则
        if !current.trim().is_empty() {
            rules.push(current.trim().to_string());
        }
        
        rules
    }
    
    /// 展开嵌套规则 {{...}}
    /// 例如: "{{$.data.list}}@.title" -> 先执行 $.data.list，结果作为上下文再执行 .title
    pub fn expand_nested_rules(rule: &str) -> Result<String> {
        let mut result = rule.to_string();
        
        // 简单实现：查找并标记嵌套规则
        // 完整实现需要递归处理嵌套的 {{}}
        while let Some(start) = result.find("{{") {
            if let Some(end) = result[start..].find("}}") {
                let nested_rule = &result[start + 2..start + end];
                // 这里只是标记，实际执行需要在分析器中处理
                result = result.replace(
                    &format!("{{{{{}}}}}", nested_rule),
                    &format!("__NESTED__[{}]", nested_rule),
                );
            } else {
                break;
            }
        }
        
        Ok(result)
    }
    
    /// 自动检测规则类型
    pub fn detect_type(rule: &str) -> RuleType {
        let rule = rule.trim();
        
        // JSONPath 通常以 $ 或 @. 开头
        if rule.starts_with('$') || rule.starts_with("@.") {
            return RuleType::Json;
        }
        
        // XPath 通常以 / 或 // 开头
        if rule.starts_with('/') {
            return RuleType::XPath;
        }
        
        // 正则表达式（包含特殊字符）
        if rule.contains("##") {
            return RuleType::Regex;
        }
        
        // 默认使用 CSS 选择器
        RuleType::Css
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_parse_css_rule() {
        let rule = "@css:.book-name";
        let parsed = RuleParser::parse(rule).unwrap();
        
        assert_eq!(parsed.rule_type, RuleType::Css);
        assert_eq!(parsed.expression, ".book-name");
        assert!(!parsed.get_all);
    }
    
    #[test]
    fn test_parse_css_rule_all() {
        let rule = "@@css:.book-item";
        let parsed = RuleParser::parse(rule).unwrap();
        
        assert_eq!(parsed.rule_type, RuleType::Css);
        assert_eq!(parsed.expression, ".book-item");
        assert!(parsed.get_all);
    }
    
    #[test]
    fn test_parse_json_rule() {
        let rule = "@json:$.data.list";
        let parsed = RuleParser::parse(rule).unwrap();
        
        assert_eq!(parsed.rule_type, RuleType::Json);
        assert_eq!(parsed.expression, "$.data.list");
    }
    
    #[test]
    fn test_parse_regex_replacement() {
        let rule = ".title##\\s+## ";
        let parsed = RuleParser::parse(rule).unwrap();
        
        assert_eq!(parsed.expression, ".title");
        assert_eq!(parsed.regex_replacement, Some(("\\s+".to_string(), " ".to_string())));
    }
    
    #[test]
    fn test_split_rules() {
        let rule = ".book-list@.title|.name";
        let rules = RuleParser::split_rules(rule);
        
        assert_eq!(rules.len(), 3);
        assert_eq!(rules[0], ".book-list");
        assert_eq!(rules[1], ".title");
        assert_eq!(rules[2], ".name");
    }
    
    #[test]
    fn test_split_nested_rules() {
        let rule = "{{$.data.list}}@.title";
        let rules = RuleParser::split_rules(rule);
        
        assert_eq!(rules.len(), 2);
        assert!(rules[0].contains("{{"));
        assert_eq!(rules[1], ".title");
    }
    
    #[test]
    fn test_detect_type() {
        assert_eq!(RuleParser::detect_type("$.data"), RuleType::Json);
        assert_eq!(RuleParser::detect_type("//div"), RuleType::XPath);
        assert_eq!(RuleParser::detect_type(".title##test##"), RuleType::Regex);
        assert_eq!(RuleParser::detect_type(".book-name"), RuleType::Css);
    }
}
