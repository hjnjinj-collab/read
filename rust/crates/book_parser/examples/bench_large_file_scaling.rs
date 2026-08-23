//! B4：大文件缩放基准——导入 + 首读（A2 统一 JS 识别后，ARCHITECTURE §9.2）
//!
//! 运行：cargo run --release -p book_parser --example bench_large_file_scaling
//!
//! 场景：合成 1/5/20/50MB 中文书籍（章节数按体量缩放），
//! 度量 导入(from_file+parse) 与 首读(get_chapter_content) 墙钟。
//! 预算：耗时随体积近线性增长（无超线性拐点）。

use std::time::Instant;

use book_parser::{BookParser, TxtParser};

/// 生成指定目标字节量的中文书（UTF-8 下中文 3 字节/字）
fn generate_book(target_bytes: usize) -> String {
    let filler = "这一段是章节正文内容，用于撑起每章的真实篇幅与行数，主角不断修炼突破。".repeat(60); // ~4KB
    let chapter_bytes = filler.len() + 60; // 正文 + 标题行
    let chapters = (target_bytes / chapter_bytes).max(2);

    let mut book = String::with_capacity(target_bytes + 4096);
    for i in 0..chapters {
        book.push_str(&format!("第{}章 修炼进阶{}\n", i + 1, i % 7));
        book.push_str(&filler);
        book.push('\n');
    }
    book
}

fn bench_size(size_mb: usize) -> anyhow::Result<(f64, f64, usize)> {
    let target = size_mb * 1024 * 1024;
    let dir = std::env::temp_dir().join(format!("b4_scale_{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("book_{size_mb}mb.txt"));
    let t0 = Instant::now();
    std::fs::write(&path, generate_book(target))?;
    let gen = t0.elapsed().as_secs_f64() * 1000.0;

    // 导入：from_file（含解码 + JS 章节识别）
    let t0 = Instant::now();
    let mut parser = TxtParser::from_file(&path)?;
    let meta = parser.parse()?;
    let import_ms = t0.elapsed().as_secs_f64() * 1000.0;

    // 首读：净化缓存构建（若有净化器）+ 第 1 章切片
    let t0 = Instant::now();
    let ch0 = parser.get_chapter_content(0)?;
    let first_read_ms = t0.elapsed().as_secs_f64() * 1000.0;
    assert!(!ch0.is_empty());

    println!(
        "{:>3}MB | 生成 {:>6.0}ms | 导入 {:>8.1}ms ({:>3} 章) | 首读 {:>7.3}ms",
        size_mb, gen, import_ms, meta.total_chapters, first_read_ms
    );

    std::fs::remove_file(&path).ok();
    let _ = std::fs::remove_dir(&dir);
    Ok((import_ms, first_read_ms, meta.total_chapters))
}

fn main() -> anyhow::Result<()> {
    println!("== B4: 大文件缩放（统一 JS 识别路径）==\n");
    let mut rows = Vec::new();
    for mb in [1usize, 5, 20, 50] {
        rows.push((mb, bench_size(mb)?));
    }

    println!("\n线性度（相对 1MB 的倍数 vs 体积倍数）:");
    let base = rows[0].1 .0;
    for (mb, (import, _, _)) in &rows {
        println!(
            "{:>3}MB: 体积 x{:<3} 导入 x{:.1}",
            mb,
            mb / rows[0].0,
            import / base
        );
    }
    Ok(())
}
