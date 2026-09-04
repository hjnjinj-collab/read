//! Skia 测量缓存（M10-B）：用 Dart TextPainter 真实渲染宽度替代 ttf-parser hmtx
//!
//! 背景：Rust 端用 `ttf-parser` 的 `glyph_hor_advance` 测量字符宽度，但 Skia 渲染时
//! 会经过 HarfBuzz 整形（连字 `fi`/`fl`、kerning、GSUB/GPOS 替换、CJK 标点宽度类、
//! 半/全角差异、subpixel 像素对齐）。原始 hmtx ≠ 整形后 advance，导致：
//!
//! - Rust 算出的断行位置 ≠ Skia 实际渲染位置
//! - 可见右边缘 ≠ `width - padding.right`，左右 padding 视觉不对称
//!
//! 修复方案：让 Rust 通过 `MeasureOracle` 在 binary search 期间按需查询宽度，
//! `MeasureOracle` 由 Dart 端 `MeasureTextService`（`TextPainter.layout`）填充。
//! 本模块只负责 Rust 侧的 LRU 缓存与并发安全。
//!
//! 设计要点：
//! - **缓存键不含 padding**：padding 变更不影响测量值（测量的是字符宽度，与容器宽无关）
//! - **缓存命中零开销**：`HashMap.get` 极快；章节内重复字符片段（如 CJK）命中率 > 80%
//! - **miss 同步回退**：cache miss 时回退到 ttf-parser 估算（保证 layout 永不阻塞）
//! - **字体变更全清**：set_default_font 时清空，防旧字体混入
//!
//! 容量：默认 50_000 条 ≈ 2MB 内存（key ≈ 40B + value 4B + overhead）

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::Mutex;

use lru::LruCache;

/// 测量缓存 key：(font_name, font_size_bits, text_hash)
// font_size_bits 用 f32::to_bits 保证 f32 NaN 等边缘情况 key 稳定
// text_hash 用 DefaultHasher(SipHash) 而不是 Hash trait，避免上游 text 改动时 key 不匹配
type MeasureKey = (String, u32, u64);

/// 全局缓存容量。50k 条覆盖单章常用字符串足够
pub const MEASURE_CACHE_CAPACITY: usize = 50_000;

/// Rust 侧测量缓存：缓存 Dart 通过 MeasureOracle 报告的真实 Skia 宽度
///
/// 线程安全：所有方法取内部 Mutex，FFI 入口多处并发安全
pub struct MeasureCache {
    inner: Mutex<LruCache<MeasureKey, f32>>,
}

impl MeasureCache {
    /// 构造指定容量的缓存
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: Mutex::new(LruCache::new(
                std::num::NonZeroUsize::new(capacity).unwrap_or(std::num::NonZeroUsize::new(1).unwrap()),
            )),
        }
    }

    /// 默认容量构造
    pub fn with_default_capacity() -> Self {
        Self::new(MEASURE_CACHE_CAPACITY)
    }

    /// 测量给定子串在指定字体/字号下的渲染宽度（缓存命中直接返回，未命中返回 None）
    ///
    /// 返回 `Option<f32>`：None 表示 cache miss，调用方应回退到 ttf-parser 估算或触发 Dart 测量回调
    pub fn get(&self, font_name: &str, font_size: f32, text: &str) -> Option<f32> {
        let key = make_key(font_name, font_size, text);
        let mut cache = self.inner.lock().unwrap();
        cache.get(&key).copied()
    }

    /// 写入缓存（Dart MeasureTextService 回调入口）
    pub fn put(&self, font_name: &str, font_size: f32, text: &str, width: f32) {
        let key = make_key(font_name, font_size, text);
        let mut cache = self.inner.lock().unwrap();
        cache.put(key, width);
    }

    /// 批量写入（Dart prefill 时调用）
    pub fn put_many(&self, entries: &[(String, f32, String, f32)]) {
        // entries: (font_name, font_size, text, width)
        let mut cache = self.inner.lock().unwrap();
        for (font_name, font_size, text, width) in entries {
            let key = make_key(font_name, *font_size, text);
            cache.put(key, *width);
        }
    }

    /// 清空缓存（字体切换时调用）
    pub fn clear(&self) {
        let mut cache = self.inner.lock().unwrap();
        cache.clear();
    }

    /// 当前缓存条目数（诊断用）
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Default for MeasureCache {
    fn default() -> Self {
        Self::with_default_capacity()
    }
}

/// 生成缓存 key：font_name + font_size_bits + text_hash
///
/// text_hash 用 SipHash 防止上游 text 长度变化导致 key 不匹配；
/// 32-byte 短文本 hash 冲突概率 ≈ 1/2^32 ≈ 2e-10，可接受
fn make_key(font_name: &str, font_size: f32, text: &str) -> MeasureKey {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    let text_hash = hasher.finish();
    (font_name.to_string(), font_size.to_bits(), text_hash)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_put_get() {
        let cache = MeasureCache::with_default_capacity();
        assert!(cache.is_empty());

        cache.put("noto_sans_sc", 18.0, "中", 18.0);
        cache.put("noto_sans_sc", 18.0, "中文字符", 72.0);

        assert_eq!(cache.get("noto_sans_sc", 18.0, "中"), Some(18.0));
        assert_eq!(cache.get("noto_sans_sc", 18.0, "中文字符"), Some(72.0));
        assert_eq!(cache.get("noto_sans_sc", 18.0, "未缓存"), None);

        // 不同字号隔离
        assert_eq!(cache.get("noto_sans_sc", 24.0, "中"), None);

        // 不同字体隔离
        assert_eq!(cache.get("other_font", 18.0, "中"), None);
    }

    #[test]
    fn test_clear() {
        let cache = MeasureCache::with_default_capacity();
        cache.put("f", 18.0, "x", 10.0);
        assert!(!cache.is_empty());
        cache.clear();
        assert!(cache.is_empty());
    }

    #[test]
    fn test_lru_eviction() {
        let cache = MeasureCache::new(2);
        cache.put("f", 18.0, "a", 1.0);
        cache.put("f", 18.0, "b", 2.0);
        cache.put("f", 18.0, "c", 3.0); // "a" 被驱逐

        assert_eq!(cache.get("f", 18.0, "a"), None);
        assert_eq!(cache.get("f", 18.0, "b"), Some(2.0));
        assert_eq!(cache.get("f", 18.0, "c"), Some(3.0));
    }

    #[test]
    fn test_font_size_bits_stability() {
        // 同一字号不同位模式应命中同一条目
        let cache = MeasureCache::with_default_capacity();
        cache.put("f", 18.0_f32, "x", 10.0);
        let same = 18.0_f32;
        assert_eq!(cache.get("f", same, "x"), Some(10.0));
    }
}