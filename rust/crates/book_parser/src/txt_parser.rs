use crate::traits::{BookFormat, BookMetadata, BookParser, ChapterInfo, ResourceType};
use crate::{Book, Chapter};
use crate::encoding::{EncodingInfo, SmartEncodingDetector};
use crate::chapter_extractor::ChapterExtractor;
use crate::content_cleaner::{ContentCleaner, ConvertMode, ParagraphMode, CleanOptions};
use anyhow::{Context, Result};
use memmap2::Mmap;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

/// TXT 解析器
///
/// 章节偏移一律基于全量解码后的文本（与 to_book/切片同源，D3）；
/// 识别统一走 JS 引擎（正则仅兜底，D9）。
pub struct TxtParser {
    /// 文件路径
    file_path: Option<std::path::PathBuf>,
    /// 解码后的完整文本内容
    content: Option<String>,
    /// 解析出的章节列表（解码文本上的字节偏移，运行时缓存）
    chapters: Vec<RawChapter>,
    /// 净化后的章节缓存（首次阅读时生成）
    cleaned_chapter_cache: Option<CleanedChapterCache>,
    /// 元信息（parse 后填充）
    metadata: Option<BookMetadata>,
    /// 检测到的编码信息
    encoding_info: Option<EncodingInfo>,
    /// 内容净化器（可选）
    content_cleaner: Option<ContentCleaner>,
}

/// 内部章节结构（包含字节偏移，用于运行时缓存）
#[derive(Debug, Clone)]
struct RawChapter {
    title: String,
    start_pos: usize,
    end_pos: usize,
}

/// 净化后的章节缓存
#[derive(Debug)]
struct CleanedChapterCache {
    /// 净化配置的哈希值（配置变更时用于失效重建）
    config_hash: u64,
    /// 净化后的章节偏移列表
    chapters: Vec<CleanedChapterOffset>,
    /// 大文本：净化后内容存储在临时文件 mmap
    cleaned_mmap: Option<Mmap>,
    /// 常规文本：净化后内容存储在内存
    cleaned_content: Option<String>,
}

/// 净化副本超过该大小（字节）时落盘 mmap 存储
const CLEANED_MMAP_THRESHOLD_BYTES: usize = 10 * 1024 * 1024;

/// 净化后的章节偏移
#[derive(Debug, Clone)]
struct CleanedChapterOffset {
    start_pos: usize,
    end_pos: usize,
}

/// 锁外重建所需输入快照（bridge 层在读锁内采集，BOOKS 锁外构建——
/// 见 lib.rs BOOKS 锁纪律；成本 = content 克隆，仅重建路径支付）
pub struct CleanedCacheBuildSnapshot {
    content: String,
    chapters: Vec<RawChapter>,
    cleaner: Option<ContentCleaner>,
    file_path: Option<std::path::PathBuf>,
}

/// 锁外构建产物（不透明；经 install_cleaned_cache 校验 hash 后装回）
pub struct BuiltCleanedChapterCache(CleanedChapterCache);

/// 行号到字节偏移的映射器
struct LineOffsetMapper {
    /// 原始行号 → 净化后字节偏移的映射
    line_offsets: Vec<usize>,
}

impl LineOffsetMapper {
    /// 构建行号 → 字节偏移的映射
    /// 
    /// 参数：
    /// - cleaned_content: 净化后的完整文本
    /// 
    /// 用原始字节扫描 '\n' 计算行起始偏移，兼容 \n 与 \r\n
    /// （lines() 会剥掉 \r，累加 len()+1 会在 CRLF 上漂移）
    fn build(cleaned_content: &str) -> Self {
        let mut line_offsets = Vec::new();
        
        // 第一行从偏移0开始
        line_offsets.push(0);
        
        for (i, b) in cleaned_content.bytes().enumerate() {
            if b == b'\n' {
                line_offsets.push(i + 1);
            }
        }
        
        Self { line_offsets }
    }
    
    /// 将原始行号映射到净化后内容的字节偏移
    /// 
    /// 注意：由于净化可能删除整行，这里返回的是最接近的有效偏移
    fn map_line_to_offset(&self, line_number: usize) -> usize {
        if line_number < self.line_offsets.len() {
            self.line_offsets[line_number]
        } else {
            // 如果行号超出范围，返回最后一个偏移
            self.line_offsets.last().copied().unwrap_or(0)
        }
    }
}

impl TxtParser {
    /// 从文件路径创建 TXT 解析器
    ///
    /// 统一语义（A2/D3）：章节偏移一律基于**全量解码后的文本**（与 to_book /
    /// 章节切片同源），识别走 JS 引擎（正则仅兜底）。
    /// 此前大文件 mmap 流式识别产出「文件字节+解码偏移」混合物，
    /// GBK 等多字节编码下章节边界系统性错位，且存在 D2 禁止的
    /// lines().len()+1 累加——已随本统一删除。
    pub fn from_file(path: &Path) -> Result<Self> {
        let buffer = std::fs::read(path)
            .with_context(|| format!("无法读取文件: {}", path.display()))?;

        let (content, encoding_info) = Self::decode_text(&buffer)?;

        let mut parser = Self {
            file_path: Some(path.to_path_buf()),
            content: Some(content),
            chapters: Vec::new(),
            cleaned_chapter_cache: None,
            metadata: None,
            encoding_info: Some(encoding_info),
            content_cleaner: None, // 默认不启用内容净化
        };

        // 立即解析章节（JS 优先，正则兜底）
        parser.chapters = parser.extract_chapters();

        Ok(parser)
    }

