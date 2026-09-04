import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/models/simple_models.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_render_state.dart';
import '../widgets/page_turn/page_turn_gesture.dart';
import '../widgets/page_turn/page_turn_types.dart';
import '../widgets/page_turn_composer.dart';
import '../widgets/reader_menu.dart';

class ReaderPage extends ConsumerStatefulWidget {
  final String filePath;
  final String bookName;

  const ReaderPage({Key? key, required this.filePath, required this.bookName})
    : super(key: key);

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  bool _showMenu = false;

  /// P4: 翻页模式（默认仿真卷曲；P5 从设置读取）
  PageTurnMode _pageTurnMode = PageTurnMode.simulation;

  // ── P2: 滑动手势状态 ──
  bool _isDragging = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragLastX = 0;
  double _dragLastY = 0;
  int _dragLastTimestampMs = 0;
  double _releaseVelocityX = 0;

  /// P4: 翻页合成器的 key，用于调用其方法
  final _composerKey = GlobalKey<_PageTurnComposerBridgeState>();

  @override
  void initState() {
    super.initState();
    // viewport 测量由 build 的 LayoutBuilder 负责（SafeArea 内实际可用
    // 区域）——postFrame 时首帧 build 已跑过，openBook 排版即用正确尺寸。
    // 旧实现取 MediaQuery.size（全屏值，含状态栏/手势条区域）喂排版，
    // 与 SafeArea 内绘制 canvas 不一致 → 移动端翻页后背景纹理放大。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(readerProvider.notifier)
          .openBook(widget.filePath, widget.bookName);
    });
  }

  @override
  void dispose() {
    ref.read(readerProvider.notifier).closeBook();
    super.dispose();
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  // ── P2+P4: 手势处理（驱动 PageTurnComposer） ──
  // 全部使用 event.localPosition：与 CurlPainter 绘制坐标系一致

  void _onPointerDown(PointerDownEvent event) {
    _isDragging = true;
    _dragStartX = event.localPosition.dx;
    _dragStartY = event.localPosition.dy;
    _dragLastX = event.localPosition.dx;
    _dragLastY = event.localPosition.dy;
    _dragLastTimestampMs = event.timeStamp.inMilliseconds;
    _releaseVelocityX = 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isDragging) return;

    final local = event.localPosition;
    final now = event.timeStamp.inMilliseconds;
    final dt = now - _dragLastTimestampMs;
    if (dt > 0) {
      _releaseVelocityX = (local.dx - _dragLastX) / (dt / 1000.0);
    }
    _dragLastX = local.dx;
    _dragLastY = local.dy;
    _dragLastTimestampMs = now;

    // 首次移动时确定方向并通知 composer 开始拖拽
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;
    final distance = dx.abs();

    // 超过启动阈值才开始动画（避免微抖误触发）
    // M9.5-J：挂起中不再重调 startDrag（之前 100ms × N 重复 register）
    if (distance > 8.0 &&
        _composerKey.currentState?.isIdle == true &&
        _composerKey.currentState?.hasPendingTurn != true) {
      final direction = dx > 0 ? PageDirection.prev : PageDirection.next;
      // 竖向意图压倒横向时不启动
      if (dy.abs() <= distance * 1.5) {
        _composerKey.currentState?.startDrag(
          direction,
          Offset(_dragStartX, _dragStartY),
        );
      }
    }

    // 持续更新进度 + 实时触点
    if (_composerKey.currentState?.isIdle == false) {
      final notifier = ref.read(readerProvider.notifier);
      final rawProgress = (distance / notifier.screenWidth).clamp(0.0, 1.0);
      
      // 2026-09-03 第二阶段优化：渐进式阻尼
      // 越接近边缘（progress 越大），阻力越大
      final dampedProgress = _applyProgressiveDamping(rawProgress);
      
      _composerKey.currentState?.updateDrag(
        dampedProgress,
        Offset(_dragLastX, _dragLastY),
      );
    }

    // 同时更新 viewport（供后续高级动画使用）——权威 viewport 与排版
    // LayoutConfig 同源（LayoutBuilder 测量的 SafeArea 内实际区域）
    final notifier2 = ref.read(readerProvider.notifier);
    ref
        .read(readerRenderStoreProvider)
        .publishViewport(
          width: notifier2.screenWidth,
          height: notifier2.screenHeight,
          startX: _dragStartX,
          startY: _dragStartY,
          touchX: local.dx,
          touchY: local.dy,
          direction: dx > 0 ? PageDirection.prev : PageDirection.next,
          isAnimationRunning: true,
        );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isDragging) return;
    _isDragging = false;

    final notifier = ref.read(readerProvider.notifier);
    final screenWidth = notifier.screenWidth;
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;

    // 发布 viewport 最终状态
    ref
        .read(readerRenderStoreProvider)
        .publishViewport(
          width: screenWidth,
          height: notifier.screenHeight,
          startX: _dragStartX,
          startY: _dragStartY,
          touchX: _dragLastX,
          touchY: _dragLastY,
          direction: PageDirection.none,
          isAnimationRunning: false,
        );

    // 单次手势判定（此前重复计算两遍，已合并）
    final result = resolveGesture(
      dx: dx,
      dy: dy,
      velocityX: _releaseVelocityX,
      screenWidth: screenWidth,
    );

    // composer 正在拖拽 → 由其执行收尾动画
    if (_composerKey.currentState?.isIdle == false) {
      _composerKey.currentState?.endDrag(
        shouldTurn: result.decision == GestureDecision.turnPage,
      );
      return;
    }

    switch (result.decision) {
      case GestureDecision.verticalIntent:
      case GestureDecision.snapBack:
        break;
      case GestureDecision.tap:
        // 2026-09-03 第二阶段优化：点击也基于微小的手势方向判断
        // 如果有微小位移（即使被判定为 tap），根据方向翻页
        // 完全无位移时打开菜单
        _handleTapGesture(dx, dy);
        break;
      case GestureDecision.turnPage:
        if (result.direction == PageDirection.prev) {
          _composerKey.currentState?.tapTurn(PageDirection.prev);
        } else if (result.direction == PageDirection.next) {
          _composerKey.currentState?.tapTurn(PageDirection.next);
        }
        break;
    }
  }

  /// 2026-09-03 第二阶段优化：基于手势方向判断翻页
  /// - 右滑（dx > 微小阈值）→ 上一页
  /// - 左滑（dx < -微小阈值）→ 下一页
  /// - 几乎无位移 → 打开菜单
  void _handleTapGesture(double dx, double dy) {
    const microGestureThreshold = 3.0; // 3px 微手势阈值
    
    if (dx > microGestureThreshold) {
      // 右滑 → 上一页
      _composerKey.currentState?.tapTurn(PageDirection.prev);
    } else if (dx < -microGestureThreshold) {
      // 左滑 → 下一页
      _composerKey.currentState?.tapTurn(PageDirection.next);
    } else {
      // 几乎无位移 → 菜单
      _toggleMenu();
    }
  }

  /// 2026-09-03 第二阶段优化：渐进式阻尼计算
  /// 
  /// 物理模型：越接近边缘，阻力越大，模拟真实翻书的阻力感
  /// - [0.0, 0.5): 无阻尼，完全跟手
  /// - [0.5, 0.8): 线性阻尼，开始感受到阻力
  /// - [0.8, 1.0]: 强阻尼，需要更大的力才能继续拖动
  double _applyProgressiveDamping(double rawProgress) {
    if (rawProgress < 0.5) {
      // 前半段：无阻尼，完全跟手
      return rawProgress;
    } else if (rawProgress < 0.8) {
      // 中段：线性阻尼
      // 将 [0.5, 0.8] 映射到 [0.5, 0.7]
      // 阻尼系数从 1.0 线性降到 0.67
      final t = (rawProgress - 0.5) / 0.3; // 归一化到 [0, 1]
      final damping = 1.0 - t * 0.33; // 1.0 → 0.67
      return 0.5 + (rawProgress - 0.5) * damping;
    } else {
      // 后段：强阻尼
      // 将 [0.8, 1.0] 映射到 [0.7, 0.85]
      // 阻尼系数从 0.67 快速降到 0.25
      final t = (rawProgress - 0.8) / 0.2; // 归一化到 [0, 1]
      final damping = 0.67 - t * 0.42; // 0.67 → 0.25
      return 0.7 + (rawProgress - 0.8) * damping;
    }
  }

  /// P5: 切换翻页模式
  void _setPageTurnMode(PageTurnMode mode) {
    setState(() {
      _pageTurnMode = mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5DC),
      // LayoutBuilder = 权威 viewport 测量点：constraints 即 SafeArea
      // 内实际可用区域，与 CustomPaint 画布尺寸严格一致。排版
      // LayoutConfig、翻页几何、手势归一化全部同源于此（禁止
      // MediaQuery.size 全屏值）。
      // 【对照实验结论 2026-09-01】SafeArea 移除后 Windows 现象不变
      // → SafeArea 无罪，已恢复。偏右根因转向绘制端实测诊断。
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final notifier = ref.read(readerProvider.notifier);
            // 权威 viewport = LayoutBuilder.constraints（已含 SafeArea 扣减）；
            // 此即 CustomPaint 实际画布尺寸（祖先约束逐层 strict 透传）。
            // 调试日志附 MediaQuery.sizeOf/viewPaddingOf 用于裁切不一致时
            // （曲面屏/分屏）溯源——三者中 constraints 与 sizeOf-paddingOf
            // 不等才是真正的 cutout 残留，Flutter 自身问题。
            final mq = MediaQuery.of(context);
            // v7 回退：用 constraints.maxWidth 而非 biggest + 不减 viewPadding
            //（SafeArea 已扣；viewPadding 已在 SafeArea 路径中处理）——
            // 回归 v1「同源 SafeArea 内 constraints」原意。最大约束
            // (= maxWidth) 即 CustomPaint canvasSize（同源），与 Rust
            // LayoutConfig.width 严格一致——这是用户实测量 v1 之前
            // 偏右不存在的关键。biggest 引入（v4）= Stack loose 撑出
            // 比 canvas 大的尺寸 → Rust 排版按更大宽布局、绘制按更小画
            // 布 → 文字左对齐、右侧空白 → 用户视觉"偏右"。
            final wLayout = constraints.maxWidth;
            final hLayout = constraints.maxHeight;
            if (wLayout != notifier.screenWidth || hLayout != notifier.screenHeight) {
              if (notifier.hasBook) {
                // 已开书：尺寸变化 → postFrame 锚点重排（onWindowResized
                // 内部 setScreenSize + FrameSet 作废 + 带锚点重载）
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  notifier.onWindowResized(wLayout, hLayout);
                });
              } else {
                // 首帧/开书前：同步登记（纯字段赋值），openBook 排版
                // 即用正确 viewport
                notifier.setScreenSize(wLayout, hLayout);
              }
            }
            return Stack(
              children: [
                // P4: 阅读区域用 Listener + PageTurnComposer
                Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              child: Container(
                color: Colors.transparent,
                child: state.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : state.error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(
                            'Error: ${state.error}',
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      )
                    : state.currentPage != null
                    ? _PageTurnComposerBridge(
                        key: _composerKey,
                        currentPage: state.currentPage!,
                        mode: _pageTurnMode,
                      )
                    : const Center(child: Text('No content')),
              ),
            ),

            // Top status bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.3),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      state.bookTitle ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${state.currentChapterIndex + 1}/${state.chapters.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // Bottom menu
            if (_showMenu)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ReaderMenu(
                  onClose: () => setState(() => _showMenu = false),
                  pageTurnMode: _pageTurnMode,
                  onPageTurnModeChanged: _setPageTurnMode,
                ),
              ),
              ],
            ); // Stack
          }, // LayoutBuilder builder
        ),
      ),
    );
  }
}

