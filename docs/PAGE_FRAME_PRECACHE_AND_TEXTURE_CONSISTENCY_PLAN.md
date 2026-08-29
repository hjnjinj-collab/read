# 卷曲翻页页面帧预缓存与纹理一致性方案

## 一句话简介

把“页面结构”和“页面依赖的图片资源”组织成一个带身份、版本和就绪状态的不可变页面帧；卷曲动画只允许使用同一批次中已经准备好的前后页，动画完成后原子提交目标帧，从根上消除内容重复和前后闪烁。

## 当前实际架构

当前项目没有整页 GPU Texture 快照缓存（既定架构决策：无快照全链路直绘）。所谓“纹理”由两部分组成：

1. Rust 生成的 `PageInfo`（经 PageFrame 包装）：包含文字行、图片 entry、背景图和分页边界。
2. Flutter `BookImageStore` 解码的 EPUB `ui.Image`：按 `bookId|resourceHref` 复用，LRU 64 张上限 + 存活帧 pin 保护 + 解码并发限 2。

已落地的 PageFrame 链路：

```text
原文/EPUB
   ↓
Rust 内容处理、排版、分页
（StructuredParams 缓存键单源；分页缓存 LRU 为主 + 300s TTL 辅助淘汰）
   ↓
PageFrame（FrameIdentity：bookId+章节+页号+锚点；ResourceManifest 资源清单）
   ↓
ReaderRenderStateStore（FrameSet 原子发布：current/previous/next 三槽，
槽位带 out-of-range / failed / pending 明确态，永不静默置 null；
pending 手势登记 → 发布落地触发重试）
   ↓
PageTurnComposer（手势门控三态：Ready 启动动画 / OutOfRange 无动画直翻 /
Wait 挂起等待——tap 400ms / drag 600ms 超时保底直翻）
   ↓
PageContentRenderer（文字直绘、图片查 ui.Image）
   ↓
CurlPainter（repaint listenable 图片就绪直达重绘；定格帧身份匹配释放 + 1500ms 安全超时兜底）
```

三页结构与图片解码经 FrameSet 统一提交：`ReaderNotifier.layoutFingerprint()` 单源指纹、`_invalidateFrames` 单入口失效联动（requestGeneration / sessionEpoch / FrameSet / pending 手势 / 图片 pin / 页数缓存六轴）；发布协议保证 stale 结果降级补发（degraded-from-state），store 永不滞后于 state。

## 两个问题的根因

### 内容纹理重复

- 主页面异步请求没有 request generation，旧章节、旧页或旧设置的结果可能晚于新请求返回并覆盖当前状态。
- Flutter 页数缓存的替换规则 key 只使用规则数量；规则数量相同但内容不同，会错误复用页数。
- `PageInfo.pageIndex` 只是章节内页号，跨章节时不能单独作为页面身份。
- Rust 分页缓存没有 schema/算法版本，分页算法或页面模型变化后可能继续命中旧进程缓存。

### 动画前后闪烁

- `PageInfo` 返回不代表图片已经解码；复杂图文页可能先绘制灰色占位，再在动画中途切换成真实图片。
- CurlPainter 当前传给 `PageContentRenderer` 的图片回调为空，图片完成后没有独立的动画层重绘通知。
- 换书/关书时，旧图片异步请求没有 epoch 校验，可能在新书生命周期中回写。
- 动画定格页与 provider 当前页的交换虽有保护，但跨章 fallback 只比较 `pageIndex`，可能过早撤掉定格页。

## 核心概念：PageFrame

```text
PageFrame
├── 页面身份：bookId + chapterIndex + pageIndex
├── 配置身份：layout/content fingerprint
├── sessionEpoch：打开、关闭、换书、设置改变时递增
├── requestGeneration：每批异步加载递增
├── PageInfo：文字布局、图片几何、背景信息
├── ResourceManifest：背景图 + 所有图片 entry 的去重引用
└── ResourceState：ready / loading / failed
```

页面帧不是把整页截图成一张图片，而是把“可绘制的页面数据”和“其全部图片依赖”绑定起来。这样继续使用 `PageContentRenderer` 的统一绘制逻辑，同时拥有稳定的提交边界。

## 复杂图文页何时算准备好

这是本方案的关键契约。

### 1. PageInfo ready

Rust 已完成内容处理、排版和分页，并返回结构完整的 `PageInfo`。文字不需要额外的 Flutter 纹理解码，因为文字行和几何已经包含在 `PageInfo` 中。

### 2. ResourceManifest ready

从 `PageInfo` 收集：

- `backgroundHref`；
- 每个 `PageEntry.resourceHref`；
- 去重后的资源引用。

对每个引用完成：

```text
getBookResource
  → Uint8List
  → instantiateImageCodec
  → getNextFrame
  → ui.Image
```

