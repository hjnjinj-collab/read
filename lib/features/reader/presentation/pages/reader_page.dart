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

  const ReaderPage({
    Key? key,
    required this.filePath,
    required this.bookName,
  }) : super(key: key);

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final size = MediaQuery.of(context).size;
      ref.read(readerProvider.notifier).setScreenSize(size.width, size.height);
      ref.read(readerProvider.notifier).openBook(widget.filePath, widget.bookName);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(readerProvider.notifier).closeBook();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    ref.read(readerProvider.notifier).onWindowResized(size.width, size.height);
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  // ── P2+P4: 手势处理（驱动 PageTurnComposer） ──

  void _onPointerDown(PointerDownEvent event) {
    _isDragging = true;
    _dragStartX = event.position.dx;
    _dragStartY = event.position.dy;
    _dragLastX = event.position.dx;
    _dragLastY = event.position.dy;
    _dragLastTimestampMs = event.timeStamp.inMilliseconds;
    _releaseVelocityX = 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isDragging) return;

    final now = event.timeStamp.inMilliseconds;
    final dt = now - _dragLastTimestampMs;
    if (dt > 0) {
      _releaseVelocityX =
          (event.position.dx - _dragLastX) / (dt / 1000.0);
    }
    _dragLastX = event.position.dx;
    _dragLastY = event.position.dy;
    _dragLastTimestampMs = now;

    // P4: 首次移动时确定方向并通知 composer 开始拖拽
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;
    final distance = dx.abs();

    // 超过启动阈值才开始动画（避免微抖误触发）
    if (distance > 8.0 && _composerKey.currentState?.isIdle == true) {
      final direction = dx > 0 ? PageDirection.prev : PageDirection.next;
      // 竖向意图压倒横向时不启动
      if (dy.abs() <= distance * 1.5) {
        _composerKey.currentState?.startDrag(direction);
      }
    }

    // 持续更新进度
    if (_composerKey.currentState?.isIdle == false) {
      final screenWidth = MediaQuery.of(context).size.width;
      final progress = (distance / screenWidth).clamp(0.0, 1.0);
      _composerKey.currentState?.updateDrag(progress);
    }

    // 同时更新 viewport（供后续高级动画使用）
    final size = MediaQuery.of(context).size;
    ref.read(readerRenderStoreProvider).publishViewport(
      width: size.width,
      height: size.height,
      startX: _dragStartX,
      startY: _dragStartY,
      touchX: event.position.dx,
      touchY: event.position.dy,
      direction: dx > 0 ? PageDirection.prev : PageDirection.next,
      isAnimationRunning: true,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isDragging) return;
    _isDragging = false;

    final screenWidth = MediaQuery.of(context).size.width;
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;

    // 发布 viewport 最终状态
    ref.read(readerRenderStoreProvider).publishViewport(
      width: screenWidth,
      height: MediaQuery.of(context).size.height,
      startX: _dragStartX,
      startY: _dragStartY,
      touchX: _dragLastX,
      touchY: _dragLastY,
      direction: PageDirection.none,
      isAnimationRunning: false,
    );

    // P4: 如果 composer 正在拖拽，判定并执行动画
    if (_composerKey.currentState?.isIdle == false) {
      final result = resolveGesture(
        dx: dx,
        dy: dy,
        velocityX: _releaseVelocityX,
        screenWidth: screenWidth,
      );
      final shouldTurn = result.decision == GestureDecision.turnPage;
      _composerKey.currentState?.endDrag(shouldTurn: shouldTurn);
      return;
    }

    // 否则走点击判定
    final result = resolveGesture(
      dx: dx,
      dy: dy,
      velocityX: _releaseVelocityX,
      screenWidth: screenWidth,
    );

    switch (result.decision) {
      case GestureDecision.verticalIntent:
      case GestureDecision.snapBack:
        break;
      case GestureDecision.tap:
        _handleTapAt(_dragStartX, screenWidth);
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

  void _handleTapAt(double tapX, double screenWidth) {
    if (tapX < screenWidth * 0.3) {
      _composerKey.currentState?.tapTurn(PageDirection.prev);
    } else if (tapX > screenWidth * 0.7) {
      _composerKey.currentState?.tapTurn(PageDirection.next);
    } else {
      _toggleMenu();
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
      body: SafeArea(
        child: Stack(
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
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
  State<_PageTurnComposerBridge> createState() => _PageTurnComposerBridgeState();
}

class _PageTurnComposerBridgeState extends State<_PageTurnComposerBridge> {
  final _composerKey = GlobalKey<PageTurnComposerState>();

  bool get isIdle => _composerKey.currentState?.isIdle ?? true;

  void startDrag(PageDirection direction) {
    _composerKey.currentState?.onDragStart(direction);
  }

  void updateDrag(double progress) {
    _composerKey.currentState?.onDragUpdate(progress);
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
