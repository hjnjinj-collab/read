use std::fs::File;
use std::io::Write;

fn main() -> anyhow::Result<()> {
    // 创建一个大文件，模拟真实场景中的大小说
    let mut content = String::new();
    
    // 添加书籍信息
    content.push_str("《贷款武圣》\n");
    content.push_str("作者：长鲸归海\n");
    content.push_str("来源：得奇小说网\n");
    content.push_str("网址：http://www.deqixs.com\n\n");
    
    // 生成很多章节以达到足够的文件大小
    for i in 1..=1000 {
        content.push_str(&format!("第{}章 章节标题\n", i));
        // 使用全角空格（\u{3000}）和其他中文字符
        content.push_str("　　大周朝。\n");
        content.push_str("　　博州，平章郡，黑山县。\n");
        content.push_str("　　县里街道空寂，碎石板路蜿蜒曲折，两旁店铺林立。\n");
        
        // 添加更多内容以增加文件大小
        for _ in 0..100 {
            content.push_str("　　这是正文内容，包含各种中文字符和标点符号。");
            content.push_str("这里有更多的文字来填充章节内容。\n");
        }
        content.push_str("\n");
    }
    
    // 将内容写入文件
    let mut file = File::create("test_very_large_book.txt")?;
    file.write_all(content.as_bytes())?;
    
    println!("文件大小: {} 字节", content.len());
    println!("测试文件已创建: test_very_large_book.txt");
    
    // 现在测试解析
    println!("\n开始解析...");
    let file = File::open("test_very_large_book.txt")?;
    
    use book_parser::TxtParser;
    let book = TxtParser::parse(file, Some("贷款武圣".to_string()))?;
    
    println!("解析成功！");
    println!("书名: {}", book.title);
    println!("章节数: {}", book.chapters.len());
    println!("内容总长度: {}", book.content.len());
    
    // 验证所有章节的边界
    for (i, chapter) in book.chapters.iter().enumerate() {
        assert!(book.content.is_char_boundary(chapter.start_pos), 
            "第 {} 章的 start_pos 不在字符边界上", i + 1);
        assert!(book.content.is_char_boundary(chapter.end_pos), 
            "第 {} 章的 end_pos 不在字符边界上", i + 1);
    }
    
    println!("\n✓ 所有章节的字符边界都是有效的！");
    println!("✓ 修复成功，没有出现 panic！");
    
    Ok(())
}
