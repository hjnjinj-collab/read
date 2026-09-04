import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 方块坍塌溶解翻页动画控制器
///
/// 2026-09-04 M3：与 RippleTurnController 同构（dragTo 跟手 + easeOutCubic
/// 收尾），仅动画时长来源不同——由 PageTurnSpeed 三档注入。
///
/// 2026-09-04 节奏调优：坍塌视觉密度高于水波纹（径向多波次同时进行），
/// 内部统一 ×1.4 放慢（快=560/中=840/慢=1120ms），三档定义本身不动。
///
/// 注意：实际动画时长由 [turnDuration] 提供（基类 animateTo 路径），
/// [buildSimulation] 是遗留死代码路径（基类不再消费 Simulation）。
class CollapseTurnController extends PageTurnAnimationController {
  CollapseTurnController({
    required super.vsync,
    required super.onProgressUpdate,
    int durationMs = 600,
  }) : _turnDurationMs = (durationMs * 1.4).round();

  /// 翻页动画时长（毫秒），由 PageTurnSpeed.rippleDurationMs 注入（三档共用）
  final int _turnDurationMs;

  @override
  Duration get turnDuration => Duration(milliseconds: _turnDurationMs);

  @override
  PageDirection get direction => PageDirection.none; // 由外部覆写

  @override
  Simulation buildSimulation({required double from, required double to}) {
    // 死代码：基类已改走 animateTo + easeOutCubic，不再消费 Simulation。
    // 仅为满足基类抽象成员保留。
    return _LinearSimulation(from: from, to: to, duration: _turnDurationMs);
  }
}

/// 简单的线性模拟（从 from 到 to，与水波纹遗留实现同源）
class _LinearSimulation extends Simulation {
  _LinearSimulation({
    required this.from,
    required this.to,
    required this.duration,
  });

  final double from;
  final double to;
  final int duration; // milliseconds

  @override
  double x(double time) {
    final progress = (time * 1000 / duration).clamp(0.0, 1.0);
    return from + (to - from) * progress;
  }

  @override
  double dx(double time) {
    return (to - from) / (duration / 1000);
  }

  @override
  bool isDone(double time) {
    return time * 1000 >= duration;
  }
}
