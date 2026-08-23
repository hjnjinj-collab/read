# 统一阅读会话管理器与实施方案

> **本文档是《高性能核心阅读加载方案设计》的续篇**  
> 包含：统一阅读会话、性能指标、实施路线图

---

## 📖 统一阅读会话管理器

### 设计目标

1. **统一入口**：所有阅读操作通过 ReadSession 统一管理
2. **状态一致性**：当前章节、页码、进度全局唯一
3. **三章缓存**：自动管理 prev/current/next 章节
4. **异步预加载**：后台自动预加载相邻章节
5. **生命周期管理**：打开→阅读→翻页→跳转→保存→关闭

### 核心实现

```rust
// rust/crates/reader_core/src/session/read_session.rs

use std::sync::Arc;
use tokio::sync::{Mutex, RwLock};
use std::collections::HashMap;

/// 统一阅读会话管理器
pub struct ReadSession {
    /// 会话 ID
    pub session_id: String,
    
    /// 书籍信息
    pub book_id: String,
    pub book_metadata: BookMetadata,
    pub chapters: Vec<ChapterInfo>,
    
    /// 当前阅读位置
    pub current_chapter: usize,
    pub current_page: usize,
    pub current_char_pos: usize,
    
    /// 书籍解析器
    parser: Arc<Mutex<Box<dyn BookParser>>>,
    
    /// 内容处理流水线
    pipeline: Arc<Mutex<ProcessingPipeline>>,
    
    /// 任务调度器
    scheduler: Arc<ChapterTaskScheduler>,
    
    /// 缓存管理器
    cache_manager: Arc<Mutex<CacheManager>>,
    
    /// 三章缓存
    chapter_cache: Arc<RwLock<ChapterCache>>,
    
    /// 预加载策略
    preload_strategy: Box<dyn PreloadStrategy>,
    
    /// 页面配置
    page_config: PageConfig,
    
    /// 并发控制锁
    prev_lock: Arc<Mutex<()>>,
    cur_lock: Arc<Mutex<()>>,
    next_lock: Arc<Mutex<()>>,
}

/// 三章缓存结构
pub struct ChapterCache {
    pub prev: Option<CachedChapterPages>,
    pub current: Option<CachedChapterPages>,
    pub next: Option<CachedChapterPages>,
}

impl ReadSession {
    /// 打开书籍（创建新会话）
    pub async fn open_book(
        book_path: &str,
        page_config: PageConfig,
        pipeline_config: PipelineConfig,
    ) -> Result<Self> {
        // 1. 检测文件格式
        let format = FormatDetector::detect(Path::new(book_path))?;
        
        // 2. 创建对应的解析器
        let mut parser: Box<dyn BookParser> = match format {
            BookFormat::Txt => Box::new(TxtParser::new(book_path)?),
            BookFormat::Epub => Box::new(EpubParser::new(book_path)?),
            _ => return Err(anyhow!("Unsupported format: {:?}", format)),
        };
        
        // 3. 解析元信息和章节列表
        let metadata = parser.parse_metadata()?;
        let chapters = parser.get_chapter_list()?;
        
        let total_chapters = chapters.len();
        let book_id = format!("{:x}", md5::compute(book_path));
        let session_id = uuid::Uuid::new_v4().to_string();
        
        // 4. 创建流水线和调度器
        let pipeline = ProcessingPipeline::new(pipeline_config)?;
        let scheduler = ChapterTaskScheduler::new(3);  // 最多 3 章并行
        let cache_manager = CacheManager::new(10, true);  // 缓存 10 章 + 磁盘缓存
        
        // 5. 初始化会话
        let session = Self {
            session_id,
            book_id,
            book_metadata: metadata,
            chapters,
            current_chapter: 0,
            current_page: 0,
            current_char_pos: 0,
            parser: Arc::new(Mutex::new(parser)),
            pipeline: Arc::new(Mutex::new(pipeline)),
            scheduler: Arc::new(scheduler),
            cache_manager: Arc::new(Mutex::new(cache_manager)),
            chapter_cache: Arc::new(RwLock::new(ChapterCache {
                prev: None,
                current: None,
                next: None,
            })),
            preload_strategy: Box::new(DefaultPreloadStrategy),
            page_config,
            prev_lock: Arc::new(Mutex::new(())),
            cur_lock: Arc::new(Mutex::new(())),
            next_lock: Arc::new(Mutex::new(())),
        };
        
        // 6. 加载第一章
        session.load_chapter(0, TaskPriority::Critical).await?;
        
        // 7. 异步预加载相邻章节
        session.trigger_preload().await;
        
        Ok(session)
    }
    
    /// 恢复会话（从进度记录恢复）
    pub async fn restore_session(
        book_path: &str,
        progress: ReadProgress,
        page_config: PageConfig,
        pipeline_config: PipelineConfig,
    ) -> Result<Self> {
        let mut session = Self::open_book(book_path, page_config, pipeline_config).await?;
        
        // 恢复阅读位置
        session.current_chapter = progress.chapter_index;
        session.current_page = progress.page_index;
        session.current_char_pos = progress.char_offset;
        
        // 重新加载当前章节
        session.load_chapter(progress.chapter_index, TaskPriority::Critical).await?;
        
        Ok(session)
    }
    
    /// 加载章节（核心方法）
    async fn load_chapter(&self, chapter_index: usize, priority: TaskPriority) -> Result<()> {
        // 1. 检查缓存
        {
            let cache = self.chapter_cache.read().await;
            if self.is_chapter_cached(&cache, chapter_index) {
                return Ok(());  // 已缓存，直接返回
            }
        }
        
        // 2. 提交到任务调度器
        let session = self.clone_arc_refs();
        let chapter_idx = chapter_index;
        
        self.scheduler.submit(chapter_index, priority, async move {
            session.process_chapter_task(chapter_idx).await
        }).await;
        
        Ok(())
    }
    
    /// 处理章节任务（在调度器中执行）
    async fn process_chapter_task(&self, chapter_index: usize) -> Result<ChapterPages> {
        let offset = chapter_index as i32 - self.current_chapter as i32;
        
        // 1. 获取原始内容
        let raw_content = {
            let mut parser = self.parser.lock().await;
            parser.get_chapter_content(chapter_index)?
        };
        
        // 2. 检查磁盘缓存
        let cache_key = CacheKey::new(&self.book_id, chapter_index, &self.page_config);
        {
            let mut cache_mgr = self.cache_manager.lock().await;
            if let Some(cached) = cache_mgr.get(&cache_key).await {
                self.update_chapter_cache(chapter_index, cached).await;
                return Ok(cached.into());
            }
        }
        
        // 3. 执行内容处理流水线
        match offset {
            0 => {
                // 当前章：完整处理 + 流式传输
                let _lock = self.cur_lock.lock().await;
                let (page_rx, handle) = {
                    let mut pipeline = self.pipeline.lock().await;
                    pipeline.process_chapter_streaming(
                        raw_content,
                        chapter_index,
                        self.page_config.clone(),
                    ).await
                };
                
                // 实时接收页面
                let mut pages = Vec::new();
                while let Some(page) = page_rx.recv().await {
                    pages.push(page.clone());
                    
                    // 找到当前阅读位置的页面，立即通知 UI
                    if page.contains_char_pos(self.current_char_pos) {
                        // TODO: 回调 Flutter UI
                    }
                }
                
                handle.await??;
                
                let chapter_pages = ChapterPages {
                    chapter_index,
                    pages,
                    total_pages: pages.len(),
                };
                
                self.update_chapter_cache(chapter_index, chapter_pages.clone()).await;
                Ok(chapter_pages)
            }
            
            1 => {
                // 下一章：只处理前 2 页
                let _lock = self.next_lock.lock().await;
                let (page_rx, handle) = {
                    let mut pipeline = self.pipeline.lock().await;
                    pipeline.process_chapter_streaming(
                        raw_content,
                        chapter_index,
                        self.page_config.clone(),
                    ).await
                };
                
                let mut pages = Vec::new();
                let mut count = 0;
                while let Some(page) = page_rx.recv().await {
                    pages.push(page);
                    count += 1;
                    if count >= 2 {
                        break;  // 只要前 2 页
                    }
                }
                
                // 取消剩余任务
                drop(page_rx);
                
                let chapter_pages = ChapterPages {
                    chapter_index,
                    pages,
                    total_pages: count,  // 不完整
                };
                
                self.update_chapter_cache(chapter_index, chapter_pages.clone()).await;
                Ok(chapter_pages)
            }
            
            -1 => {
                // 前一章：完整处理但不流式传输
                let _lock = self.prev_lock.lock().await;
                let pages = {
                    let mut pipeline = self.pipeline.lock().await;
                    pipeline.process_chapter(
                        raw_content,
                        chapter_index,
                        self.page_config.clone(),
                    ).await?
                };
                
                let chapter_pages = ChapterPages {
                    chapter_index,
                    pages,
                    total_pages: pages.len(),
                };
                
                self.update_chapter_cache(chapter_index, chapter_pages.clone()).await;
                Ok(chapter_pages)
            }
            
            _ => {
                // 其他章节：不应该到这里（已在调度器中取消）
                Err(anyhow!("Invalid chapter offset: {}", offset))
            }
        }
    }
    
    /// 更新三章缓存
    async fn update_chapter_cache(&self, chapter_index: usize, pages: ChapterPages) {
        let mut cache = self.chapter_cache.write().await;
        let offset = chapter_index as i32 - self.current_chapter as i32;
        
        match offset {
            0 => cache.current = Some(pages.into()),
            1 => cache.next = Some(pages.into()),
            -1 => cache.prev = Some(pages.into()),
            _ => {}
        }
        
        // 同时写入缓存管理器
        let cache_key = CacheKey::new(&self.book_id, chapter_index, &self.page_config);
        let mut cache_mgr = self.cache_manager.lock().await;
        cache_mgr.put(cache_key, pages.into()).await;
    }
    
    /// 下一页
    pub async fn next_page(&mut self) -> Result<NavigationResult> {
        let cache = self.chapter_cache.read().await;
        let current = cache.current.as_ref()
            .ok_or_else(|| anyhow!("No current chapter"))?;
        
        if self.current_page < current.total_pages - 1 {
            // 章节内翻页
            self.current_page += 1;
            Ok(NavigationResult::PageChanged {
                page: self.get_current_page().await?,
            })
        } else if self.current_chapter < self.chapters.len() - 1 {
            // 切换到下一章
            drop(cache);
            self.move_to_next_chapter().await?;
            Ok(NavigationResult::ChapterChanged {
                chapter_index: self.current_chapter,
                page: self.get_current_page().await?,
            })
        } else {
            Ok(NavigationResult::ReachedEnd)
        }
    }
    
    /// 上一页
    pub async fn prev_page(&mut self) -> Result<NavigationResult> {
        if self.current_page > 0 {
            self.current_page -= 1;
            Ok(NavigationResult::PageChanged {
                page: self.get_current_page().await?,
            })
        } else if self.current_chapter > 0 {
            self.move_to_prev_chapter().await?;
            Ok(NavigationResult::ChapterChanged {
                chapter_index: self.current_chapter,
                page: self.get_current_page().await?,
            })
        } else {
            Ok(NavigationResult::ReachedStart)
        }
    }
    
    /// 移动到下一章
    async fn move_to_next_chapter(&mut self) -> Result<()> {
        self.current_chapter += 1;
        self.current_page = 0;
        
        // 滑动三章缓存窗口
        {
            let mut cache = self.chapter_cache.write().await;
            cache.prev = cache.current.take();
            cache.current = cache.next.take();
            cache.next = None;
        }
        
        // 如果下一章未缓存，立即加载
        if self.chapter_cache.read().await.current.is_none() {
            self.load_chapter(self.current_chapter, TaskPriority::Critical).await?;
        }
        
        // 触发预加载
        self.trigger_preload().await;
        
        // 取消距离超过 3 章的任务
        self.scheduler.cancel_low_priority(TaskPriority::Low).await;
        
        Ok(())
    }
    
    /// 移动到前一章
    async fn move_to_prev_chapter(&mut self) -> Result<()> {
        self.current_chapter -= 1;
        
        // 获取前一章的总页数
        let prev_pages = {
            let cache = self.chapter_cache.read().await;
            cache.prev.as_ref()
                .map(|c| c.total_pages)
                .unwrap_or(0)
        };
        
        if prev_pages == 0 {
            // 前一章未缓存，需要加载
            self.load_chapter(self.current_chapter, TaskPriority::Critical).await?;
            
            // 重新获取总页数
            let cache = self.chapter_cache.read().await;
            let prev_pages = cache.current.as_ref()
                .map(|c| c.total_pages)
                .unwrap_or(1);
            self.current_page = prev_pages - 1;
        } else {
            self.current_page = prev_pages - 1;
        }
        
        // 滑动缓存窗口
        {
            let mut cache = self.chapter_cache.write().await;
            cache.next = cache.current.take();
            cache.current = cache.prev.take();
            cache.prev = None;
        }
        
        self.trigger_preload().await;
        
        Ok(())
    }
    
    /// 跳转到指定章节
    pub async fn jump_to_chapter(&mut self, chapter_index: usize, page_index: usize) -> Result<()> {
        if chapter_index >= self.chapters.len() {
            return Err(anyhow!("Invalid chapter index"));
        }
        
        self.current_chapter = chapter_index;
        self.current_page = page_index;
        
        // 清空三章缓存
        {
            let mut cache = self.chapter_cache.write().await;
            *cache = ChapterCache {
                prev: None,
                current: None,
                next: None,
            };
        }
        
        // 取消所有旧任务
        for i in 0..self.chapters.len() {
            self.scheduler.cancel(i).await;
        }
        
        // 加载目标章节
        self.load_chapter(chapter_index, TaskPriority::Critical).await?;
        
        // 触发预加载
        self.trigger_preload().await;
        
        Ok(())
    }
    
    /// 触发预加载
    async fn trigger_preload(&self) {
        let chapters_to_preload = self.preload_strategy.calculate_preload_chapters(
            self.current_chapter,
            self.chapters.len(),
        );
        
        for chapter_idx in chapters_to_preload {
            let offset = chapter_idx as i32 - self.current_chapter as i32;
            let priority = self.preload_strategy.preload_priority(offset);
            
            let _ = self.load_chapter(chapter_idx, priority).await;
        }
    }
    
    /// 获取当前页面
    pub async fn get_current_page(&self) -> Result<Page> {
        let cache = self.chapter_cache.read().await;
        let current = cache.current.as_ref()
            .ok_or_else(|| anyhow!("No current chapter"))?;
        
        current.pages.get(self.current_page)
            .cloned()
            .ok_or_else(|| anyhow!("Page not found"))
    }
    
    /// 获取当前会话状态
    pub async fn get_session_state(&self) -> SessionState {
        SessionState {
            book_id: self.book_id.clone(),
            chapter_index: self.current_chapter,
            page_index: self.current_page,
            chapter_title: self.chapters.get(self.current_chapter)
                .map(|c| c.title.clone())
                .unwrap_or_default(),
            progress_percent: self.calculate_progress(),
        }
    }
    
    /// 计算全书进度
    fn calculate_progress(&self) -> f32 {
        // 简化版：按章节数计算
        // TODO: 使用字数估算更精确的进度
        (self.current_chapter as f32 / self.chapters.len() as f32) * 100.0
    }
    
    /// 保存阅读进度
    pub async fn save_progress(&self) -> Result<()> {
        let progress = ReadProgress {
            book_path: self.book_id.clone(),
            chapter_index: self.current_chapter,
            page_index: self.current_page,
            char_offset: self.current_char_pos,
            progress_percent: self.calculate_progress(),
            last_read_time: SystemTime::now(),
            total_read_duration: Duration::from_secs(0),  // TODO: 实现计时
        };
        
        // TODO: 保存到数据库
        
        Ok(())
    }
    
    /// 关闭会话
    pub async fn close(&mut self) -> Result<()> {
        // 1. 保存进度
        self.save_progress().await?;
        
        // 2. 取消所有任务
        for i in 0..self.chapters.len() {
            self.scheduler.cancel(i).await;
        }
        
        // 3. 清理缓存
        {
            let mut cache = self.chapter_cache.write().await;
            *cache = ChapterCache {
                prev: None,
                current: None,
                next: None,
            };
        }
        
        // 4. 清理解析器
        {
            let mut parser = self.parser.lock().await;
            parser.cleanup();
        }
        
        Ok(())
    }
    
    fn is_chapter_cached(&self, cache: &ChapterCache, chapter_index: usize) -> bool {
        let offset = chapter_index as i32 - self.current_chapter as i32;
        match offset {
            0 => cache.current.is_some(),
            1 => cache.next.is_some(),
            -1 => cache.prev.is_some(),
            _ => false,
        }
    }
    
    fn clone_arc_refs(&self) -> SessionArcRefs {
        SessionArcRefs {
            parser: self.parser.clone(),
            pipeline: self.pipeline.clone(),
            cache_manager: self.cache_manager.clone(),
            chapter_cache: self.chapter_cache.clone(),
            // ... 其他 Arc 字段
        }
    }
}

/// 导航结果
#[derive(Debug, Clone)]
pub enum NavigationResult {
    PageChanged { page: Page },
    ChapterChanged { chapter_index: usize, page: Page },
    ReachedStart,
    ReachedEnd,
}

/// 会话状态
#[derive(Debug, Clone)]
pub struct SessionState {
    pub book_id: String,
    pub chapter_index: usize,
    pub page_index: usize,
    pub chapter_title: String,
    pub progress_percent: f32,
}

/// 章节页面数据
#[derive(Debug, Clone)]
pub struct ChapterPages {
    pub chapter_index: usize,
    pub pages: Vec<Page>,
    pub total_pages: usize,
}
```