只有全部资源进入 `ready`，页面才算正常 ready。资源加载失败也必须进入稳定的 `failed` 终态并使用固定占位，不允许在动画进行中随机地从占位切换到真实图像。

### 3. Frame ready

```text
Frame ready
  = PageInfo ready
  ∧ ResourceManifest ready
  ∧ bookId/sessionEpoch/config fingerprint 仍然有效
```

### 4. FrameSet ready

```text
FrameSet ready
  = current frame ready
  ∧ 目标方向邻居 frame ready
  ∧ 可用的另一邻居 frame ready 或明确标记越界
  ∧ 三页属于同一个 session/config fingerprint
```

因此，包含复杂排版、背景图、表格和多张插图的 EPUB 页面不会因为“文字已经返回”就提前启动动画；它必须等待 manifest 中所有图片完成解码。图片资源只要已在 `BookImageStore` 中 ready，多个页面和卷曲背面可以安全复用同一个 `ui.Image`。

## 目标时序

```text
加载当前页
  ↓
捕获 sessionEpoch + requestGeneration + fingerprint
  ↓
获取 current / previous / next PageInfo
  ↓
收集并并行预热三页图片资源
  ↓
校验 epoch/generation/fingerprint
  ↓
一次性提交 FrameSet 到 RenderStore
  ↓
用户拖拽/点击
  ↓
仅从已提交 FrameSet 锁定目标 frame
  ↓
动画末帧 = 目标 frame
  ↓
原子提交目标 frame 为 current
  ↓
发布下一组三页并开始后台预热
```

旧请求、旧动画和旧图片请求都不具备当前 epoch 时，只能被丢弃，不能改变 current、RenderStore 或当前书籍的图片缓存。

## 分阶段实施

> 实施状态（2026-08-28）：三阶段全部落地，详见文末「实施状态」章节。

### 第一阶段：稳定性闭环 ✅

- `BookImageStore` 增加 bind epoch、资源状态和批量页面预热。
- `ReaderNotifier` 为主页面、邻居页和预取批次增加 generation/epoch 校验。
- `ReaderRenderStateStore` 保存统一的 frame identity/revision。
- `PageTurnComposer` 使用 ready frame 才启动动画，动画层接收图片完成重绘通知。
- 跨章定格页匹配同时使用 chapter/page identity。

### 第二阶段：缓存一致性 ✅

- Dart 页数缓存使用完整替换规则内容 hash。
- TXT 与 EPUB Rust 分页缓存加入 schema/layout revision。
- 统一按书清理 TXT/EPUB 缓存；全清理覆盖两种缓存。
- 设置、窗口变化、换书和关书统一触发旧 frame 失效。

### 第三阶段：调度和性能 ✅

- 将 Rust `PreloadExecutor` 的任务身份与 Flutter frame fingerprint 对齐。
- 预缓存优先目标方向，限制并发和内存，避免重新出现预加载级联冲刷 LRU。
- 记录 frame ready、命中、丢弃、失败和动画启动等待指标。

## 必须满足的不变量

1. 动画期间 folding page 和 target page 不从全局 state 动态替换。
2. 动画末帧、定格帧和提交后的第一帧引用同一目标 frame。
3. 旧 generation 的页面、图片和预取结果不得回写当前状态。
4. 复杂图文页的所有图片依赖在动画启动前已 ready 或稳定 failed。
5. page identity 必须包含章节，不能只使用章节内 `pageIndex`。
6. 配置或内容处理设置改变后，旧 fingerprint 的缓存结果不得复用。

## 验收方式

- 快速连续 next/prev：不出现当前页翻给当前页，不重复上一页内容。
- 跨章节翻页：动画末帧与章节首页/末页一致，不提前撤除定格页。
- 含背景图、多图、表格和富文本的 EPUB：动画启动前无灰色占位，末帧不发生图片跳变。
- 改字号、窗口尺寸、简繁、替换规则后：旧页面和旧图片不回写。
- 关书立即换书：旧书资源请求完成后不影响新书。
- 自动动画收尾：光影淡出，但页面内容不发生二次替换。

## 关键文件

- `lib/features/reader/presentation/services/book_image_store.dart`
- `lib/features/reader/presentation/providers/reader_provider.dart`
- `lib/features/reader/presentation/providers/reader_render_state.dart`
- `lib/features/reader/presentation/widgets/page_turn_composer.dart`
- `lib/features/reader/presentation/widgets/reader_page_widget.dart`
- `lib/core/models/simple_models.dart`
- `rust/crates/reader_core/src/pagination_cache.rs`
- `rust/crates/bridge/src/api.rs`
- `test/reader_render_state_test.dart`
- `test/page_turn_controller_test.dart`
- `test/curl_geometry_test.dart`

## 实施状态（2026-08-28）

