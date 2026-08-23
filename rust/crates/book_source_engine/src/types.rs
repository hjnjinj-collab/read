use serde::{Deserialize, Serialize};

/// 书源配置
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookSource {
    /// 书源 URL（唯一标识）
    pub book_source_url: String,
    
    /// 书源名称
    pub book_source_name: String,
    
    /// 书源分组
    #[serde(default)]
    pub book_source_group: String,
    
    /// 书源类型: 0=文字, 1=音频
    #[serde(default)]
    pub book_source_type: i32,
    
    /// 是否启用
    #[serde(default = "default_true")]
    pub enabled: bool,
    
    /// 启用发现
    #[serde(default)]
    pub enabled_explore: bool,
    
    /// 请求头
    #[serde(default)]
    pub header: String,
    
    /// 登录 URL
    #[serde(default)]
    pub login_url: String,
    
    /// Cookie
    #[serde(default)]
    pub cookie: String,
    
    /// 搜索规则
    #[serde(default)]
    pub rule_search: SearchRule,
    
    /// 书籍信息规则
    #[serde(default)]
    pub rule_book_info: BookInfoRule,
    
    /// 目录规则
    #[serde(default)]
    pub rule_toc: TocRule,
    
    /// 正文规则
    #[serde(default)]
    pub rule_content: ContentRule,
    
    /// 发现规则
    #[serde(default)]
    pub rule_explore: Option<String>,
    
    /// 权重（用于排序）
    #[serde(default)]
    pub weight: i32,
}

fn default_true() -> bool {
    true
}

/// 搜索规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRule {
    /// 搜索 URL
    pub url: String,
    
    /// 搜索方法: GET, POST
    #[serde(default = "default_get")]
    pub method: String,
    
    /// POST 请求体
    #[serde(default)]
    pub body: String,
    
    /// 字符集
    #[serde(default)]
    pub charset: String,
    
    /// 书籍列表规则
    pub book_list: String,
    
    /// 书名规则
    pub name: String,
    
    /// 作者规则
    pub author: String,
    
    /// 分类规则
    #[serde(default)]
    pub kind: String,
    
    /// 最新章节规则
    #[serde(default)]
    pub last_chapter: String,
    
    /// 简介规则
    #[serde(default)]
    pub intro: String,
    
    /// 封面规则
    #[serde(default)]
    pub cover_url: String,
    
    /// 详情页 URL 规则
    pub book_url: String,
}

fn default_get() -> String {
    "GET".to_string()
}

/// 书籍信息规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookInfoRule {
    /// 初始化规则（在获取信息前执行）
    #[serde(default)]
    pub init: String,
    
    /// 书名规则
    pub name: String,
    
    /// 作者规则
    pub author: String,
    
    /// 分类规则
    #[serde(default)]
    pub kind: String,
    
    /// 最新章节规则
    #[serde(default)]
    pub last_chapter: String,
    
    /// 简介规则
    #[serde(default)]
    pub intro: String,
    
    /// 封面规则
    #[serde(default)]
    pub cover_url: String,
    
    /// 目录 URL 规则
    pub toc_url: String,
    
    /// 字数规则
    #[serde(default)]
    pub word_count: String,
}

/// 目录规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TocRule {
    /// 章节列表规则
    pub chapter_list: String,
    
    /// 章节名称规则
    pub chapter_name: String,
    
    /// 章节 URL 规则
    pub chapter_url: String,
    
    /// 是否为 VIP 章节
    #[serde(default)]
    pub is_vip: String,
    
    /// 更新时间规则
    #[serde(default)]
    pub update_time: String,
    
    /// 是否为卷
    #[serde(default)]
    pub is_volume: String,
    
    /// 下一页 URL（用于翻页获取目录）
    #[serde(default)]
    pub next_toc_url: String,
}

