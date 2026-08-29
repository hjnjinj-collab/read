import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

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

  /// 手势拖拽时直接驱动进度（不触发自动播放）。
  /// 同步触发 [repaintNotifier]：_controller.value setter 已通知 listeners
  /// （_onTick → onProgressUpdate → setState），但 setState 是下一帧 build
  /// 才让 painter 重建——1 帧 16ms 延迟对快速拖动不跟手。额外戳 repaint
  /// listenable 让 CustomPaint 同步调 paint（markNeedsPaint 直达 GPU），
  /// 拖动期间消除 1 帧滞后。
  final ValueNotifier<int> repaintNotifier = ValueNotifier<int>(0);

  void dragTo(double value) {
    _controller.value = value.clamp(0.0, 1.0);
    repaintNotifier.value++;
  }

  /// 正向播放翻页动画（从当前值到 1.0）。
  ///
  /// 用 AnimationController.animateTo + CurvedAnimation 替代原 SpringSimulation
  /// 路径：弹簧在欠阻尼下需要完整振荡周期才能让 isDone 判定收敛（stiffness=180
  /// damping=20 特征周期 ~700ms），兜底逻辑层层加锁仍有边缘 bug（commit 链
  /// 路死锁、setState 时序错乱）。改用 300ms 固定时长 + easeOutCubic 曲线：
  /// duration 走完必定 complete、progress 终值必定 1.0，curl_painter
  /// autoProgress>=0.9995 短路命中 → 纹理一致。
  Future<void> animateTurn() async {
    await _animateTo(
      from: _controller.value,
      to: 1.0,
      duration: const Duration(milliseconds: 300),
    );
  }

  /// 反向播放回弹动画（从当前值到 0.0）
  Future<void> animateSnapBack() async {
    await _animateTo(
      from: _controller.value,
      to: 0.0,
      duration: const Duration(milliseconds: 300),
    );
  }

  /// 通用动画播放：用 AnimationController.animateTo + CurvedAnimation 直接
  /// 驱动，不再走 Simulation 路径——简化掉仿真收敛、兜底、TickerCanceled
  /// catch 一连串易错点。duration 走完必定 complete、终值必定 to。
  Future<void> _animateTo({
    required double from,
    required double to,
    required Duration duration,
  }) async {
    _controller.stop();
    _controller.value = from;
    await _controller.animateTo(to, duration: duration, curve: Curves.easeOutCubic);
  }

  /// 停止当前动画（dispose 前必须调用，避免销毁正在 tick 的控制器断言失败）
  void stop() {
    _controller.stop();
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
    repaintNotifier.dispose();
  }
}
