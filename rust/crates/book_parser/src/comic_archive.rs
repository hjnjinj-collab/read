//! 压缩包漫画（CBZ/ZIP/CBR/RAR）解析
//!
//! 映射约定（与 `docs/compose/spec/archive-comic.md` 一致）：
//! - **文件夹 = 章**，图片文件 = 页；根下散图合成为一章「全本」
//! - 章内文件名**自然排序**（001 < 2 < 10）
//! - 页 = `LayoutItem::Image { gallery: true }`（一页一图）
//! - 资源按需读条目（对齐 EPUB `get_resource`），不整包落盘

use crate::image_size::probe_image_size;
use crate::traits::{
    BookFormat, BookMetadata, BookParser, ChapterInfo, ResourceType,
};
use anyhow::{Context, Result};
use std::collections::BTreeMap;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

/// 图片扩展名白名单
const IMAGE_EXTS: &[&str] = &["png", "jpg", "jpeg", "webp", "gif", "bmp"];

/// 单条目解压上限（防 zip 炸弹）
const MAX_ENTRY_BYTES: u64 = 64 * 1024 * 1024;
/// 条目数上限
const MAX_ENTRIES: usize = 20_000;

/// 压缩包条目
#[derive(Debug, Clone)]
pub struct ArchiveEntry {
    pub path: String,
    pub is_dir: bool,
    pub size: u64,
}

/// 归档读取统一接口（Zip / Rar）
pub trait ArchiveReader: Send + Sync {
    fn list_entries(&self) -> Result<Vec<ArchiveEntry>>;
    fn read_entry(&self, path: &str) -> Result<Vec<u8>>;
}

/// 路径安全：拒绝 `..`、绝对路径、盘符、空段
pub(crate) fn is_safe_entry_path(p: &str) -> bool {
    if p.is_empty() {
        return false;
    }
    let normalized = p.replace('\\', "/");
    if normalized.starts_with('/') || normalized.contains(':') {
        return false;
    }
    !normalized.split('/').any(|seg| seg == "..")
}

/// 自然排序键：数字片段按数值比较，数值相同再按数字串长度（2 < 002）
fn natural_key(name: &str) -> Vec<(u8, String, u64, u32)> {
    let lower = name.to_lowercase();
    let mut parts = Vec::new();
    let mut num = String::new();
    let mut text = String::new();
    let flush_num = |parts: &mut Vec<(u8, String, u64, u32)>, num: &mut String| {
        if !num.is_empty() {
            let v: u64 = num.parse().unwrap_or(u64::MAX);
            parts.push((1, String::new(), v, num.len() as u32));
            num.clear();
        }
    };
    let flush_text = |parts: &mut Vec<(u8, String, u64, u32)>, text: &mut String| {
        if !text.is_empty() {
            parts.push((0, text.clone(), 0, 0));
            text.clear();
        }
    };
    for ch in lower.chars() {
        if ch.is_ascii_digit() {
            if !text.is_empty() {
                flush_text(&mut parts, &mut text);
            }
            num.push(ch);
        } else {
            if !num.is_empty() {
                flush_num(&mut parts, &mut num);
            }
            text.push(ch);
        }
    }
    flush_num(&mut parts, &mut num);
    flush_text(&mut parts, &mut text);
    parts
}

fn is_image_path(path: &str) -> bool {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    IMAGE_EXTS.contains(&ext.as_str())
}

fn file_stem(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    name.rsplit_once('.')
        .map(|(s, _)| s.to_string())
        .unwrap_or_else(|| name.to_string())
}

// ── Zip 后端（复用 EPUB 同款 zip crate） ──

pub struct ZipArchiveReader {
    // 与 EPUB 一致：Mutex 保证 Send+Sync 下的短锁读取
    archive: std::sync::Mutex<zip::ZipArchive<File>>,
}

impl ZipArchiveReader {
    pub fn open(path: &Path) -> Result<Self> {
        let file = File::open(path)
            .with_context(|| format!("打开压缩包失败: {}", path.display()))?;
        let archive = zip::ZipArchive::new(file)
            .with_context(|| "不是有效的 ZIP/CBZ 压缩包")?;
        Ok(Self {
            archive: std::sync::Mutex::new(archive),
        })
    }
}

