use anyhow::Result;

/// 资源类型枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResourceType {
    /// 图片资源
    Image,
    /// 字体资源
    Font,
    /// 样式表资源
    Stylesheet,
    /// 未知类型
    Unknown,
}

impl ResourceType {
    /// 从 MIME 类型推断资源类型
    pub fn from_mime(mime: &str) -> Self {
        match mime.to_lowercase().as_str() {
            "image/png" | "image/jpeg" | "image/gif" | "image/svg+xml" | "image/webp" => {
                ResourceType::Image
            }
            "font/ttf" | "font/otf" | "font/woff" | "font/woff2" | "application/font-woff"
            | "application/font-woff2" => ResourceType::Font,
            "text/css" => ResourceType::Stylesheet,
            _ => ResourceType::Unknown,
        }
    }

    /// 从文件扩展名推断资源类型
    pub fn from_extension(ext: &str) -> Self {
        match ext.to_lowercase().as_str() {
            "png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" => ResourceType::Image,
            "ttf" | "otf" | "woff" | "woff2" => ResourceType::Font,
            "css" => ResourceType::Stylesheet,
            _ => ResourceType::Unknown,
        }
    }
}

/// 书籍解析器统一接口
///
/// 所有格式的解析器（TXT、EPUB 等）都实现此 trait，
/// 提供统一的书籍解析和内容获取 API。
pub trait BookParser: Send + Sync {
    /// 解析书籍元信息和章节列表
    ///
    /// 此方法执行文件读取、格式检测、元信息提取和章节分割。
    /// 对于大文件，章节内容按需加载（不在此时全部读入内存）。
    fn parse(&mut self) -> Result<BookMetadata>;

    /// 获取章节列表
    ///
    /// 必须在 `parse()` 之后调用。返回解析出的所有章节信息。
    fn get_chapter_list(&self) -> Result<Vec<ChapterInfo>>;

    /// 获取指定章节的内容
    ///
    /// 按需加载章节文本内容。对于 TXT 文件，根据偏移量切片；
    /// 对于 EPUB 文件，解压并解析对应的 HTML 文件。
    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String>;

    /// 获取书籍资源（图片、字体、样式表等）
    ///
    /// 对于 TXT 格式，始终返回错误（TXT 不支持资源）。
    /// 对于 EPUB 格式，从 ZIP 中提取指定资源。
    fn get_resource(&mut self, _resource_id: &str) -> Result<Vec<u8>> {
        anyhow::bail!("当前格式不支持资源获取")
    }

    /// 获取所有资源的 ID 列表
    ///
    /// 返回格式为 (resource_id, mime_type) 的列表。
    fn list_resources(&self) -> Result<Vec<(String, String)>> {
        Ok(Vec::new())
    }

    /// 获取资源的 MIME 类型
    fn get_resource_mime(&self, resource_id: &str) -> Option<String> {
        // 根据扩展名推断
        let ext = resource_id.rsplit('.').next()?;
        let mime = match ext.to_lowercase().as_str() {
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "svg" => "image/svg+xml",
            "css" => "text/css",
            "ttf" => "font/ttf",
            "otf" => "font/otf",
            "woff" => "font/woff",
            "woff2" => "font/woff2",
            _ => return None,
        };
        Some(mime.to_string())
    }

    /// 获取书籍支持的资源类型列表
    fn supported_resources(&self) -> Vec<ResourceType> {
        Vec::new()
    }

    /// 预估章节字数（用于进度估算）
    fn estimate_chapter_length(&self, chapter_index: usize) -> usize {
        // 默认实现：返回章节信息中的预估值
        if let Ok(chapters) = self.get_chapter_list() {
            chapters.get(chapter_index)
                .map(|ch| ch.estimated_words)
                .unwrap_or(0)
        } else {
            0
        }
    }

    /// 获取书籍格式
    fn format(&self) -> BookFormat;

