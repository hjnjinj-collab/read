import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/page_turn/page_turn_types.dart';
import 'page_frame.dart';
import '../diagnostics/reader_trace.dart';

/// 全局 ReaderRenderStateStore 实例（P1 接线层）
///
/// ReaderNotifier 通过此 provider 构建并原子发布 FrameSet；
/// 动画层通过此 provider 读取 frame/viewport 并驱动渲染。
final readerRenderStoreProvider = Provider<ReaderRenderStateStore>(
  (ref) => ReaderRenderStateStore(),
);

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

/// 低频结构渲染模型（FrameSet + 选择 + 朗读 + loading）
///
/// 页面结构以 [FrameSet] 为单一事实来源；三页数据要么整体就位、
/// 要么以明确的槽位态（越界/失败/加载中）呈现，不允许静默置 null。
@immutable
class ReaderRenderModel {
  final FrameSet? frameSet;
  final ReaderSelection? selection;
  final List<ReaderReadAloudHighlight> readAloudHighlights;
  final String? message;
  final bool isLoading;

  const ReaderRenderModel({
    this.frameSet,
    this.selection,
    this.readAloudHighlights = const [],
    this.message,
    this.isLoading = false,
  });
}

/// 双通道只读渲染状态存储
///
/// - 低频 [model]：FrameSet（三页帧）、选择、朗读高亮、loading
///
/// FrameSet 发布协议：
/// - [publishFrameSet] 原子替换当前集合（整体提交，无半更新）
/// - [advanceSession] 使旧会话全部帧作废（换书/设置/窗口变化）
/// - 待决手势（[registerPendingTurn]/[consumePendingTurn]）承载
///   「帧未就绪时挂起的翻页意图」，发布落地后由订阅者重试
///
/// P3 清理：高频 viewport 通道已删——publishViewport/addViewportListener
/// 全库零订阅者（只写不读的"未来契约"），触点/进度由 composer 自有
/// 字段直接承载（git 历史可找回）。
class ReaderRenderStateStore {
  ReaderRenderModel _model;

  ReaderRenderStateStore() : _model = const ReaderRenderModel();

  ReaderRenderModel get model => _model;

  // ── FrameSet / 会话身份 ──

  FrameSet? _frameSet;
  int _sessionEpoch = 0;
  String? _configFingerprint;
  bool _dirty = false;
  int _revision = 0;
  PendingTurnGesture? _pendingTurn;

  FrameSet? get frameSet => _frameSet;
  int get sessionEpoch => _sessionEpoch;
  String? get configFingerprint => _configFingerprint;

  /// 请求过期后置位；由下一次（degraded 或完整）发布清除。
  /// 发布协议据此决定是否补发，杜绝「静默丢弃 → 模型永久陈旧」。
  bool get dirty => _dirty;

  PendingTurnGesture? get pendingTurn => _pendingTurn;

  /// 供构建 FrameSet 时取发布序号（publishFrameSet 时生效）
  int nextSetRevision() => _revision + 1;

  // ── listener 管理（对齐 StateFlow collect） ──

  final List<void Function(ReaderRenderModel)> _modelListeners = [];

  void addModelListener(void Function(ReaderRenderModel) listener) {
    _modelListeners.add(listener);
  }

  void removeModelListener(void Function(ReaderRenderModel) listener) {
    _modelListeners.remove(listener);
  }

  void dispose() {
    _modelListeners.clear();
  }

  // ── 发布方法 ──

  /// 会话推进：换书/设置/窗口变化时调用。
  ///
  /// 旧 epoch 的 FrameSet 全部作废、待决手势取消；此后手势门控
  /// 因 frameSet==null 进入等待，直到新会话的 FrameSet 发布。
  void advanceSession({
    required int sessionEpoch,
    required String configFingerprint,
  }) {
    _sessionEpoch = sessionEpoch;
    _configFingerprint = configFingerprint;
    _frameSet = null;
    _dirty = true;
    _pendingTurn = null;
    readerTrace('render.session.advance', {
      'epoch': sessionEpoch,
      'fp': configFingerprint,
    });
  }

  /// 原子发布 FrameSet：整体替换当前集合，revision 递增并通知订阅者。
  void publishFrameSet(FrameSet set) {
    _revision++;
    _frameSet = set;
    _dirty = false;
    _model = ReaderRenderModel(
      frameSet: set,
      selection: _model.selection,
      readAloudHighlights: _model.readAloudHighlights,
      message: _model.message,
      isLoading: _model.isLoading,
    );

    readerTrace('render.publish', {
      'revision': _revision,
      'set': set.id,
      'prev': _slotTrace(set.previous),
      'next': _slotTrace(set.next),
    });

    for (final listener in _modelListeners) {
      listener(_model);
    }
  }

  /// 无 frame 的占位发布（开书 loading / 关书清空），保留消息语义。
  void publishEmpty({String? message, bool isLoading = false}) {
    _revision++;
    _frameSet = null;
    _model = ReaderRenderModel(
      frameSet: null,
      selection: _model.selection,
      readAloudHighlights: _model.readAloudHighlights,
      message: message,
      isLoading: isLoading,
    );
    readerTrace('render.publish.empty', {
      'revision': _revision,
      'loading': isLoading,
      'message': message,
    });
    for (final listener in _modelListeners) {
      listener(_model);
    }
  }

  String _slotTrace(FrameSlot slot) => frameSlotTrace(slot);

  // ── 待决手势 ──

  /// 登记挂起的翻页意图（重复注册覆盖旧意图）。
  /// 返回登记的手势（供调用方核对 epoch）。
  PendingTurnGesture registerPendingTurn(
    PageDirection direction, {
    required bool isTap,
  }) {
    final gesture = PendingTurnGesture(
      direction: direction,
      isTap: isTap,
      epoch: _sessionEpoch,
    );
    _pendingTurn = gesture;
    readerTrace('turn.pending.register', {
      'direction': direction,
      'isTap': isTap,
      'epoch': _sessionEpoch,
    });
    return gesture;
  }

  /// 消费待决手势：仅当传入集合仍是当前发布集合且 epoch 匹配时取出。
  /// 门控（帧可用性）由调用方在消费后判定，不满足时应取消或继续等待。
  PendingTurnGesture? consumePendingTurn(FrameSet? set) {
    final gesture = _pendingTurn;
    if (gesture == null) return null;
    if (set == null || !identical(set, _frameSet)) return null;
    if (gesture.epoch != _sessionEpoch) {
      _pendingTurn = null;
      return null;
    }
    _pendingTurn = null;
    return gesture;
  }

  void cancelPendingTurn(String reason) {
    if (_pendingTurn == null) return;
    _pendingTurn = null;
    readerTrace('turn.pending.cancel', {'reason': reason});
  }

  /// 获取待决手势的方向（供资源预热优先级调整使用）
  /// 
  /// 2026-09-02 阶段2优化：允许 reader_provider 检测挂起的翻页方向，
  /// 优先预热目标方向的资源。
  PageDirection? get pendingTurnDirection => _pendingTurn?.direction;
}
