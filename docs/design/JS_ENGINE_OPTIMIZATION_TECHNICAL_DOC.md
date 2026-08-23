# JS 引擎优化与深度预处理技术文档

> **文档目标**：详细说明 JS 引擎优化方案和基于 JS 引擎的深度预处理优化  
> **适用阶段**：第三阶段 Week 3-4  
> **技术栈**：rquickjs 0.6, Rust async/tokio

---

## 📋 目录

1. [JS 引擎架构设计](#1-js-引擎架构设计)
2. [运行时池化详细设计](#2-运行时池化详细设计)
3. [沙箱隔离与安全](#3-沙箱隔离与安全)
4. [超时保护机制](#4-超时保护机制)
5. [全局对象注入](#5-全局对象注入)
6. [Legado 规则兼容性](#6-legado-规则兼容性)
7. [深度预处理优化](#7-深度预处理优化)
8. [性能测试与基准](#8-性能测试与基准)
9. [故障排查指南](#9-故障排查指南)

---

## 1. JS 引擎架构设计

### 1.1 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    预处理流水线                              │
├─────────────────────────────────────────────────────────────┤
│  Stage 1  │  Stage 2  │  Stage 3  │ ... │  JsExecutor       │
└─────────────────────────────────────────────────────┬───────┘
                                                      │
                                                      ▼
                                            ┌─────────────────┐
                                            │ JsRuntimePool   │
                                            │  - 运行时池化   │
                                            │  - 最大3个实例  │
                                            │  - 自动回收     │
                                            └────────┬────────┘
                                                     │
                                    ┌────────────────┼────────────────┐
                                    ▼                ▼                ▼
                              ┌──────────┐    ┌──────────┐    ┌──────────┐
                              │ Runtime1 │    │ Runtime2 │    │ Runtime3 │
                              │  - 上下文│    │  - 上下文│    │  - 上下文│
                              │  - 全局对│    │  - 全局对│    │  - 全局对│
                              │  - 隔离沙│    │  - 隔离沙│    │  - 隔离沙│
                              └──────────┘    └──────────┘    └──────────┘
```

### 1.2 核心模块

#### JsRuntime - 单个运行时实例

```rust
// rust/crates/reader_core/src/processing/js_runtime.rs

use rquickjs::{Context, Runtime as QuickJsRuntime, CatchResultExt, Value};
use std::time::Duration;

/// JS 运行时封装
pub struct JsRuntime {
    /// QuickJS 运行时
    runtime: QuickJsRuntime,
    
    /// QuickJS 上下文
    context: Context,
    
    /// 运行时 ID（用于日志追踪）
    runtime_id: usize,
    
    /// 创建时间
    created_at: Instant,
    
    /// 使用次数
    usage_count: usize,
}

impl JsRuntime {
    /// 创建新的 JS 运行时
    pub fn new(runtime_id: usize) -> Result<Self> {
        let runtime = QuickJsRuntime::new()?;
        let context = Context::full(&runtime)?;
        
        Ok(Self {
            runtime,
            context,
            runtime_id,
            created_at: Instant::now(),
            usage_count: 0,
        })
    }
    
    /// 执行 JS 代码
    pub fn execute(&mut self, code: &str, globals: &JsGlobals) -> Result<String> {
        self.usage_count += 1;
        
        self.context.with(|ctx| {
            // 1. 注入全局对象
            self.inject_globals(ctx, globals)?;
            
            // 2. 执行代码
            let result: Value = ctx.eval(code)
                .catch(&ctx)
                .map_err(|e| anyhow!("JS execution error: {:?}", e))?;
            
            // 3. 提取结果
            let result_str = if result.is_string() {
                result.get::<String>()?
            } else if result.is_undefined() || result.is_null() {
                String::new()
            } else {
                // 尝试转换为字符串
                result.as_string()
                    .and_then(|s| s.to_string().ok())
                    .unwrap_or_default()
            };
            
            Ok(result_str)
        })
    }
    
    /// 注入全局对象
    fn inject_globals(&self, ctx: rquickjs::Ctx, globals: &JsGlobals) -> Result<()> {
        // 注入 book 对象
        if let Some(book) = &globals.book {
            let book_obj = rquickjs::Object::new(ctx)?;
            book_obj.set("title", book.title.as_str())?;
            book_obj.set("author", book.author.as_str())?;
            book_obj.set("url", book.url.as_str())?;
            ctx.globals().set("book", book_obj)?;
        }
        
        // 注入 chapter 对象
        if let Some(chapter) = &globals.chapter {
            let chapter_obj = rquickjs::Object::new(ctx)?;
            chapter_obj.set("title", chapter.title.as_str())?;
            chapter_obj.set("index", chapter.index)?;
            chapter_obj.set("url", chapter.url.as_str())?;
            ctx.globals().set("chapter", chapter_obj)?;
        }
        
        // 注入 src（源内容）
        ctx.globals().set("src", globals.src.as_str())?;
        
        // 注入 java 兼容层（Legado 兼容）
        self.inject_java_compat(ctx)?;
        
        Ok(())
    }
    
    /// 注入 java 兼容层
    fn inject_java_compat(&self, ctx: rquickjs::Ctx) -> Result<()> {
        // java.ajax() - HTTP 请求
        let ajax_code = r#"
        var java = {
            ajax: function(url) {
                // 占位符实现，实际需要通过 Rust 回调
                console.log("ajax called:", url);
                return "";
            },
            getString: function(key) {
                // 从存储获取字符串
                return "";
            },
            put: function(key, value) {
                // 存储键值对
            },
            get: function(key) {
                // 获取存储的值
                return null;
            }
        };
        "#;
        
        ctx.eval(ajax_code)?;
        
        Ok(())
    }
    
    /// 清理上下文（重置全局状态）
    pub fn reset(&mut self) -> Result<()> {
        // 清除用户定义的全局变量
        self.context.with(|ctx| {
            // 删除可能存在的全局变量
            let globals = ctx.globals();
            let _ = globals.remove("book");
            let _ = globals.remove("chapter");
            let _ = globals.remove("src");
            let _ = globals.remove("result");
            
            Ok(())
        })
    }
    
    /// 获取统计信息
    pub fn stats(&self) -> JsRuntimeStats {
        JsRuntimeStats {
            runtime_id: self.runtime_id,
            usage_count: self.usage_count,
            age: self.created_at.elapsed(),
        }
    }
}

/// 全局对象
#[derive(Debug, Clone, Default)]
pub struct JsGlobals {
    pub src: String,                // 源内容
    pub book: Option<BookContext>,  // 书籍上下文
    pub chapter: Option<ChapterContext>,  // 章节上下文
}

#[derive(Debug, Clone)]
pub struct BookContext {
    pub title: String,
    pub author: String,
    pub url: String,
}

#[derive(Debug, Clone)]
pub struct ChapterContext {
    pub title: String,
    pub index: usize,
    pub url: String,
}

/// 运行时统计
#[derive(Debug, Clone)]
pub struct JsRuntimeStats {
    pub runtime_id: usize,
    pub usage_count: usize,
    pub age: Duration,
}
```

---

## 2. 运行时池化详细设计

### 2.1 池化策略

**为什么需要池化？**
- QuickJS 运行时创建开销大（~10-20ms）
- 频繁创建销毁导致性能下降
- 内存碎片化

**池化收益**：
- 创建开销分摊：首次创建 10ms，后续复用 <0.1ms
- 内存稳定：固定 3 个实例，内存占用可预测
- 性能提升：3-5 倍执行速度提升

### 2.2 详细实现

```rust
// rust/crates/reader_core/src/processing/js_runtime_pool.rs

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::collections::VecDeque;
use tokio::sync::Mutex;
use std::time::{Duration, Instant};

/// JS 运行时池
pub struct JsRuntimePool {
    /// 可用运行时队列
    pool: Arc<Mutex<VecDeque<JsRuntime>>>,
    
    /// 最大运行时数量
    max_size: usize,
    
    /// 已创建的运行时数量
    created: AtomicUsize,
    
    /// 统计信息
    stats: Arc<Mutex<PoolStats>>,
}

#[derive(Debug, Clone, Default)]
pub struct PoolStats {
    pub total_acquisitions: usize,
    pub total_releases: usize,
    pub cache_hits: usize,
    pub cache_misses: usize,
    pub max_wait_time_ms: u64,
}

impl JsRuntimePool {
    /// 创建新的运行时池
    pub fn new(max_size: usize) -> Self {
        Self {
            pool: Arc::new(Mutex::new(VecDeque::new())),
            max_size,
            created: AtomicUsize::new(0),
            stats: Arc::new(Mutex::new(PoolStats::default())),
        }
    }
    
    /// 获取运行时（异步等待）
    pub async fn acquire(&self) -> Result<PooledRuntime> {
        let start = Instant::now();
        
        // 更新统计
        {
            let mut stats = self.stats.lock().await;
            stats.total_acquisitions += 1;
        }
        
        // 1. 尝试从池中获取（优先）
        {
            let mut pool = self.pool.lock().await;
            if let Some(mut runtime) = pool.pop_front() {
                // 缓存命中
                {
                    let mut stats = self.stats.lock().await;
                    stats.cache_hits += 1;
                }
                
                // 重置运行时状态
                runtime.reset()?;
                
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: self.pool.clone(),
                    stats: self.stats.clone(),
                });
            }
        }
        
        // 2. 如果池是空的，尝试创建新的
        let created_count = self.created.load(Ordering::SeqCst);
        if created_count < self.max_size {
            // CAS 操作，确保不会超过最大值
            let prev = self.created.fetch_add(1, Ordering::SeqCst);
            if prev < self.max_size {
                // 成功获取创建槽位
                let runtime = JsRuntime::new(prev)?;
                
                {
                    let mut stats = self.stats.lock().await;
                    stats.cache_misses += 1;
                }
                
                info!("Created new JS runtime #{}", prev);
                
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: self.pool.clone(),
                    stats: self.stats.clone(),
                });
            } else {
                // 回退计数
                self.created.fetch_sub(1, Ordering::SeqCst);
            }
        }
        
        // 3. 池满了，等待可用的运行时（自旋等待）
        warn!("JS runtime pool exhausted, waiting for available runtime...");
        
        loop {
            tokio::time::sleep(Duration::from_millis(10)).await;
            
            let mut pool = self.pool.lock().await;
            if let Some(mut runtime) = pool.pop_front() {
                let wait_time = start.elapsed();
                
                // 更新最大等待时间
                {
                    let mut stats = self.stats.lock().await;
                    stats.max_wait_time_ms = stats.max_wait_time_ms.max(wait_time.as_millis() as u64);
                    stats.cache_hits += 1;
                }
                
                if wait_time > Duration::from_millis(100) {
                    warn!("Waited {}ms for JS runtime", wait_time.as_millis());
                }
                
                runtime.reset()?;
                
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: self.pool.clone(),
                    stats: self.stats.clone(),
                });
            }
            
            // 超时检查（最多等待 5 秒）
            if start.elapsed() > Duration::from_secs(5) {
                return Err(anyhow!("Timeout waiting for JS runtime"));
            }
        }
    }
    
    /// 获取统计信息
    pub async fn get_stats(&self) -> PoolStats {
        self.stats.lock().await.clone()
    }
    
    /// 获取池状态
    pub async fn status(&self) -> PoolStatus {
        let pool = self.pool.lock().await;
        
        PoolStatus {
            available: pool.len(),
            created: self.created.load(Ordering::SeqCst),
            max_size: self.max_size,
        }
    }
}

/// 池化运行时（自动归还）
pub struct PooledRuntime {
    runtime: Option<JsRuntime>,
    pool: Arc<Mutex<VecDeque<JsRuntime>>>,
    stats: Arc<Mutex<PoolStats>>,
}

impl PooledRuntime {
    /// 执行 JS 代码
    pub fn execute(&mut self, code: &str, globals: &JsGlobals) -> Result<String> {
        self.runtime.as_mut()
            .ok_or_else(|| anyhow!("Runtime already released"))?
            .execute(code, globals)
    }
    
    /// 获取运行时统计
    pub fn runtime_stats(&self) -> Option<JsRuntimeStats> {
        self.runtime.as_ref().map(|r| r.stats())
    }
}

impl Drop for PooledRuntime {
    fn drop(&mut self) {
        if let Some(runtime) = self.runtime.take() {
            // 异步归还到池中
            let pool = self.pool.clone();
            let stats = self.stats.clone();
            
            tokio::spawn(async move {
                let mut p = pool.lock().await;
                p.push_back(runtime);
                
                let mut s = stats.lock().await;
                s.total_releases += 1;
            });
        }
    }
}

#[derive(Debug, Clone)]
pub struct PoolStatus {
    pub available: usize,
    pub created: usize,
    pub max_size: usize,
}
```

### 2.3 使用示例

```rust
// 创建全局池
static JS_POOL: Lazy<Arc<JsRuntimePool>> = Lazy::new(|| {
    Arc::new(JsRuntimePool::new(3))  // 最多 3 个运行时
});

// 使用
async fn execute_js_rule(code: &str, globals: JsGlobals) -> Result<String> {
    let mut runtime = JS_POOL.acquire().await?;
    runtime.execute(code, &globals)
}
```

---

## 3. 沙箱隔离与安全

### 3.1 安全威胁

1. **无限循环**：`while(true) {}`
2. **内存耗尽**：`var a = []; while(true) a.push(1);`
3. **文件系统访问**：尝试读写文件
4. **网络访问**：未授权的 HTTP 请求
5. **原型链污染**：修改 Object.prototype

### 3.2 沙箱配置

```rust
impl JsRuntime {
    pub fn new_sandboxed(runtime_id: usize) -> Result<Self> {
        let mut runtime = QuickJsRuntime::new()?;
        
        // 1. 禁用危险模块
        // QuickJS 默认不包含 fs、net 等模块，无需额外配置
        
        // 2. 设置内存限制（可选，QuickJS 支持）
        // runtime.set_memory_limit(10 * 1024 * 1024);  // 10MB
        
        // 3. 设置栈大小限制
        // runtime.set_max_stack_size(512 * 1024);  // 512KB
        
        let context = Context::full(&runtime)?;
        
        Ok(Self {
            runtime,
            context,
            runtime_id,
            created_at: Instant::now(),
            usage_count: 0,
        })
    }
    
    /// 在沙箱中安全执行代码
    pub fn execute_sandboxed(
        &mut self,
        code: &str,
        globals: &JsGlobals,
        timeout: Duration,
    ) -> Result<String> {
        // 1. 注入全局对象
        self.context.with(|ctx| {
            self.inject_globals(ctx, globals)?;
            Ok(())
        })?;
        
        // 2. 带超时执行（见下一节）
        self.execute_with_timeout(code, timeout)
    }
}
```

### 3.3 原型链保护

```rust
impl JsRuntime {
    fn protect_prototypes(&self, ctx: rquickjs::Ctx) -> Result<()> {
        // 冻结 Object.prototype，防止污染
        let code = r#"
        Object.freeze(Object.prototype);
        Object.freeze(Array.prototype);
        Object.freeze(String.prototype);
        "#;
        
        ctx.eval::<(), _>(code)?;
        
        Ok(())
    }
}
```

---

## 4. 超时保护机制

### 4.1 问题分析

QuickJS 本身不支持中断正在执行的代码。需要通过以下方式实现超时：

1. **Interrupt Handler**（推荐）：QuickJS 提供中断回调
2. **Tokio Timeout**：在异步层面超时
3. **Abort**：强制终止线程（不推荐）

### 4.2 详细实现

```rust
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

impl JsRuntime {
    /// 带超时执行
    pub fn execute_with_timeout(
        &mut self,
        code: &str,
        timeout: Duration,
    ) -> Result<String> {
        // 创建中断标志
        let interrupted = Arc::new(AtomicBool::new(false));
        let interrupted_clone = interrupted.clone();
        
        // 启动超时计时器
        let timeout_handle = tokio::spawn(async move {
            tokio::time::sleep(timeout).await;
            interrupted_clone.store(true, Ordering::SeqCst);
        });
        
        // 设置中断处理器
        self.runtime.set_interrupt_handler(Some(Box::new(move || {
            interrupted.load(Ordering::SeqCst)
        })));
        
        // 执行代码
        let result = self.context.with(|ctx| {
            let value: Value = ctx.eval(code)
                .catch(&ctx)
                .map_err(|e| anyhow!("JS execution error: {:?}", e))?;
            
            // 检查是否被中断
            if interrupted.load(Ordering::SeqCst) {
                return Err(anyhow!("JS execution timeout"));
            }
            
            // 提取结果
            let result_str = if value.is_string() {
                value.get::<String>()?
            } else {
                value.as_string()
                    .and_then(|s| s.to_string().ok())
                    .unwrap_or_default()
            };
            
            Ok(result_str)
        });
        
        // 清理超时计时器
        timeout_handle.abort();
        
        // 清除中断处理器
        self.runtime.set_interrupt_handler(None);
        
        result
    }
}
```

### 4.3 超时测试

```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[tokio::test]
    async fn test_infinite_loop_timeout() {
        let mut runtime = JsRuntime::new(0).unwrap();
        let code = r#"
        while(true) {
            // 无限循环
        }
        "#;
        
        let globals = JsGlobals::default();
        let result = runtime.execute_with_timeout(
            code,
            &globals,
            Duration::from_millis(100),
        );
        
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("timeout"));
    }
    
    #[tokio::test]
    async fn test_normal_execution_no_timeout() {
        let mut runtime = JsRuntime::new(0).unwrap();
        let code = r#"
        var sum = 0;
        for (var i = 0; i < 1000; i++) {
            sum += i;
        }
        sum.toString();
        "#;
        
        let globals = JsGlobals::default();
        let result = runtime.execute_with_timeout(
            code,
            &globals,
            Duration::from_secs(1),
        ).unwrap();
        
        assert_eq!(result, "499500");
    }
}
```

---

## 5. 全局对象注入

### 5.1 Legado 全局对象规范

Legado 规则中常用的全局对象：

```javascript
// book - 书籍信息
book.title     // 书名
book.author    // 作者
book.url       // 书籍 URL
book.coverUrl  // 封面 URL

// chapter - 章节信息
chapter.title  // 章节标题
chapter.index  // 章节索引
chapter.url    // 章节 URL

// src - 源内容
src  // 待处理的内容

// java - Java 兼容层
java.ajax(url)              // HTTP 请求
java.getString(key)         // 获取存储
java.put(key, value)        // 存储键值对
java.get(key)               // 获取存储

// result - 返回结果
result  // 规则执行结果
```

### 5.2 高级注入实现

```rust
impl JsRuntime {
    /// 注入完整的全局对象（包含高级功能）
    fn inject_globals_advanced(
        &self,
        ctx: rquickjs::Ctx,
        globals: &JsGlobals,
    ) -> Result<()> {
        // 1. 注入 book
        if let Some(book) = &globals.book {
            let book_obj = rquickjs::Object::new(ctx)?;
            book_obj.set("title", book.title.as_str())?;
            book_obj.set("author", book.author.as_str())?;
            book_obj.set("url", book.url.as_str())?;
            
            // 额外字段
            if let Some(cover) = &book.cover_url {
                book_obj.set("coverUrl", cover.as_str())?;
            }
            
            ctx.globals().set("book", book_obj)?;
        }
        
        // 2. 注入 chapter
        if let Some(chapter) = &globals.chapter {
            let chapter_obj = rquickjs::Object::new(ctx)?;
            chapter_obj.set("title", chapter.title.as_str())?;
            chapter_obj.set("index", chapter.index)?;
            chapter_obj.set("url", chapter.url.as_str())?;
            
            ctx.globals().set("chapter", chapter_obj)?;
        }
        
        // 3. 注入 src
        ctx.globals().set("src", globals.src.as_str())?;
        
        // 4. 注入 java 兼容层（完整实现）
        self.inject_java_full(ctx, globals)?;
        
        // 5. 注入工具函数
        self.inject_utility_functions(ctx)?;
        
        Ok(())
    }
    
    /// 完整的 java 兼容层
    fn inject_java_full(
        &self,
        ctx: rquickjs::Ctx,
        globals: &JsGlobals,
    ) -> Result<()> {
        let code = r#"
        var java = {
            // HTTP 请求（通过 Rust 回调实现）
            ajax: function(url, options) {
                // TODO: 实现 Rust 回调
                console.log("ajax:", url);
                return "";
            },
            
            // 存储 API
            getString: function(key, defaultValue) {
                // TODO: 从 Rust 获取
                return defaultValue || "";
            },
            
            put: function(key, value) {
                // TODO: 存储到 Rust
            },
            
            get: function(key) {
                // TODO: 从 Rust 获取
                return null;
            },
            
            // 编码工具
            base64Encode: function(str) {
                return btoa(unescape(encodeURIComponent(str)));
            },
            
            base64Decode: function(str) {
                return decodeURIComponent(escape(atob(str)));
            }
        };
        "#;
        
        ctx.eval::<(), _>(code)?;
        
        Ok(())
    }
    
    /// 注入工具函数
    fn inject_utility_functions(&self, ctx: rquickjs::Ctx) -> Result<()> {
        let code = r#"
        // 字符串工具
        String.prototype.replaceAll = function(search, replacement) {
            return this.split(search).join(replacement);
        };
        
        // 数组工具
        if (!Array.prototype.includes) {
            Array.prototype.includes = function(searchElement) {
                return this.indexOf(searchElement) !== -1;
            };
        }
        "#;
        
        ctx.eval::<(), _>(code)?;
        
        Ok(())
    }
}
```

---

## 6. Legado 规则兼容性

### 6.1 常见规则模式

#### 模式 1: 简单替换
```javascript
js:
src.replace(/<p>/g, "　　")
   .replace(/<\/p>/g, "\n");
```

#### 模式 2: 复杂处理
```javascript
js:
var lines = src.split("\n");
var result = [];
for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line.length > 0) {
        result.push("　　" + line);
    }
}
result.join("\n\n");
```

#### 模式 3: 使用全局对象
```javascript
js:
var title = chapter.title;
src.replace(title, "").trim();
```

#### 模式 4: 正则提取
```javascript
js:
var matches = src.match(/第[0-9]+章/g);
if (matches) {
    matches[0];
} else {
    "";
}
```

### 6.2 兼容性测试套件

```rust
#[cfg(test)]
mod legado_compat_tests {
    use super::*;
    