---

## 📊 性能指标与优化目标

### 性能基准

| 场景 | 当前实现 | 目标性能 | 优化策略 |
|------|----------|----------|---------|
| **打开书籍** | ~500ms | <300ms | 延迟解析章节列表、增量加载 |
| **首次显示** | ~300ms | <100ms | 增量排版前 3 页、流式传输 |
| **章节内翻页** | ~200ms | <16ms (60fps) | 分页结果缓存、三章缓存 |
| **跨章节翻页** | ~350ms | <50ms | 预加载下一章、异步处理 |
| **内容预处理** | ~50ms | <30ms | 正则缓存、HTML 占位符优化 |
| **文本排版** | ~100ms (10k字) | <50ms | 段落缓存、字形缓存 |
| **分页计算** | ~20ms | <10ms | 增量分页、懒计算 |

### 内存占用目标

```
三章缓存:
  - 当前章: ~50MB (10k字 × 50页)
  - 前一章: ~50MB
  - 下一章: ~20MB (只缓存前2页)
  总计: ~120MB

LRU 缓存:
  - 分页结果: ~50MB (10章 × 5MB)
  - 字形缓存: ~10MB (10k字形)
  - 段落缓存: ~5MB (50段)
  总计: ~65MB

总内存占用: ~185MB (可接受范围: <200MB)
```

