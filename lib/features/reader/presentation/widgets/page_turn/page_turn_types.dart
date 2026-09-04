// M9.4 翻页动画类型定义
//
// 首期模式：仿真卷曲 / 上下滚动；覆盖 / 平移 / 无动画 留作二期扩展位
// （对齐 legado PageDelegate 家族：Simulation/Scroll/Cover/Slide/NoAnim）。

import 'package:flutter/animation.dart';

import 'page_turn_controller.dart';
import 'scroll_turn_controller.dart';
import 'simulation_turn_controller.dart';
import 'ripple_turn_controller.dart';
import 'collapse_turn_controller.dart';

/// 翻页方向
enum PageDirection { none, prev, next }

/// 翻页动画模式
enum PageTurnMode {
  simulation,      // 卷曲翻页
  verticalScroll,  // 上下滚动
  ripple,          // 水波纹翻页（2026-09-03 新增）
  collapse,        // 方块坍塌溶解翻页（2026-09-04 新增，点击位置为坍塌中心）
}

/// 翻页动画速度（2026-09-03 三档：快/中/慢）
///
/// 当前作用于水波纹翻页动画时长；卷曲为弹簧物理驱动、滚动为
/// 固定短时长，暂不随此档位变化。
enum PageTurnSpeed {
  fast,    // 快（400ms）
  medium,  // 中（600ms，默认）
  slow;    // 慢（800ms）

  /// 水波纹翻页动画总时长（毫秒）
  int get rippleDurationMs {
    switch (this) {
      case PageTurnSpeed.fast:
        return 400;
      case PageTurnSpeed.medium:
        return 600;
      case PageTurnSpeed.slow:
        return 800;
    }
  }

  /// 菜单显示文案
  String get label {
    switch (this) {
      case PageTurnSpeed.fast:
        return '快';
      case PageTurnSpeed.medium:
        return '中';
      case PageTurnSpeed.slow:
        return '慢';
    }
  }
}

/// 翻页请求结果（供动画层区分「成功提交」与「到边界回弹」）
enum PageTurnResult { success, atStart, atEnd, failed }

/// 根据模式创建对应的翻页动画控制器
PageTurnAnimationController createTurnController({
  required PageTurnMode mode,
  required PageDirection direction,
  required TickerProvider vsync,
  required void Function(double progress) onProgressUpdate,
  PageTurnSpeed speed = PageTurnSpeed.medium,
}) {
  switch (mode) {
    case PageTurnMode.simulation:
      return SimulationTurnController(
        vsync: vsync,
        onProgressUpdate: onProgressUpdate,
      );
    case PageTurnMode.verticalScroll:
      return ScrollTurnController(
        vsync: vsync,
        onProgressUpdate: onProgressUpdate,
      );
    case PageTurnMode.ripple:
      return RippleTurnController(
        vsync: vsync,
        onProgressUpdate: onProgressUpdate,
        durationMs: speed.rippleDurationMs,
      );
    case PageTurnMode.collapse:
      return CollapseTurnController(
        vsync: vsync,
        onProgressUpdate: onProgressUpdate,
        durationMs: speed.rippleDurationMs,
      );
  }
}