    #[tokio::test]
    async fn test_simple_replace() {
        let pool = JsRuntimePool::new(1);
        let mut runtime = pool.acquire().await.unwrap();
        
        let code = r#"
        js:
        src.replace(/<p>/g, "　　")
           .replace(/<\/p>/g, "\n");
        "#;
        
        let globals = JsGlobals {
            src: "<p>第一段</p><p>第二段</p>".to_string(),
            ..Default::default()
        };
        
        let result = runtime.execute(code, &globals).unwrap();
        assert_eq!(result, "　　第一段\n　　第二段\n");
    }
    
    #[tokio::test]
    async fn test_chapter_title_removal() {
        let pool = JsRuntimePool::new(1);
        let mut runtime = pool.acquire().await.unwrap();
        
        let code = r#"
        js:
        var title = chapter.title;
        src.replace(title, "").trim();
        "#;
        
        let globals = JsGlobals {
            src: "第一章 开始\n\n正文内容...".to_string(),
            chapter: Some(ChapterContext {
                title: "第一章 开始".to_string(),
                index: 0,
                url: String::new(),
            }),
            ..Default::default()
        };
        
        let result = runtime.execute(code, &globals).unwrap();
        assert_eq!(result, "正文内容...");
    }
    
    #[tokio::test]
    async fn test_regex_extraction() {
        let pool = JsRuntimePool::new(1);
        let mut runtime = pool.acquire().await.unwrap();
        
        let code = r#"
        js:
        var matches = src.match(/第[0-9]+章/);
        if (matches) {
            matches[0];
        } else {
            "";
        }
        "#;
        
        let globals = JsGlobals {
            src: "这是第123章的内容".to_string(),
            ..Default::default()
        };
        
        let result = runtime.execute(code, &globals).unwrap();
        assert_eq!(result, "第123章");
    }
}
```

---

## 7. 深度预处理优化

### 7.1 预处理流水线集成

```rust
// rust/crates/reader_core/src/processing/stages/js_executor.rs

