//! B1：嵌套章节规则识别成本（JS 路径，ARCHITECTURE §9.2）
//!
//! 运行：cargo run --release -p book_parser --example bench_nested_chapter_rules
//!
//! 场景：合成 卷50 × 章20（=1000章）× 每章2节 的三层嵌套书，正文 ~1M 字符。
//! 度量：JS 识别墙钟、识别出的层级数量、每百万字符成本。
//! 预算：<300ms / 百万字符（D9 口径：JS 为主路径）。

use std::time::Instant;

use book_parser::chapter_extractor::ChapterExtractor;

/// 合成三层嵌套书籍：卷50 × 章20 × 节2，每章正文 ~1000 字符
fn generate_nested_book() -> String {
    let filler = "这一段是章节正文内容，用于撑起每章的真实篇幅与行数。".repeat(18); // ~500字
    let mut book = String::with_capacity(4 * 1024 * 1024);
    for v in 1..=50 {
        book.push_str(&format!("第{v}卷 风起云涌\n\n"));
        for c in 1..=20 {
            book.push_str(&format!("第{}章 试炼之地{}\n\n", (v - 1) * 20 + c, c));
            for s in 1..=2 {
                book.push_str(&format!("第{s}节 初入秘境\n"));
                book.push_str(&filler);
                book.push_str("\n\n");
            }
        }
    }
    book
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let book = generate_nested_book();
    let chars = book.chars().count() as f64;
    println!(
        "== B1: 嵌套章节规则识别（卷50×章20×节2, {} 章, {:.1}M 字符）==\n",
        50 * 20,
        chars / 1e6
    );

    let extractor = ChapterExtractor::new();

    // 预热（含 JS 引擎首次初始化）
    let warm = extractor.extract_chapters(&book).await?;
    println!(
        "预热轮: 识别 {} 条章节标记（卷+章+节）",
        warm.len()
    );

    let mut samples = Vec::with_capacity(3);
    for i in 0..3 {
        let t0 = Instant::now();
        let chapters = extractor.extract_chapters(&book).await?;
        let dt = t0.elapsed().as_secs_f64() * 1000.0;
        samples.push(dt);

        // 层级分布校验（嵌套规则正确性）
        let volumes = chapters.iter().filter(|c| c.title.starts_with('第') && c.title.contains("卷")).count();
        let sections = chapters.iter().filter(|c| c.title.contains("节 ")).count();
        println!(
            "轮{i}: {:>8.1}ms  识别 {} 条 (卷相关 {volumes}, 节 {sections})",
            dt,
            chapters.len()
        );
    }

    let avg = samples.iter().sum::<f64>() / samples.len() as f64;
    let min = samples.iter().cloned().fold(f64::MAX, f64::min);
    let per_m = avg / (chars / 1e6);
    println!(
        "\n结果: avg {avg:.1}ms / min {min:.1}ms → 每百万字符 {per_m:.1}ms {}（预算 <300ms）",
        if per_m < 300.0 { "[PASS]" } else { "[FAIL]" }
    );
    println!("层级抽样: {:?}", warm.iter().take(3).map(|c| (&c.title, c.level)).collect::<Vec<_>>());
    Ok(())
}