### 缓存命中率目标

```
顺序阅读场景（用户从头到尾阅读）:
  - 章节缓存命中率: >95%
  - 分页结果命中率: >90%
  - 字形缓存命中率: >98%

随机跳转场景（用户频繁跳章）:
  - 章节缓存命中率: ~60%
  - 分页结果命中率: ~50%
  - 磁盘缓存命中率: ~80%
```

### 关键性能优化点

#### 1. 零拷贝优化
```rust
// TXT 使用 mmap
let mmap = unsafe { MmapOptions::new().map(&file)? };
let content = std::str::from_utf8(&mmap)?;  // 零拷贝

// 章节内容使用切片引用
let chapter_content = &content[chapter.start_pos..chapter.end_pos];
```

#### 2. 异步并发优化
```rust
// 三章并行排版
tokio::join!(
    load_chapter(current - 1),  // 前一章
    load_chapter(current),      // 当前章
    load_chapter(current + 1),  // 下一章
);
```

#### 3. 增量处理优化
```rust
// 首次只排版前 3 页
let (first_3_pages, remaining_task) = layout_engine.layout_partial(content, 3)?;

// 显示前 3 页
render(first_3_pages);

// 后台继续排版剩余内容
tokio::spawn(remaining_task);
```

#### 4. 智能调度优化
```rust
// 快速翻页时自动取消过期任务
if user_skipped_ahead {
    scheduler.cancel_low_priority(TaskPriority::Normal);
}
```