    /// 从 Reader 创建 TXT 解析器（用于测试，小文件模式）
    pub fn from_reader<R: Read>(reader: R, book_name: Option<String>) -> Result<Self> {
        let mut buf_reader = BufReader::new(reader);
        let mut buffer = Vec::new();
        buf_reader.read_to_end(&mut buffer)
            .with_context(|| "读取数据失败")?;

        let (content, encoding_info) = Self::decode_text(&buffer)?;

        let mut parser = Self {
            file_path: None,
            content: Some(content),
            chapters: Vec::new(),
            cleaned_chapter_cache: None,
            metadata: None,
            encoding_info: Some(encoding_info),
            content_cleaner: None, // 默认不启用内容净化
        };

        // 立即解析章节
        parser.chapters = parser.extract_chapters();

        let title = book_name.unwrap_or_else(|| "未命名书籍".to_string());
        parser.metadata = Some(BookMetadata {
            title,
            author: String::new(),
            cover_data: None,
            language: "zh".to_string(),
            total_chapters: parser.chapters.len(),
            file_size: buffer.len() as u64,
            format: BookFormat::Txt,
        });

        Ok(parser)
    }

    /// 获取检测到的编码信息
    pub fn get_encoding_info(&self) -> Option<&EncodingInfo> {
        self.encoding_info.as_ref()
    }

    /// 转换为向后兼容的 Book 对象
    pub fn to_book(&self, book_name: Option<String>) -> Result<Book> {
        let title = if let Some(name) = book_name {
            name
        } else if let Some(ref metadata) = self.metadata {
            metadata.title.clone()
        } else {
            "未命名书籍".to_string()
        };

        // 获取完整内容
        let content = self.content.clone()
            .ok_or_else(|| anyhow::anyhow!("无可用内容源"))?;

        // 转换章节列表（TXT 平铺：层级恒为 1）
        let chapters: Vec<Chapter> = self.chapters.iter().map(|ch| Chapter {
            title: ch.title.clone(),
            start_pos: ch.start_pos,
            end_pos: ch.end_pos,
            level: 1,
            parent_index: None,
        }).collect();

        Ok(Book {
            title,
            content,
            chapters,
        })
    }

    /// 设置内容净化器
    pub fn set_content_cleaner(&mut self, cleaner: ContentCleaner) {
        self.content_cleaner = Some(cleaner);
    }

    /// 启用内容净化（使用默认选项）
    pub fn enable_content_cleaning(
        &mut self,
        convert_mode: ConvertMode,
        paragraph_mode: ParagraphMode,
    ) {
        self.content_cleaner = Some(ContentCleaner::new(
            convert_mode,
            paragraph_mode,
            CleanOptions::default(),
        ));
    }

