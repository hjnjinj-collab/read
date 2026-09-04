use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::time::{Duration, Instant};
use lru::LruCache;
use std::num::NonZeroUsize;

/// 分页缓存条目的数据布局版本。变更缓存值/键的布局时递增，避免复用旧条目。
pub const CACHE_SCHEMA_REVISION: u32 = 1;
/// 排版结果版本。影响分页结果的算法或布局语义变更时递增。
pub const LAYOUT_REVISION: u32 = 1;

/// 缓存条目 TTL（辅助淘汰）。
///
/// 决策记录：LRU 容量为主淘汰，TTL 仅兜底极端陈旧条目
/// （如小书章节长期驻留后的陈旧结果）。
/// 2026-09-02 优化：300s → 900s，避免长时间静读后翻页 cache miss。
pub const ENTRY_TTL: Duration = Duration::from_secs(900);
use layout_engine::{Page, LayoutConfig};

/// 分页缓存键（唯一标识一次排版）
///
/// `options_hash` 覆盖影响页面内容文本的处理选项（去重标题/重分段/繁简/替换规则），
/// 选项变更即产生新 key，旧条目由 LRU 淘汰——保证设置变更后不返回旧内容的页。
#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub struct CacheKey {
    pub cache_schema_revision: u32,
    pub layout_revision: u32,
    pub book_id: String,
    pub chapter_index: usize,
    pub config_hash: u64,   // 排版配置的哈希值
    pub options_hash: u64,  // 内容处理选项的哈希值
}

impl CacheKey {
    /// 仅按排版配置构造（options_hash = 0），兼容旧调用
    pub fn new(book_id: &str, chapter_index: usize, config: &LayoutConfig) -> Self {
        Self::with_options(book_id, chapter_index, config, 0)
    }

    /// 按排版配置 + 内容处理选项构造
    pub fn with_options(
        book_id: &str,
        chapter_index: usize,
        config: &LayoutConfig,
        options_hash: u64,
    ) -> Self {
        let mut hasher = DefaultHasher::new();
        config.width.to_bits().hash(&mut hasher);
        config.height.to_bits().hash(&mut hasher);
        config.font_size.to_bits().hash(&mut hasher);
        config.line_height_multiplier.to_bits().hash(&mut hasher);
        config.font_name.hash(&mut hasher);
        config.padding.left.to_bits().hash(&mut hasher);
        config.padding.top.to_bits().hash(&mut hasher);
        config.padding.right.to_bits().hash(&mut hasher);
        config.padding.bottom.to_bits().hash(&mut hasher);
        config.letter_spacing.to_bits().hash(&mut hasher);
        config.paragraph_spacing.to_bits().hash(&mut hasher);
        config.page_fill_threshold.to_bits().hash(&mut hasher);

        Self {
            cache_schema_revision: CACHE_SCHEMA_REVISION,
            layout_revision: LAYOUT_REVISION,
            book_id: book_id.to_string(),
            chapter_index,
            config_hash: hasher.finish(),
            options_hash,
        }
    }

    /// 计算内容处理选项的哈希
    ///
    /// 任何影响页面文本的选项变更都必须反映在此哈希中。
    /// M9：para_format_hash 纳入哈希，段落格式化设置变更即换键。
    pub fn hash_process_options(
        remove_duplicate_title: bool,
        re_segment: bool,
        chinese_convert: u8,
        replace_rules_hash: u64,
        para_format_hash: u64,
    ) -> u64 {
        let mut hasher = DefaultHasher::new();
        remove_duplicate_title.hash(&mut hasher);
        re_segment.hash(&mut hasher);
        chinese_convert.hash(&mut hasher);
        replace_rules_hash.hash(&mut hasher);
        para_format_hash.hash(&mut hasher);
        hasher.finish()
    }

    /// 计算替换规则列表的哈希（pattern/replacement/rule_type/enabled）
    pub fn hash_replace_rules(rules: &[crate::content_preprocessor::ReplaceRule]) -> u64 {
        let mut hasher = DefaultHasher::new();
        for rule in rules {
            rule.pattern.hash(&mut hasher);
            rule.replacement.hash(&mut hasher);
            (rule.rule_type as u8).hash(&mut hasher);
            rule.enabled.hash(&mut hasher);
        }
        hasher.finish()
    }
}

/// 缓存的章节分页结果
///
/// M9.3：pages 包 Arc——命中路径 Arc bump 免整章深克隆
/// （每次翻页曾克隆整章所有页的 TextLine 字符串，对齐 EPUB 侧先例）
#[derive(Debug, Clone)]
pub struct CachedChapterPages {
    pub pages: Arc<Vec<Page>>,
    pub total_pages: usize,
    pub created_at: Instant,
}

/// 分页缓存管理器
pub struct PaginationCache {
    cache: LruCache<CacheKey, CachedChapterPages>,
    hit_count: u64,
    miss_count: u64,
}

impl PaginationCache {
    /// 创建新的缓存（默认容量：10个章节）
    pub fn new(capacity: usize) -> Self {
        Self {
            cache: LruCache::new(NonZeroUsize::new(capacity).unwrap()),
            hit_count: 0,
            miss_count: 0,
        }
    }
    
    /// 获取缓存
    ///
    /// TTL 辅助淘汰：命中但超龄 → 移除条目按 miss 处理
    /// （peek 不更新 LRU 序，避免「提升后又逐出」的空转）。
    pub fn get(&mut self, key: &CacheKey) -> Option<&CachedChapterPages> {
        if let Some(cached) = self.cache.peek(key) {
            if cached.created_at.elapsed() > ENTRY_TTL {
                self.cache.pop(key);
                self.miss_count += 1;
                return None;
            }
        }
        if let Some(cached) = self.cache.get(key) {
            self.hit_count += 1;
            Some(cached)
        } else {
            self.miss_count += 1;
            None
        }
    }
    
