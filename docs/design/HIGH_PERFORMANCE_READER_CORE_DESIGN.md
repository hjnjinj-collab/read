# 高性能核心阅读加载方案设计

> **设计目标**：构建高度抽象、统一接口、高性能、完全兼容 Legado 的核心阅读系统
> 
> **设计日期**：2025-01-XX  
> **适用版本**：legado_flutter v1.0+  
> **参考来源**：legado-with-MD3 MIGRATION_ANALYSIS.md

---

## 📋 目录

1. [设计理念](#设计理念)
2. [整体架构](#整体架构)
3. [核心抽象层](#核心抽象层)
4. [智能任务调度系统](#智能任务调度系统)
5. [多格式文件支持](#多格式文件支持)
6. [内容处理流水线](#内容处理流水线)
7. [高性能排版引擎](#高性能排版引擎)
8. [缓存与预加载策略](#缓存与预加载策略)
9. [性能指标与优化](#性能指标与优化)
10. [实施路线图](#实施路线图)

---

## 🎯 设计理念

### 核心问题诊断

**当前痛点**：
1. ❌ **线路混乱**：加载→解析→处理→排版→分页，各环节耦合严重
2. ❌ **缺乏统一抽象**：不同格式文件各自为政，难以扩展
3. ❌ **调度混乱**：没有统一的任务调度和优先级管理
4. ❌ **性能瓶颈**：每次翻页重新排版，缺少缓存和预加载

### 设计原则

#### 1. **高度抽象化** - Trait-Based Design
```rust
// 所有文件格式统一接口
trait BookSource { }

// 所有处理步骤统一接口
trait ProcessingStage { }

// 所有调度策略统一接口
trait SchedulingPolicy { }
```

#### 2. **流水线架构** - Pipeline Pattern
```
原始文件 → [解析] → [预处理] → [排版] → [分页] → [渲染]
         ↑                                         ↓
         └──────────── 智能调度器 ─────────────────┘
```

#### 3. **性能优先** - Zero-Copy & Async
- 零拷贝：mmap、引用传递
- 异步并发：tokio、channel
- 多级缓存：LRU、持久化

#### 4. **完全兼容** - Legado Rule Engine
- 支持完整的规则语法（CSS/JSONPath/Regex/JS）
- 集成 JS 引擎（rquickjs）
- 超时保护、自动降级

---

## 🏗️ 整体架构

### 系统分层图

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Flutter UI 层                                │
│  • ReaderScreen                                                      │
│  • PageView + CustomPaint 渲染                                       │
└─────────────────────────────────────────────────────────────────────┘
                                  ↕ FFI
┌─────────────────────────────────────────────────────────────────────┐
│                      Rust Core 核心层                                │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │              统一阅读会话管理器 (ReadSession)                 │   │
│  │  • 当前阅读状态（书籍、章节、页码）                           │   │
│  │  • 三章缓存管理（prev/current/next）                          │   │
│  │  • 生命周期控制（打开、翻页、跳转、关闭）                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                  ↓                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │            智能任务调度器 (TaskScheduler)                     │   │
│  │  • 章节任务队列（每章独立队列）                               │   │
│  │  • 优先级管理（当前章 > 下一章 > 前一章）                     │   │
│  │  • 任务取消（快速翻页时取消过期任务）                         │   │
│  │  • 并发控制（三章并行、信号量限流）                           │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                  ↓                                   │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │            内容处理流水线 (ProcessingPipeline)                │   │
│  │                                                                │   │
│  │  [Stage 1: 加载]    BookSourceLoader                          │   │
│  │     ↓ 通过 Trait 统一接口加载不同格式文件                      │   │
│  │                                                                │   │
│  │  [Stage 2: 解析]    BookParser (TXT/EPUB/MOBI/PDF)           │   │
│  │     ↓ 提取章节信息、生成目录                                   │   │
│  │                                                                │   │
│  │  [Stage 3: 预处理]  ContentPreprocessor                       │   │
│  │     ↓ 净化、简繁转换、替换规则、HTML 保护                      │   │
│  │                                                                │   │
│  │  [Stage 4: 排版]    LayoutEngine                              │   │
│  │     ↓ 字体渲染、逐字测量、自动换行                             │   │
│  │                                                                │   │
│  │  [Stage 5: 分页]    Paginator                                 │   │
│  │     ↓ 按屏幕高度切分、段落完整性保护                           │   │
│  │                                                                │   │
│  │  [Stage 6: 缓存]    CacheManager                              │   │
│  │     ↓ 内存 LRU + 磁盘持久化                                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │               规则引擎 (RuleEngine)                           │   │
│  │  • CSS Selector (scraper)                                     │   │
│  │  • JSONPath (jsonpath_lib)                                    │   │
│  │  • Regex (regex + 超时保护)                                   │   │
│  │  • JavaScript (rquickjs + 沙箱隔离)                           │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 数据流转图

```
用户操作：打开书籍
    ↓
┌─────────────────────────────────────────────────────────────┐
│ ReadSession::open_book(book_path, config)                    │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ BookSourceLoader::load(book_path)                            │
│   → 检测文件格式（扩展名 + Magic Number）                    │
│   → 创建对应的 Parser: Box<dyn BookParser>                   │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ Parser::parse_metadata() + get_chapter_list()                │
│   → Book { title, author, chapters: Vec<ChapterInfo> }      │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ TaskScheduler::submit_chapter_task(chapter_0, Priority::High)│
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ ProcessingPipeline::process_chapter(chapter_0)               │
│   ├─ Stage 1: Parser::get_chapter_content() → String        │
│   ├─ Stage 2: Preprocessor::process() → String (净化后)     │
│   ├─ Stage 3: LayoutEngine::layout_text() → Vec<Line>       │
│   └─ Stage 4: Paginator::paginate() → Vec<Page>             │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ CacheManager::put(chapter_0, pages)                          │
│ ReadSession::chapter_cache.current = Some(pages)             │
└─────────────────────────────────────────────────────────────┘
    ↓
┌─────────────────────────────────────────────────────────────┐
│ Flutter: 接收 PageInfo，CustomPaint 渲染                     │
└─────────────────────────────────────────────────────────────┘
    ↓
用户操作：翻页
    ↓
┌─────────────────────────────────────────────────────────────┐
│ ReadSession::next_page()                                      │
│   → 检查缓存命中                                              │
│   → 如需切换章节，触发 TaskScheduler 异步预加载              │
└─────────────────────────────────────────────────────────────┘
```

---

## 🧩 核心抽象层

### 1. BookParser Trait - 统一解析接口

```rust
// rust/crates/book_parser/src/traits.rs

/// 书籍解析器统一接口
pub trait BookParser: Send + Sync {
    /// 解析书籍元信息
    fn parse_metadata(&mut self) -> Result<BookMetadata>;
    
    /// 获取章节列表（延迟加载，只返回章节信息）
    fn get_chapter_list(&mut self) -> Result<Vec<ChapterInfo>>;
    
    /// 获取章节内容（按需加载）
    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String>;
    
    /// 获取资源（EPUB 图片、MOBI 内嵌资源）
    fn get_resource(&mut self, resource_id: &str) -> Result<Vec<u8>>;
    
    /// 预估章节字数（用于进度估算）
    fn estimate_chapter_length(&self, chapter_index: usize) -> usize;
    
    /// 清理资源
    fn cleanup(&mut self);
    
    /// 克隆解析器（用于并发）
    fn clone_parser(&self) -> Box<dyn BookParser>;
}

/// 书籍元信息
#[derive(Debug, Clone)]
pub struct BookMetadata {
    pub title: String,
    pub author: String,
    pub cover_data: Option<Vec<u8>>,
    pub language: String,
    pub publisher: Option<String>,
    pub total_chapters: usize,
    pub file_size: u64,
    pub format: BookFormat,
}

/// 章节信息
#[derive(Debug, Clone)]
pub struct ChapterInfo {
    pub index: usize,
    pub title: String,
    pub estimated_words: usize,
    
    // 格式特定字段（使用 Option）
    pub start_offset: Option<usize>,  // TXT: 字节偏移
    pub end_offset: Option<usize>,
    pub resource_href: Option<String>, // EPUB: spine href
    pub fragment_id: Option<String>,   // EPUB: 锚点
}

/// 书籍格式枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BookFormat {
    Txt,
    Epub,
    Mobi,
    Pdf,
    Umd,
    Unknown,
}
```

### 2. ProcessingStage Trait - 统一处理步骤

```rust
// rust/crates/reader_core/src/processing/mod.rs

/// 内容处理阶段统一接口
#[async_trait]
pub trait ProcessingStage: Send + Sync {
    /// 处理内容
    async fn process(&mut self, input: StageInput) -> Result<StageOutput>;
    
    /// 阶段名称（用于日志）
    fn stage_name(&self) -> &'static str;
    
    /// 预估耗时（毫秒）
    fn estimated_duration_ms(&self) -> u64;
    
    /// 是否可跳过（性能优化）
    fn is_skippable(&self) -> bool {
        false
    }
}

/// 处理阶段输入
pub enum StageInput {
    RawContent(String),
    ProcessedContent(String),
    LayoutResult(LayoutResult),
}

/// 处理阶段输出
pub enum StageOutput {
    Content(String),
    Layout(LayoutResult),
    Pages(Vec<Page>),
}
```

### 3. CacheStrategy Trait - 统一缓存策略

```rust
// rust/crates/reader_core/src/cache/mod.rs

/// 缓存策略统一接口
pub trait CacheStrategy<K, V>: Send + Sync {
    /// 获取缓存
    fn get(&mut self, key: &K) -> Option<&V>;
    
    /// 存入缓存
    fn put(&mut self, key: K, value: V);
    
    /// 检查是否存在
    fn contains(&self, key: &K) -> bool;
    
    /// 清空缓存
    fn clear(&mut self);
    
    /// 获取统计信息
    fn stats(&self) -> CacheStats;
}

/// 缓存统计
#[derive(Debug, Clone)]
pub struct CacheStats {
    pub hit_count: u64,
    pub miss_count: u64,
    pub hit_rate: f32,
    pub size: usize,
    pub capacity: usize,
}
```

---

## ⚙️ 智能任务调度系统

### 设计目标

1. **每章独立队列**：避免不同章节任务相互阻塞
2. **最新任务优先**：快速翻页时取消过期任务
3. **优先级管理**：当前章 > 下一章 > 前一章
4. **并发控制**：三章并行，其他章节排队
5. **资源限流**：CPU/内存使用受控

### 核心实现

```rust
// rust/crates/reader_core/src/scheduler/mod.rs

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};
use tokio::task::JoinHandle;

/// 章节任务调度器（参考 Legado LatestChapterTaskScheduler）
pub struct ChapterTaskScheduler {
    /// 每章一个任务队列
    entries: Arc<Mutex<HashMap<usize, TaskEntry>>>,
    
    /// 全局并发限制（最多 3 个章节并行）
    semaphore: Arc<Semaphore>,
    
    /// 任务优先级配置
    priority_config: PriorityConfig,
}

/// 任务队列条目
struct TaskEntry {
    /// 正在运行的任务
    running: Option<RunningTask>,
    
    /// 等待执行的任务（新任务到来时替换）
    pending: Option<PendingTask>,
    
    /// 优先级
    priority: TaskPriority,
}

struct RunningTask {
    handle: JoinHandle<Result<ChapterPages>>,
    started_at: Instant,
    cancellation_token: CancellationToken,
}

struct PendingTask {
    task_fn: BoxFuture<'static, Result<ChapterPages>>,
    submitted_at: Instant,
}

/// 任务优先级
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum TaskPriority {
    Critical = 3,  // 当前章节
    High = 2,      // 下一章
    Normal = 1,    // 前一章
    Low = 0,       // 其他章节
}

#[derive(Debug, Clone)]
pub struct PriorityConfig {
    pub current_chapter_priority: TaskPriority,
    pub next_chapter_priority: TaskPriority,
    pub prev_chapter_priority: TaskPriority,
}

impl ChapterTaskScheduler {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            priority_config: PriorityConfig::default(),
        }
    }
    
    /// 提交章节任务
    pub async fn submit<F>(
        &self,
        chapter_index: usize,
        priority: TaskPriority,
        task_fn: F,
    ) -> JoinHandle<Result<ChapterPages>>
    where
        F: Future<Output = Result<ChapterPages>> + Send + 'static,
    {
        let mut entries = self.entries.lock().await;
        let entry = entries.entry(chapter_index).or_insert_with(|| TaskEntry {
            running: None,
            pending: None,
            priority,
        });
        
        // 更新优先级
        entry.priority = priority;
        
        if entry.running.is_none() {
            // 没有正在运行的任务，立即启动
            drop(entries);  // 释放锁
            self.start_task(chapter_index, task_fn, priority).await
        } else {
            // 有正在运行的任务
            
            // 取消旧的 pending 任务
            if let Some(old_pending) = entry.pending.take() {
                drop(old_pending);  // 自动取消
            }
            
            // 设置新的 pending 任务
            entry.pending = Some(PendingTask {
                task_fn: Box::pin(task_fn),
                submitted_at: Instant::now(),
            });
            
            // 返回当前 running 任务的 handle（调用者可以 await）
            entry.running.as_ref().unwrap().handle.clone()
        }
    }
    
    /// 启动任务
    async fn start_task<F>(
        &self,
        chapter_index: usize,
        task_fn: F,
        priority: TaskPriority,
    ) -> JoinHandle<Result<ChapterPages>>
    where
        F: Future<Output = Result<ChapterPages>> + Send + 'static,
    {
        let semaphore = self.semaphore.clone();
        let entries = self.entries.clone();
        let cancellation_token = CancellationToken::new();
        let token_clone = cancellation_token.clone();
        
        let handle = tokio::spawn(async move {
            // 获取并发许可
            let _permit = semaphore.acquire().await.unwrap();
            
            // 执行任务（支持取消）
            let result = tokio::select! {
                res = task_fn => res,
                _ = token_clone.cancelled() => {
                    return Err(anyhow!("Task cancelled"));
                }
            };
            
            // 任务完成，检查并启动 pending 任务
            Self::on_task_finished(entries, chapter_index).await;
            
            result
        });
        
        // 更新 entry
        let mut entries_lock = entries.lock().await;
        if let Some(entry) = entries_lock.get_mut(&chapter_index) {
            entry.running = Some(RunningTask {
                handle: handle.clone(),
                started_at: Instant::now(),
                cancellation_token,
            });
        }
        
        handle
    }
    
    /// 任务完成回调
    async fn on_task_finished(
        entries: Arc<Mutex<HashMap<usize, TaskEntry>>>,
        chapter_index: usize,
    ) {
        let mut entries_lock = entries.lock().await;
        let entry = match entries_lock.get_mut(&chapter_index) {
            Some(e) => e,
            None => return,
        };
        
        entry.running = None;
        
        // 如果有 pending 任务，启动它
        if let Some(pending) = entry.pending.take() {
            drop(entries_lock);  // 释放锁
            
            // TODO: 启动 pending 任务
            // self.start_task(chapter_index, pending.task_fn, entry.priority).await;
        } else {
            // 没有 pending 任务，清理 entry
            entries_lock.remove(&chapter_index);
        }
    }
    
    /// 取消章节任务
    pub async fn cancel(&self, chapter_index: usize) {
        let mut entries = self.entries.lock().await;
        if let Some(entry) = entries.remove(&chapter_index) {
            if let Some(running) = entry.running {
                running.cancellation_token.cancel();
                running.handle.abort();
            }
            drop(entry.pending);  // 取消 pending
        }
    }
    
    /// 取消所有低优先级任务
    pub async fn cancel_low_priority(&self, min_priority: TaskPriority) {
        let mut entries = self.entries.lock().await;
        let to_cancel: Vec<usize> = entries
            .iter()
            .filter(|(_, entry)| entry.priority < min_priority)
            .map(|(idx, _)| *idx)
            .collect();
        
        for idx in to_cancel {
            if let Some(entry) = entries.remove(&idx) {
                if let Some(running) = entry.running {
                    running.cancellation_token.cancel();
                }
            }
        }
    }
    
    /// 获取调度统计
    pub async fn stats(&self) -> SchedulerStats {
        let entries = self.entries.lock().await;
        
        let running_count = entries.values().filter(|e| e.running.is_some()).count();
        let pending_count = entries.values().filter(|e| e.pending.is_some()).count();
        
        SchedulerStats {
            total_entries: entries.len(),
            running_count,
            pending_count,
            available_permits: self.semaphore.available_permits(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SchedulerStats {
    pub total_entries: usize,
    pub running_count: usize,
    pub pending_count: usize,
    pub available_permits: usize,
}
```

### 调度策略

```rust
// rust/crates/reader_core/src/scheduler/policy.rs

/// 调度策略
pub trait SchedulingPolicy: Send + Sync {
    /// 计算章节任务优先级
    fn calculate_priority(
        &self,
        chapter_index: usize,
        current_chapter: usize,
    ) -> TaskPriority;
    
    /// 是否应该取消任务
    fn should_cancel(
        &self,
        chapter_index: usize,
        current_chapter: usize,
    ) -> bool;
}

/// 默认调度策略（参考 Legado）
pub struct DefaultSchedulingPolicy;

impl SchedulingPolicy for DefaultSchedulingPolicy {
    fn calculate_priority(
        &self,
        chapter_index: usize,
        current_chapter: usize,
    ) -> TaskPriority {
        let offset = chapter_index as i32 - current_chapter as i32;
        
        match offset {
            0 => TaskPriority::Critical,   // 当前章
            1 => TaskPriority::High,       // 下一章
            -1 => TaskPriority::Normal,    // 前一章
            _ => TaskPriority::Low,        // 其他章节
        }
    }
    
    fn should_cancel(
        &self,
        chapter_index: usize,
        current_chapter: usize,
    ) -> bool {
        let offset = (chapter_index as i32 - current_chapter as i32).abs();
        offset > 3  // 距离超过 3 章的任务取消
    }
}
```

---

## 📚 多格式文件支持

### 格式检测

```rust
// rust/crates/book_parser/src/format_detector.rs

pub struct FormatDetector;

impl FormatDetector {
    /// 检测文件格式
    pub fn detect(path: &Path) -> Result<BookFormat> {
        // 1. 先检查扩展名
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            match ext.to_lowercase().as_str() {
                "txt" => return Ok(BookFormat::Txt),
                "epub" => return Ok(BookFormat::Epub),
                "mobi" | "azw" | "azw3" => return Ok(BookFormat::Mobi),
                "pdf" => return Ok(BookFormat::Pdf),
                "umd" => return Ok(BookFormat::Umd),
                _ => {}
            }
        }
        
        // 2. 读取文件头（Magic Number）
        let mut file = File::open(path)?;
        let mut magic = [0u8; 8];
        file.read_exact(&mut magic)?;
        
        if Self::is_epub(&magic) {
            return Ok(BookFormat::Epub);
        }
        if Self::is_pdf(&magic) {
            return Ok(BookFormat::Pdf);
        }
        if Self::is_mobi(&magic) {
            return Ok(BookFormat::Mobi);
        }
        
        // 3. 默认 TXT
        Ok(BookFormat::Txt)
    }
    
    fn is_epub(magic: &[u8]) -> bool {
        magic.starts_with(b"PK\x03\x04")  // ZIP 格式
    }
    
    fn is_pdf(magic: &[u8]) -> bool {
        magic.starts_with(b"%PDF")
    }
    
    fn is_mobi(magic: &[u8]) -> bool {
        &magic[60..68] == b"BOOKMOBI" || &magic[60..68] == b"TEXtREAd"
    }
}
```

### TXT 解析器（已实现，需优化）

```rust
// rust/crates/book_parser/src/txt_parser.rs

pub struct TxtParser {
    file_path: PathBuf,
    content: String,  // 或使用 mmap 零拷贝
    chapters: Vec<ChapterInfo>,
    metadata: Option<BookMetadata>,
}

impl BookParser for TxtParser {
    fn parse_metadata(&mut self) -> Result<BookMetadata> {
        // 从文件名推断标题
        let title = self.file_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("未知书籍")
            .to_string();
        
        let file_size = fs::metadata(&self.file_path)?.len();
        
        Ok(BookMetadata {
            title,
            author: String::new(),
            cover_data: None,
            language: "zh-CN".to_string(),
            publisher: None,
            total_chapters: 0,  // 需要 parse 后才知道
            file_size,
            format: BookFormat::Txt,
        })
    }
    
    fn get_chapter_list(&mut self) -> Result<Vec<ChapterInfo>> {
        if self.chapters.is_empty() {
            self.extract_chapters()?;
        }
        Ok(self.chapters.clone())
    }
    
    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        let chapter = self.chapters.get(chapter_index)
            .ok_or_else(|| anyhow!("Chapter not found"))?;
        
        let start = chapter.start_offset.unwrap();
        let end = chapter.end_offset.unwrap();
        
        Ok(self.content[start..end].to_string())
    }
    
    fn get_resource(&mut self, _resource_id: &str) -> Result<Vec<u8>> {
        Err(anyhow!("TXT format does not support resources"))
    }
    
    fn estimate_chapter_length(&self, chapter_index: usize) -> usize {
        self.chapters.get(chapter_index)
            .map(|c| c.estimated_words)
            .unwrap_or(0)
    }
    
    fn cleanup(&mut self) {
        self.content.clear();
        self.chapters.clear();
    }
    
    fn clone_parser(&self) -> Box<dyn BookParser> {
        Box::new(TxtParser {
            file_path: self.file_path.clone(),
            content: String::new(),  // 不克隆内容，按需加载
            chapters: self.chapters.clone(),
            metadata: self.metadata.clone(),
        })
    }
}

impl TxtParser {
    /// 提取章节（智能识别章节标题）
    fn extract_chapters(&mut self) -> Result<()> {
        // 使用正则规则库识别章节
        let rules = ChapterRecognitionRules::default();
        
        // TODO: 实现章节识别逻辑
        // 参考现有的 book_parser 实现
        
        Ok(())
    }
}
```

### EPUB 解析器（新增）

```rust
// rust/crates/book_parser/src/epub_parser.rs

use epub::doc::EpubDoc;

pub struct EpubParser {
    file_path: PathBuf,
    doc: Option<EpubDoc<BufReader<File>>>,
    metadata: Option<BookMetadata>,
    chapters: Vec<ChapterInfo>,
}

impl BookParser for EpubParser {
    fn parse_metadata(&mut self) -> Result<BookMetadata> {
        let doc = self.get_or_open_doc()?;
        
        Ok(BookMetadata {
            title: doc.mdata("title").unwrap_or_else(|| "未知书籍".to_string()),
            author: doc.mdata("creator").unwrap_or_default(),
            cover_data: doc.get_cover().ok(),
            language: doc.mdata("language").unwrap_or_else(|| "zh-CN".to_string()),
            publisher: doc.mdata("publisher"),
            total_chapters: 0,
            file_size: fs::metadata(&self.file_path)?.len(),
            format: BookFormat::Epub,
        })
    }
    
    fn get_chapter_list(&mut self) -> Result<Vec<ChapterInfo>> {
        if self.chapters.is_empty() {
            self.extract_chapters()?;
        }
        Ok(self.chapters.clone())
    }
    
    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        let chapter = self.chapters.get(chapter_index)
            .ok_or_else(|| anyhow!("Chapter not found"))?;
        
        let doc = self.get_or_open_doc()?;
        
        // 通过 spine href 获取内容
        let href = chapter.resource_href.as_ref().unwrap();
        let content = doc.get_resource_str_by_path(href)?;
        
        // 清洗 HTML（移除标签，保留文本）
        let cleaned = Self::clean_html(&content)?;
        
        Ok(cleaned)
    }
    
    fn get_resource(&mut self, resource_id: &str) -> Result<Vec<u8>> {
        let doc = self.get_or_open_doc()?;
        doc.get_resource(resource_id)
            .ok_or_else(|| anyhow!("Resource not found: {}", resource_id))
    }
    
    fn estimate_chapter_length(&self, chapter_index: usize) -> usize {
        self.chapters.get(chapter_index)
            .map(|c| c.estimated_words)
            .unwrap_or(5000)  // EPUB 默认估计 5000 字
    }
    
    fn cleanup(&mut self) {
        self.doc = None;
        self.chapters.clear();
    }
    
    fn clone_parser(&self) -> Box<dyn BookParser> {
        Box::new(EpubParser {
            file_path: self.file_path.clone(),
            doc: None,  // 不克隆 doc，按需打开
            metadata: self.metadata.clone(),
            chapters: self.chapters.clone(),
        })
    }
}

impl EpubParser {
    fn get_or_open_doc(&mut self) -> Result<&mut EpubDoc<BufReader<File>>> {
        if self.doc.is_none() {
            self.doc = Some(EpubDoc::new(&self.file_path)?);
        }
        Ok(self.doc.as_mut().unwrap())
    }
    
    fn extract_chapters(&mut self) -> Result<()> {
        let doc = self.get_or_open_doc()?;
        
        // 从 spine 提取章节顺序
        let spine = doc.spine.clone();
        
        for (index, spine_item) in spine.iter().enumerate() {
            self.chapters.push(ChapterInfo {
                index,
                title: spine_item.to_string(),  // TODO: 从 TOC 获取真实标题
                estimated_words: 5000,
                start_offset: None,
                end_offset: None,
                resource_href: Some(spine_item.clone()),
                fragment_id: None,
            });
        }
        
        Ok(())
    }
    
    fn clean_html(html: &str) -> Result<String> {
        use scraper::{Html, Selector};
        
        let document = Html::parse_document(html);
        let body_selector = Selector::parse("body").unwrap();
        
        if let Some(body) = document.select(&body_selector).next() {
            Ok(body.text().collect::<Vec<_>>().join("\n"))
        } else {
            Ok(document.root_element().text().collect::<Vec<_>>().join("\n"))
        }
    }
}
```

---

## 🔄 内容处理流水线

### 设计目标

1. **模块化处理**：每个处理步骤独立、可配置、可跳过
2. **流式传输**：使用 Channel 增量传递结果，减少首屏延迟
3. **完全兼容 Legado**：支持所有替换规则（正则、JS、简繁转换）
4. **超时保护**：防止复杂正则或 JS 导致卡死
5. **性能优化**：正则缓存、HTML 占位符保护

### 核心实现

```rust
// rust/crates/reader_core/src/processing/pipeline.rs

use tokio::sync::mpsc;
use std::time::Duration;

/// 内容处理流水线
pub struct ProcessingPipeline {
    /// 预处理器
    preprocessor: ContentPreprocessor,
    
    /// 排版引擎
    layout_engine: Arc<Mutex<LayoutEngine>>,
    
    /// 分页器
    paginator: Paginator,
    
    /// 流水线配置
    config: PipelineConfig,
}

#[derive(Debug, Clone)]
pub struct PipelineConfig {
    pub remove_duplicate_title: bool,
    pub re_segment: bool,
    pub chinese_convert: Option<ChineseConvertType>,
    pub apply_replace_rules: bool,
    pub apply_user_markings: bool,
    pub enable_incremental_layout: bool,  // 增量排版
}

impl ProcessingPipeline {
    /// 处理章节（完整流水线）
    pub async fn process_chapter(
        &mut self,
        raw_content: String,
        chapter_index: usize,
        page_config: PageConfig,
    ) -> Result<Vec<Page>> {
        // Stage 1: 内容预处理
        let processed_content = self.preprocessor.process(
            &raw_content,
            ProcessOptions {
                title: String::new(),  // TODO: 从章节信息获取
                remove_duplicate_title: self.config.remove_duplicate_title,
                re_segment: self.config.re_segment,
                chinese_convert: self.config.chinese_convert.clone(),
                apply_replace_rules: self.config.apply_replace_rules,
                chapter_index,
            },
        ).await?;
        
        // Stage 2: 排版
        let layout_result = {
            let mut engine = self.layout_engine.lock().await;
            engine.layout_text(&processed_content, chapter_index)?
        };
        
        // Stage 3: 分页
        let pages = self.paginator.paginate(layout_result, page_config)?;
        
        Ok(pages)
    }
    
    /// 流式处理章节（增量排版 + Channel 传输）
    pub async fn process_chapter_streaming(
        &mut self,
        raw_content: String,
        chapter_index: usize,
        page_config: PageConfig,
    ) -> (mpsc::Receiver<Page>, JoinHandle<Result<()>>) {
        let (tx, rx) = mpsc::channel::<Page>(10);
        
        let preprocessor = self.preprocessor.clone();
        let layout_engine = self.layout_engine.clone();
        let paginator = self.paginator.clone();
        let pipeline_config = self.config.clone();
        
        let handle = tokio::spawn(async move {
            // Stage 1: 预处理
            let processed_content = preprocessor.process(
                &raw_content,
                ProcessOptions {
                    title: String::new(),
                    remove_duplicate_title: pipeline_config.remove_duplicate_title,
                    re_segment: pipeline_config.re_segment,
                    chinese_convert: pipeline_config.chinese_convert,
                    apply_replace_rules: pipeline_config.apply_replace_rules,
                    chapter_index,
                },
            ).await?;
            
            // Stage 2 + 3: 增量排版并流式分页
            let mut engine = layout_engine.lock().await;
            let mut current_page_lines = Vec::new();
            let mut current_height = page_config.padding.top;
            let mut page_index = 0;
            
            // 按段落迭代
            for paragraph in processed_content.split("\n\n") {
                let lines = engine.layout_paragraph(paragraph, &page_config)?;
                
                for line in lines {
                    if current_height + line.height > page_config.height - page_config.padding.bottom {
                        // 页面已满，发送当前页
                        let page = Page {
                            page_index,
                            lines: current_page_lines.clone(),
                            start_char: 0,  // TODO: 精确计算
                            end_char: 0,
                        };
                        
                        if tx.send(page).await.is_err() {
                            // 接收方已关闭
                            return Ok(());
                        }
                        
                        current_page_lines.clear();
                        current_height = page_config.padding.top;
                        page_index += 1;
                    }
                    
                    current_page_lines.push(line);
                    current_height += line.height + page_config.line_spacing;
                }
            }
            
            // 发送最后一页
            if !current_page_lines.is_empty() {
                let page = Page {
                    page_index,
                    lines: current_page_lines,
                    start_char: 0,
                    end_char: processed_content.len(),
                };
                let _ = tx.send(page).await;
            }
            
            Ok(())
        });
        
        (rx, handle)
    }
}
```

### 内容预处理器（完全兼容 Legado）

```rust
// rust/crates/reader_core/src/processing/preprocessor.rs

use regex::Regex;
use lru::LruCache;
use rquickjs::{Context, Runtime};

/// 内容预处理器
pub struct ContentPreprocessor {
    /// 替换规则缓存
    replace_rules: Arc<RwLock<Vec<ReplaceRule>>>,
    
    /// 正则编译缓存（LRU，容量 100）
    regex_cache: Arc<Mutex<LruCache<String, Regex>>>,
    
    /// JavaScript 运行时（用于 @js: 规则）
    js_runtime: Arc<Mutex<Option<JsRuntime>>>,
    
    /// 简繁转换器
    chinese_converter: ChineseConverter,
}

#[derive(Debug, Clone)]
pub struct ReplaceRule {
    pub id: String,
    pub pattern: String,
    pub replacement: String,
    pub is_regex: bool,
    pub scope: RuleScope,  // 书籍/全局
    pub timeout_ms: u64,
    pub enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuleScope {
    Global,      // 全局规则
    BookScope,   // 特定书籍
}

#[derive(Debug, Clone)]
pub struct ProcessOptions {
    pub title: String,
    pub remove_duplicate_title: bool,
    pub re_segment: bool,
    pub chinese_convert: Option<ChineseConvertType>,
    pub apply_replace_rules: bool,
    pub chapter_index: usize,
}

impl ContentPreprocessor {
    pub fn new() -> Self {
        Self {
            replace_rules: Arc::new(RwLock::new(Vec::new())),
            regex_cache: Arc::new(Mutex::new(LruCache::new(
                std::num::NonZeroUsize::new(100).unwrap()
            ))),
            js_runtime: Arc::new(Mutex::new(None)),
            chinese_converter: ChineseConverter::new(),
        }
    }
    
    /// 预处理内容（完整流程）
    pub async fn process(
        &self,
        raw_content: &str,
        options: ProcessOptions,
    ) -> Result<String> {
        let mut content = raw_content.to_string();
        
        // Step 1: 去除重复标题
        if options.remove_duplicate_title && !options.title.is_empty() {
            content = self.remove_duplicate_title(&content, &options.title)?;
        }
        
        // Step 2: 重新分段
        if options.re_segment {
            content = self.re_segment(&content)?;
        }
        
        // Step 3: 简繁转换
        if let Some(convert_type) = options.chinese_convert {
            content = self.chinese_converter.convert(&content, convert_type)?;
        }
        
        // Step 4: HTML 特殊格式保护
        let (protected_content, html_map) = self.protect_html_tags(&content)?;
        content = protected_content;
        
        // Step 5: 应用替换规则（带超时保护）
        if options.apply_replace_rules {
            content = self.apply_replace_rules(&content).await?;
        }
        
        // Step 6: 恢复 HTML 标签
        for (placeholder, original) in html_map {
            content = content.replace(&placeholder, &original);
        }
        
        Ok(content)
    }
    
    /// 去除重复标题
    fn remove_duplicate_title(&self, content: &str, title: &str) -> Result<String> {
        let trimmed = content.trim_start();
        
        if trimmed.starts_with(title) {
            Ok(trimmed[title.len()..].trim_start().to_string())
        } else {
            Ok(content.to_string())
        }
    }
    
    /// 重新分段（规范化段落格式）
    fn re_segment(&self, content: &str) -> Result<String> {
        // 1. 去除多余空行（连续 3+ 个换行符 → 2 个）
        let re = Regex::new(r"\n{3,}").unwrap();
        let mut result = re.replace_all(content, "\n\n").to_string();
        
        // 2. 段落首行缩进标准化
        let re_indent = Regex::new(r"(?m)^[\s　]+").unwrap();
        result = re_indent.replace_all(&result, "　　").to_string();
        
        Ok(result)
    }
    
    /// HTML 标签保护
    fn protect_html_tags(&self, content: &str) -> Result<(String, HashMap<String, String>)> {
        let mut html_map = HashMap::new();
        let mut counter = 0;
        
        let html_regex = Regex::new(r"<[^>]+>")?;
        let protected = html_regex.replace_all(content, |caps: &regex::Captures| {
            let placeholder = format!("__HTML_PLACEHOLDER_{:04}__", counter);
            html_map.insert(placeholder.clone(), caps[0].to_string());
            counter += 1;
            placeholder
        });
        
        Ok((protected.to_string(), html_map))
    }
    
    /// 应用替换规则（带超时保护）
    async fn apply_replace_rules(&self, content: &str) -> Result<String> {
        let rules = self.replace_rules.read().await.clone();
        let mut result = content.to_string();
        
        for rule in rules.iter().filter(|r| r.enabled) {
            let start = Instant::now();
            
            if rule.is_regex {
                match self.apply_regex_rule(&result, rule).await {
                    Ok(replaced) => result = replaced,
                    Err(e) if e.to_string().contains("timeout") => {
                        warn!("Regex rule '{}' timeout, skipping", rule.pattern);
                        self.disable_rule(&rule.id).await;
                    }
                    Err(e) => return Err(e),
                }
            } else {
                result = result.replace(&rule.pattern, &rule.replacement);
            }
            
            if start.elapsed() > Duration::from_secs(5) {
                warn!("Replace rules total timeout");
                break;
            }
        }
        
        Ok(result)
    }
    
    /// 应用正则规则（带超时）
    async fn apply_regex_rule(&self, content: &str, rule: &ReplaceRule) -> Result<String> {
        let regex = self.get_or_compile_regex(&rule.pattern)?;
        
        let content = content.to_string();
        let replacement = rule.replacement.clone();
        let timeout_duration = Duration::from_millis(rule.timeout_ms);
        
        tokio::time::timeout(timeout_duration, async move {
            tokio::task::spawn_blocking(move || {
                regex.replace_all(&content, replacement.as_str()).to_string()
            }).await
        })
        .await
        .map_err(|_| anyhow!("Regex timeout"))?
        .map_err(|e| anyhow!("Regex error: {}", e))
    }
    
    /// 获取或编译正则（带缓存）
    fn get_or_compile_regex(&self, pattern: &str) -> Result<Regex> {
        let mut cache = self.regex_cache.lock().unwrap();
        
        if let Some(regex) = cache.get(pattern) {
            return Ok(regex.clone());
        }
        
        let regex = Regex::new(pattern)?;
        cache.put(pattern.to_string(), regex.clone());
        
        Ok(regex)
    }
    
    async fn disable_rule(&self, rule_id: &str) {
        let mut rules = self.replace_rules.write().await;
        if let Some(rule) = rules.iter_mut().find(|r| r.id == rule_id) {
            rule.enabled = false;
        }
    }
}
```

---

现在让我继续创建第二个文档文件，包含剩余的核心内容：统一阅读会话管理器、性能指标和实施路线图：
