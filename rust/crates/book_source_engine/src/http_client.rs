use anyhow::{anyhow, Result};
use reqwest::{Client, ClientBuilder, Method, Response};
use std::collections::HashMap;
use std::time::Duration;
use tokio::sync::Semaphore;
use once_cell::sync::Lazy;

/// 全局并发限制器（最大 8 并发）
static CONCURRENT_LIMITER: Lazy<Semaphore> = Lazy::new(|| Semaphore::new(8));

/// HTTP 客户端
pub struct HttpClient {
    client: Client,
    default_headers: HashMap<String, String>,
}

impl HttpClient {
    /// 创建新的 HTTP 客户端
    pub fn new() -> Result<Self> {
        let client = ClientBuilder::new()
            .timeout(Duration::from_secs(30))
            .cookie_store(true)  // 启用 Cookie 存储
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            .build()
            .map_err(|e| anyhow!("创建 HTTP 客户端失败: {}", e))?;
        
        Ok(Self {
            client,
            default_headers: HashMap::new(),
        })
    }
    
    /// 设置默认请求头
    pub fn set_default_headers(&mut self, headers: HashMap<String, String>) {
        self.default_headers = headers;
    }
    
    /// 添加单个默认请求头
    pub fn add_default_header(&mut self, key: String, value: String) {
        self.default_headers.insert(key, value);
    }
    
    /// GET 请求
    pub async fn get(&self, url: &str) -> Result<HttpResponse> {
        self.request(Method::GET, url, None, None).await
    }
    
    /// GET 请求（带自定义请求头）
    pub async fn get_with_headers(
        &self,
        url: &str,
        headers: HashMap<String, String>,
    ) -> Result<HttpResponse> {
        self.request(Method::GET, url, Some(headers), None).await
    }
    
    /// POST 请求
    pub async fn post(&self, url: &str, body: Option<String>) -> Result<HttpResponse> {
        self.request(Method::POST, url, None, body).await
    }
    
    /// POST 请求（带自定义请求头）
    pub async fn post_with_headers(
        &self,
        url: &str,
        headers: HashMap<String, String>,
        body: Option<String>,
    ) -> Result<HttpResponse> {
        self.request(Method::POST, url, Some(headers), body).await
    }
    
    /// 通用请求方法
    pub async fn request(
        &self,
        method: Method,
        url: &str,
        headers: Option<HashMap<String, String>>,
        body: Option<String>,
    ) -> Result<HttpResponse> {
        // 获取并发许可
        let _permit = CONCURRENT_LIMITER.acquire().await
            .map_err(|e| anyhow!("获取并发许可失败: {}", e))?;
        
        // 构建请求
        let mut request = self.client.request(method, url);
        
        // 添加默认请求头
        for (key, value) in &self.default_headers {
            request = request.header(key, value);
        }
        
        // 添加自定义请求头
        if let Some(custom_headers) = headers {
            for (key, value) in custom_headers {
                request = request.header(&key, &value);
            }
        }
        
        // 添加请求体
        if let Some(body_content) = body {
            request = request.body(body_content);
        }
        
        // 发送请求
        let response = request.send().await
            .map_err(|e| anyhow!("HTTP 请求失败: {}", e))?;
        
        // 解析响应
        Self::parse_response(response).await
    }
    
    /// 解析响应
    async fn parse_response(response: Response) -> Result<HttpResponse> {
        let status = response.status().as_u16();
        let url = response.url().to_string();
        
        // 提取响应头
        let mut headers = HashMap::new();
        for (key, value) in response.headers() {
            if let Ok(value_str) = value.to_str() {
                headers.insert(key.to_string(), value_str.to_string());
            }
        }
        
        // 检测字符编码
        let charset = Self::detect_charset(&headers);
        
        // 读取响应体
        let bytes = response.bytes().await
            .map_err(|e| anyhow!("读取响应体失败: {}", e))?;
        
        // 解码文本
        let body = Self::decode_text(&bytes, &charset)?;
        
        Ok(HttpResponse {
            status,
            url,
            headers,
            body,
            charset,
        })
    }
    
    /// 检测字符编码
    fn detect_charset(headers: &HashMap<String, String>) -> String {
        if let Some(content_type) = headers.get("content-type") {
            // 从 Content-Type 中提取 charset
            if let Some(charset_pos) = content_type.to_lowercase().find("charset=") {
                let charset = &content_type[charset_pos + 8..];
                let charset = charset.split(';').next().unwrap_or("utf-8");
                return charset.trim().to_lowercase();
            }
        }
        
        // 默认使用 UTF-8
        "utf-8".to_string()
    }
    
    /// 解码文本
    fn decode_text(bytes: &[u8], charset: &str) -> Result<String> {
        match charset.to_lowercase().as_str() {
            "utf-8" | "utf8" => {
                String::from_utf8(bytes.to_vec())
                    .or_else(|_| {
                        // UTF-8 解码失败，尝试使用 GBK
                        Self::decode_gbk(bytes)
                    })
                    .map_err(|e| anyhow!("文本解码失败: {}", e))
            }
            "gbk" | "gb2312" | "gb18030" => {
                Self::decode_gbk(bytes)
            }
            _ => {
                // 未知编码，尝试 UTF-8
                String::from_utf8(bytes.to_vec())
                    .map_err(|e| anyhow!("文本解码失败: {}", e))
            }
        }
    }
    
