import 'package:flutter/physics.dart';

import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 仿真卷曲翻页动画控制器
///
/// 使用 [SpringSimulation] 模拟纸张弹性，松手后有自然的回弹感。
/// 拖拽阶段 progress 线性跟随手指；松手后弹簧动画接管。
class SimulationTurnController extends PageTurnAnimationController {
  SimulationTurnController({
    required super.vsync,
    required super.onProgressUpdate,
    this.stiffness = 180.0,
    this.damping = 20.0,
  });

  /// 弹簧刚度（越大越"硬"，回弹越快）
  final double stiffness;

  /// 弹簧阻尼（越大振荡越少）
  final double damping;

  @override
  PageDirection get direction => PageDirection.none; // 由外部覆写

  @override
  Simulation buildSimulation({required double from, required double to}) {
    // SpringSimulation: 在 [begin, end] 区间模拟弹簧运动
    // 包裹在 Tween 中映射到 [from, to] 区间
    final spring = SpringDescription(
      mass: 1.0,
      stiffness: stiffness,
      damping: damping,
    );

    // SpringSimulation 从 0 到 1，我们映射到 [from, to]
    return _MappedSpringSimulation(
      spring: spring,
      from: from,
      to: to,
    );
  }
}

/// 将 SpringSimulation 的 [0, 1] 输出映射到 [from, to] 区间
class _MappedSpringSimulation extends Simulation {
  _MappedSpringSimulation({
    required SpringDescription spring,
    required this.from,
    required this.to,
  }) : _inner = SpringSimulation(spring, 0.0, 1.0, 0.0);

  final SpringSimulation _inner;
  final double from;
  final double to;

  @override
  double x(double time) {
    final t = _inner.x(time);
    return from + (to - from) * t.clamp(0.0, 1.0);
  }

  @override
  double dx(double time) {
    return _inner.dx(time) * (to - from);
  }

  @override
  bool isDone(double time) => _inner.isDone(time);
}
