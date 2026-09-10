import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart' show Note;
import '../../../../core/models/simple_models.dart';
import '../providers/reader_provider.dart';
import '../widgets/page_turn/page_turn_gesture.dart';
import '../widgets/page_turn/page_turn_types.dart';
import '../widgets/page_turn_composer.dart';
import '../widgets/reader_menu.dart';
import '../widgets/reader_page_widget.dart';
import '../widgets/selection_highlight_painter.dart';
import '../widgets/text_selection_overlay.dart';

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

  /// P4: 翻页模式（2026-09-04 P1: 上移 ReaderNotifier 持久化——原 widget
  /// 本地 state 随 ReaderPage 销毁重置，换书即丢设置；getter 读 notifier，
  /// setter 写 notifier（写穿落库）+ 本地 setState 驱动重建）
  PageTurnMode get _pageTurnMode =>
      ref.read(readerProvider.notifier).pageTurnMode;

  /// 2026-09-03: 翻页动画速度三档（同上移持久化）
  PageTurnSpeed get _pageTurnSpeed =>
      ref.read(readerProvider.notifier).pageTurnSpeed;

  // ── P2: 滑动手势状态 ──
  bool _isDragging = false;
  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragLastX = 0;
  double _dragLastY = 0;
  int _dragLastTimestampMs = 0;
  double _releaseVelocityX = 0;

  // A31-v3: 长按选区 + 手势仲裁
  Timer? _longPressTimer;
  bool _longPressTriggered = false;
  /// PointerDown 时间戳（ms）——用于快速移动提前判定
  int _pointerDownMs = 0;
  /// 选区扩展节流（60fps = 16ms）
  int _lastSelectionUpdateMs = 0;

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
    _longPressTimer?.cancel();
    ref.read(readerProvider.notifier).closeBook();
    super.dispose();
  }

  void _toggleMenu() {
    setState(() {
      _showMenu = !_showMenu;
    });
  }

  /// A31-bugfix: 点击已有笔记高亮 → 弹出编辑/删除菜单
  void _showNoteEditMenu(Note note) {
    final notifier = ref.read(readerProvider.notifier);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 摘录预览
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: Text(
                note.excerpt.length > 80
                    ? '${note.excerpt.substring(0, 80)}…'
                    : note.excerpt,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
            ),
            if (note.note != null && note.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '备注：${note.note}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.edit, size: 20),
              title: const Text('编辑备注'),
              dense: true,
              onTap: () {
                Navigator.pop(ctx);
                _editNoteDialog(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  size: 20, color: Colors.red),
              title: const Text('删除笔记', style: TextStyle(color: Colors.red)),
              dense: true,
              onTap: () {
                Navigator.pop(ctx);
                notifier.deleteNote(note.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// A31-bugfix: 编辑笔记备注对话框
  void _editNoteDialog(Note note) {
    final notifier = ref.read(readerProvider.notifier);
    final controller = TextEditingController(text: note.note ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入备注…',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.updateNoteText(note.id, controller.text);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
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
    _longPressTriggered = false;
    _pointerDownMs = event.timeStamp.inMilliseconds;

    final notifier = ref.read(readerProvider.notifier);
    final page = notifier.state.currentPage;

    // A31-bugfix-v2: 点击已有笔记高亮 → 弹出编辑菜单（不启动长按 Timer）
    if (page != null) {
      final hitOffset = notifier.hitTestCharOffset(
        Offset(event.localPosition.dx, event.localPosition.dy),
        page,
      );
      if (hitOffset != null) {
        final existingNote = notifier.noteAtCharOffset(hitOffset);
        if (existingNote != null) {
          // 短暂延迟等待抬起——若用户拖拽则取消（不是单击）
          _longPressTimer?.cancel();
          _longPressTimer = Timer(const Duration(milliseconds: 200), () {
            if (!_isDragging) {
              // 手指已抬起且未拖拽 → 单击已有笔记
              _showNoteEditMenu(existingNote);
            }
          });
          return; // 不启动长按选区 Timer
        }
      }
    }

    // A31-bugfix: 启动长按计时器（500ms 后触发选区）
    // 互斥规则：Timer 到时检查翻页是否已启动——已启动则放弃选区
    if (page != null) {
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: 500), () {
        if (!_isDragging) return; // 手指已抬起
        // 模式互斥：翻页拖拽已启动 → 不激活选区
        final composerIdle = _composerKey.currentState?.isIdle ?? true;
        final composerPending =
            _composerKey.currentState?.hasPendingTurn ?? false;
        if (!composerIdle || composerPending) return;
        final hitOffset = notifier.hitTestCharOffset(
          Offset(_dragStartX, _dragStartY),
          page,
        );
        if (hitOffset != null) {
          _longPressTriggered = true;
          final (wordStart, _) = notifier.expandToWordBoundary(hitOffset, page);
          notifier.prepareDragCache(page); // A31-v5: 预构建 TextPainter 缓存
          notifier.beginSelection(wordStart);
        }
      });
    }
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

    final notifier = ref.read(readerProvider.notifier);

    // A31-v3: 选区已激活 → 拖拽扩展选区（节流 16ms），不翻页
    if (notifier.hasSelection) {
      // 60fps 节流：避免高频 updateSelection 导致卡顿
      if (now - _lastSelectionUpdateMs < 16) return;
      _lastSelectionUpdateMs = now;
      final page = notifier.state.currentPage;
      if (page != null) {
        final hitOffset = notifier.hitTestCharOffset(local, page);
        if (hitOffset != null) {
          notifier.updateSelection(hitOffset);
        }
      }
      return; // 选区模式下不触发翻页
    }

    // A31-v3: 快速移动提前判定（0-150ms 内移动 >10px → 翻页优先）
    // 业界标准：快速拖拽优先于长按——立即取消 Timer 防止误触选区
    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;
    final distance = dx.abs();
    final elapsed = now - _pointerDownMs;

    if (elapsed < 150 && distance > 10.0) {
      _longPressTimer?.cancel(); // 快速移动 → 取消长按
    }

    // 超过启动阈值才开始动画（避免微抖误触发）
    // M9.5-J：挂起中不再重调 startDrag（之前 100ms × N 重复 register）
    if (distance > 8.0 &&
        _composerKey.currentState?.isIdle == true &&
        _composerKey.currentState?.hasPendingTurn != true) {
      final direction = dx > 0 ? PageDirection.prev : PageDirection.next;
      // 竖向意图压倒横向时不启动
      if (dy.abs() <= distance * 1.5) {
        // A31-bugfix: 翻页拖拽启动 → 取消长按 Timer（模式互斥）
        _longPressTimer?.cancel();
        _composerKey.currentState?.startDrag(
          direction,
          Offset(_dragStartX, _dragStartY),
        );
      }
    }

    // 持续更新进度 + 实时触点
    if (_composerKey.currentState?.isIdle == false) {
      final rawProgress = (distance / notifier.screenWidth).clamp(0.0, 1.0);
      final dampedProgress = _applyProgressiveDamping(rawProgress);
      _composerKey.currentState?.updateDrag(
        dampedProgress,
        Offset(_dragLastX, _dragLastY),
      );
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _longPressTimer?.cancel();
    if (!_isDragging) return;
    _isDragging = false;

    final notifier = ref.read(readerProvider.notifier);

    // A31-v5: 长按选区模式下抬起 → 清理拖拽缓存
    if (_longPressTriggered) {
      _longPressTriggered = false;
      return;
    }

    final dx = _dragLastX - _dragStartX;
    final dy = _dragLastY - _dragStartY;
    final moveDist = (dx.abs() + dy.abs());

    // A31-bugfix: 选区激活时，单击（几乎无移动）→ 清除选区；
    // 拖拽后抬起 → 保持选区（用户在扩展选区）
    if (notifier.hasSelection) {
      if (moveDist < 8.0) {
        notifier.clearSelection();
      }
      return; // 选区模式下不触发翻页
    }

    // 单次手势判定（此前重复计算两遍，已合并）
    final result = resolveGesture(
      dx: dx,
      dy: dy,
      velocityX: _releaseVelocityX,
      screenWidth: notifier.screenWidth,
    );

    // composer 正在拖拽 → 由其执行收尾动画
    if (_composerKey.currentState?.isIdle == false) {
      // 2026-09-04 修复"连点同位置无法翻页"：动画/提交在途的纯点击
      // 此前按 shouldTurn=false 被吞（分区判定只覆盖空闲路径）——同一
      // 位置首击能翻、连点不能。现在在途点击走与空闲点击一致的意图
      // 判定后转排队（composer 侧 _turnEndInFlight 拦截 + 落地补跑）。
      if (result.decision == GestureDecision.tap) {
        final dir = _resolveInFlightTapDirection(event.localPosition, dx);
        if (dir != null) {
          _composerKey.currentState?.endDrag(
            shouldTurn: true,
            direction: dir,
          );
        }
        // dir == null（菜单意图/无方向）→ 在途时忽略，不弹菜单打断动画
        return;
      }
      _composerKey.currentState?.endDrag(
        shouldTurn: result.decision == GestureDecision.turnPage,
        direction: result.direction,
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
        // 2026-09-04: 传入真实点击坐标（坍塌模式用作坍塌中心）
        _handleTapGesture(dx, dy, event.localPosition);
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

  /// 坍塌模式点击分区（2026-09-04 v2：2D 中心区域，用户反馈修正）
  ///
  /// - 中心矩形（x∈[30%,70%] 且 y∈[30%,70%]）→ null = 菜单意图。
  ///   此前是纯横向竖条（中间 40% 全高都是菜单），点屏幕下方偏中的
  ///   位置也会弹菜单——「中部」应是屏幕正中的 2D 区域而非竖条。
  /// - 其余区域全部翻页：左半 → prev，右半 → next
  PageDirection? _collapseTapZone(Offset pos, double w, double h) {
    final inCenterX = pos.dx >= w * 0.3 && pos.dx <= w * 0.7;
    final inCenterY = pos.dy >= h * 0.3 && pos.dy <= h * 0.7;
    if (inCenterX && inCenterY) return null;
    return pos.dx < w * 0.5 ? PageDirection.prev : PageDirection.next;
  }

  /// 在途点击的翻页意图判定（动画/提交窗口期 pointer-up 走这里）
  /// 与空闲点击（_handleTapGesture）同一套语义：
  /// - 坍塌模式：2D 分区（返回 null = 菜单意图，在途时忽略）
  /// - 其他模式：微手势方向
  PageDirection? _resolveInFlightTapDirection(Offset pos, double dx) {
    if (_pageTurnMode == PageTurnMode.collapse) {
      final notifier = ref.read(readerProvider.notifier);
      return _collapseTapZone(pos, notifier.screenWidth, notifier.screenHeight);
    }
    if (dx > 3.0) return PageDirection.prev;
    if (dx < -3.0) return PageDirection.next;
    return null;
  }

  /// 2026-09-03 第二阶段优化：基于手势方向判断翻页
  /// - 右滑（dx > 微小阈值）→ 上一页
  /// - 左滑（dx < -微小阈值）→ 下一页
  /// - 几乎无位移 → 打开菜单
  ///
  /// 2026-09-04 坍塌模式专属：2D 中心区域开菜单（v2，见 _collapseTapZone），
  /// 其余区域点击翻页（坍塌中心=真实点击点）
  void _handleTapGesture(double dx, double dy, Offset tapPos) {
    const microGestureThreshold = 3.0; // 3px 微手势阈值

    if (_pageTurnMode == PageTurnMode.collapse) {
      final notifier = ref.read(readerProvider.notifier);
      final dir = _collapseTapZone(
        tapPos,
        notifier.screenWidth,
        notifier.screenHeight,
      );
      if (dir == null) {
        _toggleMenu();
      } else {
        _composerKey.currentState?.tapTurn(dir, tapPosition: tapPos);
      }
      return;
    }

    if (dx > microGestureThreshold) {
      // 右滑 → 上一页
      _composerKey.currentState?.tapTurn(PageDirection.prev, tapPosition: tapPos);
    } else if (dx < -microGestureThreshold) {
      // 左滑 → 下一页
      _composerKey.currentState?.tapTurn(PageDirection.next, tapPosition: tapPos);
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

  /// P5: 切换翻页模式（写 notifier → 持久化落库）
  void _setPageTurnMode(PageTurnMode mode) {
    ref.read(readerProvider.notifier).setPageTurnMode(mode);
    setState(() {});
  }

  /// 2026-09-03: 切换翻页速度（写 notifier → 持久化落库；下一次翻页生效，
  /// 动画中切换安全——控制器在每次翻页开始时重建并读取当前档位）
  void _setPageTurnSpeed(PageTurnSpeed speed) {
    ref.read(readerProvider.notifier).setPageTurnSpeed(speed);
    setState(() {});
  }

  /// 2026-09-04 P1: 切换暗黑主题（notifier 更新静态主题+revision 并落库；
  /// setState 驱动整树重建——PagePainter 以构造期捕获的 revision 比对
  /// 触发重绘，翻页快照键含主题分量自动生成新主题纹理）
  void _toggleThemeDark() {
    ref.read(readerProvider.notifier).setThemeDark(
          !ref.read(readerProvider.notifier).themeDark,
        );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerProvider);
    return Scaffold(
      // 2026-09-04 P1 暗黑主题：Scaffold 背景跟随阅读主题（内容区由
      // PagePainter 纸色底全覆盖，此处主要影响加载/无内容态观感）
      backgroundColor: PageContentRenderer.theme.scaffoldColor,
      // A30b 真机修复：阅读器不参与键盘避让——配 合 manifest
      // adjustNothing（窗口不缩小），背景内容在软键盘弹出/收起全程
      // 纹丝不动（阅读场景无输入框，无需为键盘腾位）。
      resizeToAvoidBottomInset: false,
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
            // 与 MediaQuery.sizeOf/viewPaddingOf 不等才是真正的 cutout 残留
            // （曲面屏/分屏），Flutter 自身问题——需要溯源时再临时取用。
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
            // A30 真机修复（2026-09-07）：软键盘弹出时 Scaffold
            // resizeToAvoidBottomInset 会临时压缩 body，LayoutBuilder 测得
            // "假尺寸变化"→ onWindowResized 全章重排 → 内容闪一下。搜索
            // 对话框是唯一带输入框的对话框，故搜索时必现。键盘弹出期间
            // （viewInsets.bottom > 0）属临时视口态，跳过重排登记；键盘
            // 收起后 constraints 回到原值自然恢复，无需补偿。分屏/转屏时
            // insets 不变，真实尺寸变化照常重排，行为不受影响。
            final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
            if (!keyboardVisible &&
                (wLayout != notifier.screenWidth ||
                    hLayout != notifier.screenHeight)) {
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
                        speed: _pageTurnSpeed,
                      )
                    : const Center(child: Text('No content')),
              ),
            ),

            // A31-v4: 选区高亮独立覆盖层（只重绘高亮矩形，不触发整页重绘）
            if (state.currentPage != null && !state.isLoading && state.error == null)
              SelectionHighlightLayer(page: state.currentPage!),

            // A31: 文本选区 Overlay（长按激活后显示工具条+手柄）
            if (state.currentPage != null && !state.isLoading && state.error == null)
              Positioned.fill(
                child: ReaderSelectionOverlay(
                  page: state.currentPage!,
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
                  pageTurnMode: notifier.pageTurnMode,
                  onPageTurnModeChanged: _setPageTurnMode,
                  pageTurnSpeed: notifier.pageTurnSpeed,
                  onPageTurnSpeedChanged: _setPageTurnSpeed,
                  themeDark: notifier.themeDark,
                  onToggleTheme: _toggleThemeDark,
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
  final PageTurnSpeed speed;

  const _PageTurnComposerBridge({
    super.key,
    required this.currentPage,
    required this.mode,
    this.speed = PageTurnSpeed.medium,
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

  void endDrag({required bool shouldTurn, PageDirection? direction}) {
    _composerKey.currentState
        ?.onDragEnd(shouldTurn: shouldTurn, direction: direction);
  }

  void tapTurn(PageDirection direction, {Offset? tapPosition}) {
    _composerKey.currentState?.onTapTurn(direction, tapPosition: tapPosition);
  }

  @override
  Widget build(BuildContext context) {
    return PageTurnComposer(
      key: _composerKey,
      currentPage: widget.currentPage,
      mode: widget.mode,
      speed: widget.speed,
    );
  }
}
