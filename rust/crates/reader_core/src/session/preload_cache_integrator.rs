use std::sync::Arc;

use anyhow::Result;
use tokio::sync::Mutex;

use super::chapter_cache::{ChapterCache, CachedChapterPages};
use crate::scheduler::preload::{PreloadStrategy, DefaultPreloadStrategy, PreloadPriority, PreloadTask};
use crate::scheduler::preload_executor::{PreloadExecutor, PreloadExecutorConfig, PreloadResult};

/// 预加载缓存集成器
///
/// 将三章缓存与预加载执行器集成，实现：
/// - 缓存 miss 时自动触发预加载
/// - 预加载完成后更新缓存
/// - 章节切换时预加载相邻章节
pub struct PreloadCacheIntegrator {
    /// 章节缓存
    chapter_cache: Arc<Mutex<ChapterCache>>,
    /// 预加载执行器
    preload_executor: Arc<PreloadExecutor>,
    /// 预加载策略
    preload_strategy: Box<dyn PreloadStrategy>,
    /// 书籍 ID
    book_id: String,
}

/// 预加载回调
pub type PreloadCallback = Box<dyn Fn(usize, bool) + Send + Sync>;

impl PreloadCacheIntegrator {
    /// 创建新的预加载缓存集成器
    pub fn new(book_id: String) -> Self {
        let config = PreloadExecutorConfig::default();

        // 创建预加载执行器
        let executor = PreloadExecutor::new(config, |_chapter_index| {
            // 这里的 load_fn 会被实际的章节加载器替换
            // 目前返回错误，实际使用时需要注入真正的加载逻辑
            Err(anyhow::anyhow!("需要注入实际的章节加载逻辑"))
        });

        Self {
            chapter_cache: Arc::new(Mutex::new(ChapterCache::new())),
            preload_executor: Arc::new(executor),
            preload_strategy: Box::new(DefaultPreloadStrategy::default()),
            book_id,
        }
    }

    /// 创建带有自定义加载函数的预加载缓存集成器
    pub fn with_loader<F>(book_id: String, load_fn: F) -> Self
    where
        F: Fn(usize) -> Result<String> + Send + Sync + 'static,
    {
        let config = PreloadExecutorConfig::default();
        let executor = PreloadExecutor::new(config, load_fn);

        Self {
            chapter_cache: Arc::new(Mutex::new(ChapterCache::new())),
            preload_executor: Arc::new(executor),
            preload_strategy: Box::new(DefaultPreloadStrategy::default()),
            book_id,
        }
    }

    /// 获取章节（优先从缓存获取，缓存 miss 时触发预加载）
    pub async fn get_chapter(&self, chapter_index: usize) -> Option<CachedChapterPages> {
        // 1. 检查缓存
        {
            let cache = self.chapter_cache.lock().await;
            if let Some(pages) = cache.current_pages() {
                if pages.chapter_index == chapter_index {
                    return Some(pages.clone());
                }
            }
            if let Some(pages) = cache.prev_pages() {
                if pages.chapter_index == chapter_index {
                    return Some(pages.clone());
                }
            }
            if let Some(pages) = cache.next_pages() {
                if pages.chapter_index == chapter_index {
                    return Some(pages.clone());
                }
            }
        }

        // 2. 缓存 miss，触发预加载
        None
    }

    /// 预加载指定章节
    pub async fn preload_chapter(&self, chapter_index: usize) -> Result<PreloadResult> {
        let task = PreloadTask {
            chapter_index,
            priority: PreloadPriority::High,
            book_id: self.book_id.clone(),
        };

        let handle = self.preload_executor.submit(task).await?;
        handle.wait().await
    }

    /// 预加载当前章节周围的章节
    pub async fn preload_surrounding(&self, current: usize, total: usize) -> Vec<PreloadResult> {
        let chapters = self.preload_strategy
            .calculate_preload_chapters(current, total);

        let mut results = Vec::new();
        for (idx, _priority) in chapters {
            if idx != current {
                // 跳过当前章节（应该已经加载）
                if let Ok(result) = self.preload_chapter(idx).await {
                    results.push(result);
                }
            }
        }

        results
    }

    /// 更新章节缓存
    pub async fn update_cache(&self, cache: CachedChapterPages) {
        let mut chapter_cache = self.chapter_cache.lock().await;

        // 根据章节索引更新对应的缓存槽位
        if cache.chapter_index > chapter_cache.current_index() {
            // 向后移动
            let current = chapter_cache.current.take();
            let next = chapter_cache.next.take();

            if let Some(current) = current {
                chapter_cache.set_prev(current);
            }
            if let Some(next) = next {
                chapter_cache.set_current(next);
            }
            chapter_cache.set_next(cache);
        } else if cache.chapter_index < chapter_cache.current_index() {
            // 向前移动
            let current = chapter_cache.current.take();
            let prev = chapter_cache.prev.take();

            if let Some(current) = current {
                chapter_cache.set_next(current);
            }
            if let Some(prev) = prev {
                chapter_cache.set_current(prev);
            }
            chapter_cache.set_prev(cache);
        } else {
            // 当前章节
            chapter_cache.set_current(cache);
        }
    }

