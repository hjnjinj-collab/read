import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 仿真卷曲翻页动画控制器
///
/// 拖拽阶段 progress 线性跟随手指；松手后 easeOutCubic 减速到位
/// （基类 _animateTo 统一驱动——弹簧路径因欠阻尼振荡收敛问题已于
/// M10 前废弃，见基类 animateTurn 注释）。
/// P3 清理：buildSimulation 死代码路径与 _MappedSpringSimulation 已删除。
class SimulationTurnController extends PageTurnAnimationController {
  SimulationTurnController({
    required super.vsync,
    required super.onProgressUpdate,
  });

  @override
  PageDirection get direction => PageDirection.none; // 由外部覆写
}