impl ArchiveReader for ZipArchiveReader {
    fn list_entries(&self) -> Result<Vec<ArchiveEntry>> {
        let mut guard = self.archive.lock().unwrap();
        let mut out = Vec::new();
        let n = guard.len();
        if n > MAX_ENTRIES {
            anyhow::bail!("压缩包条目过多（{} > {}）", n, MAX_ENTRIES);
        }
        for i in 0..n {
            let file = guard.by_index(i)?;
            let path = file.name().to_string();
            if !is_safe_entry_path(&path) {
                continue; // zip-slip：静默跳过恶意条目
            }
            out.push(ArchiveEntry {
                is_dir: file.is_dir(),
                size: file.size(),
                path,
            });
        }
        Ok(out)
    }

    fn read_entry(&self, path: &str) -> Result<Vec<u8>> {
        if !is_safe_entry_path(path) {
            anyhow::bail!("非法资源路径");
        }
        let mut guard = self.archive.lock().unwrap();
        let mut file = guard
            .by_name(path)
            .with_context(|| format!("压缩包内无此条目: {path}"))?;
        if file.size() > MAX_ENTRY_BYTES {
            anyhow::bail!("条目过大（{} bytes）", file.size());
        }
        let mut buf = Vec::with_capacity(file.size() as usize);
        file.read_to_end(&mut buf)?;
        if buf.len() as u64 > MAX_ENTRY_BYTES {
            anyhow::bail!("解压后过大（{} bytes）", buf.len());
        }
        Ok(buf)
    }
}

// ── Rar 后端（仅 Windows：libunrar C++ 含 Win32 源，Android NDK 无法编译） ──

/// RAR 是否可在本机解析
#[cfg(windows)]
pub fn rar_supported() -> bool {
    true
}

/// RAR 是否可在本机解析（Android/iOS 等：false，调用方给明确错误）
#[cfg(not(windows))]
pub fn rar_supported() -> bool {
    false
}

#[cfg(windows)]
pub struct RarArchiveReader {
    path: PathBuf,
    /// libunrar 流式句柄不可随机访问；每次 list/read 重开，用互斥串行化
    lock: std::sync::Mutex<()>,
}

#[cfg(windows)]
impl RarArchiveReader {
    pub fn open(path: &Path) -> Result<Self> {
        unrar::Archive::new(path)
            .open_for_listing()
            .map_err(|e| anyhow::anyhow!("不是有效的 RAR/CBR: {e:?}"))?;
        Ok(Self {
            path: path.to_path_buf(),
            lock: std::sync::Mutex::new(()),
        })
    }
}

#[cfg(windows)]
impl ArchiveReader for RarArchiveReader {
    fn list_entries(&self) -> Result<Vec<ArchiveEntry>> {
        let _g = self.lock.lock().unwrap();
        let archive = unrar::Archive::new(&self.path)
            .open_for_listing()
            .map_err(|e| anyhow::anyhow!("打开 RAR 失败: {e:?}"))?;
        let mut out = Vec::new();
        let mut n = 0usize;
        for item in archive {
            let item = item.map_err(|e| anyhow::anyhow!("读条目失败: {e:?}"))?;
            n += 1;
            if n > MAX_ENTRIES {
                anyhow::bail!("压缩包条目过多（> {MAX_ENTRIES}）");
            }
            let name = item.filename.to_string_lossy().replace('\\', "/");
            if !is_safe_entry_path(&name) {
                continue;
            }
            out.push(ArchiveEntry {
                path: name,
                is_dir: item.is_directory(),
                size: item.unpacked_size,
            });
        }
        Ok(out)
    }

