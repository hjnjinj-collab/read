use crate::traits::{BookFormat, BookParser};
use crate::txt_parser::TxtParser;
use crate::epub_parser::EpubParser;
use anyhow::{Context, Result};
use std::fs::File;
use std::io::Read;
use std::path::Path;

/// 格式检测结果
#[derive(Debug, Clone)]
pub struct FormatDetectionResult {
    /// 检测到的格式
    pub format: BookFormat,
    /// 检测方法
    pub method: DetectionMethod,
    /// 置信度 (0.0 - 1.0)
    pub confidence: f32,
}

/// 检测方法
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DetectionMethod {
    /// 文件扩展名
    Extension,
    /// Magic Number
    MagicNumber,
    /// 内容分析
    ContentAnalysis,
    /// 默认（兜底）
    Default,
}

/// 统一书籍加载器
///
/// 提供自动格式检测和解析器工厂功能。
/// 使用方式：
/// ```no_run
/// use book_parser::loader::BookSourceLoader;
///
/// fn main() -> anyhow::Result<()> {
///     let mut parser = BookSourceLoader::load("/path/to/book.txt")?;
///     let metadata = parser.parse()?;
///     println!("书名: {}, 章节数: {}", metadata.title, metadata.total_chapters);
///     Ok(())
/// }
/// ```
pub struct BookSourceLoader;

impl BookSourceLoader {
    /// 加载书籍（自动检测格式并创建对应解析器）
    ///
    /// 通过文件扩展名和 Magic Number 双重检测确定文件格式，
    /// 然后创建对应的解析器实例。
    pub fn load(file_path: &str) -> Result<Box<dyn BookParser>> {
        let path = Path::new(file_path);

        // 检查文件是否存在
        if !path.exists() {
            return Err(anyhow::anyhow!("文件不存在: {}", file_path));
        }

        // 检测格式
        let format = Self::detect_format(path)
            .with_context(|| format!("检测文件格式失败: {}", file_path))?;

        // 创建解析器
        Self::create_parser(path, format)
    }

    /// 检测文件格式
    ///
    /// 优先使用文件扩展名，如果扩展名不明确则读取文件头（Magic Number）判断。
    pub fn detect_format(path: &Path) -> Result<BookFormat> {
        let result = Self::detect_format_detailed(path)?;
        Ok(result.format)
    }

    /// 详细检测文件格式（包含置信度和检测方法）
    pub fn detect_format_detailed(path: &Path) -> Result<FormatDetectionResult> {
        // 1. 先检查扩展名
        if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
            let format = BookFormat::from_extension(ext);
            if format != BookFormat::Unknown {
                // EPUB vs 裸 ZIP 漫画：扩展名 .epub 直接信；.zip/.cbz 若包内
                // 带 EPUB 结构仍纠正为 Epub（少见但存在误后缀）
                let format = if format == BookFormat::Comic {
                    Self::refine_zip_as_epub(path).unwrap_or(format)
                } else if format == BookFormat::Epub {
                    format
                } else {
                    format
                };
                return Ok(FormatDetectionResult {
                    format,
                    method: DetectionMethod::Extension,
                    confidence: 0.9,
                });
            }
        }

        // 2. 读取文件头（Magic Number）
        let mut file = File::open(path)
            .with_context(|| format!("无法打开文件: {}", path.display()))?;
        let mut magic = [0u8; 16];
        let bytes_read = file.read(&mut magic)
            .with_context(|| "读取文件头失败")?;

        if bytes_read >= 4 {
            let mut format = BookFormat::from_magic(&magic);
            // ZIP 容器：有 EPUB 结构 → Epub，否则 Comic
            if format == BookFormat::Comic && magic.starts_with(b"PK") {
                format = Self::refine_zip_as_epub(path).unwrap_or(BookFormat::Comic);
            }
            if format != BookFormat::Unknown {
                return Ok(FormatDetectionResult {
                    format,
                    method: DetectionMethod::MagicNumber,
                    confidence: 0.95,
                });
            }
        }

        // 3. 尝试内容分析（检测是否为文本文件）
        if Self::is_likely_text(&magic[..bytes_read]) {
            return Ok(FormatDetectionResult {
                format: BookFormat::Txt,
                method: DetectionMethod::ContentAnalysis,
                confidence: 0.7,
            });
        }