    /// 获取可变引用（用于修改）
    pub fn get_mut(&mut self, key: &CacheKey) -> Option<&mut CachedChapterPages> {
        if let Some(cached) = self.cache.peek(key) {
            if cached.created_at.elapsed() > ENTRY_TTL {
                self.cache.pop(key);
                self.miss_count += 1;
                return None;
            }
        }
        if self.cache.contains(key) {
            self.hit_count += 1;
            self.cache.get_mut(key)
        } else {
            self.miss_count += 1;
            None
        }
    }
    
    /// 存入缓存
    pub fn put(&mut self, key: CacheKey, value: CachedChapterPages) {
        self.cache.put(key, value);
    }
    
    /// 清除特定书籍的缓存
    pub fn clear_book(&mut self, book_id: &str) {
        // LruCache 没有 retain 方法，需要手动收集要删除的键
        let keys_to_remove: Vec<CacheKey> = self.cache.iter()
            .filter(|(k, _)| k.book_id == book_id)
            .map(|(k, _)| k.clone())
            .collect();
        
        for key in keys_to_remove {
            self.cache.pop(&key);
        }
    }
    
    /// 清除所有缓存
    pub fn clear(&mut self) {
        self.cache.clear();
        self.hit_count = 0;
        self.miss_count = 0;
    }
    
    /// 获取缓存大小
    pub fn len(&self) -> usize {
        self.cache.len()
    }
    
    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.cache.is_empty()
    }
    
    /// 获取缓存统计
    pub fn stats(&self) -> CacheStats {
        let total = self.hit_count + self.miss_count;
        CacheStats {
            hit_count: self.hit_count,
            miss_count: self.miss_count,
            hit_rate: if total > 0 {
                self.hit_count as f32 / total as f32
            } else {
                0.0
            },
            size: self.cache.len(),
            capacity: self.cache.cap().get(),
        }
    }
}

/// 缓存统计信息
#[derive(Debug, Clone)]
pub struct CacheStats {
    pub hit_count: u64,
    pub miss_count: u64,
    pub hit_rate: f32,
    pub size: usize,
    pub capacity: usize,
}

impl std::fmt::Display for CacheStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Cache Stats: hit={}, miss={}, hit_rate={:.2}%, size={}/{}",
            self.hit_count,
            self.miss_count,
            self.hit_rate * 100.0,
            self.size,
            self.capacity
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use layout_engine::EdgeInsets;

    #[test]
    fn test_cache_key_equality() {
        let config1 = LayoutConfig {
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
            font_name: "default".to_string(),
            letter_spacing: 0.0,
            paragraph_spacing: 12.0,
            page_fill_threshold: 0.9,
            show_comments: true,
            justify: false,
        };
        
        let config2 = config1.clone();
        
        let key1 = CacheKey::new("book1", 0, &config1);
        let key2 = CacheKey::new("book1", 0, &config2);
        
        assert_eq!(key1, key2);
    }

    #[test]
    fn test_cache_key_contains_current_revisions() {
        let key = CacheKey::new("book1", 0, &LayoutConfig::default());

        assert_eq!(key.cache_schema_revision, CACHE_SCHEMA_REVISION);
        assert_eq!(key.layout_revision, LAYOUT_REVISION);
    }

    #[test]
    fn test_cache_basic_operations() {
        let mut cache = PaginationCache::new(2);
        
        let config = LayoutConfig::default();
        let key = CacheKey::new("book1", 0, &config);
        
        // Miss
        assert!(cache.get(&key).is_none());
        assert_eq!(cache.stats().miss_count, 1);
        
        // Put
        cache.put(key.clone(), CachedChapterPages {
            pages: Arc::new(vec![]),
            total_pages: 0,
            created_at: Instant::now(),
        });
        
        // Hit
        assert!(cache.get(&key).is_some());
        assert_eq!(cache.stats().hit_count, 1);
    }

    #[test]
    fn test_cache_lru_eviction() {
        let mut cache = PaginationCache::new(2);
        let config = LayoutConfig::default();
        
        let key1 = CacheKey::new("book1", 0, &config);
        let key2 = CacheKey::new("book1", 1, &config);
        let key3 = CacheKey::new("book1", 2, &config);
        
        cache.put(key1.clone(), CachedChapterPages {
            pages: Arc::new(vec![]),
            total_pages: 0,
            created_at: Instant::now(),
        });
        
        cache.put(key2.clone(), CachedChapterPages {
            pages: Arc::new(vec![]),
            total_pages: 0,
            created_at: Instant::now(),
        });
        
        // Cache is full, adding key3 should evict key1
        cache.put(key3.clone(), CachedChapterPages {
            pages: Arc::new(vec![]),
            total_pages: 0,
            created_at: Instant::now(),
        });
        
        assert!(cache.get(&key1).is_none()); // Evicted
        assert!(cache.get(&key2).is_some()); // Still in cache
        assert!(cache.get(&key3).is_some()); // Just added
    }

    #[test]
    fn test_cache_ttl_expiry() {
        let mut cache = PaginationCache::new(2);
        let config = LayoutConfig::default();
        let key = CacheKey::new("book1", 0, &config);

        // 陈旧条目：created_at 在 TTL 之外
        cache.put(key.clone(), CachedChapterPages {
            pages: Arc::new(vec![]),
            total_pages: 0,
            created_at: Instant::now() - (ENTRY_TTL + Duration::from_secs(1)),
        });

        // 命中但超龄 → 按 miss 处理并移除
        assert!(cache.get(&key).is_none());
        assert_eq!(cache.stats().miss_count, 1);
        assert_eq!(cache.len(), 0);
    }
}
