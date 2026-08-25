//! EPUB 导入级净化缓存（与 TXT 净化章节缓存同构）
//!
//! 物化形态的 EPUB Book 视同 TXT 解码全文处理：逐章独立清洗后按导入
//! 同款框架（`title\n` + body + `\n\n`）重新串联并累加字节偏移。
//! clean() 各阶段均无跨章上下文，逐章清洗与旧「读取时逐切片净化」行为
//! 一致；偏移在串联时直接累加，天然满足 D3（边界与所索引文本同源），
//! 无需 JS 重识别或标题对齐。
//!
//! 落盘：`{temp}/legado_cleaned/{pathhash:x}_{config_hash:x}.epub.txt`
//! 格式：首行 JSON 头（章节偏移表），其余为净化全文。跨启动复用。

use crate::content_cleaner::ContentCleaner;
use crate::Book;
use anyhow::{Context, Result};
use std::collections::hash_map::DefaultHasher;
use std::fs::File;
use std::hash::{Hash, Hasher};
use std::io::Write;
use std::path::{Path, PathBuf};

/// EPUB 净化后的整本书（内存态）
pub struct EpubCleanedBook {
    /// 构建时的净化配置哈希（配置变更检测依据）
    pub config_hash: u64,
    /// 净化后全文（title\n + cleaned_body\n\n 串联）
    pub content: String,
    /// 章节字节偏移 (start_pos, end_pos)，与 content 同源（D3）
    pub offsets: Vec<(usize, usize)>,
}

impl EpubCleanedBook {
    /// 逐章独立清洗并重建偏移
    ///
    /// 标题行不参与清洗：TOC 标题为可信元数据，且避免广告正则误伤标题。
    pub fn build(book: &Book, cleaner: &ContentCleaner) -> Result<Self> {
        let mut content = String::new();
        let mut offsets = Vec::with_capacity(book.chapters.len());

        for ch in &book.chapters {
            let region = book
                .content
                .get(ch.start_pos..ch.end_pos)
                .ok_or_else(|| anyhow::anyhow!("章节偏移越界: {}", ch.title))?;
            // 剥离标题行（物化格式 title\nbody\n\n）
            let body = region.split_once('\n').map(|(_, b)| b).unwrap_or("");

            let cleaned = cleaner.clean(body).unwrap_or_else(|e| {
                log::warn!("章节净化失败，保留原文: {} - {}", ch.title, e);
                body.to_string()
            });

            let start = content.len();
            content.push_str(&ch.title);
            content.push('\n');
            content.push_str(&cleaned);
            content.push_str("\n\n");
            offsets.push((start, content.len()));
        }

        Ok(Self {
            config_hash: cleaner.config_hash(),
            content,
            offsets,
        })
    }

    /// 磁盘命中则加载，否则构建并写盘（写盘失败仅告警，不影响可用性）
    pub fn load_or_build(source_file: &Path, book: &Book, cleaner: &ContentCleaner) -> Result<Self> {
        if let Some(cached) =
            Self::try_load_from_disk(source_file, cleaner.config_hash(), book.chapters.len())
        {
            log::info!("EPUB 净化缓存磁盘命中: {:?}", cached.1);
            return Ok(cached.0);
        }
        let built = Self::build(book, cleaner)?;
        if let Err(e) = built.persist_to_disk(source_file) {
            log::warn!("EPUB 净化缓存落盘失败（不影响使用）: {}", e);
        }
        Ok(built)
    }

    /// 缓存文件路径（与 TXT 净化落盘同目录、同键格式）
    ///
    /// M9.1：键混入源文件大小+mtime 指纹——同路径换书/换版本不再命中旧缓存
    /// （旧键仅 hash 路径字符串 + 配置，内容变更不感知）
    fn cache_path(source_file: &Path, config_hash: u64) -> PathBuf {
        let mut hasher = DefaultHasher::new();
        source_file.to_string_lossy().hash(&mut hasher);
        if let Ok(meta) = std::fs::metadata(source_file) {
            meta.len().hash(&mut hasher);
            if let Ok(mtime) = meta.modified() {
                if let Ok(d) = mtime.duration_since(std::time::UNIX_EPOCH) {
                    d.as_secs().hash(&mut hasher);
                }
            }
        }
        let path_hash = hasher.finish();
        std::env::temp_dir()
            .join("legado_cleaned")
            .join(format!("{:x}_{:x}.epub.txt", path_hash, config_hash))
    }

    fn try_load_from_disk(
        source_file: &Path,
        config_hash: u64,
        expected_chapters: usize,
    ) -> Option<(Self, PathBuf)> {
        let path = Self::cache_path(source_file, config_hash);
        let raw = std::fs::read_to_string(&path).ok()?;
        let (header_line, body) = raw.split_once('\n')?;
        let offsets: Vec<(usize, usize)> = serde_json::from_str(header_line).ok()?;
        let content = body.to_string();

        // 完整性校验：章节数一致、偏移有序且落在字符边界上（工程硬约束 #3）
        let valid = offsets.len() == expected_chapters
            && content.is_char_boundary(content.len())
            && offsets.iter().all(|&(s, e)| {
                e <= content.len()
                    && s < e
                    && content.is_char_boundary(s)
                    && content.is_char_boundary(e)
            });
        if !valid {
            log::warn!("EPUB 净化缓存校验失败，将重建: {:?}", path);
            return None;
        }

        Some((
            Self {
                config_hash,
                content,
                offsets,
            },
            path,
        ))
    }

