import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// Cover / Cube 共用：固定时长 tween 控制器（拖拽线性跟手，松手 easeOut）。
class SimpleTurnController extends PageTurnAnimationController {
  SimpleTurnController({
    required super.vsync,
    required super.onProgressUpdate,
    this.durationMs = 600,
  });

  final int durationMs;

  @override
  Duration get turnDuration => Duration(milliseconds: durationMs);

  @override
  PageDirection get direction => PageDirection.none;
}
