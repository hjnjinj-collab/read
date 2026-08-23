use std::collections::BinaryHeap;
use std::cmp::Ordering;
use std::sync::Arc;

use tokio::sync::{Mutex, Semaphore};

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
/// - Next 2 chapters: Low (optional)
pub struct DefaultPreloadStrategy {
    /// How many chapters ahead to preload
    pub look_ahead: usize,
    /// How many chapters behind to preload
    pub look_behind: usize,
}

impl Default for DefaultPreloadStrategy {
    fn default() -> Self {
        Self {
            look_ahead: 2,
            look_behind: 1,
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

/// Preload manager with priority queue and concurrency control.
pub struct PreloadManager {
    /// Priority queue for pending tasks
    queue: Arc<Mutex<BinaryHeap<PreloadTask>>>,
    /// Concurrency limit
    semaphore: Arc<Semaphore>,
    /// Maximum concurrent preloads
    max_concurrent: usize,
}

impl PreloadManager {
    /// Create a new preload manager.
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            queue: Arc::new(Mutex::new(BinaryHeap::new())),
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            max_concurrent,
        }
    }

    /// Create a preload manager with default settings (3 concurrent).
    pub fn default_manager() -> Self {
        Self::new(3)
    }

    /// Add a task to the preload queue.
    pub async fn add_task(&self, task: PreloadTask) {
        let mut queue = self.queue.lock().await;
        queue.push(task);
    }

    /// Get the next task to execute (highest priority).
    pub async fn next_task(&self) -> Option<PreloadTask> {
        let mut queue = self.queue.lock().await;
        queue.pop()
    }

    /// Check if there are pending tasks.
    pub async fn has_tasks(&self) -> bool {
        let queue = self.queue.lock().await;
        !queue.is_empty()
    }

    /// Get the number of pending tasks.
    pub async fn pending_count(&self) -> usize {
        let queue = self.queue.lock().await;
        queue.len()
    }

    /// Clear all pending tasks.
    pub async fn clear(&self) {
        let mut queue = self.queue.lock().await;
        queue.clear();
    }

    /// Try to acquire a permit for concurrent execution.
    pub async fn acquire_permit(&self) -> bool {
        self.semaphore.try_acquire().is_ok()
    }

    /// Get maximum concurrent limit.
    pub fn max_concurrent(&self) -> usize {
        self.max_concurrent
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_preload_strategy() {
        let strategy = DefaultPreloadStrategy::default();
        let chapters = strategy.calculate_preload_chapters(5, 10);

        // Should include: current(5), next(6), prev(4), ahead(7), behind(3)
        assert!(chapters.iter().any(|&(idx, _)| idx == 5)); // Current
        assert!(chapters.iter().any(|&(idx, _)| idx == 6)); // Next
        assert!(chapters.iter().any(|&(idx, _)| idx == 4)); // Prev
        assert!(chapters.iter().any(|&(idx, _)| idx == 7)); // Ahead
        assert!(chapters.iter().any(|&(idx, _)| idx == 3)); // Behind
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

    #[tokio::test]
    async fn test_preload_manager() {
        let manager = PreloadManager::new(2);

        // Add tasks
        manager.add_task(PreloadTask {
            chapter_index: 0,
            priority: PreloadPriority::Critical,
            book_id: "book1".to_string(),
        }).await;
        manager.add_task(PreloadTask {
            chapter_index: 1,
            priority: PreloadPriority::High,
            book_id: "book1".to_string(),
        }).await;

        assert_eq!(manager.pending_count().await, 2);
        assert!(manager.has_tasks().await);

        // Get next task (should be Critical)
        let task = manager.next_task().await.unwrap();
        assert_eq!(task.priority, PreloadPriority::Critical);
        assert_eq!(task.chapter_index, 0);

        // Get next task (should be High)
        let task = manager.next_task().await.unwrap();
        assert_eq!(task.priority, PreloadPriority::High);
        assert_eq!(task.chapter_index, 1);

        // Queue should be empty
        assert!(!manager.has_tasks().await);
    }

    #[tokio::test]
    async fn test_preload_manager_clear() {
        let manager = PreloadManager::default_manager();

        manager.add_task(PreloadTask {
            chapter_index: 0,
            priority: PreloadPriority::Critical,
            book_id: "book1".to_string(),
        }).await;
        manager.add_task(PreloadTask {
            chapter_index: 1,
            priority: PreloadPriority::High,
            book_id: "book1".to_string(),
        }).await;

        assert_eq!(manager.pending_count().await, 2);

        manager.clear().await;
        assert_eq!(manager.pending_count().await, 0);
        assert!(!manager.has_tasks().await);
    }
}