/// 正文规则
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentRule {
    /// 正文规则
    pub content: String,
    
    /// 下一页 URL（用于翻页获取正文）
    #[serde(default)]
    pub next_content_url: String,
    
    /// 图片 URL 规则
    #[serde(default)]
    pub image_url: String,
    
    /// 图片样式（如何处理图片）
    #[serde(default)]
    pub image_style: String,
    
    /// 替换规则（正则替换）
    #[serde(default)]
    pub replace_regex: String,
}

/// 分析上下文
#[derive(Debug, Clone)]
pub struct AnalyzeContext {
    /// 当前内容（HTML/JSON 字符串）
    pub content: String,
    
    /// 基础 URL（用于相对路径转绝对路径）
    pub base_url: String,
    
    /// 书源配置
    pub source: BookSource,
    
    /// 额外变量（用于 JS 规则）
    pub variables: std::collections::HashMap<String, String>,
}

/// 分析结果
#[derive(Debug, Clone)]
pub enum AnalyzeResult {
    /// 单个字符串结果
    Single(String),
    
    /// 多个字符串结果（列表）
    Multiple(Vec<String>),
    
    /// 键值对结果（对象）
    Object(std::collections::HashMap<String, String>),
}

impl AnalyzeResult {
    /// 转为单个字符串
    pub fn as_string(&self) -> String {
        match self {
            Self::Single(s) => s.clone(),
            Self::Multiple(v) => v.join("\n"),
            Self::Object(m) => serde_json::to_string(m).unwrap_or_default(),
        }
    }
    
    /// 转为字符串列表
    pub fn as_list(&self) -> Vec<String> {
        match self {
            Self::Single(s) => vec![s.clone()],
            Self::Multiple(v) => v.clone(),
            Self::Object(m) => m.values().cloned().collect(),
        }
    }
}

/// 规则类型
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleType {
    /// 默认（自动检测）
    Default,
    
    /// CSS 选择器 (@css:)
    Css,
    
    /// XPath (@xpath:)
    XPath,
    
    /// JSONPath (@json:)
    Json,
    
    /// 正则表达式 (##正则##)
    Regex,
    
    /// JavaScript (@js:)
    JavaScript,
}

/// 解析后的规则
#[derive(Debug, Clone)]
pub struct ParsedRule {
    /// 规则类型
    pub rule_type: RuleType,
    
    /// 规则表达式
    pub expression: String,
    
    /// 正则替换规则（正则模式, 替换文本）
    pub regex_replacement: Option<(String, String)>,
    
    /// 是否获取所有匹配项
    pub get_all: bool,
}

/// 搜索结果（书籍列表项）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchBookItem {
    /// 书名
    pub name: String,
    
    /// 作者
    pub author: String,
    
    /// 分类
    pub kind: String,
    
    /// 最新章节
    pub last_chapter: String,
    
    /// 简介
    pub intro: String,
    
    /// 封面 URL
    pub cover_url: String,
    
    /// 详情页 URL
    pub book_url: String,
    
    /// 来源书源 URL
    pub source_url: String,
}

/// 书籍详情
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookInfo {
    /// 书名
    pub name: String,
    
    /// 作者
    pub author: String,
    
    /// 分类
    pub kind: String,
    
    /// 最新章节
    pub last_chapter: String,
    
    /// 简介
    pub intro: String,
    
    /// 封面 URL
    pub cover_url: String,
    
    /// 目录 URL
    pub toc_url: String,
    
    /// 字数
    pub word_count: String,
}

/// 章节信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    /// 章节名称
    pub name: String,
    
    /// 章节 URL
    pub url: String,
    
    /// 是否为 VIP 章节
    pub is_vip: bool,
    
    /// 更新时间
    pub update_time: String,
    
    /// 是否为卷标题
    pub is_volume: bool,
    
    /// 章节索引
    pub index: usize,
}

/// 章节正文
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterContent {
    /// 正文内容
    pub content: String,
    
    /// 下一页 URL（如果有分页）
    pub next_url: Option<String>,
}
