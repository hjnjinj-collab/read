//! JS Runtime Pool - 仅在 js-engine feature 启用时编译
//!
//! 池化收益来自 [`crate::processing::js_runtime::JsRuntime`] 持久化的
//! QuickJS 实例（构造一次 ~10–20ms，复用时 <0.1ms）。
//! 同一实例的并发访问由内部互斥保证串行；执行超时由引擎中断句柄生效。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Result;

use super::js_runtime::{JsExecContext, JsRuntime};

/// 进程级共享 JS 运行时池（阅读级预处理等所有调用方共用）。
///
/// 容量 4：热路径为逐章串行处理；预加载并行时也极少超过 4 并发。
pub fn global_pool() -> Arc<JsRuntimePool> {
    static POOL: OnceLock<Arc<JsRuntimePool>> = OnceLock::new();
    POOL.get_or_init(|| Arc::new(JsRuntimePool::new(4))).clone()
}

/// Pool statistics.
#[derive(Debug, Clone, Default)]
pub struct PoolStats {
    pub total_acquisitions: usize,
    pub total_releases: usize,
    pub cache_hits: usize,
    pub cache_misses: usize,
    pub max_wait_time_ms: u64,
}

/// Pool status snapshot.
#[derive(Debug, Clone)]
pub struct PoolStatus {
    pub available: usize,
    pub created: usize,
    pub max_size: usize,
}

/// JS runtime pool for reusing runtime instances.
pub struct JsRuntimePool {
    pool: Arc<Mutex<VecDeque<Arc<Mutex<JsRuntime>>>>>,
    max_size: usize,
    created: AtomicUsize,
    stats: Arc<Mutex<PoolStats>>,
}

impl JsRuntimePool {
    /// Create a new runtime pool with the given max size.
    pub fn new(max_size: usize) -> Self {
        Self {
            pool: Arc::new(Mutex::new(VecDeque::new())),
            max_size,
            created: AtomicUsize::new(0),
            stats: Arc::new(Mutex::new(PoolStats::default())),
        }
    }

    /// Acquire a runtime from the pool. Waits if pool is exhausted.
    ///
    /// 等待使用异步 sleep（不阻塞执行器线程）；返回的守卫 drop 时归还实例。
    pub async fn acquire(&self) -> Result<PooledRuntime> {
        let start = Instant::now();

        {
            let mut stats = self.stats.lock().unwrap();
            stats.total_acquisitions += 1;
        }

        // 1. Try to get from pool (cache hit)
        {
            let mut pool = self.pool.lock().unwrap();
            if let Some(runtime) = pool.pop_front() {
                {
                    let mut stats = self.stats.lock().unwrap();
                    stats.cache_hits += 1;
                }
                runtime.lock().unwrap().reset()?;
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: Arc::clone(&self.pool),
                    stats: Arc::clone(&self.stats),
                });
            }
        }

        // 2. Try to create new (cache miss)
        let created_count = self.created.load(Ordering::SeqCst);
        if created_count < self.max_size {
            let prev = self.created.fetch_add(1, Ordering::SeqCst);
            if prev < self.max_size {
                let runtime = Arc::new(Mutex::new(JsRuntime::new()?));
                {
                    let mut stats = self.stats.lock().unwrap();
                    stats.cache_misses += 1;
                }
                log::info!("Created new JS runtime #{}", prev);
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: Arc::clone(&self.pool),
                    stats: Arc::clone(&self.stats),
                });
            } else {
                self.created.fetch_sub(1, Ordering::SeqCst);
            }
        }

        // 3. Pool exhausted, wait for available runtime
        log::warn!("JS runtime pool exhausted, waiting...");
        loop {
            tokio::time::sleep(Duration::from_millis(10)).await;

            let mut pool = self.pool.lock().unwrap();
            if let Some(runtime) = pool.pop_front() {
                let wait_time = start.elapsed();
                {
                    let mut stats = self.stats.lock().unwrap();
                    stats.max_wait_time_ms = stats
                        .max_wait_time_ms
                        .max(wait_time.as_millis() as u64);
                    stats.cache_hits += 1;
                }
                if wait_time > Duration::from_millis(100) {
                    log::warn!("Waited {}ms for JS runtime", wait_time.as_millis());
                }
                runtime.lock().unwrap().reset()?;
                return Ok(PooledRuntime {
                    runtime: Some(runtime),
                    pool: Arc::clone(&self.pool),
                    stats: Arc::clone(&self.stats),
                });
            }

            if start.elapsed() > Duration::from_secs(5) {
                return Err(anyhow::anyhow!("Timeout waiting for JS runtime"));
            }
        }
    }

    /// Get pool statistics.
    pub fn get_stats_sync(&self) -> PoolStats {
        self.stats.lock().unwrap().clone()
    }

    /// Get pool statistics.
    pub async fn get_stats(&self) -> PoolStats {
        self.get_stats_sync()
    }

    /// Get pool status.
    pub async fn status(&self) -> PoolStatus {
        let pool = self.pool.lock().unwrap();
        PoolStatus {
            available: pool.len(),
            created: self.created.load(Ordering::SeqCst),
            max_size: self.max_size,
        }
    }
}