use super::*;

/// JS 执行器阶段
pub struct JsExecutor {
    pool: Arc<JsRuntimePool>,
    timeout_ms: u64,
    enabled: bool,
}

impl JsExecutor {
    pub fn new(pool: Arc<JsRuntimePool>) -> Self {
        Self {
            pool,
            timeout_ms: 5000,  // 默认 5 秒超时
            enabled: true,
        }
    }
    
    pub fn with_timeout(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = timeout_ms;
        self
    }
    
    /// 执行 JS 规则列表
    async fn execute_rules(
        &self,
        content: String,
        rules: &[JsRule],
        context: &ProcessingContext,
    ) -> Result<String> {
        let mut result = content;
        
        for rule in rules {
            if !rule.enabled {
                continue;
            }
            
            // 获取运行时
            let mut runtime = self.pool.acquire().await?;
            
            // 准备全局对象
            let globals = JsGlobals {
                src: result.clone(),
                book: context.book.clone(),
                chapter: context.chapter.clone(),
            };
            
            // 执行规则
            match tokio::time::timeout(
                Duration::from_millis(self.timeout_ms),
                async {
                    runtime.execute(&rule.code, &globals)
                }
            ).await {
                Ok(Ok(output)) => {
                    result = output;
                    debug!("JS rule '{}' executed successfully", rule.name);
                }
                Ok(Err(e)) => {
                    warn!("JS rule '{}' failed: {}", rule.name, e);
                    if !rule.skip_on_error {
                        return Err(e);
                    }
                }
                Err(_) => {
                    warn!("JS rule '{}' timeout", rule.name);
                    if !rule.skip_on_error {
                        return Err(anyhow!("JS rule timeout"));
                    }
                }
            }
        }
        
        Ok(result)
    }
}

