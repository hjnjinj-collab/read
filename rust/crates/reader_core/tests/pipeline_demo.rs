use reader_core::{
    ChapterInfo, ChapterTaskScheduler, ChineseConvertType, ContentPreprocessor, ProcessOptions,
    ReplaceRule, RuleType,
};
use std::sync::Arc;
use std::time::Instant;
use tokio::time::Duration;

/// Simulated book with chapters
struct Book {
    name: String,
    author: String,
    chapters: Vec<Chapter>,
}

#[derive(Clone)]
struct Chapter {
    index: usize,
    title: String,
    content: String,
}

impl Chapter {
    fn new(index: usize, title: &str, content: &str) -> Self {
        Self {
            index,
            title: title.to_string(),
            content: content.to_string(),
        }
    }
}

/// Create a sample book for testing
fn create_sample_book() -> Book {
    Book {
        name: "测试小说".to_string(),
        author: "测试作者".to_string(),
        chapters: vec![
            Chapter::new(
                0,
                "第一章 开始",
                "第一章 开始\n\n  这是第一章的内容。\n\n  主角开始了冒险。\n\n  这是一个很长的段落。",
            ),
            Chapter::new(
                1,
                "第二章 冒险",
                "第二章 冒险\n\n  主角开始了他的冒险之旅。\n\n  他变得更强了。\n\n  前方的路充满了未知和危险。",
            ),
            Chapter::new(
                2,
                "第三章 战斗",
                "第三章 战斗\n\n  激烈的战斗开始了。\n\n  主角迎敌而上。\n\n  火光四溅，剑气纵横。",
            ),
        ],
    }
}

/// Test: Extract chapter information
#[test]
fn test_chapter_info_extraction() {
    println!("\n=== 测试章节信息提取 ===\n");

    let titles = vec![
        "第一章 开始",
        "第123章 大决战",
        "001、序章",
        "第一百二十三章 终结【VIP】",
    ];

    for title in titles {
        let info = ChapterInfo::new(title.to_string());
        println!(
            "原标题: {:20} | 章节号: {:3} | 纯净标题: {}",
            info.title, info.chapter_number, info.pure_title
        );
    }
}

/// Test: Content preprocessing pipeline
#[tokio::test]
async fn test_content_preprocessing() {
    println!("\n=== 测试内容预处理管道 ===\n");

    // Create preprocessor with replace rules
    let rules = vec![
        ReplaceRule {
            pattern: "主角".to_string(),
            replacement: "李明".to_string(),
            rule_type: RuleType::String,
            timeout_ms: 100,
            enabled: true,
        },
    ];
    
    let preprocessor = Arc::new(ContentPreprocessor::new(rules));

    let content = "  这是测试内容。  \n\n  主角说话了。  \n\n  主角很强大。  ";

    let options = ProcessOptions {
        book_name: "测试书籍".to_string(),
        title: "第一章".to_string(),
        chapter_index: 0,
        remove_duplicate_title: true,
        re_segment: false,
        chinese_convert: None,
        adapt_special_style: true,
        apply_user_markings: false,
    };

    println!("原始内容:\n{}\n", content);

    let start = Instant::now();
    let processed = preprocessor.process(content, &options).await.unwrap();
    let elapsed = start.elapsed();

    println!("处理后内容:\n{}\n", processed);
    println!("处理耗时: {:?}", elapsed);
}

