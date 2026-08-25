//! M9.1-P0 诊断探针：《剑来》真书第二章「正文截断 + 尾部灰字重复」根因定位
//!
//! 两路 dump：
//! 1. IR 层（EpubParser 直连）：块级 is_comment / font_scale / 重复检测
//! 2. 生产路径（FFI get_page_structured）：首页 entries 的 comment/样式
//!
//! 运行：cargo test --package bridge --test jianlai_ch2_probe -- --ignored --nocapture
//! 路径可用 JIANLAI_PROBE_PATH 覆盖。

use bridge::api::*;
use book_parser::BookParser;

fn probe_path() -> String {
    std::env::var("JIANLAI_PROBE_PATH")
        .unwrap_or_else(|_| "C:\\Users\\25644\\Desktop\\剑来 (烽火戏诸侯) (Z-Library).epub".to_string())
}

#[test]
#[ignore]
fn jianlai_ch2_duplication_probe() {
    let path = probe_path();

    // ===== 第 1 部分：IR 层 dump =====
    let mut parser = book_parser::EpubParser::from_file(std::path::Path::new(&path))
        .expect("EPUB 打开失败");
    parser.parse().expect("EPUB 解析失败");
    let chapters = parser.get_chapter_list().expect("章节表");

    let ch_idx = chapters
        .iter()
        .position(|c| {
            c.resource_href
                .as_deref()
                .map_or(false, |h| h.contains("chapter-2.xhtml"))
        })
        .expect("找不到 chapter-2.xhtml");
    println!("=== chapter-2.xhtml 章节索引: {} / 共 {} 章 ===", ch_idx, chapters.len());

    let content = parser
        .get_chapter_content_structured(ch_idx)
        .expect("IR 提取失败");
    println!("IR 总块数: {}", content.blocks.len());

    let mut para_texts: Vec<(usize, String)> = Vec::new();
    for (i, block) in content.blocks.iter().enumerate() {
        match block {
            book_parser::ContentBlock::Paragraph {
                text,
                is_comment,
                font_scale,
                indent_first_line_em,
                ..
            } => {
                println!(
                    "IR[{:_>3}] PARA comment={} scale={:?} indent={:?} len={} 「{}」",
                    i,
                    is_comment,
                    font_scale,
                    indent_first_line_em,
                    text.chars().count(),
                    text.chars().take(40).collect::<String>()
                );
                if !text.trim().is_empty() {
                    para_texts.push((i, text.clone()));
                }
            }
            book_parser::ContentBlock::Heading {
                level, text, font_scale, ..
            } => {
                println!(
                    "IR[{:_>3}] H{}    scale={:?} 「{}」",
                    i,
                    level,
                    font_scale,
                    text.chars().take(40).collect::<String>()
                );
            }
            book_parser::ContentBlock::Image { resource_href, .. } => {
                println!("IR[{:_>3}] IMG   {}", i, resource_href);
            }
            _ => println!("IR[{:_>3}] 其他块", i),
        }
    }

    // 重复检测器：长文本包含短文本（≥10 字才参与，防误报）——永久断言
    println!("=== 重复检测（子串关系） ===");
    for (ia, ta) in &para_texts {
        for (ib, tb) in &para_texts {
            let (la, lb) = (ta.chars().count(), tb.chars().count());
            if ia != ib && la > lb && lb >= 10 {
                assert!(
                    !ta.contains(tb.as_str()),
                    "IR 块 {} 文本是块 {} 文本的子串（内容重复）",
                    ib,
                    ia
                );
            }
        }
    }
    println!("IR 层无子串重复");

    // 意外注释检测（永久断言：本书无 aside/footnote、无小字号 CSS，
    // 任何 is_comment 块均为误标）
    let comments: Vec<(usize, String)> = content
        .blocks
        .iter()
        .enumerate()
        .filter_map(|(i, b)| match b {
            book_parser::ContentBlock::Paragraph {
                is_comment: true,
                text,
                ..
            } => Some((i, text.clone())),
            _ => None,
        })
        .collect();
    assert!(
        comments.is_empty(),
        "IR 层出现意外 is_comment 块（本章说误标）: {:?}",
        comments
            .iter()
            .map(|(i, t)| (i, t.chars().take(30).collect::<String>()))
            .collect::<Vec<_>>()
    );
    println!("IR 层无 is_comment 块");

    // 目标段落完整性：段落15（暮色里…）
    println!("=== 目标段落检查 ===");
    const TARGET_HEAD: &str = "暮色里，小镇名叫泥瓶巷";
    const TARGET_TAIL: &str = "人间蛇虫无处藏。";
    for (i, t) in &para_texts {
        if t.contains(TARGET_HEAD) || t.contains("念念有词") {
            let complete = t.contains(TARGET_HEAD) && t.contains(TARGET_TAIL);
            println!(
                "IR[{}] len={} 首尾完整={} 「{}…{}」",
                i,
                t.chars().count(),
                complete,
                t.chars().take(20).collect::<String>(),
                t.chars().rev().take(16).collect::<String>().chars().rev().collect::<String>()
            );
        }
    }

    drop(parser);

    // ===== 第 2 部分：生产路径布局 dump =====
    let _ = load_font_file("TestFont".into(), r"C:\Windows\Fonts\simsun.ttc".into());
    let book_id = parse_txt_file(path.clone(), None).expect("导入失败");
    let count = get_page_count_structured(
        book_id.clone(),
        ch_idx,
        400.0,
        800.0,
        18.0,
        1.5,
        20.0,
        20.0,
        20.0,
        20.0,
        "TestFont".to_string(),
        0,
        0.9,
        true,
        0,
    )
    .expect("分页计数失败");
    println!("=== 生产路径：第 {} 章共 {} 页 ===", ch_idx, count);

    for pi in 0..count.min(2) {
        let page = get_page_structured(
            book_id.clone(),
            ch_idx,
            pi,
            400.0,
            800.0,
            18.0,
            1.5,
            20.0,
            20.0,
            20.0,
            20.0,
            "TestFont".to_string(),
            None,
            0,
            0.9,
            true,
            0,
        )
        .expect("取页失败");
        println!("--- Page {} ({} entries) ---", pi, page.entries.len());
        for e in &page.entries {
            match &e.text {
                Some(t) if !t.is_empty() => {
                    // 永久断言：无本章说误标行
                    assert!(!e.is_comment, "布局层出现 is_comment 行: 「{}」", t);
                    // 永久断言：无超宽行（超宽会触发 Dart 端缩字兜底，
                    // 表现为"小字行"——即用户截图中的灰字现象根源）
                    let n = t.chars().count() as f32;
                    assert!(
                        n * 18.0 <= 360.0 * 1.02,
                        "布局行超宽（{} 字符）: 「{}」",
                        t.chars().count(),
                        t
                    );
                    println!(
                        "   y={:6.1} comment={} scale={:?} color={:?} 「{}」",
                        e.y,
                        e.is_comment,
                        e.font_scale,
                        e.color,
                        t.chars().take(44).collect::<String>()
                    );
                }
                _ => println!("   y={:6.1} [图/线框] href={:?}", e.y, e.resource_href),
            }
        }
    }
}