#[async_trait]
impl ProcessingStage for JsExecutor {
    async fn process(&mut self, input: StageInput) -> Result<StageOutput> {
        let (content, context) = match input {
            StageInput::Content(c, ctx) => (c, ctx),
            _ => return Err(anyhow!("Invalid input type for JsExecutor")),
        };
        
        if !self.enabled {
            return Ok(StageOutput::Content(content, context));
        }
        
        // 获取 JS 规则
        let rules = context.js_rules.as_ref()
            .ok_or_else(|| anyhow!("No JS rules configured"))?;
        
        if rules.is_empty() {
            return Ok(StageOutput::Content(content, context));
        }
        
        // 执行规则
        let processed = self.execute_rules(content, rules, &context).await?;
        
        Ok(StageOutput::Content(processed, context))
    }
    
    fn stage_name(&self) -> &'static str {
        "JsExecutor"
    }
    
    fn is_skippable(&self) -> bool {
        !self.enabled
    }
}

#[derive(Debug, Clone)]
pub struct JsRule {
    pub name: String,
    pub code: String,
    pub enabled: bool,
    pub skip_on_error: bool,  // 失败时是否跳过
}
```

### 7.2 预处理优化组合

**优化策略**：
1. JS 规则 → 标题去重 → 内容净化 → 分段优化
2. 缓存预处理结果（避免重复执行）
3. 错误恢复（某个规则失败不影响其他）

```rust
impl ProcessingPipeline {
    pub fn build_optimized_pipeline(
        js_pool: Arc<JsRuntimePool>,
    ) -> Self {
        let stages: Vec<Box<dyn ProcessingStage>> = vec![
            // Stage 1: 标题去重（快速，必须）
            Box::new(DuplicateTitleRemover::new()),
            
            // Stage 2: HTML 保护（JS 前置）
            Box::new(HtmlProtector::new()),
            
            // Stage 3: JS 规则执行（核心）
            Box::new(JsExecutor::new(js_pool)
                .with_timeout(5000)),
            
            // Stage 4: HTML 恢复
            Box::new(HtmlRestorer::new()),
            
            // Stage 5: 内容净化
            Box::new(ContentCleaner::new()),
            
            // Stage 6: 重新分段
            Box::new(ResegmentProcessor::new()),
            
            // Stage 7: 简繁转换
            Box::new(ChineseConvertStage::new()),
        ];
        
        ProcessingPipeline {
            stages,
            config: PipelineConfig::default(),
        }
    }
}
```

---

## 8. 性能测试与基准

### 8.1 基准测试

```rust
// benches/js_engine_bench.rs

