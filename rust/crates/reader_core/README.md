# Reader Core 使用指南

## 快速开始

`reader_core` 提供了完整的章节内容预处理功能，包括标题提取、内容处理和并发任务调度。

## 模块概览

```rust
use reader_core::{
    // 章节工具
    ChapterInfo,
    extract_chapter_number,
    get_pure_chapter_name,
    
    // 内容预处理
    ContentPreprocessor,
    ProcessOptions,
    ReplaceRule,
    ChineseConvertType,
    
    // 任务调度
    ChapterTaskScheduler,
};
```

---

## 1. 章节信息提取

### 基本用法

```rust
use reader_core::{ChapterInfo, extract_chapter_number, get_pure_chapter_name};

// 方法 1: 使用 ChapterInfo 结构体（推荐）
let info = ChapterInfo::new("第123章 大决战【VIP】".to_string());
println!("章节号: {}", info.chapter_number);    // 123
println!("纯净标题: {}", info.pure_title);      // "大决战"
println!("原标题: {}", info.title);             // "第123章 大决战【VIP】"

// 方法 2: 单独调用函数
let chapter_num = extract_chapter_number("第一百二十三章 终结");
println!("章节号: {}", chapter_num);  // 123

let pure_title = get_pure_chapter_name("001、序章");
println!("纯净标题: {}", pure_title);  // "序章"
```

### 支持的标题格式

```rust
// 数字格式
"第1章 开始"              → 章节号: 1,   纯净标题: "开始"
"第123章 战斗"            → 章节号: 123, 纯净标题: "战斗"
"001、序章"              → 章节号: 1,   纯净标题: "序章"
"042：决战"              → 章节号: 42,  纯净标题: "决战"

// 中文数字格式
"第一章 序幕"             → 章节号: 1,   纯净标题: "序幕"
"第十章 转折"             → 章节号: 10,  纯净标题: "转折"
"第一百二十三章 大战"      → 章节号: 123, 纯净标题: "大战"
"第九千九百九十九章"       → 章节号: 9999

// 带标记的标题（标记会被移除）
"第10章 VIP章节【特别篇】" → 章节号: 10,  纯净标题: "VIP章节"
"第42章 最终决战（上）"    → 章节号: 42,  纯净标题: "最终决战"
```

---

## 2. 内容预处理

### 基本用法

```rust
use reader_core::{ContentPreprocessor, ProcessOptions, ReplaceRule};
use std::sync::Arc;

#[tokio::main]
async fn main() {
    // 创建替换规则
    let rules = vec![
        ReplaceRule {
            pattern: "主角".to_string(),
            replacement: "李明".to_string(),
            is_regex: false,      // 字符串替换
            timeout_ms: 100,
            enabled: true,
        },
        ReplaceRule {
            pattern: r"\s+".to_string(),
            replacement: " ".to_string(),
            is_regex: true,       // 正则替换
            timeout_ms: 100,
            enabled: true,
        },
    ];
    
    // 创建预处理器
    let preprocessor = Arc::new(ContentPreprocessor::new(rules));
    
    // 配置处理选项
    let options = ProcessOptions {
        book_name: "测试书籍".to_string(),
        title: "第一章".to_string(),
        chapter_index: 0,
        remove_duplicate_title: true,  // 去除重复标题
        re_segment: false,             // 重新分段（暂未实现）
        chinese_convert: None,         // 简繁转换（可选）
        adapt_special_style: true,
        apply_user_markings: false,
    };
    
    // 处理内容
    let content = "第一章\n\n主角开始了冒险。主角很强大。";
    let processed = preprocessor.process(content, &options).await.unwrap();
    
    println!("{}", processed);
    // 输出: "李明开始了冒险。李明很强大。"
}
```

### 简繁转换

```rust
use reader_core::ChineseConvertType;

let options = ProcessOptions {
    // ... 其他配置
    chinese_convert: Some(ChineseConvertType::S2T),  // 简体转繁体
    // 或者
    // chinese_convert: Some(ChineseConvertType::T2S),  // 繁体转简体
};
```

### 动态更新规则

```rust
// 运行时更新替换规则
let new_rules = vec![
    ReplaceRule {
        pattern: "旧词".to_string(),
        replacement: "新词".to_string(),
        is_regex: false,
        timeout_ms: 100,
        enabled: true,
    },
];

preprocessor.set_rules(new_rules).await;
```

---

## 3. 并发任务调度

### 基本用法

```rust
use reader_core::ChapterTaskScheduler;
use std::sync::Arc;
use tokio::time::Duration;

#[tokio::main]
async fn main() {
    let scheduler = Arc::new(ChapterTaskScheduler::new());
    
    // 提交章节处理任务
    scheduler.submit(0, async {
        println!("开始处理第 0 章");
        tokio::time::sleep(Duration::from_millis(100)).await;
        println!("完成第 0 章");
    });
    
    scheduler.submit(1, async {
        println!("开始处理第 1 章");
        tokio::time::sleep(Duration::from_millis(100)).await;
        println!("完成第 1 章");
    });
    
    // 等待所有任务完成
    scheduler.wait_all().await;
}
```

### 任务取消

