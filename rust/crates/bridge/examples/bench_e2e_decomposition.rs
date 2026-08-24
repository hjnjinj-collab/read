//! B5：process_and_layout_chapter 缓存 miss 端到端延迟分解（ARCHITECTURE §9.2）
//!
//! 运行：cargo run --release -p bridge --features js-engine \
//!       --example bench_e2e_decomposition
//!
//! 三段计时（与热路径 process_and_layout_chapter 同构）：
//!   ① 取章节内容（get_chapter_content，含净化缓存命中）
//!   ② JS 预处理（ContentPreprocessor::process，空规则集）
//!   ③ 排版分页（LayoutEngine::layout_text）

use std::time::Instant;

use bridge::api;
use layout_engine::{EdgeInsets, LayoutEngine, LayoutConfig};
use reader_core::{ChineseConvertType, ContentPreprocessor, ProcessOptions};

const ROUNDS: usize = 20;

fn avg(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}

fn main() -> anyhow::Result<()> {
    let _ = api::load_font_file("BenchFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());
    // 专用 runtime 仅用于 async 预处理；主线程不在 runtime 内，
    // 使 get_chapter_content 内部的 Handle::try_current() 走「自建 runtime」路径
    // （与 FRB 生产环境线程模型一致）
    let rt = tokio::runtime::Runtime::new()?;

    // 合成 ~5MB / 300 章（与 perf_baseline 主样本同量级）
    let dir = std::env::temp_dir().join(format!("b5_e2e_{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let filler = "这一段是端到端基准的章节正文内容，覆盖真实章节篇幅。".repeat(50);
    let mut book = String::new();
    for i in 0..300 {
        book.push_str(&format!("第{}章 分解计时{}\n{}\n\n", i + 1, i % 11, filler));
    }
    let path = dir.join("book.txt");
    std::fs::write(&path, &book)?;

    let book_id = api::parse_txt_file(path.to_string_lossy().to_string(), None)?;
    let chapter = 150;

    // 预热：首次取内容会构建净化章节缓存（一次性成本，单列报告）
    let t0 = Instant::now();
    let _ = api::get_chapter_content(book_id.clone(), chapter)?;
    let cold_first_fetch = t0.elapsed().as_secs_f64() * 1000.0;

    let config = LayoutConfig {
        width: 360.0,
        height: 640.0,
        font_size: 18.0,
        line_height_multiplier: 1.5,
        padding: EdgeInsets { left: 20.0, top: 20.0, right: 20.0, bottom: 20.0 },
        font_name: "BenchFont".to_string(),
        letter_spacing: 0.0,
        paragraph_spacing: 18.0 * 0.8,
        page_fill_threshold: 0.9,
        show_comments: true,
    };
    let mut font_manager = layout_engine::FontManager::new();
    font_manager
        .load_font_from_file("BenchFont".into(), r"C:\Windows\Fonts\simsun.ttc".into())?;
    let engine = LayoutEngine::new(config, font_manager);
    let pre = ContentPreprocessor::empty();
    let options = ProcessOptions {
        title: String::new(),
        chapter_index: chapter,
        remove_duplicate_title: true,
        chinese_convert: Some(ChineseConvertType::S2T),
        ..Default::default()
    };

    let mut t_fetch = Vec::with_capacity(ROUNDS);
    let mut t_pre = Vec::with_capacity(ROUNDS);
    let mut t_layout = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let t0 = Instant::now();
        let content = api::get_chapter_content(book_id.clone(), chapter)?;
        t_fetch.push(t0.elapsed().as_secs_f64() * 1000.0);

        let t0 = Instant::now();
        let processed = rt.block_on(pre.process(&content, &options))?;
        t_pre.push(t0.elapsed().as_secs_f64() * 1000.0);

        let t0 = Instant::now();
        let pages = engine.layout_text(&processed, chapter)?;
        t_layout.push(t0.elapsed().as_secs_f64() * 1000.0);
        assert!(!pages.is_empty());
    }

    println!("== B5: 缓存 miss 端到端分解（{} 章, {} 轮）==", 300, ROUNDS);
    println!("净化缓存首次构建（一次性）: {:.1}ms", cold_first_fetch);
    println!(
        "{:<28} {:>10} {:>10} {:>10}",
        "阶段", "avg", "min", "max"
    );
    for (name, v) in [
        ("① 取章节内容", &t_fetch),
        ("② JS 预处理(简繁+去重标题)", &t_pre),
        ("③ 排版分页", &t_layout),
    ] {
        println!(
            "{:<28} {:>8.3}ms {:>8.3}ms {:>8.3}ms",
            name,
            avg(v),
            v.iter().cloned().fold(f64::MAX, f64::min),
            v.iter().cloned().fold(0.0, f64::max)
        );
    }
    let total = avg(&t_fetch) + avg(&t_pre) + avg(&t_layout);
    println!("{:<28} {:>8.3}ms", "合计(avg)", total);
    println!(
        "\n占比: 取内容 {:.0}% | JS 预处理 {:.0}% | 排版 {:.0}%",
        avg(&t_fetch) / total * 100.0,
        avg(&t_pre) / total * 100.0,
        avg(&t_layout) / total * 100.0
    );

    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}
