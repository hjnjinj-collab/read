//! M8-P4：结构化排版性能基准（跨章共享 GlyphCache + Arc 缓存验证）
//!
//! 运行：cargo run --release -p bridge --features js-engine \
//!       --example bench_structured
//!
//! 三段计时：
//!   ① 冷布局（首次 layout_items，缓存空）
//!   ② 热命中（同参重复 layout_items，GlyphCache 已预热）
//!   ③ 缓存命中率统计（GlyphCache stats）

use std::time::Instant;

use layout_engine::{
    EdgeInsets, FontManager, GlyphCache, LayoutConfig, LayoutEngine, LayoutItem,
    TextItem,
};

const ROUNDS: usize = 30;
const CHAPTERS: usize = 20;

fn avg(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}

/// 合成一章的 LayoutItem 列表（模拟 EPUB 结构化内容）
fn synthetic_chapter(chapter_index: usize) -> Vec<LayoutItem> {
    let mut items = Vec::new();
    // 章节标题
    items.push(LayoutItem::Text(TextItem {
        text: format!("第{}章 性能基准测试", chapter_index + 1),
        ..Default::default()
    }));
    // 正文段落 × 50（每段 ~200 中文字符）
    let para = "这是结构化排版性能基准的段落内容，用于验证跨章共享字形缓存的加速效果。\
         测试文本覆盖常用中文字符和标点符号，确保缓存命中率有统计意义。\
         每段约两百字以模拟真实 EPUB 章节篇幅。"
        .repeat(4);
    for p in 0..50 {
        items.push(LayoutItem::Text(TextItem {
            text: format!("第{}段 {}", p + 1, para),
            ..Default::default()
        }));
    }
    items
}

fn main() -> anyhow::Result<()> {
    // 加载字体
    let mut font_manager = FontManager::new();
    font_manager.load_font_from_file(
        "BenchFont".into(),
        r"C:\Windows\Fonts\simsun.ttc".into(),
    )?;

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
        paragraph_spacing: 18.0 * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
    };

    // ===== 1. 冷布局（每次新建 GlyphCache） =====
    let mut t_cold = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let gc = GlyphCache::with_capacity(10_000);
        let engine = LayoutEngine::with_cache(config.clone(), font_manager.clone(), gc);
        let items = synthetic_chapter(0);
        let t0 = Instant::now();
        let pages = engine.layout_items(&items, 0)?;
        t_cold.push(t0.elapsed().as_secs_f64() * 1000.0);
        assert!(!pages.is_empty());
    }

    // ===== 2. 热命中（共享 GlyphCache，跨章复用） =====
    let shared_gc = GlyphCache::with_capacity(10_000);
    // 预热：排第一章填充缓存
    {
        let engine =
            LayoutEngine::with_cache(config.clone(), font_manager.clone(), shared_gc.clone());
        let items = synthetic_chapter(0);
        let _ = engine.layout_items(&items, 0)?;
    }

    let mut t_hot = Vec::with_capacity(ROUNDS);
    for r in 0..ROUNDS {
        let ch = r % CHAPTERS;
        let engine =
            LayoutEngine::with_cache(config.clone(), font_manager.clone(), shared_gc.clone());
        let items = synthetic_chapter(ch);
        let t0 = Instant::now();
        let pages = engine.layout_items(&items, ch)?;
        t_hot.push(t0.elapsed().as_secs_f64() * 1000.0);
        assert!(!pages.is_empty());
    }

    // ===== 3. 缓存统计 =====
    let stats = shared_gc.stats();

    // ===== 报告 =====
    println!("== M8-P4: 结构化排版性能基准（{} 轮 × {} 章）==", ROUNDS, CHAPTERS);
    println!();
    println!(
        "{:<28} {:>10} {:>10} {:>10}",
        "阶段", "avg", "min", "max"
    );
    println!(
        "{:<28} {:>8.3}ms {:>8.3}ms {:>8.3}ms",
        "① 冷布局(新建GlyphCache)",
        avg(&t_cold),
        t_cold.iter().cloned().fold(f64::MAX, f64::min),
        t_cold.iter().cloned().fold(0.0, f64::max),
    );
    println!(
        "{:<28} {:>8.3}ms {:>8.3}ms {:>8.3}ms",
        "② 热命中(共享GlyphCache)",
        avg(&t_hot),
        t_hot.iter().cloned().fold(f64::MAX, f64::min),
        t_hot.iter().cloned().fold(0.0, f64::max),
    );
    println!();
    println!("③ GlyphCache 统计:");
    println!("   容量: {}/{}", stats.len, stats.cap);
    println!("   命中: {}  未命中: {}", stats.hits, stats.misses);
    println!("   命中率: {:.1}%", stats.hit_rate);

    let speedup = avg(&t_cold) / avg(&t_hot).max(0.001);
    println!();
    println!("加速比: {:.2}x（热/冷）", speedup);

    Ok(())
}