/// Test: Concurrent chapter processing with scheduler
#[tokio::test]
async fn test_concurrent_chapter_processing() {
    println!("\n=== 测试并发章节处理 ===\n");

    let book = create_sample_book();
    let scheduler = Arc::new(ChapterTaskScheduler::new());
    let preprocessor = Arc::new(ContentPreprocessor::empty());

    println!("书籍: {}", book.name);
    println!("作者: {}", book.author);
    println!("章节数: {}\n", book.chapters.len());

    let start = Instant::now();

    // Submit all chapters for processing
    let mut handles = vec![];

    for chapter in &book.chapters {
        let scheduler = scheduler.clone();
        let preprocessor = preprocessor.clone();
        let chapter = chapter.clone();
        let book_name = book.name.clone();

        let handle = tokio::spawn(async move {
            scheduler.submit(chapter.index, async move {
                // Simulate processing time
                tokio::time::sleep(Duration::from_millis(50)).await;

                let options = ProcessOptions {
                    book_name: book_name.clone(),
                    title: chapter.title.clone(),
                    chapter_index: chapter.index,
                    remove_duplicate_title: true,
                    re_segment: false,
                    chinese_convert: Some(ChineseConvertType::S2T),
                    adapt_special_style: true,
                    apply_user_markings: false,
                };

                let _processed = preprocessor
                    .process(&chapter.content, &options)
                    .await
                    .unwrap();

                let info = ChapterInfo::new(chapter.title.clone());

                println!(
                    "✓ 处理完成: {} (章节号: {}, 纯净标题: {})",
                    chapter.title, info.chapter_number, info.pure_title
                );
            });
        });

        handles.push(handle);
    }

    // Wait for all to complete
    for handle in handles {
        handle.await.unwrap();
    }

    let elapsed = start.elapsed();
    println!("\n总耗时: {:?}", elapsed);
    println!("平均每章: {:?}", elapsed / book.chapters.len() as u32);
}

/// Test: Rapid chapter switching (simulate user flipping pages quickly)
#[tokio::test]
async fn test_rapid_chapter_switching() {
    println!("\n=== 测试快速翻页场景 ===\n");

    let scheduler = Arc::new(ChapterTaskScheduler::new());
    let preprocessor = Arc::new(ContentPreprocessor::empty());

    // Simulate user rapidly switching chapters: 0 -> 1 -> 2 -> 5 -> 10
    let chapter_sequence = vec![0, 1, 2, 5, 10];

    println!("模拟用户快速翻页: {:?}\n", chapter_sequence);

    for &chapter_idx in &chapter_sequence {
        let scheduler = scheduler.clone();
        let preprocessor = preprocessor.clone();

        // Submit task (will cancel previous pending task for same chapter)
        scheduler.submit(chapter_idx, async move {
            println!("→ 开始处理章节 {}", chapter_idx);

            // Simulate processing
            tokio::time::sleep(Duration::from_millis(100)).await;

            let content = format!("第{}章的内容", chapter_idx + 1);
            let options = ProcessOptions {
                book_name: "测试书籍".to_string(),
                title: format!("第{}章", chapter_idx + 1),
                chapter_index: chapter_idx,
                remove_duplicate_title: true,
                re_segment: false,
                chinese_convert: None,
                adapt_special_style: true,
                apply_user_markings: false,
            };

            let _processed = preprocessor.process(&content, &options).await.unwrap();

            println!("✓ 完成章节 {}", chapter_idx);
        });

        // Small delay to simulate user action
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    // Wait for all tasks to settle
    tokio::time::sleep(Duration::from_millis(500)).await;

    println!("\n所有任务已完成");
}

/// Performance benchmark: Process 100 chapters
#[tokio::test]
async fn test_performance_benchmark() {
    println!("\n=== 性能基准测试：100章并发处理 ===\n");

    let scheduler = Arc::new(ChapterTaskScheduler::new());
    let preprocessor = Arc::new(ContentPreprocessor::empty());

    let num_chapters = 100;
    let start = Instant::now();

    let mut handles = vec![];

    for i in 0..num_chapters {
        let scheduler = scheduler.clone();
        let preprocessor = preprocessor.clone();

        let handle = tokio::spawn(async move {
            scheduler.submit(i, async move {
                let content = format!(
                    "第{}章 标题\n\n这是第{}章的内容。包含一些文本用于测试。",
                    i + 1,
                    i + 1
                );

                let options = ProcessOptions {
                    book_name: "性能测试书籍".to_string(),
                    title: format!("第{}章", i + 1),
                    chapter_index: i,
                    remove_duplicate_title: true,
                    re_segment: false,
                    chinese_convert: None,
                    adapt_special_style: true,
                    apply_user_markings: false,
                };

                let _processed = preprocessor.process(&content, &options).await.unwrap();
            });
        });

        handles.push(handle);
    }

    // Wait for all
    for handle in handles {
        handle.await.unwrap();
    }

    let elapsed = start.elapsed();

    println!("处理 {} 章耗时: {:?}", num_chapters, elapsed);
    println!("平均每章: {:?}", elapsed / num_chapters as u32);
    println!(
        "吞吐量: {:.0} 章/秒",
        num_chapters as f64 / elapsed.as_secs_f64()
    );
}
