//! B3：QuickJS 引擎调用成本——冷启动 vs 池化复用（ARCHITECTURE §9.2）
//!
//! 运行：cargo run --release -p reader_core --features js-engine \
//!       --example bench_quickjs_cost
//!
//! 度量：墙钟（每场景 N 轮 avg/min/max）。
//! 预期：池化命中后单次执行应远低于冷启动（冷启动含 Runtime::new ~10–20ms）。

use std::time::Instant;

use reader_core::processing::js_runtime::{JsExecContext, JsRuntime};
use reader_core::processing::js_runtime_pool::global_pool;

const ROUNDS: usize = 30;
/// ~10KB 章节文本（与 B2 同口径）
fn chapter_10kb() -> String {
    "主角武圣正在读书写字，他喜欢读书，也喜欢写字。".repeat(170)
}

fn stats(v: &[f64]) -> (f64, f64, f64) {
    let min = v.iter().cloned().fold(f64::MAX, f64::min);
    let max = v.iter().cloned().fold(0.0, f64::max);
    let avg = v.iter().sum::<f64>() / v.len() as f64;
    (avg, min, max)
}

fn report(name: &str, ms: &[f64]) {
    let (avg, min, max) = stats(ms);
    println!(
        "{:<30} avg {:>9.3}ms   min {:>9.3}ms   max {:>9.3}ms",
        name, avg, min, max
    );
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("== B3: QuickJS 调用成本（脚本: 全文替换一次, 章节 ~10KB, {} 轮）==\n", ROUNDS);

    let content = chapter_10kb();
    let script = "chapterContent.replace(/武圣/g, '李明')";

    // 场景 A：冷启动——每次执行都新建引擎（旧实现的行为）
    let mut cold = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let ctx = JsExecContext {
            chapter_content: content.clone(),
            ..Default::default()
        };
        let t0 = Instant::now();
        let mut rt = JsRuntime::new()?;
        let out = tokio::task::spawn_blocking(move || rt.execute_sync(script, &ctx)).await??;
        let dt = t0.elapsed().as_secs_f64() * 1000.0;
        assert!(!out.is_empty());
        cold.push(dt);
    }
    report("A 冷启动 (Runtime::new/次)", &cold);

    // 场景 B：池化复用——acquire/执行/归还（含池往返）
    let pool = global_pool();
    let mut pooled = Vec::with_capacity(ROUNDS);
    for _ in 0..ROUNDS {
        let ctx = JsExecContext {
            chapter_content: content.clone(),
            ..Default::default()
        };
        let t0 = Instant::now();
        let mut rt = pool.acquire().await?;
        let out = rt.execute(script, &ctx, 1000)?;
        drop(rt);
        let dt = t0.elapsed().as_secs_f64() * 1000.0;
        assert!(!out.is_empty());
        pooled.push(dt);
    }
    report("B 池化复用 (acquire+执行)", &pooled);

    // 场景 C：池化 + 持守卫连续执行（隔离池往返，纯执行+注入成本）
    let mut hot = Vec::with_capacity(ROUNDS);
    let mut rt = pool.acquire().await?;
    for _ in 0..ROUNDS {
        let ctx = JsExecContext {
            chapter_content: content.clone(),
            ..Default::default()
        };
        let t0 = Instant::now();
        let out = rt.execute(script, &ctx, 1000)?;
        let dt = t0.elapsed().as_secs_f64() * 1000.0;
        assert!(!out.is_empty());
        hot.push(dt);
    }
    drop(rt);
    report("C 池化 + 持守卫 (纯执行)", &hot);

    let st = pool.get_stats().await;
    println!(
        "\n池统计: acquisitions={} hits={} misses={} releases={}",
        st.total_acquisitions, st.cache_hits, st.cache_misses, st.total_releases
    );

    let avg = |v: &[f64]| v.iter().sum::<f64>() / v.len() as f64;
    println!(
        "\n结论: 池化/冷启动 = {:.1}x（越大说明池化收益越大）",
        avg(&cold) / avg(&pooled).max(1e-9)
    );
    Ok(())
}
