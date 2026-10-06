//! PDF 解析（lopdf）：mmap/整读文件后**按页按需**取文本或扫描图
//!
//! 大文件策略：
//! - 打开只解析结构 + 页数，不提取全文
//! - `get_chapter_content` 按章（页块）提取文本
//! - 扫描页：提取内嵌 XObject 图（JPEG 原样 / 位图转 PNG）
//! - 单页对象用后即弃，不常驻像素/全书文本

use crate::ccitt_fax::{decode_ccitt, CcittParams};
use crate::traits::{BookFormat, BookMetadata, BookParser, ChapterInfo, ResourceType};
use anyhow::{anyhow, bail, Context, Result};
use lopdf::Stream;
use std::path::{Path, PathBuf};

/// 解码输出上限（防解压炸弹）
const MAX_DECODED: usize = 64 * 1024 * 1024;

/// 每「章」页数（无书签时的页块大小）
const PAGES_PER_CHAPTER: usize = 50;

/// 扫描页资源 href 前缀：`pdfimg:{page_index}:{xobj_index}`
pub const PDF_IMG_HREF_PREFIX: &str = "pdfimg:";

/// 页内图资源描述
#[derive(Debug, Clone)]
pub struct PdfPageImage {
    /// 资源 href（get_resource 用）
    pub href: String,
    pub width: u32,
    pub height: u32,
}

/// 单页内容类型
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PdfPageKind {
    Text,
    /// 扫描/纯图
    Image,
    Blank,
}

pub struct PdfParser {
    path: PathBuf,
    /// lopdf 文档（结构 + 页对象）；大文件仍需载入 xref，但不缓存全文
    doc: lopdf::Document,
    page_count: usize,
    chapters: Vec<ChapterInfo>,
    metadata: Option<BookMetadata>,
    /// 页对象号（顺序即页序）
    page_ids: Vec<lopdf::ObjectId>,
}