    /// 构建净化后的章节缓存
    ///
    /// 便捷包装（&mut 路径）；两阶段锁外重建请走
    /// cleaned_cache_build_snapshot + build_cleaned_cache_from_snapshot +
    /// install_cleaned_cache。
    pub fn build_cleaned_chapter_cache(&mut self) -> Result<()> {
        if self.chapters.is_empty() {
            return Ok(());
        }
        let content = self
            .content
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("无可用内容源"))?;
        let cache = Self::build_cleaned_cache_core(
            content,
            &self.chapters,
            self.content_cleaner.as_ref(),
            self.file_path.as_deref(),
        )?;
        self.cleaned_chapter_cache = Some(cache);
        Ok(())
    }

    /// 净化缓存是否与当前净化配置一致（读锁内可调用；不修改任何状态）
    pub fn cleaned_cache_current(&self) -> bool {
        let current_hash = self.calculate_cleaning_config_hash();
        match &self.cleaned_chapter_cache {
            None => false,
            Some(cache) => cache.config_hash == current_hash,
        }
    }

    /// 采集锁外重建快照（读锁内调用；成本 = content 克隆）
    pub fn cleaned_cache_build_snapshot(&self) -> Option<CleanedCacheBuildSnapshot> {
        Some(CleanedCacheBuildSnapshot {
            content: self.content.clone()?,
            chapters: self.chapters.clone(),
            cleaner: self.content_cleaner.clone(),
            file_path: self.file_path.clone(),
        })
    }

    /// 锁外构建净化缓存（不接触 self；可与前台分页并发）
    pub fn build_cleaned_cache_from_snapshot(
        snap: &CleanedCacheBuildSnapshot,
    ) -> Result<BuiltCleanedChapterCache> {
        let cache = Self::build_cleaned_cache_core(
            &snap.content,
            &snap.chapters,
            snap.cleaner.as_ref(),
            snap.file_path.as_deref(),
        )?;
        Ok(BuiltCleanedChapterCache(cache))
    }

    /// 装回锁外构建的缓存：仅当配置 hash 仍与快照一致才生效。
    /// 返回 false = 期间配置又变更，调用方应丢弃并按新配置重建。
    pub fn install_cleaned_cache(&mut self, cache: BuiltCleanedChapterCache) -> bool {
        let current_hash = self.calculate_cleaning_config_hash();
        if cache.0.config_hash != current_hash {
            return false;
        }
        self.cleaned_chapter_cache = Some(cache.0);
        true
    }

    /// 净化缓存构建核心（纯函数；&mut 便捷路径与锁外快照路径共用）
    fn build_cleaned_cache_core(
        original_content: &str,
        chapters: &[RawChapter],
        cleaner: Option<&ContentCleaner>,
        file_path: Option<&std::path::Path>,
    ) -> Result<CleanedChapterCache> {
        // 1. 应用内容净化
        let cleaned_content = if let Some(cleaner) = cleaner {
            cleaner.clean(original_content)?
        } else {
            original_content.to_string()
        };

        // 2. 在净化后的内容上重新计算章节边界
        //
        // 关键：净化（智能分段、去广告、去空行等）会改变行结构，
        // 原始内容上的行号/字节偏移在净化后全部失效，
        // 必须在净化后的文本上重新识别章节位置。
        let chapter_offsets = Self::compute_cleaned_offsets(chapters, &cleaned_content)?;

        // 3. 计算配置哈希（配置变更时用于失效重建）
        let config_hash = match cleaner {
            Some(c) => c.config_hash(),
            None => 0,
        };

        // 4. 缓存结果（大文本落临时文件 mmap，避免净化副本长期驻留堆）
        let cache = if cleaned_content.len() > CLEANED_MMAP_THRESHOLD_BYTES {
            let temp_path = Self::create_cleaned_temp_file(&cleaned_content, config_hash, file_path)?;
            let cleaned_mmap = Self::create_mmap_from_temp_file(&temp_path)?;

            CleanedChapterCache {
                config_hash,
                chapters: chapter_offsets,
                cleaned_mmap: Some(cleaned_mmap),
                cleaned_content: None,
            }
        } else {
            CleanedChapterCache {
                config_hash,
                chapters: chapter_offsets,
                cleaned_mmap: None,
                cleaned_content: Some(cleaned_content),
            }
        };
        Ok(cache)
    }

    /// 在净化后的内容上计算每章的字节边界
    ///
    /// 首选：用 JS 引擎在净化后文本上重新识别章节（与导入时同一套规则）。
    /// 回退：按标题顺序在净化后文本中逐行对齐。
    fn compute_cleaned_offsets(
        chapters: &[RawChapter],
        cleaned_content: &str,
    ) -> Result<Vec<CleanedChapterOffset>> {
        #[cfg(feature = "js-engine")]
        {
            let extractor = ChapterExtractor::new();
            let result = if let Ok(handle) = tokio::runtime::Handle::try_current() {
                handle.block_on(async { extractor.extract_chapters(cleaned_content).await })
            } else {
                match tokio::runtime::Runtime::new() {
                    Ok(rt) => rt.block_on(async { extractor.extract_chapters(cleaned_content).await }),
                    Err(e) => {
                        log::warn!("创建 tokio runtime 失败: {}，回退到标题对齐", e);
                        return Self::align_offsets_by_title(cleaned_content, chapters);
                    }
                }
            };

            match result {
                Ok(ch) if ch.len() == chapters.len() => {
                    log::info!("净化后重新识别 {} 个章节，与原始章节一一对应", ch.len());
                    Ok(ch
                        .into_iter()
                        .map(|c| CleanedChapterOffset {
                            start_pos: c.start_offset,
                            end_pos: c.end_offset,
                        })
                        .collect())
                }
                Ok(ch) => {
                    log::warn!(
                        "净化后识别出 {} 章，与原始 {} 章不一致，回退到标题对齐",
                        ch.len(),
                        chapters.len()
                    );
                    Self::align_offsets_by_title(cleaned_content, chapters)
                }
                Err(e) => {
                    log::warn!("净化后章节识别失败: {}，回退到标题对齐", e);
                    Self::align_offsets_by_title(cleaned_content, chapters)
                }
            }
        }

        #[cfg(not(feature = "js-engine"))]
        {
            Self::align_offsets_by_title(cleaned_content, chapters)
        }
    }

    /// 回退方案：按标题在净化后内容中顺序查找章节行号，再映射为字节偏移
    fn align_offsets_by_title(
        cleaned_content: &str,
        chapters: &[RawChapter],
    ) -> Result<Vec<CleanedChapterOffset>> {
        let mapper = LineOffsetMapper::build(cleaned_content);
        let lines: Vec<&str> = cleaned_content.lines().collect();

        // 顺序扫描：每个标题只从上一个匹配位置向后找，保证单调对齐
        let mut title_lines = Vec::with_capacity(chapters.len());
        let mut search_from = 0usize;
        for chapter in chapters {
            let want = chapter.title.trim();
            let mut found = None;
            for (i, line) in lines.iter().enumerate().skip(search_from) {
                if line.trim() == want {
                    found = Some(i);
                    break;
                }
            }
            match found {
                Some(i) => {
                    title_lines.push(i);
                    search_from = i + 1;
                }
                None => {
                    log::warn!("未在净化后内容中找到章节标题 '{}'，沿用上一位置", want);
                    title_lines.push(search_from.saturating_sub(1));
                }
            }
        }

        let mut offsets = Vec::with_capacity(title_lines.len());
        for (idx, &tl) in title_lines.iter().enumerate() {
            // 章节起始：标题行（包含标题）；结束：下一章标题行之前
            let start_pos = mapper.map_line_to_offset(tl);
            let end_pos = if idx + 1 < title_lines.len() {
                mapper.map_line_to_offset(title_lines[idx + 1])
            } else {
                cleaned_content.len()
            };

            let start_pos = Self::adjust_to_char_boundary(cleaned_content, start_pos, true);
            let end_pos = Self::adjust_to_char_boundary(cleaned_content, end_pos, false);

            if start_pos < end_pos {
                offsets.push(CleanedChapterOffset { start_pos, end_pos });
            } else {
                log::warn!("章节 '{}' 边界异常，跳过", chapters[idx].title);
                offsets.push(CleanedChapterOffset { start_pos: 0, end_pos: 0 });
            }
        }

        Ok(offsets)
    }

    /// 检查是否有净化缓存
    pub fn has_cleaned_cache(&self) -> bool {
        self.cleaned_chapter_cache.is_some()
    }

    /// 从缓存中获取章节内容
    /// 
    /// 如果缓存不存在，返回错误。调用前应先调用 build_cleaned_chapter_cache()。
    pub fn get_chapter_content_from_cache(&self, chapter_index: usize) -> Result<String> {
        let cache = self.cleaned_chapter_cache.as_ref()
            .ok_or_else(|| anyhow::anyhow!("净化缓存不存在，请先调用 build_cleaned_chapter_cache()"))?;

        let offset = cache.chapters.get(chapter_index)
            .ok_or_else(|| anyhow::anyhow!("章节索引越界: {}", chapter_index))?;

        // 从缓存读取内容
        let content = if let Some(ref cleaned_content) = cache.cleaned_content {
            // 内存模式
            let start = offset.start_pos.min(cleaned_content.len());
            let end = offset.end_pos.min(cleaned_content.len());
            
            if start >= end {
                return Ok(String::new());
            }
            
            cleaned_content[start..end].to_string()
        } else if let Some(ref mmap) = cache.cleaned_mmap {
            // mmap 模式
            let start = offset.start_pos.min(mmap.len());
            let end = offset.end_pos.min(mmap.len());
            
            if start >= end {
                return Ok(String::new());
            }
            
            // 从 mmap 读取（假设已经是 UTF-8）
            let slice = &mmap[start..end];
            String::from_utf8_lossy(slice).into_owned()
        } else {
            return Err(anyhow::anyhow!("缓存数据不可用"));
        };

        Ok(content)
    }

    /// 调整字节位置到最近的字符边界
    fn adjust_to_char_boundary(content: &str, pos: usize, forward: bool) -> usize {
        if pos >= content.len() {
            return content.len();
        }
        if pos == 0 {
            return 0;
        }
        if content.is_char_boundary(pos) {
            return pos;
        }

        if forward {
            // 向前查找
            (pos..content.len())
                .find(|&i| content.is_char_boundary(i))
                .unwrap_or(content.len())
        } else {
            // 向后查找
            (0..=pos)
                .rev()
                .find(|&i| content.is_char_boundary(i))
                .unwrap_or(0)
        }
    }

    /// 计算净化配置的哈希值
    ///
    /// 基于净化器的完整配置（转换模式/分段模式/清理选项）。
    /// 无净化器时为固定值，与任何启用配置都不同。
    fn calculate_cleaning_config_hash(&self) -> u64 {
        match &self.content_cleaner {
            Some(cleaner) => cleaner.config_hash(),
            None => 0,
        }
    }

    /// 确保净化缓存可用且与当前净化配置一致
    ///
    /// 缓存缺失或配置哈希不匹配（用户在阅读中修改了净化设置）时自动重建。
    pub fn ensure_cleaned_chapter_cache(&mut self) -> Result<()> {
        let current_hash = self.calculate_cleaning_config_hash();
        let needs_rebuild = match &self.cleaned_chapter_cache {
            None => true,
            Some(cache) => cache.config_hash != current_hash,
        };

        if needs_rebuild {
            if self.cleaned_chapter_cache.is_some() {
                log::info!("净化配置变更，重建净化缓存 (hash={:x})", current_hash);
            }
            self.build_cleaned_chapter_cache()?;
        }
        Ok(())
    }

    /// 创建净化后内容的临时文件
    ///
    /// 路径格式：{temp_dir}/legado_cleaned/{book_id}_{config_hash}.txt
    fn create_cleaned_temp_file(
        cleaned_content: &str,
        config_hash: u64,
        file_path: Option<&std::path::Path>,
    ) -> Result<std::path::PathBuf> {
        use std::io::Write;

        // 获取系统临时目录
        let temp_dir = std::env::temp_dir();
        let cleaned_dir = temp_dir.join("legado_cleaned");

        // 创建目录（如果不存在）
        std::fs::create_dir_all(&cleaned_dir)
            .with_context(|| format!("创建临时目录失败: {:?}", cleaned_dir))?;

        // 生成唯一的文件名（基于文件路径哈希 + 配置哈希）
        let book_id = if let Some(path) = file_path {
            // 使用文件路径的哈希作为 book_id
            use std::collections::hash_map::DefaultHasher;
            use std::hash::{Hash, Hasher};
            let mut hasher = DefaultHasher::new();
            path.to_string_lossy().hash(&mut hasher);
            format!("{:x}", hasher.finish())
        } else {
            "unknown".to_string()
        };

        let temp_path = cleaned_dir.join(format!("{}_{:x}.txt", book_id, config_hash));

        // 写入净化后的内容
        let mut file = File::create(&temp_path)
            .with_context(|| format!("创建临时文件失败: {:?}", temp_path))?;
        file.write_all(cleaned_content.as_bytes())
            .with_context(|| "写入临时文件失败")?;

        log::info!("创建净化后临时文件: {:?}", temp_path);

        Ok(temp_path)
    }

    /// 从临时文件创建 mmap
    fn create_mmap_from_temp_file(temp_path: &std::path::Path) -> Result<Mmap> {
        let file = File::open(temp_path)
            .with_context(|| format!("打开临时文件失败: {:?}", temp_path))?;

        unsafe {
            Mmap::map(&file)
                .with_context(|| "创建临时文件的内存映射失败")
        }
    }

    /// 向后兼容的解析方法（返回旧的 Book 类型）
    pub fn parse<R: Read>(reader: R, book_name: Option<String>) -> Result<Book> {
        let mut buf_reader = BufReader::new(reader);
        let mut buffer = Vec::new();
        buf_reader.read_to_end(&mut buffer)
            .map_err(|e| anyhow::anyhow!("读取数据失败: {}", e))?;

        let (content, _) = Self::decode_text(&buffer)?;
        let chapters = Self::extract_chapters_from_content(&content);

        let title = book_name.unwrap_or_else(|| "未命名书籍".to_string());

        Ok(Book {
            title,
            content,
            chapters,
        })
    }

    /// 向后兼容：从内容字符串提取章节（用于旧 API）
    fn extract_chapters_from_content(content: &str) -> Vec<Chapter> {
        #[cfg(feature = "js-engine")]
        let raw_chapters = Self::extract_chapters_with_new_extractor(content);
        
        #[cfg(not(feature = "js-engine"))]
        let raw_chapters = Self::extract_chapters_static(content);
        
        raw_chapters.into_iter().map(|ch| Chapter {
            title: ch.title,
            start_pos: ch.start_pos,
            end_pos: ch.end_pos,
            level: 1,
            parent_index: None,
        }).collect()
    }

    /// 使用新的 ChapterExtractor（基于 JS 引擎）
    #[cfg(feature = "js-engine")]
    fn extract_chapters_with_new_extractor(content: &str) -> Vec<RawChapter> {
        // 使用全局的 tokio runtime（如果存在），否则创建一个
        let result = if let Ok(handle) = tokio::runtime::Handle::try_current() {
            // 如果在 tokio runtime 内，直接 block_on
            handle.block_on(async {
                Self::extract_chapters_async(content).await
            })
        } else {
            // 如果不在 tokio runtime 内，创建一个新的
            let rt = match tokio::runtime::Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    log::warn!("创建 tokio runtime 失败: {}, 回退到正则表达式", e);
                    return Self::extract_chapters_static(content);
                }
            };
            
            rt.block_on(async {
                Self::extract_chapters_async(content).await
            })
        };
        
        result
    }
    
    /// 异步提取章节（内部方法，返回完整偏移）
    #[cfg(feature = "js-engine")]
    async fn extract_chapters_async(content: &str) -> Vec<RawChapter> {
        let extractor = ChapterExtractor::new();
        
        match extractor.extract_chapters(content).await {
            Ok(chapters) => {
                log::info!("ChapterExtractor 成功识别 {} 个章节", chapters.len());
                // 转换为 RawChapter
                chapters.into_iter().map(|ch| RawChapter {
                    title: ch.title,
                    start_pos: ch.start_offset,
                    end_pos: ch.end_offset,
                }).collect()
            }
            Err(e) => {
                // 如果 JS 引擎失败，回退到旧的正则表达式方法
                log::warn!("ChapterExtractor 失败，回退到正则表达式: {}", e);
                Self::extract_chapters_static(content)
            }
        }
    }

    /// 静态章节提取（用于旧 API 与 JS 引擎降级路径）
    fn extract_chapters_static(content: &str) -> Vec<RawChapter> {
        let mut chapters = Vec::new();

        let patterns = [
            regex::Regex::new(r"(?m)^[\s　]*第[0-9零一二三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回集部卷篇][\s　:：]*(.*)$").unwrap(),
            regex::Regex::new(r"(?m)^[\s　]*Chapter[\s　]+\d+[\s　:：]*(.*)$").unwrap(),
            regex::Regex::new(r"(?m)^[\s　]*\d{3,}[\s　.、：:]+(.+)$").unwrap(),
            regex::Regex::new(r"(?m)^[\s　]*[卷][\s　]*[0-9零一二三四五六七八九十百千]+[\s　]*[章节][\s　]*\d+[\s　:：]*(.*)$").unwrap(),
        ];

        let blacklist = [
            "第一名", "第二名", "第三名", "第四名", "第五名",
            "第一天", "第二天", "第三天", "第四天", "第五天",
            "第一次", "第二次", "第三次", "第四次", "第五次",
            "第一个", "第二个", "第三个", "第四个", "第五个",
            "第一页", "第二页", "第三页", "第四页", "第五页",
            "第一步", "第二步", "第三步", "第四步", "第五步",
            "第一部分", "第二部分", "第三部分",
            "第一条", "第二条", "第三条",
            "第一项", "第二项", "第三项",
            "第一种", "第二种", "第三种",
            "第一类", "第二类", "第三类",
            "第一位", "第二位", "第三位",
            "第一季", "第二季", "第三季",
            "第一年", "第二年", "第三年",
            "第一层", "第二层", "第三层",
            "第一轮", "第二轮", "第三轮",
        ];

        let mut current_byte_pos = 0;
        let lines: Vec<&str> = content.lines().collect();

        for (line_idx, line) in lines.iter().enumerate() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.len() < 3 {
                current_byte_pos += line.len() + 1;
                continue;
            }
            if trimmed.len() > 30 {
                current_byte_pos += line.len() + 1;
                continue;
            }
            if blacklist.iter().any(|&word| trimmed.contains(word)) {
                current_byte_pos += line.len() + 1;
                continue;
            }

            for pattern in &patterns {
                if pattern.is_match(trimmed) {
                    let prev_line_is_blank = if line_idx > 0 {
                        lines[line_idx - 1].trim().is_empty()
                    } else {
                        true
                    };
                    let next_line_context = if line_idx + 1 < lines.len() {
                        let next_line = lines[line_idx + 1].trim();
                        next_line.is_empty() || !patterns.iter().any(|p| p.is_match(next_line))
                    } else {
                        true
                    };

                    if prev_line_is_blank && next_line_context {
                        chapters.push(RawChapter {
                            title: trimmed.to_string(),
                            start_pos: current_byte_pos,  // 指向标题行起始
                            end_pos: 0,
                        });
                    }
                    break;
                }
            }
            current_byte_pos += line.len() + 1;
        }

        // 设置结束位置
        for i in 0..chapters.len() {
            let mut start_pos = chapters[i].start_pos;
            if !content.is_char_boundary(start_pos) {
                start_pos = (0..=start_pos).rev()
                    .find(|&pos| content.is_char_boundary(pos))
                    .unwrap_or(0);
                chapters[i].start_pos = start_pos;
            }

            if i + 1 < chapters.len() {
                let mut end_pos = chapters[i + 1].start_pos;
                if !content.is_char_boundary(end_pos) {
                    end_pos = (end_pos..=content.len())
                        .find(|&pos| content.is_char_boundary(pos))
                        .unwrap_or(content.len());
                }
                while end_pos > start_pos && content.is_char_boundary(end_pos) {
                    let slice = &content[start_pos..end_pos];
                    if let Some(prev_char) = slice.chars().last() {
                        if prev_char.is_whitespace() {
                            end_pos -= prev_char.len_utf8();
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                chapters[i].end_pos = end_pos;
            } else {
                let mut end_pos = content.len();
                while end_pos > start_pos && content.is_char_boundary(end_pos) {
                    let slice = &content[start_pos..end_pos];
                    if let Some(prev_char) = slice.chars().last() {
                        if prev_char.is_whitespace() {
                            end_pos -= prev_char.len_utf8();
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                chapters[i].end_pos = end_pos;
            }
        }

        if chapters.is_empty() {
            chapters.push(RawChapter {
                title: "正文".to_string(),
                start_pos: 0,
                end_pos: content.len(),
            });
        }

        chapters
    }

    /// 检测并解码文本内容
    fn decode_text(buffer: &[u8]) -> Result<(String, EncodingInfo)> {
        // 使用智能编码检测器
        let encoding_info = SmartEncodingDetector::detect(buffer)
            .with_context(|| "编码检测失败")?;
        
        let content = SmartEncodingDetector::decode_with_info(buffer, &encoding_info)
            .with_context(|| "文本解码失败")?;
        
        Ok((content, encoding_info))
    }

    /// 智能章节提取（使用 JS 引擎）
    fn extract_chapters(&self) -> Vec<RawChapter> {
        match &self.content {
            Some(content) => {
                // 使用 JS 引擎的章节识别
                #[cfg(feature = "js-engine")]
                {
                    Self::extract_chapters_with_new_extractor(content)
                }
                
                // 如果没有启用 js-engine feature，使用旧正则
                #[cfg(not(feature = "js-engine"))]
                {
                    Self::extract_chapters_static(content)
                }
            }
            None => Vec::new(),
        }
    }

    /// 获取章节内容（解码文本切片，偏移与识别同源）
    fn get_chapter_content_internal(&self, chapter: &RawChapter) -> Result<String> {
        let full_content = self.content.as_ref()
            .ok_or_else(|| anyhow::anyhow!("内容未加载"))?;

        let start = if full_content.is_char_boundary(chapter.start_pos) {
            chapter.start_pos
        } else {
            (chapter.start_pos..full_content.len())
                .find(|&i| full_content.is_char_boundary(i))
                .unwrap_or(chapter.start_pos)
        };

        let end = if full_content.is_char_boundary(chapter.end_pos) {
            chapter.end_pos
        } else {
            (0..=chapter.end_pos)
                .rev()
                .find(|&i| full_content.is_char_boundary(i))
                .unwrap_or(chapter.end_pos)
        };

        let end = end.min(full_content.len());

        let mut content = full_content[start..end].to_string();

        // 应用内容净化（如果已启用）
        if let Some(cleaner) = &self.content_cleaner {
            content = cleaner.clean(&content)?;
        }

        Ok(content)
    }

    /// 向后兼容：获取章节内容（静态方法，用于旧 API）
    pub fn get_chapter_content(book: &Book, chapter_index: usize) -> Option<String> {
        book.chapters.get(chapter_index).map(|chapter| {
            let start = if book.content.is_char_boundary(chapter.start_pos) {
                chapter.start_pos
            } else {
                (chapter.start_pos..book.content.len())
                    .find(|&i| book.content.is_char_boundary(i))
                    .unwrap_or(chapter.start_pos)
            };

            let end = if book.content.is_char_boundary(chapter.end_pos) {
                chapter.end_pos
            } else {
                (chapter.end_pos..=book.content.len())
                    .find(|&i| book.content.is_char_boundary(i))
                    .unwrap_or(book.content.len())
            };

            book.content[start..end].to_string()
        })
    }
}

impl BookParser for TxtParser {
    fn format(&self) -> BookFormat {
        BookFormat::Txt
    }

    fn supported_resources(&self) -> Vec<ResourceType> {
        Vec::new() // TXT 不支持资源
    }

    fn parse(&mut self) -> Result<BookMetadata> {
        // 如果已经有元信息（from_reader 设置过），直接返回
        if let Some(ref metadata) = self.metadata {
            return Ok(metadata.clone());
        }

        // 否则从文件解析
        if self.chapters.is_empty() {
            self.chapters = self.extract_chapters();
        }

        let file_size = self.file_path.as_ref()
            .and_then(|p| std::fs::metadata(p).ok())
            .map(|m| m.len())
            .unwrap_or(self.content.as_ref().map(|c| c.len() as u64).unwrap_or(0));

        let title = self.file_path.as_ref()
            .and_then(|p| p.file_stem())
            .and_then(|s| s.to_str())
            .unwrap_or("未命名书籍")
            .to_string();

        let metadata = BookMetadata {
            title,
            author: String::new(),
            cover_data: None,
            language: "zh".to_string(),
            total_chapters: self.chapters.len(),
            file_size,
            format: BookFormat::Txt,
        };

        self.metadata = Some(metadata.clone());
        Ok(metadata)
    }

    fn get_chapter_list(&self) -> Result<Vec<ChapterInfo>> {
        if self.chapters.is_empty() {
            return Err(anyhow::anyhow!("请先调用 parse() 解析书籍"));
        }

        Ok(self.chapters.iter().enumerate().map(|(i, ch)| {
            // 字数（基于解码文本的字符计数）
            let word_count = if let Some(ref content) = self.content {
                if ch.end_pos > ch.start_pos && ch.end_pos <= content.len() {
                    content[ch.start_pos..ch.end_pos].chars().count()
                } else {
                    0
                }
            } else {
                0
            };

            ChapterInfo::txt_chapter(
                i,
                ch.title.clone(),
                word_count,
                ch.start_pos,
                ch.end_pos,
            )
        }).collect())
    }

    fn get_chapter_content(&mut self, chapter_index: usize) -> Result<String> {
        let chapter = self.chapters.get(chapter_index)
            .ok_or_else(|| anyhow::anyhow!("章节索引越界: {}", chapter_index))?;

        self.get_chapter_content_internal(chapter)
    }

    fn total_chapters(&self) -> usize {
        self.chapters.len()
    }

    fn cleanup(&mut self) {
        self.content = None;
        self.chapters.clear();
        self.metadata = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_from_reader_simple() {
        let content = r#"第一章 开始
这是第一章的内容。

第二章 继续
这是第二章的内容。"#;

        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, Some("测试书籍".to_string())).unwrap();

        let metadata = parser.parse().unwrap();
        assert_eq!(metadata.title, "测试书籍");
        assert_eq!(metadata.total_chapters, 2);

        let chapters = parser.get_chapter_list().unwrap();
        assert_eq!(chapters[0].title, "第一章 开始");
        assert_eq!(chapters[1].title, "第二章 继续");

        let ch1 = parser.get_chapter_content(0).unwrap();
        assert!(ch1.contains("这是第一章的内容"));
    }

    #[test]
    fn test_multibyte_char_boundaries() {
        let content = "《贷款武圣》\n作者：长鲸归海\n\n第1章　捕役之身\n　　大周朝。\n　　博州，平章郡，黑山县。\n\n第2章　修炼开始\n　　县里街道空寂。";

        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, Some("测试书籍".to_string())).unwrap();

        let metadata = parser.parse().unwrap();
        assert!(metadata.total_chapters >= 2);

        for i in 0..metadata.total_chapters {
            let chapter_content = parser.get_chapter_content(i).unwrap();
            assert!(!chapter_content.is_empty());
        }
    }

    #[test]
    fn test_empty_content() {
        let content = "";
        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, None).unwrap();

        let metadata = parser.parse().unwrap();
        assert_eq!(metadata.total_chapters, 1); // 默认章节 "正文"
    }

    #[test]
    #[ignore] // 需要大文件，手动运行
    fn test_chapter_extractor_integration_with_large_file() {
        let file_path = "D:\\android\\example\\legado_flutter\\rust\\test_large_file_cargo\\test_very_large_book.txt";
        
        // 检查文件是否存在
        if !std::path::Path::new(file_path).exists() {
            println!("跳过测试：大文件不存在 {}", file_path);
            return;
        }
        
        println!("开始测试大文件章节提取（使用新的 ChapterExtractor）...");
        let start = std::time::Instant::now();
        
        // 使用 TxtParser 加载文件
        let mut parser = TxtParser::from_file(std::path::Path::new(file_path))
            .expect("加载文件失败");
        
        let metadata = parser.parse().expect("解析失败");
        let elapsed = start.elapsed();
        
        println!("文件大小: {} MB", metadata.file_size / 1024 / 1024);
        println!("识别到 {} 个章节", metadata.total_chapters);
        println!("总耗时: {:?}", elapsed);
        
        // 显示前10章
        println!("\n前10章:");
        for i in 0..10.min(parser.chapters.len()) {
            println!("  [{}] {} (位置: {} -> {})", 
                i, parser.chapters[i].title, 
                parser.chapters[i].start_pos, parser.chapters[i].end_pos);
        }
        
        // 显示后10章
        if parser.chapters.len() > 10 {
            println!("\n后10章:");
            let start_idx = parser.chapters.len().saturating_sub(10);
            for i in start_idx..parser.chapters.len() {
                println!("  [{}] {} (位置: {} -> {})", 
                    i, parser.chapters[i].title, 
                    parser.chapters[i].start_pos, parser.chapters[i].end_pos);
            }
        }
        
        // 验证章节数量（应该接近1000章）
        assert!(parser.chapters.len() >= 900, 
            "应该识别出至少900章，实际: {}", parser.chapters.len());
        assert!(parser.chapters.len() <= 1000, 
            "不应该超过1000章，实际: {}", parser.chapters.len());
        
        // 测试获取章节内容
        if parser.chapters.len() > 0 {
            println!("\n测试获取第1章内容...");
            let content = parser.get_chapter_content(0)
                .expect("获取章节内容失败");
            println!("第1章内容长度: {} 字节", content.len());
            println!("第1章前100字: {}", 
                content.chars().take(100).collect::<String>());
                
            assert!(content.len() > 100, "章节内容应该有实质内容");
        }
    }

    #[test]
    fn test_chapter_extractor_integration_small() {
        // 测试小文件集成，确认 ChapterExtractor 正常工作
        let content = r#"《测试书籍》
作者：测试作者

第1章 开始的故事
这是第一章的内容，需要足够长才能通过验证。
添加更多内容：春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。
床前明月光，疑是地上霜。举头望明月，低头思故乡。白日依山尽，黄河入海流。
欲穷千里目，更上一层楼。锄禾日当午，汗滴禾下土。谁知盘中餐，粒粒皆辛苦。
鹅鹅鹅，曲项向天歌。白毛浮绿水，红掌拨清波。离离原上草，一岁一枯荣。
野火烧不尽，春风吹又生。慈母手中线，游子身上衣。临行密密缝，意恐迟迟归。
谁言寸草心，报得三春晖。独在异乡为异客，每逢佳节倍思亲。

第2章 继续冒险
这是第二章的内容，也需要足够长。
继续添加文字：遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘，
客舍青青柳色新。劝君更尽一杯酒，西出阳关无故人。千山鸟飞绝，万径人踪灭。
孤舟蓑笠翁，独钓寒江雪。两个黄鹂鸣翠柳，一行白鹭上青天。
窗含西岭千秋雪，门泊东吴万里船。日照香炉生紫烟，遥看瀑布挂前川。
飞流直下三千尺，疑是银河落九天。朝辞白帝彩云间，千里江陵一日还。
两岸猿声啼不住，轻舟已过万重山。春种一粒粟，秋收万颗子。

第3章 最终章
这是第三章的内容，继续添加。
四海无闲田，农夫犹饿死。谁道人生无再少，门前流水尚能西。休将白发唱黄鸡。
采菊东篱下，悠然见南山。山气日夕佳，飞鸟相与还。此中有真意，欲辨已忘言。
大江东去，浪淘尽，千古风流人物。故垒西边，人道是，三国周郎赤壁。
乱石穿空，惊涛拍岸，卷起千堆雪。江山如画，一时多少豪杰。
遥想公瑾当年，小乔初嫁了，雄姿英发。羽扇纶巾，谈笑间，樯橹灰飞烟灭。
故国神游，多情应笑我，早生华发。人生如梦，一尊还酹江月。
"#;

        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, Some("测试书籍".to_string())).unwrap();
        
        let metadata = parser.parse().unwrap();
        
        println!("识别到 {} 个章节", metadata.total_chapters);
        for (i, ch) in parser.chapters.iter().enumerate() {
            println!("  [{}] {}", i, ch.title);
        }
        
        // 应该识别出3个章节
        assert_eq!(metadata.total_chapters, 3, "应该识别出3个章节");
        assert_eq!(parser.chapters[0].title, "第1章 开始的故事");
        assert_eq!(parser.chapters[1].title, "第2章 继续冒险");
        assert_eq!(parser.chapters[2].title, "第3章 最终章");
        
        // 测试获取章节内容
        let ch1_content = parser.get_chapter_content(0).unwrap();
        assert!(ch1_content.contains("这是第一章的内容"));
        println!("\n第1章内容长度: {} 字节", ch1_content.len());
    }

    #[test]
    fn test_content_cleaning_integration() {
        // 测试内容净化集成
        let content = r#"《测试书籍》
作者：测试作者

第一章 开始
<p>这是第一章的<span>内容</span>。</p>
本书由笔趣阁首发 www.biquge.com
　　这是正文内容，需要足够长才能通过验证。
春眠不觉晓，处处闻啼鸟。夜来风雨声，花落知多少。
床前明月光，疑是地上霜。举头望明月，低头思故乡。
白日依山尽，黄河入海流。欲穷千里目，更上一层楼。
锄禾日当午，汗滴禾下土。谁知盘中餐，粒粒皆辛苦。

第二章 继续
　　这是第二章的内容。
遥知兄弟登高处，遍插茱萸少一人。渭城朝雨浥轻尘。
客舍青青柳色新。劝君更尽一杯酒，西出阳关无故人。
千山鸟飞绝，万径人踪灭。孤舟蓑笠翁，独钓寒江雪。
两个黄鹂鸣翠柳，一行白鹭上青天。窗含西岭千秋雪。
"#;

        let reader = content.as_bytes();
        let mut parser = TxtParser::from_reader(reader, Some("测试书籍".to_string())).unwrap();
        
        // 启用内容净化
        parser.enable_content_cleaning(
            ConvertMode::None,
            ParagraphMode::Smart,
        );
        
        let metadata = parser.parse().unwrap();
        
        println!("识别到 {} 个章节", metadata.total_chapters);
        
        // 测试获取净化后的章节内容
        let ch1_content = parser.get_chapter_content(0).unwrap();
        
        println!("\n第1章净化后的内容:");
        println!("{}", ch1_content);
        println!("\n内容长度: {} 字节", ch1_content.len());
        
        // 验证 HTML 标签已被清除
        assert!(!ch1_content.contains("<p>"));
        assert!(!ch1_content.contains("<span>"));
        
        // 验证广告已被删除
        assert!(!ch1_content.contains("笔趣阁"));
        assert!(!ch1_content.contains("www.biquge.com"));
        
        // 验证正文内容仍然存在
        assert!(ch1_content.contains("这是第一章的内容"));
        assert!(ch1_content.contains("春眠不觉晓"));
    }

    #[test]
    fn test_gbk_file_offsets_are_decoded_text_based() {
        // A2 回归：章节偏移必须基于**解码后文本**（D3 同源）。
        // GBK 每汉字 2 字节，若偏移混入原始字节（旧 mmap 路径行为），
        // 切片会错位/越界。编码检测器对无 BOM 短文本可能判 UTF-8，
        // 因此用足够长的重复中文正文保证 GBK 判定。
        use encoding_rs::GBK;

        let body_a = "主角在山中修行，一日千里。".repeat(60); // 全非 ASCII
        let body_b = "敌人出现在深夜的巷口，杀意凛然。".repeat(60);
        let text = format!(
            "第一章 初入江湖\n{}\n\n第一章 再遇强敌\n{}",
            body_a, body_b
        );
        let (bytes, _, _) = GBK.encode(&text);

        let dir = std::env::temp_dir().join(format!("gbk_offset_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("gbk_book.txt");
        std::fs::write(&path, &bytes).unwrap();

        let mut parser = TxtParser::from_file(&path).unwrap();
        parser.parse().unwrap();

        assert_eq!(
            parser.total_chapters(),
            2,
            "应识别出 2 章"
        );

        // 切片语义：start_offset 指向标题后的正文起点（标题由目录元数据承载）
        let ch0 = parser.get_chapter_content(0).unwrap();
        let ch1 = parser.get_chapter_content(1).unwrap();
        assert!(ch0.contains("山中修行"), "第 1 章正文不得因偏移错位丢失");
        assert!(!ch0.contains("深夜的巷口"), "第 1 章不得混入第 2 章正文");
        assert!(ch1.contains("深夜的巷口"), "第 2 章正文切片应正确");
        assert!(!ch1.contains("山中修行"), "第 2 章不得混入第 1 章正文");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
