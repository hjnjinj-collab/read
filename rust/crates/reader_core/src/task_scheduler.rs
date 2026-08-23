use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use tokio::task::JoinHandle;

type BoxFuture = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

/// Shared state for a chapter's task slot.
struct TaskSlot {
    running: bool,
    pending: Option<BoxFuture>,
    handle: Option<JoinHandle<()>>,
    cancel_flag: Arc<AtomicBool>,
}

/// Inner state behind the Arc.
struct SchedulerInner {
    slots: Mutex<HashMap<usize, TaskSlot>>,
}

/// Chapter task scheduler: manages per-chapter task queues.
///
/// Design principles (from Legado's LatestChapterTaskScheduler):
/// - Each chapter index has its own task slot
/// - When a new task arrives for a chapter with a running task,
///   the old pending task is cancelled and replaced
/// - When a running task completes, the pending task (if any) starts automatically
/// - Cleanup: entries are removed when both running and pending are None
pub struct ChapterTaskScheduler {
    inner: Arc<SchedulerInner>,
}

impl ChapterTaskScheduler {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(SchedulerInner {
                slots: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// Submit a task for a specific chapter.
    pub fn submit<F>(&self, chapter_index: usize, task: F)
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let mut slots = self.inner.slots.lock().unwrap();
        let slot = slots.entry(chapter_index).or_insert_with(|| TaskSlot {
            running: false,
            pending: None,
            handle: None,
            cancel_flag: Arc::new(AtomicBool::new(false)),
        });

        if !slot.running {
            let cancel_flag = slot.cancel_flag.clone();
            let inner = self.inner.clone();
            let chapter = chapter_index;

            let handle = tokio::spawn(async move {
                tokio::select! {
                    _ = task => {}
                    _ = check_cancel(cancel_flag) => {}
                }
                on_task_finished(inner, chapter);
            });

            slot.running = true;
            slot.handle = Some(handle);
        } else {
            slot.pending = Some(Box::pin(task));
        }
    }

    /// Cancel all tasks for a specific chapter.
    pub fn cancel(&self, chapter_index: usize) {
        let mut slots = self.inner.slots.lock().unwrap();
        if let Some(slot) = slots.remove(&chapter_index) {
            slot.cancel_flag.store(true, Ordering::SeqCst);
            if let Some(handle) = slot.handle {
                handle.abort();
            }
        }
    }

    /// Cancel all tasks.
    pub fn cancel_all(&self) {
        let mut slots = self.inner.slots.lock().unwrap();
        for (_, slot) in slots.drain() {
            slot.cancel_flag.store(true, Ordering::SeqCst);
            if let Some(handle) = slot.handle {
                handle.abort();
            }
        }
    }

    /// Check if a chapter has any pending work.
    pub fn has_pending(&self, chapter_index: usize) -> bool {
        let slots = self.inner.slots.lock().unwrap();
        slots
            .get(&chapter_index)
            .map(|s| s.pending.is_some())
            .unwrap_or(false)
    }

    /// Check if a chapter has a running task.
    pub fn is_running(&self, chapter_index: usize) -> bool {
        let slots = self.inner.slots.lock().unwrap();
        slots
            .get(&chapter_index)
            .map(|s| s.running)
            .unwrap_or(false)
    }

    /// Get the number of active entries.
    pub fn active_count(&self) -> usize {
        let slots = self.inner.slots.lock().unwrap();
        slots.len()
    }

    /// Wait until all tasks complete.
    pub async fn wait_all(&self) {
        loop {
            {
                let slots = self.inner.slots.lock().unwrap();
                if slots.is_empty() {
                    return;
                }
            }
            tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
        }
    }
}

impl Default for ChapterTaskScheduler {
    fn default() -> Self {
        Self::new()
    }
}

/// Called when a running task finishes. Starts pending task or cleans up.
fn on_task_finished(inner: Arc<SchedulerInner>, chapter_index: usize) {
    let pending_info = {
        let mut slots = inner.slots.lock().unwrap();
        let slot = match slots.get_mut(&chapter_index) {
            Some(s) => s,
            None => return,
        };

        slot.running = false;
        slot.handle = None;

        if let Some(pending) = slot.pending.take() {
            let cancel_flag = slot.cancel_flag.clone();
            cancel_flag.store(false, Ordering::SeqCst);
            Some((pending, cancel_flag))
        } else {
            slots.remove(&chapter_index);
            None
        }
    };

    if let Some((pending, cancel_flag)) = pending_info {
        let inner_ref = inner.clone();
        let handle = tokio::spawn(async move {
            tokio::select! {
                _ = pending => {}
                _ = check_cancel(cancel_flag) => {}
            }
            on_task_finished(inner_ref, chapter_index);
        });

        let mut slots = inner.slots.lock().unwrap();
        if let Some(s) = slots.get_mut(&chapter_index) {
            s.running = true;
            s.handle = Some(handle);
        }
    }
}

/// Helper future that resolves when the cancel flag is set.
async fn check_cancel(flag: Arc<AtomicBool>) {
    loop {
        if flag.load(Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(tokio::time::Duration::from_millis(5)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    #[tokio::test]
    async fn test_basic_submit_and_complete() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));
        let c = counter.clone();

        scheduler.submit(0, async move {
            c.fetch_add(1, Ordering::SeqCst);
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(counter.load(Ordering::SeqCst), 1);
        assert_eq!(scheduler.active_count(), 0);
    }

    #[tokio::test]
    async fn test_replaces_pending_task() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));

        let c1 = counter.clone();
        scheduler.submit(0, async move {
            tokio::time::sleep(Duration::from_secs(10)).await;
            c1.fetch_add(1, Ordering::SeqCst);
        });

        let c2 = counter.clone();
        scheduler.submit(0, async move {
            c2.fetch_add(10, Ordering::SeqCst);
        });

        let c3 = counter.clone();
        scheduler.submit(0, async move {
            c3.fetch_add(100, Ordering::SeqCst);
        });

        assert!(scheduler.is_running(0));
        assert!(scheduler.has_pending(0));

        scheduler.cancel(0);
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    #[tokio::test]
    async fn test_cancel_stops_running() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));
        let c = counter.clone();

        scheduler.submit(0, async move {
            tokio::time::sleep(Duration::from_secs(10)).await;
            c.fetch_add(1, Ordering::SeqCst);
        });

        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(scheduler.is_running(0));

        scheduler.cancel(0);
        tokio::time::sleep(Duration::from_millis(10)).await;

        assert_eq!(counter.load(Ordering::SeqCst), 0);
        assert_eq!(scheduler.active_count(), 0);
    }

    #[tokio::test]
    async fn test_different_chapters_independent() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));

        let c0 = counter.clone();
        scheduler.submit(0, async move {
            tokio::time::sleep(Duration::from_secs(10)).await;
            c0.fetch_add(1, Ordering::SeqCst);
        });

        let c1 = counter.clone();
        scheduler.submit(1, async move {
            c1.fetch_add(10, Ordering::SeqCst);
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(counter.load(Ordering::SeqCst), 10);
        assert!(scheduler.is_running(0));
        assert_eq!(scheduler.active_count(), 1);

        scheduler.cancel(0);
    }

    #[tokio::test]
    async fn test_wait_all() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));

        for i in 0..5 {
            let c = counter.clone();
            scheduler.submit(i, async move {
                tokio::time::sleep(Duration::from_millis(10)).await;
                c.fetch_add(1, Ordering::SeqCst);
            });
        }

        scheduler.wait_all().await;
        assert_eq!(counter.load(Ordering::SeqCst), 5);
    }

    #[tokio::test]
    async fn test_pending_runs_after_complete() {
        let scheduler = ChapterTaskScheduler::new();
        let counter = Arc::new(AtomicUsize::new(0));

        let c1 = counter.clone();
        scheduler.submit(0, async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            c1.fetch_add(1, Ordering::SeqCst);
        });

        let c2 = counter.clone();
        scheduler.submit(0, async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            c2.fetch_add(10, Ordering::SeqCst);
        });

        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(counter.load(Ordering::SeqCst), 11);
    }
}
