pub mod traits;
pub mod loader;
pub mod txt_parser;
pub mod epub_parser;
pub mod chapter_recognizer;
pub mod encoding;
pub mod chapter_extractor;
pub mod content_cleaner;
pub mod clean_rules;
pub mod chinese_convert;
pub mod epub_clean_cache;
pub mod content_ir;
pub mod dom_json;
pub mod extract_rules;
pub mod css_lite;
pub mod image_size;

// 重新导出新 API
pub use traits::{BookParser, BookMetadata, ChapterInfo, BookFormat};
pub use loader::BookSourceLoader;
pub use txt_parser::TxtParser;
pub use epub_parser::EpubParser;
pub use chapter_recognizer::{ChapterRecognizer, ChapterMatch, LineContext, PatternCategory, RecognizedChapter};
pub use encoding::{EncodingInfo, SmartEncodingDetector};
pub use chapter_extractor::{ChapterExtractor, ChapterRule, JsChapterInfo};
pub use content_cleaner::{ContentCleaner, ConvertMode, ParagraphMode, CleanOptions};
pub use content_ir::{ContentBlock, ListItem, TableCell, StructuredContent, PageBackground, BgSize, Align, StyledRun};
pub use epub_clean_cache::EpubCleanedBook;
pub use chinese_convert::{convert_s2t, convert_t2s};
// === 向后兼容：旧 API 保留 ===
// bridge 和其他现有代码仍使用 Book 和 Chapter 类型

/// 向后兼容的章节信息
#[derive(Debug, Clone)]
pub struct Chapter {
    pub title: String,
    pub start_pos: usize,
    pub end_pos: usize,
    /// 章节层级：1=顶层（嵌套目录用；TXT 平铺恒为 1）
    pub level: u8,
    /// 父章节索引（None=顶层）
    pub parent_index: Option<usize>,
}

/// 向后兼容的书籍结构（包含完整内容）
#[derive(Debug, Clone)]
pub struct Book {
    pub title: String,
    pub content: String,
    pub chapters: Vec<Chapter>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 向后兼容测试：旧的 TxtParser::parse 接口
    #[test]
    fn test_txt_parser_backward_compat() {
        let content = r#"第一章 开始
这是第一章的内容。

第二章 继续
这是第二章的内容。"#;

        let reader = content.as_bytes();
        let book = TxtParser::parse(reader, Some("测试书籍".to_string())).unwrap();

        assert_eq!(book.title, "测试书籍");
        assert!(book.chapters.len() >= 2);
        assert!(book.content.contains("第一章"));
    }

    /// 测试新 API：BookParser trait
    #[test]
    fn test_new_api_book_parser_trait() {
        let content = r#"第一章 开始
这是第一章的内容。

第二章 继续
这是第二章的内容。"#;

        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, Some("测试书籍".to_string())).unwrap();

        let metadata = parser.parse().unwrap();
        assert_eq!(metadata.title, "测试书籍");
        assert!(metadata.total_chapters >= 2);

        let chapters = parser.get_chapter_list().unwrap();
        assert_eq!(chapters[0].title, "第一章 开始");
    }

    /// 测试 BookSourceLoader 格式检测
    #[test]
    fn test_book_source_loader() {
        use std::io::Write;
        use tempfile::NamedTempFile;

        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"Hello").unwrap();
        let path = tmp.path().with_extension("txt");
        let new_path = path.clone();
        std::fs::rename(tmp.path(), &new_path).unwrap();

        let format = BookSourceLoader::get_format(new_path.to_str().unwrap()).unwrap();
        assert_eq!(format, BookFormat::Txt);
    }

    /// 测试 EPUB HTML 转文本
    #[test]
    fn test_epub_html_to_text() {
        let html = r#"<html><body>
            <h1>标题</h1>
            <p>内容。</p>
            <script>var x = 1;</script>
        </body></html>"#;

        let text = EpubParser::html_to_text(html);
        assert!(text.contains("标题"));
        assert!(text.contains("内容"));
        assert!(!text.contains("var x"));
    }
}
