//! 性能基线测试 v2（S4）
//!
//! 衡量标准：不只看时间，而是"最小 CPU/内存占用下的最佳性能"：
//! - 墙钟时间（用户体验）
//! - CPU 时间（真实计算成本，kernel+user）
//! - CPU/墙钟比（并行效率，越接近 1 越好）
//! - 工作集内存增量（资源代价）
//!
//! 场景：导入(净化 on/off 对比) → 净化缓存构建 → 首读切片 →
//!       内容预处理 → 排版分页 → 设置变更重建 → 锚点定位
//!
//! 运行: cargo run --release --package reader_core --example perf_baseline --features js-engine

use book_parser::{
    BookParser, ContentCleaner, CleanOptions, ConvertMode, ParagraphMode, TxtParser,
};
use layout_engine::{EdgeInsets, FontManager, LayoutConfig, LayoutEngine};
use reader_core::content_preprocessor::{ContentPreprocessor, ProcessOptions};
use std::path::Path;
use std::time::{Duration, Instant};

const BOOK_PATH: &str = r"D:\android\example\legado_flutter\贷款武圣(1-280章).txt";
const FONT_PATHS: &[&str] = &["C:/Windows/Fonts/simsun.ttc", "C:/Windows/Fonts/msyh.ttc"];

// ===== 进程级 CPU / 内存测量（Windows）=====

mod res {
    use windows_sys::Win32::{
        Foundation::FILETIME,
        System::{
            ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
            Threading::{GetCurrentProcess, GetProcessTimes},
        },
    };

