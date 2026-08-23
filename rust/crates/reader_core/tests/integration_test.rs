use reader_core::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Test: 100 replace rules performance benchmark.
///
/// Simulates a real-world scenario with many replacement rules applied
/// to a large chapter content.
#[tokio::test]
async fn test_100_replace_rules_performance() {
    // Generate 100 replace rules
    let rules: Vec<ReplaceRule> = (0..100)
        .map(|i| ReplaceRule {
            pattern: format!("word_{}", i),
            replacement: format!("REPLACED_{}", i),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: true,
        })
        .collect();

    let preprocessor = ContentPreprocessor::new(rules);

    // Generate a large content with some matches
    let mut content = String::new();
    for i in 0..1000 {
        content.push_str(&format!("This is paragraph {} with word_{} and word_{}. ", i, i % 100, (i + 50) % 100));
    }

    let options = ProcessOptions {
        remove_duplicate_title: false,
        adapt_special_style: false,
        ..Default::default()
    };

    let start = Instant::now();
    let result = preprocessor.process(&content, &options).await.unwrap();
    let elapsed = start.elapsed();

    // Verify replacements happened
    assert!(result.contains("REPLACED_0"));
    assert!(result.contains("REPLACED_99"));
    assert!(!result.contains("word_0"));
    assert!(!result.contains("word_99"));

    // Performance assertion: 100 rules on ~50KB content should complete in < 500ms
    println!("100 rules on {} chars: {:?}", content.len(), elapsed);
    assert!(
        elapsed < Duration::from_millis(500),
        "Performance regression: took {:?} (expected < 500ms)",
        elapsed
    );
}

/// Test: Regex rules with timeout protection.
///
/// Verifies that slow/complex regex rules don't block the pipeline.
#[tokio::test]
async fn test_regex_timeout_protection() {
    let rules = vec![
        ReplaceRule {
            // Normal regex that should work fine
            pattern: r"\d{4}-\d{2}-\d{2}".to_string(),
            replacement: "[DATE]".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 5000,
            enabled: true,
        },
        ReplaceRule {
            // This regex might timeout on pathological input
            pattern: r"(a*)*$".to_string(),
            replacement: "X".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 1, // Very short timeout
            enabled: true,
        },
    ];

    let preprocessor = ContentPreprocessor::new(rules);
    let options = ProcessOptions {
        remove_duplicate_title: false,
        adapt_special_style: false,
        ..Default::default()
    };

    // Content with dates and a's that might trigger backtracking
    let content = "Published on 2026-08-17 and 2025-12-31. Also aaaaaaaaaaaaaaaaaaaaaa.";
    let start = Instant::now();
    let result = preprocessor.process(content, &options).await;
    let elapsed = start.elapsed();

    assert!(result.is_ok());
    let result = result.unwrap();
    // Date regex should have been applied
    assert!(result.contains("[DATE]"));
    // Should complete quickly despite the problematic regex
    assert!(
        elapsed < Duration::from_secs(2),
        "Timeout protection failed: took {:?}",
        elapsed
    );
}

/// Test: Concurrent chapter processing.
///
/// Verifies that multiple chapters can be processed concurrently
/// using the ChapterTaskScheduler.
#[tokio::test]
async fn test_concurrent_chapter_processing() {
    let scheduler = ChapterTaskScheduler::new();
    let completed = Arc::new(AtomicUsize::new(0));

    // Create a preprocessor that will be used in each task
    let rules = vec![ReplaceRule {
        pattern: "test".to_string(),
        replacement: "passed".to_string(),
        rule_type: RuleType::String,
        timeout_ms: 1000,
        enabled: true,
    }];

    // Submit 10 concurrent chapter processing tasks
    for chapter_idx in 0..10 {
        let completed = completed.clone();
        let rules = rules.clone();

        scheduler.submit(chapter_idx, async move {
            let preprocessor = ContentPreprocessor::new(rules);
            let options = ProcessOptions {
                remove_duplicate_title: false,
                ..Default::default()
            };

            let content = format!("Chapter {} content with test word.", chapter_idx);
            let result = preprocessor.process(&content, &options).await;
            assert!(result.is_ok());
            assert!(result.unwrap().contains("passed"));
            completed.fetch_add(1, Ordering::SeqCst);
        });
    }

    // Wait for all tasks to complete
    scheduler.wait_all().await;

    assert_eq!(completed.load(Ordering::SeqCst), 10);
    assert_eq!(scheduler.active_count(), 0);
}

