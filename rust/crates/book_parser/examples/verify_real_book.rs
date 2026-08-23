use book_parser::{BookParser, CleanOptions, ContentCleaner, ConvertMode, ParagraphMode, TxtParser};
use std::path::Path;

fn main() {
    let path = Path::new(r"D:\android\example\legado_flutter\贷款武圣(1-280章).txt");

    println!("=== 端到端验证：真实书籍文件（导入级净化开启）===\n");

    // 1. 解析书籍（镜像应用默认净化配置：去HTML/去广告/智能分段）
    let mut parser = TxtParser::from_file(path).expect("解析失败");
    parser.set_content_cleaner(ContentCleaner::new(
        ConvertMode::None,
        ParagraphMode::Smart,
        CleanOptions { clean_html: true, remove_ads: true, remove_extra_whitespace: true },
    ));
    let metadata = parser.parse().expect("parse 失败");
    println!("书名: {}", metadata.title);
    println!("章节数: {}", metadata.total_chapters);

    // 2. 构建净化缓存（ensure 路径：缺失或配置变更时自动重建）
    parser
        .ensure_cleaned_chapter_cache()
        .expect("构建净化缓存失败");
    println!("净化缓存已构建\n");

    let mut all_pass = true;

    // 3. 净化效果断言：广告行消失、缩进规整
    println!("=== 净化效果检查 ===");
    let ch1 = parser.get_chapter_content_from_cache(0).unwrap();
    let has_ads = ch1.contains("得奇") || ch1.contains("www.") || ch1.contains("请记住本站");
    println!(
        "第1章含广告痕迹(来源站/URL/收藏提示): {}",
        if has_ads { "❌ 是" } else { "✅ 否" }
    );
    if has_ads {
        all_pass = false;
    }

    let indented_lines = ch1
        .lines()
        .filter(|l| l.starts_with('\u{3000}') || l.starts_with("  "))
        .count();
    println!(
        "第1章保留全角/空格缩进行: {}",
        if indented_lines > 0 { format!("❌ {} 行", indented_lines) } else { "✅ 无".to_string() }
    );
    if indented_lines > 0 {
        all_pass = false;
    }
    println!();

    // 4. 检查前5章内容开头是否包含重复标题
    println!("=== 章节内容检查 ===");
    for idx in 0..5 {
        let content = parser
            .get_chapter_content_from_cache(idx)
            .expect("读取章节失败");

        let title = {
            let chapters = parser.get_chapter_list().unwrap();
            chapters[idx].title.clone()
        };

        let first_lines: Vec<String> = content
            .lines()
            .take(3)
            .map(|l| l.trim_start_matches(['\u{3000}', ' ']).to_string())
            .collect();

        let starts_with_title = first_lines
            .iter()
            .take(2)
            .any(|l| l == title.trim());

        let status = if starts_with_title { "❌ 含重复标题" } else { "✅ 无重复标题" };
        if starts_with_title {
            all_pass = false;
        }

        println!("第{}章 '{}' {}", idx + 1, title, status);
        for (i, line) in first_lines.iter().enumerate() {
            let preview: String = line.chars().take(30).collect();
            println!("  行{}: {}", i + 1, preview);
        }
        println!();
    }

    // 5. 验证章节内容不包含上一章/下一章内容
    let ch2 = parser.get_chapter_content_from_cache(1).unwrap();
    let ch3 = parser.get_chapter_content_from_cache(2).unwrap();
    let ch2_title = parser.get_chapter_list().unwrap()[1].title.clone();
    let ch3_title = parser.get_chapter_list().unwrap()[2].title.clone();

    let ch2_contains_ch3_title = ch2.contains(&ch3_title);
    let ch3_contains_ch2_title = ch3.contains(&ch2_title);

    println!("=== 章节边界检查 ===");
    println!(
        "第2章包含第3章标题: {}",
        if ch2_contains_ch3_title { "❌ 是" } else { "✅ 否" }
    );
    println!(
        "第3章包含第2章标题: {}",
        if ch3_contains_ch2_title { "❌ 是" } else { "✅ 否" }
    );

    if all_pass && !ch2_contains_ch3_title && !ch3_contains_ch2_title {
        println!("\n🎉 端到端验证全部通过！");
    } else {
        println!("\n❌ 存在问题，需要进一步排查");
        std::process::exit(1);
    }
}
