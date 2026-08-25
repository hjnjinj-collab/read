import 'package:flutter/animation.dart';

import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 上下滚动翻页动画控制器
///
/// 使用 [CurvedAnimation] 实现平滑的减速翻页。
/// 拖拽阶段 progress 线性跟随手指；松手后 easeOutCubic 减速到位。
class ScrollTurnController extends PageTurnAnimationController {
  ScrollTurnController({
    required super.vsync,
    required super.onProgressUpdate,
    this.curve = Curves.easeOutCubic,
  });

  /// 自动播放时使用的曲线
  final Curve curve;

  @override
  PageDirection get direction => PageDirection.none; // 由外部覆写

  @override
  Simulation buildSimulation({required double from, required double to}) {
    return _CurvedSimulation(
      from: from,
      to: to,
      curve: curve,
      duration: const Duration(milliseconds: 250),
    );
  }
}

/// 基于 Curve 的 Simulation，从 [from] 匀速/减速运动到 [to]
class _CurvedSimulation extends Simulation {
  _CurvedSimulation({
    required this.from,
    required this.to,
    required this.curve,
    required this.duration,
  });

  final double from;
  final double to;
  final Curve curve;
  final Duration duration;

  double get _durationSeconds => duration.inMicroseconds / 1000000.0;

  @override
  double x(double time) {
    final t = (time / _durationSeconds).clamp(0.0, 1.0);
    final curvedT = curve.transform(t);
    return from + (to - from) * curvedT;
  }

  @override
  double dx(double time) {
    final t = (time / _durationSeconds).clamp(0.0, 1.0);
    // 数值微分：曲线在 t 处的瞬时斜率
    const dt = 0.001;
    final t1 = (t - dt).clamp(0.0, 1.0);
    final t2 = (t + dt).clamp(0.0, 1.0);
    final slope = (curve.transform(t2) - curve.transform(t1)) / (t2 - t1);
    return slope * (to - from) / _durationSeconds;
  }

  @override
  bool isDone(double time) => time >= _durationSeconds;
}