    /// 获取书籍总章节数
    fn total_chapters(&self) -> usize;

    /// 清理资源，释放文件句柄等
    fn cleanup(&mut self);
}

/// 书籍元信息
#[derive(Debug, Clone)]
pub struct BookMetadata {
    /// 书名
    pub title: String,
    /// 作者
    pub author: String,
    /// 封面图片数据（可选）
    pub cover_data: Option<Vec<u8>>,
    /// 语言代码（如 "zh-CN", "en"）
    pub language: String,
    /// 总章节数
    pub total_chapters: usize,
    /// 文件大小（字节）
    pub file_size: u64,
    /// 书籍格式
    pub format: BookFormat,
}

/// 章节信息
#[derive(Debug, Clone)]
pub struct ChapterInfo {
    /// 章节索引（从 0 开始）
    pub index: usize,
    /// 章节标题
    pub title: String,
    /// 预估字数（用于 UI 显示）
    pub estimated_words: usize,
    /// 章节级别（用于嵌套章节，如卷→章→节）
    pub level: u8,
    /// 父章节索引（用于嵌套结构，None 表示顶层）
    pub parent_index: Option<usize>,

    // === TXT 格式特有字段 ===
    /// TXT: 章节起始字节偏移（相对于文件内容）
    pub start_byte_offset: Option<usize>,
    /// TXT: 章节结束字节偏移（相对于文件内容）
    pub end_byte_offset: Option<usize>,

    // === EPUB 格式特有字段 ===
    /// EPUB: spine 中对应的 href
    pub resource_href: Option<String>,
    /// EPUB: 在 spine 中的顺序
    pub spine_index: Option<usize>,
    /// EPUB: 片段 ID（如 #chapter1）
    pub fragment_id: Option<String>,
}

impl ChapterInfo {
    /// 创建 TXT 章节信息
    pub fn txt_chapter(
        index: usize,
        title: String,
        estimated_words: usize,
        start_byte_offset: usize,
        end_byte_offset: usize,
    ) -> Self {
        Self {
            index,
            title,
            estimated_words,
            level: 1,
            parent_index: None,
            start_byte_offset: Some(start_byte_offset),
            end_byte_offset: Some(end_byte_offset),
            resource_href: None,
            spine_index: None,
            fragment_id: None,
        }
    }

    /// 创建 EPUB 章节信息
    pub fn epub_chapter(
        index: usize,
        title: String,
        estimated_words: usize,
        resource_href: String,
        spine_index: usize,
    ) -> Self {
        Self {
            index,
            title,
            estimated_words,
            level: 1,
            parent_index: None,
            start_byte_offset: None,
            end_byte_offset: None,
            resource_href: Some(resource_href),
            spine_index: Some(spine_index),
            fragment_id: None,
        }
    }

    /// 创建带层级的章节信息
    pub fn with_level(mut self, level: u8) -> Self {
        self.level = level;
        self
    }

    /// 设置父章节
    pub fn with_parent(mut self, parent_index: usize) -> Self {
        self.parent_index = Some(parent_index);
        self
    }

    /// 设置片段 ID
    pub fn with_fragment(mut self, fragment_id: String) -> Self {
        self.fragment_id = Some(fragment_id);
        self
    }

    /// 获取完整的章节路径（如 "卷一 > 第一章 > 第一节"）
    pub fn full_path(&self, chapters: &[ChapterInfo]) -> String {
        let mut path = vec![self.title.clone()];
        let mut current_parent = self.parent_index;

        while let Some(parent_idx) = current_parent {
            if let Some(parent) = chapters.get(parent_idx) {
                path.insert(0, parent.title.clone());
                current_parent = parent.parent_index;
            } else {
                break;
            }
        }

        path.join(" > ")
    }
}

/// 书籍格式枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BookFormat {
    Txt,
    Epub,
    Pdf,
    Mobi,
    Unknown,
}

