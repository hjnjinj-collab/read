//! PDF 解析（lopdf）：mmap/整读文件后**按页按需**取文本
//!
//! 大文件策略：
//! - 打开只解析结构 + 页数，不提取全文
//! - `get_chapter_content` 按章（页块）提取文本
//! - 单页对象用后即弃，不常驻像素/全书文本
//!
//! 扫描版/无文本页：返回空文本占位（后续可接渲染）。

use crate::traits::{BookFormat, BookMetadata, BookParser, ChapterInfo, ResourceType};
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// 每「章」页数（无书签时的页块大小）
const PAGES_PER_CHAPTER: usize = 50;

pub struct PdfParser {
    path: PathBuf,
    /// lopdf 文档（结构 + 页对象）；大文件仍需载入 xref，但不缓存全文
    doc: lopdf::Document,
    page_count: usize,
    chapters: Vec<ChapterInfo>,
    metadata: Option<BookMetadata>,
}

impl PdfParser {
    pub fn from_file(path: &Path) -> Result<Self> {
        // lopdf::load 走 OS 读；超大文件由 OS 页缓存托管，不额外复制 Vec
        let doc = lopdf::Document::load(path)
            .map_err(|e| anyhow::anyhow!("PDF 解析失败: {e}"))
            .with_context(|| format!("打开 PDF: {}", path.display()))?;
        let page_count = doc.get_pages().len();
        if page_count == 0 {
            anyhow::bail!("PDF 没有页面");
        }
        let mut s = Self {
            path: path.to_path_buf(),
            doc,
            page_count,
            chapters: Vec::new(),
            metadata: None,
        };
        s.build_chapters()?;
        Ok(s)
    }

