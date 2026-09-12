use crate::traits::{BookFormat, BookMetadata, BookParser, ChapterInfo, ResourceType};
use anyhow::{Context, Result};
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use lru::LruCache;
use std::num::NonZeroUsize;
use zip::ZipArchive;

// —— roxmltree 辅助：统一按「本地名」匹配，规避各实现的前缀差异 ——

/// 元素本地名是否等于指定名（忽略命名空间前缀）
///
/// 注意：roxmltree 的 `has_tag_name("x")` 只匹配无命名空间元素，
/// 带命名空间的 OPF/NCX 必须经 `tag_name().name()` 取本地名比较。
fn tag_is(node: roxmltree::Node<'_, '_>, local: &str) -> bool {
    node.tag_name().name() == local
}

/// 按属性本地名取值（不区分命名空间）
fn attr_local<'a, 'input>(node: roxmltree::Node<'a, 'input>, local: &str) -> Option<&'a str> {
    node.attributes()
        .into_iter()
        .find(|a| a.name() == local)
        .map(|a| a.value())
}

/// 收集节点内全部文本（含后代文本节点与 CDATA；实体已由解析器解码）
fn text_of<'a, 'input>(node: roxmltree::Node<'a, 'input>) -> String {
    node.descendants()
        .filter(|d| d.is_text())
        .filter_map(|d| d.text())
        .collect::<String>()
        .trim()
        .to_string()
}

/// Dublin Core 命名空间（metadata 键名归一化为 dc:* 用）
const DC_NAMESPACE: &str = "http://purl.org/dc/elements/1.1/";

/// ruby 注音默认字号倍率（rt 小字跟随；CSS font-size 命中时覆盖）
const RUBY_SCALE: f32 = 0.5;

/// px/pt 字号换算的默认基准字号。与 LayoutConfig 默认 font_size
/// （layout_engine lib.rs）及 Dart 绘制端基准 18 三方一致；
/// 阅读路径经 get_chapter_content_structured_ex 传实际排版字号覆盖
pub const DEFAULT_BASE_FONT_PX: f32 = 18.0;

/// 结构性 XML 解析选项
///
/// 真实书籍的 container/OPF/NCX 常带 `<!DOCTYPE ... DTD>` 声明，
/// roxmltree 默认（allow_dtd=false）直接报「XML with DTD detected」
/// 导致整个目录解析失败——必须显式放开；roxmltree 不加载外部 DTD、
/// 内部实体有展开限制，本地受信文件无 XXE 风险。节点上限作恶意文件加固。
const XML_PARSE_OPTIONS: roxmltree::ParsingOptions = roxmltree::ParsingOptions {
    allow_dtd: true,
    nodes_limit: 1_000_000,
};

/// OPF 解析结果（内部传递用）
struct OpfData {
    /// metadata 键值（Dublin Core 归一化为 dc:* 键，其余按本地名）
    metadata: HashMap<String, String>,
    /// spine 顺序的完整路径（已合并 OPF 目录）
    spine_hrefs: Vec<String>,
    /// EPUB3 导航文档 href（manifest properties 含 "nav"，相对 OPF 目录）
    nav_href: Option<String>,
    /// NCX href（manifest media-type 为 X-DTBNCX，相对 OPF 目录）
    ncx_href: Option<String>,
    /// 封面图 href（EPUB3 properties="cover-image" 或 EPUB2 meta[name=cover]，
    /// 相对 OPF 目录）
    cover_href: Option<String>,
    /// duokan-page-fullscreen 全屏页（itemref properties 声明，
    /// 已合并 OPF 目录；如《剑来》封面页）
    fullscreen_hrefs: HashSet<String>,
}

/// TOC 条目（文档序；键已在插入时解析为 ZIP 内完整路径）
#[derive(Debug, Clone)]
struct TocEntry {
    /// ZIP 内完整路径（片段标识符已剥离）
    href_full: String,
    /// 目录标题
    title: String,
    /// 目录层级：1=顶层（1 + 嵌套深度）
    level: u8,
}

