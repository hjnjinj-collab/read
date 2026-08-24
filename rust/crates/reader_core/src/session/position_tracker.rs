use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

/// Reading position tracker for configuration migration.
///
/// Saves reading position based on character offset (configuration-independent)
/// and restores position when configuration changes.
#[derive(Debug, Clone)]
pub struct ReadPosition {
    /// Book identifier
    pub book_id: String,
    /// Chapter index
    pub chapter_index: usize,
    /// Character offset within the chapter
    pub char_offset: usize,
    /// Page index (configuration-dependent)
    pub page_index: usize,
    /// Configuration hash when position was saved
    pub config_hash: u64,
}

/// Layout configuration for hash calculation
#[derive(Debug, Clone)]
pub struct LayoutConfigHash {
    pub width: f32,
    pub height: f32,
    pub font_size: f32,
    pub line_height_multiplier: f32,
    pub font_name: String,
    pub padding_left: f32,
    pub padding_top: f32,
    pub padding_right: f32,
    pub padding_bottom: f32,
    pub letter_spacing: f32,
    pub paragraph_spacing: f32,
    pub page_fill_threshold: f32,
}

impl LayoutConfigHash {
    /// Calculate configuration hash
    pub fn compute_hash(&self) -> u64 {
        let mut hasher = DefaultHasher::new();

        // Hash all configuration parameters
        self.width.to_bits().hash(&mut hasher);
        self.height.to_bits().hash(&mut hasher);
        self.font_size.to_bits().hash(&mut hasher);
        self.line_height_multiplier.to_bits().hash(&mut hasher);
        self.font_name.hash(&mut hasher);
        self.padding_left.to_bits().hash(&mut hasher);
        self.padding_top.to_bits().hash(&mut hasher);
        self.padding_right.to_bits().hash(&mut hasher);
        self.padding_bottom.to_bits().hash(&mut hasher);
        self.letter_spacing.to_bits().hash(&mut hasher);
        self.paragraph_spacing.to_bits().hash(&mut hasher);
        self.page_fill_threshold.to_bits().hash(&mut hasher);

        hasher.finish()
    }
}

/// Position tracker for managing reading positions
pub struct ReadPositionTracker {
    /// Current position
    position: Option<ReadPosition>,
}

impl ReadPositionTracker {
    /// Create a new position tracker
    pub fn new() -> Self {
        Self { position: None }
    }

    /// Save reading position
    pub fn save_position(&mut self, position: ReadPosition) {
        self.position = Some(position);
    }

    /// Get current position
    pub fn current_position(&self) -> Option<&ReadPosition> {
        self.position.as_ref()
    }

    /// Check if configuration has changed
    pub fn config_changed(&self, new_config_hash: u64) -> bool {
        self.position
            .as_ref()
            .map(|p| p.config_hash != new_config_hash)
            .unwrap_or(false)
    }

    /// Find page by character offset using binary search
    ///
    /// Returns the page index that contains the given character offset
    pub fn find_page_by_char_offset(pages: &[PageInfo], char_offset: usize) -> usize {
        if pages.is_empty() {
            return 0;
        }

        // Binary search for the page containing char_offset
        let mut left = 0;
        let mut right = pages.len();

        while left < right {
            let mid = left + (right - left) / 2;
            let page = &pages[mid];

            if char_offset < page.start_char_index {
                right = mid;
            } else if char_offset >= page.end_char_index {
                left = mid + 1;
            } else {
                // Found the page
                return mid;
            }
        }

        // Return the closest page
        left.min(pages.len() - 1)
    }

    /// Restore position with new configuration
    ///
    /// Returns the page index to restore to
    pub fn restore_position(
        &self,
        new_config_hash: u64,
        pages: &[PageInfo],
    ) -> Option<usize> {
        self.position.as_ref().and_then(|pos| {
            if pos.config_hash == new_config_hash {
                // Configuration unchanged, use saved page index
                Some(pos.page_index)
            } else {
                // Configuration changed, find page by character offset
                Some(Self::find_page_by_char_offset(pages, pos.char_offset))
            }
        })
    }
}

impl Default for ReadPositionTracker {
    fn default() -> Self {
        Self::new()
    }
}