use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};

fn bench_runtime_creation(c: &mut Criterion) {
    c.bench_function("create_js_runtime", |b| {
        b.iter(|| {
            let runtime = JsRuntime::new(0).unwrap();
            black_box(runtime);
        });
    });
}

fn bench_runtime_pool_acquire(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let pool = Arc::new(JsRuntimePool::new(3));
    
    c.bench_function("pool_acquire_warm", |b| {
        b.to_async(&rt).iter(|| async {
            let runtime = pool.acquire().await.unwrap();
            black_box(runtime);
        });
    });
}

fn bench_simple_js_execution(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let pool = Arc::new(JsRuntimePool::new(3));
    
    let code = r#"src.replace(/<p>/g, "　　")"#;
    let globals = JsGlobals {
        src: "<p>test</p>".repeat(100),
        ..Default::default()
    };
    
    c.bench_function("simple_replace", |b| {
        b.to_async(&rt).iter(|| async {
            let mut runtime = pool.acquire().await.unwrap();
            black_box(runtime.execute(code, &globals).unwrap());
        });
    });
}

fn bench_complex_js_execution(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let pool = Arc::new(JsRuntimePool::new(3));
    
    let code = r#"
    var lines = src.split("\n");
    var result = [];
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.length > 0) {
            result.push("　　" + line);
        }
    }
    result.join("\n\n");
    "#;
    
    let globals = JsGlobals {
        src: "line1\nline2\nline3\n".repeat(1000),
        ..Default::default()
    };
    
    c.bench_function("complex_processing", |b| {
        b.to_async(&rt).iter(|| async {
            let mut runtime = pool.acquire().await.unwrap();
            black_box(runtime.execute(code, &globals).unwrap());
        });
    });
}

