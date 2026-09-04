import 'page_turn_types.dart';

/// P2 手势判定常量
class PageTurnGestureConstants {
  const PageTurnGestureConstants();

  /// 拖拽距离超过屏幕宽度此比例时触发翻页
  /// 2026-09-03 优化：25% → 15%，提升灵敏度
  double get turnDistanceRatio => 0.15;

  /// 速度超过此阈值时即使距离不够也触发翻页（px/s）
  /// 2026-09-03 优化：600 → 400，更容易触发
  double get turnVelocityThreshold => 400.0;

  /// 距离小于此值视为点击（px）
  double get tapDistanceThreshold => 18.0;

  /// 竖直位移需超过水平位移的此倍数，才判定为竖向意图
  double get verticalDominanceRatio => 1.5;
}

/// 手势判定结果
enum GestureDecision {
  /// 竖向意图（垂直滑动占主导），不处理
  verticalIntent,

  /// 点击（距离极小）
  tap,

  /// 触发翻页
  turnPage,

  /// 距离/速度不足，回弹
  snapBack,
}

/// 翻页手势判定的纯函数（无副作用，易测试）
///
/// 根据拖拽偏移、速度和屏幕尺寸判定用户意图。
/// 返回 [GestureDecision] 和判定出的 [PageDirection]。
({GestureDecision decision, PageDirection direction}) resolveGesture({
  required double dx,
  required double dy,
  required double velocityX,
  required double screenWidth,
  PageTurnGestureConstants constants = const PageTurnGestureConstants(),
}) {
  final distance = dx.abs();
  final direction = dx > 0
      ? PageDirection.prev // 右滑 = 上一页
      : dx < 0
          ? PageDirection.next // 左滑 = 下一页
          : PageDirection.none;

  // 竖向意图压倒横向
  if (dy.abs() > distance * constants.verticalDominanceRatio) {
    return (decision: GestureDecision.verticalIntent, direction: PageDirection.none);
  }

  // 距离极小 → 点击
  if (distance < constants.tapDistanceThreshold) {
    return (decision: GestureDecision.tap, direction: PageDirection.none);
  }

  // 判定是否触发翻页：距离足够 或 速度足够
  final threshold = screenWidth * constants.turnDistanceRatio;
  final shouldTurn = distance >= threshold ||
      velocityX.abs() >= constants.turnVelocityThreshold;

  if (shouldTurn) {
    return (decision: GestureDecision.turnPage, direction: direction);
  }

  return (decision: GestureDecision.snapBack, direction: PageDirection.none);
}