impl PdfParser {
    pub fn from_file(path: &Path) -> Result<Self> {
        let started = std::time::Instant::now();
        // lopdf::load 走 OS 读；超大文件由 OS 页缓存托管，不额外复制 Vec
        let doc = lopdf::Document::load(path)
            .map_err(|e| anyhow::anyhow!("PDF 解析失败: {e}"))
            .with_context(|| format!("打开 PDF: {}", path.display()))?;
        let pages = doc.get_pages();
        let page_count = pages.len();
        if page_count == 0 {
            anyhow::bail!("PDF 没有页面");
        }
        // println + [READER] 前缀：与 Dart readerTrace 控制台约定一致
        println!(
            "[READER][pdf] open pages={} ms={}",
            page_count,
            started.elapsed().as_millis()
        );
        let mut page_ids: Vec<_> = pages.values().copied().collect();
        // get_pages 的 BTreeMap key 为页对象号，不一定是页序；按 /Type /Page 顺序
        // 已由 lopdf 页树顺序保证（values 即页序）
        page_ids.truncate(page_count);
        let mut s = Self {
            path: path.to_path_buf(),
            doc,
            page_count,
            chapters: Vec::new(),
            metadata: None,
            page_ids,
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
            let Some(&page_id) = self.page_ids.get(p) else {
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

    /// 页文本量（判扫描页）
    pub fn page_text_len(&self, page_index: usize) -> usize {
        self.extract_pages_text(page_index, page_index + 1)
            .map(|s| s.chars().filter(|c| !c.is_whitespace()).count())
            .unwrap_or(0)
    }

    /// 页类型：**轻量**判定（扫描 PDF 禁止逐页解码内容流）
    ///
    /// 有内嵌大图 → Image（扫描/插画）；否则再看文本。
    pub fn page_kind(&self, page_index: usize) -> PdfPageKind {
        if self.list_page_images(page_index).next().is_some() {
            return PdfPageKind::Image;
        }
        if self.page_text_len(page_index) >= 1 {
            return PdfPageKind::Text;
        }
        PdfPageKind::Blank
    }

    fn page_resources_xobjects(&self, page_index: usize) -> Option<lopdf::Dictionary> {
        use lopdf::Object;
        let &page_id = self.page_ids.get(page_index)?;
        let page_dict = self.doc.get_dictionary(page_id).ok()?;
        // Resources 可为内联字典或 Reference
        let res_obj = page_dict.get(b"Resources").ok()?;
        let res = match res_obj {
            Object::Reference(id) => self.doc.get_dictionary(*id).ok()?,
            Object::Dictionary(d) => d,
            _ => return None,
        };
        let xobj = res.get(b"XObject").ok()?;
        match xobj {
            Object::Reference(id) => self.doc.get_dictionary(*id).ok().cloned(),
            Object::Dictionary(d) => Some(d.clone()),
            _ => None,
        }
    }

    /// 页内 XObject 图列表（href + 宽高）
    pub fn list_page_images(&self, page_index: usize) -> impl Iterator<Item = PdfPageImage> + '_ {
        let mut items = Vec::new();
        let Some(xobjs) = self.page_resources_xobjects(page_index) else {
            return items.into_iter();
        };
        let mut idx = 0usize;
        for (_name, obj) in xobjs.iter() {
            let id = match obj {
                lopdf::Object::Reference(id) => *id,
                _ => continue,
            };
            // 图 XObject 是 Stream，不能用 get_dictionary
            let Ok(lopdf::Object::Stream(stream)) = self.doc.get_object(id) else {
                continue;
            };
            let dict = &stream.dict;
            let is_image = dict
                .get(b"Subtype")
                .ok()
                .map(|s| s.as_name().map(|n| n == b"Image").unwrap_or(false))
                .unwrap_or(false);
            if !is_image {
                continue;
            }
            let width = dict
                .get(b"Width")
                .ok()
                .and_then(|o| o.as_i64().ok())
                .unwrap_or(0)
                .max(0) as u32;
            let height = dict
                .get(b"Height")
                .ok()
                .and_then(|o| o.as_i64().ok())
                .unwrap_or(0)
                .max(0) as u32;
            items.push(PdfPageImage {
                href: format!("{}{}:{}", PDF_IMG_HREF_PREFIX, page_index, idx),
                width,
                height,
            });
            idx += 1;
        }
        items.into_iter()
    }

    /// 诊断：页内第 n 张图的滤镜与 DecodeParms 摘要
    pub fn debug_image_filters(&self, page_index: usize, img_index: usize) -> String {
        use lopdf::Object;
        let Some(xobjs) = self.page_resources_xobjects(page_index) else {
            return "no xobjects".into();
        };
        let mut idx = 0usize;
        for (_name, obj) in xobjs.iter() {
            let id = match obj {
                Object::Reference(id) => *id,
                _ => continue,
            };
            let Ok(Object::Stream(stream)) = self.doc.get_object(id) else {
                continue;
            };
            let dict = &stream.dict;
            let is_image = dict
                .get(b"Subtype")
                .ok()
                .map(|s| s.as_name().map(|n| n == b"Image").unwrap_or(false))
                .unwrap_or(false);
            if !is_image {
                continue;
            }
            if idx != img_index {
                idx += 1;
                continue;
            }
            let filters = resolve_filter_names(&self.doc, dict)
                .map(|f| f.join("+"))
                .unwrap_or_else(|e| format!("filter-err:{e}"));
            let parms = resolve_decode_parms(&self.doc, dict, 0, 1)
                .map(|d| {
                    let k = dict_i64(&d, b"K", 0);
                    let cols = dict_i64(&d, b"Columns", 0);
                    let rows = dict_i64(&d, b"Rows", 0);
                    let b1 = dict_bool(&d, b"BlackIs1", false);
                    let align = dict_bool(&d, b"EncodedByteAlign", false);
                    format!("K={k} Columns={cols} Rows={rows} BlackIs1={b1} Align={align}")
                })
                .unwrap_or_else(|| "no-decodeparms".into());
            let w = dict_i64(dict, b"Width", 0);
            let h = dict_i64(dict, b"Height", 0);
            let bits = dict_i64(dict, b"BitsPerComponent", -1);
            let cs = dict
                .get(b"ColorSpace")
                .map(|o| format!("{o:?}"))
                .unwrap_or_default();
            let head = crate::ccitt_fax::peek_hex(&stream.content);
            return format!(
                "filters={filters} {parms} {w}x{h} bpc={bits} cs={cs} raw_len={} head=[{head}]",
                stream.content.len()
            );
        }
        "no image".into()
    }

    /// 提取页内第 n 张图字节（JPEG 原样 / 其它编成 PNG）
    ///
    /// 失败返回明确错误（含滤镜名），**绝不**返回空字节（T3：禁止空图入缓存）。
    pub fn extract_page_image(&self, page_index: usize, img_index: usize) -> Result<Vec<u8>> {
        use lopdf::Object;
        let xobjs = self
            .page_resources_xobjects(page_index)
            .ok_or_else(|| anyhow!("页无 XObject"))?;
        let mut idx = 0usize;
        for (_name, obj) in xobjs.iter() {
            let id = match obj {
                Object::Reference(id) => *id,
                _ => continue,
            };
            let Ok(Object::Stream(stream)) = self.doc.get_object(id) else {
                continue;
            };
            let dict = &stream.dict;
            let is_image = dict
                .get(b"Subtype")
                .ok()
                .map(|s| s.as_name().map(|n| n == b"Image").unwrap_or(false))
                .unwrap_or(false);
            if !is_image {
                continue;
            }
            if idx != img_index {
                idx += 1;
                continue;
            }
            let width = dict.get(b"Width").ok().and_then(|o| o.as_i64().ok()).unwrap_or(0).max(0) as u32;
            let height = dict.get(b"Height").ok().and_then(|o| o.as_i64().ok()).unwrap_or(0).max(0) as u32;
            let bits = dict
                .get(b"BitsPerComponent")
                .ok()
                .and_then(|o| o.as_i64().ok())
                .unwrap_or(8) as u8;

            let filters = resolve_filter_names(&self.doc, dict).unwrap_or_default();
            let filter_label = if filters.is_empty() {
                "Raw".to_string()
            } else {
                filters.join("+")
            };

            let data = self
                .decode_image_stream(stream, &filters, width, height, bits)
                .map_err(|e| anyhow!("本页无法解码（滤镜 {filter_label}）: {e}"))?;

            if data.is_empty() {
                bail!("本页无法解码（滤镜 {filter_label}）: 解出空数据");
            }
            return Ok(data);
        }
        anyhow::bail!("页内无图: {page_index}#{img_index}")
    }

    /// 按滤镜链解码图像流 → JPEG 字节或 PNG 字节
    fn decode_image_stream(
        &self,
        stream: &Stream,
        filters: &[String],
        width: u32,
        height: u32,
        bits: u8,
    ) -> Result<Vec<u8>> {
        use lopdf::Object;
        let mut data = stream.content.clone();
        let mut i = 0usize;
        while i < filters.len() {
            let name = filters[i].as_str();
            let parms = resolve_decode_parms(&self.doc, &stream.dict, i, filters.len());
            match name {
                "DCTDecode" => {
                    // JPEG 比特流即结果（后续不应再有压缩滤镜）
                    if i + 1 < filters.len() {
                        bail!("DCTDecode 后还有滤镜 {}", &filters[i + 1..].join("+"));
                    }
                    return Ok(data);
                }
                "JPXDecode" => {
                    bail!("本页为 JPEG2000（JPXDecode），暂不支持");
                }
                "CCITTFaxDecode" => {
                    let params = ccitt_params_from(parms.as_ref(), width);
                    let img = decode_ccitt(&data, &params)?;
                    // T.4 输出 1=黑；直接出灰度 PNG
                    let png = encode_1bpp_png(&img.data, img.width, img.height)?;
                    return Ok(png);
                }
                "FlateDecode" | "LZWDecode" | "ASCIIHexDecode" | "ASCII85Decode"
                | "RunLengthDecode" | "BrotliDecode" => {
                    data = decode_simple_filter(name, &data, parms.as_ref())?;
                }
                other => bail!("不支持的滤镜 {other}"),
            }
            i += 1;
        }
        // 无图像压缩滤镜：原始采样 → PNG
        if bits == 1 {
            return encode_1bpp_png(&data, width, height);
        }
        encode_raw_png(&data, width, height, bits)
    }
}

/// 解析 Filter 名列表（Name / Array / **间接引用**）
fn resolve_filter_names(doc: &lopdf::Document, dict: &lopdf::Dictionary) -> Result<Vec<String>> {
    use lopdf::Object;
    let mut obj = dict
        .get(b"Filter")
        .map_err(|_| anyhow!("图像无 Filter"))?;
    for _ in 0..8 {
        match obj {
            Object::Reference(id) => {
                obj = doc
                    .get_object(*id)
                    .map_err(|e| anyhow!("Filter 引用解析失败: {e}"))?;
            }
            _ => break,
        }
    }
    match obj {
        Object::Name(n) => Ok(vec![String::from_utf8_lossy(n).into_owned()]),
        Object::Array(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for item in arr {
                let mut it = item;
                for _ in 0..8 {
                    match it {
                        Object::Reference(id) => {
                            it = doc
                                .get_object(*id)
                                .map_err(|e| anyhow!("Filter 数组项引用失败: {e}"))?;
                        }
                        _ => break,
                    }
                }
                match it {
                    Object::Name(n) => out.push(String::from_utf8_lossy(n).into_owned()),
                    other => bail!("Filter 数组项不是 Name: {other:?}"),
                }
            }
            Ok(out)
        }
        other => bail!("Filter 类型非法: {other:?}"),
    }
}

/// 取第 i 层滤镜的 DecodeParms（兼容 Reference 与 Array）
fn resolve_decode_parms(
    doc: &lopdf::Document,
    dict: &lopdf::Dictionary,
    filter_index: usize,
    filter_count: usize,
) -> Option<lopdf::Dictionary> {
    use lopdf::Object;
    let mut obj = dict.get(b"DecodeParms").ok()?;
    for _ in 0..8 {
        match obj {
            Object::Reference(id) => obj = doc.get_object(*id).ok()?,
            _ => break,
        }
    }
    match obj {
        Object::Dictionary(d) => {
            if filter_count <= 1 {
                Some(d.clone())
            } else {
                None
            }
        }
        Object::Array(arr) => {
            let mut it = arr.get(filter_index)?;
            for _ in 0..8 {
                match it {
                    Object::Reference(id) => it = doc.get_object(*id).ok()?,
                    Object::Null => return None,
                    _ => break,
                }
            }
            match it {
                Object::Dictionary(d) => Some(d.clone()),
                _ => None,
            }
        }
        Object::Null => None,
        _ => None,
    }
}

fn dict_i64(d: &lopdf::Dictionary, key: &[u8], default: i64) -> i64 {
    d.get(key).ok().and_then(|o| o.as_i64().ok()).unwrap_or(default)
}

fn dict_bool(d: &lopdf::Dictionary, key: &[u8], default: bool) -> bool {
    use lopdf::Object;
    match d.get(key).ok() {
        Some(Object::Boolean(b)) => *b,
        Some(Object::Integer(i)) => *i != 0,
        _ => default,
    }
}

/// 单层非图像滤镜解码（借 lopdf 临时 Stream）
fn decode_simple_filter(
    name: &str,
    input: &[u8],
    parms: Option<&lopdf::Dictionary>,
) -> Result<Vec<u8>> {
    use lopdf::Object;
    let mut d = lopdf::Dictionary::new();
    d.set("Filter", Object::Name(name.as_bytes().to_vec()));
    if let Some(p) = parms {
        d.set("DecodeParms", Object::Dictionary(p.clone()));
    }
    let stream = Stream::new(d, input.to_vec());
    stream
        .decompressed_content_with_limit(MAX_DECODED)
        .with_context(|| format!("滤镜 {name} 解压失败"))
}

/// CCITT DecodeParms
fn ccitt_params_from(parms: Option<&lopdf::Dictionary>, width_hint: u32) -> CcittParams {
    let mut p = CcittParams {
        columns: if width_hint > 0 {
            width_hint
        } else {
            1728
        },
        ..Default::default()
    };
    if let Some(d) = parms {
        p.k = dict_i64(d, b"K", 0) as i32;
        let cols = dict_i64(d, b"Columns", 0);
        if cols > 0 {
            p.columns = cols as u32;
        }
        p.rows = dict_i64(d, b"Rows", 0).max(0) as u32;
        p.black_is1 = dict_bool(d, b"BlackIs1", false);
        p.encoded_byte_align = dict_bool(d, b"EncodedByteAlign", false);
    }
    p
}

/// 1bpp（T.4 解码输出，**恒为 1=黑**）→ 8bit 灰度 PNG
///
/// PDF `BlackIs1` 描述的是样本极性，T.4 游程解码后视觉极性固定为 1=黑；
/// 显示端（PNG 0=黑/255=白）直接按 1=黑 映射即可。
fn encode_1bpp_png(packed: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    if width == 0 || height == 0 {
        bail!("图像尺寸非法");
    }
    let row_bytes = ((width as usize) + 7) / 8;
    if packed.len() < row_bytes * height as usize {
        bail!("1bpp 数据长度不足");
    }
    let n = width as usize * height as usize;
    let mut gray = vec![255u8; n];
    for y in 0..height as usize {
        for x in 0..width as usize {
            let byte = packed[y * row_bytes + x / 8];
            let bit = (byte >> (7 - (x % 8))) & 1;
            if bit == 1 {
                gray[y * width as usize + x] = 0;
            }
        }
    }
    encode_raw_png(&gray, width, height, 8)
}

/// 是否为可显示的图片字节（JPEG/PNG 魔数，且非空）
pub fn is_valid_image_bytes(b: &[u8]) -> bool {
    if b.len() < 8 {
        return false;
    }
    // JPEG
    if b[0] == 0xFF && b[1] == 0xD8 {
        return true;
    }
    // PNG
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return true;
    }
    // GIF
    if b.starts_with(b"GIF8") {
        return true;
    }
    // WEBP
    if b.len() >= 12 && &b[..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return true;
    }
    false
}

/// 原始采样 → PNG（8bit Gray 或 RGB）
fn encode_raw_png(data: &[u8], width: u32, height: u32, bits: u8) -> Result<Vec<u8>> {
    if width == 0 || height == 0 {
        anyhow::bail!("图像尺寸非法");
    }
    if bits != 8 {
        anyhow::bail!("暂只支持 8bpc 位图（实为 {bits}）");
    }
    let n = width as usize * height as usize;
    let (color_type, channels) = if data.len() >= n * 3 {
        (2u8, 3usize) // RGB
    } else if data.len() >= n {
        (0u8, 1usize) // Gray
    } else {
        anyhow::bail!("位图数据长度不足");
    };
    // 每行前加 filter=0
    let mut raw = Vec::with_capacity(height as usize * (1 + width as usize * channels));
    for y in 0..height as usize {
        raw.push(0);
        let off = y * width as usize * channels;
        let end = (off + width as usize * channels).min(data.len());
        if off < data.len() {
            raw.extend_from_slice(&data[off..end]);
            raw.resize(raw.len() + (width as usize * channels - (end - off)), 0);
        } else {
            raw.resize(raw.len() + width as usize * channels, 0);
        }
    }
    let mut png = vec![
        0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A,
    ];
    // IHDR
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.push(8); // bit depth
    ihdr.push(color_type);
    ihdr.extend_from_slice(&[0, 0, 0]); // comp/filter/interlace
    push_png_chunk(&mut png, b"IHDR", &ihdr);
    // IDAT（zlib）
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;
    let mut z = ZlibEncoder::new(Vec::new(), Compression::default());
    z.write_all(&raw)?;
    let idat = z.finish()?;
    push_png_chunk(&mut png, b"IDAT", &idat);
    push_png_chunk(&mut png, b"IEND", &[]);
    Ok(png)
}

fn push_png_chunk(out: &mut Vec<u8>, tag: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(tag);
    out.extend_from_slice(data);
    let mut crc_data = tag.to_vec();
    crc_data.extend_from_slice(data);
    out.extend_from_slice(&crc32_png(&crc_data).to_be_bytes());
}

fn crc32_png(data: &[u8]) -> u32 {
    // 标准 CRC-32（ISO 3309 / PNG）
    let mut crc = 0xFFFF_FFFFu32;
    for &b in data {
        crc ^= b as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
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

    fn get_resource(&self, resource_id: &str) -> Result<Vec<u8>> {
        // 扫描页图：pdfimg:{page}:{n}
        if let Some(rest) = resource_id.strip_prefix(PDF_IMG_HREF_PREFIX) {
            let mut it = rest.splitn(2, ':');
            let page: usize = it
                .next()
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| anyhow::anyhow!("非法 PDF 图 href"))?;
            let idx: usize = it
                .next()
                .and_then(|s| s.parse().ok())
                .ok_or_else(|| anyhow::anyhow!("非法 PDF 图 href"))?;
            return self.extract_page_image(page, idx);
        }
        anyhow::bail!("未知 PDF 资源: {resource_id}")
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
        assert_eq!(p.page_kind(0), PdfPageKind::Text);
    }

    /// 扫描页：无文字 + 内嵌图 → page_kind=Image，可 get_resource
    #[test]
    fn scanned_page_extracts_image() {
        // 2x2 RGB 未压缩图（Flate 由测试端预压）
        let raw = [255u8, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0]; // 2x2 RGB
        let mut enc = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut enc, &raw).unwrap();
        let idat = enc.finish().unwrap();
        let mut s = String::from("%PDF-1.4\n");
        let objs: Vec<String> = vec![
            "1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n".into(),
            "2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n".into(),
            "3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources<< /XObject<< /Im1 5 0 R >> >> >>endobj\n".into(),
            format!(
                "4 0 obj<< /Length {} >>stream\nBT ET\nendstream\nendobj\n",
                6
            ),
            format!(
                "5 0 obj<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {} >>stream\n",
                idat.len()
            ),
        ];
        let mut body = s.clone().into_bytes();
        let mut offsets = Vec::new();
        for (i, o) in objs.iter().enumerate() {
            offsets.push(body.len());
            body.extend_from_slice(o.as_bytes());
            if i == 4 {
                body.extend_from_slice(&idat);
                body.extend_from_slice(b"\nendstream\nendobj\n");
            }
        }
        let xref_pos = body.len();
        let mut xref = String::from("xref\n0 6\n0000000000 65535 f \n");
        for off in &offsets {
            xref.push_str(&format!("{:010} 00000 n \n", off));
        }
        xref.push_str(&format!(
            "trailer<< /Size 6 /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n",
            xref_pos
        ));
        body.extend_from_slice(xref.as_bytes());

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("scan.pdf");
        std::fs::write(&path, &body).unwrap();
        let p = PdfParser::from_file(&path).expect("扫描 PDF 打开");
        let imgs: Vec<_> = p.list_page_images(0).collect();
        assert_eq!(p.page_kind(0), PdfPageKind::Image);
        assert_eq!(imgs.len(), 1);
        assert_eq!(imgs[0].width, 2);
        assert_eq!(imgs[0].height, 2);
        let bytes = p.get_resource(&imgs[0].href).expect("取扫描图");
        assert!(bytes.starts_with(&[0x89, b'P', b'N', b'G']), "应为 PNG");
    }