/// Test: Task cancellation during processing.
///
/// Verifies that cancelling a running task stops it promptly.
#[tokio::test]
async fn test_task_cancellation() {
    let scheduler = ChapterTaskScheduler::new();
    let completed = Arc::new(AtomicUsize::new(0));

    let c = completed.clone();
    scheduler.submit(0, async move {
        // Simulate long processing
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        c.fetch_add(1, Ordering::SeqCst);
    });

    // Wait a bit for the task to start
    tokio::time::sleep(Duration::from_millis(20)).await;
    assert!(scheduler.is_running(0));

    // Cancel the task
    let start = Instant::now();
    scheduler.cancel(0);

    // Wait for cancellation to propagate
    tokio::time::sleep(Duration::from_millis(50)).await;

    let elapsed = start.elapsed();
    // Task should have been cancelled promptly
    assert_eq!(completed.load(Ordering::SeqCst), 0);
    assert_eq!(scheduler.active_count(), 0);
    assert!(
        elapsed < Duration::from_millis(200),
        "Cancellation took too long: {:?}",
        elapsed
    );
}

/// Test: Full preprocessing pipeline with all stages.
///
/// Exercises the complete pipeline: title removal, re-segment,
/// Chinese conversion, HTML protection, and replace rules.
#[tokio::test]
async fn test_full_pipeline() {
    let rules = vec![
        ReplaceRule {
            pattern: "敏感词".to_string(),
            replacement: "***".to_string(),
            rule_type: RuleType::String,
            timeout_ms: 1000,
            enabled: true,
        },
        ReplaceRule {
            pattern: r"\s+".to_string(),
            replacement: " ".to_string(),
            rule_type: RuleType::Regex,
            timeout_ms: 1000,
            enabled: true,
        },
    ];

    let preprocessor = ContentPreprocessor::new(rules);
    let options = ProcessOptions {
        book_name: "测试书籍".to_string(),
        title: "第一章 测试".to_string(),
        chapter_index: 0,
        remove_duplicate_title: true,
        re_segment: true,
        chinese_convert: Some(ChineseConvertType::S2T),
        adapt_special_style: true,
        apply_user_markings: false,
    };

    let content = "第一章 测试\n\n这是<b>敏感词</b>内容。\n\n这是第二段。";
    let result = preprocessor.process(content, &options).await.unwrap();

    // Title should be removed
    assert!(!result.starts_with("第一章 测试"));
    // HTML tag should be preserved
    assert!(result.contains("<b>"));
    assert!(result.contains("</b>"));
    // Sensitive word should be replaced
    assert!(result.contains("***"));
    assert!(!result.contains("敏感词"));
    // Re-segment should normalize newlines
    assert!(!result.contains("\n\n"));
}

/// Test: Stress test with many concurrent scheduler submissions.
///
/// Rapidly submits and cancels tasks to test thread safety.
#[tokio::test]
async fn test_scheduler_stress() {
    let scheduler = ChapterTaskScheduler::new();
    let completed = Arc::new(AtomicUsize::new(0));

    // Rapidly submit tasks for many chapters
    for i in 0..50 {
        let c = completed.clone();
        scheduler.submit(i, async move {
            tokio::time::sleep(Duration::from_millis(5)).await;
            c.fetch_add(1, Ordering::SeqCst);
        });
    }

    // Cancel half of them immediately
    for i in 0..25 {
        scheduler.cancel(i);
    }

    // Wait for remaining to complete
    scheduler.wait_all().await;

    // At least the non-cancelled ones should have completed
    let count = completed.load(Ordering::SeqCst);
    assert!(count >= 25, "Expected at least 25 completions, got {}", count);
    assert!(count <= 50);
}
