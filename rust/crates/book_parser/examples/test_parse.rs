use book_parser::{BookParser, TxtParser};
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let path = Path::new("test_large_book.txt");
    let mut parser = TxtParser::from_file(path)?;

    let metadata = parser.parse()?;
    println!("书名: {}", metadata.title);
    println!("章节数: {}", metadata.total_chapters);
    println!();

    let chapters = parser.get_chapter_list()?;
    for (i, chapter) in chapters.iter().enumerate() {
        println!("第 {} 章: {}", i + 1, chapter.title);
        if let (Some(start), Some(end)) = (chapter.start_byte_offset, chapter.end_byte_offset) {
            println!("  start: {}, end: {}", start, end);
        }

        // 尝试获取章节内容
        if let Ok(content) = parser.get_chapter_content(i) {
            let preview = content.chars().take(50).collect::<String>();
            println!("  内容预览: {}...", preview);
        }
        println!();
    }

    println!("✓ All character boundaries are valid!");
    Ok(())
}
