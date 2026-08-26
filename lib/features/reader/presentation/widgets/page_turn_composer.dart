import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/simple_models.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_render_state.dart';
import 'page_turn/page_turn_controller.dart';
import 'page_turn/page_turn_types.dart';
import 'page_turn/curl_painter.dart';
import 'reader_page_widget.dart';

/// P4 翻页合成 Widget — 管理动画生命周期 + 双页渲染
///
/// 三种呈现：
/// - 空闲：RepaintBoundary 包裹的当前页（供快照捕获）
/// - simulation 激活：CurlPainter 四层卷曲绘制（贝塞尔折面 + 镜像纸背 + 阴影）
/// - verticalScroll 激活：Y 轴平移滑页
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
    with TickerProviderStateMixin {
  PageTurnAnimationController? _turnController;

  /// 翻页方向（拖拽开始时确定）
  PageDirection _turnDirection = PageDirection.none;

  /// 目标页（拖拽开始时从 render store 取出）
  PageInfo? _targetPage;

  /// 当前是否处于拖拽/动画状态
  bool _isActive = false;

  /// 当前是否空闲（无拖拽/动画进行中）
  bool get isIdle => !_isActive;

  // ── 卷曲状态 ──

  /// 当前页快照（拖拽开始捕获；null 时 CurlPainter 回退直绘）
  ui.Image? _currentSnap;

  /// 快照归属页：与当前页不一致的快照是陈旧内容，拖拽开始时废弃
  PageInfo? _snapPage;

  /// 实时触点（本地坐标，拖拽期间更新）
  Offset _lastTouchLocal = Offset.zero;

  /// 手势起始触点（回弹锚点）
  Offset _dragFirstTouch = Offset.zero;

  /// 松手触点（自动播放插值起点）
  Offset _releaseTouch = Offset.zero;

  /// 当前自动播放方向：true=正向翻完，false=回弹
  bool _autoIsTurn = true;

  /// 自动动画起始时的控制器进度（触点插值映射 [from→1] 或 [from→0] 用）
  double _autoFromProgress = 0;

  /// 翻页提交后的定格页：动画末帧与目标页内容一致，定格显示它直到
  /// state 真正切换到新页（didUpdateWidget 撤除），消除旧页闪现
  PageInfo? _settledTarget;

  /// 空闲态当前页的绘制边界（快照源）
  final _pageBoundaryKey = GlobalKey();

  @override
  void dispose() {
    _turnController?.stop();
    _turnController?.dispose();
    _currentSnap?.dispose();
    super.dispose();
  }

  // ── 公开方法：由 ReaderPage 经 Bridge 调用 ──

  /// 拖拽开始：确定方向、取出目标页、捕获快照、创建动画控制器
  void onDragStart(PageDirection direction, Offset localTouch) {
    // F1 守卫：动画播放中忽略新请求（防 dispose 正在 tick 的控制器）
    if (_turnController?.isAnimating == true) return;

    final target = _targetFor(direction);
    if (target == null) {
      // F2 兜底：邻居页缺失 → 直接翻页保功能（无动画）
      _directFlip(direction);
      return;
    }
    // 目标==可见页说明 model 尚未跟上 state（翻页提交窗口期）→
    // 延迟启动：reader_page 在后续指针移动时会重试 startDrag
    // （isIdle 仍为 true），邻居结构发布落地后自然恢复
    if (identical(target, widget.currentPage)) return;

    _turnDirection = direction;
    _targetPage = target;
    _isActive = true;
    _dragFirstTouch = localTouch;
    _releaseTouch = localTouch;
    _lastTouchLocal = localTouch;

    _prepareSnapshot();
    _replaceController();
    setState(() {});
  }

  /// 拖拽更新：驱动动画进度 + 记录实时触点
  void onDragUpdate(double progress, Offset localTouch) {
    if (!_isActive || _turnController == null) return;
    _lastTouchLocal = localTouch;
    _turnController!.dragTo(progress.clamp(0.0, 1.0));
  }

  /// 拖拽结束：根据判定结果执行自动动画
  Future<void> onDragEnd({required bool shouldTurn}) async {
    if (!_isActive || _turnController == null) return;
    _releaseTouch = _lastTouchLocal;
    await _runAuto(shouldTurn);
  }

  /// 点击翻页（合成一个屏幕边缘起手的短卷曲动画）
  Future<void> onTapTurn(PageDirection direction) async {
    if (_turnController?.isAnimating == true) return;

    final target = _targetFor(direction);
    if (target == null) {
      _directFlip(direction);
      return;
    }
    // 同 onDragStart：提交窗口期目标==可见页时延迟启动
    if (identical(target, widget.currentPage)) return;

    final size = MediaQuery.of(context).size;
    // 合成起手触点：next 从右缘中下起手，prev 从左缘
    final start = direction == PageDirection.next
        ? Offset(size.width * 0.92, size.height * 0.8)
        : Offset(size.width * 0.08, size.height * 0.8);

    _turnDirection = direction;
    _targetPage = target;
    _isActive = true;
    _dragFirstTouch = start;
    _releaseTouch = start;
    _lastTouchLocal = start;

    _prepareSnapshot();
    _replaceController();
    setState(() {});

    await _runAuto(true);
  }

  // ── 内部流程 ──

  PageInfo? _targetFor(PageDirection direction) {
    final model = ref.read(readerRenderStoreProvider).model;
    if (direction == PageDirection.next) return model.nextPage?.page;
    if (direction == PageDirection.prev) return model.previousPage?.page;
    return null;
  }

  void _directFlip(PageDirection direction) {
    final notifier = ref.read(readerProvider.notifier);
    if (direction == PageDirection.next) {
      notifier.nextPage();
    } else if (direction == PageDirection.prev) {
      notifier.previousPage();
    }
  }

  void _replaceController() {
    _turnController?.stop();
    _turnController?.dispose();
    _turnController = createTurnController(
      mode: widget.mode,
      direction: _turnDirection,
      vsync: this,
      onProgressUpdate: (_) => setState(() {}),
    );
  }

  /// 拖拽开始前的快照准备：归属页不符的快照是上一轮翻页的陈旧内容，
  /// 直接废弃——捕获完成的异步窗口内 CurlPainter 回退直绘当前页
  /// （与空闲帧像素一致，无闪现）；快照常备时（预捕获命中）零开销
  void _prepareSnapshot() {
    if (!identical(_snapPage, widget.currentPage)) {
      _currentSnap?.dispose();
      _currentSnap = null;
      _snapPage = null;
    }
    _captureCurrentSnapshot();
  }

  Future<void> _captureCurrentSnapshot() async {
    final ctx = _pageBoundaryKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.attached) return;
    // 边界此刻显示的页（定格优先）即快照内容归属
    final snapPage = _settledTarget ?? widget.currentPage;
    try {
      final img = await ro.toImage(pixelRatio: 1.0);
      _currentSnap?.dispose();
      _currentSnap = img;
      _snapPage = snapPage;
    } catch (_) {
      // 快照失败不致命：CurlPainter 回退到内容直绘
    }
  }

  /// 自动播放：翻完→提交翻页；回弹→复位。返回后控制器已复位/清理。
  Future<void> _runAuto(bool shouldTurn) async {
    final controller = _turnController;
    if (controller == null) return;
    _autoIsTurn = shouldTurn;
    _autoFromProgress = controller.progress;
    if (shouldTurn) {
      await controller.animateTurn();
      _commitPageTurn();
    } else {
      await controller.animateSnapBack();
      _resetState();
    }
  }

  /// 提交翻页：先定格目标页（消除 state 更新间隙的旧页闪现），
  /// 再带预载页即时换页（跳过 FFI，对齐 legado onAnimStop→fillPage 同步机制）
  void _commitPageTurn() {
    final d = _turnDirection;
    final target = _targetPage;
    _settledTarget = target; // 定格：动画末帧内容 == 目标页
    _resetState();
    if (target != null) {
      final notifier = ref.read(readerProvider.notifier);
      if (d == PageDirection.next) {
        notifier.nextPage(preloaded: target);
      } else if (d == PageDirection.prev) {
        notifier.previousPage(preloaded: target);
      }
    } else {
      _directFlip(d);
    }
  }

  void _resetState() {
    _isActive = false;
    _targetPage = null;
    _turnDirection = PageDirection.none;
    _turnController?.stop();
    _turnController?.dispose();
    _turnController = null;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PageTurnComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // state 已切换到新页 → 撤定格，无缝交还正常渲染。
    // 快速路径：preloaded 直采用同一实例，identical 必然命中；
    // 兜底路径：跨章 FFI 换新实例时按 pageIndex 对齐
    if (_settledTarget != null &&
        (identical(widget.currentPage, _settledTarget) ||
            (widget.currentPage != oldWidget.currentPage &&
                widget.currentPage.pageIndex ==
                    _settledTarget!.pageIndex))) {
      _settledTarget = null;
      if (mounted) {
        setState(() {});
        // 新当前页已上屏 → 帧末预捕获快照：快速连翻时拖拽开始
        // 快照常备，不落入直绘回退窗口
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _captureCurrentSnapshot();
        });
      }
    }
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    if (!_isActive || _turnController == null || _targetPage == null) {
      // 空闲态：定格页优先（翻页提交间隙），否则当前页
      // （RepaintBoundary 供快照捕获）
      return RepaintBoundary(
        key: _pageBoundaryKey,
        child: _buildPage(_settledTarget ?? widget.currentPage),
      );
    }

    if (widget.mode == PageTurnMode.verticalScroll) {
      return _buildScrollTransition();
    }
    return _buildCurlTransition();
  }

  /// 卷曲过渡（simulation）
  Widget _buildCurlTransition() {
    final progress = _turnController!.progress;
    final size = MediaQuery.of(context).size;
    final autoActive = _turnController!.isAnimating;
    final autoProgress = autoActive ? progress : null;
    final notifier = ref.watch(readerProvider.notifier);

    // 自动阶段触点插值（legado onAnimStart L226-237 终点语义）：
    //   翻完 → 触点扫过整页（NEXT 终点 (-w,h)），折叠吞没全页后交换；
    //     收尾由 CurlPainter 的淡入层保证末帧 = 100% 干净目标页
    //   回弹 → 从松手位置回到手势起始点（legado cancel 缩回语义）
    // 映射从起始进度 _autoFromProgress 归一化，避免松手瞬间折叠跳变
    Offset effTouch = _lastTouchLocal;
    if (autoProgress != null) {
      final from = _autoFromProgress.clamp(0.0, 1.0);
      final double t;
      if (_autoIsTurn) {
        t = ((autoProgress - from) / (1.0 - from)).clamp(0.0, 1.0);
      } else {
        t = from <= 0.001
            ? 1.0
            : ((from - autoProgress) / from).clamp(0.0, 1.0);
      }
      final Offset sweepTarget;
      if (_autoIsTurn) {
        // legado 精确终点语义（onAnimStart L226-237）：触点扫到折痕轴
        // 恰落对侧页缘——NEXT(-w,h)→轴落 x=0，PREV(2w,h)→轴落 x=w，
        // 末帧折叠几何吞没整页，无当前页残缝（淡入层仅数值兜底）
        sweepTarget = _turnDirection == PageDirection.next
            ? Offset(-size.width, size.height)
            : Offset(size.width * 2, size.height);
      } else {
        sweepTarget = _dragFirstTouch;
      }
      effTouch = Offset.lerp(_releaseTouch, sweepTarget, t)!;
    }

    void paintContent(Canvas canvas, PageInfo page) {
      PageContentRenderer.paintPage(
        canvas,
        page,
        size: size,
        onImageNeeded: () {},
        applyBold: notifier.boldEnabled,
        applyItalic: notifier.italicEnabled,
        applyTitleBold: notifier.boldEnabled && !notifier.renderAsEpub,
        baseFontSize: notifier.fontSize,
        baseLineHeight: notifier.lineHeight,
      );
    }

    return SizedBox.expand(
      child: CustomPaint(
        size: Size.infinite,
        painter: CurlPainter(
          currentImage: _currentSnap,
          currentPage: widget.currentPage,
          targetPage: _targetPage!,
          paintContent: paintContent,
          touch: effTouch,
          direction: _turnDirection,
          autoProgress: autoProgress,
        ),
      ),
    );
  }

  /// 滚动过渡（verticalScroll）：Y 轴平移 + 带状露出
  Widget _buildScrollTransition() {
    final progress = _turnController!.progress;
    final size = MediaQuery.of(context).size;
    final goingNext = _turnDirection == PageDirection.next;
    final offset = size.height * progress * (goingNext ? -1 : 1);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: goingNext ? size.height * (1 - progress) : null,
          bottom: goingNext ? null : size.height * (1 - progress),
          left: 0,
          right: 0,
          height: size.height,
          child: _buildPage(_targetPage!),
        ),
        Transform.translate(
          offset: Offset(0, offset),
          child: _buildPage(widget.currentPage),
        ),
      ],
    );
  }

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
}
