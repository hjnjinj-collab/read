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
            // 多页抽样：滤镜 + 解码结果
            for p in [0usize, 1, 2, 10, 11, 20, 50, 100] {
                if p >= meta.total_chapters * 50 && p > 20 {
                    // 页数粗估；实际用 list 判空
                }
                let list: Vec<_> = parser.list_page_images(p).collect();
                if list.is_empty() {
                    println!("p{} no images", p);
                    continue;
                }
                for img in list.iter().take(1) {
                    println!(
                        "p{} {} meta={}x{}",
                        p, img.href, img.width, img.height
                    );
                    println!("  info {}", parser.debug_image_filters(p, 0));
                    match parser.extract_page_image(p, 0) {
                        Ok(b) => {
                            let jpeg = b.starts_with(&[0xFF, 0xD8]);
                            let png = b.starts_with(&[0x89, b'P']);
                            let head: Vec<String> =
                                b.iter().take(8).map(|x| format!("{:02x}", x)).collect();
                            println!(
                                "  extract bytes={} jpeg={} png={} head={}",
                                b.len(),
                                jpeg,
                                png,
                                head.join(" ")
                            );
                            // 导出供目视检查
                            let out = format!("pdf_probe_p{p}.bin");
                            std::fs::write(&out, &b).ok();
                            println!("  wrote {out}");
                        }
                        Err(e) => println!("  extract ERR {}", e),
                    }
                }
            }
        }
        Err(e) => println!("ERR {}", e),
    }
}