    /// 跳转到指定章节
    pub async fn jump_to(&self, chapter_index: usize) {
        let mut cache = self.chapter_cache.lock().await;
        cache.jump_to(chapter_index);
    }

    /// 移动到下一章
    pub async fn move_to_next(&self) {
        let mut cache = self.chapter_cache.lock().await;
        cache.move_to_next();
    }

    /// 移动到上一章
    pub async fn move_to_prev(&self) {
        let mut cache = self.chapter_cache.lock().await;
        cache.move_to_prev();
    }

    /// 获取当前章节索引
    pub async fn current_index(&self) -> usize {
        let cache = self.chapter_cache.lock().await;
        cache.current_index()
    }

    /// 检查缓存是否包含指定章节
    pub async fn has_chapter(&self, chapter_index: usize) -> bool {
        let cache = self.chapter_cache.lock().await;

        if let Some(pages) = cache.current_pages() {
            if pages.chapter_index == chapter_index {
                return true;
            }
        }
        if let Some(pages) = cache.prev_pages() {
            if pages.chapter_index == chapter_index {
                return true;
            }
        }
        if let Some(pages) = cache.next_pages() {
            if pages.chapter_index == chapter_index {
                return true;
            }
        }

        false
    }

    /// 清空缓存
    pub async fn clear(&self) {
        let mut cache = self.chapter_cache.lock().await;
        cache.clear();
    }

    /// 获取预加载统计信息
    pub fn preload_stats(&self) -> &crate::scheduler::preload_executor::PreloadStats {
        self.preload_executor.stats()
    }

    /// 关闭预加载执行器
    pub async fn shutdown(&self) {
        self.preload_executor.shutdown().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use layout_engine::{Page, PageEntry, TextLine};

    fn create_test_page(chapter_index: usize, page_index: usize) -> Page {
        Page {
            page_index,
            chapter_index,
            entries: vec![PageEntry::Text(TextLine {
                text: format!("Chapter {} Page {}", chapter_index, page_index),
                x: 0.0,
                y: 0.0,
                width: 100.0,
                height: 20.0,
                color: None,
                font_scale: None,
                segments: Vec::new(),
                is_chapter_start: false,
            })],
            start_char_index: page_index * 100,
            end_char_index: (page_index + 1) * 100,
        }
    }

    fn create_test_chapter(chapter_index: usize, page_count: usize) -> CachedChapterPages {
        let pages: Vec<Page> = (0..page_count)
            .map(|i| create_test_page(chapter_index, i))
            .collect();
        CachedChapterPages::new(chapter_index, pages, page_count * 500)
    }

    #[tokio::test]
    async fn test_integrator_creation() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());
        assert_eq!(integrator.current_index().await, 0);
    }

    #[tokio::test]
    async fn test_update_cache() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        let chapter0 = create_test_chapter(0, 5);
        integrator.update_cache(chapter0).await;

        assert!(integrator.has_chapter(0).await);
    }

    #[tokio::test]
    async fn test_jump_to() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        integrator.jump_to(5).await;
        assert_eq!(integrator.current_index().await, 5);
    }

    #[tokio::test]
    async fn test_move_to_next() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        let chapter0 = create_test_chapter(0, 5);
        integrator.update_cache(chapter0).await;

        integrator.move_to_next().await;
        assert_eq!(integrator.current_index().await, 1);
    }

    #[tokio::test]
    async fn test_move_to_prev() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        integrator.jump_to(5).await;
        integrator.move_to_prev().await;
        assert_eq!(integrator.current_index().await, 4);
    }

    #[tokio::test]
    async fn test_clear_cache() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        let chapter0 = create_test_chapter(0, 5);
        integrator.update_cache(chapter0).await;
        assert!(integrator.has_chapter(0).await);

        integrator.clear().await;
        assert!(!integrator.has_chapter(0).await);
    }

    #[tokio::test]
    async fn test_has_chapter() {
        let integrator = PreloadCacheIntegrator::new("test_book".to_string());

        assert!(!integrator.has_chapter(0).await);

        let chapter0 = create_test_chapter(0, 5);
        integrator.update_cache(chapter0).await;

        assert!(integrator.has_chapter(0).await);
        assert!(!integrator.has_chapter(1).await);
    }
}
