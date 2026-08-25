# Flutter 翻页动画实施计划

> 参考: legado-with-MD3 Track C1 ReaderRenderModel 方案
> 适配: legado_flutter (Flutter + Rust FFI + Riverpod)

**目标:** 为当前仅支持点击翻页的阅读器增加滑动翻页动画，支持仿真卷曲和上下滚动两种模式，同时保持现有渲染行为不变。

**现状分析:**
- 仅点击翻页（左30%/右30%/中40%菜单），无手势、无动画
- `ReadingState` 仅持有单页 `PageInfo`，每次翻页通过 FFI 异步加载
- Rust 侧已有 LRU 分页缓存（10 章），可快速返回任意页
- `page_turn_types.dart` 已有枚举桩：`PageDirection`、`PageTurnMode`、`PageTurnResult`
- P0 数据层已完成：`ReaderRenderStateStore` 双通道状态存储，9 个测试通过

---

## 阶段概览

| 阶段 | 代号 | 内容 | 依赖 |
|------|------|------|------|
| P0 | 数据层 | ReaderRenderStateStore 双通道状态 | ✅ 已完成 |
| P1 | 接线层 | Store 接入 ReaderNotifier + 三页预加载 | P0 |
| P2 | 手势层 | 滑动检测 + 拖拽跟踪 | P1 |
| P3 | 动画层 | 翻页动画控制器（卷曲/滚动） | P2 |
| P4 | 渲染层 | 动画合成渲染 + 集成到 ReaderPage | P3 |
| P5 | 设置集成 | 翻页模式切换 + 持久化 | P4 |

---

## P1: 接线层 — Store 接入 ReaderNotifier + 三页预加载

**目标:** 将 `ReaderRenderStateStore` 接入现有 `ReaderNotifier`，在每次页面加载时同时预加载相邻页，形成"三页缓冲区"。

### Task 1.1: Riverpod Provider 注册

**Files:**
- Modify: `lib/features/reader/presentation/providers/reader_provider.dart`
- Modify: `lib/features/reader/presentation/providers/reader_render_state.dart`

- [ ] **Step 1:** 在 `reader_render_state.dart` 底部添加 Riverpod provider

```dart
/// 全局 ReaderRenderStateStore 实例
final readerRenderStoreProvider = Provider<ReaderRenderStateStore>(
  (ref) => ReaderRenderStateStore(),
);

/// 结构态 model（低频，页面/选择/朗读变化时更新）
final readerRenderModelProvider = Provider<ReaderRenderModel>(
  (ref) => ref.watch(readerRenderStoreProvider).model,
);

/// 高频 viewport（触点/动画进度）
final readerRenderViewportProvider = Provider<ReaderRenderViewport>(
  (ref) => ref.watch(readerRenderStoreProvider).viewport,
);
```

- [ ] **Step 2:** 写测试验证 provider 与 store 的关系（可选，纯注册逻辑）

### Task 1.2: ReaderNotifier 三页预加载

**Files:**
- Modify: `lib/features/reader/presentation/providers/reader_provider.dart`

- [ ] **Step 1:** 在 `ReaderNotifier` 中持有 `ReaderRenderStateStore` 引用

```dart
class ReaderNotifier extends Notifier<ReadingState> {
  late final ReaderRenderStateStore _renderStore;
  // ...

  @override
  ReadingState build() {
    _renderStore = ref.read(readerRenderStoreProvider);
    // ...
  }
}
```

- [ ] **Step 2:** 修改 `_loadCurrentPage()`，加载当前页后同时预加载 prev/next 页

```dart
Future<void> _loadCurrentPage() async {
  // ... 现有逻辑加载 state.currentPage ...

  // P1: 发布三页结构态到 render store
  final prevPage = await _tryLoadPage(
    chapterIndex: _prevChapterIndex,
    pageIndex: _prevPageIndex,
  );
  final nextPage = await _tryLoadPage(
    chapterIndex: _nextChapterIndex,
    pageIndex: _nextPageIndex,
  );

  _renderStore.publishStructure(
    previousPage: prevPage,
    currentPage: state.currentPage,
    nextPage: nextPage,
    durPageIndex: state.currentPageIndex,
  );
}
```

- [ ] **Step 3:** `_tryLoadPage()` 辅助方法：安全加载相邻页，失败返回 null

- [ ] **Step 4:** 在 `nextPage()` / `previousPage()` / `jumpTo()` 结束时调用 `_publishStructure()`

- [ ] **Step 5:** 写测试验证三页预加载逻辑

### Task 1.3: 邻居页加载优化 — 批量 FFI

**Files:**
- Modify: `rust/crates/bridge/src/api.rs`
- Modify: `lib/core/ffi/book_service.dart`
- Modify: `lib/core/ffi/rust_bridge.dart/api.dart` (codegen)

- [ ] **Step 1:** Rust 新增 `get_pages_batch()` — 一次 FFI 返回 3 页数据

