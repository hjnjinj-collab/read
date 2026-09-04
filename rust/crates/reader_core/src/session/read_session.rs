use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use book_parser::{BookParser, BookMetadata, ChapterInfo};
use layout_engine::LayoutConfig;

use super::chapter_cache::ChapterCache;
use super::position_tracker::{ReadPositionTracker, ReadPosition, LayoutConfigHash, PageInfo};
use crate::cache::preprocessed_cache::PreprocessedCache;
use crate::scheduler::preload::{PreloadStrategy, DefaultPreloadStrategy, PreloadTask};

/// Unified read session manager.
///
/// Manages the entire reading lifecycle:
/// - Book opening and parsing
/// - Chapter caching (three-chapter window)
/// - Content preprocessing
/// - Pagination
/// - Position tracking and restoration
/// - Preload coordination
pub struct ReadSession {
    /// Book identifier
    pub book_id: String,
    /// Book metadata
    pub metadata: BookMetadata,
    /// Chapter list
    pub chapters: Vec<ChapterInfo>,
    /// Three-chapter cache
    pub chapter_cache: ChapterCache,
    /// Preprocessed content cache
    pub preprocessed_cache: PreprocessedCache,
    /// Position tracker
    pub position_tracker: ReadPositionTracker,
    /// Current configuration
    pub config: LayoutConfig,
    /// Current chapter index
    pub current_chapter: usize,
}

impl Clone for ReadSession {
    fn clone(&self) -> Self {
        Self {
            book_id: self.book_id.clone(),
            metadata: self.metadata.clone(),
            chapters: self.chapters.clone(),
            chapter_cache: ChapterCache::new(), // 创建新的缓存实例
            preprocessed_cache: PreprocessedCache::new(),
            position_tracker: ReadPositionTracker::new(),
            config: self.config.clone(),
            current_chapter: self.current_chapter,
        }
    }
}

impl ReadSession {
    /// Create a new read session from a parser
    pub fn new(
        book_id: String,
        parser: &mut Box<dyn BookParser>,
        config: LayoutConfig,
    ) -> Result<Self> {
        let metadata = parser.parse()
            .context("Failed to parse book")?;

        let chapters = parser.get_chapter_list()
            .context("Failed to get chapter list")?;

        Ok(Self {
            book_id,
            metadata,
            chapters,
            chapter_cache: ChapterCache::new(),
            preprocessed_cache: PreprocessedCache::new(),
            position_tracker: ReadPositionTracker::new(),
            config,
            current_chapter: 0,
        })
    }

    /// Jump to a specific chapter
    pub fn jump_to_chapter(&mut self, chapter_index: usize) -> Result<()> {
        if chapter_index >= self.chapters.len() {
            anyhow::bail!("Chapter index out of bounds: {}", chapter_index);
        }

        self.current_chapter = chapter_index;
        self.chapter_cache.jump_to(chapter_index);

        Ok(())
    }

    /// Move to next chapter
    pub fn move_to_next(&mut self) -> Result<()> {
        if self.current_chapter + 1 >= self.chapters.len() {
            anyhow::bail!("Already at last chapter");
        }

        self.chapter_cache.move_to_next();
        self.current_chapter += 1;

        Ok(())
    }

    /// Move to previous chapter
    pub fn move_to_prev(&mut self) -> Result<()> {
        if self.current_chapter == 0 {
            anyhow::bail!("Already at first chapter");
        }

        self.chapter_cache.move_to_prev();
        self.current_chapter -= 1;

        Ok(())
    }

    /// Get current chapter index
    pub fn current_chapter_index(&self) -> usize {
        self.current_chapter
    }

    /// Get total chapters
    pub fn total_chapters(&self) -> usize {
        self.chapters.len()
    }

    /// Get chapter info
    pub fn get_chapter_info(&self, index: usize) -> Option<&ChapterInfo> {
        self.chapters.get(index)
    }

    /// Save reading position
    pub fn save_position(&mut self, page_index: usize, char_offset: usize) {
        let config_hash = self.config_hash();

        let position = ReadPosition {
            book_id: self.book_id.clone(),
            chapter_index: self.current_chapter,
            char_offset,
            page_index,
            config_hash,
        };

        self.position_tracker.save_position(position);
    }

    /// Restore reading position
    pub fn restore_position(&self, pages: &[PageInfo]) -> Option<usize> {
        let config_hash = self.config_hash();
        self.position_tracker.restore_position(config_hash, pages)
    }

