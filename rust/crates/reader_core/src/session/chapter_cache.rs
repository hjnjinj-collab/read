use layout_engine::Page;

/// Cached chapter pages.
#[derive(Debug, Clone)]
pub struct CachedChapterPages {
    /// Chapter index
    pub chapter_index: usize,
    /// All pages for this chapter
    pub pages: Vec<Page>,
    /// Total word count
    pub word_count: usize,
}

impl CachedChapterPages {
    /// Create new cached chapter pages.
    pub fn new(chapter_index: usize, pages: Vec<Page>, word_count: usize) -> Self {
        Self {
            chapter_index,
            pages,
            word_count,
        }
    }

    /// Get page count.
    pub fn page_count(&self) -> usize {
        self.pages.len()
    }

    /// Get a specific page.
    pub fn get_page(&self, page_index: usize) -> Option<&Page> {
        self.pages.get(page_index)
    }
}

/// Three-chapter sliding window cache.
///
/// Maintains cached pages for:
/// - Previous chapter (full)
/// - Current chapter (full)
/// - Next chapter (first 2 pages)
pub struct ChapterCache {
    /// Previous chapter cache
    pub prev: Option<CachedChapterPages>,
    /// Current chapter cache
    pub current: Option<CachedChapterPages>,
    /// Next chapter cache
    pub next: Option<CachedChapterPages>,
    /// Current chapter index
    pub current_index: usize,
}

impl ChapterCache {
    /// Create a new empty chapter cache.
    pub fn new() -> Self {
        Self {
            prev: None,
            current: None,
            next: None,
            current_index: 0,
        }
    }

    /// Move to next chapter.
    ///
    /// Shifts the window:
    /// - prev ← current
    /// - current ← next
    /// - next ← None (to be loaded)
    pub fn move_to_next(&mut self) {
        self.prev = self.current.take();
        self.current = self.next.take();
        self.next = None;
        self.current_index += 1;
    }

    /// Move to previous chapter.
    ///
    /// Shifts the window:
    /// - next ← current
    /// - current ← prev
    /// - prev ← None (to be loaded)
    pub fn move_to_prev(&mut self) {
        self.next = self.current.take();
        self.current = self.prev.take();
        self.prev = None;
        if self.current_index > 0 {
            self.current_index -= 1;
        }
    }

    /// Jump to a specific chapter.
    ///
    /// Clears the cache and sets the new current chapter.
    pub fn jump_to(&mut self, chapter_index: usize) {
        self.prev = None;
        self.current = None;
        self.next = None;
        self.current_index = chapter_index;
    }

    /// Set the current chapter cache.
    pub fn set_current(&mut self, cache: CachedChapterPages) {
        self.current = Some(cache);
    }

    /// Set the previous chapter cache.
    pub fn set_prev(&mut self, cache: CachedChapterPages) {
        self.prev = Some(cache);
    }

    /// Set the next chapter cache.
    pub fn set_next(&mut self, cache: CachedChapterPages) {
        self.next = Some(cache);
    }

    /// Get current chapter pages.
    pub fn current_pages(&self) -> Option<&CachedChapterPages> {
        self.current.as_ref()
    }

    /// Get previous chapter pages.
    pub fn prev_pages(&self) -> Option<&CachedChapterPages> {
        self.prev.as_ref()
    }

    /// Get next chapter pages.
    pub fn next_pages(&self) -> Option<&CachedChapterPages> {
        self.next.as_ref()
    }

    /// Get current chapter index.
    pub fn current_index(&self) -> usize {
        self.current_index
    }

    /// Check if current chapter is cached.
    pub fn has_current(&self) -> bool {
        self.current.is_some()
    }

    /// Check if previous chapter is cached.
    pub fn has_prev(&self) -> bool {
        self.prev.is_some()
    }

    /// Check if next chapter is cached.
    pub fn has_next(&self) -> bool {
        self.next.is_some()
    }

    /// Get total cached pages.
    pub fn total_cached_pages(&self) -> usize {
        let mut total = 0;
        if let Some(ref prev) = self.prev {
            total += prev.page_count();
        }
        if let Some(ref current) = self.current {
            total += current.page_count();
        }
        if let Some(ref next) = self.next {
            total += next.page_count();
        }
        total
    }

