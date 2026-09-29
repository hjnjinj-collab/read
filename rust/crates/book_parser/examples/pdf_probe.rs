//! 手工探测真实 PDF：cargo run --example pdf_probe -- <path>
use book_parser::pdf_parser::PdfParser;
use book_parser::BookParser;

fn main() {
    let path = std::env::args().nth(1).expect("pdf path");
    match PdfParser::from_file(std::path::Path::new(&path)) {
        Ok(mut parser) => {
            let meta = parser.parse().expect("parse meta");
            println!(
                "OK chapters={} file={} title={}",
                meta.total_chapters, meta.file_size, meta.title
            );
            for (i, ch) in parser.get_chapter_list().unwrap().iter().take(8).enumerate() {
                println!("ch{} title={} words={} range={:?}-{:?}", i, ch.title, ch.estimated_words, ch.start_byte_offset, ch.end_byte_offset);
            }
            // 试提第 0 章文本前 200 字
            match parser.get_chapter_content(0) {
                Ok(t) => {
                    let n = t.chars().count();
                    println!("ch0 chars={}", n);
                    println!("ch0 head={:?}", t.chars().take(200).collect::<String>());
                }
                Err(e) => println!("ch0 text ERR {}", e),
            }
            // 试第 0 页图
            let imgs: Vec<_> = parser.list_page_images(0).collect();
            println!("page0 images={}", imgs.len());
            if let Some(img) = imgs.first() {
                println!("img0 {:?}", img);
                match parser.get_resource(&img.href) {
                    Ok(b) => println!("img0 bytes={}", b.len()),
                    Err(e) => println!("img0 ERR {}", e),
                }
            }
        }
        Err(e) => println!("ERR {}", e),
    }
}