/// A pooled runtime that automatically returns to the pool on drop.
pub struct PooledRuntime {
    runtime: Option<Arc<Mutex<JsRuntime>>>,
    pool: Arc<Mutex<VecDeque<Arc<Mutex<JsRuntime>>>>>,
    stats: Arc<Mutex<PoolStats>>,
}

impl PooledRuntime {
    /// Execute JS code synchronously on the current thread.
    ///
    /// 调用方必须处于阻塞友好上下文（spawn_blocking / 池工作线程）；
    /// 脚本级超时由引擎中断句柄在 `timeout_ms` 内强制生效。
    pub fn execute(
        &mut self,
        code: &str,
        ctx: &JsExecContext,
        timeout_ms: u64,
    ) -> Result<String> {
        self.runtime
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Runtime already released"))?
            .lock()
            .unwrap()
            .execute_sync_with_timeout(code, ctx, timeout_ms)
    }

    /// Execute JS code off the async worker thread（带外层兜底超时）。
    ///
    /// 内层保护是引擎中断（精确到脚本），外层 timeout 防御极端情况
    /// （如互斥等待异常）。两者先到者生效。
    pub async fn execute_async(
        &mut self,
        code: &str,
        ctx: &JsExecContext,
        timeout_ms: u64,
    ) -> Result<String> {
        let runtime = self
            .runtime
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("Runtime already released"))?
            .clone();
        let code = code.to_string();
        let ctx = ctx.clone();
        let task = tokio::task::spawn_blocking(move || {
            runtime.lock().unwrap().execute_sync_with_timeout(&code, &ctx, timeout_ms)
        });
        match tokio::time::timeout(Duration::from_millis(timeout_ms.saturating_add(200)), task)
            .await
        {
            Ok(Ok(result)) => result,
            Ok(Err(e)) => Err(anyhow::anyhow!("JS execution task failed: {}", e)),
            Err(_) => Err(anyhow::anyhow!(
                "JS execution timed out after {}ms",
                timeout_ms
            )),
        }
    }

    /// Get runtime stats.
    pub fn runtime_stats(&self) -> Option<super::js_runtime::JsRuntimeStats> {
        self.runtime
            .as_ref()
            .map(|r| r.lock().unwrap().stats())
    }
}

impl Drop for PooledRuntime {
    fn drop(&mut self) {
        // 同步归还：deque/stats 是 std Mutex（临界区极短），
        // 无需 tokio::spawn 异步化
        if let Some(runtime) = self.runtime.take() {
            if let Ok(mut pool) = self.pool.lock() {
                pool.push_back(runtime);
            }
            if let Ok(mut s) = self.stats.lock() {
                s.total_releases += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_pool_acquire_and_release() {
        let pool = JsRuntimePool::new(2);
        {
            let rt = pool.acquire().await.unwrap();
            let status = pool.status().await;
            assert_eq!(status.created, 1);
            assert_eq!(status.available, 0);
            drop(rt);
        }
        // Give async drop time to return runtime
        tokio::time::sleep(Duration::from_millis(50)).await;
        let status = pool.status().await;
        assert_eq!(status.available, 1);
    }

    #[tokio::test]
    async fn test_pool_reuse() {
        let pool = JsRuntimePool::new(2);

        let rt1 = pool.acquire().await.unwrap();
        let stats1 = pool.get_stats().await;
        assert_eq!(stats1.cache_misses, 1);
        drop(rt1);

        tokio::time::sleep(Duration::from_millis(50)).await;

        let rt2 = pool.acquire().await.unwrap();
        let stats2 = pool.get_stats().await;
        assert_eq!(stats2.cache_hits, 1);
        drop(rt2);
    }

    #[tokio::test]
    async fn test_pool_execute() {
        let pool = JsRuntimePool::new(1);
        let mut rt = pool.acquire().await.unwrap();
        let ctx = JsExecContext::default();
        let result = rt.execute("1 + 2", &ctx, 1000).unwrap();
        assert_eq!(result, "3");
    }

    #[tokio::test]
    async fn test_pool_max_size() {
        let pool = JsRuntimePool::new(1);
        let rt1 = pool.acquire().await.unwrap();
        let status = pool.status().await;
        assert_eq!(status.created, 1);
        assert_eq!(status.max_size, 1);
        drop(rt1);
    }

    #[tokio::test]
    async fn test_persistent_instance_reuse() {
        // 池化核心价值断言：第二次执行不得新建 QuickJS 引擎（created 恒为 1）
        let pool = JsRuntimePool::new(1);
        let ctx = JsExecContext::default();

        let mut rt = pool.acquire().await.unwrap();
        assert_eq!(rt.execute("1+1", &ctx, 1000).unwrap(), "2");
        drop(rt);
        tokio::time::sleep(Duration::from_millis(50)).await;

        let mut rt = pool.acquire().await.unwrap();
        let status = pool.status().await;
        assert_eq!(status.created, 1, "复用时不得新建引擎实例");
        assert_eq!(rt.execute("2+2", &ctx, 1000).unwrap(), "4");
        let stats = pool.get_stats().await;
        assert_eq!(stats.cache_hits, 1);
    }
}
