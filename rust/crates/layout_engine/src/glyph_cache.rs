use crate::font_manager::GlyphMetrics;
use lru::LruCache;
use std::num::NonZeroUsize;
use std::sync::{Arc, Mutex};

/// 字形缓存键
#[derive(Hash, Eq, PartialEq, Clone, Debug)]
pub struct GlyphKey {
    pub ch: char,
    /// 字号的 f32 位模式（to_bits）——精确区分任意浮点字号，
    /// 消除历史 as u32 截断 / round() 两种口径的碰撞串缓存
    pub font_size_bits: u32,
    pub font_name: String,
}

impl GlyphKey {
    pub fn new(ch: char, font_size: f32, font_name: &str) -> Self {
        Self {
            ch,
            font_size_bits: font_size.to_bits(),
            font_name: font_name.to_string(),
        }
    }
}

/// 缓存内部状态（M8-P4：三把锁合并为单把）
struct CacheInner {
    lru: LruCache<GlyphKey, GlyphMetrics>,
    hits: u64,
    misses: u64,
}

/// 线程安全的 LRU 字形缓存
///
/// M8-P4 优化：原先三把 `Arc<Mutex>`（lru / hits / misses）合并为
/// 单把 `Arc<Mutex<CacheInner>>`，每字符 `get()` 只需一次 Mutex 锁，
/// 消除两次锁争用和两次 Arc 引用计数。
#[derive(Clone)]
pub struct GlyphCache {
    inner: Arc<Mutex<CacheInner>>,
}

impl GlyphCache {
    /// 创建缓存，容量为 10000 个字形
    pub fn new() -> Self {
        Self::with_capacity(10_000)
    }

    /// 创建指定容量的缓存
    pub fn with_capacity(capacity: usize) -> Self {
        let capacity = NonZeroUsize::new(capacity).unwrap();
        Self {
            inner: Arc::new(Mutex::new(CacheInner {
                lru: LruCache::new(capacity),
                hits: 0,
                misses: 0,
            })),
        }
    }

    /// 获取字形度量（带缓存）
    ///
    /// M8-P4：单次锁获取，hit/miss 统计在同一临界区内更新
    pub fn get(&self, key: &GlyphKey) -> Option<GlyphMetrics> {
        let mut inner = self.inner.lock().unwrap();
        let result = inner.lru.get(key).copied();

        if result.is_some() {
            inner.hits += 1;
        } else {
            inner.misses += 1;
        }

        result
    }

    /// 放入缓存
    pub fn put(&self, key: GlyphKey, metrics: GlyphMetrics) {
        let mut inner = self.inner.lock().unwrap();
        inner.lru.put(key, metrics);
    }

    /// 获取缓存统计
    pub fn stats(&self) -> CacheStats {
        let inner = self.inner.lock().unwrap();
        let hits = inner.hits;
        let misses = inner.misses;

        let total = hits + misses;
        let hit_rate = if total > 0 {
            (hits as f64 / total as f64) * 100.0
        } else {
            0.0
        };

        CacheStats {
            len: inner.lru.len(),
            cap: inner.lru.cap().get(),
            hits,
            misses,
            hit_rate,
        }
    }

    /// 清空缓存
    pub fn clear(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.lru.clear();
        inner.hits = 0;
        inner.misses = 0;
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

    /// M7-P0：浮点字号按 f32 bits 精确入键——18.36 与 18.0 不串缓存
    /// （历史 as u32 截断/round() 两口径在此碰撞）
    #[test]
    fn test_font_size_bits_no_collision() {
        let cache = GlyphCache::with_capacity(10);

        let key_a = GlyphKey::new('国', 18.0, "Test");
        let key_b = GlyphKey::new('国', 18.36, "Test");
        assert_ne!(key_a.font_size_bits, key_b.font_size_bits);

        cache.put(
            key_a.clone(),
            GlyphMetrics { width: 18.0, height: 18.0, baseline_offset: -4.0 },
        );
        assert_eq!(cache.get(&key_a).unwrap().width, 18.0);
        assert!(cache.get(&key_b).is_none(), "缩放字号不得命中基准槽位");

        cache.put(
            key_b.clone(),
            GlyphMetrics { width: 18.36, height: 18.36, baseline_offset: -4.0 },
        );
        assert_eq!(cache.get(&key_b).unwrap().width, 18.36);
        assert_eq!(cache.get(&key_a).unwrap().width, 18.0);
    }

    #[test]
    fn test_glyph_cache() {
        let cache = GlyphCache::with_capacity(3);
        
        let key1 = GlyphKey {
            ch: 'A',
            font_size_bits: 16.0f32.to_bits(),
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
                font_size_bits: 16.0f32.to_bits(),
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
                font_size_bits: 16.0f32.to_bits(),
                font_name: "Test".to_string(),
            };
            cache.get(&key);
        }
        
        // 访问不存在的项（未命中）
        for i in 10..15 {
            let key = GlyphKey {
                ch: std::char::from_u32('A' as u32 + i).unwrap(),
                font_size_bits: 16.0f32.to_bits(),
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
                font_size_bits: 16.0f32.to_bits(),
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
            font_size_bits: 16.0f32.to_bits(),
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
            font_size_bits: 16.0f32.to_bits(),
            font_name: "Test".to_string(),
        };
        assert!(cache.get(&key_a).is_none());
    }
}