```rust
/// 一次返回 [prev, current, next] 三页，减少 FFI 调用次数
pub fn get_pages_batch(book_id: String, chapter_index: usize, page_index: usize) -> Vec<PageInfo> { ... }
```

- [ ] **Step 2:** `BookService` 新增 `getPagesBatch()` 包装

- [ ] **Step 3:** `_loadCurrentPage()` 改用 `getPagesBatch()` 单次调用取三页

- [ ] **Step 4:** 基准测试对比单页×3 vs 批量×1 的延迟差异

---

## P2: 手势层 — 滑动检测与拖拽跟踪

**目标:** 在 `ReaderPage` 的 `GestureDetector` 中增加水平/垂直滑动手势，跟踪拖拽偏移并实时更新 viewport 状态。

### Task 2.1: 手势检测器升级

**Files:**
- Modify: `lib/features/reader/presentation/pages/reader_page.dart`

- [ ] **Step 1:** 将 `GestureDetector` 替换为同时识别 tap + drag 的 `GestureDetector`

```dart
GestureDetector(
  onTapUp: _handleTap,
  onHorizontalDragStart: _onDragStart,
  onHorizontalDragUpdate: _onDragUpdate,
  onHorizontalDragEnd: _onDragEnd,
  // 垂直滚动模式用 onVerticalDrag*
  child: ...
)
```

- [ ] **Step 2:** 实现 `_onDragStart` — 记录起始点 (startX, startY)

- [ ] **Step 3:** 实现 `_onDragUpdate` — 实时调用 `_renderStore.publishViewport()`

```dart
void _onDragUpdate(DragUpdateDetails details) {
  _renderStore.publishViewport(
    width: _screenWidth,
    height: _screenHeight,
    startX: _dragStartX,
    startY: _dragStartY,
    touchX: details.globalPosition.dx,
    touchY: details.globalPosition.dy,
    direction: _determineDirection(details),
    isAnimationRunning: true,
  );
}
```

- [ ] **Step 4:** 实现 `_onDragEnd` — 根据拖拽距离/速度决定翻页或回弹

### Task 2.2: 翻页阈值与速度判定

**Files:**
- Modify: `lib/features/reader/presentation/pages/reader_page.dart`

- [ ] **Step 1:** 定义翻页阈值常量

```dart
/// 拖拽距离超过屏幕宽度此比例时触发翻页（否则回弹）
static const _kPageTurnDistanceRatio = 0.3;

/// 速度超过此阈值时即使距离不够也触发翻页（快速滑动）
static const _kPageTurnVelocityThreshold = 800.0; // px/s
```

- [ ] **Step 2:** `_onDragEnd` 中计算拖拽距离和速度，决定 `PageTurnResult`

- [ ] **Step 3:** 翻页成功 → 调用 `nextPage()`/`previousPage()`；失败 → 触发回弹动画

### Task 2.3: 测试

- [ ] **Step 1:** 手势判定逻辑提取为纯函数，写单元测试

---

## P3: 动画层 — 翻页动画控制器

**目标:** 实现两种翻页动画模式的动画控制器，驱动 viewport 状态从 0→1（翻页）或 1→0（回弹）。

### Task 3.1: 动画控制器抽象

**Files:**
- Create: `lib/features/reader/presentation/widgets/page_turn/page_turn_controller.dart`

- [ ] **Step 1:** 定义抽象动画控制器

```dart
abstract class PageTurnAnimationController {
  /// 翻页方向
  PageDirection get direction;

  /// 动画进度 [0.0, 1.0]
  double get progress;

  /// 开始翻页动画（从当前位置正向播放到 1.0）
  void startTurn();

  /// 回弹动画（从当前位置反向播放到 0.0）
  void snapBack();

  /// 释放资源
  void dispose();
}
```

- [ ] **Step 2:** 写测试验证抽象契约

### Task 3.2: 仿真卷曲动画

**Files:**
- Create: `lib/features/reader/presentation/widgets/page_turn/simulation_turn_controller.dart`

- [ ] **Step 1:** 基于 `AnimationController` + `Simulation` 实现仿真卷曲

- 使用 `SpringSimulation` 模拟纸张弹性
- 进度映射到卷曲角度/阴影

- [ ] **Step 2:** 支持拖拽跟随（非离散动画）— `AnimationController` 的 `value` 由手势直接驱动

- [ ] **Step 3:** 松手后根据阈值决定正向完成或回弹

### Task 3.3: 上下滚动动画

**Files:**
- Create: `lib/features/reader/presentation/widgets/page_turn/scroll_turn_controller.dart`

- [ ] **Step 1:** 基于 `AnimationController` + `CurvedAnimation` 实现上下滚动

- 使用 `Curves.easeOutCubic` 平滑减速
- 进度映射到 Y 轴偏移

- [ ] **Step 2:** 支持拖拽跟随

### Task 3.4: 动画模式工厂

**Files:**
- Modify: `lib/features/reader/presentation/widgets/page_turn/page_turn_types.dart`