/// 桥接 Widget：暴露 PageTurnComposer 的方法给 ReaderPage
///
/// 通过 GlobalKey 调用，避免 ReaderPage 直接持有 composer State。
class _PageTurnComposerBridge extends StatefulWidget {
  final PageInfo currentPage;
  final PageTurnMode mode;

  const _PageTurnComposerBridge({
    super.key,
    required this.currentPage,
    required this.mode,
  });

  @override
  State<_PageTurnComposerBridge> createState() =>
      _PageTurnComposerBridgeState();
}

class _PageTurnComposerBridgeState extends State<_PageTurnComposerBridge> {
  final _composerKey = GlobalKey<PageTurnComposerState>();

  bool get isIdle => _composerKey.currentState?.isIdle ?? true;

  /// M9.5-J：是否已挂起待决手势。供 _onPointerMove 跳过重复 startDrag
  bool get hasPendingTurn =>
      _composerKey.currentState?.hasPendingTurn ?? false;

  void startDrag(PageDirection direction, Offset localTouch) {
    _composerKey.currentState?.onDragStart(direction, localTouch);
  }

  void updateDrag(double progress, Offset localTouch) {
    _composerKey.currentState?.onDragUpdate(progress, localTouch);
  }

  void endDrag({required bool shouldTurn}) {
    _composerKey.currentState?.onDragEnd(shouldTurn: shouldTurn);
  }

  void tapTurn(PageDirection direction) {
    _composerKey.currentState?.onTapTurn(direction);
  }

  @override
  Widget build(BuildContext context) {
    return PageTurnComposer(
      key: _composerKey,
      currentPage: widget.currentPage,
      mode: widget.mode,
    );
  }
}
