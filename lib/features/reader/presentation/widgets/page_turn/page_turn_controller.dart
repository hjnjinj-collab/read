import 'package:flutter/animation.dart';

import 'page_turn_types.dart';

/// 翻页动画控制器抽象基类
///
/// 管理一个 [AnimationController]，驱动翻页进度从 0.0（未翻）到 1.0（翻完）。
/// 支持两种驱动模式：
/// 1. 手势直接驱动 — 拖拽时 [dragTo] 直接设置 progress
/// 2. 自动播放 — 松手后 [animateTurn] 或 [animateSnapBack] 自动播放到目标值
///
/// 子类只需覆写 [buildSimulation] 提供不同的动画曲线。
abstract class PageTurnAnimationController {
  PageTurnAnimationController({
    required TickerProvider vsync,
    required this.onProgressUpdate,
    Duration duration = const Duration(milliseconds: 300),
  }) : _controller = AnimationController(
          vsync: vsync,
          duration: duration,
        ) {
    _controller.addListener(_onTick);
  }

  final AnimationController _controller;
  final void Function(double progress) onProgressUpdate;

  PageDirection get direction;

  /// 当前动画进度 [0.0, 1.0]
  double get progress => _controller.value;

  /// 动画是否正在播放
  bool get isAnimating => _controller.isAnimating;

  /// 手势拖拽时直接驱动进度（不触发自动播放）
  void dragTo(double value) {
    _controller.value = value.clamp(0.0, 1.0);
  }

  /// 正向播放翻页动画（从当前值到 1.0）
  Future<void> animateTurn() async {
    final simulation = buildSimulation(
      from: _controller.value,
      to: 1.0,
    );
    _controller.reset();
    _controller.value = simulation.x(0);
    await _controller.animateWith(simulation);
  }

  /// 反向播放回弹动画（从当前值到 0.0）
  Future<void> animateSnapBack() async {
    final simulation = buildSimulation(
      from: _controller.value,
      to: 0.0,
    );
    _controller.reset();
    _controller.value = simulation.x(0);
    await _controller.animateWith(simulation);
  }

  /// 子类提供动画曲线实现
  ///
  /// [from] 当前进度，[to] 目标进度（0.0=未翻，1.0=翻完）
  Simulation buildSimulation({required double from, required double to});

  void _onTick() {
    onProgressUpdate(_controller.value);
  }

  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
  }
}
