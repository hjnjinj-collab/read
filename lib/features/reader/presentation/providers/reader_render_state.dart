import 'package:flutter/foundation.dart';

import '../../../../core/models/simple_models.dart';
import '../widgets/page_turn/page_turn_types.dart';

/// 只读渲染页面包装：identity + revision 语义
///
/// 对齐 Android Track C1 的 ReaderRenderPage：
/// - [identical(page, other.page)] 判定同一可变页实例
/// - [revision] 递增确保相同页重发时仍可触发 Flutter rebuild
@immutable
class ReaderRenderPage {
  final PageInfo page;
  final int revision;

  const ReaderRenderPage({required this.page, required this.revision});

  @override
  bool operator ==(Object other) =>
      other is ReaderRenderPage &&
      identical(page, other.page) &&
      revision == other.revision;

  @override
  int get hashCode => identityHashCode(page) * 31 + revision.hashCode;
}

/// 不可变文本位置快照
///
/// 对齐 Android 的 TextPos，但为不可变值对象。
/// [relativePage]：-1=上一页，0=当前页，1=下一页
@immutable
class ReaderTextPosition {
  final int relativePage;
  final int lineIndex;
  final int columnIndex;

  const ReaderTextPosition({
    required this.relativePage,
    required this.lineIndex,
    required this.columnIndex,
  });
}

/// 不可变选择区间
@immutable
class ReaderSelection {
  final ReaderTextPosition start;
  final ReaderTextPosition end;

  const ReaderSelection({required this.start, required this.end});
}

/// 朗读高亮范围（单页内）
@immutable
class ReaderReadAloudHighlight {
  final int relativePage;
  final int firstLineIndex;
  final int lastLineIndex;

  const ReaderReadAloudHighlight({
    required this.relativePage,
    required this.firstLineIndex,
    required this.lastLineIndex,
  });
}

/// 低频结构渲染模型（三页 + 选择 + 朗读 + loading）
///
/// 聚合所有渲染所需的结构数据。仅在页面内容/选择/朗读状态变化时更新，
/// 不随触点/动画进度高频变化。
@immutable
class ReaderRenderModel {
  final ReaderRenderPage? previousPage;
  final ReaderRenderPage? currentPage;
  final ReaderRenderPage? nextPage;
  final int durPageIndex;
  final ReaderSelection? selection;
  final List<ReaderReadAloudHighlight> readAloudHighlights;
  final String? message;
  final bool isLoading;

  const ReaderRenderModel({
    this.previousPage,
    this.currentPage,
    this.nextPage,
    this.durPageIndex = 0,
    this.selection,
    this.readAloudHighlights = const [],
    this.message,
    this.isLoading = false,
  });

