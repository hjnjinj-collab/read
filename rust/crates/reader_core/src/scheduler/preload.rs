use std::cmp::Ordering;

/// Preload priority levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum PreloadPriority {
    /// Current chapter - immediate loading
    Critical = 0,
    /// Next chapter - high priority
    High = 1,
    /// Previous chapter - normal priority
    Normal = 2,
    /// Distant chapters - low priority
    Low = 3,
}

/// A preload task with priority.
#[derive(Debug, Clone)]
pub struct PreloadTask {
    pub chapter_index: usize,
    pub priority: PreloadPriority,
    pub book_id: String,
}

impl PartialEq for PreloadTask {
    fn eq(&self, other: &Self) -> bool {
        self.priority == other.priority && self.chapter_index == other.chapter_index
    }
}

impl Eq for PreloadTask {}

impl PartialOrd for PreloadTask {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for PreloadTask {
    fn cmp(&self, other: &Self) -> Ordering {
        // Higher priority (lower number) comes first
        other.priority.cmp(&self.priority)
            .then_with(|| self.chapter_index.cmp(&other.chapter_index))
    }
}

/// Trait for defining preload strategies.
pub trait PreloadStrategy: Send + Sync {
    /// Calculate which chapters to preload based on current position.
    fn calculate_preload_chapters(
        &self,
        current: usize,
        total: usize,
    ) -> Vec<(usize, PreloadPriority)>;
}

/// Default preload strategy.
///
/// - Current chapter: Critical (immediate loading)
/// - Next chapter: High (first 2 pages only)
/// - Previous chapter: Normal (full chapter)
///
/// M9.3：目标集从 ±2 收敛为 [N+1, N-1]——预加载"真预热"会整章重排入缓存，
/// 过宽窗口叠加自激触发曾把 10 槽 LRU 冲成滑动窗口（详见 BUGFIX_INDEX）。
pub struct DefaultPreloadStrategy {
    /// How many chapters ahead to preload
    pub look_ahead: usize,
    /// How many chapters behind to preload
    pub look_behind: usize,
}

impl Default for DefaultPreloadStrategy {
    fn default() -> Self {
        Self {
            // 原 2：N+2(Low) 已取消；只保 N+1(High)
            look_ahead: 1,
            // 原 1：N-2(Low) 已取消
            look_behind: 0,
        }
    }
}

impl PreloadStrategy for DefaultPreloadStrategy {
    fn calculate_preload_chapters(
        &self,
        current: usize,
        total: usize,
    ) -> Vec<(usize, PreloadPriority)> {
        let mut chapters = Vec::new();

        // Current chapter - Critical
        chapters.push((current, PreloadPriority::Critical));

        // Next chapter - High
        if current + 1 < total {
            chapters.push((current + 1, PreloadPriority::High));
        }

        // Previous chapter - Normal
        if current > 0 {
            chapters.push((current - 1, PreloadPriority::Normal));
        }

        // Look ahead - Low
        for i in 2..=self.look_ahead {
            if current + i < total {
                chapters.push((current + i, PreloadPriority::Low));
            }
        }

        // Look behind - Low
        for i in 1..=self.look_behind {
            if current >= i + 1 {
                chapters.push((current - i - 1, PreloadPriority::Low));
            }
        }

        chapters
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BinaryHeap;

    #[test]
    fn test_default_preload_strategy_narrowed_window() {
        // M9.3：目标集收敛为 当前/N+1/N-1，不再有 N±2(Low)
        let strategy = DefaultPreloadStrategy::default();
        let chapters = strategy.calculate_preload_chapters(5, 10);

        assert_eq!(chapters.len(), 3, "收敛后应恰含当前/N+1/N-1");
        assert!(chapters.iter().any(|&(idx, _)| idx == 5)); // Current
        assert!(chapters.iter().any(|&(idx, _)| idx == 6)); // Next
        assert!(chapters.iter().any(|&(idx, _)| idx == 4)); // Prev
        assert!(
            !chapters.iter().any(|&(idx, _)| idx == 7 || idx == 3),
            "不应再有 N±2 远端章节"
        );
    }

    #[test]
    fn test_preload_strategy_first_chapter() {
        let strategy = DefaultPreloadStrategy::default();
        let chapters = strategy.calculate_preload_chapters(0, 10);

        // Should not have previous chapter (index would be invalid)
        assert!(chapters.iter().all(|&(idx, _)| idx < 10));
        assert!(chapters.iter().any(|&(idx, _)| idx == 0)); // Current
        assert!(chapters.iter().any(|&(idx, _)| idx == 1)); // Next
    }

    #[test]
    fn test_preload_strategy_last_chapter() {
        let strategy = DefaultPreloadStrategy::default();
        let chapters = strategy.calculate_preload_chapters(9, 10);

        // Should not have next chapter
        assert!(!chapters.iter().any(|&(idx, _)| idx >= 10));
        assert!(chapters.iter().any(|&(idx, _)| idx == 9)); // Current
        assert!(chapters.iter().any(|&(idx, _)| idx == 8)); // Prev
    }

    #[test]
    fn test_preload_task_ordering() {
        let task1 = PreloadTask {
            chapter_index: 5,
            priority: PreloadPriority::Low,
            book_id: "book1".to_string(),
        };
        let task2 = PreloadTask {
            chapter_index: 3,
            priority: PreloadPriority::Critical,
            book_id: "book1".to_string(),
        };
        let task3 = PreloadTask {
            chapter_index: 4,
            priority: PreloadPriority::High,
            book_id: "book1".to_string(),
        };

        let mut heap = BinaryHeap::new();
        heap.push(task1);
        heap.push(task2);
        heap.push(task3);

        // Should pop in priority order: Critical, High, Low
        assert_eq!(heap.pop().unwrap().priority, PreloadPriority::Critical);
        assert_eq!(heap.pop().unwrap().priority, PreloadPriority::High);
        assert_eq!(heap.pop().unwrap().priority, PreloadPriority::Low);
    }
}