    fn persist_to_disk(&self, source_file: &Path) -> Result<()> {
        let path = Self::cache_path(source_file, self.config_hash);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .with_context(|| format!("创建目录失败: {:?}", dir))?;
        }
        let header = serde_json::to_string(&self.offsets)?;
        let mut file = File::create(&path)
            .with_context(|| format!("创建缓存文件失败: {:?}", path))?;
        file.write_all(header.as_bytes())?;
        file.write_all(b"\n")?;
        file.write_all(self.content.as_bytes())?;
        file.flush()?;
        Ok(())
    }
}

/// 按物化格式构造测试用 Book（与 bridge/api.rs 物化逻辑一致）
#[cfg(test)]
pub(crate) fn materialize_for_test(parts: &[(&str, &str)]) -> Book {
    use crate::Chapter;
    let mut content = String::new();
    let mut chapters = Vec::with_capacity(parts.len());
    for (title, body) in parts {
        let start = content.len();
        content.push_str(title);
        content.push('\n');
        content.push_str(body);
        content.push_str("\n\n");
        chapters.push(Chapter {
            title: title.to_string(),
            start_pos: start,
            end_pos: content.len(),
            level: 1,
            parent_index: None,
        });
    }
    Book {
        title: "test".to_string(),
        content,
        chapters,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_offsets_same_source_and_ads_removed() {
        let book = materialize_for_test(&[
            ("第一章", "正文甲。\n本书由笔趣阁首发\n正文乙。"),
            ("第二章", "正文丙 www.example.com"),
        ]);
        let cleaner = ContentCleaner::default();
        let cleaned = EpubCleanedBook::build(&book, &cleaner).unwrap();

        assert_eq!(cleaned.offsets.len(), 2);

        // D3：切片必须精确还原「标题行 + 净化正文」区域
        for (i, ch) in book.chapters.iter().enumerate() {
            let (s, e) = cleaned.offsets[i];
            let region = cleaned.content.get(s..e).unwrap();
            assert!(region.starts_with(&ch.title));
            assert!(region.ends_with("\n\n"));
        }

        let ch0 = cleaned.content.get(cleaned.offsets[0].0..cleaned.offsets[0].1).unwrap();
        assert!(!ch0.contains("笔趣阁"));
        assert!(ch0.contains("正文甲。"));

        let ch1 = cleaned.content.get(cleaned.offsets[1].0..cleaned.offsets[1].1).unwrap();
        assert!(!ch1.contains("example.com"));
    }

    #[test]
    fn titles_not_cleaned_and_boundaries_safe() {
        // 全角空格占 3 字节（工程硬约束 #5），验证偏移不串章
        let book = materialize_for_test(&[
            ("第一章　上", "　　段落一。"),
            ("第二章　下", "　　段落二。"),
        ]);
        let cleaner = ContentCleaner::default();
        let cleaned = EpubCleanedBook::build(&book, &cleaner).unwrap();

        for &(s, e) in &cleaned.offsets {
            assert!(cleaned.content.is_char_boundary(s));
            assert!(cleaned.content.is_char_boundary(e));
        }
        // 标题原样保留（含全角空格），未被空白清理破坏
        assert!(cleaned.content.contains("第一章　上"));
        assert!(cleaned.content.contains("第二章　下"));
    }

    #[test]
    fn persist_reload_roundtrip() {
        let book = materialize_for_test(&[("第一章", "正文甲。"), ("第二章", "正文乙。")]);
        let cleaner = ContentCleaner::default();
        let built = EpubCleanedBook::build(&book, &cleaner).unwrap();

        // tempfile 提供唯一真实路径作为缓存键
        let tmp = tempfile::NamedTempFile::new().unwrap();
        built.persist_to_disk(tmp.path()).unwrap();

        let loaded = EpubCleanedBook::try_load_from_disk(
            tmp.path(),
            cleaner.config_hash(),
            book.chapters.len(),
        );
        assert!(loaded.is_some());
        let (loaded, _) = loaded.unwrap();
        assert_eq!(loaded.config_hash, built.config_hash);
        assert_eq!(loaded.content, built.content);
        assert_eq!(loaded.offsets, built.offsets);
    }

    #[test]
    fn corrupted_cache_is_rejected() {
        let book = materialize_for_test(&[("第一章", "正文甲。")]);
        let cleaner = ContentCleaner::default();
        let built = EpubCleanedBook::build(&book, &cleaner).unwrap();

        let tmp = tempfile::NamedTempFile::new().unwrap();
        built.persist_to_disk(tmp.path()).unwrap();

        // 破坏正文长度 → 偏移越界 → 校验失败返回 None
        let path = EpubCleanedBook::cache_path(tmp.path(), cleaner.config_hash());
        let raw = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, format!("{}\n截断", raw.split_once('\n').unwrap().0)).unwrap();
        assert!(
            EpubCleanedBook::try_load_from_disk(tmp.path(), cleaner.config_hash(), 1).is_none()
        );
    }
}
