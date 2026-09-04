import 'page_turn_controller.dart';
import 'page_turn_types.dart';

/// 上下滚动翻页动画控制器
///
/// 拖拽阶段 progress 线性跟随手指；松手后 easeOutCubic 减速到位
/// （基类 _animateTo 统一驱动）。
/// P3 清理：buildSimulation 死代码路径与 _CurvedSimulation 已删除。
class ScrollTurnController extends PageTurnAnimationController {
  ScrollTurnController({required super.vsync, required super.onProgressUpdate});

  @override
  PageDirection get direction => PageDirection.none; // 由外部覆写
}
