use crate::font_manager::GlyphMetrics;
use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

/// 字形缓存键
#[derive(Hash, Eq, PartialEq, Clone, Debug)]
pub struct GlyphKey {
    pub ch: char,
    pub font_size_int: u32,  // 字号取整避免浮点数哈希问题
    pub font_name: String,
}

/// 线程安全的 LRU 字形缓存
#[derive(Clone)]
pub struct GlyphCache {
    cache: Arc<Mutex<LruCache<GlyphKey, GlyphMetrics>>>,
    hits: Arc<Mutex<u64>>,
    misses: Arc<Mutex<u64>>,
}

impl GlyphCache {
    /// 创建缓存，容量为 10000 个字形
    pub fn new() -> Self {
        let capacity = NonZeroUsize::new(10_000).unwrap();
        Self {
            cache: Arc::new(Mutex::new(LruCache::new(capacity))),
            hits: Arc::new(Mutex::new(0)),
            misses: Arc::new(Mutex::new(0)),
        }
    }
    
    /// 创建指定容量的缓存
    pub fn with_capacity(capacity: usize) -> Self {
        let capacity = NonZeroUsize::new(capacity).unwrap();
        Self {
            cache: Arc::new(Mutex::new(LruCache::new(capacity))),
            hits: Arc::new(Mutex::new(0)),
            misses: Arc::new(Mutex::new(0)),
        }
    }
    
    /// 获取字形度量（带缓存）
    pub fn get(&self, key: &GlyphKey) -> Option<GlyphMetrics> {
        let mut cache = self.cache.lock().unwrap();
        let result = cache.get(key).copied();
        
        // 更新统计
        if result.is_some() {
            let mut hits = self.hits.lock().unwrap();
            *hits += 1;
        } else {
            let mut misses = self.misses.lock().unwrap();
            *misses += 1;
        }
        
        result
    }
    
    /// 放入缓存
    pub fn put(&self, key: GlyphKey, metrics: GlyphMetrics) {
        let mut cache = self.cache.lock().unwrap();
        cache.put(key, metrics);
    }
    
    /// 获取缓存统计
    pub fn stats(&self) -> CacheStats {
        let cache = self.cache.lock().unwrap();
        let hits = *self.hits.lock().unwrap();
        let misses = *self.misses.lock().unwrap();
        
        let total = hits + misses;
        let hit_rate = if total > 0 {
            (hits as f64 / total as f64) * 100.0
        } else {
            0.0
        };
        
        CacheStats {
            len: cache.len(),
            cap: cache.cap().get(),
            hits,
            misses,
            hit_rate,
        }
    }
    
    /// 清空缓存
    pub fn clear(&self) {
        let mut cache = self.cache.lock().unwrap();
        cache.clear();
        
        let mut hits = self.hits.lock().unwrap();
        *hits = 0;
        
        let mut misses = self.misses.lock().unwrap();
        *misses = 0;
    }
}

impl Default for GlyphCache {
    fn default() -> Self {
        Self::new()
    }
}

/// 缓存统计信息
#[derive(Debug, Clone)]
pub struct CacheStats {
    pub len: usize,      // 当前缓存数量
    pub cap: usize,      // 缓存容量
    pub hits: u64,       // 命中次数
    pub misses: u64,     // 未命中次数
    pub hit_rate: f64,   // 命中率（百分比）
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_glyph_cache() {
        let cache = GlyphCache::with_capacity(3);
        
        let key1 = GlyphKey {
            ch: 'A',
            font_size_int: 16,
            font_name: "Arial".to_string(),
        };
        
        let metrics = GlyphMetrics {
            width: 10.0,
            height: 16.0,
            baseline_offset: -4.0,
        };
        
        // 测试 put/get
        cache.put(key1.clone(), metrics);
        let result = cache.get(&key1);
        assert!(result.is_some());
        assert_eq!(result.unwrap().width, 10.0);
        
        // 测试统计
        let stats = cache.stats();
        assert_eq!(stats.len, 1);
        assert_eq!(stats.cap, 3);
        assert_eq!(stats.hits, 1);
        assert_eq!(stats.misses, 0);
        assert_eq!(stats.hit_rate, 100.0);
    }
    
    #[test]
    fn test_cache_hit_rate() {
        let cache = GlyphCache::with_capacity(100);
        
        // 添加一些项
        for i in 0..10 {
            let key = GlyphKey {
                ch: std::char::from_u32('A' as u32 + i).unwrap(),
                font_size_int: 16,
                font_name: "Test".to_string(),
            };
            let metrics = GlyphMetrics {
                width: 10.0 + i as f32,
                height: 16.0,
                baseline_offset: -4.0,
            };
            cache.put(key, metrics);
        }
        
        // 访问已存在的项（命中）
        for i in 0..10 {
            let key = GlyphKey {
                ch: std::char::from_u32('A' as u32 + i).unwrap(),
                font_size_int: 16,
                font_name: "Test".to_string(),
            };
            cache.get(&key);
        }
        
        // 访问不存在的项（未命中）
        for i in 10..15 {
            let key = GlyphKey {
                ch: std::char::from_u32('A' as u32 + i).unwrap(),
                font_size_int: 16,
                font_name: "Test".to_string(),
            };
            cache.get(&key);
        }
        
        let stats = cache.stats();
        println!("缓存统计: {:?}", stats);
        
        assert_eq!(stats.hits, 10);
        assert_eq!(stats.misses, 5);
        assert!((stats.hit_rate - 66.67).abs() < 0.1);
    }
    
    #[test]
    fn test_lru_eviction() {
        let cache = GlyphCache::with_capacity(3);
        
        // 添加 3 个项（填满缓存）
        for i in 0..3 {
            let key = GlyphKey {
                ch: std::char::from_u32('A' as u32 + i).unwrap(),
                font_size_int: 16,
                font_name: "Test".to_string(),
            };
            cache.put(key, GlyphMetrics {
                width: 10.0,
                height: 16.0,
                baseline_offset: -4.0,
            });
        }
        
        let stats = cache.stats();
        assert_eq!(stats.len, 3);
        
        // 添加第 4 个项，应该驱逐最旧的
        let key4 = GlyphKey {
            ch: 'D',
            font_size_int: 16,
            font_name: "Test".to_string(),
        };
        cache.put(key4, GlyphMetrics {
            width: 10.0,
            height: 16.0,
            baseline_offset: -4.0,
        });
        
        let stats = cache.stats();
        assert_eq!(stats.len, 3); // 容量仍为 3
        
        // 最早的 'A' 应该被驱逐
        let key_a = GlyphKey {
            ch: 'A',
            font_size_int: 16,
            font_name: "Test".to_string(),
        };
        assert!(cache.get(&key_a).is_none());
    }
}
