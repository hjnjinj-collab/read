import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_render_state.dart';
import '../widgets/page_turn/page_turn_gesture.dart';
import '../widgets/page_turn/page_turn_types.dart';
import '../widgets/reader_page_widget.dart';
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

  // ── P2: 滑动手势状态 ──

  bool _isDragging = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragLastX = 0;
  double _dragLastY = 0;
  /// 用于速度计算：记录最近一次 move 的时间戳
  int _dragLastTimestampMs = 0;
  /// 松手瞬间的速度（px/s），正=向右/下
  double _releaseVelocityX = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Open book after first frame
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
    // 窗口缩放/拖拽：布局参数必须跟随，否则按旧宽断行的文本与
    // 图片会溢出新画布（截图验证过的错位根因）。
    // 不经 MediaQuery.of(context)——observer 回调里取物理尺寸换算更可靠
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    ref.read(readerProvider.notifier).onWindowResized(size.width, size.height);
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  // ── P2: 手势处理 ──

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
      // 瞬时速度（px/s），用于松手时判定
      _releaseVelocityX =
          (event.position.dx - _dragLastX) / (dt / 1000.0);
    }
    _dragLastX = event.position.dx;
    _dragLastY = event.position.dy;
    _dragLastTimestampMs = now;

    // 发布 viewport 到 render store（驱动后续动画层）
    final size = MediaQuery.of(context).size;
    final direction = _determineDirection(
      event.position.dx - _dragStartX,
    );
    ref.read(readerRenderStoreProvider).publishViewport(
      width: size.width,
      height: size.height,
      startX: _dragStartX,
      startY: _dragStartY,
      touchX: event.position.dx,
      touchY: event.position.dy,
      direction: direction,
      isAnimationRunning: true,
    );
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isDragging) return;
    _isDragging = false;

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;

    // 发布 viewport 最终状态（动画结束）
    ref.read(readerRenderStoreProvider).publishViewport(
      width: screenWidth,
      height: screenHeight,
      startX: _dragStartX,
      startY: _dragStartY,
      touchX: _dragLastX,
      touchY: _dragLastY,
      direction: PageDirection.none,
      isAnimationRunning: false,
    );

    // 委托纯函数判定手势意图（已覆盖 9 个测试用例）
    final result = resolveGesture(
      dx: dx,
      dy: dy,
      velocityX: _releaseVelocityX,
      screenWidth: screenWidth,
    );

    switch (result.decision) {
      case GestureDecision.verticalIntent:
      case GestureDecision.snapBack:
        // 不处理 / 回弹（无动画时页面已显示，无需额外操作）
        break;
      case GestureDecision.tap:
        _handleTapAt(_dragStartX, screenWidth);
        break;
      case GestureDecision.turnPage:
        if (result.direction == PageDirection.prev) {
          ref.read(readerProvider.notifier).previousPage();
        } else if (result.direction == PageDirection.next) {
          ref.read(readerProvider.notifier).nextPage();
        }
        break;
    }
  }

  /// 根据水平偏移判定翻页方向（viewport 用）
  PageDirection _determineDirection(double dx) {
    if (dx > 0) return PageDirection.prev; // 右滑 = 上一页
    if (dx < 0) return PageDirection.next; // 左滑 = 下一页
    return PageDirection.none;
  }

  /// 点击区域判定（与原逻辑一致：左30%上一页，右30%下一页，中40%菜单）
  void _handleTapAt(double tapX, double screenWidth) {
    if (tapX < screenWidth * 0.3) {
      ref.read(readerProvider.notifier).previousPage();
    } else if (tapX > screenWidth * 0.7) {
      ref.read(readerProvider.notifier).nextPage();
    } else {
      _toggleMenu();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5DC), // Beige background
      body: SafeArea(
        child: Stack(
          children: [
            // Main reading area — P2: Listener 处理原始指针事件（tap + drag 统一）
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
                            ? ReaderPageWidget(
                                pageInfo: state.currentPage!,
                                applyBold: ref.watch(
                                    readerProvider.notifier).boldEnabled,
                                applyItalic: ref.watch(
                                    readerProvider.notifier).italicEnabled,
                                // TXT 章节标题加粗对齐：粗体开关开启且非 EPUB
                                applyTitleBold:
                                    ref.watch(readerProvider.notifier)
                                            .boldEnabled &&
                                        !ref.watch(readerProvider.notifier)
                                            .renderAsEpub,
                                // M7 排版基准同源：绘制与 Rust 断行一致
                                baseFontSize: ref.watch(
                                    readerProvider.notifier).fontSize,
                                baseLineHeight: ref.watch(
                                    readerProvider.notifier).lineHeight,
                              )
                            : const Center(child: Text('No content')),
              ),
            ),

            // Top status bar (always visible)
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

            // Bottom menu (conditional)
            if (_showMenu)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ReaderMenu(
                  onClose: () => setState(() => _showMenu = false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