---

## 🚀 实施路线图

### Phase 1: 核心架构搭建（5-7 天）

#### 任务 1.1: Trait 抽象层（2 天）
- [ ] 定义 `BookParser` trait
- [ ] 定义 `ProcessingStage` trait
- [ ] 定义 `CacheStrategy` trait
- [ ] 定义 `SchedulingPolicy` trait
- [ ] 编写 trait 单元测试

**产出**：完整的 trait 定义和文档

#### 任务 1.2: TXT + EPUB 解析器（3 天）
- [ ] 优化现有 `TxtParser`（支持 mmap）
- [ ] 实现 `EpubParser`（基于 epub crate）
- [ ] 实现 `FormatDetector`
- [ ] 编写解析器测试用例

**产出**：可用的 TXT 和 EPUB 解析器

#### 任务 1.3: 任务调度器（2 天）
- [ ] 实现 `ChapterTaskScheduler`
- [ ] 实现任务优先级管理
- [ ] 实现任务取消机制
- [ ] 编写调度器压力测试

**产出**：完整的任务调度系统

---

### Phase 2: 内容处理流水线（6-8 天）

#### 任务 2.1: 内容预处理器（3 天）
- [ ] 实现 `ContentPreprocessor` 基础功能
- [ ] 实现正则替换（带超时保护）
- [ ] 实现 HTML 占位符保护
- [ ] 集成简繁转换库