    fn read_entry(&self, path: &str) -> Result<Vec<u8>> {
        if !is_safe_entry_path(path) {
            anyhow::bail!("非法资源路径");
        }
        let _g = self.lock.lock().unwrap();
        let mut archive = unrar::Archive::new(&self.path)
            .open_for_processing()
            .map_err(|e| anyhow::anyhow!("打开 RAR 失败: {e:?}"))?;
        // 流式扫描到目标条目（unrar 无随机访问）
        let target = path.replace('\\', "/");
        loop {
            let Some(cursor) = archive
                .read_header()
                .map_err(|e| anyhow::anyhow!("读 RAR 头失败: {e:?}"))?
            else {
                anyhow::bail!("压缩包内无此条目: {path}");
            };
            let name = cursor.entry().filename.to_string_lossy().replace('\\', "/");
            if name == target {
                if cursor.entry().unpacked_size > MAX_ENTRY_BYTES {
                    anyhow::bail!("条目过大");
                }
                let (data, _rest) = cursor
                    .read()
                    .map_err(|e| anyhow::anyhow!("解压失败 {path}: {e:?}"))?;
                if data.len() as u64 > MAX_ENTRY_BYTES {
                    anyhow::bail!("解压后过大（{} bytes）", data.len());
                }
                return Ok(data);
            }
            archive = cursor
                .skip()
                .map_err(|e| anyhow::anyhow!("跳过条目失败: {e:?}"))?;
        }
    }
}

// ── ComicArchiveParser ──

/// 一页图
#[derive(Debug, Clone)]
pub struct ComicPage {
    /// ZIP 内全路径（与 get_book_resource 同基准）
    pub href: String,
    pub aspect: f32,
}

/// 一章（= 一个文件夹或合成「全本」）
#[derive(Debug, Clone)]
pub struct ComicChapter {
    pub title: String,
    pub pages: Vec<ComicPage>,
}

/// 压缩包漫画解析器
pub struct ComicArchiveParser {
    path: PathBuf,
    format: BookFormat,
    reader: Box<dyn ArchiveReader>,
    chapters: Vec<ComicChapter>,
    metadata: Option<BookMetadata>,
    cover_data: Option<Vec<u8>>,
}

impl ComicArchiveParser {
    pub fn from_file(path: &Path) -> Result<Self> {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        let reader: Box<dyn ArchiveReader> = match ext.as_str() {
            "rar" | "cbr" => {
                if !rar_supported() {
                    anyhow::bail!("当前平台暂不支持 RAR/CBR（请转为 CBZ/ZIP）");
                }
                #[cfg(windows)]
                {
                    Box::new(RarArchiveReader::open(path)?)
                }
                #[cfg(not(windows))]
                {
                    anyhow::bail!("当前平台暂不支持 RAR/CBR（请转为 CBZ/ZIP）");
                }
            }
            _ => Box::new(ZipArchiveReader::open(path)?),
        };
        Ok(Self {
            path: path.to_path_buf(),
            format: BookFormat::Comic,
            reader,
            chapters: Vec::new(),
            metadata: None,
            cover_data: None,
        })
    }

