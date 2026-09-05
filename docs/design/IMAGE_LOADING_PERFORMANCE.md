# 图片加载性能优化报告（A27）

> 2026-09-05 · 三阶段优化已完成并推送（f2fb58f → ce4a4c8 → 62712e0）
> 决策记录见 `docs/design/ARCHITECTURE.md` A27 条目；本文档为实施细节与调优手册。

## 1. 图片加载链路总览

```
EPUB ZIP（未解压）
  ↓
Rust EpubParser.ResourceCache（LRU 150，字节缓存）        ← A27 阶段1 扩容 50→150
  ↓
FFI get_book_resource（快路径：read 锁 peek 缓存命中直返；
  慢路径：write 锁读 ZIP + 写缓存，仅每资源首次）
  ↓
Dart BookImageStore（LRU 64 张 ui.Image 解码缓存，
  Semaphore(4) 限流，失败重试 3 次退避 500ms/2s/8s）       ← A27 阶段1 并发 2→4
  ↓
PageContentRenderer.paintPage（canvas.drawImageRect GPU 绘制
  或状态化占位框）                                          ← A27 阶段3 状态化
```

**预热触发点**（按时间序）：

| 时机 | 位置 | 范围 |
|------|------|------|
| 首屏打开书籍 | `_loadCurrentPage()` 成功后 → `_prewarmCurrentPageImages()` | 当前页（A27 阶段1 新增） |
| FrameSet 发布 | `_prepareAndPublishFrameSet` | current + prev + next（按挂起手势方向优先） |
| 翻页提交 | `_commitPageTurn` | 目标页 manifest |
| 预测预热 | `_updateTurnStatistics()`（A27 阶段2 新增） | 连续 ≥2 次同向翻页时预热"下下页" |

## 2. 三大根因量化

| 根因 | 机制 | 量化影响 |
|------|------|----------|
| 无首屏预加载 | 打开书籍只加载 PageInfo，首次绘制触发懒加载 | FFI ~10-30ms + 解码 ~50-150ms，200-500ms 延迟 |
| 并发限流过严 | Semaphore(2) 串行批次 | 10 图/页 = 5 轮批次 ≈ 500ms+ 累积延迟 |
| 预热时机滞后 | 仅 FrameSet 发布后触发 | 首屏无预热，用户先见文字再见图片 |

**已排除**：Rust IO 层不是瓶颈——`ResourceCache` + 快慢路径（peek 不阻塞分页）已完备；`EpubParser.archive` 常驻书会话，无重复开档开销（ZIP 池化前提不成立，已否决）。

## 3. 三阶段实施细节

### 阶段 1：快速见效（f2fb58f）

1. **首屏预热**：`lib/features/reader/presentation/providers/reader_provider.dart`
   - `_prewarmCurrentPageImages(page)`：`ResourceManifest.of(page).hrefs` 提取图片列表 → `BookImageStore.instance.prewarmManifest(hrefs)` 异步预热，readerTrace 记录启动/完成
   - 插入点：`_loadCurrentPage()` 成功后、`_prepareAndPublishFrameSet` 之前（当前页优先于邻居页）
   - 注意：`ReaderNotifier` 是 Riverpod `Notifier`，无 `notifyListeners()`——重绘由 `PageContentRenderer.ensureLoaded` 的 `onImageNeeded` 回调链自动驱动
2. **并发提升**：`lib/features/reader/presentation/services/book_image_store.dart`
   - `static const int _maxConcurrentDecodes = 4;` + `_decodeGate = _Semaphore(_maxConcurrentDecodes)`
3. **Rust 扩容**：`rust/crates/book_parser/src/epub_parser.rs:190`
   - `ResourceCache::new(150)`（原 50）

### 阶段 2：智能预测（ce4a4c8）

1. **方向统计 + 预测预热**：`reader_provider.dart`
   - 字段：`_lastTurnDirection` / `_consecutiveTurns` / `_lastTurnTime`（5s 窗口）
   - `nextPage()` / `previousPage()` 调 `_updateTurnStatistics(direction)`；连续 ≥2 次同向 → 预热"下下页"
2. **EPUB 分页缓存 TTL**：`rust/crates/bridge/src/api.rs`
   - `StructuredCacheEntry { pages, created_at: SystemTime }` + `is_expired(ttl_secs)`
   - `STRUCTURED_PAGINATION_CACHE` 三个访问点（读命中 / 写入 / prefetch）全部走 TTL 检查，TTL = 900s（与 TXT 对齐）；时钟回退异常视为过期

### 阶段 3：进度反馈（62712e0）

`lib/features/reader/presentation/widgets/reader_page_widget.dart`
- `_drawImagePlaceholder(canvas, rect, state, theme)`：
  - `BookImageState.loading` → 浅灰背景 + 3/4 圆弧指示器（仅占位框足够大时绘制）
  - `BookImageState.failed` → 深灰背景 + × 错误标记
  - `null`（未请求）→ 纯灰块兜底
- 替代原"无差别灰块"，用户可区分加载中/失败

## 4. 调优参数表

| 参数 | 当前值 | 位置 | 调整副作用 |
|------|--------|------|------------|
| 解码并发 | 4 | `book_image_store.dart` `_maxConcurrentDecodes` | ↑ 内存带宽/FFI 洪峰风险（M9.3 教训）；↓ 图片密集页变慢 |
| BookImageStore LRU | 64 张 | 同文件 `_maxCacheEntries` | ↑ 解码图常驻内存（每张可达数 MB）；↓ 频繁重解码 |
| ResourceCache | 150 条字节 | `epub_parser.rs:190` | ↑ 字节常驻内存（压缩态，远小于解码图）；↓ ZIP 重复读取 |
| 预测预热窗口 | 5s / ≥2 次 | `reader_provider.dart` `_updateTurnStatistics` | ↑ 误预热浪费；↓ 预测不生效 |
| EPUB TTL | 900s | `api.rs` `StructuredCacheEntry` 访问点 | ↑ 静默陈旧；↓ 缓存命中下降 |
| 快照 LRU | 见 composer | `page_turn_composer.dart` | 与翻页动画内存预算耦合 |

## 5. 真机验证清单

- [ ] 打开图片密集 EPUB（10+ 图/页）→ 首屏图片 <50ms 可见（几乎与文字同时）
- [ ] 连续向前翻页 10 页 → 无占位框 / 偶尔 1-2 张短暂占位（阶段2 预测生效）
- [ ] 占位框反馈：加载中圆弧指示器、失败 ×（阶段3）
- [ ] 方块/水波纹动画翻页 → 快照是否仍含灰占位框（决定是否激活暂缓的"快照等待图片"）
- [ ] 连续翻 50 页内存稳定（LRU 正常）
- [ ] 四种翻页动画模式回归正常

**测量方式**：`readerTrace` 标签——`image.bind`（换书绑定）、`image.hit`（缓存命中）、`image.ready`（解码完成）；首屏延迟对照 `_prewarmCurrentPageImages` 启动/完成时间戳。

## 6. 暂缓与后续候选

- **快照等待图片（原任务 1.4）**：暂缓。若真机实测翻页快照仍含占位框，在 `_pageToImage` 生成前对当前页图片加带超时（~200ms）的就绪等待，代价是动画启动延迟。
- **并发/容量微调**：依据真机内存与速度表现，按 §4 参数表调整。
- **网络书籍图片**：当前链路仅覆盖本地 EPUB 资源，网络书源图片加载是独立课题。