**产出**：完整的内容预处理器

#### 任务 2.2: JavaScript 引擎集成（3 天）
- [ ] 集成 rquickjs
- [ ] 实现 JS 沙箱隔离
- [ ] 实现超时保护
- [ ] 注入全局对象（book、chapter 等）
- [ ] 编写 JS 规则测试用例

**产出**：完全兼容 Legado 的 JS 规则引擎

#### 任务 2.3: 流水线整合（2 天）
- [ ] 实现 `ProcessingPipeline`
- [ ] 实现流式处理（Channel）
- [ ] 编写端到端流水线测试

**产出**：完整的内容处理流水线

---

### Phase 3: 缓存与预加载（4-5 天）

#### 任务 3.1: 缓存管理器（2 天）
- [ ] 实现内存 LRU 缓存
- [ ] 实现磁盘缓存（SQLite）
- [ ] 实现缓存统计

**产出**：多级缓存系统

#### 任务 3.2: 预加载策略（2 天）
- [ ] 实现 `DefaultPreloadStrategy`
- [ ] 实现预加载任务调度
- [ ] 编写预加载测试

**产出**：智能预加载系统

#### 任务 3.3: 性能测试（1 天）
- [ ] 缓存命中率测试
- [ ] 内存占用测试
- [ ] 并发压力测试