/// 以 base_dir 为基准把相对路径规范化为 ZIP 内路径（处理 `./` 与 `../`）
pub(crate) fn resolve_zip_path(base_dir: &str, rel: &str) -> String {
    let combined = if base_dir.is_empty() {
        rel.to_string()
    } else {
        format!("{}/{}", base_dir.trim_end_matches('/'), rel)
    };
    let mut parts: Vec<&str> = Vec::new();
    for seg in combined.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// ZIP 路径的父目录（无目录时为空串）
fn zip_parent_dir(path: &str) -> String {
    path.rsplit_once('/')
        .map(|(d, _)| d.to_string())
        .unwrap_or_default()
}

/// 资源缓存（用于缓存图片、字体等资源）
struct ResourceCache {
    cache: LruCache<String, Vec<u8>>,
}

impl ResourceCache {
    fn new(capacity: usize) -> Self {
        Self {
            cache: LruCache::new(NonZeroUsize::new(capacity).unwrap_or(NonZeroUsize::new(1).unwrap())),
        }
    }

    fn get(&mut self, key: &str) -> Option<Vec<u8>> {
        self.cache.get(key).cloned()
    }

    fn put(&mut self, key: String, value: Vec<u8>) {
        self.cache.put(key, value);
    }

    fn clear(&mut self) {
        self.cache.clear();
    }
}

/// EPUB 解析器
///
/// 解析 EPUB 格式电子书，提取元信息和章节结构。
/// EPUB 本质上是 ZIP 包，包含 XHTML 内容文件、OPF 描述和 NCX/NAV 目录。
pub struct EpubParser {
    /// 文件路径
    file_path: PathBuf,
    /// ZIP 归档（保持打开状态以按需读取章节）
    ///
    /// 内部互斥：by_name/by_index 需 &mut，包 Mutex 后资源读取可走
    /// &self——bridge 侧 get_book_resource 慢路径不再需要 BOOKS 写锁
    /// （见 lib.rs BOOKS 审计清单热点 4）。锁序：archive 锁与
    /// resource_cache 锁从不同时持有。
    archive: Mutex<Option<ZipArchive<File>>>,
    /// 元信息（parse 后填充）
    metadata: Option<BookMetadata>,
    /// 章节列表（parse 后填充）
    chapters: Vec<ChapterInfo>,
    /// OPF 基路径（用于解析相对路径）
    opf_base_path: String,
    /// spine 顺序：href 列表
    spine_hrefs: Vec<String>,
    /// href → 压缩文件索引的映射
    href_to_index: HashMap<String, usize>,
    /// 资源缓存
    resource_cache: Arc<Mutex<ResourceCache>>,
    /// EPUB3 导航文档 href（OPF properties="nav" 声明，相对 OPF 目录）
    nav_href: Option<String>,
    /// NCX href（OPF media-type 声明，相对 OPF 目录）
    ncx_href: Option<String>,
    /// 已解析样式表缓存（键=ZIP 内路径；parser 生命周期=书会话）
    ///
    /// 内部互斥：与 archive 同模式——get_chapter_content_structured_ex
    /// 降为 &self 后，搜索/分页的 IR 提取不再需要 BOOKS 写锁。
    /// 锁序：css_cache 锁与 archive 锁分段持有，从不嵌套。
    css_cache: Mutex<HashMap<String, std::sync::Arc<crate::css_lite::CssStylesheet>>>,
    /// duokan-page-fullscreen 全屏页集合（ZIP 内完整路径）
    fullscreen_hrefs: HashSet<String>,
}

impl EpubParser {
    /// 从文件路径创建 EPUB 解析器
    pub fn from_file(path: &Path) -> Result<Self> {
        let file = File::open(path)
            .with_context(|| format!("无法打开 EPUB 文件: {}", path.display()))?;
        let archive = ZipArchive::new(file)
            .with_context(|| format!("无法解析 EPUB (ZIP) 文件: {}", path.display()))?;

        Ok(Self {
            file_path: path.to_path_buf(),
            archive: Mutex::new(Some(archive)),
            metadata: None,
            chapters: Vec::new(),
            opf_base_path: String::new(),
            spine_hrefs: Vec::new(),
            href_to_index: HashMap::new(),
            resource_cache: Arc::new(Mutex::new(ResourceCache::new(150))),  // 阶段1优化：50→150
            nav_href: None,
            ncx_href: None,
            css_cache: Mutex::new(HashMap::new()),
            fullscreen_hrefs: HashSet::new(),
        })
    }

    /// 读取 ZIP 中指定文件的内容为字符串
    fn read_entry_as_string(&self, index: usize) -> Result<String> {
        let mut guard = self.archive.lock().unwrap();
        let archive = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ZIP 归档已关闭"))?;

        let mut entry = archive.by_index(index)
            .with_context(|| format!("无法读取 ZIP 索引 {}", index))?;

        let mut content = String::new();
        entry.read_to_string(&mut content)
            .with_context(|| format!("无法解码文件内容，索引: {}", index))?;

        Ok(content)
    }

    /// 按名称查找 ZIP 条目的索引
    fn find_entry_index(archive: &mut ZipArchive<File>, name: &str) -> Option<usize> {
        for i in 0..archive.len() {
            if let Ok(entry) = archive.by_index(i) {
                if entry.name() == name {
                    return Some(i);
                }
            }
        }
        None
    }

    /// 按完整 ZIP 路径直读条目字节（O(1) 哈希查找 + 大小写不敏感兜底）
    ///
    /// 取代旧 get_resource 的 opf_base_path 拼接逻辑——结构化 IR 的
    /// resource_href 已是 ZIP 全路径，二次拼接反而语义错误（:626 既有缺陷）。
    /// EPUB 规范要求路径大小写规范，但真实书籍偶有出入，故保留一次
    /// 大小写不敏感遍历作兜底。
    fn get_zip_entry(&self, zip_path: &str) -> Result<Vec<u8>> {
        let mut guard = self.archive.lock().unwrap();
        let archive = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("ZIP 归档已关闭"))?;

        if let Ok(mut entry) = archive.by_name(zip_path) {
            let mut content = Vec::new();
            entry.read_to_end(&mut content)?;
            return Ok(content);
        }

        // 大小写不敏感兜底（O(n) 遍历仅发生在未命中时）
        for i in 0..archive.len() {
            let matched = match archive.by_index(i) {
                Ok(entry) => entry.name().eq_ignore_ascii_case(zip_path),
                Err(_) => false,
            };
            if matched {
                let mut entry = archive.by_index(i)?;
                let mut content = Vec::new();
                entry.read_to_end(&mut content)?;
                return Ok(content);
            }
        }

        anyhow::bail!("ZIP 中不存在条目: {}", zip_path)
    }

    /// 解析 container.xml 获取 OPF 路径（结构性 XML，走 roxmltree）
    fn parse_container(container_xml: &str) -> Result<String> {
        // container.xml 格式：
        // <container>
        //   <rootfiles>
        //     <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        //   </rootfiles>
        // </container>
        let doc = roxmltree::Document::parse_with_options(container_xml, XML_PARSE_OPTIONS)
            .map_err(|e| anyhow::anyhow!("container.xml 解析失败: {}", e))?;

        doc.root_element()
            .descendants()
            .find(|n| tag_is(*n, "rootfile"))
            .and_then(|n| attr_local(n, "full-path"))
            .map(|s| s.to_string())
            .ok_or_else(|| anyhow::anyhow!("container.xml 中未找到 rootfile"))
    }

    /// 解析 OPF 文件，提取元信息、spine 顺序与导航声明（结构性 XML，走 roxmltree）
    ///
    /// manifest/spine 遍历真实直接子节点——自闭合标签按 XML 规范闭合，
    /// 不再需要 HTML 解析器时代的「后代选择器」变通
    /// （html5ever 会把 <item/> 当开放标签，把后续兄弟嵌套其中）。
    fn parse_opf(opf_xml: &str, opf_dir: &str) -> Result<OpfData> {
        let doc = roxmltree::Document::parse_with_options(opf_xml, XML_PARSE_OPTIONS)
            .map_err(|e| anyhow::anyhow!("OPF 解析失败: {}", e))?;
        let root = doc.root_element();

        // metadata：键名归一化——Dublin Core 命名空间补 "dc:" 前缀，
        // 其余按本地名（与旧实现的 dc:title/title 双键读取习惯兼容）
        let mut metadata = HashMap::new();
        let mut epub2_cover_id: Option<String> = None;
        if let Some(meta_el) = root.descendants().find(|n| tag_is(*n, "metadata")) {
            for child in meta_el.children().filter(|c| c.is_element()) {
                // EPUB2 封面声明：<meta name="cover" content="<manifest item id>"/>
                if child.tag_name().name() == "meta"
                    && attr_local(child, "name") == Some("cover")
                {
                    if let Some(content) = attr_local(child, "content") {
                        epub2_cover_id = Some(content.to_string());
                    }
                    continue;
                }
                let key = match child.tag_name().namespace() {
                    Some(ns) if ns == DC_NAMESPACE => {
                        format!("dc:{}", child.tag_name().name())
                    }
                    _ => child.tag_name().name().to_string(),
                };
                let text = text_of(child);
                if !text.is_empty() {
                    metadata.insert(key, text);
                }
            }
        }

        // manifest：id → href；顺带发现导航声明（properties="nav" / NCX media-type）
        let mut id_to_href = HashMap::new();
        let mut nav_href = None;
        let mut ncx_href = None;
        let mut epub3_cover_href: Option<String> = None;
        if let Some(manifest_el) = root.descendants().find(|n| tag_is(*n, "manifest")) {
            for child in manifest_el.children().filter(|c| c.is_element()) {
                if !tag_is(child, "item") {
                    continue;
                }
                if let (Some(id), Some(href)) = (attr_local(child, "id"), attr_local(child, "href"))
                {
                    id_to_href.insert(id.to_string(), href.to_string());

                    if let Some(props) = attr_local(child, "properties") {
                        if props.split_whitespace().any(|p| p == "nav") && nav_href.is_none() {
                            nav_href = Some(href.to_string());
                        }
                        // EPUB3 封面声明
                        if props.split_whitespace().any(|p| p == "cover-image")
                            && epub3_cover_href.is_none()
                        {
                            epub3_cover_href = Some(href.to_string());
                        }
                    }
                    if attr_local(child, "media-type") == Some("application/x-dtbncx+xml")
                        && ncx_href.is_none()
                    {
                        ncx_href = Some(href.to_string());
                    }
                }
            }
        }

        // 封面 href 解析优先级：EPUB3 properties > EPUB2 meta[name=cover]
        let cover_href = epub3_cover_href.or_else(|| {
            epub2_cover_id.and_then(|id| id_to_href.get(&id).cloned())
        });

        // spine：itemref 的 idref 顺序即阅读顺序；顺带收集全屏页标记
        // （duokan-page-fullscreen：整页背景语义，如封面页）
        let mut spine_hrefs = Vec::new();
        let mut fullscreen_hrefs = HashSet::new();
        if let Some(spine_el) = root.descendants().find(|n| tag_is(*n, "spine")) {
            for child in spine_el.children().filter(|c| c.is_element()) {
                if !tag_is(child, "itemref") {
                    continue;
                }
                if let Some(idref) = attr_local(child, "idref") {
                    if let Some(href) = id_to_href.get(idref) {
                        // 合并 OPF 目录路径和 href
                        let full_path = if opf_dir.is_empty() {
                            href.clone()
                        } else {
                            format!("{}/{}", opf_dir.trim_end_matches('/'), href)
                        };
                        if attr_local(child, "properties")
                            .map(|p| {
                                p.split_whitespace().any(|t| t == "duokan-page-fullscreen")
                            })
                            .unwrap_or(false)
                        {
                            fullscreen_hrefs.insert(full_path.clone());
                        }
                        spine_hrefs.push(full_path);
                    }
                }
            }
        }

        Ok(OpfData {
            metadata,
            spine_hrefs,
            nav_href,
            ncx_href,
            cover_href,
            fullscreen_hrefs,
        })
    }

    /// 从 HTML 内容中提取纯文本
    pub fn html_to_text(html: &str) -> String {
        let doc = scraper::Html::parse_document(html);

        // 查找 body 元素
        let body_selector = scraper::Selector::parse("body")
            .map_err(|_| anyhow::anyhow!("无效的 CSS 选择器"))
            .ok();

        let body = body_selector.and_then(|sel| doc.select(&sel).next());

        if let Some(body) = body {
            // 从 body 提取文本
            Self::extract_element_text(body)
        } else {
            // 没有 body，从整个文档提取
            Self::extract_document_text(&doc)
        }
    }

    /// 从元素提取文本（递归）
    fn extract_element_text(element: scraper::ElementRef) -> String {
        let mut text = String::new();

        for node in element.children() {
            match node.value() {
                scraper::Node::Text(t) => {
                    let trimmed = t.text.trim();
                    if !trimmed.is_empty() {
                        text.push_str(trimmed);
                        text.push('\n');
                    }
                }
                scraper::Node::Element(el) => {
                    // 跳过 script 和 style
                    if el.name() == "script" || el.name() == "style" {
                        continue;
                    }
                    // 块级元素后加换行
                    let is_block = matches!(
                        el.name(),
                        "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                            | "br" | "li" | "blockquote" | "pre" | "tr"
                    );
                    // 递归处理子节点
                    if let Some(child_element) = scraper::ElementRef::wrap(node) {
                        text.push_str(&Self::extract_element_text(child_element));
                    }
                    if is_block {
                        text.push('\n');
                    }
                }
                _ => {}
            }
        }

        text
    }

    /// 从整个文档提取文本
    fn extract_document_text(doc: &scraper::Html) -> String {
        let mut text = String::new();
        // 遍历根节点的所有子节点
        for node in doc.root_element().children() {
            if let Some(element) = scraper::ElementRef::wrap(node) {
                text.push_str(&Self::extract_element_text(element));
            }
        }
        text
    }

    /// 获取文件大小
    fn file_size(&self) -> u64 {
        std::fs::metadata(&self.file_path)
            .map(|m| m.len())
            .unwrap_or(0)
    }

    /// 解析 TOC (toc.ncx 或 nav.xhtml)，返回文档序条目（键为 ZIP 全路径）
    ///
    /// 优先使用 OPF 中声明的导航文件（spec 正路：properties="nav" /
    /// media-type=X-DTBNCX）；缺失时退回旧的文件名猜测。
    /// NCX 优先于 EPUB3 nav，与旧版行为一致。
    ///
    /// 键解析基准是**实际读取的目录文件所在目录**——旧实现直接用相对
    /// TOC 文件的 src 与 spine 全路径做前缀匹配（方向反了），OPF 位于
    /// 子目录时标题永远无法命中。
    fn parse_toc(&mut self) -> Result<Vec<TocEntry>> {
        // 1. 尝试 NCX：OPF 声明优先，常见固定路径兜底
        let mut ncx_candidates: Vec<String> = Vec::new();
        if let Some(href) = &self.ncx_href {
            ncx_candidates.push(self.join_opf_dir(href));
        }
        for name in ["toc.ncx", "OEBPS/toc.ncx", "EPUB/toc.ncx"] {
            ncx_candidates.push(name.to_string());
        }
        for cand in &ncx_candidates {
            if let Some((actual, content)) = self.read_toc_candidate(cand) {
                let toc_dir = zip_parent_dir(&actual);
                match Self::parse_ncx(&content, &toc_dir) {
                    Ok(entries) if !entries.is_empty() => return Ok(entries),
                    Ok(_) => log::debug!("{} 未产出目录条目", actual),
                    Err(e) => log::warn!("解析 {} 失败: {}", actual, e),
                }
            }
        }

        // 2. 尝试 EPUB3 nav.xhtml：OPF 声明路径优先，文件名扫描兜底
        let nav_declared = self.nav_href.clone();
        if let Some(href) = nav_declared {
            let full = self.join_opf_dir(&href);
            if let Some(content) = self.read_file_by_name(&full) {
                let toc_dir = zip_parent_dir(&full);
                match Self::parse_nav_xhtml(&content, &toc_dir) {
                    Ok(entries) if !entries.is_empty() => return Ok(entries),
                    Ok(_) => log::debug!("{} 未产出目录条目", full),
                    Err(e) => log::warn!("解析 {} 失败: {}", full, e),
                }
            }
        }
        if let Some((name, content)) = self.find_nav_content() {
            let toc_dir = zip_parent_dir(&name);
            match Self::parse_nav_xhtml(&content, &toc_dir) {
                Ok(entries) if !entries.is_empty() => return Ok(entries),
                Ok(_) => log::debug!("{} 未产出目录条目", name),
                Err(e) => log::warn!("解析 {} 失败: {}", name, e),
            }
        }

        Ok(Vec::new())
    }

    /// 把相对 OPF 的 href 拼为完整 ZIP 内路径
    fn join_opf_dir(&self, href: &str) -> String {
        if self.opf_base_path.is_empty() {
            href.to_string()
        } else {
            format!("{}/{}", self.opf_base_path.trim_end_matches('/'), href)
        }
    }

    /// 读取指定名称的文件内容
    fn read_file_by_name(&mut self, name: &str) -> Option<String> {
        self.read_toc_candidate(name).map(|(_, c)| c)
    }

    /// 读取 TOC 候选文件，返回（实际命中的条目名, 内容）
    ///
    /// 精确名优先；其次任意目录下的同名尾段（旧版宽松行为的保留）。
    /// 返回实际条目名是为了让键解析使用**命中文件**的目录。
    fn read_toc_candidate(&mut self, name: &str) -> Option<(String, String)> {
        let mut guard = self.archive.lock().unwrap();
        let archive = guard.as_mut()?;
        let suffix_tail = format!("/{}", name);
        let mut fallback: Option<(String, String)> = None;
        for i in 0..archive.len() {
            if let Ok(mut entry) = archive.by_index(i) {
                let ename = entry.name().to_string();
                let is_exact = ename == name;
                let is_suffix = !is_exact && ename.ends_with(&suffix_tail);
                if !is_exact && !is_suffix {
                    continue;
                }
                let mut content = String::new();
                if entry.read_to_string(&mut content).is_ok() {
                    if is_exact {
                        return Some((ename, content));
                    }
                    if fallback.is_none() {
                        fallback = Some((ename, content));
                    }
                }
            }
        }
        fallback
    }

    /// 查找 nav.xhtml 文件，返回（实际条目名, 内容）
    fn find_nav_content(&mut self) -> Option<(String, String)> {
        // 先查找文件名
        let nav_filename = {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard.as_mut()?;
            let mut found = None;
            for i in 0..archive.len() {
                if let Ok(entry) = archive.by_index(i) {
                    let name = entry.name().to_string();
                    if name.ends_with(".nav.xhtml") || name.ends_with("nav.xhtml") {
                        found = Some(name);
                        break;
                    }
                }
            }
            found?
        };

        // 然后读取内容
        self.read_file_by_name(&nav_filename)
            .map(|c| (nav_filename, c))
    }

    /// 解析 NCX 格式的 TOC（roxmltree 单遍文档序扫描）
    ///
    /// XML 文档序保证父 navPoint 的 navLabel/content 先于其嵌套子 navPoint
    /// 出现，故单遍 descendants 过滤即可覆盖任意嵌套层级，无需树形递归。
    /// 层级 = 1 + 祖先 navPoint 数；键按 TOC 文件所在目录解析为全路径。
    fn parse_ncx(ncx_content: &str, toc_dir: &str) -> Result<Vec<TocEntry>> {
        let doc = roxmltree::Document::parse_with_options(ncx_content, XML_PARSE_OPTIONS)
            .map_err(|e| anyhow::anyhow!("toc.ncx 解析失败: {}", e))?;

        let mut entries = Vec::new();
        for node in doc.root_element().descendants() {
            if !tag_is(node, "navPoint") {
                continue;
            }

            let title = node
                .children()
                .find(|c| c.is_element() && tag_is(*c, "navLabel"))
                .map(|label| {
                    // 规范要求 navLabel > text；容错处理裸文本写法
                    label
                        .children()
                        .find(|c| c.is_element() && tag_is(*c, "text"))
                        .map(text_of)
                        .unwrap_or_else(|| text_of(label))
                })
                .unwrap_or_default();

            let src = node
                .children()
                .find(|c| c.is_element() && tag_is(*c, "content"))
                .and_then(|c| attr_local(c, "src"))
                .unwrap_or_default();

            if title.is_empty() || src.is_empty() {
                continue;
            }

            // 移除片段标识符后按目录文件目录解析为 ZIP 全路径
            let rel = src.split('#').next().unwrap_or(src);
            // 层级 = 1 + 真实祖先中的 navPoint 数（ancestors 首项是自身，跳过）
            let level = 1
                + node
                    .ancestors()
                    .skip(1)
                    .filter(|a| tag_is(*a, "navPoint"))
                    .count()
                    .min(u8::MAX as usize - 1) as u8;

            entries.push(TocEntry {
                href_full: resolve_zip_path(toc_dir, rel),
                title,
                level,
            });
        }

        Ok(entries)
    }

    /// 解析 EPUB3 nav.xhtml 格式的 TOC（结构性 XHTML，走 roxmltree）
    ///
    /// 优先取 type 属性值为 "toc" 的 nav（epub:type 前缀随实现浮动，
    /// 按本地名 "type" 匹配）；无标注时取文档首个 nav。
    /// 嵌套层级由 `<ol>` 嵌套深度表达：最外层列表内的条目为 level 1。
    fn parse_nav_xhtml(nav_content: &str, toc_dir: &str) -> Result<Vec<TocEntry>> {
        let doc = roxmltree::Document::parse_with_options(nav_content, XML_PARSE_OPTIONS)
            .map_err(|e| anyhow::anyhow!("nav.xhtml 解析失败: {}", e))?;

        let mut chosen: Option<roxmltree::Node<'_, '_>> = None;
        for node in doc
            .root_element()
            .descendants()
            .filter(|n| tag_is(*n, "nav"))
        {
            let is_toc = node
                .attributes()
                .into_iter()
                .any(|a| a.name() == "type" && a.value() == "toc");
            if is_toc {
                chosen = Some(node);
                break;
            }
            if chosen.is_none() {
                chosen = Some(node);
            }
        }

        let mut entries = Vec::new();
        if let Some(nav) = chosen {
            for a in nav.descendants().filter(|n| tag_is(*n, "a")) {
                let Some(href) = attr_local(a, "href") else {
                    continue;
                };
                let title = text_of(a);
                if title.is_empty() {
                    continue;
                }
                // 最外层 <ol> 内的条目为 level 1，每深一层列表加一级
                let ol_ancestors = a.ancestors().filter(|x| tag_is(*x, "ol")).count();
                let level = ol_ancestors.clamp(1, u8::MAX as usize) as u8;

                let clean_href = href.split('#').next().unwrap_or(href);
                entries.push(TocEntry {
                    href_full: resolve_zip_path(toc_dir, clean_href),
                    title,
                    level,
                });
            }
        }

        Ok(entries)
    }

    /// 提取章节的结构化内容 IR v2（路线2 主路径；纯文本为兜底）
    ///
    /// 不做阅读级文本转换（诊断/探针语义：原始 IR）；
    /// 阅读路径用 [`Self::get_chapter_content_structured_ex`]。
    pub fn get_chapter_content_structured(
        &self,
        chapter_index: usize,
    ) -> Result<crate::content_ir::StructuredContent> {
        self.get_chapter_content_structured_ex(
            chapter_index,
            crate::content_cleaner::ConvertMode::None,
            DEFAULT_BASE_FONT_PX,
        )
    }

    /// 带阅读级简繁转换的结构化提取。
    ///
    /// 转换发生在 DOM 文本节点层（JS 提取/哨兵回收之前）——runs 字符区间
    /// 在转换后文本上计算，天然对齐，不破坏 D10 契约（IR→布局零文本变换）。
    /// `base_font_px` 为 px/pt 字号 CSS 换算基准（当前排版字号）。
    /// &self：archive/css_cache 均已内部互斥，搜索/分页只需 BOOKS.read。
    pub fn get_chapter_content_structured_ex(
        &self,
        chapter_index: usize,
        convert_mode: crate::content_cleaner::ConvertMode,
        base_font_px: f32,
    ) -> Result<crate::content_ir::StructuredContent> {
        use crate::content_ir::{BgSize, PageBackground, StructuredContent, CONTENT_IR_VERSION};
        use crate::css_lite::DeclValue;

        // 先以不可变借用取出所需数据（zip 索引 + 内容目录），再进入可变读取
        let (zip_index, content_dir) = {
            let chapter = self.chapters.get(chapter_index)
                .ok_or_else(|| anyhow::anyhow!("章节索引越界: {}", chapter_index))?;
            let href = chapter.resource_href.as_deref()
                .ok_or_else(|| anyhow::anyhow!("章节没有关联的资源文件"))?;
            let zi = *self.href_to_index.get(href)
                .ok_or_else(|| anyhow::anyhow!("无法找到章节文件: {}", href))?;
            (zi, zip_parent_dir(href))
        };

        let html_content = self.read_entry_as_string(zip_index)?;

        // 主路径：DOM JSON + JS 规则；任一环节失败走兜底。
        // 注意：blocks 为空不再视为异常——装饰页正文即空（隐藏标题+空段落）。
        const DOM_MAX_BYTES: usize = 8 * 1024 * 1024;
        let extracted = match crate::dom_json::xhtml_to_dom_json_value(&html_content) {
            Err(e) => {
                log::warn!("章节 {} DOM 构建失败，回落纯文本: {}", chapter_index, e);
                None
            }
            Ok(mut dom) => {
                // 阅读级简繁：只转文本节点（属性/标签名不动），哨兵回收
                // 在转换后文本上进行，runs 区间天然正确
                crate::dom_json::convert_text_nodes(&mut dom, convert_mode);
                match crate::dom_json::serialize_dom_json(&dom, DOM_MAX_BYTES) {
                    Err(e) => {
                        log::warn!("章节 {} DOM 序列化失败，回落纯文本: {}", chapter_index, e);
                        None
                    }
                    Ok(dom) => match crate::extract_rules::extract_structured(&dom) {
                        None => None, // 无 JS 引擎构建
                        Some(Err(e)) => {
                            log::warn!("章节 {} JS 提取失败，回落纯文本: {}", chapter_index, e);
                            None
                        }
                        Some(Ok(content)) if content.blocks.len() > 20_000 => {
                            log::warn!(
                                "章节 {} IR 输出异常（{} 块），回落纯文本",
                                chapter_index,
                                content.blocks.len()
                            );
                            None
                        }
                        Some(Ok(content)) => Some(content),
                    },
                }
            }
        };

        let Some(mut content) = extracted else {
            let mut fallback = Self::structured_fallback(&html_content);
            if !matches!(convert_mode, crate::content_cleaner::ConvertMode::None) {
                for block in &mut fallback.blocks {
                    if let crate::content_ir::ContentBlock::Paragraph { text, .. } = block {
                        *text = match convert_mode {
                            crate::content_cleaner::ConvertMode::SimplifiedToTraditional => {
                                crate::chinese_convert::convert_s2t(text)
                            }
                            crate::content_cleaner::ConvertMode::TraditionalToSimplified => {
                                crate::chinese_convert::convert_t2s(text)
                            }
                            crate::content_cleaner::ConvertMode::None => unreachable!(),
                        };
                    }
                }
            }
            return Ok(fallback);
        };

        // 样式表收集与合并（文档序合并后，declarations() 的规则序优先级
        // 天然覆盖跨 <link> 的层叠语义）
        let sheets = self.collect_stylesheets(&html_content, &content_dir);
        let mut merged_sheet = crate::css_lite::CssStylesheet::default();
        for (sheet, _) in &sheets {
            merged_sheet.extend((**sheet).clone());
        }

        // body 背景：逐表查询取最后一次命中（后者覆盖前者），URL 按
        // 该样式表自身目录解析
        let mut background: Option<PageBackground> = None;
        for (sheet, css_dir) in &sheets {
            let body_ctx = crate::css_lite::NodeCtx {
                tag: content.body_tag.clone(),
                classes: content.body_classes.clone(),
                ancestors: Vec::new(),
            };
            let decls = sheet.declarations(&body_ctx);
            // 长键 background-image 优先；简写 background（真实书
            // body.head 形态：`background: #fff url(..) no-repeat`）兜底
            let raw_url = [Some("background-image"), Some("background")]
                .into_iter()
                .flatten()
                .find_map(|key| match decls.get(key) {
                    Some(DeclValue::Url(u)) => Some(u.clone()),
                    _ => None,
                });
            if let Some(raw) = raw_url {
                let size = match decls.get("background-size") {
                    Some(v) if v.is_keyword("contain") => BgSize::Contain,
                    Some(v) if v.is_keyword("cover") => BgSize::Cover,
                    // 百分比/像素/两值拉伸统一按整页拉伸处理
                    _ => BgSize::Stretch,
                };
                // 位置关键字原文透传（bottom center / left top 等），
                // 绘制层据此确定 cover 裁切锚点
                let position = match decls.get("background-position") {
                    Some(DeclValue::Keyword(k)) => Some(k.clone()),
                    _ => None,
                };
                background = Some(PageBackground {
                    image_href: resolve_zip_path(css_dir, &raw),
                    size,
                    position,
                });
            }
        }
        // JS 层报告的 body 行内背景（罕见）：无 URL 可解析则忽略

        // 图片 href 解析（内容文件目录基准）→ CSS 物化 → 隐藏图过滤
        let mut blocks: Vec<crate::content_ir::ContentBlock> = content
            .blocks
            .into_iter()
            .map(|b| b.resolve_image_paths(&content_dir))
            .map(|b| Self::apply_css_to_block(b, &merged_sheet, base_font_px))
            .filter(|b| !matches!(b, crate::content_ir::ContentBlock::Image { hidden: true, .. }))
            .collect();

        // 全屏页判定：① OPF duokan-page-fullscreen 标记
        // ② 封面启发式：标题含「封面」或 href 文件名含 cover + 过滤后单图
        //    （cover 裁切铺满；瓦尔登湖 coverpage.html 形态）
        let (href_opt, title_opt) = self
            .chapters
            .get(chapter_index)
            .map(|c| {
                (
                    c.resource_href.clone().unwrap_or_default(),
                    c.title.clone(),
                )
            })
            .map(|(h, t)| (Some(h), Some(t)))
            .unwrap_or((None, None));
        let opf_fullscreen = href_opt
            .as_deref()
            .map(|h| self.fullscreen_hrefs.contains(h))
            .unwrap_or(false);
        let cover_names = href_opt
            .as_deref()
            .zip(title_opt.as_deref())
            .map(|(h, t)| Self::is_cover_like_names(h, t))
            .unwrap_or(false);
        // 过滤空段后的实质内容（空文本段忽略；hidden 图已在上游滤掉）
        let content_blocks: Vec<&crate::content_ir::ContentBlock> = blocks
            .iter()
            .filter(|b| {
                !matches!(
                    b,
                    crate::content_ir::ContentBlock::Paragraph { text, .. }
                        if text.trim().is_empty()
                )
            })
            .collect();
        let single_image = matches!(
            content_blocks.as_slice(),
            [crate::content_ir::ContentBlock::Image { .. }]
        );
        let cover_like = cover_names && single_image;
        let is_fullscreen = (opf_fullscreen || cover_like) && single_image;
        if is_fullscreen {
            if let [crate::content_ir::ContentBlock::Image { resource_href, .. }] =
                content_blocks.as_slice()
            {
                background = Some(PageBackground {
                    image_href: resource_href.clone(),
                    size: BgSize::Cover,
                    position: None,
                });
                blocks.clear();
            }
        }

        // 原始像素尺寸探测（分页在布局引擎，必须 Rust 侧先知道高度）
        self.fill_intrinsic_sizes(&mut blocks);

        // 剥离 JS 中间字段后交付
        let blocks = blocks
            .into_iter()
            .map(crate::content_ir::ContentBlock::strip_anc)
            .collect();

        Ok(StructuredContent {
            version: CONTENT_IR_VERSION,
            background,
            body_classes: std::mem::take(&mut content.body_classes),
            blocks,
            footnotes: std::mem::take(&mut content.footnotes),
        })
    }

    /// 纯文本兜底的 StructuredContent 包装（背景信息在此降级丢失）
    fn structured_fallback(html_content: &str) -> crate::content_ir::StructuredContent {
        crate::content_ir::StructuredContent::from_fallback_text(
            &Self::html_to_text_structured(html_content),
        )
    }

    /// 收集章节 head 中 <link rel=stylesheet> 引用的样式表
    ///
    /// 返回 (解析后的样式表, 该 CSS 文件所在 ZIP 目录)——目录用于解析
    /// CSS 内 url(...) 相对地址。解析结果按书缓存。
    /// &self：css_cache 内部互斥；查/插分段持锁，不与 archive 锁嵌套。
    fn collect_stylesheets(
        &self,
        html: &str,
        content_dir: &str,
    ) -> Vec<(std::sync::Arc<crate::css_lite::CssStylesheet>, String)> {
        let doc = match scraper::Html::parse_document(html) {
            d => d,
        };
        let Ok(link_sel) = scraper::Selector::parse("link[rel=stylesheet]") else {
            return Vec::new();
        };

        let mut out = Vec::new();
        for el in doc.select(&link_sel) {
            let Some(href) = el.value().attr("href") else {
                continue;
            };
            let css_path = resolve_zip_path(content_dir, href);
            // 缓存命中：短锁克隆 Arc 后立即放锁
            let cached = {
                let cache = self.css_cache.lock().unwrap();
                cache.get(&css_path).cloned()
            };
            let sheet = if let Some(cached) = cached {
                cached
            } else {
                let Ok(bytes) = self.get_zip_entry(&css_path) else {
                    continue;
                };
                let sheet = std::sync::Arc::new(crate::css_lite::CssStylesheet::parse(
                    &String::from_utf8_lossy(&bytes),
                ));
                self.css_cache
                    .lock()
                    .unwrap()
                    .insert(css_path.clone(), sheet.clone());
                sheet
            };
            out.push((sheet, zip_parent_dir(&css_path)));
        }
        out
    }

    /// 由 anc 链构造匹配上下文（末位为自身；链缺失时退化为未知标签）
    fn node_ctx_from_anc(
        anc: Option<&Vec<Vec<String>>>,
    ) -> crate::css_lite::NodeCtx {
        let Some(chain) = anc else {
            return crate::css_lite::NodeCtx::default();
        };
        let split_entry = |e: &[String]| -> (String, Vec<String>) {
            let mut it = e.iter();
            let tag = it.next().cloned().unwrap_or_default();
            (tag, it.cloned().collect())
        };
        let Some((last, ancestors)) = chain.split_last() else {
            return crate::css_lite::NodeCtx::default();
        };
        let (tag, classes) = split_entry(last);
        crate::css_lite::NodeCtx {
            tag,
            classes,
            ancestors: ancestors.iter().map(|e| split_entry(e)).collect(),
        }
    }

    /// 出血图判定：自身或祖先链上的 duokan-bleed 关键字含 "left"
    /// （duokan-bleed 非 CSS 标准属性、不继承，此处沿链显式查找包裹容器）
    fn inherited_bleed(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
    ) -> bool {
        let has_bleed = |sub: &crate::css_lite::NodeCtx| -> bool {
            match sheet.declarations(sub).get("duokan-bleed") {
                Some(crate::css_lite::DeclValue::Keyword(k)) => k.contains("left"),
                _ => false,
            }
        };
        if has_bleed(ctx) {
            return true;
        }
        for i in (0..ctx.ancestors.len()).rev() {
            let (tag, classes) = &ctx.ancestors[i];
            let sub = crate::css_lite::NodeCtx {
                tag: tag.clone(),
                classes: classes.clone(),
                ancestors: ctx.ancestors[..i].to_vec(),
            };
            if has_bleed(&sub) {
                return true;
            }
        }
        false
    }

    /// text-align 取值（含 CSS 继承语义：自身优先，自近及远祖先兜底）
    fn inherited_text_align(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
    ) -> Option<crate::content_ir::Align> {        use crate::content_ir::Align;
        use crate::css_lite::DeclValue;

        let parse_align = |v: Option<&DeclValue>| -> Option<Align> {
            match v? {
                DeclValue::Keyword(k) => match k.as_str() {
                    "center" => Some(Align::Center),
                    "right" | "end" => Some(Align::Right),
                    "left" | "start" => Some(Align::Left),
                    "justify" => Some(Align::Justify), // P2：两端对齐回正（此前折叠为 Left）
                    _ => None,
                },
                _ => None,
            }
        };

        parse_align(sheet.declarations(ctx).get("text-align")).or_else(|| {
            for i in (0..ctx.ancestors.len()).rev() {
                let (tag, classes) = &ctx.ancestors[i];
                let sub = crate::css_lite::NodeCtx {
                    tag: tag.clone(),
                    classes: classes.clone(),
                    ancestors: ctx.ancestors[..i].to_vec(),
                };
                if let Some(a) = parse_align(sheet.declarations(&sub).get("text-align")) {
                    return Some(a);
                }
            }
            None
        })
    }

    /// 封面启发式：href 文件名以 cover 开头（ASCII 不区分大小写）或 title 含「封面」
    /// （starts_with 避免 uncover 等误伤）
    fn is_cover_like_names(href: &str, title: &str) -> bool {
        let base = href.rsplit('/').next().unwrap_or(href);
        let name_hit = base.to_ascii_lowercase().starts_with("cover");
        let title_hit = title.contains("封面");
        name_hit || title_hit
    }

    /// 十六进制颜色规范化：`#abc`/`#aabbcc` → `#aabbcc` 小写形，其余放弃
    fn normalize_hex_color(keyword: &str) -> Option<String> {
        let h = keyword.strip_prefix('#')?;
        if !h.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        match h.len() {
            3 => Some(format!(
                "#{}",
                h.chars().flat_map(|c| [c, c]).collect::<String>().to_ascii_lowercase()
            )),
            6 => Some(format!("#{}", h.to_ascii_lowercase())),
            _ => None,
        }
    }

    /// 可继承属性的取值：自身优先，自近及远祖先兜底（CSS 继承语义）
    fn self_or_inherited(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        prop: &str,
    ) -> Option<crate::css_lite::DeclValue> {
        use crate::css_lite::DeclValue;
        // 残缺声明（如 `margin-left:;` 解析为 None）视同未声明，不阻断继承兜底
        if let Some(v) = sheet.declarations(ctx).get(prop) {
            if !matches!(v, DeclValue::None) {
                return Some(v.clone());
            }
        }
        for i in (0..ctx.ancestors.len()).rev() {
            let (tag, classes) = &ctx.ancestors[i];
            let sub = crate::css_lite::NodeCtx {
                tag: tag.clone(),
                classes: classes.clone(),
                ancestors: ctx.ancestors[..i].to_vec(),
            };
            if let Some(v) = sheet.declarations(&sub).get(prop) {
                if !matches!(v, DeclValue::None) {
                    return Some(v.clone());
                }
            }
        }
        None
    }

    /// 块级 color 物化（含继承）：#hex / rgb(a)() / 常用命名色，
    /// 统一输出 #rrggbb 小写规范形
    fn resolved_color(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
    ) -> Option<String> {
        match Self::self_or_inherited(sheet, ctx, "color") {
            Some(crate::css_lite::DeclValue::Keyword(k)) => Self::normalize_hex_color(&k)
                .or_else(|| Self::parse_rgb(&k))
                .or_else(|| Self::named_color(&k)),
            _ => None,
        }
    }

    /// rgb()/rgba() 手工解析：拆分量 clamp 0-255，alpha 忽略按不透明处理。
    /// css_lite 解析期已转小写
    fn parse_rgb(raw: &str) -> Option<String> {
        let rest = raw.strip_prefix("rgba").or_else(|| raw.strip_prefix("rgb"))?;
        let inner = rest.trim().strip_prefix('(')?.strip_suffix(')')?;
        let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
        if parts.len() < 3 || parts.len() > 4 {
            return None;
        }
        let mut out = String::from("#");
        for p in &parts[..3] {
            let v = p.parse::<f32>().ok()?;
            out.push_str(&format!("{:02x}", v.round().clamp(0.0, 255.0) as u8));
        }
        Some(out)
    }

    /// CSS 基本命名色精简表（真实书高频形态）
    fn named_color(keyword: &str) -> Option<String> {
        const NAMED_COLORS: &[(&str, &str)] = &[
            ("white", "#ffffff"),
            ("black", "#000000"),
            ("red", "#ff0000"),
            ("green", "#008000"),
            ("lime", "#00ff00"),
            ("blue", "#0000ff"),
            ("gray", "#808080"),
            ("grey", "#808080"),
            ("silver", "#c0c0c0"),
            ("maroon", "#800000"),
            ("navy", "#000080"),
            ("olive", "#808000"),
            ("purple", "#800080"),
            ("teal", "#008080"),
            ("yellow", "#ffff00"),
            ("orange", "#ffa500"),
            ("gold", "#ffd700"),
        ];
        NAMED_COLORS
            .iter()
            .find(|(k, _)| *k == keyword)
            .map(|(_, v)| v.to_string())
    }

    /// CSS border-bottom 简写解析 → 标题装饰分割线
    ///
    /// 真实书形态：`solid 2px #2C7938` / `2px solid #2c7938` / `1.5px dashed #D2691E`。
    /// 只提取 px 线宽与 #hex 色；dashed/dotted 仍按实线绘制（损失仅线型）。
    /// `none` / `0` 明确关闭。
    fn resolved_border_bottom(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        base_font_px: f32,
    ) -> Option<crate::content_ir::BorderLine> {
        use crate::content_ir::BorderLine;
        use crate::css_lite::DeclValue;

        let raw = match Self::self_or_inherited(sheet, ctx, "border-bottom")? {
            DeclValue::Keyword(k) => k,
            DeclValue::Px(p) => format!("{p}px"),
            DeclValue::None => return None,
            _ => return None,
        };
        let lower = raw.to_ascii_lowercase();
        if lower.contains("none") || lower == "0" || lower == "0px" {
            return None;
        }
        // 线宽：首个 `Npx`；无 px 时找 em（×基准字号）
        let mut width_px = None;
        for tok in lower.split_whitespace() {
            if let Some(v) = tok.strip_suffix("px") {
                if let Ok(n) = v.parse::<f32>() {
                    if n > 0.0 {
                        width_px = Some(n);
                        break;
                    }
                }
            }
        }
        if width_px.is_none() {
            for tok in lower.split_whitespace() {
                if let Some(v) = tok.strip_suffix("em") {
                    if let Ok(n) = v.parse::<f32>() {
                        if n > 0.0 && base_font_px > 0.0 {
                            width_px = Some(n * base_font_px);
                            break;
                        }
                    }
                }
            }
        }
        let width_px = width_px.unwrap_or(2.0).clamp(1.0, 8.0);
        // 颜色：#rgb / #rrggbb
        let mut color = None;
        for tok in lower.split_whitespace() {
            if tok.starts_with('#') {
                if let Some(c) = Self::normalize_hex_color(tok) {
                    color = Some(c);
                    break;
                }
            } else if let Some(c) = Self::named_color(tok) {
                color = Some(c);
                break;
            }
        }
        let color = color?;
        Some(BorderLine { color, width_px })
    }

    /// 块级 font-size 相对倍率物化：em/% 直接为倍率；px/pt 以当前
    /// 排版基准字号换算（rem 维持忽略——脱离根字号上下文）
    fn resolved_font_scale(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        base_font_px: f32,
    ) -> Option<f32> {
        match Self::self_or_inherited(sheet, ctx, "font-size") {
            Some(crate::css_lite::DeclValue::Em(e)) => Some(e),
            Some(crate::css_lite::DeclValue::Percent(p)) => Some(p / 100.0),
            Some(crate::css_lite::DeclValue::Px(px)) if base_font_px > 0.0 => {
                Some(px / base_font_px)
            }
            Some(crate::css_lite::DeclValue::Pt(pt)) if base_font_px > 0.0 => {
                Some(pt * 4.0 / 3.0 / base_font_px)
            }
            _ => None,
        }
    }

    /// M9 P5：CSS text-indent 解析 → em 倍数
    ///
    /// 支持 em / % / px / pt 单位，% 按 em 近似（相对基准字号）
    fn resolved_text_indent(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        base_font_px: f32,
    ) -> Option<f32> {
        match Self::self_or_inherited(sheet, ctx, "text-indent") {
            Some(crate::css_lite::DeclValue::Em(e)) => Some(e),
            Some(crate::css_lite::DeclValue::Percent(p)) => Some(p / 100.0),
            Some(crate::css_lite::DeclValue::Px(px)) if base_font_px > 0.0 => {
                Some(px / base_font_px)
            }
            Some(crate::css_lite::DeclValue::Pt(pt)) if base_font_px > 0.0 => {
                Some(pt * 4.0 / 3.0 / base_font_px)
            }
            _ => None,
        }
    }

    /// P2：CSS margin-bottom 解析 → em 倍数（段后间距物化）
    ///
    /// margin 为非继承属性——仅查节点自身声明（含 margin 简写展开），
    /// 不走 self_or_inherited。支持 em / % / px / pt，% 与 px/pt 按
    /// resolved_text_indent 同款近似折算 em。负值原样保留（布局层
    /// 与用户段距取 max 时自然被兜底）。
    fn resolved_spacing_after_em(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        base_font_px: f32,
    ) -> Option<f32> {
        let decls = sheet.declarations(ctx);
        match decls.get("margin-bottom") {
            Some(crate::css_lite::DeclValue::Em(e)) => Some(*e),
            Some(crate::css_lite::DeclValue::Percent(p)) => Some(p / 100.0),
            Some(crate::css_lite::DeclValue::Px(px)) if base_font_px > 0.0 => {
                Some(px / base_font_px)
            }
            Some(crate::css_lite::DeclValue::Pt(pt)) if base_font_px > 0.0 => {
                Some(pt * 4.0 / 3.0 / base_font_px)
            }
            _ => None,
        }
    }

    /// P2：CSS line-height 解析 → 行高倍率（行内物化）
    ///
    /// line-height 为 CSS 继承属性——走 self_or_inherited。
    /// 无单位数字（`line-height: 1.8`，最常见形态）落在 Keyword，
    /// parse 折算；em/%/px/pt 按 resolved_text_indent 同款折算。
    /// 倍率 ≤0 视为病态声明忽略。
    fn resolved_line_height(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
        base_font_px: f32,
    ) -> Option<f32> {
        let v = Self::self_or_inherited(sheet, ctx, "line-height")?;
        let multiplier = match v {
            crate::css_lite::DeclValue::Em(e) => Some(e),
            crate::css_lite::DeclValue::Percent(p) => Some(p / 100.0),
            crate::css_lite::DeclValue::Px(px) if base_font_px > 0.0 => {
                Some(px / base_font_px)
            }
            crate::css_lite::DeclValue::Pt(pt) if base_font_px > 0.0 => {
                Some(pt * 4.0 / 3.0 / base_font_px)
            }
            crate::css_lite::DeclValue::Keyword(k) => k.parse::<f32>().ok(),
            _ => None,
        };
        multiplier.filter(|m| *m > 0.0)
    }

    /// 行内标签的 UA 默认字形语义（b/strong 粗、i/em/cite 斜、a 下划线）
    fn tag_glyph_semantics(ctx: &crate::css_lite::NodeCtx) -> (bool, bool, bool) {
        match ctx.tag.as_str() {
            "b" | "strong" => (true, false, false),
            "i" | "em" | "cite" => (false, true, false),
            "a" => (false, false, true),
            _ => (false, false, false),
        }
    }

    /// font-weight 物化：Some(true)=粗、Some(false)=显式常规（阻断继承）、
    /// None=未声明。bold/bolder 为粗；normal/lighter 为常规；数值按
    /// CSS 级联语义整体覆盖 UA 默认（≥550 粗，其余常规）
    fn resolved_font_weight(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
    ) -> Option<bool> {
        use crate::css_lite::DeclValue;
        match Self::self_or_inherited(sheet, ctx, "font-weight") {
            Some(DeclValue::Keyword(k)) => match k.as_str() {
                "bold" | "bolder" => Some(true),
                "normal" | "lighter" => Some(false),
                _ => k.parse::<f32>().ok().map(|n| n >= 550.0),
            },
            _ => None,
        }
    }

    /// font-style 物化：italic/oblique 为斜，normal 显式常规，其余未声明
    fn resolved_font_style(
        sheet: &crate::css_lite::CssStylesheet,
        ctx: &crate::css_lite::NodeCtx,
    ) -> Option<bool> {
        match Self::self_or_inherited(sheet, ctx, "font-style") {
            Some(v) if v.is_keyword("italic") || v.is_keyword("oblique") => Some(true),
            Some(v) if v.is_keyword("normal") => Some(false),
            _ => None,
        }
    }

    /// 行内富文本段物化：run 自身链路解析颜色/字号（继承语义天然覆盖
    /// 外层段落与更远祖先），空区间与越界区间过滤；字形样式按标签默认
    /// 语义 + CSS 声明覆盖（CSS 命中胜出，未命中保留标签判定）
    fn resolve_runs(
        runs: Vec<crate::content_ir::StyledRun>,
        sheet: &crate::css_lite::CssStylesheet,
        text_chars: usize,
        base_font_px: f32,
    ) -> Vec<crate::content_ir::StyledRun> {
        runs.into_iter()
            .filter(|r| r.end > r.start)
            .map(|mut r| {
                r.start = r.start.min(text_chars);
                r.end = r.end.min(text_chars);
                if let Some(anc) = r.anc.take() {
                    let ctx = Self::node_ctx_from_anc(Some(&anc));
                    r.color = Self::resolved_color(sheet, &ctx);
                    r.font_scale =
                        Self::resolved_font_scale(sheet, &ctx, base_font_px);
                    // ruby 注音：CSS 未声明字号时以小字跟随基字（行高下限
                    // 1.0 取 max，不撑行）；CSS 命中则用 CSS
                    if ctx.tag == "rt" && r.font_scale.is_none() {
                        r.font_scale = Some(RUBY_SCALE);
                    }
                    let (tag_bold, tag_italic, tag_underline) = Self::tag_glyph_semantics(&ctx);
                    r.bold = Self::resolved_font_weight(sheet, &ctx).unwrap_or(tag_bold);
                    r.italic = Self::resolved_font_style(sheet, &ctx).unwrap_or(tag_italic);
                    r.underline = tag_underline;
                    // A34：脚注引用不上链、默认小字号上标（spec S2）
                    if r.footnote_ref.is_some() {
                        r.underline = false;
                        if r.font_scale.is_none() {
                            r.font_scale = Some(0.7);
                        }
                    }
                }
                r
            })
            .filter(|r| r.end > r.start)
            .collect()
    }

    /// 检查祖先链是否包含 aside/footer/note 等注释类元素
    /// 
    /// M9 P1：本章说检测三重验证之一（祖先链验证）
    fn has_aside_ancestor(anc: &Option<Vec<Vec<String>>>) -> bool {
        if let Some(ancestry) = anc {
            for path in ancestry {
                for tag in path {
                    let tag_lower = tag.to_lowercase();
                    if tag_lower == "aside" 
                        || tag_lower == "footer" 
                        || tag_lower == "note" {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// 检查类名是否包含 footnote/sidenote/annotation 等注释相关词汇
    /// 
    /// M9 P1：本章说检测三重验证之二（类名验证）
    fn has_note_class(anc: &Option<Vec<Vec<String>>>) -> bool {
        if let Some(ancestry) = anc {
            for path in ancestry {
                // 祖先链每层格式：[tag, class1, class2, ...]
                // 第一个元素是标签名，后续元素是类名
                for (i, item) in path.iter().enumerate() {
                    if i == 0 {
                        continue; // 跳过标签名
                    }
                    let item_lower = item.to_lowercase();
                    if item_lower.contains("footnote")
                        || item_lower.contains("endnote")
                        || item_lower.contains("sidenote")
                        || item_lower.contains("annotation")
                        || item_lower == "note"
                        || item_lower == "note1"
                    {
                        return true;
                    }
                }
            }
        }
        false
    }

    /// 检查是否为孤立小块（前后有空行 + 居中或右对齐）
    /// 
    /// M9 P1：本章说检测三重验证之三（孤立小块验证）
    /// 
    /// 注意：当前实现无法获取前后块信息，暂时通过对齐方式判断
    fn is_isolated_small_block(align: &Option<crate::content_ir::Align>) -> bool {
        // 居中或右对齐的小块更可能是注释
        matches!(align, Some(crate::content_ir::Align::Center) | Some(crate::content_ir::Align::Right))
    }

    /// 对单块做 CSS 物化：图片宽度百分比/对齐/隐藏，段落与标题对齐；
    /// 容器类递归下沉。JS 输出的 align 字段已存在时以 JS 为准（预留）。
    /// `base_font_px` 为 px/pt 字号换算基准（当前排版字号）
    fn apply_css_to_block(
        block: crate::content_ir::ContentBlock,
        sheet: &crate::css_lite::CssStylesheet,
        base_font_px: f32,
    ) -> crate::content_ir::ContentBlock {
        use crate::content_ir::ContentBlock;
        use crate::css_lite::DeclValue;

        match block {
            ContentBlock::Image {
                resource_href,
                alt,
                width_percent,
                align,
                intrinsic,
                bleed,
                hidden,
                anc,
            } => {
                let ctx = Self::node_ctx_from_anc(anc.as_ref());
                let decls = sheet.declarations(&ctx);
                let width_percent = width_percent.or_else(|| match decls.get("width") {
                    // px 宽度脱离页面上下文无法换算，v1 仅支持百分比
                    Some(DeclValue::Percent(p)) => Some(*p),
                    _ => None,
                });
                let hidden = hidden
                    || matches!(decls.get("display"), Some(v) if v.is_keyword("none"));
                // 出血图：duokan-bleed 声明在包裹 div 上（img 自身无此属性），
                // 沿祖先链查找含 left 的关键字（lefttopright 为真实书唯一形态）
                let bleed = bleed || Self::inherited_bleed(sheet, &ctx);
                let align =
                    align.or_else(|| Self::inherited_text_align(sheet, &ctx));
                ContentBlock::Image {
                    resource_href,
                    alt,
                    width_percent,
                    align,
                    intrinsic,
                    bleed,
                    hidden,
                    anc,
                }
            }
            ContentBlock::Paragraph {
                text,
                align,
                color,
                font_scale,
                runs,
                anc,
                is_comment,
                indent_first_line_em,
                spacing_after_em,
                line_height,
            } => {
                let ctx = Self::node_ctx_from_anc(anc.as_ref());
                let align = align.or_else(|| Self::inherited_text_align(sheet, &ctx));
                let color = color.or_else(|| Self::resolved_color(sheet, &ctx));
                let font_scale =
                    font_scale.or_else(|| Self::resolved_font_scale(sheet, &ctx, base_font_px));
                // M9 P5：CSS text-indent → indent_first_line_em
                let indent_first_line_em = indent_first_line_em
                    .or_else(|| Self::resolved_text_indent(sheet, &ctx, base_font_px));
                // P2：CSS margin-bottom → spacing_after_em（段后间距物化）
                let spacing_after_em = spacing_after_em
                    .or_else(|| Self::resolved_spacing_after_em(sheet, &ctx, base_font_px));
                // P2：CSS line-height → line_height（行高倍率物化，继承属性）
                let line_height =
                    line_height.or_else(|| Self::resolved_line_height(sheet, &ctx, base_font_px));
                let runs = Self::resolve_runs(runs, sheet, text.chars().count(), base_font_px);
                // M9 P1：CSS 兜底分类修正 - 收紧门槛 + 三重验证
                // 旧逻辑（0.85/200）误判率高，导致《剑来》普通正文被标记为注释。
                // 新逻辑：更严格门槛（0.75/150）+ 必须满足以下至少一项正向特征：
                // 1. 祖先链包含 aside/footer/note 元素
                // 2. 类名包含 footnote/sidenote/annotation
                // 3. 居中或右对齐的小块（孤立注释的典型布局）
                let char_count = text.chars().count();
                // A34：class note/note1（章末注）不要求 <0.75——瓦尔登湖 .note=0.85em
                let note_cls = Self::has_note_class(&anc);
                let is_potential_comment = char_count < 200
                    && ((note_cls && font_scale.unwrap_or(1.0) < 1.0)
                        || (font_scale.unwrap_or(1.0) < 0.75
                            && char_count < 150
                            && (Self::has_aside_ancestor(&anc)
                                || note_cls
                                || Self::is_isolated_small_block(&align))));
                let is_comment = is_comment || is_potential_comment;
                ContentBlock::Paragraph {
                    text,
                    align,
                    color,
                    font_scale,
                    runs,
                    anc,
                    is_comment,
                    indent_first_line_em,
                    spacing_after_em,
                    line_height,
                }
            }
            ContentBlock::Heading {
                level,
                text,
                align,
                color,
                font_scale,
                border_bottom,
                anc,
            } => {
                let ctx = Self::node_ctx_from_anc(anc.as_ref());
                let align = align.or_else(|| Self::inherited_text_align(sheet, &ctx));
                let color = color.or_else(|| Self::resolved_color(sheet, &ctx));
                let font_scale =
                    font_scale.or_else(|| Self::resolved_font_scale(sheet, &ctx, base_font_px));
                // A34.3：CSS border-bottom → 标题下装饰分割线
                // （瓦尔登湖 h1.zw-text1 { border-bottom: solid 2px #2C7938 }）
                let border_bottom =
                    border_bottom.or_else(|| Self::resolved_border_bottom(sheet, &ctx, base_font_px));
                ContentBlock::Heading {
                    level,
                    text,
                    align,
                    color,
                    font_scale,
                    border_bottom,
                    anc,
                }
            }
            ContentBlock::Quote { blocks } => ContentBlock::Quote {
                blocks: blocks
                    .into_iter()
                    .map(|b| Self::apply_css_to_block(b, sheet, base_font_px))
                    .collect(),
            },
            ContentBlock::List { ordered, items } => ContentBlock::List {
                ordered,
                items: items
                    .into_iter()
                    .map(|item| crate::content_ir::ListItem {
                        blocks: item
                            .blocks
                            .into_iter()
                            .map(|b| Self::apply_css_to_block(b, sheet, base_font_px))
                            .collect(),
                    })
                    .collect(),
            },
            ContentBlock::Table {
                caption,
                rows,
                anc,
                margin_top_percent,
                margin_left_auto,
            } => {
                // 表格级：margin-top 百分比 + margin-left:auto 右置
                // （table.vol-title{margin:20% 0 0 auto} 双命中）
                let table_ctx = Self::node_ctx_from_anc(anc.as_ref());
                let table_decls = sheet.declarations(&table_ctx);
                let margin_top_percent = margin_top_percent.or_else(|| {
                    match table_decls.get("margin-top") {
                        Some(DeclValue::Percent(p)) => Some(*p),
                        _ => None,
                    }
                });
                let margin_left_auto = margin_left_auto
                    || matches!(
                        table_decls.get("margin-left"),
                        Some(v) if v.is_keyword("auto")
                    );
                ContentBlock::Table {
                    caption,
                    rows: rows
                        .into_iter()
                        .map(|row| {
                            row.into_iter()
                                .map(|cell| {
                                    // 单元格级：td width em 列宽提示
                                    let cell_ctx =
                                        Self::node_ctx_from_anc(cell.anc.as_ref());
                                    let width_em = cell.width_em.or_else(|| {
                                        match sheet.declarations(&cell_ctx).get("width") {
                                            Some(DeclValue::Em(e)) => Some(*e),
                                            _ => None,
                                        }
                                    });
                                    crate::content_ir::TableCell {
                                        header: cell.header,
                                        width_em,
                                        anc: cell.anc,
                                        // M9.2：单元格内容物化 CSS 后递归清零散文缩进
                                        blocks: Self::clear_cell_indent(
                                            cell.blocks
                                                .into_iter()
                                                .map(|b| {
                                                    Self::apply_css_to_block(
                                                        b,
                                                        sheet,
                                                        base_font_px,
                                                    )
                                                })
                                                .collect(),
                                        ),
                                    }
                                })
                                .collect()
                        })
                        .collect(),
                    anc,
                    margin_top_percent,
                    margin_left_auto,
                }
            }
            other => other,
        }
    }

    /// M9.2：表格单元格内禁用散文首行缩进——递归清零单元格内容树中所有
    /// Paragraph 的 indent_first_line_em（覆盖 Quote/List 嵌套）。
    /// 表格是数据网格形态，`p{text-indent}` 选择器或 body 继承渗入的缩进
    /// 只会呈现"首行提前换行但不右移"的破碎形态，故在物化源头剥离。
    fn clear_cell_indent(
        blocks: Vec<crate::content_ir::ContentBlock>,
    ) -> Vec<crate::content_ir::ContentBlock> {
        use crate::content_ir::ContentBlock;
        blocks
            .into_iter()
            .map(|b| match b {
                ContentBlock::Paragraph {
                    text,
                    align,
                    color,
                    font_scale,
                    runs,
                    anc,
                    is_comment,
                    indent_first_line_em: _,
                    spacing_after_em,
                    line_height,
                } => ContentBlock::Paragraph {
                    text,
                    align,
                    color,
                    font_scale,
                    runs,
                    anc,
                    is_comment,
                    indent_first_line_em: None,
                    spacing_after_em,
                    line_height,
                },
                ContentBlock::Quote { blocks } => ContentBlock::Quote {
                    blocks: Self::clear_cell_indent(blocks),
                },
                ContentBlock::List { ordered, items } => ContentBlock::List {
                    ordered,
                    items: items
                        .into_iter()
                        .map(|mut item| {
                            item.blocks = Self::clear_cell_indent(item.blocks);
                            item
                        })
                        .collect(),
                },
                other => other,
            })
            .collect()
    }

    /// 递归探测全部图片块的原始像素尺寸（探测失败留 None，布局按默认比）
    /// &self：内部仅 get_resource_cached（archive 已内部互斥）
    fn fill_intrinsic_sizes(&self, blocks: &mut [crate::content_ir::ContentBlock]) {
        use crate::content_ir::ContentBlock;
        // 探测只需头部字节；读全量是为复用 LRU 资源缓存（渲染预热）
        const PROBE_PREFIX_BYTES: usize = 64 * 1024;

        for block in blocks.iter_mut() {
            match block {
                ContentBlock::Image { resource_href, intrinsic, .. } => {
                    if intrinsic.is_some() {
                        continue;
                    }
                    let dims = self
                        .get_resource_cached(resource_href)
                        .ok()
                        .and_then(|data| {
                            let prefix_len = data.len().min(PROBE_PREFIX_BYTES);
                            crate::image_size::probe_image_size(&data[..prefix_len])
                        })
                        .map(|d| (d.width, d.height));
                    if dims.is_some() {
                        *intrinsic = dims;
                    }
                }
                ContentBlock::Quote { blocks: inner } => {
                    self.fill_intrinsic_sizes(inner);
                }
                ContentBlock::List { items, .. } => {
                    for item in items.iter_mut() {
                        self.fill_intrinsic_sizes(&mut item.blocks);
                    }
                }
                ContentBlock::Table { rows, .. } => {
                    for row in rows.iter_mut() {
                        for cell in row.iter_mut() {
                            self.fill_intrinsic_sizes(&mut cell.blocks);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    /// 纯文本兜底：html_to_text_structured 输出的每个非空行包成 Paragraph
    #[allow(dead_code)]
    fn fallback_blocks(html_content: &str) -> Vec<crate::content_ir::ContentBlock> {
        crate::content_ir::StructuredContent::from_fallback_text(
            &Self::html_to_text_structured(html_content),
        )
        .blocks
    }

    /// 只读窥探资源缓存（不触发 ZIP 读取）：命中返回字节，None=未命中。
    ///
    /// 供 bridge 的 get_book_resource 走 BOOKS.read() 快路径——命中时
    /// 不与前台分页（BOOKS.write）争锁；未命中才落写锁慢路径。
    pub fn peek_resource_cache(&self, resource_id: &str) -> Option<Vec<u8>> {
        let mut cache = self.resource_cache.lock().unwrap();
        cache.get(resource_id)
    }

    /// 获取资源（带缓存）。&self：archive 内部互斥，bridge 可在
    /// BOOKS.read() 内调用，不再与前台分页争写锁。
    pub fn get_resource_cached(&self, resource_id: &str) -> Result<Vec<u8>> {
        // 先检查缓存
        {
            let mut cache = self.resource_cache.lock().unwrap();
            if let Some(data) = cache.get(resource_id) {
                return Ok(data);
            }
        }

        // 从 ZIP 读取
        let data = self.get_resource(resource_id)?;

        // 写入缓存
        {
            let mut cache = self.resource_cache.lock().unwrap();
            cache.put(resource_id.to_string(), data.clone());
        }

        Ok(data)
    }

    /// 清空资源缓存
    pub fn clear_resource_cache(&self) {
        let mut cache = self.resource_cache.lock().unwrap();
        cache.clear();
    }

    /// 封面字节（parse() 时提取；None=书未声明封面或提取失败）
    pub fn cover_data(&self) -> Option<&Vec<u8>> {
        self.metadata.as_ref()?.cover_data.as_ref()
    }

    /// 从 HTML 提取文本（增强版，保留基本结构）
    pub fn html_to_text_structured(html: &str) -> String {
        let doc = scraper::Html::parse_document(html);
        let mut result = String::new();

        // 查找 body
        let body_selector = scraper::Selector::parse("body")
            .ok()
            .and_then(|sel| doc.select(&sel).next());

        if let Some(body) = body_selector {
            Self::extract_structured_text(body, &mut result);
        } else {
            // 从根元素提取
            for node in doc.root_element().children() {
                if let Some(element) = scraper::ElementRef::wrap(node) {
                    Self::extract_structured_text(element, &mut result);
                }
            }
        }

        // 清理多余空行
        Self::clean_text(&result)
    }

    /// 递归提取结构化文本
    fn extract_structured_text(element: scraper::ElementRef, result: &mut String) {
        for node in element.children() {
            match node.value() {
                scraper::Node::Text(t) => {
                    let text = t.text.trim();
                    if !text.is_empty() {
                        result.push_str(text);
                    }
                }
                scraper::Node::Element(el) => {
                    // 跳过 script 和 style
                    if el.name() == "script" || el.name() == "style" {
                        continue;
                    }

                    match el.name() {
                        // 块级元素前加换行
                        "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "blockquote"
                        | "pre" | "li" | "tr" => {
                            if !result.is_empty() && !result.ends_with('\n') {
                                result.push('\n');
                            }
                        }
                        // 换行标签
                        "br" => {
                            result.push('\n');
                            continue; // 不处理子节点
                        }
                        // 图片标签
                        "img" => {
                            if let Some(alt) = el.attr("alt") {
                                if !alt.is_empty() {
                                    result.push_str(&format!("[图片: {}]", alt));
                                }
                            }
                            continue;
                        }
                        _ => {}
                    }

                    // 递归处理子节点
                    if let Some(child) = scraper::ElementRef::wrap(node) {
                        Self::extract_structured_text(child, result);
                    }

                    // 块级元素后加换行
                    if matches!(
                        el.name(),
                        "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "blockquote"
                            | "pre" | "li" | "tr"
                    ) {
                        result.push('\n');
                    }
                }
                _ => {}
            }
        }
    }

    /// 清理文本（移除多余空行和空格）
    fn clean_text(text: &str) -> String {
        let mut result = String::new();
        let mut prev_was_newline = false;

        for ch in text.chars() {
            match ch {
                '\n' => {
                    if !prev_was_newline {
                        result.push('\n');
                        prev_was_newline = true;
                    }
                }
                ' ' | '\t' | '\r' => {
                    // 跳过空白字符
                }
                _ => {
                    result.push(ch);
                    prev_was_newline = false;
                }
            }
        }

        // 移除首尾空行
        result.trim().to_string()
    }
}

impl BookParser for EpubParser {
    fn format(&self) -> BookFormat {
        BookFormat::Epub
    }

    fn supported_resources(&self) -> Vec<ResourceType> {
        vec![ResourceType::Image, ResourceType::Font, ResourceType::Stylesheet]
    }

    fn get_resource(&self, resource_id: &str) -> Result<Vec<u8>> {
        // resource_id 视为 ZIP 内完整路径直读（结构化 IR 的 resource_href
        // 即全路径；旧的 opf_base_path 拼接语义已废弃）
        self.get_zip_entry(resource_id)
    }

    fn list_resources(&self) -> Result<Vec<(String, String)>> {
        // 使用内部的 href_to_index 映射来获取资源列表
        let mut resources = Vec::new();

        // 从 spine_hrefs 获取内容文件
        for href in &self.spine_hrefs {
            let mime = if let Some(ext) = href.rsplit('.').next() {
                match ext.to_lowercase().as_str() {
                    "png" => "image/png",
                    "jpg" | "jpeg" => "image/jpeg",
                    "gif" => "image/gif",
                    "svg" => "image/svg+xml",
                    "css" => "text/css",
                    "ttf" => "font/ttf",
                    "otf" => "font/otf",
                    "woff" => "font/woff",
                    "woff2" => "font/woff2",
                    "xhtml" | "html" | "htm" => "application/xhtml+xml",
                    _ => continue,
                }
            } else {
                continue;
            };
            resources.push((href.clone(), mime.to_string()));
        }

        Ok(resources)
    }

    fn parse(&mut self) -> Result<BookMetadata> {
        // 1. 读取 container.xml
        let container_index = {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard
                .as_mut()
                .ok_or_else(|| anyhow::anyhow!("ZIP 归档不可用"))?;
            Self::find_entry_index(archive, "META-INF/container.xml")
                .or_else(|| Self::find_entry_index(archive, "META-INF/Container.xml"))
                .ok_or_else(|| anyhow::anyhow!("EPUB 中未找到 container.xml"))?
        };

        let container_xml = {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard.as_mut().unwrap();
            let mut entry = archive.by_index(container_index)?;
            let mut content = String::new();
            entry.read_to_string(&mut content)?;
            content
        };

        let opf_path = Self::parse_container(&container_xml)?;

        // 2. 确定 OPF 目录
        let opf_dir = opf_path.rsplit_once('/').map(|(dir, _)| dir).unwrap_or("");

        // 3. 读取并解析 OPF
        let opf_index = {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard.as_mut().unwrap();
            Self::find_entry_index(archive, &opf_path)
                .ok_or_else(|| anyhow::anyhow!("无法找到 OPF 文件: {}", opf_path))?
        };

        let opf_xml = {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard.as_mut().unwrap();
            let mut entry = archive.by_index(opf_index)?;
            let mut content = String::new();
            entry.read_to_string(&mut content)?;
            content
        };

        let opf_data = Self::parse_opf(&opf_xml, opf_dir)?;

        // 4. 建立 href → ZIP 索引映射
        let mut href_to_index = HashMap::new();
        {
            let mut guard = self.archive.lock().unwrap();
            let archive = guard.as_mut().unwrap();
            for href in &opf_data.spine_hrefs {
                if let Some(idx) = Self::find_entry_index(archive, href) {
                    href_to_index.insert(href.clone(), idx);
                }
            }
        }

        // 5. 构建章节列表
        let mut chapters = Vec::new();
        for (spine_idx, href) in opf_data.spine_hrefs.iter().enumerate() {
            let title = format!("章节 {}", spine_idx + 1); // 默认标题
            chapters.push(ChapterInfo::epub_chapter(
                spine_idx,
                title,
                0, // 字数在获取内容时计算
                href.clone(),
                spine_idx,
            ));
        }

        // 如果没有 spine 章节，添加一个占位
        if chapters.is_empty() {
            chapters.push(ChapterInfo::epub_chapter(
                0,
                "正文".to_string(),
                0,
                String::new(),
                0,
            ));
        }

        // 6. 提取元信息
        let metadata_map = opf_data.metadata;
        let title = metadata_map.get("dc:title")
            .or_else(|| metadata_map.get("title"))
            .cloned()
            .unwrap_or_else(|| {
                self.file_path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("未命名书籍")
                    .to_string()
            });

        let author = metadata_map.get("dc:creator")
            .or_else(|| metadata_map.get("creator"))
            .cloned()
            .unwrap_or_else(|| "未知作者".to_string());

        let language = metadata_map.get("dc:language")
            .or_else(|| metadata_map.get("language"))
            .cloned()
            .unwrap_or_else(|| "zh".to_string());

        self.spine_hrefs = opf_data.spine_hrefs;
        self.href_to_index = href_to_index;
        self.opf_base_path = opf_dir.to_string();
        self.nav_href = opf_data.nav_href;
        self.ncx_href = opf_data.ncx_href;
        self.fullscreen_hrefs = opf_data.fullscreen_hrefs;

        // 章节列表先落位：后续 TOC 标题更新直接作用其上。
        // （此前赋值发生在标题更新之后，更新循环遍历的是空的 self.chapters，
        //   TOC 标题从未生效。）
        self.chapters = chapters;

        // 6. 解析 TOC（文档序条目，键已按目录文件目录解析为全路径）
        let toc_entries = self.parse_toc().unwrap_or_else(|e| {
            log::warn!("解析 TOC 失败: {}", e);
            Vec::new()
        });

        // 7. 使用 TOC 更新章节标题与层级
        //
        // 主匹配 = 全路径相等；双向后缀仅作 `./` 前缀等非常规书的兜底。
        // 同一文件多条目时文档序首条胜出（构建时 or_insert 保证确定）——
        // 旧实现的 HashMap find 迭代序不确定，且前缀方向写反导致
        // OPF 位于子目录（OEBPS/ 等）时标题永远无法命中。
        let mut toc_first: HashMap<String, &TocEntry> = HashMap::new();
        for e in &toc_entries {
            toc_first.entry(e.href_full.clone()).or_insert(e);
        }
        for chapter in &mut self.chapters {
            let Some(href) = &chapter.resource_href else {
                continue;
            };
            let href_base = href.split('#').next().unwrap_or(href);
            let hit = toc_first.get(href_base).copied().or_else(|| {
                toc_first
                    .iter()
                    .find(|(k, _)| k.ends_with(href_base) || href_base.ends_with(k.as_str()))
                    .map(|(_, v)| *v)
            });
            if let Some(e) = hit {
                chapter.title = e.title.clone();
                chapter.level = e.level;
            }
        }

        // 8. spine 序上推 parent_index：父 = 最近的前一条严格更浅章节
        //    （TOC 条目序与 spine 序解耦——一个文件可被 0..N 个条目覆盖）
        let mut level_stack: Vec<usize> = Vec::new();
        for i in 0..self.chapters.len() {
            let lvl = self.chapters[i].level;
            while let Some(&top) = level_stack.last() {
                if self.chapters[top].level >= lvl {
                    level_stack.pop();
                } else {
                    break;
                }
            }
            self.chapters[i].parent_index = level_stack.last().copied();
            level_stack.push(i);
        }

        // 9. 封面提取（EPUB2 meta[name=cover] / EPUB3 properties=cover-image）
        let cover_data = opf_data.cover_href.as_ref().and_then(|href| {
            let full = self.join_opf_dir(href);
            match self.get_zip_entry(&full) {
                Ok(bytes) => Some(bytes),
                Err(e) => {
                    log::warn!("封面提取失败（{}）: {}", full, e);
                    None
                }
            }
        });

        let metadata = BookMetadata {
            title,
            author,
            cover_data,
            language,
            total_chapters: self.chapters.len(),
            file_size: self.file_size(),
            format: BookFormat::Epub,
        };

        self.metadata = Some(metadata.clone());

        Ok(metadata)
    }

    fn get_chapter_list(&self) -> Result<Vec<ChapterInfo>> {
        if self.chapters.is_empty() {
            return Err(anyhow::anyhow!("请先调用 parse() 解析书籍"));
        }
        Ok(self.chapters.clone())
    }

    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        let chapter = self.chapters.get(chapter_index)
            .ok_or_else(|| anyhow::anyhow!("章节索引越界: {}", chapter_index))?;

        let href = chapter.resource_href.as_deref()
            .ok_or_else(|| anyhow::anyhow!("章节没有关联的资源文件"))?;

        let zip_index = self.href_to_index.get(href)
            .ok_or_else(|| anyhow::anyhow!("无法找到章节文件: {}", href))?;

        let html_content = self.read_entry_as_string(*zip_index)?;

        // 使用增强的结构化文本提取
        let text = Self::html_to_text_structured(&html_content);

        Ok(text)
    }

    fn total_chapters(&self) -> usize {
        self.chapters.len()
    }

    fn cleanup(&mut self) {
        *self.archive.lock().unwrap() = None;
        self.metadata = None;
        self.chapters.clear();
        self.href_to_index.clear();
        self.spine_hrefs.clear();
        self.nav_href = None;
        self.ncx_href = None;
        self.css_cache.lock().unwrap().clear();
        self.fullscreen_hrefs.clear();
        self.clear_resource_cache();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clear_cell_indent_strips_nested_paragraphs() {
        use crate::content_ir::{ContentBlock, ListItem};
        let p = |indent: Option<f32>| ContentBlock::Paragraph {
            text: "单元格文本".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: None,
            is_comment: false,
            indent_first_line_em: indent,
            spacing_after_em: None,
            line_height: None,
        };
        // 单元格内容树：直接段落 + Quote 嵌套 + List 嵌套 + 非文本块
        let cell_tree = vec![
            p(Some(2.0)),
            ContentBlock::Quote {
                blocks: vec![p(Some(2.0))],
            },
            ContentBlock::List {
                ordered: false,
                items: vec![ListItem {
                    blocks: vec![p(Some(2.0))],
                }],
            },
            ContentBlock::Rule,
        ];
        let cleared = EpubParser::clear_cell_indent(cell_tree);
        let mut cleared_count = 0;
        for b in &cleared {
            match b {
                ContentBlock::Paragraph {
                    indent_first_line_em,
                    ..
                } => {
                    assert_eq!(*indent_first_line_em, None, "直接子段落应清零");
                    cleared_count += 1;
                }
                ContentBlock::Quote { blocks } => {
                    for q in blocks {
                        if let ContentBlock::Paragraph {
                            indent_first_line_em,
                            ..
                        } = q
                        {
                            assert_eq!(*indent_first_line_em, None, "Quote 内段落应清零");
                            cleared_count += 1;
                        }
                    }
                }
                ContentBlock::List { items, .. } => {
                    for it in items {
                        if let Some(ContentBlock::Paragraph {
                            indent_first_line_em,
                            ..
                        }) = it.blocks.first()
                        {
                            assert_eq!(*indent_first_line_em, None, "List 内段落应清零");
                            cleared_count += 1;
                        }
                    }
                }
                _ => {}
            }
        }
        assert_eq!(cleared_count, 3, "三处嵌套段落均应被处理");
    }

    #[test]
    fn test_html_to_text() {
        let html = r#"
        <html>
        <head><title>Test</title></head>
        <body>
            <h1>第一章</h1>
            <p>这是第一段内容。</p>
            <p>这是第二段内容。</p>
            <script>var x = 1;</script>
        </body>
        </html>
        "#;

        let text = EpubParser::html_to_text(html);
        assert!(text.contains("第一章"));
        assert!(text.contains("这是第一段内容"));
        assert!(text.contains("这是第二段内容"));
        assert!(!text.contains("var x = 1"));
    }

    #[test]
    fn test_parse_container_xml() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles>
        </container>"#;

        let opf_path = EpubParser::parse_container(xml).unwrap();
        assert_eq!(opf_path, "OEBPS/content.opf");
    }
    #[test]
    fn test_parse_opf_two_chapters() {
        let opf = r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">test-epub</dc:identifier>
    <dc:title>测试EPUB</dc:title>
    <dc:language>zh</dc:language>
    <meta property="dcterms:modified">2026-08-22T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>"#;

        let data = EpubParser::parse_opf(opf, "OEBPS").unwrap();
        assert_eq!(data.spine_hrefs.len(), 2, "spine 应有 2 条");
        assert!(data.spine_hrefs[0].ends_with("ch1.xhtml"));
        assert!(data.spine_hrefs[1].ends_with("ch2.xhtml"));
        // 自闭合 <item/> 必须被正确闭合（HTML 解析器时代的回归点）：
        // ncx 条目能被解析出来说明 manifest 全部 item 均按真实子节点遍历
        assert_eq!(data.metadata.get("dc:title").map(String::as_str), Some("测试EPUB"));
        assert_eq!(data.ncx_href.as_deref(), Some("toc.ncx"));
        assert_eq!(data.nav_href, None);
    }

    #[test]
    fn test_heading_border_bottom_css() {
        use crate::content_ir::ContentBlock;
        let sheet = crate::css_lite::CssStylesheet::parse(
            "h1.zw-text1 { border-bottom: solid 2px #2C7938; color: #2C7938; }",
        );
        let heading = ContentBlock::Heading {
            level: 1,
            text: "省俭有方".into(),
            align: None,
            color: None,
            font_scale: None,
            border_bottom: None,
            anc: Some(vec![
                vec!["body".into()],
                vec!["h1".into(), "zw-text1".into()],
            ]),
        };
        let ContentBlock::Heading { border_bottom, color, .. } =
            EpubParser::apply_css_to_block(heading, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        let b = border_bottom.expect("应解析出 border-bottom");
        assert_eq!(b.color, "#2c7938");
        assert!((b.width_px - 2.0).abs() < 0.01);
        assert_eq!(color.as_deref(), Some("#2c7938"));
    }

    #[test]
    fn test_is_cover_like_names() {
        // 瓦尔登湖 coverpage.html + 封面
        assert!(EpubParser::is_cover_like_names("OPS/coverpage.html", "封面"));
        assert!(EpubParser::is_cover_like_names("OEBPS/Text/Cover.xhtml", "Title"));
        // 仅标题命中
        assert!(EpubParser::is_cover_like_names("OPS/front001.html", "封面页"));
        // 正文章节不命中
        assert!(!EpubParser::is_cover_like_names("OPS/chapter001.html", "经济篇"));
        // uncover 等不得误伤
        assert!(!EpubParser::is_cover_like_names("OPS/uncover.html", "序"));
    }

    #[test]
    fn test_parse_opf_discovers_epub3_nav() {
        let opf = r#"<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Nav书</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>"#;

        let data = EpubParser::parse_opf(opf, "OEBPS").unwrap();
        assert_eq!(data.nav_href.as_deref(), Some("nav.xhtml"), "properties=\"nav\" 应被发现");
        assert_eq!(data.ncx_href, None);
        assert_eq!(data.spine_hrefs, vec!["OEBPS/text/ch1.xhtml".to_string()]);
    }

    #[test]
    fn test_parse_opf_fullscreen_pages() {
        // duokan-page-fullscreen（如《剑来》封面页）应被收集为全屏页
        let opf = r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>t</dc:title></metadata>
  <manifest>
    <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="cover" properties="duokan-page-fullscreen"/>
    <itemref idref="ch1"/>
  </spine>
</package>"#;

        let data = EpubParser::parse_opf(opf, "OEBPS").unwrap();
        assert!(
            data.fullscreen_hrefs.contains("OEBPS/Text/cover.xhtml"),
            "全屏页应按 OPF 目录合并为完整路径"
        );
        assert_eq!(data.fullscreen_hrefs.len(), 1);
    }

    #[test]
    fn test_parse_ncx_deeply_nested_no_overflow() {
        // 程序生成 1000 个嵌套 navPoint（旧递归实现在此必然栈溢出）
        let mut ncx = String::from(
            r#"<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>"#,
        );
        for i in 0..1000 {
            ncx.push_str(&format!(
                r#"<navPoint id="n{}" playOrder="{}"><navLabel><text>第 {} 章</text></navLabel><content src="ch{}.xhtml"/>"#,
                i, i, i, i
            ));
        }
        for _ in 0..1000 {
            ncx.push_str("</navPoint>");
        }
        ncx.push_str("</navMap></ncx>");

        // debug 测试线程默认栈仅 2MiB，roxmltree 递归解析在千层嵌套下
        // 需要更大栈（release 实测 1024 层在 1MiB 栈内正常）；
        // 真实 EPUB 的 NCX 层级通常 <20，此处取 1000 验证无递归爆炸。
        let handle = std::thread::Builder::new()
            .stack_size(16 * 1024 * 1024)
            .spawn(move || EpubParser::parse_ncx(&ncx, ""))
            .unwrap();
        let entries = handle.join().unwrap().unwrap();
        assert_eq!(entries.len(), 1000);
        assert_eq!(entries[999].href_full, "ch999.xhtml");
        assert_eq!(entries[999].title, "第 999 章");
    }

    #[test]
    fn test_parse_ncx_hierarchy_and_path_resolution() {
        // 嵌套：卷(1) > 章(2) > 节(3)；src 相对 toc.ncx 所在目录解析
        let ncx = r#"<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="v1"><navLabel><text>第一卷</text></navLabel><content src="vol1.xhtml"/>
            <navPoint id="c1"><navLabel><text>第一章</text></navLabel><content src="text/ch1.xhtml"/>
              <navPoint id="s1"><navLabel><text>第一节</text></navLabel><content src="text/ch1.xhtml#s1"/></navPoint>
            </navPoint>
            <navPoint id="c2"><navLabel><text>第二章</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
          </navPoint>
          <navPoint id="v2"><navLabel><text>第二卷</text></navLabel><content src="vol2.xhtml"/></navPoint>
        </navMap></ncx>"#;

        let entries = EpubParser::parse_ncx(ncx, "OEBPS").unwrap();
        assert_eq!(entries.len(), 5);
        assert_eq!(entries[0].level, 1);
        assert_eq!(entries[0].href_full, "OEBPS/vol1.xhtml");
        // 嵌套子项的相对路径按 TOC 文件目录解析
        assert_eq!(entries[1].href_full, "OEBPS/text/ch1.xhtml");
        assert_eq!(entries[1].level, 2);
        assert_eq!(entries[2].level, 3);
        // 片段标识符剥离后与 ch1 同路径
        assert_eq!(entries[2].href_full, "OEBPS/text/ch1.xhtml");
        assert_eq!(entries[4].level, 1);

        // spine 序 parent 推导规则验证（模拟章节序 = 条目序）
        let mut parents: Vec<Option<usize>> = vec![None; entries.len()];
        let mut stack: Vec<usize> = Vec::new();
        for i in 0..entries.len() {
            while let Some(&top) = stack.last() {
                if entries[top].level >= entries[i].level {
                    stack.pop();
                } else {
                    break;
                }
            }
            parents[i] = stack.last().copied();
            stack.push(i);
        }
        assert_eq!(parents, vec![None, Some(0), Some(1), Some(0), None]);
    }

    #[test]
    fn test_parse_ncx_multi_entry_same_file_first_wins() {
        // 同一文件多个条目（锚点差异）：文档序首条的标题应胜出
        let ncx = r#"<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="n1"><navLabel><text>开篇</text></navLabel><content src="ch1.xhtml"/></navPoint>
          <navPoint id="n2"><navLabel><text>中段</text></navLabel><content src="ch1.xhtml#mid"/></navPoint>
        </navMap></ncx>"#;

        let entries = EpubParser::parse_ncx(ncx, "").unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].href_full, "ch1.xhtml");
        assert_eq!(entries[1].href_full, "ch1.xhtml");
        // 匹配表构建时 or_insert 保证首条胜出（确定性，不依赖哈希序）
    }

    #[test]
    fn test_parse_ncx_with_doctype_dtd() {
        // 真实书籍（如 Z-Library 转换版）NCX 带外部 DTD 声明——
        // roxmltree 默认拒绝 DTD 导致整个目录解析失败（回归点）
        let ncx = r#"<?xml version="1.0" encoding="utf-8" ?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
 "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd"><ncx version="2005-1" xmlns="http://www.daisy.org/z3986/2005/ncx/">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>封面</text></navLabel>
      <content src="Text/cover.xhtml"/>
      <navPoint id="n2" playOrder="2">
        <navLabel><text>第一章 惊蛰</text></navLabel>
        <content src="Text/chapter-1.xhtml"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>"#;

        let entries = EpubParser::parse_ncx(ncx, "OEBPS").unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].href_full, "OEBPS/Text/cover.xhtml");
        assert_eq!(entries[0].title, "封面");
        assert_eq!(entries[0].level, 1);
        assert_eq!(entries[1].href_full, "OEBPS/Text/chapter-1.xhtml");
        assert_eq!(entries[1].level, 2);
    }

    #[test]
    fn test_parse_ncx_cdata_and_entities() {
        let ncx = r#"<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
          <navPoint id="n1"><navLabel><text><![CDATA[序章 &amp; 楔子]]></text></navLabel><content src="intro.xhtml"/></navPoint>
          <navPoint id="n2"><navLabel><text>第一章 &#19978;&#28023;</text></navLabel><content src="ch1.xhtml#sec1"/></navPoint>
        </navMap></ncx>"#;

        let entries = EpubParser::parse_ncx(ncx, "").unwrap();
        assert_eq!(entries.len(), 2);
        // XML 规范：CDATA 内实体不解码，保持字面量
        assert_eq!(entries[0].href_full, "intro.xhtml");
        assert_eq!(entries[0].title, "序章 &amp; 楔子");
        // 普通文本节点的数字字符引用应被解码；片段标识符应被剥离
        assert_eq!(entries[1].href_full, "ch1.xhtml");
        assert_eq!(entries[1].title, "第一章 上海");
    }

    #[test]
    fn test_parse_nav_xhtml_prefers_typed_nav() {
        let nav = r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>TOC</title></head>
<body>
  <nav epub:type="landmarks" hidden="">
    <ol><li><a epub:type="bodymatter" href="ch1.xhtml">开始阅读</a></li></ol>
  </nav>
  <nav epub:type="toc">
    <ol>
      <li><a href="ch1.xhtml">第一章</a></li>
      <li><a href="ch2.xhtml">第二章</a></li>
    </ol>
  </nav>
</body>
</html>"#;

        let entries = EpubParser::parse_nav_xhtml(nav, "").unwrap();
        assert_eq!(entries.len(), 2, "应取 epub:type=toc 的 nav 而非首个 landmarks");
        // 最外层 <ol> 内条目为 level 1
        assert_eq!(entries[0].level, 1);
        assert_eq!(entries[0].href_full, "ch1.xhtml");
        assert_eq!(entries[0].title, "第一章");
        assert_eq!(entries[1].href_full, "ch2.xhtml");
        assert_eq!(entries[1].title, "第二章");
    }

    #[test]
    fn test_parse_nav_xhtml_nested_ol_levels() {
        let nav = r#"<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body>
  <nav epub:type="toc">
    <ol>
      <li><a href="part1.xhtml">第一卷</a>
        <ol>
          <li><a href="ch1.xhtml">第一章</a></li>
          <li><a href="ch2.xhtml">第二章</a></li>
        </ol>
      </li>
      <li><a href="part2.xhtml">第二卷</a></li>
    </ol>
  </nav>
</body>
</html>"#;

        let entries = EpubParser::parse_nav_xhtml(nav, "").unwrap();
        assert_eq!(entries.len(), 4);
        let levels: Vec<u8> = entries.iter().map(|e| e.level).collect();
        assert_eq!(levels, vec![1, 2, 2, 1]);
        assert_eq!(entries[1].href_full, "ch1.xhtml");
    }

    /// 真实书籍诊断探针（默认忽略）：EBOOK_PROBE_PATH=路径 cargo test -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_book_toc_probe() {
        let path = match std::env::var("EBOOK_PROBE_PATH") {
            Ok(p) if !p.is_empty() => p,
            _ => return,
        };
        let mut parser = EpubParser::from_file(std::path::Path::new(&path)).unwrap();
        parser.parse().unwrap();

        println!("=== 内部状态 ===");
        println!("opf_base_path = {:?}", parser.opf_base_path);
        println!("ncx_href = {:?}", parser.ncx_href);
        println!("nav_href = {:?}", parser.nav_href);
        println!(
            "spine_hrefs[0..5] = {:?}",
            &parser.spine_hrefs[..5.min(parser.spine_hrefs.len())]
        );

        // 列出 ZIP 内与目录相关的真实条目名（大小写敏感！）
        {
            let mut guard = parser.archive.lock().unwrap();
            let archive = guard.as_mut().unwrap();
            println!("=== ZIP 条目（含 toc/ncx/opf）===");
            for i in 0..archive.len() {
                let name = archive.by_index(i).unwrap().name().to_string();
                let lower = name.to_lowercase();
                if lower.contains("ncx") || lower.ends_with(".opf") || lower.contains("container")
                {
                    println!("  ENTRY: {:?}", name);
                }
            }
        }

        let toc_entries = parser.parse_toc().unwrap_or_default();
        println!("toc_entries.len() = {}", toc_entries.len());

        // 定位：读取与解析分别验证
        match parser.read_toc_candidate("OEBPS/toc.ncx") {
            None => println!("READ FAILED: OEBPS/toc.ncx"),
            Some((name, content)) => {
                println!(
                    "READ ok: {:?} len={} head={:?}",
                    name,
                    content.len(),
                    &content[..120.min(content.len())]
                );
                match EpubParser::parse_ncx(&content, "OEBPS") {
                    Ok(v) => println!("PARSE ok: {} entries", v.len()),
                    Err(e) => println!("PARSE ERR: {}", e),
                }
            }
        }

        for e in toc_entries.iter().take(10) {
            println!("  TOC {:?} lvl={} {:?}", e.href_full, e.level, e.title);
        }

        // 匹配诊断：前 10 章的命中情况
        let mut first: HashMap<String, &TocEntry> = HashMap::new();
        for e in &toc_entries {
            first.entry(e.href_full.clone()).or_insert(e);
        }
        println!("=== 章节（前 10）===");
        for ch in parser.chapters.iter().take(10) {
            let base = ch
                .resource_href
                .as_deref()
                .map(|h| h.split('#').next().unwrap_or(h))
                .unwrap_or("");
            let hit = first.get(base).is_some()
                || first.iter().any(|(k, _)| {
                    k.ends_with(base) || base.ends_with(k.as_str())
                });
            println!(
                "  CH lvl={} parent={:?} hit={} href={:?} title={:?}",
                ch.level, ch.parent_index, hit, base, ch.title
            );
        }
        println!("total_chapters = {}", parser.chapters.len());
    }

    /// CSS 物化端到端：《剑来》main.css 真实形态
    /// （h2.head1 块级样式、span.txtu 行内颜色、td 列宽、table margin-top）
    #[test]
    fn css_materializes_jianlai_patterns() {
        use crate::content_ir::{ContentBlock, StyledRun, TableCell};

        let sheet = crate::css_lite::CssStylesheet::parse(
            "h2.head1 {\n\
            \x20 font-size:0.7em;\n\
            \x20 color: #b50a02;\n\
            \x20 text-align: left;\n\
            }\n\
            .txtu { color: #b50a02; }\n\
            .txtu2 { color:#498428; }\n\
            table.vol-title {\n\
            \x20 margin: 20% 0 0 auto;\n\
            \x20 color: #000000;\n\
            }\n\
            td.vol-title-name {\n\
            \x20 width: 1.2em;\n\
            \x20 vertical-align: top;\n\
            \x20 padding: 0;\n\
            \x20 text-align: center;\n\
            \x20 font-size: 1.4em;\n\
            }",
        );

        // h2.head1：块级颜色 + 字号倍率 + 对齐
        let heading = ContentBlock::Heading {
            level: 2,
            text: "注".into(),
            align: None,
            color: None,
            font_scale: None,
            border_bottom: None,
            anc: Some(vec![vec!["body".into()], vec!["h2".into(), "head1".into()]]),
        };
        let ContentBlock::Heading { align, color, font_scale, .. } =
            EpubParser::apply_css_to_block(heading, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(align, Some(crate::content_ir::Align::Left));
        assert_eq!(color.as_deref(), Some("#b50a02"));
        assert_eq!(font_scale, Some(0.7));

        // 段内 span 颜色：runs 物化后携带色值、anc 剥离前可解析
        let para = ContentBlock::Paragraph {
            text: "红绿白".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                StyledRun { start: 0, end: 1, color: None, font_scale: None, bold: false, italic: false, underline: false, anc: Some(vec![vec!["body".into()], vec!["p".into()], vec!["span".into(), "txtu".into()]]), footnote_ref: None },
                StyledRun { start: 1, end: 2, color: None, font_scale: None, bold: false, italic: false, underline: false, anc: Some(vec![vec!["body".into()], vec!["p".into()], vec!["span".into(), "txtu2".into()]]), footnote_ref: None },
                StyledRun { start: 2, end: 3, color: None, font_scale: None, bold: false, italic: false, underline: false, anc: Some(vec![vec!["body".into()], vec!["p".into()], vec!["span".into()]]), footnote_ref: None },
            ],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(runs[0].color.as_deref(), Some("#b50a02"));
        assert_eq!(runs[1].color.as_deref(), Some("#498428"));
        assert_eq!(runs[2].color, None, "无类 span 不应误染");
        // 越界/空区间防御
        assert!(EpubParser::resolve_runs(
            vec![
                StyledRun { start: 99, end: 100, color: None, font_scale: None, bold: false, italic: false, underline: false, anc: None, footnote_ref: None },
                StyledRun { start: 1, end: 1, color: None, font_scale: None, bold: false, italic: false, underline: false, anc: None, footnote_ref: None },
            ],
            &sheet,
            3,
            DEFAULT_BASE_FONT_PX,
        )
        .is_empty());

        // 卷首标题表：margin-top 百分比 + td 列宽 em + 单元格段落
        // 继承 table 的 color 与 td 的字号/对齐
        let table = ContentBlock::Table {
            caption: None,
            rows: vec![vec![
                TableCell {
                    header: false,
                    blocks: vec![ContentBlock::Paragraph {
                        text: "卷".into(),
                        align: None,
                        color: None,
                        font_scale: None,
                        runs: Vec::new(),
                        // JS 层 cellContent 产出的段落携带 td 完整链路
                        anc: Some(vec![
                            vec!["body".into()],
                            vec!["table".into(), "vol-title".into()],
                            vec!["tr".into()],
                            vec!["td".into(), "vol-title-name".into()],
                        ]),
                        is_comment: false,
                        indent_first_line_em: None,
                        spacing_after_em: None,
                        line_height: None,
                    }],
                    anc: Some(vec![
                        vec!["body".into()],
                        vec!["table".into(), "vol-title".into()],
                        vec!["tr".into()],
                        vec!["td".into(), "vol-title-name".into()],
                    ]),
                    width_em: None,
                },
            ]],
            anc: Some(vec![
                vec!["body".into()],
                vec!["table".into(), "vol-title".into()],
            ]),
            margin_top_percent: None,
            margin_left_auto: false,
        };
        let ContentBlock::Table { margin_top_percent, margin_left_auto, rows, .. } =
            EpubParser::apply_css_to_block(table, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(margin_top_percent, Some(20.0));
        assert!(margin_left_auto, "margin:20% 0 0 auto 的第四值应右置表格");
        assert_eq!(rows[0][0].width_em, Some(1.2));
        let ContentBlock::Paragraph { align, color, font_scale, .. } = &rows[0][0].blocks[0]
        else {
            panic!("单元格应为段落");
        };
        assert_eq!(*align, Some(crate::content_ir::Align::Center));
        assert_eq!(color.as_deref(), Some("#000000"), "table 级 color 应继承到单元格");
        assert_eq!(*font_scale, Some(1.4));
    }

    /// 字形样式物化：标签 UA 默认语义 + CSS 声明覆盖（CSS 胜出）
    #[test]
    fn glyph_semantics_materialize_from_tags_and_css() {
        use crate::content_ir::{ContentBlock, StyledRun};

        let mk = |start: usize,
                  end: usize,
                  chain: Vec<Vec<&str>>|
         -> StyledRun {
            StyledRun {
                start,
                end,
                color: None,
                font_scale: None,
                bold: false,
                italic: false,
                underline: false,
                anc: Some(
                    chain
                        .into_iter()
                        .map(|e| e.into_iter().map(String::from).collect())
                        .collect(),
                ),
                footnote_ref: None,
            }
        };

        // 标签默认：strong/b 粗、em 斜、a 下划线；普通 span 无字形
        let sheet = crate::css_lite::CssStylesheet::parse("");
        let para = ContentBlock::Paragraph {
            text: "粗粗斜链常".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                mk(0, 1, vec![vec!["body"], vec!["p"], vec!["strong"]]),
                mk(1, 2, vec![vec!["body"], vec!["p"], vec!["b"]]),
                mk(2, 3, vec![vec!["body"], vec!["p"], vec!["em"]]),
                mk(3, 4, vec![vec!["body"], vec!["p"], vec!["a", "link"]]),
                mk(4, 5, vec![vec!["body"], vec!["p"], vec!["span"]]),
            ],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(runs[0].bold && !runs[0].italic && !runs[0].underline);
        assert!(runs[1].bold);
        assert!(runs[2].italic && !runs[2].bold);
        assert!(runs[3].underline);
        assert!(!runs[4].bold && !runs[4].italic && !runs[4].underline);

        // CSS 覆盖：类命中加粗；显式 normal 阻断 i 的默认斜体；
        // em.it 双源一致斜体
        let sheet = crate::css_lite::CssStylesheet::parse(
            ".bl { font-weight: bold; }\n\
             .up { font-style: normal; }\n\
             .it { font-style: italic; }",
        );
        let para2 = ContentBlock::Paragraph {
            text: "甲乙丙".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                mk(0, 1, vec![vec!["body"], vec!["p"], vec!["span", "bl"]]),
                mk(1, 2, vec![vec!["body"], vec!["p"], vec!["i", "up"]]),
                mk(2, 3, vec![vec!["body"], vec!["p"], vec!["em", "it"]]),
            ],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para2, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(runs[0].bold, "CSS font-weight:bold 应命中 span.bl");
        assert!(
            !runs[1].italic,
            "显式 font-style:normal 应阻断 i 的 UA 默认斜体"
        );
        assert!(runs[2].italic, "em 与 CSS 双源一致");

        // 数值字重按 CSS 级联语义整体覆盖：700→粗、400→显式常规
        let sheet = crate::css_lite::CssStylesheet::parse(
            ".w7 { font-weight: 700; }\n.w4 { font-weight: 400; }",
        );
        let para3 = ContentBlock::Paragraph {
            text: "甲乙".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                mk(0, 1, vec![vec!["body"], vec!["p"], vec!["span", "w7"]]),
                mk(1, 2, vec![vec!["body"], vec!["p"], vec!["b", "w4"]]),
            ],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para3, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(runs[0].bold);
        assert!(!runs[1].bold, "数值 400 应覆盖 b 的 UA 默认粗体");
    }

    /// ruby 注音：rt run 默认小字倍率，CSS font-size 命中时覆盖
    #[test]
    fn ruby_rt_scale_defaults_and_css_override() {
        use crate::content_ir::{ContentBlock, StyledRun};

        let mk = |chain: Vec<Vec<&str>>| -> StyledRun {
            StyledRun {
                start: 0,
                end: 1,
                color: None,
                font_scale: None,
                bold: false,
                italic: false,
                underline: false,
                anc: Some(
                    chain
                        .into_iter()
                        .map(|e| e.into_iter().map(String::from).collect())
                        .collect(),
                ),
                footnote_ref: None,
            }
        };

        // 无 CSS 声明 → 默认 RUBY_SCALE
        let sheet = crate::css_lite::CssStylesheet::parse("");
        let para = ContentBlock::Paragraph {
            text: "甲注".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![mk(vec![
                vec!["body"],
                vec!["p"],
                vec!["ruby"],
                vec!["rt"],
            ])],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(runs[0].font_scale, Some(RUBY_SCALE));

        // CSS 命中 → 覆盖默认值
        let sheet = crate::css_lite::CssStylesheet::parse("rt { font-size: 0.6em; }");
        let para = ContentBlock::Paragraph {
            text: "甲注".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![mk(vec![
                vec!["body"],
                vec!["p"],
                vec!["ruby"],
                vec!["rt"],
            ])],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(
            runs[0].font_scale,
            Some(0.6),
            "CSS font-size 应覆盖 ruby 默认缩放"
        );

        // 非 rt 行内元素不受影响
        let sheet = crate::css_lite::CssStylesheet::parse("");
        let para = ContentBlock::Paragraph {
            text: "甲乙".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![mk(vec![vec!["body"], vec!["p"], vec!["span"]])],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(runs[0].font_scale, None);
    }

    /// S6：px/pt 字号换算（以基准字号折算）与 rgb()/命名色解析
    #[test]
    fn px_pt_font_scale_and_rgb_named_colors() {
        use crate::content_ir::{ContentBlock, StyledRun};

        let run_with_class = |classes: &[&str]| -> StyledRun {
            StyledRun {
                start: 0,
                end: 1,
                color: None,
                font_scale: None,
                bold: false,
                italic: false,
                underline: false,
                anc: Some(vec![
                    vec!["body".into()],
                    vec!["p".into()],
                    {
                        let mut e = vec!["span".to_string()];
                        e.extend(classes.iter().map(|s| s.to_string()));
                        e
                    },
                ]),
                footnote_ref: None,
            }
        };

        // px 换算：28px / 基准 18
        let sheet =
            crate::css_lite::CssStylesheet::parse("h2 { font-size: 28px; }");
        let heading = ContentBlock::Heading {
            level: 2,
            text: "大".into(),
            align: None,
            color: None,
            font_scale: None,
            border_bottom: None,
            anc: Some(vec![vec!["body".into()], vec!["h2".into()]]),
        };
        let ContentBlock::Heading { font_scale, .. } =
            EpubParser::apply_css_to_block(heading, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(font_scale, Some(28.0 / 18.0), "px 应按基准字号换算");

        // pt 换算：14pt = 14·4/3 px，再除以基准
        let sheet =
            crate::css_lite::CssStylesheet::parse("td { font-size: 14pt; }");
        let para = ContentBlock::Paragraph {
            text: "格".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: Some(vec![
                vec!["body".into()],
                vec!["table".into()],
                vec!["tr".into()],
                vec!["td".into()],
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { font_scale, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(font_scale, Some(14.0 * 4.0 / 3.0 / DEFAULT_BASE_FONT_PX));

        // 颜色：rgb()/rgba(alpha 忽略)/命名色/未知色
        let sheet = crate::css_lite::CssStylesheet::parse(
            ".c1 { color: rgb(181,10,2); }\n\
             .c2 { color: rgba(0, 255, 0, 0.5); }\n\
             .c3 { color: red; }\n\
             .c4 { color: notacolor; }",
        );
        let para = ContentBlock::Paragraph {
            text: "甲乙丙丁".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![
                run_with_class(&["c1"]),
                run_with_class(&["c2"]),
                run_with_class(&["c3"]),
                run_with_class(&["c4"]),
            ],
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { runs, .. } =
            EpubParser::apply_css_to_block(para, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert_eq!(runs[0].color.as_deref(), Some("#b50a02"));
        assert_eq!(
            runs[1].color.as_deref(),
            Some("#00ff00"),
            "rgba 的 alpha 忽略按不透明处理"
        );
        assert_eq!(runs[2].color.as_deref(), Some("#ff0000"));
        assert_eq!(runs[3].color, None, "未知颜色回落主题默认");
    }

    /// M9 P1：本章说检测修正测试
    /// 测试收紧后的门槛和三重验证逻辑
    #[test]
    fn comment_detection_stricter_threshold() {
        use crate::content_ir::ContentBlock;

        let sheet = crate::css_lite::CssStylesheet::parse(
            "p.small { font-size: 14px; }"  // 14/18 = 0.778 < 0.85 但 > 0.75
        );

        // 场景 1: font_scale=0.8（14px/18px），短文本，但无正向特征 → 不应标记为注释
        let para_normal_small = ContentBlock::Paragraph {
            text: "这是一段小字号的正文，不应被误判为注释。".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![],
            anc: Some(vec![
                vec!["body".into()],
                vec!["p".into(), "".into(), "small".into()],
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { is_comment, .. } =
            EpubParser::apply_css_to_block(para_normal_small, &sheet, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(!is_comment, "font_scale=0.778 > 0.75，不应标记为注释");

        // 场景 2: font_scale=0.7（12.6px/18px），短文本，有 aside 祖先 → 应标记为注释
        let sheet2 = crate::css_lite::CssStylesheet::parse(
            "aside p { font-size: 12.6px; }"  // 12.6/18 = 0.7 < 0.75
        );
        let para_aside = ContentBlock::Paragraph {
            text: "这是脚注内容".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![],
            anc: Some(vec![
                vec!["body".into()],
                vec!["aside".into()],
                vec!["p".into()],
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { is_comment, .. } =
            EpubParser::apply_css_to_block(para_aside, &sheet2, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(is_comment, "font_scale=0.7 + aside 祖先 → 应标记为注释");

        // 场景 3: font_scale=0.7，短文本，有 footnote 类名 → 应标记为注释
        let sheet3 = crate::css_lite::CssStylesheet::parse(
            "p.footnote { font-size: 12.6px; }"  // 12.6/18 = 0.7 < 0.75
        );
        let para_footnote_class = ContentBlock::Paragraph {
            text: "脚注文本".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: vec![],
            anc: Some(vec![
                vec!["body".into()],
                vec!["p".into(), "footnote".into()],  // 格式：[tag, class1, class2, ...]
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let result = EpubParser::apply_css_to_block(para_footnote_class, &sheet3, DEFAULT_BASE_FONT_PX);
        let ContentBlock::Paragraph { is_comment, .. } = result
        else {
            panic!("结构不应改变");
        };
        assert!(is_comment, "font_scale=0.7 + footnote 类名 → 应标记为注释");

        // 场景 4: font_scale=0.7，短文本，居中对齐 → 应标记为注释
        let sheet4 = crate::css_lite::CssStylesheet::parse(
            "p.small { font-size: 12.6px; }"  // 12.6/18 = 0.7 < 0.75
        );
        let para_centered = ContentBlock::Paragraph {
            text: "居中小字".into(),
            align: Some(crate::content_ir::Align::Center),
            color: None,
            font_scale: None,
            runs: vec![],
            anc: Some(vec![
                vec!["body".into()],
                vec!["p".into(), "small".into()],  // 格式：[tag, class1, ...]
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { is_comment, .. } =
            EpubParser::apply_css_to_block(para_centered, &sheet4, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(is_comment, "font_scale=0.7 + 居中对齐 → 应标记为注释");

        // 场景 5: font_scale=0.7，但文本过长（>150 字符） → 不应标记为注释
        let long_text = "这是一段很长的文本。".repeat(30); // 30 * 10 = 300 字符
        let para_long = ContentBlock::Paragraph {
            text: long_text,
            align: None,
            color: None,
            font_scale: None,
            runs: vec![],
            anc: Some(vec![
                vec!["body".into()],
                vec!["aside".into()],
                vec!["p".into()],
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let ContentBlock::Paragraph { is_comment, .. } =
            EpubParser::apply_css_to_block(para_long, &sheet2, DEFAULT_BASE_FONT_PX)
        else {
            panic!("结构不应改变");
        };
        assert!(!is_comment, "即使有 aside 祖先，超过 150 字符不应标记为注释");
    }

    /// P2 排版批次：CSS margin-bottom / line-height / text-align:justify
    /// 三项物化（段后间距取 em 倍数；行高倍率含无单位数字；justify 不再折叠 Left）
    #[test]
    fn css_materializes_spacing_line_height_and_justify() {
        use crate::content_ir::ContentBlock;

        let sheet = crate::css_lite::CssStylesheet::parse(
            "p.gap { margin-bottom: 1.5em; }\n\
             p.lh { line-height: 1.8; }\n\
             p.lhp { line-height: 200%; }\n\
             p.px { margin-bottom: 36px; }\n\
             p.jt { text-align: justify; }\n\
             p.inherit-lh { line-height: 3; }",
        );
        let mk = |class: &str, text: &str| ContentBlock::Paragraph {
            text: text.into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: Some(vec![
                vec!["body".into()],
                vec!["p".into(), class.into()],
            ]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let base = DEFAULT_BASE_FONT_PX;

        // margin-bottom: 1.5em → spacing_after_em=1.5
        let r = match EpubParser::apply_css_to_block(mk("gap", "甲"), &sheet, base) {
            ContentBlock::Paragraph {
                spacing_after_em, ..
            } => spacing_after_em,
            _ => panic!("结构不应改变"),
        };
        assert_eq!(r, Some(1.5), "margin-bottom:1.5em 应物化为段后间距");

        // margin-bottom: 36px → 36/18 = 2.0 em
        let r = match EpubParser::apply_css_to_block(mk("px", "甲"), &sheet, base) {
            ContentBlock::Paragraph {
                spacing_after_em, ..
            } => spacing_after_em,
            _ => panic!("结构不应改变"),
        };
        assert!((r.unwrap() - 2.0).abs() < 1e-4, "36px/18px 应折算 2.0em");

        // line-height: 1.8（无单位数字，最常见形态）
        let r = match EpubParser::apply_css_to_block(mk("lh", "甲"), &sheet, base) {
            ContentBlock::Paragraph { line_height, .. } => line_height,
            _ => panic!("结构不应改变"),
        };
        assert_eq!(r, Some(1.8), "无单位 line-height 应物化为倍率");

        // line-height: 200% → 2.0
        let r = match EpubParser::apply_css_to_block(mk("lhp", "甲"), &sheet, base) {
            ContentBlock::Paragraph { line_height, .. } => line_height,
            _ => panic!("结构不应改变"),
        };
        assert!((r.unwrap() - 2.0).abs() < 1e-4, "200% 应折算 2.0");

        // text-align: justify 不再折叠为 Left
        let r = match EpubParser::apply_css_to_block(mk("jt", "甲"), &sheet, base) {
            ContentBlock::Paragraph { align, .. } => align,
            _ => panic!("结构不应改变"),
        };
        assert_eq!(r, Some(crate::content_ir::Align::Justify));

        // line-height 继承属性：p 外层声明经 body 继承（margin-bottom 则不继承）
        let sheet2 = crate::css_lite::CssStylesheet::parse("body { line-height: 3; margin-bottom: 2em; }");
        let para = ContentBlock::Paragraph {
            text: "甲".into(),
            align: None,
            color: None,
            font_scale: None,
            runs: Vec::new(),
            anc: Some(vec![vec!["body".into()], vec!["p".into()]]),
            is_comment: false,
            indent_first_line_em: None,
            spacing_after_em: None,
            line_height: None,
        };
        let r = match EpubParser::apply_css_to_block(para, &sheet2, base) {
            ContentBlock::Paragraph {
                line_height,
                spacing_after_em,
                ..
            } => (line_height, spacing_after_em),
            _ => panic!("结构不应改变"),
        };
        assert_eq!(r.0, Some(3.0), "line-height 为继承属性，body 声明应传导");
        assert_eq!(
            r.1, None,
            "margin 为非继承属性，body 声明不得传导到子段"
        );
    }
}
