import 'package:flutter_test/flutter_test.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_gesture.dart';
import 'package:legado_flutter/features/reader/presentation/widgets/page_turn/page_turn_types.dart';

void main() {
  const constants = PageTurnGestureConstants();
  const screenWidth = 400.0;

  group('resolveGesture', () {
    test('竖向滑动占主导 → verticalIntent', () {
      // dy 远大于 dx → 竖向意图
      final result = resolveGesture(
        dx: 20,
        dy: 100,
        velocityX: 200,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.verticalIntent);
      expect(result.direction, PageDirection.none);
    });

    test('距离极小 → tap', () {
      final result = resolveGesture(
        dx: 5,
        dy: 5,
        velocityX: 50,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.tap);
    });

    test('左滑距离足够 → turnPage(next)', () {
      // 400 * 0.25 = 100, dx=-120 超过阈值
      final result = resolveGesture(
        dx: -120,
        dy: 10,
        velocityX: -300,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.turnPage);
      expect(result.direction, PageDirection.next);
    });

    test('右滑距离足够 → turnPage(prev)', () {
      final result = resolveGesture(
        dx: 150,
        dy: 5,
        velocityX: 400,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.turnPage);
      expect(result.direction, PageDirection.prev);
    });

    test('距离不足但速度足够 → turnPage', () {
      // dx=50 < threshold(100), 但 velocity=800 > 600
      final result = resolveGesture(
        dx: -50,
        dy: 5,
        velocityX: -800,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.turnPage);
      expect(result.direction, PageDirection.next);
    });

    test('距离不足且速度不够 → snapBack', () {
      final result = resolveGesture(
        dx: -40,
        dy: 5,
        velocityX: -200,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.snapBack);
      expect(result.direction, PageDirection.none);
    });

    test('dx=0 → tap（距离为0）', () {
      final result = resolveGesture(
        dx: 0,
        dy: 0,
        velocityX: 0,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.tap);
    });

    test('竖向刚好不主导时仍判定为横向', () {
      // dy = 25, dx = 20 → dy/dx = 1.25 < 1.5 → 不是竖向
      // dx=20 < tapThreshold(18)? 20 > 18 → 不是 tap
      // dx=20 < threshold(100) 且 velocity=100 < 600 → snapBack
      final result = resolveGesture(
        dx: 20,
        dy: 25,
        velocityX: 100,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.snapBack);
    });

    test('快速左滑短距离 → turnPage(next)', () {
      final result = resolveGesture(
        dx: -30,
        dy: 2,
        velocityX: -1200,
        screenWidth: screenWidth,
        constants: constants,
      );
      expect(result.decision, GestureDecision.turnPage);
      expect(result.direction, PageDirection.next);
    });
  });
}