**产出**：性能测试报告

---

### Phase 4: 统一阅读会话（5-6 天）

#### 任务 4.1: ReadSession 核心（3 天）
- [ ] 实现 `ReadSession` 基础结构
- [ ] 实现三章缓存管理
- [ ] 实现翻页逻辑
- [ ] 实现跳转功能

**产出**：完整的阅读会话管理器

#### 任务 4.2: FFI 桥接（2 天）
- [ ] 实现 FFI 接口（flutter_rust_bridge）
- [ ] 实现类型映射
- [ ] 编写 FFI 测试

**产出**：完整的 FFI 桥接层

#### 任务 4.3: Flutter 集成（1 天）
- [ ] 实现 Dart 服务层
- [ ] 集成 Riverpod 状态管理
- [ ] 编写集成测试

**产出**：可用的 Flutter 集成

---

### Phase 5: 优化与测试（3-4 天）

#### 任务 5.1: 性能优化（2 天）
- [ ] 零拷贝优化
- [ ] 异步并发优化
- [ ] 增量处理优化

#### 任务 5.2: 端到端测试（1 天）
- [ ] 打开书籍测试
- [ ] 连续翻页测试
- [ ] 跳转测试
- [ ] 内存稳定性测试

#### 任务 5.3: 文档完善（1 天）
- [ ] API 文档
- [ ] 架构文档
- [ ] 性能报告

**产出**：完整的测试报告和文档

---

## 📈 预期成果

### 技术指标

```
✅ 高度抽象化：所有核心模块基于 Trait，易于扩展
✅ 统一接口：ReadSession 统一管理所有阅读操作
✅ 高性能：翻页延迟 <16ms，首屏显示 <100ms
✅ 完全兼容：支持 Legado 完整规则语法（含 JS）
✅ 多格式支持：TXT + EPUB（架构支持扩展到 MOBI/PDF）
✅ 智能调度：自动取消过期任务，三章并行处理
✅ 多级缓存：内存 + 磁盘，缓存命中率 >90%
```

### 代码质量

```
✅ 模块化：清晰的分层和职责划分
✅ 可测试：每个模块都有单元测试
✅ 可维护：完善的文档和注释
✅ 可扩展：基于 Trait 的插件化设计
```

---

## 🎯 下一步行动

**立即开始 Phase 1.1**：定义核心 Trait 抽象层

1. 创建 `rust/crates/book_parser/src/traits.rs`
2. 定义 `BookParser` trait
3. 创建 `rust/crates/reader_core/src/processing/mod.rs`
4. 定义 `ProcessingStage` trait
5. 编写 trait 文档和示例

**预计完成时间**：2 天

---

**文档编写日期**：2025-01-XX  
**文档版本**：v1.0  
**作者**：Kiro AI Agent
