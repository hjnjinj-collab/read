use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::num::NonZeroUsize;
use std::sync::Arc;

use lru::LruCache;
use tokio::sync::Mutex;

/// Cache key for preprocessed content.
#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub struct CacheKey {
    pub book_id: String,
    pub chapter_index: usize,
    pub rules_hash: u64,
}

/// Cache statistics.
#[derive(Debug, Clone, Default)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    pub evictions: u64,
    pub size: usize,
    pub capacity: usize,
}

impl CacheStats {
    /// Calculate hit rate.
    pub fn hit_rate(&self) -> f64 {
        let total = self.hits + self.misses;
        if total == 0 {
            0.0
        } else {
            self.hits as f64 / total as f64
        }
    }
}

/// LRU cache for preprocessed content.
///
/// Caches the output of Stage 1 preprocessing to avoid repeated preprocessing.
/// Capacity: 20 chapters (configurable).
pub struct PreprocessedCache {
    cache: Arc<Mutex<LruCache<CacheKey, String>>>,
    stats: Arc<Mutex<CacheStats>>,
}

impl PreprocessedCache {
    /// Create a new cache with default capacity (20 chapters).
    pub fn new() -> Self {
        Self::with_capacity(20)
    }

    /// Create a new cache with specified capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        let stats = CacheStats {
            capacity,
            ..Default::default()
        };

        Self {
            cache: Arc::new(Mutex::new(LruCache::new(
                NonZeroUsize::new(capacity).unwrap_or(NonZeroUsize::new(1).unwrap()),
            ))),
            stats: Arc::new(Mutex::new(stats)),
        }
    }

    /// Get content from cache.
    pub async fn get(&self, key: &CacheKey) -> Option<String> {
        let mut cache = self.cache.lock().await;
        let mut stats = self.stats.lock().await;

        if let Some(content) = cache.get(key) {
            stats.hits += 1;
            Some(content.clone())
        } else {
            stats.misses += 1;
            None
        }
    }

    /// Put content into cache.
    pub async fn put(&self, key: CacheKey, content: String) {
        let mut cache = self.cache.lock().await;
        let mut stats = self.stats.lock().await;

        if cache.put(key, content).is_none() {
            // New entry added
            stats.size = cache.len();
        } else {
            // Existing entry updated
            stats.size = cache.len();
        }
    }

    /// Remove content from cache.
    pub async fn remove(&self, key: &CacheKey) -> bool {
        let mut cache = self.cache.lock().await;
        let mut stats = self.stats.lock().await;

        let result = cache.pop(key).is_some();
        if result {
            stats.size = cache.len();
        }
        result
    }

    /// Clear all cached content.
    pub async fn clear(&self) {
        let mut cache = self.cache.lock().await;
        let mut stats = self.stats.lock().await;

        cache.clear();
        stats.size = 0;
    }

    /// Get cache statistics.
    pub async fn stats(&self) -> CacheStats {
        let stats = self.stats.lock().await;
        stats.clone()
    }

    /// Get current cache size.
    pub async fn len(&self) -> usize {
        let cache = self.cache.lock().await;
        cache.len()
    }

    /// Check if cache is empty.
    pub async fn is_empty(&self) -> bool {
        let cache = self.cache.lock().await;
        cache.is_empty()
    }
}

/// Calculate rules hash for cache key.
pub fn calculate_rules_hash(rules: &[(String, String)]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for (pattern, replacement) in rules {
        pattern.hash(&mut hasher);
        replacement.hash(&mut hasher);
    }
    hasher.finish()
}

/// Calculate rules hash from rule strings.
pub fn calculate_rules_hash_str(rules: &[String]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for rule in rules {
        rule.hash(&mut hasher);
    }
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_cache_basic_operations() {
        let cache = PreprocessedCache::with_capacity(2);
        let key1 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };
        let key2 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 1,
            rules_hash: 123,
        };

        // Put and get
        cache.put(key1.clone(), "content1".to_string()).await;
        assert_eq!(cache.get(&key1).await, Some("content1".to_string()));
        assert_eq!(cache.get(&key2).await, None);

        // Stats
        let stats = cache.stats().await;
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 1);
    }

    #[tokio::test]
    async fn test_cache_lru_eviction() {
        let cache = PreprocessedCache::with_capacity(2);
        let key1 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };
        let key2 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 1,
            rules_hash: 123,
        };
        let key3 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 2,
            rules_hash: 123,
        };

        // Fill cache
        cache.put(key1.clone(), "content1".to_string()).await;
        cache.put(key2.clone(), "content2".to_string()).await;

        // Access key1 to make it recently used
        cache.get(&key1).await;

        // Add key3, should evict key2
        cache.put(key3.clone(), "content3".to_string()).await;

        assert_eq!(cache.get(&key1).await, Some("content1".to_string()));
        assert_eq!(cache.get(&key2).await, None);
        assert_eq!(cache.get(&key3).await, Some("content3".to_string()));
    }

    #[tokio::test]
    async fn test_cache_remove() {
        let cache = PreprocessedCache::new();
        let key = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };

        cache.put(key.clone(), "content".to_string()).await;
        assert!(cache.remove(&key).await);
        assert_eq!(cache.get(&key).await, None);
        assert!(!cache.remove(&key).await);
    }

    #[tokio::test]
    async fn test_cache_clear() {
        let cache = PreprocessedCache::new();
        let key1 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };
        let key2 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 1,
            rules_hash: 123,
        };

        cache.put(key1, "content1".to_string()).await;
        cache.put(key2, "content2".to_string()).await;
        assert_eq!(cache.len().await, 2);

        cache.clear().await;
        assert_eq!(cache.len().await, 0);
        assert!(cache.is_empty().await);
    }

    #[tokio::test]
    async fn test_cache_stats() {
        let cache = PreprocessedCache::new();
        let key = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };

        // Initially empty
        let stats = cache.stats().await;
        assert_eq!(stats.hits, 0);
        assert_eq!(stats.misses, 0);

        // Miss
        cache.get(&key).await;
        let stats = cache.stats().await;
        assert_eq!(stats.misses, 1);

        // Put and hit
        cache.put(key.clone(), "content".to_string()).await;
        cache.get(&key).await;
        let stats = cache.stats().await;
        assert_eq!(stats.hits, 1);

        // Hit rate
        assert_eq!(stats.hit_rate(), 0.5);
    }

    #[test]
    fn test_calculate_rules_hash() {
        let rules1 = vec![
            ("pattern1".to_string(), "replacement1".to_string()),
            ("pattern2".to_string(), "replacement2".to_string()),
        ];
        let rules2 = vec![
            ("pattern1".to_string(), "replacement1".to_string()),
            ("pattern2".to_string(), "replacement2".to_string()),
        ];
        let rules3 = vec![
            ("pattern1".to_string(), "replacement1".to_string()),
            ("pattern3".to_string(), "replacement3".to_string()),
        ];

        assert_eq!(calculate_rules_hash(&rules1), calculate_rules_hash(&rules2));
        assert_ne!(calculate_rules_hash(&rules1), calculate_rules_hash(&rules3));
    }

    #[test]
    fn test_cache_key_equality() {
        let key1 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };
        let key2 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 0,
            rules_hash: 123,
        };
        let key3 = CacheKey {
            book_id: "book1".to_string(),
            chapter_index: 1,
            rules_hash: 123,
        };

        assert_eq!(key1, key2);
        assert_ne!(key1, key3);
    }
}
