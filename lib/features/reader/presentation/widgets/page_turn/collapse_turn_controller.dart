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
/// 注意：实际动画时长由 [turnDuration] 提供（基类 animateTo 路径）。
/// P3 清理：buildSimulation 死代码路径与 _LinearSimulation 已删除。
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
}
