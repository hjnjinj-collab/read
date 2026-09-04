import 'package:flutter/animation.dart';

import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 水波纹翻页动画控制器
///
/// 2026-09-03 v2：横向潮汐推进效果
/// - 从屏幕左/右侧开始，横向推进
/// - 多层波浪叠加，产生流畅的潮汐感
/// - 2026-09-03 三档速度：快=400ms / 中=600ms / 慢=800ms（默认中）
///
/// 注意：实际动画时长由 [turnDuration] 提供（基类 animateTo 路径）。
/// P3 清理：buildSimulation 死代码路径与 _LinearSimulation 已删除。
class RippleTurnController extends PageTurnAnimationController {
  /// 翻页方向（拖拽启动时确定；点击路径由 composer 排队逻辑覆写）
  final PageDirection _direction = PageDirection.none;

  RippleTurnController({
    required super.vsync,
    required super.onProgressUpdate,
    int durationMs = 600,
  }) : _turnDurationMs = durationMs;

  /// 翻页动画时长（毫秒），由 PageTurnSpeed.rippleDurationMs 注入
  final int _turnDurationMs;

  @override
  Duration get turnDuration => Duration(milliseconds: _turnDurationMs);

  @override
  PageDirection get direction => _direction;
}