    /// 构建章节/页映射（文件夹=章，自然排序）
    fn build_chapters(&mut self) -> Result<()> {
        let entries = self.reader.list_entries()?;
        // path → size（仅图片）
        let mut images: Vec<String> = entries
            .iter()
            .filter(|e| !e.is_dir && is_image_path(&e.path))
            .map(|e| e.path.clone())
            .collect();
        if images.is_empty() {
            anyhow::bail!("压缩包内没有图片");
        }

        // 封面：根下 cover/folder 且存在子目录时单独抽出
        let has_subdir = entries.iter().any(|e| {
            e.is_dir || e.path.contains('/')
        });
        let mut cover_href: Option<String> = None;
        if has_subdir {
            images.retain(|p| {
                let stem = file_stem(p).to_lowercase();
                let is_root = !p.contains('/');
                let is_cover_name =
                    stem == "cover" || stem == "folder" || stem.starts_with("cover.");
                if is_root && is_cover_name {
                    cover_href = Some(p.clone());
                    false
                } else {
                    true
                }
            });
        }
        if images.is_empty() {
            anyhow::bail!("压缩包内没有图片");
        }

        // 第一级目录分组；根下散图 → 章 key ""
        let mut groups: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for p in images {
            let key = match p.split_once('/') {
                Some((dir, _)) if !dir.is_empty() => dir.to_string(),
                _ => String::new(),
            };
            groups.entry(key).or_default().push(p);
        }

        let mut chapters = Vec::new();
        for (key, mut pages) in groups {
            pages.sort_by(|a, b| natural_key(a).cmp(&natural_key(b)));
            let title = if key.is_empty() {
                "全本".to_string()
            } else {
                key
            };
            let mut comic_pages = Vec::new();
            for href in pages {
                // 尺寸探测：只读条目前部；失败用默认 0.75 比
                let aspect = self
                    .reader
                    .read_entry(&href)
                    .ok()
                    .and_then(|data| probe_image_size(&data).map(|d| d.ratio()))
                    .unwrap_or(0.75);
                comic_pages.push(ComicPage { href, aspect });
            }
            chapters.push(ComicChapter {
                title,
                pages: comic_pages,
            });
        }

        // 无目录时合成「全本」已由 key="" 覆盖；若只有一组且 title==路径段
        // 保持原样（单文件夹包即一章）
        self.chapters = chapters;

        // 封面：cover_href 或第一章第一页前 64KB
        if let Some(href) = cover_href {
            if let Ok(data) = self.reader.read_entry(&href) {
                self.cover_data = Some(data);
            }
        } else if let Some(first) = self.chapters.first().and_then(|c| c.pages.first()) {
            // 封面只需 header 探测 + 展示，整图交给 BookImageStore；
            // 这里存一份供 CoverStore（与 EPUB cover_data 同径）
            if let Ok(data) = self.reader.read_entry(&first.href) {
                self.cover_data = Some(data);
            }
        }

        let total_pages: usize = self.chapters.iter().map(|c| c.pages.len()).sum();
        let title = self
            .path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "压缩包漫画".to_string());
        self.metadata = Some(BookMetadata {
            title,
            author: String::new(),
            cover_data: self.cover_data.clone(),
            language: "und".to_string(),
            total_chapters: self.chapters.len(),
            file_size: std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0),
            format: BookFormat::Comic,
        });
        let _ = total_pages;
        Ok(())
    }

    pub fn chapters(&self) -> &[ComicChapter] {
        &self.chapters
    }

    /// 封面字节（parse 时提取；可能为空）
    pub fn cover_data(&self) -> Option<&Vec<u8>> {
        self.cover_data.as_ref()
    }

    /// 按 resource_href 取图片字节（bridge get_book_resource 用）
    pub fn get_resource(&self, href: &str) -> Result<Vec<u8>> {
        self.reader.read_entry(href)
    }
}

impl BookParser for ComicArchiveParser {
    fn parse(&mut self) -> Result<BookMetadata> {
        if self.metadata.is_none() {
            self.build_chapters()?;
        }
        Ok(self.metadata.clone().expect("parse 后 metadata 必有"))
    }