criterion_group!(
    benches,
    bench_runtime_creation,
    bench_runtime_pool_acquire,
    bench_simple_js_execution,
    bench_complex_js_execution
);
criterion_main!(benches);
```

### 8.2 性能目标

| 场景 | 目标 | 实际（预期） |
|------|------|-------------|
| 运行时创建 | <20ms | ~15ms |
| 池获取（缓存命中） | <0.5ms | ~0.1ms |
| 池获取（缓存未命中） | <20ms | ~15ms |
| 简单 JS 执行（100字符） | <5ms | ~2-3ms |
| 复杂 JS 执行（10k字符） | <50ms | ~30-40ms |
| 超时保护开销 | <1ms | ~0.5ms |

---

## 9. 故障排查指南

### 9.1 常见问题

#### 问题 1: JS 执行超时
**症状**：规则执行失败，错误信息包含"timeout"

**原因**：
- 无限循环
- 处理数据量过大
- 复杂正则匹配

**解决方案**：
1. 检查规则是否有无限循环
2. 增加超时时间（针对大文件）
3. 优化规则算法复杂度

#### 问题 2: 内存占用过高
**症状**：应用内存占用持续增长

**原因**：
- 运行时池未正确释放
- 全局对象未清理
- 缓存未限制大小

**解决方案**：
```rust
// 定期检查池状态
let status = JS_POOL.status().await;
if status.available == 0 && status.created == status.max_size {
    warn!("JS runtime pool exhausted!");
}