三阶段全部落地并通过验证。以 `ReaderRenderPage/revision` 三页快照为起点的旧模型已由 FrameSet 体系取代（`ReaderRenderPage` 删除；store 零订阅、composer 唯一读点，波及面已核实）。

### Stage 1 — 渲染重绘与提交原子性（止血）

- `curl_painter.dart`：`CurlPainter` 构造器增加 `required Listenable repaint` —— 图片解码完成时 `ValueNotifier` 通知直达 `markNeedsPaint`，绕过 `shouldRepaint` 比对，修复动画中占位冻结（根因 A）。
- `page_turn_composer.dart`：`onTapTurn` 重入守卫（`_isActive || _holdingFinalFrame || isAnimating`）+ `_commitInFlight` 双保险（根因 D）；定格释放收紧为身份匹配 + 1500ms 安全超时，`_commitPageTurn` await 化、失败撤定格回旧页（根因 C）。
- `book_image_store.dart`：failed 终态改 3 次退避重试（500ms/2s/8s），3 次后稳定 failed（根因 E）。

### Stage 2 — PageFrame / FrameSet 体系

- `page_frame.dart`（新增）：FrameIdentity（bookId+章节+页号+锚点）、ResourceManifest、PageFrame（含 `usableForAnimation`）、FrameSlot 四态（ready/outOfRange/failed/pending，永不静默置 null）、FrameSet、PendingTurnGesture、TargetFrameResult 密封三态。
- `reader_render_state.dart`（重写）：FrameSet 原子发布 / advanceSession / publishEmpty / pending 手势登记-消费-取消 / dirty 标记。
- `reader_provider.dart`：`layoutFingerprint()` 单源指纹、`_invalidateFrames` 单入口失效联动、`_prepareAndPublishFrameSet` 发布协议（stale 不静默丢弃 → degraded-from-state 补发）、`_loadNeighborSlot` 明确槽位态、adopt 双道校验（批次指纹 identical + 相邻性）+ 先模型后 state 预发布。
- `page_turn_composer.dart`：手势门控三态 + pending 挂起重试（模型发布监听触发；tap 400ms / drag 600ms 超时直翻保底）。
- `book_image_store.dart`：`prewarmManifest` / `isManifestReady` / LRU 64 + `setPinned` 存活帧保护。

### Stage 3 — 缓存一致性与调度

- Rust `pagination_cache.rs`：条目 TTL 300s 辅助淘汰（LRU 容量为主，`get`/`get_mut` 超龄条目移除按 miss）。
- Rust `api.rs`：`StructuredParams` + `structured_cache_key()` 缓存键单源（三个 FFI 入口 + `process_structured_chapter` 共用，FFI 签名不变免 codegen）；`get_book_resource` 快路径 read 锁窥探缓存（parser 新增 `peek_resource_cache(&self)`），命中不与前台分页争写锁，未命中才落写锁读 ZIP。
- Dart 调度：prewarm 按 next → current → prev 分组串行（目标方向最先就绪）、解码并发闸门（`_Semaphore(2)`）；指标补齐 `image.hit` / `set.drop` / `turn.wait{waitMs}`（`frame.commit{latencyMs}` / `image.failed` / `page.adopt.reject` 前两阶段已有）。

### 验证结果

- `flutter analyze`：0 错误 0 警告（23 条 info 均为既有）。
- `flutter test`：90 过 1 挂 —— 唯一失败为 `test/widget_test.dart` 计数器模板既有失败（项目初建遗留，与本次改动无关）。
- `cargo test --package reader_core --lib`：141 全过（含新增 TTL 用例）。
- `flutter build windows --debug`：成功。
- 人工验收清单见「验收方式」，建议真机重点观察：快速连翻无「翻给当前页」、图片密集 EPUB 动画中拖拽按住不动时占位在解码后立即更新、改字号后旧排版页不回写。

### 实施层偏差记录（相对本文档原始设计）

1. `FrameResourceState` 枚举不含 `outOfRange`：PageFrame 恒有非空 page，越界语义由 `FrameSlot.outOfRange` 承载（越界不存在页面帧）。
2. `ensureLoaded` 不做 sessionEpoch 双校验丢弃：图片与排版无关，epoch/bookId 守卫已覆盖「旧书请求不回写」，丢弃有效解码纯浪费。
3. `prewarmManifest` 收 `Iterable<String> hrefs` 而非 ResourceManifest：services 层不反向 import providers 层。
4. `get_book_resource` 资源锁优化采用「read 锁快路径 + 写锁慢路径」而非 parser 全面内部化：zip crate 的 `ZipArchive::by_index(&mut self)` 贯穿 `get_zip_entry` 链，全面 `&self` 化需把 archive 包 Mutex、连锁改动过大；快路径已覆盖命中场景（渲染重复图/预热去重）的锁竞争。
