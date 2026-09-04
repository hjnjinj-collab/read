import 'package:flutter/animation.dart';
import 'package:flutter/physics.dart';

import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 水波纹翻页动画控制器
/// 
/// 2026-09-03 v2：横向潮汐推进效果
/// - 从屏幕左/右侧开始，横向推进
/// - 多层波浪叠加，产生流畅的潮汐感
/// - 动画时长 600ms（比卷曲翻页稍慢，更从容）
class RippleTurnController extends PageTurnAnimationController {
  PageDirection _direction = PageDirection.none;
  
  RippleTurnController({
    required super.vsync,
    required super.onProgressUpdate,
  }) : super(duration: const Duration(milliseconds: 600));
  
  @override
  PageDirection get direction => _direction;
  
  @override
  Simulation buildSimulation({required double from, required double to}) {
    // 水波纹使用简单的线性模拟
    // AnimationController 自带的 Curves.easeOutCubic 提供缓动
    return _LinearSimulation(from: from, to: to, duration: 600);
  }
  
  /// 开始翻页（点击或滑动触发）
  void startForward(PageDirection direction, Offset? tapPosition) {
    _direction = direction;
    animateTurn();
  }
}

/// 简单的线性模拟（从 from 到 to）
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
