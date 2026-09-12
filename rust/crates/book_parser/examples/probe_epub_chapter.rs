//! 探针：打印 EPUB 指定章节 IR 前几块（标题是否还在）
use book_parser::{BookParser, ContentBlock, EpubParser};
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let path = std::env::args()
        .nth(1)
        .expect("usage: probe_epub_chapter <epub> [chapter_index]");
    let idx: usize = std::env::args()
        .nth(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(4);
    let mut p = EpubParser::from_file(Path::new(&path))?;
    p.parse()?;
    let chapters = p.get_chapter_list()?;
    println!("chapters={}", chapters.len());
    for (i, c) in chapters.iter().take(10).enumerate() {
        println!(
            "[{i}] href={:?} title={:?}",
            c.resource_href.as_deref().unwrap_or(""),
            c.title
        );
    }
    let content = p.get_chapter_content_structured(idx)?;
    println!("--- chapter {idx} blocks (first 15) ---");
    for (i, b) in content.blocks.iter().take(15).enumerate() {
        match b {
            ContentBlock::Paragraph {
                text,
                font_scale,
                is_comment,
                align,
                indent_first_line_em,
                ..
            } => {
                let s: String = text.chars().take(36).collect();
                println!(
                    "[{i}] P scale={font_scale:?} comment={is_comment} align={align:?} indent={indent_first_line_em:?} 「{s}」"
                );
            }
            ContentBlock::Heading {
                text,
                level,
                font_scale,
                align,
                color,
                ..
            } => {
                let s: String = text.chars().take(36).collect();
                println!(
                    "[{i}] H{level} scale={font_scale:?} align={align:?} color={color:?} 「{s}」"
                );
            }
            ContentBlock::Image {
                resource_href,
                hidden,
                ..
            } => {
                println!("[{i}] IMG href={resource_href} hidden={hidden}");
            }
            other => println!("[{i}] other={:?}", std::mem::discriminant(other)),
        }
    }
    println!("background={:?}", content.background);
    Ok(())
}
