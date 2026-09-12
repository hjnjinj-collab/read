//! 探针：打印 EPUB 封面提取结果
use book_parser::{BookParser, EpubParser};
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let path = std::env::args().nth(1).expect("usage: probe_cover <epub>");
    let mut p = EpubParser::from_file(Path::new(&path))?;
    let meta = p.parse()?;
    println!(
        "title={:?} cover_len={:?}",
        meta.title,
        meta.cover_data.as_ref().map(|b| b.len())
    );
    Ok(())
}