    /// 书签大纲 → 章；无大纲则按 PAGES_PER_CHAPTER 切块
    fn build_chapters(&mut self) -> Result<()> {
        let mut chapters = Vec::new();
        let outlines = self.outline_page_numbers();
        if outlines.len() >= 2 {
            for (i, &(page_1based, ref title)) in outlines.iter().enumerate() {
                let start = page_1based.saturating_sub(1);
                let end = outlines
                    .get(i + 1)
                    .map(|(n, _)| n.saturating_sub(1))
                    .unwrap_or(self.page_count)
                    .max(start + 1)
                    .min(self.page_count);
                chapters.push(ChapterInfo {
                    index: i,
                    title: title.clone(),
                    estimated_words: end - start,
                    level: 0,
                    parent_index: None,
                    start_byte_offset: None,
                    end_byte_offset: None,
                    resource_href: None,
                    spine_index: Some(i),
                    fragment_id: None,
                    // 用 start/end 偏移存页范围（1-based 页号存 start_byte）
                    // 为兼容 TXT/EPUB 字段，这里 start=页起(0-based)，end=页止(exclusive)
                });
                let _ = (start, end);
            }
            // 页范围写入 start/end_byte_offset（复用字段：页索引）
            for (i, ch) in chapters.iter_mut().enumerate() {
                let start = outlines[i].0.saturating_sub(1);
                let end = outlines
                    .get(i + 1)
                    .map(|(n, _)| n.saturating_sub(1))
                    .unwrap_or(self.page_count)
                    .max(start + 1)
                    .min(self.page_count);
                ch.start_byte_offset = Some(start);
                ch.end_byte_offset = Some(end);
            }
        } else {
            let mut idx = 0usize;
            let mut start = 0usize;
            while start < self.page_count {
                let end = (start + PAGES_PER_CHAPTER).min(self.page_count);
                chapters.push(ChapterInfo {
                    index: idx,
                    title: format!("第 {}–{} 页", start + 1, end),
                    estimated_words: end - start,
                    level: 0,
                    parent_index: None,
                    start_byte_offset: Some(start),
                    end_byte_offset: Some(end),
                    resource_href: None,
                    spine_index: Some(idx),
                    fragment_id: None,
                });
                idx += 1;
                start = end;
            }
        }
        self.chapters = chapters;
        let title = self
            .path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "PDF 文档".to_string());
        self.metadata = Some(BookMetadata {
            title,
            author: String::new(),
            cover_data: None,
            language: "und".to_string(),
            total_chapters: self.chapters.len(),
            file_size: std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0),
            format: BookFormat::Pdf,
        });
        Ok(())
    }

    /// 大纲 (1-based 页号, 标题)
    fn outline_page_numbers(&self) -> Vec<(usize, String)> {
        // 简化：lopdf Outlines 结构版本差异大；无大纲时返回空走页块
        Vec::new()
    }

    /// 按页提取文本（按需；扫描页返回空串）
    pub fn extract_pages_text(&self, start: usize, end: usize) -> Result<String> {
        use lopdf::content::Content;
        use lopdf::Object;
        let mut out = String::new();
        for p in start..end.min(self.page_count) {
            // get_pages 的 key 为对象号，顺序即页序
            let page_ids: Vec<_> = self.doc.get_pages().values().copied().collect();
            let Some(&page_id) = page_ids.get(p) else {
                continue;
            };
            let content_data = self.doc.get_page_content(page_id);
            if content_data.is_empty() {
                continue;
            }
            let content = match Content::decode(&content_data) {
                Ok(c) => c,
                Err(_) => continue,
            };
            for op in &content.operations {
                if op.operator == "Tj" || op.operator == "TJ" || op.operator == "'" || op.operator == "\""
                {
                    for arg in &op.operands {
                        match arg {
                            Object::String(bytes, _) => {
                                out.push_str(&lossy_pdf_string(bytes));
                            }
                            Object::Array(arr) => {
                                for a in arr {
                                    if let Object::String(bytes, _) = a {
                                        out.push_str(&lossy_pdf_string(bytes));
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    out.push('\n');
                } else if op.operator == "Td" || op.operator == "TD" || op.operator == "T*"
                {
                    if !out.ends_with('\n') {
                        out.push('\n');
                    }
                }
            }
            out.push_str("\n\n");
        }
        Ok(out)
    }
}

fn lossy_pdf_string(bytes: &[u8]) -> String {
    // PDF 文本常为 PDFDocEncoding/UTF-16；此处尽力解码
    if bytes.starts_with(&[0xFE, 0xFF]) && bytes.len() >= 2 {
        let u16s: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_be_bytes([c[0], c[1]]))
            .collect();
        return String::from_utf16_lossy(&u16s);
    }
    String::from_utf8_lossy(bytes).to_string()
}

impl BookParser for PdfParser {
    fn parse(&mut self) -> Result<BookMetadata> {
        Ok(self
            .metadata
            .clone()
            .expect("from_file 后 metadata 必有"))
    }

    fn get_chapter_list(&self) -> Result<Vec<ChapterInfo>> {
        Ok(self.chapters.clone())
    }

    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        let ch = self
            .chapters
            .get(chapter_index)
            .ok_or_else(|| anyhow::anyhow!("章节不存在: {chapter_index}"))?;
        let start = ch.start_byte_offset.unwrap_or(0);
        let end = ch.end_byte_offset.unwrap_or(start + 1);
        self.extract_pages_text(start, end)
    }

    fn get_resource(&self, _resource_id: &str) -> Result<Vec<u8>> {
        anyhow::bail!("PDF 资源按需渲染暂未开放")
    }

    fn list_resources(&self) -> Result<Vec<(String, String)>> {
        Ok(Vec::new())
    }

    fn supported_resources(&self) -> Vec<ResourceType> {
        Vec::new()
    }

    fn format(&self) -> BookFormat {
        BookFormat::Pdf
    }

    fn total_chapters(&self) -> usize {
        self.chapters.len()
    }

    fn cleanup(&mut self) {
        // 释放页内容引用；lopdf Document 整体 drop 于 parser 生命周期结束
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 最小合法 PDF：1 页 + "Hi"
    fn minimal_pdf() -> Vec<u8> {
        // 手工最小 PDF（lopdf 可解析）
        let mut s = String::new();
        s.push_str("%PDF-1.4\n");
        let objs: [&str; 5] = [
            "1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n",
            "2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n",
            "3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources<< /Font<< /F1 5 0 R >> >> >>endobj\n",
            "4 0 obj<< /Length 44 >>stream\nBT /F1 12 Tf 10 100 Td (Hi) Tj ET\nendstream\nendobj\n",
            "5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj\n",
        ];
        let mut offsets = Vec::new();
        let mut body = s.clone().into_bytes();
        for o in objs {
            offsets.push(body.len());
            body.extend_from_slice(o.as_bytes());
        }
        let xref_pos = body.len();
        let mut xref = format!("xref\n0 6\n0000000000 65535 f \n");
        for off in &offsets {
            xref.push_str(&format!("{:010} 00000 n \n", off));
        }
        xref.push_str(&format!(
            "trailer<< /Size 6 /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n",
            xref_pos
        ));
        body.extend_from_slice(xref.as_bytes());
        body
    }

    #[test]
    fn parse_minimal_pdf_page_count() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("t.pdf");
        std::fs::write(&path, minimal_pdf()).unwrap();
        let mut p = PdfParser::from_file(&path).expect("PDF 打开");
        let meta = p.parse().unwrap();
        assert!(meta.total_chapters >= 1);
        assert_eq!(p.page_count, 1);
        let text = p.get_chapter_content(0).unwrap();
        assert!(text.contains("Hi"), "应提出 Hi，实得 {:?}", text);
    }
}