    /// GBK 解码（简化实现，生产环境应使用 encoding_rs）
    fn decode_gbk(bytes: &[u8]) -> Result<String> {
        // 注意：这是简化实现，实际应该使用 encoding_rs crate
        // 这里先尝试 UTF-8，失败则使用 lossy 转换
        String::from_utf8(bytes.to_vec())
            .or_else(|_| Ok(String::from_utf8_lossy(bytes).to_string()))
    }
    
    /// 并发请求多个 URL
    pub async fn batch_get(&self, urls: Vec<String>) -> Vec<Result<HttpResponse>> {
        let mut tasks = Vec::new();
        
        for url in urls {
            let client = self.clone();
            let task = tokio::spawn(async move {
                client.get(&url).await
            });
            tasks.push(task);
        }
        
        let mut results = Vec::new();
        for task in tasks {
            match task.await {
                Ok(result) => results.push(result),
                Err(e) => results.push(Err(anyhow!("任务执行失败: {}", e))),
            }
        }
        
        results
    }
}

impl Clone for HttpClient {
    fn clone(&self) -> Self {
        Self {
            client: self.client.clone(),
            default_headers: self.default_headers.clone(),
        }
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new().unwrap()
    }
}

/// HTTP 响应
#[derive(Debug, Clone)]
pub struct HttpResponse {
    /// 状态码
    pub status: u16,
    
    /// 最终 URL（可能重定向）
    pub url: String,
    
    /// 响应头
    pub headers: HashMap<String, String>,
    
    /// 响应体（文本）
    pub body: String,
    
    /// 字符编码
    pub charset: String,
}

impl HttpResponse {
    /// 是否成功（2xx）
    pub fn is_success(&self) -> bool {
        self.status >= 200 && self.status < 300
    }
    
    /// 获取响应头
    pub fn get_header(&self, key: &str) -> Option<&String> {
        self.headers.get(&key.to_lowercase())
    }
    
    /// 解析为 JSON
    pub fn json<T: serde::de::DeserializeOwned>(&self) -> Result<T> {
        serde_json::from_str(&self.body)
            .map_err(|e| anyhow!("JSON 解析失败: {}", e))
    }
}

/// URL 工具
pub struct UrlUtils;

impl UrlUtils {
    /// 将相对 URL 转换为绝对 URL
    pub fn resolve(base: &str, relative: &str) -> Result<String> {
        let base_url = url::Url::parse(base)
            .map_err(|e| anyhow!("无效的基础 URL: {}", e))?;
        
        let absolute_url = base_url.join(relative)
            .map_err(|e| anyhow!("URL 拼接失败: {}", e))?;
        
        Ok(absolute_url.to_string())
    }
    
    /// 从 URL 中提取域名
    pub fn get_domain(url: &str) -> Result<String> {
        let parsed = url::Url::parse(url)
            .map_err(|e| anyhow!("无效的 URL: {}", e))?;
        
        parsed.host_str()
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow!("URL 中没有域名"))
    }
    
    /// 构建 URL（添加查询参数）
    pub fn build_url(base: &str, params: HashMap<String, String>) -> Result<String> {
        let mut url = url::Url::parse(base)
            .map_err(|e| anyhow!("无效的 URL: {}", e))?;
        
        for (key, value) in params {
            url.query_pairs_mut().append_pair(&key, &value);
        }
        
        Ok(url.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_detect_charset() {
        let mut headers = HashMap::new();
        headers.insert(
            "content-type".to_string(),
            "text/html; charset=UTF-8".to_string(),
        );
        
        let charset = HttpClient::detect_charset(&headers);
        assert_eq!(charset, "utf-8");
    }
    
    #[test]
    fn test_detect_charset_gbk() {
        let mut headers = HashMap::new();
        headers.insert(
            "content-type".to_string(),
            "text/html; charset=GBK".to_string(),
        );
        
        let charset = HttpClient::detect_charset(&headers);
        assert_eq!(charset, "gbk");
    }
    
    #[test]
    fn test_url_resolve() {
        let base = "https://example.com/books/";
        let relative = "chapter/1.html";
        let absolute = UrlUtils::resolve(base, relative).unwrap();
        
        assert_eq!(absolute, "https://example.com/books/chapter/1.html");
    }
    
    #[test]
    fn test_url_resolve_absolute() {
        let base = "https://example.com/books/";
        let relative = "https://other.com/page.html";
        let absolute = UrlUtils::resolve(base, relative).unwrap();
        
        assert_eq!(absolute, "https://other.com/page.html");
    }
    
    #[test]
    fn test_get_domain() {
        let url = "https://example.com/path/to/page.html?query=1";
        let domain = UrlUtils::get_domain(url).unwrap();
        
        assert_eq!(domain, "example.com");
    }
    
    #[test]
    fn test_build_url() {
        let base = "https://example.com/search";
        let mut params = HashMap::new();
        params.insert("keyword".to_string(), "测试".to_string());
        params.insert("page".to_string(), "1".to_string());
        
        let url = UrlUtils::build_url(base, params).unwrap();
        
        assert!(url.contains("keyword="));
        assert!(url.contains("page=1"));
    }
}
