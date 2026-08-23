use reader_core::content_preprocessor::{ContentPreprocessor, ProcessOptions};

fn make_options(title: &str) -> ProcessOptions {
    ProcessOptions {
        book_name: "测试书籍".to_string(),
        title: title.to_string(),
        chapter_index: 3,
        remove_duplicate_title: true,
        ..Default::default()
    }
}

#[tokio::test]
async fn test_duplicate_title_with_indent() {
    // 模拟真实文件结构：章节内容开头是带全角空格缩进的重复标题
    let content = "　　第3章 披挂刀法！\n　　赵大、赵二兄弟是谁？\n\n　　郑均心中一怔。";

    let preprocessor = ContentPreprocessor::new(vec![]);
    let result = preprocessor
        .process(content, &make_options("第3章 披挂刀法！"))
        .await
        .unwrap();

    assert_eq!(
        result.matches("第3章 披挂刀法！").count(),
        0,
        "处理后的内容不应包含章节标题"
    );
    assert!(result.contains("赵大、赵二兄弟是谁？"), "正文内容应保留");
}

#[tokio::test]
async fn test_duplicate_title_repeated_lines() {
    // 标题连续出现两次（无缩进 + 带缩进）
    let content = "第3章 披挂刀法！\n　　第3章 披挂刀法！\n　　赵大、赵二兄弟是谁？";

    let preprocessor = ContentPreprocessor::new(vec![]);
    let result = preprocessor
        .process(content, &make_options("第3章 披挂刀法！"))
        .await
        .unwrap();

    assert_eq!(result.matches("第3章 披挂刀法！").count(), 0);
    assert!(result.contains("赵大、赵二兄弟是谁？"));
}

#[tokio::test]
async fn test_duplicate_title_with_leading_blank_lines() {
    // 标题前有空行
    let content = "\n\n第3章 披挂刀法！\n　　第3章 披挂刀法！\n　　赵大、赵二兄弟是谁？";

    let preprocessor = ContentPreprocessor::new(vec![]);
    let result = preprocessor
        .process(content, &make_options("第3章 披挂刀法！"))
        .await
        .unwrap();

    assert_eq!(result.matches("第3章 披挂刀法！").count(), 0);
    assert!(result.contains("赵大、赵二兄弟是谁？"));
}

#[tokio::test]
async fn test_no_duplicate_title_kept() {
    // 内容开头不是标题时，内容应原样保留
    let content = "　　赵大、赵二兄弟是谁？\n　　郑均心中一怔。";

    let preprocessor = ContentPreprocessor::new(vec![]);
    let result = preprocessor
        .process(content, &make_options("第3章 披挂刀法！"))
        .await
        .unwrap();

    assert!(result.contains("赵大、赵二兄弟是谁？"));
    assert!(result.contains("郑均心中一怔。"));
}
