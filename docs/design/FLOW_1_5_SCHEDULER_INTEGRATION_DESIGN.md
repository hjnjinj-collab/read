# 流程 1.5: 调度器集成与异步改造 - 技术方案

> **版本**: v1.0  
> **日期**: 2025-01-XX  
> **状态**: 设计阶段  

## 目录

- [1. 方案概述](#1-方案概述)
- [2. 阶段 1: 连接 PreloadExecutor](#2-阶段-1-连接-preloadexecutor)
- [3. 阶段 2: 异步解析改造](#3-阶段-2-异步解析改造)
- [4. 阶段 3: 统一调度层（可选）](#4-阶段-3-统一调度层可选)
- [5. 接口设计清单](#5-接口设计清单)
- [6. 风险与缓解](#6-风险与缓解)
- [7. 测试计划](#7-测试计划)
- [8. 实施时间表](#8-实施时间表)

---

## 1. 方案概述

### 1.1 问题分析

**当前状况**:
```rust
// bridge/api.rs:91 - 同步阻塞调用
pub fn get_chapter_content(book_id: String, chapter_index: usize) -> anyhow::Result<String> {
    let books = BOOKS.lock().unwrap();
    let handle = books.get(&book_id).ok_or_else(|| anyhow::anyhow!("Book not found"))?;
    
    // ❌ 同步调用，大文件会阻塞 FFI 线程
    TxtParser::get_chapter_content(&handle.book, chapter_index)
        .ok_or_else(|| anyhow::anyhow!("Chapter not found"))
}

// bridge/api.rs:1139 - PreloadExecutor 未连接
static PRELOAD_EXECUTOR: Lazy<Arc<PreloadExecutor>> = Lazy::new(|| {
    Arc::new(PreloadExecutor::new(
        PreloadExecutorConfig::default(),
        |_chapter_index| {
            Err(anyhow::anyhow!("需要注入章节加载器")) // ❌ 占位实现
        },
    ))
});

// ❌ ChapterTaskScheduler 完全未使用
// reader_core/src/task_scheduler.rs 已实现但未在任何地方实例化
```

**痛点**:
1. **FFI 线程阻塞**: 10MB+ 文件解析可能耗时数秒，阻塞 Dart 调用
2. **无预加载机制**: 用户切换到下一章时才开始加载，体验延迟
3. **基础设施浪费**: PreloadExecutor 和 ChapterTaskScheduler 已完全实现但未使用

### 1.2 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                          Flutter 层                              │
│  ┌────────────┐  ┌────────────┐  ┌─────────────────┐          │
│  │ 阅读页面    │  │ 预加载控制  │  │ 异步解析 UI    │          │
│  └──────┬─────┘  └──────┬─────┘  └────────┬────────┘          │
└─────────┼────────────────┼──────────────────┼───────────────────┘
          │                │                  │
          │ FFI Call       │ FFI Call         │ FFI Stream
          ▼                ▼                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                      bridge/api.rs (FFI 层)                      │
│  ┌────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │ get_chapter    │  │ preload_chapter │  │ parse_txt_async │ │
│  │ _content()     │  │ ()              │  │ ()              │ │
│  │ [同步保持]     │  │ [新增]          │  │ [新增]          │ │
│  └───────┬────────┘  └────────┬────────┘  └────────┬────────┘ │
└──────────┼──────────────────────┼───────────────────┼──────────┘
           │                      │                   │
           │ 1. 同步返回          │ 2. 提交任务       │ 3. 异步执行
           │                      │                   │
           ▼                      ▼                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                       调度层 (Tokio Runtime)                     │
│  ┌──────────────────────┐         ┌───────────────────────┐    │
│  │ PRELOAD_EXECUTOR     │         │ PARSER_SCHEDULER      │    │
│  │ (PreloadExecutor)    │         │ (ChapterTaskScheduler)│    │
│  │                      │         │                       │    │
│  │ - Worker 池 (2)     │         │ - 按章节槽位管理      │    │
│  │ - 优先级队列        │         │ - 任务取消/替换       │    │
│  │ - 超时控制 (5s)     │         │ - 异步 spawn         │    │
│  │ - 并发限流 (3)      │         │                       │    │
│  └──────────┬───────────┘         └───────────┬───────────┘    │
└─────────────┼─────────────────────────────────┼────────────────┘
              │                                 │
              │ 调用加载器                      │ spawn_blocking
              ▼                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                      业务层 (book_parser)                        │
│  ┌──────────────────────────────────────────────────────┐      │
│  │ TxtParser::get_chapter_content()                     │      │
│  │ - mmap 模式: 流式解码 (大文件)                       │      │
│  │ - 内存模式: 直接切片 (小文件)                        │      │
│  └──────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 数据流

**场景 1: 用户打开第 5 章**
```
1. Flutter 调用 get_chapter_content("book_123", 5)
   ↓
2. FFI 同步返回第 5 章内容 (保持原有行为)
   ↓
3. 后台异步触发预加载:
   - 第 6 章 (High 优先级)
   - 第 7 章 (Low 优先级)
   - 第 4 章 (Normal 优先级)
   ↓
4. PRELOAD_EXECUTOR 调度 worker 执行
   ↓
5. 结果缓存到 BOOKS 或 session cache
```

**场景 2: 用户上传大文件解析**
```
1. Flutter 调用 parse_txt_file_async("path/to/big.txt")
   ↓
2. FFI 立即返回任务 ID (非阻塞)
   ↓
3. PARSER_SCHEDULER 异步执行:
   spawn_blocking {
       TxtParser::parse(file)
   }
   ↓
4. 通过 Stream 返回进度 (0% → 100%)
   ↓
5. 完成后返回 book_id
```

---

## 2. 阶段 1: 连接 PreloadExecutor

**目标**: 让 PreloadExecutor 能够实际加载章节内容

### 2.1 任务 1.1: 实现章节加载闭包

**实施步骤**:

1. **修改 PRELOAD_EXECUTOR 的创建**

```rust
// bridge/api.rs:1139-1147 (修改前)
static PRELOAD_EXECUTOR: Lazy<Arc<PreloadExecutor>> = Lazy::new(|| {
    Arc::new(PreloadExecutor::new(
        PreloadExecutorConfig::default(),
        |_chapter_index| {
            Err(anyhow::anyhow!("需要注入章节加载器"))
        },
    ))
});

// bridge/api.rs (修改后)
static PRELOAD_EXECUTOR: Lazy<Arc<PreloadExecutor>> = Lazy::new(|| {
    Arc::new(PreloadExecutor::new(
        PreloadExecutorConfig::default(),
        |chapter_index| {
            // 从全局上下文获取当前书籍 ID
            let book_id = CURRENT_BOOK_ID.lock().unwrap().clone()
                .ok_or_else(|| anyhow::anyhow!("No book loaded"))?;
            
            // 获取书籍句柄
            let books = BOOKS.lock().unwrap();
            let handle = books.get(&book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found: {}", book_id))?;
            
            // 调用同步加载方法
            TxtParser::get_chapter_content(&handle.book, chapter_index)
                .ok_or_else(|| anyhow::anyhow!("Chapter {} not found", chapter_index))
        },
    ))
});

// 新增：当前书籍 ID 上下文
static CURRENT_BOOK_ID: Lazy<Arc<Mutex<Option<String>>>> = Lazy::new(|| {
    Arc::new(Mutex::new(None))
});
```

**问题**: 闭包捕获的 `book_id` 需要在预加载时传递。

**优化方案**: 修改 PreloadTask 的设计，包含 book_id

```rust
// reader_core/src/scheduler/preload.rs (已有)
pub struct PreloadTask {
    pub chapter_index: usize,
    pub priority: PreloadPriority,
    pub book_id: String,  // ✅ 已经包含 book_id
}
```

**重新设计**: 使用支持 book_id 的加载器

```rust
// bridge/api.rs
static PRELOAD_EXECUTOR: Lazy<Arc<PreloadExecutor>> = Lazy::new(|| {
    Arc::new(PreloadExecutor::new(
        PreloadExecutorConfig::default(),
        |chapter_index| {
            // ❌ 问题: 闭包签名是 Fn(usize) -> Result<String>
            // 但我们需要 book_id
            Err(anyhow::anyhow!("需要修改 PreloadExecutor 设计"))
        },
    ))
});
```

**方案调整**: 修改 PreloadExecutor 的加载器签名

```rust
// reader_core/src/scheduler/preload_executor.rs (需修改)
pub struct PreloadExecutor {
    // ...
}

impl PreloadExecutor {
    // 修改构造函数签名
    pub fn new<F>(config: PreloadExecutorConfig, load_fn: F) -> Self
    where
        F: Fn(&str, usize) -> Result<String> + Send + Sync + 'static,
        //     ^^^^  ^^^^^ chapter_index
        //     book_id
    {
        // ...
    }
}
```

**最终实现**:

```rust
// bridge/api.rs
static PRELOAD_EXECUTOR: Lazy<Arc<PreloadExecutor>> = Lazy::new(|| {
    Arc::new(PreloadExecutor::new(
        PreloadExecutorConfig::default(),
        |book_id, chapter_index| {
            let books = BOOKS.lock().unwrap();
            let handle = books.get(book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found: {}", book_id))?;
            
            TxtParser::get_chapter_content(&handle.book, chapter_index)
                .ok_or_else(|| anyhow::anyhow!("Chapter {} not found", chapter_index))
        },
    ))
});
```

**注意事项**:
- ⚠️ 需要修改 `PreloadExecutor::new` 的签名（breaking change）
- ⚠️ 需要修改 `PreloadTaskMessage` 携带 `book_id`
- ✅ 所有测试需要更新

### 2.2 任务 1.2: 在 get_chapter_content 中触发预加载

**实施步骤**:

```rust
// bridge/api.rs:91 (修改)
pub fn get_chapter_content(book_id: String, chapter_index: usize) -> anyhow::Result<String> {
    // 1. 同步返回当前章节（保持原有行为）
    let content = {
        let books = BOOKS.lock().unwrap();
        let handle = books.get(&book_id)
            .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
        
        TxtParser::get_chapter_content(&handle.book, chapter_index)
            .ok_or_else(|| anyhow::anyhow!("Chapter not found"))?
    };
    
    // 2. 异步触发预加载（非阻塞）
    trigger_preload_async(book_id.clone(), chapter_index);
    
    Ok(content)
}

// 新增：异步触发预加载
fn trigger_preload_async(book_id: String, current_chapter: usize) {
    let executor = PRELOAD_EXECUTOR.clone();
    let book_id_clone = book_id.clone();
    
    tokio::spawn(async move {
        // 获取总章节数
        let total_chapters = {
            let books = BOOKS.lock().unwrap();
            books.get(&book_id_clone)
                .map(|h| h.book.chapters.len())
                .unwrap_or(0)
        };
        
        if total_chapters == 0 {
            return;
        }
        
        // 使用 DefaultPreloadStrategy 计算预加载范围
        let strategy = DefaultPreloadStrategy::default();
        let chapters_to_preload = strategy.calculate_preload_chapters(
            current_chapter,
            total_chapters,
        );
        
        // 提交预加载任务
        for (chapter_index, priority) in chapters_to_preload {
            if chapter_index == current_chapter {
                continue; // 跳过当前章节
            }
            
            let task = PreloadTask {
                chapter_index,
                priority,
                book_id: book_id_clone.clone(),
            };
            
            match executor.submit(task).await {
                Ok(_handle) => {
                    // 可以选择保存 handle 用于取消
                },
                Err(e) => {
                    eprintln!("预加载任务提交失败: {}", e);
                }
            }
        }
    });
}
```

**注意事项**:
- ✅ 不影响原有同步返回逻辑
- ✅ 预加载失败不影响主流程
- ⚠️ 需要 Tokio runtime 支持（flutter_rust_bridge 自动提供）

### 2.3 任务 1.3: 暴露预加载控制 API

**新增 FFI 函数**:

```rust
// bridge/api.rs (新增)

/// 手动触发单章预加载
pub fn preload_chapter(book_id: String, chapter_index: usize) -> anyhow::Result<()> {
    let executor = PRELOAD_EXECUTOR.clone();
    let book_id_clone = book_id.clone();
    
    tokio::spawn(async move {
        let task = PreloadTask {
            chapter_index,
            priority: PreloadPriority::High,
            book_id: book_id_clone,
        };
        
        match executor.submit(task).await {
            Ok(handle) => {
                // 等待完成（可选）
                if let Err(e) = handle.wait().await {
                    eprintln!("预加载失败: {}", e);
                }
            }
            Err(e) => {
                eprintln!("预加载任务提交失败: {}", e);
            }
        }
    });
    
    Ok(())
}

/// 获取预加载统计（已有，直接复用）
pub fn get_preload_stats() -> anyhow::Result<FfiPreloadStats> {
    let stats = PRELOAD_EXECUTOR.stats();
    Ok(FfiPreloadStats {
        total_tasks: stats.total_tasks.load(std::sync::atomic::Ordering::Relaxed),
        completed_tasks: stats.completed_tasks.load(std::sync::atomic::Ordering::Relaxed),
        failed_tasks: stats.failed_tasks.load(std::sync::atomic::Ordering::Relaxed),
        cancelled_tasks: stats.cancelled_tasks.load(std::sync::atomic::Ordering::Relaxed),
    })
}

/// 取消书籍的所有预加载任务
pub fn cancel_preload(book_id: String) -> anyhow::Result<()> {
    // 当前 PreloadExecutor 不支持按 book_id 取消
    // 需要在阶段 3 实现 UnifiedScheduler 时添加
    Ok(())
}

/// 获取预加载队列深度
pub fn get_preload_queue_depth() -> usize {
    PRELOAD_EXECUTOR.stats().queue_depth.load(std::sync::atomic::Ordering::Relaxed)
}
```

**Dart 调用示例**:

```dart
// lib/core/ffi/book_service.dart (新增)

/// 手动预加载指定章节
Future<void> preloadChapter(String bookId, int chapterIndex) async {
  try {
    await api.preloadChapter(bookId: bookId, chapterIndex: chapterIndex);
  } catch (e) {
    debugPrint('预加载失败: $e');
  }
}

/// 获取预加载统计
Future<FfiPreloadStats> getPreloadStats() async {
  return await api.getPreloadStats();
}

/// 取消预加载
Future<void> cancelPreload(String bookId) async {
  await api.cancelPreload(bookId: bookId);
}
```

---

## 3. 阶段 2: 异步解析改造

**目标**: 大文件解析不阻塞 FFI 线程

### 3.1 任务 2.1: 添加异步解析函数

**实施步骤**:

```rust
// bridge/api.rs (新增)

/// 异步解析 TXT 文件
pub async fn parse_txt_file_async(
    file_path: String,
    book_name: Option<String>,
) -> anyhow::Result<String> {
    // 使用 spawn_blocking 避免阻塞 Tokio 运行时
    let book_id = tokio::task::spawn_blocking(move || {
        let file = File::open(&file_path)?;
        let book = TxtParser::parse(file, book_name)?;
        
        let book_id = format!("book_{}", uuid::Uuid::new_v4());
        let mut books = BOOKS.lock().unwrap();
        books.insert(book_id.clone(), BookHandle { book });
        
        Ok::<String, anyhow::Error>(book_id)
    })
    .await
    .map_err(|e| anyhow::anyhow!("Task join error: {}", e))??;
    
    Ok(book_id)
}

/// 带进度回调的异步解析（进阶版本）
pub fn parse_txt_file_with_progress(
    file_path: String,
    book_name: Option<String>,
) -> impl Stream<Item = ParsingProgress> {
    // 返回 Stream 供 Flutter 监听
    async_stream::stream! {
        yield ParsingProgress { stage: "opening_file", progress: 0.0 };
        
        // 打开文件
        let file = match File::open(&file_path) {
            Ok(f) => f,
            Err(e) => {
                yield ParsingProgress { stage: "error", progress: 0.0 };
                return;
            }
        };
        
        yield ParsingProgress { stage: "detecting_encoding", progress: 0.1 };
        
        // 解析（spawn_blocking）
        let book_id = match tokio::task::spawn_blocking(move || {
            let book = TxtParser::parse(file, book_name)?;
            let book_id = format!("book_{}", uuid::Uuid::new_v4());
            let mut books = BOOKS.lock().unwrap();
            books.insert(book_id.clone(), BookHandle { book });
            Ok::<String, anyhow::Error>(book_id)
        }).await {
            Ok(Ok(id)) => id,
            _ => {
                yield ParsingProgress { stage: "error", progress: 0.0 };
                return;
            }
        };
        
        yield ParsingProgress { stage: "completed", progress: 1.0 };
    }
}

#[derive(Debug, Clone)]
pub struct ParsingProgress {
    pub stage: String,
    pub progress: f64,
}
```

**注意事项**:
- ⚠️ `spawn_blocking` 的代价: 创建线程池线程
- ✅ 避免阻塞 Tokio runtime
- ⚠️ Flutter Stream 支持需要 flutter_rust_bridge 2.x

### 3.2 任务 2.2: 使用 ChapterTaskScheduler 管理解析任务

**实施步骤**:

```rust
// bridge/api.rs (新增全局调度器)

/// 全局解析任务调度器
static PARSER_SCHEDULER: Lazy<Arc<ChapterTaskScheduler>> = Lazy::new(|| {
    Arc::new(ChapterTaskScheduler::new())
});

/// 使用调度器管理解析任务
pub async fn parse_txt_file_scheduled(
    file_path: String,
    book_name: Option<String>,
) -> anyhow::Result<String> {
    // 为每个文件分配唯一槽位（基于文件路径哈希）
    let slot_id = calculate_slot_id(&file_path);
    
    let (tx, rx) = oneshot::channel();
    
    // 提交到调度器
    PARSER_SCHEDULER.submit(slot_id, async move {
        let result = tokio::task::spawn_blocking(move || {
            let file = File::open(&file_path)?;
            let book = TxtParser::parse(file, book_name)?;
            let book_id = format!("book_{}", uuid::Uuid::new_v4());
            let mut books = BOOKS.lock().unwrap();
            books.insert(book_id.clone(), BookHandle { book });
            Ok::<String, anyhow::Error>(book_id)
        }).await;
        
        let _ = tx.send(result);
    });
    
    // 等待结果
    rx.await
        .map_err(|_| anyhow::anyhow!("Task cancelled"))??
}

fn calculate_slot_id(file_path: &str) -> usize {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    
    let mut hasher = DefaultHasher::new();
    file_path.hash(&mut hasher);
    hasher.finish() as usize
}

/// 取消正在进行的解析
pub fn cancel_parse_task(file_path: String) -> anyhow::Result<()> {
    let slot_id = calculate_slot_id(&file_path);
    PARSER_SCHEDULER.cancel(slot_id);
    Ok(())
}
```

**优势**:
- ✅ 自动取消重复的解析任务
- ✅ 按文件管理，避免并发冲突
- ✅ 支持取消操作

### 3.3 任务 2.3: 暴露异步 API 到 Flutter

**Flutter FFI 绑定**:

```rust
// rust/crates/bridge/src/api.rs
// flutter_rust_bridge 自动生成 Future 绑定

#[flutter_rust_bridge::frb(sync)]
pub fn parse_txt_file(file_path: String, book_name: Option<String>) -> anyhow::Result<String> {
    // 保留同步版本（向后兼容）
}

pub async fn parse_txt_file_async(
    file_path: String,
    book_name: Option<String>,
) -> anyhow::Result<String> {
    // 新增异步版本
}
```

**Dart 调用**:

```dart
// lib/core/ffi/book_service.dart

/// 同步解析（小文件）
String parseTxtFile(String filePath, String? bookName) {
  return api.parseTxtFile(filePath: filePath, bookName: bookName);
}

/// 异步解析（大文件）
Future<String> parseTxtFileAsync(String filePath, String? bookName) async {
  return await api.parseTxtFileAsync(filePath: filePath, bookName: bookName);
}

/// 带进度的解析
Stream<ParsingProgress> parseTxtFileWithProgress(
  String filePath,
  String? bookName,
) {
  return api.parseTxtFileWithProgress(filePath: filePath, bookName: bookName);
}
```

---

## 4. 阶段 3: 统一调度层（可选）

**目标**: 提供统一的任务管理接口

### 4.1 任务 3.1: 创建 UnifiedScheduler

**设计**:

```rust
// reader_core/src/scheduler/unified.rs (新增)

use super::preload_executor::{PreloadExecutor, PreloadExecutorConfig};
use crate::task_scheduler::ChapterTaskScheduler;
use std::sync::Arc;
use std::collections::HashMap;
use tokio::sync::Mutex;

/// 统一调度器
pub struct UnifiedScheduler {
    /// 预加载执行器
    preload_executor: Arc<PreloadExecutor>,
    
    /// 解析任务调度器
    parser_scheduler: Arc<ChapterTaskScheduler>,
    
    /// 按书籍管理预加载句柄
    preload_handles: Arc<Mutex<HashMap<String, Vec<tokio::task::JoinHandle<()>>>>>,
}

impl UnifiedScheduler {
    pub fn new<F>(preload_config: PreloadExecutorConfig, load_fn: F) -> Self
    where
        F: Fn(&str, usize) -> anyhow::Result<String> + Send + Sync + 'static,
    {
        Self {
            preload_executor: Arc::new(PreloadExecutor::new(preload_config, load_fn)),
            parser_scheduler: Arc::new(ChapterTaskScheduler::new()),
            preload_handles: Arc::new(Mutex::new(HashMap::new())),
        }
    }
    
    /// 提交预加载任务
    pub async fn submit_preload(
        &self,
        book_id: String,
        task: PreloadTask,
    ) -> anyhow::Result<()> {
        let handle = self.preload_executor.submit(task).await?;
        
        let handle_join = tokio::spawn(async move {
            let _ = handle.wait().await;
        });
        
        let mut handles = self.preload_handles.lock().await;
        handles.entry(book_id).or_insert_with(Vec::new).push(handle_join);
        
        Ok(())
    }
    
    /// 取消书籍的所有预加载
    pub async fn cancel_preload(&self, book_id: &str) {
        let mut handles = self.preload_handles.lock().await;
        if let Some(handles_vec) = handles.remove(book_id) {
            for handle in handles_vec {
                handle.abort();
            }
        }
    }
    
    /// 提交解析任务
    pub fn submit_parse<F>(&self, slot_id: usize, task: F)
    where
        F: std::future::Future<Output = ()> + Send + 'static,
    {
        self.parser_scheduler.submit(slot_id, task);
    }
    
    /// 取消解析任务
    pub fn cancel_parse(&self, slot_id: usize) {
        self.parser_scheduler.cancel(slot_id);
    }
    
    /// 获取统计信息
    pub fn stats(&self) -> UnifiedStats {
        UnifiedStats {
            preload_stats: self.preload_executor.stats().clone(),
            active_parse_tasks: self.parser_scheduler.active_count(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct UnifiedStats {
    pub preload_stats: Arc<PreloadStats>,
    pub active_parse_tasks: usize,
}
```

**使用**:

```rust
// bridge/api.rs

static UNIFIED_SCHEDULER: Lazy<Arc<UnifiedScheduler>> = Lazy::new(|| {
    Arc::new(UnifiedScheduler::new(
        PreloadExecutorConfig::default(),
        |book_id, chapter_index| {
            let books = BOOKS.lock().unwrap();
            let handle = books.get(book_id)
                .ok_or_else(|| anyhow::anyhow!("Book not found"))?;
            TxtParser::get_chapter_content(&handle.book, chapter_index)
                .ok_or_else(|| anyhow::anyhow!("Chapter not found"))
        },
    ))
});

pub fn cancel_all_tasks_for_book(book_id: String) -> anyhow::Result<()> {
    tokio::spawn(async move {
        UNIFIED_SCHEDULER.cancel_preload(&book_id).await;
    });
    Ok(())
}
```

---

## 5. 接口设计清单

### 5.1 新增 FFI 函数

| 函数名 | 签名 | 说明 |
|--------|------|------|
| `preload_chapter` | `(book_id: String, chapter_index: usize) -> Result<()>` | 手动触发单章预加载 |
| `get_preload_stats` | `() -> Result<FfiPreloadStats>` | 获取预加载统计 ✅ 已有 |
| `cancel_preload` | `(book_id: String) -> Result<()>` | 取消书籍的所有预加载 |
| `get_preload_queue_depth` | `() -> usize` | 获取队列深度 |
| `parse_txt_file_async` | `async (file_path: String, book_name: Option<String>) -> Result<String>` | 异步解析 TXT |
| `parse_txt_file_scheduled` | `async (file_path: String, book_name: Option<String>) -> Result<String>` | 调度器管理的解析 |
| `cancel_parse_task` | `(file_path: String) -> Result<()>` | 取消解析任务 |

### 5.2 修改的现有函数

| 函数名 | 修改内容 |
|--------|----------|
| `get_chapter_content` | 添加异步预加载触发逻辑 |

### 5.3 Rust 和 Dart 类型映射

```rust
// Rust
pub struct FfiPreloadStats {
    pub total_tasks: usize,
    pub completed_tasks: usize,
    pub failed_tasks: usize,
    pub cancelled_tasks: usize,
}

pub struct ParsingProgress {
    pub stage: String,
    pub progress: f64,
}
```

```dart
// Dart (自动生成)
class FfiPreloadStats {
  final int totalTasks;
  final int completedTasks;
  final int failedTasks;
  final int cancelledTasks;
}

class ParsingProgress {
  final String stage;
  final double progress;
}
```

---

## 6. 风险与缓解

### 6.1 向后兼容性

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 修改 PreloadExecutor 签名 | 破坏现有测试 | 保留旧签名，添加新构造函数 `new_with_book_id` |
| 同步 API 行为变化 | Flutter 层调用失败 | 保持 `get_chapter_content` 同步返回不变 |
| 新增异步 API | 需要 Flutter 适配 | 先实现 Rust 侧，再逐步适配 Flutter |

**缓解方案**:

```rust
// reader_core/src/scheduler/preload_executor.rs

impl PreloadExecutor {
    /// 原有构造函数（向后兼容）
    pub fn new<F>(config: PreloadExecutorConfig, load_fn: F) -> Self
    where
        F: Fn(usize) -> Result<String> + Send + Sync + 'static,
    {
        Self::new_with_book_id(config, move |_book_id, chapter_index| {
            load_fn(chapter_index)
        })
    }
    
    /// 新构造函数（支持 book_id）
    pub fn new_with_book_id<F>(config: PreloadExecutorConfig, load_fn: F) -> Self
    where
        F: Fn(&str, usize) -> Result<String> + Send + Sync + 'static,
    {
        // 实现
    }
}
```

### 6.2 性能影响

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 预加载占用 CPU | 影响主线程响应 | 限制并发数为 3，使用低优先级线程 |
| 异步开销 | spawn_blocking 创建线程 | 仅用于大文件（>10MB） |
| 内存占用增加 | 预加载的章节缓存 | 使用 LRU 缓存，最多缓存 10 章 |

### 6.3 错误处理

| 场景 | 策略 |
|------|------|
| 预加载超时 | 记录失败，不影响主流程 |
| 预加载取消 | 更新统计信息，释放资源 |
| 异步解析异常 | 通过 Result 返回错误到 Flutter |
| 调度器队列满 | 丢弃低优先级任务，返回错误 |

---

## 7. 测试计划

### 7.1 单元测试

```rust
// reader_core/src/scheduler/preload_executor.rs

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn test_preload_with_book_id() {
        let executor = PreloadExecutor::new_with_book_id(
            PreloadExecutorConfig::default(),
            |book_id, chapter_index| {
                Ok(format!("Book: {}, Chapter: {}", book_id, chapter_index))
            },
        );
        
        let task = PreloadTask {
            chapter_index: 5,
            priority: PreloadPriority::High,
            book_id: "test_book".to_string(),
        };
        
        let handle = executor.submit(task).await.unwrap();
        let result = handle.wait().await.unwrap();
        
        assert!(result.success);
        assert!(result.content.unwrap().contains("test_book"));
    }
}
```

### 7.2 集成测试

```rust
// rust/crates/bridge/tests/preload_integration.rs

#[tokio::test]
async fn test_chapter_preload_flow() {
    // 1. 解析书籍
    let book_id = parse_txt_file("test_data/sample.txt".to_string(), None).unwrap();
    
    // 2. 获取第 5 章（触发预加载）
    let content = get_chapter_content(book_id.clone(), 5).unwrap();
    assert!(!content.is_empty());
    
    // 3. 等待预加载完成
    tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
    
    // 4. 验证统计
    let stats = get_preload_stats().unwrap();
    assert!(stats.total_tasks > 0);
}
```

### 7.3 性能测试

```rust
#[tokio::test]
async fn test_large_file_async_parse() {
    let start = std::time::Instant::now();
    
    let book_id = parse_txt_file_async(
        "test_data/large_10mb.txt".to_string(),
        None,
    ).await.unwrap();
    
    let duration = start.elapsed();
    
    assert!(duration.as_secs() < 5, "解析超时");
    assert!(!book_id.is_empty());
}
```

### 7.4 验证清单

- [ ] 预加载不阻塞主流程
- [ ] 异步解析可取消
- [ ] 统计信息准确
- [ ] 内存占用合理（< 100MB 额外）
- [ ] 并发预加载限制生效
- [ ] 超时控制工作
- [ ] 错误传播到 Flutter

---

## 8. 实施时间表

### DAY 1: 阶段 1 - 连接 PreloadExecutor

| 时间 | 任务 | 输出 |
|------|------|------|
| 09:00-10:30 | 修改 PreloadExecutor 签名支持 book_id | `preload_executor.rs` 更新 |
| 10:30-12:00 | 实现章节加载闭包 | `api.rs` PRELOAD_EXECUTOR 连接 |
| 14:00-15:30 | 在 get_chapter_content 触发预加载 | `api.rs` trigger_preload_async |
| 15:30-17:00 | 暴露预加载控制 API | FFI 函数 + 单元测试 |
| 17:00-18:00 | 测试与验证 | 集成测试通过 |

**交付物**:
- [x] PreloadExecutor 支持 book_id
- [x] 预加载自动触发
- [x] FFI 控制 API 可用

### DAY 2: 阶段 2 - 异步解析改造

| 时间 | 任务 | 输出 |
|------|------|------|
| 09:00-10:30 | 实现 parse_txt_file_async | `api.rs` 异步解析函数 |
| 10:30-12:00 | 集成 ChapterTaskScheduler | `api.rs` PARSER_SCHEDULER |
| 14:00-15:30 | Flutter FFI 绑定 | Dart 调用示例 |
| 15:30-17:00 | 性能测试（大文件） | 性能报告 |
| 17:00-18:00 | 文档更新 | 技术方案确认 |

**交付物**:
- [x] 异步解析可用
- [x] 调度器管理解析任务
- [x] Flutter 层适配完成

### DAY 3 (可选): 阶段 3 - 统一调度层

| 时间 | 任务 | 输出 |
|------|------|------|
| 09:00-12:00 | 实现 UnifiedScheduler | `unified.rs` 新增 |
| 14:00-17:00 | 迁移现有调用 | `api.rs` 使用 UNIFIED_SCHEDULER |
| 17:00-18:00 | 完整回归测试 | 测试报告 |

**交付物**:
- [x] UnifiedScheduler 可用
- [x] 所有测试通过

---

## 附录

### A. 依赖关系图

```
PreloadExecutor  ──┐
                    ├──→ UnifiedScheduler ──→ bridge/api.rs ──→ Flutter
ChapterTaskScheduler┘
```

### B. 配置参数

```rust
pub struct PreloadExecutorConfig {
    pub worker_count: usize,        // 默认 2
    pub max_queue_size: usize,      // 默认 100
    pub task_timeout_ms: u64,       // 默认 5000
    pub max_concurrent: usize,      // 默认 3
}

pub struct DefaultPreloadStrategy {
    pub look_ahead: usize,          // 默认 2
    pub look_behind: usize,         // 默认 1
}
```

### C. 关键代码位置

```
rust/crates/
├── reader_core/src/
│   ├── scheduler/
│   │   ├── preload.rs               # 预加载策略
│   │   ├── preload_executor.rs      # 预加载执行器 [需修改]
│   │   ├── unified.rs               # 统一调度器 [新增]
│   │   └── mod.rs                   # 导出
│   └── task_scheduler.rs            # 章节任务调度器
├── bridge/src/
│   └── api.rs                        # FFI 接口 [主要修改]
└── book_parser/src/
    └── txt_parser.rs                 # TXT 解析器
```

---

**版本历史**:
- v1.0 (2025-01-XX): 初始版本
