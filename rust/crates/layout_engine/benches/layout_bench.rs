use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};
use layout_engine::{LayoutEngine, LayoutConfig, EdgeInsets, FontManager, layout_chapters_parallel};
use std::sync::Arc;

/// 生成测试文本
fn generate_test_text(char_count: usize) -> String {
    "这是一段中文测试文本，用于测试排版引擎的性能。This is English text for testing. ".repeat(char_count / 40)
}

/// 创建测试用的字体管理器
fn create_bench_font_manager() -> FontManager {
    let mut font_manager = FontManager::new();
    
    // 尝试加载系统字体
    let font_paths = vec![
        "C:/Windows/Fonts/simsun.ttc",
        "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
        "C:/Windows/Fonts/arial.ttf",
    ];
    
    for path in font_paths {
        if std::path::Path::new(path).exists() {
            if font_manager.load_font_from_file("BenchFont".to_string(), path).is_ok() {
                println!("基准测试使用字体: {}", path);
                break;
            }
        }
    }
    
    font_manager
}

/// 基准测试：单章节排版
fn bench_single_chapter_layout(c: &mut Criterion) {
    let mut group = c.benchmark_group("single_chapter_layout");
    
    let font_manager = create_bench_font_manager();
    
    let config = LayoutConfig {
        width: 360.0,
        height: 640.0,
        font_size: 18.0,
        line_height_multiplier: 1.5,
        padding: EdgeInsets {
            left: 20.0,
            top: 20.0,
            right: 20.0,
            bottom: 20.0,
        },
        font_name: "BenchFont".to_string(),
        letter_spacing: 0.0,
        paragraph_spacing: 12.0,
        page_fill_threshold: 0.9,
        show_comments: true,
    };
    
    // 测试不同长度的文本
    for size in [1000, 5000, 10000].iter() {
        let text = generate_test_text(*size);
        
        group.bench_with_input(
            BenchmarkId::new("chars", size),
            &text,
            |b, text| {
                let engine = LayoutEngine::new(config.clone(), font_manager.clone());
                b.iter(|| {
                    let _ = engine.layout_text(black_box(text), black_box(0));
                });
            },
        );
    }
    
    group.finish();
}

/// 基准测试：并行排版多章节
fn bench_parallel_layout(c: &mut Criterion) {
    let mut group = c.benchmark_group("parallel_layout");
    
    let font_manager = Arc::new(create_bench_font_manager());
    
    let config = LayoutConfig {
        width: 360.0,
        height: 640.0,
        font_size: 18.0,
        line_height_multiplier: 1.5,
        padding: EdgeInsets {
            left: 20.0,
            top: 20.0,
            right: 20.0,
            bottom: 20.0,
        },
        font_name: "BenchFont".to_string(),
        letter_spacing: 0.0,
        paragraph_spacing: 12.0,
        page_fill_threshold: 0.9,
        show_comments: true,
    };
    
    // 测试不同数量的章节
    for chapter_count in [3, 5, 10].iter() {
        let text = generate_test_text(5000);
        let chapters: Vec<(usize, String)> = (0..*chapter_count)
            .map(|i| (i, text.clone()))
            .collect();
        
        group.bench_with_input(
            BenchmarkId::new("chapters", chapter_count),
            &chapters,
            |b, chapters| {
                b.iter(|| {
                    let _ = layout_chapters_parallel(
                        black_box(chapters.clone()),
                        black_box(config.clone()),
                        black_box(font_manager.clone()),
                    );
                });
            },
        );
    }
    
    group.finish();
}

/// 基准测试：字形缓存性能
fn bench_glyph_cache(c: &mut Criterion) {
    let mut group = c.benchmark_group("glyph_cache");
    
    let font_manager = create_bench_font_manager();
    
    let config = LayoutConfig {
        width: 360.0,
        height: 640.0,
        font_size: 18.0,
        line_height_multiplier: 1.5,
        padding: EdgeInsets {
            left: 20.0,
            top: 20.0,
            right: 20.0,
            bottom: 20.0,
        },
        font_name: "BenchFont".to_string(),
        letter_spacing: 0.0,
        paragraph_spacing: 12.0,
        page_fill_threshold: 0.9,
        show_comments: true,
    };
    
    // 重复字符测试（高缓存命中率）
    let repeated_text = "测试测试测试测试测试".repeat(100);
    
    group.bench_function("high_hit_rate", |b| {
        let engine = LayoutEngine::new(config.clone(), font_manager.clone());
        b.iter(|| {
            let _ = engine.layout_text(black_box(&repeated_text), black_box(0));
        });
    });
    
    // 唯一字符测试（低缓存命中率）
    let unique_chars: String = (0x4E00..0x4E00+500)
        .filter_map(std::char::from_u32)
        .collect();
    
    group.bench_function("low_hit_rate", |b| {
        let engine = LayoutEngine::new(config.clone(), font_manager.clone());
        b.iter(|| {
            let _ = engine.layout_text(black_box(&unique_chars), black_box(0));
        });
    });
    
    group.finish();
}

/// 基准测试：不同字号的排版性能
fn bench_font_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("font_sizes");
    
    let font_manager = create_bench_font_manager();
    let text = generate_test_text(5000);
    
    for font_size in [14.0, 18.0, 22.0, 26.0].iter() {
        let config = LayoutConfig {
            width: 360.0,
            height: 640.0,
            font_size: *font_size,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 20.0,
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
            },
            font_name: "BenchFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
            show_comments: true,
        };
        
        group.bench_with_input(
            BenchmarkId::new("size", font_size),
            font_size,
            |b, _| {
                let engine = LayoutEngine::new(config.clone(), font_manager.clone());
                b.iter(|| {
                    let _ = engine.layout_text(black_box(&text), black_box(0));
                });
            },
        );
    }
    
    group.finish();
}

criterion_group!(
    benches,
    bench_single_chapter_layout,
    bench_parallel_layout,
    bench_glyph_cache,
    bench_font_sizes
);
criterion_main!(benches);