    /// Calculate configuration hash
    pub fn config_hash(&self) -> u64 {
        let config = LayoutConfigHash {
            width: self.config.width,
            height: self.config.height,
            font_size: self.config.font_size,
            line_height_multiplier: self.config.line_height_multiplier,
            font_name: self.config.font_name.clone(),
            padding_left: self.config.padding.left,
            padding_top: self.config.padding.top,
            padding_right: self.config.padding.right,
            padding_bottom: self.config.padding.bottom,
            letter_spacing: self.config.letter_spacing,
            paragraph_spacing: self.config.paragraph_spacing,
            page_fill_threshold: self.config.page_fill_threshold,
        };
        config.compute_hash()
    }

    /// Check if configuration has changed
    pub fn config_changed(&self) -> bool {
        self.position_tracker.config_changed(self.config_hash())
    }

    /// Update configuration
    pub fn update_config(&mut self, config: LayoutConfig) {
        self.config = config;
        // Clear caches when config changes
        self.chapter_cache.clear();
    }

    /// Get preload tasks for current position
    pub fn get_preload_tasks(&self) -> Vec<PreloadTask> {
        let strategy = DefaultPreloadStrategy::default();
        let chapters_to_preload = strategy
            .calculate_preload_chapters(self.current_chapter, self.chapters.len());

        chapters_to_preload
            .into_iter()
            .map(|(idx, priority)| PreloadTask {
                chapter_index: idx,
                priority,
                book_id: self.book_id.clone(),
            })
            .collect()
    }

    /// Get memory usage estimate
    pub fn estimate_memory_usage(&self) -> usize {
        self.chapter_cache.estimate_memory_usage()
    }
}

/// Read session manager for managing multiple sessions
///
/// 支持 LRU 淘汰策略，自动管理会话生命周期。
pub struct ReadSessionManager {
    sessions: Arc<Mutex<std::collections::HashMap<String, ReadSession>>>,
    /// 最大会话数
    max_sessions: usize,
    /// 访问顺序（用于 LRU 淘汰）
    access_order: Arc<Mutex<Vec<String>>>,
}

impl ReadSessionManager {
    /// Create a new session manager with default max sessions (10)
    pub fn new() -> Self {
        Self::with_max_sessions(10)
    }

    /// Create a new session manager with specified max sessions
    pub fn with_max_sessions(max_sessions: usize) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(std::collections::HashMap::new())),
            max_sessions,
            access_order: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Create a new session
    pub fn create_session(
        &self,
        book_id: String,
        parser: &mut Box<dyn BookParser>,
        config: LayoutConfig,
    ) -> Result<()> {
        let session = ReadSession::new(book_id.clone(), parser, config)?;

        let mut sessions = self.sessions.lock().unwrap();
        let mut access_order = self.access_order.lock().unwrap();

        // 如果超过最大会话数，淘汰最久未访问的会话
        if sessions.len() >= self.max_sessions {
            if let Some(oldest_id) = access_order.first().cloned() {
                sessions.remove(&oldest_id);
                access_order.retain(|id| id != &oldest_id);
            }
        }

        sessions.insert(book_id.clone(), session);
        access_order.push(book_id);

        Ok(())
    }

    /// Get a session by book ID
    pub fn get_session(&self, book_id: &str) -> Option<ReadSession> {
        let sessions = self.sessions.lock().unwrap();
        let mut access_order = self.access_order.lock().unwrap();

        if sessions.contains_key(book_id) {
            // 更新访问顺序（移到最后）
            access_order.retain(|id| id != book_id);
            access_order.push(book_id.to_string());
            // 返回会话的克隆
            sessions.get(book_id).cloned()
        } else {
            None
        }
    }

    /// Get a session by book ID (immutable reference)
    pub fn get_session_ref(&self, book_id: &str) -> Option<ReadSessionRef> {
        let sessions = self.sessions.lock().unwrap();
        let mut access_order = self.access_order.lock().unwrap();

        if sessions.contains_key(book_id) {
            // 更新访问顺序
            access_order.retain(|id| id != book_id);
            access_order.push(book_id.to_string());
            Some(ReadSessionRef {
                session_manager: self.sessions.clone(),
                book_id: book_id.to_string(),
            })
        } else {
            None
        }
    }

    /// Check if a session exists
    pub fn has_session(&self, book_id: &str) -> bool {
        let sessions = self.sessions.lock().unwrap();
        sessions.contains_key(book_id)
    }

    /// Remove a session
    pub fn remove_session(&self, book_id: &str) -> bool {
        let mut sessions = self.sessions.lock().unwrap();
        let mut access_order = self.access_order.lock().unwrap();

        let removed = sessions.remove(book_id).is_some();
        if removed {
            access_order.retain(|id| id != book_id);
        }
        removed
    }

    /// Get number of active sessions
    pub fn session_count(&self) -> usize {
        let sessions = self.sessions.lock().unwrap();
        sessions.len()
    }

    /// Get all session IDs
    pub fn session_ids(&self) -> Vec<String> {
        let access_order = self.access_order.lock().unwrap();
        access_order.clone()
    }

    /// Clear all sessions
    pub fn clear(&self) {
        let mut sessions = self.sessions.lock().unwrap();
        let mut access_order = self.access_order.lock().unwrap();
        sessions.clear();
        access_order.clear();
    }

    /// Get max sessions
    pub fn max_sessions(&self) -> usize {
        self.max_sessions
    }

    /// Get memory usage estimate
    pub fn estimate_memory_usage(&self) -> usize {
        let sessions = self.sessions.lock().unwrap();
        sessions.values().map(|s| s.estimate_memory_usage()).sum()
    }
}

