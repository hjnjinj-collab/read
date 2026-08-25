import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/simple_models.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_render_state.dart';
import 'page_turn/page_turn_controller.dart';
import 'page_turn/page_turn_types.dart';
import 'reader_page_widget.dart';

/// P4 翻页合成 Widget — 管理动画生命周期 + 双页渲染
///
/// 架构:
/// ```
/// Stack [
///   _buildTargetPage()    // 底层：目标页（露出部分）
///   _buildCurrentPage()   // 动画层：当前页（带裁切/偏移）
/// ]
/// ```
///
/// 空闲时只显示当前页；拖拽/动画时两页同时可见，
/// 当前页按进度偏移露出底层目标页。
class PageTurnComposer extends ConsumerStatefulWidget {
  final PageInfo currentPage;
  final PageTurnMode mode;

  const PageTurnComposer({
    super.key,
    required this.currentPage,
    required this.mode,
  });

  @override
  PageTurnComposerState createState() => PageTurnComposerState();
}

class PageTurnComposerState extends ConsumerState<PageTurnComposer>
    with SingleTickerProviderStateMixin {
  PageTurnAnimationController? _turnController;

  /// 翻页方向（拖拽开始时确定）
  PageDirection _turnDirection = PageDirection.none;

  /// 目标页（拖拽开始时从 render store 取出）
  PageInfo? _targetPage;

  /// 当前是否处于拖拽/动画状态
  bool _isActive = false;

  /// 当前是否空闲（无拖拽/动画进行中）
  bool get isIdle => !_isActive;

  @override
  void dispose() {
    _turnController?.dispose();
    super.dispose();
  }

  // ── 公开方法：由 ReaderPage 调用 ──

  /// 拖拽开始：确定方向、取出目标页、创建动画控制器
  void onDragStart(PageDirection direction) {
    final renderModel = ref.read(readerRenderStoreProvider).model;

    PageInfo? target;
    if (direction == PageDirection.next) {
      target = renderModel.nextPage?.page;
    } else if (direction == PageDirection.prev) {
      target = renderModel.previousPage?.page;
    }

    if (target == null) return; // 到边界，不启动动画

    _turnDirection = direction;
    _targetPage = target;
    _isActive = true;

    _turnController?.dispose();
    _turnController = createTurnController(
      mode: widget.mode,
      direction: direction,
      vsync: this,
      onProgressUpdate: (progress) {
        setState(() {}); // 触发重建以更新裁切/偏移
      },
    );
    setState(() {});
  }

  /// 拖拽更新：驱动动画进度
  void onDragUpdate(double progress) {
    if (!_isActive || _turnController == null) return;
    _turnController!.dragTo(progress.clamp(0.0, 1.0));
  }

  /// 拖拽结束：根据判定结果执行动画
  Future<void> onDragEnd({required bool shouldTurn}) async {
    if (!_isActive || _turnController == null) return;

    if (shouldTurn) {
      await _turnController!.animateTurn();
      _commitPageTurn();
    } else {
      await _turnController!.animateSnapBack();
      _resetState();
    }
  }

  /// 点击翻页（无手势拖拽，直接执行简短动画）
  Future<void> onTapTurn(PageDirection direction) async {
    final renderModel = ref.read(readerRenderStoreProvider).model;

    PageInfo? target;
    if (direction == PageDirection.next) {
      target = renderModel.nextPage?.page;
    } else if (direction == PageDirection.prev) {
      target = renderModel.previousPage?.page;
    }
    if (target == null) return;

    _turnDirection = direction;
    _targetPage = target;
    _isActive = true;

    _turnController?.dispose();
    _turnController = createTurnController(
      mode: widget.mode,
      direction: direction,
      vsync: this,
      onProgressUpdate: (_) => setState(() {}),
    );
    setState(() {});

    await _turnController!.animateTurn();
    _commitPageTurn();
  }

  /// 提交翻页：通知 ReaderNotifier 移动到目标页
  void _commitPageTurn() {
    if (_turnDirection == PageDirection.next) {
      ref.read(readerProvider.notifier).nextPage();
    } else if (_turnDirection == PageDirection.prev) {
      ref.read(readerProvider.notifier).previousPage();
    }
    _resetState();
  }

  void _resetState() {
    _isActive = false;
    _targetPage = null;
    _turnDirection = PageDirection.none;
    _turnController?.dispose();
    _turnController = null;
    setState(() {});
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    if (!_isActive || _turnController == null || _targetPage == null) {
      // 空闲态：只显示当前页
      return _buildPage(widget.currentPage);
    }

    final progress = _turnController!.progress;
    final screenWidth = MediaQuery.of(context).size.width;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 底层：目标页（被裁切，只露出露出部分）
        ClipRect(
          clipper: _TargetPageClipper(
            progress: progress,
            direction: _turnDirection,
            screenWidth: screenWidth,
          ),
          child: _buildPage(_targetPage!),
        ),
        // 动画层：当前页（按进度偏移）
        Transform.translate(
          offset: _currentPageOffset(progress, screenWidth),
          child: _buildPage(widget.currentPage),
        ),
        // 阴影叠加（卷曲模式时显示翻页边缘阴影）
        if (widget.mode == PageTurnMode.simulation && progress > 0.01)
          _buildCurlShadow(progress, screenWidth),
      ],
    );
  }

  /// 当前页偏移量
  Offset _currentPageOffset(double progress, double screenWidth) {
    if (_turnDirection == PageDirection.next) {
      // 左滑：当前页向左移出
      return Offset(-screenWidth * progress, 0);
    } else {
      // 右滑：当前页向右移出
      return Offset(screenWidth * progress, 0);
    }
  }

  /// 构建页面渲染 Widget（复用 ReaderPageWidget）
  Widget _buildPage(PageInfo pageInfo) {
    final notifier = ref.watch(readerProvider.notifier);
    return ReaderPageWidget(
      pageInfo: pageInfo,
      applyBold: notifier.boldEnabled,
      applyItalic: notifier.italicEnabled,
      applyTitleBold: notifier.boldEnabled && !notifier.renderAsEpub,
      baseFontSize: notifier.fontSize,
      baseLineHeight: notifier.lineHeight,
    );
  }

  /// 卷曲模式阴影效果
  Widget _buildCurlShadow(double progress, double screenWidth) {
    final shadowX = _turnDirection == PageDirection.next
        ? screenWidth * (1 - progress)
        : screenWidth * progress;

    return Positioned(
      left: _turnDirection == PageDirection.next ? shadowX - 30 : null,
      right: _turnDirection == PageDirection.prev ? shadowX - 30 : null,
      top: 0,
      bottom: 0,
      width: 60,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: _turnDirection == PageDirection.next
                ? Alignment.centerLeft
                : Alignment.centerRight,
            end: _turnDirection == PageDirection.next
                ? Alignment.centerRight
                : Alignment.centerLeft,
            colors: [
              Colors.black.withValues(alpha: 0.3 * progress),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }
}

/// 目标页裁切器：只显示露出区域
class _TargetPageClipper extends CustomClipper<Rect> {
  final double progress;
  final PageDirection direction;
  final double screenWidth;

  _TargetPageClipper({
    required this.progress,
    required this.direction,
    required this.screenWidth,
  });

  @override
  Rect getClip(Size size) {
    final revealed = screenWidth * progress;
    if (direction == PageDirection.next) {
      // 左滑：目标页从右侧露出
      return Rect.fromLTWH(screenWidth - revealed, 0, revealed, size.height);
    } else {
      // 右滑：目标页从左侧露出
      return Rect.fromLTWH(0, 0, revealed, size.height);
    }
  }

  @override
  bool shouldReclip(_TargetPageClipper oldClipper) {
    return progress != oldClipper.progress ||
        direction != oldClipper.direction;
  }
}
