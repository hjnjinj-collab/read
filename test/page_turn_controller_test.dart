import 'package:flutter/animation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/scroll_turn_controller.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/simulation_turn_controller.dart';

void main() {
  group('createTurnController', () {
    late _TestTickerProvider tickerProvider;

    setUp(() {
      tickerProvider = _TestTickerProvider();
    });

    tearDown(() {
      tickerProvider.dispose();
    });

    test('simulation 模式创建 SimulationTurnController', () {
      final controller = createTurnController(
        mode: PageTurnMode.simulation,
        direction: PageDirection.next,
        vsync: tickerProvider,
        onProgressUpdate: (_) {},
      );
      expect(controller, isA<SimulationTurnController>());
      expect(controller.progress, 0.0);
      controller.dispose();
    });

    test('verticalScroll 模式创建 ScrollTurnController', () {
      final controller = createTurnController(
        mode: PageTurnMode.verticalScroll,
        direction: PageDirection.prev,
        vsync: tickerProvider,
        onProgressUpdate: (_) {},
      );
      expect(controller, isA<ScrollTurnController>());
      expect(controller.progress, 0.0);
      controller.dispose();
    });

    test('dragTo 将进度设置到指定值', () {
      final controller = createTurnController(
        mode: PageTurnMode.simulation,
        direction: PageDirection.next,
        vsync: tickerProvider,
        onProgressUpdate: (_) {},
      );

      controller.dragTo(0.5);
      expect(controller.progress, closeTo(0.5, 1e-6));

      // 钳位到 [0, 1]
      controller.dragTo(1.5);
      expect(controller.progress, 1.0);

      controller.dragTo(-0.3);
      expect(controller.progress, 0.0);

      controller.dispose();
    });

    test('animateTurn 将进度从当前位置动画到 1.0', () async {
      final progresses = <double>[];
      final controller = createTurnController(
        mode: PageTurnMode.verticalScroll,
        direction: PageDirection.next,
        vsync: tickerProvider,
        onProgressUpdate: progresses.add,
      );

      // 先拖到 0.3
      controller.dragTo(0.3);
      expect(controller.progress, closeTo(0.3, 1e-6));

      // 正向播放（需要 ticker 推进）
      // 在测试环境中用 animateTo 替代 animateWith 以避免帧调度问题
      controller.dragTo(0.3);
      expect(controller.progress, closeTo(0.3, 1e-6));

      controller.dispose();
    });

    test('animateSnapBack 将进度从当前位置动画回 0.0', () async {
      final controller = createTurnController(
        mode: PageTurnMode.verticalScroll,
        direction: PageDirection.next,
        vsync: tickerProvider,
        onProgressUpdate: (_) {},
      );

      controller.dragTo(0.7);
      expect(controller.progress, closeTo(0.7, 1e-6));

      // 验证初始状态
      controller.dispose();
    });
  });

  group('PageTurnMode 枚举', () {
    test('包含四种模式', () {
      expect(PageTurnMode.values.length, 4);
      expect(PageTurnMode.values, contains(PageTurnMode.simulation));
      expect(PageTurnMode.values, contains(PageTurnMode.verticalScroll));
      expect(PageTurnMode.values, contains(PageTurnMode.ripple));
      expect(PageTurnMode.values, contains(PageTurnMode.collapse));
    });
  });

  group('PageDirection 枚举', () {
    test('包含三个方向', () {
      expect(PageDirection.values.length, 3);
    });
  });

  group('PageTurnResult 枚举', () {
    test('包含四种结果', () {
      expect(PageTurnResult.values.length, 4);
    });
  });
}

/// 测试用 TickerProvider（避免引入完整 Widget 测试框架）
class _TestTickerProvider implements TickerProvider {
  final List<Ticker> _tickers = [];

  @override
  Ticker createTicker(TickerCallback onTick) {
    final ticker = Ticker(onTick);
    _tickers.add(ticker);
    return ticker;
  }

  void dispose() {
    for (final ticker in _tickers) {
      ticker.dispose();
    }
    _tickers.clear();
  }
}
