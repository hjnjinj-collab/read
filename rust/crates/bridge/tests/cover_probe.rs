//! 真书封面提取探针（#[ignore]）：EBOOK_PROBE_PATH 指向真实 EPUB
use book_parser::BookParser;

#[test]
#[ignore]
fn real_book_cover_probe() {
    let Ok(path) = std::env::var("EBOOK_PROBE_PATH") else {
        panic!("请设置 EBOOK_PROBE_PATH");
    };
    let mut parser =
        book_parser::EpubParser::from_file(std::path::Path::new(&path)).expect("EPUB 打开失败");
    let meta = parser.parse().expect("EPUB 解析失败");
    match &meta.cover_data {
        Some(bytes) => println!(
            "封面 OK: {} 字节, 头8字节={:02x?}",
            bytes.len(),
            &bytes[..8.min(bytes.len())]
        ),
        None => println!("封面为 None！"),
    }
    println!("cover_data() 访问器: {:?}", parser.cover_data().map(|b| b.len()));
}