impl BookFormat {
    /// 从文件扩展名推断格式
    pub fn from_extension(ext: &str) -> Self {
        match ext.to_lowercase().as_str() {
            "txt" | "text" => BookFormat::Txt,
            "epub" => BookFormat::Epub,
            "pdf" => BookFormat::Pdf,
            "mobi" | "azw" | "azw3" => BookFormat::Mobi,
            _ => BookFormat::Unknown,
        }
    }

    /// 从 Magic Number 推断格式
    pub fn from_magic(magic: &[u8]) -> Self {
        if magic.len() >= 4 {
            // EPUB 是 ZIP 格式，以 PK\x03\x04 开头
            if magic.starts_with(b"PK\x03\x04") {
                return BookFormat::Epub;
            }
            // PDF 以 %PDF 开头
            if magic.starts_with(b"%PDF") {
                return BookFormat::Pdf;
            }
            // MOBI/AZW 以 BOOKMOBI 或 AZW 开头
            if magic.starts_with(b"BOOKMOBI") || magic.starts_with(b"AZW") {
                return BookFormat::Mobi;
            }
        }
        BookFormat::Unknown
    }

    /// 获取格式的文件扩展名
    pub fn extension(&self) -> &'static str {
        match self {
            BookFormat::Txt => "txt",
            BookFormat::Epub => "epub",
            BookFormat::Pdf => "pdf",
            BookFormat::Mobi => "mobi",
            BookFormat::Unknown => "unknown",
        }
    }

    /// 获取格式的中文名称
    pub fn display_name(&self) -> &'static str {
        match self {
            BookFormat::Txt => "TXT 文本",
            BookFormat::Epub => "EPUB 电子书",
            BookFormat::Pdf => "PDF 文档",
            BookFormat::Mobi => "MOBI 电子书",
            BookFormat::Unknown => "未知格式",
        }
    }

    /// 是否支持章节提取
    pub fn supports_chapters(&self) -> bool {
        matches!(self, BookFormat::Txt | BookFormat::Epub)
    }

    /// 是否支持资源获取（图片、字体等）
    pub fn supports_resources(&self) -> bool {
        matches!(self, BookFormat::Epub)
    }
}