- [ ] **Step 1:** 添加工厂方法

```dart
PageTurnAnimationController createTurnController({
  required PageTurnMode mode,
  required PageDirection direction,
  required TickerProvider vsync,
  required void Function(double progress) onProgressUpdate,
}) {
  switch (mode) {
    case PageTurnMode.simulation:
      return SimulationTurnController(...);
    case PageTurnMode.verticalScroll:
      return ScrollTurnController(...);
  }
}
```

---

## P4: 渲染层 — 动画合成与集成

**目标:** 在现有 `ReaderPageWidget` 基础上，叠加动画层渲染，实现翻页时两页同时可见的过渡效果。

### Task 4.1: 翻页合成 Widget

**Files:**
- Create: `lib/features/reader/presentation/widgets/page_turn/page_turn_composer.dart`

- [ ] **Step 1:** 创建 `PageTurnComposer` widget

```dart
/// 叠加在 ReaderPageWidget 之上，管理翻页动画期间的双页渲染
///
/// 结构:
/// Stack [
///   ReaderPageWidget(pageInfo: currentPage),  // 底层：当前页
///   AnimatedPageLayer(pageInfo: targetPage),   // 动画层：目标页
///   CustomPaint(painter: TurnEffectPainter),   // 特效层：卷曲阴影/翻页边缘
/// ]
class PageTurnComposer extends StatefulWidget {
  final PageInfo currentPage;
  final PageTurnMode mode;
  // ...
}
```

- [ ] **Step 2:** `AnimatedPageLayer` — 根据动画进度裁切/变换目标页

### Task 4.2: 卷曲效果绘制器

**Files:**
- Create: `lib/features/reader/presentation/widgets/page_turn/curl_painter.dart`

- [ ] **Step 1:** 实现 `CurlEffectPainter` (CustomPainter)

- 贝塞尔曲线模拟纸张卷曲
- 渐变阴影表示折叠深度
- 背面内容镜像绘制

- [ ] **Step 2:** 与动画进度同步更新绘制参数

### Task 4.3: 集成到 ReaderPage

**Files:**
- Modify: `lib/features/reader/presentation/pages/reader_page.dart`

- [ ] **Step 1:** 将 `ReaderPageWidget` 替换为 `PageTurnComposer`

- [ ] **Step 2:** 手势 → 动画控制器 → viewport → 渲染器 完整链路打通

- [ ] **Step 3:** 动画期间禁止新的手势输入（防抖）

- [ ] **Step 4:** 动画完成后更新 `ReadingState` 到新页

### Task 4.4: 集成测试

- [ ] **Step 1:** 模拟完整翻页流程：drag → animation → page update

- [ ] **Step 2:** 验证快速连续翻页不崩溃

- [ ] **Step 3:** 验证到章首/章尾的边界行为（`PageTurnResult.atStart/atEnd`）

---

## P5: 设置集成 — 模式切换与持久化

**目标:** 在阅读设置面板中增加翻页模式选择，并持久化到本地存储。

### Task 5.1: 设置 UI

**Files:**
- Modify: `lib/features/reader/presentation/widgets/reader_settings_dialog.dart`

- [ ] **Step 1:** 在设置对话框中增加"翻页动画"选项组

```
翻页方式:
  ○ 仿真卷曲
  ○ 上下滚动
  ○ 无动画（点击翻页）
```

- [ ] **Step 2:** 选择变化时通知 `ReaderNotifier` 切换模式

### Task 5.2: 持久化

**Files:**
- Modify: `lib/features/reader/presentation/providers/reader_provider.dart`
- Modify: `lib/core/database/app_database.dart` (如需新表)

- [ ] **Step 1:** 读取/写入翻页模式偏好到数据库或 shared_preferences

- [ ] **Step 2:** 打开书籍时自动恢复上次选择的翻页模式

---

## 验收标准

1. **功能:** 水平滑动可翻页，支持卷曲和滚动两种动画
2. **性能:** 翻页动画 ≥ 60fps，无卡顿（快速连续翻页不掉帧）
3. **边界:** 章首/章尾正确回弹，不越界
4. **兼容:** 无动画模式（点击翻页）保持原有行为不变
5. **测试:** P0-P1 单元测试全通过，P2-P4 有关键路径覆盖

---

## 文件清单

| 阶段 | 新建 | 修改 |
|------|------|------|
| P0 ✅ | `reader_render_state.dart`, `page_turn_types.dart`, `reader_render_state_test.dart` | — |
| P1 | — | `reader_provider.dart`, `reader_render_state.dart`, `api.rs`, `book_service.dart` |
| P2 | — | `reader_page.dart` |
| P3 | `page_turn_controller.dart`, `simulation_turn_controller.dart`, `scroll_turn_controller.dart` | `page_turn_types.dart` |
| P4 | `page_turn_composer.dart`, `curl_painter.dart` | `reader_page.dart` |
| P5 | — | `reader_settings_dialog.dart`, `reader_provider.dart` |