    fn get_chapter_list(&self) -> Result<Vec<ChapterInfo>> {
        Ok(self
            .chapters
            .iter()
            .enumerate()
            .map(|(i, ch)| ChapterInfo {
                index: i,
                title: ch.title.clone(),
                estimated_words: ch.pages.len(), // UI 可显示「N 页」
                level: 0,
                parent_index: None,
                start_byte_offset: None,
                end_byte_offset: None,
                resource_href: ch.pages.first().map(|p| p.href.clone()),
                spine_index: Some(i),
                fragment_id: None,
            })
            .collect())
    }

    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        // 漫画无正文文本；返回页清单供调试/搜索占位
        let ch = self
            .chapters
            .get(chapter_index)
            .ok_or_else(|| anyhow::anyhow!("章节不存在: {chapter_index}"))?;
        Ok(ch.pages
            .iter()
            .map(|p| p.href.clone())
            .collect::<Vec<_>>()
            .join("\n"))
    }

    fn get_resource(&self, resource_id: &str) -> Result<Vec<u8>> {
        self.reader.read_entry(resource_id)
    }

    fn list_resources(&self) -> Result<Vec<(String, String)>> {
        Ok(self
            .chapters
            .iter()
            .flat_map(|c| c.pages.iter())
            .map(|p| {
                let mime = self
                    .get_resource_mime(&p.href)
                    .unwrap_or_else(|| "application/octet-stream".to_string());
                (p.href.clone(), mime)
            })
            .collect())
    }

    fn supported_resources(&self) -> Vec<ResourceType> {
        vec![ResourceType::Image]
    }

    fn format(&self) -> BookFormat {
        self.format
    }

    fn total_chapters(&self) -> usize {
        self.chapters.len()
    }

    fn cleanup(&mut self) {
        self.cover_data = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::FileOptions;

    fn write_cbz(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        let file = File::create(&path).unwrap();
        let mut zw = zip::ZipWriter::new(file);
        let opts = FileOptions::default();
        // 最小 PNG 头（1x1 不必完整，probe 失败回退 0.75）
        let png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde";
        zw.start_file("Vol1/002.jpg", opts).unwrap();
        zw.write_all(png).unwrap();
        zw.start_file("Vol1/010.jpg", opts).unwrap();
        zw.write_all(png).unwrap();
        zw.start_file("Vol1/2.jpg", opts).unwrap();
        zw.write_all(png).unwrap();
        zw.start_file("Vol2/001.png", opts).unwrap();
        zw.write_all(png).unwrap();
        zw.start_file("readme.txt", opts).unwrap();
        zw.write_all(b"skip me").unwrap();
        zw.finish().unwrap();
        path
    }

    #[test]
    fn natural_sort_orders_numeric_segments() {
        let a = natural_key("002.jpg");
        let b = natural_key("2.jpg");
        let c = natural_key("010.jpg");
        assert!(b < a, "2.jpg < 002.jpg");
        assert!(a < c, "002.jpg < 010.jpg");
        let _ = natural_key("10.jpg");
        assert!(natural_key("10.jpg") > natural_key("2.jpg"));
    }

    #[test]
    fn rejects_unsafe_entry_paths() {
        assert!(!is_safe_entry_path("../evil.png"));
        assert!(!is_safe_entry_path("/abs.png"));
        assert!(!is_safe_entry_path("C:/x.png"));
        assert!(is_safe_entry_path("Vol1/001.png"));
    }

    #[test]
    fn folder_as_chapter_image_as_page() {
        let tmp = tempfile::tempdir().unwrap();
        let cbz = write_cbz(tmp.path(), "test.cbz");
        let mut parser = ComicArchiveParser::from_file(&cbz).unwrap();
        let meta = parser.parse().unwrap();
        assert_eq!(meta.total_chapters, 2);
        let list = parser.get_chapter_list().unwrap();
        assert_eq!(list[0].title, "Vol1");
        assert_eq!(list[0].estimated_words, 3);
        assert_eq!(list[1].title, "Vol2");
        assert_eq!(list[1].estimated_words, 1);
        // Vol1 内自然序：2.jpg, 002.jpg, 010.jpg
        let ch0 = &parser.chapters()[0];
        assert!(
            ch0.pages[0].href.ends_with("2.jpg"),
            "page0={}",
            ch0.pages[0].href
        );
        assert!(
            ch0.pages[1].href.ends_with("002.jpg"),
            "page1={}",
            ch0.pages[1].href
        );
        assert!(
            ch0.pages[2].href.ends_with("010.jpg"),
            "page2={}",
            ch0.pages[2].href
        );
    }

    #[test]
    fn empty_archive_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("empty.cbz");
        let file = File::create(&path).unwrap();
        let mut zw = zip::ZipWriter::new(file);
        zw.start_file("a.txt", FileOptions::default()).unwrap();
        zw.write_all(b"no images").unwrap();
        zw.finish().unwrap();
        let mut parser = ComicArchiveParser::from_file(&path).unwrap();
        assert!(parser.parse().is_err());
    }

    #[test]
    fn rar_backend_rejects_non_rar() {
        if !rar_supported() {
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("fake.cbr");
        std::fs::write(&path, b"not a rar").unwrap();
        // 应明确失败而不是 panic
        #[cfg(windows)]
        assert!(RarArchiveReader::open(&path).is_err());
    }

    #[test]
    fn rar_supported_flag() {
        // Windows 启用；其它平台明确 false（APK 走 CBZ/ZIP）
        #[cfg(windows)]
        assert!(rar_supported());
        #[cfg(not(windows))]
        assert!(!rar_supported());
    }
}