impl std::fmt::Display for BookFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display_name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_format_from_extension() {
        assert_eq!(BookFormat::from_extension("txt"), BookFormat::Txt);
        assert_eq!(BookFormat::from_extension("TXT"), BookFormat::Txt);
        assert_eq!(BookFormat::from_extension("epub"), BookFormat::Epub);
        assert_eq!(BookFormat::from_extension("EPUB"), BookFormat::Epub);
        assert_eq!(BookFormat::from_extension("pdf"), BookFormat::Pdf);
        assert_eq!(BookFormat::from_extension("mobi"), BookFormat::Mobi);
        assert_eq!(BookFormat::from_extension("azw3"), BookFormat::Mobi);
        assert_eq!(BookFormat::from_extension("docx"), BookFormat::Unknown);
    }

    #[test]
    fn test_book_format_from_magic() {
        assert_eq!(
            BookFormat::from_magic(b"PK\x03\x04\x00\x00\x00\x00"),
            BookFormat::Epub
        );
        assert_eq!(
            BookFormat::from_magic(b"%PDF-1.4"),
            BookFormat::Pdf
        );
        assert_eq!(
            BookFormat::from_magic(b"BOOKMOBI"),
            BookFormat::Mobi
        );
        assert_eq!(
            BookFormat::from_magic(b"Hello World"),
            BookFormat::Unknown
        );
    }

    #[test]
    fn test_chapter_info_txt() {
        let ch = ChapterInfo::txt_chapter(0, "第一章".to_string(), 5000, 100, 5100);
        assert_eq!(ch.index, 0);
        assert_eq!(ch.title, "第一章");
        assert_eq!(ch.start_byte_offset, Some(100));
        assert_eq!(ch.end_byte_offset, Some(5100));
        assert!(ch.resource_href.is_none());
        assert_eq!(ch.level, 1);
        assert!(ch.parent_index.is_none());
    }

    #[test]
    fn test_chapter_info_epub() {
        let ch = ChapterInfo::epub_chapter(
            0,
            "Chapter 1".to_string(),
            3000,
            "chapter001.xhtml".to_string(),
            0,
        );
        assert_eq!(ch.index, 0);
        assert_eq!(ch.resource_href, Some("chapter001.xhtml".to_string()));
        assert_eq!(ch.spine_index, Some(0));
        assert!(ch.start_byte_offset.is_none());
        assert_eq!(ch.level, 1);
    }

    #[test]
    fn test_chapter_info_with_level() {
        let ch = ChapterInfo::txt_chapter(0, "卷一".to_string(), 10000, 0, 10000)
            .with_level(0);
        assert_eq!(ch.level, 0);
    }

    #[test]
    fn test_chapter_info_with_parent() {
        let ch = ChapterInfo::txt_chapter(1, "第一节".to_string(), 2000, 100, 2100)
            .with_parent(0);
        assert_eq!(ch.parent_index, Some(0));
    }

    #[test]
    fn test_chapter_info_full_path() {
        let chapters = vec![
            ChapterInfo::txt_chapter(0, "卷一".to_string(), 10000, 0, 10000).with_level(0),
            ChapterInfo::txt_chapter(1, "第一章".to_string(), 5000, 0, 5000)
                .with_level(1)
                .with_parent(0),
            ChapterInfo::txt_chapter(2, "第一节".to_string(), 2000, 0, 2000)
                .with_level(2)
                .with_parent(1),
        ];

        assert_eq!(chapters[2].full_path(&chapters), "卷一 > 第一章 > 第一节");
        assert_eq!(chapters[1].full_path(&chapters), "卷一 > 第一章");
        assert_eq!(chapters[0].full_path(&chapters), "卷一");
    }

    #[test]
    fn test_book_format_display() {
        assert_eq!(BookFormat::Txt.to_string(), "TXT 文本");
        assert_eq!(BookFormat::Epub.to_string(), "EPUB 电子书");
        assert_eq!(BookFormat::Pdf.to_string(), "PDF 文档");
        assert_eq!(BookFormat::Mobi.to_string(), "MOBI 电子书");
        assert_eq!(BookFormat::Txt.extension(), "txt");
        assert_eq!(BookFormat::Epub.extension(), "epub");
    }

    #[test]
    fn test_book_format_capabilities() {
        assert!(BookFormat::Txt.supports_chapters());
        assert!(!BookFormat::Txt.supports_resources());
        assert!(BookFormat::Epub.supports_chapters());
        assert!(BookFormat::Epub.supports_resources());
        assert!(!BookFormat::Pdf.supports_chapters());
        assert!(!BookFormat::Pdf.supports_resources());
    }

    #[test]
    fn test_resource_type_from_mime() {
        assert_eq!(ResourceType::from_mime("image/png"), ResourceType::Image);
        assert_eq!(ResourceType::from_mime("image/jpeg"), ResourceType::Image);
        assert_eq!(ResourceType::from_mime("font/ttf"), ResourceType::Font);
        assert_eq!(ResourceType::from_mime("text/css"), ResourceType::Stylesheet);
        assert_eq!(ResourceType::from_mime("application/pdf"), ResourceType::Unknown);
    }

    #[test]
    fn test_resource_type_from_extension() {
        assert_eq!(ResourceType::from_extension("png"), ResourceType::Image);
        assert_eq!(ResourceType::from_extension("jpg"), ResourceType::Image);
        assert_eq!(ResourceType::from_extension("ttf"), ResourceType::Font);
        assert_eq!(ResourceType::from_extension("css"), ResourceType::Stylesheet);
        assert_eq!(ResourceType::from_extension("pdf"), ResourceType::Unknown);
    }
}