impl Default for ReadSessionManager {
    fn default() -> Self {
        Self::new()
    }
}

/// Read session reference (for borrowing without ownership)
pub struct ReadSessionRef {
    session_manager: Arc<Mutex<std::collections::HashMap<String, ReadSession>>>,
    book_id: String,
}

impl ReadSessionRef {
    /// Get book ID
    pub fn book_id(&self) -> &str {
        &self.book_id
    }

    /// Execute a closure with the session
    pub fn with_session<F, R>(&self, f: F) -> Option<R>
    where
        F: FnOnce(&ReadSession) -> R,
    {
        let sessions = self.session_manager.lock().unwrap();
        sessions.get(&self.book_id).map(|session| f(session))
    }

    /// Execute a mutable closure with the session
    pub fn with_session_mut<F, R>(&self, f: F) -> Option<R>
    where
        F: FnOnce(&mut ReadSession) -> R,
    {
        let mut sessions = self.session_manager.lock().unwrap();
        sessions.get_mut(&self.book_id).map(|session| f(session))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use layout_engine::EdgeInsets;

    fn create_test_config() -> LayoutConfig {
        LayoutConfig {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            padding: EdgeInsets {
                left: 20.0,
                top: 20.0,
                right: 20.0,
                bottom: 20.0,
            },
            font_name: "TestFont".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
            show_comments: true,
            justify: false,
            punctuation_compress: false,
        }
    }

    #[test]
    fn test_read_session_manager_new() {
        let manager = ReadSessionManager::new();
        assert_eq!(manager.session_count(), 0);
        assert_eq!(manager.max_sessions(), 10);
    }

    #[test]
    fn test_read_session_manager_with_max_sessions() {
        let manager = ReadSessionManager::with_max_sessions(5);
        assert_eq!(manager.max_sessions(), 5);
    }

    #[test]
    fn test_read_session_manager_clear() {
        let manager = ReadSessionManager::new();
        manager.clear();
        assert_eq!(manager.session_count(), 0);
    }

    #[test]
    fn test_config_hash_consistency() {
        let config = create_test_config();
        let config_hash = LayoutConfigHash {
            width: config.width,
            height: config.height,
            font_size: config.font_size,
            line_height_multiplier: config.line_height_multiplier,
            font_name: config.font_name.clone(),
            padding_left: config.padding.left,
            padding_top: config.padding.top,
            padding_right: config.padding.right,
            padding_bottom: config.padding.bottom,
            letter_spacing: config.letter_spacing,
            paragraph_spacing: config.paragraph_spacing,
            page_fill_threshold: config.page_fill_threshold,
        };

        let hash1 = config_hash.compute_hash();
        let hash2 = config_hash.compute_hash();

        assert_eq!(hash1, hash2);
    }

    #[test]
    fn test_read_session_manager_has_session() {
        let manager = ReadSessionManager::new();
        assert!(!manager.has_session("book1"));
    }

    #[test]
    fn test_read_session_manager_session_ids() {
        let manager = ReadSessionManager::new();
        assert!(manager.session_ids().is_empty());
    }

    #[test]
    fn test_read_session_manager_estimate_memory() {
        let manager = ReadSessionManager::new();
        assert_eq!(manager.estimate_memory_usage(), 0);
    }
}
