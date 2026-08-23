//! B2：多条替换规则扩展性——JS 为主路径，string/regex 为对照组（ARCHITECTURE §9.2）
//!
//! 运行：cargo run --release -p reader_core --features js-engine \
//!       --example bench_rule_scaling
//!
//! 口径（D9）：JS 路径为达标对象；string/regex 仅作对照。
//! 场景：~10KB 章节 × N=1/10/50/200 条规则；每组合 5 轮取 min/avg。
//! 预算：池命中时 JS N=50 <5ms。

use std::time::Instant;

use reader_core::content_preprocessor::{ContentPreprocessor, ProcessOptions, ReplaceRule};

/// ~10KB 章节文本，嵌入 词0..词199 供各条规则实际命中有意义的替换
fn chapter_10kb() -> String {
    let base =
        "主角武圣正在读书写字，他喜欢读书，也喜欢写字。这一段用来填充章节篇幅。".repeat(40);
    let mut content = String::with_capacity(16 * 1024);
    for i in 0..200 {
        content.push_str(&format!("词{i}出现在这里。"));
        content.push_str(&base);
    }
    // 截到 ~10KB（必须落在字符边界上，中文 3 字节/字）
    let mut cut = 10 * 1024;
    while !content.is_char_boundary(cut) {
        cut -= 1;
    }
    content.truncate(cut);
    content
}

fn rules_of(kind: &str, n: usize) -> Vec<ReplaceRule> {
    (0..n)
        .map(|i| match kind {
            "js" => ReplaceRule::js(format!("chapterContent.replace(/词{i}/g, '替{i}')")),
            "string" => ReplaceRule::string(format!("词{i}"), format!("替{i}")),
            _ => ReplaceRule::regex(format!("词{i}"), format!("替{i}")),
        })
        .collect()
}

async fn measure(kind: &str, n: usize, rounds: usize) -> (f64, f64) {
    let pre = ContentPreprocessor::new(rules_of(kind, n));
    let options = ProcessOptions {
        remove_duplicate_title: false,
        adapt_special_style: false,
        ..Default::default()
    };
    // 首轮预热（含池建实例/正则编译），不计入
    let _ = pre.process(&chapter_10kb(), &options).await.unwrap();

    let mut samples = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let content = chapter_10kb();
        let t0 = Instant::now();
        let out = pre.process(&content, &options).await.unwrap();
        let dt = t0.elapsed().as_secs_f64() * 1000.0;
        assert!(!out.is_empty());
        samples.push(dt);
    }
    let avg = samples.iter().sum::<f64>() / samples.len() as f64;
    let min = samples.iter().cloned().fold(f64::MAX, f64::min);
    (min, avg)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("== B2: 多规则扩展性（章节 ~10KB, 每组合 5 轮）==\n");
    println!(
        "{:<8} {:>6} | {:>12} {:>12} | {:>12} {:>12} | {:>12} {:>12}",
        "类型", "N", "js-min", "js-avg", "str-min", "str-avg", "reg-min", "reg-avg"
    );
    println!("{}", "-".repeat(100));

    for n in [1usize, 10, 50, 200] {
        let (j_min, j_avg) = measure("js", n, 5).await;
        let (s_min, s_avg) = measure("string", n, 5).await;
        let (r_min, r_avg) = measure("regex", n, 5).await;
        println!(
            "{:<8} {:>6} | {:>10.3}ms {:>10.3}ms | {:>10.3}ms {:>10.3}ms | {:>10.3}ms {:>10.3}ms",
            "混合", n, j_min, j_avg, s_min, s_avg, r_min, r_avg
        );

        if n == 50 {
            let pass = j_avg < 5.0;
            println!(
                "  >> 预算检查: js-avg @N=50 = {:.3}ms {} (预算 <5ms)",
                j_avg,
                if pass { "[PASS]" } else { "[FAIL]" }
            );
        }
    }

    println!("\n口径说明: js 列为主路径达标对象(D9)；string/regex 为兜底对照。");
    Ok(())
}