```rust
// 取消特定章节的任务
scheduler.cancel(0);

// 取消所有任务
scheduler.cancel_all();
```

### 快速翻页场景

```rust
// 模拟用户快速翻页
let chapters = vec![0, 1, 2, 5, 10];

for chapter_idx in chapters {
    // 每次提交会自动取消该章节的旧 pending 任务
    scheduler.submit(chapter_idx, async move {
        // 处理章节内容
        process_chapter(chapter_idx).await;
    });
    
    // 模拟用户操作延迟
    tokio::time::sleep(Duration::from_millis(20)).await;
}
```

---

## 4. 完整示例：处理真实书籍

```rust
use reader_core::*;
use std::sync::Arc;

struct Book {
    name: String,
    chapters: Vec<Chapter>,
}

struct Chapter {
    index: usize,
    title: String,
    content: String,
}

#[tokio::main]
async fn main() {
    // 1. 创建预处理器和调度器
    let preprocessor = Arc::new(ContentPreprocessor::empty());
    let scheduler = Arc::new(ChapterTaskScheduler::new());
    
    // 2. 加载书籍数据
    let book = load_book("book_id_123");
    
    // 3. 并发处理所有章节
    let mut handles = vec![];
    
    for chapter in &book.chapters {
        let scheduler = scheduler.clone();
        let preprocessor = preprocessor.clone();
        let chapter = chapter.clone();
        let book_name = book.name.clone();
        
        let handle = tokio::spawn(async move {
            scheduler.submit(chapter.index, async move {
                // 提取章节信息
                let info = ChapterInfo::new(chapter.title.clone());
                println!("处理: {} (章节号: {})", info.pure_title, info.chapter_number);
                
                // 预处理内容
                let options = ProcessOptions {
                    book_name: book_name,
                    title: chapter.title,
                    chapter_index: chapter.index,
                    remove_duplicate_title: true,
                    re_segment: false,
                    chinese_convert: Some(ChineseConvertType::S2T),
                    adapt_special_style: true,
                    apply_user_markings: false,
                };
                
                let processed = preprocessor
                    .process(&chapter.content, &options)
                    .await
                    .unwrap();
                
                // 保存处理后的内容
                save_processed_chapter(chapter.index, &processed);
                
                println!("✓ 完成: {}", info.pure_title);
            });
        });
        
        handles.push(handle);
    }
    
    // 4. 等待所有章节处理完成
    for handle in handles {
        handle.await.unwrap();
    }
    
    println!("所有章节处理完成！");
}

fn load_book(book_id: &str) -> Book {
    // 从数据库或文件加载书籍
    todo!()
}

fn save_processed_chapter(index: usize, content: &str) {
    // 保存到缓存
    todo!()
}
```

---

## 5. 性能优化建议

### 替换规则优化

```rust
// ✅ 好：使用字符串替换（更快）
ReplaceRule {
    pattern: "主角".to_string(),
    replacement: "李明".to_string(),
    is_regex: false,  // 字符串匹配
    timeout_ms: 100,
    enabled: true,
}

// ⚠️ 谨慎：正则表达式（设置合理的超时）
ReplaceRule {
    pattern: r"\s+".to_string(),
    replacement: " ".to_string(),
    is_regex: true,   // 正则匹配
    timeout_ms: 100,  // 防止灾难性回溯
    enabled: true,
}
```

### 批量处理

```rust
// 使用调度器批量提交任务，自动管理并发
for i in 0..100 {
    scheduler.submit(i, async move {
        // 处理章节 i
    });
}

// 调度器会自动：
// - 控制并发数量
// - 取消重复的 pending 任务
// - 清理已完成的任务槽
```

### 内存管理

```rust
// 使用 Arc 共享预处理器实例，避免重复创建
let preprocessor = Arc::new(ContentPreprocessor::new(rules));

// 在多个异步任务中克隆 Arc（仅增加引用计数）
let preprocessor_clone = preprocessor.clone();
```

---

## 6. 错误处理

```rust
use reader_core::ContentProcessError;

match preprocessor.process(content, &options).await {
    Ok(processed) => {
        println!("处理成功: {}", processed);
    }
    Err(ContentProcessError::RegexCompile(msg)) => {
        eprintln!("正则编译失败: {}", msg);
    }
    Err(ContentProcessError::RuleTimeout(ms)) => {
        eprintln!("规则超时: {}ms", ms);
    }
    Err(ContentProcessError::Cancelled) => {
        eprintln!("处理被取消");
    }
    Err(e) => {
        eprintln!("未知错误: {:?}", e);
    }
}
```

---

## 7. 测试

运行所有测试：

```bash
cargo test --package reader_core
```

运行特定测试：

```bash
# 章节工具测试
cargo test --package reader_core --lib chapter_utils

# 管道演示测试
cargo test --package reader_core --test pipeline_demo -- --nocapture
```

---

## 📚 更多资源

- [统一阅读会话设计](../../docs/design/UNIFIED_READ_SESSION_AND_IMPLEMENTATION.md)
- [预处理流水线设计](../../docs/design/DEEP_PREPROCESSING_OPTIMIZATION_TECHNICAL_DOC.md)
- [Bug 修复记录](../../docs/BUG_FIXES.md)