        // 4. 默认为 TXT
        Ok(FormatDetectionResult {
            format: BookFormat::Txt,
            method: DetectionMethod::Default,
            confidence: 0.5,
        })
    }

    /// ZIP 是否实为 EPUB：看 `mimetype` 条目或 `META-INF/container.xml`。
    /// 打开失败/非 ZIP → None（维持 Comic）。
    fn refine_zip_as_epub(path: &Path) -> Option<BookFormat> {
        use std::io::Read;
        let file = File::open(path).ok()?;
        let mut archive = zip::ZipArchive::new(file).ok()?;
        if let Ok(mut m) = archive.by_name("mimetype") {
            let mut buf = String::new();
            if m.read_to_string(&mut buf).is_ok()
                && buf.trim() == "application/epub+zip"
            {
                return Some(BookFormat::Epub);
            }
        }
        if archive.by_name("META-INF/container.xml").is_ok() {
            return Some(BookFormat::Epub);
        }
        Some(BookFormat::Comic)
    }

    /// 检测内容是否为文本
    fn is_likely_text(data: &[u8]) -> bool {
        if data.is_empty() {
            return false;
        }

        // 检查 UTF-8 有效性
        if std::str::from_utf8(data).is_ok() {
            return true;
        }

        // 检查是否有大量可打印字符
        let printable_count = data.iter()
            .filter(|&&b| b.is_ascii_graphic() || b.is_ascii_whitespace() || b == b'\n' || b == b'\r')
            .count();

        printable_count as f32 / data.len() as f32 > 0.8
    }

    /// 获取文件格式（不创建解析器，仅检测）
    pub fn get_format(file_path: &str) -> Result<BookFormat> {
        let path = Path::new(file_path);
        if !path.exists() {
            return Err(anyhow::anyhow!("文件不存在: {}", file_path));
        }
        Self::detect_format(path)
    }

    /// 获取详细格式信息
    pub fn get_format_info(file_path: &str) -> Result<FormatDetectionResult> {
        let path = Path::new(file_path);
        if !path.exists() {
            return Err(anyhow::anyhow!("文件不存在: {}", file_path));
        }
        Self::detect_format_detailed(path)
    }

    /// 创建解析器实例
    pub fn create_parser(path: &Path, format: BookFormat) -> Result<Box<dyn BookParser>> {
        match format {
            BookFormat::Txt => {
                let parser = TxtParser::from_file(path)
                    .with_context(|| "创建 TXT 解析器失败")?;
                Ok(Box::new(parser))
            }
            BookFormat::Epub => {
                let parser = EpubParser::from_file(path)
                    .with_context(|| "创建 EPUB 解析器失败")?;
                Ok(Box::new(parser))
            }
            BookFormat::Comic => {
                let parser = crate::comic_archive::ComicArchiveParser::from_file(path)
                    .with_context(|| "创建压缩包漫画解析器失败")?;
                Ok(Box::new(parser))
            }
            BookFormat::Pdf | BookFormat::Mobi => {
                Err(anyhow::anyhow!(
                    "暂不支持的文件格式: {} ({})",
                    path.display(),
                    format.display_name()
                ))
            }
            BookFormat::Unknown => {
                Err(anyhow::anyhow!(
                    "不支持的文件格式: {}",
                    path.display()
                ))
            }
        }
    }

}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_detect_txt_by_extension() {
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"Hello World").unwrap();
        let path = tmp.path().with_extension("txt");

        // 重命名以使用 .txt 扩展名
        let new_path = path.clone();
        std::fs::rename(tmp.path(), &new_path).unwrap();

        let result = BookSourceLoader::detect_format_detailed(&new_path).unwrap();
        assert_eq!(result.format, BookFormat::Txt);
        assert_eq!(result.method, DetectionMethod::Extension);
        assert!(result.confidence > 0.8);
    }

    #[test]
    fn test_detect_epub_by_extension() {
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"PK\x03\x04\x00\x00").unwrap();
        let path = tmp.path().with_extension("epub");

        let new_path = path.clone();
        std::fs::rename(tmp.path(), &new_path).unwrap();

        let result = BookSourceLoader::detect_format_detailed(&new_path).unwrap();
        assert_eq!(result.format, BookFormat::Epub);
        assert_eq!(result.method, DetectionMethod::Extension);
    }

    #[test]
    fn test_detect_epub_by_magic_number() {
        let mut tmp = NamedTempFile::new().unwrap();
        // ZIP magic: PK\x03\x04 —— 无 EPUB 结构时判 Comic
        tmp.write_all(b"PK\x03\x04\x00\x00\x00\x00").unwrap();
        // 使用无扩展名的临时文件
        let path = tmp.path().to_path_buf();

        let result = BookSourceLoader::detect_format_detailed(&path).unwrap();
        // 裸 ZIP（无 mimetype/container.xml）→ Comic
        assert_eq!(result.format, BookFormat::Comic);
        assert_eq!(result.method, DetectionMethod::MagicNumber);
    }

    #[test]
    fn test_detect_pdf_by_magic() {
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"%PDF-1.4 test content").unwrap();
        let path = tmp.path().to_path_buf();

        let result = BookSourceLoader::detect_format_detailed(&path).unwrap();
        assert_eq!(result.format, BookFormat::Pdf);
        assert_eq!(result.method, DetectionMethod::MagicNumber);
    }

    #[test]
    fn test_detect_txt_by_content() {
        let mut tmp = NamedTempFile::new().unwrap();
        // 写入纯文本内容，无扩展名
        let text = "This is a text file content\nSecond line";
        tmp.write_all(text.as_bytes()).unwrap();
        let path = tmp.path().to_path_buf();

        let result = BookSourceLoader::detect_format_detailed(&path).unwrap();
        assert_eq!(result.format, BookFormat::Txt);
        assert!(result.confidence >= 0.5);
    }

    #[test]
    fn test_file_not_found() {
        let result = BookSourceLoader::load("/nonexistent/path/book.txt");
        assert!(result.is_err());
    }

    #[test]
    fn test_get_format_info() {
        let mut tmp = NamedTempFile::new().unwrap();
        tmp.write_all(b"Hello").unwrap();
        let path = tmp.path().with_extension("txt");
        let new_path = path.clone();
        std::fs::rename(tmp.path(), &new_path).unwrap();

        let result = BookSourceLoader::get_format_info(new_path.to_str().unwrap()).unwrap();
        assert_eq!(result.format, BookFormat::Txt);
    }
}