  ReaderRenderModel copyWith({
    ReaderRenderPage? Function()? previousPage,
    ReaderRenderPage? Function()? currentPage,
    ReaderRenderPage? Function()? nextPage,
    int? durPageIndex,
    ReaderSelection? Function()? selection,
    List<ReaderReadAloudHighlight>? readAloudHighlights,
    String? Function()? message,
    bool? isLoading,
  }) {
    return ReaderRenderModel(
      previousPage:
          previousPage != null ? previousPage() : this.previousPage,
      currentPage: currentPage != null ? currentPage() : this.currentPage,
      nextPage: nextPage != null ? nextPage() : this.nextPage,
      durPageIndex: durPageIndex ?? this.durPageIndex,
      selection: selection != null ? selection() : this.selection,
      readAloudHighlights:
          readAloudHighlights ?? this.readAloudHighlights,
      message: message != null ? message() : this.message,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// 高频 viewport 与动画状态
///
/// 承载触点坐标、动画进度等高频变化数据，与结构态 [ReaderRenderModel]
/// 独立更新，避免触点事件替换整个结构态导致不必要的 rebuild。
@immutable
class ReaderRenderViewport {
  final double width;
  final double height;
  final double startX;
  final double startY;
  final double touchX;
  final double touchY;
  final PageDirection direction;
  final bool isAnimationRunning;
  final double animationProgress;

  const ReaderRenderViewport({
    this.width = 0,
    this.height = 0,
    this.startX = 0,
    this.startY = 0,
    this.touchX = 0,
    this.touchY = 0,
    this.direction = PageDirection.none,
    this.isAnimationRunning = false,
    this.animationProgress = 0,
  });
}

/// 双通道只读渲染状态存储
///
/// 对齐 Android Track C1 的 ReaderRenderStateStore：
/// - 低频 [model]：三页绘制数据、选择、朗读高亮、loading
/// - 高频 [viewport]：触点坐标、方向、动画进度
///
/// 两个通道互相独立：viewport 更新不替换结构性 model。
/// 通过 [addListener] 注册回调，与 Riverpod/ChangeNotifier 解耦。
class ReaderRenderStateStore {
  ReaderRenderModel _model;
  ReaderRenderViewport _viewport;

  ReaderRenderStateStore()
      : _model = const ReaderRenderModel(),
        _viewport = const ReaderRenderViewport();

  ReaderRenderModel get model => _model;
  ReaderRenderViewport get viewport => _viewport;

  // ── listener 管理（对齐 StateFlow collect） ──

  final List<void Function(ReaderRenderModel)> _modelListeners = [];
  final List<void Function(ReaderRenderViewport)> _viewportListeners = [];

  void addModelListener(void Function(ReaderRenderModel) listener) {
    _modelListeners.add(listener);
  }

  void removeModelListener(void Function(ReaderRenderModel) listener) {
    _modelListeners.remove(listener);
  }

  void addViewportListener(void Function(ReaderRenderViewport) listener) {
    _viewportListeners.add(listener);
  }

  void removeViewportListener(void Function(ReaderRenderViewport) listener) {
    _viewportListeners.remove(listener);
  }

  void dispose() {
    _modelListeners.clear();
    _viewportListeners.clear();
  }

  // ── 发布方法（对齐 publishSession / publishStructure / publishViewport） ──

  int _revision = 0;

  /// 更新会话级信息（书籍/章节等），保留已有的三页数据
  void publishSession({String? bookId, int? chapterIndex}) {
    // 会话信息暂存于 model 的扩展字段中（P1 阶段再细化）
    // 当前阶段仅用于测试保留语义
  }

  /// 发布结构态：三页 + 选择 + 朗读高亮 + loading
  ///
  /// 对齐 Android 的 publishStructure。每调用一次 revision 递增，
  /// 确保相同可变 PageInfo 实例重发时仍能触发 rebuild。
  void publishStructure({
    PageInfo? previousPage,
    PageInfo? currentPage,
    PageInfo? nextPage,
    int durPageIndex = 0,
    ReaderTextPosition? selectionStart,
    ReaderTextPosition? selectionEnd,
    String? message,
    bool isLoading = false,
  }) {
    _revision++;

    ReaderSelection? selection;
    if (selectionStart != null && selectionEnd != null) {
      selection = ReaderSelection(
        start: selectionStart,
        end: selectionEnd,
      );
    }

    _model = ReaderRenderModel(
      previousPage: previousPage != null
          ? ReaderRenderPage(page: previousPage, revision: _revision)
          : null,
      currentPage: currentPage != null
          ? ReaderRenderPage(page: currentPage, revision: _revision)
          : null,
      nextPage: nextPage != null
          ? ReaderRenderPage(page: nextPage, revision: _revision)
          : null,
      durPageIndex: durPageIndex,
      selection: selection,
      readAloudHighlights: const [], // P1: 从 PageInfo 行数据提取
      message: message,
      isLoading: isLoading,
    );

    for (final listener in _modelListeners) {
      listener(_model);
    }
  }

  /// 发布高频 viewport 状态（触点/动画进度）
  ///
  /// 对齐 Android 的 publishViewport。
  void publishViewport({
    required double width,
    required double height,
    required double startX,
    required double startY,
    required double touchX,
    required double touchY,
    required PageDirection direction,
    required bool isAnimationRunning,
  }) {
    final xProgress = width > 0 ? (touchX - startX).abs() / width : 0.0;
    final yProgress = height > 0 ? (touchY - startY).abs() / height : 0.0;

    _viewport = ReaderRenderViewport(
      width: width,
      height: height,
      startX: startX,
      startY: startY,
      touchX: touchX,
      touchY: touchY,
      direction: direction,
      isAnimationRunning: isAnimationRunning,
      animationProgress: (xProgress > yProgress ? xProgress : yProgress)
          .clamp(0.0, 1.0),
    );

    for (final listener in _viewportListeners) {
      listener(_viewport);
    }
  }
}
