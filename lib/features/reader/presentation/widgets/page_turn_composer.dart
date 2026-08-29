import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/models/simple_models.dart';
import '../providers/page_frame.dart';
import '../providers/reader_provider.dart';
import '../providers/reader_render_state.dart';
import '../services/book_image_store.dart';
import 'page_turn/page_turn_controller.dart';
import 'page_turn/page_turn_types.dart';
import 'page_turn/curl_painter.dart';
import 'reader_page_widget.dart';
import '../diagnostics/reader_trace.dart';

/// P4 翻页合成 Widget — 管理动画生命周期 + 双页渲染
///
/// 三种呈现：
/// - 空闲：当前页实时渲染（ReaderPageWidget，与动画共用 PageContentRenderer）
/// - simulation 激活：CurlPainter 四层卷曲绘制（贝塞尔折面 + 镜像纸背 + 阴影）
/// - verticalScroll 激活：Y 轴平移滑页
///
/// 无快照架构：空闲帧与动画帧由同一渲染函数逐帧直绘，像素级一致，
/// 起始/完成闪现、背面错位等快照时序 bug 无存在基础
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

  /// render store 引用（initState 缓存；监听注销需在 dispose 中使用）
  ReaderRenderStateStore? _store;

  /// 翻页方向（拖拽开始时确定）
  PageDirection _turnDirection = PageDirection.none;

  /// 目标帧（拖拽开始时从 render store 门控取出）
  PageFrame? _targetFrame;

  /// 当前是否处于拖拽/动画状态
  bool _isActive = false;

  /// 当前是否空闲（无拖拽/动画进行中）
  bool get isIdle => !_isActive;

  // ── 待决手势（不变量 4：帧未就绪时挂起重试） ──

  PageDirection? _pendingDirection;
  bool _pendingIsTap = false;
  Offset _pendingTouch = Offset.zero;
  Timer? _pendingTimer;

  /// 挂起登记时刻（turn.wait 指标：注册 → 动画启动的实际等待）
  DateTime? _pendingSince;

  // ── 卷曲状态 ──

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

  /// 翻页提交后的定格帧：动画末帧与目标页内容一致，定格显示它直到
  /// state 真正切换到新页（身份匹配后撤除），消除旧页闪现
  PageFrame? _settledFrame;
  bool _settledReleaseScheduled = false;
  bool _holdingFinalFrame = false;

  /// 提交在途标记：动画已停但 commit await 未返回的窗口期拒绝新手势，
  /// 防止 _replaceController 处置在用控制器与双重 commit。
  bool _commitInFlight = false;

  /// turn.end 互斥标记：断线重发/系统粘性 pointer up 会导致同一翻页周期
  /// 多次进入 onDragEnd，重复 _runAuto 会重置正在 ticking 的 controller 导致
  /// 上一轮动画"复现"。在 onDragEnd 入口置位、_runAuto 完成后清位。
  bool _turnEndInFlight = false;

  /// 定格安全超时：提交链路异常（FFI 失败/未落地）时强制定格释放，
  /// 避免永久悬挂在定格帧上。
  Timer? _settledSafetyTimer;

  /// 图片就绪重绘通道：与空闲页 PagePainter(repaint: _repaintTick)
  /// 同机制，直达 markNeedsPaint 绕过 shouldRepaint 字段比对。
  final ValueNotifier<int> _imageTick = ValueNotifier<int>(0);

  int _lastFoldingPaintId = 0;
  int _lastRevealPaintId = 0;

  @override
  void initState() {
    super.initState();
    final store = ref.read(readerRenderStoreProvider);
    _store = store;
    // FrameSet 发布监听：首次真实订阅者。帧未就绪时挂起的手势在此重试。
    store.addModelListener(_onModelPublished);
  }

  @override
  void dispose() {
    _store?.removeModelListener(_onModelPublished);
    _pendingTimer?.cancel();
    _settledSafetyTimer?.cancel();
    _imageTick.dispose();
    _turnController?.stop();
    _turnController?.dispose();
    super.dispose();
  }

  // ── 公开方法：由 ReaderPage 经 Bridge 调用 ──

  /// 拖拽开始：门控目标帧（不变量 4），就绪才创建动画控制器
  void onDragStart(PageDirection direction, Offset localTouch) {
    // F1 守卫：动画播放中忽略新请求（防 dispose 正在 tick 的控制器）
    if (_isActive || _turnController?.isAnimating == true) return;

    final result = _targetFrameFor(direction);
    readerTrace('turn.start', {
      'direction': direction,
      'result': result is TargetReady
          ? 'ready'
          : result is TargetOutOfRange
              ? 'out-of-range'
              : 'wait',
    });

    switch (result) {
      case TargetOutOfRange():
        // 越界/邻居加载失败 → 直接翻页保功能（无动画）
        _directFlip(direction);
        return;
      case TargetWait():
        // 帧未就绪（模型滞后/资源解码中）→ 挂起等待。
        // reader_page 的 pointer-move 会重试 startDrag（isIdle 仍为
        // true），FrameSet 发布落地后 listener 也会主动重试。
        _registerPending(direction, isTap: false, touch: localTouch);
        return;
      case TargetReady(:final frame):
        _clearPending(reason: 'started');
        _beginTurn(direction, frame, localTouch);
    }
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
    // 互斥：上一次 turn.end 还在跑（断线重发/系统粘性 pointer up），拒绝重入。
    // 否则重复 _runAuto 会重置正在 ticking 的 controller，导致上一轮动画"复现"。
    if (_turnEndInFlight) return;
    _turnEndInFlight = true;
    readerTrace('turn.end', {'shouldTurn': shouldTurn});
    _releaseTouch = _lastTouchLocal;
    try {
      await _runAuto(shouldTurn);
    } finally {
      _turnEndInFlight = false;
    }
  }

  /// 点击翻页（合成一个屏幕边缘起手的短卷曲动画）
  Future<void> onTapTurn(PageDirection direction) async {
    // 与 onDragStart 同等重入守卫：动画中/拖拽中/定格提交窗口期一律
    // 拒绝——此前只查 isAnimating，提交窗口期点击会 dispose 在用控制器
    // 并双提交（动画前后闪烁根因之一）。
    if (_isActive ||
        _holdingFinalFrame ||
        _commitInFlight ||
        _turnController?.isAnimating == true) {
      return;
    }

    final result = _targetFrameFor(direction);
    if (result is TargetOutOfRange) {
      await _directFlip(direction);
      return;
    }
    if (result is TargetWait) {
      // tap 无 pointer-move 重试来源 → 挂起后由 listener/超时驱动；
      // 超时保功能直翻。
      _registerPending(direction, isTap: true, touch: Offset.zero);
      return;
    }
    final frame = (result as TargetReady).frame;
    _clearPending(reason: 'started');

    final size = MediaQuery.of(context).size;
    // 合成起手触点：next 从右缘中下起手，prev 从左缘
    final start = direction == PageDirection.next
        ? Offset(size.width * 0.92, size.height * 0.8)
        : Offset(size.width * 0.08, size.height * 0.8);

    _beginTurn(direction, frame, start);
    await _runAuto(true);
  }

  // ── 内部流程 ──

  /// 手势门控（PageFrame 不变量 4/6）：返回三态——
  /// ready（启动动画）/ outOfRange（直翻保功能）/ wait（挂起重试）。
  TargetFrameResult _targetFrameFor(PageDirection direction) {
    final store = ref.read(readerRenderStoreProvider);
    final set = store.frameSet;
    // 会话推进后 frame 被作废 → 等新会话批次
    if (set == null) return const TargetWait();
    if (set.sessionEpoch != store.sessionEpoch ||
        set.configFingerprint != store.configFingerprint) {
      return const TargetWait();
    }
    // 模型未跟上可见页（提交/加载窗口期）→ 等待，
    // 杜绝「当前页翻给当前页」与旧批次邻居回写
    if (!set.current.identity.matchesPage(widget.currentPage)) {
      return const TargetWait();
    }
    final bookId = ref.read(readerProvider).bookId;
    if (bookId == null || set.current.identity.bookId != bookId) {
      return const TargetWait();
    }
    final slot = set.slotFor(direction);
    if (slot.outOfRange || slot.loadFailed) {
      // 越界是结构性边界；加载失败等待无意义（下次发布自愈）→ 直翻
      return const TargetOutOfRange();
    }
    final frame = slot.frame;
    if (frame == null || !frame.usableForAnimation) {
      // 资源解码中 → 等待（不变量 4：就绪或稳定 failed 才启动）
      return const TargetWait();
    }
    return TargetReady(frame);
  }

  /// 启动翻页动画（方向 + 目标帧 + 起手触点）
  void _beginTurn(PageDirection direction, PageFrame frame, Offset localTouch) {
    // turn.wait 指标：从挂起登记到真正启动的等待时长
    final since = _pendingSince;
    if (since != null) {
      readerTrace('turn.wait', {
        'direction': direction,
        'waitMs': DateTime.now().difference(since).inMilliseconds,
      });
      _pendingSince = null;
    }
    _turnDirection = direction;
    _targetFrame = frame;
    _isActive = true;
    _dragFirstTouch = localTouch;
    _releaseTouch = localTouch;
    _lastTouchLocal = localTouch;

    _replaceController();
    setState(() {});
  }

  // ── 待决手势管理 ──

  void _registerPending(
    PageDirection direction, {
    required bool isTap,
    required Offset touch,
  }) {
    _pendingDirection = direction;
    _pendingIsTap = isTap;
    _pendingTouch = touch;
    _pendingSince = DateTime.now();
    final store = ref.read(readerRenderStoreProvider);
    store.registerPendingTurn(direction, isTap: isTap);
    _pendingTimer?.cancel();
    _pendingTimer = Timer(
      isTap
          ? const Duration(milliseconds: 400)
          : const Duration(milliseconds: 600),
      () {
        if (!mounted || _pendingDirection == null) return;
        final d = _pendingDirection!;
        final wasTap = _pendingIsTap;
        _clearPending(reason: 'timeout');
        readerTrace('turn.pending.timeout', {'direction': d, 'isTap': wasTap});
        if (wasTap) {
          // 保功能：等待超时后无动画直翻
          _directFlip(d);
        }
        // drag：手指仍在屏，后续 pointer-move 会重试 startDrag
      },
    );
  }

  void _clearPending({required String reason}) {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingDirection = null;
    _pendingSince = null;
    ref.read(readerRenderStoreProvider).cancelPendingTurn(reason);
  }

  /// FrameSet 发布回调：有待决手势时在通知栈外重试启动
  void _onModelPublished(ReaderRenderModel model) {
    if (!mounted || _isActive || _pendingDirection == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isActive || _pendingDirection == null) return;
      _retryPendingTurn();
    });
  }

  void _retryPendingTurn() {
    final direction = _pendingDirection;
    if (direction == null) return;
    final store = ref.read(readerRenderStoreProvider);
    if (store.frameSet == null) return;
    final gesture = store.consumePendingTurn(store.frameSet);
    if (gesture == null) return; // 门控未满足，继续等待
    final isTap = gesture.isTap;
    final touch = _pendingTouch;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingDirection = null;
    readerTrace('turn.pending.retry', {'direction': direction, 'isTap': isTap});

    final result = _targetFrameFor(direction);
    if (result is TargetReady) {
      final frame = result.frame;
      if (isTap) {
        final size = MediaQuery.of(context).size;
        final start = direction == PageDirection.next
            ? Offset(size.width * 0.92, size.height * 0.8)
            : Offset(size.width * 0.08, size.height * 0.8);
        _beginTurn(direction, frame, start);
        _runAuto(true);
      } else {
        _beginTurn(direction, frame, touch == Offset.zero
            ? _dragFirstTouch
            : touch);
      }
    } else if (result is TargetOutOfRange) {
      if (isTap) _directFlip(direction);
    } else {
      // 仍未就绪：重新挂起（计时器归零重算），由下次发布再试
      _registerPending(direction, isTap: isTap, touch: touch);
    }
  }

  /// 无动画直翻（邻居缺失/越界兜底）。可 await：提交路径需要等它
  /// 真正落地后再撤定格，否则会闪现旧页。
  Future<void> _directFlip(PageDirection direction) async {
    final notifier = ref.read(readerProvider.notifier);
    if (direction == PageDirection.next) {
      await notifier.nextPage();
    } else if (direction == PageDirection.prev) {
      await notifier.previousPage();
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

  /// 自动播放：翻完→提交翻页；回弹→复位。返回后控制器已复位/清理。
  Future<void> _runAuto(bool shouldTurn) async {
    final controller = _turnController;
    if (controller == null) return;
    _autoIsTurn = shouldTurn;
    _autoFromProgress = controller.progress;
    if (shouldTurn) {
      await controller.animateTurn();
      await _commitPageTurn();
    } else {
      await controller.animateSnapBack();
      _resetState();
    }
  }

  /// 提交翻页：先定格目标帧（消除 state 更新间隙的旧页闪现），
  /// 再带预载页即时换页（跳过 FFI，对齐 legado onAnimStop→fillPage 同步机制）
  Future<void> _commitPageTurn() async {
    final d = _turnDirection;
    final frame = _targetFrame;
    _settledFrame = frame; // 定格：动画末帧内容 == 目标帧
    // 动画完成后锁定目标普通页面，等待 provider 提交完成。
    // 不再额外绘制一次“最终 CurlPainter 几何帧”，避免视觉上像动画回放。
    _holdingFinalFrame = true;
    _commitInFlight = true;
    final target = frame?.page;
    String? errorMsg;
    try {
      if (frame != null) {
        final notifier = ref.read(readerProvider.notifier);
        if (d == PageDirection.next) {
          await notifier.nextPage(preloaded: target!);
        } else if (d == PageDirection.prev) {
          await notifier.previousPage(preloaded: target!);
        }
        // 等待 revealPage 全部图片资源解码就绪（ready 或稳定 failed）：
        // 短路帧用 PageContentRenderer.paintPage 画新页——图片未就绪时画
        // 占位、异步解码完成后下一帧重画真图，肉眼看到"闪一下"。
        // 同步等 manifest 全部终态后才允许 release，切换两侧像素一致。
        final hrefs = ResourceManifest.of(target!).hrefs;
        if (hrefs.isNotEmpty) {
          await BookImageStore.instance.prewarmManifest(hrefs);
        }
        _armSettledSafetyTimer();
      } else {
        await _directFlip(d);
        _armSettledSafetyTimer();
      }
    } catch (e) {
      errorMsg = e.toString();
      // 提交失败：撤定格回到旧页（可读回退），错误已进 state.error
      _releaseSettled('commit-failed');
    } finally {
      _commitInFlight = false;
      // 合并 start/outcome/settled.release 为单条 turn.commit：
      // 翻页链路的"提交落地"事件，关键字段是 state 是否同步到目标。
      // curl.paint.frame 已含 folding/reveal/isSettled/autoProgress，
      // 不必在 commit 中再列 target/visible。
      final statePage = ref.read(readerProvider).currentPage;
      final tf = _targetFrame;
      readerTrace('turn.commit', {
        'direction': d,
        'state': statePage == null
            ? 'null'
            : '${statePage.chapterIndex}/${statePage.pageIndex}',
        'matchesState': tf == null || statePage == null
            ? false
            : identical(tf.page, statePage),
        if (errorMsg != null) 'error': errorMsg,
      });
    }
  }

  /// 定格帧释放条件：可见页已切到定格目标（同实例，或章节/页/锚点
  /// 三元等价——FrameIdentity.matchesPage）。不满足则继续持有——
  /// 提交窗口期撤定格会闪现旧页。
  bool _settledMatchesCurrentPage() {
    final settled = _settledFrame;
    if (settled == null) return false;
    return settled.identity.matchesPage(widget.currentPage);
  }

  void _scheduleFinalFrameRelease() {
    if (_settledReleaseScheduled) return;
    _settledReleaseScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _settledReleaseScheduled = false;
      if (_settledFrame == null) return;
      if (_settledMatchesCurrentPage()) {
        _releaseSettled('identity-match');
      }
      // 不匹配：等下一次 didUpdateWidget 再调度，或安全超时兜底
    });
  }

  void _releaseSettled(String reason) {
    _settledSafetyTimer?.cancel();
    _settledSafetyTimer = null;
    if (_settledFrame == null && !_holdingFinalFrame) return;
    _holdingFinalFrame = false;
    _settledFrame = null;
    // 不再单独 trace：turn.commit 已覆盖 settled 释放时机（identity-match /
    // safety-timeout / commit-failed 由调用方决定），curl.paint.frame 的
    // isSettled 字段是渲染侧真值，不需要再 trace 一次。
    // 不主动 setState：本路径由 _scheduleFinalFrameRelease 的 postFrame
    // 回调或安全 Timer 触发；外层（didUpdateWidget/state 更新）已经驱动
    // 了一次 build，再 setState 会引发同帧第二次 setState → build → 多一次
    // _buildPage 重绘（page.paint 重复 = 闪烁）。仅清动画状态即可。
    _resetState(clearTarget: false, scheduleRebuild: false);
  }

  void _armSettledSafetyTimer() {
    _settledSafetyTimer?.cancel();
    _settledSafetyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      if (_settledFrame != null) {
        _releaseSettled('safety-timeout');
      }
    });
  }

  void _resetState({bool clearTarget = true, bool scheduleRebuild = true}) {
    _isActive = false;
    if (clearTarget) _targetFrame = null;
    _turnDirection = PageDirection.none;
    _turnController?.stop();
    _turnController?.dispose();
    _turnController = null;
    if (scheduleRebuild && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PageTurnComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // state 已切换到新页 → 撤定格，无缝交还正常渲染（直接实时渲染，无快照）
    // 快速路径：preloaded 直采用同一实例，identical 必然命中；
    // 兜底路径：跨章 FFI 换新实例时按 chapter/pageIndex/startCharIndex
    // 三元对齐（仅 pageIndex 过松——同位置不同内容会提前撤定格）。
    // 不再 trace turn.widget.update：curl.paint.frame 的 folding 字段已
    // 是渲染侧对"新页"的真值，identity 匹配由 turn.commit 报告，重复
    // 输出 turn.widget.update 不会带来诊断价值。
    if (_settledFrame != null && _settledMatchesCurrentPage()) {
      // Provider 更新与动画层退出发生在同一帧时，不能立刻再 setState 一次。
      // 目标页与 settledFrame 已经是同一页面，延迟到当前帧提交后释放，
      // 避免 CurlPainter → PagePainter → PagePainter 的连续重建闪烁。
      _scheduleFinalFrameRelease();
    }
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    if (widget.mode == PageTurnMode.verticalScroll) {
      // scroll 模式无折角概念
      if (_holdingFinalFrame && _settledFrame != null) {
        return _buildPage(_settledFrame!.page);
      }
      return _buildPage(_settledFrame?.page ?? widget.currentPage);
    }
    // curl 模式：
    //   定格期间（_holdingFinalFrame && _settledFrame）→ CurlPainter 末帧短路
    //   release 后（_turnController==null）→ CurlPainter 仍以 autoProgress=1.0
    //     短路画 revealPage=当前页，**消除 PagePainter 直绘与 CurlPainter 短路
    //     帧之间的字形栅格化差异**（同一 paint 栈渲染同一内容，subpixel
    //     rendering 一致 → 不闪）
    //   空闲态（_targetFrame==null）→ 退化到 PagePainter 兜底
    if (_holdingFinalFrame && _settledFrame != null) {
      return _buildCurlTransition();
    }
    if (_isActive && _turnController != null && _targetFrame != null) {
      return widget.mode == PageTurnMode.verticalScroll
          ? _buildScrollTransition()
          : _buildCurlTransition();
    }
    // 释放路径：_turnController==null 但 _targetFrame 保留，revealPage 与
    // widget.currentPage 相同（identical）—— 走 CurlPainter 短路避免切换到
    // PagePainter 直绘带来的 subpixel rendering 差异（"闪一下"）。
    final tf = _targetFrame;
    if (tf != null && identical(tf.page, widget.currentPage)) {
      return _buildCurlTransition();
    }
    return _buildPage(_settledFrame?.page ?? widget.currentPage);
  }

  /// 卷曲过渡（simulation）
  Widget _buildCurlTransition() {
    final size = MediaQuery.of(context).size;
    // 三支 build 走到这里时的 autoProgress 取值：
    // - _holdingFinalFrame（commit 进行中）→ 1.0 短路画 revealPage
    // - _isActive && _turnController != null（拖拽 OR 动画中，build L629 已守卫）→
    //   直接取 _turnController.progress（dragTo/Ticker 推进的 value，不会 null）
    // - 释放路径（_turnController 已 dispose，build L638）→ 1.0 短路画 revealPage
    // 上一版把"!isAnimating"也短路到 1.0，导致拖拽期间一直画 revealPage（无卷曲过程），
    // 观感为"动画还没开始，下一页内容先出现"。
    final autoProgress = _holdingFinalFrame
        ? 1.0
        : (_isActive && _turnController != null
            ? _turnController!.progress
            : 1.0);
    final notifier = ref.watch(readerProvider.notifier);

    // 自动阶段触点插值（legado onAnimStart L226-237 终点语义）：
    //   翻完 → 触点扫过整页（NEXT 终点 (-w,h)），折叠吞没全页后交换，
    //     末帧折叠几何 = 100% 干净目标页
    //   回弹 → 从松手位置回到手势起始点（legado cancel 缩回语义）
    // 映射从起始进度 _autoFromProgress 归一化，避免松手瞬间折叠跳变
    Offset effTouch = _lastTouchLocal;
    // 折缝光影随自动收尾线性淡出：末帧光影归零，与干净定格页无缝衔接
    // （回弹时折叠仍可见，光影保持）
    var washScale = 1.0;
    if (_isActive || _holdingFinalFrame) {
      final from = _autoFromProgress.clamp(0.0, 1.0);
      var t = 0.0;
      if (_holdingFinalFrame) {
        effTouch = _turnDirection == PageDirection.next
            ? Offset(-size.width, size.height)
            : Offset(size.width * 2, size.height);
        washScale = 0.0;
      } else if (_autoIsTurn) {
        t = ((autoProgress - from) / (1.0 - from)).clamp(0.0, 1.0);
        washScale = 1.0 - t;
      } else {
        t = from <= 0.001
            ? 1.0
            : ((from - autoProgress) / from).clamp(0.0, 1.0);
      }
      final Offset sweepTarget;
      if (_autoIsTurn) {
        // legado 精确终点语义（onAnimStart L226-237）：触点扫到折痕轴
        // 恰落对侧页缘——NEXT(-w,h)→轴落 x=0，PREV(2w,h)→轴落 x=w，
        // 末帧折叠几何吞没整页，无当前页残缝
        sweepTarget = _turnDirection == PageDirection.next
            ? Offset(-size.width, size.height)
            : Offset(size.width * 2, size.height);
      } else {
        sweepTarget = _dragFirstTouch;
      }
      effTouch = Offset.lerp(_releaseTouch, sweepTarget, t)!;
    }

    void paintContent(Canvas canvas, PageInfo page) {
      final pageId = readerPageId(page);
      final isFolding = identical(page, widget.currentPage);
      if (isFolding
          ? pageId != _lastFoldingPaintId
          : pageId != _lastRevealPaintId) {
        if (isFolding) {
          _lastFoldingPaintId = pageId;
        } else {
          _lastRevealPaintId = pageId;
        }
        readerTrace('curl.paint.content', {
          'role': isFolding ? 'folding' : 'reveal',
          'page': '${page.chapterIndex}/${page.pageIndex}',
          'pageId': pageId,
          'entries': page.entries.length,
          'fingerprint': readerPageFingerprint([
            ...page.entries
                .take(3)
                .map((entry) => entry.text ?? entry.resourceHref ?? ''),
            page.backgroundHref ?? '',
          ]),
          'summary': readerPageSummary(page.entries),
        });
      }
      PageContentRenderer.paintPage(
        canvas,
        page,
        size: size,
        // 图片解码完成：走 repaint listenable 直达 markNeedsPaint，
        // 不 setState——动画中 touch 不变时新 painter 字段全同，
        // shouldRepaint 会抑制重绘（占位冻结根因）。scheduleFrame
        // 保证定格保持期（无 ticker 运行）也会泵帧重绘。
        onImageNeeded: () {
          _imageTick.value++;
          SchedulerBinding.instance.scheduleFrame();
        },
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
        // 拖动期间 repaint listenable 走 controller 的 repaintNotifier 直达
        // markNeedsPaint，消除 setState→build 重建 painter 的 1 帧延迟；
        // release 后 _turnController 已 dispose 退回到 _imageTick，让图片解
        // 码完成时仍能触发重绘。CustomPaint 内部会合并多次 markNeedsPaint。
        painter: CurlPainter(
          foldingPage: widget.currentPage,
          revealPage: _targetFrame!.page,
          paintContent: paintContent,
          touch: effTouch,
          direction: _turnDirection,
          autoProgress: autoProgress,
          washScale: washScale,
          repaint: _turnController?.repaintNotifier ?? _imageTick,
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
          child: _buildPage(_targetFrame!.page),
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
    return RepaintBoundary(
      child: ReaderPageWidget(
        // 页面 identity 变化时强制替换 StatefulWidget，避免动画 CustomPaint
        // 切回普通页面时复用旧页面节点/旧 repaint notifier。
        key: ValueKey(
          '${pageInfo.chapterIndex}/${pageInfo.pageIndex}/${readerPageId(pageInfo)}',
        ),
        pageInfo: pageInfo,
        applyBold: notifier.boldEnabled,
        applyItalic: notifier.italicEnabled,
        applyTitleBold: notifier.boldEnabled && !notifier.renderAsEpub,
        baseFontSize: notifier.fontSize,
        baseLineHeight: notifier.lineHeight,
      ),
    );
  }
}