    /// T4：有效图魔数嗅探
    #[test]
    fn is_valid_image_bytes_sniff() {
        assert!(is_valid_image_bytes(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]));
        assert!(is_valid_image_bytes(&[
            0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A
        ]));
        assert!(!is_valid_image_bytes(&[]));
        assert!(!is_valid_image_bytes(&[0x00, 0x01, 0x02, 0x03, 0, 0, 0, 0]));
    }

    /// T3：不支持的滤镜 → 明确错误文案，且不含空字节成功
    #[test]
    fn extract_unsupported_filter_error_message() {
        let mut s = String::from("%PDF-1.4\n");
        let objs: Vec<String> = vec![
            "1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj\n".into(),
            "2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj\n".into(),
            "3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] /Resources<< /XObject<< /Im1 5 0 R >> >> >>endobj\n".into(),
            "4 0 obj<< /Length 6 >>stream\nBT ET\nendstream\nendobj\n".into(),
            // JPXDecode：当前明确报「暂不支持」
            "5 0 obj<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /JPXDecode /Length 4 >>stream\nXXXX\nendstream\nendobj\n".into(),
        ];
        let mut body = s.clone().into_bytes();
        let mut offsets = Vec::new();
        for o in &objs {
            offsets.push(body.len());
            body.extend_from_slice(o.as_bytes());
        }
        let xref_pos = body.len();
        let mut xref = String::from("xref\n0 6\n0000000000 65535 f \n");
        for off in &offsets {
            xref.push_str(&format!("{:010} 00000 n \n", off));
        }
        xref.push_str(&format!(
            "trailer<< /Size 6 /Root 1 0 R >>\nstartxref\n{}\n%%EOF\n",
            xref_pos
        ));
        body.extend_from_slice(xref.as_bytes());

        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("jpx.pdf");
        std::fs::write(&path, &body).unwrap();
        let p = PdfParser::from_file(&path).expect("打开");
        let err = p.extract_page_image(0, 0).unwrap_err().to_string();
        assert!(
            err.contains("本页无法解码") || err.contains("JPX") || err.contains("JPEG2000"),
            "错误文案应可读，实得: {err}"
        );
    }
}