/// Page information for position tracking
#[derive(Debug, Clone)]
pub struct PageInfo {
    pub page_index: usize,
    pub start_char_index: usize,
    pub end_char_index: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_layout_config_hash() {
        let config1 = LayoutConfigHash {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            font_name: "SimSun".to_string(),
            padding_left: 20.0,
            padding_top: 20.0,
            padding_right: 20.0,
            padding_bottom: 20.0,
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
        };

        let config2 = LayoutConfigHash {
            width: 360.0,
            height: 640.0,
            font_size: 18.0,
            line_height_multiplier: 1.5,
            font_name: "SimSun".to_string(),
            padding_left: 20.0,
            padding_top: 20.0,
            padding_right: 20.0,
            padding_bottom: 20.0,
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
        };

        let config3 = LayoutConfigHash {
            width: 360.0,
            height: 640.0,
            font_size: 20.0, // Different font size
            line_height_multiplier: 1.5,
            font_name: "SimSun".to_string(),
            padding_left: 20.0,
            padding_top: 20.0,
            padding_right: 20.0,
            padding_bottom: 20.0,
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
        };

        assert_eq!(config1.compute_hash(), config2.compute_hash());
        assert_ne!(config1.compute_hash(), config3.compute_hash());
    }

    #[test]
    fn test_read_position_tracker_new() {
        let tracker = ReadPositionTracker::new();
        assert!(tracker.current_position().is_none());
    }

    #[test]
    fn test_save_and_get_position() {
        let mut tracker = ReadPositionTracker::new();

        let position = ReadPosition {
            book_id: "book1".to_string(),
            chapter_index: 5,
            char_offset: 1234,
            page_index: 10,
            config_hash: 12345,
        };

        tracker.save_position(position.clone());
        assert!(tracker.current_position().is_some());
        assert_eq!(tracker.current_position().unwrap().chapter_index, 5);
        assert_eq!(tracker.current_position().unwrap().char_offset, 1234);
    }

    #[test]
    fn test_config_changed() {
        let mut tracker = ReadPositionTracker::new();

        let position = ReadPosition {
            book_id: "book1".to_string(),
            chapter_index: 5,
            char_offset: 1234,
            page_index: 10,
            config_hash: 12345,
        };

        tracker.save_position(position);

        assert!(!tracker.config_changed(12345));
        assert!(tracker.config_changed(12346));
    }

    #[test]
    fn test_find_page_by_char_offset() {
        let pages = vec![
            PageInfo {
                page_index: 0,
                start_char_index: 0,
                end_char_index: 100,
            },
            PageInfo {
                page_index: 1,
                start_char_index: 100,
                end_char_index: 200,
            },
            PageInfo {
                page_index: 2,
                start_char_index: 200,
                end_char_index: 300,
            },
        ];

        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 0), 0);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 50), 0);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 100), 1);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 150), 1);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 200), 2);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 250), 2);
    }

    #[test]
    fn test_find_page_by_char_offset_boundary() {
        let pages = vec![
            PageInfo {
                page_index: 0,
                start_char_index: 0,
                end_char_index: 100,
            },
            PageInfo {
                page_index: 1,
                start_char_index: 100,
                end_char_index: 200,
            },
        ];

        // Test boundary cases
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 0), 0);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 99), 0);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 100), 1);
        assert_eq!(ReadPositionTracker::find_page_by_char_offset(&pages, 199), 1);
    }

    #[test]
    fn test_restore_position_same_config() {
        let mut tracker = ReadPositionTracker::new();

        let position = ReadPosition {
            book_id: "book1".to_string(),
            chapter_index: 5,
            char_offset: 1234,
            page_index: 10,
            config_hash: 12345,
        };

        tracker.save_position(position);

        let pages = vec![
            PageInfo {
                page_index: 0,
                start_char_index: 0,
                end_char_index: 100,
            },
            PageInfo {
                page_index: 1,
                start_char_index: 100,
                end_char_index: 200,
            },
        ];

        // Same config, should return saved page index
        let restored = tracker.restore_position(12345, &pages);
        assert_eq!(restored, Some(10));
    }

    #[test]
    fn test_restore_position_different_config() {
        let mut tracker = ReadPositionTracker::new();

        let position = ReadPosition {
            book_id: "book1".to_string(),
            chapter_index: 5,
            char_offset: 150,
            page_index: 10,
            config_hash: 12345,
        };

        tracker.save_position(position);

        let pages = vec![
            PageInfo {
                page_index: 0,
                start_char_index: 0,
                end_char_index: 100,
            },
            PageInfo {
                page_index: 1,
                start_char_index: 100,
                end_char_index: 200,
            },
            PageInfo {
                page_index: 2,
                start_char_index: 200,
                end_char_index: 300,
            },
        ];

        // Different config, should find page by char offset
        let restored = tracker.restore_position(12346, &pages);
        assert_eq!(restored, Some(1)); // char_offset 150 is in page 1
    }

    #[test]
    fn test_restore_position_no_position() {
        let tracker = ReadPositionTracker::new();

        let pages = vec![
            PageInfo {
                page_index: 0,
                start_char_index: 0,
                end_char_index: 100,
            },
        ];

        let restored = tracker.restore_position(12345, &pages);
        assert_eq!(restored, None);
    }
}