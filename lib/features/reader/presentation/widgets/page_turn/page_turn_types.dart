// M9.4 翻页动画类型定义
//
// 首期模式：仿真卷曲 / 上下滚动；覆盖 / 平移 / 无动画 留作二期扩展位
// （对齐 legado PageDelegate 家族：Simulation/Scroll/Cover/Slide/NoAnim）。

import 'package:flutter/animation.dart';

import 'page_turn_controller.dart';
import 'scroll_turn_controller.dart';
import 'simulation_turn_controller.dart';

/// 翻页方向
enum PageDirection { none, prev, next }

/// 翻页动画模式
enum PageTurnMode { simulation, verticalScroll }

/// 翻页请求结果（供动画层区分「成功提交」与「到边界回弹」）
enum PageTurnResult { success, atStart, atEnd, failed }

/// 根据模式创建对应的翻页动画控制器
PageTurnAnimationController createTurnController({
  required PageTurnMode mode,
  required PageDirection direction,
  required TickerProvider vsync,
  required void Function(double progress) onProgressUpdate,
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
  }
}
