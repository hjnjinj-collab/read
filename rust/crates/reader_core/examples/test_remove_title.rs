use reader_core::content_preprocessor::{ContentPreprocessor, ProcessOptions};

#[tokio::main]
async fn main() {
    // 测试1: 模拟实际章节内容 - 带缩进的重复标题
    println!("========== 测试1: 带缩进的重复标题 ==========");
    let content1 = r#"　　第3章 披挂刀法！
　　赵大、赵二兄弟是谁？

　　郑均心中一怔，但很快就从记忆中想起了赵大、赵二两兄弟。"#;

    let options1 = ProcessOptions {
        book_name: "测试书籍".to_string(),
        title: "第3章 披挂刀法！".to_string(),
        chapter_index: 3,
        remove_duplicate_title: true,
        ..Default::default()
    };

    println!("=== 原始内容 ===");
    println!("{}", content1);
    println!();

    let preprocessor = ContentPreprocessor::new(vec![]);
    let result1 = preprocessor.process(content1, &options1).await.unwrap();
    
    println!("=== 处理后的内容 ===");
    println!("{}", result1);
    println!();
    
    let title_count1 = result1.matches("第3章 披挂刀法！").count();
    println!("标题出现次数: {}", title_count1);
    
    if title_count1 == 0 {
        println!("✅ 测试1通过：标题已被删除");
    } else {
        println!("❌ 测试1失败：标题仍然存在 {} 次", title_count1);
    }
    
    if result1.contains("赵大、赵二兄弟是谁？") {
        println!("✅ 测试1通过：正文内容保留");
    } else {
        println!("❌ 测试1失败：正文内容丢失");
    }

    println!("\n========== 测试2: 多次重复的标题 ==========");
    let content2 = r#"第3章 披挂刀法！
　　第3章 披挂刀法！
　　赵大、赵二兄弟是谁？"#;

    let result2 = preprocessor.process(content2, &options1).await.unwrap();
    
    println!("=== 原始内容 ===");
    println!("{}", content2);
    println!();
    
    println!("=== 处理后的内容 ===");
    println!("{}", result2);
    println!();
    
    let title_count2 = result2.matches("第3章 披挂刀法！").count();
    println!("标题出现次数: {}", title_count2);
    
    if title_count2 == 0 {
        println!("✅ 测试2通过：所有重复标题已被删除");
    } else {
        println!("❌ 测试2失败：标题仍然存在 {} 次", title_count2);
    }

    println!("\n========== 测试3: 标题前有空行 ==========");
    let content3 = r#"

第3章 披挂刀法！
　　第3章 披挂刀法！
　　赵大、赵二兄弟是谁？"#;

    let result3 = preprocessor.process(content3, &options1).await.unwrap();
    
    println!("=== 原始内容 ===");
    println!("{}", content3);
    println!();
    
    println!("=== 处理后的内容 ===");
    println!("{}", result3);
    println!();
    
    let title_count3 = result3.matches("第3章 披挂刀法！").count();
    println!("标题出现次数: {}", title_count3);
    
    if title_count3 == 0 {
        println!("✅ 测试3通过：所有重复标题已被删除");
    } else {
        println!("❌ 测试3失败：标题仍然存在 {} 次", title_count3);
    }
}
