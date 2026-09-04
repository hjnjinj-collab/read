import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'page_turn/ripple_painter.dart';
import 'page_turn/ripple_painter_v16.dart';
import 'page_turn/ripple_turn_controller.dart';
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

  /// M9.5-J：是否已挂起待决手势（无动画/拖拽但 FrameSet 未发布）。
  /// 供 reader_page._onPointerMove 跳过重复 startDrag 调用。
  bool get hasPendingTurn => _pendingDirection != null;

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

  /// viewport.mismatch 诊断节流（仅状态翻转时输出）
  bool _lastViewportMismatch = false;

  /// 空闲帧（PagePainter 路径）mismatch 诊断节流
  bool _lastIdleViewportMismatch = false;

  /// 绘制层自愈兜底的防抖标记（帧末一次性调度）
  bool _viewportFixInFlight = false;

  /// 权威 viewport（SafeArea 内实际可用区域，逻辑像素）
  ///
  /// viewport 尺寸单源化：翻页起手/横扫终点几何、scroll 平移高度、
  /// paintContent 绘制 size 全部取自 readerProvider 的测量值
  /// （reader_page LayoutBuilder 登记的 canvas 实际尺寸）。
  /// 禁止 MediaQuery.size——那是全屏值，移动端含状态栏/手势条区域。
  Size get _viewport => Size(
        ref.read(readerProvider.notifier).screenWidth,
        ref.read(readerProvider.notifier).screenHeight,
      );

  /// 水波纹 v16 shader（2026-09-03 新增）
  ui.FragmentShader? _rippleShredderShader;

  /// v16.9.7: 每次翻页随机种子（shader 双波叠加波形不规则化）
  double _rippleSeed = 0.0;

  /// 水波纹 v16 页面纹理缓存（预转换的 ui.Image）
  /// 2026-09-03 v16.1: 修复"纹理错位"——以 frameSet.setRevision 为键，
  /// frameSet 切换时立刻淘汰旧纹理，绝不跨 setRevision 复用
  ui.Image? _currentPageImage;
  int? _currentImagePageId;
  ui.Image? _nextPageImage;
  int? _nextImagePageId;
  ui.Image? _prevPageImage;
  int? _prevImagePageId;
  /// 翻页方向（决定显示哪一侧的纹理）
  PageDirection? _prewarmDirection;

  @override
  void initState() {
    super.initState();
    final store = ref.read(readerRenderStoreProvider);
    _store = store;
    
    // 加载 shader
    _loadShaders();
    
    // FrameSet 发布监听：首次真实订阅者。帧未就绪时挂起的手势在此重试。
    store.addModelListener(_onModelPublished);
  }
  
  /// 加载水波纹 shaders（v16 新增 ripple_shredder）
  Future<void> _loadShaders() async {
    try {
      // 加载 v16 粉碎效果 shader
      final shredderProgram = await ui.FragmentProgram.fromAsset('shaders/ripple_shredder.frag');
      if (mounted) {
        setState(() {
          _rippleShredderShader = shredderProgram.fragmentShader();
        });
        readerTrace('ripple.shader.loaded', {'shader': 'ripple_shredder'});
        // v16.1: shader 加载完成后立即预热当前页面纹理
        _prewarmAllPageImages();
      }
    } catch (e) {
      readerTrace('ripple.shader.load.error', {'error': e.toString()});
    }
  }
  
  /// 将 PageInfo 转换为 ui.Image（用于 shader 纹理采样）
  /// 2026-09-03 v16.3: 按 devicePixelRatio 生成高分辨率快照——
  /// 修复"新页纹理模糊 + 动画完成后闪烁"（1x 快照被 GPU 放大 → 与矢量渲染对比闪烁）
  Future<ui.Image?> _pageToImage(PageInfo? page, Size size) async {
    if (page == null) return null;

    try {
      final dpr = View.of(context).devicePixelRatio;
      final pixelWidth = (size.width * dpr).round();
      final pixelHeight = (size.height * dpr).round();

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(dpr);  // 矢量内容按 dpr 缩放绘制，快照原生清晰

      // v16.9.3 核心修复：先画纸色底——paintPage 不含纸色底（调用方自绘），
      // 缺失导致快照透明背景 → 文字笔画间透出下层另一页内容 = 双重文字重影
      //（图片页因图片不透明而"看起来正常"，这正是"文字页重叠/图片页正常"的根因）
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = PageContentRenderer.paperColor,
      );

      final notifier = ref.read(readerProvider.notifier);
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

      final picture = recorder.endRecording();
      final image = await picture.toImage(pixelWidth, pixelHeight);

      readerTrace('ripple.image.converted', {
        'page': '${page.chapterIndex}/${page.pageIndex}',
        'size': '${size.width}x${size.height}',
        'pixels': '${pixelWidth}x${pixelHeight}',
        'dpr': dpr.toStringAsFixed(2),
      });

      return image;
    } catch (e) {
      readerTrace('ripple.image.error', {'error': e.toString()});
      return null;
    }
  }
  
  /// 预热当前页面纹理（翻页启动前调用）
  /// 2026-09-03 v16.1: 取消幂等保护——每次调用都基于当前 pageId 重新生成
  /// 防止"纹理错位"（旧 pageId 的 image 被复用到新 page）
  Future<void> _prewarmCurrentPageImage() async {
    if (widget.mode != PageTurnMode.ripple) return;
    final size = _viewport;
    final store = ref.read(readerRenderStoreProvider);
    final set = store.frameSet;
    if (set == null) return;
    final currentId = set.setRevision;
    final currentPage = set.current.page;
    
    // 仅在 pageId 变化时重新生成（避免每帧重复 toImage）
    if (_currentImagePageId != currentId || _currentPageImage == null) {
      final img = await _pageToImage(currentPage, size);
      if (img == null) return;
      if (!mounted) {
        img.dispose();
        return;
      }
      // 释放旧 image（避免内存泄漏）
      _currentPageImage?.dispose();
      _currentPageImage = img;
      _currentImagePageId = currentId;
    }
  }
  
  /// 预热所有相邻页面纹理（current + next + prev）
  /// 2026-09-03 v16.1: 在 _onModelPublished 中调用，确保 shader 始终
  /// 拿到"当前正在翻页的"页面的真实纹理，杜绝"内容错位"
  Future<void> _prewarmAllPageImages() async {
    if (widget.mode != PageTurnMode.ripple) return;
    if (_rippleShredderShader == null) return; // shader 未加载完成时跳过
    
    final size = _viewport;
    final store = ref.read(readerRenderStoreProvider);
    final set = store.frameSet;
    if (set == null) return;
    
    // 并行预热 3 个页面纹理（current/next/prev）
    final futures = <Future<void>>[];
    
    // 1. 当前页
    final currentId = set.setRevision;
    if (_currentImagePageId != currentId || _currentPageImage == null) {
      futures.add(() async {
        final img = await _pageToImage(set.current.page, size);
        if (img == null) return;
        if (!mounted) {
          img.dispose();
          return;
        }
        _currentPageImage?.dispose();
        _currentPageImage = img;
        _currentImagePageId = currentId;
      }());
    }
    
    // 2. 下一页
    final nextSlot = set.next;
    if (nextSlot != null && nextSlot.frame != null) {
      final nextFrame = nextSlot.frame!;
      // 用 setRevision + chapterIndex/pageIndex 复合 key（避免 next 变化时 key 变化）
      final nextId = set.setRevision * 1000 + nextFrame.identity.chapterIndex * 100 + nextFrame.identity.pageIndex;
      if (_nextImagePageId != nextId || _nextPageImage == null) {
        futures.add(() async {
          final img = await _pageToImage(nextFrame.page, size);
          if (img == null) return;
          if (!mounted) {
            img.dispose();
            return;
          }
          _nextPageImage?.dispose();
          _nextPageImage = img;
          _nextImagePageId = nextId;
        }());
      }
    }
    
    // 3. 上一页
    final prevSlot = set.previous;
    if (prevSlot != null && prevSlot.frame != null) {
      final prevFrame = prevSlot.frame!;
      // prev 用负数 key 避免和 next 冲突
      final prevId = -(set.setRevision * 1000 + prevFrame.identity.chapterIndex * 100 + prevFrame.identity.pageIndex);
      if (_prevImagePageId != prevId || _prevPageImage == null) {
        futures.add(() async {
          final img = await _pageToImage(prevFrame.page, size);
          if (img == null) return;
          if (!mounted) {
            img.dispose();
            return;
          }
          _prevPageImage?.dispose();
          _prevPageImage = img;
          _prevImagePageId = prevId;
        }());
      }
    }
    
    // 等待所有预热完成
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _store?.removeModelListener(_onModelPublished);
    _pendingTimer?.cancel();
    _settledSafetyTimer?.cancel();
    _imageTick.dispose();
    _turnController?.stop();
    _turnController?.dispose();
    // v16.1: 释放所有预热的页面纹理（避免内存泄漏）
    _currentPageImage?.dispose();
    _currentPageImage = null;
    _nextPageImage?.dispose();
    _nextPageImage = null;
    _prevPageImage?.dispose();
    _prevPageImage = null;
    super.dispose();
  }

  // ── 公开方法：由 ReaderPage 经 Bridge 调用 ──

  /// 拖拽开始：门控目标帧（不变量 4），就绪才创建动画控制器
  void onDragStart(PageDirection direction, Offset localTouch) {
    // F1 守卫：动画播放中忽略新请求（防 dispose 正在 tick 的控制器）
    if (_isActive || _turnController?.isAnimating == true) return;
    // M9.5-J：已有挂起手势则拒绝重入（同方向或反方向都算）。
    // 之前每帧 pointer-move 都会过守卫，10 次同 register
    // 把 store 端 _pendingTurn/epoch 反复覆盖，
    // 永远等不到 retry success。J 项用 _pendingRetryCount 上限
    // 兜底 + 此守卫避免无谓重入。
    if (_pendingDirection != null) return;

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
    // M9.5-J：挂起中收到 drag end（FrameSet 期间 gesture 中断）→ 走直翻保功能
    // 不创建新 controller（避免与 listener retry 竞争）
    if (_pendingDirection != null) {
      final d = _pendingDirection!;
      _clearPending(reason: 'end-during-pending');
      readerTrace('turn.drop', {
        'reason': 'end-during-pending',
        'direction': d,
        'shouldTurn': shouldTurn,
      });
      if (shouldTurn) {
        await _directFlip(d);
      }
      return;
    }
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

    final size = _viewport;
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
    if (set == null) {
      readerTrace('turn.gate.wait', {'reason': 'frameSet==null'});
      return const TargetWait();
    }
    if (set.sessionEpoch != store.sessionEpoch ||
        set.configFingerprint != store.configFingerprint) {
      readerTrace('turn.gate.wait', {
        'reason': 'epoch/fingerprint mismatch',
        'setEpoch': set.sessionEpoch,
        'storeEpoch': store.sessionEpoch,
        'setFp': set.configFingerprint,
        'storeFp': store.configFingerprint,
      });
      return const TargetWait();
    }
    // 模型未跟上可见页（提交/加载窗口期）→ 等待，
    // 杜绝「当前页翻给当前页」与旧批次邻居回写
    if (!set.current.identity.matchesPage(widget.currentPage)) {
      readerTrace('turn.gate.wait', {
        'reason': 'current identity mismatch',
        'setPage': '${set.current.identity.chapterIndex}/${set.current.identity.pageIndex}',
        'widgetPage': '${widget.currentPage.chapterIndex}/${widget.currentPage.pageIndex}',
      });
      return const TargetWait();
    }
    final bookId = ref.read(readerProvider).bookId;
    if (bookId == null || set.current.identity.bookId != bookId) {
      readerTrace('turn.gate.wait', {
        'reason': 'bookId mismatch',
        'setBookId': set.current.identity.bookId,
        'currentBookId': bookId,
      });
      return const TargetWait();
    }
    final slot = set.slotFor(direction);
    if (slot.outOfRange || slot.loadFailed) {
      // 越界是结构性边界；加载失败等待无意义（下次发布自愈）→ 直翻
      readerTrace('turn.gate.outOfRange', {
        'outOfRange': slot.outOfRange,
        'loadFailed': slot.loadFailed,
      });
      return const TargetOutOfRange();
    }
    final frame = slot.frame;
    if (frame == null || !frame.usableForAnimation) {
      // 资源解码中 → 等待（不变量 4：就绪或稳定 failed 才启动）
      readerTrace('turn.gate.wait', {
        'reason': 'frame not usable',
        'frameNull': frame == null,
        'usableForAnimation': frame?.usableForAnimation,
        'resourceState': frame?.resourceState.toString(),
      });
      return const TargetWait();
    }
    readerTrace('turn.gate.ready', {'direction': direction});
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
    _prewarmDirection = direction;

    // v16.9.7: 每次翻页随机种子——shader 双波叠加波形不规则化
    _rippleSeed = math.Random().nextDouble() * 100.0;

    // v16.1: 翻页前同步预热当前页纹理（不再幂等跳过）
    // 如果 pageId 变了，必须立即重生成——否则 shader 用旧纹理（用户报告"内容错位"）
    if (widget.mode == PageTurnMode.ripple) {
      _prewarmCurrentPageImage();
    }

    _replaceController();
    setState(() {});
  }

  // ── 待决手势管理 ──

  /// M9.5-J：重试上限。同手势期间 _registerPending 调用 N 次仍等不到
  /// ready → trace turn.drop 并走 _directFlip 保功能。
  /// 之前实现靠"pointer-move 重试会终有一次成功"假设，但 FrameSet
  /// 未发布时是死循环（100ms × N），手感"动画消失"主因。
  static const int _pendingRetryLimit = 5;

  /// M9.5-J：当前挂起的 registerPending 调用次数（同手势累计）
  int _pendingRetryCount = 0;

  /// 2026-09-02 阶段2优化：根据页面复杂度动态计算超时时间
  int _computeDynamicTimeout(PageFrame? frame) {
    const int baseTap = 400;
    const int baseDrag = 600;
    int base = _pendingIsTap ? baseTap : baseDrag;
    
    if (frame == null) return base;
    
    // 复杂度加成
    int imageCount = frame.manifest.hrefs.length;
    int entryCount = frame.page.entries.length;
    
    // 每张图片 +150ms，每 50 个 entry +50ms
    int imageBonus = imageCount * 150;
    int complexityBonus = (entryCount ~/ 50) * 50;
    
    // 总超时上限 2000ms
    return (base + imageBonus + complexityBonus).clamp(base, 2000);
  }

  void _registerPending(
    PageDirection direction, {
    required bool isTap,
    required Offset touch,
  }) {
    // M9.5-J：超上限后丢弃手势，保功能走 _directFlip。
    // 之前 _pendingTimer 倒计时会被每次 register 重置（拖拽持续中
    // 永远到不了 600ms），现在改用"同手势累计 register 次数"硬上限。
    if (!isTap && _pendingRetryCount >= _pendingRetryLimit) {
      readerTrace('turn.drop', {
        'reason': 'retry-limit',
        'retries': _pendingRetryCount,
        'direction': direction,
      });
      _clearPending(reason: 'retry-limit');
      _directFlip(direction);
      return;
    }

    _pendingDirection = direction;
    _pendingIsTap = isTap;
    _pendingTouch = touch;
    _pendingSince = DateTime.now();
    if (!isTap) _pendingRetryCount++;
    final store = ref.read(readerRenderStoreProvider);
    store.registerPendingTurn(direction, isTap: isTap);
    _pendingTimer?.cancel();
    
    // 2026-09-02 阶段2优化：根据目标页面复杂度动态调整超时
    final targetFrame = _getTargetFrame(direction);
    final timeout = _computeDynamicTimeout(targetFrame);
    
    _pendingTimer = Timer(
      Duration(milliseconds: timeout),
      () {
        if (!mounted || _pendingDirection == null) return;
        final d = _pendingDirection!;
        final wasTap = _pendingIsTap;
        _clearPending(reason: 'timeout');
        readerTrace('turn.pending.timeout', {
          'direction': d,
          'isTap': wasTap,
          'timeoutMs': timeout,
        });
        if (wasTap) {
          // 保功能：等待超时后无动画直翻
          _directFlip(d);
        }
        // drag：手指仍在屏，后续 pointer-move 会重试 startDrag
      },
    );
  }
  
  /// 辅助方法：获取目标方向的 PageFrame（用于动态超时计算）
  PageFrame? _getTargetFrame(PageDirection direction) {
    final store = ref.read(readerRenderStoreProvider);
    final set = store.frameSet;
    if (set == null) return null;
    
    switch (direction) {
      case PageDirection.next:
        return set.next.frame;
      case PageDirection.prev:
        return set.previous.frame;
      default:
        return null;
    }
  }

  void _clearPending({required String reason}) {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingDirection = null;
    _pendingSince = null;
    // M9.5-J：每次挂起生命周期结束重置重试计数
    _pendingRetryCount = 0;
    ref.read(readerRenderStoreProvider).cancelPendingTurn(reason);
  }

  /// FrameSet 发布回调：有待决手势时在通知栈外重试启动
  /// 2026-09-03 v16.1: 同时预热所有相邻页面纹理，防止 shader 用旧 pageId
  void _onModelPublished(ReaderRenderModel model) {
    // v16.1: 每次 frameSet 发布都预热（无论是否 pending），确保 shader 纹理
    // 始终与当前 frameSet 同步——杜绝"内容错位"
    if (widget.mode == PageTurnMode.ripple && _rippleShredderShader != null) {
      _prewarmAllPageImages();
    }
    
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
        final size = _viewport;
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
      // 2026-09-03: 根据动画模式选择不同的过渡效果
      if (widget.mode == PageTurnMode.verticalScroll) {
        return _buildScrollTransition();
      } else if (widget.mode == PageTurnMode.ripple) {
        return _buildRippleTransition();
      } else {
        return _buildCurlTransition();
      }
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
    final size = _viewport;
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

    void paintContent(Canvas canvas, PageInfo page, Size canvasSize) {
      // P0-2 防回归：排版 viewport 与绘制 canvas 必须一致——不一致 =
      // 「翻页前后背景纹理尺寸跳变」/「内容偏右/左」类几何错位的直接证据。
      // 静态节流：仅 mismatch 状态翻转时输出（含 layout/canvas/MediaQuery
      // 全套数字，便于切曲面屏/分屏/旋转屏场景溯源）。
      final vw = notifier.screenWidth;
      final vh = notifier.screenHeight;
      final mismatch = (vw - canvasSize.width).abs() > 0.5 ||
          (vh - canvasSize.height).abs() > 0.5;
      if (mismatch != _lastViewportMismatch) {
        _lastViewportMismatch = mismatch;
        final mq = MediaQuery.maybeOf(context);
        readerTrace('viewport.mismatch', {
          'mismatch': mismatch,
          'layout': '${vw}x$vh',
          'canvas': '${canvasSize.width}x${canvasSize.height}',
          if (mq != null) ...{
            'mqSize': '${mq.size.width}x${mq.size.height}',
            'mqViewPad':
                '${mq.viewPadding.left}_${mq.viewPadding.top}_${mq.viewPadding.right}_${mq.viewPadding.bottom}',
            'mqPad':
                '${mq.padding.left}_${mq.padding.top}_${mq.padding.right}_${mq.padding.bottom}',
          },
        });
      }
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
        // 绘制 size = CurlPainter 传入的画布实际尺寸（单源化：与
        // LayoutConfig 排版空间同源，禁止 MediaQuery.size 全屏值）
        size: canvasSize,
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
    final size = _viewport;
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

  /// 水波纹过渡（ripple）—— 2026-09-03 v16.1: Shader 粉碎效果
  Widget _buildRippleTransition() {
    final progress = _turnController!.progress;
    final notifier = ref.read(readerProvider.notifier);  // v16.9.5: 渲染参数同源
    
    // v16.4: 根据翻页方向选择正确的两张纹理
    // next 方向：折叠页 = current（当前页被粉碎），揭示页 = next
    // prev 方向：折叠页 = current（当前页被粉碎），揭示页 = prev（上一页从左侧揭示）
    // （v16.1-v16.3 中 prev 的 folding/reveal 赋值颠倒，导致 prev 翻页出现分割线）
    final isNext = _turnDirection == PageDirection.next;
    final ui.Image? foldingImg = _currentPageImage;
    final ui.Image? revealImg = isNext ? _nextPageImage : _prevPageImage;
    
    // v16: 使用 shader 粉碎效果（如果 shader 和 image 都已准备好）
    if (_rippleShredderShader != null && foldingImg != null) {
      return SizedBox.expand(
        child: CustomPaint(
          size: Size.infinite,
          painter: RipplePainterV16(
            foldingPage: widget.currentPage,
            revealPage: _targetFrame?.page,
            progress: progress,
            direction: _turnDirection,
            // v16.9.5: 渲染参数与正式渲染/CurlPainter 同源（notifier）——
            // 动画中实时直绘的新页与完成后渲染逐像素一致，消除完成闪烁
            applyBold: notifier.boldEnabled,
            applyItalic: notifier.italicEnabled,
            applyTitleBold: notifier.boldEnabled && !notifier.renderAsEpub,
            baseFontSize: notifier.fontSize,
            baseLineHeight: notifier.lineHeight,
            waveSeed: _rippleSeed,
            foldingPageImage: foldingImg,
            revealPageImage: revealImg,
            shredderShader: _rippleShredderShader,
          ),
        ),
      );
    }
    
    // Fallback: 使用 v15 canvas 方块（shader 未加载或 image 未转换完成）
    return SizedBox.expand(
      child: CustomPaint(
        size: Size.infinite,
        painter: RipplePainter(
          foldingPage: widget.currentPage,
          revealPage: _targetFrame?.page,
          progress: progress,
          direction: _turnDirection,
        ),
      ),
    );
  }

  Widget _buildPage(PageInfo pageInfo) {
    final notifier = ref.watch(readerProvider.notifier);
    // 空闲帧 viewport 一致性诊断（curl 帧 paintContent 内已有同款检查，
    // 此处补 PagePainter 路径覆盖）：constraints = 页面 widget 实际画布
    // 约束，必须与排版 LayoutConfig（notifier.screenWidth/Height）一致；
    // 不一致 = 移动端「内容偏右/右侧空白消失」类几何错位的直接证据。
    return LayoutBuilder(builder: (context, constraints) {
      final mismatch =
          (constraints.maxWidth - notifier.screenWidth).abs() > 0.5 ||
              (constraints.maxHeight - notifier.screenHeight).abs() > 0.5;
      if (mismatch != _lastIdleViewportMismatch) {
        _lastIdleViewportMismatch = mismatch;
        final mq = MediaQuery.maybeOf(context);
        readerTrace('viewport.mismatch.idle', {
          'mismatch': mismatch,
          'layout': '${notifier.screenWidth}x${notifier.screenHeight}',
          'canvas': '${constraints.maxWidth}x${constraints.maxHeight}',
          if (mq != null) ...{
            'mqSize': '${mq.size.width}x${mq.size.height}',
            'mqViewPad':
                '${mq.viewPadding.left}_${mq.viewPadding.top}_${mq.viewPadding.right}_${mq.viewPadding.bottom}',
            'mqPad':
                '${mq.padding.left}_${mq.padding.top}_${mq.padding.right}_${mq.padding.bottom}',
          },
        });
      }
      // 绘制层自愈兜底（第二道防线）：画布约束 ≠ 排版宽说明重排链
      // 某环被吞（如 resize 事件与 openBook 竞态）——帧末强制按当前
      // 约束重排一次。onWindowResized 自带判等守卫 + 分页缓存键隔离，
      // 与 reader_page 的 LayoutBuilder 调度重复调用幂等。
      if (mismatch && !_viewportFixInFlight) {
        _viewportFixInFlight = true;
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _viewportFixInFlight = false;
          if (!mounted) return;
          ref.read(readerProvider.notifier).onWindowResized(w, h);
        });
      }
      // v6 修复（重影根因）：resize 风暴期间 mismatch=true 时绘制旧尺寸
      // page 与新尺寸 canvas 错位 → 视觉重影/左右偏。mismatch 时返回空
      // SizedBox 不绘制任何内容，让重排 commit 后再渲染——避免错误
      // size 的 page 在屏幕上闪现，也避免双版本共存视觉重影。
      if (mismatch) {
        return const SizedBox.expand();
      }
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
    });
  }
}