    /// Estimate memory usage in bytes.
    ///
    /// Rough estimate: each page ~10KB
    pub fn estimate_memory_usage(&self) -> usize {
        self.total_cached_pages() * 10 * 1024
    }

    /// Clear all cached content.
    pub fn clear(&mut self) {
        self.prev = None;
        self.current = None;
        self.next = None;
    }
}

impl Default for ChapterCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use layout_engine::{Page, PageEntry, TextLine};

    fn create_test_page(page_index: usize, chapter_index: usize) -> Page {
        Page {
            page_index,
            chapter_index,
            entries: vec![PageEntry::Text(TextLine {
                text: format!("Page {} content", page_index),
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
            .map(|i| create_test_page(i, chapter_index))
            .collect();
        CachedChapterPages::new(chapter_index, pages, page_count * 500)
    }

    #[test]
    fn test_chapter_cache_new() {
        let cache = ChapterCache::new();
        assert!(!cache.has_current());
        assert!(!cache.has_prev());
        assert!(!cache.has_next());
        assert_eq!(cache.current_index(), 0);
    }

    #[test]
    fn test_chapter_cache_set_and_get() {
        let mut cache = ChapterCache::new();
        let chapter = create_test_chapter(0, 5);

        cache.set_current(chapter);
        assert!(cache.has_current());
        assert_eq!(cache.current_pages().unwrap().page_count(), 5);
    }

    #[test]
    fn test_chapter_cache_move_to_next() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 5);
        let chapter1 = create_test_chapter(1, 3);

        cache.set_current(chapter0);
        cache.set_next(chapter1);

        cache.move_to_next();

        assert_eq!(cache.current_index(), 1);
        assert!(cache.has_prev()); // chapter0 moved to prev
        assert!(cache.has_current()); // chapter1 moved to current
        assert!(!cache.has_next()); // next is now None
    }

    #[test]
    fn test_chapter_cache_move_to_prev() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 5);
        let chapter1 = create_test_chapter(1, 3);

        cache.set_prev(chapter0);
        cache.set_current(chapter1);

        cache.move_to_prev();

        assert_eq!(cache.current_index(), 0);
        assert!(!cache.has_prev()); // prev is now None
        assert!(cache.has_current()); // chapter0 moved to current
        assert!(cache.has_next()); // chapter1 moved to next
    }

    #[test]
    fn test_chapter_cache_jump_to() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 5);

        cache.set_current(chapter0);
        assert!(cache.has_current());

        cache.jump_to(10);
        assert_eq!(cache.current_index(), 10);
        assert!(!cache.has_current());
        assert!(!cache.has_prev());
        assert!(!cache.has_next());
    }

    #[test]
    fn test_chapter_cache_total_pages() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 5);
        let chapter1 = create_test_chapter(1, 3);
        let chapter2 = create_test_chapter(2, 2);

        cache.set_prev(chapter0);
        cache.set_current(chapter1);
        cache.set_next(chapter2);

        assert_eq!(cache.total_cached_pages(), 10); // 5 + 3 + 2
    }

    #[test]
    fn test_chapter_cache_memory_estimate() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 10);

        cache.set_current(chapter0);

        // 10 pages * 10KB = 100KB
        assert_eq!(cache.estimate_memory_usage(), 10 * 10 * 1024);
    }

    #[test]
    fn test_chapter_cache_clear() {
        let mut cache = ChapterCache::new();
        let chapter0 = create_test_chapter(0, 5);
        let chapter1 = create_test_chapter(1, 3);

        cache.set_prev(chapter0);
        cache.set_current(chapter1);

        cache.clear();
        assert!(!cache.has_prev());
        assert!(!cache.has_current());
        assert!(!cache.has_next());
    }

    #[test]
    fn test_cached_chapter_pages() {
        let chapter = create_test_chapter(0, 5);

        assert_eq!(chapter.chapter_index, 0);
        assert_eq!(chapter.page_count(), 5);
        assert_eq!(chapter.word_count, 2500);
        assert!(chapter.get_page(0).is_some());
        assert!(chapter.get_page(4).is_some());
        assert!(chapter.get_page(5).is_none());
    }
}