    /// 当前进程累计 CPU 时间（100ns 单位，kernel+user）
    pub fn cpu_time_units() -> u64 {
        unsafe {
            let handle = GetCurrentProcess();
            let (mut c, mut e, mut k, mut u) =
                (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
            GetProcessTimes(handle, &mut c, &mut e, &mut k, &mut u);
            let ft = |f: &FILETIME| (f.dwLowDateTime as u64) | ((f.dwHighDateTime as u64) << 32);
            ft(&k) + ft(&u)
        }
    }

    /// 当前工作集大小（字节）
    pub fn working_set_bytes() -> usize {
        unsafe {
            let handle = GetCurrentProcess();
            let mut pmc: PROCESS_MEMORY_COUNTERS = std::mem::zeroed();
            let cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
            if GetProcessMemoryInfo(handle, &mut pmc, cb) != 0 {
                pmc.WorkingSetSize
            } else {
                0
            }
        }
    }
}

fn fmt_dur(d: Duration) -> String {
    let ms = d.as_millis();
    if ms > 0 {
        format!("{}ms", ms)
    } else {
        format!("{}µs", d.as_micros())
    }
}

/// 一组测量的汇总报告
struct Report {
    name: String,
    wall_min: Duration,
    wall_avg: Duration,
    wall_max: Duration,
    cpu_avg: Duration,
    ws_delta_mb: f64,
}

fn report(name: &str, samples: &[(Duration, Duration)]) -> Report {
    // samples: (wall, cpu_delta)
    let wall_min = samples.iter().map(|s| s.0).min().unwrap();
    let wall_max = samples.iter().map(|s| s.0).max().unwrap();
    let wall_sum: Duration = samples.iter().map(|s| s.0).sum();
    let wall_avg = wall_sum / samples.len() as u32;
    let cpu_sum: Duration = samples.iter().map(|s| s.1).sum();
    let cpu_avg = cpu_sum / samples.len() as u32;
    Report {
        name: name.to_string(),
        wall_min,
        wall_avg,
        wall_max,
        cpu_avg,
        ws_delta_mb: 0.0,
    }
}

fn print_report(r: &Report) {
    println!(
        "{:<30} wall min={:>7} avg={:>7} max={:>7} │ cpu avg={:>7}",
        r.name,
        fmt_dur(r.wall_min),
        fmt_dur(r.wall_avg),
        fmt_dur(r.wall_max),
        fmt_dur(r.cpu_avg),
    );
}

/// 测量闭包的 (墙钟, CPU增量)
fn measure<T>(f: impl FnOnce() -> T) -> (T, (Duration, Duration)) {
    let cpu0 = res::cpu_time_units();
    let t0 = Instant::now();
    let out = f();
    let wall = t0.elapsed();
    let cpu_units = res::cpu_time_units().saturating_sub(cpu0);
    (out, (wall, Duration::from_nanos(cpu_units * 100)))
}

fn make_cleaner(smart_paragraph: bool) -> ContentCleaner {
    ContentCleaner::new(
        ConvertMode::None,
        if smart_paragraph { ParagraphMode::Smart } else { ParagraphMode::None },
        CleanOptions { clean_html: true, remove_ads: true, remove_extra_whitespace: true },
    )
}

fn main() -> anyhow::Result<()> {
    println!("=== 性能基线 v2（时间 + CPU + 内存）===");
    println!("书籍: {} ({:.1} MB)", BOOK_PATH, {
        std::fs::metadata(BOOK_PATH)?.len() as f64 / 1024.0 / 1024.0
    });

    // ── 1. 导入：净化 on / off 对比 ──
    let mut off_samples = Vec::new();
    for _ in 0..3 {
        let (_, m) = measure(|| {
            let mut parser = TxtParser::from_file(Path::new(BOOK_PATH)).unwrap();
            parser.parse().unwrap();
        });
        off_samples.push(m);
    }

    let mut on_parser = None;
    let mut on_samples = Vec::new();
    for _ in 0..3 {
        let (p, m) = measure(|| {
            let mut parser = TxtParser::from_file(Path::new(BOOK_PATH)).unwrap();
            parser.set_content_cleaner(make_cleaner(true));
            parser.parse().unwrap();
            parser
        });
        on_parser = Some(p);
        on_samples.push(m);
    }
    print_report(&report("1a. 导入（无净化）", &off_samples));
    print_report(&report("1b. 导入（净化+智能分段）", &on_samples));

    let mut parser = on_parser.unwrap();

    // ── 2. 净化缓存构建（含净化文本上的 JS 章节重识别）──
    let (_, m2) = measure(|| parser.build_cleaned_chapter_cache().unwrap());
    print_report(&report("2. 净化缓存构建", &[m2]));

    let total_chapters = parser.get_chapter_list()?.len();
    println!("{:<30} {}\n", "   章节数", total_chapters);

    // ── 3. 首读章节切片 ×20 ──
    let mut read_samples = Vec::new();
    for idx in 10..30 {
        let (_, m) = measure(|| {
            let c = parser.get_chapter_content_from_cache(idx).unwrap();
            assert!(!c.is_empty());
        });
        read_samples.push(m);
    }
    print_report(&report("3. 章节读取 x20（命中）", &read_samples));

    // ── 4. 内容预处理 ×10 ──
    let preprocessor = ContentPreprocessor::new(vec![]);
    let sample = parser.get_chapter_content_from_cache(5)?;
    let options = ProcessOptions {
        book_name: String::new(),
        title: parser.get_chapter_list()?[5].title.clone(),
        chapter_index: 5,
        remove_duplicate_title: true,
        ..Default::default()
    };
    let rt = tokio::runtime::Runtime::new()?;
    let (mut processed, prep_samples) = rt.block_on(async {
        let mut times = Vec::new();
        let mut out = String::new();
        for _ in 0..10 {
            let cpu0 = res::cpu_time_units();
            let t0 = Instant::now();
            let o = preprocessor.process(&sample, &options).await.unwrap();
            let wall = t0.elapsed();
            let cpu = Duration::from_nanos(res::cpu_time_units().saturating_sub(cpu0) * 100);
            times.push((wall, cpu));
            out = o;
        }
        anyhow::Ok::<(String, Vec<(Duration, Duration)>)>((out, times))
    })?;
    print_report(&report("4. 内容预处理 x10", &prep_samples));

    // ── 5. 排版分页 ×10 ──
    let mut font_manager = FontManager::new();
    let mut font_loaded = false;
    for path in FONT_PATHS {
        if Path::new(path).exists()
            && font_manager.load_font_from_file("BenchFont".to_string(), path).is_ok()
        {
            font_loaded = true;
            break;
        }
    }

    let mut page_count = 0;
    if !font_loaded {
        println!("{:<30} 未找到系统字体，跳过", "5. 排版分页");
    } else {
        let config = LayoutConfig {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets { left: 20.0, top: 20.0, right: 20.0, bottom: 20.0 },
            font_name: "BenchFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
        };
        let engine = LayoutEngine::new(config, font_manager);
        let mut layout_times = Vec::new();
        for _ in 0..10 {
            let (pages, m) = measure(|| engine.layout_text(&processed, 5).unwrap());
            layout_times.push(m);
            page_count = pages.len();

            // ── 6. 锚点定位（二分）×10000，验证开销可忽略 ──
            if page_count > 1 && layout_times.len() == 1 {
                let anchor = pages[page_count / 2].start_char_index;
                let t = Instant::now();
                let mut located = 0;
                for _ in 0..10_000 {
                    located = pages
                        .binary_search_by(|p| p.start_char_index.cmp(&anchor))
                        .unwrap_or_else(|ins| ins.saturating_sub(1));
                }
                let per_op = t.elapsed() / 10_000;
                println!(
                    "{:<30} {:>7}/次   （定位到第{}页）",
                    "6. 锚点定位(二分)", format!("{}ns", per_op.as_nanos()), located + 1
                );
            }
        }
        println!(
            "{:<30} wall min={:>7} avg={:>7} max={:>7}   （该章 {} 页）",
            "5. 排版分页 x10",
            fmt_dur(layout_times.iter().map(|s| s.0).min().unwrap()),
            fmt_dur(layout_times.iter().map(|s| s.0).sum::<Duration>() / layout_times.len() as u32),
            fmt_dur(layout_times.iter().map(|s| s.0).max().unwrap()),
            page_count
        );
    }

    // ── 7. 设置变更重建（模拟运行中修改净化配置）──
    let ws_before = res::working_set_bytes();
    let (_, rebuild_m) = measure(|| {
        parser.set_content_cleaner(make_cleaner(false)); // 切换智能分段开关
        parser.ensure_cleaned_chapter_cache().unwrap();
    });
    let ws_delta = (res::working_set_bytes() as i64 - ws_before as i64) as f64 / 1024.0 / 1024.0;
    println!(
        "{:<30} wall={:>7} cpu={:>7}   ΔWS={:+.1}MB",
        "7. 设置变更→缓存重建",
        fmt_dur(rebuild_m.0),
        fmt_dur(rebuild_m.1),
        ws_delta
    );

    println!("\n=== 指标说明 ===");
    println!("cpu avg = 进程累计 CPU 时间增量(kernel+user)；CPU/墙钟比越高并行利用越好");
    println!("ΔWS     = 工作集内存变化；mmap 大书场景下应接近 0");

    Ok(())
}