// 监控内存
let stats = JS_POOL.get_stats().await;
info!("Pool stats: {:?}", stats);
```

#### 问题 3: 规则执行结果不符合预期
**症状**：输出内容不正确

**排查步骤**：
1. 启用调试日志
2. 检查全局对象是否正确注入
3. 在 JS 代码中添加 console.log
4. 使用单元测试隔离问题

### 9.2 调试技巧

```rust
// 启用详细日志
impl JsRuntime {
    pub fn execute_debug(&mut self, code: &str, globals: &JsGlobals) -> Result<String> {
        debug!("Executing JS code:\n{}", code);
        debug!("Globals: src.len={}, book={:?}, chapter={:?}",
            globals.src.len(),
            globals.book.as_ref().map(|b| &b.title),
            globals.chapter.as_ref().map(|c| &c.title)
        );
        
        let start = Instant::now();
        let result = self.execute(code, globals)?;
        let elapsed = start.elapsed();
        
        debug!("JS execution completed in {:?}", elapsed);
        debug!("Result length: {}", result.len());
        
        Ok(result)
    }
}
```

---

## 10. 总结与最佳实践

### 10.1 最佳实践

1. **始终使用运行时池**：避免频繁创建销毁
2. **设置合理超时**：默认 5 秒，大文件可适当增加
3. **启用错误恢复**：单个规则失败不影响其他
4. **监控池状态**：定期检查可用性和统计信息
5. **缓存预处理结果**：避免重复执行相同规则
6. **渐进式优化**：先保证正确性，再优化性能

### 10.2 性能优化清单

- [ ] 运行时池化（3-5倍提升）
- [ ] 全局对象缓存（减少重复创建）
- [ ] 预处理结果缓存（避免重复执行）
- [ ] 并行执行独立规则（适用于多规则场景）
- [ ] 超时时间自适应（根据内容大小动态调整）
- [ ] 运行时预热（应用启动时创建池）

---

**文档版本**：v1.0  
**创建日期**：2025-01-XX  
**维护者**：Kiro AI Agent  
**更新频率**：随第三阶段实施更新
